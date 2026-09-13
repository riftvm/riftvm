import Foundation

@main
struct RendererQueueBenchmark {
    static func main() {
        let count = 20_000
        var samples: [Double] = []
        for _ in 0..<5 {
            let executor = RendererExecutor()
            let ready = DispatchSemaphore(value: 0)
            let begin = DispatchSemaphore(value: 0)
            executor.async { ready.signal(); begin.wait() }
            ready.wait()
            var checksum = 0
            for index in 0..<count { executor.async { checksum += index } }
            let start = DispatchTime.now().uptimeNanoseconds
            begin.signal()
            executor.stop()
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            precondition(checksum == count * (count - 1) / 2)
            samples.append(milliseconds)
        }
        let label = CommandLine.arguments.dropFirst().first ?? "candidate"
        print("\(label): jobs=\(count) samples_ms=\(samples) median_ms=\(samples.sorted()[2])")
    }
}
