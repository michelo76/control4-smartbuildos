#!/bin/sh
# Runs the guide's consistency test and browser test.
# Needs Node ≥ 22 (type stripping) and the platform worktree beside this repo
# (or AI_CORE_PLATFORM) for Playwright and the real permission engine (read only).
set -e
cd "$(dirname "$0")"
node --experimental-strip-types --no-warnings consistency.test.mjs
node --experimental-strip-types --no-warnings guide.browser.test.mjs
