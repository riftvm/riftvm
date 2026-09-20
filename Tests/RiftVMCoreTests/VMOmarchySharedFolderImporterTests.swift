import XCTest
@testable import RiftVMCore

final class VMOmarchySharedFolderImporterTests: XCTestCase {
    func testImportPublishesBytesAndKeepsExistingFile() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: root.appending(path: "support"))
        let shared = layout.applicationSupportRoot.appending(path: "riftvm-shared", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let source = root.appending(path: "notes.txt")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: shared.appending(path: "notes.txt"))

        let imported = try VMOmarchySharedFolderImporter(layout: layout, destination: shared).importFiles([source])

        XCTAssertEqual(imported.map(\.destinationURL.lastPathComponent), ["notes copy 2.txt"])
        XCTAssertEqual(try Data(contentsOf: shared.appending(path: "notes.txt")), Data("old".utf8))
        XCTAssertEqual(try Data(contentsOf: imported[0].destinationURL), Data("new".utf8))
    }

    func testImportRejectsSymbolicLinkSource() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: root.appending(path: "support"))
        let shared = layout.applicationSupportRoot.appending(path: "riftvm-shared", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let real = root.appending(path: "real.txt")
        let link = root.appending(path: "link.txt")
        try Data("private".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertThrowsError(try VMOmarchySharedFolderImporter(layout: layout, destination: shared).importFiles([link])) { error in
            XCTAssertEqual(error as? VMOmarchySharedFolderImportError, .unsupportedSource("link.txt"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: shared.path), [])
    }

    func testImportRejectsUnsafeSharedFolder() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: root.appending(path: "support"))
        let outside = root.appending(path: "outside")
        try FileManager.default.createDirectory(at: layout.applicationSupportRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let shared = layout.applicationSupportRoot.appending(path: "riftvm-shared", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: shared, withDestinationURL: outside)
        let source = root.appending(path: "notes.txt")
        try Data("new".utf8).write(to: source)

        XCTAssertThrowsError(try VMOmarchySharedFolderImporter(layout: layout, destination: shared).importFiles([source])) { error in
            XCTAssertEqual(error as? VMOmarchySharedFolderImportError, .sharedFolderUnavailable)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }
}
