# Lego Bricks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Nest the Spring service under `services/app` and turn every optional piece of infrastructure into a self-contained brick under `bricks/<name>/` that `make add BRICK=<name>` wires in and `make remove` takes out without residue.

**Architecture:** Gradle becomes a multi-project build that auto-discovers `services/*`. A brick is a folder whose files are wired by presence: compose fragments through compose `include:`, env blocks through marker-delimited appends, Java through copy-with-package-substitution, dependencies through an applied `brick.gradle.kts`, make targets through `-include`. `.bricks` at the root is the single list of enabled bricks, read by Make, Gradle and `scripts/brick.sh`. Three bricks ship: `observability` and `backup` (extracted from today's profiles) and `minio` (new, proves the Java side).

**Tech Stack:** Bash (`set -euo pipefail`, tested by `scripts/tests/*.test.sh`), GNU Make, Gradle 9 Kotlin DSL, Spring Boot 4.1 / Java 25, Docker Compose v5 `include:`, AWS SDK v2 S3 client, Testcontainers MinIO, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-12-lego-bricks-design.md`

## Global Constraints

- Branch `feat/bricks`; never push; one conventional commit per task (`<type>(<scope>): <imperative>`, body says why; `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` last line). The commit-msg hook rejects anything else.
- `make build` (Spotless, unit, integration, JaCoCo ≥ 60 %) and `make test-scripts` must pass at the end of every task. Run them; read the output; only then claim.
- Every bash script: `#!/usr/bin/env bash`, `set -euo pipefail`, header comment that doubles as `--help`. Every script test: the `fail()` + `mktemp -d` + `trap` shape used by `scripts/tests/init-prod-env.test.sh`.
- `.bricks` is empty of bricks in the template (only its comment line). Nothing under `bricks/` is compiled, started or read unless listed there.
- A brick never edits `application.yml`; Java in a brick uses `@ConfigurationProperties` records with `@DefaultValue` and relaxed env binding. Brick Java files use `package __PKG__...;` and `import __PKG__...;`.
- Brick prod compose services carry `mem_limit`, the json-file logging block, and `com.centurylinklabs.watchtower.enable: "false"`. A brick may extend `app`/`db` with a partial service (`environment`, `depends_on`, `volumes`) and never sets their `image`, `ports` or `networks`.
- Images: `ghcr.io/<owner>/<repo>` stays the `app` service image. Compose project name, `APP_IMAGE`, `prod-init` behaviour unchanged except password generation (Task 6).
- Spotless formats Java (`palantirJavaFormat`) and every `*.gradle.kts` including `bricks/*/brick.gradle.kts`.
- Keep README true-claims-only; runbook detail lives in `docs/` or brick READMEs. No CodeQL.
- `git mv` for every move so history follows.

## Review Focus

1. `make add` run twice, or `make remove` of a brick that is off, must be a no-op with a message, never a duplicated include line or env block — pinned in Task 3's test (`add` twice, `remove` twice).
2. `.bricks` naming a brick directory that does not exist must fail the Gradle build with the name in the message, not silently skip — pinned in Task 2 (`settings`/build check) via `brick.test.sh` Gradle-stub assertion and a `make build` run in Task 2 Step 6.
3. A second brick appended to `.env.example` after a first, then the first removed, must leave exactly one blank line between remaining blocks and no stray markers — pinned in Task 3's test (`demo` + `demo2` ordering).
4. A prod compose render with every brick enabled and an empty env must still fail on `:?` guards (a brick must not weaken the core's guards and the core's guard must still fire with bricks included) — pinned in Task 5's `deploy-config.test.sh`.
5. A rename (`make rename`) after a brick has been added must rewrite the copied brick classes along with the rest of the service and must not touch `bricks/` — pinned in Task 1's `rename-package.test.sh` (a file under `bricks/` with `__PKG__` stays byte-identical; a copied `services/app/.../config/X.java` is moved).

---

### Task 1: Nest the service under `services/app` (Gradle multi-project)

**Files:**
- Move (git mv): `src/` → `services/app/src/`, `build.gradle.kts` → `services/app/build.gradle.kts`, `gradle.lockfile` → `services/app/gradle.lockfile`, `Dockerfile` → `services/app/Dockerfile`, `lombok.config` → `services/app/lombok.config`
- Create: `build.gradle.kts` (root), `services/README.md`
- Modify: `settings.gradle.kts`, `services/app/build.gradle.kts`, `services/app/Dockerfile`, `.dockerignore`, `compose.yml` (app build), `Makefile`, `.github/workflows/ci.yml`, `.github/workflows/security-weekly.yml`, `.github/dependabot.yml`, `scripts/rename-package.sh`, `scripts/tests/rename-package.test.sh`, `CLAUDE.md` (one line), `README.md` (paths)

**Interfaces:**
- Produces: Gradle project `:app` at `services/app`; jar at `services/app/build/libs/app.jar`; system property `repo.root` in every test JVM; `tasks.bootRun.workingDir = rootDir`; Makefile variable `SERVICE ?= app`.

- [ ] **Step 1: Move the service**

```bash
cd /home/vampir/petProjects/spring-template
mkdir -p services/app
git mv src services/app/src
git mv build.gradle.kts services/app/build.gradle.kts
git mv gradle.lockfile services/app/gradle.lockfile
git mv Dockerfile services/app/Dockerfile
git mv lombok.config services/app/lombok.config
```

(`lombok.config` is read per source root; it must sit next to the sources' project.)

- [ ] **Step 2: Root Gradle files**

`settings.gradle.kts`:

```kotlin
plugins {
    // Auto-download the JDK declared in the Java toolchain (see services/app/build.gradle.kts)
    id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0"
}

rootProject.name = "spring-template"

// Every directory under services/ that holds a build.gradle.kts is a Gradle project named after the directory:
// services/app → :app. Add a second service by adding a directory (services/README.md).
file("services")
    .listFiles { dir -> File(dir, "build.gradle.kts").isFile }
    ?.sortedBy { it.name }
    ?.forEach { dir ->
        include(dir.name)
        project(":${dir.name}").projectDir = dir
    }
```

Root `build.gradle.kts`:

```kotlin
// Root build: plugin versions for every service (applied per service) and formatting for every Gradle script.
// Services live under services/<name>/ and are discovered by settings.gradle.kts; bricks under bricks/<name>/ may
// contribute dependencies through brick.gradle.kts (bricks/README.md).
plugins {
    id("org.springframework.boot") version "4.1.0" apply false
    id("io.spring.dependency-management") version "1.1.7" apply false
    id("com.diffplug.spotless") version "7.2.1"
}

spotless {
    kotlinGradle {
        target("*.gradle.kts", "services/*/*.gradle.kts", "bricks/*/*.gradle.kts")
        ktlint()
    }
}
```

- [ ] **Step 3: Service build file edits** (`services/app/build.gradle.kts`)

Replace the plugins block with versionless ids:

```kotlin
plugins {
    id("java")
    id("jacoco")
    id("org.springframework.boot")
    id("io.spring.dependency-management")
    id("com.diffplug.spotless")
}
```

Delete the `kotlinGradle { … }` block inside `spotless { … }` (root owns it). After `tasks.withType<Test>().configureEach { … }` add inside that block:

```kotlin
    // Tests that read repository files (brick assets, docs) resolve them from here, not from the project dir.
    systemProperty("repo.root", rootDir.absolutePath)
```

After `tasks.bootJar { … }` add:

```kotlin
tasks.bootRun {
    // spring-boot-docker-compose looks for compose.yml in the working directory; it lives at the repository root.
    workingDir = rootDir
}
```

- [ ] **Step 4: Dockerfile, dockerignore, compose, Makefile, CI, Dependabot**

`services/app/Dockerfile`: change the COPY line to
`COPY --chown=spring:spring services/app/build/libs/app.jar application.jar` and the header comment's "Locally: `make image` runs bootJar first" stays. Context is the repository root.

`.dockerignore`:

```
# The image needs exactly one file. Everything else (sources, secrets, .git) never reaches the daemon.
*
!services/app/build/libs/app.jar
```

`compose.yml` `app` service: `build:` becomes

```yaml
    build:
      context: .
      dockerfile: services/app/Dockerfile
```

`Makefile`: after `PROD := …` add `SERVICE ?= app  # Gradle project under services/ that run/dev/lock address`. Change targets:

```make
run: setup ## Run the app (auto-starts the compose DB)
	./gradlew :$(SERVICE):bootRun

dev: ## Run with a throwaway Testcontainers DB (no docker-compose needed)
	./gradlew :$(SERVICE):bootTestRun

lock: ## Refresh services/<service>/gradle.lockfile after changing dependencies
	./gradlew :$(SERVICE):dependencies --write-locks -q

up: ## Build the jar + image and run app + db with $(ENV_FILE)
	./gradlew :$(SERVICE):bootJar -q
	docker compose --env-file $(ENV_FILE) --profile full up --build -d

image: ## Build the jar and the OCI image (tag: $(APP_NAME))
	./gradlew :$(SERVICE):bootJar -q
	docker build -f services/$(SERVICE)/Dockerfile -t $(APP_NAME) .
```

`test`, `itest`, `build`, `format`, `check`, `clean` stay root-wide (`./gradlew test` runs every project).

`.github/workflows/ci.yml`: `build` job artifact paths → `services/app/build/libs/app.jar` and `services/app/build/reports/tests/`, `services/app/build/reports/jacoco/`; `image` job download path → `services/app/build/libs/`; `build-push-action` gains `file: services/app/Dockerfile`; trivy step `skip-dirs: "**/build,**/.gradle"`. `security-weekly.yml`: same `skip-dirs`.

`.github/dependabot.yml`: gradle `directory: /services/app`; docker `directories: [/services/app]` (the backup entry moves in Task 5).

- [ ] **Step 5: rename script and its test**

`scripts/rename-package.sh`: the loop `for src in src/main/java src/test/java` becomes `for src in services/app/src/main/java services/app/src/test/java`; the grep gains `--exclude-dir=bricks`; the `sed -i -E "s#(APP_NAME:-?)…" compose.yml src/main/resources/application.yml` path becomes `services/app/src/main/resources/application.yml`; header comment mentions `services/app`.

`scripts/tests/rename-package.test.sh`: every `src/` path → `services/app/src/`, `build.gradle.kts` → `services/app/build.gradle.kts` (the `grep -rq "com.example.company"` list and the `group =` / coverage assertions). Insert **between** the `git archive … | tar -x` line and the snapshot commit (so both files are part of the snapshot):

```bash
# Bricks carry __PKG__ placeholders resolved by scripts/brick.sh at add time: rename must leave them alone, while a
# brick class already copied into the service is moved like any other class.
mkdir -p "$tmp/bricks/demo/java/main/config"
printf 'package __PKG__.config;\n\npublic class DemoConfig {}\n' > "$tmp/bricks/demo/java/main/config/DemoConfig.java"
printf 'package com.example.company.config;\n\npublic class CopiedBrickConfig {}\n' \
  > "$tmp/services/app/src/main/java/com/example/company/config/CopiedBrickConfig.java"
```

and after the existing `grep -q 'com/acme/shop/Application.class'` assertion:

```bash
[[ -f "$tmp/services/app/src/main/java/com/acme/shop/config/CopiedBrickConfig.java" ]] || fail "copied brick class not moved"
grep -q '^package __PKG__.config;' "$tmp/bricks/demo/java/main/config/DemoConfig.java" || fail "rename touched bricks/"
```

- [ ] **Step 6: Run everything**

```bash
make test-scripts 2>&1 | tail -20
make build 2>&1 | tail -20
docker compose --env-file .env.example --profile full config -q
```

Expected: all script tests pass, `BUILD SUCCESSFUL`, jar at `services/app/build/libs/app.jar`, compose validates. If `./gradlew build` complains about Spotless `kotlinGradle` on `services/app/build.gradle.kts`, run `make format` and re-run.

- [ ] **Step 7: Docs touch and `services/README.md`**

`services/README.md`:

```markdown
# services/

One Gradle project per directory; `settings.gradle.kts` includes every `services/<name>/build.gradle.kts` as
`:<name>`. `app` is the service the template ships and the one `deploy/compose.prod.yml`, the Caddyfile and CI
build.

## Adding a second service (by hand, until `make add SERVICE=` exists)

1. `cp -r services/app services/<name>`; change `group` in its `build.gradle.kts` to `<base package>.<name>` and
   move the sources to that package; delete what the new service does not need.
2. `compose.yml`: a second `app`-like service with `dockerfile: services/<name>/Dockerfile` and its own
   `SERVER_PORT`. `deploy/compose.prod.yml`: same, image `ghcr.io/<owner>/<repo>/<name>`, on `edge` + `data`.
3. `deploy/Caddyfile`: a `handle_path /<name>/*` block with its own `reverse_proxy` + `dynamic a { name <name> }`.
4. `.github/workflows/ci.yml`: a second entry in the `image` job (or a matrix) with `file: services/<name>/Dockerfile`
   and image `ghcr.io/<owner>/<repo>/<name>`; the Dockerfile's COPY path.
5. `make lock SERVICE=<name>`; `make run SERVICE=<name>`.
```

`CLAUDE.md` Conventions: first bullet becomes "Service code lives under `services/app` (Gradle project `:app`; `make run`/`dev`/`lock` take `SERVICE=`). Layers: …". `README.md`: "Make it yours" changeset path → `services/app/src/main/resources/db/changelog/changes/`; Testing section paths → `services/app/src/test/java/**`.

- [ ] **Step 8: Commit**

```bash
make format && git add -A && git commit -F - <<'EOF'
refactor(build): nest the service under services/app

Gradle becomes a multi-project build that discovers services/*; the root keeps plugin versions and formatting.
Other things (bricks, later more services) can now sit beside the service instead of inside it.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
```

---

### Task 2: `.bricks`, Makefile include, Gradle hook, test runner glob

**Files:**
- Create: `.bricks`, `bricks/README.md` (stub, finished in Task 9)
- Modify: `Makefile`, `services/app/build.gradle.kts`, `scripts/tests/run.sh`
- Test: `scripts/tests/bricks-wiring.test.sh`

**Interfaces:**
- Produces: `.bricks` format (one name per line, `#` comments, blank lines ignored); Make variable `BRICKS` (overridable on the command line: `make BRICKS=backup …`); Gradle applies `bricks/<b>/brick.gradle.kts` for each name and fails on a missing directory; `scripts/tests/run.sh` runs `bricks/*/tests/*.test.sh` too.

- [ ] **Step 1: Write the failing test** `scripts/tests/bricks-wiring.test.sh`

```bash
#!/usr/bin/env bash
# Exercises the .bricks wiring that is not scripts/brick.sh: the Makefile include, help output and the test runner.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bricks/demo/tests" "$tmp/scripts/tests"
cp "$root/Makefile" "$tmp/"
cp "$root/scripts/tests/run.sh" "$tmp/scripts/tests/"
printf '# comment\n\ndemo\n' > "$tmp/.bricks"
cat > "$tmp/bricks/demo/Makefile" <<'EOF'
demo-hello: ## Say hello from the demo brick
	@echo hello-from-demo
EOF
printf '#!/usr/bin/env bash\necho demo-test-ran\n' > "$tmp/bricks/demo/tests/demo.test.sh"
printf '#!/usr/bin/env bash\necho core-test-ran\n' > "$tmp/scripts/tests/core.test.sh"

# A brick listed in .bricks contributes make targets and appears in help.
out="$(make -s -C "$tmp" --no-print-directory demo-hello)"
[[ "$out" == "hello-from-demo" ]] || fail "brick target not included: $out"
make -s -C "$tmp" --no-print-directory help | grep -q 'demo-hello' || fail "brick target missing from help"

# Comments and blank lines in .bricks are ignored; an unlisted brick contributes nothing.
printf '# nothing enabled\n' > "$tmp/.bricks"
if make -s -C "$tmp" --no-print-directory demo-hello >/dev/null 2>&1; then fail "disabled brick still contributes targets"; fi
# The command line can override the list (brick tests rely on this).
out="$(make -s -C "$tmp" --no-print-directory BRICKS=demo demo-hello)"
[[ "$out" == "hello-from-demo" ]] || fail "BRICKS= override ignored"

# The test runner runs brick tests whether or not the brick is enabled.
out="$(bash "$tmp/scripts/tests/run.sh")"
grep -q 'core-test-ran' <<<"$out" || fail "core test not run"
grep -q 'demo-test-ran' <<<"$out" || fail "brick test not run"
echo "bricks-wiring: all passed"
```

- [ ] **Step 2: Run it to see it fail**

Run: `bash scripts/tests/bricks-wiring.test.sh`
Expected: `FAIL: brick target not included` (Makefile has no include yet).

- [ ] **Step 3: Implement**

`.bricks`:

```
# Enabled bricks, one per line. `make bricks` lists them, `make add BRICK=<name>` / `make remove BRICK=<name>`
# edit this file. See bricks/README.md.
```

`Makefile`: after the `PROD :=` line:

```make
# Enabled bricks (bricks/README.md): names from .bricks, comments and blanks dropped. Each enabled brick's Makefile
# is included at the bottom of this file, so its targets show up in `make help`.
BRICKS ?= $(shell sed -e 's/\#.*//' -e '/^[[:space:]]*$$/d' .bricks 2>/dev/null)
```

New section before the "production, from this machine" divider:

```make
# ------------------------------------------------------------------------------------------------------------ bricks

bricks: ## List bricks and whether each is enabled (.bricks)
	@scripts/brick.sh list

add: ## Enable a brick: make add BRICK=minio
	@test -n "$(BRICK)" || (echo "usage: make add BRICK=<name>   (make bricks lists them)" && exit 1)
	scripts/brick.sh add $(BRICK)

remove: ## Disable a brick and delete what it added: make remove BRICK=minio
	@test -n "$(BRICK)" || (echo "usage: make remove BRICK=<name>" && exit 1)
	scripts/brick.sh remove $(BRICK)
```

Add `bricks add remove` to `.PHONY`. Last lines of the Makefile:

```make
# Brick make targets (one Makefile per enabled brick; they may use PROD, ENV_FILE and SERVICE).
-include $(foreach b,$(BRICKS),bricks/$(b)/Makefile)
```

`scripts/tests/run.sh`:

```bash
#!/usr/bin/env bash
# Runs every scripts/tests/*.test.sh and bricks/*/tests/*.test.sh (enabled or not) and fails if any of them fails.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
status=0
for t in "$here"/*.test.sh "$root"/bricks/*/tests/*.test.sh; do
  [[ -f "$t" ]] || continue
  echo "--- ${t#"$root"/}"
  if ! bash "$t"; then status=1; fi
done
exit $status
```

`services/app/build.gradle.kts`, after the `dependencies { … }` block:

```kotlin
// Bricks (bricks/README.md): each enabled brick may contribute dependencies through bricks/<name>/brick.gradle.kts.
rootProject
    .file(".bricks")
    .takeIf { it.isFile }
    ?.readLines()
    ?.map { it.substringBefore('#').trim() }
    ?.filter { it.isNotEmpty() }
    ?.forEach { brick ->
        val dir = rootProject.file("bricks/$brick")
        require(dir.isDirectory) { "brick '$brick' is listed in .bricks but bricks/$brick does not exist" }
        File(dir, "brick.gradle.kts").takeIf { it.isFile }?.let { apply(from = it) }
    }
```

`bricks/README.md` stub (one line, finished in Task 9): `# Bricks\n\nOptional infrastructure, one folder each. Finished in Task 9.`

- [ ] **Step 4: Run the test and the build**

Run: `bash scripts/tests/bricks-wiring.test.sh && make test-scripts | tail -3`
Expected: `bricks-wiring: all passed`, runner exits 0.

Run: `printf 'ghost\n' >> .bricks && (./gradlew :app:help -q 2>&1 | grep -q "brick 'ghost' is listed" && echo OK-fails-loudly); git checkout .bricks`
Expected: `OK-fails-loudly`.

Run: `make build 2>&1 | tail -5` → `BUILD SUCCESSFUL`.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -F - <<'EOF'
feat(bricks): read enabled bricks from .bricks in Make, Gradle and the test runner

One file lists what is on. Make includes each enabled brick's targets, the service build applies each enabled
brick's dependencies, and script tests under bricks/*/tests run regardless so a disabled brick cannot rot.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
```

---

### Task 3: `scripts/brick.sh` — list, add, remove

**Files:**
- Create: `scripts/brick.sh`
- Test: `scripts/tests/brick.test.sh`

**Interfaces:**
- Produces: `scripts/brick.sh list|add <name>|remove <name>`; env `GRADLE` (default `./gradlew`) and `BRICK_SERVICE` (default `app`) overridable for tests; markers `# brick:<name>` (include lines) and `# --- brick:<name> ---` / `# --- /brick:<name> ---` (env blocks).

- [ ] **Step 1: Write the failing test** `scripts/tests/brick.test.sh`

```bash
#!/usr/bin/env bash
# Exercises scripts/brick.sh against a fixture repository: add, add again, remove, remove again, unknown brick,
# package substitution, include insertion/removal, env marker blocks, skill install, lockfile refresh.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
mkdir -p "$repo/scripts" "$repo/deploy" "$repo/services/app/src/main/java" "$repo/services/app/src/test/java" \
  "$repo/bricks/demo/java/main/config" "$repo/bricks/demo/java/test/unit" "$repo/bricks/demo/resources/main" \
  "$repo/bricks/demo/skill" "$repo/bricks/demo2" "$repo/.claude/skills"
cp "$root/scripts/brick.sh" "$repo/scripts/"
cat > "$repo/gradlew" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GRADLE_LOG"
EOF
chmod +x "$repo/gradlew"
export GRADLE_LOG="$tmp/gradle.log"
printf '# header comment\nservices:\n  db:\n    image: postgres\n' > "$repo/compose.yml"
printf 'name: ${COMPOSE_PROJECT_NAME:?}\nservices:\n  app:\n    image: x\n' > "$repo/deploy/compose.prod.yml"
printf '# Local defaults.\nAPP_NAME=x\n' > "$repo/.env.example"
printf 'DOMAIN=\n' > "$repo/deploy/.env.prod.example"
printf 'group = "com.acme.shop"\n' > "$repo/services/app/build.gradle.kts"
printf '# comment\n' > "$repo/.bricks"
# Brick "demo": everything a brick can carry.
printf '# demo: a brick with everything\n' > "$repo/bricks/demo/README.md"
printf 'services:\n  demo:\n    image: alpine\n' > "$repo/bricks/demo/compose.yml"
printf 'services:\n  demo:\n    image: alpine\n' > "$repo/bricks/demo/compose.prod.yml"
printf 'DEMO_PORT=1234\n' > "$repo/bricks/demo/env.example"
printf 'DEMO_SECRET=\n' > "$repo/bricks/demo/env.prod.example"
printf 'package __PKG__.config;\n\nimport __PKG__.utils.X;\n\npublic class DemoConfig {}\n' > "$repo/bricks/demo/java/main/config/DemoConfig.java"
printf 'package __PKG__.unit;\n\nclass DemoTest {}\n' > "$repo/bricks/demo/java/test/unit/DemoTest.java"
printf 'hello\n' > "$repo/bricks/demo/resources/main/demo.txt"
printf '---\nname: demo\n---\n' > "$repo/bricks/demo/skill/SKILL.md"
printf 'dependencies { "implementation"("x:y:1") }\n' > "$repo/bricks/demo/brick.gradle.kts"
# Brick "demo2": only an env block, to test ordering and removal in the middle.
printf '# demo2: env only\n' > "$repo/bricks/demo2/README.md"
printf 'DEMO2=1\n' > "$repo/bricks/demo2/env.example"

b() { (cd "$repo" && scripts/brick.sh "$@"); }

# Unknown brick / bad usage.
if b add nope >/dev/null 2>&1; then fail "unknown brick accepted"; fi
if b remove demo >/dev/null 2>&1; then fail "remove of a disabled brick exited 0"; fi
if b >/dev/null 2>&1; then fail "no command exited 0"; fi

# list shows every brick with its state and README first line.
out="$(b list)"
grep -q '\[ \] demo .*a brick with everything' <<<"$out" || fail "list line for demo wrong: $out"

# add wires everything.
: > "$GRADLE_LOG"
b add demo >/dev/null
grep -qx 'demo' "$repo/.bricks" || fail ".bricks not updated"
grep -q '^include:$' "$repo/compose.yml" || fail "include: key not inserted into compose.yml"
grep -q '^  - bricks/demo/compose.yml  # brick:demo$' "$repo/compose.yml" || fail "include line missing in compose.yml"
# The include block sits before the first top-level key, after the header comment.
[[ "$(grep -n -m1 -E '^(include|services):' "$repo/compose.yml" | cut -d: -f2)" == "include" ]] || fail "include: not before services:"
grep -q '^  - ../bricks/demo/compose.prod.yml  # brick:demo$' "$repo/deploy/compose.prod.yml" || fail "prod include line missing"
grep -q '^# --- brick:demo ---$' "$repo/.env.example" && grep -q '^DEMO_PORT=1234$' "$repo/.env.example" \
  && grep -q '^# --- /brick:demo ---$' "$repo/.env.example" || fail "env block not appended"
grep -q '^DEMO_SECRET=$' "$repo/deploy/.env.prod.example" || fail "prod env block not appended"
f="$repo/services/app/src/main/java/com/acme/shop/config/DemoConfig.java"
[[ -f "$f" ]] || fail "java not copied to the package path"
grep -q '^package com.acme.shop.config;' "$f" || fail "__PKG__ not substituted in package"
grep -q '^import com.acme.shop.utils.X;' "$f" || fail "__PKG__ not substituted in import"
[[ -f "$repo/services/app/src/test/java/com/acme/shop/unit/DemoTest.java" ]] || fail "test java not copied"
[[ -f "$repo/services/app/src/main/resources/demo.txt" ]] || fail "resources not copied"
[[ -f "$repo/.claude/skills/demo/SKILL.md" ]] || fail "skill not installed"
grep -q 'dependencies --write-locks' "$GRADLE_LOG" || fail "lockfile not refreshed after add"
grep -q 'spotlessApply' "$GRADLE_LOG" || fail "copied java not formatted"
out="$(b list)"; grep -q '\[x\] demo ' <<<"$out" || fail "list does not show demo enabled"

# add twice is a no-op.
snapshot="$(cd "$repo" && find . -type f -not -path './.git/*' -exec md5sum {} + | sort)"
b add demo >/dev/null
[[ "$snapshot" == "$(cd "$repo" && find . -type f -not -path './.git/*' -exec md5sum {} + | sort)" ]] || fail "second add changed files"
[[ "$(grep -c 'brick:demo' "$repo/compose.yml")" == 1 ]] || fail "include line duplicated"

# A second brick after the first; removing the first leaves the second intact with single blank lines.
b add demo2 >/dev/null
b remove demo >/dev/null
grep -q 'brick:demo2' "$repo/.env.example" || fail "demo2 block lost"
grep -q 'brick:demo ' "$repo/.env.example" && fail "demo markers left behind"
grep -q 'DEMO_PORT' "$repo/.env.example" && fail "demo block content left behind"
grep -Pzq '\n\n\n' "$repo/.env.example" && fail "double blank line left in .env.example"
[[ "$(tail -c1 "$repo/.env.example" | od -An -tx1 | tr -d ' \n')" == "0a" ]] || fail ".env.example lost its trailing newline"

# remove undoes everything else too.
grep -qx 'demo' "$repo/.bricks" && fail ".bricks still lists demo"
grep -q 'brick:demo$' "$repo/compose.yml" && fail "compose include line left"
grep -q '^include:' "$repo/compose.yml" && fail "empty include: key left in compose.yml"
grep -q 'brick:demo$' "$repo/deploy/compose.prod.yml" && fail "prod include line left"
[[ ! -e "$f" ]] || fail "copied java not deleted"
[[ ! -d "$repo/services/app/src/main/java/com/acme/shop/config" ]] || fail "empty package dir left behind"
[[ ! -e "$repo/services/app/src/main/resources/demo.txt" ]] || fail "copied resource not deleted"
[[ ! -d "$repo/.claude/skills/demo" ]] || fail "skill dir not removed"
[[ "$(grep -c 'dependencies --write-locks' "$GRADLE_LOG")" -ge 2 ]] || fail "lockfile not refreshed after remove"
if b remove demo >/dev/null 2>&1; then fail "second remove exited 0"; fi

# A brick without a gradle file never calls gradle for locking.
: > "$GRADLE_LOG"; b remove demo2 >/dev/null
grep -q 'write-locks' "$GRADLE_LOG" && fail "lock refreshed for a brick without brick.gradle.kts"
[[ "$(cat "$repo/.env.example")" == $'# Local defaults.\nAPP_NAME=x' ]] || fail ".env.example not restored: $(cat "$repo/.env.example")"

# Every brick directory is covered by the CI matrix (the list is static in ci.yml).
for d in "$root"/bricks/*/; do
  name="$(basename "$d")"
  grep -qE "^\s+brick: \[.*\b${name}\b.*\]" "$root/.github/workflows/ci.yml" || fail "ci.yml bricks matrix does not list ${name}"
done
echo "brick: all passed"
```

- [ ] **Step 2: Run it to see it fail**

Run: `bash scripts/tests/brick.test.sh`
Expected: `cp: cannot stat '…/scripts/brick.sh'` or the first `fail`. (The CI-matrix loop at the end runs only after Task 8 adds the matrix; until then no `bricks/*/` directory exists, so the loop is empty.)

- [ ] **Step 3: Implement** `scripts/brick.sh`

```bash
#!/usr/bin/env bash
# Add, remove and list bricks: self-contained optional infrastructure under bricks/<name>/ (bricks/README.md).
#
#   scripts/brick.sh list                 every brick, [x] when enabled, with its README's first line
#   scripts/brick.sh add <name>           wire the brick in and list it in .bricks
#   scripts/brick.sh remove <name>        undo add, leaving nothing behind
#
# A brick is wired by the files it contains (each optional):
#   compose.yml            include: entry in compose.yml                    marker:  # brick:<name>
#   compose.prod.yml       include: entry in deploy/compose.prod.yml
#   env.example            block appended to .env.example                   markers: # --- brick:<name> --- … # --- /brick:<name> ---
#   env.prod.example       block appended to deploy/.env.prod.example
#   java/{main,test}/**    copied under services/<svc>/src/{main,test}/java/<package>/, __PKG__ → service package
#   resources/{main,test}/** copied under services/<svc>/src/{main,test}/resources/
#   skill/SKILL.md         copied to .claude/skills/<name>/SKILL.md
#   brick.gradle.kts       applied by the service build for every name in .bricks; the lockfile is refreshed here
#   Makefile               included by the root Makefile for every name in .bricks; nothing to copy
# Both commands are idempotent and never commit. GRADLE (default ./gradlew) and BRICK_SERVICE (default app) can
# be overridden, which the tests use.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
service="${BRICK_SERVICE:-app}"
service_dir="services/${service}"
bricks_file=".bricks"
gradle="${GRADLE:-./gradlew}"

usage() { sed -n '2,19p' "$0" >&2; exit 2; }
die() { echo "brick: $*" >&2; exit 1; }

enabled() { [[ -f "$bricks_file" ]] && grep -qx "$1" "$bricks_file"; }
service_package() {
  local pkg
  pkg="$(sed -n 's/^group = "\(.*\)"$/\1/p' "$service_dir/build.gradle.kts")"
  [[ -n "$pkg" ]] || die "cannot read 'group = \"…\"' from $service_dir/build.gradle.kts"
  printf '%s' "$pkg"
}

# --- compose include lines ------------------------------------------------------------------------------------------
include_add() { # file, include path, brick
  local file="$1" path="$2" b="$3" line
  line="  - ${path}  # brick:${b}"
  grep -q "# brick:${b}\$" "$file" && return 0
  if grep -q '^include:' "$file"; then
    awk -v l="$line" '{ print } /^include:/ { print l }' "$file" > "$file.tmp"
  else
    # New key goes before the first top-level key, after the header comments.
    awk -v l="$line" 'BEGIN { done = 0 } !done && /^[A-Za-z]/ { print "include:"; print l; done = 1 } { print }' "$file" > "$file.tmp"
  fi
  mv "$file.tmp" "$file"
  echo "  ~ $file: include ${path}"
}
include_remove() { # file, brick
  local file="$1" b="$2"
  grep -q "# brick:${b}\$" "$file" || return 0
  sed -i "/# brick:${b}\$/d" "$file"
  # Drop the key when no entry is left under it.
  if ! sed -n '/^include:/{n;p}' "$file" | grep -q '^  - '; then sed -i '/^include:$/d' "$file"; fi
  echo "  ~ $file: include removed"
}

# --- env marker blocks ----------------------------------------------------------------------------------------------
block_add() { # file, source block, brick
  local file="$1" src="$2" b="$3"
  grep -q "^# --- brick:${b} ---\$" "$file" && return 0
  { printf '\n# --- brick:%s ---\n' "$b"; cat "$src"; printf '# --- /brick:%s ---\n' "$b"; } >> "$file"
  echo "  ~ $file: block appended"
}
block_remove() { # file, brick
  local file="$1" b="$2"
  grep -q "^# --- brick:${b} ---\$" "$file" || return 0
  grep -q "^# --- /brick:${b} ---\$" "$file" || die "$file: block for '${b}' has no end marker; fix it by hand"
  sed -i "/^# --- brick:${b} ---\$/,/^# --- \/brick:${b} ---\$/d" "$file"
  # Squeeze the blank line that preceded the block; keep exactly one trailing newline.
  printf '%s\n' "$(cat -s "$file")" > "$file.tmp" && mv "$file.tmp" "$file"
  echo "  ~ $file: block removed"
}

# --- java / resources -----------------------------------------------------------------------------------------------
# Walks bricks/<b>/<kind>/<set> and calls "$4 <src file> <dst file>" for every file.
each_file() { # brick, kind (java|resources), set (main|test), callback
  local b="$1" kind="$2" set="$3" cb="$4" src dst f rel
  src="bricks/${b}/${kind}/${set}"
  [[ -d "$src" ]] || return 0
  if [[ "$kind" == java ]]; then dst="$service_dir/src/${set}/java/$(service_package | tr . /)"; else dst="$service_dir/src/${set}/resources"; fi
  while IFS= read -r -d '' f; do
    rel="${f#"$src"/}"
    "$cb" "$f" "$dst/$rel"
  done < <(find "$src" -type f -print0 | sort -z)
}
copy_one() { # src, dst
  local pkg; pkg="$(service_package)"
  mkdir -p "$(dirname "$2")"
  sed "s/__PKG__/${pkg}/g" "$1" > "$2"
  echo "  + $2"
}
delete_one() { # src, dst
  [[ -e "$2" ]] || return 0
  rm -f "$2"; echo "  - $2"
  # Prune directories the brick left empty, up to the source root.
  local d; d="$(dirname "$2")"
  while [[ "$d" == "$service_dir"/src/* ]] && rmdir "$d" 2>/dev/null; do d="$(dirname "$d")"; done
}
has_java() { [[ -d "bricks/$1/java" ]]; }

refresh_lock() { "$gradle" ":${service}:dependencies" --write-locks -q && echo "  ~ $service_dir/gradle.lockfile refreshed"; }
format_java() { "$gradle" ":${service}:spotlessApply" -q && echo "  ~ copied Java formatted"; }

# --- commands -------------------------------------------------------------------------------------------------------
cmd_list() {
  local d b mark desc
  for d in bricks/*/; do
    b="$(basename "$d")"
    mark=" "; enabled "$b" && mark="x"
    desc="$(sed -n '1s/^#[[:space:]]*//p' "$d/README.md" 2>/dev/null || true)"
    printf '  [%s] %-14s %s\n' "$mark" "$b" "$desc"
  done
}

cmd_add() {
  local b="$1"
  [[ -d "bricks/$b" ]] || die "unknown brick '$b' (make bricks lists them)"
  if enabled "$b"; then echo "brick '$b' is already enabled; nothing to do"; return 0; fi
  echo "Adding brick '$b':"
  [[ -f "bricks/$b/compose.yml" ]] && include_add compose.yml "bricks/$b/compose.yml" "$b"
  [[ -f "bricks/$b/compose.prod.yml" ]] && include_add deploy/compose.prod.yml "../bricks/$b/compose.prod.yml" "$b"
  [[ -f "bricks/$b/env.example" ]] && block_add .env.example "bricks/$b/env.example" "$b"
  [[ -f "bricks/$b/env.prod.example" ]] && block_add deploy/.env.prod.example "bricks/$b/env.prod.example" "$b"
  each_file "$b" java main copy_one; each_file "$b" java test copy_one
  each_file "$b" resources main copy_one; each_file "$b" resources test copy_one
  if [[ -f "bricks/$b/skill/SKILL.md" ]]; then mkdir -p ".claude/skills/$b"; cp "bricks/$b/skill/SKILL.md" ".claude/skills/$b/SKILL.md"; echo "  + .claude/skills/$b/SKILL.md"; fi
  echo "$b" >> "$bricks_file"; echo "  ~ $bricks_file: + $b"
  [[ -f "bricks/$b/brick.gradle.kts" ]] && refresh_lock
  has_java "$b" && format_java
  echo "Enabled '$b'. Read bricks/$b/README.md, then: make build && make test-scripts"
}

cmd_remove() {
  local b="$1"
  [[ -d "bricks/$b" ]] || die "unknown brick '$b' (make bricks lists them)"
  enabled "$b" || die "brick '$b' is not enabled"
  echo "Removing brick '$b':"
  include_remove compose.yml "$b"
  include_remove deploy/compose.prod.yml "$b"
  block_remove .env.example "$b"
  block_remove deploy/.env.prod.example "$b"
  each_file "$b" java main delete_one; each_file "$b" java test delete_one
  each_file "$b" resources main delete_one; each_file "$b" resources test delete_one
  if [[ -f "bricks/$b/skill/SKILL.md" ]]; then rm -rf ".claude/skills/$b"; echo "  - .claude/skills/$b/"; fi
  sed -i "/^${b}\$/d" "$bricks_file"; echo "  ~ $bricks_file: - $b"
  [[ -f "bricks/$b/brick.gradle.kts" ]] && refresh_lock
  echo "Disabled '$b'. Then: make build && make test-scripts"
}

cmd="${1:-}"; name="${2:-}"
case "$cmd" in
  list) cmd_list ;;
  add) [[ -n "$name" ]] || usage; cmd_add "$name" ;;
  remove) [[ -n "$name" ]] || usage; cmd_remove "$name" ;;
  *) usage ;;
esac
```

Make it executable: `chmod +x scripts/brick.sh`.

Notes for the implementer: `[[ -f … ]] && fn` lines are the last command of their line and return non-zero when the file is absent — under `set -e` that is fine for `&&` lists, but a function whose *last* statement is such a list returns non-zero; `cmd_add` ends with `echo`, so it is safe. `grep -q … && return 0` inside functions with `set -e`: `&&` lists do not trigger `-e`. If `shellcheck` is installed, run `shellcheck scripts/brick.sh` and fix what it reports.

- [ ] **Step 4: Run the test**

Run: `bash scripts/tests/brick.test.sh`
Expected: `brick: all passed`. Then `make test-scripts | tail -3` → exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/brick.sh scripts/tests/brick.test.sh && git commit -F - <<'EOF'
feat(bricks): add scripts/brick.sh to wire a brick in or out

Presence of a file in bricks/<name>/ decides what gets wired: compose include lines, env marker blocks, Java copied
into the service package, a skill, the lockfile. Both directions are idempotent so a repeated command is harmless.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
```

---

### Task 4: Extract the `observability` brick

**Files:**
- Move (git mv): `deploy/grafana` → `bricks/observability/grafana`, `deploy/alloy` → `bricks/observability/alloy`, `deploy/prometheus` → `bricks/observability/prometheus`, `scripts/grafana-push.sh` → `bricks/observability/grafana-push.sh`, `scripts/tests/grafana-push.test.sh` → `bricks/observability/tests/grafana-push.test.sh`, `.claude/skills/grafana/SKILL.md` → `bricks/observability/skill/SKILL.md`, `services/app/src/test/java/com/example/company/unit/DashboardJsonTest.java` → `bricks/observability/java/test/unit/DashboardJsonTest.java`, `docs/observability.md` → `bricks/observability/README.md`
- Create: `bricks/observability/compose.yml`, `bricks/observability/compose.prod.yml`, `bricks/observability/env.example`, `bricks/observability/env.prod.example`, `bricks/observability/Makefile`
- Modify: `compose.yml`, `deploy/compose.prod.yml`, `.env.example`, `deploy/.env.prod.example`, `Makefile`, `.github/workflows/dashboards.yml`, `scripts/tests/deploy-config.test.sh` (observability parts; the full rewrite happens in Task 5), `scripts/tests/vps.test.sh` only if it references grafana (it does not)

**Interfaces:**
- Consumes: `scripts/brick.sh`, `repo.root` system property.
- Produces: brick `observability`; volume `backup_metrics` declared in its prod compose; make targets `observability-up/down`, `grafana-push`, `grafana-push-cloud`, `grafana-pull`.

- [ ] **Step 1: Move files**

```bash
mkdir -p bricks/observability/tests bricks/observability/skill bricks/observability/java/test/unit
git mv deploy/grafana bricks/observability/grafana
git mv deploy/alloy bricks/observability/alloy
git mv deploy/prometheus bricks/observability/prometheus
git mv scripts/grafana-push.sh bricks/observability/grafana-push.sh
git mv scripts/tests/grafana-push.test.sh bricks/observability/tests/grafana-push.test.sh
git mv .claude/skills/grafana/SKILL.md bricks/observability/skill/SKILL.md
git mv services/app/src/test/java/com/example/company/unit/DashboardJsonTest.java bricks/observability/java/test/unit/DashboardJsonTest.java
git mv docs/observability.md bricks/observability/README.md
```

- [ ] **Step 2: Brick compose files** (cut the three services out of `compose.yml` and `alloy` out of `deploy/compose.prod.yml`; paths become brick-relative)

`bricks/observability/compose.yml`:

```yaml
# observability brick, local: Prometheus + Grafana + Alloy under profile `observability` (make observability-up).
# Same push path as production: Alloy scrapes /actuator/prometheus and remote-writes, here into a throwaway
# Prometheus instead of Grafana Cloud. The dashboard JSON and the Alloy config are the production files.
services:
  prometheus:
    profiles: ["observability"]
    image: prom/prometheus:v3.1.0
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --web.enable-remote-write-receiver
      - --storage.tsdb.retention.time=24h
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
    ports:
      - "127.0.0.1:${PROMETHEUS_PORT:-9090}:9090"

  grafana:
    profiles: ["observability"]
    image: grafana/grafana:11.5.1
    environment:
      GF_AUTH_ANONYMOUS_ENABLED: "true"
      GF_AUTH_ANONYMOUS_ORG_ROLE: Admin
      GF_AUTH_DISABLE_LOGIN_FORM: "true"
      GF_USERS_DEFAULT_THEME: dark
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/var/lib/grafana/dashboards:ro
    ports:
      - "127.0.0.1:${GRAFANA_PORT:-3000}:3000"
    depends_on:
      - prometheus

  alloy:
    profiles: ["observability"]
    image: grafana/alloy:v1.10.0
    command:
      - run
      - --server.http.listen-addr=0.0.0.0:12345
      - --storage.path=/var/lib/alloy/data
      - /etc/alloy/config.alloy
    volumes:
      - ./alloy/config.alloy:/etc/alloy/config.alloy:ro
      - alloy-data:/var/lib/alloy/data
    environment:
      GRAFANA_CLOUD_PROM_URL: http://prometheus:9090/api/v1/write
      GRAFANA_CLOUD_PROM_USER: local
      GRAFANA_CLOUD_PROM_TOKEN: local
      # The app normally runs on the HOST (`make run`); host-gateway is how a container reaches it on Linux, and a
      # static target is used because /etc/hosts aliases are invisible to DNS discovery (see config.alloy).
      APP_METRICS_STATIC_TARGET: host.docker.internal:${APP_METRICS_PORT:-8080}
      APP_METRICS_HOST: alloy
      APP_ENV: local
    extra_hosts:
      - "host.docker.internal:host-gateway"
    ports:
      - "127.0.0.1:${ALLOY_PORT:-12345}:12345"
    depends_on:
      - prometheus

volumes:
  alloy-data:
```

`bricks/observability/compose.prod.yml` (copy today's `alloy` service; add the three-line logging block instead of the anchor; declare what it uses):

```yaml
# observability brick, production: Alloy scrapes every app replica's /actuator/prometheus and remote-writes to
# Grafana Cloud (GRAFANA_CLOUD_PROM_* in deploy/.env.prod). Memory: 128m. Dashboards and alerts are pushed by CI
# from bricks/observability/grafana (README.md).
services:
  alloy:
    image: grafana/alloy:v1.10.0
    restart: unless-stopped
    command:
      - run
      - --server.http.listen-addr=0.0.0.0:12345
      - --storage.path=/var/lib/alloy/data
      - /etc/alloy/config.alloy
    volumes:
      - ./alloy/config.alloy:/etc/alloy/config.alloy:ro
      - alloy_data:/var/lib/alloy/data
      # The backup brick's backup.prom (empty when that brick is off; the volume is declared by both bricks).
      - backup_metrics:/metrics/backup:ro
    environment:
      GRAFANA_CLOUD_PROM_URL: ${GRAFANA_CLOUD_PROM_URL:?set GRAFANA_CLOUD_PROM_URL in deploy/.env.prod (bricks/observability/README.md)}
      GRAFANA_CLOUD_PROM_USER: ${GRAFANA_CLOUD_PROM_USER:?set GRAFANA_CLOUD_PROM_USER in deploy/.env.prod}
      GRAFANA_CLOUD_PROM_TOKEN: ${GRAFANA_CLOUD_PROM_TOKEN:?set GRAFANA_CLOUD_PROM_TOKEN in deploy/.env.prod}
      # Docker's embedded DNS answers `app` with every replica's address.
      APP_METRICS_HOST: app
      APP_METRICS_PORT: "8081"
      APP_ENV: ${APP_ENV:-prod}
    networks: [edge]
    mem_limit: 128m
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    labels:
      com.centurylinklabs.watchtower.enable: "false"

networks:
  edge:

volumes:
  alloy_data:
  backup_metrics:
```

Remove `prometheus`, `grafana`, `alloy` and the `alloy-data` volume from root `compose.yml`; remove `alloy`, `alloy_data` from `deploy/compose.prod.yml` (keep `backup_metrics` out too: Task 5 moves `backup`). Update both headers: `compose.yml` header loses the `make observability-up` line and gains "Bricks add their services through `include:` (bricks/README.md)". `deploy/compose.prod.yml` memory-budget comment becomes "caddy 64m + app 2×512m + db 384m + watchtower 48m ≈ 1.5 GB; every brick's README states what it adds".

- [ ] **Step 3: env blocks and Makefile**

`bricks/observability/env.example`:

```
# --- Local observability stack (`make observability-up`) ---
GRAFANA_PORT=3000
PROMETHEUS_PORT=9090
ALLOY_PORT=12345

# --- Personal: ad-hoc dashboard push to Grafana Cloud (CI has the same values as repository secrets) ---
# Stack URL and a service-account token with dashboards:write (+ alert.provisioning:write for alerts).
#GRAFANA_URL=https://yourstack.grafana.net
#GRAFANA_API_TOKEN=
# Telegram alerts: set both to push alert rules; leave unset to skip alerting entirely.
#TELEGRAM_BOT_TOKEN=
#TELEGRAM_CHAT_ID=
```

`bricks/observability/env.prod.example`:

```
# Grafana Cloud → stack → Prometheus → "Send metrics": remote-write URL, instance id, token with metrics:write.
GRAFANA_CLOUD_PROM_URL=
GRAFANA_CLOUD_PROM_USER=
GRAFANA_CLOUD_PROM_TOKEN=
```

Remove those lines (and the `OBSERVABILITY (optional)` header + `COMPOSE_PROFILES` comment) from `.env.example` and `deploy/.env.prod.example`. In `deploy/.env.prod.example` the `COMPOSE_PROFILES` lines go entirely (no profiles remain).

`bricks/observability/Makefile`:

```make
# --- brick: observability
observability-up: ## Start local Prometheus + Grafana (http://localhost:3000) + Alloy
	docker compose --env-file $(ENV_FILE) --profile observability up -d

observability-down: ## Stop the local observability stack
	docker compose --profile observability down

grafana-push: ## Push bricks/observability/grafana/** to the local Grafana (http://localhost:3000)
	bricks/observability/grafana-push.sh local

grafana-push-cloud: ## Push bricks/observability/grafana/** to Grafana Cloud (GRAFANA_URL + GRAFANA_API_TOKEN from env or .env)
	bricks/observability/grafana-push.sh cloud

grafana-pull: ## Export the dashboard from local Grafana back into bricks/observability/grafana/dashboards
	bricks/observability/grafana-push.sh pull
```

Delete those five targets from the root `Makefile` and from its `.PHONY`.

- [ ] **Step 4: Script, test, Java, workflow paths**

`bricks/observability/grafana-push.sh`: find every `deploy/grafana` reference and make the script resolve its own directory: `here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; grafana_dir="$here/grafana"`; `.env` is read from `$here/../..`. `bricks/observability/tests/grafana-push.test.sh`: `root="$(cd "$here/../../.." && pwd)"`, `script="$root/bricks/observability/grafana-push.sh"`, any `deploy/grafana` → `bricks/observability/grafana`.

`bricks/observability/java/test/unit/DashboardJsonTest.java`: `package __PKG__.unit;` and

```java
    private static final Path GRAFANA_DIR =
            Path.of(System.getProperty("repo.root", "../..")).resolve("bricks/observability/grafana");
```

(Its Javadoc: "Guards the committed Grafana assets under {@code bricks/observability/grafana}".) Everything else unchanged.

`.github/workflows/dashboards.yml`: paths → `bricks/observability/grafana/**`, `bricks/observability/grafana-push.sh`; run step → `bricks/observability/grafana-push.sh cloud`.

`bricks/observability/alloy/config.alloy`: comments only, if they mention `deploy/`.

- [ ] **Step 5: README and skill**

`bricks/observability/README.md` starts with the one-line heading the `list` command shows, then today's `docs/observability.md` content with paths updated, plus these sections taken from `CLAUDE.md` and `README.md`:

```markdown
# observability: Alloy → Grafana Cloud in prod, Prometheus + Grafana locally, one dashboard, Telegram alerts

`make add BRICK=observability`, then fill the `GRAFANA_CLOUD_PROM_*` block in `deploy/.env.prod` (Grafana Cloud →
stack → Prometheus → *Send metrics*) and `make prod-up`. Memory: alloy 128m.

## What you get
- Local: `make observability-up` → Grafana http://localhost:3000 with the production dashboard, Prometheus, Alloy
  scraping the app you run on the host.
- Prod: Alloy on the `edge` network scrapes every app replica (`app:8081/actuator/prometheus`) and remote-writes.
- `grafana/dashboards/app-overview.json` (one dashboard: version + deploy markers, RED, JVM, Hikari, logs, circuit
  breakers), `grafana/alerting/rules.json` (ServiceDown, 5xx > 5 %, DB connections pending, heap > 90 %,
  BackupStale), Telegram contact point. CI (`.github/workflows/dashboards.yml`) pushes them on merge when
  `GRAFANA_URL` + `GRAFANA_API_TOKEN` exist; alerts only when `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID` exist too.
- `DashboardJsonTest` (copied into the service) keeps the JSON honest.

## Invariants
- Metric names `app.<area>.<thing>`, low-cardinality tags only.
- `BackupStale` threshold (43200 s in `rules.json`) ≥ `BACKUP_MAX_AGE_HOURS` and ≥ 2 × the `BACKUP_CRON` interval
  of the backup brick, or every late run pages. Without the backup brick the rule sees no data and stays quiet.
- Alloy declares the `backup_metrics` volume itself so it starts with or without the backup brick.
```

followed by the existing "Dashboard loop", "Alerting", "Adding a metric" sections. `bricks/observability/skill/SKILL.md`: paths `deploy/grafana` → `bricks/observability/grafana`, `scripts/grafana-push.sh` → `bricks/observability/grafana-push.sh`; frontmatter `name: grafana` → `name: observability`; description unchanged.

- [ ] **Step 6: Verify as a round trip**

```bash
make build 2>&1 | tail -3                         # no bricks: must pass (DashboardJsonTest is gone from core)
make test-scripts 2>&1 | tail -3                  # deploy-config.test.sh will fail on removed alloy checks: fix in the next step
make add BRICK=observability
make build 2>&1 | tail -3                         # DashboardJsonTest back, passing
docker compose --env-file .env.example --profile observability config -q
make observability-up && sleep 5 && curl -sf localhost:3000/api/health && make observability-down
make remove BRICK=observability && git status --porcelain
```

Expected: last command prints nothing (clean tree).

- [ ] **Step 7: `deploy-config.test.sh`, interim**

Delete the lines in `scripts/tests/deploy-config.test.sh` that reference `--profile observability`, `deploy/alloy/config.alloy` and the `target: /metrics/backup` grep (Task 5 rewrites the file with per-brick renders). Run `make test-scripts` → exit 0.

- [ ] **Step 8: Commit**

```bash
make format && git add -A && git commit -F - <<'EOF'
refactor(observability): move Alloy, Grafana and the dashboard into a brick

Metrics collection, dashboards and alerts are optional per project. They now live in bricks/observability and are
wired by `make add BRICK=observability` instead of a compose profile and four documents.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
```

---

### Task 5: Extract the `backup` brick

**Files:**
- Move (git mv): `deploy/backup/*` → `bricks/backup/` (Dockerfile, backup.sh, rclone/), `scripts/tests/backup.test.sh` → `bricks/backup/tests/backup.test.sh`, `scripts/tests/make-backup.test.sh` → `bricks/backup/tests/make-backup.test.sh`
- Create: `bricks/backup/compose.prod.yml`, `bricks/backup/env.prod.example`, `bricks/backup/Makefile`, `bricks/backup/README.md`
- Modify: `deploy/compose.prod.yml`, `deploy/.env.prod.example`, `Makefile`, `.gitignore`, `.github/dependabot.yml`, `scripts/vps.sh`, `scripts/tests/vps.test.sh`, `scripts/tests/deploy-config.test.sh` (rewrite), `scripts/tests/fixtures/env.prod.test`, `docs/deployment.md`

**Interfaces:**
- Produces: brick `backup`; make targets `prod-backup-now/status/list`, `prod-restore`, `vps-backup-status`; `vps.sh deploy-status` reports backups only when `.bricks` on the VPS lists `backup`.

- [ ] **Step 1: Move files**

```bash
mkdir -p bricks/backup/tests
git mv deploy/backup/Dockerfile bricks/backup/Dockerfile
git mv deploy/backup/backup.sh bricks/backup/backup.sh
git mv deploy/backup/rclone bricks/backup/rclone       # whatever is tracked there (.gitignore/.gitkeep)
git mv scripts/tests/backup.test.sh bricks/backup/tests/backup.test.sh
git mv scripts/tests/make-backup.test.sh bricks/backup/tests/make-backup.test.sh
rmdir deploy/backup 2>/dev/null || true
```

`.gitignore`: `deploy/backup/rclone/` → `bricks/backup/rclone/` (keep whichever placeholder file was tracked, with `!bricks/backup/rclone/.gitkeep` if needed so the directory exists on clone — the compose bind has `create_host_path: false`).

- [ ] **Step 2: Brick compose and env**

`bricks/backup/compose.prod.yml` (today's `backup` service, brick-relative paths, declares its resources):

```yaml
# backup brick, production: pg_dump -Fc on BACKUP_CRON, uploaded with rclone to RCLONE_REMOTE; nothing stays on
# this disk. Status/list/restore: bricks/backup/README.md. Memory: 64m.
services:
  backup:
    build: .
    image: ${COMPOSE_PROJECT_NAME}-backup:local
    # Built on the host, never pulled: Watchtower must not look for it in a registry.
    pull_policy: build
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      POSTGRES_DB: ${POSTGRES_DB:-app}
      POSTGRES_USER: ${POSTGRES_USER:-app}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?run make prod-init (generates POSTGRES_PASSWORD)}
      RCLONE_REMOTE: ${RCLONE_REMOTE:?set RCLONE_REMOTE in deploy/.env.prod (bricks/backup/README.md)}
      RCLONE_CONFIG: /config/rclone/rclone.conf
      BACKUP_CRON: ${BACKUP_CRON:-0 */6 * * *}
      TZ: ${BACKUP_TZ:-UTC}
      BACKUP_RETENTION_DAYS: ${BACKUP_RETENTION_DAYS:-30}
      BACKUP_MAX_AGE_HOURS: ${BACKUP_MAX_AGE_HOURS:-12}
    volumes:
      # A directory, read-write: rclone saves refreshed OAuth tokens (Google Drive) by writing a new file and renaming
      # it over rclone.conf, which a single-file bind mount rejects. Must exist on the host (relative to this file).
      - type: bind
        source: ${RCLONE_CONFIG_DIR:-./rclone}
        target: /config/rclone
        bind:
          create_host_path: false
      # Shared by the scheduler and every `docker compose run --rm backup …`, so they cannot overlap.
      - backup_lock:/var/lock/backup
      # Read by the observability brick's Alloy (textfile collector) for the BackupStale alert.
      - backup_metrics:/metrics
    networks: [data]
    mem_limit: 64m
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    labels:
      com.centurylinklabs.watchtower.enable: "false"

networks:
  data:

volumes:
  backup_lock:
  backup_metrics:
```

Remove `backup`, `backup_lock`, `backup_metrics` from `deploy/compose.prod.yml`.

`bricks/backup/env.prod.example` = today's BACKUPS block, with `RCLONE_CONFIG_DIR=./rclone` and the comment "relative to bricks/backup/ (compose resolves bind sources against the file that declares them)". Remove the BACKUPS block from `deploy/.env.prod.example`.

- [ ] **Step 3: Makefile targets move**

`bricks/backup/Makefile` = `# --- brick: backup` plus the five targets `prod-backup-now`, `prod-backup-status`, `prod-backup-list`, `prod-restore`, `vps-backup-status` moved verbatim from the root Makefile with every `--profile backup` removed (the brick is included, not profiled) and `docs/deployment.md §6` → `bricks/backup/README.md`. Delete them from the root `Makefile` and its `.PHONY`.

`bricks/backup/tests/make-backup.test.sh`: `root="$(cd "$here/../../.." && pwd)"`; `mk=(make -s -C "$root" --no-print-directory BRICKS=backup PROD="$tmp/compose")`; any expectation containing `--profile backup` loses it. `bricks/backup/tests/backup.test.sh`: `root` three levels up; `deploy/backup/backup.sh` → `bricks/backup/backup.sh`.

`.github/dependabot.yml`: docker `directories: [/services/app, /bricks/backup]`; docker-compose `directories: [/, /deploy, "/bricks/*"]`.

- [ ] **Step 4: `vps.sh` reads `.bricks`**

In `scripts/vps.sh` `deploy-status`, replace the `profiles=…` / `if [[ ",${profiles// /}," …` block with:

```bash
    if ! remote "cat $app_dir/.bricks 2>/dev/null" | sed -e 's/#.*//' | grep -qx backup; then
      echo "backups: brick off (make add BRICK=backup; bricks/backup/README.md)"
    elif status_out="$(prod "run --rm -T backup status" 2>/dev/null)"; then
```

where `remote` is the existing ssh helper used by `remote_env` (read the script; if the helper is named differently, use that name — do not add a second ssh wrapper). `backup-status)` → `prod "run --rm -T backup status"`. Header comment line 14 unchanged.

`scripts/tests/vps.test.sh`: the fake ssh gains a case before the `.env.prod` one:

```bash
  *"cat "*".bricks"*) printf '%s\n' "${FAKE_BRICKS:-}" ;;
```

and wherever the test sets `FAKE_PROFILES=backup` to get backup output, set `FAKE_BRICKS=backup` instead; the "DISABLED" expectation becomes `brick off`. Run `bash scripts/tests/vps.test.sh` until it passes.

- [ ] **Step 5: Rewrite `scripts/tests/deploy-config.test.sh`**

Keep the header, `fail`, docker skip. Then:

```bash
fixture_env="$here/fixtures/env.prod.test"
prod() { docker compose -f "$1/deploy/compose.prod.yml" --env-file "${2:-$fixture_env}" config "${@:3}"; }

# --- core, no bricks ---------------------------------------------------------------------------------------------
docker compose -f "$root/compose.yml" --env-file "$root/.env.example" --profile full config -q || fail "compose.yml does not validate"
prod "$root" "$fixture_env" -q || fail "deploy/compose.prod.yml does not validate with the fixture env"
if prod "$root" /dev/null -q 2>/dev/null; then fail "compose.prod.yml validated with no environment; a required variable lost its :? guard"; fi
rendered="$(prod "$root")"
for svc in backup alloy minio prometheus grafana; do
  grep -qE "^  ${svc}:" <<<"$rendered" && fail "core prod stack contains brick service ${svc}"
done
rendered_cfg="$(DOCKER_CONFIG_FILE=/home/u/.docker/config.json prod "$root")"
grep -q 'source: /home/u/.docker/config.json' <<<"$rendered_cfg" || fail "DOCKER_CONFIG_FILE is not mounted as the file /config.json"
grep -q 'source: /dev/null' <<<"$rendered" || fail "default registry credential mount should be /dev/null"
grep -q 'WATCHTOWER_LIFECYCLE_HOOKS: "true"' <<<"$rendered" || fail "Watchtower lifecycle hooks not enabled"
grep -q 'com.centurylinklabs.watchtower.lifecycle.post-update:' <<<"$rendered" || fail "app has no post-update health wait hook"
grep -q 'unhealthy_status' "$root/deploy/Caddyfile" && fail "Caddyfile ejects replicas on 5xx responses"
docker run --rm -v "$root/deploy/Caddyfile:/etc/caddy/Caddyfile:ro" -e DOMAIN=example.com -e ACME_EMAIL=ops@example.com \
  caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 || fail "Caddyfile does not validate"

# --- every brick added, on a scratch copy of the working tree ---------------------------------------------------
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
copy="$tmp/repo"; mkdir -p "$copy"
(cd "$root" && git ls-files -z --cached --others --exclude-standard | tar --null -T - -cf - 2>/dev/null) | tar -xf - -C "$copy"
printf '#!/usr/bin/env bash\nexit 0\n' > "$copy/gradlew"; chmod +x "$copy/gradlew"
for d in "$copy"/bricks/*/; do (cd "$copy" && GRADLE=./gradlew scripts/brick.sh add "$(basename "$d")" >/dev/null) || fail "brick add failed for $d"; done

docker compose -f "$copy/compose.yml" --env-file "$copy/.env.example" --profile full --profile observability config -q \
  || fail "compose.yml with every brick does not validate"
prod "$copy" "$fixture_env" -q || fail "compose.prod.yml with every brick does not validate"
if prod "$copy" /dev/null -q 2>/dev/null; then fail "with every brick, an empty env validated; a :? guard is gone"; fi
all="$(prod "$copy")"
for svc in backup alloy minio; do grep -qE "^  ${svc}:" <<<"$all" || fail "brick service ${svc} missing from the all-bricks render"; done
# Every brick service is memory-limited and never rolled by Watchtower.
for svc in backup alloy minio; do
  awk "/^  ${svc}:/,/^  [a-z]/" <<<"$all" | grep -q 'mem_limit' || fail "${svc} has no mem_limit"
  awk "/^  ${svc}:/,/^  [a-z]/" <<<"$all" | grep -q 'com.centurylinklabs.watchtower.enable: "false"' || fail "${svc} is not excluded from Watchtower"
done
# Alloy reads the backup sidecar's textfile from the shared volume.
grep -q 'target: /metrics/backup' <<<"$all" || fail "alloy does not mount the backup metrics volume"
grep -q 'prometheus.exporter.unix "backup"' "$root/bricks/observability/alloy/config.alloy" || fail "alloy has no backup textfile pipeline"
docker run --rm -v "$root/bricks/observability/alloy/config.alloy:/c.alloy:ro" grafana/alloy:v1.10.0 fmt /c.alloy >/dev/null \
  || fail "config.alloy does not parse"
# rclone saves its config (refreshed tokens) by rename, which a single-file bind mount rejects: mount the directory.
grep -q 'RCLONE_CONFIG: /config/rclone/rclone.conf' <<<"$all" || fail "backup does not point rclone at the config inside the mounted directory"
grep -q 'target: /config/rclone$' <<<"$all" || fail "rclone config is not mounted as a directory"
grep -q 'target: /config/rclone.conf' <<<"$all" && fail "rclone.conf is still mounted as a single file"
grep -A6 'target: /config/rclone$' "$root/bricks/backup/compose.prod.yml" | grep -q 'create_host_path: false' \
  || fail "rclone config mount would be auto-created"
grep -q "source: $copy/bricks/backup/rclone" <<<"$all" || fail "rclone config dir does not resolve relative to the brick"
grep -q 'target: /var/lock/backup' <<<"$all" || fail "backup lock is not on a shared volume"
grep -q 'target: /metrics$' <<<"$all" || fail "backup metrics volume missing"
git -C "$root" check-ignore -q bricks/backup/rclone/rclone.conf || fail "bricks/backup/rclone/rclone.conf is not gitignored"
# The minio brick extends app: endpoint env and a healthy-minio dependency.
awk '/^  app:/,/^  [a-z]/' <<<"$all" | grep -q 'APP_MINIO_ENDPOINT: http://minio:9000' || fail "app lacks APP_MINIO_ENDPOINT"
awk '/^  app:/,/^  [a-z]/' <<<"$all" | grep -q 'minio:' || fail "app does not depend on minio"
echo "deploy-config: all passed"
```

(The minio assertions fail until Task 7 ships the brick; leave them in, and run this test again in Task 7. Until then, run the file with the three minio lines commented and uncomment them in Task 7 — note it in the Task 5 commit body.)

`scripts/tests/fixtures/env.prod.test` gains:

```
# Brick variables (harmless values) so the all-bricks render validates.
RCLONE_REMOTE=gdrive:fixture
GRAFANA_CLOUD_PROM_URL=https://prom.example/api/v1/write
GRAFANA_CLOUD_PROM_USER=1
GRAFANA_CLOUD_PROM_TOKEN=fixture-token
MINIO_ROOT_PASSWORD=fixture-minio-password
```

- [ ] **Step 6: README and docs**

`bricks/backup/README.md`:

```markdown
# backup: pg_dump every 6 h to any rclone remote, with status, list and restore

`make add BRICK=backup`, put `rclone.conf` in `bricks/backup/rclone/` on the VPS, set `RCLONE_REMOTE` in
`deploy/.env.prod`, `make prod-up`. Memory: 64m. Without this brick there are no backups.
```

followed by today's `docs/deployment.md` §6 (setup for Google Drive / Storage Box, status, list, restore, undo a
restore, new host) with paths updated (`deploy/backup/rclone` → `bricks/backup/rclone`, make targets unchanged),
and an "Invariants" section: rclone **directory** mount (why), `BackupStale` (observability brick) ≥
`BACKUP_MAX_AGE_HOURS` ≥ 2 × cron interval, `make prod-restore` stops Watchtower only if it was running.

`docs/deployment.md`: §6 becomes two lines pointing at `bricks/backup/README.md`; the memory budget in §7 lists
core only and says "brick services: see each brick's README"; cheat sheet rows for backup move to the brick README.
`CLAUDE.md`: remove the two backup invariants (BackupStale, rclone directory) and the backup sentence in "How this is
hosted" (Task 9 rewrites the whole file; here only delete what is now wrong).

- [ ] **Step 7: Verify**

```bash
make test-scripts 2>&1 | tail -5         # all pass (minio lines commented)
make build 2>&1 | tail -3
make add BRICK=backup && make add BRICK=observability
docker compose -f deploy/compose.prod.yml --env-file scripts/tests/fixtures/env.prod.test config -q
make BRICKS="backup observability" -n prod-backup-status | head -2      # target exists
make remove BRICK=backup && make remove BRICK=observability && git status --porcelain
```

Expected: clean tree at the end.

- [ ] **Step 8: Commit**

```bash
make format && git add -A && git commit -F - <<'EOF'
refactor(backup): move the off-host backup sidecar into a brick

The sidecar, its targets, tests and runbook now live in bricks/backup and are wired by `make add BRICK=backup`.
vps.sh reads .bricks on the host instead of COMPOSE_PROFILES to know whether to report backup freshness.

deploy-config.test.sh carries three minio assertions commented out until the minio brick lands.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
```

---

### Task 6: `init-prod-env.sh` generates every empty `*PASSWORD=`

**Files:**
- Modify: `scripts/init-prod-env.sh`, `scripts/tests/init-prod-env.test.sh`

- [ ] **Step 1: Failing test** — in `scripts/tests/init-prod-env.test.sh`, after copying the example into the fixture repo, append a brick-style block:

```bash
printf '\n# --- brick:minio ---\nMINIO_ROOT_PASSWORD=\n# --- /brick:minio ---\n' >> "$repo/deploy/.env.prod.example"
```

and after the `pw=` assertion:

```bash
mpw="$(grep '^MINIO_ROOT_PASSWORD=' "$env_file" | cut -d= -f2)"
[[ "$mpw" =~ ^[0-9a-f]{48}$ ]] || fail "MINIO_ROOT_PASSWORD not generated: '$mpw'"
[[ "$mpw" != "$pw" ]] || fail "both passwords identical"
```

Run: `bash scripts/tests/init-prod-env.test.sh` → `FAIL: MINIO_ROOT_PASSWORD not generated`.

- [ ] **Step 2: Implement** — replace the `password=…`/`sed … > "$target"` part with:

```bash
umask 077
# Every empty *PASSWORD= line in the example gets its own generated value: the core database password and whatever
# an enabled brick asks for (bricks/README.md). Lines with a value are kept as they are.
sed -e "s#^APP_IMAGE=.*#APP_IMAGE=${image}#" \
    -e "s#^COMPOSE_PROJECT_NAME=.*#COMPOSE_PROJECT_NAME=${project}#" \
    "$example" \
| while IFS= read -r line; do
    if [[ "$line" =~ ^([A-Z0-9_]*PASSWORD)=$ ]]; then printf '%s=%s\n' "${BASH_REMATCH[1]}" "$(openssl rand -hex 24)"; else printf '%s\n' "$line"; fi
  done > "$target"
chmod 600 "$target"
```

Banner text: "It will contain a freshly generated value for every `*PASSWORD=` line (POSTGRES_PASSWORD and any a brick added)". Header comment updated the same way.

- [ ] **Step 3: Verify and commit**

Run: `bash scripts/tests/init-prod-env.test.sh && make test-scripts | tail -2`.

```bash
git add -A && git commit -F - <<'EOF'
feat(deploy): generate every empty *PASSWORD= in .env.prod, not only Postgres

A brick (minio first) can ask for a secret by leaving `X_PASSWORD=` empty in its env block; prod-init fills it on
the host, so no brick secret is ever typed or committed.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
```

---

### Task 7: The `minio` brick

**Files:**
- Create: `bricks/minio/README.md`, `bricks/minio/compose.yml`, `bricks/minio/compose.prod.yml`, `bricks/minio/env.example`, `bricks/minio/env.prod.example`, `bricks/minio/brick.gradle.kts`, `bricks/minio/skill/SKILL.md`, `bricks/minio/java/main/config/MinioProperties.java`, `bricks/minio/java/main/config/MinioConfig.java`, `bricks/minio/java/main/config/MinioHealthIndicator.java`, `bricks/minio/java/main/service/ObjectStorageService.java`, `bricks/minio/java/test/MinioTestcontainersConfiguration.java`, `bricks/minio/java/test/unit/ObjectStorageServiceTest.java`, `bricks/minio/java/test/integration/ObjectStorageIntegrationTest.java`
- Modify: `scripts/tests/deploy-config.test.sh` (uncomment minio lines)

**Interfaces:**
- Consumes: `ApplicationException(HttpStatus, String)` from `services/app/src/main/java/com/example/company/exception/ApplicationException.java` (read it first; use its actual constructor), `AbstractIntegrationTest`.
- Produces: `ObjectStorageService` with `void put(String key, byte[] content, String contentType)`, `byte[] get(String key)` (404 `ApplicationException` when missing), `void delete(String key)`, `URL presignedGetUrl(String key, Duration ttl)`; properties prefix `app.minio` (`endpoint`, `accessKey`, `secretKey`, `bucket`, `region`).

- [ ] **Step 1: Pin versions**

```bash
curl -s 'https://search.maven.org/solrsearch/select?q=g:software.amazon.awssdk+AND+a:s3&rows=1&wt=json' | jq -r '.response.docs[0].latestVersion'
curl -s 'https://search.maven.org/solrsearch/select?q=g:org.testcontainers+AND+a:minio&rows=1&wt=json' | jq -r '.response.docs[0].latestVersion'
docker pull minio/minio:RELEASE.2025-09-07T16-13-09Z >/dev/null 2>&1 && echo tag-ok || echo pick-another
```

Use the printed AWS SDK version as `AWS_SDK` below; Testcontainers minio comes from the BOM already imported in the service build (`org.testcontainers:testcontainers-bom:1.21.4`), so no version there. If the MinIO tag is missing, take the newest `RELEASE.*` tag from `curl -s 'https://hub.docker.com/v2/repositories/minio/minio/tags?page_size=20&name=RELEASE' | jq -r '.results[].name' | sort | tail -1` and use that same tag in both compose files and the Testcontainer.

- [ ] **Step 2: Failing unit test** `bricks/minio/java/test/unit/ObjectStorageServiceTest.java`

```java
package __PKG__.unit;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import __PKG__.config.MinioProperties;
import __PKG__.exception.ApplicationException;
import __PKG__.service.ObjectStorageService;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import software.amazon.awssdk.core.ResponseBytes;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.GetObjectRequest;
import software.amazon.awssdk.services.s3.model.GetObjectResponse;
import software.amazon.awssdk.services.s3.model.NoSuchKeyException;
import software.amazon.awssdk.services.s3.model.PutObjectRequest;
import software.amazon.awssdk.services.s3.presigner.S3Presigner;

class ObjectStorageServiceTest {

    private final S3Client s3 = mock(S3Client.class);
    private final S3Presigner presigner = mock(S3Presigner.class);
    private final MinioProperties props =
            new MinioProperties("http://localhost:9000", "k", "s", "bucket-a", "us-east-1");
    private final ObjectStorageService service = new ObjectStorageService(s3, presigner, props);

    @Test
    void putUploadsToTheConfiguredBucketWithContentType() {
        service.put("docs/a.txt", "hi".getBytes(), "text/plain");

        var request = ArgumentCaptor.forClass(PutObjectRequest.class);
        verify(s3).putObject(request.capture(), any(RequestBody.class));
        assertThat(request.getValue().bucket()).isEqualTo("bucket-a");
        assertThat(request.getValue().key()).isEqualTo("docs/a.txt");
        assertThat(request.getValue().contentType()).isEqualTo("text/plain");
    }

    @Test
    void getReturnsTheBytes() {
        when(s3.getObjectAsBytes(any(GetObjectRequest.class)))
                .thenReturn(ResponseBytes.fromByteArray(GetObjectResponse.builder().build(), "hi".getBytes()));

        assertThat(service.get("docs/a.txt")).isEqualTo("hi".getBytes());
    }

    @Test
    void getOfAMissingKeyIsA404() {
        when(s3.getObjectAsBytes(any(GetObjectRequest.class))).thenThrow(NoSuchKeyException.builder().build());

        assertThatThrownBy(() -> service.get("nope"))
                .isInstanceOf(ApplicationException.class)
                .hasMessageContaining("nope");
    }
}
```

(`ApplicationException` carries an `HttpStatus`; assert on it the way `GlobalExceptionHandlerTest` does — read that test and add `.extracting("status").isEqualTo(HttpStatus.NOT_FOUND)` or its equivalent.)

- [ ] **Step 3: Main code**

`bricks/minio/java/main/config/MinioProperties.java`:

```java
package __PKG__.config;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.boot.context.properties.bind.DefaultValue;

/**
 * Object storage settings (minio brick). Bound from the environment by relaxed binding: {@code APP_MINIO_ENDPOINT},
 * {@code APP_MINIO_ACCESS_KEY}, {@code APP_MINIO_SECRET_KEY}, {@code APP_MINIO_BUCKET}, {@code APP_MINIO_REGION}.
 * Defaults match the local compose service. Any S3-compatible store works (MinIO, Hetzner Object Storage, AWS).
 */
@ConfigurationProperties(prefix = "app.minio")
public record MinioProperties(
        @DefaultValue("http://localhost:9000") String endpoint,
        @DefaultValue("minioadmin") String accessKey,
        @DefaultValue("minioadmin") String secretKey,
        @DefaultValue("app") String bucket,
        @DefaultValue("us-east-1") String region) {}
```

`bricks/minio/java/main/config/MinioConfig.java`:

```java
package __PKG__.config;

import java.net.URI;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.S3Configuration;
import software.amazon.awssdk.services.s3.presigner.S3Presigner;

/**
 * S3 client and presigner for the configured endpoint (minio brick). Path-style addressing because MinIO has no
 * per-bucket DNS. Nothing connects at startup: the bucket is created on first use by {@code ObjectStorageService},
 * so the context boots even when the store is down and the health indicator reports it.
 */
@Configuration
@EnableConfigurationProperties(MinioProperties.class)
public class MinioConfig {

    @Bean
    S3Client s3Client(MinioProperties props) {
        return S3Client.builder()
                .endpointOverride(URI.create(props.endpoint()))
                .region(Region.of(props.region()))
                .credentialsProvider(credentials(props))
                .forcePathStyle(true)
                .build();
    }

    @Bean
    S3Presigner s3Presigner(MinioProperties props) {
        return S3Presigner.builder()
                .endpointOverride(URI.create(props.endpoint()))
                .region(Region.of(props.region()))
                .credentialsProvider(credentials(props))
                .serviceConfiguration(
                        S3Configuration.builder().pathStyleAccessEnabled(true).build())
                .build();
    }

    private static StaticCredentialsProvider credentials(MinioProperties props) {
        return StaticCredentialsProvider.create(AwsBasicCredentials.create(props.accessKey(), props.secretKey()));
    }
}
```

`bricks/minio/java/main/service/ObjectStorageService.java`:

```java
package __PKG__.service;

import __PKG__.config.MinioProperties;
import __PKG__.exception.ApplicationException;
import java.net.URL;
import java.time.Duration;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.NoSuchBucketException;
import software.amazon.awssdk.services.s3.model.NoSuchKeyException;
import software.amazon.awssdk.services.s3.presigner.S3Presigner;
import software.amazon.awssdk.services.s3.presigner.model.GetObjectPresignRequest;

/** Put, get, delete and presign objects in the configured bucket (minio brick). Creates the bucket on first use. */
@Service
@RequiredArgsConstructor
@Slf4j
public class ObjectStorageService {

    private final S3Client s3;
    private final S3Presigner presigner;
    private final MinioProperties props;
    private volatile boolean bucketChecked;

    public void put(String key, byte[] content, String contentType) {
        ensureBucket();
        s3.putObject(
                b -> b.bucket(props.bucket()).key(key).contentType(contentType),
                RequestBody.fromBytes(content));
    }

    public byte[] get(String key) {
        try {
            return s3.getObjectAsBytes(b -> b.bucket(props.bucket()).key(key)).asByteArray();
        } catch (NoSuchKeyException e) {
            throw new ApplicationException(HttpStatus.NOT_FOUND, "object not found: " + key);
        }
    }

    public void delete(String key) {
        s3.deleteObject(b -> b.bucket(props.bucket()).key(key));
    }

    public URL presignedGetUrl(String key, Duration ttl) {
        return presigner
                .presignGetObject(GetObjectPresignRequest.builder()
                        .signatureDuration(ttl)
                        .getObjectRequest(b -> b.bucket(props.bucket()).key(key))
                        .build())
                .url();
    }

    private void ensureBucket() {
        if (bucketChecked) {
            return;
        }
        try {
            s3.headBucket(b -> b.bucket(props.bucket()));
        } catch (NoSuchBucketException e) {
            log.info("creating bucket {}", props.bucket());
            s3.createBucket(b -> b.bucket(props.bucket()));
        }
        bucketChecked = true;
    }
}
```

(Fix the `ApplicationException` constructor call to match the real signature; `putObject` with the consumer-builder overload exists on `S3Client`: `putObject(Consumer<PutObjectRequest.Builder>, RequestBody)`. The unit test's `verify(s3).putObject(request.capture(), any(RequestBody.class))` captures a `PutObjectRequest`; Mockito matches the interface method `putObject(PutObjectRequest, RequestBody)` only if the service calls that overload — so in `put` build the request explicitly: `PutObjectRequest.builder().bucket(…).key(key).contentType(contentType).build()` and pass it. Do the same explicit-builder style for `get` (`GetObjectRequest`) so the mock stub matches.)

`bricks/minio/java/main/config/MinioHealthIndicator.java`:

```java
package __PKG__.config;

import lombok.RequiredArgsConstructor;
import org.springframework.boot.health.contributor.Health;
import org.springframework.boot.health.contributor.HealthIndicator;
import org.springframework.stereotype.Component;
import software.amazon.awssdk.services.s3.S3Client;

/** /actuator/health shows the object store (minio brick): UP when the endpoint answers a bucket listing. */
@Component
@RequiredArgsConstructor
public class MinioHealthIndicator implements HealthIndicator {

    private final S3Client s3;
    private final MinioProperties props;

    @Override
    public Health health() {
        try {
            s3.listBuckets();
            return Health.up().withDetail("endpoint", props.endpoint()).build();
        } catch (RuntimeException e) {
            return Health.down(e).withDetail("endpoint", props.endpoint()).build();
        }
    }
}
```

(Boot 4 moved `Health`/`HealthIndicator` to `org.springframework.boot.health.contributor`; if the compiler disagrees, grep the actuator jar: `find ~/.gradle -name 'spring-boot-actuator-4*.jar' | head -1 | xargs -I{} unzip -l {} | grep HealthIndicator`.) Note: with this indicator, `/actuator/health` is DOWN while MinIO is unreachable; the compose healthcheck would then restart replicas. That is the wanted behaviour for a brick the app depends on, and `depends_on: minio: service_healthy` prevents it at boot. Say so in the README.

- [ ] **Step 4: Gradle, compose, env, skill**

`bricks/minio/brick.gradle.kts`:

```kotlin
// minio brick: S3 client (MinIO, Hetzner Object Storage or AWS) and a MinIO Testcontainer for integration tests.
dependencies {
    "implementation"("software.amazon.awssdk:s3:AWS_SDK")
    "testImplementation"("org.testcontainers:minio")
}
```

`bricks/minio/compose.yml`:

```yaml
# minio brick, local: S3-compatible object storage. `make run` starts it (no profile); console at
# http://localhost:9001 (MINIO_ROOT_USER / MINIO_ROOT_PASSWORD). The app on the host reaches it at localhost:9000
# through the defaults in MinioProperties; the app container gets the compose address below.
services:
  minio:
    image: minio/minio:MINIO_TAG
    command: server /data --console-address ":9001"
    ports:
      - "127.0.0.1:${MINIO_PORT:-9000}:9000"
      - "127.0.0.1:${MINIO_CONSOLE_PORT:-9001}:9001"
    environment:
      MINIO_ROOT_USER: ${MINIO_ROOT_USER:-minioadmin}
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD:-minioadmin}
    volumes:
      - minio-data:/data
    healthcheck:
      test: ["CMD", "mc", "ready", "local"]
      interval: 5s
      timeout: 5s
      retries: 5

  app:
    environment:
      APP_MINIO_ENDPOINT: http://minio:9000
      APP_MINIO_ACCESS_KEY: ${MINIO_ROOT_USER:-minioadmin}
      APP_MINIO_SECRET_KEY: ${MINIO_ROOT_PASSWORD:-minioadmin}
      APP_MINIO_BUCKET: ${APP_MINIO_BUCKET:-app}
    depends_on:
      minio:
        condition: service_healthy

volumes:
  minio-data:
```

`bricks/minio/compose.prod.yml`:

```yaml
# minio brick, production: object storage on the data network, never published; the app reaches it as minio:9000.
# Memory: 256m. Presigned URLs carry this internal endpoint: expose MinIO through Caddy yourself if browsers must
# fetch objects directly (README.md).
services:
  minio:
    image: minio/minio:MINIO_TAG
    restart: unless-stopped
    command: server /data
    environment:
      MINIO_ROOT_USER: ${MINIO_ROOT_USER:-minio}
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD:?run make prod-init (generates MINIO_ROOT_PASSWORD)}
    volumes:
      - minio_data:/data
    healthcheck:
      test: ["CMD", "mc", "ready", "local"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 20s
    networks: [data]
    mem_limit: 256m
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    labels:
      com.centurylinklabs.watchtower.enable: "false"

  app:
    environment:
      APP_MINIO_ENDPOINT: http://minio:9000
      APP_MINIO_ACCESS_KEY: ${MINIO_ROOT_USER:-minio}
      APP_MINIO_SECRET_KEY: ${MINIO_ROOT_PASSWORD:?run make prod-init (generates MINIO_ROOT_PASSWORD)}
      APP_MINIO_BUCKET: ${APP_MINIO_BUCKET:-app}
    depends_on:
      minio:
        condition: service_healthy

networks:
  data:

volumes:
  minio_data:
```

`bricks/minio/env.example`:

```
# --- minio (local object storage; console http://localhost:9001) ---
MINIO_ROOT_USER=minioadmin
MINIO_ROOT_PASSWORD=minioadmin
MINIO_PORT=9000
MINIO_CONSOLE_PORT=9001
APP_MINIO_BUCKET=app
```

`bricks/minio/env.prod.example`:

```
# Object storage credentials. The password is generated by `make prod-init` (leave empty here).
MINIO_ROOT_USER=minio
MINIO_ROOT_PASSWORD=
# Bucket the app uses; created on first use.
APP_MINIO_BUCKET=app
```

`bricks/minio/skill/SKILL.md`:

```markdown
---
name: minio
description: Store and fetch files through ObjectStorageService (S3 / MinIO). Use when a feature needs file upload, download, deletion or a temporary download link, or when MinIO is down in prod.
---

# minio brick

- Inject `ObjectStorageService` (`service` package): `put(key, bytes, contentType)`, `get(key)` (404
  `ApplicationException` when missing), `delete(key)`, `presignedGetUrl(key, ttl)`.
- Keys are paths inside the one bucket `app.minio.bucket`; prefix them by feature (`invoices/<id>.pdf`).
- Settings: `MinioProperties` (`APP_MINIO_*` env). Local defaults hit the compose `minio` at localhost:9000.
- Tests: unit with a mocked `S3Client`; integration via `@Import(MinioTestcontainersConfiguration.class)`.
- Prod: `make vps-logs SERVICE=minio`; `/actuator/health` shows `minio` DOWN when the endpoint is unreachable.
- Everything else: `bricks/minio/README.md`.
```

- [ ] **Step 5: Test support and integration test**

`bricks/minio/java/test/MinioTestcontainersConfiguration.java`:

```java
package __PKG__;

import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.test.context.DynamicPropertyRegistrar;
import org.testcontainers.containers.MinIOContainer;
import org.testcontainers.utility.DockerImageName;

/** A MinIO container for integration tests of the minio brick; import next to {@link TestcontainersConfiguration}. */
@TestConfiguration(proxyBeanMethods = false)
public class MinioTestcontainersConfiguration {

    @Bean
    MinIOContainer minioContainer() {
        return new MinIOContainer(DockerImageName.parse("minio/minio:MINIO_TAG"));
    }

    @Bean
    DynamicPropertyRegistrar minioProperties(MinIOContainer minio) {
        return registry -> {
            registry.add("app.minio.endpoint", minio::getS3URL);
            registry.add("app.minio.access-key", minio::getUserName);
            registry.add("app.minio.secret-key", minio::getPassword);
        };
    }
}
```

`bricks/minio/java/test/integration/ObjectStorageIntegrationTest.java`:

```java
package __PKG__.integration;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import __PKG__.MinioTestcontainersConfiguration;
import __PKG__.exception.ApplicationException;
import __PKG__.service.ObjectStorageService;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import lombok.RequiredArgsConstructor;
import org.junit.jupiter.api.Test;
import org.springframework.context.annotation.Import;

@Import(MinioTestcontainersConfiguration.class)
@RequiredArgsConstructor
class ObjectStorageIntegrationTest extends AbstractIntegrationTest {

    private final ObjectStorageService storage;

    @Test
    void roundTripThroughARealStore() throws Exception {
        storage.put("it/hello.txt", "hello".getBytes(), "text/plain");

        assertThat(storage.get("it/hello.txt")).isEqualTo("hello".getBytes());

        var url = storage.presignedGetUrl("it/hello.txt", Duration.ofMinutes(1));
        var response = HttpClient.newHttpClient()
                .send(HttpRequest.newBuilder(url.toURI()).GET().build(), HttpResponse.BodyHandlers.ofString());
        assertThat(response.statusCode()).isEqualTo(200);
        assertThat(response.body()).isEqualTo("hello");

        storage.delete("it/hello.txt");
        assertThatThrownBy(() -> storage.get("it/hello.txt")).isInstanceOf(ApplicationException.class);
    }
}
```

(If `@RequiredArgsConstructor` on a test class is not how the existing integration tests inject — check `VersionEndpointIntegrationTest` — use the same constructor style as that file.)

- [ ] **Step 6: README**

`bricks/minio/README.md`:

```markdown
# minio: S3-compatible object storage with an ObjectStorageService, locally and in prod

`make add BRICK=minio` → `make run` starts MinIO beside Postgres (console http://localhost:9001, minioadmin /
minioadmin). In prod: `make prod-init` (or add `MINIO_ROOT_PASSWORD=` by hand and generate one with
`openssl rand -hex 24`), `make prod-up`. Memory: 256m.

## Use it
`ObjectStorageService` (`service/`): `put(key, bytes, contentType)`, `get(key)` → 404 `ApplicationException` when
missing, `delete(key)`, `presignedGetUrl(key, ttl)`. One bucket (`APP_MINIO_BUCKET`, created on first use); prefix
keys per feature. Settings: `MinioProperties`, env `APP_MINIO_ENDPOINT / ACCESS_KEY / SECRET_KEY / BUCKET / REGION`.

## Operate it
- `/actuator/health` → `minio` component; DOWN when the endpoint is unreachable. Replicas wait for a healthy MinIO
  at boot (`depends_on`), and a MinIO outage later shows as app DOWN by design: the app cannot do its job.
- Data lives in the `minio_data` volume; it is **not** in the backup brick's dump. Back it up with `rclone` from the
  volume or switch to a managed store.
- Presigned URLs embed `APP_MINIO_ENDPOINT` (`http://minio:9000` in prod): fine for server-side fetches, not for
  browsers. To serve objects publicly add a Caddy site for MinIO, set `APP_MINIO_ENDPOINT` to that public URL and
  keep the app on the private one through a second property if needed — not provided here.
- Swap to Hetzner Object Storage / AWS: set `APP_MINIO_ENDPOINT`, `APP_MINIO_ACCESS_KEY`, `APP_MINIO_SECRET_KEY`,
  `APP_MINIO_REGION` in `deploy/.env.prod`, delete the `minio` service and the `app` partial from
  `bricks/minio/compose.prod.yml` (or remove the brick and keep the Java).

## Tests
Unit: `ObjectStorageServiceTest` (mocked `S3Client`). Integration: `ObjectStorageIntegrationTest` against a
Testcontainers MinIO (`@Import(MinioTestcontainersConfiguration.class)`).

## Change it
Dependencies: `brick.gradle.kts` (bump the AWS SDK by hand; Dependabot does not read brick files). Image tag:
both compose files and `MinioTestcontainersConfiguration` carry it; change all three.
```

- [ ] **Step 7: Run the brick end to end**

```bash
make add BRICK=minio
make build 2>&1 | tail -5                          # unit + integration incl. ObjectStorageIntegrationTest
sed -i 's/^# \(.*APP_MINIO_ENDPOINT.*\)$/\1/; s/^# \(.*depend on minio.*\)$/\1/' scripts/tests/deploy-config.test.sh   # or uncomment by hand
make test-scripts 2>&1 | tail -3
make run &  sleep 40; curl -sf localhost:8080/actuator/health | jq .components.minio; kill %1   # optional smoke
make remove BRICK=minio && git status --porcelain      # must be empty
```

Expected: `BUILD SUCCESSFUL`, `deploy-config: all passed`, clean tree after remove.

- [ ] **Step 8: Commit**

```bash
make format && git add -A && git commit -F - <<'EOF'
feat(bricks): add the minio brick with an S3 ObjectStorageService

First brick that carries Java: proves that compose, env, dependencies, main code, tests and a skill can all come
from one folder and leave no residue on removal. The AWS SDK client works unchanged against Hetzner Object Storage.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
```

---

### Task 8: CI verifies every brick; workflow lint

**Files:**
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Add the job** (after `security-fast`; `image` must not `need` it)

```yaml
  # Bricks are inert until enabled, so the plain build cannot catch a brick that rotted. Each one is added on a
  # clean checkout, built with its tests, and removed again; nothing here gates the image, so push → live stays fast.
  bricks:
    name: Brick ${{ matrix.brick }}
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        brick: [observability, backup, minio]
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false

      - uses: actions/setup-java@de7274f081f381c8f8158605e0321c36c376e2e6 # v6.0.1
        with:
          distribution: temurin
          java-version: ${{ env.JAVA_VERSION }}

      - uses: gradle/actions/setup-gradle@9c971963bec38e04b3d30dcc455b5382be2fdbfb # v6.3.0
        with:
          cache-read-only: true

      - name: Add the brick
        env:
          BRICK: ${{ matrix.brick }}
        run: scripts/brick.sh add "$BRICK"

      - name: Build with the brick
        run: ./gradlew build --no-daemon

      - name: Script tests and compose render with the brick
        run: |
          scripts/tests/run.sh
          docker compose --env-file .env.example --profile full --profile observability config -q
          docker compose -f deploy/compose.prod.yml --env-file scripts/tests/fixtures/env.prod.test config -q

      - name: Remove the brick and prove nothing is left
        env:
          BRICK: ${{ matrix.brick }}
        run: |
          scripts/brick.sh remove "$BRICK"
          git status --porcelain
          test -z "$(git status --porcelain)"
```

Header comment of `ci.yml` gains one line: "bricks: every brick added, built and removed on its own runner (not a gate)".

- [ ] **Step 2: Lint and the matrix test**

```bash
uvx zizmor@1.30.1 --min-severity medium .github/workflows
bash scripts/tests/brick.test.sh | tail -1          # the ci.yml matrix check at its end now runs for real
```

Expected: zizmor clean; `brick: all passed`.

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -F - <<'EOF'
ci: build every brick on a clean checkout without gating the image

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
```

---

### Task 9: Documentation and the bricks skill

**Files:**
- Create: `.claude/skills/bricks/SKILL.md`
- Modify: `bricks/README.md` (replace stub), `CLAUDE.md`, `README.md`, `docs/deployment.md`

- [ ] **Step 1: `bricks/README.md`** (normative brick contract; copy spec §5 into prose the agent can act on)

```markdown
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
| `Makefile` | Included by the root Makefile while enabled. Start with `# --- brick: <name>`; use `##` help comments; may use `PROD`, `ENV_FILE`, `SERVICE`. |
| `brick.gradle.kts` | Applied to the service build while enabled; `add`/`remove` refresh the lockfile. Use `"implementation"("…")` (string-invoked; no type-safe accessors). |
| `java/main/**`, `java/test/**` | Copied under `services/app/src/{main,test}/java/<package>/…`; `__PKG__` → the service package. Formatted by Spotless on add. |
| `resources/main/**`, `resources/test/**` | Copied under `services/app/src/{main,test}/resources/`. |
| `skill/SKILL.md` | Installed as `.claude/skills/<name>/SKILL.md`. |
| `tests/*.test.sh` | Run by `make test-scripts` always. Test the brick's own scripts in isolation (`BRICKS=<name>` on make). |
| anything else | Stays put; reference it from the brick's compose files by relative path. |

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
```

- [ ] **Step 2: `.claude/skills/bricks/SKILL.md`**

```markdown
---
name: bricks
description: Add, remove, operate or author a brick (optional infrastructure under bricks/). Use when the user wants MinIO, Grafana, backups or another component, asks what bricks exist, or wants a new component packaged so it can be added with one command.
---

# Bricks

- List: `make bricks`. Enable: `make add BRICK=<name>`. Disable: `make remove BRICK=<name>`. Enabled list: `.bricks`.
- After add or remove: `make build && make test-scripts`; commit the whole diff as one `feat(<name>)` / `chore(<name>)`.
- Before touching a brick's files or operating it in prod: read `bricks/<name>/README.md` (it is the runbook).
- Before writing a new brick: read `bricks/README.md` (anatomy, rules, checklist). Keep it self-contained; test the
  round trip; add it to the CI matrix.
- What add does, in order: compose includes → env blocks → Java/resources (`__PKG__` → service package) → skill →
  `.bricks` → lockfile → Spotless. `scripts/brick.sh` is the source of truth.
```

- [ ] **Step 3: `CLAUDE.md`**

Rewrite these parts, leaving the rest:

- Intro sentence after the first paragraph: "Core is one Spring service (`services/app`) + Postgres; everything else
  is a brick (`bricks/`, `make bricks`)."
- Commands table: add `make bricks` / `make add BRICK=` / `make remove BRICK=` rows; drop `make observability-up`;
  `make run` row mentions `SERVICE=`.
- "How this is hosted and deployed": first bullet becomes "One Hetzner VPS running `deploy/compose.prod.yml`: Caddy
  (TLS, only published ports) → 2 `app` replicas → Postgres (loopback only), plus Watchtower. Enabled bricks add
  their services through compose `include:`." Remove backup/Alloy mentions.
- Replace the "Observability" section with "## Bricks": "`.bricks` lists enabled bricks. `make add BRICK=<name>`
  wires `bricks/<name>/` in (compose include, env blocks, Java copied into the service, skill, lockfile);
  `make remove` reverses it. Read `bricks/<name>/README.md` before touching a brick, `bricks/README.md` before
  authoring one. Skill: `.claude/skills/bricks/SKILL.md`. Observability (Grafana, alerts, dashboard) and backups
  are bricks; their invariants live in their READMEs."
- "Invariants that break production silently": keep Watchtower API version, replicas × pool, grace periods, `:?`
  guards; delete BackupStale and rclone entries (now in `bricks/backup/README.md` and `bricks/observability/README.md`).
- Conventions: the `services/app` line from Task 1 stays.

- [ ] **Step 4: `README.md`**

- Local block: drop `make observability-up`, add `make bricks            # optional pieces: observability, backup, minio → make add BRICK=<name>`.
- "Zero to production" table: delete the two `COMPOSE_PROFILES` rows and the Grafana/Telegram secret rows; add one
  row `| Bricks | \`make add BRICK=observability\|backup\|minio\`, then that brick's README | Metrics + alerts, off-host backups, object storage |`.
- The VPS block comment: "starts Caddy + 2 app replicas + Postgres + Watchtower (+ enabled bricks)".
- Replace the "Observability" section with:

```markdown
## Bricks

Optional infrastructure lives in `bricks/<name>/` and is inert until added:

| Brick | Gives you | Add |
|---|---|---|
| observability | Alloy → Grafana Cloud, local Prometheus + Grafana, one dashboard, Telegram alerts | `make add BRICK=observability` |
| backup | pg_dump every 6 h to an rclone remote, status/list/restore | `make add BRICK=backup` |
| minio | S3-compatible object storage + `ObjectStorageService` | `make add BRICK=minio` |

`make add` wires compose, env, Java, make targets and a Claude skill from that one folder; `make remove` takes it all
out. Each brick's README is its runbook; `bricks/README.md` is the contract for writing one.
```

- Docs table: remove `docs/observability.md`; add `bricks/README.md` row.
- Testing section: `DashboardJsonTest` sentence moves under the bricks mention ("the observability brick ships
  `DashboardJsonTest`").

- [ ] **Step 5: `docs/deployment.md`** — update the cheat sheet (§8) and healthy-state (§3) sections: backup and alloy
  rows reference the bricks; §1 bring-up says "(+ enabled bricks)"; search the file for `deploy/grafana`,
  `deploy/alloy`, `deploy/backup`, `COMPOSE_PROFILES`, `--profile` and fix every hit.

- [ ] **Step 6: Verify no stale paths anywhere**

```bash
grep -rn --exclude-dir=.git --exclude-dir=build --exclude-dir=.gradle --exclude-dir=superpowers \
  -e 'deploy/grafana' -e 'deploy/alloy' -e 'deploy/backup' -e 'deploy/prometheus' -e 'COMPOSE_PROFILES' \
  -e 'scripts/grafana-push' -e 'docs/observability.md' -e '--profile backup' -e '--profile observability' . \
  | grep -v 'bricks/observability/compose.yml' | grep -v 'bricks/observability/Makefile' | grep -v 'deploy-config.test.sh' | grep -v 'ci.yml'
make build 2>&1 | tail -3 && make test-scripts 2>&1 | tail -3
```

Expected: the grep prints nothing (the excluded files legitimately use `--profile observability`); build and script tests pass.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -F - <<'EOF'
docs: describe bricks in README, CLAUDE.md and a bricks skill

The root documents shrink to the core; each brick's README is its runbook and bricks/README.md is the contract for
writing one, so an agent reads one folder to work on one component.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
```

---

### Task 10: Acceptance round trips and rename check

**Files:** none new (fix whatever the round trips reveal).

- [ ] **Step 1: Every brick, one at a time, then all together**

```bash
set -e
for b in observability backup minio; do
  make add BRICK=$b
  make build 2>&1 | tail -2
  make test-scripts 2>&1 | tail -1
  docker compose --env-file .env.example --profile full --profile observability config -q
  docker compose -f deploy/compose.prod.yml --env-file scripts/tests/fixtures/env.prod.test config -q
  make remove BRICK=$b
  test -z "$(git status --porcelain)" || { git status --porcelain; echo "RESIDUE after $b"; exit 1; }
done
make add BRICK=observability && make add BRICK=backup && make add BRICK=minio
make build 2>&1 | tail -2
make bricks
make remove BRICK=minio && make remove BRICK=backup && make remove BRICK=observability
test -z "$(git status --porcelain)" && echo ALL-CLEAN
```

Expected: `ALL-CLEAN`.

- [ ] **Step 2: Rename after add**

```bash
make add BRICK=minio && git add -A && git commit -qm "chore(tmp): minio on" \
  && make rename PKG=com.acme.shop APP=shop && make build 2>&1 | tail -2 \
  && ls services/app/src/main/java/com/acme/shop/service/ObjectStorageService.java \
  && git reset -q --hard HEAD~1
```

Expected: build passes under the new package; the file exists; the temporary commit is gone (`git log -1` shows Task 9's commit).

- [ ] **Step 3: Final checks**

```bash
make format && git status --porcelain      # empty
scripts/lint-commits.sh main..HEAD          # every commit subject accepted
uvx zizmor@1.30.1 --min-severity medium .github/workflows
```

- [ ] **Step 4: Commit any fixes** with `fix(bricks): …` subjects explaining what the round trip revealed.
