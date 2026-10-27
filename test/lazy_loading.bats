#!/usr/bin/env bats

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "lazy_loading: stubs are registered instead of eagerly loading in standard shell" {
  run zsh -f -c "
    emulate -R zsh
    unset TEST_TEMP_DIR
    unset BATS_TEST_DIRNAME
    export ZSH_CUSTOM='$TEST_SUITE_ROOT'
    export HOME='$HOME'
    export PATH='$PATH'

    # Source functions.zsh in a clean environment without test sandbox flags
    source \$ZSH_CUSTOM/functions.zsh

    # Verify public stub is defined
    if ! typeset -f git-menu &>/dev/null; then
      echo 'FAIL: git-menu stub function not defined'
      exit 1
    fi

    # Verify that the actual implementation has NOT been loaded (helper _git_dispatch is undefined)
    if typeset -f _git_dispatch &>/dev/null; then
      echo 'FAIL: git-common.zsh was sourced eagerly'
      exit 1
    fi

    echo 'SUCCESS: lazy loading stub registered without eager sourcing'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"SUCCESS: lazy loading stub registered without eager sourcing"* ]]
}

@test "lazy_loading: invoking a stub unsets it, sources actual file, and executes real function" {
  run zsh -f -c "
    emulate -R zsh
    unset TEST_TEMP_DIR
    unset BATS_TEST_DIRNAME
    export ZSH_CUSTOM='$TEST_SUITE_ROOT'
    export HOME='$HOME'
    export PATH='$PATH'

    # Source functions.zsh
    source \$ZSH_CUSTOM/functions.zsh

    # Before calling, git helpers (like _git_dispatch) do NOT exist
    if typeset -f _git_dispatch &>/dev/null; then
      echo 'FAIL: git-common.zsh helpers are already present'
      exit 1
    fi

    # Trigger the lazy loading stub
    git-menu --help >/dev/null

    # After calling, git-common.zsh must have been sourced, so _git_dispatch MUST exist
    if ! typeset -f _git_dispatch &>/dev/null; then
      echo 'FAIL: git-common.zsh was not sourced on stub invocation'
      exit 1
    fi

    echo 'SUCCESS: stub successfully hot-loaded target file and executed'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"SUCCESS: stub successfully hot-loaded target file and executed"* ]]
}

@test "lazy_loading: every public command has a cold stub" {
  run zsh -f -c "
    emulate -R zsh
    unset TEST_TEMP_DIR
    unset BATS_TEST_DIRNAME
    export ZSH_CUSTOM='$TEST_SUITE_ROOT'
    export HOME='$HOME'
    export PATH='$PATH'

    source \$ZSH_CUSTOM/functions.zsh || exit 1

    local fixture command_name suite
    local -i count=0
    for fixture in \$ZSH_CUSTOM/test/fixtures/*-public-commands.tsv; do
      while IFS=\$'\t' read -r command_name _rest; do
        [[ -z \"\$command_name\" || \"\$command_name\" == \#* ]] && continue
        [[ \"\${functions[\$command_name]-}\" == *_zdx_lazy_dispatch* ]] || {
          print -r -- \"missing lazy stub: \$command_name\"
          exit 1
        }
        (( count++ ))
      done < \"\$fixture\"
    done
    (( count == 120 )) || { print -r -- \"expected 120 stubs, found \$count\"; exit 1; }
    # Checking the stubs loads no suite.
    for suite in dev env file git py sys vpn ws; do
      (( ! \${+functions[_\${suite}_dispatch]} )) || {
        print -r -- \"suite loaded early: \$suite\"
        exit 1
      }
    done
  "
  [ "$status" -eq 0 ]
}

@test "lazy_loading: a direct command stub loads its suite on first use" {
  run zsh -f -c "
    emulate -R zsh
    unset TEST_TEMP_DIR
    unset BATS_TEST_DIRNAME
    export ZSH_CUSTOM='$TEST_SUITE_ROOT'
    export HOME='$HOME'
    export PATH='$PATH'

    source \$ZSH_CUSTOM/functions.zsh || exit 1

    local suite command_name
    for suite command_name in \
      git git-status \
      dev dev-run-all-checks \
      sys update-system \
      vpn vpn-summary; do
      (( ! \${+functions[_\${suite}_dispatch]} )) || exit 2
      \$command_name --help >/dev/null 2>&1 || {
        print -r -- \"help failed: \$command_name\"
        exit 3
      }
      (( \${+functions[_\${suite}_dispatch]} )) || {
        print -r -- \"suite not loaded: \$command_name\"
        exit 4
      }
      [[ \"\${functions[\$command_name]}\" != *_zdx_lazy_dispatch* ]] || exit 5
    done
  "
  [ "$status" -eq 0 ]
}

@test "lazy_loading: ZDX_DIRECT_COMMANDS=0 registers only the entrypoints" {
  run zsh -f -c "
    emulate -R zsh
    unset TEST_TEMP_DIR
    unset BATS_TEST_DIRNAME
    export ZSH_CUSTOM='$TEST_SUITE_ROOT'
    export HOME='$HOME'
    export PATH='$PATH'
    export ZDX_DIRECT_COMMANDS=0

    source \$ZSH_CUSTOM/functions.zsh || exit 1

    local name
    for name in dev-menu env-menu file-menu git-menu py-menu sys-menu \
      vpn-menu ws-menu zdx zdx-menu zdx-doctor zdx-plugins zdx-status; do
      (( \${+functions[\$name]} )) || {
        print -r -- \"missing entrypoint: \$name\"
        exit 1
      }
    done
    for name in git-status update-system dev-run-tests vpn-summary ws-jump \
      file-extract env-list venv-create; do
      (( ! \${+functions[\$name]} )) || {
        print -r -- \"unexpected direct stub: \$name\"
        exit 2
      }
    done
    git-menu --help >/dev/null 2>&1 || exit 3
    (( \${+functions[git-status]} )) || exit 4
  "
  [ "$status" -eq 0 ]
}

@test "lazy_loading: a fresh clone registers no user-local compatibility names" {
  local suite_copy="$TEST_TEMP_DIR/suite"
  mkdir -p "$suite_copy/functions" "$TEST_TEMP_DIR/elsewhere"
  cp "$TEST_SUITE_ROOT/functions.zsh" "$suite_copy/functions.zsh"

  local probe="
    emulate -R zsh
    unset TEST_TEMP_DIR
    unset BATS_TEST_DIRNAME
    export HOME='$HOME'
    export PATH='$PATH'

    source '$suite_copy/functions.zsh' || exit 1
    (( \${+functions[file-clean-junk]} )) || {
      print -r -- 'FAIL: file-clean-junk has no lazy stub'
      exit 1
    }
    for name in zdir zclean; do
      (( ! \${+functions[\$name]} && ! \${+_ZDX_LAZY_FILES[\$name]} )) || {
        print -r -- \"FAIL: \$name is registered\"
        exit 1
      }
    done
    (( ! \${+aliases[wsj]} )) || {
      print -r -- 'FAIL: wsj is registered'
      exit 1
    }
    print -r -- 'SUCCESS: no compatibility names'
  "

  run zsh -f -c "$probe"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SUCCESS: no compatibility names"* ]]

  # A symbolic link would be refused by the lazy dispatcher, so it is not
  # registered either.
  printf '%s\n' 'zdir() { :; }' > "$TEST_TEMP_DIR/elsewhere/zdir.zsh"
  ln -s "$TEST_TEMP_DIR/elsewhere/zdir.zsh" "$suite_copy/functions/zdir.zsh"
  run zsh -f -c "$probe"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SUCCESS: no compatibility names"* ]]
}

@test "lazy_loading: a user-local zdir registers its stub and alias; zclean stays retired" {
  local suite_copy="$TEST_TEMP_DIR/suite"
  mkdir -p "$suite_copy/functions"
  cp "$TEST_SUITE_ROOT/functions.zsh" "$suite_copy/functions.zsh"
  printf '%s\n' 'zdir() { print -r -- "local zdir:$*"; }' \
    > "$suite_copy/functions/zdir.zsh"
  printf '%s\n' 'zclean() { print -r -- "local zclean"; }' \
    > "$suite_copy/functions/zclean.zsh"

  run zsh -f -c "
    emulate -R zsh
    unset TEST_TEMP_DIR
    unset BATS_TEST_DIRNAME
    export HOME='$HOME'
    export PATH='$PATH'

    source '$suite_copy/functions.zsh' || exit 1
    [[ \"\${aliases[wsj]-}\" == zdir ]] || {
      print -r -- 'FAIL: wsj does not point to zdir'
      exit 1
    }
    (( ! \${+functions[zclean]} && ! \${+_ZDX_LAZY_FILES[zclean]} )) || {
      print -r -- 'FAIL: zclean is registered'
      exit 1
    }
    [[ \"\$(zdir one)\" == 'local zdir:one' ]] || {
      print -r -- 'FAIL: the zdir stub did not load the local file'
      exit 1
    }
    print -r -- 'SUCCESS: zdir resolved locally'
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"SUCCESS: zdir resolved locally"* ]]
}

@test "lazy_loading: setting ZDX_EAGER_LOAD=1 bypasses lazy loading" {
  run zsh -f -c "
    emulate -R zsh
    export ZSH_CUSTOM='$TEST_SUITE_ROOT'
    export HOME='$HOME'
    export PATH='$PATH'
    export ZDX_EAGER_LOAD=1

    source \$ZSH_CUSTOM/functions.zsh

    # Since eager loading was forced, helper functions must be immediately available
    if ! typeset -f _git_dispatch &>/dev/null; then
      echo 'FAIL: git-common.zsh helpers not eagerly loaded'
      exit 1
    fi

    echo 'SUCCESS: eager loading forced successfully'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"SUCCESS: eager loading forced successfully"* ]]
}

@test "lazy_loading: plugin wrapper preserves the caller's ZSH_CUSTOM" {
  local caller_custom="$HOME/caller-custom"
  local probe_dir="$HOME/.config/zdx/plugins/probe"
  mkdir -p "$caller_custom" "$probe_dir"
  # A custom plugin is sourced during the load, so it records the value that
  # eagerly loaded modules observe rather than only the final shell state.
  cat <<'EOF' > "$probe_dir/probe-menu.zsh"
typeset -g _ZDX_TEST_LOAD_TIME_CUSTOM="${ZSH_CUSTOM:-}"
probe-menu() { return 0; }
EOF

  run zsh -f -c "
    emulate -R zsh
    export HOME='$HOME'
    export PATH='$PATH'
    export ZSH_CUSTOM='$caller_custom'
    export ZDX_EAGER_LOAD=1

    source '$TEST_SUITE_ROOT/zdx-suite.plugin.zsh' || exit 1

    [[ \"\$ZSH_CUSTOM\" == '$caller_custom' ]] || {
      echo 'FAIL: plugin wrapper changed ZSH_CUSTOM'
      exit 1
    }
    (( \${ZDX_LOADED_PLUGINS[(Ie)probe]} > 0 )) || {
      echo 'FAIL: the load-time probe plugin did not load'
      exit 1
    }
    [[ \"\$_ZDX_TEST_LOAD_TIME_CUSTOM\" == '$caller_custom' ]] || {
      echo 'FAIL: the eager load did not see the caller custom root'
      exit 1
    }

    echo 'SUCCESS: plugin wrapper preserved caller configuration'
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"SUCCESS: plugin wrapper preserved caller configuration"* ]]
}

@test "lazy_loading: an eager core sourced from a function, as Oh My Zsh does, keeps its loaded plugins" {
  local plugin_root="$HOME/.config/zdx/plugins"
  mkdir -p "$plugin_root/probe"
  chmod 755 "$HOME" "$HOME/.config" "$HOME/.config/zdx" "$plugin_root/probe"
  chmod 700 "$plugin_root"
  # shellcheck disable=SC2016
  printf '%s\n' 'probe-menu() { print -r -- "probe menu: $*"; }' \
    > "$plugin_root/probe/probe-menu.zsh"
  chmod 644 "$plugin_root/probe/probe-menu.zsh"

  # Oh My Zsh sources each plugin entrypoint from its _omz_source function,
  # so the plugins loaded at startup must stay recorded after it returns.
  # shellcheck disable=SC2016
  run env -u TEST_TEMP_DIR -u BATS_TEST_DIRNAME "$(command -v zsh)" -f -c '
    emulate -R zsh
    unset -m "ZDX_*"
    ZDX_EAGER_LOAD=1 NO_COLOR=1
    _omz_source() {
      local context filepath="$1"
      source "$filepath"
    }
    _omz_source "$1/zdx-suite.plugin.zsh" || exit 90
    print -r -- "after-source: set=${+ZDX_LOADED_PLUGINS} loaded=[${(j:,:)ZDX_LOADED_PLUGINS}]"
    zdx-plugins --list 2>&1 | grep -E "^probe "
    cd "$HOME" || exit 91
    zdx-status 2>&1 | grep -E "^  Plugins:"
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "after-source: set=1 loaded=[probe]" ]
  [[ "${lines[1]}" =~ ^probe\ +Active\ +Local$ ]]
  [[ "${lines[2]}" =~ ^\ \ Plugins:\ +1\ custom\ plugin\ loaded$ ]]
}

@test "lazy_loading: plugin registers nested completions after compinit ordering" {
  local registration_log="$TEST_TEMP_DIR/completion-registrations"
  : > "$registration_log"

  run zsh -f -c "
    emulate -R zsh
    unset TEST_TEMP_DIR
    unset BATS_TEST_DIRNAME
    export HOME='$HOME'
    export PATH='$PATH'
    export ZDX_KEYBINDINGS=0
    export ZDX_LAZY_LOAD=1

    compdef() {
      local completion_function=\"\$1\"
      shift
      print -r -- \"\$completion_function:\$*\" \
        >> '$registration_log'
    }

    source '$TEST_SUITE_ROOT/zdx-suite.plugin.zsh' || exit 1
    local registrations
    registrations=\$(<'$registration_log')
    for expected in \
      '_file-menu:file-menu' \
      '_env-menu:env-menu' \
      '_py-menu:py-menu' \
      '_ws-menu:ws-menu' \
      '_git-menu:git-menu clean-branches' \
      '_dev-menu:dev-menu dev-check-health' \
      '_sys-menu:sys-menu update-system' \
      '_vpn-menu:vpn-menu' \
      '_zdx-menu:zdx zdx-menu'; do
      [[ \"\$registrations\" == *\"\$expected\"* ]] || {
        print -r -- \"missing completion registration: \$expected\"
        exit 1
      }
    done
  "

  [ "$status" -eq 0 ]
}
