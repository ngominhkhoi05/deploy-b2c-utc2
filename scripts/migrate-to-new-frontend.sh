#!/usr/bin/env bash
# =====================================================================
# One-time migration to the new frontend repo flash-sale-b2c-fe.
#
# Run on VPS Ubuntu to switch from:
#   old repo: /opt/flash-sale/flash-sale-b2c/         (ngominhkhoi05)
# to:
#   new repo: /opt/flash-sale/flash-sale-b2c-fe/     (trangkimdat2005)
#
# Steps:
#   1. git pull latest code for deploy + BE repos
#   2. git clone new FE repo (if not present)
#   3. Rebuild backend image (picks up CORS fix commit dfe0098)
#   4. Rebuild frontend image from new repo with correct build-arg names
#   5. Recreate backend + start new frontend
#   6. Verify: 4/4 containers healthy + smoke test through Nginx
#
# AFTER this script finishes and all smoke tests pass, run:
#   ./scripts/remove-old-frontend.sh
# to clean up the old repo + image.
#
# Requirements:
#   - VPS already running the old stack successfully
#   - .env + redis.env already exist in /opt/flash-sale/deploy-b2c-utc2/
#   - Good network (git clone + docker build consume bandwidth)
# =====================================================================

set -e

FLASH_SALE_DIR="/opt/flash-sale"
DEPLOY_DIR="$FLASH_SALE_DIR/deploy-b2c-utc2"

cd "$FLASH_SALE_DIR"

echo "=================================================="
echo "  Migrate to flash-sale-b2c-fe"
echo "  Working dir: $FLASH_SALE_DIR"
echo "=================================================="

# ── 1. Update deploy + BE code ────────────────────────────────────────
echo ""
echo "==> 1/6. git pull deploy + BE repos..."
cd "$DEPLOY_DIR"
git pull --no-rebase || { echo "ERROR: git pull deploy repo failed. Resolve conflict manually then re-run."; exit 1; }

cd "$FLASH_SALE_DIR/flash-sale-b2c-UTC2"
git pull --no-rebase || { echo "ERROR: git pull BE repo failed."; exit 1; }
echo "    deploy + BE code updated"

# ── 2. Clone new FE repo ──────────────────────────────────────────────
echo ""
echo "==> 2/6. Clone new FE repo (flash-sale-b2c-fe)..."
if [ -d "$FLASH_SALE_DIR/flash-sale-b2c-fe" ]; then
    echo "    Folder exists, running git pull instead"
    cd "$FLASH_SALE_DIR/flash-sale-b2c-fe"
    git pull --no-rebase || { echo "ERROR: git pull FE repo failed."; exit 1; }
else
    git clone https://github.com/trangkimdat2005/flash-sale-b2c-fe.git \
        "$FLASH_SALE_DIR/flash-sale-b2c-fe" || { echo "ERROR: git clone failed."; exit 1; }
fi
echo "    New FE repo ready"

# ── 3. Rebuild backend image ─────────────────────────────────────────
echo ""
echo "==> 3/6. Rebuild backend image (picks up CORS fix dfe0098)..."
cd "$FLASH_SALE_DIR/flash-sale-b2c-UTC2"
docker build -t flash-sale-b2c-backend:latest \
    -f "$DEPLOY_DIR/docker/backend.Dockerfile" \
    "$FLASH_SALE_DIR/flash-sale-b2c-UTC2/"
echo "    Backend image built"

# ── 4. Rebuild frontend image from new repo ──────────────────────────
# ⚠️ Tất cả biến NEXT_PUBLIC_* là BUILD-TIME trong Next.js (xem
# deploy-b2c-utc2/.env.example PHẦN 10). Phải truyền qua --build-arg,
# KHÔNG truyền runtime qua env_file (sẽ bị bỏ qua).
#
# Giá trị mặc định dưới đây khớp với .env.example PHẦN 10. Nếu muốn
# override, sửa trực tiếp ở đây (không cần sửa .env) — vì build-arg
# là 1-shot, không cần persist.
echo ""
echo "==> 4/6. Rebuild frontend image from new repo..."
cd "$FLASH_SALE_DIR/flash-sale-b2c-fe"
docker build -t flash-sale-b2c-frontend:latest \
    --build-arg NEXT_PUBLIC_API_URL=/api/v1 \
    --build-arg NEXT_PUBLIC_WS_URL= \
    --build-arg NEXT_PUBLIC_USE_MOCK=false \
    --build-arg NEXT_PUBLIC_SITE_URL="${VPS_PUBLIC_URL:-http://<VPS_IP>}" \
    --build-arg NEXT_PUBLIC_DEFAULT_LOCALE=vi \
    -f "$DEPLOY_DIR/docker/frontend.Dockerfile" \
    "$FLASH_SALE_DIR/flash-sale-b2c-fe/"
echo "    Frontend image built (from new repo)"

# ── 5. Recreate backend + start new frontend ─────────────────────────
echo ""
echo "==> 5/6. Recreate backend + start new frontend..."
cd "$DEPLOY_DIR"
docker compose up -d --force-recreate backend
docker compose up -d --no-deps frontend
echo "    Containers started"

# ── 6. Verify ────────────────────────────────────────────────────────
echo ""
echo "==> 6/6. Verify (wait for backend healthy, max 3 minutes)..."
ATTEMPTS=18  # 18 * 10s = 180s
for i in $(seq 1 $ATTEMPTS); do
    sleep 10
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' flash-sale-b2c-backend 2>/dev/null || echo "starting")
    echo "    [$i/$ATTEMPTS] backend health: $STATUS"
    if [ "$STATUS" = "healthy" ]; then
        break
    fi
done

echo ""
echo "==> Container status:"
docker compose ps

echo ""
echo "==> Smoke test via Nginx:"
echo -n "    GET /                       "
curl -s -o /dev/null -w "HTTP %{http_code}\n" "http://localhost/" || echo "FAIL"
echo -n "    GET /api/v1/products       "
curl -s -o /dev/null -w "HTTP %{http_code}\n" "http://localhost/api/v1/products" || echo "FAIL"
echo -n "    GET /actuator/health       "
curl -s -o /dev/null -w "HTTP %{http_code}\n" "http://localhost/actuator/health" || echo "FAIL"
echo -n "    GET /ws/info               "
curl -s -o /dev/null -w "HTTP %{http_code}\n" "http://localhost/ws/info" || echo "FAIL"

echo ""
echo "=================================================="
echo "  Migration complete. Check smoke tests above."
echo "=================================================="
echo ""
echo "If ALL 4 lines return HTTP 200:"
echo "  -> Run: $DEPLOY_DIR/scripts/remove-old-frontend.sh"
echo "     to clean up old frontend folder + image."
echo ""
echo "If any line shows FAIL:"
echo "  -> View logs: docker compose logs -f backend"
echo "  -> See README section 10 (Troubleshooting)"
echo ""