import AppKit
import Foundation
import SwiftUI

#if arch(arm64)
struct WorkspaceControlCenterView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var snapshot: RiftWorkspaceRegistrySnapshot?
    @State private var errorMessage: String?
    @State private var graphicsWorkspace: RiftWorkspaceRecord?
    @State private var snapshotWorkspace: RiftWorkspaceRecord?
    @State private var renameWorkspace: RiftWorkspaceRecord?
    @State private var renameDraft = ""
    @State private var deleteWorkspace: RiftWorkspaceRecord?
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
        .sheet(item: $graphicsWorkspace) { OmarchyGraphicsSettingsView(workspace: $0) }
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
            deleteConfirmationTitle,
            isPresented: deletePresented,
            titleVisibility: .visible
        ) {
            Button(deleteTargetIsMissing ? "Remove from List" : "Move to Trash", role: .destructive) { moveWorkspaceToTrash() }
            Button("Cancel", role: .cancel) { deleteWorkspace = nil }
        } message: {
            Text(deleteTargetIsMissing
                ? "The workspace folder is already missing from disk, so only this entry is removed."
                : "The virtual machine bundle can be recovered from the Trash.")
        }
        .alert("RiftVM", isPresented: errorPresented) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func controlCenter(_ snapshot: RiftWorkspaceRegistrySnapshot) -> some View {
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Prepare Omarchy", systemImage: "sparkles.rectangle.stack") {
                    prepareOmarchy()
                }
                .help("Download the verified Omarchy image and create a workspace")
                .accessibilityIdentifier("prepare-omarchy")
            }
        }
    }

    @ViewBuilder
    private func dashboard(_ snapshot: RiftWorkspaceRegistrySnapshot) -> some View {
        if snapshot.workspaces.isEmpty {
            WorkspaceControlCenterWelcomeView(prepareOmarchy: prepareOmarchy)
        } else {
            ZStack {
                WorkspaceWorldBackdrop()
                    .accessibilityHidden(true)

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Your Workspaces")
                                .font(.largeTitle.bold())
                                .foregroundStyle(
                                    .linearGradient(
                                        colors: [.primary, .primary, WorkspaceWorldTheme.fire.accent],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                            Text("Each workspace is an independent Arch Linux machine, ready on first boot.")
                                .foregroundStyle(.secondary)
                        }
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 18)],
                            alignment: .leading,
                            spacing: 18
                        ) {
                            ForEach(sortedWorkspaces(in: snapshot)) { workspace in
                                WorkspaceCardView(
                                    workspace: workspace,
                                    summary: WorkspaceSummary(workspace: workspace),
                                    liveMachine: VMLiveMachineCenter.shared.machines.first {
                                        $0.rootPath == workspace.bundleURL.standardizedFileURL
                                    },
                                    runPhase: VMRunningRegistry.shared.phase(rootPath: workspace.bundleURL),
                                    isRunning: VMRunningRegistry.shared.isRunning(rootPath: workspace.bundleURL),
                                    open: { open(workspace) },
                                    showSettings: { showSettings(for: workspace) },
                                    togglePinned: { setPinned(workspace, pinned: workspace.pinnedAt == nil) },
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

    private func sortedWorkspaces(in snapshot: RiftWorkspaceRegistrySnapshot) -> [RiftWorkspaceRecord] {
        snapshot.workspaces.sorted { lhs, rhs in
            switch (lhs.pinnedAt, rhs.pinnedAt) {
            case (.some(let left), .some(let right)): left > right
            case (.some, .none): true
            case (.none, .some): false
            case (.none, .none): (lhs.lastOpenedAt ?? lhs.createdAt) > (rhs.lastOpenedAt ?? rhs.createdAt)
            }
        }
    }

    private func prepareOmarchy() {
        openWindow(id: "create-machine-guide")
    }

    private func open(_ workspace: RiftWorkspaceRecord) {
        do {
            try WorkspaceSharing.prepareManagedFolder(for: workspace)
            snapshot = try registry.markOpened(workspace.id)
            openWindow(id: "workspace", value: workspace.id)
        } catch { errorMessage = error.localizedDescription }
    }

    private func showSettings(for workspace: RiftWorkspaceRecord) {
        graphicsWorkspace = workspace
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
            // A bundle that is already gone has nothing to trash, but its
            // registry record must still be removable. Otherwise the card
            // stays in the list and every removal attempt reports
            // "The file … doesn't exist." forever.
            try RiftWorkspaceBundleRemoval.moveToTrashIfPresent(workspace.bundleURL)
            snapshot = try registry.unregister(workspace.id)
            deleteWorkspace = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func receiveDrop(_ urls: [URL], on workspace: RiftWorkspaceRecord) -> Bool {
        let candidates = urls.filter { url in
            FileManager.default.fileExists(atPath: url.path) || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        guard !candidates.isEmpty else { return false }
        do {
            try WorkspaceSharing.copy(candidates, into: workspace)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
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
    /// A registered workspace can lose its bundle without RiftVM noticing: the
    /// folder may have been removed in Finder, or wiped when Application
    /// Support was reset. Such an entry can only be removed from the list,
    /// because there is nothing left to move to the Trash.
    private var deleteTargetIsMissing: Bool {
        guard let bundleURL = deleteWorkspace?.bundleURL else { return false }
        return !FileManager.default.fileExists(atPath: bundleURL.path)
    }
    private var deleteConfirmationTitle: String {
        let name = deleteWorkspace?.name ?? "this workspace"
        return deleteTargetIsMissing ? "Remove \"\(name)\" from the list?" : "Move \(name) to the Trash?"
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
        // Title the window after the workspace itself, so the title bar says
        // which world this is instead of the generic scene name.
        .navigationTitle(workspace?.name ?? "Workspace")
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
        OmarchyRootView(
            profile: .production,
            workspaceManager: VMOmarchyWorkspaceManager(
                layout: VMOmarchyWorkspaceLayout(applicationSupportRoot: workspace.bundleURL)
            )
        )
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
        eyebrow: "OMARCHY WORKSPACE",
        symbol: "flame.fill"
    )
    static let ice = WorkspaceWorldTheme(
        accent: Color(red: 0.14, green: 0.72, blue: 1),
        bright: Color(red: 0.64, green: 0.94, blue: 1),
        deep: Color(red: 0.015, green: 0.10, blue: 0.28),
        eyebrow: "RIFT WORLD",
        symbol: "snowflake"
    )
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
    let prepareOmarchy: () -> Void

    var body: some View {
        ZStack {
            WorkspaceRiftBackdrop()
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("APPLE SILICON  /  ARCH LINUX  /  ONE MAC")
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
                    Text("A workspace is an independent Omarchy virtual machine. Prepare one to begin.")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.72))
                        .padding(.top, 2)
                }

                WorkspaceControlCenterCreationCard(
                    title: "Omarchy",
                    description: "A focused Arch Linux desktop, ready on first boot.",
                    badge: "PREPARE",
                    action: prepareOmarchy
                )
                .frame(maxWidth: 440)
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                WorkspaceSystemIcon(size: 54)
                Text(title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.67))
                    .lineLimit(2, reservesSpace: true)
                Label(badge, systemImage: "arrow.down.circle")
                    .font(.caption.monospaced().weight(.bold))
                    .tracking(1.1)
                    .foregroundStyle(WorkspaceWorldTheme.fire.bright)
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
                .stroke(WorkspaceWorldTheme.fire.accent.opacity(0.62), lineWidth: 1.5)
        }
        .shadow(color: WorkspaceWorldTheme.fire.accent.opacity(0.12), radius: 24)
        .accessibilityLabel("Prepare an Omarchy Workspace")
        .accessibilityHint(description)
        .accessibilityIdentifier("prepare-omarchy-welcome")
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
    let liveMachine: VMLiveMachine?
    let runPhase: VMRunPhase?
    let isRunning: Bool
    let open: () -> Void
    let showSettings: () -> Void
    let togglePinned: () -> Void
    let showSnapshots: () -> Void
    let reveal: () -> Void
    let rename: () -> Void
    let delete: () -> Void
    let receiveDrop: ([URL]) -> Bool
    @State private var isDropTargeted = false

    private var theme: WorkspaceWorldTheme { .fire }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                WorkspaceSystemIcon(size: 44)
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
            Button(action: showSettings) {
                Label(summary.sharing, systemImage: "folder")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Display and shared-folder settings for this workspace")
            // Cards share a minimum height so a grid row lines up, so the
            // slack belongs above the action row: letting the VStack end at
            // the button left the empty space *below* it, which read as a
            // rendering mistake rather than as padding.
            Spacer(minLength: 0)
            actionRow
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
                WorkspaceCardAtmosphere(accent: theme.accent)
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
            Button(bundleIsMissing ? "Remove from List" : "Move to Trash", systemImage: "trash", role: .destructive, action: delete)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(workspace.name), \(statusTitle)")
    }

    /// Start or open the workspace, then pause, resume, and stop it without
    /// leaving the control center.
    private var actionRow: some View {
        HStack(spacing: 8) {
            if let date = workspace.lastOpenedAt, !isRunning {
                Text("Opened \(date, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if let liveMachine {
                if liveMachine.canResume {
                    Button("Resume", systemImage: "play.fill") { liveMachine.resumeAction() }
                        .help("Resume this workspace")
                } else if liveMachine.canPause {
                    Button("Pause", systemImage: "pause.fill") { liveMachine.pauseAction() }
                        .help("Pause this workspace")
                }
                Button("Stop", systemImage: "stop.fill", role: .destructive) { liveMachine.stopAction() }
                    .disabled(!liveMachine.canStop)
                    .help("Stop this workspace")
            }
            Button(isRunning ? "Open" : "Start", systemImage: isRunning ? "macwindow.on.rectangle" : "play.fill", action: open)
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
        }
    }

    private var statusTitle: String { runPhase?.cardLabel ?? (isRunning ? "Running" : summary.needsAttention ? "Needs Attention" : "Stopped") }
    private var statusImage: String { isRunning ? "circle.fill" : summary.needsAttention ? "exclamationmark.triangle.fill" : "circle" }
    private var statusColor: Color { isRunning ? .green : summary.needsAttention ? .orange : .secondary }
    private var bundleIsMissing: Bool { !FileManager.default.fileExists(atPath: workspace.bundleURL.path) }
}

private struct WorkspaceCardAtmosphere: View {
    let accent: Color

    var body: some View {
        Canvas { context, size in
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
    }

    private static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }
}

private enum WorkspaceSharingError: LocalizedError {
    case unsupportedItem(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedItem(let name): "RiftVM cannot copy the symbolic link “\(name)”."
        }
    }
}

@MainActor
private enum WorkspaceSharing {
    static func managedFolderURL(for workspace: RiftWorkspaceRecord) -> URL {
        VMOmarchyWorkspaceLayout(applicationSupportRoot: workspace.bundleURL).shared
    }

    static func prepareManagedFolder(for workspace: RiftWorkspaceRecord) throws {
        try FileManager.default.createDirectory(
            at: managedFolderURL(for: workspace),
            withIntermediateDirectories: true
        )
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
}

#Preview { WorkspaceControlCenterView() }
#endif
