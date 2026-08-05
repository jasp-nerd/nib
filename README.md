# Nib

A tiny, fully native macOS API client — the essentials, without the bloat.

<!--
Three badges, no more. Fill in the two placeholders before publishing:
  - the Discord invite code
  - the contact address on the "Let's talk" badge
Both are deliberately left blank rather than guessed, because a dead invite link and a stranger's
inbox are worse than no badge at all. No CI badge, no star count, no download count.
-->
<p align="center">
  <a href="https://discord.gg/REPLACE-ME"><img alt="Discord" src="https://img.shields.io/badge/Discord-join-5865F2?style=flat"></a>
  <a href="mailto:REPLACE-ME?subject=Nib"><img alt="Let's talk" src="https://img.shields.io/badge/Let's%20talk-111111?style=flat"></a>
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/License-AGPL--3.0-3DA639?style=flat"></a>
</p>

<p align="center">
  <img src="docs/screenshot.png" width="720" alt="Nib showing a request and its JSON response">
</p>

Around **1.6 MB on disk** and **30 MB of memory** at rest — no Electron, no account, no telemetry.
Just AppKit and SwiftUI with zero dependencies. It's fast because there's nothing to it.

## Features

- **Send requests** — every method, query and path parameters, headers, and six kinds of body.
- **Import from Postman** — a collection, an environment, or a whole data-dump zip, dragged in.
- **Requests as files** — one JSON file each, in a folder you choose, diffable in git.
- **Environments** — swap `{{baseUrl}}` between local and staging; secrets stay in the Keychain.
- **cURL both ways** — paste a command from devtools, copy one back out, redacted if you like.
- **Real response detail** — JSON highlighting, headers, cookies, redirect chain, timing waterfall.
- **Keyboard first** — every action has a shortcut, and every shortcut is a menu item.

## Install

```sh
brew install nib-app/tap/nib
```

Nib is **self-signed**, not notarized. The tap's `postflight` clears the quarantine attribute for
you, so this just works. If you download the zip from the releases page instead, macOS will refuse
to open it until you run:

```sh
xattr -dr com.apple.quarantine /Applications/Nib.app
```

That is the honest cost of not paying Apple $99 a year. Nib needs **zero** system permissions — no
Accessibility, no Input Monitoring, no Screen Recording — so there is nothing else to grant.

## Using it

Type a URL, press `⌘↩`. That is the whole thing.

Beyond that: `⌘O` opens a folder as a collection, `⌘K` jumps to any request in it, `⌘E` edits
environments, and `⌘T` opens a tab. The full map is in [docs/keyboard.md](docs/keyboard.md).

Your collection is a folder of plain files:

```
~/Work/acme-api/
├── collection.json
├── environments/Staging.env.json
└── Users/
    ├── folder.json
    ├── Create user.req.json
    └── Create user.req.body.json
```

Rename a file in Finder and it renames in Nib. Edit a body in vim and the app picks it up. Commit
the folder and your team has your requests. Bodies live in sibling files rather than escaped into
JSON strings, because a 40-line body inlined as `"raw": "{\n \"a\"…"` is an unreadable diff.

Response history, cookies and window state go to Application Support instead — putting those in
your repo would poison the whole idea.

## Importing from Postman

Drag a Postman export onto the window. Collections v2.1 and v2.0, environment files, and the
"Export Data" zip all work.

Nib does not run scripts, and it says so instead of pretending. Anything it cannot execute —
pre-request scripts, tests, OAuth 2.0 config, proxy settings — is preserved verbatim in the
request's `preserved` block, round-trips untouched through save and load, and is listed in the
import report by name. An import never silently drops anything.

Scripts may come later. An account never will.

## Building from source

Needs macOS 26 and Xcode 26.

```sh
make doctor    # what your toolchain can and cannot do
make check     # boundaries + format + lint + 318 tests + the size gate
make release   # a signed .app in dist/
```

There is no `.xcodeproj` in the repo — `make gen` writes one from `project.yml` with XcodeGen. A
checked-in project file produces unreviewable merge conflicts and hides build settings from review,
which is exactly where a size or signing regression would slip through.

## Contributing

> [!IMPORTANT]
> Open an issue before opening a pull request. Nib is deliberately small, and the fastest way to
> waste your afternoon is to build something that is on the not-in-v1 list.

That list, and everything else, is in [CONTRIBUTING.md](CONTRIBUTING.md). The short version: no new
dependencies, no polling timers, and the last box on the PR template asks you to explain in one
paragraph what your change does and why. If that paragraph is hard to write, the change is not
ready.

## License

AGPL-3.0. See [LICENSE](LICENSE).

Contributions are accepted under the [CLA](CLA.md), which keeps relicensing possible. The licence is
the point: this cannot be taken private and sold back to you later.
