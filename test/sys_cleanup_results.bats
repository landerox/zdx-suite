#!/usr/bin/env bats
# Focused cleanup plans, results and preserved resource identities.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  export F506_ROOT="$HOME/f506" F506_CASE_DIR=""
  export NO_COLOR=1
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
    cat "$F506_CASE_DIR/refresh.stdout" || exit 90
    cat "$F506_CASE_DIR/refresh.stderr" >&2 || exit 91
    code=$(cat "$F506_CASE_DIR/refresh.return") || exit 92
    exit "$code" ;;
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
  observed=$(cat "$F506_CASE_DIR/primary.status") || return 1
  [[ "$observed" =~ ^[0-9]+$ ]] || return 2
  [[ "$observed" -eq "$1" ]] || return 3
  [[ -f "$F506_CASE_DIR/stdout" && -f "$F506_CASE_DIR/stderr" ]] || return 4
  [[ ! -s "$F506_CASE_DIR/stdout" ]] || return 5
  [[ -f "$F506_CASE_DIR/unexpected" && ! -s "$F506_CASE_DIR/unexpected" ]] || return 6
}

f506_has() { grep -Fq -- "$1" "$F506_CASE_DIR/stderr" || return 1; }
f506_lacks() {
  local grep_rc=0
  [[ -f "$F506_CASE_DIR/stderr" ]] || return 1
  grep -Fq -- "$1" "$F506_CASE_DIR/stderr" || grep_rc=$?
  [[ "$grep_rc" -eq 1 ]] || return 2
}

f506_assert_unsafe_preserved() {
  local unsafe_link="$1"
  [[ -L "$unsafe_link" ]] || return 28
  [[ -d "$F506_CASE_DIR/linked" && ! -L "$F506_CASE_DIR/linked" ]] || return 29
  file_identity "$unsafe_link" > "$F506_CASE_DIR/link.identity.after" || return 30
  command readlink "$unsafe_link" > "$F506_CASE_DIR/link.target.after" || return 31
  file_identity "$F506_CASE_DIR/linked" > "$F506_CASE_DIR/target.identity.after" || return 32
  file_identity "$F506_CASE_DIR/linked/keep" > "$F506_CASE_DIR/payload.identity.after" || return 33
  cmp "$F506_CASE_DIR/link.identity.before" "$F506_CASE_DIR/link.identity.after" || return 34
  cmp "$F506_CASE_DIR/link.target.before" "$F506_CASE_DIR/link.target.after" || return 35
  cmp "$F506_CASE_DIR/target.identity.before" "$F506_CASE_DIR/target.identity.after" || return 36
  cmp "$F506_CASE_DIR/payload.identity.before" "$F506_CASE_DIR/payload.identity.after" || return 37
  cmp "$F506_CASE_DIR/payload.before" "$F506_CASE_DIR/linked/keep" || return 38
  return 0
}

f506_unsafe_cleanup_row() {
  local name="$1" unsafe_link=""
  f506_case "unsafe-$name" || return 1
  # Layouts are separate invocations under the same private HOME. Remove only
  # the preceding fixture symlink, never its target or a real user directory.
  if [[ -L "$HOME/.cache" ]]; then command rm "$HOME/.cache" || return 2; fi
  mkdir -p "$HOME/safe-npm-cache" "$F506_CASE_DIR/linked/registry/cache" \
    "$F506_CASE_DIR/linked/downloads" "$F506_CASE_DIR/linked/thumbnails" \
    "$F506_CASE_DIR/linked/tmp" || return 3
  printf 'retain linked data\n' > "$F506_CASE_DIR/linked/keep" || return 4
  printf 'retain dry-run cache\n' > "$HOME/safe-npm-cache/keep" || return 5
  export CARGO_HOME="$F506_CASE_DIR/unused-cargo" RUSTUP_HOME="$F506_CASE_DIR/unused-rustup"
  case "$name" in
    cache)
      unsafe_link="$HOME/.cache"
      ln -s "$F506_CASE_DIR/linked" "$unsafe_link" || return 6 ;;
    cargo)
      unsafe_link="$F506_CASE_DIR/cargo"
      ln -s "$F506_CASE_DIR/linked" "$unsafe_link" || return 7
      export CARGO_HOME="$unsafe_link" ;;
    rustup)
      unsafe_link="$F506_CASE_DIR/rustup"
      ln -s "$F506_CASE_DIR/linked" "$unsafe_link" || return 8
      export RUSTUP_HOME="$unsafe_link" ;;
    *) return 98 ;;
  esac
  [[ -L "$unsafe_link" ]] || return 19
  [[ -d "$F506_CASE_DIR/linked" && ! -L "$F506_CASE_DIR/linked" ]] || return 20
  file_identity "$unsafe_link" > "$F506_CASE_DIR/link.identity.before" || return 21
  command readlink "$unsafe_link" > "$F506_CASE_DIR/link.target.before" || return 22
  printf '%s\n' "$F506_CASE_DIR/linked" > "$F506_CASE_DIR/link.target.expected" || return 23
  cmp "$F506_CASE_DIR/link.target.expected" "$F506_CASE_DIR/link.target.before" || return 24
  file_identity "$F506_CASE_DIR/linked" > "$F506_CASE_DIR/target.identity.before" || return 25
  file_identity "$F506_CASE_DIR/linked/keep" > "$F506_CASE_DIR/payload.identity.before" || return 26
  cp "$F506_CASE_DIR/linked/keep" "$F506_CASE_DIR/payload.before" || return 27
  f506_observe '
    _sys_tool_available() { [[ "$1" == npm || "$1" == cargo || "$1" == rustup ]]; }
    _sys_has_capability() { return 1; }
    _sys_has_systemd() { return 1; }
    _sys_clean_pip_command() { return 1; }
    clean-system --deep --dry-run
  ' || return 9
  f506_status 0 || return 10
  f506_has 'npm cache' || return 11
  f506_has 'Skipping' || return 12
  case "$name" in
    cache) f506_has '~/.cache/' || return 13 ;;
    cargo) f506_has 'Cargo registry cache' || return 14 ;;
    rustup) f506_has 'Rust downloads' || return 15 ;;
  esac
  f506_assert_unsafe_preserved "$unsafe_link" || return 28
  grep -Fxq 'retain dry-run cache' "$HOME/safe-npm-cache/keep" || return 17
  return 0
}

@test "sys cleanup results: SYS023: linked cache Cargo and rustup roots skip only unsafe targets" {
  local name result failures=0
  for name in cache cargo rustup; do
    if f506_unsafe_cleanup_row "$name"; then result=0
    else result=$?; failures=$((failures + 1)); fi
    printf '%s\t%s\n' "$name" "$result" >> "$F506_ROOT/unsafe-matrix.tsv"
  done
  [ "$(wc -l < "$F506_ROOT/unsafe-matrix.tsv")" -eq 3 ]
  [ "$failures" -eq 0 ]
}

@test "sys cleanup results: SYS041: ordinary Snap failure retains both backend channels and examines later target" {
  f506_case snap-removal-error
  printf '17\n' > "$F506_CASE_DIR/one.remove.return"
  f506_observe '
    functions[_f506_original_mark_partial]="$functions[_zdx_timed_mark_partial]"
    _zdx_timed_mark_partial() {
      print -r -- called >> "$F506_CASE_DIR/partial.actual" || return 90
      _f506_original_mark_partial "$@"
    }
    clean-snaps --yes
  '
  f506_status 1
  f506_has 'backend progress: remove one --revision=11'
  f506_has 'backend diagnostic: remove one --revision=11'
  grep -Fxq 'remove two --revision=22' "$F506_CASE_DIR/snap.events"
  grep -Fxq 17 "$F506_CASE_DIR/one.backend.return"
  grep -Fxq 0 "$F506_CASE_DIR/two.backend.return"
  [ "$(cat "$F506_CASE_DIR/revisions.state")" = 'one 11' ]
  f506_has 'partial failures'
  f506_has '1 of 2'
  grep -Fxq called "$F506_CASE_DIR/partial.actual"
}

f506_snap_interrupt_row() {
  local code="$1"
  f506_case "snap-stop-$code" || return 1
  printf '%s\n' "$code" > "$F506_CASE_DIR/one.remove.return" || return 2
  cp "$F506_CASE_DIR/revisions.state" "$F506_CASE_DIR/revisions.before" || return 3
  f506_observe 'clean-snaps --yes' || return 4
  f506_status "$code" || return 5
  grep -Fxq "$code" "$F506_CASE_DIR/one.backend.return" || return 6
  [[ ! -e "$F506_CASE_DIR/two.backend.return" ]] || return 7
  if grep -Fxq 'remove two --revision=22' "$F506_CASE_DIR/snap.events"; then return 8; fi
  cmp "$F506_CASE_DIR/revisions.before" "$F506_CASE_DIR/revisions.state" || return 9
  f506_has 'backend diagnostic: remove one --revision=11' || return 10
  f506_has 'Not run:' || return 11
  f506_has 'two 22' || return 12
  f506_lacks 'completed: 2' || return 13
}

@test "sys cleanup results: SYS041 SYS055: returned Snap stops preserve status diagnostics and exact unrun target" {
  local code result failures=0
  for code in 130 143; do
    if f506_snap_interrupt_row "$code"; then result=0
    else result=$?; failures=$((failures + 1)); fi
    printf '%s\t%s\n' "$code" "$result" >> "$F506_ROOT/snap-stop-matrix.tsv"
  done
  [ "$(wc -l < "$F506_ROOT/snap-stop-matrix.tsv")" -eq 2 ]
  [ "$failures" -eq 0 ]
}

# Numbered table rows, scope labels, prompts and verdict subjects below are
# the approved focused cleanup presentation. The numbered table contains
# every reviewed target in its original order.
f506_assert_numbered_plan() {
  local kind="$1" count="$2"
  local expected="$F506_CASE_DIR/plan.expected.tsv" actual="$F506_CASE_DIR/plan.actual.tsv"
  [[ -f "$F506_CASE_DIR/stderr" ]] || return 1
  # These finite fixtures have whitespace-free names and no colored output.
  # Preserve the complete numbered sequence, including extra/duplicate rows;
  # normalize only the table renderer's alignment spaces, never sort/dedup.
  awk '
    /^[[:space:]]*[0-9]+([[:space:]]|$)/ {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      gsub(/[[:space:]]+/, "\t", line)
      print line
    }
  ' "$F506_CASE_DIR/stderr" > "$actual" || return 2
  case "$kind:$count" in
    snap:0) : > "$expected" || return 3 ;;
    snap:1) printf '1\tone\t11\n' > "$expected" || return 4 ;;
    snap:2) printf '1\tone\t11\n2\ttwo\t22\n' > "$expected" || return 5 ;;
    telemetry:1) printf '1\t~/.config/zdx/telemetry.json\n' > "$expected" || return 6 ;;
    *) return 98 ;;
  esac
  cmp "$expected" "$actual" || return 7
  return 0
}

f506_snap_plan_row() {
  local count="$1"
  f506_case "snap-plan-$count" || return 1
  case "$count" in
    0) : > "$F506_CASE_DIR/revisions.state" || return 2 ;;
    1) printf 'one 11\n' > "$F506_CASE_DIR/revisions.state" || return 3 ;;
    2) ;;
    *) return 98 ;;
  esac
  cp "$F506_CASE_DIR/revisions.state" "$F506_CASE_DIR/revisions.before" || return 4
  f506_observe 'clean-snaps --dry-run' || return 5
  f506_status 0 || return 6
  cmp "$F506_CASE_DIR/revisions.before" "$F506_CASE_DIR/revisions.state" || return 7
  if grep -q '^remove ' "$F506_CASE_DIR/snap.events"; then return 8; fi
  f506_assert_numbered_plan snap "$count" || return 11
  if [[ "$count" -eq 0 ]]; then
    f506_has 'No disabled snap revisions' || return 9
    f506_lacks 'Dry run:' || return 10
  else
    f506_has "Dry run: $count planned; nothing was removed." || return 13
  fi
}

@test "sys cleanup results: SYS055: empty one and multiple Snap plans are numbered exact snapshots" {
  local count result failures=0
  for count in 0 1 2; do
    if f506_snap_plan_row "$count"; then result=0
    else result=$?; failures=$((failures + 1)); fi
    printf '%s\t%s\n' "$count" "$result" >> "$F506_ROOT/snap-plan-matrix.tsv"
  done
  [ "$(wc -l < "$F506_ROOT/snap-plan-matrix.tsv")" -eq 3 ]
  [ "$failures" -eq 0 ]
}

@test "sys cleanup results: SYS055: successful Snap results follow actual per-target removals and counted verdict" {
  f506_case snap-success
  f506_observe 'clean-snaps --yes'
  f506_status 0
  f506_assert_numbered_plan snap 2
  [ ! -s "$F506_CASE_DIR/revisions.state" ]
  grep -Fxq 0 "$F506_CASE_DIR/one.backend.return"
  grep -Fxq 0 "$F506_CASE_DIR/two.backend.return"
  grep '^remove ' "$F506_CASE_DIR/snap.events" > "$F506_CASE_DIR/removals.actual"
  printf 'remove one --revision=11\nremove two --revision=22\n' > "$F506_CASE_DIR/removals.expected"
  cmp "$F506_CASE_DIR/removals.expected" "$F506_CASE_DIR/removals.actual"
  grep -Eq 'one.*11.*removed' "$F506_CASE_DIR/stderr"
  grep -Eq 'two.*22.*removed' "$F506_CASE_DIR/stderr"
  f506_has 'Snap cleanup completed: 2 disabled revisions removed.'
}

f506_telemetry_file() {
  mkdir -p "$HOME/.config/zdx" || return 1
  # The clear owner validates file metadata, not record-schema parsing.
  printf '{"fixture":"preserved until authorized"}\n' > "$HOME/.config/zdx/telemetry.json" || return 2
  cp "$HOME/.config/zdx/telemetry.json" "$F506_CASE_DIR/telemetry.before" || return 3
  file_identity "$HOME/.config/zdx/telemetry.json" > "$F506_CASE_DIR/identity.before" || return 4
}

@test "sys cleanup results: SYS055: telemetry dry run is one numbered abbreviated target and preserves bytes and identity" {
  f506_case telemetry-dry
  f506_telemetry_file
  f506_observe 'sys-telemetry --clear --dry-run'
  f506_status 0
  f506_assert_numbered_plan telemetry 1
  f506_has 'Dry run: 1 planned; nothing was cleared.'
  cmp "$F506_CASE_DIR/telemetry.before" "$HOME/.config/zdx/telemetry.json"
  file_identity "$HOME/.config/zdx/telemetry.json" > "$F506_CASE_DIR/identity.after"
  cmp "$F506_CASE_DIR/identity.before" "$F506_CASE_DIR/identity.after"
  [ ! -e "$HOME/.config/zdx/.telemetry.lock" ]
}

@test "sys cleanup results: SYS055: telemetry clear reports actual replacement with a counted verdict and absent-log no-op" {
  f506_case telemetry-clear
  f506_telemetry_file
  f506_observe 'sys-telemetry --clear --yes'
  f506_status 0
  f506_assert_numbered_plan telemetry 1
  [ ! -s "$HOME/.config/zdx/telemetry.json" ]
  [ "$(file_mode "$HOME/.config/zdx/telemetry.json")" = 600 ]
  file_identity "$HOME/.config/zdx/telemetry.json" > "$F506_CASE_DIR/identity.after"
  run cmp "$F506_CASE_DIR/identity.before" "$F506_CASE_DIR/identity.after"
  [ "$status" -eq 1 ]
  f506_has 'Telemetry clear completed: 1 log cleared.'
  [ ! -e "$HOME/.config/zdx/.telemetry.lock" ]
  # Only a private fixture file is removed to reach absence. No product tool,
  # telemetry writer, service or package manager runs during this setup.
  command rm "$HOME/.config/zdx/telemetry.json"
  f506_case telemetry-absent
  f506_observe 'sys-telemetry --clear --yes'
  f506_status 0
  f506_has 'already empty'
  [ ! -e "$HOME/.config/zdx/telemetry.json" ]
  [ ! -e "$HOME/.config/zdx/.telemetry.lock" ]
}


@test "sys cleanup results: all failed Snap commands retain diagnostics without a partial or successful verdict" {
  f506_case snap-all-failed
  printf '17\n' > "$F506_CASE_DIR/one.remove.return"
  printf '18\n' > "$F506_CASE_DIR/two.remove.return"
  cp "$F506_CASE_DIR/revisions.state" "$F506_CASE_DIR/revisions.before"
  f506_observe '
    functions[_f506_original_mark_partial]="$functions[_zdx_timed_mark_partial]"
    _zdx_timed_mark_partial() {
      print -r -- called >> "$F506_CASE_DIR/partial.actual" || return 90
      _f506_original_mark_partial "$@"
    }
    clean-snaps --yes
  '
  f506_status 1
  grep -Fxq 17 "$F506_CASE_DIR/one.backend.return"
  grep -Fxq 18 "$F506_CASE_DIR/two.backend.return"
  cmp "$F506_CASE_DIR/revisions.before" "$F506_CASE_DIR/revisions.state"
  f506_has 'backend diagnostic: remove one --revision=11'
  f506_has 'backend diagnostic: remove two --revision=22'
  f506_has 'Snap cleanup failed: 2 of 2 disabled revisions failed.'
  f506_lacks 'completed'
  [ ! -e "$F506_CASE_DIR/partial.actual" ]
}

@test "sys cleanup results: a changed disabled revision is refused without inventing removal failure counts" {
  f506_case snap-refused
  f506_observe '
    functions[_f506_original_mark_partial]="$functions[_zdx_timed_mark_partial]"
    _zdx_timed_mark_partial() {
      print -r -- called >> "$F506_CASE_DIR/partial.actual" || return 90
      _f506_original_mark_partial "$@"
    }
    functions[_f506_original_authorize]="$functions[_sys_privilege_authorize]"
    _sys_privilege_authorize() {
      _f506_original_authorize "$@" || return $?
      # Model the inventory changing at the existing post-auth boundary.
      printf "two 22\n" > "$F506_CASE_DIR/revisions.state"
    }
    clean-snaps --yes
  '
  f506_status 1
  [ ! -e "$F506_CASE_DIR/one.backend.return" ]
  grep -Fxq 0 "$F506_CASE_DIR/two.backend.return"
  [ ! -s "$F506_CASE_DIR/revisions.state" ]
  f506_has 'one revision 11 is no longer disabled; refusing to remove it.'
  f506_lacks '1 of 2 disabled revisions failed'
  f506_lacks 'completed: 2'
  f506_has 'Snap cleanup could not complete: 1 of 2 disabled revisions refused before removal.'
  grep -Fxq called "$F506_CASE_DIR/partial.actual"
}
