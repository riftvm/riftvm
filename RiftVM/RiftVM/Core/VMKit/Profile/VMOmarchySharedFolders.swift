import Foundation
import Virtualization

/// One Mac folder shared with Omarchy.
public struct VMOmarchySharedFolder: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var path: URL
    public var readOnly: Bool

    public init(id: UUID = UUID(), path: URL, readOnly: Bool = false) {
        self.id = id
        self.path = path.standardizedFileURL
        self.readOnly = readOnly
    }
}

/// The Mac folders a machine shares, kept beside the machine bundle rather than
/// inside `Workspace/`, so restoring a recovery point never rolls them back.
public struct VMOmarchySharedFolderSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var folders: [VMOmarchySharedFolder]

    public init(folders: [VMOmarchySharedFolder]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.folders = folders
    }

    /// The folder Open Shared Folder reveals and Import Files copies into: the
    /// first one Omarchy can write to.
    public var primaryFolder: VMOmarchySharedFolder? {
        folders.first { !$0.readOnly }
    }
}

public enum VMOmarchySharedFolderStore {
    /// The folder a new machine shares unless the user picks another one:
    /// `~/riftvm-shared`. A machine under the temporary directory (acceptance
    /// and tests) gets a sibling instead, so it never touches the real home.
    public static func defaultFolder(
        forBundle bundleURL: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let bundle = bundleURL.standardizedFileURL
        let base = VMOmarchyTemporaryPathPolicy.contains(bundle)
            ? bundle.deletingLastPathComponent()
            : homeDirectory
        return base.appending(path: defaultFolderName, directoryHint: .isDirectory).standardizedFileURL
    }

    public static let defaultFolderName = "riftvm-shared"

    public static func load(
        layout: VMOmarchyWorkspaceLayout,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> VMOmarchySharedFolderSettings {
        if let settings = loadIfPresent(layout: layout) {
            return settings
        }
        let settings = VMOmarchySharedFolderSettings(folders: [
            VMOmarchySharedFolder(path: defaultFolder(
                forBundle: layout.applicationSupportRoot,
                homeDirectory: homeDirectory
            )),
        ])
        try? save(settings, layout: layout)
        return settings
    }

    /// The saved settings, or nil when the machine has none yet.
    public static func loadIfPresent(layout: VMOmarchyWorkspaceLayout) -> VMOmarchySharedFolderSettings? {
        guard let data = try? Data(contentsOf: layout.sharedFolderSettings),
              let settings = try? JSONDecoder().decode(VMOmarchySharedFolderSettings.self, from: data),
              settings.schemaVersion <= VMOmarchySharedFolderSettings.currentSchemaVersion else { return nil }
        return settings
    }

    public static func save(_ settings: VMOmarchySharedFolderSettings, layout: VMOmarchyWorkspaceLayout) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: layout.sharedFolderSettings.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(settings).write(to: layout.sharedFolderSettings, options: .atomic)
    }

    /// Creates each writable folder that does not exist yet. A missing
    /// read-only folder is left alone and skipped by the share plan.
    public static func prepareFolders(_ settings: VMOmarchySharedFolderSettings, fileManager: FileManager = .default) {
        for folder in settings.folders where !folder.readOnly {
            try? fileManager.createDirectory(
                at: folder.path,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
        }
    }
}

/// How the `riftvm_shared` VirtioFS device is laid out for one session, and
/// where the Host stages clipboard items so the Guest finds them.
public struct VMOmarchySharePlan: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        /// Directory name under `/mnt/riftvm-shared`.
        public let name: String
        public let folder: VMOmarchySharedFolder
    }

    public static let guestMountPoint = "/mnt/riftvm-shared"
    /// Share entry the Host owns. The Agent takes clipboard items only there,
    /// because the root of the share holds the user's folders.
    public static let stagingEntryName = ".riftvm"
    /// Prefix of a staged clipboard item's path relative to the mount point.
    public static let clipboardRelativePrefix = stagingEntryName + "/"

    /// The settings this plan was made from.
    public let settings: VMOmarchySharedFolderSettings
    /// User folders, in order, with the Guest directory each one appears as.
    public let entries: [Entry]
    /// Host directory the clipboard stages items in.
    public let clipboardStaging: URL

    /// - Parameter transfer: RiftVM's own staging folder for this machine.
    public init(
        settings: VMOmarchySharedFolderSettings,
        transfer: URL,
        fileManager: FileManager = .default
    ) {
        self.settings = settings
        self.clipboardStaging = transfer
        let available = settings.folders.filter { folder in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: folder.path.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        var used: Set<String> = [Self.stagingEntryName]
        entries = available.map { folder in
            Entry(name: Self.uniqueName(for: folder.path, used: &used), folder: folder)
        }
    }

    /// The directory share for the `riftvm_shared` device.
    public func makeShare(transfer: URL) -> VZDirectoryShare {
        var directories = [Self.stagingEntryName: VZSharedDirectory(url: transfer, readOnly: false)]
        for entry in entries {
            directories[entry.name] = VZSharedDirectory(url: entry.folder.path, readOnly: entry.folder.readOnly)
        }
        return VZMultipleDirectoryShare(directories: directories)
    }

    /// Where Omarchy sees a folder, or nil when this session does not share it.
    public func guestPath(for folder: VMOmarchySharedFolder) -> String? {
        guard let entry = entries.first(where: { $0.folder.id == folder.id }) else { return nil }
        return "\(Self.guestMountPoint)/\(entry.name)"
    }

    static func uniqueName(for path: URL, used: inout Set<String>) -> String {
        var base = path.lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasPrefix(".") { base.removeFirst() }
        if base.isEmpty { base = "folder" }
        var name = base
        var suffix = 2
        while used.contains(name) || (try? VZMultipleDirectoryShare.validateName(name)) == nil {
            name = "\(base)-\(suffix)"
            suffix += 1
        }
        used.insert(name)
        return name
    }
}
