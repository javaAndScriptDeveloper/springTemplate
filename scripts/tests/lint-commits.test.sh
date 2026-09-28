#!/usr/bin/env bash
# Exercises scripts/lint-commits.sh in both --message and <range> modes.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../lint-commits.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

good=(
  "feat: add thing"
  "fix(api): handle null"
  "build(deps-dev): bump x from 1 to 2"
  "feat!: drop v1 endpoints"
  "refactor(db.migrations): rename table"
  "Merge branch 'x' into main"
  "Revert \"feat: add thing\""
)
bad=(
  "Add thing"
  "feat:no space"
  "Feat: caps"
  "feature: wrong type"
  "feat(Scope): uppercase scope"
)
for m in "${good[@]}"; do
  printf '%s\n' "$m" > "$tmp/msg"
  "$script" --message "$tmp/msg" >/dev/null || fail "rejected good subject: $m"
done
for m in "${bad[@]}"; do
  printf '%s\n' "$m" > "$tmp/msg"
  if "$script" --message "$tmp/msg" >/dev/null 2>&1; then fail "accepted bad subject: $m"; fi
done

# Comment lines in a message file (as git passes them to commit-msg) are ignored.
printf '# Please enter the commit message\nfeat: real subject\n' > "$tmp/msg"
"$script" --message "$tmp/msg" >/dev/null || fail "comment line treated as subject"

repo="$tmp/repo"; git init -q -b main "$repo"
git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
git -C "$repo" commit -q --allow-empty -m "chore: init"
git -C "$repo" tag v0.1.0
git -C "$repo" commit -q --allow-empty -m "feat: ok"
"$script" -C "$repo" v0.1.0..HEAD >/dev/null || fail "range with good commits rejected"
git -C "$repo" commit -q --allow-empty -m "bad subject"
if out="$("$script" -C "$repo" v0.1.0..HEAD 2>&1)"; then fail "range with bad commit accepted"; fi
[[ "$out" == *"bad subject"* ]] || fail "offending subject not reported: $out"

# --push-range BEFORE AFTER: lints only the pushed commits; the all-zero BEFORE (new branch / first push) means "HEAD
# only", never the whole history — a template's inherited "Initial commit" must not deadlock releases.
git -C "$repo" commit -q --allow-empty -m "fix: newest"
zero="0000000000000000000000000000000000000000"
"$script" -C "$repo" --push-range "$zero" HEAD >/dev/null || fail "zero BEFORE should lint HEAD only (which is good)"
first="$(git -C "$repo" rev-list --max-parents=0 HEAD)"
if "$script" -C "$repo" --push-range "$first" HEAD >/dev/null 2>&1; then fail "push range containing 'bad subject' accepted"; fi
"$script" -C "$repo" --push-range HEAD~1 HEAD >/dev/null || fail "push range with one good commit rejected"

echo "lint-commits: all passed"
