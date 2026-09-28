---
name: vps-db
description: Reach the production VPS and its PostgreSQL over SSH — inspect deployed version, tail prod logs, run read-only SQL, hand the user a DataGrip connection. Use when the user asks what is running in prod, wants prod logs, wants to query/inspect the production database, or asks for a DB connection for DataGrip/psql.
---

# Production VPS and database access

Everything goes through `scripts/vps.sh`. It reads `VPS_SSH` (and optional `VPS_APP_DIR`, `VPS_DB_LOCAL_PORT`) from
the environment or `.env`; credentials for the database are fetched from `deploy/.env.prod` **on the VPS** for each
call and never written to disk here. If `VPS_SSH` is missing, ask the user for `user@host` and suggest adding it to
`.env`.

## Commands

| Need | Run |
|---|---|
| What is deployed right now | `scripts/vps.sh deploy-status` (image tag per replica + `/version`) |
| Containers and health | `scripts/vps.sh ps` |
| Logs | `scripts/vps.sh logs app` (or `caddy`, `watchtower`, `db`, `backup`) |
| Config on the VPS, secrets masked | `scripts/vps.sh env` |
| One SQL statement | `scripts/vps.sh psql "select count(*) from databasechangelog"` |
| Interactive psql | `scripts/vps.sh psql` (interactive — tell the user to run it themselves) |
| DataGrip connection | `scripts/vps.sh datagrip` → prints a JDBC URL and opens the SSH tunnel in the background |
| Shell on the VPS | `scripts/vps.sh ssh` (interactive — user runs it) |

Postgres on the VPS listens on `127.0.0.1` only; every DB command opens an SSH tunnel to `localhost:15432` first.
Close it with `pkill -f 'ssh .*-L 15432:'` when done.

## Rules

- **Read-only by default.** `SELECT`, `EXPLAIN`, `\d` are fine. Run `INSERT/UPDATE/DELETE/ALTER/DROP` only when the
  user asked for that exact change in this conversation; echo the statement before running it and prefer a
  transaction with an explicit `COMMIT` the user confirms.
- **Never paste secrets into the chat.** Use `env` (masked), not `cat`. The JDBC URL from `datagrip` contains the
  password: show it once because the user asked for it, do not repeat it in summaries.
- Schema belongs to Liquibase. Never fix a schema problem with ad-hoc DDL in prod; write a changeset.
- Before a restore or rollback, read `docs/deployment.md` (rollback + expand/contract rules).
- A `deploy` job failure means the image is published but the host did not pick it up: check
  `scripts/vps.sh logs watchtower` first (`Scanned=…` lines and `DOCKER_API_VERSION` errors).
