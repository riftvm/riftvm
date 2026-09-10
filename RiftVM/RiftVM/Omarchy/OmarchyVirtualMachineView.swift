import AVFoundation
import UserNotifications
import SwiftUI
import UniformTypeIdentifiers
import Virtualization

private let omarchyMetadataQueue = DispatchQueue(label: "com.riftvm.app.omarchy.metadata")

final class OmarchyVirtualMachineInputView: VZVirtualMachineView {
    private(set) var hostOverlayVisible = false

    override var acceptsFirstResponder: Bool {
        !hostOverlayVisible && super.acceptsFirstResponder
    }

    func setHostOverlayVisible(_ visible: Bool) {
        guard hostOverlayVisible != visible else { return }
        hostOverlayVisible = visible
        if visible { releaseGuestKeys() }
        capturesSystemKeys = !visible
        if visible, let responder = window?.firstResponder as? NSView,
           responder === self || responder.isDescendant(of: self) {
            window?.makeFirstResponder(nil)
        }
        // SwiftUI overlays do not remove the VZ view's native cursor tracking.
        // Hide only the display view; keep the machine and Agent running.
        isHidden = visible
        window?.invalidateCursorRects(for: self)
        if visible {
            pendingDisplayRefresh?.cancel()
            displayRefreshGeneration &+= 1
        } else {
            refreshDisplayAfterTransition()
        }
    }

    // App-targeted events may reach the responder without traversing the
    // session event tap, so Command routing also has a direct-view seam.
    var commandEventHandler: ((NSEvent) -> Bool)?
    private var guestInputEventHandler: (([VMGuestAgentInputEvent]) -> Void)?
    private var guestPressedKeys = Set<UInt16>()
    private var diagnosticMonitor: Any?
    private var diagnosticViewEvents = 0
    private var diagnosticWindowEvents = 0
    private let inputDiagnosticsEnabled = UserDefaults.standard.bool(forKey: "RiftVMInputDiagnosticsEnabled")
    private var displayObservers: [NSObjectProtocol] = []
    private var powerObservers: [NSObjectProtocol] = []
    private var pendingDisplayRefresh: DispatchWorkItem?
    private var displayRefreshGeneration: UInt64 = 0
    private func recordInputDelivery(_ event: NSEvent, route: String) {
        guard inputDiagnosticsEnabled else { return }
        if route == "window" { diagnosticWindowEvents += 1 } else { diagnosticViewEvents += 1 }
        // Content-free diagnostics: never record characters, key codes, or flags.
        let ageMS = max(0, (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000)
        NSLog(
            "RiftVM input timing route=%@ windowEvents=%d viewEvents=%d ageMS=%.1f eventType=%lu appActive=%d keyWindow=%d firstResponder=%d",
            route, diagnosticWindowEvents, diagnosticViewEvents, ageMS, event.type.rawValue,
            NSApp.isActive ? 1 : 0, window?.isKeyWindow == true ? 1 : 0,
            window?.firstResponder === self ? 1 : 0
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeDisplayObservers()
        guard let window else { return }
        if inputDiagnosticsEnabled {
            diagnosticMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
                if let self, event.window === self.window { self.recordInputDelivery(event, route: "window") }
                return event
            }
        }
        for name in [
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didChangeBackingPropertiesNotification,
            NSWindow.didChangeScreenNotification,
        ] {
            displayObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] _ in self?.refreshDisplayAfterTransition() })
        }
        displayObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self] _ in self?.scheduleDisplayRefresh() })
        displayObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            guard let self, let window, self.window === window,
                  window.attachedSheet == nil, !self.hostOverlayVisible else { return }
            window.makeFirstResponder(self)
        })
        refreshDisplayAfterTransition()
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window,
                  window.isKeyWindow, window.attachedSheet == nil,
                  !self.hostOverlayVisible else { return }
            window.makeFirstResponder(self)
        }
        displayObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in self?.releaseGuestKeys() })
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        powerObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.releaseGuestKeys() })
        powerObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshDisplayAfterTransition() })
    }

    override func mouseDown(with event: NSEvent) {
        guard !hostOverlayVisible else { return }
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    private func scheduleDisplayRefresh() {
        pendingDisplayRefresh?.cancel()
        displayRefreshGeneration &+= 1
        let work = DispatchWorkItem { [weak self] in self?.refreshDisplayAfterTransition() }
        pendingDisplayRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { releaseGuestKeys() }
        return resigned
    }

    private func releaseGuestKeys() {
        let keys = guestPressedKeys.sorted()
        guestPressedKeys.removeAll()
        for code in keys {
            guestInputEventHandler?(VMGuestAgentInputBatch.key(code: code, pressed: false).events)
        }
    }

    private func refreshDisplayAfterTransition() {
        pendingDisplayRefresh?.cancel()
        pendingDisplayRefresh = nil
        displayRefreshGeneration &+= 1
        let generation = displayRefreshGeneration
        guard let targetWindow = window else { return }
        for delay in [0.0, 0.35, 1.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak targetWindow] in
                guard let self, let targetWindow, self.window === targetWindow,
                      self.displayRefreshGeneration == generation,
                      !self.hostOverlayVisible,
                      self.virtualMachine != nil else { return }
                targetWindow.contentView?.layoutSubtreeIfNeeded()
                self.automaticallyReconfiguresDisplay = false
                self.automaticallyReconfiguresDisplay = true
            }
        }
    }

    private func removeDisplayObservers() {
        if let diagnosticMonitor { NSEvent.removeMonitor(diagnosticMonitor) }
        diagnosticMonitor = nil
        displayRefreshGeneration &+= 1
        pendingDisplayRefresh?.cancel()
        pendingDisplayRefresh = nil
        displayObservers.forEach(NotificationCenter.default.removeObserver)
        displayObservers.removeAll()
        powerObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        powerObservers.removeAll()
    }

    deinit {
        if let diagnosticMonitor { NSEvent.removeMonitor(diagnosticMonitor) }
        pendingDisplayRefresh?.cancel()
        displayObservers.forEach(NotificationCenter.default.removeObserver)
        powerObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    private func recordAcceptanceRoute(_ route: String, event: NSEvent) {
        #if RIFTVM_ACCEPTANCE_HARNESS
        guard ProcessInfo.processInfo.environment[
            OmarchyWorkspaceConfiguration.acceptanceEnabledKey
        ] == "1", let cgEvent = event.cgEvent else { return }
        let marker = cgEvent.getIntegerValueField(.eventSourceUserData)
        if ProcessInfo.processInfo.environment["RIFTVM_OMARCHY_TRACE_INPUT_EVENTS"] == "1" {
            // Local-only diagnostic: compare injected text's key mapping with
            // the received physical code without logging the text itself.
            let text = (event.type == .keyDown || event.type == .keyUp) ? event.characters : nil
            let mappedCode = text.flatMap { OmarchyHostKeyboardTextEncoder.strokes(for: $0)?.first?.keyCode }
            NSLog("Omarchy test event route=%@ key=%hu mapped=%d repeat=%d timestamp=%.6f",
                  route, event.keyCode, mappedCode.map(Int.init) ?? -1,
                  event.type == .keyDown && event.isARepeat ? 1 : 0, event.timestamp)
        }
        guard marker == OmarchyFocusedCommandBridge.acceptanceMarker
                || marker == OmarchyFocusedCommandBridge.syntheticMarker else { return }
        NSLog(
            "Omarchy acceptance input route=%@ keyCode=%hu flags=%llu marker=%lld",
            route, event.keyCode, event.modifierFlags.rawValue, marker
        )
        #endif
    }

    override func keyDown(with event: NSEvent) {
        recordInputDelivery(event, route: "view")
        recordAcceptanceRoute("keyDown", event: event)
        if commandEventHandler?(event) == true { return }
        if let guestInputEventHandler {
            let effectiveFlags = VMGuestAgentKeyboard.effectiveModifierFlags(
                reported: event.modifierFlags,
                characters: event.characters,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers
            )
            if !event.isARepeat,
               let events = VMGuestAgentKeyboard.chordEventsForMissingModifierTransition(
                   forMacVirtualKey: event.keyCode,
                   modifierFlags: effectiveFlags,
                   alreadyPressed: guestPressedKeys
               ) {
                guestInputEventHandler(events)
                return
            }
            guard let code = VMGuestAgentKeyboard.linuxKeyCode(forMacVirtualKey: event.keyCode) else {
                super.keyDown(with: event)
                return
            }
            if !event.isARepeat, guestPressedKeys.insert(code).inserted {
                guestInputEventHandler(VMGuestAgentInputBatch.key(code: code, pressed: true).events)
            } else if event.isARepeat {
                if guestPressedKeys.contains(code) {
                    // Hyprland's virtual-keyboard path does not surface raw
                    // EV_KEY value=2 repeats consistently. Preserve AppKit's
                    // repeat cadence as balanced release/press pulses so each
                    // host repeat becomes exactly one visible Guest key.
                    guestInputEventHandler(
                        VMGuestAgentInputBatch.key(code: code, pressed: false).events
                        + VMGuestAgentInputBatch.key(code: code, pressed: true).events
                    )
                } else if guestPressedKeys.insert(code).inserted {
                    guestInputEventHandler(VMGuestAgentInputBatch.key(code: code, pressed: true).events)
                }
            }
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        recordInputDelivery(event, route: "view")
        recordAcceptanceRoute("keyUp", event: event)
        if commandEventHandler?(event) == true { return }
        if let guestInputEventHandler,
           let code = VMGuestAgentKeyboard.linuxKeyCode(forMacVirtualKey: event.keyCode) {
            if guestPressedKeys.remove(code) != nil {
                guestInputEventHandler(VMGuestAgentInputBatch.key(code: code, pressed: false).events)
            }
            return
        }
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        recordInputDelivery(event, route: "view")
        recordAcceptanceRoute("flagsChanged", event: event)
        // Command/Super chords are synthesized as one balanced Agent batch by
        // OmarchyFocusedCommandBridge. Forwarding AppKit's independent Command
        // flagsChanged event as well can leave Linux Super held when macOS does
        // not deliver the matching transition to this view.
        if OmarchyCommandCapturePolicy.ownsCommandModifier(keyCode: event.keyCode) {
            return
        }
        if let guestInputEventHandler {
            if let code = VMGuestAgentKeyboard.linuxKeyCode(forMacVirtualKey: event.keyCode),
               let pressed = VMGuestAgentKeyboard.modifierPressed(
                   forMacVirtualKey: event.keyCode,
                   flags: event.modifierFlags
               ), pressed != guestPressedKeys.contains(code) {
                if pressed { guestPressedKeys.insert(code) } else { guestPressedKeys.remove(code) }
                guestInputEventHandler(VMGuestAgentInputBatch.key(code: code, pressed: pressed).events)
            }
            // The Agent owns keyboard delivery while active. Redundant or
            // unmapped modifier notifications must not reach the VZ keyboard
            // independently of the corresponding Agent key transitions.
            return
        }
        super.flagsChanged(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        recordAcceptanceRoute("performKeyEquivalent", event: event)
        if commandEventHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    func setGuestInputEventHandler(_ handler: (([VMGuestAgentInputEvent]) -> Void)?) {
        if handler == nil, let current = guestInputEventHandler {
            for code in guestPressedKeys.sorted() {
                current(VMGuestAgentInputBatch.key(code: code, pressed: false).events)
            }
            guestPressedKeys.removeAll()
        }
        guestInputEventHandler = handler
    }

    /// Sends an intentionally unpaced burst through the same view-to-Agent
    /// handler used by physical AppKit key events. This acceptance seam keeps
    /// TCC and UI automation timing out of the measurement while still
    /// exercising the production batching queue that previously lost keys.
    #if RIFTVM_ACCEPTANCE_HARNESS
    func runGuestAgentTextBurstAcceptance(_ text: String) -> Bool {
        guard guestInputEventHandler != nil,
              let source = CGEventSource(stateID: .combinedSessionState),
              let strokes = OmarchyHostKeyboardTextEncoder.strokes(for: text) else {
            return false
        }
        let shifted = CGEventFlags.maskShift.union(CGEventFlags(rawValue: 0x00000002))
        for stroke in strokes {
            if stroke.shifted,
               let shiftDown = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: true) {
                shiftDown.type = .flagsChanged
                shiftDown.flags = shifted
                if let event = NSEvent(cgEvent: shiftDown) { flagsChanged(with: event) }
            }
            for down in [true, false] {
                guard let cgEvent = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: stroke.keyCode,
                    keyDown: down
                ) else { return false }
                cgEvent.flags = stroke.shifted ? shifted : []
                guard let event = NSEvent(cgEvent: cgEvent) else { return false }
                if down { keyDown(with: event) } else { keyUp(with: event) }
            }
            if stroke.shifted,
               let shiftUp = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: false) {
                shiftUp.type = .flagsChanged
                shiftUp.flags = []
                if let event = NSEvent(cgEvent: shiftUp) { flagsChanged(with: event) }
            }
        }
        return true
    }

    /// Sends one physical-style key down, a bounded stream of AppKit repeat
    /// events, and a matching key up through the production Agent/uinput path.
    /// This catches repeat events being collapsed, duplicated, or left held.
    func runGuestAgentKeyRepeatAcceptance(keyCode: CGKeyCode, count: Int) -> Bool {
        guard guestInputEventHandler != nil, count > 0,
              let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }
        for index in 0..<count {
            guard let cgEvent = CGEvent(
                keyboardEventSource: source,
                virtualKey: keyCode,
                keyDown: true
            ) else { return false }
            if index > 0 {
                cgEvent.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
            }
            guard let event = NSEvent(cgEvent: cgEvent) else { return false }
            keyDown(with: event)
        }
        guard let keyUpEvent = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: false
        ), let event = NSEvent(cgEvent: keyUpEvent) else { return false }
        keyUp(with: event)
        return true
    }

    /// Exercises Virtualization.framework's Apple USB keyboard directly.
    ///
    /// Acceptance probes must not depend on Accessibility permission: that
    /// permission exists only to keep Command shortcuts inside the VM and is
    /// unrelated to ordinary VZ keyboard delivery. Posting CGEvents through
    /// the session tap made the USB latency probe fail whenever the installed
    /// build's signing requirement changed. Dispatching equivalent NSEvents to
    /// `super` measures the same VZ keyboard path without involving TCC.
    func runAppleUSBTextAcceptance(_ text: String) -> Bool {
        guard let window, let source = CGEventSource(stateID: .combinedSessionState),
              let strokes = OmarchyHostKeyboardTextEncoder.strokes(for: text) else {
            return false
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(self)
        let leftShiftFlags = CGEventFlags.maskShift.union(CGEventFlags(rawValue: 0x00000002))
        var events: [CGEvent] = []
        for stroke in strokes {
            if stroke.shifted {
                guard let shift = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: true) else { return false }
                shift.type = .flagsChanged
                shift.flags = leftShiftFlags
                events.append(shift)
            }
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: stroke.keyCode, keyDown: keyDown) else { return false }
                event.flags = stroke.shifted ? leftShiftFlags : []
                events.append(event)
            }
            if stroke.shifted {
                guard let shift = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: false) else { return false }
                shift.type = .flagsChanged
                shift.flags = []
                events.append(shift)
            }
        }
        for (index, event) in events.enumerated() {
            event.setIntegerValueField(.eventSourceUserData, value: OmarchyFocusedCommandBridge.acceptanceMarker)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.025) { [weak self] in
                guard let self, let appKitEvent = NSEvent(cgEvent: event) else { return }
                self.deliverAppleUSBEvent(appKitEvent)
            }
        }
        return true
    }

    private func deliverAppleUSBEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            super.keyDown(with: event)
        case .keyUp:
            super.keyUp(with: event)
        case .flagsChanged:
            super.flagsChanged(with: event)
        default:
            break
        }
    }
    #endif

}

enum OmarchyDesktopInputPolicy {
    /// The authenticated Agent/uinput route is the sole Omarchy desktop input
    /// path. When there is no desktop session (firmware, owner setup, lock
    /// screen), leaving the handler unset lets Virtualization.framework's
    /// virtual keyboard serve that different lifecycle surface.
    static func usesGuestAgent(status: VMOmarchyGuestStatus) -> Bool {
        guard status.desktopSessionActive,
              !status.provisioningPending,
              status.capabilities.contains("input-uinput-v1"),
              status.capabilities.contains("desktop-input-v1") else { return false }
        return true
    }
}

struct OmarchyVirtualMachineView: View {
    @Environment(\.openWindow) private var openWindow
    let layout: VMOmarchyWorkspaceLayout
    let profile: VMOmarchyProfile
    @AppStorage("omarchyClipboardEnabled") private var clipboardEnabled = true
    @AppStorage("omarchyMicrophoneEnabled") private var microphoneEnabled = false
    @AppStorage("omarchyNotificationsEnabled") private var notificationsEnabled = false
    @State private var lifecycle = OmarchyMachineLifecycle()
    @State private var sessionID = UUID()
    @State private var keyboardIntegration: OmarchyKeyboardIntegrationState = .accessibilityRequired
    @State private var integration: VMOmarchyIntegrationState = .connecting
    @State private var stopTimeoutTask: Task<Void, Never>?
    @State private var recoveryPoints: [VMOmarchyRecoveryPoint] = []
    @State private var recoveryOperation: RecoveryOperation = .idle
    @State private var prepareUpdateAfterStop = false
    @State private var pendingRestore: VMOmarchyRecoveryPoint?
    @State private var factoryChannel: FactoryChannelViewState = .idle
    @State private var importingFiles = false
    @State private var notice: UserNotice?
    @State private var acceptanceFailure: String?
    @State private var recordedIntegrationSignature = ""
    @State private var sharedFolderProbe: VMOmarchySharedFolderProbeState = .notRun
    @State private var clipboardProbe: OmarchyClipboardProbeState = .notRun
    @State private var dynamicDisplayProbe: OmarchyDynamicDisplayProbeState = .notRun
    @State private var ownerSetupForm = OmarchyOwnerSetupForm()
    @State private var ownerSetupPhase: OmarchyOwnerSetupPhase = .editing
    @State private var ownerProvisioningSubmission: OmarchyOwnerProvisioningSubmission?
    @State private var automaticOwnerProvisioningStarted = false
    @State private var ownerProvisioningDetail: String?

    private var phase: Phase { lifecycle.phase }

    var body: some View {
        ZStack {
            OmarchyVirtualMachineRepresentable(
                layout: layout,
                profile: profile,
                clipboardEnabled: clipboardEnabled,
                notificationsEnabled: notificationsEnabled,
                microphoneEnabled: microphoneEnabled,
                hostOverlayVisible: ownerSetupAvailable || phase != .running,
                sessionID: sessionID,
                keyboardIntegrationChanged: { keyboardIntegration = $0 },
                integrationChanged: handleIntegrationChange,
                sharedFolderProbeChanged: handleSharedFolderProbeChange,
                clipboardProbeChanged: handleClipboardProbeChange,
                dynamicDisplayProbeChanged: handleDynamicDisplayProbeChange,
                ownerProvisioningSubmission: ownerProvisioningSubmission,
                ownerProvisioningCompleted: handleOwnerProvisioningCompletion,
                ownerProvisioningProgressChanged: {
                    ownerProvisioningDetail = $0.displayMessage
                    if ownerSetupPhase == .editing {
                        ownerSetupPhase = .finishing
                    }
                },
                phaseChanged: handlePhaseChange,
                acceptanceFailureChanged: { acceptanceFailure = $0 }
            )
            .id(sessionID)
            if phase != .running {
                statusOverlay
            }
            if ownerSetupAvailable {
                OmarchyOwnerSetupView(
                    form: $ownerSetupForm,
                    phase: ownerSetupPhase,
                    provisioningDetail: ownerProvisioningDetail,
                    submit: submitOwnerSetup
                )
            }
        }
        .background(.black)
        .onAppear {
            OmarchyReleaseReadinessReporter.reportWhenReady(
                workspaceManager: VMOmarchyWorkspaceManager(layout: layout)
            )
        }
        .dropDestination(for: URL.self) { urls, _ in
            importFiles(urls)
            return !urls.isEmpty
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                integrationMenu
                updatesMenu
                recoveryMenu
                Button("Open Shared Folder", systemImage: "folder") {
                    NSWorkspace.shared.open(layout.shared)
                }
                Button("Import Files", systemImage: "square.and.arrow.down") {
                    chooseFilesToImport()
                }
                .disabled(importingFiles)
                if phase == .running {
                    Button("Pause Omarchy", systemImage: "pause.fill") {
                        handle(.pauseRequested)
                    }
                    Button("Restart Omarchy", systemImage: "arrow.clockwise") {
                        handle(.restartRequested)
                    }
                    Button("Stop Omarchy", systemImage: "stop.fill") {
                        handle(.stopRequested)
                    }
                }
                if phase == .paused {
                    Button("Resume Omarchy", systemImage: "play.fill") {
                        handle(.resumeRequested)
                    }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if OmarchyWorkspaceConfiguration.isAcceptanceWorkspace(layout) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(acceptanceFailure == nil ? "Automated acceptance testing" : "Acceptance test failed", systemImage: acceptanceFailure == nil ? "testtube.2" : "exclamationmark.triangle")
                        .font(.headline)
                    Text(acceptanceFailure ?? "This temporary workspace may type, lock, and restart automatically. Keep this window focused while testing.")
                    if acceptanceFailure != nil {
                        Text("The test did not pass. The virtual machine remains available; use its normal controls to continue or stop it.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.orange.opacity(0.18))
            }
            if keyboardIntegration != .enabled {
                HStack {
                    if keyboardIntegration == .requestingAccessibility {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Waiting for Accessibility permission")
                        Text("Turn on RiftVM in System Settings, then return here. If it is already on, remove its old entry and add the current RiftVM app again.")
                    } else if keyboardIntegration == .eventTapUnavailable {
                        Text("Access is allowed, but shortcut capture could not start. Retry, or quit and reopen RiftVM.")
                    } else {
                        Text("Allow Accessibility access so Command shortcuts stay inside Omarchy.")
                    }
                    Spacer()
                    Button(keyboardIntegration == .requestingAccessibility ? "Open System Settings" : keyboardIntegration == .eventTapUnavailable ? "Retry" : "Enable") {
                        NotificationCenter.default.post(name: .omarchyRequestKeyboardPermission, object: sessionID)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.orange.opacity(0.18))
            }
        }
        .onChange(of: sessionID) { _, _ in acceptanceFailure = nil }
        .onDisappear {
            stopTimeoutTask?.cancel()
            stopTimeoutTask = nil
        }
        .onAppear { refreshRecoveryPoints() }
        .confirmationDialog(
            "Restore \(pendingRestore?.name ?? "this recovery point")?",
            isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Restore Omarchy", role: .destructive) {
                guard let point = pendingRestore else { return }
                pendingRestore = nil
                restore(point)
            }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: {
            Text("Changes made inside Omarchy since this recovery point will be replaced. Create a backup first if you need to keep them. Omarchy must remain stopped until recovery finishes.")
        }
        .alert(item: $notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    @ViewBuilder
    private var integrationMenu: some View {
        Menu {
            switch integration {
            case .connecting:
                Text("Connecting to Guest Agent…")
            case .authenticating:
                Text("Authenticating Guest Agent…")
            case .disconnected(let reason):
                Text("Guest Agent unavailable")
                Text(reason).foregroundStyle(.secondary)
            case .ready(let status):
                Text("Agent \(status.agentVersion) • \(status.hostName)")
                let assessment = VMOmarchyIntegrationAssessment.evaluate(
                    status: status,
                    requiredCapabilities: profile.requiredGuestCapabilities
                )
                if assessment.provisioningPending {
                    Text("Complete Omarchy owner setup")
                } else if !assessment.desktopSessionActive {
                    Text("Waiting for Omarchy desktop")
                } else if !assessment.missingCapabilities.isEmpty {
                    Text("Missing: \(assessment.missingCapabilities.joined(separator: ", "))")
                } else {
                    Text("Omarchy desktop integration ready")
                }
                if !status.addresses.isEmpty { Text(status.addresses.joined(separator: ", ")) }
                if status.capabilities.contains("shared-folders-v1") {
                    Text("Shared folder mounted at /mnt/riftvm-shared")
                } else {
                    Text("Shared folder is not mounted in Omarchy")
                }
                if !clipboardEnabled {
                    Text("Clipboard sharing is off")
                } else if status.capabilities.contains("clipboard-agent-text-v1") {
                    Text(status.capabilities.contains("clipboard-agent-image-v1")
                        ? "Authenticated text and image clipboard ready"
                        : "Authenticated text clipboard ready")
                } else if status.capabilities.contains("clipboard-text-v1") {
                    Text(status.capabilities.contains("clipboard-image-v1")
                        ? "Text and image clipboard ready (compatibility mode)"
                        : "Text clipboard ready (compatibility mode)")
                } else {
                    Text("Clipboard session integration is not ready")
                }
                Text("Capabilities: \(status.capabilities.sorted().joined(separator: ", "))")
            }
            Divider()
            Toggle("Share Clipboard", isOn: $clipboardEnabled)
            Toggle("Mirror Notifications to macOS", isOn: notificationsBinding)
            Text(notificationsEnabled
                ? "Omarchy notifications appear in macOS Notification Center"
                : "Notification mirroring is off")
            Toggle("Share Mac Microphone", isOn: microphoneBinding)
            Text(microphoneEnabled
                ? "Microphone will be available after Omarchy restarts"
                : "Microphone sharing is off")
            Divider()
            Button("Export Diagnostics…", systemImage: "square.and.arrow.up") {
                exportDiagnostics()
            }
        } label: {
            Label("Integration", systemImage: integrationReady ? "checkmark.circle.fill" : "exclamationmark.circle")
        }
        .help(integrationReady ? "Omarchy integration is ready" : "Omarchy integration is not ready")
    }

    @ViewBuilder
    private var recoveryMenu: some View {
        Menu {
            switch recoveryOperation {
            case .idle:
                if phase == .stopped {
                    Button("Create Protected Backup", systemImage: "externaldrive.badge.plus") {
                        createProtectedBackup()
                    }
                } else {
                    Text("Stop Omarchy to create or restore backups")
                }
            case .working(let message):
                Text(message)
            case .failed(let message):
                Text(message)
                Button("Dismiss") { recoveryOperation = .idle }
            }
            if !recoveryPoints.isEmpty {
                Divider()
                ForEach(recoveryPoints) { point in
                    Button {
                        pendingRestore = point
                    } label: {
                        Label("\(point.name) · \(point.createdAt.formatted(date: .abbreviated, time: .shortened))", systemImage: point.isProtected ? "lock.shield" : "clock.arrow.circlepath")
                    }
                    .disabled(phase != .stopped || recoveryOperation.isWorking)
                }
            }
        } label: {
            Label("Recovery", systemImage: recoveryOperation.isFailed ? "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90" : "clock.arrow.circlepath")
        }
        .help("Create or restore protected Omarchy recovery points")
    }

    private var integrationReady: Bool {
        if case .ready(let status) = integration {
            return VMOmarchyIntegrationAssessment.evaluate(
                status: status,
                requiredCapabilities: profile.requiredGuestCapabilities
            ).isReady
        }
        return false
    }

    private var microphoneBinding: Binding<Bool> {
        Binding(
            get: { microphoneEnabled },
            set: { enabled in
                requestMicrophoneSharing(enabled)
            }
        )
    }

    private var notificationsBinding: Binding<Bool> {
        Binding(
            get: { notificationsEnabled },
            set: { enabled in requestNotificationMirroring(enabled) }
        )
    }

    private func requestNotificationMirroring(_ enabled: Bool) {
        guard enabled != notificationsEnabled else { return }
        guard enabled else {
            notificationsEnabled = false
            return
        }
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch OmarchyNotificationPermissionPolicy.action(for: settings.authorizationStatus) {
            case .enable:
                notificationsEnabled = true
            case .request:
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) == true
                notificationsEnabled = granted
                if !granted { explainDeniedNotificationAccess() }
            case .openSystemSettings:
                explainDeniedNotificationAccess()
            }
        }
    }

    private func explainDeniedNotificationAccess() {
        notificationsEnabled = false
        notice = UserNotice(
            title: "Notification Access Is Off",
            message: "Allow RiftVM Omarchy in System Settings → Notifications, then enable mirroring again."
        )
        NSWorkspace.shared.open(OmarchyNotificationPermissionPolicy.settingsURL)
    }

    private func requestMicrophoneSharing(_ enabled: Bool) {
        guard enabled != microphoneEnabled else { return }
        guard enabled else {
            applyMicrophoneSharing(false)
            return
        }
        switch OmarchyMicrophonePermissionPolicy.action(
            for: AVCaptureDevice.authorizationStatus(for: .audio)
        ) {
        case .enable:
            applyMicrophoneSharing(true)
        case .request:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    if granted {
                        applyMicrophoneSharing(true)
                    } else {
                        explainDeniedMicrophoneAccess(openSettings: true)
                    }
                }
            }
        case .openSystemSettings:
            explainDeniedMicrophoneAccess(openSettings: true)
        }
    }

    private func applyMicrophoneSharing(_ enabled: Bool) {
        microphoneEnabled = enabled
        guard phase == .running || phase == .paused else { return }
        notice = UserNotice(
            title: "Restart Omarchy to Apply",
            message: enabled
                ? "Restart Omarchy to make the Mac microphone available to Linux applications."
                : "Restart Omarchy to remove the Mac microphone from the virtual machine."
        )
    }

    private func explainDeniedMicrophoneAccess(openSettings: Bool) {
        microphoneEnabled = false
        notice = UserNotice(
            title: "Microphone Access Is Off",
            message: "Allow RiftVM Omarchy under Privacy & Security → Microphone, then enable sharing again."
        )
        if openSettings {
            NSWorkspace.shared.open(OmarchyMicrophonePermissionPolicy.settingsURL)
        }
    }

    private var ownerSetupAvailable: Bool {
        guard phase == .running else { return false }
        guard case .ready(let status) = integration else { return false }
        return status.provisioningPending && status.capabilities.contains("owner-provisioning-v1")
    }

    private func submitOwnerSetup() {
        guard ownerSetupPhase != .submitting, ownerSetupPhase != .finishing else { return }
        do {
            let request = try ownerSetupForm.validatedRequest()
            ownerSetupPhase = .submitting
            ownerProvisioningSubmission = .init(request: request)
        } catch {
            ownerSetupPhase = .failed(error.localizedDescription)
        }
    }

    private func handleOwnerProvisioningCompletion(_ id: UUID, _ errorMessage: String?) {
        guard ownerProvisioningSubmission?.id == id else { return }
        ownerProvisioningSubmission = nil
        if let errorMessage {
            ownerSetupPhase = .failed(errorMessage)
        } else {
            ownerSetupForm.clearSecrets()
            ownerSetupPhase = .finishing
        }
    }

    @ViewBuilder
    private var updatesMenu: some View {
        Menu {
            Button("Download RiftVM Update", systemImage: "arrow.down.app") {
                NSWorkspace.shared.open(URL(string: "https://github.com/riftvm/riftvm/releases/latest")!)
            }
            Text("Homebrew users: brew upgrade --cask riftvm")
            Divider()
            Button("Prepare for Omarchy Update…", systemImage: "lock.shield") {
                if phase == .stopped {
                    createProtectedBackup(forUpdate: true)
                } else {
                    prepareUpdateAfterStop = true
                    handle(.stopRequested)
                }
            }
            .disabled(recoveryOperation.isWorking || !(phase == .running || phase == .paused || phase == .stopped))
            Text("Stops Omarchy and creates a protected recovery point before you update inside the guest.")
            Divider()
            switch factoryChannel {
            case .idle:
                Button("Check Signed Factory Channel", systemImage: "checkmark.shield") {
                    checkFactoryChannel()
                }
            case .checking:
                Text("Checking signed factory metadata…")
            case .current(let version):
                Text("Installed from current factory \(version)")
                Button("Check Again") { checkFactoryChannel() }
            case .untracked(let available):
                Text("Current workspace has no recorded factory version")
                Text("Signed channel factory: \(available)")
                Text("Factory images are only used for new installs and recovery.")
                Button("Check Again") { checkFactoryChannel() }
            case .different(let installed, let available):
                Text("Workspace factory: \(installed)")
                Text("Signed channel factory: \(available)")
                Text("Use a fresh workspace to try the channel image. Your existing workspace is kept.")
                Button("Check Again") { checkFactoryChannel() }
            case .failed(let message):
                Text(message)
                Button("Try Again") { checkFactoryChannel() }
            }
            Divider()
            Button("Create Workspace from Latest Image…", systemImage: "plus.rectangle.on.folder") {
                openWindow(id: "create-machine-guide", value: RiftWorkspaceKind.omarchy)
            }
            Text("Downloads and verifies the signed image during creation. Move your files using Shared Folder after checking the new workspace.")
        } label: {
            Label("Updates", systemImage: factoryChannel.needsAttention ? "arrow.down.circle.fill" : "arrow.triangle.2.circlepath")
        }
        .help("App, factory-image, and guest update status")
    }

    private func checkFactoryChannel() {
        guard factoryChannel != .checking else { return }
        guard let publicKey = FactoryTrustConfiguration.publicKey() else {
            factoryChannel = .failed("This build has no trusted factory signing key.")
            return
        }
        let workspace = VMOmarchyWorkspaceManager(layout: layout)
        let installedVersion = try? workspace.metadata().factoryImageVersion
        let installer = VMOmarchyFactoryInstaller(
            profile: profile,
            cacheDirectory: layout.cache,
            publicKey: publicKey,
            transport: VMOmarchyURLSessionTransport()
        )
        factoryChannel = .checking
        Task {
            do {
                let manifest = try await installer.fetchVerifiedManifest()
                switch VMOmarchyFactoryChannelState.assess(
                    installedVersion: installedVersion,
                    manifest: manifest
                ) {
                case .current(let version): factoryChannel = .current(version)
                case .untracked(let available): factoryChannel = .untracked(available)
                case .different(let installed, let available):
                    factoryChannel = .different(installed: installed, available: available)
                }
            } catch {
                factoryChannel = .failed(error.localizedDescription)
            }
        }
    }

    private func handleIntegrationChange(_ state: VMOmarchyIntegrationState) {
        integration = state
        guard case .ready(let status) = state else { return }
        startAutomaticOwnerProvisioningIfNeeded(status)
        if !status.provisioningPending {
            ownerSetupForm.clearSecrets()
            ownerProvisioningSubmission = nil
            ownerSetupPhase = .editing
            ownerProvisioningDetail = nil
        }
        OmarchyAcceptanceObservationReporter.reportIfEnabled(
            status: status,
            requiredCapabilities: profile.requiredGuestCapabilities,
            layout: layout,
            sharedFolderRoundTrip: sharedFolderRoundTrip,
            clipboardRoundTrip: clipboardRoundTrip,
            dynamicDisplayRoundTrip: dynamicDisplayRoundTrip
        )
        let signature = ([status.omarchyRevision ?? "", status.agentVersion]
            + status.capabilities.sorted()).joined(separator: "\u{1f}")
        guard signature != recordedIntegrationSignature else { return }
        recordedIntegrationSignature = signature
        let manager = VMOmarchyWorkspaceManager(layout: layout)
        omarchyMetadataQueue.async {
            do {
                try manager.recordGuestIntegration(
                    omarchyRevision: status.omarchyRevision,
                    agentVersion: status.agentVersion,
                    capabilities: status.capabilities
                )
            } catch {
                NSLog("Could not record Omarchy integration metadata: %@", error.localizedDescription)
            }
        }
    }

    private func startAutomaticOwnerProvisioningIfNeeded(_ status: VMOmarchyGuestStatus) {
        guard status.provisioningPending,
              status.capabilities.contains("owner-provisioning-v1"),
              !automaticOwnerProvisioningStarted,
              OmarchyWorkspaceConfiguration.isAcceptanceWorkspace(layout),
              let password = OmarchyWorkspaceConfiguration.acceptanceOwnerProvisioningPassword()
        else { return }

        automaticOwnerProvisioningStarted = true
        var form = ownerSetupForm
        form.password = password
        form.passwordConfirmation = password
        do {
            let request = try form.validatedRequest()
            ownerSetupForm = form
            ownerSetupPhase = .submitting
            ownerProvisioningSubmission = .init(request: request)
        } catch {
            form.clearSecrets()
            ownerSetupForm = form
            ownerSetupPhase = .failed(error.localizedDescription)
        }
    }

    private var sharedFolderRoundTrip: VMOmarchySharedFolderRoundTrip? {
        guard case .passed(let result) = sharedFolderProbe else { return nil }
        return result
    }

    private func handleSharedFolderProbeChange(_ state: VMOmarchySharedFolderProbeState) {
        sharedFolderProbe = state
        guard case .ready(let status) = integration else { return }
        OmarchyAcceptanceObservationReporter.reportIfEnabled(
            status: status,
            requiredCapabilities: profile.requiredGuestCapabilities,
            layout: layout,
            sharedFolderRoundTrip: sharedFolderRoundTrip,
            clipboardRoundTrip: clipboardRoundTrip,
            dynamicDisplayRoundTrip: dynamicDisplayRoundTrip
        )
    }

    private var clipboardRoundTrip: OmarchyClipboardRoundTrip? {
        guard case .passed(let result) = clipboardProbe else { return nil }
        return result
    }

    private func handleClipboardProbeChange(_ state: OmarchyClipboardProbeState) {
        clipboardProbe = state
        guard case .ready(let status) = integration else { return }
        OmarchyAcceptanceObservationReporter.reportIfEnabled(
            status: status,
            requiredCapabilities: profile.requiredGuestCapabilities,
            layout: layout,
            sharedFolderRoundTrip: sharedFolderRoundTrip,
            clipboardRoundTrip: clipboardRoundTrip,
            dynamicDisplayRoundTrip: dynamicDisplayRoundTrip
        )
    }

    private var dynamicDisplayRoundTrip: OmarchyDynamicDisplayRoundTrip? {
        guard case .passed(let result) = dynamicDisplayProbe else { return nil }
        return result
    }

    private func handleDynamicDisplayProbeChange(_ state: OmarchyDynamicDisplayProbeState) {
        dynamicDisplayProbe = state
        guard case .ready(let status) = integration else { return }
        OmarchyAcceptanceObservationReporter.reportIfEnabled(
            status: status,
            requiredCapabilities: profile.requiredGuestCapabilities,
            layout: layout,
            sharedFolderRoundTrip: sharedFolderRoundTrip,
            clipboardRoundTrip: clipboardRoundTrip,
            dynamicDisplayRoundTrip: dynamicDisplayRoundTrip
        )
    }

    private func chooseFilesToImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Import into Omarchy"
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.title = "Export RiftVM Omarchy Diagnostics"
        let date = ISO8601DateFormatter().string(from: Date()).prefix(10)
        panel.nameFieldStringValue = "RiftVM-Omarchy-Diagnostics-\(date).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            let report = VMOmarchyDiagnostics().report(
                layout: layout,
                appVersion: appVersion,
                integrationState: integration
            )
            try report.encoded().write(to: destination, options: .atomic)
            notice = UserNotice(title: "Diagnostics Exported", message: destination.lastPathComponent)
        } catch {
            notice = UserNotice(title: "Diagnostics Export Failed", message: error.localizedDescription)
        }
    }

    private func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty, !importingFiles else { return }
        importingFiles = true
        let importer = VMOmarchySharedFolderImporter(layout: layout)
        DispatchQueue.global(qos: .userInitiated).async {
            let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
            defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
            let result = Result { try importer.importFiles(urls) }
            DispatchQueue.main.async {
                importingFiles = false
                switch result {
                case .success(let files):
                    let names = files.map(\.destinationURL.lastPathComponent).joined(separator: ", ")
                    notice = UserNotice(
                        title: "Files Ready in Omarchy",
                        message: "Imported \(files.count) file(s): \(names). Open /mnt/riftvm-shared in Omarchy."
                    )
                case .failure(let error):
                    notice = UserNotice(title: "Import Failed", message: error.localizedDescription)
                }
            }
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch phase {
        case .starting:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Starting Omarchy…").font(.headline)
            }
            .padding(26)
            .background(.regularMaterial, in: .rect(cornerRadius: 14))
        case .running:
            EmptyView()
        case .pausing:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Pausing Omarchy…").font(.headline)
            }
            .padding(26)
            .background(.regularMaterial, in: .rect(cornerRadius: 14))
        case .paused:
            VStack(spacing: 14) {
                Text("Omarchy is paused").font(.headline)
                Button("Resume Omarchy", systemImage: "play.fill") {
                    handle(.resumeRequested)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(26)
            .background(.regularMaterial, in: .rect(cornerRadius: 14))
        case .resuming:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Resuming Omarchy…").font(.headline)
            }
            .padding(26)
            .background(.regularMaterial, in: .rect(cornerRadius: 14))
        case .stopping:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Stopping Omarchy…").font(.headline)
            }
            .padding(26)
            .background(.regularMaterial, in: .rect(cornerRadius: 14))
        case .stopped:
            VStack(spacing: 14) {
                Text("Omarchy is stopped").font(.headline)
                if case .working(let message) = recoveryOperation {
                    ProgressView(message)
                }
                if case .failed(let message) = recoveryOperation {
                    Text(message).foregroundStyle(.secondary)
                    Button("Dismiss Recovery Error") { recoveryOperation = .idle }
                }
                Button("Start Omarchy", systemImage: "play.fill") {
                    handle(.startRequested)
                }
                .buttonStyle(.borderedProminent)
                .disabled(recoveryOperation.isWorking)
            }
            .padding(26)
            .background(.regularMaterial, in: .rect(cornerRadius: 14))
        case .failed(let message):
            VStack(spacing: 14) {
                ContentUnavailableView(
                    "Omarchy needs attention",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
                .padding(30)
                .background(.regularMaterial)
                Button("Stop and Enable Recovery", systemImage: "stop.fill") {
                    handle(.stopRequested)
                }
                .buttonStyle(.borderedProminent)
                Text("Once stopped, retry Start Omarchy or restore a recovery point from Recovery.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func handlePhaseChange(_ phase: Phase) {
        switch phase {
        case .running: handle(.machineStarted)
        case .paused: handle(.machinePaused)
        case .stopped:
            handle(.machineStopped)
            refreshRecoveryPoints()
            if prepareUpdateAfterStop {
                prepareUpdateAfterStop = false
                createProtectedBackup(forUpdate: true)
            }
        case .failed(let message):
            prepareUpdateAfterStop = false
            handle(.machineFailed(message))
        case .starting, .pausing, .resuming, .stopping: break
        }
    }

    private func refreshRecoveryPoints() {
        recoveryPoints = VMOmarchyRecoveryManager(
            workspaceManager: VMOmarchyWorkspaceManager(layout: layout)
        ).recoveryPoints()
    }

    private func createProtectedBackup(forUpdate: Bool = false) {
        guard phase == .stopped, !recoveryOperation.isWorking else { return }
        recoveryOperation = .working("Creating protected backup…")
        let manager = VMOmarchyRecoveryManager(
            workspaceManager: VMOmarchyWorkspaceManager(layout: layout)
        )
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try manager.createProtectedBackup(name: forUpdate ? "Before Omarchy update" : "Protected backup") }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    recoveryOperation = .idle
                    refreshRecoveryPoints()
                    notice = UserNotice(title: "Recovery Point Created", message: forUpdate
                        ? "Start Omarchy, then choose Update in the Omarchy menu. If the update fails, stop Omarchy and choose Before Omarchy update in Recovery. Keep this recovery point until you have checked the updated system."
                        : "Your recovery point is ready. To restore it later, stop Omarchy and select it in Recovery.")
                case .failure(let error):
                    recoveryOperation = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func restore(_ point: VMOmarchyRecoveryPoint) {
        guard phase == .stopped, !recoveryOperation.isWorking else { return }
        recoveryOperation = .working("Restoring \(point.name)…")
        let manager = VMOmarchyRecoveryManager(
            workspaceManager: VMOmarchyWorkspaceManager(layout: layout)
        )
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try manager.restore(id: point.id) }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    recoveryOperation = .idle
                    refreshRecoveryPoints()
                    factoryChannel = .idle
                    notice = UserNotice(title: "Recovery Complete", message: "Your workspace has been restored. Choose Start Omarchy to use it.")
                case .failure(let error):
                    recoveryOperation = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func handle(_ event: OmarchyMachineLifecycle.Event) {
        for effect in lifecycle.handle(event) {
            switch effect {
            case .requestStop:
                NotificationCenter.default.post(name: .omarchyRequestStop, object: sessionID)
            case .requestPause:
                NotificationCenter.default.post(name: .omarchyRequestPause, object: sessionID)
            case .requestResume:
                NotificationCenter.default.post(name: .omarchyRequestResume, object: sessionID)
            case .startNewSession:
                sessionID = UUID()
            case .scheduleForceStop:
                stopTimeoutTask?.cancel()
                stopTimeoutTask = Task {
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled else { return }
                    await MainActor.run { handle(.stopTimedOut) }
                }
            case .cancelForceStop:
                stopTimeoutTask?.cancel()
                stopTimeoutTask = nil
            case .forceStop:
                NotificationCenter.default.post(name: .omarchyForceStop, object: sessionID)
            }
        }
    }

    enum Phase: Equatable {
        case starting
        case running
        case pausing
        case paused
        case resuming
        case stopping
        case stopped
        case failed(String)
    }

    private enum RecoveryOperation: Equatable {
        case idle
        case working(String)
        case failed(String)

        var isWorking: Bool {
            if case .working = self { return true }
            return false
        }

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    private enum FactoryChannelViewState: Equatable {
        case idle
        case checking
        case current(String)
        case untracked(String)
        case different(installed: String, available: String)
        case failed(String)

        var needsAttention: Bool {
            switch self {
            case .untracked, .different, .failed: true
            case .idle, .checking, .current: false
            }
        }
    }

    private struct UserNotice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }
}

enum OmarchyMicrophonePermissionAction: Equatable {
    case enable
    case request
    case openSystemSettings
}

enum OmarchyMicrophonePermissionPolicy {
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    )!

    static func action(for status: AVAuthorizationStatus) -> OmarchyMicrophonePermissionAction {
        switch status {
        case .authorized: .enable
        case .notDetermined: .request
        case .denied, .restricted: .openSystemSettings
        @unknown default: .openSystemSettings
        }
    }
}

enum OmarchyClipboardActivationPolicy {
    static func shouldRun(
        enabled: Bool,
        capabilities: Set<String>,
        desktopSessionActive: Bool,
        provisioningPending: Bool,
        probeOwnsTransport: Bool
    ) -> Bool {
        enabled
            && !probeOwnsTransport
            && desktopSessionActive
            && !provisioningPending
            && Set(["clipboard-agent-text-v1", "clipboard-agent-image-v1"])
                .isSubset(of: capabilities)
    }
}

struct OmarchyMachineLifecycle: Equatable {
    var phase: OmarchyVirtualMachineView.Phase = .starting
    private(set) var restartAfterStop = false

    enum Event: Equatable {
        case machineStarted
        case pauseRequested
        case machinePaused
        case resumeRequested
        case startRequested
        case stopRequested
        case restartRequested
        case machineStopped
        case machineFailed(String)
        case stopTimedOut
    }

    enum Effect: Equatable {
        case requestStop
        case requestPause
        case requestResume
        case startNewSession
        case scheduleForceStop
        case cancelForceStop
        case forceStop
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .machineStarted:
            phase = .running
        case .pauseRequested:
            guard phase == .running else { return [] }
            phase = .pausing
            return [.requestPause]
        case .machinePaused:
            guard phase == .pausing else { return [] }
            phase = .paused
        case .resumeRequested:
            guard phase == .paused else { return [] }
            phase = .resuming
            return [.requestResume]
        case .startRequested:
            guard phase == .stopped || isFailed else { return [] }
            restartAfterStop = false
            phase = .starting
            return [.startNewSession]
        case .stopRequested:
            guard phase == .running || phase == .paused || isFailed else { return [] }
            restartAfterStop = false
            phase = .stopping
            return [.requestStop, .scheduleForceStop]
        case .restartRequested:
            guard phase == .running || phase == .paused else { return [] }
            restartAfterStop = true
            phase = .stopping
            return [.requestStop, .scheduleForceStop]
        case .machineStopped:
            if restartAfterStop {
                restartAfterStop = false
                phase = .starting
                return [.cancelForceStop, .startNewSession]
            }
            phase = .stopped
            return [.cancelForceStop]
        case .machineFailed(let message):
            restartAfterStop = false
            phase = .failed(message)
            return [.cancelForceStop]
        case .stopTimedOut:
            guard phase == .stopping else { return [] }
            return [.forceStop]
        }
        return []
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }
}

struct OmarchyVirtualMachineRepresentable: NSViewRepresentable {
    let layout: VMOmarchyWorkspaceLayout
    let profile: VMOmarchyProfile
    let clipboardEnabled: Bool
    let notificationsEnabled: Bool
    let microphoneEnabled: Bool
    let hostOverlayVisible: Bool
    let sessionID: UUID
    let keyboardIntegrationChanged: (OmarchyKeyboardIntegrationState) -> Void
    let integrationChanged: (VMOmarchyIntegrationState) -> Void
    let sharedFolderProbeChanged: (VMOmarchySharedFolderProbeState) -> Void
    let clipboardProbeChanged: (OmarchyClipboardProbeState) -> Void
    let dynamicDisplayProbeChanged: (OmarchyDynamicDisplayProbeState) -> Void
    let ownerProvisioningSubmission: OmarchyOwnerProvisioningSubmission?
    let ownerProvisioningCompleted: (UUID, String?) -> Void
    let ownerProvisioningProgressChanged: (VMOmarchyOwnerProvisioningProgress) -> Void
    let phaseChanged: (OmarchyVirtualMachineView.Phase) -> Void
    let acceptanceFailureChanged: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            sessionID: sessionID,
            layout: layout,
            requiredGuestCapabilities: profile.requiredGuestCapabilities,
            clipboardEnabled: clipboardEnabled,
            notificationsEnabled: notificationsEnabled,
            keyboardIntegrationChanged: keyboardIntegrationChanged,
            integrationChanged: integrationChanged,
            sharedFolderProbeChanged: sharedFolderProbeChanged,
            clipboardProbeChanged: clipboardProbeChanged,
            dynamicDisplayProbeChanged: dynamicDisplayProbeChanged,
            ownerProvisioningCompleted: ownerProvisioningCompleted,
            ownerProvisioningProgressChanged: ownerProvisioningProgressChanged,
            phaseChanged: phaseChanged,
            acceptanceFailureChanged: acceptanceFailureChanged
        )
    }

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = OmarchyVirtualMachineInputView()
        view.capturesSystemKeys = true
        view.setHostOverlayVisible(hostOverlayVisible)
        view.automaticallyReconfiguresDisplay = true
        do {
            let configuration = try VMOmarchyVirtualMachineBuilder.makeConfiguration(
                layout: layout,
                profile: profile,
                microphoneEnabled: microphoneEnabled
            )
            let machine = VZVirtualMachine(configuration: configuration)
            machine.delegate = context.coordinator
            context.coordinator.machine = machine
            context.coordinator.machineView = view
            OmarchyApplicationTerminationController.shared.register(machine)
            context.coordinator.beginObservingCommands()
            view.virtualMachine = machine
            context.coordinator.installKeyboardBridge(for: view)
            context.coordinator.start(
                machine,
                in: view,
                profile: profile,
                microphoneEnabled: microphoneEnabled,
                permitsEFIVariableStoreRecovery: true
            )
        } catch {
            DispatchQueue.main.async {
                context.coordinator.phaseChanged(.failed(error.localizedDescription))
            }
        }
        return view
    }

    func updateNSView(_ nsView: VZVirtualMachineView, context: Context) {
        (nsView as? OmarchyVirtualMachineInputView)?.setHostOverlayVisible(hostOverlayVisible)
        context.coordinator.setClipboardEnabled(clipboardEnabled)
        context.coordinator.setNotificationsEnabled(notificationsEnabled)
        if let ownerProvisioningSubmission {
            context.coordinator.submitOwnerProvisioning(ownerProvisioningSubmission)
        }
    }

    static func dismantleNSView(_ nsView: VZVirtualMachineView, coordinator: Coordinator) {
        coordinator.stopImmediately()
        nsView.virtualMachine = nil
    }

    final class Coordinator: NSObject, VZVirtualMachineDelegate {
        var machine: VZVirtualMachine?
        let sessionID: UUID
        let layout: VMOmarchyWorkspaceLayout
        let requiredGuestCapabilities: [String]
        var clipboardEnabled: Bool
        var notificationsEnabled: Bool
        let keyboardIntegrationChanged: (OmarchyKeyboardIntegrationState) -> Void
        let integrationChanged: (VMOmarchyIntegrationState) -> Void
        let sharedFolderProbeChanged: (VMOmarchySharedFolderProbeState) -> Void
        let clipboardProbeChanged: (OmarchyClipboardProbeState) -> Void
        let dynamicDisplayProbeChanged: (OmarchyDynamicDisplayProbeState) -> Void
        let ownerProvisioningCompleted: (UUID, String?) -> Void
        let ownerProvisioningProgressChanged: (VMOmarchyOwnerProvisioningProgress) -> Void
        let phaseChanged: (OmarchyVirtualMachineView.Phase) -> Void
        let acceptanceFailureChanged: (String) -> Void

        func start(
            _ machine: VZVirtualMachine,
            in view: VZVirtualMachineView,
            profile: VMOmarchyProfile,
            microphoneEnabled: Bool,
            permitsEFIVariableStoreRecovery: Bool
        ) {
            machine.start { [weak self, weak view] result in
                DispatchQueue.main.async {
                    guard let self, let view else { return }
                    switch result {
                    case .success:
                        self.startIntegration(layout: self.layout)
                        self.startBootUnlockAcceptanceIfNeeded()
                        self.phaseChanged(.running)
                    case .failure(let error):
                        guard permitsEFIVariableStoreRecovery,
                              VMEFIVariableStoreRecovery.isInvalidBootLoaderError(error.localizedDescription) else {
                            self.phaseChanged(.failed(error.localizedDescription))
                            return
                        }
                        do {
                            let backup = try VMEFIVariableStoreRecovery.replaceRejectedStore(
                                at: self.layout.efiVariableStore
                            )
                            RiftVMLog.info(
                                "Rejected Omarchy EFI variable store was replaced; backup: \(backup?.path ?? "none")"
                            )
                            OmarchyApplicationTerminationController.shared.unregister(machine)
                            let configuration = try VMOmarchyVirtualMachineBuilder.makeConfiguration(
                                layout: self.layout,
                                profile: profile,
                                microphoneEnabled: microphoneEnabled
                            )
                            let replacement = VZVirtualMachine(configuration: configuration)
                            replacement.delegate = self
                            self.machine = replacement
                            view.virtualMachine = replacement
                            OmarchyApplicationTerminationController.shared.register(replacement)
                            self.start(
                                replacement,
                                in: view,
                                profile: profile,
                                microphoneEnabled: microphoneEnabled,
                                permitsEFIVariableStoreRecovery: false
                            )
                        } catch {
                            self.phaseChanged(.failed(error.localizedDescription))
                        }
                    }
                }
            }
        }
        var stopObserver: NSObjectProtocol?
        var pauseObserver: NSObjectProtocol?
        var resumeObserver: NSObjectProtocol?
        var keyboardPermissionObserver: NSObjectProtocol?
        var forceStopObserver: NSObjectProtocol?
        var keyboardBridge: OmarchyFocusedCommandBridge?
        var integrationClient: VMOmarchyGuestAgentClient?
        var agentClipboardController: OmarchyAgentClipboardController?
        var notificationController: OmarchyNotificationController?
        var notificationAcceptanceProbeTask: Task<Void, Never>?
        var notificationAcceptanceProbeStarted = false
        var notificationAcceptanceProbeCompleted = false
        var expectedAcceptanceNotificationTitle: String?
        var latestGuestStatus: VMOmarchyGuestStatus?
        var clipboardProbeOwnsTransport = false
        var sharedFolderProbeTask: Task<Void, Never>?
        var sharedFolderProbePassed = false
        var clipboardProbeTask: Task<Void, Never>?
        var clipboardProbePassed = false
        weak var machineView: VZVirtualMachineView?
        var dynamicDisplayProbeTask: Task<Void, Never>?
        var inputLatencyProbeTask: Task<Void, Never>?
        var inputLatencyProbeStarted = false
        var continuousInputProbeTask: Task<Void, Never>?
        var continuousInputProbeStarted = false
        var lockProbeTask: Task<Void, Never>?
        var bootUnlockAcceptanceStarted = false
        var dynamicDisplayProbePassed = false
        var acceptanceFailureRecorded = false
        var acceptanceEnabled: Bool {
            !acceptanceFailureRecorded && OmarchyWorkspaceConfiguration.isAcceptanceWorkspace(layout)
        }

        func reportAcceptanceFailure(_ message: String) {
            guard !acceptanceFailureRecorded else { return }
            acceptanceFailureRecorded = true
            automaticRecoveryStage = .idle
            lockProbeTask?.cancel()
            inputLatencyProbeTask?.cancel()
            continuousInputProbeTask?.cancel()
            notificationAcceptanceProbeTask?.cancel()
            sharedFolderProbeTask?.cancel()
            clipboardProbeTask?.cancel()
            dynamicDisplayProbeTask?.cancel()
            guestRestartUnlockTimeoutTask?.cancel()
            hostWakeInteractiveTask?.cancel()
            NSLog("Omarchy acceptance failed (VM lifecycle unchanged): %@", message)
            let report: [String: Any] = [
                "schemaVersion": 1, "result": "failed", "message": message,
                "observedAt": ISO8601DateFormatter().string(from: Date()),
            ]
            do {
                try FileManager.default.createDirectory(at: layout.diagnostics, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: layout.diagnostics.appending(path: "acceptance-failure.json"), options: .atomic)
            } catch {
                NSLog("Could not save acceptance failure: %@", error.localizedDescription)
            }
            acceptanceFailureChanged(message)
        }

        var automaticLockProbe = OmarchyLockAcceptanceState()
        var automaticPauseResumeProbeStarted = false
        var automaticRecoveryAfterResume = false
        var automaticRecoveryStage = AutomaticRecoveryStage.idle
        var recoveryBaselineStatus: VMOmarchyGuestStatus?
        var guestRestartAcceptanceState = OmarchyGuestRestartAcceptanceState()
        var guestRestartUnlockTimeoutTask: Task<Void, Never>?
        var hostWakeInteractiveTask: Task<Void, Never>?
        var automaticCommandSpaceProbeStarted = false
        var automaticFullScreenProbeStarted = false
        #if RIFTVM_ACCEPTANCE_HARNESS
        var fullScreenProbe: OmarchyFullScreenAcceptanceProbe?
        #endif
        var lastOwnerProvisioningSubmissionID: UUID?
        var ownerProgressFetchInFlight = false

        enum AutomaticRecoveryStage {
            case idle
            case waitingForPostResumeReady
            case waitingForAgentDisconnect
            case waitingForAgentReady
            case waitingForGuestDisconnect
            case waitingForGuestReady
            case complete
        }

        init(
            sessionID: UUID,
            layout: VMOmarchyWorkspaceLayout,
            requiredGuestCapabilities: [String],
            clipboardEnabled: Bool,
            notificationsEnabled: Bool,
            keyboardIntegrationChanged: @escaping (OmarchyKeyboardIntegrationState) -> Void,
            integrationChanged: @escaping (VMOmarchyIntegrationState) -> Void,
            sharedFolderProbeChanged: @escaping (VMOmarchySharedFolderProbeState) -> Void,
            clipboardProbeChanged: @escaping (OmarchyClipboardProbeState) -> Void,
            dynamicDisplayProbeChanged: @escaping (OmarchyDynamicDisplayProbeState) -> Void,
            ownerProvisioningCompleted: @escaping (UUID, String?) -> Void,
            ownerProvisioningProgressChanged: @escaping (VMOmarchyOwnerProvisioningProgress) -> Void,
            phaseChanged: @escaping (OmarchyVirtualMachineView.Phase) -> Void,
            acceptanceFailureChanged: @escaping (String) -> Void = { _ in }
        ) {
            self.sessionID = sessionID
            self.layout = layout
            self.requiredGuestCapabilities = requiredGuestCapabilities
            self.clipboardEnabled = clipboardEnabled
            self.notificationsEnabled = notificationsEnabled
            self.keyboardIntegrationChanged = keyboardIntegrationChanged
            self.integrationChanged = integrationChanged
            self.sharedFolderProbeChanged = sharedFolderProbeChanged
            self.clipboardProbeChanged = clipboardProbeChanged
            self.dynamicDisplayProbeChanged = dynamicDisplayProbeChanged
            self.ownerProvisioningCompleted = ownerProvisioningCompleted
            self.ownerProvisioningProgressChanged = ownerProvisioningProgressChanged
            self.phaseChanged = phaseChanged
            self.acceptanceFailureChanged = acceptanceFailureChanged
        }

        func submitOwnerProvisioning(_ submission: OmarchyOwnerProvisioningSubmission) {
            guard lastOwnerProvisioningSubmissionID != submission.id else { return }
            lastOwnerProvisioningSubmissionID = submission.id
            guard let integrationClient else {
                ownerProvisioningCompleted(submission.id, "The Guest Agent is not ready for owner setup.")
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await integrationClient.provisionOwner(submission.request)
                    ownerProvisioningCompleted(submission.id, nil)
                } catch {
                    ownerProvisioningCompleted(submission.id, error.localizedDescription)
                }
            }
        }

        func refreshOwnerProvisioningProgressIfNeeded(_ status: VMOmarchyGuestStatus) {
            guard status.provisioningPending, !ownerProgressFetchInFlight,
                  let integrationClient else { return }
            ownerProgressFetchInFlight = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { ownerProgressFetchInFlight = false }
                if let progress = try? await integrationClient.ownerProvisioningProgress() {
                    ownerProvisioningProgressChanged(progress)
                }
            }
        }

        deinit {
            if let stopObserver { NotificationCenter.default.removeObserver(stopObserver) }
            if let pauseObserver { NotificationCenter.default.removeObserver(pauseObserver) }
            if let resumeObserver { NotificationCenter.default.removeObserver(resumeObserver) }
            if let keyboardPermissionObserver { NotificationCenter.default.removeObserver(keyboardPermissionObserver) }
            if let forceStopObserver { NotificationCenter.default.removeObserver(forceStopObserver) }
            hostWakeInteractiveTask?.cancel()
        }

        func beginObservingCommands() {
            stopObserver = NotificationCenter.default.addObserver(
                forName: .omarchyRequestStop,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self, notification.object as? UUID == self.sessionID else { return }
                self.requestStop()
            }
            pauseObserver = NotificationCenter.default.addObserver(
                forName: .omarchyRequestPause,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self, notification.object as? UUID == self.sessionID else { return }
                self.pause(automaticResume: false)
            }
            resumeObserver = NotificationCenter.default.addObserver(
                forName: .omarchyRequestResume,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self, notification.object as? UUID == self.sessionID else { return }
                self.resume()
            }
            keyboardPermissionObserver = NotificationCenter.default.addObserver(
                forName: .omarchyRequestKeyboardPermission,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self, notification.object as? UUID == self.sessionID else { return }
                if let keyboardBridge = self.keyboardBridge {
                    keyboardBridge.requestPermission()
                } else {
                    OmarchyFocusedCommandBridge.requestAccessibilityAccess()
                }
            }
            forceStopObserver = NotificationCenter.default.addObserver(
                forName: .omarchyForceStop,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self, notification.object as? UUID == self.sessionID else { return }
                self.forceStop()
            }
        }

        func installKeyboardBridge(for view: VZVirtualMachineView) {
            let bridge = OmarchyFocusedCommandBridge(
                focusProbe: { [weak view] in
                    guard let view, let window = view.window else { return false }
                    guard !view.isHidden else { return false }
                    guard window.isKeyWindow, NSApp.keyWindow === window, NSApp.modalWindow == nil,
                          window.attachedSheet == nil else { return false }
                    guard let responder = window.firstResponder as? NSView else { return false }
                    // AppKit can retain a key window while another application
                    // is frontmost. A session-wide event tap must not capture it.
                    return OmarchyCommandCapturePolicy.hasKeyboardFocus(
                        applicationActive: NSApp.isActive,
                        windowKey: window.isKeyWindow,
                        responderInsideGuest: responder === view || responder.isDescendant(of: view)
                    )
                },
                stateChanged: keyboardIntegrationChanged,
                redirectedCommandChord: { [weak self] keyCode, flags in
                    // Only consume the physical Command chord when the
                    // authenticated Agent can actually deliver it. Keeping a
                    // disconnected client object must not turn every Command
                    // shortcut into a dropped key.
                    guard Thread.isMainThread else { return false }
                    return MainActor.assumeIsolated {
                        guard let client = self?.integrationClient,
                              client.currentCapabilities.contains("input-uinput-v1") else {
                            return false
                        }
                        return client.enqueueMacCommandChord(
                            keyCode: UInt16(keyCode),
                            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))
                        )
                    }
                },
                commandSpaceCaptured: { [weak self, weak view] in
                    guard let self else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        OmarchyAcceptanceObservationReporter.reportCommandSuperIfEnabled(
                            layout: self.layout,
                            applicationActive: NSApp.isActive,
                            virtualMachineWindowKey: view?.window?.isKeyWindow == true
                        )
                    }
                }
            )
            keyboardBridge = bridge
            (view as? OmarchyVirtualMachineInputView)?.commandEventHandler = { [weak bridge] event in
                guard let bridge else { return false }
                return bridge.handleLocalEvent(event) == nil
            }
            bridge.start()
        }

        func startIntegration(layout: VMOmarchyWorkspaceLayout) {
            guard let socket = machine?.socketDevices.first as? VZVirtioSocketDevice else {
                integrationChanged(.disconnected("The VM has no Virtio Socket device."))
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let client = try VMOmarchyGuestAgentClient(
                        device: socket,
                        layout: layout,
                        hostPowerChanged: { [weak self] event in
                            guard let self else { return }
                            Task { @MainActor [weak self] in
                                self?.handleHostPowerEvent(event)
                            }
                        },
                        stateChanged: { [weak self] state in
                            guard let self else { return }
                            self.integrationChanged(state)
                            switch state {
                            case .ready(let status):
                                Task { @MainActor [weak self] in
                                    guard let self else { return }
                                    // Record every authenticated status transition here. SwiftUI
                                    // can coalesce a short-lived locked status before the parent
                                    // view's onChange handler runs, which would make real lifecycle
                                    // evidence omit a lock that the recovery state machine observed.
                                    OmarchyAcceptanceObservationReporter.reportLifecycleIfEnabled(
                                        status: status,
                                        layout: self.layout
                                    )
                                    self.latestGuestStatus = status
                                    self.configureDesktopInput(for: status)
                                    self.startInputLatencyProbeIfNeeded(status)
                                    self.startContinuousInputProbeIfNeeded(status)
                                    self.configureAgentClipboard(for: status)
                                    self.configureNotifications(for: status)
                                    self.handleAutomaticRecoveryReady(status)
                                    self.refreshOwnerProvisioningProgressIfNeeded(status)
                                }
                            case .disconnected:
                                Task { @MainActor [weak self] in
                                    (self?.machineView as? OmarchyVirtualMachineInputView)?
                                        .setGuestInputEventHandler(nil)
                                    self?.latestGuestStatus = nil
                                    self?.stopAgentClipboard()
                                    self?.stopNotifications()
                                    self?.handleAutomaticRecoveryDisconnect()
                                }
                            case .connecting, .authenticating:
                                break
                            }
                            if case .ready(let status) = state,
                               VMOmarchyIntegrationAssessment.evaluate(
                                status: status,
                                requiredCapabilities: self.requiredGuestCapabilities
                               ).isReady {
                                self.startSharedFolderProbeIfNeeded(layout: layout)
                            }
                        }
                    )
                    self.integrationClient = client
                    client.start()
                } catch {
                    self.integrationChanged(.disconnected(error.localizedDescription))
                }
            }
        }

        @MainActor
        func configureDesktopInput(for status: VMOmarchyGuestStatus) {
            guard let view = machineView as? OmarchyVirtualMachineInputView else { return }
            guard OmarchyDesktopInputPolicy.usesGuestAgent(status: status),
                  let integrationClient else {
                view.setGuestInputEventHandler(nil)
                return
            }
            view.setGuestInputEventHandler { [weak integrationClient] events in
                integrationClient?.sendInputEvents(events)
            }
        }

        @MainActor
        func configureAgentClipboard(for status: VMOmarchyGuestStatus) {
            latestGuestStatus = status
            guard OmarchyClipboardActivationPolicy.shouldRun(
                enabled: clipboardEnabled,
                capabilities: Set(status.capabilities),
                desktopSessionActive: status.desktopSessionActive,
                provisioningPending: status.provisioningPending,
                probeOwnsTransport: clipboardProbeOwnsTransport
            ),
                  let integrationClient else {
                stopAgentClipboard()
                return
            }
            guard agentClipboardController == nil else { return }
            let controller = OmarchyAgentClipboardController(
                client: integrationClient,
                sharedDirectory: layout.shared
            )
            agentClipboardController = controller
            controller.start()
        }

        @MainActor
        func setClipboardEnabled(_ enabled: Bool) {
            guard clipboardEnabled != enabled else { return }
            clipboardEnabled = enabled
            guard let latestGuestStatus else {
                stopAgentClipboard()
                return
            }
            configureAgentClipboard(for: latestGuestStatus)
        }

        @MainActor
        func stopAgentClipboard() {
            agentClipboardController?.stop()
            agentClipboardController = nil
        }

        @MainActor
        func configureNotifications(for status: VMOmarchyGuestStatus) {
            guard OmarchyNotificationActivationPolicy.shouldRun(
                enabled: notificationsEnabled,
                capabilities: status.capabilities,
                desktopSessionActive: status.desktopSessionActive,
                provisioningPending: status.provisioningPending
            ), let integrationClient else {
                stopNotifications()
                return
            }
            guard notificationController == nil else { return }
            let controller = OmarchyNotificationController(
                client: integrationClient,
                bootID: status.bootID,
                deliverySucceeded: { [weak self] notification in
                    guard let self,
                          notification.title == self.expectedAcceptanceNotificationTitle else { return }
                    self.expectedAcceptanceNotificationTitle = nil
                    self.notificationAcceptanceProbeCompleted = true
                    OmarchyAcceptanceObservationReporter.reportDesktopNotificationIfEnabled(
                        notification,
                        guestBootID: status.bootID,
                        layout: self.layout
                    )
                    NSLog("Omarchy Guest notification was accepted by macOS Notification Center")
                }
            )
            notificationController = controller
            controller.start()
            startNotificationAcceptanceProbeIfNeeded(client: integrationClient)
        }

        @MainActor
        func setNotificationsEnabled(_ enabled: Bool) {
            guard notificationsEnabled != enabled else { return }
            notificationsEnabled = enabled
            guard let latestGuestStatus else {
                stopNotifications()
                return
            }
            configureNotifications(for: latestGuestStatus)
        }

        @MainActor
        func stopNotifications() {
            notificationController?.stop()
            notificationController = nil
            notificationAcceptanceProbeTask?.cancel()
            notificationAcceptanceProbeTask = nil
            expectedAcceptanceNotificationTitle = nil
            if !notificationAcceptanceProbeCompleted {
                notificationAcceptanceProbeStarted = false
            }
        }

        @MainActor
        func handleHostPowerEvent(_ event: VMOmarchyHostPowerEvent) {
            OmarchyAcceptanceObservationReporter.reportHostPowerEventIfEnabled(
                event == .willSleep ? .willSleep : .didWake,
                layout: layout
            )
            guard event == .didWake,
                  acceptanceEnabled else { return }
            startHostWakeInteractiveProbe()
        }

        @MainActor
        func handleAutomaticRecoveryDisconnect() {
            switch automaticRecoveryStage {
            case .waitingForAgentDisconnect:
                OmarchyAcceptanceObservationReporter.reportRecoveryEventIfEnabled(
                    .disconnectedAfterAgentRestart,
                    layout: layout
                )
                automaticRecoveryStage = .waitingForAgentReady
            case .waitingForGuestDisconnect:
                OmarchyAcceptanceObservationReporter.reportRecoveryEventIfEnabled(
                    .disconnectedAfterGuestRestart,
                    layout: layout
                )
                automaticRecoveryStage = .waitingForGuestReady
            case .idle, .waitingForPostResumeReady, .waitingForAgentReady,
                 .waitingForGuestReady, .complete:
                break
            }
        }

        func requestStop() {
            guard let machine, machine.state != .stopped else {
                stopIntegration()
                self.machine = nil
                phaseChanged(.stopped)
                return
            }
            guard machine.canRequestStop else {
                forceStop()
                return
            }
            do {
                try machine.requestStop()
            } catch {
                forceStop()
            }
        }

        func pause(automaticResume: Bool) {
            guard let machine, machine.canPause else {
                phaseChanged(.failed("Omarchy cannot be paused right now."))
                return
            }
            OmarchyAcceptanceObservationReporter.reportVirtualMachineEventIfEnabled(
                .pauseRequested,
                layout: layout
            )
            machine.pause { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success:
                        OmarchyAcceptanceObservationReporter.reportVirtualMachineEventIfEnabled(
                            .paused,
                            layout: self.layout
                        )
                        self.keyboardBridge?.stop()
                        self.stopAgentClipboard()
                        self.stopNotifications()
                        self.integrationClient?.virtualMachineDidPause()
                        self.phaseChanged(.paused)
                        if automaticResume {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                                self?.resume()
                            }
                        }
                    case .failure(let error):
                        self.automaticPauseResumeProbeStarted = false
                        self.phaseChanged(.failed(error.localizedDescription))
                    }
                }
            }
        }

        func resume() {
            guard let machine, machine.canResume else {
                phaseChanged(.failed("Omarchy cannot be resumed right now."))
                return
            }
            machine.resume { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success:
                        OmarchyAcceptanceObservationReporter.reportVirtualMachineEventIfEnabled(
                            .resumed,
                            layout: self.layout
                        )
                        if self.automaticRecoveryAfterResume {
                            self.automaticRecoveryAfterResume = false
                            self.automaticRecoveryStage = .waitingForPostResumeReady
                        }
                        self.integrationClient?.virtualMachineDidResume()
                        self.keyboardBridge?.start()
                        self.phaseChanged(.running)
                    case .failure(let error):
                        self.automaticPauseResumeProbeStarted = false
                        self.phaseChanged(.failed(error.localizedDescription))
                    }
                }
            }
        }

        func forceStop() {
            guard let machine, machine.state != .stopped else {
                stopIntegration()
                self.machine = nil
                phaseChanged(.stopped)
                return
            }
            guard machine.canStop else {
                phaseChanged(.failed("Omarchy could not be stopped after the graceful shutdown timed out."))
                return
            }
            machine.stop { [weak self, weak machine] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let error {
                        self.phaseChanged(.failed(error.localizedDescription))
                    } else if self.machine === machine {
                        self.stopIntegration()
                        self.machine = nil
                        self.phaseChanged(.stopped)
                    }
                }
            }
        }

        func stopImmediately() {
            inputLatencyProbeTask?.cancel()
            inputLatencyProbeTask = nil
            sharedFolderProbeTask?.cancel()
            sharedFolderProbeTask = nil
            clipboardProbeTask?.cancel()
            clipboardProbeTask = nil
            dynamicDisplayProbeTask?.cancel()
            dynamicDisplayProbeTask = nil
            keyboardBridge?.stop()
            keyboardBridge = nil
            stopIntegration()
            guard let machine else { return }
            Task { @MainActor in
                OmarchyApplicationTerminationController.shared.stopForViewTeardown(machine)
            }
            self.machine = nil
        }

        func guestDidStop(_ virtualMachine: VZVirtualMachine) {
            Task { @MainActor in
                OmarchyApplicationTerminationController.shared.machineDidStop(virtualMachine)
            }
            stopIntegration()
            machine = nil
            phaseChanged(.stopped)
        }

        func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
            Task { @MainActor in
                OmarchyApplicationTerminationController.shared.machineDidStop(virtualMachine)
            }
            stopIntegration()
            phaseChanged(.failed(error.localizedDescription))
        }

        func stopIntegration() {
            lockProbeTask?.cancel()
            lockProbeTask = nil
            continuousInputProbeTask?.cancel()
            continuousInputProbeTask = nil
            inputLatencyProbeTask?.cancel()
            inputLatencyProbeTask = nil
            (machineView as? OmarchyVirtualMachineInputView)?.setGuestInputEventHandler(nil)
            let clipboardController = agentClipboardController
            agentClipboardController = nil
            Task { @MainActor in clipboardController?.stop() }
            let notifications = notificationController
            notificationController = nil
            Task { @MainActor in notifications?.stop() }
            sharedFolderProbeTask?.cancel()
            sharedFolderProbeTask = nil
            sharedFolderProbePassed = false
            clipboardProbeTask?.cancel()
            clipboardProbeTask = nil
            clipboardProbePassed = false
            dynamicDisplayProbeTask?.cancel()
            dynamicDisplayProbeTask = nil
            dynamicDisplayProbePassed = false
            let client = integrationClient
            integrationClient = nil
            Task { @MainActor in client?.stop() }
        }
    }
}

private extension Notification.Name {
    static let omarchyRequestStop = Notification.Name("RiftVMOmarchy.requestStop")
    static let omarchyRequestPause = Notification.Name("RiftVMOmarchy.requestPause")
    static let omarchyRequestResume = Notification.Name("RiftVMOmarchy.requestResume")
    static let omarchyRequestKeyboardPermission = Notification.Name("RiftVMOmarchy.requestKeyboardPermission")
    static let omarchyForceStop = Notification.Name("RiftVMOmarchy.forceStop")
}
