import Foundation
import Darwin
import XCTest
@testable import RiftVMCore

final class VMSnapshotFileCopierTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RiftVMCopierTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    func testDataCopyReportsMonotonicProgressAndPreservesContentAndAttributes() throws {
        let source = temporaryRoot.appendingPathComponent("Disk.img")
        let destination = temporaryRoot.appendingPathComponent("Disk-copy.img")
        let payload = Self.payload(megabytes: 12)
        try payload.write(to: source)
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o640, .modificationDate: modified],
            ofItemAtPath: source.path
        )
        XCTAssertEqual(setxattr(source.path, "com.riftvm.test", "value", 5, 0, 0), 0)

        var updates: [UInt64] = []
        try VMSnapshotFileCopier.copyItem(at: source, to: destination, allowClone: false) { copied in
            updates.append(copied)
        }

        XCTAssertFalse(updates.isEmpty, "A data copy must report progress inside the file")
        XCTAssertEqual(updates, updates.sorted())
        XCTAssertEqual(updates.last, UInt64(payload.count))
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        XCTAssertEqual(attributes[.modificationDate] as? Date, modified)
        var buffer = [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(getxattr(destination.path, "com.riftvm.test", &buffer, buffer.count, 0, 0), 5)
        XCTAssertEqual(String(decoding: buffer.prefix(5), as: UTF8.self), "value")
    }

    func testCancellationDuringDataCopyRemovesPartialDestination() throws {
        let source = temporaryRoot.appendingPathComponent("Disk.img")
        let destination = temporaryRoot.appendingPathComponent("Disk-copy.img")
        let payload = Self.payload(megabytes: 12)
        try payload.write(to: source)

        var cancelled = false
        var updates: [UInt64] = []
        XCTAssertThrowsError(
            try VMSnapshotFileCopier.copyItem(
                at: source,
                to: destination,
                allowClone: false,
                isCancelled: { cancelled },
                progress: { copied in
                    updates.append(copied)
                    cancelled = true
                }
            )
        ) { error in
            XCTAssertTrue(error is VMSnapshotFileCopier.Cancelled, "\(error)")
        }

        XCTAssertEqual(updates.count, 1, "The copy must stop at the first step after cancellation")
        XCTAssertLessThan(try XCTUnwrap(updates.first), UInt64(payload.count))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: source), payload)
    }

    func testCancellationRequestedBeforeCopyCreatesNothing() throws {
        let source = temporaryRoot.appendingPathComponent("Disk.img")
        let destination = temporaryRoot.appendingPathComponent("Disk-copy.img")
        try Data("disk".utf8).write(to: source)

        XCTAssertThrowsError(
            try VMSnapshotFileCopier.copyItem(at: source, to: destination, isCancelled: { true })
        ) { error in
            XCTAssertTrue(error is VMSnapshotFileCopier.Cancelled, "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testDefaultCopyClonesOrCopiesRegularFileContent() throws {
        let source = temporaryRoot.appendingPathComponent("Disk.img")
        let destination = temporaryRoot.appendingPathComponent("Disk-copy.img")
        let payload = Self.payload(megabytes: 2)
        try payload.write(to: source)

        try VMSnapshotFileCopier.copyItem(at: source, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), payload)
        // The copy is independent of the source.
        try Data("changed".utf8).write(to: source)
        XCTAssertEqual(try Data(contentsOf: destination), payload)
    }

    func testEmptyRegularFileIsCopied() throws {
        let source = temporaryRoot.appendingPathComponent("empty")
        let destination = temporaryRoot.appendingPathComponent("empty-copy")
        try Data().write(to: source)

        try VMSnapshotFileCopier.copyItem(at: source, to: destination, allowClone: false)
        try VMSnapshotFileCopier.copyItem(
            at: source,
            to: temporaryRoot.appendingPathComponent("empty-clone")
        )

        XCTAssertEqual(try Data(contentsOf: destination), Data())
        XCTAssertEqual(try Data(contentsOf: temporaryRoot.appendingPathComponent("empty-clone")), Data())
    }

    func testExistingDestinationIsNeverOverwrittenOrRemoved() throws {
        let source = temporaryRoot.appendingPathComponent("Disk.img")
        let destination = temporaryRoot.appendingPathComponent("Disk-copy.img")
        try Data("new".utf8).write(to: source)
        try Data("existing".utf8).write(to: destination)

        for allowClone in [true, false] {
            XCTAssertThrowsError(
                try VMSnapshotFileCopier.copyItem(at: source, to: destination, allowClone: allowClone)
            ) { error in
                XCTAssertEqual((error as? CocoaError)?.code, .fileWriteFileExists, "\(error)")
            }
            XCTAssertEqual(try Data(contentsOf: destination), Data("existing".utf8))
        }
    }

    func testMissingSourceReportsFileManagerError() throws {
        let source = temporaryRoot.appendingPathComponent("missing")
        let destination = temporaryRoot.appendingPathComponent("missing-copy")

        XCTAssertThrowsError(try VMSnapshotFileCopier.copyItem(at: source, to: destination)) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileReadNoSuchFile, "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testDirectoryIsCopiedRecursivelyLikeFileManager() throws {
        let source = temporaryRoot.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("Inner", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("one".utf8).write(to: source.appendingPathComponent("one.txt"))
        try Data("two".utf8).write(to: source.appendingPathComponent("Inner/two.txt"))
        let destination = temporaryRoot.appendingPathComponent("Nested-copy", isDirectory: true)

        try VMSnapshotFileCopier.copyItem(at: source, to: destination, allowClone: false)

        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("one.txt")), Data("one".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Inner/two.txt")), Data("two".utf8))
    }

    func testSymbolicLinkIsCopiedAsLinkAndNeverFollowed() throws {
        let target = temporaryRoot.appendingPathComponent("target")
        try Data("target".utf8).write(to: target)
        let source = temporaryRoot.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: "target")
        let destination = temporaryRoot.appendingPathComponent("link-copy")

        try VMSnapshotFileCopier.copyItem(at: source, to: destination)

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), "target")
    }

    /// Non-repeating content, so the copy can neither be deduplicated nor
    /// stored as a hole.
    private static func payload(megabytes: Int) -> Data {
        var data = Data(count: megabytes * 1024 * 1024)
        data.withUnsafeMutableBytes { buffer in
            var value: UInt64 = 0x9E37_79B9_7F4A_7C15
            for index in stride(from: 0, to: buffer.count, by: 8) {
                value = value &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                buffer.storeBytes(of: value, toByteOffset: index, as: UInt64.self)
            }
        }
        return data
    }
}
