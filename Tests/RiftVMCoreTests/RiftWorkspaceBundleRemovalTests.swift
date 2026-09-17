import Foundation
import XCTest
@testable import RiftVMCore

final class RiftWorkspaceBundleRemovalTests: XCTestCase {
    func testMissingBundleIsNotAnErrorSoItsRecordStaysRemovable() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RiftWorkspaceRegistryStore(applicationSupportRoot: root.appending(path: "Support"))
        let bundle = root.appending(path: "Vanished.riftvm", directoryHint: .isDirectory)
        let record = try RiftWorkspaceRecord(name: "Vanished", kind: .omarchy, bundleURL: bundle)
        _ = try store.register(record)

        // The bundle was deleted behind RiftVM's back. Moving it to the Trash
        // used to fail with "The file … doesn't exist.", which aborted the
        // removal and left an undeletable entry in the control center.
        XCTAssertNil(try RiftWorkspaceBundleRemoval.moveToTrashIfPresent(bundle))

        let snapshot = try store.unregister(record.id)
        XCTAssertTrue(snapshot.workspaces.isEmpty)
    }

    func testExistingBundleIsTrashedAndItsNewLocationReported() throws {
        let bundle = URL(filePath: "/tmp/\(UUID().uuidString).riftvm", directoryHint: .isDirectory)
        let fileManager = RecordingTrashFileManager()

        let trashedURL = try RiftWorkspaceBundleRemoval.moveToTrashIfPresent(bundle, fileManager: fileManager)

        XCTAssertEqual(fileManager.trashedURLs, [bundle])
        XCTAssertEqual(trashedURL, fileManager.resultingURL)
    }

    func testUnrelatedTrashFailuresStillPropagate() throws {
        let bundle = URL(filePath: "/tmp/\(UUID().uuidString).riftvm", directoryHint: .isDirectory)
        let fileManager = RecordingTrashFileManager()
        fileManager.failure = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)

        // A bundle that is still on disk must keep its entry: the caller
        // reports the failure instead of dropping the record.
        XCTAssertThrowsError(try RiftWorkspaceBundleRemoval.moveToTrashIfPresent(bundle, fileManager: fileManager))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "rift-workspace-removal-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}

private final class RecordingTrashFileManager: FileManager {
    let resultingURL = URL(filePath: "/tmp/Trash/\(UUID().uuidString).riftvm")
    private(set) var trashedURLs: [URL] = []
    var failure: Error?

    override func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        if let failure { throw failure }
        trashedURLs.append(url)
        outResultingURL?.pointee = resultingURL as NSURL
    }
}
