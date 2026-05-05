#!/usr/bin/env bash

setup_suite() {
  source "${BATS_TEST_DIRNAME}/../lib/harness.bash"
  integration_setup_suite
}

teardown_suite() {
  source "${BATS_TEST_DIRNAME}/../lib/harness.bash"
  integration_teardown_suite
}
