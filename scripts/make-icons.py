#!/usr/bin/env python3
"""Generate the site icons for docs/.

The mark is an isometric package sitting on the site's dark panel colour, with
the amber seam of the landing page as its tape. Everything is drawn from the one
set of coordinates below, so the SVG and the rasters can never drift apart.

Never hand-edit the PNGs: run this instead.

    scripts/make-icons.py

Writes site/{favicon.svg,favicon.ico,favicon-16.png,favicon-32.png,
             apple-touch-icon.png,logo.svg}
"""
import pathlib
import sys

from PIL import Image, ImageDraw

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "site"

BG = "#0b0f14"
LINE = "#1e2a3a"
TOP = "#7dd3fc"
LEFT = "#0ea5e9"
RIGHT = "#0369a1"
TAPE = "#f59e0b"

# One 64x64 grid for every size. The cube is an isometric box: a rhombus lid
# with two side faces hanging off it.
FACE_TOP = [(32, 11), (53, 22), (32, 33), (11, 22)]
FACE_LEFT = [(11, 22), (32, 33), (32, 55), (11, 44)]
FACE_RIGHT = [(53, 22), (32, 33), (32, 55), (53, 44)]
# Tape across the lid, parallel to its edges rather than along a diagonal, so
# it reads as lying on the surface instead of tracing the silhouette. It ends on
# the midpoint of the front-left edge...
TAPE_LINE = [(42.5, 16.5), (21.5, 27.5)]
# ...where the run down the front face picks it up, so the box reads as sealed.
TAPE_DOWN = [(21.5, 27.5), (21.5, 49.5)]

SVG = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64">
  <rect width="64" height="64" rx="14" fill="{BG}"/>
  <rect x=".5" y=".5" width="63" height="63" rx="13.5" fill="none" stroke="{LINE}"/>
  <polygon points="{' '.join(f'{x},{y}' for x, y in FACE_LEFT)}" fill="{LEFT}"/>
  <polygon points="{' '.join(f'{x},{y}' for x, y in FACE_RIGHT)}" fill="{RIGHT}"/>
  <polygon points="{' '.join(f'{x},{y}' for x, y in FACE_TOP)}" fill="{TOP}"/>
  <path d="M{TAPE_LINE[0][0]} {TAPE_LINE[0][1]} L{TAPE_LINE[1][0]} {TAPE_LINE[1][1]}"
        stroke="{TAPE}" stroke-width="2.5" stroke-linecap="round"/>
  <path d="M{TAPE_DOWN[0][0]} {TAPE_DOWN[0][1]} L{TAPE_DOWN[1][0]} {TAPE_DOWN[1][1]}"
        stroke="{TAPE}" stroke-width="2.5" stroke-linecap="round"/>
</svg>
"""


def draw(size: int, scale: int = 8) -> Image.Image:
    """Render the mark at `size` px, supersampled so the diagonals stay clean."""
    s = size * scale
    k = s / 64
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    def pts(poly):
        return [(x * k, y * k) for x, y in poly]

    d.rounded_rectangle([0, 0, s - 1, s - 1], radius=14 * k, fill=BG, outline=LINE,
                        width=max(1, int(k)))
    d.polygon(pts(FACE_LEFT), fill=LEFT)
    d.polygon(pts(FACE_RIGHT), fill=RIGHT)
    d.polygon(pts(FACE_TOP), fill=TOP)
    d.line(pts(TAPE_LINE), fill=TAPE, width=max(1, int(2.5 * k)))
    d.line(pts(TAPE_DOWN), fill=TAPE, width=max(1, int(2.5 * k)))

    return img.resize((size, size), Image.LANCZOS)


def main() -> int:
    if not OUT.is_dir():
        print(f"no {OUT}", file=sys.stderr)
        return 1

    (OUT / "favicon.svg").write_text(SVG)
    # The landing page shows the same mark next to the title.
    (OUT / "logo.svg").write_text(SVG)

    draw(16).save(OUT / "favicon-16.png")
    draw(32).save(OUT / "favicon-32.png")
    draw(180).save(OUT / "apple-touch-icon.png")
    # Pillow rescales for the extra .ico entries, so hand it the largest first.
    draw(64).save(OUT / "favicon.ico", sizes=[(16, 16), (32, 32), (48, 48)])

    for f in ("favicon.svg", "logo.svg", "favicon.ico", "favicon-16.png",
              "favicon-32.png", "apple-touch-icon.png"):
        print(f"  docs/{f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
