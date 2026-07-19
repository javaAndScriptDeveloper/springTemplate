package com.example.company.config;

import org.springframework.cloud.openfeign.EnableFeignClients;
import org.springframework.context.annotation.Configuration;

/**
 * Activates Feign client scanning. Client interfaces (see {@code com.example.company.client}) are wrapped in a
 * Resilience4j circuit breaker via {@code spring.cloud.openfeign.circuitbreaker.enabled} in {@code application.yml}.
 */
@Configuration
@EnableFeignClients(basePackages = "com.example.company.client")
public class FeignConfig {}
