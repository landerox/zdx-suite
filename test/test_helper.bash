# test_helper.bash - shared helper for BATS test suite

# Locate repo root
TEST_SUITE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEST_SUITE_ROOT

# Setup temp directory for sandbox
export TEST_TEMP_DIR
TEST_TEMP_DIR=$(mktemp -d -t zdx-tests.XXXXXX)
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME"

# Neutralize inherited XDG base directories. Redirecting HOME alone does not
# isolate the sandbox: suites resolve their state through
# "${XDG_CONFIG_HOME:-$HOME/.config}", so a host that exports XDG_CONFIG_HOME
# (GitHub's runners do) points profile state outside the sandbox HOME and the
# private-path guards correctly refuse it. Unsetting these makes every suite
# fall back to the HOME-derived defaults the sandbox owns, so the suite behaves
# identically on a developer machine and on a clean runner.
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME
unset XDG_RUNTIME_DIR XDG_CONFIG_DIRS XDG_DATA_DIRS

# Neutralize package-manager controls injected by developer shells and hosted
# runners. Individual tests export hostile values explicitly when exercising
# environment hardening.
unset HOMEBREW_CURL_RETRIES HOMEBREW_NO_ANALYTICS HOMEBREW_NO_AUTO_UPDATE
unset SUDO_ASKPASS

# Setup mock bin directory and prepend to PATH
export TEST_MOCK_BIN="$TEST_TEMP_DIR/bin"
mkdir -p "$TEST_MOCK_BIN"
export PATH="$TEST_MOCK_BIN:$PATH"

# Shared recorder paths and deterministic mock defaults
export MOCK_SUDO_LOG="$TEST_TEMP_DIR/sudo_calls"
: > "$MOCK_SUDO_LOG"
export MOCK_SUDO_ALLOW=""

export MOCK_FZF_MODE="cancel"
export MOCK_FZF_MATCH=""
export MOCK_FZF_RESPONSE=""
export MOCK_FZF_EXPECT_KEY=""
export MOCK_FZF_STATUS="130"
export MOCK_FZF_ARGS_FILE="$TEST_TEMP_DIR/fzf_args"
export MOCK_FZF_INPUT_FILE="$TEST_TEMP_DIR/fzf_input"
: > "$MOCK_FZF_ARGS_FILE"
: > "$MOCK_FZF_INPUT_FILE"

# Create mock wg-quick
cat <<'EOF' > "$TEST_MOCK_BIN/wg-quick"
#!/usr/bin/env bash
echo "mock wg-quick called: $@"
exit 0
EOF
chmod +x "$TEST_MOCK_BIN/wg-quick"

# Create mock wg. Without this the suite silently depends on wireguard-tools
# being installed on the host: _vpn_wg_access_state reports "missing" when 'wg'
# is absent, which diverts every destructive VPN command before it reaches its
# own authorization checks. Mirrors the real binary's unprivileged behavior --
# 'wg show interfaces' succeeds with no output when no tunnel is up -- so the
# access state resolves to "direct" on every host. Tests that need the absent
# case override _vpn_wg_access_state directly.
cat <<'EOF' > "$TEST_MOCK_BIN/wg"
#!/usr/bin/env bash
set -u

case "${1:-}" in
  --version)
    echo "wireguard-tools v1.0.20210914 - https://git.zx2c4.com/wireguard-tools/"
    ;;
  show)
    # 'wg show interfaces' lists active tunnels; none are up in the sandbox.
    ;;
  *) ;;
esac

exit 0
EOF
chmod +x "$TEST_MOCK_BIN/wg"

# Create a deny-by-default sudo recorder. Tests opt in to an executable by
# adding its basename to the comma-separated MOCK_SUDO_ALLOW list.
cat <<'EOF' > "$TEST_MOCK_BIN/sudo"
#!/usr/bin/env bash
set -u

if [[ -n "${MOCK_SUDO_LOG:-}" ]]; then
  {
    printf 'sudo'
    printf ' %q' "$@"
    printf '\n'
  } >> "$MOCK_SUDO_LOG"
fi

args=("$@")
index=0
while (( index < ${#args[@]} )); do
  case "${args[index]}" in
    --)
      ((index += 1))
      break
      ;;
    -u|-g|-h|-p|-C|-T|-R|-D|--user|--group|--host|--prompt|--close-from|--command-timeout|--chroot|--chdir)
      ((index += 2))
      ;;
    -*)
      ((index += 1))
      ;;
    *)
      break
      ;;
  esac
done

# If testing write permission on /etc/resolv.conf
if [[ "${args[index]:-}" == "test" \
  && "${args[index + 1]:-}" == "-w" \
  && "${args[index + 2]:-}" == "/etc/resolv.conf" ]]; then
  if [[ "${MOCK_SUDO_WRITE_ETC_RESOLV_CONF:-}" == "1" ]]; then
    exit 0
  else
    exit 1
  fi
fi

if (( index >= ${#args[@]} )); then
  command_name="__validate__"
else
  payload_index=$index
  while [[ "${args[index]:-}" == *=* ]]; do
    ((index += 1))
  done
  if (( index >= ${#args[@]} )); then
    command_name="__validate__"
  else
    command_name="${args[index]##*/}"
  fi
fi

case ",${MOCK_SUDO_ALLOW:-}," in
  *",$command_name,"*)
    if [[ "$command_name" == "__validate__" ]]; then
      exit 0
    fi
    if (( payload_index < index )); then
      exec env "${args[@]:payload_index}"
    fi
    exec "${args[@]:index}"
    ;;
esac

printf 'mock sudo denied command: %s\n' "$command_name" >&2
exit 97
EOF
chmod +x "$TEST_MOCK_BIN/sudo"

# Create a deterministic fzf mock. It captures every call and supports:
# cancel (default), first, first-action, match, and response modes.
cat <<'EOF' > "$TEST_MOCK_BIN/fzf"
#!/usr/bin/env bash
set -u

if [[ -n "${MOCK_FZF_ARGS_FILE:-}" ]]; then
  {
    printf 'fzf'
    printf ' %q' "$@"
    printf '\n'
  } >> "$MOCK_FZF_ARGS_FILE"
fi

input_file="${MOCK_FZF_INPUT_FILE:-}"
if [[ -n "$input_file" ]]; then
  cat > "$input_file"
else
  input_file=$(mktemp "${TMPDIR:-/tmp}/zdx-fzf-input.XXXXXX")
  trap 'rm -f "$input_file"' EXIT
  cat > "$input_file"
fi

selected=""
case "${MOCK_FZF_MODE:-cancel}" in
  cancel)
    exit "${MOCK_FZF_STATUS:-130}"
    ;;
  first)
    selected=$(awk 'NF { print; exit }' "$input_file")
    ;;
  first-action)
    selected=$(awk -F '|' 'NF && $2 != ":" { print; exit }' "$input_file")
    [[ -n "$selected" ]] || selected=$(awk 'NF { print; exit }' "$input_file")
    ;;
  match)
    selected=$(awk -v needle="${MOCK_FZF_MATCH:-}" \
      'index($0, needle) { print; exit }' "$input_file")
    ;;
  response)
    selected="${MOCK_FZF_RESPONSE:-}"
    ;;
  *)
    printf 'mock fzf: unsupported mode: %s\n' "$MOCK_FZF_MODE" >&2
    exit 97
    ;;
esac

if [[ -n "${MOCK_FZF_EXPECT_KEY:-}" ]]; then
  printf '%s\n' "$MOCK_FZF_EXPECT_KEY"
fi
[[ -n "$selected" ]] && printf '%s\n' "$selected"
exit 0
EOF
chmod +x "$TEST_MOCK_BIN/fzf"

# Create mock gcloud
cat <<'EOF' > "$TEST_MOCK_BIN/gcloud"
#!/usr/bin/env bash
echo "mock gcloud called: $@"
exit 0
EOF
chmod +x "$TEST_MOCK_BIN/gcloud"

# Create mock gh
cat <<'EOF' > "$TEST_MOCK_BIN/gh"
#!/usr/bin/env bash
echo "mock gh called: $@"
exit 0
EOF
chmod +x "$TEST_MOCK_BIN/gh"

# Create mock lsattr
cat <<'EOF' > "$TEST_MOCK_BIN/lsattr"
#!/usr/bin/env bash
if [[ -n "$MOCK_LSATTR_ETC_RESOLV_CONF" ]]; then
  echo "$MOCK_LSATTR_ETC_RESOLV_CONF"
  exit 0
fi
echo "--------- $1"
exit 0
EOF
chmod +x "$TEST_MOCK_BIN/lsattr"

# Create mock chattr
cat <<'EOF' > "$TEST_MOCK_BIN/chattr"
#!/usr/bin/env bash
echo "mock chattr called: $@"
exit 0
EOF
chmod +x "$TEST_MOCK_BIN/chattr"

# Create mock install
cat <<'EOF' > "$TEST_MOCK_BIN/install"
#!/usr/bin/env bash
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|-g)
      shift 2
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
if [[ -x /usr/bin/install ]]; then
  exec /usr/bin/install "${args[@]}"
elif [[ -x /bin/install ]]; then
  exec /bin/install "${args[@]}"
else
  exec cp "${args[@]}"
fi
EOF
chmod +x "$TEST_MOCK_BIN/install"

# Create mock pgrep
cat <<'EOF' > "$TEST_MOCK_BIN/pgrep"
#!/usr/bin/env bash
if [[ "$*" == *apt-get* || "$*" == *dpkg* || "$*" == *unattended-upgr* ]]; then
  if [[ "$MOCK_APT_LOCKED" == "1" ]]; then
    echo "99999"
    exit 0
  else
    exit 1
  fi
fi

if [[ "$*" == *brew* ]]; then
  if [[ "$MOCK_BREW_LOCKED" == "1" ]]; then
    echo "99998"
    exit 0
  else
    exit 1
  fi
fi

exit 1
EOF
chmod +x "$TEST_MOCK_BIN/pgrep"

# Create mock df
cat <<'EOF' > "$TEST_MOCK_BIN/df"
#!/usr/bin/env bash
if [[ "$MOCK_DF_LOW_SPACE" == "1" ]]; then
  echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
  echo "/dev/sda1 1000000 990000 10000 99% /"
else
  echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
  echo "/dev/sda1 1000000 500000 500000 50% /"
fi
exit 0
EOF
chmod +x "$TEST_MOCK_BIN/df"

cleanup_sandbox() {
  local sandbox_root="${TEST_TEMP_DIR:-}"
  local expected_home="${sandbox_root}/home"

  if [[ -z "$sandbox_root" \
    || "$sandbox_root" == "/" \
    || "$sandbox_root" != */zdx-tests.* \
    || "${HOME:-}" != "$expected_home" ]]; then
    printf 'Refusing to remove unexpected test sandbox: %s\n' \
      "${sandbox_root:-<empty>}" >&2
    return 1
  fi

  chmod -R +w "$sandbox_root" 2>/dev/null || true
  rm -rf -- "$sandbox_root"
}

# Run code in Zsh subshell with sandbox environment variables
run_zsh() {
  local cmd="$1"
  # shellcheck disable=SC2016,SC2140
  zsh -c "
    export ZSH_CUSTOM='$TEST_SUITE_ROOT'
    export HOME='$HOME'
    export PATH='$PATH'
    export WS_BASE_DIR='$HOME/workspaces'
    export TEST_MOCK_BIN='$TEST_MOCK_BIN'

    # Propagate mock flags
    export MOCK_SUDO_WRITE_ETC_RESOLV_CONF='$MOCK_SUDO_WRITE_ETC_RESOLV_CONF'
    export MOCK_LSATTR_ETC_RESOLV_CONF='$MOCK_LSATTR_ETC_RESOLV_CONF'
    export MOCK_APT_LOCKED='$MOCK_APT_LOCKED'
    export MOCK_BREW_LOCKED='$MOCK_BREW_LOCKED'
    export MOCK_DF_LOW_SPACE='$MOCK_DF_LOW_SPACE'
    export MOCK_CHATTR_MISSING='$MOCK_CHATTR_MISSING'

    # Override command to simulate missing binaries
    command() {

      if [[ "\$1" == "-v" && "\$2" == "chattr" && "\$MOCK_CHATTR_MISSING" == "1" ]]; then
        return 1
      fi
      builtin command "\$@"
    }

    # Prefer an explicit test-local kill mock. Falling back to the builtin is
    # required by timeout tests that terminate only their own child process.
    kill() {
      if [[ -x "\$TEST_MOCK_BIN/kill" ]]; then
        command "\$TEST_MOCK_BIN/kill" "\$@"
      else
        builtin kill "\$@"
      fi
    }

    # Source the entry point
    source \$ZSH_CUSTOM/functions.zsh

    # Bypass /proc directory checks in test environment to make tests hermetic
    _sys_ports_proc_exists() {
      ps -p "\$1" &>/dev/null
    }

    # Execute command
    $cmd
  " < /dev/null
}
