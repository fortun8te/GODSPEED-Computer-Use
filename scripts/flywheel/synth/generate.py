#!/usr/bin/env python3
"""Create deterministic synthetic d1 practice rows."""
import argparse
import json
import random
from collections import Counter
from pathlib import Path

FAMILIES = {
    "mail_compose_send": ("Mail", "Compose message", "Send", "Message sent"),
    "finder_rename_move": ("Finder", "Rename item", "Move", "Item moved"),
    "settings_toggles": ("Settings", "Privacy", "Save", "Setting saved"),
    "forms_validation": ("Form", "Submit application", "Submit", "Form submitted"),
    "save_dialogs": ("Editor", "Save document", "Save", "Document saved"),
    "web_search_results": ("Browser", "Search the web", "Search", "Results loaded"),
    "multi_step_wizards": ("Setup", "Finish setup", "Continue", "Setup complete"),
    "list_selection": ("Tasks", "Select requested task", "Select", "Selection applied"),
}
LABELS = ("act", "look_again", "done", "stuck")
# Each label maps to the near-miss variants that produce it.
LABEL_VARIANTS = {
    "act": ("not_yet", "disabled", "dialog_closed", "uncommitted"),
    "look_again": ("lookalike",),
    "done": ("done",),
    "stuck": ("stuck",),
}
HELDOUT = {"export", "schedule", "library", "accessibility"}


def make_row(family, variant, number):
    app, goal, button, success = FAMILIES[family]
    win = f"{app} window"
    target = f"{button} requested item"
    if variant == "done":
        label, result, view, changed = "done", success, f'Window: "{app}", App: Fixture.\n1 button {button}\n2 text {success}', "yes"
    elif variant == "stuck":
        label, result, view, changed = "stuck", "The same validation error appeared again.", f'Window: "{app}", App: Fixture.\n1 text Error: required field missing', "no"
    else:
        label, result, changed = "act", "Action has not been completed.", "no"
        if variant == "not_yet":
            view = f'Window: "{app}", App: Fixture.\n1 button {button}\n2 text {goal} still open'
        elif variant == "lookalike":
            label = "look_again"
            view = f'Window: "{app}", App: Fixture.\n1 button {button}\nWindow: "Other", App: Fixture.\n2 button {button}\n3 text Other window changed'
            result = "A similarly named control in another window changed."
        elif variant == "disabled":
            view = f'Window: "{app}", App: Fixture.\n1 button {button} (disabled)'
        elif variant == "dialog_closed":
            view = f'Window: "{app}", App: Fixture.\n1 button {button}\nDialog or sheet open: no'
        else:
            view = f'Window: "{app}", App: Fixture.\n1 text field Value = {target}\n2 button {button}'
            result = "Value typed but not committed."
    state = {"goal": f"In the {win}, {goal}.", "last_step": f'Click "{button}"', "result": result,
             "view": f"Goal: {goal}\nSteps:\n1. {result}\nRepeated failures: {2 if variant == 'stuck' else 0}\nScreen changed: {changed}\nScreen:\n{view}"}
    return {"state": json.dumps(state, ensure_ascii=False, sort_keys=True), "answer": label,
            "meta": {"id": f"{family}/{number}/{variant}", "family": family, "synthetic": True}}


def generate(seed, per_family):
    rng = random.Random(seed)
    rows = []
    for family in sorted(FAMILIES):
        # Per-label quotas: each label gets per_family // 4 rows, and the remainder goes to the first labels.
        variants = []
        for index, label in enumerate(LABELS):
            quota = per_family // len(LABELS) + (1 if index < per_family % len(LABELS) else 0)
            options = LABEL_VARIANTS[label]
            variants.extend(options[i % len(options)] for i in range(quota))
        rng.shuffle(variants)
        rows.extend(make_row(family, variant, i) for i, variant in enumerate(variants))
    rng.shuffle(rows)
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--per-family", type=int, default=200)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    rows = generate(args.seed, args.per_family)
    Path(args.out).write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in rows), encoding="utf-8")
    for family in sorted(FAMILIES):
        counts = Counter(row["answer"] for row in rows if row["meta"]["family"] == family)
        print(f"{family}: {dict(sorted(counts.items()))}")
    print(f"total: {len(rows)}")


if __name__ == "__main__":
    main()
