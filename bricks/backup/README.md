# backup: pg_dump every 6 h to any rclone remote, with status, list and restore

`make add BRICK=backup`, put `rclone.conf` in `bricks/backup/rclone/` on the VPS, set `RCLONE_REMOTE` in
`deploy/.env.prod`, `make prod-up`. Memory: 64m. Without this brick there are no backups.

Backups are **off until you configure them** and never stay on the VPS. The `backup` service runs `pg_dump -Fc` on `BACKUP_CRON` (every 6 h) and uploads it with
[rclone](https://rclone.org) to a remote you choose. A dump on the same disk as the database does not survive losing that disk, so there is no local mode.

## Enable

1. Pick a remote; anything rclone supports works. Two cheap ones:
   - **Google Drive** (15 GB free): on your **laptop** (it opens a browser) run `rclone config` → `n` → name `gdrive`
     → storage `drive` → scope `drive.file` → finish the browser login.
   - **Hetzner Storage Box** (≈ €4/month, same data centre, no browser): storage `sftp`, host
     `uXXXXX.your-storagebox.de`, port `23`, user `uXXXXX`, an SSH key or password.
2. Copy the config to the VPS and lock it down (it holds the remote's credentials):
   `ssh <vps> 'mkdir -p <repo>/bricks/backup/rclone && chmod 700 <repo>/bricks/backup/rclone'`, then
   `scp ~/.config/rclone/rclone.conf <vps>:<repo>/bricks/backup/rclone/rclone.conf && ssh <vps> chmod 600 <repo>/bricks/backup/rclone/rclone.conf`.
   The container mounts the directory, not the file: rclone saves refreshed tokens by renaming a new file over
   `rclone.conf`, which a single-file mount rejects.
3. `make add BRICK=backup` (on the VPS checkout; it appends the brick's variables to `deploy/.env.prod.example`), and in
   `deploy/.env.prod` set `RCLONE_REMOTE=gdrive:<service-name>`. Optional: `BACKUP_CRON`, `BACKUP_TZ`, `BACKUP_RETENTION_DAYS` (30),
   `BACKUP_MAX_AGE_HOURS` (12).
4. `make prod-up`. If the remote or Postgres is unreachable the container exits with the reason:
   `make prod-logs SERVICE=backup`.
5. `make prod-backup-now`, then `make prod-backup-list`: the new stamp must be listed. Look at the remote once too.

Upgrading from the old local backups: once step 5 works, delete `deploy/backups/` by hand.

## Disable

`make remove BRICK=backup`, then `make prod-up` (it passes `--remove-orphans`, which stops the container), then delete
its last metric —
otherwise Alloy keeps exporting the frozen timestamp and `BackupStale` fires forever:
`docker run --rm -v <COMPOSE_PROJECT_NAME>_backup_metrics:/m alpine rm -f /m/backup.prom` (or stop `alloy` and
`docker volume rm <COMPOSE_PROJECT_NAME>_backup_metrics`).

## What is on the remote

```
postgres/<stamp>.dump       pg_dump --format=custom, one per successful run
pre-restore/<stamp>.dump    the database as it was just before a restore
last-success                stamp of the last fully successful run
```

Stamps are UTC (`20260928T060000Z`). After a successful run, dumps older than `BACKUP_RETENTION_DAYS` are pruned
from `postgres/` and `pre-restore/`; a failed run prunes nothing.

## Is it working?

```bash
make prod-backup-status     # on the VPS: last success and its age, non-zero beyond BACKUP_MAX_AGE_HOURS
make vps-backup-status      # the same from your laptop; `make vps-status` prints a one-line summary
```

With the observability brick on, the `BackupStale` alert fires after 12 h without a successful backup
([observability README](../observability/README.md)). Its threshold is in `bricks/observability/grafana/alerting/rules.json`; change it together
with `BACKUP_MAX_AGE_HOURS`.

## Restore

```bash
make prod-backup-list                  # stamps, oldest first
make prod-restore STAMP=latest         # or a stamp from the list; asks you to type yes
```

Stops the app replicas (and Watchtower, only if it was running) — if reading container state or stopping them fails,
nothing is restored and whatever was stopped is started again — then uploads a dump of the **current** database to
`pre-restore/`, replaces the whole `public` schema with the dump's in one transaction (a failure leaves the database
unchanged), then starts everything again either way; a failed restore still leaves the command exiting non-zero.
`latest` means the last *successful* run, never merely the newest file. Tables created after the dump are gone
afterwards — the database is exactly what it was at the dump, including its `databasechangelog` — and the app's
Liquibase migrates it forward from there when it starts.

To undo a restore, copy the safety dump back into `postgres/` and restore it:
`docker compose -f deploy/compose.prod.yml --env-file deploy/.env.prod run --rm --entrypoint rclone backup copyto "$RCLONE_REMOTE/pre-restore/<stamp>.dump" "$RCLONE_REMOTE/postgres/<stamp>.dump"`
(with `RCLONE_REMOTE` exported in your shell), then `make prod-restore STAMP=<stamp>`.

On a **new host**: `make prod-init`, `make add BRICK=backup`, copy `rclone.conf` and fill `.env.prod` as above, then start
everything **except** the scheduler: `docker compose -f deploy/compose.prod.yml --env-file deploy/.env.prod up -d db app
caddy`. Then `make prod-backup-list`, `make prod-restore STAMP=<the stamp you want>` (an explicit stamp, not `latest`),
and finally `make prod-up`. A scheduler running before the restore could back up the new, empty database and make it
`latest` — and start pruning towards it.

## Invariants

- The rclone config is a mounted read-write **directory** (`bricks/backup/rclone/`), never a single file: rclone saves
  refreshed tokens by rename, so a single-file mount logs a save error on every token refresh and breaks providers that
  rotate refresh tokens. The compose bind has `create_host_path: false`; the directory is kept in git by a `.gitkeep`,
  everything else in it is ignored.
- The `BackupStale` threshold (43200 s in the observability brick's `rules.json`) must be >= `BACKUP_MAX_AGE_HOURS` and
  >= 2 x the `BACKUP_CRON` interval, or every late run pages.
- `make prod-restore` stops Watchtower only if it was running, so a `prod-rollback` pin survives a restore.
- `backup_metrics` is shared with the observability brick's Alloy; this brick declares the volume, so it works alone.
