//go:build linux

package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"sync"
	"syscall"
	"time"
)

type clipboardSessionRequest struct {
	Operation string `json:"operation"`
	clipboardRequest
}

var clipboardOwner = struct {
	sync.Mutex
	command *exec.Cmd
	done    chan struct{}
}{}

var clipboardPublication sync.Mutex

const (
	sessionClipboardCopyExecutable  = "/usr/bin/wl-copy"
	sessionClipboardPasteExecutable = "/usr/bin/wl-paste"
)

func startClipboardSessionServer(uid uint32) (*net.UnixListener, string, error) {
	runtimeDirectory := os.Getenv("XDG_RUNTIME_DIR")
	expected := filepath.Join("/run/user", strconv.FormatUint(uint64(uid), 10))
	if runtimeDirectory != expected {
		return nil, "", errors.New("invalid XDG_RUNTIME_DIR for session clipboard")
	}
	socketPath := desktopSessionSocketPath(uid)
	_ = os.Remove(socketPath)
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: socketPath, Net: "unix"})
	if err != nil {
		return nil, "", err
	}
	if err := os.Chmod(socketPath, 0600); err != nil {
		listener.Close()
		return nil, "", err
	}
	go func() {
		for {
			connection, err := listener.AcceptUnix()
			if err != nil {
				return
			}
			go serveClipboardSession(connection)
		}
	}()
	return listener, socketPath, nil
}

func serveClipboardSession(connection *net.UnixConn) {
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(15 * time.Second))
	data, err := bufio.NewReader(io.LimitReader(connection, 8193)).ReadBytes('\n')
	if err != nil || len(data) > 8192 {
		return
	}
	var request clipboardSessionRequest
	if json.Unmarshal(data, &request) != nil {
		return
	}
	if request.Operation == "desktopNotifications" {
		encoded, _ := json.Marshal(notificationSessionResponse())
		_, _ = connection.Write(append(encoded, '\n'))
		return
	}
	result := executeClipboardSessionRequest(request)
	encoded, _ := json.Marshal(result)
	_, _ = connection.Write(append(encoded, '\n'))
}

func executeClipboardSessionRequest(request clipboardSessionRequest) clipboardResult {
	path, err := validateClipboardRequest(request.clipboardRequest)
	if err != nil {
		return clipboardResult{Message: err.Error()}
	}
	switch request.Operation {
	case "clipboardSet":
		return setSessionClipboard(path, request.clipboardRequest)
	case "clipboardGet":
		return getSessionClipboard(path, request.clipboardRequest)
	default:
		return clipboardResult{Message: "unsupported session clipboard operation"}
	}
}

func setSessionClipboard(path string, request clipboardRequest) clipboardResult {
	// Re-open beneath / with openat2(RESOLVE_NO_SYMLINKS) on the production
	// architecture. Lexical validation alone is not enough because the shared
	// staging directory is writable by the desktop user.
	file, err := secureOpenGuestFile(path)
	if err != nil {
		return clipboardResult{Message: err.Error()}
	}
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || uint64(info.Size()) > maximumClipboardBytes {
		file.Close()
		return clipboardResult{Message: "clipboard staging input is invalid"}
	}
	payload, byteCount, digestText, err := readClipboardPayload(file, maximumClipboardBytes)
	closeError := file.Close()
	if err != nil || closeError != nil || byteCount != request.ByteCount || byteCount > maximumClipboardBytes {
		return clipboardResult{Message: "clipboard staging size mismatch"}
	}
	if request.SHA256 != digestText {
		return clipboardResult{Message: "clipboard staging digest mismatch"}
	}
	// Replacing a Wayland data-control source is ordered. Wait for the old
	// wl-copy process to finish its compositor teardown before registering the
	// next source; otherwise the late teardown can clear a selection which the
	// new owner has already published and verified.
	clipboardPublication.Lock()
	defer clipboardPublication.Unlock()
	stopSessionClipboardOwner()
	command, err := startVerifiedClipboardOwner(
		payload,
		clipboardReadBack{sha256: digestText, byteCount: byteCount},
		request.MIMEType,
		func(payload []byte, mimeType string) *exec.Cmd {
			command := exec.Command(sessionClipboardCopyExecutable, clipboardCopyArguments(mimeType)...)
			// An io.Reader makes os/exec feed the distribution-matched wl-copy
			// through an OS pipe. A regular-file stdin can fail with EPIPE in the
			// Omarchy data-control session, while mixing the separately built Rust
			// owner with the distribution wl-paste delays cross-client retrieval.
			command.Stdin = bytes.NewReader(payload)
			command.Stderr = os.Stderr
			return command
		},
		readSessionClipboardDigest,
		time.Sleep,
	)
	if err != nil {
		return clipboardResult{Message: err.Error()}
	}
	done := make(chan struct{})
	clipboardOwner.Lock()
	clipboardOwner.command = command
	clipboardOwner.done = done
	clipboardOwner.Unlock()
	go func() {
		_ = command.Wait()
		close(done)
		clipboardOwner.Lock()
		if clipboardOwner.command == command {
			clipboardOwner.command = nil
			clipboardOwner.done = nil
		}
		clipboardOwner.Unlock()
	}()
	return clipboardResult{Success: true, Message: "Guest clipboard updated.", ByteCount: byteCount, SHA256: digestText}
}

func clipboardCopyArguments(mimeType string) []string {
	arguments := []string{"--foreground"}
	if mimeType != clipboardTextMIME {
		arguments = append(arguments, "--type", mimeType)
	}
	return arguments
}

func stopSessionClipboardOwner() {
	clipboardOwner.Lock()
	command := clipboardOwner.command
	done := clipboardOwner.done
	clipboardOwner.command = nil
	clipboardOwner.done = nil
	clipboardOwner.Unlock()
	if command == nil {
		return
	}
	if command.Process != nil {
		_ = command.Process.Kill()
	}
	if done != nil {
		<-done
	}
}

// readSessionClipboardDigest reads the selection back through Wayland and
// hashes it while it streams, so verifying a large item never holds a second
// copy of it.
func readSessionClipboardDigest(mimeType string) (clipboardReadBack, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, sessionClipboardPasteExecutable, clipboardPasteArguments(mimeType)...)
	hasher := sha256.New()
	writer := &clipboardCountingWriter{writer: hasher, limit: maximumClipboardBytes}
	command.Stdout = writer
	command.Stderr = io.Discard
	if err := command.Run(); err != nil {
		return clipboardReadBack{}, err
	}
	if writer.byteCount > maximumClipboardBytes {
		return clipboardReadBack{}, errors.New("clipboard readback exceeds limit")
	}
	return clipboardReadBack{sha256: hex.EncodeToString(hasher.Sum(nil)), byteCount: writer.byteCount}, nil
}

func clipboardPasteArguments(mimeType string) []string {
	arguments := []string{"--type", mimeType}
	if mimeType == clipboardTextMIME {
		arguments = append(arguments, "--no-newline")
	}
	return arguments
}

func readClipboardPayload(reader io.Reader, limit uint64) ([]byte, uint64, string, error) {
	payload, err := io.ReadAll(io.LimitReader(reader, int64(limit+1)))
	byteCount := uint64(len(payload))
	digest := sha256.Sum256(payload)
	return payload, byteCount, hex.EncodeToString(digest[:]), err
}

func getSessionClipboard(path string, request clipboardRequest) clipboardResult {
	// One budget covers the capture, including the second read of a large
	// selection that turned out to have changed.
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	capture := clipboardCapture{
		paste: func(mimeType string, output io.Writer) error {
			command := exec.CommandContext(ctx, sessionClipboardPasteExecutable, clipboardPasteArguments(mimeType)...)
			command.Stdout = output
			command.Stderr = io.Discard
			return command.Run()
		},
		createStaging: createClipboardStaging,
	}
	return capture.get(path, request)
}

func proxyClipboardRequest(operation string, payload []byte) clipboardResult {
	var request clipboardRequest
	if err := json.Unmarshal(payload, &request); err != nil {
		return clipboardResult{Message: "invalid clipboard request"}
	}
	required := "clipboard-agent-text-v1"
	if request.MIMEType == clipboardImageMIME {
		required = "clipboard-agent-image-v1"
	}
	if _, err := validateClipboardRequest(request); err != nil {
		return clipboardResult{Message: err.Error()}
	}
	session, ok := activeDesktopSession(time.Now(), required)
	if !ok {
		return clipboardResult{Message: "no clipboard-capable desktop session is active"}
	}
	if err := validateDesktopSessionSocket(session); err != nil {
		return clipboardResult{Message: "desktop clipboard session is unavailable"}
	}
	rawConnection, err := net.DialTimeout("unix", session.socketPath, 2*time.Second)
	if err != nil {
		return clipboardResult{Message: "desktop clipboard session is unavailable"}
	}
	connection, ok := rawConnection.(*net.UnixConn)
	if !ok {
		rawConnection.Close()
		return clipboardResult{Message: "desktop clipboard session is unavailable"}
	}
	defer connection.Close()
	peerUID, err := unixPeerUID(connection)
	if err != nil || peerUID != session.uid {
		return clipboardResult{Message: "desktop clipboard session identity mismatch"}
	}
	_ = connection.SetDeadline(time.Now().Add(15 * time.Second))
	encoded, _ := json.Marshal(clipboardSessionRequest{Operation: operation, clipboardRequest: request})
	if _, err := connection.Write(append(encoded, '\n')); err != nil {
		return clipboardResult{Message: err.Error()}
	}
	data, err := bufio.NewReader(io.LimitReader(connection, 8193)).ReadBytes('\n')
	if err != nil || len(data) > 8192 {
		return clipboardResult{Message: "invalid desktop clipboard response"}
	}
	var result clipboardResult
	if json.Unmarshal(data, &result) != nil {
		return clipboardResult{Message: "invalid desktop clipboard response"}
	}
	return checkedClipboardProxyResult(operation, request, result)
}

func validateDesktopSessionSocket(session registeredSession) error {
	info, err := os.Lstat(session.socketPath)
	if err != nil || info.Mode()&os.ModeSocket == 0 {
		return errors.New("desktop session socket is missing")
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != session.uid {
		return errors.New("desktop session socket owner mismatch")
	}
	return nil
}
