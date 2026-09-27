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
# Engine vendoring (issue #367): bundle Resources/libzatex.dylib is FIRST
# in the runtime load path (src/platform/macos_zatex.m), so a vendored
# engine is the version that release ships. Source: $4, then
# $LIBZATEX_PATH, then the documented install path. Absent = graceful
# fallback (math renders as source text; see docs/engine.md) — never fail
# the bundle: CI runners and engine-less checkouts must still assemble.
LIBZATEX_SRC="${4:-${LIBZATEX_PATH:-}}"
if [ -z "$LIBZATEX_SRC" ] && [ -f "/usr/local/lib/libzatex.dylib" ]; then
    LIBZATEX_SRC="/usr/local/lib/libzatex.dylib"
fi
if [ -n "$LIBZATEX_SRC" ]; then
    [ -f "$LIBZATEX_SRC" ] || { echo "bundle: libzatex not found: $LIBZATEX_SRC" >&2; exit 1; }
    cp "$LIBZATEX_SRC" "$APP/Contents/Resources/libzatex.dylib"
    echo "bundle: vendored libzatex from $LIBZATEX_SRC"
else
    echo "bundle: no libzatex source (arg \$4 / LIBZATEX_PATH / /usr/local/lib) — ships without engine, math falls back to source text (see docs/engine.md)"
fi

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
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key>
			<string>Markdown</string>
			<key>CFBundleTypeRole</key>
			<string>Viewer</string>
			<key>LSHandlerRank</key>
			<string>Owner</string>
			<key>LSItemContentTypes</key>
			<array>
				<string>public.markdown</string>
				<string>net.daringfireball.markdown</string>
			</array>
			<key>CFBundleTypeExtensions</key>
			<array>
				<string>md</string>
				<string>markdown</string>
				<string>mdown</string>
				<string>mkd</string>
				<string>mkdn</string>
			</array>
		</dict>
	</array>
	<key>UTImportedTypeDeclarations</key>
	<array>
		<dict>
			<key>UTTypeIdentifier</key>
			<string>net.daringfireball.markdown</string>
			<key>UTTypeTagSpecification</key>
			<dict>
				<key>public.filename-extension</key>
				<array>
					<string>mdown</string>
					<string>mkd</string>
					<string>mkdn</string>
				</array>
			</dict>
		</dict>
	</array>
</dict>
</plist>
EOF

echo "bundle: $APP"
