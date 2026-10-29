import XCTest
@testable import RiftVMCore

final class VMOmarchyPreparationFailureReportTests: XCTestCase {
    private let manifestURL = VMOmarchyProfile.production.factoryImage.manifestURL

    func testIssueURLPrefillsExistingBugReportFieldsAndPreservesSpecialCharacters() throws {
        let error = "下载失败: HTTP 403 & file=a+b#part?name=\"image\"\nTry again."
        let report = VMOmarchyPreparationFailureReport(
            error: error, environment: "RiftVM 0.6.2 (52) on macOS 27.0.1",
            logs: ["10:10:00  Downloading", "10:10:01  \(error)"], manifestURL: manifestURL
        )

        let url = report.issueURL
        let fields = try queryFields(url)
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(url.path, "/riftvm/riftvm/issues/new")
        XCTAssertEqual(fields["template"], "bug_report.yml")
        XCTAssertEqual(fields["title"], "[Bug]: Omarchy preparation failed")
        XCTAssertTrue(try XCTUnwrap(fields["problem"]).contains("HTTP 403 & file=a+b#part?name=\"image\""))
        XCTAssertEqual(fields["versions"], "RiftVM 0.6.2 (52) on macOS 27.0.1 / Omarchy")
        XCTAssertTrue(try XCTUnwrap(fields["context"]).contains(manifestURL.absoluteString))
        XCTAssertTrue(try XCTUnwrap(fields["context"]).contains("10:10:00  Downloading"))
        XCTAssertTrue(url.absoluteString.contains("a%2Bb"), "A literal plus must not become a space in GitHub's form")
    }

    func testCopiedReportIncludesFullErrorEnvironmentAndLogsWithoutPersonalHomePath() {
        let report = VMOmarchyPreparationFailureReport(
            error: "Cannot save /Users/example/Library/Application Support/RiftVM/image",
            environment: "RiftVM 0.6.2 (52) on macOS 27.0.1",
            logs: ["Downloading", "Failed at /Users/example/.riftvm/Omarchy.riftvm"],
            manifestURL: manifestURL, homeDirectory: "/Users/example"
        )

        XCTAssertTrue(report.text.contains("Cannot save ~/Library/Application Support/RiftVM/image"))
        XCTAssertTrue(report.text.contains("RiftVM 0.6.2 (52) on macOS 27.0.1"))
        XCTAssertTrue(report.text.contains("Guest: Omarchy"))
        XCTAssertTrue(report.text.contains("Failed at ~/.riftvm/Omarchy.riftvm"))
        XCTAssertFalse(report.text.contains("/Users/example"))
        XCTAssertFalse(report.issueURL.absoluteString.contains("/Users/example"))
    }

    func testLongUnicodeErrorAndLogsFitInURLWhileCopyKeepsFullReport() throws {
        let error = String(repeating: "无法保存镜像 + & #\n", count: 2_000)
        let finalLog = "Final detail: \(UUID().uuidString)"
        let report = VMOmarchyPreparationFailureReport(
            error: error, environment: "RiftVM 0.6.2 (52) on macOS 27.0.1",
            logs: [String(repeating: "Downloading image…\n", count: 2_000), finalLog],
            manifestURL: manifestURL
        )

        XCTAssertLessThanOrEqual(report.issueURL.absoluteString.utf8.count, 7_500)
        let fields = try queryFields(report.issueURL)
        XCTAssertTrue(try XCTUnwrap(fields["problem"]).contains("无法保存镜像"))
        XCTAssertTrue(try XCTUnwrap(fields["context"]).contains("Use Copy Error"))
        XCTAssertTrue(report.text.contains(finalLog))
        XCTAssertEqual(report.error, error)
    }

    private func queryFields(_ url: URL) throws -> [String: String] {
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
}
