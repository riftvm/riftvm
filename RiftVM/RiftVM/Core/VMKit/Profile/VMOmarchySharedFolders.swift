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
    /// Set once the machine's Agent accepted clipboard items in the `.riftvm`
    /// staging folder. Until then the machine keeps the single-folder layout
    /// its Agent understands.
    public var guestSupportsMultipleFolders: Bool

    public init(
        folders: [VMOmarchySharedFolder],
        guestSupportsMultipleFolders: Bool = false
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.folders = folders
        self.guestSupportsMultipleFolders = guestSupportsMultipleFolders
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
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> VMOmarchySharedFolderSettings {
        if let data = try? Data(contentsOf: layout.sharedFolderSettings),
           let settings = try? JSONDecoder().decode(VMOmarchySharedFolderSettings.self, from: data),
           settings.schemaVersion <= VMOmarchySharedFolderSettings.currentSchemaVersion {
            return settings
        }
        let settings = VMOmarchySharedFolderSettings(
            folders: [VMOmarchySharedFolder(path: adoptLegacyFolder(
                layout: layout,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            ))]
        )
        try? save(settings, layout: layout)
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

    /// A machine from an earlier release kept its one exchange folder at
    /// `layout.shared` (`RiftVM Shared` beside the bundle, or `Shared` inside
    /// it). Move it to the new default when that is free and on the same
    /// volume, so files already exchanged stay where the user now looks;
    /// otherwise keep sharing the old folder rather than an empty new one.
    static func adoptLegacyFolder(
        layout: VMOmarchyWorkspaceLayout,
        homeDirectory: URL,
        fileManager: FileManager
    ) -> URL {
        let target = defaultFolder(forBundle: layout.applicationSupportRoot, homeDirectory: homeDirectory)
        let legacy = layout.shared
        var isDirectory: ObjCBool = false
        guard legacy != target,
              fileManager.fileExists(atPath: legacy.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return target }
        guard !fileManager.fileExists(atPath: target.path) else { return legacy }
        do {
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: legacy, to: target)
            return target
        } catch {
            return legacy
        }
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
        /// Directory name under `/mnt/riftvm-shared`; empty for the root.
        public let name: String
        public let folder: VMOmarchySharedFolder
    }

    public static let guestMountPoint = "/mnt/riftvm-shared"
    /// Share entry the Host owns in the multi-folder layout. The Agent accepts
    /// clipboard items in it (`clipboard-staging-directory-v1`).
    public static let stagingEntryName = ".riftvm"
    public static let multipleFoldersCapability = "clipboard-staging-directory-v1"

    public let isMultiple: Bool
    /// User folders, in order, with the Guest directory each one appears as.
    public let entries: [Entry]
    /// Host directory the clipboard stages items in.
    public let clipboardStaging: URL
    /// Prefix of a staged item's path relative to the Guest mount point.
    public let clipboardRelativePrefix: String

    /// - Parameter transfer: RiftVM's own staging folder for this machine.
    public init(
        settings: VMOmarchySharedFolderSettings,
        transfer: URL,
        fileManager: FileManager = .default
    ) {
        let available = settings.folders.filter { folder in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: folder.path.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        if settings.guestSupportsMultipleFolders {
            isMultiple = true
            var used: Set<String> = [Self.stagingEntryName]
            entries = available.map { folder in
                let name = Self.uniqueName(for: folder.path, used: &used)
                return Entry(name: name, folder: folder)
            }
            clipboardStaging = transfer
            clipboardRelativePrefix = Self.stagingEntryName + "/"
        } else if let first = available.first, !first.readOnly {
            // An Agent without the staging folder reads clipboard items from
            // the root, so the root must be one writable folder.
            isMultiple = false
            entries = [Entry(name: "", folder: first)]
            clipboardStaging = first.path
            clipboardRelativePrefix = ""
        } else {
            isMultiple = false
            entries = []
            clipboardStaging = transfer
            clipboardRelativePrefix = ""
        }
    }

    /// The directory share for the `riftvm_shared` device.
    public func makeShare(transfer: URL) -> VZDirectoryShare {
        guard isMultiple else {
            let root = entries.first?.folder
            return VZSingleDirectoryShare(directory: VZSharedDirectory(
                url: root?.path ?? transfer,
                readOnly: root?.readOnly ?? false
            ))
        }
        var directories = [Self.stagingEntryName: VZSharedDirectory(url: transfer, readOnly: false)]
        for entry in entries {
            directories[entry.name] = VZSharedDirectory(url: entry.folder.path, readOnly: entry.folder.readOnly)
        }
        return VZMultipleDirectoryShare(directories: directories)
    }

    /// Where Omarchy sees a folder, or nil when this session does not share it.
    public func guestPath(for folder: VMOmarchySharedFolder) -> String? {
        guard let entry = entries.first(where: { $0.folder.id == folder.id }) else { return nil }
        return entry.name.isEmpty ? Self.guestMountPoint : "\(Self.guestMountPoint)/\(entry.name)"
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
