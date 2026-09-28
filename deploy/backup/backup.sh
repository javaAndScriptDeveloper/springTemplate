#!/bin/sh
# Scheduled pg_dump of the production database.
#
#   backup.sh          loop forever: dump every BACKUP_INTERVAL_SECONDS, prune dumps older than BACKUP_RETENTION_DAYS
#   backup.sh once     one dump, then exit (make prod-backup-now)
#
# Restore (from the repository root on the VPS):
#   make prod-restore FILE=backups/20260928T020000Z.dump
set -eu

BACKUP_ROOT=/backups
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
INTERVAL="${BACKUP_INTERVAL_SECONDS:-86400}"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

run_once() {
	stamp="$(date -u +%Y%m%dT%H%M%SZ)"
	target="${BACKUP_ROOT}/${stamp}.dump"
	mkdir -p "${BACKUP_ROOT}"
	log "backup ${stamp} starting"

	# Custom format: compressed, and restorable selectively with pg_restore.
	if PGPASSWORD="${POSTGRES_PASSWORD}" pg_dump \
		--host=db \
		--username="${POSTGRES_USER}" \
		--dbname="${POSTGRES_DB}" \
		--format=custom \
		--file="${target}"; then
		log "written ${target} ($(du -h "${target}" | cut -f1))"
	else
		log "ERROR: pg_dump failed; keeping every existing dump"
		rm -f "${target}"
		return 1
	fi

	# Prune only after a successful dump: a failing backup must never also delete the last good one.
	find "${BACKUP_ROOT}" -name '*.dump' -mtime "+${RETENTION_DAYS}" -print -delete | sed 's/^/pruned /'
	log "backup ${stamp} complete"
}

if [ "${1:-loop}" = "once" ]; then
	run_once
	exit $?
fi

while true; do
	run_once || log "continuing despite failure; next attempt in ${INTERVAL}s"
	sleep "${INTERVAL}"
done
