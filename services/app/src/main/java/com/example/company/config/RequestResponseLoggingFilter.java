package com.example.company.config;

import com.example.company.utils.SecretRedactor;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;
import org.springframework.web.util.ContentCachingRequestWrapper;
import org.springframework.web.util.ContentCachingResponseWrapper;

/**
 * One DEBUG line per HTTP exchange with method, path, status, duration and (redacted, truncated) bodies.
 *
 * <p>Inactive unless this class's logger is at DEBUG, so production pays nothing. Actuator, API docs and
 * {@code /version} are skipped: they are polled constantly and never interesting.
 */
@Slf4j
@Component
public class RequestResponseLoggingFilter extends OncePerRequestFilter {

    static final int MAX_BODY_CHARS = 4096;

    @Override
    protected boolean shouldNotFilter(HttpServletRequest request) {
        var uri = request.getRequestURI();
        return !log.isDebugEnabled()
                || uri.startsWith("/actuator")
                || uri.startsWith("/swagger-ui")
                || uri.startsWith("/v3/api-docs")
                || uri.equals("/version");
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        var wrappedRequest = new ContentCachingRequestWrapper(request, MAX_BODY_CHARS);
        var wrappedResponse = new ContentCachingResponseWrapper(response);
        var started = System.nanoTime();
        try {
            chain.doFilter(wrappedRequest, wrappedResponse);
        } finally {
            var elapsedMs = (System.nanoTime() - started) / 1_000_000;
            var query = request.getQueryString() == null ? "" : "?" + SecretRedactor.redact(request.getQueryString());
            log.debug(
                    "{} {}{} -> {} in {} ms | request: {} | response: {}",
                    request.getMethod(),
                    request.getRequestURI(),
                    query,
                    wrappedResponse.getStatus(),
                    elapsedMs,
                    body(wrappedRequest.getContentAsByteArray()),
                    body(wrappedResponse.getContentAsByteArray()));
            wrappedResponse.copyBodyToResponse();
        }
    }

    private static String body(byte[] bytes) {
        if (bytes.length == 0) {
            return "-";
        }
        var text = new String(bytes, StandardCharsets.UTF_8);
        return SecretRedactor.truncate(SecretRedactor.redact(text), MAX_BODY_CHARS);
    }
}
