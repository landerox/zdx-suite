#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  load test_helper
  export F508_ROOT="$HOME/telemetry-output" F508_CASE="" NO_COLOR=1 ZDX_LAZY_LOAD=1
  mkdir -p "$F508_ROOT" "$HOME/.config/zdx" || return 1
  chmod -- 700 "$HOME/.config" "$HOME/.config/zdx" || return 2
}

teardown() {
  cleanup_sandbox
}

# Keep collection separate from assertions so every matrix cell is observed.
f508_observe() {
  local name="$1" body="$2" wrapper=0
  export F508_CASE="$F508_ROOT/$name"
  mkdir "$F508_CASE" || return 1
  run_zsh '
    source "$ZSH_CUSTOM/functions/sys-common.zsh" || return 90
    source "$ZSH_CUSTOM/functions/sys/sys-telemetry.zsh" || return 91
    _f508_action() {
  '"$body"'
    }
    local -i primary=0
    _f508_action > "$F508_CASE/stdout" 2> "$F508_CASE/stderr" || primary=$?
    print -r -- "$primary" > "$F508_CASE/primary.status" || return 92
    return 0
  ' > "$F508_CASE/wrapper.stdout" 2> "$F508_CASE/wrapper.stderr" || wrapper=$?
  printf '%s\n' "$wrapper" > "$F508_CASE/wrapper.status" || return 2
  [[ "$wrapper" -eq 0 ]] || return 3
}

f508_primary() {
  local dir="$1" expected="$2" actual
  local file
  for file in primary.status wrapper.status stdout stderr wrapper.stdout wrapper.stderr; do
    [[ -f "$dir/$file" ]] || return 1
  done
  actual=$(cat "$dir/primary.status") || return 2
  [[ "$actual" =~ ^[0-9]+$ && "$actual" == "$expected" ]] || return 3
  actual=$(cat "$dir/wrapper.status") || return 4
  [[ "$actual" == 0 && ! -s "$dir/wrapper.stdout" && ! -s "$dir/wrapper.stderr" ]] || return 5
}

f508_exact_data() {
  local dir="$1" expected="$2"
  f508_primary "$dir" 0 || return 1
  [[ -f "$expected" && ! -s "$dir/stderr" ]] || return 2
  cmp "$expected" "$dir/stdout" || return 3
}

f508_unchanged() {
  local log="$HOME/.config/zdx/telemetry.json" after="$F508_ROOT/identity.after"
  cmp "$F508_ROOT/before" "$log" || return 1
  file_identity "$log" > "$after" || return 2
  cmp "$F508_ROOT/identity.before" "$after" || return 3
}

f508_save_input() {
  chmod -- 600 "$HOME/.config/zdx/telemetry.json" || return 1
  cp "$HOME/.config/zdx/telemetry.json" "$F508_ROOT/before" || return 2
  file_identity "$HOME/.config/zdx/telemetry.json" > "$F508_ROOT/identity.before" || return 3
}

@test "sys telemetry output: reader rejects numeric suffixes and incomplete final records while preserving complete neighbors" {
  local log="$HOME/.config/zdx/telemetry.json"
  cat > "$log" <<'JSON'
{"suite":"sys","command":"first","duration_ms":0,"exit_code":0,"timestamp":"2026-07-11T12:00:00Z"}
{"suite":"sys","command":"duration-fraction","duration_ms":25.5,"exit_code":0,"timestamp":"2026-07-11T12:00:01Z"}
{"suite":"sys","command":"duration-exponent","duration_ms":1e99,"exit_code":0,"timestamp":"2026-07-11T12:00:02Z"}
{"suite":"sys","command":"duration-junk","duration_ms":12junk,"exit_code":0,"timestamp":"2026-07-11T12:00:03Z"}
{"suite":"sys","command":"exit-fraction","duration_ms":25,"exit_code":0.5,"timestamp":"2026-07-11T12:00:04Z"}
{"suite":"sys","command":"exit-exponent","duration_ms":25,"exit_code":1e2,"timestamp":"2026-07-11T12:00:05Z"}
{"suite":"sys","command":"exit-junk","duration_ms":25,"exit_code":1junk,"timestamp":"2026-07-11T12:00:06Z"}
{"suite":"sys","command":"duplicate","duration_ms":25,"duration_ms":26,"exit_code":0,"timestamp":"2026-07-11T12:00:07Z"}
{"suite":"sys","command":"range","duration_ms":31536000001,"exit_code":256,"timestamp":"2026-07-11T12:00:08Z"}
{"suite":"sys","command":"leading-zero","duration_ms":01,"exit_code":0,"timestamp":"2026-07-11T12:00:09Z"}
{"suite":"sys|unsafe","command":"bad-label","duration_ms":25,"exit_code":0,"timestamp":"2026-07-11T12:00:10Z"}
{"suite":"sys","command":"last","exit_code":255 ,"timestamp":"2026-07-11T12:00:11Z","duration_ms":31536000000 }
JSON
  printf '%s' '{"suite":"sys","command":"no-lf","duration_ms":5,"exit_code":0,"timestamp":"2026-07-11T12:00:12Z"}' >> "$log"
  f508_save_input
  f508_observe records '_sys_telemetry_records "$HOME/.config/zdx/telemetry.json"'
  printf '2026-07-11T12:00:00Z\tsys\tfirst\t0\t0\n2026-07-11T12:00:11Z\tsys\tlast\t31536000000\t255\n' > "$F508_ROOT/expected"
  f508_exact_data "$F508_ROOT/records" "$F508_ROOT/expected"
  f508_unchanged
}

@test "sys telemetry output: missing empty and invalid-only logs keep distinct truthful empty states" {
  local mode
  for mode in missing empty partial no-lf; do
    case "$mode" in
      missing) ;;
      empty) : > "$HOME/.config/zdx/telemetry.json" ;;
      partial) printf '{"suite":"sys"' > "$HOME/.config/zdx/telemetry.json" ;;
      no-lf) printf '%s' '{"suite":"sys","command":"no-lf","duration_ms":5,"exit_code":0,"timestamp":"2026-07-11T12:00:00Z"}' > "$HOME/.config/zdx/telemetry.json" ;;
    esac
    f508_observe "$mode" 'sys-telemetry --dashboard' || return 1
  done
  for mode in missing empty partial no-lf; do
    f508_primary "$F508_ROOT/$mode" 0 || return 2
    [[ ! -s "$F508_ROOT/$mode/stdout" ]] || return 3
    if [[ "$mode" == missing || "$mode" == empty ]]; then
      grep -Fq 'No telemetry data found.' "$F508_ROOT/$mode/stderr" || return 4
    else
      grep -Fq 'No valid telemetry records found.' "$F508_ROOT/$mode/stderr" || return 5
    fi
    if grep -Fq 'Total Runs:' "$F508_ROOT/$mode/stderr"; then return 6; fi
  done
}

@test "sys telemetry output: milliseconds use core units rounding and day formatting" {
  local milliseconds expected row
  local -a rows=(
    '0|0.0s' '50|0.1s' '1500|1.5s' '9940|9.9s' '9950|10s'
    '59500|1m 00s' '124500|2m 05s' '3599500|1h 00m'
    '86400000|1d 00h' '90061000|1d 01h' '171000000|2d 00h'
  )
  for row in "${rows[@]}"; do
    IFS='|' read -r milliseconds expected <<< "$row"
    export F508_MS="$milliseconds"
    f508_observe "ms-$milliseconds" '_sys_telemetry_format_ms "$F508_MS"' || return 1
    printf '%s' "$expected" > "$F508_ROOT/ms-$milliseconds/expected" || return 2
  done
  for row in "${rows[@]}"; do
    IFS='|' read -r milliseconds expected <<< "$row"
    f508_exact_data "$F508_ROOT/ms-$milliseconds" "$F508_ROOT/ms-$milliseconds/expected" || return 3
  done
}

@test "sys telemetry output: invalid milliseconds fail without fabricated data and regex state stays local" {
  local input index=0
  for input in '' -1 01 1.5 1e3 31536000001 999999999999999999999; do
    index=$((index+1))
    export F508_MS="$input"
    f508_observe "invalid-$index" '_sys_telemetry_format_ms "$F508_MS"' || return 1
  done
  f508_observe regex-state '
    [[ fixture123 =~ "([0-9]+)" ]] || return 80
    local before="$MATCH:$MBEGIN:$MEND:${(j:,:)match}:${(j:,:)mbegin}:${(j:,:)mend}"
    _sys_telemetry_format_ms 1500 > "$F508_CASE/rendered" || return 81
    [[ "$MATCH:$MBEGIN:$MEND:${(j:,:)match}:${(j:,:)mbegin}:${(j:,:)mend}" == "$before" ]] || return 82
  '
  for index in 1 2 3 4 5 6 7; do
    f508_primary "$F508_ROOT/invalid-$index" 2 || return 2
    [[ ! -s "$F508_ROOT/invalid-$index/stdout" && ! -s "$F508_ROOT/invalid-$index/stderr" ]] || return 3
  done
  f508_primary "$F508_ROOT/regex-state" 0
  [[ ! -s "$F508_ROOT/regex-state/stdout" && ! -s "$F508_ROOT/regex-state/stderr" ]]
}

@test "sys telemetry output: dashboard and browser display core durations while retaining machine milliseconds" {
  cat > "$HOME/.config/zdx/telemetry.json" <<'JSON'
{"suite":"sys","command":"fast","duration_ms":1500,"exit_code":0,"timestamp":"2026-07-11T12:00:00Z"}
{"suite":"sys","command":"slow","duration_ms":123000,"exit_code":1,"timestamp":"2026-07-11T12:00:01Z"}
JSON
  f508_save_input
  f508_observe dashboard 'sys-telemetry --dashboard'
  f508_observe browser '
    _sys_fzf_capture() {
      printf "%s\0" "$@" > "$F508_CASE/argv" || return 91
      command cat > "$F508_CASE/input" || return 92
      REPLY=""
      return 130
    }
    sys-telemetry --browse
  '
  # Exercise the actual fixed preview with fzf-style quoted field values.
  python3 -B -I - "$F508_ROOT/browser" <<'PYCODE'
from pathlib import Path
import shlex
import subprocess
import sys
p = Path(sys.argv[1])
args = p.joinpath('argv').read_bytes().decode().split('\0')[:-1]
previews = [a.partition('=')[2] for a in args if a.startswith('--preview=')]
assert len(previews) == 1
for index, row in enumerate(p.joinpath('input').read_text().splitlines(), 1):
    program = previews[0]
    for field, value in enumerate(row.split('\t'), 1):
        program = program.replace('{' + str(field) + '}', shlex.quote(value))
    result = subprocess.run(['/bin/sh', '-c', program], stdin=subprocess.DEVNULL, capture_output=True)
    p.joinpath('preview-' + str(index) + '.stdout').write_bytes(result.stdout)
    p.joinpath('preview-' + str(index) + '.stderr').write_bytes(result.stderr)
    p.joinpath('preview-' + str(index) + '.status').write_text(str(result.returncode) + '\n')
PYCODE
  f508_unchanged
  cat > "$HOME/.config/zdx/telemetry.json" <<'JSON'
{"suite":"sys","command":"max-one","duration_ms":31536000000,"exit_code":0,"timestamp":"2026-07-11T12:00:00Z"}
{"suite":"sys","command":"max-two","duration_ms":31536000000,"exit_code":0,"timestamp":"2026-07-11T12:00:01Z"}
JSON
  f508_save_input
  f508_observe aggregate-limit 'sys-telemetry --dashboard'
  f508_primary "$F508_ROOT/dashboard" 0
  [[ ! -s "$F508_ROOT/dashboard/stdout" ]]
  local report="$F508_ROOT/dashboard/stderr"
  grep -Eq 'Total Runs: *2$' "$report"
  grep -Eq 'Successful: *1$' "$report"
  grep -Eq 'Failed: *1$' "$report"
  grep -Eq 'Total Duration: *2m 05s$' "$report"
  grep -Eq 'Average: *1m 02s$' "$report"
  grep -Eq '^  sys .*2m 05s$' "$report"
  grep -Fq 'sys:fast · 1.5s · exit 0' "$report"
  grep -Fq 'sys:slow · 2m 03s · exit 1' "$report"
  f508_primary "$F508_ROOT/browser" 0
  [[ ! -s "$F508_ROOT/browser/stdout" && ! -s "$F508_ROOT/browser/stderr" ]]
  printf '[failed] 2026-07-11T12:00:01Z [sys] slow (2m 03s)\t2026-07-11T12:00:01Z\tsys\tslow\t123000\t1\t2m 03s\n[ok] 2026-07-11T12:00:00Z [sys] fast (1.5s)\t2026-07-11T12:00:00Z\tsys\tfast\t1500\t0\t1.5s\n' > "$F508_ROOT/browser/expected"
  cmp "$F508_ROOT/browser/expected" "$F508_ROOT/browser/input"
  local index duration command_name timestamp
  for index in 1 2; do
    if [[ "$index" == 1 ]]; then duration='2m 03s'; command_name=slow; timestamp=2026-07-11T12:00:01Z
    else duration=1.5s; command_name=fast; timestamp=2026-07-11T12:00:00Z; fi
    [[ "$(cat "$F508_ROOT/browser/preview-$index.status")" == 0 ]] || return 10
    [[ ! -s "$F508_ROOT/browser/preview-$index.stderr" ]] || return 11
    printf 'Execution details\n\n  Timestamp: %s\n  Suite: sys\n  Command: %s\n  Duration: %s\n  Exit code: %s\n' "$timestamp" "$command_name" "$duration" "$((2-index))" > "$F508_ROOT/browser/preview.expected" || return 12
    cmp "$F508_ROOT/browser/preview.expected" "$F508_ROOT/browser/preview-$index.stdout" || return 13
  done
  f508_primary "$F508_ROOT/aggregate-limit" 0
  [[ ! -s "$F508_ROOT/aggregate-limit/stdout" ]]
  grep -Eq 'Total Duration: *unavailable$' "$F508_ROOT/aggregate-limit/stderr"
  grep -Eq '^  sys .*unavailable$' "$F508_ROOT/aggregate-limit/stderr"
  grep -Eq 'Average: *365d 00h$' "$F508_ROOT/aggregate-limit/stderr"
  f508_unchanged
}

@test "sys telemetry output: unsafe oversized and failed reads remain operational failures" {
  printf '%s\n' '{}' > "$F508_ROOT/target"
  ln -s "$F508_ROOT/target" "$HOME/.config/zdx/telemetry.json"
  f508_observe unsafe 'sys-telemetry --dashboard'
  rm "$HOME/.config/zdx/telemetry.json"
  printf '%s\n' '{}' > "$HOME/.config/zdx/telemetry.json"
  f508_observe oversized 'SYS_TELEMETRY_MAX_READ_BYTES=1 sys-telemetry --dashboard'
  printf '#!%s\nexit 17\n' "$BASH" > "$F508_ROOT/awk-producer"
  chmod -- 700 "$F508_ROOT/awk-producer"
  cat > "$TEST_MOCK_BIN/awk" <<EOF
#!$BASH
printf '%s\\n' "\$0" > "\$F508_CASE/\$F508_READ_PHASE.awk.reached"
printf '%s\\0' "\$@" > "\$F508_CASE/\$F508_READ_PHASE.awk.argv"
"\$F508_ROOT/awk-producer" "\$@" > "\$F508_CASE/\$F508_READ_PHASE.producer.stdout" 2> "\$F508_CASE/\$F508_READ_PHASE.producer.stderr"
observed=\$?
printf '%s\\n' "\$observed" > "\$F508_CASE/\$F508_READ_PHASE.producer.status"
exit "\$observed"
EOF
  chmod -- 700 "$TEST_MOCK_BIN/awk"
  f508_observe failed-read '
    export F508_READ_PHASE=direct
    local -i producer_rc=0
    command "$TEST_MOCK_BIN/awk" fixture || producer_rc=$?
    print -r -- "$producer_rc" > "$F508_CASE/direct.wrapper.status" || return 93
    export F508_READ_PHASE=public
    sys-telemetry --dashboard
  '
  local mode
  for mode in unsafe oversized failed-read; do
    f508_primary "$F508_ROOT/$mode" 1 || return 1
    [[ ! -s "$F508_ROOT/$mode/stdout" ]] || return 2
  done
  local phase
  for phase in direct public; do
    [[ "$(cat "$F508_ROOT/failed-read/$phase.awk.reached")" == "$TEST_MOCK_BIN/awk" ]] || return 3
    [[ -s "$F508_ROOT/failed-read/$phase.awk.argv" ]] || return 4
    [[ "$(cat "$F508_ROOT/failed-read/$phase.producer.status")" == 17 ]] || return 5
    [[ ! -s "$F508_ROOT/failed-read/$phase.producer.stdout" && ! -s "$F508_ROOT/failed-read/$phase.producer.stderr" ]] || return 6
  done
  [[ "$(cat "$F508_ROOT/failed-read/direct.wrapper.status")" == 17 ]]
  [[ "$(cat "$F508_ROOT/target")" == '{}' ]]
}

@test "sys telemetry output: duration conversion keeps a decimal point under a supported comma locale" {
  # Begin scoped locale eligibility. Each probe finishes before product code.
  f508_locale_probe() {
    local output="$1" name="$2" search="$3" rc=0
    LOCPATH="$search" LC_ALL="$name" zsh -f -c 'emulate -R zsh; printf "%.1f" 1.5' \
      > "$output.stdout" 2> "$output.stderr" || rc=$?
    printf '%s\n' "$rc" > "$output.status" || return 1
    (( rc == 0 )) || return 1
    [[ ! -s "$output.stderr" ]] || return 1
    # macOS fa_IR emits U+066B: a valid non-comma result; keep looking for 1,5.
    [[ "$(cat "$output.stdout")" == '1,5' || "$(cat "$output.stdout")" == '1.5' \
      || "$(cat "$output.stdout")" == '1٫5' ]] || return 1
  }

  f508_locale_eligible() {
    local evidence="$1" data="$2" program name entry charmap rc=0 index=0
    mkdir -p "$evidence" || return 1
    program=$(type -P locale 2> "$evidence/lookup.stderr") || rc=$?
    printf '%s\n' "$rc" > "$evidence/lookup.status" || return 1
    if (( rc != 0 )); then
      (( rc == 1 )) || return 1
      printf 'locale executable is absent\n' > "$evidence/reason" || return 1
      return 77
    fi
    "$program" -a > "$evidence/advertised.stdout" 2> "$evidence/advertised.stderr" || rc=$?
    printf '%s\n' "$rc" > "$evidence/advertised.status" || return 1
    (( rc == 0 )) || return 1
    [[ ! -s "$evidence/advertised.stderr" ]] || return 1
    while IFS= read -r name; do
      [[ -n "$name" ]] || return 1
      index=$((index+1))
      printf '%s\n' "$name" > "$evidence/installed-$index.name" || return 1
      f508_locale_probe "$evidence/installed-$index" "$name" '' || return $?
      if [[ "$(cat "$evidence/installed-$index.stdout")" == '1,5' ]]; then
        F508_LOCALE="$name" F508_LOCALE_DIR=''
        printf '%s\n' "$name" > "$evidence/selected.name" || return 1
        return 0
      fi
    done < "$evidence/advertised.stdout"

    # This optional fallback requires observable, readable GNU locale inputs.
    for entry in "$data" "$data/locales" "$data/charmaps"; do
      if [[ ! -e "$entry" && ! -L "$entry" ]]; then
        [[ -d "${entry%/*}" && -x "${entry%/*}" ]] || return 1
        printf 'no installed comma locale; GNU input directory absent: %s\n' "$entry" > "$evidence/reason" || return 1
        return 77
      fi
      [[ -d "$entry" && -r "$entry" && -x "$entry" ]] || return 1
    done
    if [[ ! -e "$data/locales/de_DE" && ! -L "$data/locales/de_DE" ]]; then
      printf 'no installed comma locale; GNU de_DE input is absent\n' > "$evidence/reason" || return 1
      return 77
    fi
    [[ -f "$data/locales/de_DE" && -r "$data/locales/de_DE" ]] || return 1
    charmap="$data/charmaps/UTF-8"
    if [[ ! -e "$charmap" && ! -L "$charmap" ]]; then charmap+=.gz; fi
    if [[ ! -e "$charmap" && ! -L "$charmap" ]]; then
      printf 'no installed comma locale; GNU UTF-8 charmap is absent\n' > "$evidence/reason" || return 1
      return 77
    fi
    [[ -f "$charmap" && -r "$charmap" ]] || return 1
    rc=0
    program=$(type -P localedef 2> "$evidence/build-lookup.stderr") || rc=$?
    printf '%s\n' "$rc" > "$evidence/build-lookup.status" || return 1
    if (( rc != 0 )); then
      (( rc == 1 )) || return 1
      printf 'no installed comma locale; localedef executable is absent\n' > "$evidence/reason" || return 1
      return 77
    fi
    "$program" --version > "$evidence/support.stdout" 2> "$evidence/support.stderr" || rc=$?
    printf '%s\n' "$rc" > "$evidence/support.status" || return 1
    (( rc == 0 )) || return 1
    [[ ! -s "$evidence/support.stderr" ]] || return 1
    if [[ "$(cat "$evidence/support.stdout")" != localedef*GNU* \
      && "$(cat "$evidence/support.stdout")" != localedef*GLIBC* ]]; then
      printf 'no installed comma locale; localedef does not advertise GNU support\n' > "$evidence/reason" || return 1
      return 77
    fi
    F508_LOCALE_DIR="$evidence/private"
    mkdir "$F508_LOCALE_DIR" || return 1
    I18NPATH="$data" "$program" -i "$data/locales/de_DE" -f UTF-8 "$F508_LOCALE_DIR/de_DE.UTF-8" \
      > "$evidence/build.stdout" 2> "$evidence/build.stderr" || rc=$?
    printf '%s\n' "$rc" > "$evidence/build.status" || return 1
    (( rc == 0 )) || return 1
    f508_locale_probe "$evidence/private-probe" de_DE.UTF-8 "$F508_LOCALE_DIR" || return $?
    [[ "$(cat "$evidence/private-probe.stdout")" == '1,5' ]] || return 1
    F508_LOCALE=de_DE.UTF-8
    printf '%s\n' "$F508_LOCALE" > "$evidence/selected.name" || return 1
  }
  # End scoped locale eligibility.

  # Failure-only receipt output; it never decides eligibility or product status.
  f508_locale_diagnostic() {
    local evidence="$1" file candidate name index highest='' highest_number=0
    local -a files=(lookup.status lookup.stdout lookup.stderr
      advertised.status advertised.stdout advertised.stderr
      build-lookup.status build-lookup.stdout build-lookup.stderr
      support.status support.stdout support.stderr
      build.status build.stdout build.stderr
      private-probe.status private-probe.stdout private-probe.stderr
      selected.name reason)
    printf 'Locale eligibility failure: existing receipts only.\n' >&2
    for candidate in "$evidence"/installed-*.name; do
      [[ -f "$candidate" && ! -L "$candidate" ]] || continue
      name="${candidate##*/}"
      index="${name#installed-}"
      index="${index%.name}"
      [[ "$index" =~ ^[0-9]+$ && ${#index} -le 8 ]] || continue
      if (( 10#$index > highest_number )); then
        highest_number=$((10#$index))
        highest="installed-$index"
      fi
    done
    if [[ -n "$highest" ]]; then
      files+=("$highest.name" "$highest.status" "$highest.stdout" "$highest.stderr")
    else
      printf 'No installed-N.name receipt found; attempted phase remains unknown.\n' >&2
    fi
    for file in "${files[@]}"; do
      if [[ ! -e "$evidence/$file" && ! -L "$evidence/$file" ]]; then
        printf 'Receipt %s: missing.\n' "$file" >&2
      elif [[ -f "$evidence/$file" && ! -L "$evidence/$file" ]]; then
        printf 'Receipt %s: hex, at most 512 bytes.\n' "$file" >&2
        command od -An -v -tx1 -N 512 "$evidence/$file" >&2 \
          || printf 'Receipt %s: read failed.\n' "$file" >&2
      else
        printf 'Receipt %s: not a regular non-link file; unread.\n' "$file" >&2
      fi
    done
    return 0
  }

  local eligibility_rc=0
  f508_locale_eligible "$F508_ROOT/eligibility" /usr/share/i18n || eligibility_rc=$?
  printf '%s\n' "$eligibility_rc" > "$F508_ROOT/eligibility.status" || return 1
  if (( eligibility_rc == 77 )); then
    local reason=""
    [[ -f "$F508_ROOT/eligibility/reason" ]] || return 1
    reason=$(cat "$F508_ROOT/eligibility/reason") || return 1
    [[ -n "$reason" ]] || return 1
    skip "$reason"
  fi
  if (( eligibility_rc != 0 && eligibility_rc != 77 )); then
    f508_locale_diagnostic "$F508_ROOT/eligibility" || :
  fi
  [[ "$eligibility_rc" == 0 ]]
  export F508_LOCALE F508_LOCALE_DIR
  f508_observe comma '
    export LOCPATH="$F508_LOCALE_DIR" LC_ALL="$F508_LOCALE"
    _sys_telemetry_format_ms 1500
  '
  printf '1.5s' > "$F508_ROOT/comma/expected"
  f508_exact_data "$F508_ROOT/comma" "$F508_ROOT/comma/expected"
}
