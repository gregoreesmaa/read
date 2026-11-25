#!/bin/sh
# Assemble a release distribution directory for one OS/arch artifact.
# Usage: sh scripts/make_dist.sh <os> <arch> <version> <binary> <out-dir>
#   <os>      macos | linux | windows
#   <arch>    arm64 | x86_64
#   <version> e.g. 0.2.0 (no leading v)
#   <binary>  path to the ship binary (read or read.exe)
#   <out-dir> parent dir receiving read-<v>-<os>-<arch>/ (tarball/zip built
#             by the release workflow, not here — zip needs PowerShell).
#
# Layout per OS (fonts + OFL texts ship on Linux/Windows; the macOS bundle
# carries the icon + plist via make_app_bundle.sh separately):
#   macos:   read, LICENSE
#   linux:   read, LICENSE, fonts/*.ttf, fonts/OFL-*.txt, README-linux.txt
#   windows: read.exe, LICENSE, fonts/*.ttf, fonts/OFL-*.txt, README-windows.txt
set -eu

OS="${1:?usage: make_dist.sh <os> <arch> <version> <binary> <out-dir>}"
ARCH="${2:?usage: make_dist.sh <os> <arch> <version> <binary> <out-dir>}"
VER="${3:?usage: make_dist.sh <os> <arch> <version> <binary> <out-dir>}"
BIN="${4:?usage: make_dist.sh <os> <arch> <version> <binary> <out-dir>}"
OUT="${5:?usage: make_dist.sh <os> <arch> <version> <binary> <out-dir>}"

cd "$(dirname "$0")/.."
[ -f "$BIN" ] || { echo "FAIL: binary not found: $BIN"; exit 2; }
case "$OS" in
    macos|linux|windows) ;;
    *) echo "FAIL: unknown os: $OS"; exit 2 ;;
esac

DIST="read-v$VER-$OS-$ARCH"
DST="$OUT/$DIST"
rm -rf "$DST"
mkdir -p "$DST"

cp "$BIN" "$DST/"
cp LICENSE "$DST/"

if [ "$OS" = "linux" ] || [ "$OS" = "windows" ]; then
    mkdir -p "$DST/fonts"
    cp assets/fonts/*.ttf "$DST/fonts/"
    cp assets/fonts/OFL-*.txt "$DST/fonts/"
    for f in "$DST/fonts/OFL-"*.txt; do
        [ -f "$f" ] || { echo "FAIL: OFL texts missing under assets/fonts (see docs/release.md)"; exit 2; }
    done
fi

if [ "$OS" = "linux" ]; then
    cat > "$DST/README-linux.txt" <<EOF
Read v$VER for Linux ($ARCH)

Run: ./read file.md
Keys: j/k scroll, Space page, t theme, q quit (full list: docs/keys.md).

Fonts: bundled under fonts/ (IBM Plex Serif, Space Grotesk, JetBrains
Mono, all SIL OFL — license texts beside them). No system install
needed; DejaVu (fontconfig) covers missing glyphs.

Requires: X11, FreeType, fontconfig, libpng (stock on Ubuntu 22.04+).
Floor: Ubuntu 22.04 / glibc 2.35+ (musl-static libc build runs anywhere).
Unsigned build: verify the SHA256SUMS file from the GitHub release.
EOF
fi

if [ "$OS" = "windows" ]; then
    cat > "$DST/README-windows.txt" <<EOF
Read v$VER for Windows ($ARCH)

Run: read.exe file.md
Keys: j/k scroll, Space page, t theme, q quit (full list: docs/keys.md).

Fonts: bundled under fonts/ (IBM Plex Serif, Space Grotesk, JetBrains
Mono, all SIL OFL — license texts beside them). No system install needed.

Floor: Windows 10 1809+.
Unsigned build: Windows SmartScreen will warn on first launch
(Verify the SHA256SUMS file, then Run anyway). See docs/release.md.
EOF
fi

echo "dist: $DST"
ls -la "$DST"
