import Foundation
import XCTest
@testable import RiftVMCore

final class RiftWorkspaceRegistryTests: XCTestCase {
    func testRegistryPersistsDistinctOmarchyWorkspaces() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RiftWorkspaceRegistryStore(applicationSupportRoot: root)
        let first = try workspace(name: "Work", kind: .omarchy)
        let second = try workspace(name: "Personal", kind: .omarchy)

        _ = try store.register(first)
        _ = try store.register(second)

        let loaded = try store.load()
        XCTAssertEqual(loaded.workspaces, [first, second])
    }

    func testRegistryRejectsDuplicateIdentityAndBundleWithoutChangingDisk() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RiftWorkspaceRegistryStore(applicationSupportRoot: root)
        let first = try workspace(name: "Work", kind: .omarchy)
        _ = try store.register(first)
        let original = try Data(contentsOf: store.registryURL)

        let duplicateIdentity = try RiftWorkspaceRecord(
            id: first.id,
            name: "Other",
            kind: .macOS,
            bundleURL: root.appending(path: "Other.riftvm")
        )
        XCTAssertThrowsError(try store.register(duplicateIdentity)) {
            XCTAssertEqual($0 as? RiftWorkspaceRegistryError, .duplicateIdentifier)
        }

        let duplicateBundle = try RiftWorkspaceRecord(
            name: "Other",
            kind: .macOS,
            bundleURL: first.bundleURL
        )
        XCTAssertThrowsError(try store.register(duplicateBundle)) {
            XCTAssertEqual($0 as? RiftWorkspaceRegistryError, .duplicateBundleURL)
        }
        XCTAssertEqual(try Data(contentsOf: store.registryURL), original)
    }

    func testUnregisterDoesNotDeleteWorkspaceBundle() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appending(path: "Keep.riftvm", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let marker = bundle.appending(path: "do-not-delete")
        try Data("kept".utf8).write(to: marker)
        let record = try RiftWorkspaceRecord(name: "Keep", kind: .omarchy, bundleURL: bundle)
        let store = RiftWorkspaceRegistryStore(applicationSupportRoot: root.appending(path: "Support"))
        _ = try store.register(record)

        let snapshot = try store.unregister(record.id)

        XCTAssertTrue(snapshot.workspaces.isEmpty)
        XCTAssertEqual(try Data(contentsOf: marker), Data("kept".utf8))
    }

    func testRegisterIfNeededIsIdempotent() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RiftWorkspaceRegistryStore(applicationSupportRoot: root)
        let bundle = root.appending(path: "macOS.riftvm", directoryHint: .isDirectory)

        let first = try store.registerIfNeeded(name: "macOS", kind: .macOS, bundleURL: bundle)
        let second = try store.registerIfNeeded(name: "Renamed", kind: .omarchy, bundleURL: bundle)

        XCTAssertEqual(first.workspaces.count, 1)
        XCTAssertEqual(second.workspaces, first.workspaces)
    }

    func testRenamePinAndLastOpenedPersist() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RiftWorkspaceRegistryStore(applicationSupportRoot: root)
        let record = try workspace(name: "Original", kind: .macOS)
        _ = try store.register(record)
        let openedAt = Date(timeIntervalSince1970: 1_800_000_000)

        _ = try store.rename(record.id, to: "  Daily Driver  ")
        _ = try store.setPinned(record.id, pinned: true)
        let updated = try store.markOpened(record.id, at: openedAt)

        XCTAssertEqual(updated.workspaces[0].name, "Daily Driver")
        XCTAssertNotNil(updated.workspaces[0].pinnedAt)
        XCTAssertEqual(updated.workspaces[0].lastOpenedAt, openedAt)
    }

    private func workspace(name: String, kind: RiftWorkspaceKind) throws -> RiftWorkspaceRecord {
        try RiftWorkspaceRecord(
            name: name,
            kind: kind,
            bundleURL: URL(filePath: "/tmp/\(UUID().uuidString).riftvm")
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "rift-workspace-registry-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}
