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
sips -g pixelWidth "$APP/Contents/Resources/Read.icns" >/dev/null || fail "Read.icns unreadable"

echo "PASS: $APP bundle valid ($(val CFBundleShortVersionString))"
