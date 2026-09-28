# CLAUDE.md

Spring Boot 4.1 / Java 25 service created from `spring-template`. Replace this paragraph with one sentence about
what the service does; everything below stays true for every project built from the template.

## Commands

| Command | What | Time |
|---|---|---|
| `make run` | app on :8080, Postgres from `compose.yml` | 20 s |
| `make test` | unit tests, no Docker | 10 s |
| `make itest` | integration tests, Testcontainers, one Postgres per fork | 1 min |
| `make build` | everything CI's `build` job runs: Spotless, unit, integration, JaCoCo gate 60 % | 1–2 min |
| `make test-scripts` | bash tests under `scripts/tests` | 5 s |
| `make format` | `spotlessApply`; run before every commit that touches Java or `*.gradle.kts` | |
| `make observability-up` | Prometheus + Grafana (`:3000`) + Alloy | |
| `make release-name` | version the next push to main would release | |

The tree is clean at `HEAD` (build, tests, Spotless): any failure after your change is yours. `make run`/`test`/
`build` call `make setup` first, which installs the commit-msg hook.

## How this is hosted and deployed

- One Hetzner VPS running `deploy/compose.prod.yml`: Caddy (TLS, only published ports) → 2 `app` replicas →
  Postgres (loopback only), plus Watchtower and, by compose profile, an off-host backup sidecar (`backup`: pg_dump →
  rclone, `BackupStale` alert; `docs/deployment.md` §6) and Alloy.
- **Push to `main` = deploy.** `ci.yml` builds and tests, packages `ghcr.io/<owner>/<repo>:{latest,X.Y.Z,X.Y,sha-…}`,
  tags `vX.Y.Z`, publishes a GitHub Release, and waits until `${PRODUCTION_URL}/version` reports the new revision
  from every replica. Watchtower on the VPS pulls `latest` within 60 s and restarts replicas one at a time.
  Push → live ≈ 5–6 min. Nobody ever SSHes to deploy.
- Rollback on the VPS: `make prod-rollback TAG=<previous version>`. Schema is not rolled back: changesets must work
  with the previous release (expand/contract; `docs/deployment.md` §5).
- `MANAGEMENT_PORT=8081` in prod: actuator is never published or proxied. `/version` is the only public build info.

## Commits and versions

Subjects: `<type>(<scope>)!: <imperative summary>` with type ∈ `feat fix perf refactor docs test build ci chore
style revert`. `feat` → minor, `!`/`BREAKING CHANGE:` → major (only when the user says so), rest → patch. Body
explains why. The hook and CI reject anything else. Details: `.claude/skills/release/SKILL.md`.

## Production database and logs

`scripts/vps.sh` (needs `VPS_SSH` in `.env`): `make vps-status`, `make vps-logs SERVICE=app`,
`make vps-psql SQL="select …"`, `make vps-datagrip`. Credentials are read from the VPS per call and never stored
locally. Read-only unless the user asked for a specific change; never fix schema by hand. Skill:
`.claude/skills/vps-db/SKILL.md`.

## Observability

`deploy/grafana/dashboards/app-overview.json` is the one dashboard; local Grafana loads it from disk, CI pushes it to
Grafana Cloud on merge. `DashboardJsonTest` guards it. Alerts ship only when Telegram secrets exist. Metric names
`app.<area>.<thing>`, low-cardinality tags only. Skill: `.claude/skills/grafana/SKILL.md`.

## Conventions

- Layers: `controller` → `service` → `repository`; `job` (schedulers, `*Scheduler`) may call services. Enforced by
  `ArchitectureTest`, including constructor injection only, no `System.out`, `@Scheduled` only under `job`.
- Liquibase owns the schema (`db/changelog/changes/*.yaml`, `includeAll`); Hibernate validates. Boot 4 needs
  `spring-boot-liquibase` on the classpath or nothing runs — it is there, do not remove it.
- Config idiom `${ENV_VAR:default}` in `application.yml`; typed access via `@ConfigurationProperties` records +
  `@EnableConfigurationProperties` (see `AppInfoProperties`).
- `@Slf4j` only. Secrets never reach logs: `SecretRedactor`, the redacting Feign logger and
  `RequestResponseLoggingFilter` (DEBUG only) already cover HTTP; use `SecretRedactor.redact` for anything else.
- Errors: throw `ApplicationException(status, message)`; `GlobalExceptionHandler` renders RFC 9457. Client mistakes
  (404/405/400) are quiet; only unexpected exceptions log at ERROR.
- Feign clients under `client/`, wrapped in a circuit breaker with a fallback class. Inject `Clock`, never
  `Instant.now()` directly.
- Tests: unit under `unit/` (concurrent, no Spring unless `@WebMvcTest`), integration under `integration/` extending
  `AbstractIntegrationTest` (constructor injection, MockMvc). Test data via `support.Fixtures` (Instancio).
- Bash lives in `scripts/`, tested by `scripts/tests/*.test.sh`; every script has `set -euo pipefail` and a header
  comment that doubles as `--help`.

## Invariants that break production silently

- `DOCKER_API_VERSION: "1.44"` on Watchtower. Remove it and Docker 25+ rejects Watchtower's API calls: no deploys,
  healthy-looking container.
- `APP_REPLICAS × DB_POOL_SIZE < max_connections (50)`.
- `stop_grace_period` (45 s) > `SPRING_LIFECYCLE_TIMEOUT_PER_SHUTDOWN_PHASE` (30 s) < `WATCHTOWER_TIMEOUT` (60 s).
- `deploy/.env.prod` required values carry `:?` guards; keep them when adding variables.
- `BackupStale` threshold (43200 s in `rules.json`) ≥ `BACKUP_MAX_AGE_HOURS` and ≥ 2 × the `BACKUP_CRON` interval,
  or every late run pages.
- The rclone config is a mounted read-write **directory** (`deploy/backup/rclone/`), never a single file: rclone
  saves refreshed tokens by rename, so a single-file mount logs a save error on every token refresh and breaks
  providers that rotate refresh tokens.

## Process

Brainstorm → plan → TDD → verify → commit (superpowers skills). Specs and plans live in
`docs/superpowers/{specs,plans}/YYYY-MM-DD-*.md`. Verify with the command, read the output, then claim.
