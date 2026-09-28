# Deployment runbook

One VPS runs everything through `deploy/compose.prod.yml`. CI publishes images; the host pulls them. This document
covers what the README's checklist does not: first-time host setup, what healthy looks like, rollback, backups and
the rule that makes rolling deploys safe.

## 1. Host prerequisites

- Ubuntu/Debian VPS, 2 vCPU / 4 GB is comfortable (memory budget below). Hetzner CX (x86) or CAX (ARM) both work.
- Docker Engine with the compose plugin (`docker compose version` ≥ 2.24). Add your user to the `docker` group.
- Ports 80 and 443 open in the provider firewall. Nothing else inbound except SSH.
- Swap (1–2 GB) is cheap insurance against the JVM and Postgres meeting an OOM killer at the same time.
- DNS `A` record for `DOMAIN` pointing at the VPS **before** `make prod-up`: Caddy asks Let's Encrypt on first start
  and failed attempts are rate-limited. While DNS propagates, uncomment `acme_ca` (staging) in `deploy/Caddyfile`.

## 2. First bring-up

```bash
git clone https://github.com/<owner>/<repo>.git && cd <repo>
make prod-init           # deploy/.env.prod, mode 600, generated POSTGRES_PASSWORD
$EDITOR deploy/.env.prod # DOMAIN, ACME_EMAIL; optional Grafana Cloud block + COMPOSE_PROFILES=observability
make prod-up             # `compose config -q` first: every :? guard fires here, not after the stack is down
make prod-ps
```

If the GHCR package is private: `docker login ghcr.io` with a PAT (`read:packages`), then set
`DOCKER_CONFIG_FILE=/home/<user>/.docker/config.json` in `deploy/.env.prod` so Watchtower can pull too. Public
packages need nothing.

## 3. What healthy looks like

```bash
make prod-ps                        # app ×2 healthy, caddy/db/watchtower/backup up
make prod-logs SERVICE=watchtower   # "Scanned=1 Updated=0 Failed=0" once per poll: label scoping works
curl -s https://$DOMAIN/version     # {"version":"1.4.2","revision":"<sha>"}
curl -s -o /dev/null -w '%{http_code}\n' https://$DOMAIN/actuator/health   # 404: actuator is not exposed
```

From your machine: `make vps-status`, `make vps-logs SERVICE=app` (needs `VPS_SSH` in `.env`).

## 4. How a rollout proceeds

1. CI pushes `ghcr.io/<owner>/<repo>:latest` with a new digest.
2. Watchtower (`WATCHTOWER_POLL_INTERVAL`, 60 s) sees it and, because `WATCHTOWER_ROLLING_RESTART=true`, stops one
   `app` replica. Spring's graceful shutdown drains in-flight requests (up to 30 s); `stop_grace_period` is 45 s.
3. Caddy's passive health check drops the refused replica within one failed dial; new connections go to the other.
4. The new container starts and runs Liquibase. Watchtower then runs the replica's `post-update` lifecycle hook,
   which polls `/actuator/health` until it reports `UP` (up to 3 min); Caddy's DNS refresh (5 s) adds the replica.
5. Only now does Watchtower repeat the cycle for replica 2. Without the hook (`WATCHTOWER_LIFECYCLE_HOOKS`), rolling
   restart is stop→start→next and both replicas are down for one JVM boot. CI's `deploy` job samples `/version` four times per round and marks the GitHub Deployment
   successful once every answer carries the new revision (15 min timeout).

A red `deploy` job means "published but not picked up": check Watchtower logs first. The one silent killer is
`DOCKER_API_VERSION`: without the pin in the compose file, Docker 25+ rejects Watchtower 1.7.1's API version and it
deploys nothing while looking healthy.

## 5. Rollback

```bash
make prod-rollback TAG=1.4.1        # or TAG=sha-abc1234; every GitHub Release names its tag
```

This stops Watchtower (so it does not immediately re-pull `latest`), pins `APP_IMAGE_TAG`, and recreates the app
replicas. To resume automatic deploys after the fix ships:

```bash
sed -i 's/^APP_IMAGE_TAG=.*/APP_IMAGE_TAG=latest/' deploy/.env.prod
docker compose -f deploy/compose.prod.yml --env-file deploy/.env.prod up -d app watchtower
```

### The migration rule (expand / contract)

Rolling the image back does not roll the schema back, and during a rolling restart the old and new code run against
the same database for about a minute. Therefore every Liquibase changeset must work with the **previous** release's
code:

- Adding a table, a nullable column, an index: fine in one release.
- Renaming or dropping a column, tightening a constraint: two releases. First release adds the new shape and stops
  reading the old one; the next release drops it.
- Never edit a changeset that has run in production; add a new one.

Liquibase's `DATABASECHANGELOGLOCK` serialises the two replicas at boot, so a migration runs once.

## 6. Backups and restore

The `backup` service runs `pg_dump -Fc` every `BACKUP_INTERVAL_SECONDS` (daily) into `BACKUP_DIR` (`./backups`,
relative to `deploy/`, so `deploy/backups/` on the host) and
prunes dumps older than `BACKUP_RETENTION_DAYS` (14) **only after a successful dump**. Copy the directory off the host
(cron + `rsync`, or object storage) — a backup on the same disk as the database is a convenience, not a backup.

```bash
make prod-backup-now                                  # one dump right now
make prod-restore FILE=deploy/backups/20260928T020000Z.dump  # stops app, pg_restore --clean, starts app
```

## 7. Memory budget

| Service | `mem_limit` | Note |
|---|---|---|
| caddy | 64 MB | |
| app × 2 | 512 MB each (`APP_MEM_LIMIT`) | JVM heap ≤ 75 % via `JAVA_TOOL_OPTIONS`; exits on OOM so Docker restarts it |
| db | 384 MB | `shared_buffers=128MB`, `max_connections=50` ≥ `APP_REPLICAS × DB_POOL_SIZE` + tools |
| watchtower | 48 MB | |
| backup | 64 MB | |
| alloy | 128 MB | only with `COMPOSE_PROFILES=observability` |
| **total** | **≈ 1.7 GB** | fits a 4 GB VPS with headroom for the OS and page cache |

Re-do this sum when adding a service or raising a limit.

## 8. Operations cheat sheet

| Task | Command (on the VPS) |
|---|---|
| Status / logs | `make prod-ps`, `make prod-logs SERVICE=app` |
| Pull now instead of waiting for Watchtower | `make prod-pull` |
| Stop everything (volumes kept) | `make prod-down` |
| Database shell | from your machine: `make vps-psql`; on the VPS: `docker compose -f deploy/compose.prod.yml --env-file deploy/.env.prod exec db psql -U app app` |
| Rotate the DB password | `scripts/init-prod-env.sh --force` is **not** enough: change it in Postgres (`ALTER USER`), then in `.env.prod`, then `make prod-up` |
| Change replicas / memory | edit `APP_REPLICAS` / `APP_MEM_LIMIT` in `.env.prod`, `make prod-up` |

## 9. Accepted exposure

- Caddy is the only listener. HSTS, nosniff and a `SAMEORIGIN` frame policy are set; add CSP when you serve HTML.
- Watchtower has the Docker socket (read-only mount, still root-equivalent). It only touches containers labelled
  `watchtower.enable=true`. Pinning `APP_IMAGE_TAG` to a digest-stable tag removes the "pull whatever `latest` is"
  trust in GHCR if you need it.
- No authentication is wired into the app. `/actuator/health` shows details; it is unreachable from outside, but add
  Spring Security before exposing anything user-specific.
