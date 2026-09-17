import XCTest
@testable import RiftVMCore

final class VMDisplayCursorPolicyTests: XCTestCase {
    func testGuestThatDrivesTheCursorPlaneKeepsTheSystemCursor() {
        var policy = VMGuestCursorPresentationPolicy()
        policy.noteCursorPlaneUpdate()
        policy.noteAbsolutePointerEvent()

        for _ in 0..<200 { policy.notePresentedFrame() }

        XCTAssertFalse(policy.hidesSystemCursor)
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

    func testACursorPlaneUpdateHandsThePointerBack() {
        var policy = VMGuestCursorPresentationPolicy()
        policy.noteAbsolutePointerEvent()
        for _ in 0..<VMGuestCursorPresentationPolicy.repaintFrameThreshold {
            policy.notePresentedFrame()
        }
        XCTAssertTrue(policy.hidesSystemCursor)

        policy.noteCursorPlaneUpdate()

        XCTAssertFalse(policy.hidesSystemCursor)
        for _ in 0..<500 { policy.notePresentedFrame() }
        XCTAssertFalse(policy.hidesSystemCursor, "a guest known to drive the plane must not hide the system cursor again")
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
