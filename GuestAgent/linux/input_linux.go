//go:build linux

package main

import (
	"fmt"
	"io"
	"os"
	"sync"
	"sync/atomic"
	"syscall"
	"unsafe"
)

var inputReportCount atomic.Uint64
var inputDiagnosticLock sync.Mutex

// The most recent request is kept as events and rendered only when diagnostics
// are requested, so the input path never formats text.
var lastInputEvents []inputEvent

const (
	uiSetEVBit   = 0x40045564
	uiSetKeyBit  = 0x40045565
	uiSetRelBit  = 0x40045566
	uiSetAbsBit  = 0x40045567
	uiDevCreate  = 0x5501
	uiDevDestroy = 0x5502
	uiDevSetup   = 0x405c5503
	uiAbsSetup   = 0x401c5504
)

type uinputDevice struct {
	keyboardFile *os.File
	relativeFile *os.File
	absoluteFile *os.File
	writeLock    sync.Mutex
	// The pointer device that last carried motion; mouse buttons follow it.
	lastPointer inputTarget
	// Reused for the kernel representation of one report; guarded by writeLock.
	scratch [maxInputEvents * inputEventBytes]byte
}

type uinputSetup struct {
	BusType, Vendor, Product, Version uint16
	Name                              [80]byte
	FFEffectsMax                      uint32
}

type inputAbsInfo struct {
	Value, Minimum, Maximum, Fuzz, Flat, Resolution int32
}

type uinputAbsSetup struct {
	Code    uint16
	Padding uint16
	AbsInfo inputAbsInfo
}

func newGuestInput() guestInput {
	device := &uinputDevice{
		keyboardFile: createKeyboard(),
		relativeFile: createRelativePointer(),
	}
	if device.keyboardFile == nil || device.relativeFile == nil {
		_ = device.Close()
		return &uinputDevice{}
	}
	device.absoluteFile = createAbsolutePointer()
	device.lastPointer = targetRelative
	if device.absoluteFile != nil {
		device.lastPointer = targetAbsolute
	}
	return device
}

func (device *uinputDevice) Available() bool {
	return device != nil && device.keyboardFile != nil && device.relativeFile != nil
}

func (device *uinputDevice) AbsolutePointerAvailable() bool {
	return device != nil && device.keyboardFile != nil && device.absoluteFile != nil
}

func (device *uinputDevice) Write(events []inputEvent) error {
	device.writeLock.Lock()
	defer device.writeLock.Unlock()
	if err := writeInputReports(events, &device.lastPointer, device.writer, device.scratch[:0]); err != nil {
		return err
	}
	inputReportCount.Add(1)
	inputDiagnosticLock.Lock()
	lastInputEvents = append(lastInputEvents[:0], events...)
	inputDiagnosticLock.Unlock()
	return nil
}

// writer returns the device node for target, or nil when it was not created.
func (device *uinputDevice) writer(target inputTarget) io.Writer {
	file := device.keyboardFile
	switch target {
	case targetAbsolute:
		file = device.absoluteFile
	case targetRelative:
		file = device.relativeFile
	}
	if file == nil {
		return nil
	}
	return file
}

func inputDiagnostics() string {
	inputDiagnosticLock.Lock()
	last := formatInputReport(lastInputEvents)
	inputDiagnosticLock.Unlock()
	return fmt.Sprintf("RiftVM input reports=%d last=[%s]", inputReportCount.Load(), last)
}

func (device *uinputDevice) Close() error {
	if device == nil {
		return nil
	}
	if device.absoluteFile != nil {
		_ = ioctlFile(device.absoluteFile, uiDevDestroy, 0)
		_ = device.absoluteFile.Close()
		device.absoluteFile = nil
	}
	if device.relativeFile != nil {
		_ = ioctlFile(device.relativeFile, uiDevDestroy, 0)
		_ = device.relativeFile.Close()
		device.relativeFile = nil
	}
	if device.keyboardFile != nil {
		_ = ioctlFile(device.keyboardFile, uiDevDestroy, 0)
		err := device.keyboardFile.Close()
		device.keyboardFile = nil
		return err
	}
	return nil
}

func ioctlFile(file *os.File, request, argument uintptr) error {
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, file.Fd(), request, argument)
	if errno != 0 {
		return errno
	}
	return nil
}

func createKeyboard() *os.File {
	file, err := os.OpenFile("/dev/uinput", os.O_WRONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil
	}
	fail := func() *os.File {
		_ = file.Close()
		return nil
	}
	if ioctlFile(file, uiSetEVBit, 0) != nil ||
		ioctlFile(file, uiSetEVBit, 1) != nil ||
		ioctlFile(file, uiSetEVBit, 20) != nil { // EV_REP
		return fail()
	}
	// Advertise only keys the host can actually emit. Claiming every code up to
	// 0xff made the kernel attach rfkill and power-switch handlers to what is
	// supposed to be a normal keyboard. Hyprland opened the device, but libinput
	// then treated its capabilities as a non-standard composite device.
	for _, code := range keyboardKeyCodes {
		if ioctlFile(file, uiSetKeyBit, code) != nil {
			return fail()
		}
	}
	setup := uinputSetup{BusType: 0x03, Vendor: 0x1d6b, Product: 0x0104, Version: 4}
	copy(setup.Name[:], "RiftVM Keyboard")
	if ioctlFile(file, uiDevSetup, uintptr(unsafe.Pointer(&setup))) != nil ||
		ioctlFile(file, uiDevCreate, 0) != nil {
		return fail()
	}
	return file
}

var keyboardKeyCodes = []uintptr{
	1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
	17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
	33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48,
	49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64,
	65, 66, 67, 68, 69, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81,
	82, 83, 87, 88, 96, 97, 98, 100, 102, 103, 104, 105, 106, 107,
	108, 109, 111, 117, 125, 126, 183, 184, 185, 186, 187, 188, 189, 190,
}

func createRelativePointer() *os.File {
	file, err := os.OpenFile("/dev/uinput", os.O_WRONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil
	}
	fail := func() *os.File {
		_ = file.Close()
		return nil
	}
	if ioctlFile(file, uiSetEVBit, 0) != nil ||
		ioctlFile(file, uiSetEVBit, 1) != nil ||
		ioctlFile(file, uiSetEVBit, 2) != nil {
		return fail()
	}
	// Advertise only the wheel protocol the host actually emits. A device that
	// exposes REL_WHEEL_HI_RES must send a matching high-resolution event (120
	// units per detent) alongside REL_WHEEL. Advertising codes 11/12 while only
	// writing the legacy code makes libinput wait for the missing high-resolution
	// axis and Wayland applications never receive a scroll event.
	for _, code := range relativePointerCodes {
		if ioctlFile(file, uiSetRelBit, code) != nil {
			return fail()
		}
	}
	for _, code := range []uintptr{272, 273, 274} {
		if ioctlFile(file, uiSetKeyBit, code) != nil {
			return fail()
		}
	}
	setup := uinputSetup{BusType: 0x06, Vendor: 0x1d6b, Product: 0x0106, Version: 1}
	copy(setup.Name[:], "RiftVM Relative Pointer")
	if ioctlFile(file, uiDevSetup, uintptr(unsafe.Pointer(&setup))) != nil ||
		ioctlFile(file, uiDevCreate, 0) != nil {
		return fail()
	}
	return file
}

var relativePointerCodes = []uintptr{0, 1, 6, 8}

func createAbsolutePointer() *os.File {
	file, err := os.OpenFile("/dev/uinput", os.O_WRONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil
	}
	fail := func() *os.File {
		_ = file.Close()
		return nil
	}
	if ioctlFile(file, uiSetEVBit, 0) != nil ||
		ioctlFile(file, uiSetEVBit, 1) != nil ||
		ioctlFile(file, uiSetEVBit, 3) != nil {
		return fail()
	}
	for _, code := range []uintptr{272, 273, 274} {
		if ioctlFile(file, uiSetKeyBit, code) != nil {
			return fail()
		}
	}
	if ioctlFile(file, uiSetAbsBit, 0) != nil || ioctlFile(file, uiSetAbsBit, 1) != nil {
		return fail()
	}
	x := uinputAbsSetup{Code: 0, AbsInfo: inputAbsInfo{Maximum: 32767}}
	y := uinputAbsSetup{Code: 1, AbsInfo: inputAbsInfo{Maximum: 32767}}
	if ioctlFile(file, uiAbsSetup, uintptr(unsafe.Pointer(&x))) != nil ||
		ioctlFile(file, uiAbsSetup, uintptr(unsafe.Pointer(&y))) != nil {
		return fail()
	}
	setup := uinputSetup{BusType: 0x06, Vendor: 0x1d6b, Product: 0x0105, Version: 1}
	copy(setup.Name[:], "RiftVM Absolute Pointer")
	if ioctlFile(file, uiDevSetup, uintptr(unsafe.Pointer(&setup))) != nil ||
		ioctlFile(file, uiDevCreate, 0) != nil {
		return fail()
	}
	return file
}
