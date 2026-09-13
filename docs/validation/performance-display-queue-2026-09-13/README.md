# Display, command-buffer, and renderer queue performance

Local performance branch: `perf/agent-io-virgl-sync`, based on
`4df32a12c802bcc1a9af36d72f1fc1c840c52409`. Validation was performed
from the working tree before the PR commit. No app replacement or release
was performed.

## Result

The branch now stops Host presentation while the view is hidden, detached,
minimized, or fully occluded. It retains the latest Guest scanout and presents
it when the view becomes visible. A visibility generation discards stale
acquisition/render completions after hide/show or scanout invalidation. At most
one acquisition/render operation remains in flight. Layer geometry is only set
when its actual frame, scale, or drawable size changes.

The new timings exposed a larger issue: `nextDrawable()` spent roughly a display
interval waiting on AppKit's main thread, while the old render-only timing
reported fractions of a millisecond. [The diagnostic discovery sample](drawable-wait-discovery.txt)
records this gap. Acquisition now runs on a dedicated queue; lifecycle checks
and presentation completion return to the main actor. The wait still exists as
normal display backpressure, but it no longer blocks input/event processing on
the main actor. A blocking-acquisition test verifies main-actor responsiveness.

VirGL submission borrows the validated command range from the original request.
It no longer extracts a second `Data` or requests mutable CoW storage. An
unaligned request is copied into aligned storage because virgl requires 4-byte
alignment. The pinned source's `virgl_renderer_submit_cmd` forwards synchronously
to `virgl_context.submit_cmd(const void *)` / `vrend_decode_ctx_submit_cmd`; the
bridge preserves its historical dynamic ABI while exposing const input to Swift.

The renderer queue clears consumed closure captures immediately and compacts
in batches instead of shifting the remaining array for every job. Repeated
`setPollingEnabled(true)` calls no longer signal the condition unnecessarily.
The 1 ms pending-fence poll cadence is retained: increasing its interval would
trade CPU wakeups for additional completion latency. Guest continuous rendering,
the 60 Hz timer policy when visible, GL flushes, and input ACK/2 ms spacing remain
unchanged.

## Measurements

Host: arm64 MacBook Pro, macOS 27.0 (26A428), Xcode 27.0 (27A266a).
The disposable Omarchy VM has 4 vCPUs and 8 GiB RAM and was created from the
existing local factory image. The personal Omarchy VM was not started.

### Queue stress benchmark

`./scripts/benchmark-renderer-queue.sh 4df32a12c802bcc1a9af36d72f1fc1c840c52409`
compiles both implementations with `swiftc -O` before measuring. A blocked first
job lets 20,000 jobs accumulate; measurement starts when they are released and
ends after stop drains the queue. Each benchmark sample checks its final sum;
separate tests verify ordering. Five samples are retained in
[queue-benchmark.txt](queue-benchmark.txt).

| Implementation | Median drain time |
| --- | ---: |
| Base revision | 50.736 ms |
| Performance branch | 1.628 ms |

This is approximately 31× faster for that deliberately large backlog. It is not
a desktop FPS or whole-VM speed ratio, and normal queues may be much shorter.

### Real VM presentation and visibility

The signed local acceptance app was built at
`/tmp/riftvm-perf2-worker/RiftVM Acceptance.app`. Graphic diagnostics/readback
were disabled during the following captures. Builds and test suites had finished
before capture. Each sample lasts 30 seconds, with the same running desktop and
window geometry; no terminal workload runs during these samples.

An initial restore encountered the Guest's normal idle animation. Escape
immediately returned to the desktop. To avoid comparing different Guest loads,
the three reported samples were then repeated before idle animation could start;
the restored desktop was visually checked without another key press.

| Metric | Visible | Minimized | Restored |
| --- | ---: | ---: | ---: |
| Host average CPU | 17.1% | 8.4% | 12.2% |
| Host average RSS | 498.6 MiB | 506.2 MiB | 508.4 MiB |
| Presentation windows logged | 6 | 0 | 6 |
| Average FPS | 60.0 | No presentation windows | 60.0 |
| Drawable acquisition average | 9.60 ms | Unavailable | 8.00 ms |
| Full CPU frame average | 10.15 ms | Unavailable | 8.26 ms |
| Worst-window full-frame P95 | 16.26 ms | Unavailable | 16.45 ms |
| Full-frame maximum | 17.12 ms | Unavailable | 20.19 ms |
| Drawable misses / render failures | 0 / 0 | No presentation windows | 0 / 0 |

Raw captures: [visible](visible.txt), [minimized](minimized.txt),
[restored](restored.txt). Both visible captures pass
`scripts/verify-virgl-performance.sh`, including the extended frame timings.
The hidden sample intentionally has no frame windows, so the visible-frame gate
is not applicable to it. The VM remained running while minimized.

These are visibility-state comparisons within the candidate, not a controlled
old-binary/new-binary whole-VM A/B. CPU varies even between the two visible
samples. Do not interpret the difference as a fixed power saving, battery-life
improvement, or universal speedup. No new complex-3D benchmark was run.

## Correctness and regression coverage

[Test summary](test-summary.json):

- Core: 404 tests, 403 passed, one skipped because the opt-in
  `RIFTVM_REAL_LOW_SPACE_VOLUME` fixture is not configured.
- CLI: 12 passed.
- VirGL runtime: 30 passed, including aligned borrowing, unaligned fallback,
  invalid ranges, 10,000-job ordering/compaction, capture release, thread affinity,
  polling, and stop/drain behavior.
- Omarchy Xcode integration: 66 passed, zero skipped. New tests cover occlusion,
  latest-scanout restoration, old completion generation invalidation, minimize,
  detach, hidden views, invalidated scanout, and stopped-view timer suppression.
- C regression tests pass, including real bridge lifecycle with stubbed EGL
  callbacks under AddressSanitizer and UndefinedBehaviorSanitizer.
- Timing parser/gate and capture preflight tests pass. They cover legacy logs,
  complete extended timing, mixed/incomplete logs, acquisition stalls, and
  expected display pacing without treating render-only timing as full timing.
- The final production Release builds and passes the executable-acceptance-code
  isolation gate. The separately signed acceptance build is explicitly excluded
  from production distribution.

Full Core tests initially failed under the execution sandbox because disk space
queries, DiskManagement, and local port probes were restricted. They were rerun
with normal local permissions and passed as above; no assertions were weakened.

Real Guest validation on the final asynchronous-acquisition build:

- Boot/login, authenticated Agent connection, and correct rendered desktop.
- Bidirectional shared-folder transfer and file import; bidirectional text and
  PNG clipboard round trips.
- Dynamic Guest resolution round trip.
- Six migration/resize/focus checks across 60 Hz DELL S2722QC and 120 Hz DELL
  S2725QC displays: [final report](multi-display-final.json).
- Minimize and restore, followed by healthy 60 FPS capture.
- Pause/resume, reauthentication, immediate Command-Return terminal opening,
  and typed `printf perf-resume-ok > /mnt/riftvm-shared/perf-resume.txt` without
  an extra focus click. The exact returned contents are retained in
  [resume-input-result.txt](resume-input-result.txt).

Earlier Agent/socket and active-context measurements are in the
[first-stage report](../performance-agent-virgl-2026-09-13/README.md).
Temporary VM artifacts remain under `/private/tmp/riftvm-perf2-acceptance.riftvm`;
the test VM is stopped after validation. No personal VM data was modified.
