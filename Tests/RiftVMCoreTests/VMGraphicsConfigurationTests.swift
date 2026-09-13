import Foundation
import Virtualization
import XCTest
@testable import RiftVMCore

final class VMGraphicsConfigurationTests: XCTestCase {
    func testLegacyOmarchyMetadataDefaultsToCustomAndExplicitChoiceRoundTrips() throws {
        let old = VMOmarchyWorkspaceMetadata(productID: VMOmarchyProfile.production.productID, createdAt: .distantPast)
        let data = try JSONEncoder().encode(old)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("graphicsBackend"))
        XCTAssertEqual(try JSONDecoder().decode(VMOmarchyWorkspaceMetadata.self, from: data).effectiveGraphicsBackend, .customVirGL)
        for backend in VMLinuxGraphicsBackend.allCases {
            var metadata = old
            metadata.graphicsBackend = backend
            XCTAssertEqual(try JSONDecoder().decode(VMOmarchyWorkspaceMetadata.self, from: JSONEncoder().encode(metadata)), metadata)
        }
        let invalid = String(decoding: data, as: UTF8.self).dropLast() + ",\"graphicsBackend\":\"unsupported\"}"
        XCTAssertThrowsError(try JSONDecoder().decode(VMOmarchyWorkspaceMetadata.self, from: Data(invalid.utf8)))
    }

    func testExplicitAppleChoiceDoesNotRequireVirGLOrGuestAgent() {
        let choice = VMGraphicsBackendSelection.resolve(isLinux: true,
            hostSupportsCustomVirtio: false, requested: .appleVirtio,
            customBackendImplemented: false, hasInstallationMedia: true, guestInputReady: false)
        XCTAssertEqual(choice.active, .appleVirtio)
        XCTAssertNil(choice.unavailabilityReason)
    }

    func testRunningAndSavedStateBlockBackendChanges() {
        XCTAssertNil(VMLinuxGraphicsBackend.changeRestriction(isRunning: false, hasSavedState: false))
        XCTAssertNotNil(VMLinuxGraphicsBackend.changeRestriction(isRunning: true, hasSavedState: false))
        XCTAssertNotNil(VMLinuxGraphicsBackend.changeRestriction(isRunning: false, hasSavedState: true))
    }

    func testExplicitAppleChoiceBuildsNativeDeviceAndSurvivesGuestMetadataUpdate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("riftvm-graphics-settings-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: root)
        for directory in [layout.workspace, layout.boot, layout.shared, layout.enrollment] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data(count: 1_048_576).write(to: layout.disk)
        try VZGenericMachineIdentifier().dataRepresentation.write(to: layout.machineIdentifier)
        let metadata = VMOmarchyWorkspaceMetadata(productID: VMOmarchyProfile.production.productID,
            createdAt: Date(), graphicsBackend: .appleVirtio)
        try JSONEncoder().encode(metadata).write(to: layout.configuration)
        let configuration = try VMOmarchyVirtualMachineBuilder.makeUnvalidatedConfigurationForTesting(layout: layout, profile: .production, hostMemoryBytes: 24 * 1024 * 1024 * 1024, activeProcessorCount: 10)
        XCTAssertEqual(configuration.graphicsDevices.count, 1)
        XCTAssertTrue(configuration.graphicsDevices.first is VZVirtioGraphicsDeviceConfiguration)
        XCTAssertTrue(configuration.customVirtioDevices.isEmpty)
        let manager = VMOmarchyWorkspaceManager(layout: layout)
        try manager.recordGuestIntegration(omarchyRevision: "new", agentVersion: "test", capabilities: ["desktop-input-v1"])
        XCTAssertEqual(try manager.metadata().effectiveGraphicsBackend, .appleVirtio)
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
