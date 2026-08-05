# Performance budget

The README's numbers are the pitch, so they get build-time guards rather than periodic manual
checks. Nothing goes in the README until it is measured here.

## Where it stands

The shipping app. Release build, `-Osize`, dead-stripped, `strip -x`. macOS 26.5, Apple silicon,
Swift 6.3.3.

| Metric | Measured | Budget | Verdict |
|---|---|---|---|
| Bundle on disk | **3272 KB** | 5.0 MB | 63% of budget |
| ├ binary | 1736 KB | | |
| └ app icon (`AppIcon.icns` + `Assets.car`) | **1524 KB** | | |
| Launch: `main()` → first frame | **~228 ms** (median of five runs) | 400 ms | 57% of budget |
| Idle physical footprint | **30 MB** | 35 MB | 86% of budget |
| Idle CPU | **0.0%** | 0.0% | ok |
| Embedded frameworks | **0** | 0 | ok |
| Third-party dependencies | **0** | 0 | ok |

Reproduce with `make size`, `make measure` and `make memory`. Launch timing is noisy enough that a
single run is not worth quoting — see the note on cold starts below.

### The app icon is 47% of the bundle, and that is not a mistake

Worth stating because it is the first thing that looks wrong: the icon weighs nearly as much as the
program. It is `App/AppIcon.icon`, an Icon Composer package, compiled by `actool` into two files.

`AppIcon.icns` is 44 KB and tops out at 256 px — that is all `actool` puts in it. Everything above
256 px, and the layered structure macOS re-composes from for the Dark, Tinted and Clear icon
styles, is in `Assets.car`. Measured with `assetutil`, that file is 24 assets: the *recipe* (the
nib vector, the colours, the gradients, three appearance-keyed `IconImageStack`s) is about **5 KB**,
and the other **98% is seven pre-rendered RGBA composites** — 1024², twice, once per scale factor,
plus 512² and 256².

It does not shrink, and the levers you would reach for do not work:

| Attempt | Result |
|---|---|
| Solid background instead of the gradient | 1668 → 1648 KB |
| `specular` and `translucency` off | no change |
| `supported-platforms` narrowed to macOS squares | byte-identical |
| `--compress-pngs` | no change |
| `--standalone-icon-behavior none` | no change |
| **`--optimization space`** | **1668 → 1480 KB, all sizes and all three appearance stacks kept** |

Only the last one helps, and it is applied in both build paths. This is a known Xcode 26 regression
— the catalogue used to hold two icon sizes and now holds seven — with no Apple response and no
workaround. It is also not peculiar to us: **Calculator.app on this machine ships a 1756 KB
`Assets.car` in a 3532 KB bundle**, which is Nib's shape almost exactly.

The alternative is dropping `Assets.car` and shipping the `.icns` alone for 1792 KB total. Verified
to work — `NSWorkspace.icon(forFile:)` still returns the full icon, because the glass is baked into
the raster. It costs two things: nothing sharper than 256 px, and an icon that ignores the Dark and
Tinted icon styles while every other icon in the Dock follows them. Not worth 1.5 MB of savings on a
5 MB budget.

### Measure memory with `footprint`, never `ps -o rss=`

This distinction produced a false alarm in both directions and is worth stating plainly.

An earlier revision of this document reported "idle RSS 36.0 MB, 1 MB over budget" and planned
remediation work for it. That figure came from `ps -o rss=`, which is the wrong metric. **RSS on
macOS counts resident pages of shared framework text** — AppKit, SwiftUI, CoreFoundation — which are
shared across every process on the machine and are not attributable to us. It therefore drifts with
unrelated system activity: the same binary measured **36 MB, then 106 MB** by RSS across a single
session, while its actual footprint went from 36 MB to 39 MB.

`footprint`'s "physical footprint" is the number Apple uses for memory limits and jetsam accounting,
and it is the one to hold a budget against. By that metric the app is **28 MB idle**, comfortably
inside 35 MB, and was never over.

Two lessons, both cheap to state and expensive to rediscover:

1. `make memory` exists so nobody reaches for `ps` again. It prints both numbers and labels the RSS
   one as not-a-budget-metric.
2. A budget is only as good as its metric. "1 MB over" prompted real remediation planning for a
   problem that did not exist, which is worse than having no number at all.

`MALLOC_SMALL` (17 MB of the 28) is the app's own heap and is the line to watch — a jump there is
ours to explain, unlike a jump in resident framework pages.

The next tier — ≤60 MB with 2000 requests and a 5 MB response loaded — has plenty of room.

### Cost of the UI

An empty AppKit shell with three placeholder panes measured 134 ms and 448 KB. Everything the app
actually does therefore costs about **1.2 MB and 65 ms** on top of a window that does nothing.
Knowing which change spends it is the whole reason for measuring from the first commit.

## An empty window, for comparison

The AppKit shell with three placeholder SwiftUI panes.

| Metric | Measured | Budget | Headroom |
|---|---|---|---|
| Bundle on disk (SPM) | **448 KB** | 5.0 MB | 91% |
| Bundle on disk (xcodebuild) | **428 KB** | 5.0 MB | 92% |
| Launch: `main()` → first frame | **134 ms** (median, n=7) | 400 ms | ~66% |
| Embedded frameworks | **0** | 0 | |
| Non-system linked dylibs | **0** | 0 | |

Both build paths agree, which is the useful part — `Tools/build-app.sh` is not a shortcut that
flatters the numbers:

| Build path | Median (n=7) | Samples |
|---|---|---|
| xcodebuild Release | 138.0 ms | 140.3 / 668.4 / 125.4 / 169.7 / 138.0 / 133.1 / 134.0 |
| SPM Release | 133.6 ms | 115.5 / 121.6 / 133.6 / 130.4 / 137.5 / 136.1 / 141.1 |

Reproduce:

```sh
make release     # assemble dist/Nib.app
make size        # size gate + segment breakdown + dylib list
make measure     # launch samples + median
```

### Cold start is much slower, and that is the number users feel first

The **first** launch of a freshly built binary measured **309 ms**, and one sample in the run above
hit **668 ms**. Nothing is wrong: the pages are not resident, and dyld has no warm cache for a
binary it has never seen. Every subsequent launch settles at ~134 ms.

Both numbers are real and they answer different questions. ~134 ms is the steady state, which is what
someone using Nib all day experiences. ~300 ms is what they get the very first time after install,
and it is the one that decides whether the app *feels* fast on first impression. Quoting only the
median would be the flattering choice and the less honest one.

Take medians. A single sample of a GUI launch is noise — the 668 ms above is proof.

## What the launch number does and does not include

123 ms is **`main()` entry to `viewDidAppear` on the root split view controller**. That is the
honest first-frame moment: the window hierarchy is on screen.

It excludes pre-`main()` dyld work. On current macOS, `DYLD_PRINT_STATISTICS` is suppressed for
most binaries, so the reliable route to that split is Instruments' App Launch template, which
needs Xcode. Until then the useful proxy is the dylib list: every entry is a system dylib
resolved from the dyld shared cache with precomputed loader info, and there are zero embedded
frameworks — which is the thing that would actually cost pre-main time, since dyld has to parse
and relocate those on every single launch.

So ~123 ms is a floor for our own code, and the real user-perceived number is somewhat higher.
Both are far inside budget, and the point of measuring now is to know which future commit
moves it.

## Two ways to measure this wrongly

Both of these produced a plausible-looking wrong answer, which is the dangerous kind.

**Lazy static initialization.** `static let processStart = ContinuousClock.now` records the
moment something first *reads* it, not program start — Swift initializes static lets lazily.
Nothing touched it until `endLaunch()`, so every launch measured as `-0.0 ms`. It is now a
stored `var` assigned explicitly in `beginLaunch()`.

**Choosing a signal that never fires.** The first attempt reported on `windowDidExpose` and
`windowDidBecomeKey`. `windowDidExpose` is only sent for non-retained backing stores, so it is
effectively never called for a buffered window; `windowDidBecomeKey` never fires if the app was
launched without being activated, which is exactly how a measurement script launches it. Result:
zero samples. `viewDidAppear` on the root view controller is the reliable signal.

There was also an ordering bug: `onFirstFrame` was assigned *after* `showWindow(nil)`, but the
notification can fire synchronously inside `showWindow`, so the callback was nil when it fired
and the latch then suppressed every later attempt.

## Memory while holding a large response

Measured with `NIB_SELFTEST_HOLD`, which keeps the app alive after a self-test so it can be weighed
while it is actually holding something rather than while it is empty.

Fetching an **8.2 MB** JSON response, three consecutive runs:

| | `phys_footprint` |
|---|---|
| Empty, idle | 29 MB |
| Holding an 8.2 MB response | 57 MB, 57 MB, 64 MB |

Against a budget of 60 MB written for a *5 MB* response, so this is a payload 64% larger than the
budgeted scenario sitting roughly on the line — comfortable, but not a lot of headroom, and worth
re-measuring rather than assuming when a later release adds response history.

Where it goes: the display copy is capped at 1 MB (`ResponseViewModel.displayLimit`), and above
8 MB the payload spills to a file and is memory-mapped rather than held. What remains is the
displayed megabyte, its hard-wrapped copy, and TextKit's UTF-16 storage for the same text.

Highlighting contributes nothing to the resting figure by design: colour is applied with
`setRenderingAttributes`, which is not stored per character, and only over the viewport.

## Budgets not yet enforced

Each becomes a gate once there is something to measure it against.

| Metric | Budget | Lands in |
|---|---|---|
| Idle RSS, empty | ≤ 35 MB | |
| Idle CPU over 60 s | 0.0% | the store (structurally backed by the CI timer ban) |
| Load 2000 requests from disk | ≤ 150 ms | |
| Postman import, 5 MB collection | ≤ 1.5 s | |
| Send → first byte, our overhead only | ≤ 5 ms | |
| 5 MB JSON response → painted | ≤ 250 ms | |
| Scrolling a 20 MB body | 60 fps | |
| Keystroke → paint in URL field | ≤ 8 ms | |

## Gates

`make check` runs boundaries, lint, tests, and the size gate. In CI the size gate runs on every
PR, so a dependency added in an unrelated change turns the build red the same day rather than
being discovered by a stranger with `du` after launch.

The size script also prints a segment breakdown and the full dylib list on every run, so a
regression is attributable rather than merely detected.
