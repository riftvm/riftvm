import CryptoKit
import Foundation
import Virtualization

public enum VMOmarchyVirtualMachineBuilder {
    public static func makeConfiguration(
        layout: VMOmarchyWorkspaceLayout,
        profile: VMOmarchyProfile,
        microphoneEnabled: Bool = false,
        hostMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        activeProcessorCount: Int = ProcessInfo.processInfo.activeProcessorCount
    ) throws -> VZVirtualMachineConfiguration {
        do {
            try VMOmarchyRecoveryManager(
                workspaceManager: VMOmarchyWorkspaceManager(layout: layout)
            ).recoverInterruptedOperations()
        } catch {
            throw VMOmarchyVirtualMachineBuilderError.recoveryFailed(error.localizedDescription)
        }
        return try buildConfiguration(
            layout: layout,
            profile: profile,
            microphoneEnabled: microphoneEnabled,
            hostMemoryBytes: hostMemoryBytes,
            activeProcessorCount: activeProcessorCount,
            validatesConfiguration: true
        )
    }

    static func makeUnvalidatedConfigurationForTesting(
        layout: VMOmarchyWorkspaceLayout,
        profile: VMOmarchyProfile,
        microphoneEnabled: Bool = false,
        hostMemoryBytes: UInt64,
        activeProcessorCount: Int
    ) throws -> VZVirtualMachineConfiguration {
        try buildConfiguration(
            layout: layout,
            profile: profile,
            microphoneEnabled: microphoneEnabled,
            hostMemoryBytes: hostMemoryBytes,
            activeProcessorCount: activeProcessorCount,
            validatesConfiguration: false
        )
    }

    private static func buildConfiguration(
        layout: VMOmarchyWorkspaceLayout,
        profile: VMOmarchyProfile,
        microphoneEnabled: Bool,
        hostMemoryBytes: UInt64,
        activeProcessorCount: Int,
        validatesConfiguration: Bool
    ) throws -> VZVirtualMachineConfiguration {
        try profile.validate()
        let resources = profile.resources(
            forHostMemory: hostMemoryBytes,
            activeProcessorCount: activeProcessorCount
        )
        let customResources = try WorkspaceResources.load(at: layout.applicationSupportRoot)
        let configuration = VZVirtualMachineConfiguration()
        configuration.cpuCount = min(
            max(customResources?.cpuCount ?? resources.cpuCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
            VZVirtualMachineConfiguration.maximumAllowedCPUCount
        )
        configuration.memorySize = min(
            max(customResources?.memoryBytes ?? resources.memoryBytes, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
            VZVirtualMachineConfiguration.maximumAllowedMemorySize
        )

        let bootLoader = VZEFIBootLoader()
        if FileManager.default.fileExists(atPath: layout.efiVariableStore.path) {
            bootLoader.variableStore = VZEFIVariableStore(url: layout.efiVariableStore)
        } else {
            try FileManager.default.createDirectory(at: layout.boot, withIntermediateDirectories: true)
            bootLoader.variableStore = try VZEFIVariableStore(
                creatingVariableStoreAt: layout.efiVariableStore,
                options: []
            )
        }
        configuration.bootLoader = bootLoader

        let machineIdentifierData = try Data(contentsOf: layout.machineIdentifier)
        guard let machineIdentifier = VZGenericMachineIdentifier(
            dataRepresentation: machineIdentifierData
        ) else {
            throw VMOmarchyVirtualMachineBuilderError.invalidMachineIdentifier
        }
        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = machineIdentifier
        configuration.platform = platform

        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: layout.disk,
            readOnly: false,
            cachingMode: .automatic,
            synchronizationMode: .full
        )
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]

        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1920, heightInPixels: 1200)]
        configuration.graphicsDevices = [graphics]
        configuration.keyboards = [VZUSBKeyboardConfiguration()]
        configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        let enrollmentDirectory = VZSharedDirectory(url: layout.enrollment, readOnly: true)
        let enrollmentShare = VZSingleDirectoryShare(directory: enrollmentDirectory)
        let enrollmentDevice = VZVirtioFileSystemDeviceConfiguration(
            tag: VMGuestAgentEnrollmentStore.sharedDirectoryTag
        )
        enrollmentDevice.share = enrollmentShare
        let sharedDirectory = VZSharedDirectory(url: layout.shared, readOnly: false)
        let sharedDevice = VZVirtioFileSystemDeviceConfiguration(tag: "riftvm_shared")
        sharedDevice.share = VZSingleDirectoryShare(directory: sharedDirectory)
        configuration.directorySharingDevices = [enrollmentDevice, sharedDevice]
        if let folders = try VMOmarchyFolderGrant.makeDevice(at: layout.applicationSupportRoot) {
            configuration.directorySharingDevices.append(folders)
        }

        // Omarchy uses the authenticated Guest Agent for text and image
        // clipboard integration. Attaching the SPICE clipboard at the same
        // time creates a second Wayland selection owner which can overwrite a
        // freshly verified Agent publication with stale Host contents.
        configuration.consoleDevices = []

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        network.macAddress = try persistentMACAddress(machineIdentifierData: machineIdentifierData)
        configuration.networkDevices = [network]

        let audio = VZVirtioSoundDeviceConfiguration()
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        output.sink = VZHostAudioOutputStreamSink()
        var audioStreams: [VZVirtioSoundDeviceStreamConfiguration] = [output]
        if microphoneEnabled {
            let input = VZVirtioSoundDeviceInputStreamConfiguration()
            input.source = VZHostAudioInputStreamSource()
            audioStreams.append(input)
        }
        audio.streams = audioStreams
        configuration.audioDevices = [audio]

        if validatesConfiguration { try configuration.validate() }
        return configuration
    }

    /// Derives a stable, locally administered unicast address from the VM's
    /// durable machine identity. This avoids a second mutable identity file and
    /// keeps DHCP/device identity stable across launches and restored backups.
    static func persistentMACAddress(machineIdentifierData: Data) throws -> VZMACAddress {
        guard !machineIdentifierData.isEmpty else {
            throw VMOmarchyVirtualMachineBuilderError.invalidMachineIdentifier
        }
        var bytes = Array(SHA256.hash(data: Data("riftvm-omarchy-network-v1".utf8) + machineIdentifierData).prefix(6))
        bytes[0] = (bytes[0] | 0x02) & 0xfe
        let value = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
        guard let address = VZMACAddress(string: value) else {
            throw VMOmarchyVirtualMachineBuilderError.invalidMachineIdentifier
        }
        return address
    }
}

public enum VMOmarchyVirtualMachineBuilderError: Error, Equatable {
    case invalidMachineIdentifier
    case recoveryFailed(String)
}

extension VMOmarchyVirtualMachineBuilderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidMachineIdentifier:
            "The Omarchy machine identity is invalid."
        case .recoveryFailed(let reason):
            "Omarchy cannot start until its interrupted recovery is resolved: \(reason)"
        }
    }
}

/// Host folders are opt-in and belong to one workspace. Removing a grant never
/// removes its host directory. Permissions are applied by VirtioFS itself.
public struct VMOmarchyFolderGrant: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let directory: URL
    public var readOnly: Bool

    public init(directory: URL, readOnly: Bool = true) {
        id = UUID()
        name = directory.lastPathComponent
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        self.readOnly = readOnly
    }

    public var guestName: String { "\(name)-\(id.uuidString.prefix(8).lowercased())" }

    public static func load(at workspace: URL) throws -> [Self] {
        let url = workspace.appending(path: "FolderGrants.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([Self].self, from: Data(contentsOf: url))
    }

    public static func save(_ grants: [Self], at workspace: URL) throws {
        guard Set(grants.map(\.id)).count == grants.count,
              Set(grants.map(\.directory)).count == grants.count else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try JSONEncoder().encode(grants).write(to: workspace.appending(path: "FolderGrants.json"), options: .atomic)
    }

    public static func makeDevice(at workspace: URL) throws -> VZVirtioFileSystemDeviceConfiguration? {
        let grants = try load(at: workspace)
        guard !grants.isEmpty else { return nil }
        var directories: [String: VZSharedDirectory] = [:]
        for grant in grants {
            var isDirectory: ObjCBool = false
            guard grant.directory.isFileURL,
                  FileManager.default.fileExists(atPath: grant.directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw NSError(domain: "RiftVM.FolderSharing", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "Shared folder is unavailable: \(grant.directory.path). Reconnect it or remove its sharing permission before starting."])
            }
            guard !grant.guestName.contains("/"), directories[grant.guestName] == nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
            directories[grant.guestName] = VZSharedDirectory(url: grant.directory, readOnly: grant.readOnly)
        }
        let device = VZVirtioFileSystemDeviceConfiguration(tag: "riftvm_folders")
        device.share = VZMultipleDirectoryShare(directories: directories)
        return device
    }
}
