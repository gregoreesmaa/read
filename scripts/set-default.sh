#!/bin/sh
# Make Read the default Markdown reader: macOS, Linux, Windows (Git Bash).
#
# Usage:
#   sh scripts/set-default.sh [--check] [--app-path PATH] [--binary PATH]
#                             [--extensions md,markdown,mdown,mkd,mkdn]
#
#   --check        report the current Markdown handler; exit 0 if it is Read,
#                  1 otherwise. Makes no changes.
#   --app-path     Read.app location (macOS only; default: /Applications,
#                  then ~/Applications).
#   --binary       `read` binary (Linux .desktop Exec, Windows open command;
#                  default: first `read` on PATH, else zig-out/bin/read).
#   --extensions   comma/space-separated list (default shown above). Selects
#                  which extensions the Windows branch claims; macOS claims
#                  the Markdown UTIs (the system maps them to these
#                  extensions) and Linux claims the Markdown MIME types.
#
# Zero dependencies beyond OS-native tools: LaunchServices via the system
# python3 (or duti when installed; canonical prefs-entry fallback when the
# setter API refuses a UTI) on macOS, xdg-mime (or mimeapps.list) on Linux,
# PowerShell + HKCU registry on Windows. No sudo needed.
set -eu

BUNDLE_ID="com.gregoreesmaa.read"
# The only settable Markdown UTIs. Rarer extensions (.mdown/.mkd/.mkdn)
# resolve to dynamic (dyn.*) UTIs whose handler no API rebinds (setter
# accepts but is a no-op), so they are deliberately not targeted here.
MAC_UTIS="public.markdown net.daringfireball.markdown"
LINUX_MIMES="text/markdown text/x-markdown"
EXTENSIONS="md markdown mdown mkd mkdn"
CHECK_ONLY=0
APP_PATH=""
BINARY=""

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
    sed -n '2,/^set -eu$/p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK_ONLY=1; shift ;;
        --app-path) APP_PATH="${2:?--app-path needs a value}"; shift 2 ;;
        --binary) BINARY="${2:?--binary needs a value}"; shift 2 ;;
        --extensions) EXTENSIONS="$(printf '%s' "${2:?--extensions needs a value}" | tr ',' ' ')"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown flag: $1 (see --help)" >&2; exit 1 ;;
    esac
done

# Space-normalize the extension list (commas and repeats collapse).
EXTENSIONS="$(printf '%s' "$EXTENSIONS" | tr ',' ' ' | tr -s ' ')"

fail() { echo "set-default: FAIL: $1" >&2; exit 1; }
note() { echo "set-default: $1"; }

detect_os() {
    case "$(uname -s 2>/dev/null || echo unknown)" in
        Darwin*) echo mac ;;
        Linux*) echo linux ;;
        MINGW*|MSYS*|CYGWIN*) echo windows ;;
        *)
            if command -v powershell.exe >/dev/null 2>&1; then echo windows
            else fail "unsupported OS: $(uname -s 2>/dev/null || echo unknown)"; fi ;;
    esac
}

# Resolve the read binary for the Linux/Windows branches: explicit flag,
# else PATH, else the repo build output (absolute path for .desktop/registry).
resolve_binary() {
    if [ -n "$BINARY" ]; then
        [ -f "$BINARY" ] || [ -f "$BINARY.exe" ] || fail "binary not found: $BINARY"
        case "$BINARY" in
            /*|*:*) printf '%s' "$BINARY" ;;
            *) printf '%s' "$(cd "$(dirname "$BINARY")" && pwd)/$(basename "$BINARY")" ;;
        esac
        return
    fi
    if command -v read >/dev/null 2>&1; then command -v read; return; fi
    if [ -x "$ROOT/zig-out/bin/read" ]; then printf '%s' "$ROOT/zig-out/bin/read"; return; fi
    fail "no read binary: build first (zig build -Doptimize=ReleaseFast) or pass --binary"
}

# ---------------------------------------------------------------- macOS ---

# Query one UTI's default handler bundle id (empty when unset).
macos_query() {
    /usr/bin/python3 - "$1" <<'EOF'
import ctypes, sys
cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
ls = ctypes.CDLL("/System/Library/Frameworks/CoreServices.framework/CoreServices")
cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
cf.CFStringCreateWithCString.restype = ctypes.c_void_p
cf.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
cf.CFStringGetCString.restype = ctypes.c_bool
ls.LSCopyDefaultRoleHandlerForContentType.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
ls.LSCopyDefaultRoleHandlerForContentType.restype = ctypes.c_void_p
uti = cf.CFStringCreateWithCString(None, sys.argv[1].encode(), 0x08000100)
h = ls.LSCopyDefaultRoleHandlerForContentType(uti, 0xFFFFFFFF)
buf = ctypes.create_string_buffer(512)
if h and cf.CFStringGetCString(h, buf, 512, 0x08000100):
    print(buf.value.decode())
EOF
}

# Fallback when the setter API refuses a UTI (observed: public.markdown
# returns paramErr on recent macOS via both the C and NSWorkspace APIs):
# write the exact entry the API would have written. Honored at least on
# daemon reseed (relogin); the set flow re-queries and reports active vs
# pending per UTI so a dormant mapping is never claimed as done.
macos_write_prefs_entry() {
    /usr/bin/python3 - "$1" "$BUNDLE_ID" <<'EOF'
import plistlib, os, sys, time
uti, bid = sys.argv[1], sys.argv[2]
p = os.path.expanduser("~/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist")
d = plistlib.load(open(p, "rb"))
hs = [h for h in d.get("LSHandlers", []) if h.get("LSHandlerContentType") != uti]
hs.append({
    "LSHandlerContentType": uti,
    "LSHandlerRoleAll": bid,
    "LSHandlerPreferredVersions": {"LSHandlerRoleAll": "-"},
    # Same clock as sibling entries (CFAbsoluteTime: seconds since 2001-01-01).
    "LSHandlerModificationDate": int(time.time() - 978307200),
})
d["LSHandlers"] = hs
plistlib.dump(d, open(p, "wb"))
EOF
    # Direct plist edits bypass cfprefsd: bounce it so the daemon re-reads
    # instead of clobbering the entry (auto-respawns; standard practice).
    killall cfprefsd 2>/dev/null || true
}

# Set one UTI's default handler via LaunchServices (same API duti uses).
macos_set_uti() {
    /usr/bin/python3 - "$1" "$BUNDLE_ID" <<'EOF'
import ctypes, sys
cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
ls = ctypes.CDLL("/System/Library/Frameworks/CoreServices.framework/CoreServices")
cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
cf.CFStringCreateWithCString.restype = ctypes.c_void_p
ls.LSSetDefaultRoleHandlerForContentType.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p]
ls.LSSetDefaultRoleHandlerForContentType.restype = ctypes.c_int32
uti = cf.CFStringCreateWithCString(None, sys.argv[1].encode(), 0x08000100)
bid = cf.CFStringCreateWithCString(None, sys.argv[2].encode(), 0x08000100)
sys.exit(0 if ls.LSSetDefaultRoleHandlerForContentType(uti, 0xFFFFFFFF, bid) == 0 else 1)
EOF
}

macos_verify() {
    ok=1
    for uti in $MAC_UTIS; do
        cur="$(macos_query "$uti")"
        note "mac: $uti -> ${cur:-(none)}"
        [ "$cur" = "$BUNDLE_ID" ] || ok=0
    done
    [ "$ok" = 1 ]
}

macos_main() {
    # --check reports system state and needs no bundle installed.
    if [ "$CHECK_ONLY" = 1 ]; then
        macos_verify
        return
    fi
    if [ -z "$APP_PATH" ]; then
        for cand in "/Applications/Read.app" "$HOME/Applications/Read.app"; do
            if [ -x "$cand/Contents/MacOS/Read" ]; then APP_PATH="$cand"; break; fi
        done
    fi
    [ -n "$APP_PATH" ] || fail "Read.app not found; bundle it first:
  zig build -Doptimize=ReleaseFast && sh scripts/make_app_bundle.sh zig-out/bin/read /Applications"
    [ -x "$APP_PATH/Contents/MacOS/Read" ] || fail "$APP_PATH is not a Read.app bundle"

    # Register the bundle (picks up CFBundleDocumentTypes), then claim UTIs.
    LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    if [ -x "$LSREG" ]; then "$LSREG" -f "$APP_PATH" 2>/dev/null || true; fi

    have_setter=0
    if command -v duti >/dev/null 2>&1; then have_setter=1; fi
    if [ -x /usr/bin/python3 ]; then have_setter=1; fi
    [ "$have_setter" = 1 ] || fail "need duti or system python3; else set it by hand:
  brew install duti && sh scripts/set-default.sh
  or Finder: any .md > Get Info > Open with > Read > Change All"

    # Per-UTI attempt: API first, canonical prefs entry on refusal.
    # Never abort mid-list: every UTI gets its attempt and its report.
    for uti in $MAC_UTIS; do
        if [ "$(macos_query "$uti")" = "$BUNDLE_ID" ]; then
            note "mac: $uti -> $BUNDLE_ID (already)"
            continue
        fi
        if command -v duti >/dev/null 2>&1; then
            duti -s "$BUNDLE_ID" "$uti" all 2>/dev/null || true
        else
            macos_set_uti "$uti" 2>/dev/null || true
        fi
        if [ "$(macos_query "$uti")" = "$BUNDLE_ID" ]; then
            note "mac: $uti -> $BUNDLE_ID (active)"
            continue
        fi
        macos_write_prefs_entry "$uti"
        cur="$(macos_query "$uti")"
        if [ "$cur" = "$BUNDLE_ID" ]; then
            note "mac: $uti -> $BUNDLE_ID (active)"
        else
            note "mac: $uti -> ${cur:-(none)} (entry written; needs logout or Finder Change All)"
        fi
    done

    macos_verify || fail "not fully active (see lines above; MDM may lock defaults)"
    note "Read is the default Markdown reader"
}

# ---------------------------------------------------------------- Linux ---

linux_desktop_file() {
    printf '%s' "${XDG_DATA_HOME:-$HOME/.local/share}/applications/read.desktop"
}

linux_query() {
    mime="$1"
    if command -v xdg-mime >/dev/null 2>&1; then
        xdg-mime query default "$mime" 2>/dev/null || true
    else
        grep -h "^$mime=" "$HOME/.config/mimeapps.list" 2>/dev/null | head -n 1 | cut -d= -f2- | tr -d ' ' || true
    fi
}

linux_verify() {
    ok=1
    for mime in $LINUX_MIMES; do
        cur="$(linux_query "$mime")"
        note "linux: $mime -> ${cur:-(none)}"
        [ "$cur" = "read.desktop" ] || ok=0
    done
    [ "$ok" = 1 ]
}

linux_main() {
    if [ "$CHECK_ONLY" = 1 ]; then
        linux_verify
        return
    fi

    desk="$(linux_desktop_file)"
    bin="$(resolve_binary)"
    if [ ! -f "$desk" ]; then
        mkdir -p "$(dirname "$desk")"
        cat > "$desk" <<EOF
[Desktop Entry]
Type=Application
Name=Read
Comment=Ultra-minimalist Markdown reader
Exec=$bin %F
MimeType=text/markdown;text/x-markdown;
Terminal=false
Categories=Office;Viewer;
EOF
        note "linux: wrote $desk"
    elif [ -n "$BINARY" ] && ! grep -q "^Exec=$bin" "$desk" 2>/dev/null; then
        sed -i "s|^Exec=.*|Exec=$bin %F|" "$desk"
        note "linux: Exec now $bin"
    fi

    if command -v xdg-mime >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        xdg-mime default read.desktop $LINUX_MIMES
        if command -v update-desktop-database >/dev/null 2>&1; then
            update-desktop-database "$(dirname "$desk")" 2>/dev/null || true
        fi
    else
        # xdg-mime is just this file; write the entries directly.
        mkdir -p "$HOME/.config"
        touch "$HOME/.config/mimeapps.list"
        grep -q "^\[Default Applications\]" "$HOME/.config/mimeapps.list" ||
            printf '[Default Applications]\n' >> "$HOME/.config/mimeapps.list"
        for mime in $LINUX_MIMES; do
            sed -i "/^$mime=/d" "$HOME/.config/mimeapps.list"
            sed -i "s|^\[Default Applications\]|[Default Applications]\n$mime=read.desktop|" \
                "$HOME/.config/mimeapps.list"
        done
    fi

    linux_verify || fail "association did not stick"
    note "Read is the default Markdown reader"
}

# --------------------------------------------------------------- Windows ---

# Pick powershell.exe (Git Bash) or pwsh (PowerShell Core).
win_ps() {
    if command -v powershell.exe >/dev/null 2>&1; then printf 'powershell.exe'
    elif command -v pwsh.exe >/dev/null 2>&1; then printf 'pwsh.exe'
    elif command -v pwsh >/dev/null 2>&1; then printf 'pwsh'
    else fail "no PowerShell found (run from Git Bash)"; fi
}

# Windows path for the binary (cygpath when under MSYS/Cygwin).
win_exe() {
    p="$(resolve_binary)"
    case "$p" in
        *.exe) ;;
        *) [ -f "$p.exe" ] && p="$p.exe" || fail "Windows needs read.exe (--binary PATH)" ;;
    esac
    if command -v cygpath >/dev/null 2>&1; then cygpath -w "$p"; else printf '%s' "$p"; fi
}

windows_main() {
    ps="$(win_ps)"
    if [ "$CHECK_ONLY" = 1 ]; then
        # "Read.Markdown" is the ProgID the set branch claims, and the check
        # expectation here.
        {
            printf '$exts = @('
            for e in $EXTENSIONS; do printf "'%s'," "$e"; done
            printf ')\n'
            cat <<'EOF'
$fail = $false
foreach ($e in $exts) {
  if (-not $e.StartsWith(".")) { $e = "." + $e }
  $v = (Get-ItemProperty -Path "HKCU:\Software\Classes\$e" -Name "(default)" -ErrorAction SilentlyContinue)."(default)"
  if ([string]::IsNullOrEmpty($v)) { $v = "(none)" }
  Write-Output ("windows: {0} -> {1}" -f $e, $v)
  if ($v -ne "Read.Markdown") { $fail = $true }
}
exit ($fail ? 1 : 0)
EOF
        } | "$ps" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command -
        return
    fi

    exe="$(win_exe)"
    # Single-quote-escape for PowerShell (' -> '').
    esc_exe="$(printf '%s' "$exe" | sed "s/'/''/g")"
    {
        printf '$exts = @('
        for e in $EXTENSIONS; do printf "'%s'," "$e"; done
        printf ')\n$exe = %s\n' "'$esc_exe'"
        cat <<'EOF'
$progid = "Read.Markdown"
New-Item -Path "HKCU:\Software\Classes\$progid\shell\open\command" -Force | Out-Null
Set-ItemProperty -Path "HKCU:\Software\Classes\$progid" -Name "(default)" -Value "Markdown document (Read)"
Set-ItemProperty -Path "HKCU:\Software\Classes\$progid\shell\open\command" -Name "(default)" -Value ('"{0}" "%1"' -f $exe)
foreach ($e in $exts) {
  if (-not $e.StartsWith(".")) { $e = "." + $e }
  New-Item -Path "HKCU:\Software\Classes\$e" -Force | Out-Null
  Set-ItemProperty -Path "HKCU:\Software\Classes\$e" -Name "(default)" -Value $progid
  $uc = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$e\UserChoice"
  if (Test-Path $uc) { Remove-Item $uc -Force }
  $v = (Get-ItemProperty -Path "HKCU:\Software\Classes\$e" -Name "(default)")."(default)"
  Write-Output ("windows: {0} -> {1}" -f $e, $v)
  if ($v -ne $progid) { exit 1 }
}
Write-Output "Read is the default Markdown reader"
EOF
    } | "$ps" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command -
}

# ------------------------------------------------------------------ main ---

case "$(detect_os)" in
    mac) macos_main ;;
    linux) linux_main ;;
    windows) windows_main ;;
esac
