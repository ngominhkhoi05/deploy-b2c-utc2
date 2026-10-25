#!/usr/bin/env bash
# =====================================================================
# Flash Sale B2C - Export the OpenSearch CA from the built image
# =====================================================================
# Run on the VPS, AFTER `docker compose build opensearch`:
#   ./scripts/export-opensearch-ca.sh
#
# WHY this exists:
#   The OpenSearch node certificate is baked into the image at build time,
#   so the private CA that signed it also lives in the image. The backend
#   must trust exactly that CA, otherwise the TLS handshake fails with
#     "PKIX path building failed" / "No subject alternative names matching
#      opensearch found"
#   and full-text search silently falls back to PostgreSQL LIKE.
#
#   Exporting the CA from the image (instead of keeping a separate copy in
#   the repo) guarantees the CA the backend trusts and the CA that signed
#   the OpenSearch certificate can never drift apart - a rebuild that
#   regenerates the CA automatically invalidates the old truststore.
#
# Output:
#   ./secrets/opensearch/ca.pem    public CA certificate (safe to keep)
#
# The CA private key (ca.key) is NOT exported. It stays inside the image
# and is never needed at runtime.
# =====================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
cd "$DEPLOY_DIR"

OS_IMAGE="${OS_IMAGE:-flash-sale-b2c-opensearch:3-local}"
OUT_DIR="$DEPLOY_DIR/secrets/opensearch"
OUT_FILE="$OUT_DIR/ca.pem"

echo "==> Exporting the OpenSearch CA from image '${OS_IMAGE}'"

if ! docker image inspect "$OS_IMAGE" >/dev/null 2>&1; then
    echo "❌ Image '${OS_IMAGE}' not found. Build it first:"
    echo "   docker compose build opensearch"
    exit 1
fi

mkdir -p "$OUT_DIR"

# `docker create` does not start the container, so nothing from the image runs.
TMP_CONTAINER=$(docker create "$OS_IMAGE" 2>/dev/null)
trap 'docker rm -f "$TMP_CONTAINER" >/dev/null 2>&1 || true' EXIT

if ! docker cp "$TMP_CONTAINER:/usr/share/opensearch/config/root-ca.pem" "$OUT_FILE" 2>/dev/null; then
    echo "❌ Could not read root-ca.pem from the image."
    echo "   The image may predate the TLS fix - rebuild it:"
    echo "   docker compose build --no-cache opensearch"
    exit 1
fi

chmod 644 "$OUT_FILE"

# Sanity check: the file must be a PEM certificate.
if ! head -1 "$OUT_FILE" | grep -q "BEGIN CERTIFICATE"; then
    echo "❌ ${OUT_FILE} is not a PEM certificate - aborting."
    rm -f "$OUT_FILE"
    exit 1
fi

echo "✅ CA exported to ${OUT_FILE}"
echo ""
echo "Next step - build the backend truststore that trusts this CA:"
echo "  ./scripts/build-truststore.sh"
