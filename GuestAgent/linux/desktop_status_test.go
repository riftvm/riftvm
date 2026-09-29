package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"
)

type fakeProcess struct {
	pid         string
	comm        string
	status      string
	environment string
	descriptors []string
}

type fakeCommandResult struct {
	output string
	err    error
}

// fakeGuest describes a guest and counts how often it is consulted.
type fakeGuest struct {
	processes     []fakeProcess
	files         map[string]string
	signatures    []string
	activeUIDs    map[uint32]bool
	omarchyShell  string
	commands      map[string]fakeCommandResult
	scans         int
	reads         map[string]int
	runs          map[string]int
	descriptorUse map[string]int
	ran           []desktopCommand
}

func (guest *fakeGuest) commandKey(name string, arguments []string, signature string) string {
	return name + " " + strings.Join(arguments, " ") + " @" + signature
}

func (guest *fakeGuest) readFile(path string) ([]byte, error) {
	if guest.reads == nil {
		guest.reads = map[string]int{}
	}
	guest.reads[path]++
	for _, process := range guest.processes {
		switch path {
		case "/proc/" + process.pid + "/status":
			return []byte(process.status), nil
		case "/proc/" + process.pid + "/environ":
			return []byte(process.environment), nil
		case "/proc/" + process.pid + "/comm":
			return []byte(process.comm), nil
		}
	}
	if content, ok := guest.files[path]; ok {
		return []byte(content), nil
	}
	return nil, os.ErrNotExist
}

func (guest *fakeGuest) run(command desktopCommand) ([]byte, error) {
	if guest.runs == nil {
		guest.runs = map[string]int{}
	}
	guest.runs[command.name+" "+strings.Join(command.arguments, " ")]++
	guest.ran = append(guest.ran, command)
	result, ok := guest.commands[guest.commandKey(command.name, command.arguments, command.session.signature)]
	if !ok {
		return nil, errors.New("exit status 127")
	}
	return []byte(result.output), result.err
}

func (guest *fakeGuest) descriptorTargets(pid string) []string {
	if guest.descriptorUse == nil {
		guest.descriptorUse = map[string]int{}
	}
	guest.descriptorUse[pid]++
	for _, process := range guest.processes {
		if process.pid == pid {
			return process.descriptors
		}
	}
	return nil
}

func (guest *fakeGuest) access() systemAccess {
	return systemAccess{
		processes: func() []processInfo {
			guest.scans++
			var processes []processInfo
			for _, process := range guest.processes {
				processes = append(processes, processInfo{
					pid: process.pid, comm: strings.ToLower(strings.TrimSpace(process.comm)),
				})
			}
			return processes
		},
		readFile:           guest.readFile,
		descriptorTargets:  guest.descriptorTargets,
		hyprlandSignatures: func(...string) []string { return guest.signatures },
		activeSessionUIDs:  func() map[uint32]bool { return guest.activeUIDs },
		run:                guest.run,
		omarchyShell:       func() string { return guest.omarchyShell },
		inputDiagnostics:   func() string { return "RiftVM input reports=3 last=[1/30/1 0/0/0]" },
	}
}

// legacyDesktop transliterates the released status helpers, which rescanned
// the process table and reran hyprctl for every question. It is the reference
// the single-snapshot probe must agree with.
type legacyDesktop struct{ guest *fakeGuest }

func (legacy legacyDesktop) pids() []string {
	legacy.guest.scans++
	var pids []string
	for _, process := range legacy.guest.processes {
		pids = append(pids, process.pid)
	}
	return pids
}

func (legacy legacyDesktop) read(path string) string {
	data, _ := legacy.guest.readFile(path)
	return string(data)
}

func (legacy legacyDesktop) findHyprlandSessions() []hyprlandSession {
	var sessions []hyprlandSession
	for _, pid := range legacy.pids() {
		if !strings.Contains(strings.ToLower(legacy.read("/proc/"+pid+"/comm")), "hyprland") {
			continue
		}
		uid, gid, ok := parseProcessCredentials([]byte(legacy.read("/proc/" + pid + "/status")))
		if !ok {
			continue
		}
		runtimeDir, signature := parseHyprlandEnvironment([]byte(legacy.read("/proc/" + pid + "/environ")))
		if runtimeDir == "" {
			runtimeDir = "/run/user/" + strconv.FormatUint(uint64(uid), 10)
		}
		if signature == "" && len(legacy.guest.signatures) > 0 {
			signature = legacy.guest.signatures[len(legacy.guest.signatures)-1]
		}
		sessions = append(sessions, hyprlandSession{pid: pid, uid: uid, gid: gid, runtimeDir: runtimeDir, signature: signature})
	}
	return sessions
}

func (legacy legacyDesktop) activeUserHyprlandSessions() []hyprlandSession {
	var sessions []hyprlandSession
	for _, session := range legacy.findHyprlandSessions() {
		if legacy.guest.activeUIDs[session.uid] {
			sessions = append(sessions, session)
		}
	}
	return sessions
}

func (legacy legacyDesktop) command(session hyprlandSession, name string, arguments ...string) ([]byte, error) {
	return legacy.guest.run(desktopCommand{session: session, name: name, arguments: arguments})
}

func (legacy legacyDesktop) hyprlandDeviceDiagnostics() string {
	sessions := legacy.activeUserHyprlandSessions()
	if len(sessions) == 0 {
		return "hyprctl devices unavailable: active user Hyprland session not found"
	}
	var failures []string
	for _, session := range sessions {
		if session.signature == "" {
			failures = append(failures, "pid="+session.pid+" has no IPC signature")
			continue
		}
		output, commandErr := legacy.command(session, "hyprctl", "-j", "devices")
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

func (legacy legacyDesktop) processPIDs(names map[string]bool) []string {
	var pids []string
	for _, pid := range legacy.pids() {
		if names[strings.ToLower(strings.TrimSpace(legacy.read("/proc/"+pid+"/comm")))] {
			pids = append(pids, pid)
		}
	}
	return pids
}

func (legacy legacyDesktop) inputNodes(pids []string) []string {
	seen := map[string]bool{}
	var devices []string
	for _, pid := range pids {
		for _, target := range legacy.guest.descriptorTargets(pid) {
			if !strings.HasPrefix(target, "/dev/input/event") || seen[target] {
				continue
			}
			seen[target] = true
			devices = append(devices, strings.TrimPrefix(target, "/dev/input/"))
		}
	}
	sort.Strings(devices)
	return devices
}

func (legacy legacyDesktop) desktopCompositorInputDevices() []string {
	return legacy.inputNodes(legacy.processPIDs(desktopCompositorNames))
}

func (legacy legacyDesktop) inputEventDevices(name string) []string {
	data, err := legacy.guest.readFile("/proc/bus/input/devices")
	if err != nil {
		return nil
	}
	return parseInputEventDevices(string(data), name)
}

func (legacy legacyDesktop) desktopInputReady() bool {
	if len(legacy.activeUserHyprlandSessions()) > 0 && strings.HasPrefix(legacy.hyprlandDeviceDiagnostics(), "hyprctl RiftVM Keyboard:") {
		return true
	}
	return intersects(legacy.inputEventDevices("RiftVM Keyboard"), legacy.desktopCompositorInputDevices())
}

func (legacy legacyDesktop) desktopPointerInputReady() bool {
	data, err := legacy.guest.readFile("/proc/bus/input/devices")
	if err != nil {
		return false
	}
	return riftvmInputOwnedByCompositor(string(data), "RiftVM Absolute Pointer", legacy.desktopCompositorInputDevices())
}

func (legacy legacyDesktop) desktopSessionActive() bool {
	sessions := legacy.activeUserHyprlandSessions()
	if len(sessions) == 0 || len(legacy.processPIDs(desktopLockerNames)) > 0 {
		return false
	}
	if legacy.guest.omarchyShell != "" {
		for _, session := range legacy.findHyprlandSessions() {
			output, err := legacy.command(session, legacy.guest.omarchyShell, "lock", "isLocked")
			if err != nil {
				continue
			}
			if locked, determined := parseOmarchyShellLockState(output); determined {
				return !locked
			}
		}
	}
	for _, session := range legacy.findHyprlandSessions() {
		if session.signature == "" {
			continue
		}
		output, err := legacy.command(session, "hyprctl", "-j", "monitors")
		if err != nil {
			continue
		}
		if locked, determined := parseHyprlandSessionLockState(output); determined {
			return !locked
		}
	}
	return true
}

func (legacy legacyDesktop) inputDeviceNames() []string {
	data, err := legacy.guest.readFile("/proc/bus/input/devices")
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
	var hyprland []string
	for _, pid := range legacy.pids() {
		if strings.Contains(strings.ToLower(legacy.read("/proc/"+pid+"/comm")), "hyprland") {
			hyprland = append(hyprland, pid)
		}
	}
	if consumers := legacy.inputNodes(hyprland); len(consumers) > 0 {
		names = append(names, "Hyprland open input devices ["+strings.Join(consumers, " ")+"]")
	} else {
		names = append(names, "Hyprland open input devices [none]")
	}
	return append([]string{legacy.hyprlandDeviceDiagnostics(), "RiftVM input reports=3 last=[1/30/1 0/0/0]"}, names...)
}

const kernelInputDevicesFixture = `I: Bus=0006 Vendor=1d6b Product=0104 Version=0004
N: Name="RiftVM Keyboard"
H: Handlers=sysrq kbd event3 leds

I: Bus=0006 Vendor=1d6b Product=0106 Version=0001
N: Name="RiftVM Relative Pointer"
H: Handlers=mouse0 event4

I: Bus=0006 Vendor=1d6b Product=0105 Version=0001
N: Name="RiftVM Absolute Pointer"
H: Handlers=event5

I: Bus=0019 Vendor=0000 Product=0001 Version=0000
N: Name="Power Button"
`

const hyprctlDevicesFixture = `{"mice":[{"name":"riftvm-relative-pointer"}],"keyboards":[{"address":"0x55d","name":"riftvm-keyboard","layout":"us","main":true},{"name":"RiftVM Keyboard"}],"tablets":[]}`

func userProcess(pid, comm string, uid int, signature string, descriptors ...string) fakeProcess {
	environment := "PATH=/usr/bin\x00XDG_RUNTIME_DIR=/run/user/" + strconv.Itoa(uid) + "\x00"
	if signature != "" {
		environment += "HYPRLAND_INSTANCE_SIGNATURE=" + signature + "\x00"
	}
	return fakeProcess{
		pid: pid, comm: comm + "\n",
		status:      fmt.Sprintf("Name:\t%s\nUid:\t%d\t%d\t%d\t%d\nGid:\t%d\t%d\t%d\t%d\n", comm, uid, uid, uid, uid, uid, uid, uid, uid),
		environment: environment, descriptors: descriptors,
	}
}

func desktopGuests() map[string]func() *fakeGuest {
	desktop := func() *fakeGuest {
		guest := &fakeGuest{
			processes: []fakeProcess{
				userProcess("1", "systemd", 0, ""),
				userProcess("410", "Hyprland", 970, "greeter_1", "/dev/input/event0"),
				userProcess("902", "Hyprland", 1000, "user_1", "/dev/null", "/dev/input/event3", "/dev/input/event4", "/dev/input/event5", "/dev/input/event3", "socket:[71]"),
				userProcess("950", "hyprland-helper", 1000, "user_1", "/dev/input/event9"),
				userProcess("990", "waybar", 1000, "user_1"),
			},
			files:        map[string]string{"/proc/bus/input/devices": kernelInputDevicesFixture},
			activeUIDs:   map[uint32]bool{1000: true},
			omarchyShell: "/usr/share/omarchy/bin/omarchy-shell",
		}
		guest.commands = map[string]fakeCommandResult{
			guest.commandKey("hyprctl", []string{"-j", "devices"}, "user_1"):                         {output: hyprctlDevicesFixture},
			guest.commandKey(guest.omarchyShell, []string{"lock", "isLocked"}, "greeter_1"):          {err: errors.New("exit status 1")},
			guest.commandKey(guest.omarchyShell, []string{"lock", "isLocked"}, "user_1"):             {output: "false\n"},
			guest.commandKey("hyprctl", []string{"-j", "monitors"}, "user_1"):                        {output: `[{"solitaryBlockedBy":[]}]`},
			guest.commandKey("hyprctl", []string{"-j", "monitors"}, "greeter_1"):                     {output: `[{"solitaryBlockedBy":["LOCK"]}]`},
			guest.commandKey("hyprctl", []string{"-j", "devices"}, "greeter_1"):                      {output: `{}`},
			guest.commandKey("/usr/bin/omarchy-shell", []string{"lock", "isLocked"}, "unused_value"): {output: "true"},
		}
		return guest
	}
	change := func(edit func(*fakeGuest)) func() *fakeGuest {
		return func() *fakeGuest {
			guest := desktop()
			edit(guest)
			return guest
		}
	}
	return map[string]func() *fakeGuest{
		"unlocked desktop": desktop,
		"no processes": func() *fakeGuest {
			return &fakeGuest{files: map[string]string{"/proc/bus/input/devices": kernelInputDevicesFixture}}
		},
		"nothing readable": func() *fakeGuest { return &fakeGuest{} },
		"greeter only": change(func(guest *fakeGuest) {
			guest.processes = guest.processes[:2]
			guest.activeUIDs = nil
		}),
		"session agent not registered": change(func(guest *fakeGuest) { guest.activeUIDs = map[uint32]bool{} }),
		"hyprlock running": change(func(guest *fakeGuest) {
			guest.processes = append(guest.processes, userProcess("1200", "hyprlock", 1000, "user_1"))
		}),
		"omarchy shell reports locked": change(func(guest *fakeGuest) {
			guest.commands[guest.commandKey(guest.omarchyShell, []string{"lock", "isLocked"}, "user_1")] = fakeCommandResult{output: "true\n"}
		}),
		"omarchy shell undetermined falls back to monitors": change(func(guest *fakeGuest) {
			guest.commands[guest.commandKey(guest.omarchyShell, []string{"lock", "isLocked"}, "user_1")] = fakeCommandResult{output: "maybe"}
		}),
		"no omarchy shell and greeter monitor locked": change(func(guest *fakeGuest) { guest.omarchyShell = "" }),
		"no omarchy shell and no monitors": change(func(guest *fakeGuest) {
			guest.omarchyShell = ""
			delete(guest.commands, guest.commandKey("hyprctl", []string{"-j", "monitors"}, "user_1"))
			delete(guest.commands, guest.commandKey("hyprctl", []string{"-j", "monitors"}, "greeter_1"))
		}),
		"hyprctl devices fails but compositor holds the keyboard": change(func(guest *fakeGuest) {
			guest.commands[guest.commandKey("hyprctl", []string{"-j", "devices"}, "user_1")] = fakeCommandResult{output: " socket refused \n", err: errors.New("exit status 1")}
		}),
		"hyprctl devices lacks the keyboard and compositor dropped it": change(func(guest *fakeGuest) {
			guest.commands[guest.commandKey("hyprctl", []string{"-j", "devices"}, "user_1")] = fakeCommandResult{output: `{"keyboards":[]}`}
			guest.processes[2].descriptors = []string{"/dev/input/event4"}
		}),
		"compositor dropped the absolute pointer": change(func(guest *fakeGuest) {
			guest.processes[2].descriptors = []string{"/dev/input/event3", "/dev/input/event4"}
		}),
		"signature found in the runtime directory": change(func(guest *fakeGuest) {
			guest.processes[2] = userProcess("902", "Hyprland", 1000, "", "/dev/input/event3")
			guest.signatures = []string{"older", "user_1"}
		}),
		"session without any signature": change(func(guest *fakeGuest) {
			guest.processes[2] = userProcess("902", "Hyprland", 1000, "", "/dev/input/event3")
			guest.processes[3] = userProcess("950", "hyprland-helper", 1000, "")
		}),
		"unreadable credentials":          change(func(guest *fakeGuest) { guest.processes[2].status = "Name:\tHyprland\n" }),
		"kernel input devices unreadable": change(func(guest *fakeGuest) { guest.files = nil }),
		"keyboard report near the start of a long device list": change(func(guest *fakeGuest) {
			guest.commands[guest.commandKey("hyprctl", []string{"-j", "devices"}, "user_1")] = fakeCommandResult{
				output: "  RiftVM Keyboard " + strings.Repeat("x", 900),
			}
		}),
		"sway desktop": change(func(guest *fakeGuest) {
			guest.processes = []fakeProcess{userProcess("700", "sway", 1000, "", "/dev/input/event3", "/dev/input/event5")}
		}),
	}
}

type desktopAnswers struct {
	Active, InputReady, PointerReady bool
	InputDevices                     []string
}

func TestDesktopProbeAgreesWithThePerQuestionScans(t *testing.T) {
	for name, build := range desktopGuests() {
		t.Run(name, func(t *testing.T) {
			legacy := legacyDesktop{build()}
			want := desktopAnswers{
				legacy.desktopSessionActive(), legacy.desktopInputReady(),
				legacy.desktopPointerInputReady(), legacy.inputDeviceNames(),
			}
			guest := build()
			probe := newDesktopProbe(guest.access())
			got := desktopAnswers{
				probe.desktopSessionActive(), probe.desktopInputReady(),
				probe.desktopPointerInputReady(), probe.inputDeviceNames(),
			}
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("answers changed:\n got %#v\nwant %#v", got, want)
			}
			if guest.scans > 1 {
				t.Fatalf("process table scanned %d times", guest.scans)
			}
			// One evaluation asks each active session until one answers.
			single := build()
			legacyDesktop{single}.hyprlandDeviceDiagnostics()
			if runs := guest.runs["hyprctl -j devices"]; runs != single.runs["hyprctl -j devices"] {
				t.Fatalf("hyprctl -j devices ran %d times, one evaluation needs %d", runs, single.runs["hyprctl -j devices"])
			}
			if reads := guest.reads["/proc/bus/input/devices"]; reads > 1 {
				t.Fatalf("kernel input devices read %d times", reads)
			}
			for pid, count := range guest.descriptorUse {
				if count > 1 {
					t.Fatalf("descriptors of %s resolved %d times", pid, count)
				}
			}
			if legacy.guest.scans > 1 && guest.scans == 0 {
				t.Fatal("the probe answered without looking at the process table")
			}
		})
	}
}

func TestDesktopCommandsKeepTheirEnvironmentAndCredentials(t *testing.T) {
	guest := desktopGuests()["omarchy shell undetermined falls back to monitors"]()
	// Every Hyprland instance is asked, the login greeter's first.
	delete(guest.commands, guest.commandKey("hyprctl", []string{"-j", "monitors"}, "greeter_1"))
	probe := newDesktopProbe(guest.access())
	if !probe.desktopSessionActive() || !probe.desktopInputReady() {
		t.Fatal("unlocked desktop was not reported as ready")
	}
	seen := map[string]desktopCommand{}
	for _, command := range guest.ran {
		if command.session.signature == "user_1" {
			seen[command.name+" "+strings.Join(command.arguments, " ")] = command
		}
	}
	base := []string{"XDG_RUNTIME_DIR=/run/user/1000", "HYPRLAND_INSTANCE_SIGNATURE=user_1"}
	for name, want := range map[string]desktopCommand{
		"hyprctl -j devices":  {timeout: 2 * time.Second, environment: base, combined: true},
		"hyprctl -j monitors": {timeout: 2 * time.Second, environment: base},
		"/usr/share/omarchy/bin/omarchy-shell lock isLocked": {
			timeout: time.Second, environment: append(append([]string{}, base...), "OMARCHY_SHELL_IPC_TIMEOUT=0.5s"),
		},
	} {
		got, ok := seen[name]
		if !ok {
			t.Fatalf("%s did not run", name)
		}
		if got.timeout != want.timeout || got.combined != want.combined || !reflect.DeepEqual(got.environment, want.environment) {
			t.Fatalf("%s ran as %#v", name, got)
		}
		if got.session.uid != 1000 || got.session.gid != 1000 {
			t.Fatalf("%s ran with session %#v", name, got.session)
		}
	}
}

func TestStatusReportTakesOneSnapshot(t *testing.T) {
	guest := desktopGuests()["unlocked desktop"]()
	revisions := 0
	value := statusReport(true, true, newDesktopProbe(guest.access()), func() string {
		revisions++
		return "4.0.3-1"
	})
	if guest.scans != 1 || guest.runs["hyprctl -j devices"] != 1 || guest.reads["/proc/bus/input/devices"] != 1 || revisions != 1 {
		t.Fatalf("scans=%d hyprctl=%d device reads=%d revisions=%d", guest.scans, guest.runs["hyprctl -j devices"], guest.reads["/proc/bus/input/devices"], revisions)
	}
	if !value.DesktopSessionActive || value.OmarchyRevision != "4.0.3-1" {
		t.Fatalf("status = %#v", value)
	}
	for _, capability := range []string{
		"file-transfer-v1", "kvm-diagnostics-v1", "shutdown-v1", "agent-restart-v1",
		"input-uinput-v1", "input-horizontal-wheel-v1", "input-uinput-desktop-v1", "desktop-input-v1",
		"dynamic-display-v1", "input-uinput-absolute-v1",
	} {
		if !contains(value.Capabilities, capability) {
			t.Fatalf("capability %s missing from %v", capability, value.Capabilities)
		}
	}
	wantDevices := []string{
		"hyprctl RiftVM Keyboard: " + hyprctlDevicesFixture,
		"RiftVM input reports=3 last=[1/30/1 0/0/0]",
		"RiftVM Keyboard [sysrq kbd event3 leds]",
		"RiftVM Relative Pointer [mouse0 event4]",
		"RiftVM Absolute Pointer [event5]",
		"Power Button",
		"Hyprland open input devices [event0 event3 event4 event5 event9]",
	}
	if !reflect.DeepEqual(value.InputDevices, wantDevices) {
		t.Fatalf("input devices = %#v", value.InputDevices)
	}

	locked := desktopGuests()["hyprlock running"]()
	value = statusReport(true, true, newDesktopProbe(locked.access()), func() string { return "" })
	if value.DesktopSessionActive || contains(value.Capabilities, "input-uinput-desktop-v1") ||
		contains(value.Capabilities, "dynamic-display-v1") || !contains(value.Capabilities, "input-uinput-absolute-v1") {
		t.Fatalf("locked status = %#v", value)
	}
	if locked.scans != 1 || locked.runs["hyprctl -j devices"] != 1 {
		t.Fatalf("locked scans=%d hyprctl=%d", locked.scans, locked.runs["hyprctl -j devices"])
	}

	dropped := desktopGuests()["compositor dropped the absolute pointer"]()
	value = statusReport(true, true, newDesktopProbe(dropped.access()), func() string { return "" })
	if !value.DesktopSessionActive || contains(value.Capabilities, "input-uinput-absolute-v1") {
		t.Fatalf("status with a dropped pointer = %#v", value)
	}
}

func TestStatusJSONFieldsAreUnchanged(t *testing.T) {
	encoded, err := json.Marshal(status{
		AgentVersion: "a", AgentInstanceID: "b", OmarchyRevision: "c", OperatingSystem: "d",
		KernelVersion: "e", HostName: "f", Addresses: []string{"g"}, BootID: "h", UptimeSeconds: 1,
		Capabilities: []string{"i"}, InputDevices: []string{"j"}, DesktopSessionActive: true,
		ProvisioningPending: true, KVMAvailable: true, KVMAPIVersion: 12, KVMError: "k",
	})
	if err != nil {
		t.Fatal(err)
	}
	want := `{"agentVersion":"a","agentInstanceID":"b","omarchyRevision":"c","operatingSystem":"d",` +
		`"kernelVersion":"e","hostName":"f","addresses":["g"],"bootID":"h","uptimeSeconds":1,` +
		`"capabilities":["i"],"inputDevices":["j"],"desktopSessionActive":true,"provisioningPending":true,` +
		`"kvmAvailable":true,"kvmAPIVersion":12,"kvmError":"k"}`
	if string(encoded) != want {
		t.Fatalf("status JSON changed:\n got %s\nwant %s", encoded, want)
	}
	encoded, err = json.Marshal(status{Addresses: []string{}})
	if err != nil {
		t.Fatal(err)
	}
	want = `{"agentVersion":"","agentInstanceID":"","operatingSystem":"","kernelVersion":"","hostName":"",` +
		`"addresses":[],"bootID":"","uptimeSeconds":0,"desktopSessionActive":false,"kvmAvailable":false}`
	if string(encoded) != want {
		t.Fatalf("empty status JSON changed:\n got %s\nwant %s", encoded, want)
	}
}

type exitStatus int

func (status exitStatus) Error() string { return "exit status " + strconv.Itoa(int(status)) }
func (status exitStatus) ExitCode() int { return int(status) }

type pacmanFixture struct {
	modified time.Time
	statErr  error
	packages map[string]string
	failure  error
	queries  int
	legacy   string
}

func (fixture *pacmanFixture) resolve(cache *omarchyRevisionCache, now time.Time) string {
	return cache.resolve(now,
		func() (time.Time, error) { return fixture.modified, fixture.statErr },
		func(name string) ([]byte, error) {
			fixture.queries++
			if fixture.failure != nil {
				return nil, fixture.failure
			}
			value, ok := fixture.packages[name]
			if !ok {
				return nil, fmt.Errorf("pacman: %w", exitStatus(1))
			}
			return []byte(name + " " + value + "\n"), nil
		},
		func() string { return fixture.legacy },
	)
}

func TestOmarchyRevisionIsCachedUntilThePackageDatabaseChanges(t *testing.T) {
	installed := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	now := installed.Add(time.Hour)
	fixture := &pacmanFixture{modified: installed, packages: map[string]string{"omarchy": "4.0.3-1"}, legacy: "4.0.0.alpha"}
	var cache omarchyRevisionCache
	for index := 0; index < 5; index++ {
		if got := fixture.resolve(&cache, now.Add(time.Duration(index)*10*time.Second)); got != "4.0.3-1" {
			t.Fatalf("revision = %q", got)
		}
	}
	if fixture.queries != 2 {
		t.Fatalf("pacman ran %d times for an unchanged database, want one pair", fixture.queries)
	}

	// An in-guest upgrade rewrites the database directory.
	fixture.packages["omarchy"] = "4.0.4-1"
	fixture.modified = now.Add(time.Minute)
	upgraded := fixture.modified.Add(2 * time.Second)
	if got := fixture.resolve(&cache, upgraded); got != "4.0.4-1" {
		t.Fatalf("revision after upgrade = %q", got)
	}
	// Until the database has settled every status asks again.
	if got := fixture.resolve(&cache, upgraded.Add(10*time.Second)); got != "4.0.4-1" || fixture.queries != 6 {
		t.Fatalf("revision=%q queries=%d while the database settles", got, fixture.queries)
	}
	settled := fixture.modified.Add(pacmanDatabaseSettleTime)
	fixture.resolve(&cache, settled)
	fixture.resolve(&cache, settled.Add(10*time.Second))
	if fixture.queries != 8 {
		t.Fatalf("queries=%d, want the settled answer to be remembered", fixture.queries)
	}
}

func TestOmarchyRevisionCacheKeepsEdgePrecedenceAndSourceInstallations(t *testing.T) {
	installed := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	now := installed.Add(time.Hour)
	edge := &pacmanFixture{modified: installed, packages: map[string]string{"omarchy-dev": "4.1.0.r42-1", "omarchy": "4.0.3-1"}}
	var cache omarchyRevisionCache
	if got := edge.resolve(&cache, now); got != "4.1.0.r42-1" {
		t.Fatalf("edge revision = %q", got)
	}

	source := &pacmanFixture{modified: installed, legacy: "4.0.0.alpha"}
	cache = omarchyRevisionCache{}
	if got := source.resolve(&cache, now); got != "4.0.0.alpha" || source.queries != 2 {
		t.Fatalf("source revision = %q after %d queries", got, source.queries)
	}
	// The version file is outside the package database and is read each time.
	source.legacy = "4.0.1.alpha"
	if got := source.resolve(&cache, now); got != "4.0.1.alpha" || source.queries != 2 {
		t.Fatalf("source revision = %q after %d queries", got, source.queries)
	}
}

func TestOmarchyRevisionIsNotCachedAfterAnError(t *testing.T) {
	installed := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	now := installed.Add(time.Hour)
	for name, failure := range map[string]error{
		"timeout":        exitStatus(-1),
		"pacman missing": errors.New("fork/exec /usr/bin/pacman: no such file or directory"),
		"pacman error":   exitStatus(2),
	} {
		t.Run(name, func(t *testing.T) {
			fixture := &pacmanFixture{modified: installed, failure: failure, legacy: "4.0.0.alpha", packages: map[string]string{"omarchy": "4.0.3-1"}}
			var cache omarchyRevisionCache
			if got := fixture.resolve(&cache, now); got != "4.0.0.alpha" {
				t.Fatalf("revision during failure = %q", got)
			}
			fixture.failure = nil
			if got := fixture.resolve(&cache, now); got != "4.0.3-1" || fixture.queries != 4 {
				t.Fatalf("revision after recovery = %q (%d queries)", got, fixture.queries)
			}
		})
	}
	t.Run("database unreadable", func(t *testing.T) {
		fixture := &pacmanFixture{statErr: os.ErrNotExist, packages: map[string]string{"omarchy": "4.0.3-1"}}
		var cache omarchyRevisionCache
		fixture.resolve(&cache, now)
		if got := fixture.resolve(&cache, now); got != "4.0.3-1" || fixture.queries != 4 {
			t.Fatalf("revision = %q (%d queries)", got, fixture.queries)
		}
	})
	t.Run("edge query fails once", func(t *testing.T) {
		// A failed query for the edge package must not pin the stable answer.
		fixture := &pacmanFixture{modified: installed, packages: map[string]string{"omarchy": "4.0.3-1"}}
		var cache omarchyRevisionCache
		calls := 0
		query := func(name string) ([]byte, error) {
			calls++
			if name == "omarchy-dev" {
				if calls == 1 {
					return nil, exitStatus(-1)
				}
				return []byte("omarchy-dev 4.1.0-1"), nil
			}
			return []byte("omarchy 4.0.3-1"), nil
		}
		stat := func() (time.Time, error) { return fixture.modified, nil }
		legacy := func() string { return "" }
		if got := cache.resolve(now, stat, query, legacy); got != "4.0.3-1" {
			t.Fatalf("revision = %q", got)
		}
		if got := cache.resolve(now, stat, query, legacy); got != "4.1.0-1" {
			t.Fatalf("revision after the edge query recovered = %q", got)
		}
	})
}

func writeProcess(t *testing.T, root, pid, comm, status string) {
	t.Helper()
	directory := filepath.Join(root, pid)
	if err := os.MkdirAll(directory, 0700); err != nil {
		t.Fatal(err)
	}
	if comm != "" {
		if err := os.WriteFile(filepath.Join(directory, "comm"), []byte(comm), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if status != "" {
		if err := os.WriteFile(filepath.Join(directory, "status"), []byte(status), 0600); err != nil {
			t.Fatal(err)
		}
	}
}

func TestProcessOwnedByReadsStatusOnlyForMatchingNames(t *testing.T) {
	root := t.TempDir()
	status := func(name string, uid int) string {
		return fmt.Sprintf("Name:\t%s\nUmask:\t0022\nState:\tS (sleeping)\nUid:\t%d\t%d\t%d\t%d\nGid:\t100\t100\t100\t100\n", name, uid, uid, uid, uid)
	}
	writeProcess(t, root, "1", "systemd\n", status("systemd", 0))
	writeProcess(t, root, "200", "spice-vdagent\n", status("spice-vdagent", 1001))
	writeProcess(t, root, "300", "spice-vdagentd\n", status("spice-vdagentd", 1000))
	// A process whose status would match but whose comm does not cannot exist;
	// it proves status is not consulted without a name match.
	writeProcess(t, root, "400", "bash\n", status("spice-vdagent", 1000))
	writeProcess(t, root, "500", "", status("spice-vdagent", 1000))
	writeProcess(t, root, "self", "spice-vdagent\n", status("spice-vdagent", 1000))
	if err := os.WriteFile(filepath.Join(root, "uptime"), []byte("1.0 1.0\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if processOwnedByIn(root, "spice-vdagent", 1000) {
		t.Fatal("matched a process of another user, another name, or a non-process entry")
	}
	if !processOwnedByIn(root, "spice-vdagent", 1001) {
		t.Fatal("process of the requested user was not found")
	}
	writeProcess(t, root, "600", "spice-vdagent\n", status("spice-vdagent", 1000))
	if !processOwnedByIn(root, "spice-vdagent", 1000) {
		t.Fatal("process was not found")
	}
	if processOwnedByIn(filepath.Join(root, "missing"), "spice-vdagent", 1000) {
		t.Fatal("missing process table reported a process")
	}
}
