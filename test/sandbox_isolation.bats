#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  load test_helper
}

teardown() {
  local stop_status=0 sandbox_status=0
  _zdx_test_stop_session_probe || stop_status=$?
  cleanup_sandbox || sandbox_status=$?
  [[ "$stop_status" -eq 0 && "$sandbox_status" -eq 0 ]]
}

# Private Linux PTY worker ownership; no process-name or global-table fallback.
_zdx_test_session_probe_decimal() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]] || return 1
  case "$2" in
    10) [[ ${#1} -le 10 ]] ;;
    20) [[ ${#1} -le 20 ]] ;;
    *) return 1 ;;
  esac
}

# Direct-call output: capture this shell before any command substitution.
_zdx_test_session_probe_self() {
  local raw="" pid=""
  REPLY=""
  IFS= read -r raw < /proc/self/stat 2>/dev/null || return 1
  pid=${raw%% *}
  _zdx_test_session_probe_decimal "$pid" 10 && [[ "$pid" != 1 ]] || return 1
  [[ -z "${BASHPID:-}" || "$pid" == "$BASHPID" ]] || return 1
  REPLY="$pid"
}

# One targeted identity row; 0 valid, 1 absent, 2 unknown. STATE is transient.
_zdx_test_session_probe_stat() {
  local pid="${1:-}" raw="" tail="" observation="" group="" session="" extra=""
  local -a fields=()
  local line_feed="" carriage_return=""
  [[ $# -eq 1 ]] && _zdx_test_session_probe_decimal "$pid" 10 \
    && [[ "$pid" != 1 ]] || return 2
  # Keep control-byte formats textual through declare -f and BATS preprocessing.
  printf -v line_feed '\n' || return 2
  printf -v carriage_return '\r' || return 2
  [[ -n "$line_feed" && -n "$carriage_return" ]] || return 2
  if ! raw=$(cat "/proc/$pid/stat" 2>/dev/null); then
    [[ -r /proc && -x /proc && ! -e "/proc/$pid" ]] && return 1
    return 2
  fi
  [[ "$raw" == "$pid ("*") "* ]] || return 2
  # comm may contain spaces, parentheses and newlines; its final ') ' wins.
  tail=${raw##*) }
  [[ "$tail" != *"$line_feed"* && "$tail" != *"$carriage_return"* ]] || return 2
  IFS=' ' read -r -a fields <<< "$tail"
  [[ ${#fields[@]} -ge 20 && "${fields[0]}" == [RSDTtIWKPZXx] ]] || return 2
  _zdx_test_session_probe_decimal "${fields[2]}" 10 \
    && _zdx_test_session_probe_decimal "${fields[3]}" 10 \
    && _zdx_test_session_probe_decimal "${fields[19]}" 20 || return 2
  if ! observation=$(ps -p "$pid" -o pgid=,sid= 2>/dev/null); then
    [[ -r /proc && -x /proc && ! -e "/proc/$pid" ]] && return 1
    return 2
  fi
  [[ "$observation" != *$'\n'* ]] || return 2
  IFS=' ' read -r group session extra <<< "$observation"
  [[ -z "$extra" && "$group" == "${fields[2]}" \
    && "$session" == "${fields[3]}" ]] || return 2
  printf '%s %s %s %s %s\n' "$pid" "$group" "$session" "${fields[19]}" "${fields[0]}"
}

_zdx_test_session_probe_directory() {
  local mode=""
  [[ -d "$1" && ! -L "$1" && -O "$1" ]] || return 1
  mode=$(file_mode "$1" 2>/dev/null) || return 1
  [[ "$mode" == 700 ]]
}

_zdx_test_session_probe_data() {
  local mode="" links=""
  [[ -f "$1" && ! -L "$1" && -O "$1" ]] || return 1
  mode=$(file_mode "$1" 2>/dev/null) || return 1
  links=$(file_links "$1" 2>/dev/null) || return 1
  [[ "$mode" == 600 && "$links" == 1 ]]
}

_zdx_test_session_probe_identities() {
  local parent="" ready="" data=""
  parent=$(file_identity "${1%/*}" 2>/dev/null) || return 1
  ready=$(file_identity "$1.ready" 2>/dev/null) || return 1
  data=$(file_identity "$1" 2>/dev/null) || return 1
  printf '%s/%s/%s\n' "$parent" "$ready" "$data"
}

_zdx_test_session_probe_parent() {
  local parent="${1%/*}" root="${TEST_TEMP_DIR:-}" relative="" component="" cursor=""
  [[ "$root" == /* && "$parent" == "$root"/* ]] || return 1
  _zdx_test_session_probe_directory "$root" || return 1
  relative=${parent#"$root"/}
  cursor=$root
  while :; do
    component=${relative%%/*}
    [[ -n "$component" && "$component" != . && "$component" != .. ]] || return 1
    cursor="$cursor/$component"
    _zdx_test_session_probe_directory "$cursor" || return 1
    [[ "$relative" == */* ]] || break
    relative=${relative#*/}
  done
  return 0
}

# A complete record plus an atomic empty-directory commit; no overwrite.
_zdx_test_session_probe_publish() {
  local pid="${1:-}" receipt="${ZDX_TEST_SESSION_RECEIPT:-}" REPLY="" row=""
  local observed="" group="" session="" start="" state="" extra=""
  [[ $# -eq 1 ]] || return 1
  _zdx_test_session_probe_self && [[ "$pid" == "$REPLY" ]] || return 1
  _zdx_test_session_probe_parent "$receipt" || return 1
  [[ ! -e "$receipt" && ! -L "$receipt" \
    && ! -e "$receipt.ready" && ! -L "$receipt.ready" ]] || return 1
  row=$(_zdx_test_session_probe_stat "$pid") || return 1
  IFS=' ' read -r observed group session start state extra <<< "$row"
  [[ "$observed" == "$pid" && -z "$extra" && "$state" == [RSDTtIWKP] ]] || return 1
  _zdx_test_session_probe_decimal "$group" 10 \
    && _zdx_test_session_probe_decimal "$session" 10 \
    && _zdx_test_session_probe_decimal "$start" 20 \
    && [[ "$group" != 1 && "$session" != 1 ]] || return 1
  (
    umask 077
    set -C
    printf 'zdx-session-probe-v1 %s %s %s %s\n' "$pid" "$group" "$session" "$start" > "$receipt"
  ) || return 1
  _zdx_test_session_probe_data "$receipt" || return 1
  mkdir -m 700 "$receipt.ready"
}

# Four identity fields plus stable parent/ready/data identities, as data only.
_zdx_test_session_probe_receipt() {
  local receipt="${1:-}" ready="" tag="" pid="" group="" session="" start="" extra=""
  local size="" identities="" after="" entry=""
  ready="$receipt.ready"
  _zdx_test_session_probe_parent "$receipt" || return 1
  _zdx_test_session_probe_directory "$ready" || return 1
  for entry in "$ready"/* "$ready"/.[!.]* "$ready"/..?*; do
    [[ ! -e "$entry" && ! -L "$entry" ]] || return 1
  done
  _zdx_test_session_probe_data "$receipt" || return 1
  size=$(file_size "$receipt" 2>/dev/null) || return 1
  [[ "$size" =~ ^[1-9][0-9]?$ && "$size" -le 75 ]] || return 1
  identities=$(_zdx_test_session_probe_identities "$receipt") || return 1
  IFS=' ' read -r tag pid group session start extra < "$receipt" || return 1
  [[ "$tag" == zdx-session-probe-v1 && -z "$extra" ]] || return 1
  _zdx_test_session_probe_decimal "$pid" 10 \
    && _zdx_test_session_probe_decimal "$group" 10 \
    && _zdx_test_session_probe_decimal "$session" 10 \
    && _zdx_test_session_probe_decimal "$start" 20 || return 1
  [[ "$pid" != 1 && "$group" != 1 && "$session" != 1 ]] || return 1
  cmp -s "$receipt" <(printf 'zdx-session-probe-v1 %s %s %s %s\n' "$pid" "$group" "$session" "$start") || return 1
  _zdx_test_session_probe_parent "$receipt" \
    && _zdx_test_session_probe_directory "$ready" || return 1
  for entry in "$ready"/* "$ready"/.[!.]* "$ready"/..?*; do
    [[ ! -e "$entry" && ! -L "$entry" ]] || return 1
  done
  _zdx_test_session_probe_data "$receipt" || return 1
  after=$(_zdx_test_session_probe_identities "$receipt") || return 1
  [[ "$identities" == "$after" ]] || return 1
  printf '%s %s %s %s %s\n' "$pid" "$group" "$session" "$start" "$identities"
}

_zdx_test_stop_session_probe() {
  [[ -n "${ZDX_TEST_SESSION_PROBE:-}" ]] || return 0
  local REPLY="" outer_pid="" outer_row="" outer_group="" outer_session="" outer_start="" outer_state=""
  local receipt="${ZDX_TEST_SESSION_RECEIPT:-}" record="" current="" pid="" group="" session="" start="" identities="" extra="" row="" status=0
  _zdx_test_session_probe_self || return 1
  outer_pid=$REPLY
  _zdx_test_session_probe_decimal "$outer_pid" 10 && [[ "$outer_pid" != 1 ]] || return 1
  record=$(_zdx_test_session_probe_receipt "$receipt") || return 1
  IFS=' ' read -r pid group session start identities extra <<< "$record"
  [[ -z "$extra" && "$pid" != "$outer_pid" ]] || return 1
  outer_row=$(_zdx_test_session_probe_stat "$outer_pid") || return 1
  IFS=' ' read -r current outer_group outer_session outer_start outer_state extra <<< "$outer_row"
  [[ "$current" == "$outer_pid" && -z "$extra" && "$outer_state" == [RSDTtIWKP] ]] || return 1
  _zdx_test_session_probe_decimal "$outer_group" 10 \
    && _zdx_test_session_probe_decimal "$outer_session" 10 \
    && _zdx_test_session_probe_decimal "$outer_start" 20 || return 1
  [[ "$group" != "$outer_group" && "$session" != "$outer_session" \
    && "$group" != "$outer_pid" && "$group" != "$outer_session" ]] || return 1
  row=$(_zdx_test_session_probe_stat "$pid") || status=$?
  [[ "$status" != 1 ]] || return 0
  [[ "$status" == 0 ]] || return 1
  case "$row" in
    "$pid $group $session $start "[ZXx]) return 0 ;;
    "$pid $group $session $start "[RSDTtIWKP]) ;;
    *) return 1 ;;
  esac
  current=$(_zdx_test_session_probe_receipt "$receipt") || return 1
  [[ "$current" == "$record" ]] || return 1
  status=0
  row=$(_zdx_test_session_probe_stat "$pid") || status=$?
  [[ "$status" != 1 ]] || return 0
  [[ "$status" == 0 ]] || return 1
  case "$row" in
    "$pid $group $session $start "[ZXx]) return 0 ;;
    "$pid $group $session $start "[RSDTtIWKP]) ;;
    *) return 1 ;;
  esac
  kill -KILL -- "-$group" 2>/dev/null || return 1
  return 0
}

_zdx_test_parallel_session_probe() {
  skip_on_darwin "requires Linux /proc for session ownership"
  has_util_linux_script || skip "requires util-linux script for a controlling terminal"
  command -v just >/dev/null || skip "requires just"
  command -v timeout >/dev/null || skip "requires timeout for the PTY bound"
  [[ "$(parallel --version 2>/dev/null)" == "GNU parallel"* ]] || skip "requires GNU parallel"
  # BATS puts its internal libexec directory on PATH. In a clean environment
  # that internal `bats` lacks the public launcher's exported helper function.
  local entry
  local -a nested_path=()
  IFS=: read -r -a nested_path <<< "$PATH"
  ZDX_TEST_NESTED_PATH=
  for entry in "${nested_path[@]}"; do
    [[ "$entry" != "$BATS_LIBEXEC" ]] || continue
    ZDX_TEST_NESTED_PATH+="${ZDX_TEST_NESTED_PATH:+:}$entry"
  done
  export ZDX_TEST_NESTED_PATH
  export ZDX_TEST_SESSION_PROBE="$TEST_TEMP_DIR/zdx-session-probe.bats"
  export ZDX_TEST_SESSION_RECEIPT="$TEST_TEMP_DIR/session-owner/receipt"
  mkdir -m 700 "$TEST_TEMP_DIR/session-owner" || return 1
  {
    printf '#!/usr/bin/env bats\nTEST_TEMP_DIR=%q\n' "$TEST_TEMP_DIR"
    # These fixed definitions are harness code, never product/startup code.
    declare -f file_stat file_mode file_identity file_links file_size
    declare -f _zdx_test_session_probe_decimal _zdx_test_session_probe_self \
      _zdx_test_session_probe_stat _zdx_test_session_probe_directory \
      _zdx_test_session_probe_data _zdx_test_session_probe_parent \
      _zdx_test_session_probe_publish
    sed 's/^@probe_test@/@test/' <<'BATS'
@probe_test@ "parallel NUL reader finishes" {
  local REPLY="" worker_pid=""
  _zdx_test_session_probe_self || return 1
  worker_pid=$REPLY
  _zdx_test_session_probe_publish "$worker_pid" || return 1
  printf 'entry\0' > "$BATS_TEST_TMPDIR/entries"
  run zsh -f -c 'emulate -R zsh
    while IFS= read -r -d "" entry; do
      print -r -- "$entry"
    done < "$1"
  ' _ "$BATS_TEST_TMPDIR/entries"
  [ "$status" -eq 0 ]
  [ "$output" = entry ]
}
BATS
  } > "$ZDX_TEST_SESSION_PROBE"
  # No outer BATS_* variable reaches the nested suite. Keep the mock-bin
  # first on PATH, so this never acquires a real external service.
  cat > "$TEST_TEMP_DIR/session-runner" <<'SH'
#!/bin/sh
exec env -i HOME="$HOME" PATH="$ZDX_TEST_NESTED_PATH" TERM="$TERM" LANG="$LANG" TMPDIR="$TMPDIR" \
  ZDX_TEST_SESSION_RECEIPT="$ZDX_TEST_SESSION_RECEIPT" \
  SHELL=/bin/sh BATS_JOBS=2 just --justfile "$ZDX_TEST_SESSION_JUSTFILE" \
  test --tap "$ZDX_TEST_SESSION_PROBE"
SH
  chmod -- 755 "$TEST_TEMP_DIR/session-runner"
  export ZDX_TEST_SESSION_JUSTFILE="$1"
  run timeout -k 2 20 script -qec "$TEST_TEMP_DIR/session-runner" /dev/null
  printf 'PTY status=%s\n%s\n' "$status" "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok 1 parallel NUL reader finishes"* ]]
}

@test "sandbox isolation: just test finishes parallel NUL readers on a controlling terminal" {
  _zdx_test_parallel_session_probe "$TEST_SUITE_ROOT/Justfile"
}

@test "sandbox isolation: just test's Perl session fallback finishes parallel NUL readers" {
  command -v perl >/dev/null || skip "requires Perl for the session fallback"
  # Exercise macOS's fallback on a Linux host without changing installed tools.
  perl -pe 's/if command -v setsid /if false /' "$TEST_SUITE_ROOT/Justfile" \
    > "$TEST_TEMP_DIR/Justfile"
  _zdx_test_parallel_session_probe "$TEST_TEMP_DIR/Justfile"
}

_zdx_test_prepare_bats_signal_probe() {
  cat > "$TEST_MOCK_BIN/bats" <<'ZSH'
#!/usr/bin/env zsh
emulate -R zsh
trap 'print -r -- INT > "$ZDX_TEST_SIGNAL_DIR/received"; exit 130' INT
trap 'print -r -- TERM > "$ZDX_TEST_SIGNAL_DIR/received"; exit 143' TERM
trap 'print -r -- HUP > "$ZDX_TEST_SIGNAL_DIR/received"; exit 129' HUP
print -r -- "$PPID" > "$ZDX_TEST_SIGNAL_DIR/recipe.pid"
print -r -- "$$" > "$ZDX_TEST_SIGNAL_DIR/bats.pid"
while true; do sleep 0.05; done
ZSH
  chmod -- 755 "$TEST_MOCK_BIN/bats"
  # Start just without an async shell's ignored SIGINT, then signal the
  # recipe after BATS has installed its trap. Bound readiness and shutdown,
  # and reap the controller's child even when the old recipe fails.
  cat > "$TEST_TEMP_DIR/forward.pl" <<'PERL'
use strict;
use warnings;
use POSIX qw(WNOHANG);
my ($justfile, $dir, $signal, $early) = @ARGV;
my $startup = $early && $early ne 'worker';
my $child = fork();
die "fork: $!" unless defined $child;
if (!$child) {
  $SIG{INT} = 'DEFAULT';
  exec 'env', '-i', "HOME=$ENV{HOME}", "PATH=$ENV{PATH}",
    "TERM=$ENV{TERM}", "LANG=$ENV{LANG}", "TMPDIR=$ENV{TMPDIR}",
    "ZDX_TEST_SIGNAL_DIR=$dir", "ZDX_TEST_REAL_SETSID=" . ($ENV{ZDX_TEST_REAL_SETSID} // ''),
    "ZDX_TEST_REAL_BATS=" . ($ENV{ZDX_TEST_REAL_BATS} // ''),
    "ZDX_TEST_WORKER_PROBE=" . ($ENV{ZDX_TEST_WORKER_PROBE} // ''), 'BATS_JOBS=1',
    'just', '--justfile', $justfile, 'test';
  die "exec: $!";
}
sub read_pid {
  my ($name) = @_;
  open my $fh, '<', "$dir/$name.pid" or return;
  my $pid = <$fh>;
  return unless defined $pid && $pid =~ /\A\s*([1-9][0-9]*)\s*\z/;
  return $1;
}
my ($bats, $recipe, $reaped, $rc, $worker);
my $ok = eval {
  local $SIG{ALRM} = sub { die "signal controller timed out\n"; };
  alarm 15;
  until (($bats = read_pid($startup ? 'launcher' : 'bats')) && ($recipe = read_pid('recipe'))
    && (!$startup || $early ne 'pid' || -f "$dir/pid-gap")
    && (!$early || $early ne 'worker' || ($worker = read_pid('worker')))) {
    select undef, undef, undef, 0.05;
  }
  kill $signal, $recipe or die "signal recipe: $!\n";
  if ($startup) {
    # The scratch recipe acknowledges its trap before either startup barrier
    # is released, so this is an observed startup gap rather than a sleep race.
    until (-f "$dir/recipe.signal") { select undef, undef, undef, 0.01; }
    open my $release, '>', "$dir/release" or die "release launcher: $!";
    close $release;
  }
  until (($reaped = waitpid($child, WNOHANG)) == $child) {
    select undef, undef, undef, 0.05;
  }
  $rc = $?;
  die "recipe returned success\n" unless $rc;
  unless ($early) {
    open my $received, '<', "$dir/received" or die "BATS did not receive $signal\n";
    my $observed = <$received>;
    die "BATS received the wrong signal\n" unless $observed eq "$signal\n";
  }
  die "BATS still runs after recipe exit\n" if kill 0, $bats;
  # Signal delivery and orphan reaping can finish after the BATS leader.
  # Keep the existing controller alarm as the overall bound.
  if ($worker) {
    for (1..100) {
      last unless kill(0, $worker);
      select undef, undef, undef, 0.02;
    }
  }
  die "parallel BATS worker survived interruption\n" if $worker && kill(0, $worker);
  alarm 0;
  1;
};
my $error = $@;
alarm 0;
if ($worker && kill(0, $worker)) {
  my $group = read_pid('worker-group');
  kill 'KILL', -$group if $group && $group != POSIX::getpgrp();
  kill 'KILL', $worker;
}
kill 'KILL', $bats if $bats && kill(0, $bats);
unless ($reaped && $reaped == $child) {
  kill 'KILL', $child;
  waitpid $child, 0;
}
die $error unless $ok;
print "recipe=nonzero signal=$signal bats=stopped\n";
PERL
}

@test "sandbox isolation: just test forwards INT, TERM, and HUP to BATS and waits for exit" {
  command -v just >/dev/null || skip "requires just"
  command -v perl >/dev/null || skip "requires Perl for the bounded signal controller"
  _zdx_test_prepare_bats_signal_probe
  local signal
  for signal in INT TERM HUP; do
    export ZDX_TEST_SIGNAL_DIR="$TEST_TEMP_DIR/signal-$signal"
    mkdir "$ZDX_TEST_SIGNAL_DIR"
    run perl "$TEST_TEMP_DIR/forward.pl" "$TEST_SUITE_ROOT/Justfile" "$ZDX_TEST_SIGNAL_DIR" "$signal"
    [ "$status" -eq 0 ]
    [[ "$output" == *"recipe=nonzero signal=$signal bats=stopped"* ]]
  done
}

_zdx_test_early_bats_signal_probe() {
  command -v just >/dev/null || skip "requires just"
  command -v perl >/dev/null || skip "requires Perl for the bounded signal controller"
  command -v setsid >/dev/null || skip "requires setsid for the delayed session launcher"
  export ZDX_TEST_REAL_SETSID
  ZDX_TEST_REAL_SETSID=$(command -v setsid)
  _zdx_test_prepare_bats_signal_probe
  cat > "$TEST_MOCK_BIN/setsid" <<'ZSH'
#!/usr/bin/env zsh
emulate -R zsh
# A startup launcher can inherit an ignored INT. Retain the signal at the
# recipe until a group exists even if its first PID delivery is ignored.
trap ':' INT TERM HUP
print -r -- "$PPID" > "$ZDX_TEST_SIGNAL_DIR/recipe.pid"
print -r -- "$$" > "$ZDX_TEST_SIGNAL_DIR/launcher.pid"
while [[ ! -f "$ZDX_TEST_SIGNAL_DIR/release" ]]; do sleep 0.01; done
exec "$ZDX_TEST_REAL_SETSID" "$@"
ZSH
  chmod -- 755 "$TEST_MOCK_BIN/setsid"
  local gap="$1" signal
    # Acknowledge entry into the real trap without changing its behavior.
    # The pid case holds assignment after launch to expose that separate gap.
    ZDX_TEST_GAP="$gap" perl -pe '
      s/'\'' (INT|TERM|HUP)$/; print -r -- trapped > "\$ZDX_TEST_SIGNAL_DIR\/recipe.signal"'\'' $1/;
      if ($ENV{ZDX_TEST_GAP} eq "pid" && /^    bats_pid=\$!$/) {
        print "    print -r -- held > \"\$ZDX_TEST_SIGNAL_DIR/pid-gap\"\n";
        print "    while [[ ! -f \"\$ZDX_TEST_SIGNAL_DIR/release\" ]]; do sleep 0.01; done\n";
      }
    ' "$TEST_SUITE_ROOT/Justfile" > "$TEST_TEMP_DIR/Justfile-$gap"
    for signal in INT TERM HUP; do
      export ZDX_TEST_SIGNAL_DIR="$TEST_TEMP_DIR/early-$gap-$signal"
      mkdir "$ZDX_TEST_SIGNAL_DIR"
      run perl "$TEST_TEMP_DIR/forward.pl" "$TEST_TEMP_DIR/Justfile-$gap" "$ZDX_TEST_SIGNAL_DIR" "$signal" "$gap"
      [ "$status" -eq 0 ]
      [[ "$output" == *"recipe=nonzero signal=$signal bats=stopped"* ]]
    done
}

@test "sandbox isolation: just test retains signals before session creation" {
  _zdx_test_early_bats_signal_probe group
}

@test "sandbox isolation: just test retains signals before PID assignment" {
  _zdx_test_early_bats_signal_probe pid
}

@test "sandbox isolation: just test preserves a failing BATS status through both session runners" {
  command -v just >/dev/null || skip "requires just"
  command -v perl >/dev/null || skip "requires Perl to select its fallback"
  printf '#!%s\nprintf "[%%s]" "$@"\nprintf "\\n"\nexit 23\n' "$BASH" \
    > "$TEST_MOCK_BIN/bats"
  chmod -- 755 "$TEST_MOCK_BIN/bats"
  perl -pe 's/if command -v setsid /if false /' "$TEST_SUITE_ROOT/Justfile" \
    > "$TEST_TEMP_DIR/Justfile-perl"
  local justfile
  for justfile in "$TEST_SUITE_ROOT/Justfile" "$TEST_TEMP_DIR/Justfile-perl"; do
    run env BATS_JOBS=1 just --justfile "$justfile" test --tap 'test/path with spaces.bats'
    [ "$status" -eq 23 ]
    [[ "$output" == *'[--print-output-on-failure][--tap][test/path with spaces.bats]'* ]]
  done
}

@test "sandbox isolation: interrupting just test stops a real GNU parallel BATS worker" {
  command -v just >/dev/null || skip "requires just"
  command -v perl >/dev/null || skip "requires Perl for the bounded signal controller"
  [[ "$(parallel --version 2>/dev/null)" == "GNU parallel"* ]] || skip "requires GNU parallel"
  export ZDX_TEST_REAL_BATS="$BATS_ROOT/bin/bats"
  [[ -x "$ZDX_TEST_REAL_BATS" ]] || skip "requires the public BATS launcher"
  _zdx_test_prepare_bats_signal_probe
  export ZDX_TEST_WORKER_PROBE="$TEST_TEMP_DIR/worker.bats"
  sed 's/^@probe_test@/@test/' > "$ZDX_TEST_WORKER_PROBE" <<'BATS'
#!/usr/bin/env bats
@probe_test@ "worker waits for interruption" {
  trap 'exit 130' INT
  trap 'exit 143' TERM
  ps -p "$BASHPID" -o pgid= > "$ZDX_TEST_SIGNAL_DIR/worker-group.pid"
  printf '%s\n' "$BASHPID" > "$ZDX_TEST_SIGNAL_DIR/worker.pid"
  while true; do sleep 0.05; done
}
BATS
  cat > "$TEST_MOCK_BIN/bats" <<'ZSH'
#!/usr/bin/env zsh
emulate -R zsh
print -r -- "$PPID" > "$ZDX_TEST_SIGNAL_DIR/recipe.pid"
print -r -- "$$" > "$ZDX_TEST_SIGNAL_DIR/bats.pid"
exec "$ZDX_TEST_REAL_BATS" --jobs 2 --tap "$ZDX_TEST_WORKER_PROBE"
ZSH
  chmod -- 755 "$TEST_MOCK_BIN/bats"
  local signal
  for signal in INT TERM; do
    export ZDX_TEST_SIGNAL_DIR="$TEST_TEMP_DIR/worker-$signal"
    mkdir "$ZDX_TEST_SIGNAL_DIR"
    run perl "$TEST_TEMP_DIR/forward.pl" "$TEST_SUITE_ROOT/Justfile" "$ZDX_TEST_SIGNAL_DIR" "$signal" worker
    [ "$status" -eq 0 ]
    [[ "$output" == *"recipe=nonzero signal=$signal bats=stopped"* ]]
  done
}

@test "sandbox isolation: inherited Git hook variables never reach fixture repositories" {
  local guarded_repo="$TEST_TEMP_DIR/guarded"
  git init -q -b main "$guarded_repo"
  git -C "$guarded_repo" config user.name "Guarded Owner"

  # Model a pre-push hook in a linked worktree, which exports GIT_DIR and
  # friends; loading the helper must clear every repository-local variable.
  run env \
    GIT_DIR="$guarded_repo/.git" \
    GIT_WORK_TREE="$guarded_repo" \
    GIT_INDEX_FILE="$guarded_repo/.git/index" \
    GIT_COMMON_DIR="$guarded_repo/.git" \
    bash -c '
      source "$1/test/test_helper.bash" || exit 90
      fixture="$TEST_TEMP_DIR/fixture"
      git init -q -b main "$fixture" || exit 91
      git -C "$fixture" config user.name "Fixture User" || exit 92
      leaked=$(env | grep -cE "^GIT_(DIR|WORK_TREE|INDEX_FILE|COMMON_DIR)=")
      rm -rf -- "$TEST_TEMP_DIR"
      [[ "$leaked" == 0 ]] || exit 93
    ' _ "$TEST_SUITE_ROOT"

  [ "$status" -eq 0 ]
  [ "$(git -C "$guarded_repo" config user.name)" = "Guarded Owner" ]
  [ "$(git -C "$guarded_repo" config --get core.bare)" = "false" ]
}

@test "sandbox isolation: a symlinked TMPDIR parent still yields a canonical sandbox" {
  # Model macOS, whose per-user TMPDIR is reached through /var -> private/var.
  local real_parent="$TEST_TEMP_DIR/private/var/folders/zz/T"
  mkdir -p "$real_parent"
  ln -s private/var "$TEST_TEMP_DIR/var"

  run env TMPDIR="$TEST_TEMP_DIR/var/folders/zz/T/" bash -c '
    source "$1/test/test_helper.bash" || exit 90
    canonical=$(cd "$TEST_TEMP_DIR" && pwd -P) || exit 91
    [[ "$TEST_TEMP_DIR" == "$canonical" ]] || exit 92
    [[ "$TEST_TEMP_DIR" == "$2"/zdx-tests.* ]] || exit 93
    [[ "$HOME" == "$TEST_TEMP_DIR/home" ]] || exit 94
    [[ "$TMPDIR" == "$TEST_TEMP_DIR/tmpdir" ]] || exit 95
    [[ "$(file_mode "$TMPDIR")" == 700 ]] || exit 96
    cleanup_sandbox || exit 97
    [[ ! -e "$canonical" ]] || exit 98
  ' _ "$TEST_SUITE_ROOT" "$real_parent"

  [ "$status" -eq 0 ]
}

@test "sandbox isolation: tests get a private TMPDIR and no host Git or SSH configuration" {
  [ "$TEST_TEMP_DIR" = "$(cd "$TEST_TEMP_DIR" && pwd -P)" ]
  [ "$TMPDIR" = "$TEST_TEMP_DIR/tmpdir" ]
  [ "$(file_mode "$TMPDIR")" = 700 ]
  [ "$GIT_CONFIG_NOSYSTEM" = 1 ]

  run ssh -G -- github-alias
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\nhostname github-alias\n'* ]]

  run ssh -o BatchMode=yes git@github.com
  [ "$status" -eq 97 ]
}

@test "sandbox isolation: the caller's locale, terminal, color, fzf, and ZDX settings never reach a test" {
  # A real plugin outside the sandbox, as a caller's ZDX_PLUGINS_DIR names it.
  local developer="$TEST_TEMP_DIR/developer"
  mkdir -p "$developer/plugins/devplug"
  chmod -- 700 "$developer" "$developer/plugins" "$developer/plugins/devplug"
  printf '%s\n' 'print -r -- developer-plugin-ran >> "$DEVPLUG_MARKER"' \
    'devplug-menu() { :; }' > "$developer/plugins/devplug/devplug-menu.zsh"
  chmod -- 600 "$developer/plugins/devplug/devplug-menu.zsh"
  export DEVPLUG_MARKER="$TEST_TEMP_DIR/devplug.marker"
  cat > "$TEST_TEMP_DIR/probe.zsh" <<'ZSH'
local text=$'\303\251' colors=plain
[[ "$(_zdx_fzf_color_opts)" == --no-color ]] || colors=color
print -r -- "locale=${LANG-unset} chars=${#text}"
print -r -- "overrides=${LC_ALL-unset},${LC_CTYPE-unset},${LC_COLLATE-unset},${LC_MESSAGES-unset},${LANGUAGE-unset}"
print -r -- "terminal=${TERM-unset},${NO_COLOR-unset},${COLORTERM-unset} fzf-colors=$colors"
print -r -- "fzf=${FZF_DEFAULT_OPTS-unset},${FZF_DEFAULT_OPTS_FILE-unset},${FZF_DEFAULT_COMMAND-unset}"
print -r -- "zdx=${ZDX_FZF_PLAIN-unset},${ZDX_VERBOSE-unset},${ZDX_TELEMETRY-unset},${ZDX_EAGER_LOAD-unset},${ZDX_FZF_TEMPLATES-unset},${ZDX_PLUGINS_DIR-unset}"
print -r -- "plugin=${+functions[devplug-menu]} discovered=${#ZDX_DISCOVERED_PLUGINS}"
ZSH

  # The caller's shell is as hostile as a developer's can be: a C locale
  # with every override, a dumb terminal, color and fzf settings, and suite
  # settings that would load the plugin above eagerly.
  run env LC_ALL=C LC_CTYPE=C LC_COLLATE=C LC_MESSAGES=C LANG=C LANGUAGE=es \
    TERM=dumb NO_COLOR=1 COLORTERM=truecolor \
    FZF_DEFAULT_OPTS=--no-unicode FZF_DEFAULT_OPTS_FILE="$developer/fzfrc" \
    FZF_DEFAULT_COMMAND=false \
    ZDX_FZF_PLAIN=1 ZDX_VERBOSE=1 ZDX_TELEMETRY=1 ZDX_EAGER_LOAD=1 \
    ZDX_FZF_TEMPLATES=1 ZDX_PLUGINS_DIR="$developer/plugins" \
    "$BASH" -c '
      source "$1/test/test_helper.bash" || exit 90
      run_zsh "$(<"$2")"
      rc=$?
      cleanup_sandbox || exit 91
      exit "$rc"
    ' _ "$TEST_SUITE_ROOT" "$TEST_TEMP_DIR/probe.zsh"

  [ "$status" -eq 0 ]
  [ "$output" = "locale=$TEST_UTF8_LOCALE chars=1
overrides=unset,unset,unset,unset,unset
terminal=xterm-256color,unset,unset fzf-colors=color
fzf=unset,unset,unset
zdx=unset,unset,unset,unset,0,unset
plugin=0 discovered=0" ]
  [ ! -e "$DEVPLUG_MARKER" ]
}

@test "sandbox isolation: a caller's BASH_ENV, terminal, Git, uv, Python, suite, and tool settings never reach a test" {
  # BASH_ENV runs in every Bash that starts without a terminal, so it could
  # export again what the helper clears. It also brings LOCPATH and
  # PATH_LOCALE, because it runs after Bash's own startup setlocale: macOS
  # reads PATH_LOCALE once per process, at that first call, so in the startup
  # environment it would hide the locales from the whole inner Bash.
  local outside="$TEST_TEMP_DIR/outside"
  mkdir -p "$outside/hooks"
  printf '%s\n' 'export LC_ALL=C TERM=dumb NO_COLOR=1 ZDX_VERBOSE=1' \
    'export FZF_DEFAULT_OPTS=--no-unicode' \
    "export LOCPATH='$outside/LOCPATH' PATH_LOCALE='$outside/PATH_LOCALE'" \
    > "$outside/bash_env"
  # The caller's real global Git configuration, as GIT_CONFIG_GLOBAL names it:
  # a hook directory whose pre-commit hook leaves a marker, and an alias.
  printf '[core]\n\thooksPath = %s\n[alias]\n\tzdxleak = status\n' \
    "$outside/hooks" > "$outside/gitconfig"
  printf '#!/bin/sh\n: > "%s"\n' "$outside/hook-ran" > "$outside/hooks/pre-commit"
  chmod -- 755 "$outside/hooks/pre-commit"
  local -A hostile=([BASH_ENV]="$outside/bash_env" [ENV]="$outside/bash_env"
    [COLUMNS]=30 [LINES]=5 [FORCE_COLOR]=3 [CLICOLOR]=1 [CLICOLOR_FORCE]=1
    [DEV_SUITE_DEBUG]=1 [PY_SUITE_DEBUG]=1 [SYS_APT_AUTOMATIC_TAKEOVER]=1
    [WS_FETCH_JOBS]=7 [FILE_EXTRACT_MAX_GIB]=7
    [GIT_CONFIG_GLOBAL]="$outside/gitconfig" [GIT_AUTHOR_NAME]="Hostile Caller"
    [GIT_TRACE]="$outside/git-trace" [UV_INDEX_URL]=https://leak.invalid/simple)
  local name
  for name in TERMINFO TERMINFO_DIRS TERMCAP \
    VPN_CONFIG_DIR VPN_CACHE_DIR VPN_MENU_REPORT_DIR DEV_BACKUP_DIR \
    DEV_REPORT_DIR WS_BASE_DIR EDITOR VISUAL SUDO_EDITOR GIT_SSH \
    GIT_SSH_COMMAND GIT_TEMPLATE_DIR UV_CACHE_DIR PYTHONPATH PYTHONUSERBASE \
    VIRTUAL_ENV CONDA_PREFIX DISPLAY WAYLAND_DISPLAY CARGO_HOME RUSTUP_HOME; do
    hostile[$name]="$outside/$name"
  done
  local -a assignments=()
  PROBE_HOSTILE="LOCPATH=$outside/LOCPATH"$'\n'"PATH_LOCALE=$outside/PATH_LOCALE"$'\n'
  for name in "${!hostile[@]}"; do
    assignments+=("$name=${hostile[$name]}")
    PROBE_HOSTILE+="$name=${hostile[$name]}"$'\n'
  done
  export PROBE_HOSTILE

  # A commit in a fixture repository must not run the caller's hook, take the
  # caller's author, or see the caller's alias. A name leaks when it still
  # has the caller's value, in the Bash that loaded the helper or in a
  # run_zsh program. run_zsh exports its own WS_BASE_DIR, so only the first
  # check can catch that one.
  run env "${assignments[@]}" "$BASH" -c '
    source "$1/test/test_helper.bash" || exit 90
    "$BASH" -c '\''printf "bash-child=%s,%s,%s,%s,%s\n" "${LC_ALL-unset}" \
      "${TERM-unset}" "${NO_COLOR-unset}" "${ZDX_VERBOSE-unset}" \
      "${FZF_DEFAULT_OPTS-unset}"'\''
    fixture="$TEST_TEMP_DIR/fixture"
    git init -q -b main "$fixture" || exit 92
    git -C "$fixture" -c user.name="Fixture User" \
      -c user.email=fixture@example.invalid commit -q --allow-empty -m probe \
      || exit 93
    printf "git=%s|%s\n" "$(git -C "$fixture" log -1 --format=%an)" \
      "$(git -C "$fixture" config --get alias.zdxleak || echo none)"
    leaked=()
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      name=${line%%=*}
      [[ "${!name-}" == "${line#*=}" ]] && leaked+=("$name")
    done <<< "$PROBE_HOSTILE"
    printf "bash-leaked=%s\n" "${leaked[*]}"
    run_zsh '\''
      local -a leaked=()
      local line name
      for line in "${(@f)PROBE_HOSTILE}"; do
        [[ -n "$line" && "$line" != WS_BASE_DIR=* ]] || continue
        name=${line%%=*}
        [[ "${(P)name-}" == "${line#*=}" ]] && leaked+=("$name")
      done
      print -r -- "zsh-leaked=${(j:,:)${(@o)leaked}}"
    '\''
    rc=$?
    cleanup_sandbox || exit 91
    exit "$rc"
  ' _ "$TEST_SUITE_ROOT"

  [ "$status" -eq 0 ]
  [ "$output" = "bash-child=unset,xterm-256color,unset,unset,unset
git=Fixture User|none
bash-leaked=
zsh-leaked=" ]
  [ ! -e "$outside/hook-ran" ]
  [ ! -e "$outside/git-trace" ]
}

@test "sandbox isolation: run_zsh reads no startup file and starts from default options" {
  # The sandbox .zshenv stands in for any startup file a plain `zsh -c` reads.
  printf '%s\n' 'print -u2 -r -- STARTUP-FILE-READ' 'setopt no_glob' > "$HOME/.zshenv"

  # -f turns the rcs option off, so it is set again only when the program
  # restores the default options, as it must after a system zshenv ran.
  run run_zsh '
    [[ -o rcs ]] || exit 3
    [[ -o glob ]] || exit 4
    print -r -- body-ran
  '

  [ "$status" -eq 0 ]
  [ "$output" = body-ran ]
}

@test "sandbox isolation: every Zsh program a test starts skips startup files and resets its options" {
  # A line-based heuristic over test/*.bats and test/*.bash. It joins
  # backslash continuations, finds each launch of zsh (also /bin/zsh, "zsh",
  # or a variable such as $INSTALLER_ZSH) whose last option cluster ends in c,
  # requires f in one of those clusters, and requires a program written after
  # the option, in any quoting, to start with `emulate -R zsh`. It does not
  # see -cf, -ci, -o OPT -c, --no-rcs -c, or options held in a variable, and
  # it does not read a program held in a variable, printed by a function,
  # written to a file by a heredoc, or fed on standard input; those programs
  # start with `emulate -R zsh` by review. A string after =, ==, !=, =~, or *,
  # such as "zsh -c example", is not a launch. A test that must read startup
  # files puts a comment that starts with `# reads startup files:` and gives
  # the reason directly above the command; it exempts only the first launch
  # of that command. In a `run env X=1 \` command, the comment goes above the
  # `run` line, because a comment inside the continuation would end the
  # command.
  cat > "$TEST_TEMP_DIR/scan.pl" <<'PERL'
use strict;
use warnings;
my $quote = qr{'"'"'|'\\''|\$'|\\"|['"]};
my $command = qr{"zsh"|'zsh'|(?:[\w./-]*/)?zsh|"\$\(command -v zsh\)"|"?\$\{?[A-Z_]*ZSH[A-Z_]*\}?"?};
my $launch = qr{(?<![^\s;|&(`"'])(?:$command)((?:\s+-[A-Za-z]+)*?\s+-[A-Za-z]*c)(?=\s|$)};
my $violations = 0;
for my $file (@ARGV) {
  open my $handle, '<', $file or die "$file: $!\n";
  chomp(my @lines = <$handle>);
  close $handle;
  my $i = 0;
  while ($i <= $#lines) {
    my ($first, $text) = ($i, $lines[$i]);
    while ($i < $#lines && $text =~ s/\\$//) {
      $text .= ' ' . $lines[++$i];
    }
    my $last = $i++;
    next if $text =~ /^\s*#/;
    my $above = $first - 1;
    $above-- while $above > 0 && $lines[$above] =~ /^\s*$/;
    my $exempt = $above >= 0 && $lines[$above] =~ /^\s*# reads startup files: \S/;
    while ($text =~ /$launch/g) {
      my ($flags, $before, $rest) = ($1, substr($text, 0, $-[0]), substr($text, $+[0]));
      next if $before =~ /(?:[!=]=|=~|[=*])\s*["']$/;
      if ($exempt) {
        $exempt = 0;
        next;
      }
      my $where = "$file:" . ($first + 1);
      if ($flags !~ /-[A-Za-z]*f/) {
        print "$where: Zsh starts without -f\n";
        $violations++;
      }
      $rest =~ s/^\s+//;
      next unless $rest =~ s/^(?:$quote)//;
      if ($rest =~ /^\s*$/) {
        my $k = $last + 1;
        $k++ while $k < $#lines && $lines[$k] =~ /^\s*$/;
        ($rest = $k <= $#lines ? $lines[$k] : '') =~ s/^\s+//;
      }
      next if $rest =~ /^\$/;
      if ($rest !~ /^emulate -R zsh\b/) {
        print "$where: the program does not start with emulate -R zsh\n";
        $violations++;
      }
    }
  }
}
exit($violations ? 1 : 0);
PERL
  # Control: the scan reports each kind of violation in a fixture and skips
  # the compliant, variable, compared, and opted-in launches. The fixture
  # spells the command as @zsh@ here, so this file itself holds no launch.
  perl -pe 's/\@zsh\@/zsh/g' > "$TEST_TEMP_DIR/fixture.bats" <<'FIXTURE'
run @zsh@ -c "
  print missing-f
"
run @zsh@ -f -c "
  print missing-emulate
"
run @zsh@ -f -c 'print inline-missing-emulate'
run @zsh@ -f -c "
  emulate -R zsh
  print compliant
"
run @zsh@ -fc 'emulate -R zsh; print compliant-inline'
run @zsh@ -f -c "$program"
# reads startup files: the test checks what a sandbox .zshenv changes.
run @zsh@ -c "
  print opted-in
"
run /bin/@zsh@ -c 'print absolute-path'
run "@zsh@" -f -c 'print quoted-command'
run env PROBE=1 \
  @zsh@ \
  -f -c 'print continued'
run @zsh@ -f -c $'print ansi-c'
run run_zsh "@zsh@ -f -c \"print escaped\""
run @zsh@ -f -c $'emulate -R zsh\nprint ansi-c-compliant'
[[ "$output" == "@zsh@ -c example" ]]
[[ "$output" == *"@zsh@ -c example"* ]]
# reads startup files: the comment covers only the first launch below.
@zsh@ -c 'print first' && @zsh@ -c 'print second'
FIXTURE
  run perl "$TEST_TEMP_DIR/scan.pl" "$TEST_TEMP_DIR/fixture.bats"
  [ "$status" -eq 1 ]
  [ "$output" = "$TEST_TEMP_DIR/fixture.bats:1: Zsh starts without -f
$TEST_TEMP_DIR/fixture.bats:1: the program does not start with emulate -R zsh
$TEST_TEMP_DIR/fixture.bats:4: the program does not start with emulate -R zsh
$TEST_TEMP_DIR/fixture.bats:7: the program does not start with emulate -R zsh
$TEST_TEMP_DIR/fixture.bats:18: Zsh starts without -f
$TEST_TEMP_DIR/fixture.bats:18: the program does not start with emulate -R zsh
$TEST_TEMP_DIR/fixture.bats:19: the program does not start with emulate -R zsh
$TEST_TEMP_DIR/fixture.bats:20: the program does not start with emulate -R zsh
$TEST_TEMP_DIR/fixture.bats:23: the program does not start with emulate -R zsh
$TEST_TEMP_DIR/fixture.bats:24: the program does not start with emulate -R zsh
$TEST_TEMP_DIR/fixture.bats:29: Zsh starts without -f
$TEST_TEMP_DIR/fixture.bats:29: the program does not start with emulate -R zsh" ]

  run perl "$TEST_TEMP_DIR/scan.pl" "$TEST_SUITE_ROOT"/test/*.bats \
    "$TEST_SUITE_ROOT"/test/*.bash

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sandbox isolation: only a working UTF-8 locale passes the probe, and the environment cannot pick the candidates" {
  [ "$LANG" = "$TEST_UTF8_LOCALE" ]
  [ -z "${LC_ALL+set}" ]
  _zdx_test_locale_works "$TEST_UTF8_LOCALE"
  local name
  for name in C POSIX xx_YY.UTF-8; do
    run _zdx_test_locale_works "$name"
    [ "$status" -ne 0 ]
  done

  # Only a Bash array names the candidates, and an array never comes from
  # the environment: an exported value of the same name changes nothing.
  run env _zdx_test_locale_candidates=xx_YY.UTF-8 "$BASH" -c '
    source "$1/test/test_helper.bash" || exit 90
    printf "%s\n" "$LANG"
    cleanup_sandbox
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_UTF8_LOCALE" ]
}

@test "sandbox isolation: a host without a UTF-8 locale fails setup instead of testing under C" {
  # The candidates model such a host on every platform: C and POSIX are not
  # UTF-8, and the last name exists nowhere.
  local nested_tmp="$TEST_TEMP_DIR/nested-tmp"
  mkdir "$nested_tmp"
  run env TMPDIR="$nested_tmp" "$BASH" -c '
    _zdx_test_locale_candidates=(C POSIX xx_YY.UTF-8)
    source "$1/test/test_helper.bash"
    printf "helper-status=%s\n" "$?"
  ' _ "$TEST_SUITE_ROOT"

  [ "$status" -eq 0 ]
  [ "$output" = "test_helper: no UTF-8 locale works on this host; the tests do not run under C.
test_helper: install C.UTF-8 or en_US.UTF-8 (Debian and Ubuntu: apt install locales).
helper-status=1" ]
  # The helper stops before it creates a sandbox.
  [ -z "$(find "$nested_tmp" -mindepth 1 -print -quit)" ]
}

@test "sandbox isolation: portable metadata helpers describe the path itself" {
  local file="$TEST_TEMP_DIR/metadata"
  printf 'abc' > "$file"
  chmod 640 "$file"
  [ "$(file_mode "$file")" = 640 ]
  [ "$(file_size "$file")" = 3 ]
  [ "$(file_links "$file")" = 1 ]
  [ "$(file_owner_uid "$file")" = "$(id -u)" ]
  [ "$(file_identity "$file")" = "$(file_stat "$file" device inode)" ]
  [ "$(file_inode "$file")" = "$(file_stat "$file" inode)" ]
  [ "$(file_stat "$file" mode size)" = "640:3" ]

  ln "$file" "$file.hardlink"
  [ "$(file_links "$file")" = 2 ]
  [ "$(file_identity "$file.hardlink")" = "$(file_identity "$file")" ]
  ln -s "$file" "$file.symlink"
  [ "$(file_identity "$file.symlink")" != "$(file_identity "$file")" ]

  mkdir "$TEST_TEMP_DIR/sticky"
  chmod 1700 "$TEST_TEMP_DIR/sticky"
  [ "$(file_mode "$TEST_TEMP_DIR/sticky")" = 1700 ]
  run file_mode "$TEST_TEMP_DIR/missing"
  [ "$status" -ne 0 ]
  [[ "$output" != [0-7]* ]]
}

@test "sandbox isolation: portable content helpers replace sha256sum and truncate" {
  local file="$TEST_TEMP_DIR/content"
  printf 'abc' > "$file"
  [ "$(sha256_file "$file")" = \
    ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad ]

  make_sized_file "$file" 5
  [ "$(file_size "$file")" = 5 ]
  [ "$(head -c 3 "$file")" = abc ]
  make_sized_file "$file" 2
  [ "$(cat "$file")" = ab ]
  make_sized_file "$TEST_TEMP_DIR/created" 1048577
  [ "$(file_size "$TEST_TEMP_DIR/created")" = 1048577 ]
}

@test "sandbox isolation: the Zsh assertion guard reports each supported literal form" {
  run python3 -I "$TEST_SUITE_ROOT/test/zsh_assertions.py" \
    "$TEST_SUITE_ROOT/test/fixtures/zsh-assertions.txt"

  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 18 ]
  [[ "${lines[0]}" == *':4: unchecked non-final Zsh assertion: [[ A == B ]]' ]]
  [[ "${lines[1]}" == *':8: unchecked non-final Zsh assertion: [[ "A" == B ]]' ]]
  [[ "${lines[2]}" == *':11: unchecked non-final Zsh assertion: [ A = B ]' ]]
  [[ "${lines[3]}" == *':12: unchecked non-final Zsh assertion: test A = B' ]]
  [[ "${lines[4]}" == *':17: unchecked non-final Zsh assertion: [[ A == B ]]' ]]
  [[ "${lines[5]}" == *':22: unchecked non-final Zsh assertion: (( count > 0 ))' ]]
  [[ "${lines[6]}" == *':25: unchecked non-final Zsh assertion: grep -qE pattern file' ]]
  [[ "${lines[7]}" == *':26: unchecked non-final Zsh assertion: ! helper-command' ]]
  [[ "${lines[8]}" == *':27: unchecked non-final Zsh assertion: [[ A == B && C == D ]]' ]]
  [[ "${lines[9]}" == *':43: unchecked non-final Zsh assertion: [[ A == B ]]' ]]
  [[ "${lines[10]}" == *':44: unchecked non-final Zsh assertion: [[ A == B ]]' ]]
  [[ "${lines[11]}" == *':45: unchecked non-final Zsh assertion: grep -q "left||right" file' ]]
  [[ "${lines[12]}" == *':46: unchecked non-final Zsh assertion: test A = "left&&right"' ]]
  [[ "${lines[13]}" == *':56: unchecked non-final Zsh assertion: [[ A == B ]]' ]]
  [[ "${lines[14]}" == *':60: unchecked non-final Zsh assertion: [[ A == B ]]' ]]
  [[ "${lines[15]}" == *':62: unchecked non-final Zsh assertion: [[ A == B ]]' ]]
  [[ "${lines[16]}" == *':68: unchecked non-final Zsh assertion: [[ A == B ]]' ]]
  [[ "${lines[17]}" == *':74: unchecked non-final Zsh assertion: [[ A == B ]]' ]]
}

@test "sandbox isolation: literal Zsh programs handle every non-final assertion" {
  run python3 -I "$TEST_SUITE_ROOT/test/zsh_assertions.py" \
    "$TEST_SUITE_ROOT"/test/*.bats "$TEST_SUITE_ROOT"/test/*.bash

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
