import XCTest
@testable import RiftVMCore

final class VMGraphicsTimingSummaryTests: XCTestCase {
    func testEmptyAndSingleTimingWindow() {
        let empty = VMGraphicsTimingSummary(durations: [])
        XCTAssertEqual(empty.averageMilliseconds, 0)
        XCTAssertEqual(empty.p95Milliseconds, 0)
        XCTAssertEqual(empty.maximumMilliseconds, 0)
        let one = VMGraphicsTimingSummary(durations: [0.017])
        XCTAssertEqual(one.averageMilliseconds, 17, accuracy: 0.000001)
        XCTAssertEqual(one.p95Milliseconds, 17, accuracy: 0.000001)
    }

    func testP95KeepsDrawableStallVisibleWithoutConfusingItWithAverage() {
        let timing = VMGraphicsTimingSummary(durations: Array(repeating: 0.001, count: 18) + [0.020, 0.050])
        XCTAssertEqual(timing.averageMilliseconds, 4.4, accuracy: 0.000001)
        XCTAssertEqual(timing.p95Milliseconds, 20, accuracy: 0.000001)
        XCTAssertEqual(timing.maximumMilliseconds, 50, accuracy: 0.000001)
    }
}

extension VMGraphicsTimingSummaryTests {
    @MainActor
    func testBlockedDrawableAcquisitionLeavesMainActorResponsive() async {
        let acquirer = VMGraphicsDrawableAcquirer()
        let acquiring = expectation(description: "worker started")
        let finished = expectation(description: "main actor receives drawable")
        let heartbeat = expectation(description: "main actor remains responsive")
        let release = DispatchSemaphore(value: 0)
        acquirer.acquire({
            XCTAssertFalse(Thread.isMainThread)
            acquiring.fulfill()
            _ = release.wait(timeout: .now() + 2)
            return 42
        }) { value, duration in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(value, 42)
            XCTAssertGreaterThan(duration, 0)
            finished.fulfill()
        }
        await fulfillment(of: [acquiring], timeout: 1)
        DispatchQueue.main.async { heartbeat.fulfill() }
        await fulfillment(of: [heartbeat], timeout: 1)
        release.signal()
        await fulfillment(of: [finished], timeout: 1)
    }

    @MainActor
    func testNilDrawableStillReportsAcquisitionDuration() async {
        let acquirer = VMGraphicsDrawableAcquirer()
        let finished = expectation(description: "nil acquisition")
        acquirer.acquire({ Optional<Int>.none }) { value, duration in
            XCTAssertNil(value)
            XCTAssertGreaterThanOrEqual(duration, 0)
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 1)
    }
}
