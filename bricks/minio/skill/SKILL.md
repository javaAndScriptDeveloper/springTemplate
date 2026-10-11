---
name: minio
description: Store and fetch files through ObjectStorageService (S3 / MinIO). Use when a feature needs file upload, download, deletion or a temporary download link, or when MinIO is down in prod.
---

# minio brick

- Inject `ObjectStorageService` (`service` package): `put(key, bytes, contentType)`, `get(key)` (404
  `ApplicationException` when missing), `delete(key)`, `presignedGetUrl(key, ttl)`.
- Keys are paths inside the one bucket `app.minio.bucket`; prefix them by feature (`invoices/<id>.pdf`).
- Settings: `MinioProperties` (`APP_MINIO_*` env). Local defaults hit the compose `minio` at localhost:9000.
- Tests: unit with a mocked `S3Client`; integration via `@Import(MinioTestcontainersConfiguration.class)`.
- Prod: `make vps-logs SERVICE=minio`; `/actuator/health` shows `minio` DOWN when the endpoint is unreachable.
- Everything else: `bricks/minio/README.md`.
