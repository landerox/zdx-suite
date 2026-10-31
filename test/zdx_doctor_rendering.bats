#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  load core_options_test_helper
  unset FZF_DEFAULT_OPTS FZF_DEFAULT_OPTS_FILE FZF_DEFAULT_COMMAND
  export NO_COLOR=1
  export MOCK_DOCTOR_VERSION='0.74.3 (fixture)'
  export MOCK_DOCTOR_FZF_RC=0
  cat > "$TEST_MOCK_BIN/fzf" <<'MOCK'
#!/usr/bin/env bash
[[ "$#" -eq 1 && "$1" == --version ]] || exit 97
[[ -z "${FZF_DEFAULT_OPTS:-}${FZF_DEFAULT_OPTS_FILE:-}${FZF_DEFAULT_COMMAND:-}" ]] || exit 96
if IFS= read -r unexpected_input; then exit 95; fi
[[ -z "${MOCK_DOCTOR_VERSION:-}" ]] || printf '%s\n' "$MOCK_DOCTOR_VERSION"
exit "${MOCK_DOCTOR_FZF_RC:-0}"
MOCK
  chmod +x "$TEST_MOCK_BIN/fzf"
  cat > "$TEST_TEMP_DIR/doctor-fixture.zsh" <<'FIXTURE'
_zdx_doctor_detect_os() { print -r -- Linux; }
_zdx_doctor_detect_pkg_manager() { print -r -- none; }
_zdx_doctor_timeout_command() { return 1; }
_zdx_doctor_sha256_command() { return 1; }
command() {
  if [[ "${1:-}" == -v ]]; then
    [[ "${2:-}" == fzf ]]
  else
    builtin command "$@"
  fi
}
FIXTURE
}

teardown() { cleanup_sandbox; }

@test "doctor rendering: version probe isolates fzf defaults and leaves caller state intact" {
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions/zdx-doctor.zsh" || exit
    export FZF_DEFAULT_OPTS="--header-lines=999"
    export FZF_DEFAULT_OPTS_FILE="$HOME/unreadable-options"
    export FZF_DEFAULT_COMMAND="do-not-run"
    _zdx_doctor_get_version fzf <<< "must not be consumed" >"$HOME/version"
    probe_rc=$?
    (( probe_rc == 0 )) || exit 1
    [[ "$(<"$HOME/version")" == 0.74.3 ]] || exit 1
    [[ "$FZF_DEFAULT_OPTS" == --header-lines=999 \
      && "$FZF_DEFAULT_OPTS_FILE" == "$HOME/unreadable-options" \
      && "$FZF_DEFAULT_COMMAND" == do-not-run ]]
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
}

@test "doctor rendering: version failures and interruptions cannot become empty success" {
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions/zdx-doctor.zsh" || exit
    local expected_rc=0
    for expected_rc in 19 130 143; do
      export MOCK_DOCTOR_FZF_RC="$expected_rc"
      _zdx_doctor_get_version fzf >"$HOME/version"
      (( $? == expected_rc )) || exit 1
      [[ ! -s "$HOME/version" ]] || exit 1
    done
    export MOCK_DOCTOR_FZF_RC=0
    local invalid_version=""
    for invalid_version in "" "unexpected output"; do
      export MOCK_DOCTOR_VERSION="$invalid_version"
      _zdx_doctor_get_version fzf >"$HOME/version"
      (( $? == 1 )) || exit 1
      [[ ! -s "$HOME/version" ]] || exit 1
    done
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
}

@test "doctor rendering: report distinguishes a valid fzf version from a failed probe" {
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions/zdx-doctor.zsh" || exit
    source "$2/doctor-fixture.zsh" || exit
    zdx-doctor >"$HOME/stdout" 2>"$HOME/valid-report"
    (( $? == 1 )) || exit 1
    export MOCK_DOCTOR_FZF_RC=19
    zdx-doctor >"$HOME/stdout" 2>"$HOME/failed-report"
    (( $? == 1 ))
  ' _ "$TEST_SUITE_ROOT" "$TEST_TEMP_DIR"
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/stdout" ]
  grep -Fq 'fzf - Installed' "$HOME/valid-report"
  grep -Fq 'v0.74.3' "$HOME/valid-report"
  grep -Fq 'fzf - VERSION CHECK FAILED' "$HOME/failed-report"
  grep -Fq 'status 19' "$HOME/failed-report"
  grep -Fq 'Optional Suite-Specific Dependencies' "$HOME/failed-report"
  run grep -Fq 'fzf - Installed' "$HOME/failed-report"
  [ "$status" -eq 1 ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "doctor rendering: interrupted fzf probes stop later diagnostics" {
  for expected_rc in 130 143; do
    export MOCK_DOCTOR_FZF_RC="$expected_rc"
    run zsh -f -c '
      emulate -R zsh
      source "$1/functions/zdx-doctor.zsh" || exit
      source "$2/doctor-fixture.zsh" || exit
      zdx-doctor >"$HOME/stdout"
    ' _ "$TEST_SUITE_ROOT" "$TEST_TEMP_DIR"
    [ "$status" -eq "$expected_rc" ]
    [[ "$output" == *"fzf - VERSION CHECK FAILED"* ]]
    [[ "$output" != *"Optional Suite-Specific Dependencies"* ]]
    [ ! -s "$HOME/stdout" ]
  done
}

@test "doctor rendering: passive display context escapes terminal and source paths without secrets" {
  local copied_dir="$TEST_TEMP_DIR/"$'copy\033[31m\nproject'
  mkdir "$copied_dir"
  cp "$TEST_SUITE_ROOT/functions/zdx-doctor.zsh" "$copied_dir/zdx-doctor.zsh"
  run zsh -f -c '
    emulate -R zsh
    source "$1" || exit
    [[ "$_ZDX_DOCTOR_SOURCE_FILE" == "${1:A}" ]] || exit 1
    export TERM=$'\''vt100\033[31m\nforged-line'\''
    export ZDX_FZF_THEME="PRIVATE_THEME_VALUE"
    export FZF_DEFAULT_OPTS="PRIVATE_OPTIONS_VALUE"
    export FZF_DEFAULT_OPTS_FILE="PRIVATE_FILE_VALUE"
    export NO_COLOR=1
    PATH=""
    _zdx_doctor_visual_diagnostics >"$HOME/stdout" 2>"$HOME/display-report"
  ' _ "$copied_dir/zdx-doctor.zsh"
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/stdout" ]
  grep -Fq 'colors: disabled by NO_COLOR' "$HOME/display-report"
  grep -Fq 'custom theme: configured' "$HOME/display-report"
  grep -Fq 'options=set; file=set' "$HOME/display-report"
  grep -Fq 'Doctor source:' "$HOME/display-report"
  grep -Fq 'open a new shell' "$HOME/display-report"
  [ "$(wc -l < "$HOME/display-report")" -eq 3 ]
  run grep -Eq $'PRIVATE_|\033' "$HOME/display-report"
  [ "$status" -eq 1 ]
}

@test "doctor rendering: explicit plain mode takes precedence over a custom theme" {
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions/zdx-doctor.zsh" || exit
    unset NO_COLOR
    export ZDX_FZF_PLAIN=1 ZDX_FZF_THEME="PRIVATE_THEME_VALUE" TERM=xterm-256color
    _zdx_doctor_visual_diagnostics
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"colors: disabled by ZDX_FZF_PLAIN"* ]]
  [[ "$output" == *"custom theme: configured"* ]]
  [[ "$output" != *"PRIVATE_THEME_VALUE"* ]]
}

# Writes one fixture command that prints a fixed version text.
_doctor_fixture_command() {
  local name="$1"
  local text="$2"
  local status="${3:-0}"
  mkdir -p "$TEST_TEMP_DIR/doctor-bin"
  printf '#!/bin/sh\nprintf "%%s\\n" %s\nexit %s\n' \
    "'$text'" "$status" > "$TEST_TEMP_DIR/doctor-bin/$name"
  chmod +x "$TEST_TEMP_DIR/doctor-bin/$name"
}

# A complete, healthy toolset whose tar is BSD tar and whose GNU tar is gtar.
_doctor_fixture_macos_tools() {
  _doctor_fixture_command fzf '0.74.3 (fixture)'
  _doctor_fixture_command git 'git version 2.39.3 (Apple Git-146)'
  _doctor_fixture_command jq 'jq-1.7.1'
  _doctor_fixture_command gh 'gh version 2.45.0 (2024-03-04)'
  _doctor_fixture_command python3 'Python 3.12.3'
  _doctor_fixture_command curl 'curl 8.7.1 (x86_64-apple-darwin23.0) libcurl/8.7.1'
  _doctor_fixture_command wg-quick 'Usage: wg-quick [ up | down ]' 1
  _doctor_fixture_command wg 'wireguard-tools v1.0.20210914 - https://git.zx2c4.com/wireguard-tools/'
  _doctor_fixture_command uv 'uv 0.4.0 (fixture 2024-08-01)'
  _doctor_fixture_command pipx '1.4.3'
  _doctor_fixture_command tar 'bsdtar 3.5.3 - libarchive 3.7.4'
  _doctor_fixture_command gtar 'tar (GNU tar) 1.35'
  _doctor_fixture_command shasum 'shasum fixture'
  _doctor_fixture_command brew 'Homebrew fixture'
}

@test "doctor rendering: WSL is detected from interop, late interop, or the kernel release" {
  local fixture="$TEST_TEMP_DIR/proc"
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions/zdx-doctor.zsh" || exit
    unset WSL_DISTRO_NAME WSL_INTEROP
    OSTYPE=linux-gnu
    local fixture="$2" case_name="" release=""
    for case_name in interop late kernel-wsl2 kernel-wsl1 native; do
      command rm -rf -- "$fixture"
      command mkdir -p -- "$fixture/sys/fs/binfmt_misc" "$fixture/sys/kernel"
      release="6.8.0-45-generic"
      case "$case_name" in
        interop) : > "$fixture/sys/fs/binfmt_misc/WSLInterop" ;;
        late) : > "$fixture/sys/fs/binfmt_misc/WSLInterop-late" ;;
        kernel-wsl2) release="5.15.167.4-microsoft-standard-WSL2" ;;
        kernel-wsl1) release="4.4.0-19041-Microsoft" ;;
      esac
      print -r -- "$release" > "$fixture/sys/kernel/osrelease"
      print -r -- "$case_name=$(_zdx_doctor_detect_os "$fixture")"
    done
    WSL_DISTRO_NAME=Ubuntu
    print -r -- "variable=$(_zdx_doctor_detect_os "$fixture")"
  ' _ "$TEST_SUITE_ROOT" "$fixture"

  [ "$status" -eq 0 ]
  [ "$output" = $'interop=WSL\nlate=WSL\nkernel-wsl2=WSL\nkernel-wsl1=WSL\nnative=Linux\nvariable=WSL' ]
}

@test "doctor rendering: Linux prefers its system package manager over Linuxbrew" {
  _doctor_fixture_command brew 'Homebrew fixture'
  _doctor_fixture_command apt-get 'apt fixture'
  _doctor_fixture_command dnf 'dnf fixture'
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions/zdx-doctor.zsh" || exit
    print -r -- "linux=$(PATH="$2"; _zdx_doctor_detect_pkg_manager Linux)"
    print -r -- "wsl=$(PATH="$2"; _zdx_doctor_detect_pkg_manager WSL)"
    print -r -- "macos=$(PATH="$2"; _zdx_doctor_detect_pkg_manager macOS)"
    command rm -f -- "$2/apt-get" "$2/dnf"
    print -r -- "linuxbrew=$(PATH="$2"; _zdx_doctor_detect_pkg_manager Linux)"
    command rm -f -- "$2/brew"
    print -r -- "macos-none=$(PATH="$2"; _zdx_doctor_detect_pkg_manager macOS)"
  ' _ "$TEST_SUITE_ROOT" "$TEST_TEMP_DIR/doctor-bin"

  [ "$status" -eq 0 ]
  [ "$output" = $'linux=apt\nwsl=apt\nmacos=brew\nlinuxbrew=brew\nmacos-none=none' ]
}

@test "doctor rendering: a healthy macOS host passes with platform rows not applicable" {
  _doctor_fixture_macos_tools
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions/zdx-doctor.zsh" || exit
    OSTYPE=darwin23.0
    PATH="$2"
    zdx-doctor >"$3/stdout"
  ' _ "$TEST_SUITE_ROOT" "$TEST_TEMP_DIR/doctor-bin" "$TEST_TEMP_DIR"

  [ "$status" -eq 0 ]
  [ ! -s "$TEST_TEMP_DIR/stdout" ]
  [[ "$output" == *"Platform:      macOS"* ]]
  [[ "$output" == *"Pkg Manager:   brew"* ]]
  [[ "$output" == *"⊘ ip - Not applicable on macOS"* ]]
  [[ "$output" != *"findmnt"* ]]
  [[ "$output" == *"GNU tar - Available ($TEST_TEMP_DIR/doctor-bin/gtar, tar (GNU tar) 1.35)"* ]]
  [[ "$output" == *"timeout/gtimeout - Not found"*"slower Zsh watchdog"* ]]
  [[ "$output" == *"brew install coreutils provides the faster gtimeout"* ]]
  [[ "$output" == *"git - Installed ($TEST_TEMP_DIR/doctor-bin/git, v2.39.3)"* ]]
  [[ "$output" == *"python3 - Installed ($TEST_TEMP_DIR/doctor-bin/python3, v3.12.3)"* ]]
  [[ "$output" == *"curl - Installed ($TEST_TEMP_DIR/doctor-bin/curl, v8.7.1)"* ]]
  [[ "$output" == *"wg-quick - Installed ($TEST_TEMP_DIR/doctor-bin/wg-quick, v1.0.20210914)"* ]]
  [[ "$output" == *"No issues found"* ]]
  [[ "$output" != *"vinstalled"* && "$output" != *", v)"* ]]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "doctor rendering: command names that hide executables are reported, not counted" {
  _doctor_fixture_macos_tools
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions/zdx-doctor.zsh" || exit
    OSTYPE=darwin23.0
    PATH="$2"
    zdx-doctor
  ' _ "$TEST_SUITE_ROOT" "$TEST_TEMP_DIR/doctor-bin"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Command Names"* ]]

  run zsh -f -c '
    emulate -R zsh
    source "$1/functions/zdx-doctor.zsh" || exit
    typeset -gA _ZDX_LAZY_FILES=(git-status git-menu.zsh sys-info sys-menu.zsh)
    OSTYPE=darwin23.0
    PATH="$2"
    zdx-doctor
  ' _ "$TEST_SUITE_ROOT" "$TEST_TEMP_DIR/doctor-bin"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Command Names"*"No executable on PATH shares a ZDX command name"* ]]
  [[ "$output" == *"No issues found"* ]]

  _doctor_fixture_command git-status 'shadowed fixture'
  _doctor_fixture_command sys-info 'shadowed fixture'
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions/zdx-doctor.zsh" || exit
    typeset -gA _ZDX_LAZY_FILES=(git-status git-menu.zsh sys-info sys-menu.zsh zdx zdx-menu.zsh)
    OSTYPE=darwin23.0
    PATH="$2"
    zdx-doctor
  ' _ "$TEST_SUITE_ROOT" "$TEST_TEMP_DIR/doctor-bin"
  [ "$status" -eq 0 ]
  [[ "$output" == *"take precedence over these executables on PATH: git-status, sys-info"* ]]
  [[ "$output" == *"Run 'command NAME' to reach the executable."* ]]
  [[ "$output" == *"No issues found"* ]]
}

@test "doctor rendering: a BSD-only tar stays incompatible and names gtar" {
  _doctor_fixture_macos_tools
  rm "$TEST_TEMP_DIR/doctor-bin/gtar"
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions/zdx-doctor.zsh" || exit
    OSTYPE=darwin23.0
    PATH="$2"
    zdx-doctor
  ' _ "$TEST_SUITE_ROOT" "$TEST_TEMP_DIR/doctor-bin"

  [ "$status" -eq 1 ]
  [[ "$output" == *"GNU tar - INCOMPATIBLE ($TEST_TEMP_DIR/doctor-bin/tar, bsdtar 3.5.3"* ]]
  [[ "$output" == *"requires GNU tar, found as either tar or gtar"* ]]
  [[ "$output" == *"brew install gnu-tar"* ]]
  [[ "$output" == *"1 dependency or capability issue"* ]]
}

@test "doctor rendering: Apple placeholders are reported missing instead of being run" {
  _doctor_fixture_command xcode-select 'xcode-select: error: no developer tools' 2
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions/zdx-doctor.zsh" || exit
    PATH="$2:$PATH"
    OSTYPE=darwin23.0
    _zdx_doctor_clt_placeholder git /usr/bin/git && print -r -- "git=placeholder"
    _zdx_doctor_clt_placeholder python3 /usr/bin/python3 \
      && print -r -- "python3=placeholder"
    _zdx_doctor_clt_placeholder curl /usr/bin/curl || print -r -- "curl=system"
    _zdx_doctor_clt_placeholder git /opt/homebrew/bin/git \
      || print -r -- "homebrew=real"
  ' _ "$TEST_SUITE_ROOT" "$TEST_TEMP_DIR/doctor-bin"
  [ "$status" -eq 0 ]
  [ "$output" = $'git=placeholder\npython3=placeholder\ncurl=system\nhomebrew=real' ]

  mkdir -p "$TEST_TEMP_DIR/CommandLineTools"
  _doctor_fixture_command xcode-select "$TEST_TEMP_DIR/CommandLineTools"
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions/zdx-doctor.zsh" || exit
    PATH="$2:$PATH"
    OSTYPE=darwin23.0
    _zdx_doctor_clt_placeholder git /usr/bin/git || print -r -- "installed=real"
    OSTYPE=linux-gnu
    _zdx_doctor_clt_placeholder git /usr/bin/git || print -r -- "linux=real"
  ' _ "$TEST_SUITE_ROOT" "$TEST_TEMP_DIR/doctor-bin"
  [ "$status" -eq 0 ]
  [ "$output" = $'installed=real\nlinux=real' ]
}

@test "doctor rendering: a placeholder row never probes the Apple shim" {
  [[ -x /usr/bin/git && -x /usr/bin/python3 ]] \
    || skip "this host has no /usr/bin/git and /usr/bin/python3 to stand in for the shims"
  _doctor_fixture_macos_tools
  rm "$TEST_TEMP_DIR/doctor-bin/git" "$TEST_TEMP_DIR/doctor-bin/python3"
  _doctor_fixture_command xcode-select 'xcode-select: error: no developer tools' 2
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions/zdx-doctor.zsh" || exit
    OSTYPE=darwin23.0
    PATH="$2:/usr/bin"
    zdx-doctor
  ' _ "$TEST_SUITE_ROOT" "$TEST_TEMP_DIR/doctor-bin"

  [ "$status" -eq 1 ]
  [[ "$output" == *"git - MISSING"* ]]
  [[ "$output" == *"/usr/bin/git is an Apple Command Line Tools placeholder"* ]]
  [[ "$output" == *"python3 - MISSING"* ]]
  [[ "$output" == *"/usr/bin/python3 is an Apple Command Line Tools placeholder"* ]]
  [[ "$output" == *"Suggested Command: brew install git"* ]]
  [[ "$output" != *"git - Installed"* && "$output" != *"python3 - Installed"* ]]
}

@test "doctor rendering: failed or unrecognized version probes are never installed" {
  _doctor_fixture_macos_tools
  _doctor_fixture_command git '' 3
  _doctor_fixture_command python3 'unexpected output'
  rm "$TEST_TEMP_DIR/doctor-bin/wg"
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions/zdx-doctor.zsh" || exit
    OSTYPE=darwin23.0
    PATH="$2"
    zdx-doctor
  ' _ "$TEST_SUITE_ROOT" "$TEST_TEMP_DIR/doctor-bin"

  [ "$status" -eq 1 ]
  [[ "$output" == *"git - VERSION CHECK FAILED ($TEST_TEMP_DIR/doctor-bin/git, status 3)"* ]]
  [[ "$output" == *"python3 - VERSION CHECK FAILED ($TEST_TEMP_DIR/doctor-bin/python3, status 1)"*"[Developer & Python]"* ]]
  [[ "$output" == *"wg-quick - Installed ($TEST_TEMP_DIR/doctor-bin/wg-quick) [WireGuard VPN]"* ]]
  [[ "$output" != *"git - Installed"* && "$output" != *"python3 - Installed"* ]]
  [[ "$output" != *"vinstalled"* && "$output" != *", v)"* ]]
  [[ "$output" == *"2 dependency or capability issue"* ]]
}

@test "doctor rendering: Linux keeps ip as a counted capability" {
  _doctor_fixture_macos_tools
  _doctor_fixture_command tar 'tar (GNU tar) 1.35'
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions/zdx-doctor.zsh" || exit
    unset WSL_DISTRO_NAME WSL_INTEROP
    OSTYPE=linux-gnu
    _zdx_doctor_is_wsl() { return 1; }
    PATH="$2"
    zdx-doctor
  ' _ "$TEST_SUITE_ROOT" "$TEST_TEMP_DIR/doctor-bin"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Platform:      Linux"* ]]
  [[ "$output" == *"ip - MISSING (route lookups in VPN diagnostics) [VPN]"* ]]
  [[ "$output" != *"findmnt"* ]]
  [[ "$output" == *"GNU coreutils provides the faster timeout command"* ]]
  [[ "$output" == *"1 dependency or capability issue"* ]]
  [[ "$output" != *"Not applicable"* ]]
}

@test "F3-04 regex: doctor-version preserves seeded caller state" {
  f304_mock_local_probes
  run f304_regex_probe 'doctor-version' seeded
  [ "$status" -eq 0 ]
}

@test "F3-04 regex: doctor-version preserves unset caller state" {
  f304_mock_local_probes
  run f304_regex_probe 'doctor-version' unset
  [ "$status" -eq 0 ]
}

@test "F3-04 regex: doctor-package preserves seeded caller state" {
  f304_mock_local_probes
  run f304_regex_probe 'doctor-package' seeded
  [ "$status" -eq 0 ]
}

@test "F3-04 regex: doctor-package preserves unset caller state" {
  f304_mock_local_probes
  run f304_regex_probe 'doctor-package' unset
  [ "$status" -eq 0 ]
}

@test "F3-04 regression: the doctor report retains field meanings under hostile options" {
  f304_mock_local_probes
  run run_zsh '
    builtin cd -- "$HOME" || exit 80
    _zdx_doctor_detect_os() { print -r -- Linux; }
    _zdx_doctor_detect_pkg_manager() { print -r -- none; }
    _zdx_doctor_timeout_command() { return 1; }
    _zdx_doctor_sha256_command() { return 1; }
    command() {
      if [[ "${1:-}" == -v ]]; then
        [[ "${2:-}" == fzf ]]
      else
        builtin command "$@"
      fi
    }
    setopt ksh_arrays sh_word_split force_float pipe_fail
    zdx-doctor > "$HOME/doctor.data" 2> "$HOME/doctor.ui"
    local call_rc=$? kept="${options[ksharrays]}:${options[shwordsplit]}:${options[forcefloat]}:${options[pipefail]}"
    unsetopt ksh_arrays sh_word_split force_float pipe_fail
    [[ $call_rc == 1 && "$kept" == on:on:on:on ]] || exit 31
    [[ ! -s "$HOME/doctor.data" ]] || exit 32
    command grep -Fq "fzf - Installed" "$HOME/doctor.ui" || exit 33
    command grep -Fq "v0.74.3" "$HOME/doctor.ui"
  '
  [ "$status" -eq 0 ]
}

@test "F3-04 augmentation v2: doctor field under ksh_arrays" {
  f304_mock_local_probes
  run f304_doctor_option_field ksh_arrays
  [ "$status" -eq 0 ]
}

@test "F3-04 augmentation v2: doctor field under sh_word_split" {
  f304_mock_local_probes
  run f304_doctor_option_field sh_word_split
  [ "$status" -eq 0 ]
}

@test "F3-04 augmentation v2: doctor field under force_float" {
  f304_mock_local_probes
  run f304_doctor_option_field force_float
  [ "$status" -eq 0 ]
}

@test "F3-04 augmentation v2: doctor field under pipe_fail" {
  f304_mock_local_probes
  run f304_doctor_option_field pipe_fail
  [ "$status" -eq 0 ]
}

@test "F3-04 augmentation v2: doctor field under nounset" {
  f304_mock_local_probes
  run f304_doctor_option_field nounset
  [ "$status" -eq 0 ]
}

@test "F3-04 augmentation v2: doctor field under warn_create_global" {
  f304_mock_local_probes
  run f304_doctor_option_field warn_create_global
  [ "$status" -eq 0 ]
}

@test "F3-04 augmentation v2: lazy doctor source identity is its actual file under KSH_ARRAYS" {
  f304_mock_local_probes
  run env -u TEST_TEMP_DIR -u BATS_TEST_DIRNAME -u ZDX_EAGER_LOAD ZDX_LAZY_LOAD=1 zsh -f -c '
    emulate -R zsh
    builtin cd -- "$HOME" || exit 80
    source "$1/functions.zsh" || exit 90
    setopt ksh_arrays
    zdx-doctor --help > "$HOME/doctor.stdout" 2> "$HOME/doctor.stderr"
    local call_rc=$? source_name="${_ZDX_DOCTOR_SOURCE_FILE-}" kept="${options[ksharrays]}"
    unsetopt ksh_arrays
    [[ "$call_rc" == 0 && "$kept" == on && ! -s "$HOME/doctor.stdout" ]] || exit 31
    [[ "$source_name" == "$1/functions/zdx-doctor.zsh" ]]
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
}

# Run the actual confirmation branch on a private Zsh-owned pseudo-terminal;
# stdin and stderr are TTYs, while stdout is still checked independently.
# The sandbox child uses -i to own that terminal (docs/testing.md); -f skips
# optional startup files and HOME remains the isolated test directory.
f304_module_confirm_state() {
  export F304_CONFIRM_STATE="$1"
  cat > "$HOME/f304-confirm-child.zsh" <<'ZSH'
emulate -R zsh
builtin cd -- "$HOME" || exit 80
source "$TEST_SUITE_ROOT/functions/zdx-doctor.zsh" || exit 81
if [[ "$F304_CONFIRM_STATE" == seeded ]]; then
  MATCH=caller MBEGIN=7 MEND=12
  match=(captured other) mbegin=(2 5) mend=(8 11)
else
  unset MATCH MBEGIN MEND match mbegin mend
fi
_zdx_doctor_confirm F304_CONFIRM > "$HOME/confirm.stdout"
local confirm_rc=$?
print -r -- "rc=$confirm_rc state=${+MATCH}:${+MBEGIN}:${+MEND}:${+match}:${+mbegin}:${+mend}" \
  > "$HOME/confirm.diagnostic"
[[ "$confirm_rc" == "$1" && ! -s "$HOME/confirm.stdout" ]] || exit 82
if [[ "$F304_CONFIRM_STATE" == seeded ]]; then
  print -r -- "$MATCH:$MBEGIN:$MEND:${(j:,:)match}:${(j:,:)mbegin}:${(j:,:)mend}" \
    >> "$HOME/confirm.diagnostic"
  [[ "$MATCH" == caller && "$MBEGIN" == 7 && "$MEND" == 12 \
    && "${(j:,:)match}" == captured,other && "${(j:,:)mbegin}" == 2,5 \
    && "${(j:,:)mend}" == 8,11 ]] || exit 83
else
  (( ! ${+MATCH} && ! ${+MBEGIN} && ! ${+MEND} \
    && ! ${+match} && ! ${+mbegin} && ! ${+mend} )) || exit 84
fi
print -r -- "ok:$confirm_rc" > "$HOME/confirm.result.tmp" || exit 85
command mv -- "$HOME/confirm.result.tmp" "$HOME/confirm.result" || exit 86
ZSH
  zsh -n "$HOME/f304-confirm-child.zsh" || return 96
  run zsh -f -c '
    emulate -R zsh
    builtin cd -- "$HOME" || exit 80
    zmodload zsh/zpty || exit 81
    zmodload zsh/zselect || exit 82
    local answer="" expected="" chunk="" transcript="" enter="${(#):-13}"
    local -i attempt=0 sent=0
    for answer expected in y 0 N 1 yes 1 "" 1; do
      command rm -f -- "$HOME/confirm.result" "$HOME/confirm.result.tmp" "$HOME/confirm.diagnostic"
      transcript="" sent=0 attempt=0
      zpty -b F304CONFIRM zsh -f -i "$HOME/f304-confirm-child.zsh" "$expected" || exit 83
      {
        while (( ++attempt <= 1000 )); do
          if zpty -r -t F304CONFIRM chunk 2>/dev/null; then
            transcript+="$chunk"
          fi
          if (( ! sent )) && [[ "$transcript" == *"F304_CONFIRM [y/N]: "* ]]; then
            # A zero-byte zpty write can fail before it appends a newline.
            # Send the real Enter byte even for the empty decline response.
            zpty -n -w F304CONFIRM "$answer$enter" || exit 84
            sent=1
          fi
          [[ -f "$HOME/confirm.result" ]] && break
          zpty -t F304CONFIRM 2>/dev/null || break
          zselect -t 1
        done
      } always {
        zpty -d F304CONFIRM 2>/dev/null || :
      }
      if (( ! sent )) || [[ ! -f "$HOME/confirm.result" ]] \
        || [[ "$(<"$HOME/confirm.result")" != "ok:$expected" ]]; then
        [[ ! -f "$HOME/confirm.diagnostic" ]] || command cat "$HOME/confirm.diagnostic"
        print -r -- "confirmation transcript: ${(V)transcript}"
        exit 85
      fi
    done
    print -r -- confirmation-state-kept
  '
  if [ "$status" -ne 0 ]; then
    printf 'Confirmation controller status: %s\n%s\n' "$status" "$output"
    if [ -f "$HOME/confirm.diagnostic" ]; then
      cat "$HOME/confirm.diagnostic"
    fi
  fi
  [ "$status" -eq 0 ]
  [ "$output" = confirmation-state-kept ]
}

@test "F3-04 module regex: actual doctor confirmation preserves seeded caller state" {
  f304_module_confirm_state seeded
}

@test "F3-04 module regex: actual doctor confirmation preserves unset caller state" {
  f304_module_confirm_state unset
}
