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

# ─── 2. Chuẩn bị TLS cho backend ↔ OpenSearch ──────────────────────────
# Cert của OpenSearch được bake vào image lúc build (SAN = DNS:opensearch).
# Backend cần trust đúng CA đó, nếu không handshake fail:
#   "No subject alternative names matching opensearch found"
# và search toàn văn im lặng rơi về LIKE trong DB (sai dấu, không xếp hạng).
#
# ⚠️ Truststore PHẢI có cả CA của JDK. -Djavax.net.ssl.trustStore thay thế
#    toàn bộ CA mặc định của JVM; thiếu CA public thì Supabase / Cloudinary
#    / ZaloPay / Google OAuth đều fail.
#
# CA được export TỪ IMAGE (không copy riêng trong repo) nên CA mà backend tin
# và CA đã ký cert không bao giờ lệch nhau.
echo "==> Chuẩn bị truststore OpenSearch cho backend..."
if ! ./scripts/export-opensearch-ca.sh; then
    echo ""
    echo "❌ Không export được CA của OpenSearch."
    echo "   Nếu image chưa được build, build trước:"
    echo "     docker compose build opensearch"
    exit 1
fi

if ! ./scripts/build-truststore.sh; then
    echo ""
    echo "❌ Không build được truststore cho backend."
    echo "   Backend sẽ không boot được (Invalid keystore format)."
    exit 1
fi

# ─── 3. Khởi động stack ────────────────────────────────────────────────
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
    echo "   - Nếu thấy 'Invalid keystore format', truststore chưa được mount"
    echo "     đúng. Chạy: ./scripts/build-truststore.sh"
    echo "   - Xem log chi tiết: docker compose up -d 2>&1 | tail -30"
    exit 1
fi

# ─── 4. Kiểm tra container ─────────────────────────────────────────────
echo ""
echo "==> Trạng thái containers:"
docker compose ps

# Đếm container đang chạy. Nếu thiếu → KHÔNG được báo "deploy hoàn tất".
RUNNING=$(docker compose ps --status running -q | wc -l | tr -d ' ')
# 5 containers: redis, opensearch, backend, frontend, nginx.
# ⚠️ opensearch PHẢI được đếm: backend phụ thuộc cứng vào nó
# (depends_on: opensearch: condition: service_healthy). Nếu chỉ đếm 4,
# trường hợp thiếu search engine vẫn bị báo "deploy hoàn tất" → người dùng
# tưởng đã xong nhưng tìm kiếm toàn văn im lặng chạy sai (fallback LIKE).
EXPECTED=5

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
    echo "⚠️ Nếu opensearch không chạy/unhealthy, backend sẽ KHÔNG lên (depends_on:"
    echo "   opensearch: condition: service_healthy) và tìm kiếm toàn văn sẽ"
    echo "   fallback sang LIKE trong DB (sai chính tả, không xếp hạng relevance)."
    echo "   docker compose logs --tail=50 opensearch"
    echo "Lưu ý: backend cần thời gian khởi động (Flyway migration + kết nối"
    echo "Supabase). Nếu backend vẫn 'starting', chờ rồi kiểm tra lại:"
    echo "  sleep 30 && docker compose ps"
    echo "  ./scripts/check-health.sh"
    exit 1
fi

# ─── 5. Xác minh TLS backend ↔ OpenSearch ───────────────────────────────
# ⚠️ Đây là lớp lỗi im lặng nguy hiểm nhất: container đều "running" nhưng
#    backend KHÔNG nối được OpenSearch -> search toàn văn fallback LIKE
#    trong DB (sai dấu tiếng Việt, không xếp hạng relevance) mà không có
#    lỗi nào hiện ra cho người dùng.
#
#    Đây KHÔNG phải check thừa: nó là tiêu chí "deploy hoàn tất" thực sự.
echo ""
echo "==> Xác minh TLS backend ↔ OpenSearch..."
TLS_HTTP=$(docker run --rm \
    --network flash-sale-net \
    -v "$(pwd)/secrets/opensearch/ca.pem:/ca.pem:ro" \
    --entrypoint sh \
    flash-sale-b2c-opensearch:3-local -c "
        curl --cacert /ca.pem -s -o /dev/null -w '%{http_code}' \
            -u admin:\"\$OPENSEARCH_INITIAL_ADMIN_PASSWORD\" \
            https://opensearch:9200/_cluster/health 2>/dev/null
    " 2>/dev/null | tr -d '[:space:]')

if [ "${TLS_HTTP:-000}" = "200" ]; then
    echo "✅ TLS backend ↔ OpenSearch OK (HTTP 200 qua hostname 'opensearch')"
else
    echo ""
    echo "=================================================="
    echo "  ⚠️  Deploy CHƯA hoàn tất: TLS tới OpenSearch FAIL (HTTP ${TLS_HTTP:-000})"
    echo "=================================================="
    echo ""
    echo "Backend dùng https://opensearch:9200 với cert SAN=DNS:opensearch."
    echo "Handshake fail -> search toàn văn fallback LIKE trong DB (sai dấu,"
    echo "không xếp hạng relevance) và KHÔNG có lỗi nào hiện ra cho người dùng."
    echo ""
    echo "Cách sửa:"
    echo "  ./scripts/export-opensearch-ca.sh   # export CA từ image"
    echo "  ./scripts/build-truststore.sh       # build truststore cho backend"
    echo "  docker compose up -d --force-recreate backend"
    echo ""
    echo "Xem log backend:"
    echo "  docker compose logs --tail=50 backend"
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
echo "⚠️ SEARCH TOÀN VĂN — cần nạp index sau khi deploy:"
echo "   Lúc boot, backend chỉ tạo index + alias (rỗng). Scheduler reconcile"
echo "   chỉ quét sản phẩm đổi trong 5 phút gần nhất, nên index có thể rỗng."
echo "   Admin phải gọi reindex 1 lần (idempotent):"
echo "     curl -X POST http://localhost:8080/api/v1/admin/search/reindex \\"
echo "          -H \"Authorization: Bearer \$ADMIN_TOKEN\""
echo "   Kiểm tra số document trong index:"
echo "     curl http://localhost:8080/api/v1/admin/search/status \\"
echo "          -H \"Authorization: Bearer \$ADMIN_TOKEN\""
echo ""
VPS_IP=$(grep '^VPS_IP=' .env | cut -d= -f2-)
echo "  • Truy cập:       http://${VPS_IP}"
echo "  • Swagger UI:     http://${VPS_IP}/swagger-ui.html"
