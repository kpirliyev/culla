#!/usr/bin/env python3
"""Count cullaapp.com visits from the nginx log, and take a daily snapshot of
the download numbers GitHub keeps for the disk images.

Runs from root's crontab once a day, after midnight. Writes two CSV files in
/data/cullaapp.com/stats/ (not served):

    visits.csv      date,lang,visits,page_views
    downloads.csv   date,tag,file,total,new

visits.csv (from access.log, for the previous day)
  Page view  A GET with status 200 or 304 of exactly /en/, /ru/ or /tk/ (a
             query string is ignored). 304 is a returning visitor whose
             browser revalidated the page (HTML is served "no-cache").
  Visit      One distinct (shortened address, browser) per language per day.
             Every language gets a row each day, also with 0.
  Robots     Requests whose user agent matches ROBOT_PATTERNS below, or that
             have no user agent, are left out.
  Lines are picked by the date in their timestamp (server local time). The
  current log, .1 and older .N / .N.gz files are read, so it does not matter
  when logrotate ran; a file seen twice under two names (rotation during the
  run) is read once. Re-running a date replaces that date's rows.

downloads.csv (from GitHub, as of the moment the script runs)
  The disk images are assets of the releases on GitHub, which counts their
  downloads itself. One unauthenticated request a day,
      GET https://api.github.com/repos/<repository>/releases?per_page=100
  and for every .dmg asset of every release one row:
      date    the day the numbers were read (server local time)
      tag     the release tag, such as v1.0
      file    the asset's file name, such as Culla-1.0.dmg
      total   GitHub's download_count: downloads so far
      new     downloads since the previous row for that tag and file (the
              whole total for the first row). When the total went down, the
              asset was replaced and GitHub began counting again from 0, so
              new is the new total; it is never negative.
  A second run on the same day replaces that day's rows with fresh numbers.
  If GitHub cannot be reached, answers with an error or is rate limited, no
  downloads row is written that day, one line goes to stderr and the visits
  are still counted; the exit status stays 0 (cron sends the output to the
  journal) and the next day's row catches up, since totals are cumulative.

Usage:
    count.py                     visits for yesterday, downloads now
    count.py --date 2026-11-15   visits for one given day, downloads now
    count.py --backfill          visits for every complete day in the logs
    count.py --repository owner/name   another GitHub repository
    count.py --releases-file f.json    read GitHub's answer from a file
                                       instead of asking GitHub (for tests)

Settings can be overridden through the environment (for tests):
    CULLA_LOG_DIR        default /data/cullaapp.com/log
    CULLA_STATS_DIR      default /data/cullaapp.com/stats
    CULLA_REPOSITORY     default kpirliyev/culla

Standard library only; works with Python 3.7 and later.
"""

import argparse
import csv
import datetime
import glob
import gzip
import http.client
import json
import os
import re
import sys
import urllib.error
import urllib.request

# User agents that are not people. Matched case-insensitively anywhere in the
# user agent. curl and wget are deliberately not here: people use them too.
ROBOT_PATTERNS = [
    r"bot\b", r"bot/", r"crawl", r"spider", r"slurp", r"archiver",
    r"facebookexternalhit", r"embedly", r"preview", r"headlesschrome",
    r"lighthouse", r"pagespeed", r"pingdom", r"uptime", r"monitor",
    r"python-requests", r"python-urllib", r"aiohttp", r"httpx", r"go-http-client",
    r"java/", r"okhttp", r"libwww", r"scrapy", r"node-fetch", r"axios",
    r"feed", r"validator", r"scanner", r"zgrab", r"masscan", r"nmap",
]
ROBOT_RE = re.compile("|".join(ROBOT_PATTERNS), re.IGNORECASE)

LANGUAGES = ("en", "ru", "tk")
PAGES = {"/%s/" % lang: lang for lang in LANGUAGES}
# 304: a returning visitor's browser revalidated the no-cache HTML.
PAGE_STATUSES = (200, 304)

LOG_DIR = os.environ.get("CULLA_LOG_DIR", "/data/cullaapp.com/log")
STATS_DIR = os.environ.get("CULLA_STATS_DIR", "/data/cullaapp.com/stats")
REPOSITORY = os.environ.get("CULLA_REPOSITORY", "kpirliyev/culla")

GITHUB_URL = "https://api.github.com/repos/%s/releases?per_page=100"
GITHUB_TIMEOUT = 20  # seconds
USER_AGENT = "cullaapp-count"
_NAME = r"(?=[A-Za-z0-9_.-]*[A-Za-z0-9_-])[A-Za-z0-9_.-]+"  # not only dots
REPOSITORY_RE = re.compile(r"%s/%s" % (_NAME, _NAME))

VISITS_HEADER = ["date", "lang", "visits", "page_views"]
DOWNLOADS_HEADER = ["date", "tag", "file", "total", "new"]


def is_robot(ua):
    ua = (ua or "").strip()
    return not ua or ua == "-" or bool(ROBOT_RE.search(ua))


# ---------------------------------------------------------------------------
# Reading logs
# ---------------------------------------------------------------------------

def log_files(name, all_rotations=False):
    """Paths of the current log and its rotations, newest first."""
    base = os.path.join(LOG_DIR, name)
    found = {}
    for path in glob.glob(glob.escape(base) + ".*"):
        match = re.match(r"^\.(\d+)(\.gz)?$", path[len(base):])
        if match:
            number = int(match.group(1))
            # While logrotate compresses .N into .N.gz both exist for a
            # moment; the plain file is the complete one.
            if number not in found or not path.endswith(".gz"):
                found[number] = path
    numbered = sorted(found.items())
    if not all_rotations:
        # A day's lines are at most two rotations back; one more for safety.
        numbered = [item for item in numbered if item[0] <= 3]
    return [base] + [path for _, path in numbered]


def read_entries(name, all_rotations=False):
    """Yield the parsed JSON lines of a log and all its rotations."""
    seen_inodes = set()
    for path in log_files(name, all_rotations):
        try:
            f = gzip.open(path, "rb") if path.endswith(".gz") else open(path, "rb")
        except FileNotFoundError:
            continue
        with f:
            if not path.endswith(".gz"):
                inode = os.fstat(f.fileno()).st_ino
                if inode in seen_inodes:
                    continue
                seen_inodes.add(inode)
            try:
                for raw in f:
                    try:
                        entry = json.loads(raw.decode("utf-8", errors="replace"))
                    except ValueError:
                        continue
                    if isinstance(entry, dict):
                        yield entry
            except (OSError, EOFError) as error:
                # A .gz being written by logrotate right now, for example.
                sys.stderr.write("count: could not finish reading %s: %s\n" % (path, error))


def entry_date(entry):
    return str(entry.get("time", ""))[:10]


def as_int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return -1


# ---------------------------------------------------------------------------
# Visits
# ---------------------------------------------------------------------------

def count_visits(entries, dates):
    """{date: {lang: (visits, page_views)}}; every language appears."""
    views = {d: {lang: 0 for lang in LANGUAGES} for d in dates}
    visitors = {d: {lang: set() for lang in LANGUAGES} for d in dates}
    for entry in entries:
        day = entry_date(entry)
        if day not in views:
            continue
        if entry.get("method") != "GET" or as_int(entry.get("status")) not in PAGE_STATUSES:
            continue
        path = str(entry.get("uri", "")).split("?", 1)[0]
        lang = PAGES.get(path)
        if lang is None or is_robot(entry.get("ua", "")):
            continue
        views[day][lang] += 1
        visitors[day][lang].add((entry.get("ip", ""), entry.get("ua", "")))
    return {d: {lang: (len(visitors[d][lang]), views[d][lang]) for lang in LANGUAGES}
            for d in dates}


# ---------------------------------------------------------------------------
# Downloads: GitHub's numbers
# ---------------------------------------------------------------------------

class GitHubError(Exception):
    pass


def fetch_url(url):
    """GET url and return the body. Raises GitHubError on any failure."""
    request = urllib.request.Request(url, headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": USER_AGENT,
    })
    try:
        with urllib.request.urlopen(request, timeout=GITHUB_TIMEOUT) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        if error.headers.get("X-RateLimit-Remaining") == "0" or error.code == 429:
            raise GitHubError("rate limited by GitHub (HTTP %d)" % error.code)
        raise GitHubError("GitHub answered HTTP %d" % error.code)
    except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError) as error:
        reason = getattr(error, "reason", error)
        raise GitHubError("could not reach GitHub: %s" % reason)


def release_assets(body):
    """[(tag, file, download_count)] for every .dmg asset in GitHub's answer."""
    try:
        releases = json.loads(body.decode("utf-8") if isinstance(body, bytes) else body)
    except ValueError as error:
        raise GitHubError("GitHub's answer is not JSON: %s" % error)
    if not isinstance(releases, list):
        raise GitHubError("GitHub's answer is not a list of releases")
    found = []
    for release in releases:
        if not isinstance(release, dict):
            continue
        tag = release.get("tag_name")
        assets = release.get("assets")
        if not isinstance(tag, str) or not tag or not isinstance(assets, list):
            continue
        for asset in assets:
            if not isinstance(asset, dict):
                continue
            name, total = asset.get("name"), asset.get("download_count")
            if (isinstance(name, str) and name.lower().endswith(".dmg")
                    and isinstance(total, int) and not isinstance(total, bool) and total >= 0):
                found.append((tag, name, total))
    return found


def download_rows(assets, day, earlier_rows):
    """Rows for downloads.csv on day; earlier_rows are the rows before day."""
    previous = {}
    for row in sorted(earlier_rows, key=lambda r: r[0]):
        if len(row) >= 4 and row[0] < day:
            try:
                previous[(row[1], row[2])] = int(row[3])
            except ValueError:
                continue
    rows = []
    for tag, name, total in sorted(set(assets), key=lambda a: (version_key(a[0]), a[1])):
        before = previous.get((tag, name))
        if before is None:
            new = total           # the first row for this asset
        elif total >= before:
            new = total - before
        else:
            new = total           # replaced asset: GitHub counts from 0 again
        rows.append([day, tag, name, str(total), str(new)])
    return rows


# ---------------------------------------------------------------------------
# CSV files
# ---------------------------------------------------------------------------

def replace_rows(path, header, new_rows, dates):
    """Drop the rows of the given dates, add new_rows, keep sorted by date."""
    rows = []
    if os.path.exists(path):
        with open(path, newline="", encoding="utf-8") as f:
            reader = csv.reader(f)
            for i, row in enumerate(reader):
                if i == 0 and row == header:
                    continue
                if row and row[0] not in dates:
                    rows.append(row)
    rows.extend(new_rows)
    rows.sort(key=lambda r: r[0])  # stable: a day's rows keep their order
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f, lineterminator="\n")
        writer.writerow(header)
        writer.writerows(rows)
    os.replace(tmp, path)


def read_rows(path, header):
    """The data rows of a CSV file written by replace_rows (none if missing)."""
    if not os.path.exists(path):
        return []
    with open(path, newline="", encoding="utf-8") as f:
        return [row for i, row in enumerate(csv.reader(f))
                if row and not (i == 0 and row == header)]


def set_aside_old_format(path, header):
    """Rename a CSV file whose first line is not header to <name>.old-<n>."""
    if not os.path.exists(path):
        return
    with open(path, newline="", encoding="utf-8") as f:
        first = next(csv.reader(f), None)
    if first is None or first == header:
        return
    n = 1
    while os.path.exists("%s.old-%d" % (path, n)):
        n += 1
    os.replace(path, "%s.old-%d" % (path, n))
    sys.stderr.write("count: %s had other columns; kept as %s.old-%d\n" % (path, path, n))


def version_key(version):
    """Sort key for tags such as v1.0, v1.10, v2.0-beta.1."""
    return [(0, int(p), "") if p.isdigit() else (1, 0, p)
            for p in re.split(r"[.-]", version.lstrip("vV"))]


def snapshot_downloads(repository, releases_file, fetch, today):
    """Write today's downloads rows; on failure write nothing and say why."""
    try:
        if releases_file:
            try:
                with open(releases_file, "rb") as f:
                    body = f.read()
            except OSError as error:
                raise GitHubError("cannot read %s: %s" % (releases_file, error))
        else:
            body = fetch(GITHUB_URL % repository)
        assets = release_assets(body)
    except GitHubError as error:
        sys.stderr.write("count: no downloads row today: %s\n" % error)
        return
    path = os.path.join(STATS_DIR, "downloads.csv")
    set_aside_old_format(path, DOWNLOADS_HEADER)
    rows = download_rows(assets, today, read_rows(path, DOWNLOADS_HEADER))
    replace_rows(path, DOWNLOADS_HEADER, rows, {today})


def main(argv=None, fetch=fetch_url):
    parser = argparse.ArgumentParser(description="Count cullaapp.com visits and downloads.")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--date", help="the day to count visits for, YYYY-MM-DD (default: yesterday)")
    group.add_argument("--backfill", action="store_true",
                       help="count visits for every complete day found in the logs and their rotations")
    parser.add_argument("--repository", default=REPOSITORY,
                        help="the GitHub repository, owner/name (default: %(default)s)")
    parser.add_argument("--releases-file",
                        help="read GitHub's list of releases from this file instead of asking GitHub")
    args = parser.parse_args(argv)
    if not REPOSITORY_RE.fullmatch(args.repository):
        parser.error("--repository must be owner/name")

    today = datetime.date.today()
    access = list(read_entries("access.log", all_rotations=args.backfill))

    if args.backfill:
        dates = sorted({entry_date(e) for e in access
                        if re.match(r"^\d{4}-\d{2}-\d{2}$", entry_date(e))
                        and entry_date(e) < today.isoformat()})
        if not dates:
            print("count: no complete day in the logs")
    else:
        if args.date:
            try:
                day = datetime.date.fromisoformat(args.date)
            except ValueError:
                parser.error("--date must be YYYY-MM-DD")
        else:
            day = today - datetime.timedelta(days=1)
        dates = [day.isoformat()]

    if dates:
        visit_counts = count_visits(access, dates)
        visit_rows = [[d, lang, str(visit_counts[d][lang][0]), str(visit_counts[d][lang][1])]
                      for d in dates for lang in LANGUAGES]
        replace_rows(os.path.join(STATS_DIR, "visits.csv"), VISITS_HEADER, visit_rows, set(dates))

    snapshot_downloads(args.repository, args.releases_file, fetch, today.isoformat())
    return 0


if __name__ == "__main__":
    sys.exit(main())
