# --- brick: backup

prod-backup-now: ## Run one off-host backup now (needs rclone set up, bricks/backup/README.md)
	$(PROD) run --rm backup once

prod-backup-status: ## Age of the last successful off-host backup; fails if older than BACKUP_MAX_AGE_HOURS
	$(PROD) run --rm backup status

prod-backup-list: ## Database dumps on the backup remote, oldest first (stamps for prod-restore)
	$(PROD) run --rm backup list

prod-restore: ## Restore the DB from the backup remote: make prod-restore STAMP=<stamp|latest>  (asks; CONFIRM=yes skips)
	@case "$$STAMP" in \
		latest|[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;; \
		*) echo "usage: make prod-restore STAMP=<stamp|latest>   (stamps: make prod-backup-list)"; exit 1 ;; \
	esac
	@if [ "$(CONFIRM)" != yes ]; then \
		printf 'Overwrite the production database with backup %s? A safety dump is uploaded first. Type yes: ' "$$STAMP"; \
		read answer || true; \
		[ "$$answer" = yes ] || { echo "aborted"; exit 1; }; \
	fi
	@# Watchtower is stopped only if it was running (a prod-rollback pin keeps it stopped), so it cannot recreate a
	@# replica mid-restore. A failed `ps` or `stop` leaves the stack untouched (ps: nothing to restart; stop: whatever
	@# it tried to stop is started again) and aborts before the restore ever runs. A failed restore still restarts
	@# app (+ watchtower) and the target still fails then.
	@running="$$($(PROD) ps --status running --services)" || { echo "cannot read container state; nothing changed"; exit 1; }; \
		wt="$$(echo "$$running" | grep -x watchtower || true)"; \
		$(PROD) stop app $$wt || { echo "stop failed; nothing was restored"; $(PROD) start app $$wt; exit 1; }; \
		$(PROD) run --rm -e RESTORE_CONFIRM=yes backup restore "$$STAMP"; rc=$$?; \
		$(PROD) start app $$wt; \
		exit $$rc

vps-backup-status: ## Backup freshness on the VPS, checked from this machine
	scripts/vps.sh backup-status
