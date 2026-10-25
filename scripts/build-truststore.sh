#!/usr/bin/env bash
# =====================================================================
# Flash Sale B2C - Build the backend JVM truststore for OpenSearch
# =====================================================================
# Run on the VPS, AFTER ./scripts/export-opensearch-ca.sh:
#   ./scripts/build-truststore.sh
#
# WHY a truststore and not a system property per CA:
#   -Djavax.net.ssl.trustStore REPLACES the JVM default CA set. A truststore
#   holding only the search CA would break every outbound HTTPS call the
#   backend makes: Supabase (PostgreSQL over TLS), Cloudinary (image upload),
#   ZaloPay (payment callback) and Google OAuth. So the truststore is built
#   from the JDK default cacerts PLUS the OpenSearch CA (119 entries).
#
# WHY the truststore is built inside a container:
#   The default CA set must match the backend runtime exactly. Building it
#   with the same image (eclipse-temurin:25-jre-jammy) that runs the backend
#   guarantees an identical cacerts, even when the JDK image is updated.
#   It also means the VPS host needs no JDK installed.
#
# Output:
#   ./secrets/opensearch/truststore.p12
#
# NOTE: the truststore password is NOT a secret. It only protects public CA
#       certificates - the same convention the JDK uses for its own cacerts
#       ("changeit"). The private CA key never leaves the OpenSearch image.
# =====================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
cd "$DEPLOY_DIR"

JRE_IMAGE="${JRE_IMAGE:-eclipse-temurin:25-jre-jammy}"
TRUSTSTORE_PASSWORD="${TRUSTSTORE_PASSWORD:-changeit}"
CERT_DIR="$DEPLOY_DIR/secrets/opensearch"
CA_FILE="$CERT_DIR/ca.pem"
TRUSTSTORE_FILE="$CERT_DIR/truststore.p12"

echo "==> Building the OpenSearch truststore"

if [ ! -f "$CA_FILE" ]; then
    echo "❌ CA certificate not found: ${CA_FILE}"
    echo "   Export it from the built image first:"
    echo "   ./scripts/export-opensearch-ca.sh"
    exit 1
fi

if ! head -1 "$CA_FILE" | grep -q "BEGIN CERTIFICATE"; then
    echo "❌ ${CA_FILE} is not a PEM certificate."
    exit 1
fi

mkdir -p "$CERT_DIR"
rm -f "$TRUSTSTORE_FILE"

# Build the truststore inside the backend runtime image:
#   1. copy the JDK default cacerts
#   2. import the OpenSearch CA into it
#   3. convert to PKCS12 (the format the backend loads)
docker run --rm \
    -v "$CERT_DIR:/out" \
    -e "TRUSTSTORE_PASSWORD=${TRUSTSTORE_PASSWORD}" \
    --entrypoint sh \
    "$JRE_IMAGE" -c '
        set -e
        cp /opt/java/openjdk/lib/security/cacerts /tmp/cacerts-work
        keytool -importcert -noprompt \
            -alias fs-search-ca \
            -file /out/ca.pem \
            -keystore /tmp/cacerts-work \
            -storepass "$TRUSTSTORE_PASSWORD" >/dev/null
        keytool -importkeystore \
            -srckeystore /tmp/cacerts-work \
            -srcstoretype JKS \
            -srcstorepass "$TRUSTSTORE_PASSWORD" \
            -destkeystore /out/truststore.p12 \
            -deststoretype PKCS12 \
            -deststorepass "$TRUSTSTORE_PASSWORD" >/dev/null
        rm -f /tmp/cacerts-work
    '

if [ ! -f "$TRUSTSTORE_FILE" ]; then
    echo "❌ Truststore was not created at ${TRUSTSTORE_FILE}"
    exit 1
fi

chmod 644 "$TRUSTSTORE_FILE"

# Verify: the search CA must be present AND the JDK default CAs must still be
# there (otherwise Supabase / Cloudinary / ZaloPay / Google OAuth break).
ENTRIES=$(docker run --rm \
    -v "$CERT_DIR:/out:ro" \
    -e "TRUSTSTORE_PASSWORD=${TRUSTSTORE_PASSWORD}" \
    --entrypoint sh \
    "$JRE_IMAGE" -c "
        keytool -list -keystore /out/truststore.p12 -storetype PKCS12 \
            -storepass \"\$TRUSTSTORE_PASSWORD\" 2>/dev/null \
        | grep -c trustedCertEntry
    ")

HAS_CA=$(docker run --rm \
    -v "$CERT_DIR:/out:ro" \
    -e "TRUSTSTORE_PASSWORD=${TRUSTSTORE_PASSWORD}" \
    --entrypoint sh \
    "$JRE_IMAGE" -c "
        keytool -list -keystore /out/truststore.p12 -storetype PKCS12 \
            -storepass \"\$TRUSTSTORE_PASSWORD\" 2>/dev/null \
        | grep -c 'fs-search-ca'
    ")

if [ "$HAS_CA" -lt 1 ]; then
    echo "❌ The truststore does not contain the search CA (alias fs-search-ca)."
    exit 1
fi

# The JDK ships ~118 CAs. A truststore with only our CA would silently break
# every other outbound HTTPS call, so refuse to continue in that case.
if [ "$ENTRIES" -lt 100 ]; then
    echo "❌ The truststore only holds ${ENTRIES} certificates."
    echo "   The JDK default CAs are missing - outbound HTTPS calls to Supabase,"
    echo "   Cloudinary, ZaloPay and Google OAuth would fail."
    exit 1
fi

echo "✅ Truststore built: ${TRUSTSTORE_FILE} (${ENTRIES} certificates, search CA present)"
