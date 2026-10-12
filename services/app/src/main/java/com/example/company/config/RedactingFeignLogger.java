package com.example.company.config;

import com.example.company.utils.SecretRedactor;
import feign.slf4j.Slf4jLogger;

/**
 * Feign's SLF4J logger with every line passed through {@link SecretRedactor}, so {@code Logger.Level.HEADERS} or
 * {@code FULL} can be switched on in production without printing Authorization headers.
 *
 * <p>Lines are emitted under the {@code com.example.company.client} logger, which the application's own log level
 * controls (DEBUG locally, INFO in prod — see {@code application*.yml}).
 */
public class RedactingFeignLogger extends Slf4jLogger {

    public RedactingFeignLogger() {
        super("com.example.company.client.FeignHttp");
    }

    @Override
    protected void log(String configKey, String format, Object... args) {
        super.log(configKey, "%s", SecretRedactor.redact(String.format(format, args)));
    }
}
