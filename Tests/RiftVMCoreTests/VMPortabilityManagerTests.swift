import XCTest
@testable import RiftVMCore

final class VMPortabilityManagerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RiftVMPortability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testCloneChangesIdentityAndNameAndDropsUnsafeRuntimeHistory() throws {
        let source = try makeMachine(name: "Source")
        try Data("old state".utf8).write(to: source.appendingPathComponent("MachineState.vzvmsave"))
        try Data("old manifest".utf8).write(to: source.appendingPathComponent("MachineState.vzvmsave.manifest.json"))
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Snapshots"), withIntermediateDirectories: true)
        try Data("history".utf8).write(to: source.appendingPathComponent("Snapshots/item"))
        let destination = root.appendingPathComponent("Clone.riftvm")
        let newID = Data("new identifier".utf8)

        try unwrap(VMPortabilityManager.clone(
            sourceURL: source, destinationURL: destination, newName: "Clone", machineIdentifierData: newID
        ))

        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("MachineIdentifier")), newID)
        let config = try json(destination.appendingPathComponent("config.json"))
        XCTAssertEqual(config["name"] as? String, "Clone")
        XCTAssertEqual(
            VMConfigurationIdentity.label(for: try XCTUnwrap(config["name"] as? String)),
            "Clone",
            "The next launch must derive its framework label from the clone's rewritten name"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("MachineState.vzvmsave").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("MachineState.vzvmsave.manifest.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Snapshots").path))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("MachineIdentifier")), Data("source identifier".utf8))
    }

    func testCloneRefusesExistingDestinationWithoutChangingIt() throws {
        let source = try makeMachine(name: "Source")
        let destination = root.appendingPathComponent("Existing.riftvm")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: destination.appendingPathComponent("marker"))
        if case .success = VMPortabilityManager.clone(
            sourceURL: source, destinationURL: destination, newName: "Clone", machineIdentifierData: Data()
        ) { XCTFail("Expected destination conflict") }
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("marker")), Data("keep".utf8))
    }

    func testFailedCloneRollsBackPartialDestinationAndKeepsSource() throws {
        let source = try makeMachine(name: "Source")
        let destination = root.appendingPathComponent("Failed.riftvm")
        if case .success = VMPortabilityManager.clone(
            sourceURL: source,
            destinationURL: destination,
            newName: "   ",
            machineIdentifierData: Data("new".utf8)
        ) { XCTFail("Expected invalid-name failure") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try json(source.appendingPathComponent("config.json"))["name"] as? String, "Source")
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("Disk.img")), Data("disk data".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix("partial") })
    }

    func testNestedDestinationsAreRejected() throws {
        let source = try makeMachine(name: "Source")
        let nestedClone = source.appendingPathComponent("Clone.riftvm")
        if case .success = VMPortabilityManager.clone(
            sourceURL: source, destinationURL: nestedClone, newName: "Clone", machineIdentifierData: Data("new".utf8)
        ) { XCTFail("Expected nested clone rejection") }
        let nestedExport = source.appendingPathComponent("Export.riftvmexport")
        if case .success = VMPortabilityManager.exportMachine(sourceURL: source, destinationURL: nestedExport) {
            XCTFail("Expected nested export rejection")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: nestedClone.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: nestedExport.path))
    }

    func testExportValidateAndImportRoundTrip() throws {
        let source = try makeMachine(name: "Portable")
        let export = root.appendingPathComponent("Portable.riftvmexport")
        try unwrap(VMPortabilityManager.exportMachine(sourceURL: source, destinationURL: export))
        let manifest = try unwrap(VMPortabilityManager.validateExport(at: export))
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.minimumMacOSMajorVersion, 27)
        XCTAssertEqual(Set(manifest.files.map(\.relativePath)), ["Disk.img", "MachineIdentifier", "config.json"])

        let imported = root.appendingPathComponent("Imported.riftvm")
        let importedID = Data("imported identifier".utf8)
        try unwrap(VMPortabilityManager.importMachine(
            exportURL: export, destinationURL: imported,
            identityMode: .copy(machineIdentifierData: importedID, name: "Imported")
        ))
        XCTAssertEqual(try Data(contentsOf: imported.appendingPathComponent("Disk.img")), Data("disk data".utf8))
        XCTAssertEqual(try Data(contentsOf: imported.appendingPathComponent("MachineIdentifier")), importedID)
        let importedConfig = try json(imported.appendingPathComponent("config.json"))
        XCTAssertEqual(importedConfig["name"] as? String, "Imported")
        XCTAssertEqual(
            VMConfigurationIdentity.label(for: try XCTUnwrap(importedConfig["name"] as? String)),
            "Imported",
            "The next launch must derive its framework label from the imported copy's rewritten name"
        )
    }

    func testValidationDetectsSameSizeCorruptionAndImportCreatesNothing() throws {
        let source = try makeMachine(name: "Portable")
        let export = root.appendingPathComponent("Portable.riftvmexport")
        try unwrap(VMPortabilityManager.exportMachine(sourceURL: source, destinationURL: export))
        let disk = export.appendingPathComponent("Machine.riftvm/Disk.img")
        try Data("DIsk data".utf8).write(to: disk)
        if case .success = VMPortabilityManager.validateExport(at: export) { XCTFail("Expected checksum failure") }
        let destination = root.appendingPathComponent("Rejected.riftvm")
        if case .success = VMPortabilityManager.importMachine(
            exportURL: export, destinationURL: destination,
            identityMode: .copy(machineIdentifierData: Data("new".utf8), name: "Rejected")
        ) {
            XCTFail("Expected import failure")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testRestoreImportPreservesIdentityNameAndHistory() throws {
        let source = try makeMachine(name: "Backup")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Snapshots"), withIntermediateDirectories: true)
        try Data("history".utf8).write(to: source.appendingPathComponent("Snapshots/item"))
        let export = root.appendingPathComponent("Backup.riftvmexport")
        try unwrap(VMPortabilityManager.exportMachine(sourceURL: source, destinationURL: export))
        let restored = root.appendingPathComponent("Restored.riftvm")

        try unwrap(VMPortabilityManager.importMachine(exportURL: export, destinationURL: restored, identityMode: .restore))

        XCTAssertEqual(try Data(contentsOf: restored.appendingPathComponent("MachineIdentifier")), Data("source identifier".utf8))
        XCTAssertEqual(try json(restored.appendingPathComponent("config.json"))["name"] as? String, "Backup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.appendingPathComponent("Snapshots/item").path))
    }

    func testCopyImportDropsRuntimeHistoryAndRepeatedImportsUseDistinctIdentities() throws {
        let source = try makeMachine(name: "Portable")
        try Data("state".utf8).write(to: source.appendingPathComponent("MachineState.vzvmsave"))
        try Data("manifest".utf8).write(to: source.appendingPathComponent("MachineState.vzvmsave.manifest.json"))
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Snapshots"), withIntermediateDirectories: true)
        let export = root.appendingPathComponent("Portable.riftvmexport")
        try unwrap(VMPortabilityManager.exportMachine(sourceURL: source, destinationURL: export))
        let first = root.appendingPathComponent("First.riftvm")
        let second = root.appendingPathComponent("Second.riftvm")

        try unwrap(VMPortabilityManager.importMachine(
            exportURL: export, destinationURL: first,
            identityMode: .copy(machineIdentifierData: Data("first identity".utf8), name: "First")
        ))
        try unwrap(VMPortabilityManager.importMachine(
            exportURL: export, destinationURL: second,
            identityMode: .copy(machineIdentifierData: Data("second identity".utf8), name: "Second")
        ))

        XCTAssertNotEqual(try Data(contentsOf: first.appendingPathComponent("MachineIdentifier")),
                          try Data(contentsOf: second.appendingPathComponent("MachineIdentifier")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.appendingPathComponent("MachineState.vzvmsave").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.appendingPathComponent("MachineState.vzvmsave.manifest.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.appendingPathComponent("Snapshots").path))
    }

    func testCopiesReceiveIndependentWorkspaceUUIDsAndCanCoexistInRegistry() throws {
        let source = try makeMachine(name: "Source")
        let identity = WorkspaceIdentity(profile: .macOS)
        try identity.write(to: source)
        let export = root.appendingPathComponent("Source.riftvmexport")
        try unwrap(VMPortabilityManager.exportMachine(sourceURL: source, destinationURL: export))
        let clone = root.appendingPathComponent("Clone.riftvm")
        let imported = root.appendingPathComponent("Imported.riftvm")
        try unwrap(VMPortabilityManager.clone(
            sourceURL: source, destinationURL: clone, newName: "Clone",
            machineIdentifierData: Data("clone hardware".utf8)
        ))
        try unwrap(VMPortabilityManager.importMachine(
            exportURL: export, destinationURL: imported,
            identityMode: .copy(machineIdentifierData: Data("import hardware".utf8), name: "Imported")
        ))
        let cloneIdentity = try WorkspaceIdentity.load(at: clone)
        let importedIdentity = try WorkspaceIdentity.load(at: imported)
        XCTAssertEqual(Set([identity.id, cloneIdentity.id, importedIdentity.id]).count, 3)
        XCTAssertEqual(cloneIdentity.profile, identity.profile)
        XCTAssertEqual(importedIdentity.profile, identity.profile)
        XCTAssertEqual(try WorkspaceIdentity.load(at: source), identity)
        var registry = try WorkspaceRegistry(fileURL: root.appendingPathComponent("Registry.json"))
        for location in [source, clone, imported] { try registry.register(location, profile: .macOS) }
        XCTAssertEqual(registry.workspaces.count, 3)
        let restored = root.appendingPathComponent("Restored.riftvm")
        try unwrap(VMPortabilityManager.importMachine(exportURL: export, destinationURL: restored, identityMode: .restore))
        XCTAssertEqual(try WorkspaceIdentity.load(at: restored), identity)
    }

    func testIndependentCopiesKeepActiveDiskLayersWhileDroppingSnapshotHistory() throws {
        let source = try makeMachine(name: "Layered")
        let snapshots = source.appendingPathComponent("Snapshots")
        let layers = snapshots.appendingPathComponent("Layers")
        try FileManager.default.createDirectory(at: layers, withIntermediateDirectories: true)
        let activePath = "Snapshots/Layers/active.asif"
        try Data("installed operating system".utf8).write(to: source.appendingPathComponent(activePath))
        try Data("unused history".utf8).write(to: layers.appendingPathComponent("unused.asif"))
        try Data("old machine identity".utf8).write(to: snapshots.appendingPathComponent("old-snapshot"))
        let state: [String: Any] = ["currentSnapshotID": "old-snapshot", "activeDiskLayers": ["Disk.img": [activePath]]]
        try JSONSerialization.data(withJSONObject: state).write(to: snapshots.appendingPathComponent("state.json"))
        let export = root.appendingPathComponent("Layered.riftvmexport")
        try unwrap(VMPortabilityManager.exportMachine(sourceURL: source, destinationURL: export))
        let clone = root.appendingPathComponent("Clone.riftvm")
        let imported = root.appendingPathComponent("Imported.riftvm")
        try unwrap(VMPortabilityManager.clone(sourceURL: source, destinationURL: clone,
            newName: "Clone", machineIdentifierData: Data("clone".utf8)))
        try unwrap(VMPortabilityManager.importMachine(exportURL: export, destinationURL: imported,
            identityMode: .copy(machineIdentifierData: Data("import".utf8), name: "Imported")))
        for copy in [clone, imported] {
            XCTAssertEqual(try Data(contentsOf: copy.appendingPathComponent(activePath)), Data("installed operating system".utf8))
            let copiedState = try json(copy.appendingPathComponent("Snapshots/state.json"))
            XCTAssertEqual(copiedState["activeDiskLayers"] as? [String: [String]], ["Disk.img": [activePath]])
            XCTAssertNil(copiedState["currentSnapshotID"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: copy.appendingPathComponent("Snapshots/old-snapshot").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: copy.appendingPathComponent("Snapshots/Layers/unused.asif").path))
        }
        XCTAssertEqual(try json(snapshots.appendingPathComponent("state.json"))["currentSnapshotID"] as? String, "old-snapshot")
        XCTAssertTrue(FileManager.default.fileExists(atPath: layers.appendingPathComponent("unused.asif").path))
    }

    func testCopyRejectsUnreadableOrMissingActiveLayersWithoutPublishingPartialWorkspace() throws {
        for invalidState in ["not JSON", "{\"activeDiskLayers\":{\"Disk.img\":[\"Snapshots/Layers/missing.asif\"]}}"] {
            let source = try makeMachine(name: UUID().uuidString)
            let snapshots = source.appendingPathComponent("Snapshots")
            try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
            try Data(invalidState.utf8).write(to: snapshots.appendingPathComponent("state.json"))
            let export = root.appendingPathComponent("\(UUID().uuidString).riftvmexport")
            try unwrap(VMPortabilityManager.exportMachine(sourceURL: source, destinationURL: export))
            let destination = root.appendingPathComponent("\(UUID().uuidString).riftvm")
            if case .success = VMPortabilityManager.importMachine(exportURL: export, destinationURL: destination,
                identityMode: .copy(machineIdentifierData: Data("copy".utf8), name: "Copy")) {
                XCTFail("An incomplete active disk chain must not be published")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertEqual(try String(contentsOf: snapshots.appendingPathComponent("state.json"), encoding: .utf8), invalidState)
        }
    }

    func testSparseEstimateUsesAllocatedBytesInsteadOfLogicalDiskSize() throws {
        let sparse = root.appendingPathComponent("Sparse.riftvm")
        try FileManager.default.createDirectory(at: sparse, withIntermediateDirectories: false)
        let disk = sparse.appendingPathComponent("Disk.img")
        XCTAssertTrue(FileManager.default.createFile(atPath: disk.path, contents: nil))
        let handle = try FileHandle(forWritingTo: disk)
        try handle.truncate(atOffset: 8 * 1_024 * 1_024 * 1_024)
        try handle.close()

        let estimate = try VMPortabilityManager.estimate(
            sourceURL: sparse, destinationParent: root,
            availableBytes: Int64(256 * 1_024 * 1_024)
        )

        XCTAssertEqual(estimate.logicalBytes, 8 * 1_024 * 1_024 * 1_024)
        XCTAssertLessThan(estimate.allocatedBytes, 128 * 1_024 * 1_024)
        XCTAssertTrue(estimate.hasEnoughSpace)
    }

    func testPortabilityByteAggregationSaturatesInsteadOfOverflowing() {
        XCTAssertEqual(VMPortabilityManager.saturatingSum([UInt64.max, 1]), UInt64.max)
        XCTAssertEqual(VMPortabilityManager.saturatingSum([7, 11, 13]), 31)
    }

    func testLowSpaceCloneFailsBeforeCreatingDestinationOrStagingDirectory() throws {
        let source = try makeMachine(name: "Clone Source")
        let destination = root.appendingPathComponent("Clone Destination.riftvm")

        assertFailureContains(VMPortabilityManager.clone(
            sourceURL: source,
            destinationURL: destination,
            newName: "Clone",
            machineIdentifierData: Data("new identity".utf8),
            availableCapacityBytes: 0
        ), "Required:")

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".partial") })
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("Disk.img")), Data("disk data".utf8))
    }

    func testLowSpaceExportFailsBeforeCreatingDestinationOrStagingDirectory() throws {
        let source = try makeMachine(name: "Export Source")
        let destination = root.appendingPathComponent("Export.riftvmexport")

        assertFailureContains(VMPortabilityManager.exportMachine(
            sourceURL: source,
            destinationURL: destination,
            availableCapacityBytes: 0
        ), "available:")

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".partial") })
    }

    func testLowSpaceImportFailsBeforeCreatingDestinationOrStagingDirectory() throws {
        let source = try makeMachine(name: "Import Source")
        let export = root.appendingPathComponent("Import.riftvmexport")
        try unwrap(VMPortabilityManager.exportMachine(sourceURL: source, destinationURL: export))
        let destination = root.appendingPathComponent("Imported.riftvm")

        assertFailureContains(VMPortabilityManager.importMachine(
            exportURL: export,
            destinationURL: destination,
            identityMode: .restore,
            availableCapacityBytes: 0
        ), "Required:")

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".partial") })
    }

    func testValidationDetectsMissingAndUnexpectedFiles() throws {
        let source = try makeMachine(name: "Portable")
        let missingExport = root.appendingPathComponent("Missing.riftvmexport")
        try unwrap(VMPortabilityManager.exportMachine(sourceURL: source, destinationURL: missingExport))
        try FileManager.default.removeItem(at: missingExport.appendingPathComponent("Machine.riftvm/Disk.img"))
        assertFailureContains(VMPortabilityManager.validateExport(at: missingExport), "missing")

        let extraExport = root.appendingPathComponent("Extra.riftvmexport")
        try unwrap(VMPortabilityManager.exportMachine(sourceURL: source, destinationURL: extraExport))
        try Data("extra".utf8).write(to: extraExport.appendingPathComponent("Machine.riftvm/injected"))
        assertFailureContains(VMPortabilityManager.validateExport(at: extraExport), "unexpected")
    }

    func testSymbolicLinkIsRejectedAndPartialExportIsCleaned() throws {
        let source = try makeMachine(name: "Unsafe")
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/tmp")
        )
        let export = root.appendingPathComponent("Unsafe.riftvmexport")
        if case .success = VMPortabilityManager.exportMachine(sourceURL: source, destinationURL: export) {
            XCTFail("Expected symlink rejection")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.contains("Unsafe.riftvmexport") && $0.hasSuffix("partial") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    private func makeMachine(name: String) throws -> URL {
        let url = root.appendingPathComponent("\(name).riftvm")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let config: [String: Any] = ["name": name, "type": "linux"]
        try JSONSerialization.data(withJSONObject: config).write(to: url.appendingPathComponent("config.json"))
        try Data("disk data".utf8).write(to: url.appendingPathComponent("Disk.img"))
        try Data("source identifier".utf8).write(to: url.appendingPathComponent("MachineIdentifier"))
        return url
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func unwrap(_ result: VMOSResultVoid) throws {
        if case .failure(let error) = result { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
    }

    private func unwrap<T>(_ result: VMOSResult<T, String>) throws -> T {
        switch result {
        case .success(let value): return value
        case .failure(let error): throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
        }
    }

    private func assertFailureContains<T>(_ result: VMOSResult<T, String>, _ text: String) {
        guard case .failure(let error) = result else { return XCTFail("Expected failure") }
        XCTAssertTrue(error.localizedCaseInsensitiveContains(text), error)
    }

    private func assertFailureContains(_ result: VMOSResultVoid, _ text: String) {
        guard case .failure(let error) = result else { return XCTFail("Expected failure") }
        XCTAssertTrue(error.localizedCaseInsensitiveContains(text), error)
    }
}
