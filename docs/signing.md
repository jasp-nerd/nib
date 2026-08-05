# Signing and distribution

Nib is **self-signed**, not notarized. This page says plainly what that means, why, and what would
change if we bought a Developer ID.

## Three signing modes

| Mode | Used for | Identity |
|---|---|---|
| Ad-hoc (`codesign -s -`) | Local development, CI test builds | None; changes every build |
| Persistent self-signed | Releases | `Nib Self-Signed`, stable across builds |
| Developer ID + notarization | Not currently used | Apple-issued, $99/yr |

A fresh clone builds and runs with **no certificate in the keychain at all** — both `project.yml`
and `Tools/build-app.sh` default to ad-hoc. Nothing about getting started requires this document.

## Why a persistent identity for releases

Ad-hoc signatures change on every build, which makes macOS treat each release as a different
program. That breaks update-in-place behaviour and resets any per-app state keyed to code identity.
A stable self-signed certificate fixes that at no cost.

Worth noting what we *don't* need it for: Nib requests **zero TCC permissions** — no Accessibility,
no Input Monitoring, no Screen Recording. A launcher or hotkey app cannot get an Accessibility grant
with an ad-hoc signature, and would be forced into this. We are not, which is a side benefit of the
app not needing to touch other applications.

## Creating the release identity

Run once, on the release machine:

```sh
./Tools/selfsign.sh
```

It creates a 10-year self-signed code-signing certificate named `Nib Self-Signed` and prints the
base64 `.p12` to store as the `SIGNING_P12_BASE64` GitHub secret (with `SIGNING_P12_PASSWORD`).

CI imports it into an **ephemeral keychain** that is deleted when the job ends, so the key never
persists on a shared runner.

## What the user sees

Because the app is not notarized, macOS quarantines it on first download.

- **Via Homebrew** — nothing to do. The cask's `postflight` clears the quarantine attribute on every
  install and upgrade.
- **Via the DMG directly** — once:

  ```sh
  xattr -dr com.apple.quarantine "/Applications/Nib.app"
  ```

The README states this plainly rather than burying it. We are asking people to run a command that
disables a security check, and that deserves a sentence explaining why, not a footnote.

## The risk we are carrying

Homebrew 5.x removed `--no-quarantine`, and casks failing the codesign + notarization audit are
being removed from the **official** `homebrew-cask` tap. Our own tap still works — a third-party tap
may run a `postflight` — but we are relying on behaviour Homebrew is actively deprecating.

Mitigations, in the order we would reach for them:

1. **Buy a Developer ID and notarize.** ~15 lines in `release.yml`:
   `ENABLE_HARDENED_RUNTIME: YES`, then `xcrun notarytool submit --wait` and
   `xcrun stapler staple` on both the `.app` and the `.dmg`. Notarization does not require the App
   Store and is fully compatible with AGPL-3.0. Nothing else in the project changes — this is
   deliberately isolated to one workflow file and two build settings.
2. **Also ship a Homebrew formula that builds from source.** A locally compiled binary never gets a
   quarantine attribute at all, so Gatekeeper is bypassed entirely. Our audience can compile.
3. **Document the manual `xattr` line**, which is where we are today.

## Not sandboxed

Nib is not sandboxed, and the README says so. Two concrete reasons:

- It reads and writes a user-chosen folder tree of request files.
- It shells out to `/usr/bin/ditto` to expand Postman data-dump zips.

`NibStore` is nevertheless written as though sandboxing were coming — security-scoped bookmarks for
the collection folder — so this can be revisited without restructuring anything.

Hardened runtime is currently **off**, since it is only required for notarization. Turning it on is
step one of mitigation 1 above.
