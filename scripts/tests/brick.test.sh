#!/usr/bin/env bash
# Exercises scripts/brick.sh against a fixture repository: add, add again, remove, remove again, unknown brick,
# include insertion/removal, env marker blocks, skill install, lockfile refresh, and that a brick's Java is never
# copied into the service (it is a Gradle subproject, included by settings.gradle.kts).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
mkdir -p "$repo/scripts" "$repo/deploy" "$repo/services/app/src/main/java" "$repo/services/app/src/test/java" \
  "$repo/bricks/demo/java/src/main/java/template/bricks/demo" \
  "$repo/bricks/demo/skill" "$repo/bricks/demo2" "$repo/.claude/skills"
cp "$root/scripts/brick.sh" "$repo/scripts/"
cat > "$repo/gradlew" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GRADLE_LOG"
[[ "${GRADLE_FAIL:-0}" != 1 ]] || exit 1
EOF
chmod +x "$repo/gradlew"
export GRADLE_LOG="$tmp/gradle.log"
printf '# header comment\nservices:\n  db:\n    image: postgres\n' > "$repo/compose.yml"
printf 'name: ${COMPOSE_PROJECT_NAME:?}\nservices:\n  app:\n    image: x\n' > "$repo/deploy/compose.prod.yml"
printf '# Local defaults.\nAPP_NAME=x\n' > "$repo/.env.example"
printf 'DOMAIN=\n' > "$repo/deploy/.env.prod.example"
printf 'group = "com.acme.shop"\n' > "$repo/services/app/build.gradle.kts"
printf '# comment\n' > "$repo/.bricks"
# Brick "demo": everything a brick can carry.
printf '# demo: a brick with everything\n' > "$repo/bricks/demo/README.md"
printf 'services:\n  demo:\n    image: alpine\n' > "$repo/bricks/demo/compose.yml"
printf 'services:\n  demo:\n    image: alpine\n' > "$repo/bricks/demo/compose.prod.yml"
printf 'DEMO_PORT=1234\n' > "$repo/bricks/demo/env.example"
printf 'DEMO_SECRET=\n' > "$repo/bricks/demo/env.prod.example"
printf 'plugins { id("java-library") }\n' > "$repo/bricks/demo/java/build.gradle.kts"
printf 'package template.bricks.demo;\n\npublic class DemoConfig {}\n' > "$repo/bricks/demo/java/src/main/java/template/bricks/demo/DemoConfig.java"
printf -- '---\nname: demo\n---\n' > "$repo/bricks/demo/skill/SKILL.md"
printf 'dependencies { "implementation"("x:y:1") }\n' > "$repo/bricks/demo/brick.gradle.kts"
# Brick "demo2": only an env block, to test ordering and removal in the middle.
printf '# demo2: env only\n' > "$repo/bricks/demo2/README.md"
printf 'DEMO2=1\n' > "$repo/bricks/demo2/env.example"

b() { (cd "$repo" && scripts/brick.sh "$@"); }

# Unknown brick / bad usage.
if b add nope >/dev/null 2>&1; then fail "unknown brick accepted"; fi
if b remove demo >/dev/null 2>&1; then fail "remove of a disabled brick exited 0"; fi
if b >/dev/null 2>&1; then fail "no command exited 0"; fi

# list shows every brick with its state and README first line.
out="$(b list)"
grep -q '\[ \] demo .*a brick with everything' <<<"$out" || fail "list line for demo wrong: $out"

# add wires everything.
: > "$GRADLE_LOG"
app_before="$(cd "$repo" && find services/app -type f | sort)"
b add demo >/dev/null
grep -qx 'demo' "$repo/.bricks" || fail ".bricks not updated"
grep -q '^include:$' "$repo/compose.yml" || fail "include: key not inserted into compose.yml"
grep -q '^  - bricks/demo/compose.yml  # brick:demo$' "$repo/compose.yml" || fail "include line missing in compose.yml"
# The include block sits before the first top-level key, after the header comment.
[[ "$(grep -n -m1 -E '^(include|services):' "$repo/compose.yml" | cut -d: -f2)" == "include" ]] || fail "include: not before services:"
grep -q '^  - ../bricks/demo/compose.prod.yml  # brick:demo$' "$repo/deploy/compose.prod.yml" || fail "prod include line missing"
grep -q '^# --- brick:demo ---$' "$repo/.env.example" && grep -q '^DEMO_PORT=1234$' "$repo/.env.example" \
  && grep -q '^# --- /brick:demo ---$' "$repo/.env.example" || fail "env block not appended"
grep -q '^DEMO_SECRET=$' "$repo/deploy/.env.prod.example" || fail "prod env block not appended"
[[ "$app_before" == "$(cd "$repo" && find services/app -type f | sort)" ]] || fail "add touched files under services/app"
[[ -f "$repo/bricks/demo/java/src/main/java/template/bricks/demo/DemoConfig.java" ]] || fail "brick java moved"
[[ -f "$repo/.claude/skills/demo/SKILL.md" ]] || fail "skill not installed"
grep -q 'dependencies --write-locks' "$GRADLE_LOG" || fail "lockfile not refreshed after add"
grep -q 'spotlessApply' "$GRADLE_LOG" && fail "add ran spotless although nothing is copied"
out="$(b list)"; grep -q '\[x\] demo ' <<<"$out" || fail "list does not show demo enabled"

# add twice is a no-op.
snapshot="$(cd "$repo" && find . -type f -not -path './.git/*' -exec md5sum {} + | sort)"
b add demo >/dev/null
[[ "$snapshot" == "$(cd "$repo" && find . -type f -not -path './.git/*' -exec md5sum {} + | sort)" ]] || fail "second add changed files"
[[ "$(grep -c 'brick:demo' "$repo/compose.yml")" == 1 ]] || fail "include line duplicated"

# A second brick after the first; removing the first leaves the second intact with single blank lines.
b add demo2 >/dev/null
b remove demo >/dev/null
grep -q 'brick:demo2' "$repo/.env.example" || fail "demo2 block lost"
grep -q 'brick:demo ' "$repo/.env.example" && fail "demo markers left behind"
grep -q 'DEMO_PORT' "$repo/.env.example" && fail "demo block content left behind"
grep -Pzq '\n\n\n' "$repo/.env.example" && fail "double blank line left in .env.example"
[[ "$(tail -c1 "$repo/.env.example" | od -An -tx1 | tr -d ' \n')" == "0a" ]] || fail ".env.example lost its trailing newline"

# remove undoes everything else too.
grep -qx 'demo' "$repo/.bricks" && fail ".bricks still lists demo"
grep -q 'brick:demo$' "$repo/compose.yml" && fail "compose include line left"
grep -q '^include:' "$repo/compose.yml" && fail "empty include: key left in compose.yml"
grep -q 'brick:demo$' "$repo/deploy/compose.prod.yml" && fail "prod include line left"
[[ "$app_before" == "$(cd "$repo" && find services/app -type f | sort)" ]] || fail "remove touched files under services/app"
[[ ! -d "$repo/.claude/skills/demo" ]] || fail "skill dir not removed"
[[ "$(grep -c 'dependencies --write-locks' "$GRADLE_LOG")" -ge 2 ]] || fail "lockfile not refreshed after remove"
if b remove demo >/dev/null 2>&1; then fail "second remove exited 0"; fi

# A brick without a gradle file never calls gradle for locking.
: > "$GRADLE_LOG"; b remove demo2 >/dev/null
grep -q 'write-locks' "$GRADLE_LOG" && fail "lock refreshed for a brick without brick.gradle.kts"
[[ "$(cat "$repo/.env.example")" == $'# Local defaults.\nAPP_NAME=x' ]] || fail ".env.example not restored: $(cat "$repo/.env.example")"

# Brick names are validated before anything touches the filesystem.
for bad in .. a/b release vps-db bricks Upper; do
  if out="$(b add "$bad" 2>&1)"; then fail "add '$bad' exited 0"; fi
  if out="$(b remove "$bad" 2>&1)"; then fail "remove '$bad' exited 0"; fi
done
grep -q 'brick name must match' <<<"$(b add .. 2>&1 || true)" || fail "no name-validation message for '..'"
grep -q 'collides with a core skill' <<<"$(b add release 2>&1 || true)" || fail "no collision message for 'release'"
grep -q 'bricks/' "$repo/compose.yml" && fail "a rejected name touched compose.yml"

# A hand-edited .bricks without a final newline does not get the name glued onto its last line.
printf '# comment' > "$repo/.bricks"
b add demo2 >/dev/null
[[ "$(cat "$repo/.bricks")" == $'# comment\ndemo2' ]] || fail ".bricks glued: $(cat "$repo/.bricks")"
b remove demo2 >/dev/null

# A lockfile failure leaves the brick in place, says how to continue, and a retry of the printed command works.
if out="$(GRADLE_FAIL=1 b add demo 2>&1)"; then fail "add exited 0 although the lockfile refresh failed"; fi
grep -q 'make lock' <<<"$out" || fail "add failure does not mention make lock: $out"
grep -qx 'demo' "$repo/.bricks" || fail ".bricks lost demo after a failed lock refresh"
if out="$(GRADLE_FAIL=1 b remove demo 2>&1)"; then fail "remove exited 0 although the lockfile refresh failed"; fi
grep -q 'make lock' <<<"$out" || fail "remove failure does not mention make lock: $out"
grep -qx 'demo' "$repo/.bricks" && fail ".bricks still lists demo after remove"

# The CI matrix is static; once the bricks job exists every brick directory must be in it.
if grep -q '^  bricks:' "$root/.github/workflows/ci.yml"; then
  for d in "$root"/bricks/*/; do
    name="$(basename "$d")"
    grep -qE "^\s+brick: \[.*\b${name}\b.*\]" "$root/.github/workflows/ci.yml" || fail "ci.yml bricks matrix does not list ${name}"
  done
fi
echo "brick: all passed"
