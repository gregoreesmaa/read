#!/bin/sh
# Homebrew formula bump gate (issue #369): the per-release formula edit
# documented in docs/release.md is unavoidable — this check fails the
# release when homebrew/read.rb disagrees with the tag being cut.
#
# Order matters (see docs/release.md): builds are reproducible, so build
# locally first, take the tarball sha256, bump the formula, commit, THEN
# tag. The release workflow runs this after packaging, comparing the
# formula against the just-built tarball; a mismatch fails before publish.
#
# Usage: sh scripts/check_homebrew_formula.sh <tag> <tarball> <tarball.sha256>
# Example: sh scripts/check_homebrew_formula.sh v0.2.0 \
#            dist/read-v0.2.0-macos-arm64.tar.gz dist/read-v0.2.0-macos-arm64.tar.gz.sha256
# Runs anywhere (sh + sed + shasum only).
set -eu

TAG="${1:?usage: check_homebrew_formula.sh <tag> <tarball> <tarball.sha256}"
TARBALL="${2:?usage: check_homebrew_formula.sh <tag> <tarball> <tarball.sha256}"
SHAFILE="${3:?usage: check_homebrew_formula.sh <tag> <tarball> <tarball.sha256}"
RB="homebrew/read.rb"
fail() { echo "FAIL: $1" >&2; exit 1; }

VER="${TAG#v}"
[ "$VER" != "$TAG" ] || fail "tag \"$TAG\" must look like vX.Y.Z"
[ -f "$RB" ] || fail "$RB not found"
[ -f "$TARBALL" ] || fail "tarball not found: $TARBALL"
[ -f "$SHAFILE" ] || fail "sha file not found: $SHAFILE"

version=$(sed -n 's/^[[:space:]]*version "\(.*\)".*/\1/p' "$RB" | head -n 1)
url=$(sed -n 's/^[[:space:]]*url "\(.*\)".*/\1/p' "$RB" | head -n 1)
sha=$(sed -n 's/^[[:space:]]*sha256 "\(.*\)".*/\1/p' "$RB" | head -n 1)

[ -n "$version" ] || fail "no version line in $RB"
[ "$version" = "$VER" ] || fail "formula version \"$version\" != tag \"$VER\" — bump homebrew/read.rb before tagging (see docs/release.md)"
case "$url" in
    *"$TAG"*) ;;
    *) fail "formula url \"$url\" does not contain tag \"$TAG\" — bump homebrew/read.rb before tagging" ;;
esac
[ -n "$sha" ] || fail "no sha256 line in $RB"
[ "$sha" != "REPLACE_WITH_RELEASE_SHA256" ] || fail "formula sha256 is still the placeholder — fill it from the built tarball before tagging"

# The tarball must match its own checksum file, and the formula must
# carry that same hash.
(cd "$(dirname "$SHAFILE")" && shasum -a 256 -c "$(basename "$SHAFILE")") \
    || fail "built tarball does not match $SHAFILE"
want=$(awk '{print $1}' "$SHAFILE")
[ "$sha" = "$want" ] || fail "formula sha256 \"$sha\" != built tarball \"$want\" — rebuild locally, update the formula, re-tag"

echo "PASS: $RB matches $TAG (version + url + sha256)"
