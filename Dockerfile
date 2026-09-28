# syntax=docker/dockerfile:1
# Runtime-only image. CI builds the jar once at native speed and this stage merely packages it, which is what
# makes an amd64+arm64 manifest cheap (no Gradle under QEMU). Locally: `make image` runs bootJar first.
FROM eclipse-temurin:25-jre

# Baked in by CI; /version and the app_build_info metric read them. Defaults keep local images honest.
ARG APP_VERSION=local
ARG APP_REVISION=dev
ENV APP_VERSION=${APP_VERSION} \
    APP_REVISION=${APP_REVISION} \
    JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError"

# curl is the only addition to the base image: the compose healthcheck needs it and temurin ships neither curl nor wget.
RUN apt-get update \
    && apt-get install --no-install-recommends -y curl \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --system spring && useradd --system --gid spring spring
WORKDIR /application
COPY --chown=spring:spring build/libs/app.jar application.jar
USER spring:spring

EXPOSE 8080
# Probes the management port (8081 in prod, same as the app port locally). start-period covers Liquibase at boot.
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
    CMD curl -sf "http://127.0.0.1:${MANAGEMENT_PORT:-8080}/actuator/health" || exit 1
ENTRYPOINT ["java", "-jar", "application.jar"]
