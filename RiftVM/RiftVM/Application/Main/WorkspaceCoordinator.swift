import AppKit
import SwiftUI
import Observation
import Virtualization

@MainActor @Observable
final class WorkspaceCoordinator: NSObject, NSWindowDelegate {
    static let shared = WorkspaceCoordinator()
    private var windows: [UUID: NSWindow] = [:]
    private var runtimeStates: [URL: VMRuntimeState] = [:]
    private var omarchyMachines: [URL: VZVirtualMachine] = [:]
    private var omarchyStates: [URL: VZVirtualMachine.State] = [:]
    @ObservationIgnored private var omarchyStateObservers: [URL: NSKeyValueObservation] = [:]
    private var omarchyShutdownRequests: [URL: () -> Void] = [:]
    private var omarchySaveRequests: [URL: () -> Void] = [:]
    private var omarchyCanSave: [URL: () -> Bool] = [:]
    private var omarchySavePending: [URL: () -> Bool] = [:]
    private var omarchyForceStopRequests: [URL: () -> Void] = [:]
    private var omarchyLeases: [URL: VMRunLease] = [:]
    @ObservationIgnored private lazy var quitController = WorkspaceQuitController(
        participants: { [weak self] in self?.quitParticipants() ?? [] },
        confirmShutdown: {
            let alert = NSAlert()
            alert.messageText = "Quit RiftVM?"
            alert.informativeText = "Workspaces that support saved state will resume next time. Other running workspaces must shut down before RiftVM can quit."
            alert.addButton(withTitle: "Shut Down and Quit")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        },
        chooseTimeout: {
            let alert = NSAlert()
            alert.messageText = "Workspaces are still stopping"
            alert.informativeText = "You can wait, cancel quitting, or force stop the remaining workspaces. Force stopping may lose unsaved guest work."
            alert.addButton(withTitle: "Wait")
            alert.addButton(withTitle: "Cancel Quit")
            alert.addButton(withTitle: "Force Stop")
            switch alert.runModal() {
            case .alertSecondButtonReturn: return .cancel
            case .alertThirdButtonReturn: return .forceStop
            default: return .wait
            }
        }
    )
    var isQuitting: Bool { quitController.isPending }
    private(set) var errorMessage: String?

    func phase(of workspace: WorkspaceRecord) -> String {
        let url = WorkspaceRegistry.canonical(workspace.location)
        if let state = omarchyStates[url] {
            switch state {
            case .running: return "Running"
            case .paused: return "Paused"
            case .stopped: return "Stopped"
            case .error: return "Needs attention"
            default: return "Starting or stopping"
            }
        }
        if let state = runtimeStates[url] { return String(describing: state.phase).capitalized }
        if VMRunningRegistry.shared.isRunning(rootPath: url) { return "Running" }
        if !FileManager.default.fileExists(atPath: url.path) { return "Offline" }
        if workspace.profile == .omarchy,
           VMOmarchyWorkspaceManager(layout: .init(applicationSupportRoot: url)).inspect() == .notPrepared { return "Ready to install" }
        return "Stopped"
    }

    func open(_ url: URL, recoveryMode: Bool = false) {
        guard !isQuitting else { return }
        let canonical = WorkspaceRegistry.canonical(url)
        if let record = sharedAppConfigManager.workspaces.first(where: { WorkspaceRegistry.canonical($0.location) == canonical }) {
            open(record, recoveryMode: recoveryMode)
        } else {
            sharedAppConfigManager.addVMPath(url: canonical)
            if let record = sharedAppConfigManager.workspaces.first(where: { WorkspaceRegistry.canonical($0.location) == canonical }) {
                open(record, recoveryMode: recoveryMode)
            }
        }
    }

    func open(_ record: WorkspaceRecord, recoveryMode: Bool = false) {
        guard !isQuitting else { return }
        if let window = windows[record.id] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        do {
            let identity = try WorkspaceIdentity.load(at: record.location)
            guard identity.id == record.id, identity.profile == record.profile else { throw WorkspaceRegistryError.profileMismatch }
            guard !VMRunningRegistry.shared.isRunning(rootPath: record.location) else {
                throw VMOSError.regularFailure("This workspace is already owned by another RiftVM process.")
            }
            let content: AnyView
            if record.profile == .omarchy {
                content = AnyView(OmarchyRootView(profile: .production, workspaceManager: .init(layout: .init(applicationSupportRoot: record.location))))
            } else {
                content = AnyView(VMOSMainVirtualMachineView(rootPath: record.location, recoveryMode: recoveryMode))
            }
            let controller = NSHostingController(rootView: content)
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.title = record.name
            window.representedURL = record.location
            window.setContentSize(NSSize(width: 1100, height: 760))
            window.minSize = NSSize(width: 820, height: 600)
            window.setFrameAutosaveName("workspace-\(record.id)")
            window.isReleasedWhenClosed = false
            window.delegate = self
            windows[record.id] = window
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            if record.profile == .omarchy {
                DispatchQueue.main.async { [weak window] in
                    guard let window, !window.styleMask.contains(.fullScreen) else { return }
                    window.toggleFullScreen(nil)
                }
            }
            errorMessage = nil
        } catch {
            errorMessage = "\(record.name): \(error.localizedDescription)"
            let alert = NSAlert()
            alert.messageText = "Could not open workspace"
            alert.informativeText = errorMessage ?? error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Keep the view/controller and guest alive. Closing is a visibility action.
        sender.orderOut(nil)
        return false
    }

    func runtimeDidStop(at url: URL) {
        let key = WorkspaceRegistry.canonical(url)
        runtimeStates.removeValue(forKey: key)
        if let record = sharedAppConfigManager.workspaces.first(where: { WorkspaceRegistry.canonical($0.location) == key }),
           let window = windows.removeValue(forKey: record.id) {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
    }

    func registerRuntime(_ state: VMRuntimeState, at url: URL) {
        runtimeStates[WorkspaceRegistry.canonical(url)] = state
    }

    func reserveOmarchy(at url: URL) throws -> VMRunLease {
        let key = WorkspaceRegistry.canonical(url)
        guard let lease = VMRunningRegistry.shared.acquire(rootPath: key) else {
            throw VMOSError.regularFailure("This workspace is already running in another process.")
        }
        omarchyLeases[key] = lease
        return lease
    }

    func releaseOmarchyReservation(at url: URL, expectedLease: VMRunLease? = nil) {
        let key = WorkspaceRegistry.canonical(url)
        if let expectedLease, omarchyLeases[key]?.id != expectedLease.id { return }
        omarchyMachines.removeValue(forKey: key)
        omarchyStates.removeValue(forKey: key)
        omarchyStateObservers.removeValue(forKey: key)
        omarchyShutdownRequests.removeValue(forKey: key)
        omarchySaveRequests.removeValue(forKey: key)
        omarchyCanSave.removeValue(forKey: key)
        omarchySavePending.removeValue(forKey: key)
        omarchyForceStopRequests.removeValue(forKey: key)
        if let lease = omarchyLeases.removeValue(forKey: key) { VMRunningRegistry.shared.release(lease) }
    }

    func registerOmarchy(
        _ machine: VZVirtualMachine,
        configuration: VZVirtualMachineConfiguration,
        at url: URL,
        requestShutdown: @escaping () -> Void,
        canSave: @escaping () -> Bool,
        requestSave: @escaping () -> Void,
        savePending: @escaping () -> Bool,
        requestForceStop: @escaping () -> Void
    ) throws {
        let key = WorkspaceRegistry.canonical(url)
        guard let lease = omarchyLeases[key] else {
            throw VMOSError.regularFailure("This workspace is already running in another process.")
        }
        guard let assessment = VMRunningRegistry.shared.configureResources(lease, cpuCount: configuration.cpuCount, memoryBytes: configuration.memorySize), assessment.allowed else {
            releaseOmarchyReservation(at: key)
            throw VMOSError.regularFailure("There are not enough host resources. Stop another workspace or reduce its allocation.")
        }
        omarchyLeases[key] = lease
        omarchyMachines[key] = machine
        omarchyStates[key] = machine.state
        // VZVirtualMachine is KVO observable, not Swift Observation observable.
        // Bridge state changes so library cards and the menu bar stay current.
        omarchyStateObservers[key] = machine.observe(\.state, options: [.new]) { [weak self, weak machine] _, _ in
            Task { @MainActor in
                guard let self, let machine, self.omarchyMachines[key] === machine else { return }
                self.omarchyStates[key] = machine.state
            }
        }
        omarchyShutdownRequests[key] = requestShutdown
        omarchySaveRequests[key] = requestSave
        omarchyCanSave[key] = canSave
        omarchySavePending[key] = savePending
        omarchyForceStopRequests[key] = requestForceStop
    }

    func omarchyDidStop(_ machine: VZVirtualMachine) {
        guard let key = omarchyMachines.first(where: { $0.value === machine })?.key else { return }
        omarchyMachines.removeValue(forKey: key)
        omarchyStates.removeValue(forKey: key)
        omarchyStateObservers.removeValue(forKey: key)
        omarchyShutdownRequests.removeValue(forKey: key)
        omarchySaveRequests.removeValue(forKey: key)
        omarchyCanSave.removeValue(forKey: key)
        omarchySavePending.removeValue(forKey: key)
        omarchyForceStopRequests.removeValue(forKey: key)
        if let lease = omarchyLeases.removeValue(forKey: key) { VMRunningRegistry.shared.release(lease) }
    }

    func hasLiveOmarchy(at url: URL) -> Bool {
        guard let machine = omarchyMachines[WorkspaceRegistry.canonical(url)] else { return false }
        return machine.state != .stopped && machine.state != .error
    }

    func reopenCommandLineWindow(at url: URL) {
        guard let window = windows.values.first(where: { $0.representedURL == url }) else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func retainCommandLineWindow(_ window: NSWindow, at url: URL) {
        guard let identity = try? WorkspaceIdentity.load(at: url) else { return }
        window.isReleasedWhenClosed = false
        window.representedURL = url
        window.delegate = self
        windows[identity.id] = window
    }

    func requestOmarchyStop(at url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let machine = omarchyMachines[WorkspaceRegistry.canonical(url)] else {
            completion(.failure(VMOSError.regularFailure("The workspace is not running.")))
            return
        }
        if let shutdown = omarchyShutdownRequests[WorkspaceRegistry.canonical(url)] {
            shutdown()
            completion(.success(()))
            return
        }
        let request = {
            do { try machine.requestStop(); completion(.success(())) }
            catch { completion(.failure(error)) }
        }
        if machine.state == .paused {
            machine.resume { result in
                Task { @MainActor in
                    switch result {
                    case .success: request()
                    case .failure(let error): completion(.failure(error))
                    }
                }
            }
        } else { request() }
    }

    func requestTermination() -> NSApplication.TerminateReply { quitController.requestTermination() }

    private func quitParticipants() -> [WorkspaceQuitController.Participant] {
        let standard = runtimeStates.map { url, state in
            WorkspaceQuitController.Participant(
                id: url.path,
                isStopped: {
                    switch state.phase { case .stopped, .failed: true; default: false }
                },
                canSave: { state.canSave },
                save: { state.saveAndStop() },
                shutDown: { state.requestStop() },
                forceStop: { state.forceStop() }
            )
        }
        let omarchy = omarchyMachines.map { url, machine in
            WorkspaceQuitController.Participant(
                id: url.path,
                isStopped: { [weak self] in
                    (machine.state == .stopped || machine.state == .error) && self?.omarchySavePending[url]?() != true
                },
                canSave: { [weak self] in self?.omarchyCanSave[url]?() == true },
                save: { [weak self] in self?.omarchySaveRequests[url]?() },
                shutDown: { [weak self] in
                    if let shutdown = self?.omarchyShutdownRequests[url] {
                        shutdown()
                    } else if machine.canResume {
                        machine.resume { result in
                            if case .success = result, machine.canRequestStop { try? machine.requestStop() }
                        }
                    } else if machine.canRequestStop { try? machine.requestStop() }
                },
                forceStop: { [weak self] in self?.omarchyForceStopRequests[url]?() }
            )
        }
        return standard + omarchy
    }
}
