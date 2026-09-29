import Foundation
import XCTest
@testable import RiftVMCore

#if arch(arm64)
final class VMStorageCapacityTests: XCTestCase {
    private let location = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    private let gibibyte: Int64 = 1_073_741_824

    func testDefaultReserveIsOneGibibyte() {
        XCTAssertEqual(VMStorageCapacity.defaultReserveBytes, gibibyte)
    }

    func testNothingRequiredNeverFails() {
        for required in [nil, 0, -1, Int64.min] as [Int64?] {
            XCTAssertNoThrow(try VMStorageCapacity.validate(
                requiredBytes: required,
                at: location,
                availableBytesOverride: 0
            ))
        }
    }

    func testRequirementIncludesTheReserve() {
        // Exactly enough for the payload and the reserve.
        XCTAssertNoThrow(try VMStorageCapacity.validate(
            requiredBytes: 100,
            at: location,
            availableBytesOverride: gibibyte + 100
        ))

        XCTAssertThrowsError(try VMStorageCapacity.validate(
            requiredBytes: 100,
            at: location,
            availableBytesOverride: gibibyte + 99
        )) { error in
            XCTAssertEqual(
                error as? VMStorageCapacityError,
                .insufficientDiskSpace(required: gibibyte + 100, available: gibibyte + 99)
            )
        }
    }

    func testCustomReserveIsHonouredAndNegativeReserveCountsAsZero() {
        XCTAssertNoThrow(try VMStorageCapacity.validate(
            requiredBytes: 100,
            at: location,
            reserveBytes: 50,
            availableBytesOverride: 150
        ))
        XCTAssertThrowsError(try VMStorageCapacity.validate(
            requiredBytes: 100,
            at: location,
            reserveBytes: 50,
            availableBytesOverride: 149
        ))

        XCTAssertNoThrow(try VMStorageCapacity.validate(
            requiredBytes: 100,
            at: location,
            reserveBytes: -1_000,
            availableBytesOverride: 100
        ))
        XCTAssertThrowsError(try VMStorageCapacity.validate(
            requiredBytes: 100,
            at: location,
            reserveBytes: -1_000,
            availableBytesOverride: 99
        )) { error in
            XCTAssertEqual(
                error as? VMStorageCapacityError,
                .insufficientDiskSpace(required: 100, available: 99)
            )
        }
    }

    func testOverflowingRequirementSaturatesInsteadOfTrapping() {
        XCTAssertThrowsError(try VMStorageCapacity.validate(
            requiredBytes: Int64.max,
            at: location,
            availableBytesOverride: Int64.max - 1
        )) { error in
            XCTAssertEqual(
                error as? VMStorageCapacityError,
                .insufficientDiskSpace(required: Int64.max, available: Int64.max - 1)
            )
        }
        XCTAssertNoThrow(try VMStorageCapacity.validate(
            requiredBytes: Int64.max,
            at: location,
            availableBytesOverride: Int64.max
        ))
    }

    func testNegativeAvailableSpaceIsInsufficient() {
        XCTAssertThrowsError(try VMStorageCapacity.validate(
            requiredBytes: 1,
            at: location,
            reserveBytes: 0,
            availableBytesOverride: -1
        ))
    }

    func testErrorMessageNamesBothAmounts() throws {
        let error = VMStorageCapacityError.insufficientDiskSpace(required: 2 * gibibyte, available: gibibyte)
        let message = try XCTUnwrap(error.errorDescription)
        let formatted = { (value: Int64) in
            ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
        }

        XCTAssertEqual(
            message,
            "The operation needs at least \(formatted(2 * gibibyte)) free, "
                + "but only \(formatted(gibibyte)) is available."
        )
        XCTAssertEqual(error.localizedDescription, message)
    }

    func testRealVolumeReportsCapacityForFilesAndDirectories() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RiftVMCapacityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let forDirectory = try XCTUnwrap(VMStorageCapacity.availableBytes(at: directory))
        // A file that does not exist yet is measured through its directory.
        let forFile = try XCTUnwrap(VMStorageCapacity.availableBytes(
            at: directory.appendingPathComponent("Disk.img", isDirectory: false)
        ))
        XCTAssertGreaterThan(forDirectory, 0)
        XCTAssertGreaterThan(forFile, 0)

        // Without an override the real volume decides.
        XCTAssertThrowsError(try VMStorageCapacity.validate(
            requiredBytes: Int64.max,
            at: directory,
            reserveBytes: 0
        ))
        XCTAssertNoThrow(try VMStorageCapacity.validate(requiredBytes: 1, at: directory, reserveBytes: 0))
    }

    func testUnknownCapacityDoesNotBlockTheOperation() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/machine", isDirectory: true)

        XCTAssertNil(VMStorageCapacity.availableBytes(at: missing))
        XCTAssertNoThrow(try VMStorageCapacity.validate(requiredBytes: Int64.max, at: missing))
    }
}

final class VMEFIVariableStoreRecoveryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RiftVMEFITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testOnlyAnInvalidBootLoaderMessageTriggersRecovery() {
        XCTAssertTrue(VMEFIVariableStoreRecovery.isInvalidBootLoaderError("The boot loader is invalid."))
        XCTAssertTrue(VMEFIVariableStoreRecovery.isInvalidBootLoaderError("INVALID Boot Loader configuration"))

        XCTAssertFalse(VMEFIVariableStoreRecovery.isInvalidBootLoaderError(""))
        XCTAssertFalse(VMEFIVariableStoreRecovery.isInvalidBootLoaderError("The boot loader could not be read."))
        XCTAssertFalse(VMEFIVariableStoreRecovery.isInvalidBootLoaderError("The storage device is invalid."))
        XCTAssertFalse(VMEFIVariableStoreRecovery.isInvalidBootLoaderError("bootloader invalid"))
    }

    func testRejectedStoreIsKeptAsBackupAndReplaced() throws {
        let store = directory.appendingPathComponent("NVRAM")
        let rejected = Data("rejected store".utf8)
        try rejected.write(to: store)

        let backup = try XCTUnwrap(VMEFIVariableStoreRecovery.replaceRejectedStore(at: store))

        XCTAssertEqual(backup.lastPathComponent, "NVRAM.invalid-backup")
        XCTAssertEqual(try Data(contentsOf: backup), rejected)
        let replacement = try Data(contentsOf: store)
        XCTAssertFalse(replacement.isEmpty)
        XCTAssertNotEqual(replacement, rejected)
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
            ["NVRAM", "NVRAM.invalid-backup"]
        )
    }

    func testMissingStoreIsCreatedWithoutBackup() throws {
        let store = directory.appendingPathComponent("NVRAM")

        XCTAssertNil(try VMEFIVariableStoreRecovery.replaceRejectedStore(at: store))

        XCTAssertFalse(try Data(contentsOf: store).isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["NVRAM"])
    }

    func testRepeatedRecoveryKeepsOnlyTheMostRecentlyRejectedStore() throws {
        let store = directory.appendingPathComponent("NVRAM")
        try Data("first".utf8).write(to: store)
        _ = try VMEFIVariableStoreRecovery.replaceRejectedStore(at: store)
        try Data("second".utf8).write(to: store)
        // Leftovers of an interrupted attempt must not get in the way.
        try Data("stale".utf8).write(to: store.appendingPathExtension("replacement"))

        let backup = try XCTUnwrap(VMEFIVariableStoreRecovery.replaceRejectedStore(at: store))

        XCTAssertEqual(try Data(contentsOf: backup), Data("second".utf8))
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
            ["NVRAM", "NVRAM.invalid-backup"]
        )
    }

    func testFailureToCreateReplacementLeavesRejectedStoreInPlace() throws {
        let missingDirectory = directory.appendingPathComponent("missing", isDirectory: true)
        let store = missingDirectory.appendingPathComponent("NVRAM")

        XCTAssertThrowsError(try VMEFIVariableStoreRecovery.replaceRejectedStore(at: store))

        XCTAssertFalse(FileManager.default.fileExists(atPath: missingDirectory.path))
    }
}
#endif
