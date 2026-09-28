#!/usr/bin/env bash
# Exercises the prod-backup-* and prod-restore Makefile targets with a fake `docker compose` passed as PROD.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/compose" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$COMPOSE_LOG"
case "$*" in
  "ps --status running --services") printf '%s\n' ${FAKE_RUNNING:-}; exit "${FAKE_PS_RC:-0}" ;;
  "stop "*) exit "${FAKE_STOP_RC:-0}" ;;
  *" run "*) exit "${FAKE_RUN_RC:-0}" ;;
esac
FAKE
chmod +x "$tmp/compose"
export COMPOSE_LOG="$tmp/compose.log"
mk=(make -s -C "$root" --no-print-directory PROD="$tmp/compose")

# No STAMP: usage error, compose never called.
: > "$COMPOSE_LOG"
if "${mk[@]}" prod-restore </dev/null >/dev/null 2>&1; then fail "prod-restore without STAMP exited 0"; fi
[[ -s "$COMPOSE_LOG" ]] && fail "compose called without STAMP"

# Not confirmed: aborted before anything is stopped.
if echo no | "${mk[@]}" prod-restore STAMP=latest >/dev/null 2>&1; then fail "restore ran after 'no'"; fi
[[ -s "$COMPOSE_LOG" ]] && fail "compose called although the restore was not confirmed: $(cat "$COMPOSE_LOG")"

# Confirmed, Watchtower running: app and Watchtower stopped, restore, both started again, in that order.
: > "$COMPOSE_LOG"
echo yes | FAKE_RUNNING="app watchtower db" "${mk[@]}" prod-restore STAMP=latest >/dev/null || fail "confirmed restore failed"
expected="ps --status running --services
stop app watchtower
--profile backup run --rm -e RESTORE_CONFIRM=yes backup restore latest
start app watchtower"
[[ "$(cat "$COMPOSE_LOG")" == "$expected" ]] || fail "unexpected sequence: $(cat "$COMPOSE_LOG")"

# Watchtower stopped on purpose (prod-rollback pin): restore must leave it stopped.
: > "$COMPOSE_LOG"
FAKE_RUNNING="app db" "${mk[@]}" prod-restore STAMP=20260101T000000Z CONFIRM=yes >/dev/null || fail "CONFIRM=yes restore failed"
grep -q watchtower "$COMPOSE_LOG" && fail "restore touched a Watchtower that was stopped: $(cat "$COMPOSE_LOG")"

# Failed restore: the app comes back anyway and the target fails.
: > "$COMPOSE_LOG"
if FAKE_RUN_RC=1 FAKE_RUNNING="app watchtower" "${mk[@]}" prod-restore STAMP=latest CONFIRM=yes >/dev/null 2>&1; then
  fail "failed restore exited 0"
fi
[[ "$(tail -n1 "$COMPOSE_LOG")" == "start app watchtower" ]] || fail "app not restarted after a failed restore: $(cat "$COMPOSE_LOG")"

# ps fails: nothing changed, nothing to restart because nothing was stopped.
: > "$COMPOSE_LOG"
if FAKE_PS_RC=1 "${mk[@]}" prod-restore STAMP=latest CONFIRM=yes >/dev/null 2>&1; then
  fail "restore exited 0 although ps failed"
fi
grep -q '^stop ' "$COMPOSE_LOG" && fail "stop was called although ps failed: $(cat "$COMPOSE_LOG")"
grep -q ' run ' "$COMPOSE_LOG" && fail "restore ran although ps failed: $(cat "$COMPOSE_LOG")"

# stop fails: app (and watchtower, if it was running) is started again, restore never runs.
: > "$COMPOSE_LOG"
if FAKE_STOP_RC=1 FAKE_RUNNING="app watchtower" "${mk[@]}" prod-restore STAMP=latest CONFIRM=yes >/dev/null 2>&1; then
  fail "restore exited 0 although stop failed"
fi
grep -q ' run ' "$COMPOSE_LOG" && fail "restore ran although stop failed: $(cat "$COMPOSE_LOG")"
[[ "$(tail -n1 "$COMPOSE_LOG")" == "start app watchtower" ]] \
  || fail "app not restarted after a failed stop: $(cat "$COMPOSE_LOG")"

# STAMP carrying shell metacharacters is rejected outright, never reaches a shell as code.
: > "$COMPOSE_LOG"
marker="$tmp/pwned"
if "${mk[@]}" prod-restore "STAMP=latest; touch $marker" CONFIRM=yes >/dev/null 2>&1; then
  fail "restore exited 0 with a metacharacter STAMP"
fi
[[ -e "$marker" ]] && fail "STAMP was interpreted as shell code: marker file created"
[[ -s "$COMPOSE_LOG" ]] && fail "compose called with an invalid STAMP: $(cat "$COMPOSE_LOG")"

# Malformed stamp (not "latest", not YYYYMMDDTHHMMSSZ): usage error, compose never called.
: > "$COMPOSE_LOG"
if "${mk[@]}" prod-restore STAMP=2026 CONFIRM=yes >/dev/null 2>&1; then
  fail "restore exited 0 with a malformed STAMP"
fi
[[ -s "$COMPOSE_LOG" ]] && fail "compose called with a malformed STAMP: $(cat "$COMPOSE_LOG")"

# Backup verbs force the profile, so they work on a host whose .env.prod does not enable it.
for pair in now:once status:status list:list; do
  : > "$COMPOSE_LOG"
  "${mk[@]}" "prod-backup-${pair%%:*}" >/dev/null || fail "prod-backup-${pair%%:*} failed"
  [[ "$(cat "$COMPOSE_LOG")" == "--profile backup run --rm backup ${pair#*:}" ]] \
    || fail "prod-backup-${pair%%:*}: $(cat "$COMPOSE_LOG")"
done

echo "make-backup: all passed"
