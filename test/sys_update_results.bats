#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  export F506_ROOT="$HOME/f506" F506_CASE_DIR=""
  export NO_COLOR=1
  unset F506_FNM_BEFORE F506_FZF_MODE F506_FZF_NEW F506_FZF_OLD
  export F506_NVM_BEFORE=none F506_NVM_DEFAULT=v22.1.0
  export F506_NVM_ALIAS_RC=0 F506_NVM_USE_RC=0
  mkdir -p "$F506_ROOT" || return 1
  cat > "$F506_ROOT/context.zsh" <<'ZSH'
emulate -R zsh
builtin cd -q -- "$TEST_TEMP_DIR" || return 90
source "$ZSH_CUSTOM/functions/sys-menu.zsh" || return 91
_SYS_CAPABILITIES=(os linux environment native architecture x86_64
  os_updates_backend unavailable package_manager unavailable
  ports_backend unavailable privilege direct process_backend unavailable
  service_manager unavailable snapd available wsl_interop unavailable)
_SYS_CAPABILITIES_READY=1
_sys_capabilities_refresh() { return 0; }
_sys_snap_ready() { return 0; }
# Installed-manager discovery is a modeled boundary here. The exact fzf
# ownership tests below still use the real active executable resolver.
command() {
  if [[ "$1" == -v ]]; then
    case "${2:-}" in
      apt-get|brew|uv|pip|pip3|python3|go|pre-commit|aws|starship|systemctl|service|journalctl|softwareupdate)
        return 1 ;;
    esac
  fi
  builtin command "$@"
}
ZSH
  # Every mock has a finite grammar. Unexpected calls fail and leave evidence.
  # Use the harness-selected Bash, including when a consumer fixes PATH.
  printf '#!%s\n' "$BASH" > "$F506_ROOT/snap-backend" || return 2
  cat >> "$F506_ROOT/snap-backend" <<'MOCK'
printf '%s\0' "$@" >> "$F506_CASE_DIR/snap.argv.nul"
printf '%s\n' "$*" >> "$F506_CASE_DIR/snap.events"
case "$*" in
  'refresh --list')
    if IFS= read -r fixture_input; then
      printf '%s\n' "$fixture_input" > "$F506_CASE_DIR/stdin-read"
    else
      printf '%s\n' closed > "$F506_CASE_DIR/stdin-closed"
    fi
    cat "$F506_CASE_DIR/refresh.stdout" || exit 90
    cat "$F506_CASE_DIR/refresh.stderr" >&2 || exit 91
    code=$(cat "$F506_CASE_DIR/refresh.return") || exit 92
    exit "$code" ;;
  refresh) printf 'snap refresh\n' >> "$F506_CASE_DIR/mutations"; exit 0 ;;
  'list --all')
    printf 'Name Version Rev Tracking Publisher Notes\n'
    while IFS=' ' read -r name revision; do
      [[ -n "$name" ]] || continue
      printf '%s 1.0 %s latest/stable fixture disabled\n' "$name" "$revision"
    done < "$F506_CASE_DIR/revisions.state"
    exit 0 ;;
  'remove one --revision=11'|'remove two --revision=22')
    printf 'backend progress: %s\n' "$*"
    printf 'backend diagnostic: %s\n' "$*" >&2
    name=$2
    code=$(cat "$F506_CASE_DIR/$name.remove.return") || exit 93
    if [[ "$code" == 0 ]]; then
      # Backend state changes only on actual successful removal.
      while IFS=' ' read -r item revision; do
        [[ "$item" == "$name" ]] || printf '%s %s\n' "$item" "$revision"
      done < "$F506_CASE_DIR/revisions.state" > "$F506_CASE_DIR/revisions.next" || exit 94
      mv "$F506_CASE_DIR/revisions.next" "$F506_CASE_DIR/revisions.state" || exit 95
    fi
    exit "$code" ;;
  *) printf 'unexpected snap: %s\n' "$*" >> "$F506_CASE_DIR/unexpected"; exit 97 ;;
esac
MOCK
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/snap" || return 7
  cat >> "$TEST_MOCK_BIN/snap" <<'MOCK'
case "$*" in
  'refresh --list') record=refresh ;;
  'list --all') record=inventory ;;
  refresh) record=mutation ;;
  'remove one --revision=11') record=one ;;
  'remove two --revision=22') record=two ;;
  *) printf 'unexpected snap wrapper: %s\n' "$*" >> "$F506_CASE_DIR/unexpected"; exit 97 ;;
esac
observed=0
"$F506_ROOT/snap-backend" "$@" || observed=$?
printf '%s\n' "$observed" > "$F506_CASE_DIR/$record.backend.return" || exit 96
exit "$observed"
MOCK
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/npm" || return 3
  cat >> "$TEST_MOCK_BIN/npm" <<'MOCK'
printf '%s\n' "$*" >> "$F506_CASE_DIR/npm.events"
case "$*" in
  'config get cache') printf '%s\n' "$HOME/safe-npm-cache" ;;
  *) printf 'unexpected npm: %s\n' "$*" >> "$F506_CASE_DIR/unexpected"; exit 97 ;;
esac
MOCK
  # No package manager, network client, service operation or process signal can
  # fall through to a real backend. Individual tests enable only finite mocks.
  local denied
  for denied in apt-get brew cargo rustup uv pip pip3 python3 go pre-commit \
    aws starship systemctl service journalctl softwareupdate curl wget sudo; do
    printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/$denied" || return 4
    cat >> "$TEST_MOCK_BIN/$denied" <<'MOCK'
printf '%s %s\n' "${0##*/}" "$*" >> "$F506_CASE_DIR/unexpected"
exit 97
MOCK
    chmod -- 700 "$TEST_MOCK_BIN/$denied" || return 5
  done
  chmod -- 700 "$TEST_MOCK_BIN/snap" "$F506_ROOT/snap-backend" "$TEST_MOCK_BIN/npm" || return 6
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/dpkg-query" || return 8
  cat >> "$TEST_MOCK_BIN/dpkg-query" <<'MOCK' || return 9
printf '%s\0' "$@" >> "$F506_CASE_DIR/dpkg-query.argv.nul"
[[ $# == 4 && "$1" == -W && "$2" == '-f=${db:Status-Status}\n' \
  && "$3" == -- && "$4" == fzf ]] || exit 97
# Documented missing-package protocol, not an indeterminate failed query.
exit 1
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/dpkg-query" || return 10
}

teardown() { cleanup_sandbox; }

f506_case() {
  export F506_CASE_DIR="$F506_ROOT/$1"
  mkdir -p "$F506_CASE_DIR" || return 1
  : > "$F506_CASE_DIR/snap.events" || return 2
  : > "$F506_CASE_DIR/snap.argv.nul" || return 3
  : > "$F506_CASE_DIR/unexpected" || return 4
  : > "$F506_CASE_DIR/refresh.stdout" || return 5
  : > "$F506_CASE_DIR/refresh.stderr" || return 6
  printf '0\n' > "$F506_CASE_DIR/refresh.return" || return 7
  printf 'one 11\ntwo 22\n' > "$F506_CASE_DIR/revisions.state" || return 8
  printf '0\n' > "$F506_CASE_DIR/one.remove.return" || return 9
  printf '0\n' > "$F506_CASE_DIR/two.remove.return" || return 10
}

# Capture the actual public return before any observer command runs. Wrapper
# success means the observation completed, not that the public command passed.
f506_observe() {
  local body="$1" wrapper_rc=0
  run_zsh '
    source "$F506_ROOT/context.zsh" || return 90
    _f506_action() {
  '"$body"'
    }
    local -i observed_rc=0
    _f506_action > "$F506_CASE_DIR/stdout" 2> "$F506_CASE_DIR/stderr" || observed_rc=$?
    print -r -- "$observed_rc" > "$F506_CASE_DIR/primary.status" || return 92
    return 0
  ' > "$F506_CASE_DIR/wrapper.stdout" 2> "$F506_CASE_DIR/wrapper.stderr" || wrapper_rc=$?
  printf '%s\n' "$wrapper_rc" > "$F506_CASE_DIR/wrapper.status" || return 1
  [[ "$wrapper_rc" -eq 0 ]] || return 2
  [[ -f "$F506_CASE_DIR/primary.status" ]] || return 3
}

f506_status() {
  local observed
  [[ -f "$F506_CASE_DIR/stdout" && -f "$F506_CASE_DIR/stderr" \
    && -f "$F506_CASE_DIR/unexpected" ]] || return 6
  observed=$(cat "$F506_CASE_DIR/primary.status") || return 1
  [[ "$observed" =~ ^[0-9]+$ ]] || return 2
  [[ "$observed" -eq "$1" ]] || return 3
  [[ ! -s "$F506_CASE_DIR/stdout" ]] || return 4
  [[ ! -s "$F506_CASE_DIR/unexpected" ]] || return 5
}

f506_has() { grep -Fq -- "$1" "$F506_CASE_DIR/stderr" || return 1; }
f506_lacks() {
  local grep_rc=0
  [[ -f "$F506_CASE_DIR/stderr" ]] || return 1
  grep -Fq -- "$1" "$F506_CASE_DIR/stderr" || grep_rc=$?
  [[ "$grep_rc" -eq 1 ]] || return 2
}

# Each matrix aggregates row failures after every row has been observed.
# Every intermediate oracle propagates explicitly: callers may use || return.
f506_node_row() {
  local name="$1" before="$2" default="$3" expected="$4" outcome
  f506_case "$name" || return 1
  export F506_NVM_BEFORE="$before" F506_NVM_DEFAULT="$default"
  f506_observe '
    export NVM_DIR="$F506_CASE_DIR/nvm"
    mkdir -p "$NVM_DIR/versions/node/v22.1.0/lib/node_modules/npm" || return 91
    functions[_f506_original_tool_program]="$functions[_sys_tool_program]"
    _sys_tool_program() {
      [[ "$1" == fnm ]] && return 1
      _f506_original_tool_program "$@"
    }
    nvm() {
      print -r -- "$*" >> "$F506_CASE_DIR/nvm.events" || return 90
      case "$*" in
        current)
          if [[ -e "$F506_CASE_DIR/node.active" ]]; then
            cat "$F506_CASE_DIR/node.active"
          else
            print -r -- "$F506_NVM_BEFORE"
          fi ;;
        "version default") print -r -- "$F506_NVM_DEFAULT" ;;
        "install --lts") print -r -- v22.1.0 > "$F506_CASE_DIR/node.installed" ;;
        "version lts/*") cat "$F506_CASE_DIR/node.installed" ;;
        "alias default v22.1.0")
          (( F506_NVM_ALIAS_RC == 0 )) || return "$F506_NVM_ALIAS_RC"
          print -r -- v22.1.0 > "$F506_CASE_DIR/node.default" ;;
        "use v22.1.0")
          (( F506_NVM_USE_RC == 0 )) || return "$F506_NVM_USE_RC"
          print -r -- v22.1.0 > "$F506_CASE_DIR/node.active" ;;
        *) print -r -- "unexpected nvm: $*" >> "$F506_CASE_DIR/unexpected"; return 97 ;;
      esac
    }
    local -a reply=()
    local -i step_rc=0
    _sys_step_exec update-node || step_rc=$?
    print -r -- "${reply[1]}" > "$F506_CASE_DIR/outcome" || return 92
    print -r -- "${reply[2]}" > "$F506_CASE_DIR/detail" || return 93
    return "$step_rc"
  ' || return 2
  f506_status 0 || return 3
  outcome=$(cat "$F506_CASE_DIR/outcome") || return 4
  grep -Fxq v22.1.0 "$F506_CASE_DIR/node.installed" || return 6
  grep -Fxq v22.1.0 "$F506_CASE_DIR/node.active" || return 7
  grep -Fxq v22.1.0 "$F506_CASE_DIR/node.default" || return 8
  grep -Fxq 'version default' "$F506_CASE_DIR/nvm.events" || return 9
  [[ "$outcome" == "$expected" ]] || return 5
}

@test "sys update results: Node outcomes follow observed current and previous default identities" {
  local row result failures=0
  for row in 'missing-same|none|v22.1.0|current' \
    'missing-other|none|v20.1.0|done' \
    'known-same|v22.1.0|v22.1.0|current' \
    'known-change|v20.1.0|v20.1.0|updated'; do
    IFS='|' read -r name before default expected <<< "$row"
    if f506_node_row "$name" "$before" "$default" "$expected"; then result=0
    else result=$?; failures=$((failures + 1)); fi
    printf '%s\t%s\n' "$name" "$result" >> "$F506_ROOT/node-matrix.tsv"
  done
  [ "$(wc -l < "$F506_ROOT/node-matrix.tsv")" -eq 4 ]
  [ "$failures" -eq 0 ]
}

@test "sys update results: failed default selection cannot publish a successful Node outcome" {
  export F506_NVM_ALIAS_RC=17
  # The public model actually attempts install/use; a failed alias never writes
  # the observed default file. This is an existing F4 positive safety control.
  local helper_rc=0
  f506_node_row node-alias-failure none v22.1.0 current || helper_rc=$?
  [ "$helper_rc" -ne 0 ]
  f506_status 1
  [ -s "$F506_CASE_DIR/node.installed" ]
  [ ! -e "$F506_CASE_DIR/node.default" ]
  grep -Fxq failed "$F506_CASE_DIR/outcome"
  f506_has 'default selection failed'
}

f506_fnm_row() {
  local name="$1" before="$2" expected="$3"
  f506_case "fnm-$name" || return 1
  export F506_FNM_BEFORE="$before"
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/fnm" || return 2
  cat >> "$TEST_MOCK_BIN/fnm" <<'MOCK' || return 3
printf '%s\n' "$*" >> "$F506_CASE_DIR/fnm.events"
case "$*" in
  current)
    if [[ -e "$F506_CASE_DIR/fnm.installed" ]]; then printf 'v22.1.0\n'
    else printf '%s\n' "$F506_FNM_BEFORE"; fi ;;
  'install --lts') printf 'v22.1.0\n' > "$F506_CASE_DIR/fnm.installed" ;;
  'use lts-latest') printf 'v22.1.0\n' > "$F506_CASE_DIR/fnm.active" ;;
  'default lts-latest') printf 'v22.1.0\n' > "$F506_CASE_DIR/fnm.default" ;;
  *) printf 'unexpected fnm: %s\n' "$*" >> "$F506_CASE_DIR/unexpected"; exit 97 ;;
esac
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/fnm" || return 4
  f506_observe '
    local -a reply=()
    local -i step_rc=0
    _sys_step_exec update-node || step_rc=$?
    print -r -- "${reply[1]}" > "$F506_CASE_DIR/outcome" || return 90
    return "$step_rc"
  ' || return 5
  f506_status 0 || return 6
  grep -Fxq v22.1.0 "$F506_CASE_DIR/fnm.active" || return 8
  grep -Fxq v22.1.0 "$F506_CASE_DIR/fnm.default" || return 9
  grep -Fxq 'install --lts' "$F506_CASE_DIR/fnm.events" || return 10
  grep -Fxq "$expected" "$F506_CASE_DIR/outcome" || return 7
}

@test "sys update results: fnm without prior version has done evidence and known identities retain their outcomes" {
  local row name before expected result failures=0
  for row in 'unknown|none|done' 'same|v22.1.0|current' 'changed|v20.1.0|updated'; do
    IFS='|' read -r name before expected <<< "$row"
    if f506_fnm_row "$name" "$before" "$expected"; then result=0
    else result=$?; failures=$((failures + 1)); fi
    printf '%s\t%s\n' "$name" "$result" >> "$F506_ROOT/fnm-matrix.tsv"
  done
  [ "$(wc -l < "$F506_ROOT/fnm-matrix.tsv")" -eq 3 ]
  [ "$failures" -eq 0 ]
}

f506_snap_preview_row() {
  local name="$1" expected_primary="$2" expected_fragment="$3"
  f506_case "$name" || return 1
  case "$name" in
    snap-empty-warning)
      printf 'All snaps up to date.\nWARNING: There is 1 new warning.\n' \
        > "$F506_CASE_DIR/refresh.stderr" || return 2 ;;
    snap-stdout-current)
      printf 'All snaps up to date.\n' > "$F506_CASE_DIR/refresh.stdout" || return 24 ;;
    snap-header-empty)
      printf 'Name Version Rev Size Publisher Notes\n' > "$F506_CASE_DIR/refresh.stdout" || return 25 ;;
    snap-two-warning)
      printf 'Name Version Rev Size Publisher Notes\none 1.1 12 1MB fixture -\ntwo 2.1 23 2MB fixture -\n' \
        > "$F506_CASE_DIR/refresh.stdout" || return 3
      printf 'WARNING: There is 1 new warning.\n' > "$F506_CASE_DIR/refresh.stderr" || return 4 ;;
    snap-partial-failure)
      printf 'Name Version Rev Size Publisher Notes\none 1.1 12 1MB fixture -\n' \
        > "$F506_CASE_DIR/refresh.stdout" || return 5
      printf 'fixture discovery unavailable\ntoken=fixture-private-value\n\033[31mcolored fixture diagnostic\033[0m\n' > "$F506_CASE_DIR/refresh.stderr" || return 6
      printf '17\n' > "$F506_CASE_DIR/refresh.return" || return 7 ;;
    *) return 98 ;;
  esac
  f506_observe '
    local -a reply=()
    local -i step_rc=0
    _sys_step_exec update-snap --dry-run || step_rc=$?
    print -r -- "${reply[1]}" > "$F506_CASE_DIR/outcome" || return 90
    print -r -- "${reply[2]}" > "$F506_CASE_DIR/detail" || return 91
    return "$step_rc"
  ' || return 8
  f506_status "$expected_primary" || return 9
  if [[ "$name" == snap-partial-failure ]]; then
    grep -Fxq 17 "$F506_CASE_DIR/refresh.backend.return" || return 16
  else
    grep -Fxq 0 "$F506_CASE_DIR/refresh.backend.return" || return 17
  fi
  if [[ "$expected_primary" -eq 0 ]]; then
    grep -Fxq "$expected_fragment" "$F506_CASE_DIR/detail" || return 10
    if [[ "$name" == snap-empty-warning || "$name" == snap-stdout-current || "$name" == snap-header-empty ]]; then
      grep -Fxq current "$F506_CASE_DIR/outcome" || return 18
    else
      grep -Fxq planned "$F506_CASE_DIR/outcome" || return 19
    fi
  else
    f506_has "$expected_fragment" || return 10
    grep -Fxq failed "$F506_CASE_DIR/outcome" || return 20
  fi
  grep -Fxq closed "$F506_CASE_DIR/stdin-closed" || return 22
  [[ ! -e "$F506_CASE_DIR/stdin-read" ]] || return 23
  grep -Fxq 'refresh --list' "$F506_CASE_DIR/snap.events" || return 11
  [[ "$(wc -l < "$F506_CASE_DIR/snap.events")" -eq 1 ]] || return 12
  f506_lacks '3 snaps' || return 13
  if [[ "$expected_primary" -ne 0 ]]; then
    f506_has 'fixture discovery unavailable' || return 21
    f506_has '[redacted potentially sensitive output]' || return 26
    f506_has 'colored fixture diagnostic' || return 27
    f506_lacks 'fixture-private-value' || return 28
    f506_lacks $'\033' || return 29
    f506_lacks '1 snap pending' || return 14
    f506_lacks 'updated' || return 15
  fi
}

@test "sys update results: Snap advisory counts stdout rows and rejects partial producer failure" {
  local row name code fragment result failures=0
  for row in 'snap-empty-warning|0|no refreshes pending' \
    'snap-stdout-current|0|no refreshes pending' \
    'snap-header-empty|0|no refreshes pending' \
    'snap-two-warning|0|2 snaps pending' \
    'snap-partial-failure|1|Snap could not calculate the refresh plan.'; do
    IFS='|' read -r name code fragment <<< "$row"
    if f506_snap_preview_row "$name" "$code" "$fragment"; then result=0
    else result=$?; failures=$((failures + 1)); fi
    printf '%s\t%s\n' "$name" "$result" >> "$F506_ROOT/preview-matrix.tsv"
  done
  [ "$(wc -l < "$F506_ROOT/preview-matrix.tsv")" -eq 5 ]
  [ "$failures" -eq 0 ]
}

# This new caller fixture is intentionally smaller than sys_fzf_integrity's
# release/archive fixture. It proves only the post-release owner check and
# observed HEAD result. Existing real release-publication controls stay owned
# by sys_fzf_integrity.bats and must be retained when the draft is ported.
f506_fzf_checkout() {
  local repository="$1"
  mkdir -p "$repository/bin" || return 1
  printf '#!%s\nprintf "0.99.0 (fixture)\\n"\n' "$BASH" > "$repository/bin/fzf" || return 2
  chmod -- 700 "$repository/bin/fzf" || return 3
  git init -q -b main "$repository" || return 4
  git -C "$repository" config user.name 'System Fixture' || return 5
  git -C "$repository" config user.email fixture@example.invalid || return 6
  git -C "$repository" config commit.gpgSign false || return 7
  git -C "$repository" config core.hooksPath /dev/null || return 8
  git -C "$repository" add bin/fzf || return 9
  git -C "$repository" commit -qm fixture || return 10
  git -C "$repository" remote add origin https://github.com/junegunn/fzf.git || return 11
}

f506_fzf_post_owner_row() {
  local mode="$1" old new after
  f506_case "fzf-post-$mode" || return 1
  export XDG_DATA_HOME="$F506_CASE_DIR/data"
  export F506_FZF_DIR="$XDG_DATA_HOME/fzf"
  f506_fzf_checkout "$F506_FZF_DIR" || return 2
  old=$(git -C "$F506_FZF_DIR" rev-parse HEAD) || return 3
  git -C "$F506_FZF_DIR" commit --allow-empty -qm 'next fixture identity' || return 4
  new=$(git -C "$F506_FZF_DIR" rev-parse HEAD) || return 5
  git -C "$F506_FZF_DIR" update-ref HEAD "$old" "$new" || return 6
  export F506_FZF_NEW="$new" F506_FZF_OLD="$old" F506_FZF_MODE="$mode"
  f506_observe '
    path=("$F506_FZF_DIR/bin" $path)
    _sys_update_git_logged() {
      [[ "$*" == "-C $F506_FZF_DIR pull --ff-only origin" ]] || return 97
      print -r -- "$*" > "$F506_CASE_DIR/pull.reached" || return 91
      if [[ "$F506_FZF_MODE" == changed ]]; then
        git -C "$F506_FZF_DIR" update-ref HEAD "$F506_FZF_NEW" "$F506_FZF_OLD" || return 92
      fi
      return 0
    }
    _sys_update_fzf_verified_release() {
      print -r -- "$1" > "$F506_CASE_DIR/release.reached" || return 93
      # Boundary model: publication completed but a competing owner now wins.
      mkdir -p "$F506_CASE_DIR/other-bin" || return 94
      cp "$F506_FZF_DIR/bin/fzf" "$F506_CASE_DIR/other-bin/fzf" || return 95
      path=("$F506_CASE_DIR/other-bin" $path)
      rehash
      return 0
    }
    update-fzf --yes
  ' || return 7
  f506_status 1 || return 8
  [[ -s "$F506_CASE_DIR/pull.reached" ]] || return 9
  [[ -s "$F506_CASE_DIR/release.reached" ]] || return 16
  after=$(git -C "$F506_FZF_DIR" rev-parse HEAD) || return 10
  printf '%s\n%s\n' "$old" "$after" > "$F506_CASE_DIR/head.before-after" || return 11
  case "$mode" in
    same)
      [[ "$after" == "$old" ]] || return 12
      f506_lacks 'fzf updated' || return 13
      f506_has 'fzf checkout is current' || return 17 ;;
    changed)
      [[ "$after" == "$new" && "$after" != "$old" ]] || return 14
      f506_has 'fzf checkout updated' || return 18 ;;
    *) return 98 ;;
  esac
  f506_has 'active executable no longer belongs to this checkout' || return 15
}

@test "sys update results: post-release owner refusal never infers a HEAD change" {
  local mode result failures=0
  for mode in same changed; do
    if f506_fzf_post_owner_row "$mode"; then result=0
    else result=$?; failures=$((failures + 1)); fi
    printf '%s\t%s\n' "$mode" "$result" >> "$F506_ROOT/fzf-result-matrix.tsv"
  done
  [ "$(wc -l < "$F506_ROOT/fzf-result-matrix.tsv")" -eq 2 ]
  [ "$failures" -eq 0 ]
}

@test "sys update results: unsafe active fzf remains applicable and aggregate reports blocked" {
  f506_case fzf-unsafe-active
  f506_fzf_checkout "$F506_CASE_DIR/checkout"
  ln -s "$F506_CASE_DIR/checkout" "$HOME/.fzf"
  f506_observe '
    path=("$HOME/.fzf/bin" $path)
    local -i applies_rc=0 direct_rc=0
    _sys_update_fzf_applies || applies_rc=$?
    print -r -- "$applies_rc" > "$F506_CASE_DIR/applies.actual" || return 90
    local -a reply=()
    _sys_step_exec update-fzf --yes || direct_rc=$?
    print -r -- "$direct_rc" > "$F506_CASE_DIR/direct.actual" || return 91
    print -r -- "${reply[1]}" > "$F506_CASE_DIR/outcome" || return 92
    # Restrict only host applicability. The real fzf predicate and command run.
    _sys_step_applies() {
      [[ "$1" == update-fzf ]] || return 1
      _sys_update_fzf_applies
    }
    update-system --yes
  '
  f506_status 1
  grep -Fxq 0 "$F506_CASE_DIR/applies.actual"
  grep -Fxq 1 "$F506_CASE_DIR/direct.actual"
  grep -Fxq blocked "$F506_CASE_DIR/outcome"
  f506_has 'blocked'
  f506_lacks 'No update steps apply'
  f506_lacks 'updated'
}


# Terminal guards are real. The helper return values below are finite returned
# models; the common wrapper/core picker protocol has its own qualification.
f506_pty_observe() {
  local body="$1" runner_rc=0
  export F506_PTY_PROGRAM="$F506_CASE_DIR/pty.zsh" SHELL=/bin/sh
  cat > "$F506_PTY_PROGRAM" <<'ZSH' || return 1
emulate -R zsh
export ZSH_CUSTOM="$TEST_SUITE_ROOT"
source "$TEST_SUITE_ROOT/functions.zsh" || exit 90
source "$F506_ROOT/context.zsh" || exit 91
_f506_action() {
ZSH
  printf '%s\n' "$body" >> "$F506_PTY_PROGRAM" || return 2
  cat >> "$F506_PTY_PROGRAM" <<'ZSH' || return 3
}
local -i primary=0
_f506_action > "$F506_CASE_DIR/stdout" || primary=$?
print -r -- "$primary" > "$F506_CASE_DIR/primary.status" || exit 92
exit 0
ZSH
  script -qefc 'exec zsh -f "$F506_PTY_PROGRAM"' \
    "$F506_CASE_DIR/pty.raw" < /dev/null \
    > "$F506_CASE_DIR/pty.wrapper.stdout" 2> "$F506_CASE_DIR/pty.wrapper.stderr" || runner_rc=$?
  printf '%s\n' "$runner_rc" > "$F506_CASE_DIR/pty.wrapper.status" || return 4
  [[ "$runner_rc" -eq 0 ]] || return 5
  [[ -f "$F506_CASE_DIR/primary.status" ]] || return 6
  tr -d '\r' < "$F506_CASE_DIR/pty.raw" > "$F506_CASE_DIR/stderr" || return 7
}

f506_confirm_fixture() {
  local consumer="$1"
  printf 'Name Version Rev Size Publisher Notes\none 1.1 12 1MB fixture -\n' \
    > "$F506_CASE_DIR/refresh.stdout" || return 1
  printf '#!%s\n' "$BASH" > "$F506_CASE_DIR/native-backend" || return 2
  cat >> "$F506_CASE_DIR/native-backend" <<'MOCK' || return 3
printf '%s\0' "$@" >> "$F506_CASE_DIR/native.argv.nul"
case "${0##*/}:$*" in
  'pacman:-Qu') printf 'one 1.0 -> 1.1\n' ;;
  'pacman:-Syu --noconfirm'|'softwareupdate:--install --no-scan Fixture-1')
    printf '%s\n' "${0##*/} $*" >> "$F506_CASE_DIR/mutations" ;;
  *) printf 'unexpected native: %s %s\n' "${0##*/}" "$*" >> "$F506_CASE_DIR/unexpected"; exit 97 ;;
esac
MOCK
  cp "$F506_CASE_DIR/native-backend" "$TEST_MOCK_BIN/pacman" || return 4
  cp "$F506_CASE_DIR/native-backend" "$TEST_MOCK_BIN/softwareupdate" || return 5
  chmod -- 700 "$TEST_MOCK_BIN/pacman" "$TEST_MOCK_BIN/softwareupdate" || return 6
  printf '#!%s\n' "$BASH" > "$F506_CASE_DIR/apt-env" || return 7
  cat >> "$F506_CASE_DIR/apt-env" <<'MOCK' || return 8
[[ "$1" == -i ]] || exit 97
shift
while [[ "${1:-}" == *=* ]]; do shift; done
[[ "$1" == apt-get ]] || exit 97
shift
case " $* " in
  *' -s full-upgrade '*) printf 'Inst one [1] (2 fixture [amd64])\n' ;;
  *' full-upgrade -y '*|*' autoremove -y '*)
    printf 'apt-get %s\n' "$*" >> "$F506_CASE_DIR/mutations"
    printf '0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.\n' ;;
  *) printf 'unexpected apt: %s\n' "$*" >> "$F506_CASE_DIR/unexpected"; exit 97 ;;
esac
MOCK
  chmod -- 700 "$F506_CASE_DIR/apt-env" || return 9
  case "$consumer" in
    fzf)
      export XDG_DATA_HOME="$F506_CASE_DIR/data" F506_FZF_DIR="$F506_CASE_DIR/data/fzf"
      f506_fzf_checkout "$F506_FZF_DIR" || return 10 ;;
    omz) f506_fzf_checkout "$F506_CASE_DIR/omz" || return 11 ;;
    plugins) f506_fzf_checkout "$F506_CASE_DIR/custom/plugins/fixture" || return 12 ;;
  esac
  cat > "$F506_CASE_DIR/confirm-context.zsh" <<'ZSH' || return 13
emulate -R zsh
# Record the actual return of this finite helper boundary, distinct from the
# outer PTY runner and public command; no picker/native signal is simulated.
_f506_ask_backend() {
  print -r -- "$1" > "$F506_CASE_DIR/prompt" || return 91
  [[ -t 0 && -t 2 ]] || return 92
  return "$F506_CONFIRM_RC"
}
_sys_confirm() {
  local -i observed=0
  _f506_ask_backend "$@" || observed=$?
  print -r -- "$observed" > "$F506_CASE_DIR/confirm.actual" || return 93
  return "$observed"
}
_sys_update_git_logged() {
  print -r -- "$*" >> "$F506_CASE_DIR/mutations" || return 94
  return 0
}
_sys_update_fzf_verified_release() {
  print -r -- "$*" > "$F506_CASE_DIR/release.reached" || return 95
}
_sys_run_with_timeout() { shift; "$@"; }
case "$F506_CONSUMER" in
  fzf) path=("$F506_FZF_DIR/bin" $path) ;;
  omz) ZSH="$F506_CASE_DIR/omz" ;;
  plugins) ZSH_CUSTOM="$F506_CASE_DIR/custom" ;;
  aggregate)
    _sys_step_applies() { [[ "$1" == update-snap ]]; } ;;
  native)
    _SYS_CAPABILITIES[package_manager]=pacman ;;
  software)
    _sys_macos_softwareupdate_records() {
      print -r -- reached > "$F506_CASE_DIR/native-collector.reached" || return 96
      print -r -- $'Fixture-1\tinstall\tFixture'
    } ;;
  apt)
    _SYS_PRIVILEGE_NONINTERACTIVE=1
    _sys_has_capability() { [[ "$1" == package:apt ]]; }
    _sys_update_resolve_trusted_program() {
      [[ "$1" == env ]] || return 97
      REPLY="$F506_CASE_DIR/apt-env"
    }
    _sys_apt_key_plan() { REPLY=0; }
    _sys_apt_plan_blocker() { REPLY=""; }
    _sys_apt_prepare_transaction() { return 0; }
    _sys_resolve_privilege_prefix() { reply=(); }
    _sys_apt_refresh_indexes() { reply=(0 '' '' ''); }
    _sys_apt_dpkg_state_clean() { return 0; }
    _sys_apt_report_reboot_requirement() { return 0; }
    ;;
esac
ZSH
}

f506_confirm_consumer_row() {
  local consumer="$1" code="$2" expected=0 observed
  f506_case "confirm-$consumer-$code" || return 1
  export F506_CONSUMER="$consumer" F506_CONFIRM_RC="$code"
  f506_confirm_fixture "$consumer" || return 2
  f506_pty_observe '
    source "$F506_CASE_DIR/confirm-context.zsh" || return 90
    case "$F506_CONSUMER" in
      snap) update-snap ;;
      software) _sys_update_softwareupdate 0 0 ;;
      native) _sys_update_platform_packages 0 0 ;;
      fzf) update-fzf ;;
      omz) update-omz ;;
      plugins) update-zsh-plugins ;;
      aggregate) update-system ;;
      apt) update-apt ;;
      *) return 97 ;;
    esac
  ' || return 3
  # First qualify branch reach, before checking the expected public status.
  [[ -s "$F506_CASE_DIR/prompt" ]] || return 4
  observed=$(cat "$F506_CASE_DIR/confirm.actual") || return 5
  [[ "$observed" -eq "$code" ]] || return 6
  case "$code" in 0|1) expected=0 ;; 2) expected=1 ;; 130|143) expected="$code" ;; *) return 98 ;; esac
  f506_status "$expected" || return 7
  if [[ "$code" -eq 0 ]]; then
    [[ -s "$F506_CASE_DIR/mutations" ]] || return 8
  else
    [[ ! -e "$F506_CASE_DIR/mutations" ]] || return 9
  fi
  if [[ "$code" -eq 1 ]]; then
    grep -Eiq 'cancelled' "$F506_CASE_DIR/stderr" || return 10
  else
    # Error or interruption must never be described as deliberate decline.
    local grep_rc=0
    grep -Eiq 'cancelled' "$F506_CASE_DIR/stderr" || grep_rc=$?
    [[ "$grep_rc" -eq 1 ]] || return 11
  fi
  if [[ "$consumer" == fzf ]]; then
    [[ "$(git -C "$F506_FZF_DIR" status --porcelain)" == '' ]] || return 12
  fi
}

f506_confirm_consumer_matrix() {
  local consumer="$1" code result failures=0
  for code in 0 1 2 130 143; do
    if f506_confirm_consumer_row "$consumer" "$code"; then result=0
    else result=$?; failures=$((failures + 1)); fi
    printf '%s\t%s\t%s\n' "$consumer" "$code" "$result" >> "$F506_ROOT/confirm-matrix.tsv" || return 1
  done
  [[ "$(wc -l < "$F506_ROOT/confirm-matrix.tsv")" -eq 5 ]] || return 2
  [[ "$failures" -eq 0 ]] || return 3
}

@test "sys update confirmation: Snap accepts declines and preserves operational stops" {
  has_util_linux_script || skip "requires the existing util-linux script PTY harness"
  f506_confirm_consumer_matrix snap
}
@test "sys update confirmation: macOS update consumer accepts declines and preserves operational stops" {
  has_util_linux_script || skip "requires the existing util-linux script PTY harness"
  f506_confirm_consumer_matrix software
}
@test "sys update confirmation: native packages accept declines and preserve operational stops" {
  has_util_linux_script || skip "requires the existing util-linux script PTY harness"
  f506_confirm_consumer_matrix native
}
@test "sys update confirmation: Git fzf accepts declines and preserves operational stops" {
  has_util_linux_script || skip "requires the existing util-linux script PTY harness"
  f506_confirm_consumer_matrix fzf
}
@test "sys update confirmation: Oh My Zsh accepts declines and preserves operational stops" {
  has_util_linux_script || skip "requires the existing util-linux script PTY harness"
  f506_confirm_consumer_matrix omz
}
@test "sys update confirmation: plugins accept declines and preserve operational stops" {
  has_util_linux_script || skip "requires the existing util-linux script PTY harness"
  f506_confirm_consumer_matrix plugins
}
@test "sys update confirmation: aggregate accepts declines and preserves operational stops" {
  has_util_linux_script || skip "requires the existing util-linux script PTY harness"
  f506_confirm_consumer_matrix aggregate
}
@test "sys update confirmation: APT accepts declines and preserves operational stops" {
  has_util_linux_script || skip "requires the existing util-linux script PTY harness"
  f506_confirm_consumer_matrix apt
}

@test "sys update results: observation helpers reject missing and tampered intermediate evidence" {
  f506_case oracle-qualification
  printf '0\n' > "$F506_CASE_DIR/primary.status"
  : > "$F506_CASE_DIR/stdout"
  : > "$F506_CASE_DIR/stderr"
  local label rc failures=0
  for label in valid wrong-status missing-status missing-stdout missing-unexpected stdout-leak unexpected-call missing-stderr; do
    printf '0\n' > "$F506_CASE_DIR/primary.status"
    : > "$F506_CASE_DIR/stdout"
    : > "$F506_CASE_DIR/stderr"
    : > "$F506_CASE_DIR/unexpected"
    case "$label" in
      wrong-status) printf '17\n' > "$F506_CASE_DIR/primary.status" ;;
      missing-status) rm "$F506_CASE_DIR/primary.status" ;;
      missing-stdout) rm "$F506_CASE_DIR/stdout" ;;
      missing-unexpected) rm "$F506_CASE_DIR/unexpected" ;;
      stdout-leak) printf 'leak\n' > "$F506_CASE_DIR/stdout" ;;
      unexpected-call) printf 'unexpected\n' > "$F506_CASE_DIR/unexpected" ;;
      missing-stderr) rm "$F506_CASE_DIR/stderr" ;;
    esac
    rc=0
    if [[ "$label" == missing-stderr ]]; then f506_lacks foo || rc=$?
    else f506_status 0 || rc=$?; fi
    printf '%s\t%s\n' "$label" "$rc" >> "$F506_ROOT/oracle-qualification.tsv"
    if [[ "$label" == valid ]]; then [[ "$rc" -eq 0 ]] || failures=$((failures+1))
    else [[ "$rc" -ne 0 ]] || failures=$((failures+1)); fi
  done
  [ "$(wc -l < "$F506_ROOT/oracle-qualification.tsv")" -eq 8 ]
  [ "$failures" -eq 0 ]
}

@test "sys update results: finite Snap recorder distinguishes supplied input from closed probe stdin" {
  f506_case snap-recorder-qualification
  local actual=0
  printf 'provided-fixture-input\n' | "$F506_ROOT/snap-backend" refresh --list \
    > "$F506_CASE_DIR/control.stdout" 2> "$F506_CASE_DIR/control.stderr" || actual=$?
  printf '%s\n' "$actual" > "$F506_CASE_DIR/control.actual"
  [ "$actual" -eq 0 ]
  grep -Fxq provided-fixture-input "$F506_CASE_DIR/stdin-read"
  [ ! -e "$F506_CASE_DIR/stdin-closed" ]
  f506_case snap-closed-qualification
  f506_observe 'update-snap --dry-run'
  f506_status 0
  grep -Fxq 0 "$F506_CASE_DIR/refresh.backend.return"
  grep -Fxq closed "$F506_CASE_DIR/stdin-closed"
  [ ! -e "$F506_CASE_DIR/stdin-read" ]
}


f506_snap_refusal_row() {
  local mode="$1" actual expected=1 producer_code="$1"
  f506_case "snap-refusal-$mode" || return 1
  printf 'Name Version Rev Size Publisher Notes\none 1.1 12 1MB fixture -\n' \
    > "$F506_CASE_DIR/refresh.stdout" || return 2
  case "$mode" in
    headerless) printf 'one 1.1 12 1MB fixture -\n' > "$F506_CASE_DIR/refresh.stdout" || return 3 ;;
    malformed) printf 'Name Version Rev Size Publisher Notes\none incomplete\n' > "$F506_CASE_DIR/refresh.stdout" || return 4 ;;
    stdout-limit) make_sized_file "$F506_CASE_DIR/refresh.stdout" 262145 || return 5 ;;
    stderr-limit) make_sized_file "$F506_CASE_DIR/refresh.stderr" 262145 || return 6 ;;
    130|143) printf '%s\n' "$mode" > "$F506_CASE_DIR/refresh.return" || return 7; expected="$mode" ;;
    130-overflow|143-overflow)
      producer_code="${mode%-overflow}"
      printf '%s\n' "$producer_code" > "$F506_CASE_DIR/refresh.return" || return 21
      make_sized_file "$F506_CASE_DIR/refresh.stderr" 262145 || return 22
      expected="$producer_code" ;;
    124) printf '%s\n' "$mode" > "$F506_CASE_DIR/refresh.return" || return 8 ;;
    *) return 98 ;;
  esac
  f506_observe '
    local -a reply=()
    local -i observed=0
    _sys_step_exec update-snap --dry-run || observed=$?
    print -r -- "${reply[1]}" > "$F506_CASE_DIR/outcome" || return 91
    print -r -- "${reply[2]}" > "$F506_CASE_DIR/detail" || return 92
    return "$observed"
  ' || return 9
  # Retain and qualify actual child return before classifying the public result.
  actual=$(cat "$F506_CASE_DIR/refresh.backend.return") || return 10
  printf '%s\t%s\n' "$mode" "$actual" >> "$F506_ROOT/refusal-producer.tsv" || return 11
  case "$mode" in
    124|130|143|130-overflow|143-overflow) [[ "$actual" -eq "$producer_code" ]] || return 12 ;;
    *) [[ "$actual" -eq 0 ]] || return 13 ;;
  esac
  f506_status "$expected" || return 14
  [[ "$(wc -l < "$F506_CASE_DIR/snap.events")" -eq 1 ]] || return 15
  [[ ! -e "$F506_CASE_DIR/mutations" ]] || return 16
  f506_lacks 'snap pending' || return 17
  f506_lacks 'snaps pending' || return 18
  f506_lacks 'updated' || return 19
  [[ "$(wc -c < "$F506_CASE_DIR/stderr")" -lt 10000 ]] || return 20
}

@test "sys update results: Snap rejects incomplete successful observations before constructing a plan" {
  # Headerless/malformed refusal is the approved companion policy; the byte
  # controls qualify both streams, not an invented historical original case.
  local mode result failures=0
  for mode in headerless malformed stdout-limit stderr-limit; do
    if f506_snap_refusal_row "$mode"; then result=0
    else result=$?; failures=$((failures+1)); fi
    printf '%s\t%s\n' "$mode" "$result" >> "$F506_ROOT/refusal-policy.tsv"
  done
  [ "$(wc -l < "$F506_ROOT/refusal-policy.tsv")" -eq 4 ]
  [ "$failures" -eq 0 ]
}

@test "sys update results: Snap preview timeout remains failure and interruptions retain their statuses" {
  local mode result failures=0
  for mode in 124 130 143 130-overflow 143-overflow; do
    if f506_snap_refusal_row "$mode"; then result=0
    else result=$?; failures=$((failures+1)); fi
    printf '%s\t%s\n' "$mode" "$result" >> "$F506_ROOT/refusal-stops.tsv"
  done
  [ "$(wc -l < "$F506_ROOT/refusal-stops.tsv")" -eq 5 ]
  [ "$failures" -eq 0 ]
}
