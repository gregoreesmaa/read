#!/bin/sh
# Verify a Read.app bundle (issue #102): structure, executable, icon,
# plist validity + required keys. Used by CI and releases.
# Usage: sh scripts/check_app_bundle.sh <path-to-Read.app>
set -eu

APP="${1:?usage: check_app_bundle.sh <Read.app>}"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -d "$APP/Contents/MacOS" ] || fail "missing Contents/MacOS"
[ -d "$APP/Contents/Resources" ] || fail "missing Contents/Resources"
[ -x "$APP/Contents/MacOS/Read" ] || fail "MacOS/Read not executable"
[ -f "$APP/Contents/Resources/Read.icns" ] || fail "missing Read.icns"
[ -f "$APP/Contents/Info.plist" ] || fail "missing Info.plist"

file "$APP/Contents/MacOS/Read" | grep -q "Mach-O" || fail "MacOS/Read is not a Mach-O binary"
plutil -lint "$APP/Contents/Info.plist" >/dev/null || fail "Info.plist does not parse"

val() { plutil -extract "$1" raw "$APP/Contents/Info.plist" 2>/dev/null || echo ""; }
[ "$(val CFBundleExecutable)" = "Read" ] || fail "CFBundleExecutable != Read"
[ "$(val CFBundleIconFile)" = "Read" ] || fail "CFBundleIconFile != Read"
[ "$(val CFBundlePackageType)" = "APPL" ] || fail "CFBundlePackageType != APPL"
[ -n "$(val CFBundleIdentifier)" ] || fail "CFBundleIdentifier empty"
[ -n "$(val CFBundleShortVersionString)" ] || fail "CFBundleShortVersionString empty"
[ "$(val CFBundleDocumentTypes.0.CFBundleTypeRole)" = "Viewer" ] || fail "CFBundleDocumentTypes.0 role != Viewer"
grep -q "public.markdown" "$APP/Contents/Info.plist" || fail "missing public.markdown document type"
grep -q "net.daringfireball.markdown" "$APP/Contents/Info.plist" || fail "missing net.daringfireball.markdown document type"
grep -q "UTImportedTypeDeclarations" "$APP/Contents/Info.plist" || fail "missing UTImportedTypeDeclarations (mdown/mkd/mkdn)"
sips -g pixelWidth "$APP/Contents/Resources/Read.icns" >/dev/null || fail "Read.icns unreadable"
# Font vendoring (issue #390): Typography ships under Resources/Fonts so
# launch pays bundle-relative lookups, never source-tree stats. Hard gate:
# a bundle without fonts renders in fallback faces (silent degradation).
for f in IBMPlexSerif-Regular.ttf IBMPlexSerif-Bold.ttf IBMPlexSerif-Italic.ttf SpaceGrotesk.ttf JetBrainsMono.ttf; do
    [ -f "$APP/Contents/Resources/Fonts/$f" ] || fail "missing Resources/Fonts/$f (see scripts/make_app_bundle.sh)"
done
echo "NOTE: vendored fonts present (Resources/Fonts, 5 TTFs)"
# Engine assertion (issue #367): a vendored libzatex is the version that
# release ships. Soft gate: present must be a Mach-O dylib; absent is a
# NOTE, not a failure — engine-less bundles still assemble and run, with
# math falling back to source text (see docs/engine.md).
if [ -f "$APP/Contents/Resources/libzatex.dylib" ]; then
    file "$APP/Contents/Resources/libzatex.dylib" | grep -q "Mach-O" || fail "Resources/libzatex.dylib is not a Mach-O binary"
    file "$APP/Contents/Resources/libzatex.dylib" | grep -q "shared library" || fail "Resources/libzatex.dylib is not a shared library"
    echo "NOTE: vendored engine present (Resources/libzatex.dylib)"
else
    echo "NOTE: Resources/libzatex.dylib absent — math falls back to source text (see docs/engine.md)"
fi

echo "PASS: $APP bundle valid ($(val CFBundleShortVersionString))"
