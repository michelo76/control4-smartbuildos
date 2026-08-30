#!/usr/bin/env python3
"""Generate the Mode Button icon library.

Original geometric glyphs drawn with Pillow — one kind per mode template
plus a few extras, each in an active ("on") and inactive ("off") state at
the three documented Navigator sizes (300/90/70). Re-run after changing a
glyph; output is committed so builds don't depend on Pillow.

Usage: .venv/bin/python3 tools/gen_mode_icons.py
"""

import math
import pathlib

from PIL import Image, ImageDraw

OUT = (
    pathlib.Path(__file__).resolve().parent.parent
    / "drivers"
    / "smartbuildos-mode-button"
    / "www"
    / "icons"
    / "device"
)

SIZE = 300  # master; 90 and 70 are LANCZOS downscales
SIZES = (300, 90, 70)

BG_ON = (38, 44, 54, 255)
BG_OFF = (30, 33, 39, 255)
RING_ON = (255, 255, 255, 235)
GLYPH_ON = (255, 255, 255, 245)
GLYPH_OFF = (140, 148, 160, 200)


def canvas(state):
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    r = 62
    d.rounded_rectangle(
        [10, 10, SIZE - 10, SIZE - 10],
        radius=r,
        fill=BG_ON if state == "on" else BG_OFF,
    )
    if state == "on":
        d.rounded_rectangle(
            [10, 10, SIZE - 10, SIZE - 10], radius=r, outline=RING_ON, width=8
        )
    return img, d, GLYPH_ON if state == "on" else GLYPH_OFF


def poly(d, pts, c, w=None):
    if w:
        d.line(pts + [pts[0]], fill=c, width=w, joint="curve")
    else:
        d.polygon(pts, fill=c)


def glyph_home(d, c):
    poly(
        d,
        [
            (150, 62),
            (242, 140),
            (208, 140),
            (208, 232),
            (92, 232),
            (92, 140),
            (58, 140),
        ],
        c,
    )
    d.rectangle([132, 172, 168, 232], fill=BG_ON if c == GLYPH_ON else BG_OFF)


def glyph_away(d, c):
    d.rectangle([70, 90, 160, 210], outline=c, width=14)
    d.line([(150, 150), (240, 150)], fill=c, width=16)
    poly(d, [(240, 150), (200, 116), (200, 184)], c)


def glyph_vacation(d, c):
    d.line([(150, 230), (150, 120)], fill=c, width=14)
    for ang in (200, 240, 280, 320, 360):
        a = math.radians(ang)
        d.line(
            [(150, 120), (150 + 70 * math.cos(a), 120 + 45 * math.sin(a))],
            fill=c,
            width=12,
        )
    d.arc([60, 208, 240, 268], 180, 360, fill=c, width=12)


def glyph_moon(d, c):
    d.ellipse([70, 70, 230, 230], fill=c)
    d.ellipse([110, 55, 260, 205], fill=BG_ON if c == GLYPH_ON else BG_OFF)


def glyph_film(d, c):
    d.rounded_rectangle([60, 90, 240, 210], radius=16, outline=c, width=14)
    for x in (88, 128, 168, 208):
        d.rectangle([x, 104, x + 18, 122], fill=c)
        d.rectangle([x, 178, x + 18, 196], fill=c)


def glyph_party(d, c):
    poly(d, [(96, 230), (140, 120), (180, 196)], c)
    for x, y in ((178, 96), (210, 130), (226, 80), (196, 60), (240, 170)):
        d.ellipse([x - 9, y - 9, x + 9, y + 9], fill=c)


def glyph_sunrise(d, c):
    d.pieslice([100, 130, 200, 230], 180, 360, fill=c)
    d.line([(60, 200), (240, 200)], fill=c, width=12)
    for ang in (210, 240, 270, 300, 330):
        a = math.radians(ang)
        x1 = 150 + 62 * math.cos(a)
        y1 = 180 + 62 * math.sin(a)
        x2 = 150 + 88 * math.cos(a)
        y2 = 180 + 88 * math.sin(a)
        d.line([(x1, y1), (x2, y2)], fill=c, width=10)


def glyph_night(d, c):
    d.ellipse([76, 84, 208, 216], fill=c)
    d.ellipse([112, 70, 236, 194], fill=BG_ON if c == GLYPH_ON else BG_OFF)
    s = 16
    x, y = 224, 110
    poly(
        d,
        [
            (x, y - s),
            (x + s * 0.35, y - s * 0.35),
            (x + s, y),
            (x + s * 0.35, y + s * 0.35),
            (x, y + s),
            (x - s * 0.35, y + s * 0.35),
            (x - s, y),
            (x - s * 0.35, y - s * 0.35),
        ],
        c,
    )


def glyph_custom(d, c):
    d.ellipse([95, 95, 205, 205], outline=c, width=16)
    d.ellipse([135, 135, 165, 165], fill=c)


def glyph_lock(d, c):
    d.rounded_rectangle([90, 140, 210, 232], radius=14, fill=c)
    d.arc([110, 70, 190, 170], 180, 360, fill=c, width=16)
    d.ellipse([140, 168, 160, 188], fill=BG_ON if c == GLYPH_ON else BG_OFF)


def glyph_shield(d, c):
    poly(d, [(150, 62), (232, 92), (232, 160), (150, 238), (68, 160), (68, 92)], c)
    d.line(
        [(112, 150), (140, 182), (196, 116)],
        fill=BG_ON if c == GLYPH_ON else BG_OFF,
        width=18,
        joint="curve",
    )


def glyph_energy(d, c):
    poly(d, [(168, 58), (98, 168), (144, 168), (128, 242), (206, 128), (156, 128)], c)


def glyph_cleaning(d, c):
    for x, y, s in ((150, 140, 52), (216, 92, 22), (96, 210, 18)):
        poly(
            d,
            [
                (x, y - s),
                (x + s * 0.28, y - s * 0.28),
                (x + s, y),
                (x + s * 0.28, y + s * 0.28),
                (x, y + s),
                (x - s * 0.28, y + s * 0.28),
                (x - s, y),
                (x - s * 0.28, y - s * 0.28),
            ],
            c,
        )


def glyph_work(d, c):
    d.rounded_rectangle([66, 120, 234, 226], radius=14, outline=c, width=14)
    d.line([(120, 120), (120, 96), (180, 96), (180, 120)], fill=c, width=12)
    d.line([(66, 168), (234, 168)], fill=c, width=10)


def glyph_dinner(d, c):
    d.line([(110, 70), (110, 230)], fill=c, width=12)
    for x in (94, 110, 126):
        d.line([(x, 70), (x, 120)], fill=c, width=8)
    d.line([(190, 70), (190, 230)], fill=c, width=12)
    d.arc([172, 60, 208, 140], 160, 380, fill=c, width=10)


def glyph_guest(d, c):
    d.ellipse([118, 70, 182, 134], fill=c)
    d.pieslice([84, 140, 216, 280], 180, 360, fill=c)


GLYPHS = {
    "home": glyph_home,
    "away": glyph_away,
    "vacation": glyph_vacation,
    "moon": glyph_moon,
    "film": glyph_film,
    "party": glyph_party,
    "sunrise": glyph_sunrise,
    "night": glyph_night,
    "custom": glyph_custom,
    "lock": glyph_lock,
    "shield": glyph_shield,
    "energy": glyph_energy,
    "cleaning": glyph_cleaning,
    "work": glyph_work,
    "dinner": glyph_dinner,
    "guest": glyph_guest,
}


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for kind, fn in GLYPHS.items():
        for state in ("on", "off"):
            img, d, color = canvas(state)
            fn(d, color)
            for size in SIZES:
                out = img if size == SIZE else img.resize((size, size), Image.LANCZOS)
                out.save(OUT / f"{kind}_{state}_{size}.png")
    # The default (unassigned) icon is the custom glyph, off state.
    for size in SIZES:
        src = Image.open(OUT / f"custom_off_{size}.png")
        src.save(OUT / f"default_{size}.png")
    n = len(list(OUT.glob("*.png")))
    print(f"wrote {n} icons to {OUT}")


if __name__ == "__main__":
    main()
