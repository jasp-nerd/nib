# Contributing

Thanks for wanting to help. Two things to read before you write any code: the not-in-v1 list below,
and the issue-first rule.

## Open an issue first

Nib is deliberately small, and the fastest way to waste an afternoon is to build something that is
on the list below. An issue costs you five minutes and can save you a weekend.

This is not a formality. Pull requests that add a feature nobody agreed to will be closed, however
good the code is.

## Explicitly not in v1

Not "no forever" in every case, but "no now", and a pull request adding one will be closed:

- **Scripts of any kind.** No JavaScriptCore. This is the largest scope and binary-size risk in the
  project by a wide margin. Nib imports scripts, preserves them, round-trips them and reports them —
  it does not run them. See `docs/architecture.md`.
- Test assertions and a collection runner. Both need scripts.
- OAuth 2.0 flows, AWS SigV4, digest, NTLM, hawk.
- gRPC, WebSocket, SSE.
- Mock servers, monitors, sync, accounts, teams.
- Proxy configuration, client certificates.
- Code generation beyond cURL.
- OpenAPI, Insomnia and Bruno import. Planned for later — see the roadmap in the issues.
- jq or JSONPath filtering.
- Multiple windows.
- Auto-update. `brew upgrade` is the mechanism.

Scripts is the omission that generates the most issues, so to say it plainly: **we may add scripts
later. We will never add an account.**

## Never do these

Every one of these is enforced by `Tools/check-boundaries.sh`, which is blocking in CI. They are not
style preferences.

- **No new dependencies.** The size claim in the README depends on staying at zero. Open an issue.
- **No polling timers.** No `Timer.scheduledTimer`, no `Timer.publish`, no
  `DispatchSource.makeTimerSource`. Use FSEvents, vnode sources, or `NSWorkspace` notifications.
  Timers keep the CPU out of idle and are the single most likely way this app stops being able to
  claim 0% idle CPU.
- **No `import AppKit` or `SwiftUI` outside `NibUI`.** The other four packages stay UI-free so they
  test headlessly.
- **No `.library(type: .dynamic)`.** An embedded framework is launch-time tax dyld pays on every
  start, plus bundle size.
- **No `try!` or `as!`** without a trailing `// allow-force: <reason>`.
- **Don't touch signing or optimization settings in `project.yml`.** Each is load-bearing and
  commented where it sits.
- **Don't add a TCC permission.** Nib needs zero — no Accessibility, no Input Monitoring, no Screen
  Recording. That is a feature.

## Before you push

```sh
make check
```

That runs the boundary checks, `swift-format lint --strict`, `swiftlint --strict`, the whole test
suite, and the bundle-size gate. It is exactly what CI runs. It must be green.

`make doctor` tells you what your toolchain can do; a few targets need full Xcode rather than the
Command Line Tools.

## Tests

Swift Testing, not XCTest. Write the test first where you can — the parameterised fixture tables in
`NibInterchange` are the specification for the importers, and they were written before the code.

The rules that matter:

- A test that needs the network talks to `TestHTTPServer` on localhost, not to the internet.
- A test that needs the Keychain uses its own service name and is skipped, not failed, when the
  Keychain is unavailable. Red that means "your machine is configured differently" trains people to
  ignore red.
- Timing assertions belong in release-mode runs only. Debug is several times slower and the budget
  is not meaningful there.

## Performance is a feature, and it has numbers

The README claims a size, a launch time and a memory figure. Those are measured, not estimated, and
they are gated in CI. If your change moves one, say so in the pull request with the before and after.

Memory is measured with `footprint`, never `ps -o rss=`. RSS counts resident pages of shared
framework text and drifts with unrelated system activity — the same binary has measured 36 MB and
106 MB by RSS while its actual footprint moved by 3 MB.

## The pull request template

The last box asks you to explain in one paragraph what the change does and why. That box is the
actual review control. If the paragraph is hard to write, the change is not ready — and that is
true whether a person or a model wrote the code.
