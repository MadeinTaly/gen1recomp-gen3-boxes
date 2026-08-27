#!/usr/bin/env python3
"""Measures a wallpaper entry and says what will move.

Run over assets/wallpapers/. For every image it reports size, colour count
and SEAM -- the mean difference between the first and last columns. A layer
whose right edge continues into its left can be scrolled without showing the
join; one that cannot must be held still, or it drags a visible seam across
the box every few seconds.

This is deliberately a measurement rather than a review. It does not judge
whether art is good: it tells the author what the mod will do with it.

    python3 tools/check_wallpaper.py [directory]

Exits non-zero only for things that are actually broken: unreadable files,
wrong height, or a file named _far/_near whose seam says it cannot loop.
"""
import os
import struct
import sys
import zlib

SEAM_OK = 12.0
HEIGHT = 144


def read(path):
    d = open(path, "rb").read()
    if d[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos, idat, w, h, bd, ct = 8, b"", 0, 0, 8, 6
    while pos < len(d):
        ln = struct.unpack(">I", d[pos:pos + 4])[0]
        typ = d[pos + 4:pos + 8]
        body = d[pos + 8:pos + 8 + ln]
        if typ == b"IHDR":
            w, h, bd, ct = struct.unpack(">IIBB", body[:10])
        elif typ == b"IDAT":
            idat += body
        elif typ == b"IEND":
            break
        pos += 12 + ln
    if bd != 8 or ct not in (2, 6):
        raise ValueError("expected 8-bit RGB or RGBA")
    nch = 4 if ct == 6 else 3
    raw = zlib.decompress(idat)
    stride = w * nch
    rows, prev, p = [], bytearray(stride), 0
    for _ in range(h):
        f = raw[p]; p += 1
        line = bytearray(raw[p:p + stride]); p += stride
        for i in range(stride):
            a = line[i - nch] if i >= nch else 0
            b = prev[i]
            c = prev[i - nch] if i >= nch else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                pp = a + b - c
                pa, pb, pc = abs(pp - a), abs(pp - b), abs(pp - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        prev = line
        rows.append([tuple(line[x * nch:(x + 1) * nch]) + ((255,) if nch == 3 else ())
                     for x in range(w)])
    return w, h, rows


def seam(rows, w):
    tot = n = 0
    for row in rows:
        a, b = row[0], row[w - 1]
        if len(a) > 3 and a[3] < 40 and b[3] < 40:
            continue
        tot += sum(abs(a[i] - b[i]) for i in range(3))
        n += 1
    return (tot / n / 3) if n else 0.0


def main(directory):
    bad = []
    files = sorted(f for f in os.listdir(directory) if f.endswith(".png"))
    if not files:
        print("no wallpapers found in " + directory)
        return 0
    print("%-34s %9s %7s %7s  %s" % ("file", "size", "colours", "seam", "verdict"))
    for f in files:
        path = os.path.join(directory, f)
        try:
            w, h, rows = read(path)
        except Exception as e:
            print("%-34s  UNREADABLE: %s" % (f, e))
            bad.append(f)
            continue
        cols = len({p[:3] for row in rows for p in row})
        s = seam(rows, w)
        loops = s < SEAM_OK
        verdict = "loops -> may scroll" if loops else "painted -> holds still"
        print("%-34s %4dx%-4d %7d %7.1f  %s" % (f, w, h, cols, s, verdict))
        if h != HEIGHT:
            print("    ! height is %d, expected %d" % (h, HEIGHT))
            bad.append(f)
        if ("_far" in f or "_near" in f) and not loops:
            print("    ! named as a moving layer but does not loop: rename to "
                  "_base, or make its edges meet")
            bad.append(f)
    if bad:
        print("\n%d file(s) need attention" % len(bad))
        return 1
    print("\nall good")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "assets/wallpapers"))
