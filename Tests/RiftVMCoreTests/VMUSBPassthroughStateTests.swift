import XCTest
@testable import RiftVMCore

final class VMUSBPassthroughStateTests: XCTestCase {
    func testOnlyAssignedDevicesCanAttachAndDuplicateAttachIsBlocked() throws {
        var state = VMUSBPassthroughState()
        XCTAssertNil(state.beginAttachment(1))
        state.start()
        XCTAssertNil(state.beginAttachment(1))
        state.assign(1)
        let attach = try XCTUnwrap(state.beginAttachment(1))
        XCTAssertNil(state.beginAttachment(1))
        XCTAssertTrue(state.finishAttachment(attach))
    }

    func testReleaseAndRapidReassignRejectOldAttachmentUntilItIsDetached() throws {
        var state = VMUSBPassthroughState()
        state.start(); state.assign(1)
        let old = try XCTUnwrap(state.beginAttachment(1))
        state.release(1); state.assign(1)
        XCTAssertNil(state.beginAttachment(1))
        XCTAssertFalse(state.finishAttachment(old))
        let detach = state.beginDetachment(1)
        XCTAssertNil(state.beginAttachment(1))
        XCTAssertTrue(state.finishDetachment(1, token: detach))
        let replacement = try XCTUnwrap(state.beginAttachment(1))
        XCTAssertTrue(state.finishAttachment(replacement))
    }

    func testStopRejectsInFlightAttachmentAndListenerCallback() throws {
        var state = VMUSBPassthroughState()
        let session = state.start(); state.assign(1)
        let old = try XCTUnwrap(state.beginAttachment(1))
        state.stop()
        XCTAssertFalse(state.isCurrentSession(session))
        XCTAssertFalse(state.finishAttachment(old))
        XCTAssertNil(state.beginAttachment(1))
    }

    func testOldVMCompletionCannotClearNewVMAttachmentWithSameRegistryID() throws {
        var state = VMUSBPassthroughState()
        let oldSession = state.start(); state.assign(1)
        let old = try XCTUnwrap(state.beginAttachment(1))
        state.stop()
        let newSession = state.start(); state.assign(1)
        let current = try XCTUnwrap(state.beginAttachment(1))
        XCTAssertFalse(state.finishAttachment(old))
        XCTAssertNil(state.beginAttachment(1))
        XCTAssertTrue(state.finishAttachment(current))
        XCTAssertFalse(state.isCurrentSession(oldSession))
        XCTAssertTrue(state.isCurrentSession(newSession))
    }

    func testOldDetachCannotUnblockAReplacementDetach() throws {
        var state = VMUSBPassthroughState()
        state.start(); state.assign(1)
        let old = state.beginDetachment(1)
        state.stop(); state.start(); state.assign(1)
        let current = state.beginDetachment(1)
        XCTAssertFalse(state.finishDetachment(1, token: old))
        XCTAssertNil(state.beginAttachment(1))
        XCTAssertTrue(state.finishDetachment(1, token: current))
        XCTAssertNotNil(state.beginAttachment(1))
    }

    func testReleaseWhileDetachingNeverReattachesToHostRevokedDevice() throws {
        var state = VMUSBPassthroughState()
        state.start(); state.assign(1)
        let detach = state.beginDetachment(1)
        state.release(1)
        XCTAssertTrue(state.finishDetachment(1, token: detach))
        XCTAssertNil(state.beginAttachment(1))
    }
}
