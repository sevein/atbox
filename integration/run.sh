#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INTEGRATION_DIR="$ROOT_DIR/integration"
COMPOSE_FILE="$INTEGRATION_DIR/docker-compose.yml"
PROJECT_NAME="${PROJECT_NAME:-atbox-it}"
DUMP_SQL="${DUMP_SQL:-${INTEGRATION_DIR}/fixtures/dump.sql}"
ATBOX_URL="${ATBOX_URL:-http://127.0.0.1:18080/}"
KEEP_UP="${KEEP_UP:-0}"
OUTPUT_DIR="${INTEGRATION_DIR}/output"
PLAYWRIGHT_SCREENSHOT="${OUTPUT_DIR}/playwright/home.png"
PLAYWRIGHT_BROWSERS_PATH="${OUTPUT_DIR}/ms-playwright"
NPM_CACHE_DIR="${OUTPUT_DIR}/npm-cache"
PLAYWRIGHT_TIMEOUT_MS="${PLAYWRIGHT_TIMEOUT_MS:-20000}"
PLAYWRIGHT_WAIT_AFTER_MS="${PLAYWRIGHT_WAIT_AFTER_MS:-1000}"
PLAYWRIGHT_WAIT_SELECTOR="${PLAYWRIGHT_WAIT_SELECTOR:-#search-box-input}"

mkdir -p "${OUTPUT_DIR}/playwright"

compose() {
  docker compose -p "${PROJECT_NAME}" -f "${COMPOSE_FILE}" "$@"
}

cleanup() {
  if [[ "${KEEP_UP}" == "1" ]]; then
    echo "Integration stack kept running (KEEP_UP=1)."
    return
  fi

  compose down -v --remove-orphans >/dev/null 2>&1 || true
}

on_error() {
  echo
  echo "Integration run failed. Recent atbox logs:"
  compose logs --no-color --tail=200 atbox || true
}

trap on_error ERR
trap cleanup EXIT

wait_for_healthy() {
  local service="$1"
  local timeout="${2:-240}"
  local start ts container_id status

  start="$(date +%s)"

  while true; do
    container_id="$(compose ps -q "${service}" || true)"
    if [[ -n "${container_id}" ]]; then
      status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${container_id}")"
      if [[ "${status}" == "healthy" || "${status}" == "running" ]]; then
        echo "${service} is ${status}"
        return 0
      fi
      if [[ "${status}" == "unhealthy" || "${status}" == "exited" || "${status}" == "dead" ]]; then
        echo "${service} reached bad status: ${status}"
        compose logs --no-color --tail=200 "${service}" || true
        return 1
      fi
    fi

    ts="$(date +%s)"
    if (( ts - start > timeout )); then
      echo "Timed out waiting for ${service} health"
      compose logs --no-color --tail=200 "${service}" || true
      return 1
    fi

    sleep 2
  done
}

wait_for_http_ok() {
  local url="$1"
  local timeout="${2:-240}"
  local start ts status

  start="$(date +%s)"
  while true; do
    status="$(curl -sS -o /tmp/atbox-it-http-body.txt -w '%{http_code}' "${url}" || true)"
    if [[ "${status}" =~ ^[23][0-9][0-9]$ ]]; then
      echo "HTTP check passed: ${status} (${url})"
      return 0
    fi

    ts="$(date +%s)"
    if (( ts - start > timeout )); then
      echo "Timed out waiting for HTTP success at ${url} (last status: ${status})"
      tail -n +1 /tmp/atbox-it-http-body.txt || true
      return 1
    fi

    sleep 2
  done
}

assert_runtime_hardening() {
  local container_id inspect

  container_id="$(compose ps -q atbox || true)"
  if [[ -z "${container_id}" ]]; then
    echo "Unable to find atbox container id for hardening checks"
    return 1
  fi

  inspect="$(docker inspect -f '{{json .HostConfig.SecurityOpt}} {{json .HostConfig.CapDrop}}' "${container_id}")"
  if [[ "${inspect}" != *'no-new-privileges:true'* ]]; then
    echo "Expected security_opt to include no-new-privileges:true, got: ${inspect}"
    return 1
  fi

  if [[ "${inspect}" != *'"CAP_NET_RAW"'* ]]; then
    echo "Expected cap_drop to include CAP_NET_RAW, got: ${inspect}"
    return 1
  fi

  echo "Runtime hardening assertions passed (${inspect})"
}

assert_rootless_processes() {
  compose exec -T atbox sh -lc '
set -eu

check_non_root_comm() {
  comm_name="$1"
  label="$2"
  found=0

  for proc in /proc/[0-9]*; do
    [ -r "$proc/comm" ] || continue
    comm="$(cat "$proc/comm" 2>/dev/null || true)"
    [ "$comm" = "$comm_name" ] || continue

    found=1
    uid="$(awk "/^Uid:/{print \$2}" "$proc/status")"
    if [ "$uid" = "0" ]; then
      echo "$label is running as root (pid $(basename "$proc"))"
      exit 1
    fi
  done

  if [ "$found" != "1" ]; then
    echo "No process matched comm for $label: $comm_name"
    exit 1
  fi
}

check_non_root_comm "php-fpm" "php-fpm"
check_non_root_comm "nginx" "nginx"
'

  echo "Rootless process assertions passed (nginx + php-fpm)"
}

assert_no_tail_loggers() {
  compose exec -T atbox sh -lc '
set -eu

for proc in /proc/[0-9]*; do
  [ -r "$proc/comm" ] || continue
  comm="$(cat "$proc/comm" 2>/dev/null || true)"
  [ "$comm" = "tail" ] || continue

  cmd="$(tr "\000" " " < "$proc/cmdline" 2>/dev/null || true)"
  echo "Unexpected tail process found (pid $(basename "$proc")): $cmd"
  exit 1
done
'

  echo "No tail-based logger processes detected"
}

assert_logs() {
  local logs_file="${OUTPUT_DIR}/atbox.logs.txt"
  compose logs --no-color atbox > "${logs_file}"

  if ! grep -q 'ready to handle connections' "${logs_file}"; then
    echo "Missing php-fpm readiness log entry"
    return 1
  fi

  if grep -Eq 'Permission denied|Fatal error: Uncaught sfCacheException|failed to open error_log' "${logs_file}"; then
    echo "Detected fatal/permission issues in logs"
    return 1
  fi

  echo "Log assertions passed (${logs_file})"
}

import_dump() {
  if [[ ! -f "${DUMP_SQL}" ]]; then
    echo "SQL dump not found at ${DUMP_SQL}"
    echo "Set DUMP_SQL=/path/to/dump.sql"
    return 1
  fi

  echo "Importing dump: ${DUMP_SQL}"
  compose exec -T mysql sh -ec 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" atom' < "${DUMP_SQL}"
}

ensure_playwright() {
  echo "Installing pinned Playwright dependencies (npm ci)"
  command -v npm >/dev/null 2>&1
  npm ci --prefix "${INTEGRATION_DIR}" --no-audit --no-fund --cache "${NPM_CACHE_DIR}" >/dev/null
  PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH}" npm --prefix "${INTEGRATION_DIR}" exec playwright install chromium >/dev/null
}

run_playwright_smoke() {
  echo "Running Playwright landing-page smoke check (Node script)"
  ensure_playwright
  ATBOX_URL="${ATBOX_URL}" \
  PLAYWRIGHT_SCREENSHOT="${PLAYWRIGHT_SCREENSHOT}" \
  PLAYWRIGHT_TIMEOUT_MS="${PLAYWRIGHT_TIMEOUT_MS}" \
  PLAYWRIGHT_WAIT_AFTER_MS="${PLAYWRIGHT_WAIT_AFTER_MS}" \
  PLAYWRIGHT_WAIT_SELECTOR="${PLAYWRIGHT_WAIT_SELECTOR}" \
  PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH}" \
  npm --prefix "${INTEGRATION_DIR}" run --silent smoke
}

bootstrap_search_index() {
  echo "Populating Elasticsearch index"
  compose exec -T atbox sh -lc 'php symfony search:populate'
  compose exec -T atbox sh -lc 'php symfony search:status'
}

assert_search_zero_results() {
  local query status search_url search_html

  query="zzzzzz-atbox-smoke-$(date +%s)"
  search_url="${ATBOX_URL%/}/index.php/informationobject/browse?topLod=0&sort=relevance&query=${query}"
  search_html="${OUTPUT_DIR}/search-zero-results.html"

  status="$(curl -sS -o "${search_html}" -w '%{http_code}' "${search_url}" || true)"
  if [[ ! "${status}" =~ ^[23][0-9][0-9]$ ]]; then
    echo "Search request failed: HTTP ${status} (${search_url})"
    return 1
  fi

  if grep -q 'Elasticsearch error' "${search_html}"; then
    echo "Search response contains Elasticsearch error"
    return 1
  fi

  if ! grep -q 'No results found' "${search_html}"; then
    echo "Search response did not contain expected zero-results marker"
    return 1
  fi

  echo "Search assertions passed (${search_url})"
}

echo "Starting dependencies (mysql + elasticsearch)"
compose up -d mysql elasticsearch
wait_for_healthy mysql 240
wait_for_healthy elasticsearch 240

import_dump

echo "Starting atbox"
compose up -d --build atbox
wait_for_healthy atbox 240
assert_runtime_hardening
wait_for_http_ok "${ATBOX_URL}" 240
assert_rootless_processes
assert_no_tail_loggers

bootstrap_search_index

run_playwright_smoke
assert_search_zero_results
assert_logs

echo "Integration smoke run succeeded."
