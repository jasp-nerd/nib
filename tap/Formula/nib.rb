class Nib < Formula
  desc "Tiny, fully native macOS API client"
  homepage "https://github.com/nib-app/nib"
  url "https://github.com/nib-app/nib/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "AGPL-3.0-only"
  head "https://github.com/nib-app/nib.git", branch: "main"

  depends_on xcode: ["26.0", :build]
  depends_on macos: :tahoe

  # The source-built alternative to the cask, and the reason it exists is not preference: a binary
  # you compiled locally never acquires a quarantine attribute, so Gatekeeper is not involved at
  # all. That sidesteps the entire deprecation described in the cask, at the cost of a few minutes
  # of compiling — which this audience can afford.
  def install
    system "./Tools/build-app.sh", "--release"
    prefix.install "dist/Nib.app"
    bin.write_exec_script "#{prefix}/Nib.app/Contents/MacOS/Nib"
  end

  test do
    assert_predicate prefix/"Nib.app/Contents/MacOS/Nib", :executable?
  end
end
