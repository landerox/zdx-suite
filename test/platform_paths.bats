#!/usr/bin/env bats
# shellcheck disable=SC2016
#
# Temporary roots reached through symbolic links. macOS exposes TMPDIR as
# /var/folders/... and /tmp through root-owned aliases of /private, so every
# check that compared the literal and canonical path refused it. These cases
# reproduce that layout on Linux with an alias owned by the test user, and a
# simulated root-owned alias, and prove every suite yields the canonical root.

setup() {
  load test_helper

  PLATFORM_PHYSICAL="$TEST_TEMP_DIR/physical"
  mkdir -m 700 "$PLATFORM_PHYSICAL" "$PLATFORM_PHYSICAL/tmp"
  ln -s "$PLATFORM_PHYSICAL" "$TEST_TEMP_DIR/alias"
  PLATFORM_CANONICAL=$(cd -P "$PLATFORM_PHYSICAL/tmp" && pwd -P)
  export PLATFORM_CANONICAL
  export PLATFORM_ALIAS_TMP="$TEST_TEMP_DIR/alias/tmp"
  export PLATFORM_PROBE="$TEST_TEMP_DIR/platform-probe.zsh"

  # Every suite-owned temporary-root check, one result line per suite.
  cat > "$PLATFORM_PROBE" <<'ZSH'
_platform_probe() {
  local label="$1"
  shift
  REPLY=""
  if "$@" >/dev/null 2>&1 && [[ -n "$REPLY" ]]; then
    print -r -- "$label=$REPLY"
  else
    print -r -- "$label=refused"
  fi
}

_platform_probe_all() {
  local REPLY="" root=""
  local -a reply=()
  _platform_probe zdx-core _zdx_capture_parent_safe
  _platform_probe zdx-menu _zdx_temp_parent_safe "$TMPDIR"
  _platform_probe env _env_validate_temp_parent "$TMPDIR"
  _platform_probe file _file_validate_temp_parent "$TMPDIR" "platform test"
  _platform_probe py _py_validate_temp_parent "$TMPDIR"
  _platform_probe git _git_temp_parent_safe "$TMPDIR"
  _platform_probe sys _sys_temp_parent_safe "$TMPDIR"
  _platform_probe dev _dev_temp_parent_safe "$TMPDIR"
  _platform_probe ws _ws_validate_temp_parent "$TMPDIR"
  if root=$(_vpn_temp_root_candidate "$TMPDIR" 2>/dev/null); then
    print -r -- "vpn=$root"
  else
    print -r -- "vpn=refused"
  fi
  if [[ "${PLATFORM_PROBE_WRITES:-1}" == 1 ]]; then
    if _dev_update_workspace_create >/dev/null 2>&1; then
      print -r -- "dev-workspace=${reply[1]}"
      _dev_update_workspace_cleanup "${reply[@]}" >/dev/null 2>&1 \
        || print -r -- "dev-workspace-cleanup=failed"
    else
      print -r -- "dev-workspace=refused"
    fi
    if _dev_pypi_cache_init >/dev/null 2>&1; then
      print -r -- "dev-pypi=$_DEV_PYPI_CACHE_ROOT"
      _dev_pypi_cache_cleanup >/dev/null 2>&1 \
        || print -r -- "dev-pypi-cleanup=failed"
    else
      print -r -- "dev-pypi=refused"
    fi
  fi
}

# A zstat wrapper that reports one exact path as owned by another UID. The
# override replaces only that path's uid in the caller's array.
_platform_fake_owner() {
  typeset -g PLATFORM_FAKE_PATH="$1" PLATFORM_FAKE_UID="$2"
  zstat() {
    builtin zstat "$@" || return
    local array_name="" argument="" previous=""
    for argument in "$@"; do
      [[ "$previous" == -*H ]] && array_name="$argument"
      previous="$argument"
    done
    [[ -n "$array_name" && "${@[-1]}" == "$PLATFORM_FAKE_PATH" ]] || return 0
    local -A observed=("${(@kvP)array_name}")
    observed[uid]="$PLATFORM_FAKE_UID"
    set -A "$array_name" "${(@kv)observed}"
  }
}
ZSH
}

teardown() {
  cleanup_sandbox
}

# Expected probe output: every label with the same value.
_platform_expect() {
  local value="$1"
  local label expected=""
  shift
  for label in "$@"; do
    expected+="$label=$value"$'\n'
  done
  printf '%s' "${expected%$'\n'}"
}

# stdout: uid:octal-mode of a path without following a final link.
_platform_owner_mode() {
  zsh -f -c '
    zmodload -F zsh/stat b:zstat || exit 1
    local -A state=()
    zstat -LH state -- "$1" 2>/dev/null || exit 1
    print -r -- "${state[uid]}:$(( [##8] state[mode] & 8#7777 ))"
  ' _ "$1"
}

# Succeeds when a directory has no entries.
_platform_empty_dir() {
  [ -z "$(ls -A "$1")" ]
}

_platform_labels=(zdx-core zdx-menu env file py git sys dev ws vpn \
  dev-workspace dev-pypi)

@test "platform paths: every suite resolves a TMPDIR behind an owned alias" {
  run run_zsh '
    source "$PLATFORM_PROBE" || return 90
    export TMPDIR="$PLATFORM_ALIAS_TMP"
    _platform_probe_all
  '

  [ "$status" -eq 0 ]
  [ "$output" = "$(_platform_expect "$PLATFORM_CANONICAL" "${_platform_labels[@]}")" ]
  _platform_empty_dir "$PLATFORM_CANONICAL"
}

@test "platform paths: trailing slashes resolve like the macOS TMPDIR value" {
  run run_zsh '
    source "$PLATFORM_PROBE" || return 90
    export TMPDIR="$PLATFORM_ALIAS_TMP/"
    _platform_probe_all
  '

  [ "$status" -eq 0 ]
  [ "$output" = "$(_platform_expect "$PLATFORM_CANONICAL" "${_platform_labels[@]}")" ]
}

@test "platform paths: a simulated root-owned final alias such as macOS /tmp is accepted" {
  ln -s "$PLATFORM_PHYSICAL/tmp" "$TEST_TEMP_DIR/system-tmp"
  run run_zsh '
    source "$PLATFORM_PROBE" || return 90
    zmodload -F zsh/stat b:zstat || return 91
    local -A root_state=()
    builtin zstat -LH root_state -- / || return 92
    _platform_fake_owner "$TEST_TEMP_DIR/system-tmp" "${root_state[uid]}"
    export TMPDIR="$TEST_TEMP_DIR/system-tmp"
    _platform_probe_all
  '

  [ "$status" -eq 0 ]
  [ "$output" = "$(_platform_expect "$PLATFORM_CANONICAL" "${_platform_labels[@]}")" ]
}

@test "platform paths: a real root-owned system alias resolves without writes" {
  [[ -L /var/lock ]] || skip "/var/lock is not a symbolic link on this host"
  local system_target
  system_target=$(cd -P /var/lock 2>/dev/null && pwd -P) \
    || skip "/var/lock does not resolve to a directory"
  [[ "$(_platform_owner_mode /var/lock)" == 0:* \
    && "$(_platform_owner_mode "$system_target")" == 0:1777 ]] \
    || skip "/var/lock is not a root-owned alias of a sticky shared root"
  export PLATFORM_PROBE_WRITES=0

  run run_zsh '
    source "$PLATFORM_PROBE" || return 90
    export TMPDIR=/var/lock
    _platform_probe_all
  '

  [ "$status" -eq 0 ]
  [ "$output" = "$(_platform_expect "$system_target" \
    zdx-core zdx-menu env file py git sys dev ws vpn)" ]
}

@test "platform paths: a TMPDIR that is itself an owned link is refused" {
  ln -s "$PLATFORM_PHYSICAL/tmp" "$TEST_TEMP_DIR/tmp-link"
  run run_zsh '
    source "$PLATFORM_PROBE" || return 90
    export TMPDIR="$TEST_TEMP_DIR/tmp-link"
    _platform_probe_all
  '

  [ "$status" -eq 0 ]
  [ "$output" = "$(_platform_expect refused "${_platform_labels[@]}")" ]
  _platform_empty_dir "$PLATFORM_CANONICAL"
}

@test "platform paths: an owned alias inside a group-writable directory is refused" {
  mkdir -m 770 "$TEST_TEMP_DIR/shared"
  ln -s "$PLATFORM_PHYSICAL" "$TEST_TEMP_DIR/shared/alias"
  run run_zsh '
    source "$PLATFORM_PROBE" || return 90
    export TMPDIR="$TEST_TEMP_DIR/shared/alias/tmp"
    _platform_probe_all
  '

  [ "$status" -eq 0 ]
  [ "$output" = "$(_platform_expect refused "${_platform_labels[@]}")" ]
}

@test "platform paths: a group-writable canonical root stays refused behind an alias" {
  mkdir -m 770 "$PLATFORM_PHYSICAL/group-tmp"
  run run_zsh '
    source "$PLATFORM_PROBE" || return 90
    export TMPDIR="$TEST_TEMP_DIR/alias/group-tmp"
    _platform_probe_all
  '

  [ "$status" -eq 0 ]
  [ "$output" = "$(_platform_expect refused "${_platform_labels[@]}")" ]
  _platform_empty_dir "$PLATFORM_PHYSICAL/group-tmp"
}

@test "platform paths: a foreign-owned canonical root stays refused behind an alias" {
  mkdir -m 700 "$PLATFORM_PHYSICAL/foreign-tmp"
  local foreign_canonical
  foreign_canonical=$(cd -P "$PLATFORM_PHYSICAL/foreign-tmp" && pwd -P)
  export PLATFORM_FOREIGN_CANONICAL="$foreign_canonical"
  run run_zsh '
    source "$PLATFORM_PROBE" || return 90
    zmodload -F zsh/stat b:zstat || return 91
    _platform_fake_owner "$PLATFORM_FOREIGN_CANONICAL" "$(( EUID + 4242 ))"
    export TMPDIR="$TEST_TEMP_DIR/alias/foreign-tmp"
    _platform_probe_all
  '

  [ "$status" -eq 0 ]
  [ "$output" = "$(_platform_expect refused "${_platform_labels[@]}")" ]
  _platform_empty_dir "$foreign_canonical"
}

@test "platform paths: a non-normalized TMPDIR is refused before resolution" {
  run run_zsh '
    source "$PLATFORM_PROBE" || return 90
    export TMPDIR="$TEST_TEMP_DIR/alias/../physical/tmp"
    _platform_probe_all
  '

  [ "$status" -eq 0 ]
  [ "$output" = "$(_platform_expect refused "${_platform_labels[@]}")" ]
}

@test "platform paths: real pickers and staging work below an aliased TMPDIR" {
  export MOCK_FZF_MODE=response
  export MOCK_FZF_RESPONSE=picked
  run run_zsh '
    export TMPDIR="$PLATFORM_ALIAS_TMP"
    local capture="" REPLY=""
    local -i capture_rc=0
    for capture in _zdx_fzf_capture _env_fzf_capture _file_fzf_capture \
      _py_fzf_capture _git_fzf_capture _sys_fzf_capture _dev_fzf_capture; do
      REPLY=""
      capture_rc=0
      "$capture" </dev/null >/dev/null 2>&1 || capture_rc=$?
      print -r -- "$capture=$capture_rc:$REPLY"
    done
    if _vpn_preview_dir_init >/dev/null 2>&1; then
      print -r -- "vpn-preview=${_VPN_PREVIEW_DIR:h}"
      _vpn_preview_dir_cleanup >/dev/null 2>&1
    else
      print -r -- "vpn-preview=refused"
    fi
    _zdx_run_captured "platform check" "" "" true 2>/dev/null
    print -r -- "zdx-run-captured=$?"
  '

  [ "$status" -eq 0 ]
  local expected
  expected=$(printf '%s=0:picked\n' _zdx_fzf_capture _env_fzf_capture \
    _file_fzf_capture _py_fzf_capture _git_fzf_capture _sys_fzf_capture \
    _dev_fzf_capture)
  expected+=$'\n'"vpn-preview=$PLATFORM_CANONICAL"$'\n'"zdx-run-captured=0"
  [ "$output" = "$expected" ]
  _platform_empty_dir "$PLATFORM_CANONICAL"
}

@test "platform paths: every private resolver copy matches the core rule" {
  run zsh -f -c '
    source "$1/functions/zdx-common.zsh" || exit 90
    print -r -- "${functions[_zdx_resolve_trusted_dir]}"
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  local standalone_fallback="$output"

  run run_zsh '
    local core="${functions[_zdx_resolve_trusted_dir]}" name=""
    [[ -n "$core" ]] || return 90
    for name in _env_resolve_trusted_dir _file_resolve_trusted_dir \
      _py_resolve_trusted_dir _git_resolve_trusted_dir \
      _sys_resolve_trusted_dir _dev_resolve_trusted_dir \
      _vpn_resolve_trusted_dir _ws_resolve_trusted_dir; do
      [[ "${functions[$name]}" == "$core" ]] || print -r -- "drift: $name"
    done
    print -r -- "$core"
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *"drift:"* ]]
  [ "$output" = "$standalone_fallback" ]
}

# A File and Python project below the physical directory, with junk, a
# validated environment, and an archive input.
_platform_project() {
  PLATFORM_PROJECT="$PLATFORM_PHYSICAL/project"
  mkdir -m 700 "$PLATFORM_PROJECT"
  mkdir -p "$PLATFORM_PROJECT/.venv"
  printf '%s\n' "version = 3.12.1" > "$PLATFORM_PROJECT/.venv/pyvenv.cfg"
  printf '%s\n' junk > "$PLATFORM_PROJECT/.DS_Store"
  printf '%s\n' notes > "$PLATFORM_PROJECT/notes.txt"
  PLATFORM_PROJECT_CANONICAL=$(cd -P "$PLATFORM_PROJECT" && pwd -P)
  export PLATFORM_PROJECT PLATFORM_PROJECT_CANONICAL
}

@test "platform paths: File and Python operation bases behind an owned alias are canonical" {
  _platform_project
  run run_zsh '
    cd "$TEST_TEMP_DIR/alias/project" || return 90
    [[ "$PWD" == "$TEST_TEMP_DIR/alias/project" ]] || return 91
    NO_COLOR=1 file-clean-junk --dry-run || return 92
    file-compress --format tar.gz --output notes.tar.gz --yes -- notes.txt \
      >/dev/null 2>&1 || return 93
    file-compress --format tar.gz --output "$PWD/alias-path.tar.gz" --yes \
      -- "$PWD/notes.txt" >/dev/null 2>&1 || return 94
    NO_COLOR=1 venv-list || return 95
    venv-info --path .venv >/dev/null 2>&1 || return 96
    venv-info --path "$PWD/.venv" >/dev/null 2>&1 || return 97
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"Directory:"*"$PLATFORM_PROJECT_CANONICAL"* ]]
  [[ "$output" == *"1  .DS_Store"* ]]
  [[ "$output" == *"Project:"*"$PLATFORM_PROJECT_CANONICAL"* ]]
  [[ "$output" == *".venv"*"3.12.1"*"inactive"* ]]
  [ -f "$PLATFORM_PROJECT/notes.tar.gz" ]
  [ -f "$PLATFORM_PROJECT/alias-path.tar.gz" ]
  [ -f "$PLATFORM_PROJECT/.DS_Store" ]
}

@test "platform paths: a simulated root-owned alias such as macOS /tmp reaches a project" {
  _platform_project
  ln -s "$PLATFORM_PHYSICAL" "$TEST_TEMP_DIR/system-alias"
  run run_zsh '
    source "$PLATFORM_PROBE" || return 90
    zmodload -F zsh/stat b:zstat || return 91
    local -A root_state=()
    builtin zstat -LH root_state -- / || return 92
    _platform_fake_owner "$TEST_TEMP_DIR/system-alias" "${root_state[uid]}"
    cd "$TEST_TEMP_DIR/system-alias/project" || return 93
    file-clean-junk --yes || return 94
    venv-list
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"Deletion completed: 1 file deleted."* ]]
  [[ "$output" == *".venv"* ]]
  [ ! -e "$PLATFORM_PROJECT/.DS_Store" ]
}

@test "platform paths: a working directory that is an owned link stays refused" {
  _platform_project
  ln -s "$PLATFORM_PROJECT" "$TEST_TEMP_DIR/project-link"
  mkdir -m 770 "$TEST_TEMP_DIR/shared"
  ln -s "$PLATFORM_PHYSICAL" "$TEST_TEMP_DIR/shared/alias"

  for working_directory in "$TEST_TEMP_DIR/project-link" \
    "$TEST_TEMP_DIR/shared/alias/project"; do
    export PLATFORM_WORKDIR="$working_directory"
    run run_zsh 'cd "$PLATFORM_WORKDIR" && file-clean-junk --yes'
    [ "$status" -eq 1 ]
    [[ "$output" == *"reached without untrusted symbolic links"* ]]

    run run_zsh 'cd "$PLATFORM_WORKDIR" && venv-list'
    [ "$status" -eq 1 ]
    [[ "$output" == *"The project directory must be owned, reached without untrusted symbolic links"* ]]
  done
  [ -f "$PLATFORM_PROJECT/.DS_Store" ]
}
