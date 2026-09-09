package main

import (
	"context"
	"os/exec"
	"strings"
	"time"
)

func installedOmarchyRevision() string {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	return resolveOmarchyRevision(func(name string) ([]byte, error) {
		return exec.CommandContext(ctx, "/usr/bin/pacman", "-Q", name).Output()
	}, func() string {
		return readTrimmed("/usr/share/omarchy/version")
	})
}

func resolveOmarchyRevision(query func(string) ([]byte, error), legacy func() string) string {
	// Packaged Omarchy reports its installed package version. The source-tree
	// version file can remain at an old alpha release after a stable update.
	// Match omarchy-version's edge-channel precedence, and query on each status
	// request so an in-guest upgrade is reflected without restarting the Agent.
	for _, name := range []string{"omarchy-dev", "omarchy"} {
		output, err := query(name)
		if err != nil {
			continue
		}
		fields := strings.Fields(string(output))
		if len(fields) == 2 && fields[0] == name {
			return fields[1]
		}
	}
	// Older, source-based installations do not have an Omarchy package.
	return legacy()
}
