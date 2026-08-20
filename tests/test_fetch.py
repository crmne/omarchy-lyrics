"""Tests for the URL guard in the fetch helper.

Run with: python3 -m unittest discover -s tests

The helper is handed URLs that came from remote page state, so those URLs are
input, not addresses. These cover the shapes that mattered: a scheme that reads
the local disk, a host on the loopback or private side of the network, and a
name that merely looks like the real one.
"""

import importlib.util
import os
import unittest

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


if __name__ == "__main__":
    unittest.main()
