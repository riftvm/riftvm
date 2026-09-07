import CryptoKit
import RiftVMCore
import Foundation
import Virtualization

private struct RollbackObservation: Codable {
    let guestDiskVerified: Bool
    let schemaVersion: Int
    let observedAt: Date
    let sourceRevision: String
    let snapshotID: String
    let snapshotName: String
    let snapshotProtected: Bool
    let beforeSHA256: String
    let simulatedUpdateSHA256: String
    let restoredSHA256: String
    let restoredMatchesSnapshot: Bool
    let workspaceReadyAfterRestore: Bool
}

@main
enum OmarchyRollbackAcceptanceTool {
    @MainActor static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    @MainActor private static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 3 else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let root = URL(filePath: arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        guard VMOmarchyTemporaryPathPolicy.contains(root) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let revision = arguments[1]
        guard revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let output = URL(filePath: arguments[2]).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw CocoaError(.fileWriteFileExists)
        }

        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: root)
        let workspaceManager = VMOmarchyWorkspaceManager(layout: layout)
        guard workspaceManager.inspect() == .ready else { throw CocoaError(.fileReadCorruptFile) }
        let nonce = UUID()
        let before = Data("before-update:\(nonce.uuidString)".utf8)
        let after = Data("after-update:\(nonce.uuidString)".utf8)
        _ = try await guestPass(layout: layout, nonce: nonce, expected: nil, replacement: before)
        let recovery = VMOmarchyRecoveryManager(workspaceManager: workspaceManager)
        let point = try recovery.createProtectedPreUpdatePoint(targetVersion: "guest-disk-\(nonce.uuidString.prefix(8))")
        _ = try await guestPass(layout: layout, nonce: nonce, expected: before, replacement: after)
        try recovery.restore(id: point.id)
        let restored = try await guestPass(layout: layout, nonce: nonce, expected: before, replacement: nil)
        let observation = RollbackObservation(
            guestDiskVerified: true,
            schemaVersion: 2,
            observedAt: Date(),
            sourceRevision: revision,
            snapshotID: point.id,
            snapshotName: point.name,
            snapshotProtected: point.isProtected,
            beforeSHA256: digest(before),
            simulatedUpdateSHA256: digest(after),
            restoredSHA256: digest(restored),
            restoredMatchesSnapshot: restored == before && restored != after,
            workspaceReadyAfterRestore: workspaceManager.inspect() == .ready
        )
        guard observation.snapshotProtected, observation.restoredMatchesSnapshot,
              observation.workspaceReadyAfterRestore else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(observation).write(to: output, options: [.atomic])
    }

    @MainActor private static func guestPass(
        layout: VMOmarchyWorkspaceLayout, nonce: UUID, expected: Data?, replacement: Data?
    ) async throws -> Data {
        let vm = VZVirtualMachine(configuration: try VMOmarchyVirtualMachineBuilder.makeConfiguration(layout: layout, profile: .production))
        try await vm.start()
        guard let device = vm.socketDevices.first as? VZVirtioSocketDevice else { throw CocoaError(.featureUnsupported) }
        var ready = false
        let client = try VMOmarchyGuestAgentClient(device: device, layout: layout) { state in
            if case .ready = state { ready = true }
        }
        client.start()
        defer { client.stop() }
        let deadline = Date().addingTimeInterval(180)
        while !ready && Date() < deadline { try await Task.sleep(for: .seconds(1)) }
        guard ready else { throw NSError(domain: "GuestRollback", code: 1, userInfo: [NSLocalizedDescriptionKey: "Authenticated Agent readiness timed out"]) }
        let observed = try await client.verifyTemporaryGuestDiskMarker(nonce: nonce, expected: expected, replacement: replacement)
        client.requestShutdown()
        let stopDeadline = Date().addingTimeInterval(90)
        while vm.state != .stopped && Date() < stopDeadline { try await Task.sleep(for: .seconds(1)) }
        guard vm.state == .stopped else { throw NSError(domain: "GuestRollback", code: 2, userInfo: [NSLocalizedDescriptionKey: "Guest shutdown timed out; recovery was not attempted"]) }
        return observed
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
