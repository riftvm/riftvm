//go:build linux

package main

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

func hyprlandSignatures(paths ...string) []string {
	seen := make(map[string]bool)
	var signatures []string
	for _, path := range paths {
		entries, _ := os.ReadDir(path)
		for _, entry := range entries {
			if !entry.IsDir() || seen[entry.Name()] {
				continue
			}
			// A stale directory is not a usable Hyprland session.  Both current
			// and older Hyprland releases expose at least one IPC socket here.
			matches, _ := filepath.Glob(filepath.Join(path, entry.Name(), ".socket*.sock"))
			if len(matches) == 0 {
				continue
			}
			seen[entry.Name()] = true
			signatures = append(signatures, entry.Name())
		}
	}
	sort.Strings(signatures)
	return signatures
}

// guestSystemAccess reads the running guest.
func guestSystemAccess() systemAccess {
	return systemAccess{
		processes:          scanProcesses,
		readFile:           os.ReadFile,
		descriptorTargets:  processDescriptorTargets,
		hyprlandSignatures: hyprlandSignatures,
		activeSessionUIDs:  func() map[uint32]bool { return activeSessionUIDs(time.Now()) },
		run:                runDesktopCommand,
		omarchyShell:       omarchyShellExecutable,
		inputDiagnostics:   inputDiagnostics,
	}
}

func scanProcesses() []processInfo {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return nil
	}
	var processes []processInfo
	for _, entry := range entries {
		pid := entry.Name()
		if !entry.IsDir() {
			continue
		}
		if _, err := strconv.Atoi(pid); err != nil {
			continue
		}
		processes = append(processes, processInfo{
			pid:  pid,
			comm: strings.ToLower(readTrimmed("/proc/" + pid + "/comm")),
		})
	}
	return processes
}

func processDescriptorTargets(pid string) []string {
	fds, _ := os.ReadDir("/proc/" + pid + "/fd")
	var targets []string
	for _, fd := range fds {
		target, err := os.Readlink("/proc/" + pid + "/fd/" + fd.Name())
		if err != nil {
			continue
		}
		targets = append(targets, target)
	}
	return targets
}

func runDesktopCommand(request desktopCommand) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), request.timeout)
	defer cancel()
	command := exec.CommandContext(ctx, request.name, request.arguments...)
	command.Env = append(os.Environ(), request.environment...)
	command.SysProcAttr = &syscall.SysProcAttr{Credential: &syscall.Credential{Uid: request.session.uid, Gid: request.session.gid}}
	if request.combined {
		return command.CombinedOutput()
	}
	return command.Output()
}

func omarchyShellExecutable() string {
	executable := "/usr/share/omarchy/bin/omarchy-shell"
	if info, err := os.Stat(executable); err != nil || info.IsDir() || info.Mode()&0111 == 0 {
		executable, _ = exec.LookPath("omarchy-shell")
	}
	return executable
}

type sockaddrVM struct {
	Family   uint16
	Reserved uint16
	Port     uint32
	CID      uint32
	Flags    uint8
	Zero     [3]uint8
}

// AF_VSOCK is part of Linux's UAPI, but the frozen syscall package does not
// expose it on every architecture/toolchain combination used by CI.
const addressFamilyVSock = 40

func listenVSock(port uint32) (int, error) {
	fd, err := syscall.Socket(addressFamilyVSock, syscall.SOCK_STREAM|syscall.SOCK_CLOEXEC, 0)
	if err != nil {
		return -1, err
	}
	address := sockaddrVM{Family: addressFamilyVSock, Port: port, CID: vmaddrCIDAny}
	_, _, errno := syscall.Syscall(syscall.SYS_BIND, uintptr(fd), uintptr(unsafe.Pointer(&address)), unsafe.Sizeof(address))
	if errno != 0 {
		syscall.Close(fd)
		return -1, errno
	}
	if err := syscall.Listen(fd, 4); err != nil {
		syscall.Close(fd)
		return -1, err
	}
	return fd, nil
}

func acceptSocket(fd int) (int, error) {
	for {
		// syscall.Accept asks the Go syscall package to decode the peer
		// sockaddr. Its legacy Linux decoder does not understand AF_VSOCK and
		// returns EAFNOSUPPORT after the kernel has accepted the connection.
		// The agent does not use the peer address, so omit it at the syscall
		// boundary and retain close-on-exec atomically.
		connection, _, errno := syscall.Syscall6(
			syscall.SYS_ACCEPT4, uintptr(fd), 0, 0, syscall.SOCK_CLOEXEC, 0, 0,
		)
		if errno == syscall.EINTR {
			continue
		}
		if errno != 0 {
			return -1, errno
		}
		return int(connection), nil
	}
}

func closeSocket(fd int) { _ = syscall.Close(fd) }

type fdStream struct{ fd int }

func (stream fdStream) Shutdown() error { return syscall.Shutdown(stream.fd, syscall.SHUT_RDWR) }

func (stream fdStream) Read(p []byte) (int, error) { return syscall.Read(stream.fd, p) }
func (stream fdStream) Write(p []byte) (int, error) {
	written := 0
	for written < len(p) {
		count, err := syscall.Write(stream.fd, p[written:])
		if err == syscall.EINTR {
			continue
		}
		if err != nil {
			return written, err
		}
		if count == 0 {
			return written, syscall.EIO
		}
		written += count
	}
	return written, nil
}

func power(operation string) {
	time.Sleep(250 * time.Millisecond)
	argument := "poweroff"
	if operation == "restart" {
		argument = "reboot"
	}
	if err := exec.Command("systemctl", argument).Run(); err == nil {
		return
	}
	_ = exec.Command("/sbin/" + argument).Run()
}
