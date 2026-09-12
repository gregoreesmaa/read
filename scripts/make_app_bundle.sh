#!/bin/sh
# Assemble Read.app from a built `read` binary (issue #102).
# Usage: sh scripts/make_app_bundle.sh <path-to-read-binary> <out-dir> [version]
# Produces <out-dir>/Read.app with the committed icon + Info.plist.
# No compiler, no dependencies; safe to run in CI and releases.
set -eu

BIN="${1:?usage: make_app_bundle.sh <read-binary> <out-dir> [version]}"
OUT="${2:?usage: make_app_bundle.sh <read-binary> <out-dir> [version]}"
VERSION="${3:-0.1.0}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$OUT/Read.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Read"
chmod +x "$APP/Contents/MacOS/Read"
cp "$ROOT/assets/icon/Read.icns" "$APP/Contents/Resources/Read.icns"
cp "$ROOT/scripts/read-plugin-render.sh" "$APP/Contents/Resources/read-plugin-render.sh"
chmod +x "$APP/Contents/Resources/read-plugin-render.sh"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>Read</string>
	<key>CFBundleDisplayName</key>
	<string>Read</string>
	<key>CFBundleIdentifier</key>
	<string>com.gregoreesmaa.read</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleExecutable</key>
	<string>Read</string>
	<key>CFBundleIconFile</key>
	<string>Read</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>LSMinimumSystemVersion</key>
	<string>12.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
EOF

echo "bundle: $APP"
