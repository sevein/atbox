#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INTEGRATION_DIR="$ROOT_DIR/hack/integration"
OUTPUT_DIR="${INTEGRATION_DIR}/output"
NPM_CACHE_DIR="${OUTPUT_DIR}/npm-cache"
PLAYWRIGHT_BROWSERS_PATH="${OUTPUT_DIR}/ms-playwright"

mkdir -p "${OUTPUT_DIR}"

echo "Installing integration dependencies (npm ci)"
npm ci --prefix "${INTEGRATION_DIR}" --no-audit --no-fund --cache "${NPM_CACHE_DIR}" >/dev/null

echo "Running Bats integration suite"
PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH}" \
npm --prefix "${INTEGRATION_DIR}" exec -- bats --timing "${INTEGRATION_DIR}/tests"
