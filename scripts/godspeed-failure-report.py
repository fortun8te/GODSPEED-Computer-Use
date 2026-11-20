#!/usr/bin/env python3
"""Group Godspeed failures by cause, newest first, from local trajectory logs.

Reads ~/.godspeed/trajectories (or a directory argument). Rows written by builds with failure detail carry
`failure_detail.message`; older rows only have the tool and failure code. Nothing leaves the machine.
"""
import argparse
import collections
import glob
import json
import os
import re


def normalize(message: str) -> str:
    text = re.sub(r"\d+(\.\d+)?", "N", message)
    text = re.sub(r'"[^"]{0,80}"', '"…"', text)
    text = re.sub(r"'[^']{0,80}'", "'…'", text)
    return text[:160]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", nargs="?", default=os.path.expanduser("~/.godspeed/trajectories"))
    parser.add_argument("--since", default="", help="ISO date prefix, e.g. 2026-11-19")
    parser.add_argument("--top", type=int, default=25)
    args = parser.parse_args()

    groups: dict = collections.defaultdict(lambda: {"count": 0, "last": "", "example": None, "slow_ms": 0.0})
    total = failures = 0
    for path in glob.glob(os.path.join(args.directory, "*.jsonl")):
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if row.get("event") != "tool_call" or row.get("timestamp", "") < args.since:
                    continue
                total += 1
                if not (row.get("is_error") or row.get("batch_failed")):
                    continue
                failures += 1
                detail = row.get("failure_detail") or {}
                message = detail.get("message") or row.get("result_text") or ""
                key = (row.get("tool"), row.get("failure_code") or row.get("batch_stop_code"), normalize(message))
                group = groups[key]
                group["count"] += 1
                group["slow_ms"] = max(group["slow_ms"], row.get("duration_ms") or 0)
                if row.get("timestamp", "") >= group["last"]:
                    group["last"] = row.get("timestamp", "")
                    group["example"] = {"message": message[:400], "arguments": detail.get("arguments")}

    print(f"{failures} failures in {total} calls" + (f" since {args.since}" if args.since else ""))
    ranked = sorted(groups.items(), key=lambda item: (-item[1]["count"], item[1]["last"]))
    for (tool, code, cause), group in ranked[: args.top]:
        print(f"\n{group['count']:>4}x  {tool}  [{code}]  last {group['last'][:16]}  slowest {group['slow_ms']:.0f} ms")
        if cause:
            print(f"      cause: {cause}")
        example = group["example"] or {}
        if example.get("arguments"):
            print(f"      args:  {json.dumps(example['arguments'])[:300]}")


if __name__ == "__main__":
    main()
