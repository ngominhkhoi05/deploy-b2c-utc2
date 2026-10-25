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

# 4. OpenSearch TLS from the backend's point of view (most important)
#    This is the "deploy finished but search silently runs wrong" layer:
#    the backend connects to https://opensearch:9200 with a certificate
#    whose SAN is DNS:opensearch. If the truststore is wrong or the CA
#    drifted, the handshake fails and search falls back to PostgreSQL LIKE.
#
#    The probe uses the CA the backend trusts and connects through the
#    SERVICE NAME "opensearch" (not localhost) so it reproduces exactly
#    the SAN failure the backend would hit. curl verifies both the chain
#    (--cacert) and the hostname in the SAN of the URL.
echo "> OpenSearch TLS (hostname 'opensearch' + backend CA):"
CA_FILE="./secrets/opensearch/ca.pem"
TRUSTSTORE_FILE="./secrets/opensearch/truststore.p12"

if [ ! -f "$CA_FILE" ]; then
    echo "FAIL: CA file not found: ${CA_FILE}"
    echo "     fix: ./scripts/export-opensearch-ca.sh"
elif [ ! -f "$TRUSTSTORE_FILE" ]; then
    echo "FAIL: truststore not found: ${TRUSTSTORE_FILE}"
    echo "     fix: ./scripts/build-truststore.sh"
else
    # (a) does the backend truststore actually contain the search CA?
    HAS_CA=$(docker run --rm \
        -v "$(pwd)/${TRUSTSTORE_FILE}:/truststore.p12:ro" \
        --entrypoint sh \
        eclipse-temurin:25-jre-jammy -c "
            keytool -list -keystore /truststore.p12 -storetype PKCS12 -storepass changeit 2>/dev/null \
                | grep -c 'fs-search-ca'
        " 2>/dev/null | tr -d '[:space:]')

    # (b) real handshake through the service name, verifying the SAN
    TLS_HTTP=$(docker run --rm \
        --network flash-sale-net \
        -v "$(pwd)/${CA_FILE}:/ca.pem:ro" \
        --entrypoint sh \
        flash-sale-b2c-opensearch:3-local -c "
            curl --cacert /ca.pem -s -o /dev/null -w '%{http_code}' \
                -u admin:\"\$OPENSEARCH_INITIAL_ADMIN_PASSWORD\" \
                https://opensearch:9200/_cluster/health 2>/dev/null
        " 2>/dev/null | tr -d '[:space:]')

    if [ "${HAS_CA:-0}" -lt 1 ]; then
        echo "FAIL: backend truststore does NOT contain the search CA (alias fs-search-ca)"
        echo "     the backend handshake will fail: PKIX path building failed"
        echo "     fix: ./scripts/build-truststore.sh"
    elif [ "${TLS_HTTP:-000}" = "200" ]; then
        echo "OK: TLS handshake succeeded (HTTP 200 via hostname 'opensearch')"
    else
        echo "FAIL: TLS handshake failed (HTTP ${TLS_HTTP:-000})"
        echo "     the backend CANNOT reach OpenSearch -> full-text search falls back"
        echo "     to PostgreSQL LIKE (wrong diacritics, no relevance ranking)"
        echo "     fix: ./scripts/export-opensearch-ca.sh && ./scripts/build-truststore.sh"
        echo "     then: docker compose up -d --force-recreate backend"
    fi
fi
echo ""

# 5. Backend health (actuator) — qua bind localhost:8080 trên host
echo "▶ Backend /actuator/health (direct):"
curl -s -o /dev/null -w "HTTP %{http_code} (%{time_total}s)\n" \
    "http://localhost:8080/actuator/health" 2>&1 || echo "❌ Backend không phản hồi"
echo ""

# 6. Frontend qua Nginx
echo "▶ Frontend via Nginx (root):"
curl -s -o /dev/null -w "HTTP %{http_code} (%{time_total}s)\n" \
    "http://localhost/" 2>&1 || echo "❌ Frontend không phản hồi"
echo ""

# 7. Backend API via Nginx
echo "▶ Backend API via Nginx (/api/v1/products):"
curl -s -o /dev/null -w "HTTP %{http_code} (%{time_total}s)\n" \
    "http://localhost/api/v1/products" 2>&1 || echo "❌ API không phản hồi"
echo ""

# 8. WebSocket endpoint info
echo "▶ WebSocket endpoint (/ws/info):"
curl -s -o /dev/null -w "HTTP %{http_code} (%{time_total}s)\n" \
    "http://localhost/ws/info" 2>&1 || echo "❌ WebSocket không phản hồi"
echo ""

# 9. Redis key count (debug)
echo "▶ Redis keys (count):"
$REDIS_CMD dbsize 2>&1 || echo "  (không có quyền)"
echo ""

# 10. Disk usage
echo "▶ Disk usage:"
df -h / | tail -1
echo ""

# 11. Docker volume size
echo "▶ Docker volumes:"
docker system df -v 2>&1 | grep -E "(VOLUME|flash-sale)" || echo "  (không tìm thấy volume)"
echo ""

echo "✅ Health check hoàn tất."
