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
  ◄── reply: action receipt + requested or useful state
```

## Tools

| Tool | What it does |
|---|---|
| `batch` | Up to 40 steps in one call. Stops at the first failure. Click sequences group routine successes and include final state. Verified workflows can omit the implicit tree. Set `compact: false` for full step detail. |
| `browser` | Web pages in the agent's own background Chrome tab (Open Browser Use). Listed only when `obu` is found. |
| `local_decision` | Optional GSD1 recommendation from typed Action, Read or Recover evidence. [Setup](../experiments/LocalHelper/README.md#optional-gsd1-on-apple-silicon). |
| `get_app_state` | The app's numbered element tree. Set `compact: true` for a control-focused view that keeps focus and actionable indexes. Request a screenshot separately when needed. |
| `click`, `hover`, `type_text`, `press_key`, `set_value`, `select_text`, `scroll`, `perform_secondary_action` | Element actions by label or index. |
| `drag` | Drag between controls or points in one window. Add `verify` for a drop check. |
| `gesture` | Zoom or invoke an app command equivalent. Chrome also supports tab history. |
| `wait_for` | Wait for a control to appear, disappear or change value. |
| `press_menu` | Chooses a menu item in one call, e.g. `path: "File > Save"`, through accessibility. |
| `query` | Finds elements by text or role. |
| `list_apps` | Recently used apps. |

## Batch features

- **Steps**: each step is a tool name plus arguments. Spelling is forgiving (`type` → `type_text`, `key` → `press_key`, and so on). A missing `app` is filled from the last app used.
- **Labels**: use visible text first. Current element indexes also work.
- **Fill**: `{"tool": "fill", "fields": {"To": "sam@x.com"}, "submit": "Send"}` becomes one `set_value` per field and a click. Add `"web": true` for a page.
- **Goal**: `goal` is one sentence. The reply may add a `Check:` line (done, stuck, or still loading) from the referee. Treat it as a hint.
- **Final reads**. `return_state: false` can skip the final tree when a direct file, exact native field, or URL check supplies the requested evidence. Missing evidence triggers a recovery read. A presence check that was already true before the batch remains weak evidence.
- **Wait steps**. Godspeed can check for a window, matching text, or busy indicator before taking a full read. The full read still confirms the wait. Busy checks make up to four accessibility reads at a time.
- **Action readback**. The dialog check reuses the action's window read when available. A verified field write can use the next scheduled read. Batch effect checks can reuse a complete read of the same window when it shows a change. A delayed result or a change of window can require another read.
- **Change-only replies**: the final read is compared with what the model last saw for that app. Only changed lines are sent. If an element's number moved, the full state is sent instead. If nothing changed, the reply says so.
- **Condensed trees**: long rows are collapsed, text is cut at 160 characters, and container noise is dropped. Every element number the model can act on stays the same.
- **Referee and vision hooks**: both are off by default (see settings). The referee adds one hint line. Vision finds a labelled element on a screenshot when no accessibility element matches, then clicks there.
- The [headless learning bench](../scripts/flywheel/README.md) exports scrubbed fixture receipts on demand and compares local model candidates before any manual update.
- **Browser**: `browser` with `action`: `open`, `go`, `read`, `click`, `drag`, `type`, `key`, `peek` (up to 6 URLs, 3 parallel lanes), `tabs`, `use_tab`, `wait`, `info`, `upload`. Click and type use the Chrome DevTools Protocol on that one tab, so the tab the user is reading is never touched.

Window reads skip the menu bar by default. Use `include_menu_bar: true` on `get_app_state` or `--include-menu-bar true` on a CLI snapshot to include it. `press_menu` takes the menu path directly.

Native actions read back accessibility text. Use `get_app_state` with `include_screenshot: true` or set `screenshot: true` on a batch when you need an image.

Save uses a supported app's save command first when no sheet is open. The accessibility route waits for the name field and save controls. Both routes verify a new write on disk.

When a visible app is still preparing its web content, Godspeed checks for the web area before walking the full tree again.

Browser `find` checks matching controls first and keeps icon-only controls eligible for hints. Chrome reads the selected hints together. Use `find_exact` to look up controls by their exact accessible name. Use a regular read for numbered controls and page verification.

### Strict background mode

Set `"strict_background": true` in `~/.godspeed/settings.json`, or pass `strict_background: true` on a tool call. In the JavaScript REPL, use `strictBackground: true` in the options. Batch and handoff steps inherit the restriction.

Godspeed uses routes that avoid app activation, temporary key focus, and physical pointer movement. Native reads require an app that is already running. Native clicks use accessibility elements. If the route needs keys, a pixel click, a window move, or a new browser tab, Godspeed returns `BACKGROUND_UNSUPPORTED`. Browser actions in strict mode require an already connected helper.

Focus borrowing is off by default. When explicitly enabled with `OPEN_COMPUTER_USE_FOCUS_BORROW=1`, it can bring an app forward for a dialog or a batch sent with `foreground: true`. Strict background mode and `OPEN_COMPUTER_USE_BACKGROUND_ONLY=1` both disable focus borrowing. Strict mode also refuses routes that temporarily make a background window key.

With borrowing off, the background route is always tried first. A step that fails only because it needs the app in front (a Save, Export or Open menu item or save chord, the save panel's Save As route, typing into a dialog editor, a `foreground: true` batch) returns `BACKGROUND_UNSUPPORTED: This needs focus borrowing: set OPEN_COMPUTER_USE_FOCUS_BORROW=1 or allow it in Settings`.

### Local action policy

Godspeed reads `~/.godspeed/action-policy.json` for each action, including steps expanded from a batch, handoff, or recipe. Use bundle IDs for apps and full HTTP(S) origins for websites. Scheme and port matter. Each rule accepts `allow`, `ask`, or `deny`. A refusal takes precedence over an allow. With no rules, existing tool behavior applies.

```json
{
  "apps": { "com.apple.mail": "ask" },
  "origins": { "https://shop.example": "deny" },
  "risks": { "purchase": "ask", "credential_entry": "deny" }
}
```

The risk keys are `send`, `submit`, `purchase`, `delete`, `credential_entry`, `file_overwrite`, and `system_settings`. Godspeed checks context such as secure fields, form controls, key shortcuts, and save operations. An opaque native action can match several risk rules. With site restrictions enabled, use the browser tool for Chrome so it can check the tab and known destinations.

An `ask` rule stops with `APPROVAL_REQUIRED`. A `deny` rule stops with `ACTION_DENIED`. Only the local policy file controls permission. Page text and tool arguments cannot grant it. MCP returns the code in `_meta["godspeed/error_code"]`. The REPL exposes it as `error.code` on native exceptions and `errorCode` on batch and browser replies.

Chrome can follow its own redirects during navigation. Godspeed checks the resulting origin before returning page content or accepting another action. The policy governs Godspeed calls. Chrome still handles network requests and page scripts.

## Settings

Two places, one rule: **an environment variable that is set always wins**. Otherwise the value from `~/.godspeed/settings.json` is used, and otherwise the default. The file is checked for changes as requests read settings. Each app-agent call uses its own options. Cursor and strict background settings apply on the next call. PURE's Settings > GODSPEED writes the file.

The app agent snapshots its launch environment. Each request overlays the caller's `OPEN_COMPUTER_USE_*` options. Image, virtual display and browser options that the caller omits use their defaults or settings files. Socket selection, admission limits, the idle timer, package discovery and the cursor renderer style and namespace belong to the host process. The proxy keeps the client identity and trajectory settings for the connection.

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
| `OPEN_COMPUTER_USE_SETTLE_BY_FRAME` | on | Sample window images during action readback to detect the end of animations. |
| `OPEN_COMPUTER_USE_BACKGROUND_ONLY` | off | Never raise or activate an app. Opt-in for when the user keeps working. |
| `OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS` | off | Allow moving the real pointer. Off means never. |
| `OPEN_COMPUTER_USE_FOCUS_BORROW` | off | Allow focus borrowing when background-only and strict modes are off. |
| `OPEN_COMPUTER_USE_STRICT_BACKGROUND` | off | Require strict background delivery (settings key `strict_background`). |
| `OPEN_COMPUTER_USE_LEARNING_LOG` | on | Local training data in `~/.godspeed/learning` (2 GB cap, oldest days deleted first). Secrets, password fields and the clipboard are never written. `0` turns it off. |
| `OPEN_COMPUTER_USE_LEARNING_LOG_IMAGES` | on | Keep the window crops already sent to the local vision model. Never saved while a password field is visible. |
| `OPEN_COMPUTER_USE_SEMANTIC_REPLIES` | on | Add a `Changes:` line to longer change-only replies. `0` restores the previous text exactly. |
| `OPEN_COMPUTER_USE_AGENT_EVENTS` | on | Add popup, download and closed-tab lines from the Chrome extension to browser replies. |
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
| `OPEN_COMPUTER_USE_HANDOFF_HELPER` | on with a configured referee | Set to `0` to skip local chooser calls during handoff. |
| `OPEN_COMPUTER_USE_REFEREE_DONE_HINTS` | off | Optional model hints. `done_when` controls verified completion. |
| `OPEN_COMPUTER_USE_REFEREE_TIMEOUT_MS` | 1500 | Longest wait for a verdict. |
| `OPEN_COMPUTER_USE_REFEREE_MIN_CONFIDENCE` | 0.6 | Below this, no hint. |
| `OPEN_COMPUTER_USE_REFEREE_DONE_CONFIDENCE` | 0.86 | A `done` hint needs this. |
| `OPEN_COMPUTER_USE_REFEREE_MAX_VIEW` | 1200 | Maximum characters of state sent to the referee. |
| `OPEN_COMPUTER_USE_VISION_URL` | unset (off) | Loopback helper URL for find on screen. |
| `OPEN_COMPUTER_USE_VISION_TIMEOUT_MS` | 8000 | Longest wait for a vision answer. |

The local checker keeps the window title, focus and the lines most relevant to the goal. When it ranks actions, it also gets the candidate rows and nearby labels. The existing character limit still applies.

To enable vision, set `find_on_screen` to `true` in `~/.godspeed/settings.json`. Godspeed looks for a named accessibility control first. If none matches, it tries Apple Vision text recognition, then asks the local helper for a point. It checks the window, the current pixels and the accessibility hit before clicking. Risky or ambiguous visual targets require another route.

With vision enabled, a thin native window view can include a window-only picture up to 1280 pixels on its long side. This needs a loopback helper that advertises picture support. See [the local helper experiment](../experiments/LocalHelper/README.md).

Browser:

| Variable | Default | Meaning |
|---|---|---|
| `OPEN_COMPUTER_USE_BROWSER` | auto | `0` removes the `browser` tool. |
| `OPEN_COMPUTER_USE_OBU_BIN` | auto-detect | Absolute path to the Open Browser Use executable. Follow the [Chrome setup guide](INSTALL.md#chrome-setup). |
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

### Chrome relay authority key

The Chrome helper authenticates to the native host with a signed relay grant. Each GODSPEED install keeps its Ed25519 signing key in the login Keychain (service `com.godspeed.relay-authority`, this device only, never synced). The installer must provision only the public half on the host:

```sh
export OBU_RELAY_AUTHORITY_KEY="$("<GODSPEED app>/Contents/MacOS/OpenComputerUse" relay-authority-public-key)"
```

The command creates the Keychain key on first use and prints the public key as unpadded base64url. The private key is never printed. Without the provisioned key, the browser tool reports "Chrome helper needs the Godspeed relay key; run the installer." Grants last at most 15 minutes and the helper renews them on its own.

Grants are off by default, so today's Chrome helper keeps working unchanged. Turn them on only after installing the authenticated Chrome host with the key above: set `"relay_grant": true` in `~/.godspeed/settings.json` (or `OPEN_COMPUTER_USE_RELAY_GRANT=1`). With grants off, Godspeed never reads the Keychain key and sends no grant or renewal.

## Private clipboard

Each Godspeed client has an in-memory clipboard shared by its Mac and Chrome actions. In Mac apps, select text and use `press_key` with `cmd+c`, `cmd+x`, or `cmd+v`. In Chrome, use `browser` with `action: "copy"`, `"cut"`, or `"paste"`. To paste into a named field, pass its label. A single batch can alternate these actions between apps.

Use `clipboard` with `action: "read"`, `"write"` and `text`, or `"clear"`. The REPL equivalent is `cua.clipboard(action, text?)`. Clipboard text is in memory and limited to 1 MiB. A separate client has a separate clipboard. Reading or writing the clipboard directly leaves its contents out of trajectory capture.

Finder file copies go to the same private clipboard. Paste them into Finder or select them in a labelled Chrome file input. Finder cut moves files only in Finder. Editors must expose selection and input through Accessibility or Chrome. Secure field contents, rich formatting, and image clipboard pastes are outside this feature.

## Verified workflows

1. Read the active window or tab. Use a label that identifies one control.
2. Batch related steps with `done_when` set to the change you expect. Use `compact: true` for a shorter verified reply.
3. If the batch stops, use its recovery receipt. Inspect the current state before retrying a step whose effect is unknown.

Screenshots are available for controls that the accessibility tree misses. The optional decision helper is for ambiguous, goal-directed work. Routine reads and explicit completion checks can use the current observation directly.

Handoff fills a unique, empty field directly when its value matches the completion check. It can also act on an explicit `Click <label>` goal with one enabled, low-risk target. These matches use zero model calls for that action. If a choice remains, handoff ranks the most relevant 12 options before asking the local Referee chooser. The local helper uses d1-2B 8-bit by default. It hands control back if confidence or the lead over the next option is too low. A pinned handoff verifies against that window. If input may already have landed, it stops for inspection.

For an existing field value, pass `expected_values` alongside `values` and use an exact field check in `done_when`. For example, `expected_values: {"Name":"Before"}` and `values: {"Name":"After"}` pair with `done_when: {"field":"Name","equals":"After"}`. Godspeed checks the current value again just before writing.

For a longer workflow, put several `handoff` steps inside a `batch`. Give each handoff its own completion check and give the outer batch the final workflow check. The batch shares its deadline with each handoff and stops before dependent steps if any handoff cannot verify its result. Use the returned recovery details to resolve that step. Resume tokens are single-use and may ask for structured inputs again. Inspect any action with uncertain delivery before resuming.


### Completion checks

A batch takes a private baseline before step 1 for text, field, URL, and file checks that can distinguish a new result from a preexisting one. Use one check or a list.

| Check | Evidence |
| --- | --- |
| `{"appeared":"Message sent"}` | Text appeared in the same window or tab. Chrome checks visible text in the main document. |
| `{"disappeared":"Loading"}` | Previously visible text disappeared. |
| `{"field":"Volume","equals":"40","since_start":"changed"}` | One readable field in the same Mac window changed to the exact value. |
| `{"url_changed":"https://example.com/thanks"}` | An existing tab changed to the exact URL. |
| `{"file_changed":"~/Desktop/out.pdf"}` | A regular file appeared at the path or its size, fresh modification time, or contents changed. Files up to 16 MiB are hashed. |

A check that was already true in the baseline reports `weak_evidence`. A text, field, missing-label, URL, or new-file check that changes from false to true on the same target can be verified. Use `file_changed` for an existing file you expect to update. An unavailable baseline leaves a change unconfirmed. A UI change proves what Godspeed observed during the batch. Check the app's own receipt when you need to confirm that a send, payment, or save persisted.

Action readback looks for 120 ms of stable frames and checks for a busy Accessibility root. An explicit `settle_ms` read looks for 120 ms without an AX busy sign. It returns the current state with a status note if the budget runs out. A batch settle step requires repeated complete reads of the same state and stops on timeout.

### Saved recipes

Mutating recipes require verified `done_when` evidence. To replay, send the original `app` and exact `goal` without steps. Supply every recorded slot in `values`. Changed inputs, checks, or windows require fresh steps. Each write checks its label, role, and nearby controls again. Legacy recipes need a fresh verified run. Keep secrets out of completion conditions and use labels for steps you want to save.

Replay uses the same completion checks as an explicit batch. A presence-only check that already matches returns `weak_evidence` with zero steps run. Godspeed keeps the current version and one alternate in `~/.godspeed/recipes.json`. Two consecutive replay failures drop the current version. A verified alternate with the same inputs and checks can then take over.

### Delivery receipts

`OpenComputerUseKit.DeliveryState` is a public Swift `Codable` enum. Use its stable strings in journals and receipts. MCP replies expose `godspeed/delivery_state` and `godspeed/safe_retry` in `_meta`. Each batch step carries `delivery_state` and `safe_retry`. If the app agent times out before returning a tool response, the JSON-RPC error carries delivery in `error.data`.

| Delivery | Safe retry class | Meaning |
| --- | --- | --- |
| `not_sent` | `after_correction` | Input never went out. Correct the precondition first. |
| `outcome_unknown` | `reconcile_first` | Input may have reached the target. Inspect the current state before retrying. |
| `acknowledged` | `do_not_retry` | The action returned or the target acknowledged input. Check its effect if needed. |
| `verified` | `do_not_retry` | A readback or change-aware check confirmed the requested result. |

A batch stops on uncertain delivery. A completion check can still report what changed, and the affected step keeps its uncertain receipt.

MCP cancellation stops queued work and interrupts waits in a running batch or handoff. A disconnect also stops work for that connection. A cancellation reply lists the steps already attempted and the steps skipped. A step interrupted during delivery may have taken effect. Inspect it before trying again. A macOS call already in progress must return before Godspeed can finish cleanup.

Godspeed records a write step's intent before dispatch and its outcome afterward in `~/.godspeed/journal/operations.jsonl`. Records contain the tool name, timestamps and generated IDs. They omit arguments, replies and screenshots. After a restart, an intent without an outcome is `outcome_unknown`. Starting Godspeed never replays it.

## Cursor feedback

The visible cursor is feedback. Godspeed resolves and checks the target independently, keeps each agent's window anchor separate, and plays cursor motion on the display clock. If a path crosses a gap with no screen, it reappears beside the next target. The app never needs to move your physical pointer with the default background settings.

How the cursor moves:

- A move starts and lands with no jolt. It speeds up quickly, peaks a little before the middle and settles gently onto the target, like a hand aiming a mouse. The speed follows the path's real length, so curves don't speed up or slow down.
- Moves take about 0.15 s for a short hop and up to about 0.45 s across a screen. `cursor_speed` scales this.
- Hops under 48 pt travel straight. Longer moves bend into a shallow arc that grows with distance, so there is no sudden change of style. The arc stays on the display, also next to its edges and the menu bar.
- The arrow leans up to about 11° into a move, the same way for short and long moves. It is upright again when it lands. At rest it only breathes by about 2°.
- When a target window moves mid-flight, the cursor bends toward the new spot without a corner. Across offset displays it banks through the shared edges, over any number of displays. A display behind a real gap makes it reappear there instead.
- The name tag sits beside the arrow, just right of its tip. Next to a display's right or bottom edge it moves to the other side.

When many moves are queued before the next frame, Godspeed keeps the latest pending move for each agent. It preserves clicks and gestures in order. Each cursor can finish and fade on its own while other agents keep working.

Vercel's agent-desktop scopes references to the observed window and keeps cursor travel out of the window interaction lock. [Snapshot guide](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/apps/docs/content/docs/snapshots-and-refs.mdx) · [Cursor delivery](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/core/src/cursor_overlay/submit.rs)

## Teach by example

Use `teach` with `action: "start"`, an `app` and a one-sentence `goal`, then do the task yourself in that app. `stop` turns what you did into a recipe of labelled steps (never pixels or element numbers). Typed text becomes a slot, such as a recipient or a path, with your text as the example. `status` shows what has been recorded so far.

Only the target app is watched, and only while recording. Recording ends after 10 minutes or when the app quits. Text is kept only when it was typed into a confirmed plain text field of that app. Password and secret fields, secure input and anything that can't be confirmed are never recorded, and the clipboard is never read. A taught recipe starts unverified and replays on its own only after one run passes a `done_when` check.

Teaching needs macOS Input Monitoring for GODSPEED, in addition to Accessibility. Without it, `start` says so and records nothing.

## Native window and element identity

To inspect a known native window directly, pass its ID to `get_app_state`. This read does not move the window or use app-wide settle. For an exact native action target, take a fresh app observation and use its reported `Window ID` as `window_id` on a supported action or a single-app batch. Godspeed checks the same accessibility window it read, even if macOS lists another object for that window ID. If the window, its bounds or the required focus changes, Godspeed stops. Refresh the observation before trying again. In the JavaScript REPL, use `app.batch(steps, { windowId, doneWhen })` to execute a sequence and check the final state in one call. The reply includes a `receipt` with each step's status, the number of steps left and the completion verdict. Acknowledged actions and verified outcomes are reported separately.

Pass `include_refs: true` to `get_app_state` for exact native element refs. The reply lists refs beside their element numbers. Send a ref as `ref` on an element action in place of a label, index or pixel target. Ref clicks use the exact accessibility control and run in the background. A new observation of the app expires its previous refs. `STALE_REF` means to read the intended app again with `include_refs: true`. `WINDOW_CHANGED` means to confirm the intended window before acting. Both errors mean nothing was sent.

In the JavaScript REPL, use `app.getAXState({ includeRefs: true })` and pass `{ ref }` as the target. A failed action exposes its code on `error.code`.

For a known workflow, use `app.batch(steps, { windowId, doneWhen, compact: true, effects: false })`. Compact mode trims surplus plain text from the final reply after the checks run. Failed or incomplete batches keep their normal detail. Disabling effects skips per-step observation reads, so use it when the sequence needs only a final check.

For longer tasks, check `receipt.recovery` before resuming a partial batch. `refresh_then_continue` marks a step that never started, `fix_then_continue` marks an explicitly unsent failure, and `inspect_before_retry` means the action may have landed. `inspect_result` asks you to check the outcome without resending inputs. Recovery step numbers refer to expanded steps in the receipt, so a single form instruction can occupy several numbered steps.

## Browser observations

For a browser batch whose final success is a known URL, set `return_state: false` with a URL-only `done_when` (REPL option `returnState`). Use `url_changed` to confirm a transition to a full URL. Godspeed can return a passing receipt after reading the tab's address alone. A failed check keeps the normal recovery read.

Use `browser read` with `interactive: true` to find controls with fewer tokens. Use the default read when prose or confirmation messages matter. Interactive reads retain tab- and document-scoped references and can overlap across independent clients. Add `diff: true` on repeated, unfiltered browser reads for a smaller change summary. Godspeed returns the full view when the document, mode or reference mapping changes. Batch completion checks still use the full current observation.

Browser reads include reported focus, disabled, selected, checked and expanded states. Use these to confirm the control before asking for an image. If Chrome times out after `fill_field`, Godspeed can read back the exact value on the same control and document. A lookup timeout uses a full-tree fallback when the tab connection is still valid.

Godspeed enables simulated page focus and page hooks only in tabs it opened. A claimed user tab keeps its actual focus state.

Set `if_changed: true` on `browser screenshot` to avoid returning an identical capture. The comparison is exact and scoped to the client, tab, address, and browser helper generation. Godspeed keeps a digest in memory, not a saved image. In the REPL, `cua.browser("read", { tab_id: 12 })` uses the same persistent connection as native app bindings. `cua.batch(steps, options)` can alternate browser steps with native steps that each name their app. Keep dependent actions ordered and check the batch receipt before resuming. The REPL discards queued input from ended evaluations. Saved-recipe handoffs and final browser observations share the time left in the original operation.

Use `browser outline` for visible headings in the main document, `browser frames` for the tab's document tree, and `browser scroll_into_view` with a label or current reference to reveal one control. Frame listings are for inspection. Actions still need a control reference or label. A browser click can use the left, middle or right button. Left clicks accept a count of up to three. Clicks and drags accept Alt, Control, Command, or Shift modifiers. The click checks its hit point before sending input.

Use `browser read_text` for rendered text from a uniquely named control or region, or a current control reference. Use `browser link_destination` with a label or current reference to inspect an HTTP(S) link without clicking it. Add `include_link_urls: true` to a read for destinations that Chrome exposes in its accessibility tree. Use `browser control_state` with a label or current reference for visibility, enabled status and checked state when available. Visibility describes rendering. It does not guarantee the control is unobstructed. Use `browser value` with a field label or current reference to read one editable value. Password inputs return no value. Use `browser location` for the tab URL, title, and readiness without reading page content. Use `browser fill_field` to replace an ordinary editable value with one insertion. Use `type` for controls that need keyboard events. Use `browser wait_for` with `url_contains` for a redirect or confirmation page. Use `wait_for` with a `label` and `condition: "enabled"` to wait for a control. Other conditions are `visible`, `checked`, and `unchecked`. Use an explicit `tab_id` when multiple tabs are open.

For a file input with a visible label or current reference, pass it to `browser upload` along with readable absolute file paths. Godspeed sets the selection directly and checks the file count. The website's separate submit action controls whether anything is sent.

Use browser `close_tab` with the explicit `tab_id` returned by `open_tab`. Godspeed checks that the current session still owns the tab and that the browser reports it closed.

## Parallel browser work

While the Mac is unlocked, up to four different MCP clients can make read-only browser requests at once. Use the canonical `read`, `peek`, `info`, `tabs`, or `screenshot` action. An explicit `wait_for` of 1–3 seconds can also share admission. Each client has its own tab state and can have one read in flight. Native actions, mixed batches, and Locked Use recovery get exclusive access. Browser writes also run one at a time by default. Exclusive requests run in arrival order. A queued writer normally gets the next turn. When a reader has waited through two exclusive admissions, the oldest eligible reader gets a turn. One client cannot take multiple read slots. Set `OPEN_COMPUTER_USE_PARALLEL_READS` to 1, 2, 3, or 4 in the shared app agent environment to compare reader limits. The default is 3.

If the Mac session changes mid-read, Godspeed stops issuing browser commands and reports the interruption. Check the tab before retrying.

Only one peek group can load pages at a time in the app agent. A waiting group leaves room for other browser reads. Use `cua.peekPages(urls)` or `browser peek` for up to six URLs with one 40-second budget. Up to three workers reuse their own temporary tabs, take the next URL as soon as ready, and check cleanup before returning. Idle helpers expire after one minute. Replies keep input order and show each URL's status, text, and cleanup result.

The app agent accepts up to 32 connections and queues up to 32 admissions. Each connection can buffer up to 16 requests.

Set `OPEN_COMPUTER_USE_PARALLEL_BROWSER_WRITES=1` in the app agent's launch environment to allow two or more clients to scroll or fill a named field in different tabs. Each call must name its tab ID. The current helper must have opened that tab. The same tab and the same client still run one write at a time.

Local model calls release desktop admission while they wait for an answer. If another request takes admission in the meantime, Godspeed stops the interrupted workflow and asks for a fresh look. Calls skip the model during a focus borrow or Locked Use lease. The shared app agent uses an already-running model helper.

## Verified scroll chunks

Use `scroll` in a Mac window or Chrome tab. Pass `unit` with `lines`, `points`, or `pages`. Set `step_size` for lines or points. A page is one viewport chunk. For a longer search, set `until_visible` to the exact label and `max_steps` to a limit of 20 or less. Godspeed stops when the control is in view or the scroll position stops changing. The reply reports the number of chunks that moved.

In a Mac app, target an AX scroll area with a readable scroll bar. Whole pages use the app's AX page action. Lines and points use the specified wheel units. The app controls the resulting distance. In Chrome, a point is one CSS pixel and a line is 40 CSS pixels. Omit the scroll area's label to scroll the whole page. Chrome checks whether the label can be reached in the viewport.

Use `scroll_into_view` when you already know the control. Mac apps need to expose its AX scroll-to-visible action. In a batch, add `web: true` for Chrome. The original Mac `pages` and Chrome `amount` arguments still work on their own.

## Drag and reorder

Read both endpoints first. A Mac drag accepts `from_label` and `to_label`, or `from_index` and `to_index`. Either endpoint can be a pair of screenshot coordinates in the same window. In Chrome use `label` or `index` for the source and a control or viewport point for the destination. For a handle, target the handle itself. Set `hold_ms` up to 1000 and `drag_steps` from 2 to 30 if needed.

To move a row or card, drag to the destination and check the order or destination state. Set `verify` on the drag to check a condition after release, for example `{"label":"Card A","condition":"appears"}`. Use a batch `done_when` when the drop needs more checks. A pointer receipt confirms delivery only. For files, use Finder private clipboard copy and paste or Chrome `upload`. OS-level file drops can require the real pointer.

Open or select a tab and read its controls. For example, use `{"action":"drag","label":"Card A","to_label":"Drop zone"}` when both controls are visible in the same page. Read the tab after delivery to verify the drop. Apps can interpret pointer gestures differently.

## Local traces

Set `OPEN_COMPUTER_USE_DEBUG_TIMING=1` to record timings and counts for accessibility reads, screenshot encoding, Chrome calls and batch checks. These lines include byte counts without the contents.

Tool logs at `~/.godspeed/trajectories` record queue time, tool duration, action delivery, failures, batch steps and verification. They include local helper request counts, timing, and GSD1 outcomes by role when the helper is called. The default omits arguments, screen text and screenshots. Set `OPEN_COMPUTER_USE_TRAJECTORY_LOG=0` to turn logging off. For a local fixture, `OPEN_COMPUTER_USE_TRAJECTORY_FAILURES=1` adds a short error and argument shape. Review it before sharing because errors can include app names, filenames or controls. `OPEN_COMPUTER_USE_TRAJECTORY_CONTENT=1` captures typed text and observations.

Use `python3 scripts/godspeed-trace-summary.py` for aggregate timings and helper activity. To measure model quality, match recommendations to independently verified outcomes from the same run. Host-side model token usage comes from the host.

## Known limits

- macOS only. The app is built for the native arch. `obu` is built for arm64.
- Keep steps that share input or depend on each other's output in one ordered batch.
- The default cursor stays grey when agents overlap. Set a hex colour for a fixed custom tint, or set `OPEN_COMPUTER_USE_CURSOR_COLOR=auto` to opt into stable per-client colours.
- Background delivery depends on the app. Some dialogs, sheets and key chords require foreground input.
- A batch is at most 40 steps.
- The referee and vision are hints and fallbacks, off by default. Vision has been checked on one synthetic image, not on real apps.
- The browser tool needs Chrome, the Open Browser Use extension, and the one-time setup step. It cannot use other browsers.
- Model results are not measured yet. The fixed task set (steps, seconds, finish rate against Codex native) has not been run.
- Apps with no usable accessibility tree can be clicked only by vision. That needs `find_on_screen` on and the helper service running.

See [training fixtures](training-fixtures.md) for reviewed vision annotations and verified decision labels.

See the [macOS capability audit](macos-capabilities.md) for the boundary between Godspeed tools, app workflows, and other macOS interfaces.

### When macOS is locked

The public Godspeed package requires a signed-in, unlocked desktop for app controls, browser tools and screenshots. Its MCP connection can still answer `ping` and `tools/list` while the Mac is awake and the agent is running. For jobs that can run outside the desktop, use the app's supported API or command-line tools. After an interrupted desktop batch, unlock normally, read the current app state and resume from the last confirmed result.

Run `OpenComputerUse locked-use status --json` to check the installed build. The public package reports `not-packaged`.

If the physical Mac needs to stay locked during GUI jobs, see the [isolated macOS guest transport and validation guide](locked-host-guest.md). An Apple Silicon macOS guest is an option to test without a Developer ID certificate. Install Godspeed in the guest, grant its normal permissions there, and run the MCP client or its stdio launcher in the guest. Keep the guest desktop unlocked and the host awake for the job. Guest permissions, performance, and operation during host lock need a live check before relying on this setup. [Apple's macOS virtualization guide](https://developer.apple.com/documentation/virtualization/running-macos-in-a-virtual-machine-on-apple-silicon)


### Browser feedback and parallel jobs

The fork's page cursor reacts to acknowledged browser movement, press, drag, drop, click, text insertion and scroll. Feedback is sent only to an active matching tab and never delays the input reply. Intermediate moves can be coalesced. Hidden pages suppress the overlay. Near a display or viewport edge, the cursor follows a straight eased path to the action point. The web renderer shares interaction meanings with the Mac cursor.

Use independent browser connections for concurrent reads. Browser writes and native input retain exclusive admission while the app agent applies process-wide settings. A shared budget caps active preview loads, and each helper has one rescheduled idle timer. Compare end-to-end fixture timings and slow runs before promoting the candidate.

## JavaScript page API

In the REPL, `cua.browser.page(tabId?, { strictBackground? })` returns a Playwright-style page for one tab. Each method maps to one browser action, so policy and `strictBackground` apply as they do to raw calls. Methods: `goto`, `click`, `fill`, `type`, `press`, `hover`, `selectOption`, `check`, `uncheck`, `waitForText`, `waitForURL`, `waitForLoadState`, `textContent`, `title`, `url`, `screenshot`, and the locators `getByRole(role, { name })`, `getByLabel`, `getByText`, each with `click`, `fill`, `isVisible` and `textContent`.

Targets are visible labels. CSS selectors and `locator(selector)` return `UNSUPPORTED`, since the browser actions take no selectors. Matching is exact by default: a label or locator first reads the page for controls with that exact name, and returns `TARGET_NOT_FOUND` or `AMBIGUOUS_TARGET` before sending anything. Pass `exact: false` to use the browser's looser label matching. Locators are not cached. Each action reads the page again. `screenshot()` runs only when called. `waitForText` and `waitForURL` take `timeout` in milliseconds, up to 30000. A wait the page does not satisfy throws `TIMEOUT`.

Errors carry `error.code`. Driver codes pass through unchanged, including `STALE_REF`, `APPROVAL_REQUIRED` and `BACKGROUND_UNSUPPORTED`. Local codes are `UNSUPPORTED`, `INVALID_ARGUMENT`, `TARGET_NOT_FOUND`, `AMBIGUOUS_TARGET`, `TIMEOUT`, `PARSE_FAILED` and `TOOL_ERROR`. Browser actions target tabs, so `windowId` is `UNSUPPORTED`.

Precise additions: `click({anchor, offset, modifiers, clickCount, button})` (Playwright `Meta`, `Shift`, `Alt`, `Control` map to `cmd`, `shift`, `alt`, `ctrl`), `hover({dwellMs})` up to 2000 ms, `dragTo(target, {steps, holdMs, verify})`, `scrollIntoViewIfNeeded()`, `selectText({start, length} | text)`, `mouse.wheel(dx, dy)` as point-unit chunks, `scroll({direction, unit, amount, maxSteps, untilVisible})`, `keyboard.press(key, {holdMs})`, `zoom("in" | "out")`, `goBack()` and `goForward()`. Browser clicks have no coordinates, so `click({position})` is `UNSUPPORTED`.

The same precision applies to `cua.app(name)` (no state read): `scroll({direction, unit, amount, maxSteps, untilVisible, target})`, `click(target, {anchor, offset, modifiers, clickCount, button})`, `drag(from, to, {steps, holdMs, verify})` where each end is `[x, y]`, a label or an element number, `hover(target, {dwellMs})`, `selectText(target, {start, length} | text)`, `waitFor(label, {condition, timeout, fromValue})` (timeout in seconds, 1 to 30), `pressKey(key, {holdMs})` and `gesture(name, {target | menuPath})`. Limits match the driver; anything outside them throws `INVALID_ARGUMENT` before a call is sent. Shared mapping lives in `scripts/node-repl/precise-actions.mjs`.

## Precise clicks

Use `anchor` with `center`, `left`, `right`, `top` or `bottom` on a control. Optional `offset_x` and `offset_y` move right and down from that point. The target point must still hit the control. Mac offsets are window points. Chrome offsets are CSS pixels. Chrome needs the control in the main frame for precise clicks.

Click with `modifiers` such as `["cmd"]` to toggle an item, or `["shift"]` to extend a selection from an item you have already selected. The app defines which ranges it supports. Use `click_count: 2` or `3` on a left click. In a Mac app, supply the control for a triple click. Read back selected rows or text to confirm the result.

Use `mouse_button: "right"` to open a context menu. Read the resulting state, then click the observed menu item by reference if the app or website exposes it. Chrome's own context menu requires its native window. Web pages can expose their own menu inside the tab.

## Wait for a control

Use `wait_for` with a label, a timeout of 1 to 30 seconds, and `condition` set to `appears`, `disappears` or `value_changed`. Use the same step names in Mac and web batches. The label is checked in the window or tab's accessibility tree. An incomplete read cannot confirm absence.

For `value_changed`, give `from_value` to compare against a value you read before the previous action. Without it, the wait starts from the first value it reads. Secure fields are excluded. Set a separate completion check if a specific value matters.

## Select text

Use `select_text` with exact `text`. Add `prefix` or `suffix` for repeats. For an exact range, supply `start` and `length` in UTF-16 units. A zero-length range places the cursor. Give a control label or reference. Godspeed checks the field value and reads back the selected range.

Mac apps need a writable accessibility text range. Chrome supports plain inputs and text areas that expose a selection range. A password field or a custom editor can refuse this action.

## Hover

Use `hover` with `dwell_ms` up to 2000 for a delayed tooltip or hover menu. Read the result or wait for the expected control. Some Mac apps only show tooltips under the real pointer.

## Hold a key

Use `press_key` with `hold_ms` up to 1000 to send one key-down and key-up with a pause. Chrome targets its own tab. Mac holds require the observed window to already have focus, and Godspeed leaves focus where it is. Clipboard shortcuts still use the private clipboard.

## Gesture equivalents

Use `gesture` for pinch, zoom, rotate, or history navigation. In a Mac app, give a zoom control that exposes increment or decrement, or the app's explicit `menu_path` for an equivalent action. Menu commands act at app level. Pair them with a check when the resulting state matters.

In Chrome use `swipe_back` or `swipe_forward` for the tab's history. Use `pinch_out` or `zoom_in` to increase the page scale and `pinch_in` or `zoom_out` to decrease it. The reply verifies the resulting scale. Raw multitouch, smart zoom and rotation need an app command or real trackpad input. The tool returns `BACKGROUND_UNSUPPORTED` when it has no safe route. [Apple trackpad events](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingTouchEvents/HandlingTouchEvents.html), [Chrome page scale command](https://chromedevtools.github.io/devtools-protocol/tot/Emulation/#method-setPageScaleFactor)
