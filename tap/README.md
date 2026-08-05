# The Nib tap

These two files belong in a separate repository, `nib-app/homebrew-tap`, not in this one. They live
here so they are reviewed alongside the code that produces the artefacts they point at, and so the
release workflow has something to `sed`.

```sh
brew install nib-app/tap/nib          # the cask: a signed .app, no compiling
brew install nib-app/tap/nib --formula # builds from source, no Gatekeeper involved at all
```

Publishing:

1. Create `nib-app/homebrew-tap` on GitHub.
2. Copy `Casks/` and `Formula/` into it.
3. Add a `TAP_TOKEN` secret to this repository — a fine-grained PAT with contents:write on the tap.

From then on the release workflow bumps the version and the SHA on every tag. The placeholder
`sha256` values below are meant to be replaced by that workflow, not by hand.
