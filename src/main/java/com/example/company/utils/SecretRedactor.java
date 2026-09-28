package com.example.company.utils;

import java.util.List;
import java.util.regex.Pattern;

/**
 * Masks credentials before they reach a log line. Applied to Feign request/response logging and to the inbound
 * request/response filter, so DEBUG logging can stay on without leaking tokens.
 *
 * <p>Rules are deliberately broad: any field or header whose name <em>contains</em> a sensitive word is masked
 * whole, whatever the auth scheme or casing. A false positive hides a harmless value; a false negative ships a
 * credential to the log store.
 */
public final class SecretRedactor {

    private static final String MASK = "****";

    /** Matched as a substring of the field/header name, case-insensitively. */
    private static final String SENSITIVE_WORDS =
            "password|passwd|secret|token|api[-_]?key|apikey|authorization|cookie|credential|private[-_]?key";

    private static final String SENSITIVE_NAME = "[\\w-]*(?:" + SENSITIVE_WORDS + ")[\\w-]*";
    /** A JSON string body including escaped characters, so a value with an escaped quote is masked whole. */
    private static final String JSON_STRING = "(?:\\\\.|[^\"\\\\])*";

    private static final List<Rule> RULES = List.of(
            // Header lines: Authorization: <anything>, X-Api-Key: …, Cookie: …, Set-Cookie: …
            new Rule(Pattern.compile("(?im)^(\\s*" + SENSITIVE_NAME + "\\s*:\\s*)\\S.*$"), "$1" + MASK),
            // JSON fields: "password": "…", "accessToken":"…", "Authorization": "Bearer …"
            new Rule(
                    Pattern.compile("(?i)(\"" + SENSITIVE_NAME + "\"\\s*:\\s*\")" + JSON_STRING + "(\")"),
                    "$1" + MASK + "$2"),
            // Form bodies and query strings: password=…, accessToken=…, client_secret=…
            new Rule(Pattern.compile("(?i)(?<![\\w-])(" + SENSITIVE_NAME + "=)[^&\\s]+"), "$1" + MASK),
            // Bare OAuth codes (short-lived, but they mint tokens)
            new Rule(Pattern.compile("(?i)(\"code\"\\s*:\\s*\")" + JSON_STRING + "(\")"), "$1" + MASK + "$2"),
            new Rule(Pattern.compile("(?i)(?<![\\w-])(code=)[^&\\s]+"), "$1" + MASK));

    private SecretRedactor() {}

    /** Returns {@code text} with every recognised credential replaced by {@code ****}. Null-safe. */
    public static String redact(String text) {
        if (text == null || text.isEmpty()) {
            return text;
        }
        var result = text;
        for (var rule : RULES) {
            result = rule.pattern().matcher(result).replaceAll(rule.replacement());
        }
        return result;
    }

    /** Cuts {@code text} to {@code max} characters and appends how much was dropped. Null-safe. */
    public static String truncate(String text, int max) {
        if (text == null || text.length() <= max) {
            return text;
        }
        return text.substring(0, max) + "…(+" + (text.length() - max) + ")";
    }

    private record Rule(Pattern pattern, String replacement) {}
}
