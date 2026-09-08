import Foundation
import RiftVMCore
import Virtualization

private enum AcceptanceError: LocalizedError {
    case usage
    case invalidPath(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            "usage: omarchy-workspace-acceptance-tool --factory FACTORY.asif --root /private/tmp/NAME.riftvm --image-version VERSION --omarchy-revision REVISION --agent-version VERSION [--register-name NAME]"
        case .invalidPath(let message):
            message
        }
    }
}

private struct Arguments {
    let factory: URL
    let root: URL
    let imageVersion: String
    let omarchyRevision: String
    let agentVersion: String
    let registerName: String?

    init(_ values: [String]) throws {
        var options: [String: String] = [:]
        var index = 0
        while index < values.count {
            guard values[index].hasPrefix("--"), index + 1 < values.count else {
                throw AcceptanceError.usage
            }
            options[values[index]] = values[index + 1]
            index += 2
        }
        guard let factory = options["--factory"],
              let root = options["--root"],
              let imageVersion = options["--image-version"], !imageVersion.isEmpty,
              let omarchyRevision = options["--omarchy-revision"], !omarchyRevision.isEmpty,
              let agentVersion = options["--agent-version"], !agentVersion.isEmpty,
              Set(options.keys).isSubset(of: [
                  "--factory", "--root", "--image-version", "--omarchy-revision",
                  "--agent-version", "--register-name",
              ]) else {
            throw AcceptanceError.usage
        }
        self.factory = URL(filePath: factory).standardizedFileURL
        self.root = URL(filePath: root, directoryHint: .isDirectory).standardizedFileURL
        self.imageVersion = imageVersion
        self.omarchyRevision = omarchyRevision
        self.agentVersion = agentVersion
        registerName = options["--register-name"]
    }
}

@main
private enum OmarchyWorkspaceAcceptanceTool {
    static func main() throws {
        let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
        guard VMOmarchyTemporaryPathPolicy.contains(arguments.root) else {
            throw AcceptanceError.invalidPath("acceptance workspace must stay under /tmp or /private/tmp")
        }
        guard arguments.root.pathExtension == "riftvm" else {
            throw AcceptanceError.invalidPath("acceptance workspace root must end in .riftvm")
        }

        let profile = VMOmarchyProfile.production
        let resources = profile.resources(
            forHostMemory: ProcessInfo.processInfo.physicalMemory,
            activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount
        )
        let metadata = VMOmarchyWorkspaceMetadata(
            productID: profile.productID,
            createdAt: Date(),
            factoryImageVersion: arguments.imageVersion,
            omarchyRevision: arguments.omarchyRevision,
            guestAgentVersion: arguments.agentVersion,
            guestCapabilities: profile.factoryGuestCapabilities,
            cpuCount: resources.cpuCount,
            memoryBytes: resources.memoryBytes
        )
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: arguments.root)
        let manager = VMOmarchyWorkspaceManager(layout: layout)
        try manager.prepare(
            factoryDisk: arguments.factory,
            configuration: try JSONEncoder().encode(metadata),
            machineIdentifier: VZGenericMachineIdentifier().dataRepresentation
        )
        guard manager.inspect() == .ready else {
            throw AcceptanceError.invalidPath("new acceptance workspace did not become ready")
        }

        if let name = arguments.registerName {
            _ = try RiftWorkspaceRegistryStore.standard.registerIfNeeded(
                name: name,
                kind: .omarchy,
                bundleURL: arguments.root
            )
        }
        let result: [String: Any] = [
            "factoryImageVersion": arguments.imageVersion,
            "registered": arguments.registerName != nil,
            "root": arguments.root.path,
            "state": "ready",
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
