#!/usr/bin/env bash
# Add, remove and list bricks: self-contained optional infrastructure under bricks/<name>/ (bricks/README.md).
#
#   scripts/brick.sh list                 every brick, [x] when enabled, with its README's first line
#   scripts/brick.sh add <name>           wire the brick in and list it in .bricks
#   scripts/brick.sh remove <name>        undo add, leaving nothing behind
#
# A brick is wired by the files it contains (each optional):
#   compose.yml            include: entry in compose.yml                    marker:  # brick:<name>
#   compose.prod.yml       include: entry in deploy/compose.prod.yml
#   env.example            block appended to .env.example                   markers: # --- brick:<name> --- … # --- /brick:<name> ---
#   env.prod.example       block appended to deploy/.env.prod.example
#   java/build.gradle.kts  Gradle project :bricks:<name> (dir bricks/<name>/java), included by settings.gradle.kts while enabled
#   skill/SKILL.md         copied to .claude/skills/<name>/SKILL.md
#   brick.gradle.kts       applied by the service build for every name in .bricks; the lockfile is refreshed here
#   Makefile               included by the root Makefile for every name in .bricks; nothing to copy
# Both commands are idempotent and never commit. GRADLE (default ./gradlew) and BRICK_SERVICE (default app) can
# be overridden, which the tests use.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
service="${BRICK_SERVICE:-app}"
service_dir="services/${service}"
bricks_file=".bricks"
gradle="${GRADLE:-./gradlew}"

usage() { sed -n '2,18p' "$0" >&2; exit 2; }
die() { echo "brick: $*" >&2; exit 1; }

enabled() { [[ -f "$bricks_file" ]] && grep -qx "$1" "$bricks_file"; }

# --- compose include lines ------------------------------------------------------------------------------------------
include_add() { # file, include path, brick
  local file="$1" path="$2" b="$3" line
  line="  - ${path}  # brick:${b}"
  grep -q "# brick:${b}\$" "$file" && return 0
  if grep -q '^include:' "$file"; then
    awk -v l="$line" '{ print } /^include:/ { print l }' "$file" > "$file.tmp"
  else
    # New key goes before the first top-level key, after the header comments.
    awk -v l="$line" 'BEGIN { done = 0 } !done && /^[A-Za-z]/ { print "include:"; print l; done = 1 } { print }' "$file" > "$file.tmp"
  fi
  mv "$file.tmp" "$file"
  echo "  ~ $file: include ${path}"
}
include_remove() { # file, brick
  local file="$1" b="$2"
  grep -q "# brick:${b}\$" "$file" || return 0
  sed -i "/# brick:${b}\$/d" "$file"
  # Drop the key when no entry is left under it.
  if ! sed -n '/^include:/{n;p}' "$file" | grep -q '^  - '; then sed -i '/^include:$/d' "$file"; fi
  echo "  ~ $file: include removed"
}

# --- env marker blocks ----------------------------------------------------------------------------------------------
block_add() { # file, source block, brick
  local file="$1" src="$2" b="$3"
  grep -q "^# --- brick:${b} ---\$" "$file" && return 0
  { printf '\n# --- brick:%s ---\n' "$b"; cat "$src"; printf '# --- /brick:%s ---\n' "$b"; } >> "$file"
  echo "  ~ $file: block appended"
}
block_remove() { # file, brick
  local file="$1" b="$2"
  grep -q "^# --- brick:${b} ---\$" "$file" || return 0
  grep -q "^# --- /brick:${b} ---\$" "$file" || die "$file: block for '${b}' has no end marker; fix it by hand"
  sed -i "/^# --- brick:${b} ---\$/,/^# --- \/brick:${b} ---\$/d" "$file"
  # Squeeze the blank line that preceded the block; keep exactly one trailing newline.
  printf '%s\n' "$(cat -s "$file")" > "$file.tmp" && mv "$file.tmp" "$file"
  echo "  ~ $file: block removed"
}

refresh_lock() { "$gradle" ":${service}:dependencies" --write-locks -q && echo "  ~ $service_dir/gradle.lockfile refreshed"; }

check_name() { # brick
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "brick name must match ^[a-z0-9][a-z0-9-]*\$"
  case "$1" in release|vps-db|bricks) die "brick name '$1' collides with a core skill" ;; esac
}

# --- commands -------------------------------------------------------------------------------------------------------
cmd_list() {
  local d b mark desc
  shopt -s nullglob
  for d in bricks/*/; do
    b="$(basename "$d")"
    mark=" "; enabled "$b" && mark="x"
    desc="$(sed -n '1s/^#[[:space:]]*//p' "$d/README.md" 2>/dev/null || true)"
    printf '  [%s] %-14s %s\n' "$mark" "$b" "$desc"
  done
}

cmd_add() {
  local b="$1"
  check_name "$b"
  [[ -d "bricks/$b" ]] || die "unknown brick '$b' (make bricks lists them)"
  if enabled "$b"; then echo "brick '$b' is already enabled; nothing to do"; return 0; fi
  echo "Adding brick '$b':"
  [[ -f "bricks/$b/compose.yml" ]] && include_add compose.yml "bricks/$b/compose.yml" "$b"
  [[ -f "bricks/$b/compose.prod.yml" ]] && include_add deploy/compose.prod.yml "../bricks/$b/compose.prod.yml" "$b"
  [[ -f "bricks/$b/env.example" ]] && block_add .env.example "bricks/$b/env.example" "$b"
  [[ -f "bricks/$b/env.prod.example" ]] && block_add deploy/.env.prod.example "bricks/$b/env.prod.example" "$b"
  if [[ -f "bricks/$b/skill/SKILL.md" ]]; then mkdir -p ".claude/skills/$b"; cp "bricks/$b/skill/SKILL.md" ".claude/skills/$b/SKILL.md"; echo "  + .claude/skills/$b/SKILL.md"; fi
  [[ -s "$bricks_file" && $(tail -c1 "$bricks_file" | wc -l) -eq 0 ]] && echo >> "$bricks_file"
  echo "$b" >> "$bricks_file"; echo "  ~ $bricks_file: + $b"
  if [[ -f "bricks/$b/brick.gradle.kts" ]]; then
    refresh_lock || die "lockfile refresh failed; the brick's files are in place: fix the cause, then: make lock"
  fi
  [[ -f "bricks/$b/java/build.gradle.kts" ]] && echo "  ~ bricks/$b/java is now Gradle project :bricks:$b"
  echo "Enabled '$b'. Read bricks/$b/README.md, then: make build && make test-scripts"
}

cmd_remove() {
  local b="$1"
  check_name "$b"
  [[ -d "bricks/$b" ]] || die "unknown brick '$b' (make bricks lists them)"
  enabled "$b" || die "brick '$b' is not enabled"
  echo "Removing brick '$b':"
  include_remove compose.yml "$b"
  include_remove deploy/compose.prod.yml "$b"
  block_remove .env.example "$b"
  block_remove deploy/.env.prod.example "$b"
  if [[ -f "bricks/$b/skill/SKILL.md" ]]; then rm -rf ".claude/skills/$b"; echo "  - .claude/skills/$b/"; fi
  sed -i "/^${b}\$/d" "$bricks_file"; echo "  ~ $bricks_file: - $b"
  if [[ -f "bricks/$b/brick.gradle.kts" ]]; then
    refresh_lock || die "lockfile refresh failed; the brick is already removed: fix the cause, then: make lock"
  fi
  echo "Disabled '$b'. Then: make build && make test-scripts"
}

cmd="${1:-}"; name="${2:-}"
case "$cmd" in
  list) cmd_list ;;
  add) [[ -n "$name" ]] || usage; cmd_add "$name" ;;
  remove) [[ -n "$name" ]] || usage; cmd_remove "$name" ;;
  *) usage ;;
esac
