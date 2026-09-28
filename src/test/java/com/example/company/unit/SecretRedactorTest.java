package com.example.company.unit;

import static org.assertj.core.api.Assertions.assertThat;

import com.example.company.utils.SecretRedactor;
import org.junit.jupiter.api.Test;

class SecretRedactorTest {

    @Test
    void masksBearerAndBasicAuthorizationHeaders() {
        assertThat(SecretRedactor.redact("Authorization: Bearer abc.def-ghi")).isEqualTo("Authorization: Bearer ****");
        assertThat(SecretRedactor.redact("authorization: basic dXNlcjpwYXNz")).isEqualTo("authorization: basic ****");
    }

    @Test
    void masksSensitiveJsonFieldsAndKeepsOthers() {
        var json = "{\"password\":\"p4ss\",\"token\":\"t0k\",\"name\":\"ada\",\"apiKey\":\"k\"}";

        assertThat(SecretRedactor.redact(json))
                .isEqualTo("{\"password\":\"****\",\"token\":\"****\",\"name\":\"ada\",\"apiKey\":\"****\"}");
    }

    @Test
    void masksSensitiveFormAndQueryParameters() {
        assertThat(SecretRedactor.redact("client_secret=abc&code=1234&state=xyz"))
                .isEqualTo("client_secret=****&code=****&state=xyz");
    }

    @Test
    void truncateKeepsShortTextAndMarksCutText() {
        assertThat(SecretRedactor.truncate("abc", 5)).isEqualTo("abc");
        assertThat(SecretRedactor.truncate("abcdef", 3)).isEqualTo("abc…(+3)");
        assertThat(SecretRedactor.truncate(null, 3)).isNull();
    }
}
