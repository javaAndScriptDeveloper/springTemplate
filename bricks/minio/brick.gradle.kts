// minio brick: the application depends on the brick's Gradle project; its own build file owns the dependencies.
dependencies {
    "implementation"(project(":bricks:minio"))
}
