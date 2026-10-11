# Bricks

Optional infrastructure, one folder each. A brick is inert until its name is in `.bricks`; `make add BRICK=<name>`
wires it in, `make remove BRICK=<name>` takes it out without residue, `make bricks` lists them. Read
`bricks/<name>/README.md` before using or changing a brick; read this file before writing one.

| Brick | One line |
|---|---|
| `observability` | Alloy → Grafana Cloud in prod, Prometheus + Grafana locally, one dashboard, Telegram alerts |
| `backup` | pg_dump every 6 h to any rclone remote, with status, list and restore |
| `minio` | S3-compatible object storage with an `ObjectStorageService`, locally and in prod |

## Anatomy — presence wires it

| File in `bricks/<name>/` | Effect of `add` |
|---|---|
| `README.md` (required) | Nothing. First line `# <name>: <one line>` is what `make bricks` prints. Sections: Use it, Operate it, Invariants, Tests, Change it. |
| `compose.yml` | `include:` entry in root `compose.yml` (`# brick:<name>` marker). Paths inside are relative to the brick folder. |
| `compose.prod.yml` | `include:` entry in `deploy/compose.prod.yml`. |
| `env.example` / `env.prod.example` | Block appended to `.env.example` / `deploy/.env.prod.example` between `# --- brick:<name> ---` and `# --- /brick:<name> ---`. An empty `X_PASSWORD=` line is filled by `make prod-init`. |
| `Makefile` | Included by the root Makefile while enabled (nothing is copied). Start with `# --- brick: <name>`; use `##` help comments; may use `PROD`, `ENV_FILE`, `SERVICE`. |
| `brick.gradle.kts` | Applied to the service build while enabled; `add`/`remove` refresh `services/app/gradle.lockfile`. Use `"implementation"("…")` (string-invoked; no type-safe accessors). |
| `java/main/**`, `java/test/**` | Copied under `services/app/src/{main,test}/java/<package>/…`; `__PKG__` → the service package. Spotless runs on add when the brick has `java/`. |
| `resources/main/**`, `resources/test/**` | Copied under `services/app/src/{main,test}/resources/`. |
| `skill/SKILL.md` | Copied to `.claude/skills/<name>/SKILL.md`; `remove` deletes that folder. |
| `tests/*.test.sh` | Run by `make test-scripts` always. Test the brick's own scripts in isolation (`BRICKS=<name>` on make). |
| anything else | Stays put; reference it from the brick's compose files by relative path. |

`scripts/brick.sh` is the source of truth; `add` is idempotent and never commits.

## Rules

1. Self-contained: declare every network and volume you use, even ones the core declares (compose merges same-name
   declarations). Never `depends_on` another brick; share through declared volumes.
2. Prod services: `mem_limit`, the json-file logging block (anchors do not cross files), label
   `com.centurylinklabs.watchtower.enable: "false"`. State the memory in the README.
3. Extending `app` or `db`: a partial service with `environment`, `depends_on`, `volumes` only. Never `image`,
   `ports`, `networks` of a core service.
4. `:?` guards are right in brick prod files: an enabled brick is on.
5. Spring settings through `@ConfigurationProperties` records with `@DefaultValue`, bound from `APP_<BRICK>_*` env
   by relaxed binding. Never edit `application.yml`.
6. Grafana assets live in `observability`; another brick documents the panel or alert it wants.
7. `add` twice = `add` once; `remove` leaves `git status` clean. Ship at least one test.

## Authoring checklist

1. `mkdir bricks/<name>`; write `README.md` first (what, why, how, env, memory, invariants).
2. Compose fragments; `docker compose -f bricks/<name>/compose.prod.yml config` must not be needed — the all-bricks
   render in `scripts/tests/deploy-config.test.sh` validates it; extend that test's service list.
3. Env blocks, Makefile, Gradle, Java with `__PKG__`, skill, tests.
4. Add the name to the `bricks` matrix in `.github/workflows/ci.yml` (`scripts/tests/brick.test.sh` checks this).
5. `make add BRICK=<name> && make build && make test-scripts && make remove BRICK=<name> && git status --porcelain`
   (empty).
