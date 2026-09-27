# Production-ready Template Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the template into a push-to-deploy Spring Boot starter for one Hetzner VPS: SemVer from conventional commits, GHCR image + GitHub Release per push, Watchtower rolling deploy behind Caddy, Grafana dashboards locally and in Grafana Cloud, Claude skills for prod DB access, honest README and CLAUDE.md.

**Architecture:** CI builds the jar once, packages a runtime-only multi-arch image, tags a release, and tracks the rollout by polling `/version`. The VPS runs `deploy/compose.prod.yml` (Caddy → 2 app replicas → Postgres, plus Watchtower, backup, Alloy). Observability is push-based: Alloy scrapes `/actuator/prometheus` on the management port and remote-writes to Grafana Cloud (prod) or a local Prometheus (dev); one committed dashboard JSON renders in both because the datasource uid is fixed.

**Tech Stack:** Java 25, Spring Boot 4.1, Gradle 9.6 Kotlin DSL, Testcontainers, Micrometer Prometheus, Docker Compose, Caddy 2, Watchtower 1.7.1, Grafana Alloy, Grafana 11, Prometheus 3, GitHub Actions, bash.

**Spec:** `docs/superpowers/specs/2026-09-28-prod-ready-template-design.md`

## Global Constraints

- Java 25 toolchain, Spring Boot 4.1.0, Spring Cloud 2025.1.2, Testcontainers BOM 1.21.4 stay as they are.
- Spotless (palantir 2.97.0) must pass: run `./gradlew spotlessApply` before every commit that touches Java or `*.gradle.kts`.
- Commit subjects follow `^(feat|fix|perf|refactor|docs|test|build|ci|chore|style|revert)(\([a-z0-9._-]+\))?!?: .+` from Task 4 onward (the hook is installed there); earlier tasks use the same format by hand.
- Every commit message ends with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Secrets never appear in committed files. `.env.example` holds only local defaults; `deploy/.env.prod.example` holds empty keys with comments.
- Management port (`MANAGEMENT_PORT`, 8081 in prod) is never published by compose and never proxied by Caddy.
- No `container_name` on services that may have replicas or several clones.
- GitHub Actions pinned to a full commit SHA with a `# vN` comment.
- Bash scripts: `#!/usr/bin/env bash`, `set -euo pipefail`, pass `shellcheck` if installed.

## Review Focus

1. Commit subject with a scope containing a dot or dash (`build(deps-dev): bump x`) must pass the regex — Dependabot writes these. Test in Task 4.
2. `next-version.sh` on a repo whose latest tag is not on the first-parent line (tag on a merged branch) must still find the highest `v*` tag by version sort, not by `git describe` topology. Test in Task 4.
3. `/version` must answer before the datasource is up? No: it is in the same context. But it must answer with `local`/`dev` when `APP_VERSION`/`APP_REVISION` are unset, never blank. Test in Task 2.
4. `init-prod-env.sh` run from a repo whose remote is SSH form (`git@github.com:Owner/Repo.git`) must derive `ghcr.io/owner/repo` lowercased. Test in Task 6.
5. `grafana-push.sh cloud` with `GRAFANA_URL` ending in a trailing slash must not produce `//api/...`. Test in Task 7.

---

### Task 1: Gradle foundation — fix deps, test split, forks, caching, locking

**Files:**
- Modify: `build.gradle.kts`
- Create: `gradle.properties`
- Create: `gradle.lockfile` (generated)
- Modify: `Makefile` (test targets)
- Move: `src/test/java/com/example/company/InstancioExampleTest.java` → `src/test/java/com/example/company/unit/InstancioExampleTest.java`

**Interfaces:**
- Produces: Gradle tasks `test` (unit) and `integrationTest`; `bootJar` output `build/libs/app.jar`; `make test`, `make itest`, `make lock`.

- [ ] **Step 1: Write the failing check** — a shell assertion that `integrationTest` exists and `test` excludes integration classes.

```bash
./gradlew tasks --all -q | grep -q '^integrationTest' && echo OK || echo MISSING
```
Expected: `MISSING`.

- [ ] **Step 2: Edit `build.gradle.kts`.** Replace the dependencies and test blocks:

```kotlin
plugins {
    id("java")
    id("jacoco")
    id("org.springframework.boot") version "4.1.0"
    id("io.spring.dependency-management") version "1.1.7"
    id("com.diffplug.spotless") version "7.2.1"
}

group = "com.example.company"
version = "0.0.1-SNAPSHOT"

java {
    toolchain {
        languageVersion = JavaLanguageVersion.of(25)
    }
}

repositories {
    mavenCentral()
}

// Reproducible builds: every configuration is locked in gradle.lockfile. `make lock` refreshes it.
dependencyLocking {
    lockAllConfigurations()
}

extra["springCloudVersion"] = "2025.1.2"

dependencies {
    compileOnly("org.projectlombok:lombok")
    annotationProcessor("org.projectlombok:lombok")
    annotationProcessor("org.projectlombok:lombok-mapstruct-binding:0.2.0")

    implementation("org.mapstruct:mapstruct:1.6.3")
    annotationProcessor("org.mapstruct:mapstruct-processor:1.6.3")

    implementation("org.springframework.boot:spring-boot-starter-web")
    implementation("org.springframework.boot:spring-boot-starter-data-jpa")
    implementation("org.springframework.boot:spring-boot-starter-validation")
    implementation("org.springframework.boot:spring-boot-starter-actuator")
    implementation("org.springframework.boot:spring-boot-starter-cache")
    implementation("com.github.ben-manes.caffeine:caffeine")
    // Boot 4 dropped spring-boot-starter-aop; spring-aspects brings AspectJ + @Aspect support.
    implementation("org.springframework:spring-aspects")
    // /actuator/prometheus needs the registry; without it the endpoint is a 404.
    runtimeOnly("io.micrometer:micrometer-registry-prometheus")

    implementation("org.springframework.cloud:spring-cloud-starter-openfeign")
    implementation("org.springframework.cloud:spring-cloud-starter-circuitbreaker-resilience4j")

    implementation("org.springdoc:springdoc-openapi-starter-webmvc-ui:3.0.3")

    // Boot 4 split Liquibase auto-configuration out: liquibase-core alone never runs changesets.
    implementation("org.springframework.boot:spring-boot-liquibase")
    implementation("org.liquibase:liquibase-core")
    runtimeOnly("org.postgresql:postgresql")

    developmentOnly("org.springframework.boot:spring-boot-docker-compose")

    testCompileOnly("org.projectlombok:lombok")
    testAnnotationProcessor("org.projectlombok:lombok")
    testImplementation("org.springframework.boot:spring-boot-starter-test")
    testImplementation("org.springframework.boot:spring-boot-webmvc-test")
    testImplementation("org.springframework.boot:spring-boot-testcontainers")
    testImplementation("org.testcontainers:junit-jupiter")
    testImplementation("org.testcontainers:postgresql")
    testImplementation("org.instancio:instancio-junit:5.4.1")
    testImplementation("com.tngtech.archunit:archunit-junit5:1.4.2")
}

dependencyManagement {
    imports {
        mavenBom("org.springframework.cloud:spring-cloud-dependencies:${property("springCloudVersion")}")
        mavenBom("org.testcontainers:testcontainers-bom:1.21.4")
    }
}

springBoot {
    buildInfo()
}

tasks.bootJar {
    // Fixed name so the Dockerfile's COPY and the CI artifact upload never depend on the version string.
    archiveFileName = "app.jar"
}

tasks.withType<JavaCompile> {
    options.compilerArgs.add("-Amapstruct.defaultComponentModel=spring")
    options.encoding = "UTF-8"
}

val integrationPattern = "**/integration/**"

tasks.withType<Test>().configureEach {
    useJUnitPlatform()
    systemProperty("junit.jupiter.extensions.autodetection.enabled", true)
    systemProperty("file.encoding", "UTF-8")
    testLogging {
        events("failed")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
}

// Unit tests: no Docker, classes run concurrently inside one JVM.
tasks.test {
    exclude(integrationPattern)
    systemProperty("junit.jupiter.execution.parallel.enabled", true)
    systemProperty("junit.jupiter.execution.parallel.mode.default", "concurrent")
    systemProperty("junit.jupiter.execution.parallel.mode.classes.default", "concurrent")
}

// Integration tests: each fork boots its own Spring context and its own Postgres container, so forks never
// share a database. Classes inside one fork run sequentially.
val integrationTest by tasks.registering(Test::class) {
    description = "Runs Testcontainers-backed tests under src/test/java/**/integration/**."
    group = "verification"
    testClassesDirs = sourceSets.test.get().output.classesDirs
    classpath = sourceSets.test.get().runtimeClasspath
    include(integrationPattern)
    maxParallelForks = (Runtime.getRuntime().availableProcessors() / 2).coerceIn(1, 4)
    maxHeapSize = "1g"
    shouldRunAfter(tasks.test)
}

tasks.check {
    dependsOn(integrationTest)
    dependsOn(tasks.jacocoTestCoverageVerification)
}

val coverageExclusions = listOf(
    "com/example/company/Application.class",
    "com/example/company/config/**",
    "com/example/company/dto/**",
)

tasks.jacocoTestReport {
    dependsOn(tasks.test, integrationTest)
    executionData.setFrom(fileTree(layout.buildDirectory) { include("jacoco/*.exec") })
    reports {
        xml.required = true
        html.required = true
    }
    classDirectories.setFrom(classDirectories.files.map { fileTree(it) { exclude(coverageExclusions) } })
}

tasks.jacocoTestCoverageVerification {
    dependsOn(tasks.jacocoTestReport)
    executionData.setFrom(fileTree(layout.buildDirectory) { include("jacoco/*.exec") })
    classDirectories.setFrom(classDirectories.files.map { fileTree(it) { exclude(coverageExclusions) } })
    violationRules {
        rule {
            limit {
                counter = "INSTRUCTION"
                minimum = "0.60".toBigDecimal()
            }
        }
    }
}

spotless {
    java {
        target("src/*/java/**/*.java")
        // The version bundled with Spotless 7.2.1 crashes on JDK 25 class files.
        palantirJavaFormat("2.97.0")
        importOrder()
        removeUnusedImports()
        trimTrailingWhitespace()
        endWithNewline()
    }
    kotlinGradle {
        target("*.gradle.kts")
        ktlint()
    }
}
```

- [ ] **Step 3: Create `gradle.properties`:**

```properties
org.gradle.caching=true
org.gradle.parallel=true
org.gradle.configuration-cache=true
org.gradle.jvmargs=-Xmx2g -XX:+UseParallelGC
```

- [ ] **Step 4: Move the Instancio test** into `unit/` (`git mv`), adjust its `package` line to `com.example.company.unit` and import `com.example.company.support.Fixtures`.

- [ ] **Step 5: Generate the lockfile and run the build.**

```bash
./gradlew dependencies --write-locks -q
./gradlew build
./gradlew tasks --all -q | grep -q '^integrationTest' && echo OK
```
Expected: BUILD SUCCESSFUL; `OK`; `build/libs/app.jar` exists; `build/reports/tests/integrationTest/index.html` exists.

- [ ] **Step 6: Makefile** — change `test` to `./gradlew test`, add `itest: ./gradlew integrationTest`, `lock: ./gradlew dependencies --write-locks`, update `.PHONY`.

- [ ] **Step 7: Commit.**

```bash
git add build.gradle.kts gradle.properties gradle.lockfile Makefile src/test
git commit -m "build: fix Liquibase/Prometheus deps, split unit and integration tests" -m "..."
```

---

### Task 2: Version endpoint, build-info metric, management config

**Files:**
- Create: `src/main/java/com/example/company/controller/VersionController.java`
- Create: `src/main/java/com/example/company/config/BuildInfoMetrics.java`
- Create: `src/main/java/com/example/company/config/AppInfoProperties.java`
- Modify: `src/main/resources/application.yml`, `application-prod.yml`
- Create: `src/test/java/com/example/company/unit/BuildInfoMetricsTest.java`
- Create: `src/test/java/com/example/company/integration/VersionEndpointIntegrationTest.java`

**Interfaces:**
- Produces: `GET /version` → `{"version":"<APP_VERSION|local>","revision":"<APP_REVISION|dev>"}`; Prometheus series `app_build_info{version,revision}`; properties `app.info.version`, `app.info.revision`.

- [ ] **Step 1: Failing unit test**

```java
package com.example.company.unit;

import static org.assertj.core.api.Assertions.assertThat;

import com.example.company.config.AppInfoProperties;
import com.example.company.config.BuildInfoMetrics;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.junit.jupiter.api.Test;

class BuildInfoMetricsTest {

    @Test
    void registersBuildInfoGaugeWithVersionAndRevisionTags() {
        var registry = new SimpleMeterRegistry();
        new BuildInfoMetrics(new AppInfoProperties("1.2.3", "abc1234")).bindTo(registry);

        var gauge = registry.get("app.build.info").tags("version", "1.2.3", "revision", "abc1234").gauge();
        assertThat(gauge.value()).isEqualTo(1.0);
    }
}
```

- [ ] **Step 2: Run** `./gradlew test --tests '*BuildInfoMetricsTest'` → compile failure.

- [ ] **Step 3: Implement.**

`AppInfoProperties`:
```java
package com.example.company.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Build identity baked into the image by CI ({@code APP_VERSION}, {@code APP_REVISION} build args).
 *
 * @param version SemVer without the {@code v} prefix, or {@code local} outside CI
 * @param revision full git SHA, or {@code dev} outside CI
 */
@ConfigurationProperties(prefix = "app.info")
public record AppInfoProperties(String version, String revision) {}
```

`BuildInfoMetrics`:
```java
package com.example.company.config;

import io.micrometer.core.instrument.Gauge;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.binder.MeterBinder;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.stereotype.Component;

/**
 * Exposes {@code app_build_info{version,revision} 1}. One series per running build: Grafana reads the running
 * version from it and draws deploy markers where the label set changes. Tagging every metric with the version
 * would multiply series on each release; this convention (as in Prometheus' own {@code build_info}) does not.
 */
@Component
@EnableConfigurationProperties(AppInfoProperties.class)
public class BuildInfoMetrics implements MeterBinder {

    private final AppInfoProperties info;

    public BuildInfoMetrics(AppInfoProperties info) {
        this.info = info;
    }

    @Override
    public void bindTo(MeterRegistry registry) {
        Gauge.builder("app.build.info", () -> 1)
                .description("Build identity of the running process; always 1")
                .tag("version", info.version())
                .tag("revision", info.revision())
                .register(registry);
    }
}
```

`VersionController`:
```java
package com.example.company.controller;

import com.example.company.config.AppInfoProperties;
import java.util.Map;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/** Public build identity. CI's deploy job polls this until every replica reports the released revision. */
@RestController
public class VersionController {

    private final AppInfoProperties info;

    public VersionController(AppInfoProperties info) {
        this.info = info;
    }

    @GetMapping("/version")
    public Map<String, String> version() {
        return Map.of("version", info.version(), "revision", info.revision());
    }
}
```

`application.yml` additions:
```yaml
app:
  info:
    version: ${APP_VERSION:local}
    revision: ${APP_REVISION:dev}

management:
  server:
    # Same port locally; prod sets MANAGEMENT_PORT=8081 so actuator is never published or proxied.
    port: ${MANAGEMENT_PORT:${SERVER_PORT:8080}}
  endpoints:
    web:
      exposure:
        include: health,info,metrics,prometheus
  endpoint:
    health:
      show-details: always
      probes:
        enabled: true
  info:
    env:
      enabled: true
  metrics:
    tags:
      application: ${APP_NAME:spring-template}
      env: ${APP_ENV:local}
    distribution:
      slo:
        http.server.requests: 100ms,250ms,500ms,1s,2s,5s
info:
  app:
    version: ${APP_VERSION:local}
    revision: ${APP_REVISION:dev}
```
Remove the `resilience4j.retry` block (not wired to Feign). `application-prod.yml`: add `springdoc.api-docs.enabled: false`, `springdoc.swagger-ui.enabled: false`.

- [ ] **Step 4: Integration test**

```java
package com.example.company.integration;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MockMvc;

class VersionEndpointIntegrationTest extends AbstractIntegrationTest {

    private final MockMvc mockMvc;

    VersionEndpointIntegrationTest(MockMvc mockMvc) {
        this.mockMvc = mockMvc;
    }

    @Test
    void versionDefaultsToLocalOutsideCi() throws Exception {
        mockMvc.perform(get("/version"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.version").value("local"))
                .andExpect(jsonPath("$.revision").value("dev"));
    }

    @Test
    void prometheusEndpointExposesBuildInfo() throws Exception {
        mockMvc.perform(get("/actuator/prometheus"))
                .andExpect(status().isOk())
                .andExpect(result -> {
                    var body = result.getResponse().getContentAsString();
                    if (!body.contains("app_build_info{")) {
                        throw new AssertionError("app_build_info missing from:\n" + body);
                    }
                });
    }
}
```
Constructor injection in tests needs `@TestConstructor(autowireMode = ALL)` on `AbstractIntegrationTest`; add it there. Rewrite `SpringContextIntegrationTest` to constructor injection too.

- [ ] **Step 5: Run** `./gradlew spotlessApply test integrationTest` → PASS.
- [ ] **Step 6: Commit** `feat: expose /version and app_build_info for deploy tracking`.

---

### Task 3: Application hardening

**Files:**
- Modify: `config/GlobalExceptionHandler.java`, `config/BaseConfig.java`, `config/JobLoggingAspect.java`, `config/OpenApiConfig.java`, `config/FeignConfig.java`
- Create: `utils/SecretRedactor.java`, `config/RedactingFeignLogger.java`, `config/RequestResponseLoggingFilter.java`
- Modify: `TestcontainersConfiguration.java`, `architecture/ArchitectureTest.java`
- Delete: `model/.gitkeep`, `dto/request/.gitkeep`, `dto/response/.gitkeep`, `utils/.gitkeep`, `application-dev.yml`; create `dto/.gitkeep`
- Create tests: `unit/SecretRedactorTest.java`, `unit/GlobalExceptionHandlerTest.java` (`@WebMvcTest` with a throwing test controller)

**Steps (TDD per class):**

- [ ] `SecretRedactorTest`: `redact("Authorization: Bearer abc.def")` → `Authorization: Bearer ****`; `redact("{\"password\":\"x\",\"token\":\"y\",\"name\":\"n\"}")` keeps `name`, masks the other two; `redact("client_secret=abc&code=1")` masks both; `truncate("abcdef", 3)` → `abc…(+3)`. Implement with a small list of `Pattern`s (`(?i)(authorization:\s*)(bearer|basic)\s+\S+`, `(?i)"(password|token|secret|api[_-]?key|access_token|refresh_token|client_secret|code)"\s*:\s*"[^"]*"`, `(?i)\b(password|token|secret|api[_-]?key|client_secret|code)=([^&\s]+)`).
- [ ] `GlobalExceptionHandlerTest` (`@WebMvcTest(controllers = ThrowingController.class)` with `@Import(GlobalExceptionHandler.class)`): unknown path → 404 problem; `POST` on a GET route → 405; `?n=abc` on an `int` param → 400; controller throwing `FeignException` (build via `FeignException.errorStatus("x", Response.builder()...build())`) → 502 with detail `Upstream service unavailable` and no upstream text; `RuntimeException` → 500 `Something went wrong`.
- [ ] Implement the handler; delete the `RestClientException` handler.
- [ ] `BaseConfig`: `@EnableScheduling @EnableAsync`, `@Bean Clock clock() { return Clock.systemUTC(); }`.
- [ ] `JobLoggingAspect`: remove `@SneakyThrows`, `throws Throwable`.
- [ ] `RedactingFeignLogger extends feign.slf4j.Slf4jLogger`, overrides `log(String configKey, String format, Object... args)` to redact the formatted line; registered in `FeignConfig` as `@Bean feign.Logger` + `@Bean Logger.Level feignLoggerLevel() { return Logger.Level.HEADERS; }`.
- [ ] `RequestResponseLoggingFilter extends OncePerRequestFilter`, `@Component`, active only when `log.isDebugEnabled()`; wraps with `ContentCachingRequestWrapper`/`ContentCachingResponseWrapper`, logs method, uri, status, duration, redacted + truncated bodies (4096); `shouldNotFilter` for `/actuator`, `/swagger-ui`, `/v3/api-docs`, `/version`.
- [ ] `TestcontainersConfiguration`: `@Bean(name = "applicationTaskExecutor") Executor syncExecutor() { return new SyncTaskExecutor(); }` with Javadoc.
- [ ] `ArchitectureTest`: add optional `Job` layer (`..job..`) that may access Service; `noScheduledOutsideJob = methods().that().areAnnotatedWith(Scheduled.class).should().beDeclaredInClassesThat().resideInAPackage("..job..")`; `GeneralCodingRules.NO_CLASSES_SHOULD_ACCESS_STANDARD_STREAMS`, `NO_CLASSES_SHOULD_USE_JAVA_UTIL_LOGGING`; naming rules `.that().areNotAnonymousClasses().and().doNotHaveModifier(JavaModifier.SYNTHETIC)`.
- [ ] `OpenApiConfig`: `@Value("${app.openapi.contact-name:}")` etc.; omit contact/licence when blank.
- [ ] Delete `.gitkeep`s and `application-dev.yml`; update the README section later (Task 10).
- [ ] `./gradlew spotlessApply build` → PASS. Commit `refactor: harden error handling, add redaction and scheduling base config`.

---

### Task 4: Conventional commits → SemVer tooling

**Files:**
- Create: `scripts/lib.sh`, `scripts/next-version.sh`, `scripts/lint-commits.sh`, `.githooks/commit-msg`, `scripts/tests/next-version.test.sh`, `scripts/tests/lint-commits.test.sh`, `scripts/tests/run.sh`
- Modify: `Makefile` (`setup`, `test-scripts`, `release-name`)

**Interfaces:**
- Produces: `scripts/next-version.sh [--current]` prints `X.Y.Z` (no `v`); `scripts/lint-commits.sh <rev-range>` exits 1 listing bad subjects; `scripts/lint-commits.sh --message <file>` for the hook.

- [ ] **Step 1: Test file** `scripts/tests/next-version.test.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../next-version.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected '$2' got '$1' ($3)"; }

repo="$(mktemp -d)"; trap 'rm -rf "$repo"' EXIT
git -C "$repo" init -q -b main
git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
c() { git -C "$repo" commit -q --allow-empty -m "$1"; }

c "chore: init"
assert_eq "$("$script" -C "$repo")" "0.1.0" "no tag → 0.1.0"

git -C "$repo" tag v0.1.0
c "docs: readme"
assert_eq "$("$script" -C "$repo")" "0.1.1" "docs → patch"

c "feat: thing"
assert_eq "$("$script" -C "$repo")" "0.2.0" "feat → minor"

c "fix(deps-dev): bump x"
assert_eq "$("$script" -C "$repo")" "0.2.0" "fix after feat keeps minor"

c "feat!: breaking"
assert_eq "$("$script" -C "$repo")" "1.0.0" "bang → major"

git -C "$repo" tag v1.0.0
c "refactor: x"
git -C "$repo" commit -q --allow-empty -m "fix: y" -m "BREAKING CHANGE: api removed"
assert_eq "$("$script" -C "$repo")" "2.0.0" "footer → major"

# Highest tag wins even when an older tag is nearer in history.
git -C "$repo" tag v1.9.0 HEAD~1
assert_eq "$("$script" -C "$repo" --current)" "1.9.0" "version sort"
echo "next-version: all passed"
```

- [ ] **Step 2: Run** → fails (script missing).

- [ ] **Step 3: Implement `scripts/next-version.sh`:**

```bash
#!/usr/bin/env bash
# Prints the next SemVer (no "v") derived from conventional-commit subjects since the highest v* tag.
#   feat → minor, "!" or "BREAKING CHANGE:" footer → major, anything else → patch, no tag → 0.1.0
set -euo pipefail
dir="."; current_only=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -C) dir="$2"; shift 2 ;;
    --current) current_only=true; shift ;;
    *) echo "usage: $0 [-C dir] [--current]" >&2; exit 2 ;;
  esac
done
g() { git -C "$dir" "$@"; }

current="$(g tag -l 'v[0-9]*.[0-9]*.[0-9]*' | sed 's/^v//' | sort -V | tail -n1 || true)"
if $current_only; then echo "${current:-0.0.0}"; exit 0; fi
if [[ -z "$current" ]]; then echo "0.1.0"; exit 0; fi

range="v${current}..HEAD"
bump="patch"
while IFS= read -r subject; do
  [[ "$subject" =~ ^[a-z]+(\([^)]*\))?!: ]] && { bump="major"; break; }
  [[ "$subject" =~ ^feat(\([^)]*\))?: ]] && bump="minor"
done < <(g log --format=%s "$range")
if [[ "$bump" != "major" ]] && g log --format=%b "$range" | grep -q '^BREAKING CHANGE:'; then bump="major"; fi

IFS=. read -r major minor patch <<< "$current"
case "$bump" in
  major) echo "$((major + 1)).0.0" ;;
  minor) echo "${major}.$((minor + 1)).0" ;;
  patch) echo "${major}.${minor}.$((patch + 1))" ;;
esac
```

- [ ] **Step 4: `scripts/lint-commits.sh`** — regex `^(feat|fix|perf|refactor|docs|test|build|ci|chore|style|revert)(\([a-z0-9._/-]+\))?!?: .+` plus allow `^Merge ` and `^Revert "`. Modes: `--message <file>` (hook) and `<range>` (`git log --format=%s range`). Prints each offending subject and the rule; exit 1 on any. Test file: good subjects pass (`build(deps-dev): bump x`, `feat!: y`, `Merge branch 'x'`), bad fail (`Add thing`, `feat:no space`, `Feat: caps`).

- [ ] **Step 5: `.githooks/commit-msg`:** `exec "$(git rev-parse --show-toplevel)/scripts/lint-commits.sh" --message "$1"`. `chmod +x` all scripts.

- [ ] **Step 6: `scripts/tests/run.sh`** runs every `*.test.sh`. **Makefile:** `setup: git config core.hooksPath .githooks` (echo once), `test-scripts: scripts/tests/run.sh`, `release-name: scripts/next-version.sh`; `run`, `test`, `build` depend on `setup`.

- [ ] **Step 7: Run** `make test-scripts` → all passed. Commit `feat: derive SemVer from conventional commits and enforce the format`.

---

### Task 5: Runtime-only Dockerfile and local compose

**Files:**
- Rewrite: `Dockerfile`, `.dockerignore`
- Rename: `docker-compose.yml` → `compose.yml` (rewrite)
- Modify: `Makefile` (`image`, `up`, `observability-up/down`), `application.yml` (`spring.docker.compose.file: compose.yml` not needed — Boot finds `compose.yml` by default; remove `docker-compose.yml` reference in comments)

- [ ] **Step 1: Dockerfile**

```dockerfile
# syntax=docker/dockerfile:1
# Runtime-only image. CI builds the jar once (native speed) and this stage merely packages it, which is what
# makes an amd64+arm64 manifest cheap. Locally: `make image` (runs bootJar first).
FROM eclipse-temurin:25-jre

ARG APP_VERSION=local
ARG APP_REVISION=dev
ENV APP_VERSION=${APP_VERSION} \
    APP_REVISION=${APP_REVISION} \
    JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError"

# curl: the compose healthcheck. Nothing else is added to the base image.
RUN apt-get update \
    && apt-get install --no-install-recommends -y curl \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --system spring && useradd --system --gid spring spring
WORKDIR /application
COPY --chown=spring:spring build/libs/app.jar application.jar
USER spring:spring

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
  CMD curl -sf "http://127.0.0.1:${MANAGEMENT_PORT:-8080}/actuator/health" || exit 1
ENTRYPOINT ["java", "-jar", "application.jar"]
```

`.dockerignore`: `*` then `!build/libs/app.jar`.

- [ ] **Step 2: `compose.yml`** — services `db` (as spec), `app` (profile `full`, `build: .`), `prometheus`, `grafana`, `alloy` (profile `observability`) using paths `./deploy/grafana/provisioning`, `./deploy/grafana/dashboards`, `./deploy/alloy/config.alloy` (created in Task 7; compose validates mounts only at `up`). Grafana env: `GF_AUTH_ANONYMOUS_ENABLED=true`, `GF_AUTH_ANONYMOUS_ORG_ROLE=Admin`, `GF_AUTH_DISABLE_LOGIN_FORM=true`. Alloy env: `GRAFANA_CLOUD_PROM_URL=http://prometheus:9090/api/v1/write`, `GRAFANA_CLOUD_PROM_USER=local`, `GRAFANA_CLOUD_PROM_TOKEN=local`, `APP_METRICS_HOST=host.docker.internal`, `APP_METRICS_PORT=8080`, `APP_ENV=local`, `extra_hosts: ["host.docker.internal:host-gateway"]`.

- [ ] **Step 3: Makefile:** `image: ./gradlew bootJar -q && docker build -t $(APP_NAME) .`; `up: ./gradlew bootJar -q && docker compose --env-file $(ENV_FILE) --profile full up --build -d`; `observability-up: docker compose --profile observability up -d`; `observability-down`. `APP_NAME := $(shell basename $(CURDIR))`.

- [ ] **Step 4: Verify**

```bash
make image && docker run --rm -d -p 18080:8080 --name tpl -e DB_URL=jdbc:postgresql://127.0.0.1:1/x $(basename $PWD) ; sleep 1; docker logs tpl | head -3; docker rm -f tpl
docker compose config -q
```
Image builds; container starts (it will fail on DB, that is fine — we only check the jar runs); compose config validates.

- [ ] **Step 5: Commit** `build: package a runtime-only image and add the local observability profile`.

---

### Task 6: `deploy/` — prod compose, Caddy, backup, env example, init script, Makefile

**Files:**
- Create: `deploy/compose.prod.yml`, `deploy/Caddyfile`, `deploy/backup/Dockerfile`, `deploy/backup/backup.sh`, `deploy/.env.prod.example`, `scripts/init-prod-env.sh`, `scripts/tests/init-prod-env.test.sh`, `scripts/tests/fixtures/env.prod.test`
- Modify: `Makefile`, `.gitignore`

- [ ] **Step 1: Test** `scripts/tests/init-prod-env.test.sh`: temp repo with remote `git@github.com:Owner/My-Repo.git`, copy `deploy/.env.prod.example`, run `printf 'yes\n' | scripts/init-prod-env.sh` with `HOME`/cwd set to the temp repo; assert `deploy/.env.prod` has `APP_IMAGE=ghcr.io/owner/my-repo`, `COMPOSE_PROJECT_NAME=my-repo`, `POSTGRES_PASSWORD=` 48 hex chars, mode `600`; second run without `--force` exits 1 and leaves the file untouched; `printf 'no\n'` exits 1 with no file.

- [ ] **Step 2: Implement `scripts/init-prod-env.sh`** (banner, `read -r answer`, `[[ $answer == yes ]]`, `openssl rand -hex 24`, remote parsing `sed -E 's#^(git@github.com:|https://github.com/)##; s#\.git$##' | tr A-Z a-z`, `sed -i` replacements for `APP_IMAGE=`, `COMPOSE_PROJECT_NAME=`, `POSTGRES_PASSWORD=`, `chmod 600`, final "still to fill" list).

- [ ] **Step 3: `deploy/.env.prod.example`** grouped: REQUIRED (`DOMAIN`, `ACME_EMAIL`, `POSTGRES_PASSWORD`), FILLED BY init (`APP_IMAGE`, `COMPOSE_PROJECT_NAME`), OBSERVABILITY (`COMPOSE_PROFILES=` commented, `GRAFANA_CLOUD_PROM_URL/USER/TOKEN`), TUNING (`APP_IMAGE_TAG=latest`, `APP_REPLICAS=2`, `APP_MEM_LIMIT=512m`, `DB_POOL_SIZE=5`, `POSTGRES_DB=app`, `POSTGRES_USER=app`, `POSTGRES_HOST_PORT=5432`, `WATCHTOWER_POLL_INTERVAL=60`, `BACKUP_DIR=./backups`, `BACKUP_INTERVAL_SECONDS=86400`, `BACKUP_RETENTION_DAYS=14`, `DOCKER_CONFIG_DIR=`). Every key has a one-line comment saying what reads it.

- [ ] **Step 4: `deploy/compose.prod.yml`** exactly per spec Section 2 table. **`deploy/Caddyfile`** per spec. **`deploy/backup/*`** per spec (alpine:3.21, `postgresql17-client`).

- [ ] **Step 5: Validate**

```bash
docker compose -f deploy/compose.prod.yml --env-file scripts/tests/fixtures/env.prod.test config -q
docker run --rm -v "$PWD/deploy/Caddyfile:/etc/caddy/Caddyfile:ro" -e DOMAIN=example.com -e ACME_EMAIL=a@b.c caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile
docker build -q deploy/backup
bash -n deploy/backup/backup.sh
```
All exit 0. Add the first two commands to `scripts/tests/deploy-config.test.sh` (skips with a notice if docker is absent).

- [ ] **Step 6: Makefile** prod targets per spec; `.gitignore` add `deploy/.env.prod`, `deploy/backups/`. Commit `feat: add single-VPS production stack with Caddy, Watchtower and backups`.

---

### Task 7: Observability assets and push script

**Files:**
- Create: `deploy/alloy/config.alloy`, `deploy/grafana/provisioning/datasources.yml`, `deploy/grafana/provisioning/dashboards.yml`, `deploy/grafana/dashboards/app-overview.json`, `deploy/grafana/alerting/contact-point.json`, `deploy/grafana/alerting/notification-policy.json`, `deploy/grafana/alerting/rules.json`, `scripts/grafana-push.sh`, `scripts/tests/grafana-push.test.sh`
- Create: `src/test/java/com/example/company/unit/DashboardJsonTest.java`
- Modify: `Makefile` (`grafana-push`, `grafana-pull`)

- [ ] **Step 1: `DashboardJsonTest`** (failing: files missing). Uses Jackson (`ObjectMapper` from starter-test classpath) to walk `deploy/grafana/**/*.json`; asserts each parses; every `datasource.uid` equals `grafanacloud-prom`; collects every `expr`/`model.expr` string and asserts it matches `(app_build_info|http_server_requests_seconds|jvm_|hikaricp_|logback_events_total|process_|system_cpu|up\b|resilience4j_)`; dashboard `uid` is `app-overview`; templating contains variable `env`.

- [ ] **Step 2: Alloy config** per spec (`discovery.dns`, `prometheus.scrape`, `prometheus.remote_write`, `coalesce(sys.env(...), default)`).

- [ ] **Step 3: Provisioning YAMLs** per spec.

- [ ] **Step 4: Dashboard JSON.** Schema version 39, `uid: app-overview`, `title: App overview`, `time: now-6h`, `refresh: 30s`. Templating: `env` (query `label_values(app_build_info, env)`, multi false, includeAll false). Annotations: `changes(app_build_info{env="$env"}[2m]) > 0`, `titleFormat: deploy {{version}}`, `iconColor: green`. Panels (all `datasource: {type: prometheus, uid: grafanacloud-prom}`):

| Row | Panel | expr |
|---|---|---|
| Overview | Running version (stat, `textMode: name`, legend `{{version}}`) | `max by (version) (app_build_info{env="$env"})` |
| | Instances up (stat) | `count(up{env="$env"} == 1)` |
| | Uptime (stat, unit s) | `max(process_uptime_seconds{env="$env"})` |
| HTTP | Requests/s (timeseries) | `sum(rate(http_server_requests_seconds_count{env="$env"}[5m]))` |
| | 5xx % (timeseries, unit percent) | `100 * sum(rate(http_server_requests_seconds_count{env="$env",status=~"5.."}[5m])) / sum(rate(http_server_requests_seconds_count{env="$env"}[5m]))` |
| | Latency p50/p95/p99 (timeseries, unit s) | `histogram_quantile(0.5, sum by (le) (rate(http_server_requests_seconds_bucket{env="$env"}[5m])))` (×3) |
| | Slowest URIs (table) | `topk(10, sum by (uri) (rate(http_server_requests_seconds_sum{env="$env"}[5m])) / sum by (uri) (rate(http_server_requests_seconds_count{env="$env"}[5m])))` |
| JVM | Heap used vs max (timeseries, bytes) | `sum(jvm_memory_used_bytes{env="$env",area="heap"})`, `sum(jvm_memory_max_bytes{env="$env",area="heap"})` |
| | GC pause (timeseries, s) | `sum(rate(jvm_gc_pause_seconds_sum{env="$env"}[5m]))` |
| | Threads (timeseries) | `sum(jvm_threads_live_threads{env="$env"})` |
| | CPU (timeseries, percentunit) | `avg(process_cpu_usage{env="$env"})`, `avg(system_cpu_usage{env="$env"})` |
| DB | Hikari connections (timeseries) | `sum(hikaricp_connections_active{env="$env"})`, `..._idle`, `..._pending` |
| | Acquire time p95 (timeseries, s) | `histogram_quantile(0.95, sum by (le) (rate(hikaricp_connections_acquire_seconds_bucket{env="$env"}[5m])))` |
| Logs | Log events/s by level (timeseries) | `sum by (level) (rate(logback_events_total{env="$env"}[5m]))` |
| Resilience | Circuit breaker state (state-timeline) | `max by (name, state) (resilience4j_circuitbreaker_state{env="$env"} == 1)` |

- [ ] **Step 5: Alerting JSON** — contact point `{"name":"telegram","type":"telegram","settings":{"bottoken":"${TELEGRAM_BOT_TOKEN}","chatid":"${TELEGRAM_CHAT_ID}"}}`; policy `{"receiver":"telegram","group_by":["alertname"],"group_wait":"30s","repeat_interval":"4h"}`; rules per spec with `folderUID: app`, `ruleGroup: app-baseline`, `for` durations, `noDataState: Alerting` for ServiceDown only, `execErrState: Error`.

- [ ] **Step 6: `scripts/grafana-push.sh`** with a stubbed-`curl` test (`scripts/tests/grafana-push.test.sh` puts a fake `curl` on `PATH` that records args to a file; asserts folder create, dashboard POST with `overwrite:true`, alerting skipped without Telegram vars, URL has no `//api`, `local` sends no auth header). `pull` writes the JSON with `id`/`version` removed (`jq 'del(.dashboard.id, .dashboard.version) | .dashboard'`; script requires `jq`).

- [ ] **Step 7: Verify locally**

```bash
make observability-up
./gradlew bootRun &   # wait for start
sleep 20; curl -s localhost:9090/api/v1/query?query=app_build_info | jq .data.result[0].metric
curl -s localhost:3000/api/dashboards/uid/app-overview | jq .dashboard.title
```
Expected: metric with `version:"local"`; title `App overview`. Stop bootRun, `make observability-down`. Run `./gradlew test --tests '*DashboardJsonTest'` → PASS. Commit `feat: add Grafana dashboard, alerting, Alloy config and push script`.

---

### Task 8: GitHub workflows and Dependabot

**Files:**
- Rewrite: `.github/workflows/ci.yml`
- Create: `.github/workflows/security-weekly.yml`, `.github/workflows/dashboards.yml`, `.github/dependabot.yml`, `.trivyignore.yaml`
- Delete: `renovate.json`

- [ ] **Step 1: Resolve action SHAs** with `gh api repos/<owner>/<repo>/git/ref/tags/<tag>` (or `git ls-remote --tags`), for: `actions/checkout` v4, `actions/setup-java` v4, `gradle/actions/setup-gradle` v4, `actions/upload-artifact` v4, `actions/download-artifact` v4, `docker/setup-qemu-action` v3, `docker/setup-buildx-action` v3, `docker/login-action` v3, `docker/metadata-action` v5, `docker/build-push-action` v6, `softprops/action-gh-release` v2, `actions/github-script` v7, `aquasecurity/trivy-action` (latest 0.x), `gitleaks/gitleaks-action` v2 (or `docker run ghcr.io/gitleaks/gitleaks`), `astral-sh/setup-uv` v5 (for `uvx zizmor`). Record the tag next to each SHA.

- [ ] **Step 2: Write `ci.yml`** per spec Section 1 (jobs `build`, `security-fast`, `image`, `release`, `deploy`). Key details:
  - `build`: `./gradlew build --scan=false`; `scripts/tests/run.sh`; `scripts/lint-commits.sh ${{ github.event.pull_request.base.sha }}..HEAD` on PRs (fetch-depth 0) and `$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || git rev-list --max-parents=0 HEAD)..HEAD` on main; upload `build/libs/app.jar` as `jar`.
  - `image`: `download-artifact` into `build/libs/`; `VERSION=$(scripts/next-version.sh)`; metadata-action tags:
    ```
    type=raw,value=latest,enable={{is_default_branch}}
    type=raw,value=${{ steps.ver.outputs.version }},enable={{is_default_branch}}
    type=raw,value=${{ steps.ver.outputs.minor }},enable={{is_default_branch}}
    type=sha,prefix=sha-,format=short
    ```
    outputs `version`, `revision`, `image`, `digest`.
  - `release`: `git tag v$VERSION && git push origin v$VERSION` (with `contents: write` token), then `softprops/action-gh-release` with `tag_name: v$VERSION`, `generate_release_notes: true`, body with image tag, digest, rollback snippet (`make prod-rollback TAG=<previous>`).
  - `deploy`: as spec; jq for `.revision`.
- [ ] **Step 3: `security-weekly.yml`**, **`dashboards.yml`**, **`dependabot.yml`**, **`.trivyignore.yaml`** (empty with a header comment) per spec.
- [ ] **Step 4: Lint** — `docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest` and `uvx zizmor .github/workflows` (or `docker run ghcr.io/woodruffw/zizmor`), fix findings. Delete `renovate.json`.
- [ ] **Step 5: Commit** `ci: publish versioned images and releases, add fast and weekly security lanes`.

---

### Task 9: VPS script, Claude skills, rename script

**Files:**
- Create: `scripts/vps.sh`, `scripts/rename-package.sh`, `scripts/tests/vps.test.sh`, `scripts/tests/rename-package.test.sh`
- Create: `.claude/skills/vps-db/SKILL.md`, `.claude/skills/grafana/SKILL.md`, `.claude/skills/release/SKILL.md`
- Modify: `.env.example` (add `VPS_SSH`, `VPS_APP_DIR`, `VPS_DB_LOCAL_PORT`, `GRAFANA_URL`, `GRAFANA_API_TOKEN`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, `APP_ENV` — all commented with purpose), `Makefile` (`vps-ssh`, `vps-psql`, `vps-datagrip`, `vps-logs`, `rename`)

- [ ] **Step 1: `vps.test.sh`** — puts a fake `ssh` on PATH that echoes its args and, for the `cat deploy/.env.prod` call, prints a fixture env; asserts `vps.sh env` masks values (`POSTGRES_PASSWORD=****`), `vps.sh datagrip --no-tunnel --no-clipboard` prints `jdbc:postgresql://localhost:15432/app?user=app&password=s3cret`, missing `VPS_SSH` exits 2 with a hint.
- [ ] **Step 2: Implement `scripts/vps.sh`** per spec Section 4. Remote reads use `ssh "$VPS_SSH" "cat '$VPS_APP_DIR/deploy/.env.prod'"`; parsing via `grep -E '^KEY=' | cut -d= -f2-`. Tunnel: `ssh -f -N -o ExitOnForwardFailure=yes -L "$local:127.0.0.1:$remote_port" "$VPS_SSH"`; PID via `pgrep -f`. `psql` fallback to `docker run --rm -it --network host postgres:17-alpine psql`.
- [ ] **Step 3: `rename-package.test.sh`** — copies the repo (`git worktree`-free: `git archive HEAD | tar -x -C tmp`), runs `scripts/rename-package.sh com.acme.shop shop`, asserts `src/main/java/com/acme/shop/Application.java` exists, no `com.example.company` string remains under `src/`, `build.gradle.kts`, `settings.gradle.kts`, `compose.yml`, `.env.example`; `rootProject.name = "shop"`. Implement with `git mv`-free `mkdir -p && mv`, `grep -rl | xargs sed -i`, refuse when `git status --porcelain` is non-empty.
- [ ] **Step 4: Skills** — three `SKILL.md` with frontmatter `name`, `description` (trigger phrases), sections: when to use, commands, rules, what never to do. Content per spec Section 4.
- [ ] **Step 5: Run** `make test-scripts` → PASS; run `scripts/rename-package.sh` in the test only. Commit `feat: add VPS access, rename script and Claude skills`.

---

### Task 10: Documentation, CLAUDE.md, gitignore, final verification

**Files:**
- Rewrite: `README.md`
- Create: `docs/deployment.md`, `docs/observability.md`, `CLAUDE.md`
- Modify: `.gitignore` (`!/CLAUDE.md`)

- [ ] **Step 1:** Write the three docs and CLAUDE.md per spec Section 6. README must not mention retry, must show the checklist table and the 6 prod commands, and link the docs.
- [ ] **Step 2:** Every command shown in README/CLAUDE.md exists in `Makefile` — check with `grep -o 'make [a-z-]*' README.md CLAUDE.md docs/*.md | sort -u` vs `make help`.
- [ ] **Step 3: Full verification**

```bash
./gradlew spotlessApply build
make test-scripts
docker compose config -q
docker compose -f deploy/compose.prod.yml --env-file scripts/tests/fixtures/env.prod.test config -q
make image
git status --short   # only intended files
```
- [ ] **Step 4: Commit** `docs: rewrite README, add deployment and observability runbooks and CLAUDE.md`.
