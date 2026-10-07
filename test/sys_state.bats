#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

# Load only the common services and the telemetry module. This keeps eager
# suite loading from polluting mock call records before the command under test.
run_sys_state_zsh() {
  local command_text="$1"

  zsh -c "
    export HOME='$HOME'
    export PATH='$PATH'
    export ZSH_CUSTOM='$TEST_SUITE_ROOT'
    export TEST_MOCK_BIN='$TEST_MOCK_BIN'

    source '$TEST_SUITE_ROOT/functions/sys-common.zsh' || exit 90
    source '$TEST_SUITE_ROOT/functions/sys/sys-capabilities.zsh' || exit 91
    source '$TEST_SUITE_ROOT/functions/sys/sys-telemetry.zsh' || exit 92

    $command_text
  " < /dev/null
}

# The telemetry writer is core-owned. Load functions.zsh lazily so no suite
# entrypoint or feature module is sourced as a side effect of the fixture.
run_core_state_zsh() {
  local command_text="$1"

  zsh -c "
    export HOME='$HOME'
    export PATH='$PATH'
    export ZSH_CUSTOM='$TEST_SUITE_ROOT'
    export ZDX_LAZY_LOAD=1
    unset TEST_TEMP_DIR BATS_TEST_DIRNAME ZDX_EAGER_LOAD

    source '$TEST_SUITE_ROOT/functions.zsh' || exit 90

    $command_text
  " < /dev/null
}

@test "sys state telemetry: writer creates owner-only directory and file" {
  run run_core_state_zsh '
    _log_telemetry "sys:permissions" 0.001 0
  '

  [ "$status" -eq 0 ]
  [ -d "$HOME/.config/zdx" ]
  [ -f "$HOME/.config/zdx/telemetry.json" ]
  [ "$(file_mode "$HOME/.config/zdx")" = "700" ]
  [ "$(file_mode "$HOME/.config/zdx/telemetry.json")" = "600" ]
  [ ! -e "$HOME/.config/zdx/.telemetry.lock" ]
}

@test "sys state telemetry: huge duration is omitted without arithmetic errors" {
  run run_core_state_zsh '
    _log_telemetry \
      "sys:duration-out-of-range" \
      "999999999999999999999999999999999999" 0
  '

  [ "$status" -eq 1 ]
  [ ! -e "$HOME/.config/zdx/telemetry.json" ]
  [[ "$output" != *"bad math expression"* ]]
  [[ "$output" != *"number truncated after 64 bits"* ]]
  [[ "$output" != *"integer expression expected"* ]]
}

@test "sys state telemetry: writer discards a final partial JSON line" {
  mkdir -p "$HOME/.config/zdx"
  chmod 700 "$HOME/.config/zdx"
  printf '%s\n' \
    '{"suite":"sys","command":"complete","duration_ms":1,"exit_code":0,"timestamp":"2026-01-01T00:00:00Z"}' \
    > "$HOME/.config/zdx/telemetry.json"
  printf '%s' '{"suite":"sys","command":"partial"' \
    >> "$HOME/.config/zdx/telemetry.json"
  chmod 600 "$HOME/.config/zdx/telemetry.json"

  run run_core_state_zsh '
    _log_telemetry "sys:after-partial" 0.001 0
  '

  [ "$status" -eq 0 ]
  local log_file="$HOME/.config/zdx/telemetry.json"
  [ "$(wc -l < "$log_file")" -eq 2 ]
  grep -q '"command":"complete"' "$log_file"
  grep -q '"command": "after-partial"' "$log_file"
  [ "$(grep -c '"command":"partial"' "$log_file" || true)" -eq 0 ]
  [ "$(grep -c '}{' "$log_file" || true)" -eq 0 ]
  [ "$(tail -c 1 "$log_file" | wc -l)" -eq 1 ]
  [ ! -e "$HOME/.config/zdx/.telemetry.lock" ]
}

@test "sys state telemetry: writer enforces bounded record retention" {
  run run_core_state_zsh '
    ZDX_TELEMETRY_MAX_RECORDS=3
    for command_name in one two three four five; do
      _log_telemetry "sys:${command_name}" 0.001 0 || exit
    done
  '

  [ "$status" -eq 0 ]
  local log_file="$HOME/.config/zdx/telemetry.json"
  [ "$(wc -l < "$log_file")" -eq 3 ]
  [ "$(grep -c '"command": "one"' "$log_file" || true)" -eq 0 ]
  [ "$(grep -c '"command": "two"' "$log_file" || true)" -eq 0 ]
  grep -q '"command": "three"' "$log_file"
  grep -q '"command": "four"' "$log_file"
  grep -q '"command": "five"' "$log_file"
}

@test "sys state telemetry: writer keeps the published file within byte limit" {
  run run_core_state_zsh '
    ZDX_TELEMETRY_MAX_BYTES=160
    _log_telemetry "sys:one" 0.001 0 || exit
    _log_telemetry "sys:two" 0.001 0 || exit
    _log_telemetry "sys:three" 0.001 0 || exit
  '

  [ "$status" -eq 0 ]
  local log_file="$HOME/.config/zdx/telemetry.json"
  [ "$(wc -c < "$log_file")" -le 160 ]
  [ "$(wc -l < "$log_file")" -eq 1 ]
  grep -q '"command": "three"' "$log_file"
  [ "$(grep -c '"command": "one"' "$log_file" || true)" -eq 0 ]
  [ "$(grep -c '"command": "two"' "$log_file" || true)" -eq 0 ]
  [ ! -e "$HOME/.config/zdx/.telemetry.lock" ]
  [ -z "$(find "$HOME/.config/zdx" -name '.telemetry.*' -print -quit)" ]
}

@test "sys state telemetry: writer refuses a symbolic-link log" {
  mkdir -p "$HOME/.config/zdx"
  printf 'sentinel\n' > "$HOME/telemetry-target"
  ln -s "$HOME/telemetry-target" "$HOME/.config/zdx/telemetry.json"

  run run_core_state_zsh '
    _log_telemetry "sys:must-not-write" 0.001 0
  '

  [ "$status" -eq 1 ]
  [ -L "$HOME/.config/zdx/telemetry.json" ]
  [ "$(cat "$HOME/telemetry-target")" = "sentinel" ]
  [ ! -e "$HOME/.config/zdx/.telemetry.lock" ]
  [ -z "$(find "$HOME/.config/zdx" -name '.telemetry.*' -print -quit)" ]
}

@test "sys state telemetry: writer reader and clear reject symlinked parent" {
  local real_config="$HOME/real-config"
  mkdir -p "$real_config/zdx"
  chmod 700 "$real_config/zdx"
  printf '%s\n' \
    '{"suite":"sys","command":"sentinel","duration_ms":1,"exit_code":0,"timestamp":"2026-01-01T00:00:00Z"}' \
    > "$real_config/zdx/telemetry.json"
  chmod 600 "$real_config/zdx/telemetry.json"
  ln -s "$real_config" "$HOME/.config"
  local before_digest
  before_digest=$(sha256_file "$real_config/zdx/telemetry.json")

  run run_core_state_zsh '
    _log_telemetry "sys:must-not-follow-parent" 0.001 0
  '
  [ "$status" -eq 1 ]

  run run_sys_state_zsh '
    sys-telemetry --dashboard
  '
  [ "$status" -eq 1 ]

  run run_sys_state_zsh '
    sys-telemetry --clear --yes
  '
  [ "$status" -eq 1 ]

  [ -L "$HOME/.config" ]
  [ "$(readlink "$HOME/.config")" = "$real_config" ]
  [ "$(sha256_file "$real_config/zdx/telemetry.json")" = "$before_digest" ]
  [ ! -e "$real_config/zdx/.telemetry.lock" ]
  [ -z "$(find "$real_config/zdx" -name '.telemetry.*' -print -quit)" ]
}

@test "sys state telemetry: writer refuses an oversized existing log" {
  mkdir -p "$HOME/.config/zdx"
  printf '0123456789abcdef\n' > "$HOME/.config/zdx/telemetry.json"
  chmod 600 "$HOME/.config/zdx/telemetry.json"
  local before_digest
  before_digest=$(sha256_file "$HOME/.config/zdx/telemetry.json")

  run run_core_state_zsh '
    ZDX_TELEMETRY_MAX_BYTES=8
    _log_telemetry "sys:must-not-append" 0.001 0
  '

  [ "$status" -eq 1 ]
  [ "$(sha256_file "$HOME/.config/zdx/telemetry.json")" = "$before_digest" ]
  [ ! -e "$HOME/.config/zdx/.telemetry.lock" ]
  [ -z "$(find "$HOME/.config/zdx" -name '.telemetry.*' -print -quit)" ]
}

@test "sys state telemetry: clear dry-run preserves content and identity" {
  mkdir -p "$HOME/.config/zdx"
  printf 'telemetry-data\n' > "$HOME/.config/zdx/telemetry.json"
  chmod 600 "$HOME/.config/zdx/telemetry.json"
  local before_inode
  before_inode=$(file_identity "$HOME/.config/zdx/telemetry.json")

  run run_sys_state_zsh '
    sys-telemetry --clear --dry-run \
      >"$HOME/clear.stdout" 2>"$HOME/clear.stderr"
  '

  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.config/zdx/telemetry.json")" = "telemetry-data" ]
  [ "$(file_identity "$HOME/.config/zdx/telemetry.json")" = "$before_inode" ]
  [ ! -e "$HOME/.config/zdx/.telemetry.lock" ]
  grep -q "Dry run complete" "$HOME/clear.stderr"
}

@test "sys state telemetry: non-interactive clear without yes fails closed" {
  mkdir -p "$HOME/.config/zdx"
  printf 'telemetry-data\n' > "$HOME/.config/zdx/telemetry.json"
  chmod 600 "$HOME/.config/zdx/telemetry.json"
  local before_inode
  before_inode=$(file_identity "$HOME/.config/zdx/telemetry.json")

  run run_sys_state_zsh '
    sys-telemetry --clear \
      >"$HOME/clear.stdout" 2>"$HOME/clear.stderr"
  '

  [ "$status" -eq 1 ]
  [ "$(cat "$HOME/.config/zdx/telemetry.json")" = "telemetry-data" ]
  [ "$(file_identity "$HOME/.config/zdx/telemetry.json")" = "$before_inode" ]
  [ ! -e "$HOME/.config/zdx/.telemetry.lock" ]
  grep -q "requires --yes" "$HOME/clear.stderr"
}

@test "sys state telemetry: clear refuses a symbolic-link log" {
  mkdir -p "$HOME/.config/zdx"
  printf 'sentinel\n' > "$HOME/telemetry-target"
  ln -s "$HOME/telemetry-target" "$HOME/.config/zdx/telemetry.json"

  run run_sys_state_zsh '
    sys-telemetry --clear --yes \
      >"$HOME/clear.stdout" 2>"$HOME/clear.stderr"
  '

  [ "$status" -eq 1 ]
  [ -L "$HOME/.config/zdx/telemetry.json" ]
  [ "$(cat "$HOME/telemetry-target")" = "sentinel" ]
  [ ! -e "$HOME/.config/zdx/.telemetry.lock" ]
  grep -q "not a link" "$HOME/clear.stderr"
}

@test "sys state telemetry: writer records durations under a decimal-comma locale" {
  local locale_dir="$TEST_TEMP_DIR/locales"
  command -v localedef >/dev/null 2>&1 || skip "localedef is unavailable"
  mkdir -p "$locale_dir"
  localedef -i de_DE -f UTF-8 "$locale_dir/de_DE.UTF-8" >/dev/null 2>&1 \
    || skip "a decimal-comma locale cannot be built"

  run run_core_state_zsh "
    export LOCPATH='$locale_dir' LC_ALL=de_DE.UTF-8 ZDX_TELEMETRY=1
    printf -v probe '%.1f' 1.5
    [[ \"\$probe\" == '1,5' ]] || exit 42
    _timed 'sys:sys-info' true
  "

  [ "$status" -ne 42 ] || skip "the built locale does not use a decimal comma"
  [ "$status" -eq 0 ]
  grep -q '"command": "sys-info"' "$HOME/.config/zdx/telemetry.json"
}
