#!/bin/sh
# Plugin renderer driver (spec docs/plugins-async-spec.md §3).
# Usage: read-plugin-render.sh probe <renderer>
#        read-plugin-render.sh render <renderer> <srcfile> <outfile>
# probe: exit 0 when the renderer CLI exists, 1 otherwise.
# render: re-probes, renders SRC to OUT atomically (OUT.tmp + rename).
set -eu

tool_for() {
    case "$1" in
        mermaid) echo "mmdc" ;;
        *) echo "" ;;
    esac
}

if [ "${1:-}" = "probe" ]; then
    tool=$(tool_for "${2:-}")
    [ -n "$tool" ] && command -v "$tool" >/dev/null 2>&1
    exit $?
fi

if [ "${1:-}" = "render" ]; then
    renderer="$2"; src="$3"; out="$4"
    tool=$(tool_for "$renderer")
    [ -n "$tool" ] || exit 1
    command -v "$tool" >/dev/null 2>&1 || exit 1
    case "$renderer" in
        mermaid) "$tool" -i "$src" -o "$out.tmp" ;;
    esac
    [ -f "$out.tmp" ] && mv "$out.tmp" "$out"
    exit 0
fi

echo "usage: $0 probe|render ..." >&2
exit 2
