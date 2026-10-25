#!/bin/sh
# =====================================================================
# Flash Sale B2C - Generate the OpenSearch TLS material.
# =====================================================================
# WHY THIS EXISTS
#   The OpenSearch demo certificate has
#   SAN = node-0.example.com, localhost, 127.0.0.1
#   and NEVER contains "opensearch" - the Docker Compose service name the
#   backend connects to. With `opensearch.ssl-trust-all: false` (the
#   production default) the backend TLS handshake therefore fails with
#
#     javax.net.ssl.SSLHandshakeException: (certificate_unknown)
#     No subject alternative names matching opensearch found
#
#   and full-text search silently falls back to PostgreSQL LIKE - wrong
#   diacritics, no relevance ranking. The failure is silent because the
#   gateway catches the error and degrades instead of failing the request.
#
# WHAT THIS CREATES
#   ca.pem / ca.key           private CA (the key never leaves the VPS)
#   esnode.pem / esnode-key.pem   node certificate, SAN includes DNS:opensearch
#   kirk.pem / kirk-key.pem   admin certificate for securityadmin.sh
#   truststore.p12            JVM truststore: JDK default CAs + this CA
#
# WHY THE TRUSTSTORE MUST CONTAIN THE JDK DEFAULT CAs
#   -Djavax.net.ssl.trustStore REPLACES the JVM default CA set. A truststore
#   holding only the search CA would break every outbound HTTPS call the
#   backend makes: Supabase (PostgreSQL over TLS), Cloudinary (image upload),
#   ZaloPay (payment callback) and Google OAuth. The truststore is therefore
#   built from the JDK cacerts PLUS the search CA (119 entries).
#
# IDEMPOTENCY
#   If the certificates already exist they are kept as-is, so a rebuild does
#   not invalidate a truststore that is already mounted on the backend.
#
# NOTE: comments are intentionally ASCII-only so the build never depends on
#       the encoding of the build context.
# =====================================================================

set -eu

OUT_DIR="${1:-/certs}"
CA_DAYS="${CA_DAYS:-3650}"
NODE_DAYS="${NODE_DAYS:-3650}"
TRUSTSTORE_PASSWORD="${TRUSTSTORE_PASSWORD:-changeit}"

# SAN of the node certificate.
#   DNS:opensearch          -> the Compose service name the backend uses.
#   DNS:localhost + loopback -> the container health check hits
#                               https://localhost:9200 from inside.
NODE_SAN="DNS:opensearch,DNS:localhost,IP:127.0.0.1,IP:0:0:0:0:0:0:0:1"

# DN of the admin certificate. MUST match plugins.security.authcz.admin_dn
# that the OpenSearch demo installer writes, otherwise securityadmin.sh is
# rejected and the security index is never initialized.
ADMIN_SUBJECT="/C=de/L=test/O=client/OU=client/CN=kirk"

log() { echo "[generate-certs] $*"; }

if [ -f "$OUT_DIR/esnode.pem" ] && [ -f "$OUT_DIR/kirk.pem" ] && [ -f "$OUT_DIR/ca.pem" ]; then
    log "certificates already present in $OUT_DIR - keeping them (idempotent)"
    exit 0
fi

mkdir -p "$OUT_DIR"
cd "$OUT_DIR"

# ── 1. Private CA ────────────────────────────────────────────────────────
log "generating CA (${CA_DAYS} days)"
openssl req -x509 -newkey rsa:4096 -sha256 -days "$CA_DAYS" -nodes \
    -keyout ca.key -out ca.pem \
    -subj "/C=VN/O=FlashSale B2C/OU=Search/CN=FlashSale Search Root CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"

# ── 2. Node key + CSR ────────────────────────────────────────────────────
log "generating node key and CSR"
openssl req -newkey rsa:2048 -sha256 -nodes \
    -keyout esnode-key.pem -out node.csr \
    -subj "/C=de/L=test/O=node/OU=node/CN=opensearch" \
    -addext "subjectAltName=${NODE_SAN}"

# ── 3. Sign the node certificate with the CA ─────────────────────────────
log "signing node certificate"
cat > node.ext <<EOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=${NODE_SAN}
EOF

openssl x509 -req -in node.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
    -out esnode.pem -days "$NODE_DAYS" -sha256 -extfile node.ext

# ── 4. Admin certificate for securityadmin.sh ────────────────────────────
log "generating admin (kirk) certificate"
openssl req -newkey rsa:2048 -sha256 -nodes \
    -keyout kirk-key.pem -out kirk.csr \
    -subj "$ADMIN_SUBJECT"

cat > kirk.ext <<EOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth
EOF

openssl x509 -req -in kirk.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
    -out kirk.pem -days "$NODE_DAYS" -sha256 -extfile kirk.ext

rm -f node.csr node.ext kirk.csr kirk.ext ca.srl

# ── 5. Truststore: JDK default CAs + our CA ──────────────────────────────
log "building truststore (JDK default CAs + search CA)"
cp "$JAVA_HOME/lib/security/cacerts" ./cacerts-work
keytool -importcert -noprompt -alias fs-search-ca \
    -file ca.pem -keystore ./cacerts-work -storepass "$TRUSTSTORE_PASSWORD" >/dev/null
rm -f truststore.p12
keytool -importkeystore \
    -srckeystore ./cacerts-work -srcstoretype JKS -srcstorepass "$TRUSTSTORE_PASSWORD" \
    -destkeystore truststore.p12 -deststoretype PKCS12 -deststorepass "$TRUSTSTORE_PASSWORD" >/dev/null
rm -f cacerts-work

# ── 6. Verify the result ─────────────────────────────────────────────────
# A broken PKI here produces a container that starts but can never be
# reached, so every invariant is checked before the image is built.
log "verification"

node_pub=$(openssl x509 -in esnode.pem -noout -pubkey | openssl sha256 | awk '{print $NF}')
key_pub=$(openssl pkey -in esnode-key.pem -pubout | openssl sha256 | awk '{print $NF}')
if [ "$node_pub" != "$key_pub" ]; then
    echo "[generate-certs] FATAL: esnode.pem does not match esnode-key.pem" >&2
    exit 1
fi

admin_pub=$(openssl x509 -in kirk.pem -noout -pubkey | openssl sha256 | awk '{print $NF}')
admin_key_pub=$(openssl pkey -in kirk-key.pem -pubout | openssl sha256 | awk '{print $NF}')
if [ "$admin_pub" != "$admin_key_pub" ]; then
    echo "[generate-certs] FATAL: kirk.pem does not match kirk-key.pem" >&2
    exit 1
fi

openssl verify -CAfile ca.pem esnode.pem >/dev/null || {
    echo "[generate-certs] FATAL: esnode.pem is not signed by ca.pem" >&2
    exit 1
}
openssl verify -CAfile ca.pem kirk.pem >/dev/null || {
    echo "[generate-certs] FATAL: kirk.pem is not signed by ca.pem" >&2
    exit 1
}

# The SAN is the whole point of this script - fail loudly if it is missing.
openssl verify -CAfile ca.pem -verify_hostname opensearch esnode.pem >/dev/null || {
    echo "[generate-certs] FATAL: esnode.pem does not verify for hostname 'opensearch'" >&2
    exit 1
}
openssl verify -CAfile ca.pem -verify_hostname localhost esnode.pem >/dev/null || {
    echo "[generate-certs] FATAL: esnode.pem does not verify for hostname 'localhost'" >&2
    exit 1
}

log "OK - node SAN: $(openssl x509 -in esnode.pem -noout -ext subjectAltName | tail -1 | tr -d ' ')"
log "OK - truststore entries: $(keytool -list -keystore truststore.p12 -storetype PKCS12 -storepass "$TRUSTSTORE_PASSWORD" 2>/dev/null | grep -c trustedCertEntry)"
log "done"
