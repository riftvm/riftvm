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

    func testLoadWritesAndKeepsTheDefaultFolder() throws {
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let layout = VMOmarchyWorkspaceLayout(
            applicationSupportRoot: home.appending(path: ".riftvm/Omarchy.riftvm", directoryHint: .isDirectory)
        )

        let settings = VMOmarchySharedFolderStore.load(layout: layout, homeDirectory: home)

        XCTAssertEqual(settings.folders.map(\.path), [
            VMOmarchySharedFolderStore.defaultFolder(forBundle: layout.applicationSupportRoot, homeDirectory: home),
        ])
        XCTAssertEqual(VMOmarchySharedFolderStore.load(layout: layout, homeDirectory: home), settings)
    }

    func testSettingsSurviveAWorkspaceRecoveryBecauseTheyLiveOutsideIt() {
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: root.appending(path: "M.riftvm"))
        XCTAssertFalse(layout.sharedFolderSettings.path.hasPrefix(layout.workspace.path))
        XCTAssertFalse(layout.transfer.path.hasPrefix(layout.workspace.path))
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
            ]
        )

        let plan = VMOmarchySharePlan(settings: settings, transfer: transfer)

        XCTAssertEqual(plan.entries.map(\.name), ["riftvm-shared", "code", "code-2", "riftvm"])
        XCTAssertEqual(plan.clipboardStaging, transfer)
        XCTAssertEqual(VMOmarchySharePlan.clipboardRelativePrefix, ".riftvm/")
        XCTAssertEqual(plan.guestPath(for: settings.folders[1]), "/mnt/riftvm-shared/code")
        XCTAssertNil(plan.guestPath(for: settings.folders[4]))
        let share = try XCTUnwrap(plan.makeShare(transfer: transfer) as? VZMultipleDirectoryShare)
        XCTAssertEqual(Set(share.directories.keys), [".riftvm", "riftvm-shared", "code", "code-2", "riftvm"])
        XCTAssertEqual(share.directories["code-2"]?.isReadOnly, true)
        XCTAssertEqual(share.directories[".riftvm"]?.url, transfer)
    }

    func testEveryFolderRemovedKeepsOnlyTheClipboardStagingFolder() {
        let transfer = root.appending(path: "Transfer")
        let plan = VMOmarchySharePlan(
            settings: VMOmarchySharedFolderSettings(folders: []),
            transfer: transfer
        )

        let share = plan.makeShare(transfer: transfer) as? VZMultipleDirectoryShare
        XCTAssertEqual(share.map { Array($0.directories.keys) }, [".riftvm"])
        XCTAssertEqual(VMOmarchySharePlan.clipboardRelativePrefix, ".riftvm/")
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
