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
# NOTE: comments are intentionally ASCII-only so the build never depends on
#       the encoding of the build context.
# =====================================================================

FROM opensearchproject/opensearch:3

# Install analysis-icu (required by the `vi_folded` analyzer in the index mapping).
RUN /usr/share/opensearch/bin/opensearch-plugin install --batch analysis-icu
