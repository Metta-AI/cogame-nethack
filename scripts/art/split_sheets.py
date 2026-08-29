#!/usr/bin/env python3
"""Key, split and pad the nano-banana sheets into board sprites.

Gemini does not return alpha, and the "pure green" you asked for comes back
as *some* green with a tinted edge. Flood-fill from the image border (so
green accents inside a figure survive), take the backdrop colour as the
median of the border, split the row on empty columns and pad each part to a
square, then resize to SIZE px.

    python3 scripts/art/split_sheets.py

Writes data/art/<name>.png, which src/nethack/global.nim blits onto the
board. The derived PNGs are COMMITTED — CI does not regenerate art.
"""

import os
from collections import deque

from PIL import Image

SIZE = 64
TOLERANCE = 60

SHEETS = [
    ("cog_sheet.png", ["cog_digger"]),
    ("monsters_sheet_a.png", ["mon_gridbug", "mon_rat", "mon_lichen", "mon_jackal"]),
    ("monsters_sheet_b.png", ["mon_kobold", "mon_gnome", "mon_zombie", "mon_eye"]),
    ("monsters_sheet_c.png", ["mon_orc", "mon_dwarf", "mon_mummy", "mon_oracle"]),
]


def border_colour(image):
    w, h = image.size
    px = image.load()
    samples = []
    for x in range(0, w, max(1, w // 64)):
        samples.append(px[x, 0][:3])
        samples.append(px[x, h - 1][:3])
    for y in range(0, h, max(1, h // 64)):
        samples.append(px[0, y][:3])
        samples.append(px[w - 1, y][:3])
    channels = []
    for i in range(3):
        values = sorted(s[i] for s in samples)
        channels.append(values[len(values) // 2])
    return tuple(channels)


def key(image):
    """Flood-fill the backdrop from the border, so inner greens survive."""
    image = image.convert("RGBA")
    w, h = image.size
    px = image.load()
    target = border_colour(image)
    seen = bytearray(w * h)
    queue = deque()

    def near(c):
        return (abs(c[0] - target[0]) + abs(c[1] - target[1]) +
                abs(c[2] - target[2])) <= TOLERANCE * 3

    for x in range(w):
        for y in (0, h - 1):
            queue.append((x, y))
    for y in range(h):
        for x in (0, w - 1):
            queue.append((x, y))
    while queue:
        x, y = queue.popleft()
        if x < 0 or y < 0 or x >= w or y >= h or seen[y * w + x]:
            continue
        seen[y * w + x] = 1
        if not near(px[x, y]):
            continue
        px[x, y] = (0, 0, 0, 0)
        queue.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))
    return image


def column_weights(image):
    w, h = image.size
    px = image.load()
    weights = []
    for x in range(w):
        count = 0
        for y in range(h):
            if px[x, y][3] > 16:
                count += 1
        weights.append(count)
    return weights


def split(image, count):
    weights = column_weights(image)
    filled = [w > 2 for w in weights]
    spans = []
    start = None
    for x, on in enumerate(filled):
        if on and start is None:
            start = x
        elif not on and start is not None:
            spans.append((start, x))
            start = None
    if start is not None:
        spans.append((start, len(filled)))
    spans = [s for s in spans if s[1] - s[0] > 8]
    spans.sort(key=lambda s: s[1] - s[0], reverse=True)
    spans = spans[:max(count, 1)]
    # Two figures whose props overlap (a pickaxe crossing a club) merge into
    # one span. Cut the widest span at its thinnest interior column until the
    # expected number of figures is back.
    while len(spans) < count:
        spans.sort(key=lambda s: s[1] - s[0], reverse=True)
        x0, x1 = spans.pop(0)
        lo = x0 + (x1 - x0) // 4
        hi = x1 - (x1 - x0) // 4
        cut = min(range(lo, hi), key=lambda x: (weights[x], abs(x - (x0 + x1) // 2)))
        spans.extend([(x0, cut), (cut, x1)])
    return sorted(spans)


def pad_square(image):
    w, h = image.size
    side = max(w, h)
    out = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    out.paste(image, ((side - w) // 2, (side - h) // 2))
    return out.resize((SIZE, SIZE), Image.LANCZOS)


def crop_rows(image):
    px = image.load()
    w, h = image.size
    top, bottom = 0, h
    for y in range(h):
        if any(px[x, y][3] > 16 for x in range(0, w, 2)):
            top = y
            break
    for y in range(h - 1, -1, -1):
        if any(px[x, y][3] > 16 for x in range(0, w, 2)):
            bottom = y + 1
            break
    return top, bottom


def main():
    os.makedirs("data/art", exist_ok=True)
    for sheet, names in SHEETS:
        path = os.path.join("scripts/art/source", sheet)
        image = key(Image.open(path))
        spans = split(image, len(names))
        if len(spans) != len(names):
            raise SystemExit(
                f"{sheet}: found {len(spans)} figures, expected {len(names)}")
        for (x0, x1), name in zip(spans, names):
            part = image.crop((x0, 0, x1, image.size[1]))
            top, bottom = crop_rows(part)
            part = part.crop((0, top, part.size[0], bottom))
            out = os.path.join("data/art", name + ".png")
            pad_square(part).save(out)
            print(f"wrote {out}")


if __name__ == "__main__":
    main()
