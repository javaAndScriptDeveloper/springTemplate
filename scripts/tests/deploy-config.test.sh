#!/usr/bin/env bash
# Validates the compose files and the Caddyfile with the real tools. Skips (exit 0) when Docker is unavailable.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

if ! docker info >/dev/null 2>&1; then echo "deploy-config: skipped (no docker)"; exit 0; fi

fixture_env="$here/fixtures/env.prod.test"
prod() { docker compose -f "$1/deploy/compose.prod.yml" --env-file "${2:-$fixture_env}" config "${@:3}"; }

# Lines of one top-level service in a rendered config (a plain awk range would end on its own first line).
svc_block() { awk -v s="$1" '$0 ~ "^  " s ":" {f=1; next} f && /^  [a-z]/ {f=0} f'; }

# --- core, no bricks ---------------------------------------------------------------------------------------------
docker compose -f "$root/compose.yml" --env-file "$root/.env.example" --profile full config -q || fail "compose.yml does not validate"
prod "$root" "$fixture_env" -q || fail "deploy/compose.prod.yml does not validate with the fixture env"
if prod "$root" /dev/null -q 2>/dev/null; then fail "compose.prod.yml validated with no environment; a required variable lost its :? guard"; fi
rendered="$(prod "$root")"
for svc in backup alloy minio prometheus grafana; do
  grep -qE "^  ${svc}:" <<<"$rendered" && fail "core prod stack contains brick service ${svc}"
done
rendered_cfg="$(DOCKER_CONFIG_FILE=/home/u/.docker/config.json prod "$root")"
grep -q 'source: /home/u/.docker/config.json' <<<"$rendered_cfg" || fail "DOCKER_CONFIG_FILE is not mounted as the file /config.json"
grep -q 'source: /dev/null' <<<"$rendered" || fail "default registry credential mount should be /dev/null"
grep -q 'WATCHTOWER_LIFECYCLE_HOOKS: "true"' <<<"$rendered" || fail "Watchtower lifecycle hooks not enabled"
grep -q 'com.centurylinklabs.watchtower.lifecycle.post-update:' <<<"$rendered" || fail "app has no post-update health wait hook"
grep -q 'unhealthy_status' "$root/deploy/Caddyfile" && fail "Caddyfile ejects replicas on 5xx responses"
docker run --rm -v "$root/deploy/Caddyfile:/etc/caddy/Caddyfile:ro" -e DOMAIN=example.com -e ACME_EMAIL=ops@example.com \
  caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 || fail "Caddyfile does not validate"

# --- every brick added, on a scratch copy of the working tree ---------------------------------------------------
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
copy="$tmp/repo"; mkdir -p "$copy"
(cd "$root" && git ls-files -z --cached --others --exclude-standard | tar --null -T - -cf - 2>/dev/null) | tar -xf - -C "$copy"
printf '#!/usr/bin/env bash\nexit 0\n' > "$copy/gradlew"; chmod +x "$copy/gradlew"
for d in "$copy"/bricks/*/; do (cd "$copy" && GRADLE=./gradlew scripts/brick.sh add "$(basename "$d")" >/dev/null) || fail "brick add failed for $d"; done

docker compose -f "$copy/compose.yml" --env-file "$copy/.env.example" --profile full --profile observability config -q \
  || fail "compose.yml with every brick does not validate"
prod "$copy" "$fixture_env" -q || fail "compose.prod.yml with every brick does not validate"
if prod "$copy" /dev/null -q 2>/dev/null; then fail "with every brick, an empty env validated; a :? guard is gone"; fi
all="$(prod "$copy")"
for svc in backup alloy; do grep -qE "^  ${svc}:" <<<"$all" || fail "brick service ${svc} missing from the all-bricks render"; done  # TODO(minio brick): add minio
# Every brick service is memory-limited and never rolled by Watchtower.
for svc in backup alloy; do  # TODO(minio brick): add minio
  svc_block "$svc" <<<"$all" | grep -q 'mem_limit' || fail "${svc} has no mem_limit"
  svc_block "$svc" <<<"$all" | grep -q 'com.centurylinklabs.watchtower.enable: "false"' || fail "${svc} is not excluded from Watchtower"
done
# Alloy reads the backup sidecar's textfile from the shared volume.
grep -q 'target: /metrics/backup' <<<"$all" || fail "alloy does not mount the backup metrics volume"
grep -q 'prometheus.exporter.unix "backup"' "$root/bricks/observability/alloy/config.alloy" || fail "alloy has no backup textfile pipeline"
docker run --rm -v "$root/bricks/observability/alloy/config.alloy:/c.alloy:ro" grafana/alloy:v1.10.0 fmt /c.alloy >/dev/null \
  || fail "config.alloy does not parse"
# rclone saves its config (refreshed tokens) by rename, which a single-file bind mount rejects: mount the directory.
grep -q 'RCLONE_CONFIG: /config/rclone/rclone.conf' <<<"$all" || fail "backup does not point rclone at the config inside the mounted directory"
grep -q 'target: /config/rclone$' <<<"$all" || fail "rclone config is not mounted as a directory"
grep -q 'target: /config/rclone.conf' <<<"$all" && fail "rclone.conf is still mounted as a single file"
grep -A6 'target: /config/rclone$' "$root/bricks/backup/compose.prod.yml" | grep -q 'create_host_path: false' \
  || fail "rclone config mount would be auto-created"
grep -q "source: $copy/bricks/backup/rclone" <<<"$all" || fail "rclone config dir does not resolve relative to the brick"
grep -q 'target: /var/lock/backup' <<<"$all" || fail "backup lock is not on a shared volume"
grep -q 'target: /metrics$' <<<"$all" || fail "backup metrics volume missing"
git -C "$root" check-ignore -q bricks/backup/rclone/rclone.conf || fail "bricks/backup/rclone/rclone.conf is not gitignored"
# The minio brick extends app: endpoint env and a healthy-minio dependency.
# TODO(minio brick): enable these two assertions
#svc_block app <<<"$all" | grep -q 'APP_MINIO_ENDPOINT: http://minio:9000' || fail "app lacks APP_MINIO_ENDPOINT"
#svc_block app <<<"$all" | grep -q 'minio:' || fail "app does not depend on minio"
echo "deploy-config: all passed"
