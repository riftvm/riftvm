import XCTest
@testable import RiftVM

/// The app-level quit path: quitting must drain the live machines instead of
/// letting process teardown kill the guests, and it must always reply.
@MainActor
final class VMLiveMachineCenterTests: XCTestCase {
    func testTerminateNowWhenNothingIsRunning() {
        let recorder = CenterRecorder()
        let center = makeCenter(recorder)

        XCTAssertEqual(center.requestTermination(), .terminateNow)
        XCTAssertTrue(recorder.replies.isEmpty)
        XCTAssertTrue(recorder.shown.isEmpty)
    }

    func testMacGuestSavesStateBeforeQuitting() {
        let recorder = CenterRecorder()
        let center = makeCenter(recorder)
        let spy = LiveMachineSpy(name: "macOS 27")
        spy.machine.canSaveAndStop = true
        spy.machine.canStop = true
        center.register(spy.machine)

        XCTAssertEqual(center.requestTermination(), .terminateLater)
        XCTAssertEqual(spy.saveAndStopCount, 1)
        XCTAssertEqual(spy.stopCount, 0)
        XCTAssertEqual(recorder.shown, ["Saving macOS 27…"])
        XCTAssertTrue(recorder.replies.isEmpty)

        center.unregister(spy.machine)
        XCTAssertEqual(recorder.replies, [true])
    }

    func testLinuxGuestStopsBecauseItCannotSaveState() {
        let recorder = CenterRecorder()
        let center = makeCenter(recorder)
        let spy = LiveMachineSpy(name: "Omarchy")
        spy.machine.canStop = true
        center.register(spy.machine)

        XCTAssertEqual(center.requestTermination(), .terminateLater)
        XCTAssertEqual(spy.saveAndStopCount, 0)
        XCTAssertEqual(spy.stopCount, 1)
        XCTAssertEqual(recorder.shown, ["Stopping Omarchy…"])

        center.unregister(spy.machine)
        XCTAssertEqual(recorder.replies, [true])
    }

    func testTimeoutForceStopsAndAlwaysReplies() {
        let recorder = CenterRecorder()
        let center = makeCenter(recorder)
        let spy = LiveMachineSpy(name: "Omarchy")
        spy.machine.canStop = true
        center.register(spy.machine)
        XCTAssertEqual(center.requestTermination(), .terminateLater)

        recorder.timeout?.perform()
        XCTAssertEqual(spy.forceStopCount, 1)
        XCTAssertEqual(recorder.replies, [true])
    }

    func testProgressTracksTheRemainingMachines() {
        let recorder = CenterRecorder()
        let center = makeCenter(recorder)
        let first = LiveMachineSpy(name: "Omarchy")
        first.machine.canStop = true
        let second = LiveMachineSpy(name: "macOS 27")
        second.machine.canStop = true
        center.register(first.machine)
        center.register(second.machine)

        XCTAssertEqual(center.requestTermination(), .terminateLater)
        XCTAssertEqual(recorder.shown, ["Stopping 2 workspaces…"])

        center.unregister(first.machine)
        XCTAssertEqual(recorder.updated, ["Stopping macOS 27…"])
        XCTAssertTrue(recorder.replies.isEmpty)

        center.unregister(second.machine)
        XCTAssertEqual(recorder.replies, [true])
    }

    func testSecondQuitRequestDoesNotReplyTwice() {
        let recorder = CenterRecorder()
        let center = makeCenter(recorder)
        let spy = LiveMachineSpy(name: "Omarchy")
        spy.machine.canStop = true
        center.register(spy.machine)

        XCTAssertEqual(center.requestTermination(), .terminateLater)
        XCTAssertEqual(center.requestTermination(), .terminateLater)
        XCTAssertEqual(spy.stopCount, 1)

        center.unregister(spy.machine)
        XCTAssertEqual(recorder.replies, [true])
    }

    func testRegisteringTheSameWorkspaceReplacesItsEntry() {
        let recorder = CenterRecorder()
        let center = makeCenter(recorder)
        let root = URL(filePath: "/tmp/riftvm-live-machine.riftvm")
        let first = VMLiveMachine(rootPath: root, name: "Omarchy")
        let second = VMLiveMachine(rootPath: root, name: "Renamed Omarchy")
        center.register(first)
        center.register(second)

        XCTAssertEqual(center.machines.count, 1)
        XCTAssertEqual(center.machines.first?.name, "Renamed Omarchy")
        XCTAssertTrue(center.machines.first === second)
    }

    // MARK: - Helpers
    private func makeCenter(_ recorder: CenterRecorder) -> VMLiveMachineCenter {
        VMLiveMachineCenter(
            reply: { recorder.replies.append($0) },
            showProgress: { recorder.shown.append($0) },
            updateProgress: { recorder.updated.append($0) },
            hideProgress: {},
            scheduleTimeout: { recorder.timeout = $0 }
        )
    }
}

/// Closing an Omarchy window while its guest runs must ask first, and a stop in
/// flight must keep the window open until the guest is down.
@MainActor
final class OmarchyWindowClosePolicyTests: XCTestCase {
    func testRunningAndPausedGuestsAskBeforeClosing() {
        XCTAssertTrue(OmarchyVirtualMachineView.Phase.running.needsCloseConfirmation(isTerminating: false))
        XCTAssertTrue(OmarchyVirtualMachineView.Phase.paused.needsCloseConfirmation(isTerminating: false))
        XCTAssertFalse(OmarchyVirtualMachineView.Phase.starting.needsCloseConfirmation(isTerminating: false))
        XCTAssertFalse(OmarchyVirtualMachineView.Phase.stopping.needsCloseConfirmation(isTerminating: false))
        XCTAssertFalse(OmarchyVirtualMachineView.Phase.stopped.needsCloseConfirmation(isTerminating: false))
    }

    func testQuittingNeverPromptsForAWindowClose() {
        XCTAssertFalse(OmarchyVirtualMachineView.Phase.running.needsCloseConfirmation(isTerminating: true))
    }

    func testStopInFlightKeepsTheWindowOpen() {
        XCTAssertTrue(OmarchyVirtualMachineView.Phase.stopping.blocksWindowClose)
        XCTAssertTrue(OmarchyVirtualMachineView.Phase.pausing.blocksWindowClose)
        XCTAssertFalse(OmarchyVirtualMachineView.Phase.running.blocksWindowClose)
        XCTAssertFalse(OmarchyVirtualMachineView.Phase.stopped.blocksWindowClose)
    }

    func testStopAndFailureBothRetireTheMachine() {
        XCTAssertTrue(OmarchyVirtualMachineView.Phase.stopped.hasStopped)
        XCTAssertTrue(OmarchyVirtualMachineView.Phase.failed("boom").hasStopped)
        XCTAssertFalse(OmarchyVirtualMachineView.Phase.stopping.hasStopped)
        XCTAssertFalse(OmarchyVirtualMachineView.Phase.running.hasStopped)
    }
}

/// Collects what the quit path reported and keeps the scheduled fallback so a
/// test can fire it without waiting for the real timeout.
@MainActor
private final class CenterRecorder {
    var replies: [Bool] = []
    var shown: [String] = []
    var updated: [String] = []
    var timeout: DispatchWorkItem?
}

/// A live machine whose control actions only count calls, so a test can drive
/// the center without a guest.
@MainActor
private final class LiveMachineSpy {
    let machine: VMLiveMachine
    private(set) var stopCount = 0
    private(set) var saveAndStopCount = 0
    private(set) var forceStopCount = 0

    init(name: String) {
        machine = VMLiveMachine(
            rootPath: URL(filePath: "/tmp/riftvm-live-\(UUID().uuidString).riftvm"),
            name: name
        )
        machine.stopAction = { [weak self] in self?.stopCount += 1 }
        machine.saveAndStopAction = { [weak self] in self?.saveAndStopCount += 1 }
        machine.forceStopAction = { [weak self] in self?.forceStopCount += 1 }
    }
}
