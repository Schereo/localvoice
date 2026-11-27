"""Offline tests for stamping the website's download with a release."""

import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "stamp_site_release", ROOT / "scripts/stamp-site-release.py"
)
stamp_site = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(stamp_site)


class StampSiteReleaseTests(unittest.TestCase):
    def test_stamps_the_real_page(self):
        html = (ROOT / "site/index.html").read_text(encoding="utf-8")

        stamped = stamp_site.stamp(html, "9.8.7")

        self.assertIn(
            'href="https://github.com/Schereo/localvoice/releases/download/'
            'v9.8.7/LocalVoice-v9.8.7-arm64.dmg"',
            stamped,
        )
        self.assertIn("Version <span data-release-version>9.8.7</span> ·", stamped)
        # Nothing but the link and the label changes.
        self.assertEqual(len(stamped.splitlines()), len(html.splitlines()))

    def test_stamping_twice_is_stable(self):
        html = (ROOT / "site/index.html").read_text(encoding="utf-8")
        once = stamp_site.stamp(html, "2.0.0")
        self.assertEqual(stamp_site.stamp(once, "2.0.0"), once)

    def test_refuses_a_page_without_the_markers(self):
        with self.assertRaises(ValueError):
            stamp_site.stamp("<p>Version 1.0.0</p>", "2.0.0")

    def test_refuses_a_second_download_link(self):
        link = stamp_site.download_url("1.0.0")
        html = f'<a href="{link}"></a><a href="{link}"></a><span data-release-version>1.0.0</span>'
        with self.assertRaises(ValueError):
            stamp_site.stamp(html, "2.0.0")

    def test_tags(self):
        self.assertEqual(stamp_site.version_from_tag("v1.4.0"), "1.4.0")
        self.assertEqual(stamp_site.version_from_tag("1.4.0\n"), "1.4.0")
        for tag in ("v1.4.0-dev.3", "latest", "v1.4", ""):
            with self.assertRaises(ValueError):
                stamp_site.version_from_tag(tag)

    def test_main_leaves_the_page_alone_on_refusal(self):
        with tempfile.TemporaryDirectory() as directory:
            page = Path(directory) / "index.html"
            page.write_text("<p>no markers</p>", encoding="utf-8")

            self.assertEqual(stamp_site.main(["stamp", "v2.0.0", str(page)]), 1)
            self.assertEqual(page.read_text(encoding="utf-8"), "<p>no markers</p>")


if __name__ == "__main__":
    unittest.main()
