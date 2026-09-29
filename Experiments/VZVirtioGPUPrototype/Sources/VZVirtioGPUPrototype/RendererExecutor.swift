import Foundation

private final class RendererResultBox<Value>: @unchecked Sendable {
    var value: Value?
}

/// How long the renderer thread sleeps between fence polls while it has no
/// queued work. A guest waits on its fence before it draws the next frame, so
/// the poll starts at 1 ms and only backs off, to at most 4 ms, once that many
/// polls in a row retired nothing. New work, a new fence, and a retired fence
/// each return it to 1 ms.
struct RendererPollBackoff: Equatable {
    static let minimumInterval: TimeInterval = 0.001
    static let maximumInterval: TimeInterval = 0.004
    /// Idle polls spent at one interval before it doubles.
    static let pollsPerStep = 8

    private(set) var idlePolls = 0

    mutating func reset() {
        idlePolls = 0
    }

    /// The wait before the next poll. Counts that poll as idle until `reset`.
    mutating func nextInterval() -> TimeInterval {
        let step = idlePolls / Self.pollsPerStep
        if idlePolls < 2 * Self.pollsPerStep { idlePolls += 1 }
        switch step {
        case 0: return Self.minimumInterval
        case 1: return 2 * Self.minimumInterval
        default: return Self.maximumInterval
        }
    }
}

final class RendererExecutor: @unchecked Sendable {
    private let condition = NSCondition()
    private let ready = DispatchSemaphore(value: 0)
    private var jobs: [(() -> Void)?] = []
    private var jobHead = 0
    private var jobsAreEmpty: Bool { jobHead == jobs.count }
    private var stopping = false
    private var hasStopped = false
    private var pollOperation: (() -> Void)?
    private var pollingEnabled = false
    private var pollBackoff = RendererPollBackoff()
    private var thread: Thread!

    init() {
        thread = Thread { [unowned self] in run() }
        thread.name = "com.riftvm.app.prototype.virgl-renderer"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    deinit { stop() }

    func sync<Value>(_ operation: @escaping () -> Value) -> Value {
        if Thread.current === thread { return operation() }
        let completion = DispatchSemaphore(value: 0)
        let result = RendererResultBox<Value>()
        condition.lock()
        precondition(!stopping, "RendererExecutor cannot accept work after stop")
        jobs.append {
            result.value = operation()
            completion.signal()
        }
        condition.signal()
        condition.unlock()
        completion.wait()
        return result.value!
    }

    func async(_ operation: @escaping () -> Void) {
        condition.lock()
        guard !stopping else {
            condition.unlock()
            return
        }
        jobs.append(operation)
        condition.signal()
        condition.unlock()
    }

    func configurePolling(_ operation: @escaping () -> Void) {
        condition.lock()
        pollOperation = operation
        condition.unlock()
    }

    func setPollingEnabled(_ enabled: Bool) {
        condition.lock()
        guard pollingEnabled != enabled else {
            condition.unlock()
            return
        }
        pollingEnabled = enabled
        if enabled { pollBackoff.reset() }
        condition.signal()
        condition.unlock()
    }

    /// The poll operation retired something, so more may follow shortly.
    func pollDidMakeProgress() {
        condition.lock()
        pollBackoff.reset()
        condition.unlock()
    }

    func stop() {
        condition.lock()
        stopping = true
        condition.signal()
        if Thread.current === thread {
            condition.unlock()
            return
        }
        while !hasStopped {
            condition.wait()
        }
        condition.unlock()
    }

    private func run() {
        ready.signal()
        while true {
            condition.lock()
            while jobsAreEmpty && !stopping {
                if pollingEnabled {
                    _ = condition.wait(until: Date(timeIntervalSinceNow: pollBackoff.nextInterval()))
                    break
                }
                condition.wait()
            }
            if stopping && jobsAreEmpty {
                hasStopped = true
                condition.broadcast()
                condition.unlock()
                return
            }
            let job: (() -> Void)?
            if jobsAreEmpty {
                job = nil
            } else {
                // New work: a fence it creates or retires is worth a prompt poll.
                pollBackoff.reset()
                job = jobs[jobHead]
                jobs[jobHead] = nil // Release captures before the next compaction.
                jobHead += 1
                if jobsAreEmpty {
                    jobs.removeAll(keepingCapacity: true)
                    jobHead = 0
                } else if jobHead >= 1024 && jobHead >= jobs.count / 2 {
                    jobs.removeFirst(jobHead)
                    jobHead = 0
                }
            }
            let poll = pollingEnabled ? pollOperation : nil
            condition.unlock()
            job?()
            poll?()
        }
    }
}
