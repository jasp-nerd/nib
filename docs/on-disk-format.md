# On-disk format

A collection is a folder. One file per request, bodies in sibling files, deterministic bytes. The
point is that `git diff` on your requests reads like a diff on source code.

This page is the spec. It is a contract with users' repos, not an implementation detail.

## Layout

```
~/Work/acme-api/                    ← you choose this folder; it is a git repo
├── collection.json                 ← metadata + child order
├── .gitignore                      ← written once, ignores .DS_Store
├── environments/
│   ├── Local.env.json
│   └── Staging.env.json
├── Auth/                           ← a folder in the tree is a directory
│   ├── folder.json
│   ├── Login.req.json
│   └── Login.req.body.json         ← the body, verbatim
└── List users.req.json
```

Nothing else is written here. Response history, cookies and window state live in
`~/Library/Application Support/Nib/`. Putting app state in someone's repo would retire the
git-friendly claim on day one, so `StoreLocations` keeps the two apart and nothing crosses.

## Files

`collection.json`

```json
{
  "auth" : { "token" : "{{token}}", "type" : "bearer" },
  "formatVersion" : 1,
  "id" : "01JQ8Z9K3F7VN2M4CQW8XR6TAB",
  "name" : "Acme API",
  "order" : [ "Auth", "Users" ],
  "variables" : [
    { "enabled" : true, "key" : "baseUrl", "secret" : false, "value" : "https://api.acme.dev" }
  ]
}
```

`Users/Create user.req.json`

```json
{
  "auth" : { "type" : "inherit" },
  "body" : {
    "contentType" : "application/json",
    "file" : "Create user.req.body.json",
    "language" : "json",
    "type" : "raw"
  },
  "formatVersion" : 1,
  "headers" : [
    { "enabled" : true, "name" : "Accept", "value" : "application/json" }
  ],
  "id" : "01JQ8Z9K3F7VN2M4CQW8XR6TAB",
  "method" : "POST",
  "params" : [
    { "enabled" : true, "kind" : "query", "name" : "notify", "value" : "true" }
  ],
  "settings" : {
    "followRedirects" : true,
    "maximumRedirects" : 10,
    "preserveMethodOnRedirect" : false,
    "sendBodyOnGet" : false,
    "timeoutMilliseconds" : 30000,
    "verifyTLS" : true
  },
  "url" : "{{baseUrl}}/orgs/:orgId/users"
}
```

`environments/Staging.env.json`

```json
{
  "formatVersion" : 1,
  "id" : "01JQ8Z9K3F7VN2M4CQW8XR6TAB",
  "name" : "Staging",
  "variables" : [
    { "enabled" : true, "key" : "baseUrl", "secret" : false, "value" : "https://api.staging.acme.dev" },
    { "enabled" : true, "key" : "token", "secret" : true, "value" : null }
  ]
}
```

## The rules that make it work

**Bodies are sibling files, never inlined.** A 40-line JSON body escaped into a single
`"raw": "{\n \"a\"…"` string is an unreadable diff. The sibling file contains the body byte-for-byte
as it goes on the wire, so it diffs line by line like any other source file. Enforced by a test that
asserts the body's content does not appear in the request JSON at all.

**Bytes are deterministic.** `sortedKeys`, `withoutEscapingSlashes`, `prettyPrinted`, trailing
newline. Two tests hold this: saving the same collection twice must produce identical bytes, and a
load-then-save cycle must be a no-op in git. Without them every save churns the diff and `git status`
is never clean.

**Order lives in the parent, not the child.** Reordering three siblings rewrites one file instead of
three. Anything on disk but missing from `order` is appended alphabetically, which is what makes
`cp`-ing a request in from Finder just work.

**The filename is the display name.** Rename in Finder and it renames in Nib. The `id` is a ULID that
survives the rename, so response history and open tabs stay attached. `/` and `:` become `-`, a
leading dot is stripped, and an empty name becomes `Untitled`.

**Secrets are never written.** A secret variable is `"value": null` on disk, always; the value lives
in the Keychain under service `app.nib.secret`, account `<collectionUUID>/<environment>/<key>`. A
clone on another machine keeps the collection id, finds nothing in its own Keychain, and prompts —
which is exactly right. This is the single most important guarantee in the store and it has a test
that greps the written file for the secret.

**Enums carry an explicit `type`.** Swift's synthesized enum encoding produces
`{"bearer":{"token":"x"}}` — legal, but a property of the compiler rather than a format we chose, and
opaque to someone reading a diff. `auth` and multipart parts use a `type` discriminator, and an
unrecognised value degrades (auth to `none`) rather than failing the load.

**`null` is written explicitly.** Swift omits nil optionals by default, which made a secret's key
vanish from the file entirely instead of appearing with a null value — indistinguishable from never
having existed. `EnvironmentVariable` encodes `value` by hand for this reason.

## Reading is tolerant, writing is strict

A folder someone has been editing by hand, or that a colleague pushed to, has to open:

- A malformed request file is **skipped with a diagnostic**, not fatal. One bad file must not stop the
  other two hundred from opening. The diagnostic appears in the sidebar.
- Unknown files and directories are ignored and **never deleted**. A `README.md` or a colleague's
  scratch folder is not ours to touch; stale-file cleanup is scoped to our own naming conventions.
- A directory without `folder.json` is not part of the collection — that is how a `.git` checkout or a
  scratch directory stays out of the tree.
- A `formatVersion` newer than we understand is refused with a clear message, checked *before*
  decoding the rest so the error is "this file is too new" rather than an opaque `DecodingError`
  about whichever field changed shape first.

## Changes made outside the app

`FolderWatcher` uses **FSEvents, not a polling timer** — the boundary check enforces that, because a
repeating timer is the most likely way this app stops being able to claim 0% idle CPU. A 200 ms
coalescing window turns a `git checkout` of hundreds of files into a handful of callbacks.

Our own writes come back through the watcher too, so `CollectionStore` bumps a generation on every
save and the owner compares it before reloading. Without that, saving would reload the tree we just
wrote — and a reload mid-edit would discard whatever was typed next.

FSEvents also fires once when the watch root is established, which callers must tolerate; a reload is
idempotent, so it is harmless.

## Format version

`formatVersion: 1`. Every file carries it. Bump only for a change older builds cannot read, and add a
migration in `DiskFormat` — that mapping layer exists so the file format can stay stable while the
in-memory tree is refactored freely.
