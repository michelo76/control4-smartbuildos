#!/usr/bin/env python3
"""Generate the Flight Recorder's built-in event catalogue from a driver library.

Reads every ``.c4z`` (a zip whose ``driver.xml`` is plain text even when the
Lua is encrypted) and every ``.c4i`` in the given directories, extracts the
Composer events each driver declares (``<devicedata><events><event>``), and
writes ``src/tracer/catalog_data.lua``: a Lua table keyed by driver FILE NAME
(the exact string ``C4:GetDevices`` reports as ``driverFileName``) mapping
event id to event name.

Why a build-time catalogue: Director offers no documented call that lists
another device's events (CAPABILITY-MATRIX row 7). The tracer therefore needs
to know, per driver file, which event ids exist before it can subscribe with
``C4:RegisterDeviceEvent``. The project XML may carry the same data on the
controller (a bench PROBE, see docs/event-tracer/DESIGN.md); this file is the
offline tier that works on every OS, plus what the tracer learns at runtime.

Usage:
    tools/gen-event-catalog.py ~/Documents/Control4/Drivers ~/Documents/Control4/Projects

A directory may also hold Composer project backups (``.c4p``, a zip with a
``drivers/`` folder). Those are the only local copies of Control4's own c4i
drivers, the lighting and keypad proxies among them (``light_v2.c4i``,
``keypad_proxy.c4i``), which never sit in a dealer's library. Only driver
files are read from a backup; nothing about the project itself is.

Nothing from Control4's docs is copied: only the ids and names that each
driver's own XML declares, which is what Composer shows the dealer.
"""

from __future__ import annotations

import datetime as _dt
import html
import io
import re
import sys
import zipfile
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "src" / "tracer" / "catalog_data.lua"

EVENTS_BLOCK = re.compile(r"<events>(.*?)</events>", re.S | re.I)
EVENT = re.compile(r"<event>(.*?)</event>", re.S | re.I)
ID = re.compile(r"<id>\s*(\d+)\s*</id>", re.I)
NAME = re.compile(r"<name>\s*(.*?)\s*</name>", re.S | re.I)
DESCRIPTION = re.compile(r"<description>\s*(.*?)\s*</description>", re.S | re.I)
CONSTANT = re.compile(r"^[A-Z0-9_]+$")
# Placeholders Composer fills in a proxy event's description.
PLACEHOLDER = re.compile(r"\b(NAME|BTN_NAME|BTN_ID)\b")
CDATA = re.compile(r"<!\[CDATA\[(.*?)\]\]>", re.S)


def _clean(text: str) -> str:
    text = CDATA.sub(lambda m: m.group(1), text)
    text = html.unescape(text)
    text = re.sub(r"\s+", " ", text).strip()
    return text[:120]


def readable_name(name: str, description: str | None) -> str:
    """A proxy event's name is a constant (``PUSH``); Composer shows its
    description instead (``When NAME BTN_NAME button is pushed``). For such
    an event, use the description without its placeholders (``Button is
    pushed``). Every other name is kept exactly as declared: a plain number
    (the timer drivers' "10"), a description with no placeholder, or one that
    would still read as a constant ("IP_CONNECTED on", "BUTTONNAME has
    changed")."""
    if not description or not CONSTANT.match(name) or not re.search(r"[A-Z]", name):
        return name
    text = _clean(description)
    if not PLACEHOLDER.search(text):
        return name
    text = PLACEHOLDER.sub("", text)
    text = re.sub(r"^\s*When\s+", "", text, flags=re.I)
    text = re.sub(r"\s+", " ", text).strip()
    if not text or re.search(r"\b(?:[A-Z0-9]*_[A-Z0-9_]*|[A-Z]{6,})\b", text):
        return name
    return (text[0].upper() + text[1:])[:120]


def events_from_xml(xml: str) -> dict[int, str]:
    """Top-level ``<events>`` of a driver.xml → {id: name}.

    Proxy sub-documents can carry their own ``<events>``; the first block in a
    driver.xml is the device's own, which is the one Composer lists under the
    device and the one ``C4:RegisterDeviceEvent`` addresses.
    """
    out: dict[int, str] = {}
    block = EVENTS_BLOCK.search(xml)
    if not block:
        return out
    for ev in EVENT.finditer(block.group(1)):
        body = ev.group(1)
        m_id = ID.search(body)
        m_name = NAME.search(body)
        if not m_id or not m_name:
            continue
        name = _clean(m_name.group(1))
        if not name:
            continue
        m_desc = DESCRIPTION.search(body)
        name = readable_name(name, m_desc.group(1) if m_desc else None)
        out[int(m_id.group(1))] = name
    return out


def read_driver_xml(path: Path) -> str | None:
    try:
        if path.suffix.lower() == ".c4z":
            with zipfile.ZipFile(path) as z:
                for member in z.namelist():
                    if member.lower() == "driver.xml" or member.lower().endswith(
                        "/driver.xml"
                    ):
                        return z.read(member).decode("utf-8", errors="replace")
            return None
        if path.suffix.lower() == ".c4i":
            return path.read_text(encoding="utf-8", errors="replace")
    except (zipfile.BadZipFile, OSError):
        return None
    return None


def drivers_in_backup(path: Path):
    """(file name, driver.xml text) for every driver inside a ``.c4p``."""
    try:
        with zipfile.ZipFile(path) as z:
            for member in sorted(z.namelist()):
                parts = member.split("/")
                if len(parts) != 2 or parts[0] != "drivers":
                    continue
                name = parts[1]
                suffix = Path(name).suffix.lower()
                if suffix == ".c4i":
                    yield name, z.read(member).decode("utf-8", errors="replace")
                elif suffix == ".c4z":
                    try:
                        with zipfile.ZipFile(io.BytesIO(z.read(member))) as inner:
                            for m in inner.namelist():
                                if m.lower() == "driver.xml" or m.lower().endswith(
                                    "/driver.xml"
                                ):
                                    yield name, inner.read(m).decode(
                                        "utf-8", errors="replace"
                                    )
                                    break
                    except zipfile.BadZipFile:
                        continue
    except (zipfile.BadZipFile, OSError):
        return


def lua_string(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main(argv: list[str]) -> int:
    dirs = [Path(a).expanduser() for a in argv[1:]] or [
        Path("~/Documents/Control4/Drivers").expanduser()
    ]
    catalog: dict[str, dict[int, str]] = {}
    seen: set[str] = set()
    unreadable: list[str] = []

    def add(file_name: str, xml: str) -> None:
        seen.add(file_name)
        events = events_from_xml(xml)
        if events:
            # A file present in two places: keep the larger event set.
            prev = catalog.get(file_name)
            if prev is None or len(events) > len(prev):
                catalog[file_name] = events

    for d in dirs:
        if not d.is_dir():
            print(f"skip (not a directory): {d}", file=sys.stderr)
            continue
        for path in sorted(d.iterdir()):
            suffix = path.suffix.lower()
            if suffix == ".c4p":
                for file_name, xml in drivers_in_backup(path):
                    add(file_name, xml)
                continue
            if suffix not in (".c4z", ".c4i"):
                continue
            xml = read_driver_xml(path)
            if xml is None:
                unreadable.append(path.name)
                continue
            add(path.name, xml)
    scanned = len(seen)

    total_events = sum(len(v) for v in catalog.values())
    stamp = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%d")
    lines = [
        "--- GENERATED by tools/gen-event-catalog.py — do not edit by hand.",
        f"--- Source: {scanned} distinct driver files scanned on {stamp}; {len(catalog)} declare events;",
        f"--- {total_events} events in all. Keyed by the exact driverFileName C4:GetDevices reports.",
        "--- Values map event id → event name as the driver's own XML declares it",
        "--- (a proxy's constant names, like PUSH, read from their description).",
        "return {",
    ]
    for file in sorted(catalog):
        events = catalog[file]
        items = ", ".join(
            f"[{eid}] = {lua_string(events[eid])}" for eid in sorted(events)
        )
        lines.append(f"  [{lua_string(file)}] = {{ {items} }},")
    lines.append("}")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(
        f"scanned {scanned} files; {len(catalog)} with events; {total_events} events → {OUT}"
    )
    if unreadable:
        print(
            f"unreadable: {len(unreadable)} ({', '.join(unreadable[:8])}{'…' if len(unreadable) > 8 else ''})"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
