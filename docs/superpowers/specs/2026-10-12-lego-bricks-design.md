# Lego bricks: nested service, add-on-demand infrastructure

Date: 2026-10-12. Status: approved for planning (brainstormed with the user; remaining rulings made autonomously
during an overnight run and listed in §10).

## 1. Intent

The template exists so a new pet project reaches business logic on day one with production delivery, security
checks and operations already in place. Today everything optional (backups, Alloy, Grafana, dashboards, alerts) is
checked in next to the core, gated by compose profiles, documented in four places and wired through 18 production
make targets. A new project carries all of it whether it wants it or not, and an agent working in the repo has to
read all of it to find the piece it needs.

What the user asked for, in their words: a lego. "Want to add some component and you got it." Core is Postgres plus
one Spring service. Everything else — Grafana, MinIO, backups, later Debezium or Kafka — is a brick that is added on
demand, lives in one folder, and is understood by reading that folder. Services sit nested so other things can sit
beside them at the root. The agent must be able to add a brick, work inside a brick, or author a new one without
getting lost.

Success looks like:

- `git clone`, `make rename`, `make add BRICK=minio`, write code, push: live in ≈ 5 minutes with MinIO running
  locally and in production.
- Reading `bricks/<name>/README.md` is enough to use, operate or change that brick.
- `make build` on a project with no bricks never touches brick code; CI on the template still verifies every brick.
- Root `CLAUDE.md`, `README.md` and `Makefile` get shorter, not longer.

Out of scope for this change (§11 lists them as follow-ups): a second-service generator, blue-green deploys, new
bricks beyond the three below.

## 2. Model chosen: add-on-demand (B)

Three models were weighed. **Present-but-off** (everything checked in, profiles toggle it) is today's pattern and the
source of the clutter. **Recipe-only** (a skill tells the agent how to generate a brick) is lightest but untested and
drifts. **Add-on-demand** keeps every brick checked in under `bricks/<name>/`, inert until enabled; enabling wires it
in with one command and is reversible. The user chose B.

A brick is inert when disabled: nothing under `bricks/<name>/` is compiled, started, or read by Gradle, compose or
Spring until it appears in `.bricks`. A brick is complete when enabled: compose services, env blocks, Java code,
dependencies, make targets, skill and docs all come from that one folder.

## 3. Repository layout after the change

```
.bricks                      enabled bricks, one per line; empty in the template
bricks/
  README.md                  the brick contract: anatomy, rules, authoring checklist (agent-facing)
  observability/             Alloy, Prometheus+Grafana (local), dashboard, alert rules, Telegram contact point
  backup/                    pg_dump → rclone sidecar, status/list/restore
  minio/                     S3-compatible object storage + S3Client, ObjectStorageService, health indicator
services/
  README.md                  how to add a second service by hand (follow-up generator, §11)
  app/                       the Spring service: build.gradle.kts, gradle.lockfile, Dockerfile, src/
deploy/
  compose.prod.yml           caddy, app, db, watchtower — nothing else
  Caddyfile, .env.prod.example
scripts/                     brick.sh, rename-package.sh, vps.sh, init-prod-env.sh, next-version.sh, lint-commits.sh
compose.yml                  db (+ app under profile full); bricks are `include:`d
build.gradle.kts             plugin versions (apply false) + Spotless for every *.gradle.kts
settings.gradle.kts          includes every directory under services/ as a Gradle project
```

`.claude/skills/` keeps `release`, `vps-db` and gains `bricks`. Brick-specific skills (today's `grafana`) move into
their brick and are installed on `add`.

## 4. Nested service

- `settings.gradle.kts` discovers `services/*/build.gradle.kts` and includes each as `:<dirname>`; project dir is
  the service folder. `services/app` becomes `:app`.
- Root `build.gradle.kts` declares the Boot, dependency-management and Spotless plugin versions with `apply false`
  and configures Spotless `kotlinGradle` for `*.gradle.kts`, `services/*/*.gradle.kts` and `bricks/*/*.gradle.kts`.
  No dependencies at the root; no root lockfile.
- `services/app/build.gradle.kts` is today's build file minus plugin versions, plus the brick hook (§5.4) and
  `tasks.bootRun { workingDir = rootDir }` so Spring's docker-compose support finds `compose.yml`. Tests receive
  `systemProperty("repo.root", rootDir)` for tests that read repository files.
- `services/app/Dockerfile` copies `services/app/build/libs/app.jar`; build context stays the repository root
  (`.dockerignore` allows only that path). `compose.yml` and CI pass `dockerfile: services/app/Dockerfile`.
- Images keep their names: `ghcr.io/<owner>/<repo>` is the `app` service. A second service would publish
  `ghcr.io/<owner>/<repo>/<name>` (documented in `services/README.md`, not built now).
- Makefile: Gradle targets address `:app` (`SERVICE ?= app`); `build`, `format`, `check` stay root-wide.
- Dependabot: gradle directory `/services/app`; docker `/services/app` and `/bricks/*`; docker-compose `/`,
  `/deploy`, `/bricks/*`.
- Trivy `skip-dirs`: `**/build,**/.gradle`.
- `rename-package.sh` learns the new paths (`services/app/src/{main,test}/java`, `group` in
  `services/app/build.gradle.kts`) and excludes `bricks/` (bricks carry `__PKG__`, resolved at add time).

## 5. The brick contract (`bricks/README.md` is the normative copy)

### 5.1 Anatomy

Every file is optional except `README.md`. Presence of a file is what wires it; there is no manifest.

| Path in `bricks/<name>/` | What `brick.sh add` does with it |
|---|---|
| `README.md` | Nothing. The one document for the brick: what, why, local use, production use, env, invariants, verification, how to change it. |
| `compose.yml` | Adds `  - bricks/<name>/compose.yml  # brick:<name>` under `include:` in root `compose.yml`. |
| `compose.prod.yml` | Adds `  - ../bricks/<name>/compose.prod.yml  # brick:<name>` under `include:` in `deploy/compose.prod.yml`. |
| `env.example` | Appends the block to `.env.example` between `# --- brick:<name> ---` and `# --- /brick:<name> ---`. |
| `env.prod.example` | Same, into `deploy/.env.prod.example`. |
| `Makefile` | Nothing to copy: root Makefile does `-include $(foreach b,$(BRICKS),bricks/$(b)/Makefile)` where `BRICKS` is read from `.bricks`. Targets use `##` help comments like the root. |
| `brick.gradle.kts` | Nothing to copy: the service build applies it for every enabled brick (§5.4). Runs `make lock` after add/remove. |
| `java/main/**/*.java`, `java/test/**/*.java` | Copied into `services/app/src/{main,test}/java/<pkg path>/...` with `__PKG__` replaced by the service base package (read from `group` in the service build file). Then `spotlessApply`. |
| `resources/main/**`, `resources/test/**` | Copied verbatim into `services/app/src/{main,test}/resources/`. |
| `skill/SKILL.md` | Copied to `.claude/skills/<name>/SKILL.md`. |
| `tests/*.test.sh` | Nothing to copy: `scripts/tests/run.sh` runs `scripts/tests/*.test.sh` and `bricks/*/tests/*.test.sh` always, enabled or not. They test the brick's own scripts in isolation. |
| anything else (`Dockerfile`, `backup.sh`, `alloy/`, `grafana/`) | Stays in place; the brick's compose files reference it by brick-relative path (compose `include` resolves paths against the included file's directory — verified with Compose v5). |

Spring configuration: brick Java code reads settings through `@ConfigurationProperties` records with
`@DefaultValue` defaults, bound from environment variables by relaxed binding (`APP_MINIO_ENDPOINT` →
`app.minio.endpoint`). Bricks never edit `application.yml`. The brick README lists its variables.

### 5.2 Rules

1. Self-contained: a brick's compose file declares every network and volume it uses, even ones the core also
   declares (`data`, `backup_metrics`). Compose merges same-named declarations; an undeclared reference fails.
   Cross-brick coupling goes through declared shared volumes, never through `depends_on` on another brick.
2. Every prod compose service in a brick carries `mem_limit`, the json-file logging block (YAML anchors do not
   cross files, so the core's `*default-logging` cannot be referenced; repeat the three lines) and the label
   `com.centurylinklabs.watchtower.enable: "false"` unless the brick is meant to be rolled by Watchtower.
   A brick may extend a core service (`app`, `db`) with a partial definition — `environment:`, `depends_on:`,
   `volumes:` — and never redefines `image`, `ports` or `networks` of a core service.
3. `:?` guards are allowed in brick prod files: an enabled brick is on, there is no profile to be off.
4. Memory: every prod service's `mem_limit` is listed in the brick README; `deploy/compose.prod.yml`'s header keeps
   the core budget only.
5. Grafana assets live in the `observability` brick. Another brick that wants a panel or alert documents it in its
   README; no automatic merge.
6. Everything a brick adds must be removable by `brick.sh remove` with no residue, and `add` twice equals `add` once.
7. A brick ships at least one test: a bash test for its scripts, a unit or integration test for its Java, or both.

### 5.3 `scripts/brick.sh` (`make add BRICK=x`, `make remove BRICK=x`, `make bricks`)

- `list`: every directory under `bricks/` with `[x]`/`[ ]` and the README's first line.
- `add <name>`: refuses an unknown name; no-op with a message when already enabled; otherwise applies §5.1 in the
  order compose → env → java/resources → skill → `.bricks`, then `./gradlew :app:dependencies --write-locks -q`
  when `brick.gradle.kts` exists and `./gradlew spotlessApply -q` when Java was copied. Prints what changed and the
  README path. Never commits.
- `remove <name>`: reverse of add, computed from the brick directory (no state besides `.bricks`): drops include
  lines and marker blocks, deletes the copied files, removes the skill dir, removes the line from `.bricks`, refreshes
  the lockfile. Refuses when the brick is not enabled.
- Idempotent edits use the `# brick:<name>` line marker (include lists) and the `# --- brick:<name> ---` block
  markers (env files). An `include:` key is inserted at the top of the compose file when missing and removed when
  it becomes empty.
- Tested by `scripts/tests/brick.test.sh` against a fixture repository in a temp dir: add, add again, remove, remove
  again, unknown brick, package substitution, include insertion/removal, marker blocks, `.bricks` contents.

### 5.4 Gradle hook (in `services/app/build.gradle.kts`)

```kotlin
// Bricks (bricks/README.md): each enabled brick may contribute dependencies through bricks/<name>/brick.gradle.kts.
rootProject.file(".bricks").takeIf { it.isFile }?.readLines()
    ?.map { it.substringBefore('#').trim() }?.filter { it.isNotEmpty() }
    ?.forEach { brick ->
        rootProject.file("bricks/$brick/brick.gradle.kts").takeIf { it.isFile }?.let { apply(from = it) }
    }
```

Inside `brick.gradle.kts` dependencies are declared as `dependencies { "implementation"("…") }` (string-invoked
configurations: applied scripts have no type-safe accessors). BOM imports go through `dependencyManagement`.

## 6. The three bricks

### 6.1 `observability` (extracted; today's profile `observability` plus `deploy/grafana`, `deploy/alloy`, `deploy/prometheus`, `scripts/grafana-push.sh`, the `grafana` skill, `docs/observability.md`, `DashboardJsonTest`)

- `compose.yml`: prometheus, grafana, alloy under profile `observability` (so `make run` does not start them).
- `compose.prod.yml`: alloy on `edge`, mounts `backup_metrics:/metrics/backup:ro` and declares that volume.
- `env.example`: `GRAFANA_PORT`, `PROMETHEUS_PORT`, `ALLOY_PORT`, personal `GRAFANA_URL`, `GRAFANA_API_TOKEN`,
  `TELEGRAM_*`. `env.prod.example`: `GRAFANA_CLOUD_PROM_*`.
- `Makefile`: `observability-up/down`, `grafana-push`, `grafana-push-cloud`, `grafana-pull`.
- `grafana-push.sh` moves here with its test; `.github/workflows/dashboards.yml` stays (workflows cannot be
  fragmented) and points at `bricks/observability/grafana/**`.
- `java/test/unit/DashboardJsonTest.java` resolves `bricks/observability/grafana` from `repo.root`.
- `README.md` absorbs `docs/observability.md` and the CLAUDE.md observability section; `skill/SKILL.md` is today's
  `grafana` skill with updated paths.
- `BuildInfoMetrics` and `/actuator/prometheus` stay in core: metrics exist without a collector.

### 6.2 `backup` (extracted; today's profile `backup`, `deploy/backup/`, backup make targets, `docs/deployment.md` §6, `BackupStale` invariants)

- `compose.prod.yml`: the backup service, declares `data`, `backup_lock`, `backup_metrics`. No local compose.
- `env.prod.example`: `RCLONE_REMOTE`, `RCLONE_CONFIG_DIR` (default `./rclone`: compose resolves bind sources in an
  included file against that file's directory, so this is `bricks/backup/rclone`), `BACKUP_*`.
- `Makefile`: `prod-backup-now/status/list`, `prod-restore`, `vps-backup-status`.
- `backup.sh`, `Dockerfile`, `rclone/.gitignore` move here; `backup.test.sh` and `make-backup.test.sh` move to
  `bricks/backup/tests/`.
- `README.md` absorbs deployment.md §6 (setup, restore, undo, new host) and the invariants (rclone directory
  mount, `BackupStale` ≥ `BACKUP_MAX_AGE_HOURS` ≥ 2 × cron interval).
- `vps.sh deploy-status` stops reporting backup freshness unconditionally: it reports it only when `bricks/backup`
  is enabled on the VPS checkout (`.bricks` contains `backup`), else prints "backup brick: off".

### 6.3 `minio` (new; proves the Java side of the contract)

- `compose.yml`: `minio` un-profiled (so `make run` starts it), ports `127.0.0.1:9000/9001`, healthcheck, volume.
- `compose.prod.yml`: `minio` on `data`, `mem_limit: 256m`, volume `minio_data`, healthcheck, no published ports,
  `MINIO_ROOT_PASSWORD:?`. The brick also carries a partial `app:` service holding only `environment:`
  (`APP_MINIO_*`) and `depends_on: minio: service_healthy`; compose merges it into the core `app` (verified on
  Compose v5: a partial service in an included file extends the parent's service of the same name). Both compose
  files of the brick do this.
- `env.example`: `MINIO_ROOT_USER/PASSWORD` (`minioadmin`), `APP_MINIO_BUCKET`. `env.prod.example`: the same with
  an empty password that `init-prod-env.sh` fills (§7).
- `brick.gradle.kts`: `software.amazon.awssdk:s3` via the AWS SDK BOM (works against MinIO and Hetzner Object
  Storage alike), `org.testcontainers:minio` for tests.
- Java (`__PKG__`): `config/MinioProperties` (endpoint, accessKey, secretKey, bucket, region; defaults for local),
  `config/MinioConfig` (`S3Client` bean, path-style, creates the bucket when missing),
  `service/ObjectStorageService` (`put`, `get`, `delete`, `presignedGetUrl`), `config/MinioHealthIndicator`
  (bucket reachable). Tests: `unit/ObjectStorageServiceTest` (mocked `S3Client`),
  `integration/ObjectStorageIntegrationTest` (Testcontainers `MinIOContainer` registered by a
  `MinioTestcontainersConfiguration` the test `@Import`s; round-trip put → get → presigned URL → delete).
- `README.md`: variables, local console URL, mem budget, "presigned URLs carry the internal endpoint; expose MinIO
  through Caddy yourself if clients must fetch directly", how to swap to Hetzner Object Storage (change endpoint and
  credentials, remove the compose service).

## 7. Core changes outside bricks

- `scripts/init-prod-env.sh`: besides `POSTGRES_PASSWORD`, every `^[A-Z_]*PASSWORD=$` line in the example gets its
  own `openssl rand -hex 24`. Test updated.
- `Makefile`: reads `BRICKS` from `.bricks`, `-include`s brick Makefiles, gains `add`, `remove`, `bricks`; loses
  observability, grafana and backup targets; `prod-rollback` stays (core). Help output groups brick targets after
  core ones (brick Makefiles put a `# --- brick: <name>` divider line that `help` prints).
- `compose.yml`, `deploy/compose.prod.yml`: core services only; header comments explain `include:` and point at
  `bricks/README.md`. Memory-budget comment lists core only.
- `deploy/.env.prod.example`, `.env.example`: core blocks only.
- `.github/workflows/ci.yml`: `build` job paths (`services/app/build/...`), `image` job `file:`; new job
  `bricks` (matrix from `ls bricks/`, not a gate for `image`): checkout, `scripts/brick.sh add ${brick}`,
  `./gradlew build`, `make test-scripts`, `docker compose --env-file .env.example config -q` and the prod render
  that `deploy-config.test.sh` already performs with a filled example env. `security-weekly.yml` unchanged apart
  from paths. `dashboards.yml` paths.
- `scripts/tests/run.sh` also runs `bricks/*/tests/*.test.sh`. `deploy-config.test.sh` learns the include layout.
- `README.md`: Concern table unchanged; "Zero to production" table drops the backup and Grafana rows and gains one
  row "Bricks: `make add BRICK=…`, then that brick's README"; new short "Bricks" section with the three bricks and
  the one-line command; Observability section shrinks to a pointer. "Docs" table drops `docs/observability.md`.
- `CLAUDE.md`: new "Bricks" section (what `.bricks` is, `make add/remove/bricks`, "read `bricks/<name>/README.md`
  before touching a brick; `bricks/README.md` before authoring one"); observability and backup prose and
  invariants move to brick READMEs; conventions gain "nested service at `services/app`; Gradle project `:app`".
- `docs/deployment.md`: §6 replaced by a pointer to `bricks/backup/README.md`; paths updated; memory budget
  references brick READMEs for brick services. `docs/observability.md` deleted.
- `.claude/skills/bricks/SKILL.md`: when to add a brick, the commands, the anatomy table in short, authoring
  checklist, "verify with `make build` and `make test-scripts` after add and after remove".
- Memory-budget invariant and the three deploy invariants in CLAUDE.md remain in CLAUDE.md (core).

## 8. Error handling

- `brick.sh` fails fast with a one-line reason: unknown brick, not enabled (remove), dirty markers (a block start
  without end), missing `group` in the service build file, Gradle lock failure (leaves files in place and says
  `make lock` to retry).
- Compose: a brick that references an undeclared resource fails at `docker compose config`, which `make prod-up`
  already runs first and the CI `bricks` job runs for every brick.
- Gradle: a missing `brick.gradle.kts` for an enabled brick is fine (no deps); a missing brick directory listed in
  `.bricks` fails the build with "brick X listed in .bricks does not exist".

## 9. Testing

- Unit: `brick.test.sh` (fixture repo), `init-prod-env.test.sh` (password generation for every `*PASSWORD=`),
  `rename-package.test.sh` (new paths, bricks excluded), `deploy-config.test.sh` (core compose renders with no
  bricks; renders with every brick added; `:?` guards still fire), `vps.test.sh` (deploy-status with backup
  on/off), each brick's own tests.
- Java: existing tests move with the service; `DashboardJsonTest` moves into the observability brick; minio brick
  ships unit and integration tests. `ArchitectureTest` keeps passing with brick classes present (they follow the
  layer rules).
- CI: `build` (no bricks) stays the gate for `image`; `bricks` matrix verifies each brick on a clean checkout.
- Local acceptance before the branch is handed over: `make build` with `.bricks` empty; then for each brick
  `make add BRICK=x && make build && make test-scripts && docker compose config -q && make remove BRICK=x` leaves
  `git status` clean: the lockfile is regenerated on both add and remove, so a round trip restores it.

## 10. Rulings made while the user slept

| Question | Ruling | Why |
|---|---|---|
| Nest the single service now? | Yes, `services/app`, Gradle auto-discovery | User asked for nested services with other things beside them; doing it later would touch every path twice. |
| Second-service generator in v1? | No; `services/README.md` recipe | Needs Caddy routing, CI matrix and image naming decisions worth their own brainstorm; bricks were the stated priority. |
| Bricks enabled in the template by default? | None | User: "by default only postgres and one spring microservice". CI's `bricks` job keeps them from rotting. |
| Compose mechanism | `include:` | Verified: cross-file references, merged same-name resources, brick-relative paths, `--env-file` interpolation and `:?` guards all work on Compose v5. Multiple `-f` would break brick-relative paths. |
| Spring config for bricks | `@ConfigurationProperties` + `@DefaultValue`, env relaxed binding | Avoids editing `application.yml`; removable without residue. |
| Brick Gradle file name | `brick.gradle.kts` | Gradle only treats `*.gradle.kts` as Kotlin DSL. |
| Enabled list location | `.bricks` at the root | One line per brick, readable by Make, Gradle and bash alike. |
| Object storage client | AWS SDK v2 S3 | Same code works for MinIO and Hetzner Object Storage. |
| Blue-green / canary | Not in this change | Neither this repo nor submissions-checker has it; both use Watchtower rolling restart behind Caddy, which already gives zero-downtime deploys. A `bluegreen` brick is a candidate (§11). |
| CodeQL / SAST | Not added | Standing user preference. |

## 11. Follow-ups (not in this change)

- `make add SERVICE=<name>`: copy `services/app`, suffix the package, add compose service, Caddy path route, CI
  matrix entry, image `ghcr.io/<owner>/<repo>/<name>`.
- Candidate bricks the user named or that the sibling projects use: `redis`, `kafka` (+ `debezium`), `mail`,
  `bluegreen` (two app stacks and a Caddy switch), `hetzner-object-storage` (minio brick's README covers the swap).
- Post-deploy smoke test in the `deploy` job (hit one business endpoint, not only `/version`).
