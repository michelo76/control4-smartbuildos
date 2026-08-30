#!/usr/bin/env python3
"""Generate the Bond suite's Navigator/Composer icons from inline SVG.

One visual language across the whole suite, instead of the mixed emoji-style
art the commercial Bond driver ships: geometric glyphs, one warm amber
gradient for "active", cool neutral strokes for "inactive", green/red badges
only where they mean up/down.

Outputs (committed to the repo; re-run only when the art changes):
  drivers/bond-fireplace/www/icons/{70x70,90x90,300x300}/*.png
  drivers/bond-generic/www/icons/{70x70,90x90,300x300}/*.png
  drivers/<each>/www/icons/device_sm.png (16px) + device_lg.png (32px)

Dependency: cairosvg (pip install cairosvg into the repo venv; not part of
requirements.txt because builds never run this — the PNGs are committed).

Usage: .venv/bin/python3 tools/bond_icons.py
"""

from pathlib import Path

import cairosvg

ROOT = Path(__file__).resolve().parent.parent
DRIVERS = ROOT / "drivers"

UIBUTTON_SIZES = [70, 90, 300]

# ─── SVG building blocks ──────────────────────────────────────────────────────

DEFS = """
<defs>
  <!-- userSpaceOnUse: an objectBoundingBox gradient on a zero-width shape
       (the power stem is a vertical line) has an undefined bbox and paints
       NOTHING. Fixed canvas coordinates paint everything. -->
  <linearGradient id="amber" x1="0" y1="100" x2="0" y2="0" gradientUnits="userSpaceOnUse">
    <stop offset="0" stop-color="#ea580c"/>
    <stop offset="0.55" stop-color="#f59e0b"/>
    <stop offset="1" stop-color="#fbbf24"/>
  </linearGradient>
  <linearGradient id="amberCore" x1="0" y1="1" x2="0" y2="0">
    <stop offset="0" stop-color="#fbbf24"/>
    <stop offset="1" stop-color="#fef3c7"/>
  </linearGradient>
  <filter id="glow" x="-40%" y="-40%" width="180%" height="180%">
    <feGaussianBlur stdDeviation="3.5" result="b"/>
    <feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge>
  </filter>
</defs>
"""

NEUTRAL = "#cbd5e1"
DIM = "#64748b"


def svg(body: str) -> str:
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">'
        + DEFS
        + body
        + "</svg>"
    )


def flame(scale: float, active: bool, cx: float = 50.0, cy: float = 54.0) -> str:
    """The suite's flame glyph. `scale` sizes it (1.0 = full), active picks
    the amber gradient vs a dim outline."""
    fill = "url(#amber)" if active else "none"
    stroke = "" if active else f' stroke="{DIM}" stroke-width="4"'
    core = (
        f'<path d="M0,16 C-7,8 -6,2 0,-8 C6,2 7,8 0,16 Z" fill="url(#amberCore)"/>'
        if active
        else ""
    )
    glow = ' filter="url(#glow)"' if active else ""
    return f"""
<g transform="translate({cx},{cy}) scale({scale})"{glow}>
  <path d="M0,34 C-19,34 -28,20 -28,6 C-28,-10 -16,-20 -10,-34
           C-6,-26 -8,-20 -4,-14 C2,-24 0,-32 6,-40
           C12,-26 28,-16 28,4 C28,21 18,34 0,34 Z" fill="{fill}"{stroke}/>
  {core}
</g>"""


def power(active: bool) -> str:
    color = "url(#amber)" if active else NEUTRAL
    glow = ' filter="url(#glow)"' if active else ""
    return f"""
<g{glow}>
  <path d="M 33.5 26.5 A 29 29 0 1 0 66.5 26.5" fill="none"
        stroke="{color}" stroke-width="9" stroke-linecap="round"/>
  <line x1="50" y1="16" x2="50" y2="46"
        stroke="{color}" stroke-width="9" stroke-linecap="round"/>
</g>"""


def fan_rotor(color: str, spin_arcs: int = 0) -> str:
    """Three-blade rotor; spin_arcs (0-3) adds motion arcs for speed states."""
    blades = "".join(
        f'<path d="M50,50 C38,44 30,34 34,22 C38,12 50,12 50,26 Z" fill="{color}" transform="rotate({angle} 50 50)"/>'
        for angle in (0, 120, 240)
    )
    arcs = ""
    arc_defs = [
        ("M 78 34 A 34 34 0 0 1 84 50", 1),
        ("M 84 58 A 34 34 0 0 1 76 72", 2),
        ("M 70 78 A 34 34 0 0 1 56 84", 3),
    ]
    for path, index in arc_defs:
        if spin_arcs >= index:
            arcs += (
                f'<path d="{path}" fill="none" stroke="url(#amber)" '
                'stroke-width="5" stroke-linecap="round"/>'
            )
    return f"""
<g>
  {blades}
  <circle cx="50" cy="50" r="9" fill="{color}"/>
  <circle cx="50" cy="50" r="3.5" fill="#1e293b"/>
  {arcs}
</g>"""


def badge(direction: str) -> str:
    """Up/down chevron badge, top-right corner."""
    fill = "#22c55e" if direction == "up" else "#ef4444"
    chevron = (
        '<path d="M 74 26 L 81 18 L 88 26" fill="none" stroke="#ffffff" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/>'
        if direction == "up"
        else '<path d="M 74 18 L 81 26 L 88 18" fill="none" stroke="#ffffff" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/>'
    )
    return f'<circle cx="81" cy="22" r="15" fill="{fill}"/>{chevron}'


def bulb(active: bool) -> str:
    color = "url(#amber)" if active else NEUTRAL
    rays = ""
    if active:
        for angle in range(0, 360, 45):
            rays += (
                f'<line x1="0" y1="-34" x2="0" y2="-42" stroke="url(#amber)" '
                f'stroke-width="5" stroke-linecap="round" transform="translate(50 42) rotate({angle})"/>'
            )
    return f"""
<g>
  {rays}
  <path d="M50,16 A 26 26 0 0 1 63 64 L 63 70 L 37 70 L 37 64 A 26 26 0 0 1 50 16 Z"
        fill="none" stroke="{color}" stroke-width="6" stroke-linejoin="round"/>
  <line x1="38" y1="78" x2="62" y2="78" stroke="{color}" stroke-width="6" stroke-linecap="round"/>
  <line x1="42" y1="86" x2="58" y2="86" stroke="{color}" stroke-width="6" stroke-linecap="round"/>
</g>"""


def shade_glyph() -> str:
    return f"""
<g stroke="{NEUTRAL}" stroke-width="5" fill="none" stroke-linecap="round">
  <rect x="20" y="14" width="60" height="72" rx="4"/>
  <rect x="26" y="20" width="48" height="26" rx="2" fill="{NEUTRAL}" stroke="none"/>
  <line x1="26" y1="54" x2="74" y2="54"/>
  <line x1="50" y1="46" x2="50" y2="66"/>
  <path d="M 44 61 L 50 68 L 56 61" fill="none"/>
</g>"""


def heater_glyph() -> str:
    """Radiant heat: three rising heat waves over a base bar."""
    waves = "".join(
        f'<path d="M {x} 66 C {x - 6} 56 {x + 6} 46 {x} 36 C {x - 6} 26 {x + 6} 16 {x} 10"'
        f' fill="none" stroke="url(#amber)" stroke-width="6" stroke-linecap="round"/>'
        for x in (34, 50, 66)
    )
    return f"""
<g>
  {waves}
  <line x1="24" y1="82" x2="76" y2="82" stroke="{NEUTRAL}" stroke-width="6" stroke-linecap="round"/>
  <line x1="32" y1="90" x2="68" y2="90" stroke="{NEUTRAL}" stroke-width="6" stroke-linecap="round"/>
</g>"""


def bridge_glyph() -> str:
    return f"""
<g stroke="{NEUTRAL}" stroke-width="5" fill="none" stroke-linecap="round">
  <rect x="22" y="52" width="56" height="26" rx="8"/>
  <circle cx="36" cy="65" r="3.5" fill="{NEUTRAL}" stroke="none"/>
  <path d="M 38 40 A 17 17 0 0 1 62 40"/>
  <path d="M 30 30 A 28 28 0 0 1 70 30"/>
</g>"""


# ─── Icon catalog ─────────────────────────────────────────────────────────────

FIREPLACE_ICONS = {
    "power-off": svg(power(False)),
    "power-on": svg(power(True)),
    "flame-off": svg(flame(0.9, False)),
    "flame-low": svg(flame(0.62, True)),
    "flame-medium": svg(flame(0.8, True)),
    "flame-high": svg(flame(1.0, True)),
    "flame-up": svg(flame(0.85, True) + badge("up")),
    "flame-down": svg(flame(0.85, True) + badge("down")),
    "fpfan-off": svg(fan_rotor(DIM, 0)),
    "fpfan-low": svg(fan_rotor(NEUTRAL, 1)),
    "fpfan-medium": svg(fan_rotor(NEUTRAL, 2)),
    "fpfan-high": svg(fan_rotor(NEUTRAL, 3)),
}

GENERIC_ICONS = {
    "power-off": svg(power(False)),
    "power-on": svg(power(True)),
}

DEVICE_ICONS = {
    "bond-bridge": svg(bridge_glyph()),
    "bond-fan": svg(fan_rotor(NEUTRAL, 0)),
    "bond-light": svg(bulb(False)),
    "bond-shade": svg(shade_glyph()),
    "bond-fireplace": svg(flame(0.9, True)),
    "bond-heater": svg(heater_glyph()),
    "bond-generic": svg(power(False)),
}


def render(svg_text: str, path: Path, size: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    cairosvg.svg2png(
        bytestring=svg_text.encode(),
        write_to=str(path),
        output_width=size,
        output_height=size,
    )


def main() -> None:
    count = 0
    for driver, icons in (
        ("bond-fireplace", FIREPLACE_ICONS),
        ("bond-generic", GENERIC_ICONS),
    ):
        for name, svg_text in icons.items():
            for size in UIBUTTON_SIZES:
                render(
                    svg_text,
                    DRIVERS
                    / driver
                    / "www"
                    / "icons"
                    / f"{size}x{size}"
                    / f"{name}.png",
                    size,
                )
                count += 1
    for driver, svg_text in DEVICE_ICONS.items():
        render(svg_text, DRIVERS / driver / "www" / "icons" / "device_sm.png", 16)
        render(svg_text, DRIVERS / driver / "www" / "icons" / "device_lg.png", 32)
        count += 2
    print(f"rendered {count} icons")


if __name__ == "__main__":
    main()
