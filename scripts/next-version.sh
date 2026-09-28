#!/usr/bin/env bash
# Prints the next SemVer (without "v") derived from conventional-commit subjects since the highest v* tag.
#
#   feat:                          → minor
#   "!" after the type, or a
#   "BREAKING CHANGE:" footer      → major
#   anything else                  → patch   (every push to main is a release)
#   no tag yet                     → 0.1.0
#
# Usage: next-version.sh [-C <repo>] [--current]
#   --current  print the highest existing tag instead (0.0.0 when there is none)
set -euo pipefail

dir="."
current_only=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -C) dir="$2"; shift 2 ;;
    --current) current_only=true; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "usage: $0 [-C dir] [--current]" >&2; exit 2 ;;
  esac
done
g() { git -C "$dir" "$@"; }

# Highest tag by version sort, not the nearest one in history: a tag on a merged branch must still count.
current="$(g tag -l 'v[0-9]*.[0-9]*.[0-9]*' | sed 's/^v//' | sort -V | tail -n1)"

if $current_only; then
  echo "${current:-0.0.0}"
  exit 0
fi
if [[ -z "$current" ]]; then
  echo "0.1.0"
  exit 0
fi

range="v${current}..HEAD"
bump="patch"
major_re='^[a-z]+(\([^)]*\))?!: '
minor_re='^feat(\([^)]*\))?: '
while IFS= read -r subject; do
  if [[ "$subject" =~ $major_re ]]; then bump="major"; break; fi
  if [[ "$subject" =~ $minor_re ]]; then bump="minor"; fi
done < <(g log --format=%s "$range")
if [[ "$bump" != "major" ]] && g log --format=%b "$range" | grep -q '^BREAKING CHANGE:'; then
  bump="major"
fi

IFS=. read -r major minor patch <<< "$current"
case "$bump" in
  major) echo "$((major + 1)).0.0" ;;
  minor) echo "${major}.$((minor + 1)).0" ;;
  patch) echo "${major}.${minor}.$((patch + 1))" ;;
esac
