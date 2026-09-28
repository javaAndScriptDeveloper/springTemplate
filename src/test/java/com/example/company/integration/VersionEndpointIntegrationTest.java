package com.example.company.integration;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MockMvc;

class VersionEndpointIntegrationTest extends AbstractIntegrationTest {

    private final MockMvc mockMvc;

    VersionEndpointIntegrationTest(MockMvc mockMvc) {
        this.mockMvc = mockMvc;
    }

    @Test
    void versionDefaultsToLocalOutsideCi() throws Exception {
        mockMvc.perform(get("/version"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.version").value("local"))
                .andExpect(jsonPath("$.revision").value("dev"));
    }

    @Test
    void prometheusEndpointExposesBuildInfo() throws Exception {
        var body = mockMvc.perform(get("/actuator/prometheus"))
                .andExpect(status().isOk())
                .andReturn()
                .getResponse()
                .getContentAsString();

        assertThat(body).contains("app_build_info{");
    }
}
