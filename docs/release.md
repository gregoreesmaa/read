# Releasing Read

## Cut a release

```bash
git tag v0.1.0 && git push origin v0.1.0
```

Pushing a `v*` tag runs [.github/workflows/release.yml](../.github/workflows/release.yml),
which gates (strict tests, size budget), builds, checks reproducibility, optionally
signs + notarizes, and publishes a GitHub release with:

- `read-vX.Y.Z-macos-arm64.tar.gz` (the `read` ship binary + `LICENSE`)
- `read-vX.Y.Z-macos-arm64.tar.gz.sha256` (checksum)
- Changelog generated from `git log` since the previous tag (or a first-release note
  when no earlier tag exists)

## Signing & notarization (maintainer secrets)

Without secrets the workflow still publishes, but the artifact is **unsigned** and the
release notes say so. To ship signed + notarized, set these repo secrets first:

| Secret | Value |
| :--- | :--- |
| `APPLE_DEVELOPER_IDENTITY` | Developer ID Application identity (e.g. `Developer ID Application: Name (TEAMID)`) |
| `APPLE_ID` | Apple ID for notarytool |
| `APPLE_APP_PASSWORD` | App-specific password |
| `APPLE_TEAM_ID` | Developer team ID |

The workflow codesigns with `--options runtime`, submits via `xcrun notarytool --wait`,
and staples. These steps are skipped (not failed) when the secrets are absent.

## Homebrew

`homebrew/read.rb` is the formula. Per release, update its `version`, `url`, and `sha256`
(from the published `.sha256` file). From a clean machine:

```bash
brew install --build-from-source ./homebrew/read.rb
```

For a one-word install, create the tap once (`homebrew-read` repo containing this
`Formula/`), then `brew tap gregoreesmaa/read && brew install read`.

## Reproducible builds

Same tag, same bytes: pinned Zig 0.16.0 + `zig build -Doptimize=ReleaseFast`.
The workflow rebuilds twice into separate prefixes and `cmp`s the binaries —
a mismatch fails the release. Verified locally (2026-09, Darwin arm64):
two `--prefix` rebuilds produced identical sha256 with the size gate green.

## Lean-release guarantee

Release artifacts go through the same contract as local builds: the strict gate,
`scripts/size_gate.sh` (< 180 KiB), and the compile-time test/prod separation
(test tooling lives in `read-test`, never in `read`). Release tooling (this workflow,
the formula) never links into the ship binary.
