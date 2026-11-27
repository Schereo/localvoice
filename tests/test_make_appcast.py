"""Offline tests for the update feed builder: picking delta bases and checking the feed."""

import importlib.util
import tempfile
import unittest
from pathlib import Path


SPEC = importlib.util.spec_from_file_location(
    "make_appcast", Path(__file__).resolve().parents[1] / "scripts/make-appcast.py"
)
appcast = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(appcast)

PREFIX = "https://github.com/Schereo/localvoice/releases/download/v1.4.1/"


def release(tag, created, prerelease=False, draft=False):
    return {"tagName": tag, "createdAt": created, "isPrerelease": prerelease, "isDraft": draft}


def shipped(*tags):
    """assets(tag): an appcast and the image for `tags`, only the image for the others."""
    def assets(tag):
        names = {appcast.dmg_name(tag), appcast.dmg_name(tag) + ".sha256"}
        return names | {"appcast.xml"} if tag in tags else names
    return assets


class PreviousReleaseTests(unittest.TestCase):
    RELEASES = [
        release("v1.3.0", "2026-11-25T09:00:00Z"),
        release("v1.4.0", "2026-12-10T09:00:00Z"),
        release("v1.4.1", "2026-12-20T09:00:00Z"),
        release("v1.4.0-dev.40", "2026-12-12T09:00:00Z", prerelease=True),
        release("v1.4.0-dev.41", "2026-12-14T09:00:00Z", prerelease=True),
        release("v1.4.0-dev.42", "2026-12-15T09:00:00Z", prerelease=True),
        release("dev-feed", "2026-12-01T09:00:00Z", prerelease=True),
        release("v1.5.0", "2026-12-21T09:00:00Z", draft=True),
    ]

    def test_newest_releases_with_the_updater(self):
        assets = shipped("v1.4.0", "v1.4.1", "v1.4.0-dev.41", "v1.4.0-dev.42")
        self.assertEqual(appcast.previous_releases(self.RELEASES, assets, "release", "v1.5.1", 2),
                         ["v1.4.1", "v1.4.0"])
        # 1.3.0 has no updater, so it is never a base; the current tag is skipped.
        self.assertEqual(appcast.previous_releases(self.RELEASES, assets, "release", "v1.4.1", 3),
                         ["v1.4.0"])

    def test_dev_channel_only_uses_dev_builds(self):
        assets = shipped("v1.4.0", "v1.4.0-dev.41", "v1.4.0-dev.42")
        self.assertEqual(appcast.previous_releases(self.RELEASES, assets, "dev", "v1.4.0-dev.43", 2),
                         ["v1.4.0-dev.42", "v1.4.0-dev.41"])

    def test_none_before_the_first_release_with_the_updater(self):
        self.assertEqual(appcast.previous_releases(self.RELEASES, shipped(), "release", "v1.4.0", 2), [])

    def test_no_bases_without_deltas(self):
        assets = shipped("v1.4.0", "v1.4.1")
        self.assertEqual(appcast.previous_releases(self.RELEASES, assets, "release", "v1.5.1", 0), [])


def feed(version="312", url=PREFIX + "LocalVoice-v1.4.1-arm64.dmg", signature="sig", deltas=()):
    entries = "".join(
        f'<enclosure url="{PREFIX}{name}" sparkle:deltaFrom="{base}" length="1" '
        f'type="application/octet-stream" sparkle:edSignature="{signed}"/>'
        for name, base, signed in deltas
    )
    return (
        '<?xml version="1.0" standalone="yes"?>'
        '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">'
        f'<channel><title>LocalVoice</title><item><title>1.4.1</title>'
        f'<sparkle:version>{version}</sparkle:version>'
        f'<enclosure url="{url}" length="1" type="application/octet-stream" sparkle:edSignature="{signature}"/>'
        f'<sparkle:deltas>{entries}</sparkle:deltas></item></channel></rss>'
    )


class CheckFeedTests(unittest.TestCase):
    def setUp(self):
        self.out = Path(tempfile.mkdtemp())
        (self.out / "LocalVoice312-305.delta").write_bytes(b"patch")

    def check(self, text):
        return appcast.check_feed(text, PREFIX, "LocalVoice-v1.4.1-arm64.dmg", "312", self.out)

    def test_accepts_a_signed_feed_with_its_deltas(self):
        self.assertEqual(self.check(feed(deltas=[("LocalVoice312-305.delta", "305", "sig")])),
                         ["LocalVoice312-305.delta"])

    def test_refuses_what_would_not_update_anyone(self):
        cases = {
            "wrong build": feed(version="311"),
            "wrong image": feed(url=PREFIX + "Other.dmg"),
            "unsigned image": feed(signature=""),
            "missing delta": feed(deltas=[("LocalVoice312-300.delta", "300", "sig")]),
            "unsigned delta": feed(deltas=[("LocalVoice312-305.delta", "305", "")]),
            "unsafe name": feed(deltas=[("../LocalVoice312-305.delta", "305", "sig")]),
        }
        for name, text in cases.items():
            with self.subTest(name), self.assertRaises(ValueError):
                self.check(text)

    def test_refuses_more_than_one_item(self):
        text = feed().replace("</channel>", "<item><title>old</title></item></channel>")
        with self.assertRaises(ValueError):
            self.check(text)


if __name__ == "__main__":
    unittest.main()
