cask "nib" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/jasp-nerd/nib/releases/download/v#{version}/Nib.zip"
  name "Nib"
  desc "Tiny, fully native macOS API client"
  homepage "https://github.com/jasp-nerd/nib"

  depends_on macos: ">= :tahoe"

  app "Nib.app"

  # Nib is ad-hoc signed rather than notarized, so Gatekeeper quarantines the download and macOS
  # refuses to open it with a message that reads like the app is damaged. Clearing the attribute is
  # what makes `brew install --cask nib` just work.
  #
  # This depends on behaviour Homebrew is actively deprecating: 5.x removed --no-quarantine, and
  # casks failing the codesign audit are being removed from the *official* tap. This is our own tap,
  # so it still works — but see docs/signing.md for the two exits, both of which are small: notarize
  # with a Developer ID, or install the formula below, which builds from source and never acquires a
  # quarantine attribute in the first place.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Nib.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Application Support/Nib",
    "~/Library/Preferences/app.nib.Nib.plist",
    "~/Library/Saved Application State/app.nib.Nib.savedState",
  ]
end
