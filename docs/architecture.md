# Architecture

A tiny, fully native macOS API client. Postman alternative. AGPL-3.0.

The shape of the thing: an AppKit window shell hosting SwiftUI content, five local SPM
packages, zero third-party dependencies, requests stored as plain files in a folder the user
owns. Targets macOS 26, Swift 6 with strict concurrency.

## Bird's-eye view

A request travels one way through the system, and each arrow crosses a module boundary that
SPM enforces at compile time:

```
  collection folder on disk
        │  (NibStore: read, watch, atomic write)
        ▼
  CollectionTree ── HTTPRequestSpec        [NibCore: pure value types]
        │
        │  VariableResolver applies {{vars}} from the layered scope
        ▼
  SendPlan  (absolute URL, final headers, body as Data or file)
        │
        │  HTTPEngine  → AsyncStream<SendEvent>
        ▼            [NibHTTP: URLSession, no vars, no UI]
  SendEvent.Result  (payload, timing, hops, fidelity notes)
        │
        ▼
  RequestSession ── SwiftUI + NSTextView   [NibUI: the only UI-aware module]
```

Imports come in from the side: `NibInterchange` turns a Postman export into a
`CollectionTree` + environments + diagnostics, and hands it to `NibStore` to write out.

## Module map

| Module | Isolation | What lives here |
|---|---|---|
| `NibCore` | `nonisolated` | Every model, as `Sendable` structs and enums — no classes. `HTTPRequestSpec`, `SendPlan`, `SendEvent`, `SendPlanBuilder`, `VariableResolver`, `VariableScope`, `HTTPMethod`, `JSONTokenizer`, `FuzzyMatcher`, `ShellLexer`. Foundation only. |
| `NibHTTP` | `nonisolated` | The `HTTPEngine` actor, its `URLSession` delegate, and the response sink. No models. One `URLSession` per collection so the cookie jar is per-collection. |
| `NibStore` | `nonisolated` | `StoreLocations` (the two-store split + canonical encoder), `CollectionStore`, `FolderWatcher`, `SecretStore`, `HistoryStore`. |
| `NibInterchange` | `nonisolated` | `Importer` protocol and its implementations. Pure `Data` → value types. |
| `NibUI` | `MainActor` | SwiftUI views, `@Observable` models, AppKit view controllers. The only module allowed to import AppKit or SwiftUI. |
| `App` | `MainActor` | `main.swift`, `AppDelegate`, `MainMenu`, `MainWindowController`, `LaunchMetrics`. Thin. |

Why five packages rather than one target with folders: **SPM enforces the boundaries at
compile time.** You cannot `import` something you have not declared as a dependency. That is a
stronger guarantee than a convention, and it is the main structural defence against the
importer quietly growing a dependency on AppKit.

`Tools/check-boundaries.sh` covers what the compiler cannot: the no-timer rule, static
linking, force-unwraps, and accidental external dependencies.

## Invariants

Load-bearing. Each is a design decision with a consequence attached, not a preference.

1. **`NibHTTP` never sees `{{vars}}`.** Interpolation happens upstream in `NibCore`. The
   engine receives a fully-resolved `SendPlan`, which means it can be tested by constructing
   one by hand and firing it at a localhost echo server — no store, no UI, no environment.

   This is why `SendPlan` and `SendEvent` live in `NibCore` and not in `NibHTTP`, which is not
   where they started. `SendPlanBuilder` needs both `HTTPRequestSpec` and `SendPlan`, and
   `NibCore` cannot depend on `NibHTTP`; putting the builder in `NibHTTP` instead would have
   meant the engine's own module took `{{vars}}` as input. Moving the models down keeps
   `NibHTTP` as nothing but the actor, its delegate and the response sink.

2. **Variable precedence is `request > environment > folder > collection`.**
   Environment beating collection is the non-obvious part, and it matches Postman. The
   collection holds defaults (`baseUrl` = production); the active environment is the user's
   "which target am I hitting" switch and must override them. Invert this and selecting the
   Staging environment silently fails to redirect — the app appears to work and hits
   production. `VariableResolverTests.environmentBeatsCollection` guards it.

3. **Nothing blocks the main actor.** Networking, parsing and file I/O all live in
   `nonisolated` packages. `NibUI` and `App` default to `MainActor` precisely so that leaving
   it is a visible, deliberate act.

4. **No polling.** FSEvents for the collection folder, `NSWorkspace` notifications for app
   state. Enforced by grep because it is the easiest invariant to break by accident.

5. **`applicationDidFinishLaunching` does three things** — build the menu, create the window,
   show it. Everything with a cost goes in `deferredStartup()` after first frame. The launch
   number is reported on `windowDidExpose`, not at the end of `didFinishLaunching`, which
   returns long before any pixels exist.

6. **Two stores, never mixed.** The collection folder is the user's, git-tracked, and stays
   clean. Response history, cookie jars, window state and bookmarks go to Application Support.

7. **On-disk encoding is deterministic and bodies are sibling files.** Both exist to make
   `git diff` on a collection genuinely useful, which is the product's second pitch. Tested.

8. **Secrets never touch disk.** `null` in the file, value in the Keychain keyed by
   `<collectionUUID>/<envName>/<key>`. A repo cloned onto another machine finds nothing and
   prompts, which is the correct behaviour. The stripping happens in exactly one place —
   `CollectionStore.writeEnvironments` — and the Keychain side is `docs/environments.md`.

9. **An import never silently drops anything.** Scripts, OAuth config, proxy settings — we
   preserve them verbatim in the request's `preserved` block, round-trip them untouched, and
   name every affected request in the import report.

10. **Zero TCC permissions.** No Accessibility, no Input Monitoring, no Screen Recording. This
    is a feature, and it also means the self-signed distribution path has no permission
    problem to work around.

## Deliberate choices worth not re-litigating

**AppKit shell, SwiftUI content.** Not `@main struct App: SwiftUI.App`. The scene graph costs
launch time we do not need to spend, and the response body has to be a real `NSTextView` in a
real `NSViewController` — TextKit 2 rendering attributes are unreliable inside
`NSViewRepresentable`. Owning the window with `NSSplitViewController` keeps that path clean.

**Folder of JSON, not SQLite.** At our scale (a few thousand requests) the performance argument
for a database does not apply, and a folder buys reviewable diffs, per-request merge conflicts,
zero dependencies, and editability from vim. The two rules that make JSON work as a git format
— deterministic output and bodies in sibling files — are both cheap and both tested.

**URLSession, not a hand-rolled stack on Network.framework.** URLSession has real fidelity
gaps: reserved headers, comma-joined duplicates, injected `Accept-Encoding` and `User-Agent`,
no header-order control, method rewriting on 30x. We document them in `docs/http-fidelity.md`
and surface them in the UI as `fidelityNotes`. Building our own would cost HTTP/2, HTTP/3 and
TLS session reuse and buy a year of bugs. Being the client that documents its deviations is
more useful than being the one that pretends it has none.

**Syntax highlighting with no dependency.** A JSON token can never span a line — string
literals forbid raw newlines, there are no block comments. So tokenization is stateless at
line granularity and line 40,000 can be highlighted without reading the previous 39,999. That
removes the whole reason people reach for Highlightr, which would embed highlight.js and a JS
runtime and roughly double the app.

## Where the rest of the documentation is

| | |
|---|---|
| [`on-disk-format.md`](on-disk-format.md) | What a collection folder looks like, and why |
| [`environments.md`](environments.md) | The variable chain, and the Keychain |
| [`http-fidelity.md`](http-fidelity.md) | Every place URLSession does not send what we asked |
| [`import-curl.md`](import-curl.md) | The three cURL dialects, and what we refuse to interpret |
| [`keyboard.md`](keyboard.md) | The full shortcut map |
| [`performance-budget.md`](performance-budget.md) | The measured numbers and the gates on them |
| [`signing.md`](signing.md) | Self-signing, Gatekeeper, and the notarization exit |

## Toolchain note

Full Xcode is required for the `.app` target, `xcodebuild`, asset compilation, code signing,
and `make budget`. With Command Line Tools only, all five packages still build and test —
`make doctor` reports which mode you are in, and the `Makefile` supplies the framework search
paths that SwiftPM omits for `Testing.framework` under CLT.
