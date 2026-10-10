#!/usr/bin/env bash
# =====================================================================
# Remove old frontend repo + Docker image.
# Run this on VPS AFTER migrating to flash-sale-b2c-fe successfully
# (i.e. the new frontend is running and healthcheck passes).
#
# Old repo: /opt/flash-sale/flash-sale-b2c/        (owner ngominhkhoi05)
# New repo: /opt/flash-sale/flash-sale-b2c-fe/    (owner trangkimdat2005)
#
# Actions:
#   1. Stop + remove container 'flash-sale-b2c-frontend'
#   2. Remove Docker image 'flash-sale-b2c-frontend:latest'
#   3. Remove folder /opt/flash-sale/flash-sale-b2c/
#   4. Rebuild image from new repo (in case current image is from old code)
#   5. Restart frontend
#   6. Print container status
#
# Does NOT touch backend / redis / nginx -- frontend only.
# =====================================================================

set -e

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=================================================="
echo "  Remove Old Frontend"
echo "  Deploy dir: $DEPLOY_DIR"
echo "=================================================="

# ── 1. Stop + remove container frontend ───────────────────────────────
echo "==> Stopping frontend container (old)..."
cd "$DEPLOY_DIR"
docker compose stop frontend 2>/dev/null || echo "    (container not running, skipped)"
docker compose rm -f frontend 2>/dev/null || echo "    (container not found, skipped)"

# ── 2. Remove old Docker image ────────────────────────────────────────
echo ""
echo "==> Removing old frontend image..."
if docker images --format '{{.Repository}}:{{.Tag}}' | grep -q '^flash-sale-b2c-frontend:latest$'; then
    docker image rm -f flash-sale-b2c-frontend:latest
    echo "    Removed flash-sale-b2c-frontend:latest"
else
    echo "    (no flash-sale-b2c-frontend:latest image found, skipped)"
fi

# ── 3. Remove old repo folder ─────────────────────────────────────────
echo ""
echo "==> Removing old frontend repo folder..."
if [ -d "/opt/flash-sale/flash-sale-b2c" ]; then
    rm -rf /opt/flash-sale/flash-sale-b2c
    echo "    Removed /opt/flash-sale/flash-sale-b2c/"
else
    echo "    (no /opt/flash-sale/flash-sale-b2c/ folder, skipped)"
fi

# ── 4. Rebuild image from new repo ────────────────────────────────────
echo ""
if [ -d "/opt/flash-sale/flash-sale-b2c-fe" ]; then
    echo "==> Rebuilding frontend image from new repo (flash-sale-b2c-fe)..."
    cd /opt/flash-sale/flash-sale-b2c-fe
    docker build -t flash-sale-b2c-frontend:latest \
        --build-arg NEXT_PUBLIC_API_URL=/api/v1 \
        --build-arg NEXT_PUBLIC_WS_URL= \
        -f /opt/flash-sale/deploy-b2c-utc2/docker/frontend.Dockerfile \
        /opt/flash-sale/flash-sale-b2c-fe/
else
    echo "ERROR: /opt/flash-sale/flash-sale-b2c-fe/ not found."
    echo "Clone the new repo first, then re-run this script:"
    echo "  cd /opt/flash-sale"
    echo "  git clone https://github.com/trangkimdat2005/flash-sale-b2c-fe.git flash-sale-b2c-fe"
    exit 1
fi

# ── 5. Restart new frontend ───────────────────────────────────────────
echo ""
echo "==> Starting new frontend..."
cd "$DEPLOY_DIR"
docker compose up -d --no-deps frontend

# ── 6. Print status ───────────────────────────────────────────────────
echo ""
echo "==> Container status:"
docker compose ps

echo ""
echo "==> Frontend healthcheck:"
sleep 5
HEALTH=$(docker inspect --format='{{.State.Health.Status}}' flash-sale-b2c-frontend 2>/dev/null || echo "unknown")
echo "    flash-sale-b2c-frontend: $HEALTH"

echo ""
echo "=================================================="
echo "  Done. Old frontend repo + image removed."
echo "=================================================="
echo ""
echo "Next steps:"
echo "  - Full health check:   $DEPLOY_DIR/scripts/check-health.sh"
echo "  - View new FE logs:    docker compose logs -f frontend"
echo ""