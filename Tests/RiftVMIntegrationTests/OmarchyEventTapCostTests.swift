import AppKit
import CoreGraphics
import XCTest
@testable import RiftVM

/// The session event tap sees every key event of every application. These
/// tests pin the decision it makes from the event alone, and that keyboard
/// focus is only consulted for an event that could be redirected.
final class OmarchyEventTapCostTests: XCTestCase {
    private let keyTypes: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
    private let keyCodes: [CGKeyCode] = [0, 12, 36, 49, 54, 55, 56, 123]
    private let flagSets: [CGEventFlags] = [
        [], .maskShift, .maskControl, .maskAlternate, .maskCommand,
        [.maskCommand, .maskShift], [.maskCommand, .maskAlternate], [.maskCommand, .maskControl],
    ]

    func testCandidateRequiresCommandOnAPhysicalNonModifierKey() {
        func candidate(
            _ type: CGEventType = .keyDown, _ keyCode: CGKeyCode = 49,
            _ flags: CGEventFlags = .maskCommand, synthetic: Bool = false
        ) -> Bool {
            OmarchyCommandCapturePolicy.isRedirectCandidate(
                type: type, keyCode: keyCode, flags: flags, isSynthetic: synthetic
            )
        }
        XCTAssertTrue(candidate())
        XCTAssertTrue(candidate(.keyUp))
        XCTAssertTrue(candidate(.keyDown, 12, [.maskCommand, .maskShift]))
        XCTAssertFalse(candidate(.keyDown, 49, []))
        XCTAssertFalse(candidate(.keyDown, 49, [.maskShift, .maskControl, .maskAlternate]))
        XCTAssertFalse(candidate(synthetic: true))
        XCTAssertFalse(candidate(.flagsChanged))
        XCTAssertFalse(candidate(.tapDisabledByTimeout))
        XCTAssertFalse(candidate(.tapDisabledByUserInput))
        XCTAssertFalse(candidate(.keyDown, 54))
        XCTAssertFalse(candidate(.keyDown, 55))
    }

    func testRedirectIsExactlyFocusAndCandidate() {
        for type in keyTypes {
            for keyCode in keyCodes {
                for flags in flagSets {
                    for synthetic in [false, true] {
                        let candidate = OmarchyCommandCapturePolicy.isRedirectCandidate(
                            type: type, keyCode: keyCode, flags: flags, isSynthetic: synthetic
                        )
                        for focused in [false, true] {
                            XCTAssertEqual(
                                OmarchyCommandCapturePolicy.shouldRedirect(
                                    type: type, keyCode: keyCode, flags: flags,
                                    focused: focused, isSynthetic: synthetic
                                ),
                                focused && candidate,
                                "type=\(type.rawValue) key=\(keyCode) flags=\(flags.rawValue) synthetic=\(synthetic) focused=\(focused)"
                            )
                        }
                    }
                }
            }
        }
    }

    func testRedirectMatchesTheOriginalDecision() {
        // The decision as it was written before it was split.
        func original(
            type: CGEventType, keyCode: CGKeyCode, flags: CGEventFlags,
            focused: Bool, isSynthetic: Bool
        ) -> Bool {
            guard focused, !isSynthetic, flags.contains(.maskCommand) else { return false }
            guard type == .keyDown || type == .keyUp else { return false }
            return keyCode != 54 && keyCode != 55
        }
        for type in keyTypes {
            for keyCode in keyCodes {
                for flags in flagSets {
                    for synthetic in [false, true] {
                        for focused in [false, true] {
                            XCTAssertEqual(
                                OmarchyCommandCapturePolicy.shouldRedirect(
                                    type: type, keyCode: keyCode, flags: flags,
                                    focused: focused, isSynthetic: synthetic
                                ),
                                original(
                                    type: type, keyCode: keyCode, flags: flags,
                                    focused: focused, isSynthetic: synthetic
                                )
                            )
                        }
                    }
                }
            }
        }
    }

    func testKeyboardFocusNeedsEveryCondition() {
        for mask in 0..<16 {
            let values = (0..<4).map { mask & (1 << $0) != 0 }
            XCTAssertEqual(
                OmarchyCommandCapturePolicy.hasKeyboardFocus(
                    applicationActive: values[0], applicationFrontmost: values[1],
                    windowKey: values[2], responderInsideGuest: values[3]
                ),
                mask == 15
            )
        }
    }

    @MainActor
    func testOrdinaryTypingNeverAsksForFocus() throws {
        var probes = 0
        var forwarded = 0
        var posted = 0
        let bridge = OmarchyFocusedCommandBridge(
            focusProbe: { probes += 1; return true },
            stateChanged: { _ in },
            redirectedCommandChord: { _, _ in forwarded += 1; return true },
            postVirtualKeyboardEvent: { _ in posted += 1 }
        )
        defer { bridge.stop() }
        for flags: CGEventFlags in [[], .maskShift, .maskControl, .maskAlternate] {
            for keyCode: CGKeyCode in [0, 36, 49, 123] {
                for down in [true, false] {
                    let event = try XCTUnwrap(
                        CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)
                    )
                    event.flags = flags
                    XCTAssertNotNil(bridge.handleLocalEvent(try XCTUnwrap(NSEvent(cgEvent: event))))
                }
            }
        }
        let synthetic = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true))
        synthetic.flags = .maskCommand
        synthetic.setIntegerValueField(
            .eventSourceUserData, value: OmarchyFocusedCommandBridge.syntheticMarker
        )
        XCTAssertNotNil(bridge.handleLocalEvent(try XCTUnwrap(NSEvent(cgEvent: synthetic))))
        XCTAssertEqual(probes, 0)
        XCTAssertEqual(forwarded, 0)
        XCTAssertEqual(posted, 0)
    }

    @MainActor
    func testCommandChordAsksForFocusOncePerEvent() throws {
        var focused = false
        var probes = 0
        var forwarded: [CGKeyCode] = []
        let bridge = OmarchyFocusedCommandBridge(
            focusProbe: { probes += 1; return focused },
            stateChanged: { _ in },
            redirectedCommandChord: { code, _ in forwarded.append(code); return true }
        )
        defer { bridge.stop() }
        func event(_ down: Bool) throws -> NSEvent {
            let value = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: down))
            value.flags = .maskCommand
            return try XCTUnwrap(NSEvent(cgEvent: value))
        }
        // Another application owns the keyboard: the chord stays with macOS.
        XCTAssertNotNil(bridge.handleLocalEvent(try event(true)))
        XCTAssertNotNil(bridge.handleLocalEvent(try event(false)))
        XCTAssertEqual(probes, 2)
        XCTAssertEqual(forwarded, [])
        focused = true
        XCTAssertNil(bridge.handleLocalEvent(try event(true)))
        XCTAssertEqual(probes, 3)
        XCTAssertEqual(forwarded, [12])
        // The release of a key the Agent owns is decided without asking.
        XCTAssertNil(bridge.handleLocalEvent(try event(false)))
        XCTAssertEqual(probes, 3)
    }

    func testSafetyTimerSlowsDownOnlyWhileCaptureIsEnabled() {
        XCTAssertEqual(OmarchyCaptureSafetyTimerPolicy.interval(for: .enabled), 10)
        for state: OmarchyKeyboardIntegrationState? in [
            nil, .accessibilityRequired, .eventTapUnavailable, .requestingAccessibility,
        ] {
            XCTAssertEqual(OmarchyCaptureSafetyTimerPolicy.interval(for: state), 2)
        }
    }
}
