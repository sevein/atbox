#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART_DIR="${ROOT_DIR}/charts/atbox"
KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.30.0}"

VALUES_FILES=(
  values-readonly-attached.yaml
  values-admin-attached.yaml
  values-public-plus-admin.yaml
)

if ! command -v kubeconform >/dev/null 2>&1; then
  echo "kubeconform is required; install it before running this script" >&2
  exit 1
fi

for values_file in "${VALUES_FILES[@]}"; do
  echo "Validating rendered chart preset with kubeconform: ${values_file}"
  helm template atbox "${CHART_DIR}" \
    --values "${CHART_DIR}/${values_file}" \
    | kubeconform \
      -strict \
      -summary \
      -kubernetes-version "${KUBERNETES_VERSION}" \
      -
done
