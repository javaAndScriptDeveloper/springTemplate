# services/

One Gradle project per directory; `settings.gradle.kts` includes every `services/<name>/build.gradle.kts` as
`:<name>`. `app` is the service the template ships and the one `deploy/compose.prod.yml`, the Caddyfile and CI
build.

## Adding a second service (by hand, until `make add SERVICE=` exists)

1. `cp -r services/app services/<name>`; change `group` in its `build.gradle.kts` to `<base package>.<name>` and
   move the sources to that package; delete what the new service does not need.
2. `compose.yml`: a second `app`-like service with `dockerfile: services/<name>/Dockerfile` and its own
   `SERVER_PORT`. `deploy/compose.prod.yml`: same, image `ghcr.io/<owner>/<repo>/<name>`, on `edge` + `data`.
3. `deploy/Caddyfile`: a `handle_path /<name>/*` block with its own `reverse_proxy` + `dynamic a { name <name> }`.
4. `.github/workflows/ci.yml`: a second entry in the `image` job (or a matrix) with `file: services/<name>/Dockerfile`
   and image `ghcr.io/<owner>/<repo>/<name>`; the Dockerfile's COPY path.
5. `make lock SERVICE=<name>`; `make run SERVICE=<name>`.
