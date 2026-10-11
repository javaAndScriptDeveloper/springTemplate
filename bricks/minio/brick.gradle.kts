// minio brick: S3 client (MinIO, Hetzner Object Storage or AWS) and a MinIO Testcontainer for integration tests.
dependencies {
    "implementation"("software.amazon.awssdk:s3:2.46.7")
    "testImplementation"("org.testcontainers:minio")
}
