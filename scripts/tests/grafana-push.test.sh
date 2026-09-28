#!/usr/bin/env bash
# Exercises scripts/grafana-push.sh against a fake curl that records every call.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
script="$root/scripts/grafana-push.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/curl" <<'FAKE'
#!/usr/bin/env bash
# Records the full argument list, one call per line; answers like Grafana would.
printf '%s\n' "$*" >> "$CURL_LOG"
for a in "$@"; do case "$a" in */api/folders/*) echo '{"uid":"app"}'; exit 0;; esac; done
echo '{"status":"success","uid":"app-overview","id":1,"version":1,"folderUid":"app"}'
FAKE
chmod +x "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH" CURL_LOG="$tmp/calls.log"

# local: no auth header, folder ensured, dashboard posted with overwrite, alerting skipped without Telegram vars.
: > "$CURL_LOG"
(cd "$root" && env -u TELEGRAM_BOT_TOKEN -u TELEGRAM_CHAT_ID "$script" local > "$tmp/out.log")
grep -q 'localhost:3000/api/folders' "$CURL_LOG" || fail "folder not ensured on local"
grep -q 'localhost:3000/api/dashboards/db' "$CURL_LOG" || fail "dashboard not posted on local"
grep -q 'Authorization' "$CURL_LOG" && fail "local push sent an Authorization header"
grep -q '"overwrite": *true' "$CURL_LOG" || fail "dashboard POST lacks overwrite:true"
grep -q 'provisioning/contact-points' "$CURL_LOG" && fail "alerting pushed without Telegram vars"
grep -qi 'alerting skipped' "$tmp/out.log" || fail "no skip notice for alerting"

# cloud: token required, trailing slash on GRAFANA_URL tolerated, alerting pushed when Telegram vars are set.
: > "$CURL_LOG"
if (cd "$root" && env -u GRAFANA_API_TOKEN GRAFANA_URL=https://g.example.net "$script" cloud >/dev/null 2>&1); then
  fail "cloud push without GRAFANA_API_TOKEN did not fail"
fi
(cd "$root" && GRAFANA_URL=https://g.example.net/ GRAFANA_API_TOKEN=tok TELEGRAM_BOT_TOKEN=bt TELEGRAM_CHAT_ID=42 \
  "$script" cloud > "$tmp/out.log")
grep -q 'https://g.example.net/api/dashboards/db' "$CURL_LOG" || fail "cloud URL wrong: $(grep dashboards "$CURL_LOG")"
grep -q 'g.example.net//api' "$CURL_LOG" && fail "double slash in URL"
grep -q 'Authorization: Bearer tok' "$CURL_LOG" || fail "bearer token missing"
grep -q 'provisioning/contact-points' "$CURL_LOG" || fail "contact point not pushed"
grep -q 'provisioning/policies' "$CURL_LOG" || fail "notification policy not pushed"
grep -q 'provisioning/folder/app/rule-groups/app-baseline' "$CURL_LOG" || fail "alert rule group not pushed"
grep -q '"bottoken": *"bt"' "$CURL_LOG" || fail "telegram token not substituted into contact point"
grep -q 'X-Disable-Provenance' "$CURL_LOG" || fail "provisioning calls must disable provenance so the UI stays editable"

echo "grafana-push: all passed"
