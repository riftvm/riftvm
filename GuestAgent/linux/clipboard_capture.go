package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
)

// clipboardUnchangedBufferBytes bounds the memory that holds a selection while
// it is compared with the digest the Host already knows. A changed selection
// of at most this size is staged from that memory; a larger one is read from
// Wayland a second time, straight into the staging file.
const clipboardUnchangedBufferBytes = 1024 * 1024

const clipboardUnchangedMessage = "Guest clipboard unchanged."

// knownClipboardDigest returns the digest of the selection the Host already
// holds, or "" when the request names none. The field is optional and was
// added after protocol v1 shipped: a Host that does not know it never sends
// it, and a value that is not a lowercase SHA-256 is ignored rather than
// rejected, so the request is served exactly as one without the field.
func knownClipboardDigest(request clipboardRequest) string {
	if !isLowerHexSHA256(request.KnownSHA256) {
		return ""
	}
	return request.KnownSHA256
}

// clipboardCapture reads the desktop selection for the Host.
type clipboardCapture struct {
	// paste streams the current selection of a MIME type into output.
	paste func(mimeType string, output io.Writer) error
	// createStaging creates the staging file that is committed to path.
	createStaging func(path string) (io.WriteCloser, secureUploadTarget, error)
}

func createClipboardStaging(path string) (io.WriteCloser, secureUploadTarget, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return nil, nil, clipboardStagingError{message: err.Error()}
	}
	// Create an unguessable file and retain an open descriptor for the parent.
	// Committing through secureUploadTarget prevents symlink traversal and
	// refuses to replace a destination that appeared during capture.
	file, target, err := secureCreateUpload(path)
	if err != nil {
		return nil, nil, clipboardStagingError{message: "could not create clipboard staging output: " + err.Error()}
	}
	return file, target, nil
}

// clipboardStagingError carries the message reported to the Host.
type clipboardStagingError struct{ message string }

func (err clipboardStagingError) Error() string { return err.message }

// clipboardStaging creates its file when the first byte arrives. A selection
// that offers nothing for the requested MIME type, the normal answer to the
// image probe while text is copied, then never touches the shared folder.
type clipboardStaging struct {
	path    string
	create  func(path string) (io.WriteCloser, secureUploadTarget, error)
	file    io.WriteCloser
	target  secureUploadTarget
	failure error
	closed  bool
}

func (staging *clipboardStaging) open() error {
	if staging.failure != nil {
		return staging.failure
	}
	if staging.file != nil {
		return nil
	}
	staging.file, staging.target, staging.failure = staging.create(staging.path)
	return staging.failure
}

func (staging *clipboardStaging) Write(data []byte) (int, error) {
	if err := staging.open(); err != nil {
		return 0, err
	}
	return staging.file.Write(data)
}

func (staging *clipboardStaging) close() error {
	if staging.file == nil || staging.closed {
		return nil
	}
	staging.closed = true
	return staging.file.Close()
}

// discard removes whatever was staged and not committed.
func (staging *clipboardStaging) discard() {
	_ = staging.close()
	if staging.target != nil {
		staging.target.cleanup()
		staging.target = nil
	}
}

func (capture clipboardCapture) get(path string, request clipboardRequest) clipboardResult {
	known := knownClipboardDigest(request)
	if known == "" {
		return capture.stage(path, request, nil)
	}
	// Hash the selection before anything is written to the shared folder. The
	// Host polls once per second and the selection is usually the one it
	// already holds.
	hasher := sha256.New()
	memory := &boundedBuffer{limit: clipboardUnchangedBufferBytes}
	counter := &clipboardCountingWriter{
		writer: io.MultiWriter(hasher, memory),
		limit:  maximumClipboardBytes,
	}
	err := capture.paste(request.MIMEType, counter)
	if counter.byteCount > maximumClipboardBytes {
		return clipboardResult{Message: "clipboard output is invalid"}
	}
	if err != nil {
		return clipboardResult{Message: "could not read the Wayland clipboard"}
	}
	if digest := hex.EncodeToString(hasher.Sum(nil)); digest == known {
		return clipboardResult{
			Success: true, Message: clipboardUnchangedMessage,
			ByteCount: counter.byteCount, SHA256: digest, Unchanged: true,
		}
	}
	if memory.overflowed {
		return capture.stage(path, request, nil)
	}
	return capture.stage(path, request, memory.data.Bytes())
}

// stage writes the selection to the staging file and commits it. content is
// the selection when it was already read; otherwise it is read from Wayland.
func (capture clipboardCapture) stage(path string, request clipboardRequest, content []byte) clipboardResult {
	staging := &clipboardStaging{path: path, create: capture.createStaging}
	committed := false
	defer func() {
		if !committed {
			staging.discard()
		}
	}()
	hasher := sha256.New()
	counter := &clipboardCountingWriter{
		writer: io.MultiWriter(staging, hasher),
		limit:  maximumClipboardBytes,
	}
	var err error
	if content != nil {
		_, err = counter.Write(content)
	} else {
		err = capture.paste(request.MIMEType, counter)
	}
	if err == nil {
		// An empty selection is still a selection: stage the empty file.
		err = staging.open()
	}
	closeError := staging.close()
	if staging.failure != nil {
		var stagingError clipboardStagingError
		if errors.As(staging.failure, &stagingError) {
			return clipboardResult{Message: stagingError.message}
		}
		return clipboardResult{Message: "could not create clipboard staging output: " + staging.failure.Error()}
	}
	if counter.byteCount > maximumClipboardBytes {
		return clipboardResult{Message: "clipboard output is invalid"}
	}
	if err != nil || closeError != nil {
		return clipboardResult{Message: "could not read the Wayland clipboard"}
	}
	if err := staging.target.commit(false); err != nil {
		return clipboardResult{Message: "could not commit clipboard staging output: " + err.Error()}
	}
	committed = true
	return clipboardResult{
		Success: true, Message: "Guest clipboard captured.",
		ByteCount: counter.byteCount, SHA256: hex.EncodeToString(hasher.Sum(nil)),
	}
}

// boundedBuffer keeps what is written to it until that exceeds limit, then
// keeps nothing. It never fails, so it cannot interrupt the hash beside it.
type boundedBuffer struct {
	data       bytes.Buffer
	limit      int
	overflowed bool
}

func (buffer *boundedBuffer) Write(data []byte) (int, error) {
	if !buffer.overflowed && buffer.data.Len()+len(data) > buffer.limit {
		buffer.overflowed = true
		buffer.data = bytes.Buffer{}
	}
	if !buffer.overflowed {
		buffer.data.Write(data)
	}
	return len(data), nil
}

type clipboardCountingWriter struct {
	writer    io.Writer
	byteCount uint64
	limit     uint64
}

func (writer *clipboardCountingWriter) Write(data []byte) (int, error) {
	if writer.byteCount >= writer.limit+1 {
		return 0, errors.New("clipboard output exceeds limit")
	}
	remaining := writer.limit + 1 - writer.byteCount
	if uint64(len(data)) > remaining {
		data = data[:remaining]
	}
	written, err := writer.writer.Write(data)
	writer.byteCount += uint64(written)
	if err == nil && writer.byteCount > writer.limit {
		err = errors.New("clipboard output exceeds limit")
	}
	return written, err
}

// checkedClipboardProxyResult is what the system Agent forwards to the Host.
// Only a capture that named a known digest can be answered with "unchanged",
// and only with that digest; anything else from the Session Agent is not a
// valid answer.
func checkedClipboardProxyResult(operation string, request clipboardRequest, result clipboardResult) clipboardResult {
	if !result.Unchanged {
		return result
	}
	known := knownClipboardDigest(request)
	if operation != "clipboardGet" || !result.Success || known == "" || result.SHA256 != known {
		return clipboardResult{Message: "invalid desktop clipboard response"}
	}
	return result
}
