import CryptoKit
import Darwin
import XCTest
@testable import RiftVMCore

final class VMOmarchyFactoryImageVerificationTests: XCTestCase {
    private var root: URL!
    private var cache: URL!
    private let key = Curve25519.Signing.PrivateKey()
    private let image = Data("factory-image-for-verification-record".utf8)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "OmarchyVerificationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        cache = root.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testDownloadedImageIsHashedOnceAndReusedWithoutHashing() async throws {
        let counter = HashCounter()
        let transport = Transport(manifestData: try manifestData(for: image), image: image)
        let installer = makeInstaller(transport: transport, counter: counter)

        let installed = try await installer.install()
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(installed.diskURL, publishedURL)
        XCTAssertNotNil(VMOmarchyFactoryImageVerificationRecord.read(forImageAt: publishedURL))

        var stages: [String] = []
        let reused = try await installer.install(stage: { stages.append($0) })

        XCTAssertEqual(counter.count, 1, "An untouched cached image must not be hashed again")
        XCTAssertEqual(stages, ["Checking the image manifest", "Verifying the cached image"])
        XCTAssertEqual(reused, installed)
        XCTAssertEqual(transport.downloadCount, 1)
        XCTAssertEqual(try Data(contentsOf: publishedURL), image)
    }

    func testCachedImageWithoutRecordIsHashedThenRemembered() async throws {
        try image.write(to: publishedURL)
        let counter = HashCounter()
        let installer = makeInstaller(
            transport: Transport(manifestData: try manifestData(for: image), image: image),
            counter: counter
        )

        _ = try await installer.install()
        XCTAssertEqual(counter.count, 1)
        let record = try XCTUnwrap(VMOmarchyFactoryImageVerificationRecord.read(forImageAt: publishedURL))
        XCTAssertEqual(record.sha256, Self.digest(image))
        XCTAssertEqual(record.fingerprint.fileSize, UInt64(image.count))
        XCTAssertEqual(
            record.fingerprint,
            VMOmarchyFactoryImageVerificationRecord.Fingerprint.current(of: publishedURL)
        )

        _ = try await installer.install()
        XCTAssertEqual(counter.count, 1)
    }

    func testChangedSizeForcesHashAndRejectsImage() async throws {
        let counter = HashCounter()
        let installer = makeInstaller(
            transport: Transport(manifestData: try manifestData(for: image), image: image),
            counter: counter
        )
        _ = try await installer.install()

        try (image + Data("x".utf8)).write(to: publishedURL)

        await assertInstallFails(installer, with: .imageSizeMismatch)
        XCTAssertEqual(counter.count, 2)
        XCTAssertNil(VMOmarchyFactoryImageVerificationRecord.read(forImageAt: publishedURL))
    }

    func testSameSizeContentChangeForcesHashAndRejectsImage() async throws {
        let counter = HashCounter()
        let installer = makeInstaller(
            transport: Transport(manifestData: try manifestData(for: image), image: image),
            counter: counter
        )
        _ = try await installer.install()

        try overwriteInPlace(publishedURL, with: Data(repeating: 0x21, count: image.count))

        await assertInstallFails(installer, with: .imageDigestMismatch)
        XCTAssertEqual(counter.count, 2)
        XCTAssertNil(VMOmarchyFactoryImageVerificationRecord.read(forImageAt: publishedURL))
    }

    func testContentChangeWithRestoredModificationDateStillForcesHash() async throws {
        let counter = HashCounter()
        let installer = makeInstaller(
            transport: Transport(manifestData: try manifestData(for: image), image: image),
            counter: counter
        )
        _ = try await installer.install()
        let recorded = try XCTUnwrap(VMOmarchyFactoryImageVerificationRecord.read(forImageAt: publishedURL))

        // Same inode, same size, modification time put back to the nanosecond.
        try overwriteInPlace(publishedURL, with: Data(repeating: 0x21, count: image.count))
        var times = [
            timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
            timespec(
                tv_sec: Int(recorded.fingerprint.modificationSeconds),
                tv_nsec: Int(recorded.fingerprint.modificationNanoseconds)
            ),
        ]
        XCTAssertEqual(utimensat(AT_FDCWD, publishedURL.path, &times, 0), 0)
        let tampered = try XCTUnwrap(VMOmarchyFactoryImageVerificationRecord.Fingerprint.current(of: publishedURL))
        XCTAssertTrue(tampered.matchesIgnoringStatusChange(recorded.fingerprint))

        await assertInstallFails(installer, with: .imageDigestMismatch)
        XCTAssertEqual(counter.count, 2)
    }

    func testChangedModificationDateAloneForcesHashAndRefreshesRecord() async throws {
        let counter = HashCounter()
        let installer = makeInstaller(
            transport: Transport(manifestData: try manifestData(for: image), image: image),
            counter: counter
        )
        _ = try await installer.install()

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
            ofItemAtPath: publishedURL.path
        )

        _ = try await installer.install()
        XCTAssertEqual(counter.count, 2)
        _ = try await installer.install()
        XCTAssertEqual(counter.count, 2, "The refreshed record must be honoured")
    }

    func testReplacedFileWithSameContentForcesHash() async throws {
        let counter = HashCounter()
        let installer = makeInstaller(
            transport: Transport(manifestData: try manifestData(for: image), image: image),
            counter: counter
        )
        _ = try await installer.install()

        // Keep the old file alive so the replacement cannot reuse its inode.
        let aside = cache.appending(path: "aside")
        try FileManager.default.moveItem(at: publishedURL, to: aside)
        try image.write(to: publishedURL)

        _ = try await installer.install()
        XCTAssertEqual(counter.count, 2)
    }

    func testManifestExpectingAnotherDigestForcesHashAndRejectsImage() async throws {
        let counter = HashCounter()
        let installer = makeInstaller(
            transport: Transport(manifestData: try manifestData(for: image), image: image),
            counter: counter
        )
        _ = try await installer.install()
        XCTAssertEqual(counter.count, 1)

        // Same version and size, different signed digest.
        let other = Data(repeating: 0x42, count: image.count)
        let strict = makeInstaller(
            transport: Transport(manifestData: try manifestData(for: other), image: other),
            counter: counter
        )

        await assertInstallFails(strict, with: .imageDigestMismatch)
        XCTAssertEqual(counter.count, 2)
        XCTAssertEqual(try Data(contentsOf: publishedURL), image)
    }

    func testRecordClaimingTheExpectedDigestForADifferentFileIsIgnored() async throws {
        // A forged or stale record: right digest, wrong file identity.
        let tampered = Data(repeating: 0x21, count: image.count)
        try tampered.write(to: publishedURL)
        let actual = try XCTUnwrap(VMOmarchyFactoryImageVerificationRecord.Fingerprint.current(of: publishedURL))
        let forged = VMOmarchyFactoryImageVerificationRecord(
            schemaVersion: VMOmarchyFactoryImageVerificationRecord.currentSchemaVersion,
            fingerprint: .init(
                fileSize: actual.fileSize,
                modificationSeconds: actual.modificationSeconds,
                modificationNanoseconds: actual.modificationNanoseconds,
                statusChangeSeconds: actual.statusChangeSeconds,
                statusChangeNanoseconds: actual.statusChangeNanoseconds,
                inode: actual.inode &+ 1
            ),
            sha256: Self.digest(image)
        )
        try forged.write(forImageAt: publishedURL)
        let counter = HashCounter()
        let installer = makeInstaller(
            transport: Transport(manifestData: try manifestData(for: image), image: image),
            counter: counter
        )

        await assertInstallFails(installer, with: .imageDigestMismatch)
        XCTAssertEqual(counter.count, 1)
    }

    func testRecordWithAnotherDigestForcesHash() async throws {
        let counter = HashCounter()
        let installer = makeInstaller(
            transport: Transport(manifestData: try manifestData(for: image), image: image),
            counter: counter
        )
        _ = try await installer.install()
        let recorded = try XCTUnwrap(VMOmarchyFactoryImageVerificationRecord.read(forImageAt: publishedURL))
        try VMOmarchyFactoryImageVerificationRecord(
            schemaVersion: recorded.schemaVersion,
            fingerprint: recorded.fingerprint,
            sha256: String(repeating: "0", count: 64)
        ).write(forImageAt: publishedURL)

        _ = try await installer.install()

        XCTAssertEqual(counter.count, 2)
        XCTAssertEqual(
            VMOmarchyFactoryImageVerificationRecord.read(forImageAt: publishedURL)?.sha256,
            Self.digest(image)
        )
    }

    func testUnreadableUnknownOrOversizedRecordForcesHash() async throws {
        let counter = HashCounter()
        let installer = makeInstaller(
            transport: Transport(manifestData: try manifestData(for: image), image: image),
            counter: counter
        )
        _ = try await installer.install()
        let recordURL = VMOmarchyFactoryImageVerificationRecord.url(forImageAt: publishedURL)
        let valid = try Data(contentsOf: recordURL)
        let futureSchema = try XCTUnwrap(String(data: valid, encoding: .utf8))
            .replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 2")
        XCTAssertNotEqual(Data(futureSchema.utf8), valid)

        let invalidRecords = [
            Data("not json".utf8),
            Data(),
            Data(futureSchema.utf8),
            valid + Data(repeating: 0x20, count: VMOmarchyFactoryImageVerificationRecord.maximumEncodedBytes),
        ]
        for (index, invalid) in invalidRecords.enumerated() {
            try invalid.write(to: recordURL)
            _ = try await installer.install()
            XCTAssertEqual(counter.count, 2 + index, "record \(index)")
            // Every full verification leaves a usable record behind.
            XCTAssertNotNil(VMOmarchyFactoryImageVerificationRecord.read(forImageAt: publishedURL))
        }
    }

    func testRecordReachedThroughSymbolicLinkIsIgnored() async throws {
        let counter = HashCounter()
        let installer = makeInstaller(
            transport: Transport(manifestData: try manifestData(for: image), image: image),
            counter: counter
        )
        _ = try await installer.install()
        let recordURL = VMOmarchyFactoryImageVerificationRecord.url(forImageAt: publishedURL)
        let elsewhere = root.appending(path: "record.json")
        try FileManager.default.moveItem(at: recordURL, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: recordURL, withDestinationURL: elsewhere)

        _ = try await installer.install()

        XCTAssertEqual(counter.count, 2)
    }

    func testStaleRecordIsNotAppliedToNewlyDownloadedImage() async throws {
        let counter = HashCounter()
        let transport = Transport(manifestData: try manifestData(for: image), image: image)
        let installer = makeInstaller(transport: transport, counter: counter)
        _ = try await installer.install()
        try FileManager.default.removeItem(at: publishedURL)

        _ = try await installer.install()

        XCTAssertEqual(transport.downloadCount, 2)
        XCTAssertEqual(counter.count, 2, "A downloaded image is always hashed")
        XCTAssertEqual(
            VMOmarchyFactoryImageVerificationRecord.read(forImageAt: publishedURL)?.fingerprint,
            VMOmarchyFactoryImageVerificationRecord.Fingerprint.current(of: publishedURL)
        )
    }

    func testRejectedDownloadLeavesNoImageAndNoRecord() async throws {
        let counter = HashCounter()
        let installer = makeInstaller(
            transport: Transport(
                manifestData: try manifestData(for: image),
                image: Data(repeating: 0x21, count: image.count)
            ),
            counter: counter
        )

        await assertInstallFails(installer, with: .imageDigestMismatch)

        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), [])
    }

    func testSymbolicLinkImageIsNeverFingerprinted() throws {
        let target = root.appending(path: "target.asif")
        try image.write(to: target)
        try FileManager.default.createSymbolicLink(at: publishedURL, withDestinationURL: target)

        XCTAssertNil(VMOmarchyFactoryImageVerificationRecord.Fingerprint.current(of: publishedURL))
        XCTAssertNil(VMOmarchyFactoryImageVerificationRecord.Fingerprint.current(of: cache))
        XCTAssertNil(VMOmarchyFactoryImageVerificationRecord.Fingerprint.current(
            of: cache.appending(path: "missing")
        ))
    }

    func testHashingReadsInFourMebibyteChunksAndMatchesCryptoKit() throws {
        XCTAssertEqual(VMOmarchyFactoryValidator.hashReadChunkBytes, 4 * 1_024 * 1_024)
        // Spans several chunks and ends inside one.
        var large = Data(count: 9 * 1_024 * 1_024 + 123)
        large.withUnsafeMutableBytes { buffer in
            for index in stride(from: 0, to: buffer.count, by: 4_096) {
                buffer[index] = UInt8(truncatingIfNeeded: index / 4_096)
            }
        }
        let url = root.appending(path: "large.asif")
        try large.write(to: url)
        let manifest = try JSONDecoder().decode(
            VMOmarchyFactoryManifest.self,
            from: manifestData(for: large)
        )

        XCTAssertNoThrow(try VMOmarchyFactoryValidator.validateImage(at: url, manifest: manifest))

        try overwriteInPlace(url, with: Data([0xff]), atOffset: UInt64(large.count - 1))
        XCTAssertThrowsError(try VMOmarchyFactoryValidator.validateImage(at: url, manifest: manifest)) { error in
            XCTAssertEqual(error as? VMOmarchyFactoryValidationError, .imageDigestMismatch)
        }
    }

    // MARK: - Helpers

    private var publishedURL: URL { cache.appending(path: "Factory-test.asif") }

    private var profile: VMOmarchyProfile {
        VMOmarchyProfile(
            schemaVersion: 1,
            productID: "com.riftvm.app.omarchy",
            minimumHostMajorVersion: 27,
            diskCapacityBytes: 64 * 1_024 * 1_024 * 1_024,
            resourceTiers: VMOmarchyProfile.production.resourceTiers,
            requiredGuestCapabilities: ["desktop-input-v1"],
            factoryImage: .init(
                manifestURL: URL(string: "https://example.test/manifest.json")!,
                signingKeyID: "test-key",
                architecture: "arm64",
                maximumDownloadBytes: 64 * 1_024 * 1_024
            )
        )
    }

    private func makeInstaller(transport: Transport, counter: HashCounter) -> VMOmarchyFactoryInstaller {
        var installer = VMOmarchyFactoryInstaller(
            profile: profile,
            cacheDirectory: cache,
            publicKeys: [key.publicKey.rawRepresentation],
            transport: transport
        )
        installer.validateImage = { imageURL, manifest in
            counter.increment()
            try VMOmarchyFactoryValidator.validateImage(at: imageURL, manifest: manifest)
        }
        return installer
    }

    private func manifestData(for image: Data) throws -> Data {
        let payload = VMOmarchyFactoryManifest.Payload(
            schemaVersion: 1,
            imageVersion: "test",
            imageURL: URL(string: "https://example.test/factory.asif")!,
            imageByteCount: UInt64(image.count),
            imageSHA256: Self.digest(image),
            architecture: "arm64",
            omarchyRevision: "revision",
            guestAgentVersion: "1",
            guestCapabilities: VMOmarchyProfile.production.factoryGuestCapabilities
        )
        let signature = try key.signature(for: VMOmarchyFactoryValidator.canonicalPayload(payload))
        return try JSONEncoder().encode(VMOmarchyFactoryManifest(
            payload: payload,
            keyID: "test-key",
            signature: signature.base64EncodedString()
        ))
    }

    private func assertInstallFails(
        _ installer: VMOmarchyFactoryInstaller,
        with expected: VMOmarchyFactoryValidationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await installer.install()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? VMOmarchyFactoryValidationError, expected, file: file, line: line)
        }
    }

    /// Rewrites bytes without replacing the file, so the inode is kept.
    private func overwriteInPlace(_ url: URL, with data: Data, atOffset offset: UInt64 = 0) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private final class HashCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class Transport: VMOmarchyFactoryTransport {
        let manifestData: Data
        let image: Data
        var downloadCount = 0

        init(manifestData: Data, image: Data) {
            self.manifestData = manifestData
            self.image = image
        }

        func fetchData(from url: URL) async throws -> Data { manifestData }

        func downloadFile(
            from url: URL,
            to destination: URL,
            resumeDataURL: URL,
            progress: @escaping (Int64, Int64) -> Void
        ) async throws {
            downloadCount += 1
            try image.write(to: destination)
            progress(Int64(image.count), Int64(image.count))
        }
    }
}
