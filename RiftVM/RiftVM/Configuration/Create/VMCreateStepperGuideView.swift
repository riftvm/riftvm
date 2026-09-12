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
        .disclosureGroupStyle(WorkspaceCreationDisclosureStyle())
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
                    Label("Resources", systemImage: "cpu")
                    Spacer()
                    Text("\(session.config.cpuCount) CPU · \(session.config.memorySize / (1024 * 1024 * 1024)) GB memory")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            if session.isOmarchy {
                DisclosureGroup(isExpanded: $showSharing) {
                    Text("After creation, open RiftVM Shared on your Mac to add files. In Omarchy, open /mnt/riftvm-shared to use those same files. Your other Mac folders stay private.")
                        .font(.callout).foregroundStyle(.secondary).padding(.top, 8)
                } label: {
                    Label("File exchange with your Mac · Ready to use", systemImage: "folder.badge.arrow.up")
                }
            } else {
                DisclosureGroup(isExpanded: $showSharing) {
                    CreatePhaseSharingView().padding(.top, 8)
                } label: {
                    Label("Share folders with your Mac", systemImage: "folder")
                }
            }
            if let error = session.errorMessage { errorView(error) }
        }
    }

    private var progress: some View {
        VStack(spacing: 18) {
            RiftCreationEffect(
                isReady: session.phase == .ready,
                isActive: session.phase == .creating,
                isOmarchy: session.isOmarchy,
                progress: session.form.installingProgress
            )
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
                DisclosureGroup(isExpanded: $showDetails) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(session.form.logs) { entry in
                            Text("\(entry.time)  \(entry.log)").font(.caption).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                } label: {
                    Label("Details", systemImage: "text.alignleft")
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
        WorkspaceSystemIcon(isOmarchy: session.isOmarchy, size: size)
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

/// A rift of light that tears open while a workspace is being prepared.
///
/// `progress` is the real creation progress (0...1) rather than a decorative
/// loop, so the seam doubles as a progress indicator: the two lit lips and the
/// light spilling between them widen as the download and install advance, then
/// the open seam reveals the workspace icon once creation finishes.
struct RiftCreationEffect: View {
    let isReady: Bool
    let isActive: Bool
    let isOmarchy: Bool
    var progress: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// Geometry of the seam. The width only has to be wider than the open lens;
    /// the travelling highlights use the height to walk along the lips.
    private static let seamHeight: Double = 150
    private static let seamWidth: Double = 360

    private var isAnimating: Bool { isActive && !reduceMotion && scenePhase == .active }

    /// Eased so the first bytes of a long download already move the seam.
    private var openness: Double { pow(min(max(progress, 0), 1), 0.65) }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimating)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let breath = isAnimating ? (sin(time * 1.7) + 1) / 2 : 0.5
            let waist = seamWaist(breath: breath)
            let energy = isReady ? 0.5 : 0.2 + openness * 0.7
            ZStack {
                rift(waist: waist, energy: energy, time: time)
                if isReady {
                    WorkspaceSystemIcon(isOmarchy: isOmarchy, size: 112)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.82).combined(with: .opacity))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: isReady)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.45), value: progress)
        .accessibilityHidden(true)
    }

    /// Half the width of the seam at its waist.
    private func seamWaist(breath: Double) -> Double {
        isReady ? 78 : 5 + openness * 38 + breath * 1.8
    }

    private func rift(waist: Double, energy: Double, time: Double) -> some View {
        ZStack {
            riftGlow(waist: waist, energy: energy)
            riftLight(waist: waist, energy: energy)
            riftLip(direction: -1, waist: waist, color: .red, energy: energy, time: time, travelsDown: true)
            riftLip(direction: 1, waist: waist, color: .blue, energy: energy, time: time, travelsDown: false)
            riftSparks(waist: waist, energy: energy, time: time)
        }
        .rotationEffect(.degrees(-4))
        .opacity(isActive || isReady ? 1 : 0.45)
    }

    /// Light the rift casts into this world.
    private func riftGlow(waist: Double, energy: Double) -> some View {
        RiftLens(waist: waist * 1.7)
            .fill(LinearGradient(stops: [
                .init(color: Color.red.opacity(0.9), location: 0),
                .init(color: Color.red.opacity(0.1), location: 0.45),
                .init(color: Color.blue.opacity(0.1), location: 0.55),
                .init(color: Color.blue.opacity(0.9), location: 1)
            ], startPoint: .leading, endPoint: .trailing))
            .frame(width: max(waist * 3.4, 4), height: Self.seamHeight * 1.16)
            .blur(radius: 26)
            .opacity(0.3 + energy * 0.55)
    }

    /// The light of the other side escaping through the open seam. The gradient
    /// is laid out across the lens itself, so each lip keeps its own colour and
    /// the middle stays a soft blend rather than a white bar.
    private func riftLight(waist: Double, energy: Double) -> some View {
        ZStack {
            RiftLens(waist: waist)
                .fill(LinearGradient(stops: [
                    .init(color: Color.red.opacity(0.95), location: 0),
                    .init(color: Color.red.opacity(0.5), location: 0.22),
                    .init(color: Color.white.opacity(0.3), location: 0.5),
                    .init(color: Color.blue.opacity(0.5), location: 0.78),
                    .init(color: Color.blue.opacity(0.95), location: 1)
                ], startPoint: .leading, endPoint: .trailing))
                .frame(width: max(waist * 2, 2), height: Self.seamHeight)
                .blur(radius: 6 + waist * 0.12)
                .opacity(0.35 + energy * 0.5)
            RiftLens(waist: max(waist * 0.5, 1))
                .fill(Color.white.opacity(0.9))
                .frame(width: max(waist, 2), height: Self.seamHeight * 0.92)
                .blur(radius: 3)
                .opacity(0.12 + energy * 0.3)
        }
    }

    /// One lit lip of the seam, with energy running along it.
    private func riftLip(
        direction: Double,
        waist: Double,
        color: Color,
        energy: Double,
        time: Double,
        travelsDown: Bool
    ) -> some View {
        let phase = (time * 0.4).truncatingRemainder(dividingBy: 1)
        let travel = travelsDown ? phase : 1 - phase
        return ZStack {
            RiftLip(direction: direction, waist: waist)
                .stroke(
                    LinearGradient(
                        colors: [color.opacity(0.35), color, color.opacity(0.35)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    style: StrokeStyle(lineWidth: 2.6, lineCap: .round)
                )
                .frame(width: Self.seamWidth, height: Self.seamHeight)
                .shadow(color: color.opacity(0.9), radius: 10)
            Circle().fill(Color.white.opacity(0.95))
                .frame(width: 3.4, height: 3.4)
                .blur(radius: 1.6)
                .shadow(color: color, radius: 8)
                .offset(
                    x: direction * 4 * waist * travel * (1 - travel),
                    y: Self.seamHeight / 2 * (2 * travel - 1)
                )
                .opacity(isAnimating ? 0.3 + energy * 0.6 : 0)
        }
        .opacity(isReady ? 0.45 : 1)
    }

    /// Motes drifting out of the seam.
    private func riftSparks(waist: Double, energy: Double, time: Double) -> some View {
        ZStack {
            ForEach(0..<7, id: \.self) { index in
                let seed = Double(index)
                let life = (time * 0.35 + seed / 7).truncatingRemainder(dividingBy: 1)
                let side: Double = index.isMultiple(of: 2) ? -1 : 1
                Circle()
                    .fill(side < 0 ? Color.red : Color.blue)
                    .frame(width: 2.6, height: 2.6)
                    .blur(radius: 0.8)
                    .offset(
                        x: side * (waist + 3 + life * 22),
                        y: sin((seed + 1) * 2.4) * 58 + (life - 0.5) * 26
                    )
                    .opacity(isAnimating ? (1 - life) * (0.12 + energy * 0.45) : 0)
            }
        }
    }
}

/// One lip of the seam: a shallow bow, widest at the waist.
private struct RiftLip: Shape {
    var direction: Double
    var waist: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control: CGPoint(x: rect.midX + direction * waist * 2, y: rect.midY)
        )
        return path
    }
}

/// The lens of light held between the two lips.
private struct RiftLens: Shape {
    var waist: Double

    func path(in rect: CGRect) -> Path {
        var path = RiftLip(direction: -1, waist: waist).path(in: rect)
        path.addQuadCurve(
            to: CGPoint(x: rect.midX, y: rect.minY),
            control: CGPoint(x: rect.midX + waist * 2, y: rect.midY)
        )
        path.closeSubpath()
        return path
    }
}
#endif

/// Omarchy artwork: https://omarchy.org/brand/ (Omarchy trademark).
struct WorkspaceSystemIcon: View {
    let isOmarchy: Bool
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24)
                .fill(LinearGradient(
                    colors: isOmarchy ? [Color(white: 0.19), Color(white: 0.10)] : [Color(white: 0.98), Color(white: 0.78)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            if isOmarchy {
                Image("OmarchyLogo")
                    .resizable().scaledToFit()
                    .frame(width: size * 0.60, height: size * 0.60)
            } else {
                Image(systemName: "apple.logo")
                    .font(.system(size: size * 0.48, weight: .regular))
                    .foregroundStyle(Color(white: 0.20))
            }
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.24)
                .strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}
