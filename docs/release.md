# Releasing Read

## Cut a release

```bash
git tag v0.1.0 && git push origin v0.1.0
```

Tag last: bump `homebrew/read.rb` first (see [Homebrew](#homebrew)) — the
workflow fails before publish when the formula disagrees with the tag.

Pushing a `v*` tag runs [.github/workflows/release.yml](../.github/workflows/release.yml):
six native build jobs (runner-per-OS, never cross-compile) plus one publish
job. Each build job gates (strict tests, size budget), builds, checks
reproducibility, and uploads its artifact; `publish` downloads all
artifacts, writes one changelog + `SHA256SUMS`, runs the Homebrew gate, and
creates the GitHub release with:

| Artifact | Contents |
| :--- | :--- |
| `read-vX.Y.Z-macos-arm64.tar.gz` | `read` ship binary + `LICENSE` + `Read.app` bundle (icon + plist via `scripts/make_app_bundle.sh`). Vendors `libzatex.dylib` at `Contents/Resources/` when available at bundle time (see [engine.md](engine.md)); without one math falls back to source text. |
| `read-vX.Y.Z-macos-x86_64.tar.gz` | Same layout, Intel build. |
| `read-vX.Y.Z-linux-x86_64.tar.gz` | `read` + `LICENSE` + `fonts/*.ttf` + `fonts/OFL-*.txt` + `README-linux.txt` (via `scripts/make_dist.sh`). |
| `read-vX.Y.Z-linux-arm64.tar.gz` | Same layout, ARM64 build. |
| `read-vX.Y.Z-windows-x86_64.zip` | `read.exe` + `LICENSE` + `fonts/` + `README-windows.txt` (via `scripts/make_dist.sh`). |
| `read-vX.Y.Z-windows-arm64.zip` | Same layout, ARM64 build (non-blocking until proven — see below). |
| `SHA256SUMS` | Unified checksums over all archives (plus per-file `.sha256` sidecars). |
| Notes | Changelog from `git log` since the previous tag (or a first-release note). |

The Windows ARM64 job runs with `continue-on-error: true` and is excluded
from `publish`'s `needs`: it must not block the other five releases until
it is green for two consecutive releases, then it is promoted to required.

## Per-OS install notes

- **macOS**: unpack, drag `Read.app` to Applications (or run `read`
  directly). `--version` prints the release tag (baked in via
  `-Dversion=`; local builds report `0.0.0-dev`).
- **Linux**: `tar xzf read-vX.Y.Z-linux-<arch>.tar.gz && ./read-vX.Y.Z-linux-<arch>/read file.md`.
  Requires X11, FreeType, fontconfig, libpng (stock on Ubuntu 22.04+).
  Floor: Ubuntu 22.04 / glibc 2.35 — the release binary is musl-static-libc
  with dynamic system GUI libs, and each Linux job smoke-runs it on a
  `ubuntu:22.04` container before packaging.
- **Windows**: unzip, run `read.exe file.md`. Floor: Windows 10 1809+.
  SmartScreen warns on first launch (unsigned — see below).

## Signing & notarization (maintainer secrets)

macOS artifacts sign + notarize per-arch when secrets exist; Linux and
Windows artifacts are **unsigned** in v1 (Authenticode is a follow-up —
needs cert procurement). Without secrets the workflow still publishes, but
the artifacts are unsigned and the release notes say so.

| Secret | Value |
| :--- | :--- |
| `APPLE_DEVELOPER_IDENTITY` | Developer ID Application identity (e.g. `Developer ID Application: Name (TEAMID)`) |
| `APPLE_ID` | Apple ID for notarytool |
| `APPLE_APP_PASSWORD` | App-specific password |
| `APPLE_TEAM_ID` | Developer team ID |

The workflow codesigns with `--options runtime`, submits via `xcrun notarytool --wait`,
and staples. These steps are skipped (not failed) when the secrets are absent.

## Homebrew

`homebrew/read.rb` is the formula, pointed at the **macOS arm64 tarball
only** (a Linuxbrew stanza is a follow-up). Per release, update its
`version`, `url`, and `sha256` **before tagging** — the publish job runs
`scripts/check_homebrew_formula.sh` and fails before publish when the
formula disagrees with the tag, so a skipped bump blocks the release
instead of shipping a stale formula. Order (builds are reproducible, so
the hash is knowable up front):

```bash
zig build -Doptimize=ReleaseFast
sh scripts/make_app_bundle.sh zig-out/bin/read /tmp/ReadApp "${TAG#v}"
# ... package as below, take dist/*.tar.gz.sha256, then:
# edit homebrew/read.rb: version → TAG without `v`, url → the new
# tarball URL, sha256 → the hash above. Commit, then:
git tag vX.Y.Z && git push origin vX.Y.Z
```

Verify the gate locally with the packaged files:

```bash
sh scripts/check_homebrew_formula.sh vX.Y.Z dist/read-vX.Y.Z-macos-arm64.tar.gz dist/read-vX.Y.Z-macos-arm64.tar.gz.sha256
```

From a clean machine:

```bash
brew install --build-from-source ./homebrew/read.rb
```

For a one-word install, create the tap once (`homebrew-read` repo containing this
`Formula/`), then `brew tap gregoreesmaa/read && brew install read`.

## Reproducible builds

Same tag, same bytes: pinned Zig 0.16.0 + `zig build -Doptimize=ReleaseFast -Dversion=<tag>`.
Each build job rebuilds twice into separate prefixes and `cmp`s the binaries —
a mismatch fails the release. Verified locally (2026-09, Darwin arm64):
two `--prefix` rebuilds produced identical sha256 with the size gate green.
Linux musl targets reproduce the same way; Windows PE `cmp`s byte-identical
in practice (re-record the verdict here if a timestamp-only drift appears).

## Font licensing (OFL)

The Linux/Windows distributions redistribute the bundled fonts, so the
license texts ship beside them: `assets/fonts/OFL-*.txt` (copyright lines
copied from each TTF's name table — IBM Plex Serif © 2020 IBM Corp,
JetBrains Mono © 2020 JetBrains, Space Grotesk © 2020 Florian Karsten —
plus the SIL OFL 1.1 body). `scripts/make_dist.sh` fails the package when
an `OFL-*.txt` is missing. macOS needs no change (fonts register from
`assets/fonts/` at dev time; the bundle carries the binary only).

## Lean-release guarantee

Release artifacts go through the same contract as local builds: the strict gate,
`scripts/size_gate.sh` (200 KiB Mach-O/ELF, 280 KiB PE — the Windows CRT
links statically into `.text`, see the script header), and the compile-time
test/prod separation (test tooling lives in `read-test`, never in `read`;
each build job re-proves it with `scripts/ship_separation.sh`). Release
tooling (this workflow, the formula) never links into the ship binary.
