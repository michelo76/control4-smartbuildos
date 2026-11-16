#!/usr/bin/env python3
"""Assembles the VenueFlow pages.

Each page is ONE self-contained HTML file (inline style and script, no external
resource): that is what the driver can serve from its relay and embed in Lua.
The sources are kept as separate files under ui/venueflow and stitched here.

A template (ui/venueflow/<page>/index.html) pulls files in with two markers:

    /*@include shared/base.css*/        inside <style>
    //@include shared/vf.js             inside <script>

Paths are relative to ui/venueflow. A marker must be alone on its line.

    tools/venueflow-ui.py build           write drivers/smartbuildos-venueflow/www/{app,studio}/index.html
    tools/venueflow-ui.py check           exit 1 when a written page is stale (used by the test suite)
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "ui" / "venueflow"
OUT = ROOT / "drivers" / "smartbuildos-venueflow" / "www"
PAGES = {"operator": "app", "studio": "studio"}

MARKER = re.compile(
    r"^[ \t]*(?:/\*@include\s+(\S+?)\s*\*/|//@include\s+(\S+))[ \t]*$", re.M
)


def render(page: str) -> str:
    template = (SRC / page / "index.html").read_text(encoding="utf-8")

    def include(match: "re.Match[str]") -> str:
        rel = match.group(1) or match.group(2)
        path = (SRC / rel).resolve()
        if SRC.resolve() not in path.parents:
            raise SystemExit(f"include outside ui/venueflow: {rel}")
        text = path.read_text(encoding="utf-8")
        if "</script" in text.lower() and path.suffix == ".js":
            raise SystemExit(
                f"{rel} contains a closing script tag; it would end the inline script"
            )
        return text.rstrip("\n")

    out = MARKER.sub(include, template)
    if "@include" in out:
        raise SystemExit(
            f"{page}: an @include marker was not resolved (it must be alone on its line)"
        )
    return out


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    quiet = "--quiet" in sys.argv
    cmd = args[0] if args else "build"
    stale = []
    for page, folder in PAGES.items():
        if not (SRC / page / "index.html").exists():
            continue
        html = render(page)
        target = OUT / folder / "index.html"
        current = target.read_text(encoding="utf-8") if target.exists() else None
        if current == html:
            continue
        if cmd == "check":
            stale.append(str(target.relative_to(ROOT)))
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(html, encoding="utf-8")
            if not quiet:
                print(f"wrote {target.relative_to(ROOT)} ({len(html) // 1024} kB)")
    if stale:
        print(
            "stale page(s): " + ", ".join(stale) + " -- run `make venueflow-ui`",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
