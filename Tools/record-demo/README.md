# Recording the demo

Two scripts. `shoot.sh` films the app; `assemble.sh` cuts the clips together.

```sh
./Tools/build-app.sh --release
./Tools/record-demo/shoot.sh
./Tools/record-demo/assemble.sh      # writes nib-demo.mp4
```

Needs ImageMagick and ffmpeg, and the terminal running it needs Screen Recording and Accessibility
permission. **Don't touch the keyboard or mouse while it runs** — the scripts drive the app the way
a person would, and anything you do goes into the take.

The result is about forty seconds: import a Postman export, send a request, look at the response
headers, cookies and timings, then open the environment editor to show the token living in the
Keychain rather than in the file.

## What the pieces do

`record-window.swift` records with ScreenCaptureKit, filtered to Nib's own windows. That filter is
the point: the compositor draws only this application, so whatever else is on the machine cannot
reach a frame — including the window in front of it. A screen-region capture cannot promise that,
and an early attempt at this recorded an editor full of somebody's files instead of the app.

`click.swift` posts mouse events, because the response tabs have no keyboard shortcut and the app
exposes nothing useful through the accessibility API. System Events' own `click at` returns -25208
here and aborts the rest of the script when it does.

## Things that were not obvious

Every one of these produced a take that looked fine until you watched it.

- **Focus.** Anything that steals focus mid-clip takes the keystrokes and clicks with it, while the
  recording — scoped to Nib — shows an app calmly ignoring its input. `shoot.sh` re-asserts the
  front application before every step and fails loudly if it cannot.
- **Frames only arrive on change.** ScreenCaptureKit sends nothing while the screen is still, so a
  dropped frame can be the only record of a state the app then holds for seconds, and a clip ends
  showing the moment before the click. The recorder keeps a copy of the last skipped frame and
  appends it at the end; `assemble.sh` clones the final frame to restore the pauses.
- **Never block the capture callback.** Waiting there for the encoder to catch up fixes the dropped
  frames and makes the app miss mouse clicks, which is much worse.
- **Synthetic clicks get dropped anyway**, perhaps one in three. `shoot.sh` checks the tab actually
  changed colour and clicks again if it did not.
- **Window geometry is autosaved**, frame and both split positions. All three are pinned before
  launch, or one clip that resized something silently reframes every clip after it — and the tab
  coordinates, which are measured in screen points, stop being true.
- **`NIB_SELFTEST_COLLECTION` sends the selected request** as part of its diagnostics, so clips
  opened with a response already on screen. The scripts open the folder as a document instead,
  which is also what a real user does.

## Retaking one clip

```sh
./Tools/record-demo/shoot.sh timing
```

Clip names: `import`, `send`, `headers`, `cookies`, `timing`, `env`. Re-run `assemble.sh` after.
