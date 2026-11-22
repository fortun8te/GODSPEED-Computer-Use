# Install Godspeed on Apple Silicon

The v1.1.12 development ZIP targets Apple Silicon and macOS 14 or later. You need no Xcode installation to run the ZIP. Source builds need Xcode with Swift 6.2 or newer. Chrome and the local decision models are optional.

## Download and install

1. Download and run the installer from a terminal.

   ```sh
   curl -fLO https://github.com/fortun8te/godspeed/releases/download/v1.1.12/install-godspeed.sh && bash install-godspeed.sh
   ```

   It shows progress, verifies the archive hash, and installs the app at `~/Applications/GODSPEED.app` and the launcher at `~/.local/bin/godspeed-mcp`. The [release page](https://github.com/fortun8te/godspeed/releases/tag/v1.1.12) also has the ZIP and its SHA-256 file for manual verification.

2. Open **GODSPEED.app** and follow the permission screen. Accessibility enables native app controls. Grant Screen Recording if you want screenshots or visual targeting. macOS may ask you to quit and reopen after a permission change.

3. Register the launcher using its absolute path, then open a new client session.

   ```sh
   codex mcp add godspeed -- "$HOME/.local/bin/godspeed-mcp"
   claude mcp add --scope user godspeed -- "$HOME/.local/bin/godspeed-mcp"
   ```

   Use the line for your client. For another MCP client, configure a local **stdio** server with `$HOME/.local/bin/godspeed-mcp` as its command, expanding `$HOME` to your home directory if the client expects a literal path. The launcher sets background-only mode and disables focus borrowing and global pointer fallbacks.

### Signing and permissions

The public ZIP is an **ad hoc signed development build**. A fresh Mac may show a Gatekeeper warning. Verify that the archive came from the release and that its checksum matches. If macOS offers **Open Anyway** under **System Settings → Privacy & Security**, use it only after you’ve verified the download and chosen to trust it. Leave normal macOS protections enabled. Signing and permission behavior can vary by Mac and by OS policy. [Apple guidance on opening apps](https://support.apple.com/en-us/102445)

macOS may require a fresh permission grant after replacing a development build. If native tools report permission problems after upgrading, check the current copy’s entries in Accessibility and Screen Recording, then reopen the app and reconnect to MCP.

### Manual download and verification

Save both [Godspeed-macOS-arm64.zip](https://github.com/fortun8te/godspeed/releases/download/v1.1.12/Godspeed-macOS-arm64.zip) and [Godspeed-macOS-arm64.zip.sha256](https://github.com/fortun8te/godspeed/releases/download/v1.1.12/Godspeed-macOS-arm64.zip.sha256) in the same directory. Verify before extracting.

```sh
shasum -a 256 -c Godspeed-macOS-arm64.zip.sha256
```

The installer sets up the portable launcher, so use it for the complete setup. After installation, you can inspect the package you’re running:

```sh
codesign --verify --strict --deep "$HOME/Applications/GODSPEED.app"
file "$HOME/Applications/GODSPEED.app/Contents/MacOS/OpenComputerUse"
```

Look for `arm64` in the binary architecture. Before an upgrade, let active Godspeed sessions finish and close their connections. If the installer still sees a running process, quit GODSPEED.app and rerun it. Reopen your MCP client session afterward so its connection points to the current app.

## First MCP check

Open a fresh session after registering the MCP launcher. Check that your client lists Godspeed and tools such as `get_app_state` and `batch`.

For a terminal protocol check, run the [MCP smoke test](../scripts/tests/godspeed-mcp-smoke.py) with Python 3 from a source checkout:

```sh
python3 scripts/tests/godspeed-mcp-smoke.py
```

It keeps the connection open until both initialization and the tool list arrive. It sends no UI action. For a first live check, use a disposable app window with the Mac unlocked. Ask the agent to read it before acting and check a visible result after its first action.

If the wrapper cannot find the app, check that you installed one copy where expected. For a nonstandard app location set `GODSPEED_APP` to the absolute app bundle path in the MCP client’s environment. If an old connection stopped responding after an upgrade, start a fresh client session.

## Chrome setup

Native app tools work on their own. Chrome needs the [Open Browser Use CLI and extension](https://github.com/iFurySt/open-browser-use#quick-start).

1. With Node.js and npm available, install the CLI and run its setup.

   ```sh
   npm install -g open-browser-use
   obu setup
   ```

   Setup registers the native messaging host and opens the Chrome Web Store. Install or enable the extension in the profile you will use. Restart Chrome if it asks you to.

2. Open that Chrome profile and verify the bridge.

   ```sh
   obu ping
   ```

3. Reconnect your MCP client. Confirm that `tools/list` includes `browser`, then try a read in a disposable tab.

If npm installed the long executable name only, try `open-browser-use setup` and `open-browser-use ping`. If the CLI works in your terminal and the MCP client omits `browser`, the client may have a different shell path. Use `command -v obu` (or `command -v open-browser-use`) and set `OPEN_COMPUTER_USE_OBU_BIN` to that executable’s **absolute path** in your client’s MCP environment. Remove or correct a stale path before reconnecting. If `ping` itself fails, check that the extension is enabled in the current profile and rerun setup.

The [upstream setup guide](https://github.com/iFurySt/open-browser-use#quick-start) includes the Homebrew alternative and the keyed extension ZIP fallback. Keep the CLI and extension versions compatible. For background and browser access details, see the [tool guide](GODSPEED.md#browser-observations).

## Optional local models

The app download contains the driver. Install the optional helper using the [local model setup guide](../experiments/LocalHelper/README.md), then reconnect to MCP. The separate [GSD1 adapter release](https://github.com/fortun8te/godspeed/releases/tag/gsd1-v0.1.0) contains Action, Read, and Recover weights and an MLX export script. Use the base checkpoints from Liquid AI under the accompanying license. The models are local advisory tools. Ordinary app and Chrome operations can run without them.

## Build from source

Install Xcode with Swift 6.2 or newer, then:

```sh
git clone https://github.com/fortun8te/godspeed.git
cd godspeed
GODSPEED_ARCH=arm64 ./scripts/package-godspeed.sh
```

The build writes a signed development ZIP and its checksum in `dist/godspeed`. For a checkout-based MCP connection, point your client at the absolute path to `scripts/godspeed-mcp`.
