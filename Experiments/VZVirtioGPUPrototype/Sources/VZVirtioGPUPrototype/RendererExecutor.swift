import Foundation

private final class RendererResultBox<Value>: @unchecked Sendable {
    var value: Value?
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
        condition.signal()
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
                    _ = condition.wait(until: Date(timeIntervalSinceNow: 0.001))
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
