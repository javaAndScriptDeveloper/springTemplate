// Root build: plugin versions for every service (applied per service) and formatting for every Gradle script.
// Services live under services/<name>/ and are discovered by settings.gradle.kts; bricks under bricks/<name>/ may
// contribute dependencies through brick.gradle.kts (bricks/README.md).
plugins {
    id("org.springframework.boot") version "4.1.0" apply false
    id("io.spring.dependency-management") version "1.1.7" apply false
    id("com.diffplug.spotless") version "7.2.1"
}

// Spotless resolves ktlint from here; the services declare their own repositories.
repositories {
    mavenCentral()
}

spotless {
    kotlinGradle {
        target("*.gradle.kts", "services/*/*.gradle.kts", "bricks/*/*.gradle.kts")
        ktlint()
    }
}
