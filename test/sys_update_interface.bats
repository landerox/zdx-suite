#!/usr/bin/env bats
# Quoted programs are passed literally to the isolated Zsh process.
# shellcheck disable=SC2016

setup() {
  load test_helper
  export NVM_DIR="$HOME/nvm installation"
  mkdir -p "$NVM_DIR"
}

teardown() {
  cleanup_sandbox
}

@test "sys update interface: an unloaded nvm installation is annotated before selection" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/sys-menu.zsh"
    path=("$TEST_MOCK_BIN")
    command() {
      [[ "$1" == "-v" && ( "$2" == fnm || "$2" == nvm ) ]] && return 1
      builtin command "$@"
    }
    _sys_menu_entry "Update Node.js" update-node "Install the latest LTS release."
    sys-menu update-node
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"Update Node.js (missing: loaded nvm)"* ]]
  [[ "$output" == *"nvm is installed but is not loaded in this shell."* ]]
}

@test "sys update interface: nvm annotation changes when the existing installation is loaded" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/sys-menu.zsh"
    path=("$TEST_MOCK_BIN")
    command() {
      [[ "$1" == "-v" && "$2" == fnm ]] && return 1
      builtin command "$@"
    }
    nvm() {
      print -r -- unexpected >"$HOME/nvm.executed"
      return 97
    }
    _sys_menu_entry "Update Node.js" update-node "Install the latest LTS release."
    NVM_DIR="$HOME/missing nvm installation"
    _sys_menu_entry "Update Node.js" update-node "Install the latest LTS release."
  '

  [ "$status" -eq 0 ]
  [ "$output" = $'  Update Node.js|update-node|Install the latest LTS release.\n  Update Node.js (missing: fnm or nvm)|update-node|Install the latest LTS release.' ]
  [ ! -e "$HOME/nvm.executed" ]
}

@test "sys update interface: installed fnm satisfies Node readiness without executing it" {
  cat >"$TEST_MOCK_BIN/fnm" <<'EOF'
#!/usr/bin/env zsh
print -r -- unexpected >"$HOME/fnm.executed"
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/fnm"

  run run_zsh '
    source "$ZSH_CUSTOM/functions/sys-menu.zsh"
    path=("$TEST_MOCK_BIN")
    NVM_DIR="$HOME/missing nvm installation"
    _sys_menu_entry "Update Node.js" update-node "Install the latest LTS release."
  '

  [ "$status" -eq 0 ]
  [ "$output" = "  Update Node.js|update-node|Install the latest LTS release." ]
  [ ! -e "$HOME/fnm.executed" ]
}

@test "sys update interface: a shell function cannot substitute for external fnm" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/sys-menu.zsh"
    path=("$TEST_MOCK_BIN")
    NVM_DIR="$HOME/missing nvm installation"
    fnm() {
      print -r -- unexpected >"$HOME/fnm.executed"
      return 97
    }
    _sys_menu_entry "Update Node.js" update-node "Install the latest LTS release."
  '

  [ "$status" -eq 0 ]
  [ "$output" = "  Update Node.js (missing: fnm or nvm)|update-node|Install the latest LTS release." ]
  [ ! -e "$HOME/fnm.executed" ]
}
