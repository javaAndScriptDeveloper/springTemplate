package template.bricks.minio;

import java.net.URI;
import java.time.Duration;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.S3Configuration;
import software.amazon.awssdk.services.s3.presigner.S3Presigner;

/**
 * Beans of the minio brick: S3 client, presigner, {@link ObjectStorageService} and health indicator for the configured
 * endpoint. Each yields to a bean of the same type the application defines. Path-style addressing because MinIO has no
 * per-bucket DNS. Nothing connects at startup: the bucket is created on first use by {@code ObjectStorageService},
 * so the context boots even when the store is down and the health indicator reports it. Calls are bounded (10 s in
 * total, 5 s per attempt) so a hung store cannot hold a health probe past the compose interval.
 */
@AutoConfiguration
@EnableConfigurationProperties(MinioProperties.class)
public class MinioAutoConfiguration {

    @Bean
    @ConditionalOnMissingBean
    S3Client s3Client(MinioProperties props) {
        return S3Client.builder()
                .endpointOverride(URI.create(props.endpoint()))
                .region(Region.of(props.region()))
                .credentialsProvider(credentials(props))
                .forcePathStyle(true)
                .overrideConfiguration(
                        c -> c.apiCallTimeout(Duration.ofSeconds(10)).apiCallAttemptTimeout(Duration.ofSeconds(5)))
                .build();
    }

    @Bean
    @ConditionalOnMissingBean
    S3Presigner s3Presigner(MinioProperties props) {
        return S3Presigner.builder()
                .endpointOverride(URI.create(props.endpoint()))
                .region(Region.of(props.region()))
                .credentialsProvider(credentials(props))
                .serviceConfiguration(
                        S3Configuration.builder().pathStyleAccessEnabled(true).build())
                .build();
    }

    @Bean
    @ConditionalOnMissingBean
    ObjectStorageService objectStorageService(S3Client s3, S3Presigner presigner, MinioProperties props) {
        return new ObjectStorageService(s3, presigner, props);
    }

    @Bean
    @ConditionalOnMissingBean
    MinioHealthIndicator minioHealthIndicator(S3Client s3, MinioProperties props) {
        return new MinioHealthIndicator(s3, props);
    }

    private static StaticCredentialsProvider credentials(MinioProperties props) {
        return StaticCredentialsProvider.create(AwsBasicCredentials.create(props.accessKey(), props.secretKey()));
    }
}
