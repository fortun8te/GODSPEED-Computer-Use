#!/usr/bin/env python3
"""Render a synthetic interface with positions and angles from CursorPathDumpTests.

The supplied cursor-paths.json samples the production CursorGlide planner.
With Pillow installed on macOS:
python3 scripts/demo/render-cursor-motion.py scripts/demo/cursor-paths.json docs/media/cursor-motion.gif
"""
import argparse
import json
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


WIDTH, HEIGHT, SCALE = 720, 390, 2
FRAME_MS = 50
BACKGROUND = "#111216"
CARD = "#1b1d23"
BORDER = "#2a2d35"
TEXT = "#f3f2f6"
MUTED = "#a2a5b1"
RED = "#ff4c62"
FONT = Path("/System/Library/Fonts/Helvetica.ttc")

BUTTONS = (
    ((508, 231, 664, 271), "Save draft"),
    ((508, 91, 664, 131), "Verify result"),
    ((299, 91, 455, 131), "Export receipt"),
)


def px(value):
    return round(value * SCALE)


def rounded(draw, bounds, radius, fill, outline=None):
    draw.rounded_rectangle(tuple(map(px, bounds)), radius=px(radius), fill=fill,
                           outline=outline, width=SCALE)


def label(draw, x, y, text, size=13, color=TEXT, bold=False):
    font = ImageFont.truetype(str(FONT), px(size), index=1 if bold else 0)
    draw.text((px(x), px(y)), text, font=font, fill=color, anchor="lt")


def backdrop(completed):
    frame = Image.new("RGB", (px(WIDTH), px(HEIGHT)), BACKGROUND)
    draw = ImageDraw.Draw(frame)
    label(draw, 28, 22, "Godspeed", 19, bold=True)
    label(draw, 137, 25, "Background cursor", 14, MUTED)
    label(draw, 531, 26, "PLANNER-RENDERED DEMO", 11, MUTED, bold=True)

    rounded(draw, (20, 63, 700, 350), 13, CARD, BORDER)
    rounded(draw, (34, 78, 244, 335), 10, "#16181e")
    label(draw, 50, 96, "Workflow", 15, bold=True)
    for i, (_, name) in enumerate(BUTTONS):
        top = 130 + 56 * i
        rounded(draw, (46, top, 230, top + 46), 8,
                "#242630" if i == completed else "#191b22")
        completed_step = i < completed
        color = "#85dbaf" if completed_step else (RED if i == completed else MUTED)
        draw.ellipse((px(59), px(top + 17), px(69), px(top + 27)), fill=color)
        label(draw, 79, top + 16, name, 13, TEXT if i <= completed else MUTED)

    label(draw, 263, 155, "Quarterly report", 21, bold=True)
    label(draw, 263, 183, "Workspace", 13, MUTED)
    for i, width in enumerate((183, 151, 193, 121)):
        rounded(draw, (263, 226 + i * 16, 263 + width, 231 + i * 16), 2, "#363945")

    for i, (bounds, name) in enumerate(BUTTONS):
        active = i == completed
        done = i < completed
        rounded(draw, bounds, 8, "#3f2530" if active else "#23252e", RED if active else BORDER)
        x0, y0, _, _ = bounds
        label(draw, x0 + 12, y0 + 13, name, 13, "#a4e1bf" if done else TEXT, active)
        if done:
            draw.line((px(bounds[2] - 22), px(y0 + 19), px(bounds[2] - 18), px(y0 + 23),
                       px(bounds[2] - 11), px(y0 + 15)), fill="#85dbaf", width=px(2))

    label(draw, 28, 368, "Motion from Godspeed’s cursor planner · synthetic interface", 12, MUTED)
    return frame


def cursor(frame, x, y, angle, pulse=None):
    draw = ImageDraw.Draw(frame, "RGBA")
    if pulse is not None:
        radius = 8 + 14 * pulse
        draw.ellipse(tuple(map(px, (x - radius, y - radius, x + radius, y + radius))),
                     outline=(255, 92, 109, round(205 * (1 - pulse))), width=px(2))
    # Keep the arrow tip on the same position reported by the planner.
    points = ((0, 0), (5, 27), (11, 19), (18, 26), (23, 22), (16, 15), (26, 13))
    c, s = math.cos(angle), math.sin(angle)
    outline = [(px(x + ax * c - ay * s), px(y + ax * s + ay * c)) for ax, ay in points]
    shadow = [(a + px(2), b + px(3)) for a, b in outline]
    draw.polygon(shadow, fill=(0, 0, 0, 100))
    draw.polygon(outline, fill=RED)
    draw.line(outline + outline[:1], fill="#ffb2bc", width=px(1), joint="curve")
    rounded(draw, (x + 18, y + 23, x + 79, y + 44), 5, "#752a40")
    label(draw, x + 26, y + 28, "Godspeed", 10, TEXT, bold=True)


def interpolate(samples, ratio):
    position = ratio * (len(samples) - 1)
    index = min(int(position), len(samples) - 2)
    remainder = position - index
    a, b = samples[index], samples[index + 1]
    angle_delta = (b[2] - a[2] + math.pi) % (2 * math.pi) - math.pi
    return (a[0] + (b[0] - a[0]) * remainder, a[1] + (b[1] - a[1]) * remainder,
            a[2] + angle_delta * remainder)


def render(trace, output):
    frames = []
    durations = []
    x, y = 359, 251
    for i, index in enumerate((0, 2, 1)):
        path = trace[index]
        samples = path["samples"]
        if len(samples) < 2 or not 0 < path["ms"] < 5000:
            raise ValueError("Invalid motion trace")
        old_x, old_y, old_angle = samples[0]
        # One fixed scale for both axes across all glides. Flip AppKit's vertical axis.
        scale = 0.375
        steps = max(3, math.ceil(path["ms"] / FRAME_MS))
        for j in range(steps + 1):
            sx, sy, rotation = interpolate(samples, j / steps)
            frame = backdrop(i)
            cursor(frame, x + (sx - old_x) * scale, y - (sy - old_y) * scale, rotation - old_angle)
            frames.append(frame)
            durations.append(350 if i == 0 and j == 0 else FRAME_MS)
        x += (samples[-1][0] - old_x) * scale
        y -= (samples[-1][1] - old_y) * scale
        for j in range(5):
            frame = backdrop(i + 1)
            cursor(frame, x, y, 0, j / 4)
            frames.append(frame)
            durations.append(250 if j == 4 else FRAME_MS)

    durations[-1] += 550
    frames = [frame.resize((WIDTH, HEIGHT), Image.Resampling.LANCZOS) for frame in frames]
    color_samples = Image.new("RGB", (WIDTH, HEIGHT * 4))
    for i in range(4):
        color_samples.paste(backdrop(i).resize((WIDTH, HEIGHT), Image.Resampling.LANCZOS), (0, HEIGHT * i))
    palette = color_samples.quantize(colors=128)
    indexed = [frame.quantize(palette=palette, dither=Image.Dither.NONE) for frame in frames]
    indexed[0].save(output, save_all=True, append_images=indexed[1:], duration=durations,
                    loop=0, optimize=True, disposal=1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    render(json.loads(args.trace.read_text()), args.output)


if __name__ == "__main__":
    main()
