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
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(item.accent)
                        }
                        .tag(item)
                    }
                }
            }
            .navigationTitle("RiftVM")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            VStack(spacing: 0) {
                if !WorkspaceCreationStore.shared.sessions.isEmpty {
                    VStack(spacing: 10) {
                        ForEach(WorkspaceCreationStore.shared.sessions) { session in
                            HStack(spacing: 14) {
                                Image(systemName: session.phase == .ready ? "checkmark.circle" : session.phase == .failed ? "exclamationmark.triangle" : "arrow.down.circle")
                                    .foregroundStyle(session.phase == .failed ? Color.orange : Color.accentColor)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(session.config.name).font(.headline)
                                    Text(session.phase == .failed ? "Creation needs attention" : session.form.creationStage)
                                        .font(.caption).foregroundStyle(.secondary)
                                    if session.phase == .creating,
                                       let received = session.form.downloadBytesReceived,
                                       let expected = session.form.downloadBytesExpected, received < expected {
                                        ProgressView(value: Double(received), total: Double(max(expected, 1)))
                                            .frame(maxWidth: 300)
                                        Text("\(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))")
                                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                                    }
                                }
                                Spacer()
                                Button(session.phase == .ready ? "Open" : "View Progress") {
                                    openWindow(id: "workspace-creation", value: session.id)
                                }
                            }
                            .padding(14)
                            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }.padding(20)
                }
                dashboard(snapshot).id(runStateRevision)
            }
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
            ZStack {
                WorkspaceWorldBackdrop()
                    .accessibilityHidden(true)

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(filter == .all ? "Your Workspaces" : filter.title)
                                .font(.largeTitle.bold())
                                .foregroundStyle(
                                    .linearGradient(
                                        colors: [.primary, .primary, filter.accent],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                            Text("Two worlds, one Mac. Each workspace is an independent virtual machine.")
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
            if workspace.kind == .macOS {
                try WorkspaceSharing.prepareManagedFolder(for: workspace)
            }
            snapshot = try registry.markOpened(workspace.id)
            openWindow(id: "workspace", value: workspace.id)
        } catch { errorMessage = error.localizedDescription }
    }

    private func showSettings(for workspace: RiftWorkspaceRecord) {
        guard workspace.kind == .macOS else {
            errorMessage = "Omarchy hardware and integration settings are managed by RiftVM for the best supported experience."
            return
        }
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
            if workspace.kind == .omarchy {
                try WorkspaceSharing.copy(files + folders, into: workspace)
                return !files.isEmpty || !folders.isEmpty
            }
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
        switch workspace.kind {
        case .omarchy:
            OmarchyRootView(
                profile: .production,
                workspaceManager: VMOmarchyWorkspaceManager(
                    layout: VMOmarchyWorkspaceLayout(applicationSupportRoot: workspace.bundleURL)
                )
            )
        case .macOS:
            VMOSMainVirtualMachineView(rootPath: workspace.bundleURL, recoveryMode: false)
        }
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
    var accent: Color {
        switch self {
        case .all: .purple
        case .running: .green
        case .omarchy: WorkspaceWorldTheme.fire.accent
        case .macOS: WorkspaceWorldTheme.ice.accent
        }
    }
}

private struct WorkspaceWorldTheme {
    let accent: Color
    let bright: Color
    let deep: Color
    let eyebrow: String
    let symbol: String

    static let fire = WorkspaceWorldTheme(
        accent: Color(red: 1, green: 0.34, blue: 0.12),
        bright: Color(red: 1, green: 0.68, blue: 0.12),
        deep: Color(red: 0.32, green: 0.025, blue: 0.015),
        eyebrow: "FIRE WORLD",
        symbol: "flame.fill"
    )
    static let ice = WorkspaceWorldTheme(
        accent: Color(red: 0.14, green: 0.72, blue: 1),
        bright: Color(red: 0.64, green: 0.94, blue: 1),
        deep: Color(red: 0.015, green: 0.10, blue: 0.28),
        eyebrow: "ICE WORLD",
        symbol: "snowflake"
    )

    static func theme(for kind: RiftWorkspaceKind) -> WorkspaceWorldTheme {
        kind == .omarchy ? .fire : .ice
    }
}

private struct WorkspaceWorldBackdrop: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            HStack(spacing: 0) {
                LinearGradient(
                    colors: [WorkspaceWorldTheme.fire.deep.opacity(0.48), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                LinearGradient(
                    colors: [.clear, WorkspaceWorldTheme.ice.deep.opacity(0.52)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            RadialGradient(
                colors: [WorkspaceWorldTheme.fire.accent.opacity(0.13), .clear],
                center: .bottomLeading,
                startRadius: 12,
                endRadius: 430
            )
            RadialGradient(
                colors: [WorkspaceWorldTheme.ice.accent.opacity(0.14), .clear],
                center: .topTrailing,
                startRadius: 12,
                endRadius: 460
            )
            LinearGradient(
                colors: [.clear, Color.primary.opacity(0.045), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

private struct WorkspaceControlCenterWelcomeView: View {
    let createOmarchy: () -> Void
    let createMacOS: () -> Void

    var body: some View {
        ZStack {
            WorkspaceRiftBackdrop()
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("APPLE SILICON  /  TWO WORLDS  /  ONE MAC")
                        .font(.caption2.monospaced().weight(.semibold))
                        .tracking(2.4)
                        .foregroundStyle(.white.opacity(0.58))
                    Text("Break into")
                        .font(.system(.largeTitle, design: .rounded, weight: .black))
                        .foregroundStyle(.white)
                    Text("another world.")
                        .font(.system(.largeTitle, design: .rounded, weight: .black))
                        .foregroundStyle(
                            .linearGradient(
                                colors: [.pink, .orange, .cyan],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    Text("A Workspace is an independent virtual machine. Pick a world to begin.")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.72))
                        .padding(.top, 2)
                }

                HStack(spacing: 18) {
                    WorkspaceControlCenterCreationCard(
                        title: "Omarchy",
                        description: "A focused Arch Linux desktop, ready on first boot.",
                        badge: "RECOMMENDED",
                        isOmarchy: true,
                        accent: .orange,
                        action: createOmarchy
                    )
                    WorkspaceControlCenterCreationCard(
                        title: "macOS",
                        description: "Create a clean Mac from a supported restore image.",
                        badge: "CHOOSE VERSION",
                        isOmarchy: false,
                        accent: .cyan,
                        action: createMacOS
                    )
                }
                .frame(maxWidth: 880)
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(44)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

private struct WorkspaceControlCenterCreationCard: View {
    let title: String
    let description: String
    let badge: String
    let isOmarchy: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                WorkspaceSystemIcon(isOmarchy: isOmarchy, size: 54)
                Text(title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.67))
                    .lineLimit(2, reservesSpace: true)
                Label(badge, systemImage: "arrow.up.right")
                    .font(.caption.monospaced().weight(.bold))
                    .tracking(1.1)
                    .foregroundStyle(accent)
                    .padding(.top, 10)
            }
            .multilineTextAlignment(.leading)
            .padding(22)
            .frame(maxWidth: .infinity, minHeight: 245, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(Color.white.opacity(0.075), in: .rect(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(accent.opacity(0.62), lineWidth: 1.5)
        }
        .shadow(color: accent.opacity(0.12), radius: 24)
        .accessibilityLabel("Create \(title) Workspace")
        .accessibilityHint(description)
    }
}

private struct WorkspaceRiftBackdrop: View {
    var body: some View {
        Canvas { context, size in
            let centerX = size.width * 0.56
            let centerY = size.height * 0.43
            let red = GraphicsContext.Shading.radialGradient(
                Gradient(colors: [.orange.opacity(0.42), .pink.opacity(0.2), .clear]),
                center: CGPoint(x: size.width * 0.18, y: centerY),
                startRadius: 0,
                endRadius: size.width * 0.65
            )
            let blue = GraphicsContext.Shading.radialGradient(
                Gradient(colors: [.cyan.opacity(0.36), .blue.opacity(0.18), .clear]),
                center: CGPoint(x: size.width * 0.9, y: centerY),
                startRadius: 0,
                endRadius: size.width * 0.58
            )
            context.fill(Path(CGRect(origin: .zero, size: size)), with: red)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: blue)

            for index in 0..<9 {
                let offset = CGFloat(index - 4)
                var path = Path()
                path.move(to: CGPoint(x: centerX + offset * 12, y: -30))
                path.addLine(to: CGPoint(x: centerX - 90 + offset * 19, y: size.height + 30))
                context.stroke(
                    path,
                    with: .linearGradient(
                        Gradient(colors: [.pink.opacity(0.05), .white.opacity(0.3), .cyan.opacity(0.05)]),
                        startPoint: CGPoint(x: centerX, y: 0),
                        endPoint: CGPoint(x: centerX, y: size.height)
                    ),
                    lineWidth: index == 4 ? 2.2 : 0.7
                )
            }
        }
        .blur(radius: 0.4)
        .overlay {
            LinearGradient(
                colors: [.black.opacity(0.08), .clear, .black.opacity(0.42)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
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

    private var theme: WorkspaceWorldTheme { .theme(for: workspace.kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                WorkspaceSystemIcon(isOmarchy: workspace.kind == .omarchy, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(workspace.name).font(.title3.weight(.semibold)).lineLimit(1)
                    Label(theme.eyebrow, systemImage: theme.symbol)
                        .font(.caption2.monospaced().weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(theme.accent)
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
                    .tint(theme.accent)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
        .background {
            ZStack {
                Rectangle().fill(.regularMaterial)
                LinearGradient(
                    colors: [theme.deep.opacity(0.72), theme.accent.opacity(0.13), .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                WorkspaceCardAtmosphere(kind: workspace.kind, accent: theme.accent)
            }
            .clipShape(.rect(cornerRadius: 18))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(
                    isDropTargeted ? theme.bright : theme.accent.opacity(0.56),
                    lineWidth: isDropTargeted ? 2 : 1
                )
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

private struct WorkspaceCardAtmosphere: View {
    let kind: RiftWorkspaceKind
    let accent: Color

    var body: some View {
        Canvas { context, size in
            if kind == .omarchy {
                for index in 0..<7 {
                    let x = size.width * (0.58 + CGFloat(index) * 0.065)
                    let height = size.height * (0.18 + CGFloat(index % 3) * 0.07)
                    var ember = Path()
                    ember.move(to: CGPoint(x: x, y: size.height))
                    ember.addCurve(
                        to: CGPoint(x: x + 12, y: size.height - height),
                        control1: CGPoint(x: x - 22, y: size.height - height * 0.35),
                        control2: CGPoint(x: x + 28, y: size.height - height * 0.7)
                    )
                    context.stroke(ember, with: .color(accent.opacity(0.13)), lineWidth: 2)
                }
            } else {
                for index in 0..<6 {
                    let inset = CGFloat(index) * 22
                    var shard = Path()
                    shard.move(to: CGPoint(x: size.width - inset, y: 0))
                    shard.addLine(to: CGPoint(x: size.width * 0.55 - inset * 0.25, y: size.height))
                    context.stroke(shard, with: .color(accent.opacity(0.11)), lineWidth: index == 0 ? 2 : 1)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct WorkspaceSummary {
    let hardware: String?
    let sharing: String
    let needsAttention: Bool

    init(workspace: RiftWorkspaceRecord) {
        if workspace.kind == .omarchy {
            let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: workspace.bundleURL)
            let profile = VMOmarchyProfile.production
            let resources = profile.resources(
                forHostMemory: ProcessInfo.processInfo.physicalMemory,
                activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount
            )
            let metadata = try? VMOmarchyWorkspaceManager(layout: layout).metadata()
            hardware = "\(metadata?.cpuCount ?? resources.cpuCount) CPU · \(Self.bytes(metadata?.memoryBytes ?? resources.memoryBytes)) memory · \(Self.bytes(profile.diskCapacityBytes)) disk"
            sharing = "RiftVM Shared · No host folders shared"
            needsAttention = VMOmarchyWorkspaceManager(layout: layout).inspect() != .ready
            return
        }
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
        workspace.kind == .omarchy
            ? VMOmarchyWorkspaceLayout(applicationSupportRoot: workspace.bundleURL).shared
            : VMManagedSharedFolder.url(for: workspace.bundleURL)
    }

    static func prepareManagedFolder(for workspace: RiftWorkspaceRecord) throws {
        if workspace.kind == .omarchy {
            try FileManager.default.createDirectory(
                at: managedFolderURL(for: workspace),
                withIntermediateDirectories: true
            )
            return
        }
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
