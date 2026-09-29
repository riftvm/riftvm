import AppKit
import CryptoKit
import Foundation

@MainActor
final class OmarchyAgentClipboardController {
    static let maximumBytes = 100 * 1024 * 1024
    static let textMIME = "text/plain;charset=utf-8"
    static let imageMIME = "image/png"

    private struct Item {
        let data: Data
        let mimeType: String
        let fileExtension: String

        var fingerprint: String {
            "\(mimeType):\(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())"
        }
    }

    private let client: VMOmarchyGuestAgentClient
    private let sharedDirectory: URL
    /// Path of `sharedDirectory` below the Guest mount point: empty when it is
    /// the root, `.riftvm/` in the multi-folder layout.
    private let guestRelativePrefix: String
    private let pasteboard: NSPasteboard
    private var timer: Timer?
    private var operationTask: Task<Void, Never>?
    private var lastPasteboardChangeCount: Int
    private var lastSentToGuest: String?
    private var lastReceivedFromGuest: String?
    private var pendingHostItem: Item?
    /// What the previous capture saw, so an unchanged Guest selection is
    /// neither staged nor read again.
    private var captureMemory = VMOmarchyClipboardCaptureMemory()

    private enum Capture {
        /// The same result as the previous capture, which was handled then.
        case unchanged
        case item(Item)
        case nothing
    }

    private enum CapturedData {
        case unchanged
        case data(Data, sha256: String)
    }

    init(
        client: VMOmarchyGuestAgentClient,
        sharedDirectory: URL,
        guestRelativePrefix: String = "",
        pasteboard: NSPasteboard = .general
    ) {
        self.client = client
        self.sharedDirectory = sharedDirectory
        self.guestRelativePrefix = guestRelativePrefix
        self.pasteboard = pasteboard
        lastPasteboardChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        operationTask?.cancel()
        operationTask = nil
    }

    /// Stops polling and waits until the in-flight Agent request can no
    /// longer change the Guest selection. Acceptance uses this barrier before
    /// beginning its ordered clipboard round trips.
    func quiesce() async {
        timer?.invalidate()
        timer = nil
        let task = operationTask
        NSLog("Omarchy clipboard bridge quiescing (in-flight=%@)", task == nil ? "no" : "yes")
        task?.cancel()
        await task?.value
        operationTask = nil
        NSLog("Omarchy clipboard bridge quiesced")
    }

    private func tick() {
        guard operationTask == nil else { return }
        if pasteboard.changeCount != lastPasteboardChangeCount {
            lastPasteboardChangeCount = pasteboard.changeCount
            pendingHostItem = nil
            guard let item = Self.item(from: pasteboard),
                  item.fingerprint != lastReceivedFromGuest else { return }
            pendingHostItem = item
        }
        if let item = pendingHostItem {
            operationTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.operationTask = nil }
                // Sending changes the Guest selection and what the next
                // captured item is compared with.
                self.captureMemory.reset()
                defer { self.captureMemory.reset() }
                do {
                    try await self.sendToGuest(item)
                    self.lastSentToGuest = item.fingerprint
                    if self.pendingHostItem?.fingerprint == item.fingerprint {
                        self.pendingHostItem = nil
                    }
                } catch is CancellationError {
                } catch {
                    NSLog("Omarchy Agent Host-to-Guest clipboard failed: %@", error.localizedDescription)
                }
            }
            return
        }
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.operationTask = nil }
            do {
                if case let .item(item) = await self.captureFromGuest(),
                   item.fingerprint != self.lastSentToGuest,
                   item.fingerprint != self.lastReceivedFromGuest {
                    try Self.publish(item, on: self.pasteboard)
                    self.lastReceivedFromGuest = item.fingerprint
                    self.lastPasteboardChangeCount = self.pasteboard.changeCount
                }
            } catch {
                // A requested format can be absent while the other one is
                // active. Capture failures are transient and must not tear
                // down the authenticated integration connection. The item
                // was not published, so it must be captured again.
                self.captureMemory.reset()
            }
        }
    }

    private func sendToGuest(_ item: Item) async throws {
        let url = try stagingURL(fileExtension: item.fileExtension)
        defer { try? FileManager.default.removeItem(at: url) }
        try item.data.write(to: url, options: [.atomic])
        let digest = SHA256.hash(data: item.data).map { String(format: "%02x", $0) }.joined()
        _ = try await client.setGuestClipboard(VMOmarchyClipboardRequest(
            relativePath: relativePath(for: url),
            mimeType: item.mimeType,
            byteCount: UInt64(item.data.count),
            sha256: digest
        ))
    }

    /// Probes the image format first and text second, as before. An Agent
    /// that does not know `knownSHA256` stages the item on every capture and
    /// the result is handled exactly as it always was.
    private func captureFromGuest() async -> Capture {
        captureMemory.beginCapture()
        defer { captureMemory.endCapture() }
        for (mimeType, fileExtension) in [(Self.imageMIME, "png"), (Self.textMIME, "txt")] {
            var item: Item?
            let probe: VMOmarchyClipboardCaptureMemory.Probe
            switch try? await capture(
                mimeType: mimeType,
                fileExtension: fileExtension,
                knownSHA256: captureMemory.knownSHA256(for: mimeType)
            ) {
            case .none:
                probe = .failed
            case .some(.unchanged):
                probe = .unchanged
            case let .some(.data(data, sha256)):
                let usable = Self.isUsable(data, mimeType: mimeType)
                if usable {
                    item = Item(data: data, mimeType: mimeType, fileExtension: fileExtension)
                }
                probe = .captured(sha256: sha256, usable: usable)
            }
            switch captureMemory.resolve(probe, for: mimeType) {
            case .unchanged:
                return .unchanged
            case .captured:
                if let item { return .item(item) }
            case .tryNext:
                break
            }
        }
        return .nothing
    }

    private static func isUsable(_ data: Data, mimeType: String) -> Bool {
        switch mimeType {
        case imageMIME:
            NSBitmapImageRep(data: data) != nil
        default:
            data.count <= maximumBytes && String(data: data, encoding: .utf8) != nil
        }
    }

    private func capture(
        mimeType: String,
        fileExtension: String,
        knownSHA256: String?
    ) async throws -> CapturedData {
        let url = try stagingURL(fileExtension: fileExtension)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await client.captureGuestClipboard(VMOmarchyClipboardRequest(
            relativePath: relativePath(for: url),
            mimeType: mimeType,
            byteCount: 0,
            sha256: "",
            knownSHA256: knownSHA256
        ))
        if result.unchanged == true {
            // Nothing was staged. Only the answer to the digest that was
            // asked about counts; anything else is a failed capture.
            guard result.confirmsUnchanged(knownSHA256: knownSHA256) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return .unchanged
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let sha256 = SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined()
        guard data.count <= Self.maximumBytes,
              result.byteCount == UInt64(data.count),
              result.sha256 == sha256
        else { throw CocoaError(.fileReadCorruptFile) }
        return .data(data, sha256: sha256)
    }

    private func stagingURL(fileExtension: String) throws -> URL {
        try FileManager.default.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
        return sharedDirectory.appending(
            path: ".riftvm-clipboard-\(UUID().uuidString.lowercased()).\(fileExtension)"
        )
    }

    private func relativePath(for url: URL) -> String {
        guestRelativePrefix + String(url.path.dropFirst(sharedDirectory.path.count + 1))
    }

    private static func item(from pasteboard: NSPasteboard) -> Item? {
        if let data = pasteboard.data(forType: .png),
           !data.isEmpty, data.count <= maximumBytes,
           NSBitmapImageRep(data: data) != nil {
            return Item(data: data, mimeType: imageMIME, fileExtension: "png")
        }
        guard let value = pasteboard.string(forType: .string) else { return nil }
        let data = Data(value.utf8)
        guard data.count <= maximumBytes else { return nil }
        return Item(data: data, mimeType: textMIME, fileExtension: "txt")
    }

    private static func publish(_ item: Item, on pasteboard: NSPasteboard) throws {
        pasteboard.clearContents()
        let succeeded: Bool
        switch item.mimeType {
        case imageMIME:
            succeeded = pasteboard.setData(item.data, forType: .png)
        case textMIME:
            guard let value = String(data: item.data, encoding: .utf8) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            succeeded = pasteboard.setString(value, forType: .string)
        default:
            throw CocoaError(.featureUnsupported)
        }
        guard succeeded else { throw CocoaError(.fileWriteUnknown) }
    }
}
