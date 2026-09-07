import AppKit
import Foundation
import Observation

#if arch(arm64)
struct AppConfigModel {
    var rootPaths: [String]
}

@MainActor @Observable
final class AppConfigManager {
    static let newVMChangedNotification = Notification.Name("RiftVM.workspacesChanged")
    private var registry: WorkspaceRegistry?
    private(set) var errorMessage: String?
    var workspaces: [WorkspaceRecord] { registry?.workspaces ?? [] }
    var defaultID: UUID? { registry?.defaultID }
    var launchRoute: WorkspaceLaunchRoute { registry?.launchRoute ?? .choose }
    var appConfig: AppConfigModel {
        AppConfigModel(rootPaths: workspaces.filter { $0.profile != .omarchy }.map { $0.location.path })
    }

    init() { loadConfig() }

    func getRootPath() -> URL {
        if let override = ProcessInfo.processInfo.environment["RIFTVM_DATA_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RiftVM", isDirectory: true)
    }

    func getConfigPath() -> URL { getRootPath().appendingPathComponent("Workspaces.json") }

    func loadConfig() {
        do {
            registry = try WorkspaceRegistry(fileURL: getConfigPath())
            errorMessage = nil
        } catch {
            registry = nil
            errorMessage = "Could not read the workspace library: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func register(url: URL, profile: WorkspaceProfile) throws -> WorkspaceRecord {
        guard registry != nil else { throw CocoaError(.fileReadCorruptFile) }
        let record = try registry!.register(url, profile: profile)
        changed()
        return record
    }

    func setDefault(_ id: UUID?) {
        perform {
            guard registry != nil else { throw CocoaError(.fileReadCorruptFile) }
            try registry!.setDefault(id)
        }
    }

    func addVMPath(url: URL) {
        perform {
            let profile: WorkspaceProfile
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(WorkspaceIdentity.fileName).path) {
                profile = try WorkspaceIdentity.load(at: url).profile
            } else {
                switch VMModel.loadConfigFromFile(rootPath: url) {
                case .success(let model): profile = model.config.type == .macOS ? .macOS : .linux
                case .failure(let message): throw VMOSError.regularFailure(message)
                }
            }
            _ = try register(url: url, profile: profile)
        }
    }

    func removeVMPath(url: URL) {
        perform {
            guard let record = workspaces.first(where: { WorkspaceRegistry.canonical($0.location) == WorkspaceRegistry.canonical(url) }) else { return }
            try registry?.remove(record.id)
        }
    }

    func addVMPathWithSelect() {
        let panel = NSOpenPanel()
        panel.title = "Open a RiftVM workspace"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addVMPath(url: url)
    }

    func addVMPathWithRefresh(url: URL) { addVMPath(url: url) }
    func removeVMPathWithReload(url: URL) { removeVMPath(url: url) }

    private func perform(_ action: () throws -> Void) {
        do { try action(); changed() }
        catch {
            // An operation failure does not invalidate the loaded library.
            // Only loadConfig owns the persistent library error shown by ContentView.
            let alert = NSAlert()
            alert.messageText = "Workspace Library"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.newVMChangedNotification, object: nil)
    }
}

@MainActor let sharedAppConfigManager = AppConfigManager()
#endif
