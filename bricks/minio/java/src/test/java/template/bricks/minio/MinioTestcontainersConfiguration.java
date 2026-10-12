package template.bricks.minio;

import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.test.context.DynamicPropertyRegistrar;
import org.testcontainers.containers.MinIOContainer;
import org.testcontainers.utility.DockerImageName;

/** A MinIO container for integration tests of the minio brick. */
@TestConfiguration(proxyBeanMethods = false)
public class MinioTestcontainersConfiguration {

    @Bean
    MinIOContainer minioContainer() {
        // Chainguard's build: MinIO Inc. no longer publishes minio/minio. It is real MinIO, so substitute the name.
        return new MinIOContainer(
                DockerImageName.parse("cgr.dev/chainguard/minio:latest").asCompatibleSubstituteFor("minio/minio"));
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
