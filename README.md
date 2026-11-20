<p align="center"><img src="assets/app-icons/godspeed-1024.png" width="88" alt="Godspeed's red glass cursor icon"></p>
<h1 align="center">Godspeed</h1>
<p align="center">Background computer use for Mac apps and Chrome.<br>For Codex, Claude Code, and other MCP clients.</p>
<p align="center"><a href="#install">Install</a> · <a href="#examples">Examples</a> · <a href="docs/benchmarks.md">Benchmarks</a> · <a href="docs/GODSPEED.md">Tool guide</a></p>

Godspeed reads controls by name, runs related actions in one call, and checks what changed. When more than one client is working, each software cursor shows a short client name. Godspeed leaves the physical pointer alone with the background defaults below.

## Install

**macOS 14 or later.** Build the development package with Xcode and Swift 6.2 or newer.

```sh
git clone https://github.com/fortun8te/godspeed.git
cd godspeed
./scripts/package-godspeed.sh
mkdir -p "$HOME/Applications"
ditto -x -k "dist/godspeed/Godspeed-macOS-$(uname -m).zip" "$HOME/Applications"
```

Open **GODSPEED.app** and follow the permission screen. Accessibility enables app control. Screen Recording enables screenshots and visual targeting. When upgrading, close active Godspeed sessions and move the previous app aside before extracting the new version.

Register Godspeed from the checkout, then open a fresh agent session.

```sh
codex mcp add godspeed -- "$PWD/scripts/godspeed-mcp"
claude mcp add --scope user godspeed -- "$PWD/scripts/godspeed-mcp"
```

Godspeed recognizes Codex, Claude Code, Cursor and OpenCode from MCP initialization. Other clients get a numbered `Agent` label when they overlap. To name a particular connection, set `OPEN_COMPUTER_USE_CURSOR_NAME` in that client's MCP environment. See the [cursor settings](docs/GODSPEED.md#cursor-and-client-names).

For Chrome, install [Open Browser Use](https://github.com/iFurySt/open-browser-use) and its Chrome extension. Run `obu setup` and check `obu ping`. Godspeed can also find the helper through `OPEN_COMPUTER_USE_OBU_BIN`.

## Examples

| Ask your agent | Godspeed uses |
| --- | --- |
| “Use Calculator to multiply 1234 by 56. Verify the result.” | One native batch with a fresh Calculator read. |
| “Open these public URLs in separate tabs and read their headings.” | Chrome `peek` with up to three parallel reads. |
| “Drag the selected control to the marked position in the same window.” | A targeted mouse-down, move, and release. Check the result in the app. |

Tool replies are text-first. Ask for a screenshot when you need a visual target. Local logs record timings and outcomes by default. [Training fixtures](docs/training-fixtures.md) explains how to collect reviewed data.

For longer workflows, give a batch one visible result to check. After a partial result, inspect the current app state before resending any step whose delivery is uncertain. The [workflow guide](docs/GODSPEED.md#verified-workflows) shows the request shape and recovery signals.

## Project

Development builds are locally signed. Follow [Releases](https://github.com/fortun8te/godspeed/releases) for distribution updates, and use [Issues](https://github.com/fortun8te/godspeed/issues) for reproducible failures.

MIT. Based on [Open Computer Use](https://github.com/iFurySt/open-computer-use). [Third-party notices](THIRD_PARTY_NOTICES.md).
