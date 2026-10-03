#!/usr/bin/env bash
# =====================================================================
# Flash Sale B2C - Deploy to VPS (Ubuntu)
# =====================================================================
# Script này chạy TRÊN VPS sau khi đã copy thư mục deploy-b2c-utc2 lên.
# Nó sẽ:
#   1. Tạo Docker network nếu chưa có
#   2. Khởi động Redis container
#   3. Khởi động Backend Spring Boot (kết nối Supabase DB + Redis)
#   4. Khởi động Frontend Next.js + Nginx reverse proxy
#
# Yêu cầu:
#   - Docker + Docker Compose đã cài trên VPS
#   - File .env đã điền giá trị thật (copy từ .env.example)
#   - Images đã build: flash-sale-b2c-backend:latest, flash-sale-b2c-frontend:latest
# =====================================================================

set -e  # Exit ngay khi có lỗi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
cd "$DEPLOY_DIR"

echo "=================================================="
echo "  Flash Sale B2C - Deploy"
echo "  Working dir: $DEPLOY_DIR"
echo "=================================================="

# ─── 1. Kiểm tra file .env ─────────────────────────────────────────────
if [ ! -f ".env" ]; then
    echo "❌ Chưa có file .env. Hãy copy từ .env.example và điền giá trị thật:"
    echo "    cp .env.example .env && nano .env"
    exit 1
fi

# ─── 2. Tạo Docker network nếu chưa có ─────────────────────────────────
if ! docker network inspect flash-sale-net >/dev/null 2>&1; then
    echo "==> Tạo Docker network 'flash-sale-net'..."
    docker network create flash-sale-net
fi

# ─── 3. Khởi động stack ────────────────────────────────────────────────
echo "==> Khởi động Docker Compose stack..."
docker compose up -d

# ─── 4. Kiểm tra container ─────────────────────────────────────────────
echo ""
echo "==> Trạng thái containers:"
docker compose ps

echo ""
echo "=================================================="
echo "  ✅ Deploy hoàn tất!"
echo "=================================================="
echo ""
echo "Các bước tiếp theo:"
echo "  • Xem log:        docker compose logs -f backend"
echo "  • Xem log FE:     docker compose logs -f frontend"
echo "  • Xem log Nginx:  docker compose logs -f nginx"
echo "  • Health check:   ./scripts/check-health.sh"
echo ""
VPS_IP=$(grep '^VPS_IP=' .env | cut -d= -f2)
echo "  • Truy cập:       http://${VPS_IP}"
echo "  • Swagger UI:     http://${VPS_IP}/swagger-ui.html"