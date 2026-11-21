#!/usr/bin/env python3
"""Lists text a translated run still shows in English.

Compares the outputs of two UI automation runs of the same screens, one in another language and
one in English (Scripts/ui/66-screens-ru.json or 67-screens-tk.json against 65-screens-en.json),
and prints every string the translated run shows exactly as the English run does: menu titles
(each dump's `mainMenu`), the accessibility trees (`a11y-*.json`: names, values, actions, window
titles) and the text in the state dumps (notices, banners, hint lines, button titles, Settings
lines). Strings that are the same in every language are left out: Culla, file and folder names,
numbers, key symbols and single letters, language names, numbers with a unit abbreviation that
stays Latin in Turkmen (MB, GB, MP), the few strings AppKit itself adds to windows and toolbars
(English in a Turkmen run, as macOS has no Turkmen), and anything in `--allow`.

Usage:
    Scripts/l10n-screens.py <translated run folder> <English run folder> [--allow <file>] [--json]

`--allow` names a file of further strings to leave out, one per line; a line starting with `re:`
is a regular expression matched against the whole string. With `--json` the result is a JSON
list of {"text", "where"}. Exit status 1 when anything is left in English, 0 otherwise.

The runs' folders are printed by `Scripts/ui-run.sh`, under
~/Library/Containers/com.kpirliyev.Culla/Data/tmp/CullaAutomation/runs/. Python 3 standard
library only.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# The same in every language.
ALWAYS_SAME = {
    "Culla", "English", "Русский", "Türkmençe", "CullaSampleShoot", "Empty", "XMP", "RAW", "JPEG", "HEIC",
    "DNG", "TIFF", "ISO", "MIT", "OK", "—", "·", "…",
}
# Text AppKit itself gives windows and toolbars (the zoom button's help, toolbar items' actions).
# macOS is not translated into Turkmen, so a Turkmen run shows it in English; it is not Culla's.
SYSTEM_TEXT = {
    "this button also has an action to zoom the window", "Move next", "Move previous", "Remove from toolbar",
}
# A number with a unit abbreviation that stays Latin in Turkmen: "1,7 MB", "5 GB", "6,0 MP".
NUMBER_WITH_UNIT = re.compile(r"^[<≈~]?[\d.,\u00a0\u202f ]+ ?(B|kB|KB|MB|GB|TB|MP)$")
FILE_NAME = re.compile(r".*\.(jpe?g|heic|heif|dng|cr2|cr3|nef|arw|raf|orf|rw2|png|tiff?|mov|xmp|sqlite)$", re.IGNORECASE)
# Key names and chords: "P", "⇧⌘Z", "F1", "⌥⌘I".
KEY = re.compile(r"^[⌃⌥⇧⌘]*([A-Z0-9]|F\d{1,2}|[←→↑↓↩⎋⇥⌫⌦↖↘⇞⇟,.\[\]+\-=/;'`\\])$")
# Identifiers in dumps: camelCase names, dotted keys, enum values, paths, dates, hashes, versions.
IDENTIFIER = re.compile(r"^([a-z][A-Za-z0-9]*|[a-z][A-Za-z0-9]*(\.[A-Za-z0-9_]+)+|[A-Z]{2}[A-Za-z]+(\.[A-Za-z]+)*)$")
PATH = re.compile(r"(^/|^~|/.+/|^file:)")
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}")
CAMERA_LIKE = re.compile(r"^(ƒ/|ISO )")
# Dump fields that hold identifiers, file names or developer text, not interface text.
SKIPPED_KEYS = {
    "id", "ids", "photo", "photos", "members", "pick", "current", "focus", "selection", "gridOrder", "groupMembers",
    "role", "subrole", "window", "path", "url", "folder", "log", "error", "stall", "slowSections", "keyMap",
    "menuKeys", "key", "tuning", "tuningDefault", "preferredLocalizations", "localizations", "running",
    "launchChoice", "rawValue", "kind", "state", "action", "screen", "viewMode", "group", "pane",
    "lastFileAction", "listing", "measurements", "loopSteps", "openTimings", "power", "memory",
    # Developer fields of the dump, and sidecar values written to disk in English on purpose.
    "summaryLine", "concurrencyReason", "keptLabel", "rejectedLabel",
}


def strings_in(node, where: str, out: list[tuple[str, str]], parent_key: str = "") -> None:
    if isinstance(node, dict):
        for key, value in node.items():
            if key in SKIPPED_KEYS and parent_key not in ("mainMenu",):
                continue
            strings_in(value, f"{where}.{key}", out, key)
    elif isinstance(node, list):
        for index, value in enumerate(node):
            strings_in(value, f"{where}[{index}]", out, parent_key)
    elif isinstance(node, str):
        out.append((node, where))


def menu_strings(items, where: str, out: list[tuple[str, str]]) -> None:
    for item in items or []:
        title = item.get("title", "")
        here = f"{where} ▸ {title}"
        out.append((title, here))
        menu_strings(item.get("items"), here, out)


def accessibility_strings(data: dict, name: str, out: list[tuple[str, str]]) -> None:
    out.append((data.get("title", ""), f"{name}: window title"))
    for node in data.get("tree", []):
        role = node.get("role", "")
        for field in ("name", "value", "help", "roleDescription"):
            value = node.get(field)
            if isinstance(value, str):
                out.append((value, f"{name}: {role} {field}"))
        for action in node.get("actions", []):
            if action not in ("press", "increment", "decrement", "showMenu", "cancel", "confirm", "pick", "raise", "scrollToVisible", "showAlternateUI", "showDefaultUI"):
                out.append((action, f"{name}: {role} action"))


def collect(run: Path) -> list[tuple[str, str]]:
    found: list[tuple[str, str]] = []
    for path in sorted(run.glob("*.json")):
        if path.name == "result.json":
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if path.name.startswith("a11y-"):
            accessibility_strings(data, path.name, found)
            continue
        if not isinstance(data, dict):
            continue
        menu_strings(data.get("mainMenu"), f"{path.name}: menu", found)
        rest = {key: value for key, value in data.items() if key != "mainMenu"}
        strings_in(rest, path.name, found)
    return found


def read_allow(path: str | None) -> tuple[set[str], list[re.Pattern]]:
    exact: set[str] = set()
    patterns: list[re.Pattern] = []
    if not path:
        return exact, patterns
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        line = line.rstrip("\n")
        if not line.strip() or line.startswith("#"):
            continue
        if line.startswith("re:"):
            patterns.append(re.compile(line[3:]))
        else:
            exact.add(line)
    return exact, patterns


def same_everywhere(text: str, allow: set[str], patterns: list[re.Pattern]) -> bool:
    text = text.strip()
    if not text or text in ALWAYS_SAME or text in SYSTEM_TEXT or text in allow or NUMBER_WITH_UNIT.match(text):
        return True
    if any(pattern.fullmatch(text) for pattern in patterns):
        return True
    if not any(character.isalpha() for character in text) or KEY.match(text) or FILE_NAME.match(text) or PATH.search(text):
        return True
    if IDENTIFIER.match(text) or DATE.match(text) or CAMERA_LIKE.match(text):
        return True
    # A list of file names or keys joined by separators: "a.jpg, b.jpg", "P or X".
    parts = [part for part in re.split(r"\s*[,·|]\s*", text) if part]
    if len(parts) > 1 and all(same_everywhere(part, allow, patterns) for part in parts):
        return True
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description="Lists text a translated run still shows in English.")
    parser.add_argument("translated", type=Path, help="the run folder in Russian or Turkmen")
    parser.add_argument("english", type=Path, help="the run folder of the same screens in English")
    parser.add_argument("--allow", help="a file of further strings (or re: patterns) that stay the same")
    parser.add_argument("--json", action="store_true", help="print JSON instead of a table")
    arguments = parser.parse_args()
    for folder in (arguments.translated, arguments.english):
        if not folder.is_dir():
            print(f"No such run folder: {folder}", file=sys.stderr)
            return 2
    allow, patterns = read_allow(arguments.allow)
    english = {text.strip() for text, _ in collect(arguments.english)}
    left: dict[str, list[str]] = {}
    for text, where in collect(arguments.translated):
        text = text.strip()
        if text in english and not same_everywhere(text, allow, patterns):
            left.setdefault(text, [])
            if where not in left[text]:
                left[text].append(where)
    if arguments.json:
        print(json.dumps([{"text": text, "where": wheres} for text, wheres in sorted(left.items())], ensure_ascii=False, indent=2))
    else:
        for text, wheres in sorted(left.items(), key=lambda item: item[0].lower()):
            shown = wheres[:3] + ([f"and {len(wheres) - 3} more"] if len(wheres) > 3 else [])
            print(f"{json.dumps(text, ensure_ascii=False)}\n    {'; '.join(shown)}")
        print(f"{len(left)} string(s) the same as in English", file=sys.stderr)
    return 1 if left else 0


if __name__ == "__main__":
    sys.exit(main())
