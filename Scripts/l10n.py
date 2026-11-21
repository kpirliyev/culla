#!/usr/bin/env python3
"""Checks, exports and imports the translations in Culla's string catalogs.

Works on every `*.xcstrings` file in the repository (the package's targets and the app). Python 3
standard library only. See docs/localization.md for what is translated and the glossary.

Commands
--------

    Scripts/l10n.py check [--require ru,tk]
    Scripts/l10n.py stats
    Scripts/l10n.py export <lang> --out <file.json> [--missing-only]
    Scripts/l10n.py import <lang> <file.json>
    Scripts/l10n.py clean [--dry-run]

`check` fails (exit status 1) on:
  - an entry without a comment for the translator;
  - a translation whose format specifiers differ from the English (their number, their types, or
    their order unless they are positional such as %1$@);
  - a plural entry missing a category the language needs (en: one, other; ru: one, few, many,
    other; tk: one, other), or having one the language does not use;
  - a stale entry: one Xcode marked stale, or a hand-written (`manual`) entry whose key no Swift
    file next to the catalog uses any more;
  - a key written twice in one catalog.
Missing translations are only counted, unless `--require` names the languages that must be
complete: then every entry missing or not marked translated in them is an error. Catalogs under a
Tests folder are test data: they are checked, but left out of the counts, `stats` and `export`.

`stats` prints, per catalog and language, how many entries there are, how many are translated
and how many are missing.

`clean` undoes what an Xcode build in the IDE may do to the catalogs: Xcode's string extraction
adds entries for literals it finds (a key of its own such as "hint.pick" appears again under its
English default, "pick") with no comment, and marks entries it no longer finds as stale. Every one
of Culla's entries is written by hand (`manual`) with a comment, so `clean` removes each entry
that is neither, turns a stale mark on an entry the Swift code still uses back into `manual`, and
lists stale entries nothing uses. It writes a catalog only when something changed (`--dry-run`
writes nothing). The app target has extraction turned off (`SWIFT_EMIT_LOC_STRINGS = NO`);
Swift packages have no such setting, so run `clean` after building in Xcode (`check` fails on
entries without a comment, which is how they are noticed).

`export` writes what a translator needs; `import` merges the filled-in file back, marks those
entries translated, checks the result as `check` does, and writes nothing if anything is wrong
(including a key or catalog the repository does not have). Catalogs are written with sorted keys
and the formatting Xcode uses, so diffs stay small.

The translator's file
---------------------

`export ru --out ru.json` writes:

    {
      "language": "ru",
      "pluralCategories": ["one", "few", "many", "other"],
      "catalogs": {
        "CullaKit/Sources/CullaCommands/Localizable.xcstrings": [
          {
            "key": "Reject %lld photos?",
            "comment": "Where it appears and what each placeholder is.",
            "english": "Reject %lld photos?",
            "translation": null
          }
        ]
      }
    }

Fill in "translation" and leave everything else as it is. Its shape follows "english":

  - a string: the translation as a string. Keep every placeholder (%@, %lld, %1$@ ...). With
    numbered placeholders (%1$@, %2$lld) the order may change; without numbers it may not.
  - plural forms, such as {"one": "%lld photo", "other": "%lld photos"}: an object with one string
    for each name in "pluralCategories" (Russian: one, few, many, other; Turkmen: one, other).
    Each form keeps the placeholders.
  - a sentence with plural parts, {"value": "Stack %1$lld of %2$lld · %#@frames@",
    "substitutions": {"frames": {"one": "%arg frame", "other": "%arg frames"}}}: the same object
    translated. "value" keeps every placeholder including %#@frames@; each substitution has one
    string for each plural category, where %arg is the number.

Leave "translation" as null (or an empty string) for an entry you have not translated; it stays
untranslated. Unknown keys or catalogs make the whole import fail, so a file made from an older
export can be re-exported and merged by hand.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE_LANGUAGE = "en"
LANGUAGES = ["en", "ru", "tk"]
PLURAL_CATEGORIES = {
    "en": ["one", "other"],
    "ru": ["one", "few", "many", "other"],
    "tk": ["one", "other"],
}
# A category any language may add for the number 0 ("No photos").
OPTIONAL_CATEGORIES = {"zero"}
SKIPPED_DIRECTORIES = {".build", ".git", ".swiftpm", "DerivedData", "build", "culla-eval-output", "node_modules"}

# printf-style specifiers as Foundation reads them; %% is a literal percent sign. The space and
# apostrophe flags are left out on purpose: a key without arguments keeps a lone % as it is
# ("Zoom to 100% or Fit"), and "% o" there is text, not an octal number.
SPECIFIER = re.compile(
    r"%(?:%|#@(?P<sub>[A-Za-z0-9_]+)@|(?P<pos>\d+\$)?[-+#0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?"
    r"(?P<len>hh|h|ll|l|q|L|z|t|j)?(?P<conv>[@dDiuUxXoOfFeEgGaAcCsSp])|(?P<arg>arg))"
)


class CatalogError(Exception):
    pass


# MARK: - Reading and writing catalogs


def find_catalogs() -> list[Path]:
    found = []
    for directory, subdirectories, files in os.walk(ROOT):
        subdirectories[:] = sorted(d for d in subdirectories if d not in SKIPPED_DIRECTORIES and not d.startswith("."))
        for name in sorted(files):
            if name.endswith(".xcstrings"):
                found.append(Path(directory) / name)
    return found


def is_fixture(path: Path) -> bool:
    """True for a catalog of test data (under a Tests folder): checked, but never shipped, so it is
    left out of translation counts, `--require`, `stats` and `export`."""
    return "Tests" in path.resolve().relative_to(ROOT).parts


def relative(path: Path) -> str:
    return path.resolve().relative_to(ROOT).as_posix()


def load(path: Path) -> tuple[dict, list[str]]:
    """The catalog and the keys written more than once in it."""
    duplicates: list[str] = []

    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                duplicates.append(key)
            result[key] = value
        return result

    with open(path, encoding="utf-8") as file:
        data = json.load(file, object_pairs_hook=pairs)
    if data.get("sourceLanguage") != SOURCE_LANGUAGE:
        raise CatalogError(f"{relative(path)}: the source language is {data.get('sourceLanguage')!r}, not {SOURCE_LANGUAGE!r}")
    return data, duplicates


def dumps(data: dict) -> str:
    """The catalog as Xcode writes it: two-space indent, " : " between key and value, sorted keys."""
    return json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : ")) + "\n"


def save(path: Path, data: dict) -> None:
    text = dumps(data)
    with open(path, "w", encoding="utf-8") as file:
        file.write(text)


# MARK: - Entries


def unit(value: str, state: str = "translated") -> dict:
    return {"stringUnit": {"state": state, "value": value}}


def shape(localization: dict | None, key: str):
    """A localization in the translator's shape: a string, {category: string}, or
    {"value": ..., "substitutions": {name: {category: string}}}. None when it has no text."""
    if localization is None:
        return None
    plural = localization.get("variations", {}).get("plural")
    if plural is not None:
        return {category: form.get("stringUnit", {}).get("value", "") for category, form in plural.items()}
    value = localization.get("stringUnit", {}).get("value")
    substitutions = localization.get("substitutions")
    if substitutions:
        return {
            "value": value if value is not None else key,
            "substitutions": {
                name: {
                    category: form.get("stringUnit", {}).get("value", "")
                    for category, form in substitution.get("variations", {}).get("plural", {}).items()
                }
                for name, substitution in substitutions.items()
            },
        }
    return value


def english(key: str, entry: dict):
    """The English text of an entry: its en localization, or the key itself."""
    found = shape(entry.get("localizations", {}).get(SOURCE_LANGUAGE), key)
    return key if found is None else found


def states(localization: dict) -> list[str]:
    """The state of every piece of text in a localization."""
    found = []

    def walk(node):
        if isinstance(node, dict):
            if "stringUnit" in node:
                found.append(node["stringUnit"].get("state", "new"))
            for name, value in node.items():
                if name != "stringUnit":
                    walk(value)

    walk(localization)
    return found


def is_translated(entry: dict, language: str) -> bool:
    localization = entry.get("localizations", {}).get(language)
    if localization is None:
        return False
    found = states(localization)
    return bool(found) and all(state == "translated" for state in found)


def needs_translation(entry: dict) -> bool:
    return entry.get("shouldTranslate", True) is not False


# MARK: - Format specifiers


def specifiers(text: str, substitutions: dict | None = None, arg: tuple[int, str] | None = None) -> list[tuple[str, str]]:
    """The arguments a string uses, as (position or "", type). `substitutions` maps a %#@name@
    token to its (argNum, formatSpecifier); `arg` is what %arg stands for inside one."""
    result = []
    for match in SPECIFIER.finditer(text):
        if match.group(0) == "%%":
            continue
        if match.group("sub"):
            name = match.group("sub")
            if substitutions is None or name not in substitutions:
                result.append(("?", f"unknown substitution {name}"))
            else:
                number, specifier = substitutions[name]
                result.append((str(number), kind(specifier)))
        elif match.group("arg"):
            if arg is None:
                result.append(("?", "%arg outside a substitution"))
            else:
                result.append((str(arg[0]), kind(arg[1])))
        else:
            position = (match.group("pos") or "").rstrip("$")
            result.append((position, kind((match.group("len") or "") + match.group("conv"))))
    return result


def kind(specifier: str) -> str:
    conversion = specifier[-1:]
    if conversion in "dDi":
        return "integer"
    if conversion in "uUxXoO":
        return "unsigned integer"
    if conversion in "fFeEgGaA":
        return "floating point"
    if conversion == "@":
        return "object"
    if conversion in "sS":
        return "C string"
    if conversion in "cC":
        return "character"
    if conversion == "p":
        return "pointer"
    return specifier


def signature(found: list[tuple[str, str]]) -> tuple[bool, object]:
    """Arguments in a comparable form: positional ones by position, others in order."""
    if any(position for position, _ in found):
        mapping = {}
        next_position = 1
        for position, type_ in found:
            number = int(position) if position.isdigit() else next_position
            next_position = number + 1
            mapping.setdefault(number, set()).add(type_)
        return True, mapping
    return False, [type_ for _, type_ in found]


def same_arguments(source: list[tuple[str, str]], target: list[tuple[str, str]]) -> bool:
    """True when two strings take the same arguments: the same types at the same positions."""
    source_positional, source_signature = signature(source)
    target_positional, target_signature = signature(target)
    if source_positional or target_positional:
        def as_mapping(positional, value):
            if positional:
                return value
            return {index + 1: {type_} for index, type_ in enumerate(value)}

        return as_mapping(source_positional, source_signature) == as_mapping(target_positional, target_signature)
    return source_signature == target_signature


def describe(found: list[tuple[str, str]]) -> str:
    if not found:
        return "no placeholders"
    return ", ".join(f"{'%' + position + '$' if position else ''}{type_}" for position, type_ in found)


# MARK: - Checking


def localization_problems(key: str, entry: dict, language: str) -> list[str]:
    """What is wrong with one language of one entry."""
    problems = []
    localizations = entry.get("localizations", {})
    localization = localizations.get(language)
    source_localization = localizations.get(SOURCE_LANGUAGE)
    if localization is None:
        return problems
    required = PLURAL_CATEGORIES.get(language)
    allowed = set(required or []) | OPTIONAL_CATEGORIES

    def check_categories(where: str, categories) -> None:
        if required is None:
            return
        missing = [category for category in required if category not in categories]
        extra = sorted(set(categories) - allowed)
        if missing:
            problems.append(f"{where}missing plural forms {', '.join(missing)}")
        if extra:
            problems.append(f"{where}plural forms {', '.join(extra)} are not used in {language}")

    def substitutions_of(loc: dict | None) -> dict:
        return {
            name: (value.get("argNum", 0), value.get("formatSpecifier", "@"))
            for name, value in ((loc or {}).get("substitutions") or {}).items()
        }

    source_subs = substitutions_of(source_localization)
    target_subs = substitutions_of(localization) or source_subs
    source_text = english(key, entry)
    if isinstance(source_text, dict) and "value" in source_text:
        source_main = specifiers(source_text["value"], source_subs)
    elif isinstance(source_text, dict):
        source_main = specifiers(source_text.get("other", next(iter(source_text.values()), "")))
    else:
        source_main = specifiers(source_text)

    plural = localization.get("variations", {}).get("plural")
    if plural is not None:
        check_categories("", plural.keys())
        # English forms must keep the key's placeholders; translations the English ones.
        expected = specifiers(key) if language == SOURCE_LANGUAGE and key_is_text(key) else source_main
        for category, form in sorted(plural.items()):
            found = specifiers(form.get("stringUnit", {}).get("value", ""))
            if not same_arguments(expected, found):
                problems.append(f"plural form {category} has {describe(found)}, expected {describe(expected)}")
    elif "stringUnit" in localization:
        found = specifiers(localization["stringUnit"].get("value", ""), target_subs)
        if language != SOURCE_LANGUAGE:
            expected = source_main
        elif key_is_text(key):
            expected = specifiers(key, source_subs)  # the English must keep the key's placeholders
        else:
            expected = found  # a key of its own, such as "hint.pick": nothing to compare with
        if not same_arguments(expected, found):
            problems.append(f"has {describe(found)}, expected {describe(expected)}")
    for name, substitution in (localization.get("substitutions") or {}).items():
        sub_plural = substitution.get("variations", {}).get("plural", {})
        check_categories(f"substitution {name}: ", sub_plural.keys())
        argument = (substitution.get("argNum", 0), substitution.get("formatSpecifier", "@"))
        if name in source_subs and argument != source_subs[name]:
            problems.append(f"substitution {name} is argument {argument}, the English one {source_subs[name]}")
        for category, form in sorted(sub_plural.items()):
            text = form.get("stringUnit", {}).get("value", "")
            found = specifiers(text, arg=argument)
            if any(position == "?" for position, _ in found) or len(found) > 1:
                problems.append(f"substitution {name}, form {category}: has {describe(found)}, expected only %arg")
    return problems


def key_is_text(key: str) -> bool:
    """True when the key is the English text itself rather than a name such as "hint.pick"."""
    return not re.fullmatch(r"[a-z][A-Za-z0-9]*(\.[A-Za-z0-9]+)+", key)


def swift_sources(catalog: Path) -> str:
    """The Swift code that can use a catalog: every Swift file in the catalog's folder and below."""
    texts = []
    for directory, subdirectories, files in os.walk(catalog.parent):
        subdirectories[:] = [d for d in subdirectories if d not in SKIPPED_DIRECTORIES]
        for name in files:
            if name.endswith(".swift"):
                with open(Path(directory) / name, encoding="utf-8") as file:
                    texts.append(file.read())
    return "\n".join(texts)


def usage_pattern(key: str) -> re.Pattern:
    """How a key appears in Swift: as the string literal itself, with each placeholder written as
    an interpolation `\\(...)`."""
    if not key_is_text(key):
        return re.compile(re.escape(json.dumps(key, ensure_ascii=False)))
    parts = []
    last = 0
    for match in SPECIFIER.finditer(key):
        parts.append(re.escape(swift_literal(key[last:match.start()])))
        parts.append(re.escape("%") if match.group(0) == "%%" else r"\\\(.+?\)")
        last = match.end()
    parts.append(re.escape(swift_literal(key[last:])))
    return re.compile('"' + "".join(parts) + '"')


def swift_literal(text: str) -> str:
    return text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")


def check_catalog(path: Path, data: dict, duplicates: list[str], require: list[str]) -> tuple[list[str], dict[str, int]]:
    """Errors in one catalog, and the number of untranslated entries per language."""
    errors = []
    name = relative(path)
    for key in sorted(set(duplicates)):
        errors.append(f"{name}: {key!r} is written more than once")
    strings = data.get("strings", {})
    sources = None
    missing: dict[str, int] = {language: 0 for language in LANGUAGES if language != SOURCE_LANGUAGE}
    for key in sorted(strings):
        entry = strings[key]
        where = f"{name}: {key!r}"
        if not (entry.get("comment") or "").strip():
            errors.append(f"{where}: no comment for the translator")
        state = entry.get("extractionState")
        if state == "stale":
            errors.append(f"{where}: stale (no longer in the code)")
        elif state == "manual":
            if sources is None:
                sources = swift_sources(path)
            if not usage_pattern(key).search(sources):
                errors.append(f"{where}: stale (no Swift file next to the catalog uses this key)")
        for language in sorted(entry.get("localizations", {})):
            for problem in localization_problems(key, entry, language):
                errors.append(f"{where} [{language}]: {problem}")
        if not needs_translation(entry) or is_fixture(path):
            continue
        for language in missing:
            if not is_translated(entry, language):
                missing[language] += 1
                if language in require:
                    errors.append(f"{where} [{language}]: not translated")
    return errors, missing


def command_check(arguments) -> int:
    require = [language.strip() for language in (arguments.require or "").split(",") if language.strip()]
    unknown = [language for language in require if language not in LANGUAGES]
    if unknown:
        print(f"Unknown language {', '.join(unknown)}; Culla ships in {', '.join(LANGUAGES)}.", file=sys.stderr)
        return 2
    catalogs = find_catalogs()
    all_errors = []
    totals = {language: 0 for language in LANGUAGES if language != SOURCE_LANGUAGE}
    entries = 0
    for path in catalogs:
        try:
            data, duplicates = load(path)
        except (CatalogError, json.JSONDecodeError) as error:
            all_errors.append(f"{relative(path)}: {error}")
            continue
        errors, missing = check_catalog(path, data, duplicates, require)
        all_errors.extend(errors)
        entries += len(data.get("strings", {}))
        for language, count in missing.items():
            totals[language] += count
    for error in all_errors:
        print(error)
    summary = ", ".join(f"{count} untranslated in {language}" for language, count in totals.items())
    print(f"{len(catalogs)} catalogs, {entries} entries; {summary}.")
    if all_errors:
        print(f"{len(all_errors)} problem{'s' if len(all_errors) != 1 else ''}.")
        return 1
    print("OK")
    return 0


# MARK: - Stats


def command_stats(arguments) -> int:
    rows = []
    for path in find_catalogs():
        if is_fixture(path):
            continue
        data, _ = load(path)
        strings = data.get("strings", {})
        translatable = [entry for entry in strings.values() if needs_translation(entry)]
        for language in LANGUAGES:
            if language == SOURCE_LANGUAGE:
                translated = len(translatable)
            else:
                translated = sum(1 for entry in translatable if is_translated(entry, language))
            rows.append((relative(path), language, len(translatable), translated, len(translatable) - translated))
    header = ("Catalog", "Lang", "Total", "Translated", "Missing")
    widths = [max(len(str(row[index])) for row in rows + [header]) for index in range(len(header))]
    print("  ".join(str(cell).ljust(width) if index < 2 else str(cell).rjust(width) for index, (cell, width) in enumerate(zip(header, widths))))
    for row in rows:
        print("  ".join(str(cell).ljust(width) if index < 2 else str(cell).rjust(width) for index, (cell, width) in enumerate(zip(row, widths))))
    return 0


# MARK: - Export


def command_export(arguments) -> int:
    language = arguments.language
    if language not in LANGUAGES or language == SOURCE_LANGUAGE:
        print(f"Export a translation language: {', '.join(l for l in LANGUAGES if l != SOURCE_LANGUAGE)}.", file=sys.stderr)
        return 2
    catalogs = {}
    for path in find_catalogs():
        if is_fixture(path):
            continue
        data, _ = load(path)
        items = []
        for key, entry in sorted(data.get("strings", {}).items()):
            if not needs_translation(entry):
                continue
            translated = is_translated(entry, language)
            if arguments.missing_only and translated:
                continue
            items.append({
                "key": key,
                "comment": entry.get("comment", ""),
                "english": english(key, entry),
                "translation": shape(entry.get("localizations", {}).get(language), key),
            })
        if items:
            catalogs[relative(path)] = items
    document = {
        "language": language,
        "pluralCategories": PLURAL_CATEGORIES[language],
        "catalogs": catalogs,
    }
    out = Path(arguments.out)
    with open(out, "w", encoding="utf-8") as file:
        file.write(json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    count = sum(len(items) for items in catalogs.values())
    print(f"Wrote {count} entr{'y' if count == 1 else 'ies'} from {len(catalogs)} catalog{'s' if len(catalogs) != 1 else ''} to {out}.")
    return 0


# MARK: - Import


def build_localization(key: str, entry: dict, translation, language: str) -> dict:
    """The catalog's localization object for a translation in the translator's shape."""
    source = english(key, entry)
    if isinstance(source, str):
        if not isinstance(translation, str):
            raise CatalogError("expected a string")
        return unit(translation)
    if "value" in source:
        if not isinstance(translation, dict) or not isinstance(translation.get("value"), str):
            raise CatalogError('expected {"value": ..., "substitutions": {...}}')
        source_localization = entry.get("localizations", {}).get(SOURCE_LANGUAGE, {})
        given = translation.get("substitutions") or {}
        if set(given) != set(source["substitutions"]):
            raise CatalogError(f"expected the substitutions {', '.join(sorted(source['substitutions']))}")
        substitutions = {}
        for name, forms in given.items():
            if not isinstance(forms, dict) or not all(isinstance(text, str) for text in forms.values()):
                raise CatalogError(f"substitution {name}: expected {{category: string}}")
            original = source_localization["substitutions"][name]
            substitutions[name] = {
                "argNum": original.get("argNum"),
                "formatSpecifier": original.get("formatSpecifier"),
                "variations": {"plural": {category: unit(text) for category, text in forms.items()}},
            }
        return {"stringUnit": {"state": "translated", "value": translation["value"]}, "substitutions": substitutions}
    if not isinstance(translation, dict) or not all(isinstance(text, str) for text in translation.values()):
        raise CatalogError("expected plural forms {category: string}")
    return {"variations": {"plural": {category: unit(text) for category, text in translation.items()}}}


def is_empty(translation) -> bool:
    if translation is None or translation == "":
        return True
    if isinstance(translation, dict):
        if "value" in translation:
            return not translation.get("value")
        return all(not text for text in translation.values())
    return False


def command_import(arguments) -> int:
    language = arguments.language
    if language not in LANGUAGES or language == SOURCE_LANGUAGE:
        print(f"Import a translation language: {', '.join(l for l in LANGUAGES if l != SOURCE_LANGUAGE)}.", file=sys.stderr)
        return 2
    with open(arguments.file, encoding="utf-8") as file:
        document = json.load(file)
    if document.get("language") != language:
        print(f"The file is for {document.get('language')!r}, not {language!r}.", file=sys.stderr)
        return 1
    known = {relative(path): path for path in find_catalogs()}
    errors = []
    changed: dict[str, dict] = {}
    imported = 0
    for name, items in sorted((document.get("catalogs") or {}).items()):
        if name not in known:
            errors.append(f"{name}: no such catalog in the repository")
            continue
        data, duplicates = load(known[name])
        strings = data.get("strings", {})
        for item in items:
            key = item.get("key")
            if key not in strings:
                errors.append(f"{name}: {key!r} is not in the catalog")
                continue
            translation = item.get("translation")
            if is_empty(translation):
                continue
            try:
                localization = build_localization(key, strings[key], translation, language)
            except CatalogError as error:
                errors.append(f"{name}: {key!r}: {error}")
                continue
            strings[key].setdefault("localizations", {})[language] = localization
            for problem in localization_problems(key, strings[key], language):
                errors.append(f"{name}: {key!r} [{language}]: {problem}")
            imported += 1
            changed[name] = data
    if errors:
        for error in errors:
            print(error)
        print(f"Nothing imported: {len(errors)} problem{'s' if len(errors) != 1 else ''}.")
        return 1
    for name, data in changed.items():
        save(known[name], data)
    print(f"Imported {imported} translation{'s' if imported != 1 else ''} into {len(changed)} catalog{'s' if len(changed) != 1 else ''}.")
    return 0


def command_clean(arguments) -> int:
    """Undoes what an Xcode build may do to the catalogs. Culla writes every entry by hand
    (`manual`, with a comment); Xcode's string extraction, when it runs in the IDE, adds entries
    for literals it finds in the code (keys of their own such as "hint.pick" show up under their
    English default, "pick") without a comment, and marks entries it no longer finds as stale."""
    changed_any = False
    for path in find_catalogs():
        data, _ = load(path)
        strings = data.get("strings", {})
        name = relative(path)
        sources = None
        removed, unstaled, still_stale = [], [], []
        for key in sorted(strings):
            entry = strings[key]
            state = entry.get("extractionState")
            has_comment = bool((entry.get("comment") or "").strip())
            if state != "manual" and not has_comment:
                # Added by Xcode: never written by hand, so nothing of value is lost.
                removed.append(key)
                del strings[key]
                continue
            if state == "stale":
                if sources is None:
                    sources = swift_sources(path)
                if usage_pattern(key).search(sources):
                    entry["extractionState"] = "manual"
                    unstaled.append(key)
                else:
                    still_stale.append(key)
        for key in removed:
            print(f"{name}: removed {key!r} (added by Xcode, no comment)")
        for key in unstaled:
            print(f"{name}: {key!r} is used in the code: marked manual again")
        for key in still_stale:
            print(f"{name}: {key!r} is stale and no Swift file uses it: left for you to remove", file=sys.stderr)
        if removed or unstaled:
            changed_any = True
            if not arguments.dry_run:
                save(path, data)
    if not changed_any:
        print("Nothing to clean.")
    elif arguments.dry_run:
        print("Dry run: nothing written.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser("check", help="find problems in every catalog")
    check.add_argument("--require", help="languages that must be fully translated, such as ru,tk")
    commands.add_parser("stats", help="count translated and missing entries")
    export = commands.add_parser("export", help="write a translator's file")
    export.add_argument("language")
    export.add_argument("--out", required=True)
    export.add_argument("--missing-only", action="store_true", help="only entries not translated yet")
    import_ = commands.add_parser("import", help="merge a translator's file back")
    import_.add_argument("language")
    import_.add_argument("file")
    clean = commands.add_parser("clean", help="remove entries an Xcode build added and stale marks it set")
    clean.add_argument("--dry-run", action="store_true", help="say what would change, write nothing")
    arguments = parser.parse_args()
    handlers = {"check": command_check, "stats": command_stats, "export": command_export, "import": command_import,
                "clean": command_clean}
    try:
        return handlers[arguments.command](arguments)
    except CatalogError as error:
        print(error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
