package com.example.company.config;

import io.micrometer.core.instrument.Gauge;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.binder.MeterBinder;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.stereotype.Component;

/**
 * Exposes {@code app_build_info{version,revision} 1}.
 *
 * <p>One series per running build: Grafana reads the running version from it and draws deploy markers where the
 * label set changes. Tagging every metric with the version would multiply series on each release; this convention
 * (the same one Prometheus uses for its own {@code build_info}) does not.
 */
@Component
@EnableConfigurationProperties(AppInfoProperties.class)
public class BuildInfoMetrics implements MeterBinder {

    private final AppInfoProperties info;

    public BuildInfoMetrics(AppInfoProperties info) {
        this.info = info;
    }

    @Override
    public void bindTo(MeterRegistry registry) {
        Gauge.builder("app.build.info", () -> 1)
                .description("Build identity of the running process; always 1")
                .tag("version", info.version())
                .tag("revision", info.revision())
                .register(registry);
    }
}
