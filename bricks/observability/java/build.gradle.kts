// observability brick, Gradle project :bricks:observability (included by settings.gradle.kts while the brick is
// enabled). No production code: it only guards the committed Grafana assets (DashboardJsonTest).
plugins {
    id("java")
    id("io.spring.dependency-management")
    id("com.diffplug.spotless")
}

java {
    toolchain {
        languageVersion = JavaLanguageVersion.of(25)
    }
}

repositories {
    mavenCentral()
}

// `./gradlew :bricks:observability:dependencies --write-locks` refreshes gradle.lockfile next to this file.
dependencyLocking {
    lockAllConfigurations()
}

// Security bumps ahead of the Boot BOM (trivy fails the build on fixable HIGH/CRITICAL CVEs). Drop each override
// once the BOM catches up; `./gradlew :bricks:observability:dependencyInsight --dependency jackson-core` shows what is in effect.
extra["jackson-bom.version"] = "3.1.7"
extra["jackson-2-bom.version"] = "2.21.7"

dependencyManagement {
    imports {
        mavenBom(org.springframework.boot.gradle.plugin.SpringBootPlugin.BOM_COORDINATES)
    }
}

dependencies {
    // JUnit and AssertJ; Boot 4's test starter ships Jackson 3 only, the test reads JSON with Jackson 2 databind.
    testImplementation("org.springframework.boot:spring-boot-starter-test")
    // Gradle 9 no longer supplies the JUnit launcher itself (the Boot plugin does it for the app).
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
    testImplementation("com.fasterxml.jackson.core:jackson-databind")
}

spotless {
    java {
        target("src/*/java/**/*.java")
        palantirJavaFormat("2.97.0")
        importOrder()
        removeUnusedImports()
        trimTrailingWhitespace()
        endWithNewline()
    }
}

tasks.withType<Test>().configureEach {
    useJUnitPlatform()
    systemProperty("repo.root", rootDir.absolutePath)
}
