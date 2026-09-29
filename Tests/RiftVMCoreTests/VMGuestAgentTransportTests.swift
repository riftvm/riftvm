import Darwin
import Foundation
import XCTest
@testable import RiftVMCore

/// The shared frame coders and the handshake write path.
final class VMGuestAgentTransportTests: XCTestCase {
    private let token = Data(repeating: 0x07, count: 32)
    private let machineID = "machine-transport-tests"

    // MARK: - Frame codec

    func testFrameBytesMatchAFreshlyConfiguredEncoder() throws {
        let authenticator = try VMGuestAgentAuthenticator(tokenData: token, machineID: machineID)
        let envelope = try authenticator.makeEnvelope(
            sessionID: "session/with+slashes",
            sequence: 42,
            requestID: "request-1",
            operation: .status,
            payload: Data("{\"z\":1,\"a\":\"caf\u{e9} / \u{1F600}\"}".utf8)
        )

        let frame = try VMGuestAgentFrameCodec.encode(envelope)

        let fresh = JSONEncoder()
        fresh.outputFormatting = [.sortedKeys]
        let expectedPayload = try fresh.encode(envelope)
        var length = UInt32(expectedPayload.count).bigEndian
        XCTAssertEqual(frame, Data(bytes: &length, count: 4) + expectedPayload)
        // Encoding is deterministic, so a repeated frame is identical.
        XCTAssertEqual(try VMGuestAgentFrameCodec.encode(envelope), frame)
        XCTAssertEqual(try VMGuestAgentFrameCodec.decode(VMGuestAgentEnvelope.self, from: frame), envelope)
    }

    func testReusedAuthenticatorSignsExactlyLikeANewOne() throws {
        let reused = try VMGuestAgentAuthenticator(tokenData: token, machineID: machineID)

        for sequence in UInt64(1) ... 5 {
            let fresh = try VMGuestAgentAuthenticator(tokenData: token, machineID: machineID)
            let payload = Data("payload-\(sequence)".utf8)
            let fromReused = try reused.makeEnvelope(
                sessionID: "session", sequence: sequence, requestID: "r\(sequence)",
                operation: .heartbeat, payload: payload
            )
            let fromFresh = try fresh.makeEnvelope(
                sessionID: "session", sequence: sequence, requestID: "r\(sequence)",
                operation: .heartbeat, payload: payload
            )

            XCTAssertEqual(fromReused, fromFresh)
            XCTAssertEqual(
                try VMGuestAgentFrameCodec.encode(fromReused),
                try VMGuestAgentFrameCodec.encode(fromFresh)
            )
        }
    }

    func testSharedCodecIsSafeAcrossThreads() throws {
        let authenticator = try VMGuestAgentAuthenticator(tokenData: token, machineID: machineID)
        let envelopes = try (UInt64(1) ... 64).map { sequence in
            try authenticator.makeEnvelope(
                sessionID: "session", sequence: sequence, requestID: "request-\(sequence)",
                operation: .status, payload: Data(repeating: UInt8(sequence), count: Int(sequence) * 37)
            )
        }
        let expected = try envelopes.map { try VMGuestAgentFrameCodec.encode($0) }
        let failures = FailureCounter()

        DispatchQueue.concurrentPerform(iterations: 512) { iteration in
            let index = iteration % envelopes.count
            guard let frame = try? VMGuestAgentFrameCodec.encode(envelopes[index]),
                  frame == expected[index],
                  let decoded = try? VMGuestAgentFrameCodec.decode(VMGuestAgentEnvelope.self, from: frame),
                  decoded == envelopes[index] else {
                failures.increment()
                return
            }
        }

        XCTAssertEqual(failures.count, 0)
    }

    // MARK: - Handshake write

    func testHandshakeWriteWaitsForSlowReaderAndDeliversEveryByte() throws {
        let pair = try sockets()
        defer { close(pair[0]); close(pair[1]) }
        let writer = try VMOmarchySocketWriter(descriptor: pair[0])
        // Far larger than the send buffer, so the write must wait for the peer.
        let frame = Data((0 ..< 512 * 1024).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let written = expectation(description: "handshake written")
        DispatchQueue.global().async {
            do {
                try writer.writeHandshake(frame)
            } catch {
                XCTFail("\(error)")
            }
            written.fulfill()
        }

        var received = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        while received.count < frame.count {
            var event = pollfd(fd: pair[1], events: Int16(POLLIN), revents: 0)
            guard poll(&event, 1, 2000) > 0 else { XCTFail("reader timed out"); break }
            let count = read(pair[1], &bytes, bytes.count)
            guard count > 0 else { XCTFail("unexpected EOF"); break }
            received.append(contentsOf: bytes.prefix(count))
        }

        wait(for: [written], timeout: 2)
        XCTAssertEqual(received, frame)
    }

    func testBlockedWriteStopsAtItsDeadline() throws {
        let pair = try sockets()
        defer { close(pair[0]); close(pair[1]) }
        let flags = fcntl(pair[0], F_GETFL)
        XCTAssertEqual(fcntl(pair[0], F_SETFL, flags | O_NONBLOCK), 0)
        let started = DispatchTime.now().uptimeNanoseconds

        // Nobody reads, so the write can never finish.
        XCTAssertThrowsError(try VMOmarchySocketWriter.writeAll(
            Data(repeating: 1, count: 1024 * 1024),
            to: pair[0],
            deadline: started + 300_000_000,
            isCancelled: { false }
        )) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .ETIMEDOUT, "\(error)")
        }

        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        XCTAssertGreaterThanOrEqual(elapsed, 300_000_000)
        XCTAssertLessThan(elapsed, 2_000_000_000)
    }

    func testCancellationStopsBlockedHandshakeAndPoisonsTheWriter() throws {
        let pair = try sockets()
        defer { close(pair[0]); close(pair[1]) }
        let writer = try VMOmarchySocketWriter(descriptor: pair[0])
        let stopped = expectation(description: "handshake stopped")
        DispatchQueue.global().async {
            do {
                try writer.writeHandshake(Data(repeating: 1, count: 1024 * 1024))
                XCTFail("Expected the blocked handshake to be cancelled")
            } catch {
                XCTAssertTrue(error is CancellationError, "\(error)")
            }
            stopped.fulfill()
        }
        var readable = pollfd(fd: pair[1], events: Int16(POLLIN), revents: 0)
        XCTAssertGreaterThan(poll(&readable, 1, 2000), 0)

        writer.cancel()

        wait(for: [stopped], timeout: 2)
        let rejected = expectation(description: "later frame rejected")
        writer.enqueue(Data([2])) { error in
            XCTAssertNotNil(error)
            rejected.fulfill()
        }
        wait(for: [rejected], timeout: 2)
    }

    func testFailedHandshakePoisonsTheWriter() throws {
        let pair = try sockets()
        defer { close(pair[0]) }
        let writer = try VMOmarchySocketWriter(descriptor: pair[0])
        close(pair[1])

        XCTAssertThrowsError(try writer.writeHandshake(Data([1])))

        let rejected = expectation(description: "later frame rejected")
        writer.enqueue(Data([2])) { error in
            XCTAssertTrue(error is CancellationError, "\(String(describing: error))")
            rejected.fulfill()
        }
        wait(for: [rejected], timeout: 2)
    }

    func testEmptyWriteSucceedsImmediately() throws {
        let pair = try sockets()
        defer { close(pair[0]); close(pair[1]) }
        let writer = try VMOmarchySocketWriter(descriptor: pair[0])

        XCTAssertNoThrow(try writer.writeHandshake(Data()))
    }

    // MARK: - Helpers

    private func sockets() throws -> [Int32] {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(.EIO)
        }
        var size: Int32 = 4096
        setsockopt(descriptors[0], SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        return descriptors
    }

    private final class FailureCounter: @unchecked Sendable {
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
}
