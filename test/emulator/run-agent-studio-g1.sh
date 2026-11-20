#!/bin/sh
# Runs the Studio release G1 scenario under the Director emulator with the
# REAL Agent (drivers/smartbuildos) from THIS working tree, and writes the
# captured heartbeat / devices bodies to docs/studio-g1/sample-payloads/
# (pretty-printed; JSON null preserved).
#
#   test/emulator/run-agent-studio-g1.sh [path/to/control4-director-emulator]
#
# The emulator is used read-only: the Agent is assembled into a temp dir (OSS
# preprocessor, then src/ and vendor/ beside it, as examples/connector/
# assemble.sh does) and DIRECTOR_CACHE points there too, so nothing is written
# into the emulator's tree. Only the sample payloads land in this repo.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
EMU=${1:-${DIRECTOR_EMULATOR:-$REPO/../control4-director-emulator}}
EMU=$(cd "$EMU" && pwd)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/sbos-g1-emulator.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/tree" "$OUT/payloads"
rsync -a --exclude .git --exclude build --exclude dist "$REPO/" "$OUT/tree/"
(cd "$OUT/tree" && python3 -I tools/preprocess.py --oss >/dev/null)
dest=$OUT/smartbuildos
mkdir -p "$dest"
cp -R "$OUT/tree/build/oss/drivers/smartbuildos/." "$dest/"
cp -R "$OUT/tree/build/oss/src/." "$dest/"
cp -R "$OUT/tree/build/oss/vendor/." "$dest/"
cd "$OUT"
SBOS_G1_OUT=$OUT SBOS_G1_PAYLOADS=$OUT/payloads DIRECTOR_EMULATOR=$EMU DIRECTOR_CACHE=$OUT/cache \
	luajit "$EMU/bin/director.lua" run "$REPO/test/emulator/agent_studio_g1.lua"
mkdir -p "$REPO/docs/studio-g1/sample-payloads"
for f in "$OUT"/payloads/*.json; do
	python3 -I -m json.tool "$f" >"$REPO/docs/studio-g1/sample-payloads/$(basename "$f")"
done
echo "sample payloads written to docs/studio-g1/sample-payloads/"
