# minio: S3-compatible object storage with an ObjectStorageService, locally and in prod

`make add BRICK=minio` → `make run` starts MinIO beside Postgres (console http://localhost:9001, minioadmin /
minioadmin). In prod: `make prod-init` (or add `MINIO_ROOT_PASSWORD=` by hand and generate one with
`openssl rand -hex 24`), `make prod-up`. Memory: 256m. The app uses the MinIO root credentials (fine for a solo
project; create a scoped user with `mc admin user add` if you need least privilege).

Enabling on a running host: do the VPS steps (`git pull`, `.env.prod` block, `make prod-up`) right after the push
([deployment.md](../../docs/deployment.md)). If the new image rolls out first, `APP_MINIO_ENDPOINT` falls back to
`localhost:9000`, `minio` health is DOWN, replicas go unhealthy and uploads fail until the host catches up.

## Use it
`template.bricks.minio.ObjectStorageService`: `put(key, bytes, contentType)`, `get(key)` → 404
`ResponseStatusException` when missing, `delete(key)`, `presignedGetUrl(key, ttl)`. One bucket (`APP_MINIO_BUCKET`, created on first use); prefix
keys per feature. Settings: `MinioProperties`, env `APP_MINIO_ENDPOINT / ACCESS_KEY / SECRET_KEY / BUCKET / REGION`.

## Operate it
- `/actuator/health` → `minio` component: a `HEAD` on the configured bucket (no list permission needed, so
  bucket-scoped keys work); UP while the bucket is not yet created, DOWN when the endpoint is unreachable or refuses. Replicas wait for a healthy MinIO
  at boot (`depends_on`), and a MinIO outage later shows as app DOWN by design: the app cannot do its job.
- Data lives in the `minio_data` volume; it is **not** in the backup brick's dump. Back it up with `rclone` from the
  volume or switch to a managed store.
- Presigned URLs embed `APP_MINIO_ENDPOINT` (`http://minio:9000` in prod): fine for server-side fetches, not for
  browsers: the app signs with `APP_MINIO_ENDPOINT`. If browsers must fetch, put MinIO behind a Caddy site and set
  that public URL as the endpoint.
- Swap to Hetzner Object Storage / AWS: set `APP_MINIO_ENDPOINT`, `APP_MINIO_ACCESS_KEY`, `APP_MINIO_SECRET_KEY`,
  `APP_MINIO_REGION` in `deploy/.env.prod`, delete the `minio` service and the `app` partial from
  `bricks/minio/compose.prod.yml` (or remove the brick and keep the Java).

## Tests
Gradle project `:bricks:minio` (`./gradlew :bricks:minio:test`). Unit: `ObjectStorageServiceTest` (mocked
`S3Client`). Integration: `ObjectStorageIntegrationTest` against a Testcontainers MinIO, in a minimal context
(`MinioTestApplication`), so the auto-configuration must wire itself.

## Change it
The Java is the Gradle project `:bricks:minio` (`bricks/minio/java`, package `template.bricks.minio`). Override any
bean (`S3Client`, `S3Presigner`, `ObjectStorageService`, `MinioHealthIndicator`) by defining your own. Dependencies:
`java/build.gradle.kts`; Dependabot bumps them, then refresh the lockfile with
`./gradlew :bricks:minio:dependencies --write-locks`. A second module using awssdk should move both to the AWS SDK
BOM.

Image: MinIO Inc. stopped publishing community images (`minio/minio` is no longer pullable), so the brick uses
Chainguard's build, `cgr.dev/chainguard/minio:latest`. Only `latest` exists on the free tier; to get reproducible
deploys pin by digest: `cgr.dev/chainguard/minio:latest@sha256:…`. Watchtower never touches it. Both compose files and
`MinioTestcontainersConfiguration` carry the image; change all three. Alternatives: `bitnamilegacy/minio` (frozen),
`rustfs/rustfs` (a different product, S3-compatible), or a managed store (Hetzner Object Storage) through the env
vars above.
