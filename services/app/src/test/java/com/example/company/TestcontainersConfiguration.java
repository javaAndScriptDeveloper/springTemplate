package com.example.company;

import java.util.concurrent.Executor;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.springframework.context.annotation.Bean;
import org.springframework.core.task.SyncTaskExecutor;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.utility.DockerImageName;

/**
 * Provides the container-backed infrastructure used by tests. The {@link ServiceConnection} annotation wires the
 * container's JDBC connection details into Spring Boot automatically — no manual {@code spring.datasource.*} needed.
 */
@TestConfiguration(proxyBeanMethods = false)
public class TestcontainersConfiguration {

    @Bean
    @ServiceConnection
    PostgreSQLContainer<?> postgresContainer() {
        return new PostgreSQLContainer<>(DockerImageName.parse("postgres:17-alpine"));
    }

    /**
     * Runs {@code @Async} work on the calling thread so a test can assert on its outcome right after the call, instead
     * of polling for a background thread to finish.
     */
    @Bean(name = "applicationTaskExecutor")
    Executor applicationTaskExecutor() {
        return new SyncTaskExecutor();
    }
}
