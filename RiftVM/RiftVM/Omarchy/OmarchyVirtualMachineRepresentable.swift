import SwiftUI
import Virtualization

struct OmarchyVirtualMachineRepresentable: NSViewRepresentable {
    let layout: VMOmarchyWorkspaceLayout
    let profile: VMOmarchyProfile
    let clipboardEnabled: Bool
    let notificationsEnabled: Bool
    let microphoneEnabled: Bool
    let hostOverlayVisible: Bool
    let sharedFolders: VMOmarchySharedFolderSettings?
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
    let acceptanceFailureChanged: (String) -> Void
    let graphicsIssueChanged: (String?) -> Void
    let sharePlanChanged: (VMOmarchySharePlan) -> Void

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
            acceptanceFailureChanged: acceptanceFailureChanged,
            graphicsIssueChanged: graphicsIssueChanged,
            sharePlanChanged: sharePlanChanged
        )
    }

    func makeNSView(context: Context) -> VZVirtualMachineView {
        context.coordinator.runLease = VMRunningRegistry.shared.acquire(rootPath: layout.applicationSupportRoot)
        let metadata = Result { try VMOmarchyWorkspaceManager(layout: layout).metadata() }
        let view = OmarchyVirtualMachineInputView()
        view.capturesSystemKeys = true
        view.setHostOverlayVisible(hostOverlayVisible)
        context.coordinator.machineView = view
        // Stop/recovery must remain available even when graphics or VM
        // configuration fails before a VZVirtualMachine can be constructed.
        context.coordinator.beginObservingCommands()
        do {
            guard context.coordinator.runLease != nil else {
                throw VMOSError.regularFailure("Omarchy is already running or its settings are being changed.")
            }
            _ = try metadata.get()
            // Boot straight into the mode the session will keep: the screen the
            // window opens full screen on. The host never publishes another mode
            // while the session runs, because a mode change rebuilds every guest
            // output, which is what flickers the desktop and leaves its
            // background layer without a committed buffer.
            let canvas = VMDisplayGeometry.guestResolution(
                for: NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1200)
            )
            let backend: any VMGraphicsBackend = try VMCustomVirGLGraphicsBackend(
                guestSize: CGSize(width: CGFloat(canvas.width), height: CGFloat(canvas.height)),
                displayView: view
            )
            context.coordinator.graphicsBackend = backend
            backend.setRuntimeIssueHandler(context.coordinator.graphicsIssueChanged)
            view.displayConfigurationChanged = { [weak coordinator = context.coordinator] in coordinator?.graphicsBackend?.refreshDisplayConfiguration() }
            let sharedFolders = sharedFolders ?? VMOmarchySharedFolderStore.load(layout: layout)
            VMOmarchySharedFolderStore.prepareFolders(sharedFolders)
            let sharePlan = context.coordinator.adoptSharedFolders(sharedFolders)
            let configuration = try VMOmarchyVirtualMachineBuilder.makeConfiguration(
                layout: layout,
                profile: profile,
                customGraphicsDevices: (backend as? VMCustomVirGLGraphicsBackend)?.deviceConfigurations ?? [],
                microphoneEnabled: microphoneEnabled,
                sharePlan: sharePlan
            )
            guard let lease = context.coordinator.runLease,
                  let assessment = VMRunningRegistry.shared.configureResources(lease,
                    cpuCount: configuration.cpuCount, memoryBytes: configuration.memorySize) else {
                throw VMOSError.regularFailure("Could not reserve resources for Omarchy.")
            }
            guard assessment.allowed else {
                throw VMOSError.regularFailure(assessment.denialReason ?? "Insufficient host resources.")
            }
            let machine = VZVirtualMachine(configuration: configuration)
            machine.delegate = context.coordinator
            context.coordinator.machine = machine
            OmarchyApplicationTerminationController.shared.register(machine)
            backend.bind(virtualMachine: machine)
            context.coordinator.installKeyboardBridge(for: view)
            context.coordinator.start(
                machine,
                in: view,
                profile: profile,
                microphoneEnabled: microphoneEnabled,
                permitsEFIVariableStoreRecovery: true
            )
        } catch {
            context.coordinator.graphicsBackend?.shutdown()
            context.coordinator.graphicsBackend = nil
            DispatchQueue.main.async {
                context.coordinator.phaseChanged(.failed(error.localizedDescription))
            }
        }
        return view
    }

    func updateNSView(_ nsView: VZVirtualMachineView, context: Context) {
        (nsView as? OmarchyVirtualMachineInputView)?.setHostOverlayVisible(hostOverlayVisible)
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
}
