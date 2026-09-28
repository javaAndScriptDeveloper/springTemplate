#!/usr/bin/env bash
# Exercises scripts/rename-package.sh on a pristine export of the repository.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
git -C "$root" archive HEAD | tar -x -C "$tmp"
# Working-tree versions of the script under test and its inputs, so an uncommitted fix is what gets tested.
cp "$root/scripts/rename-package.sh" "$tmp/scripts/"
cp "$root/scripts/tests/rename-package.test.sh" "$tmp/scripts/tests/"
git -C "$tmp" init -q -b main; git -C "$tmp" -c user.email=t@t -c user.name=t add -A >/dev/null
git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "chore: snapshot"

# Refuses a dirty tree.
echo dirty > "$tmp/dirty.txt"
if (cd "$tmp" && scripts/rename-package.sh com.acme.shop shop >/dev/null 2>&1); then fail "ran on a dirty tree"; fi
rm "$tmp/dirty.txt"

(cd "$tmp" && scripts/rename-package.sh com.acme.shop shop >/dev/null)

[[ -f "$tmp/src/main/java/com/acme/shop/Application.java" ]] || fail "main sources not moved"
[[ -f "$tmp/src/test/java/com/acme/shop/TestcontainersConfiguration.java" ]] || fail "test sources not moved"
[[ ! -d "$tmp/src/main/java/com/example" ]] || fail "old package directory left behind"
grep -q '^package com.acme.shop;' "$tmp/src/main/java/com/acme/shop/Application.java" || fail "package line not rewritten"
if grep -rq "com.example.company" "$tmp/src" "$tmp/build.gradle.kts" "$tmp/compose.yml" "$tmp/.env.example" "$tmp/CLAUDE.md" 2>/dev/null; then
  fail "old package name still referenced: $(grep -rl 'com.example.company' "$tmp/src" "$tmp/build.gradle.kts" "$tmp/compose.yml" "$tmp/.env.example" | head -3)"
fi
grep -q 'rootProject.name = "shop"' "$tmp/settings.gradle.kts" || fail "rootProject.name not set"
grep -q '^APP_NAME=shop$' "$tmp/.env.example" || fail "APP_NAME not set in .env.example"
grep -q 'group = "com.acme.shop"' "$tmp/build.gradle.kts" || fail "gradle group not set"
grep -q 'com/acme/shop/Application.class' "$tmp/build.gradle.kts" || fail "coverage exclusions not rewritten"

# The script's own tests and the historical design docs keep the old name; rewriting them breaks CI after a rename.
untouched="$(git -C "$tmp" status --porcelain -- scripts/tests docs/superpowers)"
[[ -z "$untouched" ]] || fail "rename rewrote files that must keep the template name: $untouched"
# And it must exit 0 when run on a tree where nothing matches any more (idempotent, no pipefail death).
git -C "$tmp" -c user.email=t@t -c user.name=t add -A >/dev/null
git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "chore: rename"
(cd "$tmp" && scripts/rename-package.sh com.acme.shop shop >/dev/null) || fail "second run did not exit 0"

echo "rename-package: all passed"
