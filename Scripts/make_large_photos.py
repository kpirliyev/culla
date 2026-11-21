#!/usr/bin/env python3
"""Builds a small shoot of 24 MP photos for checking the loupe's zoom, from the Sonoma wallpaper
that ships with macOS.

Usage:
    make_large_photos.py <output dir>

Writes a burst of six 6000 x 4000 frames 0.3 s apart, each shifted a few pixels, with a
resolution chart (1-pixel stripes and text) near (0.6, 0.4) that is crisp only at 100%; an over-
and an under-exposed 6000 x 4000 frame; a 1500 x 2000 portrait; and a 1500 x 1000 photo.
Capture times are written as EXIF, and file dates set to them. Needs Python 3, Pillow and `sips`.
Used by Scripts/ui/12-loupe-large-photos.json.
"""

import datetime as dt
import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageEnhance

SOURCE = "/System/Library/Desktop Pictures/Sonoma.heic"  # 6016 x 6016
START = dt.datetime(2026, 11, 2, 9, 0, 0)


def exif_for(time):
    exif = Image.Exif()
    ifd = exif.get_ifd(0x8769)
    ifd[0x9003] = time.strftime("%Y:%m:%d %H:%M:%S")
    ifd[0x9291] = f"{time.microsecond // 10000:02d}"
    return exif


def save(image, folder, name, time):
    path = os.path.join(folder, name)
    image.save(path, "JPEG", quality=92, exif=exif_for(time))
    stamp = time.timestamp()
    os.utime(path, (stamp, stamp))


def draw_chart(image, frame):
    """1-pixel stripes, a 2-pixel grid and text: crisp only when one image pixel lands on one
    display pixel."""
    draw = ImageDraw.Draw(image)
    x0, y0 = 3400, 1400
    draw.rectangle((x0, y0, x0 + 400, y0 + 400), fill=(235, 235, 235))
    for i in range(0, 200, 2):
        draw.line((x0 + 10 + i, y0 + 10, x0 + 10 + i, y0 + 190), fill=(20, 20, 20))
        draw.line((x0 + 210, y0 + 10 + i, x0 + 390, y0 + 10 + i), fill=(20, 20, 20))
    for i in range(0, 180, 4):
        draw.rectangle((x0 + 10 + i, y0 + 210, x0 + 11 + i, y0 + 390), fill=(200, 40, 40))
    draw.text((x0 + 220, y0 + 260), f"FRAME {frame}", fill=(0, 0, 0))
    draw.text((x0 + 220, y0 + 300), "1 px = 1 px", fill=(0, 0, 0))


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    folder = sys.argv[1]
    os.makedirs(folder, exist_ok=True)
    with tempfile.TemporaryDirectory() as temporary:
        png = os.path.join(temporary, "source.png")
        subprocess.run(["sips", "-s", "format", "png", SOURCE, "--out", png],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        base = Image.open(png).convert("RGB")
    for k in range(6):
        frame = base.crop((8 + k * 2, 1000 + k * 3, 8 + k * 2 + 6000, 1000 + k * 3 + 4000))
        draw_chart(frame, k + 1)
        save(frame, folder, f"burst_{k + 1}.jpg", START + dt.timedelta(seconds=0.3 * k))
    save(ImageEnhance.Brightness(base.crop((0, 0, 6000, 4000))).enhance(2.4), folder, "overexposed.jpg",
         START + dt.timedelta(seconds=10))
    save(ImageEnhance.Brightness(base.crop((0, 2000, 6000, 6000))).enhance(0.25), folder, "underexposed.jpg",
         START + dt.timedelta(seconds=20))
    save(base.crop((1000, 1000, 4000, 5000)).resize((1500, 2000)), folder, "portrait.jpg",
         START + dt.timedelta(seconds=30))
    save(base.resize((1500, 1000)), folder, "small.jpg", START + dt.timedelta(seconds=40))
    print(f"Wrote 10 photos to {folder}")


if __name__ == "__main__":
    main()
