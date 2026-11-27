#!/usr/bin/env python3
"""Build the Sparkle update feed for a new release, with delta patches.

The release workflow runs this after the disk image is signed and notarized:

  SPARKLE_ED_PRIVATE_KEY=… scripts/make-appcast.py --channel release --tag v1.4.0 \\
      --build-number 312 --dmg build/LocalVoice-v1.4.0-arm64.dmg --notes notes.md \\
      --sparkle build/sparkle/2.10.1 --out build/updates

It downloads the disk images of the last few releases of the same channel that
already ship the updater (they have an appcast.xml), lets Sparkle's
generate_appcast compute a delta patch from each of them to the new app, and
signs the image and the patches with the EdDSA key. The result in --out:

  appcast.xml                  the feed: one item, the new version, with its deltas
  LocalVoice<new>-<old>.delta  one patch per earlier version (a few MB instead of the image)
  upload.txt                   the files to attach to the release, one per line

Copies that are older, or that differ from the published app (the patch checks
every file first), download the full image instead; Sparkle falls back on its own.

For a dry run without GitHub, pass the earlier images with --base and point the
feed at a local server with --url-prefix.
"""

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ElementTree


SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
CHANNELS = {
    "release": re.compile(r"v\d+\.\d+\.\d+"),
    "dev": re.compile(r"v\d+\.\d+\.\d+-dev\.\d+"),
}
FEED = "appcast.xml"


def dmg_name(tag):
    # The asset name the Build workflow publishes (sign job, "Disk image").
    return f"LocalVoice-{tag}-arm64.dmg"


def gh(*arguments):
    return subprocess.run(["gh", *arguments], check=True, capture_output=True, text=True).stdout


def previous_releases(releases, assets, channel, tag, limit):
    """Tags of the newest earlier releases of `channel` whose app has the updater.

    `releases` is `gh release list --json tagName,isPrerelease,isDraft,createdAt`;
    `assets(tag)` returns the asset names of one release. Only releases that ship
    an appcast.xml are bases for a patch: older apps have no updater to apply one."""
    if limit <= 0:
        return []
    pattern = CHANNELS[channel]
    candidates = [
        release for release in releases
        if pattern.fullmatch(release["tagName"]) and release["tagName"] != tag and not release.get("isDraft")
        and release.get("isPrerelease", False) == (channel == "dev")
    ]
    candidates.sort(key=lambda release: release["createdAt"], reverse=True)
    found = []
    # A handful is plenty: releases without the updater only get older from here.
    for release in candidates[:limit + 5]:
        names = assets(release["tagName"])
        if FEED in names and dmg_name(release["tagName"]) in names:
            found.append(release["tagName"])
            if len(found) == limit:
                break
    return found


def check_feed(text, prefix, image, build_number, out):
    """Refuse a feed that would not update anyone correctly; return its delta files.

    `text` is what generate_appcast just wrote in this run, not downloaded input."""
    root = ElementTree.fromstring(text)
    items = root.findall("./channel/item")
    if len(items) != 1:
        raise ValueError(f"expected one item in the feed, found {len(items)}")
    item = items[0]
    version = item.findtext(f"{{{SPARKLE_NS}}}version")
    if version != build_number:
        raise ValueError(f"the feed offers build {version}, not {build_number}")
    enclosure = item.find("enclosure")
    if enclosure is None or enclosure.get("url") != prefix + image:
        raise ValueError("the feed does not point at the new disk image")
    if not enclosure.get(f"{{{SPARKLE_NS}}}edSignature"):
        raise ValueError("the disk image is not signed with the EdDSA key")
    deltas = []
    for delta in item.findall(f"./{{{SPARKLE_NS}}}deltas/enclosure"):
        url = delta.get("url", "")
        name = url[len(prefix):] if url.startswith(prefix) else ""
        if not re.fullmatch(r"[A-Za-z0-9._-]+\.delta", name) or not (out / name).is_file():
            raise ValueError(f"delta {url!r} is not a file next to the feed")
        if not delta.get(f"{{{SPARKLE_NS}}}edSignature"):
            raise ValueError(f"delta {name} is not signed with the EdDSA key")
        deltas.append(name)
    return deltas


def app_build_number(dmg):
    """CFBundleVersion of the app inside a disk image."""
    mount = Path(subprocess.run(["/usr/bin/mktemp", "-d"], check=True, capture_output=True,
                                text=True).stdout.strip())
    subprocess.run(["/usr/bin/hdiutil", "attach", "-quiet", "-nobrowse", "-readonly",
                    "-mountpoint", str(mount), str(dmg)], check=True)
    try:
        info = plistlib.loads((mount / "LocalVoice.app/Contents/Info.plist").read_bytes())
        return str(info["CFBundleVersion"])
    finally:
        subprocess.run(["/usr/bin/hdiutil", "detach", "-quiet", str(mount)], check=True)
        mount.rmdir()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--channel", choices=sorted(CHANNELS), required=True)
    parser.add_argument("--tag", required=True, help="the release being published, e.g. v1.4.0")
    parser.add_argument("--build-number", required=True, help="CFBundleVersion of the new app")
    parser.add_argument("--dmg", type=Path, required=True, help="the signed, notarized disk image")
    parser.add_argument("--notes", type=Path, required=True, help="release notes (Markdown)")
    parser.add_argument("--sparkle", type=Path, required=True, help="directory from scripts/fetch-sparkle.sh")
    parser.add_argument("--out", type=Path, required=True, help="empty or missing output directory")
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "Schereo/localvoice"))
    parser.add_argument("--deltas", type=int, default=2, help="patches from this many earlier versions")
    parser.add_argument("--base", type=Path, action="append", default=[],
                        help="an earlier disk image to patch from, instead of looking up releases (repeatable)")
    parser.add_argument("--url-prefix", help="where the release's files are served "
                                             "(default: the GitHub release of --tag)")
    args = parser.parse_args()

    if not CHANNELS[args.channel].fullmatch(args.tag):
        parser.error(f"{args.tag} is not a {args.channel} tag.")
    if args.dmg.name != dmg_name(args.tag):
        parser.error(f"Expected the disk image {dmg_name(args.tag)}, got {args.dmg.name}.")
    key = os.environ.get("SPARKLE_ED_PRIVATE_KEY", "").strip()
    if not key:
        sys.exit("SPARKLE_ED_PRIVATE_KEY is not set.")
    if args.out.exists() and any(args.out.iterdir()):
        sys.exit(f"{args.out} is not empty.")
    if app_build_number(args.dmg) != args.build_number:
        sys.exit(f"The app in {args.dmg.name} is not build {args.build_number}.")
    args.out.mkdir(parents=True, exist_ok=True)

    if args.base:
        for image in args.base:
            shutil.copy2(image, args.out / image.name)
        print(f"Delta bases: {', '.join(image.name for image in args.base)}", flush=True)
    else:
        releases = json.loads(gh("release", "list", "--repo", args.repo, "--limit", "100",
                                 "--json", "tagName,isPrerelease,isDraft,createdAt"))
        assets = lambda tag: {asset["name"] for asset in json.loads(
            gh("release", "view", tag, "--repo", args.repo, "--json", "assets"))["assets"]}
        bases = previous_releases(releases, assets, args.channel, args.tag, args.deltas)
        print(f"Delta bases: {', '.join(bases) or 'none (no earlier release has the updater)'}", flush=True)
        for tag in bases:
            gh("release", "download", tag, "--repo", args.repo, "--pattern", dmg_name(tag), "--dir", str(args.out))

    shutil.copy2(args.dmg, args.out / args.dmg.name)
    # generate_appcast embeds the .md next to an archive as the item's release notes.
    shutil.copy2(args.notes, args.out / (args.dmg.stem + ".md"))
    prefix = args.url_prefix or f"https://github.com/{args.repo}/releases/download/{args.tag}/"
    if not prefix.endswith("/"):
        prefix += "/"
    subprocess.run([
        str(args.sparkle / "bin/generate_appcast"), "--ed-key-file", "-",
        "--download-url-prefix", prefix, "--link", f"https://github.com/{args.repo}/releases/tag/{args.tag}",
        "--embed-release-notes", "--maximum-versions", "1", "--maximum-deltas", str(args.deltas),
        str(args.out),
    ], input=key + "\n", text=True, check=True)

    feed = args.out / FEED
    try:
        deltas = check_feed(feed.read_text(encoding="utf-8"), prefix, args.dmg.name, args.build_number, args.out)
    except (OSError, ValueError, ElementTree.ParseError) as error:
        sys.exit(f"Refusing the generated feed: {error}")
    # Only the feed and the patches are new; the images already live on their releases.
    (args.out / "upload.txt").write_text("".join(f"{args.out / name}\n" for name in [FEED, *deltas]))
    for name in deltas:
        size = (args.out / name).stat().st_size
        print(f"  {name}: {size / 1_048_576:.1f} MB" if size >= 100_000 else f"  {name}: {size / 1024:.0f} KB")
    print(f"Feed for build {args.build_number} with {len(deltas)} delta(s): {feed}")


if __name__ == "__main__":
    main()
