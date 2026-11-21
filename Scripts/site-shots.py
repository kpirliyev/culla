#!/usr/bin/env python3
"""Makes the landing page's screenshots from the app. Run by Scripts/site-shots.sh.

  site-shots.py stage <shoot folder> <staging folder> <names.json>
      Copies the shoot's finished image files (never .part or hidden files) to the staging
      folder as IMG_4101.jpg upward, in capture-time order, and writes the old name of each new
      one to names.json. Prints how many it copied; fails when there are none.

  site-shots.py probe <stack gap> <out.json>
      Writes the probe script: open the shoot, set the stack time gap, analyse, dump.

  site-shots.py script <probe.json> <language> <out.json> <stack gap> <names.json> [<evidence photo>]
      Writes the capture script for one language. What each slot shows is chosen from the probe
      dump (what Culla found in the shoot), never by file name: the stack with the most frames,
      a photo flagged for closed eyes, and so on. Prints what it chose, and a warning for a slot
      that has to fall back because the shoot has nothing to show for it. <evidence photo>, an
      original file name, picks the Eyes Closed photo for vision-evidence by hand (when Culla flags a
      photo whose eyes are in fact open).

  site-shots.py finish <run folder> <language> <shots folder>
      Crops and scales the run's snapshots to the slots' sizes and writes
      <shots folder>/<slot>.<language>.png.

Python standard library only; cropping and scaling use site-shots/crop.swift.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

# Every snapshot is taken at 2 pixels per point, whatever screen the window is on.
SCALE = 2

# Per slot: the window in points, the part of it to keep (x, y, width, height in points from the
# top left; None for the whole window), and the PNG's size in pixels: twice the largest size
# ShotSlot.vue shows the slot at, so it is sharp on Retina screens. Each crop has the slot's
# proportions (16:10, 4:3, 3:2).
SLOTS = {
    "how-1-open":        {"window": [1024, 640], "crop": [0, 0, 720, 540], "size": [800, 600]},
    "how-2-groups":      {"window": [1024, 640], "crop": [0, 0, 640, 480], "size": [800, 600]},
    "hero-stack-review": {"window": [1152, 720], "crop": None, "size": [1280, 800]},
    "vision-evidence":   {"window": [960, 640], "crop": None, "size": [1200, 800]},
    "how-3-decide":      {"window": [960, 720], "crop": None, "size": [800, 600]},
}


# What was chosen is said once, for the first language; the others choose the same.
SAY = True


def warn(text):
    if SAY:
        print(f"site-shots: warning: {text}", file=sys.stderr)


def note(text):
    if SAY:
        print(f"site-shots: {text}", file=sys.stderr)


def resize(slot):
    width, height = SLOTS[slot]["window"]
    return [{"windowSize": [width, height]}, {"sleep": 0.3}, {"wait": "idle", "timeout": 60}]


def snapshot(slot):
    return [{"wait": "idle", "timeout": 60}, {"sleep": 0.5},
            {"snapshot": slot, "scale": SCALE}, {"dump": slot, "photos": False}]


def main_faces(photos, ids):
    return sum(len(photos.get(i, {}).get("mainFaces") or []) for i in ids)


def rank_stacks(probe):
    """Stacks by how well they show stack review: at least three frames, then the most frames
    with a face (so the face strip is full), the most faces, more frames; the earlier stack on
    a tie."""
    photos = {p["id"]: p for p in probe.get("photos") or []}
    stacks = probe.get("stacks") or []

    def with_faces(i):
        return sum(1 for m in stacks[i]["members"] if photos.get(m, {}).get("mainFaces"))

    ranked = sorted(
        range(len(stacks)),
        key=lambda i: (len(stacks[i]["members"]) >= 3, with_faces(i), main_faces(photos, stacks[i]["members"]),
                       len(stacks[i]["members"]), -i),
        reverse=True,
    )
    return [(i, stacks[i]) for i in ranked]


def open_stack(index, stack):
    """Stack review on the stack at `index` of the dump's stacks (nothing decided yet: stack review
    opens on the first stack, and each down arrow skips to the next)."""
    steps = [{"group": "allPhotos"}, {"wait": "idle", "timeout": 60},
             {"group": "similarStacks"}, {"wait": "idle", "timeout": 60}]
    for _ in range(index):
        steps += [{"key": "down"}, {"wait": "idle", "timeout": 60}]
    steps.append({"expect": {"viewMode": "stackReview", "stackReview.stackIndex": index}})
    return steps


def show_frame(frame):
    """Makes a frame of the open stack the current one (the left pane)."""
    return [{"click": frame, "in": "stack"}, {"wait": "idle", "timeout": 60},
            {"expect": {"stackReview.current": frame}}]


def others(stack):
    return [f for f in stack["members"] if f != stack.get("bestPick")]


IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".tif", ".tiff",
                    ".dng", ".cr2", ".cr3", ".nef", ".arw", ".raf", ".orf", ".rw2"}


def capture_time(path):
    """The capture time from the file's metadata, as sips reads it ("2017:06:01 12:00:00"), or
    an empty string."""
    result = subprocess.run(["sips", "-g", "creation", path], capture_output=True, text=True)
    for line in result.stdout.splitlines():
        if line.strip().startswith("creation:"):
            return line.split(":", 1)[1].strip()
    return ""


def stage(shoot, staging, names_file):
    files = sorted(
        name for name in os.listdir(shoot)
        if not name.startswith(".") and os.path.splitext(name)[1].lower() in IMAGE_EXTENSIONS
        and os.path.isfile(os.path.join(shoot, name))
    )
    if not files:
        raise SystemExit(f"No finished photos in {shoot} (files still downloading end in .part)")
    os.makedirs(staging, exist_ok=True)
    for old in os.listdir(staging):
        os.remove(os.path.join(staging, old))
    # Photos without a capture time go last, by name.
    timed = sorted(files, key=lambda name: (capture_time(os.path.join(shoot, name)) or "9999", name))
    names = {}
    for number, original in enumerate(timed, start=4101):
        new = f"IMG_{number}{os.path.splitext(original)[1].lower()}"
        shutil.copy2(os.path.join(shoot, original), os.path.join(staging, new))
        names[new] = original
    with open(names_file, "w") as file:
        json.dump(names, file, indent=1, ensure_ascii=False)
    print(len(files))


def set_stack_gap(gap):
    """The stack time gap as the open shoot's own tuning, as the tuning panel sets it; the default
    tuning and every other value are left alone."""
    return [{"tuning": {"stackGapSeconds": gap}}, {"expect": {"tuning.stackGapSeconds": gap}}]


def build_probe(gap):
    return {
        "timeout": 900,
        "window": [1120, 700],
        "steps": [
            {"log": "Written by Scripts/site-shots.py: analyses the shoot once and dumps what Culla found (stacks, groups, flags, faces), so the capture can choose what each screenshot shows by state."},
            {"open": "$SHOOT"},
            *set_stack_gap(gap),
            {"wait": "analysis", "timeout": 840},
            {"wait": "grouping", "timeout": 120},
            {"dump": "probe"},
            {"quit": True},
        ],
    }


def build_script(probe, language, gap, names, evidence=None):
    global SAY
    SAY = language == "en"
    photos = {p["id"]: p for p in probe.get("photos") or []}
    members = probe.get("groupMembers") or {}
    steps = [
        {"log": "Written by Scripts/site-shots.py: the landing page's screenshots, chosen by what Culla found in the shoot."},
        *resize("how-1-open"),
        {"open": "$SHOOT"},
        *snapshot("how-1-open"),
        *set_stack_gap(gap),
        {"wait": "analysis", "timeout": 840},
        {"wait": "grouping", "timeout": 120},
        {"group": "allPhotos"},
        *resize("how-2-groups"),
        *snapshot("how-2-groups"),
    ]

    ranked = rank_stacks(probe)
    # The hero: stack review of the best stack.
    steps += resize("hero-stack-review")
    if ranked:
        index, stack = ranked[0]
        note(f"hero-stack-review: stack {index + 1} of {len(ranked)}, {len(stack['members'])} frames, "
             f"{main_faces(photos, stack['members'])} main faces")
        if len(stack["members"]) < 3:
            warn("hero-stack-review: no stack has three frames or more")
        steps += open_stack(index, stack)
        # A frame other than the best pick in front, so the two panes differ.
        if others(stack):
            steps += show_frame(others(stack)[0])
    else:
        warn("hero-stack-review: Culla found no stacks; the slot shows the grid instead")
        steps += [{"group": "allPhotos"}]
    steps += snapshot("hero-stack-review")

    # Evidence: the loupe on a photo flagged for closed eyes, zoomed to the face.
    steps += [{"group": "allPhotos"}, {"wait": "idle", "timeout": 60}]
    steps += resize("vision-evidence")
    closed = members.get("eyesClosed") or []
    blurry = members.get("blurry") or []
    if closed:
        chosen = sorted(closed, key=lambda i: (photos.get(i, {}).get("tiers", {}).get("eyesClosed") == "certain",
                                               len(photos.get(i, {}).get("mainFaces") or []),
                                               -closed.index(i)), reverse=True)[0]
        if evidence:
            evidence = next((new for new, old in names.items() if old == evidence), evidence)
        if evidence and evidence in closed:
            chosen = evidence
        elif evidence:
            warn(f"vision-evidence: {evidence} is not in Eyes Closed; choosing by state instead")
        note(f"vision-evidence: Eyes Closed, photo {closed.index(chosen) + 1} of {len(closed)} ({chosen}, was {names.get(chosen, chosen)})")
        steps += [{"group": "eyesClosed"}, {"wait": "idle", "timeout": 60}]
        if chosen != closed[0]:
            steps += [{"click": chosen, "in": "filmstrip"}, {"wait": "idle", "timeout": 60}]
        steps.append({"expect": {"viewMode": "loupe", "focus": chosen}})
    elif blurry:
        warn("vision-evidence: no photo is flagged for closed eyes; the slot shows Blurry instead")
        steps += [{"group": "blurry"}, {"wait": "idle", "timeout": 60}, {"expect": {"viewMode": "loupe"}}]
    else:
        faces = [i for i in members.get("unreviewed") or [] if photos.get(i, {}).get("mainFaces")]
        warn("vision-evidence: no photo is flagged for closed eyes or blur; the slot shows face boxes instead")
        steps += [{"group": "unreviewed"}, {"wait": "idle", "timeout": 60}]
        if faces:
            chosen = max(faces, key=lambda i: len(photos[i]["mainFaces"]))
            steps += [{"click": chosen, "in": "filmstrip"}, {"wait": "idle", "timeout": 60}]
        steps += [{"command": "toggleFaceBoxes", "allowUnavailable": True}]
    steps += snapshot("vision-evidence")

    # Deciding: P and X on frames of another stack (the same one when there is only one).
    steps += resize("how-3-decide")
    if ranked:
        index, stack = ranked[1] if len(ranked) > 1 else ranked[0]
        frames = stack["members"]
        note(f"how-3-decide: stack {index + 1} of {len(ranked)}, {len(frames)} frames, "
             f"{main_faces(photos, frames)} main faces")
        steps += [{"group": "allPhotos"}, {"wait": "idle", "timeout": 60},
                  {"group": "similarStacks"}, {"wait": "idle", "timeout": 60}]
        for _ in range(index):
            steps += [{"key": "down"}, {"wait": "idle", "timeout": 60}]
        steps.append({"expect": {"viewMode": "stackReview", "stackReview.stackIndex": index}})
        # The best pick kept and every other frame but one rejected, so the stack stays open
        # with frames of each kind; the undecided frame in front, the kept pick beside it.
        rest = others(stack)
        if stack.get("bestPick"):
            steps += show_frame(stack["bestPick"]) + [{"key": "p"}]
        for frame in rest[:-1]:
            steps += show_frame(frame) + [{"key": "x"}]
        if rest:
            steps += show_frame(rest[-1])
        steps += [{"wait": "idle", "timeout": 60},
                  {"expect": {"viewMode": "stackReview", "stackReview.stackIndex": index}}]
    else:
        warn("how-3-decide: Culla found no stacks; the slot shows the loupe instead")
        steps += [{"group": "allPhotos"}, {"wait": "idle", "timeout": 60}, {"key": "space"},
                  {"wait": "idle", "timeout": 60}, {"key": "p"}, {"key": "x"}, {"key": "p"}]
    steps += snapshot("how-3-decide")
    steps.append({"quit": True})

    return {
        "needs": {"reset": True},
        "language": language,
        "timeout": 1200,
        "window": SLOTS["how-1-open"]["window"],
        "steps": steps,
    }


def finish(run, language, shots):
    os.makedirs(shots, exist_ok=True)
    with tempfile.TemporaryDirectory() as scratch:
        tool = os.path.join(scratch, "crop")
        here = os.path.dirname(os.path.abspath(__file__))
        result = subprocess.run(["xcrun", "swiftc", "-O", os.path.join(here, "site-shots", "crop.swift"), "-o", tool],
                                capture_output=True, text=True)
        if result.returncode != 0:
            raise SystemExit(f"site-shots: cannot build crop.swift: {result.stderr.strip()}")
        for slot, spec in SLOTS.items():
            source = os.path.join(run, f"{slot}.png")
            if not os.path.exists(source):
                raise SystemExit(f"site-shots: the run made no {slot}.png ({run})")
            target = os.path.join(shots, f"{slot}.{language}.png")
            if os.path.exists(target):
                os.remove(target)
            crop = spec["crop"] or [0, 0, *spec["window"]]
            pixels = [str(round(v * SCALE)) for v in crop]
            result = subprocess.run([tool, source, target, *pixels, *map(str, spec["size"])], capture_output=True, text=True)
            if result.returncode != 0 or not os.path.exists(target):
                raise SystemExit(f"site-shots: cannot write {target}: {result.stderr.strip()}")
            print(target)


def main(argv):
    if len(argv) == 5 and argv[1] == "stage":
        stage(argv[2], argv[3], argv[4])
    elif len(argv) == 4 and argv[1] == "probe":
        with open(argv[3], "w") as file:
            json.dump(build_probe(float(argv[2])), file, indent=1)
    elif len(argv) in (7, 8) and argv[1] == "script":
        with open(argv[2]) as file:
            probe = json.load(file)
        with open(argv[6]) as file:
            names = json.load(file)
        script = build_script(probe, argv[3], float(argv[5]), names, argv[7] if len(argv) == 8 else None)
        with open(argv[4], "w") as file:
            json.dump(script, file, indent=1, ensure_ascii=False)
    elif len(argv) == 5 and argv[1] == "finish":
        finish(argv[2], argv[3], argv[4])
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
