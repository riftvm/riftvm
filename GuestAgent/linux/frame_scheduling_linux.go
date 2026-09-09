//go:build linux

package main

import (
	"context"
	"os"
	"os/exec"
	"time"
)

// Hyprland 0.56 on virtio-gpu can leave keyboard-driven damage unpresented
// until the pointer moves. Run as the desktop user, outside input delivery.
// Rechecking also repairs configuration reloads. Continuous rendering trades
// idle efficiency for reliable presentation; revisit with upstream fixes.
func reconcileFrameScheduling() {
	if _, err := os.Stat("/sys/module/virtio_gpu"); err != nil {
		return
	}
	for _, session := range activeUserHyprlandSessions() {
		if session.uid != uint32(os.Getuid()) || session.signature == "" {
			continue
		}
		func() {
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			run := func(arguments ...string) *exec.Cmd {
				command := exec.CommandContext(ctx, "hyprctl", arguments...)
				command.Env = append(os.Environ(), "XDG_RUNTIME_DIR="+session.runtimeDir, "HYPRLAND_INSTANCE_SIGNATURE="+session.signature)
				return command
			}
			data, err := run("-j", "getoption", "debug:vfr").Output()
			if err != nil || !variableFrameRenderingEnabled(data) {
				return
			}
			_ = run("eval", "hl.config({ debug = { vfr = false } })").Run()
		}()
	}
}
