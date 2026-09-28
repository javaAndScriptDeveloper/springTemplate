#!/usr/bin/env bash
# Checks commit subjects against the Conventional Commits format the release pipeline relies on.
#
#   <type>(<scope>)!: <summary>      type ∈ feat fix perf refactor docs test build ci chore style revert
#
# Usage:
#   lint-commits.sh --message <file>                     one message (the commit-msg hook)
#   lint-commits.sh [-C <repo>] <rev-range>              every commit in the range (CI, pull requests)
#   lint-commits.sh [-C <repo>] --push-range BEFORE SHA  the commits of one push (CI, main). An all-zero BEFORE
#                                                        (first push, new branch) lints SHA alone: history inherited
#                                                        from a template must never block a release.
set -euo pipefail

pattern='^(feat|fix|perf|refactor|docs|test|build|ci|chore|style|revert)(\([a-z0-9._/-]+\))?!?: .+'
# Git-generated subjects that carry no release information but must not block a merge.
allow='^(Merge |Revert ")'

ok() { [[ "$1" =~ $pattern || "$1" =~ $allow ]]; }

explain() {
  cat >&2 <<'MSG'
Commit subjects must look like:  <type>(<optional-scope>)!: <summary>
  types:  feat fix perf refactor docs test build ci chore style revert
  scope:  lowercase letters, digits, . _ / -
  "!"     marks a breaking change (major version bump); feat bumps minor; the rest bump patch
  e.g.    feat(api): add /orders endpoint      fix: handle empty cart      feat!: drop v1 endpoints
MSG
}

dir="."
if [[ "${1:-}" == "-C" ]]; then dir="$2"; shift 2; fi

if [[ "${1:-}" == "--message" ]]; then
  # First non-comment, non-empty line is the subject (git passes the whole message file to commit-msg).
  subject="$(grep -v '^#' "$2" | grep -m1 -v '^[[:space:]]*$' || true)"
  if ok "$subject"; then exit 0; fi
  echo "Rejected commit subject: $subject" >&2
  explain
  exit 1
fi

if [[ "${1:-}" == "--push-range" ]]; then
  [[ $# -eq 3 ]] || { echo "usage: $0 [-C dir] --push-range BEFORE SHA" >&2; exit 2; }
  if [[ "$2" =~ ^0+$ ]] || ! git -C "$dir" cat-file -e "$2^{commit}" 2>/dev/null; then
    range="$3 -1"
  else
    range="$2..$3"
  fi
  set -- "$range"
fi

[[ $# -eq 1 ]] || { echo "usage: $0 --message <file> | [-C dir] <rev-range> | [-C dir] --push-range BEFORE SHA" >&2; exit 2; }
status=0
while IFS= read -r subject; do
  if ! ok "$subject"; then
    echo "Bad commit subject: $subject" >&2
    status=1
  fi
done < <(git -C "$dir" log --format=%s $1)
[[ $status -eq 0 ]] || explain
exit $status
