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

# 3. OpenSearch (full-text search) — qua bind localhost:9200 trên host
# ⚠️ Health check này là "canh cảnh" cho đúng lớp lỗi "deploy xong nhưng
#    search không hoạt động": nếu OS không trả lời, backend vẫn chạy được
#    (fallback LIKE trong DB) nên deploy vẫn báo thành công — nhưng tìm kiếm
#    toàn văn thì im lặng trả kết quả sai (không bỏ dấu, không xếp hạng).
echo "▶ OpenSearch (direct :9200):"
OS_HTTP=$(curl -s -k -o /dev/null -w "%{http_code}" \
    "https://localhost:9200" 2>/dev/null || echo "000")
if [ "$OS_HTTP" = "401" ] || [ "$OS_HTTP" = "200" ]; then
    echo "HTTP $OS_HTTP (OpenSearch phản hồi)"
elif [ "$OS_HTTP" = "000" ]; then
    echo "❌ OpenSearch không phản hồi — search toàn văn sẽ fallback LIKE (sai chính tả)"
    echo "   docker compose logs --tail=50 opensearch"
else
    echo "⚠️ OpenSearch trả HTTP $OS_HTTP (mong đợi 200 hoặc 401 do basic auth)"
fi
echo ""

# 4. Backend health (actuator) — qua bind localhost:8080 trên host
echo "▶ Backend /actuator/health (direct):"
curl -s -o /dev/null -w "HTTP %{http_code} (%{time_total}s)\n" \
    "http://localhost:8080/actuator/health" 2>&1 || echo "❌ Backend không phản hồi"
echo ""

# 5. Frontend qua Nginx
echo "▶ Frontend via Nginx (root):"
curl -s -o /dev/null -w "HTTP %{http_code} (%{time_total}s)\n" \
    "http://localhost/" 2>&1 || echo "❌ Frontend không phản hồi"
echo ""

# 6. Backend API qua Nginx
echo "▶ Backend API via Nginx (/api/v1/products):"
curl -s -o /dev/null -w "HTTP %{http_code} (%{time_total}s)\n" \
    "http://localhost/api/v1/products" 2>&1 || echo "❌ API không phản hồi"
echo ""

# 7. WebSocket endpoint info
echo "▶ WebSocket endpoint (/ws/info):"
curl -s -o /dev/null -w "HTTP %{http_code} (%{time_total}s)\n" \
    "http://localhost/ws/info" 2>&1 || echo "❌ WebSocket không phản hồi"
echo ""

# 8. Redis key count (debug)
echo "▶ Redis keys (count):"
$REDIS_CMD dbsize 2>&1 || echo "  (không có quyền)"
echo ""

# 9. Disk usage
echo "▶ Disk usage:"
df -h / | tail -1
echo ""

# 10. Docker volume size
echo "▶ Docker volumes:"
docker system df -v 2>&1 | grep -E "(VOLUME|flash-sale)" || echo "  (không tìm thấy volume)"
echo ""

echo "✅ Health check hoàn tất."
