# Local helper experiments

Run the offline comparison from the repo with:

```sh
python3 experiments/LocalHelper/eval.py --output /tmp/godspeed-local-eval.json
```

The runner only connects to the existing helper at `127.0.0.1:8765`. It skips when the helper is unavailable. It makes sequential requests and records the checkpoint reported by `/health`. It never starts a helper. The Swift fixture test exports requests made with the same view builders Godspeed uses. Use `--skip-build` after building those tests.

The tree fixtures are synthetic. The calculator and form lines follow the headless scenario bank. Mail, Finder, Settings and the web page use scrubbed, hand-authored trees. Each app family belongs to one split. The PNGs are drawn fixtures. No screen capture or live app is needed.

The runner compares top choices, abstention at the existing cutoffs, and wall time. It fits exploratory cutoffs on the dev families before sending any held-out requests. A fit needs three correct accepted dev examples and no incorrect accepted examples. The benchmark never writes runtime settings. OCR and model grounding are scored by whether the proposed point lands inside the labelled box. Native AX hit-testing and click delivery are outside that measurement.

See [the first run](RESULTS.md) for the measured results.

## Optional decision pictures

`decision-images.patch` applies to a separate copy of `server_mlx.py`. It adds the optional `image_base64` field to `/choose` and `/decide` and advertises support through `/health` as `"decision_image": "v1"`. It accepts JPEG or PNG up to 1280 pixels on either side and 1 MiB before base64 encoding. Invalid media falls back to text. Replies keep their existing shape.

Check the patch on a staging copy:

```sh
staging=$(mktemp -d)
cp ~/.ocu-referee/server_mlx.py "$staging/server_mlx.py"
patch -d "$staging" -p1 < experiments/LocalHelper/decision-images.patch
python3 -m py_compile "$staging/server_mlx.py"
```

The current helper keeps serving text-only requests. The comparison records native OCR and `/locate` separately. It takes a helper with the patch applied to measure d1's picture accuracy.

## Optional GSD1 on Apple Silicon

From a Godspeed v1.1.12 source checkout, run `./scripts/setup-gsd1.sh` with native arm64 Python 3.10 or newer. The installer downloads the published [GSD1 adapters](https://github.com/fortun8te/godspeed/releases/tag/gsd1-v0.1.0), verifies their SHA-256, downloads pinned base checkpoints with progress, and converts the adapters locally. Allow roughly 14 GB of free storage for the base files, runtime and all three outputs. The regular Godspeed installer skips this download.

The setup adds a loopback helper on port 18765. In a fresh MCP session, `local_decision` can score typed Action, Read and Recover questions. Only one tuned checkpoint stays loaded at a time and idle checkpoints unload. The helper binds locally, and the tool yields recommendations for existing Godspeed actions and verification. First use may return no recommendation while the helper starts. If needed, check `curl -fsS http://127.0.0.1:18765/health`.

The adapter and base artifacts carry Liquid AI's LFM Open License terms. See the model release's LICENSE and NOTICE.
