#!/usr/bin/env python3
"""Checks the SwiftUI views under Culla/ for controls VoiceOver could not name.

The automation harness reads the accessibility tree of the AppKit side of the app (windows,
toolbars, tiles, filmstrips, the face strip). SwiftUI builds its elements only for a connected
assistive app, so its views are checked here, in the source:

- a Button whose label is only an Image must carry .accessibilityLabel;
- a view that acts on .onTapGesture must also say it is a button (.accessibilityAddTraits(.isButton))
  or offer .accessibilityAction, and should rather be a Button;
- an Image(systemName:) that stands alone as a control's label must be named.

Usage: Scripts/check-accessibility.py [Culla]   Exit status 1 when something is found.
"""
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parent.parent / "Culla")
problems = []

for path in sorted(root.rglob("*.swift")):
    if "Automation" in path.parts:
        continue
    lines = path.read_text().splitlines()
    for number, line in enumerate(lines):
        window = "\n".join(lines[number:number + 12])
        # Button { ... } label: { Image(systemName: ...) } with nothing else in the label.
        if re.search(r"\bButton\s*\{", line) or re.search(r"\bButton\s*\(action:", line):
            label = re.search(r"label:\s*\{\s*\n?\s*Image\(systemName:[^)]*\)\s*\n?\s*\}", window)
            if label and ".accessibilityLabel" not in window:
                problems.append(f"{path.relative_to(root.parent)}:{number + 1}: an icon-only Button without .accessibilityLabel")
        if ".onTapGesture" in line:
            nearby = "\n".join(lines[max(0, number - 8):number + 14])
            if ".isButton" not in nearby and ".accessibilityAction" not in nearby and ".accessibilityHidden(true)" not in nearby:
                problems.append(f"{path.relative_to(root.parent)}:{number + 1}: .onTapGesture without a button trait or an accessibility action")

for problem in problems:
    print(problem)
print(f"{len(problems)} accessibility problem(s) in the SwiftUI sources" if problems else "SwiftUI sources: no unnamed controls found")
sys.exit(1 if problems else 0)
