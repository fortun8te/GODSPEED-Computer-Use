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
