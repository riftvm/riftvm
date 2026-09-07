@testable import RiftVMCLIKit
import CryptoKit
import Foundation
import XCTest
import RiftVMCore

final class RiftVMCLIKitTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testHostAppLocationResolvesHomebrewStyleCLISymlink() throws {
        let app = root.appendingPathComponent("RiftVM.app/Contents")
        let helper = app.appendingPathComponent("Helpers/riftvm")
        let executable = app.appendingPathComponent("MacOS/RiftVM")
        let bin = root.appendingPathComponent("bin/riftvm")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: helper.path, contents: Data()))
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try FileManager.default.createSymbolicLink(at: bin, withDestinationURL: helper)

        XCTAssertEqual(RiftVMExecutableLocation.hostAppExecutable(for: bin.path), executable)
        XCTAssertEqual(
            RiftVMExecutableLocation.hostAppExecutable(for: "riftvm", environment: ["PATH": bin.deletingLastPathComponent().path]),
            executable
        )
    }

    func testListIsSortedAndReportsValidMachineMetadata() throws {
        try makeMachine("Zulu.riftvm", name: "Zulu")
        try makeMachine("Alpha.riftvm", name: "Alpha")
        let (code, response) = RiftVMCLI().run(arguments: ["list", "--root", root.path])
        XCTAssertEqual(code, .success)
        guard case .array(let machines) = response.result else { return XCTFail("expected array") }
        XCTAssertEqual(machines.count, 2)
        guard case .object(let first) = machines[0] else { return XCTFail("expected object") }
        XCTAssertEqual(first["name"], .string("Alpha"))
        XCTAssertEqual(first["valid"], .bool(true))
        XCTAssertEqual(first["cpuCount"], .number(4))
    }

    func testValidateFailsDeterministicallyForMissingDisk() throws {
        let machine = try makeMachine("Broken.riftvm", name: "Broken", createDisk: false)
        let (code, response) = RiftVMCLI().run(arguments: ["validate", machine.path])
        XCTAssertEqual(code, .invalidMachine)
        XCTAssertEqual(response.error?.code, "invalid_machine")
        XCTAssertTrue(response.error?.message.contains("storage file is missing") == true)
    }

    func testListIncludesRegisteredWorkspaceOutsideDefaultDirectory() throws {
        let machine = try makeMachine("External/Registered.riftvm", name: "Registered")
        let support = root.appendingPathComponent("AppData")
        var registry = try WorkspaceRegistry(fileURL: support.appendingPathComponent("Workspaces.json"))
        _ = try registry.register(machine, profile: .linux)
        let (code, response) = RiftVMCLI().run(arguments: ["list"], environment: ["HOME": root.path, "RIFTVM_DATA_ROOT": support.path])
        XCTAssertEqual(code, .success)
        let json = String(data: try RiftVMCLI().encode(response), encoding: .utf8)!
        XCTAssertTrue(json.contains("Registered"))
    }

    func testInspectRejectsAmbiguousNamesAndAcceptsExactPath() throws {
        let first = try makeMachine("One/Same.riftvm", name: "Same")
        _ = try makeMachine("Two/Same.riftvm", name: "Same")
        let roots = [root.appendingPathComponent("One"), root.appendingPathComponent("Two")]
        let ambiguous = RiftVMCLI().run(arguments: ["inspect", "Same", "--root", roots[0].path, "--root", roots[1].path])
        XCTAssertEqual(ambiguous.0, .notFound)
        XCTAssertTrue(ambiguous.1.error?.message.contains("More than one") == true)
        XCTAssertEqual(RiftVMCLI().run(arguments: ["inspect", first.path]).0, .success)
    }

    func testSymlinkedMachineAndDiskAreNotTrusted() throws {
        let machine = try makeMachine("Real.riftvm", name: "Real")
        let alias = root.appendingPathComponent("Alias.riftvm")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: machine)
        XCTAssertEqual(RiftVMMachineInspector().discover(roots: [root]), [machine.standardizedFileURL])
        try FileManager.default.removeItem(at: machine.appendingPathComponent("Disk.img"))
        let outside = root.appendingPathComponent("outside.img")
        FileManager.default.createFile(atPath: outside.path, contents: Data())
        try FileManager.default.createSymbolicLink(at: machine.appendingPathComponent("Disk.img"), withDestinationURL: outside)
        XCTAssertFalse(RiftVMMachineInspector().inspect(machine).valid)
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

    func testPreinstalledImageManifestRejectsWrongIdentityArchitectureAndChecksum() throws {
        let disk = Data("test disk".utf8)
        let manifestURL = try makeManifest(disk: disk)
        XCTAssertNoThrow(try RiftVMPreinstalledImageManifest.load(from: manifestURL, minimumDiskSize: 1))

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        object["architecture"] = "x86_64"
        try JSONSerialization.data(withJSONObject: object).write(to: manifestURL)
        XCTAssertThrowsError(try RiftVMPreinstalledImageManifest.load(from: manifestURL, minimumDiskSize: 1))

        object["architecture"] = "arm64"
        var diskObject = try XCTUnwrap(object["disk"] as? [String: Any])
        diskObject["sha256"] = "not-a-digest"
        object["disk"] = diskObject
        try JSONSerialization.data(withJSONObject: object).write(to: manifestURL)
        XCTAssertThrowsError(try RiftVMPreinstalledImageManifest.load(from: manifestURL, minimumDiskSize: 1))
    }

    func testInstallImageVerifiesManifestAndInvokesHostApp() throws {
        let disk = Data("preinstalled image".utf8)
        let imageURL = root.appendingPathComponent("image.raw")
        try disk.write(to: imageURL)
        let manifestURL = try makeManifest(disk: disk)
        let destination = root.appendingPathComponent("Installed.riftvm")
        let fakeApp = try makeFakeApp(body: """
        destination=''
        while [ \"$#\" -gt 0 ]; do
          if [ \"$1\" = '--destination' ]; then destination=$2; shift 2; else shift; fi
        done
        mkdir -p \"$destination\"
        """)
        setenv("RIFTVM_APP_EXECUTABLE", fakeApp.path, 1)
        defer { unsetenv("RIFTVM_APP_EXECUTABLE") }

        let result = RiftVMCLI(minimumPreinstalledDiskSize: 1).run(arguments: [
            "install-image", manifestURL.path, "--image", imageURL.path,
            "--destination", destination.path, "--name", "Test VM", "--timeout", "5",
        ])
        XCTAssertEqual(result.0, .success)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        guard case .object(let value) = result.1.result else { return XCTFail("expected result object") }
        XCTAssertEqual(value["productID"], .string("example.image"))
        XCTAssertEqual(value["name"], .string("Test VM"))
    }

    func testInstallImagePassesOptionalThumbnailToHostApp() throws {
        let disk = Data("preinstalled image with thumbnail".utf8)
        let imageURL = root.appendingPathComponent("image.raw")
        try disk.write(to: imageURL)
        let thumbnailURL = root.appendingPathComponent("thumbnail.png")
        try Data("thumbnail".utf8).write(to: thumbnailURL)
        let manifestURL = try makeManifest(disk: disk)
        let destination = root.appendingPathComponent("Installed.riftvm")
        let fakeApp = try makeFakeApp(body: """
        destination=''
        thumbnail=''
        while [ "$#" -gt 0 ]; do
          if [ "$1" = '--destination' ]; then destination=$2; shift 2
          elif [ "$1" = '--thumbnail' ]; then thumbnail=$2; shift 2
          else shift; fi
        done
        test "$thumbnail" = "\(thumbnailURL.path)"
        mkdir -p "$destination"
        """)
        setenv("RIFTVM_APP_EXECUTABLE", fakeApp.path, 1)
        defer { unsetenv("RIFTVM_APP_EXECUTABLE") }

        let result = RiftVMCLI(minimumPreinstalledDiskSize: 1).run(arguments: [
            "install-image", manifestURL.path, "--image", imageURL.path,
            "--destination", destination.path, "--thumbnail", thumbnailURL.path, "--timeout", "5",
        ])
        XCTAssertEqual(result.0, .success)
    }

    func testInstallImageTimeoutRemovesPartialDestination() throws {
        let disk = Data("interrupted image".utf8)
        let imageURL = root.appendingPathComponent("image.raw")
        try disk.write(to: imageURL)
        let manifestURL = try makeManifest(disk: disk)
        let destination = root.appendingPathComponent("Interrupted.riftvm")
        let fakeApp = try makeFakeApp(body: """
        destination=''
        staging_token=''
        while [ \"$#\" -gt 0 ]; do
          if [ \"$1\" = '--destination' ]; then destination=$2; shift 2
          elif [ \"$1\" = '--staging-token' ]; then staging_token=$2; shift 2
          else shift; fi
        done
        mkdir -p \"$destination\"
        mkdir -p \"$(dirname \"$destination\")/.$(basename \"$destination\").install-$staging_token\"
        sleep 10
        """)
        setenv("RIFTVM_APP_EXECUTABLE", fakeApp.path, 1)
        defer { unsetenv("RIFTVM_APP_EXECUTABLE") }

        let result = RiftVMCLI(minimumPreinstalledDiskSize: 1).run(arguments: [
            "install-image", manifestURL.path, "--image", imageURL.path,
            "--destination", destination.path, "--timeout", "1",
        ])
        XCTAssertEqual(result.0, .unavailable)
        XCTAssertEqual(result.1.error?.code, "install_timeout")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".Interrupted.riftvm.install-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testInstallImageRejectsModifiedDiskBeforeLaunchingApp() throws {
        let original = Data("original image".utf8)
        let manifestURL = try makeManifest(disk: original)
        let imageURL = root.appendingPathComponent("image.raw")
        try Data("modified image".utf8).write(to: imageURL)
        let destination = root.appendingPathComponent("Rejected.riftvm")
        let result = RiftVMCLI(minimumPreinstalledDiskSize: 1).run(arguments: [
            "install-image", manifestURL.path, "--image", imageURL.path, "--destination", destination.path,
        ])
        XCTAssertEqual(result.0, .invalidMachine)
        XCTAssertEqual(result.1.error?.code, "image_checksum_mismatch")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    @discardableResult
    private func makeMachine(_ relative: String, name: String, createDisk: Bool = true) throws -> URL {
        let machine = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: machine, withIntermediateDirectories: true)
        let config: [String: Any] = [
            "type": "linux", "name": name, "cpu": ["count": 4],
            "memory": ["size": 4_294_967_296 as UInt64],
            "storageDevices": [["type": "Block", "imagePath": "Disk.img", "size": 1024]],
        ]
        try JSONSerialization.data(withJSONObject: config).write(to: machine.appendingPathComponent("config.json"))
        if createDisk { FileManager.default.createFile(atPath: machine.appendingPathComponent("Disk.img").path, contents: Data()) }
        return machine
    }

    private func makeManifest(disk: Data) throws -> URL {
        let digest = SHA256.hash(data: disk).map { String(format: "%02x", $0) }.joined()
        let value: [String: Any] = [
            "schemaVersion": 1,
            "kind": "io.github.everettjf.riftvm.preinstalled-image",
            "architecture": "arm64",
            "minimumRiftVMVersion": "1.0.0",
            "product": ["id": "example.image", "name": "Example", "version": "1.0.0"],
            "disk": ["format": "raw", "virtualSize": disk.count, "sha256": digest],
            "virtualMachine": ["name": "Example VM", "remark": "Test image"],
        ]
        let url = root.appendingPathComponent("preinstalled-image.json")
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url)
        return url
    }

    private func makeFakeApp(body: String) throws -> URL {
        let url = root.appendingPathComponent("fake-riftvm-app")
        try ("#!/bin/sh\nset -eu\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
