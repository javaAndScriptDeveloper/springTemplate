import java.time.Duration

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
        // Gradle auto-provisions this JDK via the foojay resolver (settings.gradle.kts)
        languageVersion = JavaLanguageVersion.of(25)
    }
}

repositories {
    mavenCentral()
}

// Reproducible builds: every configuration is pinned in gradle.lockfile, which Trivy also scans in CI.
// `make lock` refreshes it after changing dependencies.
dependencyLocking {
    lockAllConfigurations()
}

extra["springCloudVersion"] = "2025.1.2"

dependencies {
    // Lombok
    compileOnly("org.projectlombok:lombok")
    annotationProcessor("org.projectlombok:lombok")
    annotationProcessor("org.projectlombok:lombok-mapstruct-binding:0.2.0")

    // MapStruct
    implementation("org.mapstruct:mapstruct:1.6.3")
    annotationProcessor("org.mapstruct:mapstruct-processor:1.6.3")

    // Spring Boot Starters
    implementation("org.springframework.boot:spring-boot-starter-web")
    implementation("org.springframework.boot:spring-boot-starter-data-jpa")
    implementation("org.springframework.boot:spring-boot-starter-validation")
    implementation("org.springframework.boot:spring-boot-starter-actuator")
    implementation("org.springframework.boot:spring-boot-starter-cache")
    // Caffeine backs the cache abstraction above (starter-cache alone only ships a simple in-memory map)
    implementation("com.github.ben-manes.caffeine:caffeine")
    // AOP: Boot 4 dropped spring-boot-starter-aop; spring-aspects pulls AspectJ + enables @Aspect support
    implementation("org.springframework:spring-aspects")
    // /actuator/prometheus needs a registry; without this the endpoint is a 404 even though it is exposed.
    runtimeOnly("io.micrometer:micrometer-registry-prometheus")

    // Spring Cloud
    implementation("org.springframework.cloud:spring-cloud-starter-openfeign")
    // Resilience4j circuit breaker, integrated with Feign via spring.cloud.openfeign.circuitbreaker.enabled
    implementation("org.springframework.cloud:spring-cloud-starter-circuitbreaker-resilience4j")

    // API Documentation (OpenAPI 3 / Swagger UI)
    implementation("org.springdoc:springdoc-openapi-starter-webmvc-ui:3.0.3")

    // Database migration. Boot 4 moved Liquibase auto-configuration into its own module: liquibase-core
    // alone is on the classpath but never runs a changeset.
    implementation("org.springframework.boot:spring-boot-liquibase")
    implementation("org.liquibase:liquibase-core")

    // PostgreSQL Driver
    runtimeOnly("org.postgresql:postgresql")

    // Local development: manage compose.yml lifecycle automatically on bootRun
    developmentOnly("org.springframework.boot:spring-boot-docker-compose")

    // Test Dependencies (JUnit 5, AssertJ, Mockito, JSONassert ship with starter-test)
    testCompileOnly("org.projectlombok:lombok")
    testAnnotationProcessor("org.projectlombok:lombok")
    testImplementation("org.springframework.boot:spring-boot-starter-test")
    // Boot 4 split MockMvc test support (@AutoConfigureMockMvc, @WebMvcTest) into its own module
    testImplementation("org.springframework.boot:spring-boot-webmvc-test")

    // Integration testing against a real PostgreSQL via Testcontainers
    testImplementation("org.springframework.boot:spring-boot-testcontainers")
    testImplementation("org.testcontainers:junit-jupiter")
    testImplementation("org.testcontainers:postgresql")

    // Random, fully-populated test objects — the project convention over hand-built fixtures
    testImplementation("org.instancio:instancio-junit:5.4.1")
    // Architecture rules enforced as tests (layering, naming, no field injection)
    testImplementation("com.tngtech.archunit:archunit-junit5:1.4.2")
}

dependencyManagement {
    imports {
        mavenBom("org.springframework.cloud:spring-cloud-dependencies:${property("springCloudVersion")}")
        // Boot 4.1 no longer manages Testcontainers versions; pin them via the Testcontainers BOM.
        mavenBom("org.testcontainers:testcontainers-bom:1.21.4")
    }
}

// Populate /actuator/info with build metadata
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
    // A hung Docker daemon once stalled a fork for an hour; fail fast instead of burning CI minutes.
    timeout = Duration.ofMinutes(20)
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

// Integration tests: each fork boots its own Spring context and therefore its own Postgres container
// (see TestcontainersConfiguration), so forks never share a database. Classes inside one fork run sequentially.
val integrationTest =
    tasks.register<Test>("integrationTest") {
        description = "Runs Testcontainers-backed tests under src/test/java/**/integration/**."
        group = "verification"
        testClassesDirs =
            sourceSets.test
                .get()
                .output.classesDirs
        classpath = sourceSets.test.get().runtimeClasspath
        include(integrationPattern)
        maxParallelForks = (Runtime.getRuntime().availableProcessors() / 2).coerceIn(1, 4)
        maxHeapSize = "1g"
        shouldRunAfter(tasks.test)
    }

// Classes with no meaningful branches to cover — excluded from the coverage report and gate.
val coverageExclusions =
    listOf(
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
    classDirectories.setFrom(
        classDirectories.files.map {
            fileTree(it) { exclude(coverageExclusions) }
        },
    )
}

tasks.jacocoTestCoverageVerification {
    dependsOn(tasks.jacocoTestReport)
    executionData.setFrom(fileTree(layout.buildDirectory) { include("jacoco/*.exec") })
    classDirectories.setFrom(
        classDirectories.files.map {
            fileTree(it) { exclude(coverageExclusions) }
        },
    )
    violationRules {
        rule {
            limit {
                counter = "INSTRUCTION"
                // Raised to 0.60 in the hardening task once the redactor and handler tests exist.
                minimum = "0.0".toBigDecimal()
            }
        }
    }
}

tasks.check {
    dependsOn(integrationTest)
    dependsOn(tasks.jacocoTestCoverageVerification)
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
