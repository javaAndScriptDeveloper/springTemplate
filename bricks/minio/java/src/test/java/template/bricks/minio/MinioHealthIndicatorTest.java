package template.bricks.minio;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import java.util.function.Consumer;
import org.junit.jupiter.api.Test;
import org.springframework.boot.health.contributor.Status;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.HeadBucketRequest;
import software.amazon.awssdk.services.s3.model.NoSuchBucketException;

class MinioHealthIndicatorTest {

    private final S3Client s3 = mock(S3Client.class);
    private final MinioHealthIndicator indicator = new MinioHealthIndicator(
            s3, new MinioProperties("http://localhost:9000", "k", "s", "bucket-a", "us-east-1"));

    @Test
    void upWhenTheBucketAnswers() {
        assertThat(indicator.health().getStatus()).isEqualTo(Status.UP);
    }

    @Test
    void upWhenTheBucketIsNotCreatedYet() {
        when(s3.headBucket(anyConsumer()))
                .thenThrow(NoSuchBucketException.builder().build());

        var health = indicator.health();

        assertThat(health.getStatus()).isEqualTo(Status.UP);
        assertThat(health.getDetails()).containsKey("bucket");
    }

    @Test
    void downWhenTheStoreFails() {
        when(s3.headBucket(anyConsumer())).thenThrow(new IllegalStateException("boom"));

        assertThat(indicator.health().getStatus()).isEqualTo(Status.DOWN);
    }

    private static Consumer<HeadBucketRequest.Builder> anyConsumer() {
        return any();
    }
}
