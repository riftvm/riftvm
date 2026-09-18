//
//  VMModelFieldGraphicDevice.swift
//  RiftVM
//
//  Created by everettjf on 2022/8/24.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Metal
import QuartzCore
import Virtualization
#if arch(arm64)
import RiftVMVirGLRuntime
#endif

#if arch(arm64)
struct VMModelFieldGraphicDevice : Decodable, Encodable, CustomStringConvertible {
    enum DeviceType : String, CaseIterable, Identifiable, Decodable, Encodable {
        case Mac, Virtio
        var id: Self { self }

        var displayName: String {
            switch self {
            case .Mac: "Mac Display"
            case .Virtio: "Virtio Display"
            }
        }
    }
    
    let type: DeviceType
    let width: Int
    let height: Int
    let pixelsPerInch: Int
    
    var description: String {
        if type == .Virtio {
            return "\(type.displayName) · \(width) × \(height)"
        } else {
            return "\(type.displayName) · \(width) × \(height) · \(pixelsPerInch) ppi"
        }
    }
    
    static func `default`(osType: VMOSType) -> VMModelFieldGraphicDevice {
        switch osType {
        case .macOS:
            return VMModelFieldGraphicDevice(type: .Mac, width: 1920, height: 1200, pixelsPerInch: 80)
        case .linux:
            return VMModelFieldGraphicDevice(type: .Virtio, width: 1280, height: 720, pixelsPerInch: 0)
        }
    }
    
    func createConfiguration() -> VZGraphicsDeviceConfiguration {
        if self.type == .Virtio {
            let config = VZVirtioGraphicsDeviceConfiguration()
            config.scanouts = [
                VZVirtioGraphicsScanoutConfiguration(widthInPixels: self.width, heightInPixels: self.height)
            ]
            return config
        }
        
        let graphicsConfiguration = VZMacGraphicsDeviceConfiguration()
        graphicsConfiguration.displays = [
            // We abitrarily choose the resolution of the display to be 1920 x 1200.
            VZMacGraphicsDisplayConfiguration(widthInPixels: self.width, heightInPixels: self.height, pixelsPerInch: self.pixelsPerInch)
        ]
        return graphicsConfiguration
    }
}

protocol VMGraphicsBackend {
    var kind: VMGraphicsBackendKind { get }
    var displayView: NSView { get }
    var supportsMachineSaveRestore: Bool { get }
    func applyGraphics(
        from devices: [VMModelFieldGraphicDevice],
        to configuration: VZVirtualMachineConfiguration
    ) -> VMOSResultVoid
    func bind(virtualMachine: VZVirtualMachine?)
    func refreshDisplayConfiguration()
    func setDynamicDisplayReady(_ ready: Bool)
    func setGuestInputHandler(_ handler: (([VMGuestAgentInputEvent]) -> Void)?)
    func setKeyboardIntegrationStateHandler(_ handler: ((VMKeyboardIntegrationState) -> Void)?)
    func requestKeyboardIntegrationPermission()
    func setAbsolutePointerEnabled(_ enabled: Bool)
    func setRuntimeIssueHandler(_ handler: ((String?) -> Void)?)
    func shutdown()
}

final class VMAppleGraphicsBackend: VMGraphicsBackend {
    let kind: VMGraphicsBackendKind
    let supportsMachineSaveRestore = true
    let virtualMachineView: VZVirtualMachineView
    var displayView: NSView { virtualMachineView }

    init(displayView: VZVirtualMachineView = VZVirtualMachineView(), kind: VMGraphicsBackendKind = .appleVirtio) {
        self.kind = kind
        virtualMachineView = displayView
        if #available(macOS 14.0, *) {
            virtualMachineView.automaticallyReconfiguresDisplay = true
        }
    }

    func applyGraphics(
        from devices: [VMModelFieldGraphicDevice],
        to configuration: VZVirtualMachineConfiguration
    ) -> VMOSResultVoid {
        configuration.graphicsDevices = devices.map { $0.createConfiguration() }
        return .success
    }

    func bind(virtualMachine: VZVirtualMachine?) {
        virtualMachineView.virtualMachine = virtualMachine
    }

    func refreshDisplayConfiguration() {
        guard #available(macOS 14.0, *) else { return }
        virtualMachineView.automaticallyReconfiguresDisplay = false
        virtualMachineView.automaticallyReconfiguresDisplay = true
    }

    func setDynamicDisplayReady(_ ready: Bool) {}

    func setGuestInputHandler(_ handler: (([VMGuestAgentInputEvent]) -> Void)?) {}

    func setKeyboardIntegrationStateHandler(_ handler: ((VMKeyboardIntegrationState) -> Void)?) {
        handler?(.unavailable)
    }

    func requestKeyboardIntegrationPermission() {}

    func setAbsolutePointerEnabled(_ enabled: Bool) {}

    func setRuntimeIssueHandler(_ handler: ((String?) -> Void)?) {}

    func shutdown() {
        virtualMachineView.virtualMachine = nil
    }
}

@available(macOS 27.0, *)
private final class VMFocusedCommandEventTap {
    typealias FocusProbe = () -> Bool
    typealias EventHandler = ([VMGuestAgentInputEvent]) -> Void

    private let focusProbe: FocusProbe
    private let eventHandler: EventHandler
    private var state = VMFocusedCommandCaptureState()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var focusTimer: Timer?

    init(focusProbe: @escaping FocusProbe, eventHandler: @escaping EventHandler) {
        self.focusProbe = focusProbe
        self.eventHandler = eventHandler
    }

    deinit {
        stop()
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (UInt64(1) << CGEventType.keyDown.rawValue)
            | (UInt64(1) << CGEventType.keyUp.rawValue)
            | (UInt64(1) << CGEventType.flagsChanged.rawValue)
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<VMFocusedCommandEventTap>
                    .fromOpaque(userInfo).takeUnretainedValue()
                return owner.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        tap = eventTap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        focusTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.releaseIfFocusWasLost()
        }
        return true
    }

    func stop() {
        emit(state.releaseAll())
        focusTimer?.invalidate()
        focusTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        tap = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            emit(state.releaseAll())
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let kind: VMFocusedCommandEventKind
        switch type {
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        case .flagsChanged: kind = .flagsChanged
        default: return Unmanaged.passUnretained(event)
        }
        let input = VMFocusedCommandEvent(
            kind: kind,
            keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)),
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        )
        let outcome = state.process(input, focused: focusProbe())
        emit(outcome.guestEvents)
        return outcome.suppressHostEvent ? nil : Unmanaged.passUnretained(event)
    }

    private func releaseIfFocusWasLost() {
        guard state.isCapturing, !focusProbe() else { return }
        emit(state.releaseAll())
    }

    private func emit(_ events: [VMGuestAgentInputEvent]) {
        guard !events.isEmpty else { return }
        // Each transition is a key event followed by SYN_REPORT. Split large
        // forced releases without breaking those pairs or the Agent's 64-event
        // input-batch limit.
        let maximumPairs = VMGuestAgentInputBatch.maximumEventCount / 2
        var pairIndex = 0
        while pairIndex * 2 < events.count {
            let start = pairIndex * 2
            let end = min(events.count, start + maximumPairs * 2)
            eventHandler(Array(events[start..<end]))
            pairIndex += maximumPairs
        }
    }
}

@available(macOS 27.0, *)
class VMVirGLDisplayView: VZVirtualMachineView {
    private let backgroundLayer = CALayer()
    private let metalLayer = CAMetalLayer()
    private let drawableAcquirer = VMGraphicsDrawableAcquirer()
    private let cursorLayer = CALayer()
    weak var runtime: RiftVMVirGLRuntime?
    private var guestInputHandler: (([VMGuestAgentInputEvent]) -> Void)?
    var runtimeIssueHandler: ((String?) -> Void)?
    private var presentedFrames: UInt64 = 0
    private var performanceWindowStartedAt = CACurrentMediaTime()
    private var requestedFramesInWindow: UInt64 = 0
    private var presentedFramesInWindow: UInt64 = 0
    private var drawableMissesInWindow: UInt64 = 0
    private var failuresInWindow: UInt64 = 0
    private var totalPresentationTimeInWindow: TimeInterval = 0
    private var maximumPresentationTimeInWindow: TimeInterval = 0
    private var presentationDurationsInWindow: [TimeInterval] = []
    private var drawableWaitDurationsInWindow: [TimeInterval] = []
    private var frameDurationsInWindow: [TimeInterval] = []
    private var cursorPosition = CGPoint.zero
    private var cursorHotspot = CGPoint.zero
    private var cursorImageSize = CGSize.zero
    private var cursorPresentation = VMGuestCursorPresentationPolicy()
    private var pressedKeys = Set<UInt16>()
    private var pressedButtons = Set<UInt16>()
    private var pointerCaptured = false
    private var windowObservers: [NSObjectProtocol] = []
    private let managesKeyboardIntegration: Bool
    let usesCustomGraphics: Bool
    private var commandKeyMonitor: Any?
    private var focusedCommandEventTap: VMFocusedCommandEventTap?
    private var accessibilityRetryTimer: Timer?
    private var keyboardIntegrationStateHandler: ((VMKeyboardIntegrationState) -> Void)?
    private var guestSize: CGSize
    private var scrollWheelAccumulator = VMScrollWheelAccumulator()
    private var presentationDemand = VMGraphicsPresentationDemand()
    private var latestScanout: (resourceID: UInt32, x: Int, y: Int, width: Int, height: Int)?
    private var presentationIsActive = false
    private var displayRefreshTimer: Timer?
    var isDisplayRefreshScheduled: Bool { displayRefreshTimer != nil }

    var canPresentFrames: Bool {
        guard usesCustomGraphics, let window else { return false }
        return window.isVisible && !window.isMiniaturized
            && window.occlusionState.contains(.visible) && !isHiddenOrHasHiddenAncestor
    }
    private var presentationInFlight = false
    private(set) var displayActivityGeneration: UInt64 = 0
    private var presentationHealth = VMGraphicsPresentationHealthTracker()
    private var presentationLifecycle = VMGraphicsPresentationLifecycle()
    private var presentationEventFence = VMGraphicsPresentationEventFence()
    // Custom VirGL owns presentation and input. There is no native VZ display
    // attached; authenticated Guest Agent input becomes available in userspace.
    private var absolutePointerEnabled = true

    init(frame frameRect: NSRect, guestSize: CGSize, managesKeyboardIntegration: Bool = true, usesCustomGraphics: Bool = true) {
        self.usesCustomGraphics = usesCustomGraphics
        self.managesKeyboardIntegration = managesKeyboardIntegration
        self.guestSize = guestSize
        super.init(frame: frameRect)
        if usesCustomGraphics {
            wantsLayer = true
            backgroundLayer.backgroundColor = NSColor.black.cgColor
            layer = backgroundLayer
            metalLayer.device = MTLCreateSystemDefaultDevice()
            metalLayer.pixelFormat = .bgra8Unorm
            metalLayer.framebufferOnly = false
            metalLayer.backgroundColor = NSColor.black.cgColor
            backgroundLayer.addSublayer(metalLayer)
            cursorLayer.anchorPoint = .zero
            cursorLayer.contentsGravity = .resize
            cursorLayer.isHidden = true
            metalLayer.addSublayer(cursorLayer)
        }
        capturesSystemKeys = true
        automaticallyReconfiguresDisplay = false
        if managesKeyboardIntegration {
            commandKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      let vmWindow = self.window,
                      vmWindow.isKeyWindow,
                      NSApp.keyWindow === vmWindow,
                      NSApp.modalWindow == nil,
                      !NSApp.windows.contains(where: {
                          $0.isVisible && ($0 is NSOpenPanel || $0 is NSSavePanel)
                      }),
                      vmWindow.attachedSheet == nil else { return event }
                // Accessibility input and some system-key event sources leave the
                // event's window unset even though AppKit is dispatching to the key
                // VM window. Accept that form, but never steal a chord explicitly
                // associated with another RiftVM window.
                if let eventWindow = event.window, eventWindow !== vmWindow { return event }
                if let responderView = vmWindow.firstResponder as? NSView,
                   responderView !== self, !responderView.isDescendant(of: self) {
                    return event
                }
                if self.isHostFullScreenShortcut(event) { return event }
                return self.forwardCommandChordToGuest(event) ? nil : event
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        focusedCommandEventTap?.stop()
        accessibilityRetryTimer?.invalidate()
        if let commandKeyMonitor { NSEvent.removeMonitor(commandKeyMonitor) }
        displayRefreshTimer?.invalidate()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        releaseInputCapture()
    }

    func stopPresentation() {
        focusedCommandEventTap?.stop()
        focusedCommandEventTap = nil
        accessibilityRetryTimer?.invalidate()
        accessibilityRetryTimer = nil
        presentationLifecycle.stop()
        presentationIsActive = false
        displayRefreshTimer?.invalidate()
        displayRefreshTimer = nil
        latestScanout = nil
        presentationDemand.cancel()
        presentationInFlight = false
        cursorLayer.isHidden = true
        cursorPresentation.reset()
        runtimeIssueHandler?(nil)
        releaseInputCapture()
    }

    func invalidateScanout(eventSequence: UInt64) {
        guard presentationEventFence.accept(eventSequence) else { return }
        displayActivityGeneration &+= 1
        latestScanout = nil
        presentationDemand.cancel()
        presentationIsActive = false
        displayRefreshTimer?.invalidate()
        displayRefreshTimer = nil
    }

    override var acceptsFirstResponder: Bool { true }

    func setGuestInputHandler(_ handler: (([VMGuestAgentInputEvent]) -> Void)?) {
        focusedCommandEventTap?.stop()
        focusedCommandEventTap = nil
        if handler == nil { releaseInputCapture() }
        guestInputHandler = handler
        guard handler != nil else {
            keyboardIntegrationStateHandler?(.waitingForGuest)
            return
        }
        if managesKeyboardIntegration { installFocusedCommandEventTap() }
    }

    func setKeyboardIntegrationStateHandler(
        _ handler: ((VMKeyboardIntegrationState) -> Void)?
    ) {
        keyboardIntegrationStateHandler = handler
        if focusedCommandEventTap != nil {
            handler?(.enabled)
        } else if guestInputHandler == nil {
            handler?(.waitingForGuest)
        } else {
            handler?(.accessibilityRequired)
        }
    }

    func requestKeyboardIntegrationPermission() {
        guard guestInputHandler != nil else {
            keyboardIntegrationStateHandler?(.waitingForGuest)
            return
        }
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        accessibilityRetryTimer?.invalidate()
        var attemptsRemaining = 40
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self, self.guestInputHandler != nil else {
                timer.invalidate()
                return
            }
            if AXIsProcessTrusted() {
                timer.invalidate()
                self.accessibilityRetryTimer = nil
                self.installFocusedCommandEventTap()
                return
            }
            attemptsRemaining -= 1
            if attemptsRemaining == 0 {
                timer.invalidate()
                self.accessibilityRetryTimer = nil
                self.keyboardIntegrationStateHandler?(.accessibilityRequired)
            }
        }
        accessibilityRetryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        keyboardIntegrationStateHandler?(.accessibilityRequired)
    }

    private func installFocusedCommandEventTap() {
        guard focusedCommandEventTap == nil, let handler = guestInputHandler else { return }
        let eventTap = VMFocusedCommandEventTap(
            focusProbe: { [weak self] in self?.shouldCaptureSystemKeys == true },
            eventHandler: handler
        )
        if eventTap.start() {
            focusedCommandEventTap = eventTap
            keyboardIntegrationStateHandler?(.enabled)
            RiftVMLog.info("Focused Command/Super event tap enabled", logger: RiftVMLog.input)
        } else {
            keyboardIntegrationStateHandler?(.accessibilityRequired)
            RiftVMLog.error(
                "Focused Command/Super event tap unavailable; grant Accessibility permission for system shortcuts",
                logger: RiftVMLog.input
            )
        }
    }

    private var shouldCaptureSystemKeys: Bool {
        guard guestInputHandler != nil,
              let vmWindow = window,
              vmWindow.isKeyWindow,
              NSApp.isActive,
              NSApp.keyWindow === vmWindow,
              NSApp.modalWindow == nil,
              vmWindow.attachedSheet == nil,
              !NSApp.windows.contains(where: {
                  $0.isVisible && ($0 is NSOpenPanel || $0 is NSSavePanel)
              }) else { return false }
        guard let responder = vmWindow.firstResponder else { return false }
        if responder === self { return true }
        return (responder as? NSView)?.isDescendant(of: self) == true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        if releaseShortcutIsActive(event) {
            releaseInputCapture()
            return
        }
        // AppKit normally offers Command chords via `performKeyEquivalent`,
        // but some event sources (including hardware
        // layouts and accessibility event injection) deliver them directly as
        // key-down events. Cover both routes so macOS Command consistently
        // becomes Linux Super instead of silently disappearing.
        if forwardCommandChordToGuest(event) { return }
        if let guestInputHandler {
            let effectiveFlags = VMGuestAgentKeyboard.effectiveModifierFlags(
                reported: event.modifierFlags,
                characters: event.characters,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers
            )
            if !event.isARepeat,
               let events = VMGuestAgentKeyboard.chordEventsForMissingModifierTransition(
                   forMacVirtualKey: event.keyCode,
                   modifierFlags: effectiveFlags,
                   alreadyPressed: pressedKeys
               ) {
                guestInputHandler(events)
                RiftVMLog.info(
                    "Synthesized missing guest modifier transition for keyCode=\(event.keyCode)",
                    logger: RiftVMLog.input
                )
                return
            }
            guard let code = VMGuestAgentKeyboard.linuxKeyCode(forMacVirtualKey: event.keyCode) else {
                super.keyDown(with: event)
                return
            }
            if !event.isARepeat, !pressedKeys.contains(code) {
                sendKey(code: code, pressed: true, using: guestInputHandler)
            }
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if let guestInputHandler,
           let code = VMGuestAgentKeyboard.linuxKeyCode(forMacVirtualKey: event.keyCode) {
            if pressedKeys.contains(code) {
                sendKey(code: code, pressed: false, using: guestInputHandler)
            }
            return
        }
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        if let guestInputHandler,
           let code = VMGuestAgentKeyboard.linuxKeyCode(forMacVirtualKey: event.keyCode),
           let pressed = VMGuestAgentKeyboard.modifierPressed(
               forMacVirtualKey: event.keyCode,
               flags: event.modifierFlags
           ) {
            if pressed != pressedKeys.contains(code) {
                sendKey(code: code, pressed: pressed, using: guestInputHandler)
            }
            return
        }
        super.flagsChanged(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isHostFullScreenShortcut(event) { return false }
        if forwardCommandChordToGuest(event) { return true }
        // Non-Command equivalents and pre-agent firmware input retain the VZ
        // native fallback. Ordinary desktop key events are handled above.
        return super.performKeyEquivalent(with: event)
    }

    private func forwardCommandChordToGuest(_ event: NSEvent) -> Bool {
        guard managesKeyboardIntegration else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return false }
        guard !event.isARepeat else { return true }
        guard let guestInputHandler,
              let events = VMGuestAgentKeyboard.chordEvents(
                forMacVirtualKey: event.keyCode,
                modifierFlags: flags,
                alreadyPressed: pressedKeys
              ) else { return false }
        // AppKit consumes host Command shortcuts before VZ's native USB
        // keyboard sees them. Send a complete, synchronized Linux Super chord
        // through the standard uinput keyboard instead.
        guestInputHandler(events)
        RiftVMLog.info(
            "Forwarded host Command chord through guest keyboard keyCode=\(event.keyCode)",
            logger: RiftVMLog.input
        )
        return true
    }

    private func isHostFullScreenShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.keyCode == 3 && flags.contains([.command, .control])
    }

    private func forwardPointerMotion(_ event: NSEvent) -> Bool {
        guard guestInputHandler != nil, !isHidden else { return false }
        if absolutePointerEnabled { sendAbsolutePosition(event) }
        else { sendRelativeMotion(event) }
        return true
    }

    override func mouseMoved(with event: NSEvent) {
        if !forwardPointerMotion(event) { super.mouseMoved(with: event) }
    }
    override func mouseDragged(with event: NSEvent) {
        if !forwardPointerMotion(event) { super.mouseDragged(with: event) }
    }
    override func rightMouseDragged(with event: NSEvent) {
        if !forwardPointerMotion(event) { super.rightMouseDragged(with: event) }
    }
    override func otherMouseDragged(with event: NSEvent) {
        if !forwardPointerMotion(event) { super.otherMouseDragged(with: event) }
    }
    override func mouseDown(with event: NSEvent) {
        restoreKeyboardFocus()
        if guestInputHandler != nil, !isHidden {
            if absolutePointerEnabled { sendAbsolutePosition(event) }
            else { capturePointer() }
            sendButton(code: 272, pressed: true)
        } else {
            super.mouseDown(with: event)
        }
    }
    override func mouseUp(with event: NSEvent) {
        if guestInputHandler != nil, !isHidden {
            if absolutePointerEnabled { sendAbsolutePosition(event) }
            sendButton(code: 272, pressed: false)
        } else {
            super.mouseUp(with: event)
        }
    }
    override func rightMouseDown(with event: NSEvent) {
        restoreKeyboardFocus()
        if guestInputHandler != nil, !isHidden {
            if absolutePointerEnabled { sendAbsolutePosition(event) }
            else { capturePointer() }
            sendButton(code: 273, pressed: true)
        } else {
            super.rightMouseDown(with: event)
        }
    }
    override func rightMouseUp(with event: NSEvent) {
        if guestInputHandler != nil, !isHidden {
            if absolutePointerEnabled { sendAbsolutePosition(event) }
            sendButton(code: 273, pressed: false)
        } else {
            super.rightMouseUp(with: event)
        }
    }
    override func otherMouseDown(with event: NSEvent) {
        restoreKeyboardFocus()
        if guestInputHandler != nil, !isHidden {
            if absolutePointerEnabled { sendAbsolutePosition(event) }
            else { capturePointer() }
            sendButton(code: 274, pressed: true)
        } else {
            super.otherMouseDown(with: event)
        }
    }
    override func otherMouseUp(with event: NSEvent) {
        if guestInputHandler != nil, !isHidden {
            if absolutePointerEnabled { sendAbsolutePosition(event) }
            sendButton(code: 274, pressed: false)
        } else {
            super.otherMouseUp(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let guestInputHandler else {
            super.scrollWheel(with: event)
            return
        }
        let detents = scrollWheelAccumulator.consume(
            delta: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas
        )
        guard detents != 0 else { return }
        guestInputHandler([
            VMGuestAgentInputEvent(type: 2, code: 8, value: detents),
            VMGuestAgentInputEvent(type: 0, code: 0, value: 0),
        ])
    }

    private func sendRelativeMotion(_ event: NSEvent) {
        guard pointerCaptured else { return }
        let x = Int32(max(-32767, min(32767, Int(event.deltaX.rounded()))))
        let y = Int32(max(-32767, min(32767, Int(event.deltaY.rounded()))))
        guard x != 0 || y != 0 else { return }
        var events: [VMGuestAgentInputEvent] = []
        if x != 0 { events.append(.init(type: 2, code: 0, value: x)) }
        if y != 0 { events.append(.init(type: 2, code: 1, value: y)) }
        events.append(.init(type: 0, code: 0, value: 0))
        guestInputHandler?(events)
    }

    private func sendAbsolutePosition(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let coordinates = VMAbsolutePointerMapper.coordinates(
            for: point,
            in: metalLayer.frame
        ) else { return }
        cursorPresentation.noteAbsolutePointerEvent()
        guestInputHandler?(VMAbsolutePointerMapper.events(x: coordinates.x, y: coordinates.y))
    }

    func setAbsolutePointerEnabled(_ enabled: Bool) {
        guard absolutePointerEnabled != enabled else { return }
        absolutePointerEnabled = enabled
        if enabled { releaseInputCapture() }
        // In absolute mode the native macOS cursor is already at the exact
        // guest position. Hide the separately composited GPU cursor to avoid
        // a delayed duplicate while preserving natural boundary crossing.
        cursorLayer.isHidden = enabled || cursorLayer.contents == nil
        // Leaving absolute mode restores the system cursor that stood in for
        // the guest's own.
        window?.invalidateCursorRects(for: self)
        RiftVMLog.info("VirGL absolute pointer enabled=\(enabled)", logger: RiftVMLog.graphics)
    }

    private func sendButton(code: UInt16, pressed: Bool) {
        if pressed { pressedButtons.insert(code) } else { pressedButtons.remove(code) }
        guestInputHandler?(VMGuestAgentInputBatch.key(code: code, pressed: pressed).events)
    }

    private func sendKey(
        code: UInt16,
        pressed: Bool,
        using handler: ([VMGuestAgentInputEvent]) -> Void
    ) {
        if pressed { pressedKeys.insert(code) } else { pressedKeys.remove(code) }
        handler(VMGuestAgentInputBatch.key(code: code, pressed: pressed).events)
    }

    private func schedulePresentationRetry() {
        guard displayRefreshTimer == nil, canPresentFrames,
              presentationDemand.isPending, latestScanout != nil,
              presentationLifecycle.tokenForPresentation() != nil else { return }
        // Normal frames are entirely event driven. A failed last frame gets a
        // bounded, one-shot retry instead of relying on another Guest flush.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.displayRefreshTimer = nil
            self.drainLatestPresentation()
        }
        displayRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // Keep the live scanout while occluded, but stop acquiring drawables and
    // waking the presentation timer. Restoration immediately uses the newest
    // scanout even if the Guest has not issued another RESOURCE_FLUSH.
    func refreshPresentationActivity() {
        guard canPresentFrames, presentationLifecycle.tokenForPresentation() != nil,
              let scanout = latestScanout else {
            if presentationIsActive { displayActivityGeneration &+= 1 }
            presentationIsActive = false
            displayRefreshTimer?.invalidate()
            displayRefreshTimer = nil
            return
        }
        let wasInactive = !presentationIsActive
        presentationIsActive = true
        if wasInactive {
            presentationDemand.request()
            resetPerformanceWindow(at: CACurrentMediaTime())
            presentFrame(resourceID: scanout.resourceID, x: scanout.x, y: scanout.y,
                         width: scanout.width, height: scanout.height)
        }
    }

    override func viewDidHide() {
        super.viewDidHide()
        refreshPresentationActivity()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        refreshPresentationActivity()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if usesCustomGraphics { updateDrawableGeometry() }
    }

    private func releaseShortcutIsActive(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains([.control, .option])
    }

    private func restoreKeyboardFocus() {
        guard let window else { return }
        if !window.isKeyWindow { window.makeKey() }
        window.makeFirstResponder(self)
    }

    private func capturePointer() {
        guard !pointerCaptured, window?.isKeyWindow == true else { return }
        pointerCaptured = true
        restoreKeyboardFocus()
        NSCursor.hide()
        CGAssociateMouseAndMouseCursorPosition(boolean_t(0))
    }

    func releaseInputCapture() {
        if let guestInputHandler {
            for code in pressedKeys.sorted() {
                guestInputHandler(VMGuestAgentInputBatch.key(code: code, pressed: false).events)
            }
            for code in pressedButtons.sorted() {
                guestInputHandler(VMGuestAgentInputBatch.key(code: code, pressed: false).events)
            }
        }
        pressedKeys.removeAll()
        pressedButtons.removeAll()
        guard pointerCaptured else { return }
        pointerCaptured = false
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        NSCursor.unhide()
    }

    override func layout() {
        super.layout()
        if usesCustomGraphics {
            updateDrawableGeometry()
            updateCursorGeometry()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        window?.acceptsMouseMovedEvents = true
        guard let window else {
            releaseInputCapture()
            refreshPresentationActivity()
            return
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) {
                [weak self] _ in self?.refreshPresentationActivity()
            })
        }
        refreshPresentationActivity()
        windowObservers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in self?.releaseInputCapture() })
        windowObservers.append(center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in self?.releaseInputCapture() })
    }

    override func updateTrackingAreas() {
        guard usesCustomGraphics else { super.updateTrackingAreas(); return }
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
        super.updateTrackingAreas()
    }

    func updateCursor(_ update: RiftVMVirGLRuntime.CursorUpdate) {
        guard presentationLifecycle.tokenForPresentation() != nil else { return }
        cursorPosition = CGPoint(x: Int(update.x), y: Int(update.y))
        if update.replacesImage {
            cursorHotspot = CGPoint(x: Int(update.hotX), y: Int(update.hotY))
            if let image = update.image {
                cursorLayer.contents = image
                cursorImageSize = CGSize(width: image.width, height: image.height)
            } else {
                cursorLayer.contents = nil
                cursorImageSize = .zero
            }
        }
        cursorPlaneUpdateReceived()
        cursorLayer.isHidden = absolutePointerEnabled || !update.isVisible
        updateCursorGeometry()
    }

    /// A guest that drives virtio-gpu's cursor plane can never be painting its
    /// own cursor into the scanout, so this also releases the macOS cursor when
    /// the guest switched strategies mid-session.
    private func cursorPlaneUpdateReceived() {
        let wasHiding = cursorPresentation.hidesSystemCursor
        cursorPresentation.noteCursorPlaneUpdate()
        if wasHiding != cursorPresentation.hidesSystemCursor {
            window?.invalidateCursorRects(for: self)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        // Absolute mode keeps the macOS cursor as the pointer unless the guest
        // already drew one into the frame; relative mode manages the cursor
        // through capture instead.
        guard absolutePointerEnabled, cursorPresentation.hidesSystemCursor else { return }
        addCursorRect(bounds, cursor: Self.blankCursor)
    }

    /// A fully transparent cursor used to yield to a cursor the guest drew.
    private static let blankCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 1, height: 1), flipped: false) { rect in
            NSColor.clear.setFill()
            rect.fill()
            return true
        }
        return NSCursor(image: image, hotSpot: .zero)
    }()

    func present(
        resourceID: UInt32,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        eventSequence: UInt64
    ) {
        guard presentationLifecycle.tokenForPresentation() != nil else { return }
        guard presentationEventFence.accept(eventSequence) else { return }
        latestScanout = (resourceID, x, y, width, height)
        presentationDemand.request()
        guard canPresentFrames else {
            refreshPresentationActivity()
            return
        }
        presentationIsActive = true
        presentFrame(resourceID: resourceID, x: x, y: y, width: width, height: height)
    }

    func presentFrame(resourceID: UInt32, x: Int, y: Int, width: Int, height: Int) {
        guard canPresentFrames else { return }
        guard let presentationToken = presentationLifecycle.tokenForPresentation() else { return }
        requestedFramesInWindow &+= 1
        if width > 0, height > 0 {
            guestSize = CGSize(width: width, height: height)
        }
        updateDrawableGeometry()
        // Preserve damage received while the drawable/renderer is busy. The
        // completion drains it even when the Guest never submits another frame.
        guard !presentationInFlight else {
            recordPerformanceIfNeeded()
            return
        }
        guard presentationDemand.take() else { return }
        guard let runtime else {
            failuresInWindow &+= 1
            recordPresentationResult(success: false)
            recordPerformanceIfNeeded()
            return
        }
        let frameStartedAt = CACurrentMediaTime()
        let targetLayer = metalLayer
        presentationInFlight = true
        let activityGeneration = displayActivityGeneration
        drawableAcquirer.acquire({ targetLayer.nextDrawable() }) { [weak self] drawable, wait in
            guard let self,
                  self.presentationLifecycle.acceptsCompletion(token: presentationToken) else { return }
            guard self.canPresentFrames, self.displayActivityGeneration == activityGeneration else {
                self.presentationInFlight = false
                self.presentLatestAfterActivityChange()
                return
            }
            // Include nil acquisitions; their wait would otherwise disappear.
            self.drawableWaitDurationsInWindow.append(wait)
            guard let drawable else {
                self.presentationInFlight = false
                self.drawableMissesInWindow &+= 1
                self.presentationDemand.retryAfterFailure()
                self.schedulePresentationRetry()
                self.recordPerformanceIfNeeded()
                return
            }
            let startedAt = CACurrentMediaTime()
            runtime.presentAsync(
                resourceID: resourceID,
                sourceX: x, sourceY: y, sourceWidth: width, sourceHeight: height,
                into: drawable.texture
            ) { [weak self] succeeded in
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.presentationLifecycle.acceptsCompletion(token: presentationToken) else { return }
                    self.presentationInFlight = false
                    // A frame already in flight may complete after occlusion.
                    guard self.canPresentFrames else { return }
                    guard self.displayActivityGeneration == activityGeneration else {
                        // A hide/show or scanout invalidation may overtake a
                        // renderer completion. Discard its drawable and immediately
                        // schedule the latest scanout without allowing two in flight.
                        self.presentLatestAfterActivityChange()
                        return
                    }
                    if succeeded { drawable.present() }
                    self.frameDurationsInWindow.append(CACurrentMediaTime() - frameStartedAt)
                    if succeeded {
                        self.recordPresentationResult(success: true)
                        let duration = CACurrentMediaTime() - startedAt
                        self.totalPresentationTimeInWindow += duration
                        self.maximumPresentationTimeInWindow = max(self.maximumPresentationTimeInWindow, duration)
                        self.presentationDurationsInWindow.append(duration)
                        self.presentedFrames &+= 1
                        self.presentedFramesInWindow &+= 1
                        self.notePresentedFrameForCursor()
                        if self.presentedFrames == 1 || self.presentedFrames.isMultiple(of: 600) {
                            RiftVMLog.info("VirGL zero-copy frames presented: \(self.presentedFrames)", logger: RiftVMLog.graphics)
                        }
                    } else {
                        self.failuresInWindow &+= 1
                        self.recordPresentationResult(success: false)
                        self.presentationDemand.retryAfterFailure()
                        self.schedulePresentationRetry()
                        RiftVMLog.error("VirGL zero-copy presentation failed for resource \(resourceID)")
                    }
                    self.recordPerformanceIfNeeded()
                    if succeeded { self.drainLatestPresentation() }
                }
            }
        }
    }

    /// A guest that draws its own cursor repaints in response to pointer
    /// events while never driving the cursor plane; the first such repaint
    /// hands the pointer over from the macOS cursor to the guest's own.
    private func notePresentedFrameForCursor() {
        let wasHiding = cursorPresentation.hidesSystemCursor
        cursorPresentation.notePresentedFrame()
        if wasHiding != cursorPresentation.hidesSystemCursor {
            window?.invalidateCursorRects(for: self)
        }
    }

    private func drainLatestPresentation() {
        guard presentationDemand.isPending else {
            displayRefreshTimer?.invalidate()
            displayRefreshTimer = nil
            return
        }
        guard canPresentFrames, let scanout = latestScanout else { return }
        presentFrame(resourceID: scanout.resourceID, x: scanout.x, y: scanout.y,
                     width: scanout.width, height: scanout.height)
    }

    private func presentLatestAfterActivityChange() {
        guard canPresentFrames, let scanout = latestScanout else { return }
        presentationDemand.request()
        presentationIsActive = true
        presentFrame(resourceID: scanout.resourceID, x: scanout.x, y: scanout.y,
                     width: scanout.width, height: scanout.height)
    }

    private func recordPresentationResult(success: Bool) {
        switch presentationHealth.record(success: success) {
        case .none:
            break
        case .degraded:
            runtimeIssueHandler?(
                String(localized: "Custom VirGL repeatedly failed to present the guest display. The VM is still running. If the display does not recover, stop it and restart; report the graphics diagnostics if the problem persists.")
            )
        case .recovered:
            runtimeIssueHandler?(nil)
        }
    }

    private func recordPerformanceIfNeeded() {
        let now = CACurrentMediaTime()
        let elapsed = now - performanceWindowStartedAt
        guard elapsed >= 5 else { return }
        let fps = Double(presentedFramesInWindow) / elapsed
        let averageMilliseconds = presentedFramesInWindow == 0
            ? 0
            : totalPresentationTimeInWindow * 1_000 / Double(presentedFramesInWindow)
        let sortedDurations = presentationDurationsInWindow.sorted()
        let p95Milliseconds: Double
        if sortedDurations.isEmpty {
            p95Milliseconds = 0
        } else {
            let percentileIndex = Int(ceil(Double(sortedDurations.count) * 0.95)) - 1
            p95Milliseconds = sortedDurations[max(0, percentileIndex)] * 1_000
        }
        let drawable = metalLayer.drawableSize
        let summary = String(
                format: "VirGL performance: fps=%.1f requested=%llu presented=%llu drawableMisses=%llu failures=%llu avgPresentMs=%.2f p95PresentMs=%.2f maxPresentMs=%.2f drawable=%.0fx%.0f",
                fps,
                requestedFramesInWindow,
                presentedFramesInWindow,
                drawableMissesInWindow,
                failuresInWindow,
                averageMilliseconds,
                p95Milliseconds,
                maximumPresentationTimeInWindow * 1_000,
                drawable.width,
                drawable.height
            )
        let drawableTiming = VMGraphicsTimingSummary(durations: drawableWaitDurationsInWindow)
        let frameTiming = VMGraphicsTimingSummary(durations: frameDurationsInWindow)
        let completeSummary = summary + String(
            format: " timingVersion=2 avgDrawableMs=%.2f p95DrawableMs=%.2f maxDrawableMs=%.2f avgFrameMs=%.2f p95FrameMs=%.2f maxFrameMs=%.2f",
            drawableTiming.averageMilliseconds, drawableTiming.p95Milliseconds, drawableTiming.maximumMilliseconds,
            frameTiming.averageMilliseconds, frameTiming.p95Milliseconds, frameTiming.maximumMilliseconds
        )
        RiftVMLog.info(completeSummary, logger: RiftVMLog.graphics)
        if ProcessInfo.processInfo.environment["RIFTVM_VIRGL_DIAGNOSTICS"] == "1",
           let file = fopen("/tmp/riftvm-virgl-presentation.log", "a") {
            fputs("\(completeSummary) bounds=\(Int(bounds.width))x\(Int(bounds.height)) guest=\(Int(guestSize.width))x\(Int(guestSize.height)) layer=\(Int(metalLayer.frame.width))x\(Int(metalLayer.frame.height))\n", file)
            fclose(file)
        }
        resetPerformanceWindow(at: now)
    }

    private func resetPerformanceWindow(at now: TimeInterval) {
        performanceWindowStartedAt = now
        requestedFramesInWindow = 0
        presentedFramesInWindow = 0
        drawableMissesInWindow = 0
        failuresInWindow = 0
        totalPresentationTimeInWindow = 0
        maximumPresentationTimeInWindow = 0
        presentationDurationsInWindow.removeAll(keepingCapacity: true)
        drawableWaitDurationsInWindow.removeAll(keepingCapacity: true)
        frameDurationsInWindow.removeAll(keepingCapacity: true)
    }

    private func updateDrawableGeometry() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let presentationFrame = VMDisplayGeometry.aspectFit(content: guestSize, in: bounds)
        let drawableSize = CGSize(
            width: max(1, presentationFrame.width * scale),
            height: max(1, presentationFrame.height * scale)
        )
        guard metalLayer.frame != presentationFrame || metalLayer.contentsScale != scale
                || metalLayer.drawableSize != drawableSize else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if metalLayer.frame != presentationFrame { metalLayer.frame = presentationFrame }
        if metalLayer.contentsScale != scale { metalLayer.contentsScale = scale }
        if metalLayer.drawableSize != drawableSize { metalLayer.drawableSize = drawableSize }
        CATransaction.commit()
        if latestScanout != nil {
            presentationDemand.request()
            DispatchQueue.main.async { [weak self] in self?.drainLatestPresentation() }
        }
    }

    private func updateCursorGeometry() {
        guard guestSize.width > 0, guestSize.height > 0 else { return }
        let presentationSize = metalLayer.bounds.size
        let scaleX = presentationSize.width / guestSize.width
        let scaleY = presentationSize.height / guestSize.height
        let width = cursorImageSize.width * scaleX
        let height = cursorImageSize.height * scaleY
        let x = (cursorPosition.x - cursorHotspot.x) * scaleX
        let top = (cursorPosition.y - cursorHotspot.y) * scaleY
        cursorLayer.frame = CGRect(x: x, y: presentationSize.height - top - height, width: width, height: height)
    }
}

@available(macOS 27.0, *)
final class VMCustomVirGLGraphicsBackend: VMGraphicsBackend {
    let kind = VMGraphicsBackendKind.customVirGL
    // Restoring guest RAM alone cannot reconstruct VirGL contexts, resources,
    // fences, or renderer command-stream state. Keep VZ machine-state saving
    // disabled until the complete GPU state has a versioned representation.
    let supportsMachineSaveRestore = false
    let displayView: NSView
    private let virglView: VMVirGLDisplayView
    private var runtime: RiftVMVirGLRuntime?
    let deviceConfigurations: [VZCustomVirtioDeviceConfiguration]
    private var requestedResolution: (width: UInt32, height: UInt32)?
    private var pendingDisplayRequest: DispatchWorkItem?
    private var dynamicDisplayReady = false
    /// The size the window has to hold before it becomes a DRM mode, and the
    /// bookkeeping that keeps a burst of samples or an alternating host from
    /// turning into a burst of guest output rebuilds.
    private var stableDisplayCandidate: (width: UInt32, height: UInt32)?
    private var stableDisplayCandidateSince: TimeInterval = 0
    private var publishedDisplayModes: [(width: UInt32, height: UInt32, at: TimeInterval)] = []
    private static let displayStabilityWindow: TimeInterval = 2.0
    private static let displayPublishWindow: TimeInterval = 30
    private static let displayPublishLimit = 6
    private static let displayHoldWindow: TimeInterval = 10
    private let dynamicDisplayEnabled = ProcessInfo.processInfo.environment[
        "RIFTVM_DISABLE_DYNAMIC_VIRGL_DISPLAY"
    ] != "1"

    init(devices: [VMModelFieldGraphicDevice], displayView: VMVirGLDisplayView? = nil) throws {
        let device = devices.first ?? .default(osType: .linux)
        let initialResolution = VMDisplayGeometry.guestResolution(for: CGSize(
            width: max(1, device.width),
            height: max(1, device.height)
        ))
        let dependencies = VirGLRuntimeDependencies.resolve()
        try dependencies.validate()
        let view = displayView ?? VMVirGLDisplayView(
            frame: .zero,
            guestSize: CGSize(
                width: Int(initialResolution.width),
                height: Int(initialResolution.height)
            )
        )
        virglView = view
        self.displayView = view
        let runtime = try RiftVMVirGLRuntime(
            configuration: .init(
                width: initialResolution.width,
                height: initialResolution.height,
                rendererLibraryURL: dependencies.virglRendererURL,
                experimentalStaticInputEnabled: ProcessInfo.processInfo.environment[
                    "RIFTVM_EXPERIMENTAL_STATIC_VIRTIO_INPUT"
                ] == "1"
            ),
            onScanout: { [weak view] resourceID, x, y, width, height, eventSequence in
                view?.present(
                    resourceID: resourceID,
                    x: x, y: y, width: width, height: height,
                    eventSequence: eventSequence
                )
            },
            onScanoutInvalidated: { [weak view] eventSequence in
                view?.invalidateScanout(eventSequence: eventSequence)
            },
            onCursor: { [weak view] update in
                view?.updateCursor(update)
            }
        )
        // Create every Virtualization.framework device while the backend is
        // still inside the factory's recoverable initialization boundary. If
        // this fails, the factory can discard the runtime and select Apple
        // Virtio before a VZVirtualMachine or guest-visible device exists.
        let deviceConfigurations = try runtime.makeDeviceConfigurations()
        self.runtime = runtime
        self.deviceConfigurations = deviceConfigurations
        requestedResolution = initialResolution
        view.runtime = runtime
    }

    func applyGraphics(
        from devices: [VMModelFieldGraphicDevice],
        to configuration: VZVirtualMachineConfiguration
    ) -> VMOSResultVoid {
        configuration.graphicsDevices = []
        configuration.customVirtioDevices.append(contentsOf: deviceConfigurations)
        return .success
    }

    func bind(virtualMachine: VZVirtualMachine?) {
        virglView.virtualMachine = virtualMachine
    }

    func refreshDisplayConfiguration() {
        guard dynamicDisplayEnabled else {
            let size = virglView.bounds.size
            RiftVMLog.info(
                "VirGL stable-canvas scaling: logical=\(Int(size.width))x\(Int(size.height))",
                logger: RiftVMLog.graphics
            )
            return
        }
        // A Linux text console can acknowledge a new virtio-gpu mode and then
        // immediately replace it with its 800x600 fbcon fallback. Omarchy's
        // first-boot form runs on that console, before Hyprland and its display
        // watcher exist. Keep the persisted 1280x720 boot mode until the Guest
        // Agent reports a real desktop session; otherwise the setup UI becomes
        // cropped even though host-side mode negotiation succeeded.
        guard dynamicDisplayReady else { return }
        pendingDisplayRequest?.cancel()
        scheduleDisplaySample(after: 0.35)
    }

    /// A resize, a full-screen transition, and the macOS toolbar or safe area
    /// moving all expose a burst of different view sizes, and every size that
    /// reaches DRM makes the guest destroy and rebuild its outputs: a burst of
    /// samples becomes a burst of flashes. Sample the window rather than the
    /// display view, let the size hold still before it becomes a mode, and keep
    /// a candidate off DRM while the window is still moving.
    private func scheduleDisplaySample(after delay: TimeInterval) {
        let request = DispatchWorkItem { [weak self] in self?.sampleStableDisplaySize() }
        pendingDisplayRequest = request
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: request)
    }

    private func sampleStableDisplaySize() {
        // The window frame only changes when the window changes. `virglView.bounds`
        // also shrinks while an auto-hidden full-screen toolbar slides in, which is
        // presentation, not a new display size.
        let size = virglView.window?.frame.size ?? virglView.bounds.size
        let candidate = VMDisplayGeometry.guestResolution(for: size)
        let now = Date().timeIntervalSinceReferenceDate
        if let stable = stableDisplayCandidate,
           VMDisplayGeometry.isSameResolution(stable, candidate) {
            let held = now - stableDisplayCandidateSince
            guard held >= Self.displayStabilityWindow else {
                scheduleDisplaySample(after: Self.displayStabilityWindow - held)
                return
            }
        } else {
            stableDisplayCandidate = candidate
            stableDisplayCandidateSince = now
            scheduleDisplaySample(after: Self.displayStabilityWindow)
            return
        }
        stableDisplayCandidate = nil
        publishDisplaySize(candidate: candidate, sampled: size)
    }

    private func publishDisplaySize(
        candidate: (width: UInt32, height: UInt32),
        sampled: CGSize
    ) {
        let resolution = VMDisplayGeometry.stabilizedResolution(
            candidate: candidate,
            current: requestedResolution ?? candidate
        )
        let now = Date().timeIntervalSinceReferenceDate
        publishedDisplayModes.removeAll { now - $0.at > Self.displayPublishWindow }
        RiftVMLog.info(
            "VirGL display sample: window=\(Int(sampled.width))x\(Int(sampled.height))"
                + " view=\(Int(virglView.bounds.width))x\(Int(virglView.bounds.height))"
                + " candidate=\(candidate.width)x\(candidate.height)"
                + " guest=\(resolution.width)x\(resolution.height)"
                + " recentModes=\(publishedDisplayModes.count)",
            logger: RiftVMLog.graphics
        )
        guard requestedResolution?.width != resolution.width
                || requestedResolution?.height != resolution.height else { return }

        // A↔B flapping is the case that makes the desktop unusable: the host
        // keeps offering the two sizes, and the guest switches outputs for each
        // step. Hold the current mode instead of following it.
        if let previous = publishedDisplayModes.dropLast().last,
           previous.width == resolution.width,
           previous.height == resolution.height {
            RiftVMLog.info(
                "VirGL display request held: \(resolution.width)x\(resolution.height) was the"
                    + " previous mode \(Int(now - previous.at))s ago; the host is alternating",
                logger: RiftVMLog.graphics
            )
            holdDisplayPublishing(candidate: candidate, now: now)
            return
        }
        guard publishedDisplayModes.count < Self.displayPublishLimit else {
            RiftVMLog.info(
                "VirGL display request held: \(publishedDisplayModes.count) modes in"
                    + " \(Int(Self.displayPublishWindow))s",
                logger: RiftVMLog.graphics
            )
            holdDisplayPublishing(candidate: candidate, now: now)
            return
        }
        publishedDisplayModes.append((width: resolution.width, height: resolution.height, at: now))
        requestedResolution = resolution
        runtime?.requestDisplaySize(width: resolution.width, height: resolution.height)
    }

    /// Re-offer the size once the hold expires, so a genuine resize is applied
    /// after a burst instead of being dropped.
    private func holdDisplayPublishing(
        candidate: (width: UInt32, height: UInt32),
        now: TimeInterval
    ) {
        stableDisplayCandidate = candidate
        stableDisplayCandidateSince = now
        scheduleDisplaySample(after: Self.displayHoldWindow)
    }

    func setDynamicDisplayReady(_ ready: Bool) {
        guard dynamicDisplayReady != ready else { return }
        dynamicDisplayReady = ready
        if ready {
            requestedResolution = nil
            refreshDisplayConfiguration()
        } else {
            pendingDisplayRequest?.cancel()
            pendingDisplayRequest = nil
        }
    }

    func setGuestInputHandler(_ handler: (([VMGuestAgentInputEvent]) -> Void)?) {
        virglView.setGuestInputHandler(handler)
    }

    func setKeyboardIntegrationStateHandler(
        _ handler: ((VMKeyboardIntegrationState) -> Void)?
    ) {
        virglView.setKeyboardIntegrationStateHandler(handler)
    }

    func requestKeyboardIntegrationPermission() {
        virglView.requestKeyboardIntegrationPermission()
    }

    func setAbsolutePointerEnabled(_ enabled: Bool) {
        virglView.setAbsolutePointerEnabled(enabled)
    }

    func setRuntimeIssueHandler(_ handler: ((String?) -> Void)?) {
        virglView.runtimeIssueHandler = handler
    }

    func shutdown() {
        pendingDisplayRequest?.cancel()
        pendingDisplayRequest = nil
        virglView.stopPresentation()
        virglView.virtualMachine = nil
        virglView.setGuestInputHandler(nil)
        virglView.setKeyboardIntegrationStateHandler(nil)
        virglView.runtimeIssueHandler = nil
        virglView.runtime = nil
        runtime?.shutdown()
        runtime = nil
    }
}

struct VMGraphicsBackendCreation {
    let backend: any VMGraphicsBackend
    let detail: String?
}

enum VMGraphicsBackendFactory {
    // This flips to true only when the production Custom Virtio GPU runtime,
    // presenter, and lifecycle implementation are linked into the app target.
    static let customBackendImplemented = true

    static func make(
        forLinux: Bool = true,
        devices: [VMModelFieldGraphicDevice],
        requested: VMLinuxGraphicsBackend = .customVirGL,
        hasInstallationMedia: Bool = false,
        guestInputReady: Bool = true,
        forceAppleGraphics: Bool = false
    ) throws -> VMGraphicsBackendCreation {
        guard forLinux else {
            return VMGraphicsBackendCreation(backend: VMAppleGraphicsBackend(kind: .appleMac), detail: nil)
        }
        if forceAppleGraphics || requested == .appleVirtio {
            return VMGraphicsBackendCreation(backend: VMAppleGraphicsBackend(), detail: nil)
        }
        let selection = VMGraphicsBackendSelection.resolve(
            isLinux: true,
            hostSupportsCustomVirtio: VirtualizationCapability.customVirtio.isAvailable,
            requested: requested,
            customBackendImplemented: customBackendImplemented,
            hasInstallationMedia: hasInstallationMedia,
            guestInputReady: guestInputReady
        )
        guard selection.active == .customVirGL else {
            throw VMOSError.regularFailure("\(selection.unavailabilityReason ?? "Custom VirGL is unavailable.") Shut down and open Settings → Display to change the backend.")
        }
        do {
            return VMGraphicsBackendCreation(
                backend: try VMCustomVirGLGraphicsBackend(devices: devices), detail: nil
            )
        } catch {
            throw VMOSError.regularFailure("Custom VirGL could not start: \(error.localizedDescription). Verify the bundled runtime, or shut down and choose Apple Virtio in Settings → Display.")
        }
    }
}

#endif
