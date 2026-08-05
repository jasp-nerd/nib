#!/bin/bash
#
# Launch-time measurement.
#
# Phase 0's real deliverable: know the floor before writing UI against a 400 ms budget. A
# single sample is noise (first run pays page-in and dyld cache warming), so this takes
# several and reports all of them plus the median.
#
# Also captures the dyld breakdown, which attributes anything slow to a specific phase --
# dylib loading vs rebase/binding vs ObjC setup vs static initializers.
#
#   ./Tools/measure-launch.sh [runs]

set -uo pipefail
cd "$(dirname "$0")/.."

RUNS="${1:-5}"
BIN="dist/Nib.app/Contents/MacOS/Nib"

if [ ! -x "$BIN" ]; then
    echo "no build found -- run: ./Tools/build-app.sh --release"
    exit 1
fi

echo "measuring $RUNS launches of $BIN"
echo

samples=()
for i in $(seq 1 "$RUNS"); do
    log=$(mktemp)
    NIB_LAUNCH_TRACE=1 "$BIN" 2>"$log" &
    pid=$!

    # Poll for the trace line rather than sleeping a fixed amount, so a fast launch is not
    # padded and a hung one still terminates.
    ms=""
    for _ in $(seq 1 100); do
        if grep -q "launch ->" "$log" 2>/dev/null; then
            ms=$(sed -n 's/.*launch -> first frame: \([0-9.]*\) ms.*/\1/p' "$log" | head -1)
            break
        fi
        sleep 0.05
    done

    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null

    if [ -n "$ms" ]; then
        samples+=("$ms")
        printf "  run %d: %s ms\n" "$i" "$ms"
    else
        printf "  run %d: no trace captured\n" "$i"
    fi
    rm -f "$log"
done

echo
if [ "${#samples[@]}" -gt 0 ]; then
    median=$(printf '%s\n' "${samples[@]}" | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}')
    echo "median: ${median} ms   (budget 400 ms, target 250 ms)"
else
    echo "no samples captured -- the app may need a GUI session to reach first frame"
fi

echo
echo "note: the figure above is main() -> first frame. Pre-main dyld work is extra."
echo
echo "dyld pre-main breakdown:"
dyld_out=$(mktemp)
DYLD_PRINT_STATISTICS=1 "$BIN" >"$dyld_out" 2>&1 &
dyld_pid=$!
sleep 2
kill "$dyld_pid" 2>/dev/null
wait "$dyld_pid" 2>/dev/null

if grep -q "total time" "$dyld_out" 2>/dev/null; then
    sed 's/^/    /' "$dyld_out"
else
    # dyld strips DYLD_* variables in a number of situations on current macOS, so treat this
    # as best-effort rather than pretending it failed silently. Instruments' App Launch
    # template is the reliable route, and it needs Xcode.
    echo "    unavailable -- macOS suppressed DYLD_PRINT_STATISTICS for this binary."
    echo "    Use Instruments' App Launch template (needs Xcode) for the pre-main split."
    echo
    echo "    Proxy check: every linked dylib should be a system one, since those come"
    echo "    precomputed from the dyld shared cache and cost ~nothing, whereas an embedded"
    echo "    framework must be parsed and relocated on every launch."
    otool -L "$BIN" 2>/dev/null | tail -n +2 | awk '{print $1}' \
        | grep -vE '^(/usr/lib|/System/)' | sed 's/^/      NON-SYSTEM: /' \
        || true
    if [ -z "$(otool -L "$BIN" 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib|/System/)')" ]; then
        echo "      all system dylibs - nothing embedded"
    fi
fi
rm -f "$dyld_out"
