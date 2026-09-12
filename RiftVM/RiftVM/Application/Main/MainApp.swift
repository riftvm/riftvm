//
//  RiftVMApp.swift
//  RiftVM
//
//  Created by everettjf on 2022/6/24.
//

import SwiftUI
import CoreGraphics

@main
struct MainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    
#if arch(arm64)
    var body: some Scene {
        Window("RiftVM Control Center", id: "control-center") {
            if HeadlessLaunchConfiguration.current == nil {
                WorkspaceControlCenterView()
                    .frame(minWidth: 800, minHeight: 600)
            } else {
                EmptyView()
            }
        }
        .defaultPosition(.center)
        .defaultSize(width: 1080, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommunityCommands()
        }

        // Persistent status for the running machines, and the way back to the
        // app once every workspace window is closed.
        MenuBarExtra {
            VMWorkspaceMenu()
        } label: {
            VMWorkspaceMenuLabel()
        }
        .menuBarExtraStyle(.menu)

        WindowGroup("Workspace", id: "workspace", for: UUID.self) { $workspaceID in
            if let workspaceID {
                WorkspaceWindowView(workspaceID: workspaceID)
            } else {
                ContentUnavailableView("Workspace unavailable", systemImage: "exclamationmark.triangle")
            }
        }
        .defaultPosition(.center)
        .defaultSize(width: 1024, height: 768)
        .windowToolbarStyle(.unifiedCompact)
        .restorationBehavior(.disabled)
        
        WindowGroup("Create Workspace", id: "create-machine-guide", for: RiftWorkspaceKind.self) { $initialKind in
            VMCreateStepperGuideView(initialKind: initialKind)
        }
        .defaultPosition(.center)
        .defaultSize(width: 760, height: 650)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        
        WindowGroup("Creating Workspace", id: "workspace-creation", for: UUID.self) { $sessionID in
            if let session = WorkspaceCreationStore.shared.sessions.first(where: { $0.id == sessionID }) {
                WorkspaceCreationView(session: session)
            } else {
                ContentUnavailableView("Creation Finished", systemImage: "checkmark.circle", description: Text("Find your workspace in the control center."))
            }
        }
        .defaultSize(width: 760, height: 650)
        .restorationBehavior(.disabled)

        WindowGroup(id: "start-machine", for: URL.self) { $modelRootPath in
            if let rootPath = modelRootPath {
                VMOSMainVirtualMachineView(rootPath: rootPath, recoveryMode: false)
            } else {
                Text("Invalid , just close")
            }
        }
        .defaultPosition(.center)
        .defaultSize(width: 1024, height: 768)
        .windowToolbarStyle(.unifiedCompact)
        .restorationBehavior(.disabled)
        .commands {
            ControlCenterCommands()
        }
        
        
        WindowGroup(id: "start-machine-recovery", for: URL.self) { $modelRootPath in
            if let rootPath = modelRootPath {
                VMOSMainVirtualMachineView(rootPath: rootPath, recoveryMode: true)
            } else {
                Text("Invalid , just close")
            }
        }
        .defaultPosition(.center)
        .defaultSize(width: 1024, height: 768)
        .windowToolbarStyle(.unifiedCompact)
        .restorationBehavior(.disabled)
        .commands {
            ControlCenterCommands()
        }

        Settings {
            VirtualizationFeaturesSettingsView()
        }
    }
#else
    
    var body: some Scene {
        WindowGroup {
            Text("App support only Apple Chips")
                .frame(minWidth: 800, minHeight: 600)
        }
    }
    
#endif
}

#if arch(arm64)
/// Menu bar icon: filled while a workspace machine is alive.
private struct VMWorkspaceMenuLabel: View {
    @State private var center = VMLiveMachineCenter.shared

    var body: some View {
        Image(systemName: center.machines.isEmpty ? "rectangle.stack" : "rectangle.stack.fill")
            .accessibilityLabel(center.machines.isEmpty
                ? "RiftVM: no workspace running"
                : "RiftVM: \(center.machines.count) workspace running")
    }
}

/// Menu bar menu: what is running, what can be done to it, and Quit, which
/// drains the machines before the process exits.
private struct VMWorkspaceMenu: View {
    @State private var center = VMLiveMachineCenter.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if center.machines.isEmpty {
            Text("No workspace is running")
        } else {
            ForEach(center.machines) { machine in
                Menu("\(machine.name) · \(machine.status)") {
                    Button("Show Window") { show(machine) }
                    Divider()
                    Button("Pause") { machine.pauseAction() }
                        .disabled(!machine.canPause)
                    Button("Resume") { machine.resumeAction() }
                        .disabled(!machine.canResume)
                    if machine.canSaveAndStop {
                        Button("Save State and Stop") { machine.saveAndStopAction() }
                    }
                    Button("Stop") { machine.stopAction() }
                        .disabled(!machine.canStop)
                }
            }
        }

        Divider()

        Button("Open Control Center") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "control-center")
        }
        Menu("New Workspace") {
            Button("Omarchy", systemImage: "sparkles.rectangle.stack") {
                openWindow(id: "create-machine-guide", value: RiftWorkspaceKind.omarchy)
            }
            Button("macOS", systemImage: "macwindow") {
                openWindow(id: "create-machine-guide", value: RiftWorkspaceKind.macOS)
            }
        }

        Divider()

        Button("Quit RiftVM") { NSApp.terminate(nil) }
    }

    private func show(_ machine: VMLiveMachine) {
        NSApp.activate(ignoringOtherApps: true)
        guard let record = (try? RiftWorkspaceRegistryStore.standard.load())?.workspaces.first(where: {
            $0.bundleURL.standardizedFileURL == machine.rootPath
        }) else { return }
        openWindow(id: "workspace", value: record.id)
    }
}

private struct CommunityCommands: Commands {
    @Environment(\.openURL) private var openURL

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Star RiftVM on GitHub") {
                openURL(URL(string: "https://github.com/riftvm/riftvm")!)
            }
            Button("Send Feedback…") {
                openURL(URL(string: "https://github.com/riftvm/riftvm/issues")!)
            }
            Button("Follow @everettjf on X") {
                openURL(URL(string: "https://x.com/everettjf")!)
            }
        }
    }
}
#endif

#if arch(arm64)
private struct ControlCenterCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        if HeadlessLaunchConfiguration.current == nil {
            CommandGroup(before: .windowList) {
                Button("Show RiftVM Control Center") {
                    openWindow(id: "control-center")
                }
                .keyboardShortcut("0", modifiers: .command)

                Divider()
            }
        }
    }
}
#endif

#if arch(arm64)
private struct VirtualizationFeaturesSettingsView: View {
    @State private var capabilityRefreshID = UUID()
    @AppStorage(RiftVMExperimentalFeatures.customVirGLGraphicsKey) private var customVirGLGraphics = true
    @AppStorage(VMThumbnailPreferences.screenCaptureEnabledKey) private var screenCaptureThumbnails = false
    @AppStorage(VMThumbnailPreferences.generatedStyleKey) private var generatedThumbnailStyle = VMGeneratedThumbnailStyle.aurora.rawValue

    var body: some View {
        Form {
            Section {
                ForEach(VirtualizationCapability.allCases) { capability in
                    HStack {
                        Label(capability.title, systemImage: "info.circle")
                        Spacer()
                        Text(capability.isAvailable ? "Host OS eligible" : "Requires macOS \(capability.minimumMajorVersion)+")
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(capability.isAvailable ? .primary : .secondary)
                }
            } header: {
                Text("Host OS requirements")
            } footer: {
                Text("These rows check the host OS version only. They do not show whether a feature is enabled or verified in a particular VM. Hardware, guest OS, disk format, and VM configuration may impose additional requirements. Check the workspace configuration and runtime status for the active VM.")
            }

            Section {
                ForEach(VMHostCapability.allCases) { capability in
                    HostCapabilityStatusRow(capability: capability, refreshID: capabilityRefreshID)
                }

                Button("Refresh Signed Capabilities", systemImage: "arrow.clockwise") {
                    capabilityRefreshID = UUID()
                }
            } header: {
                Text("Signed capabilities")
            } footer: {
                Text("These values come from the entitlements in the running RiftVM process. A granted entitlement does not mean a device is connected or a network mode is active. USB access also requires your authorization.")
            }

            Section {
                LabeledContent("DiskImageKit snapshots", value: "Eligible ASIF configurations")
                LabeledContent("EFI Secure Boot", value: "Configured per Linux VM")
                featureToggle(
                    "Prefer Custom VirGL for Linux",
                    isOn: $customVirGLGraphics,
                    capability: .customVirtio
                )
            } header: {
                Text("Feature configuration")
            } footer: {
                Text("Snapshot storage depends on the machine configuration; an ASIF file alone does not establish that layered snapshots are active. The graphics preference applies on the next start and may fall back to Apple graphics if initialization fails. macOS guests use Apple's graphics stack; graphics support depends on the host, guest, and hardware. This page does not verify guest Metal support or iCloud sign-in eligibility.")
            }

            Section {
                Toggle("Capture the virtual machine display", isOn: $screenCaptureThumbnails)
                    .onChange(of: screenCaptureThumbnails) { _, enabled in
                        if enabled && !CGPreflightScreenCaptureAccess() {
                            screenCaptureThumbnails = CGRequestScreenCaptureAccess()
                        }
                    }

                Picker("Generated cover style", selection: $generatedThumbnailStyle) {
                    ForEach(VMGeneratedThumbnailStyle.allCases) { style in
                        Text(style.title).tag(style.rawValue)
                    }
                }

                GeneratedMachineThumbnailView(
                    title: "Omarchy",
                    type: .linux,
                    style: VMGeneratedThumbnailStyle(rawValue: generatedThumbnailStyle) ?? .aurora
                )
                .frame(height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } header: {
                Text("Thumbnails")
            } footer: {
                Text(screenCaptureThumbnails
                    ? "Enabled by you. macOS requires Screen & System Audio Recording permission. Turn this off to stop RiftVM from capturing VM windows."
                    : "Off by default. RiftVM uses a generated title cover and never requests screen recording permission.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 720)
        .padding()
    }

    @ViewBuilder
    private func featureToggle(_ title: LocalizedStringKey, isOn: Binding<Bool>, capability: VirtualizationCapability) -> some View {
        Toggle(title, isOn: isOn)
            .disabled(!capability.isAvailable)
    }
}

private struct HostCapabilityStatusRow: View {
    let capability: VMHostCapability
    let refreshID: UUID

    var body: some View {
        let _ = refreshID
        let grantedKey = capability.grantedEntitlementKey()

        HStack(alignment: .firstTextBaseline) {
            Label(capability.title, systemImage: grantedKey == nil ? "xmark.circle" : "checkmark.circle.fill")
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(grantedKey == nil ? "Missing" : "Granted")
                Text(grantedKey ?? capability.entitlementKeys.joined(separator: " or "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .foregroundStyle(grantedKey == nil ? .secondary : .primary)
        .accessibilityElement(children: .combine)
    }
}
#endif
