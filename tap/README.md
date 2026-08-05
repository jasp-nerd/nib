# The Nib tap

These two files belong in a separate repository, `nib-app/homebrew-tap`, not in this one. They live
here so they are reviewed alongside the code that produces the artefacts they point at, and so the
release workflow has something to `sed`.

```sh
brew install nib-app/tap/nib           # the cask. This is the one to tell users about.
brew install nib-app/tap/nib --formula # builds from source
```

**The formula is not a user-facing install option.** It declares `depends_on xcode: ["26.0", :build]`,
so Homebrew refuses to run it unless full Xcode is already installed, and that is a 15 GB download.
It exists for two narrower reasons: people who compile things on principle, and as an escape hatch
if the unsigned-cask deprecation below ever lands, since a locally compiled binary never acquires a
quarantine attribute in the first place. Keep it out of the README install section.

> **Before launch:** the cask above is a 404 until this tap exists as a real repository. The
> install command in the project README does not work until then, and that is the single thing most
> worth fixing before anyone is pointed at it.

Publishing:

1. Create `nib-app/homebrew-tap` on GitHub.
2. Copy `Casks/` and `Formula/` into it.
3. Add a `TAP_TOKEN` secret to this repository — a fine-grained PAT with contents:write on the tap.

From then on the release workflow bumps the version and the SHA on every tag. The placeholder
`sha256` values below are meant to be replaced by that workflow, not by hand.
