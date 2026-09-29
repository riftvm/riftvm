//go:build linux

package main

import (
	"bytes"
	"os"
	"strings"
	"testing"
)

func TestRelativePointerDoesNotAdvertiseUnemittedHighResolutionWheel(t *testing.T) {
	for _, code := range relativePointerCodes {
		if code == 11 || code == 12 {
			t.Fatalf("relative pointer advertises high-resolution wheel code %d without emitting it", code)
		}
	}
	foundLegacyWheel := false
	for _, code := range relativePointerCodes {
		if code == 8 {
			foundLegacyWheel = true
		}
	}
	if !foundLegacyWheel {
		t.Fatal("relative pointer no longer advertises REL_WHEEL")
	}
}

// The device must hand each descriptor exactly the bytes the released Agent
// produced with one write(2) per event.
func TestUinputDeviceWritesUnchangedBytesToEachDescriptor(t *testing.T) {
	open := func(name string) *os.File {
		file, err := os.CreateTemp(t.TempDir(), name)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { file.Close() })
		return file
	}
	device := &uinputDevice{
		keyboardFile: open("keyboard"), relativeFile: open("relative"), absoluteFile: open("absolute"),
		lastPointer: targetAbsolute,
	}
	events := inputPathCases["keyboard between pointer reports"]
	if err := device.Write(events); err != nil {
		t.Fatal(err)
	}
	legacy := &recordingDevices{}
	legacyPointer := targetAbsolute
	if err := legacyWriteInputReports(events, &legacyPointer, legacy); err != nil {
		t.Fatal(err)
	}
	want := map[inputTarget][]byte{}
	for _, write := range legacy.writes {
		want[write.target] = append(want[write.target], write.data...)
	}
	for target, file := range map[inputTarget]*os.File{
		targetKeyboard: device.keyboardFile, targetRelative: device.relativeFile, targetAbsolute: device.absoluteFile,
	} {
		written, err := os.ReadFile(file.Name())
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(written, want[target]) {
			t.Fatalf("device %d received %v, want %v", target, written, want[target])
		}
	}
	if device.lastPointer != legacyPointer {
		t.Fatalf("last pointer = %d, want %d", device.lastPointer, legacyPointer)
	}
	if diagnostics := inputDiagnostics(); !strings.HasSuffix(diagnostics, "last=["+legacyFormatInputReport(events)+"]") {
		t.Fatalf("diagnostics = %q", diagnostics)
	}
}

func TestUinputDeviceReportsAMissingDevice(t *testing.T) {
	device := &uinputDevice{}
	if err := device.Write([]inputEvent{{Type: 1, Code: 30, Value: 1}, {Type: 0}}); err == nil {
		t.Fatal("write to a missing device succeeded")
	}
}
