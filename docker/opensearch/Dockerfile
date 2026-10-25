# =====================================================================
# Flash Sale B2C - OpenSearch Dockerfile (full-text search engine)
# =====================================================================
# Build:
#   docker compose build opensearch
#
# WHY a custom image is needed:
#   Plugin `analysis-icu` is NOT bundled in `opensearchproject/opensearch`.
#   `icu_folding` is the analyzer that folds Vietnamese diacritics CORRECTLY
#   (it also maps `d`/`D` -> `d`, `o`/`u` -> `o`/`u`). The built-in
#   `asciifolding` does NOT map `d` (U+0111), so "do" would not match "du".
#
# WHY the TLS material is baked into the image:
#   The demo certificate OpenSearch generates has
#   SAN = node-0.example.com, localhost, 127.0.0.1. It NEVER contains
#   "opensearch", which is the Docker Compose service name the backend
#   connects to. With `opensearch.ssl-trust-all: false` (the production
#   default) the backend handshake fails with
#     "No subject alternative names matching opensearch found"
#   and full-text search silently falls back to PostgreSQL LIKE.
#
#   generate-certs.sh creates a private CA and a node certificate whose SAN
#   contains DNS:opensearch, and the certificate is baked into the image.
#   The material survives every container start: the OpenSearch security
#   demo installer PRESERVES an existing esnode.pem / esnode-key.pem /
#   root-ca.pem / kirk.pem / kirk-key.pem byte-for-byte (verified against
#   OpenSearch 3.9.0), it only fills in the rest of the demo configuration.
#
#   The CA public certificate is also exported from the image so the backend
#   truststore and the OpenSearch certificate can never drift apart - see
#   scripts/export-opensearch-ca.sh.
#
# NOTE: comments are intentionally ASCII-only so the build never depends on
#       the encoding of the build context.
# =====================================================================

# ── Stage 1: TLS material ──────────────────────────────────────────────
# generate-certs.sh needs openssl (CA + node certificate) and keytool (JVM
# truststore). The JDK image provides keytool but no openssl.
FROM eclipse-temurin:25-jdk-jammy AS certbuilder

RUN apt-get update \
    && apt-get install -y --no-install-recommends openssl \
    && rm -rf /var/lib/apt/lists/*

COPY generate-certs.sh /usr/local/bin/generate-certs.sh
RUN chmod +x /usr/local/bin/generate-certs.sh \
    && /usr/local/bin/generate-certs.sh /certsout

# ── Stage 2: OpenSearch runtime ─────────────────────────────────────────
FROM opensearchproject/opensearch:3

# Install analysis-icu (required by the `vi_folded` analyzer in the index mapping).
RUN /usr/share/opensearch/bin/opensearch-plugin install --batch analysis-icu

# Bake the certificates into the OpenSearch config dir.
# The security plugin reads these exact paths (see the demo installer's
# opensearch.yml): esnode.pem + esnode-key.pem + root-ca.pem for the node
# certificate, and kirk.pem + kirk-key.pem for the admin certificate used
# by securityadmin.sh. The kirk DN must stay
# CN=kirk,OU=client,O=client,L=test,C=de because that is what the demo
# installer writes into plugins.security.authcz.admin_dn.
COPY --from=certbuilder /certsout/esnode.pem     /usr/share/opensearch/config/esnode.pem
COPY --from=certbuilder /certsout/esnode-key.pem /usr/share/opensearch/config/esnode-key.pem
COPY --from=certbuilder /certsout/ca.pem         /usr/share/opensearch/config/root-ca.pem
COPY --from=certbuilder /certsout/kirk.pem       /usr/share/opensearch/config/kirk.pem
COPY --from=certbuilder /certsout/kirk-key.pem   /usr/share/opensearch/config/kirk-key.pem

# The security plugin requires the private keys to be readable only by the
# process owner (uid 1000) and warns loudly about loose permissions.
# The base image runs as uid 1000, so switch to root just to fix ownership.
USER root
RUN chmod 600 /usr/share/opensearch/config/esnode-key.pem \
        /usr/share/opensearch/config/kirk-key.pem \
    && chmod 644 /usr/share/opensearch/config/esnode.pem \
        /usr/share/opensearch/config/root-ca.pem \
        /usr/share/opensearch/config/kirk.pem \
    && chown -R 1000:1000 /usr/share/opensearch/config

# Restore the non-root user required by the OpenSearch entrypoint.
USER 1000
