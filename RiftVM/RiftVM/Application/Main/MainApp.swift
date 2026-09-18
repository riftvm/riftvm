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
        // The app has one window. It prepares the workspace while there is none
        // and drives the Omarchy workspace afterwards, so there is no control
        // center, no separate creation window, and no second workspace window.
        Window("RiftVM", id: "workspace") {
            if HeadlessLaunchConfiguration.current == nil {
                WorkspaceHomeView()
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
            WorkspaceCommands()
        }

        // Persistent status for the running workspace, and the way back to the
        // app once its window is closed.
        MenuBarExtra {
            VMWorkspaceMenu()
        } label: {
            VMWorkspaceMenuLabel()
        }
        .menuBarExtraStyle(.menu)

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

        Button("Open RiftVM") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "workspace")
        }

        Divider()

        Button("Quit RiftVM") { NSApp.terminate(nil) }
    }

    private func show(_ machine: VMLiveMachine) {
        _ = machine
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "workspace")
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
private struct WorkspaceCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        if HeadlessLaunchConfiguration.current == nil {
            CommandGroup(before: .windowList) {
                Button("Show RiftVM") {
                    openWindow(id: "workspace")
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
                LabeledContent("Linux graphics", value: "Configured per VM in Settings → Display")
            } header: {
                Text("Feature configuration")
            } footer: {
                Text("Snapshot storage depends on the machine configuration; an ASIF file alone does not establish that layered snapshots are active. The graphics backend is saved per VM and changes only after shutdown. Startup failures never silently switch backends. Guest graphics support depends on the host, the guest, and the hardware; this page does not verify guest Metal support or sign-in eligibility.")
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
