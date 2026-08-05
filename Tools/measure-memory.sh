#!/bin/bash
#
# Memory measurement.
#
# Uses `footprint`, NOT `ps -o rss=`.
#
# This distinction cost a false alarm. RSS on macOS counts resident pages of *shared* framework
# text — AppKit, SwiftUI, CoreFoundation — which are shared across every process on the machine and
# are not attributable to us. It therefore drifts with unrelated system activity: the same binary
# measured 36 MB and then 106 MB by RSS while its actual footprint moved from 36 MB to 39 MB.
#
# "Physical footprint" is the number Apple uses for memory limits and jetsam accounting, and it is
# the one to hold a budget against.
#
#   ./Tools/measure-memory.sh [seconds-to-settle]

set -uo pipefail
cd "$(dirname "$0")/.."

SETTLE="${1:-4}"
BUDGET_MB=35
BIN="dist/Nib.app/Contents/MacOS/Nib"

if [ ! -x "$BIN" ]; then
    echo "no build found -- run: ./Tools/build-app.sh --release"
    exit 1
fi

"$BIN" >/dev/null 2>&1 &
pid=$!
sleep "$SETTLE"

if ! kill -0 "$pid" 2>/dev/null; then
    echo "the app exited before it could be measured"
    exit 1
fi

report=$(footprint -p "$pid" 2>/dev/null)
rss_kb=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')

kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null

footprint_mb=$(echo "$report" | sed -n 's/.*Footprint: \([0-9.]*\) MB.*/\1/p' | head -1)

echo "physical footprint: ${footprint_mb:-?} MB   (budget ${BUDGET_MB} MB)"
echo "ps RSS:             $(awk -v k="${rss_kb:-0}" 'BEGIN{printf "%.1f", k/1024}') MB   (not a budget metric -- see header)"
echo
echo "biggest categories:"
echo "$report" | sed -n '/Category/,/^$/p' | head -12 | sed 's/^/    /'
echo

if [ -z "$footprint_mb" ]; then
    echo "memory: SKIPPED -- could not parse footprint output"
    exit 0
fi

if [ "${footprint_mb%%.*}" -gt "$BUDGET_MB" ]; then
    echo "memory: OVER budget by $(( ${footprint_mb%%.*} - BUDGET_MB )) MB"
    echo "  MALLOC_SMALL is usually the app's own heap; a jump there is ours to explain."
    exit 1
fi

echo "memory: ok"
