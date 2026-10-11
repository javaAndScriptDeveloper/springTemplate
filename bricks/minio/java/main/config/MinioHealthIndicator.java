package __PKG__.config;

import lombok.RequiredArgsConstructor;
import org.springframework.boot.health.contributor.Health;
import org.springframework.boot.health.contributor.HealthIndicator;
import org.springframework.stereotype.Component;
import software.amazon.awssdk.services.s3.S3Client;

/** /actuator/health shows the object store (minio brick): UP when the endpoint answers a bucket listing. */
@Component
@RequiredArgsConstructor
public class MinioHealthIndicator implements HealthIndicator {

    private final S3Client s3;
    private final MinioProperties props;

    @Override
    public Health health() {
        try {
            s3.listBuckets();
            return Health.up().withDetail("endpoint", props.endpoint()).build();
        } catch (RuntimeException e) {
            return Health.down(e).withDetail("endpoint", props.endpoint()).build();
        }
    }
}
