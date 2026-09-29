import Foundation
import XCTest
@testable import RiftVMCore

final class VMSnapshotIndexTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RiftVMIndexTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        try Data("config".utf8).write(to: temporaryRoot.appendingPathComponent("config.json"))
        try Data("disk".utf8).write(to: temporaryRoot.appendingPathComponent("Disk.img"))
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    func testRenameReplacesMetadataAtomicallyAndKeepsEveryOtherField() throws {
        let snapshot = try create("Before")
        let metadataURL = VMSnapshotManager.snapshotsRootURL(vmRootPath: temporaryRoot)
            .appendingPathComponent(snapshot.id)
            .appendingPathComponent("snapshot.json")
        let inodeBefore = try inode(of: metadataURL)

        guard case .success = VMSnapshotManager.renameSnapshot(
            vmRootPath: temporaryRoot,
            snapshot: snapshot,
            newName: "After"
        ) else {
            return XCTFail("Expected the rename to succeed")
        }

        // An atomic write replaces the file with a fully written one instead
        // of truncating the only copy of the metadata in place.
        XCTAssertNotEqual(try inode(of: metadataURL), inodeBefore)
        let renamed = try XCTUnwrap(VMSnapshotManager.listSnapshots(vmRootPath: temporaryRoot).first)
        XCTAssertEqual(renamed.name, "After")
        XCTAssertEqual(renamed.id, snapshot.id)
        XCTAssertEqual(renamed.fileManifest, snapshot.fileManifest)
        XCTAssertEqual(renamed.parentSnapshotID, snapshot.parentSnapshotID)
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: metadataURL.deletingLastPathComponent().path
        )
        XCTAssertEqual(Set(siblings), ["files", "snapshot.json"])
    }

    func testLoadIndexMatchesTheIndividualQueries() throws {
        let root = try create("Root")
        let child = try create("Child")
        guard case .success = VMSnapshotManager.restoreSnapshot(vmRootPath: temporaryRoot, snapshot: root) else {
            return XCTFail("Expected the restore to succeed")
        }
        let branch = try create("Branch")
        // Corrupt metadata is skipped by every query alike.
        let corrupt = VMSnapshotManager.snapshotsRootURL(vmRootPath: temporaryRoot)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: corrupt.appendingPathComponent("snapshot.json"))

        let index = VMSnapshotManager.loadIndex(vmRootPath: temporaryRoot)

        XCTAssertEqual(
            index.snapshots.map(\.id),
            VMSnapshotManager.listSnapshots(vmRootPath: temporaryRoot).map(\.id)
        )
        XCTAssertEqual(Set(index.snapshots.map(\.id)), [root.id, child.id, branch.id])
        XCTAssertEqual(index.currentSnapshotID, branch.id)
        XCTAssertEqual(index.currentSnapshotID, VMSnapshotManager.currentSnapshotID(vmRootPath: temporaryRoot))
        XCTAssertEqual(
            index.maximumASIFLayerDepth,
            VMSnapshotManager.maximumASIFLayerDepth(vmRootPath: temporaryRoot)
        )
        XCTAssertEqual(
            Self.flatten(index.tree),
            Self.flatten(VMSnapshotManager.snapshotTree(vmRootPath: temporaryRoot))
        )
        XCTAssertEqual(Self.flatten(index.tree), [
            "\(root.id)@0", "\(child.id)@1", "\(branch.id)@1",
        ])
    }

    func testLoadIndexOfMachineWithoutSnapshotsIsEmpty() {
        let index = VMSnapshotManager.loadIndex(vmRootPath: temporaryRoot)

        XCTAssertTrue(index.snapshots.isEmpty)
        XCTAssertTrue(index.tree.isEmpty)
        XCTAssertNil(index.currentSnapshotID)
        XCTAssertEqual(index.maximumASIFLayerDepth, 0)
    }

    func testCurrentSnapshotIDIgnoresStateThatPointsAtMissingSnapshot() throws {
        let snapshot = try create("Only")
        XCTAssertEqual(VMSnapshotManager.currentSnapshotID(vmRootPath: temporaryRoot), snapshot.id)

        try FileManager.default.removeItem(
            at: VMSnapshotManager.snapshotsRootURL(vmRootPath: temporaryRoot).appendingPathComponent(snapshot.id)
        )

        XCTAssertNil(VMSnapshotManager.currentSnapshotID(vmRootPath: temporaryRoot))
        XCTAssertNil(VMSnapshotManager.loadIndex(vmRootPath: temporaryRoot).currentSnapshotID)
    }

    func testDeletingCurrentLeafMovesCurrentSnapshotToParent() throws {
        let root = try create("Root")
        let child = try create("Child")

        guard case .failure = VMSnapshotManager.deleteSnapshot(vmRootPath: temporaryRoot, snapshot: root) else {
            return XCTFail("A snapshot with children must not be deleted")
        }
        guard case .success = VMSnapshotManager.deleteSnapshot(vmRootPath: temporaryRoot, snapshot: child) else {
            return XCTFail("Expected the leaf to be deleted")
        }

        let index = VMSnapshotManager.loadIndex(vmRootPath: temporaryRoot)
        XCTAssertEqual(index.snapshots.map(\.id), [root.id])
        XCTAssertEqual(index.currentSnapshotID, root.id)
    }

    func testCachedFormattersMatchFreshlyCreatedFormatters() {
        let reference = Date()
        let dates = [
            Date(timeIntervalSince1970: 0),
            Date(timeIntervalSince1970: 1_700_000_000),
            Date(timeIntervalSince1970: 1_711_846_800), // around a DST change in many zones
            reference.addingTimeInterval(-90),
            reference.addingTimeInterval(-3 * 86_400),
            reference.addingTimeInterval(7_200),
        ]
        for date in dates {
            let fresh = DateFormatter()
            fresh.dateFormat = "yyyy-MM-dd HH:mm"
            XCTAssertEqual(VMSnapshotDateFormatting.minuteTimestamp(date), fresh.string(from: date))
            let snapshot = VMSnapshotModel(
                id: UUID().uuidString,
                name: "Formatted",
                createdAt: date,
                parentSnapshotID: nil,
                totalSize: nil
            )
            XCTAssertEqual(snapshot.displayDate, fresh.string(from: date))

            let freshRelative = RelativeDateTimeFormatter()
            freshRelative.unitsStyle = .full
            XCTAssertEqual(
                VMSnapshotDateFormatting.relativeDescription(of: date, relativeTo: reference),
                freshRelative.localizedString(for: date, relativeTo: reference)
            )
        }
    }

    func testDefaultSnapshotNameUsesTheMinuteTimestamp() {
        let fresh = DateFormatter()
        fresh.dateFormat = "yyyy-MM-dd HH:mm"
        let before = "Snapshot \(fresh.string(from: Date()))"
        let name = VMSnapshotManager.defaultSnapshotName()
        let after = "Snapshot \(fresh.string(from: Date()))"

        XCTAssertTrue(name == before || name == after, name)
    }

    func testFormattersAreSafeToUseConcurrently() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let reference = date.addingTimeInterval(3_600)
        let expectedTimestamp = VMSnapshotDateFormatting.minuteTimestamp(date)
        let expectedRelative = VMSnapshotDateFormatting.relativeDescription(of: date, relativeTo: reference)
        let mismatches = MismatchCounter()

        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            if VMSnapshotDateFormatting.minuteTimestamp(date) != expectedTimestamp
                || VMSnapshotDateFormatting.relativeDescription(of: date, relativeTo: reference) != expectedRelative {
                mismatches.increment()
            }
        }

        XCTAssertEqual(mismatches.value, 0)
    }

    private final class MismatchCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    private static func flatten(_ nodes: [VMSnapshotTreeNode], depth: Int = 0) -> [String] {
        nodes.flatMap { ["\($0.snapshot.id)@\(depth)"] + flatten($0.children ?? [], depth: depth + 1) }
    }

    private func create(_ name: String) throws -> VMSnapshotModel {
        // Snapshot order is decided by creation time with second resolution
        // once it has been through the ISO 8601 metadata.
        Thread.sleep(forTimeInterval: 1.05)
        switch VMSnapshotManager.createSnapshot(vmRootPath: temporaryRoot, name: name) {
        case .success(let snapshot): return snapshot
        case .failure(let message):
            XCTFail(message)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func inode(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
    }
}
