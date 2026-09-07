import XCTest
@testable import RiftVMCore

final class WorkspaceRegistryTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("riftvm-registry-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func bundle(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name + ".riftvm")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func registry() throws -> WorkspaceRegistry { try .init(fileURL: directory.appendingPathComponent("Registry.json")) }

    func testDefaultRoutesSurviveReloadAndMissingDiskDoesNotFallThrough() throws {
        var store = try registry()
        XCTAssertEqual(store.launchRoute, .create)
        let first = try store.register(bundle("First"), profile: .omarchy)
        XCTAssertEqual(store.launchRoute, .open(first.id))
        let second = try store.register(bundle("Second"), profile: .macOS)
        XCTAssertEqual(store.launchRoute, .choose)
        try store.setDefault(second.id)
        try FileManager.default.removeItem(at: second.location)
        XCTAssertEqual(try registry().launchRoute, .open(second.id))
        try store.remove(second.id)
        XCTAssertNil(store.defaultID)
        XCTAssertEqual(store.launchRoute, .open(first.id))
    }

    func testTwoOmarchyInstancesAndRepeatedRegistrationHaveIndependentStableIdentity() throws {
        var store = try registry()
        let a = try store.register(bundle("One"), profile: .omarchy)
        let b = try store.register(bundle("Two"), profile: .omarchy)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(try store.register(a.location, profile: .omarchy).id, a.id)
        XCTAssertEqual(try registry().workspaces.count, 2)
    }

    func testCopyIdentityIsRejectedAndMovePreservesDefault() throws {
        var store = try registry()
        let original = try store.register(bundle("Original"), profile: .macOS)
        try store.setDefault(original.id)
        let copy = directory.appendingPathComponent("Copy.riftvm")
        try FileManager.default.copyItem(at: original.location, to: copy)
        XCTAssertThrowsError(try store.register(copy, profile: .macOS))
        XCTAssertEqual(store.workspaces.count, 1)
        try FileManager.default.removeItem(at: original.location)
        let moved = try store.register(copy, profile: .macOS)
        XCTAssertEqual(moved.id, original.id)
        XCTAssertEqual(try registry().defaultID, original.id)
    }

    func testCorruptionCannotSilentlyResetRegistryOrWorkspaceIdentity() throws {
        var store = try registry()
        let root = try bundle("Damaged")
        try Data("invalid".utf8).write(to: root.appendingPathComponent(WorkspaceIdentity.fileName))
        XCTAssertThrowsError(try store.register(root, profile: .omarchy))
        XCTAssertTrue(store.workspaces.isEmpty)
        try Data("invalid".utf8).write(to: store.fileURL)
        XCTAssertThrowsError(try registry())
        XCTAssertEqual(try String(contentsOf: store.fileURL, encoding: .utf8), "invalid")
    }

    @MainActor
    func testLeaseRejectsSameIdentityAtAnotherPath() throws {
        let first = try bundle("FirstLease")
        let second = try bundle("SecondLease")
        let identity = WorkspaceIdentity(profile: .omarchy)
        try identity.write(to: first)
        try identity.write(to: second)
        let leases = VMRunningRegistry(lockDirectory: directory.appendingPathComponent("Leases"))
        let original = try XCTUnwrap(leases.acquire(rootPath: first))
        XCTAssertNil(leases.acquire(rootPath: second))
        leases.release(original)
        let next = try XCTUnwrap(leases.acquire(rootPath: second))
        leases.release(next)
    }

    func testForgetPreservesAllWorkspaceFilesAndProfileCannotChange() throws {
        var store = try registry()
        let record = try store.register(bundle("Keep"), profile: .linux)
        XCTAssertThrowsError(try store.register(record.location, profile: .omarchy))
        try store.remove(record.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.location.path))
        XCTAssertEqual(try WorkspaceIdentity.load(at: record.location).id, record.id)
    }
}
