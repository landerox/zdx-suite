#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  REAL_GIT=$(command -v git)
  export REAL_GIT
  load test_helper
  export WS="$HOME/workspaces" WS_COLLATING_LOCALE=""
  export WS_TEST_SSH_HOST=github.example WS_SSH_LOCALE="$HOME/ssh-locale"
  mkdir -p "$WS/selfhost/personal"

  # A listed locale is insufficient: require the actual widening libc regex
  # behavior in a fresh Zsh, independent of the product's validator.
  local locale_name
  while IFS= read -r locale_name; do
    case "$locale_name" in *.[Uu][Tt][Ff]8|*.[Uu][Tt][Ff]-8) ;; *) continue ;; esac
    if LC_ALL="$locale_name" zsh -f -c '
      emulate -R zsh
      [[ "café" =~ "^[A-Za-z0-9]+$" ]]
    ' >/dev/null 2>&1; then
      WS_COLLATING_LOCALE="$locale_name"
      break
    fi
  done < <(locale -a 2>/dev/null)

  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/ssh"
  cat >> "$TEST_MOCK_BIN/ssh" <<'MOCK'
[[ "${1:-}" == -G && "${2:-}" == -- ]] || exit 97
printf '%s\n' "${LC_ALL-unset}" > "$WS_SSH_LOCALE"
printf 'hostname %s\r\n' "$WS_TEST_SSH_HOST"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/ssh"
}

teardown() {
  cleanup_sandbox
}

require_collating_locale() {
  [ -n "$WS_COLLATING_LOCALE" ] || skip "no installed UTF-8 locale widens ASCII libc ranges"
}

prepare_fsmonitor_repository() {
  export WS_REPOSITORY="$WS/selfhost/personal/app" WS_FS_LOG="$HOME/fsmonitor.log"
  export WS_GIT_LOG="$HOME/git-argv.log"
  "$REAL_GIT" init -q "$WS_REPOSITORY" || return
  printf 'tracked\n' > "$WS_REPOSITORY/tracked"
  "$REAL_GIT" -C "$WS_REPOSITORY" add -- tracked || return
  "$REAL_GIT" -C "$WS_REPOSITORY" -c user.name=Test -c user.email=test@example.invalid \
    -c commit.gpgsign=false commit -qm initial || return
  printf '#!%s\n' "$BASH" > "$HOME/fsmonitor-hook"
  cat >> "$HOME/fsmonitor-hook" <<'MOCK'
printf 'hook\n' >> "$WS_FS_LOG"
printf '\0'
MOCK
  chmod -- 700 "$HOME/fsmonitor-hook"
  "$REAL_GIT" -C "$WS_REPOSITORY" config core.fsmonitor "$HOME/fsmonitor-hook" || return
  # Positive control: the same real Git and configured hook demonstrably run.
  "$REAL_GIT" -C "$WS_REPOSITORY" status --porcelain >/dev/null 2>&1 || return
  [ -s "$WS_FS_LOG" ] || return 1
  : > "$WS_FS_LOG"
  printf 'changed\n' >> "$WS_REPOSITORY/tracked"
  WS_INDEX_HASH=$(sha256_file "$WS_REPOSITORY/.git/index")
  export WS_INDEX_HASH
  : > "$WS_GIT_LOG"
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/git"
  cat >> "$TEST_MOCK_BIN/git" <<'MOCK'
printf '%s\t' "$@" >> "$WS_GIT_LOG"
printf '\n' >> "$WS_GIT_LOG"
exec "$REAL_GIT" "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/git"
}

@test "ws input safety: mixed non-ASCII directory names are refused in a widening locale" {
  require_collating_locale
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws-menu.zsh" || return
    export LC_ALL="$WS_COLLATING_LOCALE"
    local value
    for value in café repoß repoı repoİ repoａ repo١ repo¹ repo① repo⅓ repoK repoÅ; do
      _ws_name_valid "$value" && return 31
    done
    return 0
  '
  [ "$status" -eq 0 ]
}

@test "ws input safety: non-ASCII initial directory characters are refused" {
  require_collating_locale
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws-menu.zsh" || return
    export LC_ALL="$WS_COLLATING_LOCALE"
    local value
    for value in érepo ßrepo ırepo İrepo ａrepo ١repo ①repo Krepo; do
      _ws_name_valid "$value" && return 31
    done
    return 0
  '
  [ "$status" -eq 0 ]
}

@test "ws input safety: all public directory options reject non-ASCII before Git probes" {
  require_collating_locale
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws-menu.zsh" || return
    export LC_ALL="$WS_COLLATING_LOCALE"
    _ws_require_git() { : > "$HOME/unexpected-git-probe"; return 91; }
    local option rc
    for option in --platform --identity --name; do
      ws-clone https://github.com/acme/app.git "$option" café --yes \
        > "$HOME/result.stdout" 2> "$HOME/result.stderr"
      rc=$?
      (( rc == 2 )) || return 32
      [[ ! -s "$HOME/result.stdout" && -s "$HOME/result.stderr" \
        && ! -e "$HOME/unexpected-git-probe" ]] || return 33
    done
  '
  [ "$status" -eq 0 ]
}

@test "ws input safety: mixed non-ASCII URL hosts are refused" {
  require_collating_locale
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws-menu.zsh" || return
    export LC_ALL="$WS_COLLATING_LOCALE"
    local host rc
    for host in gíthub.com github.ｃom github١.com gitK.example gitß.example; do
      _ws_clone_parse_url "https://$host/acme/app.git" 2>/dev/null
      rc=$?
      (( rc == 2 )) && (( ${#reply} == 0 )) || return 34
    done
  '
  [ "$status" -eq 0 ]
}

@test "ws input safety: non-ASCII initial URL hosts are refused for every transport" {
  require_collating_locale
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws-menu.zsh" || return
    export LC_ALL="$WS_COLLATING_LOCALE"
    local url rc
    for url in https://ｇithub.com/acme/app.git ssh://git@Key.example/acme/app.git \
      git@Å.example:acme/app.git; do
      _ws_clone_parse_url "$url" 2>/dev/null
      rc=$?
      (( rc == 2 )) && (( ${#reply} == 0 )) || return 35
    done
  '
  [ "$status" -eq 0 ]
}

@test "ws input safety: SSH users refuse mixed and initial non-ASCII characters" {
  require_collating_locale
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws-menu.zsh" || return
    export LC_ALL="$WS_COLLATING_LOCALE"
    local user rc
    for user in gít ｇit git١ Key; do
      _ws_clone_parse_url "ssh://$user@github.com/acme/app.git" 2>/dev/null
      rc=$?
      (( rc == 2 )) || return 36
      _ws_clone_parse_url "$user@github.com:acme/app.git" 2>/dev/null
      rc=$?
      (( rc == 2 )) || return 37
    done
  '
  [ "$status" -eq 0 ]
}

@test "ws input safety: URL path components refuse non-ASCII bytes in either position" {
  require_collating_locale
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws-menu.zsh" || return
    export LC_ALL="$WS_COLLATING_LOCALE"
    local component rc
    for component in café ａcme app١ ①repo repoK; do
      _ws_clone_parse_url "https://github.com/$component/app.git" 2>/dev/null
      rc=$?
      (( rc == 2 )) || return 38
      _ws_clone_parse_url "git@github.com:acme/$component.git" 2>/dev/null
      rc=$?
      (( rc == 2 )) || return 39
    done
  '
  [ "$status" -eq 0 ]
}

@test "ws input safety: hostname files with non-ASCII names cannot infer an identity" {
  require_collating_locale
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws-menu.zsh" || return
    export LC_ALL="$WS_COLLATING_LOCALE"
    local host
    for host in gitK.example ｇit.example git١.example café.example; do
      print -r -- "$host" > "$WS/selfhost/personal/.ws-hostname"
      _ws_workspace_hostname "$WS" selfhost personal
      [[ -z "$REPLY" ]] || return 40
    done
  '
  [ "$status" -eq 0 ]
}

@test "ws input safety: SSH configured HostName refuses non-ASCII without changing child locale" {
  require_collating_locale
  export WS_TEST_SSH_HOST=gitK.example
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws-menu.zsh" || return
    export LC_ALL="$WS_COLLATING_LOCALE"
    _ws_git_command() { return 1; }
    _ws_ssh_alias_hostname "$REAL_GIT" selfhost-personal
    [[ -z "$REPLY" && "$(<"$WS_SSH_LOCALE")" == "$WS_COLLATING_LOCALE" \
      && "$LC_ALL" == "$WS_COLLATING_LOCALE" ]]
  '
  [ "$status" -eq 0 ]
}

@test "ws input safety: ASCII name grammar and its exact length bounds remain usable" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws-menu.zsh" || return
    local value
    for value in a Z 0 abc.DEF_ghi-9 "a${(l:99::x:)}"; do
      _ws_name_valid "$value" || return 41
    done
    for value in "" .hidden -option _prefix ../escape "two names" "a${(l:100::x:)}"; do
      _ws_name_valid "$value" && return 42
    done
    return 0
  '
  [ "$status" -eq 0 ]
}

@test "ws input safety: ASCII transport grammars preserve the exact parsed tuple" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws-menu.zsh" || return
    _ws_clone_parse_url https://Git-Hub.Example/acme_1/app.git || return 43
    [[ "${(j:|:)reply}" == "https||Git-Hub.Example||acme_1/app.git" ]] || return 44
    _ws_clone_parse_url ssh://git-user@github.example:2222/acme_1/app.git || return 45
    [[ "${(j:|:)reply}" == "ssh|git-user|github.example|2222|acme_1/app.git" ]] || return 46
    _ws_clone_parse_url _git@github.example:acme/app.git || return 47
    [[ "${(j:|:)reply}" == "scp|_git|github.example||acme/app.git" ]]
  '
  [ "$status" -eq 0 ]
}

@test "ws input safety: existing ASCII URL host user and component bounds are preserved" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws-menu.zsh" || return
    local host="a${(l:252::b:)}" user="u${(l:63::x:)}" component="r${(l:99::y:)}" rc
    _ws_clone_parse_url "ssh://$user@$host/$component" || return 67
    [[ "${reply[2]}" == "$user" && "${reply[3]}" == "$host" \
      && "${reply[5]}" == "$component" ]] || return 68
    _ws_clone_parse_url "ssh://$user@$host/$component/" || return 69
    _ws_clone_parse_url "ssh://${user}x@github.com/app" 2>/dev/null
    rc=$?
    (( rc == 2 )) || return 70
    _ws_clone_parse_url "https://${host}x/app" 2>/dev/null
    rc=$?
    (( rc == 2 )) || return 71
    _ws_clone_parse_url "https://github.com/${component}x" 2>/dev/null
    rc=$?
    (( rc == 2 ))
  '
  [ "$status" -eq 0 ]
}

@test "ws input safety: ASCII hostnames retain CRLF normalization and platform defaults" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws-menu.zsh" || return
    printf "Git-Hub.Example\r\nignored\n" > "$WS/selfhost/personal/.ws-hostname"
    _ws_workspace_hostname "$WS" selfhost personal
    [[ "$REPLY" == git-hub.example ]] || return 48
    _ws_workspace_hostname "$WS" github personal
    [[ "$REPLY" == github.com ]] || return 49
    _ws_workspace_hostname "$WS" other personal
    [[ "$REPLY" == gitlab.com ]]
  '
  [ "$status" -eq 0 ]
}

@test "ws input safety: SSH ASCII HostName remains usable with the callers locale" {
  require_collating_locale
  export WS_TEST_SSH_HOST=Git-Hub.Example
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws-menu.zsh" || return
    export LC_ALL="$WS_COLLATING_LOCALE"
    _ws_git_command() { return 1; }
    _ws_ssh_alias_hostname "$REAL_GIT" selfhost-personal
    [[ "$REPLY" == Git-Hub.Example && "$(<"$WS_SSH_LOCALE")" == "$LC_ALL" ]]
  '
  [ "$status" -eq 0 ]
}

@test "ws input safety: seeded regex captures survive all ASCII validators" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws-menu.zsh" || return
    local MATCH=seed MBEGIN=17 MEND=23
    local -a match=(one two) mbegin=(3 5) mend=(7 9)
    local expected="$(typeset -p MATCH MBEGIN MEND match mbegin mend)"
    _ws_name_valid ascii || return 50
    [[ "$(typeset -p MATCH MBEGIN MEND match mbegin mend)" == "$expected" ]] || return 51
    _ws_clone_parse_url https://github.com/acme/app.git || return 52
    [[ "$(typeset -p MATCH MBEGIN MEND match mbegin mend)" == "$expected" ]] || return 53
    _ws_workspace_hostname "$WS" github personal
    [[ "$(typeset -p MATCH MBEGIN MEND match mbegin mend)" == "$expected" ]] || return 54
    _ws_git_command() { return 1; }
    _ws_ssh_alias_hostname "$REAL_GIT" selfhost-personal
    [[ "$(typeset -p MATCH MBEGIN MEND match mbegin mend)" == "$expected" ]]
  '
  [ "$status" -eq 0 ]
}

@test "ws input safety: initially unset regex captures remain unset after validators" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws-menu.zsh" || return
    unset MATCH MBEGIN MEND match mbegin mend
    _ws_name_valid ascii || return 55
    [[ ! -v MATCH && ! -v MBEGIN && ! -v MEND && ! -v match && ! -v mbegin && ! -v mend ]] || return 56
    _ws_clone_parse_url https://github.com/acme/app.git || return 57
    [[ ! -v MATCH && ! -v MBEGIN && ! -v MEND && ! -v match && ! -v mbegin && ! -v mend ]] || return 58
    _ws_workspace_hostname "$WS" github personal
    [[ ! -v MATCH && ! -v MBEGIN && ! -v MEND && ! -v match && ! -v mbegin && ! -v mend ]] || return 59
    _ws_git_command() { return 1; }
    _ws_ssh_alias_hostname "$REAL_GIT" selfhost-personal
    [[ ! -v MATCH && ! -v MBEGIN && ! -v MEND && ! -v match && ! -v mbegin && ! -v mend ]]
  '
  [ "$status" -eq 0 ]
}

@test "ws input safety: locale parameters and hostile caller options remain unchanged" {
  require_collating_locale
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws-menu.zsh" || return
    export LC_ALL="$WS_COLLATING_LOCALE"
    setopt ksh_arrays sh_word_split glob_subst
    unsetopt extended_glob
    local expected="$(typeset -p LC_ALL LANG)" options_before="${(kv)options}"
    _ws_name_valid ascii || return 60
    _ws_clone_parse_url https://github.com/acme/app.git || return 61
    _ws_workspace_hostname "$WS" github personal
    [[ "$(typeset -p LC_ALL LANG)" == "$expected" && "${(kv)options}" == "$options_before" ]]
  '
  [ "$status" -eq 0 ]
}

@test "ws input safety: an unset LC_ALL remains unset after ASCII validation" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws-menu.zsh" || return
    unset LC_ALL
    _ws_name_valid ascii || return 62
    _ws_clone_parse_url https://github.com/acme/app.git || return 63
    _ws_workspace_hostname "$WS" github personal
    [[ ! -v LC_ALL ]]
  '
  [ "$status" -eq 0 ]
}

@test "ws input safety: status probe does not execute the configured real fsmonitor hook" {
  prepare_fsmonitor_repository
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws-menu.zsh" || return
    _ws_status_probe "$REAL_GIT" "$WS_REPOSITORY" || return 64
    [[ "${reply[1]}" == ok && "${reply[9]}" == 1 ]]
  '
  [ "$status" -eq 0 ]
  [ ! -s "$WS_FS_LOG" ]
  [ "$(sha256_file "$WS_REPOSITORY/.git/index")" = "$WS_INDEX_HASH" ]
}

@test "ws input safety: text status keeps the real hook dormant and the index unchanged" {
  prepare_fsmonitor_repository
  run run_zsh 'ws-status > "$HOME/status.stdout" 2> "$HOME/status.stderr"'
  [ "$status" -eq 0 ]
  [ ! -s "$WS_FS_LOG" ]
  [ ! -s "$HOME/status.stdout" ]
  grep -Eq 'selfhost/personal[[:space:]]+app[[:space:]]' "$HOME/status.stderr"
  [ "$(sha256_file "$WS_REPOSITORY/.git/index")" = "$WS_INDEX_HASH" ]
}

@test "ws input safety: JSON status keeps the real hook dormant and exposes actual changes" {
  prepare_fsmonitor_repository
  run run_zsh 'ws-status --json > "$HOME/status.json" 2> "$HOME/status.stderr"'
  [ "$status" -eq 0 ]
  [ ! -s "$WS_FS_LOG" ]
  jq -e '.schema == "zdx.ws-status.v1" and (.repositories | length == 1) and .repositories[0].changes == 1' "$HOME/status.json"
  [ "$(sha256_file "$WS_REPOSITORY/.git/index")" = "$WS_INDEX_HASH" ]
}

@test "ws input safety: index based preview keeps the real hook dormant" {
  prepare_fsmonitor_repository
  export WS_PREVIEW_OUT="$HOME/preview.out"
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/fzf"
  cat >> "$TEST_MOCK_BIN/fzf" <<'MOCK'
preview=""
for argument in "$@"; do
  case "$argument" in --preview=*) preview="${argument#--preview=}" ;; esac
done
[[ -n "$preview" ]] || exit 97
cat >/dev/null
/bin/sh -c "${preview//\{n\}/0}" > "$WS_PREVIEW_OUT" 2>&1 || exit 98
exit 130
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/fzf"
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws-menu.zsh" || return
    _ws_jump_pick "$WS" private-workspace selfhost/personal/app
  '
  [ "$status" -eq 130 ]
  grep -Fq 'Changes:     1' "$WS_PREVIEW_OUT"
  [ ! -s "$WS_FS_LOG" ]
  [ "$(sha256_file "$WS_REPOSITORY/.git/index")" = "$WS_INDEX_HASH" ]
}

@test "ws input safety: all read only Git probes explicitly suppress fsmonitor" {
  prepare_fsmonitor_repository
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws-menu.zsh" || return
    _ws_status_probe "$TEST_MOCK_BIN/git" "$WS_REPOSITORY" || return 65
    local -A fetch_outcomes=()
    _ws_status_fetch "$TEST_MOCK_BIN/git" "$WS" selfhost/personal/app || return 66
    _ws_ssh_alias_hostname "$TEST_MOCK_BIN/git" selfhost-personal
  '
  [ "$status" -eq 0 ]
  [ ! -s "$WS_FS_LOG" ]
  [ "$(wc -l < "$WS_GIT_LOG")" -ge 6 ]
  awk -F '\t' 'index($0, "core.fsmonitor=false") == 0 { bad=1 } END { exit bad }' "$WS_GIT_LOG"
}

@test "ws status regex scope: seeded caller captures survive a successful read only probe" {
  prepare_fsmonitor_repository
  "$REAL_GIT" -C "$WS_REPOSITORY" config core.fsmonitor false
  WS_CAPTURE_BRANCH=$("$REAL_GIT" -C "$WS_REPOSITORY" symbolic-ref --short HEAD)
  export WS_CAPTURE_BRANCH
  "$REAL_GIT" -C "$WS_REPOSITORY" config "branch.$WS_CAPTURE_BRANCH.remote" .
  "$REAL_GIT" -C "$WS_REPOSITORY" config "branch.$WS_CAPTURE_BRANCH.merge" "refs/heads/$WS_CAPTURE_BRANCH"
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws-menu.zsh" || return 90
    local MATCH=caller-match MBEGIN=17 MEND=23
    local -a match=(caller-one caller-two) mbegin=(3 5) mend=(7 9)
    local expected="$(typeset -p MATCH MBEGIN MEND match mbegin mend)"
    _ws_status_probe "$REAL_GIT" "$WS_REPOSITORY" \
      >"$HOME/capture-probe.data" 2>"$HOME/capture-probe.ui" || return 91
    [[ "${reply[1]}:${reply[2]}:${reply[6]}:${reply[7]}:${reply[8]}:${reply[9]}" \
      == "ok:${WS_CAPTURE_BRANCH}:tracking:0:0:1" ]] || return 92
    [[ "$(typeset -p MATCH MBEGIN MEND match mbegin mend)" == "$expected" ]] || return 93
  '
  if [ "$status" -ne 0 ]; then
    printf 'probe-status=%s\n%s\n' "$status" "$output" >&2
  fi
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$HOME/capture-probe.data" ]
  [ ! -s "$HOME/capture-probe.ui" ]
  [ ! -s "$WS_FS_LOG" ]
  [ "$(sha256_file "$WS_REPOSITORY/.git/index")" = "$WS_INDEX_HASH" ]
}

@test "ws status regex scope: initially unset caller captures stay unset after a read only probe" {
  prepare_fsmonitor_repository
  "$REAL_GIT" -C "$WS_REPOSITORY" config core.fsmonitor false
  WS_CAPTURE_BRANCH=$("$REAL_GIT" -C "$WS_REPOSITORY" symbolic-ref --short HEAD)
  export WS_CAPTURE_BRANCH
  "$REAL_GIT" -C "$WS_REPOSITORY" config "branch.$WS_CAPTURE_BRANCH.remote" .
  "$REAL_GIT" -C "$WS_REPOSITORY" config "branch.$WS_CAPTURE_BRANCH.merge" "refs/heads/$WS_CAPTURE_BRANCH"
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws-menu.zsh" || return 90
    unset MATCH MBEGIN MEND match mbegin mend
    [[ ! -v MATCH && ! -v MBEGIN && ! -v MEND \
      && ! -v match && ! -v mbegin && ! -v mend ]] || return 94
    _ws_status_probe "$REAL_GIT" "$WS_REPOSITORY" \
      >"$HOME/capture-probe.data" 2>"$HOME/capture-probe.ui" || return 91
    [[ "${reply[1]}:${reply[2]}:${reply[6]}:${reply[7]}:${reply[8]}:${reply[9]}" \
      == "ok:${WS_CAPTURE_BRANCH}:tracking:0:0:1" ]] || return 92
    [[ ! -v MATCH && ! -v MBEGIN && ! -v MEND \
      && ! -v match && ! -v mbegin && ! -v mend ]] || return 95
  '
  if [ "$status" -ne 0 ]; then
    printf 'probe-status=%s\n%s\n' "$status" "$output" >&2
  fi
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$HOME/capture-probe.data" ]
  [ ! -s "$HOME/capture-probe.ui" ]
  [ ! -s "$WS_FS_LOG" ]
  [ "$(sha256_file "$WS_REPOSITORY/.git/index")" = "$WS_INDEX_HASH" ]
}
