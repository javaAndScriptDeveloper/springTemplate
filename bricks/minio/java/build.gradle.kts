// minio brick, Gradle project :bricks:minio (included by settings.gradle.kts while the brick is enabled).
// Beans are registered through META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports;
// the application only needs `implementation(project(":bricks:minio"))` (brick.gradle.kts next to this directory).
plugins {
    id("java-library")
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

// `./gradlew :bricks:minio:dependencies --write-locks` refreshes gradle.lockfile next to this file.
dependencyLocking {
    lockAllConfigurations()
}

// Security bumps ahead of the Boot BOM (trivy fails the build on fixable HIGH/CRITICAL CVEs). Drop each override
// once the BOM catches up; `./gradlew :bricks:minio:dependencyInsight --dependency jackson-core` shows what is in effect.
extra["jackson-bom.version"] = "3.1.7"
extra["jackson-2-bom.version"] = "2.21.7"
extra["netty.version"] = "4.2.17.Final"
extra["httpcore5.version"] = "5.4.3"

dependencyManagement {
    imports {
        mavenBom(org.springframework.boot.gradle.plugin.SpringBootPlugin.BOM_COORDINATES)
        // Boot 4.1 no longer manages Testcontainers versions; pin them via the Testcontainers BOM.
        mavenBom("org.testcontainers:testcontainers-bom:1.21.4")
    }
}

dependencies {
    compileOnly("org.projectlombok:lombok")
    annotationProcessor("org.projectlombok:lombok")
    // AWS SDK classes carry Jackson 2 annotations (@JsonInclude); without them javac warns "unknown enum constant".
    compileOnly("com.fasterxml.jackson.core:jackson-annotations")

    // S3Client and S3Presigner appear in the public beans, so consumers see the SDK.
    api("software.amazon.awssdk:s3:2.55.13")
    implementation("org.springframework.boot:spring-boot-starter")
    // HealthIndicator; the brick stays web-free, spring-web is here only for ResponseStatusException.
    implementation("org.springframework.boot:spring-boot-health")
    implementation("org.springframework:spring-web")

    testCompileOnly("org.projectlombok:lombok")
    testAnnotationProcessor("org.projectlombok:lombok")
    testImplementation("org.springframework.boot:spring-boot-starter-test")
    // Gradle 9 no longer supplies the JUnit launcher itself (the Boot plugin does it for the app).
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
    testImplementation("org.springframework.boot:spring-boot-testcontainers")
    testImplementation("org.testcontainers:junit-jupiter")
    testImplementation("org.testcontainers:minio")
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
