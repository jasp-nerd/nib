#!/bin/bash
#
# Architectural invariants, enforced mechanically.
#
# These are the rules that are cheap to state, expensive to rediscover, and very easy for
# an assistant (or a tired human) to break without anyone noticing at review time. Telling
# a model "don't use Timer" is not a control; failing the build is.
#
# Run: ./Tools/check-boundaries.sh   (or `make boundaries`)

set -uo pipefail
cd "$(dirname "$0")/.."

fail=0

report() {
    fail=1
    echo
    echo "FAIL: $1"
    echo "$2" | sed 's/^/    /'
    echo
    echo "  why: $3"
}

# --- 1. UI frameworks stay in NibUI -------------------------------------------
#
# SPM already enforces that you cannot import a package you did not declare. This catches
# the other direction: reaching for AppKit/SwiftUI from a package that is supposed to stay
# pure. Keeping NibCore/NibHTTP/NibStore/NibInterchange UI-free is what makes them testable
# in milliseconds with no window server.

PURE_PACKAGES=(NibCore NibHTTP NibStore NibInterchange)
for pkg in "${PURE_PACKAGES[@]}"; do
    [ -d "Packages/$pkg/Sources" ] || continue
    hits=$(grep -rnE '^[[:space:]]*import[[:space:]]+(AppKit|SwiftUI|UIKit|WebKit|Cocoa)\b' \
        "Packages/$pkg/Sources" 2>/dev/null)
    if [ -n "$hits" ]; then
        report "$pkg imports a UI framework" "$hits" \
            "$pkg must stay UI-free so it tests headlessly and adds nothing to launch time."
    fi
done

# --- 2. No polling timers ------------------------------------------------------
#
# The single most likely way this app quietly stops being "0% idle CPU". Models reach for
# Timer.scheduledTimer by default because it dominates the training data. Use FSEvents,
# DispatchSource vnode sources, or NSWorkspace notifications instead.
#
# There is currently no legitimate exception. If one appears, add it here with a comment
# saying why -- do not weaken the grep.

timer_hits=$(grep -rnE 'Timer\.scheduledTimer|Timer\.publish|DispatchSource\.makeTimerSource|CADisplayLink' \
    App Packages/*/Sources 2>/dev/null)
if [ -n "$timer_hits" ]; then
    report "polling timer found" "$timer_hits" \
        "Timers keep the CPU out of idle. Use FSEvents / DispatchSource vnode / NSWorkspace notifications."
fi

# --- 3. Every library links statically ----------------------------------------
#
# One `.library(type: .dynamic)` embeds a framework in the bundle. That is pure launch-time
# tax (dyld must parse and relocate it on every start, unlike the shared cache) and it
# blows the size budget. Omit `type:` entirely and let SPM link statically.

dynamic_hits=$(grep -rn 'type:[[:space:]]*\.dynamic' Packages/*/Package.swift 2>/dev/null)
if [ -n "$dynamic_hits" ]; then
    report "a package declares a dynamic library" "$dynamic_hits" \
        "Embedded frameworks cost launch time and bundle size. Omit 'type:' to link statically."
fi

# --- 4. No force unwraps or force try -----------------------------------------
#
# swiftlint covers this properly, but it is not installed everywhere and this catches the
# common shapes cheaply. Deliberate exceptions carry an explicit opt-out comment.

force_hits=$(grep -rnE '(\btry!|\bas!)' App Packages/*/Sources 2>/dev/null \
    | grep -v 'allow-force' || true)
if [ -n "$force_hits" ]; then
    report "force try / force cast found" "$force_hits" \
        "Handle the error. If genuinely impossible, add a trailing '// allow-force: <reason>'."
fi

# --- 5. Third-party dependencies are opt-in, not accidental -------------------
#
# The bundle-size claim in the README depends on this staying at zero. A new dependency is
# a deliberate decision that belongs in an issue, not something that arrives inside an
# unrelated PR.

dep_hits=$(grep -rnE '\.package\(url:' Packages/*/Package.swift 2>/dev/null)
if [ -n "$dep_hits" ]; then
    report "external package dependency declared" "$dep_hits" \
        "Nib ships zero dependencies. Open an issue before adding one; update this check if agreed."
fi

# --- Result --------------------------------------------------------------------

if [ "$fail" -eq 0 ]; then
    echo "boundaries: ok (UI isolation, no timers, static linking, no force-try, no deps)"
else
    echo "boundaries: FAILED -- see above"
fi
exit "$fail"
