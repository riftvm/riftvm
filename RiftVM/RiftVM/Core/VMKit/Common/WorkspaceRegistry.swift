import Foundation

public enum WorkspaceProfile: String, Codable, CaseIterable, Sendable {
    case omarchy, macOS, linux

    public var title: String {
        switch self {
        case .omarchy: "Omarchy"
        case .macOS: "macOS"
        case .linux: "Custom Linux"
        }
    }

    public var symbol: String {
        switch self {
        case .omarchy: "terminal"
        case .macOS: "macwindow"
        case .linux: "opticaldisc"
        }
    }
}

public struct WorkspaceIdentity: Codable, Equatable, Sendable {
    public static let fileName = "Workspace.json"
    public let schemaVersion: Int
    public let id: UUID
    public let profile: WorkspaceProfile
    public let createdAt: Date

    public init(id: UUID = UUID(), profile: WorkspaceProfile, createdAt: Date = Date()) {
        schemaVersion = 1
        self.id = id
        self.profile = profile
        self.createdAt = createdAt
    }

    public static func load(at root: URL) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: root.appendingPathComponent(fileName)))
        guard value.schemaVersion == 1 else { throw WorkspaceRegistryError.unsupportedSchema }
        return value
    }

    public func write(to root: URL) throws {
        try JSONEncoder().encode(self).write(to: root.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

public struct WorkspaceRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let profile: WorkspaceProfile
    public var location: URL
    public var name: String { location.deletingPathExtension().lastPathComponent }
}

public enum WorkspaceLaunchRoute: Equatable {
    case create
    case choose
    case open(UUID)
}

public enum WorkspaceRegistryError: LocalizedError {
    case unsupportedSchema, invalidBundle, duplicateIdentity, profileMismatch, unknownWorkspace, invalidResources

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema: "This workspace format requires a different version of RiftVM."
        case .invalidBundle: "Choose a .riftvm workspace folder."
        case .duplicateIdentity: "Another workspace has the same identity. Move the original workspace or use Duplicate to create an independent copy."
        case .profileMismatch: "The workspace profile does not match its recorded identity."
        case .unknownWorkspace: "The workspace is no longer registered."
        case .invalidResources: "An Omarchy workspace needs at least two CPUs and 4 GB of memory."
        }
    }
}

/// Main-thread ownership is supplied by the App. This value store is also usable
/// by tools and tests without loading SwiftUI or Virtualization.framework.
public struct WorkspaceRegistry {
    private struct Document: Codable {
        var schemaVersion = 1
        var workspaces: [WorkspaceRecord] = []
        var defaultID: UUID?
    }
    private var document: Document
    public let fileURL: URL
    public var workspaces: [WorkspaceRecord] { document.workspaces }
    public var defaultID: UUID? { document.defaultID }

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: fileURL))
            guard document.schemaVersion == 1,
                  Set(document.workspaces.map(\.id)).count == document.workspaces.count,
                  Set(document.workspaces.map { Self.canonical($0.location) }).count == document.workspaces.count,
                  document.defaultID == nil || document.workspaces.contains(where: { $0.id == document.defaultID }) else {
                throw WorkspaceRegistryError.unsupportedSchema
            }
        } else {
            document = Document()
        }
    }

    public var launchRoute: WorkspaceLaunchRoute {
        if let id = defaultID { return .open(id) }
        switch workspaces.count {
        case 0: return .create
        case 1: return .open(workspaces[0].id)
        default: return .choose
        }
    }

    @discardableResult
    public mutating func register(_ root: URL, profile: WorkspaceProfile) throws -> WorkspaceRecord {
        let root = Self.canonical(root)
        var isDirectory: ObjCBool = false
        guard root.pathExtension == "riftvm",
              FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorkspaceRegistryError.invalidBundle
        }
        let metadata = root.appendingPathComponent(WorkspaceIdentity.fileName)
        let identity: WorkspaceIdentity
        if FileManager.default.fileExists(atPath: metadata.path) {
            identity = try WorkspaceIdentity.load(at: root)
        } else {
            identity = WorkspaceIdentity(profile: profile)
            try identity.write(to: root)
        }
        guard identity.profile == profile else { throw WorkspaceRegistryError.profileMismatch }
        if let previous = workspaces.first(where: { $0.id == identity.id }), Self.canonical(previous.location) != root,
           FileManager.default.fileExists(atPath: previous.location.path) {
            throw WorkspaceRegistryError.duplicateIdentity
        }
        let record = WorkspaceRecord(id: identity.id, profile: profile, location: root)
        var next = document
        // A moved workspace retains identity. A replaced bundle at the same path
        // replaces its registry entry and cannot silently inherit the default.
        next.workspaces.removeAll { $0.id == record.id || Self.canonical($0.location) == root }
        next.workspaces.append(record)
        if let id = next.defaultID, !next.workspaces.contains(where: { $0.id == id }) { next.defaultID = nil }
        try commit(next)
        return record
    }

    public mutating func setDefault(_ id: UUID?) throws {
        guard id == nil || workspaces.contains(where: { $0.id == id }) else { throw WorkspaceRegistryError.unknownWorkspace }
        var next = document
        next.defaultID = id
        try commit(next)
    }

    /// Forgetting a registration never removes guest disks or host directories.
    public mutating func remove(_ id: UUID) throws {
        var next = document
        next.workspaces.removeAll { $0.id == id }
        if next.defaultID == id { next.defaultID = nil }
        try commit(next)
    }

    private mutating func commit(_ next: Document) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(next)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        document = next
    }

    public static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
}

public struct WorkspaceResources: Codable, Equatable, Sendable {
    public let cpuCount: Int
    public let memoryBytes: UInt64
    public init(cpuCount: Int, memoryBytes: UInt64) {
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
    }
    public static func load(at root: URL) throws -> Self? {
        let url = root.appendingPathComponent("Resources.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard value.cpuCount >= 2, value.memoryBytes >= 4 * 1_024 * 1_024 * 1_024 else {
            throw WorkspaceRegistryError.invalidResources
        }
        return value
    }
    public func write(to root: URL) throws {
        guard cpuCount >= 2, memoryBytes >= 4 * 1_024 * 1_024 * 1_024 else { throw WorkspaceRegistryError.invalidResources }
        try JSONEncoder().encode(self).write(to: root.appendingPathComponent("Resources.json"), options: .atomic)
    }
}
