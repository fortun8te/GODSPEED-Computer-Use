# Godspeed workflow reliability

Current implementation covers cursor feedback, background typing, per-client browser state, text-first reads, and private runtime measurements.

## Upstream review

- [#113](https://github.com/iFurySt/open-computer-use/pull/113) adds nonblocking animation upstream. Godspeed already had an async queue. Keep pulse ordering and avoid reintroducing the main-thread wait.
- [#137](https://github.com/iFurySt/open-computer-use/pull/137) informs the text-only default in the JavaScript API. Coordinate callers can request screenshots explicitly.
- [#159](https://github.com/iFurySt/open-computer-use/pull/159) documents an acknowledged AX text insertion that does nothing. Godspeed verifies the change when the field is readable. An uncertain write needs a fresh read before another attempt.
- [#177](https://github.com/iFurySt/open-computer-use/pull/177) Chrome AX initialization, [#182](https://github.com/iFurySt/open-computer-use/pull/182) disabled controls and [#183](https://github.com/iFurySt/open-computer-use/pull/183) stale indexes are already represented in the branch.
- [#114](https://github.com/iFurySt/open-computer-use/pull/114) changes virtual display layout restoration. This remains a separate adoption decision with a display fixture.

## Comparison

[Cua Driver](https://github.com/trycua/cua/blob/main/docs/content/docs/cua-driver/concepts/how-cua-driver-works.mdx) has explicit window targeting and input delivery modes. [Peekaboo](https://github.com/openclaw/Peekaboo) has semantic Mac actions and targeted captures. [agent-desktop](https://github.com/vercel-labs/agent-desktop) has a compact interactive snapshot mode. Codex native computer use is the comparison baseline for the same model and task.

Measure independent final-state pass rate, model input and output tokens, calls and elapsed time. Use identical fixtures and model settings with repeated alternating runs. Compare one worker with several distinct tabs and measure time to finish a fixed batch. Separate native UI contention, browser helper latency, and model decision time. For helper attribution, run the same tasks with helpers off, vision alone, decision alone, and both. Validate smaller models on the same held-out tasks. Publish paired results and workload limits.

## Open verification

- Native modal and file chooser coverage, including the CapCut import.
- Live Chrome separate-tab checks and timeout cleanup under load.
- Live cross-client throughput. The shared app agent now admits up to three independent browser reads with request-local settings. Native actions, browser writes and mixed batches still run alone. Compare parallel and sequential Chrome fixtures before claiming a throughput gain.
- A signed, notarized binary release and a fresh-machine install.
