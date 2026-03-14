#!/usr/bin/env bash
set -euo pipefail

ARTIFACTS_DIR="${ARTIFACTS_DIR:-artifacts/coverage}"

mkdir -p "${ARTIFACTS_DIR}"
rm -f "${ARTIFACTS_DIR}/luacov.stats.out" \
      "${ARTIFACTS_DIR}/luacov.report.out"

echo "[coverage] busted unit + integration with luacov"
busted --coverage spec/unit/ spec/integration/

echo "[coverage] luacov text report"
luacov
