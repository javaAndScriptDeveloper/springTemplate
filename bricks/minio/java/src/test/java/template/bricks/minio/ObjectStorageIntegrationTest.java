package __PKG__.integration;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import __PKG__.MinioTestcontainersConfiguration;
import __PKG__.exception.ApplicationException;
import __PKG__.service.ObjectStorageService;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import org.junit.jupiter.api.Test;
import org.springframework.context.annotation.Import;

@Import(MinioTestcontainersConfiguration.class)
class ObjectStorageIntegrationTest extends AbstractIntegrationTest {

    private final ObjectStorageService storage;

    ObjectStorageIntegrationTest(ObjectStorageService storage) {
        this.storage = storage;
    }

    @Test
    void roundTripThroughARealStore() throws Exception {
        storage.put("it/hello.txt", "hello".getBytes(), "text/plain");

        assertThat(storage.get("it/hello.txt")).isEqualTo("hello".getBytes());

        var url = storage.presignedGetUrl("it/hello.txt", Duration.ofMinutes(1));
        var response = HttpClient.newHttpClient()
                .send(HttpRequest.newBuilder(url.toURI()).GET().build(), HttpResponse.BodyHandlers.ofString());
        assertThat(response.statusCode()).isEqualTo(200);
        assertThat(response.body()).isEqualTo("hello");

        storage.delete("it/hello.txt");
        assertThatThrownBy(() -> storage.get("it/hello.txt")).isInstanceOf(ApplicationException.class);
    }
}
