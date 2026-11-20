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
