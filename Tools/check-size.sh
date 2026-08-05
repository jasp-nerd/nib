#!/bin/bash
#
# Bundle size gate.
#
# The README claims a size on disk. That claim is the pitch, so it gets a build-time guard
# rather than a periodic manual check -- a dependency added in an unrelated PR should turn the
# build red the same day, not be discovered by a stranger with `du` after launch.
#
# Prints a segment breakdown on every run so a regression is attributable rather than merely
# detected.
#
# Works with Command Line Tools only, because it measures the bundle assembled by
# Tools/build-app.sh rather than an xcodebuild archive.

set -uo pipefail
cd "$(dirname "$0")/.."

BUDGET_KB=5120   # 5.0 MB
APP="dist/Nib.app"
BIN="$APP/Contents/MacOS/Nib"

if [ ! -d "$APP" ]; then
    echo "no bundle found -- run: ./Tools/build-app.sh --release"
    exit 1
fi

size_kb=$(du -sk "$APP" | cut -f1)
bin_kb=$(du -k "$BIN" | cut -f1)

echo "bundle:  ${size_kb} KB   (budget ${BUDGET_KB} KB)"
echo "binary:  ${bin_kb} KB"
echo

echo "segments:"
size -m "$BIN" 2>/dev/null | sed -n '1,12p' | sed 's/^/    /'
echo

echo "linked dylibs (each non-system one is launch-time tax):"
otool -L "$BIN" 2>/dev/null | tail -n +2 | awk '{print $1}' | sed 's/^/    /'
echo

# Any embedded framework is a red flag: dyld must parse and relocate it on every launch,
# unlike the system dylibs which come precomputed from the shared cache.
if [ -d "$APP/Contents/Frameworks" ]; then
    echo "WARNING: $APP/Contents/Frameworks exists -- something is being embedded."
    du -sh "$APP/Contents/Frameworks"/* 2>/dev/null | sed 's/^/    /'
    echo
fi

if [ "$size_kb" -gt "$BUDGET_KB" ]; then
    echo "size: FAILED -- ${size_kb} KB exceeds ${BUDGET_KB} KB by $((size_kb - BUDGET_KB)) KB"
    echo
    echo "  Most likely causes, in order:"
    echo "    1. A new package dependency (check Package.resolved)"
    echo "    2. A .library(type: .dynamic) embedding a framework"
    echo "    3. The strip step being skipped"
    echo "    4. Bitmap assets that should be SF Symbols"
    exit 1
fi

pct=$((size_kb * 100 / BUDGET_KB))
echo "size: ok -- ${size_kb} KB, ${pct}% of budget"
exit 0
