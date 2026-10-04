#!/usr/bin/env python3
# fringe_localize.py — pixel-diff localizer for damage_parity drag failures.
#
# TEMPORARY diagnostic for issue #389 / PR #398 (gestures 5/12/13): the
# cmp-based oracle says WHICH gesture mismatches but not WHERE. This script
# diffs an incremental-vs-fresh PNG pair and prints the diff bounding box,
# count, max per-channel delta, and the first rows of differing pixel
# coordinates, so the fringe can be mapped back onto text records
# (--dump-commands CMD text_run rects) and the painting mechanism named.
#
# Inputs are the same RGBA8 PNGs the headless harness writes; decoding is
# stdlib only (struct + zlib), same pattern as copy_button_damage.sh.
# Read-only: never touches the compared images, exit 0 always on success
# (localization, not gating — the cmp oracle stays the strict gate).
import struct
import sys
import zlib


def read_png(path):
    d = open(path, 'rb').read()
    pos = 8
    idat = b''
    w = h = bitd = ctype = inter = None
    while pos < len(d):
        (ln,) = struct.unpack('>I', d[pos:pos + 4])
        typ = d[pos + 4:pos + 8]
        data = d[pos + 8:pos + 8 + ln]
        if typ == b'IHDR':
            w, h, bitd, ctype, comp, filt, inter = struct.unpack('>IIBBBBB', data)
        elif typ == b'IDAT':
            idat += data
        elif typ == b'IEND':
            break
        pos += 12 + ln
    assert bitd == 8 and inter == 0, 'want 8-bit non-interlaced PNG'
    ch = {0: 1, 2: 3, 4: 2, 6: 4}[ctype]
    raw = zlib.decompress(idat)
    stride = w * ch
    px = bytearray(w * h * ch)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        f = raw[p]
        p += 1
        line = bytearray(raw[p:p + stride])
        p += stride
        if f == 1:
            for i in range(ch, stride):
                line[i] = (line[i] + line[i - ch]) & 255
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride):
                a = line[i - ch] if i >= ch else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
        elif f == 4:
            for i in range(stride):
                a = line[i - ch] if i >= ch else 0
                b = prev[i]
                c = prev[i - ch] if i >= ch else 0
                q = a + b - c
                pa, pb, pc = abs(q - a), abs(q - b), abs(q - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        px[y * stride:(y + 1) * stride] = line
        prev = bytes(line)
    return w, h, ch, px


def main():
    if len(sys.argv) != 4:
        print('usage: fringe_localize.py <inc.png> <fresh.png> <label>')
        return 2
    inc_path, fresh_path, label = sys.argv[1], sys.argv[2], sys.argv[3]
    wi, hi, chi, pi = read_png(inc_path)
    wf, hf, chf, pf = read_png(fresh_path)
    if (wi, hi, chi) != (wf, hf, chf):
        print('FRINGE %s: shape mismatch inc=%dx%dx%d fresh=%dx%dx%d' %
              (label, wi, hi, chi, wf, hf, chf))
        return 0
    n = 0
    maxd = 0
    x0, y0, x1, y1 = wi, hi, -1, -1
    first = []
    for y in range(hi):
        base = y * wi * chi
        for x in range(wi):
            o = base + x * chi
            dd = 0
            for c in range(chi):
                dd = max(dd, abs(pi[o + c] - pf[o + c]))
            if dd:
                n += 1
                maxd = max(maxd, dd)
                if x < x0:
                    x0 = x
                if x > x1:
                    x1 = x
                if y < y0:
                    y0 = y
                if y > y1:
                    y1 = y
                if len(first) < 12:
                    pix = tuple(pi[o + c] for c in range(chi))
                    ref = tuple(pf[o + c] for c in range(chi))
                    first.append((x, y, pix, ref))
    if n == 0:
        print('FRINGE %s: identical' % label)
        return 0
    print('FRINGE %s: n=%d maxd=%d bbox=x[%d..%d] y[%d..%d] w=%d h=%d' %
          (label, n, maxd, x0, x1, y0, y1, x1 - x0 + 1, y1 - y0 + 1))
    for (x, y, pix, ref) in first:
        print('FRINGE %s: px (%d,%d) inc=%s fresh=%s' % (label, x, y, pix, ref))
    return 0


if __name__ == '__main__':
    sys.exit(main())
