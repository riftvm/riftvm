import Virtualization

/// Waits for a virtual machine to reach a terminal state without polling.
/// Used by teardown after the bounded force-stop phase: the run lease and the
/// GPU renderer must outlive the machine, so the waiter observes the state key
/// and resumes exactly once when Virtualization reports stopped or error.
@MainActor
final class VMTerminalStateWaiter {
    private var observation: NSKeyValueObservation?
    private var continuation: CheckedContinuation<Void, Never>?

    func wait(for machine: VZVirtualMachine) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
            // .initial closes the gap between the caller's last state check
            // and the observation being installed.
            observation = machine.observe(\.state, options: [.initial, .new]) { [weak self] observed, _ in
                guard observed.state == .stopped || observed.state == .error else { return }
                Task { @MainActor in self?.finish() }
            }
        }
    }

    private func finish() {
        observation?.invalidate()
        observation = nil
        continuation?.resume()
        continuation = nil
    }
}
