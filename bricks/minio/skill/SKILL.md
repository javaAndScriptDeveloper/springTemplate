---
name: minio
description: Store and fetch files through ObjectStorageService (S3 / MinIO). Use when a feature needs file upload, download, deletion or a temporary download link, or when MinIO is down in prod.
---

# minio brick

- Inject `template.bricks.minio.ObjectStorageService`: `put(key, bytes, contentType)`, `get(key)` (404
  `ResponseStatusException` when missing), `delete(key)`, `presignedGetUrl(key, ttl)`.
- Keys are paths inside the one bucket `app.minio.bucket`; prefix them by feature (`invoices/<id>.pdf`).
- Settings: `MinioProperties` (`APP_MINIO_*` env). Local defaults hit the compose `minio` at localhost:9000.
- Tests: unit with a mocked `S3Client`; integration against a Testcontainers MinIO (`:bricks:minio:test`).
- Prod: `make vps-logs SERVICE=minio`; `/actuator/health` shows `minio` DOWN when the endpoint is unreachable.
- Everything else: `bricks/minio/README.md`.
