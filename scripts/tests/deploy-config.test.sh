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

docker run --rm -v "$root/deploy/Caddyfile:/etc/caddy/Caddyfile:ro" -e DOMAIN=example.com -e ACME_EMAIL=ops@example.com \
  caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 || fail "Caddyfile does not validate"

bash -n "$root/deploy/backup/backup.sh" || fail "backup.sh has a syntax error"

echo "deploy-config: all passed"
