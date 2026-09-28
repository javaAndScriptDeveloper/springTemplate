# Off-host database backups via rclone — design

Date: 2026-09-28 · Source: ported from `submissions-checker` (`docker/backup/backup.sh`, merge `8c7a2a4`),
database part only.

## Goal

Production database backups leave the VPS. Today `deploy/backup` writes `pg_dump` files to `deploy/backups/` on the
same disk as Postgres, which `docs/deployment.md` §6 already calls "a convenience, not a backup". After this change the
backup sidecar uploads dumps to any rclone remote (Google Drive, Hetzner Storage Box, B2, S3, …), restores from it with
safeguards, and reports freshness to Grafana so a stopped or failing backup pages someone.

## Decisions (made with the owner)

| # | Decision |
|---|---|
| D1 | Scope is PostgreSQL only. MinIO/object storage is not part of the template; if added later it gets its own spec. |
| D2 | Backups are **opt-in** through compose profile `backup`. With no remote there are no backups; the local-disk mode is removed, not kept as a fallback. |
| D3 | Freshness is visible on the CLI (`prod-backup-status`, `vps-status`) **and** as a Grafana alert (`BackupStale`) when the observability profile is on. |
| D4 | The metric reaches Alloy as a Prometheus textfile on a shared named volume. Networks `edge` and `data` stay separate. |
| D5 | Defaults: cron `0 */6 * * *`, `TZ=UTC`, retention 30 days, max age 12 h. No encryption; an rclone `crypt` remote works with no code change. |
| D6 | Restore runs only on the VPS (`make prod-restore`), never from the laptop scripts. |

## 1. Sidecar, compose, env

### `deploy/backup/backup.sh` (rewrite, POSIX `sh`, runs in alpine)

Commands:

| Command | Does |
|---|---|
| `schedule` (default) | preflight, seed the metric from `last-success`, write crontab, `exec crond -f` |
| `once` | one backup (under the lock) |
| `status` | print `last-success` and its age; non-zero if missing or older than `BACKUP_MAX_AGE_HOURS` |
| `list` | stamps in `postgres/`, oldest first; stamps newer than `last-success` are marked as not from a successful run |
| `restore <stamp\|latest>` | restore the database (under the lock); requires `RESTORE_CONFIRM=yes` |

Remote layout under `$RCLONE_REMOTE` (e.g. `gdrive:myservice`):

```
postgres/<stamp>.dump       pg_dump --format=custom
pre-restore/<stamp>.dump    the database as it was just before a restore
last-success                stamp of the last fully successful run
```

Stamp format `YYYYMMDDTHHMMSSZ` (UTC).

Preflight (fail fast, non-zero exit, message says what to fix):
- `RCLONE_REMOTE` set.
- `RCLONE_REMOTE` contains `name:`; a bare path would write onto the VPS's own disk and is refused unless
  `BACKUP_ALLOW_LOCAL_REMOTE=1` (tests and the manual dev check only).
- `rclone mkdir "$RCLONE_REMOTE"` succeeds (idempotent, also works on an empty remote).
- `pg_isready` against `db`.

One run (`once`):
1. Remove leftover `*.dump` in the temp dir (safe: the lock is held).
2. `pg_dump --format=custom` to `$BACKUP_TMP/<stamp>.dump`, then `rclone copyto` to `postgres/<stamp>.dump`.
3. Only if 2 succeeded: prune `postgres/` and `pre-restore/` entries whose **name stamp** is older than
   `BACKUP_RETENTION_DAYS`; entries whose name is not a stamp are ignored. Then write `last-success`.
4. Write the metric file (§3) — on failure too.

A failing run never prunes and never moves `last-success`.

Restore (`restore <stamp|latest>`):
1. Refuse without `RESTORE_CONFIRM=yes`.
2. `latest` resolves through `last-success`, never "newest file in `postgres/`".
3. The dump must exist on the remote.
4. Safety dump of the current database, uploaded to `pre-restore/<now>.dump`. If either fails: stop, nothing changed.
5. Download the chosen dump; `pg_restore --clean --if-exists --no-owner --single-transaction`. A failure rolls back and
   leaves the database unchanged.

Mechanics:
- `flock -n` on `$BACKUP_LOCK` (default `/var/lock/backup/lock`, on named volume `backup_lock`) wraps `once` and
  `restore`, so `docker compose run --rm backup once` cannot overlap the long-lived `schedule` container's cron run.
- Temp files are tracked and removed by an `EXIT` trap.
- busybox `crond` does not pass the environment to jobs: `schedule` writes `export -p` to an owner-only file (`umask 077`)
  that the cron line sources; job output goes to `/proc/1/fd/1` so it shows in `docker compose logs`.
- rclone is throttled for the 64 MB limit: `--transfers 2 --checkers 4 --buffer-size 8M`.
- Paths overridable for tests: `BACKUP_TMP` (default `/tmp`), `BACKUP_LOCK`, `BACKUP_METRICS_DIR` (default `/metrics`).
- Header comment doubles as `--help`, per repository convention.

### `deploy/backup/Dockerfile`

`alpine:3.21` + `postgresql17-client` + `rclone` + `tzdata`. Entrypoint `backup.sh`, default command `schedule`.

### `deploy/compose.prod.yml` — `backup` service

- `profiles: ["backup"]`.
- Environment, all with `:-` defaults (compose interpolates profiled services even when inactive, so no `:?`):
  `RCLONE_REMOTE`, `BACKUP_CRON` (`0 */6 * * *`), `BACKUP_TZ` (`UTC`, passed to the container as `TZ`; a bare `TZ`
  would be picked up from the operator's shell by compose interpolation), `BACKUP_RETENTION_DAYS` (30), `BACKUP_MAX_AGE_HOURS`
  (12), `RCLONE_CONFIG=/config/rclone.conf`. `POSTGRES_*` as today (`POSTGRES_PASSWORD` keeps its existing `:?`).
- Volumes:
  - `${RCLONE_CONFIG_FILE:-./backup/rclone.conf}:/config/rclone.conf` — **read-write**: rclone writes refreshed OAuth
    tokens back.
  - `backup_lock:/var/lock/backup`
  - `backup_metrics:/metrics`
- Removed: `BACKUP_DIR`, `BACKUP_INTERVAL_SECONDS`, the `./backups` bind mount.
- `mem_limit: 64m` unchanged; memory budget comment unchanged.
- New named volumes `backup_lock`, `backup_metrics`.

### Other files
- `deploy/.env.prod.example`: replace the backup block with a commented one (`COMPOSE_PROFILES=backup,observability`,
  `RCLONE_REMOTE`, `RCLONE_CONFIG_FILE`, `BACKUP_*`, `TZ`) and a pointer to `docs/deployment.md` §6. Note there that
  `BackupStale`'s 12 h threshold is hardcoded in `rules.json` and must change together with `BACKUP_MAX_AGE_HOURS`.
- `.gitignore`: `deploy/backup/rclone.conf`.

## 2. Commands

### Makefile (run on the VPS)

| Target | Does |
|---|---|
| `prod-backup-now` | `$(PROD) --profile backup run --rm backup once` |
| `prod-backup-status` | `$(PROD) --profile backup run --rm backup status` |
| `prod-backup-list` | `$(PROD) --profile backup run --rm backup list` |
| `prod-restore STAMP=<stamp\|latest>` | confirm → stop app (and Watchtower only if running) → `run --rm -e RESTORE_CONFIRM=yes backup restore $(STAMP)` → start the same set |

- `--profile backup` explicitly, so the targets work on a host whose `.env.prod` does not enable the profile (fresh host
  being restored).
- `prod-restore` asks for `yes` typed back unless `CONFIRM=yes` is passed; usage error without `STAMP`. The old `FILE=`
  form is removed.
- Watchtower is stopped during restore only if it was running, so it cannot recreate a replica mid-restore. A
  Watchtower stopped by `prod-rollback` stays stopped. `start` runs even if restore failed (the database is then
  unchanged), and the target still exits non-zero.
- Schema after restore: Liquibase at app start migrates forward; expand/contract (deployment.md §5) keeps older dumps
  compatible.

### `scripts/vps.sh` (run on the laptop)

- New command `backup-status`: over SSH, `docker compose … --profile backup run --rm backup status`. Make target
  `vps-backup-status`.
- `deploy-status` appends one line:
  - `backups: DISABLED (COMPOSE_PROFILES lacks backup)` when the remote `.env.prod` does not enable the profile;
  - otherwise the `status` output, prefixed `backups: ok` or `backups: STALE`.
- No restore command.

### Skill

`.claude/skills/vps-db/SKILL.md` gains a short "Backups" section: use `make vps-backup-status`; restore is never run by
Claude — hand the user the `ssh` + `make prod-restore STAMP=…` command.

## 3. Metric and alert

### Metric file

Written atomically (temp file + `mv`) to `$BACKUP_METRICS_DIR/backup.prom` after every run:

```
# HELP app_backup_last_success_timestamp_seconds Unix time of the last fully successful backup.
# TYPE app_backup_last_success_timestamp_seconds gauge
app_backup_last_success_timestamp_seconds 1790000000
# HELP app_backup_last_run_success 1 if the most recent backup run succeeded, else 0.
# TYPE app_backup_last_run_success gauge
app_backup_last_run_success 1
```

- A failed run writes `last_run_success 0` and keeps the previous success timestamp (read from the previous file, else
  from remote `last-success`, else the line is omitted).
- `schedule` seeds the file from remote `last-success` at start, so a recreated container reports immediately.
- Names follow the `app.<area>.<thing>` convention.

### Alloy (`deploy/alloy/config.alloy`)

```
prometheus.exporter.unix "backup" {
	set_collectors = ["textfile"]
	textfile { directory = "/metrics/backup" }
}

prometheus.scrape "backup" {
	targets         = prometheus.exporter.unix.backup.targets
	job_name        = "backup"
	scrape_interval = "60s"
	forward_to      = [prometheus.remote_write.out.receiver]
}
```

- Prod compose: `alloy` mounts `backup_metrics:/metrics/backup:ro`.
- Local `compose.yml` has no sidecar: the directory is empty or absent, the collector exports nothing, and the same
  config file keeps working locally. Verified during implementation.

### Alert `BackupStale` (`deploy/grafana/alerting/rules.json`)

- Group `app-baseline`, severity `critical`, `for: 15m`.
- Expression: `time() - max(app_backup_last_success_timestamp_seconds{env="prod"}) > 43200`.
- `noDataState: OK` — no series means backups are disabled, which is a valid configuration (D2). `execErrState: Error`.
- Summary points to `make prod-backup-status` and `make prod-logs SERVICE=backup`.
- A dead sidecar is covered: the file stops changing, the timestamp ages, the alert fires.

### Dashboard (`deploy/grafana/dashboards/app-overview.json`)

One stat panel "Last successful backup": `time() - max(app_backup_last_success_timestamp_seconds{env="prod"})`, unit
seconds, green < 43200, red ≥ 43200, "No data" text "backups disabled".

## 4. Testing

- `scripts/tests/backup.test.sh` (new, no Docker, part of `make test-scripts`). Fakes on `PATH`: `pg_isready`,
  `pg_dump` (writes a known payload; can be told to fail), `pg_restore` (records its arguments), and `rclone` mapping
  `name:path` onto a temp directory (`mkdir`, `copyto`, `lsf`, `cat`, `rcat`, `deletefile`). Cases:
  - missing `RCLONE_REMOTE` → non-zero, message names the variable;
  - remote without `name:` → refused; accepted with `BACKUP_ALLOW_LOCAL_REMOTE=1`;
  - `once` → dump uploaded, `last-success` written, metric has `last_run_success 1` and the timestamp;
  - `pg_dump` failure → non-zero, nothing pruned, `last-success` unchanged, metric `last_run_success 0` with the old
    timestamp;
  - prune → stamps older than retention removed, newer kept, non-stamp names untouched, decision by name not mtime;
  - `status` → zero when fresh, non-zero when stale or missing;
  - `list` → sorted, stamps after `last-success` marked;
  - `restore` → refused without `RESTORE_CONFIRM=yes`; `latest` resolves via `last-success`; safety dump uploaded before
    `pg_restore` is called; unknown stamp refused;
  - lock held → second `once` exits non-zero.
- `scripts/tests/deploy-config.test.sh`: prod compose `config -q` also with `--profile backup`; `rclone.conf` is
  gitignored; `bash -n`/`sh -n` on `backup.sh`; `shellcheck` when installed.
- `scripts/tests/vps.test.sh`: `deploy-status` backup line in the DISABLED / ok / STALE states; `backup-status`
  issues the expected SSH command.
- `DashboardJsonTest`: the backup panel exists; `BackupStale` exists with `noDataState: OK`.
- Manual, once before claiming done: build the image; against the local dev Postgres with a local-path remote
  (`BACKUP_ALLOW_LOCAL_REMOTE=1`) run `once`, `list`, `status`, `restore latest`; start Alloy with the observability
  profile and confirm the textfile is picked up (or that an empty directory does not break it).
- `make build` green.

## 5. Docs and rollout

- `docs/deployment.md` §6 rewritten: pick a remote; `rclone config` on the laptop (Drive needs a browser; Storage Box
  over sftp needs none); `scp` the file to `deploy/backup/rclone.conf` on the VPS; set `COMPOSE_PROFILES` and
  `RCLONE_REMOTE`; `make prod-up`; `make prod-backup-now`; confirm the dump on the remote; only then delete old
  `deploy/backups/*.dump` by hand. Restore procedure and what `pre-restore/` holds.
- `docs/observability.md`: `BackupStale` runbook entry.
- README checklist: one line about enabling backups.
- `CLAUDE.md` "How this is hosted": backups are opt-in (`backup` profile), rclone off-host, `BackupStale` alert.
  "Invariants": `BackupStale` threshold ≥ `BACKUP_MAX_AGE_HOURS` and ≥ 2× the cron interval.
- Existing deployments: after upgrade the backup container is gone until the profile is enabled; local dumps stay on
  disk untouched.
- Commit type `feat(backup)` (minor). Not marked breaking; the owner decides that.

## Out of scope

Object storage/MinIO; encryption by default; WAL archiving / point-in-time recovery; restore from the laptop;
alerting on backup size anomalies.
