#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INTEGRATION_DIR="$ROOT_DIR/integration"
COMPOSE_FILE="$INTEGRATION_DIR/docker-compose.yml"
PROJECT_NAME="${PROJECT_NAME:-atbox-it}"
DUMP_SQL="${DUMP_SQL:-${INTEGRATION_DIR}/fixtures/dump.sql}"
ATBOX_URL="${ATBOX_URL:-http://127.0.0.1:18080/}"
ATBOX_REPLICA_URL="${ATBOX_REPLICA_URL:-http://127.0.0.1:18081/}"
ATBOX_PRIMARY_SERVICE="${ATBOX_PRIMARY_SERVICE:-atbox}"
ATBOX_REPLICA_SERVICE="${ATBOX_REPLICA_SERVICE:-atbox_replica}"
ATOM_NAMESPACE="${ATOM_NAMESPACE:-atbox-it}"
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
  compose logs --no-color --tail=200 "${ATBOX_PRIMARY_SERVICE}" "${ATBOX_REPLICA_SERVICE}" || true
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
  local service="${1:?service name required}"
  local container_id inspect

  container_id="$(compose ps -q "${service}" || true)"
  if [[ -z "${container_id}" ]]; then
    echo "Unable to find ${service} container id for hardening checks"
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

  echo "Runtime hardening assertions passed for ${service} (${inspect})"
}

assert_rootless_processes() {
  local service="${1:?service name required}"

  compose exec -T "${service}" sh -lc '
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

  echo "Rootless process assertions passed for ${service} (nginx + php-fpm)"
}

assert_no_tail_loggers() {
  local service="${1:?service name required}"

  compose exec -T "${service}" sh -lc '
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

  echo "No tail-based logger processes detected for ${service}"
}

assert_logs() {
  local service="${1:?service name required}"
  local logs_file="${OUTPUT_DIR}/${service}.logs.txt"
  compose logs --no-color "${service}" > "${logs_file}"

  if ! grep -q 'ready to handle connections' "${logs_file}"; then
    echo "Missing php-fpm readiness log entry"
    return 1
  fi

  if grep -Eq 'Permission denied|Fatal error: Uncaught sfCacheException|failed to open error_log' "${logs_file}"; then
    echo "Detected fatal/permission issues in logs"
    return 1
  fi

  echo "Log assertions passed for ${service} (${logs_file})"
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
  compose exec -T "${ATBOX_PRIMARY_SERVICE}" sh -lc 'php symfony search:populate'
  compose exec -T "${ATBOX_PRIMARY_SERVICE}" sh -lc 'php symfony search:status'
}

first_repository_id() {
  local repository_id

  repository_id="$(
    compose exec -T mysql sh -ec \
      'mysql -N -B -uroot -p"$MYSQL_ROOT_PASSWORD" atom -e "SELECT id FROM repository ORDER BY id ASC LIMIT 1;"' \
      | tr -d '\r'
  )"

  if [[ ! "${repository_id}" =~ ^[0-9]+$ ]]; then
    echo "Unable to resolve a repository id from MySQL (got: ${repository_id})"
    return 1
  fi

  printf '%s\n' "${repository_id}"
}

extract_session_cookie_value() {
  local headers_file="${1:?headers file required}"
  local cookie_name="${2:?cookie name required}"

  awk -v cookie_name="${cookie_name}" '
BEGIN {
  IGNORECASE = 1
}
tolower($1) == "set-cookie:" {
  line = $0
  sub(/\r$/, "", line)
  sub(/^[Ss]et-[Cc]ookie:[[:space:]]*/, "", line)
  split(line, parts, ";")
  split(parts[1], kv, "=")
  if (kv[1] == cookie_name) {
    print kv[2]
    exit
  }
}
' "${headers_file}"
}

assert_session_shareability() {
  local repository_id seed_url seed_headers seed_body verify_body status session_cookie_value

  repository_id="$(first_repository_id)"
  seed_url="${ATBOX_URL%/}/index.php/search/autocomplete?query=a&repos=${repository_id}"
  seed_headers="${OUTPUT_DIR}/session-seed.headers.txt"
  seed_body="${OUTPUT_DIR}/session-seed.body.txt"
  verify_body="${OUTPUT_DIR}/session-replica-home.html"

  status="$(curl -sS -D "${seed_headers}" -o "${seed_body}" -w '%{http_code}' "${seed_url}" || true)"
  if [[ ! "${status}" =~ ^[23][0-9][0-9]$ ]]; then
    echo "Failed to seed session realm on ${ATBOX_URL} (HTTP ${status})"
    return 1
  fi

  session_cookie_value="$(extract_session_cookie_value "${seed_headers}" "${ATOM_NAMESPACE}")"
  if [[ -z "${session_cookie_value}" ]]; then
    echo "Missing ${ATOM_NAMESPACE} cookie after session seed request (${seed_url})"
    return 1
  fi

  status="$(
    curl -sS \
      -H "Cookie: ${ATOM_NAMESPACE}=${session_cookie_value}" \
      -o "${verify_body}" \
      -w '%{http_code}' \
      "${ATBOX_REPLICA_URL}" || true
  )"
  if [[ ! "${status}" =~ ^[23][0-9][0-9]$ ]]; then
    echo "Replica session validation request failed on ${ATBOX_REPLICA_URL} (HTTP ${status})"
    return 1
  fi

  if ! grep -q 'id="search-realm-alt-repo"' "${verify_body}"; then
    echo "Expected session realm marker not found on replica response (${verify_body})"
    return 1
  fi

  echo "Session shareability assertion passed (${ATBOX_URL} -> ${ATBOX_REPLICA_URL})"
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

assert_non_get_methods_blocked() {
  local -a routes
  local route status

  routes=(
    "/"
    "/index.php"
    "/index.php/informationobject/browse"
    "/index.php/informationobject/itemOrFileList"
    "/index.php/informationobject/storageLocations"
    "/index.php/informationobject/boxLabel"
  )

  for route in "${routes[@]}"; do
    status="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${ATBOX_URL%/}${route}" || true)"
    if [[ "${status}" != "403" ]]; then
      echo "Expected HTTP 403 for blocked non-GET request on primary (${route}), got ${status}"
      return 1
    fi

    status="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${ATBOX_REPLICA_URL%/}${route}" || true)"
    if [[ "${status}" != "403" ]]; then
      echo "Expected HTTP 403 for blocked non-GET request on replica (${route}), got ${status}"
      return 1
    fi
  done

  echo "Non-GET method block assertions passed (primary + replica)"
}

echo "Starting dependencies (mysql + elasticsearch + memcached)"
compose up -d mysql elasticsearch memcached
wait_for_healthy mysql 240
wait_for_healthy elasticsearch 240
wait_for_healthy memcached 120

import_dump

echo "Starting atbox replicas"
compose up -d --build "${ATBOX_PRIMARY_SERVICE}" "${ATBOX_REPLICA_SERVICE}"
wait_for_healthy "${ATBOX_PRIMARY_SERVICE}" 240
wait_for_healthy "${ATBOX_REPLICA_SERVICE}" 240
assert_runtime_hardening "${ATBOX_PRIMARY_SERVICE}"
assert_runtime_hardening "${ATBOX_REPLICA_SERVICE}"
wait_for_http_ok "${ATBOX_URL}" 240
wait_for_http_ok "${ATBOX_REPLICA_URL}" 240
assert_rootless_processes "${ATBOX_PRIMARY_SERVICE}"
assert_rootless_processes "${ATBOX_REPLICA_SERVICE}"
assert_no_tail_loggers "${ATBOX_PRIMARY_SERVICE}"
assert_no_tail_loggers "${ATBOX_REPLICA_SERVICE}"

bootstrap_search_index
assert_session_shareability
assert_non_get_methods_blocked

run_playwright_smoke
assert_search_zero_results
assert_logs "${ATBOX_PRIMARY_SERVICE}"
assert_logs "${ATBOX_REPLICA_SERVICE}"

echo "Integration smoke run succeeded."
