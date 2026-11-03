# Isolated executable probes with no native timeout implementation on PATH.
# Source only after test_helper.bash has created this test's sandbox.
make_core_probe_path() {
  export CORE_PROBE_BIN="$TEST_TEMP_DIR/core-probe-bin"
  mkdir -p "$CORE_PROBE_BIN"
  local tool="" resolved=""
  for tool in chmod env mkdir mktemp ps rm sleep; do
    resolved=$(command -v "$tool") || return 1
    ln -s "$resolved" "$CORE_PROBE_BIN/$tool" || return 1
  done
}

# Standard input becomes the body after a fixed, selected Bash interpreter.
core_probe_program() {
  local name="$1"
  printf '#!%s\n' "$BASH" > "$CORE_PROBE_BIN/$name"
  cat >> "$CORE_PROBE_BIN/$name"
  chmod -- 755 "$CORE_PROBE_BIN/$name"
}

run_core_probe_zsh() {
  local program="$1"
  zsh -f -c '
    emulate -R zsh
    source "$1/functions.zsh" || exit 90
    cd "$HOME" || exit 91
    path=("$CORE_PROBE_BIN")
    rehash
    '"$program"'
  ' _ "$TEST_SUITE_ROOT" < /dev/null
}
