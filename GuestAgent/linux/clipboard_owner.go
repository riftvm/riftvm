package main

import (
	"errors"
	"fmt"
	"os/exec"
	"time"
)

const clipboardPublicationAttempts = 5
const clipboardPublicationVerifications = 3

// clipboardOwnerSettleStep is the wait of the first attempt between an owner
// starting and its publication being declared rejected, and between two
// verifications. Later attempts scale it.
const clipboardOwnerSettleStep = 100 * time.Millisecond

// clipboardOwnerFirstProbe is how soon a new owner is first read back.
const clipboardOwnerFirstProbe = 25 * time.Millisecond

// clipboardReadBack is the content the Wayland selection served.
type clipboardReadBack struct {
	sha256    string
	byteCount uint64
}

// startVerifiedClipboardOwner starts a clipboard owner and returns it only
// after the selection has served the expected content on
// clipboardPublicationVerifications consecutive read-backs.
//
// A freshly activated Hyprland data-control session can reject its first
// ownership request. Prove the exact bytes are serveable before acknowledging
// the authenticated Host request; a longer wait on the same rejected owner
// does not recover it, so a rejected owner is replaced.
//
// The repeated verification is deliberate. A rejection, or the late teardown
// of the previous owner, can clear a selection that was already read back
// correctly once, so one successful read does not prove ownership. The
// verifications after the first therefore stay one settle step apart, which
// keeps the observed interval after the first correct read-back unchanged.
// What changed is the cost of looking: every read-back is hashed while it
// streams instead of being buffered and compared byte by byte, and the first
// read-back no longer waits a full settle step. It is tried early and
// repeated until the settle step has passed, so a publication is accepted as
// soon as it is served but is still declared rejected no earlier than before.
func startVerifiedClipboardOwner(
	payload []byte,
	expected clipboardReadBack,
	mimeType string,
	makeCommand func([]byte, string) *exec.Cmd,
	readBack func(string) (clipboardReadBack, error),
	pause func(time.Duration),
) (*exec.Cmd, error) {
	var lastError error
	verify := func() bool {
		actual, err := readBack(mimeType)
		if err != nil {
			lastError = err
			return false
		}
		if actual != expected {
			lastError = errors.New("Wayland clipboard readback did not match")
			return false
		}
		return true
	}
	for attempt := 0; attempt < clipboardPublicationAttempts; attempt++ {
		settle := time.Duration(attempt+1) * clipboardOwnerSettleStep
		command := makeCommand(payload, mimeType)
		if err := command.Start(); err != nil {
			lastError = err
		} else {
			verified := false
			waited := time.Duration(0)
			for _, probe := range []time.Duration{clipboardOwnerFirstProbe, 2 * clipboardOwnerFirstProbe, settle} {
				pause(probe - waited)
				waited = probe
				if verified = verify(); verified {
					break
				}
			}
			for verification := 1; verified && verification < clipboardPublicationVerifications; verification++ {
				pause(settle)
				verified = verify()
			}
			if verified {
				return command, nil
			}
			if command.Process != nil {
				_ = command.Process.Kill()
			}
			_ = command.Wait()
		}
		if attempt+1 < clipboardPublicationAttempts {
			pause(settle)
		}
	}
	return nil, fmt.Errorf("could not publish verified Wayland clipboard: %w", lastError)
}
