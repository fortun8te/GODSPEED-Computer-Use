# GODSPEED

Godspeed is a macOS computer-use server for local agents. It handles Mac apps through accessibility and Chrome through Open Browser Use. The app runs as an accessory without a Dock icon.

The desktop implementation lives in `packages/OpenComputerUseKit`. See the [verification plan](exec-plans/active/20261118-godspeed-workflow-reliability.md) for current coverage.

## How a call flows

```
MCP client
  │  stdio MCP, one JSON-RPC message per line
  ▼
GODSPEED.app/Contents/MacOS/OpenComputerUse mcp        (stdio entry point)
  │  unix socket: $TMPDIR/godspeed-agent.sock
  │  (namespace via OPEN_COMPUTER_USE_AGENT_SOCKET_NAMESPACE)
  ▼
GODSPEED agent (the app, started by macOS so grants stick to it)
  StdioMCPServer.handle        tools/list, tools/call, turn-ended
  ComputerUseToolDispatcher.callTool
    ArgumentNormalizer          alias names, types, missing app = last app used
    dispatchTool
      batch    -> BatchTool       steps, goal, recipes, referee hint, diff
      browser  -> BrowserBridge   obu mcp, CDP on the agent's own tab
      others   -> ComputerUseService   accessibility tree, actions, cursor
        VisionFallback            only when a label matches nothing
  LeanOutput.condensed            shrink the state text, keep element numbers
  ◄── reply: step lines + one state (change-only when possible)
```

## Tools

| Tool | What it does |
|---|---|
| `batch` | Up to 20 steps in one call. Stops at the first failure, one line per step, then one state. The main tool. |
| `browser` | Web pages in the agent's own background Chrome tab (Open Browser Use). Listed only when `obu` is found. |
| `get_app_state` | The app's numbered element tree. Set `compact: true` for a control-focused view that keeps focus and actionable indexes. Request a screenshot separately when needed. |
| `click`, `hover`, `type_text`, `press_key`, `set_value`, `select_text`, `scroll`, `perform_secondary_action` | Element actions by label or index. |
| `drag` | Two points on an app screenshot. Both must be in the observed window. Optional `modifiers` such as `["shift"]`. |
| `press_menu` | Chooses a menu item in one call, e.g. `path: "File > Save"`, through accessibility. |
| `query` | Finds elements by text or role. |
| `list_apps` | Recently used apps. |

## Batch features

- **Steps**: each step is a tool name plus arguments. Spelling is forgiving (`type` → `type_text`, `key` → `press_key`, and so on). A missing `app` is filled from the last app used.
- **Labels**: use visible text first. Current element indexes also work.
- **Fill**: `{"tool": "fill", "fields": {"To": "sam@x.com"}, "submit": "Send"}` becomes one `set_value` per field and a click. Add `"web": true` for a page.
- **Goal**: `goal` is one sentence. The reply may add a `Check:` line (done, stuck, or still loading) from the referee. Treat it as a hint.
- **Recipes**: send `remember: true` with a goal that reached it. Later, send only `goal` to replay the saved steps and their completion checks. Changed recipe values need a fresh check. Keep secrets out of completion conditions because saved recipes store them locally. Steps with element numbers or coordinates are never saved. A recipe that fails twice in a row is dropped.
- **Action readback**. The dialog check reuses the action’s window read when available. Batch effect checks can reuse a complete read of the same window when it shows a change. A delayed result or a change of window can require another read.
- **Change-only replies**: the final read is compared with what the model last saw for that app. Only changed lines are sent. If an element's number moved, the full state is sent instead. If nothing changed, the reply says so.
- **Condensed trees**: long rows are collapsed, text is cut at 160 characters, and container noise is dropped. Every element number the model can act on stays the same.
- **Referee and vision hooks**: both are off by default (see settings). The referee adds one hint line. Vision finds a labelled element on a screenshot when no accessibility element matches, then clicks there.
- **Browser**: `browser` with `action`: `open`, `go`, `read`, `click`, `drag`, `type`, `key`, `peek` (up to 6 URLs, 3 parallel lanes), `tabs`, `use_tab`, `wait`, `info`, `upload`. Click and type use the Chrome DevTools Protocol on that one tab, so the tab the user is reading is never touched.

Native actions read back accessibility text. Use `get_app_state` with `include_screenshot: true` or set `screenshot: true` on a batch when you need an image.

### Works only with focus borrowing

Focus borrowing brings one app to the front for a moment, then gives focus back to the app that had it. The pointer does not move. It is used only where background delivery cannot work:

- Dialogs and editors: Save, Export, Rename, New Folder, Print, Duplicate, Move To, and any menu title ending in `…`.
- Typing into a sheet that a shortcut just opened (for example after ⌘S).
- Key chords and activation-based clicks, and typing into a field a shortcut just opened, while `OPEN_COMPUTER_USE_BACKGROUND_ONLY=1`.
- Any batch sent with `foreground: true` (the whole batch runs with the app in front).

Set `OPEN_COMPUTER_USE_FOCUS_BORROW=0` to turn it off. Steps then run in the background only.

## Settings

Two places, one rule: **an environment variable that is set always wins**. Otherwise the value from `~/.godspeed/settings.json` is used, and otherwise the default. The file is re-read when it changes. Cursor settings apply on the next action. The others are read once per process, so they apply from the next start. PURE's Settings > GODSPEED writes the file.

### `~/.godspeed/settings.json`

| Key | Sets | Default if absent |
|---|---|---|
| `cursor_visible` | `OPEN_COMPUTER_USE_VISUAL_CURSOR` | `true` |
| `cursor_lens` | `OPEN_COMPUTER_USE_CURSOR_LENS` | `false`. Optional local capture under the cursor window. |
| `cursor_color` | `OPEN_COMPUTER_USE_CURSOR_COLOR` (`#RRGGBB`; `"default"` = original grey) | default grey |
| `cursor_speed` | `OPEN_COMPUTER_USE_CURSOR_SPEED`: `calm` (2), `normal` (4), `fast` (8), `instant`, or a number | `normal` (4) |
| `screenshots_by_default` | `OPEN_COMPUTER_USE_DEFAULT_SCREENSHOT` | `false` |
| `decision_hints` | `OPEN_COMPUTER_USE_REFEREE_URL` = `helper_url` | `false` |
| `find_on_screen` | `OPEN_COMPUTER_USE_VISION_URL` = `helper_url` | `false` |
| `helper_url` | the URL used by the two keys above | `http://127.0.0.1:8765` |
| `recipes` | `OPEN_COMPUTER_USE_RECIPES` | `true` |
| `browser` | `OPEN_COMPUTER_USE_BROWSER` | on if `obu` is found, else off |

### Environment variables

Behaviour switches (`0`/`off` turns off, unless noted):

| Variable | Default | Meaning |
|---|---|---|
| `OPEN_COMPUTER_USE_CONDENSE` | on | Condense state text (`AXTreeCondenser`). |
| `OPEN_COMPUTER_USE_BATCH_DIFF` | on | Change-only final read in batch replies. |
| `OPEN_COMPUTER_USE_DEFAULT_SCREENSHOT` | off | Screenshot with explicit app-state reads (settings key `screenshots_by_default`). |
| `OPEN_COMPUTER_USE_AX_COMPACT` | on | Short role spellings in the tree. `0` = older long spellings. |
| `OPEN_COMPUTER_USE_AX_INDENTATION` | `level` | `tab4` for four-space indent (opt-in). |
| `OPEN_COMPUTER_USE_MAX_COLLECTION_ROWS` | 20 | Visible rows kept per list, table or outline. |
| `OPEN_COMPUTER_USE_ACTION_READ_BACK` | on | Read the window back after an action. |
| `OPEN_COMPUTER_USE_SETTLE_BY_FRAME` | off | Sample window images during action readback to detect the end of animations. |
| `OPEN_COMPUTER_USE_BACKGROUND_ONLY` | off | Never raise or activate an app. Opt-in for when the user keeps working. |
| `OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS` | off | Allow moving the real pointer. Off means never. |
| `OPEN_COMPUTER_USE_FOCUS_BORROW` | on | Focus borrowing (see above). |
| `OPEN_COMPUTER_USE_RECIPES` | on | Saved recipes (settings key `recipes`). |
| `OPEN_COMPUTER_USE_VIRTUAL_DISPLAY_ENABLED` | off | Adds `window_placement` to `get_app_state`. |
| `OPEN_COMPUTER_USE_AGENT_SOCKET_NAMESPACE` | none | Separate socket for tests (`godspeed-agent-<hash>.sock`). |

### Cursor and client names

The MCP proxy uses known client names from initialization. Overlapping cursors with the same name receive a number. Labels show a client or nickname, while window and browser state stay scoped to the connection. For a nickname, set `OPEN_COMPUTER_USE_CURSOR_NAME` on that client's MCP process. Use up to 20 letters, digits, spaces, or hyphens and start with a letter.

| Variable | Default | Meaning |
|---|---|---|
| `OPEN_COMPUTER_USE_VISUAL_CURSOR` | on | Show the cursor (settings key `cursor_visible`). |
| `OPEN_COMPUTER_USE_CURSOR_COLOR` | original grey | `#RRGGBB` (settings key `cursor_color`). |
| `OPEN_COMPUTER_USE_CURSOR_SPEED` | 4 | 2 calm, 4 normal, 8 fast, `instant` (settings key `cursor_speed`). |
| `OPEN_COMPUTER_USE_CURSOR_FLOAT` | off | Draw above every window. |
| `OPEN_COMPUTER_USE_CURSOR_IDLE_HIDE_SECONDS` | 3 | Seconds before the idle cursor fades. |
| `OPEN_COMPUTER_USE_CURSOR_ASYNC` | on | Cursor work is queued and played by a display-synced frame clock; actions never wait for it. Env only. |

Helpers (referee and vision):

| Variable | Default | Meaning |
|---|---|---|
| `OPEN_COMPUTER_USE_REFEREE_URL` | unset (off) | Helper service base URL, e.g. `http://127.0.0.1:8765`. |
| `OPEN_COMPUTER_USE_HANDOFF_HELPER` | on with a configured referee | Set to `0` to skip model-ranked recipe handoff. |
| `OPEN_COMPUTER_USE_REFEREE_DONE_HINTS` | off | Optional model hints. `done_when` controls verified completion. |
| `OPEN_COMPUTER_USE_REFEREE_TIMEOUT_MS` | 1500 | Longest wait for a verdict. |
| `OPEN_COMPUTER_USE_REFEREE_MIN_CONFIDENCE` | 0.6 | Below this, no hint. |
| `OPEN_COMPUTER_USE_REFEREE_DONE_CONFIDENCE` | 0.85 | A `done` hint needs this. |
| `OPEN_COMPUTER_USE_REFEREE_MAX_VIEW` | 1200 | Characters of state sent to the referee. |
| `OPEN_COMPUTER_USE_VISION_URL` | unset (off) | Helper service base URL for `/locate`. |
| `OPEN_COMPUTER_USE_VISION_TIMEOUT_MS` | 8000 | Longest wait for a vision answer. |

Browser:

| Variable | Default | Meaning |
|---|---|---|
| `OPEN_COMPUTER_USE_BROWSER` | auto | `0` removes the `browser` tool. |
| `OPEN_COMPUTER_USE_OBU_BIN` | bundled `obu` | Explicit `obu` path. |
| `OPEN_COMPUTER_USE_BROWSER_SESSION` | `godspeed-<pid>` | Base session ID. Each agent's interactive browser and each of its peek lanes have distinct IDs. |
| `OPEN_COMPUTER_USE_BROWSER_PROFILE` | none | Passed to `obu --profile`. |
| `OPEN_COMPUTER_USE_BROWSER_APP` | `Google Chrome` | The app read after a browser step. |

Debugging and config:

| Variable | Default | Meaning |
|---|---|---|
| `OPEN_COMPUTER_USE_DEBUG_TIMING` | off | Timing lines on stderr. |
| `OPEN_COMPUTER_USE_CURSOR_TRACE_FILE` | none | One line per cursor event. |
| `OPEN_COMPUTER_USE_VISUAL_CURSOR_OBSERVATION_FILE` | none | Cursor state for tests. |
| `OPEN_COMPUTER_USE_DEBUG_INPUT_FALLBACKS` | off | Log input fallbacks. |
| `OPEN_COMPUTER_USE_DISABLE_AX_READ_CACHE` | off | `1` turns the accessibility read cache off. |
| `OPEN_COMPUTER_USE_CONFIG_FILE` | `~/.config/ocu/config.json` | Image settings file (`OPEN_COMPUTER_USE_IMAGE_*`: format, quality, max size, defaults in `ImageCaptureConfig.swift`). |
| Timing knobs | see `TimingLog.swift` | `TYPE_CHUNK_DELAY_MS`, `PRESS_KEY_SETTLE_MS`, `FOCUS_RECORD_SETTLE_MS`, `SKY_*`. Leave alone. |

Test and bench switches (`RUN_*`, `BENCH_*`, `APP_MATRIX_*`, `SMOKE_SERVER`, `FIXTURE_*`) are for the test suites only.

## Build, install, connect

See the [Godspeed setup guide](../README.md) for source and package installation, MCP registration, and Chrome setup.

## Private clipboard

Each Godspeed client has an in-memory clipboard shared by its Mac and Chrome actions. In Mac apps, select text and use `press_key` with `cmd+c`, `cmd+x`, or `cmd+v`. In Chrome, use `browser` with `action: "copy"`, `"cut"`, or `"paste"`. To paste into a named field, pass its label. A single batch can alternate these actions between apps.

Use `clipboard` with `action: "read"`, `"write"` and `text`, or `"clear"`. The REPL equivalent is `cua.clipboard(action, text?)`. Clipboard text is in memory and limited to 1 MiB. A separate client has a separate clipboard. Reading or writing the clipboard directly leaves its contents out of trajectory capture.

Finder file copies go to the same private clipboard. Paste them into Finder or select them in a labelled Chrome file input. Finder cut moves files only in Finder. Editors must expose selection and input through Accessibility or Chrome. Secure field contents, rich formatting, and image clipboard pastes are outside this feature.

## Verified workflows

1. Read the active window or tab. Use a label that identifies one control.
2. Batch related steps with `done_when` set to a visible result. Add `compact: true` to get a short reply when the check passes.
3. If the batch stops, use its recovery receipt. Inspect the current state before retrying a step whose effect is unknown.

Screenshots are available for controls that the accessibility tree misses. The optional decision helper is for ambiguous, goal-directed work. Routine reads and explicit completion checks can use the current observation directly.

Handoff can fill an empty, uniquely named field directly when its supplied value matches the explicit completion check. The helper ranks candidates only when the workflow still has a choice to make. A pinned handoff verifies against that window. If input might already have landed, it reads back before deciding whether to continue.

The visible cursor is feedback. Godspeed resolves and checks the target independently, keeps each agent's window anchor separate, and plays cursor motion on the display clock. If a path crosses a gap with no screen, it reappears beside the next target. The app never needs to move your physical pointer with the default background settings.

When many moves are queued before the next frame, Godspeed keeps the latest pending move for each agent. It preserves clicks and gestures in order. Each cursor can finish and fade on its own while other agents keep working.

Vercel's agent-desktop scopes references to the observed window and keeps cursor travel out of the window interaction lock. [Snapshot guide](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/apps/docs/content/docs/snapshots-and-refs.mdx) · [Cursor delivery](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/core/src/cursor_overlay/submit.rs)

## Parallel browser reads

To inspect a known native window directly, pass its ID to `get_app_state`. This read does not move the window or use app-wide settle. For an exact native action target, take a fresh app observation and use its reported `Window ID` as `window_id` on a supported action or a single-app batch. Godspeed stops if the observed window or required focus no longer matches. Refresh the observation before trying again. In the JavaScript REPL, use `app.batch(steps, { windowId, doneWhen })` to execute a sequence and check the final state in one call. The reply includes a `receipt` with each step's status, the number of steps left and the completion verdict. Acknowledged actions and verified outcomes are reported separately.

For a known workflow, use `app.batch(steps, { windowId, doneWhen, compact: true, effects: false })`. Compact mode trims surplus plain text from the final reply after the checks run. Failed or incomplete batches keep their normal detail. Disabling effects skips per-step observation reads, so use it when the sequence needs only a final check.

For a browser batch whose final success is a known URL, set `return_state: false` with a URL-only `done_when` (REPL option `returnState`). Godspeed reads the tab's address directly. A passing check can return the receipt without fetching the page snapshot. A failed check keeps the normal recovery read.

For longer tasks, check `receipt.recovery` before resuming a partial batch. `refresh_then_continue` marks a step that never started, `fix_then_continue` marks an explicitly unsent failure, and `inspect_before_retry` means the action may have landed. `inspect_result` asks you to check the outcome without resending inputs. Recovery step numbers refer to expanded steps in the receipt, so a single form instruction can occupy several numbered steps.

Use `browser read` with `interactive: true` to find controls with fewer tokens. Use the default read when prose or confirmation messages matter. Interactive reads retain tab- and document-scoped references and can overlap across independent clients. Add `diff: true` on repeated, unfiltered browser reads for a smaller change summary. Godspeed returns the full view when the document, mode or reference mapping changes. Batch completion checks still use the full current observation.

Browser reads include reported focus, disabled, selected, checked and expanded states. Use these to confirm the control before asking for an image. If Chrome times out after `fill_field`, Godspeed can verify the exact value on the same control and document without sending the text again. If the final click has uncertain delivery, a fresh page read can still verify an explicit text or URL condition. The step receipt retains the missing acknowledgement. A lookup timeout uses a full-tree fallback when the tab connection is still valid.

Set `if_changed: true` on `browser screenshot` to avoid returning an identical capture. The comparison is exact and scoped to the client, tab, address, and browser helper generation. Godspeed keeps a digest in memory, not a saved image. In the REPL, `cua.browser("read", { tab_id: 12 })` uses the same persistent connection as native app bindings. `cua.batch(steps, options)` can alternate browser steps with native steps that each name their app. Keep dependent actions ordered and check the batch receipt before resuming. The REPL discards queued input from ended evaluations. Saved-recipe handoffs and final browser observations share the time left in the original operation.

Use `browser outline` for visible headings in the main document, `browser frames` for the tab's document tree, and `browser scroll_into_view` with a label or current reference to reveal one control. Frame listings are for inspection. Actions still need a control reference or label. A browser click can use the left, middle, or right button, or a left double-click. Clicks and drags accept Alt, Control, Command, or Shift modifiers. The click checks its hit point before sending input.

Use `browser read_text` for rendered text from a uniquely named control or region, or a current control reference. Use `browser link_destination` with a label or current reference to inspect an HTTP(S) link without clicking it. Add `include_link_urls: true` to a read for destinations that Chrome exposes in its accessibility tree. Use `browser control_state` with a label or current reference for visibility, enabled status and checked state when available. Visibility describes rendering. It does not guarantee the control is unobstructed. Use `browser value` with a field label or current reference to read one editable value. Password inputs return no value. Use `browser location` for the tab URL, title, and readiness without reading page content. Use `browser fill_field` to replace an ordinary editable value with one insertion. Use `type` for controls that need keyboard events. Use `browser wait_for` with `url_contains` for a redirect or confirmation page. Use `wait_for` with a `label` and `condition: "enabled"` to wait for a control. Other conditions are `visible`, `checked`, and `unchecked`. Use an explicit `tab_id` when multiple tabs are open.

For a file input with a visible label or current reference, pass it to `browser upload` along with readable absolute file paths. Godspeed sets the selection directly and checks the file count. The website's separate submit action controls whether anything is sent.

Use browser `close_tab` with the explicit `tab_id` returned by `open_tab`. Godspeed checks that the current session still owns the tab and that the browser reports it closed.

While the Mac is unlocked, up to four different MCP clients can make read-only browser requests at once. Use the canonical `read`, `peek`, `info`, `tabs`, or `screenshot` action. An explicit `wait_for` of 1–3 seconds can also share admission. Each client has its own tab state and can have one read in flight. Native actions, browser writes, mixed batches, and any Locked Use recovery get exclusive access. Exclusive requests run in arrival order. A queued writer normally gets the next turn. When a reader has waited through two exclusive admissions, the oldest eligible reader gets a turn. One client cannot take multiple read slots. Set `OPEN_COMPUTER_USE_PARALLEL_READS` to 1, 2, 3, or 4 in the shared app agent environment to compare reader limits. The default is 3.

If the Mac session changes mid-read, Godspeed stops issuing browser commands and reports the interruption. Check the tab before retrying.

## Browser drag

Open or select a tab and read its controls. For example, use `{"action":"drag","label":"Card A","to_label":"Drop zone"}` when both controls are visible in the same page. Read the tab after delivery to verify the drop. Apps can interpret pointer gestures differently.

## Local traces

Tool logs at `~/.godspeed/trajectories` record queue time, tool duration, batch outcomes and verification. The default omits arguments, screen text and screenshots. Set `OPEN_COMPUTER_USE_TRAJECTORY_LOG=0` to turn logging off. For a local fixture, `OPEN_COMPUTER_USE_TRAJECTORY_FAILURES=1` adds a short error and argument shape. Review it before sharing because errors can include app names, filenames or controls. `OPEN_COMPUTER_USE_TRAJECTORY_CONTENT=1` captures typed text and observations.

Use `python3 scripts/godspeed-trace-summary.py` for aggregate timings and helper activity. A helper receipt records that the helper ran. Match verified fixture outcomes to exact run streams before using them as labels.

## Known limits

- macOS only. The app is built for the native arch. `obu` is built for arm64.
- Native app input and browser writes are serialized. Eligible browser reads overlap across clients. Use `cua.peekPages(urls)` in the REPL to load up to three independent pages at once, with up to six URLs per call. Keep steps that share input or depend on each other's output in one ordered batch.
- Set `OPEN_COMPUTER_USE_CURSOR_COLOR=auto` for stable per-client cursor colors. The active cursor shows which client is driving the shared Mac input.
- Background delivery depends on the app. Dialogs, sheets and some key chords need focus borrowing.
- A batch is at most 20 steps. `peek` takes at most 6 URLs with a shared 40-second browser budget. Idle preview workers pick up the next unread URL automatically. At most three preview loads run across the shared process. Preview helpers expire after a minute of inactivity. The REPL returns `pages` with a URL, status, text, and cleanup result for each page. Retry only failed or unstarted URLs. Results stay in the input order and report pages that could not be read.
- The referee and vision are hints and fallbacks, off by default. Vision has been checked on one synthetic image, not on real apps.
- Recipes match the exact goal text. They are stored only on this Mac (`~/.godspeed/recipes.json`).
- The browser tool needs Chrome, the Open Browser Use extension, and the one-time setup step. It cannot use other browsers.
- Model results are not measured yet. The fixed task set (steps, seconds, finish rate against Codex native) has not been run.
- Apps with no usable accessibility tree can be clicked only by vision. That needs `find_on_screen` on and the helper service running.

See [training fixtures](training-fixtures.md) for reviewed vision annotations and verified decision labels.

See the [macOS capability audit](macos-capabilities.md) for the boundary between Godspeed tools, app workflows, and other macOS interfaces.

### When macOS is locked

The public Godspeed package requires a signed-in, unlocked desktop for app controls, browser tools and screenshots. Its MCP connection can still answer `ping` and `tools/list` while the Mac is awake and the agent is running. For jobs that can run outside the desktop, use the app's supported API or command-line tools. After an interrupted desktop batch, unlock normally, read the current app state and resume from the last confirmed result.

The local `OpenComputerUse locked-use status --json` command reports `not-packaged` on this build. Apple Screen Sharing provides authenticated remote desktop access when it is enabled in System Settings. [Apple Screen Sharing guide](https://support.apple.com/en-sg/guide/mac-help/mh14066/mac)

### Browser feedback and parallel jobs

The fork's page cursor reacts to acknowledged browser movement, press, drag, drop, click, text insertion and scroll. Feedback is sent only to an active matching tab and never delays the input reply. Intermediate moves can be coalesced. Hidden pages suppress the overlay. Near a display or viewport edge, the cursor follows a straight eased path to the action point. The web renderer shares interaction meanings with the Mac cursor.

Use independent browser connections for concurrent reads. Browser writes and native input retain exclusive admission while the app agent applies process-wide settings. A shared budget caps active preview loads, and each helper has one rescheduled idle timer. Compare end-to-end fixture timings and slow runs before promoting the candidate.
