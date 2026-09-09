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
    var isOmarchy: Bool { form.systemImageSelection == .preinstalled(.omarchy) }
    var context: VMCreateStepperGuidePhaseContext { .init(formData: form, configData: config) }

    init(kind: RiftWorkspaceKind?) {
        config = VMConfigurationViewStateObject(configModel: VMConfigModel.createWithDefaultValues(osType: kind == .omarchy ? .linux : .macOS))
        if kind == .omarchy {
            config.name = "Omarchy"
            config.remark = VMPreinstalledImageCatalogItem.omarchy.detail
            config.linuxFeatures = .recommended
            let resources = VMOmarchyProfile.production.resources(forHostMemory: ProcessInfo.processInfo.physicalMemory, activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount)
            config.cpuCount = resources.cpuCount
            config.memorySize = resources.memoryBytes
            form.systemImageSelection = .preinstalled(.omarchy)
            form.hasChosenSystem = true
            form.hasGeneratedNameSuggestion = true
        } else if kind == .macOS {
            form.hasChosenSystem = true
        }
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
        let checks: [any VMCreateStepperGuidePhaseHandler] = [CreatePhaseSystemViewHandler(), CreatePhaseNameLocationViewHandler(), CreatePhaseConfigurationViewHandler()]
        for check in checks {
            if case .failure(let message) = check.verifyForm(context: context) {
                errorMessage = message
                return
            }
        }
        if isOmarchy { config.directorySharingDevices.removeAll() }
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

struct VMCreateStepperGuideView: View {
    @State private var session: WorkspaceCreationSession
    init(initialKind: RiftWorkspaceKind? = nil) {
        _session = State(initialValue: WorkspaceCreationSession(kind: initialKind))
    }
    var body: some View { WorkspaceCreationView(session: session) }
}

struct WorkspaceCreationView: View {
    let session: WorkspaceCreationSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showImage = false
    @State private var showResources = false
    @State private var showSharing = false
    @State private var showDetails = false
    @State private var launchError: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Group {
                    if session.phase == .setup { setup }
                    else { progress }
                }
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
                .padding(32)
                .transition(.opacity)
            }
            Divider()
            footer
        }
        .background(.background)
        .environment(session.form)
        .environment(session.config)
        .frame(minWidth: 680, idealWidth: 760, minHeight: 590, idealHeight: 650)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: session.phase)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Close") { close() }
                    .help(session.phase == .creating ? "Creation continues in the background" : "Close this window")
                    .accessibilityIdentifier("create-guide-close")
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
                    Text(session.form.hasChosenSystem ? "Make room for \(session.isOmarchy ? "Omarchy" : "macOS")." : "Choose your next world.")
                        .font(.largeTitle.weight(.semibold))
                    Text("Recommended settings. Your name. Ready to create.").foregroundStyle(.secondary)
                }
            }
            if !session.form.hasChosenSystem {
                CreatePhaseSystemView()
                    .frame(height: 260)
            } else if !session.isOmarchy {
                DisclosureGroup("System image · \(session.form.systemImageSelection.title)", isExpanded: $showImage) {
                    CreatePhaseSystemView(initiallyShowingMacOSVersions: true).frame(height: 330)
                }
            }
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
                if session.isOmarchy {
                    CreateResourceControlsView().padding(.top, 14)
                } else {
                    CreatePhaseConfigurationView().padding(.top, 14)
                }
            } label: {
                HStack {
                    Text("Resources")
                    Spacer()
                    Text("\(session.config.cpuCount) CPU · \(session.config.memorySize / (1024 * 1024 * 1024)) GB memory")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            if session.isOmarchy {
                DisclosureGroup("File exchange with your Mac · Ready to use", isExpanded: $showSharing) {
                    Text("After creation, open RiftVM Shared on your Mac to add files. In Omarchy, open /mnt/riftvm-shared to use those same files. Your other Mac folders stay private.")
                        .font(.callout).foregroundStyle(.secondary).padding(.top, 8)
                }
            } else {
                DisclosureGroup("Share folders with your Mac", isExpanded: $showSharing) {
                    CreatePhaseSharingView().padding(.top, 8)
                }
            }
            if let error = session.errorMessage { errorView(error) }
        }
    }

    private var progress: some View {
        VStack(spacing: 18) {
            RiftCreationEffect(isReady: session.phase == .ready, isActive: session.phase == .creating, isOmarchy: session.isOmarchy)
                .frame(height: 190)
            Text(session.phase == .ready ? "\(session.config.name) is ready." : session.phase == .failed ? "Let’s get this back on track." : "Preparing \(session.config.name)")
                .font(.largeTitle.weight(.semibold)).multilineTextAlignment(.center)
            Text(session.phase == .ready ? "Your other world starts here." : session.phase == .failed ? "Your choices are saved. Review the details below." : "You can keep using RiftVM while this finishes.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            if session.phase == .creating {
                VStack(alignment: .leading, spacing: 10) {
                    Text(session.form.creationStage).font(.headline)
                    if let received = session.form.downloadBytesReceived, let expected = session.form.downloadBytesExpected, received < expected {
                        ProgressView(value: Double(received), total: Double(max(expected, 1)))
                        Text("\(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }.frame(maxWidth: 420).padding(.vertical, 12)
            }
            if let error = session.errorMessage { errorView(error) }
            if session.phase == .ready {
                Button("Launch \(session.config.name)", systemImage: "arrow.up.right") { launch() }
                    .buttonStyle(RiftCreationButtonStyle())
                    .tint(.blue).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("workspace-create-launch")
                Text(NSString(string: savePath).abbreviatingWithTildeInPath)
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if !session.form.logs.isEmpty {
                DisclosureGroup("Details", isExpanded: $showDetails) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(session.form.logs) { entry in
                            Text("\(entry.time)  \(entry.log)").font(.caption).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }.padding(.top, 12)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text(session.phase == .setup ? (session.isOmarchy ? "64 GB disk · Image downloads only if needed." : "The selected image downloads only if needed.") : session.phase == .creating ? "Keep RiftVM open. Follow progress on the home screen." : session.phase == .failed ? "Your settings are saved for this session." : "Available from your workspace list.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            switch session.phase {
            case .setup:
                Button("Create \(session.isOmarchy ? "Omarchy" : "Workspace")", systemImage: "arrow.up.right") { session.start() }
                    .buttonStyle(RiftCreationButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!session.initialized || !session.form.hasChosenSystem)
                    .accessibilityIdentifier("workspace-create-start")
            case .creating:
                if session.form.canCancelCreation {
                    Button(VMCreationCancellationPolicy.buttonTitle(for: session.form.creationCancellationKind)) { session.cancel() }
                }
                Button("Continue in Background") { close() }
            case .failed:
                Button("Dismiss") {
                    WorkspaceCreationStore.shared.remove(session)
                    dismiss()
                }
                Button("Edit Settings") { session.phase = .setup }
                Button("Retry") { session.start() }.buttonStyle(.borderedProminent)
            case .ready:
                Button("Back to Workspaces") { close() }
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
    private func close() {
        if session.phase == .ready || session.phase == .setup { WorkspaceCreationStore.shared.remove(session) }
        openWindow(id: "control-center")
        dismiss()
    }
    private func launch() {
        do {
            let record = try RiftWorkspaceRegistryStore.standard.registerIfNeeded(name: session.config.name, kind: session.isOmarchy ? .omarchy : .macOS, bundleURL: URL(filePath: session.form.rootPath))
            guard let workspace = record.workspaces.first(where: { $0.bundleURL.standardizedFileURL == URL(filePath: session.form.rootPath).standardizedFileURL }) else {
                launchError = "The workspace could not be found. Open it from the control center."
                return
            }
            openWindow(id: "workspace", value: workspace.id)
            WorkspaceCreationStore.shared.remove(session)
            dismiss()
        } catch { launchError = error.localizedDescription }
    }
    private func errorView(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            .accessibilityIdentifier("workspace-create-error")
    }
    private func workspaceIcon(size: CGFloat) -> some View {
        Image(systemName: session.isOmarchy ? "sparkles.rectangle.stack" : "apple.logo")
            .font(.system(size: size * 0.45)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [.red, .purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 18))
            .accessibilityHidden(true)
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

struct RiftCreationEffect: View {
    let isReady: Bool
    let isActive: Bool
    let isOmarchy: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || !isActive || scenePhase != .active)) { context in
            let breath = reduceMotion || !isActive ? 0.5 : (sin(context.date.timeIntervalSinceReferenceDate * 1.7) + 1) / 2
            ZStack {
                ForEach(0..<2) { index in
                    let color: Color = index == 0 ? .red : .blue
                    Capsule().fill(color.opacity(0.22))
                        .frame(width: 32, height: 142).blur(radius: 22)
                        .offset(x: index == 0 ? -15 : 15)
                    Capsule().fill(color.gradient)
                        .frame(width: 3, height: 132)
                        .shadow(color: color.opacity(0.6), radius: 12)
                        .rotationEffect(.degrees(24))
                        .offset(x: (index == 0 ? -1 : 1) * (isReady ? 74 : 6))
                        .scaleEffect(y: 0.85 + breath * 0.15)
                        .opacity(isReady ? 0.3 : 0.65 + breath * 0.35)
                }
                if isReady {
                    Image(systemName: isOmarchy ? "sparkles.rectangle.stack" : "apple.logo")
                        .font(.system(size: 42)).foregroundStyle(.white)
                        .frame(width: 112, height: 112)
                        .background(LinearGradient(colors: [.red, .purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 28))
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: isReady)
        .accessibilityHidden(true)
    }
}
#endif
