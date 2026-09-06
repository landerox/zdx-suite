#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper

  export MAINT_PROBE_LOG="$TEST_TEMP_DIR/maintenance-probes.log"
  export MAINT_MUTATION_LOG="$TEST_TEMP_DIR/maintenance-mutations.log"
  export MAINT_NETWORK_LOG="$TEST_TEMP_DIR/maintenance-network.log"
  export MAINT_SHELL_LOG="$TEST_TEMP_DIR/maintenance-shell.log"
  export MAINT_SIGNAL_LOG="$TEST_TEMP_DIR/maintenance-signals.log"
  export MAINT_PLATFORM_LOG="$TEST_TEMP_DIR/maintenance-platform.log"
  export APT_ENV_LOG="$TEST_TEMP_DIR/apt-env.log"
  : > "$MAINT_PROBE_LOG"
  : > "$MAINT_MUTATION_LOG"
  : > "$MAINT_NETWORK_LOG"
  : > "$MAINT_SHELL_LOG"
  : > "$MAINT_SIGNAL_LOG"
  : > "$MAINT_PLATFORM_LOG"
  : > "$APT_ENV_LOG"

  export MOCK_APT_LOCKED=0
  export MOCK_APT_FAIL_OPERATION=""
  export MOCK_BREW_LOCKED=0

  local network_client
  for network_client in curl wget; do
    cat <<'EOF' > "$TEST_MOCK_BIN/$network_client"
#!/usr/bin/env bash
{
  printf '%s' "${0##*/}"
  printf ' %q' "$@"
  printf '\n'
} >> "$MAINT_NETWORK_LOG"
exit 97
EOF
    chmod +x "$TEST_MOCK_BIN/$network_client"
  done

  cat <<'EOF' > "$TEST_MOCK_BIN/sh"
#!/usr/bin/env bash
{
  printf 'sh'
  printf ' %q' "$@"
  printf '\n'
} >> "$MAINT_SHELL_LOG"
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/sh"

  cat <<'EOF' > "$TEST_MOCK_BIN/docker"
#!/usr/bin/env bash
{
  printf 'docker'
  printf ' %q' "$@"
  printf '\n'
} >> "$MAINT_MUTATION_LOG"
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/docker"

cat <<'EOF' > "$TEST_MOCK_BIN/kill"
#!/usr/bin/env bash
{
  printf 'kill'
  printf ' %q' "$@"
  printf '\n'
} >> "$MAINT_SIGNAL_LOG"
if [[ "${MOCK_KILL_ALLOW_TERM:-0}" == "1" \
  && "$*" == "-s TERM -- 4242" ]]; then
  exit 0
fi
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/kill"

  cat <<'EOF' > "$TEST_MOCK_BIN/apt-get"
#!/usr/bin/env bash
{
  printf 'apt-get'
  printf ' %q' "$@"
  printf '\n'
} >> "$MAINT_PROBE_LOG"

if IFS= read -r unexpected_input; then
  printf 'apt-unexpected-stdin:%s\n' "$unexpected_input" \
    >> "$MAINT_MUTATION_LOG"
  exit 98
fi

if [[ "${DEBIAN_FRONTEND:-}" != "noninteractive" \
  || "${APT_LISTCHANGES_FRONTEND:-}" != "none" \
  || -n "${APT_CONFIG+x}" \
  || -n "${http_proxy+x}" \
  || -n "${HTTP_PROXY+x}" \
  || -n "${https_proxy+x}" \
  || -n "${HTTPS_PROXY+x}" ]] \
  || /usr/bin/env | /usr/bin/grep -q '^BASH_FUNC_'; then
  printf '%s\n' 'apt-unsafe-environment' >> "$MAINT_MUTATION_LOG"
  exit 98
fi

if [[ " $* " == *" -s "* && " $* " == *" full-upgrade "* ]]; then
  printf '%s\n' \
    'Inst zdx-example [1.0] (1.1 stable [amd64])' \
    'Conf zdx-example (1.1 stable [amd64])'
  exit 0
fi

{
  printf 'apt-get'
  printf ' %q' "$@"
  printf '\n'
} >> "$MAINT_MUTATION_LOG"
if [[ -n "${MOCK_APT_FAIL_OPERATION:-}" \
  && " $* " == *" ${MOCK_APT_FAIL_OPERATION} "* ]]; then
  exit 97
fi
[[ "${MOCK_APT_MUTATIONS_SUCCEED:-0}" == "1" ]] && exit 0
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/apt-get"

  cat <<'EOF' > "$TEST_MOCK_BIN/env"
#!/usr/bin/env bash
set -u

args=("$@")
if [[ "${args[0]:-}" == "-i" ]]; then
  index=1
  while (( index < ${#args[@]} )) && [[ "${args[index]}" == *=* ]]; do
    ((index += 1))
  done
  payload="${args[index]:-}"
  case "${payload##*/}" in
    apt-config|apt-get|dpkg|dpkg-query|trusted-apt-config)
      {
        printf '%s' "$0"
        printf ' %q' "$@"
        printf '\n'
      } >> "$APT_ENV_LOG"
      assignments=("${args[@]:1:index - 1}")
      exec /usr/bin/env -i "${assignments[@]}" \
        PATH="$TEST_MOCK_BIN:/usr/sbin:/usr/bin:/sbin:/bin" \
        TEST_MOCK_BIN="$TEST_MOCK_BIN" \
        APT_ENV_LOG="$APT_ENV_LOG" \
        MAINT_PROBE_LOG="$MAINT_PROBE_LOG" \
        MAINT_MUTATION_LOG="$MAINT_MUTATION_LOG" \
        MOCK_APT_FAIL_OPERATION="${MOCK_APT_FAIL_OPERATION:-}" \
        MOCK_APT_MUTATIONS_SUCCEED="${MOCK_APT_MUTATIONS_SUCCEED:-0}" \
        MOCK_APT_CONFIG_MODE="${MOCK_APT_CONFIG_MODE:-unset}" \
        MOCK_DPKG_STATUS="${MOCK_DPKG_STATUS:-install}" \
        MOCK_DPKG_QUERY_MODE="${MOCK_DPKG_QUERY_MODE:-valid}" \
        MOCK_UNATTENDED_VERSION="${MOCK_UNATTENDED_VERSION:-0.95}" \
        "${args[@]:index}"
      ;;
  esac
fi
exec /usr/bin/env "$@"
EOF
  chmod +x "$TEST_MOCK_BIN/env"

  cat <<'EOF' > "$TEST_MOCK_BIN/apt-config"
#!/usr/bin/env bash
{
  printf 'apt-config'
  printf ' %q' "$@"
  printf '\n'
} >> "$MAINT_PROBE_LOG"
if IFS= read -r unexpected_input; then
  printf 'apt-config-unexpected-stdin:%s\n' "$unexpected_input" \
    >> "$MAINT_MUTATION_LOG"
  exit 98
fi
if [[ -n "${APT_CONFIG+x}" \
  || -n "${http_proxy+x}" \
  || -n "${HTTP_PROXY+x}" ]] \
  || /usr/bin/env | /usr/bin/grep -q '^BASH_FUNC_'; then
  printf '%s\n' 'apt-config-unsafe-environment' \
    >> "$MAINT_MUTATION_LOG"
  exit 98
fi
[[ "${1:-}" == "shell" && $# -eq 3 ]] || exit 97
case "${MOCK_APT_CONFIG_MODE:-unset}" in
  unset) ;;
  true|false)
    printf "%s='%s'\n" "$2" "$MOCK_APT_CONFIG_MODE"
    ;;
  primary-true)
    if [[ "$2" == "ZdxMinimalSteps" ]]; then
      printf "%s='true'\n" "$2"
    fi
    ;;
  compat-true)
    if [[ "$2" == "ZdxMinimalStepsCompat" ]]; then
      printf "%s='true'\n" "$2"
    fi
    ;;
  primary-false)
    if [[ "$2" == "ZdxMinimalSteps" ]]; then
      printf "%s='false'\n" "$2"
    fi
    ;;
  malformed)
    printf '%s\n' 'malformed apt-config record'
    ;;
  *) exit 97 ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/apt-config"

  cat <<'EOF' > "$TEST_MOCK_BIN/dpkg"
#!/usr/bin/env bash
if IFS= read -r unexpected_input; then
  printf 'dpkg-unexpected-stdin:%s\n' "$unexpected_input" \
    >> "$MAINT_MUTATION_LOG"
  exit 98
fi
if [[ -n "${APT_CONFIG+x}" \
  || -n "${http_proxy+x}" \
  || -n "${HTTP_PROXY+x}" ]] \
  || /usr/bin/env | /usr/bin/grep -q '^BASH_FUNC_'; then
  printf '%s\n' 'dpkg-unsafe-environment'
  exit 0
fi
case "${1:-}" in
  --audit)
    [[ $# -eq 1 ]]
    ;;
  --compare-versions)
    [[ $# -eq 4 ]] || exit 97
    exec /usr/bin/dpkg --compare-versions "$2" "$3" "$4"
    ;;
  *)
    exit 97
    ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/dpkg"

  cat <<'EOF' > "$TEST_MOCK_BIN/dpkg-query"
#!/usr/bin/env bash
if IFS= read -r unexpected_input; then
  printf 'dpkg-query-unexpected-stdin:%s\n' "$unexpected_input" \
    >> "$MAINT_MUTATION_LOG"
  exit 98
fi
if [[ -n "${APT_CONFIG+x}" \
  || -n "${http_proxy+x}" \
  || -n "${HTTP_PROXY+x}" ]] \
  || /usr/bin/env | /usr/bin/grep -q '^BASH_FUNC_'; then
  printf '%s\n' 'dpkg-query-unsafe-environment' \
    >> "$MAINT_MUTATION_LOG"
  exit 98
fi
[[ "${1:-}" == "--show" \
  && "${2:-}" == '--showformat=${Status}\t${Version}\n' \
  && "${3:-}" == "unattended-upgrades" \
  && $# -eq 3 ]] || exit 97
case "${MOCK_DPKG_QUERY_MODE:-valid}" in
  valid)
    printf '%s ok installed\t%s\n' \
      "${MOCK_DPKG_STATUS:-install}" \
      "${MOCK_UNATTENDED_VERSION:-0.95}"
    ;;
  malformed)
    printf '%s\n' 'deinstall ok config-files 0.95'
    ;;
  error)
    exit 73
    ;;
  *)
    exit 97
    ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/dpkg-query"

  cat <<'EOF' > "$TEST_MOCK_BIN/hermes"
#!/usr/bin/env bash
{
  printf 'hermes'
  printf ' %q' "$@"
  printf '\n'
} >> "$MAINT_PROBE_LOG"

if [[ "${1:-}" == "version" ]]; then
  printf '%s\n' 'Hermes 1.2.3'
  exit 0
fi

{
  printf 'hermes'
  printf ' %q' "$@"
  printf '\n'
} >> "$MAINT_MUTATION_LOG"
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/hermes"

  cat <<'EOF' > "$TEST_MOCK_BIN/starship"
#!/usr/bin/env bash
printf 'starship %s\n' "$*" >> "$MAINT_PROBE_LOG"
printf '%s\n' 'starship 1.2.3'
EOF
  chmod +x "$TEST_MOCK_BIN/starship"

  cat <<'EOF' > "$TEST_MOCK_BIN/ps"
#!/usr/bin/env bash
{
  printf 'ps'
  printf ' %q' "$@"
  printf '\n'
} >> "$MAINT_PROBE_LOG"

case " $* " in
  *" -o comm= "*) printf '%s\n' 'apt-get' ;;
  *" -o args= "*) printf '%s\n' 'brew update' ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/ps"

  local platform_backend
  for platform_backend in dnf pacman zypper apk softwareupdate; do
    cat <<'EOF' > "$TEST_MOCK_BIN/$platform_backend"
#!/usr/bin/env bash
set -u

backend="${0##*/}"
{
  printf '%s' "$backend"
  printf ' %q' "$@"
  printf '\n'
} >> "$MAINT_PLATFORM_LOG"

case "$backend" in
  dnf)
    if [[ "$*" == "--setopt=exit_on_lock=True --setopt=retries=1 -q check-update" ]]; then
      printf '%s\n' 'zdx-example.x86_64 1.1 updates'
      exit 100
    fi
    ;;
  pacman)
    if [[ "$*" == "-Qu" ]]; then
      printf '%s\n' 'zdx-example 1.0 -> 1.1'
      exit 1
    fi
    ;;
  zypper)
    if [[ "$*" == "--non-interactive list-updates" ]]; then
      printf '%s\n' 'zdx-example | 1.1 | x86_64'
      exit 100
    fi
    ;;
  apk)
    if [[ "$*" == "version -l <" ]]; then
      printf '%s\n' 'zdx-example-1.0 < 1.1'
      exit 0
    fi
    ;;
  softwareupdate)
    if [[ "$*" == "--list" ]]; then
      printf '%s\n' '* Label: ZDX Example 1.1'
      exit 0
    fi
    ;;
esac

exit 0
EOF
    chmod +x "$TEST_MOCK_BIN/$platform_backend"
  done
}

teardown() {
  cleanup_sandbox
}

run_maintenance_zsh() {
  local command_text="$1"
  local package_backend="${2:-unavailable}"
  local service_backend="${3:-unavailable}"
  local os_backend="${4:-linux}"
  local os_updates_backend="unavailable"
  [[ "$os_backend" == "darwin" ]] && os_updates_backend="softwareupdate"

  run_zsh "
    source \"\$ZSH_CUSTOM/functions/sys-menu.zsh\" || return 98
    _SYS_CAPABILITIES=(
      architecture x86_64
      environment native
      fonts_backend unavailable
      os '$os_backend'
      os_updates_backend '$os_updates_backend'
      package_manager '$package_backend'
      ports_backend unavailable
      privilege sudo
      process_backend procps
      service_manager '$service_backend'
      snapd unavailable
      wsl_interop unavailable
    )
    _SYS_CAPABILITIES_READY=1
    _sys_capabilities_refresh() { return 0; }
    command() {
      if [[ "\${1:-}" == "-v" && "\${2:-}" == "sudo" ]]; then
        print -r -- "\$TEST_MOCK_BIN/sudo"
        return 0
      fi
      if [[ "\${1:-}" == "sudo" ]]; then
        shift
        "\$TEST_MOCK_BIN/sudo" "\$@"
        return \$?
      fi
      builtin command "\$@"
    }
    sudo() {
      "\$TEST_MOCK_BIN/sudo" "\$@"
    }
    _test_ai_result_report() {
      local default_outcome="\${1:-skipped}"
      local default_reason="\${2:-not-installed}"
      local default_rc="\${3:-0}"
      local exception_id="\${4:-}"
      local exception_outcome="\${5:-}"
      local exception_reason="\${6:-}"
      local exception_rc="\${7:-}"
      local -a ids=(
        claude codex antigravity opencode cursor copilot amp hermes
      )
      local -A labels=(
        claude 'Claude Code'
        codex 'Codex CLI'
        antigravity 'Antigravity CLI'
        opencode 'OpenCode'
        cursor 'Cursor Agent'
        copilot 'GitHub Copilot CLI'
        amp 'Amp CLI'
        hermes 'Hermes Agent'
      )
      local tab=\$'\\t'
      local id outcome reason result_rc
      for id in "\${ids[@]}"; do
        outcome="\$default_outcome"
        reason="\$default_reason"
        result_rc="\$default_rc"
        if [[ "\$id" == "\$exception_id" ]]; then
          outcome="\$exception_outcome"
          reason="\$exception_reason"
          result_rc="\$exception_rc"
        fi
        print -r -- \
          "ai-update-result-v1\${tab}\$id\${tab}\${labels[\$id]}\${tab}\$outcome\${tab}\$reason\${tab}\$result_rc"
      done
    }
    if [[ '$package_backend' == apt ]]; then
      _sys_update_resolve_trusted_program() {
        case "\$1" in
          apt-config|dpkg|dpkg-query|env)
            REPLY="\$TEST_MOCK_BIN/\$1"
            ;;
          *)
            return 97
            ;;
        esac
      }
    fi
    $command_text
  "
}

create_maintenance_git_repo() {
  local repository="$1"
  local origin="${2-https://example.invalid/zdx-test.git}"

  mkdir -p "$repository"
  git -C "$repository" init --quiet
  git -C "$repository" \
    -c user.name='ZDX Test' \
    -c user.email='zdx-test@example.invalid' \
    commit --allow-empty --quiet -m 'test: initialize repository'
  if [[ -n "$origin" ]]; then
    git -C "$repository" remote add origin "$origin"
  fi
}

assert_no_privilege_network_or_signal() {
  [ ! -s "$MOCK_SUDO_LOG" ]
  [ ! -s "$MAINT_NETWORK_LOG" ]
  [ ! -s "$MAINT_SHELL_LOG" ]
  [ ! -s "$MAINT_SIGNAL_LOG" ]
}

expected_apt_call() {
  printf '%s' \
    'apt-get -o Acquire::Retries=0 -o DPkg::Lock::Timeout=0' \
    ' -o Dpkg::Use-Pty=0' \
    ' -o Dpkg::Options::=--force-confdef' \
    ' -o Dpkg::Options::=--force-confold'
  local argument
  for argument in "$@"; do
    printf ' %s' "$argument"
  done
  [[ "${1:-}" != update ]] || printf ' --error-on=any'
}

expected_apt_environment_prefix() {
  printf '%s' \
    "$TEST_MOCK_BIN/env -i HOME=/nonexistent" \
    ' XDG_CACHE_HOME=/nonexistent XDG_CONFIG_HOME=/nonexistent' \
    ' XDG_DATA_HOME=/nonexistent LC_ALL=C' \
    ' PATH=/usr/sbin:/usr/bin:/sbin:/bin TERM=dumb' \
    ' DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none'
}

expected_apt_env_call() {
  expected_apt_environment_prefix
  printf ' '
  expected_apt_call "$@"
}

expected_phased_apt_call() {
  expected_apt_call
  printf '%s' ' -o APT::Get::Always-Include-Phased-Updates=true'
  local argument
  for argument in "$@"; do
    printf ' %s' "$argument"
  done
  [[ "${1:-}" != update ]] || printf ' --error-on=any'
}

expected_phased_apt_env_call() {
  expected_apt_environment_prefix
  printf ' '
  expected_phased_apt_call "$@"
}

expected_sudo_apt_call() {
  printf 'sudo -n '
  expected_apt_env_call "$@"
}

expected_dpkg_audit_call() {
  printf '%s' \
    "$TEST_MOCK_BIN/env -i HOME=/nonexistent LC_ALL=C" \
    ' PATH=/usr/sbin:/usr/bin:/sbin:/bin TERM=dumb ' \
    "$TEST_MOCK_BIN/dpkg --audit"
}

@test "sys maintenance: aggregate update dry-run has no side effects" {
  run run_maintenance_zsh '
    _sys_step_applies() {
      case "$1" in
        update-uv-system|update-fzf|update-omz|update-zsh-plugins|_sys_update_ai_tools)
          return 0 ;;
        *) return 1 ;;
      esac
    }
    update-system --dry-run --yes --safe-only
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"System Update Plan"* ]]
  [[ "$output" != *"AI assistants"* ]]
  [[ "$output" != *"Oh My Zsh"* ]]
  [[ "$output" != *"Zsh Plugins"* ]]
  [[ "$output" != *"fzf"* ]]
  [ ! -s "$MAINT_MUTATION_LOG" ]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: APT dry-run only calculates the upgrade plan" {
  run run_maintenance_zsh "update-apt --dry-run --yes" apt

  [ "$status" -eq 0 ]
  grep -Fq -- '-o DPkg::Lock::Timeout=0' "$MAINT_PROBE_LOG"
  grep -Fq -- '-o Acquire::Retries=0' "$MAINT_PROBE_LOG"
  grep -Fq -- '-o Dpkg::Use-Pty=0' "$MAINT_PROBE_LOG"
  grep -Fq -- '-o Dpkg::Options::=--force-confdef' "$MAINT_PROBE_LOG"
  grep -Fq -- '-o Dpkg::Options::=--force-confold' "$MAINT_PROBE_LOG"
  grep -Fq -- '-s full-upgrade' "$MAINT_PROBE_LOG"
  [ "$(cat "$APT_ENV_LOG")" = \
    "$(expected_apt_env_call -s full-upgrade)" ]
  [[ "$(cat "$APT_ENV_LOG")" != \
    *"APT::Get::Always-Include-Phased-Updates"* ]]
  [ ! -s "$MAINT_MUTATION_LOG" ]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: APT uses no-wait and no-retry options for every apt-get call" {
  export MOCK_APT_MUTATIONS_SUCCEED=1
  export MOCK_SUDO_ALLOW="true,__validate__,apt-get,env"

  run run_maintenance_zsh '
    _sys_package_manager_busy() { return 1; }
    _sys_apt_dpkg_state_clean() { return 0; }
    update-apt --yes
  ' apt

  [ "$status" -eq 0 ]
  [ "$(wc -l < "$MAINT_PROBE_LOG")" -eq 4 ]
  while IFS= read -r apt_call; do
    [[ "$apt_call" == *'-o DPkg::Lock::Timeout=0'* ]]
    [[ "$apt_call" == *'-o Acquire::Retries=0'* ]]
    [[ "$apt_call" == *'-o Dpkg::Use-Pty=0'* ]]
    [[ "$apt_call" == *'-o Dpkg::Options::=--force-confdef'* ]]
    [[ "$apt_call" == *'-o Dpkg::Options::=--force-confold'* ]]
  done < "$MAINT_PROBE_LOG"
  grep -Fq -- '-s full-upgrade' "$MAINT_PROBE_LOG"
  grep -Eq -- 'apt-get .* update --error-on=any$' "$MAINT_PROBE_LOG"
  grep -Eq -- 'apt-get .* full-upgrade -y$' "$MAINT_PROBE_LOG"
  grep -Eq -- 'apt-get .* autoremove -y$' "$MAINT_PROBE_LOG"
  local expected_environment_log
  expected_environment_log=$(expected_apt_env_call -s full-upgrade)
  expected_environment_log+=$'\n'
  expected_environment_log+="$(expected_apt_env_call update)"
  expected_environment_log+=$'\n'
  expected_environment_log+="$(expected_apt_env_call full-upgrade -y)"
  expected_environment_log+=$'\n'
  expected_environment_log+="$(expected_apt_env_call autoremove -y)"
  [ "$(cat "$APT_ENV_LOG")" = "$expected_environment_log" ]
  [[ "$output" == *"Privileged operation: sudo -n apt-get update"* ]]
  [[ "$output" == *"Privileged operation: sudo -n apt-get full-upgrade -y"* ]]
  [[ "$output" == *"Privileged operation: sudo -n apt-get autoremove -y"* ]]
  [[ "$output" != *"Full invocation:"* ]]
  [[ "$output" != *"XDG_CACHE_HOME=/nonexistent"* ]]
}

@test "sys maintenance: verbose APT output reveals the complete isolated invocations" {
  export MOCK_APT_MUTATIONS_SUCCEED=1
  export MOCK_SUDO_ALLOW="true,__validate__,apt-get,env"

  run run_maintenance_zsh '
    _sys_apt_plan_blocker() { REPLY=""; }
    _sys_apt_dpkg_state_clean() { return 0; }
    update-apt --yes --verbose
  ' apt

  [ "$status" -eq 0 ]
  [ "$(grep -c -- 'Full invocation:' <<< "$output")" -eq 3 ]
  [[ "$output" == *"XDG_CACHE_HOME=/nonexistent"* ]]
  [[ "$output" == *"DPkg::Lock::Timeout=0"* ]]
  [[ "$output" == *"Acquire::Retries=0"* ]]
}

@test "sys maintenance: phased APT policy reaches preview and every mutation only when explicit" {
  export MOCK_APT_MUTATIONS_SUCCEED=1
  export MOCK_SUDO_ALLOW="true,__validate__,env"

  run run_maintenance_zsh '
    _sys_apt_plan_blocker() { REPLY=""; }
    _sys_apt_dpkg_state_clean() { return 0; }
    update-apt --yes --include-phased-updates
  ' apt

  [ "$status" -eq 0 ]
  local expected_environment_log
  expected_environment_log=$(expected_phased_apt_env_call -s full-upgrade)
  expected_environment_log+=$'\n'
  expected_environment_log+="$(expected_phased_apt_env_call update)"
  expected_environment_log+=$'\n'
  expected_environment_log+="$(expected_phased_apt_env_call full-upgrade -y)"
  expected_environment_log+=$'\n'
  expected_environment_log+="$(expected_phased_apt_env_call autoremove -y)"
  [ "$(cat "$APT_ENV_LOG")" = "$expected_environment_log" ]
  [ "$(grep -c -- 'Always-Include-Phased-Updates=true' \
    "$APT_ENV_LOG")" -eq 4 ]
  [ "$(grep -c -- 'Always-Include-Phased-Updates=true' \
    "$MAINT_MUTATION_LOG")" -eq 3 ]
  [ ! -s "$MAINT_SIGNAL_LOG" ]
  [ ! -s "$MAINT_NETWORK_LOG" ]
  [ ! -s "$MAINT_SHELL_LOG" ]
}

@test "sys maintenance: aggregate propagates phased consent only to APT" {
  run run_maintenance_zsh '
    _sys_step_applies() {
      [[ "$1" == "update-apt" || "$1" == "update-uv-system" ]]
    }
    _sys_apt_plan_blocker() { REPLY=""; }
    _sys_update_preauthenticate() { REPLY=0; }
    update-apt() {
      (( $# == 2 \
        && ${@[(Ie)--yes]} > 0 \
        && ${@[(Ie)--include-phased-updates]} > 0 )) || return 97
      print -r -- "apt:${(j: :)@}" >> "$MAINT_MUTATION_LOG"
    }
    update-uv-system() {
      (( $# == 0 )) || return 97
      print -r -- "uv" >> "$MAINT_MUTATION_LOG"
    }
    update-system --yes --safe-only --include-phased-updates
  ' apt

  [ "$status" -eq 0 ]
  local aggregate_apt_call
  aggregate_apt_call=$(head -n 1 "$MAINT_MUTATION_LOG")
  [[ "$aggregate_apt_call" == apt:*"--yes"* ]]
  [[ "$aggregate_apt_call" == apt:*"--include-phased-updates"* ]]
  [ "$(tail -n 1 "$MAINT_MUTATION_LOG")" = uv ]
  [ "$(wc -l < "$MAINT_MUTATION_LOG")" -eq 2 ]

  : > "$MAINT_MUTATION_LOG"
  run run_maintenance_zsh '
    _sys_step_applies() { [[ "$1" == "update-apt" ]]; }
    _sys_apt_plan_blocker() { REPLY=""; }
    _sys_update_preauthenticate() { REPLY=0; }
    update-apt() {
      [[ $# == 1 && "$1" == "--yes" ]] || return 97
      print -r -- "apt:$1" >> "$MAINT_MUTATION_LOG"
    }
    update-system --yes --safe-only
  ' apt

  [ "$status" -eq 0 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = "apt:--yes" ]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: aggregate verbose mode is forwarded only to APT" {
  run run_maintenance_zsh '
    _sys_step_applies() {
      [[ "$1" == "update-apt" || "$1" == "update-uv-system" ]]
    }
    _sys_apt_plan_blocker() { REPLY=""; }
    _sys_update_preauthenticate() { REPLY=0; }
    update-apt() {
      [[ "${(j: :)@}" == "--yes --verbose" ]] || return 97
      print -r -- "apt:${(j: :)@}" >> "$MAINT_MUTATION_LOG"
    }
    update-uv-system() {
      (( $# == 0 )) || return 97
      print -r -- "uv" >> "$MAINT_MUTATION_LOG"
    }

    update-system --yes --safe-only --verbose
  ' apt

  [ "$status" -eq 0 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = $'apt:--yes --verbose\nuv' ]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: every APT mutation receives closed stdin" {
  run run_maintenance_zsh '
    _SYS_PRIVILEGE_NONINTERACTIVE=1
    _sys_run_with_timeout() {
      print -r -- "Inst zdx-example [1.0] (1.1 stable [amd64])"
    }
    _sys_apt_plan_blocker() { REPLY=""; }
    _sys_apt_dpkg_state_clean() { return 0; }
    _sys_resolve_privilege_prefix() { reply=(_capture_apt_stdin); }
    _capture_apt_stdin() {
      local unexpected_input=""
      if IFS= read -r unexpected_input; then
        print -r -- "unexpected-input:$unexpected_input" \
          >> "$MAINT_MUTATION_LOG"
        return 97
      fi
      local joined=" ${(j: :)@} " operation=""
      case "$joined" in
        *" full-upgrade -y "*) operation=full-upgrade ;;
        *" autoremove -y "*) operation=autoremove ;;
        *" update "*) operation=update ;;
        *) return 97 ;;
      esac
      [[ "$1" == "$TEST_MOCK_BIN/env" \
        && "$2" == "-i" \
        && "$3" == "HOME=/nonexistent" \
        && "$4" == "XDG_CACHE_HOME=/nonexistent" \
        && "$5" == "XDG_CONFIG_HOME=/nonexistent" \
        && "$6" == "XDG_DATA_HOME=/nonexistent" \
        && "$7" == "LC_ALL=C" \
        && "$8" == "PATH=/usr/sbin:/usr/bin:/sbin:/bin" \
        && "$9" == "TERM=dumb" \
        && "${10}" == "DEBIAN_FRONTEND=noninteractive" \
        && "${11}" == "APT_LISTCHANGES_FRONTEND=none" \
        && "${12}" == "apt-get" ]] || return 97
      print -r -- "stdin:closed:$operation" >> "$MAINT_MUTATION_LOG"
    }

    update-apt --yes <<< "untrusted-apt-input"
  ' apt

  [ "$status" -eq 0 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = \
    $'stdin:closed:update\nstdin:closed:full-upgrade\nstdin:closed:autoremove' ]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: APT drops hostile caller environment and functions" {
  export APT_CONFIG="$TEST_TEMP_DIR/secret-apt.conf"
  export HTTP_PROXY="http://apt-secret.example.invalid:8080"
  export http_proxy="http://lower-apt-secret.example.invalid:8080"
  hostile_apt_environment() {
    printf '%s\n' 'hostile-exported-function-ran' \
      >> "$MAINT_MUTATION_LOG"
  }
  export -f hostile_apt_environment

  run run_maintenance_zsh '
    env() {
      print -r -- "hostile-env-function-ran" >> "$MAINT_MUTATION_LOG"
      return 97
    }
    _sys_package_manager_busy() { return 1; }
    update-apt --dry-run --yes <<< "untrusted-apt-input"
  ' apt

  [ "$status" -eq 0 ]
  [ "$(cat "$APT_ENV_LOG")" = \
    "$(expected_apt_env_call -s full-upgrade)" ]
  [ ! -s "$MAINT_MUTATION_LOG" ]
  [[ "$output" != *"apt-secret"* ]]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: Snap list timeout and errors fail visibly" {
  cat <<'EOF' > "$TEST_MOCK_BIN/snap"
#!/usr/bin/env bash
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/snap"

  run run_maintenance_zsh '
    _sys_snap_ready() { return 0; }
    _sys_run_bounded_probe() { return 124; }
    update-snap --dry-run
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"Snap"* ]]
  [[ "$output" == *"timed out"* ]]
  [[ "$output" != *"No Snap refreshes"* ]]
  assert_no_privilege_network_or_signal

  run run_maintenance_zsh '
    _sys_snap_ready() { return 0; }
    _sys_run_bounded_probe() { return 73; }
    update-snap --dry-run
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"Snap"* ]]
  [[ "$output" == *"could not calculate"* ]]
  [[ "$output" != *"No Snap refreshes"* ]]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: unattended-upgrade fingerprints accept only the automatic identity" {
  run run_maintenance_zsh '
    _sys_apt_validate_unattended_fingerprint \
      $'"'"'unattended-upgrade\t4242\t0\t998877\tunattended-upgr\tapt-daily-upgrade.service\t/usr/bin/unattended-upgrade'"'"'
  ' apt

  [ "$status" -eq 0 ]

  local invalid_fingerprint
  for invalid_fingerprint in \
    $'unattended-upgrade\t4242\t1000\t998877\tunattended-upgr\tapt-daily-upgrade.service\t/usr/bin/unattended-upgrade' \
    $'unattended-upgrade\t4242\t0\t998877\tdpkg\tapt-daily-upgrade.service\t/usr/bin/unattended-upgrade' \
    $'unattended-upgrade\t4242\t0\t998877\tunattended-upgr\tuser.slice\t/usr/bin/unattended-upgrade' \
    $'unattended-upgrade\t4242\t0\t998877\tunattended-upgr\tapt-daily.service\t/tmp/unattended-upgrade'; do
    export INVALID_APT_FINGERPRINT="$invalid_fingerprint"
    run run_maintenance_zsh \
      '_sys_apt_validate_unattended_fingerprint "$INVALID_APT_FINGERPRINT"' \
      apt
    [ "$status" -eq 2 ]
  done

  assert_no_privilege_network_or_signal
}

@test "sys maintenance: unattended fingerprint requires caught SIGTERM and enabled minimal steps" {
  export APT_PROC_ROOT="$TEST_TEMP_DIR/proc-fixture"
  export APT_PROGRAM_CHECK_LOG="$TEST_TEMP_DIR/apt-program-check.log"
  : > "$APT_PROGRAM_CHECK_LOG"
  local proc_dir="$APT_PROC_ROOT/4242"
  mkdir -p "$proc_dir"
  {
    printf '%s' '4242 (unattended-upgr) S'
    local stat_field
    for ((stat_field = 4; stat_field <= 21; stat_field++)); do
      printf '%s' ' 0'
    done
    printf '%s\n' ' 998877'
  } > "$proc_dir/stat"
  printf '%s\n' \
    '0::/system.slice/apt-daily-upgrade.service' \
    > "$proc_dir/cgroup"
  printf '/usr/bin/python3\0/usr/bin/unattended-upgrade\0' \
    > "$proc_dir/cmdline"

  local sigcgt_lines expected_status record
  for record in \
    'valid|0' \
    'missing|1' \
    'zero|1' \
    'malformed|1' \
    'duplicate|1' \
    'short|1' \
    'long|1'; do
    IFS='|' read -r sigcgt_lines expected_status <<< "$record"
    case "$sigcgt_lines" in
      valid) sigcgt_lines=$'SigCgt:\t0000000000004000' ;;
      missing) sigcgt_lines='' ;;
      zero) sigcgt_lines=$'SigCgt:\t0000000000000000' ;;
      malformed) sigcgt_lines=$'SigCgt:\t000000000000zzzz' ;;
      duplicate)
        sigcgt_lines=$'SigCgt:\t0000000000004000\nSigCgt:\t0000000000004000'
        ;;
      short) sigcgt_lines=$'SigCgt:\t400' ;;
      long) sigcgt_lines=$'SigCgt:\t00000000000004000' ;;
    esac
    printf 'Name:\tunattended-upgr\nUid:\t0\t0\t0\t0\n%s\n' \
      "$sigcgt_lines" > "$proc_dir/status"

    run run_maintenance_zsh '
      typeset fingerprint_source="$functions[_sys_apt_unattended_fingerprint]"
      fingerprint_source="${fingerprint_source//\/proc/\$APT_PROC_ROOT}"
      functions[_sys_apt_unattended_fingerprint]="$fingerprint_source"
      _sys_apt_read_unattended_pid() { REPLY=4242; }
      _sys_apt_unattended_program_trusted() {
        print -r -- checked >> "$APT_PROGRAM_CHECK_LOG"
        REPLY=/usr/bin/unattended-upgrade
      }
      zstat() {
        [[ "$1" == "-H" && -n "$2" ]] || return 97
        eval "$2=(uid 0 nlink 1 mode 33261)"
      }
      _sys_apt_unattended_fingerprint || return $?
      print -r -- "$REPLY"
    ' apt

    if [ "$status" -ne "$expected_status" ]; then
      printf 'fingerprint case %s: expected %s, got %s: %s\n' \
        "$record" "$expected_status" "$status" "$output" >&2
      return 1
    fi
    if [ "$expected_status" -eq 0 ]; then
      [ "$output" = \
        $'unattended-upgrade\t4242\t0\t998877\tunattended-upgr\tapt-daily-upgrade.service\t/usr/bin/unattended-upgrade' ]
    fi
  done

  printf 'Name:\tunattended-upgr\nUid:\t0\t0\t0\t0\n%s\n' \
    $'SigCgt:\t0000000000004000' > "$proc_dir/status"
  local process_argument
  for record in \
    'separator|--|0' \
    'short-prefix|--n|1' \
    'no-prefix|--no|1' \
    'minimal-prefix|--no-m|1' \
    'long-prefix|--no-minimal|1' \
    'exact-disable|--no-minimal-upgrade-steps|1'; do
    IFS='|' read -r sigcgt_lines process_argument expected_status \
      <<< "$record"
    printf '/usr/bin/unattended-upgrade\0%s\0' "$process_argument" \
      > "$proc_dir/cmdline"

    run run_maintenance_zsh '
      typeset fingerprint_source="$functions[_sys_apt_unattended_fingerprint]"
      fingerprint_source="${fingerprint_source//\/proc/\$APT_PROC_ROOT}"
      functions[_sys_apt_unattended_fingerprint]="$fingerprint_source"
      _sys_apt_read_unattended_pid() { REPLY=4242; }
      _sys_apt_unattended_program_trusted() {
        print -r -- checked >> "$APT_PROGRAM_CHECK_LOG"
        REPLY=/usr/bin/unattended-upgrade
      }
      zstat() {
        [[ "$1" == "-H" && -n "$2" ]] || return 97
        eval "$2=(uid 0 nlink 1 mode 33261)"
      }
      _sys_apt_unattended_fingerprint || return $?
      print -r -- "$REPLY"
    ' apt

    if [ "$status" -ne "$expected_status" ]; then
      printf 'fingerprint argv case %s: expected %s, got %s: %s\n' \
        "$record" "$expected_status" "$status" "$output" >&2
      return 1
    fi
  done

  [ "$(wc -l < "$APT_PROGRAM_CHECK_LOG")" -eq 2 ]

  assert_no_privilege_network_or_signal
}

@test "sys maintenance: unattended takeover freezes one trusted version record" {
  export MOCK_KILL_ALLOW_TERM=1
  export MOCK_SUDO_ALLOW="kill"
  export APT_CONFIG="$TEST_TEMP_DIR/secret-apt.conf"
  export HTTP_PROXY="http://apt-version-secret.example.invalid:8080"
  printf '%s\n' \
    'Unattended-Upgrade::MinimalSteps "true";' \
    'Unattended-Upgrades::MinimalSteps "true";' \
    > "$APT_CONFIG"

  local hostile_bin="$TEST_TEMP_DIR/hostile-apt-tools"
  local hostile_log="$TEST_TEMP_DIR/hostile-apt-tools.log"
  mkdir -p "$hostile_bin"
  : > "$hostile_log"
  export HOSTILE_APT_TOOL_LOG="$hostile_log"
  local hostile_tool
  for hostile_tool in apt-config cat dpkg dpkg-query env head timeout; do
    cat <<'EOF' > "$hostile_bin/$hostile_tool"
#!/usr/bin/env bash
printf '%s\n' "${0##*/}" >> "$HOSTILE_APT_TOOL_LOG"
if [[ "${0##*/}" == "apt-config" ]]; then
  printf "%s='true'\n" "${2:-ZdxMinimalSteps}"
fi
exit 0
EOF
    chmod +x "$hostile_bin/$hostile_tool"
  done

  hostile_apt_version_function() {
    printf '%s\n' 'hostile-version-function-ran' \
      >> "$HOSTILE_APT_TOOL_LOG"
  }
  export -f hostile_apt_version_function

  local version config_mode query_mode package_status expected_status
  local test_case
  for test_case in \
    '0.93|true|valid|install|1' \
    '0.94|unset|valid|install|1' \
    '0.94|primary-true|valid|install|0' \
    '0.94|compat-true|valid|install|0' \
    '0.95|unset|valid|install|0' \
    '0.95|primary-false|valid|install|1' \
    '0.95|unset|valid|hold|0' \
    '1:0.93|true|valid|install|1' \
    '1:0.95|unset|valid|install|0' \
    '0.95|true|malformed|install|1' \
    '0.95|true|error|install|1'; do
    IFS='|' read -r \
      version config_mode query_mode package_status expected_status \
      <<< "$test_case"
    export MOCK_UNATTENDED_VERSION="$version"
    export MOCK_APT_CONFIG_MODE="$config_mode"
    export MOCK_DPKG_QUERY_MODE="$query_mode"
    export MOCK_DPKG_STATUS="$package_status"
    : > "$APT_ENV_LOG"
    : > "$MAINT_MUTATION_LOG"
    : > "$MAINT_SIGNAL_LOG"
    : > "$MOCK_SUDO_LOG"

    run run_maintenance_zsh '
      PATH="'$hostile_bin':$PATH"
      _SYS_PRIVILEGE_NONINTERACTIVE=1
      _sys_apt_kill_program() { REPLY="$TEST_MOCK_BIN/kill"; }
      _sys_apt_unattended_fingerprint_matches() { return 0; }
      _sys_apt_request_automatic_yield \
        $'"'"'unattended-upgrade\t4242\t0\t998877\tunattended-upgr\tapt-daily-upgrade.service\t/usr/bin/unattended-upgrade'"'"' \
        <<< "untrusted-version-probe-input"
    ' apt

    [ "$status" -eq "$expected_status" ]
    [ "$(grep -c -- '/dpkg-query ' "$APT_ENV_LOG")" -eq 1 ]
    [ ! -s "$MAINT_MUTATION_LOG" ]
    [ ! -s "$HOSTILE_APT_TOOL_LOG" ]
    [[ "$(cat "$APT_ENV_LOG")" != *"apt-version-secret"* ]]
    [[ "$output" != *"apt-version-secret"* ]]
    if [ "$expected_status" -eq 0 ]; then
      [ "$(cat "$MAINT_SIGNAL_LOG")" = "kill -s TERM -- 4242" ]
      [ "$(cat "$MOCK_SUDO_LOG")" = \
        "sudo -n $TEST_MOCK_BIN/kill -s TERM -- 4242" ]
    else
      [ ! -s "$MAINT_SIGNAL_LOG" ]
      [ ! -s "$MOCK_SUDO_LOG" ]
    fi
  done
}

@test "sys maintenance: cooperative APT takeover sends only one validated SIGTERM" {
  export MOCK_KILL_ALLOW_TERM=1
  export MOCK_SUDO_ALLOW="__validate__,kill"
  local fingerprint=$'unattended-upgrade\t4242\t0\t998877\tunattended-upgr\tapt-daily-upgrade.service\t/usr/bin/unattended-upgrade'
  export APT_AUTOMATIC_FINGERPRINT="$fingerprint"

  run run_maintenance_zsh '
    _sys_apt_minimal_steps_enabled() { return 0; }
    _sys_apt_kill_program() {
      REPLY="$TEST_MOCK_BIN/kill"
    }
    _sys_apt_unattended_fingerprint() {
      REPLY="$APT_AUTOMATIC_FINGERPRINT"
    }
    _sys_apt_unattended_fingerprint_matches() {
      [[ "$1" == "$APT_AUTOMATIC_FINGERPRINT" ]]
    }

    _sys_apt_request_automatic_yield "$APT_AUTOMATIC_FINGERPRINT"
  ' apt

  [ "$status" -eq 0 ]
  [ "$(cat "$MAINT_SIGNAL_LOG")" = "kill -s TERM -- 4242" ]
  if grep -Eq -- 'KILL|systemctl|rm|lock' \
    "$MAINT_SIGNAL_LOG" "$MOCK_SUDO_LOG"; then
    return 1
  fi
  if (( EUID == 0 )); then
    [ ! -s "$MOCK_SUDO_LOG" ]
  else
    [ "$(cat "$MOCK_SUDO_LOG")" = \
      $'sudo -v\n'"sudo -n $TEST_MOCK_BIN/kill -s TERM -- 4242" ]
  fi
  [ ! -s "$MAINT_MUTATION_LOG" ]
  [ ! -s "$MAINT_NETWORK_LOG" ]
  [ ! -s "$MAINT_SHELL_LOG" ]
}

@test "sys maintenance: identity change during sudo prevents APT signaling" {
  export MOCK_KILL_ALLOW_TERM=1
  export MOCK_SUDO_ALLOW="__validate__,kill"
  local fingerprint=$'unattended-upgrade\t4242\t0\t998877\tunattended-upgr\tapt-daily.service\t/usr/bin/unattended-upgrade'
  export APT_AUTOMATIC_FINGERPRINT="$fingerprint"

  run run_maintenance_zsh '
    _sys_apt_minimal_steps_enabled() { return 0; }
    _sys_apt_kill_program() {
      REPLY="$TEST_MOCK_BIN/kill"
    }
    _sys_apt_unattended_fingerprint() {
      REPLY="$APT_AUTOMATIC_FINGERPRINT"
    }
    typeset -i identity_checks=0
    _sys_apt_unattended_fingerprint_matches() {
      (( ++identity_checks == 1 ))
    }

    _sys_apt_request_automatic_yield "$APT_AUTOMATIC_FINGERPRINT"
  ' apt

  [ "$status" -eq 1 ]
  [[ "$output" == *"changed during authentication"* ]]
  [ ! -s "$MAINT_SIGNAL_LOG" ]
  if (( EUID == 0 )); then
    [ ! -s "$MOCK_SUDO_LOG" ]
  else
    [ "$(cat "$MOCK_SUDO_LOG")" = "sudo -v" ]
  fi
  [ ! -s "$MAINT_MUTATION_LOG" ]
  [ ! -s "$MAINT_NETWORK_LOG" ]
  [ ! -s "$MAINT_SHELL_LOG" ]
}

@test "sys maintenance: disabled minimal steps fail immediately without signaling" {
  export MOCK_KILL_ALLOW_TERM=1
  export MOCK_SUDO_ALLOW="__validate__,kill"
  local fingerprint=$'unattended-upgrade\t4242\t0\t998877\tunattended-upgr\tapt-daily.service\t/usr/bin/unattended-upgrade'
  export APT_AUTOMATIC_FINGERPRINT="$fingerprint"

  run run_maintenance_zsh '
    _sys_apt_minimal_steps_enabled() { return 1; }
    _sys_apt_request_automatic_yield "$APT_AUTOMATIC_FINGERPRINT"
  ' apt

  [ "$status" -eq 1 ]
  [[ "$output" != *"waiting"* ]]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: exact automatic APT owner gets one TERM without polling" {
  export MOCK_KILL_ALLOW_TERM=1
  export MOCK_SUDO_ALLOW="__validate__,kill"
  local fingerprint=$'unattended-upgrade\t4242\t0\t998877\tunattended-upgr\tapt-daily-upgrade.service\t/usr/bin/unattended-upgrade'
  export APT_AUTOMATIC_FINGERPRINT="$fingerprint"

  run run_maintenance_zsh '
    _sys_package_manager_busy() {
      print -r -- "unexpected-busy:$1" >> "$MAINT_PROBE_LOG"
      return 97
    }
    _sys_apt_minimal_steps_enabled() { return 0; }
    _sys_apt_kill_program() {
      REPLY="$TEST_MOCK_BIN/kill"
    }
    _sys_apt_unattended_fingerprint() {
      REPLY="$APT_AUTOMATIC_FINGERPRINT"
    }
    _sys_apt_unattended_fingerprint_matches() {
      [[ "$1" == "$APT_AUTOMATIC_FINGERPRINT" ]]
    }
    _sys_wait_for_package_manager() {
      print -r -- "unexpected-wait:$1" >> "$MAINT_MUTATION_LOG"
      return 97
    }
    _sys_package_lock_pause() {
      print -r -- "unexpected-pause:$1" >> "$MAINT_MUTATION_LOG"
      return 97
    }
    sleep() {
      print -r -- "unexpected-sleep:$*" >> "$MAINT_MUTATION_LOG"
      return 97
    }
    _sys_apt_dpkg_state_clean() {
      print -r -- "dpkg-clean" >> "$MAINT_MUTATION_LOG"
    }

    _sys_apt_prepare_transaction "$APT_AUTOMATIC_FINGERPRINT"
  ' apt

  [ "$status" -eq 0 ]
  [ "$(cat "$MAINT_SIGNAL_LOG")" = "kill -s TERM -- 4242" ]
  if grep -q '^unexpected-busy:' "$MAINT_PROBE_LOG"; then
    return 1
  fi
  [ "$(cat "$MAINT_MUTATION_LOG")" = "dpkg-clean" ]
  [[ "$output" == *"Cooperative takeover"* ]]
  [[ "$output" != *"waiting"* ]]
  if grep -Eq -- 'KILL|systemctl|rm|lock' \
    "$MAINT_SIGNAL_LOG" "$MOCK_SUDO_LOG"; then
    return 1
  fi
}

@test "sys maintenance: cancellation occurs before any cooperative APT action" {
  run run_maintenance_zsh '
    _sys_apt_prepare_transaction() {
      print -r -- "unexpected-takeover" >> "$MAINT_MUTATION_LOG"
      return 97
    }
    update-apt
  ' apt

  [ "$status" -eq 1 ]
  [[ "$output" == *"require --yes"* ]]
  [ ! -s "$MAINT_MUTATION_LOG" ]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: a generic APT owner cannot gate the native no-wait attempt" {
  export MOCK_SUDO_ALLOW="env"

  run run_maintenance_zsh '
    _sys_step_applies() {
      [[ "$1" == "update-apt" || "$1" == "update-uv-system" ]]
    }
    _sys_package_manager_busy() {
      print -r -- "unexpected-generic-busy:$1" >> "$MAINT_PROBE_LOG"
      return 97
    }
    _sys_apt_unattended_fingerprint() {
      return 1
    }
    _sys_wait_for_package_manager() {
      print -r -- "unexpected-wait:$1" >> "$MAINT_MUTATION_LOG"
      return 97
    }
    _sys_package_lock_pause() {
      print -r -- "unexpected-pause:$1" >> "$MAINT_MUTATION_LOG"
      return 97
    }
    sleep() {
      print -r -- "unexpected-sleep:$*" >> "$MAINT_MUTATION_LOG"
      return 97
    }
    _sys_apt_dpkg_state_clean() {
      print -r -- "dpkg-clean" >> "$MAINT_MUTATION_LOG"
    }
    _sys_update_preauthenticate() { return 0; }
    update-uv-system() {
      print -r -- "update-uv-system" >> "$MAINT_MUTATION_LOG"
    }

    update-system --yes --safe-only
  ' apt

  [ "$status" -eq 1 ]
  if grep -q '^unexpected-generic-busy:' "$MAINT_PROBE_LOG"; then
    return 1
  fi
  local apt_update_call
  apt_update_call=$(expected_apt_call update)
  [ "$(cat "$MAINT_MUTATION_LOG")" = \
    "dpkg-clean"$'\n'"$apt_update_call"$'\n'"dpkg-clean"$'\n'"update-uv-system" ]
  [ "$(cat "$MOCK_SUDO_LOG")" = \
    "$(expected_sudo_apt_call update)" ]
  [[ "$output" != *"APT is currently busy"* ]]
  [[ "$output" == *"APT index update failed"* ]]
  [[ "$output" == *"System update completed with partial failures"* ]]
  [[ "$output" != *"waiting"* ]]
  [[ "$output" != *"Deferring"* ]]
  [[ "$output" != *"Retrying"* ]]
  [ ! -s "$MAINT_SIGNAL_LOG" ]
  [ ! -s "$MAINT_NETWORK_LOG" ]
  [ ! -s "$MAINT_SHELL_LOG" ]
}

@test "sys maintenance: APT takeover opt-out uses one native attempt without signaling" {
  export MOCK_SUDO_ALLOW="true,__validate__,env"

  run run_maintenance_zsh '
    SYS_APT_AUTOMATIC_TAKEOVER=0
    _sys_package_manager_busy() {
      print -r -- "unexpected-generic-busy:$1" >> "$MAINT_PROBE_LOG"
      return 97
    }
    _sys_apt_unattended_fingerprint() {
      print -r -- "unexpected-fingerprint" >> "$MAINT_MUTATION_LOG"
      return 97
    }
    _sys_wait_for_package_manager() {
      print -r -- "unexpected-wait:$1" >> "$MAINT_MUTATION_LOG"
      return 97
    }
    _sys_apt_dpkg_state_clean() {
      print -r -- "dpkg-clean" >> "$MAINT_MUTATION_LOG"
    }

    update-apt --yes
  ' apt

  [ "$status" -eq 1 ]
  if grep -q '^unexpected-generic-busy:' "$MAINT_PROBE_LOG"; then
    return 1
  fi
  local apt_update_call
  apt_update_call=$(expected_apt_call update)
  [ "$(cat "$MAINT_MUTATION_LOG")" = \
    "dpkg-clean"$'\n'"$apt_update_call"$'\n'"dpkg-clean" ]
  local expected_sudo_log=$'sudo -n true\nsudo -n -v\n'
  expected_sudo_log+="$(expected_sudo_apt_call update)"
  [ "$(cat "$MOCK_SUDO_LOG")" = \
    "$expected_sudo_log" ]
  [[ "$output" != *"waiting"* ]]
  [[ "$output" != *"Retrying"* ]]
  [ ! -s "$MAINT_SIGNAL_LOG" ]
  [ ! -s "$MAINT_NETWORK_LOG" ]
  [ ! -s "$MAINT_SHELL_LOG" ]
}

@test "sys maintenance: malformed APT takeover configuration fails closed" {
  run run_maintenance_zsh '
    SYS_APT_AUTOMATIC_TAKEOVER=yes
    _sys_package_manager_busy() {
      print -r -- "unexpected-generic-busy:$1" >> "$MAINT_PROBE_LOG"
      return 97
    }

    _sys_apt_plan_blocker
  ' apt

  [ "$status" -eq 2 ]
  [[ "$output" == *"must be exactly 0 or 1"* ]]
  if grep -q '^unexpected-generic-busy:' "$MAINT_PROBE_LOG"; then
    return 1
  fi
  [ ! -s "$MAINT_MUTATION_LOG" ]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: exact unattended fingerprint remains eligible for takeover" {
  local fingerprint=$'unattended-upgrade\t4242\t0\t998877\tunattended-upgr\tapt-daily-upgrade.service\t/usr/bin/unattended-upgrade'
  export APT_AUTOMATIC_FINGERPRINT="$fingerprint"

  run run_maintenance_zsh '
    _sys_package_manager_busy() {
      print -r -- "unexpected-generic-busy:$1" >> "$MAINT_PROBE_LOG"
      return 97
    }
    _sys_apt_unattended_fingerprint() {
      REPLY="$APT_AUTOMATIC_FINGERPRINT"
    }
    _sys_apt_minimal_steps_enabled() { return 0; }
    _sys_apt_plan_blocker || return $?
    print -r -- "$REPLY"
  ' apt

  [ "$status" -eq 0 ]
  [[ "$output" == *"Proposed APT takeover"* ]]
  [[ "$output" == *"$APT_AUTOMATIC_FINGERPRINT"* ]]
  if grep -q '^unexpected-generic-busy:' "$MAINT_PROBE_LOG"; then
    return 1
  fi
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: a persistent automatic lock fails in the one native APT attempt" {
  export MOCK_KILL_ALLOW_TERM=1
  export MOCK_SUDO_ALLOW="kill,env"
  local fingerprint=$'unattended-upgrade\t4242\t0\t998877\tunattended-upgr\tapt-daily.service\t/usr/bin/unattended-upgrade'
  export APT_AUTOMATIC_FINGERPRINT="$fingerprint"

  run run_maintenance_zsh '
    _sys_step_applies() { [[ "$1" == "update-apt" ]]; }
    _sys_apt_plan_blocker() {
      REPLY="$APT_AUTOMATIC_FINGERPRINT"
    }
    _sys_update_preauthenticate() { return 0; }
    _sys_package_manager_busy() {
      print -r -- "unexpected-busy:$1" >> "$MAINT_PROBE_LOG"
      return 97
    }
    _sys_apt_minimal_steps_enabled() { return 0; }
    _sys_apt_kill_program() { REPLY="$TEST_MOCK_BIN/kill"; }
    _sys_apt_unattended_fingerprint() {
      REPLY="$APT_AUTOMATIC_FINGERPRINT"
    }
    _sys_apt_unattended_fingerprint_matches() {
      [[ "$1" == "$APT_AUTOMATIC_FINGERPRINT" ]]
    }
    _sys_wait_for_package_manager() {
      print -r -- "unexpected-wait:$1" >> "$MAINT_MUTATION_LOG"
      return 97
    }
    _sys_package_lock_pause() {
      print -r -- "unexpected-pause:$1" >> "$MAINT_MUTATION_LOG"
      return 97
    }
    sleep() {
      print -r -- "unexpected-sleep:$*" >> "$MAINT_MUTATION_LOG"
      return 97
    }
    _sys_apt_dpkg_state_clean() {
      print -r -- "dpkg-clean" >> "$MAINT_MUTATION_LOG"
    }

    update-system --yes --safe-only
  ' apt

  [ "$status" -eq 1 ]
  [ "$(cat "$MAINT_SIGNAL_LOG")" = "kill -s TERM -- 4242" ]
  if grep -q '^unexpected-busy:' "$MAINT_PROBE_LOG"; then
    return 1
  fi
  local apt_update_call
  apt_update_call=$(expected_apt_call update)
  [ "$(cat "$MAINT_MUTATION_LOG")" = \
    "dpkg-clean"$'\n'"$apt_update_call"$'\n'"dpkg-clean" ]
  [ "$(wc -l < "$MOCK_SUDO_LOG")" -eq 2 ]
  grep -Fxq -- \
    "sudo -n $TEST_MOCK_BIN/kill -s TERM -- 4242" "$MOCK_SUDO_LOG"
  grep -Fxq -- \
    "$(expected_sudo_apt_call update)" \
    "$MOCK_SUDO_LOG"
  [[ "$output" == *"APT index update failed"* ]]
  [[ "$output" == *"System update failed: the only step failed."* ]]
  [[ "$output" != *"completed with partial failures"* ]]
  [[ "$output" != *"waiting"* ]]
  [[ "$output" != *"Retrying"* ]]
  [ ! -s "$MAINT_NETWORK_LOG" ]
  [ ! -s "$MAINT_SHELL_LOG" ]
}

@test "sys maintenance: an owner identity race skips TERM but still runs APT" {
  export MOCK_APT_MUTATIONS_SUCCEED=1
  export MOCK_SUDO_ALLOW="apt-get,env"
  local fingerprint=$'unattended-upgrade\t4242\t0\t998877\tunattended-upgr\tapt-daily.service\t/usr/bin/unattended-upgrade'
  export APT_AUTOMATIC_FINGERPRINT="$fingerprint"

  run run_maintenance_zsh '
    typeset -i identity_checks=0
    _sys_step_applies() { [[ "$1" == "update-apt" ]]; }
    _sys_apt_plan_blocker() {
      REPLY="$APT_AUTOMATIC_FINGERPRINT"
    }
    _sys_update_preauthenticate() { return 0; }
    _sys_package_manager_busy() {
      print -r -- "unexpected-busy:$1" >> "$MAINT_PROBE_LOG"
      return 97
    }
    _sys_apt_minimal_steps_enabled() { return 0; }
    _sys_apt_kill_program() { REPLY="$TEST_MOCK_BIN/kill"; }
    _sys_apt_unattended_fingerprint_matches() {
      (( ++identity_checks ))
      print -r -- "identity:$identity_checks" >> "$MAINT_PROBE_LOG"
      (( identity_checks == 1 ))
    }
    _sys_apt_dpkg_state_clean() {
      print -r -- "dpkg-clean" >> "$MAINT_MUTATION_LOG"
    }
    _sys_wait_for_package_manager() {
      print -r -- "unexpected-wait:$1" >> "$MAINT_MUTATION_LOG"
      return 97
    }
    sleep() {
      print -r -- "unexpected-sleep:$*" >> "$MAINT_MUTATION_LOG"
      return 97
    }

    update-system --yes --safe-only
  ' apt

  [ "$status" -eq 0 ]
  [ "$(grep -c '^identity:' "$MAINT_PROBE_LOG")" -eq 2 ]
  if grep -q '^unexpected-busy:' "$MAINT_PROBE_LOG"; then
    return 1
  fi
  local expected_apt_log="dpkg-clean"
  expected_apt_log+=$'\n'
  expected_apt_log+="$(expected_apt_call update)"
  expected_apt_log+=$'\n'
  expected_apt_log+="$(expected_apt_call full-upgrade -y)"
  expected_apt_log+=$'\n'
  expected_apt_log+="$(expected_apt_call autoremove -y)"
  expected_apt_log+=$'\ndpkg-clean'
  [ "$(cat "$MAINT_MUTATION_LOG")" = \
    "$expected_apt_log" ]
  [ "$(wc -l < "$MOCK_SUDO_LOG")" -eq 3 ]
  if grep -Fq -- ' kill ' "$MOCK_SUDO_LOG"; then
    return 1
  fi
  [[ "$output" == *"no signal was sent"* ]]
  [[ "$output" == *"System update completed successfully"* ]]
  [[ "$output" != *"waiting"* ]]
  [[ "$output" != *"Retrying"* ]]
  [ ! -s "$MAINT_SIGNAL_LOG" ]
  [ ! -s "$MAINT_NETWORK_LOG" ]
  [ ! -s "$MAINT_SHELL_LOG" ]
}

@test "sys maintenance: uncertain dpkg state blocks the owned APT transaction" {
  run run_maintenance_zsh '
    _sys_package_manager_busy() { return 1; }
    _sys_apt_dpkg_state_clean() {
      print -r -- "dpkg-clean" >> "$MAINT_MUTATION_LOG"
      _sys_error "dpkg reports an incomplete package state."
      return 1
    }

    _sys_apt_prepare_transaction
  ' apt

  [ "$status" -eq 1 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = "dpkg-clean" ]
  [[ "$output" == *"incomplete package state"* ]]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: dirty trusted dpkg audit precedes takeover signaling" {
  export APT_CONFIG="$TEST_TEMP_DIR/secret-dpkg.conf"
  export HTTP_PROXY="http://dpkg-secret.example.invalid:8080"
  local hostile_bin="$TEST_TEMP_DIR/hostile-dpkg-tools"
  local hostile_log="$TEST_TEMP_DIR/hostile-dpkg-tools.log"
  mkdir -p "$hostile_bin"
  : > "$hostile_log"
  export HOSTILE_DPKG_TOOL_LOG="$hostile_log"
  local hostile_tool
  for hostile_tool in cat dpkg env head timeout; do
    cat <<'EOF' > "$hostile_bin/$hostile_tool"
#!/usr/bin/env bash
printf '%s\n' "${0##*/}" >> "$HOSTILE_DPKG_TOOL_LOG"
exit 0
EOF
    chmod +x "$hostile_bin/$hostile_tool"
  done

  cat <<'EOF' > "$TEST_MOCK_BIN/dpkg"
#!/usr/bin/env bash
if IFS= read -r unexpected_input; then
  printf 'dpkg-unexpected-stdin:%s\n' "$unexpected_input" \
    >> "$MAINT_MUTATION_LOG"
  exit 98
fi
if [[ -n "${APT_CONFIG+x}" \
  || -n "${HTTP_PROXY+x}" ]] \
  || /usr/bin/env | /usr/bin/grep -q '^BASH_FUNC_'; then
  printf '%s\n' 'dpkg-unsafe-environment' \
    >> "$MAINT_MUTATION_LOG"
  exit 98
fi
[[ "${1:-}" == "--audit" && $# -eq 1 ]] || exit 97
printf '%s\n' 'zdx-example is only half-configured'
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/dpkg"

  local fingerprint=$'unattended-upgrade\t4242\t0\t998877\tunattended-upgr\tapt-daily-upgrade.service\t/usr/bin/unattended-upgrade'
  export APT_AUTOMATIC_FINGERPRINT="$fingerprint"
  run run_maintenance_zsh '
    PATH="'$hostile_bin':$PATH"
    env() {
      print -r -- "hostile-env-function" >> "$HOSTILE_DPKG_TOOL_LOG"
      return 0
    }
    dpkg() {
      print -r -- "hostile-dpkg-function" >> "$HOSTILE_DPKG_TOOL_LOG"
      return 0
    }
    _sys_apt_unattended_fingerprint_matches() {
      print -r -- "unexpected-fingerprint-recheck" \
        >> "$MAINT_MUTATION_LOG"
      return 0
    }
    _sys_apt_request_automatic_yield() {
      print -r -- "unexpected-signal-request" \
        >> "$MAINT_MUTATION_LOG"
      return 0
    }
    _sys_apt_prepare_transaction "$APT_AUTOMATIC_FINGERPRINT" \
      <<< "untrusted-dpkg-input"
  ' apt

  [ "$status" -eq 1 ]
  [[ "$output" == *"incomplete package state"* ]]
  [ "$(cat "$APT_ENV_LOG")" = "$(expected_dpkg_audit_call)" ]
  [ ! -s "$MAINT_MUTATION_LOG" ]
  [ ! -s "$HOSTILE_DPKG_TOOL_LOG" ]
  [[ "$output" != *"dpkg-secret"* ]]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: APT audits dpkg again after the completed transaction" {
  export MOCK_APT_MUTATIONS_SUCCEED=1
  export MOCK_SUDO_ALLOW="true,__validate__,env"

  run run_maintenance_zsh '
    typeset -gi apt_audit_checks=0
    _sys_apt_plan_blocker() { REPLY=""; }
    _sys_apt_dpkg_state_clean() {
      (( ++apt_audit_checks ))
      if (( apt_audit_checks == 1 )); then
        (( $# == 0 )) || return 97
      else
        [[ $# == 1 && "$1" == after ]] || return 97
      fi
      print -r -- "audit:$apt_audit_checks" >> "$MAINT_MUTATION_LOG"
    }
    _sys_apt_report_reboot_requirement() {
      print -r -- "reboot-report" >> "$MAINT_MUTATION_LOG"
    }
    update-apt --yes
  ' apt

  [ "$status" -eq 0 ]
  local expected_mutations=$'audit:1\n'
  expected_mutations+="$(expected_apt_call update)"
  expected_mutations+=$'\n'
  expected_mutations+="$(expected_apt_call full-upgrade -y)"
  expected_mutations+=$'\n'
  expected_mutations+="$(expected_apt_call autoremove -y)"
  expected_mutations+=$'\naudit:2\nreboot-report'
  [ "$(cat "$MAINT_MUTATION_LOG")" = "$expected_mutations" ]
  [ "$(grep -c '^audit:' "$MAINT_MUTATION_LOG")" -eq 2 ]
  [[ "$output" == *"APT update plan completed"* ]]
  [ ! -s "$MAINT_SIGNAL_LOG" ]
  [ ! -s "$MAINT_NETWORK_LOG" ]
  [ ! -s "$MAINT_SHELL_LOG" ]
}

@test "sys maintenance: failed post-transaction dpkg audit is visible and nonzero" {
  export MOCK_APT_MUTATIONS_SUCCEED=1
  export MOCK_SUDO_ALLOW="true,__validate__,env"

  run run_maintenance_zsh '
    typeset -gi apt_audit_checks=0
    _sys_apt_plan_blocker() { REPLY=""; }
    _sys_apt_dpkg_state_clean() {
      (( ++apt_audit_checks ))
      if (( apt_audit_checks == 1 )); then
        (( $# == 0 )) || return 97
      else
        [[ $# == 1 && "$1" == after ]] || return 97
      fi
      print -r -- "audit:$apt_audit_checks" >> "$MAINT_MUTATION_LOG"
      if (( apt_audit_checks == 2 )); then
        _sys_error "Post-transaction dpkg audit failed."
        return 1
      fi
    }
    _sys_apt_report_reboot_requirement() {
      print -r -- "unexpected-reboot-report" >> "$MAINT_MUTATION_LOG"
      return 97
    }
    update-apt --yes
  ' apt

  [ "$status" -eq 1 ]
  [ "$(grep -c '^audit:' "$MAINT_MUTATION_LOG")" -eq 2 ]
  grep -Fxq -- "$(expected_apt_call update)" "$MAINT_MUTATION_LOG"
  grep -Fxq -- "$(expected_apt_call full-upgrade -y)" \
    "$MAINT_MUTATION_LOG"
  grep -Fxq -- "$(expected_apt_call autoremove -y)" \
    "$MAINT_MUTATION_LOG"
  [[ "$output" == *"Post-transaction dpkg audit failed"* ]]
  [[ "$output" != *"APT update plan completed"* ]]
  if grep -q '^unexpected-reboot-report$' "$MAINT_MUTATION_LOG"; then
    return 1
  fi
  [ ! -s "$MAINT_SIGNAL_LOG" ]
  [ ! -s "$MAINT_NETWORK_LOG" ]
  [ ! -s "$MAINT_SHELL_LOG" ]
}

@test "sys maintenance: every failed APT mutation still reaches the post-audit" {
  export MOCK_APT_MUTATIONS_SUCCEED=1
  export MOCK_SUDO_ALLOW="env"

  local failed_operation expected_mutations
  for failed_operation in update full-upgrade autoremove; do
    export MOCK_APT_FAIL_OPERATION="$failed_operation"
    : > "$MAINT_MUTATION_LOG"
    : > "$MOCK_SUDO_LOG"

    run run_maintenance_zsh '
      _SYS_PRIVILEGE_NONINTERACTIVE=1
      typeset -gi apt_audit_checks=0
      _sys_apt_plan_blocker() { REPLY=""; }
      _sys_apt_dpkg_state_clean() {
        (( ++apt_audit_checks ))
        print -r -- \
          "audit:$apt_audit_checks:${1:-before}" >> "$MAINT_MUTATION_LOG"
      }
      _sys_apt_report_reboot_requirement() {
        print -r -- "reboot-report" >> "$MAINT_MUTATION_LOG"
      }
      update-apt --yes
    ' apt

    [ "$status" -eq 1 ]
    expected_mutations=$'audit:1:before\n'
    expected_mutations+="$(expected_apt_call update)"
    if [[ "$failed_operation" != update ]]; then
      expected_mutations+=$'\n'
      expected_mutations+="$(expected_apt_call full-upgrade -y)"
    fi
    if [[ "$failed_operation" == autoremove ]]; then
      expected_mutations+=$'\n'
      expected_mutations+="$(expected_apt_call autoremove -y)"
    fi
    expected_mutations+=$'\naudit:2:after\nreboot-report'
    [ "$(cat "$MAINT_MUTATION_LOG")" = "$expected_mutations" ]
    [[ "$output" != *"APT update plan completed"* ]]
  done

  [ ! -s "$MAINT_SIGNAL_LOG" ]
  [ ! -s "$MAINT_NETWORK_LOG" ]
  [ ! -s "$MAINT_SHELL_LOG" ]
}

@test "sys maintenance: safe reboot-required marker produces an advisory only" {
  run run_maintenance_zsh '
    _sys_apt_reboot_required() { return 0; }
    _sys_apt_report_reboot_requirement
  ' apt

  [ "$status" -eq 0 ]
  [[ "$output" == *"Reboot"*"required"* \
    || "$output" == *"reboot"*"required"* ]]
  [ ! -s "$MAINT_MUTATION_LOG" ]
  assert_no_privilege_network_or_signal

  run run_maintenance_zsh '
    _sys_apt_reboot_required() { return 1; }
    _sys_apt_report_reboot_requirement
  ' apt

  [ "$status" -eq 0 ]
  [[ "$output" != *"Reboot"*"required"* ]]
  [[ "$output" != *"reboot"*"required"* ]]
  [ ! -s "$MAINT_MUTATION_LOG" ]
  assert_no_privilege_network_or_signal

  run run_maintenance_zsh '
    _sys_apt_reboot_required() { return 2; }
    _sys_apt_report_reboot_requirement
  ' apt

  [ "$status" -eq 0 ]
  [[ "$output" == *"could not be validated safely"* ]]
  [[ "$output" == *"unknown"* ]]
  [ ! -s "$MAINT_MUTATION_LOG" ]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: reboot-required validates the opened marker identity" {
  local marker="$TEST_TEMP_DIR/reboot-required"
  local linked_marker="$TEST_TEMP_DIR/reboot-required-link"
  printf '%s\n' 'System restart required' > "$marker"
  chmod 644 "$marker"
  ln -s "$marker" "$linked_marker"
  export REBOOT_REQUIRED_FIXTURE="$marker"

  run run_maintenance_zsh '
    zmodload zsh/stat || return 97
    zstat() {
      builtin zstat "$@" || return $?
      case "${2:-}" in
        before_state) before_state[uid]=0 ;;
        fd_state)     fd_state[uid]=0 ;;
        after_state)  after_state[uid]=0 ;;
      esac
    }
    _sys_apt_reboot_required_path() {
      REPLY="$REBOOT_REQUIRED_FIXTURE"
    }
    _sys_apt_reboot_required || return $?
    _sys_apt_report_reboot_requirement
  ' apt

  [ "$status" -eq 0 ]
  [[ "$output" == *"system reboot is required"* ]]
  [ ! -s "$MAINT_MUTATION_LOG" ]
  assert_no_privilege_network_or_signal

  export REBOOT_REQUIRED_FIXTURE="$linked_marker"
  run run_maintenance_zsh '
    _sys_apt_reboot_required_path() {
      REPLY="$REBOOT_REQUIRED_FIXTURE"
    }
    _sys_apt_reboot_required
  ' apt

  [ "$status" -eq 2 ]
  [ -L "$linked_marker" ]
  [ ! -s "$MAINT_MUTATION_LOG" ]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: native package step applies only to supported backends" {
  local backend
  for backend in dnf pacman zypper apk softwareupdate; do
    run run_maintenance_zsh \
      "_sys_step_applies _sys_update_platform_packages" "$backend"

    [ "$status" -eq 0 ]
  done

  run run_maintenance_zsh \
    "_sys_step_applies _sys_update_platform_packages" apt

  [ "$status" -eq 1 ]
  [ ! -s "$MAINT_PLATFORM_LOG" ]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: native package mutation receives closed stdin" {
  run run_maintenance_zsh '
    _sys_run_with_timeout() {
      [[ "$1" == 60 \
        && "$2" == "pacman" \
        && "$3" == "-Qu" \
        && $# -eq 3 ]] || return 97
      print -r -- "zdx-example 1.0 -> 1.1"
      return 1
    }
    _sys_resolve_privilege_prefix() { reply=(_capture_native_stdin); }
    _capture_native_stdin() {
      local unexpected_input=""
      if IFS= read -r unexpected_input; then
        print -r -- "unexpected-input:$unexpected_input" \
          >> "$MAINT_MUTATION_LOG"
        return 97
      fi
      [[ "${(j: :)@}" == "pacman -Syu --noconfirm" ]] || return 97
      print -r -- "stdin:closed:pacman" >> "$MAINT_MUTATION_LOG"
    }

    _sys_update_platform_packages 1 <<< "untrusted-native-input"
  ' pacman

  [ "$status" -eq 0 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = "stdin:closed:pacman" ]
  [[ "$output" == *"Native pacman packages updated"* ]]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: DNF version parsing accepts only canonical major records" {
  export DNF_VERSION_RECORD="4.21.1"
  run run_maintenance_zsh '
    _sys_dnf_resolve_trusted_program() {
      [[ "$1" == "env" ]] || return 97
      REPLY="/usr/bin/env"
    }
    _sys_run_bounded_probe() { print -r -- "$DNF_VERSION_RECORD"; }
    _sys_dnf_major_version /usr/bin/dnf || return $?
    [[ "${(j: :)reply}" == "4 21 1" ]] || return 97
    print -r -- "$REPLY"
  ' dnf
  [ "$status" -eq 0 ]
  [ "$output" = "4" ]

  export DNF_VERSION_RECORD="dnf5 version 5.2.13.1"
  run run_maintenance_zsh '
    _sys_dnf_resolve_trusted_program() {
      [[ "$1" == "env" ]] || return 97
      REPLY="/usr/bin/env"
    }
    _sys_run_bounded_probe() { print -r -- "$DNF_VERSION_RECORD"; }
    _sys_dnf_major_version /usr/bin/dnf5 || return $?
    [[ "${(j: :)reply}" == "5 2 13 1" ]] || return 97
    print -r -- "$REPLY"
  ' dnf
  [ "$status" -eq 0 ]
  [ "$output" = "5" ]

  local invalid_version
  for invalid_version in \
    "5.2.13.1" \
    "dnf5 version 4.21.1" \
    "dnf5 version 5" \
    "DNF5 version 5.2.13" \
    "4.21.1 trailing" \
    "4.21.1.0" \
    "dnf5 version 5.2.13.1 trailing" \
    "6.0"; do
    export DNF_VERSION_RECORD="$invalid_version"
    run run_maintenance_zsh '
      _sys_dnf_resolve_trusted_program() {
        [[ "$1" == "env" ]] || return 97
        REPLY="/usr/bin/env"
      }
      _sys_run_bounded_probe() { print -r -- "$DNF_VERSION_RECORD"; }
      _sys_dnf_major_version /usr/bin/dnf
    ' dnf
    [ "$status" -eq 1 ]
  done

  assert_no_privilege_network_or_signal
}

@test "sys maintenance: DNF env resolver rejects non-root or writable programs" {
  export DNF_TEST_PROGRAM_UID=0
  export DNF_TEST_PROGRAM_MODE=33261
  run run_maintenance_zsh '
    zstat() {
      [[ "$1" == "-H" && $# -eq 3 ]] || return 97
      set -A "$2" \
        uid "$DNF_TEST_PROGRAM_UID" mode "$DNF_TEST_PROGRAM_MODE"
    }
    _sys_dnf_resolve_trusted_program env || return $?
    print -r -- "$REPLY"
  ' dnf
  [ "$status" -eq 0 ]
  [[ "$output" == /*/env ]]

  export DNF_TEST_PROGRAM_UID=1
  run run_maintenance_zsh '
    zstat() {
      set -A "$2" \
        uid "$DNF_TEST_PROGRAM_UID" mode "$DNF_TEST_PROGRAM_MODE"
    }
    _sys_dnf_resolve_trusted_program env
  ' dnf
  [ "$status" -eq 1 ]

  export DNF_TEST_PROGRAM_UID=0
  export DNF_TEST_PROGRAM_MODE=33279
  run run_maintenance_zsh '
    zstat() {
      set -A "$2" \
        uid "$DNF_TEST_PROGRAM_UID" mode "$DNF_TEST_PROGRAM_MODE"
    }
    _sys_dnf_resolve_trusted_program env
  ' dnf
  [ "$status" -eq 1 ]

  run run_maintenance_zsh '_sys_dnf_resolve_trusted_program printf' dnf
  [ "$status" -eq 2 ]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: DNF probes use the exact clean environment argv" {
  run run_maintenance_zsh '
    _sys_dnf_resolve_trusted_program() {
      [[ "$1" == "env" ]] || return 97
      REPLY="/usr/bin/env"
    }
    _sys_run_bounded_probe() {
      print -r -- "${(j:|:)@}" >> "$MAINT_PROBE_LOG"
      case "${@[-1]}" in
        --version) print -r -- "dnf5 version 5.2.13.1" ;;
        --dump-main-config)
          printf "%s\n" \
            "persistdir = /var/lib/dnf" \
            "installroot = /" \
            "skip_system_repo_lock = False"
          ;;
        *) return 97 ;;
      esac
    }

    _sys_dnf_major_version /usr/bin/dnf5 || return $?
    [[ "$REPLY" == 5 ]] || return 97
    _sys_dnf5_persistdir /usr/bin/dnf5 || return $?
    [[ "$REPLY" == "/var/lib/dnf" ]] || return 97
  ' dnf

  [ "$status" -eq 0 ]
  local clean_environment="-i|HOME=/nonexistent"
  clean_environment+="|XDG_CACHE_HOME=/nonexistent"
  clean_environment+="|XDG_CONFIG_HOME=/nonexistent"
  clean_environment+="|XDG_DATA_HOME=/nonexistent"
  clean_environment+="|LC_ALL=C|PATH=/usr/sbin:/usr/bin:/sbin:/bin"
  clean_environment+="|TERM=dumb|DNF5_FORCE_INTERACTIVE=0"
  clean_environment+="|PYTHONNOUSERSITE=1"
  local expected_probe_log="10|16384|/usr/bin/env|$clean_environment"
  expected_probe_log+="|/usr/bin/dnf5|--version"
  expected_probe_log+=$'\n'
  expected_probe_log+="10|262144|/usr/bin/env|$clean_environment"
  expected_probe_log+="|/usr/bin/dnf5|--dump-main-config"
  [ "$(cat "$MAINT_PROBE_LOG")" = "$expected_probe_log" ]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: DNF probes do not inherit hostile shell or plugin state" {
  local hostile_hook="$TEST_TEMP_DIR/dnf-hostile-hook.bash"
  local hostile_marker="$TEST_TEMP_DIR/dnf-hostile-executed"
  printf ': > %q\n' "$hostile_marker" > "$hostile_hook"
  export BASH_ENV="$hostile_hook"
  export ENV="$hostile_hook"
  export ZDOTDIR="$TEST_TEMP_DIR/hostile-zdotdir"
  export PYTHONPATH="$TEST_TEMP_DIR/hostile-python"
  export PYTHONUSERBASE="$TEST_TEMP_DIR/hostile-python-user"
  export DNF5_PLUGIN_PATH="$TEST_TEMP_DIR/hostile-dnf5-plugins"
  export LIBDNF5_PLUGINS_CONFIG_DIR="$TEST_TEMP_DIR/hostile-dnf5-config"
  export http_proxy="https://probe-proxy-secret.invalid:8443"
  export FTP_PROXY="ftp://probe-ftp-secret.invalid:2121"
  export DNF5_FORCE_INTERACTIVE=1
  export PYTHONNOUSERSITE=0
  hostile_dnf_function() {
    : > "$hostile_marker"
  }
  export -f hostile_dnf_function

  cat <<'EOF' > "$TEST_MOCK_BIN/dnf5-clean-env"
#!/usr/bin/env bash
set -u

audit_log="${0%/*}/dnf-clean-env.log"
{
  printf 'call=%s\n' "${1:-}"
  /usr/bin/env | /usr/bin/sort
  if declare -F hostile_dnf_function >/dev/null; then
    printf '%s\n' 'inherited-function=hostile_dnf_function'
    hostile_dnf_function
  fi
} >> "$audit_log"

case "${1:-}" in
  --version)
    printf '%s\n' 'dnf5 version 5.2.13.1'
    ;;
  --dump-main-config)
    printf '%s\n' \
      'persistdir = /var/lib/dnf' \
      'installroot = /' \
      'skip_system_repo_lock = False'
    ;;
  *) exit 97 ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/dnf5-clean-env"

  run run_maintenance_zsh '
    _sys_dnf_resolve_trusted_program() {
      [[ "$1" == "env" ]] || return 97
      REPLY="/usr/bin/env"
    }
    _sys_dnf_major_version "$TEST_MOCK_BIN/dnf5-clean-env" || return $?
    [[ "$REPLY" == 5 ]] || return 97
    _sys_dnf5_persistdir "$TEST_MOCK_BIN/dnf5-clean-env" || return $?
    print -r -- "$REPLY"
  ' dnf

  [ "$status" -eq 0 ]
  [ "$output" = "/var/lib/dnf" ]
  [ ! -e "$hostile_marker" ]
  local environment_log="$TEST_MOCK_BIN/dnf-clean-env.log"
  [ "$(grep -c '^call=' "$environment_log")" -eq 2 ]
  local expected_environment
  for expected_environment in \
    HOME=/nonexistent \
    XDG_CACHE_HOME=/nonexistent \
    XDG_CONFIG_HOME=/nonexistent \
    XDG_DATA_HOME=/nonexistent \
    LC_ALL=C \
    PATH=/usr/sbin:/usr/bin:/sbin:/bin \
    TERM=dumb \
    DNF5_FORCE_INTERACTIVE=0 \
    PYTHONNOUSERSITE=1; do
    [ "$(grep -Fxc -- "$expected_environment" "$environment_log")" -eq 2 ]
  done
  local hostile_name
  for hostile_name in \
    BASH_ENV ENV ZDOTDIR PYTHONPATH PYTHONUSERBASE DNF5_PLUGIN_PATH \
    LIBDNF5_PLUGINS_CONFIG_DIR http_proxy FTP_PROXY; do
    if grep -Fq -- "$hostile_name=" "$environment_log"; then
      return 1
    fi
  done
  ! grep -Fq -- 'inherited-function=' "$environment_log"
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: DNF5 freezes one unambiguous system-root configuration" {
  export DNF_CONFIG_RECORD=$'persistdir = /var/lib/dnf\ninstallroot = /\nskip_system_repo_lock = False'
  run run_maintenance_zsh '
    _sys_dnf_resolve_trusted_program() {
      [[ "$1" == "env" ]] || return 97
      REPLY="/usr/bin/env"
    }
    _sys_run_bounded_probe() { print -r -- "$DNF_CONFIG_RECORD"; }
    _sys_dnf5_persistdir /usr/bin/dnf5 || return $?
    [[ "${(j:|:)reply}" == "/var/lib/dnf|1" ]] || return 97
    print -r -- "$REPLY"
  ' dnf

  [ "$status" -eq 0 ]
  [ "$output" = "/var/lib/dnf" ]

  export DNF_CONFIG_RECORD=$'persistdir = /var/lib/dnf\ninstallroot = /'
  run run_maintenance_zsh '
    _sys_dnf_resolve_trusted_program() {
      [[ "$1" == "env" ]] || return 97
      REPLY="/usr/bin/env"
    }
    _sys_run_bounded_probe() { print -r -- "$DNF_CONFIG_RECORD"; }
    _sys_dnf5_persistdir /usr/bin/dnf5 || return $?
    [[ "$REPLY" == "/var/lib/dnf" \
      && "${(j:|:)reply}" == "/var/lib/dnf|0" ]] || return 97
  ' dnf
  [ "$status" -eq 0 ]

  local invalid_config
  for invalid_config in \
    $'persistdir = /var/lib/dnf\npersistdir = /var/cache/dnf\ninstallroot = /\nskip_system_repo_lock = False' \
    $'persistdir = /var/lib/dnf\ninstallroot = /\ninstallroot = /\nskip_system_repo_lock = False' \
    $'persistdir = /var/lib/dnf\ninstallroot = /\nskip_system_repo_lock = False\nskip_system_repo_lock = True' \
    $'installroot = /\nskip_system_repo_lock = False' \
    $'persistdir = /var/lib/dnf\nskip_system_repo_lock = False' \
    $'persistdir = /var/lib/dnf\ninstallroot = /srv/chroot\nskip_system_repo_lock = False' \
    $'persistdir = var/lib/dnf\ninstallroot = /\nskip_system_repo_lock = False' \
    $'persistdir = /\ninstallroot = /\nskip_system_repo_lock = False' \
    $'persistdir = /var/lib/../lib/dnf\ninstallroot = /\nskip_system_repo_lock = False' \
    $'persistdir = /var/lib/dnf\ninstallroot = /\nskip_system_repo_lock = maybe'; do
    export DNF_CONFIG_RECORD="$invalid_config"
    run run_maintenance_zsh '
      _sys_dnf_resolve_trusted_program() {
        [[ "$1" == "env" ]] || return 97
        REPLY="/usr/bin/env"
      }
      _sys_run_bounded_probe() { print -r -- "$DNF_CONFIG_RECORD"; }
      _sys_dnf5_persistdir /usr/bin/dnf5
    ' dnf
    [ "$status" -eq 1 ]
    [[ "$output" == *"could not be frozen safely"* ]]
  done

  assert_no_privilege_network_or_signal
}

@test "sys maintenance: DNF5 5.4 skips preview and dispatches one frozen guard" {
  run run_maintenance_zsh '
    typeset -i persistdir_calls=0 guard_calls=0 fallback_calls=0
    _sys_dnf_resolve_trusted_program() {
      [[ "$1" == "dnf" ]] || return 97
      REPLY="$TEST_MOCK_BIN/dnf"
    }
    _sys_dnf_major_version() {
      [[ "$1" == "$TEST_MOCK_BIN/dnf" ]] || return 97
      REPLY=5
      reply=(5 4 0 0)
    }
    _sys_dnf5_persistdir() {
      (( ++persistdir_calls ))
      print -r -- "persistdir:$persistdir_calls:$1" \
        >> "$MAINT_MUTATION_LOG"
      if (( persistdir_calls == 1 )); then
        REPLY="/var/lib/dnf"
      else
        REPLY="/tmp/changed"
      fi
      reply=("$REPLY" 1)
    }
    _sys_run_with_timeout() {
      print -r -- "unexpected-check-update:${(j: :)@}" \
        >> "$MAINT_MUTATION_LOG"
      return 97
    }
    _sys_resolve_privilege_prefix() { reply=(sudo -n); }
    _sys_dnf5_run_guarded() {
      (( ++guard_calls ))
      [[ "$1" == "sudo -n " \
        && "$2" == "$TEST_MOCK_BIN/dnf" \
        && "$3" == "/var/lib/dnf" \
        && "$4" == "sudo" \
        && "$5" == "-n" \
        && $# -eq 5 ]] || return 97
      print -r -- "guard:$guard_calls:$2:$3:$4:$5" \
        >> "$MAINT_MUTATION_LOG"
    }
    _sys_dnf5_run_without_system_lock() {
      (( ++fallback_calls ))
      print -r -- "unexpected-fallback:$fallback_calls:${(j: :)@}" \
        >> "$MAINT_MUTATION_LOG"
      return 97
    }

    _sys_update_platform_packages 1
  ' dnf

  [ "$status" -eq 0 ]
  local expected_dispatch="persistdir:1:$TEST_MOCK_BIN/dnf"
  expected_dispatch+=$'\n'
  expected_dispatch+="guard:1:$TEST_MOCK_BIN/dnf:/var/lib/dnf:sudo:-n"
  [ "$(cat "$MAINT_MUTATION_LOG")" = "$expected_dispatch" ]
  [ ! -s "$MAINT_PLATFORM_LOG" ]
  [[ "$output" == *"DNF5 candidate rendering is skipped"* ]]
  [[ "$output" == *"Native dnf packages updated"* ]]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: pre-5.4 DNF5 dispatches one sanitized fallback" {
  run run_maintenance_zsh '
    typeset -i persistdir_calls=0 fallback_calls=0 guard_calls=0
    _sys_dnf_resolve_trusted_program() {
      [[ "$1" == "dnf" ]] || return 97
      REPLY="$TEST_MOCK_BIN/dnf"
    }
    _sys_dnf_major_version() {
      [[ "$1" == "$TEST_MOCK_BIN/dnf" ]] || return 97
      REPLY=5
      reply=(5 3 6 0)
    }
    _sys_dnf5_persistdir() {
      (( ++persistdir_calls ))
      REPLY="/var/lib/dnf"
      reply=("$REPLY" 0)
      print -r -- "persistdir:$persistdir_calls:$1" \
        >> "$MAINT_MUTATION_LOG"
    }
    _sys_run_with_timeout() {
      print -r -- "unexpected-check-update:${(j: :)@}" \
        >> "$MAINT_MUTATION_LOG"
      return 97
    }
    _sys_resolve_privilege_prefix() { reply=(sudo -n); }
    _sys_dnf5_run_without_system_lock() {
      (( ++fallback_calls ))
      [[ "$1" == "sudo -n " \
        && "$2" == "$TEST_MOCK_BIN/dnf" \
        && "$3" == "/var/lib/dnf" \
        && "$4" == "sudo" \
        && "$5" == "-n" \
        && $# -eq 5 ]] || return 97
      print -r -- "fallback:$fallback_calls:$2:$3:$4:$5" \
        >> "$MAINT_MUTATION_LOG"
    }
    _sys_dnf5_run_guarded() {
      (( ++guard_calls ))
      print -r -- "unexpected-guard:$guard_calls:${(j: :)@}" \
        >> "$MAINT_MUTATION_LOG"
      return 97
    }

    _sys_update_platform_packages 1
  ' dnf

  [ "$status" -eq 0 ]
  local expected_dispatch="persistdir:1:$TEST_MOCK_BIN/dnf"
  expected_dispatch+=$'\n'
  expected_dispatch+="fallback:1:$TEST_MOCK_BIN/dnf:/var/lib/dnf:sudo:-n"
  [ "$(cat "$MAINT_MUTATION_LOG")" = "$expected_dispatch" ]
  [ ! -s "$MAINT_PLATFORM_LOG" ]
  [[ "$output" == *"pre-5.4 DNF5"* ]]
  [[ "$output" == *"Native dnf packages updated"* ]]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: DNF5 5.1 skips config and mutates once without persistdir" {
  run run_maintenance_zsh '
    typeset -i capture_calls=0
    unset http_proxy https_proxy ftp_proxy no_proxy all_proxy
    unset HTTP_PROXY HTTPS_PROXY FTP_PROXY NO_PROXY ALL_PROXY
    _sys_dnf_resolve_trusted_program() {
      case "$1" in
        dnf) REPLY="$TEST_MOCK_BIN/dnf" ;;
        zsh) REPLY="/usr/bin/zsh" ;;
        env) REPLY="/usr/bin/env" ;;
        *) return 97 ;;
      esac
    }
    _sys_dnf_major_version() {
      [[ "$1" == "$TEST_MOCK_BIN/dnf" ]] || return 97
      REPLY=5
      reply=(5 1 17 0)
    }
    _sys_dnf5_persistdir() {
      print -r -- "unexpected-config-probe:$*" >> "$MAINT_MUTATION_LOG"
      return 97
    }
    _sys_run_with_timeout() {
      print -r -- "unexpected-preview:${(j: :)@}" \
        >> "$MAINT_MUTATION_LOG"
      return 97
    }
    _sys_dnf5_run_guarded() {
      print -r -- "unexpected-guard:${(j: :)@}" \
        >> "$MAINT_MUTATION_LOG"
      return 97
    }
    _sys_resolve_privilege_prefix() { reply=(_capture_early_dnf5); }
    _capture_early_dnf5() {
      (( ++capture_calls ))
      [[ $# -eq 20 \
        && "$1" == "/usr/bin/env" \
        && "$2" == "-i" \
        && "$3" == "HOME=/nonexistent" \
        && "$4" == "XDG_CACHE_HOME=/nonexistent" \
        && "$5" == "XDG_CONFIG_HOME=/nonexistent" \
        && "$6" == "XDG_DATA_HOME=/nonexistent" \
        && "$7" == "LC_ALL=C" \
        && "$8" == "PATH=/usr/sbin:/usr/bin:/sbin:/bin" \
        && "$9" == "TERM=dumb" \
        && "$10" == "DNF5_FORCE_INTERACTIVE=0" \
        && "$11" == "PYTHONNOUSERSITE=1" \
        && "$12" == "/usr/bin/zsh" \
        && "$13" == "-fc" \
        && "$15" == "zdx-dnf5-runner" \
        && "$16" == 0 \
        && -z "$17" \
        && -z "$18" \
        && "$19" == "$TEST_MOCK_BIN/dnf" \
        && "$20" == "/usr/bin/env" ]] || return 97
      local wrapper_source="$14"
      local dollar=\$
      [[ "$wrapper_source" == *"dnf_arguments=("*"--installroot=/"* \
        && "$wrapper_source" == *"[[ -n \"${dollar}persistdir\" ]]"* \
        && "$wrapper_source" == *"dnf_arguments+=(\"--setopt=persistdir=${dollar}persistdir\")"* \
        && "$wrapper_source" == *"\"${dollar}env_program\" -i HOME=/nonexistent"* ]] \
        || return 97
      print -r -- "early-dnf5:$capture_calls:mode=$16:persistdir=<$18>" \
        >> "$MAINT_MUTATION_LOG"
    }

    _sys_update_platform_packages 1
  ' dnf

  [ "$status" -eq 0 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = \
    "early-dnf5:1:mode=0:persistdir=<>" ]
  [ ! -s "$MAINT_PLATFORM_LOG" ]
  [[ "$output" == *"does not depend on config dumping"* ]]
  [[ "$output" == *"Sanitized command:"*"--installroot=/ --assumeyes --refresh upgrade"* ]]
  [[ "$output" != *"--setopt=persistdir="* ]]
  [[ "$output" != *"--setopt=skip_system_repo_lock=True"* ]]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: DNF5 5.4 refuses a missing lock capability" {
  run run_maintenance_zsh '
    _sys_dnf_resolve_trusted_program() {
      [[ "$1" == "dnf" ]] || return 97
      REPLY="$TEST_MOCK_BIN/dnf"
    }
    _sys_dnf_major_version() {
      REPLY=5
      reply=(5 4 0 0)
    }
    _sys_dnf5_persistdir() {
      REPLY="/var/lib/dnf"
      reply=("$REPLY" 0)
    }
    _sys_run_with_timeout() {
      print -r -- "unexpected-preview:${(j: :)@}" \
        >> "$MAINT_MUTATION_LOG"
      return 97
    }
    _sys_dnf5_run_guarded() {
      print -r -- "unexpected-guard:${(j: :)@}" \
        >> "$MAINT_MUTATION_LOG"
      return 97
    }
    _sys_dnf5_run_without_system_lock() {
      print -r -- "unexpected-fallback:${(j: :)@}" \
        >> "$MAINT_MUTATION_LOG"
      return 97
    }

    _sys_update_platform_packages 1
  ' dnf

  [ "$status" -eq 1 ]
  [[ "$output" == *"did not expose its required"* ]]
  [ ! -s "$MAINT_MUTATION_LOG" ]
  [ ! -s "$MAINT_PLATFORM_LOG" ]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: DNF5 wrapper drops hostile raw environment and secrets" {
  export HTTP_PROXY="https://caller-proxy-secret.invalid:8443"
  export FTP_PROXY="ftp://caller-ftp-secret.invalid:2121"
  export BASH_ENV="$TEST_TEMP_DIR/caller-bash-env-secret"
  export ENV="$TEST_TEMP_DIR/caller-env-secret"
  export ZDOTDIR="$TEST_TEMP_DIR/caller-zdotdir-secret"
  export PYTHONPATH="$TEST_TEMP_DIR/caller-python-secret"
  export DNF5_PLUGINS_DIR="$TEST_TEMP_DIR/caller-dnf-plugin-secret"
  dnf_raw_secret_hook() { return 97; }
  export -f dnf_raw_secret_hook

  run run_maintenance_zsh '
    _sys_dnf_resolve_trusted_program() {
      case "$1" in
        zsh) REPLY="/usr/bin/zsh" ;;
        env) REPLY="/usr/bin/env" ;;
        *) return 97 ;;
      esac
    }
    _capture_dnf5_fallback() {
      [[ $# -eq 20 \
        && "$1" == "/usr/bin/env" \
        && "$2" == "-i" \
        && "$3" == "HOME=/nonexistent" \
        && "$4" == "XDG_CACHE_HOME=/nonexistent" \
        && "$5" == "XDG_CONFIG_HOME=/nonexistent" \
        && "$6" == "XDG_DATA_HOME=/nonexistent" \
        && "$7" == "LC_ALL=C" \
        && "$8" == "PATH=/usr/sbin:/usr/bin:/sbin:/bin" \
        && "$9" == "TERM=dumb" \
        && "$10" == "DNF5_FORCE_INTERACTIVE=0" \
        && "$11" == "PYTHONNOUSERSITE=1" \
        && "$12" == "/usr/bin/zsh" \
        && "$13" == "-fc" \
        && "$15" == "zdx-dnf5-runner" \
        && "$16" == 0 \
        && -z "$17" \
        && "$18" == "/var/lib/dnf" \
        && "$19" == "/usr/bin/dnf5" \
        && "$20" == "/usr/bin/env" \
        && "${(j: :)@}" != *"caller-proxy-secret"* \
        && "${(j: :)@}" != *"caller-ftp-secret"* \
        && "${(j: :)@}" != *"dnf_raw_secret_hook"* ]] || return 97
      local wrapper_source="$14"
      local dollar=\$
      [[ "$wrapper_source" != *"caller-proxy-secret"* \
        && "$wrapper_source" != *"caller-ftp-secret"* \
        && "$wrapper_source" != *"dnf_raw_secret_hook"* \
        && "$wrapper_source" != *"http_proxy"* \
        && "$wrapper_source" != *"HTTP_PROXY"* \
        && "$wrapper_source" != *"BASH_FUNC"* \
        && "$wrapper_source" != *"BASH_ENV"* \
        && "$wrapper_source" != *"PYTHONPATH"* \
        && "$wrapper_source" != *"DNF5_PLUGINS_DIR"* \
        && "$wrapper_source" == *"env_program=\"${dollar}5\""* \
        && "$wrapper_source" == *"[[ -f \"${dollar}env_program\""* \
        && "$wrapper_source" == *"\"${dollar}env_program\" -i HOME=/nonexistent"* \
        && "$wrapper_source" == *"DNF5_FORCE_INTERACTIVE=0 PYTHONNOUSERSITE=1"* \
        && "$wrapper_source" == *"--installroot=/"*"--setopt=persistdir="*\
"--assumeyes --refresh upgrade"* \
        && "$wrapper_source" == *"</dev/null"* ]] || return 97
      print -r -- "fallback:ok" >> "$MAINT_MUTATION_LOG"
    }

    (( ! ${+functions[_sys_dnf_proxy_environment]} )) || return 97
    _sys_dnf5_run_without_system_lock \
      "sudo -n " "/usr/bin/dnf5" "/var/lib/dnf" _capture_dnf5_fallback
  ' dnf

  [ "$status" -eq 0 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = "fallback:ok" ]
  [[ "$output" == *"fixed DNF5 sanitized runner"* ]]
  [[ "$output" == *"env -i <fixed-system-environment>"* ]]
  [[ "$output" == *"--installroot=/ --setopt=persistdir=/var/lib/dnf"* ]]
  [[ "$output" != *"caller-proxy-secret"* ]]
  [[ "$output" != *"caller-ftp-secret"* ]]
  [[ "$output" != *"dnf_raw_secret_hook"* ]]
  [[ "$output" != *"caller-dnf-plugin-secret"* ]]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: DNF5 guard dispatch freezes wrapper and lock argv" {
  run run_maintenance_zsh '
    unset http_proxy https_proxy ftp_proxy no_proxy all_proxy
    unset HTTP_PROXY HTTPS_PROXY FTP_PROXY NO_PROXY ALL_PROXY
    export HTTPS_PROXY="https://guard-proxy-secret.invalid:8443"
    _sys_dnf_resolve_trusted_program() {
      case "$1" in
        zsh) REPLY="/usr/bin/zsh" ;;
        env) REPLY="/usr/bin/env" ;;
        *) return 97 ;;
      esac
    }
    _capture_dnf5_guard() {
      [[ $# -eq 20 \
        && "$1" == "/usr/bin/env" \
        && "$2" == "-i" \
        && "$3" == "HOME=/nonexistent" \
        && "$4" == "XDG_CACHE_HOME=/nonexistent" \
        && "$5" == "XDG_CONFIG_HOME=/nonexistent" \
        && "$6" == "XDG_DATA_HOME=/nonexistent" \
        && "$7" == "LC_ALL=C" \
        && "$8" == "PATH=/usr/sbin:/usr/bin:/sbin:/bin" \
        && "$9" == "TERM=dumb" \
        && "$10" == "DNF5_FORCE_INTERACTIVE=0" \
        && "$11" == "PYTHONNOUSERSITE=1" \
        && "$12" == "/usr/bin/zsh" \
        && "$13" == "-fc" \
        && "$15" == "zdx-dnf5-runner" \
        && "$16" == 1 \
        && "$17" == "/var/lib/dnf/system-repo.lock" \
        && "$18" == "/var/lib/dnf" \
        && "$19" == "/usr/bin/dnf5" \
        && "$20" == "/usr/bin/env" \
        && "$HTTPS_PROXY" == "https://guard-proxy-secret.invalid:8443" \
        && "${(j: :)@}" != *"guard-proxy-secret"* ]] \
        || return 97
      local wrapper_source="$14"
      local dollar=\$
      [[ "$wrapper_source" == *"zsystem flock -t 0"* \
        && "$wrapper_source" != *"zsystem flock -t 0."* \
        && "$wrapper_source" == *"local lock_mode=\"${dollar}1\" lock_path=\"${dollar}2\""* \
        && "$wrapper_source" == *"env_program=\"${dollar}5\""* \
        && "$wrapper_source" == *"\"${dollar}env_program\" -i HOME=/nonexistent"* \
        && "$wrapper_source" == *"--installroot=/"*"--setopt=persistdir="*\
"--setopt=skip_system_repo_lock=True"*"--assumeyes --refresh upgrade"* \
        && "$wrapper_source" == *"</dev/null"* \
        && "$wrapper_source" != *"guard-proxy-secret"* \
        && "$wrapper_source" != *"HTTP_PROXY"* \
        && "$wrapper_source" != *"--skip-file-locks"* ]] \
        || return 97
      print -r -- "wrapper:ok" >> "$MAINT_MUTATION_LOG"
    }

    _sys_dnf5_run_guarded \
      "sudo -n " "/usr/bin/dnf5" "/var/lib/dnf" _capture_dnf5_guard
  ' dnf

  [ "$status" -eq 0 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = "wrapper:ok" ]
  [[ "$output" == *"fixed DNF5 no-wait lock guard"* ]]
  [[ "$output" == *"--installroot=/ --setopt=persistdir=/var/lib/dnf"* ]]
  [[ "$output" != *"guard-proxy-secret"* ]]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: Darwin with Homebrew also dispatches softwareupdate" {
  export MOCK_SUDO_ALLOW="softwareupdate"

  run run_maintenance_zsh '
    _sys_step_applies _sys_update_platform_packages || exit
    _sys_update_platform_packages 1
  ' brew unavailable darwin

  [ "$status" -eq 0 ]
  [[ "$output" == *"Backend:"*"softwareupdate"* ]]
  [[ "$output" == *"Native softwareupdate packages updated"* ]]
  [ "$(cat "$MAINT_PLATFORM_LOG")" = \
    $'softwareupdate --list\nsoftwareupdate --install --all' ]
  if (( EUID == 0 )); then
    [ ! -s "$MOCK_SUDO_LOG" ]
  else
    [ "$(cat "$MOCK_SUDO_LOG")" = \
      "sudo softwareupdate --install --all" ]
  fi
  [ "$(command -v softwareupdate)" = \
    "$TEST_MOCK_BIN/softwareupdate" ]
  [ "$(command -v sudo)" = "$TEST_MOCK_BIN/sudo" ]
  [ ! -s "$MAINT_MUTATION_LOG" ]
  [ ! -s "$MAINT_NETWORK_LOG" ]
  [ ! -s "$MAINT_SHELL_LOG" ]
  [ ! -s "$MAINT_SIGNAL_LOG" ]
}

@test "sys maintenance: native package aggregate dry-run invokes no backend" {
  local backend
  for backend in dnf pacman zypper apk softwareupdate; do
    : > "$MAINT_PLATFORM_LOG"
    : > "$MOCK_SUDO_LOG"

    run run_maintenance_zsh '
      _sys_step_applies() {
        [[ "$1" == "_sys_update_platform_packages" ]]
      }
      update-system --dry-run
    ' "$backend"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Native packages"* ]]
    [ ! -s "$MAINT_PLATFORM_LOG" ]
    [ ! -s "$MOCK_SUDO_LOG" ]
  done

  [ ! -s "$MAINT_NETWORK_LOG" ]
  [ ! -s "$MAINT_SHELL_LOG" ]
  [ ! -s "$MAINT_SIGNAL_LOG" ]
}

@test "sys maintenance: aggregate dispatches every native package backend safely" {
  local backend expected_calls privileged_program
  for backend in dnf pacman zypper apk softwareupdate; do
    : > "$MAINT_PLATFORM_LOG"
    : > "$MOCK_SUDO_LOG"
    export MOCK_SUDO_ALLOW="$backend"
    if [[ "$backend" == "apk" ]]; then
      export APK_WAIT=600
    else
      unset APK_WAIT
    fi
    privileged_program="$backend"
    [[ "$backend" == "dnf" ]] \
      && privileged_program="$TEST_MOCK_BIN/dnf"

    run run_maintenance_zsh '
      _sys_dnf_resolve_trusted_program() {
        [[ "$1" == "dnf" ]] || return 97
        REPLY="$TEST_MOCK_BIN/dnf"
      }
      _sys_dnf_major_version() {
        [[ "$1" == "$TEST_MOCK_BIN/dnf" ]] || return 97
        REPLY=4
      }
      _sys_step_applies() {
        [[ "$1" == "_sys_update_platform_packages" ]]
      }
      update-system --yes
    ' "$backend"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Backend:"*"$backend"* ]]
    [[ "$output" == *"Native $backend packages updated"* ]]
    case "$backend" in
      dnf)
        grep -Fxq -- \
          'dnf --setopt=exit_on_lock=True --setopt=retries=1 -q check-update' \
          "$MAINT_PLATFORM_LOG"
        grep -Fxq -- \
          'dnf --setopt=exit_on_lock=True --setopt=retries=1 -y upgrade --refresh' \
          "$MAINT_PLATFORM_LOG"
        [ "$(grep -c -- '--setopt=exit_on_lock=True' \
          "$MAINT_PLATFORM_LOG")" -eq 2 ]
        [ "$(grep -c -- '--setopt=retries=1' \
          "$MAINT_PLATFORM_LOG")" -eq 2 ]
        expected_calls=2
        ;;
      pacman)
        grep -Fxq -- 'pacman -Qu' "$MAINT_PLATFORM_LOG"
        grep -Fxq -- 'pacman -Syu --noconfirm' "$MAINT_PLATFORM_LOG"
        expected_calls=2
        ;;
      zypper)
        grep -Fxq -- \
          'zypper --non-interactive list-updates' "$MAINT_PLATFORM_LOG"
        grep -Fxq -- \
          'zypper --non-interactive refresh' "$MAINT_PLATFORM_LOG"
        grep -Fxq -- \
          'zypper --non-interactive update -y' "$MAINT_PLATFORM_LOG"
        expected_calls=3
        ;;
      apk)
        grep -Fxq -- 'apk version -l \<' "$MAINT_PLATFORM_LOG"
        grep -Fxq -- 'apk --wait 0 update' "$MAINT_PLATFORM_LOG"
        grep -Fxq -- 'apk --wait 0 upgrade' "$MAINT_PLATFORM_LOG"
        expected_calls=3
        ;;
      softwareupdate)
        grep -Fxq -- 'softwareupdate --list' "$MAINT_PLATFORM_LOG"
        grep -Fxq -- \
          'softwareupdate --install --all' "$MAINT_PLATFORM_LOG"
        expected_calls=2
        ;;
    esac
    [ "$(wc -l < "$MAINT_PLATFORM_LOG")" -eq "$expected_calls" ]
    [ "$(command -v "$backend")" = "$TEST_MOCK_BIN/$backend" ]
    [ "$(command -v sudo)" = "$TEST_MOCK_BIN/sudo" ]
    if (( EUID == 0 )); then
      [ ! -s "$MOCK_SUDO_LOG" ]
    else
      [ "$(wc -l < "$MOCK_SUDO_LOG")" -eq "$expected_calls" ]
      grep -Fxq -- "sudo -n true" "$MOCK_SUDO_LOG"
      while IFS= read -r sudo_call; do
        [[ "$sudo_call" == "sudo -n true" \
          || "$sudo_call" == "sudo -n $privileged_program"* ]] || return 1
      done < "$MOCK_SUDO_LOG"
      [[ "$output" == *"Privileged operation: sudo -n $privileged_program"* ]]
    fi
  done

  [ ! -s "$MAINT_MUTATION_LOG" ]
  [ ! -s "$MAINT_NETWORK_LOG" ]
  [ ! -s "$MAINT_SHELL_LOG" ]
  [ ! -s "$MAINT_SIGNAL_LOG" ]
}

@test "sys maintenance: aggregate forwards only explicit consent to native step" {
  run run_maintenance_zsh '
    _sys_step_applies() {
      [[ "$1" == "_sys_update_platform_packages" ]]
    }
    _sys_update_platform_packages() {
      print -r -- "$1" >> "$MAINT_MUTATION_LOG"
    }
    _sys_update_preauthenticate() { REPLY=0; }
    update-system --yes --safe-only
  '

  [ "$status" -eq 0 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = "1" ]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: aggregate update includes every applicable step by default" {
  run run_maintenance_zsh '
    _sys_step_applies() {
      case "$1" in
        update-uv-system|update-fzf|update-omz|update-zsh-plugins|_sys_update_ai_tools)
          return 0 ;;
        *) return 1 ;;
      esac
    }
    _sys_test_pkg_manager() { return 0; }
    update-uv-system() {
      print -r -- "safe:update-uv-system" >> "$MAINT_MUTATION_LOG"
    }
    update-fzf() {
      print -r -- "remote:update-fzf" >> "$MAINT_MUTATION_LOG"
    }
    update-omz() {
      print -r -- "remote:update-omz" >> "$MAINT_MUTATION_LOG"
    }
    update-zsh-plugins() {
      print -r -- "remote:update-zsh-plugins" >> "$MAINT_MUTATION_LOG"
    }
    _sys_update_ai_load_owner() {
      return 0
    }
    ai-menu() {
      print -r -- "remote:ai-menu:${(j: :)@}" >> "$MAINT_MUTATION_LOG"
      _test_ai_result_report skipped not-installed 0
    }
    update-system --yes
  '

  [ "$status" -eq 0 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = \
    $'remote:update-fzf\nsafe:update-uv-system\nremote:ai-menu:ai-update --skip-homebrew-managed --result-tsv --yes\nremote:update-omz\nremote:update-zsh-plugins' ]
  [[ "$output" == *"AI assistants"* ]]
  [[ "$output" == *"Oh My Zsh"* ]]
  [[ "$output" == *"Zsh Plugins"* ]]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: aggregate executes exactly the entries it authorized" {
  run run_maintenance_zsh '
    typeset -i applicability_calls=0
    _sys_step_applies() {
      (( ++applicability_calls ))
      if (( applicability_calls <= 16 )); then
        [[ "$1" == "update-uv-system" ]]
      else
        [[ "$1" == "update-pipx" ]]
      fi
    }
    update-uv-system() {
      print -r -- "authorized:update-uv-system" >> "$MAINT_MUTATION_LOG"
    }
    update-pipx() {
      print -r -- "unauthorized:update-pipx" >> "$MAINT_MUTATION_LOG"
      return 97
    }

    update-system --yes
  '

  [ "$status" -eq 0 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = "authorized:update-uv-system" ]
  [[ "$output" == *"uv"* ]]
  [[ "$output" != *"pipx"* ]]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: aggregate update steps receive closed stdin" {
  run run_maintenance_zsh '
    _sys_step_applies() { [[ "$1" == "update-uv-system" ]]; }
    update-uv-system() {
      local unexpected_input=""
      if IFS= read -r unexpected_input; then
        print -r -- "unexpected-input:$unexpected_input" \
          >> "$MAINT_MUTATION_LOG"
        return 97
      fi
      print -r -- "stdin:closed" >> "$MAINT_MUTATION_LOG"
    }

    update-system --yes --safe-only <<< "untrusted-input"
  '

  [ "$status" -eq 0 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = "stdin:closed" ]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: one interactive aggregate authorization covers every step" {
  command -v script >/dev/null || skip "util-linux script is unavailable"

  run script -qefc \
    "zsh -fc 'source \"$TEST_SUITE_ROOT/functions/sys-menu.zsh\" || exit 98
_sys_capabilities_refresh_for_command() { return 0 }
_sys_step_applies() { [[ \"\$1\" == \"update-fzf\" ]] }
update-fzf() { print -r -- \"fzf:\${(j: :)@}\" >> \"\$MAINT_MUTATION_LOG\" }
_sys_confirm() { return 0 }
NO_COLOR=1 update-system'" \
    /dev/null

  [ "$status" -eq 0 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = "fzf:--yes" ]
  [[ "$output" == *"Aggregate plan authorized"* ]]
  [[ "$output" == *"System update completed successfully"* ]]
}

@test "sys maintenance: Git-owned updates cannot prompt and bound stalled transfers" {
  local omz_repo="$HOME/.oh-my-zsh"
  create_maintenance_git_repo \
    "$omz_repo" 'https://example.invalid/ohmyzsh.git'
  export MAINT_OMZ_REPO="$omz_repo"

  run run_maintenance_zsh '
    export ZSH="$MAINT_OMZ_REPO"
    export GIT_SSH_COMMAND=""
    _sys_run_logged() {
      {
        print -r -- "prompt:${GIT_TERMINAL_PROMPT:-unset}"
        print -r -- "ssh:${GIT_SSH_COMMAND:-unset}"
        print -r -- "askpass:${GIT_ASKPASS-unset}:${SSH_ASKPASS-unset}"
        print -r -- "cfg:${GIT_CONFIG_COUNT:-0}:${GIT_CONFIG_KEY_0:-}=${GIT_CONFIG_VALUE_0:-}:${GIT_CONFIG_KEY_1:-}=${GIT_CONFIG_VALUE_1:-}"
      } >> "$MAINT_MUTATION_LOG"
      return 0
    }
    update-omz --yes
  '

  [ "$status" -eq 0 ]
  grep -Fxq -- "prompt:0" "$MAINT_MUTATION_LOG"
  grep -Fq -- "ssh:ssh -o BatchMode=yes -o ConnectTimeout=15" \
    "$MAINT_MUTATION_LOG"
  grep -Fxq -- "askpass:unset:unset" "$MAINT_MUTATION_LOG"
  grep -Fxq -- \
    "cfg:2:http.lowSpeedLimit=1024:http.lowSpeedTime=60" \
    "$MAINT_MUTATION_LOG"
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: a caller-provided Git SSH command is preserved" {
  local omz_repo="$HOME/.oh-my-zsh"
  create_maintenance_git_repo \
    "$omz_repo" 'https://example.invalid/ohmyzsh.git'
  export MAINT_OMZ_REPO="$omz_repo"

  run run_maintenance_zsh '
    export ZSH="$MAINT_OMZ_REPO"
    export GIT_SSH_COMMAND="ssh -F $HOME/custom-ssh-config"
    _sys_run_logged() {
      print -r -- "ssh:${GIT_SSH_COMMAND:-unset}" >> "$MAINT_MUTATION_LOG"
      return 0
    }
    update-omz --yes
  '

  [ "$status" -eq 0 ]
  grep -Fxq -- "ssh:ssh -F $HOME/custom-ssh-config" "$MAINT_MUTATION_LOG"
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: privileged plans pre-authenticate sudo once when promptable" {
  cat <<'EOF' > "$TEST_MOCK_BIN/sudo"
#!/usr/bin/env bash
{
  printf 'sudo'
  printf ' %q' "$@"
  printf '\n'
} >> "$MOCK_SUDO_LOG"
[[ "$1" == "-n" ]] && exit 1
[[ "$1" == "-v" ]] && exit 0
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/sudo"

  run run_maintenance_zsh '
    _sys_update_can_prompt() { return 0 }
    _sys_update_preauthenticate \
      "APT;update-apt" "uv;update-uv-system"
  ' apt

  [ "$status" -eq 0 ]
  grep -Fxq -- "sudo -n true" "$MOCK_SUDO_LOG"
  [ "$(grep -Fxc -- "sudo -v" "$MOCK_SUDO_LOG")" -eq 1 ]
  [[ "$output" == *"authenticate once"* ]]
  [ ! -s "$MAINT_MUTATION_LOG" ]
  [ ! -s "$MAINT_SIGNAL_LOG" ]
}

@test "sys maintenance: one interactive sudo authorization covers aggregate APT" {
  (( EUID != 0 )) || skip "sudo prefix is not used for direct-root execution"
  export MOCK_APT_MUTATIONS_SUCCEED=1
  export MOCK_SUDO_ALLOW="__validate__,apt-get,env"

  run run_maintenance_zsh '
    _sys_step_applies() { [[ "$1" == "update-apt" ]]; }
    _sys_package_manager_busy() { return 1; }
    _sys_apt_dpkg_state_clean() { return 0; }
    _sys_update_can_prompt() { return 0; }
    update-system --yes --safe-only
  ' apt

  [ "$status" -eq 0 ]
  [ -s "$MOCK_SUDO_LOG" ]
  [ "$(grep -Fxc -- 'sudo -n true' "$MOCK_SUDO_LOG")" -eq 1 ]
  [ "$(grep -Fxc -- 'sudo -v' "$MOCK_SUDO_LOG")" -eq 1 ]
  grep -Fxq -- 'sudo -n -v' "$MOCK_SUDO_LOG"
  if grep -vFx -- 'sudo -v' "$MOCK_SUDO_LOG" \
    | grep -Evq -- '^sudo -n '; then
    return 1
  fi
  grep -Fxq -- "$(expected_sudo_apt_call update)" "$MOCK_SUDO_LOG"
  grep -Fxq -- \
    "$(expected_sudo_apt_call full-upgrade -y)" "$MOCK_SUDO_LOG"
  grep -Fxq -- \
    "$(expected_sudo_apt_call autoremove -y)" "$MOCK_SUDO_LOG"
}

@test "sys maintenance: sudo refresher stops after the last privileged step" {
  run run_maintenance_zsh '
    _sys_step_applies() {
      [[ "$1" == "update-apt" || "$1" == "update-snap" \
        || "$1" == "update-uv-system" ]]
    }
    _sys_apt_plan_blocker() { REPLY=""; }
    _sys_update_preauthenticate() {
      print -r -- "preauthenticate" >> "$MAINT_MUTATION_LOG"
      REPLY=1
    }
    _sys_update_start_sudo_keepalive() {
      [[ "$1" == 1 ]] || return 97
      print -r -- "keepalive:start" >> "$MAINT_MUTATION_LOG"
      REPLY=4242
    }
    _sys_update_stop_sudo_keepalive() {
      [[ "$1" == 4242 ]] || return 97
      print -r -- "keepalive:stop" >> "$MAINT_MUTATION_LOG"
    }
    update-apt() {
      print -r -- "update-apt" >> "$MAINT_MUTATION_LOG"
    }
    update-snap() {
      print -r -- "update-snap" >> "$MAINT_MUTATION_LOG"
    }
    update-uv-system() {
      print -r -- "update-uv-system" >> "$MAINT_MUTATION_LOG"
    }

    update-system --yes --safe-only
  ' apt

  [ "$status" -eq 0 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = \
    $'preauthenticate\nkeepalive:start\nupdate-apt\nupdate-snap\nkeepalive:stop\nupdate-uv-system' ]
  [ "$(grep -c '^keepalive:start$' "$MAINT_MUTATION_LOG")" -eq 1 ]
  [ "$(grep -c '^keepalive:stop$' "$MAINT_MUTATION_LOG")" -eq 1 ]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: Darwin Homebrew keeps sudo refresh active through its step" {
  (( EUID != 0 )) || skip "sudo preauthentication is not used as root"
  export MOCK_SUDO_ALLOW="true"

  run run_maintenance_zsh '
    _sys_update_step_requires_privilege update-brew || return 97
    _sys_step_applies() {
      [[ "$1" == "update-brew" || "$1" == "update-uv-system" ]]
    }
    _sys_update_start_sudo_keepalive() {
      [[ "$1" == 1 ]] || return 97
      print -r -- "keepalive:start" >> "$MAINT_MUTATION_LOG"
      REPLY=4242
    }
    _sys_update_stop_sudo_keepalive() {
      [[ "$1" == 4242 ]] || return 97
      print -r -- "keepalive:stop" >> "$MAINT_MUTATION_LOG"
    }
    update-brew() {
      print -r -- "update-brew" >> "$MAINT_MUTATION_LOG"
    }
    update-uv-system() {
      print -r -- "update-uv-system" >> "$MAINT_MUTATION_LOG"
    }

    update-system --yes --safe-only
  ' brew unavailable darwin

  [ "$status" -eq 0 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = \
    $'keepalive:start\nupdate-brew\nkeepalive:stop\nupdate-uv-system' ]
  [ "$(cat "$MOCK_SUDO_LOG")" = "sudo -n true" ]
  [ ! -s "$MAINT_SIGNAL_LOG" ]
  [ ! -s "$MAINT_NETWORK_LOG" ]
  [ ! -s "$MAINT_SHELL_LOG" ]
}

@test "sys maintenance: Linuxbrew does not require sudo or a refresher" {
  run run_maintenance_zsh '
    if _sys_update_step_requires_privilege update-brew; then
      print -r -- "unexpected:privileged" >> "$MAINT_MUTATION_LOG"
      return 97
    fi
    _sys_step_applies() { [[ "$1" == "update-brew" ]]; }
    _sys_update_start_sudo_keepalive() {
      print -r -- "unexpected:keepalive" >> "$MAINT_MUTATION_LOG"
      return 97
    }
    update-brew() {
      print -r -- "update-brew" >> "$MAINT_MUTATION_LOG"
    }

    update-system --yes --safe-only
  ' brew

  [ "$status" -eq 0 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = "update-brew" ]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: Homebrew preauthentication guidance is platform-specific" {
  (( EUID != 0 )) || skip "sudo preauthentication is not used as root"
  export MOCK_SUDO_ALLOW="__validate__"

  run run_maintenance_zsh '
    _sys_update_can_prompt() { return 0; }
    _sys_update_preauthenticate \
      "APT;update-apt" "Homebrew;update-brew"
  ' apt unavailable linux

  [ "$status" -eq 0 ]
  [[ "$output" == *"Later ZDX privilege calls use sudo -n."* ]]
  [[ "$output" != *"macOS Homebrew cask operations"* ]]

  : > "$MOCK_SUDO_LOG"
  run run_maintenance_zsh '
    _sys_update_can_prompt() { return 0; }
    _sys_update_preauthenticate \
      "Native packages;_sys_update_platform_packages" \
      "Homebrew;update-brew"
  ' brew unavailable darwin

  [ "$status" -eq 0 ]
  [[ "$output" == *"Later ZDX privilege calls use sudo -n."* ]]
  [[ "$output" == \
    *"macOS Homebrew cask operations use a fixed non-interactive askpass guard."* ]]
  [ "$(grep -Fxc -- 'sudo -v' "$MOCK_SUDO_LOG")" -eq 1 ]
}

@test "sys maintenance: fail-fast always cleans up the sudo refresher" {
  run run_maintenance_zsh '
    _sys_step_applies() {
      [[ "$1" == "update-apt" || "$1" == "update-snap" ]]
    }
    _sys_apt_plan_blocker() { REPLY=""; }
    _sys_update_preauthenticate() {
      print -r -- "preauthenticate" >> "$MAINT_MUTATION_LOG"
      REPLY=1
    }
    _sys_update_start_sudo_keepalive() {
      [[ "$1" == 1 ]] || return 97
      print -r -- "keepalive:start" >> "$MAINT_MUTATION_LOG"
      REPLY=4242
    }
    _sys_update_stop_sudo_keepalive() {
      [[ "$1" == 4242 ]] || return 97
      print -r -- "keepalive:stop" >> "$MAINT_MUTATION_LOG"
    }
    update-apt() {
      print -r -- "update-apt" >> "$MAINT_MUTATION_LOG"
      return 41
    }
    update-snap() {
      print -r -- "unexpected:update-snap" >> "$MAINT_MUTATION_LOG"
      return 97
    }

    update-system --fail-fast --yes --safe-only
  ' apt

  [ "$status" -eq 1 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = \
    $'preauthenticate\nkeepalive:start\nupdate-apt\nkeepalive:stop' ]
  [ "$(grep -c '^keepalive:start$' "$MAINT_MUTATION_LOG")" -eq 1 ]
  [ "$(grep -c '^keepalive:stop$' "$MAINT_MUTATION_LOG")" -eq 1 ]
  [[ "$output" == *"Aborting after first failure (--fail-fast): APT"* ]]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: a failed sudo refresh is not retried and its sentinel is cleaned" {
  (( EUID != 0 )) || skip "sudo refresher is not used as root"
  export KEEPALIVE_READY_FIFO="$TEST_TEMP_DIR/keepalive-ready.fifo"
  export KEEPALIVE_RELEASE_FIFO="$TEST_TEMP_DIR/keepalive-release.fifo"
  mkfifo "$KEEPALIVE_READY_FIFO" "$KEEPALIVE_RELEASE_FIFO"

  cat <<'EOF' > "$TEST_MOCK_BIN/sudo"
#!/usr/bin/env bash
{
  printf 'sudo'
  printf ' %q' "$@"
  printf '\n'
} >> "$MOCK_SUDO_LOG"

if [[ "$*" == "-n -v" ]]; then
  refresh_count=$(grep -Fxc -- 'sudo -n -v' "$MOCK_SUDO_LOG")
  [[ "$refresh_count" -eq 1 ]]
  exit
fi
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/sudo"

  run run_maintenance_zsh '
    typeset -gi test_keepalive_waits=0
    _sys_update_sudo_keepalive_wait() {
      (( ++test_keepalive_waits ))
      if (( test_keepalive_waits > 3 )); then
        zselect -r 0 -t 3000 2>/dev/null
        return $?
      fi
      print -r -- ready > "$KEEPALIVE_READY_FIFO"
      local release=""
      IFS= read -r release < "$KEEPALIVE_RELEASE_FIFO"
      print -r -- "pause:$release" >> "$MAINT_MUTATION_LOG"
      return 1
    }
    _test_failed_refresh_lifecycle() {
      local keepalive_handle=""
      _sys_update_start_sudo_keepalive 1 || return $?
      keepalive_handle="$REPLY"
      [[ "$keepalive_handle" \
        =~ '^zdx-sudo-keepalive-[0-9]+-[0-9]+-[0-9]+$' ]] || return 97

      {
        local ready=""
        IFS= read -r ready < "$KEEPALIVE_READY_FIFO" || return 97
        [[ "$ready" == ready ]] || return 97
        print -r -- one > "$KEEPALIVE_RELEASE_FIFO" || return 97
        IFS= read -r ready < "$KEEPALIVE_READY_FIFO" || return 97
        [[ "$ready" == ready ]] || return 97
        print -r -- two > "$KEEPALIVE_RELEASE_FIFO" || return 97
        IFS= read -r ready < "$KEEPALIVE_READY_FIFO" || return 97
        [[ "$ready" == ready ]] || return 97
        zpty -t "$keepalive_handle" 2>/dev/null || return 97
        print -r -- "sentinel:alive" >> "$MAINT_MUTATION_LOG"
        print -r -- three > "$KEEPALIVE_RELEASE_FIFO" || return 97
      } always {
        _sys_update_stop_sudo_keepalive "$keepalive_handle" || true
      }

      zpty -t "$keepalive_handle" 2>/dev/null && return 97
      print -r -- "sentinel:stopped" >> "$MAINT_MUTATION_LOG"
    }

    _test_failed_refresh_lifecycle
  '

  [ "$status" -eq 0 ]
  [ "$(grep -Fxc -- 'sudo -n -v' "$MOCK_SUDO_LOG")" -eq 2 ]
  [ "$(grep -c '^pause:' "$MAINT_MUTATION_LOG")" -eq 3 ]
  grep -Fxq -- "sentinel:alive" "$MAINT_MUTATION_LOG"
  grep -Fxq -- "sentinel:stopped" "$MAINT_MUTATION_LOG"
  [ ! -s "$MAINT_SIGNAL_LOG" ]
  [ ! -s "$MAINT_NETWORK_LOG" ]
  [ ! -s "$MAINT_SHELL_LOG" ]
}

@test "sys maintenance: interactive sudo keepalive has no job completion UI" {
  (( EUID != 0 )) || skip "sudo refresher is not used as root"
  command -v script >/dev/null || skip "util-linux script is unavailable"

  cat <<'EOF' > "$TEST_MOCK_BIN/sudo"
#!/usr/bin/env bash
{
  printf 'sudo'
  printf ' %q' "$@"
  printf '\n'
} >> "$MOCK_SUDO_LOG"
[[ "$*" == "-n -v" ]]
EOF
  chmod +x "$TEST_MOCK_BIN/sudo"

  export ZDX_KEEPALIVE_PTY_CODE='
    source "$TEST_SUITE_ROOT/functions/sys-menu.zsh" || exit 98
    _SYS_CAPABILITIES=(
      architecture x86_64
      environment native
      os linux
      package_manager apt
      privilege sudo
    )
    _SYS_CAPABILITIES_READY=1
    _sys_has_capability() {
      [[ "$1" == "privilege:sudo" ]]
    }
    command() {
      if [[ "${1:-}" == "-v" && "${2:-}" == "sudo" ]]; then
        print -r -- "$TEST_MOCK_BIN/sudo"
        return 0
      fi
      if [[ "${1:-}" == "sudo" ]]; then
        shift
        "$TEST_MOCK_BIN/sudo" "$@"
        return $?
      fi
      builtin command "$@"
    }

    _sys_update_start_sudo_keepalive 1 || return $?
    keepalive_handle="$REPLY"
    zmodload zsh/zpty || return 97
    zpty -t "$keepalive_handle" 2>/dev/null || return 96

    print -r -- PTY_JOBS_BEFORE_BEGIN
    jobs -p
    print -r -- PTY_JOBS_BEFORE_END

    _sys_update_stop_sudo_keepalive "$keepalive_handle" || return 95
    zpty -t "$keepalive_handle" 2>/dev/null && return 94

    print -r -- PTY_JOBS_AFTER_BEGIN
    jobs -p
    print -r -- PTY_JOBS_AFTER_END
    print -r -- PTY_AFTER
  '

  run script -qefc 'NO_COLOR=1 zsh -fic "$ZDX_KEEPALIVE_PTY_CODE"' \
    /dev/null

  [ "$status" -eq 0 ]
  local pty_output="${output//$'\r'/}"
  [[ "$pty_output" == \
    *$'PTY_JOBS_BEFORE_BEGIN\nPTY_JOBS_BEFORE_END'* ]]
  [[ "$pty_output" == \
    *$'PTY_JOBS_AFTER_BEGIN\nPTY_JOBS_AFTER_END'* ]]
  [[ "$pty_output" == *"PTY_AFTER"* ]]
  [[ "$pty_output" != *"refresh_enabled=1"* ]]
  if grep -Eq '^\[[0-9]+\].*(terminated|done|running)' \
    <<< "$pty_output"; then
    return 1
  fi
  [ "$(cat "$MOCK_SUDO_LOG")" = "sudo -n -v" ]
  [ ! -s "$MAINT_SIGNAL_LOG" ]
  [ ! -s "$MAINT_NETWORK_LOG" ]
  [ ! -s "$MAINT_SHELL_LOG" ]
}

@test "sys maintenance: unprivileged plans skip sudo and unpromptable plans only probe" {
  run run_maintenance_zsh '
    _sys_update_can_prompt() { return 0 }
    _sys_update_preauthenticate "uv;update-uv-system"
  ' apt

  [ "$status" -eq 0 ]
  assert_no_privilege_network_or_signal

  run run_maintenance_zsh '
    _sys_update_preauthenticate "APT;update-apt"
  ' apt

  [ "$status" -eq 0 ]
  if (( EUID == 0 )); then
    [ ! -s "$MOCK_SUDO_LOG" ]
  else
    [ "$(cat "$MOCK_SUDO_LOG")" = "sudo -n true" ]
  fi
  [[ "$output" != *"sudo -v"* ]]
  [ ! -s "$MAINT_NETWORK_LOG" ]
  [ ! -s "$MAINT_SHELL_LOG" ]
  [ ! -s "$MAINT_SIGNAL_LOG" ]
}

@test "sys maintenance: a stalled Homebrew metadata refresh fails the step visibly" {
  cat <<'EOF' > "$TEST_MOCK_BIN/brew"
#!/usr/bin/env bash
exit 96
EOF
  chmod +x "$TEST_MOCK_BIN/brew"

  run run_maintenance_zsh '
    _sys_brew_askpass_program() { REPLY="/usr/bin/false"; }
    _sys_run_with_timeout() {
      [[ "$1" == 120 \
        && "$2" == "$TEST_MOCK_BIN/brew" \
        && "$3" == "update" \
        && $# -eq 3 \
        && "$HOMEBREW_CURL_RETRIES" == 0 \
        && "$HOMEBREW_NO_ANALYTICS" == 1 \
        && "$SUDO_ASKPASS" == "/usr/bin/false" ]] || return 97
      print -r -- "bounded:$1:${(j: :)@[2,-1]}" >> "$MAINT_MUTATION_LOG"
      return 124
    }
    update-brew
  ' brew unavailable darwin

  [ "$status" -eq 1 ]
  [[ "$output" == *"timed out after 120s"* ]]
  [ "$(cat "$MAINT_MUTATION_LOG")" = \
    "bounded:120:$TEST_MOCK_BIN/brew update" ]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: Darwin Homebrew fails closed without its askpass guard" {
  cat <<'EOF' > "$TEST_MOCK_BIN/brew"
#!/usr/bin/env bash
printf 'unexpected-brew %s\n' "$*" >> "$MAINT_MUTATION_LOG"
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/brew"

  run run_maintenance_zsh '
    _sys_brew_askpass_program() {
      print -r -- "askpass:unavailable" >> "$MAINT_MUTATION_LOG"
      return 1
    }
    update-brew
  ' brew unavailable darwin

  [ "$status" -eq 1 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = "askpass:unavailable" ]
  [[ "$output" == *"askpass guard is unavailable"* ]]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: Linuxbrew skips askpass and upgrades with no-ask" {
  cat <<'EOF' > "$TEST_MOCK_BIN/brew"
#!/usr/bin/env bash
unexpected_input=""
if IFS= read -r unexpected_input; then
  printf 'unexpected-input:%s\n' "$unexpected_input" >> "$MAINT_MUTATION_LOG"
  exit 98
fi
{
  printf 'brew'
  printf ' %q' "$@"
  printf ' | curl=%s analytics=%s auto=%s askpass=%s\n' \
    "${HOMEBREW_CURL_RETRIES-unset}" \
    "${HOMEBREW_NO_ANALYTICS-unset}" \
    "${HOMEBREW_NO_AUTO_UPDATE-unset}" \
    "${SUDO_ASKPASS-unset}"
} >> "$MAINT_MUTATION_LOG"
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/brew"

  export HOMEBREW_CURL_RETRIES=99
  export HOMEBREW_NO_ANALYTICS=0
  export HOMEBREW_NO_AUTO_UPDATE=1
  export SUDO_ASKPASS="$TEST_TEMP_DIR/host-askpass"

  run run_maintenance_zsh '
    brew() {
      print -r -- "unexpected:brew-function:$*" >> "$MAINT_MUTATION_LOG"
      return 97
    }
    env() {
      print -r -- "unexpected:env-function:$*" >> "$MAINT_MUTATION_LOG"
      return 97
    }
    _sys_brew_askpass_program() {
      print -r -- "unexpected:askpass-guard" >> "$MAINT_MUTATION_LOG"
      return 97
    }
    update-brew <<< "untrusted-brew-input"
  ' brew

  [ "$status" -eq 0 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = \
    $'brew update | curl=0 analytics=1 auto=unset askpass=unset\nbrew upgrade --no-ask | curl=0 analytics=1 auto=1 askpass=unset\nbrew autoremove | curl=0 analytics=1 auto=1 askpass=unset\nbrew cleanup | curl=0 analytics=1 auto=1 askpass=unset' ]
  [[ "$output" == *"Homebrew updated"* ]]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: Homebrew-owned AWS and Starship upgrades use no-ask" {
  cat <<'EOF' > "$TEST_MOCK_BIN/brew"
#!/usr/bin/env bash
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/brew"

  run run_maintenance_zsh '
    _sys_brew() {
      print -r -- "${(j: :)@}" >> "$MAINT_MUTATION_LOG"
      case "${1:-}" in
        list) return 0 ;;
        upgrade)
          [[ "${2:-}" == "--no-ask" \
            && ( "${3:-}" == "awscli" || "${3:-}" == "starship" ) \
            && $# -eq 3 ]]
          ;;
        *) return 97 ;;
      esac
    }

    update-awscli || return $?
    update-starship
  ' brew

  [ "$status" -eq 0 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = \
    $'list awscli\nupgrade --no-ask awscli\nlist starship\nupgrade --no-ask starship' ]
  [[ "$output" == *"AWS CLI updated through Homebrew"* ]]
  [[ "$output" == *"Starship updated through Homebrew"* ]]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: a Homebrew uv formula does not hide the active user uv" {
  export MOCK_UV_BREW_PREFIX="$TEST_TEMP_DIR/homebrew"
  mkdir -p \
    "$MOCK_UV_BREW_PREFIX/Cellar/uv/9.9.9/bin" \
    "$MOCK_UV_BREW_PREFIX/bin" \
    "$HOME/.local/bin"

  cat <<'EOF' > "$TEST_MOCK_BIN/brew"
#!/usr/bin/env bash
set -u
case "$*" in
  "--prefix") printf '%s\n' "$MOCK_UV_BREW_PREFIX" ;;
  *) exit 97 ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/brew"

  cat <<'EOF' > "$MOCK_UV_BREW_PREFIX/Cellar/uv/9.9.9/bin/uv"
#!/usr/bin/env bash
printf 'unexpected-brew-uv:%s\n' "$*" >> "$MAINT_MUTATION_LOG"
exit 97
EOF
  chmod +x "$MOCK_UV_BREW_PREFIX/Cellar/uv/9.9.9/bin/uv"
  ln -s \
    "$MOCK_UV_BREW_PREFIX/Cellar/uv/9.9.9/bin/uv" \
    "$MOCK_UV_BREW_PREFIX/bin/uv"

  cat <<'EOF' > "$HOME/.local/bin/uv"
#!/usr/bin/env bash
set -u
if [[ "${1:-}" == "--version" ]]; then
  printf '%s\n' 'uv 1.2.3'
  exit 0
fi
printf 'user-uv:%s | retries=%s\n' \
  "$*" "${UV_HTTP_RETRIES-unset}" >> "$MAINT_MUTATION_LOG"
[[ "$*" == "self update" ]]
EOF
  chmod +x "$HOME/.local/bin/uv"

  run run_maintenance_zsh '
    PATH="$HOME/.local/bin:$MOCK_UV_BREW_PREFIX/bin:$PATH"
    update-uv-system || return $?
    _sys_step_applies update-uv-system || return 97
    print -r -- "applicable:user-uv" >> "$MAINT_MUTATION_LOG"
  '

  [ "$status" -eq 0 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = \
    $'user-uv:self update | retries=0\napplicable:user-uv' ]
  [[ "$output" == *"uv updated to 1.2.3"* ]]
  [[ "$output" != *"managed by Homebrew"* ]]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: only the active Homebrew uv is assigned to update-brew" {
  export MOCK_UV_BREW_PREFIX="$TEST_TEMP_DIR/homebrew"
  mkdir -p \
    "$MOCK_UV_BREW_PREFIX/Cellar/uv/9.9.9/bin" \
    "$MOCK_UV_BREW_PREFIX/bin"

  cat <<'EOF' > "$TEST_MOCK_BIN/brew"
#!/usr/bin/env bash
set -u
case "$*" in
  "--prefix") printf '%s\n' "$MOCK_UV_BREW_PREFIX" ;;
  "upgrade --no-ask uv")
    printf 'brew:%s\n' "$*" >> "$MAINT_MUTATION_LOG"
    ;;
  *) exit 97 ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/brew"

  cat <<'EOF' > "$MOCK_UV_BREW_PREFIX/Cellar/uv/9.9.9/bin/uv"
#!/usr/bin/env bash
set -u
if [[ "${1:-}" == "--version" ]]; then
  printf '%s\n' 'uv 9.9.9'
  exit 0
fi
printf 'unexpected-self-update:%s\n' "$*" >> "$MAINT_MUTATION_LOG"
exit 97
EOF
  chmod +x "$MOCK_UV_BREW_PREFIX/Cellar/uv/9.9.9/bin/uv"
  ln -s \
    "$MOCK_UV_BREW_PREFIX/Cellar/uv/9.9.9/bin/uv" \
    "$MOCK_UV_BREW_PREFIX/bin/uv"

  run run_maintenance_zsh '
    PATH="$MOCK_UV_BREW_PREFIX/bin:$PATH"
    update-uv-system || return $?
    if _sys_step_applies update-uv-system; then
      print -r -- "unexpected:applicable" >> "$MAINT_MUTATION_LOG"
      return 97
    fi
  '

  [ "$status" -eq 0 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = 'brew:upgrade --no-ask uv' ]
  [[ "$output" == \
    *"The active uv executable is managed by Homebrew"* ]]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: retry-controlled logged updates bypass an env function" {
  local controlled_tool
  for controlled_tool in uv pipx rustup; do
    cat <<'EOF' > "$TEST_MOCK_BIN/$controlled_tool"
#!/usr/bin/env bash
set -u

tool_name="${0##*/}"
if [[ "$tool_name" == "uv" && "${1:-}" == "--version" ]]; then
  printf '%s\n' 'uv 1.2.3'
  exit 0
fi
{
  printf '%s %s' "$tool_name" "$*"
  printf ' | uv=%s pip-input=%s pip-retries=%s rust=%s\n' \
    "${UV_HTTP_RETRIES-unset}" \
    "${PIP_NO_INPUT-unset}" \
    "${PIP_RETRIES-unset}" \
    "${RUSTUP_MAX_RETRIES-unset}"
} >> "$MAINT_MUTATION_LOG"
exit 0
EOF
    chmod +x "$TEST_MOCK_BIN/$controlled_tool"
  done
  cat <<'EOF' > "$TEST_MOCK_BIN/brew"
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$TEST_MOCK_BIN/brew"

  run run_maintenance_zsh '
    env() {
      print -r -- "unexpected:env-function:$*" >> "$MAINT_MUTATION_LOG"
      return 97
    }

    update-uv-system || return $?
    update-pipx || return $?
    update-rust
  '

  [ "$status" -eq 0 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = \
    $'uv self update | uv=0 pip-input=unset pip-retries=unset rust=unset\npipx upgrade-all | uv=unset pip-input=1 pip-retries=0 rust=unset\nrustup update | uv=unset pip-input=unset pip-retries=unset rust=0' ]
  [[ "$output" == *"uv updated to 1.2.3"* ]]
  [[ "$output" == *"pipx packages updated"* ]]
  [[ "$output" == *"Rust toolchain updated"* ]]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: aggregate dry-run forwards AI ownership flags exactly" {
  run run_maintenance_zsh '
    _sys_step_applies() {
      [[ "$1" == "_sys_update_ai_tools" ]]
    }
    _sys_update_ai_load_owner() {
      return 0
    }
    ai-menu() {
      print -r -- "${(j: :)@}" >> "$MAINT_MUTATION_LOG"
      _test_ai_result_report planned eligible 0
    }

    update-system --dry-run --yes
  '

  [ "$status" -eq 0 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = \
    "ai-update --skip-homebrew-managed --result-tsv --dry-run --yes" ]
  [[ "$output" == *"Detailed preview: AI assistants"* ]]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: aggregate remote-code modes are mutually exclusive" {
  run run_maintenance_zsh '
    _sys_capabilities_refresh_for_command() {
      print -r -- "unexpected-capability-probe" >> "$MAINT_MUTATION_LOG"
      return 99
    }
    update-system --safe-only --include-remote-code --yes
  '

  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot be combined"* ]]
  [ ! -s "$MAINT_MUTATION_LOG" ]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: Homebrew ownership deduplicates aggregate tool steps" {
  export MOCK_UV_BREW_PREFIX="$TEST_TEMP_DIR/homebrew"
  mkdir -p "$MOCK_UV_BREW_PREFIX/Cellar/uv/9.9.9/bin"
  cat <<'EOF' > "$TEST_MOCK_BIN/brew"
#!/usr/bin/env bash
{
  printf 'brew'
  printf ' %q' "$@"
  printf '\n'
} >> "$MAINT_PROBE_LOG"
if [[ "$*" == "--prefix" ]]; then
  printf '%s\n' "$MOCK_UV_BREW_PREFIX"
  exit 0
fi
[[ "${1:-}" == "list" ]]
EOF
  chmod +x "$TEST_MOCK_BIN/brew"

  cat <<'EOF' > "$MOCK_UV_BREW_PREFIX/Cellar/uv/9.9.9/bin/uv"
#!/usr/bin/env bash
exit 97
EOF
  chmod +x "$MOCK_UV_BREW_PREFIX/Cellar/uv/9.9.9/bin/uv"
  ln -s "$MOCK_UV_BREW_PREFIX/Cellar/uv/9.9.9/bin/uv" \
    "$TEST_MOCK_BIN/uv"

  mkdir -p "$MOCK_UV_BREW_PREFIX/Cellar/repomix/1.0.0/bin"
  cat <<'EOF' > "$MOCK_UV_BREW_PREFIX/Cellar/repomix/1.0.0/bin/repomix"
#!/usr/bin/env bash
exit 97
EOF
  chmod +x "$MOCK_UV_BREW_PREFIX/Cellar/repomix/1.0.0/bin/repomix"
  ln -s "$MOCK_UV_BREW_PREFIX/Cellar/repomix/1.0.0/bin/repomix" \
    "$TEST_MOCK_BIN/repomix"

  local update_step
  for update_step in \
    update-awscli \
    update-starship \
    update-fzf \
    update-uv-system \
    update-gcloud \
    update-repomix; do
    run run_maintenance_zsh "_sys_step_applies $update_step" brew
    [ "$status" -eq 1 ]
  done

  run run_maintenance_zsh "_sys_step_applies update-brew" brew
  [ "$status" -eq 0 ]
  [ ! -s "$MAINT_MUTATION_LOG" ]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: a Homebrew failure does not cancel later updates" {
  run run_maintenance_zsh '
    _sys_step_applies() {
      [[ "$1" == "update-brew" || "$1" == "update-uv-system" \
        || "$1" == "update-pipx" ]]
    }
    update-brew() {
      print -r -- "update-brew" >> "$MAINT_MUTATION_LOG"
      return 73
    }
    update-uv-system() {
      print -r -- "update-uv-system" >> "$MAINT_MUTATION_LOG"
    }
    update-pipx() {
      print -r -- "update-pipx" >> "$MAINT_MUTATION_LOG"
    }

    update-system --yes
  '

  [ "$status" -eq 1 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = \
    $'update-brew\nupdate-uv-system\nupdate-pipx' ]
  [[ "$output" == *"System update completed with partial failures"* ]]
  [[ "$output" == *"Homebrew"* ]]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: Hermes compatibility command delegates exact arguments" {
  run run_maintenance_zsh '
    [[ -z "$(_sys_cmd_deps update-hermes)" ]] || return 91
    _sys_update_ai_load_owner() {
      return 0
    }
    ai-menu() {
      print -r -- "${(j: :)@}" >> "$MAINT_MUTATION_LOG"
      return 37
    }

    update-hermes --dry-run --yes --skip-homebrew-managed
  '

  [ "$status" -eq 37 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = \
    "ai-update-hermes --dry-run --yes --skip-homebrew-managed" ]
  [[ "$output" == *"compatibility command"* ]]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: Git updater rejects symlink, outside-HOME, and worktree paths" {
  local real_repo="$HOME/real/repository"
  local outside_repo="$TEST_TEMP_DIR/outside-repository"
  local worktree_repo="$HOME/linked-worktree"
  create_maintenance_git_repo "$real_repo"
  create_maintenance_git_repo "$outside_repo"
  mkdir -p "$HOME/symlink-parent" "$worktree_repo"
  rmdir "$HOME/symlink-parent"
  ln -s "$HOME/real" "$HOME/symlink-parent"
  printf 'gitdir: %s\n' "$real_repo/.git/worktrees/linked" \
    > "$worktree_repo/.git"
  export MAINT_SYMLINK_REPO="$HOME/symlink-parent/repository"
  export MAINT_OUTSIDE_REPO="$outside_repo"
  export MAINT_WORKTREE_REPO="$worktree_repo"

  run run_maintenance_zsh '
    local REPLY
    local -a reply=()
    local label repository
    for label repository in \
      symlink "$MAINT_SYMLINK_REPO" \
      outside "$MAINT_OUTSIDE_REPO" \
      worktree "$MAINT_WORKTREE_REPO"; do
      if _sys_update_git_fingerprint "$HOME" "$repository"; then
        print -r -- "${label}:accepted"
      else
        print -r -- "${label}:rejected"
      fi
    done
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"symlink:rejected"* ]]
  [[ "$output" == *"outside:rejected"* ]]
  [[ "$output" == *"worktree:rejected"* ]]
  [[ "$output" == *"Linked worktrees and .git indirection files are not supported"* ]]
  [ ! -s "$MAINT_MUTATION_LOG" ]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: OMZ aborts when origin changes after authorization" {
  local omz_repo="$HOME/.oh-my-zsh"
  create_maintenance_git_repo \
    "$omz_repo" 'https://example.invalid/ohmyzsh.git'
  export MAINT_OMZ_REPO="$omz_repo"

  run run_maintenance_zsh '
    export ZSH="$MAINT_OMZ_REPO"
    functions[_sys_test_original_git_revalidate]=\
      "${functions[_sys_update_git_revalidate]}"
    typeset -gi _SYS_TEST_REVALIDATION_CALLS=0
    _sys_update_git_revalidate() {
      if (( _SYS_TEST_REVALIDATION_CALLS++ == 0 )); then
        command git -C "$ZSH" remote set-url origin \
          https://example.invalid/changed.git
      fi
      _sys_test_original_git_revalidate "$@"
    }
    _sys_run_logged() {
      print -r -- "$*" >> "$MAINT_MUTATION_LOG"
      return 0
    }
    update-omz --yes
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"Git checkout changed after authorization"* ]]
  [ ! -s "$MAINT_MUTATION_LOG" ]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: OMZ uses direct fast-forward Git pull and never upgrade.sh" {
  local omz_repo="$HOME/.oh-my-zsh"
  create_maintenance_git_repo \
    "$omz_repo" 'https://example.invalid/ohmyzsh.git'
  mkdir -p "$omz_repo/tools"
  cat <<'EOF' > "$omz_repo/tools/upgrade.sh"
#!/usr/bin/env zsh
print -r -- executed >> "$MAINT_SHELL_LOG"
EOF
  chmod +x "$omz_repo/tools/upgrade.sh"
  export MAINT_OMZ_REPO="$omz_repo"

  run run_maintenance_zsh '
    export ZSH="$MAINT_OMZ_REPO"
    _sys_run_logged() {
      print -r -- "$*" >> "$MAINT_MUTATION_LOG"
      return 0
    }
    update-omz --yes
  '

  [ "$status" -eq 0 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = \
    "omz-pull git -C $omz_repo pull --ff-only" ]
  [[ "$output" == *"tools/upgrade.sh will not be executed"* ]]
  [ ! -s "$MAINT_SHELL_LOG" ]
  [ ! -s "$MAINT_NETWORK_LOG" ]
  [ ! -s "$MAINT_SIGNAL_LOG" ]
}

@test "sys maintenance: fzf refuses a linked installer after Git pull" {
  local fzf_repo="$HOME/.fzf"
  local unsafe_installer="$HOME/unsafe-fzf-installer"
  create_maintenance_git_repo \
    "$fzf_repo" 'https://example.invalid/fzf.git'
  printf '#!/usr/bin/env zsh\nexit 0\n' > "$fzf_repo/install"
  chmod +x "$fzf_repo/install"
  git -C "$fzf_repo" add install
  git -C "$fzf_repo" \
    -c user.name='ZDX Test' \
    -c user.email='zdx-test@example.invalid' \
    commit --quiet -m 'test: add installer'
  printf '#!/usr/bin/env zsh\nprint executed >> "$MAINT_SHELL_LOG"\n' \
    > "$unsafe_installer"
  chmod +x "$unsafe_installer"
  rm "$fzf_repo/install"
  ln -s "$unsafe_installer" "$fzf_repo/install"

  run run_maintenance_zsh '
    dpkg() { return 1; }
    _sys_run_logged() {
      print -r -- "$*" >> "$MAINT_MUTATION_LOG"
      return 0
    }
    update-fzf --yes
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"Refusing an unsafe fzf integration installer"* ]]
  [ "$(cat "$MAINT_MUTATION_LOG")" = \
    "fzf-pull git -C $fzf_repo pull --ff-only" ]
  [ ! -s "$MAINT_SHELL_LOG" ]
  [ ! -s "$MAINT_NETWORK_LOG" ]
  [ ! -s "$MAINT_SIGNAL_LOG" ]
}

@test "sys maintenance: plugin updates fail closed per repository and report partial success" {
  local custom_dir="$HOME/.oh-my-zsh/custom"
  local valid_repo="$custom_dir/plugins/valid"
  local invalid_repo="$custom_dir/plugins/missing-origin"
  create_maintenance_git_repo \
    "$valid_repo" 'https://example.invalid/valid.git'
  create_maintenance_git_repo "$invalid_repo" ''
  export MAINT_CUSTOM_DIR="$custom_dir"

  run run_maintenance_zsh '
    export ZSH_CUSTOM="$MAINT_CUSTOM_DIR"
    _sys_run_logged() {
      print -r -- "$*" >> "$MAINT_MUTATION_LOG"
      return 0
    }
    update-zsh-plugins --yes
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"1 repository failed safety validation"* ]]
  [[ "$output" == *"1 repository updated; 1 failed"* ]]
  [ "$(cat "$MAINT_MUTATION_LOG")" = \
    "zsh-valid git -C $valid_repo pull --ff-only --quiet" ]
  [ ! -s "$MAINT_NETWORK_LOG" ]
  [ ! -s "$MAINT_SHELL_LOG" ]
  [ ! -s "$MAINT_SIGNAL_LOG" ]
}

@test "sys maintenance: the active ZDX development link is externally managed" {
  local custom_dir="$HOME/.oh-my-zsh/custom"
  local active_repo="$HOME/workspaces/active-zdx-suite"
  local valid_repo="$custom_dir/plugins/valid"
  local zdx_link="$custom_dir/plugins/zdx-suite"
  create_maintenance_git_repo \
    "$active_repo" 'https://example.invalid/active-zdx-suite.git'
  mkdir -p "$active_repo/functions"
  printf '%s\n' '# test ZDX core marker' > "$active_repo/functions.zsh"
  printf '%s\n' '# test ZDX plugin marker' \
    > "$active_repo/zdx-suite.plugin.zsh"
  create_maintenance_git_repo \
    "$valid_repo" 'https://example.invalid/valid.git'
  ln -s "$active_repo" "$zdx_link"
  export MAINT_ACTIVE_ZDX_ROOT="$active_repo"
  export MAINT_CUSTOM_DIR="$custom_dir"

  run run_maintenance_zsh '
    export ZSH_CUSTOM="$MAINT_CUSTOM_DIR"
    _ZDX_FUNCTIONS_DIR="$MAINT_ACTIVE_ZDX_ROOT/functions"
    _sys_run_logged() {
      print -r -- "$*" >> "$MAINT_MUTATION_LOG"
      return 0
    }
    update-zsh-plugins --yes
  '

  [ "$status" -eq 0 ]
  [[ "$output" == \
    *"Linked ZDX development checkout is managed from its source checkout:"* ]]
  [[ "$output" == \
    *"No Git pull will be attempted by update-zsh-plugins."* ]]
  [[ "$output" == *"1 linked ZDX development checkout skipped"* ]]
  [[ "$output" != *"Excluded unsafe repository: $zdx_link"* ]]
  [[ "$output" != *"failed safety validation"* ]]
  [ "$(cat "$MAINT_MUTATION_LOG")" = \
    "zsh-valid git -C $valid_repo pull --ff-only --quiet" ]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: a zdx-suite link to another checkout remains unsafe" {
  local custom_dir="$HOME/.oh-my-zsh/custom"
  local active_repo="$HOME/workspaces/active-zdx-suite"
  local other_repo="$HOME/workspaces/other-zdx-suite"
  local zdx_link="$custom_dir/plugins/zdx-suite"
  create_maintenance_git_repo \
    "$active_repo" 'https://example.invalid/active-zdx-suite.git'
  mkdir -p "$active_repo/functions"
  printf '%s\n' '# test ZDX core marker' > "$active_repo/functions.zsh"
  printf '%s\n' '# test ZDX plugin marker' \
    > "$active_repo/zdx-suite.plugin.zsh"
  create_maintenance_git_repo \
    "$other_repo" 'https://example.invalid/other-zdx-suite.git'
  mkdir -p "$custom_dir/plugins"
  ln -s "$other_repo" "$zdx_link"
  export MAINT_ACTIVE_ZDX_ROOT="$active_repo"
  export MAINT_CUSTOM_DIR="$custom_dir"

  run run_maintenance_zsh '
    export ZSH_CUSTOM="$MAINT_CUSTOM_DIR"
    _ZDX_FUNCTIONS_DIR="$MAINT_ACTIVE_ZDX_ROOT/functions"
    _sys_run_logged() {
      print -r -- "$*" >> "$MAINT_MUTATION_LOG"
      return 0
    }
    update-zsh-plugins --yes
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"Excluded unsafe repository: $zdx_link"* ]]
  [[ "$output" == *"No repository passed executable-code safety validation"* ]]
  [ ! -s "$MAINT_MUTATION_LOG" ]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: cleanup dry-run preserves every planned target" {
  local shared_tmp="$TEST_TEMP_DIR/shared-tmp"
  mkdir -p "$HOME/.cache/tmp" "$HOME/.cache/thumbnails" "$shared_tmp"
  printf '%s\n' keep > "$HOME/.cache/tmp/user-cache"
  printf '%s\n' keep > "$HOME/.cache/thumbnails/thumbnail"
  printf '%s\n' keep > "$shared_tmp/shared"
  export TMPDIR="$shared_tmp"

  run run_maintenance_zsh '
    command() {
      if [[ "${1:-}" == "-v" ]]; then
        case "${2:-}" in
          apt-get|brew|npm|uv|pip|cargo|rustup|go|snap) return 1 ;;
        esac
      fi
      builtin command "$@"
    }
    clean-system-quick --dry-run --yes
  '

  [ "$status" -eq 0 ]
  [ -f "$HOME/.cache/tmp/user-cache" ]
  [ -f "$HOME/.cache/thumbnails/thumbnail" ]
  [ -f "$shared_tmp/shared" ]
  [ ! -s "$MAINT_MUTATION_LOG" ]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: cleanup removes user caches but not TMPDIR or Docker" {
  local shared_tmp="$TEST_TEMP_DIR/shared-tmp"
  mkdir -p "$HOME/.cache/tmp" "$HOME/.cache/thumbnails" "$shared_tmp"
  printf '%s\n' remove > "$HOME/.cache/tmp/user-cache"
  printf '%s\n' remove > "$HOME/.cache/thumbnails/thumbnail"
  printf '%s\n' keep > "$shared_tmp/shared"
  export TMPDIR="$shared_tmp"

  run run_maintenance_zsh '
    command() {
      if [[ "${1:-}" == "-v" ]]; then
        case "${2:-}" in
          apt-get|brew|npm|uv|pip|cargo|rustup|go|snap) return 1 ;;
        esac
      fi
      builtin command "$@"
    }
    clean-system-quick --yes
  '

  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.cache/tmp/user-cache" ]
  [ ! -e "$HOME/.cache/thumbnails/thumbnail" ]
  [ -f "$shared_tmp/shared" ]
  [ ! -s "$MAINT_MUTATION_LOG" ]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: aggregate update reports a partial failure" {
  run run_maintenance_zsh '
    _sys_step_applies() {
      [[ "$1" == "update-uv-system" || "$1" == "update-pipx" ]]
    }
    _sys_test_pkg_manager() { return 0; }
    update-uv-system() {
      print -r -- "update-uv-system" >> "$MAINT_MUTATION_LOG"
      return 0
    }
    update-pipx() {
      print -r -- "update-pipx" >> "$MAINT_MUTATION_LOG"
      return 41
    }
    update-system --yes
  '

  [ "$status" -eq 1 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = $'update-uv-system\nupdate-pipx' ]
  [[ "$output" == *"System update completed with partial failures"* ]]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: aggregate summary includes a validated nested AI failure" {
  run run_maintenance_zsh '
    _sys_step_applies() {
      [[ "$1" == "_sys_update_ai_tools" || "$1" == "update-omz" ]]
    }
    _sys_update_ai_load_owner() { return 0; }
    ai-menu() {
      print -r -- "ai:${(j: :)@}" >> "$MAINT_MUTATION_LOG"
      _test_ai_result_report \
        skipped not-installed 0 cursor failed authentication-required 1
      return 1
    }
    update-omz() {
      print -r -- "update-omz" >> "$MAINT_MUTATION_LOG"
    }

    sys-menu update-system --yes \
      > "$HOME/update-system.stdout" 2> "$HOME/update-system.stderr"
  '

  [ "$status" -eq 1 ]
  [ ! -s "$HOME/update-system.stdout" ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = \
    $'ai:ai-update --skip-homebrew-managed --result-tsv --yes\nupdate-omz' ]
  grep -Fq -- \
    "AI assistants — Cursor Agent: authentication required" \
    "$HOME/update-system.stderr"
  grep -Fq -- \
    "System update completed with partial failures: 1 of 2 steps failed." \
    "$HOME/update-system.stderr"
  grep -Eq -- \
    'sys:update-system completed with partial failures in [0-9]+[.][0-9]s \(status 1\)' \
    "$HOME/update-system.stderr"
  grep -Fq -- "Step completed" "$HOME/update-system.stderr"
  grep -Fq -- "Oh My Zsh" "$HOME/update-system.stderr"
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: invalid AI result records fail closed without UI injection" {
  run run_maintenance_zsh '
    _sys_step_applies() { [[ "$1" == "_sys_update_ai_tools" ]]; }
    _sys_update_ai_load_owner() { return 0; }
    ai-menu() {
      local report
      report=$(_test_ai_result_report skipped not-installed 0)
      print -r -- "${report/Cursor Agent/INJECTED}"
      return 1
    }

    update-system --yes
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"AI updater returned an invalid result report"* ]]
  [[ "$output" == *"AI assistants — result report is invalid"* ]]
  [[ "$output" != *"AI assistants — INJECTED"* ]]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: incomplete AI result reports fail closed" {
  run run_maintenance_zsh '
    _sys_step_applies() { [[ "$1" == "_sys_update_ai_tools" ]]; }
    _sys_update_ai_load_owner() { return 0; }
    ai-menu() {
      _test_ai_result_report skipped not-installed 0 | command head -n 7
    }

    update-system --yes
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"AI updater returned an invalid result report"* ]]
  [[ "$output" == *"AI assistants — result report is invalid"* ]]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: AI result parser rejects structural and semantic violations" {
  run run_maintenance_zsh '
    local baseline tab
    tab=$(printf "\t")
    baseline=$(_test_ai_result_report skipped not-installed 0)

    local -a names=(schema order duplicate outcome-status status-bound)
    local -a candidates=()
    local -a records=("${(@f)baseline}")
    local first="${records[1]}"

    candidates+=("${baseline/ai-update-result-v1/ai-update-result-v2}")
    records[1]="${records[2]}"
    records[2]="$first"
    candidates+=("${(F)records}")
    records=("${(@f)baseline}")
    records[2]="${records[1]}"
    candidates+=("${(F)records}")
    candidates+=(
      "${baseline/skipped${tab}not-installed${tab}0/updated${tab}version-changed${tab}1}"
      "${baseline/skipped${tab}not-installed${tab}0/skipped${tab}not-installed${tab}999}"
    )

    local -i index parse_rc
    for (( index = 1; index <= ${#candidates[@]}; ++index )); do
      if _sys_update_ai_parse_results "${candidates[index]}"; then
        parse_rc=0
      else
        parse_rc=$?
      fi
      (( parse_rc == 2 )) || {
        print -r -- "unexpected:${names[index]}:$parse_rc"
        return 1
      }
    done
    print -r -- "rejected:${#candidates[@]}"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"rejected:5"* ]]
  [[ "$output" != *"unexpected:"* ]]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: aggregate summary separates core packages and optional tools" {
  run run_maintenance_zsh '
    _sys_step_applies() {
      [[ "$1" == "update-apt" || "$1" == "update-snap" \
        || "$1" == "update-uv-system" || "$1" == "update-pipx" ]]
    }
    _sys_apt_plan_blocker() { REPLY=""; }
    _sys_update_preauthenticate() { REPLY=0; }
    update-apt() {
      print -r -- "apt" >> "$MAINT_MUTATION_LOG"
    }
    update-snap() {
      print -r -- "snap" >> "$MAINT_MUTATION_LOG"
      return 41
    }
    update-uv-system() {
      print -r -- "uv" >> "$MAINT_MUTATION_LOG"
    }
    update-pipx() {
      print -r -- "pipx" >> "$MAINT_MUTATION_LOG"
      return 42
    }
    update-system --yes --safe-only
  ' apt

  [ "$status" -eq 1 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = $'apt\nsnap\nuv\npipx' ]
  [[ "$output" == *"Core package steps: 1/2 succeeded; 1 failed"* ]]
  [[ "$output" == *"Optional tool steps: 1/2 succeeded; 1 failed"* ]]

  : > "$MAINT_MUTATION_LOG"
  run run_maintenance_zsh '
    _sys_step_applies() {
      [[ "$1" == "update-apt" || "$1" == "update-snap" \
        || "$1" == "update-uv-system" ]]
    }
    _sys_apt_plan_blocker() { REPLY=""; }
    _sys_update_preauthenticate() { REPLY=0; }
    update-apt() {
      print -r -- "apt" >> "$MAINT_MUTATION_LOG"
      return 41
    }
    update-snap() {
      print -r -- "unexpected:snap" >> "$MAINT_MUTATION_LOG"
    }
    update-uv-system() {
      print -r -- "unexpected:uv" >> "$MAINT_MUTATION_LOG"
    }
    update-system --fail-fast --yes --safe-only
  ' apt

  [ "$status" -eq 1 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = apt ]
  [[ "$output" == \
    *"Core package steps: 0/2 succeeded; 1 failed; 1 not run"* ]]
  [[ "$output" == \
    *"Optional tool steps: 0/1 succeeded; 1 not run"* ]]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: aggregate update lock rejects overlap at t0 and is reusable" {
  export UPDATE_LOCK_READY_FIFO="$TEST_TEMP_DIR/update-lock-ready.fifo"
  export UPDATE_LOCK_RELEASE_FIFO="$TEST_TEMP_DIR/update-lock-release.fifo"
  export UPDATE_LOCK_ENTERED="$TEST_TEMP_DIR/update-lock-entered"
  export UPDATE_LOCK_FIRST_OUTPUT="$TEST_TEMP_DIR/update-lock-first.output"
  export UPDATE_LOCK_PATH="$TEST_TEMP_DIR/update-system.lock"
  mkfifo "$UPDATE_LOCK_READY_FIFO" "$UPDATE_LOCK_RELEASE_FIFO"

  run run_maintenance_zsh '
    _sys_update_lock_path() { REPLY="$UPDATE_LOCK_PATH"; }
    _sys_step_applies() { [[ "$1" == "update-uv-system" ]]; }
    _sys_update_preauthenticate() { REPLY=0; }
    update-uv-system() {
      if [[ ! -e "$UPDATE_LOCK_ENTERED" ]]; then
        : > "$UPDATE_LOCK_ENTERED"
        print -r -- ready > "$UPDATE_LOCK_READY_FIFO"
        local release=""
        IFS= read -r release < "$UPDATE_LOCK_RELEASE_FIFO" || return 97
        [[ "$release" == release ]] || return 97
        print -r -- "step:first" >> "$MAINT_MUTATION_LOG"
        return 41
      else
        print -r -- "step:later" >> "$MAINT_MUTATION_LOG"
      fi
    }

    update-system --yes --safe-only \
      > "$UPDATE_LOCK_FIRST_OUTPUT" 2>&1 &
    local holder_pid=$!
    local ready="" second_output="" second_rc=0 first_rc=0 third_rc=0
    IFS= read -r ready < "$UPDATE_LOCK_READY_FIFO" || return 97
    [[ "$ready" == ready ]] || return 97

    second_output=$(update-system --yes --safe-only 2>&1) || second_rc=$?
    print -r -- "second:$second_rc" >> "$MAINT_MUTATION_LOG"
    print -u2 -r -- "$second_output"

    print -r -- release > "$UPDATE_LOCK_RELEASE_FIFO" || return 97
    wait "$holder_pid" || first_rc=$?
    print -r -- "first:$first_rc" >> "$MAINT_MUTATION_LOG"

    update-system --yes --safe-only || third_rc=$?
    print -r -- "third:$third_rc" >> "$MAINT_MUTATION_LOG"
    [[ "$_SYS_UPDATE_LOCK_HELD" == 0 \
      && -z "$_SYS_UPDATE_LOCK_HELD_FD" ]] || return 97
    (( first_rc == 1 && second_rc == 1 && third_rc == 0 ))
  '

  [ "$status" -eq 0 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = \
    $'second:1\nstep:first\nfirst:1\nstep:later\nthird:0' ]
  [[ "$output" == *"lock could not be acquired"* ]]
  [[ "$output" == *"No update step was started"* ]]
  [[ "$output" != *"waiting"* ]]
  [[ "$output" != *"Retrying"* ]]
  [ "$(grep -c '^step:' "$MAINT_MUTATION_LOG")" -eq 2 ]
  [ -f "$UPDATE_LOCK_PATH" ]
  [ "$(stat -c '%a' "$UPDATE_LOCK_PATH")" = 600 ]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: aggregate lock path is stable under canonical HOME" {
  run run_zsh '
    _sys_update_lock_path || return $?
    print -r -- "$REPLY"
  '

  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.zdx-update-system.lock" ]
  [ ! -s "$MAINT_MUTATION_LOG" ]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: aggregate lock directories are owner-controlled" {
  local safe_directory="$TEST_TEMP_DIR/safe-lock-directory"
  local writable_directory="$TEST_TEMP_DIR/writable-lock-directory"
  local linked_directory="$TEST_TEMP_DIR/linked-lock-directory"
  mkdir -p "$safe_directory" "$writable_directory"
  chmod 700 "$safe_directory"
  chmod 770 "$writable_directory"
  ln -s "$safe_directory" "$linked_directory"
  export SAFE_LOCK_DIRECTORY="$safe_directory"
  export WRITABLE_LOCK_DIRECTORY="$writable_directory"
  export LINKED_LOCK_DIRECTORY="$linked_directory"

  run run_zsh '
    _sys_update_lock_directory_safe "$SAFE_LOCK_DIRECTORY" || return $?
    print -r -- "safe:$REPLY"
    _sys_update_lock_directory_safe "$WRITABLE_LOCK_DIRECTORY" \
      && return 97
    _sys_update_lock_directory_safe "$LINKED_LOCK_DIRECTORY" \
      && return 97
    return 0
  '

  [ "$status" -eq 0 ]
  [ "$output" = "safe:$safe_directory" ]
  [ ! -s "$MAINT_MUTATION_LOG" ]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: an unsafe precreated aggregate lock is never followed or replaced" {
  local lock_directory="$TEST_TEMP_DIR/precreated-lock-directory"
  local target="$TEST_TEMP_DIR/precreated-lock-target"
  local linked_lock="$lock_directory/zdx-update-system.lock"
  mkdir -p "$lock_directory"
  chmod 700 "$lock_directory"
  printf '%s\n' untouched > "$target"
  ln -s "$target" "$linked_lock"
  export PRECREATED_LOCK="$linked_lock"

  run run_zsh '
    _sys_update_acquire_lock "$PRECREATED_LOCK"
    local lock_rc=$?
    print -r -- "held:$_SYS_UPDATE_LOCK_HELD"
    print -r -- "fd:${_SYS_UPDATE_LOCK_HELD_FD:-none}"
    return $lock_rc
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"lock file is unsafe"* ]]
  [[ "$output" == *"held:0"* ]]
  [[ "$output" == *"fd:none"* ]]
  [ -L "$linked_lock" ]
  [ "$(cat "$target")" = untouched ]
  [ ! -s "$MAINT_MUTATION_LOG" ]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: lock release closes the owned fd when flock unlock fails" {
  local lock_directory="$TEST_TEMP_DIR/release-fallback-lock-directory"
  local lock_path="$lock_directory/zdx-update-system.lock"
  mkdir -p "$lock_directory"
  chmod 700 "$lock_directory"
  export RELEASE_FALLBACK_LOCK="$lock_path"

  run run_zsh '
    _sys_update_acquire_lock "$RELEASE_FALLBACK_LOCK" || return $?
    local first_fd="$REPLY"
    zsystem() {
      if [[ "$1" == flock && "$2" == -u ]]; then
        return 1
      fi
      builtin zsystem "$@"
    }
    _sys_update_release_lock "$first_fd" || return $?
    print -r -- "released:$_SYS_UPDATE_LOCK_HELD:${_SYS_UPDATE_LOCK_HELD_FD:-empty}"
    unfunction zsystem

    _sys_update_acquire_lock "$RELEASE_FALLBACK_LOCK" || return $?
    local second_fd="$REPLY"
    print -r -- "reacquired:$second_fd"
    _sys_update_release_lock "$second_fd"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"released:0:empty"* ]]
  [[ "$output" == *"reacquired:"* ]]
  [ -f "$lock_path" ]
  [ "$(stat -c '%a' "$lock_path")" = 600 ]
  [ ! -s "$MAINT_MUTATION_LOG" ]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: aggregate runs APT exactly once immediately after preauthentication" {
  run run_maintenance_zsh '
    _sys_step_applies() {
      [[ "$1" == "update-apt" || "$1" == "update-uv-system" ]]
    }
    _sys_update_preauthenticate() {
      print -r -- "preauthenticate" >> "$MAINT_MUTATION_LOG"
    }
    _sys_package_manager_busy() { return 1; }
    update-apt() {
      print -r -- "update-apt" >> "$MAINT_MUTATION_LOG"
    }
    update-uv-system() {
      print -r -- "update-uv-system" >> "$MAINT_MUTATION_LOG"
    }

    update-system --yes
  ' apt

  [ "$status" -eq 0 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = \
    $'preauthenticate\nupdate-apt\nupdate-uv-system' ]
  [ "$(grep -c '^update-apt$' "$MAINT_MUTATION_LOG")" -eq 1 ]
  [[ "$output" != *"Deferring"* ]]
  [[ "$output" != *"Retrying"* ]]
  [[ "$output" == *"System update completed successfully"* ]]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: aggregate keeps its only TERM inside APT before a later fail-fast error" {
  export MOCK_APT_MUTATIONS_SUCCEED=1
  export MOCK_SUDO_ALLOW="apt-get,env"
  local fingerprint=$'unattended-upgrade\t4242\t0\t998877\tunattended-upgr\tapt-daily-upgrade.service\t/usr/bin/unattended-upgrade'
  export APT_AUTOMATIC_FINGERPRINT="$fingerprint"

  run run_maintenance_zsh '
    _sys_step_applies() {
      [[ "$1" == "update-apt" || "$1" == "update-uv-system" ]]
    }
    _sys_apt_plan_blocker() {
      print -r -- "plan:blocker" >> "$MAINT_MUTATION_LOG"
      REPLY="$APT_AUTOMATIC_FINGERPRINT"
    }
    _sys_update_preauthenticate() {
      print -r -- "preauthenticate" >> "$MAINT_MUTATION_LOG"
    }
    functions[_maintenance_real_update_apt]=$functions[update-apt]
    update-apt() {
      print -r -- "apt:start" >> "$MAINT_MUTATION_LOG"
      local apt_rc=0
      _maintenance_real_update_apt "$@" || apt_rc=$?
      print -r -- "apt:end:$apt_rc" >> "$MAINT_MUTATION_LOG"
      return $apt_rc
    }
    _sys_package_manager_busy() {
      print -r -- "unexpected-busy:$1" >> "$MAINT_MUTATION_LOG"
      return 97
    }
    _sys_apt_unattended_fingerprint_matches() {
      [[ "$1" == "$APT_AUTOMATIC_FINGERPRINT" ]]
    }
    _sys_apt_request_automatic_yield() {
      [[ "$1" == "$APT_AUTOMATIC_FINGERPRINT" ]] || return 97
      print -r -- "apt:TERM" >> "$MAINT_MUTATION_LOG"
    }
    _sys_apt_dpkg_state_clean() {
      print -r -- "apt:dpkg-clean" >> "$MAINT_MUTATION_LOG"
    }
    _sys_wait_for_package_manager() {
      print -r -- "unexpected-wait:$1" >> "$MAINT_MUTATION_LOG"
      return 97
    }
    _sys_package_lock_pause() {
      print -r -- "unexpected-pause:$1" >> "$MAINT_MUTATION_LOG"
      return 97
    }
    sleep() {
      print -r -- "unexpected-sleep:$*" >> "$MAINT_MUTATION_LOG"
      return 97
    }
    update-uv-system() {
      print -r -- "later:update-uv-system" >> "$MAINT_MUTATION_LOG"
      return 41
    }

    update-system --fail-fast --yes --safe-only
  ' apt

  [ "$status" -eq 1 ]
  local expected_mutations=$'plan:blocker\npreauthenticate\napt:start\napt:dpkg-clean\napt:TERM\n'
  expected_mutations+="$(expected_apt_call update)"
  expected_mutations+=$'\n'
  expected_mutations+="$(expected_apt_call full-upgrade -y)"
  expected_mutations+=$'\n'
  expected_mutations+="$(expected_apt_call autoremove -y)"
  expected_mutations+=$'\napt:dpkg-clean\napt:end:0\nlater:update-uv-system'
  [ "$(cat "$MAINT_MUTATION_LOG")" = \
    "$expected_mutations" ]
  [ "$(grep -c '^apt:TERM$' "$MAINT_MUTATION_LOG")" -eq 1 ]
  [[ "$output" == *"Aborting after first failure (--fail-fast): uv"* ]]
  [[ "$output" != *"Deferring"* ]]
  [[ "$output" != *"Retrying"* ]]
  [ ! -s "$MAINT_SIGNAL_LOG" ]
  [ ! -s "$MAINT_NETWORK_LOG" ]
  [ ! -s "$MAINT_SHELL_LOG" ]
}

@test "sys maintenance: an APT failure is reported before independent updates continue" {
  run run_maintenance_zsh '
    _sys_step_applies() {
      [[ "$1" == "update-apt" || "$1" == "update-uv-system" \
        || "$1" == "update-pipx" ]]
    }
    _sys_package_manager_busy() { return 1; }
    update-apt() {
      print -r -- "update-apt" >> "$MAINT_MUTATION_LOG"
      return 41
    }
    update-uv-system() {
      print -r -- "update-uv-system" >> "$MAINT_MUTATION_LOG"
    }
    update-pipx() {
      print -r -- "update-pipx" >> "$MAINT_MUTATION_LOG"
    }

    update-system --yes
  ' apt

  [ "$status" -eq 1 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = \
    $'update-apt\nupdate-uv-system\nupdate-pipx' ]
  [ "$(grep -c '^update-apt$' "$MAINT_MUTATION_LOG")" -eq 1 ]
  [[ "$output" == *"System update completed with partial failures"* ]]
  [[ "$output" == *"APT"* ]]
  [[ "$output" != *"Deferring"* ]]
  [[ "$output" != *"Retrying"* ]]
  [ ! -s "$MAINT_SIGNAL_LOG" ]
  if (( EUID == 0 )); then
    [ ! -s "$MOCK_SUDO_LOG" ]
  else
    [ "$(cat "$MOCK_SUDO_LOG")" = "sudo -n true" ]
  fi
  [ ! -s "$MAINT_NETWORK_LOG" ]
  [ ! -s "$MAINT_SHELL_LOG" ]
}

@test "sys maintenance: fail-fast aborts on APT before any later update step" {
  run run_maintenance_zsh '
    _sys_step_applies() {
      [[ "$1" == "update-apt" || "$1" == "update-uv-system" ]]
    }
    _sys_package_manager_busy() { return 1; }
    update-apt() {
      print -r -- "update-apt" >> "$MAINT_MUTATION_LOG"
      return 41
    }
    update-uv-system() {
      print -r -- "update-uv-system" >> "$MAINT_MUTATION_LOG"
    }

    update-system --fail-fast --yes
  ' apt

  [ "$status" -eq 1 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = "update-apt" ]
  [ "$(grep -c '^update-apt$' "$MAINT_MUTATION_LOG")" -eq 1 ]
  [[ "$output" == *"Aborting after first failure (--fail-fast): APT"* ]]
  [[ "$output" != *"Deferring"* ]]
  [[ "$output" != *"Retrying"* ]]
  if (( EUID == 0 )); then
    [ ! -s "$MOCK_SUDO_LOG" ]
  else
    [ "$(cat "$MOCK_SUDO_LOG")" = "sudo -n true" ]
  fi
  [ ! -s "$MAINT_SIGNAL_LOG" ]
  [ ! -s "$MAINT_NETWORK_LOG" ]
  [ ! -s "$MAINT_SHELL_LOG" ]
}

@test "sys maintenance: aggregate cleanup continues and reports partial failure" {
  run run_maintenance_zsh '
    _sys_clean_plan() {
      printf "%s\n" \
        "APT cache|apt-get clean" \
        "npm cache|$HOME/.cache/npm" \
        "uv cache|$HOME/.cache/uv" \
        "pip cache|$HOME/.cache/pip" \
        "Cargo registry cache|$HOME/.cargo/registry/cache" \
        "Journal logs|journal entries older than 3 days" \
        "Thumbnail cache|$HOME/.cache/thumbnails" \
        "Temporary files|$HOME/.cache/tmp"
    }
    _sys_test_pkg_manager() { return 0; }
    _sys_clean_step_apt_cache() {
      print -r -- "apt" >> "$MAINT_MUTATION_LOG"
    }
    _sys_clean_step_npm_cache() {
      print -r -- "npm" >> "$MAINT_MUTATION_LOG"
      return 41
    }
    _sys_clean_step_uv_cache() {
      print -r -- "uv" >> "$MAINT_MUTATION_LOG"
    }
    _sys_clean_step_pip_cache() {
      print -r -- "pip" >> "$MAINT_MUTATION_LOG"
    }
    _sys_clean_step_cargo_cache() {
      print -r -- "cargo" >> "$MAINT_MUTATION_LOG"
    }
    _sys_clean_step_journal() {
      print -r -- "journal" >> "$MAINT_MUTATION_LOG"
    }
    _sys_clean_step_thumbnails() {
      print -r -- "thumbnails" >> "$MAINT_MUTATION_LOG"
    }
    _sys_clean_step_temp_files() {
      print -r -- "temp" >> "$MAINT_MUTATION_LOG"
    }
    clean-system-quick --yes
  '

  [ "$status" -eq 1 ]
  [ "$(wc -l < "$MAINT_MUTATION_LOG")" -eq 8 ]
  [ "$(tail -n 1 "$MAINT_MUTATION_LOG")" = "temp" ]
  [[ "$output" == *"Cleanup completed with 1 issue(s)"* ]]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: cleanup dispatches only its confirmed plan records" {
  run run_maintenance_zsh '
    _sys_clean_plan() {
      print -r -- "Temporary files|$HOME/.cache/tmp"
    }
    _sys_clean_step_apt_cache() {
      print -r -- "unexpected:apt" >> "$MAINT_MUTATION_LOG"
      return 71
    }
    _sys_clean_step_npm_cache() {
      print -r -- "unexpected:npm" >> "$MAINT_MUTATION_LOG"
      return 71
    }
    _sys_clean_step_uv_cache() {
      print -r -- "unexpected:uv" >> "$MAINT_MUTATION_LOG"
      return 71
    }
    _sys_clean_step_pip_cache() {
      print -r -- "unexpected:pip" >> "$MAINT_MUTATION_LOG"
      return 71
    }
    _sys_clean_step_cargo_cache() {
      print -r -- "unexpected:cargo" >> "$MAINT_MUTATION_LOG"
      return 71
    }
    _sys_clean_step_journal() {
      print -r -- "unexpected:journal" >> "$MAINT_MUTATION_LOG"
      return 71
    }
    _sys_clean_step_thumbnails() {
      print -r -- "unexpected:thumbnails" >> "$MAINT_MUTATION_LOG"
      return 71
    }
    _sys_clean_step_temp_files() {
      print -r -- "temp:$1" >> "$MAINT_MUTATION_LOG"
    }
    clean-system-quick --yes
  '

  [ "$status" -eq 0 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = \
    "temp:$HOME/.cache/tmp" ]
  [[ "$output" == *"System cleanup completed successfully! (1/1 steps)"* ]]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: changed cache path aborts before mutation" {
  mkdir -p "$HOME/.cache/npm-before" "$HOME/.cache/npm-after"
  printf 'before\n' > "$HOME/.cache/npm-before/sentinel"
  printf 'after\n' > "$HOME/.cache/npm-after/sentinel"

cat <<'EOF' > "$TEST_MOCK_BIN/npm"
#!/usr/bin/env bash
log_file="$MAINT_MUTATION_LOG"
[[ "$*" == "config get prefix" ]] && log_file="$MAINT_PROBE_LOG"
{
  printf 'npm'
  printf ' %q' "$@"
  printf '\n'
} >> "$log_file"
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/npm"

  run run_maintenance_zsh '
    _sys_clean_plan() {
      print -r -- "npm cache|$HOME/.cache/npm-before"
    }
    _sys_clean_npm_cache_dir() {
      print -r -- "$HOME/.cache/npm-after"
    }
    clean-system-quick --yes
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"npm cache path changed after confirmation"* ]]
  [ "$(cat "$HOME/.cache/npm-before/sentinel")" = "before" ]
  [ "$(cat "$HOME/.cache/npm-after/sentinel")" = "after" ]
  [ ! -s "$MAINT_MUTATION_LOG" ]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: package-manager locks never signal a process" {
  export MOCK_APT_LOCKED=1
  run run_maintenance_zsh "_sys_test_pkg_manager apt"

  [ "$status" -eq 1 ]
  [[ "$output" == *"APT-family process is active"* ]]
  [[ "$output" == *"fails closed without waiting or signaling"* ]]
  [[ "$output" != *"Retrying"* ]]
  [ ! -s "$MAINT_SIGNAL_LOG" ]

  [ ! -s "$MAINT_MUTATION_LOG" ]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: AWS and Starship avoid curl, shell, and sudo installers" {
  local owner_hiding_wrapper='
    command() {
      if [[ "${1:-}" == "-v" ]]; then
        case "${2:-}" in
          aws|brew|cargo|snap) return 1 ;;
        esac
      fi
      builtin command "$@"
    }
  '

  run run_maintenance_zsh "$owner_hiding_wrapper update-awscli"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Automatic AWS CLI bundle installation is disabled"* ]]

  run run_maintenance_zsh "$owner_hiding_wrapper update-starship"
  [ "$status" -eq 1 ]
  [[ "$output" == *"installation owner could not be verified"* ]]

  [ ! -s "$MAINT_MUTATION_LOG" ]
  assert_no_privilege_network_or_signal
}

@test "sys maintenance: a nested update-system refusal preserves the outer lock" {
  export UPDATE_LOCK_PATH="$TEST_TEMP_DIR/update-system.lock"

  run run_maintenance_zsh '
    _sys_update_lock_path() { REPLY="$UPDATE_LOCK_PATH"; }
    _sys_step_applies() { [[ "$1" == "update-uv-system" ]]; }
    _sys_update_preauthenticate() { REPLY=0; }
    update-uv-system() {
      print -r -- "step:ran" >> "$MAINT_MUTATION_LOG"
      return 0
    }
    probe_lock() {
      zsh -c "zmodload zsh/system && zsystem flock -t 0 \"\$1\"" \
        zsh "$UPDATE_LOCK_PATH" 2>/dev/null
    }

    local outer_fd="" nested_rc=0
    _sys_update_acquire_lock "$UPDATE_LOCK_PATH" || return 97
    outer_fd="$REPLY"
    [[ "$_SYS_UPDATE_LOCK_HELD" == 1 \
      && "$_SYS_UPDATE_LOCK_HELD_FD" == "$outer_fd" ]] || return 96

    update-system --yes --safe-only || nested_rc=$?
    print -r -- "nested:$nested_rc" >> "$MAINT_MUTATION_LOG"

    # The refused nested run must not release the outer descriptor.
    [[ "$_SYS_UPDATE_LOCK_HELD" == 1 \
      && "$_SYS_UPDATE_LOCK_HELD_FD" == "$outer_fd" ]] || return 95
    ! probe_lock || return 94

    _sys_update_release_lock "$outer_fd" || return 93
    [[ "$_SYS_UPDATE_LOCK_HELD" == 0 \
      && -z "$_SYS_UPDATE_LOCK_HELD_FD" ]] || return 92
    probe_lock || return 91
    (( nested_rc == 1 ))
  '

  [ "$status" -eq 0 ]
  [ "$(cat "$MAINT_MUTATION_LOG")" = "nested:1" ]
  [[ "$output" == *"already running in this shell"* ]]
  assert_no_privilege_network_or_signal
}
