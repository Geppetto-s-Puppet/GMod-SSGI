"""Generate a tiling blue-noise VTF for the SSGI sampler.

Void-and-cluster (Ulichney 1993) on a toroidal grid, one independent channel per
RGBA slot, written out as an uncompressed VTF 7.2 (IMAGE_FORMAT_RGBA8888, no mips).
"""
import math, struct, sys

SIZE = 64
SIGMA = 1.9


def _gauss_kernel(n, sigma):
    r = int(math.ceil(3.0 * sigma))
    ks = 2 * r + 1
    k = [[0.0] * ks for _ in range(ks)]
    for y in range(ks):
        for x in range(ks):
            dy, dx = y - r, x - r
            k[y][x] = math.exp(-(dx * dx + dy * dy) / (2.0 * sigma * sigma))
    return k, r


class Energy:
    """Toroidal Gaussian energy field, updated incrementally."""

    def __init__(self, n, sigma):
        self.n = n
        self.k, self.r = _gauss_kernel(n, sigma)
        self.e = [0.0] * (n * n)

    def add(self, x, y, s):
        n, r, k = self.n, self.r, self.k
        for dy in range(-r, r + 1):
            row = ((y + dy) % n) * n
            kr = k[dy + r]
            for dx in range(-r, r + 1):
                self.e[row + ((x + dx) % n)] += s * kr[dx + r]

    def extreme(self, mask, want_filled):
        """Tightest cluster (want_filled) or largest void (not want_filled)."""
        best_i, best_v = -1, None
        for i in range(self.n * self.n):
            if mask[i] != want_filled:
                continue
            v = self.e[i]
            if best_v is None or (v > best_v if want_filled else v < best_v):
                best_i, best_v = i, v
        return best_i


def void_and_cluster(n, sigma, seed):
    total = n * n
    rnd = _Rand(seed)

    # 1. random initial binary pattern (~10% ones), then relax it to a
    #    "prototype" pattern by repeatedly moving the tightest cluster into
    #    the largest void.
    ones = total // 10
    mask = [False] * total
    picked = set()
    while len(picked) < ones:
        picked.add(rnd.below(total))
    for i in picked:
        mask[i] = True

    en = Energy(n, sigma)
    for i in range(total):
        if mask[i]:
            en.add(i % n, i // n, 1.0)

    while True:
        c = en.extreme(mask, True)
        mask[c] = False
        en.add(c % n, c // n, -1.0)
        v = en.extreme(mask, False)
        if v == c:
            mask[c] = True
            en.add(c % n, c // n, 1.0)
            break
        mask[v] = True
        en.add(v % n, v // n, 1.0)

    rank = [0] * total
    proto = list(mask)

    # 2. phase I - remove the tightest cluster repeatedly, ranking downwards.
    work = list(proto)
    en = Energy(n, sigma)
    for i in range(total):
        if work[i]:
            en.add(i % n, i // n, 1.0)
    count = sum(1 for v in work if v)
    for r in range(count - 1, -1, -1):
        c = en.extreme(work, True)
        work[c] = False
        en.add(c % n, c // n, -1.0)
        rank[c] = r

    # 3. phase II - fill the largest void repeatedly, ranking upwards.
    work = list(proto)
    en = Energy(n, sigma)
    for i in range(total):
        if work[i]:
            en.add(i % n, i // n, 1.0)
    for r in range(count, total):
        v = en.extreme(work, False)
        work[v] = True
        en.add(v % n, v // n, 1.0)
        rank[v] = r

    return [int((r + 0.5) * 255.0 / total) for r in rank]


class _Rand:
    """Small deterministic LCG so output is reproducible across machines."""

    def __init__(self, seed):
        self.s = seed & 0xFFFFFFFF

    def next(self):
        self.s = (self.s * 1664525 + 1013904223) & 0xFFFFFFFF
        return self.s

    def below(self, n):
        return self.next() % n


def write_vtf(path, size, channels):
    TEXTUREFLAGS_POINTSAMPLE = 0x0001
    TEXTUREFLAGS_NOMIP = 0x0100
    TEXTUREFLAGS_NOLOD = 0x0200
    IMAGE_FORMAT_RGBA8888 = 0

    header_size = 80
    h = bytearray()
    h += b"VTF\0"
    h += struct.pack("<II", 7, 2)
    h += struct.pack("<I", header_size)
    h += struct.pack("<HH", size, size)
    h += struct.pack("<I", TEXTUREFLAGS_POINTSAMPLE | TEXTUREFLAGS_NOMIP | TEXTUREFLAGS_NOLOD)
    h += struct.pack("<HH", 1, 0)          # frames, firstFrame
    h += b"\0" * 4                          # padding0
    h += struct.pack("<fff", 0.5, 0.5, 0.5)  # reflectivity
    h += b"\0" * 4                          # padding1
    h += struct.pack("<f", 1.0)             # bumpmapScaleFactor
    h += struct.pack("<i", IMAGE_FORMAT_RGBA8888)
    h += struct.pack("<B", 1)               # mipmapCount
    h += struct.pack("<i", -1)              # lowResImageFormat = none
    h += struct.pack("<BB", 0, 0)           # lowResImageWidth/Height
    h += struct.pack("<H", 1)               # depth (7.2)
    h += b"\0" * (header_size - len(h))
    assert len(h) == header_size

    px = bytearray()
    for i in range(size * size):
        for c in range(4):
            px.append(channels[c][i])

    with open(path, "wb") as f:
        f.write(bytes(h))
        f.write(bytes(px))


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "materials/texture_samples/ssgi_bluenoise.vtf"
    chans = []
    for c in range(4):
        sys.stderr.write("channel %d/4...\n" % (c + 1))
        chans.append(void_and_cluster(SIZE, SIGMA, 0x9E3779B9 + c * 0x85EBCA6B))
    write_vtf(out, SIZE, chans)
    sys.stderr.write("wrote %s (%dx%d RGBA8888)\n" % (out, SIZE, SIZE))
