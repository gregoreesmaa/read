# Homebrew formula for Read (MRI: update per release, see docs/release.md).
#
# Until this repo owns a tap, install from a clean machine with:
#   brew install --build-from-source ./homebrew/read.rb
# or, once tapped (see docs/release.md):
#   brew tap gregoreesmaa/read && brew install read
class Read < Formula
  desc "Ultra-minimalist zero-dependency Markdown reader in Zig"
  homepage "https://github.com/gregoreesmaa/read"
  version "0.1.0"
  url "https://github.com/gregoreesmaa/read/releases/download/v0.1.0/read-v0.1.0-macos-arm64.tar.gz"
  sha256 "REPLACE_WITH_RELEASE_SHA256"

  def install
    bin.install "read"
  end

  test do
    assert_predicate bin/"read", :exist?
  end
end
