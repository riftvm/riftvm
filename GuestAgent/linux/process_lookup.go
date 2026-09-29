package main

import (
	"os"
	"strconv"
	"strings"
)

// processOwnedBy reports whether a process with the given command name runs
// as uid. It reads the one-line comm of every process and parses the much
// larger status only for a process whose name matches.
func processOwnedBy(name string, uid uint32) bool {
	return processOwnedByIn("/proc", name, uid)
}

func processOwnedByIn(procRoot, name string, uid uint32) bool {
	entries, err := os.ReadDir(procRoot)
	if err != nil {
		return false
	}
	for _, entry := range entries {
		pid := entry.Name()
		if pid == "" || strings.Trim(pid, "0123456789") != "" {
			continue
		}
		comm, err := os.ReadFile(procRoot + "/" + pid + "/comm")
		if err != nil {
			continue
		}
		// status reports the same name as comm. It is compared up to its
		// first white space below, so compare comm the same way.
		if fields := strings.Fields(string(comm)); len(fields) == 0 || fields[0] != name {
			continue
		}
		data, err := os.ReadFile(procRoot + "/" + pid + "/status")
		if err != nil {
			continue
		}
		if processStatusMatches(data, name, uid) {
			return true
		}
	}
	return false
}

func processStatusMatches(status []byte, name string, uid uint32) bool {
	processName := ""
	processUID := uint64(^uint32(0))
	for _, line := range strings.Split(string(status), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 2 && fields[0] == "Name:" {
			processName = fields[1]
		}
		if len(fields) >= 2 && fields[0] == "Uid:" {
			processUID, _ = strconv.ParseUint(fields[1], 10, 32)
		}
	}
	return processName == name && uint32(processUID) == uid
}
