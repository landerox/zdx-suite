#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  load core_options_test_helper
  load core_probe_test_helper
  load core_clt_consumer_test_helper
  unset FZF_DEFAULT_OPTS FZF_DEFAULT_OPTS_FILE FZF_DEFAULT_COMMAND
  export NO_COLOR=1
  export MOCK_DOCTOR_VERSION='0.74.3 (fixture)'
  export MOCK_DOCTOR_FZF_RC=0
  export DOCTOR_FIXTURE_BIN="$TEST_TEMP_DIR/doctor-bin"
  export CORE_PROBE_BIN="$DOCTOR_FIXTURE_BIN" F308C_REAL_PYTHON
  F308C_REAL_PYTHON=$(type -P python3) || return 1
  [[ "$F308C_REAL_PYTHON" == /* && -f "$F308C_REAL_PYTHON" \
    && -x "$F308C_REAL_PYTHON" ]] || return 1
  mkdir -p "$DOCTOR_FIXTURE_BIN"
  # A bounded test-only leaf runner keeps actual standalone diagnostics
  # supported without borrowing a host timeout or auto-sourcing the core.
  f308c_timeout_backend
  printf '#!%s\n' "$BASH" > "$DOCTOR_FIXTURE_BIN/fzf"
  cat >> "$DOCTOR_FIXTURE_BIN/fzf" <<'MOCK'
[[ "$#" -eq 1 && "$1" == --version ]] || exit 97
[[ -z "${FZF_DEFAULT_OPTS:-}${FZF_DEFAULT_OPTS_FILE:-}${FZF_DEFAULT_COMMAND:-}" ]] || exit 96
if IFS= read -r unexpected_input; then exit 95; fi
[[ -z "${MOCK_DOCTOR_VERSION:-}" ]] || printf '%s\n' "$MOCK_DOCTOR_VERSION"
exit "${MOCK_DOCTOR_FZF_RC:-0}"
MOCK
  chmod -- 755 "$DOCTOR_FIXTURE_BIN/fzf"
  cat > "$TEST_TEMP_DIR/doctor-fixture.zsh" <<'FIXTURE'
emulate -R zsh
path=("$DOCTOR_FIXTURE_BIN")
rehash
FIXTURE
}

teardown() { cleanup_sandbox; }

@test "doctor rendering: version probe isolates fzf defaults and leaves caller state intact" {
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions/zdx-doctor.zsh" || exit
    path=("$DOCTOR_FIXTURE_BIN")
    rehash
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
    path=("$DOCTOR_FIXTURE_BIN")
    rehash
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
  grep -Eq '^  fzf:[[:space:]]+Installed \(.*, v0[.]74[.]3\)$' "$HOME/valid-report"
  grep -Eq '^  fzf:[[:space:]]+Unknown \(version check failed, status 19; ' "$HOME/failed-report"
  grep -Fq 'Optional Suite-Specific Dependencies' "$HOME/failed-report"
  run grep -Eq '^  fzf:[[:space:]]+Installed ' "$HOME/failed-report"
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
    [[ "$output" =~ (^|$'\n')'▸ Core Dependencies'($|$'\n') ]]
    [[ ! "$output" =~ (^|$'\n')'  fzf:'[[:space:]]+'Installed ' ]]
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
  grep -Eq '^  Colors:[[:space:]]+disabled by NO_COLOR$' "$HOME/display-report"
  grep -Eq '^  Custom theme:[[:space:]]+configured$' "$HOME/display-report"
  grep -Eq '^  fzf defaults:[[:space:]]+options=set; file=set \(isolated by suite menus\)$' "$HOME/display-report"
  grep -Fq 'Doctor source:' "$HOME/display-report"
  grep -Fq 'open a new shell' "$HOME/display-report"
  [ "$(wc -l < "$HOME/display-report")" -eq 5 ]
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
  [[ "$output" =~ (^|$'\n')'  Colors:'[[:space:]]+'disabled by ZDX_FZF_PLAIN'($|$'\n') ]]
  [[ "$output" =~ (^|$'\n')'  Custom theme:'[[:space:]]+'configured'($|$'\n') ]]
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
  # This existing advisory scenario deliberately uses the actual core
  # watchdog, with no native runner on its private executable-only PATH.
  rm -- "$DOCTOR_FIXTURE_BIN/timeout"
  make_core_probe_path
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions.zsh" || exit
    OSTYPE=darwin23.0
    path=("$2" "$3")
    rehash
    zdx-doctor >"$4/stdout"
  ' _ "$TEST_SUITE_ROOT" "$TEST_TEMP_DIR/doctor-bin" "$CORE_PROBE_BIN" "$TEST_TEMP_DIR"

  [ "$status" -eq 0 ]
  [ ! -s "$TEST_TEMP_DIR/stdout" ]
  [[ "$output" =~ (^|$'\n')'  Platform:'[[:space:]]+'macOS'($|$'\n') ]]
  [[ "$output" =~ (^|$'\n')'  Package manager:'[[:space:]]+'brew'($|$'\n') ]]
  [[ "$output" =~ (^|$'\n')'  ip:'[[:space:]]+'Not applicable on macOS (iproute2 route lookups run on Linux and WSL) [VPN]'($|$'\n') ]]
  [[ "$output" != *"findmnt"* ]]
  [[ "$output" =~ (^|$'\n')'  GNU tar:'[[:space:]]+"Available ($TEST_TEMP_DIR/doctor-bin/gtar, tar (GNU tar) 1.35) [File & Archive Utilities]"($|$'\n') ]]
  [[ "$output" =~ (^|$'\n')'  timeout/gtimeout:'[[:space:]]+'Not found (bounded inventories, probes, and remote lookups use the slower Zsh watchdog) [System, Python & VPN]'($|$'\n') ]]
  [[ "$output" =~ (^|$'\n')'  Optional backend:'[[:space:]]+'brew install coreutils provides the faster gtimeout'($|$'\n') ]]
  [[ "$output" =~ (^|$'\n')'  git:'[[:space:]]+"Installed ($TEST_TEMP_DIR/doctor-bin/git, v2.39.3)"($|$'\n') ]]
  [[ "$output" =~ (^|$'\n')'  python3:'[[:space:]]+"Installed ($TEST_TEMP_DIR/doctor-bin/python3, v3.12.3) [Developer & Python]"($|$'\n') ]]
  [[ "$output" =~ (^|$'\n')'  curl:'[[:space:]]+"Installed ($TEST_TEMP_DIR/doctor-bin/curl, v8.7.1) [VPN & Python]"($|$'\n') ]]
  [[ "$output" =~ (^|$'\n')'  wg-quick:'[[:space:]]+"Installed ($TEST_TEMP_DIR/doctor-bin/wg-quick, v1.0.20210914) [WireGuard VPN]"($|$'\n') ]]
  [[ "$output" == *"Diagnosis completed: no issues found."* ]]
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
  [[ "$output" =~ (^|$'\n')'  timeout/gtimeout:'[[:space:]]+"Available ($DOCTOR_FIXTURE_BIN/timeout) [System, Python & VPN]"($|$'\n') ]]
  [[ "$output" != *"Optional backend:"* ]]

  run zsh -f -c '
    emulate -R zsh
    source "$1/functions/zdx-doctor.zsh" || exit
    typeset -gA _ZDX_LAZY_FILES=(git-status git-menu.zsh sys-info sys-menu.zsh)
    OSTYPE=darwin23.0
    PATH="$2"
    zdx-doctor
  ' _ "$TEST_SUITE_ROOT" "$TEST_TEMP_DIR/doctor-bin"
  [ "$status" -eq 0 ]
  [[ "$output" =~ (^|$'\n')'▸ Command Names'($|$'\n') ]]
  [[ "$output" =~ (^|$'\n')'  Command names:'[[:space:]]+'No executable on PATH shares a ZDX command name'($|$'\n') ]]
  [[ "$output" == *"Diagnosis completed: no issues found."* ]]

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
  [[ "$output" =~ (^|$'\n')'  PATH names:'[[:space:]]+'ZDX commands take precedence over git-status, sys-info'($|$'\n') ]]
  [[ "$output" == *"Run 'command NAME' to reach the executable."* ]]
  [[ "$output" == *"Diagnosis completed: no issues found."* ]]
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
  [[ "$output" =~ (^|$'\n')'  GNU tar:'[[:space:]]+"INCOMPATIBLE ($TEST_TEMP_DIR/doctor-bin/tar, bsdtar 3.5.3 - libarchive 3.7.4) [File & Archive Utilities]"($|$'\n') ]]
  [[ "$output" == *"requires GNU tar, found as either tar or gtar"* ]]
  [[ "$output" == *"brew install gnu-tar"* ]]
  [[ "$output" =~ (^|$'\n')'  Issues:'[[:space:]]+'1 dependency or capability issue'($|$'\n') ]]
}

@test "doctor rendering: Apple placeholders are reported missing instead of being run" {
  # Retain the actual classifier with private Apple identities and executable
  # secondaries. No host shim is exposed even if a guard regresses.
  f308c_setup
  _doctor_fixture_command git-alternate 'git version 2.43.0'
  export F308C_XCODE_RC=2
  run run_f308c_standalone '
    OSTYPE=darwin23.0
    local -i classifier_rc=0
    _zdx_doctor_clt_placeholder git "$F308C_BIN/git" || classifier_rc=$?
    (( classifier_rc == 0 )) || exit 31
    print -r -- git=placeholder
    classifier_rc=0
    _zdx_doctor_clt_placeholder python3 "$F308C_BIN/python3" || classifier_rc=$?
    (( classifier_rc == 0 )) || exit 32
    print -r -- python3=placeholder
    classifier_rc=0
    _zdx_doctor_clt_placeholder curl "$F308C_BIN/curl" || classifier_rc=$?
    (( classifier_rc == 1 )) || exit 33
    print -r -- curl=system
    classifier_rc=0
    _zdx_doctor_clt_placeholder git "$F308C_BIN/git-alternate" || classifier_rc=$?
    (( classifier_rc == 1 )) || exit 34
    print -r -- homebrew=real
  '
  [ "$status" -eq 0 ]
  [ "$output" = $'git=placeholder\npython3=placeholder\ncurl=system\nhomebrew=real' ]

  export F308C_XCODE_RC=0
  run run_f308c_standalone '
    OSTYPE=darwin23.0
    local -i classifier_rc=0
    _zdx_doctor_clt_placeholder git "$F308C_BIN/git" || classifier_rc=$?
    (( classifier_rc == 1 )) || exit 31
    print -r -- installed=real
    OSTYPE=linux-gnu
    classifier_rc=0
    _zdx_doctor_clt_placeholder git "$F308C_BIN/git" || classifier_rc=$?
    (( classifier_rc == 1 )) || exit 32
    print -r -- linux=real
  '
  [ "$status" -eq 0 ]
  [ "$output" = $'installed=real\nlinux=real' ]
}

@test "doctor rendering: a placeholder row never probes the Apple shim" {
  load core_probe_test_helper
  load core_clt_consumer_test_helper
  make_core_probe_path
  f308c_setup
  f308c_complete_tools
  f308c_timeout_backend
  export F308C_XCODE_RC=2
  run run_f308c_standalone '
    OSTYPE=darwin23.0
    zdx-doctor || F308C_STANDALONE_RETURN=$?
  '

  [ "$status" -eq 1 ]
  [[ "$output" =~ (^|$'\n')'  git:'[[:space:]]+'MISSING (' ]]
  [[ "$output" == *"$F308C_BIN/git is an Apple Command Line Tools placeholder"* ]]
  [[ "$output" =~ (^|$'\n')'  python3:'[[:space:]]+'MISSING (' ]]
  [[ "$output" == *"$F308C_BIN/python3 is an Apple Command Line Tools placeholder"* ]]
  [[ "$output" =~ (^|$'\n')'  Suggested command:'[[:space:]]+'brew install git' ]]
  [[ ! "$output" =~ (^|$'\n')'  git:'[[:space:]]+'Installed (' ]]
  [[ ! "$output" =~ (^|$'\n')'  python3:'[[:space:]]+'Installed (' ]]
  [ -s "$HOME/clt.argv" ]
  run grep -Eq -- "/(git|python3)( |$)" "$HOME/standalone-probes.calls"
  [ "$status" -eq 1 ]
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
  [[ "$output" =~ (^|$'\n')'  git:'[[:space:]]+"Unknown (version check failed, status 3; $TEST_TEMP_DIR/doctor-bin/git)"($|$'\n') ]]
  [[ "$output" =~ (^|$'\n')'  python3:'[[:space:]]+"Unknown (version check failed, status 1; $TEST_TEMP_DIR/doctor-bin/python3) [Developer & Python]"($|$'\n') ]]
  [[ "$output" =~ (^|$'\n')'  wg-quick:'[[:space:]]+"Unknown (version check failed, status 127; $TEST_TEMP_DIR/doctor-bin/wg-quick) [WireGuard VPN]"($|$'\n') ]]
  [[ ! "$output" =~ (^|$'\n')'  git:'[[:space:]]+'Installed ' ]]
  [[ ! "$output" =~ (^|$'\n')'  python3:'[[:space:]]+'Installed ' ]]
  [[ ! "$output" =~ (^|$'\n')'  wg-quick:'[[:space:]]+'Installed ' ]]
  [[ "$output" != *"vinstalled"* && "$output" != *", v)"* ]]
  [[ "$output" =~ (^|$'\n')'  Issues:'[[:space:]]+'3 dependency or capability issues'($|$'\n') ]]
}

@test "doctor rendering: Linux keeps ip as a counted capability" {
  _doctor_fixture_macos_tools
  _doctor_fixture_command tar 'tar (GNU tar) 1.35'
  rm -- "$DOCTOR_FIXTURE_BIN/timeout"
  make_core_probe_path
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions.zsh" || exit
    unset WSL_DISTRO_NAME WSL_INTEROP
    OSTYPE=linux-gnu
    _zdx_doctor_is_wsl() { return 1; }
    path=("$2" "$3")
    rehash
    zdx-doctor
  ' _ "$TEST_SUITE_ROOT" "$TEST_TEMP_DIR/doctor-bin" "$CORE_PROBE_BIN"

  [ "$status" -eq 1 ]
  [[ "$output" =~ (^|$'\n')'  Platform:'[[:space:]]+'Linux'($|$'\n') ]]
  [[ "$output" =~ (^|$'\n')'  ip:'[[:space:]]+'MISSING (route lookups in VPN diagnostics) [VPN]'($|$'\n') ]]
  [[ "$output" != *"findmnt"* ]]
  [[ "$output" =~ (^|$'\n')'  timeout/gtimeout:'[[:space:]]+'Not found (bounded inventories, probes, and remote lookups use the slower Zsh watchdog) [System, Python & VPN]'($|$'\n') ]]
  [[ "$output" =~ (^|$'\n')'  Optional backend:'[[:space:]]+'GNU coreutils provides the faster timeout command.'($|$'\n') ]]
  [[ "$output" =~ (^|$'\n')'  Issues:'[[:space:]]+'1 dependency or capability issue'($|$'\n') ]]
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
    local saved_path="$PATH"
    source "$TEST_TEMP_DIR/doctor-fixture.zsh" || exit 81
    setopt ksh_arrays sh_word_split force_float pipe_fail
    zdx-doctor > "$HOME/doctor.data" 2> "$HOME/doctor.ui"
    local call_rc=$? kept="${options[ksharrays]}:${options[shwordsplit]}:${options[forcefloat]}:${options[pipefail]}"
    unsetopt ksh_arrays sh_word_split force_float pipe_fail
    [[ $call_rc == 1 && "$kept" == on:on:on:on ]] || exit 31
    [[ ! -s "$HOME/doctor.data" ]] || exit 32
    PATH="$saved_path"
    rehash
    command grep -Eq "^  fzf:[[:space:]]+Installed " "$HOME/doctor.ui" || exit 33
    command grep -Eq "^  fzf:[[:space:]]+Installed .*, v0[.]74[.]3" "$HOME/doctor.ui"
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

@test "core probes: doctor resolves primary and alternative tools despite functions and aliases" {
  _doctor_fixture_macos_tools
  _doctor_fixture_command timeout 'timeout fixture'
  _doctor_fixture_command fd 'fd fixture'
  _doctor_fixture_command sha256sum 'sha256 fixture'
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions.zsh" || exit 90
    cd "$HOME" || exit 91
    path=("$2")
    rehash
    python3() { print -r -- function-intercepted; }
    timeout() { return 97; }
    fd() { return 97; }
    sha256sum() { return 97; }
    alias fdfind=fd
    local -a missing_cmds=() missing_pkgs=()
    local -i issues_count=0 capability_issues_count=0
    local pm=none REPLY=""
    _zdx_doctor_report_dependency "python3|Fixture|optional|https://example.invalid|python3|python|python3|python|Fixture" \
      > "$HOME/stdout" 2> "$HOME/report" || exit 92
    [[ "$(<"$HOME/report")" == *"$2/python3"* && ! -s "$HOME/stdout" ]] || exit 93
    _zdx_doctor_timeout_command && [[ "$REPLY" == "$2/timeout" ]] || exit 94
    _zdx_doctor_fd_command && [[ "$REPLY" == "$2/fd" ]] || exit 95
    _zdx_doctor_sha256_command && [[ "$REPLY" == "$2/sha256sum" ]] || exit 96
  ' _ "$TEST_SUITE_ROOT" "$TEST_TEMP_DIR/doctor-bin"
  [ "$status" -eq 0 ]
}

@test "core probes: doctor stops a hung version probe without native timeout" {
  load core_probe_test_helper
  make_core_probe_path
  export CORE_PROBE_SLEEP
  CORE_PROBE_SLEEP=$(command -v sleep)
  core_probe_program pipx <<'MOCK'
"$CORE_PROBE_SLEEP" 8
: > "$HOME/version-probe-completed"
printf '1.4.3\n'
MOCK
  run run_core_probe_zsh '
    _zdx_doctor_get_version pipx > "$HOME/version"
    local probe_rc=$?
    [[ "$probe_rc" == 124 && ! -s "$HOME/version" && ! -e "$HOME/version-probe-completed" ]]
  '
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/version-probe-completed" ]
}

@test "core probes: doctor step results remain visible with a decimal comma" {
  local locale_dir="$TEST_TEMP_DIR/locales"
  command -v localedef >/dev/null 2>&1 || skip "localedef is unavailable"
  mkdir -p "$locale_dir"
  localedef -i de_DE -f UTF-8 "$locale_dir/de_DE.UTF-8" >/dev/null 2>&1 \
    || skip "a decimal-comma locale cannot be built"
  export CORE_PROBE_LOCALE_DIR="$locale_dir"
  run run_zsh '
    cd "$HOME" || return 90
    export LOCPATH="$CORE_PROBE_LOCALE_DIR" LC_ALL=de_DE.UTF-8
    local probe=""
    printf -v probe "%.1f" 1.5
    [[ "$probe" == "1,5" ]] || return 42
    _zdx_doctor_step_result 1 2 install 0 "$EPOCHREALTIME" > "$HOME/stdout" 2> "$HOME/success"
    _zdx_doctor_step_result 2 2 install 7 "$EPOCHREALTIME" >> "$HOME/stdout" 2> "$HOME/failure"
    [[ ! -s "$HOME/stdout" && "$(<"$HOME/success")" == *"done (0.0s)"* \
      && "$(<"$HOME/failure")" == *"failed: exit 7 (0.0s)"* ]]
  '
  [ "$status" -ne 42 ] || skip "the built locale does not use a decimal comma"
  [ "$status" -eq 0 ]
}

@test "core probes: public doctor decline succeeds even when manual issues remain" {
  printf '#!%s\n: > "$HOME/package-manager-ran"\nexit 97\n' "$BASH" > "$TEST_MOCK_BIN/apt-get"
  chmod -- 755 "$TEST_MOCK_BIN/apt-get"
  run run_zsh '
    cd "$HOME" || return 90
    _zdx_doctor_detect_os() { print -r -- Linux; }
    _zdx_doctor_detect_pkg_manager() { print -r -- apt; }
    _zdx_doctor_report_dependency() {
      if [[ "$1" == jq\|* ]]; then
        missing_cmds+=(jq)
        missing_pkgs+=(jq)
        (( issues_count += 1 ))
      fi
      return 0
    }
    _zdx_doctor_timeout_command() { REPLY=fixture; return 0; }
    _zdx_doctor_fd_command() { REPLY=fixture; return 0; }
    _zdx_doctor_sha256_command() { return 1; }
    _zdx_doctor_gnu_tar() { reply=(fixture "GNU tar fixture"); return 0; }
    _zdx_doctor_program_trusted() { [[ "$1" == "$TEST_MOCK_BIN"/* && -f "$1" && -x "$1" ]]; }
    functions[_fixture_real_confirm]="${functions[_zdx_confirm_prompt]}"
    _zdx_confirm_prompt() { print -r -- used > "$HOME/shared-confirm-used"; return 1; }
    zdx-doctor > "$HOME/stdout" 2> "$HOME/decline-report"
    local public_rc=$?
    [[ "$public_rc" == 0 && -f "$HOME/shared-confirm-used" && ! -s "$HOME/stdout" ]] || return 91
    [[ "$(<"$HOME/decline-report")" != *"All packages installed"* ]] || return 92
    functions[_zdx_confirm_prompt]="${functions[_fixture_real_confirm]}"
    zdx-doctor </dev/null > "$HOME/stdout" 2> "$HOME/headless-report"
    [[ $? == 1 && ! -s "$HOME/stdout" && ! -e "$HOME/package-manager-ran" ]]
  '
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/package-manager-ran" ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "core probes: doctor headers and sections obey aggregate output scope" {
  run run_zsh '
    cd "$HOME" || return 90
    NO_COLOR=1
    _zdx_doctor_section Fixture > "$HOME/stdout" 2> "$HOME/section"
    local -i _ZDX_STEP_DEPTH=1
    _zdx_doctor_header Hidden >> "$HOME/stdout" 2> "$HOME/heading"
    [[ ! -s "$HOME/stdout" && ! -s "$HOME/heading" \
      && "$(<"$HOME/section")" == *"▸ Fixture" ]]
  '
  [ "$status" -eq 0 ]
}
