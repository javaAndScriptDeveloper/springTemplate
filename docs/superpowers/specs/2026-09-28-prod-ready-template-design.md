# Production-ready template: CI/CD, single-VPS deploy, observability, tooling

Date: 2026-09-28
Status: approved in conversation (sections 1–3 explicitly; 4–6 delegated: "go implement, I trust you")

## Goal

Make this template a fast start for solo pet projects hosted on one Hetzner VPS. Target flow:

```
clone template → rename package → push to main → CI tests → image on GHCR + GitHub Release
→ Watchtower on the VPS pulls → rolling restart behind Caddy → Grafana shows the new version
```

Time from `git push` to serving traffic: about 5–6 minutes. Time from a fresh clone to a running
local app: `make run`, no env file needed.

Success criteria:

- `make run` works with zero configuration (committed `.env.example` defaults).
- One VPS bootstrap (`make prod-init`, fill 3–6 values, `make prod-up`), then hands-off deploys.
- Every push to main produces: git tag `vX.Y.Z`, GitHub Release with auto-generated notes and
  rollback commands, image tags `latest`, `X.Y.Z`, `X.Y`, `sha-<short>`.
- Grafana (local and Grafana Cloud) shows the running version and deploy markers with one committed
  dashboard.
- Claude has skills to reach the prod DB over SSH and push dashboards; CLAUDE.md states how the
  app is hosted, how deploys happen, and how to reach the DB.
- README lists exactly which values to set where, and why.

Out of scope: Kubernetes, managed DB, object storage, Loki/tracing, multi-environment (staging),
semantic-release/Node tooling, CodeQL (needs paid GHAS on private repos).

## Findings that shaped the design

Template bugs (all fixed here):

- `liquibase-core` without `spring-boot-liquibase` → on Boot 4 no changesets ever run.
- `prometheus` in actuator exposure but no `micrometer-registry-prometheus` → 404.
- Spotless' bundled palantir-java-format crashes on JDK 25; pin 2.97.0.
- `GlobalExceptionHandler` handles `RestClientException` (Feign throws `FeignException`) and leaks
  upstream messages to the client; 404/405/400 fall into the 500 handler with ERROR stack traces.
- `JobLoggingAspect` wraps `@Scheduled` but nothing enables scheduling.
- README overclaims (retry "wired", Prometheus "works"); 9 of 11 packages are empty `.gitkeep`.
- `.gitignore` ignores `CLAUDE.md`, so a project CLAUDE.md can never be committed.
- Renovate config does nothing until the Renovate app is installed per repo.

Patterns taken from `silpoRestockAI` and `submissions-checker` (both by the same author): GHCR image
job, Caddy dynamic upstreams + Watchtower rolling restart, `${VAR:?}` guards, `x-logging` anchor,
`edge`/`data` networks, Alloy → Grafana Cloud with a local Prometheus+Grafana harness using the same
datasource uid, pg_dump sidecar, deploy-tracking job, SHA-pinned actions, `SecretRedactor`,
quiet 404/405/400 handlers, `Clock` bean, `SyncTaskExecutor` in tests.

## Decisions (with the alternative rejected)

| Decision | Chosen | Rejected because |
|---|---|---|
| Dependency updates | Dependabot (gradle, github-actions, docker; minor+patch grouped) | Renovate needs an app install per repo; silently inert on forks |
| Versioning | SemVer computed from Conventional Commits by a bash script | Animal names: not sortable; semantic-release: Node; release-please: PR step kills push=deploy |
| Prod topology | 2 replicas, Caddy dynamic DNS upstreams, Watchtower rolling restart | Single replica: downtime on every deploy |
| Image build | Jar built once in CI, Dockerfile is runtime-only | Compiling inside Docker under QEMU for arm64 is 4–5 min slower |
| Security | Fast lane in CI (parallel, ~1 min) + weekly heavy lane | CodeQL: slow, paid on private repos |
| Test speed | `test` (unit, JUnit concurrent) + `integrationTest` (Testcontainers, `maxParallelForks`, one Postgres per fork) | One shared DB with concurrent classes: flaky |
| Grafana prod push | CI job on merge (`deploy/grafana/**`), local script for ad-hoc | Local-only: token on every laptop |
| Alerting | Pushed only when Telegram secrets are set | Always-on: forces Telegram setup per project |
| Layout | `deploy/` dir for prod/observability; root keeps `compose.yml`, `Dockerfile` | Flat root: 8 infra files next to Gradle files |
| Local env | `.env.example` committed with working defaults; no generator | Generator/`.env.local`: a third file with the same content |
| Version visibility | `app_build_info{version,revision}` gauge, `/version` endpoint | Version tag on every metric: cardinality grows per release |

## Section 1 — CI/CD and versioning

### Conventional commits → SemVer

Commit subject regex (enforced locally and in CI):

```
^(feat|fix|perf|refactor|docs|test|build|ci|chore|style|revert)(\([a-z0-9._-]+\))?!?: .+
```

Bump rule, applied over all commits since the last `v*` tag; the highest wins:

- `!` after the type, or a `BREAKING CHANGE:` footer → major
- `feat` → minor
- everything else → patch (every push to main is a release)
- no tag yet → `v0.1.0`

`scripts/next-version.sh` prints the next version. Pure bash + git, tested by
`scripts/tests/next-version.test.sh` (creates a temp repo, asserts each rule). `scripts/lint-commits.sh
<range>` validates subjects; `.githooks/commit-msg` runs the same check on one message. `make setup`
sets `core.hooksPath=.githooks`; `make run`/`make test` call `setup` first (idempotent).

Merge commits (`Merge ...`) and Dependabot subjects (`build(deps): ...`) pass the regex.

### `.github/workflows/ci.yml`

Triggers: push to `main`, `pull_request`. `concurrency` cancels superseded runs. Default
`permissions: contents: read`. Actions pinned to commit SHAs with `# vN` comments.

Jobs:

1. `build` — JDK 25 (temurin), `gradle/actions/setup-gradle` (build cache persisted), `./gradlew build`
   (runs `test`, `integrationTest`, Spotless, JaCoCo gate), `scripts/tests/next-version.test.sh`,
   uploads `build/libs/*.jar` as artifact `jar`, uploads test/coverage reports. Also runs
   `lint-commits.sh` over `origin/main..HEAD` on PRs and over `<last tag>..HEAD` on main.
2. `security-fast` — parallel to `build`: gitleaks (full history), trivy fs (vuln, secret, misconfig;
   HIGH/CRITICAL; `.trivyignore.yaml`), zizmor (`--min-severity medium`).
3. `image` — `needs: [build, security-fast]`. Downloads the jar. Computes `VERSION`
   (`next-version.sh`, no `v`), `REVISION` (full sha), `IMAGE=ghcr.io/${GITHUB_REPOSITORY,,}`. QEMU +
   Buildx. `docker/build-push-action` with `platforms: linux/amd64,linux/arm64`, build args
   `APP_VERSION`, `APP_REVISION`, tags `latest`, `X.Y.Z`, `X.Y`, `sha-<short>` (`latest`/`X.Y` only
   on main), gha cache, `push` only on main. PRs build without pushing.
4. `release` — `needs: image`, main only, `contents: write`. Creates tag `vX.Y.Z` and a GitHub
   Release (`generate_release_notes: true`, so the body lists commits since the previous tag with a
   compare link). Body prepends image tag, digest, and rollback snippet.
5. `deploy` — `needs: [image, release]`, main only, `deployments: write`. Skipped with a notice unless
   repo variable `PRODUCTION_URL` is set. Opens a GitHub Deployment, polls `${PRODUCTION_URL}/version`
   four times per round until every answer has `revision == REVISION` (both replicas rolled), timeout
   15 min, closes the Deployment with success/failure.

### `.github/workflows/security-weekly.yml`

Cron Monday 06:00 Kyiv (`0 3 * * 1` UTC) + `workflow_dispatch`. Jobs: trivy image on
`ghcr.io/<repo>:latest` (pull, no rebuild), trivy fs. On failure: a step sends a Telegram message
(`TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` secrets) with the run URL; if the secrets are empty, GitHub's
default email on scheduled-workflow failure is the notification. Never blocks deploys.

### `.github/workflows/dashboards.yml`

Push to main with `paths: deploy/grafana/**` + `workflow_dispatch`. Runs
`scripts/grafana-push.sh cloud`. Skips with a notice when secret `GRAFANA_URL` is empty. Alerting
sub-step runs only when both Telegram secrets are set.

### `.github/dependabot.yml`

Weekly. Ecosystems: `gradle` (`/`, group `minor-and-patch`), `github-actions` (`/`), `docker` (`/`,
`/deploy`, `/deploy/backup`). `renovate.json` removed.

### Dockerfile (runtime only)

```dockerfile
FROM eclipse-temurin:25-jre
ARG APP_VERSION=local ARG APP_REVISION=dev
ENV APP_VERSION=... APP_REVISION=... JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError"
apt-get install curl (healthcheck); non-root user spring; WORKDIR /application owned by spring
COPY --chown build/libs/*.jar application.jar
HEALTHCHECK curl -sf http://127.0.0.1:${MANAGEMENT_PORT:-8080}/actuator/health
ENTRYPOINT ["java", "-jar", "application.jar"]
```

`make image` and `make up` run `./gradlew bootJar` first. `.dockerignore` keeps only `build/libs`.
Boot's `bootJar` output name fixed to `app.jar` via `archiveFileName` so `COPY` is unambiguous.

### Gradle: test split and speed

- `test`: excludes `**/integration/**`; JUnit `execution.parallel.enabled=true`, `mode.default=concurrent`,
  `mode.classes.default=concurrent`. No Docker.
- `integrationTest` (new `Test` task, same classpath): includes `**/integration/**`,
  `maxParallelForks = max(1, min(4, availableProcessors / 2))`, `maxHeapSize = 1g`. Each fork boots its
  own Spring context and Postgres container → isolated DBs.
- `check` depends on both; `jacocoTestReport` aggregates both execution files; gate raised to 0.60
  instruction coverage (config, `Application`, DTO records excluded).
- `gradle.properties`: `org.gradle.caching=true`, `org.gradle.parallel=true`,
  `org.gradle.configuration-cache=true`, `org.gradle.jvmargs=-Xmx2g`.
- Dependency locking on all configurations, `gradle.lockfile` committed (trivy scans it; reproducible
  builds). `make lock` regenerates.
- Two sample integration tests exist so the split is real: context-loads and `/version` + `/actuator/health`
  via MockMvc.

## Section 2 — Runtime

### `compose.yml` (root, local)

- `db` postgres:17-alpine, `127.0.0.1:${DB_PORT:-5432}:5432`, healthcheck, volume. No `container_name`.
- `app` (profile `full`) builds from `Dockerfile`, expects the jar; `SPRING_PROFILES_ACTIVE=prod`,
  `DB_URL=jdbc:postgresql://db:5432/...`.
- Profile `observability`: `prometheus` (v3, `--web.enable-remote-write-receiver`, 24h retention,
  empty scrape config), `grafana` (anonymous Admin, provisioning from `deploy/grafana/provisioning`,
  dashboards from `deploy/grafana/dashboards`, port 3000), `alloy` (`deploy/alloy/config.alloy`,
  `APP_METRICS_HOST=host.docker.internal`, `APP_METRICS_PORT=8080`, `extra_hosts: host-gateway`,
  remote write to `http://prometheus:9090/api/v1/write` with dummy creds, `APP_ENV=local`).
- `spring.docker.compose` starts only un-profiled services → `db`.

### `deploy/compose.prod.yml`

`name: ${COMPOSE_PROJECT_NAME:?}` (set by init script from repo name). `x-logging` anchor: json-file,
`max-size 10m`, `max-file 3`. Networks `edge`, `data`.

| Service | Key settings |
|---|---|
| `caddy` caddy:2-alpine | ports 80/443 only published service; `DOMAIN`, `ACME_EMAIL` `:?`-guarded; volumes `caddy_data`, `caddy_config`; `edge`; `mem_limit 64m`; watchtower disabled |
| `app` | `image: ${APP_IMAGE:?}:${APP_IMAGE_TAG:-latest}`; `deploy.replicas: ${APP_REPLICAS:-2}`; no container_name; `stop_grace_period: 45s`; env `SPRING_PROFILES_ACTIVE=prod`, `MANAGEMENT_PORT=8081`, `APP_ENV=prod`, `SPRING_LIFECYCLE_TIMEOUT_PER_SHUTDOWN_PHASE=30s`, `DB_URL=jdbc:postgresql://db:5432/${POSTGRES_DB}`, `DB_POOL_SIZE=${DB_POOL_SIZE:-5}`; healthcheck curl `:8081/actuator/health` (30s/10s/3, start 90s); `edge`+`data`; `mem_limit ${APP_MEM_LIMIT:-512m}`; watchtower enabled |
| `db` postgres:17-alpine | `127.0.0.1:${POSTGRES_HOST_PORT:-5432}:5432`; `POSTGRES_PASSWORD` `:?`-guarded; `max_connections=50`, `shared_buffers=128MB`; healthcheck; `data`; `mem_limit 384m`; watchtower disabled |
| `watchtower` containrrr/watchtower:1.7.1 | `DOCKER_API_VERSION=1.44`, `WATCHTOWER_LABEL_ENABLE`, `WATCHTOWER_ROLLING_RESTART`, `WATCHTOWER_CLEANUP`, `WATCHTOWER_TIMEOUT=60s`, poll `${WATCHTOWER_POLL_INTERVAL:-60}`; docker.sock ro; optional `${DOCKER_CONFIG_DIR:-~/.docker}/config.json` for private GHCR; `mem_limit 48m` |
| `backup` | `build: ./backup`, `pull_policy: build`; env `POSTGRES_*`, `BACKUP_INTERVAL_SECONDS` (86400), `BACKUP_RETENTION_DAYS` (14); volume `${BACKUP_DIR:-./backups}:/backups`; `data`; watchtower disabled |
| `alloy` grafana/alloy | profile `observability`; `deploy/alloy/config.alloy`; env `GRAFANA_CLOUD_PROM_URL/USER/TOKEN` (no `:?`, compose interpolates inactive profiles), `APP_METRICS_HOST=app`, `APP_METRICS_PORT=8081`, `APP_ENV=prod`; volume `alloy_data`; `edge`; `mem_limit 128m` |

Liquibase runs at boot in every replica; its `DATABASECHANGELOGLOCK` serialises them. Docs state
the expand/contract rule: a migration must work with the previous release's code.

### `deploy/Caddyfile`

`email {$ACME_EMAIL}`; site `{$DOMAIN}`: `encode zstd gzip`; `@actuator path /actuator*` → 404;
`reverse_proxy { dynamic a { name app port 8080 refresh 5s } fail_duration 10s max_fails 1
unhealthy_status 5xx lb_policy round_robin lb_try_duration 5s lb_try_interval 250ms transport http {
dial_timeout 2s response_header_timeout 60s } }`; headers HSTS, nosniff, `X-Frame-Options SAMEORIGIN`,
Referrer-Policy, `-Server`; json log to stdout.

### `deploy/backup/`

`Dockerfile`: alpine + `postgresql17-client` + `tzdata`, copies `backup.sh`. `backup.sh`: loop,
`pg_dump -Fc` to `/backups/<UTC stamp>.dump`, prune older than retention only after a successful dump,
`once` argument for manual runs. Restore documented: `pg_restore -c -d $POSTGRES_DB file.dump` via
`docker compose exec -T db`.

### Scripts and Makefile (prod side)

`scripts/init-prod-env.sh`: run on the VPS from the repo root. Refuses if `deploy/.env.prod` exists
(unless `--force`); prints a banner naming the target path and that it holds prod secrets; requires
typing `yes`. Writes `.env.prod` from `deploy/.env.prod.example` with `POSTGRES_PASSWORD=$(openssl rand
-hex 24)`, `APP_IMAGE=ghcr.io/<owner>/<repo>` and `COMPOSE_PROJECT_NAME=<repo>` derived from `git remote
get-url origin` (lowercased), `chmod 600`. Prints the values still to fill (`DOMAIN`, `ACME_EMAIL`,
optionally Grafana Cloud). Why: prod DB never runs with `app/app`; the secret is generated where it is
used and never leaves the host.

Makefile `PROD := docker compose -f deploy/compose.prod.yml --env-file deploy/.env.prod`. Targets:
`prod-init`, `prod-up` (`config -q` first, then `up -d --remove-orphans --wait`), `prod-down`,
`prod-ps`, `prod-logs`, `prod-pull`, `prod-backup-now`, `prod-restore FILE=`, `prod-rollback TAG=`
(stops watchtower, sets `APP_IMAGE_TAG`, recreates app, prints how to resume watchtower).

## Section 3 — Observability

### App

- Deps: `micrometer-registry-prometheus`.
- `application.yml`: `management.server.port: ${MANAGEMENT_PORT:${SERVER_PORT:8080}}`; exposure
  `health,info,prometheus,metrics`; `metrics.tags.application=${APP_NAME}`, `env=${APP_ENV:local}`;
  `distribution.slo.http.server.requests: 100ms,250ms,500ms,1s,2s,5s`; `info.app.version=${APP_VERSION:local}`,
  `info.app.revision=${APP_REVISION:dev}`.
- `config/BuildInfoMetrics`: `Gauge app.build.info{version,revision} = 1` (rendered
  `app_build_info`).
- `controller/VersionController`: `GET /version` → `{"version":"...","revision":"..."}`.
- `application-prod.yml`: disable springdoc, `show-details: when-authorized`.

### `deploy/alloy/config.alloy`

`discovery.dns` on `APP_METRICS_HOST` (default `app`), port `APP_METRICS_PORT` (default 8081), A
records, refresh 15s → `prometheus.scrape` path `/actuator/prometheus` every 30s →
`prometheus.remote_write` to `GRAFANA_CLOUD_PROM_URL` with basic auth from env; `external_labels
env=APP_ENV`. Identical file for local and prod.

### `deploy/grafana/`

- `provisioning/datasources.yml`: Prometheus uid `grafanacloud-prom`, url `http://prometheus:9090`.
- `provisioning/dashboards.yml`: file provider on `/var/lib/grafana/dashboards`, `allowUiUpdates: true`.
- `dashboards/app-overview.json`: uid `app-overview`, template var `env` (label values of
  `app_build_info`), annotation `changes(app_build_info{env="$env"}[2m]) > 0` with version text. Rows:
  Overview (version stat, instances up, uptime), HTTP (rps, 5xx %, p50/p95/p99, slowest URIs), JVM
  (heap, GC pause, threads, CPU), DB (Hikari active/idle/pending, acquire time), Logs
  (`logback_events_total` by level), Resilience4j (state).
- `alerting/contact-point.json` (Telegram, placeholders substituted by the push script),
  `alerting/notification-policy.json`, `alerting/rules.json` (folder `app`, group `app-baseline`):
  ServiceDown (`up == 0` or NoData, 3m), HighErrorRate (5xx > 5% over 10m with ≥ 20 req, 5m),
  HikariPending (`hikaricp_connections_pending > 0` for 5m), HeapHigh (> 90% of max for 10m).

### `scripts/grafana-push.sh {local|cloud} [--alerting] | pull`

`local`: `http://localhost:3000`, no auth. `cloud`: `GRAFANA_URL`, `GRAFANA_API_TOKEN` from env or
`.env`. Dashboards: ensure folder `App`, `POST /api/dashboards/db` with `overwrite: true`. Alerting
(only when `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` are set, else prints skip notice): contact
point, notification policy, rule group via `/api/v1/provisioning/*` with `X-Disable-Provenance: true`.
`pull`: `GET /api/dashboards/uid/app-overview` from local, strips `id`/`version`, writes the JSON back.

### Test

`DashboardJsonTest` (unit): parses every file under `deploy/grafana`, asserts valid JSON, datasource
uid `grafanacloud-prom` everywhere, every `expr` mentions at least one metric from a known-name list
(`app_build_info`, `http_server_requests_seconds_*`, `jvm_*`, `hikaricp_*`, `logback_events_total`,
`process_*`, `system_*`, `up`, `resilience4j_*`).

## Section 4 — Local scripts and Claude skills

### `scripts/vps.sh <cmd>`

Config from env/`.env`: `VPS_SSH` (`user@host` or ssh alias, required), `VPS_APP_DIR` (default
`~/<repo>`), `VPS_DB_LOCAL_PORT` (default 15432). Commands:

- `ssh` — interactive shell in `VPS_APP_DIR`.
- `env` — prints `deploy/.env.prod` from the VPS with secret values masked (`KEY=****`).
- `tunnel` — `ssh -N -L <local>:127.0.0.1:<POSTGRES_HOST_PORT>` in the foreground until Ctrl-C.
- `psql [sql]` — opens the tunnel in the background, reads `POSTGRES_*` from the remote `.env.prod`,
  runs `psql` interactively or with `-c "<sql>"`, closes the tunnel. Requires local `psql`; falls back
  to `docker run --rm -it --network host postgres:17-alpine psql`.
- `datagrip` — opens the tunnel in the background (prints PID and how to stop), fetches creds, prints
  `jdbc:postgresql://localhost:<port>/<db>?user=<u>&password=<p>` and copies it to the clipboard
  (`wl-copy`/`xclip`/`pbcopy` if present). DataGrip: New → Data Source from URL → paste.
- `logs [service]`, `ps`, `deploy-status` (running image tags per replica + `/version`).

Secrets never land on disk locally; they are read over SSH per invocation.

### `.claude/skills/`

- `vps-db/SKILL.md`: when to use (user asks to query/inspect prod DB, check what's deployed, tail
  prod logs), how (`scripts/vps.sh`), rules: read-only by default, `psql` with mutating SQL only when
  the user asked for that exact change, never paste secrets into chat, prefer `env` (masked) over `cat`.
- `grafana/SKILL.md`: pushing/pulling dashboards, when to use `local` vs `cloud`, the
  `DashboardJsonTest` guard, alerting gating.
- `release/SKILL.md`: commit format, how the version is derived, `make release-name` (prints next
  version), how to force major, how to roll back (`make prod-rollback TAG=`).

### `scripts/rename-package.sh <new.package> <app-name>`

Fast "make it yours": moves `src/{main,test}/java` trees, rewrites `package`/`import`/string
references, `group`, `rootProject.name`, `APP_NAME` defaults, Spotless/ArchUnit package literals,
compose `APP_NAME`. Refuses on a dirty git tree. Prints the follow-up (`make build`).

## Section 5 — Application code hardening

- `build.gradle.kts`: add `spring-boot-liquibase`, `micrometer-registry-prometheus`; pin
  `palantirJavaFormat("2.97.0")`; remove unused Resilience4j retry config from yml (retry is not
  applied to Feign; README must not claim it).
- `GlobalExceptionHandler`: replace `RestClientException` with `FeignException` → 502 with a generic
  detail (no upstream message); add `NoResourceFoundException` → 404, `HttpRequestMethodNotSupportedException`
  → 405, `ServletRequestBindingException`/`MethodArgumentTypeMismatchException`/`HttpMessageNotReadableException`
  → 400, all logged at DEBUG/WARN without stack traces; keep `Exception` → 500 with ERROR.
- `BaseConfig` → `@EnableScheduling`, `@EnableAsync`, `Clock` bean (`Clock.systemUTC()`).
- `JobLoggingAspect`: drop `@SneakyThrows`, declare `throws Throwable`.
- New `utils/SecretRedactor` (bearer/basic auth, `password`, `token`, `secret`, `key` JSON/form fields,
  `truncate`), `config/RedactingFeignLogger` (`Slf4jLogger` subclass, DEBUG-only, redacts), and
  `config/RequestResponseLoggingFilter` (DEBUG-only, 4 KB cap, skips `/actuator`, `/swagger-ui`,
  `/v3/api-docs`, `/version`).
- `TestcontainersConfiguration`: add `SyncTaskExecutor` bean named `applicationTaskExecutor`.
- `SpringContextIntegrationTest`: constructor injection.
- `ArchitectureTest`: add optional `Job` layer (`..job..`, may access Service), `@Scheduled` only in
  `..job..`, no `System.out`/`java.util.logging`, exclude synthetic classes from naming rules.
- Remove empty scaffolding: `model/`, `utils/.gitkeep` (utils gets real classes), `mapper/.gitkeep`
  stays (MapStruct is a stated convention), `dto/request`, `dto/response` collapse to `dto/`.
- `application-dev.yml` removed (duplicated base). `application-test.yml` trimmed to what differs.
- `OpenApiConfig`: contact/licence read from `app.openapi.*` properties with empty defaults.
- `.gitignore`: add `!/CLAUDE.md`, `deploy/.env.prod`, `deploy/backups/`, remove `!build/libs/*.jar` from
  `.dockerignore` confusion by listing only what the image needs.

## Section 6 — Documentation

### README.md (rewrite, ~150 lines, no marketing)

1. What this is (3 lines) + stack table (only true claims).
2. Local: `make run`, URLs, `make observability-up` → Grafana at :3000 with the dashboard.
3. **Zero to prod checklist** — the table from the conversation (GitHub secrets/vars, GHCR
   visibility, VPS `.env.prod` values, DNS, local `.env` for skills, Grafana Cloud), each row with
   *why*. Then the 6 commands: clone on VPS → `make prod-init` → edit → `make prod-up` → set
   `PRODUCTION_URL` → push.
4. How a deploy works (one paragraph + the timeline table) and how to roll back.
5. Versioning: commit format table, what bumps what, how to force major.
6. Observability: what the dashboard shows, local vs cloud, alerting gating.
7. Testing: unit vs integration split, forks, Instancio, ArchUnit, coverage gate.
8. Make it yours: `scripts/rename-package.sh`.
9. Docs index → `docs/deployment.md`, `docs/observability.md`, `docs/superpowers/specs/`.

### `docs/deployment.md`

Runbook: VPS prerequisites (Docker, git, open 80/443, swap), first bring-up, what Watchtower logs
look like when healthy, rollback, backup/restore, migration expand/contract rule, private GHCR login,
memory budget table, reading `deploy` job failures.

### `docs/observability.md`

Metrics path, Alloy, dashboard editing loop (edit locally → `make grafana-pull` → commit → CI pushes),
adding a metric checklist, alert rules, series budget note (Grafana Cloud free tier 10k).

### CLAUDE.md (root, committed)

Sections: what the project is (one line, placeholder for the derived project); commands with
expected runtimes; hosting model (one Hetzner VPS, compose in `deploy/`, Watchtower pulls
`ghcr.io/<repo>:latest`, push to main = deploy in ~6 min, rollback command); versioning + commit
format (conventional, when to use `!`); prod DB access (`scripts/vps.sh psql`, read-only default;
`vps-db` skill); observability (dashboard file is source of truth, CI pushes, `DashboardJsonTest`);
conventions (Liquibase owns schema, constructor injection, ArchUnit, `${ENV:default}` idiom,
`@Slf4j` only, Instancio fixtures); test layout (unit vs `integration/**`); invariants
(`spring-boot-liquibase` required on Boot 4, `DOCKER_API_VERSION=1.44` for Watchtower, `MANAGEMENT_PORT`
never published/proxied).

## Testing strategy for this change

- Bash scripts: `scripts/tests/*.test.sh` (plain bash asserts, temp git repos, stub `curl` via PATH
  for `grafana-push.sh`), run by `make test-scripts` and in CI `build`.
- Java: unit tests for `SecretRedactor`, `GlobalExceptionHandler` (WebMvcTest), `BuildInfoMetrics`,
  `DashboardJsonTest`; integration tests for `/version` and context load.
- Compose/Caddy: `docker compose -f deploy/compose.prod.yml --env-file <fixture> config -q` in CI
  `build` with a fixture env to validate interpolation; `caddy validate` via `caddy:2-alpine` image.
- Workflows: zizmor in `security-fast`; `actionlint` locally via `make lint-workflows` (optional).
- Manual verification before completion: `make build`, `make observability-up` + `make run` +
  dashboard shows `local` version, `make image` + `docker run` answers `/version`, `make prod-up` against
  a local fixture `.env.prod` with `DOMAIN=localhost` is not possible (ACME) → validated via `config`
  only; documented.
