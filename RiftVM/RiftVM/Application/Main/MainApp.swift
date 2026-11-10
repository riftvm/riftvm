//
//  RiftVMApp.swift
//  RiftVM
//
//  Created by everettjf on 2022/6/24.
//

import SwiftUI
import CoreGraphics
import Foundation

@main
struct MainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    
#if arch(arm64)
    var body: some Scene {
        // The app has one window. It prepares the workspace while there is none
        // and drives the Omarchy workspace afterwards, so there is no control
        // center, no separate creation window, and no second workspace window.
        Window("RiftVM", id: "workspace") {
            WorkspaceHomeView()
                .frame(minWidth: 800, minHeight: 600)
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
struct RiftVMAppRelease: Equatable {
    let version: String
    let url: URL
}

enum RiftVMAppUpdatePolicy {
    static let checkInterval: TimeInterval = 7 * 24 * 60 * 60

    static func isCheckDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        return lastCheck > now || now.timeIntervalSince(lastCheck) >= checkInterval
    }

    static func newerRelease(from data: Data, currentVersion: String) throws -> RiftVMAppRelease? {
        struct GitHubRelease: Decodable {
            let tag_name: String
            let draft: Bool
            let prerelease: Bool
        }

        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        let candidates = releases.compactMap { release -> (version: [Int], appRelease: RiftVMAppRelease)? in
            guard !release.draft, !release.prerelease,
                  release.tag_name.hasPrefix("riftvm-v") else { return nil }
            let version = String(release.tag_name.dropFirst("riftvm-v".count))
            guard let appRelease = newerRelease(version: version, currentVersion: currentVersion),
                  let parts = versionParts(version) else { return nil }
            return (parts, appRelease)
        }
        return candidates.max { $0.version.lexicographicallyPrecedes($1.version) }?.appRelease
    }

    static func newerRelease(version: String, currentVersion: String) -> RiftVMAppRelease? {
        guard let current = versionParts(currentVersion),
              let latest = versionParts(version),
              current.lexicographicallyPrecedes(latest),
              let url = URL(string: "https://github.com/riftvm/riftvm/releases/tag/riftvm-v\(version)") else {
            return nil
        }
        return RiftVMAppRelease(version: version, url: url)
    }

    private static func versionParts(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) }) else {
            return nil
        }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == 3 ? numbers : nil
    }
}

/// Checks GitHub's latest published release at most once every seven days.
/// The user chooses whether to open the release page; no update is installed.
@MainActor
@Observable
final class RiftVMAppUpdateChecker {
    static let shared = RiftVMAppUpdateChecker()

    private enum Keys {
        static let lastCheck = "RiftVMAppUpdateLastCheck"
        static let latestVersion = "RiftVMAppUpdateLatestVersion"
        static let dismissedVersion = "RiftVMAppUpdateDismissedVersion"
    }

    private let defaults: UserDefaults
    private var timer: Timer?
    private var checking = false
    private(set) var availableRelease: RiftVMAppRelease?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showCachedRelease()
    }

    func start() {
        guard timer == nil else { return }
        checkIfDue()
        // A running VM can keep the app open for days without reopening its window.
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
    }

    func dismiss() {
        guard let availableRelease else { return }
        defaults.set(availableRelease.version, forKey: Keys.dismissedVersion)
        self.availableRelease = nil
    }

    private func showCachedRelease() {
        guard let version = defaults.string(forKey: Keys.latestVersion),
              let release = RiftVMAppUpdatePolicy.newerRelease(version: version, currentVersion: AppInfo.version),
              defaults.string(forKey: Keys.dismissedVersion) != version else { return }
        availableRelease = release
    }

    private func checkIfDue() {
        guard !checking,
              RiftVMAppUpdatePolicy.isCheckDue(
                lastCheck: defaults.object(forKey: Keys.lastCheck) as? Date,
                now: Date()
              ) else { return }
        checking = true
        defaults.set(Date(), forKey: Keys.lastCheck)

        var request = URLRequest(url: URL(string: "https://api.github.com/repos/riftvm/riftvm/releases?per_page=30")!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("RiftVM/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        Task { [weak self] in
            guard let self else { return }
            defer { self.checking = false }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { return }
                let release = try RiftVMAppUpdatePolicy.newerRelease(
                    from: data, currentVersion: AppInfo.version
                )
                self.defaults.set(release?.version, forKey: Keys.latestVersion)
                self.availableRelease = release?.version == self.defaults.string(forKey: Keys.dismissedVersion)
                    ? nil : release
            } catch {
                RiftVMLog.info("Could not check GitHub for an app update: \(error.localizedDescription)")
            }
        }
    }
}

/// Menu bar icon: filled while a workspace machine is alive.
private struct VMWorkspaceMenuLabel: View {
    @State private var center = VMLiveMachineCenter.shared

    var body: some View {
        Image(systemName: center.machines.isEmpty ? "rectangle.stack" : "rectangle.stack.fill")
            .accessibilityLabel(center.machines.isEmpty
                ? "RiftVM: Omarchy is not running"
                : "RiftVM: Omarchy is running")
    }
}

/// Menu bar menu: what is running, what can be done to it, and Quit, which
/// drains the machines before the process exits.
private struct VMWorkspaceMenu: View {
    @State private var center = VMLiveMachineCenter.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if center.machines.isEmpty {
            Text("Omarchy is not running")
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
        CommandGroup(before: .windowList) {
            Button("Show RiftVM") {
                openWindow(id: "workspace")
            }
            .keyboardShortcut("0", modifiers: .command)

            Divider()
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
                Text("These rows check the host OS version only. They do not show whether a feature is enabled or verified in a particular VM. Hardware, guest OS, disk format, and VM configuration may impose additional requirements. Check the runtime status of the running VM.")
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
