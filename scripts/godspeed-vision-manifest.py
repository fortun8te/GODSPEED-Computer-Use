#!/usr/bin/env python3
"""Validate reviewed fixture annotations and fingerprint the exact PNGs used for vision training."""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import struct
import tempfile


def index(fixtures):
    live = (Path.home() / ".godspeed" / "trajectories").resolve()
    fixtures = fixtures.resolve(strict=True)
    if fixtures == live or live in fixtures.parents or fixtures in live.parents:
        raise ValueError("use a reviewed fixture directory")

    family_splits = {}
    image_splits = {}
    with (fixtures / "annotations.jsonl").open(encoding="utf-8") as annotations:
        for line_number, line in enumerate(annotations, 1):
            try:
                row = json.loads(line)
                family, target, split = (row[key] for key in ("family", "target", "split"))
                if not isinstance(family, str) or not family.strip() or not isinstance(target, str) or not target.strip():
                    raise ValueError("family and target must be nonempty text")
                if split not in ("train", "validation", "test"):
                    raise ValueError("split must be train, validation or test")
                file = (fixtures / row["image"]).resolve(strict=True)
                if not file.is_relative_to(fixtures) or file.suffix.lower() != ".png":
                    raise ValueError("image must be a PNG inside the fixture directory")
                data = file.read_bytes()
                if not data.startswith(b"\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR") or len(data) < 33:
                    raise ValueError("image has no PNG header")
                width, height = struct.unpack(">II", data[16:24])
                box = row["box_xyxy"]
                if not isinstance(box, list) or len(box) != 4 or any(type(n) not in (int, float) or not math.isfinite(n) for n in box):
                    raise ValueError("box needs four finite pixel coordinates")
                x0, y0, x1, y1 = box
                if not (0 <= x0 < x1 <= width and 0 <= y0 < y1 <= height):
                    raise ValueError("box lies outside the image")
                digest = hashlib.sha256(data).hexdigest()
                if family_splits.setdefault(family, split) != split or image_splits.setdefault(digest, split) != split:
                    raise ValueError("a fixture family or identical image crosses dataset splits")
            except (KeyError, OSError, TypeError, ValueError) as error:
                raise ValueError(f"annotation line {line_number}: {error}") from error
            yield {
                "schema_version": 1,
                "family": family,
                "target": target,
                "split": split,
                "image": file.relative_to(fixtures).as_posix(),
                "sha256": digest,
                "width": width,
                "height": height,
                "box_xyxy": box,
            }


def write_manifest(fixtures, output):
    output = output.resolve()
    live = (Path.home() / ".godspeed" / "trajectories").resolve()
    if live in output.parents:
        raise ValueError("keep the manifest out of the active trajectory directory")
    if output == (fixtures / "annotations.jsonl").resolve() or output.suffix != ".jsonl":
        raise ValueError("choose a separate .jsonl output file")
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=output.parent, delete=False) as stream:
            temporary = Path(stream.name)
            count = 0
            for row in index(fixtures):
                stream.write(json.dumps(row, ensure_ascii=False) + "\n")
                count += 1
            if count == 0:
                raise ValueError("no fixture annotations")
        os.replace(temporary, output)
        return count
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixtures", type=Path, help="reviewed directory containing annotations.jsonl")
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        count = write_manifest(arguments.fixtures, arguments.output)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    print(f"Indexed {count} reviewed target annotations.")
