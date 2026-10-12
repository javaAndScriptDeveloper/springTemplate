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

// A brick with Java (bricks/<name>/java/build.gradle.kts) is a Gradle project :bricks:<name> while it is listed in
// .bricks (bricks/README.md); `make add` / `make remove` edit that file, nothing is copied into a service.
file(".bricks")
    .takeIf { it.isFile }
    ?.readLines()
    ?.map { it.substringBefore('#').trim() }
    ?.filter { it.isNotEmpty() }
    ?.forEach { name ->
        val dir = file("bricks/$name")
        require(dir.isDirectory) { "brick '$name' is listed in .bricks but bricks/$name does not exist" }
        if (File(dir, "java/build.gradle.kts").isFile) {
            include("bricks:$name")
            project(":bricks:$name").projectDir = File(dir, "java")
        }
    }
