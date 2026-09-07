import Virtualization
import XCTest
@testable import RiftVMCore

final class VMOmarchyVirtualMachineBuilderTests: XCTestCase {
    func testBuilderRefusesToBootAcrossUnreadableInterruptedRestore() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "VMOmarchyBuilderRecoveryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: root)
        try FileManager.default.createDirectory(at: layout.workspace, withIntermediateDirectories: true)
        try Data("not a recovery journal".utf8).write(
            to: layout.workspace.appending(path: ".restore-transaction.json")
        )

        XCTAssertThrowsError(try VMOmarchyVirtualMachineBuilder.makeConfiguration(
            layout: layout,
            profile: .production
        )) { error in
            guard case .recoveryFailed(let reason) = error as? VMOmarchyVirtualMachineBuilderError else {
                return XCTFail("Expected recovery to block VM startup, got \(error)")
            }
            XCTAssertTrue(reason.contains("recovery"), reason)
        }
    }

    func testBuilderCreatesValidatedFixedLinuxConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "VMOmarchyBuilderTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: root)
        try FileManager.default.createDirectory(at: layout.workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: layout.boot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: layout.enrollment, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: layout.shared, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: layout.disk.path, contents: Data(count: 1_048_576)))
        try VZGenericMachineIdentifier().dataRepresentation.write(to: layout.machineIdentifier)

        let gib = UInt64(1_024 * 1_024 * 1_024)
        let configuration = try VMOmarchyVirtualMachineBuilder.makeUnvalidatedConfigurationForTesting(
            layout: layout,
            profile: .production,
            hostMemoryBytes: 32 * gib,
            activeProcessorCount: 10
        )

        XCTAssertEqual(configuration.cpuCount, 6)
        XCTAssertEqual(configuration.memorySize, 16 * gib)
        XCTAssertEqual(configuration.storageDevices.count, 1)
        XCTAssertEqual(configuration.graphicsDevices.count, 1)
        XCTAssertEqual(configuration.socketDevices.count, 1)
        XCTAssertEqual(configuration.directorySharingDevices.count, 2)
        XCTAssertEqual(
            (configuration.directorySharingDevices.first as? VZVirtioFileSystemDeviceConfiguration)?.tag,
            "rift-agent"
        )
        XCTAssertEqual(
            (configuration.directorySharingDevices.last as? VZVirtioFileSystemDeviceConfiguration)?.tag,
            "riftvm_shared"
        )
        let sharedDevice = try XCTUnwrap(
            configuration.directorySharingDevices.last as? VZVirtioFileSystemDeviceConfiguration
        )
        let sharedShare = try XCTUnwrap(sharedDevice.share as? VZSingleDirectoryShare)
        XCTAssertFalse(sharedShare.directory.isReadOnly)
        XCTAssertTrue(
            configuration.consoleDevices.isEmpty,
            "The dedicated Agent clipboard must not compete with a SPICE clipboard owner."
        )
        XCTAssertEqual(configuration.audioDevices.count, 1)
        let sound = try XCTUnwrap(configuration.audioDevices.first as? VZVirtioSoundDeviceConfiguration)
        XCTAssertEqual(sound.streams.count, 1)
        XCTAssertTrue(sound.streams.first is VZVirtioSoundDeviceOutputStreamConfiguration)
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.efiVariableStore.path))

        let identifierData = try Data(contentsOf: layout.machineIdentifier)
        let expectedMAC = try VMOmarchyVirtualMachineBuilder.persistentMACAddress(
            machineIdentifierData: identifierData
        )
        let network = try XCTUnwrap(configuration.networkDevices.first as? VZVirtioNetworkDeviceConfiguration)
        XCTAssertEqual(network.macAddress.string, expectedMAC.string)
    }

    func testBuilderAddsMicrophoneOnlyWhenExplicitlyEnabled() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "VMOmarchyMicrophoneTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: root)
        try FileManager.default.createDirectory(at: layout.workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: layout.boot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: layout.enrollment, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: layout.shared, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: layout.disk.path, contents: Data(count: 1_048_576)))
        try VZGenericMachineIdentifier().dataRepresentation.write(to: layout.machineIdentifier)

        let configuration = try VMOmarchyVirtualMachineBuilder.makeUnvalidatedConfigurationForTesting(
            layout: layout,
            profile: .production,
            microphoneEnabled: true,
            hostMemoryBytes: 32 * UInt64(1_024 * 1_024 * 1_024),
            activeProcessorCount: 10
        )

        let sound = try XCTUnwrap(configuration.audioDevices.first as? VZVirtioSoundDeviceConfiguration)
        XCTAssertEqual(sound.streams.count, 2)
        XCTAssertTrue(sound.streams.contains { $0 is VZVirtioSoundDeviceOutputStreamConfiguration })
        XCTAssertTrue(sound.streams.contains { $0 is VZVirtioSoundDeviceInputStreamConfiguration })
    }

    func testNetworkIdentityIsStableLocalAndUnicast() throws {
        let identity = Data("durable machine identity".utf8)
        let first = try VMOmarchyVirtualMachineBuilder.persistentMACAddress(machineIdentifierData: identity)
        let second = try VMOmarchyVirtualMachineBuilder.persistentMACAddress(machineIdentifierData: identity)
        let different = try VMOmarchyVirtualMachineBuilder.persistentMACAddress(
            machineIdentifierData: Data("another machine identity".utf8)
        )

        XCTAssertEqual(first.string, second.string)
        XCTAssertNotEqual(first.string, different.string)
        let firstOctet = try XCTUnwrap(UInt8(first.string.prefix(2), radix: 16))
        XCTAssertEqual(firstOctet & 0x01, 0, "address must be unicast")
        XCTAssertEqual(firstOctet & 0x02, 0x02, "address must be locally administered")
    }

    func testNetworkIdentityRejectsMissingMachineIdentity() {
        XCTAssertThrowsError(
            try VMOmarchyVirtualMachineBuilder.persistentMACAddress(machineIdentifierData: Data())
        ) { error in
            XCTAssertEqual(error as? VMOmarchyVirtualMachineBuilderError, .invalidMachineIdentifier)
        }
    }
}


final class VMOmarchyFolderGrantTests: XCTestCase {
    func testPermissionsPersistAndRemovalPreservesHostFiles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appending(path: "first")
        let second = root.appending(path: "second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let source = first.appending(path: "keep.txt")
        try Data("Keep me".utf8).write(to: source)
        let readOnly = VMOmarchyFolderGrant(directory: first)
        let writable = VMOmarchyFolderGrant(directory: second, readOnly: false)
        try VMOmarchyFolderGrant.save([readOnly, writable], at: root)
        let device = try XCTUnwrap(VMOmarchyFolderGrant.makeDevice(at: root))
        let share = try XCTUnwrap(device.share as? VZMultipleDirectoryShare)
        XCTAssertEqual(share.directories[readOnly.guestName]?.isReadOnly, true)
        XCTAssertEqual(share.directories[writable.guestName]?.isReadOnly, false)
        XCTAssertEqual(try VMOmarchyFolderGrant.load(at: root), [readOnly, writable])
        try VMOmarchyFolderGrant.save([], at: root)
        XCTAssertNil(try VMOmarchyFolderGrant.makeDevice(at: root))
        XCTAssertEqual(try Data(contentsOf: source), Data("Keep me".utf8))
    }

    func testOfflineAndCorruptPermissionsFailClosed() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(try VMOmarchyFolderGrant.makeDevice(at: root))
        try VMOmarchyFolderGrant.save([VMOmarchyFolderGrant(directory: root.appending(path: "offline"))], at: root)
        XCTAssertThrowsError(try VMOmarchyFolderGrant.makeDevice(at: root))
        try Data("corrupt".utf8).write(to: root.appending(path: "FolderGrants.json"))
        XCTAssertThrowsError(try VMOmarchyFolderGrant.makeDevice(at: root))
    }
}
