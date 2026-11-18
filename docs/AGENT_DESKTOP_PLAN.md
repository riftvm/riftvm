# Agent desktop control plan

RiftVM should let a person use their Omarchy desktop, hand it to a local agent
for a task, and take control back at any time. RiftVM 4.5.1 targets a preview
for an already running, signed-in Omarchy workspace on Apple silicon with
macOS 27 or later. Use the default Omarchy 4.5 Factory for acceptance.

The estimate is 7–10 engineering days. Revisit it after verifying that RiftVM
can capture a settled frame on demand and cancel queued input on handoff.

## 1. Prove the desktop loop (1–2 days)

- Capture a PNG from the existing [VirGL renderer](CUSTOM_VIRGL_ARCHITECTURE.md)
  on demand. Return the guest pixel dimensions and a frame identifier. A
  settled desktop must remain readable without waiting for a new redraw.
- Use the existing authenticated [Guest Agent input channel](GUEST_AGENT_PROTOCOL.md)
  to click a visible launcher item. Take a second screenshot and confirm that
  the terminal opened. Capture only the guest display.
- Verify where the host can cancel pending input and release keys before
  handing control back to the person.

## 2. Add the local CLI session (2–3 days)

Extend the [existing CLI](../README.md#command-line) with `riftvm agent connect`.
Use a long-lived, local-only connection to the running RiftVM app and exchange
newline-delimited JSON. Provide `status`, `screenshot`, `click`, `scroll`, `key`,
and `type`. Reuse the existing input and guest clipboard paths where applicable.

Use screenshot pixels for pointer coordinates. Reject a pointer action when its
frame belongs to an earlier display geometry or desktop session. Report whether
an input event was delivered to the guest. The caller uses a fresh screenshot to
verify what the desktop did in response.

Verify the interface from an independent client script. Check that a desktop
that is still starting, an expired session, and invalid coordinates each produce
a distinct error.

## 3. Add permission and handoff controls (2–3 days)

- Add an **Allow Agent Control** action in RiftVM. Bind the approved connection
  to the current workspace and allow one controlling agent at a time.
- Show when the agent has control and keep **Take Back Control** reachable in
  the RiftVM toolbar. Restore human input when the person takes control back,
  the agent disconnects, or the VM stops.
- Invalidate the old session, discard input still queued for it, and release
  any pressed keys or buttons on handoff. Verify that the old connection cannot
  send more input and the person's keyboard and pointer work immediately.

## 4. Qualify the signed release candidate (2 days)

Use the default Factory and the normal Prepare Omarchy flow. After first setup,
have an agent open a terminal, create a test file, open it from the graphical
file manager, save a screenshot showing the result, and return control. Repeat
with the client script and add the scenario to the
[real-guest release checklist](V1_RELEASE_CHECKLIST.md) during implementation.

Exercise taking control back during input, terminating the agent process, and
restarting the VM. Verify that the person's input still works and that the agent
must obtain a new grant before controlling the restarted desktop.

## After 4.5.1

1. **Disposable workspaces.** Create an independent VM from the verified
   Factory, with host folder sharing off by default. Let the user inspect,
   export, or discard the result.
2. **Structured guest operations.** Add guest command execution with exit
   status and output, plus file access to designated guest directories.
3. **MCP integration.** Expose the same operations after validating the local
   desktop and development workflows.

This roadmap focuses on the current macOS and Omarchy baseline. Older macOS
versions, multi-display support, cameras, Touch ID, and peripheral compatibility
work are outside the planned preview.
