import Foundation
import XCTest
@testable import RiftVMCore

final class ActiveWorkspaceStoreTests: XCTestCase {
    func testAdoptingAWorkspaceRecordsItAndSurvivesAReload() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActiveWorkspaceStore(applicationSupportRoot: root.appending(path: "Support"))
        let bundle = root.appending(path: ".riftvm/Omarchy.riftvm", directoryHint: .isDirectory)

        let record = try store.adopt(bundleURL: bundle, name: "  Omarchy  ")
        XCTAssertEqual(record.name, "Omarchy")
        XCTAssertEqual(record.bundleURL.standardizedFileURL, bundle.standardizedFileURL)

        let reloaded = try XCTUnwrap(try store.load())
        XCTAssertEqual(reloaded.name, "Omarchy")
        XCTAssertEqual(reloaded.bundleURL, record.bundleURL)
        XCTAssertEqual(reloaded.createdAt, record.createdAt)
    }

    func testAdoptingAnotherBundleReplacesTheSingleRecord() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActiveWorkspaceStore(applicationSupportRoot: root.appending(path: "Support"))
        let first = root.appending(path: ".riftvm/Omarchy.riftvm", directoryHint: .isDirectory)
        let second = root.appending(path: ".riftvm/Other.riftvm", directoryHint: .isDirectory)

        _ = try store.adopt(bundleURL: first, name: "Omarchy")
        _ = try store.markOpened(at: Date(timeIntervalSince1970: 1_800_000_000))
        let replaced = try store.adopt(bundleURL: second, name: "Other")

        XCTAssertEqual(replaced.bundleURL.standardizedFileURL, second.standardizedFileURL)
        XCTAssertNil(replaced.lastOpenedAt, "a different bundle starts with a fresh record")
        XCTAssertEqual(try store.load()?.bundleURL.standardizedFileURL, second.standardizedFileURL)
    }

    func testCurrentFindsTheWorkspaceInTheDefaultDirectory() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appending(path: ".riftvm", directoryHint: .isDirectory)
        let bundle = base.appending(path: "Omarchy.riftvm", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        // A plain folder is not a workspace, however it is named.
        try FileManager.default.createDirectory(
            at: base.appending(path: "Notes", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        let store = ActiveWorkspaceStore(applicationSupportRoot: root.appending(path: "Support"))

        let record = try XCTUnwrap(try store.current(baseDirectory: base))
        XCTAssertEqual(record.bundleURL.standardizedFileURL, bundle.standardizedFileURL)
        XCTAssertEqual(record.name, "Omarchy")
        XCTAssertEqual(try store.load()?.bundleURL.standardizedFileURL, bundle.standardizedFileURL)
    }

    func testCurrentIgnoresARecordWhoseBundleIsGone() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appending(path: ".riftvm", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let store = ActiveWorkspaceStore(applicationSupportRoot: root.appending(path: "Support"))
        _ = try store.adopt(bundleURL: base.appending(path: "Vanished.riftvm"), name: "Vanished")

        XCTAssertNil(try store.current(baseDirectory: base))
    }

    func testDefaultBaseDirectoryIsTheHiddenRiftVMFolder() {
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".riftvm", directoryHint: .isDirectory)
        XCTAssertEqual(ActiveWorkspaceLocation.defaultBaseDirectory().path, expected.path)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "rift-active-workspace-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}
