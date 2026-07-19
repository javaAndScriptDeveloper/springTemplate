package com.example.company;

import org.springframework.boot.SpringApplication;

/**
 * Runs the application locally with a Testcontainers-managed PostgreSQL instead of a real database.
 *
 * <p>Start it from the IDE or with {@code ./gradlew bootTestRun} — handy for local development without
 * provisioning any infrastructure yourself.
 */
public class TestApplication {

    public static void main(String[] args) {
        SpringApplication.from(Application::main)
                .with(TestcontainersConfiguration.class)
                .run(args);
    }
}
