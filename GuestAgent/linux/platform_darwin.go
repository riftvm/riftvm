//go:build darwin

package main

import (
	"errors"
	"os"
)

func listenVSock(uint32) (int, error) { return -1, errors.New("AF_VSOCK is Linux-only") }
func acceptSocket(int) (int, error)   { return -1, errors.New("AF_VSOCK is Linux-only") }
func closeSocket(int)                 {}

type fdStream struct{ fd int }

func (fdStream) Shutdown() error { return nil }

func (fdStream) Read([]byte) (int, error)  { return 0, errors.New("AF_VSOCK is Linux-only") }
func (fdStream) Write([]byte) (int, error) { return 0, errors.New("AF_VSOCK is Linux-only") }
func power(string)                         {}

type unavailableInput struct{}

func newGuestInput() guestInput                         { return unavailableInput{} }
func inputDiagnostics() string                          { return "RiftVM input unavailable" }
func (unavailableInput) Available() bool                { return false }
func (unavailableInput) AbsolutePointerAvailable() bool { return false }
func (unavailableInput) Write([]inputEvent) error       { return errors.New("uinput is Linux-only") }
func (unavailableInput) Close() error                   { return nil }

// guestSystemAccess describes a host without a Linux desktop; the Agent is
// built here only to run its tests.
func guestSystemAccess() systemAccess {
	return systemAccess{
		processes:          func() []processInfo { return nil },
		readFile:           os.ReadFile,
		descriptorTargets:  func(string) []string { return nil },
		hyprlandSignatures: func(...string) []string { return nil },
		activeSessionUIDs:  func() map[uint32]bool { return nil },
		run:                func(desktopCommand) ([]byte, error) { return nil, errors.New("desktop commands are Linux-only") },
		omarchyShell:       func() string { return "" },
		inputDiagnostics:   inputDiagnostics,
	}
}
