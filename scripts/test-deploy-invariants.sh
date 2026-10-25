#!/usr/bin/env bash
# =====================================================================
# Flash Sale B2C - Invariant tests for deploy scripts
# =====================================================================
# Run: ./scripts/test-deploy-invariants.sh
#
# No Docker required, no network required - only reads files in this repo.
# Purpose: catch "deploy finished but search is broken" regressions BEFORE
# merging into main.
#
# WHY this file is ASCII-only:
#   The Write tool on this machine emits UTF-16LE without BOM. Vietnamese
#   diacritics would be mangled and the shebang would break. Keeping this
#   script pure ASCII avoids the whole encoding class of bugs.
# =====================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"

COMPOSE_FILE="$DEPLOY_DIR/docker-compose.yml"
DEPLOY_SH="$DEPLOY_DIR/scripts/deploy.sh"
WORKFLOW="$DEPLOY_DIR/.github/workflows/deploy-dev.yml"

PASS=0
FAIL=0

if [ -t 1 ]; then
    C_OK=$(printf '\033[32m'); C_BAD=$(printf '\033[31m'); C_OFF=$(printf '\033[0m')
else
    C_OK=""; C_BAD=""; C_OFF=""
fi

pass() { printf '  %sPASS%s %s\n' "$C_OK" "$C_OFF" "$1"; PASS=$((PASS + 1)); }
fail() { printf '  %sFAIL%s %s\n' "$C_BAD" "$C_OFF" "$1"; FAIL=$((FAIL + 1)); }

# --- Helpers ---------------------------------------------------------

# Count services declared in docker-compose.yml.
# A service name sits at indent 2 under the "services:" key.
count_compose_services() {
    awk '
        /^services:[ \t]*$/ { in_services = 1; next }
        # A new top-level key (no indent) ends the services block.
        in_services && /^[a-zA-Z_][a-zA-Z0-9_-]*:/ { exit }
        # Service name: indent 2, no inline value.
        in_services && /^  [a-zA-Z_][a-zA-Z0-9_-]*:[ \t]*$/ { count++ }
        END { print count + 0 }
    ' "$COMPOSE_FILE"
}

# First line number matching a pattern, or empty.
# Comment lines are skipped: the workflow documents the old broken command
# inside "# ..." comments, and those must not be mistaken for real commands.
line_of() {
    local file="$1" pattern="$2"
    grep -n -- "$pattern" "$file" \
        | grep -v -- '^[0-9]*:[[:space:]]*#' \
        | head -1 | cut -d: -f1
}

# --- Test 1: EXPECTED in deploy.sh matches compose service count -----
echo "[1] deploy.sh EXPECTED matches docker-compose.yml service count"
COMPOSE_SERVICE_COUNT=$(count_compose_services)
EXPECTED_DECL=$(grep -oE '^EXPECTED=[0-9]+' "$DEPLOY_SH" | head -1 | cut -d= -f2)

if [ -z "$EXPECTED_DECL" ]; then
    fail "deploy.sh does not declare EXPECTED=<number>"
elif [ "$EXPECTED_DECL" = "$COMPOSE_SERVICE_COUNT" ]; then
    pass "EXPECTED=$EXPECTED_DECL == $COMPOSE_SERVICE_COUNT services in compose"
else
    fail "EXPECTED=$EXPECTED_DECL but compose declares $COMPOSE_SERVICE_COUNT services"
fi

# --- Test 2: workflow starts opensearch BEFORE backend ---------------
echo "[2] deploy-dev.yml: opensearch starts before backend"
OS_LINE=$(line_of "$WORKFLOW" 'docker compose up.*opensearch')
BACKEND_LINE=$(line_of "$WORKFLOW" 'docker compose up.*backend')

if [ -z "$OS_LINE" ]; then
    fail "workflow has no 'docker compose up ... opensearch'"
elif [ -z "$BACKEND_LINE" ]; then
    fail "workflow has no 'docker compose up ... backend'"
elif [ "$OS_LINE" -lt "$BACKEND_LINE" ]; then
    pass "opensearch (line $OS_LINE) starts before backend (line $BACKEND_LINE)"
else
    fail "opensearch (line ${OS_LINE:-none}) must start BEFORE backend (line ${BACKEND_LINE:-none})"
fi

# --- Test 3: workflow waits for opensearch health --------------------
echo "[3] deploy-dev.yml: waits for opensearch health (--wait)"
# Real (non-comment) opensearch up command.
OS_CMD=$(grep -n -- 'docker compose up.*opensearch' "$WORKFLOW" \
    | grep -v -- '^[0-9]*:[[:space:]]*#' \
    | head -1 | sed 's/^[0-9]*://')

if [ -z "$OS_CMD" ]; then
    fail "could not find opensearch up command"
elif echo "$OS_CMD" | grep -q -- '--wait'; then
    pass "opensearch uses --wait (health gate applied)"
else
    fail "opensearch missing --wait -> backend may boot before OS is healthy"
fi

# --- Test 4: workflow bounds the OS wait ----------------------------
echo "[4] deploy-dev.yml: has --wait-timeout (no infinite hang)"
if echo "$OS_CMD" | grep -q -- '--wait-timeout'; then
    pass "has --wait-timeout"
else
    fail "missing --wait-timeout -> CI can hang forever if OS is unhealthy"
fi

# --- Test 5: workflow builds the opensearch image --------------------
echo "[5] deploy-dev.yml: builds opensearch image (service uses build key)"
if grep -q -- 'docker compose build opensearch' "$WORKFLOW"; then
    pass "has 'docker compose build opensearch'"
else
    fail "missing 'docker compose build opensearch' -> VPS has no local image"
fi

# --- Test 6: deploy.sh keeps depends_on (no --no-deps) ----------------
echo "[6] deploy.sh: keeps depends_on service_healthy (no --no-deps)"
if grep -q -- '--no-deps' "$DEPLOY_SH"; then
    fail "deploy.sh uses --no-deps -> skips depends_on opensearch service_healthy"
else
    pass "deploy.sh does not use --no-deps"
fi

# --- Test 7: workflow keeps --no-deps for backend/frontend -----------
echo "[7] deploy-dev.yml: keeps --no-deps for backend/frontend"
if grep -q -- 'docker compose up -d --no-deps backend frontend' "$WORKFLOW"; then
    pass "backend/frontend still use --no-deps (nginx not recreated unintentionally)"
else
    fail "backend/frontend no longer use --no-deps -> may recreate nginx before reload"
fi

# --- Test 8: check-health.sh verifies OpenSearch -----------------------
echo "[8] check-health.sh: probes OpenSearch (not just redis/backend/nginx)"
if grep -q -- 'localhost:9200' "$DEPLOY_DIR/scripts/check-health.sh"; then
    pass "check-health.sh probes OpenSearch on :9200"
else
    fail "check-health.sh does not probe OpenSearch -> search breakage stays invisible"
fi

# --- Test 9: deploy.sh prints the reindex instruction -----------------
echo "[9] deploy.sh: tells the operator to reindex after deploy"
if grep -q -- 'admin/search/reindex' "$DEPLOY_SH"; then
    pass "deploy.sh prints the reindex command"
else
    fail "deploy.sh does not mention reindex -> index stays empty after deploy"
fi

# --- Test 10: OpenSearch image ships a cert with SAN=opensearch -------
# The demo certificate has SAN = node-0.example.com / localhost / 127.0.0.1
# and NEVER contains "opensearch", which is the Compose service name the
# backend connects to. With ssl-trust-all=false the handshake fails with
# "No subject alternative names matching opensearch found" and full-text
# search silently falls back to PostgreSQL LIKE.
echo "[10] OpenSearch image builds a node certificate with SAN=opensearch"
GEN_CERTS="$DEPLOY_DIR/docker/opensearch/generate-certs.sh"
OS_DOCKERFILE="$DEPLOY_DIR/docker/opensearch/Dockerfile"

if [ ! -f "$GEN_CERTS" ]; then
    fail "docker/opensearch/generate-certs.sh is missing"
elif ! grep -q 'DNS:opensearch' "$GEN_CERTS"; then
    fail "generate-certs.sh does not put DNS:opensearch in the node certificate SAN"
elif ! grep -q 'verify_hostname opensearch' "$GEN_CERTS"; then
    fail "generate-certs.sh does not verify the SAN for hostname 'opensearch'"
else
    pass "generate-certs.sh creates + verifies a node cert with SAN DNS:opensearch"
fi

# --- Test 11: the cert is baked into the OpenSearch image -------------
echo "[11] OpenSearch Dockerfile bakes the certificates into the image"
if [ ! -f "$OS_DOCKERFILE" ]; then
    fail "docker/opensearch/Dockerfile is missing"
elif ! grep -q -- '--from=certbuilder' "$OS_DOCKERFILE"; then
    fail "Dockerfile does not COPY the generated certificates into the image"
elif ! grep -q 'esnode.pem' "$OS_DOCKERFILE"; then
    fail "Dockerfile does not install esnode.pem (the node certificate)"
elif ! grep -q 'root-ca.pem' "$OS_DOCKERFILE"; then
    fail "Dockerfile does not install root-ca.pem (the CA the backend must trust)"
else
    pass "Dockerfile bakes esnode.pem + root-ca.pem into the image"
fi

# --- Test 12: backend gets a truststore with the JDK default CAs ------
# -Djavax.net.ssl.trustStore REPLACES the JVM default CA set. A truststore
# with only the search CA breaks Supabase / Cloudinary / ZaloPay / Google
# OAuth, so the truststore must be built from the JDK cacerts + the CA.
echo "[12] backend truststore contains the JDK default CAs + the search CA"
if [ ! -f "$DEPLOY_DIR/scripts/build-truststore.sh" ]; then
    fail "scripts/build-truststore.sh is missing"
elif ! grep -q 'cacerts' "$DEPLOY_DIR/scripts/build-truststore.sh"; then
    fail "build-truststore.sh does not start from the JDK default cacerts"
elif ! grep -q 'fs-search-ca' "$DEPLOY_DIR/scripts/build-truststore.sh"; then
    fail "build-truststore.sh does not import the search CA"
else
    pass "build-truststore.sh builds the truststore from cacerts + the search CA"
fi

# --- Test 13: compose mounts the truststore into the backend ----------
# Without the mount the backend has no way to trust the OpenSearch CA and
# fails to boot with "Invalid keystore format" (or silently falls back).
echo "[13] docker-compose.yml mounts the truststore into the backend"
if ! grep -q 'truststore.p12' "$COMPOSE_FILE"; then
    fail "docker-compose.yml does not mount truststore.p12 into the backend"
elif ! grep -q 'javax.net.ssl.trustStore' "$COMPOSE_FILE"; then
    fail "docker-compose.yml does not set -Djavax.net.ssl.trustStore for the backend"
elif ! grep -q 'javax.net.ssl.trustStoreType' "$COMPOSE_FILE"; then
    fail "docker-compose.yml does not set -Djavax.net.ssl.trustStoreType=PKCS12"
else
    pass "backend receives truststore.p12 + the matching JVM system properties"
fi

# --- Test 14: the CA is exported from the built image -----------------
# Keeping a copy of the CA in the repo would let it drift away from the CA
# that actually signed the OpenSearch certificate, breaking the handshake.
echo "[14] the CA is exported from the built image (no drift)"
EXPORT_CA="$DEPLOY_DIR/scripts/export-opensearch-ca.sh"
if [ ! -f "$EXPORT_CA" ]; then
    fail "scripts/export-opensearch-ca.sh is missing"
elif ! grep -q 'root-ca.pem' "$EXPORT_CA"; then
    fail "export-opensearch-ca.sh does not read root-ca.pem from the image"
elif ! grep -q 'docker cp' "$EXPORT_CA"; then
    fail "export-opensearch-ca.sh does not extract the CA from the image"
else
    pass "the CA is extracted from the built image, so it cannot drift"
fi

# --- Test 15: deploy.sh gates on the TLS handshake -------------------
# "All containers running" is NOT the same as "search works". A backend
# that cannot complete the handshake still starts fine and silently serves
# LIKE-based search results.
echo "[15] deploy.sh verifies the backend -> OpenSearch TLS handshake"
if ! grep -q 'export-opensearch-ca.sh' "$DEPLOY_SH"; then
    fail "deploy.sh does not export the OpenSearch CA"
elif ! grep -q 'build-truststore.sh' "$DEPLOY_SH"; then
    fail "deploy.sh does not build the backend truststore"
elif ! grep -q 'https://opensearch:9200' "$DEPLOY_SH"; then
    fail "deploy.sh does not probe https://opensearch:9200 (the SAN-sensitive URL)"
else
    pass "deploy.sh exports the CA, builds the truststore and probes the TLS handshake"
fi

# --- Test 16: the CI workflow builds the truststore before the backend --
echo "[16] deploy-dev.yml builds the truststore BEFORE starting the backend"
CA_LINE=$(line_of "$WORKFLOW" 'export-opensearch-ca.sh')
TS_LINE=$(line_of "$WORKFLOW" 'build-truststore.sh')
BACKEND_LINE=$(line_of "$WORKFLOW" 'docker compose up.*backend')

if [ -z "$CA_LINE" ]; then
    fail "workflow has no 'export-opensearch-ca.sh'"
elif [ -z "$TS_LINE" ]; then
    fail "workflow has no 'build-truststore.sh'"
elif [ -z "$BACKEND_LINE" ]; then
    fail "workflow has no 'docker compose up ... backend'"
elif [ "$CA_LINE" -lt "$BACKEND_LINE" ] && [ "$TS_LINE" -lt "$BACKEND_LINE" ]; then
    pass "CA export (line $CA_LINE) and truststore build (line $TS_LINE) precede the backend (line $BACKEND_LINE)"
else
    fail "the truststore must be built BEFORE the backend starts (backend at line ${BACKEND_LINE:-none})"
fi

# --- Test 17: the OpenSearch healthcheck verifies the certificate -----
# `curl -k` skips certificate verification, so a broken or wrong-SAN
# certificate would still report healthy -> the backend would boot and
# then fail the handshake.
echo "[17] the OpenSearch healthcheck verifies the certificate (no -k)"
OS_HEALTH=$(awk '/healthcheck:/,/networks:/' "$COMPOSE_FILE" | grep -n 'curl' | grep 'cluster/health' | head -1)
if [ -z "$OS_HEALTH" ]; then
    fail "could not find the OpenSearch healthcheck curl command"
elif echo "$OS_HEALTH" | grep -q -- '-k'; then
    fail "the OpenSearch healthcheck still uses -k -> a broken cert would report healthy"
elif ! echo "$OS_HEALTH" | grep -q -- '--cacert'; then
    fail "the OpenSearch healthcheck does not use --cacert -> the cert is never verified"
else
    pass "the OpenSearch healthcheck verifies the certificate via --cacert"
fi

# --- Test 18: the generated secrets are not committed ----------------
echo "[18] the generated OpenSearch TLS material stays out of git"
if ! grep -q 'secrets/opensearch/' "$DEPLOY_DIR/.gitignore"; then
    fail ".gitignore does not exclude secrets/opensearch/ -> the CA and truststore could be committed"
elif git -C "$DEPLOY_DIR" ls-files --error-unmatch secrets/opensearch >/dev/null 2>&1; then
    fail "secrets/opensearch is tracked by git -> the CA private key would be exposed"
else
    pass "secrets/opensearch/ is ignored and untracked"
fi

# --- Summary ---------------------------------------------------------
echo ""
echo "=================================================="
if [ "$FAIL" -eq 0 ]; then
    echo "  PASS: $PASS/$((PASS + FAIL)) invariant tests"
    echo "=================================================="
    exit 0
fi
echo "  FAIL: $FAIL/$((PASS + FAIL)) invariant tests failed"
echo "=================================================="
exit 1
