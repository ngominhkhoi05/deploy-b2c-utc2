#!/usr/bin/env bash
# =====================================================================
# Flash Sale B2C - Deploy to VPS (Ubuntu)
# =====================================================================
# Script này chạy TRÊN VPS sau khi đã copy thư mục deploy-b2c-utc2 lên.
# Nó sẽ:
#   1. Kiểm tra file .env / redis.env đã điền chưa
#   2. Khởi động stack bằng `docker compose up -d`
#      (Compose TỰ tạo network 'flash-sale-net' kèm label cần thiết)
#   3. Kiểm tra số container đang chạy, báo lỗi nếu thiếu
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
# Chọn editor có sẵn trên VPS (Ubuntu minimal thường không có nano).
# Dung if/then/fi thay vi && { } de tuong thich sh cua busybox.
detect_editor() {
    if [ -n "${EDITOR:-}" ] && command -v "$EDITOR" >/dev/null 2>&1; then
        echo "$EDITOR"
        return 0
    fi
    if command -v nano >/dev/null 2>&1; then
        echo "nano"
        return 0
    fi
    if command -v vi >/dev/null 2>&1; then
        echo "vi"
        return 0
    fi
    echo "vi"
}

if [ ! -f ".env" ]; then
    _ED="$(detect_editor)"
    echo "❌ Chưa có file .env. Hãy copy từ .env.example và điền giá trị thật:"
    echo "    cp .env.example .env"
    echo "    ${_ED} .env"
    command -v nano >/dev/null 2>&1 || \
        echo "    (nano không có sẵn — cài bằng: apt update && apt install -y nano)"
    exit 1
fi

# ─── 1b. Kiểm tra file redis.env ────────────────────────────────────────
if [ ! -f "redis.env" ]; then
    echo "❌ Chưa có file redis.env. Hãy copy từ redis.env.example:"
    echo "    cp redis.env.example redis.env"
    echo "    $(detect_editor) redis.env"
    exit 1
fi

# ─── 2. Khởi động stack ────────────────────────────────────────────────
# KHÔNG tạo network thủ công ở đây.
# docker-compose.yml khai báo networks: flash-sale-net (name: flash-sale-net)
# nên `docker compose up` TỰ tạo network kèm label com.docker.compose.*.
# Nếu tạo tay bằng `docker network create`, network sẽ thiếu label và Compose
# báo: "network flash-sale-net was found but has incorrect label
# com.docker.compose.network set to \"\" (expected: ...)" rồi abort,
# không container nào khởi động.
echo "==> Khởi động Docker Compose stack..."
if ! docker compose up -d; then
    echo ""
    echo "❌ docker compose up thất bại."
    echo "   - Nếu thấy 'incorrect label com.docker.compose.network',"
    echo "     network cũ đã bị tạo tay từ lần deploy trước. Xoá rồi chạy lại:"
    echo "       docker network rm flash-sale-net"
    echo "       ./scripts/deploy.sh"
    echo "   - Nếu thấy 'pull access denied', image backend/frontend chưa build."
    echo "     Build trước (README §5.1) rồi chạy lại script này."
    echo "   - Xem log chi tiết: docker compose up -d 2>&1 | tail -30"
    exit 1
fi

# ─── 3. Kiểm tra container ─────────────────────────────────────────────
echo ""
echo "==> Trạng thái containers:"
docker compose ps

# Đếm container đang chạy. Nếu thiếu → KHÔNG được báo "deploy hoàn tất".
RUNNING=$(docker compose ps --status running -q | wc -l | tr -d ' ')
EXPECTED=4   # redis, backend, frontend, nginx

echo ""
if [ "$RUNNING" -lt "$EXPECTED" ]; then
    echo "=================================================="
    echo "  ⚠️  Deploy CHƯA hoàn tất: $RUNNING/$EXPECTED container đang chạy."
    echo "=================================================="
    echo ""
    echo "Các container còn thiếu — xem log để biết nguyên nhân:"
    echo "  docker compose logs --tail=50 backend"
    echo "  docker compose logs --tail=50 frontend"
    echo ""
    echo "Lưu ý: backend cần thời gian khởi động (Flyway migration + kết nối"
    echo "Supabase). Nếu backend vẫn 'starting', chờ rồi kiểm tra lại:"
    echo "  sleep 30 && docker compose ps"
    echo "  ./scripts/check-health.sh"
    exit 1
fi

echo "=================================================="
echo "  ✅ Deploy hoàn tất! ($RUNNING/$EXPECTED container đang chạy)"
echo "=================================================="
echo ""
echo "Các bước tiếp theo:"
echo "  • Health check:   ./scripts/check-health.sh"
echo "  • Xem log:        docker compose logs -f backend"
echo "  • Xem log FE:     docker compose logs -f frontend"
echo "  • Xem log Nginx:  docker compose logs -f nginx"
echo ""
VPS_IP=$(grep '^VPS_IP=' .env | cut -d= -f2-)
echo "  • Truy cập:       http://${VPS_IP}"
echo "  • Swagger UI:     http://${VPS_IP}/swagger-ui.html"
