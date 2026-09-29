import AppKit
import SwiftUI
import Virtualization

extension OmarchyVirtualMachineRepresentable {
    @MainActor
    final class Coordinator: NSObject, @preconcurrency VZVirtualMachineDelegate {
        var runLease: VMRunLease?
        var machine: VZVirtualMachine?
        var graphicsBackend: (any VMGraphicsBackend)?
        let sessionID: UUID
        let layout: VMOmarchyWorkspaceLayout
        let requiredGuestCapabilities: [String]
        var clipboardEnabled: Bool
        var notificationsEnabled: Bool
        let keyboardIntegrationChanged: (OmarchyKeyboardIntegrationState) -> Void
        let integrationChanged: (VMOmarchyIntegrationState) -> Void
        let sharedFolderProbeChanged: (VMOmarchySharedFolderProbeState) -> Void
        let clipboardProbeChanged: (OmarchyClipboardProbeState) -> Void
        let dynamicDisplayProbeChanged: (OmarchyDynamicDisplayProbeState) -> Void
        let ownerProvisioningCompleted: (UUID, String?) -> Void
        let ownerProvisioningProgressChanged: (VMOmarchyOwnerProvisioningProgress) -> Void
        private let reportPhase: (OmarchyVirtualMachineView.Phase) -> Void
        let acceptanceFailureChanged: (String) -> Void
        let graphicsIssueChanged: (String?) -> Void
        let sharePlanChanged: (VMOmarchySharePlan) -> Void
        private(set) var sharePlan: VMOmarchySharePlan?

        func phaseChanged(_ phase: OmarchyVirtualMachineView.Phase) {
            if let lease = runLease {
                switch phase {
                case .starting: VMRunningRegistry.shared.transition(lease, to: .starting)
                case .running, .resuming: VMRunningRegistry.shared.transition(lease, to: .running)
                case .paused, .pausing: VMRunningRegistry.shared.transition(lease, to: .paused)
                case .stopping: VMRunningRegistry.shared.transition(lease, to: .stopping)
                case .stopped, .failed:
                    // An operation error can leave the VM running. Keep its lease
                    // until VZ confirms stop, including asynchronous view teardown.
                    if machine == nil || machine?.state == .stopped || machine?.state == .error {
                        VMRunningRegistry.shared.release(lease)
                        runLease = nil
                    }
                }
            }
            reportPhase(phase)
        }

        func start(
            _ machine: VZVirtualMachine,
            in view: VZVirtualMachineView,
            profile: VMOmarchyProfile,
            microphoneEnabled: Bool,
            permitsEFIVariableStoreRecovery: Bool
        ) {
            machine.start { [weak self, weak view] result in
                DispatchQueue.main.async {
                    guard let self, let view else { return }
                    switch result {
                    case .success:
                        self.startIntegration(layout: self.layout)
                        self.startBootUnlockAcceptanceIfNeeded()
                        self.phaseChanged(.running)
                    case .failure(let error):
                        guard permitsEFIVariableStoreRecovery,
                              VMEFIVariableStoreRecovery.isInvalidBootLoaderError(error.localizedDescription) else {
                            self.phaseChanged(.failed(error.localizedDescription))
                            return
                        }
                        do {
                            let backup = try VMEFIVariableStoreRecovery.replaceRejectedStore(
                                at: self.layout.efiVariableStore
                            )
                            RiftVMLog.info(
                                "Rejected Omarchy EFI variable store was replaced; backup: \(backup?.path ?? "none")"
                            )
                            OmarchyApplicationTerminationController.shared.unregister(machine)
                            let configuration = try VMOmarchyVirtualMachineBuilder.makeConfiguration(
                                layout: self.layout,
                                profile: profile,
                                customGraphicsDevices: (self.graphicsBackend as? VMCustomVirGLGraphicsBackend)?.deviceConfigurations ?? [],
                                microphoneEnabled: microphoneEnabled,
                                sharePlan: self.currentSharePlan()
                            )
                            let replacement = VZVirtualMachine(configuration: configuration)
                            replacement.delegate = self
                            self.machine = replacement
                            self.graphicsBackend?.bind(virtualMachine: replacement)
                            OmarchyApplicationTerminationController.shared.register(replacement)
                            self.start(
                                replacement,
                                in: view,
                                profile: profile,
                                microphoneEnabled: microphoneEnabled,
                                permitsEFIVariableStoreRecovery: false
                            )
                        } catch {
                            self.phaseChanged(.failed(error.localizedDescription))
                        }
                    }
                }
            }
        }
        var stopObserver: NSObjectProtocol?
        var pauseObserver: NSObjectProtocol?
        var resumeObserver: NSObjectProtocol?
        var keyboardPermissionObserver: NSObjectProtocol?
        var forceStopObserver: NSObjectProtocol?
        var keyboardBridge: OmarchyFocusedCommandBridge?
        var integrationClient: VMOmarchyGuestAgentClient?
        var agentClipboardController: OmarchyAgentClipboardController?
        var notificationController: OmarchyNotificationController?
        var latestGuestStatus: VMOmarchyGuestStatus?
        weak var machineView: VZVirtualMachineView?
        // State of the automatic acceptance probes. Production has no probe
        // implementation, so it carries none of their state either.
        #if RIFTVM_ACCEPTANCE_HARNESS
        var notificationAcceptanceProbeTask: Task<Void, Never>?
        var notificationAcceptanceProbeStarted = false
        var notificationAcceptanceProbeCompleted = false
        var expectedAcceptanceNotificationTitle: String?
        var clipboardProbeOwnsTransport = false
        var sharedFolderProbeTask: Task<Void, Never>?
        var sharedFolderProbePassed = false
        var desktopCommandStarted = false
        var clipboardProbeTask: Task<Void, Never>?
        var clipboardProbePassed = false
        var dynamicDisplayProbeTask: Task<Void, Never>?
        var inputLatencyProbeTask: Task<Void, Never>?
        var inputLatencyProbeStarted = false
        var continuousInputProbeTask: Task<Void, Never>?
        var continuousInputProbeStarted = false
        var lockProbeTask: Task<Void, Never>?
        var bootUnlockAcceptanceStarted = false
        var dynamicDisplayProbePassed = false
        #else
        /// No probe exists to take the clipboard transport.
        var clipboardProbeOwnsTransport: Bool { false }
        #endif
        var acceptanceFailureRecorded = false
        var acceptanceEnabled: Bool {
            !acceptanceFailureRecorded && OmarchyWorkspaceConfiguration.isAcceptanceWorkspace(layout)
        }

        func reportAcceptanceFailure(_ message: String) {
            guard !acceptanceFailureRecorded else { return }
            acceptanceFailureRecorded = true
            #if RIFTVM_ACCEPTANCE_HARNESS
            automaticRecoveryStage = .idle
            lockProbeTask?.cancel()
            inputLatencyProbeTask?.cancel()
            continuousInputProbeTask?.cancel()
            notificationAcceptanceProbeTask?.cancel()
            sharedFolderProbeTask?.cancel()
            clipboardProbeTask?.cancel()
            dynamicDisplayProbeTask?.cancel()
            guestRestartUnlockTimeoutTask?.cancel()
            hostWakeInteractiveTask?.cancel()
            #endif
            NSLog("Omarchy acceptance failed (VM lifecycle unchanged): %@", message)
            let report: [String: Any] = [
                "schemaVersion": 1, "result": "failed", "message": message,
                "observedAt": ISO8601DateFormatter().string(from: Date()),
            ]
            do {
                try FileManager.default.createDirectory(at: layout.diagnostics, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: layout.diagnostics.appending(path: "acceptance-failure.json"), options: .atomic)
            } catch {
                NSLog("Could not save acceptance failure: %@", error.localizedDescription)
            }
            acceptanceFailureChanged(message)
        }

        #if RIFTVM_ACCEPTANCE_HARNESS
        var automaticLockProbe = OmarchyLockAcceptanceState()
        var automaticPauseResumeProbeStarted = false
        var automaticRecoveryAfterResume = false
        var automaticRecoveryStage = AutomaticRecoveryStage.idle
        var recoveryBaselineStatus: VMOmarchyGuestStatus?
        var guestRestartAcceptanceState = OmarchyGuestRestartAcceptanceState()
        var guestRestartUnlockTimeoutTask: Task<Void, Never>?
        var hostWakeInteractiveTask: Task<Void, Never>?
        var automaticCommandSpaceProbeStarted = false
        var automaticFullScreenProbeStarted = false
        var fullScreenProbe: OmarchyFullScreenAcceptanceProbe?
        #endif
        var lastOwnerProvisioningSubmissionID: UUID?
        var ownerProgressFetchInFlight = false

        #if RIFTVM_ACCEPTANCE_HARNESS
        enum AutomaticRecoveryStage {
            case idle
            case waitingForPostResumeReady
            case waitingForAgentDisconnect
            case waitingForAgentReady
            case waitingForGuestDisconnect
            case waitingForGuestReady
            case complete
        }
        #endif

        init(
            sessionID: UUID,
            layout: VMOmarchyWorkspaceLayout,
            requiredGuestCapabilities: [String],
            clipboardEnabled: Bool,
            notificationsEnabled: Bool,
            keyboardIntegrationChanged: @escaping (OmarchyKeyboardIntegrationState) -> Void,
            integrationChanged: @escaping (VMOmarchyIntegrationState) -> Void,
            sharedFolderProbeChanged: @escaping (VMOmarchySharedFolderProbeState) -> Void,
            clipboardProbeChanged: @escaping (OmarchyClipboardProbeState) -> Void,
            dynamicDisplayProbeChanged: @escaping (OmarchyDynamicDisplayProbeState) -> Void,
            ownerProvisioningCompleted: @escaping (UUID, String?) -> Void,
            ownerProvisioningProgressChanged: @escaping (VMOmarchyOwnerProvisioningProgress) -> Void,
            phaseChanged: @escaping (OmarchyVirtualMachineView.Phase) -> Void,
            acceptanceFailureChanged: @escaping (String) -> Void = { _ in },
            graphicsIssueChanged: @escaping (String?) -> Void = { _ in },
            sharePlanChanged: @escaping (VMOmarchySharePlan) -> Void = { _ in }
        ) {
            self.sessionID = sessionID
            self.layout = layout
            self.requiredGuestCapabilities = requiredGuestCapabilities
            self.clipboardEnabled = clipboardEnabled
            self.notificationsEnabled = notificationsEnabled
            self.keyboardIntegrationChanged = keyboardIntegrationChanged
            self.integrationChanged = integrationChanged
            self.sharedFolderProbeChanged = sharedFolderProbeChanged
            self.clipboardProbeChanged = clipboardProbeChanged
            self.dynamicDisplayProbeChanged = dynamicDisplayProbeChanged
            self.ownerProvisioningCompleted = ownerProvisioningCompleted
            self.ownerProvisioningProgressChanged = ownerProvisioningProgressChanged
            self.reportPhase = phaseChanged
            self.acceptanceFailureChanged = acceptanceFailureChanged
            self.graphicsIssueChanged = graphicsIssueChanged
            self.sharePlanChanged = sharePlanChanged
        }

        /// The folders this session shares. Edits made while Omarchy runs are
        /// saved and picked up by the next start.
        @discardableResult
        func adoptSharedFolders(_ settings: VMOmarchySharedFolderSettings) -> VMOmarchySharePlan {
            let plan = VMOmarchySharePlan(settings: settings, transfer: layout.transfer)
            sharePlan = plan
            DispatchQueue.main.async { [sharePlanChanged] in sharePlanChanged(plan) }
            return plan
        }

        /// The plan this session runs with, made now when the VM is being
        /// rebuilt before one exists.
        func currentSharePlan() -> VMOmarchySharePlan {
            sharePlan ?? adoptSharedFolders(VMOmarchySharedFolderStore.load(layout: layout))
        }

        func submitOwnerProvisioning(_ submission: OmarchyOwnerProvisioningSubmission) {
            guard lastOwnerProvisioningSubmissionID != submission.id else { return }
            lastOwnerProvisioningSubmissionID = submission.id
            guard let integrationClient else {
                ownerProvisioningCompleted(submission.id, "The Guest Agent is not ready for owner setup.")
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await integrationClient.provisionOwner(submission.request)
                    ownerProvisioningCompleted(submission.id, nil)
                } catch {
                    ownerProvisioningCompleted(submission.id, error.localizedDescription)
                }
            }
        }

        func refreshOwnerProvisioningProgressIfNeeded(_ status: VMOmarchyGuestStatus) {
            guard status.provisioningPending, !ownerProgressFetchInFlight,
                  let integrationClient else { return }
            ownerProgressFetchInFlight = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { ownerProgressFetchInFlight = false }
                if let progress = try? await integrationClient.ownerProvisioningProgress() {
                    ownerProvisioningProgressChanged(progress)
                }
            }
        }

        deinit {
            if let stopObserver { NotificationCenter.default.removeObserver(stopObserver) }
            if let pauseObserver { NotificationCenter.default.removeObserver(pauseObserver) }
            if let resumeObserver { NotificationCenter.default.removeObserver(resumeObserver) }
            if let keyboardPermissionObserver { NotificationCenter.default.removeObserver(keyboardPermissionObserver) }
            if let forceStopObserver { NotificationCenter.default.removeObserver(forceStopObserver) }
            #if RIFTVM_ACCEPTANCE_HARNESS
            hostWakeInteractiveTask?.cancel()
            #endif
        }

        func beginObservingCommands() {
            stopObserver = NotificationCenter.default.addObserver(
                forName: .omarchyRequestStop,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, notification.object as? UUID == self.sessionID else { return }
                    self.requestStop()
                }
            }
            pauseObserver = NotificationCenter.default.addObserver(
                forName: .omarchyRequestPause,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, notification.object as? UUID == self.sessionID else { return }
                    self.pause(automaticResume: false)
                }
            }
            resumeObserver = NotificationCenter.default.addObserver(
                forName: .omarchyRequestResume,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, notification.object as? UUID == self.sessionID else { return }
                    self.resume()
                }
            }
            keyboardPermissionObserver = NotificationCenter.default.addObserver(
                forName: .omarchyRequestKeyboardPermission,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, notification.object as? UUID == self.sessionID else { return }
                    if let keyboardBridge = self.keyboardBridge {
                        keyboardBridge.requestPermission()
                    } else {
                        OmarchyFocusedCommandBridge.requestAccessibilityAccess()
                    }
                }
            }
            forceStopObserver = NotificationCenter.default.addObserver(
                forName: .omarchyForceStop,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, notification.object as? UUID == self.sessionID else { return }
                    self.forceStop()
                }
            }
        }

        func installKeyboardBridge(for view: VZVirtualMachineView) {
            let bridge = OmarchyFocusedCommandBridge(
                focusProbe: { [weak view] in
                    guard let view, let window = view.window else { return false }
                    guard !view.isHidden else { return false }
                    guard window.isKeyWindow, NSApp.keyWindow === window, NSApp.modalWindow == nil,
                          window.attachedSheet == nil else { return false }
                    guard let responder = window.firstResponder as? NSView else { return false }
                    // In-process state first: the frontmost-application query
                    // below is only worth making once everything else holds.
                    guard NSApp.isActive,
                          responder === view || responder.isDescendant(of: view) else { return false }
                    // AppKit can retain a key window while another application
                    // is frontmost. A session-wide event tap must not capture it.
                    return OmarchyCommandCapturePolicy.hasKeyboardFocus(
                        applicationActive: NSApp.isActive,
                        applicationFrontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                        windowKey: window.isKeyWindow,
                        responderInsideGuest: responder === view || responder.isDescendant(of: view)
                    )
                },
                stateChanged: keyboardIntegrationChanged,
                redirectedCommandChord: { [weak self] keyCode, flags in
                    // Only consume the physical Command chord when the
                    // authenticated Agent can actually deliver it. Keeping a
                    // disconnected client object must not turn every Command
                    // shortcut into a dropped key.
                    guard Thread.isMainThread else { return false }
                    return MainActor.assumeIsolated {
                        guard let client = self?.integrationClient,
                              client.currentCapabilities.contains("input-uinput-v1") else {
                            return false
                        }
                        return client.enqueueMacCommandChord(
                            keyCode: UInt16(keyCode),
                            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))
                        )
                    }
                },
                commandSpaceCaptured: { [weak self, weak view] in
                    guard let self else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        OmarchyAcceptanceObservationReporter.reportCommandSuperIfEnabled(
                            layout: self.layout,
                            applicationActive: NSApp.isActive,
                            virtualMachineWindowKey: view?.window?.isKeyWindow == true
                        )
                    }
                }
            )
            keyboardBridge = bridge
            (view as? OmarchyVirtualMachineInputView)?.commandEventHandler = { [weak bridge] event in
                guard let bridge else { return false }
                return bridge.handleLocalEvent(event) == nil
            }
            bridge.start()
        }

        func startIntegration(layout: VMOmarchyWorkspaceLayout) {
            guard let socket = machine?.socketDevices.first as? VZVirtioSocketDevice else {
                integrationChanged(.disconnected("The VM has no Virtio Socket device."))
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let client = try VMOmarchyGuestAgentClient(
                        device: socket,
                        layout: layout,
                        hostPowerChanged: { [weak self] event in
                            guard let self else { return }
                            Task { @MainActor [weak self] in
                                self?.handleHostPowerEvent(event)
                            }
                        },
                        stateChanged: { [weak self] state in
                            guard let self else { return }
                            self.integrationChanged(state)
                            switch state {
                            case .ready(let status):
                                Task { @MainActor [weak self] in
                                    guard let self else { return }
                                    // Record every authenticated status transition here. SwiftUI
                                    // can coalesce a short-lived locked status before the parent
                                    // view's onChange handler runs, which would make real lifecycle
                                    // evidence omit a lock that the recovery state machine observed.
                                    OmarchyAcceptanceObservationReporter.reportLifecycleIfEnabled(
                                        status: status,
                                        layout: self.layout
                                    )
                                    self.latestGuestStatus = status
                                    self.configureDesktopInput(for: status)
                                    self.startInputLatencyProbeIfNeeded(status)
                                    self.startContinuousInputProbeIfNeeded(status)
                                    self.configureAgentClipboard(for: status)
                                    self.configureNotifications(for: status)
                                    self.handleAutomaticRecoveryReady(status)
                                    self.refreshOwnerProvisioningProgressIfNeeded(status)
                                }
                            case .disconnected:
                                Task { @MainActor [weak self] in
                                    (self?.machineView as? OmarchyVirtualMachineInputView)?
                                        .setGuestInputEventHandler(nil)
                                    self?.latestGuestStatus = nil
                                    self?.stopAgentClipboard()
                                    self?.stopNotifications()
                                    self?.handleAutomaticRecoveryDisconnect()
                                }
                            case .connecting, .authenticating:
                                break
                            }
                            if case .ready(let status) = state,
                               VMOmarchyIntegrationAssessment.evaluate(
                                status: status,
                                requiredCapabilities: self.requiredGuestCapabilities
                               ).isReady {
                                self.startSharedFolderProbeIfNeeded(layout: layout)
                                self.startDesktopCommandIfNeeded(status)
                            }
                        }
                    )
                    self.integrationClient = client
                    client.start()
                } catch {
                    self.integrationChanged(.disconnected(error.localizedDescription))
                }
            }
        }

        @MainActor
        func configureDesktopInput(for status: VMOmarchyGuestStatus) {
            guard let view = machineView as? OmarchyVirtualMachineInputView else { return }
            graphicsBackend?.setDynamicDisplayReady(status.desktopSessionActive && !status.provisioningPending)
            graphicsBackend?.setAbsolutePointerEnabled(status.capabilities.contains("input-uinput-absolute-v1"))
            guard OmarchyDesktopInputPolicy.usesGuestAgent(status: status),
                  let integrationClient else {
                view.setGuestInputEventHandler(nil)
                return
            }
            view.setGuestInputEventHandler { [weak integrationClient] events in
                integrationClient?.sendInputEvents(events)
            }
        }

        @MainActor
        func configureAgentClipboard(for status: VMOmarchyGuestStatus) {
            latestGuestStatus = status
            guard OmarchyClipboardActivationPolicy.shouldRun(
                enabled: clipboardEnabled,
                capabilities: Set(status.capabilities),
                desktopSessionActive: status.desktopSessionActive,
                provisioningPending: status.provisioningPending,
                probeOwnsTransport: clipboardProbeOwnsTransport
            ),
                  let integrationClient else {
                stopAgentClipboard()
                return
            }
            guard agentClipboardController == nil else { return }
            let controller = OmarchyAgentClipboardController(
                client: integrationClient,
                sharedDirectory: sharePlan?.clipboardStaging ?? layout.transfer,
                guestRelativePrefix: VMOmarchySharePlan.clipboardRelativePrefix
            )
            agentClipboardController = controller
            controller.start()
        }

        @MainActor
        func setClipboardEnabled(_ enabled: Bool) {
            guard clipboardEnabled != enabled else { return }
            clipboardEnabled = enabled
            guard let latestGuestStatus else {
                stopAgentClipboard()
                return
            }
            configureAgentClipboard(for: latestGuestStatus)
        }

        @MainActor
        func stopAgentClipboard() {
            agentClipboardController?.stop()
            agentClipboardController = nil
        }

        @MainActor
        func configureNotifications(for status: VMOmarchyGuestStatus) {
            guard OmarchyNotificationActivationPolicy.shouldRun(
                enabled: notificationsEnabled,
                capabilities: status.capabilities,
                desktopSessionActive: status.desktopSessionActive,
                provisioningPending: status.provisioningPending
            ), let integrationClient else {
                stopNotifications()
                return
            }
            guard notificationController == nil else { return }
            #if RIFTVM_ACCEPTANCE_HARNESS
            let controller = OmarchyNotificationController(
                client: integrationClient,
                bootID: status.bootID,
                deliverySucceeded: { [weak self] notification in
                    guard let self,
                          notification.title == self.expectedAcceptanceNotificationTitle else { return }
                    self.expectedAcceptanceNotificationTitle = nil
                    self.notificationAcceptanceProbeCompleted = true
                    OmarchyAcceptanceObservationReporter.reportDesktopNotificationIfEnabled(
                        notification,
                        guestBootID: status.bootID,
                        layout: self.layout
                    )
                    NSLog("Omarchy Guest notification was accepted by macOS Notification Center")
                }
            )
            #else
            // Only a probe expects a particular notification.
            let controller = OmarchyNotificationController(
                client: integrationClient,
                bootID: status.bootID
            )
            #endif
            notificationController = controller
            controller.start()
            startNotificationAcceptanceProbeIfNeeded(client: integrationClient)
        }

        @MainActor
        func setNotificationsEnabled(_ enabled: Bool) {
            guard notificationsEnabled != enabled else { return }
            notificationsEnabled = enabled
            guard let latestGuestStatus else {
                stopNotifications()
                return
            }
            configureNotifications(for: latestGuestStatus)
        }

        @MainActor
        func stopNotifications() {
            notificationController?.stop()
            notificationController = nil
            #if RIFTVM_ACCEPTANCE_HARNESS
            notificationAcceptanceProbeTask?.cancel()
            notificationAcceptanceProbeTask = nil
            expectedAcceptanceNotificationTitle = nil
            if !notificationAcceptanceProbeCompleted {
                notificationAcceptanceProbeStarted = false
            }
            #endif
        }

        @MainActor
        func handleHostPowerEvent(_ event: VMOmarchyHostPowerEvent) {
            OmarchyAcceptanceObservationReporter.reportHostPowerEventIfEnabled(
                event == .willSleep ? .willSleep : .didWake,
                layout: layout
            )
            guard event == .didWake,
                  acceptanceEnabled else { return }
            startHostWakeInteractiveProbe()
        }

        @MainActor
        func handleAutomaticRecoveryDisconnect() {
            #if RIFTVM_ACCEPTANCE_HARNESS
            switch automaticRecoveryStage {
            case .waitingForAgentDisconnect:
                OmarchyAcceptanceObservationReporter.reportRecoveryEventIfEnabled(
                    .disconnectedAfterAgentRestart,
                    layout: layout
                )
                automaticRecoveryStage = .waitingForAgentReady
            case .waitingForGuestDisconnect:
                OmarchyAcceptanceObservationReporter.reportRecoveryEventIfEnabled(
                    .disconnectedAfterGuestRestart,
                    layout: layout
                )
                automaticRecoveryStage = .waitingForGuestReady
            case .idle, .waitingForPostResumeReady, .waitingForAgentReady,
                 .waitingForGuestReady, .complete:
                break
            }
            #endif
        }

        func requestStop() {
            guard let machine, machine.state != .stopped else {
                stopIntegration()
                graphicsBackend?.shutdown()
                graphicsBackend = nil
                self.machine = nil
                phaseChanged(.stopped)
                return
            }
            guard machine.canRequestStop else {
                forceStop()
                return
            }
            do {
                try machine.requestStop()
            } catch {
                forceStop()
            }
        }

        func pause(automaticResume: Bool) {
            guard let machine, machine.canPause else {
                phaseChanged(.failed("Omarchy cannot be paused right now."))
                return
            }
            OmarchyAcceptanceObservationReporter.reportVirtualMachineEventIfEnabled(
                .pauseRequested,
                layout: layout
            )
            machine.pause { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success:
                        OmarchyAcceptanceObservationReporter.reportVirtualMachineEventIfEnabled(
                            .paused,
                            layout: self.layout
                        )
                        self.keyboardBridge?.stop()
                        self.stopAgentClipboard()
                        self.stopNotifications()
                        self.integrationClient?.virtualMachineDidPause()
                        self.phaseChanged(.paused)
                        if automaticResume {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                                self?.resume()
                            }
                        }
                    case .failure(let error):
                        #if RIFTVM_ACCEPTANCE_HARNESS
                        self.automaticPauseResumeProbeStarted = false
                        #endif
                        self.phaseChanged(.failed(error.localizedDescription))
                    }
                }
            }
        }

        func resume() {
            guard let machine, machine.canResume else {
                phaseChanged(.failed("Omarchy cannot be resumed right now."))
                return
            }
            machine.resume { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success:
                        OmarchyAcceptanceObservationReporter.reportVirtualMachineEventIfEnabled(
                            .resumed,
                            layout: self.layout
                        )
                        #if RIFTVM_ACCEPTANCE_HARNESS
                        if self.automaticRecoveryAfterResume {
                            self.automaticRecoveryAfterResume = false
                            self.automaticRecoveryStage = .waitingForPostResumeReady
                        }
                        #endif
                        self.integrationClient?.virtualMachineDidResume()
                        self.keyboardBridge?.start()
                        self.phaseChanged(.running)
                    case .failure(let error):
                        #if RIFTVM_ACCEPTANCE_HARNESS
                        self.automaticPauseResumeProbeStarted = false
                        #endif
                        self.phaseChanged(.failed(error.localizedDescription))
                    }
                }
            }
        }

        func forceStop() {
            guard let machine, machine.state != .stopped else {
                stopIntegration()
                graphicsBackend?.shutdown()
                graphicsBackend = nil
                self.machine = nil
                phaseChanged(.stopped)
                return
            }
            guard machine.canStop else {
                phaseChanged(.failed("Omarchy could not be stopped after the graceful shutdown timed out."))
                return
            }
            machine.stop { [weak self, weak machine] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let error {
                        self.phaseChanged(.failed(error.localizedDescription))
                    } else if self.machine === machine {
                        self.stopIntegration()
                        self.graphicsBackend?.shutdown()
                        self.graphicsBackend = nil
                        self.machine = nil
                        self.phaseChanged(.stopped)
                    }
                }
            }
        }

        func stopImmediately() {
            #if RIFTVM_ACCEPTANCE_HARNESS
            inputLatencyProbeTask?.cancel()
            inputLatencyProbeTask = nil
            sharedFolderProbeTask?.cancel()
            sharedFolderProbeTask = nil
            clipboardProbeTask?.cancel()
            clipboardProbeTask = nil
            dynamicDisplayProbeTask?.cancel()
            dynamicDisplayProbeTask = nil
            #endif
            keyboardBridge?.stop()
            keyboardBridge = nil
            stopIntegration()
            guard let machine else {
                if let lease = runLease { VMRunningRegistry.shared.release(lease); runLease = nil }
                graphicsBackend?.shutdown()
                graphicsBackend = nil
                return
            }
            let lease = runLease
            runLease = nil
            let backend = graphicsBackend
            graphicsBackend = nil
            // The renderer owns guest resources: retain it until VZ has actually
            // stopped, even if SwiftUI has already dismantled the display view.
            Task { @MainActor in
                // Bounded force-stop phase. A healthy machine leaves it within a
                // few iterations; the deadline exists so a wedged Virtualization
                // state machine cannot keep this loop polling forever.
                let deadline = ContinuousClock.now.advanced(by: Self.teardownForceStopDeadline)
                while machine.state != .stopped && machine.state != .error && ContinuousClock.now < deadline {
                    if machine.canStop {
                        let error: Error? = await withCheckedContinuation { continuation in
                            machine.stop { continuation.resume(returning: $0) }
                        }
                        if let error {
                            RiftVMLog.error("Omarchy teardown stop failed; retaining GPU until stopped: \(error.localizedDescription)")
                        }
                    }
                    if machine.state != .stopped && machine.state != .error {
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
                if machine.state != .stopped && machine.state != .error {
                    // Do not release anything early: the disk is still attached,
                    // so freeing the run lease here would let a second process
                    // open the same disk. Wait for the state change instead of
                    // polling, and finish the moment VZ reports a terminal state.
                    RiftVMLog.error("Omarchy teardown did not reach a terminal state within \(Int(Self.teardownForceStopDeadline.components.seconds))s (state \(machine.state.rawValue)); GPU and run lease stay retained until Virtualization stops")
                    await VMTerminalStateWaiter().wait(for: machine)
                    RiftVMLog.info("Omarchy teardown completed after the deadline (state \(machine.state.rawValue)); releasing GPU and run lease")
                }
                backend?.shutdown()
                if let lease { VMRunningRegistry.shared.release(lease) }
                OmarchyApplicationTerminationController.shared.unregister(machine)
            }
            self.machine = nil
        }

        /// How long teardown actively retries a force stop before it stops
        /// polling and waits for Virtualization's state change instead.
        static let teardownForceStopDeadline: Duration = .seconds(60)

        func guestDidStop(_ virtualMachine: VZVirtualMachine) {
            Task { @MainActor in
                OmarchyApplicationTerminationController.shared.machineDidStop(virtualMachine)
            }
            guard machine === virtualMachine else { return }
            stopIntegration()
            graphicsBackend?.shutdown()
            graphicsBackend = nil
            machine = nil
            phaseChanged(.stopped)
        }

        func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
            Task { @MainActor in
                OmarchyApplicationTerminationController.shared.machineDidStop(virtualMachine)
            }
            guard machine === virtualMachine else { return }
            stopIntegration()
            graphicsBackend?.shutdown()
            graphicsBackend = nil
            machine = nil
            phaseChanged(.failed(error.localizedDescription))
        }

        func stopIntegration() {
            #if RIFTVM_ACCEPTANCE_HARNESS
            lockProbeTask?.cancel()
            lockProbeTask = nil
            continuousInputProbeTask?.cancel()
            continuousInputProbeTask = nil
            inputLatencyProbeTask?.cancel()
            inputLatencyProbeTask = nil
            #endif
            (machineView as? OmarchyVirtualMachineInputView)?.setGuestInputEventHandler(nil)
            let clipboardController = agentClipboardController
            agentClipboardController = nil
            Task { @MainActor in clipboardController?.stop() }
            let notifications = notificationController
            notificationController = nil
            Task { @MainActor in notifications?.stop() }
            #if RIFTVM_ACCEPTANCE_HARNESS
            sharedFolderProbeTask?.cancel()
            sharedFolderProbeTask = nil
            sharedFolderProbePassed = false
            clipboardProbeTask?.cancel()
            clipboardProbeTask = nil
            clipboardProbePassed = false
            dynamicDisplayProbeTask?.cancel()
            dynamicDisplayProbeTask = nil
            dynamicDisplayProbePassed = false
            #endif
            let client = integrationClient
            integrationClient = nil
            Task { @MainActor in client?.stop() }
        }
    }
}

extension Notification.Name {
    static let omarchyRequestStop = Notification.Name("RiftVMOmarchy.requestStop")
    static let omarchyRequestPause = Notification.Name("RiftVMOmarchy.requestPause")
    static let omarchyRequestResume = Notification.Name("RiftVMOmarchy.requestResume")
    static let omarchyRequestKeyboardPermission = Notification.Name("RiftVMOmarchy.requestKeyboardPermission")
    static let omarchyForceStop = Notification.Name("RiftVMOmarchy.forceStop")
}
