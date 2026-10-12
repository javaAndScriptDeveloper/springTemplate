package template.bricks.minio;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;

import org.junit.jupiter.api.Test;
import org.springframework.boot.autoconfigure.AutoConfigurations;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.presigner.S3Presigner;

class MinioAutoConfigurationTest {

    private final ApplicationContextRunner runner =
            new ApplicationContextRunner().withConfiguration(AutoConfigurations.of(MinioAutoConfiguration.class));

    @Test
    void registersTheBeansAndBindsProperties() {
        runner.withPropertyValues("app.minio.bucket=x").run(context -> {
            assertThat(context).hasSingleBean(ObjectStorageService.class);
            assertThat(context).hasSingleBean(S3Client.class);
            assertThat(context).hasSingleBean(S3Presigner.class);
            assertThat(context).hasSingleBean(MinioHealthIndicator.class);
            assertThat(context.getBean(MinioProperties.class).bucket()).isEqualTo("x");
        });
    }

    @Test
    void backsOffForAnS3ClientTheApplicationDefines() {
        var own = mock(S3Client.class);

        runner.withBean(S3Client.class, () -> own).run(context -> {
            assertThat(context).hasSingleBean(S3Client.class);
            assertThat(context.getBean(S3Client.class)).isSameAs(own);
        });
    }
}
