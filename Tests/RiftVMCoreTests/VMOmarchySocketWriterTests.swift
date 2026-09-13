import XCTest
import Darwin
@testable import RiftVMCore

final class VMOmarchySocketWriterTests: XCTestCase {
    private func sockets() throws -> [Int32] {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(.EIO)
        }
        var size: Int32 = 4096
        setsockopt(descriptors[0], SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        return descriptors
    }

    func testBackpressurePreservesWholeFramesAndOrder() throws {
        let pair = try sockets()
        defer { close(pair[0]); close(pair[1]) }
        let writer = try VMOmarchySocketWriter(descriptor: pair[0])
        let first = Data(repeating: 0x41, count: 256 * 1024)
        let second = Data(repeating: 0x42, count: 256 * 1024)
        let sent = expectation(description: "both frames written")
        sent.expectedFulfillmentCount = 2
        // Enqueue before starting a reader: a synchronous implementation would
        // block here because the first frame exceeds the socket send buffer.
        writer.enqueue(first) { error in XCTAssertNil(error); sent.fulfill() }
        writer.enqueue(second) { error in XCTAssertNil(error); sent.fulfill() }
        var received = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        while received.count < first.count + second.count {
            var event = pollfd(fd: pair[1], events: Int16(POLLIN), revents: 0)
            guard poll(&event, 1, 2000) > 0 else { XCTFail("reader timed out"); break }
            let count = read(pair[1], &bytes, bytes.count)
            guard count > 0 else { XCTFail("unexpected EOF"); break }
            received.append(contentsOf: bytes.prefix(count))
        }
        wait(for: [sent], timeout: 2)
        XCTAssertEqual(received, first + second)
    }

    func testCancellationStopsBlockedAndQueuedFrames() throws {
        let pair = try sockets()
        defer { close(pair[0]); close(pair[1]) }
        let writer = try VMOmarchySocketWriter(descriptor: pair[0])
        let cancelled = expectation(description: "blocked and queued sends cancelled")
        cancelled.expectedFulfillmentCount = 2
        writer.enqueue(Data(repeating: 1, count: 1024 * 1024)) { error in
            XCTAssertNotNil(error); cancelled.fulfill()
        }
        writer.enqueue(Data([2])) { error in
            XCTAssertNotNil(error); cancelled.fulfill()
        }
        // Wait until the writer has filled at least part of the send buffer.
        var readable = pollfd(fd: pair[1], events: Int16(POLLIN), revents: 0)
        XCTAssertGreaterThan(poll(&readable, 1, 2000), 0)
        writer.cancel()
        wait(for: [cancelled], timeout: 2)
    }

    func testPeerClosureFailsWithoutSIGPIPE() throws {
        let pair = try sockets()
        defer { close(pair[0]) }
        let writer = try VMOmarchySocketWriter(descriptor: pair[0])
        close(pair[1])
        let failed = expectation(description: "closed peer")
        writer.enqueue(Data([1])) { error in XCTAssertNotNil(error); failed.fulfill() }
        wait(for: [failed], timeout: 2)
    }

    func testOriginalDescriptorReuseCannotRedirectQueuedWrites() throws {
        let old = try sockets()
        let writer = try VMOmarchySocketWriter(descriptor: old[0])
        let new = try sockets()
        defer { close(old[0]); close(old[1]); close(new[0]); close(new[1]) }
        // Force reuse rather than depending on the OS allocating the same fd.
        XCTAssertEqual(dup2(new[0], old[0]), old[0])
        let sent = expectation(description: "original connection receives frame")
        writer.enqueue(Data([0x42])) { error in XCTAssertNil(error); sent.fulfill() }
        wait(for: [sent], timeout: 2)
        var event = pollfd(fd: old[1], events: Int16(POLLIN), revents: 0)
        XCTAssertGreaterThan(poll(&event, 1, 1000), 0)
        var byte: UInt8 = 0
        XCTAssertEqual(read(old[1], &byte, 1), 1)
        XCTAssertEqual(byte, 0x42)
        var unexpected = pollfd(fd: new[1], events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&unexpected, 1, 0), 0)
    }
}
