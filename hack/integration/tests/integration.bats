#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../lib/harness.bash"
}

bats::on_failure() {
  collect_diagnostics
}

@test "fixture data is loaded into mysql" {
  first_repository_id >/dev/null
}

@test "role images expose expected role markers" {
  assert_role_marker "${ATBOX_PRIMARY_SERVICE}" "readonly"
  assert_role_marker "${ATBOX_REPLICA_SERVICE}" "readonly"
  assert_role_marker "${ATBOX_ADMIN_SERVICE}" "admin"
  assert_role_marker "${ATBOX_CLI_SERVICE}" "cli"
}

@test "public and admin endpoints answer HTTP requests" {
  wait_for_http_ok "${ATBOX_URL}" 240
  wait_for_http_ok "${ATBOX_REPLICA_URL}" 240
  wait_for_http_ok "${ATBOX_ADMIN_URL}" 240
}

@test "generated runtime config matches each role" {
  assert_generated_runtime_config "${ATBOX_PRIMARY_SERVICE}" "true" "atbox-it" "true"
  assert_generated_runtime_config "${ATBOX_REPLICA_SERVICE}" "true" "atbox-it" "true"
  assert_generated_runtime_config "${ATBOX_ADMIN_SERVICE}" "false" "atbox-admin-it" "false"
}

@test "web roles run hardened and rootless" {
  assert_runtime_hardening "${ATBOX_PRIMARY_SERVICE}"
  assert_runtime_hardening "${ATBOX_REPLICA_SERVICE}"
  assert_runtime_hardening "${ATBOX_ADMIN_SERVICE}"
  assert_rootless_processes "${ATBOX_PRIMARY_SERVICE}"
  assert_rootless_processes "${ATBOX_REPLICA_SERVICE}"
  assert_rootless_processes "${ATBOX_ADMIN_SERVICE}"
  assert_no_tail_loggers "${ATBOX_PRIMARY_SERVICE}"
  assert_no_tail_loggers "${ATBOX_REPLICA_SERVICE}"
  assert_no_tail_loggers "${ATBOX_ADMIN_SERVICE}"
}

@test "readonly web roles block unsafe HTTP methods" {
  assert_non_get_methods_blocked
}

@test "cli role bootstraps and manages the search index" {
  bootstrap_search_index
}

@test "readonly replicas share session state" {
  assert_session_shareability
}

@test "public browser and search workflows work" {
  run_playwright_smoke
  assert_search_zero_results
}

@test "admin edge policy allows forms but blocks unsafe access" {
  assert_admin_post_allowed
  assert_admin_blocks_dangerous_methods
  assert_php_direct_access_blocked "${ATBOX_URL}" "public primary"
  assert_php_direct_access_blocked "${ATBOX_REPLICA_URL}" "public replica"
  assert_php_direct_access_blocked "${ATBOX_ADMIN_URL}" "admin"
}

@test "admin browser metadata create and edit workflow works" {
  run_admin_metadata_smoke
}

@test "admin-created metadata is visible on the public readonly site" {
  assert_public_admin_record_visible
}

@test "REST API accepts API-key reads on readonly and admin sites" {
  assert_rest_api_requires_key
  assert_rest_api_read_operations
}

@test "web role logs are clean" {
  assert_logs "${ATBOX_PRIMARY_SERVICE}"
  assert_logs "${ATBOX_REPLICA_SERVICE}"
  assert_logs "${ATBOX_ADMIN_SERVICE}"
}
