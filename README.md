<p align="center"><img src="assets/app-icons/godspeed-1024.png" width="88" alt="Godspeed's red glass cursor icon"></p>
<h1 align="center">Godspeed</h1>
<p align="center">Background computer use for macOS and Chrome.<br>Accessibility-first desktop automation for Codex, Claude Code, and other MCP clients.</p>
<p align="center"><a href="#install">Install</a> · <a href="#how-it-works">How it works</a> · <a href="docs/benchmarks.md">Benchmarks</a> · <a href="CHANGELOG.md">Changelog</a></p>

Godspeed lets an agent read a Mac window, find controls by name, and run a sequence of actions with a final check. It serves those tools over the Model Context Protocol (MCP). With the supplied background launcher, Godspeed keeps the user’s physical pointer free and refuses actions that require taking focus.

![Two Godspeed cursor paths rendered on a simulated desktop from the production motion planner](docs/media/cursor-motion.gif)

*Motion rendered from Godspeed’s production cursor planner on a simulated desktop.*

## Install

The **v1.1.12 development download** targets **Apple Silicon Macs running macOS 14 or later**. It includes the app and a stable MCP launcher. It uses ad hoc signing. See the [installation guide](docs/INSTALL.md) for macOS permissions, Gatekeeper, upgrades, and source builds.

Download the installer from the release, then run it:

```sh
curl -fLO https://github.com/fortun8te/godspeed/releases/download/v1.1.12/install-godspeed.sh && bash install-godspeed.sh
```

The installer shows download progress and checks the archive’s SHA-256 before installing. Open **GODSPEED.app** from `~/Applications` and follow its permission screen. Register the MCP launcher with your client, then open a fresh agent session.

```sh
# Codex
codex mcp add godspeed -- "$HOME/.local/bin/godspeed-mcp"

# Claude Code
claude mcp add --scope user godspeed -- "$HOME/.local/bin/godspeed-mcp"
```

For Chrome, add the optional [Open Browser Use](https://github.com/iFurySt/open-browser-use#quick-start) helper and extension. The [Chrome setup guide](docs/INSTALL.md#chrome-setup) covers installation, enrollment, and how to check the extension bridge.

## How it works

- **Read the current target.** Native tools use macOS Accessibility data. Query by label for a small result, or read the window when you need the surrounding controls. Screenshots and visual targeting are available with Screen Recording permission.
- **Send related steps in one batch.** Bind actions to the observed window or control, then set a visible result to check with `done_when`. A compact reply can keep only the information needed for the next decision. Detailed recovery receipts stay available when input delivery is uncertain.
- **Check before continuing.** Godspeed separates action dispatch from evidence that the action worked. Resume tokens keep unfinished native steps tied to their saved window and preserve the original step numbers across repeated resumes.
- **Give each agent a visible cursor.** The software cursor shows where a client is working. Client names and cursor effects are configurable. The [tool guide](docs/GODSPEED.md#cursor-and-client-names) explains naming, visual feedback, and background limits.
- **Use local decisions when needed.** The optional GSD1 helper exposes Action, Read, and Recover as advisory models through `local_decision`. They share one tuned checkpoint slot. Godspeed’s tool checks still govern dispatch and verification. [Model setup](experiments/LocalHelper/README.md) · [GSD1 adapter weights](https://github.com/fortun8te/godspeed/releases/tag/gsd1-v0.1.0)

## Examples

| Ask your agent | Godspeed uses |
| --- | --- |
| “Multiply 1234 by 56 in Calculator and verify the display.” | A native batch and a checked result |
| “Read the headings of these public pages in Chrome.” | The browser bridge and a bounded parallel read |
| “Move the selected control to the marked position in this window, then check the result.” | A targeted drag and a separate outcome check |

The default trajectory logs record timings and outcome metadata locally. See the [trace controls](docs/GODSPEED.md#local-traces) for content logging and what to review before sharing a trace.

See [benchmarks](docs/benchmarks.md) for reproducible payload measurements and the public CUA Driver, Codex Computer Use, and Aside comparison. Godspeed’s internal fixtures have a different workload from that public suite.

## Project

[Releases](https://github.com/fortun8te/godspeed/releases) · [Installation](docs/INSTALL.md) · [Tool guide](docs/GODSPEED.md) · [Changelog](CHANGELOG.md) · [Issues](https://github.com/fortun8te/godspeed/issues)

Godspeed’s app source is [MIT-licensed](LICENSE) and based on [Open Computer Use](https://github.com/iFurySt/open-computer-use). GSD1 model weights use the LFM Open License v1.0. [Third-party notices](THIRD_PARTY_NOTICES.md)
