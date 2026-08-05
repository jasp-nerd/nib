#!/bin/bash
#
# Take the product screenshot used by the README and the website.
#
# The window is captured with its shadow onto a transparent background and then composited over a
# wallpaper. That is deliberate: it never touches the real desktop, so there is nothing to tidy
# away first and no widgets, files or menu-bar clutter to crop out. It also means the shot is
# reproducible — run it again after a UI change and you get the same framing.
#
# The app is driven by the NIB_SELFTEST_COLLECTION hook so the window always contains the same
# collection, the same request and the same response. A screenshot that depends on whatever
# happened to be on screen is a screenshot you cannot retake.
#
#   ./Tools/screenshot.sh                 # default backdrop
#   BACKDROP=/path/to/image.png ./Tools/screenshot.sh
#
# Needs ImageMagick (brew install imagemagick).

set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Nib.app/Contents/MacOS/Nib"
FIXTURE="${NIB_SCREENSHOT_COLLECTION:-}"
OUT_DOCS="docs/screenshot.png"
OUT_SITE="website/screenshot.png"
PORT=8795

command -v magick >/dev/null || { echo "needs ImageMagick: brew install imagemagick"; exit 1; }
[ -x "$APP" ] || { echo "no build — run: ./Tools/build-app.sh --release"; exit 1; }
[ -n "$FIXTURE" ] || { echo "set NIB_SCREENSHOT_COLLECTION to a collection folder"; exit 1; }

cleanup() {
    pkill -f "dist/Nib.app" 2>/dev/null || true
    [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true
    rm -f /tmp/nib-shot-raw.png /tmp/nib-shot-bg.png /tmp/nib-server.py /tmp/nib-wallpaper.png
}
trap cleanup EXIT

# A local server, so the response in the shot is real rather than mocked.
cat > /tmp/nib-server.py <<'PY'
import http.server, socketserver, json
body = json.dumps({
  "id": 42, "name": "Ada Lovelace", "active": True, "score": -3.5e2,
  "tags": ["math", "engine"], "manager": None,
  "note": "she said \"hi\"", "emoji": "\U0001F389"
}).encode()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Set-Cookie", "session=abc123; Path=/; HttpOnly; Secure; SameSite=Lax")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
socketserver.TCPServer(("127.0.0.1", 8795), H).serve_forever()
PY
python3 /tmp/nib-server.py & SERVER_PID=$!
sleep 1

echo "==> launching with the demo collection"
# A fresh window frame every time, so an autosaved size from a previous run cannot change framing.
defaults delete app.nib.Nib 2>/dev/null || true
NIB_SELFTEST_COLLECTION="$FIXTURE" NIB_SELFTEST_ENVIRONMENT=Local NIB_SELFTEST_HOLD=45 \
    "$APP" >/dev/null 2>&1 &
sleep 7

echo "==> finding the window"
cat > /tmp/nib-winid.swift <<'SWIFT'
import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []
for w in list {
    guard (w[kCGWindowOwnerName as String] as? String) == "Nib",
          (w[kCGWindowLayer as String] as? Int) == 0,
          let b = w[kCGWindowBounds as String] as? [String: CGFloat],
          (b["Width"] ?? 0) > 900, (b["Height"] ?? 0) > 500
    else { continue }
    // Width alone is not enough: the app also owns a menu-bar window that is wide and 78 points
    // tall, and it sorts ahead of the real one.
    print(w[kCGWindowNumber as String] as? Int ?? 0)
    break
}
SWIFT
WINDOW=$(swift /tmp/nib-winid.swift); rm -f /tmp/nib-winid.swift
[ -n "$WINDOW" ] || { echo "could not find the main window"; exit 1; }

# No -o, so the window's shadow is included and the corners come out transparent. That shadow is
# what makes the composite look like a window sitting on a desktop rather than a pasted rectangle.
echo "==> capturing window $WINDOW"
screencapture -x -l"$WINDOW" /tmp/nib-shot-raw.png

W=$(magick identify -format "%w" /tmp/nib-shot-raw.png)
H=$(magick identify -format "%h" /tmp/nib-shot-raw.png)
echo "    window is ${W}x${H}"

# Canvas with room around the window for the backdrop to read as a backdrop.
PAD_X=$((W / 8))
PAD_Y=$((H / 8))
CANVAS_W=$((W + PAD_X * 2))
CANVAS_H=$((H + PAD_Y * 2))

# A real macOS wallpaper by default, which is what the app will actually be sitting on when
# somebody runs it. The system ships these as HEIC and ImageMagick has no HEIC delegate here, so
# sips does the decode — it is part of macOS and always present.
BACKDROP="${BACKDROP:-/System/Library/Desktop Pictures/Mac Purple.heic}"

if [ -f "$BACKDROP" ]; then
    echo "==> backdrop: $(basename "$BACKDROP")"
    case "$BACKDROP" in
        *.heic|*.HEIC)
            sips -s format png "$BACKDROP" --out /tmp/nib-wallpaper.png >/dev/null 2>&1
            SOURCE=/tmp/nib-wallpaper.png ;;
        *) SOURCE="$BACKDROP" ;;
    esac
    # Darkened, because these wallpapers are built to sit behind a bright desktop and at full
    # brightness one competes with the app for attention. The subject of the picture is the app.
    magick "$SOURCE" -resize "${CANVAS_W}x${CANVAS_H}^" -gravity center \
        -extent "${CANVAS_W}x${CANVAS_H}" -brightness-contrast -18x-8 /tmp/nib-shot-bg.png
    rm -f /tmp/nib-wallpaper.png
else
    echo "==> backdrop: generated gradient ($BACKDROP not found)"
    magick -size "${CANVAS_W}x${CANVAS_H}" \
        -define gradient:vector="0,0 ${CANVAS_W},${CANVAS_H}" \
        gradient:'#2b2350'-'#0d0d12' /tmp/nib-shot-bg.png
fi

echo "==> compositing"
magick /tmp/nib-shot-bg.png /tmp/nib-shot-raw.png -gravity center -composite \
    -resize 1600x "$OUT_DOCS"
cp "$OUT_DOCS" "$OUT_SITE"

echo "==> done"
magick identify -format "    %f  %wx%h  %b\n" "$OUT_DOCS"
magick identify -format "    %f  %wx%h  %b\n" "$OUT_SITE"
