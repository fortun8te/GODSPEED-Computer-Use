# Benchmarks

## Release checks

These runs measure the UTF-8 text passed back to the agent. Input token counts depend on the host model and how it serializes tool results.

| Synthetic window | Earlier reply | Current reply | Text reduction |
| --- | ---: | ---: | ---: |
| One changed control in a small window | 184 B | 71 B | 61% |
| 80 controls after a verified batch, full versus compact | 1,959 B | 105 B | 95% |

Run `swift test --filter CompactVerifiedReplyTests` to reproduce the reply checks. The first case selects the smaller of the state and its diff. The second uses `compact: true` and an explicit passing check. A later read still returns information the client has yet to see.

The app agent used to check for idle exit every five seconds. It now arms a single deadline after the last client disconnects. `swift test --filter LifecycleTests` covers deadline changes as clients connect and disconnect. Whole-machine CPU, GPU and power measurements are pending.

### Desktop cursor checks

GitHub CI covers client names, cursor geometry and idle deadlines. Run the animation and window-follow checks on an unlocked Mac with Reduce Motion off. Enable Accessibility for the local test host to exercise the real button click. A second connected display lets the window-follow test cover both displays.

```sh
OPEN_COMPUTER_USE_CURSOR_NAMESPACE=godspeed-test swift test \
  --filter 'CursorHideTimerTests|CursorWindowFollowTests'
```

The 1.1.10 desktop run passed both the two-display follow check and the live click on a moved window. Those checks verify the cursor's behavior and placement.

## Earlier runs

These recorded runs used GPT-6 Luna at low reasoning. A task checker scored the final result.

| Setup | Passed | Attempts |
| --- | ---: | ---: |
| Codex native | 2 | 10 |
| Godspeed | 1 | 16 |
| Godspeed with local helpers | 150 | 256 |

The sets included different tasks and repeated attempts. Three Godspeed-only runs also recorded native computer-use calls. Use these numbers as history. A matched comparison is needed to estimate the effect of the helpers or compare tools.

An isolated Chrome trial on November 18 verified three outcomes in 21 Godspeed calls and 109 seconds. Six calls returned errors that required a correction or a readback. It identified partial typing, ambiguous action delivery, and tab-close verification as targets for the next pass. The two attempted native comparison sessions both timed out during startup, so the trial produced no matched ranking.

## A fair comparison

Use the same model, prompt, app state, and checks. Alternate runs and report task success, wall time, tool calls, and input and output tokens. Keep standalone, parallel, and helper-assisted runs identifiable. [Verification plan](exec-plans/active/20261118-godspeed-workflow-reliability.md)

## Aside comparison

The matched public target is the Scale suite with Sonnet 5.5: 87/90 passes, 37/40 of them in the background, with a 15.1-second median and 7 median agent calls. Preserve the complete trial schedule and the GUI and background-disturbance checks. Godspeed has no matched result yet. [Scale trial catalog](https://huggingface.co/spaces/earakely-scale/CuaDriverBench-AgentEnv/blob/main/data/catalog.json)

Use `python3 scripts/godspeed-benchmark-compare.py --suite scale-bench-v2 baseline.jsonl candidate.jsonl` to compare normalized trial receipts offline. The script checks matching configurations and all 90 trial slots before scoring. It does not execute the benchmark. The separate `aside-internal` profile requires a predeclared schedule.
