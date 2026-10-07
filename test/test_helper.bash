# test_helper.bash - shared helper for BATS test suite

# Bash before 4.1 does not apply errexit to a failing [[ ]] or (( )) that is
# not a test's last command, so most assertions would pass without checking
# anything. Refuse such a shell (macOS /bin/bash is 3.2) instead of reporting
# a false success; setup_suite.bash applies the same floor once per run.
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 1) )); then
  printf 'test_helper: Bash 4.1 or newer is required; this is Bash %s (%s).\n' \
    "$BASH_VERSION" "$BASH" >&2
  printf 'test_helper: put a current Bash first on PATH (macOS: brew install bash).\n' >&2
  # No sandbox exists yet, so teardown has nothing to remove.
  cleanup_sandbox() { :; }
  return 1
fi

# BATS 1.13 and 1.14 keep the BATS_TEST_TIMEOUT watchdog's PID in a variable
# local to their test runner. A failing test exits where that local is out of
# scope, so the watchdog is never stopped: the run waits for it, and when it
# fires it signals a test PID the system may have reused. A global copy, made
# while the local is visible here, lets BATS stop it on every exit path. Older
# releases pass the PID to their traps and ignore the copy.
if [[ -n "${BATS_killer_pid:-}" ]]; then
  declare -g BATS_killer_pid="$BATS_killer_pid" 2>/dev/null || true
fi

# Locate repo root
TEST_SUITE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEST_SUITE_ROOT

# Record the host kernel before any test can shadow uname with a mock.
TEST_HOST_OS=$(uname -s 2>/dev/null || true)
export TEST_HOST_OS

# Setup temp directory for sandbox. Resolve it physically: macOS reaches its
# per-user TMPDIR through the /var -> /private/var symlink, and production
# code correctly refuses symlinked temporary, state, and home paths. A
# canonical sandbox makes every derived path (HOME, TMPDIR, fixtures) real.
_zdx_test_parent="${TMPDIR:-/tmp}"
[[ "$_zdx_test_parent" == / ]] || _zdx_test_parent="${_zdx_test_parent%/}"
export TEST_TEMP_DIR
TEST_TEMP_DIR=$(mktemp -d "$_zdx_test_parent/zdx-tests.XXXXXX") || return 1
TEST_TEMP_DIR=$(cd "$TEST_TEMP_DIR" && pwd -P) || return 1
unset _zdx_test_parent
# cleanup_sandbox refuses any root other than the one created here.
_ZDX_TEST_SANDBOX_ROOT="$TEST_TEMP_DIR"
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME"

# Give every test a private, canonical TMPDIR so production code never sees
# the host's temporary directory unless a test sets one deliberately.
export TMPDIR="$TEST_TEMP_DIR/tmpdir"
mkdir -m 700 "$TMPDIR" || return 1

# Neutralize inherited XDG base directories. Redirecting HOME alone does not
# isolate the sandbox: suites resolve their state through
# "${XDG_CONFIG_HOME:-$HOME/.config}", so a host that exports XDG_CONFIG_HOME
# (GitHub's runners do) points profile state outside the sandbox HOME and the
# private-path guards correctly refuse it. Unsetting these makes every suite
# fall back to the HOME-derived defaults the sandbox owns, so the suite behaves
# identically on a developer machine and on a clean runner.
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME
unset XDG_RUNTIME_DIR XDG_CONFIG_DIRS XDG_DATA_DIRS

# An exported ZDOTDIR would make every `zsh -c` read the caller's .zshenv.
unset ZDOTDIR

# Neutralize package-manager controls injected by developer shells and hosted
# runners. Individual tests export hostile values explicitly when exercising
# environment hardening.
unset HOMEBREW_CURL_RETRIES HOMEBREW_NO_ANALYTICS HOMEBREW_NO_AUTO_UPDATE
unset HOMEBREW_NO_ENV_HINTS SUDO_ASKPASS SYS_APT_KEY_RENEWAL

# Git exports repository variables such as GIT_DIR to its hooks. Inherited by
# the pre-push `just check`, they redirect every fixture repository a test
# creates into the real one; from a linked worktree that rewrites its shared
# config and refs. Clear the complete set Git itself reports as repository-local.
# shellcheck disable=SC2046
unset $(command git rev-parse --local-env-vars 2>/dev/null)

# HOME already isolates global Git configuration; also ignore the system file.
# Homebrew's Git ships one that selects the macOS keychain credential helper.
export GIT_CONFIG_NOSYSTEM=1
# Suites probe fzf for template support once per shell; mocked fzf scripts that
# answer each call differently would see that probe, so tests opt in explicitly.
export ZDX_FZF_TEMPLATES=0

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

# The VPN suite's fixed privileged metadata probe runs a trusted zsh whose
# program names itself zdx-vpn-stat. Allowlist it by that name only, so a test
# can permit the probe without permitting zsh in general.
if [[ "$command_name" == zsh && "${args[index + 1]:-}" == -f \
  && "${args[index + 2]:-}" == -c && "${args[index + 4]:-}" == zdx-vpn-stat ]]; then
  command_name="zdx-vpn-stat"
fi

case ",${MOCK_SUDO_ALLOW:-}," in
  *",$command_name,"*)
    if [[ "$command_name" == "__validate__" ]]; then
      exit 0
    fi
    # Lets a mock model a root-only answer for commands run through sudo.
    export MOCK_SUDO_ROOT=1
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

# Create a deny-by-default ssh mock. OpenSSH reads the account's home from the
# password database rather than HOME, so the real client would consult the
# developer's or runner's configuration. Only the local configuration query
# `ssh -G [--] HOST` is answered, as for a host without any configuration.
cat <<'EOF' > "$TEST_MOCK_BIN/ssh"
#!/usr/bin/env bash
if [[ "${1:-}" == -G ]]; then
  shift
  [[ "${1:-}" == -- ]] && shift
  if [[ $# -eq 1 && -n "$1" && "$1" != -* ]]; then
    printf 'user git\nhostname %s\nport 22\n' "$1"
    exit 0
  fi
fi
printf 'mock ssh denied: %s\n' "$*" >&2
exit 97
EOF
chmod +x "$TEST_MOCK_BIN/ssh"

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

# --- Portable assertions ------------------------------------------------------
# GNU and BSD userlands disagree on stat(1), sha256sum, truncate, and script.
# Tests use these helpers instead, so the same assertion runs unchanged on
# Linux and macOS. Metadata comes from Zsh's stat module, which the suite
# already requires, and describes the path itself (lstat), like `stat -c`.

# file_stat PATH ELEMENT...: print the named zstat elements of PATH joined by
# colons. "mode" prints the octal permission bits (as `stat -c %a`); other
# elements are zstat's decimal values (device, inode, nlink, uid, size, ...).
file_stat() {
  local path="$1"
  shift
  zsh -fc '
    zmodload -F zsh/stat b:zstat || exit 2
    local target="$1" element
    shift
    local -A state
    local -a values
    zstat -LH state -- "$target" || exit 1
    for element in "$@"; do
      if [[ "$element" == mode ]]; then
        values+=("$(( [##8] state[mode] & 8#7777 ))")
      else
        [[ -n "${state[$element]+set}" ]] || exit 2
        values+=("${state[$element]}")
      fi
    done
    print -r -- "${(j.:.)values}"
  ' zdx-test-stat "$path" "$@"
}

# file_mode PATH: octal permission bits, such as 600 or 1500.
file_mode() { file_stat "$1" mode; }

# file_owner_uid PATH: numeric owner.
file_owner_uid() { file_stat "$1" uid; }

# file_inode PATH: inode number.
file_inode() { file_stat "$1" inode; }

# file_identity PATH: device:inode, which changes when a path is replaced.
file_identity() { file_stat "$1" device inode; }

# file_links PATH: hard-link count.
file_links() { file_stat "$1" nlink; }

# file_size PATH: size in bytes.
file_size() { file_stat "$1" size; }

# sha256_file PATH: lowercase hex SHA-256 digest of the content only. Reading
# standard input keeps unusual file names out of the digest line.
sha256_file() {
  local digest
  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum < "$1") || return 1
  elif command -v shasum >/dev/null 2>&1; then
    digest=$(shasum -a 256 < "$1") || return 1
  else
    printf 'sha256_file: neither sha256sum nor shasum is available\n' >&2
    return 1
  fi
  printf '%s\n' "${digest%% *}"
}

# make_sized_file PATH BYTES: create PATH or set its size exactly, like
# `truncate -s BYTES PATH` (absent on macOS): existing content is kept up to
# BYTES and any extension reads as zeros.
make_sized_file() {
  command perl -e '
    open(my $file, ">>", $ARGV[0]) or die "make_sized_file: $ARGV[0]: $!\n";
    truncate($file, $ARGV[1]) or die "make_sized_file: $ARGV[0]: $!\n";
  ' "$1" "$2" || return 1
  [[ "$(file_size "$1")" == "$2" ]]
}

# has_util_linux_script: true only for util-linux script(1), whose -q -e -f -c
# options PTY tests use; BSD script accepts different options.
has_util_linux_script() {
  local version
  command -v script >/dev/null 2>&1 || return 1
  version=$(script --version 2>/dev/null) || return 1
  [[ "$version" == *util-linux* ]]
}

# host_is_darwin: the kernel recorded at load, so a uname mock cannot change it.
host_is_darwin() { [[ "$TEST_HOST_OS" == Darwin ]]; }

# skip_on_darwin REASON: skip a test whose subject is Linux-only by design.
skip_on_darwin() {
  if host_is_darwin; then
    skip "Linux-only by design: $1"
  fi
}

cleanup_sandbox() {
  local sandbox_root="${TEST_TEMP_DIR:-}"
  local expected_home="${sandbox_root}/home"

  if [[ -z "$sandbox_root" \
    || "$sandbox_root" == "/" \
    || "$sandbox_root" != */zdx-tests.* \
    || "$sandbox_root" != "${_ZDX_TEST_SANDBOX_ROOT:-}" \
    || "${HOME:-}" != "$expected_home" ]]; then
    printf 'Refusing to remove unexpected test sandbox: %s\n' \
      "${sandbox_root:-<empty>}" >&2
    return 1
  fi
  # Nothing to remove when a test already deleted its own sandbox.
  [[ -e "$sandbox_root" || -L "$sandbox_root" ]] || return 0
  if [[ -L "$sandbox_root" || ! -d "$sandbox_root" ]]; then
    printf 'Refusing to remove a test sandbox that is not a directory: %s\n' \
      "$sandbox_root" >&2
    return 1
  fi

  # Restore owner access everywhere, including directories a test made
  # unreadable, so removal cannot stop halfway. Symbolic links are not followed.
  chmod -R u+rwX "$sandbox_root" 2>/dev/null || true
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
      builtin command \"\$@\"
    }

    # Prefer an explicit test-local kill mock. Falling back to the builtin is
    # required by timeout tests that terminate only their own child process.
    kill() {
      if [[ -x "\$TEST_MOCK_BIN/kill" ]]; then
        command \"\$TEST_MOCK_BIN/kill\" \"\$@\"
      else
        builtin kill \"\$@\"
      fi
    }

    # Source the entry point
    source \$ZSH_CUSTOM/functions.zsh

    # Bypass /proc directory checks in test environment to make tests hermetic
    _sys_ports_proc_exists() {
      ps -p \"\$1\" &>/dev/null
    }

    # Execute command
    $cmd
  " < /dev/null
}
