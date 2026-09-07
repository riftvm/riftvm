import AppKit
import Observation

/// One quit transaction covers every live workspace. Time passing is never
/// authorization to force stop a guest.
@MainActor @Observable
final class WorkspaceQuitController {
    enum TimeoutChoice { case wait, cancel, forceStop }
    struct Participant {
        let id: String
        let isStopped: () -> Bool
        let canSave: () -> Bool
        let save: () -> Void
        let shutDown: () -> Void
        let forceStop: () -> Void
    }

    private(set) var isPending = false
    private var remaining: [Participant] = []
    private var pollCount = 0
    private var generation = 0
    private let participants: () -> [Participant]
    private let confirmShutdown: () -> Bool
    private let chooseTimeout: () -> TimeoutChoice
    private let reply: (Bool) -> Void
    private let schedulePoll: (@escaping @MainActor () -> Void) -> Void

    init(
        participants: @escaping () -> [Participant],
        confirmShutdown: @escaping () -> Bool,
        chooseTimeout: @escaping () -> TimeoutChoice,
        reply: @escaping (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) },
        schedulePoll: @escaping (@escaping @MainActor () -> Void) -> Void = { action in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: action)
        }
    ) {
        self.participants = participants
        self.confirmShutdown = confirmShutdown
        self.chooseTimeout = chooseTimeout
        self.reply = reply
        self.schedulePoll = schedulePoll
    }

    func requestTermination() -> NSApplication.TerminateReply {
        guard !isPending else { return .terminateLater }
        let active = participants().filter { !$0.isStopped() }
        guard !active.isEmpty else { return .terminateNow }
        guard !active.contains(where: { !$0.canSave() }) || confirmShutdown() else { return .terminateCancel }
        remaining = active
        isPending = true
        generation += 1
        pollCount = 0
        for participant in active {
            if participant.canSave() { participant.save() }
            else { participant.shutDown() }
        }
        scheduleNextPoll()
        return .terminateLater
    }

    func poll() {
        guard isPending else { return }
        remaining.removeAll { $0.isStopped() }
        guard !remaining.isEmpty else { finish(true); return }
        pollCount += 1
        if pollCount >= 20 { handleTimeout() }
        if isPending { scheduleNextPoll() }
    }

    func handleTimeout() {
        guard isPending else { return }
        remaining.removeAll { $0.isStopped() }
        guard !remaining.isEmpty else { finish(true); return }
        pollCount = 0
        switch chooseTimeout() {
        case .wait: break
        case .cancel: finish(false)
        case .forceStop:
            for participant in remaining where !participant.isStopped() { participant.forceStop() }
            // Await the actual stop, including a potentially failed force-stop.
        }
    }

    private func scheduleNextPoll() {
        let expectedGeneration = generation
        schedulePoll { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            self.poll()
        }
    }

    private func finish(_ allowed: Bool) {
        isPending = false
        generation += 1
        remaining = []
        reply(allowed)
    }
}
