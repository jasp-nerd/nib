#!/bin/bash
#
# Set the stage for recording the demo, then get out of the way.
#
# Starts a local API on 127.0.0.1:8795, creates an empty collection at /tmp/acme-api with a Local
# environment already pointing at it, and opens Nib on that folder. You record; this script does
# not touch the screen.
#
# It runs until you press Ctrl-C, and cleans up after itself.
#
#   ./Tools/demo-setup.sh

set -uo pipefail
cd "$(dirname "$0")/.."

APP="dist/Nib.app"
COLLECTION="/tmp/acme-api"
EXPORT="$(pwd)/Tools/DemoPostmanExport/Acme API.postman_collection.json"

[ -d "$APP" ] || { echo "no build — run: ./Tools/build-app.sh --release"; exit 1; }

cleanup() {
    echo
    echo "==> stopping"
    [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null
    pkill -f "$APP" 2>/dev/null
    rm -f /tmp/nib-demo-server.py
}
trap cleanup EXIT INT TERM

# A local API, so responses are instant and the demo works with the wifi off.
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
        self.end_headers()
        self.wfile.write(body)
    do_POST = do_GET
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
socketserver.TCPServer(("127.0.0.1", 8795), H).serve_forever()
PY
python3 /tmp/nib-demo-server.py & SERVER_PID=$!
sleep 1

# An empty collection with the environment already in place. Empty so the import visibly fills the
# sidebar; the environment pre-set so the first send after the import resolves and succeeds, rather
# than needing a detour to create one on camera.
rm -rf "$COLLECTION"
mkdir -p "$COLLECTION/environments"
cat > "$COLLECTION/collection.json" <<'JSON'
{
  "formatVersion" : 1,
  "id" : "01DEMOCOLLECTION0000000000",
  "name" : "acme-api",
  "order" : [],
  "auth" : { "type" : "none" },
  "variables" : []
}
JSON
cat > "$COLLECTION/environments/Local.env.json" <<'JSON'
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

pkill -f "$APP" 2>/dev/null
sleep 1
open -a "$(pwd)/$APP" --args 2>/dev/null
sleep 3

cat <<INSTRUCTIONS

  Ready. Nib is open; if it did not open the collection, press Cmd-O and choose:

      $COLLECTION

  Record with Cmd-Shift-5 -> "Record Selected Portion" -> drag a box around the Nib
  window only. Nothing behind it is captured, so the desktop does not matter.

  The Postman export to drag in is at:

      $EXPORT

  Shot list, about 45 seconds:

    1. Drag that .json file onto the Nib window.
       The sidebar fills. Let the import report sit for two seconds, then close it.

    2. Cmd-K, type "ping", Enter.  Then Cmd-Return.
       A response with highlighted JSON.

    3. Cmd-K, type "list users", Enter.  Then Cmd-Return.
       Click through Headers, Cookies and Timing in the response pane.

    4. Cmd-E to show environments. The API_TOKEN row has no value: that is the
       Keychain point. Escape.

    5. Optional, and the strongest ending if you have ten more seconds:
       reveal /tmp/acme-api in Finder, run 'git init && git add . && git commit -m x',
       change a header in Nib, then 'git diff'. One clean line.

  No voiceover, no music, no intro card. Let each shot sit still for a beat.

  Ctrl-C here when you are done.

INSTRUCTIONS

while true; do sleep 3600; done
