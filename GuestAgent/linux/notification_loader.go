//go:build linux || darwin

package main

import (
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const maximumNotificationSnapshotBytes = 64 * 1024

// A snapshot modified this recently could be rewritten again within the
// resolution of its timestamps, so a scan that saw one is not remembered.
const notificationSettleTime = 2 * time.Second

var omarchyNotificationFilePattern = regexp.MustCompile(`^([0-9]+)-([0-9]+)\.json$`)

var desktopNotificationCache notificationCache

// notificationCache remembers the parsed snapshots of one directory. The Host
// polls every two seconds and the snapshots rarely change, so a poll normally
// costs one directory listing and one lstat per snapshot instead of opening,
// reading and parsing every file.
type notificationCache struct {
	lock      sync.Mutex
	valid     bool
	directory string
	uid       uint32
	signature string
	batch     desktopNotificationBatch
}

func (cache *notificationCache) load(directory string, uid uint32, now time.Time) desktopNotificationBatch {
	cache.lock.Lock()
	defer cache.lock.Unlock()
	// Take the signature before reading any snapshot: a file that changes
	// while it is read then differs from the remembered signature on the next
	// poll instead of matching it.
	names, signature, newest, err := notificationDirectorySignature(directory)
	if err != nil {
		cache.valid = false
		return desktopNotificationBatch{Message: "Omarchy notification state is unavailable."}
	}
	if cache.valid && cache.directory == directory && cache.uid == uid && cache.signature == signature {
		return copyNotificationBatch(cache.batch)
	}
	batch := loadDesktopNotificationFiles(directory, uid, names)
	cache.valid = now.Sub(newest) >= notificationSettleTime
	cache.directory, cache.uid, cache.signature = directory, uid, signature
	cache.batch = copyNotificationBatch(batch)
	return batch
}

func copyNotificationBatch(batch desktopNotificationBatch) desktopNotificationBatch {
	if batch.Notifications != nil {
		batch.Notifications = append([]desktopNotification{}, batch.Notifications...)
	}
	return batch
}

// notificationDirectorySignature lists the snapshot candidates of a directory
// and describes the directory and each candidate by what lstat reports. Any
// snapshot that is added, removed, replaced or rewritten changes it.
func notificationDirectorySignature(directory string) (names []string, signature string, newest time.Time, err error) {
	directoryInfo, err := os.Stat(directory)
	if err != nil {
		return nil, "", time.Time{}, err
	}
	entries, err := os.ReadDir(directory)
	if err != nil {
		return nil, "", time.Time{}, err
	}
	var text strings.Builder
	describe := func(name string, info os.FileInfo) {
		text.WriteString(name)
		text.WriteByte(0)
		text.WriteString(strconv.FormatInt(info.Size(), 10))
		text.WriteByte(0)
		text.WriteString(strconv.FormatInt(info.ModTime().UnixNano(), 10))
		text.WriteByte(0)
		text.WriteString(strconv.FormatUint(uint64(info.Mode()), 8))
		if stat, ok := info.Sys().(*syscall.Stat_t); ok {
			text.WriteByte(0)
			text.WriteString(strconv.FormatUint(uint64(stat.Ino), 10))
			text.WriteByte(0)
			text.WriteString(strconv.FormatUint(uint64(stat.Uid), 10))
		}
		text.WriteByte('\n')
		if info.ModTime().After(newest) {
			newest = info.ModTime()
		}
	}
	describe(".", directoryInfo)
	for _, entry := range entries {
		if !omarchyNotificationFilePattern.MatchString(entry.Name()) || entry.Type()&os.ModeSymlink != 0 {
			continue
		}
		names = append(names, entry.Name())
		info, err := os.Lstat(filepath.Join(directory, entry.Name()))
		if err != nil {
			text.WriteString(entry.Name())
			text.WriteString("\x00unavailable\n")
			// Whatever removed it may still be at work.
			newest = time.Now()
			continue
		}
		describe(entry.Name(), info)
	}
	return names, text.String(), newest, nil
}

func loadDesktopNotifications(directory string, uid uint32) desktopNotificationBatch {
	entries, err := os.ReadDir(directory)
	if err != nil {
		return desktopNotificationBatch{Message: "Omarchy notification state is unavailable."}
	}
	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		if !omarchyNotificationFilePattern.MatchString(entry.Name()) || entry.Type()&os.ModeSymlink != 0 {
			continue
		}
		names = append(names, entry.Name())
	}
	return loadDesktopNotificationFiles(directory, uid, names)
}

func loadDesktopNotificationFiles(directory string, uid uint32, names []string) desktopNotificationBatch {
	values := make([]desktopNotification, 0, len(names))
	for _, name := range names {
		matches := omarchyNotificationFilePattern.FindStringSubmatch(name)
		if len(matches) != 3 {
			continue
		}
		path := filepath.Join(directory, name)
		info, err := os.Lstat(path)
		if err != nil || !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > maximumNotificationSnapshotBytes {
			continue
		}
		stat, ok := info.Sys().(*syscall.Stat_t)
		if !ok || stat.Uid != uid {
			continue
		}
		file, err := os.Open(path)
		if err != nil {
			continue
		}
		// Revalidate the opened descriptor. The desktop user owns this directory
		// and can replace a path between Lstat and Open; only consume the exact
		// regular, owned, bounded file that is now open.
		openedInfo, statError := file.Stat()
		if statError != nil {
			file.Close()
			continue
		}
		openedStat, statOK := openedInfo.Sys().(*syscall.Stat_t)
		if !openedInfo.Mode().IsRegular() || openedInfo.Size() <= 0 ||
			openedInfo.Size() > maximumNotificationSnapshotBytes || !statOK || openedStat.Uid != uid {
			file.Close()
			continue
		}
		var snapshot omarchyNotificationSnapshot
		decodeError := json.NewDecoder(io.LimitReader(file, maximumNotificationSnapshotBytes+1)).Decode(&snapshot)
		file.Close()
		if decodeError != nil {
			continue
		}
		fileTimestamp, _ := strconv.ParseUint(matches[1], 10, 64)
		if snapshot.Timestamp == 0 {
			snapshot.Timestamp = fileTimestamp
		}
		value, err := validatedDesktopNotification(desktopNotification{
			ID: name, App: snapshot.App, Title: snapshot.Summary,
			Body: snapshot.Body, Urgency: snapshot.Urgency, Timestamp: snapshot.Timestamp,
		})
		if err == nil {
			values = append(values, value)
		}
	}
	sort.Slice(values, func(first, second int) bool {
		if values[first].Timestamp == values[second].Timestamp {
			return values[first].ID < values[second].ID
		}
		return values[first].Timestamp < values[second].Timestamp
	})
	if len(values) > maximumDesktopNotifications {
		values = values[len(values)-maximumDesktopNotifications:]
	}
	return desktopNotificationBatch{Success: true, Message: "Current Omarchy notifications captured.", Notifications: values}
}
