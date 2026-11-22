# Changelog

## 1.1.12

### Install and distribution

- Apple Silicon development ZIP, checksum, and a download installer with progress.
- A stable user-local MCP launcher for Codex, Claude Code, and other stdio clients.
- Separate setup instructions for macOS permissions, Chrome’s extension bridge, and optional local models.
- Public GSD1 Action, Read, and Recover adapter weights under the LFM Open License v1.0. [GSD1 research preview](https://github.com/fortun8te/godspeed/releases/tag/gsd1-v0.1.0)

### Godspeed

- Explicitly compact, verified batches can summarize step metadata while retaining individual receipts for failures and uncertain delivery.
- Resumed native batches retain per-step window bindings and original step numbers across repeated stops.
- Background-mode fixes keep focus borrowing out of the way after control returns to the user, and preserve Finder’s folder navigation guard.
- More robust targeted reads, safer numeric completion checks, and formatted browser paste handling.
- Optional typed `local_decision` recommendations for the three role-specific checkpoints. The installed helper keeps one tuned model loaded at a time across clients.
- Benchmark accounting reports fresh input, cached input, cache writes, output, and reasoning when the host provides those fields.

## 1.1.11

- Background-first MCP tools for native Mac apps and Chrome, with cursor identity per connection.
- Compact reads, verified batches, and native resume receipts in the development build.
- [Prior driver measurements](docs/benchmarks.md) record exact fixture versions and test conditions.
