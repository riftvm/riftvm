import AVFoundation
import UserNotifications
import SwiftUI
import UniformTypeIdentifiers
import Virtualization

private let omarchyMetadataQueue = DispatchQueue(label: "com.riftvm.app.metadata")

final class OmarchyVirtualMachineInputView: VZVirtualMachineView {
    private var diagnosticMonitor: Any?
    private var diagnosticViewEvents = 0
    private var diagnosticWindowEvents = 0
    private let inputDiagnosticsEnabled = UserDefaults.standard.bool(forKey: "RiftVMInputDiagnosticsEnabled")

    private func recordInputDelivery(_ event: NSEvent, route: String) {
        guard inputDiagnosticsEnabled else { return }
        if route == "window" { diagnosticWindowEvents += 1 } else { diagnosticViewEvents += 1 }
        // Deliberately exclude characters, key codes, and modifier values.
        let ageMS = max(0, (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000)
        NSLog("RiftVM input timing route=%@ windowEvents=%d viewEvents=%d ageMS=%.1f keyWindow=%d firstResponder=%d",
              route, diagnosticWindowEvents, diagnosticViewEvents, ageMS,
              window?.isKeyWindow == true ? 1 : 0, window?.firstResponder === self ? 1 : 0)
    }

    private var displayObservers: [NSObjectProtocol] = []
    private var pendingDisplayRefresh: DispatchWorkItem?
    private var displayRefreshGeneration: UInt64 = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeDisplayObservers()
        guard let window else { return }
        if inputDiagnosticsEnabled {
            diagnosticMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
                if let self, event.window === self.window { self.recordInputDelivery(event, route: "window") }
                return event
            }
        }
        for name in [NSWindow.didEnterFullScreenNotification,
                     NSWindow.didExitFullScreenNotification,
                     NSWindow.didEndLiveResizeNotification,
                     NSWindow.didChangeBackingPropertiesNotification] {
            displayObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] _ in self?.refreshDisplayAfterTransition() })
        }
        displayObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self] _ in self?.scheduleDisplayRefresh() })
        refreshDisplayAfterTransition()
        // Match the standard VM window's initial focus, without stealing focus
        // from another workspace, a toolbar control, or a settings sheet.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window,
                  window.isKeyWindow, window.attachedSheet == nil,
                  window.firstResponder === window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    private func scheduleDisplayRefresh() {
        pendingDisplayRefresh?.cancel()
        displayRefreshGeneration &+= 1
        let work = DispatchWorkItem { [weak self] in self?.refreshDisplayAfterTransition() }
        pendingDisplayRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func refreshDisplayAfterTransition() {
        pendingDisplayRefresh?.cancel()
        pendingDisplayRefresh = nil
        displayRefreshGeneration &+= 1
        let generation = displayRefreshGeneration
        guard let targetWindow = window else { return }
        // Reuse the standard window's bounded native display refresh. The host
        // geometry and Linux modesetting settle at different times. Superseded
        // transitions and detached views must not reconfigure a newer session.
        for delay in [0.0, 0.35, 1.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak targetWindow] in
                guard let self, let targetWindow, self.window === targetWindow,
                      self.displayRefreshGeneration == generation,
                      self.virtualMachine != nil else { return }
                targetWindow.contentView?.layoutSubtreeIfNeeded()
                self.automaticallyReconfiguresDisplay = false
                self.automaticallyReconfiguresDisplay = true
            }
        }
    }

    private func removeDisplayObservers() {
        if let diagnosticMonitor { NSEvent.removeMonitor(diagnosticMonitor) }
        diagnosticMonitor = nil
        displayRefreshGeneration &+= 1
        pendingDisplayRefresh?.cancel()
        pendingDisplayRefresh = nil
        displayObservers.forEach(NotificationCenter.default.removeObserver)
        displayObservers.removeAll()
    }

    deinit {
        if let diagnosticMonitor { NSEvent.removeMonitor(diagnosticMonitor) }
        pendingDisplayRefresh?.cancel()
        displayObservers.forEach(NotificationCenter.default.removeObserver)
    }

    private func recordAcceptanceRoute(_ route: String, event: NSEvent) {
        guard ProcessInfo.processInfo.environment[
            OmarchyWorkspaceConfiguration.acceptanceEnabledKey
        ] == "1", let cgEvent = event.cgEvent else { return }
        let marker = cgEvent.getIntegerValueField(.eventSourceUserData)
        guard marker == OmarchyFocusedCommandBridge.acceptanceMarker
                || marker == OmarchyFocusedCommandBridge.syntheticMarker else { return }
        NSLog(
            "Omarchy acceptance input route=%@ keyCode=%hu flags=%llu marker=%lld",
            route, event.keyCode, event.modifierFlags.rawValue, marker
        )
    }

    override func keyDown(with event: NSEvent) {
        recordInputDelivery(event, route: "view")
        recordAcceptanceRoute("keyDown", event: event)
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        recordInputDelivery(event, route: "view")
        recordAcceptanceRoute("keyUp", event: event)
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        recordInputDelivery(event, route: "view")
        recordAcceptanceRoute("flagsChanged", event: event)
        super.flagsChanged(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        recordAcceptanceRoute("performKeyEquivalent", event: event)
        return super.performKeyEquivalent(with: event)
    }
}

struct OmarchyVirtualMachineView: View {
    let layout: VMOmarchyWorkspaceLayout
    let profile: VMOmarchyProfile
    let runtimePhaseChanged: ((Phase) -> Void)?
    @AppStorage("omarchyClipboardEnabled") private var clipboardEnabled = true
    @AppStorage("omarchyMicrophoneEnabled") private var microphoneEnabled = false
    @AppStorage("omarchyNotificationsEnabled") private var notificationsEnabled = false
    @State private var lifecycle = OmarchyMachineLifecycle()
    @State private var sessionID = UUID()
    @State private var keyboardIntegration: OmarchyKeyboardIntegrationState = .accessibilityRequired
    @State private var integration: VMOmarchyIntegrationState = .connecting
    @State private var stopTimeoutTask: Task<Void, Never>?
    @State private var recoveryPoints: [VMOmarchyRecoveryPoint] = []
    @State private var recoveryOperation: RecoveryOperation = .idle
    @State private var pendingRestore: VMOmarchyRecoveryPoint?
    @State private var factoryChannel: FactoryChannelViewState = .idle
    @State private var importingFiles = false
    @State private var managingFolders = false
    @State private var notice: UserNotice?
    @State private var recordedIntegrationSignature = ""
    @State private var sharedFolderProbe: VMOmarchySharedFolderProbeState = .notRun
    @State private var clipboardProbe: OmarchyClipboardProbeState = .notRun
    @State private var dynamicDisplayProbe: OmarchyDynamicDisplayProbeState = .notRun
    @State private var ownerSetupForm = OmarchyOwnerSetupForm()
    @State private var ownerSetupPhase: OmarchyOwnerSetupPhase = .editing
    @State private var ownerProvisioningSubmission: OmarchyOwnerProvisioningSubmission?
    @State private var automaticOwnerProvisioningStarted = false
    @State private var ownerProvisioningDetail: String?

    init(layout: VMOmarchyWorkspaceLayout, profile: VMOmarchyProfile, runtimePhaseChanged: ((Phase) -> Void)? = nil) {
        self.layout = layout
        self.profile = profile
        self.runtimePhaseChanged = runtimePhaseChanged
        let identity = (try? WorkspaceIdentity.load(at: layout.applicationSupportRoot).id.uuidString) ?? layout.applicationSupportRoot.path
        _clipboardEnabled = AppStorage(wrappedValue: true, "workspace.\(identity).clipboard")
        _microphoneEnabled = AppStorage(wrappedValue: false, "workspace.\(identity).microphone")
        _notificationsEnabled = AppStorage(wrappedValue: false, "workspace.\(identity).notifications")
    }

    private var phase: Phase { lifecycle.phase }

    var body: some View {
        ZStack {
            OmarchyVirtualMachineRepresentable(
                layout: layout,
                profile: profile,
                clipboardEnabled: clipboardEnabled,
                notificationsEnabled: notificationsEnabled,
                microphoneEnabled: microphoneEnabled,
                sessionID: sessionID,
                keyboardIntegrationChanged: { keyboardIntegration = $0 },
                integrationChanged: handleIntegrationChange,
                sharedFolderProbeChanged: handleSharedFolderProbeChange,
                clipboardProbeChanged: handleClipboardProbeChange,
                dynamicDisplayProbeChanged: handleDynamicDisplayProbeChange,
                ownerProvisioningSubmission: ownerProvisioningSubmission,
                ownerProvisioningCompleted: handleOwnerProvisioningCompletion,
                ownerProvisioningProgressChanged: {
                    ownerProvisioningDetail = $0.displayMessage
                    if ownerSetupPhase == .editing {
                        ownerSetupPhase = .finishing
                    }
                },
                phaseChanged: handlePhaseChange,
                sessionFailed: { notice = UserNotice(title: "Saved Session Needs Attention", message: $0) }
            )
            .id(sessionID)
            if phase != .running {
                statusOverlay
            }
            if ownerSetupAvailable {
                OmarchyOwnerSetupView(
                    form: $ownerSetupForm,
                    phase: ownerSetupPhase,
                    provisioningDetail: ownerProvisioningDetail,
                    submit: submitOwnerSetup
                )
            }
        }
        .sheet(isPresented: $managingFolders) {
            OmarchyFolderPermissionsView(workspace: layout.applicationSupportRoot, canEdit: phase == .stopped)
        }
        .onChange(of: phase) { _, updated in runtimePhaseChanged?(updated) }
        .background(.black)
        .dropDestination(for: URL.self) { urls, _ in
            importFiles(urls)
            return !urls.isEmpty
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                integrationMenu
                updatesMenu
                recoveryMenu
                Button("Folder Permissions", systemImage: "folder.badge.gearshape") {
                    managingFolders = true
                }
                Button("Open Shared Folder", systemImage: "folder") {
                    NSWorkspace.shared.open(layout.shared)
                }
                Button("Import Files", systemImage: "square.and.arrow.down") {
                    chooseFilesToImport()
                }
                .disabled(importingFiles)
                if phase == .running {
                    Button("Pause Omarchy", systemImage: "pause.fill") {
                        handle(.pauseRequested)
                    }
                    Button("Restart Omarchy", systemImage: "arrow.clockwise") {
                        handle(.restartRequested)
                    }
                    Button("Stop Omarchy", systemImage: "stop.fill") {
                        handle(.stopRequested)
                    }
                }
                if phase == .paused {
                    Button("Resume Omarchy", systemImage: "play.fill") {
                        handle(.resumeRequested)
                    }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if keyboardIntegration != .enabled {
                HStack {
                    if keyboardIntegration == .requestingAccessibility {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Waiting for Accessibility permission")
                        Text("Turn on RiftVM under Privacy & Security → Device Control and Data Access, then return here.")
                    } else {
                        Text("Allow Device Control and Data Access so Command shortcuts stay inside Omarchy.")
                    }
                    Spacer()
                    Button("Show RiftVM in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    }
                    .help("If RiftVM is missing from the permission list, use the + button in System Settings to add this application.")
                    Button(keyboardIntegration == .requestingAccessibility ? "Open System Settings" : "Enable") {
                        NotificationCenter.default.post(name: .omarchyRequestKeyboardPermission, object: sessionID)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.orange.opacity(0.18))
            }
        }
        .onDisappear {
            stopTimeoutTask?.cancel()
            stopTimeoutTask = nil
        }
        .onAppear { refreshRecoveryPoints() }
        .confirmationDialog(
            "Restore \(pendingRestore.map(recoveryPointTitle) ?? "this recovery point")?",
            isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Restore Omarchy", role: .destructive) {
                guard let point = pendingRestore else { return }
                pendingRestore = nil
                restore(point)
            }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: {
            Text("Omarchy must remain stopped. The current workspace will be replaced transactionally; an interrupted restore is rolled back automatically.")
        }
        .alert(item: $notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    @ViewBuilder
    private var integrationMenu: some View {
        Menu {
            switch integration {
            case .connecting:
                Text("Connecting to Guest Agent…")
            case .authenticating:
                Text("Authenticating Guest Agent…")
            case .disconnected(let reason):
                Text("Guest Agent unavailable")
                Text(reason).foregroundStyle(.secondary)
            case .ready(let status):
                Text("Agent \(status.agentVersion) • \(status.hostName)")
                let assessment = VMOmarchyIntegrationAssessment.evaluate(
                    status: status,
                    requiredCapabilities: profile.requiredGuestCapabilities
                )
                if assessment.provisioningPending {
                    Text("Complete Omarchy owner setup")
                } else if !assessment.desktopSessionActive {
                    Text("Waiting for Omarchy desktop")
                } else if !assessment.missingCapabilities.isEmpty {
                    Text("Missing: \(assessment.missingCapabilities.joined(separator: ", "))")
                } else {
                    Text("Omarchy desktop integration ready")
                }
                if !status.addresses.isEmpty { Text(status.addresses.joined(separator: ", ")) }
                if status.capabilities.contains("shared-folders-v1") {
                    Text("Shared folder mounted at /mnt/riftvm-shared")
                } else {
                    Text("Shared folder is not mounted in Omarchy")
                }
                if !clipboardEnabled {
                    Text("Clipboard sharing is off")
                } else if status.capabilities.contains("clipboard-agent-text-v1") {
                    Text(status.capabilities.contains("clipboard-agent-image-v1")
                        ? "Authenticated text and image clipboard ready"
                        : "Authenticated text clipboard ready")
                } else if status.capabilities.contains("clipboard-text-v1") {
                    Text(status.capabilities.contains("clipboard-image-v1")
                        ? "Text and image clipboard ready (compatibility mode)"
                        : "Text clipboard ready (compatibility mode)")
                } else {
                    Text("Clipboard session integration is not ready")
                }
                Text("Capabilities: \(status.capabilities.sorted().joined(separator: ", "))")
            }
            Divider()
            Toggle("Share Clipboard", isOn: $clipboardEnabled)
            Toggle("Mirror Notifications to macOS", isOn: notificationsBinding)
            Text(notificationsEnabled
                ? "Omarchy notifications appear in macOS Notification Center"
                : "Notification mirroring is off")
            Toggle("Share Mac Microphone", isOn: microphoneBinding)
            Text(microphoneEnabled
                ? "Microphone will be available after Omarchy restarts"
                : "Microphone sharing is off")
            Divider()
            Button("Export Diagnostics…", systemImage: "square.and.arrow.up") {
                exportDiagnostics()
            }
        } label: {
            Label("Integration", systemImage: integrationReady ? "checkmark.circle.fill" : "exclamationmark.circle")
        }
        .help(integrationReady ? "Omarchy integration is ready" : "Omarchy integration is not ready")
    }

    @ViewBuilder
    private func recoveryPointTitle(_ point: VMOmarchyRecoveryPoint) -> String {
        "\(point.name) · \(point.createdAt.formatted(date: .abbreviated, time: .standard))"
    }

    private var recoveryMenu: some View {
        Menu {
            switch recoveryOperation {
            case .idle:
                if phase == .stopped {
                    Button("Create Protected Backup", systemImage: "externaldrive.badge.plus") {
                        createProtectedBackup()
                    }
                } else {
                    Text("Stop Omarchy to create or restore backups")
                }
            case .working(let message):
                Text(message)
            case .failed(let message):
                Text(message)
                Button("Dismiss") { recoveryOperation = .idle }
            }
            if !recoveryPoints.isEmpty {
                Divider()
                ForEach(recoveryPoints) { point in
                    Button {
                        pendingRestore = point
                    } label: {
                        Label(recoveryPointTitle(point), systemImage: point.isProtected ? "lock.shield" : "clock.arrow.circlepath")
                    }
                    .disabled(phase != .stopped || recoveryOperation.isWorking)
                }
            }
        } label: {
            Label("Recovery", systemImage: recoveryOperation.isFailed ? "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90" : "clock.arrow.circlepath")
        }
        .help("Create or restore protected Omarchy recovery points")
    }

    private var integrationReady: Bool {
        if case .ready(let status) = integration {
            return VMOmarchyIntegrationAssessment.evaluate(
                status: status,
                requiredCapabilities: profile.requiredGuestCapabilities
            ).isReady
        }
        return false
    }

    private var microphoneBinding: Binding<Bool> {
        Binding(
            get: { microphoneEnabled },
            set: { enabled in
                requestMicrophoneSharing(enabled)
            }
        )
    }

    private var notificationsBinding: Binding<Bool> {
        Binding(
            get: { notificationsEnabled },
            set: { enabled in requestNotificationMirroring(enabled) }
        )
    }

    private func requestNotificationMirroring(_ enabled: Bool) {
        guard enabled != notificationsEnabled else { return }
        guard enabled else {
            notificationsEnabled = false
            return
        }
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch OmarchyNotificationPermissionPolicy.action(for: settings.authorizationStatus) {
            case .enable:
                notificationsEnabled = true
            case .request:
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) == true
                notificationsEnabled = granted
                if !granted { explainDeniedNotificationAccess() }
            case .openSystemSettings:
                explainDeniedNotificationAccess()
            }
        }
    }

    private func explainDeniedNotificationAccess() {
        notificationsEnabled = false
        notice = UserNotice(
            title: "Notification Access Is Off",
            message: "Allow RiftVM in System Settings → Notifications, then enable mirroring again."
        )
        NSWorkspace.shared.open(OmarchyNotificationPermissionPolicy.settingsURL)
    }

    private func requestMicrophoneSharing(_ enabled: Bool) {
        guard enabled != microphoneEnabled else { return }
        guard enabled else {
            applyMicrophoneSharing(false)
            return
        }
        switch OmarchyMicrophonePermissionPolicy.action(
            for: AVCaptureDevice.authorizationStatus(for: .audio)
        ) {
        case .enable:
            applyMicrophoneSharing(true)
        case .request:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    if granted {
                        applyMicrophoneSharing(true)
                    } else {
                        explainDeniedMicrophoneAccess(openSettings: true)
                    }
                }
            }
        case .openSystemSettings:
            explainDeniedMicrophoneAccess(openSettings: true)
        }
    }

    private func applyMicrophoneSharing(_ enabled: Bool) {
        microphoneEnabled = enabled
        guard phase == .running || phase == .paused else { return }
        notice = UserNotice(
            title: "Restart Omarchy to Apply",
            message: enabled
                ? "Restart Omarchy to make the Mac microphone available to Linux applications."
                : "Restart Omarchy to remove the Mac microphone from the virtual machine."
        )
    }

    private func explainDeniedMicrophoneAccess(openSettings: Bool) {
        microphoneEnabled = false
        notice = UserNotice(
            title: "Microphone Access Is Off",
            message: "Allow RiftVM Omarchy under Privacy & Security → Microphone, then enable sharing again."
        )
        if openSettings {
            NSWorkspace.shared.open(OmarchyMicrophonePermissionPolicy.settingsURL)
        }
    }

    private var ownerSetupAvailable: Bool {
        guard case .ready(let status) = integration else { return false }
        return status.provisioningPending && status.capabilities.contains("owner-provisioning-v1")
    }

    private func submitOwnerSetup() {
        guard ownerSetupPhase != .submitting, ownerSetupPhase != .finishing else { return }
        do {
            let request = try ownerSetupForm.validatedRequest()
            ownerSetupPhase = .submitting
            ownerProvisioningSubmission = .init(request: request)
        } catch {
            ownerSetupPhase = .failed(error.localizedDescription)
        }
    }

    private func handleOwnerProvisioningCompletion(_ id: UUID, _ errorMessage: String?) {
        guard ownerProvisioningSubmission?.id == id else { return }
        ownerProvisioningSubmission = nil
        if let errorMessage {
            ownerSetupPhase = .failed(errorMessage)
        } else {
            ownerSetupForm.clearSecrets()
            ownerSetupPhase = .finishing
        }
    }

    @ViewBuilder
    private var updatesMenu: some View {
        Menu {
            Text("App updates are delivered separately from Omarchy and factory images.")
            Text("Guest updates run inside Omarchy; create a protected backup first.")
            Divider()
            switch factoryChannel {
            case .idle:
                Button("Check Signed Factory Channel", systemImage: "checkmark.shield") {
                    checkFactoryChannel()
                }
            case .checking:
                Text("Checking signed factory metadata…")
            case .current(let version):
                Text("Installed from current factory \(version)")
                Button("Check Again") { checkFactoryChannel() }
            case .untracked(let available):
                Text("Current workspace has no recorded factory version")
                Text("Signed channel factory: \(available)")
                Text("Factory images are only used for new installs and recovery.")
                Button("Check Again") { checkFactoryChannel() }
            case .different(let installed, let available):
                Text("Workspace factory: \(installed)")
                Text("Signed channel factory: \(available)")
                Text("The different channel image will not replace this workspace.")
                Button("Check Again") { checkFactoryChannel() }
            case .failed(let message):
                Text(message)
                Button("Try Again") { checkFactoryChannel() }
            }
        } label: {
            Label("Updates", systemImage: factoryChannel.needsAttention ? "arrow.down.circle.fill" : "arrow.triangle.2.circlepath")
        }
        .help("App, factory-image, and guest update status")
    }

    private func checkFactoryChannel() {
        guard factoryChannel != .checking else { return }
        guard let publicKey = FactoryTrustConfiguration.publicKey() else {
            factoryChannel = .failed("This build has no trusted factory signing key.")
            return
        }
        let workspace = VMOmarchyWorkspaceManager(layout: layout)
        let installedVersion = try? workspace.metadata().factoryImageVersion
        let installer = VMOmarchyFactoryInstaller(
            profile: profile,
            cacheDirectory: layout.cache,
            publicKey: publicKey,
            transport: VMOmarchyURLSessionTransport()
        )
        factoryChannel = .checking
        Task {
            do {
                let manifest = try await installer.fetchVerifiedManifest()
                switch VMOmarchyFactoryChannelState.assess(
                    installedVersion: installedVersion,
                    manifest: manifest
                ) {
                case .current(let version): factoryChannel = .current(version)
                case .untracked(let available): factoryChannel = .untracked(available)
                case .different(let installed, let available):
                    factoryChannel = .different(installed: installed, available: available)
                }
            } catch {
                factoryChannel = .failed(error.localizedDescription)
            }
        }
    }

    private func handleIntegrationChange(_ state: VMOmarchyIntegrationState) {
        integration = state
        guard case .ready(let status) = state else { return }
        startAutomaticOwnerProvisioningIfNeeded(status)
        if !status.provisioningPending {
            ownerSetupForm.clearSecrets()
            ownerProvisioningSubmission = nil
            ownerSetupPhase = .editing
            ownerProvisioningDetail = nil
        }
        OmarchyAcceptanceObservationReporter.reportIfEnabled(
            status: status,
            requiredCapabilities: profile.requiredGuestCapabilities,
            layout: layout,
            sharedFolderRoundTrip: sharedFolderRoundTrip,
            clipboardRoundTrip: clipboardRoundTrip,
            dynamicDisplayRoundTrip: dynamicDisplayRoundTrip
        )
        let signature = ([status.omarchyRevision ?? "", status.agentVersion]
            + status.capabilities.sorted()).joined(separator: "\u{1f}")
        guard signature != recordedIntegrationSignature else { return }
        recordedIntegrationSignature = signature
        let manager = VMOmarchyWorkspaceManager(layout: layout)
        omarchyMetadataQueue.async {
            do {
                try manager.recordGuestIntegration(
                    omarchyRevision: status.omarchyRevision,
                    agentVersion: status.agentVersion,
                    capabilities: status.capabilities
                )
            } catch {
                NSLog("Could not record Omarchy integration metadata: %@", error.localizedDescription)
            }
        }
    }

    private func startAutomaticOwnerProvisioningIfNeeded(_ status: VMOmarchyGuestStatus) {
        guard status.provisioningPending,
              status.capabilities.contains("owner-provisioning-v1"),
              !automaticOwnerProvisioningStarted,
              let password = OmarchyWorkspaceConfiguration.acceptanceOwnerProvisioningPassword()
        else { return }

        automaticOwnerProvisioningStarted = true
        var form = ownerSetupForm
        form.password = password
        form.passwordConfirmation = password
        do {
            let request = try form.validatedRequest()
            ownerSetupForm = form
            ownerSetupPhase = .submitting
            ownerProvisioningSubmission = .init(request: request)
        } catch {
            form.clearSecrets()
            ownerSetupForm = form
            ownerSetupPhase = .failed(error.localizedDescription)
        }
    }

    private var sharedFolderRoundTrip: VMOmarchySharedFolderRoundTrip? {
        guard case .passed(let result) = sharedFolderProbe else { return nil }
        return result
    }

    private func handleSharedFolderProbeChange(_ state: VMOmarchySharedFolderProbeState) {
        sharedFolderProbe = state
        guard case .ready(let status) = integration else { return }
        OmarchyAcceptanceObservationReporter.reportIfEnabled(
            status: status,
            requiredCapabilities: profile.requiredGuestCapabilities,
            layout: layout,
            sharedFolderRoundTrip: sharedFolderRoundTrip,
            clipboardRoundTrip: clipboardRoundTrip,
            dynamicDisplayRoundTrip: dynamicDisplayRoundTrip
        )
    }

    private var clipboardRoundTrip: OmarchyClipboardRoundTrip? {
        guard case .passed(let result) = clipboardProbe else { return nil }
        return result
    }

    private func handleClipboardProbeChange(_ state: OmarchyClipboardProbeState) {
        clipboardProbe = state
        guard case .ready(let status) = integration else { return }
        OmarchyAcceptanceObservationReporter.reportIfEnabled(
            status: status,
            requiredCapabilities: profile.requiredGuestCapabilities,
            layout: layout,
            sharedFolderRoundTrip: sharedFolderRoundTrip,
            clipboardRoundTrip: clipboardRoundTrip,
            dynamicDisplayRoundTrip: dynamicDisplayRoundTrip
        )
    }

    private var dynamicDisplayRoundTrip: OmarchyDynamicDisplayRoundTrip? {
        guard case .passed(let result) = dynamicDisplayProbe else { return nil }
        return result
    }

    private func handleDynamicDisplayProbeChange(_ state: OmarchyDynamicDisplayProbeState) {
        dynamicDisplayProbe = state
        guard case .ready(let status) = integration else { return }
        OmarchyAcceptanceObservationReporter.reportIfEnabled(
            status: status,
            requiredCapabilities: profile.requiredGuestCapabilities,
            layout: layout,
            sharedFolderRoundTrip: sharedFolderRoundTrip,
            clipboardRoundTrip: clipboardRoundTrip,
            dynamicDisplayRoundTrip: dynamicDisplayRoundTrip
        )
    }

    private func chooseFilesToImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Import into Omarchy"
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.title = "Export RiftVM Omarchy Diagnostics"
        let date = ISO8601DateFormatter().string(from: Date()).prefix(10)
        panel.nameFieldStringValue = "RiftVM-Omarchy-Diagnostics-\(date).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            let report = VMOmarchyDiagnostics().report(
                layout: layout,
                appVersion: appVersion,
                integrationState: integration
            )
            try report.encoded().write(to: destination, options: .atomic)
            notice = UserNotice(title: "Diagnostics Exported", message: destination.lastPathComponent)
        } catch {
            notice = UserNotice(title: "Diagnostics Export Failed", message: error.localizedDescription)
        }
    }

    private func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty, !importingFiles else { return }
        importingFiles = true
        let importer = VMOmarchySharedFolderImporter(layout: layout)
        DispatchQueue.global(qos: .userInitiated).async {
            let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
            defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
            let result = Result { try importer.importFiles(urls) }
            DispatchQueue.main.async {
                importingFiles = false
                switch result {
                case .success(let files):
                    let names = files.map(\.destinationURL.lastPathComponent).joined(separator: ", ")
                    notice = UserNotice(
                        title: "Files Ready in Omarchy",
                        message: "Imported \(files.count) file(s): \(names). Open /mnt/riftvm-shared in Omarchy."
                    )
                case .failure(let error):
                    notice = UserNotice(title: "Import Failed", message: error.localizedDescription)
                }
            }
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch phase {
        case .starting:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Starting Omarchy…").font(.headline)
            }
            .padding(26)
            .background(.regularMaterial, in: .rect(cornerRadius: 14))
        case .running:
            EmptyView()
        case .pausing:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Pausing Omarchy…").font(.headline)
            }
            .padding(26)
            .background(.regularMaterial, in: .rect(cornerRadius: 14))
        case .paused:
            VStack(spacing: 14) {
                Text("Omarchy is paused").font(.headline)
                Button("Resume Omarchy", systemImage: "play.fill") {
                    handle(.resumeRequested)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(26)
            .background(.regularMaterial, in: .rect(cornerRadius: 14))
        case .resuming:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Resuming Omarchy…").font(.headline)
            }
            .padding(26)
            .background(.regularMaterial, in: .rect(cornerRadius: 14))
        case .stopping:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Stopping Omarchy…").font(.headline)
            }
            .padding(26)
            .background(.regularMaterial, in: .rect(cornerRadius: 14))
        case .stopped:
            VStack(spacing: 14) {
                Text("Omarchy is stopped").font(.headline)
                Button("Start Omarchy", systemImage: "play.fill") {
                    handle(.startRequested)
                }
                .buttonStyle(.borderedProminent)
                .disabled(recoveryOperation.isWorking)
            }
            .padding(26)
            .background(.regularMaterial, in: .rect(cornerRadius: 14))
        case .failed(let message):
            VStack(spacing: 14) {
                ContentUnavailableView(
                    "Omarchy needs attention",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
                if VMOmarchySavedSession.hasSession(layout: layout),
                   !WorkspaceCoordinator.shared.hasLiveOmarchy(at: layout.applicationSupportRoot) {
                    Button("Start Without Saved Session…") { discardSavedSessionAndStart() }
                }
            }
            .padding(30)
            .background(.regularMaterial)
        }
    }

    private func discardSavedSessionAndStart() {
        let alert = NSAlert()
        alert.messageText = "Discard the saved session?"
        alert.informativeText = "Unsaved work held in guest memory will be lost. The virtual disk will be kept and Omarchy will start normally."
        alert.addButton(withTitle: "Discard and Start")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let lease = VMRunningRegistry.shared.acquire(rootPath: layout.applicationSupportRoot, phase: .maintaining) else { return }
        defer { VMRunningRegistry.shared.release(lease) }
        do {
            try VMOmarchySavedSession.discard(layout: layout)
            handle(.startRequested)
        } catch {
            notice = UserNotice(title: "Could Not Discard Session", message: error.localizedDescription)
        }
    }

    private func handlePhaseChange(_ phase: Phase) {
        switch phase {
        case .running: handle(.machineStarted)
        case .paused: handle(.machinePaused)
        case .stopped:
            handle(.machineStopped)
            refreshRecoveryPoints()
        case .failed(let message): handle(.machineFailed(message))
        case .stopping: lifecycle.phase = .stopping
        case .starting, .pausing, .resuming: break
        }
    }

    private func refreshRecoveryPoints() {
        recoveryPoints = VMOmarchyRecoveryManager(
            workspaceManager: VMOmarchyWorkspaceManager(layout: layout)
        ).recoveryPoints()
    }

    private func createProtectedBackup() {
        guard phase == .stopped, !recoveryOperation.isWorking else { return }
        guard let lease = VMRunningRegistry.shared.acquire(rootPath: layout.applicationSupportRoot, phase: .maintaining) else {
            recoveryOperation = .failed("This workspace is busy. Shut it down and wait for other maintenance operations to finish.")
            return
        }
        recoveryOperation = .working("Creating protected backup…")
        let manager = VMOmarchyRecoveryManager(
            workspaceManager: VMOmarchyWorkspaceManager(layout: layout)
        )
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try manager.createProtectedBackup() }
            DispatchQueue.main.async {
                VMRunningRegistry.shared.release(lease)
                switch result {
                case .success:
                    recoveryOperation = .idle
                    refreshRecoveryPoints()
                case .failure(let error):
                    recoveryOperation = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func restore(_ point: VMOmarchyRecoveryPoint) {
        guard phase == .stopped, !recoveryOperation.isWorking else { return }
        guard let lease = VMRunningRegistry.shared.acquire(rootPath: layout.applicationSupportRoot, phase: .maintaining) else {
            recoveryOperation = .failed("This workspace is busy. Shut it down and wait for other maintenance operations to finish.")
            return
        }
        recoveryOperation = .working("Restoring \(point.name)…")
        let manager = VMOmarchyRecoveryManager(
            workspaceManager: VMOmarchyWorkspaceManager(layout: layout)
        )
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try manager.restore(id: point.id) }
            DispatchQueue.main.async {
                VMRunningRegistry.shared.release(lease)
                switch result {
                case .success:
                    recoveryOperation = .idle
                    refreshRecoveryPoints()
                case .failure(let error):
                    recoveryOperation = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func handle(_ event: OmarchyMachineLifecycle.Event) {
        for effect in lifecycle.handle(event) {
            switch effect {
            case .requestStop:
                NotificationCenter.default.post(name: .omarchyRequestStop, object: sessionID)
            case .requestPause:
                NotificationCenter.default.post(name: .omarchyRequestPause, object: sessionID)
            case .requestResume:
                NotificationCenter.default.post(name: .omarchyRequestResume, object: sessionID)
            case .startNewSession:
                sessionID = UUID()
            case .scheduleStopTimeout:
                stopTimeoutTask?.cancel()
                stopTimeoutTask = Task {
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled else { return }
                    await MainActor.run { handle(.stopTimedOut) }
                }
            case .cancelStopTimeout:
                stopTimeoutTask?.cancel()
                stopTimeoutTask = nil
            case .askStopTimeout:
                let alert = NSAlert()
                alert.messageText = "Omarchy is still shutting down"
                alert.informativeText = "Wait for shutdown to finish, or force stop this workspace. Force stopping may lose unsaved guest work."
                alert.addButton(withTitle: "Wait")
                alert.addButton(withTitle: "Force Stop")
                handle(alert.runModal() == .alertSecondButtonReturn ? .forceStopConfirmed : .keepWaiting)
            case .forceStop:
                NotificationCenter.default.post(name: .omarchyForceStop, object: sessionID)
            }
        }
    }

    enum Phase: Equatable {
        case starting
        case running
        case pausing
        case paused
        case resuming
        case stopping
        case stopped
        case failed(String)
    }

    private enum RecoveryOperation: Equatable {
        case idle
        case working(String)
        case failed(String)

        var isWorking: Bool {
            if case .working = self { return true }
            return false
        }

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    private enum FactoryChannelViewState: Equatable {
        case idle
        case checking
        case current(String)
        case untracked(String)
        case different(installed: String, available: String)
        case failed(String)

        var needsAttention: Bool {
            switch self {
            case .untracked, .different, .failed: true
            case .idle, .checking, .current: false
            }
        }
    }

    private struct UserNotice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }
}

enum OmarchyMicrophonePermissionAction: Equatable {
    case enable
    case request
    case openSystemSettings
}

enum OmarchyMicrophonePermissionPolicy {
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    )!

    static func action(for status: AVAuthorizationStatus) -> OmarchyMicrophonePermissionAction {
        switch status {
        case .authorized: .enable
        case .notDetermined: .request
        case .denied, .restricted: .openSystemSettings
        @unknown default: .openSystemSettings
        }
    }
}

enum OmarchyClipboardActivationPolicy {
    static func shouldRun(
        enabled: Bool,
        capabilities: Set<String>,
        desktopSessionActive: Bool,
        provisioningPending: Bool,
        probeOwnsTransport: Bool
    ) -> Bool {
        enabled
            && !probeOwnsTransport
            && desktopSessionActive
            && !provisioningPending
            && Set(["clipboard-agent-text-v1", "clipboard-agent-image-v1"])
                .isSubset(of: capabilities)
    }
}

struct OmarchyMachineLifecycle: Equatable {
    var phase: OmarchyVirtualMachineView.Phase = .starting
    private(set) var restartAfterStop = false

    enum Event: Equatable {
        case machineStarted
        case pauseRequested
        case machinePaused
        case resumeRequested
        case startRequested
        case stopRequested
        case restartRequested
        case machineStopped
        case machineFailed(String)
        case stopTimedOut
        case keepWaiting
        case forceStopConfirmed
    }

    enum Effect: Equatable {
        case requestStop
        case requestPause
        case requestResume
        case startNewSession
        case scheduleStopTimeout
        case cancelStopTimeout
        case askStopTimeout
        case forceStop
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .machineStarted:
            phase = .running
        case .pauseRequested:
            guard phase == .running else { return [] }
            phase = .pausing
            return [.requestPause]
        case .machinePaused:
            guard phase == .pausing else { return [] }
            phase = .paused
        case .resumeRequested:
            guard phase == .paused else { return [] }
            phase = .resuming
            return [.requestResume]
        case .startRequested:
            guard phase == .stopped || isFailed else { return [] }
            restartAfterStop = false
            phase = .starting
            return [.startNewSession]
        case .stopRequested:
            guard phase == .running || phase == .paused else { return [] }
            restartAfterStop = false
            phase = .stopping
            return [.requestStop, .scheduleStopTimeout]
        case .restartRequested:
            guard phase == .running || phase == .paused else { return [] }
            restartAfterStop = true
            phase = .stopping
            return [.requestStop, .scheduleStopTimeout]
        case .machineStopped:
            if restartAfterStop {
                restartAfterStop = false
                phase = .starting
                return [.cancelStopTimeout, .startNewSession]
            }
            phase = .stopped
            return [.cancelStopTimeout]
        case .machineFailed(let message):
            restartAfterStop = false
            phase = .failed(message)
            return [.cancelStopTimeout]
        case .stopTimedOut:
            guard phase == .stopping else { return [] }
            return [.askStopTimeout]
        case .keepWaiting:
            guard phase == .stopping else { return [] }
            return [.scheduleStopTimeout]
        case .forceStopConfirmed:
            guard phase == .stopping else { return [] }
            return [.forceStop]
        }
        return []
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }
}

private struct OmarchyVirtualMachineRepresentable: NSViewRepresentable {
    let layout: VMOmarchyWorkspaceLayout
    let profile: VMOmarchyProfile
    let clipboardEnabled: Bool
    let notificationsEnabled: Bool
    let microphoneEnabled: Bool
    let sessionID: UUID
    let keyboardIntegrationChanged: (OmarchyKeyboardIntegrationState) -> Void
    let integrationChanged: (VMOmarchyIntegrationState) -> Void
    let sharedFolderProbeChanged: (VMOmarchySharedFolderProbeState) -> Void
    let clipboardProbeChanged: (OmarchyClipboardProbeState) -> Void
    let dynamicDisplayProbeChanged: (OmarchyDynamicDisplayProbeState) -> Void
    let ownerProvisioningSubmission: OmarchyOwnerProvisioningSubmission?
    let ownerProvisioningCompleted: (UUID, String?) -> Void
    let ownerProvisioningProgressChanged: (VMOmarchyOwnerProvisioningProgress) -> Void
    let phaseChanged: (OmarchyVirtualMachineView.Phase) -> Void
    let sessionFailed: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            sessionID: sessionID,
            layout: layout,
            requiredGuestCapabilities: profile.requiredGuestCapabilities,
            clipboardEnabled: clipboardEnabled,
            notificationsEnabled: notificationsEnabled,
            keyboardIntegrationChanged: keyboardIntegrationChanged,
            integrationChanged: integrationChanged,
            sharedFolderProbeChanged: sharedFolderProbeChanged,
            clipboardProbeChanged: clipboardProbeChanged,
            dynamicDisplayProbeChanged: dynamicDisplayProbeChanged,
            ownerProvisioningCompleted: ownerProvisioningCompleted,
            ownerProvisioningProgressChanged: ownerProvisioningProgressChanged,
            phaseChanged: phaseChanged,
            sessionFailed: sessionFailed
        )
    }

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = OmarchyVirtualMachineInputView()
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        var reservation: VMRunLease?
        do {
            reservation = try WorkspaceCoordinator.shared.reserveOmarchy(at: layout.applicationSupportRoot)
            let configuration = try VMOmarchyVirtualMachineBuilder.makeConfiguration(
                layout: layout,
                profile: profile,
                microphoneEnabled: microphoneEnabled
            )
            let machine = VZVirtualMachine(configuration: configuration)
            machine.delegate = context.coordinator
            context.coordinator.machine = machine
            context.coordinator.machineView = view
            context.coordinator.configureSavedSession(configuration, microphoneEnabled: microphoneEnabled)
            try WorkspaceCoordinator.shared.registerOmarchy(
                machine, configuration: configuration, at: layout.applicationSupportRoot,
                requestShutdown: { [weak coordinator = context.coordinator] in coordinator?.requestStop() },
                canSave: { [weak coordinator = context.coordinator] in coordinator?.canSaveSession == true },
                requestSave: { [weak coordinator = context.coordinator] in coordinator?.saveAndStop() },
                savePending: { [weak coordinator = context.coordinator] in coordinator?.savingSession == true },
                requestForceStop: { [weak coordinator = context.coordinator] in coordinator?.forceStop() }
            )
            context.coordinator.beginObservingCommands()
            view.virtualMachine = machine
            context.coordinator.installKeyboardBridge(for: view)
            try context.coordinator.startMachine()
        } catch {
            if let reservation {
                WorkspaceCoordinator.shared.releaseOmarchyReservation(at: layout.applicationSupportRoot, expectedLease: reservation)
            }
            DispatchQueue.main.async {
                context.coordinator.phaseChanged(.failed(error.localizedDescription))
            }
        }
        return view
    }

    func updateNSView(_ nsView: VZVirtualMachineView, context: Context) {
        context.coordinator.setClipboardEnabled(clipboardEnabled)
        context.coordinator.setNotificationsEnabled(notificationsEnabled)
        if let ownerProvisioningSubmission {
            context.coordinator.submitOwnerProvisioning(ownerProvisioningSubmission)
        }
    }

    static func dismantleNSView(_ nsView: VZVirtualMachineView, coordinator: Coordinator) {
        coordinator.stopImmediately()
        nsView.virtualMachine = nil
    }

    final class Coordinator: NSObject, VZVirtualMachineDelegate {
        var machine: VZVirtualMachine?
        let sessionID: UUID
        let layout: VMOmarchyWorkspaceLayout
        let requiredGuestCapabilities: [String]
        private var clipboardEnabled: Bool
        private var notificationsEnabled: Bool
        let keyboardIntegrationChanged: (OmarchyKeyboardIntegrationState) -> Void
        let integrationChanged: (VMOmarchyIntegrationState) -> Void
        let sharedFolderProbeChanged: (VMOmarchySharedFolderProbeState) -> Void
        let clipboardProbeChanged: (OmarchyClipboardProbeState) -> Void
        let dynamicDisplayProbeChanged: (OmarchyDynamicDisplayProbeState) -> Void
        let ownerProvisioningCompleted: (UUID, String?) -> Void
        let ownerProvisioningProgressChanged: (VMOmarchyOwnerProvisioningProgress) -> Void
        let phaseChanged: (OmarchyVirtualMachineView.Phase) -> Void
        let sessionFailed: (String) -> Void
        private var stopObserver: NSObjectProtocol?
        private var pauseObserver: NSObjectProtocol?
        private var resumeObserver: NSObjectProtocol?
        private var keyboardPermissionObserver: NSObjectProtocol?
        private var forceStopObserver: NSObjectProtocol?
        private var keyboardBridge: OmarchyFocusedCommandBridge?
        private var integrationClient: VMOmarchyGuestAgentClient?
        private var agentClipboardController: OmarchyAgentClipboardController?
        private var notificationController: OmarchyNotificationController?
        private var notificationAcceptanceProbeTask: Task<Void, Never>?
        private var notificationAcceptanceProbeStarted = false
        private var notificationAcceptanceProbeCompleted = false
        private var expectedAcceptanceNotificationTitle: String?
        private var latestGuestStatus: VMOmarchyGuestStatus?
        private var shutdownAfterResume = false
        private var clipboardProbeOwnsTransport = false
        private var sharedFolderProbeTask: Task<Void, Never>?
        private var sharedFolderProbePassed = false
        private var clipboardProbeTask: Task<Void, Never>?
        private var clipboardProbePassed = false
        weak var machineView: VZVirtualMachineView?
        private var dynamicDisplayProbeTask: Task<Void, Never>?
        private var dynamicDisplayProbePassed = false
        private var automaticLockProbe = OmarchyLockAcceptanceState()
        private var automaticPauseResumeProbeStarted = false
        private var automaticRecoveryAfterResume = false
        private var automaticRecoveryStage = AutomaticRecoveryStage.idle
        private var recoveryBaselineStatus: VMOmarchyGuestStatus?
        private var guestRestartAcceptanceState = OmarchyGuestRestartAcceptanceState()
        private var guestRestartUnlockTimeoutTask: Task<Void, Never>?
        private var hostWakeInteractiveTask: Task<Void, Never>?
        private var automaticCommandSpaceProbeStarted = false
        private var automaticFullScreenProbeStarted = false
        private var fullScreenProbe: OmarchyFullScreenAcceptanceProbe?
        private var lastOwnerProvisioningSubmissionID: UUID?
        private var ownerProgressFetchInFlight = false

        private enum AutomaticRecoveryStage {
            case idle
            case waitingForPostResumeReady
            case waitingForAgentDisconnect
            case waitingForAgentReady
            case waitingForGuestDisconnect
            case waitingForGuestReady
            case complete
        }

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
            sessionFailed: @escaping (String) -> Void
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
            self.phaseChanged = phaseChanged
            self.sessionFailed = sessionFailed
        }

        private(set) var sessionConfiguration: VMOmarchySavedSession.Configuration?
        private var supportsSavedSession = false
        private(set) var savingSession = false
        private var sessionGeneration = 0

        @MainActor
        func configureSavedSession(_ configuration: VZVirtualMachineConfiguration, microphoneEnabled: Bool) {
            sessionConfiguration = .init(cpuCount: configuration.cpuCount, memoryBytes: configuration.memorySize,
                                         microphoneEnabled: microphoneEnabled)
            do {
                try configuration.validateSaveRestoreSupport()
                supportsSavedSession = true
            } catch {
                supportsSavedSession = false
                RiftVMLog.info("Omarchy saved sessions are unavailable: \(error.localizedDescription)")
            }
        }

        @MainActor
        var canSaveSession: Bool {
            supportsSavedSession && !savingSession && (machine?.state == .running || machine?.state == .paused)
        }

        @MainActor
        func startMachine() throws {
            guard let machine, let sessionConfiguration else { return }
            if let state = try VMOmarchySavedSession.stateToRestore(layout: layout, configuration: sessionConfiguration) {
                machine.restoreMachineStateFrom(url: state) { [weak self, weak machine] error in
                    DispatchQueue.main.async {
                        guard let self, let machine, self.machine === machine else { return }
                        if let error {
                            if machine.state == .stopped || machine.state == .error {
                                WorkspaceCoordinator.shared.omarchyDidStop(machine)
                            }
                            self.phaseChanged(.failed("Could not restore the saved session: \(error.localizedDescription)"))
                            return
                        }
                        self.restoredSavedSession = true
                        machine.resume { result in
                            DispatchQueue.main.async {
                                switch result {
                                case .success:
                                    do { try VMOmarchySavedSession.discard(layout: self.layout) }
                                    catch { RiftVMLog.error("Could not remove consumed Omarchy session: \(error.localizedDescription)") }
                                    self.restoredSavedSession = true
                                    self.startIntegration(layout: self.layout)
                                    self.phaseChanged(.running)
                                    RiftVMLog.info("Omarchy saved session restored")
                                case .failure(let error):
                                    self.phaseChanged(.paused)
                                    self.sessionFailed("The restored session remains paused: \(error.localizedDescription)")
                                }
                            }
                        }
                    }
                }
            } else {
                machine.start { [weak self, weak machine] result in
                    DispatchQueue.main.async {
                        guard let self, let machine, self.machine === machine else { return }
                        switch result {
                        case .success:
                            self.startIntegration(layout: self.layout)
                            self.phaseChanged(.running)
                        case .failure(let error):
                            WorkspaceCoordinator.shared.omarchyDidStop(machine)
                            self.phaseChanged(.failed(error.localizedDescription))
                        }
                    }
                }
            }
        }

        @MainActor
        func saveAndStop() {
            guard canSaveSession, let machine, let configuration = sessionConfiguration else { return }
            savingSession = true
            sessionGeneration += 1
            let generation = sessionGeneration
            phaseChanged(.stopping)
            let save: @MainActor () -> Void = { [weak self] in
                guard let self, self.sessionGeneration == generation else { return }
                self.keyboardBridge?.stop()
                self.stopAgentClipboard()
                self.stopNotifications()
                self.integrationClient?.virtualMachineDidPause()
                do {
                    let pending = try VMOmarchySavedSession.prepare(layout: self.layout)
                    machine.saveMachineStateTo(url: pending) { [weak self] error in
                        DispatchQueue.main.async {
                            guard let self, self.sessionGeneration == generation else { return }
                            if let error { self.savedSessionFailed(error); return }
                            machine.stop { error in
                                DispatchQueue.main.async {
                                    guard self.sessionGeneration == generation else { return }
                                    if let error { self.savedSessionFailed(error); return }
                                    // Disk/EFI fingerprints must be captured after VZ has
                                    // flushed and closed the stopped guest's devices.
                                    do {
                                        try VMOmarchySavedSession.commit(layout: self.layout, configuration: configuration)
                                        RiftVMLog.info("Omarchy saved session committed")
                                    } catch {
                                        self.savedSessionFailed(error, preservePending: true)
                                        return
                                    }
                                    self.savingSession = false
                                    WorkspaceCoordinator.shared.omarchyDidStop(machine)
                                    self.stopIntegration()
                                    self.machineView?.virtualMachine = nil
                                    self.machine = nil
                                    self.phaseChanged(.stopped)
                                }
                            }
                        }
                    }
                } catch { self.savedSessionFailed(error) }
            }
            if machine.state == .paused { save() }
            else {
                machine.pause { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self, self.sessionGeneration == generation else { return }
                        switch result {
                        case .success: save()
                        case .failure(let error): self.savedSessionFailed(error)
                        }
                    }
                }
            }
        }

        @MainActor
        private func savedSessionFailed(_ error: Error, preservePending: Bool = false) {
            savingSession = false
            if !preservePending { VMOmarchySavedSession.discardPending(layout: layout) }
            let message = "Could not save the Omarchy session: \(error.localizedDescription)"
            RiftVMLog.error(message)
            sessionFailed(message)
            if let machine, machine.state == .stopped || machine.state == .error {
                WorkspaceCoordinator.shared.omarchyDidStop(machine)
                stopIntegration()
                phaseChanged(.failed(message))
            } else {
                // Keep ownership of a live VM; a failed save is never permission
                // to force stop it. The quit transaction offers Wait/Cancel.
                phaseChanged(machine?.state == .paused ? .paused : .running)
            }
        }

        private var folderAcceptanceStarted = false

        @MainActor
        private func runFolderAcceptanceIfRequested(_ status: VMOmarchyGuestStatus) {
            guard ProcessInfo.processInfo.environment["RIFTVM_OMARCHY_FOLDER_GRANTS_ACCEPTANCE"] == "1",
                  !folderAcceptanceStarted, VMOmarchyTemporaryPathPolicy.contains(layout.applicationSupportRoot),
                  VMOmarchyIntegrationAssessment.evaluate(status: status, requiredCapabilities: requiredGuestCapabilities).isReady,
                  let client = integrationClient else { return }
            folderAcceptanceStarted = true
            Task { @MainActor in
                do {
                    let removedNames = (ProcessInfo.processInfo.environment["RIFTVM_OMARCHY_REMOVED_FOLDER_NAMES"] ?? "")
                        .split(separator: ",").map(String.init)
                    let observations = try await client.verifyTemporaryFolderGrants(layout: layout, removedGuestNames: removedNames)
                    try FileManager.default.createDirectory(at: layout.diagnostics, withIntermediateDirectories: true)
                    try JSONEncoder().encode(observations).write(
                        to: layout.diagnostics.appending(path: "FolderGrantsAcceptance.json"), options: .atomic)
                    if !removedNames.isEmpty {
                        try JSONSerialization.data(withJSONObject: ["removedGuestNames": removedNames, "absenceVerified": true], options: .sortedKeys)
                            .write(to: layout.diagnostics.appending(path: "FolderGrantsRemovalAcceptance.json"), options: .atomic)
                    }
                } catch {
                    try? Data(error.localizedDescription.utf8).write(
                        to: layout.diagnostics.appending(path: "FolderGrantsAcceptance-error.txt"), options: .atomic)
                }
                requestStop()
            }
        }

        private var sessionAcceptanceStarted = false
        private var restoredSavedSession = false

        @MainActor
        private func runSessionAcceptanceIfRequested(_ status: VMOmarchyGuestStatus) {
            let mode = ProcessInfo.processInfo.environment["RIFTVM_OMARCHY_SESSION_ACCEPTANCE"] ?? ""
            guard ["save", "save-paused", "quit-save", "quit-save-paused", "restore"].contains(mode), !sessionAcceptanceStarted,
                  VMOmarchyTemporaryPathPolicy.contains(layout.applicationSupportRoot),
                  VMOmarchyIntegrationAssessment.evaluate(status: status, requiredCapabilities: requiredGuestCapabilities).isReady else { return }
            sessionAcceptanceStarted = true
            do {
                try FileManager.default.createDirectory(at: layout.diagnostics, withIntermediateDirectories: true)
                let before = layout.diagnostics.appending(path: "SessionAcceptance-before.json")
                if mode == "restore" {
                    let previous = try JSONSerialization.jsonObject(with: Data(contentsOf: before)) as? [String: String]
                    let matches = restoredSavedSession && previous?["bootID"] == status.bootID
                    let observation: [String: Any] = ["restoredSavedSession": restoredSavedSession,
                                                     "guestBootIDPreserved": matches, "bootID": status.bootID,
                                                     "agentAuthenticated": true]
                    try JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys])
                        .write(to: layout.diagnostics.appending(path: "SessionAcceptance-after.json"), options: .atomic)
                    RiftVMLog.info("Omarchy saved-session acceptance: restored=\(restoredSavedSession), bootIDPreserved=\(matches)")
                    requestStop()
                } else {
                    try JSONSerialization.data(withJSONObject: ["bootID": status.bootID, "mode": mode], options: [.sortedKeys])
                        .write(to: before, options: .atomic)
                    let saveAction = {
                        if mode.hasPrefix("quit-") {
                            // Terminate from the AppKit event loop, as a menu
                            // action does. Calling it inside a main-queue Task
                            // blocks that queue while AppKit waits for its reply.
                            RunLoop.main.perform { NSApp.terminate(nil) }
                        } else { self.saveAndStop() }
                    }
                    if mode.hasSuffix("-paused"), let machine {
                        machine.pause { result in
                            DispatchQueue.main.async {
                                switch result {
                                case .success: saveAction()
                                case .failure(let error): self.savedSessionFailed(error)
                                }
                            }
                        }
                    } else { saveAction() }
                }
            } catch {
                RiftVMLog.error("Omarchy saved-session acceptance failed: \(error.localizedDescription)")
            }
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

        private func refreshOwnerProvisioningProgressIfNeeded(_ status: VMOmarchyGuestStatus) {
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
            hostWakeInteractiveTask?.cancel()
        }

        func beginObservingCommands() {
            stopObserver = NotificationCenter.default.addObserver(
                forName: .omarchyRequestStop,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self, notification.object as? UUID == self.sessionID else { return }
                self.requestStop()
            }
            pauseObserver = NotificationCenter.default.addObserver(
                forName: .omarchyRequestPause,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self, notification.object as? UUID == self.sessionID else { return }
                self.pause(automaticResume: false)
            }
            resumeObserver = NotificationCenter.default.addObserver(
                forName: .omarchyRequestResume,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self, notification.object as? UUID == self.sessionID else { return }
                self.resume()
            }
            keyboardPermissionObserver = NotificationCenter.default.addObserver(
                forName: .omarchyRequestKeyboardPermission,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self, notification.object as? UUID == self.sessionID else { return }
                if let keyboardBridge = self.keyboardBridge {
                    keyboardBridge.requestPermission()
                } else {
                    OmarchyFocusedCommandBridge.requestAccessibilityAccess()
                }
            }
            forceStopObserver = NotificationCenter.default.addObserver(
                forName: .omarchyForceStop,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self, notification.object as? UUID == self.sessionID else { return }
                self.forceStop()
            }
        }

        func installKeyboardBridge(for view: VZVirtualMachineView) {
            let bridge = OmarchyFocusedCommandBridge(
                focusProbe: { [weak view] in
                    guard let view, let window = view.window else { return false }
                    guard window.isKeyWindow, NSApp.keyWindow === window, NSApp.modalWindow == nil,
                          window.attachedSheet == nil else { return false }
                    guard let responder = window.firstResponder as? NSView else { return false }
                    return responder === view || responder.isDescendant(of: view)
                },
                stateChanged: keyboardIntegrationChanged,
                redirectedCommandChord: { [weak self] keyCode, flags in
                    guard let client = self?.integrationClient else { return false }
                    Task { @MainActor in
                        do {
                            try await client.injectMacCommandChord(
                                keyCode: UInt16(keyCode),
                                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))
                            )
                        } catch {
                            NSLog(
                                "Omarchy Command chord Agent forwarding failed: %@",
                                error.localizedDescription
                            )
                        }
                    }
                    return true
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
                                    if self.shutdownAfterResume {
                                        self.shutdownAfterResume = false
                                        self.requestStop()
                                        return
                                    }
                                    self.configureAgentClipboard(for: status)
                                    self.configureNotifications(for: status)
                                    self.handleAutomaticRecoveryReady(status)
                                    self.refreshOwnerProvisioningProgressIfNeeded(status)
                                    self.runSessionAcceptanceIfRequested(status)
                                    self.runFolderAcceptanceIfRequested(status)
                                }
                            case .disconnected:
                                Task { @MainActor [weak self] in
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
        private func configureAgentClipboard(for status: VMOmarchyGuestStatus) {
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
                sharedDirectory: layout.shared,
                workspaceID: try? WorkspaceIdentity.load(at: layout.applicationSupportRoot).id,
                isActive: { [weak self] in
                    guard let view = self?.machineView, let window = view.window,
                          window.isKeyWindow, window.isVisible, NSApp.isActive,
                          let responder = window.firstResponder as? NSView else { return false }
                    return responder === view || responder.isDescendant(of: view)
                }
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
        private func stopAgentClipboard() {
            agentClipboardController?.stop()
            agentClipboardController = nil
        }

        @MainActor
        private func configureNotifications(for status: VMOmarchyGuestStatus) {
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
            let controller = OmarchyNotificationController(
                client: integrationClient,
                bootID: status.bootID,
                workspaceID: try? WorkspaceIdentity.load(at: layout.applicationSupportRoot).id,
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
        private func stopNotifications() {
            notificationController?.stop()
            notificationController = nil
            notificationAcceptanceProbeTask?.cancel()
            notificationAcceptanceProbeTask = nil
            expectedAcceptanceNotificationTitle = nil
            if !notificationAcceptanceProbeCompleted {
                notificationAcceptanceProbeStarted = false
            }
        }

        private func startNotificationAcceptanceProbeIfNeeded(
            client: VMOmarchyGuestAgentClient
        ) {
            guard ProcessInfo.processInfo.environment[
                OmarchyWorkspaceConfiguration.acceptanceEnabledKey
            ] == "1", !notificationAcceptanceProbeStarted,
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

        private func startSharedFolderProbeIfNeeded(layout: VMOmarchyWorkspaceLayout) {
            guard ProcessInfo.processInfo.environment[
                OmarchyWorkspaceConfiguration.acceptanceEnabledKey
            ] == "1", !sharedFolderProbePassed, sharedFolderProbeTask == nil,
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

        private func startClipboardProbeIfNeeded(layout: VMOmarchyWorkspaceLayout) {
            guard ProcessInfo.processInfo.environment[
                OmarchyWorkspaceConfiguration.acceptanceEnabledKey
            ] == "1", sharedFolderProbePassed, !clipboardProbePassed,
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

        private func startDynamicDisplayProbeIfNeeded(layout: VMOmarchyWorkspaceLayout) {
            guard ProcessInfo.processInfo.environment[
                OmarchyWorkspaceConfiguration.acceptanceEnabledKey
            ] == "1", clipboardProbePassed, !dynamicDisplayProbePassed,
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
                    self.startAutomaticCommandSpaceProbeIfNeeded(self.latestGuestStatus)
                } catch {
                    NSLog("Omarchy dynamic display round trip failed: %@", error.localizedDescription)
                    self.dynamicDisplayProbeChanged(.failed(error.localizedDescription))
                }
                self.dynamicDisplayProbeTask = nil
            }
        }

        private func startAutomaticPauseResumeProbeIfNeeded() {
            guard ProcessInfo.processInfo.environment[
                OmarchyWorkspaceConfiguration.acceptanceEnabledKey
            ] == "1", dynamicDisplayProbePassed, !automaticPauseResumeProbeStarted else { return }
            automaticPauseResumeProbeStarted = true
            automaticRecoveryAfterResume = true
            pause(automaticResume: true)
        }

        @MainActor
        private func startAutomaticLockProbeIfNeeded() {
            let environment = ProcessInfo.processInfo.environment
            guard environment[OmarchyWorkspaceConfiguration.acceptanceEnabledKey] == "1" else {
                return
            }
            guard OmarchyAcceptanceUnlockCredential(environment: environment) != nil else {
                phaseChanged(.failed(
                    "Acceptance requires a printable ASCII unlock password of 1–128 bytes."
                ))
                return
            }
            guard automaticLockProbe.begin(), let integrationClient,
                  let credential = OmarchyAcceptanceUnlockCredential(environment: environment) else {
                return
            }
            Task { @MainActor [weak self, weak integrationClient] in
                do {
                    guard let self, let integrationClient else { return }
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
                } catch {
                    self?.phaseChanged(.failed("Guest lock probe failed: \(error.localizedDescription)"))
                }
            }
        }

        @MainActor
        private func handleHostPowerEvent(_ event: VMOmarchyHostPowerEvent) {
            OmarchyAcceptanceObservationReporter.reportHostPowerEventIfEnabled(
                event == .willSleep ? .willSleep : .didWake,
                layout: layout
            )
            guard event == .didWake,
                  ProcessInfo.processInfo.environment[
                    OmarchyWorkspaceConfiguration.acceptanceEnabledKey
                  ] == "1" else { return }
            startHostWakeInteractiveProbe()
        }

        @MainActor
        private func startHostWakeInteractiveProbe() {
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
                    self.phaseChanged(.failed(
                        "Host wake interactive probe failed: \(error.localizedDescription)"
                    ))
                }
                self.hostWakeInteractiveTask = nil
            }
        }

        @MainActor
        private func handleAutomaticRecoveryReady(_ status: VMOmarchyGuestStatus) {
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
                        self.phaseChanged(.failed("Guest Agent restart probe failed: \(error.localizedDescription)"))
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
                    phaseChanged(.failed("Guest restart probe could not establish its boot baseline."))
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
        private func recoverGuestRestartInteractiveDesktop() {
            guard let credential = OmarchyAcceptanceUnlockCredential(
                environment: ProcessInfo.processInfo.environment
            ), let integrationClient, keyboardBridge != nil else {
                automaticRecoveryStage = .idle
                phaseChanged(.failed("The Guest restart unlock credential became unavailable."))
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
                    self.phaseChanged(.failed(
                        "Guest restart unlock probe failed: \(error.localizedDescription)"
                    ))
                }
            }
        }

        @MainActor
        private func startAutomaticFullScreenProbeIfNeeded(_ status: VMOmarchyGuestStatus) {
            guard ProcessInfo.processInfo.environment[
                OmarchyWorkspaceConfiguration.acceptanceEnabledKey
            ] == "1", status.desktopSessionActive, !status.provisioningPending,
                  automaticRecoveryStage == .complete,
                  !automaticFullScreenProbeStarted, let machineView,
                  let window = machineView.window else { return }
            automaticFullScreenProbeStarted = true
            let probe = OmarchyFullScreenAcceptanceProbe(
                window: window,
                virtualMachineView: machineView,
                layout: layout
            )
            fullScreenProbe = probe
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak probe] in
                probe?.start()
            }
        }

        @MainActor
        private func startAutomaticCommandSpaceProbeIfNeeded(_ status: VMOmarchyGuestStatus?) {
            guard ProcessInfo.processInfo.environment[
                OmarchyWorkspaceConfiguration.acceptanceEnabledKey
            ] == "1", let status, status.desktopSessionActive, !status.provisioningPending,
                  !automaticCommandSpaceProbeStarted else { return }
            guard keyboardBridge?.runAcceptanceCommandSpaceProbe() == true,
                  let integrationClient else {
                phaseChanged(.failed(
                    "Focused Command+Space acceptance could not reach the Accessibility event tap."
                ))
                return
            }
            automaticCommandSpaceProbeStarted = true
            Task { @MainActor [weak self, weak integrationClient] in
                do {
                    // Command+Space intentionally opens Omarchy Menu. Keep it
                    // visible long enough for the event-tap observation to be
                    // committed, then dismiss it before the lock probe begins.
                    // Otherwise the next acceptance chord and typed secret can
                    // land in the menu's search field instead of the desktop.
                    try await Task.sleep(for: .seconds(1))
                    try await integrationClient?.injectKeyChord(modifiers: [], key: 1)
                    try await Task.sleep(for: .milliseconds(500))
                    self?.startAutomaticLockProbeIfNeeded()
                } catch {
                    self?.phaseChanged(.failed(
                        "Focused Command+Space cleanup failed: \(error.localizedDescription)"
                    ))
                }
            }
        }

        @MainActor
        private func handleAutomaticRecoveryDisconnect() {
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
        }

        func requestStop() {
            guard let machine else { return }
            // Resume the entire integration lifecycle, then wait for a fresh
            // authenticated status before sending shutdown. Resuming only VZ
            // leaves the Agent suspension gate closed and drops the request.
            if machine.state == .paused {
                shutdownAfterResume = true
                resume()
                return
            }
            guard !shutdownAfterResume else { return }
            if let integrationClient, latestGuestStatus?.capabilities.contains("shutdown-v1") == true {
                Task { @MainActor in integrationClient.requestShutdown() }
                return
            }
            guard machine.canRequestStop else {
                phaseChanged(.failed("Omarchy cannot accept a graceful stop request right now."))
                return
            }
            do {
                try machine.requestStop()
            } catch {
                phaseChanged(.failed(error.localizedDescription))
            }
        }

        private func pause(automaticResume: Bool) {
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
                        self.automaticPauseResumeProbeStarted = false
                        self.phaseChanged(.failed(error.localizedDescription))
                    }
                }
            }
        }

        private func resume() {
            guard let machine, machine.canResume else {
                shutdownAfterResume = false
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
                        if self.automaticRecoveryAfterResume {
                            self.automaticRecoveryAfterResume = false
                            self.automaticRecoveryStage = .waitingForPostResumeReady
                        }
                        if self.integrationClient == nil {
                            if self.restoredSavedSession { try? VMOmarchySavedSession.discard(layout: self.layout) }
                            self.startIntegration(layout: self.layout)
                        } else { self.integrationClient?.virtualMachineDidResume() }
                        self.keyboardBridge?.start()
                        self.phaseChanged(.running)
                    case .failure(let error):
                        self.shutdownAfterResume = false
                        self.automaticPauseResumeProbeStarted = false
                        self.phaseChanged(.failed(error.localizedDescription))
                    }
                }
            }
        }

        func forceStop() {
            guard let machine, machine.canStop else {
                phaseChanged(.failed("Omarchy could not be stopped after the graceful shutdown timed out."))
                return
            }
            sessionGeneration += 1
            savingSession = false
            VMOmarchySavedSession.discardPending(layout: layout)
            machine.stop { [weak self, weak machine] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let error {
                        self.phaseChanged(.failed(error.localizedDescription))
                    } else if self.machine === machine {
                        self.stopIntegration()
                        self.machine = nil
                        self.phaseChanged(.stopped)
                    }
                }
            }
        }

        func stopImmediately() {
            sharedFolderProbeTask?.cancel()
            sharedFolderProbeTask = nil
            clipboardProbeTask?.cancel()
            clipboardProbeTask = nil
            dynamicDisplayProbeTask?.cancel()
            dynamicDisplayProbeTask = nil
            keyboardBridge?.stop()
            keyboardBridge = nil
            stopIntegration()
            guard let machine else { return }
            Task { @MainActor in
                // Running windows are retained by the workspace coordinator.
                // Teardown after a completed stop may release ownership.
                if machine.state == .stopped || machine.state == .error {
                    WorkspaceCoordinator.shared.omarchyDidStop(machine)
                }
            }
            self.machine = nil
        }

        func guestDidStop(_ virtualMachine: VZVirtualMachine) {
            Task { @MainActor in
                guard !savingSession else { return }
                WorkspaceCoordinator.shared.omarchyDidStop(virtualMachine)
                stopIntegration()
                machine = nil
                phaseChanged(.stopped)
            }
        }

        func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
            Task { @MainActor in
                WorkspaceCoordinator.shared.omarchyDidStop(virtualMachine)
            }
            stopIntegration()
            phaseChanged(.failed(error.localizedDescription))
        }

        private func stopIntegration() {
            let clipboardController = agentClipboardController
            agentClipboardController = nil
            Task { @MainActor in clipboardController?.stop() }
            let notifications = notificationController
            notificationController = nil
            Task { @MainActor in notifications?.stop() }
            sharedFolderProbeTask?.cancel()
            sharedFolderProbeTask = nil
            sharedFolderProbePassed = false
            clipboardProbeTask?.cancel()
            clipboardProbeTask = nil
            clipboardProbePassed = false
            dynamicDisplayProbeTask?.cancel()
            dynamicDisplayProbeTask = nil
            dynamicDisplayProbePassed = false
            shutdownAfterResume = false
            let client = integrationClient
            integrationClient = nil
            Task { @MainActor in client?.stop() }
        }
    }
}

private extension Notification.Name {
    static let omarchyRequestStop = Notification.Name("RiftVMOmarchy.requestStop")
    static let omarchyRequestPause = Notification.Name("RiftVMOmarchy.requestPause")
    static let omarchyRequestResume = Notification.Name("RiftVMOmarchy.requestResume")
    static let omarchyRequestKeyboardPermission = Notification.Name("RiftVMOmarchy.requestKeyboardPermission")
    static let omarchyForceStop = Notification.Name("RiftVMOmarchy.forceStop")
}


private struct OmarchyFolderPermissionsView: View {
    let workspace: URL
    let canEdit: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var grants: [VMOmarchyFolderGrant] = []
    @State private var errorMessage: String?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Folder Permissions").font(.title2.bold())
            Text("Only folders you add here are shared with this workspace. Removing permission leaves the original files on your Mac.")
            if !canEdit {
                Text("Shut down this workspace to change permissions.").foregroundStyle(.secondary)
            }
            List {
                if grants.isEmpty { Text("No host folders shared").foregroundStyle(.secondary) }
                ForEach(grants) { grant in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(grant.directory.path).textSelection(.enabled)
                        Text("~/Mac/\(grant.guestName)").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Picker("Access", selection: Binding(get: { grant.readOnly }, set: { value in
                                var changed = grants
                                if let index = changed.firstIndex(where: { $0.id == grant.id }) {
                                    changed[index].readOnly = value
                                    save(changed)
                                }
                            })) {
                                Text("Read Only").tag(true)
                                Text("Read & Write").tag(false)
                            }
                            Button("Remove", role: .destructive) { save(grants.filter { $0.id != grant.id }) }
                        }.disabled(!canEdit || !loaded)
                    }.padding(.vertical, 6)
                }
            }.frame(minHeight: 220)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            HStack {
                Button("Add Folder…", action: addFolder).disabled(!canEdit || !loaded)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 600)
        .task {
            do { grants = try VMOmarchyFolderGrant.load(at: workspace); loaded = true }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func save(_ changed: [VMOmarchyFolderGrant]) {
        guard canEdit, let lease = VMRunningRegistry.shared.acquire(rootPath: workspace, phase: .maintaining) else {
            errorMessage = "This workspace is busy. Shut it down before changing folder permissions."
            return
        }
        defer { VMRunningRegistry.shared.release(lease) }
        do {
            try VMOmarchyFolderGrant.save(changed, at: workspace)
            grants = changed
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Share Read Only"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let grant = VMOmarchyFolderGrant(directory: url)
        let alert = NSAlert()
        alert.messageText = "Share this folder with Omarchy?"
        alert.informativeText = "The guest will be able to read every file in \(grant.directory.path) and its subfolders. Check that it contains no passwords, private keys, or other files you do not want to share. You can enable write access separately."
        alert.addButton(withTitle: "Share Read Only")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        save(grants + [grant])
    }
}
