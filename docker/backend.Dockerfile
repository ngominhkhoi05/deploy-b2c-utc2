# =====================================================================
# Flash Sale B2C - Backend Dockerfile (Spring Boot 4 + Java 25)
# =====================================================================
# Build context: thư mục repo backend (flash-sale-b2c-UTC2/).
#
# Build:
#   docker build -t flash-sale-b2c-backend:latest \
#       -f /opt/flash-sale/deploy-b2c-utc2/docker/backend.Dockerfile \
#       /opt/flash-sale/flash-sale-b2c-UTC2/
#
# Stage 1: Build bootJar với JDK 25 (Temurin).
# Stage 2: Runtime image với JRE 25, user non-root.
# =====================================================================

# ── Stage 1: Build ──────────────────────────────────────────────────────
FROM eclipse-temurin:25-jdk-jammy AS builder
WORKDIR /build

# Copy Gradle config
#
# ⚠️ gradle.properties KHÔNG tồn tại trong repo hiện tại.
# Docker KHÔNG có flag "COPY --optional" (đã thử 1.7-labs và 1.18-labs —
# cả hai đều báo "unknown flag: --optional"). COPY một file không tồn tại
# sẽ fail ngay, nên không thể copy thẳng file này.
#
# Cách dùng ở đây: COPY thư mục gốc (chứa cả .gitignore, README...) rồi
# XÓA file trong cùng một RUN. `rm -f` không fail khi file vắng mặt.
# Tách "copy config" và "copy src" thành 2 lần COPY để cache đổi .java
# không làm mất layer config.
COPY . ./
RUN rm -f ./gradle.properties

# Copy source code (ghi đè lên bản config đã copy ở trên)
COPY src ./src

# Cache gradle wrapper + dependencies
RUN chmod +x ./gradlew
RUN ./gradlew --version

# Build executable jar (skip test để build nhanh; CI/CD chạy test riêng)
RUN ./gradlew clean bootJar -x test --no-daemon

# ── Stage 2: Runtime ────────────────────────────────────────────────────
FROM eclipse-temurin:25-jre-jammy

# Tạo non-root user để chạy app
RUN groupadd --system app && \
    useradd --system --gid app --create-home --home-dir /app --shell /sbin/nologin appuser

# Tạo thư mục /tmp cho Java với quyền ghi
# (một số thư viện ghi file tạm vào /tmp như Font cache, OkHttp, ...)
RUN mkdir -p /tmp && chmod 1777 /tmp

USER appuser
WORKDIR /app

# Copy jar từ builder
COPY --from=builder --chown=appuser:app /build/build/libs/*.jar app.jar

# Healthcheck (Spring Boot Actuator)
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD wget -q --spider http://localhost:8080/actuator/health || exit 1

EXPOSE 8080

# JAVA_OPTS truyền từ docker-compose env
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar app.jar"]