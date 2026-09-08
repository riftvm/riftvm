import AppKit
import Foundation
import SwiftUI

#if arch(arm64)
struct WorkspaceControlCenterView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var snapshot: RiftWorkspaceRegistrySnapshot?
    @State private var filter: WorkspaceFilter = .all
    @State private var errorMessage: String?
    @State private var settingsModel: VMModel?
    @State private var snapshotWorkspace: RiftWorkspaceRecord?
    @State private var renameWorkspace: RiftWorkspaceRecord?
    @State private var renameDraft = ""
    @State private var deleteWorkspace: RiftWorkspaceRecord?
    @State private var pendingFolderDrop: WorkspaceFolderDrop?
    @State private var runStateRevision = UUID()

    private let registry = RiftWorkspaceRegistryStore.standard

    var body: some View {
        Group {
            if let snapshot {
                controlCenter(snapshot)
            } else if let errorMessage {
                ContentUnavailableView(
                    "Workspace registry unavailable",
                    systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView("Loading workspaces…")
            }
        }
        .task { loadRegistry() }
        .onReceive(NotificationCenter.default.publisher(for: .riftWorkspaceRegistryDidChange)) { _ in loadRegistry() }
        .onReceive(NotificationCenter.default.publisher(for: .riftVMRunStateDidChange)) { _ in runStateRevision = UUID() }
        .onReceive(NotificationCenter.default.publisher(for: .riftvmConfigurationSaved)) { _ in loadRegistry() }
        .sheet(item: $settingsModel) { VMEditConfigurationView(model: $0) }
        .sheet(item: $snapshotWorkspace) { workspace in
            MachineSnapshotsView(machineName: workspace.name, rootPath: workspace.bundleURL)
                .frame(minWidth: 820, minHeight: 620)
        }
        .alert("Rename Workspace", isPresented: renamePresented) {
            TextField("Workspace name", text: $renameDraft)
            Button("Cancel", role: .cancel) { renameWorkspace = nil }
            Button("Rename") { commitRename() }
                .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("This changes the display name. The workspace folder is not renamed.")
        }
        .confirmationDialog(
            "Move \(deleteWorkspace?.name ?? "this workspace") to the Trash?",
            isPresented: deletePresented,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { moveWorkspaceToTrash() }
            Button("Cancel", role: .cancel) { deleteWorkspace = nil }
        } message: {
            Text("The virtual machine bundle can be recovered from the Trash.")
        }
        .confirmationDialog(
            "Add \(pendingFolderDrop?.urls.count ?? 0) folder\((pendingFolderDrop?.urls.count ?? 0) == 1 ? "" : "s")?",
            isPresented: folderDropPresented,
            titleVisibility: .visible
        ) {
            Button("Share Read Only") { finishFolderDrop(copy: false) }
            Button("Copy into RiftVM Shared") { finishFolderDrop(copy: true) }
            Button("Cancel", role: .cancel) { pendingFolderDrop = nil }
        } message: {
            Text("Sharing leaves the folders on your Mac. Copying creates independent copies inside this workspace.")
        }
        .alert("RiftVM", isPresented: errorPresented) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func controlCenter(_ snapshot: RiftWorkspaceRegistrySnapshot) -> some View {
        NavigationSplitView {
            List(selection: $filter) {
                Section("Workspaces") {
                    ForEach(WorkspaceFilter.allCases) { item in
                        Label {
                            HStack {
                                Text(item.title)
                                Spacer()
                                Text("\(count(for: item, in: snapshot))")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        } icon: {
                            Image(systemName: item.systemImage)
                        }
                        .tag(item)
                    }
                }
            }
            .navigationTitle("RiftVM")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            dashboard(snapshot)
                .id(runStateRevision)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("New Workspace", systemImage: "plus") {
                    Button("Omarchy", systemImage: "sparkles.rectangle.stack") {
                        openWindow(id: "create-machine-guide", value: RiftWorkspaceKind.omarchy)
                    }
                    Button("macOS", systemImage: "macwindow") {
                        openWindow(id: "create-machine-guide", value: RiftWorkspaceKind.macOS)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func dashboard(_ snapshot: RiftWorkspaceRegistrySnapshot) -> some View {
        let workspaces = filteredWorkspaces(in: snapshot)
        if snapshot.workspaces.isEmpty {
            WorkspaceControlCenterWelcomeView(
                createOmarchy: { openWindow(id: "create-machine-guide", value: RiftWorkspaceKind.omarchy) },
                createMacOS: { openWindow(id: "create-machine-guide", value: RiftWorkspaceKind.macOS) }
            )
        } else if workspaces.isEmpty {
            ContentUnavailableView(
                "No \(filter.title) Workspaces",
                systemImage: filter.systemImage,
                description: Text("Choose another category or create a new workspace.")
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(filter == .all ? "Your Workspaces" : filter.title)
                            .font(.largeTitle.bold())
                        Text("Each workspace is an independent virtual machine.")
                            .foregroundStyle(.secondary)
                    }
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 18)],
                        alignment: .leading,
                        spacing: 18
                    ) {
                        ForEach(workspaces) { workspace in
                            WorkspaceCardView(
                                workspace: workspace,
                                summary: WorkspaceSummary(workspace: workspace),
                                runPhase: VMRunningRegistry.shared.phase(rootPath: workspace.bundleURL),
                                isRunning: VMRunningRegistry.shared.isRunning(rootPath: workspace.bundleURL),
                                open: { open(workspace) },
                                manageSharing: { showSettings(for: workspace) },
                                togglePinned: { setPinned(workspace, pinned: workspace.pinnedAt == nil) },
                                showSettings: { showSettings(for: workspace) },
                                showSnapshots: { snapshotWorkspace = workspace },
                                reveal: { NSWorkspace.shared.activateFileViewerSelecting([workspace.bundleURL]) },
                                rename: { beginRename(workspace) },
                                delete: { requestDelete(workspace) },
                                receiveDrop: { receiveDrop($0, on: workspace) }
                            )
                        }
                    }
                }
                .frame(maxWidth: 1120, alignment: .leading)
                .padding(32)
            }
        }
    }

    private func filteredWorkspaces(in snapshot: RiftWorkspaceRegistrySnapshot) -> [RiftWorkspaceRecord] {
        snapshot.workspaces
            .filter { workspace in
                switch filter {
                case .all: true
                case .running: VMRunningRegistry.shared.isRunning(rootPath: workspace.bundleURL)
                case .omarchy: workspace.kind == .omarchy
                case .macOS: workspace.kind == .macOS
                }
            }
            .sorted { lhs, rhs in
                switch (lhs.pinnedAt, rhs.pinnedAt) {
                case (.some(let left), .some(let right)): left > right
                case (.some, .none): true
                case (.none, .some): false
                case (.none, .none): (lhs.lastOpenedAt ?? lhs.createdAt) > (rhs.lastOpenedAt ?? rhs.createdAt)
                }
            }
    }

    private func count(for filter: WorkspaceFilter, in snapshot: RiftWorkspaceRegistrySnapshot) -> Int {
        switch filter {
        case .all: snapshot.workspaces.count
        case .running: snapshot.workspaces.filter { VMRunningRegistry.shared.isRunning(rootPath: $0.bundleURL) }.count
        case .omarchy: snapshot.workspaces.filter { $0.kind == .omarchy }.count
        case .macOS: snapshot.workspaces.filter { $0.kind == .macOS }.count
        }
    }

    private func open(_ workspace: RiftWorkspaceRecord) {
        do {
            try WorkspaceSharing.prepareManagedFolder(for: workspace)
            snapshot = try registry.markOpened(workspace.id)
            openWindow(id: "workspace", value: workspace.id)
        } catch { errorMessage = error.localizedDescription }
    }

    private func showSettings(for workspace: RiftWorkspaceRecord) {
        switch VMModel.loadConfigFromFile(rootPath: workspace.bundleURL) {
        case .success(let model): settingsModel = model
        case .failure:
            errorMessage = "The configuration for \(workspace.name) is unavailable."
        }
    }

    private func setPinned(_ workspace: RiftWorkspaceRecord, pinned: Bool) {
        do { snapshot = try registry.setPinned(workspace.id, pinned: pinned) }
        catch { errorMessage = error.localizedDescription }
    }

    private func beginRename(_ workspace: RiftWorkspaceRecord) {
        renameDraft = workspace.name
        renameWorkspace = workspace
    }

    private func commitRename() {
        guard let workspace = renameWorkspace else { return }
        do {
            snapshot = try registry.rename(workspace.id, to: renameDraft)
            renameWorkspace = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func requestDelete(_ workspace: RiftWorkspaceRecord) {
        guard !VMRunningRegistry.shared.isRunning(rootPath: workspace.bundleURL) else {
            errorMessage = "Stop \(workspace.name) before moving it to the Trash."
            return
        }
        deleteWorkspace = workspace
    }

    private func moveWorkspaceToTrash() {
        guard let workspace = deleteWorkspace else { return }
        do {
            _ = try FileManager.default.trashItem(at: workspace.bundleURL, resultingItemURL: nil)
            snapshot = try registry.unregister(workspace.id)
            deleteWorkspace = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func receiveDrop(_ urls: [URL], on workspace: RiftWorkspaceRecord) -> Bool {
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let files = urls.filter { !folders.contains($0) }
        do {
            if !files.isEmpty { try WorkspaceSharing.copy(files, into: workspace) }
            if !folders.isEmpty { pendingFolderDrop = WorkspaceFolderDrop(workspace: workspace, urls: folders) }
            return !files.isEmpty || !folders.isEmpty
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func finishFolderDrop(copy: Bool) {
        guard let drop = pendingFolderDrop else { return }
        do {
            if copy { try WorkspaceSharing.copy(drop.urls, into: drop.workspace) }
            else { try WorkspaceSharing.shareReadOnly(drop.urls, with: drop.workspace) }
            pendingFolderDrop = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func loadRegistry() {
        do {
            snapshot = try registry.load()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameWorkspace != nil }, set: { if !$0 { renameWorkspace = nil } })
    }
    private var deletePresented: Binding<Bool> {
        Binding(get: { deleteWorkspace != nil }, set: { if !$0 { deleteWorkspace = nil } })
    }
    private var folderDropPresented: Binding<Bool> {
        Binding(get: { pendingFolderDrop != nil }, set: { if !$0 { pendingFolderDrop = nil } })
    }
    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil && snapshot != nil }, set: { if !$0 { errorMessage = nil } })
    }
}

struct WorkspaceWindowView: View {
    let workspaceID: UUID
    @State private var workspace: RiftWorkspaceRecord?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let workspace {
                WorkspaceRuntimeView(workspace: workspace)
            } else if let errorMessage {
                ContentUnavailableView("Workspace unavailable", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else {
                ProgressView("Opening workspace…")
            }
        }
        .task { load() }
    }

    private func load() {
        do {
            guard let record = try RiftWorkspaceRegistryStore.standard.load().workspaces.first(where: { $0.id == workspaceID }) else {
                throw RiftWorkspaceRegistryError.workspaceNotFound
            }
            try WorkspaceSharing.prepareManagedFolder(for: record)
            workspace = record
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct WorkspaceRuntimeView: View {
    let workspace: RiftWorkspaceRecord

    var body: some View {
        VMOSMainVirtualMachineView(rootPath: workspace.bundleURL, recoveryMode: false)
    }
}

private enum WorkspaceFilter: String, CaseIterable, Identifiable {
    case all, running, omarchy, macOS
    var id: Self { self }
    var title: String {
        switch self { case .all: "All"; case .running: "Running"; case .omarchy: "Omarchy"; case .macOS: "macOS" }
    }
    var systemImage: String {
        switch self { case .all: "square.grid.2x2"; case .running: "play.circle"; case .omarchy: "sparkles.rectangle.stack"; case .macOS: "macwindow" }
    }
}

private struct WorkspaceControlCenterWelcomeView: View {
    let createOmarchy: () -> Void
    let createMacOS: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Text("RiftVM").font(.system(size: 42, weight: .bold))
                Text("A workspace is an independent virtual machine on your Mac.")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 20) {
                WorkspaceControlCenterCreationCard(title: "Create Omarchy Workspace", description: "A focused Linux desktop with Rift integration.", systemImage: "sparkles.rectangle.stack", action: createOmarchy)
                WorkspaceControlCenterCreationCard(title: "Create macOS Workspace", description: "Install from a supported restore image or local IPSW.", systemImage: "macwindow", action: createMacOS)
            }
            .frame(maxWidth: 780)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WorkspaceControlCenterCreationCard: View {
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
                Label("Continue", systemImage: "arrow.right")
                    .padding(.top, 12)
            }
            .multilineTextAlignment(.leading)
            .padding(24)
            .frame(maxWidth: .infinity, minHeight: 230, maxHeight: 250, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(.quaternary) }
    }
}

private struct WorkspaceCardView: View {
    let workspace: RiftWorkspaceRecord
    let summary: WorkspaceSummary
    let runPhase: VMRunPhase?
    let isRunning: Bool
    let open: () -> Void
    let manageSharing: () -> Void
    let togglePinned: () -> Void
    let showSettings: () -> Void
    let showSnapshots: () -> Void
    let reveal: () -> Void
    let rename: () -> Void
    let delete: () -> Void
    let receiveDrop: ([URL]) -> Bool
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Image(systemName: workspace.kind == .omarchy ? "sparkles.rectangle.stack" : "macwindow")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(workspace.name).font(.title3.weight(.semibold)).lineLimit(1)
                    Text(workspace.kind == .omarchy ? "Omarchy Workspace" : "macOS Workspace")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if workspace.pinnedAt != nil { Image(systemName: "pin.fill").foregroundStyle(.secondary) }
            }
            Label(statusTitle, systemImage: statusImage)
                .font(.callout.weight(.medium))
                .foregroundStyle(statusColor)
            if let hardware = summary.hardware {
                Text(hardware).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Button(action: manageSharing) {
                Label(summary.sharing, systemImage: "folder")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Manage the host folders available to this workspace")
            HStack {
                if let date = workspace.lastOpenedAt {
                    Text("Opened \(date, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button(isRunning ? "Open" : "Start", systemImage: isRunning ? "macwindow.on.rectangle" : "play.fill", action: open)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: isDropTargeted ? 2 : 1)
        }
        .overlay {
            if isDropTargeted {
                Label("Drop files or folders", systemImage: "folder.fill.badge.plus")
                    .font(.headline)
                    .padding(14)
                    .background(.regularMaterial, in: Capsule())
            }
        }
        .dropDestination(for: URL.self) { urls, _ in receiveDrop(urls) } isTargeted: { isDropTargeted = $0 }
        .contextMenu {
            Button(workspace.pinnedAt == nil ? "Pin" : "Unpin", systemImage: "pin", action: togglePinned)
            Button("Settings", systemImage: "gearshape", action: showSettings)
            Button("Snapshots", systemImage: "camera.on.rectangle", action: showSnapshots)
            Divider()
            Button("Show in Finder", systemImage: "folder", action: reveal)
            Button("Rename", systemImage: "pencil", action: rename)
            Divider()
            Button("Move to Trash", systemImage: "trash", role: .destructive, action: delete)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(workspace.name), \(statusTitle)")
    }

    private var statusTitle: String { runPhase?.cardLabel ?? (isRunning ? "Running" : summary.needsAttention ? "Needs Attention" : "Stopped") }
    private var statusImage: String { isRunning ? "circle.fill" : summary.needsAttention ? "exclamationmark.triangle.fill" : "circle" }
    private var statusColor: Color { isRunning ? .green : summary.needsAttention ? .orange : .secondary }
}

private struct WorkspaceSummary {
    let hardware: String?
    let sharing: String
    let needsAttention: Bool

    init(workspace: RiftWorkspaceRecord) {
        switch VMModel.loadConfigFromFile(rootPath: workspace.bundleURL) {
        case .success(let model):
            let disk = model.config.storageDevices.first(where: { $0.type == .Block })?.size ?? 0
            hardware = "\(model.config.cpu.count) CPU · \(Self.bytes(model.config.memory.size)) memory · \(Self.bytes(disk)) disk"
            let managedURL = VMManagedSharedFolder.url(for: workspace.bundleURL)
            let externalCount = model.config.directorySharingDevices.flatMap(\.items).filter {
                $0.path.standardizedFileURL != managedURL
            }.count
            sharing = externalCount == 0 ? "RiftVM Shared · No host folders shared" : "RiftVM Shared · \(externalCount) additional folder\(externalCount == 1 ? "" : "s")"
            needsAttention = false
        case .failure:
            hardware = nil
            sharing = "Shared-folder status unavailable"
            needsAttention = true
        }
    }

    private static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }
}

private struct WorkspaceFolderDrop: Identifiable {
    let id = UUID()
    let workspace: RiftWorkspaceRecord
    let urls: [URL]
}

private enum WorkspaceSharingError: LocalizedError {
    case unsupportedItem(String)
    case configurationUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedItem(let name): "RiftVM cannot copy the symbolic link “\(name)”."
        case .configurationUnavailable: "This workspace does not support additional host-folder shares."
        }
    }
}

@MainActor
private enum WorkspaceSharing {
    static func managedFolderURL(for workspace: RiftWorkspaceRecord) -> URL {
        VMManagedSharedFolder.url(for: workspace.bundleURL)
    }

    static func prepareManagedFolder(for workspace: RiftWorkspaceRecord) throws {
        try VMManagedSharedFolder.prepare(at: workspace.bundleURL)
        guard case .success(let model) = VMModel.loadConfigFromFile(rootPath: workspace.bundleURL) else { return }
        let managedURL = managedFolderURL(for: workspace)
        guard !model.config.directorySharingDevices.contains(where: { device in
            device.items.contains { $0.path.standardizedFileURL == managedURL }
        }) else { return }
        try unwrap(model.config.addingManagedSharedFolder(rootPath: workspace.bundleURL).writeConfigToFile(path: model.configURL))
    }

    static func copy(_ sources: [URL], into workspace: RiftWorkspaceRecord) throws {
        try prepareManagedFolder(for: workspace)
        let destinationRoot = managedFolderURL(for: workspace)
        for source in sources {
            let values = try source.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw WorkspaceSharingError.unsupportedItem(source.lastPathComponent) }
            var destination = destinationRoot.appending(path: source.lastPathComponent)
            var suffix = 2
            while FileManager.default.fileExists(atPath: destination.path) {
                let stem = source.deletingPathExtension().lastPathComponent
                let ext = source.pathExtension.isEmpty ? "" : ".\(source.pathExtension)"
                destination = destinationRoot.appending(path: "\(stem) copy \(suffix)\(ext)")
                suffix += 1
            }
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    static func shareReadOnly(_ folders: [URL], with workspace: RiftWorkspaceRecord) throws {
        try prepareManagedFolder(for: workspace)
        guard case .success(let model) = VMModel.loadConfigFromFile(rootPath: workspace.bundleURL) else {
            throw WorkspaceSharingError.configurationUnavailable
        }
        let state = VMConfigurationViewStateObject(configModel: model.config)
        for folder in folders { _ = state.addSharedDirectory(folder, readOnly: true) }
        try unwrap(state.getConfigModel().writeConfigToFile(path: model.configURL))
        NotificationCenter.default.post(name: AppConfigManager.newVMChangedNotification, object: nil)
    }

    private static func unwrap(_ result: VMOSResultVoid) throws {
        if case .failure(let message) = result {
            throw NSError(domain: "RiftVM.Sharing", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}

#Preview { WorkspaceControlCenterView() }
#endif
