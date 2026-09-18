import SwiftUI
import Observation

#if arch(arm64)
@MainActor
struct VMCreateStepperGuidePhaseContext {
    let formData: VMCreateViewStateObject
    let configData: VMConfigurationViewStateObject
}

@MainActor
protocol VMCreateStepperGuidePhaseHandler {
    func verifyForm(context: VMCreateStepperGuidePhaseContext) -> VMOSResultVoid
    func onStepMovedIn(context: VMCreateStepperGuidePhaseContext) async -> VMOSResultVoid
    func cancel(context: VMCreateStepperGuidePhaseContext)
}
extension VMCreateStepperGuidePhaseHandler {
    func cancel(context: VMCreateStepperGuidePhaseContext) {}
}

@MainActor @Observable
final class WorkspaceCreationStore {
    static let shared = WorkspaceCreationStore()
    var sessions: [WorkspaceCreationSession] = []
    var isCreating: Bool { sessions.contains { $0.phase == .creating } }
    func retain(_ session: WorkspaceCreationSession) {
        if !sessions.contains(where: { $0.id == session.id }) { sessions.append(session) }
    }
    func remove(_ session: WorkspaceCreationSession) {
        guard session.phase != .creating else { return }
        sessions.removeAll { $0.id == session.id }
    }
}

/// One Omarchy preparation run: the resource choices, the verified factory
/// download, and the workspace it produces. The session outlives its window so a
/// long download keeps going after the window is closed.
@MainActor @Observable
final class WorkspaceCreationSession: Identifiable {
    enum Phase { case setup, creating, ready, failed }
    let id = UUID()
    let form = VMCreateViewStateObject()
    let config: VMConfigurationViewStateObject
    var phase: Phase = .setup
    var errorMessage: String?
    var initialized = false
    private let creator = CreatePhaseCreatingViewHandler()
    private var task: Task<Void, Never>?
    var context: VMCreateStepperGuidePhaseContext { .init(formData: form, configData: config) }

    init() {
        config = VMConfigurationViewStateObject(configModel: VMConfigModel.createWithDefaultValues(osType: .linux))
        config.name = "Omarchy"
        config.remark = "Preinstalled Arch Linux desktop · ready on first boot"
        config.linuxFeatures = .recommended
        let resources = VMOmarchyProfile.production.resources(
            forHostMemory: ProcessInfo.processInfo.physicalMemory,
            activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount
        )
        config.cpuCount = resources.cpuCount
        config.memorySize = resources.memoryBytes
        // Omarchy exchanges files through the workspace-owned shared folder, so
        // no host directory is exposed to the guest.
        config.directorySharingDevices.removeAll()
    }

    func initialize() async {
        guard !initialized else { return }
        initialized = true
        _ = await CreatePhaseNameLocationViewHandler().onStepMovedIn(context: context)
    }

    func start() {
        guard phase != .creating else { return }
        errorMessage = nil
        if WorkspaceCreationStore.shared.sessions.contains(where: { $0.id != id && $0.phase == .creating }) {
            errorMessage = "Another workspace is being created. Wait for it to finish, then try again."
            return
        }
        let checks: [any VMCreateStepperGuidePhaseHandler] = [
            CreatePhaseSystemViewHandler(),
            CreatePhaseNameLocationViewHandler(),
            CreatePhaseConfigurationViewHandler()
        ]
        for check in checks {
            if case .failure(let message) = check.verifyForm(context: context) {
                errorMessage = message
                return
            }
        }
        phase = .creating
        WorkspaceCreationStore.shared.retain(self)
        task = Task { @MainActor [self] in
            let result = await creator.onStepMovedIn(context: context)
            form.canCancelCreation = false
            form.creationCancellationKind = nil
            switch result {
            case .success: phase = .ready
            case .failure(let message): errorMessage = message; phase = .failed
            }
            task = nil
        }
    }

    func cancel() { creator.cancel(context: context) }
}

/// The preparation half of the one window: the form, the verified download, and
/// the transition to the workspace once it exists.
struct WorkspaceCreationView: View {
    let session: WorkspaceCreationSession
    /// Called when the workspace exists and the window should show it.
    let onCreated: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showResources = false
    @State private var showSharing = false
    @State private var showDetails = false
    @State private var launchError: String?
    /// The meter holds the finished row for a beat before the ready icon takes
    /// the slot over.
    @State private var meterOpacity: Double = 1

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ScrollView {
                    Group {
                        if session.phase == .setup { setup }
                        else { progress }
                    }
                    .frame(maxWidth: 680)
                    .frame(maxWidth: .infinity)
                    .padding(32)
                    // Centering the short preparation status keeps it from
                    // hugging the top of the window; the taller setup form
                    // still grows past the viewport and scrolls.
                    .frame(minHeight: proxy.size.height, alignment: .center)
                    .transition(.opacity)
                }
            }
            Divider()
            footer
        }
        .background(.background)
        .disclosureGroupStyle(WorkspaceCreationDisclosureStyle())
        .environment(session.form)
        .environment(session.config)
        .frame(minWidth: 680, idealWidth: 760, minHeight: 590, idealHeight: 620)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: session.phase)
        .onChange(of: session.phase) { _, phase in
            guard phase == .ready else {
                meterOpacity = 1
                return
            }
            // The row is full and settled here; let it sit for a beat, then hand
            // the slot to the workspace icon.
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3).delay(0.55)) {
                meterOpacity = 0
            }
        }
        .task { await session.initialize() }
        .alert("Unable to Open Workspace", isPresented: Binding(get: { launchError != nil }, set: { if !$0 { launchError = nil } })) {
            Button("OK") { launchError = nil }
        } message: { Text(launchError ?? "") }
    }

    private var setup: some View {
        @Bindable var config = session.config
        return VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 18) {
                workspaceIcon(size: 60)
                VStack(alignment: .leading, spacing: 4) {
                    Text("YOUR NEXT WORKSPACE").font(.caption2).tracking(2).foregroundStyle(.secondary)
                    Text("Make room for Omarchy.")
                        .font(.largeTitle.weight(.semibold))
                    Text("Recommended settings. Your name. Ready to create.").foregroundStyle(.secondary)
                }
            }
            CreatePhaseSystemView()
                .frame(height: 220)
            VStack(alignment: .leading, spacing: 8) {
                Text("Workspace name").font(.callout).foregroundStyle(.secondary)
                TextField("Workspace name", text: $config.name)
                    .textFieldStyle(.roundedBorder).controlSize(.large)
                    .accessibilityIdentifier("workspace-create-name")
                HStack(alignment: .top) {
                    Image(systemName: "folder")
                    Text(NSString(string: savePath).abbreviatingWithTildeInPath)
                        .textSelection(.enabled).lineLimit(3)
                        .accessibilityIdentifier("workspace-create-path")
                    Spacer(minLength: 8)
                    Button("Change…") { chooseLocation() }.buttonStyle(.link)
                }.font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            DisclosureGroup(isExpanded: $showResources) {
                CreateResourceControlsView().padding(.top, 14)
            } label: {
                HStack {
                    Label("Resources", systemImage: "cpu")
                    Spacer()
                    Text("\(session.config.cpuCount) CPU · \(session.config.memorySize / (1024 * 1024 * 1024)) GB memory")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            DisclosureGroup(isExpanded: $showSharing) {
                Text("After creation, open RiftVM Shared on your Mac to add files. In Omarchy, open /mnt/riftvm-shared to use those same files. Your other Mac folders stay private.")
                    .font(.callout).foregroundStyle(.secondary).padding(.top, 8)
            } label: {
                Label("File exchange with your Mac · Ready to use", systemImage: "folder.badge.arrow.up")
            }
            if let error = session.errorMessage { errorView(error) }
        }
    }

    private var progress: some View {
        VStack(spacing: 20) {
            // A failed preparation shows only the explanation, so the meter does
            // not keep an empty row above it.
            if session.phase != .failed {
                ZStack {
                    CreateProgressMeter(
                        progress: session.phase == .ready ? 1 : session.form.installingProgress,
                        isActive: session.phase == .creating,
                        isSettled: session.phase == .ready
                    )
                    .opacity(meterOpacity)
                    if session.phase == .ready {
                        WorkspaceSystemIcon(size: 112)
                            .transition(.opacity.combined(with: .scale(scale: 0.86)))
                    }
                }
                .frame(height: session.phase == .ready ? 112 : VMCreateProgressMeterGeometry.rowHeight)
            }
            VStack(spacing: 6) {
                Text(progressHeadline)
                    .font(.largeTitle.weight(.semibold)).multilineTextAlignment(.center)
                Text(progressSubheadline)
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if session.phase == .creating { progressCard }
            if let error = session.errorMessage { errorView(error) }
            if session.phase == .ready { readyActions }
            if !session.form.logs.isEmpty { detailsDisclosure }
        }
        .frame(maxWidth: .infinity)
    }

    private var progressHeadline: String {
        switch session.phase {
        case .ready: "\(session.config.name) is ready."
        case .failed: "Let’s get this back on track."
        default: "Preparing \(session.config.name)"
        }
    }

    private var progressSubheadline: String {
        switch session.phase {
        case .ready: "Your other world starts here."
        case .failed: "Your choices are saved. Review the details below."
        default: "You can keep using RiftVM while this finishes."
        }
    }

    /// One card carries the live progress: the stage on the left, the transferred
    /// bytes and percentage on the right, the bar underneath.
    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(session.form.creationStage).font(.headline)
                Spacer(minLength: 0)
                if let received = session.form.downloadBytesReceived,
                   let expected = session.form.downloadBytesExpected, received < expected {
                    Text("\(Self.byteCount(received)) of \(Self.byteCount(expected)) · \(Self.percentage(received, of: expected))")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if let received = session.form.downloadBytesReceived,
               let expected = session.form.downloadBytesExpected, received < expected {
                ProgressView(value: Double(received), total: Double(max(expected, 1)))
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: 340, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).stroke(.quaternary, lineWidth: 1)
        }
    }

    private var readyActions: some View {
        VStack(spacing: 8) {
            Button("Open Omarchy", systemImage: "arrow.up.right") { launch() }
                .buttonStyle(RiftCreationButtonStyle())
                .tint(.blue).keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("workspace-create-launch")
            Text(NSString(string: savePath).abbreviatingWithTildeInPath)
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private var detailsDisclosure: some View {
        DisclosureGroup(isExpanded: $showDetails) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(session.form.logs) { entry in
                    Text("\(entry.time)  \(entry.log)").font(.caption).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
        } label: {
            Label("Details", systemImage: "text.alignleft")
        }
        .frame(maxWidth: 340)
    }

    private static func byteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private static func percentage(_ received: Int64, of expected: Int64) -> String {
        guard expected > 0 else { return "0%" }
        return "\(Int((Double(received) / Double(expected) * 100).rounded()))%"
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text(session.phase == .setup
                 ? "64 GB disk · Image downloads only if needed."
                 : session.phase == .creating
                    ? "Creation continues if you close this window."
                    : session.phase == .failed
                        ? "Your settings are saved for this session."
                        : "Omarchy is ready.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            switch session.phase {
            case .setup:
                Button("Create Omarchy", systemImage: "arrow.up.right") { session.start() }
                    .buttonStyle(RiftCreationButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!session.initialized)
                    .accessibilityIdentifier("workspace-create-start")
            case .creating:
                if session.form.canCancelCreation {
                    Button(VMCreationCancellationPolicy.buttonTitle(for: session.form.creationCancellationKind)) { session.cancel() }
                }
                // A long download continues in the background: the window can be
                // closed and the menu bar item keeps reporting it.
                Text("Creation continues if you close this window.")
                    .font(.caption).foregroundStyle(.secondary)
            case .failed:
                Button("Edit Settings") { session.phase = .setup }
                Button("Retry") { session.start() }.buttonStyle(.borderedProminent)
            case .ready:
                // The ready action sits with the finished meter above.
                EmptyView()
            }
        }.padding(22)
    }

    private var savePath: String {
        CreatePhaseNameLocationViewHandler.bundlePath(baseDirectory: session.form.baseDirectory, name: session.config.name)
    }
    private func chooseLocation() {
        MacKitUtil.selectDirectory(title: "Save Workspace In") { url in
            guard let url else { return }
            session.form.baseDirectory = url.path(percentEncoded: false)
        }
    }
    private func launch() {
        do {
            try ActiveWorkspaceStore.standard.adopt(
                bundleURL: URL(filePath: session.form.rootPath),
                name: session.config.name
            )
            WorkspaceCreationStore.shared.remove(session)
            onCreated()
        } catch { launchError = error.localizedDescription }
    }

    private func errorView(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            .accessibilityIdentifier("workspace-create-error")
    }
    private func workspaceIcon(size: CGFloat) -> some View {
        WorkspaceSystemIcon(size: size)
            .accessibilityHidden(true)
    }
}

private struct WorkspaceCreationDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.callout.weight(.semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    configuration.label
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(WorkspaceCreationDisclosureButtonStyle())
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(configuration.isExpanded ? "Collapse section" : "Expand section")

            if configuration.isExpanded {
                configuration.content
                    .padding(.horizontal, 10)
            }
        }
    }
}

private struct WorkspaceCreationDisclosureButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.primary.opacity(configuration.isPressed ? 0.10 : isHovered ? 0.05 : 0),
                        in: .rect(cornerRadius: 8))
            .onHover { isHovered = $0 }
    }
}

struct RiftCreationButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .padding(.horizontal, 22).padding(.vertical, 12)
            .foregroundStyle(.white)
            .background(LinearGradient(colors: [Color(red: 0.76, green: 0.22, blue: 0.22), Color(red: 0.47, green: 0.25, blue: 0.60), Color(red: 0.12, green: 0.36, blue: 0.65)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 10))
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#endif

/// Omarchy artwork: https://omarchy.org/brand/ (Omarchy trademark).
struct WorkspaceSystemIcon: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24)
                .fill(LinearGradient(
                    colors: [Color(white: 0.19), Color(white: 0.10)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            Image("OmarchyLogo")
                .resizable().scaledToFit()
                .frame(width: size * 0.60, height: size * 0.60)
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.24)
                .strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}
