# Benchmarks

Godspeed's current package passes macOS source checks and an MCP handshake. A fresh comparison on real workflows is pending.

## Earlier runs

These recorded runs used GPT-6 Luna at low reasoning. A task checker scored the final result.

| Setup | Passed | Attempts |
| --- | ---: | ---: |
| Codex native | 2 | 10 |
| Godspeed | 1 | 16 |
| Godspeed with local helpers | 150 | 256 |

The sets included different tasks and repeated attempts. Three Godspeed-only runs also recorded native computer-use calls. Use these numbers as history. A matched comparison is needed to estimate the effect of the helpers or compare tools.

## A fair comparison

Use the same model, prompt, app state, and checks. Alternate runs and report task success, wall time, tool calls, and input and output tokens. Keep standalone, parallel, and helper-assisted runs identifiable. [Verification plan](exec-plans/active/20261118-godspeed-workflow-reliability.md)

## Aside comparison

The matched public target is the Scale suite with Sonnet 5.5: 87/90 passes, 37/40 of them in the background, with a 15.1-second median and 7 median agent calls. Preserve the complete trial schedule and the GUI and background-disturbance checks. Godspeed has no matched result yet. [Scale trial catalog](https://huggingface.co/spaces/earakely-scale/CuaDriverBench-AgentEnv/blob/main/data/catalog.json)

Use `python3 scripts/godspeed-benchmark-compare.py --suite scale-bench-v2 baseline.jsonl candidate.jsonl` to compare normalized trial receipts offline. The script checks matching configurations and all 90 trial slots before scoring. It does not execute the benchmark. The separate `aside-internal` profile requires a predeclared schedule.
