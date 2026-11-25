# Local execution and reliable background work

Godspeed should carry out a well-specified task with local evidence, keep progress attached to the right window, and return a useful checkpoint when it cannot continue. A model is useful for an unresolved choice; it should not be required to remember which button was already pressed, check a field value, or wait for a slow interface.

## Configuration

Open `godspeed` and choose **Presets → Model-free** to stage compact reads, verified recipes, change-only batch replies, screenshots on request, and disabled optional model helpers. Review the changes and save. The host agent still uses its own configured model; this preset controls inference inside Godspeed.

The master switch is `model_helpers: false` in `~/.godspeed/settings.json`, or `OPEN_COMPUTER_USE_MODEL_HELPERS=0` for a client. It disables decision/vision/GSD1 helpers, the default localhost handoff chooser, warmups, model picture capture, health probes and auto-start. Explicit process environment values take precedence over file preferences. AX inspection, local OCR, exact actions, verified recipes and deterministic checks remain available.

**Quiet** reduces visual feedback while keeping apps in the background. **Balanced** uses normal cursor motion and compact observations. Neither silently turns model helpers on or changes the selected accent. For a completely hidden software cursor, turn off **Show agent cursor**. The real pointer remains separate.

## Execution rules

| Situation | Behaviour |
| --- | --- |
| Exact unique control or fully specified form | Resolve locally, preflight the action, compare guarded field values and read back the result. |
| A supported named target is absent from AX | Try bounded local OCR. Optional model fallback requires enabled helpers and configured vision. |
| An acknowledged action initially appears unchanged | Wait locally with up to three read-only polls after 100, 200 and 400 ms, within the request deadline. |
| A mutation has uncertain delivery | Return the uncertainty. Do not replay it because a read or timeout failed. |
| A handoff changes windows or process identity | Stop. All subsequent reads and actions belong to the original window/process. |
| An explicit `Click X` has already been attempted | Verify or return the incomplete outcome; do not substitute an unrelated model-selected action. |
| A stale element number needs recovery | Re-read the original window, require the same process and an unambiguous observed identity, then keep the retry pinned. |
| A workflow repeats unchanged states or navigation cycles | Detect the stall locally and return evidence without a separate stuck-model call. |
| A resume request is canceled or already expired | Leave its checkpoint available; do not consume the token or send pending input. |
| A saved pending step or completion check contains user values | Require fresh value slots. Normalize aliases before storage, keep completion operators separate from their values and refuse legacy unslotted values. |

Recipe replay remains evidence-based. A previous successful recipe is a reusable plan, not proof that the present task is already done or permission to repeat an uncertain side effect. Existing action policy and delivery receipts continue to apply.

The settling budget is a maximum of 700 ms of deliberate delay plus at most three local reads. It is used after an acknowledged but unchanged action, stops early on progress, and does not repeat the action. It is not a measured latency improvement across applications.

## Native observation and scheduling

Accessibility notifications invalidate cached misses immediately. A fresh search that overlaps a notification does not save its negative result. Observer callbacks and read generations are tied to the observer's lifetime, so an expired observer cannot alter a replacement observer for the same process number.

Notification waits check cancellation at intervals of at most 50 ms without replacing the request's cancellation callback. Readiness and settling check again after native reads, before accepting completion. A transient attribute failure is not evidence that a window is quiet. Parallel scans carry the request cancellation token into their workers and stop before subsequent reads; an AX call already in flight still depends on the operating system to return.

The action monitor records the generation before dispatch, so a notification received during dispatch establishes that the app reports changes. A delivered action still invalidates reusable read evidence: a preflight notification or read cannot prove its later effect. It does not start an action grace period for input reported as unsent or uncertain. Text values are withheld while secure-field classification is unavailable, with a retry once classification resolves.

## Shared workspace behaviour

The standard MCP launcher enforces background-only operation and disables focus borrowing and physical-pointer fallbacks. Some applications still cannot perform particular actions in the background; these return a refusal with the current evidence.

For separately configured sessions that allow focus borrowing, Godspeed checks foreground ownership again after waiting for user inactivity, before both acquisition and restoration. Nested borrowing respects user activity. A previously hidden application is not hidden again while the user is actively using it.

Software cursor presentation is asynchronous. Accent, nickname, visibility, labels, action indicators, speed, reduced motion, idle timeout and floating are independent preferences. System mode respects macOS Reduce Motion. Cosmetic motion has a finite duration even for extreme numeric settings. OCR/vision clicks use the same anchored indication, with the click pulse following delivered input.

Native input rechecks cancellation and the active time budget after window, focus and hit validation, immediately before posting. Keyboard and click sequences prepare matching releases before pressing. If a request ends after input starts, cleanup releases the keys or button already pressed while the receipt preserves uncertain delivery; the caller must inspect the result before repeating it.

## Settings integrity and privacy

The terminal menu stages edits and presets until an explicit save. Resetting or reverting a setting updates the draft's actual difference; an unchanged draft does not rewrite the file. Read-only output omits editing commands. Custom URL credentials and terminal control characters are not displayed.

Saving preserves unrelated keys, detects external changes and atomically replaces a private settings file. Large retained values use compact output when indentation would exceed the read limit; an oversized draft is refused without replacing the original. The runtime cache tracks file identity, size and modification time so atomic replacements with identical timestamps are observed. Partial manual edits and temporary permission or I/O errors keep the last valid settings. Only an explicit missing-file result resets preferences to defaults.

Local learning records and image retention have separate controls. Images remain opt-in. Learning preferences apply per request; connection-level trajectory preferences apply when a client reconnects. Neither logging control changes whether input is sent.

## Reference projects

The implementation is native Swift and adds no agent-framework dependency. These primary sources informed the design review; the changes do not transplant their code or claim their benchmark results.

| Source inspected | Useful design lesson |
| --- | --- |
| [agent-desktop: delivery dispositions](https://github.com/vercel-labs/agent-desktop/blob/ce2ddf07226346818de2a1c6bae9869cfad142df/crates/core/src/response/delivery_disposition.rs), [window-bound waits](https://github.com/vercel-labs/agent-desktop/blob/ce2ddf07226346818de2a1c6bae9869cfad142df/crates/core/src/ref_action/ref_action_wait.rs), [cursor presentation](https://github.com/vercel-labs/agent-desktop/blob/ce2ddf07226346818de2a1c6bae9869cfad142df/crates/core/src/ref_action/presentation.rs) | Separate delivery from verification, bind waits to the original target and distinguish visual presentation from actual input. |
| [agent-browser: snapshot reference lifecycle](https://github.com/vercel-labs/agent-browser/blob/f0a98351ec920bd826b22c98dacf8414f04b9832/docs/content/docs/snapshots.mdx) | Reuse surviving identities; reject ambiguous replacement targets instead of silently rebinding them. |
| [browser-use: execution instructions](https://github.com/browser-use/browser-use/blob/94784c1f7ecb6b0a5f565b7f9fba59e395b7e048/browser_use/agent/prompt.py) | Batch an action with its needed reads, retain verified progress and do not replay mutations after partial execution. |
| [Firecrawl Local: scrape pipeline](https://github.com/firecrawl/firecrawl/blob/0519b26a2b73c13048c0d29bce12c0306f7601ec/apps/local/src/scrape.rs) | Use cheap local extraction before expensive fallback. Disable implicit fallback explicitly in a model-free mode. |
| [Stagehand: caching](https://docs.stagehand.dev/v4/best-practices/caching) | Deterministic replay requires relevant context and invalidation. Its current cache is Browserbase-managed and does not operate for local-browser sessions; Godspeed retains its local recipe mechanism. |

## Validation

The macOS workflow covers menu transactions and interactive flows, settings-to-runtime mapping, helper exclusion, cursor preferences, foreground races, handoff settling, target integrity, batch resume, observer replacement and cancelled native input. Portable launcher tests check executable packaging, argument forwarding, missing applications and enforced MCP defaults.

Tool telemetry is finalized before it is logged, using monotonic execution time. Trace summaries report measurement coverage, queue-inclusive latency, helper routes and completion evidence separately. Missing legacy telemetry remains unknown; a fixture with the expected side effects still fails overall completion if its workload aborts. See [benchmark interpretation and commands](benchmarks.md).

Unit tests establish those contracts. Live evaluations are still needed for unfamiliar applications, overlapping user activity, interrupted long workflows, Retina/canvas targets and video editors. Measure success, false actions, abstentions, helper-call counts and latency on matched tasks before claiming an overall performance gain. The public build still requires an awake, unlocked desktop for GUI work.
