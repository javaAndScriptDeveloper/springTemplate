#!/usr/bin/env bash
# Exercises scripts/next-version.sh against a throwaway git repository.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../next-version.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected '$2' got '$1' ($3)"; }

repo="$(mktemp -d)"; trap 'rm -rf "$repo"' EXIT
git -C "$repo" init -q -b main
git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
c() { git -C "$repo" commit -q --allow-empty -m "$1"; }

c "chore: init"
assert_eq "$("$script" -C "$repo")" "0.1.0" "no tag → 0.1.0"

git -C "$repo" tag v0.1.0
c "docs: readme"
assert_eq "$("$script" -C "$repo")" "0.1.1" "docs → patch"

c "feat: thing"
assert_eq "$("$script" -C "$repo")" "0.2.0" "feat → minor"

c "fix(deps-dev): bump x"
assert_eq "$("$script" -C "$repo")" "0.2.0" "fix after feat keeps minor"

c "feat!: breaking"
assert_eq "$("$script" -C "$repo")" "1.0.0" "bang → major"

git -C "$repo" tag v1.0.0
c "refactor: x"
git -C "$repo" commit -q --allow-empty -m "fix: y" -m "BREAKING CHANGE: api removed"
assert_eq "$("$script" -C "$repo")" "2.0.0" "footer → major"

# Highest tag wins even when an older tag is nearer in history.
git -C "$repo" tag v1.9.0 HEAD~1
assert_eq "$("$script" -C "$repo" --current)" "1.9.0" "version sort"
assert_eq "$("$script" -C "$repo")" "2.0.0" "bump computed from highest tag"

echo "next-version: all passed"
