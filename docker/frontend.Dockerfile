# =====================================================================
# Flash Sale B2C - Frontend Dockerfile (Next.js 16)
# =====================================================================
# Build context: thư mục repo frontend (flash-sale-b2c/).
#
# Build:
#   docker build -t flash-sale-b2c-frontend:latest \
#       -f /opt/flash-sale/deploy-b2c-utc2/docker/frontend.Dockerfile \
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
#
# ⚠️ TÊN BIẾN PHẢI KHỚP CODE (repo flash-sale-b2c-fe):
#    - src/lib/api/client.ts đọc process.env.NEXT_PUBLIC_API_URL
#    - src/lib/stomp.ts    đọc process.env.NEXT_PUBLIC_WS_URL
#    Nếu sai tên, Next.js sẽ inline undefined vào bundle → FE fallback
#    về http://localhost:8080 → trang trắng trên trình duyệt user.
#
# Build (prod — qua Nginx reverse proxy cùng origin):
#   docker build --build-arg NEXT_PUBLIC_API_URL=/api/v1 \
#       --build-arg NEXT_PUBLIC_WS_URL= \
#       -f docker/frontend.Dockerfile .
#
# Lưu ý: NEXT_PUBLIC_WS_URL để TRỐNG → SockJS dùng window.location.host
# tự dộng (ra ws://<current-host>/ws), tránh sai khi đổi domain/IP.
ARG NEXT_PUBLIC_API_URL=
ENV NEXT_PUBLIC_API_URL=$NEXT_PUBLIC_API_URL

# Base URL cho WebSocket (SockJS). Qua Nginx reverse proxy ở port 80.
ARG NEXT_PUBLIC_WS_URL=
ENV NEXT_PUBLIC_WS_URL=$NEXT_PUBLIC_WS_URL

# Bật/tắt mock data ở FE. Mặc định false (gọi API thật).
ARG NEXT_PUBLIC_USE_MOCK=false
ENV NEXT_PUBLIC_USE_MOCK=$NEXT_PUBLIC_USE_MOCK

# Base URL tuyệt đối cho OG/meta tags. Build-time.
# Khi deploy qua Nginx, truyền --build-arg NEXT_PUBLIC_SITE_URL=http://<VPS_IP>.
ARG NEXT_PUBLIC_SITE_URL=
ENV NEXT_PUBLIC_SITE_URL=$NEXT_PUBLIC_SITE_URL

# Locale mặc định (vi | en). Build-time, embed vào bundle.
ARG NEXT_PUBLIC_DEFAULT_LOCALE=vi
ENV NEXT_PUBLIC_DEFAULT_LOCALE=$NEXT_PUBLIC_DEFAULT_LOCALE

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