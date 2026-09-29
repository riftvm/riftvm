import Darwin
import Foundation

public protocol VMOmarchyFactoryTransport {
    func fetchData(from url: URL) async throws -> Data
    func downloadFile(
        from url: URL,
        to destination: URL,
        resumeDataURL: URL,
        progress: @escaping (Int64, Int64) -> Void
    ) async throws
}

public final class VMOmarchyURLSessionTransport: NSObject, VMOmarchyFactoryTransport, URLSessionDownloadDelegate {
    private struct ActiveDownload {
        let destination: URL
        let resumeDataURL: URL
        let progress: (Int64, Int64) -> Void
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var activeDownloads: [Int: ActiveDownload] = [:]
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    public override init() {}

    public func cancel() {
        session.invalidateAndCancel()
    }

    public func fetchData(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(for: Self.uncachedRequest(for: url))
        try Self.validateHTTPResponse(response)
        return data
    }

    public func downloadFile(
        from url: URL,
        to destination: URL,
        resumeDataURL: URL,
        progress: @escaping (Int64, Int64) -> Void
    ) async throws {
        try? FileManager.default.removeItem(at: destination)
        let resumeData = try? Data(contentsOf: resumeDataURL)
        try await withCheckedThrowingContinuation { continuation in
            let task = resumeData.map(session.downloadTask(withResumeData:))
                ?? session.downloadTask(with: Self.uncachedRequest(for: url))
            lock.withLock {
                activeDownloads[task.taskIdentifier] = ActiveDownload(
                    destination: destination,
                    resumeDataURL: resumeDataURL,
                    progress: progress,
                    continuation: continuation
                )
            }
            task.resume()
        }
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // The closure belongs to the caller and may block or re-enter this
        // transport, so it must never run while the lock is held.
        let progress = lock.withLock { activeDownloads[downloadTask.taskIdentifier]?.progress }
        progress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let active = lock.withLock({ activeDownloads[downloadTask.taskIdentifier] }) else { return }
        do {
            try Self.validateHTTPResponse(downloadTask.response)
            try FileManager.default.createDirectory(
                at: active.destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: location, to: active.destination)
        } catch {
            downloadTask.cancel()
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let active = lock.withLock({ activeDownloads.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let error {
            let cocoa = error as NSError
            if let resumeData = cocoa.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                try? resumeData.write(to: active.resumeDataURL, options: .atomic)
            }
            active.continuation.resume(throwing: error)
        } else if FileManager.default.fileExists(atPath: active.destination.path) {
            try? FileManager.default.removeItem(at: active.resumeDataURL)
            active.continuation.resume()
        } else {
            active.continuation.resume(throwing: VMOmarchyFactoryInstallError.downloadDidNotPublish)
        }
    }

    static func uncachedRequest(for url: URL) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData
        )
        // GitHub release URLs redirect to time-limited asset URLs. A 404 from
        // before a draft is published must not survive in URLCache and make the
        // in-app Try Again action repeat the stale response.
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        return request
    }

    private static func validateHTTPResponse(_ response: URLResponse?) throws {
        guard let response = response as? HTTPURLResponse,
              (200 ... 299).contains(response.statusCode) else {
            throw VMOmarchyFactoryInstallError.invalidHTTPResponse(
                statusCode: (response as? HTTPURLResponse)?.statusCode
            )
        }
    }
}

public enum VMOmarchyFactoryInstallError: Error, Equatable, LocalizedError {
    case invalidHTTPResponse(statusCode: Int?)
    case downloadDidNotPublish
    case manifestTooLarge
    case invalidManifestEncoding

    public var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse(let statusCode):
            if let statusCode {
                "The Omarchy release server returned HTTP \(statusCode)."
            } else {
                "The Omarchy release server returned an invalid response."
            }
        case .downloadDidNotPublish:
            "The Omarchy factory download completed without a usable file."
        case .manifestTooLarge:
            "The Omarchy factory manifest exceeds the allowed size."
        case .invalidManifestEncoding:
            "The Omarchy factory manifest is not valid signed-channel metadata."
        }
    }
}

public struct VMOmarchyFactoryInstallResult: Equatable {
    public let diskURL: URL
    public let manifest: VMOmarchyFactoryManifest

    public init(diskURL: URL, manifest: VMOmarchyFactoryManifest) {
        self.diskURL = diskURL
        self.manifest = manifest
    }
}

public enum VMOmarchyFactoryChannelState: Equatable, Sendable {
    case untracked(availableVersion: String)
    case current(version: String)
    case different(installedVersion: String, availableVersion: String)

    public static func assess(
        installedVersion: String?,
        manifest: VMOmarchyFactoryManifest
    ) -> Self {
        let available = manifest.payload.imageVersion
        guard let installedVersion, !installedVersion.isEmpty else {
            return .untracked(availableVersion: available)
        }
        if installedVersion == available {
            return .current(version: installedVersion)
        }
        return .different(installedVersion: installedVersion, availableVersion: available)
    }
}

/// What RiftVM knew about a cached factory image the last time it hashed the
/// whole file. It lets a later install skip re-reading a multi-gigabyte image
/// that has not been touched since.
///
/// This is an optimisation against redundant reads, not a trust anchor: the
/// record is only honoured when every field still matches the file on disk and
/// the recorded digest is the one the signed manifest demands. Anything else
/// falls back to hashing the image again.
struct VMOmarchyFactoryImageVerificationRecord: Codable, Equatable {
    static let currentSchemaVersion = 1
    static let maximumEncodedBytes = 4 * 1_024

    struct Fingerprint: Codable, Equatable {
        let fileSize: UInt64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        /// Changes whenever content or metadata changes and, unlike the
        /// modification date, cannot be set back by the file's owner.
        let statusChangeSeconds: Int64
        let statusChangeNanoseconds: Int64
        let inode: UInt64

        /// Returns nil unless `url` is a regular file that is not reached
        /// through a symbolic link.
        static func current(of url: URL) -> Fingerprint? {
            var status = stat()
            guard lstat(url.path(percentEncoded: false), &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFREG,
                  status.st_size >= 0 else {
                return nil
            }
            return Fingerprint(
                fileSize: UInt64(status.st_size),
                modificationSeconds: Int64(status.st_mtimespec.tv_sec),
                modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec),
                statusChangeSeconds: Int64(status.st_ctimespec.tv_sec),
                statusChangeNanoseconds: Int64(status.st_ctimespec.tv_nsec),
                inode: UInt64(status.st_ino)
            )
        }

        /// A rename changes the status-change time but nothing else.
        func matchesIgnoringStatusChange(_ other: Fingerprint) -> Bool {
            fileSize == other.fileSize
                && modificationSeconds == other.modificationSeconds
                && modificationNanoseconds == other.modificationNanoseconds
                && inode == other.inode
        }
    }

    let schemaVersion: Int
    let fingerprint: Fingerprint
    /// Lowercase hexadecimal SHA-256 of the image when it was verified.
    let sha256: String

    static func url(forImageAt imageURL: URL) -> URL {
        imageURL.deletingLastPathComponent()
            .appending(path: "\(imageURL.lastPathComponent).verified.json")
    }

    /// Returns nil for a missing, oversized, linked or undecodable record.
    static func read(forImageAt imageURL: URL) -> Self? {
        let recordURL = url(forImageAt: imageURL)
        var status = stat()
        guard lstat(recordURL.path(percentEncoded: false), &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size > 0,
              status.st_size <= maximumEncodedBytes,
              let data = try? Data(contentsOf: recordURL),
              data.count <= maximumEncodedBytes,
              let record = try? JSONDecoder().decode(Self.self, from: data),
              record.schemaVersion == currentSchemaVersion else {
            return nil
        }
        return record
    }

    func write(forImageAt imageURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(forImageAt: imageURL), options: .atomic)
    }

    static func remove(forImageAt imageURL: URL) {
        try? FileManager.default.removeItem(at: url(forImageAt: imageURL))
    }
}

public struct VMOmarchyFactoryInstaller {
    public static let maximumManifestBytes = 256 * 1_024
    public let profile: VMOmarchyProfile
    public let cacheDirectory: URL
    public let publicKeys: [Data]
    public let transport: any VMOmarchyFactoryTransport
    /// Hashes the whole image. Replaceable so tests can count full reads.
    var validateImage: (URL, VMOmarchyFactoryManifest) throws -> Void = { imageURL, manifest in
        try VMOmarchyFactoryValidator.validateImage(at: imageURL, manifest: manifest)
    }

    public init(
        profile: VMOmarchyProfile,
        cacheDirectory: URL,
        publicKeys: [Data],
        transport: any VMOmarchyFactoryTransport
    ) {
        self.profile = profile
        self.cacheDirectory = cacheDirectory
        self.publicKeys = publicKeys
        self.transport = transport
    }

    public func install(
        progress: @escaping (Int64, Int64) -> Void = { _, _ in }
    ) async throws -> VMOmarchyFactoryInstallResult {
        try await install(stage: { _ in }, progress: progress)
    }

    public func install(
        stage: @escaping (String) -> Void,
        progress: @escaping (Int64, Int64) -> Void = { _, _ in }
    ) async throws -> VMOmarchyFactoryInstallResult {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        stage("Checking the image manifest")
        let manifest = try await fetchVerifiedManifest()

        let published = cacheDirectory.appending(path: "Factory-\(manifest.payload.imageVersion).asif")
        guard !FileManager.default.fileExists(atPath: published.path) else {
            stage("Verifying the cached image")
            try verifyCachedImage(at: published, manifest: manifest)
            return VMOmarchyFactoryInstallResult(diskURL: published, manifest: manifest)
        }
        // A record left behind by an image that no longer exists must never
        // describe the image that is about to be published.
        VMOmarchyFactoryImageVerificationRecord.remove(forImageAt: published)
        let staging = cacheDirectory.appending(path: ".Factory-\(UUID().uuidString).download")
        do {
            stage("Downloading Omarchy")
            if let imageURL = manifest.payload.imageURL {
                try await transport.downloadFile(
                    from: imageURL,
                    to: staging,
                    resumeDataURL: cacheDirectory.appending(path: "Factory.resume"),
                    progress: progress
                )
            } else if let parts = manifest.payload.imageParts {
                try await downloadAndAssemble(parts, to: staging, stage: stage, progress: progress)
            } else {
                throw VMOmarchyFactoryValidationError.invalidManifest
            }
            stage("Verifying the downloaded image")
            let verified = try validateImageReturningStableFingerprint(at: staging, manifest: manifest)
            try FileManager.default.moveItem(at: staging, to: published)
            if let verified,
               let installed = VMOmarchyFactoryImageVerificationRecord.Fingerprint.current(of: published),
               installed.matchesIgnoringStatusChange(verified) {
                recordVerification(of: published, fingerprint: installed, manifest: manifest)
            }
            return VMOmarchyFactoryInstallResult(diskURL: published, manifest: manifest)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Skips the full hash only when the image is byte-for-byte the file that
    /// was hashed before, as far as the file system can tell, and that hash is
    /// the one this manifest expects. Every doubt ends in a full re-hash.
    private func verifyCachedImage(at imageURL: URL, manifest: VMOmarchyFactoryManifest) throws {
        let expectedDigest = manifest.payload.imageSHA256.lowercased()
        if let current = VMOmarchyFactoryImageVerificationRecord.Fingerprint.current(of: imageURL),
           let record = VMOmarchyFactoryImageVerificationRecord.read(forImageAt: imageURL),
           record.fingerprint == current,
           record.sha256 == expectedDigest,
           current.fileSize == manifest.payload.imageByteCount {
            return
        }

        VMOmarchyFactoryImageVerificationRecord.remove(forImageAt: imageURL)
        if let verified = try validateImageReturningStableFingerprint(at: imageURL, manifest: manifest) {
            recordVerification(of: imageURL, fingerprint: verified, manifest: manifest)
        }
    }

    /// Returns the image's fingerprint when it was identical before and after
    /// hashing, and nil when the file changed while it was being read.
    private func validateImageReturningStableFingerprint(
        at imageURL: URL,
        manifest: VMOmarchyFactoryManifest
    ) throws -> VMOmarchyFactoryImageVerificationRecord.Fingerprint? {
        let before = VMOmarchyFactoryImageVerificationRecord.Fingerprint.current(of: imageURL)
        try validateImage(imageURL, manifest)
        guard let before,
              VMOmarchyFactoryImageVerificationRecord.Fingerprint.current(of: imageURL) == before else {
            return nil
        }
        return before
    }

    /// Failing to write the record only costs a re-hash next time.
    private func recordVerification(
        of imageURL: URL,
        fingerprint: VMOmarchyFactoryImageVerificationRecord.Fingerprint,
        manifest: VMOmarchyFactoryManifest
    ) {
        let record = VMOmarchyFactoryImageVerificationRecord(
            schemaVersion: VMOmarchyFactoryImageVerificationRecord.currentSchemaVersion,
            fingerprint: fingerprint,
            sha256: manifest.payload.imageSHA256.lowercased()
        )
        do {
            try record.write(forImageAt: imageURL)
        } catch {
            VMOmarchyFactoryImageVerificationRecord.remove(forImageAt: imageURL)
        }
    }

    private func downloadAndAssemble(
        _ parts: [VMOmarchyFactoryManifest.ImagePart],
        to destination: URL,
        stage: @escaping (String) -> Void,
        progress: @escaping (Int64, Int64) -> Void
    ) async throws {
        let total = parts.reduce(Int64(0)) { partial, part in
            partial + Int64(clamping: part.byteCount)
        }
        var completed: Int64 = 0
        let localParts = parts.indices.map {
            cacheDirectory.appending(path: ".Factory.part-\($0).download")
        }
        defer { localParts.forEach { try? FileManager.default.removeItem(at: $0) } }

        for (index, part) in parts.enumerated() {
            stage("Downloading Omarchy")
            let local = localParts[index]
            let resume = cacheDirectory.appending(path: "Factory.part-\(index).resume")
            try? FileManager.default.removeItem(at: local)
            try await transport.downloadFile(
                from: part.url,
                to: local,
                resumeDataURL: resume
            ) { received, _ in
                progress(min(completed + max(received, 0), total), total)
            }
            stage("Verifying image part \(index + 1) of \(parts.count)")
            try VMOmarchyFactoryValidator.validatePart(at: local, part: part)
            completed += Int64(clamping: part.byteCount)
            progress(completed, total)
        }

        stage("Assembling the image")
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        for local in localParts {
            let input = try FileHandle(forReadingFrom: local)
            defer { try? input.close() }
            while true {
                let data = try input.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
                if data.isEmpty { break }
                try output.write(contentsOf: data)
            }
        }
        try output.synchronize()
    }

    /// Fetches and authenticates channel metadata without downloading or
    /// changing a factory image or the user's workspace.
    public func fetchVerifiedManifest() async throws -> VMOmarchyFactoryManifest {
        let manifestData = try await transport.fetchData(from: profile.factoryImage.manifestURL)
        guard manifestData.count <= Self.maximumManifestBytes else {
            throw VMOmarchyFactoryInstallError.manifestTooLarge
        }
        let manifest: VMOmarchyFactoryManifest
        do {
            manifest = try JSONDecoder().decode(VMOmarchyFactoryManifest.self, from: manifestData)
        } catch {
            throw VMOmarchyFactoryInstallError.invalidManifestEncoding
        }
        try VMOmarchyFactoryValidator.validateManifest(manifest, profile: profile, publicKeys: publicKeys)
        return manifest
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
