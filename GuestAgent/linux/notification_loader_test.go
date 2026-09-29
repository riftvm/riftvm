//go:build linux || darwin

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func writeSnapshot(t *testing.T, directory, name, summary string, modified time.Time) {
	t.Helper()
	path := filepath.Join(directory, name)
	payload := fmt.Sprintf(`{"app":"Browser","summary":%q,"body":"Body","urgency":1,"timestamp":0}`, summary)
	if err := os.WriteFile(path, []byte(payload), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, modified, modified); err != nil {
		t.Fatal(err)
	}
}

func settleDirectory(t *testing.T, directory string, modified time.Time) {
	t.Helper()
	if err := os.Chtimes(directory, modified, modified); err != nil {
		t.Fatal(err)
	}
}

func titles(batch desktopNotificationBatch) []string {
	values := []string{}
	for _, notification := range batch.Notifications {
		values = append(values, notification.Title)
	}
	return values
}

// makeUnreadable removes every permission from a snapshot and keeps its
// modification time.
func makeUnreadable(t *testing.T, path string) {
	t.Helper()
	if os.Getuid() == 0 {
		t.Skip("root can read files without permission")
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0); err != nil {
		t.Fatal(err)
	}
	// Restore the timestamps chmod does not touch, but not the mode.
	if err := os.Chtimes(path, info.ModTime(), info.ModTime()); err != nil {
		t.Fatal(err)
	}
}

func TestNotificationCacheMatchesAFreshLoad(t *testing.T) {
	directory := t.TempDir()
	uid := uint32(os.Getuid())
	old := time.Now().Add(-time.Hour)
	for index := 0; index < maximumDesktopNotifications+3; index++ {
		writeSnapshot(t, directory, fmt.Sprintf("%d-%d.json", 1000+index, index), fmt.Sprintf("Notice %d", index), old)
	}
	if err := os.WriteFile(filepath.Join(directory, "1500-1.json"), []byte(`{"summary":`), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "not-a-notification.json"), []byte(`{"summary":"ignored"}`), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(directory, "1000-0.json"), filepath.Join(directory, "9999-1.json")); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(filepath.Join(directory, "1500-1.json"), old, old); err != nil {
		t.Fatal(err)
	}
	settleDirectory(t, directory, old)

	var cache notificationCache
	want := loadDesktopNotifications(directory, uid)
	for poll := 0; poll < 3; poll++ {
		got := cache.load(directory, uid, time.Now())
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("poll %d:\n got %#v\nwant %#v", poll, got, want)
		}
		first, _ := json.Marshal(got)
		second, _ := json.Marshal(want)
		if string(first) != string(second) {
			t.Fatalf("poll %d encodes differently:\n got %s\nwant %s", poll, first, second)
		}
	}
	if !cache.valid || len(want.Notifications) != maximumDesktopNotifications {
		t.Fatalf("valid=%v notifications=%d", cache.valid, len(want.Notifications))
	}
}

func TestNotificationCacheAnswersAnUnchangedDirectoryWithoutReadingSnapshots(t *testing.T) {
	directory := t.TempDir()
	uid := uint32(os.Getuid())
	old := time.Now().Add(-time.Hour)
	writeSnapshot(t, directory, "1000-1.json", "First", old)
	writeSnapshot(t, directory, "1001-2.json", "Second", old)
	settleDirectory(t, directory, old)

	var cache notificationCache
	if got := titles(cache.load(directory, uid, time.Now())); !reflect.DeepEqual(got, []string{"First", "Second"}) {
		t.Fatalf("first poll = %v", got)
	}
	// Rewrite one snapshot in place and restore its timestamp, so that lstat
	// reports exactly what it reported before. Only reading the file again
	// could reveal the new title.
	path := filepath.Join(directory, "1000-1.json")
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	replacement := fmt.Sprintf(`{"app":"Browser","summary":%q,"body":"Body","urgency":1,"timestamp":0}`, "Tampr")
	if int64(len(replacement)) != info.Size() {
		t.Fatalf("replacement is %d bytes, snapshot %d", len(replacement), info.Size())
	}
	file, err := os.OpenFile(path, os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.WriteString(replacement); err != nil {
		t.Fatal(err)
	}
	file.Close()
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatal(err)
	}
	// Same name, size, inode, owner, mode and modification time: the poll must
	// be answered from memory. This is the one change the cache cannot see,
	// and it needs a writer that restores the timestamp.
	if got := titles(cache.load(directory, uid, time.Now())); !reflect.DeepEqual(got, []string{"First", "Second"}) {
		t.Fatalf("unchanged directory was read again: %v", got)
	}
	if got := titles(loadDesktopNotifications(directory, uid)); !reflect.DeepEqual(got, []string{"Tampr", "Second"}) {
		t.Fatalf("fresh load = %v", got)
	}
}

func TestNotificationCacheSeesEveryKindOfChange(t *testing.T) {
	uid := uint32(os.Getuid())
	old := time.Now().Add(-time.Hour)
	later := old.Add(time.Minute)
	for name, test := range map[string]struct {
		change func(t *testing.T, directory string)
		want   []string
	}{
		"added": {func(t *testing.T, directory string) {
			writeSnapshot(t, directory, "1002-3.json", "Third", later)
		}, []string{"First", "Second", "Third"}},
		"removed": {func(t *testing.T, directory string) {
			if err := os.Remove(filepath.Join(directory, "1000-1.json")); err != nil {
				t.Fatal(err)
			}
		}, []string{"Second"}},
		"rewritten with another size": {func(t *testing.T, directory string) {
			writeSnapshot(t, directory, "1000-1.json", "First, edited", old)
		}, []string{"First, edited", "Second"}},
		"rewritten with the same size": {func(t *testing.T, directory string) {
			writeSnapshot(t, directory, "1000-1.json", "Frist", later)
		}, []string{"Frist", "Second"}},
		"replaced by rename with the same size and time": {func(t *testing.T, directory string) {
			writeSnapshot(t, directory, "replacement.tmp", "Fresh", old)
			if err := os.Rename(filepath.Join(directory, "replacement.tmp"), filepath.Join(directory, "1000-1.json")); err != nil {
				t.Fatal(err)
			}
			settleDirectory(t, directory, old)
		}, []string{"Fresh", "Second"}},
		"replaced by a symbolic link": {func(t *testing.T, directory string) {
			path := filepath.Join(directory, "1000-1.json")
			if err := os.Remove(path); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(filepath.Join(directory, "1001-2.json"), path); err != nil {
				t.Fatal(err)
			}
		}, []string{"Second"}},
		"made unreadable": {func(t *testing.T, directory string) {
			makeUnreadable(t, filepath.Join(directory, "1000-1.json"))
		}, []string{"Second"}},
		"unchanged": {func(*testing.T, string) {}, []string{"First", "Second"}},
	} {
		t.Run(name, func(t *testing.T) {
			directory := t.TempDir()
			writeSnapshot(t, directory, "1000-1.json", "First", old)
			writeSnapshot(t, directory, "1001-2.json", "Second", old)
			settleDirectory(t, directory, old)
			var cache notificationCache
			cache.load(directory, uid, time.Now())
			if !cache.valid {
				t.Fatal("settled directory was not remembered")
			}
			test.change(t, directory)
			got := cache.load(directory, uid, time.Now())
			if !reflect.DeepEqual(titles(got), test.want) {
				t.Fatalf("after change: %v, want %v", titles(got), test.want)
			}
			if fresh := loadDesktopNotifications(directory, uid); !reflect.DeepEqual(got, fresh) {
				t.Fatalf("cache %#v differs from a fresh load %#v", got, fresh)
			}
		})
	}
}

func TestNotificationCacheDoesNotRememberARecentlyModifiedDirectory(t *testing.T) {
	directory := t.TempDir()
	uid := uint32(os.Getuid())
	now := time.Now()
	writeSnapshot(t, directory, "1000-1.json", "First", now.Add(-time.Hour))
	writeSnapshot(t, directory, "1001-2.json", "Second", now.Add(-time.Second))
	settleDirectory(t, directory, now.Add(-time.Hour))
	var cache notificationCache
	cache.load(directory, uid, now)
	if cache.valid {
		t.Fatal("a snapshot written a second ago was remembered")
	}
	cache.load(directory, uid, now.Add(notificationSettleTime))
	if !cache.valid {
		t.Fatal("a settled directory was not remembered")
	}
}

func TestNotificationCacheIsPerDirectoryAndUser(t *testing.T) {
	uid := uint32(os.Getuid())
	old := time.Now().Add(-time.Hour)
	first, second := t.TempDir(), t.TempDir()
	writeSnapshot(t, first, "1000-1.json", "First", old)
	writeSnapshot(t, second, "1000-1.json", "Other", old)
	settleDirectory(t, first, old)
	settleDirectory(t, second, old)
	var cache notificationCache
	cache.load(first, uid, time.Now())
	if got := titles(cache.load(second, uid, time.Now())); !reflect.DeepEqual(got, []string{"Other"}) {
		t.Fatalf("another directory answered %v", got)
	}
	if got := titles(cache.load(second, uid+1, time.Now())); len(got) != 0 {
		t.Fatalf("another user received %v", got)
	}
}

func TestNotificationCacheReportsAMissingDirectoryAndRecovers(t *testing.T) {
	uid := uint32(os.Getuid())
	directory := filepath.Join(t.TempDir(), "notifications")
	var cache notificationCache
	missing := cache.load(directory, uid, time.Now())
	if want := loadDesktopNotifications(directory, uid); !reflect.DeepEqual(missing, want) || missing.Success {
		t.Fatalf("missing directory = %#v, want %#v", missing, want)
	}
	if err := os.Mkdir(directory, 0700); err != nil {
		t.Fatal(err)
	}
	writeSnapshot(t, directory, "1000-1.json", "First", time.Now().Add(-time.Hour))
	if got := titles(cache.load(directory, uid, time.Now())); !reflect.DeepEqual(got, []string{"First"}) {
		t.Fatalf("recovered directory = %v", got)
	}
}

func TestNotificationCacheCallersCannotChangeTheRememberedBatch(t *testing.T) {
	directory := t.TempDir()
	uid := uint32(os.Getuid())
	old := time.Now().Add(-time.Hour)
	writeSnapshot(t, directory, "1000-1.json", "First", old)
	settleDirectory(t, directory, old)
	var cache notificationCache
	cache.load(directory, uid, time.Now()).Notifications[0].Title = "changed by the first caller"
	cache.load(directory, uid, time.Now()).Notifications[0].Title = "changed by the second caller"
	if got := titles(cache.load(directory, uid, time.Now())); !reflect.DeepEqual(got, []string{"First"}) {
		t.Fatalf("remembered batch = %v", got)
	}
}
