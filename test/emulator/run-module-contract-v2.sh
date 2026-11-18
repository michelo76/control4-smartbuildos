#!/bin/sh
# Runs the module contract v2 scenario under the Director emulator with the
# REAL Agent (drivers/smartbuildos) and two copies of a test-fixture module
# driver (test/emulator/fixtures/sbos-v2-probe), from THIS working tree.
#
#   test/emulator/run-module-contract-v2.sh [path/to/control4-director-emulator]
#
# The emulator is used read-only: drivers are assembled into a temp dir
# (OSS preprocessor, then src/ and vendor/ beside each driver, as
# examples/connector/assemble.sh does) and DIRECTOR_CACHE points there too,
# so nothing is written into the emulator's tree or this repo.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
EMU=${1:-${DIRECTOR_EMULATOR:-$REPO/../control4-director-emulator}}
EMU=$(cd "$EMU" && pwd)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/sbos-v2-emulator.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/tree"
rsync -a --exclude .git --exclude build --exclude dist "$REPO/" "$OUT/tree/"
(cd "$OUT/tree" && python3 -I tools/preprocess.py --oss >/dev/null)
assemble() {
	dest=$OUT/$1
	mkdir -p "$dest"
	cp -R "$2/." "$dest/"
	cp -R "$OUT/tree/build/oss/src/." "$dest/"
	cp -R "$OUT/tree/build/oss/vendor/." "$dest/"
}
assemble smartbuildos "$OUT/tree/build/oss/drivers/smartbuildos"
assemble sbos-v2-consumer "$REPO/test/emulator/fixtures/sbos-v2-probe"
assemble sbos-v2-provider "$REPO/test/emulator/fixtures/sbos-v2-probe"
sed -i.bak 's|<default>consumer</default>|<default>provider</default>|' "$OUT/sbos-v2-provider/driver.xml"
cd "$OUT"
SBOS_V2_OUT=$OUT DIRECTOR_EMULATOR=$EMU DIRECTOR_CACHE=$OUT/cache \
	luajit "$EMU/bin/director.lua" run "$REPO/test/emulator/module_contract_v2.lua"
