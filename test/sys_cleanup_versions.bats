#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031
#
# clean-system targets for superseded tool versions: self-updating CLI release
# stores, AWS CLI v2 bundles, and nvm runtimes, plus the pre-commit cache.
# Every fixture lives below the sandbox HOME. Running executables come from a
# stub unless a test exercises the real collector, and aws resolves only to a
# fixture, so host processes and installations are never observed.

setup() {
  load test_helper
  export CLEAN_TOOL_LOG="$TEST_TEMP_DIR/clean-tools.log"
  : > "$CLEAN_TOOL_LOG"
  export CLEAN_RUNNING=""
}

teardown() {
  cleanup_sandbox
}

# Runs Zsh with the System suite on a Linux host without systemd or a package
# manager. Cleanup tools are hidden unless named in CLEAN_SHOW_TOOLS, and
# running executables are the colon-separated CLEAN_RUNNING paths.
run_cleanup_zsh() {
  run_zsh "
    source \"\$ZSH_CUSTOM/functions/sys-menu.zsh\" || return 98
    _SYS_CAPABILITIES=(
      architecture x86_64
      environment native
      os linux
      os_updates_backend unavailable
      package_manager unavailable
      ports_backend unavailable
      privilege sudo
      process_backend procps
      service_manager unavailable
      snapd unavailable
      wsl_interop unavailable
    )
    _SYS_CAPABILITIES_READY=1
    _sys_capabilities_refresh() { return 0; }
    command() {
      if [[ \"\${1:-}\" == -v ]]; then
        case \",\${CLEAN_SHOW_TOOLS:-},\" in
          *\",\${2:-},\"*) ;;
          *)
            case \"\${2:-}\" in
              apt-get|brew|npm|uv|pip|pip3|python3|cargo|rustup|go|snap|pre-commit|aws)
                return 1 ;;
            esac
            ;;
        esac
      fi
      builtin command \"\$@\"
    }
    sudo() {
      \"\$TEST_MOCK_BIN/sudo\" \"\$@\"
    }
    _sys_clean_running_executables() {
      reply=(\${(s.:.)CLEAN_RUNNING})
    }
    $1
  "
}

# Creates the Claude CLI layout: one file per version, the launcher link to
# the selected version, and modification times in the given order (oldest
# first) unless a version is listed after the selected one.
# Usage: make_claude_store <selected> <version>...
make_claude_store() {
  local selected="$1" version
  local -i minute=10
  shift
  local store="$HOME/.local/share/claude/versions"
  mkdir -p "$store" "$HOME/.local/bin"
  for version in "$@"; do
    printf '%s\n' "$version" > "$store/$version"
    touch -t "2026101012$minute" "$store/$version"
    (( minute += 1 ))
  done
  ln -sfn "$store/$selected" "$HOME/.local/bin/claude"
}

# Creates one Codex package with release directories (oldest first) and its
# current link to the selected release.
# Usage: make_codex_package <package> <selected> <release>...
make_codex_package() {
  local package="$HOME/.codex/packages/$1" selected="$2" release
  local -i minute=10
  shift 2
  mkdir -p "$package/releases"
  for release in "$@"; do
    mkdir -p "$package/releases/$release/bin"
    printf '#!/bin/sh\n' > "$package/releases/$release/bin/codex"
    touch -t "2026101012$minute" "$package/releases/$release"
    (( minute += 1 ))
  done
  ln -sfn "$package/releases/$selected" "$package/current"
}

# Creates nvm runtimes with npm and corepack plus the given global packages.
# Usage: make_nvm_runtime <version> [package...]
make_nvm_runtime() {
  local runtime="$HOME/.nvm/versions/node/$1" package
  shift
  mkdir -p "$runtime/bin" "$runtime/lib/node_modules/npm" \
    "$runtime/lib/node_modules/corepack" "$HOME/.nvm/alias"
  for package in "$@"; do
    mkdir -p "$runtime/lib/node_modules/$package"
  done
}

# Creates an AWS CLI v2 bundled-installer layout with the given versions and
# links aws, as the installer's bin directory does, to the active one.
# Usage: make_awscli <active> <version>...
make_awscli() {
  local v2="$TEST_TEMP_DIR/aws-cli/v2" active="$1" version
  shift
  for version in "$@"; do
    mkdir -p "$v2/$version/dist" "$v2/$version/bin"
    printf '#!/bin/sh\n' > "$v2/$version/dist/aws"
    chmod 755 "$v2/$version/dist/aws"
    ln -sfn ../dist/aws "$v2/$version/bin/aws"
  done
  ln -sfn "$v2/$active" "$v2/current"
  ln -sfn "$v2/current/bin/aws" "$TEST_MOCK_BIN/aws"
}

@test "sys cleanup versions: a release store keeps selected, newer, previous, locked, and running versions" {
  make_claude_store 2.1.303 2.1.290 2.1.293 2.1.295 2.1.298 2.1.300 2.1.303 2.1.304
  local store="$HOME/.local/share/claude/versions"
  export CLEAN_RUNNING="$store/2.1.298"

  run run_cleanup_zsh '
    mkdir -p "$HOME/.local/state/claude/locks"
    printf "{\n  \"pid\": %s,\n  \"version\": \"2.1.295\"\n}\n" "$$" \
      > "$HOME/.local/state/claude/locks/2.1.295.lock"
    printf "{\"pid\": 2147483646}\n" \
      > "$HOME/.local/state/claude/locks/2.1.290.lock"
    _sys_clean_plan quick
  '

  [ "$status" -eq 0 ]
  [ "$output" = "Claude CLI versions|$store|2.1.290 2.1.293" ]
}

@test "sys cleanup versions: clean-system removes only the planned superseded releases" {
  make_claude_store 2.1.303 2.1.290 2.1.293 2.1.300 2.1.303
  local store="$HOME/.local/share/claude/versions"

  run run_cleanup_zsh 'clean-system --quick --dry-run'

  [ "$status" -eq 0 ]
  [[ "$output" == *"Claude CLI versions"*"~/.local/share/claude/versions (superseded: 2.1.290, 2.1.293)"* ]]
  [ -f "$store/2.1.290" ]

  run run_cleanup_zsh 'clean-system --quick --yes'

  [ "$status" -eq 0 ]
  [ ! -e "$store/2.1.290" ]
  [ ! -e "$store/2.1.293" ]
  [ -f "$store/2.1.300" ]
  [ -f "$store/2.1.303" ]
  [[ "$output" == *"Removed: 2.1.290, 2.1.293"* ]]
  [[ "$output" == *"Claude CLI versions — done: 2 superseded versions removed"* ]]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "sys cleanup versions: Codex packages are planned with store-relative names" {
  make_codex_package standalone 0.162.0-x86 0.160.0-x86 0.161.0-x86 0.162.0-x86
  make_codex_package app-server-daemon 0.162.0-x86 0.161.0-x86 0.162.0-x86

  run run_cleanup_zsh '_sys_clean_plan quick'

  [ "$status" -eq 0 ]
  [ "$output" = "Codex releases|$HOME/.codex/packages|standalone/releases/0.160.0-x86" ]

  run run_cleanup_zsh 'clean-system --quick --yes'

  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.codex/packages/standalone/releases/0.160.0-x86" ]
  [ -d "$HOME/.codex/packages/standalone/releases/0.161.0-x86" ]
  [ -d "$HOME/.codex/packages/app-server-daemon/releases/0.161.0-x86" ]
  [[ "$output" == *"standalone/0.160.0-x86"* ]]
}

@test "sys cleanup versions: an undetermined or unsafe store is never pruned" {
  local store="$HOME/.local/share/cursor-agent/versions"
  mkdir -p "$store/2026.09.01-a" "$store/2026.09.15-b" "$store/2026.10.01-c"

  run run_cleanup_zsh '_sys_clean_plan quick'

  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping ~/.local/share/cursor-agent/versions: its active release could not be determined."* ]]
  [[ "$output" != *"Cursor Agent versions|"* ]]

  rm -rf "$HOME/.local/share/cursor-agent"
  mkdir -p "$TEST_TEMP_DIR/elsewhere/versions" "$HOME/.local/share/claude"
  ln -s "$TEST_TEMP_DIR/elsewhere/versions" "$HOME/.local/share/claude/versions"

  run run_cleanup_zsh '_sys_clean_plan quick'

  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping Claude CLI versions"*"is not a safe user-owned directory."* ]]
  [[ "$output" != *"Claude CLI versions|"* ]]
}

@test "sys cleanup versions: unknown running programs keep every older release" {
  make_claude_store 2.1.303 2.1.290 2.1.293 2.1.300 2.1.303

  run run_cleanup_zsh '
    _sys_clean_running_executables() { return 1; }
    _sys_clean_plan quick
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"running programs cannot be inspected on this host."* ]]
  [[ "$output" != *"Claude CLI versions|"* ]]
  [ -f "$HOME/.local/share/claude/versions/2.1.290" ]
}

@test "sys cleanup versions: execution revalidates every planned name" {
  make_claude_store 2.1.303 2.1.290 2.1.300 2.1.303
  local store="$HOME/.local/share/claude/versions"

  run run_cleanup_zsh "
    _sys_clean_step_claude_versions '$store|2.1.250 2.1.290 2.1.303'
  "

  [ "$status" -eq 1 ]
  [ ! -e "$store/2.1.290" ]
  [ -f "$store/2.1.303" ]
  [[ "$output" == *"2.1.303 is no longer superseded; it was kept."* ]]
  [[ "$output" == *"Some planned Claude CLI versions could not be removed."* ]]

  run run_cleanup_zsh "
    _sys_clean_step_claude_versions '$store|../2.1.300'
  "

  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid Claude CLI versions plan record."* ]]
  [ -f "$store/2.1.300" ]

  run run_cleanup_zsh "
    _sys_clean_step_claude_versions '$HOME/.local/share/claude|versions/2.1.300'
  "

  [ "$status" -eq 1 ]
  [[ "$output" == *"Claude CLI versions path changed after confirmation."* ]]
  [ -f "$store/2.1.300" ]
}

@test "sys cleanup versions: /proc reports this user's running executables" {
  [ -L /proc/self/exe ] || skip "this host has no /proc executable links"

  run run_zsh '
    source "$ZSH_CUSTOM/functions/sys-menu.zsh" || return 98
    local -a reply=()
    _sys_clean_running_executables || return 11
    (( ${reply[(Ie)${$(readlink /proc/$$/exe)% (deleted)}]} ))
  '

  [ "$status" -eq 0 ]
}

@test "sys cleanup versions: lsof reports running programs where /proc is unavailable" {
  cat <<'EOF' > "$TEST_MOCK_BIN/lsof"
#!/usr/bin/env bash
printf 'lsof %s\n' "$*" >> "$CLEAN_TOOL_LOG"
[[ "${CLEAN_LSOF_EMPTY:-0}" == 1 ]] && exit 1
printf '%s\n' p4242 ftxt n/opt/tools/2.1.290 p4243 ftxt n/usr/lib/libz.dylib
exit 1
EOF
  chmod +x "$TEST_MOCK_BIN/lsof"

  run run_zsh '
    source "$ZSH_CUSTOM/functions/sys-menu.zsh" || return 98
    _sys_clean_proc_exe_available() { return 1; }
    local -a reply=()
    _sys_clean_running_executables || return 11
    print -rl -- "${reply[@]}"
    export CLEAN_LSOF_EMPTY=1
    _sys_clean_running_executables && return 12
    unset CLEAN_LSOF_EMPTY
    PATH="$TEST_TEMP_DIR/no-tools" _sys_clean_running_executables && return 13
    return 0
  '

  [ "$status" -eq 0 ]
  [ "$output" = $'/opt/tools/2.1.290\n/usr/lib/libz.dylib' ]
  grep -q -- "-u $(id -u) -d txt -F n" "$CLEAN_TOOL_LOG"
}

@test "sys cleanup versions: AWS CLI bundles keep the active and running versions" {
  make_awscli 2.32.0 2.30.0 2.31.0 2.31.5 2.32.0
  local v2="$TEST_TEMP_DIR/aws-cli/v2"
  export CLEAN_SHOW_TOOLS=aws CLEAN_RUNNING="$v2/2.31.5/dist/aws"

  run run_cleanup_zsh '
    _sys_clean_trusted_directory_chain() { return 0; }
    _sys_clean_plan quick
  '

  [ "$status" -eq 0 ]
  [ "$output" = "AWS CLI bundles|$v2|2.30.0 2.31.0" ]

  run run_cleanup_zsh '
    _sys_clean_trusted_directory_chain() { return 0; }
    clean-system --quick --yes
  '

  [ "$status" -eq 0 ]
  [ ! -e "$v2/2.30.0" ]
  [ ! -e "$v2/2.31.0" ]
  [ -d "$v2/2.31.5" ]
  [ -d "$v2/2.32.0" ]
  [[ "$output" == *"AWS CLI bundles — done: 2 superseded versions removed, kept 2.32.0"* ]]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "sys cleanup versions: root-owned AWS CLI bundles are removed only through sudo" {
  [ "$(id -u)" -ne 0 ] || skip "root owns every fixture"
  make_awscli 2.32.0 2.30.0 2.32.0
  local v2="$TEST_TEMP_DIR/aws-cli/v2"
  export CLEAN_SHOW_TOOLS=aws MOCK_SUDO_ALLOW=rm

  run run_cleanup_zsh "
    _sys_clean_awscli_root() {
      REPLY='$v2'
      reply=(2.32.0 0)
    }
    _sys_clean_awscli_superseded() { reply=('$v2/2.30.0'); }
    clean-system --quick --yes
  "

  [ "$status" -eq 0 ]
  [ ! -e "$v2/2.30.0" ]
  [ -d "$v2/2.32.0" ]
  [[ "$output" == *"These steps run through sudo: AWS CLI bundles."* ]]
  [[ "$output" == *"Privileged operation: sudo rm -rf -- $v2/2.30.0"* ]]
  grep -q -- "rm -rf -- $v2/2.30.0" "$MOCK_SUDO_LOG"

  # A bundle owned unlike the root-owned v2 directory refuses the whole plan.
  make_awscli 2.32.0 2.30.0 2.32.0
  run run_cleanup_zsh "
    _sys_clean_awscli_root() {
      REPLY='$v2'
      reply=(2.32.0 0)
    }
    _sys_clean_plan quick
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping AWS CLI bundles: a bundle directory has an unexpected owner."* ]]
  [[ "$output" != *"AWS CLI bundles|"* ]]
  [ -d "$v2/2.30.0" ]
}

@test "sys cleanup versions: only the bundled AWS CLI layout below a trusted chain applies" {
  make_awscli 2.32.0 2.30.0 2.32.0
  export CLEAN_SHOW_TOOLS=aws

  # The sandbox lies below a world-writable or user-owned temporary root.
  mkdir -p "$TEST_TEMP_DIR/shared"
  chmod 775 "$TEST_TEMP_DIR/shared"
  mkdir -p "$TEST_TEMP_DIR/shared/aws-cli"
  ln -s "$TEST_TEMP_DIR/shared" "$TEST_TEMP_DIR/linked"

  run run_cleanup_zsh '
    _sys_clean_trusted_directory_chain /usr 0 || return 11
    _sys_clean_trusted_directory_chain "$TEST_TEMP_DIR/shared/aws-cli" "$EUID" \
      && return 12
    _sys_clean_trusted_directory_chain "$TEST_TEMP_DIR/linked" "$EUID" \
      && return 13
    _sys_clean_trusted_directory_chain relative/path 0 && return 14
    return 0
  '
  [ "$status" -eq 0 ]

  # Homebrew and other layouts never plan bundle removal.
  rm "$TEST_MOCK_BIN/aws"
  mkdir -p "$TEST_TEMP_DIR/Cellar/awscli/2.32.0/bin"
  printf '#!/bin/sh\n' > "$TEST_TEMP_DIR/Cellar/awscli/2.32.0/bin/aws"
  chmod 755 "$TEST_TEMP_DIR/Cellar/awscli/2.32.0/bin/aws"
  ln -s "$TEST_TEMP_DIR/Cellar/awscli/2.32.0/bin/aws" "$TEST_MOCK_BIN/aws"

  run run_cleanup_zsh '
    _sys_clean_trusted_directory_chain() { return 0; }
    _sys_clean_awscli_root && return 11
    _sys_clean_plan quick
  '

  [ "$status" -eq 0 ]
  [[ "$output" != *"AWS CLI bundles"* ]]
}

@test "sys cleanup versions: nvm keeps other lines, newer, aliased, and package-holding runtimes" {
  make_nvm_runtime v20.5.0
  make_nvm_runtime v22.0.0 cli-tool
  make_nvm_runtime v22.0.5
  make_nvm_runtime v22.0.7 only-old
  make_nvm_runtime v22.1.0 cli-tool @scope/agent
  make_nvm_runtime v22.2.0
  mkdir -p "$HOME/.nvm/alias/lts"
  printf '%s\n' v22.1.0 > "$HOME/.nvm/alias/default"
  printf '%s\n' v22.0.5 > "$HOME/.nvm/alias/work"
  printf '%s\n' v22.0.0 > "$HOME/.nvm/alias/lts/jod"

  run run_cleanup_zsh 'ZDX_VERBOSE=1 _sys_clean_plan quick'

  [ "$status" -eq 0 ]
  [[ "$output" == *"Node.js runtimes|$HOME/.nvm/versions/node|v22.0.0"* ]]
  [[ "$output" == *"Keeping v22.0.5: the nvm alias work selects it."* ]]
  [[ "$output" == *"Keeping v22.0.7: v22.1.0 lacks its global packages (only-old)."* ]]

  run run_cleanup_zsh 'clean-system --quick --yes'

  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.nvm/versions/node/v22.0.0" ]
  local kept
  for kept in v20.5.0 v22.0.5 v22.0.7 v22.1.0 v22.2.0; do
    [ -d "$HOME/.nvm/versions/node/$kept" ]
  done
  [[ "$output" == *"Node.js runtimes — done: 1 superseded runtime removed"* ]]
  [[ "$output" == *"Open shells that still use a planned Node.js runtime need nvm use default afterwards."* ]]
}

@test "sys cleanup versions: nvm keeps pinned, active, and running runtimes" {
  local project="$HOME/workspaces/github/me/app"
  mkdir -p "$project"
  make_nvm_runtime v22.0.0
  make_nvm_runtime v22.1.0
  printf '%s\n' v22.1.0 > "$HOME/.nvm/alias/default"

  printf '%s\n' 22.0 > "$project/.nvmrc"
  run run_cleanup_zsh 'ZDX_VERBOSE=1 _sys_clean_plan quick'
  [[ "$output" == *"Keeping v22.0.0: pinned by ~/workspaces/github/me/app/.nvmrc."* ]]
  [[ "$output" != *"Node.js runtimes|"* ]]

  rm "$project/.nvmrc"
  printf '%s\n' '{' '  "engines": { "node": ">=22.0.0" }' '}' > "$project/package.json"
  run run_cleanup_zsh 'ZDX_VERBOSE=1 _sys_clean_plan quick'
  [[ "$output" == *"pinned by ~/workspaces/github/me/app/package.json."* ]]

  # A major-only pin is satisfied by the default.
  rm "$project/package.json"
  printf '%s\n' 22 > "$project/.node-version"
  run run_cleanup_zsh '_sys_clean_plan quick'
  [ "$output" = "Node.js runtimes|$HOME/.nvm/versions/node|v22.0.0" ]

  run run_cleanup_zsh '
    path=("$HOME/.nvm/versions/node/v22.0.0/bin" $path)
    ZDX_VERBOSE=1 _sys_clean_plan quick
  '
  [[ "$output" == *"Keeping v22.0.0: this shell's PATH uses it."* ]]
  [[ "$output" != *"Node.js runtimes|"* ]]

  export CLEAN_RUNNING="$HOME/.nvm/versions/node/v22.0.0/bin/node"
  run run_cleanup_zsh '_sys_clean_plan quick'
  [ "$status" -eq 0 ]
  [[ "$output" != *"Node.js runtimes|"* ]]
  [ -d "$HOME/.nvm/versions/node/v22.0.0" ]
}

@test "sys cleanup versions: nvm needs a resolvable default version" {
  make_nvm_runtime v22.0.0
  make_nvm_runtime v22.1.0
  printf '%s\n' 'lts/*' > "$HOME/.nvm/alias/default"

  run run_cleanup_zsh 'ZDX_VERBOSE=1 _sys_clean_plan quick'

  [ "$status" -eq 0 ]
  [[ "$output" == *"the nvm default version could not be determined."* ]]
  [[ "$output" != *"Node.js runtimes|"* ]]

  run run_cleanup_zsh '
    nvm() {
      [[ "$*" == "version default" ]] || return 97
      print -r -- v22.1.0
    }
    _sys_clean_plan quick
  '

  [ "$status" -eq 0 ]
  [ "$output" = "Node.js runtimes|$HOME/.nvm/versions/node|v22.0.0" ]
}

@test "sys cleanup versions: pre-commit gc runs against the confirmed cache" {
  cat <<'EOF' > "$TEST_MOCK_BIN/pre-commit"
#!/usr/bin/env bash
printf 'PRE_COMMIT_HOME=%s %s\n' "${PRE_COMMIT_HOME:-unset}" "$*" >> "$CLEAN_TOOL_LOG"
EOF
  chmod +x "$TEST_MOCK_BIN/pre-commit"
  mkdir -p "$HOME/.cache/pre-commit" "$HOME/hooks-cache"
  export CLEAN_SHOW_TOOLS=pre-commit

  run run_cleanup_zsh 'clean-system --quick --yes'

  [ "$status" -eq 0 ]
  [ "$(cat "$CLEAN_TOOL_LOG")" = "PRE_COMMIT_HOME=$HOME/.cache/pre-commit gc" ]

  : > "$CLEAN_TOOL_LOG"
  run run_cleanup_zsh '
    export PRE_COMMIT_HOME="$HOME/hooks-cache"
    clean-system --quick --yes
  '

  [ "$status" -eq 0 ]
  [ "$(cat "$CLEAN_TOOL_LOG")" = "PRE_COMMIT_HOME=$HOME/hooks-cache gc" ]

  : > "$CLEAN_TOOL_LOG"
  run run_cleanup_zsh '
    export PRE_COMMIT_HOME="$TEST_TEMP_DIR/outside"
    _sys_clean_plan quick
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping pre-commit cache: its directory could not be resolved."* ]]
  [ ! -s "$CLEAN_TOOL_LOG" ]
}
