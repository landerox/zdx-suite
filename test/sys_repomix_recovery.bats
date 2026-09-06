#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  export REPOMIX_REAL_NODE
  REPOMIX_REAL_NODE=$(command -v node) || skip "Node.js is required for passive descriptor coverage"
  load test_helper
  export REPOMIX_LOG="$TEST_TEMP_DIR/repomix.log"
  export REPOMIX_PREFIX="$HOME/npm-prefix"
  export TMPDIR="$TEST_TEMP_DIR/tmp"
  mkdir -m 700 "$TMPDIR" "$REPOMIX_PREFIX"
  mkdir -p "$REPOMIX_PREFIX/lib/node_modules/repomix/bin" "$REPOMIX_PREFIX/bin"
  : > "$REPOMIX_LOG"
  cat > "$REPOMIX_PREFIX/lib/node_modules/repomix/package.json" <<'EOF'
{"name":"repomix","version":"1.0.0","bin":{"repomix":"bin/repomix.cjs"}}
EOF
  cat > "$REPOMIX_PREFIX/lib/node_modules/repomix/bin/repomix.cjs" <<'EOF'
#!/usr/bin/env zsh
print -r -- "version:$*" >> "$REPOMIX_LOG"
print -r -- '1.0.0'
if [[ -f "$REPOMIX_PREFIX/updated" ]]; then exit "${REPOMIX_POST_VERSION_STATUS:-0}"; fi
exit 0
EOF
  chmod +x "$REPOMIX_PREFIX/lib/node_modules/repomix/bin/repomix.cjs"
  ln -s "$REPOMIX_PREFIX/lib/node_modules/repomix/bin/repomix.cjs" "$REPOMIX_PREFIX/bin/repomix"
  cat > "$TEST_MOCK_BIN/node" <<'EOF'
#!/usr/bin/env zsh
if [[ "$*" == --version ]]; then print -r -- v22.1.0; exit 0; fi
exec "$REPOMIX_REAL_NODE" "$@"
EOF
  cat > "$TEST_MOCK_BIN/npm" <<'EOF'
#!/usr/bin/env zsh
case "$*" in
  'config get prefix') print -r -- "${REPOMIX_QUERY_PREFIX:-$REPOMIX_PREFIX}" ;;
  'root -g') print -r -- "$REPOMIX_PREFIX/lib/node_modules" ;;
  'list -g --depth=0 repomix') print -r -- 'repomix@1.0.0' ;;
  install*)
    print -r -- "npm:$*" >> "$REPOMIX_LOG"
    touch "$REPOMIX_PREFIX/updated"
    exit "${REPOMIX_INSTALL_STATUS:-0}"
    ;;
  *) exit 97 ;;
esac
EOF
  cat > "$TEST_MOCK_BIN/brew" <<'EOF'
#!/usr/bin/env zsh
case "$*" in
  --prefix) print -r -- "$HOME/unrelated-brew" ;;
  'list repomix') exit "${REPOMIX_BREW_STATUS:-1}" ;;
  *) print -r -- "unexpected-brew:$*" >> "$REPOMIX_LOG"; exit 97 ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/node" "$TEST_MOCK_BIN/npm" "$TEST_MOCK_BIN/brew"
}

teardown() {
  cleanup_sandbox
}

@test "sys Repomix: a shell wrapper alone never authorizes a global npm installation" {
  run run_zsh '
    PATH="$TEST_MOCK_BIN:/usr/bin:/bin"
    repomix() { print -r -- unexpected-wrapper >> "$REPOMIX_LOG"; }
    update-repomix
  '
  [ "$status" -eq 0 ]
  [ ! -s "$REPOMIX_LOG" ]
  [[ "$output" == *"skipping"* ]]
}

@test "sys Repomix: an unrelated active executable cannot update the global package" {
  cp "$REPOMIX_PREFIX/lib/node_modules/repomix/bin/repomix.cjs" "$TEST_MOCK_BIN/repomix"
  run run_zsh 'update-repomix'
  [ "$status" -eq 1 ]
  [ ! -s "$REPOMIX_LOG" ]
  [[ "$output" == *"does not belong to the selected npm global package"* ]]
}

@test "sys Repomix: the exact global package updates through its frozen npm prefix" {
  export REPOMIX_BREW_STATUS=0
  run run_zsh '
    PATH="$REPOMIX_PREFIX/bin:$PATH"
    update-repomix || return $?
    _sys_step_applies update-repomix
  '
  [ "$status" -eq 0 ]
  grep -Fx "npm:install -g --prefix $REPOMIX_PREFIX -- repomix@latest" "$REPOMIX_LOG"
  [[ "$output" == *"Repomix already at latest"* ]]
}

@test "sys Repomix: an escaping package bin descriptor is refused before mutation" {
  printf '%s\n' '{"name":"repomix","bin":{"repomix":"../../outside"}}' \
    > "$REPOMIX_PREFIX/lib/node_modules/repomix/package.json"
  run run_zsh 'PATH="$REPOMIX_PREFIX/bin:$PATH"; update-repomix'
  [ "$status" -eq 1 ]
  [ ! -s "$REPOMIX_LOG" ]
}

@test "sys Repomix: updater failure remains nonzero and never reports success" {
  export REPOMIX_INSTALL_STATUS=42
  run run_zsh 'PATH="$REPOMIX_PREFIX/bin:$PATH"; update-repomix'
  [ "$status" -eq 1 ]
  [[ "$output" != *"Repomix already at latest"* ]]
  [[ "$output" != *"Repomix updated"* ]]
}

@test "sys Repomix: an unusable CLI after installation is not reported as updated" {
  export REPOMIX_POST_VERSION_STATUS=42
  run run_zsh 'PATH="$REPOMIX_PREFIX/bin:$PATH"; update-repomix'
  [ "$status" -eq 1 ]
  [[ "$output" != *"Repomix already at latest"* ]]
  [[ "$output" != *"Repomix updated"* ]]
}

@test "sys Repomix: the global installer refuses a changed frozen prefix" {
  export REPOMIX_QUERY_PREFIX="$HOME/another-prefix"
  mkdir -p "$REPOMIX_QUERY_PREFIX"
  run run_zsh '_sys_npm_install_g repomix@latest "$REPOMIX_PREFIX" "$TEST_MOCK_BIN/npm"'
  [ "$status" -eq 1 ]
  [ ! -s "$REPOMIX_LOG" ]
  [[ "$output" == *"prefix changed"* ]]
}
