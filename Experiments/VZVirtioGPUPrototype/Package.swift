// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "VZVirtioGPUPrototype",
    // Match RiftVM's WWDC26 release baseline and its Custom Virtio APIs.
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "RiftVMVirGLRuntime", targets: ["RiftVMVirGLRuntime"]),
        .executable(name: "vz-virtio-gpu-prototype", targets: ["VZVirtioGPUPrototype"]),
    ],
    targets: [
        .target(
            name: "CVirGLBridge",
            linkerSettings: [.linkedLibrary("dl")]
        ),
        .target(
            name: "RiftVMVirGLRuntime",
            dependencies: ["CVirGLBridge"],
            path: "Sources/VZVirtioGPUPrototype"
        ),
        .executableTarget(
            name: "VZVirtioGPUPrototype",
            dependencies: ["RiftVMVirGLRuntime"],
            path: "Sources/VZVirtioGPUPrototypeRunner"
        ),
        .testTarget(
            name: "VZVirtioGPUPrototypeTests",
            dependencies: ["RiftVMVirGLRuntime"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
