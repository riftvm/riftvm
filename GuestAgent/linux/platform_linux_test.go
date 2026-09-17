//go:build linux

package main

import (
	"reflect"
	"testing"
)

func TestParseHyprlandEnvironment(t *testing.T) {
	runtimeDir, signature := parseHyprlandEnvironment([]byte("PATH=/usr/bin\x00XDG_RUNTIME_DIR=/run/user/1000\x00HYPRLAND_INSTANCE_SIGNATURE=abc_123\x00"))
	if runtimeDir != "/run/user/1000" {
		t.Fatalf("runtime directory = %q", runtimeDir)
	}
	if signature != "abc_123" {
		t.Fatalf("signature = %q", signature)
	}
}

func TestParseProcessCredentials(t *testing.T) {
	uid, gid, ok := parseProcessCredentials([]byte("Name:\tHyprland\nUid:\t1000\t1000\t1000\t1000\nGid:\t984\t984\t984\t984\n"))
	if !ok || uid != 1000 || gid != 984 {
		t.Fatalf("credentials = (%d, %d, %t)", uid, gid, ok)
	}
}

func TestParseProcessCredentialsRejectsIncompleteStatus(t *testing.T) {
	if _, _, ok := parseProcessCredentials([]byte("Uid:\t1000\t1000\t1000\t1000\n")); ok {
		t.Fatal("incomplete process credentials were accepted")
	}
}

func TestIntersectsInputDeviceSets(t *testing.T) {
	if !intersects([]string{"event3", "event4"}, []string{"event1", "event3"}) {
		t.Fatal("shared input event was not detected")
	}
	if intersects([]string{"event3"}, []string{"event1", "event2"}) {
		t.Fatal("disjoint input devices were accepted")
	}
}

// procInputDevicesFixture mirrors the shape of /proc/bus/input/devices once the
// Agent has created its three devices. The absolute pointer is deliberately
// present, as it is on a guest whose compositor dropped it: existence is not
// readiness.
const procInputDevicesFixture = `I: Bus=0006 Vendor=1d6b Product=0104 Version=0004
N: Name="RiftVM Keyboard"
P: Phys=
S: Sysfs=/devices/virtual/input/input20
U: Uniq=
H: Handlers=sysrq kbd event3 leds
B: PROP=0

I: Bus=0006 Vendor=1d6b Product=0106 Version=0001
N: Name="RiftVM Relative Pointer"
P: Phys=
S: Sysfs=/devices/virtual/input/input21
U: Uniq=
H: Handlers=mouse0 event4
B: PROP=0

I: Bus=0006 Vendor=1d6b Product=0105 Version=0001
N: Name="RiftVM Absolute Pointer"
P: Phys=
S: Sysfs=/devices/virtual/input/input22
U: Uniq=
H: Handlers=event5
B: PROP=0

I: Bus=0003 Vendor=05ac Product=8103 Version=0100
N: Name="Apple Inc. Virtual USB Digitizer"
P: Phys=
S: Sysfs=/devices/virtual/input/input23
U: Uniq=
H: Handlers=event9
B: PROP=0
`

func TestParseInputEventDevicesSelectsTheNamedDevice(t *testing.T) {
	if got := parseInputEventDevices(procInputDevicesFixture, "RiftVM Keyboard"); !reflect.DeepEqual(got, []string{"event3"}) {
		t.Fatalf("keyboard event nodes = %v", got)
	}
	if got := parseInputEventDevices(procInputDevicesFixture, "RiftVM Absolute Pointer"); !reflect.DeepEqual(got, []string{"event5"}) {
		t.Fatalf("absolute pointer event nodes = %v", got)
	}
	if got := parseInputEventDevices(procInputDevicesFixture, "RiftVM Absent Pointer"); len(got) != 0 {
		t.Fatalf("unknown device reported event nodes = %v", got)
	}
}

func TestRiftVMInputOwnedByCompositorRequiresTheSameEventNode(t *testing.T) {
	if !riftvmInputOwnedByCompositor(procInputDevicesFixture, "RiftVM Absolute Pointer", []string{"event9", "event5"}) {
		t.Fatal("compositor-owned absolute pointer was reported as unowned")
	}
	// A compositor that opened the keyboard and dropped the misclassified
	// pointer must not count as ready for absolute pointer input.
	if riftvmInputOwnedByCompositor(procInputDevicesFixture, "RiftVM Absolute Pointer", []string{"event3", "event4"}) {
		t.Fatal("keyboard and wheel ownership were accepted as pointer ownership")
	}
}

func TestDesktopSessionRequiresCompositorWithoutActiveLocker(t *testing.T) {
	if !desktopSessionInteractive([]string{"101"}, nil) {
		t.Fatal("unlocked compositor was not reported as interactive")
	}
	if desktopSessionInteractive([]string{"101"}, []string{"202"}) {
		t.Fatal("locked compositor was reported as interactive")
	}
	if desktopSessionInteractive(nil, nil) {
		t.Fatal("missing compositor was reported as interactive")
	}
}

func TestParseHyprlandSessionLockState(t *testing.T) {
	tests := []struct {
		name       string
		input      string
		locked     bool
		determined bool
	}{
		{"locked", `[{"solitaryBlockedBy":["LOCK"]}]`, true, true},
		{"locked among monitors", `[{"solitaryBlockedBy":["WORKSPACE"]},{"solitaryBlockedBy":["LOCK"]}]`, true, true},
		{"unlocked", `[{"solitaryBlockedBy":[]}]`, false, true},
		{"unlocked with another blocker", `[{"solitaryBlockedBy":["MIRROR"]}]`, false, true},
		{"workspace only is undetermined", `[{"solitaryBlockedBy":["WORKSPACE"]}]`, false, false},
		{"empty is undetermined", `[]`, false, false},
		{"invalid is undetermined", `{`, false, false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			locked, determined := parseHyprlandSessionLockState([]byte(test.input))
			if locked != test.locked || determined != test.determined {
				t.Fatalf("got (%t, %t), want (%t, %t)", locked, determined, test.locked, test.determined)
			}
		})
	}
}

func TestParseOmarchyShellLockState(t *testing.T) {
	tests := []struct {
		name       string
		input      string
		locked     bool
		determined bool
	}{
		{"locked", "true\n", true, true},
		{"unlocked", " false \n", false, true},
		{"empty", "", false, false},
		{"unexpected", "LOCK", false, false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			locked, determined := parseOmarchyShellLockState([]byte(test.input))
			if locked != test.locked || determined != test.determined {
				t.Fatalf("got (%v, %v), want (%v, %v)", locked, determined, test.locked, test.determined)
			}
		})
	}
}
