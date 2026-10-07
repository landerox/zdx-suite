#!/usr/bin/env bats

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "lazy_loading: stubs are registered instead of eagerly loading in standard shell" {
  run zsh -c "
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
  run zsh -c "
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

@test "lazy_loading: hardened suite direct commands have cold stubs" {
  run zsh -c "
    unset TEST_TEMP_DIR
    unset BATS_TEST_DIRNAME
    export ZSH_CUSTOM='$TEST_SUITE_ROOT'
    export HOME='$HOME'
    export PATH='$PATH'

    source \$ZSH_CUSTOM/functions.zsh || exit 1

    local fixture command_name
    for fixture in \
      file-public-commands.tsv \
      env-public-commands.tsv \
      py-public-commands.tsv \
      ws-public-commands.tsv; do
      while IFS=\$'\t' read -r command_name _rest; do
        [[ -z \"\$command_name\" || \"\$command_name\" == \#* ]] && continue
        typeset -f \"\$command_name\" >/dev/null || {
          print -r -- \"missing lazy stub: \$command_name\"
          exit 1
        }
      done < \"\$ZSH_CUSTOM/test/fixtures/\$fixture\"
    done
  "
  [ "$status" -eq 0 ]
}

@test "lazy_loading: a fresh clone registers no user-local compatibility names" {
  local suite_copy="$TEST_TEMP_DIR/suite"
  mkdir -p "$suite_copy/functions" "$TEST_TEMP_DIR/elsewhere"
  cp "$TEST_SUITE_ROOT/functions.zsh" "$suite_copy/functions.zsh"

  local probe="
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
  run zsh -c "
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

  run zsh -c "
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

@test "lazy_loading: plugin registers nested completions after compinit ordering" {
  local registration_log="$TEST_TEMP_DIR/completion-registrations"
  : > "$registration_log"

  run zsh -f -c "
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
      '_zdx-menu:zdx zdx-menu'; do
      [[ \"\$registrations\" == *\"\$expected\"* ]] || {
        print -r -- \"missing completion registration: \$expected\"
        exit 1
      }
    done
  "

  [ "$status" -eq 0 ]
}
