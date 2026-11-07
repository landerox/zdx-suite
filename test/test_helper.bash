# test_helper.bash - shared helper for BATS test suite

# Status assertions use run -N (BATS 1.5+). Plain Bash probes also source this
# helper, so declare the requirement only when the BATS API is available.
if declare -F bats_require_minimum_version >/dev/null; then
  bats_require_minimum_version 1.5.0
fi

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

# A caller's BASH_ENV runs again in every Bash mock and nested `bash -c`, and
# ENV in every interactive POSIX shell; either can export what this helper
# clears. Unsetting LOCPATH and PATH_LOCALE keeps them from child processes.
# This process may already have read them: macOS reads PATH_LOCALE once per
# process, so a caller that starts BATS with a PATH_LOCALE that hides the
# locales gets the no-UTF-8 error below.
unset BASH_ENV ENV LOCPATH PATH_LOCALE

# --- Locale and terminal ------------------------------------------------------
# The product degrades on purpose under a C or POSIX locale, under TERM=dumb,
# and under NO_COLOR, and it sizes banners from COLUMNS, so the caller's values
# would change what every test observes. Every test starts from one UTF-8
# locale and a capable terminal; a test of those branches exports its own
# values after setup.

# _zdx_test_locale_works NAME: true when NAME switches Bash to UTF-8 text. A
# locale the host lacks leaves C in force, where the two-byte character below
# counts as two characters.
_zdx_test_locale_works() {
  (
    LC_ALL=C
    LC_ALL="$1"
    _zdx_test_text=$'\303\251'
    (( ${#_zdx_test_text} == 1 ))
  ) 2>/dev/null
}

# _zdx_test_utf8_locale: print the first UTF-8 locale that works here:
# C.UTF-8, then en_US.UTF-8 on Linux; en_US.UTF-8, then C.UTF-8 on macOS; then
# any other UTF-8 locale that `locale -a` lists. A test of the failure below
# defines the indexed array _zdx_test_locale_candidates before it sources this
# file, and only those names are tried. The environment cannot carry a Bash
# array, so a caller cannot choose the candidates.
_zdx_test_utf8_locale() {
  local -a preferred=(C.UTF-8 en_US.UTF-8)
  local -i scan_listed=1
  # shellcheck disable=SC2154 # the sourcing test defines it, if anything does
  if [[ "$(declare -p _zdx_test_locale_candidates 2>/dev/null)" == "declare -a "* ]]; then
    preferred=("${_zdx_test_locale_candidates[@]}")
    scan_listed=0
  elif [[ "$TEST_HOST_OS" == Darwin ]]; then
    preferred=(en_US.UTF-8 C.UTF-8)
  fi
  local name
  for name in "${preferred[@]}"; do
    if _zdx_test_locale_works "$name"; then
      printf '%s\n' "$name"
      return 0
    fi
  done
  (( scan_listed )) || return 1
  while IFS= read -r name; do
    [[ "$name" =~ \.[Uu][Tt][Ff]-?8$ ]] || continue
    if _zdx_test_locale_works "$name"; then
      printf '%s\n' "$name"
      return 0
    fi
  done < <(locale -a 2>/dev/null)
  return 1
}

# A host without a UTF-8 locale fails every test here, instead of running
# them under C and reporting the product's C-locale output as failures.
if ! TEST_UTF8_LOCALE=$(_zdx_test_utf8_locale); then
  printf 'test_helper: no UTF-8 locale works on this host; the tests do not run under C.\n' >&2
  printf 'test_helper: install C.UTF-8 or en_US.UTF-8 (Debian and Ubuntu: apt install locales).\n' >&2
  # No sandbox exists yet, so teardown has nothing to remove.
  cleanup_sandbox() { :; }
  return 1
fi
export TEST_UTF8_LOCALE
# LC_ALL and each LC_* category override LANG, and LANGUAGE overrides the
# message language of a UTF-8 locale, so LANG alone decides here. A test can
# still narrow one category, such as LC_COLLATE=C, or set LC_ALL itself.
unset LC_ALL LANGUAGE "${!LC_@}"
export LANG="$TEST_UTF8_LOCALE"
export TERM=xterm-256color
# The terminal size and database, and the color switches that tools honor.
unset COLUMNS LINES TERMINFO TERMINFO_DIRS TERMCAP
unset NO_COLOR COLORTERM FORCE_COLOR CLICOLOR CLICOLOR_FORCE
# fzf reads its FZF_DEFAULT_* variables in every picker a test runs.
unset "${!FZF_DEFAULT_@}"

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

# An exported ZDOTDIR points every Zsh that a test starts without -f at the
# caller's startup files.
unset ZDOTDIR

# Neutralize package-manager controls injected by developer shells and hosted
# runners. Individual tests export hostile values explicitly when exercising
# environment hardening.
unset HOMEBREW_CURL_RETRIES HOMEBREW_NO_ANALYTICS HOMEBREW_NO_AUTO_UPDATE
unset HOMEBREW_NO_ENV_HINTS SUDO_ASKPASS SYS_APT_KEY_RENEWAL
# Tool homes that the System cleanup resolves: a developer shell's values
# point outside the sandbox HOME.
unset NVM_DIR CODEX_HOME PRE_COMMIT_HOME CARGO_HOME RUSTUP_HOME

# Clear every GIT_* variable the caller exports, before the helper sets its
# own. Git exports repository variables such as GIT_DIR to its hooks:
# inherited by the pre-push `just check`, they redirect every fixture
# repository a test creates into the real one, and from a linked worktree that
# rewrites its shared config and refs. Every name that
# `git rev-parse --local-env-vars` reports starts with GIT_. The other GIT_*
# variables reach around the sandbox HOME: GIT_CONFIG_GLOBAL names the
# caller's real global configuration, with its hooks, signing, URL rewrites,
# and templates, and GIT_AUTHOR_*, GIT_COMMITTER_*, GIT_TEMPLATE_DIR,
# GIT_SSH_COMMAND, and GIT_TRACE* change fixture commits, transports, or
# stderr. Tests and suite helpers export their own values after setup.
unset "${!GIT_@}"

# HOME already isolates global Git configuration; also ignore the system file.
# Homebrew's Git ships one that selects the macOS keychain credential helper.
export GIT_CONFIG_NOSYSTEM=1
# The caller's suite settings, such as ZDX_VERBOSE, ZDX_FZF_PLAIN, or
# ZDX_TELEMETRY, would change what tests observe, and a caller's
# ZDX_PLUGINS_DIR would let the loader run the caller's real plugins. Clear
# every ZDX_* variable: the plugin root then resolves to the sandbox default,
# $HOME/.config/zdx/plugins, and follows a test that changes HOME. Tests
# export their own values after setup.
unset "${!ZDX_@}"
# Other settings the suites read from the environment, as their code and
# contracts name them. Report and backup directories would also send writes
# outside the sandbox. A test that needs one sets it after setup.
unset VPN_CONFIG_DIR VPN_CACHE_DIR VPN_MENU_REPORT_DIR VPN_MENU_REPORT_RETENTION
unset VPN_MENU_WSL_IPV6_FIX VPN_MENU_MTU_TARGET VPN_MENU_IP_CROSSCHECK
unset VPN_MENU_IPINFO_URL VPN_MENU_IPINFO_URLS VPN_MENU_IPINFO_PLAIN_URLS
unset VPN_MENU_IPINFO_TRACE_URLS VPN_DNS_FALLBACK_PRIMARY VPN_DNS_FALLBACK_SECONDARY
unset DEV_SUITE_DEBUG DEV_REPORT_DIR DEV_BACKUP_DIR DEV_BACKUP_RETENTION
unset DEV_SCAN_DEPTH DEV_CLEAN_DEPTH DEV_CLEAN_MAX_TARGETS DEV_ALLOW_EPHEMERAL
unset DEV_PYPI_JOBS DEV_PYPI_RETRIES DEV_PYPI_TIMEOUT
unset DEV_ACTIONS_TIMEOUT DEV_ACTIONS_COOLDOWN_DAYS
unset PY_SUITE_DEBUG SYS_APT_AUTOMATIC_TAKEOVER SYS_COMMAND_CAPTURE_MAX_BYTES
unset SYS_HEALTH_INCLUDE_APPLE_JOBS SYS_TELEMETRY_MAX_READ_BYTES
unset WS_BASE_DIR WS_MAX_DEPTH WS_FETCH_JOBS WS_EXCLUDE FILE_EXTRACT_MAX_GIB
# Tool settings the suites read: editors, the pager, the active Python
# environment, and the display that picks a clipboard tool.
unset EDITOR VISUAL SUDO_EDITOR LESS VIRTUAL_ENV CONDA_PREFIX
unset DISPLAY WAYLAND_DISPLAY
# Tests run a real uv and python3, which read every UV_* and PYTHON*
# variable: UV_CACHE_DIR or PYTHONPYCACHEPREFIX would write outside the
# sandbox, UV_INDEX_URL would change where uv resolves packages, and
# PYTHONPATH, PYTHONHOME, or PYTHONUSERBASE would load the caller's modules.
# No test runs a real pip, so PIP_* variables are left as they are.
unset "${!UV_@}" "${!PYTHON@}"
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

# Create mock pgrep. No production code scans process names, and a test must
# never observe the host's processes.
cat <<'EOF' > "$TEST_MOCK_BIN/pgrep"
#!/usr/bin/env bash
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
    emulate -R zsh
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

# Run code in a Zsh subshell with sandbox environment variables. -f reads no
# startup files except the system-wide zshenv (/etc/zshenv, or /etc/zsh/zshenv
# on Debian and Ubuntu), which Zsh always reads first. emulate -R then gives
# every option its Zsh default again, except the options that describe the
# interactive environment; functions, aliases, and variables that file defines
# remain.
run_zsh() {
  local cmd="$1"
  # shellcheck disable=SC2016,SC2140
  zsh -f -c "
    emulate -R zsh
    export ZSH_CUSTOM='$TEST_SUITE_ROOT'
    export HOME='$HOME'
    export PATH='$PATH'
    export WS_BASE_DIR='$HOME/workspaces'
    export TEST_MOCK_BIN='$TEST_MOCK_BIN'

    # Propagate mock flags
    export MOCK_SUDO_WRITE_ETC_RESOLV_CONF='$MOCK_SUDO_WRITE_ETC_RESOLV_CONF'
    export MOCK_LSATTR_ETC_RESOLV_CONF='$MOCK_LSATTR_ETC_RESOLV_CONF'
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

# Build real private metadata launchers; the base stdlib/framework remains installed.
_zdx_test_dev_preview_private_python() {
  local candidate resolved bootstrap="" binary
  [[ "$HOME" == "$TEST_TEMP_DIR/home" && -d "$HOME" && ! -L "$HOME" ]] || return 1
  for candidate in /usr/bin/python3 python3 python3.15 python3.14 python3.13 python3.12 python3.11; do
    resolved=$(command -v "$candidate" 2>/dev/null) || continue
    # Do not execute Apple's Command Line Tools placeholder during setup.
    [[ "$TEST_HOST_OS" != Darwin || "$resolved" != /usr/bin/python3 ]] || continue
    if "$resolved" -B -I -S -c 'import sys, tomllib, venv; assert sys.version_info >= (3, 11)' \
      >/dev/null 2>&1; then
      bootstrap="$resolved"
      break
    fi
  done
  [[ -n "$bootstrap" ]] || { printf '%s\n' 'A real installed Python 3.11+ with venv and tomllib is required.' >&2; return 1; }
  export PREVIEW_PYTHON_ENV="$HOME/preview-python"
  [[ ! -e "$PREVIEW_PYTHON_ENV" && ! -L "$PREVIEW_PYTHON_ENV" ]] || return 1
  (umask 077; "$bootstrap" -B -I -S -m venv --without-pip --copies "$PREVIEW_PYTHON_ENV") || return 1
  export REAL_PREVIEW_PYTHON="$PREVIEW_PYTHON_ENV/bin/python"
  export PREVIEW_PYTHON_CONFIG="$PREVIEW_PYTHON_ENV/pyvenv.cfg"
  [[ -d "$PREVIEW_PYTHON_ENV" && ! -L "$PREVIEW_PYTHON_ENV" \
    && "$(file_mode "$PREVIEW_PYTHON_ENV")" == 700 \
    && "$(file_owner_uid "$PREVIEW_PYTHON_ENV")" == "$EUID" \
    && -f "$PREVIEW_PYTHON_CONFIG" && ! -L "$PREVIEW_PYTHON_CONFIG" ]] || return 1
  # The resolver probes this capability name; sys.version remains the real version.
  if [[ ! -e "$PREVIEW_PYTHON_ENV/bin/python3.14" && ! -L "$PREVIEW_PYTHON_ENV/bin/python3.14" ]]; then
    cp "$REAL_PREVIEW_PYTHON" "$PREVIEW_PYTHON_ENV/bin/python3.14" || return 1
    chmod -- 755 "$PREVIEW_PYTHON_ENV/bin/python3.14" || return 1
  fi
  for binary in "$REAL_PREVIEW_PYTHON" "$PREVIEW_PYTHON_ENV/bin/python3" "$PREVIEW_PYTHON_ENV/bin/python3.14"; do
    [[ -f "$binary" && ! -L "$binary" && -x "$binary" \
      && "$(file_owner_uid "$binary")" == "$EUID" \
      && "$(file_mode "$binary")" == 755 ]] || return 1
  done
  [[ "$(file_identity "$REAL_PREVIEW_PYTHON")" != "$(file_identity "$PREVIEW_PYTHON_ENV/bin/python3")" \
    && "$(file_identity "$REAL_PREVIEW_PYTHON")" != "$(file_identity "$PREVIEW_PYTHON_ENV/bin/python3.14")" ]] || return 1
  "$REAL_PREVIEW_PYTHON" -B -I -S -c 'import sys, tomllib; assert sys.version_info >= (3, 11)' || return 1
  "$REAL_PREVIEW_PYTHON" -B -I -c \
    'from pathlib import Path; import sys; assert Path(sys.prefix).resolve() == Path(sys.argv[1])' \
    "$PREVIEW_PYTHON_ENV" || return 1
  # Hostile mock-bin entries must still be considered before a safe fallback.
  export PATH="$TEST_MOCK_BIN:$PREVIEW_PYTHON_ENV/bin:$PATH"
}

# Emit fixed test-only observers; their original calls retain all streams and status.
_zdx_test_dev_preview_diagnostic_program() {
  cat <<'ZSH'
# Keep the first literal rejection, including expected unsafe-path controls.
_zdx_test_dev_preview_note() {
  emulate -L zsh
  local REPLY _zdx_test_role="$1" _zdx_test_rc="$2" _zdx_test_exec="$3"
  local _zdx_test_log="$HOME/dev-preview-qualification.log" _zdx_test_item
  local _zdx_test_path _zdx_test_depth
  local -A _zdx_test_state=()
  [[ "$HOME" == "$TEST_TEMP_DIR/home" && -d "$HOME" && ! -L "$HOME" \
    && ! -e "$_zdx_test_log" && ! -L "$_zdx_test_log" ]] || return 0
  [[ "$_zdx_test_exec" == /* && ${#_zdx_test_exec} -le 512 \
    && "$_zdx_test_exec" != *[[:cntrl:]]* ]] || return 0
  case "${_zdx_test_exec:t}" in
    python*|Python|uv|pre-commit|sha256sum|shasum) ;;
    *) return 0 ;;
  esac
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 0
  (
    umask 077
    setopt NOCLOBBER
    {
      printf 'Preview qualification: first rejection; role=%s status=%s\n' \
        "$_zdx_test_role" "$_zdx_test_rc"
      print -r -- 'Passive metadata after rejection; no candidate was rerun.'
      for _zdx_test_item in "$_zdx_test_exec" "${_zdx_test_exec:A}"; do
        [[ ${#_zdx_test_item} -le 512 \
          && "$_zdx_test_item" != *[[:cntrl:]]* ]] || continue
        _zdx_test_path="$_zdx_test_item"
        _zdx_test_depth=0
        while (( _zdx_test_depth < 32 )); do
          _zdx_test_state=()
          if zstat -LH _zdx_test_state -- "$_zdx_test_path" 2>/dev/null; then
            printf 'path=%q uid=%s gid=%s mode=%o type=%o device=%s inode=%s\n' \
              "$_zdx_test_path" "${_zdx_test_state[uid]}" "${_zdx_test_state[gid]}" \
              "${_zdx_test_state[mode]}" "$(( _zdx_test_state[mode] & 8#170000 ))" \
              "${_zdx_test_state[device]}" "${_zdx_test_state[inode]}"
          else
            printf 'path=%q metadata=unavailable\n' "$_zdx_test_path"
          fi
          [[ "$_zdx_test_path" == / ]] && break
          _zdx_test_path="${_zdx_test_path:h}"
          (( ++_zdx_test_depth ))
        done
      done
    } > "$_zdx_test_log"
  ) 2>/dev/null || :
  return 0
}

if (( ${+functions[_dev_preview_exec_snapshot]} \
  && ${+functions[_dev_preview_exec_guard]} \
  && ${+functions[_dev_run_with_timeout]} \
  && ! ${+functions[_zdx_test_dev_preview_original_snapshot]} )); then
  functions[_zdx_test_dev_preview_original_snapshot]="${functions[_dev_preview_exec_snapshot]}"
  functions[_zdx_test_dev_preview_original_guard]="${functions[_dev_preview_exec_guard]}"
  functions[_zdx_test_dev_preview_original_timeout]="${functions[_dev_run_with_timeout]}"
  _dev_preview_exec_snapshot() {
    _zdx_test_dev_preview_original_snapshot "$@"
    local _zdx_test_rc=$?
    if (( _zdx_test_rc != 0 )); then
      _zdx_test_dev_preview_note snapshot "$_zdx_test_rc" "${1:-}" 2>/dev/null || :
    fi
    return "$_zdx_test_rc"
  }
  _dev_preview_exec_guard() {
    _zdx_test_dev_preview_original_guard "$@"
    local _zdx_test_rc=$?
    if (( _zdx_test_rc != 0 )); then
      _zdx_test_dev_preview_note guard "$_zdx_test_rc" "${1:-}" 2>/dev/null || :
    fi
    return "$_zdx_test_rc"
  }
  _dev_run_with_timeout() {
    _zdx_test_dev_preview_original_timeout "$@"
    local _zdx_test_rc=$? _zdx_test_program="${2:-}"
    if (( _zdx_test_rc != 0 && ${_DEV_PREVIEW_EXEC_TRUST:-0} )) \
      && [[ "${_zdx_test_program:t}" == sha256sum || "${_zdx_test_program:t}" == shasum ]]; then
      _zdx_test_dev_preview_note hash-service "$_zdx_test_rc" "$_zdx_test_program" 2>/dev/null || :
    fi
    return "$_zdx_test_rc"
  }
fi
ZSH
}

# BATS buffers teardown output and exposes it with failures, even after redirection.
_zdx_test_dev_preview_diagnostic_dump() {
  local diagnostic_log="$HOME/dev-preview-qualification.log" diagnostic_line diagnostic_count=0
  [[ -f "$diagnostic_log" && ! -L "$diagnostic_log" && -s "$diagnostic_log" ]] || return 0
  while IFS= read -r diagnostic_line || [[ -n "$diagnostic_line" ]]; do
    printf '%s\n' "$diagnostic_line" >&2 || return 0
    diagnostic_count=$((diagnostic_count + 1))
    [[ "$diagnostic_count" -lt 70 ]] || break
  done < "$diagnostic_log"
  return 0
}

# Prints the body Zsh stores for _<prefix>_<base> with every `_<prefix>_`
# replaced by `_P_` and each NOUN argument by `NOUN`, after the core and every
# suite common file are sourced, so duplicated primitives compare as text.
# Usage: normalized_function_body PREFIX BASE [NOUN...]
normalized_function_body() {
  local prefix="$1" base="$2"
  shift 2
  zsh -f -c '
    emulate -R zsh
    source "$1/functions.zsh" 2>/dev/null || exit 90
    local common
    for common in "$1"/functions/*-common.zsh; do
      source "$common" 2>/dev/null || exit 91
    done
    local name="_${2}_${3}" body="" noun=""
    (( ${+functions[$name]} )) || exit 92
    body="${functions[$name]//_${2}_/_P_}"
    shift 3
    for noun in "$@"; do
      body="${body//$noun/NOUN}"
    done
    print -r -- "$body"
  ' _ "$TEST_SUITE_ROOT" "$prefix" "$base" "$@"
}
