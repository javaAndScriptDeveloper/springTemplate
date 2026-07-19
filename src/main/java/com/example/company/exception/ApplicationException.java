package com.example.company.exception;

import lombok.Getter;
import org.springframework.http.HttpStatus;

/**
 * Base exception for application-level errors. Carries the HTTP status that
 * {@link com.example.company.config.GlobalExceptionHandler} translates into an RFC 9457 problem detail.
 */
@Getter
public class ApplicationException extends RuntimeException {

    private final HttpStatus status;

    public ApplicationException(HttpStatus status, String message) {
        super(message);
        this.status = status;
    }

    public ApplicationException(HttpStatus status, String message, Throwable cause) {
        super(message, cause);
        this.status = status;
    }
}
