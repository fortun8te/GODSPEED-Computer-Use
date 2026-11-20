# Learn from fixture failures

Use outcome-only receipts to find a failure worth recreating. Add a disposable headless fixture with a known starting state and check what it actually changed. Train a candidate on the PC, compare it on the Mac, and change the live helper only after Michael reviews the report.

## Make the PC package

From the repo root, run:

```sh
stage=$(mktemp -d "${TMPDIR:-/tmp}/godspeed-learning.XXXXXX")
GODSPEED_LEARNING_OUTPUT="$stage" swift test --jobs 2 --filter 'HeadlessScenarioBankTests/testLearning'
python3 -I scripts/flywheel/flywheel.py package "$stage/learning.jsonl" "$stage/godspeed-training-v1.zip"
python3 -I scripts/flywheel/flywheel.py eval --dry-run --report "$stage/d1-dry-run.md"
python3 -I scripts/flywheel/flywheel.py eval --track lfm --dry-run --report "$stage/lfm-dry-run.md"
```

The export requires `GODSPEED_LEARNING_OUTPUT` and runs inside XCTest. It uses synthetic state and the driver's `BatchEffects`, `DoneCheck`, and secure-field redaction. It records a decision and a click-effect check for each case. The fixture provides window identity, a simulated file result where needed, and known changes. Cases include a disabled control, a click that never opens a dialog, a look-alike button, an unrelated window showing success text, a staged value that never commits, and repeated failures.

The packer checks the reviewed fixture digest and the exact trainer row format. The ZIP contains 128 training, 64 validation, and 64 PC test rows across eight task families. The frozen Mac evaluation has 128 d1 rows across four different families. Keep it out of training and threshold tuning. The LFM track has nine frozen grounding queries across three synthetic layouts, with nine development queries in `grounding-development.json`. The images are drawn fixtures, and the labels give a normalized target box or an absent target.

To count failures in a JSONL file already reviewed as metadata-only, run `python3 -I scripts/flywheel/flywheel.py counts /path/to/reviewed-metadata.jsonl`. This reports counts only. An unchanged view in an old batch receipt cannot tell which tool or target was involved. Recreate that failure in a fixture before using it as a label. When adding fixtures, review the generated rows and update `fixture-input.sha256` for the new package version. Keep the existing held-out families and files frozen for comparisons within that version.

## Train d1 on the PC

Copy the ZIP to the PC. In PowerShell, use the existing `C:\Users\micha\godspeed-train` checkout, CUDA Python environment, and `d1pkg` base. Read the config from the ZIP and verify the staged files before running the existing trainer.

```powershell
Set-Location 'C:\Users\micha\godspeed-train'
$stage = Join-Path $env:TEMP ("godspeed-training-" + [guid]::NewGuid())
Expand-Archive 'C:\path\to\godspeed-training-v1.zip' $stage
$config = Get-Content (Join-Path $stage 'train-config.json') -Raw | ConvertFrom-Json
$source = Join-Path $stage "data\$($config.D1_DATA)"
foreach ($split in 'train', 'val', 'test') {
    $file = Join-Path $source "$split.jsonl"
    if ((Get-FileHash $file -Algorithm SHA256).Hash -ne $config.splits.$split.sha256) {
        throw "Dataset hash mismatch in $split"
    }
}
$destination = Join-Path 'data' $config.D1_DATA
if ((Test-Path $destination) -or (Test-Path $config.D1_OUT)) {
    throw 'Choose fresh dataset and output names before training again.'
}
Copy-Item $source $destination -Recurse
$env:D1_DATA = $config.D1_DATA
$env:D1_OUT = $config.D1_OUT
$env:D1_LORA_TARGETS = $config.D1_LORA_TARGETS
python.exe -I .\train_d1.py train $config.epochs
```

Bring back `flywheel-d1-v1\model.safetensors` and `trained.json`. Check that the trainer logged zero missing and extra merged keys. The PC test tracks the training run. The separate Mac report is the promotion check. The LFM bench grades grounding candidates and supplies synthetic box labels. This package drives the existing d1 trainer.

## Convert and compare on the Mac

Use a new staging directory outside the live folders. The BF16 template from the prior d1 run supplies the configuration, tokenizer, and d1 runtime files. Put the new merged weights beside them, then quantize to the same 8-bit format.

```sh
stage=$(mktemp -d "${TMPDIR:-/tmp}/godspeed-candidate.XXXXXX")
helper="$HOME/.ocu-referee"
mlx_python="$helper/candidates/lfm3-vl-2b-mlx4/venv/bin/python"
rsync -a --exclude='*.safetensors' --exclude='*.safetensors.index.json' \
  "$helper/train/d1lora/run3/hf/" "$stage/bf16/"
cp /path/to/pc-output/model.safetensors "$stage/bf16/model.safetensors"
HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 HF_HUB_DISABLE_TELEMETRY=1 \
  "$mlx_python" -IB -m mlx_vlm.convert --hf-path "$stage/bf16" \
  --mlx-path "$stage/d1-candidate-mlx8bit" -q --q-bits 8 --q-group-size 64
"$mlx_python" -IB scripts/flywheel/flywheel.py eval \
  --candidate "$stage/d1-candidate-mlx8bit" --report "$stage/d1-eval.md"
```

The scorer reads the live model path from loopback `/health` once. It runs both models through the installed helper code with logging off, keeping one model loaded at a time in the evaluator. A d1 comparison uses up to 256 sequential inference calls. Use the serving settings for both arms. The defaults are single-question d1 mode, a 1,200-character view, and confidence cutoffs of 0.60 for hints and 0.86 for done. The click check asks d1 whether a specific click took effect. Its answer is scored against the fixture outcome. LFM uses zoom off by default and accepts `--zoom` when the serving helper has it on.

A recommendation requires higher held-out accuracy, no drop in done, stuck, or click verification recall, and no new false done or false click success on any row. Raw and thresholded claims both count. For LFM, use `eval --track lfm --candidate /path/to/local-mlx-candidate --report "$stage/lfm-eval.md"`. Its gate requires higher target accuracy and zero new wrong points. Dry runs exercise the report with scripted answers and always leave the candidate on hold.

## Apply or undo by hand

Apply only after reviewing a real comparison. For a d1 candidate, keep the old model in place and copy the reviewed candidate to a permanent local path. Check that the live helper is managed by `com.michael.godspeed.helper` in your GUI session. Back up that LaunchAgent plist, set only its candidate path, and reload the helper at a quiet time. This is Michael's manual step.

```sh
domain="gui/$(id -u)"
plist="$HOME/Library/LaunchAgents/com.michael.godspeed.helper.plist"
candidate="$HOME/Models/godspeed-d1-v1-mlx8bit"
(
  set -eu
  launchctl print "$domain/com.michael.godspeed.helper"
  test ! -e "$candidate"
  test ! -e "$stage/helper.before.plist"
  mkdir -p "$(dirname "$candidate")"
  cp -R "$stage/d1-candidate-mlx8bit" "$candidate"
  cp -p "$plist" "$stage/helper.before.plist"
  cp -p "$plist" "$stage/helper.candidate.plist"
  plutil -extract EnvironmentVariables json -o /dev/null "$stage/helper.candidate.plist" 2>/dev/null ||
    plutil -insert EnvironmentVariables -xml '<dict/>' "$stage/helper.candidate.plist"
  plutil -replace EnvironmentVariables.OCU_REFEREE_D1 -string "$candidate" "$stage/helper.candidate.plist"
  plutil -lint "$stage/helper.candidate.plist"
  launchctl bootout "$domain" "$plist"
  cp -p "$stage/helper.candidate.plist" "$plist"
  launchctl bootstrap "$domain" "$plist"
  launchctl kickstart "$domain/com.michael.godspeed.helper"
  curl --fail --silent http://127.0.0.1:8765/health
)
```

Before reloading, verify the backup and the new candidate path. After reloading, look for the exact path in the health reply and run an approved disposable fixture. For a reviewed LFM candidate, the corresponding plist key is `EnvironmentVariables.OCU_REFEREE_LFM`.

Undo with the saved plist. Verify that health reports the original path again.

```sh
(
  set -eu
  plutil -lint "$stage/helper.before.plist"
  if launchctl print "$domain/com.michael.godspeed.helper" >/dev/null 2>&1; then
    launchctl bootout "$domain" "$plist"
  fi
  cp -p "$stage/helper.before.plist" "$plist"
  launchctl bootstrap "$domain" "$plist"
  launchctl kickstart "$domain/com.michael.godspeed.helper"
  curl --fail --silent http://127.0.0.1:8765/health
)
```
