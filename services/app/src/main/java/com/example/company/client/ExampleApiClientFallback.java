package com.example.company.client;

import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Component;

/**
 * Fallback for {@link ExampleApiClient}, invoked when the upstream call fails or the circuit breaker is open.
 * Returns a safe default instead of propagating the failure to the caller.
 */
@Slf4j
@Component
public class ExampleApiClientFallback implements ExampleApiClient {

    @Override
    public String getGreeting() {
        log.warn("example API unavailable — serving fallback greeting");
        return "Hello (fallback)";
    }
}
