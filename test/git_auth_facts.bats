#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  load test_helper
  export AUTH_REAL_GIT AUTH_CASE="$HOME/case"
  AUTH_REAL_GIT=$(type -P git)
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=0 GIT_TERMINAL_PROMPT=0
  export GIT_ALLOW_PROTOCOL=file GIT_PAGER=cat PAGER=cat TERM=dumb NO_COLOR=1
  unset GIT_SSH_COMMAND GIT_SSH
  mkdir -p "$AUTH_CASE"
  printf '%s\n' "$TEST_SUITE_ROOT" > "$AUTH_CASE/source-root"
  # Every hostname is accepted: a wrong displayed host must not become an
  # artificial authentication failure. Only the read-only operation is allowed.
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/gh"
  cat >> "$TEST_MOCK_BIN/gh" <<'MOCK'
if [[ "$#" -eq 4 && "$1" == auth && "$2" == status && "$3" == --hostname ]]; then
  printf '%s\0' "$@" >> "$AUTH_CASE/gh.args.nul"
  printf '%s\n' "$4" >> "$AUTH_CASE/gh.hostnames"
  exit 0
fi
printf '%s\0' "$@" >> "$AUTH_CASE/gh.unexpected.nul"
exit 97
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/gh"
}

teardown() {
  cleanup_sandbox
}

auth_facts_repo() {
  export AUTH_REPO="$1"
  "$AUTH_REAL_GIT" init -q -b main "$AUTH_REPO" || return 1
  "$AUTH_REAL_GIT" -C "$AUTH_REPO" config core.hooksPath /dev/null || return 2
  "$AUTH_REAL_GIT" -C "$AUTH_REPO" config user.name 'Auth Test' || return 3
  "$AUTH_REAL_GIT" -C "$AUTH_REPO" config user.email auth@example.invalid || return 4
  "$AUTH_REAL_GIT" -C "$AUTH_REPO" rev-parse --show-toplevel \
    > "$AUTH_CASE/repository-root" || return 5
}

auth_facts_field() {
  local label="$1" expected="$2" actual
  actual=$(awk -v label="$label" '{
    sub(/^[[:space:]]*/, "")
    if (substr($0, 1, length(label)) == label) {
      value = substr($0, length(label) + 1)
      sub(/^[[:space:]]*/, "", value)
      print value
    }
  }' "$AUTH_CASE/command.stderr") || return 1
  if [[ "$actual" != "$expected" ]]; then
    printf 'Expected %s %s; got %s\n' "$label" "$expected" "$actual" >&2
    return 1
  fi
}

auth_facts_read_only() {
  cmp "$AUTH_CASE/config.before.nul" "$AUTH_CASE/config.after.nul" || return 1
  [ ! -s "$AUTH_CASE/gh.unexpected.nul" ] || return 2
  [ "$(cat "$AUTH_CASE/command.primary.status")" -eq 0 ] || return 3
  [ ! -s "$AUTH_CASE/command.stdout" ] || return 4
}

auth_facts_layout() {
  export AUTH_MODE="$1" AUTH_BASE="$AUTH_CASE/layout"
  case "$AUTH_MODE" in
    valid-root|valid-subdir|relative) auth_facts_repo "$AUTH_BASE/github/personal/project" || return 1 ;;
    identity) auth_facts_repo "$AUTH_BASE/github/personal" || return 1 ;;
    *) auth_facts_repo "$AUTH_CASE/plain/repo" || return 1 ;;
  esac
  "$AUTH_REAL_GIT" -C "$AUTH_REPO" remote add origin \
    https://github.com/example/repository.git || return 2
  "$AUTH_REAL_GIT" -C "$AUTH_REPO" config --local --null --list \
    > "$AUTH_CASE/config.before.nul" || return 3
  mkdir -p "$AUTH_REPO/sub/dir"
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
    cd "$AUTH_REPO" || return 91
    case "$AUTH_MODE" in
      empty) WS_BASE_DIR="" ;;
      unset) unset WS_BASE_DIR ;;
      root) WS_BASE_DIR=/ ;;
      relative) WS_BASE_DIR="../../.." ;;
      identity|valid-root|valid-subdir) WS_BASE_DIR="$AUTH_BASE" ;;
      default-outside) : ;;
      *) return 92 ;;
    esac
    if [[ "$AUTH_MODE" == valid-subdir ]]; then
      cd sub/dir || return 93
    fi
    print -r -- "${WS_BASE_DIR-UNSET}" > "$AUTH_CASE/base.value"
    print -r -- "$PWD" > "$AUTH_CASE/invocation-directory"
    git-auth >"$AUTH_CASE/command.stdout" 2>"$AUTH_CASE/command.stderr"
    local -i result=$?
    print -r -- "$result" > "$AUTH_CASE/command.primary.status"
    command git config --local --null --list > "$AUTH_CASE/config.after.nul" || return 94
    return "$result"
  '
  [ "$status" -eq 0 ] || return 11
  auth_facts_read_only || return 12
  case "$AUTH_MODE" in
    valid-root|valid-subdir)
      auth_facts_field Workspace: github/personal || return 13
      auth_facts_field 'SSH alias:' github-personal || return 14
      auth_facts_field Repository: project || return 15
      ;;
    *)
      auth_facts_field Workspace: '(none)' || return 16
      ! grep -Eq '^[[:space:]]+SSH alias:' "$AUTH_CASE/command.stderr" || return 17
      ;;
  esac
  auth_facts_field Host: github.com || return 18
  [ "$(cat "$AUTH_CASE/gh.hostnames")" = github.com ] || return 19
}

@test "git auth facts: the default base leaves an outside repository outside" {
  auth_facts_layout default-outside
}

@test "git auth facts: an empty base cannot fabricate a workspace" {
  auth_facts_layout empty
}

@test "git auth facts: a base unset after loading cannot fabricate a workspace" {
  auth_facts_layout unset
}

@test "git auth facts: the filesystem root cannot be a workspace base" {
  auth_facts_layout root
}

@test "git auth facts: a relative base is rejected even when it resolves to a layout" {
  auth_facts_layout relative
}

@test "git auth facts: the identity directory itself is not a repository segment" {
  auth_facts_layout identity
}

@test "git auth facts: a valid repository root retains workspace facts" {
  auth_facts_layout valid-root
}

@test "git auth facts: a repository subdirectory retains repository-root workspace facts" {
  auth_facts_layout valid-subdir
}

# These are nonsecret fixture canaries. No remote Git operation is performed.
auth_facts_url() {
  export AUTH_INPUT_URL="$1"
  local expected_redacted="$2" expected_host="$3"
  auth_facts_repo "$AUTH_CASE/repository" || return 1
  "$AUTH_REAL_GIT" -C "$AUTH_REPO" remote add origin "$AUTH_INPUT_URL" || return 2
  "$AUTH_REAL_GIT" -C "$AUTH_REPO" config --local --null --list \
    > "$AUTH_CASE/config.before.nul" || return 3
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
    cd "$AUTH_REPO" || return 91
    WS_BASE_DIR="$HOME/not-a-workspace"
    _git_redact_remote_url "$AUTH_INPUT_URL" \
      >"$AUTH_CASE/redacted.stdout" 2>"$AUTH_CASE/redacted.stderr"
    print -r -- "$?" > "$AUTH_CASE/redacted.primary.status"
    _git_remote_hostname "$AUTH_INPUT_URL" \
      >"$AUTH_CASE/hostname.stdout" 2>"$AUTH_CASE/hostname.stderr"
    print -r -- "$?" > "$AUTH_CASE/hostname.primary.status"
    git-auth >"$AUTH_CASE/command.stdout" 2>"$AUTH_CASE/command.stderr"
    local -i result=$?
    print -r -- "$result" > "$AUTH_CASE/command.primary.status"
    command git config --local --null --list > "$AUTH_CASE/config.after.nul" || return 92
    return "$result"
  '
  [ "$status" -eq 0 ] || return 11
  auth_facts_read_only || return 12
  [ "$(cat "$AUTH_CASE/redacted.primary.status")" -eq 0 ] || return 13
  [ "$(cat "$AUTH_CASE/hostname.primary.status")" -eq 0 ] || return 14
  [ ! -s "$AUTH_CASE/redacted.stderr" ] || return 15
  [ ! -s "$AUTH_CASE/hostname.stderr" ] || return 16
  [ "$(cat "$AUTH_CASE/redacted.stdout")" = "$expected_redacted" ] || return 17
  [ "$(cat "$AUTH_CASE/hostname.stdout")" = "$expected_host" ] || return 18
  auth_facts_field URL: "$expected_redacted" || return 19
  auth_facts_field Host: "$expected_host" || return 20
  if [[ "$expected_host" == unknown ]]; then
    [ ! -e "$AUTH_CASE/gh.hostnames" ] || return 21
  else
    [ "$(cat "$AUTH_CASE/gh.hostnames")" = "$expected_host" ] || return 21
  fi
  ! grep -Eq 'USERINFO_CANARY|QUERY_CANARY|FRAGMENT_CANARY' \
    "$AUTH_CASE/redacted.stdout" "$AUTH_CASE/command.stderr" || return 22
}

@test "git auth facts: an ordinary HTTPS remote retains its host and URL" {
  auth_facts_url https://github.com/org/repository.git \
    https://github.com/org/repository.git github.com
}

@test "git auth facts: ordinary authority userinfo and query secrets stay masked" {
  auth_facts_url 'https://user:USERINFO_CANARY@github.com/org/repo.git?QUERY_CANARY#FRAGMENT_CANARY' \
    'https://***@github.com/org/repo.git (query or fragment redacted)' github.com
}

@test "git auth facts: an HTTPS path at-sign preserves the authority" {
  auth_facts_url https://github.com/org/repo@v1.git \
    https://github.com/org/repo@v1.git github.com
}

@test "git auth facts: userinfo stays masked beside a literal path at-sign" {
  auth_facts_url 'https://user:USERINFO_CANARY@github.com/org/repo@v1.git?QUERY_CANARY#FRAGMENT_CANARY' \
    'https://***@github.com/org/repo@v1.git (query or fragment redacted)' github.com
}

@test "git auth facts: an SCP path at-sign survives user masking" {
  auth_facts_url git@github.com:org/repo@v1.git \
    '***@github.com:org/repo@v1.git' github.com
}

@test "git auth facts: an SSH URI with a port retains its path at-sign" {
  auth_facts_url ssh://git@github.com:2222/org/repo@v1.git \
    'ssh://***@github.com:2222/org/repo@v1.git' github.com
}

@test "git auth facts: ambiguous non-URI credentials remain masked" {
  auth_facts_url 'user:USERINFO_CANARY@github.com:org/repo.git' \
    '***@github.com:org/repo.git' unknown
}

@test "git auth facts: a slash-qualified SCP path keeps its at-sign and colon" {
  auth_facts_url 'github.com:org/repo@release:v1.git' \
    'github.com:org/repo@release:v1.git' unknown
}
