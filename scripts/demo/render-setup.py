#!/usr/bin/env python3
"""Render the Godspeed 1.1.12 setup clip with Pillow and FFmpeg on macOS.

Run from the repository root: python3 scripts/demo/render-setup.py
The terminal and permission cards are synthetic. No desktop is captured.
"""
from pathlib import Path
import subprocess

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
MEDIA = ROOT / "docs/media"
SIZE = 1280, 720
FPS = 24
BG, CARD, EDGE = "#111216", "#1b1d23", "#343743"
TEXT, MUTED, RED, GREEN = "#f3f2f6", "#aeb1bd", "#ff6272", "#85dbaf"
FONT = "/System/Library/Fonts/Supplemental/Arial.ttf"
BOLD = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
MONO = "/System/Library/Fonts/Menlo.ttc"
VERSION = "1.1.12"
RELEASE = f"https://github.com/fortun8te/godspeed/releases/download/v{VERSION}/install-godspeed.sh"
SCENES = [
    ("Install the verified download", "Download and run the installer in Terminal.", "Terminal", [
        ('$ curl -fLO \\', TEXT),
        ("  " + RELEASE + " " + chr(92), TEXT),
        ("  && bash install-godspeed.sh", TEXT),
        ("", TEXT),
        ("✓ Archive checksum and application signature verified", GREEN),
    ], "Apple Silicon · macOS 14 or later"),
    ("Grant app permissions", "Open GODSPEED.app from ~/Applications.", "Godspeed permissions", [],
     "macOS may ask you to reopen the app after a change."),
    ("Connect and check MCP", "Register your client, then start a fresh session.", "Terminal · Codex example", [
        ('$ codex mcp add godspeed -- "$HOME/.local/bin/godspeed-mcp"', TEXT),
        ("", TEXT),
        ("✓ Check that get_app_state and batch are listed", GREEN),
        ("   Try a read in a disposable window with the Mac unlocked.", MUTED),
    ], "Claude Code and optional Chrome setup are covered in the install guide."),
]


def draw_text(draw, x, y, value, size, color=TEXT, face=FONT):
    draw.text((x, y), value, font=ImageFont.truetype(face, size), fill=color, anchor="lt")


def box(draw, coords, fill, radius=15, border=None):
    draw.rounded_rectangle(coords, radius, fill=fill, outline=border, width=1)


def frame_for(index, energy):
    title, subtitle, panel, lines, foot = SCENES[index]
    frame = Image.new("RGB", SIZE, BG)
    draw = ImageDraw.Draw(frame)
    box(draw, (57, 36, 63, 65), RED, 3)
    draw_text(draw, 77, 40, "Godspeed", 26, face=BOLD)
    draw_text(draw, 220, 44, f"v{VERSION}", 18, MUTED, MONO)
    draw_text(draw, 923, 43, "RENDERED SETUP WALKTHROUGH", 16, MUTED, BOLD)
    draw.line((56, 91, 1224, 91), fill=EDGE, width=1)

    draw_text(draw, 57, 120, f"0{index+1} / 03", 17, RED, MONO)
    draw_text(draw, 57, 155, title, 54, face=BOLD)
    draw_text(draw, 58, 225, subtitle, 25, MUTED)

    box(draw, (56, 292, 1224, 569), CARD, 18, EDGE)
    draw_text(draw, 84, 313, panel, 18, MUTED, BOLD)
    draw.line((57, 350, 1223, 350), fill=EDGE, width=1)
    if index == 1:
        for y, name, details, kind in [
            (375, "Accessibility", "Required for native app controls", "REQUIRED"),
            (463, "Screen Recording", "Enables screenshots and visual targeting", "OPTIONAL"),
        ]:
            box(draw, (84, y, 1196, y+68), "#24262e", 10)
            draw_text(draw, 108, y+14, name, 23, face=BOLD)
            draw_text(draw, 108, y+44, details, 17, MUTED)
            draw_text(draw, 1004, y+25, kind, 16, RED if kind == "REQUIRED" else MUTED, MONO)
    else:
        for i, (line, color) in enumerate(lines):
            if line:
                draw_text(draw, 84, 376+i*32, line, 20, color, MONO)
    draw_text(draw, 57, 595, foot, 21, MUTED)
    draw.line((56, 647, 1224, 647), fill=EDGE, width=1)
    for idx in range(3):
        start = 57 + idx * 391
        box(draw, (start, 674, start+375, 679), "#333640", 2)
        if idx <= index:
            width = 375 if idx < index else max(4, round(energy*375))
            box(draw, (start, 674, start+width, 679), RED, 2)
    return frame


def main():
    MEDIA.mkdir(exist_ok=True)
    frame_for(0, 1 / 24).save(MEDIA / "setup-poster.png", optimize=True)
    cmd = ["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24",
           "-s", "1280x720", "-r", str(FPS), "-i", "-", "-an", "-c:v", "libx264",
           "-preset", "medium", "-crf", "21", "-pix_fmt", "yuv420p", "-movflags", "+faststart",
           str(MEDIA / "setup-walkthrough.mp4")]
    with subprocess.Popen(cmd, stdin=subprocess.PIPE) as proc:
        for scene in range(3):
            still = frame_for(scene, 0)
            for tick in range(0, FPS * 4):
                frame = still.copy()
                end = round(56 + 391*scene + 375*(tick+1)/(FPS*4))
                box(ImageDraw.Draw(frame), (57+391*scene, 674, max(60+391*scene, end), 679), RED, 2)
                proc.stdin.write(frame.tobytes())
        proc.stdin.close()
        if proc.wait():
            raise RuntimeError("FFmpeg failed to encode the walkthrough")


if __name__ == "__main__":
    main()
