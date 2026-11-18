# GODSPEED

Godspeed is a macOS computer-use server for local agents. It handles Mac apps through accessibility and Chrome through Open Browser Use. The app runs as an accessory without a Dock icon.

The desktop implementation lives in `packages/OpenComputerUseKit`. See the [verification plan](exec-plans/active/20261118-godspeed-workflow-reliability.md) for current coverage.

## How a call flows

```
agent (TIANWANG, SuperApp Pi, Codex)
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
| `get_app_state` | The app's numbered element tree (`App=` text). Screenshot only when asked. |
| `click`, `type_text`, `press_key`, `set_value`, `select_text`, `scroll`, `drag`, `perform_secondary_action` | Element actions by `label` (visible text) or `element_index`. |
| `press_menu` | Chooses a menu item in one call, e.g. `path: "File > Save"`, through accessibility. |
| `query` | Finds elements by text or role. |
| `list_apps` | Recently used apps. |

## Batch features

- **Steps**: each step is a tool name plus arguments. Spelling is forgiving (`type` → `type_text`, `key` → `press_key`, and so on). A missing `app` is filled from the last app used.
- **Labels**: name elements by their visible text, not by index. Indexes still work.
- **Fill**: `{"tool": "fill", "fields": {"To": "sam@x.com"}, "submit": "Send"}` becomes one `set_value` per field and a click. Add `"web": true` for a page.
- **Goal**: `goal` is one sentence. The reply may add a `Check:` line (done, stuck, or still loading) from the referee. Treat it as a hint.
- **Recipes**: send `remember: true` with a goal that reached it. Later, send only `goal` and the saved steps replay. Steps with element numbers or coordinates are never saved. A recipe that fails twice in a row is dropped.
- **Change-only replies**: the final read is compared with what the model last saw for that app. Only changed lines are sent. If an element's number moved, the full state is sent instead. If nothing changed, the reply says so.
- **Condensed trees**: long rows are collapsed, text is cut at 160 characters, and container noise is dropped. Every element number the model can act on stays the same.
- **Referee and vision hooks**: both are off by default (see settings). The referee adds one hint line. Vision finds a labelled element on a screenshot when no accessibility element matches, then clicks there.
- **Browser**: `browser` with `action`: `open`, `go`, `read`, `click`, `type`, `key`, `peek` (up to 6 URLs, 3 parallel lanes), `tabs`, `use_tab`, `wait`, `info`, `upload`. Click and type use the Chrome DevTools Protocol on that one tab, so the tab the user is reading is never touched.

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
| `OPEN_COMPUTER_USE_DEFAULT_SCREENSHOT` | off | Screenshot with every read (settings key `screenshots_by_default`). |
| `OPEN_COMPUTER_USE_AX_COMPACT` | on | Short role spellings in the tree. `0` = older long spellings. |
| `OPEN_COMPUTER_USE_AX_INDENTATION` | `level` | `tab4` for four-space indent (opt-in). |
| `OPEN_COMPUTER_USE_MAX_COLLECTION_ROWS` | 20 | Visible rows kept per list, table or outline. |
| `OPEN_COMPUTER_USE_ACTION_READ_BACK` | on | Read the window back after an action. |
| `OPEN_COMPUTER_USE_SETTLE_BY_FRAME` | on | Stop waiting when the window stops changing. |
| `OPEN_COMPUTER_USE_BACKGROUND_ONLY` | off | Never raise or activate an app. Opt-in for when the user keeps working. |
| `OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS` | off | Allow moving the real pointer. Off means never. |
| `OPEN_COMPUTER_USE_FOCUS_BORROW` | on | Focus borrowing (see above). |
| `OPEN_COMPUTER_USE_RECIPES` | on | Saved recipes (settings key `recipes`). |
| `OPEN_COMPUTER_USE_VIRTUAL_DISPLAY_ENABLED` | off | Adds `window_placement` to `get_app_state`. |
| `OPEN_COMPUTER_USE_AGENT_SOCKET_NAMESPACE` | none | Separate socket for tests (`godspeed-agent-<hash>.sock`). |

Cursor:

| Variable | Default | Meaning |
|---|---|---|
| `OPEN_COMPUTER_USE_VISUAL_CURSOR` | on | Show the cursor (settings key `cursor_visible`). |
| `OPEN_COMPUTER_USE_CURSOR_COLOR` | original grey | `#RRGGBB` (settings key `cursor_color`). |
| `OPEN_COMPUTER_USE_CURSOR_SPEED` | 4 | 2 calm, 4 normal, 8 fast, `instant` (settings key `cursor_speed`). |
| `OPEN_COMPUTER_USE_CURSOR_FLOAT` | off | Draw above every window. |
| `OPEN_COMPUTER_USE_CURSOR_IDLE_HIDE_SECONDS` | 3 | Seconds before the idle cursor fades. |
| `OPEN_COMPUTER_USE_CURSOR_ASYNC` | on | Queue cursor animation on the main thread. Env only. |

Helpers (referee and vision):

| Variable | Default | Meaning |
|---|---|---|
| `OPEN_COMPUTER_USE_REFEREE_URL` | unset (off) | Helper service base URL, e.g. `http://127.0.0.1:8765`. |
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

## Local traces

Tool logs at `~/.godspeed/trajectories` record timings, tool errors, failed batch steps and helper receipts. Arguments, screen text, and screenshots are omitted by default. Turn logging off with `OPEN_COMPUTER_USE_TRAJECTORY_LOG=0`. Only set `OPEN_COMPUTER_USE_TRAJECTORY_CONTENT=1` on an approved fixture connection. That captures typed text and observations. Review those files before using or sharing them.

Use `python3 scripts/godspeed-trace-summary.py` for aggregate timings and helper activity. A helper receipt records that the helper ran. Match verified fixture outcomes to exact run streams before using them as labels.

## Known limits

- macOS only. The app is built for the native arch. `obu` is built for arm64.
- The Mac app agent processes one tool request at a time across clients. A browser `peek` loads up to three pages in parallel within one request.
- Background delivery depends on the app. Dialogs, sheets and some key chords need focus borrowing.
- A batch is at most 20 steps. `peek` takes at most 6 URLs with a shared 40-second browser budget. It reports pages it could not load or read.
- The referee and vision are hints and fallbacks, off by default. Vision has been checked on one synthetic image, not on real apps.
- Recipes match the exact goal text. They are stored only on this Mac (`~/.godspeed/recipes.json`).
- The browser tool needs Chrome, the Open Browser Use extension, and the one-time setup step. It cannot use other browsers.
- Model results are not measured yet. The fixed task set (steps, seconds, finish rate against Codex native) has not been run.
- Apps with no usable accessibility tree can be clicked only by vision. That needs `find_on_screen` on and the helper service running.

See [training fixtures](training-fixtures.md) for reviewed vision annotations and verified decision labels.
