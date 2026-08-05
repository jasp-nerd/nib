# HTTP fidelity

Nib sends requests through `URLSession`. That buys HTTP/2, HTTP/3, TLS session reuse and
connection pooling for free, and it costs some control over exactly what goes on the wire.

This page documents every place where what Nib sends differs from what you asked for. Being the
client that writes these down is more useful than being the one that pretends they don't exist.

**Everything here is measured, not read off Apple's documentation.** The numbers and behaviours
come from `HTTPEngineTests`, which runs against a real localhost HTTP server. Where the docs and
the observed behaviour disagreed, the observed behaviour won — see the note on reserved headers.

Measured on **macOS 26.5.2 (25F84)**, Swift 6.3.3.

## Headers Foundation manages

Only two. Everything else you set is delivered verbatim.

| Field | What happens |
|---|---|
| `Content-Length` | Always recomputed from the actual body. Setting it has no effect. |
| `Transfer-Encoding` | Dropped entirely. |

Nib flags both before you send, via `HTTPEngine.reservedHeaders(_:)`.

### A correction worth recording

Apple's documentation describes a much longer reserved list, and early versions of this project
copied it — including `Host`, `Connection`, `Authorization`, `WWW-Authenticate` and
`Proxy-Authorization`. **On macOS 26.5 that list is obsolete.** All of those are sent exactly as
set. Measured:

```
honoured verbatim: Accept-Encoding, Authorization, Connection, Cookie, Host,
                   Proxy-Authorization, Referer, User-Agent, WWW-Authenticate
altered  Content-Length:    sent "5"        (recomputed from the body)
altered  Transfer-Encoding: sent "<absent>" (dropped)
```

This matters in practice: you *can* override `Host` to test virtual hosts, and you *can* force
`Accept-Encoding: identity` to see an uncompressed response. Warning about headers that actually
work would train people to ignore the warnings.

`HTTPEngineTests.reservedHeaderProbe` re-measures this on every run and fails if the set drifts, so
a future macOS change shows up as a failing test rather than a user bug report.

## Headers Foundation adds

Present on every request whether you asked or not:

- `Accept-Encoding: gzip, deflate` — and the response is transparently decompressed. Nib shows you
  the decoded body, which is what you want from an API client, but note a server that varies on
  this header will behave differently than your header list suggests.
- `User-Agent` — a `CFNetwork`/Darwin string. You can override it.
- `Host` — derived from the URL. You can override it.

## Repeated header fields are combined

`URLRequest` cannot emit two lines with the same field name. Setting `X-Trial: one` and
`X-Trial: two` puts a single line on the wire:

```
X-Trial: one,two
```

Semantically equivalent for most headers per RFC 9110, but **not** for `Set-Cookie`-style fields
that forbid list syntax. Nib reports this in the response's fidelity notes when it happens.

### The same thing happens on the way back, and `Set-Cookie` is where it bites

`HTTPURLResponse.allHeaderFields` is a dictionary, so two `Set-Cookie` headers have already been
merged into one value by the time any of our code runs. Measured against a server sending exactly
two:

```
Set-Cookie: session=abc123; Path=/; HttpOnly; Secure; SameSite=Lax
Set-Cookie: tracking=xyz; Path=/api; Expires=Wed, 21 Oct 2026 07:28:00 GMT
```

what arrives is one header, comma-joined:

```
session=abc123; Path=/; HttpOnly; Secure; SameSite=Lax, tracking=xyz; Path=/api; Expires=Wed, 21 Oct 2026 07:28:00 GMT
```

`Expires` contains a comma of its own, so this cannot be split naively — and handing the joined
string to `HTTPCookie.cookies(withResponseHeaderFields:for:)` does not work either. It returned
**one** cookie, and not the first: `session`, the one carrying every security flag, disappeared
silently.

Nib splits the joined value itself, on the only comma that reliably separates cookies — one
followed by something shaped like `name=`, using the RFC 6265 token characters. A date's comma is
followed by ` 21 Oct`, which is not. `ResponsePresentationTests` pins this with the exact string
above.

### `HTTPCookie` also drops `Secure` cookies parsed against an `http://` URL

Measured: the same two cookies parse as two against `https://127.0.0.1` and as **one** against
`http://127.0.0.1`, with no error either way.

That is right for a browser and wrong for this tab. "My server is setting a `Secure` cookie and I
am testing over plain HTTP on localhost" is a real misconfiguration people open the Cookies tab to
find, and answering it with an empty list is the least useful thing we could do. So Nib parses
against an https-normalised copy of the URL — never used to send anything — shows the cookie, and
labels it: *marked Secure but sent over plain HTTP, a browser would discard it.*

## Redirects rewrite the method

On `301`, `302` and `303`, URLSession changes the method to `GET` and drops the body — matching
browsers, and *not* matching `curl --location -X POST`. This is the deviation most likely to
surprise someone migrating from curl.

Nib makes it a per-request choice:

- **Default (off).** URLSession's behaviour. A note explains that the method changed and how to
  keep it.
- **"Preserve method on redirect".** Nib re-applies the original method and body on each hop.

`307` and `308` preserve the method at the protocol level, so neither setting changes anything.

Every hop is reported as a `SendEvent.Hop`, so the redirect chain is visible rather than collapsed
into a final URL.

## Header order and casing

Not under our control. `URLRequest` stores headers in a dictionary, so the order they appear on the
wire is not the order you typed, and field-name casing may be normalised. This is fine for
conforming servers — RFC 9110 makes field names case-insensitive and order-independent, except
among repeated fields of the same name.

If you are debugging a server that depends on header order, Nib is the wrong tool and so is
anything else built on URLSession.

## Timing

Taken from `URLSessionTaskMetrics.transactionMetrics`, in microseconds. `DNS`, `connect` and `TLS`
are legitimately absent for a loopback or reused connection — a reused pooled connection has no
handshake to report, which is information rather than a gap.

Timing is measured in **microseconds**. An earlier version used milliseconds and reported `0` for
every localhost request, which reads as "no data" rather than "very fast".

## Bodies

- Request bodies from a file are streamed via `uploadTask(with:fromFile:)`, so a large upload never
  counts against the app's memory budget.
- Response bodies stay in memory up to **8 MB** and spill to a temp file above that. The switch
  happens mid-stream, because `Content-Length` is often absent or wrong.
- A body on a method that does not conventionally carry one (`GET`, `DELETE`, …) is dropped unless
  **"Send body on GET"** is enabled. This is Postman's `disableBodyPruning`, renamed to say what it
  does. Dropping it silently would be worse than either alternative, so a note always explains it.

## TLS

Certificate failures are surfaced with the real `SecTrust` reason, not a bare `-1202`. Disabling
verification is per-request, never global, never a default, and never applied automatically after a
failure — Nib offers a one-click retry and records a note on the response that it was insecure.

Client certificates are out of scope for v1.

## What we deliberately do not do

Build our own HTTP stack on `Network.framework`. It would give exact control over header order,
repeated fields and reserved names — and cost HTTP/2, HTTP/3, TLS session reuse and connection
pooling, plus a year of bugs. For the 80% of Postman users Nib is aimed at, the deviations above are
acceptable. For the last 20%, the honest answer is this document.
