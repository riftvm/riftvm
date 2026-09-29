//go:build linux

package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"os/exec"
	"testing"
)

func TestReadClipboardPayloadRetainsAuthenticatedBytes(t *testing.T) {
	want := []byte("RiftVM clipboard payload\nwith unicode: 你好")
	payload, byteCount, digest, err := readClipboardPayload(bytes.NewReader(want), maximumClipboardBytes)
	if err != nil {
		t.Fatal(err)
	}
	wantDigest := sha256.Sum256(want)
	if !bytes.Equal(payload, want) || byteCount != uint64(len(want)) ||
		digest != hex.EncodeToString(wantDigest[:]) {
		t.Fatalf("payload=%q byteCount=%d digest=%s", payload, byteCount, digest)
	}
}

func TestSessionClipboardUsesDistributionMatchedCopyFrontend(t *testing.T) {
	if sessionClipboardCopyExecutable != "/usr/bin/wl-copy" {
		t.Fatalf("copy executable=%q, want the distribution-matched frontend", sessionClipboardCopyExecutable)
	}
	if sessionClipboardPasteExecutable != "/usr/bin/wl-paste" {
		t.Fatalf("paste executable=%q, want the distribution-matched frontend", sessionClipboardPasteExecutable)
	}
}

func TestClipboardCopyArgumentsLetTextFrontendAdvertiseNativeAliases(t *testing.T) {
	arguments := clipboardCopyArguments(clipboardTextMIME)
	if len(arguments) != 1 || arguments[0] != "--foreground" {
		t.Fatalf("text arguments=%v", arguments)
	}
	arguments = clipboardCopyArguments(clipboardImageMIME)
	if len(arguments) != 3 || arguments[0] != "--foreground" ||
		arguments[1] != "--type" || arguments[2] != clipboardImageMIME {
		t.Fatalf("image arguments=%v", arguments)
	}
}

func TestClipboardPasteArgumentsKeepTextWithoutATrailingNewline(t *testing.T) {
	arguments := clipboardPasteArguments(clipboardTextMIME)
	if len(arguments) != 3 || arguments[0] != "--type" || arguments[1] != clipboardTextMIME || arguments[2] != "--no-newline" {
		t.Fatalf("text arguments=%v", arguments)
	}
	arguments = clipboardPasteArguments(clipboardImageMIME)
	if len(arguments) != 2 || arguments[0] != "--type" || arguments[1] != clipboardImageMIME {
		t.Fatalf("image arguments=%v", arguments)
	}
}

func TestStopSessionClipboardOwnerWaitsForProcessExit(t *testing.T) {
	command := exec.Command("sleep", "30")
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	clipboardOwner.Lock()
	clipboardOwner.command = command
	clipboardOwner.done = done
	clipboardOwner.Unlock()
	go func() {
		_ = command.Wait()
		close(done)
	}()

	stopSessionClipboardOwner()
	select {
	case <-done:
	default:
		t.Fatal("clipboard owner stop returned before process exit")
	}
	if command.ProcessState == nil {
		t.Fatal("clipboard owner process was not reaped")
	}
	clipboardOwner.Lock()
	defer clipboardOwner.Unlock()
	if clipboardOwner.command != nil || clipboardOwner.done != nil {
		t.Fatal("stopped clipboard owner remained registered")
	}
}

func TestReadClipboardPayloadStopsOneBytePastLimit(t *testing.T) {
	reader := bytes.NewReader(make([]byte, 6))
	payload, byteCount, _, err := readClipboardPayload(reader, 4)
	if err != nil {
		t.Fatal(err)
	}
	if byteCount != 5 || len(payload) != 5 {
		t.Fatalf("payload bytes=%d count=%d", len(payload), byteCount)
	}
}

func TestClipboardCountingWriterStopsOneBytePastLimit(t *testing.T) {
	var output bytes.Buffer
	writer := &clipboardCountingWriter{writer: &output, limit: 4}

	written, err := writer.Write([]byte("abcdef"))
	if err == nil {
		t.Fatal("oversized write unexpectedly succeeded")
	}
	if written != 5 || writer.byteCount != 5 || output.String() != "abcde" {
		t.Fatalf("written=%d count=%d output=%q", written, writer.byteCount, output.String())
	}
	if written, err = writer.Write([]byte("z")); err == nil || written != 0 {
		t.Fatalf("second write = (%d, %v), want (0, error)", written, err)
	}
}
