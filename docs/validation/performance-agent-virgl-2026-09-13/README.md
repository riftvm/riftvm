# Agent I/O and VirGL context synchronization performance

Branch: `perf/agent-io-virgl-sync`. Local validation on September 13, 2026,
arm64 MacBook Pro, macOS 27.0 (26A428), Xcode 27.0 (27A266a).

## Changes

- Authenticated Omarchy Agent frames are queued to a dedicated serial writer.
  Socket backpressure no longer blocks the main actor. Sequence allocation and
  encoding remain on the main actor, and transmission preserves their order.
- The writer owns a duplicated descriptor. Connection shutdown cancels pending
  sends; an old connection cannot write into a recycled descriptor. Nonblocking
  writes wait for readiness, have a 30-second deadline including queue time,
  and fail the stream after a partial-frame error. Cancellation is checked at
  least every 100 ms during backpressure; normal readiness wakes immediately.
- The reader retains the duplicated descriptor and waits for readability rather
  than sleeping for 10 ms after EAGAIN. The initial welcome still completes on
  the I/O thread before authenticated frames may be queued.
- A two-level bitset indexes contexts with pending EGL sync objects. Presentation
  skips empty groups instead of examining all 65,536 pointer slots. Ascending
  context order, sync replacement, and failure/retry behavior are preserved.
  The index costs 8,320 bytes. Cleanup now retires remaining tracked EGL syncs.

The 60 Hz presentation policy, Guest continuous rendering workaround, per-input
ACK ordering, 2 ms key-transition spacing, renderer polling cadence, and GL
flush policy are unchanged.

## Measurement

Run `scripts/test-virgl-context-sync.sh` from the repository root. It runs the
real bridge lifecycle with stubbed EGL/renderer callbacks under AddressSanitizer
and UndefinedBehaviorSanitizer, then an optimized standalone CPU microbenchmark.
The raw output is in [context-results.txt](context-results.txt).

Each benchmark case executes 20,000 iterations. The old loop visits all 65,536
slots; the new loop inserts and drains the active-context index. Both clear the
same populated pointer slots and accumulate a checksum. Sparse IDs cover the
index boundaries, including ID 65,535. GPU work, locks, frame scheduling, and
presentation are not included. This is one local sample, not an end-to-end A/B.

| Active contexts | Old traversal | Indexed traversal |
| ---: | ---: | ---: |
| 0 | 18.066 µs | 0.006 µs |
| 1 | 17.810 µs | 0.012 µs |
| 4 | 17.851 µs | 0.041 µs |
| 64 | 18.792 µs | 0.512 µs |

At four active contexts this removes about 0.018 ms of CPU work per traversal.
Even at 60 traversals per second that is only about 1.1 ms of CPU time per
second; the large local speed ratio must not be presented as a VM FPS increase.

The socket tests establish that enqueue returns while the send buffer is full,
then verify complete frame delivery in order when a reader drains the buffer.
They also cover blocked/queued cancellation, peer closure without SIGPIPE, and
forced original-descriptor reuse through dup2. They do not measure Guest input
latency or prove actual VZ socket behavior.

## Validation

- Seven Core tests passed: four socket-writer tests and three connection
  suspension tests. The final descriptor-reuse test forces reuse explicitly.
- All 26 VirGL runtime tests passed.
- C index tests passed for empty/full sets, boundaries, duplicate insertion,
  removal, and reuse. Real bridge callback tests passed for replacement,
  destroy/reuse, failed wait/retry, and cleanup with ASan/UBSan.
- Unsigned Release app build passed.
- Five Xcode integration tests passed with zero skips: Custom VirGL login/ready
  input policy, down/repeat/up, held-key release, Command modifier ownership,
  and completed pause/resume transitions.

Reproduction commands:

```sh
scripts/test-virgl-context-sync.sh
swift test --filter 'VMOmarchySocketWriterTests|VMOmarchyConnectionSuspensionGateTests'
swift test --package-path Experiments/VZVirtioGPUPrototype
xcodebuild -quiet -project RiftVM/RiftVM.xcodeproj -scheme RiftVM \
  -configuration Release -derivedDataPath /tmp/riftvm-perf-build \
  CODE_SIGNING_ALLOWED=NO build
```

The local sandbox required `--disable-sandbox` and a temporary
`CLANG_MODULE_CACHE_PATH` for SwiftPM; Xcode used its normal build cache.

No new real-VM graphics, input-latency, idle-power, or resize benchmark was run.
Before release, validate VZ socket initialization/authentication and clipboard
round trips, then compare the same disposable VM on both revisions for input
ACK P95, presentation P95, and idle CPU using the repository's existing probes.
No merge, push, or published release was performed.

Subsequent real-VM validation and further optimizations on the same branch are
recorded in the [second-stage report](../performance-display-queue-2026-09-13/README.md).
The no-real-VM limitation above describes this first stage only.
