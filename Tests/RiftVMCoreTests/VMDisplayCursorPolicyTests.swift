import XCTest
@testable import RiftVMCore

final class VMDisplayCursorPolicyTests: XCTestCase {
    func testBeforeTheGuestUsesItsCursorPlaneTheSystemArrowIsThePointer() {
        let state = VMGuestCursorState()
        XCTAssertEqual(
            state.hostCursor(absolutePointer: true, captured: false, insideGuestImage: true),
            .system
        )
        XCTAssertFalse(state.showsCursorLayer(absolutePointer: true, captured: false))
    }

    func testAVisibleGuestCursorBecomesTheOnlyPointer() {
        var state = VMGuestCursorState()
        state.noteCursorPlane(visible: true, at: 10)
        XCTAssertEqual(
            state.hostCursor(absolutePointer: true, captured: false, insideGuestImage: true),
            .guestImage
        )
        // Never a second, composited copy while the macOS cursor carries it.
        XCTAssertFalse(state.showsCursorLayer(absolutePointer: true, captured: false))
    }

    func testAHiddenGuestCursorHidesTheHostCursorAndComesBack() {
        var state = VMGuestCursorState()
        state.noteCursorPlane(visible: true, at: 10)
        state.noteCursorPlane(visible: false, at: 11)
        XCTAssertEqual(
            state.hostCursor(absolutePointer: true, captured: false, insideGuestImage: true),
            .hidden
        )
        state.noteCursorPlane(visible: true, at: 10)
        XCTAssertEqual(
            state.hostCursor(absolutePointer: true, captured: false, insideGuestImage: true),
            .guestImage
        )
    }

    func testTheLetterboxKeepsTheSystemArrow() {
        var state = VMGuestCursorState()
        state.noteCursorPlane(visible: false, at: 11)
        XCTAssertEqual(
            state.hostCursor(absolutePointer: true, captured: false, insideGuestImage: false),
            .system
        )
    }

    func testACapturedPointerHidesTheMacCursorAndDrawsTheGuestCursor() {
        var state = VMGuestCursorState()
        state.noteCursorPlane(visible: true, at: 10)
        XCTAssertEqual(
            state.hostCursor(absolutePointer: false, captured: true, insideGuestImage: true),
            .hidden
        )
        XCTAssertTrue(state.showsCursorLayer(absolutePointer: false, captured: true))
        // An uncaptured relative pointer is the macOS cursor alone.
        XCTAssertEqual(
            state.hostCursor(absolutePointer: false, captured: false, insideGuestImage: true),
            .system
        )
        XCTAssertFalse(state.showsCursorLayer(absolutePointer: false, captured: false))
    }

    func testResetForgetsTheCursorPlane() {
        var state = VMGuestCursorState()
        state.noteCursorPlane(visible: true, at: 10)
        state.reset()
        XCTAssertEqual(state, VMGuestCursorState())
    }

    func testHostCursorGeometryScalesAndClampsTheHotspot() {
        let geometry = VMGuestCursorState.hostCursorGeometry(
            imagePixels: CGSize(width: 64, height: 64),
            hotspotPixels: CGPoint(x: 4, y: 6),
            scale: 0.5
        )
        XCTAssertEqual(geometry.size, CGSize(width: 32, height: 32))
        XCTAssertEqual(geometry.hotSpot, CGPoint(x: 2, y: 3))

        let clamped = VMGuestCursorState.hostCursorGeometry(
            imagePixels: CGSize(width: 64, height: 64),
            hotspotPixels: CGPoint(x: 70, y: -3),
            scale: 2
        )
        XCTAssertEqual(clamped.hotSpot, CGPoint(x: 127, y: 0))

        let invalidScale = VMGuestCursorState.hostCursorGeometry(
            imagePixels: CGSize(width: 24, height: 24),
            hotspotPixels: .zero,
            scale: .nan
        )
        XCTAssertEqual(invalidScale.size, CGSize(width: 24, height: 24))
    }
    func testAHideRightAfterAShowIsTheBlinkNotIntent() {
        var state = VMGuestCursorState()
        state.noteCursorPlane(visible: true, at: 10)
        state.noteCursorPlane(visible: false, at: 10.02)
        XCTAssertEqual(
            state.hostCursor(absolutePointer: true, captured: false, insideGuestImage: true),
            .guestImage
        )
        // The blink's off-phase repeating never wears the debounce down.
        state.noteCursorPlane(visible: true, at: 10.05)
        state.noteCursorPlane(visible: false, at: 10.07)
        XCTAssertEqual(
            state.hostCursor(absolutePointer: true, captured: false, insideGuestImage: true),
            .guestImage
        )
    }

    func testAHideAtRestIsIntentAndStillApplies() {
        var state = VMGuestCursorState()
        state.noteCursorPlane(visible: true, at: 10)
        state.noteCursorPlane(visible: false, at: 10.5)
        XCTAssertEqual(
            state.hostCursor(absolutePointer: true, captured: false, insideGuestImage: true),
            .hidden
        )
    }

    func testAHideBeforeAnyShowApplies() {
        var state = VMGuestCursorState()
        state.noteCursorPlane(visible: false, at: 10)
        XCTAssertFalse(state.showsCursorLayer(absolutePointer: false, captured: true))
        XCTAssertEqual(
            state.hostCursor(absolutePointer: true, captured: false, insideGuestImage: true),
            .hidden
        )
    }
    func testEqualityIgnoresWhenTheCursorLastShowed() {
        var a = VMGuestCursorState()
        var b = VMGuestCursorState()
        a.noteCursorPlane(visible: true, at: 10)
        b.noteCursorPlane(visible: true, at: 99)
        XCTAssertEqual(a, b)
        b.noteCursorPlane(visible: false, at: 200)
        XCTAssertNotEqual(a, b)
    }
}
