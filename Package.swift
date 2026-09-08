// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "RiftVMCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "RiftVMCore", targets: ["RiftVMCore"]),
        .library(name: "RiftVMCLIKit", targets: ["RiftVMCLIKit"]),
        .executable(name: "riftvm", targets: ["riftvm"]),
        .executable(name: "omarchy-factory-tool", targets: ["OmarchyFactoryTool"]),
        .executable(name: "omarchy-rollback-acceptance-tool", targets: ["OmarchyRollbackAcceptanceTool"]),
        .executable(name: "omarchy-soak-acceptance-tool", targets: ["OmarchySoakAcceptanceTool"]),
    ],
    targets: [
        .target(
            name: "RiftVMCore",
            path: "RiftVM/RiftVM/Core/VMKit",
            exclude: [
                "Catalog",
                "Model/VMModel.swift",
                "Model/VMOSType.swift",
                "Model/Fields/VMModelFieldAudioDevice.swift",
                "Model/Fields/VMModelFieldCPU.swift",
                "Model/Fields/VMModelFieldDirectorySharingDevice.swift",
                "Model/Fields/VMModelFieldGraphicDevice.swift",
                "Model/Fields/VMModelFieldMemory.swift",
                "Model/Fields/VMModelFieldPointingDevice.swift",
                "Model/Fields/VMModelFieldStorageDevice.swift",
                "OS",
                "GuestAgent/VMGuestAgentHostClient.swift",
                "VMOSCreator.swift",
                "VMOSDownloader.swift",
                "VMOSRunner.swift",
            ],
            sources: [
                "Common/VMOSResultVoid.swift",
                "Common/VMOSHelper.swift",
                "Common/VMPortabilityManager.swift",
                "Common/VMRunningRegistry.swift",
                "GuestAgent/VMGuestAgentProtocol.swift",
                "GuestAgent/VMGuestAgentEnrollmentStore.swift",
                "Model/Fields/VMModelFieldNetworkDevice.swift",
                "Profile/VMOmarchyProfile.swift",
                "Profile/VMOmarchyStorageForecast.swift",
                "Profile/VMOmarchyFactoryManifest.swift",
                "Profile/VMOmarchyFactoryInstaller.swift",
                "Profile/VMOmarchyDiagnostics.swift",
                "Profile/VMOmarchyWorkspace.swift",
                "Profile/VMOmarchySharedFolderImporter.swift",
                "Profile/VMOmarchyVirtualMachineBuilder.swift",
                "Profile/VMOmarchyGuestAgentClient.swift",
                "Profile/RiftWorkspaceRegistry.swift",
                "Snapshot/VMSnapshotManager.swift",
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-weak_framework",
                    "-Xlinker", "DiskImageKit",
                ], .when(platforms: [.macOS])),
            ]
        ),
        .testTarget(
            name: "RiftVMCoreTests",
            dependencies: ["RiftVMCore"],
            path: "Tests/RiftVMCoreTests"
        ),
        .target(name: "RiftVMCLIKit", path: "CLI/Kit"),
        .executableTarget(
            name: "riftvm",
            dependencies: ["RiftVMCLIKit"],
            path: "CLI/Executable"
        ),
        .executableTarget(
            name: "OmarchyFactoryTool",
            dependencies: ["RiftVMCore"],
            path: "Tools/OmarchyFactoryTool"
        ),
        .executableTarget(
            name: "OmarchyRollbackAcceptanceTool",
            dependencies: ["RiftVMCore"],
            path: "Tools/OmarchyRollbackAcceptanceTool"
        ),
        .executableTarget(
            name: "OmarchySoakAcceptanceTool",
            path: "Tools/OmarchySoakAcceptanceTool"
        ),
        .testTarget(
            name: "RiftVMCLIKitTests",
            dependencies: ["RiftVMCLIKit"],
            path: "Tests/RiftVMCLIKitTests"
        ),
    ]
)
