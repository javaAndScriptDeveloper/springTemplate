#!/usr/bin/env bash
# Exercises scripts/vps.sh with a fake ssh that answers like the VPS would.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
script="$root/scripts/vps.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSH_LOG"
case "$*" in
  *"cat "*".env.prod"*) printf 'POSTGRES_DB=app\nPOSTGRES_USER=app\nPOSTGRES_PASSWORD=s3cret\nPOSTGRES_HOST_PORT=5433\nDOMAIN=example.com\nGRAFANA_CLOUD_PROM_TOKEN=tok\n' ;;
  *) echo "fake-ssh: $*" ;;
esac
FAKE
chmod +x "$tmp/bin/ssh"
export PATH="$tmp/bin:$PATH" SSH_LOG="$tmp/ssh.log"
cd "$tmp"   # no .env here: everything must come from the environment

# Missing VPS_SSH is a usage error with a hint, not a stack of ssh failures.
if out="$(env -u VPS_SSH "$script" ps 2>&1)"; then fail "ps without VPS_SSH exited 0"; fi
[[ "$out" == *VPS_SSH* ]] || fail "no hint about VPS_SSH: $out"

export VPS_SSH=deploy@vps.example VPS_APP_DIR=/srv/app

# env: values masked, keys kept.
out="$("$script" env)"
[[ "$out" == *"POSTGRES_PASSWORD=****"* ]] || fail "password not masked: $out"
[[ "$out" == *"GRAFANA_CLOUD_PROM_TOKEN=****"* ]] || fail "token not masked: $out"
[[ "$out" == *"DOMAIN=example.com"* ]] || fail "non-secret value masked: $out"
[[ "$out" != *s3cret* ]] || fail "secret leaked: $out"

# datagrip: JDBC URL from remote creds and the tunnel port, remote host port honoured.
: > "$SSH_LOG"
out="$("$script" datagrip --no-tunnel --no-clipboard)"
[[ "$out" == *"jdbc:postgresql://localhost:15432/app?user=app&password=s3cret"* ]] || fail "jdbc url wrong: $out"
grep -q -- "-L 15432:127.0.0.1:5433" "$SSH_LOG" && fail "tunnel opened despite --no-tunnel"

# ps runs compose on the VPS in the app directory.
: > "$SSH_LOG"
"$script" ps >/dev/null
grep -q "cd /srv/app" "$SSH_LOG" || fail "ps did not cd into VPS_APP_DIR: $(cat "$SSH_LOG")"
grep -q "compose.prod.yml" "$SSH_LOG" || fail "ps did not use the prod compose file: $(cat "$SSH_LOG")"

echo "vps: all passed"
