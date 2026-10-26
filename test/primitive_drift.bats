#!/usr/bin/env bats
# shellcheck disable=SC2016
#
# Primitives that stay duplicated so each suite can be sourced on its own.
# Identical copies must stay identical, and every copy must behave like the
# core service. docs/development.md lists the inventory.

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

# Fails with the first prefix whose normalized body differs from the first.
assert_identical_bodies() {
  local base="$1" nouns="$2" reference="" body="" prefix=""
  shift 2
  for prefix in "$@"; do
    # shellcheck disable=SC2086
    body=$(normalized_function_body "$prefix" "$base" $nouns) || {
      printf 'cannot extract _%s_%s\n' "$prefix" "$base" >&2
      return 1
    }
    if [[ -z "$reference" ]]; then
      reference="$body"
    elif [[ "$body" != "$reference" ]]; then
      printf '_%s_%s drifted from _%s_%s\n' "$prefix" "$base" "$1" "$base" >&2
      diff <(printf '%s\n' "$reference") <(printf '%s\n' "$body") >&2 || true
      return 1
    fi
  done
}

@test "primitive drift: every trusted-directory resolver is the core's" {
  assert_identical_bodies resolve_trusted_dir "" zdx git sys dev py ws env file vpn
}

@test "primitive drift: suite counted nouns are identical copies" {
  assert_identical_bodies count_noun "" sys dev py ws env file vpn
}

@test "primitive drift: suite duration labels are identical copies" {
  assert_identical_bodies duration_label "" sys dev vpn
}

@test "primitive drift: narrow timeout fallbacks are identical copies" {
  assert_identical_bodies run_with_timeout "Dev Git File" dev git file
  assert_identical_bodies run_with_timeout "Environment VPN" env vpn
}

@test "primitive drift: the standalone System watchdog helpers are the core's" {
  local base=""
  for base in timeout_ps_listing timeout_claim timeout_job_running timeout_linger; do
    assert_identical_bodies "$base" "" zdx sys || return 1
  done
}

@test "primitive drift: every counted noun behaves like the core service" {
  run zsh -f -c '
    source "$1/functions.zsh" 2>/dev/null || exit 90
    local common prefix case expected actual
    for common in "$1"/functions/*-common.zsh; do source "$common" 2>/dev/null; done
    for prefix in git sys dev py ws env file vpn; do
      for case in "0 file" "1 file" "2 file" "1 branch branches" "3 branch branches"; do
        _zdx_count_noun ${=case}; expected="$REPLY"
        REPLY=""
        "_${prefix}_count_noun" ${=case}; actual="$REPLY"
        [[ "$actual" == "$expected" ]] \
          || { print -r -- "$prefix: [$case] gave [$actual], core [$expected]"; exit 91; }
      done
    done
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
}

@test "primitive drift: every suite timeout fallback stays bounded without the core" {
  run zsh -f -c '
    local prefix common started rc
    zmodload zsh/datetime
    for prefix in git dev py ws env file vpn sys; do
      (
        unset -f _zdx_run_with_timeout 2>/dev/null
        for common in "$1"/functions/*-common.zsh; do source "$common" 2>/dev/null; done
        (( ! ${+functions[_zdx_run_with_timeout]} )) || exit 95
        started=$EPOCHSECONDS
        "_${prefix}_run_with_timeout" 1 sleep 20 2>/dev/null
        rc=$?
        (( EPOCHSECONDS - started < 10 )) || exit 96
        (( rc != 0 )) || exit 97
      ) || { print -r -- "$prefix failed ($?)"; exit 91; }
    done
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
}
