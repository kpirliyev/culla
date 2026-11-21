"""Tests for count.py. Run: python3 -m unittest discover -s site/deploy/test

No test uses the network: GitHub's answer comes from a function passed to
count.main() or from the fixture file test/fixtures/github-releases.json.
"""

import csv
import datetime
import gzip
import importlib.util
import io
import json
import os
import tempfile
import unittest
import urllib.error
from contextlib import redirect_stderr
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(os.path.dirname(HERE), "count.py")
FIXTURE = os.path.join(HERE, "fixtures", "github-releases.json")

spec = importlib.util.spec_from_file_location("count", SCRIPT)
count = importlib.util.module_from_spec(spec)
spec.loader.exec_module(count)

DAY = "2026-11-15"
TODAY = datetime.date.today().isoformat()
SAFARI = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 Safari/605.1.15"
FIREFOX = "Mozilla/5.0 (Macintosh; rv:140.0) Gecko/20100101 Firefox/140.0"
BOT = "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
DOWNLOADS_HEADER = ["date", "tag", "file", "total", "new"]


def page(uri, status=200, ip="203.0.113.57", ua=SAFARI, day=DAY, method="GET"):
    return {"time": day + "T09:30:00+05:00", "ip": ip, "host": "cullaapp.com",
            "method": method, "uri": uri, "status": status, "bytes": 5000,
            "referrer": "", "ua": ua}


def write_log(path, entries, gz=False):
    data = "".join(json.dumps(e, separators=(",", ":")) + "\n" for e in entries).encode()
    if gz:
        with gzip.open(path, "wb") as f:
            f.write(data)
    else:
        with open(path, "wb") as f:
            f.write(data)


def releases(*items):
    """GitHub's answer for [(tag, [(file, download_count), ...]), ...]."""
    return json.dumps([
        {"tag_name": tag, "assets": [{"name": name, "download_count": n} for name, n in assets]}
        for tag, assets in items
    ]).encode()


class FakeGitHub:
    """Stands in for count.fetch_url: answers with body, or raises."""

    def __init__(self, body=None, error=None):
        self.body, self.error, self.urls = body, error, []

    def __call__(self, url):
        self.urls.append(url)
        if self.error:
            raise self.error
        return self.body


class CountTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = self.tmp.name
        self.logs = os.path.join(root, "log")
        self.stats = os.path.join(root, "stats")
        for d in (self.logs, self.stats):
            os.makedirs(d)
        count.LOG_DIR, count.STATS_DIR = self.logs, self.stats
        self.github = FakeGitHub(releases())

    def tearDown(self):
        self.tmp.cleanup()

    def log(self, name):
        return os.path.join(self.logs, name)

    def run_count(self, *argv, fetch=None):
        with redirect_stderr(io.StringIO()) as err:
            self.assertEqual(count.main(list(argv), fetch=fetch or self.github), 0)
        return err.getvalue()

    def csv_rows(self, name):
        with open(os.path.join(self.stats, name), newline="") as f:
            return list(csv.reader(f))

    def write_csv(self, name, text):
        with open(os.path.join(self.stats, name), "w") as f:
            f.write(text)


class VisitTests(CountTestCase):
    def fixture(self):
        # Spread over the current file, .1 and .2.gz, as after logrotate.
        write_log(self.log("access.log.2.gz"), [
            page("/en/"), page("/en/"),                        # 2 views, 1 visit
            page("/en/", day="2026-11-13"),                    # other day
        ], gz=True)
        write_log(self.log("access.log.1"), [
            page("/en/?ref=forum", ip="198.51.100.23", ua=FIREFOX),
            page("/ru/"),
            page("/en/", ua=BOT),
            page("/download", status=302),                     # not a page view
        ])
        write_log(self.log("access.log"), [
            page("/tk/", status=304, ip="192.0.2.14", ua=FIREFOX),  # returning visitor
            page("/tk/", status=404),
            page("/en/", status=301),
            page("/en/index.html"),
            page("/ru/release-notes/"),
            page("/", status=302),
            page("/tk/", method="POST"),
            page("/tk/", ip="2001:db8:5:6::1"),
            page("/en/", ua=""),                               # no user agent
        ])
        with open(self.log("access.log"), "ab") as f:
            f.write(b"{broken json\n")

    def test_counts_one_day(self):
        self.fixture()
        self.run_count("--date", DAY)
        self.assertEqual(self.csv_rows("visits.csv"), [
            ["date", "lang", "visits", "page_views"],
            [DAY, "en", "2", "3"],
            [DAY, "ru", "1", "1"],
            [DAY, "tk", "2", "2"],
        ])

    def test_rerun_replaces_only_that_day(self):
        self.fixture()
        self.write_csv("visits.csv", "date,lang,visits,page_views\n"
                                     "2026-11-01,en,7,9\n2026-11-15,en,99,99\n")
        self.run_count("--date", DAY)
        first = self.csv_rows("visits.csv")
        self.run_count("--date", DAY)
        self.assertEqual(self.csv_rows("visits.csv"), first)
        self.assertEqual(first[1], ["2026-11-01", "en", "7", "9"])
        self.assertNotIn(["2026-11-15", "en", "99", "99"], first)
        self.assertEqual(sum(1 for r in first if r[0] == DAY and r[1] == "en"), 1)

    def test_day_without_traffic(self):
        self.fixture()
        self.run_count("--date", "2026-10-01")
        self.assertEqual(self.csv_rows("visits.csv")[1:],
                         [["2026-10-01", lang, "0", "0"] for lang in ("en", "ru", "tk")])

    def test_yesterday_by_default(self):
        yesterday = (datetime.date.today() - datetime.timedelta(days=1)).isoformat()
        write_log(self.log("access.log"), [page("/ru/", day=yesterday), page("/ru/", day=TODAY)])
        self.run_count()
        self.assertEqual(self.csv_rows("visits.csv")[1:], [
            [yesterday, "en", "0", "0"], [yesterday, "ru", "1", "1"], [yesterday, "tk", "0", "0"]])

    def test_backfill(self):
        self.fixture()
        write_log(self.log("access.log.3.gz"), [page("/ru/", day="2026-11-10")], gz=True)
        with open(self.log("access.log"), "a") as f:
            f.write(json.dumps(page("/en/", day=TODAY)) + "\n")
        self.run_count("--backfill")
        days = sorted({r[0] for r in self.csv_rows("visits.csv")[1:]})
        self.assertEqual(days, ["2026-11-10", "2026-11-13", "2026-11-15"])
        self.assertNotIn(TODAY, days)

    def test_visit_is_full_address_and_browser(self):
        # Addresses are logged in full: neighbours in the same network are
        # two visitors, the same address and browser twice is one.
        write_log(self.log("access.log"), [
            page("/en/", ip="203.0.113.57"), page("/en/", ip="203.0.113.58"),
            page("/en/", ip="203.0.113.57"), page("/en/", ip="203.0.113.57", ua=FIREFOX),
            page("/ru/", ip="2001:db8:5:6::1"), page("/ru/", ip="2001:db8:5:6::2"),
        ])
        self.run_count("--date", DAY)
        self.assertEqual(self.csv_rows("visits.csv")[1:], [
            [DAY, "en", "3", "4"], [DAY, "ru", "2", "2"], [DAY, "tk", "0", "0"]])

    def test_rotated_file_seen_twice_is_read_once(self):
        # logrotate renamed access.log while count.py was starting: the same
        # file shows up as both access.log and access.log.1 (a hard link here).
        write_log(self.log("access.log"), [page("/en/")])
        os.link(self.log("access.log"), self.log("access.log.1"))
        self.run_count("--date", DAY)
        self.assertEqual(self.csv_rows("visits.csv")[1], [DAY, "en", "1", "1"])

    def test_plain_rotation_wins_over_unfinished_gz(self):
        write_log(self.log("access.log.2"), [page("/en/")])
        with open(self.log("access.log.2.gz"), "wb") as f:
            f.write(b"\x1f\x8b\x08\x00 truncated")
        self.run_count("--date", DAY)
        self.assertEqual(self.csv_rows("visits.csv")[1], [DAY, "en", "1", "1"])

    def test_robot_patterns(self):
        for ua in (BOT, "Mozilla/5.0 (compatible; bingbot/2.0)", "python-requests/2.32",
                   "facebookexternalhit/1.1", "Mozilla/5.0 HeadlessChrome/140", "", "-"):
            self.assertTrue(count.is_robot(ua), ua)
        for ua in (SAFARI, FIREFOX, "curl/8.7.1", "Wget/1.24.5",
                   "Mozilla/5.0 (Linux; Android 14; CUBOT_X70) Chrome/140 Mobile"):
            self.assertFalse(count.is_robot(ua), ua)


class DownloadSnapshotTests(CountTestCase):
    def test_one_request_to_github(self):
        self.run_count("--date", DAY)
        self.assertEqual(self.github.urls,
                         ["https://api.github.com/repos/kpirliyev/culla/releases?per_page=100"])
        self.run_count("--date", DAY, "--repository", "someone/other.repo")
        self.assertEqual(self.github.urls[-1],
                         "https://api.github.com/repos/someone/other.repo/releases?per_page=100")

    def test_bad_repository_is_refused(self):
        for bad in ("culla", "a/b/c", "a b/c", "../x", "owner/..", "a/b\n", "a/b?x=1"):
            with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                count.main(["--repository", bad], fetch=self.github)
        self.assertEqual(self.github.urls, [])

    def test_request_headers(self):
        seen = {}

        class Response(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

        def fake_urlopen(request, timeout):
            seen["url"], seen["timeout"] = request.full_url, timeout
            seen["headers"] = {k.lower(): v for k, v in request.header_items()}
            seen["method"] = request.get_method()
            return Response(b"[]")

        with mock.patch.object(count.urllib.request, "urlopen", fake_urlopen):
            self.assertEqual(count.fetch_url("https://api.github.com/x"), b"[]")
        self.assertEqual(seen["method"], "GET")
        self.assertLessEqual(seen["timeout"], 30)
        self.assertEqual(seen["headers"]["accept"], "application/vnd.github+json")
        self.assertEqual(seen["headers"]["user-agent"], "cullaapp-count")
        self.assertNotIn("authorization", seen["headers"])

    def test_fixture_file(self):
        self.run_count("--date", DAY, "--releases-file", FIXTURE)
        self.assertEqual(self.github.urls, [])  # the file replaces the request
        self.assertEqual(self.csv_rows("downloads.csv"), [
            DOWNLOADS_HEADER,
            [TODAY, "v1.0", "Culla-1.0.dmg", "57", "57"],
            [TODAY, "v1.1", "Culla-1.1.dmg", "12", "12"],
        ])

    def test_new_since_the_previous_row(self):
        self.write_csv("downloads.csv", "date,tag,file,total,new\n"
                                        "2026-11-01,v1.0,Culla-1.0.dmg,10,10\n"
                                        "2026-11-02,v1.0,Culla-1.0.dmg,40,30\n")
        self.github.body = releases(("v1.0", [("Culla-1.0.dmg", 57)]),
                                    ("v1.1", [("Culla-1.1.dmg", 5)]))
        self.run_count("--date", DAY)
        self.assertEqual(self.csv_rows("downloads.csv"), [
            DOWNLOADS_HEADER,
            ["2026-11-01", "v1.0", "Culla-1.0.dmg", "10", "10"],
            ["2026-11-02", "v1.0", "Culla-1.0.dmg", "40", "30"],
            [TODAY, "v1.0", "Culla-1.0.dmg", "57", "17"],
            [TODAY, "v1.1", "Culla-1.1.dmg", "5", "5"],
        ])

    def test_running_twice_a_day_does_not_duplicate(self):
        self.write_csv("downloads.csv", "date,tag,file,total,new\n"
                                        "2026-11-02,v1.0,Culla-1.0.dmg,40,40\n")
        self.github.body = releases(("v1.0", [("Culla-1.0.dmg", 50)]))
        self.run_count("--date", DAY)
        self.github.body = releases(("v1.0", [("Culla-1.0.dmg", 52)]))
        self.run_count("--date", DAY)
        self.run_count("--date", DAY)
        rows = self.csv_rows("downloads.csv")
        self.assertEqual(rows, [
            DOWNLOADS_HEADER,
            ["2026-11-02", "v1.0", "Culla-1.0.dmg", "40", "40"],
            [TODAY, "v1.0", "Culla-1.0.dmg", "52", "12"],  # against 11-02, not against itself
        ])

    def test_lower_count_is_never_negative(self):
        # The asset was deleted and uploaded again; GitHub counts from 0.
        self.write_csv("downloads.csv", "date,tag,file,total,new\n"
                                        "2026-11-02,v1.0,Culla-1.0.dmg,40,40\n")
        self.github.body = releases(("v1.0", [("Culla-1.0.dmg", 3)]))
        self.run_count("--date", DAY)
        self.assertEqual(self.csv_rows("downloads.csv")[-1], [TODAY, "v1.0", "Culla-1.0.dmg", "3", "3"])
        self.github.body = releases(("v1.0", [("Culla-1.0.dmg", 0)]))
        self.run_count("--date", DAY)
        self.assertEqual(self.csv_rows("downloads.csv")[-1], [TODAY, "v1.0", "Culla-1.0.dmg", "0", "0"])

    def test_only_dmg_assets(self):
        self.github.body = releases(("v1.0", [("Culla-1.0.dmg", 4), ("Culla-1.0.zip", 9),
                                              ("Culla-1.0.dmg.sha256", 2), ("Source.tar.gz", 1)]),
                                    ("v0.1", []))
        self.run_count("--date", DAY)
        self.assertEqual(self.csv_rows("downloads.csv")[1:], [[TODAY, "v1.0", "Culla-1.0.dmg", "4", "4"]])

    def test_tags_in_version_order(self):
        self.github.body = releases(("v1.10", [("Culla-1.10.dmg", 1)]), ("v1.2", [("Culla-1.2.dmg", 1)]),
                                    ("v1.9", [("Culla-1.9.dmg", 1)]))
        self.run_count("--date", DAY)
        self.assertEqual([r[1] for r in self.csv_rows("downloads.csv")[1:]], ["v1.2", "v1.9", "v1.10"])

    def assert_soft_failure(self, fetch, message):
        write_log(self.log("access.log"), [page("/en/")])
        self.write_csv("downloads.csv", "date,tag,file,total,new\n2026-11-02,v1.0,Culla-1.0.dmg,40,40\n")
        before = self.csv_rows("downloads.csv")
        err = self.run_count("--date", DAY, fetch=fetch)  # still exits 0
        self.assertEqual(self.csv_rows("downloads.csv"), before)
        self.assertEqual(len(err.strip().splitlines()), 1, err)
        self.assertIn(message, err)
        self.assertTrue(err.startswith("count: "), err)
        self.assertEqual(self.csv_rows("visits.csv")[1], [DAY, "en", "1", "1"])

    def http_error(self, code, headers):
        return urllib.error.HTTPError("https://api.github.com/x", code, "error", headers, None)

    def test_unreachable(self):
        with mock.patch.object(count.urllib.request, "urlopen",
                               side_effect=urllib.error.URLError("Name or service not known")):
            self.assert_soft_failure(count.fetch_url, "could not reach GitHub")

    def test_timeout(self):
        with mock.patch.object(count.urllib.request, "urlopen", side_effect=TimeoutError("timed out")):
            self.assert_soft_failure(count.fetch_url, "could not reach GitHub")

    def test_rate_limited(self):
        error = self.http_error(403, {"X-RateLimit-Remaining": "0"})
        with mock.patch.object(count.urllib.request, "urlopen", side_effect=error):
            self.assert_soft_failure(count.fetch_url, "rate limited")

    def test_http_error(self):
        error = self.http_error(502, {})
        with mock.patch.object(count.urllib.request, "urlopen", side_effect=error):
            self.assert_soft_failure(count.fetch_url, "HTTP 502")

    def test_not_json_or_not_a_list(self):
        self.assert_soft_failure(FakeGitHub(b"<html>oops</html>"), "not JSON")
        self.assert_soft_failure(FakeGitHub(b'{"message": "Not Found"}'), "not a list")

    def test_missing_releases_file(self):
        with redirect_stderr(io.StringIO()) as err:
            self.assertEqual(count.main(["--date", DAY, "--releases-file",
                                         os.path.join(self.stats, "none.json")]), 0)
        self.assertIn("cannot read", err.getvalue())
        self.assertFalse(os.path.exists(os.path.join(self.stats, "downloads.csv")))

    def test_old_format_is_set_aside(self):
        # downloads.csv from the time the disk images were on this server.
        self.write_csv("downloads.csv", "date,version,downloads\n2026-11-01,1.0,7\n")
        self.github.body = releases(("v1.0", [("Culla-1.0.dmg", 9)]))
        err = self.run_count("--date", DAY)
        self.assertIn("other columns", err)
        self.assertEqual(self.csv_rows("downloads.csv"),
                         [DOWNLOADS_HEADER, [TODAY, "v1.0", "Culla-1.0.dmg", "9", "9"]])
        with open(os.path.join(self.stats, "downloads.csv.old-1")) as f:
            self.assertEqual(f.read(), "date,version,downloads\n2026-11-01,1.0,7\n")


if __name__ == "__main__":
    unittest.main()
