#!/bin/bash
#
# Assemble Nib.app from the SwiftPM executable.
#
# Exists so the app can be built, launched and measured with only Command Line Tools. The
# Phase 0 job is to establish the launch-time floor and size baseline *before* writing UI
# against a 400 ms budget, and that cannot wait on an Xcode install.
#
#   ./Tools/build-app.sh              debug build, ad-hoc signed
#   ./Tools/build-app.sh --release    release build with size flags, stripped
#
# Ad-hoc signing (`codesign -s -`) is deliberate for local builds: it needs no keychain and
# therefore never blocks on a GUI password prompt. It is fine here because Nib requests zero
# TCC permissions, so there is no grant for a changing signature to invalidate. A release picks up
# the persistent identity automatically if Tools/selfsign.sh has been run on this machine.

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="debug"
SWIFT_FLAGS=()
if [ "${1:-}" = "--release" ]; then
    CONFIG="release"
    # -Osize over -O: we are optimising for bundle size, and for a UI app the difference in
    # throughput is unmeasurable. Dead-strip removes unreferenced code at link time.
    SWIFT_FLAGS=(-c release -Xswiftc -Osize -Xlinker -dead_strip)
else
    SWIFT_FLAGS=(-c debug)
fi

APP="dist/Nib.app"
CONTENTS="$APP/Contents"

echo "==> building ($CONFIG)"
swift build "${SWIFT_FLAGS[@]}" --product Nib

BIN_PATH="$(swift build "${SWIFT_FLAGS[@]}" --product Nib --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BIN_PATH/Nib" "$CONTENTS/MacOS/Nib"
cp App/Info.plist "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

# SwiftPM emits .bundle directories for targets that declare resources. Copy any that exist so
# Bundle.module keeps working inside the app.
for bundle in "$BIN_PATH"/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$CONTENTS/Resources/"
done

if [ "$CONFIG" = "release" ]; then
    echo "==> stripping"
    # -x removes local symbols only. Anything more aggressive risks the Swift runtime metadata
    # the reflection APIs need, and buys very little on a binary this size.
    strip -x "$CONTENTS/MacOS/Nib"
fi

# A release signs with the persistent identity when it is on the machine, and falls back to
# ad-hoc when it is not, so a fresh clone still builds with an empty keychain.
#
# The difference matters more than it looks. An ad-hoc signature is regenerated from scratch every
# build, so macOS treats each release as a different program: the Keychain access control we rely
# on for environment secrets is bound to the signature, and it breaks on every upgrade. A stable
# self-signed identity fixes that and costs nothing. This is also what Tinycast ships with, for the
# same reason. See Tools/selfsign.sh and docs/signing.md.
IDENTITY="Nib Self-Signed"
if [ "$CONFIG" = "release" ] && security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    echo "==> signing ($IDENTITY)"
    codesign --force --sign "$IDENTITY" --timestamp=none "$APP" 2>&1 | sed 's/^/    /'
else
    echo "==> signing (ad-hoc)"
    codesign --force --sign - --timestamp=none "$APP" 2>&1 | sed 's/^/    /'
fi

# Validate rather than assume. A bundle that fails verification launches with a Gatekeeper
# dialog, and finding that out at launch time is worse than finding it out here.
codesign --verify --deep --strict "$APP" && echo "    signature ok"

echo
echo "==> result"
du -sh "$APP" | sed 's/^/    /'
echo "    binary: $(du -h "$CONTENTS/MacOS/Nib" | cut -f1)"
echo
echo "run it:   open $APP     (or: $CONTENTS/MacOS/Nib to see stderr)"
