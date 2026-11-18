# Training fixtures

Default Godspeed logs are useful for counting failures and timing. They omit screenshots, inputs and UI text. Capture content only in an approved fixture session, and review the output before it enters a training set.

## Decision and harness data

Record initial state, the task, actions, and the postconditions that a separate checker verifies. Keep source streams and check results paired by run ID and SHA-256. A decision hint or a model's final answer is insufficient evidence for a completion label. Separate unfinished turns and keep entire workflow families in one train, validation, or test split.

## Vision data

Use synthetic or reviewed fixture screenshots with independently annotated target boxes. Put reviewed PNGs and `annotations.jsonl` in a separate directory, with one record per target. The box uses top-left pixel coordinates.

```json
{"family":"fixture-form","target":"Save button","split":"train","image":"form-before-save.png","box_xyxy":[20,30,100,62]}
```

Run the local validator to produce a private manifest.

```sh
python3 scripts/godspeed-vision-manifest.py ./reviewed-fixtures --output ./vision-manifest.jsonl
```

The manifest records dimensions, the exact image SHA-256, and the annotated box. The validator refuses out-of-bounds boxes, images outside the fixture directory, and a family or identical image shared between dataset splits. It keeps the PNGs in place and does not inspect active desktop sessions.
