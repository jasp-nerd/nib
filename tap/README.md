# The Nib tap

These two files belong in a separate repository, `jasp-nerd/homebrew-nib`, not in this one. They live
here so they are reviewed alongside the code that produces the artefacts they point at, and so the
release workflow has something to `sed`.

> [!NOTE]
> The `version`, `url` and `sha256` lines in these copies are stale on purpose. `jasp-nerd/homebrew-nib`
> is what Homebrew reads, and the release workflow rewrites all of them there after it has built and
> uploaded the artefacts. Do not fix the placeholder checksums here expecting it to change an install;
> check the live tap instead.

```sh
brew trust --tap jasp-nerd/nib             # Homebrew 6 requires this for any third-party tap
brew install --cask jasp-nerd/nib/nib      # the cask. This is the one to tell users about.
brew install --formula jasp-nerd/nib/nib   # builds from source
```

The tap repository must be named **`homebrew-nib`** for `jasp-nerd/nib` to resolve. Homebrew strips
the `homebrew-` prefix, which is why Tinycast's `abue-ammar/homebrew-tinycast` is tapped as
`abue-ammar/tinycast`.

**The formula is not a user-facing install option.** It declares `depends_on xcode: ["26.0", :build]`,
so Homebrew refuses to run it unless full Xcode is already installed, and that is a 15 GB download.
It exists for two narrower reasons: people who compile things on principle, and as an escape hatch
if the unsigned-cask deprecation below ever lands, since a locally compiled binary never acquires a
quarantine attribute in the first place. Keep it out of the README install section.
