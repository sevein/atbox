ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
INTEGRATION_DIR="$ROOT_DIR/hack/integration"
COMPOSE_FILE="$INTEGRATION_DIR/docker-compose.yml"
PROJECT_NAME="${PROJECT_NAME:-atbox-it}"
DUMP_SQL="${DUMP_SQL:-${INTEGRATION_DIR}/fixtures/dump.sql}"
ATBOX_URL="${ATBOX_URL:-http://127.0.0.1:18080/}"
ATBOX_REPLICA_URL="${ATBOX_REPLICA_URL:-http://127.0.0.1:18081/}"
ATBOX_ADMIN_URL="${ATBOX_ADMIN_URL:-http://127.0.0.1:18082/}"
ATBOX_PRIMARY_SERVICE="${ATBOX_PRIMARY_SERVICE:-atbox}"
ATBOX_REPLICA_SERVICE="${ATBOX_REPLICA_SERVICE:-atbox_replica}"
ATBOX_ADMIN_SERVICE="${ATBOX_ADMIN_SERVICE:-atbox_admin}"
ATBOX_CLI_SERVICE="${ATBOX_CLI_SERVICE:-atbox_cli}"
ATBOX_WORKER_SERVICE="${ATBOX_WORKER_SERVICE:-atbox_worker}"
ATBOX_WORKER_TOOLCHAIN_SERVICE="${ATBOX_WORKER_TOOLCHAIN_SERVICE:-atbox_worker_toolchain}"
ATOM_NAMESPACE="${ATOM_NAMESPACE:-atbox-it}"
ADMIN_ATOM_SESSION_NAME="${ADMIN_ATOM_SESSION_NAME:-atbox-admin-it}"
ATBOX_REST_API_KEY="${ATBOX_REST_API_KEY:-atbox-rest-api-key}"
KEEP_UP="${KEEP_UP:-0}"
OUTPUT_DIR="${INTEGRATION_DIR}/output"
PLAYWRIGHT_SCREENSHOT="${OUTPUT_DIR}/playwright/home.png"
PLAYWRIGHT_ADMIN_SCREENSHOT="${OUTPUT_DIR}/playwright/admin-metadata.png"
PLAYWRIGHT_ADMIN_STATE="${OUTPUT_DIR}/playwright/admin-metadata.json"
PLAYWRIGHT_BROWSERS_PATH="${OUTPUT_DIR}/ms-playwright"
NPM_CACHE_DIR="${OUTPUT_DIR}/npm-cache"
PLAYWRIGHT_TIMEOUT_MS="${PLAYWRIGHT_TIMEOUT_MS:-20000}"
PLAYWRIGHT_WAIT_AFTER_MS="${PLAYWRIGHT_WAIT_AFTER_MS:-1000}"
PLAYWRIGHT_WAIT_SELECTOR="${PLAYWRIGHT_WAIT_SELECTOR:-#search-box-input}"

export ROOT_DIR
export INTEGRATION_DIR
export COMPOSE_FILE
export PROJECT_NAME
export DUMP_SQL
export ATBOX_URL
export ATBOX_REPLICA_URL
export ATBOX_ADMIN_URL
export ATBOX_PRIMARY_SERVICE
export ATBOX_REPLICA_SERVICE
export ATBOX_ADMIN_SERVICE
export ATBOX_CLI_SERVICE
export ATBOX_WORKER_SERVICE
export ATBOX_WORKER_TOOLCHAIN_SERVICE
export ATOM_NAMESPACE
export ADMIN_ATOM_SESSION_NAME
export ATBOX_REST_API_KEY
export KEEP_UP
export OUTPUT_DIR
export PLAYWRIGHT_SCREENSHOT
export PLAYWRIGHT_ADMIN_SCREENSHOT
export PLAYWRIGHT_ADMIN_STATE
export PLAYWRIGHT_BROWSERS_PATH
export NPM_CACHE_DIR
export PLAYWRIGHT_TIMEOUT_MS
export PLAYWRIGHT_WAIT_AFTER_MS
export PLAYWRIGHT_WAIT_SELECTOR

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

collect_diagnostics() {
  echo
  echo "Integration run failed. Recent atbox logs:"
  compose logs --no-color --tail=200 "${ATBOX_PRIMARY_SERVICE}" "${ATBOX_REPLICA_SERVICE}" "${ATBOX_ADMIN_SERVICE}" "${ATBOX_WORKER_SERVICE}" || true
}

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

  if [[ "${inspect}" != *'"NET_RAW"'* && "${inspect}" != *'"CAP_NET_RAW"'* ]]; then
    echo "Expected cap_drop to include NET_RAW, got: ${inspect}"
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

assert_worker_process() {
  local service="${1:?service name required}"

  compose exec -T "${service}" php -r '
if (!extension_loaded("gearman") || !class_exists("GearmanWorker")) {
    fwrite(STDERR, "PHP Gearman extension is not loaded\n");
    exit(1);
}
'

  compose exec -T "${service}" sh -lc '
set -eu
found=0
self="$$"

for proc in /proc/[0-9]*; do
  [ "$(basename "$proc")" = "$self" ] && continue
  [ -r "$proc/cmdline" ] || continue
  cmd="$(tr "\000" " " < "$proc/cmdline" 2>/dev/null || true)"
  case "$cmd" in
    *"symfony jobs:worker"*)
      found=1
      uid="$(awk "/^Uid:/{print \$2}" "$proc/status")"
      if [ "$uid" = "0" ]; then
        echo "jobs:worker is running as root (pid $(basename "$proc"))"
        exit 1
      fi
      ;;
  esac
done

if [ "$found" != "1" ]; then
  echo "No jobs:worker process found"
  exit 1
fi
'

  echo "Worker process assertion passed for ${service}"
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

reset_demo_password() {
  local password_hash

  password_hash="$(
    compose run --rm --entrypoint php "${ATBOX_CLI_SERVICE}" \
      -r 'echo password_hash(sha1("demo"), PASSWORD_ARGON2I), PHP_EOL;' \
      | tail -n 1 \
      | tr -d '\r'
  )"

  if [[ -z "${password_hash}" ]]; then
    echo "Unable to generate demo user password hash"
    return 1
  fi

  compose exec -T mysql sh -ec 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" atom' <<SQL
UPDATE user
SET password_hash = '${password_hash}', salt = ''
WHERE email = 'demo@example.com';
SQL

  echo "Demo admin password reset for integration smoke"
}

enable_rest_api_plugin() {
  compose exec -T mysql sh -ec 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" atom' <<'SQL'
UPDATE setting_i18n
SET value = 'a:13:{i:0;s:10:"sfDcPlugin";i:1;s:18:"arDominionB5Plugin";i:2;s:11:"sfEacPlugin";i:3;s:11:"sfEadPlugin";i:4;s:13:"sfIsaarPlugin";i:5;s:12:"sfIsadPlugin";i:6;s:12:"arDacsPlugin";i:7;s:12:"sfIsdfPlugin";i:8;s:14:"sfIsdiahPlugin";i:9;s:12:"sfModsPlugin";i:10;s:11:"sfRadPlugin";i:11;s:12:"sfSkosPlugin";i:12;s:15:"arRestApiPlugin";}'
WHERE id = 1 AND culture = 'en';
SQL

  echo "REST API plugin enabled for integration smoke"
}

set_demo_api_key() {
  compose exec -T mysql sh -ec 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" atom' <<SQL
DELETE pi
FROM property_i18n pi
INNER JOIN property p ON p.id = pi.id
WHERE p.object_id = 448 AND p.name = 'restApiKey';

DELETE FROM property
WHERE object_id = 448 AND name = 'restApiKey';

INSERT INTO property (object_id, scope, name, source_culture, serial_number)
VALUES (448, NULL, 'restApiKey', 'en', 0);

INSERT INTO property_i18n (value, id, culture)
VALUES ('${ATBOX_REST_API_KEY}', LAST_INSERT_ID(), 'en');
SQL

  echo "Demo admin REST API key configured for integration smoke"
}

ensure_playwright() {
  echo "Installing Playwright dependencies (npm ci)"
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
  npm --prefix "${INTEGRATION_DIR}" run --silent public-smoke
}

bootstrap_search_index() {
  echo "Populating Elasticsearch index"
  compose run --rm "${ATBOX_CLI_SERVICE}" php symfony search:populate
  compose run --rm "${ATBOX_CLI_SERVICE}" php symfony search:status
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
  local -a methods
  local route status

  routes=(
    "/"
    "/index.php"
    "/index.php/informationobject/browse"
    "/index.php/informationobject/itemOrFileList"
    "/index.php/informationobject/storageLocations"
    "/index.php/informationobject/boxLabel"
  )
  methods=(POST PUT PATCH DELETE)

  for route in "${routes[@]}"; do
    for method in "${methods[@]}"; do
      status="$(curl -sS -o /dev/null -w '%{http_code}' -X "${method}" "${ATBOX_URL%/}${route}" || true)"
      if [[ "${status}" != "403" ]]; then
        echo "Expected HTTP 403 for blocked ${method} request on primary (${route}), got ${status}"
        return 1
      fi

      status="$(curl -sS -o /dev/null -w '%{http_code}' -X "${method}" "${ATBOX_REPLICA_URL%/}${route}" || true)"
      if [[ "${status}" != "403" ]]; then
        echo "Expected HTTP 403 for blocked ${method} request on replica (${route}), got ${status}"
        return 1
      fi
    done
  done

  echo "Non-GET method block assertions passed (primary + replica)"
}

assert_admin_post_allowed() {
  local status

  status="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${ATBOX_ADMIN_URL%/}/index.php/user/login" || true)"
  if [[ "${status}" == "403" || "${status}" == "405" ]]; then
    echo "Expected admin POST to be allowed, got HTTP ${status}"
    return 1
  fi

  echo "Admin POST method assertion passed (HTTP ${status})"
}

assert_role_marker() {
  local service="${1:?service name required}"
  local expected_role="${2:?expected role required}"
  local role

  role="$(compose run --rm --entrypoint sh "${service}" -c 'cat /etc/atbox/role' | tr -d '\r')"
  if [[ "${role}" != "${expected_role}" ]]; then
    echo "Expected ${service} role ${expected_role}, got ${role}"
    return 1
  fi

  echo "Role marker assertion passed for ${service}: ${role}"
}

assert_toolchain_commands() {
  local service="${1:?service name required}"
  local expected_commands="${2:-}"
  local absent_commands="${3:-}"
  local expected_report_tools="${4:-}"
  local absent_report_tools="${5:-}"

  compose run --rm --entrypoint sh "${service}" -lc '
set -eu

expected_commands="$1"
absent_commands="$2"
expected_report_tools="$3"
absent_report_tools="$4"

for command_name in ${expected_commands}; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Expected command is missing: ${command_name}"
    exit 1
  fi
done

for command_name in ${absent_commands}; do
  if command -v "${command_name}" >/dev/null 2>&1; then
    echo "Unexpected command is present: ${command_name}"
    exit 1
  fi
done

case " ${expected_commands} " in
  *" version-report "*)
    report="$(version-report)"

    for tool_name in ${expected_report_tools}; do
      if ! printf "%s\n" "${report}" | grep -q "^${tool_name} "; then
        echo "Expected tool is missing from version-report: ${tool_name}"
        exit 1
      fi
    done

    for tool_name in ${absent_report_tools}; do
      if printf "%s\n" "${report}" | grep -q "^${tool_name} "; then
        echo "Unexpected tool is present in version-report: ${tool_name}"
        exit 1
      fi
    done
    ;;
esac
' sh "${expected_commands}" "${absent_commands}" "${expected_report_tools}" "${absent_report_tools}"

  echo "Toolchain command assertions passed for ${service}"
}

assert_worker_toolchain_image() {
  local service="${ATBOX_WORKER_TOOLCHAIN_SERVICE}"
  local expected_commands="ffmpeg ffprobe convert identify mogrify composite magick gs ps2pdf pdfinfo pdftotext java fop unzip version-report"
  local expected_report=$'ffmpeg 6.1.1\nfop 2.8\nghostscript 10.03.1\nimagemagick 7.1.1-34\njava 17.0.10\npoppler-utils 24.02.0\nunzip 6.0'
  local command_name report sorted_report sorted_expected status output image_ref image_id container_id path

  compose build --quiet "${service}" >/dev/null

  report="$(compose run --rm "${service}" | tr -d '\r')"
  sorted_report="$(printf "%s\n" "${report}" | sort)"
  sorted_expected="$(printf "%s\n" "${expected_report}" | sort)"
  if [[ "${sorted_report}" != "${sorted_expected}" ]]; then
    echo "Unexpected worker toolchain version-report output."
    echo "Expected:"
    printf "%s\n" "${sorted_expected}"
    echo "Got:"
    printf "%s\n" "${sorted_report}"
    return 1
  fi

  for command_name in ${expected_commands}; do
    set +e
    output="$(compose run --rm "${service}" "${command_name}" --version 2>&1)"
    status=$?
    set -e

    if [[ ${status} -eq 127 ]] || printf "%s\n" "${output}" | grep -qiE "executable file not found|command not found"; then
      echo "Expected worker toolchain command is missing from PATH: ${command_name}"
      printf "%s\n" "${output}"
      return 1
    fi
  done

  image_id="$(compose images -q "${service}" | head -n 1)"
  if [[ -z "${image_id}" ]]; then
    image_ref="$(compose config "${service}" | awk '$1 == "image:" { print $2; exit }')"
    image_id="$(docker image inspect "${image_ref}" --format '{{.Id}}' 2>/dev/null || true)"
  fi
  if [[ -z "${image_id}" ]]; then
    echo "Could not resolve image id for ${service}"
    return 1
  fi

  container_id="$(docker create "${image_id}")"
  trap 'docker rm -f "${container_id}" >/dev/null 2>&1 || true; trap - RETURN' RETURN

  for path in /nix /usr/local/bin; do
    if ! docker cp "${container_id}:${path}" - >/dev/null 2>&1; then
      echo "Expected worker toolchain image path is missing: ${path}"
      return 1
    fi
  done

  for path in /atom /etc/atbox /etc/s6-overlay /usr/bin/php /usr/sbin/nginx /usr/local/bin/atbox-worker-entrypoint; do
    if docker cp "${container_id}:${path}" - >/dev/null 2>&1; then
      echo "Unexpected runtime path is present in worker toolchain image: ${path}"
      return 1
    fi
  done

  echo "Worker toolchain image assertions passed for ${service}"
}

assert_generated_runtime_config() {
  local service="${1:?service name required}"
  local expected_read_only="${2:?expected read_only value required}"
  local expected_session_name="${3:?expected session name required}"
  local expected_session_secure="${4:?expected session secure value required}"

  compose exec -T "${service}" sh -s -- "${expected_read_only}" "${expected_session_name}" "${expected_session_secure}" <<'SH'
set -eu
expected_read_only="$1"
expected_session_name="$2"
expected_session_secure="$3"

grep -q "read_only: ${expected_read_only}" /atom/src/apps/qubit/config/app.yml
grep -q "prefix: atbox-it" /atom/src/apps/qubit/config/app.yml
grep -q "default: gearmand:4730" /atom/src/config/gearman.yml
grep -q "worker_types:" /atom/src/config/gearman.yml
grep -q "arFindingAidJob" /atom/src/config/gearman.yml
grep -q "worker_types:" /atom/src/apps/qubit/config/gearman.yml
grep -q "arFindingAidJob" /atom/src/apps/qubit/config/gearman.yml
grep -q "workers_key:" /atom/src/apps/qubit/config/app.yml
grep -q "no_script_name: *true" /atom/src/apps/qubit/config/settings.yml
! grep -q "no_script_name: *false" /atom/src/apps/qubit/config/settings.yml
grep -q "session_name: ${expected_session_name}" /atom/src/apps/qubit/config/factories.yml
grep -q "session_cookie_secure: ${expected_session_secure}" /atom/src/apps/qubit/config/factories.yml
grep -q "file_uploads = Off" /etc/php/8.3/mods-available/atbox.ini
grep -q "upload_max_filesize = 0" /etc/php/8.3/mods-available/atbox.ini
SH

  echo "Generated runtime config assertions passed for ${service}"
}

assert_admin_oidc_bootstrap_config() {
  compose run --rm \
    --no-deps \
    --entrypoint sh \
    -e ATOM_OIDC_ENABLED=true \
    -e ATOM_OIDC_PROVIDER_URL=https://keycloak.example.org/realms/atom \
    -e ATOM_OIDC_CLIENT_ID=atom-admin \
    -e ATOM_OIDC_CLIENT_SECRET=secret \
    -e ATOM_OIDC_REDIRECT_URL=https://atom.example.org/oidc/login \
    -e ATOM_OIDC_LOGOUT_REDIRECT_URL=https://atom.example.org \
    "${ATBOX_ADMIN_SERVICE}" \
    -lc '
set -eu
php /usr/local/bin/atbox-bootstrap.php
grep -q "arOidcPlugin.*Managed by atbox-bootstrap" /atom/src/config/ProjectConfiguration.class.php
grep -Eq "login_module:[[:space:]]*oidc" /atom/src/apps/qubit/config/settings.yml
grep -q "class: oidcUser" /atom/src/apps/qubit/config/factories.yml
grep -q "primary_provider_name: primary" /atom/src/plugins/arOidcPlugin/config/app.yml
' || return 1

  echo "Admin OIDC bootstrap config assertions passed"
}

assert_worker_default_abilities() {
  local ability_count deadline

  deadline=$(( $(date +%s) + 60 ))
  while true; do
    ability_count="$(
      compose run --rm "${ATBOX_CLI_SERVICE}" php -r '
require_once "/atom/src/config/ProjectConfiguration.class.php";
$configuration = ProjectConfiguration::getApplicationConfiguration("qubit", "prod", false);
new sfDatabaseManager($configuration);
sfContext::createInstance($configuration);
sfConfig::add(QubitSetting::getSettingsArray());
$manager = new Net_Gearman_Manager(arGearman::getServer(), 2);
$status = $manager->status();
$prefix = QubitJob::getJobPrefix();
$abilities = [
    "arFindingAidJob",
    "arInheritRightsJob",
    "arInformationObjectCsvExportJob",
    "arFileImportJob",
    "arAccessionCsvExportJob",
];
$registered = 0;
foreach ($abilities as $ability) {
    $name = $prefix.$ability;
    if (isset($status[$name]) && $status[$name]["capable_workers"] > 0) {
        ++$registered;
    }
}
echo $registered, PHP_EOL;
' | tail -n 1 | tr -d '\r'
    )"

    if [[ "${ability_count}" == "5" ]]; then
      echo "Worker default ability registration assertion passed"
      return 0
    fi

    if (( $(date +%s) > deadline )); then
      echo "Expected worker to register default AtoM abilities, got ${ability_count}/5"
      compose logs --no-color --tail=100 "${ATBOX_WORKER_SERVICE}" || true
      return 1
    fi

    sleep 2
  done
}

assert_admin_blocks_dangerous_methods() {
  local -a methods
  local method status

  methods=(PUT PATCH DELETE)
  for method in "${methods[@]}"; do
    status="$(curl -sS -o /dev/null -w '%{http_code}' -X "${method}" "${ATBOX_ADMIN_URL%/}/index.php/user/login" || true)"
    if [[ "${status}" != "403" ]]; then
      echo "Expected admin ${method} to be blocked with HTTP 403, got ${status}"
      return 1
    fi
  done

  echo "Admin dangerous method assertions passed"
}

assert_clean_urls() {
  local status

  status="$(curl -sS -o /dev/null -w '%{http_code}' "${ATBOX_URL%/}/informationobject/browse" || true)"
  if [[ ! "${status}" =~ ^[23][0-9][0-9]$ ]]; then
    echo "Expected public clean URL to work, got HTTP ${status}"
    return 1
  fi

  status="$(curl -sS -o /dev/null -w '%{http_code}' "${ATBOX_ADMIN_URL%/}/user/login" || true)"
  if [[ ! "${status}" =~ ^[23][0-9][0-9]$ ]]; then
    echo "Expected admin clean URL to work, got HTTP ${status}"
    return 1
  fi

  echo "Clean URL assertions passed"
}

assert_php_direct_access_blocked() {
  local service_url="${1:?service URL required}"
  local label="${2:?label required}"
  local status

  status="$(curl -sS -o /dev/null -w '%{http_code}' "${service_url%/}/uploads/smoke.php" || true)"
  if [[ "${status}" != "404" && "${status}" != "403" ]]; then
    echo "Expected direct PHP path to be blocked for ${label}, got HTTP ${status}"
    return 1
  fi

  echo "Direct PHP path block assertion passed for ${label} (HTTP ${status})"
}

run_admin_metadata_smoke() {
  echo "Running Playwright admin metadata smoke check"
  ensure_playwright
  ATBOX_ADMIN_URL="${ATBOX_ADMIN_URL}" \
  ATBOX_ADMIN_USERNAME="${ATBOX_ADMIN_USERNAME:-demo@example.com}" \
  ATBOX_ADMIN_PASSWORD="${ATBOX_ADMIN_PASSWORD:-demo}" \
  PLAYWRIGHT_ADMIN_SCREENSHOT="${PLAYWRIGHT_ADMIN_SCREENSHOT}" \
  PLAYWRIGHT_ADMIN_STATE="${PLAYWRIGHT_ADMIN_STATE}" \
  PLAYWRIGHT_TIMEOUT_MS="${PLAYWRIGHT_TIMEOUT_MS}" \
  PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH}" \
  npm --prefix "${INTEGRATION_DIR}" run --silent admin-smoke
}

admin_smoke_updated_title() {
  node -e "const fs = require('fs'); const state = JSON.parse(fs.readFileSync(process.argv[1], 'utf8')); if (!state.updatedTitle) process.exit(1); console.log(state.updatedTitle);" "${PLAYWRIGHT_ADMIN_STATE}"
}

assert_public_admin_record_visible() {
  local title search_url search_html status

  title="$(admin_smoke_updated_title)"
  bootstrap_search_index
  search_url="${ATBOX_URL%/}/index.php/informationobject/browse?topLod=0&sort=relevance&query=$(node -e 'console.log(encodeURIComponent(process.argv[1]))' "${title}")"
  search_html="${OUTPUT_DIR}/public-admin-record-search.html"

  status="$(curl -sS -o "${search_html}" -w '%{http_code}' "${search_url}" || true)"
  if [[ ! "${status}" =~ ^[23][0-9][0-9]$ ]]; then
    echo "Public search for admin-created record failed: HTTP ${status} (${search_url})"
    return 1
  fi

  if ! grep -q "${title}" "${search_html}"; then
    echo "Admin-created record was not visible on public readonly search (${search_html})"
    return 1
  fi

  echo "Admin-created record visible on public readonly site (${title})"
}

assert_api_json_get() {
  local base_url="${1:?base URL required}"
  local route="${2:?route required}"
  local label="${3:?label required}"
  local body_file="${OUTPUT_DIR}/api-${label}.json"
  local status

  status="$(
    curl -sS \
      -H "REST-API-Key: ${ATBOX_REST_API_KEY}" \
      -H 'Accept: application/json' \
      -o "${body_file}" \
      -w '%{http_code}' \
      "${base_url%/}/index.php/${route#/}" || true
  )"

  if [[ ! "${status}" =~ ^[23][0-9][0-9]$ ]]; then
    echo "API request failed for ${label}: HTTP ${status}"
    cat "${body_file}" || true
    return 1
  fi

  node -e "JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'))" "${body_file}"
  echo "API request passed for ${label} (${route})"
}

assert_rest_api_read_operations() {
  assert_api_json_get "${ATBOX_URL}" "/api" "readonly-index"
  assert_api_json_get "${ATBOX_URL}" "/api/taxonomies/34" "readonly-taxonomy"
  assert_api_json_get "${ATBOX_URL}" "/api/informationobjects?limit=1" "readonly-informationobjects"

  assert_api_json_get "${ATBOX_ADMIN_URL}" "/api" "admin-index"
  assert_api_json_get "${ATBOX_ADMIN_URL}" "/api/taxonomies/34" "admin-taxonomy"
  assert_api_json_get "${ATBOX_ADMIN_URL}" "/api/informationobjects?limit=1" "admin-informationobjects"
}

assert_rest_api_requires_key() {
  local status

  status="$(curl -sS -o /dev/null -w '%{http_code}' "${ATBOX_URL%/}/index.php/api" || true)"
  if [[ "${status}" =~ ^[23][0-9][0-9]$ ]]; then
    echo "Expected readonly API without key to be rejected, got HTTP ${status}"
    return 1
  fi

  status="$(curl -sS -o /dev/null -w '%{http_code}' "${ATBOX_ADMIN_URL%/}/index.php/api" || true)"
  if [[ "${status}" =~ ^[23][0-9][0-9]$ ]]; then
    echo "Expected admin API without key to be rejected, got HTTP ${status}"
    return 1
  fi

  echo "REST API key requirement assertions passed"
}

integration_setup_suite() {
  mkdir -p "${OUTPUT_DIR}/playwright"
  cleanup

  echo "Starting dependencies (mysql + elasticsearch + memcached)"
  compose up -d mysql elasticsearch memcached
  wait_for_healthy mysql 240
  wait_for_healthy elasticsearch 240
  wait_for_healthy memcached 120

  import_dump
  enable_rest_api_plugin

  echo "Building role images"
  compose build "${ATBOX_PRIMARY_SERVICE}" "${ATBOX_REPLICA_SERVICE}" "${ATBOX_ADMIN_SERVICE}" "${ATBOX_CLI_SERVICE}" "${ATBOX_WORKER_SERVICE}"
  reset_demo_password
  set_demo_api_key

  echo "Starting atbox roles"
  compose up -d "${ATBOX_PRIMARY_SERVICE}" "${ATBOX_REPLICA_SERVICE}" "${ATBOX_ADMIN_SERVICE}" "${ATBOX_WORKER_SERVICE}"
  wait_for_healthy "${ATBOX_PRIMARY_SERVICE}" 240
  wait_for_healthy "${ATBOX_REPLICA_SERVICE}" 240
  wait_for_healthy "${ATBOX_ADMIN_SERVICE}" 240
}

integration_teardown_suite() {
  cleanup
}
