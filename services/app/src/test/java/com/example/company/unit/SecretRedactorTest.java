package com.example.company.unit;

import static org.assertj.core.api.Assertions.assertThat;

import com.example.company.utils.SecretRedactor;
import org.junit.jupiter.api.Test;

class SecretRedactorTest {

    @Test
    void masksBearerAndBasicAuthorizationHeaders() {
        assertThat(SecretRedactor.redact("Authorization: Bearer abc.def-ghi")).isEqualTo("Authorization: ****");
        assertThat(SecretRedactor.redact("authorization: basic dXNlcjpwYXNz")).isEqualTo("authorization: ****");
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
    void masksAnyFieldWhoseNameContainsASensitiveWord() {
        var json =
                "{\"accessToken\":\"a\",\"clientSecret\":\"b\",\"Authorization\": \"Bearer c\",\"userName\":\"ada\"}";

        assertThat(SecretRedactor.redact(json))
                .isEqualTo(
                        "{\"accessToken\":\"****\",\"clientSecret\":\"****\",\"Authorization\": \"****\",\"userName\":\"ada\"}");
        assertThat(SecretRedactor.redact("accessToken=abc&refresh_token=def&name=x"))
                .isEqualTo("accessToken=****&refresh_token=****&name=x");
    }

    @Test
    void masksSensitiveHeadersWhateverTheScheme() {
        assertThat(SecretRedactor.redact("Authorization: Token abc")).isEqualTo("Authorization: ****");
        assertThat(SecretRedactor.redact("X-Api-Key: abc-123")).isEqualTo("X-Api-Key: ****");
        assertThat(SecretRedactor.redact("Cookie: session=abc; theme=dark")).isEqualTo("Cookie: ****");
        assertThat(SecretRedactor.redact("Set-Cookie: sid=1; Path=/")).isEqualTo("Set-Cookie: ****");
    }

    @Test
    void masksJsonValuesContainingEscapedQuotes() {
        assertThat(SecretRedactor.redact("{\"password\": \"a\\\"b\", \"x\": 1}"))
                .isEqualTo("{\"password\": \"****\", \"x\": 1}");
    }

    @Test
    void truncateKeepsShortTextAndMarksCutText() {
        assertThat(SecretRedactor.truncate("abc", 5)).isEqualTo("abc");
        assertThat(SecretRedactor.truncate("abcdef", 3)).isEqualTo("abc…(+3)");
        assertThat(SecretRedactor.truncate(null, 3)).isNull();
    }
}
