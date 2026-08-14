#!/bin/bash

# Cut a release: bump VERSION, promote the Unreleased section of the changelog
# to the new version, commit, tag.
#
# Kept deliberately dumb — it refuses rather than guesses, because the failure
# mode of a clever release script is a tag that does not match what shipped.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$PROJECT_DIR/VERSION"
CHANGELOG="$PROJECT_DIR/CHANGELOG.md"
REPO_URL="https://github.com/Schereo/localvoice"

fail() {
  echo "Error: $*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: ./scripts/release.sh <version>

Bumps VERSION, moves everything under "## [Unreleased]" in CHANGELOG.md into a
section for the new version, commits both, and creates an annotated tag.

  ./scripts/release.sh 1.2.0

Push it afterwards with:

  git push && git push --tags

Then publish the release notes:

  gh release create v1.2.0 --notes "$(./scripts/release.sh --notes 1.2.0)"

Options:
  --notes <version>   Print the changelog section for a version and exit.
                      Does not modify anything.
USAGE
}

# Extract one version's section from the changelog, without its heading.
notes_for() {
  local version="$1"
  awk -v want="## [$version]" '
    index($0, want) == 1 { capture = 1; next }
    capture && /^## \[/   { exit }
    capture               { print }
  ' "$CHANGELOG" | sed -e '/./,$!d' | awk 'NF {blank = 0; print; next} {blank++; if (blank < 2) print}'
}

if [[ "${1:-}" == "--notes" ]]; then
  [[ -n "${2:-}" ]] || fail "--notes needs a version."
  notes="$(notes_for "$2")"
  [[ -n "$notes" ]] || fail "No changelog section found for $2."
  printf '%s\n' "$notes"
  exit 0
fi

if [[ $# -ne 1 || "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit $(( $# == 1 ? 0 : 1 ))
fi

NEW_VERSION="$1"
[[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  fail "Version must be MAJOR.MINOR.PATCH, e.g. 1.2.0 — got '$NEW_VERSION'."

cd "$PROJECT_DIR"

[[ -f "$VERSION_FILE" ]] || fail "VERSION not found."
[[ -f "$CHANGELOG" ]] || fail "CHANGELOG.md not found."

CURRENT_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
[[ "$NEW_VERSION" != "$CURRENT_VERSION" ]] ||
  fail "VERSION already says $NEW_VERSION."

git diff --quiet && git diff --cached --quiet ||
  fail "Working tree is dirty. Commit or stash first."

git rev-parse -q --verify "refs/tags/v$NEW_VERSION" >/dev/null &&
  fail "Tag v$NEW_VERSION already exists."

# An empty Unreleased section means there is nothing to release, which is
# almost always a forgotten changelog entry rather than an intentional release.
UNRELEASED="$(notes_for "Unreleased")"
[[ -n "${UNRELEASED//[[:space:]]/}" ]] ||
  fail "The Unreleased section is empty — write the changelog entry first."

TODAY="$(date +%Y-%m-%d)"

printf '%s\n' "$NEW_VERSION" > "$VERSION_FILE"

# Open a fresh Unreleased section above the new one, and add the compare links
# at the bottom so they keep pointing at the right range.
python3 - "$CHANGELOG" "$NEW_VERSION" "$CURRENT_VERSION" "$TODAY" "$REPO_URL" <<'PY'
import re
import sys

path, new_version, previous_version, today, repo_url = sys.argv[1:6]

with open(path, encoding="utf-8") as handle:
    text = handle.read()

text = text.replace(
    "## [Unreleased]\n",
    f"## [Unreleased]\n\n## [{new_version}] — {today}\n",
    1,
)

text = re.sub(
    r"^\[Unreleased\]: .*$",
    f"[Unreleased]: {repo_url}/compare/v{new_version}...HEAD\n"
    f"[{new_version}]: {repo_url}/compare/v{previous_version}...v{new_version}",
    text,
    count=1,
    flags=re.MULTILINE,
)

with open(path, "w", encoding="utf-8") as handle:
    handle.write(text)
PY

git add "$VERSION_FILE" "$CHANGELOG"
git commit -q -m "Release $NEW_VERSION"
git tag -a "v$NEW_VERSION" -m "LocalVoice $NEW_VERSION"

echo "Released $NEW_VERSION."
echo
echo "  git push && git push --tags"
echo "  gh release create v$NEW_VERSION --notes \"\$(./scripts/release.sh --notes $NEW_VERSION)\""
