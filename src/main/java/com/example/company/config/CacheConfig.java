package com.example.company.config;

import org.springframework.cache.annotation.EnableCaching;
import org.springframework.context.annotation.Configuration;

/**
 * Enables Spring's cache abstraction. The provider (Caffeine) and cache specs are configured in
 * {@code application.yml} under {@code spring.cache}.
 */
@Configuration
@EnableCaching
public class CacheConfig {}
