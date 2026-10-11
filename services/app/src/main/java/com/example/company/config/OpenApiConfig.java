package com.example.company.config;

import io.swagger.v3.oas.models.OpenAPI;
import io.swagger.v3.oas.models.info.Contact;
import io.swagger.v3.oas.models.info.Info;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * OpenAPI / Swagger UI metadata. Swagger UI is served at {@code /swagger-ui.html}, the raw spec at
 * {@code /v3/api-docs}. Both are disabled by the {@code prod} profile.
 */
@Configuration
public class OpenApiConfig {

    @Bean
    public OpenAPI customOpenAPI(
            @Value("${spring.application.name:service}") String applicationName,
            @Value("${app.info.version:local}") String version,
            @Value("${app.openapi.contact-name:}") String contactName,
            @Value("${app.openapi.contact-email:}") String contactEmail) {
        var info = new Info()
                .title(applicationName + " API")
                .description("API documentation for " + applicationName)
                .version(version);
        if (!contactName.isBlank() || !contactEmail.isBlank()) {
            info.contact(new Contact().name(contactName).email(contactEmail));
        }
        return new OpenAPI().info(info);
    }
}
