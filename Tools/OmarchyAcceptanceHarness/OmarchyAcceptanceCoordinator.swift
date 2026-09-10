import AppKit
import Virtualization

#if RIFTVM_ACCEPTANCE_HARNESS
extension OmarchyVirtualMachineRepresentable.Coordinator {
    private var acceptanceScenario: String {
        ProcessInfo.processInfo.environment["RIFTVM_OMARCHY_ACCEPTANCE_SCENARIO"] ?? "lifecycle"
    }

    @MainActor
    func startBootUnlockAcceptanceIfNeeded() {
        let environment = ProcessInfo.processInfo.environment
        guard acceptanceEnabled, environment[OmarchyWorkspaceConfiguration.acceptanceBootUnlockKey] == "1",
              !bootUnlockAcceptanceStarted,
              let password = environment[
                OmarchyWorkspaceConfiguration.acceptanceUnlockPasswordKey
              ], !password.isEmpty else { return }
        bootUnlockAcceptanceStarted = true
        Task { @MainActor [weak self] in
            // The encrypted-volume prompt appears before the authenticated
            // desktop Agent. Waiting here keeps this acceptance-only seam
            // out of firmware startup while still avoiding UI automation's
            // synthetic text path.
            // VZ reports the VM as running before the encrypted-volume
            // prompt is ready to consume keyboard reports. Sending during
            // that gap silently drops the leading keys, so leave enough
            // time for the prompt rather than treating VM start as input
            // readiness.
            try? await Task.sleep(for: .seconds(20))
            guard let self,
                  self.latestGuestStatus?.desktopSessionActive != true,
                  let inputView = self.machineView as? OmarchyVirtualMachineInputView else {
                return
            }
            guard inputView.runAppleUSBTextAcceptance(password + "\n") else {
                self.reportAcceptanceFailure("Boot unlock acceptance could not deliver Apple USB input.")
                return
            }
            NSLog("Omarchy boot unlock acceptance dispatched through Apple USB")
        }
    }

    @MainActor
    func startInputLatencyProbeIfNeeded(_ status: VMOmarchyGuestStatus) {
        if acceptanceScenario == "ime" { startIMEAcceptanceIfNeeded(status); return }
        let environment = ProcessInfo.processInfo.environment
        guard acceptanceEnabled, environment["RIFTVM_OMARCHY_INPUT_LATENCY_ACCEPTANCE"] == "1",
              !inputLatencyProbeStarted,
              status.desktopSessionActive,
              !status.provisioningPending,
              status.capabilities.contains("input-uinput-v1"),
              status.capabilities.contains("desktop-input-v1"),
              let client = integrationClient,
              let inputView = machineView as? OmarchyVirtualMachineInputView else { return }
        inputLatencyProbeStarted = true
        let requestedSamples = environment["RIFTVM_OMARCHY_INPUT_LATENCY_SAMPLES"]
            .flatMap(Int.init) ?? 20
        inputLatencyProbeTask = Task { @MainActor [weak self, weak client, weak inputView] in
            guard let self, let client, let inputView else { return }
            do {
                let report = try await OmarchyInputLatencyAcceptanceProbe.run(
                    client: client,
                    sharedDirectory: self.layout.shared,
                    diagnosticsDirectory: self.layout.diagnostics,
                    sampleCount: requestedSamples,
                    unlockPassword: environment[
                        OmarchyWorkspaceConfiguration.acceptanceUnlockPasswordKey
                    ],
                    sendAppleUSBText: { [weak self, weak inputView] text in
                        guard let self, let inputView else { return false }
                        inputView.setGuestInputEventHandler(nil)
                        defer {
                            if let status = self.latestGuestStatus {
                                self.configureDesktopInput(for: status)
                            }
                        }
                        guard inputView.runAppleUSBTextAcceptance(text) else { return false }
                        try? await Task.sleep(for: OmarchyHostKeyboardTextEncoder.eventQueueDuration(
                            for: text
                        ))
                        return true
                    }
                )
                NSLog(
                    "Omarchy input latency A/B complete recommended=%@ samples=%d report=%@",
                    report.recommendedBackend.rawValue, report.samples.count,
                    self.layout.diagnostics.appending(path: OmarchyInputLatencyAcceptanceProbe.reportFileName).path
                )
            } catch is CancellationError {
                return
            } catch {
                self.reportAcceptanceFailure("Input latency acceptance failed: \(error.localizedDescription)")
            }
            self.inputLatencyProbeTask = nil
        }
    }

    @MainActor
    func startContinuousInputProbeIfNeeded(_ status: VMOmarchyGuestStatus) {
        let environment = ProcessInfo.processInfo.environment
        guard acceptanceEnabled,
              environment["RIFTVM_OMARCHY_CONTINUOUS_INPUT_ACCEPTANCE"] == "1",
              !continuousInputProbeStarted,
              status.desktopSessionActive,
              !status.provisioningPending,
              status.capabilities.contains("input-uinput-v1"),
              status.capabilities.contains("desktop-input-v1"),
              let client = integrationClient,
              let inputView = machineView as? OmarchyVirtualMachineInputView else { return }
        continuousInputProbeStarted = true
        continuousInputProbeTask = Task { @MainActor [weak self, weak client, weak inputView] in
            guard let self, let client, let inputView else { return }
            do {
                // A running Wayland session can still be covered by
                // hyprlock. Wait for a command to reach a real terminal so
                // the burst cannot be mistaken for an unlock-screen test.
                try await OmarchyInputDiagnosticsAcceptanceProbe.verifyInteractiveDesktopEventually(
                    client: client,
                    sharedDirectory: self.layout.shared,
                    attempts: 120,
                    timeoutPerAttempt: .seconds(2),
                    retryDelay: .seconds(1)
                )
                try await OmarchyInputDiagnosticsAcceptanceProbe.runContinuousInputBurst(
                    client: client,
                    sharedDirectory: self.layout.shared,
                    diagnosticsDirectory: self.layout.diagnostics,
                    sendTextBurst: { inputView.runGuestAgentTextBurstAcceptance($0) },
                    sendKeyRepeat: {
                        inputView.runGuestAgentKeyRepeatAcceptance(keyCode: 0, count: $0)
                    }
                )
                NSLog("Omarchy continuous input burst acceptance passed")
            } catch is CancellationError {
                return
            } catch {
                self.reportAcceptanceFailure(
                    "Continuous input acceptance failed: \(error.localizedDescription)"
                )
            }
            self.continuousInputProbeTask = nil
        }
    }

    func startNotificationAcceptanceProbeIfNeeded(
        client: VMOmarchyGuestAgentClient
    ) {
        guard acceptanceEnabled, ["lifecycle", "displays", "stability"].contains(acceptanceScenario), !notificationAcceptanceProbeStarted,
              !notificationAcceptanceProbeCompleted else { return }
        notificationAcceptanceProbeStarted = true
        let title = "RiftVM notification \(UUID().uuidString.lowercased())"
        expectedAcceptanceNotificationTitle = title
        notificationAcceptanceProbeTask = Task { @MainActor [weak self, weak client] in
            guard let self, let client else { return }
            do {
                // Let the first poll establish its baseline before the
                // synthetic Guest notification is created.
                try await Task.sleep(for: .seconds(3))
                try await OmarchyInputDiagnosticsAcceptanceProbe.sendDesktopNotification(
                    client: client,
                    sharedDirectory: self.layout.shared,
                    title: title
                )
                let deadline = ContinuousClock.now + .seconds(30)
                while self.expectedAcceptanceNotificationTitle != nil,
                      ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(200))
                }
                if self.expectedAcceptanceNotificationTitle != nil {
                    NSLog("Omarchy notification acceptance timed out")
                    self.expectedAcceptanceNotificationTitle = nil
                    self.notificationAcceptanceProbeStarted = false
                }
            } catch is CancellationError {
                return
            } catch {
                NSLog("Omarchy notification acceptance failed: %@", error.localizedDescription)
                self.expectedAcceptanceNotificationTitle = nil
                self.notificationAcceptanceProbeStarted = false
            }
            self.notificationAcceptanceProbeTask = nil
        }
    }

    func startSharedFolderProbeIfNeeded(layout: VMOmarchyWorkspaceLayout) {
        guard acceptanceEnabled, ["lifecycle", "displays", "stability"].contains(acceptanceScenario), !sharedFolderProbePassed, sharedFolderProbeTask == nil,
              let integrationClient else { return }
        sharedFolderProbeChanged(.running)
        sharedFolderProbeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await integrationClient.verifySharedFolderRoundTrip(
                    layout: layout
                )
                self.sharedFolderProbePassed = true
                NSLog(
                    "Omarchy shared-folder round trip passed (host-to-guest %@, guest-to-host %@)",
                    result.hostToGuestSHA256,
                    result.guestToHostSHA256
                )
                self.sharedFolderProbeChanged(.passed(result))
                self.startClipboardProbeIfNeeded(layout: layout)
            } catch {
                NSLog("Omarchy shared-folder round trip failed: %@", error.localizedDescription)
                self.sharedFolderProbeChanged(.failed(error.localizedDescription))
            }
            self.sharedFolderProbeTask = nil
        }
    }

    func startClipboardProbeIfNeeded(layout: VMOmarchyWorkspaceLayout) {
        guard acceptanceEnabled, sharedFolderProbePassed, !clipboardProbePassed,
              clipboardProbeTask == nil, let integrationClient else { return }
        // Claim clipboard transport ownership before scheduling the probe.
        // A ready-status callback is delivered on a separate MainActor task;
        // without this synchronous gate it can create a new polling bridge
        // after the probe has already attempted to quiesce the old one.
        clipboardProbeOwnsTransport = true
        clipboardProbeChanged(.running)
        clipboardProbeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // The continuous clipboard bridge is another legitimate
            // writer. Pause it while acceptance performs ordered native
            // and Agent round trips, otherwise a concurrent host
            // pasteboard change can overwrite the selection under test.
            let clipboardController = self.agentClipboardController
            await clipboardController?.quiesce()
            if self.agentClipboardController === clipboardController {
                self.agentClipboardController = nil
            }
            defer {
                self.clipboardProbeOwnsTransport = false
                if let status = self.latestGuestStatus {
                    self.configureAgentClipboard(for: status)
                }
            }
            do {
                NSApp.activate(ignoringOtherApps: true)
                if let machineView = self.machineView,
                   let window = machineView.window {
                    window.makeKeyAndOrderFront(nil)
                    window.makeFirstResponder(machineView)
                }
                let result = try await OmarchyClipboardAcceptanceProbe.run(
                    client: integrationClient,
                    sharedDirectory: layout.shared,
                    unlockCredential: OmarchyAcceptanceUnlockCredential(
                        environment: ProcessInfo.processInfo.environment
                    )
                )
                self.clipboardProbePassed = true
                NSLog(
                    "Omarchy clipboard round trip passed (text %@/%@, PNG %@/%@)",
                    result.hostToGuestTextSHA256,
                    result.guestToHostTextSHA256,
                    result.hostToGuestImageSHA256,
                    result.guestToHostImageSHA256
                )
                self.clipboardProbeChanged(.passed(result))
                self.startDynamicDisplayProbeIfNeeded(layout: layout)
            } catch {
                NSLog("Omarchy clipboard round trip failed: %@", error.localizedDescription)
                self.clipboardProbeChanged(.failed(error.localizedDescription))
            }
            self.clipboardProbeTask = nil
        }
    }

    func startDynamicDisplayProbeIfNeeded(layout: VMOmarchyWorkspaceLayout) {
        guard acceptanceEnabled, clipboardProbePassed, !dynamicDisplayProbePassed,
              dynamicDisplayProbeTask == nil, let integrationClient,
              let machineView else { return }
        dynamicDisplayProbeChanged(.running)
        dynamicDisplayProbeTask = Task { @MainActor [weak self, weak machineView] in
            guard let self, let machineView else { return }
            do {
                let result = try await OmarchyDynamicDisplayAcceptanceProbe.run(
                    client: integrationClient,
                    view: machineView,
                    sharedDirectory: layout.shared
                )
                self.dynamicDisplayProbePassed = true
                NSLog(
                    "Omarchy dynamic display round trip passed (%dx%d -> %dx%d; host %dx%d)",
                    result.guestBefore.width, result.guestBefore.height,
                    result.guestAfter.width, result.guestAfter.height,
                    result.hostViewAfter.width, result.hostViewAfter.height
                )
                self.dynamicDisplayProbeChanged(.passed(result))
                if self.acceptanceScenario == "displays" {
                    try await OmarchyDynamicDisplayAcceptanceProbe.runAcrossDisplays(
                        client: integrationClient, view: machineView,
                        sharedDirectory: layout.shared, diagnosticsDirectory: layout.diagnostics
                    )
                } else {
                    self.startAutomaticCommandSpaceProbeIfNeeded(self.latestGuestStatus)
                }
            } catch {
                NSLog("Omarchy dynamic display round trip failed: %@", error.localizedDescription)
                self.dynamicDisplayProbeChanged(.failed(error.localizedDescription))
            }
            self.dynamicDisplayProbeTask = nil
        }
    }

    func startAutomaticPauseResumeProbeIfNeeded() {
        guard acceptanceEnabled, dynamicDisplayProbePassed, !automaticPauseResumeProbeStarted else { return }
        automaticPauseResumeProbeStarted = true
        automaticRecoveryAfterResume = true
        pause(automaticResume: true)
    }

    @MainActor
    func startAutomaticLockProbeIfNeeded() {
        let environment = ProcessInfo.processInfo.environment
        guard acceptanceEnabled else {
            return
        }
        guard OmarchyAcceptanceUnlockCredential(environment: environment) != nil else {
            reportAcceptanceFailure(
                "Acceptance requires a printable ASCII unlock password of 1–128 bytes."
            )
            return
        }
        guard automaticLockProbe.begin(), let integrationClient,
              let credential = OmarchyAcceptanceUnlockCredential(environment: environment) else {
            return
        }
        lockProbeTask = Task { @MainActor [weak self, weak integrationClient] in
            do {
                guard let self, let integrationClient else { return }
                NSApp.activate(ignoringOtherApps: true)
                if let view = self.machineView, let window = view.window {
                    window.makeKeyAndOrderFront(nil)
                    window.makeFirstResponder(view)
                }
                try await OmarchyInputDiagnosticsAcceptanceProbe.run(
                    client: integrationClient,
                    sharedDirectory: self.layout.shared,
                    diagnosticsDirectory: self.layout.diagnostics
                )
                NSApp.activate(ignoringOtherApps: true)
                if let machineView = self.machineView,
                   let window = machineView.window {
                    window.makeKeyAndOrderFront(nil)
                    window.makeFirstResponder(machineView)
                }
                let cycle = try await OmarchyInputDiagnosticsAcceptanceProbe.runObservedLockCycle(
                    client: integrationClient,
                    sharedDirectory: self.layout.shared,
                    sendLockShortcut: { [weak self] in
                        // macOS virtual key 37 is L. Command is redirected
                        // to Guest Super by the production Accessibility
                        // bridge; Control remains part of the same chord.
                        self?.keyboardBridge?.runAcceptanceCommandChordProbe(
                            keyCode: 37,
                            additionalFlags: .maskControl
                        ) == true
                    },
                    sendUnlockSecret: { [weak self] in
                        self?.keyboardBridge?.runAcceptanceTextInput(
                            credential.password + "\n"
                        ) == true
                    },
                    checkFocus: { [weak self] in
                        guard let self, self.acceptanceEnabled,
                              NSApp.isActive,
                              let view = self.machineView,
                              view.window?.isKeyWindow == true,
                              view.window?.firstResponder === view else {
                            throw OmarchyInputDiagnosticsAcceptanceProbe.ProbeError.focusLost
                        }
                    }
                )
                guard self.automaticLockProbe.completeObservedCycle() else { return }
                NSLog(
                    "Omarchy observed Guest lock/unlock cycle (%@ -> %@)",
                    cycle.lockedAt as NSDate,
                    cycle.unlockedAt as NSDate
                )
                OmarchyAcceptanceObservationReporter.reportLockCycleIfEnabled(
                    layout: self.layout,
                    lockedAt: cycle.lockedAt,
                    activeAt: cycle.unlockedAt
                )
                self.startAutomaticPauseResumeProbeIfNeeded()
            } catch is CancellationError {
                return
            } catch {
                self?.reportAcceptanceFailure("Guest lock probe failed: \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    func startHostWakeInteractiveProbe() {
        hostWakeInteractiveTask?.cancel()
        hostWakeInteractiveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var client: VMOmarchyGuestAgentClient?
                for _ in 0..<30 {
                    if let integrationClient = self.integrationClient,
                       self.latestGuestStatus != nil {
                        client = integrationClient
                        break
                    }
                    try await Task.sleep(for: .seconds(1))
                }
                guard let client else { throw CocoaError(.fileReadNoSuchFile) }
                do {
                    try await OmarchyInputDiagnosticsAcceptanceProbe.verifyInteractiveDesktopEventually(
                        client: client,
                        sharedDirectory: self.layout.shared,
                        attempts: 2,
                        timeoutPerAttempt: .seconds(6)
                    )
                } catch {
                    guard let credential = OmarchyAcceptanceUnlockCredential(
                        environment: ProcessInfo.processInfo.environment
                    ) else { throw error }
                    NSApp.activate(ignoringOtherApps: true)
                    if let machineView = self.machineView, let window = machineView.window {
                        window.makeKeyAndOrderFront(nil)
                        window.makeFirstResponder(machineView)
                    }
                    try await Task.sleep(for: .milliseconds(300))
                    guard self.keyboardBridge?.runAcceptanceTextInput(
                        credential.password + "\n"
                    ) == true else { throw CocoaError(.featureUnsupported) }
                    try await Task.sleep(for: OmarchyHostKeyboardTextEncoder.deliveryDuration(
                        for: credential.password + "\n"
                    ))
                    try await Task.sleep(for: .seconds(3))
                    try await OmarchyInputDiagnosticsAcceptanceProbe.verifyInteractiveDesktopEventually(
                        client: client,
                        sharedDirectory: self.layout.shared,
                        attempts: 3,
                        timeoutPerAttempt: .seconds(8)
                    )
                }
                guard let status = self.latestGuestStatus else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                OmarchyAcceptanceObservationReporter.reportInteractiveAfterHostWakeIfEnabled(
                    status: status,
                    layout: self.layout
                )
                NSLog("Omarchy interactive desktop recovered after host wake")
            } catch is CancellationError {
                return
            } catch {
                self.reportAcceptanceFailure(
                    "Host wake interactive probe failed: \(error.localizedDescription)"
                )
            }
            self.hostWakeInteractiveTask = nil
        }
    }

    @MainActor
    func handleAutomaticRecoveryReady(_ status: VMOmarchyGuestStatus) {
        guard acceptanceEnabled else { return }
        switch automaticRecoveryStage {
        case .waitingForPostResumeReady:
            guard status.capabilities.contains("agent-restart-v1"),
                  !status.bootID.isEmpty,
                  status.agentInstanceID?.isEmpty == false,
                  let integrationClient else { return }
            recoveryBaselineStatus = status
            automaticRecoveryStage = .waitingForAgentDisconnect
            OmarchyAcceptanceObservationReporter.reportRecoveryEventIfEnabled(
                .agentRestartRequested(status),
                layout: layout
            )
            Task { @MainActor [weak self, weak integrationClient] in
                do {
                    try await integrationClient?.requestAgentRestart()
                } catch {
                    guard let self else { return }
                    self.automaticRecoveryStage = .idle
                    self.reportAcceptanceFailure("Guest Agent restart probe failed: \(error.localizedDescription)")
                }
            }
        case .waitingForAgentReady:
            guard let baseline = recoveryBaselineStatus,
                  OmarchyAgentRestartRecoveryReadiness.isReady(
                    baseline: baseline,
                    recovered: status
                  ),
                  let integrationClient else { return }
            OmarchyAcceptanceObservationReporter.reportRecoveryEventIfEnabled(
                .guestRestartRequested(status),
                layout: layout
            )
            recoveryBaselineStatus = status
            guard guestRestartAcceptanceState.begin(previousBootID: status.bootID) else {
                automaticRecoveryStage = .idle
                reportAcceptanceFailure("Guest restart probe could not establish its boot baseline.")
                return
            }
            automaticRecoveryStage = .waitingForGuestDisconnect
            integrationClient.requestRestart()
        case .waitingForGuestReady:
            switch guestRestartAcceptanceState.observe(status) {
            case .none:
                break
            case .recoverInteractiveDesktop:
                recoverGuestRestartInteractiveDesktop()
            }
        case .idle, .waitingForAgentDisconnect, .waitingForGuestDisconnect, .complete:
            break
        }
        startAutomaticFullScreenProbeIfNeeded(status)
    }

    @MainActor
    func recoverGuestRestartInteractiveDesktop() {
        guard let credential = OmarchyAcceptanceUnlockCredential(
            environment: ProcessInfo.processInfo.environment
        ), let integrationClient, keyboardBridge != nil else {
            automaticRecoveryStage = .idle
            reportAcceptanceFailure("The Guest restart unlock credential became unavailable.")
            return
        }
        guestRestartUnlockTimeoutTask?.cancel()
        guestRestartUnlockTimeoutTask = Task { @MainActor [weak self, weak integrationClient] in
            do {
                guard let self, let integrationClient else { return }
                do {
                    // A reboot may return directly to an already unlocked
                    // desktop. Prove that path before typing a credential;
                    // otherwise the password would leak into an application.
                    try await OmarchyInputDiagnosticsAcceptanceProbe.verifyInteractiveDesktopEventually(
                        client: integrationClient,
                        sharedDirectory: self.layout.shared,
                        attempts: 2,
                        timeoutPerAttempt: .seconds(6)
                    )
                } catch {
                    NSApp.activate(ignoringOtherApps: true)
                    if let machineView = self.machineView, let window = machineView.window {
                        window.makeKeyAndOrderFront(nil)
                        window.makeFirstResponder(machineView)
                    }
                    try await Task.sleep(for: .milliseconds(300))
                    guard self.keyboardBridge?.runAcceptanceTextInput(
                        credential.password + "\n"
                    ) == true else {
                        throw CocoaError(.featureUnsupported)
                    }
                    try await Task.sleep(for: OmarchyHostKeyboardTextEncoder.deliveryDuration(
                        for: credential.password + "\n"
                    ))
                    try await Task.sleep(for: .seconds(3))
                    try await OmarchyInputDiagnosticsAcceptanceProbe.verifyInteractiveDesktopEventually(
                        client: integrationClient,
                        sharedDirectory: self.layout.shared,
                        attempts: 3,
                        timeoutPerAttempt: .seconds(8)
                    )
                }
                guard let status = self.latestGuestStatus,
                      self.guestRestartAcceptanceState.completeInteractiveProof(
                        bootID: status.bootID
                      ) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                OmarchyAcceptanceObservationReporter.reportRecoveryEventIfEnabled(
                    .guestInteractiveAfterRestart(status),
                    layout: self.layout
                )
                self.guestRestartUnlockTimeoutTask = nil
                self.automaticRecoveryStage = .complete
                self.recoveryBaselineStatus = nil
                self.startAutomaticFullScreenProbeIfNeeded(status)
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.automaticRecoveryStage = .idle
                self.reportAcceptanceFailure(
                    "Guest restart unlock probe failed: \(error.localizedDescription)"
                )
            }
        }
    }

    @MainActor
    private func startIMEAcceptanceIfNeeded(_ status: VMOmarchyGuestStatus) {
        guard acceptanceEnabled, !inputLatencyProbeStarted,
              status.desktopSessionActive, !status.provisioningPending,
              let client = integrationClient else { return }
        inputLatencyProbeStarted = true
        inputLatencyProbeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await OmarchyInputDiagnosticsAcceptanceProbe.runPinyin(
                    client: client, sharedDirectory: self.layout.shared,
                    diagnosticsDirectory: self.layout.diagnostics
                )
                try await OmarchyInputDiagnosticsAcceptanceProbe.runPinyin(
                    client: client, sharedDirectory: self.layout.shared,
                    diagnosticsDirectory: self.layout.diagnostics, xiaohe: true
                )
            } catch is CancellationError { return }
            catch { self.reportAcceptanceFailure("Pinyin acceptance failed: \(error.localizedDescription)") }
        }
    }

    @MainActor
    private func runStabilityScenarios() {
        guard acceptanceEnabled, let client = integrationClient,
              let view = machineView as? OmarchyVirtualMachineInputView else { return }
        continuousInputProbeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await OmarchyInputDiagnosticsAcceptanceProbe.verifyInteractiveDesktopEventually(
                    client: client, sharedDirectory: self.layout.shared, attempts: 3, timeoutPerAttempt: .seconds(8)
                )
                try await OmarchyInputDiagnosticsAcceptanceProbe.runContinuousInputBurst(
                    client: client, sharedDirectory: self.layout.shared,
                    diagnosticsDirectory: self.layout.diagnostics,
                    sendTextBurst: { view.runGuestAgentTextBurstAcceptance($0) },
                    sendKeyRepeat: { view.runGuestAgentKeyRepeatAcceptance(keyCode: 0, count: $0) }
                )
                _ = try await OmarchyInputLatencyAcceptanceProbe.run(
                    client: client, sharedDirectory: self.layout.shared,
                    diagnosticsDirectory: self.layout.diagnostics, sampleCount: 5,
                    sendAppleUSBText: { text in
                        view.setGuestInputEventHandler(nil)
                        defer { if let status = self.latestGuestStatus { self.configureDesktopInput(for: status) } }
                        guard view.runAppleUSBTextAcceptance(text) else { return false }
                        try? await Task.sleep(for: OmarchyHostKeyboardTextEncoder.eventQueueDuration(for: text))
                        return true
                    }
                )
                try await OmarchyDynamicDisplayAcceptanceProbe.runAcrossDisplays(
                    client: client, view: view, sharedDirectory: self.layout.shared,
                    diagnosticsDirectory: self.layout.diagnostics
                )
                try Data("{\"result\":\"passed\"}\n".utf8)
                    .write(to: self.layout.diagnostics.appending(path: "stability-scenarios.json"), options: .atomic)
            } catch is CancellationError { return }
            catch { self.reportAcceptanceFailure("Stability acceptance failed: \(error.localizedDescription)") }
        }
    }

    @MainActor
    func startAutomaticFullScreenProbeIfNeeded(_ status: VMOmarchyGuestStatus) {
        guard acceptanceEnabled, status.desktopSessionActive, !status.provisioningPending,
              automaticRecoveryStage == .complete,
              !automaticFullScreenProbeStarted, let machineView,
              let window = machineView.window else { return }
        automaticFullScreenProbeStarted = true
        let probe = OmarchyFullScreenAcceptanceProbe(
            window: window,
            virtualMachineView: machineView,
            layout: layout,
            completed: { [weak self] passed in
                guard let self else { return }
                if !passed { self.reportAcceptanceFailure("Full-screen transition timed out.") }
                else if self.acceptanceScenario == "stability" { self.runStabilityScenarios() }
            }
        )
        fullScreenProbe = probe
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak probe] in
            probe?.start()
        }
    }

    @MainActor
    func startAutomaticCommandSpaceProbeIfNeeded(_ status: VMOmarchyGuestStatus?) {
        guard acceptanceEnabled, let status, status.desktopSessionActive, !status.provisioningPending,
              !automaticCommandSpaceProbeStarted else { return }
        guard let integrationClient else { return }
        automaticCommandSpaceProbeStarted = true
        Task { @MainActor [weak self, weak integrationClient] in
            guard let self, let view = self.machineView, let window = view.window else { return }
            do {
                // The local harness may have been launched in the background.
                // Establish real focus before posting a system-level chord;
                // never send it to whichever host app happens to be active.
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(view)
                let deadline = ContinuousClock.now + .seconds(3)
                while !NSApp.isActive || !window.isKeyWindow {
                    guard ContinuousClock.now < deadline else {
                        self.reportAcceptanceFailure("Command+Space acceptance could not focus its test window.")
                        return
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard self.keyboardBridge?.runAcceptanceCommandSpaceProbe() == true else {
                    self.reportAcceptanceFailure(
                        "Focused Command+Space acceptance could not reach the Accessibility event tap."
                    )
                    return
                }
                // Command+Space intentionally opens Omarchy Menu. Keep it
                // visible long enough for the event-tap observation to be
                // committed, then dismiss it before the lock probe begins.
                // Otherwise the next acceptance chord and typed secret can
                // land in the menu's search field instead of the desktop.
                try await Task.sleep(for: .seconds(1))
                try await integrationClient?.injectKeyChord(modifiers: [], key: 1)
                try await Task.sleep(for: .milliseconds(500))
                self.startAutomaticLockProbeIfNeeded()
            } catch {
                self.reportAcceptanceFailure(
                    "Focused Command+Space cleanup failed: \(error.localizedDescription)"
                )
            }
        }
    }
}
#else
// Production has no automatic test implementation.
extension OmarchyVirtualMachineRepresentable.Coordinator {
    @MainActor
    func startBootUnlockAcceptanceIfNeeded() {}
    @MainActor
    func startInputLatencyProbeIfNeeded(_ status: VMOmarchyGuestStatus) {}
    @MainActor
    func startContinuousInputProbeIfNeeded(_ status: VMOmarchyGuestStatus) {}
    func startNotificationAcceptanceProbeIfNeeded(
        client: VMOmarchyGuestAgentClient
    ) {}
    func startSharedFolderProbeIfNeeded(layout: VMOmarchyWorkspaceLayout) {}
    func startClipboardProbeIfNeeded(layout: VMOmarchyWorkspaceLayout) {}
    func startDynamicDisplayProbeIfNeeded(layout: VMOmarchyWorkspaceLayout) {}
    func startAutomaticPauseResumeProbeIfNeeded() {}
    @MainActor
    func startAutomaticLockProbeIfNeeded() {}
    @MainActor
    func startHostWakeInteractiveProbe() {}
    @MainActor
    func handleAutomaticRecoveryReady(_ status: VMOmarchyGuestStatus) {}
    @MainActor
    func recoverGuestRestartInteractiveDesktop() {}
    @MainActor
    func startAutomaticFullScreenProbeIfNeeded(_ status: VMOmarchyGuestStatus) {}
    @MainActor
    func startAutomaticCommandSpaceProbeIfNeeded(_ status: VMOmarchyGuestStatus?) {}
}
#endif
