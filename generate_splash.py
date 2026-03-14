#!/usr/bin/env python3
"""
generate_splash.py - Generates a fullscreen splash screen for the VideoPlayer.
Outputs /opt/videoplayer/web/static/splash.jpg
Run once at install time: python3 generate_splash.py
Requires: Pillow (python3-pil)
"""

from PIL import Image, ImageDraw, ImageFont
from pathlib import Path
import sys

OUT = Path("/opt/videoplayer/web/static/splash.jpg")
W, H = 1920, 1080
BG   = (10, 10, 10)
DIM  = (30, 30, 30)
GOLD = (245, 197, 24)
WHITE = (220, 220, 220)
GREY = (100, 100, 100)

ASCII_ART = r"""
██╗   ██╗██╗██████╗ ███████╗ ██████╗ ██████╗ ██╗      █████╗ ██╗   ██╗███████╗██████╗
██║   ██║██║██╔══██╗██╔════╝██╔═══██╗██╔══██╗██║     ██╔══██╗╚██╗ ██╔╝██╔════╝██╔══██╗
██║   ██║██║██║  ██║█████╗  ██║   ██║██████╔╝██║     ███████║ ╚████╔╝ █████╗  ██████╔╝
╚██╗ ██╔╝██║██║  ██║██╔══╝  ██║   ██║██╔═══╝ ██║     ██╔══██║  ╚██╔╝  ██╔══╝  ██╔══██╗
 ╚████╔╝ ██║██████╔╝███████╗╚██████╔╝██║     ███████╗██║  ██║   ██║   ███████╗██║  ██║
  ╚═══╝  ╚═╝╚═════╝ ╚══════╝ ╚═════╝ ╚═╝     ╚══════╝╚═╝  ╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝
"""

SUBTITLE = "Raspberry Pi Video Kiosk"
HINT     = "Connect to  VideoPlayer  WiFi  →  open  http://192.168.4.1  to upload videos"

def load_font(size):
    """Try to load a monospace font, fall back to default."""
    candidates = [
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationMono-Bold.ttf",
        "/usr/share/fonts/truetype/freefont/FreeMono.ttf",
        "/usr/share/fonts/truetype/noto/NotoMono-Regular.ttf",
    ]
    for path in candidates:
        if Path(path).exists():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()

def load_font_regular(size):
    candidates = [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
        "/usr/share/fonts/truetype/freefont/FreeSans.ttf",
    ]
    for path in candidates:
        if Path(path).exists():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()

def main():
    img  = Image.new("RGB", (W, H), BG)
    draw = ImageDraw.Draw(img)

    # ── Subtle grid lines for depth ──────────────────────────────────────────
    for x in range(0, W, 80):
        draw.line([(x, 0), (x, H)], fill=(18, 18, 18), width=1)
    for y in range(0, H, 80):
        draw.line([(0, y), (W, y)], fill=(18, 18, 18), width=1)

    # ── Gold horizontal accent bars ───────────────────────────────────────────
    draw.rectangle([(0, 0), (W, 3)],   fill=GOLD)
    draw.rectangle([(0, H-3), (W, H)], fill=GOLD)

    # ── ASCII art ─────────────────────────────────────────────────────────────
    font_ascii = load_font(18)
    lines = [l for l in ASCII_ART.split("\n") if l.strip()]

    # Measure total block height
    line_h = font_ascii.getbbox("A")[3] + 4
    total_h = len(lines) * line_h
    start_y = (H // 2) - (total_h // 2) - 80

    for i, line in enumerate(lines):
        bbox = font_ascii.getbbox(line)
        lw = bbox[2] - bbox[0]
        x = (W - lw) // 2
        y = start_y + i * line_h
        # Draw glow effect (dark gold shadow)
        draw.text((x+2, y+2), line, font=font_ascii, fill=(60, 48, 0))
        draw.text((x, y), line, font=font_ascii, fill=GOLD)

    # ── Subtitle ──────────────────────────────────────────────────────────────
    font_sub = load_font_regular(32)
    bbox = font_sub.getbbox(SUBTITLE)
    sw = bbox[2] - bbox[0]
    draw.text(((W - sw) // 2, start_y + total_h + 24), SUBTITLE,
              font=font_sub, fill=WHITE)

    # ── Divider ───────────────────────────────────────────────────────────────
    div_y = start_y + total_h + 80
    draw.rectangle([(W//2 - 200, div_y), (W//2 + 200, div_y + 1)], fill=(60, 60, 60))

    # ── Hint text ─────────────────────────────────────────────────────────────
    font_hint = load_font_regular(24)
    bbox = font_hint.getbbox(HINT)
    hw = bbox[2] - bbox[0]
    draw.text(((W - hw) // 2, div_y + 20), HINT, font=font_hint, fill=GREY)

    # ── Pulsing dot decoration (static approximation) ─────────────────────────
    for r, alpha in [(30, 15), (18, 30), (8, 80)]:
        cx, cy = W // 2, div_y + 90
        col = (int(245 * alpha // 100), int(197 * alpha // 100), int(24 * alpha // 100))
        draw.ellipse([(cx - r, cy - r), (cx + r, cy + r)], fill=col)

    # ── Corner decorations ────────────────────────────────────────────────────
    for (x1, y1, x2, y2) in [(0,0,60,3),(0,0,3,60),(W-60,0,W,3),(W-3,0,W,60),
                               (0,H-3,60,H),(0,H-60,3,H),(W-60,H-3,W,H),(W-3,H-60,W,H)]:
        draw.rectangle([(x1,y1),(x2,y2)], fill=GOLD)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    img.save(str(OUT), "JPEG", quality=95)
    print(f"Splash saved to {OUT} ({W}x{H})")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"Error generating splash: {e}", file=sys.stderr)
        sys.exit(1)
