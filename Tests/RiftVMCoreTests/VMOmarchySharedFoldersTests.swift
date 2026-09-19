import Foundation
import Virtualization
import XCTest
@testable import RiftVMCore

final class VMOmarchySharedFoldersTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "shared-folders-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testDefaultFolderIsInHomeForARealMachine() {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        let folder = VMOmarchySharedFolderStore.defaultFolder(
            forBundle: URL(filePath: "/Users/someone/.riftvm/Omarchy.riftvm", directoryHint: .isDirectory),
            homeDirectory: home
        )
        XCTAssertEqual(folder.path, "/Users/someone/riftvm-shared")
    }

    func testDefaultFolderStaysBesideATemporaryMachine() {
        let folder = VMOmarchySharedFolderStore.defaultFolder(
            forBundle: URL(filePath: "/private/tmp/acceptance.riftvm", directoryHint: .isDirectory),
            homeDirectory: URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        )
        XCTAssertEqual(folder.path, "/private/tmp/riftvm-shared")
    }

    func testLoadMovesTheLegacyFolderToTheDefault() throws {
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let bundle = home.appending(path: ".riftvm/Omarchy.riftvm", directoryHint: .isDirectory)
        let layout = VMOmarchyWorkspaceLayout(
            applicationSupportRoot: bundle,
            sharedRoot: home.appending(path: ".riftvm/RiftVM Shared", directoryHint: .isDirectory)
        )
        try FileManager.default.createDirectory(at: layout.shared, withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: layout.shared.appending(path: "notes.txt"))

        let settings = VMOmarchySharedFolderStore.load(layout: layout, homeDirectory: home)

        // The test tree is under the temporary directory, so the default is
        // beside the bundle rather than in `home`.
        let expected = VMOmarchySharedFolderStore.defaultFolder(forBundle: bundle, homeDirectory: home)
        XCTAssertEqual(settings.folders.map(\.path), [expected])
        XCTAssertFalse(settings.guestSupportsMultipleFolders)
        XCTAssertEqual(try Data(contentsOf: expected.appending(path: "notes.txt")), Data("kept".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.shared.path))
        XCTAssertEqual(VMOmarchySharedFolderStore.load(layout: layout, homeDirectory: home), settings)
    }

    func testLoadKeepsTheLegacyFolderWhenTheDefaultIsTaken() throws {
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let bundle = home.appending(path: ".riftvm/Omarchy.riftvm", directoryHint: .isDirectory)
        let layout = VMOmarchyWorkspaceLayout(
            applicationSupportRoot: bundle,
            sharedRoot: home.appending(path: ".riftvm/RiftVM Shared", directoryHint: .isDirectory)
        )
        try FileManager.default.createDirectory(at: layout.shared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: VMOmarchySharedFolderStore.defaultFolder(forBundle: bundle, homeDirectory: home),
            withIntermediateDirectories: true
        )

        let settings = VMOmarchySharedFolderStore.load(layout: layout, homeDirectory: home)

        XCTAssertEqual(settings.folders.map(\.path), [layout.shared.standardizedFileURL])
    }

    func testSettingsSurviveAWorkspaceRecoveryBecauseTheyLiveOutsideIt() {
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: root.appending(path: "M.riftvm"))
        XCTAssertFalse(layout.sharedFolderSettings.path.hasPrefix(layout.workspace.path))
        XCTAssertFalse(layout.transfer.path.hasPrefix(layout.workspace.path))
    }

    func testAnOlderAgentGetsTheFirstWritableFolderAtTheRoot() throws {
        let first = try folder("riftvm-shared")
        let second = try folder("code")
        let settings = VMOmarchySharedFolderSettings(folders: [
            VMOmarchySharedFolder(path: first),
            VMOmarchySharedFolder(path: second),
        ])

        let plan = VMOmarchySharePlan(settings: settings, transfer: root.appending(path: "Transfer"))

        XCTAssertFalse(plan.isMultiple)
        XCTAssertEqual(plan.entries.map(\.name), [""])
        XCTAssertEqual(plan.clipboardStaging, first)
        XCTAssertEqual(plan.clipboardRelativePrefix, "")
        XCTAssertEqual(plan.guestPath(for: settings.folders[0]), "/mnt/riftvm-shared")
        XCTAssertNil(plan.guestPath(for: settings.folders[1]))
        XCTAssertTrue(plan.makeShare(transfer: root) is VZSingleDirectoryShare)
    }

    func testAnOlderAgentWithoutAWritableFolderStillHasAClipboardRoot() throws {
        let transfer = root.appending(path: "Transfer")
        let settings = VMOmarchySharedFolderSettings(folders: [
            VMOmarchySharedFolder(path: try folder("docs"), readOnly: true),
        ])

        let plan = VMOmarchySharePlan(settings: settings, transfer: transfer)

        XCTAssertTrue(plan.entries.isEmpty)
        XCTAssertEqual(plan.clipboardStaging, transfer)
        XCTAssertEqual(plan.clipboardRelativePrefix, "")
    }

    func testMultipleFoldersAppearAsSubdirectoriesBesideTheStagingFolder() throws {
        let transfer = root.appending(path: "Transfer")
        let settings = VMOmarchySharedFolderSettings(
            folders: [
                VMOmarchySharedFolder(path: try folder("riftvm-shared")),
                VMOmarchySharedFolder(path: try folder("a/code")),
                VMOmarchySharedFolder(path: try folder("b/code"), readOnly: true),
                VMOmarchySharedFolder(path: try folder(".riftvm")),
                VMOmarchySharedFolder(path: root.appending(path: "missing")),
            ],
            guestSupportsMultipleFolders: true
        )

        let plan = VMOmarchySharePlan(settings: settings, transfer: transfer)

        XCTAssertTrue(plan.isMultiple)
        XCTAssertEqual(plan.entries.map(\.name), ["riftvm-shared", "code", "code-2", "riftvm"])
        XCTAssertEqual(plan.clipboardStaging, transfer)
        XCTAssertEqual(plan.clipboardRelativePrefix, ".riftvm/")
        XCTAssertEqual(plan.guestPath(for: settings.folders[1]), "/mnt/riftvm-shared/code")
        XCTAssertNil(plan.guestPath(for: settings.folders[4]))
        let share = try XCTUnwrap(plan.makeShare(transfer: transfer) as? VZMultipleDirectoryShare)
        XCTAssertEqual(Set(share.directories.keys), [".riftvm", "riftvm-shared", "code", "code-2", "riftvm"])
        XCTAssertEqual(share.directories["code-2"]?.isReadOnly, true)
        XCTAssertEqual(share.directories[".riftvm"]?.url, transfer)
    }

    func testRemovingEveryFolderKeepsTheClipboardStagingFolder() {
        let transfer = root.appending(path: "Transfer")
        let plan = VMOmarchySharePlan(
            settings: VMOmarchySharedFolderSettings(folders: [], guestSupportsMultipleFolders: true),
            transfer: transfer
        )

        let share = plan.makeShare(transfer: transfer) as? VZMultipleDirectoryShare
        XCTAssertEqual(share.map { Array($0.directories.keys) }, [".riftvm"])
        XCTAssertEqual(plan.clipboardRelativePrefix, ".riftvm/")
    }

    func testPrimaryFolderSkipsReadOnlyFolders() throws {
        let settings = VMOmarchySharedFolderSettings(folders: [
            VMOmarchySharedFolder(path: try folder("docs"), readOnly: true),
            VMOmarchySharedFolder(path: try folder("work")),
        ])
        XCTAssertEqual(settings.primaryFolder?.path.lastPathComponent, "work")
    }

    func testImporterCopiesIntoTheChosenFolder() throws {
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: try folder("M.riftvm"))
        let destination = try folder("work")
        let source = root.appending(path: "a.txt")
        try Data("a".utf8).write(to: source)

        let imported = try VMOmarchySharedFolderImporter(layout: layout, destination: destination).importFiles([source])

        XCTAssertEqual(imported.map { $0.destinationURL.deletingLastPathComponent().lastPathComponent }, ["work"])
        XCTAssertEqual(try Data(contentsOf: destination.appending(path: "a.txt")), Data("a".utf8))
    }

    private func folder(_ relativePath: String) throws -> URL {
        let url = root.appending(path: relativePath, directoryHint: .isDirectory).standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
