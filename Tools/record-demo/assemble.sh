#!/bin/bash
#
# Cut the clips together into the demo.
#
# Each source clip carries dead air at the head (the recorder starts before the first keystroke) and
# the three tab clips repeat the same setup before their one click, so only their tails are used.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
IN="$HERE/clips"
WORK="$HERE/cut"
OUT="$HERE/nib-demo.mp4"

rm -rf "$WORK"; mkdir -p "$WORK"

# Common output geometry. The source is 3024x1964 (a 1512x982 display at 2x), so this is a clean
# downscale rather than a resample onto some unrelated grid.
SCALE="scale=1920:1248:flags=lanczos"
ENC=(-c:v libx264 -preset slow -crf 20 -pix_fmt yuv420p -an)

# Every segment is padded by cloning its final frame and then cut to an exact length.
#
# `setpts` first, because `-sseof` leaves the frame timestamps offset from zero and `-t` then cuts
# against the original timeline: asking for three seconds returned half a second.
#
# Necessary because the recordings are variable-rate: ScreenCaptureKit emits a frame when something
# changes and nothing at all while the screen is still. A clip that ends on four seconds of held
# state therefore contains no frames for those four seconds, and a straight trim collapses the hold
# to nothing -- the first attempt turned a 3.5s tail into 1.5s. Cloning restores the pause, which is
# the part of a demo that lets the viewer actually read the screen.
seg() { # seg <name> <seconds> <ffmpeg-seek-args...>
    local name=$1 length=$2; shift 2
    ffmpeg -v error -y "$@" \
        -vf "setpts=PTS-STARTPTS,$SCALE,fps=30,tpad=stop_mode=clone:stop_duration=8" \
        -t "$length" "${ENC[@]}" "$WORK/$name.mp4"
    printf "    %-9s %ss\n" "$name" \
        "$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$WORK/$name.mp4")"
}

echo "==> cutting"
# The whole import, less the pause before the first keystroke.
seg 1-import  11.5 -ss 1.3 -i "$IN/import.mov"
# The whole send.
seg 2-send    11.0 -ss 1.0 -i "$IN/send.mov"
# Tails only: everything before the click is setup already shown in the previous clip.
seg 3-headers  3.0 -sseof -4.0 -i "$IN/headers.mov"
seg 4-cookies  3.2 -sseof -4.0 -i "$IN/cookies.mov"
seg 5-timing   3.5 -sseof -4.5 -i "$IN/timing.mov"
seg 6-env      8.5 -ss 1.0 -i "$IN/env.mov"

echo "==> joining"
: > "$WORK/list.txt"
for f in "$WORK"/[1-6]-*.mp4; do echo "file '$f'" >> "$WORK/list.txt"; done
ffmpeg -v error -y -f concat -safe 0 -i "$WORK/list.txt" -c copy "$OUT"

echo "==> done"
ffprobe -v error -show_entries format=duration,size -show_entries stream=width,height \
    -of default=nw=1 "$OUT"
