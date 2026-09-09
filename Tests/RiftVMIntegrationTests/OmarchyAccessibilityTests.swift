import AppKit
import CoreGraphics
import XCTest
@testable import RiftVM

final class OmarchyAccessibilityTests: XCTestCase {
    @MainActor
    func testNativeFallbackReleasesCommandAfterFocusAndModifierChange() throws {
        var focused = true
        var events: [CGEvent] = []
        let bridge = OmarchyFocusedCommandBridge(
            focusProbe: { focused }, stateChanged: { _ in },
            postVirtualKeyboardEvent: { events.append($0) }
        )
        let down = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: true))
        down.flags = .maskCommand
        XCTAssertNil(bridge.handleLocalEvent(try XCTUnwrap(NSEvent(cgEvent: down))))
        focused = false
        let up = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: false))
        up.flags = []
        XCTAssertNil(bridge.handleLocalEvent(try XCTUnwrap(NSEvent(cgEvent: up))))
        XCTAssertEqual(events.map(\.type), [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
        XCTAssertFalse(try XCTUnwrap(events.last).flags.contains(.maskCommand))
        // A second release belongs to macOS; ownership was cleared.
        XCTAssertNotNil(bridge.handleLocalEvent(try XCTUnwrap(NSEvent(cgEvent: up))))
        bridge.stop()
    }

    @MainActor
    func testCommandShortcutMatrixPreservesChordAndHostFocusBoundary() throws {
        for code: CGKeyCode in [36, 49, 12, 13, 3, 8, 9, 18, 19, 48, 123, 124] {
            for flags: CGEventFlags in [.maskCommand, [.maskCommand, .maskShift], [.maskCommand, .maskAlternate], [.maskCommand, .maskControl]] {
                var focused = true
                var forwarded: [(CGKeyCode, CGEventFlags)] = []
                let bridge = OmarchyFocusedCommandBridge(
                    focusProbe: { focused }, stateChanged: { _ in },
                    redirectedCommandChord: { forwarded.append(($0, $1)); return true }
                )
                let down = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true))
                down.flags = flags
                let event = try XCTUnwrap(NSEvent(cgEvent: down))
                XCTAssertNil(bridge.handleLocalEvent(event))
                XCTAssertEqual(forwarded.count, 1)
                XCTAssertEqual(forwarded.first?.0, code)
                XCTAssertEqual(forwarded.first?.1, flags)
                let up = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false))
                up.flags = []
                focused = false
                XCTAssertNil(bridge.handleLocalEvent(try XCTUnwrap(NSEvent(cgEvent: up))))
                XCTAssertNotNil(bridge.handleLocalEvent(event))
                XCTAssertEqual(forwarded.count, 1)
                bridge.stop()
            }
        }
    }

    func testMacOSCatalogNeverFallsBackToHardCodedHistoricalImages() {
        XCTAssertTrue(VMSystemImageCatalog.macOSItems.isEmpty)
    }

    func testAccessibilityButtonTargetsTheAccessibilityPrivacyPane() {
        XCTAssertEqual(
            OmarchyFocusedCommandBridge.accessibilitySettingsURL.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
    }

    func testHostAcceptanceTextEncoderCoversPrintableCredentialCharacters() throws {
        let strokes = try XCTUnwrap(
            OmarchyHostKeyboardTextEncoder.strokes(for: "aZ09-_!@ /?\n")
        )
        XCTAssertEqual(strokes.count, 12)
        XCTAssertEqual(strokes[0], .init(keyCode: 0, shifted: false))
        XCTAssertEqual(strokes[1], .init(keyCode: 6, shifted: true))
        XCTAssertEqual(strokes[2], .init(keyCode: 29, shifted: false))
        XCTAssertEqual(strokes[3], .init(keyCode: 25, shifted: false))
        XCTAssertEqual(strokes.last, .init(keyCode: 36, shifted: false))

        let printableASCII = String(
            (0x20...0x7e).map { Character(UnicodeScalar($0)!) }
        )
        XCTAssertEqual(
            OmarchyHostKeyboardTextEncoder.strokes(for: printableASCII)?.count,
            95
        )
        XCTAssertEqual(
            OmarchyHostKeyboardTextEncoder.deliveryDuration(for: "123456\n"),
            .milliseconds(600)
        )
        XCTAssertEqual(
            OmarchyHostKeyboardTextEncoder.eventQueueDuration(for: "x"),
            .milliseconds(75)
        )
        XCTAssertEqual(
            OmarchyHostKeyboardTextEncoder.eventQueueDuration(for: "X"),
            .milliseconds(125)
        )
    }

    func testHostAcceptanceTextEncoderRejectsNonASCII() {
        XCTAssertNil(OmarchyHostKeyboardTextEncoder.strokes(for: "密碼"))
    }
}
