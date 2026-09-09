import AppKit
import CoreGraphics

struct OmarchyHostKeyboardStroke: Equatable {
    let keyCode: CGKeyCode
    let shifted: Bool
}

enum OmarchyHostKeyboardTextEncoder {
    /// Time required for the last asynchronously posted key event to enter
    /// AppKit, plus one 25 ms scheduling quantum. Unlike `deliveryDuration`,
    /// this contains no acceptance settling margin.
    static func eventQueueDuration(for text: String) -> Duration {
        let eventCount = (strokes(for: text) ?? []).reduce(0) { $0 + ($1.shifted ? 4 : 2) }
        return .milliseconds(max(25, eventCount * 25 + 25))
    }

    /// Matches the 25 ms spacing used for each key-down and key-up event and
    /// leaves a small margin for the final event to reach the virtual keyboard.
    static func deliveryDuration(for text: String) -> Duration {
        .milliseconds((strokes(for: text) ?? []).reduce(0) { $0 + ($1.shifted ? 100 : 50) } + 250)
    }

    static func strokes(for text: String) -> [OmarchyHostKeyboardStroke]? {
        var result: [OmarchyHostKeyboardStroke] = []
        for character in text {
            if let keyCode = lowerKeyCodes[character] {
                result.append(.init(keyCode: keyCode, shifted: false))
            } else if character.isUppercase,
                      let lower = character.lowercased().first,
                      let keyCode = lowerKeyCodes[lower] {
                result.append(.init(keyCode: keyCode, shifted: true))
            } else if let stroke = symbolKeyCodes[character] {
                result.append(stroke)
            } else {
                return nil
            }
        }
        return result
    }

    private static let lowerKeyCodes: [Character: CGKeyCode] = [
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5,
        "h": 4, "i": 34, "j": 38, "k": 40, "l": 37, "m": 46,
        "n": 45, "o": 31, "p": 35, "q": 12, "r": 15, "s": 1,
        "t": 17, "u": 32, "v": 9, "w": 13, "x": 7, "y": 16,
        "z": 6, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23,
        "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
    ]

    private static let symbolKeyCodes: [Character: OmarchyHostKeyboardStroke] = [
        " ": .init(keyCode: 49, shifted: false),
        "\n": .init(keyCode: 36, shifted: false),
        "/": .init(keyCode: 44, shifted: false),
        ".": .init(keyCode: 47, shifted: false),
        "-": .init(keyCode: 27, shifted: false), "_": .init(keyCode: 27, shifted: true),
        "=": .init(keyCode: 24, shifted: false), "+": .init(keyCode: 24, shifted: true),
        "[": .init(keyCode: 33, shifted: false), "{": .init(keyCode: 33, shifted: true),
        "]": .init(keyCode: 30, shifted: false), "}": .init(keyCode: 30, shifted: true),
        ";": .init(keyCode: 41, shifted: false), ":": .init(keyCode: 41, shifted: true),
        "'": .init(keyCode: 39, shifted: false), "\"": .init(keyCode: 39, shifted: true),
        "`": .init(keyCode: 50, shifted: false), "~": .init(keyCode: 50, shifted: true),
        "\\": .init(keyCode: 42, shifted: false), "|": .init(keyCode: 42, shifted: true),
        ",": .init(keyCode: 43, shifted: false), "<": .init(keyCode: 43, shifted: true),
        ">": .init(keyCode: 47, shifted: true), "?": .init(keyCode: 44, shifted: true),
        "!": .init(keyCode: 18, shifted: true), "@": .init(keyCode: 19, shifted: true),
        "#": .init(keyCode: 20, shifted: true), "$": .init(keyCode: 21, shifted: true),
        "%": .init(keyCode: 23, shifted: true), "^": .init(keyCode: 22, shifted: true),
        "&": .init(keyCode: 26, shifted: true), "*": .init(keyCode: 28, shifted: true),
        "(": .init(keyCode: 25, shifted: true), ")": .init(keyCode: 29, shifted: true),
    ]
}

enum OmarchyKeyboardIntegrationState: Equatable {
    case enabled
    case accessibilityRequired
    case eventTapUnavailable
    case requestingAccessibility
}

enum OmarchyCommandCapturePolicy {
    static func ownsCommandModifier(keyCode: UInt16) -> Bool {
        keyCode == 54 || keyCode == 55
    }

    static func shouldRedirect(
        type: CGEventType,
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        focused: Bool,
        isSynthetic: Bool
    ) -> Bool {
        guard focused, !isSynthetic, flags.contains(.maskCommand) else { return false }
        guard type == .keyDown || type == .keyUp else { return false }
        // Modifier-only transitions continue through the normal VZ input path.
        return keyCode != 54 && keyCode != 55
    }
}

struct OmarchyCommandSpaceCaptureState {
    private(set) var sawKeyDown = false

    mutating func observe(type: CGEventType, keyCode: CGKeyCode) -> Bool {
        guard keyCode == 49 else { return false }
        if type == .keyDown {
            sawKeyDown = true
            return false
        }
        guard type == .keyUp, sawKeyDown else { return false }
        sawKeyDown = false
        return true
    }
}

final class OmarchyFocusedCommandBridge {
    static let syntheticMarker: Int64 = 0x455A_4F4D_4152_4348
    static let acceptanceMarker: Int64 = 0x455A_4143_4345_5054

    private let focusProbe: () -> Bool
    private let stateChanged: (OmarchyKeyboardIntegrationState) -> Void
    private let redirectedCommandChord: (CGKeyCode, CGEventFlags) -> Bool
    private let commandSpaceCaptured: () -> Void
    private var localMonitor: Any?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var permissionTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var commandSpaceState = OmarchyCommandSpaceCaptureState()
    private var agentForwardedKeys = Set<CGKeyCode>()
    private var virtualKeyboardForwardedKeys = Set<CGKeyCode>()

    static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!

    @discardableResult
    static func requestAccessibilityAccess() -> Bool {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        guard AXIsProcessTrusted() else {
            NSWorkspace.shared.open(accessibilitySettingsURL)
            return false
        }
        return true
    }

    init(
        focusProbe: @escaping () -> Bool,
        stateChanged: @escaping (OmarchyKeyboardIntegrationState) -> Void,
        redirectedCommandChord: @escaping (CGKeyCode, CGEventFlags) -> Bool = { _, _ in false },
        commandSpaceCaptured: @escaping () -> Void = {}
    ) {
        self.focusProbe = focusProbe
        self.stateChanged = stateChanged
        self.redirectedCommandChord = redirectedCommandChord
        self.commandSpaceCaptured = commandSpaceCaptured
    }

    func start() {
        if activationObserver == nil {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.start()
            }
        }
        guard AXIsProcessTrusted() else {
            stateChanged(.accessibilityRequired)
            return
        }
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self else { return event }
                return self.handleLocalEvent(event)
            }
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            stateChanged(.enabled)
            return
        }
        installEventTap()
    }

    private func installEventTap() {
        guard tap == nil else { return }
        let mask = (UInt64(1) << CGEventType.keyDown.rawValue)
            | (UInt64(1) << CGEventType.keyUp.rawValue)
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let bridge = Unmanaged<OmarchyFocusedCommandBridge>
                    .fromOpaque(userInfo).takeUnretainedValue()
                return bridge.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            stateChanged(.eventTapUnavailable)
            return
        }
        tap = eventTap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        stateChanged(.enabled)
    }

    func requestPermission() {
        stateChanged(.requestingAccessibility)
        if Self.requestAccessibilityAccess() {
            start()
            return
        }
        permissionTimer?.invalidate()
        var attemptsRemaining = 240
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if AXIsProcessTrusted() {
                timer.invalidate()
                self.permissionTimer = nil
                self.start()
                return
            }
            attemptsRemaining -= 1
            if attemptsRemaining == 0 {
                timer.invalidate()
                self.permissionTimer = nil
                self.stateChanged(.accessibilityRequired)
            }
        }
        permissionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        agentForwardedKeys.removeAll()
        virtualKeyboardForwardedKeys.removeAll()
        commandSpaceState = OmarchyCommandSpaceCaptureState()
        permissionTimer?.invalidate()
        permissionTimer = nil
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        tap = nil
    }

    @discardableResult
    func runAcceptanceCommandSpaceProbe() -> Bool {
        runAcceptanceCommandChordProbe(keyCode: 49)
    }

    @discardableResult
    func runAcceptanceCommandChordProbe(
        keyCode: CGKeyCode,
        additionalFlags: CGEventFlags = []
    ) -> Bool {
        guard tap != nil, AXIsProcessTrusted(), focusProbe() else { return false }
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        let flags = additionalFlags.union(.maskCommand)
        var events: [CGEvent] = []
        for keyDown in [true, false] {
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: keyCode,
                keyDown: keyDown
            ) else { return false }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: Self.acceptanceMarker)
            events.append(event)
        }
        // The event tap converts the modifier flags into balanced uinput key
        // transitions; only the main key needs to traverse the session tap.
        for (index, event) in events.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.05) {
                event.post(tap: .cghidEventTap)
            }
        }
        return true
    }

    /// Posts acceptance-only text through the focused VZVirtualMachineView.
    /// Secure lock screens may intentionally ignore the Guest Agent's uinput
    /// keyboard, so unlock verification exercises Virtualization.framework's
    /// virtual USB keyboard just like real user input does.
    @discardableResult
    func runAcceptanceTextInput(_ text: String) -> Bool {
        guard tap != nil, AXIsProcessTrusted(), focusProbe(),
              let source = CGEventSource(stateID: .combinedSessionState),
              let strokes = OmarchyHostKeyboardTextEncoder.strokes(for: text) else {
            return false
        }
        // VZ consumes explicit modifier transitions. Merely attaching Shift to
        // the printable key does not establish a pressed modifier in the guest.
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
            event.setIntegerValueField(.eventSourceUserData, value: Self.acceptanceMarker)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.025) {
                event.post(tap: .cghidEventTap)
            }
        }
        return true
    }

    /// App-targeted accessibility events can bypass the session event tap.
    /// Physical events redirected by the tap are consumed before this monitor;
    /// fallback events carry syntheticMarker and therefore never loop.
    func handleLocalEvent(_ event: NSEvent) -> NSEvent? {
        let releasesCapturedKey = event.type == .keyUp && agentForwardedKeys.contains(event.keyCode)
        guard releasesCapturedKey || event.window == nil || event.window === NSApp.keyWindow,
              let cgEvent = event.cgEvent else { return event }
        return handle(type: cgEvent.type, event: cgEvent) == nil ? nil : event
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let synthetic = event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        // A redirected key remains owned by the Agent path until its release,
        // even when Command or focus changes first.
        if !synthetic, type == .keyUp, agentForwardedKeys.remove(keyCode) != nil {
            if commandSpaceState.observe(type: type, keyCode: keyCode) {
                DispatchQueue.main.async { [commandSpaceCaptured] in commandSpaceCaptured() }
            }
            return nil
        }
        let redirect = OmarchyCommandCapturePolicy.shouldRedirect(
            type: type,
            keyCode: keyCode,
            flags: event.flags,
            focused: focusProbe(),
            isSynthetic: synthetic
        )
        guard redirect else {
            return Unmanaged.passUnretained(event)
        }
        if commandSpaceState.observe(type: type, keyCode: keyCode) {
            DispatchQueue.main.async { [commandSpaceCaptured] in commandSpaceCaptured() }
        }
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if type == .keyDown, !isRepeat,
           redirectedCommandChord(keyCode, event.flags) {
            agentForwardedKeys.insert(keyCode)
            if event.getIntegerValueField(.eventSourceUserData) == Self.acceptanceMarker {
                NSLog("Omarchy acceptance Command chord forwarded through Guest Agent keyCode=%hu", keyCode)
            }
            return nil
        }
        if type == .keyDown, isRepeat, agentForwardedKeys.contains(keyCode) {
            return nil
        }
        forwardThroughVirtualKeyboard(type: type, keyCode: keyCode, event: event)
        return nil
    }

    /// VZ's USB keyboard needs an explicit Command modifier transition to
    /// produce Linux Super. A key event carrying only `.maskCommand` is not
    /// sufficient, and macOS does not deliver its physical Command transition
    /// to the virtual-machine view after the session tap owns the chord.
    private func forwardThroughVirtualKeyboard(
        type: CGEventType,
        keyCode: CGKeyCode,
        event: CGEvent
    ) {
        guard type == .keyDown || type == .keyUp else { return }
        let pid = ProcessInfo.processInfo.processIdentifier
        let leftCommandDeviceFlag = CGEventFlags(rawValue: 0x0000_0008)
        let commandFlags = event.flags.union(.maskCommand).union(leftCommandDeviceFlag)

        if type == .keyDown, virtualKeyboardForwardedKeys.insert(keyCode).inserted,
           let commandDown = CGEvent(
               keyboardEventSource: nil,
               virtualKey: 55,
               keyDown: true
           ) {
            commandDown.type = .flagsChanged
            commandDown.flags = commandFlags
            commandDown.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            commandDown.postToPid(pid)
        }

        if let localEvent = event.copy() {
            localEvent.flags = commandFlags
            localEvent.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            localEvent.postToPid(pid)
        }

        if type == .keyUp, virtualKeyboardForwardedKeys.remove(keyCode) != nil,
           let commandUp = CGEvent(
               keyboardEventSource: nil,
               virtualKey: 55,
               keyDown: false
           ) {
            commandUp.type = .flagsChanged
            commandUp.flags = event.flags
                .subtracting(.maskCommand)
                .subtracting(leftCommandDeviceFlag)
            commandUp.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            commandUp.postToPid(pid)
        }
    }
}
