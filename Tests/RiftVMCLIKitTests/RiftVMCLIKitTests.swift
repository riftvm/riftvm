@testable import RiftVMCLIKit
import CryptoKit
import Foundation
import XCTest

final class RiftVMCLIKitTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testInspectReadsTheOmarchyWorkspaceLayout() throws {
        let bundle = try makeOmarchyWorkspace("Omarchy.riftvm", cpuCount: 6, memoryBytes: 6_442_450_944)
        let (code, response) = RiftVMCLI().run(arguments: ["inspect", bundle.path])
        XCTAssertEqual(code, .success)
        guard case .object(let summary) = response.result else { return XCTFail("expected object") }
        XCTAssertEqual(summary["osType"], .string("linux"))
        XCTAssertEqual(summary["cpuCount"], .number(6))
        XCTAssertEqual(summary["memoryBytes"], .number(6_442_450_944))
        XCTAssertEqual(summary["valid"], .bool(true))
        XCTAssertEqual(summary["path"], .string(bundle.standardizedFileURL.path))
    }

    func testValidateReportsAMissingWorkspaceDisk() throws {
        let bundle = try makeOmarchyWorkspace("Broken.riftvm", createDisk: false)
        let (code, response) = RiftVMCLI().run(arguments: ["validate", bundle.path])
        XCTAssertEqual(code, .invalidMachine)
        XCTAssertEqual(response.error?.code, "invalid_machine")
        XCTAssertTrue(response.error?.message.contains("storage file is missing") == true)
    }

    func testOutputSchemaIsStableSortedJSONWithNewline() throws {
        let cli = RiftVMCLI()
        let data = try cli.encode(.init(command: "list", result: .array([])))
        XCTAssertEqual(data.last, 0x0a)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"command":"list","result":[],"schemaVersion":1,"success":true}"# + "\n")
    }

    func testArgumentsAndNotFoundUseDocumentedExitCodes() {
        XCTAssertEqual(RiftVMCLI().run(arguments: []).0, .invalidArguments)
        XCTAssertEqual(RiftVMCLI().run(arguments: ["wat"]).0, .invalidArguments)
        XCTAssertEqual(RiftVMCLI().run(arguments: ["inspect", "missing", "--root", root.path]).0, .notFound)
        XCTAssertEqual(RiftVMCLI().run(arguments: ["list", "unexpected"]).0, .invalidArguments)
        XCTAssertEqual(RiftVMCLI().run(arguments: ["start"]).0, .invalidArguments)
        XCTAssertEqual(RiftVMCLI().run(arguments: ["stop"]).0, .invalidArguments)
        XCTAssertEqual(RiftVMCLI().run(arguments: ["status"]).0, .invalidArguments)
        XCTAssertEqual(RiftVMCLI().run(arguments: ["start", "vm", "--timeout", "0"]).0, .invalidArguments)
        XCTAssertEqual(RiftVMCLI().run(arguments: ["install-image"]).0, .invalidArguments)
    }

    @discardableResult
    private func makeOmarchyWorkspace(
        _ relative: String,
        createDisk: Bool = true,
        cpuCount: Int = 4,
        memoryBytes: UInt64 = 8_589_934_592
    ) throws -> URL {
        let bundle = root.appendingPathComponent(relative)
        let workspace = bundle.appendingPathComponent("Workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let config: [String: Any] = [
            "schemaVersion": 2,
            "productID": "com.riftvm.app.omarchy",
            "createdAt": 810_886_380.48,
            "factoryImageVersion": "v4.0.3-riftvm.7",
            "cpuCount": cpuCount,
            "memoryBytes": memoryBytes,
        ]
        try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
            .write(to: workspace.appendingPathComponent("Configuration.json"))
        try Data("machine-identity".utf8).write(to: workspace.appendingPathComponent("MachineIdentifier"))
        if createDisk {
            FileManager.default.createFile(atPath: workspace.appendingPathComponent("Disk.asif").path, contents: Data())
        }
        return bundle
    }
}
