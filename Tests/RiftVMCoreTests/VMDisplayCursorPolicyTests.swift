import XCTest
@testable import RiftVMCore

final class VMDisplayCursorPolicyTests: XCTestCase {
    func testGuestThatDrivesTheCursorPlaneYieldsTheSystemCursor() {
        var policy = VMGuestCursorPresentationPolicy()
        policy.noteCursorPlaneUpdate()
        policy.noteAbsolutePointerEvent()

        for _ in 0..<200 { policy.notePresentedFrame() }

        // The plane is composited by the view, so the macOS cursor must yield
        // immediately instead of waiting for a software-cursor repaint.
        XCTAssertTrue(policy.hidesSystemCursor)
        XCTAssertEqual(policy.cursorPlaneUpdates, 1)
    }

    func testGuestThatRepaintsWithoutTheCursorPlaneYieldsTheSystemCursor() {
        var policy = VMGuestCursorPresentationPolicy()
        policy.noteAbsolutePointerEvent()

        for _ in 0..<(VMGuestCursorPresentationPolicy.repaintFrameThreshold - 1) {
            policy.notePresentedFrame()
        }
        XCTAssertFalse(policy.hidesSystemCursor, "repaints are only proof once they respond to pointer input")

        policy.notePresentedFrame()
        XCTAssertTrue(policy.hidesSystemCursor)
    }

    func testFramesBeforeAnyPointerEventAreNotEvidenceOfASoftwareCursor() {
        var policy = VMGuestCursorPresentationPolicy()

        for _ in 0..<500 { policy.notePresentedFrame() }

        XCTAssertFalse(policy.hidesSystemCursor)
    }

    func testPointerMotionRestartsTheRepaintWindow() {
        var policy = VMGuestCursorPresentationPolicy()
        policy.noteAbsolutePointerEvent()
        for _ in 0..<(VMGuestCursorPresentationPolicy.repaintFrameThreshold - 1) {
            policy.notePresentedFrame()
        }

        policy.noteAbsolutePointerEvent()
        for _ in 0..<(VMGuestCursorPresentationPolicy.repaintFrameThreshold - 1) {
            policy.notePresentedFrame()
        }

        XCTAssertFalse(policy.hidesSystemCursor)
        policy.notePresentedFrame()
        XCTAssertTrue(policy.hidesSystemCursor)
    }

    func testACursorPlaneUpdateKeepsTheSystemCursorHidden() {
        var policy = VMGuestCursorPresentationPolicy()
        policy.noteAbsolutePointerEvent()
        for _ in 0..<VMGuestCursorPresentationPolicy.repaintFrameThreshold {
            policy.notePresentedFrame()
        }
        XCTAssertTrue(policy.hidesSystemCursor)

        policy.noteCursorPlaneUpdate()

        XCTAssertTrue(policy.hidesSystemCursor)
        for _ in 0..<500 { policy.notePresentedFrame() }
        XCTAssertTrue(policy.hidesSystemCursor, "a guest that draws a cursor keeps the macOS cursor blanked")
    }

    func testResetReturnsToAnUnknownCursorSource() {
        var policy = VMGuestCursorPresentationPolicy()
        policy.noteAbsolutePointerEvent()
        for _ in 0..<VMGuestCursorPresentationPolicy.repaintFrameThreshold {
            policy.notePresentedFrame()
        }
        XCTAssertTrue(policy.hidesSystemCursor)

        policy.reset()

        XCTAssertFalse(policy.hidesSystemCursor)
    }
}
