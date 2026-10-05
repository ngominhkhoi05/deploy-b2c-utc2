#!/usr/bin/env bash
# =====================================================================
# Flash Sale B2C - Health check (chạy trên VPS)
# =====================================================================
# Kiểm tra nhanh các thành phần: Redis, Backend, Frontend, Nginx.
# Dùng khi: nghi ngờ có vấn đề, muốn xem trạng thái tổng thể.
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
cd "$DEPLOY_DIR"

# Lấy IP từ .env
VPS_IP=$(grep '^VPS_IP=' .env | cut -d= -f2-)
# ⚠️ REDIS_PASSWORD nằm trong redis.env (tách riêng để không lộ
# DB password / JWT secret vào container Redis), KHÔNG phải trong .env.
# Dùng cut -d= -f2- để giữ nguyên dấu = nếu password có chứa ký tự đặc biệt.
REDIS_PASSWORD=$(grep '^REDIS_PASSWORD=' redis.env 2>/dev/null | cut -d= -f2-)

# Lệnh redis-cli có/không password
if [ -n "$REDIS_PASSWORD" ]; then
    REDIS_CMD="docker exec flash-sale-b2c-redis redis-cli -a $REDIS_PASSWORD"
else
    REDIS_CMD="docker exec flash-sale-b2c-redis redis-cli"
fi

echo "================================================="
echo "  Flash Sale B2C - Health Check"
echo "  VPS IP: $VPS_IP"
echo "  Time:   $(date)"
echo "================================================="
echo ""

# 1. Docker containers
echo "▶ Docker containers:"
docker compose ps
echo ""

# 2. Redis ping
echo "▶ Redis status:"
$REDIS_CMD ping 2>&1 || echo "❌ Redis không phản hồi"
echo ""

# 3. Backend health (actuator) — qua bind localhost:8080 trên host
echo "▶ Backend /actuator/health (direct):"
curl -s -o /dev/null -w "HTTP %{http_code} (%{time_total}s)\n" \
    "http://localhost:8080/actuator/health" 2>&1 || echo "❌ Backend không phản hồi"
echo ""

# 4. Frontend qua Nginx
echo "▶ Frontend via Nginx (root):"
curl -s -o /dev/null -w "HTTP %{http_code} (%{time_total}s)\n" \
    "http://localhost/" 2>&1 || echo "❌ Frontend không phản hồi"
echo ""

# 5. Backend API qua Nginx
echo "▶ Backend API via Nginx (/api/v1/products):"
curl -s -o /dev/null -w "HTTP %{http_code} (%{time_total}s)\n" \
    "http://localhost/api/v1/products" 2>&1 || echo "❌ API không phản hồi"
echo ""

# 6. WebSocket endpoint info
echo "▶ WebSocket endpoint (/ws/info):"
curl -s -o /dev/null -w "HTTP %{http_code} (%{time_total}s)\n" \
    "http://localhost/ws/info" 2>&1 || echo "❌ WebSocket không phản hồi"
echo ""

# 7. Redis key count (debug)
echo "▶ Redis keys (count):"
$REDIS_CMD dbsize 2>&1 || echo "  (không có quyền)"
echo ""

# 8. Disk usage
echo "▶ Disk usage:"
df -h / | tail -1
echo ""

# 9. Docker volume size
echo "▶ Docker volumes:"
docker system df -v 2>&1 | grep -E "(VOLUME|flash-sale)" || echo "  (không tìm thấy volume)"
echo ""

echo "✅ Health check hoàn tất."