# Godspeed

**Background computer use for macOS agents.** Drive Mac apps and Chrome from Claude Code, Codex, or any stdio MCP client. Godspeed starts with accessibility and page structure, batches familiar actions, and returns the app state needed to check what changed.

- **Desktop** · Read controls, type into the live editor, and verify changes with a fresh observation. The background launcher keeps the real pointer and keyboard focus with you.
- **Chrome** · Use semantic browser controls through Open Browser Use. Each client gets its own tab session. Peek reads several independent URLs in parallel.
- **Small models** · Group actions with `batch`, target controls by name or identifier, and describe a verifiable `done_when`. Screenshots are available on request.
- **Visible feedback** · A separate cursor moves to the target and gives clicks a short pulse. Reduce Motion keeps the cursor still between targets.
- **Local measurements** · Compact tool receipts make failures, latency, and helper activity inspectable. Your desktop content stays out of the default log.

## Install on macOS

Godspeed targets macOS 14 and newer. Build from source with Xcode and Swift 6.2 or newer.

```sh
git clone https://github.com/fortun8te/godspeed.git
cd godspeed
./scripts/package-godspeed.sh
mkdir -p "$HOME/Applications"
ditto -x -k "dist/godspeed/Godspeed-macOS-$(uname -m).zip" "$HOME/Applications"
```

If you're upgrading, end active Godspeed sessions first and move the previous app bundle aside before extracting the replacement. Launch Godspeed once and grant Accessibility in System Settings. Grant Screen Recording if you want screenshot-based actions. The source packager signs locally for development. A notarized download will appear on the [Releases page](https://github.com/fortun8te/godspeed/releases) when available.

### Connect your agent

From the checkout, use the background launcher with either client.

```sh
codex mcp add godspeed -- "$PWD/scripts/godspeed-mcp"
claude mcp add --scope user godspeed -- "$PWD/scripts/godspeed-mcp"
```

Open a new agent session and ask it to use Godspeed to list apps. Start with a disposable app or document. Specify the app and the result you want checked. If you installed the bundle elsewhere, set `GODSPEED_APP` in the client's server environment.

### Connect Chrome

Install the Open Browser Use CLI and Chrome extension using the [upstream setup guide](https://github.com/iFurySt/open-browser-use). Run `obu setup` for the Chrome profile you intend to automate and verify it with `obu ping`. Put `obu` in your agent's PATH or set `OPEN_COMPUTER_USE_OBU_BIN` to its executable. Godspeed's native Mac tools work independently of Chrome.

### Privacy and performance

By default, telemetry stays on your Mac and records timing and outcomes without UI text, tool arguments, or screenshot bytes. Review the [settings and tool guide](docs/GODSPEED.md) before collecting training fixtures. For production workflows, check the actual final state before replaying any partial action.

Fewer round trips and text-first reads remove work from routine calls. Speed, input tokens, and task success depend on the model, workflow, and app. The [verification plan](docs/exec-plans/active/20261118-godspeed-workflow-reliability.md) describes how to compare the same tasks across tools.

## License

MIT. Godspeed is based on [Open Computer Use](https://github.com/iFurySt/open-computer-use). Chrome automation uses [Open Browser Use](https://github.com/iFurySt/open-browser-use). [Third-party notices](THIRD_PARTY_NOTICES.md) cover bundled dependencies.
