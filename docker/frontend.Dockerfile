# =====================================================================
# Flash Sale B2C - Frontend Dockerfile (Next.js 16)
# =====================================================================
# Build context: thư mục repo frontend (flash-sale-b2c/).
#
# Build:
#   docker build -t flash-sale-b2c-frontend:latest \
#       -f /opt/deploy-b2c-utc2/docker/frontend.Dockerfile \
#       /opt/flash-sale-b2c/
#
# ARCHITECTURE:
#   - Nginx container (chạy riêng) làm reverse proxy & serve static.
#   - Next.js container chạy `next start` ở port 3000.
#   - Nginx proxy /api, /wl → backend; /  → Next.js container.
#
# Stage 1: Build Next.js production bundle.
# Stage 2: Runtime image — Node 22, chạy `next start`.
# =====================================================================

# ── Stage 1: Build ──────────────────────────────────────────────────────
FROM node:22-alpine AS builder
WORKDIR /build

# Cache npm install layer
COPY package.json package-lock.json* ./
RUN npm ci --no-audit --no-fund

# Copy source
COPY . .

# Build arg: API base URL mà FE sẽ gọi.
# Mặc định: relative path /api/v1 — Nginx proxy /api → backend.
ARG NEXT_PUBLIC_API_BASE_URL=/api/v1
ENV NEXT_PUBLIC_API_BASE_URL=$NEXT_PUBLIC_API_BASE_URL

ENV NEXT_TELEMETRY_DISABLED=1
RUN npm run build

# ── Stage 2: Runtime ────────────────────────────────────────────────────
FROM node:22-alpine

# Cài wget cho HEALTHCHECK
RUN apk add --no-cache wget

# Tạo non-root user
RUN addgroup -S app && adduser -S app -G app

WORKDIR /app

# Copy build output + production dependencies only.
# LƯU Ý: Copy toàn bộ node_modules (~300MB) — trade-off giữa đơn giản và
# image size. Để tối ưu, thêm `output: 'standalone'` vào next.config.ts
# rồi dùng COPY .next/standalone + .next/static + public.
COPY --from=builder --chown=app:app /build/.next ./.next
COPY --from=builder --chown=app:app /build/public ./public
COPY --from=builder --chown=app:app /build/package.json ./package.json
COPY --from=builder --chown=app:app /build/node_modules ./node_modules

USER app

ENV NODE_ENV=production
ENV PORT=3000
ENV HOSTNAME=0.0.0.0

EXPOSE 3000

# Healthcheck
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -q --spider http://localhost:3000/ || exit 1

CMD ["npm", "start"]