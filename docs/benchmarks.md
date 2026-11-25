# Benchmarks

For bounded local parameter search with matched controls, explicit measurement coverage and held-out qualification, see [Local evaluation and hill climbing](local-evaluation.md). The runner produces an evaluated recommendation; it does not apply settings or change code automatically.

## Release checks

These runs measure the UTF-8 text passed back to the agent. Input token counts depend on the host model and how it serializes tool results.

| Synthetic window | Earlier reply | Current reply | Text reduction |
| --- | ---: | ---: | ---: |
| One changed control in a small window | 184 B | 71 B | 61% |
| 80 controls after a verified batch, full versus compact | 1,959 B | 105 B | 95% |

Run `swift test --filter CompactVerifiedReplyTests` to reproduce the reply checks. The first case selects the smaller of the state and its diff. The second uses `compact: true` and an explicit passing check. A later read still returns information the client has yet to see.

A local MCP handshake with all 19 tools advertised sent 673 bytes of startup instructions, down from 1,001. The serialized `tools/list` response fell from 24,054 to 22,575 bytes. Tool names and supported actions stayed available in both runs.

### Native fixture: compact versus separate reads

Three sets per mode on Godspeed 1.1.10. A disposable AppKit window checked each task outcome independently. Reply sizes are UTF-8 text bytes, and timing excludes fixture setup and grading.

| Measure | Separate read + batch | Read inside compact batch |
| --- | ---: | ---: |
| Independently verified tasks | 11/12 | 12/12 |
| MCP calls per four-task set | 8 | 4 |
| Reply text per set | 5,757 B | 2,033 B |
| Median driver time | 2.77 s | 4.38 s |

```text
Reply text per set, relative to the separate-read mode
Separate read       ████████████████████  5,757 B
Compact batch       ███████               2,033 B
```

Moving the read into the batch halved calls and cut response text by 65% in this fixture. The compact batch took longer at the median. [Fixture, commands and failure details](four-task-benchmark.md)

### Structured receipts and token accounting

Explicitly compact, verified batches can summarize per-step metadata. In an offline 40-step serialization test, the receipt metadata fell from 3,923 bytes to 128 bytes. Failed, incomplete, and uncertain steps retain detailed receipts. Byte counts describe the response payload. For actual model input, use the host's token usage receipts and separate total input, cache reads, cache writes, output, and reasoning where reported. Missing fields stay unreported.

The app agent used to check for idle exit every five seconds. It now arms a single deadline after the last client disconnects. `swift test --filter LifecycleTests` covers deadline changes as clients connect and disconnect. Whole-machine CPU, GPU and power measurements are pending.

### Desktop cursor checks

GitHub CI covers client names, cursor geometry and idle deadlines. Run the animation and window-follow checks on an unlocked Mac with Reduce Motion off. Enable Accessibility for the local test host to exercise the real button click. A second connected display lets the window-follow test cover both displays.

```sh
OPEN_COMPUTER_USE_CURSOR_NAMESPACE=godspeed-test swift test \
  --filter 'CursorHideTimerTests|CursorWindowFollowTests'
```

The 1.1.10 desktop run passed both the two-display follow check and the live click on a moved window. Those checks verify the cursor's behavior and placement.

In a separate 1.1.11 desktop fixture, 80 visual move requests from two clients produced two deliveries, one per client, down from 80. Both cursors landed at the latest target. Five cold runs measured median queue drain at 146 ms, versus 137 ms before. The range narrowed from 115–486 ms to 127–156 ms. This measures delivery of visual feedback. Input actions and display frame rate use separate measurements.

The deterministic handoff fixture fills two known empty fields in two actions and uses zero chooser requests. The separate ambiguous two-action fixture uses two chooser requests. `swift test --filter HandoffToolTests` verifies target binding, readback and escalation.

The configured local scorer selected the intended field on a separate two-option synthetic input. The first request took 2.48 seconds with the model unloaded. A repeat took 86 ms. Use matched held-out inputs before changing the model or its confidence threshold.

### Payload and cache accounting

| Offline comparison | Earlier | Current |
| --- | ---: | ---: |
| Structured metadata for a verified 40-step receipt | 3,923 B | 128 B |
| Tool catalog with the same tools and shorter shared descriptions | 30,364 B | 29,927 B |

Reproduce these byte counts with `GODSPEED_MEASURE_PAYLOADS=1 swift test --filter 'CompactVerifiedReplyTests|testLeanToolListingShortens'`. The receipt comparison uses explicit `compact: true`. Failed, incomplete, or uncertain steps still provide their individual receipts, and local logs retain the full details.

Use host usage receipts for input, cache reads, cache writes, output, and reasoning. Fresh input equals total input minus cache reads when both are reported. Reasoning is part of output. Missing counts remain unreported. Compare payload bytes separately because hosts may handle structured metadata differently.

### Queue delays, local routes, and incomplete work

Use a distinct `OPEN_COMPUTER_USE_RUN_ID` for each workload. After the run, summarize its metadata with the driver build recorded in the receipts:

```sh
python3 scripts/godspeed-trace-summary.py --run-id local-pass --driver-build BUILD_ID
```

The report counts top-level tool calls. A call can contain several batch actions or handoffs, so calls, helper requests, and independently checked tasks have different denominators.

| Report field | Population and meaning |
| --- | --- |
| `calls`, `tool_errors`, `error_flag_samples` | All matching tool calls; the error sample count shows how many explicitly report an error flag. A non-error reply does not establish task completion. |
| `delivery_states`, `delivery_state_samples` | Delivery evidence for calls. The sample count covers the four recognized states. Newly reported labels remain visible in the distribution. Acknowledged input is distinct from verified delivery. |
| `duration_samples`, `p50_duration_ms`, `p95_duration_ms` | Calls with valid execution durations, including execution failures. Admission timeouts have no execution and are excluded. |
| `admission_samples`, `p50_admission_ms`, `p95_admission_ms` | Calls with recorded admission time, including admission timeouts. |
| `queue_inclusive_samples`, `p50_queue_inclusive_ms`, `p95_queue_inclusive_ms` | Admission plus execution from each call with both samples; an admission timeout contributes admission alone. Missing admission is not assumed to be zero. These timings exclude client transport and later reply handling. |
| `helper_activity` | Recorded requests for `decide`, `choose`, `locate`, and the three `gsd1` roles. Image requests overlap those routes and are not added again. The per-call denominator is `telemetry_calls`; `calls_without_telemetry` remains separate. |
| `local_routing` | Handoff rule versus model actions, using only records containing both counters. The rule fraction divides rule actions by rule plus model actions. Visual search separately reports fast OCR, accurate OCR, vision proposals, and ambiguous text matches. |
| `done_checks`, `done_check_samples`, `batch_not_run_total` | Explicit batch checks and unexecuted steps. Weak evidence, skipped checks, unmet checks, and cancelled batches remain visible alongside verified checks. `batch_not_run_samples` identifies how many calls report the unexecuted-step count. |

Percentiles use nearest rank over their stated sample population. Queue-inclusive percentiles are calculated from paired samples, not by adding two independently calculated percentiles. Step-level delivery and failure distributions remain separate from top-level calls. Receipt labels are retained when a newer driver introduces a code, rather than omitted by an outdated list.

Older logs may omit telemetry even when a call made no helper request. That absence does not establish zero helper use. A report with no telemetry returns `null` for requests per telemetry-bearing call. `telemetry_totals` retains helper wall time, inference time, busy responses, and other recorded counters. Route labels do not identify whether a service ran locally or remotely; these traces also do not measure the host model's reasoning, token use, whole-machine CPU, or power. OCR targets are proposals, not verified completed actions.

The native regression workload has a separate completion measure:

```sh
python3 scripts/godspeed-regression-bench.py --repeat 20 --output regression.json
```

`fixture_pass_rate` measures the expected fixture effects. `completed_pass_rate` additionally requires that the whole workload finish without an error, including its final observation. Both divide by all reported runs. A run that produces the expected effects but loses its final observation can pass the fixture check and still fail completion. `aborted_runs` reports that distinction, and p95 wall time includes completed and aborted runs. These scripted fixture checks can expose regressions; a claim that Godspeed outperforms another driver still requires the matched task schedule below.

## Earlier runs

These recorded runs used GPT-6 Luna at low reasoning. A task checker scored the final result.

| Setup | Passed | Attempts |
| --- | ---: | ---: |
| Codex native | 2 | 10 |
| Godspeed | 1 | 16 |
| Godspeed with local helpers | 150 | 256 |

The sets included different tasks and repeated attempts. Three Godspeed-only runs also recorded native computer-use calls. Use these numbers as history. A matched comparison is needed to estimate the effect of the helpers or compare tools.

An isolated Chrome trial on November 18 verified three outcomes in 21 Godspeed calls and 109 seconds. Six calls returned errors that required a correction or a readback. It identified partial typing, ambiguous action delivery, and tab-close verification as targets for the next pass. The two attempted native comparison sessions both timed out during startup, so the trial produced no matched ranking.

## A fair comparison

Use the same model, prompt, app state, and checks. Alternate runs and report task success, wall time, tool calls, and input and output tokens. Keep standalone, parallel, and helper-assisted runs identifiable. [Verification plan](exec-plans/active/20261118-godspeed-workflow-reliability.md)

## Public macOS comparison

These results come from the [Scale CUA Driver Benchmark catalog](https://huggingface.co/spaces/earakely-scale/CuaDriverBench-AgentEnv/resolve/main/data/catalog.json). The rows below use the same macOS schedule and Claude Sonnet 5.5 model. The 40 background trials include simulated user activity. Driver names identify the tool in this evaluation, so the Codex Computer Use row refers to its driver under these conditions.

| Tool | Foreground | Background | Total |
| --- | ---: | ---: | ---: |
| Aside | 50/50 | 37/40 | 87/90 |
| CUA Driver | 43/50 | 23/40 | 66/90 |
| Codex Computer Use | 26/50 | 11/40 | 37/90 |
| Godspeed | — | — | No matched result |

```text
Background passes on the public macOS schedule (one full block = two passes)
Aside                ██████████████████▌  37 / 40
CUA Driver           ███████████▌         23 / 40
Codex Computer Use   █████▌               11 / 40
Godspeed                                 unmeasured
```

The public catalog also reports other model configurations. Keep each configuration separate when comparing tools. Godspeed’s four-task AppKit measurements above use a different fixture and measure driver output and timing. An equivalent Godspeed Scale score requires the full trial schedule and the same model, task states, GUI-only rules, and background disturbance checks.

Use `python3 scripts/godspeed-benchmark-compare.py --suite scale-bench-v2 baseline.jsonl candidate.jsonl` to compare normalized trial receipts offline. The script checks matching configurations and all 90 trial slots before scoring. It does not execute the benchmark. The separate `aside-internal` profile requires a predeclared schedule.

## Isolation options checked on 21 Nov 2026

Godspeed's hidden virtual display can separate target windows for a focused same-session smoke test. It does not isolate the login, files, Keychain, or other apps, so it is not a substitute for the Scale background-disturbance benchmark. The opt-in live check is [AgentDisplayLiveTests.swift](../packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/AgentDisplayLiveTests.swift); it must run in a dedicated or idle session because it creates and removes a system display.

The repeatable full-suite option is a macOS guest under Apple's Virtualization framework. CUA's Lume runner uses a 150 GB sparse disk; its simpler setup guide asks for at least 50 GB free plus restore-image space ([runner](https://github.com/trycua/cua/blob/main/libs/cua-driver/tests/runners/macos-lume/README.md), [VM setup](https://github.com/trycua/cua/blob/main/docs/content/docs/how-to-guides/driver/run-in-macos-lume-vm.mdx)). This Mac had 22 GiB free and no `lume` binary, so no VM or live desktop benchmark was started.
