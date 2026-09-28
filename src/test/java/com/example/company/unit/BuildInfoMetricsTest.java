package com.example.company.unit;

import static org.assertj.core.api.Assertions.assertThat;

import com.example.company.config.AppInfoProperties;
import com.example.company.config.BuildInfoMetrics;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.junit.jupiter.api.Test;

class BuildInfoMetricsTest {

    @Test
    void registersBuildInfoGaugeWithVersionAndRevisionTags() {
        var registry = new SimpleMeterRegistry();
        new BuildInfoMetrics(new AppInfoProperties("1.2.3", "abc1234")).bindTo(registry);

        var gauge = registry.get("app.build.info")
                .tags("version", "1.2.3", "revision", "abc1234")
                .gauge();
        assertThat(gauge.value()).isEqualTo(1.0);
    }
}
