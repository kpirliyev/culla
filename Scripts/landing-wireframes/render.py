#!/usr/bin/env python3
"""Draw the landing-page wireframes into docs/images/ with headless Chrome.

Each HTML file is first loaded once to measure the sheet (its full size and
where the hero's buttons and version line end), then captured at 2x.
Fails if a hero button or version line ends below its fold, or if any box's
content is wider than the box.
"""
import html
import json
import pathlib
import re
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
IMAGES = HERE.parent.parent / "docs" / "images"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PAGES = ["landing-desktop", "landing-mobile", "landing-hero-ru"]


def chrome(profile, *args):
    cmd = [CHROME, "--headless", f"--user-data-dir={profile}", "--hide-scrollbars",
           "--no-first-run", "--no-default-browser-check", "--disable-extensions",
           "--disable-background-networking", "--disable-component-update",
           "--disable-sync", *args]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=120)


def main():
    ok = True
    with tempfile.TemporaryDirectory() as profile:
        for name in PAGES:
            url = (HERE / f"{name}.html").as_uri()
            dom = chrome(profile, "--window-size=2600,1200", "--virtual-time-budget=3000",
                         "--dump-dom", url).stdout
            m = re.search(r'id="metrics">(.*?)</script>', dom, re.S)
            if not m or not m.group(1).strip():
                sys.exit(f"{name}: could not measure the page")
            metrics = json.loads(html.unescape(m.group(1)))
            w, h = metrics["width"], metrics["height"]

            out = IMAGES / f"{name}.png"
            chrome(profile, f"--window-size={w},{h}", "--force-device-scale-factor=2",
                   "--virtual-time-budget=3000", f"--screenshot={out}", url)
            print(f"{out.relative_to(HERE.parent.parent)}: {w} x {h} CSS px, {2 * w} x {2 * h} image px")

            for frame in metrics["frames"]:
                for c in frame["checks"]:
                    above = c["bottom"] <= frame["fold"]
                    ok &= above
                    print(f"  {frame['name']}: {c['what']} ends at y = {c['bottom']}, fold at {frame['fold']}"
                          f" -> {'above' if above else 'BELOW THE FOLD'}")
            for o in metrics["overflow"]:
                ok = False
                print(f"  overflow: {o}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
