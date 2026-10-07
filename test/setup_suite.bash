# setup_suite.bash - suite-wide defaults for the BATS test suite
#
# BATS 1.7+ loads this file from the directory of the first test file it is
# given and runs setup_suite once, before any test file. Values exported here
# reach every test process.

setup_suite() {
  # Same floor as test_helper.bash, checked once so a Bash that is too old
  # stops the run with one message instead of failing every test.
  if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 1) )); then
    printf 'setup_suite: Bash 4.1 or newer is required; this is Bash %s (%s).\n' \
      "$BASH_VERSION" "$BASH" >&2
    printf 'setup_suite: put a current Bash first on PATH (macOS: brew install bash).\n' >&2
    return 1
  fi

  # A hung test must fail instead of blocking the run. BATS arms this timer
  # before setup() runs, so the default cannot come from test_helper.bash. The
  # slowest test takes about 20 seconds under a parallel Linux run; 300 seconds
  # leaves room for slower runners. A caller's own value wins.
  if [[ -z "${BATS_TEST_TIMEOUT:-}" ]]; then
    export BATS_TEST_TIMEOUT=300
  fi
}
