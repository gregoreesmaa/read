#!/bin/sh
# Math test-double run (issue #378, upstream zatex#274).
#
# When a zatex checkout is available (ZATEX_CHECKOUT, a ../zatex sibling,
# or third_party/zatex), builds libzatex_test and runs the suite against
# it, so the OK + no_space + bad-input paths exercise deterministically
# through the TEST_HOOKS-gated ZATEX_TEST_DYLIB override in
# src/platform/macos_zatex.m. The double is scripted (fixed bytes, no
# network), so the hermetic default is preserved.
#
# macOS-only (the double's .dylib spelling): Linux/Windows runners
# build their own spellings but the host backends there resolve the
# double through their own loaders — until a per-OS double step lands,
# this script runs the suite against the double only on macOS and
# skips elsewhere, so the strict gate keeps pinning engine-absent
# skips there.
#
# Without a checkout (e.g. Read CI) it skips gracefully: the default
# suite already covers the engine-absent skip and the live-dylib paths.
#
# Usage: sh scripts/math_testdouble.sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
checkout="${ZATEX_CHECKOUT:-}"
if [ -z "$checkout" ]; then
    for cand in "$root/../zatex" "$root/third_party/zatex"; do
        if [ -f "$cand/packages/zatex/build.zig" ]; then checkout="$cand"; break; fi
    done
fi
if [ -z "$checkout" ] || [ ! -f "$checkout/packages/zatex/build.zig" ]; then
    echo "math_testdouble: no zatex checkout, skipping (hermetic default)"
    exit 0
fi
case "$(uname -s)" in
    Darwin) ;;
    *) echo "math_testdouble: non-macOS host, skipping (per-OS double step not landed)"; exit 0 ;;
esac
(cd "$checkout/packages/zatex" && zig build test-double)
dylib="$checkout/packages/zatex/zig-out/test-double/libzatex_test.dylib"
if [ ! -f "$dylib" ]; then
    echo "math_testdouble: double build produced no dylib, skipping"
    exit 0
fi

echo "math_testdouble: running suite against $dylib"
cd "$root"
# The live engine stays out (same note as ci.yml): the double run pins
# the scripted paths, not the real dylib behind READ_ZATEX_LIB.
READ_ZATEX_LIB="" ZATEX_TEST_DYLIB="$dylib" zig build test -Doptimize=ReleaseFast --summary all
