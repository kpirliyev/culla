#!/usr/bin/env python3
"""Prints the newest macOS crash reports, for a CI log.

    Scripts/crash-reports.py [--minutes 30] [--max-reports 4] [--max-lines 150] [--wait 20]

Reads the `.ips` files in ~/Library/Logs/DiagnosticReports changed in the last `--minutes` and
prints, for each of the newest `--max-reports`, the process, the exception type, signal and
codes, the termination reason, any message the crashing library left (`asi`), and the crashed
thread's backtrace, capped at `--max-lines` lines per report. A trap inside a system framework
prints nothing to the test output; the crash report is where its reason is.

Waits up to `--wait` seconds for a report to appear, because ReportCrash writes it a little
after the process has died. Python 3 standard library only. Always exits 0: it only reports.
"""

import argparse
import json
import os
import sys
import time
from pathlib import Path

REPORT_FOLDERS = [
    Path.home() / "Library/Logs/DiagnosticReports",
    Path.home() / "Library/Logs/DiagnosticReports/Retired",
]


def recent_reports(minutes):
    cutoff = time.time() - minutes * 60
    found = []
    for folder in REPORT_FOLDERS:
        if not folder.is_dir():
            continue
        for path in folder.glob("*.ips"):
            try:
                modified = path.stat().st_mtime
            except OSError:
                continue
            if modified >= cutoff:
                found.append((modified, path))
    return [path for _, path in sorted(found, reverse=True)]


def parse(text):
    """An .ips file is one line of JSON (the header) followed by a JSON body."""
    header_line, _, body = text.partition("\n")
    header = json.loads(header_line)
    return header, json.loads(body) if body.strip() else {}


def describe_frame(number, frame, images):
    image = {}
    index = frame.get("imageIndex")
    if isinstance(index, int) and 0 <= index < len(images):
        image = images[index]
    name = image.get("name") or image.get("path") or "???"
    symbol = frame.get("symbol")
    if symbol:
        where = f"{symbol} + {frame.get('symbolLocation', 0)}"
    else:
        where = f"{name} + {frame.get('imageOffset', 0)}"
    source = ""
    if frame.get("sourceFile"):
        source = f"  ({frame['sourceFile']}:{frame.get('sourceLine', '?')})"
    return f"  {number:<3} {name:<34} {where}{source}"


def summarise(header, body):
    lines = []
    lines.append(f"Process:     {body.get('procName') or header.get('name')}  ({body.get('procPath', '')})")
    lines.append(f"Captured:    {body.get('captureTime', header.get('timestamp', ''))}")
    lines.append(f"OS:          {header.get('os_version', '')}")
    model = body.get("modelCode")
    if model:
        lines.append(f"Model:       {model}")
    exception = body.get("exception") or {}
    if exception:
        lines.append(
            f"Exception:   {exception.get('type', '')} ({exception.get('signal', '')})"
            f"  codes {exception.get('codes', '')}  {exception.get('subtype', '')}".rstrip()
        )
    termination = body.get("termination") or {}
    if termination:
        reasons = termination.get("reasons") or []
        lines.append(
            f"Termination: {termination.get('namespace', '')} {termination.get('indicator', '')}"
            f" code {termination.get('code', '')}".rstrip()
        )
        for reason in reasons:
            lines.append(f"             {reason}")
    if body.get("ktriageinfo"):
        lines.append("Kernel triage:")
        lines.extend(f"  {line}" for line in str(body["ktriageinfo"]).splitlines())
    asi = body.get("asi") or {}
    if asi:
        lines.append("Application-specific information:")
        for image, messages in asi.items():
            for message in messages if isinstance(messages, list) else [messages]:
                lines.append(f"  {image}: {message}")

    threads = body.get("threads") or []
    images = body.get("usedImages") or []
    faulting = body.get("faultingThread")
    if isinstance(faulting, int) and 0 <= faulting < len(threads):
        thread = threads[faulting]
        title = f"Crashed thread {faulting}"
        if thread.get("name"):
            title += f" ({thread['name']})"
        if thread.get("queue"):
            title += f"  queue {thread['queue']}"
        lines.append(title + ":")
        for number, frame in enumerate(thread.get("frames") or []):
            lines.append(describe_frame(number, frame, images))
    else:
        lines.append(f"No crashed thread recorded (faultingThread {faulting!r}).")
    return lines


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--minutes", type=float, default=30)
    parser.add_argument("--max-reports", type=int, default=4)
    parser.add_argument("--max-lines", type=int, default=150)
    parser.add_argument("--wait", type=float, default=20)
    options = parser.parse_args()

    deadline = time.time() + max(0, options.wait)
    reports = recent_reports(options.minutes)
    while not reports and time.time() < deadline:
        time.sleep(2)
        reports = recent_reports(options.minutes)

    if not reports:
        folders = ", ".join(str(folder) for folder in REPORT_FOLDERS)
        print(f"No crash report (.ips) from the last {options.minutes:g} minutes in {folders}.")
        return 0

    print(f"{len(reports)} crash report(s) from the last {options.minutes:g} minutes; showing the newest {min(len(reports), options.max_reports)}.")
    for path in reports[: options.max_reports]:
        print()
        print(f"===== {path.name} =====")
        try:
            text = path.read_text(errors="replace")
        except OSError as error:
            print(f"Cannot read it: {error}")
            continue
        try:
            lines = summarise(*parse(text))
        except (ValueError, AttributeError, TypeError) as error:
            # Not the JSON format: show the file as it is.
            print(f"(Not a JSON crash report: {error}; showing the start of the file.)")
            lines = text.splitlines()
        for line in lines[: options.max_lines]:
            print(line)
        if len(lines) > options.max_lines:
            print(f"... {len(lines) - options.max_lines} more line(s) cut")
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:  # never fail the job because of this report
        print(f"crash-reports.py could not finish: {error!r}")
        sys.exit(0)
