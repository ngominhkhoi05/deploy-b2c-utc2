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
