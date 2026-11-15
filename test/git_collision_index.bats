#!/usr/bin/env bats
# GIT-017 collision semantics, observer qualification and public inventory.
# Input sizes below are proposed fixture sizes, never observed step counts.
# The additive operation allowance was frozen against the unchanged base.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  export F504_REAL_GIT
  F504_REAL_GIT=$(type -P git)
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=0 GIT_TERMINAL_PROMPT=0
  export GIT_ALLOW_PROTOCOL=file GIT_PAGER=cat PAGER=cat TERM=dumb NO_COLOR=1
  export GIT_AUTHOR_NAME='Collision Index Test'
  export GIT_AUTHOR_EMAIL='collision-index@example.invalid'
  export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
  export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
  export F504_CASE="$HOME/collision-case"
  mkdir -p "$F504_CASE"
}

teardown() {
  cleanup_sandbox
}

# Test-local artifact/counter support only. Isolation, interpreter launch,
# metadata, temporary roots and cleanup come from the existing harness.
f504_support_program() {
  cat <<'ZSH'
emulate -R zsh
source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
cd "$HOME" || return 91

_f504_save_array() {
  emulate -L zsh
  local destination="$1"
  local -a values=("${(@P)2}")
  if (( ${#values[@]} > 0 )); then
    printf '%s\0' "${values[@]}" >"$destination"
  else
    : >"$destination"
  fi
}

_f504_direct_case() {
  emulate -L zsh
  local label="$1"
  local -a reply=("stale prior reply")
  local -i helper_rc=0
  _git_path_collisions "$2" "$3" "$4" \
    >"$F504_CASE/$label.stdout" 2>"$F504_CASE/$label.stderr" || helper_rc=$?
  print -r -- "$helper_rc" >"$F504_CASE/$label.primary.status" || return 91
  print -r -- "${6:-0}" >"$F504_CASE/$label.expected.primary.status" || return 91
  _f504_save_array "$F504_CASE/$label.actual.nul" reply || return 92
  _f504_save_array "$F504_CASE/$label.expected.nul" "$5" || return 93
  print -r -- "$label" >>"$F504_CASE/direct.labels" || return 94
  return 0
}

# A proposal requiring positive runtime qualification BEFORE its counts can
# support a complexity bound. No source-command/variable-name matching.
_f504_measure() {
  emulate -L zsh
  local label="$1"
  local -a reply=("stale prior reply") measured_reply=()
  local -i helper_rc=0 outside_before=0 outside_after=0 outside_probe=0
  (( ! ${+functions[TRAPDEBUG]} )) || return 94
  typeset -gi F504_DEBUG_STEPS=0
  {
    TRAPDEBUG() {
      if (( ${funcstack[(Ie)_git_path_collisions]} > 0 )); then
        (( ++F504_DEBUG_STEPS ))
      fi
      return 0
    }
    # These operations occur with the observer installed, outside the helper.
    outside_before=$F504_DEBUG_STEPS
    :
    (( ++outside_probe ))
    outside_after=$F504_DEBUG_STEPS
    _git_path_collisions "$2" "$3" "$4" \
      >"$F504_CASE/$label.stdout" 2>"$F504_CASE/$label.stderr" || helper_rc=$?
    measured_reply=("${reply[@]}")
  } always {
    unfunction TRAPDEBUG
  }
  (( ! ${+functions[TRAPDEBUG]} )) || return 95
  print -r -- "$helper_rc" >"$F504_CASE/$label.primary.status" || return 98
  print -r -- "${6:-0}" >"$F504_CASE/$label.expected.primary.status" || return 98
  print -r -- "$F504_DEBUG_STEPS" >"$F504_CASE/$label.steps" || return 98
  print -r -- "$(( outside_after - outside_before ))" >"$F504_CASE/$label.outside-delta" || return 98
  _f504_save_array "$F504_CASE/$label.actual.nul" measured_reply || return 96
  _f504_save_array "$F504_CASE/$label.expected.nul" "$5" || return 97
  print -r -- "$label" >>"$F504_CASE/measured.labels" || return 99
  return 0
}

# Record fixed input work before installing the observer. Paths in the
# measurement families are ASCII, so the character total is also a byte total.
_f504_record_input_work() {
  emulate -L zsh
  local label="$1" path_value=""
  local -a candidates=("${(@P)2}") targets=("${(@P)3}") components=()
  local -i component_count=0 pathname_bytes=0
  for path_value in "${candidates[@]}" "${targets[@]}"; do
    components=("${(@s:/:)path_value}")
    (( component_count += ${#components[@]} ))
    (( pathname_bytes += ${#path_value} ))
  done
  printf '%s\t%d\t%d\t%d\t%d\n' "$label" "${#candidates[@]}" \
    "${#targets[@]}" "$component_count" "$pathname_bytes" \
    >>"$F504_CASE/input-work.tsv" || return 100
  return 0
}
ZSH
}

# The observer return and actual Zsh program primary are separate evidence.
f504_execute_program() {
  local primary=0
  run_zsh "$1" > "$F504_CASE/program.stdout" 2> "$F504_CASE/program.stderr" || primary=$?
  printf '%s\n' "$primary" > "$F504_CASE/program.primary.status" || return 1
  return 0
}

f504_assert_artifacts() {
  local labels_file="$1" label actual_status expected_status total=0
  [ -s "$labels_file" ] || return 10
  while IFS= read -r label; do
    [ -n "$label" ] || return 19
    total=$((total + 1))
    actual_status=$(cat "$F504_CASE/$label.primary.status") || return 11
    expected_status=$(cat "$F504_CASE/$label.expected.primary.status") || return 15
    [[ "$actual_status" =~ ^[0-9]+$ ]] || return 16
    [[ "$expected_status" =~ ^[0-9]+$ ]] || return 17
    [ "$actual_status" -eq "$expected_status" ] || return 18
    [ -f "$F504_CASE/$label.stdout" ] || return 20
    [ ! -s "$F504_CASE/$label.stdout" ] || return 12
    [ -f "$F504_CASE/$label.stderr" ] || return 21
    [ ! -s "$F504_CASE/$label.stderr" ] || return 13
    cmp "$F504_CASE/$label.expected.nul" "$F504_CASE/$label.actual.nul" || return 14
  done <"$labels_file"
  [ -z "$label" ] || return 22
  [ "$total" -gt 0 ] || return 23
  return 0
}

# Independent fixture arithmetic: no product result, collector output or step
# count feeds these expected cardinalities/component totals/ASCII byte totals.
f504_digit_total() {
  local limit="$1" value total=0
  for ((value=1; value<=limit; ++value)); do
    total=$((total + ${#value}))
  done
  printf '%s\n' "$total" || return 1
}

f504_assert_input_work() {
  local name c t components bytes extra digits64 digits128 depth prefix_bytes
  local digits_depth expected_count=0
  digits64=$(f504_digit_total 64) || return 1
  digits128=$(f504_digit_total 128) || return 2
  : > "$F504_CASE/input-work.expected.tsv" || return 3
  for name in shallow-n-n shallow-2n-n shallow-n-2n shallow-2n-2n; do
    case "$name" in
      shallow-n-n) c=64; t=64; bytes=$((15*c + 12*t + 2*digits64)) ;;
      shallow-2n-n) c=128; t=64; bytes=$((15*c + 12*t + digits128 + digits64)) ;;
      shallow-n-2n) c=64; t=128; bytes=$((15*c + 12*t + digits64 + digits128)) ;;
      shallow-2n-2n) c=128; t=128; bytes=$((15*c + 12*t + 2*digits128)) ;;
    esac
    printf '%s\t%d\t%d\t%d\t%d\n' "$name" "$c" "$t" "$((2*(c+t)))" "$bytes" \
      >> "$F504_CASE/input-work.expected.tsv" || return 4
  done
  for depth in 16 32 64; do
    digits_depth=$(f504_digit_total "$depth") || return 5
    prefix_bytes=$((4 + 6*depth + digits_depth))
    bytes=$((128*prefix_bytes + 64*19 + 2*digits64))
    printf 'deep-%d\t64\t64\t%d\t%d\n' "$depth" "$((128*(depth+2)))" "$bytes" \
      >> "$F504_CASE/input-work.expected.tsv" || return 6
  done
  for c in 64 128; do
    digits_depth=$(f504_digit_total "$c") || return 7
    printf 'unique-%d\t%d\t1\t%d\t%d\n' "$c" "$((2*c))" "$((4*c+1))" \
      "$((2*(12*c+digits_depth)+4))" >> "$F504_CASE/input-work.expected.tsv" || return 8
  done
  [ -s "$F504_CASE/input-work.tsv" ] || return 9
  while IFS=$'\t' read -r name c t components bytes extra; do
    [[ -n "$name" && -z "$extra" ]] || return 10
    [[ "$c" =~ ^[0-9]+$ && "$t" =~ ^[0-9]+$ ]] || return 11
    [[ "$components" =~ ^[0-9]+$ && "$bytes" =~ ^[0-9]+$ ]] || return 12
    [ "$c" -gt 0 ] || return 13
    [ "$t" -gt 0 ] || return 14
    [ "$components" -gt 0 ] || return 15
    [ "$bytes" -gt 0 ] || return 16
    expected_count=$((expected_count + 1))
  done < "$F504_CASE/input-work.tsv"
  [ "$expected_count" -eq 9 ] || return 17
  cmp "$F504_CASE/input-work.expected.tsv" "$F504_CASE/input-work.tsv" || return 18
  cut -f1 "$F504_CASE/input-work.expected.tsv" > "$F504_CASE/measurement-labels.expected" || return 19
  cmp "$F504_CASE/measurement-labels.expected" "$F504_CASE/measured.labels" || return 20
  return 0
}

f504_assert_additive_bound() {
  local label c t components bytes steps work allowance rows=0 failures=0
  : > "$F504_CASE/additive-bound.tsv" || return 1
  while IFS=$'\t' read -r label c t components bytes; do
    case "$label" in shallow-*) ;; *) continue ;; esac
    steps=$(cat "$F504_CASE/$label.steps") || return 2
    [[ "$steps" =~ ^[0-9]+$ ]] || return 3
    work=$((1 + c + t + components))
    # Frozen before changing the helper; allow constant work per component.
    allowance=$((256 + 16*work))
    printf '%s\t%d\t%d\t%d\n' "$label" "$steps" "$work" "$allowance" \
      >> "$F504_CASE/additive-bound.tsv" || return 4
    rows=$((rows + 1))
    if [ "$steps" -gt "$allowance" ]; then failures=$((failures + 1)); fi
  done < "$F504_CASE/input-work.tsv"
  [ "$rows" -eq 4 ] || return 5
  [ "$failures" -eq 0 ] || return 6
  return 0
}

@test "git collision index: direct collision table preserves exact semantics, order and case policy" {
  local program
  program=$(cat <<'ZSH'
emulate -R zsh
local -a candidates=() targets=() expected=()
candidates=(alpha); targets=(alpha); expected=(alpha)
_f504_direct_case equality candidates targets no expected || return 10
candidates=(a/b/c a2/b); targets=(a); expected=(a/b/c)
_f504_direct_case candidate-below candidates targets no expected || return 11
candidates=(a a2); targets=(a/b/c); expected=(a)
_f504_direct_case candidate-above candidates targets no expected || return 12
candidates=(doc docs2 docs/item topical/x); targets=(docs topic/file); expected=(docs/item)
_f504_direct_case slash-boundary candidates targets no expected || return 13
candidates=(docs/ docs docs/ / ""); targets=(docs/a); expected=(docs)
_f504_direct_case directory-marker candidates targets no expected || return 14
candidates=(third/file first third/file/ second first third/file)
targets=(first second/x third third); expected=(third/file first second)
_f504_direct_case order-and-dedup candidates targets no expected || return 15
candidates=(Notes.TXT notes.txt); targets=(notes.txt); expected=(notes.txt)
_f504_direct_case case-sensitive candidates targets no expected || return 16
candidates=(Notes.TXT notes.txt notes.txt/ NOTES.txt)
targets=(notes.txt NOTES.TXT); expected=(Notes.TXT notes.txt NOTES.txt)
_f504_direct_case case-folded candidates targets yes expected || return 17
candidates=(FOO foo); targets=(foo); expected=(foo)
_f504_direct_case only-exact-yes-folds candidates targets YES expected || return 18
candidates=(match absent); targets=(match); expected=(match)
_f504_direct_case match-then-miss candidates targets no expected || return 19
candidates=(candidate); targets=(different); expected=()
_f504_direct_case no-matches-clears-reply candidates targets no expected || return 20
candidates=(); targets=(target); expected=()
_f504_direct_case empty-candidates candidates targets no expected || return 21
candidates=(candidate); targets=(); expected=()
_f504_direct_case empty-targets candidates targets no expected || return 22
candidates=(); targets=(); expected=()
_f504_direct_case both-empty candidates targets no expected || return 23
ZSH
)
  run f504_execute_program "$(f504_support_program)"$'\n'"$program"
  [ "$status" -eq 0 ]
  [ "$(cat "$F504_CASE/program.primary.status")" -eq 0 ]
  [ ! -s "$F504_CASE/program.stdout" ]
  [ ! -s "$F504_CASE/program.stderr" ]
  [ "$(wc -l <"$F504_CASE/direct.labels")" -eq 14 ]
  f504_assert_artifacts "$F504_CASE/direct.labels"
}

@test "git collision index: metacharacters and control characters stay literal data" {
  local program
  program=$(cat <<'ZSH'
emulate -R zsh
local -a candidates=(
  'alpha*' alpha1 'x[12]' x1 'space name' 'back\slash'
  "quote'and\"double" '$(touch .f504-executed)' '-leading-dash'
  $'tab\tname' $'line\nname' 'café.txt'
)
local -a targets=(
  'alpha*' 'x[12]' 'space name' 'back\slash'
  "quote'and\"double" '$(touch .f504-executed)' '-leading-dash'
  $'tab\tname' $'line\nname' 'café.txt'
)
local -a expected=("${targets[@]}")
_f504_direct_case literal-data candidates targets no expected || return 10
[[ ! -e "$HOME/.f504-executed" ]] || return 11
ZSH
)
  run f504_execute_program "$(f504_support_program)"$'\n'"$program"
  [ "$status" -eq 0 ]
  [ "$(cat "$F504_CASE/program.primary.status")" -eq 0 ]
  [ ! -s "$F504_CASE/program.stdout" ]
  [ ! -s "$F504_CASE/program.stderr" ]
  f504_assert_artifacts "$F504_CASE/direct.labels"
  [ ! -e "$HOME/.f504-executed" ]
}

@test "git collision index: qualify DEBUG observation cleanup refusal and metadata failure" {
  local program
  program=$(cat <<'ZSH'
emulate -R zsh
local -a candidates=(a/b) targets=(a) expected=(a/b)
_f504_direct_case unobserved-match candidates targets no expected || return 10
_f504_measure observed-match candidates targets no expected || return 11
candidates=(different); expected=()
_f504_direct_case unobserved-miss candidates targets no expected || return 12
_f504_measure observed-miss candidates targets no expected || return 13
candidates=(); targets=(); expected=()
_f504_direct_case unobserved-empty candidates targets no expected || return 14
_f504_measure observed-empty candidates targets no expected || return 15
(( ! ${+functions[TRAPDEBUG]} )) || return 16

# A failure from this private qualification wrapper is NOT a product finding.
# Run the real helper, preserve its full reply, then return an ordinary17.
# Both observed/unobserved calls must retain17 and always cleanup the observer.
(( ! ${+functions[_f504_failure_original]} )) || return 17
functions[_f504_failure_original]="${functions[_git_path_collisions]}"
{
  _git_path_collisions() {
    _f504_failure_original "$@" || return $?
    return 17
  }
  candidates=(a/b); targets=(a); expected=(a/b)
  _f504_direct_case unobserved-failed candidates targets no expected 17 || return 18
  _f504_measure observed-failed candidates targets no expected 17 || return 19
  print -r -- "${+functions[TRAPDEBUG]}" > "$F504_CASE/debug.after-failed" || return 20
} always {
  functions[_git_path_collisions]="${functions[_f504_failure_original]}"
  unfunction _f504_failure_original
}
(( ! ${+functions[TRAPDEBUG]} )) || return 21

# Refuse a caller's existing observer without replacing/removing its body.
local -i refused_rc=0
TRAPDEBUG() { return 0; }
{
  print -r -- "${functions[TRAPDEBUG]}" > "$F504_CASE/debug.existing.before" || return 22
  _f504_measure refused-existing candidates targets no expected || refused_rc=$?
  print -r -- "$refused_rc" > "$F504_CASE/debug.refused.primary.status" || return 23
  print -r -- "${functions[TRAPDEBUG]}" > "$F504_CASE/debug.existing.after" || return 24
  (( ${+functions[TRAPDEBUG]} )) || return 25
} always {
  unfunction TRAPDEBUG
}
(( ! ${+functions[TRAPDEBUG]} )) || return 26

# An obstructed append is an observer failure. Do not collect a measurement
# after failed work metadata, and do not mislabel it a complexity red.
local -i work_rc=0
mkdir "$F504_CASE/input-work.tsv" || return 27
_f504_record_input_work refused-work candidates targets \
  > "$F504_CASE/work.refused.stdout" 2> "$F504_CASE/work.refused.stderr" || work_rc=$?
print -r -- "$work_rc" > "$F504_CASE/work.refused.primary.status" || return 28
rmdir "$F504_CASE/input-work.tsv" || return 29
ZSH
)
  run f504_execute_program "$(f504_support_program)"$'\n'"$program"
  [ "$status" -eq 0 ]
  [ "$(cat "$F504_CASE/program.primary.status")" -eq 0 ]
  [ ! -s "$F504_CASE/program.stdout" ]
  [ ! -s "$F504_CASE/program.stderr" ]
  [ "$(wc -l <"$F504_CASE/direct.labels")" -eq 4 ]
  [ "$(wc -l <"$F504_CASE/measured.labels")" -eq 4 ]
  f504_assert_artifacts "$F504_CASE/direct.labels"
  f504_assert_artifacts "$F504_CASE/measured.labels"
  local family
  for family in match miss empty failed; do
    [ "$(cat "$F504_CASE/observed-$family.steps")" -gt 0 ]
    [ "$(cat "$F504_CASE/observed-$family.outside-delta")" -eq 0 ]
    cmp "$F504_CASE/unobserved-$family.actual.nul" "$F504_CASE/observed-$family.actual.nul"
    cmp "$F504_CASE/unobserved-$family.primary.status" "$F504_CASE/observed-$family.primary.status"
  done
  [ "$(cat "$F504_CASE/observed-failed.primary.status")" -eq 17 ]
  [ "$(cat "$F504_CASE/debug.after-failed")" -eq 0 ]
  [ "$(cat "$F504_CASE/debug.refused.primary.status")" -eq 94 ]
  cmp "$F504_CASE/debug.existing.before" "$F504_CASE/debug.existing.after"
  [ ! -e "$F504_CASE/refused-existing.primary.status" ]
  [ "$(cat "$F504_CASE/work.refused.primary.status")" -eq 100 ]
  [ ! -s "$F504_CASE/work.refused.stdout" ]
  [ -s "$F504_CASE/work.refused.stderr" ]
  [ ! -e "$F504_CASE/input-work.tsv" ]
}

@test "git collision index: operation-growth follows the reviewed additive bound" {
  local program
  program=$(cat <<'ZSH'
emulate -R zsh
# Proposed sizes only, subject to actual base qualification/cost review.
local -i n=64 i=0 depth=0 part=0
local -a c1=() c2=() t1=() t2=() candidates=() targets=() expected=()
for (( i=1; i<=2*n; ++i )); do
  c2+=("candidate/file-$i")
  t2+=("target/file-$i")
done
c1=("${(@)c2[1,n]}"); t1=("${(@)t2[1,n]}")
_f504_record_input_work shallow-n-n c1 t1 || return 30
_f504_measure shallow-n-n c1 t1 no expected || return 10
_f504_record_input_work shallow-2n-n c2 t1 || return 31
_f504_measure shallow-2n-n c2 t1 no expected || return 11
_f504_record_input_work shallow-n-2n c1 t2 || return 32
_f504_measure shallow-n-2n c1 t2 no expected || return 12
_f504_record_input_work shallow-2n-2n c2 t2 || return 33
_f504_measure shallow-2n-2n c2 t2 no expected || return 13

local prefix=""
for depth in 16 32 64; do
  prefix=root
  for (( part=1; part<=depth; ++part )); do prefix+="/part-$part"; done
  candidates=(); targets=(); expected=()
  for (( i=1; i<=n; ++i )); do
    candidates+=("$prefix/candidate-$i")
    targets+=("$prefix/target-$i")
  done
  _f504_record_input_work "deep-$depth" candidates targets || return 34
  _f504_measure "deep-$depth" candidates targets no expected || return 14
done

# An output-array scan can hide byte work inside one command; these complete
# result controls complement, rather than replace, structural dedup review.
for n in 64 128; do
  candidates=(); targets=(root)
  for (( i=1; i<=n; ++i )); do candidates+=("root/unique-$i"); done
  expected=("${candidates[@]}")
  candidates+=("${expected[@]}")
  _f504_record_input_work "unique-$n" candidates targets || return 35
  _f504_measure "unique-$n" candidates targets no expected || return 15
done
ZSH
)
  run f504_execute_program "$(f504_support_program)"$'\n'"$program"
  [ "$status" -eq 0 ]
  [ "$(cat "$F504_CASE/program.primary.status")" -eq 0 ]
  [ ! -s "$F504_CASE/program.stdout" ]
  [ ! -s "$F504_CASE/program.stderr" ]
  [ "$(wc -l <"$F504_CASE/measured.labels")" -eq 9 ]
  f504_assert_artifacts "$F504_CASE/measured.labels"
  f504_assert_input_work
  local label
  while IFS= read -r label; do
    [ "$(cat "$F504_CASE/$label.steps")" -gt 0 ]
    [ "$(cat "$F504_CASE/$label.outside-delta")" -eq 0 ]
  done <"$F504_CASE/measured.labels"

  # All four shallow points must pass. Deep/unique semantic controls above
  # complement independent structural review of hidden byte/dedup work.
  f504_assert_additive_bound
}

# All observed calls must contain the independently expected complete arrays.
# Call count is deliberately not fixed: require one or more, unique sequential
# records, then validate every record, including its actual primary/streams.
f504_assert_public_calls() {
  local phase="$1" expected_candidates="$2" expected_count="$3"
  local record c t extra primary expected_record=1 total=0 directory
  local observed_calls ledger_bytes recorded_bytes=0
  [ -s "$F504_CASE/$phase.calls.tsv" ] || return 1
  observed_calls=$(cat "$F504_CASE/$phase.call-count.actual") || return 15
  [[ "$observed_calls" =~ ^[0-9]+$ ]] || return 16
  [ "$observed_calls" -gt 0 ] || return 17
  while IFS=$'\t' read -r record c t extra; do
    [[ "$record" =~ ^[0-9]+$ && -z "$extra" ]] || return 2
    [ "$record" -eq "$expected_record" ] || return 3
    [[ "$c" =~ ^[0-9]+$ && "$t" =~ ^[0-9]+$ ]] || return 4
    [ "$c" -eq "$expected_count" ] || return 5
    [ "$t" -eq 1001 ] || return 6
    directory="$F504_CASE/$phase.calls/$record"
    primary=$(cat "$directory/primary.status") || return 7
    [ "$primary" -eq 0 ] || return 8
    [ -f "$directory/stdout" ] || return 21
    [ ! -s "$directory/stdout" ] || return 9
    [ -f "$directory/stderr" ] || return 22
    [ ! -s "$directory/stderr" ] || return 10
    cmp "$F504_CASE/targets.expected.nul" "$directory/targets.nul" || return 11
    cmp "$expected_candidates" "$directory/candidates.nul" || return 12
    expected_record=$((expected_record + 1))
    total=$((total + 1))
    recorded_bytes=$((recorded_bytes + ${#record} + ${#c} + ${#t} + 3))
  done < "$F504_CASE/$phase.calls.tsv"
  [ "$total" -gt 0 ] || return 13
  [ "$total" -eq "$observed_calls" ] || return 18
  ledger_bytes=$(file_size "$F504_CASE/$phase.calls.tsv") || return 19
  [ "$recorded_bytes" -eq "$ledger_bytes" ] || return 20
  printf '%s\n' "$total" > "$F504_CASE/$phase.call-count.observed" || return 14
  return 0
}

@test "git collision index: public hard-undo dry run preserves complete 1000-by-4000 inventories and payload identities" {
  local program
  program=$(cat <<'ZSH'
emulate -R zsh
zmodload zsh/datetime || return 10
zmodload -F zsh/stat b:zstat || return 11
# Git emits byte-ordered paths; keep independent expected sorting identical
# under both C.UTF-8 and macOS en_US.UTF-8 without changing UTF-8 character use.
export LC_COLLATE=C
local work="$F504_CASE/repository" expected_root="$F504_CASE/payload-bytes"
command git init -q -b main "$work" || return 12
cd "$work" || return 13
command git config core.hooksPath /dev/null || return 14
command git config commit.gpgSign false || return 15
mkdir -p src ignored "$expected_root/src" "$expected_root/ignored" \
  "$F504_CASE/control.calls" "$F504_CASE/large.calls" || return 16
print -r -- 'ignored/' > .gitignore || return 17
print -r -- 'ignored/' > "$expected_root/.gitignore" || return 18
local -i i=0
local -a protected_paths=(.gitignore) ignored_paths=() payload_paths=() empty=()
for (( i=1; i<=1000; ++i )); do
  print -r -- "$i" > "src/file$i.txt" || return 19
  print -r -- "$i" > "$expected_root/src/file$i.txt" || return 20
  protected_paths+=("src/file$i.txt")
done
command git add -A || return 21
command git commit -q -m base || return 22
print -r -- change > src/file1.txt || return 23
print -r -- change > "$expected_root/src/file1.txt" || return 24
command git commit -qam second || return 25

# Expected names come from literal fixture data, independently of the helper
# and Git inventory. Sorting only these fixed ASCII expected names matches
# Git's discovery order; no observed input/result is sorted or deduplicated.
protected_paths=("${(@o)protected_paths}")
(( ${#protected_paths[@]} == 1001 )) || return 26
_f504_save_array "$F504_CASE/targets.expected.nul" protected_paths || return 27
_f504_save_array "$F504_CASE/control.candidates.expected.nul" empty || return 28
command git ls-tree -r -z --name-only HEAD^ > "$F504_CASE/parent-tree.actual.nul" || return 29
command cmp -- "$F504_CASE/targets.expected.nul" "$F504_CASE/parent-tree.actual.nul" || return 30
_git_require_git || return 31

# Use the documented portable Zsh stat builtin already used by the harness;
# no shell per pathname, new metadata observer, directory walk or timed work.
# lstat identity, type/mode, ownership, links and size are compared per payload.
# cmp binds exact bytes against separately written fixture data, including LF.
_f504_capture_public_state() {
  emulate -L zsh
  local stage="$1" moment="$2" path_value
  local -a checked_paths=("${(@P)3}")
  local -A path_state=()
  command git rev-parse HEAD > "$F504_CASE/$stage.head.$moment" || return 90
  command git symbolic-ref --quiet HEAD > "$F504_CASE/$stage.symbolic.$moment" || return 91
  command git ls-files --stage -z > "$F504_CASE/$stage.index.$moment.nul" || return 92
  : > "$F504_CASE/$stage.payload.$moment.nul" || return 93
  for path_value in "${checked_paths[@]}"; do
    [[ -f "$path_value" && ! -L "$path_value" ]] || return 94
    path_state=()
    zstat -LH path_state -- "$path_value" || return 95
    command cmp -- "$expected_root/$path_value" "$path_value" || return 96
    printf '%s\0%s:%s:%s:%s:%s:%s:%s\0' "$path_value" \
      "${path_state[device]}" "${path_state[inode]}" "${path_state[mode]}" \
      "${path_state[uid]}" "${path_state[gid]}" "${path_state[nlink]}" \
      "${path_state[size]}" >> "$F504_CASE/$stage.payload.$moment.nul" || return 97
  done
  _f504_save_array "$F504_CASE/$stage.payload-checked.$moment.nul" checked_paths || return 98
  return 0
}

# Keep every invocation's complete raw arrays and actual delegate status.
# The current caller combines complete untracked+ignored individual records;
# all calls in a stage must therefore have that stage's complete expected set.
# An additional invocation can never overwrite or hide an incomplete one.
(( ! ${+functions[_f504_original_collisions]} )) || return 32
functions[_f504_original_collisions]="${functions[_git_path_collisions]}"
typeset -gi F504_CALL_NUMBER=0
typeset -g F504_STAGE=control
_git_path_collisions() {
  emulate -L zsh
  local -a recorded_candidates=("${(@P)1}") recorded_targets=("${(@P)2}")
  local -i delegate_rc=0
  (( ++F504_CALL_NUMBER ))
  local record="$F504_CALL_NUMBER"
  local directory="$F504_CASE/$F504_STAGE.calls/$record"
  mkdir "$directory" || return 90
  _f504_save_array "$directory/candidates.nul" recorded_candidates || return 91
  _f504_save_array "$directory/targets.nul" recorded_targets || return 92
  printf '%s\t%d\t%d\n' "$record" "${#recorded_candidates[@]}" "${#recorded_targets[@]}" \
    >> "$F504_CASE/$F504_STAGE.calls.tsv" || return 93
  _f504_original_collisions "$@" > "$directory/stdout" 2> "$directory/stderr" || delegate_rc=$?
  print -r -- "$delegate_rc" > "$directory/primary.status" || return 94
  command cat "$directory/stdout" || return 95
  command cat "$directory/stderr" >&2 || return 96
  return "$delegate_rc"
}
local -F started=0 finished=0 elapsed=0
local -i command_rc=0
{
  payload_paths=("${protected_paths[@]}")
  _f504_save_array "$F504_CASE/control.payload-expected.nul" payload_paths || return 33
  _f504_capture_public_state control before payload_paths || return 34
  started=$EPOCHREALTIME
  git-undo-commit --hard --dry-run \
    > "$F504_CASE/control.stdout" 2> "$F504_CASE/control.stderr" || command_rc=$?
  finished=$EPOCHREALTIME
  elapsed=$(( finished - started ))
  print -r -- "$command_rc" > "$F504_CASE/control.primary.status" || return 35
  print -r -- "$F504_CALL_NUMBER" > "$F504_CASE/control.call-count.actual" || return 47
  LC_NUMERIC=C printf '%.9f\n' "$elapsed" > "$F504_CASE/control.elapsed.seconds" || return 36
  LC_NUMERIC=C printf '%.9f\t%.9f\n' "$started" "$finished" \
    > "$F504_CASE/control.realtime-endpoints.tsv" || return 49
  _f504_capture_public_state control after payload_paths || return 37

  # Creation, expected bytes, inventories and metadata are outside both timers.
  for (( i=1; i<=4000; ++i )); do
    print -r -- "$i" > "ignored/cache$i.bin" || return 38
    print -r -- "$i" > "$expected_root/ignored/cache$i.bin" || return 39
    ignored_paths+=("ignored/cache$i.bin")
  done
  ignored_paths=("${(@o)ignored_paths}")
  (( ${#ignored_paths[@]} == 4000 )) || return 40
  _f504_save_array "$F504_CASE/large.candidates.expected.nul" ignored_paths || return 41
  payload_paths=("${protected_paths[@]}" "${ignored_paths[@]}")
  _f504_save_array "$F504_CASE/large.payload-expected.nul" payload_paths || return 42
  _f504_capture_public_state large before payload_paths || return 43
  F504_STAGE=large
  F504_CALL_NUMBER=0
  command_rc=0
  started=$EPOCHREALTIME
  git-undo-commit --hard --dry-run \
    > "$F504_CASE/large.stdout" 2> "$F504_CASE/large.stderr" || command_rc=$?
  finished=$EPOCHREALTIME
  elapsed=$(( finished - started ))
  print -r -- "$command_rc" > "$F504_CASE/large.primary.status" || return 44
  print -r -- "$F504_CALL_NUMBER" > "$F504_CASE/large.call-count.actual" || return 48
  LC_NUMERIC=C printf '%.9f\n' "$elapsed" > "$F504_CASE/large.elapsed.seconds" || return 45
  LC_NUMERIC=C printf '%.9f\t%.9f\n' "$started" "$finished" \
    > "$F504_CASE/large.realtime-endpoints.tsv" || return 50
  _f504_capture_public_state large after payload_paths || return 46
} always {
  functions[_git_path_collisions]="${functions[_f504_original_collisions]}"
  unfunction _f504_original_collisions
}
ZSH
)
  run f504_execute_program "$(f504_support_program)"$'\n'"$program"
  [ "$status" -eq 0 ]
  [ "$(cat "$F504_CASE/program.primary.status")" -eq 0 ]
  [ ! -s "$F504_CASE/program.stdout" ]
  [ ! -s "$F504_CASE/program.stderr" ]
  f504_assert_public_calls control "$F504_CASE/control.candidates.expected.nul" 0
  f504_assert_public_calls large "$F504_CASE/large.candidates.expected.nul" 4000
  local phase
  for phase in control large; do
    [ "$(cat "$F504_CASE/$phase.primary.status")" -eq 0 ]
    [ ! -s "$F504_CASE/$phase.stdout" ]
    cmp "$F504_CASE/$phase.head.before" "$F504_CASE/$phase.head.after"
    cmp "$F504_CASE/$phase.symbolic.before" "$F504_CASE/$phase.symbolic.after"
    cmp "$F504_CASE/$phase.index.before.nul" "$F504_CASE/$phase.index.after.nul"
    cmp "$F504_CASE/$phase.payload.before.nul" "$F504_CASE/$phase.payload.after.nul"
    cmp "$F504_CASE/$phase.payload-expected.nul" "$F504_CASE/$phase.payload-checked.before.nul"
    cmp "$F504_CASE/$phase.payload-expected.nul" "$F504_CASE/$phase.payload-checked.after.nul"
    # Realtime can step backwards: these signed samples are supplementary
    # clock deltas, not monotonic durations or a performance pass/fail limit.
    awk 'NR == 1 && /^-?[0-9]+([.][0-9]+)?$/ { valid=1 }
      END { exit !(valid && NR == 1) }' "$F504_CASE/$phase.elapsed.seconds" || {
      printf 'Invalid realtime sample for %s (delta, then start/end):\n' "$phase" >&2
      cat "$F504_CASE/$phase.elapsed.seconds" "$F504_CASE/$phase.realtime-endpoints.tsv" >&2 || return 1
      return 1
    }
  done
  grep -Fq 'src/file1.txt' "$F504_CASE/large.stderr"
}

# Small hard-undo fixture shared only by the two inventory safety controls.
f504_undo_victim_fixture() {
  local ignore_rule="${1:-victim.txt}"
  export F504_VICTIM_REPO="$F504_CASE/repository"
  "$F504_REAL_GIT" init -q -b main "$F504_VICTIM_REPO" || return 1
  "$F504_REAL_GIT" -C "$F504_VICTIM_REPO" config core.hooksPath /dev/null || return 2
  "$F504_REAL_GIT" -C "$F504_VICTIM_REPO" config commit.gpgSign false || return 3
  printf '%s\n' "$ignore_rule" > "$F504_VICTIM_REPO/.gitignore" || return 4
  printf 'tracked parent bytes\n' > "$F504_VICTIM_REPO/victim.txt" || return 5
  "$F504_REAL_GIT" -C "$F504_VICTIM_REPO" add -f .gitignore victim.txt || return 6
  "$F504_REAL_GIT" -C "$F504_VICTIM_REPO" commit -qm parent || return 7
  "$F504_REAL_GIT" -C "$F504_VICTIM_REPO" rm -q victim.txt || return 8
  "$F504_REAL_GIT" -C "$F504_VICTIM_REPO" commit -qm removed || return 9
  "$F504_REAL_GIT" -C "$F504_VICTIM_REPO" rev-parse HEAD > "$F504_CASE/head.before" || return 10
  "$F504_REAL_GIT" -C "$F504_VICTIM_REPO" symbolic-ref --quiet HEAD > "$F504_CASE/symbolic.before" || return 11
  "$F504_REAL_GIT" -C "$F504_VICTIM_REPO" ls-files --stage -z > "$F504_CASE/index.before.nul" || return 12
}

@test "git collision index: hard undo protects an ignored symlink victim without replacing it" {
  f504_undo_victim_fixture
  printf 'keep linked bytes\n\n' > "$F504_CASE/link-target"
  cp "$F504_CASE/link-target" "$F504_CASE/target.expected"
  ln -s "$F504_CASE/link-target" "$F504_VICTIM_REPO/victim.txt"
  file_identity "$F504_VICTIM_REPO/victim.txt" > "$F504_CASE/link.identity.before"
  file_identity "$F504_CASE/link-target" > "$F504_CASE/target.identity.before"
  local mode
  for mode in --dry-run --yes; do
    export F504_UNDO_MODE="$mode"
    run f504_execute_program '
      source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
      cd "$F504_VICTIM_REPO" || return 91
      git-undo-commit --hard "$F504_UNDO_MODE"
    '
    [ "$status" -eq 0 ]
    [ "$(cat "$F504_CASE/program.primary.status")" -eq 1 ]
    [ ! -s "$F504_CASE/program.stdout" ]
    grep -Fq victim.txt "$F504_CASE/program.stderr"
    mv "$F504_CASE/program.primary.status" "$F504_CASE/$mode.primary.status"
    mv "$F504_CASE/program.stdout" "$F504_CASE/$mode.stdout"
    mv "$F504_CASE/program.stderr" "$F504_CASE/$mode.stderr"
    [ -L "$F504_VICTIM_REPO/victim.txt" ]
    [ "$(readlink "$F504_VICTIM_REPO/victim.txt")" = "$F504_CASE/link-target" ]
    cmp "$F504_CASE/target.expected" "$F504_CASE/link-target"
    file_identity "$F504_VICTIM_REPO/victim.txt" > "$F504_CASE/link.identity.after"
    file_identity "$F504_CASE/link-target" > "$F504_CASE/target.identity.after"
    cmp "$F504_CASE/link.identity.before" "$F504_CASE/link.identity.after"
    cmp "$F504_CASE/target.identity.before" "$F504_CASE/target.identity.after"
    "$F504_REAL_GIT" -C "$F504_VICTIM_REPO" rev-parse HEAD > "$F504_CASE/head.after"
    "$F504_REAL_GIT" -C "$F504_VICTIM_REPO" symbolic-ref --quiet HEAD > "$F504_CASE/symbolic.after"
    "$F504_REAL_GIT" -C "$F504_VICTIM_REPO" ls-files --stage -z > "$F504_CASE/index.after.nul"
    cmp "$F504_CASE/head.before" "$F504_CASE/head.after"
    cmp "$F504_CASE/symbolic.before" "$F504_CASE/symbolic.after"
    cmp "$F504_CASE/index.before.nul" "$F504_CASE/index.after.nul"
  done
}

f504_partial_inventory_row() {
  local phase="$1"
  mkdir -p "$F504_CASE" || return 1
  if [[ "$phase" == untracked ]]; then
    f504_undo_victim_fixture other-ignored || return 2
  else
    f504_undo_victim_fixture || return 2
  fi
  printf 'keep local bytes\n\n' > "$F504_VICTIM_REPO/victim.txt" || return 3
  cp "$F504_VICTIM_REPO/victim.txt" "$F504_CASE/victim.expected" || return 4
  file_identity "$F504_VICTIM_REPO/victim.txt" > "$F504_CASE/victim.identity.before" || return 5
  export F504_INVENTORY_PHASE="$phase"
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/git" || return 6
  cat >> "$TEST_MOCK_BIN/git" <<'MOCK' || return 7
inventory=0; others=0; ignored=0
for word in "$@"; do
  case "$word" in
    ls-files) inventory=1 ;;
    --others) others=1 ;;
    --ignored) ignored=1 ;;
    reset) printf 'unexpected reset\n' >> "$F504_CASE/reset.events" ;;
  esac
done
if (( inventory && others )) && {
  [[ "$F504_INVENTORY_PHASE" == untracked && "$ignored" == 0 ]] ||
  [[ "$F504_INVENTORY_PHASE" == ignored && "$ignored" == 1 ]]
}; then
  printf '%s\0' "$@" > "$F504_CASE/producer.argv.nul" || exit 90
  observed=0
  "$BASH" -c 'printf "not-the-victim\0"; printf "fixture inventory failed\n" >&2; exit 17' \
    > "$F504_CASE/producer.stdout" 2> "$F504_CASE/producer.stderr" || observed=$?
  printf '%s\n' "$observed" > "$F504_CASE/producer.observed.status" || exit 91
  cat "$F504_CASE/producer.stdout" || exit 92
  cat "$F504_CASE/producer.stderr" >&2 || exit 93
  exit "$observed"
fi
exec "$F504_REAL_GIT" "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/git" || return 8
  run f504_execute_program '
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
    cd "$F504_VICTIM_REPO" || return 91
    git-undo-commit --hard --yes
  '
  [ "$status" -eq 0 ] || return 9
  [ "$(cat "$F504_CASE/program.primary.status")" -eq 1 ] || return 10
  [ ! -s "$F504_CASE/program.stdout" ] || return 11
  [ "$(cat "$F504_CASE/producer.observed.status")" -eq 17 ] || return 12
  printf 'not-the-victim\0' > "$F504_CASE/producer.expected.nul" || return 13
  cmp "$F504_CASE/producer.expected.nul" "$F504_CASE/producer.stdout" || return 14
  [ ! -e "$F504_CASE/reset.events" ] || return 15
  cmp "$F504_CASE/victim.expected" "$F504_VICTIM_REPO/victim.txt" || return 16
  file_identity "$F504_VICTIM_REPO/victim.txt" > "$F504_CASE/victim.identity.after" || return 17
  cmp "$F504_CASE/victim.identity.before" "$F504_CASE/victim.identity.after" || return 18
  "$F504_REAL_GIT" -C "$F504_VICTIM_REPO" rev-parse HEAD > "$F504_CASE/head.after" || return 19
  "$F504_REAL_GIT" -C "$F504_VICTIM_REPO" symbolic-ref --quiet HEAD > "$F504_CASE/symbolic.after" || return 20
  "$F504_REAL_GIT" -C "$F504_VICTIM_REPO" ls-files --stage -z > "$F504_CASE/index.after.nul" || return 21
  cmp "$F504_CASE/head.before" "$F504_CASE/head.after" || return 22
  cmp "$F504_CASE/symbolic.before" "$F504_CASE/symbolic.after" || return 23
  cmp "$F504_CASE/index.before.nul" "$F504_CASE/index.after.nul" || return 24
  return 0
}

@test "git collision index: failed partial local inventories never authorize hard reset" {
  local phase outcome failures=0 root_case="$F504_CASE"
  for phase in untracked ignored; do
    export F504_CASE="$root_case/$phase"
    if f504_partial_inventory_row "$phase"; then outcome=0
    else outcome=$?; failures=$((failures + 1)); fi
    printf '%s\t%s\n' "$phase" "$outcome" >> "$root_case/partial-results.tsv"
  done
  [ "$(wc -l < "$root_case/partial-results.tsv")" -eq 2 ]
  [ "$failures" -eq 0 ]
}
