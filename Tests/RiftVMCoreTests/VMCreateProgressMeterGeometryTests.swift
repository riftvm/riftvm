import XCTest
@testable import RiftVMCore

final class VMCreateProgressMeterGeometryTests: XCTestCase {
    func testUnlitBlocksStayAtTheMinimumHeight() {
        for progress in [0.0, 0.25, 0.5, 0.99] {
            let lit = VMCreateProgressMeterGeometry.litBars(progress: progress)
            for index in 0..<VMCreateProgressMeterGeometry.barCount {
                for time in [0.0, 0.7, 3.3] {
                    let height = VMCreateProgressMeterGeometry.height(index: index, progress: progress, time: time)
                    if Double(index) >= lit {
                        XCTAssertEqual(height, VMCreateProgressMeterGeometry.minimumHeight, accuracy: 0.001,
                                       "unlit block \(index) at progress \(progress) moved")
                    } else {
                        XCTAssertGreaterThanOrEqual(height, VMCreateProgressMeterGeometry.minimumHeight)
                        XCTAssertLessThanOrEqual(height, VMCreateProgressMeterGeometry.maximumHeight)
                    }
                }
            }
        }
    }

    func testNoProgressLeavesEveryBlockUnlit() {
        for index in 0..<VMCreateProgressMeterGeometry.barCount {
            XCTAssertFalse(VMCreateProgressMeterGeometry.isLit(index: index, progress: 0))
        }
    }

    func testFinishedProgressLightsEveryBlock() {
        for index in 0..<VMCreateProgressMeterGeometry.barCount {
            XCTAssertTrue(VMCreateProgressMeterGeometry.isLit(index: index, progress: 1))
        }
    }

    func testFrontierBlockBouncesWiderThanSettledBlocks() {
        let progress = 0.6
        let frontier = Int(VMCreateProgressMeterGeometry.litBars(progress: progress))
        func range(_ index: Int) -> Double {
            let samples = stride(from: 0.0, through: 2.0, by: 0.05).map {
                VMCreateProgressMeterGeometry.height(index: index, progress: progress, time: $0)
            }
            return (samples.max() ?? 0) - (samples.min() ?? 0)
        }
        XCTAssertGreaterThan(range(frontier), range(0), "the frontier block must carry the largest bounce")
    }

    func testHeightsAreDeterministicForTheSameClock() {
        for index in [3, 9, 17] {
            let first = VMCreateProgressMeterGeometry.height(index: index, progress: 0.42, time: 12.5)
            let second = VMCreateProgressMeterGeometry.height(index: index, progress: 0.42, time: 12.5)
            XCTAssertEqual(first, second)
        }
    }

    func testSettledRowIsUniformAndTallerThanUnlitBlocks() {
        let settled = VMCreateProgressMeterGeometry.settledHeight(index: 5, progress: 1)
        XCTAssertGreaterThan(settled, VMCreateProgressMeterGeometry.minimumHeight)
        XCTAssertLessThanOrEqual(settled, VMCreateProgressMeterGeometry.maximumHeight)
        XCTAssertEqual(settled, VMCreateProgressMeterGeometry.settledHeight(index: 20, progress: 1), accuracy: 0.001)
        XCTAssertEqual(VMCreateProgressMeterGeometry.settledHeight(index: 20, progress: 0.1),
                       VMCreateProgressMeterGeometry.minimumHeight)
    }

    func testReadyRowIsTallerThanADownloadedBlockAndStillBounded() {
        let ready = VMCreateProgressMeterGeometry.restingHeight(index: 4, progress: 1, isReady: true)
        let settled = VMCreateProgressMeterGeometry.restingHeight(index: 4, progress: 1, isReady: false)
        XCTAssertGreaterThan(ready, settled, "the finished row must read as full, not stopped")
        XCTAssertLessThanOrEqual(ready, VMCreateProgressMeterGeometry.maximumHeight)
        XCTAssertEqual(ready, VMCreateProgressMeterGeometry.restingHeight(index: 25, progress: 1, isReady: true),
                       accuracy: 0.001)
        XCTAssertEqual(VMCreateProgressMeterGeometry.restingHeight(index: 25, progress: 0.2, isReady: true),
                       VMCreateProgressMeterGeometry.minimumHeight)
    }
}
