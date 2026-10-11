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
