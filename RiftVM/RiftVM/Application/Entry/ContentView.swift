import Foundation
import SwiftUI

#if arch(arm64)
struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var snapshot: RiftWorkspaceRegistrySnapshot?
    @State private var selectedWorkspaceID: UUID?
    @State private var errorMessage: String?

    private let registry = RiftWorkspaceRegistryStore.standard

    var body: some View {
        Group {
            if let snapshot {
                content(for: snapshot)
            } else if let errorMessage {
                ContentUnavailableView("Workspace registry unavailable", systemImage: "externaldrive.badge.exclamationmark", description: Text(errorMessage))
            } else {
                ProgressView("Loading workspaces…")
            }
        }
        .task { loadRegistry() }
        .onReceive(NotificationCenter.default.publisher(for: .riftWorkspaceRegistryDidChange)) { _ in
            loadRegistry()
        }
    }

    @ViewBuilder
    private func content(for snapshot: RiftWorkspaceRegistrySnapshot) -> some View {
        if let workspace = selectedWorkspace(in: snapshot) {
            workspaceView(workspace)
        } else if snapshot.workspaces.isEmpty {
            WorkspaceWelcomeView(
                createOmarchy: createOmarchyWorkspace,
                createMacOS: { openWindow(id: "create-machine-guide") },
                createCustomLinux: { openWindow(id: "create-machine-guide") }
            )
        } else {
            WorkspaceChooserView(
                snapshot: snapshot,
                openWorkspace: { selectedWorkspaceID = $0.id },
                makeDefault: setDefault,
                createWorkspace: { openWindow(id: "create-machine-guide") }
            )
        }
    }

    @ViewBuilder
    private func workspaceView(_ workspace: RiftWorkspaceRecord) -> some View {
        VStack(spacing: 0) {
            workspaceToolbar(workspace)
            Divider()
            switch workspace.kind {
            case .omarchy:
                let manager = VMOmarchyWorkspaceManager(layout: .init(applicationSupportRoot: workspace.bundleURL))
                OmarchyRootView(profile: .production, workspaceManager: manager)
                    .onAppear { OmarchyReleaseReadinessReporter.reportWhenReady(workspaceManager: manager) }
            case .macOS, .customLinux:
                VMOSMainVirtualMachineView(rootPath: workspace.bundleURL, recoveryMode: false)
            }
        }
    }

    private func workspaceToolbar(_ workspace: RiftWorkspaceRecord) -> some View {
        HStack {
            Button("Workspaces", systemImage: "square.grid.2x2") { selectedWorkspaceID = nil }
            Spacer()
            Text(workspace.name).font(.headline)
            Spacer()
            Button("New Workspace", systemImage: "plus") {
                selectedWorkspaceID = nil
                openWindow(id: "create-machine-guide")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private func selectedWorkspace(in snapshot: RiftWorkspaceRegistrySnapshot) -> RiftWorkspaceRecord? {
        if let selectedWorkspaceID {
            return snapshot.workspaces.first { $0.id == selectedWorkspaceID }
        }
        if case .open(let workspace) = snapshot.launchSelection() { return workspace }
        return nil
    }

    private func loadRegistry() {
        do {
            snapshot = try registry.load()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createOmarchyWorkspace() {
        do {
            let id = UUID()
            let machines = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "RiftVM Virtual Machines", directoryHint: .isDirectory)
            let workspace = try RiftWorkspaceRecord(
                id: id,
                name: "Omarchy",
                kind: .omarchy,
                bundleURL: machines.appending(path: "Omarchy-\(id.uuidString).riftvm", directoryHint: .isDirectory)
            )
            snapshot = try registry.register(workspace, makeDefault: snapshot?.workspaces.isEmpty == true)
            selectedWorkspaceID = workspace.id
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setDefault(_ workspace: RiftWorkspaceRecord) {
        do {
            snapshot = try registry.setDefault(workspace.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct WorkspaceWelcomeView: View {
    let createOmarchy: () -> Void
    let createMacOS: () -> Void
    let createCustomLinux: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Text("RiftVM").font(.system(size: 42, weight: .bold))
                Text("Bring another world to your Mac.").font(.title2).foregroundStyle(.secondary)
            }
            HStack(spacing: 20) {
                WorkspaceCreationCard(title: "Create Omarchy Workspace", description: "A focused Linux desktop with Rift integration.", systemImage: "sparkles.rectangle.stack", action: createOmarchy)
                WorkspaceCreationCard(title: "Create macOS Workspace", description: "Install from a supported restore image or local IPSW.", systemImage: "macwindow", action: createMacOS)
            }
            .frame(maxWidth: 780)
            Button("More Systems / Custom ISO…", systemImage: "opticaldisc", action: createCustomLinux)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WorkspaceCreationCard: View {
    let title: String
    let description: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: systemImage).font(.system(size: 34))
                Text(title).font(.title2.weight(.semibold))
                Text(description).foregroundStyle(.secondary)
                Spacer()
                Label("Continue", systemImage: "arrow.right")
            }
            .multilineTextAlignment(.leading)
            .padding(24)
            .frame(maxWidth: .infinity, minHeight: 230, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.quaternary) }
    }
}

private struct WorkspaceChooserView: View {
    let snapshot: RiftWorkspaceRegistrySnapshot
    let openWorkspace: (RiftWorkspaceRecord) -> Void
    let makeDefault: (RiftWorkspaceRecord) -> Void
    let createWorkspace: () -> Void

    var body: some View {
        NavigationSplitView {
            List(snapshot.workspaces) { workspace in
                Button { openWorkspace(workspace) } label: {
                    Label(workspace.name, systemImage: icon(for: workspace.kind))
                }
                .contextMenu { Button("Make Default") { makeDefault(workspace) } }
            }
            .navigationTitle("Workspaces")
            .toolbar { Button("New Workspace", systemImage: "plus", action: createWorkspace) }
        } detail: {
            ContentUnavailableView("Choose a workspace", systemImage: "square.grid.2x2", description: Text("Open an existing workspace or create another one."))
        }
    }

    private func icon(for kind: RiftWorkspaceKind) -> String {
        switch kind {
        case .omarchy: "sparkles.rectangle.stack"
        case .macOS: "macwindow"
        case .customLinux: "terminal"
        }
    }
}

#Preview { ContentView() }
#endif
