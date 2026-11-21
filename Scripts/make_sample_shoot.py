#!/usr/bin/env python3
"""Builds a sample shoot of non-private test photos from wallpapers that ship with macOS.

Usage:
    make_sample_shoot.py <output dir> [--count N] [--jobs J]

Without --count it writes the standard 35-photo shoot:

- 10 distinct "photos" (5 crops of Sonoma, 5 of Sonoma Horizon), 3000 x 2000, 5 minutes apart;
- blurred variants of the first crop of each (Gaussian radius 1.5, 3 and 6);
- one over-exposed and one under-exposed variant of the same crop;
- a burst of 4 frames per source, each shifted a few pixels, 0.3 s apart;
- a half-size copy of one photo with the same capture time (a near-duplicate);
- an exact file copy ("sonoma_1 copy.jpg");
- three small real photos in a subfolder (sub/), without capture times;
- one undecodable .jpg, one fake video (.mov), and one fake RAW twin (horizon_2.dng beside
  horizon_2.jpg, a copy of its bytes).

With --count N it adds generated scenes until the shoot holds about N photos: 1500 x 1000 crops
at varying positions and sizes, 3 minutes apart, with bursts, blurred and exposure variants,
near-duplicates and exact copies mixed in. 2,000 photos take about 0.45 GB.

Capture times are written as EXIF DateTimeOriginal (0x9003) and SubsecTimeOriginal (0x9291) in
the Exif IFD (0x8769), and every file's modification date is set to its capture time, so the
output is the same on every run. Needs Python 3, Pillow, and the `sips` command.
"""

import argparse
import datetime as dt
import multiprocessing
import os
import random
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageEnhance, ImageFilter

DESKTOP = "/System/Library/Desktop Pictures"
SOURCES = {
    "sonoma": f"{DESKTOP}/Sonoma.heic",  # 6016 x 6016
    "horizon": f"{DESKTOP}/.wallpapers/Sonoma Horizon/Sonoma Horizon.heic",  # 3840 x 2160
}
THUMBNAILS = f"{DESKTOP}/.thumbnails"
SUBFOLDER_PHOTOS = ["Big Sur Aerial", "Big Sur Coastline", "Big Sur Horizon"]

START = dt.datetime(2026, 11, 1, 10, 0, 0)
BLUR_RADII = [1.5, 3, 6]
QUALITY = 90
SCALED_QUALITY = 85


def convert_with_sips(source, destination, fmt):
    subprocess.run(
        ["sips", "-s", "format", fmt, source, "--out", destination],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def exif_for(time):
    """EXIF holding a capture time with hundredths of a second."""
    exif = Image.Exif()
    ifd = exif.get_ifd(0x8769)
    ifd[0x9003] = time.strftime("%Y:%m:%d %H:%M:%S")
    ifd[0x9291] = f"{time.microsecond // 10000:02d}"
    return exif


def set_file_time(path, time):
    stamp = time.timestamp()
    os.utime(path, (stamp, stamp))


def save(image, path, time, quality=QUALITY):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    image.save(path, "JPEG", quality=quality, exif=exif_for(time))
    set_file_time(path, time)


def copy(source, destination, time):
    shutil.copyfile(source, destination)
    set_file_time(destination, time)


def crop(image, x, y, width, height, size=None):
    piece = image.crop((x, y, x + width, y + height))
    if size and piece.size != size:
        piece = piece.resize(size, Image.Resampling.LANCZOS)
    return piece


def over_exposed(image):
    return ImageEnhance.Brightness(image).enhance(2.6)


def under_exposed(image):
    return ImageEnhance.Brightness(image).enhance(0.12)


# MARK: - The standard 35-photo shoot

# Crop origins for the five distinct photos of each source, chosen to show different parts.
STANDARD_CROPS = {
    "sonoma": [(0, 0), (3016, 0), (0, 2000), (3016, 2000), (1508, 4016)],
    "horizon": [(0, 0), (840, 0), (420, 80), (210, 160), (840, 160)],
}


def write_standard(sources, out):
    base_times = {"sonoma": START, "horizon": START + dt.timedelta(minutes=25)}
    for name, image in sources.items():
        t0 = base_times[name]
        crops = [crop(image, x, y, 3000, 2000) for x, y in STANDARD_CROPS[name]]
        for index, piece in enumerate(crops):
            save(piece, f"{out}/{name}_{index}.jpg", t0 + dt.timedelta(minutes=5 * index))

        # Variants of the first photo, each more than the stack gap apart, so they do not stack.
        for radius, seconds in zip(BLUR_RADII, [35, 50, 80]):
            blurred = crops[0].filter(ImageFilter.GaussianBlur(radius))
            save(blurred, f"{out}/{name}_0_blur{radius:g}.jpg", t0 + dt.timedelta(seconds=seconds))
        save(over_exposed(crops[0]), f"{out}/{name}_0_over.jpg", t0 + dt.timedelta(seconds=90))
        save(under_exposed(crops[0]), f"{out}/{name}_0_under.jpg", t0 + dt.timedelta(seconds=120))

        # A burst: four frames shifted a few pixels, 0.3 s apart.
        x, y = STANDARD_CROPS[name][2]
        burst_time = t0 + dt.timedelta(minutes=23, seconds=20)
        for frame in range(4):
            shift = 4 * frame
            piece = crop(image, max(0, x - shift), max(0, y - shift // 2), 3000, 2000)
            save(piece, f"{out}/{name}_burst{frame}.jpg", burst_time + dt.timedelta(seconds=0.3 * frame))

        # A near-duplicate: the last photo at half size, with the same capture time.
        small = crops[4].resize((1500, 1000), Image.Resampling.LANCZOS)
        save(small, f"{out}/{name}_4_small.jpg", t0 + dt.timedelta(minutes=20))

    # An exact copy, and a fake RAW twin of a JPEG.
    copy(f"{out}/sonoma_1.jpg", f"{out}/sonoma_1 copy.jpg", START + dt.timedelta(minutes=5))
    copy(f"{out}/horizon_2.jpg", f"{out}/horizon_2.dng", base_times["horizon"] + dt.timedelta(minutes=10))

    # Small real photos in a subfolder, converted without capture times.
    os.makedirs(f"{out}/sub", exist_ok=True)
    for index, name in enumerate(SUBFOLDER_PHOTOS):
        destination = f"{out}/sub/{name}.jpg"
        convert_with_sips(f"{THUMBNAILS}/{name}.heic", destination, "jpeg")
        set_file_time(destination, START + dt.timedelta(hours=2, minutes=index))

    # Files that are not photos Culla can read.
    with open(f"{out}/broken.jpg", "wb") as handle:
        handle.write(b"not an image")
    with open(f"{out}/clip.mov", "wb") as handle:
        handle.write(b"video")
    for path in (f"{out}/broken.jpg", f"{out}/clip.mov"):
        set_file_time(path, START + dt.timedelta(hours=3))
    return 35


# MARK: - Generated scenes for large shoots

SCENE_SIZE = (1500, 1000)
SCENE_START = START + dt.timedelta(days=1)
SCENE_SPACING = dt.timedelta(minutes=3)

_worker_sources = {}


def _init_worker(paths):
    for name, path in paths.items():
        _worker_sources[name] = Image.open(path).convert("RGB")


def scene_plan(index):
    """The files of one scene: (file name, kind, argument, seconds after the scene's time)."""
    files = [(f"IMG_{index:05d}.jpg", "base", None, 0)]
    if index % 4 == 1:
        files += [(f"IMG_{index:05d}_b{frame}.jpg", "burst", frame, 0.3 * frame) for frame in range(1, 4)]
    if index % 7 == 3:
        files.append((f"IMG_{index:05d}_blur.jpg", "blur", BLUR_RADII[(index // 7) % 3], 35))
    if index % 11 == 5:
        files.append((f"IMG_{index:05d}_small.jpg", "small", None, 0))
    if index % 13 == 7:
        files.append((f"IMG_{index:05d} copy.jpg", "copy", None, 0))
    if index % 17 == 9:
        files.append((f"IMG_{index:05d}_over.jpg", "over", None, 90))
    if index % 19 == 10:
        files.append((f"IMG_{index:05d}_under.jpg", "under", None, 120))
    return files


def write_scene(job):
    index, out = job
    rng = random.Random(index)
    name = "sonoma" if index % 2 == 0 else "horizon"
    image = _worker_sources[name]
    width = rng.randint(1500, min(3000, image.width))
    height = width * 2 // 3
    x = rng.randint(0, image.width - width - 16)
    y = rng.randint(0, image.height - height - 16)
    time = SCENE_START + SCENE_SPACING * index
    base = crop(image, x, y, width, height, SCENE_SIZE)
    base_path = f"{out}/IMG_{index:05d}.jpg"
    for file_name, kind, argument, seconds in scene_plan(index):
        path = f"{out}/{file_name}"
        when = time + dt.timedelta(seconds=seconds)
        if kind == "base":
            save(base, path, when, SCALED_QUALITY)
        elif kind == "burst":
            shift = 3 * argument
            save(crop(image, x + shift, y + shift, width, height, SCENE_SIZE), path, when, SCALED_QUALITY)
        elif kind == "blur":
            save(base.filter(ImageFilter.GaussianBlur(argument)), path, when, SCALED_QUALITY)
        elif kind == "small":
            save(base.resize((750, 500), Image.Resampling.LANCZOS), path, when, SCALED_QUALITY)
        elif kind == "copy":
            copy(base_path, path, when)
        elif kind == "over":
            save(over_exposed(base), path, when, SCALED_QUALITY)
        elif kind == "under":
            save(under_exposed(base), path, when, SCALED_QUALITY)
    return len(scene_plan(index))


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("output", help="folder to create; must not exist or be empty")
    parser.add_argument("--count", type=int, default=None, help="add generated scenes until about this many photos")
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 4, help="processes for --count (default: all cores)")
    args = parser.parse_args()

    out = os.path.abspath(args.output)
    if os.path.exists(out) and os.listdir(out):
        sys.exit(f"error: {out} exists and is not empty")
    os.makedirs(out, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="make_sample_shoot-") as temp:
        paths = {}
        for name, source in SOURCES.items():
            paths[name] = f"{temp}/{name}.png"
            convert_with_sips(source, paths[name], "png")
        sources = {name: Image.open(path).convert("RGB") for name, path in paths.items()}

        photos = write_standard(sources, out)
        # The .dng is a companion and the .mov is ignored, so they do not count as photos.
        if args.count and args.count > photos:
            jobs = []
            planned = photos
            index = 0
            while planned < args.count:
                # Exact copies and near-duplicates are photos of their own.
                planned += len(scene_plan(index))
                jobs.append((index, out))
                index += 1
            with multiprocessing.Pool(max(1, args.jobs), initializer=_init_worker, initargs=(paths,)) as pool:
                for done, _ in enumerate(pool.imap_unordered(write_scene, jobs, chunksize=8), start=1):
                    if done % 100 == 0 or done == len(jobs):
                        print(f"  {done} of {len(jobs)} scenes", file=sys.stderr)
            photos = planned

    print(f"Wrote about {photos} photos to {out}")


if __name__ == "__main__":
    main()
