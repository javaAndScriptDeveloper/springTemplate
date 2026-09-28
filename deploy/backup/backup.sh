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
	write_metrics 1 "$(stamp_epoch "${stamp}")" || die "could not write metrics"
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
	-h|--help) sed -n '2,17p' "$0" ;;
	schedule) schedule ;;
	once) locked once ;;
	metrics) metrics ;;
	*) die "unknown command: ${cmd} (schedule|once|status|list|metrics|restore)" ;;
esac
