package __PKG__.config;

import lombok.RequiredArgsConstructor;
import org.springframework.boot.health.contributor.Health;
import org.springframework.boot.health.contributor.HealthIndicator;
import org.springframework.stereotype.Component;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.NoSuchBucketException;

/** /actuator/health shows the object store (minio brick): UP when the endpoint answers for the configured bucket.
 * Bucket-scoped on purpose: managed stores hand out credentials without {@code ListAllMyBuckets}. */
@Component
@RequiredArgsConstructor
public class MinioHealthIndicator implements HealthIndicator {

    private final S3Client s3;
    private final MinioProperties props;

    @Override
    public Health health() {
        try {
            s3.headBucket(b -> b.bucket(props.bucket()));
            return Health.up().withDetail("endpoint", props.endpoint()).build();
        } catch (NoSuchBucketException e) {
            // The bucket is created on first use, so a reachable store without it is healthy.
            return Health.up()
                    .withDetail("endpoint", props.endpoint())
                    .withDetail("bucket", "missing (created on first use)")
                    .build();
        } catch (RuntimeException e) {
            return Health.down(e).withDetail("endpoint", props.endpoint()).build();
        }
    }
}
