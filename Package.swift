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
        .executable(name: "omarchy-workspace-acceptance-tool", targets: ["OmarchyWorkspaceAcceptanceTool"]),
        .executable(name: "omarchy-rollback-acceptance-tool", targets: ["OmarchyRollbackAcceptanceTool"]),
        .executable(name: "omarchy-soak-acceptance-tool", targets: ["OmarchySoakAcceptanceTool"]),
    ],
    targets: [
        .target(
            name: "RiftVMCore",
            path: "RiftVM/RiftVM/Core/VMKit",
            exclude: [
                "Graphics/VMCustomVirGLGraphics.swift",
            ],
            sources: [
                "Common/VMOSResultVoid.swift",
                "Common/VMOSHelper.swift",
                "Common/VMDisplayCursorPolicy.swift",
                "Common/VMCreateProgressMeterPolicy.swift",
                "Common/VMRunningRegistry.swift",
                "GuestAgent/VMGuestAgentProtocol.swift",
                "GuestAgent/VMGuestAgentEnrollmentStore.swift",
                "Profile/VMOmarchyProfile.swift",
                "Profile/VMOmarchyStorageForecast.swift",
                "Profile/VMOmarchyFactoryManifest.swift",
                "Profile/VMOmarchyFactoryInstaller.swift",
                "Profile/VMOmarchyDiagnostics.swift",
                "Profile/VMOmarchyWorkspace.swift",
                "Profile/VMOmarchySharedFolderImporter.swift",
                "Profile/VMOmarchySharedFolders.swift",
                "Profile/VMOmarchyVirtualMachineBuilder.swift",
                "Profile/VMOmarchyGuestAgentClient.swift",
                "Profile/ActiveWorkspace.swift",
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
            name: "OmarchyWorkspaceAcceptanceTool",
            dependencies: ["RiftVMCore"],
            path: "Tools/OmarchyWorkspaceAcceptanceTool"
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
