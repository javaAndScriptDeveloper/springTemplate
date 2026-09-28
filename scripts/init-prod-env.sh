#!/usr/bin/env bash
# Creates deploy/.env.prod on the VPS from deploy/.env.prod.example.
#
# Why a script: the production database must never run with the local app/app defaults, and the password should be
# generated on the host that uses it, never typed, pasted or committed. The script also derives the image name and
# compose project name from the git remote, so the two values most likely to be mistyped never are.
#
# Usage: scripts/init-prod-env.sh [--force]     (or: make prod-init)
set -euo pipefail

force=false
[[ "${1:-}" == "--force" ]] && force=true

root="$(git rev-parse --show-toplevel)"
example="$root/deploy/.env.prod.example"
target="$root/deploy/.env.prod"

if [[ -e "$target" && "$force" == false ]]; then
  echo "Refusing: $target already exists. Re-run with --force to replace it (this generates a NEW database password," >&2
  echo "which only makes sense before the first 'make prod-up' or together with a database reset)." >&2
  exit 1
fi

remote="$(git -C "$root" remote get-url origin 2>/dev/null || true)"
slug="$(printf '%s' "$remote" | sed -E 's#^(git@github\.com:|https://github\.com/|ssh://git@github\.com/)##; s#\.git$##' | tr '[:upper:]' '[:lower:]')"
if [[ -z "$slug" || "$slug" != */* ]]; then
  echo "Could not derive owner/repo from git remote '$remote'; add the GitHub remote first." >&2
  exit 1
fi
project="${slug##*/}"
image="ghcr.io/${slug}"

cat <<BANNER

  This writes production secrets to:

      $target

  It will contain a freshly generated POSTGRES_PASSWORD and is chmod 600. It is gitignored and must stay on this host.
$( [[ "$force" == true ]] && printf '\n  --force: the existing file will be OVERWRITTEN and the database password REPLACED.\n' )
  Derived from the git remote:
      APP_IMAGE=$image
      COMPOSE_PROJECT_NAME=$project

BANNER
read -r -p "  Type 'yes' to continue: " answer
[[ "$answer" == "yes" ]] || { echo "Aborted; nothing written."; exit 1; }

password="$(openssl rand -hex 24)"
umask 077
sed -e "s#^POSTGRES_PASSWORD=.*#POSTGRES_PASSWORD=${password}#" \
    -e "s#^APP_IMAGE=.*#APP_IMAGE=${image}#" \
    -e "s#^COMPOSE_PROJECT_NAME=.*#COMPOSE_PROJECT_NAME=${project}#" \
    "$example" > "$target"
chmod 600 "$target"

cat <<NEXT

  Written $target

  Still to fill by hand (REQUIRED block):
      DOMAIN=          public hostname, DNS A record already pointing at this VPS
      ACME_EMAIL=      Let's Encrypt account e-mail

  Optional: GRAFANA_CLOUD_PROM_* and COMPOSE_PROFILES=observability for metrics in Grafana Cloud.
  Then:  make prod-up
NEXT
