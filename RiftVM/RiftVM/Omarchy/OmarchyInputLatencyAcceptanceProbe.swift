import Foundation

@MainActor
enum OmarchyInputLatencyAcceptanceProbe {
    enum Backend: String, Codable, CaseIterable {
        case appleUSB = "apple-usb"
        case guestAgent = "guest-agent-uinput"
    }

    struct Sample: Codable, Equatable {
        let backend: Backend
        let index: Int
        let traceID: String
        let clockOffsetGuestMinusHostNanoseconds: Int64
        let calibrationRoundTripMilliseconds: Double
        let hostDispatchedAtUnixNanoseconds: UInt64
        let guestAgentReceivedAtUnixNanoseconds: UInt64?
        let uinputCompletedAtUnixNanoseconds: UInt64?
        let guestApplicationReceivedAtUnixNanoseconds: UInt64
        let guestVisibleSurfaceCapturedAtUnixNanoseconds: UInt64
        let hostObservedAtUnixNanoseconds: UInt64
        let agentWriteMilliseconds: Double?
        let hostToGuestApplicationMilliseconds: Double
        let guestApplicationToVisibleMilliseconds: Double
        let hostToVisibleObservationMilliseconds: Double
        let baselineSHA256: String
        let visibleSHA256: String
    }

    struct BackendSummary: Codable, Equatable {
        let backend: Backend
        let samples: Int
        let p50HostToGuestApplicationMilliseconds: Double
        let p95HostToGuestApplicationMilliseconds: Double
        let p95GuestApplicationToVisibleMilliseconds: Double
        let p95HostToVisibleObservationMilliseconds: Double
    }

    struct Report: Codable, Equatable {
        let schemaVersion: Int
        let measuredAt: Date
        let clockOffsetGuestMinusHostNanoseconds: Int64
        let calibrationRoundTripMilliseconds: Double
        let samples: [Sample]
        let summaries: [BackendSummary]
        let recommendedBackend: Backend
    }

    enum ProbeError: LocalizedError {
        case invalidSampleCount
        case terminalUnavailable
        case usbDeliveryUnavailable
        case timeout(String)
        case invalidResult(String)
        case noVisibleChange

        var errorDescription: String? {
            switch self {
            case .invalidSampleCount: "Input latency sample count must be between 5 and 100."
            case .terminalUnavailable: "The Omarchy terminal could not be opened for input latency acceptance."
            case .usbDeliveryUnavailable: "The Apple USB keyboard acceptance path could not deliver its sample."
            case .timeout(let path): "Timed out waiting for the Guest input result at \(path)."
            case .invalidResult(let value): "The Guest returned an invalid input latency result: \(value)."
            case .noVisibleChange: "The Guest compositor capture did not change after input."
            }
        }
    }

    static let reportFileName = "input-latency-ab.json"

    static func run(
        client: VMOmarchyGuestAgentClient,
        sharedDirectory: URL,
        diagnosticsDirectory: URL,
        sampleCount: Int = 20,
        unlockPassword: String? = nil,
        sendAppleUSBText: @escaping (String) async -> Bool
    ) async throws -> Report {
        guard (5...100).contains(sampleCount) else { throw ProbeError.invalidSampleCount }
        let clock = try await calibrateClock(client: client)
        // A previous interrupted acceptance run may have left its terminal
        // blocked in `read`. Clear that foreground process before opening the
        // dedicated probe terminal so retries remain deterministic.
        try? await client.injectKeyChord(modifiers: [29], key: 46)
        try await Task.sleep(for: .milliseconds(150))
        try await client.injectKeyChord(modifiers: [125], key: 28)
        try await Task.sleep(for: .seconds(2))

        var samples: [Sample] = []
        do {
            for backend in Backend.allCases {
                for index in 0..<sampleCount {
                    samples.append(try await runSample(
                        backend: backend,
                        index: index,
                        client: client,
                        sharedDirectory: sharedDirectory,
                        unlockPassword: samples.isEmpty ? unlockPassword : nil,
                        sendAppleUSBText: sendAppleUSBText
                    ))
                }
            }
        } catch {
            // Startup clears a prior foreground reader. Report the original
            // failure immediately rather than hiding it behind cleanup I/O.
            throw error
        }
        try? await client.typeUSASCII("exit\n")

        let summaries = Backend.allCases.map { summarize($0, samples: samples) }
        let recommended = summaries.min {
            if $0.p95HostToGuestApplicationMilliseconds == $1.p95HostToGuestApplicationMilliseconds {
                return $0.p95HostToVisibleObservationMilliseconds < $1.p95HostToVisibleObservationMilliseconds
            }
            return $0.p95HostToGuestApplicationMilliseconds < $1.p95HostToGuestApplicationMilliseconds
        }?.backend ?? .guestAgent
        let report = Report(
            schemaVersion: 2,
            measuredAt: Date(),
            clockOffsetGuestMinusHostNanoseconds: clock.offset,
            calibrationRoundTripMilliseconds: clock.roundTripMilliseconds,
            samples: samples,
            summaries: summaries,
            recommendedBackend: recommended
        )
        try FileManager.default.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder.acceptance.encode(report)
        try data.write(to: diagnosticsDirectory.appending(path: reportFileName), options: .atomic)
        return report
    }

    private static func calibrateClock(
        client: VMOmarchyGuestAgentClient
    ) async throws -> (offset: Int64, roundTripMilliseconds: Double) {
        var traces: [VMOmarchyInputTraceResult] = []
        let invisibleReport = [
            VMGuestAgentInputEvent(type: 2, code: 0, value: 0),
            VMGuestAgentInputEvent(type: 0, code: 0, value: 0),
        ]
        for _ in 0..<7 {
            traces.append(try await client.injectTracedInputEvents(invisibleReport))
        }
        let best = traces.min {
            ($0.hostAcknowledgedAtUnixNanoseconds - $0.hostSentAtUnixNanoseconds)
                < ($1.hostAcknowledgedAtUnixNanoseconds - $1.hostSentAtUnixNanoseconds)
        }!
        let midpoint = best.hostSentAtUnixNanoseconds
            + (best.hostAcknowledgedAtUnixNanoseconds - best.hostSentAtUnixNanoseconds) / 2
        return (
            signedDifference(best.guestReceivedAtUnixNanoseconds, midpoint),
            Double(best.hostAcknowledgedAtUnixNanoseconds - best.hostSentAtUnixNanoseconds) / 1_000_000
        )
    }

    private static func runSample(
        backend: Backend,
        index: Int,
        client: VMOmarchyGuestAgentClient,
        sharedDirectory: URL,
        unlockPassword: String?,
        sendAppleUSBText: @escaping (String) async -> Bool
    ) async throws -> Sample {
        let traceID = UUID().uuidString.lowercased()
        let directory = sharedDirectory.appending(path: ".riftvm-input-latency-\(traceID)")
        let script = directory.appending(path: "probe.sh")
        let ready = directory.appending(path: "ready")
        let result = directory.appending(path: "result.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var succeeded = false
        defer { if succeeded { try? FileManager.default.removeItem(at: directory) } }
        try Data(probeScript(guestDirectory: "/mnt/riftvm-shared/\(directory.lastPathComponent)").utf8)
            .write(to: script, options: .atomic)
        try await client.typeUSASCII("bash /mnt/riftvm-shared/\(directory.lastPathComponent)/probe.sh\n")
        do {
            try await waitForFile(ready, timeout: .seconds(10))
        } catch {
            // A persistent workspace can reconnect while the secure lock
            // surface is still visible. uinput is intentionally ignored there,
            // so unlock through the always-present Apple USB keyboard, wait for
            // the desktop Agent to rebind, then open a fresh probe terminal.
            guard let unlockPassword,
                  await sendAppleUSBText(unlockPassword + "\n") else { throw error }
            try await Task.sleep(for: .seconds(5))
            try await client.injectKeyChord(modifiers: [125], key: 28)
            try await Task.sleep(for: .seconds(2))
            try await client.typeUSASCII("bash /mnt/riftvm-shared/\(directory.lastPathComponent)/probe.sh\n")
            try await waitForFile(ready, timeout: .seconds(10))
        }

        // Linux's wall clock can slew while chronyd converges after boot. A
        // single calibration for the whole run made later samples appear
        // hundreds of milliseconds slower. Calibrate immediately before each
        // dispatch so Host -> Guest timings remain comparable and auditable.
        let clock = try await calibrateClock(client: client)
        let hostDispatch = unixNanoseconds()
        let trace: VMOmarchyInputTraceResult?
        switch backend {
        case .guestAgent:
            trace = try await client.injectTracedInputEvents([
                VMGuestAgentInputEvent(type: 1, code: 45, value: 1),
                VMGuestAgentInputEvent(type: 0, code: 0, value: 0),
                VMGuestAgentInputEvent(type: 1, code: 45, value: 0),
                VMGuestAgentInputEvent(type: 0, code: 0, value: 0),
            ], traceID: traceID)
        case .appleUSB:
            trace = nil
            guard await sendAppleUSBText("x") else { throw ProbeError.usbDeliveryUnavailable }
        }
        try await waitForFile(result, timeout: .seconds(10))
        let hostObserved = unixNanoseconds()
        let fields = try parseResult(String(decoding: Data(contentsOf: result), as: UTF8.self))
        guard fields.baselineSHA256 != fields.visibleSHA256 else { throw ProbeError.noVisibleChange }

        let hostDispatchOnGuestClock = adding(hostDispatch, clock.offset)
        let hostToGuest = milliseconds(from: hostDispatchOnGuestClock, to: fields.receivedAt)
        let guestToVisible = Double(fields.visibleAfterReceivedNanoseconds) / 1_000_000
        let hostToVisibleObservation = milliseconds(from: hostDispatch, to: hostObserved)
        succeeded = true
        return Sample(
            backend: backend,
            index: index,
            traceID: traceID,
            clockOffsetGuestMinusHostNanoseconds: clock.offset,
            calibrationRoundTripMilliseconds: clock.roundTripMilliseconds,
            hostDispatchedAtUnixNanoseconds: hostDispatch,
            guestAgentReceivedAtUnixNanoseconds: trace?.guestReceivedAtUnixNanoseconds,
            uinputCompletedAtUnixNanoseconds: trace?.uinputCompletedAtUnixNanoseconds,
            guestApplicationReceivedAtUnixNanoseconds: fields.receivedAt,
            guestVisibleSurfaceCapturedAtUnixNanoseconds:
                fields.receivedAt &+ fields.visibleAfterReceivedNanoseconds,
            hostObservedAtUnixNanoseconds: hostObserved,
            agentWriteMilliseconds: trace.map {
                milliseconds(from: $0.guestReceivedAtUnixNanoseconds, to: $0.uinputCompletedAtUnixNanoseconds)
            },
            hostToGuestApplicationMilliseconds: hostToGuest,
            guestApplicationToVisibleMilliseconds: guestToVisible,
            hostToVisibleObservationMilliseconds: hostToVisibleObservation,
            baselineSHA256: fields.baselineSHA256,
            visibleSHA256: fields.visibleSHA256
        )
    }

    private static func summarize(_ backend: Backend, samples: [Sample]) -> BackendSummary {
        let selected = samples.filter { $0.backend == backend }
        return BackendSummary(
            backend: backend,
            samples: selected.count,
            p50HostToGuestApplicationMilliseconds: percentile(selected.map(\.hostToGuestApplicationMilliseconds), 0.50),
            p95HostToGuestApplicationMilliseconds: percentile(selected.map(\.hostToGuestApplicationMilliseconds), 0.95),
            p95GuestApplicationToVisibleMilliseconds: percentile(selected.map(\.guestApplicationToVisibleMilliseconds), 0.95),
            p95HostToVisibleObservationMilliseconds: percentile(selected.map(\.hostToVisibleObservationMilliseconds), 0.95)
        )
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))
        return sorted[index]
    }

    private static func waitForFile(_ url: URL, timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        repeat {
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        throw ProbeError.timeout(url.path)
    }

    private static func parseResult(_ value: String) throws -> (
        receivedAt: UInt64,
        visibleAfterReceivedNanoseconds: UInt64,
        baselineSHA256: String,
        visibleSHA256: String
    ) {
        let fields = Dictionary(uniqueKeysWithValues: value.split(whereSeparator: \Character.isNewline).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        })
        guard let received = fields["received_ns"].flatMap(UInt64.init),
              let receivedMonotonic = fields["received_monotonic_ns"].flatMap(UInt64.init),
              let visibleMonotonic = fields["visible_monotonic_ns"].flatMap(UInt64.init),
              visibleMonotonic >= receivedMonotonic,
              let baseline = fields["baseline_sha256"], baseline.count == 64,
              let changed = fields["visible_sha256"], changed.count == 64 else {
            throw ProbeError.invalidResult(value)
        }
        return (received, visibleMonotonic - receivedMonotonic, baseline, changed)
    }

    private static func probeScript(guestDirectory: String) -> String {
        """
        #!/bin/bash
        set -euo pipefail
        d='\(guestDirectory)'
        baseline="$d/baseline.png"
        visible="$d/visible.png"
        result="$d/result.txt"
        rm -f -- "$d/ready" "$result" "$baseline" "$visible"
        clear
        printf '%s\n' 'RiftVM input latency probe ready'
        sleep 0.10
        grim -t png "$baseline"
        touch "$d/ready"
        IFS= read -rsn1 key
        received_monotonic_ns=$(python -c 'import time; print(time.monotonic_ns())')
        received_ns=$(date +%s%N)
        clear
        printf '\033[48;2;255;64;16m\033[38;2;255;255;255m'
        for _ in $(seq 1 18); do printf '%s\n' ' RIFTVM INPUT VISIBLE RIFTVM INPUT VISIBLE RIFTVM INPUT VISIBLE '; done
        printf '\033[0m'
        sleep 0.02
        grim -t png "$visible"
        visible_monotonic_ns=$(python -c 'import time; print(time.monotonic_ns())')
        visible_ns=$(date +%s%N)
        {
          printf 'received_ns=%s\n' "$received_ns"
          printf 'visible_ns=%s\n' "$visible_ns"
          printf 'received_monotonic_ns=%s\n' "$received_monotonic_ns"
          printf 'visible_monotonic_ns=%s\n' "$visible_monotonic_ns"
          printf 'baseline_sha256=%s\n' "$(sha256sum "$baseline" | cut -d' ' -f1)"
          printf 'visible_sha256=%s\n' "$(sha256sum "$visible" | cut -d' ' -f1)"
        } > "$result.part"
        mv -f -- "$result.part" "$result"
        clear
        """
    }

    private static func unixNanoseconds() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
    }

    private static func signedDifference(_ lhs: UInt64, _ rhs: UInt64) -> Int64 {
        lhs >= rhs ? Int64(clamping: lhs - rhs) : -Int64(clamping: rhs - lhs)
    }

    private static func adding(_ value: UInt64, _ offset: Int64) -> UInt64 {
        if offset >= 0 { return value &+ UInt64(offset) }
        return value &- UInt64(-offset)
    }

    private static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        Double(signedDifference(end, start)) / 1_000_000
    }
}

private extension JSONEncoder {
    static var acceptance: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
