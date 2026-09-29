import AppKit
import Virtualization

final class OmarchyVirtualMachineInputView: VMVirGLDisplayView {
    var displayConfigurationChanged: (() -> Void)?

    init(usesCustomGraphics: Bool = true) {
        super.init(frame: .zero, guestSize: CGSize(width: 1920, height: 1200), managesKeyboardIntegration: false, usesCustomGraphics: usesCustomGraphics)
    }

    required init?(coder: NSCoder) { nil }

    private(set) var hostOverlayVisible = false

    override var acceptsFirstResponder: Bool {
        !hostOverlayVisible && super.acceptsFirstResponder
    }

    func setHostOverlayVisible(_ visible: Bool) {
        guard hostOverlayVisible != visible else { return }
        hostOverlayVisible = visible
        capturesSystemKeys = !visible
        if visible {
            releaseGuestKeys()
            releaseInputCapture()
        }
        if visible, let responder = window?.firstResponder as? NSView,
           responder === self || responder.isDescendant(of: self) {
            window?.makeFirstResponder(nil)
        }
        // Hide guest presentation while native controls own input; keep the
        // machine and authenticated Agent running.
        isHidden = visible
        window?.invalidateCursorRects(for: self)
        if visible {
            pendingDisplayRefresh?.cancel()
            displayRefreshGeneration &+= 1
        } else {
            refreshDisplayAfterTransition()
            // Resume and owner completion remove a native button/form that
            // owned focus. Return input to the Guest only in the active window.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.hostOverlayVisible,
                      let window = self.window, window.isKeyWindow,
                      NSApp.isActive, window.attachedSheet == nil else { return }
                window.makeFirstResponder(self)
            }
        }
    }

    // App-targeted events may reach the responder without traversing the
    // session event tap, so Command routing also has a direct-view seam.
    var commandEventHandler: ((NSEvent) -> Bool)?
    private var guestInputEventHandler: (([VMGuestAgentInputEvent]) -> Void)?
    private var guestPressedKeys = Set<UInt16>()
    /// Mac key codes pressed through the Virtualization.framework keyboard,
    /// because the Agent was unavailable or the key has no Linux mapping. Their
    /// release goes to the same keyboard, or the guest keeps them held and
    /// auto-repeating.
    private var nativePressedKeys = Set<UInt16>()
    private var diagnosticMonitor: Any?
    private var diagnosticViewEvents = 0
    private var diagnosticWindowEvents = 0
    private let inputDiagnosticsEnabled = UserDefaults.standard.bool(forKey: "RiftVMInputDiagnosticsEnabled")
    private var displayObservers: [NSObjectProtocol] = []
    private var powerObservers: [NSObjectProtocol] = []
    private var pendingDisplayRefresh: DispatchWorkItem?
    private var lastDisplayLayoutSize = CGSize.zero
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
        // A window resize reaches the display through layout(), which sees
        // every change of this view's size; the guest keeps its mode, so
        // there is nothing else for a resize to update.
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

    override func layout() {
        super.layout()
        guard bounds.size != lastDisplayLayoutSize else { return }
        lastDisplayLayoutSize = bounds.size
        scheduleDisplayRefresh()
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
        // The guest keeps one display mode for the session, so the backend
        // only records the geometry it scales into. AppKit lays the window out
        // on its own, and a size it changes later arrives through layout().
        DispatchQueue.main.async { [weak self, weak targetWindow] in
            guard let self, let targetWindow, self.window === targetWindow,
                  self.displayRefreshGeneration == generation,
                  !self.hostOverlayVisible else { return }
            self.displayConfigurationChanged?()
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
                nativeKeyDown(event)
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
        nativeKeyDown(event)
    }

    private func nativeKeyDown(_ event: NSEvent) {
        if !event.isARepeat { nativePressedKeys.insert(event.keyCode) }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        recordInputDelivery(event, route: "view")
        recordAcceptanceRoute("keyUp", event: event)
        if nativePressedKeys.remove(event.keyCode) != nil {
            super.keyUp(with: event)
            return
        }
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
            // macOS reports Caps Lock as a latched state that flips once per
            // press. Omarchy maps the key to Compose, so each press has to be a
            // whole press and release; following the latch sent only a press on
            // one stroke and only a release on the next.
            if event.keyCode == Self.capsLockKeyCode,
               let code = VMGuestAgentKeyboard.linuxKeyCode(forMacVirtualKey: event.keyCode) {
                guestInputEventHandler(
                    VMGuestAgentInputBatch.key(code: code, pressed: true).events
                    + VMGuestAgentInputBatch.key(code: code, pressed: false).events
                )
                return
            }
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

    private static let capsLockKeyCode: UInt16 = 57

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
        setGuestInputHandler(usesCustomGraphics ? handler : nil)
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
