package main

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

type hyprlandSession struct {
	pid        string
	uid        uint32
	gid        uint32
	runtimeDir string
	signature  string
}

// processInfo is one entry of the process table: its PID and its command
// name, trimmed and lowercased.
type processInfo struct {
	pid  string
	comm string
}

// desktopCommand is a program run inside a Hyprland session with the
// credentials of the session owner.
type desktopCommand struct {
	session     hyprlandSession
	timeout     time.Duration
	name        string
	arguments   []string
	environment []string
	// combined also captures standard error, for diagnostics.
	combined bool
}

// systemAccess is everything a status report reads from the guest. Tests
// replace it to describe a guest and to count how often it is consulted.
type systemAccess struct {
	// processes scans the process table once.
	processes func() []processInfo
	readFile  func(path string) ([]byte, error)
	// descriptorTargets resolves every open descriptor of a process.
	descriptorTargets func(pid string) []string
	// hyprlandSignatures lists usable Hyprland instance directories.
	hyprlandSignatures func(paths ...string) []string
	activeSessionUIDs  func() map[uint32]bool
	run                func(command desktopCommand) ([]byte, error)
	// omarchyShell returns the omarchy-shell executable, or "" without one.
	omarchyShell     func() string
	inputDiagnostics func() string
}

// desktopProbe answers every desktop question of one status report from a
// single process-table scan, a single read of the kernel input device list,
// and a single `hyprctl -j devices` call. A heartbeat used to rescan /proc
// and rerun hyprctl for each question; the answers are unchanged.
//
// A probe describes one instant and is not safe for concurrent use: create one
// per status report.
type desktopProbe struct {
	system systemAccess

	processList   []processInfo
	processesRead bool

	sessions     []hyprlandSession
	sessionsRead bool

	activeUIDs     map[uint32]bool
	activeUIDsRead bool

	diagnostics     string
	diagnosticsRead bool

	kernelDevices      []byte
	kernelDevicesError error
	kernelDevicesRead  bool

	inputNodes map[string][]string
}

func newDesktopProbe(system systemAccess) *desktopProbe {
	return &desktopProbe{system: system, inputNodes: map[string][]string{}}
}

func (probe *desktopProbe) processes() []processInfo {
	if !probe.processesRead {
		probe.processList = probe.system.processes()
		probe.processesRead = true
	}
	return probe.processList
}

func (probe *desktopProbe) kernelInputDevices() ([]byte, error) {
	if !probe.kernelDevicesRead {
		probe.kernelDevices, probe.kernelDevicesError = probe.system.readFile("/proc/bus/input/devices")
		probe.kernelDevicesRead = true
	}
	return probe.kernelDevices, probe.kernelDevicesError
}

// openInputNodes lists the /dev/input/event* nodes a process holds open, in
// descriptor order and with repeats.
func (probe *desktopProbe) openInputNodes(pid string) []string {
	if nodes, known := probe.inputNodes[pid]; known {
		return nodes
	}
	var nodes []string
	for _, target := range probe.system.descriptorTargets(pid) {
		if strings.HasPrefix(target, "/dev/input/event") {
			nodes = append(nodes, strings.TrimPrefix(target, "/dev/input/"))
		}
	}
	probe.inputNodes[pid] = nodes
	return nodes
}

func parseHyprlandEnvironment(data []byte) (string, string) {
	var runtimeDir, signature string
	for _, item := range strings.Split(string(data), "\x00") {
		switch {
		case strings.HasPrefix(item, "XDG_RUNTIME_DIR="):
			runtimeDir = strings.TrimPrefix(item, "XDG_RUNTIME_DIR=")
		case strings.HasPrefix(item, "HYPRLAND_INSTANCE_SIGNATURE="):
			signature = strings.TrimPrefix(item, "HYPRLAND_INSTANCE_SIGNATURE=")
		}
	}
	return runtimeDir, signature
}

func parseProcessCredentials(data []byte) (uint32, uint32, bool) {
	var uid, gid uint64
	var haveUID, haveGID bool
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		var err error
		switch fields[0] {
		case "Uid:":
			uid, err = strconv.ParseUint(fields[1], 10, 32)
			haveUID = err == nil
		case "Gid:":
			gid, err = strconv.ParseUint(fields[1], 10, 32)
			haveGID = err == nil
		}
	}
	return uint32(uid), uint32(gid), haveUID && haveGID
}

// hyprlandSessions finds every Hyprland process, including the login
// greeter's compositor.
func (probe *desktopProbe) hyprlandSessions() []hyprlandSession {
	if probe.sessionsRead {
		return probe.sessions
	}
	probe.sessionsRead = true
	for _, process := range probe.processes() {
		if !strings.Contains(process.comm, "hyprland") {
			continue
		}
		pid := process.pid
		status, _ := probe.system.readFile("/proc/" + pid + "/status")
		uid, gid, ok := parseProcessCredentials(status)
		if !ok {
			continue
		}
		environment, _ := probe.system.readFile("/proc/" + pid + "/environ")
		runtimeDir, signature := parseHyprlandEnvironment(environment)
		if runtimeDir == "" {
			runtimeDir = "/run/user/" + strconv.FormatUint(uint64(uid), 10)
		}
		if signature == "" {
			procRoot := "/proc/" + pid + "/root"
			signatures := probe.system.hyprlandSignatures(
				filepath.Join(runtimeDir, "hypr"),
				filepath.Join(procRoot, runtimeDir, "hypr"),
				"/tmp/hypr",
				filepath.Join(procRoot, "tmp/hypr"),
			)
			if len(signatures) > 0 {
				signature = signatures[len(signatures)-1]
			}
		}
		probe.sessions = append(probe.sessions, hyprlandSession{pid: pid, uid: uid, gid: gid, runtimeDir: runtimeDir, signature: signature})
	}
	return probe.sessions
}

// activeUserHyprlandSessions keeps the sessions of users whose Session Agent
// is registered, which excludes the login greeter.
func (probe *desktopProbe) activeUserHyprlandSessions() []hyprlandSession {
	if !probe.activeUIDsRead {
		probe.activeUIDs = probe.system.activeSessionUIDs()
		probe.activeUIDsRead = true
	}
	var sessions []hyprlandSession
	for _, session := range probe.hyprlandSessions() {
		if probe.activeUIDs[session.uid] {
			sessions = append(sessions, session)
		}
	}
	return sessions
}

func sessionEnvironment(session hyprlandSession, additional ...string) []string {
	return append([]string{
		"XDG_RUNTIME_DIR=" + session.runtimeDir,
		"HYPRLAND_INSTANCE_SIGNATURE=" + session.signature,
	}, additional...)
}

func (probe *desktopProbe) hyprlandDeviceDiagnostics() string {
	if !probe.diagnosticsRead {
		probe.diagnostics = probe.readHyprlandDeviceDiagnostics()
		probe.diagnosticsRead = true
	}
	return probe.diagnostics
}

func (probe *desktopProbe) readHyprlandDeviceDiagnostics() string {
	sessions := probe.activeUserHyprlandSessions()
	if len(sessions) == 0 {
		return "hyprctl devices unavailable: active user Hyprland session not found"
	}
	var failures []string
	for _, session := range sessions {
		if session.signature == "" {
			failures = append(failures, "pid="+session.pid+" has no IPC signature")
			continue
		}
		output, commandErr := probe.system.run(desktopCommand{
			session: session, timeout: 2 * time.Second,
			name: "hyprctl", arguments: []string{"-j", "devices"},
			environment: sessionEnvironment(session), combined: true,
		})
		if commandErr != nil {
			failures = append(failures, fmt.Sprintf("pid=%s uid=%d signature=%s: %v %s", session.pid, session.uid, session.signature, commandErr, strings.TrimSpace(string(output))))
			continue
		}
		text := string(output)
		index := strings.Index(strings.ToLower(text), "riftvm keyboard")
		if index < 0 {
			return "hyprctl devices has no RiftVM Keyboard"
		}
		start := max(0, index-250)
		end := min(len(text), index+650)
		return "hyprctl RiftVM Keyboard: " + strings.TrimSpace(text[start:end])
	}
	return "hyprctl devices failed: " + strings.Join(failures, "; ")
}

func (probe *desktopProbe) desktopInputReady() bool {
	if len(probe.activeUserHyprlandSessions()) > 0 && strings.HasPrefix(probe.hyprlandDeviceDiagnostics(), "hyprctl RiftVM Keyboard:") {
		return true
	}
	data, err := probe.kernelInputDevices()
	if err != nil {
		return false
	}
	return riftvmInputOwnedByCompositor(string(data), "RiftVM Keyboard", probe.desktopCompositorInputDevices())
}

// desktopPointerInputReady reports whether the desktop compositor holds the
// RiftVM absolute pointer open.
//
// The device node exists whenever the Agent could create it, including when a
// wrong udev class makes libinput drop it, so "the device exists" cannot stand
// in for "the desktop reads it". While this is false the Agent must not claim
// absolute pointer input: the Host would send absolute coordinates into a node
// nothing consumes and the cursor would never move. Relative pointer, wheel,
// and button input stay available either way.
func (probe *desktopProbe) desktopPointerInputReady() bool {
	data, err := probe.kernelInputDevices()
	if err != nil {
		return false
	}
	return riftvmInputOwnedByCompositor(
		string(data),
		"RiftVM Absolute Pointer",
		probe.desktopCompositorInputDevices(),
	)
}

func (probe *desktopProbe) desktopSessionActive() bool {
	sessions := probe.activeUserHyprlandSessions()
	if len(sessions) == 0 || len(probe.desktopProcessPIDs(desktopLockerNames)) > 0 {
		return false
	}
	if locked, determined := probe.omarchyShellLockState(); determined {
		return !locked
	}
	if locked, determined := probe.hyprlandSessionLockState(); determined {
		return !locked
	}
	return true
}

func (probe *desktopProbe) omarchyShellLockState() (bool, bool) {
	executable := probe.system.omarchyShell()
	if executable == "" {
		return false, false
	}
	for _, session := range probe.hyprlandSessions() {
		output, commandErr := probe.system.run(desktopCommand{
			session: session, timeout: time.Second,
			name: executable, arguments: []string{"lock", "isLocked"},
			environment: sessionEnvironment(session, "OMARCHY_SHELL_IPC_TIMEOUT=0.5s"),
		})
		if commandErr != nil {
			continue
		}
		if locked, determined := parseOmarchyShellLockState(output); determined {
			return locked, true
		}
	}
	return false, false
}

func parseOmarchyShellLockState(data []byte) (bool, bool) {
	switch strings.TrimSpace(string(data)) {
	case "true":
		return true, true
	case "false":
		return false, true
	default:
		return false, false
	}
}

func (probe *desktopProbe) hyprlandSessionLockState() (bool, bool) {
	for _, session := range probe.hyprlandSessions() {
		if session.signature == "" {
			continue
		}
		output, err := probe.system.run(desktopCommand{
			session: session, timeout: 2 * time.Second,
			name: "hyprctl", arguments: []string{"-j", "monitors"},
			environment: sessionEnvironment(session),
		})
		if err != nil {
			continue
		}
		if locked, determined := parseHyprlandSessionLockState(output); determined {
			return locked, true
		}
	}
	return false, false
}

func parseHyprlandSessionLockState(data []byte) (bool, bool) {
	var monitors []struct {
		SolitaryBlockedBy []string `json:"solitaryBlockedBy"`
	}
	if json.Unmarshal(data, &monitors) != nil || len(monitors) == 0 {
		return false, false
	}
	readable := false
	for _, monitor := range monitors {
		hasWorkspace := false
		for _, blocker := range monitor.SolitaryBlockedBy {
			switch blocker {
			case "LOCK":
				return true, true
			case "WORKSPACE":
				hasWorkspace = true
			}
		}
		if !hasWorkspace {
			readable = true
		}
	}
	if readable {
		return false, true
	}
	return false, false
}

func desktopSessionInteractive(compositorPIDs, lockerPIDs []string) bool {
	return len(compositorPIDs) > 0 && len(lockerPIDs) == 0
}

var desktopCompositorNames = map[string]bool{
	"gnome-shell":  true,
	"hyprland":     true,
	"kwin_wayland": true,
	"sway":         true,
	"weston":       true,
}

var desktopLockerNames = map[string]bool{
	"hyprlock": true,
}

func (probe *desktopProbe) desktopProcessPIDs(names map[string]bool) []string {
	var pids []string
	for _, process := range probe.processes() {
		if names[process.comm] {
			pids = append(pids, process.pid)
		}
	}
	return pids
}

func (probe *desktopProbe) desktopCompositorInputDevices() []string {
	seen := make(map[string]bool)
	var devices []string
	for _, pid := range probe.desktopProcessPIDs(desktopCompositorNames) {
		for _, device := range probe.openInputNodes(pid) {
			if !seen[device] {
				seen[device] = true
				devices = append(devices, device)
			}
		}
	}
	sort.Strings(devices)
	return devices
}

// hyprlandInputDevices lists the input nodes held by any Hyprland process.
func (probe *desktopProbe) hyprlandInputDevices() []string {
	seen := make(map[string]bool)
	var devices []string
	for _, process := range probe.processes() {
		if !strings.Contains(process.comm, "hyprland") {
			continue
		}
		for _, device := range probe.openInputNodes(process.pid) {
			if !seen[device] {
				seen[device] = true
				devices = append(devices, device)
			}
		}
	}
	sort.Strings(devices)
	return devices
}

func (probe *desktopProbe) inputDeviceNames() []string {
	data, err := probe.kernelInputDevices()
	if err != nil {
		return nil
	}
	var names []string
	for _, block := range strings.Split(string(data), "\n\n") {
		name := ""
		handlers := ""
		for _, line := range strings.Split(block, "\n") {
			switch {
			case strings.HasPrefix(line, "N: Name="):
				name = strings.Trim(strings.TrimPrefix(line, "N: Name="), "\"")
			case strings.HasPrefix(line, "H: Handlers="):
				handlers = strings.TrimSpace(strings.TrimPrefix(line, "H: Handlers="))
			}
		}
		if name != "" {
			if handlers != "" {
				name += " [" + handlers + "]"
			}
			names = append(names, name)
		}
	}
	if consumers := probe.hyprlandInputDevices(); len(consumers) > 0 {
		names = append(names, "Hyprland open input devices ["+strings.Join(consumers, " ")+"]")
	} else {
		names = append(names, "Hyprland open input devices [none]")
	}
	return append([]string{probe.hyprlandDeviceDiagnostics(), probe.system.inputDiagnostics()}, names...)
}

// parseInputEventDevices returns the event handlers of every device that
// reports the given kernel name in /proc/bus/input/devices.
func parseInputEventDevices(procDevices, name string) []string {
	marker := `N: Name="` + name + `"`
	var devices []string
	for _, block := range strings.Split(procDevices, "\n\n") {
		if !strings.Contains(block, marker) {
			continue
		}
		for _, line := range strings.Split(block, "\n") {
			if !strings.HasPrefix(line, "H: Handlers=") {
				continue
			}
			for _, field := range strings.Fields(strings.TrimPrefix(line, "H: Handlers=")) {
				if strings.HasPrefix(field, "event") {
					devices = append(devices, field)
				}
			}
		}
	}
	return devices
}

// riftvmInputOwnedByCompositor reports whether the compositor holds one of the
// event nodes belonging to the named RiftVM device.
func riftvmInputOwnedByCompositor(procDevices, name string, compositorDevices []string) bool {
	return intersects(parseInputEventDevices(procDevices, name), compositorDevices)
}

func intersects(left, right []string) bool {
	values := make(map[string]bool, len(left))
	for _, value := range left {
		values[value] = true
	}
	for _, value := range right {
		if values[value] {
			return true
		}
	}
	return false
}
