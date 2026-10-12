package template.bricks.minio;

import org.springframework.boot.SpringBootConfiguration;
import org.springframework.boot.autoconfigure.EnableAutoConfiguration;

/** Minimal context for the brick's integration test: only auto-configuration, so {@link MinioAutoConfiguration} must wire itself. */
@SpringBootConfiguration
@EnableAutoConfiguration
class MinioTestApplication {}
