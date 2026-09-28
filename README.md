# spring-template

Spring Boot service template for a solo project that ships to one VPS. Clone, rename, push: CI publishes a versioned
image, the server pulls it and rolls the replicas, Grafana shows the release. Local run needs no configuration.

| Concern | Choice |
|---|---|
| Runtime | Java 25, Spring Boot 4.1, Gradle 9.6 (Kotlin DSL) |
| Data | PostgreSQL 17, Spring Data JPA, Liquibase owns the schema (`ddl-auto: validate`) |
| HTTP clients | OpenFeign wrapped in a Resilience4j circuit breaker, redacted request logging |
| API | RFC 9457 `ProblemDetail` errors, springdoc Swagger UI (`/swagger-ui.html`, off in prod) |
| Caching | Spring Cache with Caffeine |
| Tests | JUnit 5, Testcontainers (one Postgres per fork), Instancio, ArchUnit, JaCoCo gate 60 % |
| Ops | `/version`, actuator on a private management port, `app_build_info` metric, graceful shutdown |
| Delivery | GitHub Actions → GHCR + GitHub Release → Watchtower rolling restart behind Caddy |
| Observability | Micrometer → Grafana Alloy → Grafana Cloud (prod) / Prometheus + Grafana (local) |
| Hygiene | Spotless, Dependabot, gitleaks, trivy, zizmor, conventional commits, SemVer from history |

## Local

```bash
make run              # starts Postgres from compose.yml, runs the app on :8080
make observability-up # Prometheus + Grafana (http://localhost:3000) + Alloy scraping the app
make test             # unit tests, no Docker
make itest            # integration tests, Testcontainers
make help             # everything else
```

`make run` uses the defaults in `.env.example`; create `.env` only to override them. Port 5432 taken?
`DB_PORT=15433 make run`.

Endpoints: `/version`, `/actuator/health`, `/actuator/prometheus`, `/swagger-ui.html`.

## Zero to production

One VPS (Hetzner CX or CAX both work: images are amd64 + arm64), Docker installed, ports 80/443 open, a domain.

| Where | Set | Why |
|---|---|---|
| DNS | `A` record → VPS IP | Caddy obtains the Let's Encrypt certificate for it |
| VPS `deploy/.env.prod` | `DOMAIN`, `ACME_EMAIL` (`POSTGRES_PASSWORD`, `APP_IMAGE`, `COMPOSE_PROJECT_NAME` are generated) | TLS, database, which image Watchtower follows |
| VPS `deploy/.env.prod` (optional) | `COMPOSE_PROFILES=observability`, `GRAFANA_CLOUD_PROM_URL/USER/TOKEN` | Alloy pushes metrics to Grafana Cloud |
| VPS `deploy/.env.prod` (recommended) | `COMPOSE_PROFILES=backup`, `RCLONE_REMOTE`; `deploy/backup/rclone.conf` | Off-host database backups ([§6](docs/deployment.md)); without it there are none |
| GitHub → Packages | GHCR package **public**, or `docker login ghcr.io` on the VPS and set `DOCKER_CONFIG_FILE` | Watchtower must be able to pull |
| GitHub → Variables | `PRODUCTION_URL=https://your.domain` | CI waits for the VPS to serve the new revision and records a Deployment |
| GitHub → Secrets (optional) | `GRAFANA_URL`, `GRAFANA_API_TOKEN` | CI pushes `deploy/grafana/**` to Grafana Cloud on merge |
| GitHub → Secrets (optional) | `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` | Alert rules get pushed; weekly security failures notify you |
| Grafana Cloud | stack → Prometheus → *Send metrics* (URL, instance id, token `metrics:write`); service account token `dashboards:write` | The two blocks above |
| Local `.env` (optional) | `VPS_SSH=user@host`, `GRAFANA_URL`, `GRAFANA_API_TOKEN` | `make vps-*` and `make grafana-push-cloud` from your machine |

On the VPS:

```bash
git clone https://github.com/<owner>/<repo>.git && cd <repo>
make prod-init                 # writes deploy/.env.prod: generated DB password, image name from the git remote
$EDITOR deploy/.env.prod       # DOMAIN, ACME_EMAIL, optional Grafana Cloud block
make prod-up                   # validates the env, starts Caddy + 2 app replicas + Postgres + Watchtower (+ backup, alloy by profile)
```

Then push to `main`. Nothing on the VPS is touched again.

## How a deploy works

```
git push main ─► ci: build+tests ‖ gitleaks+trivy+zizmor ─► image (amd64+arm64) ─► tag vX.Y.Z + Release
                                                                     │
                                          Watchtower polls GHCR ◄────┘   every 60 s
                                                  │
                     stop replica 1 (graceful) ─► start new ─► replica 2 ─► /version shows the new revision
```

| Stage | Typical time |
|---|---|
| build + tests, security in parallel | 3 min |
| multi-arch image from the prebuilt jar | 1 min |
| Watchtower poll + rolling restart | 1–2 min |
| push → live | **≈ 5–6 min** |

Watchtower waits for each new replica's health check before stopping the next one, and Caddy re-resolves the `app`
service name every 5 s and retries only connection-level failures, so a rolling restart is invisible to clients. Postgres and the management port are never reachable from the internet.

Rollback on the VPS: `make prod-rollback TAG=1.4.1` (every GitHub Release lists its tag and this command).
Details, first-time host setup, backups and the migration rule: [docs/deployment.md](docs/deployment.md).

## Versioning

Commit subjects follow Conventional Commits; `make setup` (run automatically by `make run`/`test`/`build`) installs a
hook that rejects anything else, and CI checks again.

| Subject | Release |
|---|---|
| `fix: …`, `perf: …`, `refactor|docs|test|build|ci|chore|style|revert: …` | patch |
| `feat: …` | minor |
| `feat!: …` or a `BREAKING CHANGE:` footer | major |

`make release-name` prints the version the next push would produce. Image tags: `latest`, `X.Y.Z`, `X.Y`,
`sha-<short>`. The Release notes list every commit since the previous tag.

## Observability

One dashboard, `deploy/grafana/dashboards/app-overview.json`, renders locally and in Grafana Cloud: running version
and deploy markers (from `app_build_info`), HTTP rate/errors/latency, JVM, Hikari, log levels, circuit breakers.
Edit it in the local Grafana, `make grafana-pull`, commit; CI pushes it to Grafana Cloud. Alerts (service down,
5xx > 5 %, DB connections pending, heap > 90 %) are pushed only when the Telegram secrets exist.
[docs/observability.md](docs/observability.md).

## Testing

- `src/test/java/**/unit/**` and everything outside `integration/`: no Docker, classes run concurrently.
- `src/test/java/**/integration/**`: extend `AbstractIntegrationTest`; each Gradle fork boots its own context and
  its own Postgres container, so forks never share a database.
- Test data with Instancio (`support.Fixtures`); architecture rules in `ArchitectureTest`; `DashboardJsonTest` keeps
  the Grafana JSON honest; `scripts/tests/*.test.sh` cover the bash tooling (`make test-scripts`).

## Make it yours

```bash
make rename PKG=com.acme.shop APP=shop   # moves the package, renames the app, one reviewable diff
make build
```

Then add the first Liquibase changeset under `src/main/resources/db/changelog/changes/` and go.

## Docs

| | |
|---|---|
| [docs/deployment.md](docs/deployment.md) | host setup, rollback, backups/restore, migration rule, memory budget, reading a failed deploy |
| [docs/observability.md](docs/observability.md) | metrics path, dashboard loop, alerts, adding a metric |
| [CLAUDE.md](CLAUDE.md) | what Claude needs to know to work in this repo |
| `docs/superpowers/specs/` | design records |

MIT — see [LICENSE](LICENSE).
