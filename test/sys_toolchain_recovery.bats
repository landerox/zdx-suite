#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  export TOOLCHAIN_LOG="$TEST_TEMP_DIR/toolchain.log"
  export TMPDIR="$TEST_TEMP_DIR/tmp"
  export TOOLCHAIN_BREW_PREFIX="$TEST_TEMP_DIR/brew"
  mkdir -m 700 "$TMPDIR"
  : > "$TOOLCHAIN_LOG"
  cat > "$TEST_MOCK_BIN/brew" <<'EOF'
#!/usr/bin/env zsh
exit 1
EOF
  chmod +x "$TEST_MOCK_BIN/brew"
}

teardown() {
  cleanup_sandbox
}

write_fnm() {
  cat > "$TEST_MOCK_BIN/fnm" <<'EOF'
#!/usr/bin/env zsh
print -r -- "fnm:$*" >> "$TOOLCHAIN_LOG"
case "$*" in
  'install --lts') exit "${NODE_INSTALL_STATUS:-0}" ;;
  'use lts-latest') exit "${NODE_USE_STATUS:-0}" ;;
  'default lts-latest') exit "${NODE_DEFAULT_STATUS:-0}" ;;
  current)
    print -r -- "${NODE_CURRENT_VERSION-v22.1.0}"
    exit "${NODE_CURRENT_STATUS:-0}"
    ;;
  *) exit 97 ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/fnm"
}

run_nvm_update() {
  run_zsh '
    export NVM_DIR="$HOME/.nvm"
    mkdir -p "$NVM_DIR"
    command() {
      [[ "$1 $2" == "-v fnm" ]] && return 1
      builtin command "$@"
    }
    nvm() {
      print -r -- "nvm:$*" >> "$TOOLCHAIN_LOG"
      case "$*" in
        "install --lts") return "${NODE_INSTALL_STATUS:-0}" ;;
        "version lts/*")
          print -r -- "${NODE_CURRENT_VERSION-v22.1.0}"
          return "${NODE_CURRENT_STATUS:-0}"
          ;;
        "alias default v22.1.0") return "${NODE_DEFAULT_STATUS:-0}" ;;
        "use v22.1.0") return "${NODE_USE_STATUS:-0}" ;;
        current) print -r -- "${NODE_ACTIVE_VERSION-v22.1.0}" ;;
        *) return 97 ;;
      esac
    }
    update-node
  '
}

write_brew_uv() {
  mkdir -p "$TOOLCHAIN_BREW_PREFIX/Cellar/uv/1.2.3/bin" \
    "$TOOLCHAIN_BREW_PREFIX/bin"
  cat > "$TOOLCHAIN_BREW_PREFIX/Cellar/uv/1.2.3/bin/uv" <<'EOF'
#!/usr/bin/env zsh
if [[ "$*" == --version ]]; then
  print -r -- 'uv 1.2.3'
  exit "${UV_VERSION_STATUS:-0}"
fi
print -r -- "unexpected-self-update:$*" >> "$TOOLCHAIN_LOG"
exit 97
EOF
  chmod +x "$TOOLCHAIN_BREW_PREFIX/Cellar/uv/1.2.3/bin/uv"
  ln -s "$TOOLCHAIN_BREW_PREFIX/Cellar/uv/1.2.3/bin/uv" \
    "$TOOLCHAIN_BREW_PREFIX/bin/uv"
  cat > "$TEST_MOCK_BIN/brew" <<'EOF'
#!/usr/bin/env zsh
case "$*" in
  --prefix) print -r -- "$TOOLCHAIN_BREW_PREFIX" ;;
  'upgrade --no-ask uv')
    if IFS= read -r unexpected_input; then
      print -r -- unexpected-stdin >> "$TOOLCHAIN_LOG"
      exit 98
    fi
    print -r -- "brew:$*|auto=${HOMEBREW_NO_AUTO_UPDATE:-}|analytics=${HOMEBREW_NO_ANALYTICS:-}|retries=${HOMEBREW_CURL_RETRIES:-}" >> "$TOOLCHAIN_LOG"
    if [[ -n "${UV_RELINK_TARGET:-}" ]]; then
      ln -sf "$UV_RELINK_TARGET" "$TOOLCHAIN_BREW_PREFIX/bin/uv"
    fi
    exit "${UV_BREW_STATUS:-0}"
    ;;
  *)
    print -r -- "unexpected-brew:$*" >> "$TOOLCHAIN_LOG"
    exit 97
    ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/brew"
}

@test "sys toolchain: fnm use failure preserves installation and still sets the default" {
  write_fnm
  export NODE_USE_STATUS=42
  run run_zsh 'update-node'
  [ "$status" -eq 1 ]
  grep -qx 'fnm:default lts-latest' "$TOOLCHAIN_LOG"
  [[ "$output" == *"activation failed"* ]]
  [[ "$output" != *"installed and set as default"* ]]
}

@test "sys toolchain: fnm default failure still attempts activation" {
  write_fnm
  export NODE_DEFAULT_STATUS=42
  run run_zsh 'update-node'
  [ "$status" -eq 1 ]
  grep -qx 'fnm:use lts-latest' "$TOOLCHAIN_LOG"
  [[ "$output" == *"default selection failed"* ]]
  [[ "$output" != *"installed and set as default"* ]]
}

@test "sys toolchain: fnm success requires a usable current version" {
  write_fnm
  export NODE_CURRENT_VERSION=system
  run run_zsh 'update-node'
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not verify"* ]]

  export NODE_CURRENT_VERSION=v22.1.0 NODE_CURRENT_STATUS=42
  run run_zsh 'update-node'
  [ "$status" -eq 1 ]
  [[ "$output" != *"installed and set as default"* ]]
}

@test "sys toolchain: fnm reports completion after all phases succeed" {
  write_fnm
  run run_zsh '
    fnm() { print -r -- unexpected-fnm-function >> "$TOOLCHAIN_LOG"; return 97; }
    update-node
  '
  [ "$status" -eq 0 ]
  grep -qx 'fnm:install --lts' "$TOOLCHAIN_LOG"
  grep -qx 'fnm:use lts-latest' "$TOOLCHAIN_LOG"
  grep -qx 'fnm:default lts-latest' "$TOOLCHAIN_LOG"
  [[ "$(cat "$TOOLCHAIN_LOG")" != *unexpected-fnm-function* ]]
  [[ "$output" == *"Node.js LTS (v22.1.0) installed and set as default"* ]]
}

@test "sys toolchain: nvm default failure does not discard successful activation" {
  export NODE_DEFAULT_STATUS=42
  run run_nvm_update
  [ "$status" -eq 1 ]
  grep -qx 'nvm:use v22.1.0' "$TOOLCHAIN_LOG"
  [[ "$output" == *"default selection failed"* ]]
  [[ "$output" != *"installed and set as default"* ]]
}

@test "sys toolchain: nvm activation failure remains visible" {
  export NODE_USE_STATUS=42
  run run_nvm_update
  [ "$status" -eq 1 ]
  grep -qx 'nvm:alias default v22.1.0' "$TOOLCHAIN_LOG"
  [[ "$output" == *"activation failed"* ]]
  [[ "$output" != *"installed and set as default"* ]]
}

@test "sys toolchain: nvm rejects an unavailable or failed LTS version probe" {
  export NODE_CURRENT_VERSION=N/A
  run run_nvm_update
  [ "$status" -eq 1 ]
  [ "$(grep -cE '^nvm:(alias|use)' "$TOOLCHAIN_LOG")" -eq 0 ]

  export NODE_CURRENT_VERSION=v22.1.0 NODE_CURRENT_STATUS=42
  run run_nvm_update
  [ "$status" -eq 1 ]
  [ "$(grep -cE '^nvm:(alias|use)' "$TOOLCHAIN_LOG")" -eq 0 ]
}

@test "sys toolchain: nvm verifies activation and reports successful completion" {
  run run_nvm_update
  [ "$status" -eq 0 ]
  [[ "$output" == *"Node.js LTS (v22.1.0) installed and set as default"* ]]

  export NODE_ACTIVE_VERSION=v20.0.0
  run run_nvm_update
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not verify"* ]]
}

@test "sys toolchain: direct Homebrew uv update targets uv and stays aggregate-deduplicated" {
  write_brew_uv
  run run_zsh '
    PATH="$TOOLCHAIN_BREW_PREFIX/bin:$PATH"
    update-uv-system <<< unexpected-input || return $?
    ! _sys_step_applies update-uv-system
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$TOOLCHAIN_LOG")" = \
    'brew:upgrade --no-ask uv|auto=1|analytics=1|retries=0' ]
  [[ "$output" == *"uv updated through Homebrew"* ]]
}

@test "sys toolchain: Homebrew uv failure never falls through to self-update" {
  write_brew_uv
  export UV_BREW_STATUS=42
  run run_zsh 'PATH="$TOOLCHAIN_BREW_PREFIX/bin:$PATH"; update-uv-system'
  [ "$status" -eq 1 ]
  [[ "$(cat "$TOOLCHAIN_LOG")" != *unexpected* ]]
  [[ "$output" != *"uv updated"* ]]
}

@test "sys toolchain: Homebrew uv verification follows the replaced Cellar target" {
  write_brew_uv
  mkdir -p "$TOOLCHAIN_BREW_PREFIX/Cellar/uv/1.2.4/bin"
  export UV_RELINK_TARGET="$TOOLCHAIN_BREW_PREFIX/Cellar/uv/1.2.4/bin/uv"
  cat > "$UV_RELINK_TARGET" <<'EOF'
#!/usr/bin/env zsh
[[ "$*" == --version ]] || exit 97
print -r -- 'uv 1.2.4'
EOF
  chmod +x "$UV_RELINK_TARGET"
  run run_zsh 'PATH="$TOOLCHAIN_BREW_PREFIX/bin:$PATH"; update-uv-system'
  [ "$status" -eq 0 ]
  [[ "$output" == *"uv updated through Homebrew to 1.2.4"* ]]
}

@test "sys toolchain: uv self-update requires a successful version probe" {
  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env zsh
if [[ "$*" == 'self update' ]]; then
  print -r -- self-update >> "$TOOLCHAIN_LOG"
  exit 0
fi
print -r -- 'uv 1.2.3'
exit 42
EOF
  chmod +x "$TEST_MOCK_BIN/uv"
  run run_zsh 'update-uv-system'
  [ "$status" -eq 1 ]
  [ "$(cat "$TOOLCHAIN_LOG")" = self-update ]
  [[ "$output" == *"could not verify its version"* ]]
  [[ "$output" != *"uv updated"* ]]
}

@test "sys toolchain: Homebrew uv success requires a working updated executable" {
  write_brew_uv
  export UV_VERSION_STATUS=42
  run run_zsh 'PATH="$TOOLCHAIN_BREW_PREFIX/bin:$PATH"; update-uv-system'
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not verify"* ]]
  [[ "$output" != *"uv updated"* ]]
}
