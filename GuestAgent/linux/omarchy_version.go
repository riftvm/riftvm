package main

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

const pacmanLocalDatabase = "/var/lib/pacman/local"

// A database that changed this recently may still be inside the transaction
// that changed it, so its answer is not remembered yet.
const pacmanDatabaseSettleTime = time.Minute

var installedOmarchyRevisionCache omarchyRevisionCache

func installedOmarchyRevision() string {
	return installedOmarchyRevisionCache.resolve(
		time.Now(),
		func() (time.Time, error) {
			info, err := os.Stat(pacmanLocalDatabase)
			if err != nil {
				return time.Time{}, err
			}
			return info.ModTime(), nil
		},
		func(name string) ([]byte, error) {
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			return exec.CommandContext(ctx, "/usr/bin/pacman", "-Q", name).Output()
		},
		func() string {
			return readTrimmed("/usr/share/omarchy/version")
		},
	)
}

// omarchyRevisionCache remembers what pacman reported for as long as its local
// database directory keeps the same modification time. Installing, upgrading
// or removing a package adds or removes an entry of that directory, so an
// in-guest upgrade is still reflected without restarting the Agent, while an
// idle guest no longer runs pacman twice for every heartbeat.
type omarchyRevisionCache struct {
	lock     sync.Mutex
	valid    bool
	modified time.Time
	found    bool
	revision string
}

func (cache *omarchyRevisionCache) resolve(
	now time.Time,
	databaseModified func() (time.Time, error),
	query func(string) ([]byte, error),
	legacy func() string,
) string {
	cache.lock.Lock()
	defer cache.lock.Unlock()
	// Read the modification time before asking pacman: a change that lands
	// while pacman runs then invalidates the answer instead of matching it.
	modified, statError := databaseModified()
	if statError == nil && cache.valid && cache.modified.Equal(modified) {
		if cache.found {
			return cache.revision
		}
		// The version file of a source installation is not covered by the
		// package database; it is a single small read.
		return legacy()
	}
	cache.valid = false
	revision, found, conclusive := queryOmarchyPackageRevision(query)
	settled := now.Sub(modified) >= pacmanDatabaseSettleTime
	if statError == nil && conclusive && settled {
		cache.valid, cache.modified, cache.found, cache.revision = true, modified, found, revision
	}
	if found {
		return revision
	}
	return legacy()
}

func resolveOmarchyRevision(query func(string) ([]byte, error), legacy func() string) string {
	if revision, found, _ := queryOmarchyPackageRevision(query); found {
		return revision
	}
	// Older, source-based installations do not have an Omarchy package.
	return legacy()
}

// queryOmarchyPackageRevision asks for the installed Omarchy package. The
// answer is conclusive when every query either succeeded or reported that the
// package is not installed; a timeout or a pacman that could not run is not,
// and must be asked again.
func queryOmarchyPackageRevision(query func(string) ([]byte, error)) (revision string, found, conclusive bool) {
	conclusive = true
	// Packaged Omarchy reports its installed package version. The source-tree
	// version file can remain at an old alpha release after a stable update.
	// Match omarchy-version's edge-channel precedence.
	for _, name := range []string{"omarchy-dev", "omarchy"} {
		output, err := query(name)
		if err != nil {
			if !packageNotInstalled(err) {
				conclusive = false
			}
			continue
		}
		fields := strings.Fields(string(output))
		if len(fields) == 2 && fields[0] == name {
			return fields[1], true, conclusive
		}
	}
	return "", false, conclusive
}

// packageNotInstalled recognizes `pacman -Q` exiting with status 1, which is
// how it reports a package that is not installed.
func packageNotInstalled(err error) bool {
	var exit interface{ ExitCode() int }
	return errors.As(err, &exit) && exit.ExitCode() == 1
}
