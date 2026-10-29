import Foundation
import CryptoKit

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
        var publicationError: Error?
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
        lock.withLock {
            activeDownloads[downloadTask.taskIdentifier]?.progress(
                totalBytesWritten,
                totalBytesExpectedToWrite
            )
        }
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
            lock.withLock {
                activeDownloads[downloadTask.taskIdentifier]?.publicationError = error
            }
            downloadTask.cancel()
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let active = lock.withLock({ activeDownloads.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let error = active.publicationError ?? error {
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
    case invalidManualDownload(fileName: String, reason: String)

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
        case .invalidManualDownload(let fileName, let reason):
            "The manual download \"\(fileName)\" could not be verified: \(reason) Replace this file and retry."
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

/// Browser downloads live separately from temporary downloads, so retries never
/// delete the user's files. All inputs still pass the signed manifest checks.
public struct VMOmarchyFactoryManualDownload: Equatable, Sendable {
    public struct File: Equatable, Sendable {
        public let source: URL
        public let destination: URL
    }

    public let directory: URL
    public let files: [File]
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

public struct VMOmarchyFactoryInstaller {
    public static let maximumManifestBytes = 256 * 1_024
    public let profile: VMOmarchyProfile
    public let cacheDirectory: URL
    public let publicKeys: [Data]
    public let transport: any VMOmarchyFactoryTransport

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

    public func manualDownload(manifest: VMOmarchyFactoryManifest? = nil) -> VMOmarchyFactoryManualDownload {
        // Isolate immutable release channels so files from an older app cannot
        // override the manifest selected by a newer build.
        let channel = SHA256.hash(data: Data(profile.factoryImage.manifestURL.absoluteString.utf8))
            .prefix(6).map { String(format: "%02x", $0) }.joined()
        let directory = cacheDirectory.appending(path: "ManualDownloads/\(channel)", directoryHint: .isDirectory)
        var sources = [profile.factoryImage.manifestURL]
        if let manifest {
            sources += manifest.payload.imageURL.map { [$0] }
                ?? manifest.payload.imageParts?.map(\.url) ?? []
        }
        var names = Set<String>()
        let files = sources.enumerated().map { index, source in
            var name = source.lastPathComponent.replacingOccurrences(of: "/", with: "_")
            if name.isEmpty || name == "." || name == ".." { name = "download-\(index)" }
            while !names.insert(name).inserted { name = "\(index)-\(name)" }
            return VMOmarchyFactoryManualDownload.File(
                source: source,
                destination: directory.appendingPathComponent(name, isDirectory: false)
            )
        }
        return VMOmarchyFactoryManualDownload(directory: directory, files: files)
    }

    public func install(
        progress: @escaping (Int64, Int64) -> Void = { _, _ in }
    ) async throws -> VMOmarchyFactoryInstallResult {
        try await install(stage: { _ in }, progress: progress)
    }

    public func install(
        stage: @escaping (String) -> Void,
        manualDownloadAvailable: @escaping (VMOmarchyFactoryManualDownload) async -> Void = { _ in },
        progress: @escaping (Int64, Int64) -> Void = { _, _ in }
    ) async throws -> VMOmarchyFactoryInstallResult {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        stage("Checking the image manifest")
        let manifest = try await fetchVerifiedManifest()
        let manual = manualDownload(manifest: manifest)
        await manualDownloadAvailable(manual)
        try FileManager.default.createDirectory(at: manual.directory, withIntermediateDirectories: true)
        // Retain verified metadata so manual image downloads can be retried
        // without another network request, including after relaunching the app.
        try JSONEncoder().encode(manifest).write(to: manual.files[0].destination, options: .atomic)

        let published = cacheDirectory.appending(path: "Factory-\(manifest.payload.imageVersion).asif")
        guard !FileManager.default.fileExists(atPath: published.path) else {
            stage("Verifying the cached image")
            try VMOmarchyFactoryValidator.validateImage(at: published, manifest: manifest)
            return VMOmarchyFactoryInstallResult(diskURL: published, manifest: manifest)
        }
        let staging = cacheDirectory.appending(path: ".Factory-\(UUID().uuidString).download")
        do {
            stage("Downloading Omarchy")
            if let imageURL = manifest.payload.imageURL {
                let local = manual.files[1].destination
                if FileManager.default.fileExists(atPath: local.path) {
                    stage("Verifying the manual download")
                    do {
                        try VMOmarchyFactoryValidator.validateImage(at: local, manifest: manifest)
                    } catch {
                        throw VMOmarchyFactoryInstallError.invalidManualDownload(
                            fileName: local.lastPathComponent, reason: error.localizedDescription
                        )
                    }
                    try FileManager.default.copyItem(at: local, to: staging)
                } else {
                    try await transport.downloadFile(
                        from: imageURL,
                        to: staging,
                        resumeDataURL: cacheDirectory.appending(path: "Factory.resume"),
                        progress: progress
                    )
                }
            } else if let parts = manifest.payload.imageParts {
                try await downloadAndAssemble(parts, manual: manual, to: staging, stage: stage, progress: progress)
            } else {
                throw VMOmarchyFactoryValidationError.invalidManifest
            }
            stage("Verifying the downloaded image")
            try VMOmarchyFactoryValidator.validateImage(at: staging, manifest: manifest)
            try FileManager.default.moveItem(at: staging, to: published)
            return VMOmarchyFactoryInstallResult(diskURL: published, manifest: manifest)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    private func downloadAndAssemble(
        _ parts: [VMOmarchyFactoryManifest.ImagePart],
        manual: VMOmarchyFactoryManualDownload,
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
        var assemblyParts: [URL] = []

        for (index, part) in parts.enumerated() {
            stage("Downloading Omarchy")
            let manualPart = manual.files[index + 1].destination
            let local: URL
            if FileManager.default.fileExists(atPath: manualPart.path) {
                local = manualPart
            } else {
                local = localParts[index]
                let resume = cacheDirectory.appending(path: "Factory.part-\(index).resume")
                try? FileManager.default.removeItem(at: local)
                try await transport.downloadFile(
                    from: part.url,
                    to: local,
                    resumeDataURL: resume
                ) { received, _ in
                    progress(min(completed + max(received, 0), total), total)
                }
            }
            stage("Verifying image part \(index + 1) of \(parts.count)")
            do {
                try VMOmarchyFactoryValidator.validatePart(at: local, part: part)
            } catch {
                guard local == manualPart else { throw error }
                throw VMOmarchyFactoryInstallError.invalidManualDownload(
                    fileName: local.lastPathComponent, reason: error.localizedDescription
                )
            }
            assemblyParts.append(local)
            completed += Int64(clamping: part.byteCount)
            progress(completed, total)
        }

        stage("Assembling the image")
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        for local in assemblyParts {
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
        let local = manualDownload().files[0].destination
        let manifestData: Data
        if FileManager.default.fileExists(atPath: local.path) {
            let input = try FileHandle(forReadingFrom: local)
            defer { try? input.close() }
            manifestData = try input.read(upToCount: Self.maximumManifestBytes + 1) ?? Data()
        } else {
            manifestData = try await transport.fetchData(from: profile.factoryImage.manifestURL)
        }
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
