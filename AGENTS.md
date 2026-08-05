# Working in this repo

The rules that a change has to satisfy, in the form a coding agent can act on. `AGENTS.md` is the
conventional filename for this; Claude Code, Cursor and others read it automatically.

Nothing here is agent-specific advice. Every rule below is a real constraint on the project, most of
them enforced by `Tools/check-boundaries.sh` or by CI, and they apply the same whether a person or a
tool is making the change. `CONTRIBUTING.md` says the same things in prose for humans;
`docs/architecture.md` explains why.

## Commands

```sh
make doctor      # what the local toolchain can and cannot do — run this first
make build       # build all five packages
make test        # run all package tests
make check       # boundaries + format lint + test   (what CI runs)
make format      # rewrite with swift-format
make gen         # regenerate Nib.xcodeproj (needs Xcode + xcodegen)
make budget      # Release bundle size gate (needs Xcode)
```

`make check` must be green before any commit.

## Never do these

- **No polling timers.** No `Timer.scheduledTimer`, no `Timer.publish`, no
  `DispatchSource.makeTimerSource`. Use FSEvents, `DispatchSource` vnode sources, or
  `NSWorkspace` notifications. Timers keep the CPU out of idle and are the single most
  likely way this app stops being able to claim 0% idle CPU. Enforced by
  `Tools/check-boundaries.sh`.
- **No new dependencies.** The bundle-size claim depends on staying at zero. Open an issue
  first. Enforced by the boundary check.
- **No `import AppKit` / `SwiftUI` outside `NibUI`.** `NibCore`, `NibHTTP`, `NibStore` and
  `NibInterchange` stay UI-free so they test headlessly. Enforced.
- **No `.library(type: .dynamic)`.** An embedded framework is launch-time tax dyld pays on
  every start, plus bundle size. Omit `type:` and let SPM link statically. Enforced.
- **No `try!` / `as!`** without a trailing `// allow-force: <reason>`. Enforced.
- **Don't touch signing or optimization settings in `project.yml`.** Specifically
  `ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES`, `DEPLOYMENT_POSTPROCESSING`, `STRIP_*`,
  `CODE_SIGN_*`, `ENABLE_HARDENED_RUNTIME`. Each is load-bearing and commented where it sits.
- **Don't add work to `applicationDidFinishLaunching`.** It does three things: build menu,
  create window, show it. Anything with a cost goes in `deferredStartup()`, after first frame.
- **Don't add a TCC permission.** Nib currently needs zero — no Accessibility, no Input
  Monitoring, no Screen Recording. That is a feature and a marketing point.

## Invariants

These are the load-bearing design facts. Breaking one is a design change, not a refactor.

1. **`NibHTTP` never sees `{{vars}}`.** Interpolation happens in `NibCore`; the engine gets a
   fully-resolved `SendPlan`. This is why the engine is testable without a store or a UI.
2. **Variable precedence is `request > environment > folder > collection`.** Environment
   beats collection deliberately — the collection holds defaults and the active environment
   is the "which target" switch. Inverting this makes selecting Staging silently hit
   production. There is a regression test; do not "simplify" it.
3. **Secret values are never written to disk.** `null` in the file, value in the Keychain.
4. **Two stores, never mixed.** The user's collection folder is git-tracked and clean.
   Response history, cookies and window state go to Application Support. Writing history into
   someone's repo would poison the git-friendly pitch.
5. **On-disk encoding is deterministic.** Same model, same bytes, every time. Tested by
   encoding 1000× and asserting one unique byte sequence.
6. **Request bodies are sibling files**, never inlined into the request JSON. An escaped
   40-line body is an unreadable diff.
7. **An import never silently drops anything.** Whatever we cannot execute goes in the
   request's `preserved` block, round-trips untouched, and is reported as an
   `ImportDiagnostic`.

## Scope

`v1` is deliberately small. Before adding a feature, check the "Explicitly NOT in v1" list in
the plan. The big one: **no scripts, no JavaScriptCore** — largest scope and size risk in the
project. Import them, preserve them, report them, do not run them.

## Swift specifics to watch

macOS-only AppKit is the thin tail of the training data, so:

- Verify AppKit APIs exist before using them. The compiler catches invented ones; *you* have
  to catch the deprecated-but-still-compiling ones (`SMLoginItemSetEnabled`,
  `NSUserNotification`, `NSStatusItem.view`).
- No synchronous file I/O or `Process.waitUntilExit` on the main actor. Default isolation is
  `MainActor` in `NibUI` and the app target, so this is easy to do by accident.
- No unstructured `Task { }` in a view body with no cancellation. Use `.task { }` or store the
  handle.
- Splitting a large view means extracting a new `View` type, **not** a computed property —
  computed properties don't get `@Observable`'s fine-grained invalidation.
- Don't add `Coordinator` / `Router` / `ViewModelFactory` layers, or protocols with one
  conformer. In a 5 MB app that is defensive complexity, not architecture.
- If you find yourself writing a third slightly-different debouncer or LRU cache, stop and
  reuse the first one.

## Pull requests

The last box on the template is "explain in one paragraph what this does and why". If that
paragraph is hard to write, the change is not ready.
