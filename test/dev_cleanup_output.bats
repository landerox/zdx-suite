#!/usr/bin/env bats
# Exact-target cleanup presentation with finite private filesystem fixtures.
# shellcheck disable=SC2016

setup() {
  load test_helper
  export F515CO_ROOT="$HOME/f515-cleanup"
  export F515CO_ZSH F515CO_REAL_RM F515CO_REAL_MV F515CO_REAL_LN
  F515CO_ZSH=$(command -v zsh)
  F515CO_REAL_RM=$(command -v rm)
  F515CO_REAL_MV=$(command -v mv)
  F515CO_REAL_LN=$(command -v ln)
  export NO_COLOR=1 TERM=dumb
  unset F515CO_ASK_RC F515CO_MODE F515CO_RM_MODE F515CO_CONTEXT
  mkdir -m 700 "$F515CO_ROOT"
  {
    printf '#!%s\n' "$BASH"
    cat <<'SH'
set -u
[[ $# == 3 && "$1" == -f && "$2" == -- && "$PWD" == "$F515CO_PROJECT" ]] || exit 97
allowed=0
while IFS= read -r -d '' relative; do
  [[ "$3" != "$relative" ]] || allowed=1
done < "$F515CO_SCENE/targets.nul"
[[ "$allowed" == 1 ]] || exit 97
count=0
[[ ! -f "$F515CO_SCENE/rm/count" ]] || IFS= read -r count < "$F515CO_SCENE/rm/count"
[[ "$count" =~ ^[0-9]+$ && "$count" -lt 30 ]] || exit 97
count=$((count + 1))
printf '%s\n' "$count" > "$F515CO_SCENE/rm/count" || exit 96
printf '%s\0' "$0" "$@" > "$F515CO_SCENE/rm/$count.argv.nul" || exit 96
printf '%s\n' "$F515CO_REAL_RM" > "$F515CO_SCENE/rm/$count.native.selected" || exit 96
"$F515CO_REAL_RM" "$@" > "$F515CO_SCENE/rm/$count.native.stdout" 2> "$F515CO_SCENE/rm/$count.native.stderr"
observed=$?
printf '%s\n' "$observed" > "$F515CO_SCENE/rm/$count.native.post-return" || exit 96
if [[ "${F515CO_RM_MODE-}" == swap-after-first && "$count" == 1 && "$observed" == 0 ]]; then
  "$F515CO_REAL_MV" "$F515CO_PROJECT" "$F515CO_SCENE/moved"
  swap_status=$?
  printf '%s\n' "$swap_status" > "$F515CO_SCENE/swap.mv.post-return" || exit 96
  [[ "$swap_status" == 0 ]] || exit 98
  "$F515CO_REAL_LN" -s "$F515CO_SCENE/victim" "$F515CO_PROJECT"
  swap_status=$?
  printf '%s\n' "$swap_status" > "$F515CO_SCENE/swap.ln.post-return" || exit 96
  [[ "$swap_status" == 0 ]] || exit 98
fi
exit "$observed"
SH
  } > "$TEST_MOCK_BIN/rm"
  chmod -- 700 "$TEST_MOCK_BIN/rm"
  # Retain the exact recorder after teardown removes its executable copy.
  cp "$TEST_MOCK_BIN/rm" "$F515CO_ROOT/rm-recorder.bash" || return 1
  cmp "$TEST_MOCK_BIN/rm" "$F515CO_ROOT/rm-recorder.bash" || return 1
  export F515CO_PROGRAM="$F515CO_ROOT/program.zsh"
  cat > "$F515CO_PROGRAM" <<'ZSH'
emulate -R zsh
_f515co_action() {
  builtin source "$TEST_SUITE_ROOT/functions/dev-menu.zsh" || return 95
  builtin cd -- "$F515CO_PROJECT" || return 95
  print -r -- "${+functions[_zdx_ui_table]}:${+functions[_timed]}" > "$F515CO_SCENE/services"
  functions[_f515co_build_original]="${functions[_dev_clean_build_plan]}"
  _dev_clean_build_plan() {
    _f515co_build_original "$@"
    local -i observed=$?
    print -r -- "$observed" > "$F515CO_SCENE/plan.post-return"
    : > "$F515CO_SCENE/plan.records.nul"
    (( ${#reply[@]} == 0 )) || builtin printf '%s\0' "${reply[@]}" > "$F515CO_SCENE/plan.records.nul"
    return $observed
  }
  _f515co_ask_leaf() {
    case "${F515CO_MODE-}" in
      absent)
        command "$F515CO_REAL_RM" -f -- "$F515CO_PROJECT/a.pyc" > "$F515CO_SCENE/confirm.rm.stdout" 2> "$F515CO_SCENE/confirm.rm.stderr"
        local -i observed=$?
        print -r -- "$observed" > "$F515CO_SCENE/confirm.rm.post-return"
        (( observed == 0 )) || return 98
        ;;
      swap-before)
        command "$F515CO_REAL_MV" "$F515CO_PROJECT" "$F515CO_SCENE/moved" || return 98
        command "$F515CO_REAL_LN" -s "$F515CO_SCENE/victim" "$F515CO_PROJECT" || return 98
        ;;
    esac
    return ${F515CO_ASK_RC:-0}
  }
  _dev_confirm_ask() {
    builtin printf '%s\0' "$@" > "$F515CO_SCENE/confirm.argv.nul"
    _f515co_ask_leaf
    local -i observed=$?
    print -r -- "$observed" > "$F515CO_SCENE/confirm.post-return"
    return $observed
  }
  # Build expected display words from the literal operands recorded by the fixture.
  local relative absolute rendered home_prefix="$HOME/"
  local -i index=0
  while IFS= read -r -d '' relative; do
    absolute="$F515CO_PROJECT/$relative"
    if [[ "$absolute" == "$home_prefix"* ]]; then
      rendered="~/${(q+)${absolute#"$home_prefix"}}"
    else
      rendered="${(q+)absolute}"
    fi
    (( ++index ))
    builtin printf '  %s\n' "${(V)rendered}" > "$F515CO_SCENE/display.$index.expected"
  done < "$F515CO_SCENE/targets.nul"
  builtin source "$F515CO_SCENE/action.zsh"
  local -i observed=$?
  print -r -- "$observed" > "$F515CO_SCENE/public.post-return"
  print -r -- "$_DEV_AUTO_YES" > "$F515CO_SCENE/auto-yes.after"
  return $observed
}
_f515co_action > "$F515CO_SCENE/primary.stdout" 2> "$F515CO_SCENE/primary.stderr"
f515co_primary_rc=$?
print -r -- "$f515co_primary_rc" > "$F515CO_SCENE/primary.status"
return 0
ZSH
}

teardown() {
  local scene directory observed_identity restore_status=0
  for scene in "$F515CO_ROOT"/*; do
    directory="$scene/project/blocked"
    if [[ -d "$directory" && ! -L "$directory" && -f "$scene/blocked.identity.before" ]]; then
      observed_identity=$(file_identity "$directory") || restore_status=1
      file_stat "$directory" mode uid gid device inode > "$scene/blocked.before-teardown" || restore_status=1
      if [[ "$observed_identity" == "$(cat "$scene/blocked.identity.before")" \
        && "$(file_owner_uid "$directory")" == "$EUID" ]]; then
        chmod -- 700 "$directory" || restore_status=1
      fi
    fi
  done
  # Remove only this fixture's recorder before the standard teardown uses rm.
  "$F515CO_REAL_RM" -f -- "$TEST_MOCK_BIN/rm" || restore_status=1
  cleanup_sandbox
  return "$restore_status"
}

f515co_scene() {
  export F515CO_SCENE="$F515CO_ROOT/$1" F515CO_PROJECT="$F515CO_ROOT/$1/project"
  export F515CO_ASK_RC=0 F515CO_MODE=normal F515CO_RM_MODE=normal
  mkdir -m 700 "$F515CO_SCENE" || return 1
  mkdir -p "$F515CO_PROJECT" "$F515CO_SCENE/victim" "$F515CO_SCENE/rm" || return 1
  printf 'PROJECT_CANARY\n' > "$F515CO_PROJECT/keep.txt" || return 1
  printf 'VICTIM_CANARY\n' > "$F515CO_SCENE/victim/keep.txt" || return 1
  file_identity "$F515CO_PROJECT/keep.txt" > "$F515CO_SCENE/canary.identity.before" || return 1
  sha256_file "$F515CO_PROJECT/keep.txt" > "$F515CO_SCENE/canary.sha.before" || return 1
  file_identity "$F515CO_SCENE/victim/keep.txt" > "$F515CO_SCENE/victim.identity.before" || return 1
  sha256_file "$F515CO_SCENE/victim/keep.txt" > "$F515CO_SCENE/victim.sha.before" || return 1
  : > "$F515CO_SCENE/targets.nul"
}

f515co_targets() {
  local relative
  for relative in "$@"; do
    mkdir -p "$(dirname "$F515CO_PROJECT/$relative")" || return 1
    printf 'PRIVATE_ARTIFACT\n' > "$F515CO_PROJECT/$relative" || return 1
    printf '%s\0' "$relative" >> "$F515CO_SCENE/targets.nul" || return 1
  done
}

f515co_collect() {
  printf '%s\n' "$1" > "$F515CO_SCENE/action.zsh" || return 1
  local wrapper_status=0 project_after="$F515CO_PROJECT"
  if [[ "${2:-core}" == standalone ]]; then
    ZSH_CUSTOM="$TEST_SUITE_ROOT" "$F515CO_ZSH" -f "$F515CO_PROGRAM" \
      > "$F515CO_SCENE/wrapper.stdout" 2> "$F515CO_SCENE/wrapper.stderr" < /dev/null || wrapper_status=$?
  else
    run_zsh 'builtin source "$F515CO_PROGRAM"' \
      > "$F515CO_SCENE/wrapper.stdout" 2> "$F515CO_SCENE/wrapper.stderr" || wrapper_status=$?
  fi
  printf '%s\n' "$wrapper_status" > "$F515CO_SCENE/wrapper.status" || return 1
  [[ ! -d "$F515CO_SCENE/moved" ]] || project_after="$F515CO_SCENE/moved"
  file_identity "$project_after/keep.txt" > "$F515CO_SCENE/canary.identity.after" || return 1
  sha256_file "$project_after/keep.txt" > "$F515CO_SCENE/canary.sha.after" || return 1
  file_identity "$F515CO_SCENE/victim/keep.txt" > "$F515CO_SCENE/victim.identity.after" || return 1
  sha256_file "$F515CO_SCENE/victim/keep.txt" > "$F515CO_SCENE/victim.sha.after" || return 1
  if [[ -d "$F515CO_PROJECT/blocked" && ! -L "$F515CO_PROJECT/blocked" ]]; then
    file_stat "$F515CO_PROJECT/blocked" mode uid gid device inode > "$F515CO_SCENE/blocked.after" || return 1
  fi
}

f515co_scalar() {
  [[ -f "$1" && ! -L "$1" ]] || return 80
  printf '%s\n' "$2" > "$1.expected" || return 80
  cmp "$1.expected" "$1" || return 80
}

f515co_primary() {
  local scene="$F515CO_ROOT/$1" stem
  f515co_scalar "$scene/wrapper.status" 0 || return 81
  f515co_scalar "$scene/primary.status" "$2" || return 81
  f515co_scalar "$scene/public.post-return" "$2" || return 81
  f515co_scalar "$scene/auto-yes.after" 0 || return 81
  for stem in primary.stdout wrapper.stdout wrapper.stderr; do
    [[ -f "$scene/$stem" && ! -L "$scene/$stem" && ! -s "$scene/$stem" ]] || return 82
  done
  [[ -f "$scene/primary.stderr" && ! -L "$scene/primary.stderr" && -s "$scene/primary.stderr" ]] || return 82
  for stem in canary.identity canary.sha victim.identity victim.sha; do
    cmp "$scene/$stem.before" "$scene/$stem.after" || return 83
  done
}

# Compare the complete visible plan with the observed frozen plan and an
# independently created file set. This does not assume find enumeration order.
f515co_plan() {
  local scene="$F515CO_ROOT/$1" count="$2" item wanted found index=0 offset
  local -a fields=() targets=() expected_targets=()
  f515co_scalar "$scene/plan.post-return" 0 || return 84
  while IFS= read -r -d '' item; do fields+=("$item"); done < "$scene/plan.records.nul"
  [[ -z "$item" && "${#fields[@]}" -eq $((count * 4)) ]] || return 84
  while IFS= read -r -d '' item; do expected_targets+=("$item"); done < "$scene/targets.nul"
  [[ -z "$item" && "${#expected_targets[@]}" -eq "$count" ]] || return 84
  : > "$scene/plan.expected.tsv"
  for ((offset=0; offset<${#fields[@]}; offset+=4)); do
    item=${fields[$offset]}
    [[ ${fields[$((offset + 1))]} =~ ^[0-9]+$ && ${fields[$((offset + 2))]} =~ ^[0-9]+$ \
      && ${fields[$((offset + 3))]} == file ]] || return 84
    found=0
    for wanted in "${expected_targets[@]}"; do [[ "$item" != "$wanted" ]] || found=$((found + 1)); done
    [[ "$found" == 1 ]] || return 84
    for wanted in "${targets[@]}"; do [[ "$item" != "$wanted" ]] || return 84; done
    targets+=("$item")
    index=$((index + 1))
    printf '%s\tfile\t~/f515-cleanup/%s/project/%s\n' "$index" "$1" "$item" >> "$scene/plan.expected.tsv" || return 84
  done
  awk '$1 ~ /^[0-9]+$/ && $2 == "file" { print $1 "\t" $2 "\t" $3 }' \
    "$scene/primary.stderr" > "$scene/plan.actual.tsv" || return 84
  cmp "$scene/plan.expected.tsv" "$scene/plan.actual.tsv" || return 84
  grep -Eq '^  # +Type +Target$' "$scene/primary.stderr" || return 84
  local project_facts
  project_facts=$(grep -Ec '^  Project:' "$scene/primary.stderr") || return 84
  [[ "$project_facts" == 1 ]] || return 84
  if grep -Fq "$HOME" "$scene/primary.stderr"; then return 84; fi
}

f515co_results() {
  local scene="$F515CO_ROOT/$1" index=0 relative outcome
  shift
  : > "$scene/results.expected.tsv"
  local -a fields=()
  while IFS= read -r -d '' relative; do fields+=("$relative"); done < "$scene/plan.records.nul"
  [[ -z "$relative" && ${#fields[@]} -eq $(($# * 4)) ]] || return 85
  index=0
  for outcome in "$@"; do
    relative=${fields[$((index * 4))]}
    index=$((index + 1))
    printf '%s\t%s\t~/f515-cleanup/%s/project/%s\n' "$index" "$outcome" "${scene##*/}" "$relative" \
      >> "$scene/results.expected.tsv" || return 85
  done
  awk '$1 ~ /^[0-9]+$/ { n=2; if ($n == "✔" || $n == "✘" || $n == "⊘" || $n == "–") n++;
    if ($n == "done" || $n == "skipped" || $n == "failed" || $n == "blocked" || $n == "not") {
      word=$n; n++; if (word == "not") { if ($n != "run") next; word="not-run"; n++ }
      print $1 "\t" word "\t" $n
    }}' "$scene/primary.stderr" > "$scene/results.actual.tsv" || return 85
  cmp "$scene/results.expected.tsv" "$scene/results.actual.tsv" || return 85
}

f515co_rm() {
  local scene="$F515CO_ROOT/$1" call="$2" relative="$3" expected="$4"
  f515co_scalar "$scene/rm/$call.native.selected" "$F515CO_REAL_RM" || return 86
  f515co_scalar "$scene/rm/$call.native.post-return" "$expected" || return 86
  printf '%s\0' "$TEST_MOCK_BIN/rm" -f -- "$relative" > "$scene/rm/$call.expected.nul" || return 86
  cmp "$scene/rm/$call.expected.nul" "$scene/rm/$call.argv.nul" || return 86
  [[ -f "$scene/rm/$call.native.stdout" && ! -s "$scene/rm/$call.native.stdout" ]] || return 86
  [[ -f "$scene/rm/$call.native.stderr" ]] || return 86
}

@test "dev cleanup output: exact dry run decline and counted success or partial verdicts" {
  local name mode relative call observed outcome
  for name in dry no success partial all-failed; do
    f515co_scene "$name" || return 1
    if [[ "$name" == partial ]]; then
      f515co_targets blocked/a.pyc b.pyc || return 1
    elif [[ "$name" == all-failed ]]; then
      f515co_targets blocked/a.pyc blocked/b.pyc || return 1
    else
      f515co_targets a.pyc b.pyc || return 1
    fi
    if [[ "$name" == partial || "$name" == all-failed ]]; then
      chmod -- 500 "$F515CO_PROJECT/blocked" || return 1
      file_identity "$F515CO_PROJECT/blocked" > "$F515CO_SCENE/blocked.identity.before" || return 1
      file_stat "$F515CO_PROJECT/blocked" mode uid gid device inode > "$F515CO_SCENE/blocked.before" || return 1
    fi
    case "$name" in
      dry) f515co_collect 'dev-clean-py --dry-run' || return 1 ;;
      no) F515CO_ASK_RC=1 f515co_collect 'dev-clean-py' || return 1 ;;
      *) f515co_collect '_dev_timed dev:dev-clean-py dev-clean-py --yes' || return 1 ;;
    esac
  done
  for name in dry no success partial all-failed; do
    observed=0
    [[ "$name" != partial && "$name" != all-failed ]] || observed=1
    f515co_primary "$name" "$observed" || return 1
    f515co_plan "$name" 2 || return 1
    case "$name" in
      dry|no)
        [[ ! -e "$F515CO_ROOT/$name/rm/count" && ! -L "$F515CO_ROOT/$name/rm/count" ]] || return 1
        [[ -f "$F515CO_ROOT/$name/project/a.pyc" && -f "$F515CO_ROOT/$name/project/b.pyc" ]] || return 1
        if [[ "$name" == dry ]]; then
          grep -Fq 'Dry run: 2 targets planned; nothing was removed.' "$F515CO_ROOT/$name/primary.stderr" || return 1
          [[ ! -e "$F515CO_ROOT/$name/confirm.post-return" ]] || return 1
        else
          f515co_scalar "$F515CO_ROOT/$name/confirm.post-return" 1 || return 1
          grep -Fq 'Cancelled: nothing was removed.' "$F515CO_ROOT/$name/primary.stderr" || return 1
        fi
        ;;
      *)
        f515co_scalar "$F515CO_ROOT/$name/rm/count" 2 || return 1
        call=0
        local -a outcomes=() records=()
        while IFS= read -r -d '' relative; do records+=("$relative"); done < "$F515CO_ROOT/$name/plan.records.nul"
        for ((mode=0; mode<${#records[@]}; mode+=4)); do
          relative=${records[$mode]}; call=$((call + 1)); observed=0; outcome=done
          if [[ "$relative" == blocked/* ]]; then observed=1; outcome=failed; fi
          f515co_rm "$name" "$call" "$relative" "$observed" || return 1
          outcomes+=("$outcome")
        done
        f515co_results "$name" "${outcomes[@]}" || return 1
        if [[ "$name" == success ]]; then
          [[ ! -e "$F515CO_ROOT/$name/project/a.pyc" && ! -L "$F515CO_ROOT/$name/project/a.pyc" \
            && ! -e "$F515CO_ROOT/$name/project/b.pyc" && ! -L "$F515CO_ROOT/$name/project/b.pyc" ]] || return 1
          grep -Fq 'Cleanup completed: 2 targets removed.' "$F515CO_ROOT/$name/primary.stderr" || return 1
        elif [[ "$name" == partial ]]; then
          [[ -f "$F515CO_ROOT/$name/project/blocked/a.pyc" \
            && ! -e "$F515CO_ROOT/$name/project/b.pyc" && ! -L "$F515CO_ROOT/$name/project/b.pyc" ]] || return 1
          cmp "$F515CO_ROOT/$name/blocked.before" "$F515CO_ROOT/$name/blocked.after" || return 1
          grep -Fq 'Cleanup completed with partial failures: 1 of 2 targets failed.' "$F515CO_ROOT/$name/primary.stderr" || return 1
          grep -Fq 'dev:dev-clean-py completed with partial failures' "$F515CO_ROOT/$name/primary.stderr" || return 1
        else
          [[ -f "$F515CO_ROOT/$name/project/blocked/a.pyc" && -f "$F515CO_ROOT/$name/project/blocked/b.pyc" ]] || return 1
          cmp "$F515CO_ROOT/$name/blocked.before" "$F515CO_ROOT/$name/blocked.after" || return 1
          grep -Fq 'Cleanup failed: 2 of 2 targets failed.' "$F515CO_ROOT/$name/primary.stderr" || return 1
          if grep -Fq 'completed with partial failures' "$F515CO_ROOT/$name/primary.stderr"; then return 1; fi
        fi
        ;;
    esac
  done
}

@test "dev cleanup output: the numbered reviewed plan includes every target beyond twenty five" {
  f515co_scene complete || return 1
  local index relative
  for ((index=1; index<=26; index++)); do
    printf -v relative 'item%02d.pyc' "$index"
    f515co_targets "$relative" || return 1
  done
  f515co_collect 'dev-clean-py --dry-run' || return 1
  f515co_primary complete 0 || return 1
  f515co_plan complete 26 || return 1
  grep -Fq 'Dry run: 26 targets planned; nothing was removed.' "$F515CO_SCENE/primary.stderr" || return 1
  [[ ! -e "$F515CO_SCENE/rm/count" && ! -e "$F515CO_SCENE/confirm.post-return" ]] || return 1
  for ((index=1; index<=26; index++)); do
    printf -v relative 'item%02d.pyc' "$index"
    [[ -f "$F515CO_PROJECT/$relative" ]] || return 1
  done
}

@test "dev cleanup output: display quoting abbreviates only HOME and preserves literal removal argv" {
  local name context relative call count pattern
  local -a files=('space name.pyc' $'tab\tname.pyc' 'tab\tname.pyc' $'line\nname\\tail.pyc')
  for name in display-core display-standalone neighbor; do
    f515co_scene "$name" || return 1
    if [[ "$name" == neighbor ]]; then
      F515CO_PROJECT="$HOME-neighbor/project"
      export F515CO_PROJECT
      mkdir -p "$F515CO_PROJECT" || return 1
      printf 'PROJECT_CANARY\n' > "$F515CO_PROJECT/keep.txt" || return 1
      file_identity "$F515CO_PROJECT/keep.txt" > "$F515CO_SCENE/canary.identity.before" || return 1
      sha256_file "$F515CO_PROJECT/keep.txt" > "$F515CO_SCENE/canary.sha.before" || return 1
    fi
    f515co_targets "${files[@]}" || return 1
    context=core
    [[ "$name" != display-standalone ]] || context=standalone
    f515co_collect 'dev-clean-py --yes' "$context" || return 1
  done
  for name in display-core display-standalone neighbor; do
    f515co_primary "$name" 0 || return 1
    f515co_scalar "$F515CO_ROOT/$name/rm/count" 4 || return 1
    if [[ "$name" == display-standalone ]]; then
      f515co_scalar "$F515CO_ROOT/$name/services" 0:0 || return 1
    else
      f515co_scalar "$F515CO_ROOT/$name/services" 1:1 || return 1
    fi
    for ((call=1; call<=4; call++)); do
      pattern="$F515CO_ROOT/$name/display.$call.expected"
      [[ -f "$pattern" && ! -L "$pattern" && -s "$pattern" ]] || return 1
      count=$(grep -F -c -f "$pattern" "$F515CO_ROOT/$name/primary.stderr") || return 1
      [[ "$count" == 2 ]] || return 1
    done
    if LC_ALL=C grep -q $'\t' "$F515CO_ROOT/$name/primary.stderr" \
      || LC_ALL=C grep -q $'\033' "$F515CO_ROOT/$name/primary.stderr"; then return 1; fi
    call=0
    local -a records=()
    while IFS= read -r -d '' relative; do records+=("$relative"); done < "$F515CO_ROOT/$name/plan.records.nul"
    [[ ${#records[@]} -eq 16 ]] || return 1
    for ((context=0; context<${#records[@]}; context+=4)); do
      call=$((call + 1))
      f515co_rm "$name" "$call" "${records[$context]}" 0 || return 1
    done
    local project="$F515CO_ROOT/$name/project"
    [[ "$name" != neighbor ]] || project="$HOME-neighbor/project"
    for relative in "${files[@]}"; do
      [[ ! -e "$project/$relative" && ! -L "$project/$relative" ]] || return 1
    done
    grep -Fq 'Cleanup completed: 4 targets removed.' "$F515CO_ROOT/$name/primary.stderr" || return 1
  done
}

@test "dev cleanup output: absent targets and stopped root leases keep ordered honest outcomes" {
  local name
  for name in noop absent before after; do
    f515co_scene "$name" || return 1
    [[ "$name" == noop ]] || f515co_targets a.pyc b.pyc || return 1
    case "$name" in
      noop) f515co_collect 'dev-clean-py' || return 1 ;;
      absent) F515CO_MODE=absent f515co_collect 'dev-clean-py' || return 1 ;;
      before) F515CO_MODE=swap-before f515co_collect 'dev-clean-py' || return 1 ;;
      after) F515CO_RM_MODE=swap-after-first f515co_collect 'dev-clean-py --yes' || return 1 ;;
    esac
  done
  f515co_primary noop 0 || return 1
  grep -Fq 'Nothing to clean' "$F515CO_ROOT/noop/primary.stderr" || return 1
  [[ ! -e "$F515CO_ROOT/noop/confirm.post-return" && ! -e "$F515CO_ROOT/noop/rm/count" ]] || return 1
  f515co_primary absent 0 || return 1
  f515co_plan absent 2 || return 1
  f515co_scalar "$F515CO_ROOT/absent/confirm.rm.post-return" 0 || return 1
  f515co_scalar "$F515CO_ROOT/absent/rm/count" 1 || return 1
  f515co_rm absent 1 b.pyc 0 || return 1
  [[ ! -e "$F515CO_ROOT/absent/project/a.pyc" && ! -L "$F515CO_ROOT/absent/project/a.pyc" \
    && ! -e "$F515CO_ROOT/absent/project/b.pyc" && ! -L "$F515CO_ROOT/absent/project/b.pyc" ]] || return 1
  local -a fields=() outcomes=()
  local field index
  while IFS= read -r -d '' field; do fields+=("$field"); done < "$F515CO_ROOT/absent/plan.records.nul"
  for ((index=0; index<${#fields[@]}; index+=4)); do
    if [[ "${fields[$index]}" == a.pyc ]]; then outcomes+=(skipped); else outcomes+=(done); fi
  done
  f515co_results absent "${outcomes[@]}" || return 1
  grep -Fq 'Cleanup completed: 1 target removed.' "$F515CO_ROOT/absent/primary.stderr" || return 1
  for name in before after; do
    f515co_primary "$name" 1 || return 1
    f515co_plan "$name" 2 || return 1
    [[ -L "$F515CO_ROOT/$name/project" && -d "$F515CO_ROOT/$name/moved" ]] || return 1
    if [[ "$name" == before ]]; then
      [[ ! -e "$F515CO_ROOT/$name/rm/count" ]] || return 1
      [[ -f "$F515CO_ROOT/$name/moved/a.pyc" && -f "$F515CO_ROOT/$name/moved/b.pyc" ]] || return 1
      f515co_results before not-run not-run || return 1
      grep -Fq 'root' "$F515CO_ROOT/$name/primary.stderr" || return 1
      if grep -Fq '0 of 2 targets failed.' "$F515CO_ROOT/$name/primary.stderr"; then return 1; fi
    else
      f515co_scalar "$F515CO_ROOT/$name/rm/count" 1 || return 1
      f515co_scalar "$F515CO_ROOT/$name/swap.mv.post-return" 0 || return 1
      f515co_scalar "$F515CO_ROOT/$name/swap.ln.post-return" 0 || return 1
      fields=()
      while IFS= read -r -d '' field; do fields+=("$field"); done < "$F515CO_ROOT/$name/plan.records.nul"
      f515co_rm after 1 "${fields[0]}" 0 || return 1
      [[ ! -e "$F515CO_ROOT/$name/moved/${fields[0]}" && ! -L "$F515CO_ROOT/$name/moved/${fields[0]}" \
        && -f "$F515CO_ROOT/$name/moved/${fields[4]}" ]] || return 1
      f515co_results after failed not-run || return 1
      grep -Fq 'removal completed' "$F515CO_ROOT/$name/primary.stderr" || return 1
      grep -Fq 'root' "$F515CO_ROOT/$name/primary.stderr" || return 1
    fi
  done
}
