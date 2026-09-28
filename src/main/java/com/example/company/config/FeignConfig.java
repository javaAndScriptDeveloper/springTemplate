package com.example.company.config;

import feign.Logger;
import org.springframework.cloud.openfeign.EnableFeignClients;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Activates Feign client scanning. Client interfaces (see {@code com.example.company.client}) are wrapped in a
 * Resilience4j circuit breaker via {@code spring.cloud.openfeign.circuitbreaker.enabled} in {@code application.yml}.
 */
@Configuration
@EnableFeignClients(basePackages = "com.example.company.client")
public class FeignConfig {

    @Bean
    public Logger feignLogger() {
        return new RedactingFeignLogger();
    }

    /** Method, URL, status and headers per call; bodies only if you raise this to FULL. Redacted either way. */
    @Bean
    public Logger.Level feignLoggerLevel() {
        return Logger.Level.HEADERS;
    }
}
