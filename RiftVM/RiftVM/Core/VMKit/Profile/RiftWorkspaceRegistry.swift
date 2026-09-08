import Foundation

public enum RiftWorkspaceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case omarchy
    case macOS
}

public struct RiftWorkspaceRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public let kind: RiftWorkspaceKind
    public var bundleURL: URL
    public let createdAt: Date
    public var pinnedAt: Date?
    public var lastOpenedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        kind: RiftWorkspaceKind,
        bundleURL: URL,
        createdAt: Date = Date(),
        pinnedAt: Date? = nil,
        lastOpenedAt: Date? = nil
    ) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.utf8.count <= 128 else {
            throw RiftWorkspaceRegistryError.invalidName
        }
        guard bundleURL.isFileURL, bundleURL.path.hasPrefix("/") else {
            throw RiftWorkspaceRegistryError.invalidBundleURL
        }
        self.id = id
        self.name = trimmedName
        self.kind = kind
        self.bundleURL = bundleURL.standardizedFileURL
        self.createdAt = createdAt
        self.pinnedAt = pinnedAt
        self.lastOpenedAt = lastOpenedAt
    }
}

public struct RiftWorkspaceRegistrySnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public var workspaces: [RiftWorkspaceRecord]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        workspaces: [RiftWorkspaceRecord] = []
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw RiftWorkspaceRegistryError.unsupportedSchema
        }
        try Self.validate(workspaces: workspaces)
        self.schemaVersion = schemaVersion
        self.workspaces = workspaces
    }

    fileprivate static func validate(workspaces: [RiftWorkspaceRecord]) throws {
        guard Set(workspaces.map(\.id)).count == workspaces.count else {
            throw RiftWorkspaceRegistryError.duplicateIdentifier
        }
        let canonicalPaths = workspaces.map { $0.bundleURL.standardizedFileURL.path }
        guard Set(canonicalPaths).count == canonicalPaths.count else {
            throw RiftWorkspaceRegistryError.duplicateBundleURL
        }
    }
}

public enum RiftWorkspaceRegistryError: Error, Equatable {
    case invalidName
    case invalidBundleURL
    case duplicateIdentifier
    case duplicateBundleURL
    case unsupportedSchema
    case invalidRegistry
    case workspaceNotFound
    case persistenceFailed(String)
}

extension RiftWorkspaceRegistryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidName:
            "The workspace name must contain between 1 and 128 UTF-8 bytes."
        case .invalidBundleURL:
            "A workspace must use an absolute local file URL."
        case .duplicateIdentifier:
            "The workspace registry contains a duplicate identifier."
        case .duplicateBundleURL:
            "The workspace registry contains the same bundle more than once."
        case .unsupportedSchema:
            "The workspace registry schema is unsupported."
        case .invalidRegistry:
            "The workspace registry is invalid."
        case .workspaceNotFound:
            "The workspace is not present in the registry."
        case .persistenceFailed(let reason):
            "The workspace registry could not be saved: \(reason)"
        }
    }
}

public struct RiftWorkspaceRegistryStore {
    public static var standard: Self {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appending(path: "RiftVM", directoryHint: .isDirectory)
        return Self(applicationSupportRoot: root)
    }

    public let registryURL: URL
    private let fileManager: FileManager

    public init(applicationSupportRoot: URL, fileManager: FileManager = .default) {
        registryURL = applicationSupportRoot.standardizedFileURL
            .appending(path: "WorkspaceRegistry.json")
        self.fileManager = fileManager
    }

    public func load() throws -> RiftWorkspaceRegistrySnapshot {
        guard fileManager.fileExists(atPath: registryURL.path) else {
            return try RiftWorkspaceRegistrySnapshot()
        }
        do {
            let snapshot = try JSONDecoder().decode(
                RiftWorkspaceRegistrySnapshot.self,
                from: Data(contentsOf: registryURL)
            )
            guard snapshot.schemaVersion == RiftWorkspaceRegistrySnapshot.currentSchemaVersion else {
                throw RiftWorkspaceRegistryError.unsupportedSchema
            }
            try RiftWorkspaceRegistrySnapshot.validate(workspaces: snapshot.workspaces)
            return snapshot
        } catch let error as RiftWorkspaceRegistryError {
            throw error
        } catch {
            throw RiftWorkspaceRegistryError.invalidRegistry
        }
    }

    public func save(_ snapshot: RiftWorkspaceRegistrySnapshot) throws {
        try RiftWorkspaceRegistrySnapshot.validate(workspaces: snapshot.workspaces)
        do {
            try fileManager.createDirectory(
                at: registryURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: registryURL, options: .atomic)
        } catch {
            throw RiftWorkspaceRegistryError.persistenceFailed(error.localizedDescription)
        }
    }

    public func register(_ workspace: RiftWorkspaceRecord) throws -> RiftWorkspaceRegistrySnapshot {
        var snapshot = try load()
        guard !snapshot.workspaces.contains(where: { $0.id == workspace.id }) else {
            throw RiftWorkspaceRegistryError.duplicateIdentifier
        }
        guard !snapshot.workspaces.contains(where: {
            $0.bundleURL.standardizedFileURL == workspace.bundleURL.standardizedFileURL
        }) else {
            throw RiftWorkspaceRegistryError.duplicateBundleURL
        }
        snapshot.workspaces.append(workspace)
        try save(snapshot)
        return snapshot
    }

    public func registerIfNeeded(
        name: String,
        kind: RiftWorkspaceKind,
        bundleURL: URL
    ) throws -> RiftWorkspaceRegistrySnapshot {
        let canonicalURL = bundleURL.standardizedFileURL
        let current = try load()
        if current.workspaces.contains(where: { $0.bundleURL.standardizedFileURL == canonicalURL }) {
            return current
        }
        return try register(RiftWorkspaceRecord(name: name, kind: kind, bundleURL: canonicalURL))
    }

    public func rename(_ workspaceID: UUID, to name: String) throws -> RiftWorkspaceRegistrySnapshot {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.utf8.count <= 128 else {
            throw RiftWorkspaceRegistryError.invalidName
        }
        var snapshot = try load()
        guard let index = snapshot.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            throw RiftWorkspaceRegistryError.workspaceNotFound
        }
        snapshot.workspaces[index].name = trimmedName
        try save(snapshot)
        return snapshot
    }

    public func setPinned(_ workspaceID: UUID, pinned: Bool) throws -> RiftWorkspaceRegistrySnapshot {
        var snapshot = try load()
        guard let index = snapshot.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            throw RiftWorkspaceRegistryError.workspaceNotFound
        }
        snapshot.workspaces[index].pinnedAt = pinned ? Date() : nil
        try save(snapshot)
        return snapshot
    }

    public func markOpened(_ workspaceID: UUID, at date: Date = Date()) throws -> RiftWorkspaceRegistrySnapshot {
        var snapshot = try load()
        guard let index = snapshot.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            throw RiftWorkspaceRegistryError.workspaceNotFound
        }
        snapshot.workspaces[index].lastOpenedAt = date
        try save(snapshot)
        return snapshot
    }

    public func unregister(_ workspaceID: UUID) throws -> RiftWorkspaceRegistrySnapshot {
        var snapshot = try load()
        guard snapshot.workspaces.contains(where: { $0.id == workspaceID }) else {
            throw RiftWorkspaceRegistryError.workspaceNotFound
        }
        snapshot.workspaces.removeAll(where: { $0.id == workspaceID })
        try save(snapshot)
        return snapshot
    }
}

extension Notification.Name {
    static let riftWorkspaceRegistryDidChange = Notification.Name("RiftWorkspaceRegistryDidChange")
}
