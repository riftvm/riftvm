//go:build linux

package main

import (
	"bufio"
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

func desktopNotificationStateDirectory() string {
	home, err := os.UserHomeDir()
	if err != nil || !filepath.IsAbs(home) {
		return ""
	}
	return filepath.Join(home, ".local", "state", "omarchy", "notifications")
}

func desktopNotificationStateAvailable(uid uint32) bool {
	directory := desktopNotificationStateDirectory()
	info, err := os.Lstat(directory)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return false
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && stat.Uid == uid
}

func proxyDesktopNotifications() desktopNotificationBatch {
	session, ok := activeDesktopSession(time.Now(), desktopNotificationCapability)
	if !ok {
		return desktopNotificationBatch{Message: "no notification-capable desktop session is active"}
	}
	if err := validateDesktopSessionSocket(session); err != nil {
		return desktopNotificationBatch{Message: "desktop notification session is unavailable"}
	}
	rawConnection, err := net.DialTimeout("unix", session.socketPath, 2*time.Second)
	if err != nil {
		return desktopNotificationBatch{Message: "desktop notification session is unavailable"}
	}
	connection, ok := rawConnection.(*net.UnixConn)
	if !ok {
		rawConnection.Close()
		return desktopNotificationBatch{Message: "desktop notification session is unavailable"}
	}
	defer connection.Close()
	peerUID, err := unixPeerUID(connection)
	if err != nil || peerUID != session.uid {
		return desktopNotificationBatch{Message: "desktop notification session identity mismatch"}
	}
	_ = connection.SetDeadline(time.Now().Add(5 * time.Second))
	encoded, _ := json.Marshal(clipboardSessionRequest{Operation: "desktopNotifications"})
	if _, err := connection.Write(append(encoded, '\n')); err != nil {
		return desktopNotificationBatch{Message: err.Error()}
	}
	data, err := bufio.NewReader(io.LimitReader(connection, 128*1024+1)).ReadBytes('\n')
	if err != nil || len(data) > 128*1024 {
		return desktopNotificationBatch{Message: "invalid desktop notification response"}
	}
	var result desktopNotificationBatch
	if json.Unmarshal(data, &result) != nil || !result.Success || len(result.Notifications) > maximumDesktopNotifications {
		return desktopNotificationBatch{Message: "invalid desktop notification response"}
	}
	for index, value := range result.Notifications {
		validated, err := validatedDesktopNotification(value)
		if err != nil {
			return desktopNotificationBatch{Message: "invalid desktop notification response"}
		}
		result.Notifications[index] = validated
	}
	return result
}

func notificationSessionResponse() desktopNotificationBatch {
	directory := desktopNotificationStateDirectory()
	if directory == "" {
		return desktopNotificationBatch{Message: "Omarchy notification state is unavailable."}
	}
	return desktopNotificationCache.load(directory, uint32(os.Getuid()), time.Now())
}
