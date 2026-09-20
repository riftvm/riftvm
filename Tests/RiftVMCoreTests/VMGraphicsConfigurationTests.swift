import Foundation
import Virtualization
import XCTest
@testable import RiftVMCore

final class VMGraphicsConfigurationTests: XCTestCase {
    func testMetadataCarriesNoGraphicsChoiceAndIgnoresLegacyOnes() throws {
        let metadata = VMOmarchyWorkspaceMetadata(productID: VMOmarchyProfile.production.productID, createdAt: .distantPast)
        let data = try JSONEncoder().encode(metadata)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("graphicsBackend"))

        // A workspace written when the app still recorded Apple Virtio decodes,
        // and the stale choice has no effect: Custom VirGL is the only backend.
        let legacy = String(decoding: data, as: UTF8.self).dropLast() + ",\"graphicsBackend\":\"appleVirtio\"}"
        let decoded = try JSONDecoder().decode(VMOmarchyWorkspaceMetadata.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.productID, metadata.productID)
    }

    func testALegacyAppleChoiceStillBuildsTheCustomDevice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("riftvm-graphics-settings-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: root)
        for directory in [layout.workspace, layout.boot, layout.transfer, layout.enrollment] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data(count: 1_048_576).write(to: layout.disk)
        try VZGenericMachineIdentifier().dataRepresentation.write(to: layout.machineIdentifier)
        let legacyJSON = """
        {"schemaVersion":2,"productID":"\(VMOmarchyProfile.production.productID)","createdAt":0,"graphicsBackend":"appleVirtio"}
        """
        try Data(legacyJSON.utf8).write(to: layout.configuration)

        let devices = [VZCustomVirtioDeviceConfiguration()]
        let configuration = try VMOmarchyVirtualMachineBuilder.makeUnvalidatedConfigurationForTesting(
            layout: layout,
            profile: .production,
            customGraphicsDevices: devices,
            sharePlan: VMOmarchySharePlan(
                settings: VMOmarchySharedFolderSettings(folders: []),
                transfer: layout.transfer
            ),
            hostMemoryBytes: 24 * 1024 * 1024 * 1024,
            activeProcessorCount: 10
        )

        // The recorded Apple choice is ignored: no Apple graphics device, and the
        // custom device is what the machine gets.
        XCTAssertTrue(configuration.graphicsDevices.isEmpty)
        XCTAssertEqual(configuration.customVirtioDevices.count, devices.count)
    }

    @MainActor
    func testSettingsLeaseExcludesStartupAndReleasesOnError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("riftvm-graphics-lease-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = VMRunningRegistry(lockDirectory: root.appendingPathComponent("locks"))
        let machine = root.appendingPathComponent("test.riftvm")
        try registry.withStoppedMachine(rootPath: machine) {
            XCTAssertNil(registry.acquire(rootPath: machine))
        }
        enum Failure: Error { case expected }
        XCTAssertThrowsError(try registry.withStoppedMachine(rootPath: machine) { throw Failure.expected })
        let lease = try XCTUnwrap(registry.acquire(rootPath: machine))
        XCTAssertThrowsError(try registry.withStoppedMachine(rootPath: machine) { XCTFail("Must not edit running VM") })
        registry.release(lease)
    }
}
