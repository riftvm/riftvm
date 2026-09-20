import Foundation
import Virtualization

/// What the Prepare screen lets the user choose for the one Omarchy machine:
/// processors, memory, and the Mac folder it shares. The disk comes from the
/// signed factory image and is fixed for a release.
@MainActor
@Observable
final class OmarchyPreparationSettings {
    /// The machine's name is always Omarchy; there is nothing to choose.
    static let machineName = "Omarchy"
    static let storageBytes = UInt64(64) * .gibibyte

    var cpuCount: Int
    var memoryBytes: UInt64
    /// The Mac folder Omarchy shares first; empty means `~/riftvm-shared`.
    var sharedFolderPath = ""

    init(
        hostMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        activeProcessorCount: Int = ProcessInfo.processInfo.activeProcessorCount,
        profile: VMOmarchyProfile = .production
    ) {
        let tier = profile.resources(
            forHostMemory: hostMemoryBytes,
            activeProcessorCount: activeProcessorCount
        )
        cpuCount = tier.cpuCount
        memoryBytes = tier.memoryBytes
    }

    static var minimumCPUCount: Int { max(1, VZVirtualMachineConfiguration.minimumAllowedCPUCount) }

    static var maximumCPUCount: Int {
        max(minimumCPUCount, min(ProcessInfo.processInfo.activeProcessorCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount))
    }

    static var minimumMemoryBytes: UInt64 {
        max(VZVirtualMachineConfiguration.minimumAllowedMemorySize, 2 * .gibibyte)
    }

    /// Leaves the Mac 2 GB to work with.
    static var maximumMemoryBytes: UInt64 {
        let host = ProcessInfo.processInfo.physicalMemory
        let headroom = host > 2 * .gibibyte ? host - 2 * .gibibyte : host
        return max(minimumMemoryBytes, min(headroom, VZVirtualMachineConfiguration.maximumAllowedMemorySize))
    }
}

extension UInt64 {
    static let gibibyte = UInt64(1024 * 1024 * 1024)
}
