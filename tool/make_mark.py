"""Render the MELTDOWN mark to PNG.

Same geometry as LogoPainter in main.dart: a radiation trefoil whose blades
are melting, with an eye at the hub. No imaging library on this machine, so
this writes the PNG itself - zlib and struct are all it takes. Drawn oversized
and downsampled by sips, which buys clean antialiasing for free.
"""
import math, struct, zlib, sys

N = 1024
MASKABLE = len(sys.argv) > 1 and sys.argv[1] == 'maskable'
# A maskable icon may be cropped to a circle, so the art sits in the safe zone.
SCALE = 0.62 if MASKABLE else 0.88

BG_IN, BG_OUT = (0x16, 0x1E, 0x28), (0x06, 0x09, 0x0D)
GOLD  = (0xFF, 0xC9, 0x4D)
HOT   = (0xFF, 0x8A, 0x3A)
GREEN = (0x4B, 0xE0, 0x8A)
PALE  = (0xCF, 0xFF, 0xE4)
DARK  = (0x05, 0x07, 0x0A)

def lerp(a, b, t):
    t = max(0.0, min(1.0, t))
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))

def over(dst, src, a):
    a = max(0.0, min(1.0, a))
    return tuple(dst[i] * (1 - a) + src[i] * a for i in range(3))

BLADES = [-math.pi / 2, math.pi / 6, math.pi * 5 / 6]
DRIP   = [0.0, 0.34, 0.23]
B_IN, B_OUT, HUB = 0.31, 0.84, 0.265

def ang_in_blade(th, centre):
    d = (th - centre + math.pi) % (2 * math.pi) - math.pi
    return abs(d) <= math.pi / 6

def melt_base(centre):
    half = math.pi / 6
    a = centre - half * 0.55 if math.sin(centre - half) > math.sin(centre + half) \
        else centre + half * 0.55
    return math.cos(a) * B_OUT, math.sin(a) * B_OUT

rows = []
c = N / 2.0
R = c * SCALE
for py in range(N):
    row = bytearray()
    for px in range(N):
        x, y = (px - c + 0.5) / R, (py - c + 0.5) / R
        rad = math.hypot(x, y)
        col = lerp(BG_IN, BG_OUT, math.hypot(x, y) * 0.62 * SCALE * 1.6)

        th = math.atan2(y, x)
        # blades
        if B_IN <= rad <= B_OUT and any(ang_in_blade(th, b) for b in BLADES):
            col = GOLD
        # melt runs
        for i, b in enumerate(BLADES):
            L = DRIP[i]
            if L <= 0:
                continue
            bx, by = melt_base(b)
            dy = y - by
            if 0 <= dy <= L:
                t = dy / L
                w = 0.10 * (1 - t * t * 0.92)
                if abs(x - bx) <= w:
                    col = lerp(GOLD, HOT, t)
        # the drop that has already left the longest run
        dbx, dby = melt_base(BLADES[1])
        if math.hypot(x - math.cos(BLADES[1] + 0.22) * B_OUT,
                      y - (B_OUT + DRIP[1] * 1.30)) < 0.055:
            col = HOT
        # the hub: an iris, not a disc
        if rad < HUB:
            k = rad / HUB
            col = lerp(lerp(PALE, GREEN, min(1.0, k / 0.55)),
                       lerp(GREEN, DARK, max(0.0, (k - 0.55) / 0.45)),
                       1.0 if k > 0.55 else 0.0)
        elif rad < HUB * 1.9:
            col = over(col, GREEN, 0.22 * (1 - (rad - HUB) / (HUB * 0.9)) ** 2)
        # the slit
        pw, ph = HUB * 0.24, HUB * 1.42
        if abs(y) <= ph / 2:
            t = 1 - (abs(y) / (ph / 2)) ** 2
            if abs(x) <= pw * t:
                col = DARK
        row += bytes(int(round(max(0, min(255, v)))) for v in col)
    rows.append(bytes(row))

raw = b''.join(b'\x00' + r for r in rows)
def chunk(tag, data):
    return (struct.pack('>I', len(data)) + tag + data
            + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF))
png = (b'\x89PNG\r\n\x1a\n'
       + chunk(b'IHDR', struct.pack('>IIBBBBB', N, N, 8, 2, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))
out = 'master_maskable.png' if MASKABLE else 'master.png'
open(out, 'wb').write(png)
print('wrote', out, len(png), 'bytes')
