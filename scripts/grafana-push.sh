#!/usr/bin/env bash
# Pushes deploy/grafana/** to a Grafana instance, or pulls the dashboard back after editing it in the UI.
#
#   grafana-push.sh local            → http://localhost:3000 (compose observability profile, anonymous admin)
#   grafana-push.sh cloud            → $GRAFANA_URL with $GRAFANA_API_TOKEN (service account, dashboards:write +
#                                      alert.provisioning:write). CI runs this on every change under deploy/grafana.
#   grafana-push.sh pull             → export the dashboard from local Grafana into deploy/grafana/dashboards.
#
# Alerting (contact point, notification policy, rules) is pushed only when TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID
# are set; otherwise the dashboards go up and a notice explains what was skipped. Values are read from the
# environment first, then from .env in the repository root.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
assets="$root/deploy/grafana"
dashboard_uid="app-overview"
folder_uid="app"
folder_title="App"

mode="${1:-}"
[[ "$mode" =~ ^(local|cloud|pull)$ ]] || { sed -n '2,12p' "$0" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq is required (apt install jq / brew install jq)" >&2; exit 2; }

# .env fills in whatever the environment did not provide; never overrides it.
if [[ -f "$root/.env" ]]; then
  while IFS='=' read -r key value; do
    [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
    [[ -z "${!key:-}" ]] && export "$key=$value"
  done < <(grep -E '^[A-Z_]+=' "$root/.env" || true)
fi

auth=()
if [[ "$mode" == "cloud" ]]; then
  : "${GRAFANA_URL:?GRAFANA_URL is not set (Grafana Cloud stack URL, e.g. https://you.grafana.net)}"
  : "${GRAFANA_API_TOKEN:?GRAFANA_API_TOKEN is not set (service account token with dashboards:write)}"
  base="${GRAFANA_URL%/}"
  auth=(-H "Authorization: Bearer ${GRAFANA_API_TOKEN}")
else
  base="${GRAFANA_URL_LOCAL:-http://localhost:3000}"
fi

api() { # method path [json-body] [extra curl args...]
  local method="$1" path="$2" body="${3:-}"; shift 3 || shift $#
  if [[ -n "$body" ]]; then
    curl -sfS -X "$method" "${base}${path}" -H "Content-Type: application/json" "${auth[@]}" "$@" --data-binary "$body"
  else
    curl -sfS -X "$method" "${base}${path}" "${auth[@]}" "$@"
  fi
}

if [[ "$mode" == "pull" ]]; then
  out="$assets/dashboards/${dashboard_uid}.json"
  api GET "/api/dashboards/uid/${dashboard_uid}" | jq '.dashboard | del(.id, .version)' > "$out.tmp"
  mv "$out.tmp" "$out"
  echo "pulled ${dashboard_uid} → ${out#"$root"/}"
  exit 0
fi

echo "→ ${base}"
# Folder: create if missing (409 = exists, fine).
api POST "/api/folders" "$(jq -n --arg uid "$folder_uid" --arg title "$folder_title" '{uid:$uid,title:$title}')" >/dev/null 2>&1 \
  || api GET "/api/folders/${folder_uid}" >/dev/null

for file in "$assets"/dashboards/*.json; do
  payload="$(jq -n --slurpfile d "$file" --arg folder "$folder_uid" '{dashboard: ($d[0] | del(.id)), folderUid: $folder, overwrite: true, message: "grafana-push.sh"}')"
  api POST "/api/dashboards/db" "$payload" | jq -r '"  dashboard \(.uid) → \(.status) (v\(.version))"'
done

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
  echo "  alerting skipped: TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID not set (set both to enable Telegram alerts)"
  exit 0
fi

# Provisioning API with provenance disabled, so the objects stay editable in the UI too.
prov=(-H "X-Disable-Provenance: true")
contact="$(jq --arg t "$TELEGRAM_BOT_TOKEN" --arg c "$TELEGRAM_CHAT_ID" '.settings.bottoken=$t | .settings.chatid=$c' "$assets/alerting/contact-point.json")"
name="$(jq -r .name "$assets/alerting/contact-point.json")"
existing_uid="$(api GET "/api/v1/provisioning/contact-points" "" "${prov[@]}" | jq -r --arg n "$name" '[.[]? | objects | select(.name==$n)][0].uid // empty')"
if [[ -n "$existing_uid" ]]; then
  api PUT "/api/v1/provisioning/contact-points/${existing_uid}" "$contact" "${prov[@]}" >/dev/null
else
  api POST "/api/v1/provisioning/contact-points" "$contact" "${prov[@]}" >/dev/null
fi
echo "  contact point ${name} → ok"

api PUT "/api/v1/provisioning/policies" "$(cat "$assets/alerting/notification-policy.json")" "${prov[@]}" >/dev/null
echo "  notification policy → ok"

group="$(jq -r '.[0].ruleGroup' "$assets/alerting/rules.json")"
api PUT "/api/v1/provisioning/folder/${folder_uid}/rule-groups/${group}" \
  "$(jq --arg g "$group" '{title:$g, interval:"1m", rules:.}' "$assets/alerting/rules.json")" "${prov[@]}" >/dev/null
echo "  alert rules ${group} ($(jq length "$assets/alerting/rules.json")) → ok"
