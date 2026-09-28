#!/usr/bin/env bash
# Validates the compose files and the Caddyfile with the real tools. Skips (exit 0) when Docker is unavailable.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

if ! docker info >/dev/null 2>&1; then echo "deploy-config: skipped (no docker)"; exit 0; fi

docker compose -f "$root/compose.yml" --env-file "$root/.env.example" --profile observability --profile full config -q \
  || fail "compose.yml does not validate"

docker compose -f "$root/deploy/compose.prod.yml" --env-file "$here/fixtures/env.prod.test" config -q \
  || fail "deploy/compose.prod.yml does not validate with the fixture env"

# Every required variable must be guarded: an empty env file has to fail on the :? guards, not silently start.
if docker compose -f "$root/deploy/compose.prod.yml" --env-file /dev/null config -q 2>/dev/null; then
  fail "compose.prod.yml validated with no environment; a required variable lost its :? guard"
fi

rendered="$(docker compose -f "$root/deploy/compose.prod.yml" --env-file "$here/fixtures/env.prod.test" config)"
# Private-registry credentials: the mount must be a FILE ending in config.json, or Watchtower sees a directory.
rendered_cfg="$(DOCKER_CONFIG_FILE=/home/u/.docker/config.json docker compose -f "$root/deploy/compose.prod.yml" --env-file "$here/fixtures/env.prod.test" config)"
grep -q 'source: /home/u/.docker/config.json' <<<"$rendered_cfg" || fail "DOCKER_CONFIG_FILE is not mounted as the file /config.json"
grep -q 'source: /dev/null' <<<"$rendered" || fail "default registry credential mount should be /dev/null"
# Rolling restart must wait for the new replica to be healthy before the next one is stopped.
grep -q 'WATCHTOWER_LIFECYCLE_HOOKS: "true"' <<<"$rendered" || fail "Watchtower lifecycle hooks not enabled"
grep -q 'com.centurylinklabs.watchtower.lifecycle.post-update:' <<<"$rendered" || fail "app has no post-update health wait hook"
# A single 5xx must not eject a replica from Caddy's rotation.
grep -q 'unhealthy_status' "$root/deploy/Caddyfile" && fail "Caddyfile ejects replicas on 5xx responses"

# Alloy reads the backup sidecar's textfile from the shared volume.
grep -q 'target: /metrics/backup' <<<"$(docker compose -f "$root/deploy/compose.prod.yml" --env-file "$here/fixtures/env.prod.test" --profile observability config)" \
  || fail "alloy does not mount the backup metrics volume"
grep -q 'prometheus.exporter.unix "backup"' "$root/deploy/alloy/config.alloy" || fail "alloy has no backup textfile pipeline"
docker run --rm -v "$root/deploy/alloy/config.alloy:/c.alloy:ro" grafana/alloy:v1.10.0 fmt /c.alloy >/dev/null \
  || fail "config.alloy does not parse"

docker run --rm -v "$root/deploy/Caddyfile:/etc/caddy/Caddyfile:ro" -e DOMAIN=example.com -e ACME_EMAIL=ops@example.com \
  caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 || fail "Caddyfile does not validate"

# Backups are opt-in: absent without the profile, valid with it.
grep -qE '^  backup:' <<<"$rendered" && fail "backup service must only exist with the backup profile"
rendered_backup="$(docker compose -f "$root/deploy/compose.prod.yml" --env-file "$here/fixtures/env.prod.test" --profile backup config)" \
  || fail "deploy/compose.prod.yml does not validate with the backup profile"
grep -q 'RCLONE_CONFIG: /config/rclone.conf' <<<"$rendered_backup" || fail "backup does not point rclone at the mounted config"
# A missing rclone.conf must fail loudly, not become a directory the later scp lands inside.
grep -q 'create_host_path: false' <<<"$rendered_backup" || fail "rclone.conf mount would be auto-created as a directory"
grep -q 'target: /var/lock/backup' <<<"$rendered_backup" || fail "backup lock is not on a shared volume"
grep -q 'target: /metrics$' <<<"$rendered_backup" || fail "backup metrics volume missing"
git -C "$root" check-ignore -q deploy/backup/rclone.conf || fail "deploy/backup/rclone.conf is not gitignored"

sh -n "$root/deploy/backup/backup.sh" || fail "backup.sh has a syntax error"
if command -v shellcheck >/dev/null; then shellcheck -s sh "$root/deploy/backup/backup.sh" || fail "shellcheck backup.sh"; fi

echo "deploy-config: all passed"
