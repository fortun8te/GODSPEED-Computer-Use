#!/usr/bin/env python3
"""Synthetic protocol fixture; does not execute Godspeed, a model, or a GUI.

Measures bytes of two toy encodings and checks decoded semantics. The deliberately
broken option demonstrates that dropping information cannot win on payload size.
"""

import json
import sys
import time


def main():
    request = json.load(sys.stdin)
    started = time.perf_counter()
    case = request["case"]
    count = case["input"]["nodes"]
    nodes = [{"id": f"node-{index}", "role": "AXButton", "label": f"{case['input']['label']} {index}",
              "enabled": index % 3 != 0, "actions": ["AXPress"], "children": [],
              "description": "", "help": "", "value": None}
             for index in range(count)]
    encoding = request["profile"]["encoding"]
    if encoding == "verbose":
        encoded = nodes
    else:
        encoded = [[node["id"], node["role"], node["label"], node["enabled"]]
                   for node in (nodes[:2] if encoding == "broken" else nodes)]
    payload = json.dumps(encoded, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    decoded = json.loads(payload)
    if encoding != "verbose":
        decoded = [dict(zip(("id", "role", "label", "enabled"), row)) for row in decoded]
    # Check the round trip separately from the encoder, including a late target.
    expected = {node["id"]: (node["role"], node["label"], node["enabled"]) for node in nodes}
    observed = {node["id"]: (node["role"], node["label"], node["enabled"]) for node in decoded}
    checks = {"target_retained": observed.get(nodes[-1]["id"]) == expected[nodes[-1]["id"]],
              "states_retained": observed == expected}
    result = {"schema": 1, "case_id": case["id"], "completed": True,
              "checker_pass": all(checks.values()), "checks": checks,
              "safety": {"wrong_targets": 0, "duplicate_actions": 0, "user_disturbances": 0},
              "metrics": {"duration_ms": (time.perf_counter() - started) * 1000,
                          "observation_bytes": len(payload), "agent_calls": 0, "helper_calls": 0},
              "token_source": None}
    print(json.dumps(result, allow_nan=False))


if __name__ == "__main__":
    main()
