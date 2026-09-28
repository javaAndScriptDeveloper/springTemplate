package com.example.company.config;

import com.example.company.exception.ApplicationException;
import feign.FeignException;
import java.util.HashMap;
import lombok.extern.slf4j.Slf4j;
import org.springframework.cloud.client.circuitbreaker.NoFallbackAvailableException;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.HttpStatusCode;
import org.springframework.http.ProblemDetail;
import org.springframework.http.ResponseEntity;
import org.springframework.validation.FieldError;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.context.request.WebRequest;
import org.springframework.web.servlet.mvc.method.annotation.ResponseEntityExceptionHandler;

/**
 * Translates exceptions into RFC 9457 {@link ProblemDetail} responses (served as {@code application/problem+json}).
 *
 * <p>Extends {@link ResponseEntityExceptionHandler}, which already maps every Spring MVC client-side failure
 * (unknown path, wrong method, unsupported media type, type mismatch, unreadable body, {@code ResponseStatusException}
 * …) to the right 4xx quietly. Without that, each one falls into the catch-all below and produces a 500 with an ERROR
 * stack trace, which is how a port scanner ends up paging you. Only the cases that need a different body or a log line
 * are handled here.
 */
@Slf4j
@RestControllerAdvice
public class GlobalExceptionHandler extends ResponseEntityExceptionHandler {

    @ExceptionHandler(ApplicationException.class)
    public ProblemDetail handleApplicationException(ApplicationException ex) {
        log.debug("Application error: {}", ex.getMessage());
        return ProblemDetail.forStatusAndDetail(ex.getStatus(), ex.getMessage());
    }

    /** Adds a field → message map to the standard validation problem. */
    @Override
    protected ResponseEntity<Object> handleMethodArgumentNotValid(
            MethodArgumentNotValidException ex, HttpHeaders headers, HttpStatusCode status, WebRequest request) {
        var errors = new HashMap<String, String>();
        for (var error : ex.getBindingResult().getAllErrors()) {
            var field = error instanceof FieldError fieldError ? fieldError.getField() : error.getObjectName();
            errors.put(field, error.getDefaultMessage());
        }
        var problem = ProblemDetail.forStatusAndDetail(HttpStatus.BAD_REQUEST, "Request validation failed");
        problem.setProperty("errors", errors);
        return ResponseEntity.status(HttpStatus.BAD_REQUEST).headers(headers).body(problem);
    }

    /**
     * Upstream failures surface as 502 and the upstream body never reaches the caller (it may carry their secrets).
     * With the circuit breaker on, a client without a fallback throws {@link NoFallbackAvailableException} wrapping
     * the real cause; a client called outside the breaker throws {@link FeignException} directly.
     */
    @ExceptionHandler({FeignException.class, NoFallbackAvailableException.class})
    public ProblemDetail handleUpstreamFailure(Exception ex) {
        var cause = ex instanceof NoFallbackAvailableException wrapped && wrapped.getCause() != null
                ? wrapped.getCause()
                : ex;
        if (cause instanceof FeignException feign) {
            log.warn(
                    "Upstream call failed with status {}: {}",
                    feign.status(),
                    feign.request().url());
        } else {
            log.warn("Upstream call failed: {}", cause.toString());
        }
        return ProblemDetail.forStatusAndDetail(HttpStatus.BAD_GATEWAY, "Upstream service unavailable");
    }

    @ExceptionHandler(Exception.class)
    public ProblemDetail handleUnexpected(Exception ex) {
        log.error("Unhandled exception", ex);
        return ProblemDetail.forStatusAndDetail(HttpStatus.INTERNAL_SERVER_ERROR, "Something went wrong");
    }
}
