import Foundation

/// RiftVM keeps one Omarchy workspace. This record is the memory of which one
/// it is: the bundle on disk, the display name, and when it was last opened.
///
/// The app used to keep a registry of many workspaces with a guest kind. There
/// is one workspace and one guest now, so the record is a single value and a
/// record written by an older build — a workspace under another directory — is
/// simply not the workspace this app shows.
public struct ActiveWorkspaceRecord: Codable, Equatable, Sendable {
    public var name: String
    public var bundleURL: URL
    public let createdAt: Date
    public var lastOpenedAt: Date?

    public init(
        name: String,
        bundleURL: URL,
        createdAt: Date = Date(),
        lastOpenedAt: Date? = nil
    ) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              trimmedName.utf8.count <= 128,
              trimmedName != ".",
              trimmedName != "..",
              !trimmedName.contains("/"),
              !trimmedName.contains(":") else {
            throw ActiveWorkspaceError.invalidName
        }
        guard bundleURL.isFileURL, bundleURL.path.hasPrefix("/") else {
            throw ActiveWorkspaceError.invalidBundleURL
        }
        self.name = trimmedName
        self.bundleURL = bundleURL.standardizedFileURL
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
    }
}

public enum ActiveWorkspaceError: Error, Equatable {
    case invalidName
    case invalidBundleURL
    case persistenceFailed(String)
}

extension ActiveWorkspaceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidName:
            "The workspace name must contain between 1 and 128 characters without slashes or colons."
        case .invalidBundleURL:
            "A workspace must use an absolute local file path."
        case .persistenceFailed(let reason):
            "The workspace record could not be saved: \(reason)"
        }
    }
}

/// Where the one workspace lives and how it is remembered.
public enum ActiveWorkspaceLocation {
    /// Hidden folder the app creates new workspaces in, so a 64 GB virtual
    /// machine does not sit in the visible home folder.
    public static let folderName = ".riftvm"

    public static func defaultBaseDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser.appending(path: folderName, directoryHint: .isDirectory)
    }

    /// The `.riftvm` bundle inside `baseDirectory`, if there is one. The app
    /// creates at most one; a second bundle placed there by hand is ignored
    /// rather than listed, because there is no UI that could choose between them.
    public static func discover(
        baseDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        let base = (baseDirectory ?? defaultBaseDirectory(fileManager: fileManager)).standardizedFileURL
        guard let children = try? fileManager.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return children
            .filter { $0.pathExtension == "riftvm" }
            .filter { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values?.isDirectory == true && values?.isSymbolicLink != true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .first?
            .standardizedFileURL
    }
}

/// Reads and writes the one Omarchy record, and makes sure it matches what is
/// actually on disk.
public struct ActiveWorkspaceStore {
    public static var standard: Self {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appending(path: "RiftVM", directoryHint: .isDirectory)
        return Self(applicationSupportRoot: root)
    }

    public let recordURL: URL
    private let fileManager: FileManager

    public init(applicationSupportRoot: URL, fileManager: FileManager = .default) {
        recordURL = applicationSupportRoot.standardizedFileURL
            .appending(path: "ActiveWorkspace.json")
        self.fileManager = fileManager
    }

    public func load() throws -> ActiveWorkspaceRecord? {
        guard fileManager.fileExists(atPath: recordURL.path) else { return nil }
        do {
            return try JSONDecoder().decode(ActiveWorkspaceRecord.self, from: Data(contentsOf: recordURL))
        } catch {
            throw ActiveWorkspaceError.persistenceFailed(error.localizedDescription)
        }
    }

    public func save(_ record: ActiveWorkspaceRecord) throws {
        do {
            try fileManager.createDirectory(
                at: recordURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(record).write(to: recordURL, options: .atomic)
            NotificationCenter.default.post(name: .riftActiveWorkspaceDidChange, object: record.bundleURL)
        } catch {
            throw ActiveWorkspaceError.persistenceFailed(error.localizedDescription)
        }
    }

    /// Makes `bundleURL` the workspace. There is only one, so adopting a
    /// different bundle replaces the record instead of adding to it.
    @discardableResult
    public func adopt(bundleURL: URL, name: String) throws -> ActiveWorkspaceRecord {
        let existing = try? load()
        let record = try ActiveWorkspaceRecord(
            name: name,
            bundleURL: bundleURL,
            createdAt: existing?.bundleURL.standardizedFileURL == bundleURL.standardizedFileURL
                ? (existing?.createdAt ?? Date())
                : Date(),
            lastOpenedAt: existing?.bundleURL.standardizedFileURL == bundleURL.standardizedFileURL
                ? existing?.lastOpenedAt
                : nil
        )
        try save(record)
        return record
    }

    @discardableResult
    public func markOpened(at date: Date = Date()) throws -> ActiveWorkspaceRecord? {
        guard var record = try load() else { return nil }
        record.lastOpenedAt = date
        try save(record)
        return record
    }

    public func clear() throws {
        guard fileManager.fileExists(atPath: recordURL.path) else { return }
        do {
            try fileManager.removeItem(at: recordURL)
            NotificationCenter.default.post(name: .riftActiveWorkspaceDidChange, object: nil)
        } catch {
            throw ActiveWorkspaceError.persistenceFailed(error.localizedDescription)
        }
    }

    /// The workspace to show: the recorded bundle while it is still on disk,
    /// otherwise one found in the default directory, which is then recorded.
    public func current(
        baseDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> ActiveWorkspaceRecord? {
        if let record = try load(),
           fileManager.fileExists(atPath: record.bundleURL.path) {
            return record
        }
        guard let discovered = ActiveWorkspaceLocation.discover(
            baseDirectory: baseDirectory,
            fileManager: fileManager
        ) else { return nil }
        return try adopt(
            bundleURL: discovered,
            name: discovered.deletingPathExtension().lastPathComponent
        )
    }
}

extension Notification.Name {
    /// Posted after the active workspace record is written or cleared.
    static let riftActiveWorkspaceDidChange = Notification.Name("RiftActiveWorkspaceDidChange")
}

/// Moves a workspace bundle to the Trash on behalf of the workspace UI.
///
/// The record and the disk can disagree: the folder may have been deleted in
/// Finder, or wiped when Application Support was reset, while the record
/// survives. Trashing a path that no longer exists fails with
/// "The file … doesn't exist.", so treating a missing bundle as an error would
/// strand the app with no way to prepare a new workspace.
public enum RiftWorkspaceBundleRemoval {
    /// Trashes `bundleURL` when it is still on disk and reports where macOS put
    /// it. A bundle that is already gone returns `nil` instead of throwing, so
    /// the caller can still clear its record.
    ///
    /// Failures other than a missing bundle (a locked volume, a permission
    /// problem) are rethrown, because the bundle is still there and the record
    /// must not silently disappear.
    @discardableResult
    public static func moveToTrashIfPresent(_ bundleURL: URL, fileManager: FileManager = .default) throws -> URL? {
        var resultingURL: NSURL?
        do {
            try fileManager.trashItem(at: bundleURL, resultingItemURL: &resultingURL)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            return nil
        }
        return resultingURL as URL?
    }
}
