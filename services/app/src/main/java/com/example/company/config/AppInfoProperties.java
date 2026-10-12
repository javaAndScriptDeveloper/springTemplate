package com.example.company.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Build identity baked into the image by CI ({@code APP_VERSION} and {@code APP_REVISION} build args, surfaced as
 * environment variables). Outside CI both fall back to placeholders so local runs still answer {@code /version}.
 *
 * @param version SemVer without the {@code v} prefix, or {@code local}
 * @param revision full git SHA, or {@code dev}
 */
@ConfigurationProperties(prefix = "app.info")
public record AppInfoProperties(String version, String revision) {}
