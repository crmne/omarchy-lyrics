"""Tests for the URL guard in the fetch helper.

Run with: python3 -m unittest discover -s tests

The helper is handed URLs that came from remote page state, so those URLs are
input, not addresses. These cover the shapes that mattered: a scheme that reads
the local disk, a host on the loopback or private side of the network, and a
name that merely looks like the real one.
"""

import argparse
import gzip
import http.client
import importlib.machinery
import importlib.util
import io
import json
import os
import sys
import time
import unittest
from contextlib import redirect_stdout
from unittest import mock

HELPER = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "bin", "lrclib")
spec = importlib.util.spec_from_loader("lrclib", importlib.machinery.SourceFileLoader("lrclib", HELPER))
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class CheckUrl(unittest.TestCase):
    def test_allows_the_site_and_its_subdomains(self):
        for url in ("https://lrclib.net/api/get?a=b",
                    "https://api.lrclib.net/x"):
            self.assertEqual(helper.check_url(url), url)

    def test_refuses_schemes_that_are_not_https(self):
        # file:// reads the disk; http:// is both downgradeable and was the
        # route to loopback and link-local services.
        for url in ("file:///etc/passwd",
                    "http://lrclib.net/x",
                    "http://127.0.0.1:8080/x",
                    "http://[::1]/x",
                    "http://169.254.169.254/latest/meta-data/",
                    "ftp://lrclib.net/x",
                    "/etc/passwd",
                    ""):
            with self.assertRaises(helper.BlockedUrl, msg=url):
                helper.check_url(url)

    def test_refuses_other_hosts_however_they_are_dressed(self):
        for url in ("https://evil.example/x",
                    "https://127.0.0.1/x",
                    "https://notlrclib.net/x",
                    "https://lrclib.net.evil.example/x",
                    "https://evil.example/?next=https://lrclib.net/x"):
            with self.assertRaises(helper.BlockedUrl, msg=url):
                helper.check_url(url)

    def test_refuses_authorities_a_browser_would_read_differently(self):
        # A backslash is a separator to the parser browsers use, so this reads
        # as ours to anything splitting on "@" while a browser goes elsewhere.
        for url in ("https://evil.example\\@lrclib.net/",
                    "https://evil.example@lrclib.net/",
                    "https://lrclib.net:8080/x",
                    "https://lrclib.net\t.evil.example/x",
                    "https://lrclib.net /x"):
            with self.assertRaises(helper.BlockedUrl, msg=url):
                helper.check_url(url % ())

    def test_every_redirect_hop_is_checked_too(self):
        # An allowed host can still redirect anywhere, so the handler re-checks
        # rather than trusting the first URL it was given.
        handler = helper.GuardedRedirects()
        self.assertTrue(hasattr(handler, "redirect_request"))
        with self.assertRaises(helper.BlockedUrl):
            helper.check_url("https://evil.example/after-redirect")


class Redirects(unittest.TestCase):
    """A redirect's body never reaches memory: only the final answer is read,
    and that one through read_limited."""

    class Endless:
        """A redirect body with no end, until it is closed."""

        def __init__(self):
            self.closed = False
            self.served = 0

        def read(self, size=-1):
            if self.closed:
                return b""
            self.served += 1 << 20
            return b"x" * (1 << 20)

        def close(self):
            self.closed = True

    def follow(self, location):
        handler = helper.GuardedRedirects()
        handler.parent = mock.Mock()
        body = self.Endless()
        request = helper.urllib.request.Request("https://lrclib.net/api/get")
        request.timeout = 5
        headers = http.client.HTTPMessage()
        headers["Location"] = location
        handler.http_error_302(request, body, 302, "Found", headers)
        return handler.parent, body

    def test_a_redirect_body_is_never_read(self):
        parent, body = self.follow("https://lrclib.net/api/get?again=1")
        parent.open.assert_called_once()
        self.assertEqual(parent.open.call_args.args[0].full_url, "https://lrclib.net/api/get?again=1")
        self.assertTrue(body.closed)
        self.assertEqual(body.served, 0)

    def test_a_redirect_elsewhere_is_refused_before_anything_is_read(self):
        with self.assertRaises(helper.BlockedUrl):
            self.follow("https://evil.example/api/get")


class MissingMetadata(unittest.TestCase):
    """A browser playing a video reports a title and no artist."""

    def test_get_without_an_artist_asks_nothing_and_reports_no_result(self):
        # /api/get answers 400 without both names, which is not a fault worth
        # putting in front of anyone: there is simply no exact match to ask for.
        args = argparse.Namespace(artist="", title="Some Video Title", album="",
                                  duration=0, no_cache=True, ttl=0)
        self.assertEqual(helper.cmd_get(args), {"ok": True, "result": None})

        args.artist, args.title = "Tool", "   "
        self.assertEqual(helper.cmd_get(args), {"ok": True, "result": None})


class FakeResponse(io.BytesIO):
    def __init__(self, body, headers=None):
        super().__init__(body)
        self.headers = headers or {}


class ResponseLimits(unittest.TestCase):
    """A response is refused before it can outgrow the shell's memory."""

    def test_reads_an_ordinary_response_plain_or_gzipped(self):
        body = b'{"trackName": "Song"}'
        self.assertEqual(helper.read_limited(FakeResponse(body)), body)
        packed = FakeResponse(gzip.compress(body), {"Content-Encoding": "gzip"})
        self.assertEqual(helper.read_limited(packed), body)

    def test_refuses_a_body_larger_than_the_wire_limit(self):
        body = b"x" * (helper.MAX_RESPONSE_BYTES + 1)
        with self.assertRaises(helper.TooLarge):
            helper.read_limited(FakeResponse(body))

    def test_refuses_a_declared_length_before_reading_it(self):
        response = FakeResponse(b"", {"Content-Length": str(helper.MAX_RESPONSE_BYTES + 1)})
        with self.assertRaises(helper.TooLarge):
            helper.read_limited(response)

    def test_refuses_gzip_that_inflates_past_the_decoded_limit(self):
        # A few kilobytes on the wire, far more once expanded.
        bomb = gzip.compress(b"\0" * (helper.MAX_DECODED_BYTES + 1))
        self.assertLess(len(bomb), helper.MAX_RESPONSE_BYTES)
        with self.assertRaises(helper.TooLarge):
            helper.read_limited(FakeResponse(bomb, {"Content-Encoding": "gzip"}))

    def test_refuses_encodings_it_cannot_bound(self):
        with self.assertRaises(ValueError):
            helper.read_limited(FakeResponse(b"x", {"Content-Encoding": "br"}))


class OutputLimits(unittest.TestCase):
    """What the helper prints stays under the cap the shell collects."""

    def record(self, lyrics):
        return {"id": 1, "artistName": "A", "trackName": "T", "albumName": "",
                "duration": 200, "plainLyrics": lyrics, "syncedLyrics": lyrics}

    def test_lyrics_are_cut_at_a_whole_line(self):
        line = "la la la\n"
        lyrics = line * (helper.MAX_LYRICS_CHARS // len(line) + 10)
        shaped = helper.shape(self.record(lyrics))
        self.assertLessEqual(len(shaped["plain"]), helper.MAX_LYRICS_CHARS)
        self.assertTrue(shaped["plain"].endswith("la la la"))

    def test_fields_that_are_not_what_they_claim_become_empty(self):
        shaped = helper.shape({"artistName": ["x"], "duration": "long", "id": {}})
        self.assertEqual((shaped["artist"], shaped["duration"], shaped["id"]), ("", 0, 0))
        self.assertIsNone(helper.shape(["not", "a", "record"]))

    def test_search_output_drops_results_until_it_fits(self):
        # Non-ASCII is escaped six bytes a character, the worst case per field.
        big = helper.shape(self.record("\u00e9" * helper.MAX_LYRICS_CHARS))
        encoded = helper.encode({"ok": True, "results": [big] * 50})
        self.assertLess(len(encoded), helper.MAX_OUTPUT_BYTES)
        results = json.loads(encoded)["results"]
        self.assertGreater(len(results), 0)
        self.assertLessEqual(len(results), helper.MAX_RESULTS)

    def test_oversized_cache_entries_are_capped_on_the_way_out(self):
        stale = {"artist": "A" * 10000, "plain": "x" * (helper.MAX_LYRICS_CHARS * 2)}
        result = json.loads(helper.encode({"ok": True, "result": stale}))["result"]
        self.assertEqual(len(result["artist"]), helper.MAX_FIELD_CHARS)
        self.assertEqual(len(result["plain"]), helper.MAX_LYRICS_CHARS)


class TrackStaysOffTheCommandLine(unittest.TestCase):
    """What is playing arrives in the environment, which only its owner can
    read, never in the arguments, which every user can (/proc/<pid>/cmdline)."""

    TRACK = {"LRCLIB_ARTIST": "Invented Artist", "LRCLIB_TITLE": "Made Up Song",
             "LRCLIB_ALBUM": "Imaginary Album", "LRCLIB_DURATION": "241"}

    def run_main(self, argv, environ, fetch):
        out = io.StringIO()
        with mock.patch.object(sys, "argv", ["lrclib"] + argv), \
                mock.patch.dict(os.environ, environ), \
                mock.patch.object(helper, "fetch", fetch), \
                redirect_stdout(out):
            code = helper.main()
            leftover = {k: os.environ.get(k) for k in environ}
        return code, json.loads(out.getvalue()), leftover

    def test_get_reads_the_track_from_the_environment(self):
        seen = {}

        def fetch(path, params, **kwargs):
            seen[path] = params
            return None

        code, payload, leftover = self.run_main(["--no-cache", "get"], self.TRACK, fetch)
        self.assertEqual(code, 0)
        self.assertEqual(payload, {"ok": True, "result": None})
        self.assertEqual(seen["/get"], {"artist_name": "Invented Artist",
                                        "track_name": "Made Up Song",
                                        "album_name": "Imaginary Album",
                                        "duration": 241})
        # Popped, so nothing the helper starts inherits it.
        self.assertEqual(set(leftover.values()), {None})

    def test_search_reads_the_track_from_the_environment(self):
        seen = {}

        def fetch(path, params, **kwargs):
            seen[path] = params
            return []

        code, payload, _ = self.run_main(["--no-cache", "search"], self.TRACK, fetch)
        self.assertEqual((code, payload), (0, {"ok": True, "results": []}))
        self.assertEqual(seen["/search"], {"artist_name": "Invented Artist",
                                           "track_name": "Made Up Song"})

    def test_track_options_on_the_command_line_are_refused(self):
        for argv in (["get", "--artist", "A", "--title", "T"],
                     ["search", "--title", "T"]):
            with mock.patch.object(sys, "argv", ["lrclib"] + argv), \
                    redirect_stdout(io.StringIO()), \
                    mock.patch("sys.stderr", io.StringIO()), \
                    self.assertRaises(SystemExit, msg=argv):
                helper.main()

    def test_a_duration_that_is_not_a_number_is_unknown(self):
        for value in ("", "abc", "nan", "-5", "inf"):
            track = helper.track_from_environment({"LRCLIB_DURATION": value})
            self.assertEqual(track["duration"], 0, value)
        self.assertEqual(helper.track_from_environment({})["artist"], "")


class BracketedTitles(unittest.TestCase):
    """A credit in brackets keeps LRCLIB's search from finding the song, so a
    search that finds nothing asks again without it, by the same artist."""

    RECORD = {"id": 7, "artistName": "Invented Artist", "trackName": "Made Up Song",
              "albumName": "Imaginary Album", "duration": 241, "syncedLyrics": "[00:01.00] An invented line"}

    def search(self, environ, answers):
        asked = []

        def fetch(path, params, **kwargs):
            asked.append(params)
            return answers.get(params["track_name"], [])

        track = dict(TrackStaysOffTheCommandLine.TRACK, **environ)
        code, payload, _ = TrackStaysOffTheCommandLine.run_main(self, ["--no-cache", "search"], track, fetch)
        self.assertEqual(code, 0)
        return asked, payload["results"]

    def test_a_search_that_finds_nothing_asks_again_without_the_brackets(self):
        asked, results = self.search({"LRCLIB_TITLE": "Made Up Song (Invented Composer)"},
                                     {"Made Up Song": [self.RECORD]})
        self.assertEqual(asked, [{"artist_name": "Invented Artist", "track_name": "Made Up Song (Invented Composer)"},
                                 {"artist_name": "Invented Artist", "track_name": "Made Up Song"}])
        self.assertEqual([r["track"] for r in results], ["Made Up Song"])

    def test_a_search_that_finds_the_song_asks_once(self):
        title = "Made Up Song (Invented Composer)"
        asked, results = self.search({"LRCLIB_TITLE": title}, {title: [dict(self.RECORD, trackName=title)]})
        self.assertEqual(len(asked), 1)
        self.assertEqual(len(results), 1)

    def test_without_an_artist_the_shorter_title_is_not_asked_for(self):
        asked, results = self.search({"LRCLIB_ARTIST": "", "LRCLIB_TITLE": "Made Up Song (Invented Cover)"},
                                     {"Made Up Song": [self.RECORD]})
        self.assertEqual(asked, [{"artist_name": "", "track_name": "Made Up Song (Invented Cover)"}])
        self.assertEqual(results, [])

    def test_only_a_title_with_something_left_beside_its_brackets_is_shortened(self):
        self.assertEqual(helper.without_brackets("Made Up Song (Invented Composer)"), "Made Up Song")
        self.assertEqual(helper.without_brackets("(I Can't Get No) Satisfaction"), "Satisfaction")
        self.assertEqual(helper.without_brackets("Made Up Song [From \"Invented Film\"]"), "Made Up Song")
        for title in ("Made Up Song", "(Only Brackets)", "Made Up Song (unclosed", ""):
            self.assertEqual(helper.without_brackets(title), "", title)


class Deadline(unittest.TestCase):
    """A server that answers slowly enough cannot hold the helper open."""

    def test_a_lookup_that_outlives_the_deadline_is_abandoned(self):
        def fetch(path, params, **kwargs):
            time.sleep(5)
            return None

        environ = dict(TrackStaysOffTheCommandLine.TRACK, LRCLIB_DEADLINE="1")
        started = time.monotonic()
        code, payload, _ = TrackStaysOffTheCommandLine.run_main(
            self, ["--no-cache", "get"], environ, fetch)
        self.assertLess(time.monotonic() - started, 4)
        self.assertEqual(code, 1)
        self.assertEqual(payload["code"], "timeout")

    def test_the_deadline_cannot_be_raised_past_the_ceiling(self):
        track = helper.track_from_environment({"LRCLIB_DEADLINE": "99999"})
        self.assertEqual(track["deadline"], helper.DEADLINE_SECONDS)
        self.assertEqual(helper.track_from_environment({"LRCLIB_DEADLINE": "x"})["deadline"],
                         helper.DEADLINE_SECONDS)


if __name__ == "__main__":
    unittest.main()
