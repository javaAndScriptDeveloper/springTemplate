package com.example.company.config;

import java.time.Clock;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.scheduling.annotation.EnableAsync;
import org.springframework.scheduling.annotation.EnableScheduling;

/**
 * Framework switches that every service in this template wants on, plus the one bean tests need to control time.
 *
 * <p>{@link EnableScheduling} is what makes {@code @Scheduled} methods (and {@link JobLoggingAspect}) do anything.
 * Inject {@link Clock} instead of calling {@code Instant.now()} so tests can pin the time.
 */
@Configuration
@EnableScheduling
@EnableAsync
public class BaseConfig {

    @Bean
    public Clock clock() {
        return Clock.systemUTC();
    }
}
