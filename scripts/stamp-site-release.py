#!/usr/bin/env python3
"""Point the website's download button at a release.

The site deploy runs this on its checkout with the latest published release,
right before uploading site/, so every release reaches the website without a
commit that bumps the link by hand. The committed page keeps whatever version
it was last stamped with; only the deployed copy changes.

    scripts/stamp-site-release.py v1.4.0 [site/index.html]

It refuses rather than guesses: unless the page holds exactly one download
link and one version label, nothing is written and the deploy stops, so a
redesign cannot quietly ship a stale or broken download.
"""

import re
import sys
from pathlib import Path

DEFAULT_PAGE = Path(__file__).resolve().parents[1] / "site/index.html"

TAG = re.compile(r"v?(\d+\.\d+\.\d+)")
DOWNLOAD = re.compile(
    r"https://github\.com/Schereo/localvoice/releases/download/"
    r"v\d+\.\d+\.\d+/LocalVoice-v\d+\.\d+\.\d+-arm64\.dmg"
)
VERSION_LABEL = re.compile(r"(<span data-release-version>)[^<]*(</span>)")


def version_from_tag(tag):
    """'v1.4.0' or '1.4.0' -> '1.4.0'; dev tags (v1.4.0-dev.3) are refused."""
    match = TAG.fullmatch(tag.strip())
    if match is None:
        raise ValueError(f"not a release tag: {tag!r}")
    return match.group(1)


def download_url(version):
    # The asset name the Build workflow publishes (sign job, "Package").
    return (
        "https://github.com/Schereo/localvoice/releases/download/"
        f"v{version}/LocalVoice-v{version}-arm64.dmg"
    )


def stamp(html, version):
    html, links = DOWNLOAD.subn(download_url(version), html)
    html, labels = VERSION_LABEL.subn(rf"\g<1>{version}\g<2>", html)
    if links != 1 or labels != 1:
        raise ValueError(
            f"expected one download link and one version label, "
            f"found {links} and {labels}"
        )
    return html


def main(argv):
    if len(argv) not in (2, 3):
        print(__doc__.strip(), file=sys.stderr)
        return 2

    page = Path(argv[2]) if len(argv) == 3 else DEFAULT_PAGE
    try:
        version = version_from_tag(argv[1])
        page.write_text(stamp(page.read_text(encoding="utf-8"), version), encoding="utf-8")
    except (OSError, ValueError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    print(f"{page}: download points at LocalVoice {version}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
