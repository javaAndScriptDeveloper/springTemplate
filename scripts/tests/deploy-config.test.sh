#!/usr/bin/env bash
# Validates the compose files and the Caddyfile with the real tools. Skips (exit 0) when Docker is unavailable.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

# Compose < 5 rejects a service that an include: redefines (services.app conflicts with imported resource), so a
# brick's partial of a core service belongs in override(.prod).yml, which -f merges. Static: needs no Docker.
for f in "$root"/bricks/*/compose.yml "$root"/bricks/*/compose.prod.yml; do
  [[ -f "$f" ]] || continue
  if grep -qE '^  (app|db|caddy|watchtower):' "$f"; then
    fail "brick ${f#"$root"/} redefines a core service inside an include: move the partial to override(.prod).yml"
  fi
done

if ! docker info >/dev/null 2>&1; then echo "deploy-config: skipped (no docker)"; exit 0; fi

fixture_env="$here/fixtures/env.prod.test"
# Renders through the Makefile, the one place that builds the -f list (core file plus each brick's override.prod.yml).
prod() { (cd "$1" && eval "$(make -s --no-print-directory print-prod PROD_ENV_FILE="${2:-$fixture_env}") config ${*:3}"); }

# Lines of one top-level service in a rendered config (a plain awk range would end on its own first line).
svc_block() { awk -v s="$1" '$0 ~ "^  " s ":" {f=1; next} f && /^  [a-z]/ {f=0} f'; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# Copies the working tree (tracked and untracked, minus deleted files) to $1 with a stub gradlew.
scratch() {
  mkdir -p "$1"
  # Files deleted in the working tree are still "cached"; leave them out or tar exits non-zero.
  (cd "$root" && comm -z -23 <(git ls-files -z --cached --others --exclude-standard | sort -z) <(git ls-files -z --deleted | sort -z) \
    | tar --null -T - -cf - 2>/dev/null) | tar -xf - -C "$1"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$1/gradlew"; chmod +x "$1/gradlew"
}
# The core stack is rendered from a copy with every enabled brick removed, so the test holds in a project with bricks.
core="$tmp/core"; scratch "$core"
for b in $(grep -vE '^\s*(#|$)' "$core/.bricks" 2>/dev/null || true); do (cd "$core" && GRADLE=./gradlew scripts/brick.sh remove "$b" >/dev/null) || fail "brick remove failed for $b"; done

# --- core, no bricks ---------------------------------------------------------------------------------------------
make -s -C "$core" config || fail "compose.yml does not validate"
make -s -C "$core" prod-config PROD_ENV_FILE="$fixture_env" || fail "make prod-config fails with the fixture env"
prod "$core" "$fixture_env" -q || fail "deploy/compose.prod.yml does not validate with the fixture env"
if prod "$core" /dev/null -q 2>/dev/null; then fail "compose.prod.yml validated with no environment; a required variable lost its :? guard"; fi
rendered="$(prod "$core")"
for svc in backup alloy minio prometheus grafana; do
  grep -qE "^  ${svc}:" <<<"$rendered" && fail "core prod stack contains brick service ${svc}"
done
rendered_cfg="$(DOCKER_CONFIG_FILE=/home/u/.docker/config.json prod "$core")"
grep -q 'source: /home/u/.docker/config.json' <<<"$rendered_cfg" || fail "DOCKER_CONFIG_FILE is not mounted as the file /config.json"
grep -q 'source: /dev/null' <<<"$rendered" || fail "default registry credential mount should be /dev/null"
grep -q 'WATCHTOWER_LIFECYCLE_HOOKS: "true"' <<<"$rendered" || fail "Watchtower lifecycle hooks not enabled"
grep -q 'com.centurylinklabs.watchtower.lifecycle.post-update:' <<<"$rendered" || fail "app has no post-update health wait hook"
grep -q 'unhealthy_status' "$root/deploy/Caddyfile" && fail "Caddyfile ejects replicas on 5xx responses"
docker run --rm -v "$root/deploy/Caddyfile:/etc/caddy/Caddyfile:ro" -e DOMAIN=example.com -e ACME_EMAIL=ops@example.com \
  caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 || fail "Caddyfile does not validate"

# --- every brick added, on a scratch copy of the working tree ---------------------------------------------------
copy="$tmp/repo"; scratch "$copy"
for d in "$copy"/bricks/*/; do (cd "$copy" && GRADLE=./gradlew scripts/brick.sh add "$(basename "$d")" >/dev/null) || fail "brick add failed for $d"; done

make -s -C "$copy" config \
  || fail "compose.yml with every brick does not validate"
make -s -C "$copy" prod-config PROD_ENV_FILE="$fixture_env" || fail "make prod-config with every brick fails"
prod "$copy" "$fixture_env" -q || fail "compose.prod.yml with every brick does not validate"
if prod "$copy" /dev/null -q 2>/dev/null; then fail "with every brick, an empty env validated; a :? guard is gone"; fi
all="$(prod "$copy")"
for svc in backup alloy minio; do grep -qE "^  ${svc}:" <<<"$all" || fail "brick service ${svc} missing from the all-bricks render"; done
# Every brick service is memory-limited and never rolled by Watchtower.
for svc in backup alloy minio; do
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
svc_block app <<<"$all" | grep -q 'APP_MINIO_ENDPOINT: http://minio:9000' || fail "app lacks APP_MINIO_ENDPOINT"
svc_block app <<<"$all" | grep -qE '^ {6}minio:$' || fail "app does not depend on minio"
# The partial-service merge must not drop the core app labels Watchtower relies on.
grep -q 'com.centurylinklabs.watchtower.lifecycle.post-update:' <<<"$all" || fail "core app post-update label lost in the merge"
svc_block app <<<"$all" | grep -q 'com.centurylinklabs.watchtower.enable: "true"' || fail "app lost its watchtower.enable label in the merge"
# The rclone tokens live next to the Dockerfile: the build context must carry only what the image needs.
[[ -f "$root/bricks/backup/.dockerignore" ]] || fail "bricks/backup has no .dockerignore (rclone tokens would enter the build context)"
ctx="$(mktemp -d)"; mkdir -p "$ctx/rclone"; echo secret > "$ctx/rclone/rclone.conf"
cp "$root/bricks/backup/backup.sh" "$root/bricks/backup/.dockerignore" "$ctx/"
printf 'FROM busybox\nCOPY . /ctx\nRUN find /ctx -type f | sort\n' > "$ctx/Dockerfile.ctx"
listing="$(docker build --no-cache --progress=plain -f "$ctx/Dockerfile.ctx" "$ctx" 2>&1)" || fail "context probe build failed: $listing"
rm -rf "$ctx"
grep -q '/ctx/backup.sh' <<<"$listing" || fail "backup.sh missing from the build context"
grep -q '/ctx/rclone' <<<"$listing" && fail "rclone config reaches the docker build context"

sh -n "$root/bricks/backup/backup.sh" || fail "backup.sh has a syntax error"
if command -v shellcheck >/dev/null; then shellcheck -s sh "$root/bricks/backup/backup.sh" || fail "shellcheck backup.sh"; fi

echo "deploy-config: all passed"
