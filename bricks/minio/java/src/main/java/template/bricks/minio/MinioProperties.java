package __PKG__.config;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.boot.context.properties.bind.DefaultValue;

/**
 * Object storage settings (minio brick). Bound from the environment by relaxed binding: {@code APP_MINIO_ENDPOINT},
 * {@code APP_MINIO_ACCESS_KEY}, {@code APP_MINIO_SECRET_KEY}, {@code APP_MINIO_BUCKET}, {@code APP_MINIO_REGION}.
 * Defaults match the local compose service. Any S3-compatible store works (MinIO, Hetzner Object Storage, AWS).
 */
@ConfigurationProperties(prefix = "app.minio")
public record MinioProperties(
        @DefaultValue("http://localhost:9000") String endpoint,
        @DefaultValue("minioadmin") String accessKey,
        @DefaultValue("minioadmin") String secretKey,
        @DefaultValue("app") String bucket,
        @DefaultValue("us-east-1") String region) {

    /** The generated record toString would print the secret key into logs. */
    @Override
    public String toString() {
        return "MinioProperties[endpoint=" + endpoint + ", accessKey=" + accessKey + ", secretKey=****, bucket="
                + bucket + ", region=" + region + "]";
    }
}
