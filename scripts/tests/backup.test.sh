#!/usr/bin/env bash
# Exercises deploy/backup/backup.sh under POSIX sh (as the alpine container runs it) with fake pg_* and rclone
# binaries. No Docker, no network: the "remote" is a directory.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
script="$root/deploy/backup/backup.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# rclone: "name:path" lives under $FAKE_REMOTE_ROOT/name/path, anything else is a local path. Flags that take a value
# (--transfers 2 …) are skipped.
cat > "$tmp/bin/rclone" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
echo "rclone $*" >> "$CALL_LOG"
map() { if [[ "$1" == *:* ]]; then printf '%s/%s/%s' "$FAKE_REMOTE_ROOT" "${1%%:*}" "${1#*:}"; else printf '%s' "$1"; fi; }
cmd="$1"; shift
pos=()
while (($#)); do case "$1" in --*) shift 2 ;; *) pos+=("$1"); shift ;; esac; done
case "$cmd" in
  mkdir) mkdir -p "$(map "${pos[0]}")" ;;
  copyto) src="$(map "${pos[0]}")"; dst="$(map "${pos[1]}")"; [[ -f "$src" ]] || exit 3
          mkdir -p "$(dirname "$dst")"; cp "$src" "$dst" ;;
  lsf) p="$(map "${pos[0]}")"
       if [[ -d "$p" ]]; then ls -1 "$p"; elif [[ -f "$p" ]]; then basename "$p"; else exit 3; fi ;;
  cat) p="$(map "${pos[0]}")"; [[ -f "$p" ]] || exit 3; cat "$p" ;;
  rcat) p="$(map "${pos[0]}")"; [[ "${FAKE_RCAT_FAIL:-}" != 1 ]] || exit 1; mkdir -p "$(dirname "$p")"; cat > "$p" ;;
  deletefile) rm "$(map "${pos[0]}")" ;;
  *) echo "fake rclone: unsupported $cmd" >&2; exit 2 ;;
esac
FAKE
cat > "$tmp/bin/pg_dump" <<'FAKE'
#!/usr/bin/env bash
echo "pg_dump $*" >> "$CALL_LOG"
[[ "${FAKE_PG_DUMP_FAIL:-}" != 1 ]] || exit 1
for a in "$@"; do case "$a" in --file=*) echo "dump-of-${FAKE_DB_STATE:-db}" > "${a#--file=}" ;; esac; done
FAKE
cat > "$tmp/bin/pg_restore" <<'FAKE'
#!/usr/bin/env bash
file="${*: -1}"
echo "pg_restore $* <= $(cat "$file")" >> "$CALL_LOG"
[[ "${FAKE_PG_RESTORE_FAIL:-}" != 1 ]] || exit 1
FAKE
cat > "$tmp/bin/pg_isready" <<'FAKE'
#!/usr/bin/env bash
exit "${FAKE_PG_READY_RC:-0}"
FAKE
chmod +x "$tmp"/bin/*

export PATH="$tmp/bin:$PATH" CALL_LOG="$tmp/calls.log" FAKE_REMOTE_ROOT="$tmp/remote"
export BACKUP_TMP="$tmp/work" BACKUP_LOCK="$tmp/lock/lock" BACKUP_METRICS_DIR="$tmp/metrics"
export RCLONE_REMOTE=remote:svc POSTGRES_PASSWORD=pw
store="$tmp/remote/remote/svc"
prom="$tmp/metrics/backup.prom"
reset() { rm -rf "$tmp/remote" "$tmp/metrics" "$tmp/work" "$tmp/plain" "$tmp/lock"; mkdir -p "$tmp/work"; : > "$CALL_LOG"; }
days_ago() { date -u -d "-$1 days" +%Y%m%dT%H%M%SZ; }
epoch_of() { date -u -d "$(echo "$1" | sed -E 's/^(....)(..)(..)T(..)(..)(..)Z$/\1-\2-\3 \4:\5:\6/')" +%s; }

sh "$script" --help | grep -q "backup.sh once" || fail "--help does not print the header"

# once: dump uploaded, last-success recorded, metric published and readable by Alloy even under umask 077,
# a leftover partial dump from a crashed run removed.
reset
echo partial > "$tmp/work/20200101T000000Z.dump"
(umask 077; sh "$script" once >/dev/null) || fail "once failed: $(cat "$CALL_LOG")"
dumps=("$store"/postgres/*.dump)
[[ ${#dumps[@]} -eq 1 && -f "${dumps[0]}" ]] || fail "expected one dump, got: ${dumps[*]}"
[[ "$(cat "${dumps[0]}")" == dump-of-db ]] || fail "dump content wrong"
stamp="$(basename "${dumps[0]}" .dump)"
[[ "$(cat "$store/last-success")" == "$stamp" ]] || fail "last-success is not $stamp"
grep -qx "app_backup_last_run_success 1" "$prom" || fail "metric: $(cat "$prom")"
grep -qx "app_backup_last_success_timestamp_seconds $(epoch_of "$stamp")" "$prom" || fail "metric ts: $(cat "$prom")"
[[ "$(stat -c %a "$prom")" == 644 ]] || fail "backup.prom must be 644 for Alloy, is $(stat -c %a "$prom")"
compgen -G "$tmp/work/*.dump" >/dev/null && fail "dump left in the temp dir"

# preflight: no remote → clear message, failure reported as a metric.
reset
if out="$(env -u RCLONE_REMOTE sh "$script" once 2>&1)"; then fail "once without RCLONE_REMOTE exited 0"; fi
[[ "$out" == *RCLONE_REMOTE* ]] || fail "no hint about RCLONE_REMOTE: $out"
grep -qx "app_backup_last_run_success 0" "$prom" || fail "failed run not reported: $(cat "$prom" 2>&1)"

# preflight: a bare path would be this host's own disk → refused unless explicitly allowed.
reset
if out="$(RCLONE_REMOTE="$tmp/plain" sh "$script" once 2>&1)"; then fail "local-path remote accepted"; fi
[[ "$out" == *"name:"* ]] || fail "no explanation for refusing a local path: $out"
[[ -e "$tmp/plain" ]] && fail "refused remote was written to"
RCLONE_REMOTE="$tmp/plain" BACKUP_ALLOW_LOCAL_REMOTE=1 sh "$script" once >/dev/null \
  || fail "BACKUP_ALLOW_LOCAL_REMOTE=1 did not allow a local path"
compgen -G "$tmp/plain/postgres/*.dump" >/dev/null || fail "no dump in the local-path remote"

# retention: decided by the stamp in the name, not mtime; non-stamp names untouched; pre-restore pruned too.
reset
mkdir -p "$store/postgres" "$store/pre-restore"
old="$(days_ago 40)"; recent="$(days_ago 5)"
echo x > "$store/postgres/$old.dump"
echo x > "$store/postgres/$recent.dump"; touch -d '100 days ago' "$store/postgres/$recent.dump"
echo x > "$store/postgres/notes.txt"; touch -d '100 days ago' "$store/postgres/notes.txt"
echo x > "$store/pre-restore/$old.dump"
sh "$script" once >/dev/null
[[ -e "$store/postgres/$old.dump" ]] && fail "dump older than retention kept"
[[ -e "$store/pre-restore/$old.dump" ]] && fail "old pre-restore dump kept"
[[ -e "$store/postgres/$recent.dump" ]] || fail "recent dump pruned (by mtime?)"
[[ -e "$store/postgres/notes.txt" ]] || fail "non-stamp file pruned"

# a failed run prunes nothing, keeps last-success, reports 0 with the previous success time.
reset
sh "$script" once >/dev/null
good="$(cat "$store/last-success")"
old="$(days_ago 40)"; echo x > "$store/postgres/$old.dump"
if FAKE_PG_DUMP_FAIL=1 sh "$script" once >/dev/null 2>&1; then fail "once exited 0 although pg_dump failed"; fi
[[ -e "$store/postgres/$old.dump" ]] || fail "a failed run pruned"
[[ "$(cat "$store/last-success")" == "$good" ]] || fail "a failed run moved last-success"
grep -qx "app_backup_last_run_success 0" "$prom" || fail "failure not reported: $(cat "$prom")"
grep -qx "app_backup_last_success_timestamp_seconds $(epoch_of "$good")" "$prom" \
  || fail "failed run lost the last success time: $(cat "$prom")"

# a run whose last-success write fails is a failed run.
reset
if FAKE_RCAT_FAIL=1 sh "$script" once >/dev/null 2>&1; then fail "once exited 0 although last-success was not written"; fi
grep -qx "app_backup_last_run_success 0" "$prom" || fail "unrecorded success reported as success"

# lock: a second run while one holds the lock exits non-zero and touches nothing.
reset
mkdir -p "$tmp/lock"
exec 8>"$BACKUP_LOCK"; flock -n 8
if out="$(sh "$script" once 2>&1)"; then fail "once ran while the lock was held"; fi
exec 8>&-
[[ "$out" == *"another backup or restore"* ]] || fail "unclear lock message: $out"
compgen -G "$store/postgres/*.dump" >/dev/null && fail "locked-out run still uploaded"

# metrics: seeds from the remote when there is no file; never overwrites an existing one (a recreated container
# must not hide the previous run's failure).
reset
mkdir -p "$store"; echo 20260101T000000Z > "$store/last-success"
sh "$script" metrics
grep -qx "app_backup_last_success_timestamp_seconds $(epoch_of 20260101T000000Z)" "$prom" \
  || fail "metrics did not seed from last-success: $(cat "$prom")"
printf 'app_backup_last_run_success 0\n' > "$prom"
sh "$script" metrics
grep -qx "app_backup_last_run_success 0" "$prom" || fail "metrics overwrote an existing file"

# a run whose metric cannot be written is a failed run, even though the dump and last-success succeeded.
reset
: > "$tmp/metrics"
if sh "$script" once >/dev/null 2>&1; then fail "once exited 0 although the backup metric could not be written"; fi

echo "backup: all passed"
