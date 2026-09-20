//
//  VMOSHelper.swift
//  RiftVM
//
//  Created by everettjf on 2022/10/1.
//

import Foundation
import CryptoKit
import Security
import Virtualization

enum VMCreationCancellationKind: Equatable {
    case download
    case installation
}


enum VMDiagnosticSanitizer {
    private static let removedKeys: Set<String> = [
        "id", "imagepath", "name", "path", "remark"
    ]
    private static let secretKeyFragments = [
        "credential", "password", "secret", "serial", "token"
    ]

    static func sanitizedConfiguration(data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let output = try? JSONSerialization.data(
                withJSONObject: sanitize(object),
                options: [.prettyPrinted, .sortedKeys]
              ) else { return nil }
        return String(data: output, encoding: .utf8)
    }

    static func sanitizedLogMessage(
        _ message: String,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        machinePaths: [String]
    ) -> String {
        ([homeDirectory] + machinePaths)
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
            .reduce(message) { result, path in
                result.replacingOccurrences(
                    of: path,
                    with: path == homeDirectory ? "<home>" : "<vm-bundle>"
                )
            }
    }

    static func errorIdentifier(_ error: Error) -> String {
        let error = error as NSError
        return "domain=\(error.domain) code=\(error.code)"
    }

    private static func sanitize(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, entry in
                let normalizedKey = entry.key.lowercased()
                if removedKeys.contains(normalizedKey) { return }
                if secretKeyFragments.contains(where: normalizedKey.contains) {
                    result[entry.key] = "<redacted>"
                } else if normalizedKey == "networkidentifier" {
                    result[entry.key] = "<configured>"
                } else {
                    result[entry.key] = sanitize(entry.value)
                }
            }
        }
        if let array = value as? [Any] { return array.map(sanitize) }
        if let string = value as? String,
           string.hasPrefix("/") || string.lowercased().hasPrefix("file:") {
            return "<redacted-path>"
        }
        return value
    }
}

enum VMHostCapability: String, CaseIterable, Identifiable {
    case virtualization
    case vmnet
    case accessoryAccess

    var id: String { rawValue }

    var title: String {
        switch self {
        case .virtualization: "Virtualization"
        case .vmnet: "VMNet"
        case .accessoryAccess: "Accessory Access"
        }
    }

    var entitlementKeys: [String] {
        switch self {
        case .virtualization:
            ["com.apple.security.virtualization"]
        case .vmnet:
            ["com.apple.developer.networking.vmnet"]
        case .accessoryAccess:
            ["com.apple.developer.accessory-access.usb"]
        }
    }

    func grantedEntitlementKey(
        lookup: (String) -> Bool = VMHostCapability.entitlementValue
    ) -> String? {
        entitlementKeys.first(where: lookup)
    }

    var isGranted: Bool {
        grantedEntitlementKey() != nil
    }

    private static func entitlementValue(for key: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, key as CFString, nil) as? Bool == true
    }

    static func diagnosticSummary(
        entitlementLookup: (String) -> Bool,
        diskImageKitIncluded: Bool,
        customVirGLIncluded: Bool
    ) -> [String] {
        var lines = allCases.map { capability in
            let state = capability.grantedEntitlementKey(lookup: entitlementLookup) == nil
                ? "missing entitlement"
                : "entitlement present"
            return "\(capability.title): \(state)"
        }
        lines.append("DiskImageKit / ASIF snapshots: \(diskImageKitIncluded ? "included" : "unavailable in this build")")
        lines.append("Custom Virtio GPU / VirGL: \(customVirGLIncluded ? "included" : "unavailable in this build")")
        return lines
    }
}















#if arch(arm64)
public enum VMPreinstalledSparseStreamDecoder {
    public static func decode(
        from input: FileHandle,
        to outputURL: URL,
        expectedSize: UInt64,
        shouldCancel: () -> Bool = { Task.isCancelled }
    ) throws {
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        guard try readLine(input) == "RiftVM-SPARSE-1",
              let sizeLine = try readLine(input), let logicalSize = UInt64(sizeLine),
              logicalSize == expectedSize else {
            throw DecodeError.invalidHeader
        }
        try output.truncate(atOffset: logicalSize)
        while let line = try readLine(input) {
            if shouldCancel() { throw CancellationError() }
            if line == "END" { return }
            let values = line.split(separator: " ")
            guard values.count == 2,
                  let offset = UInt64(values[0]), let length = UInt64(values[1]),
                  offset <= logicalSize, length <= logicalSize - offset else {
                throw DecodeError.invalidExtent
            }
            try output.seek(toOffset: offset)
            var remaining = length
            while remaining > 0 {
                if shouldCancel() { throw CancellationError() }
                let count = Int(min(remaining, 4 * 1024 * 1024))
                let data = try readExactly(input, count: count)
                try output.write(contentsOf: data)
                remaining -= UInt64(data.count)
            }
            guard try input.read(upToCount: 1) == Data([0x0a]) else { throw DecodeError.invalidExtent }
        }
        throw DecodeError.truncated
    }

    private static func readLine(_ handle: FileHandle) throws -> String? {
        var data = Data()
        while data.count <= 128 {
            guard let byte = try handle.read(upToCount: 1), !byte.isEmpty else {
                return data.isEmpty ? nil : String(data: data, encoding: .utf8)
            }
            if byte[0] == 0x0a { return String(data: data, encoding: .utf8) }
            data.append(byte)
        }
        throw DecodeError.invalidHeader
    }

    private static func readExactly(_ handle: FileHandle, count: Int) throws -> Data {
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            guard let chunk = try handle.read(upToCount: count - result.count), !chunk.isEmpty else {
                throw DecodeError.truncated
            }
            result.append(chunk)
        }
        return result
    }

    public enum DecodeError: LocalizedError, Equatable {
        case invalidHeader, invalidExtent, truncated
        public var errorDescription: String? {
            switch self {
            case .invalidHeader: "The sparse image header is invalid."
            case .invalidExtent: "The sparse image contains an invalid extent."
            case .truncated: "The sparse image stream ended unexpectedly."
            }
        }
    }
}









enum VirtualizationCapability: String, CaseIterable, Identifiable {
    case savedState, automaticDisplayResize, asifStorage
    case guestProvisioning, diskImageKitSnapshots, customVirtio, efiSecureBoot
    case macOSGuestICloud

    var id: String { rawValue }

    var title: String {
        switch self {
        case .savedState: "Saved machine state"
        case .automaticDisplayResize: "Automatic display resizing"
        case .asifStorage: "ASIF storage"
        case .guestProvisioning: "macOS guest provisioning"
        case .diskImageKitSnapshots: "DiskImageKit snapshots"
        case .customVirtio: "Custom Virtio devices"
        case .efiSecureBoot: "EFI Secure Boot management"
        case .macOSGuestICloud: "macOS guest iCloud identity"
        }
    }

    var minimumMajorVersion: Int {
        switch self {
        case .savedState, .automaticDisplayResize: 14
        case .asifStorage: 26
        case .macOSGuestICloud: 15
        case .guestProvisioning, .diskImageKitSnapshots, .customVirtio, .efiSecureBoot: 27
        }
    }

    var isAvailable: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: minimumMajorVersion, minorVersion: 0, patchVersion: 0)
        )
    }
}

/// The one graphics backend RiftVM runs. The type stays for the status plumbing
/// that reports which backend a running machine is using.
enum VMGraphicsBackendKind: String, Codable, Equatable {
    case customVirGL
}

extension VMGraphicsBackendKind {
    var displayName: String {
        switch self {
        case .customVirGL: "Custom VirGL"
        }
    }
}


enum VMGraphicsPresentationHealthTransition: Equatable {
    case none
    case degraded
    case recovered
}

// CAMetalLayer may wait for the display to release a drawable. Keep that wait
// off AppKit and deliver the result on the main actor for lifecycle validation.
final class VMGraphicsDrawableAcquirer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.riftvm.app.drawable", qos: .userInteractive)

    func acquire<Value>(
        _ operation: @escaping () -> Value,
        completion: @escaping @MainActor (Value, TimeInterval) -> Void
    ) {
        queue.async {
            let started = DispatchTime.now().uptimeNanoseconds
            let value = operation()
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
            DispatchQueue.main.async { completion(value, elapsed) }
        }
    }
}

/// Damage remains pending until a presentation actually starts. A request that
/// arrives during that presentation survives its completion. Failed acquisitions
/// get bounded retries, so a lost final frame can recover without an idle loop.
struct VMGraphicsPresentationDemand {
    private(set) var isPending = false
    private var retriesRemaining = 0

    mutating func request() {
        isPending = true
        retriesRemaining = 3
    }

    mutating func take() -> Bool {
        guard isPending else { return false }
        isPending = false
        return true
    }

    mutating func retryAfterFailure() {
        guard !isPending, retriesRemaining > 0 else { return }
        retriesRemaining -= 1
        isPending = true
    }

    mutating func cancel() {
        isPending = false
        retriesRemaining = 0
    }
}

/// CPU-side timing only; completion does not measure display scanout latency.
struct VMGraphicsTimingSummary: Equatable {
    let averageMilliseconds: Double
    let p95Milliseconds: Double
    let maximumMilliseconds: Double

    init(durations: [TimeInterval]) {
        let sorted = durations.sorted()
        guard !sorted.isEmpty else {
            averageMilliseconds = 0
            p95Milliseconds = 0
            maximumMilliseconds = 0
            return
        }
        averageMilliseconds = sorted.reduce(0, +) * 1000 / Double(sorted.count)
        p95Milliseconds = sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1] * 1000
        maximumMilliseconds = sorted[sorted.count - 1] * 1000
    }
}

struct VMGraphicsPresentationHealthTracker: Equatable {
    private(set) var consecutiveFailures = 0
    private(set) var isDegraded = false
    let failureThreshold: Int

    init(failureThreshold: Int = 3) {
        self.failureThreshold = max(1, failureThreshold)
    }

    mutating func record(success: Bool) -> VMGraphicsPresentationHealthTransition {
        if success {
            consecutiveFailures = 0
            guard isDegraded else { return .none }
            isDegraded = false
            return .recovered
        }

        consecutiveFailures = min(consecutiveFailures + 1, failureThreshold)
        guard !isDegraded, consecutiveFailures >= failureThreshold else { return .none }
        isDegraded = true
        return .degraded
    }
}

struct VMGraphicsPresentationLifecycle: Equatable {
    private(set) var generation: UInt64 = 0
    private(set) var isStopped = false

    func tokenForPresentation() -> UInt64? {
        isStopped ? nil : generation
    }

    func acceptsCompletion(token: UInt64) -> Bool {
        !isStopped && token == generation
    }

    mutating func stop() {
        guard !isStopped else { return }
        isStopped = true
        generation &+= 1
    }
}

struct VMGraphicsPresentationEventFence: Equatable {
    private(set) var latestAcceptedSequence: UInt64 = 0

    mutating func accept(_ sequence: UInt64) -> Bool {
        guard sequence > latestAcceptedSequence else { return false }
        latestAcceptedSequence = sequence
        return true
    }
}



@available(macOS 27.0, *)











enum VMDiskImageFormat: String, Codable, CaseIterable, Identifiable {
    case raw
    case asif

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .raw: "img"
        case .asif: "asif"
        }
    }
}

struct VMDiskImageManager {
    struct Command: Equatable {
        let executable: String
        let arguments: [String]
    }

    static func creationCommand(format: VMDiskImageFormat, url: URL, size: UInt64) -> Command? {
        guard format == .asif else { return nil }
        return Command(
            executable: "/usr/sbin/diskutil",
            arguments: [
                "image", "create", "blank",
                "--format", "ASIF",
                "--size", String(size),
                "--fs", "None",
                url.path(percentEncoded: false),
            ]
        )
    }

    static func conversionCommand(sourceURL: URL, destinationURL: URL) -> Command {
        Command(
            executable: "/usr/sbin/diskutil",
            arguments: [
                "image", "create", "from",
                "--format", "ASIF",
                sourceURL.path(percentEncoded: false),
                destinationURL.path(percentEncoded: false),
            ]
        )
    }

    static func create(format: VMDiskImageFormat, at url: URL, size: UInt64) -> VMOSResultVoid {
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            let matches: Bool
            switch format {
            case .raw:
                matches = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                    .map { UInt64($0) == size } ?? false
            case .asif:
                // ASIF is sparse, so its physical file size is unrelated to
                // its logical capacity. Once created, the image itself is the
                // capacity authority and must never be recreated on startup.
                matches = existingASIFImageHasValidHeader(url: url)
            }
            guard matches else {
                return .failure("A disk image already exists at the destination with a different format or size.")
            }
            return .success
        }

        switch format {
        case .raw:
            return createRaw(at: url, size: size)
        case .asif:
            guard let command = creationCommand(format: format, url: url, size: size) else {
                return .failure("Could not prepare the ASIF creation command.")
            }
            let result = run(command)
            if case .failure = result { try? FileManager.default.removeItem(at: url) }
            return result
        }
    }

    static func convertRawToASIF(sourceURL: URL, destinationURL: URL) -> VMOSResultVoid {
        guard FileManager.default.fileExists(atPath: sourceURL.path(percentEncoded: false)) else {
            return .failure("The source disk image does not exist.")
        }
        guard !FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false)) else {
            return .failure("The destination disk image already exists.")
        }
        return convertRawToASIF(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            executor: run
        )
    }

    static func convertRawToASIF(
        sourceURL: URL,
        destinationURL: URL,
        availableCapacityBytes: Int64? = nil,
        executor: (Command) -> VMOSResultVoid
    ) -> VMOSResultVoid {
        guard FileManager.default.fileExists(atPath: sourceURL.path(percentEncoded: false)) else {
            return .failure("The source disk image does not exist.")
        }
        guard !FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false)) else {
            return .failure("The destination disk image already exists.")
        }
        do {
            let values = try sourceURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            let requiredBytes = Int64(max(0, values.totalFileAllocatedSize ?? values.fileSize ?? 0))
            try VMStorageCapacity.validate(
                requiredBytes: requiredBytes,
                at: destinationURL,
                availableBytesOverride: availableCapacityBytes
            )
        } catch {
            return .failure("Cannot convert the disk to ASIF: \(error.localizedDescription)")
        }
        let result = executor(conversionCommand(sourceURL: sourceURL, destinationURL: destinationURL))
        if case .failure = result {
            try? FileManager.default.removeItem(at: destinationURL)
        }
        return result
    }

    private static func createRaw(at url: URL, size: UInt64) -> VMOSResultVoid {
        let descriptor = open(url.path(percentEncoded: false), O_RDWR | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor != -1 else {
            return .failure("Cannot create the raw disk image.")
        }
        defer { close(descriptor) }
        guard ftruncate(descriptor, off_t(size)) == 0 else {
            try? FileManager.default.removeItem(at: url)
            return .failure("Could not resize the raw disk image.")
        }
        return .success
    }

    static func existingASIFImageHasValidHeader(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4) else { return false }
        return header == Data([0x73, 0x68, 0x64, 0x77])
    }

    private static func run(_ command: Command) -> VMOSResultVoid {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(message?.isEmpty == false ? message! : "diskutil failed with status \(process.terminationStatus).")
            }
            return .success
        } catch {
            return .failure("Could not run diskutil: \(error.localizedDescription)")
        }
    }
}


enum VMEFIVariableStoreRecovery {
    static func isInvalidBootLoaderError(_ message: String) -> Bool {
        let value = message.lowercased()
        return value.contains("boot loader") && value.contains("invalid")
    }

    /// Replaces a store only after Virtualization.framework explicitly rejects
    /// its boot loader. The rejected bytes are retained for diagnostics.
    static func replaceRejectedStore(at storeURL: URL) throws -> URL? {
        let fileManager = FileManager.default
        let replacementURL = storeURL.appendingPathExtension("replacement")
        let backupURL = storeURL.appendingPathExtension("invalid-backup")
        try? fileManager.removeItem(at: replacementURL)
        try? fileManager.removeItem(at: backupURL)
        _ = try VZEFIVariableStore(creatingVariableStoreAt: replacementURL)

        let hadOriginal = fileManager.fileExists(atPath: storeURL.path)
        if hadOriginal {
            try fileManager.moveItem(at: storeURL, to: backupURL)
        }
        do {
            try fileManager.moveItem(at: replacementURL, to: storeURL)
            return hadOriginal ? backupURL : nil
        } catch {
            try? fileManager.removeItem(at: replacementURL)
            if hadOriginal, !fileManager.fileExists(atPath: storeURL.path) {
                try? fileManager.moveItem(at: backupURL, to: storeURL)
            }
            throw error
        }
    }
}









/// Why an operation that needs disk space cannot run.
enum VMStorageCapacityError: LocalizedError, Equatable {
    case insufficientDiskSpace(required: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case let .insufficientDiskSpace(required, available):
            "The operation needs at least \(Self.bytes(required)) free, but only \(Self.bytes(available)) is available."
        }
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

enum VMStorageCapacity {
    static let defaultReserveBytes: Int64 = 1_073_741_824

    static func availableBytes(at url: URL) -> Int64? {
        let directory = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        return (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    static func validate(
        requiredBytes: Int64?,
        at url: URL,
        reserveBytes: Int64 = defaultReserveBytes,
        availableBytesOverride: Int64? = nil
    ) throws {
        guard let requiredBytes, requiredBytes > 0,
              let available = availableBytesOverride ?? availableBytes(at: url) else { return }
        let (sum, overflow) = requiredBytes.addingReportingOverflow(max(0, reserveBytes))
        let requiredWithReserve = overflow ? Int64.max : sum
        guard available < requiredWithReserve else { return }
        throw VMStorageCapacityError.insufficientDiskSpace(required: requiredWithReserve, available: available)
    }
}



enum VMThumbnailPreferences {
    static let screenCaptureEnabledKey = "thumbnail.screen-capture-enabled"
    static let generatedStyleKey = "thumbnail.generated-style"

    static func generatedStyleKey(for rootPath: URL) -> String {
        "\(generatedStyleKey).vm.\(rootPath.standardizedFileURL.path(percentEncoded: true))"
    }
}






#endif
