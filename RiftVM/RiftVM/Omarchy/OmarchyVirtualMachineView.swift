import AVFoundation
import UserNotifications
import SwiftUI
import UniformTypeIdentifiers
import Virtualization

private let omarchyMetadataQueue = DispatchQueue(label: "com.riftvm.app.omarchy.metadata")

enum OmarchyDesktopInputPolicy {
    /// Custom VirGL has no native VZ display to receive keyboard events.
    /// Use authenticated uinput at the login screen as well as the desktop;
    /// the native owner form is protected separately by hostOverlayVisible.
    static func usesGuestAgent(status: VMOmarchyGuestStatus) -> Bool {
        guard !status.provisioningPending,
              status.capabilities.contains("input-uinput-v1") else { return false }
        return !status.desktopSessionActive || status.capabilities.contains("desktop-input-v1")
    }
}

struct OmarchyVirtualMachineView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    let layout: VMOmarchyWorkspaceLayout
    let profile: VMOmarchyProfile
    /// The single window shows the one Omarchy; this action removes it from
    /// inside the window, returning the window to preparation.
    let workspace: ActiveWorkspaceRecord
    let actions: WorkspaceWindowActions
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
    @State private var prepareUpdateAfterStop = false
    @State private var pendingRestore: VMOmarchyRecoveryPoint?
    @State private var factoryChannel: FactoryChannelViewState = .idle
    @State private var importingFiles = false
    /// The Mac folders shared with Omarchy, loaded when the window appears.
    @State private var sharedFolders: VMOmarchySharedFolderSettings?
    /// How the running session lays them out in Omarchy.
    @State private var sharePlan: VMOmarchySharePlan?
    @State private var showsSharedFolders = false
    /// Shown briefly each time Omarchy starts: while its window has focus,
    /// Command shortcuts belong to Omarchy, so say how to get back to macOS.
    @State private var showsReleaseHint = false
    @State private var notice: UserNotice?
    @State private var graphicsIssue: String?
    @State private var acceptanceFailure: String?
    @State private var recordedIntegrationSignature = ""
    @State private var sharedFolderProbe: VMOmarchySharedFolderProbeState = .notRun
    @State private var clipboardProbe: OmarchyClipboardProbeState = .notRun
    @State private var dynamicDisplayProbe: OmarchyDynamicDisplayProbeState = .notRun
    @State private var ownerSetupForm = OmarchyOwnerSetupForm()
    @State private var ownerSetupPhase: OmarchyOwnerSetupPhase = .editing
    @State private var ownerProvisioningSubmission: OmarchyOwnerProvisioningSubmission?
    @State private var automaticOwnerProvisioningStarted = false
    @State private var ownerProvisioningDetail: String?
    @State private var liveMachine: VMLiveMachine?
    @State private var isShowingCloseConfirmation = false
    @State private var closesWhenStopped = false
    @State private var removesWhenStopped = false
    @State private var isShowingRemovalConfirmation = false
    @State private var showsSnapshots = false
    /// Bumped when the guest starts running, so the window takes the screen for
    /// the desktop and stays a normal window for the preparation and stopped
    /// screens.
    @State private var fullScreenRequest = 0
    /// The stopped screen's hardware line. It comes from the machine's metadata
    /// on disk, so it is read when that can have changed, not on every render.
    @State private var hardwareSummary: HardwareSummary?

    private var phase: Phase { lifecycle.phase }

    var body: some View {
        machineLayer
        .background(.black)
        .onAppear {
            OmarchyReleaseReadinessReporter.reportWhenReady(
                workspaceManager: VMOmarchyWorkspaceManager(layout: layout)
            )
            registerLiveMachine()
        }
        .onDisappear { unregisterLiveMachine() }
        .onChange(of: lifecycle.phase) { _, _ in
            syncLiveMachine()
            closeWindowOnceStopped()
        }
        .background {
            VMWindowCloseObserver(
                rootPath: layout.applicationSupportRoot,
                shouldConfirm: {
                    phase.needsCloseConfirmation(isTerminating: VMLiveMachineCenter.shared.isTerminating)
                },
                shouldBlock: {
                    phase.blocksWindowClose
                },
                onCloseAttempt: {
                    isShowingCloseConfirmation = true
                },
                appliesGuestWindowChrome: false,
                fullScreenRequest: fullScreenRequest
            )
        }
        .modifier(WorkspaceWindowPresentations(
            workspace: workspace,
            showsSnapshots: $showsSnapshots,
            isShowingRemovalConfirmation: $isShowingRemovalConfirmation,
            remove: removeWorkspace,
            snapshotsDismissed: refreshHardwareSummary
        ))
        .alert("Stop Omarchy and Close?", isPresented: $isShowingCloseConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Stop Omarchy and Close") {
                closesWhenStopped = true
                handle(.stopRequested)
            }
        } message: {
            Text("RiftVM will ask Omarchy to shut down, force stop it only if it does not respond, and then close this window. Linux guests cannot save machine state, so the next start is a full boot.")
        }
        .dropDestination(for: URL.self) { urls, _ in
            importFiles(urls)
            return !urls.isEmpty
        }
        .toolbar { workspaceToolbar }
        .safeAreaInset(edge: .top) { topBanners }
        .onChange(of: sessionID) { _, _ in acceptanceFailure = nil; graphicsIssue = nil }
        .onDisappear {
            stopTimeoutTask?.cancel()
            stopTimeoutTask = nil
        }
        .onAppear {
            refreshRecoveryPoints()
            refreshHardwareSummary()
            if sharedFolders == nil {
                sharedFolders = VMOmarchySharedFolderStore.load(layout: layout)
            }
        }
        .sheet(isPresented: $showsSharedFolders) {
            OmarchySharedFoldersView(
                settings: sharedFolders ?? VMOmarchySharedFolderStore.load(layout: layout),
                plan: phase == .running ? sharePlan : nil,
                machineRoot: layout.applicationSupportRoot,
                save: saveSharedFolders,
                restart: phase == .running ? { handle(.restartRequested) } : nil
            )
        }
        .confirmationDialog(
            restoreConfirmationTitle,
            isPresented: restoreConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Restore Omarchy", role: .destructive) {
                guard let point = pendingRestore else { return }
                pendingRestore = nil
                restore(point)
            }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: {
            Text("Changes made inside Omarchy since this recovery point will be replaced. Create a backup first if you need to keep them. Omarchy must remain stopped until recovery finishes.")
        }
        .alert(item: $notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    /// The guest canvas plus the stopped/paused/failed overlay and the owner
    /// setup form. Kept out of `body` so the type checker does not have to solve
    /// the representable's closure list together with every modifier.
    private var machineLayer: some View {
        ZStack {
            OmarchyVirtualMachineRepresentable(
                layout: layout,
                profile: profile,
                clipboardEnabled: clipboardEnabled,
                notificationsEnabled: notificationsEnabled,
                microphoneEnabled: microphoneEnabled,
                hostOverlayVisible: ownerSetupAvailable || phase != .running,
                sharedFolders: sharedFolders,
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
                acceptanceFailureChanged: { acceptanceFailure = $0 },
                graphicsIssueChanged: { graphicsIssue = $0 },
                sharePlanChanged: { sharePlan = $0 }
            )
            .id(sessionID)
            
            if phase != .running {
                statusOverlay
            }
            if showsReleaseHint, phase == .running, !ownerSetupAvailable {
                VStack {
                    Label("Command shortcuts go to Omarchy. Press Control-Option to free the pointer, then use the Dock or menu bar to switch apps.", systemImage: "keyboard")
                        .font(.callout)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 14)
                    Spacer()
                }
                .transition(.opacity)
                .allowsHitTesting(false)
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
    }

    /// Status banners above the guest canvas: a graphics problem, an acceptance
    /// workspace, or the Accessibility permission the Command shortcuts need.
    /// Kept out of `body` for the type checker.
    @ViewBuilder
    private var topBanners: some View {
        if let graphicsIssue {
            Label(graphicsIssue, systemImage: "display.trianglebadge.exclamationmark")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.orange.opacity(0.18))
        }
        if OmarchyWorkspaceConfiguration.isAcceptanceWorkspace(layout) {
            VStack(alignment: .leading, spacing: 4) {
                Label(acceptanceFailure == nil ? "Automated acceptance testing" : "Acceptance test failed", systemImage: acceptanceFailure == nil ? "testtube.2" : "exclamationmark.triangle")
                    .font(.headline)
                Text(acceptanceFailure ?? "This temporary copy of Omarchy may type, lock, and restart automatically. Keep this window focused while testing.")
                if acceptanceFailure != nil {
                    Text("The test did not pass. The virtual machine remains available; use its normal controls to continue or stop it.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.orange.opacity(0.18))
        }
        if keyboardIntegration != .enabled {
            HStack {
                if keyboardIntegration == .requestingAccessibility {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Waiting for Accessibility permission")
                    Text("Turn on RiftVM in System Settings, then return here. If it is already on, remove its old entry and add the current RiftVM app again.")
                } else if keyboardIntegration == .eventTapUnavailable {
                    Text("Access is allowed, but shortcut capture could not start. Retry, or quit and reopen RiftVM.")
                } else {
                    Text("Allow Accessibility access so Command shortcuts stay inside Omarchy.")
                }
                Spacer()
                Button(keyboardIntegration == .requestingAccessibility ? "Open System Settings" : keyboardIntegration == .eventTapUnavailable ? "Retry" : "Enable") {
                    NotificationCenter.default.post(name: .omarchyRequestKeyboardPermission, object: sessionID)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.orange.opacity(0.18))
        }
    }

    /// The recovery-point confirmation is built from explicit values: a large
    /// interpolation inside the window body is what tips the type checker over.
    private var restoreConfirmationTitle: String {
        let name = pendingRestore?.name ?? "this recovery point"
        return "Restore \(name)?"
    }

    private var restoreConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingRestore != nil },
            set: { if !$0 { pendingRestore = nil } }
        )
    }

    /// Every control the window offers. Extracted from `body` so the type
    /// checker does not have to solve the toolbar together with the modifiers.
    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            workspaceMenu
            graphicsMenu
            integrationMenu
            updatesMenu
            recoveryMenu
            Button("Open Shared Folder", systemImage: "folder") {
                if let folder = exchangeFolder {
                    NSWorkspace.shared.open(folder.path)
                }
            }
            .disabled(exchangeFolder == nil)
            Button("Shared Folders…", systemImage: "folder.badge.gearshape") {
                showsSharedFolders = true
            }
            Button("Import Files", systemImage: "square.and.arrow.down") {
                chooseFilesToImport()
            }
            .disabled(importingFiles || exchangeFolder == nil)
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

    /// The backend in use and any graphics problem. There is nothing to choose:
    /// Custom VirGL is the only backend RiftVM runs.
    private var graphicsMenu: some View {
        Menu {
            Text(VMGraphicsBackendKind.customVirGL.displayName)
            if let graphicsIssue { Text(graphicsIssue) }
            Text("RiftVM renders the guest desktop through its own VirGL device.")
        } label: { Label("Graphics", systemImage: "display") }
    }

    /// Snapshots, display settings, and removal for Omarchy. Extracted from the
    /// toolbar so the type checker does not have to solve it together with every
    /// other toolbar item.
    private var workspaceMenu: some View {
        Menu {
            Button("Snapshots…", systemImage: "camera.on.rectangle") { showsSnapshots = true }
            Button("Show in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([workspace.bundleURL])
            }
            Button("Save Diagnostics…", systemImage: "doc.text.magnifyingglass") {
                // The graphics, cursor and input decisions of this session, for a
                // bug report. Cancelling the panel is not an error.
                if let url = try? RiftVMDiagnostics.export() {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            Divider()
            Button("Remove Omarchy…", systemImage: "trash", role: .destructive) {
                isShowingRemovalConfirmation = true
            }
        } label: { Label("Omarchy", systemImage: "square.grid.2x2") }
        .help("Snapshots, display settings, and removal for Omarchy")
    }

    @ViewBuilder
    private var integrationMenu: some View {
        let assessment = integrationAssessment
        let integrationReady = assessment?.isReady == true
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
                if let assessment {
                    if assessment.provisioningPending {
                        Text("Complete Omarchy owner setup")
                    } else if !assessment.desktopSessionActive {
                        Text("Waiting for Omarchy desktop")
                    } else if !assessment.missingCapabilities.isEmpty {
                        Text("Missing: \(assessment.missingCapabilities.joined(separator: ", "))")
                    } else {
                        Text("Omarchy desktop integration ready")
                    }
                }
                if !status.addresses.isEmpty { Text(status.addresses.joined(separator: ", ")) }
                if status.capabilities.contains("shared-folders-v1") {
                    Text("Shared folder mounted at /mnt/mac")
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
                Text("Control-Option frees the pointer; Command shortcuts go to Omarchy")
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
                        Label("\(point.name) · \(point.createdAt.formatted(date: .abbreviated, time: .shortened))", systemImage: point.isProtected ? "lock.shield" : "clock.arrow.circlepath")
                    }
                    .disabled(phase != .stopped || recoveryOperation.isWorking)
                }
            }
        } label: {
            Label("Recovery", systemImage: recoveryOperation.isFailed ? "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90" : "clock.arrow.circlepath")
        }
        .help("Create or restore protected Omarchy recovery points")
    }

    /// The assessment of the connected Agent, made once for the whole menu.
    private var integrationAssessment: VMOmarchyIntegrationAssessment? {
        guard case .ready(let status) = integration else { return nil }
        return VMOmarchyIntegrationAssessment.evaluate(
            status: status,
            requiredCapabilities: profile.requiredGuestCapabilities
        )
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
            message: "Allow RiftVM Omarchy in System Settings → Notifications, then enable mirroring again."
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
        guard phase == .running else { return false }
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
            Button("Download RiftVM Update", systemImage: "arrow.down.app") {
                NSWorkspace.shared.open(URL(string: "https://github.com/riftvm/riftvm/releases/latest")!)
            }
            Text("Homebrew users: brew upgrade --cask riftvm")
            Divider()
            Button("Prepare for Omarchy Update…", systemImage: "lock.shield") {
                if phase == .stopped {
                    createProtectedBackup(forUpdate: true)
                } else {
                    prepareUpdateAfterStop = true
                    handle(.stopRequested)
                }
            }
            .disabled(recoveryOperation.isWorking || !(phase == .running || phase == .paused || phase == .stopped))
            Text("Stops Omarchy and creates a protected recovery point before you update inside the guest.")
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
                Text("This copy of Omarchy has no recorded factory version")
                Text("Signed channel factory: \(available)")
                Text("Factory images are only used for new installs and recovery.")
                Button("Check Again") { checkFactoryChannel() }
            case .different(let installed, let available):
                Text("Installed factory: \(installed)")
                Text("Signed channel factory: \(available)")
                Text("Remove Omarchy to create a fresh one from the channel image.")
                Button("Check Again") { checkFactoryChannel() }
            case .failed(let message):
                Text(message)
                Button("Try Again") { checkFactoryChannel() }
            }
            Divider()
        } label: {
            Label("Updates", systemImage: factoryChannel.needsAttention ? "arrow.down.circle.fill" : "arrow.triangle.2.circlepath")
        }
        .help("App, factory-image, and guest update status")
    }

    private func checkFactoryChannel() {
        guard factoryChannel != .checking else { return }
        let publicKeys = FactoryTrustConfiguration.publicKeys()
        guard !publicKeys.isEmpty else {
            factoryChannel = .failed("This build has no trusted factory signing key.")
            return
        }
        let workspace = VMOmarchyWorkspaceManager(layout: layout)
        let installedVersion = try? workspace.metadata().factoryImageVersion
        let installer = VMOmarchyFactoryInstaller(
            profile: profile,
            cacheDirectory: layout.cache,
            publicKeys: publicKeys,
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
              OmarchyWorkspaceConfiguration.isAcceptanceWorkspace(layout),
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
                integrationState: integration,
                sharedDirectory: exchangeFolder?.path
            )
            try report.encoded().write(to: destination, options: .atomic)
            notice = UserNotice(title: "Diagnostics Exported", message: destination.lastPathComponent)
        } catch {
            notice = UserNotice(title: "Diagnostics Export Failed", message: error.localizedDescription)
        }
    }

    /// The folder Open Shared Folder and Import Files use: the first writable
    /// one Omarchy sees in this session, or the saved list's while stopped.
    private var exchangeFolder: VMOmarchySharedFolder? {
        if phase == .running, let sharePlan {
            return sharePlan.entries.first { !$0.folder.readOnly }?.folder
        }
        return sharedFolders?.primaryFolder
    }

    /// Saves the folder list. Omarchy sees it from its next start.
    private func saveSharedFolders(_ settings: VMOmarchySharedFolderSettings) {
        do {
            try VMOmarchySharedFolderStore.save(settings, layout: layout)
            sharedFolders = settings
        } catch {
            notice = UserNotice(title: "Shared Folders Not Saved", message: error.localizedDescription)
        }
    }

    private func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty, !importingFiles else { return }
        importingFiles = true
        guard let folder = exchangeFolder else { return }
        let guestPath = sharePlan?.guestPath(for: folder) ?? "the shared folder"
        let importer = VMOmarchySharedFolderImporter(layout: layout, destination: folder.path)
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
                        message: "Imported \(files.count) file(s): \(names). Open \(guestPath) in Omarchy."
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
                Text(workspaceHardwareSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(NSString(string: layout.applicationSupportRoot.path(percentEncoded: false)).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                if case .working(let message) = recoveryOperation {
                    ProgressView(message)
                }
                if case .failed(let message) = recoveryOperation {
                    Text(message).foregroundStyle(.secondary)
                    Button("Dismiss Recovery Error") { recoveryOperation = .idle }
                }
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
                .padding(30)
                .background(.regularMaterial)
                Button("Stop and Enable Recovery", systemImage: "stop.fill") {
                    handle(.stopRequested)
                }
                .buttonStyle(.borderedProminent)
                Text("Once stopped, retry Start Omarchy or restore a recovery point from Recovery.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func handlePhaseChange(_ phase: Phase) {
        switch phase {
        case .running:
            handle(.machineStarted)
            // The guest keeps one display mode — the screen the window is on — so
            // full screen is what shows the running desktop at native size. The
            // preparation and stopped screens stay normal windows. The release
            // readiness probe measures a window and never starts a guest, but it
            // opts out explicitly as well.
            if ProcessInfo.processInfo.environment["RIFTVM_GUI_READY_FILE"] == nil {
                fullScreenRequest += 1
            }
            withAnimation { showsReleaseHint = true }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                withAnimation { showsReleaseHint = false }
            }
        case .paused: handle(.machinePaused)
        case .stopped:
            handle(.machineStopped)
            refreshRecoveryPoints()
            refreshHardwareSummary()
            if prepareUpdateAfterStop {
                prepareUpdateAfterStop = false
                createProtectedBackup(forUpdate: true)
            }
        case .failed(let message):
            prepareUpdateAfterStop = false
            handle(.machineFailed(message))
        case .starting, .pausing, .resuming, .stopping: break
        }
    }

    private func refreshRecoveryPoints() {
        recoveryPoints = VMOmarchyRecoveryManager(
            workspaceManager: VMOmarchyWorkspaceManager(layout: layout)
        ).recoveryPoints()
    }

    private func createProtectedBackup(forUpdate: Bool = false) {
        guard phase == .stopped, !recoveryOperation.isWorking else { return }
        recoveryOperation = .working("Creating protected backup…")
        let manager = VMOmarchyRecoveryManager(
            workspaceManager: VMOmarchyWorkspaceManager(layout: layout)
        )
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try manager.createProtectedBackup(name: forUpdate ? "Before Omarchy update" : "Protected backup") }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    recoveryOperation = .idle
                    refreshRecoveryPoints()
                    refreshHardwareSummary()
                    notice = UserNotice(title: "Recovery Point Created", message: forUpdate
                        ? "Start Omarchy, then choose Update in the Omarchy menu. If the update fails, stop Omarchy and choose Before Omarchy update in Recovery. Keep this recovery point until you have checked the updated system."
                        : "Your recovery point is ready. To restore it later, stop Omarchy and select it in Recovery.")
                case .failure(let error):
                    recoveryOperation = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func restore(_ point: VMOmarchyRecoveryPoint) {
        guard phase == .stopped, !recoveryOperation.isWorking else { return }
        recoveryOperation = .working("Restoring \(point.name)…")
        let manager = VMOmarchyRecoveryManager(
            workspaceManager: VMOmarchyWorkspaceManager(layout: layout)
        )
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try manager.restore(id: point.id) }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    recoveryOperation = .idle
                    refreshRecoveryPoints()
                    refreshHardwareSummary()
                    factoryChannel = .idle
                    notice = UserNotice(title: "Recovery Complete", message: "Omarchy has been restored. Choose Start Omarchy to use it.")
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
            case .scheduleForceStop:
                stopTimeoutTask?.cancel()
                stopTimeoutTask = Task {
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled else { return }
                    await MainActor.run { handle(.stopTimedOut) }
                }
            case .cancelForceStop:
                stopTimeoutTask?.cancel()
                stopTimeoutTask = nil
            case .forceStop:
                NotificationCenter.default.post(name: .omarchyForceStop, object: sessionID)
            }
        }
    }

    // MARK: - App-level status

    /// Publishes this workspace to the menu bar item and the quit path. The
    /// entry lives only while the window does: closing the window already stops
    /// the guest through the view-teardown path.
    private func registerLiveMachine() {
        let machine = VMLiveMachine(rootPath: layout.applicationSupportRoot, name: workspaceName)
        machine.pauseAction = { handle(.pauseRequested) }
        machine.resumeAction = { handle(.resumeRequested) }
        machine.stopAction = { handle(.stopRequested) }
        machine.forceStopAction = { handle(.stopTimedOut) }
        liveMachine = machine
        VMLiveMachineCenter.shared.register(machine)
        syncLiveMachine()
    }

    private func unregisterLiveMachine() {
        guard let liveMachine else { return }
        VMLiveMachineCenter.shared.unregister(liveMachine)
        self.liveMachine = nil
    }

    /// The user chose "Stop Omarchy and Close": wait for the guest to stop, then
    /// close the window the close attempt left open. Removing the workspace uses
    /// the same wait, so the disk is never pulled out from under a live guest.
    private func closeWindowOnceStopped() {
        guard phase.hasStopped else { return }
        if removesWhenStopped {
            removesWhenStopped = false
            actions.remove()
            return
        }
        guard closesWhenStopped else { return }
        closesWhenStopped = false
        dismissWindow(id: "workspace")
    }

    private func removeWorkspace() {
        switch phase {
        case .running, .paused, .starting, .pausing, .resuming:
            removesWhenStopped = true
            handle(.stopRequested)
        case .stopping, .stopped, .failed:
            actions.remove()
        }
    }

    private var workspaceHardwareSummary: String {
        if let hardwareSummary, hardwareSummary.root == layout.applicationSupportRoot {
            return hardwareSummary.text
        }
        return readWorkspaceHardwareSummary()
    }

    /// Reads the metadata again: when the window appears, when Omarchy stops,
    /// and after a backup, a restore, or the snapshots sheet.
    private func refreshHardwareSummary() {
        hardwareSummary = HardwareSummary(
            root: layout.applicationSupportRoot,
            text: readWorkspaceHardwareSummary()
        )
    }

    private func readWorkspaceHardwareSummary() -> String {
        let resources = profile.resources(
            forHostMemory: ProcessInfo.processInfo.physicalMemory,
            activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount
        )
        let metadata = try? VMOmarchyWorkspaceManager(layout: layout).metadata()
        let memory = ByteCountFormatter.string(
            fromByteCount: Int64(clamping: metadata?.memoryBytes ?? resources.memoryBytes),
            countStyle: .memory
        )
        let disk = ByteCountFormatter.string(fromByteCount: Int64(clamping: profile.diskCapacityBytes), countStyle: .file)
        return "\(metadata?.cpuCount ?? resources.cpuCount) CPU · \(memory) memory · \(disk) disk"
    }

    private func syncLiveMachine() {
        guard let liveMachine else { return }
        liveMachine.status = phase.liveStatusTitle
        liveMachine.canPause = phase == .running
        liveMachine.canResume = phase == .paused
        liveMachine.canStop = phase == .running || phase == .paused
        // Linux guests cannot save machine state, so quitting shuts them down
        // instead of saving and stopping.
        liveMachine.canSaveAndStop = false
        if phase.hasStopped {
            liveMachine.hasStopped = true
            unregisterLiveMachine()
        }
    }

    private var workspaceName: String { workspace.name }

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

    private struct HardwareSummary {
        /// The machine the text was read for.
        let root: URL
        let text: String
    }

    private struct UserNotice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }
}

/// Sheets and confirmations the one workspace window can present. They live in
/// their own modifier so the window body stays inside the type-checker budget.
private struct WorkspaceWindowPresentations: ViewModifier {
    let workspace: ActiveWorkspaceRecord
    @Binding var showsSnapshots: Bool
    @Binding var isShowingRemovalConfirmation: Bool
    let remove: () -> Void
    /// A snapshot restore replaces the machine's files, metadata included.
    let snapshotsDismissed: () -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showsSnapshots, onDismiss: snapshotsDismissed) {
                MachineSnapshotsView(machineName: workspace.name, rootPath: workspace.bundleURL)
                    .frame(minWidth: 820, minHeight: 620)
            }
            .confirmationDialog(
                "Move Omarchy to the Trash?",
                isPresented: $isShowingRemovalConfirmation,
                titleVisibility: .visible
            ) {
                Button("Move to Trash", role: .destructive) { remove() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Omarchy and its disk go to the Trash. RiftVM Shared — the folder you and Omarchy exchange files through — stays on your Mac. RiftVM then starts over with Prepare Omarchy.")
            }
    }
}

extension OmarchyVirtualMachineView.Phase {
    /// Status line the menu bar item shows for this workspace.
    var liveStatusTitle: String {
        switch self {
        case .starting: "Starting"
        case .running: "Running"
        case .pausing: "Pausing"
        case .paused: "Paused"
        case .resuming: "Resuming"
        case .stopping: "Stopping"
        case .stopped: "Stopped"
        case .failed: "Error"
        }
    }

    /// The guest is no longer running, so the live-machine entry can retire.
    var hasStopped: Bool {
        switch self {
        case .stopped, .failed: true
        default: false
        }
    }

    /// Closing the window while the guest runs asks first. Quitting drains the
    /// machines through its own panel, so it never asks here.
    func needsCloseConfirmation(isTerminating: Bool) -> Bool {
        guard !isTerminating else { return false }
        return self == .running || self == .paused
    }

    /// A close attempt during a stop is ignored until the guest finishes, so the
    /// window keeps showing the stop progress instead of vanishing mid-shutdown.
    var blocksWindowClose: Bool {
        self == .pausing || self == .stopping
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
