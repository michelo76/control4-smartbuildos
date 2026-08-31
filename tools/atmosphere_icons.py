#!/usr/bin/env python3
"""Generate SmartBuildOS Atmosphere's Navigator/Composer icons from inline SVG.

The mark: a sun cresting a cloud over a deep-sky gradient — calm, premium,
readable at 16px. Same pipeline as tools/bond_icons.py (cairosvg in the repo
venv; PNGs are committed, builds never run this).

Outputs:
  drivers/smartbuildos-atmosphere/www/icons/device_sm.png (16)
  drivers/smartbuildos-atmosphere/www/icons/device_lg.png (32)
  drivers/smartbuildos-atmosphere/www/icons/device/experience_{70,90,300,512,1024}.png

Usage: .venv/bin/python3 tools/atmosphere_icons.py
"""

from pathlib import Path

import cairosvg

ROOT = Path(__file__).resolve().parent.parent
ICONS = ROOT / "drivers" / "smartbuildos-atmosphere" / "www" / "icons"

SVG = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <defs>
    <linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#1b2b4d"/>
      <stop offset="0.55" stop-color="#27406e"/>
      <stop offset="1" stop-color="#3d5a8a"/>
    </linearGradient>
    <linearGradient id="sun" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#ffd98a"/>
      <stop offset="1" stop-color="#f5a623"/>
    </linearGradient>
    <linearGradient id="cloud" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#ffffff"/>
      <stop offset="1" stop-color="#c9d6e8"/>
    </linearGradient>
  </defs>
  <rect x="0" y="0" width="512" height="512" rx="112" fill="url(#sky)"/>
  <circle cx="310" cy="212" r="86" fill="url(#sun)"/>
  <g fill="url(#cloud)">
    <circle cx="196" cy="300" r="62"/>
    <circle cx="266" cy="276" r="48"/>
    <circle cx="330" cy="304" r="52"/>
    <rect x="166" y="292" width="196" height="70" rx="35"/>
  </g>
  <rect x="150" y="396" width="212" height="14" rx="7" fill="#8fb4e8" opacity="0.85"/>
  <rect x="188" y="428" width="136" height="12" rx="6" fill="#6f93c4" opacity="0.7"/>
</svg>"""


def render(size: int, out: Path) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    cairosvg.svg2png(
        bytestring=SVG.encode(),
        write_to=str(out),
        output_width=size,
        output_height=size,
    )
    print(f"  {out.relative_to(ROOT)} ({size}px)")


def main() -> None:
    render(16, ICONS / "device_sm.png")
    render(32, ICONS / "device_lg.png")
    for size in (70, 90, 300, 512, 1024):
        render(size, ICONS / "device" / f"experience_{size}.png")


if __name__ == "__main__":
    main()
