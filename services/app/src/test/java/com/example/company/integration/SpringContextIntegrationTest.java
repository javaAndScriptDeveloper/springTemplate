package com.example.company.integration;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;
import org.springframework.context.ApplicationContext;

class SpringContextIntegrationTest extends AbstractIntegrationTest {

    private final ApplicationContext applicationContext;

    SpringContextIntegrationTest(ApplicationContext applicationContext) {
        this.applicationContext = applicationContext;
    }

    @Test
    void contextLoads() {
        assertThat(applicationContext.getId()).isNotBlank();
    }
}
