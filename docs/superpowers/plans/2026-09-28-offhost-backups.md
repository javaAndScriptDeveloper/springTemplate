# Off-host rclone Backups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the local-disk `pg_dump` sidecar with an opt-in sidecar that uploads dumps to an rclone remote, restores from it safely, and reports freshness to Grafana.

**Architecture:** One POSIX `sh` script (`deploy/backup/backup.sh`) in an alpine image does all data work (`schedule|once|status|list|metrics|restore`). Compose runs it under profile `backup`; Make targets and `scripts/vps.sh` are thin wrappers. Freshness goes out as a Prometheus textfile on a shared volume that Alloy reads with `prometheus.exporter.unix` (textfile collector only); a Grafana rule `BackupStale` alerts on it.

**Tech Stack:** POSIX sh + busybox crond, rclone, postgresql17-client, Docker Compose profiles, Grafana Alloy v1.10, Grafana alert provisioning JSON, bash tests (`scripts/tests`), JUnit 5 + AssertJ (`DashboardJsonTest`).

**Spec:** `docs/superpowers/specs/2026-09-28-offhost-backups-design.md`

## Global Constraints

- Backups are opt-in: compose profile `backup`; no `:?` guards on backup variables (compose interpolates profiled services even when the profile is off). `POSTGRES_PASSWORD` keeps its existing `:?`.
- No local-disk backup mode. A remote without a `name:` prefix is refused unless `BACKUP_ALLOW_LOCAL_REMOTE=1` (tests/manual checks only).
- Remote layout: `postgres/<stamp>.dump`, `pre-restore/<stamp>.dump`, `last-success`. Stamp format `YYYYMMDDTHHMMSSZ`, UTC.
- Defaults: `BACKUP_CRON=0 */6 * * *`, `BACKUP_TZ=UTC` (see deviation note in Task 7), `BACKUP_RETENTION_DAYS=30`, `BACKUP_MAX_AGE_HOURS=12`.
- A failing run never prunes and never moves `last-success`. Pruning is decided by the stamp in the **name**, never mtime.
- `restore latest` resolves through `last-success`, never "newest file". Restore requires `RESTORE_CONFIRM=yes`, uploads a safety dump first, runs `pg_restore --clean --if-exists --no-owner --single-transaction`.
- Metric names: `app_backup_last_success_timestamp_seconds`, `app_backup_last_run_success`. File `backup.prom`, mode 0644.
- `BackupStale`: group `app-baseline`, severity `critical`, `for: 15m`, threshold 43200 s, `noDataState: OK`.
- `backup` mem_limit stays 64m; rclone flags `--transfers 2 --checkers 4 --buffer-size 8M`.
- `rclone.conf` is gitignored and mounted **read-write** (OAuth tokens refresh into it) with `create_host_path: false`.
- Bash scripts: `set -euo pipefail` and a header comment that doubles as `--help` (`backup.sh` is POSIX `sh`: `set -eu`).
- Commits: `<type>(<scope>): <imperative summary>` ≤72 chars, body explains why, end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never `!`.
- Run `make format` before any commit touching Java.

## Review Focus

1. **Alloy cannot read the metric file** because `schedule` sets `umask 077` for the env file and cron jobs inherit it → `write_metrics` must `chmod 644`. Pinned in Task 1 (run under `umask 077`, assert mode 644).
2. **Restore after `make prod-rollback`** (Watchtower deliberately stopped) must not start Watchtower again, or the pin is silently undone. Pinned in Task 4.
3. **`rclone.conf` missing on the VPS**: a short-syntax bind mount makes Docker create a *directory* there, and the later `scp` lands inside it. Long syntax with `create_host_path: false`. Pinned in Task 3.
4. **A run that uploaded its dump but failed before `last-success`** leaves a newer dump; `restore latest` must still pick the last successful one, and `list` must mark the newer one. Pinned in Task 2.
5. **A crashed run leaves a partial dump in the temp dir** (fills a small disk over time) → the next `once` removes leftovers. Pinned in Task 1.

---

### Task 1: backup.sh core — once, metrics, preflight, prune, lock

**Files:**
- Modify (full rewrite): `deploy/backup/backup.sh`
- Create: `scripts/tests/backup.test.sh`

**Interfaces:**
- Produces (used by Tasks 2–8):
  - CLI: `backup.sh [schedule|once|metrics|--help]` (Task 2 adds `status|list|restore`).
  - Env: `RCLONE_REMOTE`, `BACKUP_ALLOW_LOCAL_REMOTE`, `BACKUP_RETENTION_DAYS`, `BACKUP_MAX_AGE_HOURS`, `BACKUP_CRON`, `BACKUP_TMP` (default `/tmp`), `BACKUP_LOCK` (default `/var/lock/backup/lock`), `BACKUP_METRICS_DIR` (default `/metrics`), `POSTGRES_HOST` (default `db`), `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`, `TZ`.
  - Shell functions Task 2 relies on: `log`, `die`, `stamp_now`, `is_stamp STAMP`, `stamp_epoch STAMP`, `pg CMD ARGS…` (connection flags first), `last_success` (prints stamp, non-zero if none), `preflight`, `locked FN ARGS…`, variables `REMOTE`, `TMP_DIR`, `MAX_AGE_HOURS`, `RCLONE_FLAGS`.
  - Test fakes in `backup.test.sh` (Task 2 appends cases to this file): `rclone` (mkdir/copyto/lsf/cat/rcat/deletefile over `$FAKE_REMOTE_ROOT`), `pg_dump` (writes `dump-of-${FAKE_DB_STATE:-db}`, fails with `FAKE_PG_DUMP_FAIL=1`), `pg_restore` (logs `pg_restore ARGS <= <file content>`), `pg_isready`; all log to `$CALL_LOG`. Helpers `reset`, `days_ago N`, `epoch_of STAMP`; vars `store`, `prom`.

- [ ] **Step 1: Write the failing test** — create `scripts/tests/backup.test.sh`:

```bash
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

echo "backup: all passed"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash scripts/tests/backup.test.sh`
Expected: FAIL — the current script has no `--help` header match for `backup.sh once` in the new form, or fails at `once` (it writes to `/backups`). Any `FAIL:` line is acceptable; a pass is not.

- [ ] **Step 3: Rewrite `deploy/backup/backup.sh`** (tabs for indentation, as today):

```sh
#!/bin/sh
# Backs up the production database to an off-host rclone remote ($RCLONE_REMOTE, e.g. gdrive:myservice). Nothing is
# kept on the VPS: a dump next to the database does not survive losing that disk.
#
#   backup.sh schedule        preflight, then `once` on $BACKUP_CRON (default; the long-running container)
#   backup.sh once            one backup now
#   backup.sh status          last successful backup and its age; non-zero if missing or older than BACKUP_MAX_AGE_HOURS
#   backup.sh list            database dumps on the remote, oldest first
#   backup.sh metrics         write the Prometheus textfile from the remote's last-success if it does not exist yet
#   backup.sh restore STAMP   restore the database from STAMP or `latest` (needs RESTORE_CONFIRM=yes)
#
# Remote layout:
#   postgres/<stamp>.dump      pg_dump --format=custom
#   pre-restore/<stamp>.dump   the database as it was just before a restore
#   last-success               stamp of the last fully successful run
#
# From the repository root on the VPS: make prod-backup-now | prod-backup-status | prod-backup-list | prod-restore
set -eu

REMOTE="${RCLONE_REMOTE:-}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
MAX_AGE_HOURS="${BACKUP_MAX_AGE_HOURS:-12}"
TMP_DIR="${BACKUP_TMP:-/tmp}"
# On a named volume: `docker compose run --rm backup once` is a new container, and a container-local lock would never
# see the long-running scheduler's cron runs.
LOCK="${BACKUP_LOCK:-/var/lock/backup/lock}"
METRICS_DIR="${BACKUP_METRICS_DIR:-/metrics}"
ENV_FILE="${TMP_DIR}/backup.env"
# Keeps rclone inside the container's 64 MB limit. Used unquoted on purpose: it is a word list.
RCLONE_FLAGS="--transfers 2 --checkers 4 --buffer-size 8M"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }
die() { log "ERROR: $*"; exit 1; }
stamp_now() { date -u +%Y%m%dT%H%M%SZ; }
is_stamp() {
	case "$1" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) return 0 ;; esac
	return 1
}
# 20260928T060000Z -> epoch seconds (busybox and GNU date both read "YYYY-MM-DD hh:mm:ss").
stamp_epoch() { date -u -d "$(echo "$1" | sed -E 's/^(....)(..)(..)T(..)(..)(..)Z$/\1-\2-\3 \4:\5:\6/')" +%s; }
# Connection flags before the caller's arguments: musl's getopt does not reorder options after a file operand.
pg() {
	cmd="$1"; shift
	PGPASSWORD="${POSTGRES_PASSWORD:-}" "${cmd}" --host="${POSTGRES_HOST:-db}" --username="${POSTGRES_USER:-app}" \
		--dbname="${POSTGRES_DB:-app}" "$@"
}
last_success() {
	[ -n "${REMOTE}" ] || return 1
	rclone cat "${REMOTE}/last-success" 2>/dev/null
}

preflight() {
	[ -n "${REMOTE}" ] || die "RCLONE_REMOTE is not set; backups are off-host only (docs/deployment.md §6)"
	case "${REMOTE}" in
		*:*) ;;
		*)
			[ "${BACKUP_ALLOW_LOCAL_REMOTE:-}" = "1" ] \
				|| die "RCLONE_REMOTE '${REMOTE}' has no 'name:' prefix: refusing to write backups onto this host's own disk"
			;;
	esac
	rclone mkdir "${REMOTE}" || die "cannot reach ${REMOTE}; check rclone.conf (RCLONE_CONFIG=${RCLONE_CONFIG:-default})"
	pg pg_isready >/dev/null || die "postgres is not ready"
}

# $1 = 1|0 for the run that just ended, $2 = epoch of the last successful run ("" when unknown).
write_metrics() {
	mkdir -p "${METRICS_DIR}"
	tmp="${METRICS_DIR}/.backup.prom.$$"
	{
		if [ -n "$2" ]; then
			echo "# HELP app_backup_last_success_timestamp_seconds Unix time of the last fully successful backup."
			echo "# TYPE app_backup_last_success_timestamp_seconds gauge"
			echo "app_backup_last_success_timestamp_seconds $2"
		fi
		echo "# HELP app_backup_last_run_success 1 if the most recent backup run succeeded, else 0."
		echo "# TYPE app_backup_last_run_success gauge"
		echo "app_backup_last_run_success $1"
	} > "${tmp}"
	# The scheduler runs under umask 077 (its env file holds secrets); Alloy reads this file as another user.
	chmod 644 "${tmp}"
	mv "${tmp}" "${METRICS_DIR}/backup.prom"
}

previous_success_epoch() {
	e="$(sed -n 's/^app_backup_last_success_timestamp_seconds //p' "${METRICS_DIR}/backup.prom" 2>/dev/null || true)"
	if [ -z "${e}" ]; then
		s="$(last_success || true)"
		if is_stamp "${s}"; then e="$(stamp_epoch "${s}")"; fi
	fi
	echo "${e}"
}

metrics() {
	[ -f "${METRICS_DIR}/backup.prom" ] && return 0
	s="$(last_success || true)"
	if is_stamp "${s}"; then write_metrics 1 "$(stamp_epoch "${s}")"; else write_metrics 1 ""; fi
}

# Delete "<stamp>.dump" entries of a remote directory whose stamp is older than the retention. By name, not mtime:
# rclone keeps the source mtime on upload, so mtime says nothing about when the backup was taken.
prune() {
	cutoff=$(( $(date -u +%s) - RETENTION_DAYS * 86400 ))
	rclone lsf "$1" 2>/dev/null | while IFS= read -r entry; do
		s="${entry%.dump}"
		is_stamp "${s}" || continue
		[ "${entry}" = "${s}.dump" ] || continue
		if [ "$(stamp_epoch "${s}")" -lt "${cutoff}" ]; then
			rclone deletefile "$1/${entry}" && log "pruned $1/${entry}"
		fi
	done
}

# Runs in a subshell (see once), where `set -e` does not apply: every step that matters ends in `|| die`.
run_once() {
	preflight
	stamp="$(stamp_now)"
	dump="${TMP_DIR}/${stamp}.dump"
	trap 'rm -f "${dump}"' EXIT
	log "backup ${stamp} starting"
	pg pg_dump --format=custom --file="${dump}" || die "pg_dump failed"
	# shellcheck disable=SC2086
	rclone copyto ${RCLONE_FLAGS} "${dump}" "${REMOTE}/postgres/${stamp}.dump" || die "dump upload failed"
	log "uploaded postgres/${stamp}.dump ($(du -h "${dump}" | cut -f1))"
	# Only a successful run prunes: a failing backup must never also delete the last good one.
	prune "${REMOTE}/postgres"
	prune "${REMOTE}/pre-restore"
	echo "${stamp}" | rclone rcat "${REMOTE}/last-success" || die "could not record last-success"
	write_metrics 1 "$(stamp_epoch "${stamp}")"
	log "backup ${stamp} complete"
}

once() {
	# Leftovers of a crashed run; the lock guarantees no other run is using them.
	rm -f "${TMP_DIR}"/*.dump
	if ( run_once ); then return 0; fi
	write_metrics 0 "$(previous_success_epoch)"
	return 1
}

locked() {
	mkdir -p "$(dirname "${LOCK}")"
	exec 9>"${LOCK}"
	flock -n 9 || die "another backup or restore is running"
	"$@"
}

schedule() {
	preflight
	metrics
	cron="${BACKUP_CRON:-0 */6 * * *}"
	# busybox crond does not pass the container environment to jobs. The file holds POSTGRES_PASSWORD: owner-only.
	umask 077
	export -p > "${ENV_FILE}"
	echo "${cron} . ${ENV_FILE}; /usr/local/bin/backup.sh once > /proc/1/fd/1 2>&1" > /etc/crontabs/root
	log "scheduled '${cron}' (TZ=${TZ:-UTC}) to ${REMOTE}"
	exec crond -f -l 8
}

cmd="${1:-schedule}"
[ $# -gt 0 ] && shift
case "${cmd}" in
	-h|--help) sed -n '2,18p' "$0" ;;
	schedule) schedule ;;
	once) locked once ;;
	metrics) metrics ;;
	*) die "unknown command: ${cmd} (schedule|once|status|list|metrics|restore)" ;;
esac
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash scripts/tests/backup.test.sh`
Expected: `backup: all passed`

- [ ] **Step 5: Commit**

```bash
git add deploy/backup/backup.sh scripts/tests/backup.test.sh
git commit -F - <<'EOF'
feat(backup): upload database dumps to an rclone remote

A dump on the VPS disk dies with that disk. The sidecar now uploads each
pg_dump to an off-host rclone remote, prunes by the stamp in the name only
after a fully successful run, and publishes its outcome as a Prometheus
textfile so a stalled backup can alert.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 2: backup.sh status, list, restore

**Files:**
- Modify: `deploy/backup/backup.sh` (add three functions before `schedule()`, three `case` entries)
- Modify: `scripts/tests/backup.test.sh` (append cases before the final `echo`)

**Interfaces:**
- Consumes (Task 1): `last_success`, `is_stamp`, `stamp_epoch`, `stamp_now`, `pg`, `preflight`, `locked`, `log`, `die`, `REMOTE`, `TMP_DIR`, `MAX_AGE_HOURS`, `RCLONE_FLAGS`; test helpers `reset`, `days_ago`, `store`, `CALL_LOG`, fakes.
- Produces (Tasks 4, 6):
  - `backup.sh status` → stdout `last successful backup: <stamp> (<N>h ago)`, plus `OLDER THAN <N>h` and exit 1 when `N >= BACKUP_MAX_AGE_HOURS`; `no successful backup yet` + exit 1 when none.
  - `backup.sh list` → one stamp per line, sorted; stamps newer than `last-success` get suffix `  (after the last successful backup)`.
  - `backup.sh restore <stamp|latest>` under the lock; `RESTORE_CONFIRM=yes` required.

- [ ] **Step 1: Write the failing tests** — insert before `echo "backup: all passed"` in `scripts/tests/backup.test.sh`:

```bash
# status: missing → non-zero; fresh → zero with the age; stale → non-zero; threshold configurable.
reset
if out="$(sh "$script" status 2>&1)"; then fail "status exited 0 with no backup"; fi
[[ "$out" == *"no successful backup"* ]] || fail "status without backup: $out"
sh "$script" once >/dev/null
out="$(sh "$script" status)" || fail "status failed right after a backup: $out"
[[ "$out" == *"(0h ago)"* ]] || fail "age missing: $out"
days_ago 1 > "$store/last-success"
if out="$(sh "$script" status)"; then fail "24h-old backup reported fresh"; fi
[[ "$out" == *"OLDER THAN 12h"* ]] || fail "stale status: $out"
BACKUP_MAX_AGE_HOURS=48 sh "$script" status >/dev/null || fail "BACKUP_MAX_AGE_HOURS ignored"

# list: sorted stamps only; a dump newer than last-success is marked.
reset
mkdir -p "$store/postgres"
for s in 20260103T000000Z 20260101T000000Z 20260102T000000Z; do echo x > "$store/postgres/$s.dump"; done
echo x > "$store/postgres/readme.txt"
echo 20260102T000000Z > "$store/last-success"
out="$(sh "$script" list)"
expected="20260101T000000Z
20260102T000000Z
20260103T000000Z  (after the last successful backup)"
[[ "$out" == "$expected" ]] || fail "list: $out"

# restore: refused without confirmation; `latest` = last-success even when a newer dump exists; safety dump of the
# current database uploaded before pg_restore; one transaction; temp files removed.
reset
sh "$script" once >/dev/null
good="$(cat "$store/last-success")"
echo "dump-of-half-run" > "$store/postgres/29990101T000000Z.dump"
: > "$CALL_LOG"
if sh "$script" restore latest >/dev/null 2>&1; then fail "restore ran without RESTORE_CONFIRM=yes"; fi
grep -q '^pg_' "$CALL_LOG" && fail "unconfirmed restore touched the database: $(cat "$CALL_LOG")"
: > "$CALL_LOG"
FAKE_DB_STATE=current RESTORE_CONFIRM=yes sh "$script" restore latest >/dev/null \
  || fail "restore latest failed: $(cat "$CALL_LOG")"
grep -q '^pg_restore .*<= dump-of-db$' "$CALL_LOG" || fail "latest did not restore the last successful dump: $(cat "$CALL_LOG")"
grep -q -- '--single-transaction' "$CALL_LOG" || fail "restore is not one transaction"
safety=("$store"/pre-restore/*.dump)
[[ -f "${safety[0]}" && "$(cat "${safety[0]}")" == dump-of-current ]] || fail "no safety dump of the current database"
upload_line="$(grep -n 'rclone copyto .*pre-restore/' "$CALL_LOG" | cut -d: -f1)"
restore_line="$(grep -n '^pg_restore' "$CALL_LOG" | cut -d: -f1)"
(( upload_line < restore_line )) || fail "safety dump uploaded after pg_restore"
compgen -G "$tmp/work/*.dump" >/dev/null && fail "restore left dumps in the temp dir"

# restore: unknown stamp, malformed stamp, failed safety dump → nothing restored.
: > "$CALL_LOG"
if RESTORE_CONFIRM=yes sh "$script" restore 20000101T000000Z >/dev/null 2>&1; then fail "missing stamp exited 0"; fi
if RESTORE_CONFIRM=yes sh "$script" restore ../etc >/dev/null 2>&1; then fail "malformed stamp exited 0"; fi
grep -q '^pg_' "$CALL_LOG" && fail "bad stamp still touched the database: $(cat "$CALL_LOG")"
if FAKE_PG_DUMP_FAIL=1 RESTORE_CONFIRM=yes sh "$script" restore "$good" >/dev/null 2>&1; then
  fail "restore exited 0 although the safety dump failed"
fi
grep -q '^pg_restore' "$CALL_LOG" && fail "restored although the safety dump failed"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash scripts/tests/backup.test.sh`
Expected: `FAIL: status without backup: … unknown command: status …` (or similar FAIL on the first status case).

- [ ] **Step 3: Implement** — in `deploy/backup/backup.sh`, add before `schedule() {`:

```sh
status() {
	[ -n "${REMOTE}" ] || die "RCLONE_REMOTE is not set"
	last="$(last_success || true)"
	is_stamp "${last}" || { echo "no successful backup yet"; exit 1; }
	age_h=$(( ($(date -u +%s) - $(stamp_epoch "${last}")) / 3600 ))
	echo "last successful backup: ${last} (${age_h}h ago)"
	[ "${age_h}" -lt "${MAX_AGE_HOURS}" ] || { echo "OLDER THAN ${MAX_AGE_HOURS}h"; exit 1; }
}

# A dump newer than last-success comes from a run that failed after uploading it: listed, but marked, because
# restoring it explicitly is allowed and `latest` never picks it.
list() {
	[ -n "${REMOTE}" ] || die "RCLONE_REMOTE is not set"
	last="$(last_success || true)"
	last_epoch=""
	if is_stamp "${last}"; then last_epoch="$(stamp_epoch "${last}")"; fi
	rclone lsf "${REMOTE}/postgres" 2>/dev/null | sort | while IFS= read -r entry; do
		s="${entry%.dump}"
		is_stamp "${s}" || continue
		[ "${entry}" = "${s}.dump" ] || continue
		if [ -n "${last_epoch}" ] && [ "$(stamp_epoch "${s}")" -gt "${last_epoch}" ]; then
			echo "${s}  (after the last successful backup)"
		else
			echo "${s}"
		fi
	done
}

restore() {
	[ "${RESTORE_CONFIRM:-}" = "yes" ] || die "restore overwrites the database; set RESTORE_CONFIRM=yes"
	want="${1:-}"
	[ -n "${want}" ] || die "usage: backup.sh restore <stamp|latest>"
	preflight
	if [ "${want}" = "latest" ]; then
		# Via last-success, not the newest file: a dump whose run then failed is not a backup to restore.
		want="$(last_success)" || die "no successful backup recorded at ${REMOTE}/last-success"
	fi
	is_stamp "${want}" || die "not a backup stamp: ${want}"
	rclone lsf "${REMOTE}/postgres/${want}.dump" 2>/dev/null | grep -q . || die "no dump postgres/${want}.dump on ${REMOTE}"

	safety="$(stamp_now)"
	safety_dump="${TMP_DIR}/pre-${safety}.dump"
	restore_dump="${TMP_DIR}/restore-${want}.dump"
	trap 'rm -f "${safety_dump}" "${restore_dump}"' EXIT
	pg pg_dump --format=custom --file="${safety_dump}" || die "safety dump failed; nothing changed"
	# shellcheck disable=SC2086
	rclone copyto ${RCLONE_FLAGS} "${safety_dump}" "${REMOTE}/pre-restore/${safety}.dump" \
		|| die "safety dump upload failed; nothing changed"
	log "current database saved to pre-restore/${safety}.dump"

	# shellcheck disable=SC2086
	rclone copyto ${RCLONE_FLAGS} "${REMOTE}/postgres/${want}.dump" "${restore_dump}" \
		|| die "download of postgres/${want}.dump failed; database unchanged"
	# One transaction: a failed restore leaves the database exactly as it was.
	pg pg_restore --clean --if-exists --no-owner --single-transaction "${restore_dump}" \
		|| die "pg_restore failed; database unchanged (transaction rolled back)"
	log "database restored from postgres/${want}.dump"
}
```

and extend the `case` (after `once)`):

```sh
	status) status ;;
	list) list ;;
	restore) locked restore "$@" ;;
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash scripts/tests/backup.test.sh`
Expected: `backup: all passed`

- [ ] **Step 5: Commit**

```bash
git add deploy/backup/backup.sh scripts/tests/backup.test.sh
git commit -F - <<'EOF'
feat(backup): add status, list and safe restore to the backup sidecar

Restoring must never make things worse: it now uploads a dump of the
current database first, restores in one transaction, and resolves
`latest` through last-success so a half-finished run is never picked.
status gives a single freshness check for make targets and vps.sh.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 3: Image, compose service, env example, gitignore

**Files:**
- Modify: `deploy/backup/Dockerfile`
- Modify: `deploy/compose.prod.yml` (`backup:` service at ~line 153, `volumes:` at the end)
- Modify: `deploy/.env.prod.example` (lines 24-27 observability comment; lines 56-59 backup block)
- Modify: `.gitignore` (Env / secrets block, line ~26)
- Test: `scripts/tests/deploy-config.test.sh`

**Interfaces:**
- Consumes (Tasks 1–2): the script's env names and default command `schedule`.
- Produces (Tasks 4, 5, 8): service `backup` in profile `backup`; named volumes `backup_lock`, `backup_metrics`; env `RCLONE_REMOTE`, `RCLONE_CONFIG_FILE`, `BACKUP_CRON`, `BACKUP_TZ`, `BACKUP_RETENTION_DAYS`, `BACKUP_MAX_AGE_HOURS`.

- [ ] **Step 1: Write the failing test** — in `scripts/tests/deploy-config.test.sh`, replace the line `bash -n "$root/deploy/backup/backup.sh" || fail "backup.sh has a syntax error"` with:

```bash
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash scripts/tests/deploy-config.test.sh`
Expected: `FAIL: backup service must only exist with the backup profile`

- [ ] **Step 3: Implement**

`deploy/backup/Dockerfile`:

```dockerfile
# Backup sidecar: pg_dump + rclone on a cron schedule. Built on the VPS by compose (pull_policy: build), never published.
FROM alpine:3.21

# The client must match the server's major version (17): an older pg_dump refuses a newer server.
RUN apk add --no-cache postgresql17-client rclone tzdata

COPY backup.sh /usr/local/bin/backup.sh
RUN chmod +x /usr/local/bin/backup.sh

ENTRYPOINT ["/usr/local/bin/backup.sh"]
CMD ["schedule"]
```

`deploy/compose.prod.yml` — replace the whole `backup:` service with:

```yaml
  backup:
    # Enabled by COMPOSE_PROFILES=backup in deploy/.env.prod; uploads pg_dump to an rclone remote (docs/deployment.md
    # §6). No :? guards on the backup variables: compose interpolates profiled services even when the profile is off.
    profiles: ["backup"]
    build: ./backup
    image: ${COMPOSE_PROJECT_NAME}-backup:local
    # Built on the host, never pulled: Watchtower must not look for it in a registry.
    pull_policy: build
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      POSTGRES_DB: ${POSTGRES_DB:-app}
      POSTGRES_USER: ${POSTGRES_USER:-app}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?run make prod-init (generates POSTGRES_PASSWORD)}
      RCLONE_REMOTE: ${RCLONE_REMOTE:-}
      RCLONE_CONFIG: /config/rclone.conf
      BACKUP_CRON: ${BACKUP_CRON:-0 */6 * * *}
      TZ: ${BACKUP_TZ:-UTC}
      BACKUP_RETENTION_DAYS: ${BACKUP_RETENTION_DAYS:-30}
      BACKUP_MAX_AGE_HOURS: ${BACKUP_MAX_AGE_HOURS:-12}
    volumes:
      # Read-write: rclone stores refreshed OAuth tokens (Google Drive) back into this file. Must exist on the host.
      - type: bind
        source: ${RCLONE_CONFIG_FILE:-./backup/rclone.conf}
        target: /config/rclone.conf
        bind:
          create_host_path: false
      # Shared by the scheduler and every `docker compose run --rm backup …`, so they cannot overlap.
      - backup_lock:/var/lock/backup
      # Read by Alloy (textfile collector) for the BackupStale alert.
      - backup_metrics:/metrics
    networks: [data]
    mem_limit: 64m
    logging: *default-logging
    labels:
      com.centurylinklabs.watchtower.enable: "false"
```

and in the top-level `volumes:` add:

```yaml
  backup_lock:
  backup_metrics:
```

`deploy/.env.prod.example` — change the observability comment line `# Uncomment to start Alloy, …` block so the profile line reads (keep the Grafana Cloud explanation):

```
# Profiles: `backup` (off-host database backups, see BACKUPS below) and `observability` (Alloy pushes metrics to
# Grafana Cloud). Comma-separated, e.g. COMPOSE_PROFILES=backup,observability.
#COMPOSE_PROFILES=backup,observability
```

Replace the three `BACKUP_*` lines and their comment (lines 56-59) with:

```
# ============================================================== BACKUPS (optional, strongly recommended)

# pg_dump every BACKUP_CRON, uploaded with rclone; nothing is kept on this disk. Needs `backup` in COMPOSE_PROFILES
# and deploy/backup/rclone.conf (docs/deployment.md §6). Without the profile there are NO backups.
# rclone remote and folder, e.g. gdrive:myservice or storagebox:backups/myservice.
RCLONE_REMOTE=
# rclone.conf on this host (gitignored), relative to deploy/. Read-write: rclone stores refreshed tokens in it.
RCLONE_CONFIG_FILE=./backup/rclone.conf
# busybox cron schedule and the time zone it is read in.
BACKUP_CRON="0 */6 * * *"
BACKUP_TZ=UTC
# Dumps and pre-restore safety dumps older than this many days are pruned after a successful run.
BACKUP_RETENTION_DAYS=30
# `make prod-backup-status` fails beyond this age. The BackupStale alert's 12 h threshold lives in
# deploy/grafana/alerting/rules.json: change both together.
BACKUP_MAX_AGE_HOURS=12
```

`.gitignore` — under `deploy/backups/` add:

```
deploy/backup/rclone.conf
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash scripts/tests/deploy-config.test.sh && bash scripts/tests/backup.test.sh`
Expected: `deploy-config: all passed` and `backup: all passed`

- [ ] **Step 5: Build the image once** (catches a wrong apk package name)

Run: `docker build -q -t backup-check deploy/backup && docker run --rm backup-check --help | head -3`
Expected: an image id, then the first header lines of `backup.sh`.

- [ ] **Step 6: Commit**

```bash
git add deploy/backup/Dockerfile deploy/compose.prod.yml deploy/.env.prod.example .gitignore scripts/tests/deploy-config.test.sh
git commit -F - <<'EOF'
feat(backup): run the backup sidecar only under the backup profile

Backups need an rclone remote the template cannot know, so the sidecar
becomes opt-in instead of silently writing dumps next to the database.
rclone.conf is mounted read-write for token refresh and must exist, so a
missing file fails loudly instead of turning into a directory.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 4: Makefile targets

**Files:**
- Modify: `Makefile` (`.PHONY` line 2-3; `prod-backup-now` and `prod-restore` at lines ~129-136; add `vps-backup-status` after `vps-status`)
- Create: `scripts/tests/make-backup.test.sh`

**Interfaces:**
- Consumes (Tasks 2–3): `backup.sh once|status|list|restore`, `RESTORE_CONFIRM`, profile `backup`.
- Produces (Tasks 6, 7): `make prod-backup-now|prod-backup-status|prod-backup-list|prod-restore STAMP=… [CONFIRM=yes]|vps-backup-status`. `vps-backup-status` calls `scripts/vps.sh backup-status` (implemented in Task 6).

- [ ] **Step 1: Write the failing test** — `scripts/tests/make-backup.test.sh`:

```bash
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
  "ps --status running --services") printf '%s\n' ${FAKE_RUNNING:-} ;;
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

# Backup verbs force the profile, so they work on a host whose .env.prod does not enable it.
for pair in now:once status:status list:list; do
  : > "$COMPOSE_LOG"
  "${mk[@]}" "prod-backup-${pair%%:*}" >/dev/null || fail "prod-backup-${pair%%:*} failed"
  [[ "$(cat "$COMPOSE_LOG")" == "--profile backup run --rm backup ${pair#*:}" ]] \
    || fail "prod-backup-${pair%%:*}: $(cat "$COMPOSE_LOG")"
done

echo "make-backup: all passed"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash scripts/tests/make-backup.test.sh`
Expected: FAIL (the current `prod-restore` requires `FILE=`; the confirmed-restore sequence does not match).

- [ ] **Step 3: Implement** — in `Makefile`, `.PHONY`: replace `prod-backup-now prod-restore` with `prod-backup-now prod-backup-status prod-backup-list prod-restore` and add `vps-backup-status` after `vps-status`. Replace the `prod-backup-now` and `prod-restore` targets with (recipe lines start with a TAB):

```make
prod-backup-now: ## Run one off-host backup now (needs rclone set up, docs/deployment.md §6)
	$(PROD) --profile backup run --rm backup once

prod-backup-status: ## Age of the last successful off-host backup; fails if older than BACKUP_MAX_AGE_HOURS
	$(PROD) --profile backup run --rm backup status

prod-backup-list: ## Database dumps on the backup remote, oldest first (stamps for prod-restore)
	$(PROD) --profile backup run --rm backup list

prod-restore: ## Restore the DB from the backup remote: make prod-restore STAMP=<stamp|latest>  (asks; CONFIRM=yes skips)
	@test -n "$(STAMP)" || { echo "usage: make prod-restore STAMP=<stamp|latest>   (stamps: make prod-backup-list)"; exit 1; }
	@if [ "$(CONFIRM)" != yes ]; then \
		printf 'Overwrite the production database with backup %s? A safety dump is uploaded first. Type yes: ' "$(STAMP)"; \
		read answer || true; \
		[ "$$answer" = yes ] || { echo "aborted"; exit 1; }; \
	fi
	@# Watchtower is stopped only if it was running (a prod-rollback pin keeps it stopped), so it cannot recreate a
	@# replica mid-restore. Both come back even when the restore fails; the target still fails then.
	@wt="$$($(PROD) ps --status running --services | grep -x watchtower || true)"; \
		$(PROD) stop app $$wt; \
		$(PROD) --profile backup run --rm -e RESTORE_CONFIRM=yes backup restore $(STAMP); rc=$$?; \
		$(PROD) start app $$wt; \
		exit $$rc
```

After the `vps-status` target add:

```make
vps-backup-status: ## Backup freshness on the VPS, checked from this machine
	scripts/vps.sh backup-status
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash scripts/tests/make-backup.test.sh && make help | grep -E 'prod-backup|prod-restore|vps-backup'`
Expected: `make-backup: all passed` and five help lines.

- [ ] **Step 5: Commit**

```bash
git add Makefile scripts/tests/make-backup.test.sh
git commit -F - <<'EOF'
feat(backup): add make targets to run, check, list and restore backups

prod-restore now restores from the off-host remote by stamp and asks
first. It stops Watchtower only if it was running, so restoring after a
prod-rollback does not silently resume following latest.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 5: Metric pipeline, BackupStale alert, dashboard panel

**Files:**
- Modify: `src/test/java/com/example/company/unit/DashboardJsonTest.java`
- Modify: `deploy/grafana/alerting/rules.json` (append one rule)
- Modify: `deploy/grafana/dashboards/app-overview.json` (append a row + stat panel)
- Modify: `deploy/alloy/config.alloy` (append the backup pipeline; update header line 1)
- Modify: `deploy/compose.prod.yml` (`alloy` volumes)
- Modify: `docs/observability.md` (alert table, line ~53)
- Test: `scripts/tests/deploy-config.test.sh`

**Interfaces:**
- Consumes (Tasks 1, 3): `backup.prom` in volume `backup_metrics`; metric names from Global Constraints.
- Produces: alert uid `app-backup-stale`, title `BackupStale`; dashboard panel titled `Last successful backup`.

- [ ] **Step 1: Write the failing Java tests** — in `DashboardJsonTest` add these two tests and the helper. Do not touch `KNOWN_METRICS` yet (Step 5).

```java
    @Test
    void backupStaleAlertFiresAfterTwelveHoursAndStaysQuietWhenBackupsAreOff() throws IOException {
        var rules = mapper.readTree(GRAFANA_DIR.resolve("alerting/rules.json").toFile());
        var stale = element(rules, "title", "BackupStale");

        // No data means the backup profile is off, which is a valid configuration, not an incident.
        assertThat(stale.path("noDataState").asText()).isEqualTo("OK");
        assertThat(stale.toString()).contains("app_backup_last_success_timestamp_seconds");
        var threshold = element(stale.path("data"), "refId", "C")
                .path("model").path("conditions").get(0).path("evaluator").path("params").get(0);
        assertThat(threshold.asInt()).isEqualTo(43200);
    }

    @Test
    void dashboardShowsTheAgeOfTheLastBackup() throws IOException {
        var dashboard = mapper.readTree(
                GRAFANA_DIR.resolve("dashboards/app-overview.json").toFile());

        var panel = element(dashboard.path("panels"), "title", "Last successful backup");
        assertThat(panel.toString()).contains("app_backup_last_success_timestamp_seconds");
    }

    private static JsonNode element(JsonNode array, String field, String value) {
        for (var node : array) {
            if (node.path(field).asText().equals(value)) {
                return node;
            }
        }
        throw new AssertionError("no element with " + field + "=" + value);
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `./gradlew test --tests '*DashboardJsonTest'`
Expected: 2 failures, `AssertionError: no element with title=BackupStale` and `…title=Last successful backup`.

- [ ] **Step 3: Add the rule and the panel** (jq keeps the 2-space layout; check `git diff` shows only additions):

```bash
t="$(mktemp)"
jq '. + [{
  "uid": "app-backup-stale", "title": "BackupStale", "ruleGroup": "app-baseline", "folderUID": "app", "orgID": 1,
  "condition": "C", "for": "15m", "noDataState": "OK", "execErrState": "Error",
  "labels": {"severity": "critical"},
  "annotations": {"summary": "No successful off-host backup for over 12 h. On the VPS: `make prod-backup-status`, `make prod-logs SERVICE=backup`."},
  "data": [
    {"refId": "A", "relativeTimeRange": {"from": 600, "to": 0}, "datasourceUid": "grafanacloud-prom",
     "model": {"refId": "A", "expr": "time() - max(app_backup_last_success_timestamp_seconds{env=\"prod\"})",
               "instant": true, "range": false, "intervalMs": 1000, "maxDataPoints": 43200}},
    {"refId": "B", "datasourceUid": "__expr__",
     "model": {"refId": "B", "type": "reduce", "expression": "A", "reducer": "last", "settings": {"mode": "dropNN"}}},
    {"refId": "C", "datasourceUid": "__expr__",
     "model": {"refId": "C", "type": "threshold", "expression": "B",
               "conditions": [{"evaluator": {"type": "gt", "params": [43200]}}]}}
  ]
}]' deploy/grafana/alerting/rules.json > "$t" && mv "$t" deploy/grafana/alerting/rules.json

jq '.panels += [
  {"collapsed": false, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 55}, "id": 24, "panels": [], "title": "Backups", "type": "row"},
  {"datasource": {"type": "prometheus", "uid": "grafanacloud-prom"},
   "description": "Age of the newest dump that reached the off-host remote. No data: the backup profile is off.",
   "fieldConfig": {"defaults": {"unit": "s", "noValue": "backups disabled", "color": {"mode": "thresholds"},
     "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "red", "value": 43200}]}},
     "overrides": []},
   "gridPos": {"h": 4, "w": 6, "x": 0, "y": 56}, "id": 25,
   "options": {"colorMode": "background", "graphMode": "none", "justifyMode": "center",
     "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "value"},
   "targets": [{"datasource": {"type": "prometheus", "uid": "grafanacloud-prom"},
     "expr": "time() - max(app_backup_last_success_timestamp_seconds{env=\"$env\"})",
     "instant": true, "range": false, "refId": "A"}],
   "title": "Last successful backup", "type": "stat"}
]' deploy/grafana/dashboards/app-overview.json > "$t" && mv "$t" deploy/grafana/dashboards/app-overview.json
git diff --stat deploy/grafana
```

If `git diff` shows reformatting of untouched lines, revert and insert the same objects by hand before the closing `]`.

- [ ] **Step 4: Run — expect the metric-name guard to fail now**

Run: `./gradlew test --tests '*DashboardJsonTest'`
Expected: 1 failure in `everyQueryReferencesAMetricTheAppExports` listing the two `app_backup_…` expressions.

- [ ] **Step 5: Teach the guard the new metric** — in `KNOWN_METRICS`, change `"app_build_info|http_server_requests_seconds|…"` to start with `"app_build_info|app_backup_|http_server_requests_seconds|…"`, and extend the class Javadoc's second sentence to: "Every query must reference a metric this application (or its backup sidecar) exports, …".

- [ ] **Step 6: Run to verify it passes**

Run: `make format && ./gradlew test --tests '*DashboardJsonTest'`
Expected: BUILD SUCCESSFUL, 5 tests passed.

- [ ] **Step 7: Alloy pipeline — write the failing config check** — in `scripts/tests/deploy-config.test.sh`, before the Caddy `docker run` line, add:

```bash
# Alloy reads the backup sidecar's textfile from the shared volume.
grep -q 'target: /metrics/backup' <<<"$(docker compose -f "$root/deploy/compose.prod.yml" --env-file "$here/fixtures/env.prod.test" --profile observability config)" \
  || fail "alloy does not mount the backup metrics volume"
grep -q 'prometheus.exporter.unix "backup"' "$root/deploy/alloy/config.alloy" || fail "alloy has no backup textfile pipeline"
docker run --rm -v "$root/deploy/alloy/config.alloy:/c.alloy:ro" grafana/alloy:v1.10.0 fmt /c.alloy >/dev/null \
  || fail "config.alloy does not parse"
```

Run: `bash scripts/tests/deploy-config.test.sh`
Expected: `FAIL: alloy does not mount the backup metrics volume`

- [ ] **Step 8: Implement the Alloy side** — `deploy/alloy/config.alloy`: change line 1 to
`// Metrics pipeline: scrape the app's /actuator/prometheus and the backup sidecar's textfile, and remote-write both out.`
and append at the end of the file:

```alloy

// Backup freshness. The backup sidecar (deploy/backup, profile `backup`) writes backup.prom into a volume mounted here
// read-only. Without the sidecar the directory is empty or missing and nothing is exported, which is what the
// BackupStale alert's noDataState=OK expects.
prometheus.exporter.unix "backup" {
	set_collectors = ["textfile"]

	textfile {
		directory = "/metrics/backup"
	}
}

prometheus.scrape "backup" {
	targets         = prometheus.exporter.unix.backup.targets
	job_name        = "backup"
	scrape_interval = "60s"
	forward_to      = [prometheus.remote_write.out.receiver]
}
```

`deploy/compose.prod.yml` — in the `alloy` service `volumes:` add after `alloy_data:/var/lib/alloy/data`:

```yaml
      # The backup sidecar's backup.prom (empty when the backup profile is off).
      - backup_metrics:/metrics/backup:ro
```

`docs/observability.md` — add to the rule table after `HeapHigh`:

```
| BackupStale | no successful off-host backup for 12 h; no data (backups off) stays quiet | 15 m |
```

and below the table:

```
BackupStale reads `app_backup_last_success_timestamp_seconds`, which the backup sidecar writes as a textfile that
Alloy picks up (`deploy/alloy/config.alloy`). Its 12 h threshold must stay ≥ `BACKUP_MAX_AGE_HOURS` and ≥ 2 × the
`BACKUP_CRON` interval. Runbook: `make prod-backup-status`, then `make prod-logs SERVICE=backup` on the VPS
(`docs/deployment.md` §6).
```

- [ ] **Step 9: Run to verify it passes**

Run: `bash scripts/tests/deploy-config.test.sh`
Expected: `deploy-config: all passed`

- [ ] **Step 10: Commit**

```bash
git add src/test/java/com/example/company/unit/DashboardJsonTest.java deploy/grafana deploy/alloy/config.alloy deploy/compose.prod.yml docs/observability.md scripts/tests/deploy-config.test.sh
git commit -F - <<'EOF'
feat(backup): alert when no off-host backup succeeded for 12 hours

Opt-in backups are easy to forget and a broken token fails silently.
Alloy now reads the sidecar's textfile and BackupStale pages after two
missed runs; no data stays quiet because backups may legitimately be off.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 6: vps.sh backup status and skill

**Files:**
- Modify: `scripts/vps.sh` (header lines 10-18, `usage()` line 33, `deploy-status)` case ~line 72, new case)
- Modify: `scripts/tests/vps.test.sh` (fake ssh, fake curl, new cases)
- Modify: `.claude/skills/vps-db/SKILL.md`

**Interfaces:**
- Consumes (Task 2): `backup.sh status` output and exit code; (Task 4) `make vps-backup-status` calls `scripts/vps.sh backup-status`.
- Produces: `scripts/vps.sh backup-status` (exit code = remote status); `deploy-status` last line `backups: DISABLED …` | `backups: ok — …` | `backups: STALE — …`.

- [ ] **Step 1: Write the failing test** — in `scripts/tests/vps.test.sh`, change the fake ssh `case` to:

```bash
case "$*" in
  *"cat "*".env.prod"*) printf 'POSTGRES_DB=app\nPOSTGRES_USER=app\nPOSTGRES_PASSWORD=s3cret\nPOSTGRES_HOST_PORT=5433\nDOMAIN=example.com\nGRAFANA_CLOUD_PROM_TOKEN=tok\nCOMPOSE_PROFILES=%s\n' "${FAKE_PROFILES:-}" ;;
  *"backup status"*) [[ -n "${FAKE_BACKUP_STATUS:-}" ]] && printf '%s\n' "$FAKE_BACKUP_STATUS"; exit "${FAKE_BACKUP_RC:-0}" ;;
  *) echo "fake-ssh: $*" ;;
esac
```

After the `chmod +x "$tmp/bin/ssh"` line add a fake curl so `deploy-status` never reaches the network:

```bash
printf '#!/usr/bin/env bash\necho %s\n' "'{\"version\":\"1.0.0\"}'" > "$tmp/bin/curl"; chmod +x "$tmp/bin/curl"
```

Before `echo "vps: all passed"` add:

```bash
# deploy-status: one backup line, three states.
out="$(FAKE_PROFILES=observability "$script" deploy-status)"
[[ "$out" == *"backups: DISABLED"* ]] || fail "disabled backups not reported: $out"
out="$(FAKE_PROFILES=backup,observability FAKE_BACKUP_STATUS="last successful backup: 20260928T060000Z (3h ago)" "$script" deploy-status)"
[[ "$out" == *"backups: ok — last successful backup: 20260928T060000Z (3h ago)"* ]] || fail "fresh backup line: $out"
out="$(FAKE_PROFILES="observability,backup" FAKE_BACKUP_RC=1 FAKE_BACKUP_STATUS="no successful backup yet" "$script" deploy-status)" \
  || fail "deploy-status must not fail because backups are stale"
[[ "$out" == *"backups: STALE — no successful backup yet"* ]] || fail "stale backup line: $out"

# backup-status: runs status with the profile forced and passes its exit code through.
: > "$SSH_LOG"
if FAKE_BACKUP_RC=1 "$script" backup-status >/dev/null; then fail "backup-status hid a stale backup"; fi
grep -q -- "--profile backup run --rm -T backup status" "$SSH_LOG" || fail "backup-status command: $(cat "$SSH_LOG")"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash scripts/tests/vps.test.sh`
Expected: `FAIL: disabled backups not reported: …`

- [ ] **Step 3: Implement** — in `scripts/vps.sh`:

Header, after the `deploy-status` line:

```bash
#   deploy-status        image tag per replica, what /version answers, and whether backups are fresh
#   backup-status        age of the last successful off-host backup; non-zero when stale or missing
```

(replace the existing `deploy-status` header line with the first of these). Change `usage()` to print one more line: `sed -n '2,21p' "$0"`. Verify with `scripts/vps.sh 2>&1 | tail -3` that the `datagrip` continuation line is still printed.

At the end of the `deploy-status)` branch, before its `;;`, append (the branch already ran `load_remote_env`):

```bash
    profiles="$(env_value COMPOSE_PROFILES "")"
    if [[ ",${profiles// /}," != *",backup,"* ]]; then
      echo "backups: DISABLED (COMPOSE_PROFILES lacks backup; docs/deployment.md §6)"
    elif status_out="$(prod "--profile backup run --rm -T backup status" 2>/dev/null)"; then
      echo "backups: ok — ${status_out//$'\n'/; }"
    else
      status_out="${status_out//$'\n'/; }"
      echo "backups: STALE — ${status_out:-no answer; run make vps-backup-status}"
    fi
```

Make sure the line before it ends with a newline, not `;;` — i.e. move the existing `;;` of `deploy-status` to after this block. Add a new case after `deploy-status`:

```bash
  backup-status)
    prod "--profile backup run --rm -T backup status" ;;
```

`.claude/skills/vps-db/SKILL.md` — add a table row after "What is deployed right now":

```
| Are backups working | `scripts/vps.sh backup-status` (non-zero when stale/missing); `deploy-status` shows a one-line summary |
```

and replace the rule "Before a restore or rollback, read `docs/deployment.md` …" with:

```
- Before a restore or rollback, read `docs/deployment.md` (§6 backups/restore, rollback, expand/contract rules).
- **Never run a restore.** `make prod-restore` overwrites the production database; hand the user the command
  (`scripts/vps.sh ssh`, then `make prod-backup-list` and `make prod-restore STAMP=<stamp|latest>`) and let them run it.
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash scripts/tests/vps.test.sh && make test-scripts`
Expected: `vps: all passed`, and `run.sh` exits 0 with every `*: all passed` line.

- [ ] **Step 5: Commit**

```bash
git add scripts/vps.sh scripts/tests/vps.test.sh .claude/skills/vps-db/SKILL.md
git commit -F - <<'EOF'
feat(backup): show backup freshness in vps-status and vps-backup-status

The first place anyone looks is make vps-status; a disabled or stale
backup now shows up there instead of only in Grafana, which may be off.
The skill forbids Claude from running a restore itself.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 7: Deployment docs, README, CLAUDE.md, spec deviations

**Files:**
- Modify: `docs/deployment.md` (§6 lines ~84-94; §7 backup row; any `prod-restore FILE=` elsewhere)
- Modify: `README.md` (checklist table ~line 40; `make prod-up` comment line 56)
- Modify: `CLAUDE.md` (hosting bullet line 24-25; "Invariants" section)
- Modify: `docs/superpowers/specs/2026-09-28-offhost-backups-design.md` (record two deviations)

**Interfaces:**
- Consumes: every name produced by Tasks 1–6. No code.

- [ ] **Step 1: Find every stale reference**

Run: `grep -rn 'BACKUP_DIR\|BACKUP_INTERVAL\|prod-restore FILE\|deploy/backups\|pg_dump sidecar' --exclude-dir=build --exclude-dir=.git . | grep -v docs/superpowers`
Expected: hits in `docs/deployment.md`, `CLAUDE.md`, possibly `README.md`. Each is fixed below; re-run at the end and expect only the `.gitignore` `deploy/backups/` line and the deliberate "delete `deploy/backups/`" upgrade note.

- [ ] **Step 2: Rewrite `docs/deployment.md` §6** to exactly:

````markdown
## 6. Backups and restore

Backups are **off until you configure them** and never stay on the VPS. The `backup` service (compose profile
`backup`) runs `pg_dump -Fc` on `BACKUP_CRON` (every 6 h) and uploads it with [rclone](https://rclone.org) to a remote
you choose. A dump on the same disk as the database does not survive losing that disk, so there is no local mode.

### Enable

1. Pick a remote; anything rclone supports works. Two cheap ones:
   - **Google Drive** (15 GB free): on your **laptop** (it opens a browser) run `rclone config` → `n` → name `gdrive`
     → storage `drive` → scope `drive.file` → finish the browser login.
   - **Hetzner Storage Box** (≈ €4/month, same data centre, no browser): storage `sftp`, host
     `uXXXXX.your-storagebox.de`, port `23`, user `uXXXXX`, an SSH key or password.
2. Copy the config to the VPS and lock it down (it holds the remote's credentials):
   `scp ~/.config/rclone/rclone.conf <vps>:<repo>/deploy/backup/rclone.conf && ssh <vps> chmod 600 <repo>/deploy/backup/rclone.conf`
3. In `deploy/.env.prod`: add `backup` to `COMPOSE_PROFILES` (e.g. `COMPOSE_PROFILES=backup,observability`) and set
   `RCLONE_REMOTE=gdrive:<service-name>`. Optional: `BACKUP_CRON`, `BACKUP_TZ`, `BACKUP_RETENTION_DAYS` (30),
   `BACKUP_MAX_AGE_HOURS` (12).
4. `make prod-up`. If the remote or Postgres is unreachable the container exits with the reason:
   `make prod-logs SERVICE=backup`.
5. `make prod-backup-now`, then `make prod-backup-list`: the new stamp must be listed. Look at the remote once too.

Upgrading from the old local backups: once step 5 works, delete `deploy/backups/` by hand.

### What is on the remote

```
postgres/<stamp>.dump       pg_dump --format=custom, one per successful run
pre-restore/<stamp>.dump    the database as it was just before a restore
last-success                stamp of the last fully successful run
```

Stamps are UTC (`20260928T060000Z`). After a successful run, dumps older than `BACKUP_RETENTION_DAYS` are pruned
from `postgres/` and `pre-restore/`; a failed run prunes nothing.

### Is it working?

```bash
make prod-backup-status     # on the VPS: last success and its age, non-zero beyond BACKUP_MAX_AGE_HOURS
make vps-backup-status      # the same from your laptop; `make vps-status` prints a one-line summary
```

With the observability profile on, the `BackupStale` alert fires after 12 h without a successful backup
([observability.md](observability.md)). Its threshold is in `deploy/grafana/alerting/rules.json`; change it together
with `BACKUP_MAX_AGE_HOURS`.

### Restore

```bash
make prod-backup-list                  # stamps, oldest first
make prod-restore STAMP=latest         # or a stamp from the list; asks you to type yes
```

In order: stops the app replicas (and Watchtower, only if it is running), uploads a dump of the **current** database
to `pre-restore/`, restores the chosen dump in one transaction (a failure leaves the database unchanged), starts
everything again. `latest` means the last *successful* run, never merely the newest file. The app migrates the schema
forward at start (Liquibase); expand/contract (§5) keeps older dumps compatible.

To undo a restore, copy the safety dump back into `postgres/` and restore it:
`docker compose -f deploy/compose.prod.yml --env-file deploy/.env.prod --profile backup run --rm --entrypoint rclone backup copyto "$RCLONE_REMOTE/pre-restore/<stamp>.dump" "$RCLONE_REMOTE/postgres/<stamp>.dump"`
(with `RCLONE_REMOTE` exported in your shell), then `make prod-restore STAMP=<stamp>`.

On a **new host**: `make prod-init`, copy `rclone.conf` and fill `.env.prod` as above, `make prod-up`, then
`make prod-restore STAMP=latest`.
````

In §7 change the backup row note to `only with COMPOSE_PROFILES=backup`. Fix any other hit from Step 1 in this file (cheat sheet §8) to use `prod-backup-now`, `prod-backup-status`, `prod-restore STAMP=`.

- [ ] **Step 3: README** — add a checklist row after the optional observability row:

```
| VPS `deploy/.env.prod` (recommended) | `COMPOSE_PROFILES=backup`, `RCLONE_REMOTE`; `deploy/backup/rclone.conf` | Off-host database backups ([§6](docs/deployment.md)); without it there are none |
```

and change the `make prod-up` comment to `# validates the env, starts Caddy + 2 app replicas + Postgres + Watchtower (+ backup, alloy by profile)`.

- [ ] **Step 4: CLAUDE.md** — in "How this is hosted", replace `plus Watchtower, a pg_dump sidecar and optionally Alloy.` with
`plus Watchtower and, by compose profile, an off-host backup sidecar (\`backup\`: pg_dump → rclone, \`BackupStale\` alert; \`docs/deployment.md\` §6) and Alloy.`
In "Invariants that break production silently" add:

```
- `BackupStale` threshold (43200 s in `rules.json`) ≥ `BACKUP_MAX_AGE_HOURS` and ≥ 2 × the `BACKUP_CRON` interval,
  or every late run pages. The `rclone.conf` mount stays read-write: Drive tokens refresh into it, and a read-only
  mount works for an hour, then every backup fails.
```

- [ ] **Step 5: Spec deviations** — in the spec's §1 compose environment list, change `` `TZ` (`UTC`) `` to `` `BACKUP_TZ` (`UTC`, passed to the container as `TZ`; a bare `TZ` would be picked up from the operator's shell by compose interpolation) ``; in §2 `prod-restore` row change `stop app watchtower` / `start app watchtower` to "stop app (and Watchtower only if running) … start the same set", adding: "A Watchtower stopped by `prod-rollback` stays stopped."

- [ ] **Step 6: Verify**

Run the Step 1 grep again; expected hits only as described there. Then `make test-scripts`.
Expected: all `*: all passed`.

- [ ] **Step 7: Commit**

```bash
git add docs/deployment.md README.md CLAUDE.md docs/superpowers/specs/2026-09-28-offhost-backups-design.md
git commit -F - <<'EOF'
docs(backup): document enabling, checking and restoring off-host backups

The old §6 told operators to copy dumps off the host themselves. It now
walks through choosing a remote, verifying the first backup, restoring
and undoing a restore, and records the new silent-failure invariants.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 8: End-to-end check against real containers, full build

**Files:** none (verification only; everything lives in the scratchpad `$S`).

**Interfaces:**
- Consumes: the image from Task 3, the Alloy config from Task 5, the local `compose.yml` stack.

- [ ] **Step 1: Start local Postgres and build the image**

```bash
S="$(mktemp -d)"   # or the session scratchpad
make db-up
docker build -q -t backup-check deploy/backup
net="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$(docker compose ps -q db)")"
mkdir -p "$S/remote" "$S/metrics" "$S/lock"
```

`bk` runs one sidecar command against the local database with a local-path remote:

```bash
bk() { docker run --rm --network "$net" -e POSTGRES_USER=app -e POSTGRES_PASSWORD=app -e POSTGRES_DB=app \
  -e RCLONE_REMOTE=/remote -e BACKUP_ALLOW_LOCAL_REMOTE=1 -e RCLONE_CONFIG=/dev/null -e RESTORE_CONFIRM="${RC:-}" \
  -v "$S/remote:/remote" -v "$S/metrics:/metrics" -v "$S/lock:/var/lock/backup" backup-check "$@"; }
```

- [ ] **Step 2: Backup, list, status against real pg_dump 17 and real rclone**

```bash
docker compose exec -T db psql -U app -d app -c "create table backup_check(x int); insert into backup_check values (42);"
bk once && bk list && bk status && cat "$S/metrics/backup.prom" && ls -l "$S/metrics/backup.prom"
```

Expected: `backup … complete`; one stamp listed; `last successful backup: <stamp> (0h ago)`; metric file with `app_backup_last_run_success 1`, mode `-rw-r--r--`.

- [ ] **Step 3: Restore round-trip**

```bash
docker compose exec -T db psql -U app -d app -c "drop table backup_check;"
RC=yes bk restore latest
docker compose exec -T db psql -U app -d app -tAc "select x from backup_check;"
ls "$S/remote/pre-restore"
```

Expected: `42`; one `pre-restore/<stamp>.dump`. Also `bk restore latest` without `RC=yes` exits non-zero with `set RESTORE_CONFIRM=yes`.

- [ ] **Step 4: Scheduler actually fires with the environment** (catches busybox crond env/stdout wiring)

```bash
docker run -d --name backup-sched --network "$net" -e POSTGRES_USER=app -e POSTGRES_PASSWORD=app -e POSTGRES_DB=app \
  -e RCLONE_REMOTE=/remote -e BACKUP_ALLOW_LOCAL_REMOTE=1 -e RCLONE_CONFIG=/dev/null -e BACKUP_CRON='* * * * *' \
  -v "$S/remote:/remote" -v "$S/metrics:/metrics" -v "$S/lock:/var/lock/backup" backup-check
```

Wait ~75 s (Monitor/until-loop on `docker logs backup-sched 2>&1 | grep -q 'complete'`), then `docker logs backup-sched; docker rm -f backup-sched`.
Expected: `scheduled '* * * * *'`, then a `backup … complete` line from the cron job.

- [ ] **Step 5: Alloy picks up the textfile** (same config file as prod)

```bash
make observability-up
docker run -d --name alloy-backup-check --network "$net" \
  -v "$PWD/deploy/alloy/config.alloy:/etc/alloy/config.alloy:ro" -v "$S/metrics:/metrics/backup:ro" \
  -e GRAFANA_CLOUD_PROM_URL=http://prometheus:9090/api/v1/write -e GRAFANA_CLOUD_PROM_USER=local \
  -e GRAFANA_CLOUD_PROM_TOKEN=local -e APP_ENV=backupcheck grafana/alloy:v1.10.0 run /etc/alloy/config.alloy
```

Wait ~90 s, then `curl -s 'http://127.0.0.1:9090/api/v1/query?query=app_backup_last_run_success{env="backupcheck"}'`.
Expected: one result with value `"1"`. Also `docker compose logs alloy | grep -i textfile` shows no crash of the local Alloy (whose directory is absent). Then `docker rm -f alloy-backup-check && make observability-down`.

- [ ] **Step 6: Full verification**

Run: `make test-scripts && make build`
Expected: every `*: all passed`; `BUILD SUCCESSFUL` (Spotless, unit, integration, JaCoCo gate).

- [ ] **Step 7: Clean up**

`docker compose exec -T db psql -U app -d app -c "drop table if exists backup_check;"`; `docker rmi backup-check`; `rm -rf "$S"`. Nothing to commit; report the observed outputs of Steps 2–6.
