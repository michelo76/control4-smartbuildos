#!/bin/sh
# Rebuilds ../SmartBuildOS_AI_Core_Interactive_Guide.html from these parts.
# tool-registry.json is regenerated from the platform worktree with dump-tools.mjs;
# shots/*.webp from the real UI screenshots with make-shots.sh (both checked in).
set -e
cd "$(dirname "$0")"
OUT=../SmartBuildOS_AI_Core_Interactive_Guide.html
{
  cat p1.html p2.html p3.html | node inline-shots.mjs
  printf '<script type="application/json" id="ref-data">'
  node refdata.mjs
  printf '</script>\n<script>\n'
  cat p4a.js p4b.js p4c.js p4d.js p4e.js p4f.js
  printf '</script>\n</body>\n</html>\n'
} > "$OUT"
wc -c "$OUT"
