# Local evaluation and bounded profile search

`scripts/godspeed-hillclimb.py` runs a finite, reproducible search over explicitly
allowed settings. It compares each candidate with controls on the same cases,
seeds and repeats, requires task/checker/safety success, and qualifies the frozen
winner on separate held-out cases. The output is a recommended profile and its
evidence. **Nothing is installed, deployed, or applied to Godspeed settings.**

The runner uses Python's standard library. It contains no network or model client;
the shipped demonstration only serializes synthetic data locally. A custom
adapter is an explicitly chosen local program. It can call a local model or a
native test fixture when that is the experiment being requested. The adapter is
not sandboxed, so review its behavior and run native experiments in a disposable
test session. The runner is not a background scheduler or a self-modifying agent.

## Try the portable demonstration

From the repository root:

```sh
python3 scripts/godspeed-hillclimb.py plan scripts/fixtures/hillclimb-demo.json
python3 scripts/godspeed-hillclimb.py run scripts/fixtures/hillclimb-demo.json --output /tmp/godspeed-hillclimb-demo-001
python3 -I -m unittest discover -s scripts/tests -p 'test_godspeed_hillclimb.py' -v
```

Use a new output directory for each run. `plan` validates the manifest and shows
the maximum trial count and wall-time budget without executing the adapter.
`run` creates a directory readable only by its owner. It refuses to reuse an
existing directory, so previous evidence cannot silently mix with a new run.

The demo compares a verbose encoding, an intentionally broken encoding that
drops later controls, and a compact encoding. It measures the actual UTF-8 bytes
and independently checks the decoded target, labels, roles and enabled states.
The broken encoding is rejected even though it is smaller. Training and held-out
cases include different node counts and Unicode labels. There are 54 actual
adapter invocations in the provided search: two candidate comparisons and one
held-out comparison, each with two cases, three repeats and three arms.

**This validates the runner and its protocol. It is not evidence of faster
Godspeed, better GUI task completion, lower model token use, or 9B model quality.**
The demo never starts Godspeed, a browser, an LLM or a user application. Its token
metrics are deliberately unmeasured. Its serialization time is reported but is
not a performance gate: this tiny Python fixture is too sensitive to timing noise
to qualify a latency claim.

## How a candidate earns a recommendation

The manifest declares a baseline profile, allowed values for each tunable
parameter, a training set, a held-out set, seeds, repeats, and hard search bounds.
Profile values are JSON scalars. A profile can select an implementation or harness
version through the adapter, as well as ordinary settings.

1. Generate deterministic one-parameter neighbours of the current incumbent.
   Skip profiles already evaluated. Stop at the candidate, round or wall-time
   limit; there is no open-ended generation or code modification.
2. For **each case, seed and repeat**, execute control, candidate, control in that
   order. Every arm gets the same input, seed and repeat number. Run at least three
   repeats; use six or more for noisy local model or latency experiments.
3. Require every scheduled run to complete, pass its independent checker and all
   required case checks, and report zero wrong targets, duplicate actions and user
   disturbances. A missing safety measurement fails the gate. An aborted run with
   correct final effects still fails completion.
4. Compute medians across repeats separately for each case/seed/arm. The objective
   is the equally weighted mean of the case/seed candidate-to-control ratios. It
   must improve by the configured minimum against **both** neighbouring controls.
   A separate per-case limit prevents a large win on one case from hiding a
   regression on another. Guardrail metrics have their own per-case limits.
5. Reject unstable comparisons when the two control medians differ by more than
   the permitted drift, for any objective or guardrail metric. A zero control
   followed by a positive value is an unbounded regression/drift, not an invented
   percentage. Two zeros mean no improvement.
6. Freeze the training winner. Evaluate it once on the held-out suite against the
   original baseline, using the same repeated, interleaved protocol and gates.
   If it fails, emit no recommendation. Do not use held-out feedback to choose a
   runner-up or continue the search in that run.
7. Check the fingerprints of the runner, adapter executable and declared artifacts
   again. A changed artifact blocks recommendation. A passing result produces a
   profile file for review; it does not apply it.

These are conservative deterministic gates, not a statistical confidence claim.
Per-repeat outliers remain in the ledger, although median performance scoring is
robust to them. Completion and safety gates still apply to **every repeat**. The
current runner does not estimate confidence intervals or tail latency; add these
as independent qualification checks before making production latency guarantees.

Held-out protection is procedural: a suite hash is recorded before search,
training decisions do not execute held-out cases, and a frozen candidate receives
one qualification attempt. The cases still exist on the same machine. Repeatedly
changing a manifest after reading failures leaks held-out information across
runs. Maintain an externally managed final qualification suite for release
claims, and do not reuse it as a tuning dataset.

## Manifest and reproducibility

Start with [the demo manifest](../scripts/fixtures/hillclimb-demo.json). All paths
in `artifacts`, and relative adapter arguments, are resolved from the manifest's
directory. `adapter` is an argv array, never a shell command. The runner records:

| Field | Purpose |
| --- | --- |
| `identity.suite_revision` | Fixed workload/checker revision. |
| `identity.host` | Host identity, OS, architecture, power/performance mode, and relevant runtime conditions. |
| `identity.model` | Model revision, quantization, tokenizer, inference engine, sampling and context configuration; `none` for no-model experiments. |
| `identity.harness_revision` | Pinned harness/build identity. Include clean-build provenance for release qualification. |
| `artifacts` | Files whose SHA-256 values must stay unchanged: adapter code, evaluated binaries, checker code, configuration and relevant source/version receipts. |
| `baseline` / `parameters` | Initial profile and explicitly permitted parameter values. |
| `train` / `holdout` | Disjoint case IDs, per-case inputs, and required independent checks. |
| `seeds` / `repeats` | Identical workload randomness and repeat counts for each arm. |
| `max_candidates` / `max_rounds` | Finite search bounds. Seen profiles are never revisited. |
| `timeout_seconds` / `max_total_seconds` | Per-adapter and evaluation/promotion wall-time limits, including initial and final artifact hashing. |
| `objective` | Lower-is-better metric, minimum improvement, permitted control drift, per-case regression and guardrails. |
| `context_limit_tokens` | Optional hard gate requiring measured peak live context on every arm. |
| `memory_limit_bytes` | Optional hard gate requiring measured peak memory on every arm. |

The manifest is copied into the evidence directory. Cases, seeds, profiles and
checks are covered by its SHA-256. The runner also fingerprints itself and the
resolved adapter executable, and records Python and platform versions. Declare
all relevant dependencies in `artifacts`; hashing the adapter alone does not pin
imported modules, model weights, remote services, external settings, or a driver
binary that the adapter launches. Build pinned candidates before evaluation and
include the resulting binaries and build provenance among the artifacts.

Environment conditions are not inferred from an arbitrary identity string. A
real adapter should check host/power/thermal/runtime conditions before and after
its workload and fail a required check if they changed. Keep the same tokenizer,
cache regime, generation budget and quality criteria across comparable arms, or
make the difference an explicit profile change. Initialize/warm the relevant
runtime consistently inside the adapter and state whether its timing includes
startup. Do not mix cold and warm measurements.

The runner serializes all trials within one process. It does **not** lock unrelated
experiments or jobs on the machine. Avoid running multiple searches against the
same local inference server or test desktop at once.

## Local adapter protocol

For each trial, the runner starts the configured command in the manifest's
directory and writes one JSON object to stdin:

```json
{
  "schema": 1,
  "profile": {"encoding": "compact"},
  "case": {
    "id": "resume-after-restart",
    "input": {"fixture": "disposable-recovery-case"},
    "checks": ["receipt_exact", "checkpoint_restored", "no_duplicate_effects"]
  },
  "seed": 17,
  "repeat": 0
}
```

Only the current case is passed, not the complete training/held-out suite. The
request deliberately does not identify whether it is a candidate, control or
held-out trial. The adapter must execute the profile and return exactly one JSON
object on stdout; send diagnostics to stderr:

```json
{
  "schema": 1,
  "case_id": "resume-after-restart",
  "completed": true,
  "checker_pass": true,
  "checks": {
    "receipt_exact": true,
    "checkpoint_restored": true,
    "no_duplicate_effects": true
  },
  "safety": {
    "wrong_targets": 0,
    "duplicate_actions": 0,
    "user_disturbances": 0
  },
  "metrics": {
    "duration_ms": 1250.5,
    "observation_bytes": 8000,
    "agent_calls": 3,
    "helper_calls": null,
    "input_tokens": null,
    "output_tokens": null,
    "reasoning_output_tokens": null,
    "peak_context_tokens": null
  },
  "token_source": null
}
```

The numbers above illustrate the schema; they are not measured Godspeed results.
The checker must inspect fixture receipts or independently verifiable outcomes,
not ask the candidate to grade itself. The runner validates the receipt and gates
its claims, but cannot establish that an adapter's checker is independent or
that a reported measurement is honest.

Required top-level fields are exactly those shown. Metric fields may be omitted
or `null` when unmeasured. Safety counters must be present; `null` blocks
qualification. Missing/false required checks, and any additionally reported false
check, block qualification. Boolean, negative, non-finite, fractional count,
duplicate-key, wrong-case and impossible token receipts are rejected. Fractional
`duration_ms` is allowed; count metrics are nonnegative integers.

The runner records its own `runner_wall_ms` separately from adapter-reported
`duration_ms`. The former includes process startup/protocol overhead; the latter
must have a documented workload timing scope. Neither is inferred from an LLM
response or from the length of a transcript.

### Measurements and coverage

Supported metrics are `duration_ms`, `observation_bytes`, `agent_calls`,
`helper_calls`, `peak_memory_bytes`, `input_tokens`, `output_tokens`,
`reasoning_output_tokens`, `cached_input_tokens`, `cache_write_input_tokens`,
`uncached_input_tokens`, and `peak_context_tokens`.

The objective and guardrails need complete measured coverage in every arm. The
report exposes expected, measured and fully paired counts for every metric,
including unmeasured optional metrics. An absent metric never becomes zero.
`cached_input_tokens` and `cache_write_input_tokens` are diagnostics, not
lower-is-better objectives. Use uncached input, duration or a workload-relevant
cost metric instead of treating fewer cache hits as an improvement.

Keep these measurements separate:

- `observation_bytes`: actual UTF-8 bytes of the observations delivered to the
  agent under the specified representation; do not treat these as model tokens.
- `agent_calls`: real outer-agent inference calls, not native tool invocations.
  A deterministic scripted native workload can report zero if no outer model ran.
- `helper_calls`: helper inference counts only when telemetry coverage is complete.
  No telemetry is an unknown count, not zero. Route and image counters may overlap.
- Model input/output/cache/reasoning tokens: actual host usage receipts or a
  correctly identified tokenizer applied to the relevant complete text. Never
  count streamed chunks or use a characters-per-token estimate as measured usage.
  `token_source` must identify the host fields/tokenizer when any token metric is
  present. Missing hidden reasoning usage remains unknown. Reasoning is a subset
  of output, cache reads cannot exceed total input, and uncached input must equal
  total input minus cached input. Cache writes require a measured input total and
  cannot exceed it; when cache reads are known, writes must also fit within total
  input minus cache reads. These are normalized counts: total input includes
  cache-read and cache-write tokens. Adapt providers that report these separately
  before emitting a receipt. Unknown cache reads/uncached input remain unknown.
- `peak_context_tokens`: actual peak live prompt plus retained history/tool
  observations under the target model's tokenizer. Cumulative billed input across
  turns is not peak context. A 16K/32K limit gate requires this measurement; it does
  not itself prove retrieval or recovery quality at that context size.
- `peak_memory_bytes`: measurement appropriate to the runtime, including GPU or
  unified-memory residency where applicable. The runner checks the reported
  limit after a trial; an adapter needing a live memory cap must enforce it while
  running. The runner does not provide a GPU memory watchdog.

## Connect real Godspeed evaluations

Existing tools remain separate and retain their original semantics:

| Existing evidence | Adapter use and limits |
| --- | --- |
| `godspeed-regression-bench.py` | Its native fixture grades tab changes, delayed controls, a moved window, relaunch and a dropped reply. Map `completed` to `error is None`, `checker_pass` to `fixture_pass`, and copy actual wrong-target/duplicate counts. A fixture pass with a workload error must fail completion. Host tokens and human disturbance are not measured by this script alone. |
| `godspeed-trace-summary.py` | Use its helper-route and timing coverage rules. Retain missing telemetry and missing host usage as unknown. Do not add overlapping helper/image counters. |
| `godspeed-benchmark-compare.py` | Keeps the stricter normalized, matched-arm reporting for the existing benchmark suites. A hillclimb recommendation is not a replacement for completing those schedules or an official competitor score. |
| AX semantic fixtures | Preserve exact control identity, labels, states, context and action evidence while measuring UTF-8 bytes. `AX_LOCAL_OBSERVATION_METRICS` from the native fixture can support a representation-specific adapter; its nullable model-token field must remain unknown. |

For a native setting or harness comparison, use one adapter that selects a
prebuilt, pinned driver/profile, runs the same disposable workload, and converts
independent receipts to this protocol. Pin both binaries and the workload/checker.
For background coexistence, independently check key focus, window order, user
input, pointer, clipboard, Space, dialogs and app activation; report zero user
disturbances only if all required observations were made and passed. Do not fill
unknown counters with zero just to qualify a profile.

For small local models, run separate pinned experiments for each model,
quantization and context configuration. Include real long-horizon cases requiring
state recovery after restart, repeated-object disambiguation, interrupted input,
late evidence retrieval, changed windows and exact completion receipts. Put
unseen variants in the held-out set. The model must actually use the target 16K
or 32K context configuration, and the adapter must measure peak context and actual
usage. Passing a synthetic compression fixture cannot establish that a 9B agent
completes these tasks. Live macOS/model qualification remains required.

## Artifacts, interruption and rollback

Each fresh output directory contains:

- `manifest.json`: exact validated experiment configuration.
- `ledger.jsonl`: append-only, flushed records for every attempted trial, failures,
  comparison decisions, incumbent changes, the freeze point and the final status.
- `report.json`: metric coverage, per-case medians, relative comparisons,
  qualification status, profile history and artifact fingerprints.
- `rollback-profile.json`: the original baseline, always written.
- `recommended-profile.json`: written only after successful held-out qualification
  and unchanged artifacts. It contains the profile itself for inspection/import.

There is no settings deployment to undo: `applied` is always false. If a reviewed
profile is subsequently applied by another workflow, retain this directory and
use its baseline profile through that same settings workflow for rollback.

The runner starts each adapter in its own process session. Timeouts, interruption
and excessive output terminate only that owned process group. Combined stdout and
stderr are bounded to 256 KiB; failing stdout excerpts are bounded to 4 KiB. The
child environment forwards only `PATH`, locale/timezone and temporary-directory
variables, plus `GODSPEED_EVALUATION=1`; API key environment variables are not
forwarded. This is not filesystem or network isolation. Use explicit paths and
configuration for adapters and avoid dumping sensitive case content to diagnostics.

Adapters must not detach jobs, operate on live user apps, launch permanent model
servers, change credentials/policy, or apply profiles. They should use an already
prepared local service or own disposable children, and handle cancellation and
cleanup. A process escaping its session is outside this runner's containment.
Native fixtures must also clean up their own OS-level resources.

Budget exhaustion or Ctrl-C writes a partial result and emits no recommendation.
The same monotonic deadline covers initialization, trials, scoring and both
artifact checks. Hashing checks the deadline before and after each read of at
most 1 MiB, and profile publication checks it around the atomic write. A late
artifact check cannot turn an expired run into a recommendation. Cleanup and
durable failure reporting may finish after the evaluation budget: kernel file
I/O cannot be preempted by a Python deadline check, and an owned child receives
SIGTERM followed by SIGKILL with bounded waits of 0.2 and 1 second. Unconfirmed
cleanup is recorded and stops the search without a recommendation, so a possibly
surviving process cannot contaminate later comparisons.
If the process is forcibly killed, the flushed ledger still records completed
attempts. There is intentionally no resume that reuses half a control/candidate
block: start a new run with a fresh directory and full matched repeats. Exit code
0 means qualified or no qualifying improvement; exit code 2 means invalid input,
failed qualification, changed artifacts, interrupted/incomplete evaluation or
another runner error. Consult `status` and `recommended_profile`, not exit code
alone, when deciding whether an evaluated profile exists.

## Design reference

This implementation adapts the one-change experiment loop, interleaved controls,
repeated medians, complete failure ledger, real token measurement and separate
qualification principles from
[sybil-solutions/inference-optimisation-skill](https://github.com/sybil-solutions/inference-optimisation-skill/tree/fda968e7fc1996aa23c67139c755fe541c9d4be0)
at commit `fda968e7fc1996aa23c67139c755fe541c9d4be0`. The README, skill instructions,
measurement methodology and queue script were reviewed as design references.
No skill is installed and no external permission or machine-setting instructions
are executed. No benchmark claims or measured gains from that project are
attributed to Godspeed.
