import Foundation
import XCTest
@testable import RiftVMCore

final class VMOmarchyReleaseTransportTests: XCTestCase {
    private let releaseURL = URL(string: "https://github.com/riftvm/image/releases/download/v1/factory.json?download=1")!

    override func tearDown() {
        ReleaseProtocol.reset([])
        super.tearDown()
    }

    func testOriginalReleaseRequestsGetFreshCacheKeysButSignedURLsStayUnchanged() throws {
        let first = VMOmarchyURLSessionTransport.uncachedRequest(for: releaseURL)
        let second = VMOmarchyURLSessionTransport.uncachedRequest(for: releaseURL)
        XCTAssertNotEqual(first.url, second.url)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(first.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "github.com")
        XCTAssertEqual(components.path, releaseURL.path)
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "download" })?.value, "1")
        XCTAssertEqual(components.queryItems?.filter { $0.name == "riftvm_download" }.count, 1)
        let signed = URL(string: "https://release-assets.githubusercontent.com/file?jwt=signature%2Btoken&se=expired")!
        XCTAssertEqual(VMOmarchyURLSessionTransport.uncachedRequest(for: signed).url, signed)
    }

    func testExpiredManifestRedirectIsResolvedAgainFromOriginalURL() async throws {
        ReleaseProtocol.reset([.init(618, "jwt:expired"), .init(200, "signed manifest")])
        let transport = makeTransport()
        defer { transport.cancel() }
        let result = try await transport.fetchData(from: releaseURL)
        XCTAssertEqual(result, Data("signed manifest".utf8))
        let requests = ReleaseProtocol.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(Set(requests.compactMap(\.url)).count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "github.com" && $0.url?.path == releaseURL.path })
    }

    func testRepeatedExpiredTokensStopAfterThreeAttempts() async throws {
        ReleaseProtocol.reset(Array(repeating: .init(618, "jwt:expired"), count: 4))
        let transport = makeTransport()
        defer { transport.cancel() }
        do {
            _ = try await transport.fetchData(from: releaseURL)
            XCTFail("Expected bounded failure")
        } catch {
            XCTAssertEqual(error as? VMOmarchyFactoryInstallError, .invalidHTTPResponse(statusCode: 618))
        }
        XCTAssertEqual(ReleaseProtocol.requests.count, 3)
    }

    func testUnrelatedHostOrHTTPFailureDoesNotTriggerReleaseRecovery() async throws {
        for (url, status) in [(releaseURL, 404), (URL(string: "https://example.test/factory")!, 618)] {
            ReleaseProtocol.reset([.init(status, "failure")])
            let transport = makeTransport()
            do {
                _ = try await transport.fetchData(from: url)
                XCTFail("Expected HTTP failure")
            } catch {
                XCTAssertEqual(error as? VMOmarchyFactoryInstallError, .invalidHTTPResponse(statusCode: status))
            }
            transport.cancel()
            XCTAssertEqual(ReleaseProtocol.requests.count, 1)
        }
    }

    func testExpiredDownloadIsRetriedWithoutPublishingTheErrorBody() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("image")
        let resume = folder.appendingPathComponent("resume")
        ReleaseProtocol.reset([.init(618, "jwt:expired"), .init(200, "verified image bytes")])
        let transport = makeTransport()
        defer { transport.cancel() }
        try await transport.downloadFile(from: releaseURL, to: destination, resumeDataURL: resume, progress: { _, _ in })
        XCTAssertEqual(try Data(contentsOf: destination), Data("verified image bytes".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: resume.path))
        XCTAssertEqual(ReleaseProtocol.requests.count, 2)
        XCTAssertEqual(Set(ReleaseProtocol.requests.compactMap(\.url)).count, 2)
    }

    private func makeTransport() -> VMOmarchyURLSessionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReleaseProtocol.self]
        return VMOmarchyURLSessionTransport(configuration: configuration)
    }
}

private final class ReleaseProtocol: URLProtocol {
    struct Reply {
        let status: Int
        let body: Data
        init(_ status: Int, _ body: String) { self.status = status; self.body = Data(body.utf8) }
    }
    private static let lock = NSLock()
    private static var replies: [Reply] = []
    private static var recorded: [URLRequest] = []
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    static func reset(_ values: [Reply]) {
        lock.lock(); defer { lock.unlock() }
        replies = values; recorded = []
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        let reply = Self.replies.isEmpty ? Reply(500, "unexpected request") : Self.replies.removeFirst()
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(reply.body.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
