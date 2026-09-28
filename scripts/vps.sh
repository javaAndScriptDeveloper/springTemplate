#!/usr/bin/env bash
# Reach the production VPS and its database over SSH. Nothing secret is ever stored on this machine: credentials
# are read from deploy/.env.prod on the VPS for each command and shown masked unless a connection needs them.
#
# Configuration (environment or .env in the repository root):
#   VPS_SSH            user@host or an alias from ~/.ssh/config          (required)
#   VPS_APP_DIR        repository checkout on the VPS                   (default: ~/<repo name>)
#   VPS_DB_LOCAL_PORT  local end of the database tunnel                 (default: 15432)
#
# Commands:
#   ssh                  shell in the app directory
#   env                  deploy/.env.prod with secret values masked
#   ps | logs [service]  production compose status / logs
#   deploy-status        image tag per replica, what /version answers, and whether backups are fresh
#   backup-status        age of the last successful off-host backup; non-zero when stale or missing
#   tunnel               forward localhost:$VPS_DB_LOCAL_PORT → Postgres on the VPS until Ctrl-C
#   psql [sql]           interactive psql through the tunnel, or run one statement and exit
#   datagrip             open the tunnel in the background and print a ready-to-paste JDBC URL
#                        (DataGrip: New → Data Source from URL). --no-tunnel / --no-clipboard for scripting.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose_file="deploy/compose.prod.yml"
env_file="deploy/.env.prod"

# .env fills in whatever the environment did not provide; never overrides it.
if [[ -f "$root/.env" ]]; then
  while IFS='=' read -r key value; do
    [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
    [[ -z "${!key:-}" ]] && export "$key=$value"
  done < <(grep -E '^[A-Z_]+=' "$root/.env" || true)
fi

usage() { sed -n '2,21p' "$0" >&2; exit 2; }
cmd="${1:-}"; shift || true
[[ -n "$cmd" ]] || usage

if [[ -z "${VPS_SSH:-}" ]]; then
  echo "VPS_SSH is not set. Put VPS_SSH=user@host (or an ~/.ssh/config alias) in .env or the environment." >&2
  exit 2
fi
app_dir="${VPS_APP_DIR:-~/$(basename "$root")}"
local_port="${VPS_DB_LOCAL_PORT:-15432}"

remote() { ssh "$VPS_SSH" "cd $app_dir && $*"; }
remote_env() { ssh "$VPS_SSH" "cat $app_dir/$env_file"; }
prod() { remote "docker compose -f $compose_file --env-file $env_file $*"; }
env_value() { # KEY DEFAULT
  local v; v="$(printf '%s\n' "$REMOTE_ENV" | grep -E "^$1=" | head -n1 | cut -d= -f2- || true)"
  printf '%s' "${v:-$2}"
}
load_remote_env() { REMOTE_ENV="$(remote_env)"; }
tunnel_running() { pgrep -f "ssh .*-L ${local_port}:127.0.0.1:" >/dev/null; }
open_tunnel() { # background, once
  if tunnel_running; then echo "tunnel already open on localhost:${local_port}" >&2; return; fi
  ssh -f -N -o ExitOnForwardFailure=yes -L "${local_port}:127.0.0.1:$1" "$VPS_SSH"
  echo "tunnel: localhost:${local_port} → ${VPS_SSH}:127.0.0.1:$1 (pid $(pgrep -f "ssh .*-L ${local_port}:127.0.0.1:" | head -n1)); close with: pkill -f 'ssh .*-L ${local_port}:'" >&2
}

case "$cmd" in
  ssh)
    exec ssh -t "$VPS_SSH" "cd $app_dir && exec \$SHELL -l" ;;

  env)
    remote_env | sed -E 's/^([A-Z0-9_]*(PASSWORD|TOKEN|SECRET|KEY)[A-Z0-9_]*=).+$/\1****/' ;;

  ps)
    prod ps ;;

  logs)
    prod logs -f --tail=200 "${1:-}" ;;

  deploy-status)
    prod "ps --format '{{.Service}} {{.Image}} {{.Status}}'" | grep -E '^app ' || true
    load_remote_env
    domain="$(env_value DOMAIN "")"
    [[ -n "$domain" ]] && { echo "https://${domain}/version →"; curl -fsS --max-time 10 "https://${domain}/version" || true; echo; }
    profiles="$(env_value COMPOSE_PROFILES "")"
    if [[ ",${profiles// /}," != *",backup,"* ]]; then
      echo "backups: DISABLED (COMPOSE_PROFILES lacks backup; docs/deployment.md §6)"
    elif status_out="$(prod "--profile backup run --rm -T backup status" 2>/dev/null)"; then
      echo "backups: ok — ${status_out//$'\n'/; }"
    else
      status_out="${status_out//$'\n'/; }"
      echo "backups: STALE — ${status_out:-no answer; run make vps-backup-status}"
    fi ;;

  backup-status)
    prod "--profile backup run --rm -T backup status" ;;

  tunnel)
    load_remote_env
    port="$(env_value POSTGRES_HOST_PORT 5432)"
    echo "localhost:${local_port} → ${VPS_SSH}:127.0.0.1:${port}  (Ctrl-C to close)"
    exec ssh -N -o ExitOnForwardFailure=yes -L "${local_port}:127.0.0.1:${port}" "$VPS_SSH" ;;

  psql)
    load_remote_env
    port="$(env_value POSTGRES_HOST_PORT 5432)"
    db="$(env_value POSTGRES_DB app)"; user="$(env_value POSTGRES_USER app)"; pass="$(env_value POSTGRES_PASSWORD "")"
    open_tunnel "$port"
    export PGPASSWORD="$pass"
    if command -v psql >/dev/null; then
      psql_cmd=(psql -h localhost -p "$local_port" -U "$user" -d "$db")
    else
      psql_cmd=(docker run --rm -it --network host -e PGPASSWORD postgres:17-alpine psql -h localhost -p "$local_port" -U "$user" -d "$db")
    fi
    if [[ $# -gt 0 ]]; then "${psql_cmd[@]}" -c "$*"; else "${psql_cmd[@]}"; fi ;;

  datagrip)
    want_tunnel=true; want_clip=true
    for a in "$@"; do case "$a" in --no-tunnel) want_tunnel=false ;; --no-clipboard) want_clip=false ;; esac; done
    load_remote_env
    port="$(env_value POSTGRES_HOST_PORT 5432)"
    db="$(env_value POSTGRES_DB app)"; user="$(env_value POSTGRES_USER app)"; pass="$(env_value POSTGRES_PASSWORD "")"
    $want_tunnel && open_tunnel "$port"
    url="jdbc:postgresql://localhost:${local_port}/${db}?user=${user}&password=${pass}"
    if $want_clip; then
      if command -v wl-copy >/dev/null; then printf '%s' "$url" | wl-copy && echo "(copied to clipboard)" >&2
      elif command -v xclip >/dev/null; then printf '%s' "$url" | xclip -selection clipboard && echo "(copied to clipboard)" >&2
      elif command -v pbcopy >/dev/null; then printf '%s' "$url" | pbcopy && echo "(copied to clipboard)" >&2
      fi
    fi
    echo "DataGrip → New → Data Source from URL → paste:"
    echo "$url" ;;

  *) usage ;;
esac
