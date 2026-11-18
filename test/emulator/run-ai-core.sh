#!/bin/sh
# Runs the AI Core scenario under the Director emulator (EMULATOR ONLY — not
# a bench result) with, from THIS working tree:
#   the REAL Agent            drivers/smartbuildos
#   the REAL Flight Recorder  drivers/smartbuildos-flight-recorder
#   the REAL AI Core          drivers/smartbuildos-ai-core
# plus a v1-only Agent taken from git (the last commit before module
# contract v2, 7db22e7) for the "Agent update required" case.
#
#   test/emulator/run-ai-core.sh [path/to/control4-director-emulator]
#
# The emulator is used read-only: drivers are assembled into a temp dir (OSS
# preprocessor, then src/ and vendor/ beside each driver, as
# examples/connector/assemble.sh does) and DIRECTOR_CACHE points there too.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
EMU=${1:-${DIRECTOR_EMULATOR:-$REPO/../control4-director-emulator}}
EMU=$(cd "$EMU" && pwd)
V1_REF=${SBOS_V1_AGENT_REF:-7db22e7}
OUT=$(mktemp -d "${TMPDIR:-/tmp}/sbos-ai-core-emulator.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/tree" "$OUT/v1tree"
rsync -a --exclude .git --exclude build --exclude dist "$REPO/" "$OUT/tree/"
(cd "$OUT/tree" && python3 -I tools/preprocess.py --oss >/dev/null)
git -C "$REPO" archive "$V1_REF" drivers/smartbuildos src vendor tools | tar -x -C "$OUT/v1tree"
(cd "$OUT/v1tree" && python3 -I tools/preprocess.py --oss >/dev/null)
assemble() {
	dest=$OUT/$1
	mkdir -p "$dest"
	cp -R "$2/." "$dest/"
	cp -R "$3/build/oss/src/." "$dest/"
	cp -R "$3/build/oss/vendor/." "$dest/"
}
assemble smartbuildos "$OUT/tree/build/oss/drivers/smartbuildos" "$OUT/tree"
assemble smartbuildos-flight-recorder "$OUT/tree/build/oss/drivers/smartbuildos-flight-recorder" "$OUT/tree"
assemble smartbuildos-ai-core "$OUT/tree/build/oss/drivers/smartbuildos-ai-core" "$OUT/tree"
# The v1 Agent keeps the Agent's file name so dependents find it by name.
mkdir -p "$OUT/v1"
assemble v1/smartbuildos "$OUT/v1tree/build/oss/drivers/smartbuildos" "$OUT/v1tree"
cd "$OUT"
SBOS_AI_OUT=$OUT DIRECTOR_EMULATOR=$EMU DIRECTOR_CACHE=$OUT/cache \
	luajit "$EMU/bin/director.lua" run "$REPO/test/emulator/ai_core.lua"
