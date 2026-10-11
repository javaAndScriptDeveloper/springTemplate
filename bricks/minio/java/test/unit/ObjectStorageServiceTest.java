package __PKG__.unit;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import __PKG__.config.MinioProperties;
import __PKG__.exception.ApplicationException;
import __PKG__.service.ObjectStorageService;
import java.util.function.Consumer;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.mockito.ArgumentMatchers;
import org.springframework.http.HttpStatus;
import software.amazon.awssdk.core.ResponseBytes;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.BucketAlreadyOwnedByYouException;
import software.amazon.awssdk.services.s3.model.CreateBucketRequest;
import software.amazon.awssdk.services.s3.model.GetObjectRequest;
import software.amazon.awssdk.services.s3.model.GetObjectResponse;
import software.amazon.awssdk.services.s3.model.HeadBucketRequest;
import software.amazon.awssdk.services.s3.model.NoSuchBucketException;
import software.amazon.awssdk.services.s3.model.NoSuchKeyException;
import software.amazon.awssdk.services.s3.model.PutObjectRequest;
import software.amazon.awssdk.services.s3.presigner.S3Presigner;

class ObjectStorageServiceTest {

    private final S3Client s3 = mock(S3Client.class);
    private final S3Presigner presigner = mock(S3Presigner.class);
    private final MinioProperties props =
            new MinioProperties("http://localhost:9000", "k", "s", "bucket-a", "us-east-1");
    private final ObjectStorageService service = new ObjectStorageService(s3, presigner, props);

    @Test
    void propertiesToStringDoesNotLeakTheSecretKey() {
        var secret = new MinioProperties("http://localhost:9000", "k", "s3cr3t-value", "b", "us-east-1");

        assertThat(secret.toString()).doesNotContain("s3cr3t-value").contains("secretKey=****");
    }

    @Test
    void putUploadsToTheConfiguredBucketWithContentType() {
        service.put("docs/a.txt", "hi".getBytes(), "text/plain");

        var request = ArgumentCaptor.forClass(PutObjectRequest.class);
        verify(s3).putObject(request.capture(), any(RequestBody.class));
        assertThat(request.getValue().bucket()).isEqualTo("bucket-a");
        assertThat(request.getValue().key()).isEqualTo("docs/a.txt");
        assertThat(request.getValue().contentType()).isEqualTo("text/plain");
    }

    @Test
    void getReturnsTheBytes() {
        when(s3.getObjectAsBytes(any(GetObjectRequest.class)))
                .thenReturn(
                        ResponseBytes.fromByteArray(GetObjectResponse.builder().build(), "hi".getBytes()));

        assertThat(service.get("docs/a.txt")).isEqualTo("hi".getBytes());
    }

    @Test
    void getOfAMissingKeyIsA404() {
        when(s3.getObjectAsBytes(any(GetObjectRequest.class)))
                .thenThrow(NoSuchKeyException.builder().build());

        assertThatThrownBy(() -> service.get("nope"))
                .isInstanceOf(ApplicationException.class)
                .hasMessageContaining("nope")
                .extracting("status")
                .isEqualTo(HttpStatus.NOT_FOUND);
    }

    @Test
    void getFromAMissingBucketIsA404() {
        when(s3.getObjectAsBytes(any(GetObjectRequest.class)))
                .thenThrow(NoSuchBucketException.builder().build());

        assertThatThrownBy(() -> service.get("x"))
                .isInstanceOf(ApplicationException.class)
                .extracting("status")
                .isEqualTo(HttpStatus.NOT_FOUND);
    }

    @Test
    void putSurvivesAReplicaCreatingTheBucketFirst() {
        when(s3.headBucket(ArgumentMatchers.<Consumer<HeadBucketRequest.Builder>>any()))
                .thenThrow(NoSuchBucketException.builder().build());
        when(s3.createBucket(ArgumentMatchers.<Consumer<CreateBucketRequest.Builder>>any()))
                .thenThrow(BucketAlreadyOwnedByYouException.builder().build());

        service.put("a", "hi".getBytes(), "text/plain");

        verify(s3).putObject(any(PutObjectRequest.class), any(RequestBody.class));
    }
}
