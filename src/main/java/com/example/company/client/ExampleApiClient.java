package com.example.company.client;

import org.springframework.cloud.openfeign.FeignClient;
import org.springframework.web.bind.annotation.GetMapping;

/**
 * Example upstream API client. Delete or adapt this for your own integrations.
 *
 * <p>With {@code spring.cloud.openfeign.circuitbreaker.enabled=true}, every call is wrapped in a Resilience4j circuit
 * breaker; when the upstream fails or the breaker is open, calls are routed to {@link ExampleApiClientFallback}.
 */
@FeignClient(
        name = "example",
        url = "${example.api.url:https://example.com}",
        fallback = ExampleApiClientFallback.class)
public interface ExampleApiClient {

    @GetMapping("/greeting")
    String getGreeting();
}
