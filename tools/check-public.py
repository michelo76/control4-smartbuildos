#!/usr/bin/env python3
"""Refuse private data in a public repository.

This repository is public, so nothing committed may carry a site's network
addresses, a person's home folder, a key or token, a site's coordinates or a
Telegram chat id. gitleaks covers secrets before a push; this check runs in CI
on every pull request and also covers the things that are not secrets but
still must not be published.

Scans every file `git ls-files` lists (text files only) for:

- home folders (/Users/<name>/, /home/<name>/, C:\\Users\\<name>\\), except
  placeholder names such as `you` or `user`
- key and token shapes: GitHub, Stripe live, OpenAI-style sk-, Slack, AWS,
  Telegram bot tokens, JWTs
- latitude/longitude pairs given to four or more decimals
- Telegram group chat ids (-100 followed by ten digits)
- every term in tools/.public-denylist, when that file exists: one term per
  line, matched without regard to case. It holds what must never appear but
  cannot itself be published (customer and site names, the bench's real
  addresses), so it is gitignored and the check only runs where it exists.

Private network addresses are not a rule of their own: the tests and the
vendors' API documents are full of made-up ones (192.168.1.50), and only the
real ones matter, which is what the denylist is for. Examples should use the
documentation ranges 192.0.2.0/24, 198.51.100.0/24 and 203.0.113.0/24.

A finding that is fine to publish goes in tools/public-allowlist.txt as
`path<TAB>exact text` (path `*` for any file), with a comment saying why.

Usage: tools/check-public.py            (exit 1 when anything is found)
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ALLOWLIST = ROOT / "tools" / "public-allowlist.txt"
DENYLIST = ROOT / "tools" / ".public-denylist"

PLACEHOLDER_USERS = {
    "you",
    "user",
    "username",
    "me",
    "name",
    "example",
    "runner",
    "shared",
    "public",
}

RULES: list[tuple[str, re.Pattern[str]]] = [
    (
        "home folder",
        re.compile(r"(?:/Users/|/home/|C:\\\\?Users\\\\?)([A-Za-z][A-Za-z0-9._-]+)"),
    ),
    (
        "key or token",
        re.compile(
            r"ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,}|gho_[A-Za-z0-9]{30,}"
            r"|sk_live_[A-Za-z0-9]{16,}|rk_live_[A-Za-z0-9]{16,}"
            r"|sk-(?:proj-)?[A-Za-z0-9_-]{32,}"
            r"|xox[abprs]-[A-Za-z0-9-]{10,}"
            r"|AKIA[0-9A-Z]{16}"
            r"|\b\d{8,10}:AA[A-Za-z0-9_-]{30,}"
            r"|eyJ[A-Za-z0-9_-]{15,}\.eyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{10,}"
        ),
    ),
    (
        "coordinates",
        re.compile(r"(?<![\d.])-?\d{1,2}\.\d{4,}\s*,\s*-?\d{1,3}\.\d{4,}(?![\d])"),
    ),
    ("Telegram chat id", re.compile(r"(?<!\d)-100\d{10}(?!\d)")),
]


def load_allowlist() -> set[tuple[str, str]]:
    allowed: set[tuple[str, str]] = set()
    if not ALLOWLIST.exists():
        return allowed
    for raw in ALLOWLIST.read_text(encoding="utf-8").splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if "\t" not in raw:
            print(
                f"public-allowlist.txt: expected `path<TAB>text`: {raw!r}",
                file=sys.stderr,
            )
            continue
        path, text = raw.split("\t", 1)
        allowed.add((path.strip(), text))
    return allowed


def load_denylist() -> list[str]:
    if not DENYLIST.exists():
        return []
    terms = []
    for raw in DENYLIST.read_text(encoding="utf-8").splitlines():
        term = raw.strip()
        if term and not term.startswith("#"):
            terms.append(term.lower())
    return terms


def tracked_files() -> list[str]:
    out = subprocess.run(
        ["git", "ls-files", "-z"], cwd=ROOT, check=True, capture_output=True
    ).stdout
    return [p for p in out.decode("utf-8", "replace").split("\0") if p]


def main() -> int:
    allowed = load_allowlist()
    denied = load_denylist()
    used: set[tuple[str, str]] = set()
    findings: list[str] = []
    for rel in tracked_files():
        path = ROOT / rel
        if rel == "tools/public-allowlist.txt" or not path.is_file():
            continue
        try:
            data = path.read_bytes()
        except OSError:
            continue
        if b"\0" in data[:8192]:
            continue  # binary
        text = data.decode("utf-8", "replace")
        for lineno, line in enumerate(text.splitlines(), 1):
            for label, rule in RULES:
                for m in rule.finditer(line):
                    if (
                        label == "home folder"
                        and m.group(1).lower() in PLACEHOLDER_USERS
                    ):
                        continue
                    hit = m.group(0)
                    for key in ((rel, hit), ("*", hit)):
                        if key in allowed:
                            used.add(key)
                            break
                    else:
                        findings.append(f"{rel}:{lineno}: {label}: {hit}")
            if denied:
                lower = line.lower()
                for term in denied:
                    if term in lower:
                        # The term itself is private: say where, not what.
                        findings.append(
                            f"{rel}:{lineno}: a term from tools/.public-denylist"
                        )
    for entry in sorted(allowed - used):
        findings.append(
            f"tools/public-allowlist.txt: unused entry {entry[0]}\t{entry[1]} (remove it)"
        )
    for f in findings:
        print(f)
    if findings:
        print(
            f"\n{len(findings)} finding(s). This repository is public: remove the data, "
            "use a placeholder (192.0.2.x, ~/, <token>), or allowlist it with a reason "
            "in tools/public-allowlist.txt.",
            file=sys.stderr,
        )
        return 1
    note = (
        f" (and {len(denied)} private terms)"
        if denied
        else " (no tools/.public-denylist here)"
    )
    print("check-public: no private data found" + note)
    return 0


if __name__ == "__main__":
    sys.exit(main())
