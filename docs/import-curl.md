# cURL import and export

Copy as cURL in devtools, `⌥⌘V` into Nib, `⌘↩`. Copy back out with `⇧⌘C`.

## Dialects

Three, and they are mutually incompatible. All three are in the fixture corpus verbatim, because a
fixture that has been tidied up tests the tidying rather than the parser.

| Source | Shape |
|---|---|
| Chrome / Safari (macOS) | POSIX quoting, `\` continuations, `$'…'` when a value contains escapes |
| Firefox | POSIX, single-quotes nearly everything, adds `--compressed` |
| Chrome "Copy as cURL (cmd)" | `curl.exe`, `^` continuations, `"` quoting with `\"`, `^%^` for `%` |

Detection is automatic: `curl.exe`, a `^` at end of line, or `^%^` means cmd; otherwise POSIX.

## Flags

**Supported** — these shape the request:

`-X/--request` · `--url` · `-H/--header` · `-d/--data` · `--data-raw` · `--data-binary`
`--data-ascii` · `--data-urlencode` · `--json` · `-F/--form` · `--form-string` · `-u/--user`
`-A/--user-agent` · `-e/--referer` · `-b/--cookie` · `-G/--get` · `-I/--head` · `-L/--location`
`--max-redirs` · `-k/--insecure` · `-T/--upload-file` · `-m/--max-time`

**Ignored** — about curl's own output, not the request, so silently dropping them is correct:

`-s` · `-S` · `-v` · `-i` · `-o` · `-O` · `-w` · `-#` · `--retry*` · `--compressed` · `-f`

The ones that take a value still consume it, or it would be mistaken for the URL.

**Reported** — recognised, not representable in v1, never silently dropped:

`-x/--proxy` · `-E/--cert` · `--key` · `--cacert` · `--digest` · `--ntlm` · `--negotiate`

## Inference rules

curl's own, and getting them wrong produces a request that looks right and behaves differently:

- `-d` implies `POST` unless `-X` says otherwise.
- `-T` implies `PUT`. This check runs **before** the generic body rule, or every upload would be
  classified as POST.
- `-G` moves `-d` data into the query string and keeps the method `GET`.
- `--json` sets `Content-Type` *and* `Accept` to `application/json`, plus POST.
- `-u user:pass` becomes structured Basic auth, not a raw header, so it round-trips and appears in
  the Auth tab.
- Repeated `-d` flags join with `&`.
- A body on a method that does not normally carry one sets "send body on GET", because curl really
  does send it.

## What we refuse

Anything that would require running a shell: pipes, `&&`, `;`, backticks, `$(…)`. The message names
what it found and suggests pasting just the curl part. Importing half a command and appearing to
succeed is worse than refusing.

Quoting decides whether a character is control syntax, and it cuts both ways:

- **Single quotes are literal.** `-H 'X-Pipe: a|b'` and `-d 'a && b'` are ordinary and import fine.
- **Double quotes are not.** `$(…)` and backticks still execute inside them, so
  `-H "token: $(cat secret)"` is refused.

An early version skipped the control check inside *any* quote, which let the second case through — it
would have imported a header containing a literal `$(cat secret)` and sent it to the server.

## Export

Two variants:

- **`⇧⌘C` Copy as cURL** — everything, ready to run.
- **`⌥⇧⌘C` Copy as cURL (Redacted)** — credential-shaped headers replaced with `$VARIABLE` plus an
  `export` preamble. This is the one to paste into a GitHub issue. The auth *scheme* is kept
  (`Bearer $AUTHORIZATION`) because it is not secret and is often what someone needs to see to help.

Recognised as credentials by name: `authorization`, `proxy-authorization`, `cookie`, `set-cookie`,
`x-api-key`, `x-auth-token`, `api-key`, `apikey`, `x-access-token`, `x-csrf-token`.

Export details worth knowing:

- `--data-raw`, never plain `--data`. `--data` strips newlines and treats a leading `@` as a
  filename, both of which silently corrupt a body.
- `-X` is omitted for GET, since that is curl's default.
- Only settings that differ from curl's defaults are emitted.
- Single quotes inside values use the POSIX `'\''` idiom, so the command stays runnable.
- Exporting resolves `{{variables}}` first — the output is the request as sent.

## Round trip

`CurlExportTests.roundTrip` exports a request, re-imports the result, and compares method, URL,
headers, body and TLS setting. It runs over a table of specs covering GET, POST with JSON, PUT with
text and header values containing commas and equals signs, and DELETE with verification off.

## A Swift note

`"\r\n"` is a **single `Character`** in Swift — one grapheme cluster. Comparing against `"\r"` or
`"\n"` individually misses CRLF entirely, which is exactly what Windows devtools emits. The lexer
uses `Character.isNewline` and `Character.isWhitespace` throughout. This cost a failing test to find
and would otherwise have looked like "Windows import is broken" with no obvious cause.
