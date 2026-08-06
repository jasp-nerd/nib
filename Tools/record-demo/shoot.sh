#!/bin/bash
#
# Record the demo, one clip at a time.
#
# Separate clips rather than one continuous take: a take is only as good as its worst second, and
# four short clips can each be retaken without redoing the other three.
#
#   ./Tools/record-demo/shoot.sh            # every clip
#   ./Tools/record-demo/shoot.sh send env   # just those
#
# Then ./Tools/record-demo/assemble.sh cuts them together.
#
# Needs a release build (./Tools/build-app.sh --release) and ImageMagick. The terminal running it
# needs Screen Recording and Accessibility permission, because the whole thing works by driving the
# app the way a person would and filming the result.
#
# Do not touch the keyboard or mouse while it runs.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUT="$HERE/clips"
EXPORT_DIR="/tmp/Postman Export"
STOP=/tmp/nib-record.stop

mkdir -p "$OUT"

# The two helpers are Swift source rather than checked-in binaries. Compiled once per run into a
# temporary directory, which takes about a second and keeps the repository free of executables.
BIN="$(mktemp -d)"
trap 'rm -rf "$BIN"' EXIT
for helper in record-window click; do
    swiftc -swift-version 5 -O "$HERE/$helper.swift" -o "$BIN/$helper" || {
        echo "could not build $helper.swift"; exit 1; }
done

# Screen coordinates of the response tabs.
#
# Measured from a frame scaled to 1512x982, where one pixel is one screen point. Reproducible only
# because `launch` pins the window frame *and* both split positions -- all three are autosaved, so
# without pinning them the row moves and every click lands on empty pane, which is exactly how an
# earlier take came out with the tabs never changing.
#
# The detail split sits below the toolbar, so the row is at 74 + 55 + 421 + 22, not at
# window-top + split-height. Re-measure rather than re-derive if the layout changes.
HEADERS_X=1065; HEADERS_Y=572
COOKIES_X=1137; COOKIES_Y=572
TIMING_X=1209;  TIMING_Y=572

say() { printf "\n\033[1m==> %s\033[0m\n" "$*"; }

# MARK: - Input
#
# Every one of these reports failure loudly. An earlier version sent osascript's stderr to
# /dev/null, so when `click at` started returning -25208 the script aborted mid-clip and the
# recording just came out short -- with nothing anywhere saying why.

as() {
    if ! osascript -e "tell application \"System Events\" to $1" >/dev/null; then
        echo "    !! failed: $1" >&2
        return 1
    fi
}

type_text() { as "keystroke \"$1\""; }
press()     { as "key code $1"; }
cmd()       { as "keystroke \"$1\" using {command down}"; }
cmd_shift() { as "keystroke \"$1\" using {command down, shift down}"; }
cmd_return(){ as "key code 36 using {command down}"; }
# System Events' own `click at` is not permitted here, so post the event directly.
click()     { "$BIN/click" "$1" "$2"; }
pause()     { sleep "$1"; }

# Bring Nib to the front, and confirm it got there.
#
# This is the single biggest cause of a ruined take. Anything else on the machine can steal focus
# between steps -- and when it does, the synthetic clicks and keystrokes go to *that* window while
# the recording, which is scoped to Nib's own windows, carries on showing a perfectly still app
# that mysteriously ignores its input. Re-assert before every step rather than once per clip.
focus() {
    osascript -e 'tell application "System Events" to set frontmost of process "Nib" to true' \
        >/dev/null 2>&1
    sleep 0.35
    local front
    front=$(osascript -e 'tell application "System Events" to return name of first process whose frontmost is true' 2>/dev/null)
    [ "$front" = "Nib" ] || { echo "    !! front app is \"$front\", not Nib" >&2; return 1; }
}

# Is the response tab centred on x currently selected?
#
# By colour, because the app exposes nothing useful through the accessibility API -- `entire
# contents` of the window comes back with no named elements at all. A selected tab is drawn in the
# accent purple and an unselected one in grey, so the red-minus-green gap separates them cleanly:
# about +43 selected against about -5 unselected. Hover state does not move it.
tab_is_selected() {
    local x=$1 y=$2 shot=/tmp/nib-tabpx.png
    screencapture -x -R "$((x - 10)),$((y - 7)),20,14" "$shot" 2>/dev/null || return 1
    local rgb
    rgb=$(magick "$shot" -resize '1x1!' \
        -format "%[fx:int(255*r)] %[fx:int(255*g)]" info: 2>/dev/null) || return 1
    local r=${rgb% *} g=${rgb#* }
    [ $((r - g)) -gt 25 ]
}

# Click a response tab and confirm it took, retrying if it did not.
#
# Synthetic clicks on this control are dropped now and then -- the pointer arrives, the tab lights
# up on hover, and the selection never changes. It happened on roughly a third of takes and left
# the clip sitting on the previous tab, which is worse than useless because it looks deliberate.
# Rather than keep guessing at the cause, check the result and click again.
click_tab() {
    local x=$1 y=$2
    for attempt in 1 2 3 4; do
        focus || { sleep 0.6; continue; }
        click "$x" "$y"
        sleep 0.8
        tab_is_selected "$x" "$y" && return 0
        echo "    .. tab at x=$x did not take, retrying ($attempt)" >&2
        sleep 0.5
    done
    echo "    !! tab at x=$x never selected" >&2
    return 1
}

# MARK: - Stage

start_server() {
    pkill -f nib-demo-server >/dev/null 2>&1
    sleep 0.3
    cat > /tmp/nib-demo-server.py <<'PY'
import http.server, socketserver, json
users = [{"id": i, "name": n, "email": e, "active": a} for i, n, e, a in [
    (1, "Ada Lovelace", "ada@acme.dev", True),
    (2, "Grace Hopper", "grace@acme.dev", True),
    (3, "Katherine Johnson", "katherine@acme.dev", False)]]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        payload = {"users": users} if "user" in self.path else {
            "status": "ok", "region": "eu-central", "version": "2.4.1", "uptime": 918273}
        body = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Set-Cookie", "session=abc123; Path=/; HttpOnly; Secure; SameSite=Lax")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    do_POST = do_GET
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
socketserver.TCPServer(("127.0.0.1", 8795), H).serve_forever()
PY
    python3 /tmp/nib-demo-server.py >/dev/null 2>&1 &
    sleep 1
}

empty_collection() {
    rm -rf /tmp/acme-api
    mkdir -p /tmp/acme-api/environments
    cat > /tmp/acme-api/collection.json <<'JSON'
{
  "formatVersion" : 1,
  "id" : "01DEMOCOLLECTION0000000000",
  "name" : "acme-api",
  "order" : [],
  "auth" : { "type" : "none" },
  "variables" : []
}
JSON
    cat > /tmp/acme-api/environments/Local.env.json <<'JSON'
{
  "formatVersion" : 1,
  "id" : "01DEMOENVIRONMENT000000000",
  "name" : "Local",
  "variables" : [
    { "enabled" : true, "key" : "baseUrl", "secret" : false, "value" : "http://127.0.0.1:8795" },
    { "enabled" : true, "key" : "API_TOKEN", "secret" : true, "value" : null }
  ]
}
JSON
}

full_collection() {
    rm -rf /tmp/acme-api
    cp -R /tmp/acme-api-full /tmp/acme-api
}

launch() {
    pkill -f "dist/Nib.app" >/dev/null 2>&1
    sleep 1.2
    # Response history is restored into the pane on open, so without this a clip opens showing a
    # response from the previous take -- which is how "send" started with its ending already on
    # screen.
    rm -rf "$HOME/Library/Application Support/Nib/History"
    # A pinned frame, so clips cut against each other without the window moving and the tab
    # coordinates above stay true.
    defaults write app.nib.Nib "NSWindow Frame NibMainWindow" -string "156 74 1200 800 0 0 1512 949"
    defaults write app.nib.Nib RecentCollections -array /tmp/acme-api
    # Which environment the picker starts on, so the first send resolves {{baseUrl}} without a
    # detour on camera. Keyed by collection id; both ids are fixed by the fixtures above.
    defaults write app.nib.Nib ActiveEnvironment -dict \
        01DEMOCOLLECTION0000000000 01DEMOENVIRONMENT000000000
    # Both splits pinned as well. They are autosaved too, so without this the response pane is
    # whatever height the last clip left it -- which is what invalidated the tab coordinates above.
    # A narrower sidebar and a taller response pane also simply film better.
    defaults write app.nib.Nib "NSSplitView Subview Frames NibMainSplit" -array \
        "0.000000, 0.000000, 300.000000, 800.000000, NO, NO" \
        "300.000000, 0.000000, 900.000000, 800.000000, NO, NO"
    defaults write app.nib.Nib "NSSplitView Subview Frames NibDetailSplit" -array \
        "0.000000, 0.000000, 900.000000, 420.000000, NO, NO" \
        "0.000000, 421.000000, 900.000000, 379.000000, NO, NO"

    # Opened as a document rather than through NIB_SELFTEST_COLLECTION: that hook sends the
    # selected request as part of its diagnostics, so every clip began with a response already on
    # screen. This is also the path a real user takes.
    open -a "$REPO/dist/Nib.app" /tmp/acme-api
    sleep 6
    osascript -e 'tell application "System Events" to set frontmost of process "Nib" to true' \
        >/dev/null 2>&1
    sleep 1
    # Set the frame on the live window rather than trusting the autosaved default: the app writes
    # that key back on quit, so one clip that resized the window silently reframed every clip after
    # it. This is authoritative and takes effect immediately.
    osascript <<'AS' >/dev/null 2>&1
tell application "System Events" to tell process "Nib"
  set position of window 1 to {156, 74}
  set size of window 1 to {1200, 800}
end tell
AS
    sleep 1.5
}

# record <name> <maxSeconds> <action-function>
record() {
    local name=$1 limit=$2 action=$3
    rm -f "$STOP"
    "$BIN/record-window" Nib app "$OUT/$name.mov" "$limit" "$STOP" </dev/null >/dev/null 2>&1 &
    local pid=$!
    # Wait for the stream to be up, or the first second of the clip is missing.
    for _ in $(seq 1 60); do [ -f /tmp/nib-record.ready ] && break; sleep 0.1; done
    sleep 0.8

    "$action"
    local status=$?

    sleep 1.2
    touch "$STOP"
    wait $pid
    rm -f "$STOP"
    printf "    %-8s %ss" "$name" \
        "$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT/$name.mov")"
    [ $status -ne 0 ] && printf "   \033[31m(actions failed)\033[0m"
    printf "\n"
}

# The panel remembers where it was last used, so one throwaway import off camera means the real
# take opens straight into the export folder rather than wherever Nib was last pointed.
warmup() {
    say "warm-up (off camera): teaching the open panel where the export lives"
    rm -rf "$EXPORT_DIR"; mkdir -p "$EXPORT_DIR"
    cp "$REPO/Tools/DemoPostmanExport/Acme API.postman_collection.json" "$EXPORT_DIR/"
    empty_collection
    launch
    cmd_shift i; pause 1.8
    cmd_shift g; pause 1.2
    type_text "$EXPORT_DIR"; pause 1.0
    press 36; pause 1.8
    press 125; pause 0.8
    press 36; pause 2.5
    pkill -f "dist/Nib.app" >/dev/null 2>&1
    sleep 1
}

# MARK: - Clips

act_import() {
    focus || return 1
    pause 1.5
    cmd_shift i   || return 1
    pause 2.2
    press 125     || return 1   # into the file list
    pause 1.2
    press 36      || return 1   # Import
    pause 3.5                   # let the report sheet be read
    press 53      || return 1   # dismiss
    pause 1.5
}

act_send() {
    focus || return 1
    pause 1.2
    cmd k         || return 1
    pause 1.4
    type_text ping || return 1
    pause 1.4
    press 36      || return 1
    # Long, because the switcher has to close and the newly selected request has to resolve its
    # scope before the send is worth making. Sending into a half-settled selection is how a take
    # came out ending on "No response yet".
    pause 2.5
    cmd_return    || return 1
    pause 3.5
}

# Select "List users", send, then click exactly one response tab.
#
# One click per clip on purpose. Three in a row worked every time in a bare loop and dropped the
# third one about half the time while recording, always leaving the clip on the previous tab with
# the pointer sitting on the next. One click per launch is slower to shoot and never wrong.
act_one_tab() {
    local x=$1
    focus || return 1
    pause 1.0
    cmd k         || return 1
    pause 1.2
    type_text "list users" || return 1
    pause 1.2
    press 36      || return 1
    pause 2.2
    focus || return 1
    cmd_return    || return 1
    pause 2.8
    click_tab "$x" $HEADERS_Y || return 1
    pause 3.0
}

act_headers() { act_one_tab $HEADERS_X; }
act_cookies() { act_one_tab $COOKIES_X; }
act_timing()  { act_one_tab $TIMING_X; }

act_env() {
    focus || return 1
    pause 1.2
    cmd e         || return 1
    pause 4.5
    press 53      || return 1
    pause 1.2
}

clip_import() { say "clip 1/4  import";              empty_collection; launch; record import 26 act_import; }
clip_send()   { say "clip 2/4  send";                full_collection;  launch; record send   22 act_send; }
clip_headers(){ say "clip 3a  response headers";     full_collection;  launch; record headers 26 act_headers; }
clip_cookies(){ say "clip 3b  response cookies";     full_collection;  launch; record cookies 26 act_cookies; }
clip_timing() { say "clip 3c  response timing";      full_collection;  launch; record timing  26 act_timing; }
clip_env()    { say "clip 4    environments";        full_collection;  launch; record env     20 act_env; }

# MARK: - Run

start_server
[ -d /tmp/acme-api-full ] || { echo "missing /tmp/acme-api-full"; exit 1; }

WANTED=("$@")
[ ${#WANTED[@]} -eq 0 ] && WANTED=(import send headers cookies timing env)

case " ${WANTED[*]} " in *" import "*) warmup ;; esac
for clip in "${WANTED[@]}"; do "clip_$clip"; done

pkill -f "dist/Nib.app" >/dev/null 2>&1
pkill -f nib-demo-server >/dev/null 2>&1
say "clips in $OUT"
