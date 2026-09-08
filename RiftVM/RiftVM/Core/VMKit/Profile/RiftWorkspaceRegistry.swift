import Foundation

public enum RiftWorkspaceKind: String, Codable, CaseIterable, Sendable {
    case omarchy
    case macOS
    case customLinux
}

public struct RiftWorkspaceRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public let kind: RiftWorkspaceKind
    public var bundleURL: URL
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        kind: RiftWorkspaceKind,
        bundleURL: URL,
        createdAt: Date = Date()
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
    }
}

public struct RiftWorkspaceRegistrySnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public var workspaces: [RiftWorkspaceRecord]
    public var defaultWorkspaceID: UUID?

    public init(
        schemaVersion: Int = currentSchemaVersion,
        workspaces: [RiftWorkspaceRecord] = [],
        defaultWorkspaceID: UUID? = nil
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw RiftWorkspaceRegistryError.unsupportedSchema
        }
        try Self.validate(workspaces: workspaces, defaultWorkspaceID: defaultWorkspaceID)
        self.schemaVersion = schemaVersion
        self.workspaces = workspaces
        self.defaultWorkspaceID = defaultWorkspaceID
    }

    public func launchSelection() -> RiftWorkspaceLaunchSelection {
        guard !workspaces.isEmpty else { return .createWorkspace }
        if let defaultWorkspaceID,
           let workspace = workspaces.first(where: { $0.id == defaultWorkspaceID }) {
            return .open(workspace)
        }
        if workspaces.count == 1, let workspace = workspaces.first {
            return .open(workspace)
        }
        return .chooseWorkspace
    }

    fileprivate static func validate(
        workspaces: [RiftWorkspaceRecord],
        defaultWorkspaceID: UUID?
    ) throws {
        guard Set(workspaces.map(\.id)).count == workspaces.count else {
            throw RiftWorkspaceRegistryError.duplicateIdentifier
        }
        let canonicalPaths = workspaces.map { $0.bundleURL.standardizedFileURL.path }
        guard Set(canonicalPaths).count == canonicalPaths.count else {
            throw RiftWorkspaceRegistryError.duplicateBundleURL
        }
        if let defaultWorkspaceID,
           !workspaces.contains(where: { $0.id == defaultWorkspaceID }) {
            throw RiftWorkspaceRegistryError.missingDefaultWorkspace
        }
    }
}

public enum RiftWorkspaceLaunchSelection: Equatable, Sendable {
    case createWorkspace
    case open(RiftWorkspaceRecord)
    case chooseWorkspace
}

public enum RiftWorkspaceRegistryError: Error, Equatable {
    case invalidName
    case invalidBundleURL
    case duplicateIdentifier
    case duplicateBundleURL
    case missingDefaultWorkspace
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
        case .missingDefaultWorkspace:
            "The default workspace is not present in the registry."
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
            try RiftWorkspaceRegistrySnapshot.validate(
                workspaces: snapshot.workspaces,
                defaultWorkspaceID: snapshot.defaultWorkspaceID
            )
            return snapshot
        } catch let error as RiftWorkspaceRegistryError {
            throw error
        } catch {
            throw RiftWorkspaceRegistryError.invalidRegistry
        }
    }

    public func save(_ snapshot: RiftWorkspaceRegistrySnapshot) throws {
        try RiftWorkspaceRegistrySnapshot.validate(
            workspaces: snapshot.workspaces,
            defaultWorkspaceID: snapshot.defaultWorkspaceID
        )
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

    public func register(
        _ workspace: RiftWorkspaceRecord,
        makeDefault: Bool = false
    ) throws -> RiftWorkspaceRegistrySnapshot {
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
        if makeDefault { snapshot.defaultWorkspaceID = workspace.id }
        try save(snapshot)
        return snapshot
    }

    public func registerIfNeeded(
        name: String,
        kind: RiftWorkspaceKind,
        bundleURL: URL,
        makeDefaultWhenFirst: Bool = true
    ) throws -> RiftWorkspaceRegistrySnapshot {
        let canonicalURL = bundleURL.standardizedFileURL
        let current = try load()
        if current.workspaces.contains(where: { $0.bundleURL.standardizedFileURL == canonicalURL }) {
            return current
        }
        return try register(
            RiftWorkspaceRecord(name: name, kind: kind, bundleURL: canonicalURL),
            makeDefault: makeDefaultWhenFirst && current.workspaces.isEmpty
        )
    }

    public func setDefault(_ workspaceID: UUID?) throws -> RiftWorkspaceRegistrySnapshot {
        var snapshot = try load()
        if let workspaceID,
           !snapshot.workspaces.contains(where: { $0.id == workspaceID }) {
            throw RiftWorkspaceRegistryError.workspaceNotFound
        }
        snapshot.defaultWorkspaceID = workspaceID
        try save(snapshot)
        return snapshot
    }

    public func unregister(_ workspaceID: UUID) throws -> RiftWorkspaceRegistrySnapshot {
        var snapshot = try load()
        guard snapshot.workspaces.contains(where: { $0.id == workspaceID }) else {
            throw RiftWorkspaceRegistryError.workspaceNotFound
        }
        snapshot.workspaces.removeAll(where: { $0.id == workspaceID })
        if snapshot.defaultWorkspaceID == workspaceID {
            snapshot.defaultWorkspaceID = nil
        }
        try save(snapshot)
        return snapshot
    }
}

extension Notification.Name {
    static let riftWorkspaceRegistryDidChange = Notification.Name("RiftWorkspaceRegistryDidChange")
}
