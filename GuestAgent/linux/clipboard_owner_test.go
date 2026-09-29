package main

import (
	"errors"
	"os/exec"
	"reflect"
	"testing"
	"time"
)

// ownerTrial drives startVerifiedClipboardOwner with a scripted selection and
// records every wait and read-back against the owner that was running.
type ownerTrial struct {
	expected clipboardReadBack
	// serve answers one read-back, given the owner (1-based), the read-back
	// (1-based, per owner) and the time waited since that owner started.
	serve func(owner, read int, elapsed time.Duration) (clipboardReadBack, error)

	starts  int
	reads   []int
	readAt  [][]time.Duration
	elapsed time.Duration
	between []time.Duration
	command *exec.Cmd
}

func (trial *ownerTrial) run(t *testing.T) (*exec.Cmd, error) {
	t.Helper()
	command, err := startVerifiedClipboardOwner(
		[]byte("clipboard bytes"),
		trial.expected,
		clipboardTextMIME,
		func(_ []byte, _ string) *exec.Cmd {
			trial.starts++
			trial.reads = append(trial.reads, 0)
			trial.readAt = append(trial.readAt, nil)
			trial.elapsed = 0
			trial.command = exec.Command("sleep", "30")
			return trial.command
		},
		func(mimeType string) (clipboardReadBack, error) {
			if mimeType != clipboardTextMIME {
				t.Fatalf("read back %q", mimeType)
			}
			owner := trial.starts
			trial.reads[owner-1]++
			trial.readAt[owner-1] = append(trial.readAt[owner-1], trial.elapsed)
			return trial.serve(owner, trial.reads[owner-1], trial.elapsed)
		},
		func(duration time.Duration) {
			if duration < 0 {
				t.Fatalf("negative wait %v", duration)
			}
			trial.elapsed += duration
		},
	)
	if command != nil {
		t.Cleanup(func() {
			_ = command.Process.Kill()
			_ = command.Wait()
		})
	}
	return command, err
}

var expectedReadBack = clipboardReadBack{
	sha256:    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
	byteCount: 15,
}

func milliseconds(values ...int) []time.Duration {
	durations := make([]time.Duration, len(values))
	for index, value := range values {
		durations[index] = time.Duration(value) * time.Millisecond
	}
	return durations
}

func TestClipboardOwnerIsAcceptedAfterThreeMatchingReadBacks(t *testing.T) {
	trial := &ownerTrial{expected: expectedReadBack, serve: func(int, int, time.Duration) (clipboardReadBack, error) {
		return expectedReadBack, nil
	}}
	command, err := trial.run(t)
	if err != nil || command != trial.command {
		t.Fatalf("command=%v error=%v", command, err)
	}
	if trial.starts != 1 || trial.reads[0] != clipboardPublicationVerifications {
		t.Fatalf("starts=%d reads=%v", trial.starts, trial.reads)
	}
	// Served at once: read early, then observed for two more settle steps.
	if want := milliseconds(25, 125, 225); !reflect.DeepEqual(trial.readAt[0], want) {
		t.Fatalf("read-backs at %v, want %v", trial.readAt[0], want)
	}
}

func TestClipboardOwnerThatNeedsTheFullSettleStepKeepsTheReleasedTiming(t *testing.T) {
	trial := &ownerTrial{expected: expectedReadBack, serve: func(_, _ int, elapsed time.Duration) (clipboardReadBack, error) {
		if elapsed < 100*time.Millisecond {
			return clipboardReadBack{}, errors.New("no selection yet")
		}
		return expectedReadBack, nil
	}}
	if _, err := trial.run(t); err != nil {
		t.Fatal(err)
	}
	// The released Agent read back at 100, 200 and 300 ms.
	if want := milliseconds(25, 50, 100, 200, 300); trial.starts != 1 || !reflect.DeepEqual(trial.readAt[0], want) {
		t.Fatalf("starts=%d read-backs at %v, want %v", trial.starts, trial.readAt[0], want)
	}
}

func TestStartVerifiedClipboardOwnerRetriesRejectedPublications(t *testing.T) {
	trial := &ownerTrial{expected: expectedReadBack, serve: func(owner, _ int, _ time.Duration) (clipboardReadBack, error) {
		if owner < 3 {
			return clipboardReadBack{}, errors.New("selection rejected")
		}
		return expectedReadBack, nil
	}}
	command, err := trial.run(t)
	if err != nil || command == nil {
		t.Fatal(err)
	}
	if trial.starts != 3 || !reflect.DeepEqual(trial.reads, []int{3, 3, clipboardPublicationVerifications}) {
		t.Fatalf("starts=%d reads=%v, want retries followed by stable verification", trial.starts, trial.reads)
	}
	// A rejected owner is given up no earlier than before: after one settle
	// step of its attempt, which grows with every attempt.
	if want := milliseconds(25, 50, 100); !reflect.DeepEqual(trial.readAt[0], want) {
		t.Fatalf("first owner read at %v, want %v", trial.readAt[0], want)
	}
	if want := milliseconds(25, 50, 200); !reflect.DeepEqual(trial.readAt[1], want) {
		t.Fatalf("second owner read at %v, want %v", trial.readAt[1], want)
	}
	if want := milliseconds(25, 325, 625); !reflect.DeepEqual(trial.readAt[2], want) {
		t.Fatalf("third owner read at %v, want %v", trial.readAt[2], want)
	}
}

func TestClipboardOwnerThatLosesTheSelectionIsReplaced(t *testing.T) {
	for _, lostAt := range []int{2, 3} {
		trial := &ownerTrial{expected: expectedReadBack, serve: func(owner, read int, _ time.Duration) (clipboardReadBack, error) {
			if owner == 1 && read >= lostAt {
				return clipboardReadBack{}, errors.New("selection cleared")
			}
			return expectedReadBack, nil
		}}
		command, err := trial.run(t)
		if err != nil || command == nil {
			t.Fatal(err)
		}
		if trial.starts != 2 || !reflect.DeepEqual(trial.reads, []int{lostAt, clipboardPublicationVerifications}) {
			t.Fatalf("lost at %d: starts=%d reads=%v", lostAt, trial.starts, trial.reads)
		}
	}
}

func TestStartVerifiedClipboardOwnerRejectsPersistentMismatch(t *testing.T) {
	for name, served := range map[string]clipboardReadBack{
		"other content":  {sha256: "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", byteCount: 15},
		"other length":   {sha256: expectedReadBack.sha256, byteCount: 16},
		"empty readback": {},
	} {
		t.Run(name, func(t *testing.T) {
			trial := &ownerTrial{expected: expectedReadBack, serve: func(int, int, time.Duration) (clipboardReadBack, error) {
				return served, nil
			}}
			command, err := trial.run(t)
			if err == nil || command != nil {
				t.Fatalf("command=%v error=%v, want verified publication failure", command, err)
			}
			if err.Error() != "could not publish verified Wayland clipboard: Wayland clipboard readback did not match" {
				t.Fatalf("error = %v", err)
			}
			if trial.starts != clipboardPublicationAttempts {
				t.Fatalf("starts=%d, want %d", trial.starts, clipboardPublicationAttempts)
			}
			if trial.command.ProcessState == nil {
				t.Fatal("rejected owner was not reaped")
			}
		})
	}
}

func TestClipboardOwnerReportsTheReadBackError(t *testing.T) {
	failure := errors.New("exit status 1")
	trial := &ownerTrial{expected: expectedReadBack, serve: func(int, int, time.Duration) (clipboardReadBack, error) {
		return clipboardReadBack{}, failure
	}}
	if _, err := trial.run(t); !errors.Is(err, failure) {
		t.Fatalf("error = %v", err)
	}
}

func TestClipboardOwnerThatCannotStartIsRetried(t *testing.T) {
	starts := 0
	command, err := startVerifiedClipboardOwner(
		nil, expectedReadBack, clipboardTextMIME,
		func(_ []byte, _ string) *exec.Cmd {
			starts++
			return exec.Command("/nonexistent/riftvm-clipboard-owner")
		},
		func(string) (clipboardReadBack, error) {
			t.Fatal("read back without an owner")
			return clipboardReadBack{}, nil
		},
		func(time.Duration) {},
	)
	if err == nil || command != nil || starts != clipboardPublicationAttempts {
		t.Fatalf("command=%v error=%v starts=%d", command, err, starts)
	}
}
