#!/usr/bin/env bats
# shellcheck disable=SC2016
#
# Ownership and permission checks before ZDX sources user code: the
# configuration, the overrides, and plugin entrypoints.

setup() {
  load test_helper
  TRUST_HOME="$TEST_TEMP_DIR/trust-home"
  mkdir -p "$TRUST_HOME/.config/zdx"
  chmod 755 "$TRUST_HOME" "$TRUST_HOME/.config" "$TRUST_HOME/.config/zdx"
  export TRUST_HOME
}

teardown() {
  cleanup_sandbox
}

# Starts ZDX with TRUST_HOME and prints the probe variable, the refused files,
# and whether the zdx router exists.
trust_start() {
  HOME="$TRUST_HOME" zsh -f -c '
    emulate -R zsh
    source "$1/functions.zsh"
    print -r -- "probe=${ZDX_TRUST_PROBE:-unset}"
    print -r -- "refused=${(j:,:)_ZDX_REFUSED_USER_FILES}"
    (( ${+functions[zdx]} )) && print -r -- "router=loaded"
  ' _ "$TEST_SUITE_ROOT"
}

@test "trusted user code: a private configuration loads" {
  printf '%s\n' 'typeset -g ZDX_TRUST_PROBE=config' > "$TRUST_HOME/.config/zdx/config.zsh"
  chmod 644 "$TRUST_HOME/.config/zdx/config.zsh"
  run trust_start
  [ "$status" -eq 0 ]
  [[ "$output" == *"probe=config"* ]]
  [[ "$output" == *"refused="$'\n'* ]]
  [[ "$output" == *"router=loaded"* ]]
}

@test "trusted user code: a group-writable configuration is refused with the remedy" {
  local config="$TRUST_HOME/.config/zdx/config.zsh"
  printf '%s\n' 'typeset -g ZDX_TRUST_PROBE=config' > "$config"
  chmod 664 "$config"
  run trust_start
  [ "$status" -eq 0 ]
  [[ "$output" == *"zdx: refusing to load user configuration $config"* ]]
  [[ "$output" == *"chmod -- go-w $config $TRUST_HOME/.config/zdx"* ]]
  [[ "$output" == *"probe=unset"* ]]
  [[ "$output" == *"refused=$config"* ]]
  [[ "$output" == *"router=loaded"* ]]
}

@test "trusted user code: overrides follow the same rule" {
  local overrides="$TRUST_HOME/.config/zdx/overrides.zsh"
  printf '%s\n' 'typeset -g ZDX_TRUST_PROBE=overrides' > "$overrides"
  chmod 600 "$overrides"
  run -0 trust_start
  [[ "$output" == *"probe=overrides"* ]]

  chmod 606 "$overrides"
  run -0 trust_start
  [[ "$output" == *"zdx: refusing to load user overrides $overrides"* ]]
  [[ "$output" == *"probe=unset"* ]]
}

@test "trusted user code: hard links and writable directories are refused" {
  local config="$TRUST_HOME/.config/zdx/config.zsh"
  printf '%s\n' 'typeset -g ZDX_TRUST_PROBE=config' > "$config"
  chmod 644 "$config"
  ln "$config" "$TEST_TEMP_DIR/second-link"
  run -0 trust_start
  [[ "$output" == *"probe=unset"* ]]
  [[ "$output" == *"refused=$config"* ]]

  rm "$TEST_TEMP_DIR/second-link"
  chmod 775 "$TRUST_HOME/.config/zdx"
  run -0 trust_start
  [[ "$output" == *"probe=unset"* ]]
  [[ "$output" == *"refused=$config"* ]]
}

@test "trusted user code: dotfile links are followed and checked hop by hop" {
  local config="$TRUST_HOME/.config/zdx/config.zsh"
  mkdir -p "$TRUST_HOME/dotfiles/zdx"
  chmod 755 "$TRUST_HOME/dotfiles" "$TRUST_HOME/dotfiles/zdx"
  printf '%s\n' 'typeset -g ZDX_TRUST_PROBE=linked' > "$TRUST_HOME/dotfiles/zdx/config.zsh"
  chmod 644 "$TRUST_HOME/dotfiles/zdx/config.zsh"
  ln -s ../../dotfiles/zdx/config.zsh "$config"
  run -0 trust_start
  [[ "$output" == *"probe=linked"* ]]

  # A second hop through a directory that other users can write.
  mkdir -p "$TEST_TEMP_DIR/shared"
  chmod 777 "$TEST_TEMP_DIR/shared"
  ln -s "$TRUST_HOME/dotfiles/zdx/config.zsh" "$TEST_TEMP_DIR/shared/hop"
  rm "$config"
  ln -s "$TEST_TEMP_DIR/shared/hop" "$config"
  run -0 trust_start
  [[ "$output" == *"probe=unset"* ]]
  [[ "$output" == *"refused=$config"* ]]

  # A target inside a group-writable directory.
  rm "$config"
  chmod 775 "$TRUST_HOME/dotfiles/zdx"
  ln -s ../../dotfiles/zdx/config.zsh "$config"
  run -0 trust_start
  [[ "$output" == *"probe=unset"* ]]
}

@test "trusted user code: read-only root-owned Nix store files are accepted" {
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions.zsh" 2>/dev/null || exit 90
    typeset -gA fake_state=(
      /nix "0 $(( 8#040755 ))"
      /nix/store "0 $(( 8#041775 ))"
      /nix/store/abc-home-manager-files "0 $(( 8#040555 ))"
      /nix/store/abc-home-manager-files/zdx "0 $(( 8#040555 ))"
    )
    zstat() {
      local target="${@[-1]}" name="" previous=""
      for name in "$@"; do
        [[ "$previous" == -LH ]] && break
        previous="$name"
      done
      (( ${+fake_state[$target]} )) || return 1
      local -a fields=(${=fake_state[$target]})
      set -A "$name" uid "${fields[1]}" mode "${fields[2]}"
    }
    file=/nix/store/abc-home-manager-files/zdx/config.zsh
    _zdx_nix_store_file_trusted "$file" 0 $(( 8#100444 )) && print store-file
    _zdx_nix_store_file_trusted "$file" 0 $(( 8#100644 )) || print writable-refused
    _zdx_nix_store_file_trusted "$file" 1000 $(( 8#100444 )) || print user-refused
    fake_state[/nix/store]="0 $(( 8#040777 ))"
    _zdx_nix_store_file_trusted "$file" 0 $(( 8#100444 )) || print open-store-refused
    _zdx_nix_store_file_trusted /etc/zdx/config.zsh 0 $(( 8#100444 )) || print outside-refused
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = $'store-file\nwritable-refused\nuser-refused\nopen-store-refused\noutside-refused' ]
}

@test "trusted user code: plugin entrypoints writable by others are refused" {
  local plugins="$TRUST_HOME/.config/zdx/plugins"
  mkdir -p "$plugins/demo"
  chmod 700 "$plugins"
  chmod 755 "$plugins/demo"
  printf '%s\n' 'demo-menu() { :; }' > "$plugins/demo/demo-menu.zsh"
  chmod 644 "$plugins/demo/demo-menu.zsh"
  run -0 env HOME="$TRUST_HOME" zsh -f -c '
    emulate -R zsh
    source "$1/functions.zsh"
    print -r -- "plugins=${(j:,:)ZDX_LOADED_PLUGINS}"
  ' _ "$TEST_SUITE_ROOT"
  [[ "$output" == *"plugins=demo"* ]]

  chmod 664 "$plugins/demo/demo-menu.zsh"
  run -0 env HOME="$TRUST_HOME" zsh -f -c '
    emulate -R zsh
    source "$1/functions.zsh"
    print -r -- "plugins=${(j:,:)ZDX_LOADED_PLUGINS}"
  ' _ "$TEST_SUITE_ROOT"
  [[ "$output" == *"refusing unsafe plugin entrypoint 'demo'"* ]]
  [[ "$output" == *"plugins="$'\n'* || "$output" == *"plugins=" ]]

  chmod 644 "$plugins/demo/demo-menu.zsh"
  chmod 775 "$plugins/demo"
  run -0 env HOME="$TRUST_HOME" zsh -f -c '
    emulate -R zsh
    source "$1/functions.zsh"
    print -r -- "plugins=${(j:,:)ZDX_LOADED_PLUGINS}"
  ' _ "$TEST_SUITE_ROOT"
  [[ "$output" == *"refusing unsafe plugin entrypoint 'demo'"* ]]
}

@test "trusted user code: zdx doctor reports a refused configuration" {
  printf '#!/usr/bin/env bash\nprintf "0.74.3 (fixture)\\n"\n' > "$TEST_MOCK_BIN/fzf"
  chmod +x "$TEST_MOCK_BIN/fzf"
  printf '%s\n' 'typeset -g ZDX_TRUST_PROBE=config' > "$TRUST_HOME/.config/zdx/config.zsh"
  chmod 666 "$TRUST_HOME/.config/zdx/config.zsh"
  # Keep the unrelated deny-by-default gh mock out of version diagnostics.
  printf '%s\n' "#!$BASH" \
    '[[ "$#" -eq 1 && "$1" == --version ]] || exit 97' \
    'printf "%s\n" "gh version 2.45.0 (fixture)"' > "$TEST_MOCK_BIN/gh"
  chmod -- 755 "$TEST_MOCK_BIN/gh"
  run -1 env HOME="$TRUST_HOME" zsh -f -c '
    emulate -R zsh
    source "$1/functions.zsh" 2>/dev/null
    source "$1/functions/zdx-doctor.zsh"
    _zdx_doctor_detect_pkg_manager() { print -r -- none; }
    zdx-doctor </dev/null 2>&1
  ' _ "$TEST_SUITE_ROOT"
  [[ "$output" == *"[User Files]"* ]]
  [[ "$output" == *"Refused at startup: $TRUST_HOME/.config/zdx/config.zsh"* ]]
}

@test "trusted user code: overrides keep winning after a lazy suite load" {
  printf '%s\n' 'git-status() { print -r -- "override:git-status"; }' \
    > "$TRUST_HOME/.config/zdx/overrides.zsh"
  chmod 600 "$TRUST_HOME/.config/zdx/overrides.zsh"
  run env -u TEST_TEMP_DIR -u BATS_TEST_DIRNAME HOME="$TRUST_HOME" \
    ZDX_LAZY_LOAD=1 zsh -f -c '
      emulate -R zsh
      source "$1/functions.zsh" || exit 90
      git-status
      git-switch --help >/dev/null 2>&1
      (( ${+functions[_git_dispatch]} )) && print -r -- "suite=loaded"
      git-status
    ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = $'override:git-status\nsuite=loaded\noverride:git-status' ]

  run env HOME="$TRUST_HOME" zsh -f -c '
    emulate -R zsh
    source "$1/functions.zsh" || exit 90
    git-status
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "override:git-status" ]
}
