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
# rclone saves its config (refreshed tokens) by rename, which a single-file bind mount rejects: mount the directory.
grep -q 'RCLONE_CONFIG: /config/rclone/rclone.conf' <<<"$rendered_backup" \
  || fail "backup does not point rclone at the config inside the mounted directory"
grep -q 'target: /config/rclone$' <<<"$rendered_backup" || fail "rclone config is not mounted as a directory"
grep -q 'target: /config/rclone.conf' <<<"$rendered_backup" && fail "rclone.conf is still mounted as a single file"
# A missing config directory must fail loudly, not be created empty (backups would then fail far less clearly).
# Checked in the source: Compose v2 omits `create_host_path: false` from `config` output (false is its default), v5
# prints it, so the rendered text cannot prove it on every runner. It can prove nobody turned it on.
grep -A6 'target: /config/rclone$' "$root/deploy/compose.prod.yml" | grep -q 'create_host_path: false' \
  || fail "rclone config mount would be auto-created"
grep -A3 'target: /config/rclone$' <<<"$rendered_backup" | grep -q 'create_host_path: true' \
  && fail "rclone config mount would be auto-created"
grep -q 'target: /var/lock/backup' <<<"$rendered_backup" || fail "backup lock is not on a shared volume"
grep -q 'target: /metrics$' <<<"$rendered_backup" || fail "backup metrics volume missing"
git -C "$root" check-ignore -q deploy/backup/rclone/rclone.conf || fail "deploy/backup/rclone/rclone.conf is not gitignored"

# The rclone tokens live next to the Dockerfile: the build context must carry only what the image needs.
[[ -f "$root/deploy/backup/.dockerignore" ]] || fail "deploy/backup has no .dockerignore (rclone tokens would enter the build context)"
ctx="$(mktemp -d)"; mkdir -p "$ctx/rclone"; echo secret > "$ctx/rclone/rclone.conf"
cp "$root/deploy/backup/backup.sh" "$root/deploy/backup/.dockerignore" "$ctx/"
printf 'FROM busybox\nCOPY . /ctx\nRUN find /ctx -type f | sort\n' > "$ctx/Dockerfile.ctx"
listing="$(docker build --no-cache --progress=plain -f "$ctx/Dockerfile.ctx" "$ctx" 2>&1)" || fail "context probe build failed: $listing"
rm -rf "$ctx"
grep -q '/ctx/backup.sh' <<<"$listing" || fail "backup.sh missing from the build context"
grep -q '/ctx/rclone' <<<"$listing" && fail "rclone config reaches the docker build context"

sh -n "$root/deploy/backup/backup.sh" || fail "backup.sh has a syntax error"
if command -v shellcheck >/dev/null; then shellcheck -s sh "$root/deploy/backup/backup.sh" || fail "shellcheck backup.sh"; fi

echo "deploy-config: all passed"
