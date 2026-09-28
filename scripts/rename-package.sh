#!/usr/bin/env bash
# Make the template yours: move the Java package and rename the application in one step.
#
#   scripts/rename-package.sh <new.base.package> <app-name>
#   e.g.   scripts/rename-package.sh com.acme.shop shop
#
# Rewrites: package/import lines and package-literal strings (Feign/ArchUnit/JaCoCo), Gradle group and project name,
# APP_NAME defaults in application.yml, compose.yml and .env.example, and CLAUDE.md. Refuses on a dirty git tree so
# the result is one reviewable diff. Afterwards: make build.
set -euo pipefail

new_pkg="${1:-}"; app="${2:-}"
[[ "$new_pkg" =~ ^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$ ]] || { echo "usage: $0 <new.base.package> <app-name>  (package: lowercase dotted, at least two segments)" >&2; exit 2; }
[[ "$app" =~ ^[a-z][a-z0-9-]*$ ]] || { echo "app-name: lowercase letters, digits, dashes (used for rootProject.name and APP_NAME)" >&2; exit 2; }

root="$(git rev-parse --show-toplevel)"
cd "$root"
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Refusing: working tree is not clean. Commit or stash first so the rename is one reviewable diff." >&2
  exit 1
fi

old_pkg="com.example.company"
old_name="spring-template"
old_dir="${old_pkg//./\/}"; new_dir="${new_pkg//./\/}"
# Literal dots for sed: otherwise "com.example.company" also matches the slashed form and mangles it.
old_pkg_re="${old_pkg//./\\.}"

for src in src/main/java src/test/java; do
  [[ -d "$src/$old_dir" ]] || continue
  mkdir -p "$src/$new_dir"
  # Move contents (not the directory) so a new package that shares a prefix with the old one still works.
  find "$src/$old_dir" -mindepth 1 -maxdepth 1 -exec mv -t "$src/$new_dir/" {} +
  # Remove the now-empty old tree, bottom-up, stopping at the first non-empty parent.
  d="$src/$old_dir"; while [[ "$d" != "$src" ]] && rmdir "$d" 2>/dev/null; do d="$(dirname "$d")"; done
done

# Package references: dotted (Java, YAML, Gradle strings) and slashed (JaCoCo exclusions). The script's own tests
# and the historical design docs keep the template's name on purpose.
{ grep -rl --exclude-dir=.git --exclude-dir=build --exclude-dir=.gradle --exclude-dir=superpowers \
    --exclude-dir=tests --exclude="$(basename "$0")" -e "$old_pkg" -e "$old_dir" . || true; } \
  | xargs -r sed -i -e "s#${old_pkg_re}#${new_pkg}#g" -e "s#${old_dir}#${new_dir}#g"

# Application name: Gradle project, env defaults, docs.
sed -i "s#rootProject.name = \"${old_name}\"#rootProject.name = \"${app}\"#" settings.gradle.kts
sed -i -E "s#(APP_NAME:-?)${old_name}#\1${app}#g" compose.yml src/main/resources/application.yml
sed -i "s#^APP_NAME=${old_name}\$#APP_NAME=${app}#" .env.example
[[ -f CLAUDE.md ]] && sed -i "s#${old_name}#${app}#g" CLAUDE.md
[[ -f README.md ]] && sed -i "s#${old_name}#${app}#g" README.md

cat <<DONE
Renamed ${old_pkg} → ${new_pkg}, ${old_name} → ${app}.

Next:
  make build            # compiles, runs tests, checks formatting
  git add -A && git commit -m "chore: rename template to ${app}"
DONE
