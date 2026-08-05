# Security

## Reporting

Report a vulnerability privately through GitHub's ["Report a vulnerability"][advisory] form on this
repository. Please do not open a public issue for anything exploitable.

Expect an acknowledgement within a week. Nib is maintained by volunteers, so there is no paid
bounty and no formal SLA — but a real report will be taken seriously and credited unless you would
rather it were not.

[advisory]: https://github.com/nib-app/nib/security/advisories/new

## What Nib does with your data

Nothing leaves your machine except the HTTP requests you ask it to send.

- **No telemetry, no analytics, no crash reporting, no update check.** There is no network traffic
  that you did not type a URL for.
- **No account.** There is nothing to sign in to.
- **Zero third-party dependencies**, so there is no transitive supply chain to audit.
- **Zero TCC permissions** — no Accessibility, no Input Monitoring, no Screen Recording.

## Where secrets live

Secret environment values go in the **Keychain**, service `app.nib.secret`, account
`<collectionID>/<environmentName>/<key>`. They are never written to your collection folder: the file
records the key with `"value": null`, so a repo you clone on another machine knows a token is
expected and correctly finds nothing.

Everything else in a collection is plain text in a folder you chose. That is the point of the
format, and it means **anything you type into a non-secret field is committable**. Tick "secret" for
things that should not be.

Two limitations, both consequences of shipping self-signed, are written up in
[`docs/environments.md`](docs/environments.md): Nib uses the file-based keychain rather than the
data-protection keychain, and the access control is bound to the code signature, so upgrading can
re-prompt for permission.

## Things Nib deliberately refuses to do

- **It does not run scripts.** Imported pre-request and test scripts are preserved and reported,
  never executed. An imported collection cannot run code on your machine.
- **It does not interpret shell syntax.** Pasting a cURL command containing `$(…)`, backticks, a
  pipe or `&&` is refused with an explanation rather than partially interpreted. An earlier version
  skipped this check inside double quotes, which would have let `-H "token: $(cat secret)"` through
  as a literal header — that is fixed and has a regression test.
- **It does not send a body on GET by default**, does not disable TLS verification globally, and
  warns before putting an API key in a query string.

## Certificate verification

Verification can be turned off **per request**, from the panel shown when a certificate is rejected.
It is stored with that request, so it appears in your diff and cannot be forgotten in a global
setting. There is no application-wide switch, on purpose.
