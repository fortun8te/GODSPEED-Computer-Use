# Four native tasks

This benchmark sends scripted MCP calls through the installed Godspeed app. It uses a disposable AppKit window with accessibility controls for multiplication, multiline editing, folder creation, and file selection. The fixture creates files only inside a fresh temporary directory and runs with background-only input.

The verifier reads the fixture's calculation result, exact document text and selected file, and checks the new folder on disk. Each result can be checked independently of what Godspeed reports. The fixture counts its own activations and compares the foreground app before and after each set.

## Godspeed 1.1.10 results

Three fresh fixture runs per mode, recorded on November 20, 2026. Times and bytes are the median of fully verified sets. Timing starts with each task's first MCP request and ends at its last response. App setup, discovery, and independent checks are outside the timer. Reply sizes are UTF-8 text bytes.

| Mode | Verified tasks | Tool errors | MCP calls per set | Reply text | Median driver time |
| --- | ---: | ---: | ---: | ---: | ---: |
| Expose each observation, then use a window-pinned batch | 11 / 12 | 1 | 8 | 5,757 B | 2.77 s |
| Observe inside each compact batch | 12 / 12 | 0 | 4 | 2,033 B | 4.38 s |

Putting the observation inside each batch halved the calls and cut reply text by 65%. Both modes submitted the same 14 observation and action steps per complete set and used a final check with per-step effects off. The second mode had a higher median driver time in this small sample. The fixture recorded zero activations. The foreground app was the same before and after all three batched runs. In the first mode it changed during one set without activating the fixture.

In one trial with a pinned window, Godspeed rejected the first click as stale before sending input. Grouping all operations in one pinned batch produced the same first-click rejection in three fresh runs. In those failures, the recovery observation still listed the previous window ID. The binding also checks app identity, the accessibility object and window bounds. Retain these failures when reproducing the test.

This is a driver test of the four task shapes. A direct comparison with a Sonnet run needs that same model, the original apps and task prompts, independent checks, and the same timing and token boundaries.

## Run locally

On an unlocked Mac with Godspeed's Accessibility permission and Xcode command-line tools, run these from the checkout.

```sh
python3 scripts/godspeed-native-four-task-bench.py --repeat 3 --output separate.json
python3 scripts/godspeed-native-four-task-bench.py --repeat 3 --batch-per-task --output batched.json
python3 scripts/godspeed-native-four-task-bench.py --repeat 3 --single-window-batch --output grouped.json
```

Each receipt includes the installed MCP server version, per-call timing, text and JSON reply sizes, independent task results, and foreground checks. The command exits nonzero when a task fails independent verification.
