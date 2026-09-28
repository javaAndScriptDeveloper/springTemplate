package com.example.company.utils;

import java.util.List;
import java.util.regex.Pattern;

/**
 * Masks credentials before they reach a log line. Applied to Feign request/response logging and to the inbound
 * request/response filter, so DEBUG logging can stay on without leaking tokens.
 *
 * <p>Rules are deliberately broad ({@code token}, {@code secret}, {@code key} in any field name): a false positive
 * hides a harmless value, a false negative ships a credential to the log store.
 */
public final class SecretRedactor {

    private static final String MASK = "****";
    private static final String SENSITIVE_NAMES =
            "password|passwd|secret|token|access_token|refresh_token|id_token|client_secret|api[_-]?key|apikey|code";

    private static final List<Rule> RULES = List.of(
            // Authorization: Bearer xxx / Basic xxx
            new Rule(Pattern.compile("(?i)(authorization:\\s*(?:bearer|basic)\\s+)\\S+"), "$1" + MASK),
            // "password": "xxx"  (JSON, any spacing)
            new Rule(Pattern.compile("(?i)(\"(?:" + SENSITIVE_NAMES + ")\"\\s*:\\s*\")[^\"]*(\")"), "$1" + MASK + "$2"),
            // password=xxx (form bodies, query strings)
            new Rule(Pattern.compile("(?i)\\b((?:" + SENSITIVE_NAMES + ")=)[^&\\s]+"), "$1" + MASK));

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
