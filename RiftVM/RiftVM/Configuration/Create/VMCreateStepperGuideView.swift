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

/// One Omarchy preparation run: the resource and storage choices, the verified
/// factory download, and the machine it produces. The session outlives its window so a
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
        // Omarchy exchanges files through its own shared folder, so no host
        // directory is exposed to the guest.
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
            errorMessage = "Omarchy is already being prepared. Wait for it to finish, then try again."
            return
        }
        let checks: [any VMCreateStepperGuidePhaseHandler] = [
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
            // the slot to the Omarchy icon and switch the window to Omarchy's own
            // controls. There is nothing to choose between, so nothing waits for
            // a click.
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3).delay(0.55)) {
                meterOpacity = 0
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.2))
                guard session.phase == .ready else { return }
                finishPreparation()
            }
        }
        .task { await session.initialize() }
    }

    /// The window is the whole product, so this screen is a centred statement of
    /// what Omarchy is, two settings it is worth choosing, and one button. There
    /// is no name and no location to pick: both are fixed.
    private var setup: some View {
        VStack(spacing: 20) {
            VStack(spacing: 12) {
                workspaceIcon(size: 96)
                Text("Omarchy")
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                Text("A focused Arch Linux desktop, ready on first boot.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            VStack(spacing: 0) {
                DisclosureGroup(isExpanded: $showResources) {
                    CreateResourceControlsView().padding(.top, 14)
                } label: {
                    settingsRow(
                        title: "Resources",
                        detail: "\(session.config.cpuCount) CPU · \(session.config.memorySize / (1024 * 1024 * 1024)) GB memory · \(storageGiB) GB disk",
                        systemImage: "cpu"
                    )
                }
                Divider()
                DisclosureGroup(isExpanded: $showSharing) {
                    fileExchangeExplanation.padding(.top, 14)
                } label: {
                    settingsRow(
                        title: "File exchange",
                        detail: "One shared folder, both directions",
                        systemImage: "folder.badge.arrow.up"
                    )
                }
            }
            .padding(18)
            .frame(maxWidth: 520)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.5), lineWidth: 1)
            }

            VStack(spacing: 6) {
                Label("The signed image is downloaded, verified, and cached when you prepare.", systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Stored in \(NSString(string: savePath).abbreviatingWithTildeInPath)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("omarchy-storage-path")
            }
            .multilineTextAlignment(.center)

            if let error = session.errorMessage { errorView(error) }
        }
        .frame(maxWidth: .infinity)
    }

    private func settingsRow(title: String, detail: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: systemImage)
            Spacer(minLength: 12)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// What the shared folder is, on both sides, and what it is not.
    private var fileExchangeExplanation: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("On your Mac").font(.caption.weight(.semibold))
                    Text("RiftVM Shared")
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(.tint)
                    .padding(.top, 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text("In Omarchy").font(.caption.weight(.semibold))
                    Text("/mnt/riftvm-shared")
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            Text("It is one folder, shared both ways: add files on either side and the other sees them. Open Shared Folder reveals it on your Mac, and Import Files or dropping files on the window copies them in. Your other Mac folders stay private.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            if !session.form.logs.isEmpty { detailsDisclosure }
        }
        .frame(maxWidth: .infinity)
    }

    private var progressHeadline: String {
        switch session.phase {
        case .ready: "Omarchy is ready."
        case .failed: "Let’s get this back on track."
        default: "Preparing \(session.config.name)"
        }
    }

    private var progressSubheadline: String {
        switch session.phase {
        case .ready: "Start it whenever you are ready."
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
                 ? "64 GB disk · The signed image is downloaded and verified once."
                 : session.phase == .creating
                    ? "Creation continues if you close this window."
                    : session.phase == .failed
                        ? "Your settings are saved for this session."
                        : "Omarchy is ready.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            switch session.phase {
            case .setup:
                Button("Prepare Omarchy", systemImage: "arrow.up.right") { session.start() }
                    .buttonStyle(RiftCreationButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!session.initialized)
                    .accessibilityIdentifier("omarchy-prepare-start")
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

    private var storageGiB: UInt64 {
        let bytes = session.config.storageDevices.first(where: { $0.data.type == .Block })?.data.size
            ?? VMModelFieldStorageDevice.default().size
        return bytes / (1024 * 1024 * 1024)
    }
    /// The preparation finished: let the store forget the session and let the
    /// window show Omarchy itself.
    private func finishPreparation() {
        WorkspaceCreationStore.shared.remove(session)
        onCreated()
    }

    private func errorView(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            .accessibilityIdentifier("omarchy-prepare-error")
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
