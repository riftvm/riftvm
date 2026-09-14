# Watcher idle query validation

Candidate image source: `2e181a47a0640fbdfd7b5ce72641d388bec068f0`.

A disposable 4-CPU/8-GiB Guest with the previously qualified Agent received the
candidate watcher. A 65-second real-compositor trace included an injected wrong
1280x720 mode after 15 seconds. The periodic audit restored the DRM preferred
1024x656 mode; a later query confirmed it. The service restarted successfully,
VFR stayed enabled and the final blue terminal frame was visibly observed.
`live-repair.json` records the component digest and sanitized measurements.

Tracing adds overhead; these are IPC counts and correctness evidence, not a CPU
or energy benchmark. The earlier deterministic test covers 60 stable ticks:
7 queries including startup instead of 61. ARM64 source CI passed. Eight updater
fault-injection tests and the Host factory-profile tests passed locally.

The local full image suite requires GNU sed; its complete run is covered by
ARM64 Linux CI. The first sandboxed Swift invocation could not access compiler
caches; the normal permitted invocation passed.

A subsequent cold start passed file import, text/PNG clipboard and dynamic
1024x656-to-880x528 resize. `multi-display-focus.json` records six successful
size/focus cycles across two physical displays. The timestamps in `cold-start.json`
identify this run. VFR was still true after the cycles; keyboard output and a final
blue terminal frame were observed. The tiled test terminal was small after the
six cycles, so a separate terminal was used to hold the final frame for inspection.
The disposable Guest was then stopped. No personal Guest was started or modified.
