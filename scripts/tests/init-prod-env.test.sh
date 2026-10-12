#!/usr/bin/env bash
# Exercises scripts/init-prod-env.sh: banner confirmation, derived values, refusal to overwrite.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"; mkdir -p "$repo/deploy" "$repo/scripts"
cp "$root/deploy/.env.prod.example" "$repo/deploy/"
printf '\n# --- brick:demo ---\nDEMO_PASSWORD=\n# --- /brick:demo ---\n' >> "$repo/deploy/.env.prod.example"
printf 'LAST_PASSWORD=' >> "$repo/deploy/.env.prod.example"   # final line, no trailing newline
cp "$root/scripts/init-prod-env.sh" "$repo/scripts/"
git -C "$repo" init -q -b main
git -C "$repo" remote add origin git@github.com:Owner/My-Repo.git

# Answering anything but "yes" writes nothing.
if (cd "$repo" && printf 'no\n' | scripts/init-prod-env.sh >/dev/null 2>&1); then fail "declined banner still exited 0"; fi
[[ ! -e "$repo/deploy/.env.prod" ]] || fail "file written despite 'no'"

(cd "$repo" && printf 'yes\n' | scripts/init-prod-env.sh >/dev/null)
env_file="$repo/deploy/.env.prod"
[[ -f "$env_file" ]] || fail ".env.prod not created"
grep -q '^APP_IMAGE=ghcr.io/owner/my-repo$' "$env_file" || fail "APP_IMAGE not derived/lowercased: $(grep APP_IMAGE "$env_file")"
grep -q '^COMPOSE_PROJECT_NAME=my-repo$' "$env_file" || fail "COMPOSE_PROJECT_NAME wrong: $(grep COMPOSE_PROJECT_NAME "$env_file")"
pw="$(grep '^POSTGRES_PASSWORD=' "$env_file" | cut -d= -f2)"
[[ "$pw" =~ ^[0-9a-f]{48}$ ]] || fail "POSTGRES_PASSWORD not 48 hex chars: '$pw'"
mpw="$(grep '^DEMO_PASSWORD=' "$env_file" | cut -d= -f2)"
[[ "$mpw" =~ ^[0-9a-f]{48}$ ]] || fail "DEMO_PASSWORD not generated: '$mpw'"
[[ "$mpw" != "$pw" ]] || fail "both passwords identical"
lpw="$(grep '^LAST_PASSWORD=' "$env_file" | cut -d= -f2 || true)"
[[ "$lpw" =~ ^[0-9a-f]{48}$ ]] || fail "unterminated last line dropped or not generated: '$lpw'"
[[ "$(stat -c %a "$env_file")" == "600" ]] || fail "mode is $(stat -c %a "$env_file"), want 600"

# A second run must refuse and leave the file untouched.
before="$(cat "$env_file")"
if (cd "$repo" && printf 'yes\n' | scripts/init-prod-env.sh >/dev/null 2>&1); then fail "overwrote existing .env.prod"; fi
[[ "$before" == "$(cat "$env_file")" ]] || fail "existing file changed"

# --force regenerates the password.
(cd "$repo" && printf 'yes\n' | scripts/init-prod-env.sh --force >/dev/null)
[[ "$pw" != "$(grep '^POSTGRES_PASSWORD=' "$env_file" | cut -d= -f2)" ]] || fail "--force kept the old password"

# HTTPS remotes work too.
git -C "$repo" remote set-url origin https://github.com/Owner/My-Repo.git
(cd "$repo" && printf 'yes\n' | scripts/init-prod-env.sh --force >/dev/null)
grep -q '^APP_IMAGE=ghcr.io/owner/my-repo$' "$env_file" || fail "https remote not parsed"

# A failing openssl must abort: no file, not one with an empty password.
fakebin="$tmp/fakebin"; mkdir -p "$fakebin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/openssl"; chmod +x "$fakebin/openssl"
rm -f "$env_file"
if (cd "$repo" && printf 'yes\n' | PATH="$fakebin:$PATH" scripts/init-prod-env.sh >/dev/null 2>&1); then fail "exited 0 with a failing openssl"; fi
[[ ! -e "$env_file" ]] || fail "wrote .env.prod after openssl failed"

echo "init-prod-env: all passed"
