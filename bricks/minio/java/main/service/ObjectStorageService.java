package __PKG__.service;

import __PKG__.config.MinioProperties;
import __PKG__.exception.ApplicationException;
import java.net.URL;
import java.time.Duration;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.GetObjectRequest;
import software.amazon.awssdk.services.s3.model.NoSuchBucketException;
import software.amazon.awssdk.services.s3.model.NoSuchKeyException;
import software.amazon.awssdk.services.s3.model.PutObjectRequest;
import software.amazon.awssdk.services.s3.presigner.S3Presigner;
import software.amazon.awssdk.services.s3.presigner.model.GetObjectPresignRequest;

/** Put, get, delete and presign objects in the configured bucket (minio brick). Creates the bucket on first use. */
@Service
@RequiredArgsConstructor
@Slf4j
public class ObjectStorageService {

    private final S3Client s3;
    private final S3Presigner presigner;
    private final MinioProperties props;
    private volatile boolean bucketChecked;

    public void put(String key, byte[] content, String contentType) {
        ensureBucket();
        var request = PutObjectRequest.builder()
                .bucket(props.bucket())
                .key(key)
                .contentType(contentType)
                .build();
        s3.putObject(request, RequestBody.fromBytes(content));
    }

    public byte[] get(String key) {
        var request = GetObjectRequest.builder().bucket(props.bucket()).key(key).build();
        try {
            return s3.getObjectAsBytes(request).asByteArray();
        } catch (NoSuchKeyException e) {
            throw new ApplicationException(HttpStatus.NOT_FOUND, "object not found: " + key, e);
        }
    }

    public void delete(String key) {
        s3.deleteObject(b -> b.bucket(props.bucket()).key(key));
    }

    public URL presignedGetUrl(String key, Duration ttl) {
        return presigner
                .presignGetObject(GetObjectPresignRequest.builder()
                        .signatureDuration(ttl)
                        .getObjectRequest(b -> b.bucket(props.bucket()).key(key))
                        .build())
                .url();
    }

    private void ensureBucket() {
        if (bucketChecked) {
            return;
        }
        try {
            s3.headBucket(b -> b.bucket(props.bucket()));
        } catch (NoSuchBucketException e) {
            log.info("creating bucket {}", props.bucket());
            s3.createBucket(b -> b.bucket(props.bucket()));
        }
        bucketChecked = true;
    }
}
