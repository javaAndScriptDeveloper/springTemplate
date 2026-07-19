# syntax=docker/dockerfile:1

# ---- Build stage: compile and produce a Spring Boot jar ----
FROM eclipse-temurin:25-jdk AS build
WORKDIR /workspace

# Warm the Gradle dependency cache separately from the sources for better layer caching.
COPY gradlew settings.gradle.kts build.gradle.kts ./
COPY gradle gradle
RUN --mount=type=cache,target=/root/.gradle ./gradlew --no-daemon dependencies || true

COPY src src
RUN --mount=type=cache,target=/root/.gradle ./gradlew --no-daemon clean bootJar \
    && cp build/libs/*.jar application.jar \
    && java -Djarmode=tools -jar application.jar extract --layers --destination extracted

# ---- Runtime stage: minimal JRE, non-root, layered for cache-friendly deploys ----
FROM eclipse-temurin:25-jre AS runtime
WORKDIR /application

RUN groupadd --system spring && useradd --system --gid spring spring
USER spring:spring

COPY --from=build /workspace/extracted/dependencies/ ./
COPY --from=build /workspace/extracted/spring-boot-loader/ ./
COPY --from=build /workspace/extracted/snapshot-dependencies/ ./
COPY --from=build /workspace/extracted/application/ ./

EXPOSE 8080
ENTRYPOINT ["java", "-jar", "application.jar"]
