#!/usr/bin/env bats
# Real public status/resolver coverage with executable private Git fixtures.
# These model WSL classification; no host Windows executable or /mnt is used.
# shellcheck disable=SC2016

setup() {
  load test_helper
  load core_probe_test_helper
  export WSL_STATUS_REAL_ZSH WSL_STATUS_REAL_JQ
  WSL_STATUS_REAL_ZSH=$(type -P zsh) || return 1
  WSL_STATUS_REAL_JQ=$(type -P jq) || return 1
  local program
  for program in "$WSL_STATUS_REAL_ZSH" "$WSL_STATUS_REAL_JQ" "$BASH"; do
    [[ "$program" == /* && -f "$program" && -x "$program" ]] || return 1
  done
  # Freeze the serializer's regular resolved target, including Homebrew links.
  WSL_STATUS_REAL_JQ=$("$WSL_STATUS_REAL_ZSH" -f -c '
    emulate -R zsh
    [[ "$1" == /* && -f "$1" && -x "$1" ]] || exit 1
    print -r -- "${1:A}"
  ' _ "$WSL_STATUS_REAL_JQ") || return 1
  [[ -f "$WSL_STATUS_REAL_JQ" && -x "$WSL_STATUS_REAL_JQ" \
    && ! -L "$WSL_STATUS_REAL_JQ" ]] || return 1

  make_core_probe_path
  [[ ! -e "$CORE_PROBE_BIN/jq" && ! -L "$CORE_PROBE_BIN/jq" ]] || return 1
  # This support link is never a core_probe_program write target.
  ln -s "$WSL_STATUS_REAL_JQ" "$CORE_PROBE_BIN/jq" || return 1
  export WSL_STATUS_WORKTREE="$HOME/wsl-status-project"
  export WSL_STATUS_GIT_DIR="$HOME/wsl-status-git-metadata"
  mkdir -m 700 "$WSL_STATUS_WORKTREE" "$WSL_STATUS_GIT_DIR" || return 1
  printf 'all:\n\t@:\n' > "$WSL_STATUS_WORKTREE/Makefile"
}

teardown() { cleanup_sandbox; }

_wsl_status_git_fixture() {
  local leaf="$1"
  case "$leaf" in windows-git.exe|native-git) ;; *) return 1 ;; esac
  export WSL_STATUS_GIT_TARGET="$CORE_PROBE_BIN/$leaf"
  [[ ! -e "$WSL_STATUS_GIT_TARGET" && ! -L "$WSL_STATUS_GIT_TARGET" \
    && ! -e "$CORE_PROBE_BIN/git" && ! -L "$CORE_PROBE_BIN/git" ]] || return 1
  core_probe_program "$leaf" <<'BASH'
printf '%s\n' "$0" >> "$HOME/wsl-status-git.started"
printf '%s\0' "$0" "$@" >> "$HOME/wsl-status-git.argv"
if [[ $# -eq 3 && "$1" == rev-parse && "$2" == --show-toplevel \
  && "$3" == --absolute-git-dir ]]; then
  printf '%s\0' "$@" > "$HOME/wsl-status-revparse.argv"
  printf '%s\n%s\n' "$WSL_STATUS_WORKTREE" "$WSL_STATUS_GIT_DIR"
  exit 0
fi
# Both literal status vectors are intentional: c18 precedes F308's fsmonitor
# flag. No arbitrary command, target, configuration or network is forwarded.
if [[ $# -eq 5 && "$1" == --no-optional-locks && "$2" == status \
  && "$3" == --porcelain=v2 && "$4" == --branch && "$5" == -z ]] \
  || [[ $# -eq 7 && "$1" == --no-optional-locks && "$2" == -c \
    && "$3" == core.fsmonitor=false && "$4" == status \
    && "$5" == --porcelain=v2 && "$6" == --branch && "$7" == -z ]]; then
  printf '# branch.oid 1111111111111111111111111111111111111111\0# branch.head wsl-private\0'
  exit 0
fi
if [[ $# -eq 3 && "$1" == config && "$2" == --get && "$3" == user.email ]]; then
  printf 'wsl-fixture@example.invalid\n'
  exit 0
fi
exit 97
BASH
  [[ -f "$WSL_STATUS_GIT_TARGET" && -x "$WSL_STATUS_GIT_TARGET" \
    && ! -L "$WSL_STATUS_GIT_TARGET" ]] || return 1
  [[ "$(file_mode "$WSL_STATUS_GIT_TARGET")" == 755 \
    && "$(file_links "$WSL_STATUS_GIT_TARGET")" == 1 ]] || return 1
  ln -s "$WSL_STATUS_GIT_TARGET" "$CORE_PROBE_BIN/git" || return 1
  [[ -L "$CORE_PROBE_BIN/git" && -f "$CORE_PROBE_BIN/git" \
    && -x "$CORE_PROBE_BIN/git" ]] || return 1
}

_wsl_status_public_json() {
  "$WSL_STATUS_REAL_ZSH" -f -c '
    emulate -R zsh
    builtin source "$1/functions.zsh" || exit 90
    builtin cd -- "$WSL_STATUS_WORKTREE" || exit 91
    OSTYPE=linux-gnu
    WSL_DISTRO_NAME=ZdxPrivateFixture
    unset WSL_INTEROP VIRTUAL_ENV ZDX_TELEMETRY ZDX_VERBOSE
    path=("$CORE_PROBE_BIN")
    rehash
    local selected="$(whence -p -- git)"
    [[ "$selected" == "$CORE_PROBE_BIN/git" && "${selected:A}" == "$2" \
      && -f "$2" && -x "$2" && ! -L "$2" ]] || exit 92
    printf "%s\n%s\n" "$selected" "${selected:A}" > "$HOME/wsl-status.lookup"
    local -i public_rc=0
    zdx-status --json > "$HOME/wsl-status.json" 2> "$HOME/wsl-status.stderr" || public_rc=$?
    printf "%s\n" "$public_rc" > "$HOME/wsl-status.public-status"
    exit "$public_rc"
  ' _ "$TEST_SUITE_ROOT" "$WSL_STATUS_GIT_TARGET" </dev/null
}

# Require one complete plain canonical footer; reject extra bytes or lines.
_wsl_status_assert_timing_footer() {
  local report="$HOME/wsl-status.stderr" footer_line="" bytes=""
  local duration_pattern='([0-9][.][0-9]s|[1-5][0-9]s|([1-9]|[1-5][0-9])m [0-5][0-9]s|([1-9]|1[0-9]|2[0-3])h [0-5][0-9]m|[1-9][0-9]*d (0[0-9]|1[0-9]|2[0-3])h)'
  local footer_pattern="^  zdx:status completed in ${duration_pattern}$"
  [[ -f "$report" && ! -L "$report" ]] || return 1
  IFS= read -r footer_line < "$report" || return 1
  [[ "$footer_line" =~ $footer_pattern ]] || return 1
  # A matched line is ASCII. This also rejects extra LF and embedded NUL bytes.
  bytes=$(file_size "$report") || return 1
  [ "$bytes" -eq "$(( ${#footer_line} + 1 ))" ]
}

_wsl_status_independent_json() {
  run "$WSL_STATUS_REAL_JQ" -e --arg root "$WSL_STATUS_WORKTREE" '
    type == "object" and .schema == "zdx.status.v1"
    and .project.directory == $root and .project.files == ["Makefile"]
    and (.host.platform == "WSL1" or .host.platform == "WSL2")
    and (.zdx.version | type) == "string" and (.zdx.version | length) > 0
  ' "$HOME/wsl-status.json"
  [ "$status" -eq 0 ]
  [ "$output" = true ]
  [ "$(wc -l < "$HOME/wsl-status.json")" -eq 1 ]
}

@test "core probes: public status rejects an executable private Windows-like Git target on WSL" {
  _wsl_status_git_fixture windows-git.exe
  run _wsl_status_public_json
  local public_status="$status" reached=no
  [[ ! -e "$HOME/wsl-status-git.started" ]] || reached=yes
  printf 'public_status=%s private_git_started=%s\n' "$public_status" "$reached"
  [ "$public_status" -eq 0 ]
  [ "$(< "$HOME/wsl-status.public-status")" = 0 ]
  # On old c18, this must fail because the real public call started this
  # existing executable, not because a new product helper returned127.
  [ ! -e "$HOME/wsl-status-git.started" ]
  [ ! -e "$HOME/wsl-status-git.argv" ]
  [ ! -e "$HOME/wsl-status-revparse.argv" ]
  _wsl_status_assert_timing_footer
  printf '%s\n%s\n' "$CORE_PROBE_BIN/git" "$WSL_STATUS_GIT_TARGET" \
    > "$HOME/wsl-status.expected-lookup"
  cmp "$HOME/wsl-status.expected-lookup" "$HOME/wsl-status.lookup"
  _wsl_status_independent_json
  run "$WSL_STATUS_REAL_JQ" -e '.repository == null' "$HOME/wsl-status.json"
  [ "$status" -eq 0 ]
  [ "$output" = true ]
}

@test "core probes: public status accepts an ordinary private Git target on WSL and preserves independent JSON facts" {
  _wsl_status_git_fixture native-git
  run _wsl_status_public_json
  local public_status="$status" reached=no
  [[ ! -e "$HOME/wsl-status-git.started" ]] || reached=yes
  printf 'public_status=%s private_git_started=%s\n' "$public_status" "$reached"
  [ "$public_status" -eq 0 ]
  [ "$(< "$HOME/wsl-status.public-status")" = 0 ]
  [ -s "$HOME/wsl-status-git.started" ]
  [ -s "$HOME/wsl-status-git.argv" ]
  _wsl_status_assert_timing_footer
  printf '%s\0' rev-parse --show-toplevel --absolute-git-dir \
    > "$HOME/wsl-status.expected-revparse"
  cmp "$HOME/wsl-status.expected-revparse" "$HOME/wsl-status-revparse.argv"
  printf '%s\n%s\n' "$CORE_PROBE_BIN/git" "$WSL_STATUS_GIT_TARGET" \
    > "$HOME/wsl-status.expected-lookup"
  cmp "$HOME/wsl-status.expected-lookup" "$HOME/wsl-status.lookup"
  _wsl_status_independent_json
  run "$WSL_STATUS_REAL_JQ" -e --arg root "$WSL_STATUS_WORKTREE" '
    .repository.root == $root and .repository.branch == "wsl-private"
  ' "$HOME/wsl-status.json"
  [ "$status" -eq 0 ]
  [ "$output" = true ]
}
