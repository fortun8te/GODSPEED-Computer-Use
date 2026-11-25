# Local execution and reliable background work

Godspeed should carry out a well-specified task with local evidence, keep progress attached to the right window, and return a useful checkpoint when it cannot continue. A model is useful for an unresolved choice; it should not be required to remember which button was already pressed, check a field value, or wait for a slow interface.

## Coworker behaviour

The user owns the foreground and physical input. Background work can continue in its own target while the user works elsewhere; optional focus borrowing yields when the user returns. A delayed request must not reclaim focus or resurrect an old cursor after its ownership has ended.

An unattended task keeps its original application lifetime, window, deadline and delivery evidence. An app restart is a new target even if macOS reuses its process and window numbers. Cancellation releases held input and stops queued work before dispatch; an operation already handed to macOS remains uncertain until its effect can be inspected. The system returns that distinction instead of treating a timeout as permission to repeat an action.

Local actions, accessibility reads, OCR and verification carry routine work. Optional models handle unresolved choices under the same task budget. Progress and recovery should be useful to the host agent without requiring the user to supervise every click.

Pure browser observations from another client can run while a native task waits for inference without cancelling that task. Any intervening potentially mutating admission still invalidates the old observations, including previews that create temporary tabs. Focus restoration uses the live foreground owner and rechecks it across accessibility reads, so changing apps or windows does not restore the person's previous focus.

## Continuing with a small context window

Keep the resume token from a stopped batch in the host's short task summary. After a context reset, call `batch {"inspect_resume":"TOKEN"}`. This local read returns compact JSON containing the original step numbers, pending tools, dispatched and uncertain steps, required fresh value slots, target identity and next action. It does not execute actions, consume the token, expose stored argument payloads, or claim that saved evidence is the current screen.

An eligible continuation uses `batch {"resume":"TOKEN","values":{...}}`. The existing resume path rechecks process lifetime and window identity, reads the target again, and claims the token only after preflight. Uncertain delivery, browser continuations, unbound steps and legacy process identities require fresh inspection and explicit remaining steps. A dispatched step is not automatically a completed goal.

This keeps progress outside the model's transcript and can help hosts with 16–32K context windows. It does not establish a completion rate for a particular 9B model; that needs a matched task evaluation with the selected model and tokenizer.

## Local tree interpretation

Accessibility traversal fetches scalar attributes separately from child arrays. It asks for child counts, reads only the prefix permitted by the remaining discovery budget, and reuses successful counts and pages within the snapshot. Short or failed pages remain incomplete evidence; they do not become proof that a target disappeared.

Compaction builds a local parent/sibling index. It preserves named groups, distinct controls, adjacent field labels, validation/status text, state traits and explicitly retained refs. A repeated plain label directly under its own control can be omitted. Budget selection carries the selected control's real ancestor path, avoiding misleading placements under an unrelated section.

Semantic changes match names within their parent context. Repeated unqualified controls use state multisets; ambiguous differences are reported as ambiguity. Values containing literal parentheses remain values, and sensitive ancestor labels suppress field-value summaries. The diff reply computes semantic events once and reuses them for summarization and trimming.

## Delivered motion and activity

Drag presentation receives positions and monotonic timestamps after input events are posted. One pending display update takes the latest delivered point rather than replaying an accumulated path after release. Cancellation retains that last point, and a skipped release cannot generate a delivered-release indication.

The active target gets a passive, click-through window-edge bloom with a dark accent core and broad soft falloff. Its label follows action state: Working, Dragging, Typing, Scrolling, Waiting or Delivered. The treatment stays at the target window's layer, leaves document contents clear, hides at idle/reset/cancellation, and follows existing feedback, label and Reduce Motion preferences. Delivered indicates posted input, not independently verified task completion.

## Bounded local improvement

The [local evaluation runner](local-evaluation.md) compares declared parameter neighbours with interleaved controls, independent completion/safety checks, explicit metric coverage and held-out qualification. It logs unsuccessful trials and emits a recommended profile plus rollback baseline only after qualification. It does not invoke a model, apply settings or modify code on its own.

## Configuration

Open `godspeed` and choose **Presets → Model-free** to stage compact reads, verified recipes, change-only batch replies, screenshots on request, and disabled optional model helpers. Review the changes and save. The host agent still uses its own configured model; this preset controls inference inside Godspeed.

The master switch is `model_helpers: false` in `~/.godspeed/settings.json`, or `OPEN_COMPUTER_USE_MODEL_HELPERS=0` for a client. It disables decision/vision/GSD1 helpers, the default localhost handoff chooser, warmups, model picture capture, health probes and auto-start. Explicit process environment values take precedence over file preferences. AX inspection, local OCR, exact actions, verified recipes and deterministic checks remain available.

Optional helper requests share the enclosing task's deadline. Encoding, admission handoff and HTTP waiting consume the same budget; expired work does not start a request, and late replies are discarded. Background health checks and warmup recovery retain the originating deadline. A queued probe that expires before starting releases its cooldown reservation without overwriting a newer caller's reservation.

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
| A native checkpoint belongs to a restarted app, or lacks launch identity | Refuse the old continuation and require fresh explicit steps; matching process/window numbers are insufficient. |
| A compatible native checkpoint resumes | Carry the original window through actions, waits, baselines and final verification. Validate incompatible steps before claiming the checkpoint. |
| A save sheet shows only a folder basename | Do not infer the destination from that name. Require the accepted full-path filename or an observed absolute destination before pressing Save. |
| A saved pending step or completion check contains user values | Require fresh value slots. Normalize aliases before storage, keep completion operators separate from their values and refuse legacy unslotted values. |

Recipe replay remains evidence-based. A previous successful recipe is a reusable plan, not proof that the present task is already done or permission to repeat an uncertain side effect. Existing action policy and delivery receipts continue to apply.

The settling budget is a maximum of 700 ms of deliberate delay plus at most three local reads. It is used after an acknowledged but unchanged action, stops early on progress, and does not repeat the action. It is not a measured latency improvement across applications.

## Native observation and scheduling

Accessibility notifications invalidate cached misses immediately. A fresh search that overlaps a notification does not save its negative result. Observer callbacks and read generations are tied to the observer's lifetime, so an expired observer cannot alter a replacement observer for the same process number.

Notification waits check cancellation at intervals of at most 50 ms without replacing the request's cancellation callback. Readiness and settling check again after native reads, before accepting completion. A transient attribute failure is not evidence that a window is quiet. Parallel scans carry the request cancellation token into their workers and stop before subsequent reads; an AX call already in flight still depends on the operating system to return.

Control-condition waits check cancellation before reading, after reading and between polls. A ready sample received after cancellation cannot become a successful completion. The stdio request queue refuses only the excess request when full, keeps reading cancellation messages and preserves active and previously queued work. The request worker and overflow reader serialize whole reply lines so concurrent responses cannot corrupt the JSON-RPC stream.

Local readiness polls also respect the enclosing workflow deadline. NSWorkspace opens and Apple Events retain cancellation and the same absolute budget through their asynchronous callbacks. A delayed Apple Event worker cannot dispatch after its caller has timed out. Duplicate or late completions do not replace the first result; cancellation after dispatch preserves uncertain delivery. A queued desktop request rechecks its deadline when the admission gate becomes available.

App-agent cancellation covers a blocked request write as well as the response wait. A partially written request is interrupted by shutting down that connection, rather than inserting a cancellation message into its unfinished frame. Closed, malformed and timed-out streams are invalidated immediately; the next non-cancelled request reconnects. Queued requests survive the connection failure, and the interrupted action retains uncertain delivery.

The action monitor records the generation before dispatch, so a notification received during dispatch establishes that the app reports changes. A delivered action still invalidates reusable read evidence: a preflight notification or read cannot prove its later effect. It does not start an action grace period for input reported as unsent or uncertain. Text values are withheld while secure-field classification is unavailable, with a retry once classification resolves.

## Shared workspace behaviour

The standard MCP launcher enforces background-only operation and disables focus borrowing and physical-pointer fallbacks. Some applications still cannot perform particular actions in the background; these return a refusal with the current evidence.

At native mutating dispatch boundaries, background-only sessions yield when recent physical user activity overlaps the target foreground app or window. Work in another app, or a demonstrably different explicitly pinned window, can continue. Read-only operations and the private clipboard remain available. This check does not establish an exclusive lease against user input arriving after dispatch.

For separately configured sessions that allow focus borrowing, Godspeed checks foreground ownership again after waiting for user inactivity, before both acquisition and restoration. Nested borrowing respects user activity. A previously hidden application is not hidden again while the user is actively using it.

Acquisition rechecks live foreground ownership, user inactivity and the originating request on the main queue, including after unhiding. It does not schedule a forced asynchronous activation retry that could arrive after the user returns. Retained leases are checked against the current foreground owner when a workflow moves between apps. Synthetic input cleanup does not deactivate a target the user has brought forward.

Software cursor presentation is asynchronous. Accent, nickname, visibility, labels, action indicators, speed, reduced motion, idle timeout and floating are independent preferences. System mode respects macOS Reduce Motion. Cosmetic motion has a finite duration even for extreme numeric settings. OCR/vision clicks use the same anchored indication, with the click pulse following delivered input.

Cursor ownership resets discard queued animation generations, including a retained main-thread slice. Fresh work can still drain normally. A cursor-disabled request dismisses its own existing presentation without clearing another client's cursor.

Native input rechecks cancellation and the active time budget after window, focus and hit validation, immediately before posting. Keyboard and click sequences prepare matching releases before pressing. If a request ends after input starts, cleanup releases the keys or button already pressed while the receipt preserves uncertain delivery; the caller must inspect the result before repeating it.

Held keys and drag holds use sleep intervals of at most 50 ms and recheck target validity, cancellation and the remaining budget between intervals. Validation time counts toward the requested hold. A synchronous accessibility call already in flight can take longer than the sleep interval.

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
