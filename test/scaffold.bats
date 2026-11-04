#!/usr/bin/env bats

# The surface checker and command generator run against a private copy of the
# repository, never the tree under test. The scenarios use the Python and
# Developer suites; any suite whose layout follows the same contract works.

setup() {
  load test_helper
  SCAFFOLD_REPO="$TEST_TEMP_DIR/repo"
  mkdir -p "$SCAFFOLD_REPO/docs"
  cp -R "$TEST_SUITE_ROOT/functions" "$TEST_SUITE_ROOT/completions" \
    "$TEST_SUITE_ROOT/scripts" "$TEST_SUITE_ROOT/test" \
    "$TEST_SUITE_ROOT/functions.zsh" "$SCAFFOLD_REPO/"
  cp "$TEST_SUITE_ROOT"/docs/*.md "$SCAFFOLD_REPO/docs/"
  SURFACE_TOOL="$SCAFFOLD_REPO/scripts/command-surface.zsh"
  SURFACE_OUT="$TEST_TEMP_DIR/surface.out"
  SURFACE_ERR="$TEST_TEMP_DIR/surface.err"
  # run_zsh sources the runtime below TEST_SUITE_ROOT: point it at the copy.
  TEST_SUITE_ROOT="$SCAFFOLD_REPO"
}

teardown() {
  cleanup_sandbox
}

# Runs the tool from the copy with separate streams; SURFACE_STATUS keeps the
# status so a failing run does not stop the test.
surface() {
  SURFACE_STATUS=0
  zsh -f "$SURFACE_TOOL" "$@" >"$SURFACE_OUT" 2>"$SURFACE_ERR" \
    || SURFACE_STATUS=$?
}

snapshot_copy() {
  rm -rf "$TEST_TEMP_DIR/snapshot"
  cp -R "$SCAFFOLD_REPO" "$TEST_TEMP_DIR/snapshot"
}

assert_copy_unchanged() {
  diff -r "$TEST_TEMP_DIR/snapshot" "$SCAFFOLD_REPO"
}

# Generates the Python scenario command tool-probe after tool-upgrade.
generate_tool_probe() {
  surface new --after tool-upgrade --capability tool \
    --label "Probe Tool Backend" \
    --description "Show which backend owns one isolated tool." \
    "$@" py tool-probe py-tools.zsh read-only
}

@test "surfaces: suites with complete surfaces pass with a row per command" {
  surface check py dev

  [ "$SURFACE_STATUS" -eq 0 ]
  head -n 1 "$SURFACE_OUT" | grep -Eq '^SUITE +COMMAND +FN +DISP +MENU +HELP +COMP +BIND +LAZY +ALLOW +DOC +GUIDE$'
  grep -Eq '^py +venv-create +ok +ok +ok +ok +ok +ok +ok +ok +ok +ok$' "$SURFACE_OUT"
  # Developer binds and lazily registers its commands but has no interactive
  # allowlist, so that column does not apply.
  grep -Eq '^dev +dev-run-tests +ok +ok +ok +ok +ok +ok +ok +- +ok +ok$' "$SURFACE_OUT"
  grep -Eq '^py +[0-9]+ +ok +ok +ok +ok +ok +ok$' "$SURFACE_OUT"
  grep -Fq ' 0 problems,' "$SURFACE_ERR"
}

@test "surfaces: unknown suites and options are invalid arguments" {
  surface check nosuite
  [ "$SURFACE_STATUS" -eq 2 ]
  grep -Fq 'unknown suite "nosuite"' "$SURFACE_ERR"
  [ ! -s "$SURFACE_OUT" ]

  surface check --bogus
  [ "$SURFACE_STATUS" -eq 2 ]
}

@test "surfaces: a removed or orphaned surface fails with a file hint" {
  perl -ni -e 'print unless /^\s+dev-run-tests\) dev-run-tests "\$\@" ;;$/' \
    "$SCAFFOLD_REPO/functions/dev-common.zsh"
  perl -ni -e "print unless /^\\s+'dev-run-bandit:/" \
    "$SCAFFOLD_REPO/completions/_dev-menu"
  perl -pi -e 's/^(\s+)dev-run-audit\) dev-run-audit "\$\@" ;;$/$&\n$1dev-run-orphan) dev-run-orphan "\$\@" ;;/' \
    "$SCAFFOLD_REPO/functions/dev-common.zsh"

  surface check dev

  [ "$SURFACE_STATUS" -eq 1 ]
  grep -Eq '^dev +dev-run-tests +ok +MISS +ok' "$SURFACE_OUT"
  grep -Eq '^dev +dev-run-bandit +ok +ok +ok +ok +MISS' "$SURFACE_OUT"
  grep -Eq '^surfaces: dev/dev-run-tests: no dispatcher arm in _dev_dispatch \(functions/dev-common\.zsh:[0-9]+\)$' "$SURFACE_ERR"
  grep -Eq '^surfaces: dev/dev-run-bandit: no completion entry in subcmds \(completions/_dev-menu:[0-9]+\)$' "$SURFACE_ERR"
  grep -Eq '^surfaces: dev/dev-run-orphan: dispatcher arm without a fixture row \(functions/dev-common\.zsh:[0-9]+\)$' "$SURFACE_ERR"
  grep -Fq ' 3 problems,' "$SURFACE_ERR"
}

@test "new-command: a dry run prints the planned edits and writes nothing" {
  snapshot_copy

  generate_tool_probe --dry-run

  [ "$SURFACE_STATUS" -eq 0 ]
  [ ! -s "$SURFACE_ERR" ]
  grep -Fq 'Planned edits (dry run; nothing is written):' "$SURFACE_OUT"
  grep -Fq "    + tool-probe"$'\t'"py-tools.zsh"$'\t'"read-only"$'\t'"tool" "$SURFACE_OUT"
  grep -Fq '    + tool-probe() {' "$SURFACE_OUT"
  grep -Fq "    +   'tool-probe:Show which backend owns one isolated tool'" "$SURFACE_OUT"
  grep -Fq 'Remaining manual surfaces for tool-probe:' "$SURFACE_OUT"
  assert_copy_unchanged
}

@test "new-command: the uniform surfaces are wired and only manual ones remain" {
  local menu="$SCAFFOLD_REPO/functions/py-menu.zsh"
  local module="$SCAFFOLD_REPO/functions/py/py-tools.zsh"
  local mode_before
  mode_before=$(file_mode "$menu")

  generate_tool_probe

  [ "$SURFACE_STATUS" -eq 0 ]
  [ ! -s "$SURFACE_ERR" ]
  [ "$(file_mode "$menu")" = "$mode_before" ]
  # No temporary file is left beside a replaced file.
  [ -z "$(find "$SCAFFOLD_REPO" -name '.*.??????' -print)" ]

  # Fixture: the unsorted Python fixture keeps the row next to its anchor.
  [ "$(tail -n 1 "$SCAFFOLD_REPO/test/fixtures/py-public-commands.tsv")" = \
    $'tool-probe\tpy-tools.zsh\tread-only\ttool' ]
  # Stub: a documented public function before the module sentinel.
  grep -Fxq 'tool-probe() {' "$module"
  grep -Fxq '_py_tool_probe_usage() {' "$module"
  grep -Fxq '#   Effects:   read-only; not implemented yet.' "$module"
  [ "$(tail -n 1 "$module")" = 'typeset -g _PY_TOOLS_SOURCED=1' ]
  # Uniform surfaces follow the anchor in each file.
  grep -A1 -E '^    tool-upgrade\) ' "$menu" | grep -Fxq '    tool-probe)          tool-probe "$@" ;;'
  grep -A1 -Fx '  print -u2 -r -- "  tool-upgrade"' "$menu" \
    | grep -Fxq '  print -u2 -r -- "  tool-probe"'
  grep -Fxq '    tool-probe|\' "$menu"
  # The record joins tool-upgrade's block, which the read-only view omits.
  grep -B1 -Fx '      "Probe Tool Backend" "tool-probe" \' "$menu" \
    | grep -Fxq '    row=$(_py_menu_entry \'
  head -n 1 "$SCAFFOLD_REPO/completions/_py-menu" | grep -Eq ' tool-upgrade tool-probe( |$)'
  grep -Fxq "  'tool-probe:Show which backend owns one isolated tool'" \
    "$SCAFFOLD_REPO/completions/_py-menu"
  grep -Fxq '  tool-probe py-menu.zsh' "$SCAFFOLD_REPO/functions.zsh"

  local changed
  for changed in "$menu" "$module" "$SCAFFOLD_REPO/functions.zsh" \
    "$SCAFFOLD_REPO/completions/_py-menu"; do
    zsh -n "$changed"
  done

  # The checklist names the manual surfaces with file and line.
  grep -Eq '^     functions/py/py-tools\.zsh:[0-9]+$' "$SURFACE_OUT"
  grep -Fq 'Document it in the suite contract (docs/py-menu.md)' "$SURFACE_OUT"
  grep -Eq '^     docs/user-guide\.md:[0-9]+: ## .*\(`py-menu`\)' "$SURFACE_OUT"
  grep -Eq '^     test/py_contract\.bats:[0-9]+: \[ "\$count" -eq [0-9]+ \]$' "$SURFACE_OUT"

  # The checker reports only the documented manual surfaces.
  surface check py
  [ "$SURFACE_STATUS" -eq 1 ]
  grep -Eq '^py +tool-probe +ok +ok +ok +ok +ok +ok +ok +ok +MISS +warn$' "$SURFACE_OUT"
  grep -Eq '^py +[0-9]+ +ok +ok +ok +ok +ok +MISS$' "$SURFACE_OUT"
  grep -Fxq 'surfaces: py/tool-probe: not documented in docs/py-menu.md' "$SURFACE_ERR"
  grep -Fxq 'surfaces: warning: py/tool-probe: not mentioned in docs/user-guide.md' "$SURFACE_ERR"
  grep -Eq '^surfaces: py: test/py_contract\.bats:[0-9]+ freezes [0-9]+ commands; the fixture has [0-9]+$' "$SURFACE_ERR"
  grep -Fq ' 2 problems, 1 warning.' "$SURFACE_ERR"
}

@test "surfaces: finishing the manual surfaces passes, and --strict needs the guide" {
  generate_tool_probe
  [ "$SURFACE_STATUS" -eq 0 ]

  printf '\nThe `tool-probe` command reports the owning backend.\n' \
    >>"$SCAFFOLD_REPO/docs/py-menu.md"
  local count
  count=$(awk -F '\t' '!/^#/ && NF' "$SCAFFOLD_REPO/test/fixtures/py-public-commands.tsv" | wc -l)
  COUNT=$((count)) perl -pi -e 's/\[ "\$count" -eq \d+ \]/[ "\$count" -eq $ENV{COUNT} ]/' \
    "$SCAFFOLD_REPO/test/py_contract.bats"

  surface check py
  [ "$SURFACE_STATUS" -eq 0 ]
  grep -Fq ' 0 problems, 1 warning.' "$SURFACE_ERR"

  surface check --strict py
  [ "$SURFACE_STATUS" -eq 1 ]

  printf '\nUse `tool-probe` to see which backend owns a tool.\n' \
    >>"$SCAFFOLD_REPO/docs/user-guide.md"
  surface check --strict py
  [ "$SURFACE_STATUS" -eq 0 ]
  grep -Eq '^py +tool-probe +ok +ok +ok +ok +ok +ok +ok +ok +ok +ok$' "$SURFACE_OUT"
}

@test "new-command: the generated command runs through the suite runtime" {
  generate_tool_probe
  [ "$SURFACE_STATUS" -eq 0 ]

  run run_zsh 'tool-probe --help'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: tool-probe [-h|--help]"* ]]
  [[ "$output" == *"Show which backend owns one isolated tool."* ]]

  run run_zsh 'py-menu tool-probe'
  [ "$status" -eq 1 ]
  [[ "$output" == *"tool-probe is not implemented yet."* ]]

  run run_zsh 'py-menu tool-probe --bogus'
  [ "$status" -eq 2 ]

  run run_zsh '
    _py_command_is_canonical tool-probe || return 3
    py-menu --help 2>&1 | command grep -Fxq "  tool-probe" || return 4
    _py_menu_rows | command grep -Fq "|tool-probe|Show which backend owns one isolated tool." \
      || return 5
  '
  [ "$status" -eq 0 ]

  # A cold shell resolves the new lazy stub.
  run zsh -f -c '
    emulate -R zsh
    unset TEST_TEMP_DIR BATS_TEST_DIRNAME
    export ZSH_CUSTOM="$1" HOME="$2"
    source "$ZSH_CUSTOM/functions.zsh" || exit 1
    (( ${+_ZDX_LAZY_FILES[tool-probe]} )) || exit 3
    tool-probe --help
  ' _ "$SCAFFOLD_REPO" "$HOME"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: tool-probe"* ]]
}

@test "new-command: a list-style suite extends its help line and menu record" {
  surface new --after dev-run-coverage \
    --label "Run Probe Checks" --description "Run the probe checks over the project." \
    dev dev-run-probe dev-checks.zsh read-only

  [ "$SURFACE_STATUS" -eq 0 ]
  grep -Fxq '  print -u2 -r -- "  dev-run-tests, dev-run-coverage, dev-run-probe"' \
    "$SCAFFOLD_REPO/functions/dev-menu.zsh"
  grep -A1 -Fx '    dev-run-coverage) dev-run-coverage "$@" ;;' \
    "$SCAFFOLD_REPO/functions/dev-common.zsh" \
    | grep -Fxq '    dev-run-probe) dev-run-probe "$@" ;;'
  grep -B1 -Fx '    "Run Probe Checks" "dev-run-probe" \' \
    "$SCAFFOLD_REPO/functions/dev-menu.zsh" | grep -Fxq '  _dev_menu_entry \'
  # The sorted Developer fixture stays sorted.
  run -0 awk -F '\t' '!/^#/ && NF { print $1 }' \
    "$SCAFFOLD_REPO/test/fixtures/dev-public-commands.tsv"
  [ "$output" = "$(printf '%s\n' "${lines[@]}" | LC_ALL=C sort)" ]
  [[ "$output" == *"dev-run-probe"* ]]

  surface check dev
  [ "$SURFACE_STATUS" -eq 1 ]
  grep -Eq '^dev +dev-run-probe +ok +ok +ok +ok +ok +ok +ok +- +MISS +warn$' "$SURFACE_OUT"
  grep -Fq ' 2 problems, 1 warning.' "$SURFACE_ERR"
}

@test "new-command: a second run refuses the existing command and writes nothing" {
  generate_tool_probe
  [ "$SURFACE_STATUS" -eq 0 ]
  snapshot_copy

  generate_tool_probe

  [ "$SURFACE_STATUS" -eq 1 ]
  grep -Fq 'tool-probe already exists (test/fixtures/py-public-commands.tsv)' "$SURFACE_ERR"
  [ ! -s "$SURFACE_OUT" ]
  assert_copy_unchanged
}

@test "new-command: invalid names, modules, metadata, and text are refused" {
  local label="Probe Tool Backend" description="Show one tool."
  snapshot_copy

  surface new --label "$label" --description "$description" \
    nosuite tool-probe py-tools.zsh read-only
  [ "$SURFACE_STATUS" -eq 2 ]
  grep -Fq 'unknown suite "nosuite"' "$SURFACE_ERR"

  local name
  for name in Tool-Probe tool_probe tool probe-tool tool-probe2; do
    surface new --capability tool --label "$label" --description "$description" \
      py "$name" py-tools.zsh read-only
    [ "$SURFACE_STATUS" -eq 2 ]
  done

  surface new --capability tool --label "$label" --description "$description" \
    py tool-list py-tools.zsh read-only
  [ "$SURFACE_STATUS" -eq 1 ]
  grep -Fq 'tool-list already exists' "$SURFACE_ERR"

  local module
  for module in py-missing.zsh py-common.zsh ../py-tools.zsh py/py-tools.zsh; do
    surface new --capability tool --label "$label" --description "$description" \
      py tool-probe "$module" read-only
    [ "$SURFACE_STATUS" -eq 2 ]
  done

  surface new --capability tool --label "$label" --description "$description" \
    py tool-probe py-tools.zsh privileged
  [ "$SURFACE_STATUS" -eq 2 ]
  grep -Fq 'test/py_contract.bats accepts' "$SURFACE_ERR"

  surface new --label "$label" --description "$description" \
    py tool-probe py-tools.zsh read-only
  [ "$SURFACE_STATUS" -eq 2 ]
  grep -Fq 'pass --capability VALUE' "$SURFACE_ERR"

  surface new --capability 'tool;id' --label "$label" --description "$description" \
    py tool-probe py-tools.zsh read-only
  [ "$SURFACE_STATUS" -eq 2 ]

  surface new --privilege privileged --label "$label" --description "$description" \
    dev dev-run-probe dev-checks.zsh read-only
  [ "$SURFACE_STATUS" -eq 2 ]
  grep -Fq -- '--privilege does not apply' "$SURFACE_ERR"

  local text
  for text in 'Show "quoted"' 'Show $(id)' 'Show `id`' 'Show a | b' \
    "Show it's" 'lowercase start' 'Show \n escape'; do
    surface new --capability tool --label "$text" --description "$description" \
      py tool-probe py-tools.zsh read-only
    [ "$SURFACE_STATUS" -eq 2 ]
    surface new --capability tool --label "$label" --description "$text" \
      py tool-probe py-tools.zsh read-only
    [ "$SURFACE_STATUS" -eq 2 ]
  done

  surface new --capability tool --label "$label" py tool-probe py-tools.zsh read-only
  [ "$SURFACE_STATUS" -eq 2 ]
  surface new --bogus --capability tool --label "$label" --description "$description" \
    py tool-probe py-tools.zsh read-only
  [ "$SURFACE_STATUS" -eq 2 ]
  surface new --capability tool --label "$label" --description "$description" \
    py tool-probe py-tools.zsh
  [ "$SURFACE_STATUS" -eq 2 ]

  assert_copy_unchanged
}

@test "new-command: an ambiguous or unrecognized target region is refused" {
  local label="Probe Tool Backend" description="Show one tool."
  snapshot_copy

  # venv-list has two menu records: the read-only batch view and the full menu.
  surface new --after venv-list --capability tool --label "$label" \
    --description "$description" py tool-probe py-tools.zsh read-only
  [ "$SURFACE_STATUS" -eq 1 ]
  grep -Fq 'venv-list appears 2 times in _py_menu_rows' "$SURFACE_ERR"
  assert_copy_unchanged

  # A dispatcher arm with extra logic is not a shape the generator clones.
  perl -pi -e 's/^(\s+tool-upgrade\)\s+)tool-upgrade "\$\@" ;;$/$1tool-upgrade "\$\@" || true ;;/' \
    "$SCAFFOLD_REPO/functions/py-menu.zsh"
  snapshot_copy
  generate_tool_probe
  [ "$SURFACE_STATUS" -eq 1 ]
  grep -Fq 'the dispatcher arm of tool-upgrade' "$SURFACE_ERR"
  grep -Fq 'has an unrecognized shape' "$SURFACE_ERR"
  assert_copy_unchanged

  # A module whose sentinel is not the last line cannot place the stub.
  printf '%s\n' '# trailing note' >>"$SCAFFOLD_REPO/functions/py/py-tools.zsh"
  snapshot_copy
  surface new --after tool-uninstall --capability tool --label "$label" \
    --description "$description" py tool-probe py-tools.zsh read-only
  [ "$SURFACE_STATUS" -eq 1 ]
  grep -Fq 'does not end with its typeset -g _..._SOURCED=1 sentinel' "$SURFACE_ERR"
  assert_copy_unchanged
}

# F3-09 prospective scaffold acceptance. The generator adds dispatcher arms;
# it does not generate a complete entrypoint or migrate the Python suite.
# shellcheck disable=SC2016

scaffold_timed_anchor() {
  SCAFFOLD_ANCHOR_KIND="${1:-valid}" perl - \
    "$SCAFFOLD_REPO/functions/py-menu.zsh" <<'PERL'
use strict;
use warnings;
my $path = shift @ARGV;
open my $input, '<', $path or die "$path: $!\n";
local $/;
my $source = <$input>;
close $input or die "$path: $!\n";
my %bodies = (
    valid => q{_py_timed "py:tool-upgrade" tool-upgrade "$@"},
    wrong_suite => q{_py_timed "dev:tool-upgrade" tool-upgrade "$@"},
    wrong_label => q{_py_timed "py:tool-install" tool-upgrade "$@"},
    wrong_target => q{_py_timed "py:tool-upgrade" tool-uninstall "$@"},
    wrong_wrapper => q{_dev_timed "py:tool-upgrade" tool-upgrade "$@"},
    dynamic_label => q{_py_timed "py:$command_name" tool-upgrade "$@"},
    dynamic_target => q{_py_timed "py:tool-upgrade" "$command_name" "$@"},
    extra_argument => q{_py_timed "py:tool-upgrade" tool-upgrade --invented "$@"},
    extra_logic => q{_py_timed "py:tool-upgrade" tool-upgrade "$@" || true},
);
my $kind = $ENV{SCAFFOLD_ANCHOR_KIND};
exists $bodies{$kind} or die "unknown fixture kind\n";
my $replacement = "    tool-upgrade)\n      $bodies{$kind}\n      ;;";
my $count = $source =~ s{^    tool-upgrade\)[ \t]+tool-upgrade "\$\@" ;;$}{$replacement}mg;
$count == 1 or die "expected exactly one legacy fixture anchor, got $count\n";
open my $output, '>', $path or die "$path: $!\n";
print {$output} $source or die "$path: $!\n";
close $output or die "$path: $!\n";
PERL
}

# Instantiates the actual normative code examples, rather than maintaining a
# second handwritten entrypoint/selection implementation in these tests.
scaffold_contract_templates() {
  perl - "$SCAFFOLD_REPO/docs/menu-spec.md" "$HOME" <<'PERL'
use strict;
use warnings;
my ($path, $home) = @ARGV;
open my $input, '<', $path or die "$path: $!\n";
local $/;
my $document = <$input>;
close $input or die "$path: $!\n";
sub example {
    my ($heading) = @_;
    my ($section) = $document =~ /^## \Q$heading\E\s*\n(.*?)(?=^## |\z)/ms;
    defined $section or die "missing normative section $heading\n";
    my $fence = chr(96) x 3;
    my ($body) = $section =~ /^\Q$fence\Ezsh\n(.*?)^\Q$fence\E\s*$/ms;
    defined $body or die "missing Zsh example in $heading\n";
    $body =~ s/<suite>/py/g;
    $body =~ s/<prefix>/py/g;
    return $body;
}
my $entry = "emulate -R zsh\n" . example('Entrypoint routing');
my $selection = "emulate -R zsh\n_py_interactive() {\n" .
    "  local -a options=(\n" .
    "    '  Probe Tool Backend|tool-probe|Show which backend owns one isolated tool.'\n" .
    "    'Section|:|Select an action.'\n" .
    "  )\n" . example('Selection and cancellation') . "}\n";
for my $item (['scaffold-entry.zsh', $entry], ['scaffold-selection.zsh', $selection]) {
    my ($name, $body) = @$item;
    open my $output, '>', "$home/$name" or die "$home/$name: $!\n";
    print {$output} $body or die "$home/$name: $!\n";
    close $output or die "$home/$name: $!\n";
}
PERL
  zsh -n "$HOME/scaffold-entry.zsh" || return 96
  zsh -n "$HOME/scaffold-selection.zsh" || return 97
}

scaffold_routing_support() {
  cat > "$HOME/scaffold-support.zsh" <<'ZSH'
emulate -R zsh
builtin cd -- "$HOME" || return 80
export NO_COLOR=1 ZDX_TELEMETRY=1
functions[_scaffold_original_timed]="${functions[_timed]}"
_timed() {
  print -r -- "$1" >> "$HOME/timer.labels"
  _scaffold_original_timed "$@"
}
tool-probe() {
  print -r -- "$#" > "$HOME/actual.argc"
  : > "$HOME/actual.args"
  if (( $# > 0 )); then
    printf '%s\0' "$@" > "$HOME/actual.args"
  fi
  printf 'payload\n\n'
  return "${SCAFFOLD_ROUTE_STATUS:-7}"
}
# Never let a mis-generated target reach the real updater in this fixture.
tool-upgrade() { print -r -- anchor >> "$HOME/forbidden"; return 98; }
tool-plausible-unknown() { print -r -- unknown >> "$HOME/forbidden"; return 98; }
# Metadata is deliberately permissive; only the real case arms authorize execution.
_py_command_is_canonical() { return 0; }
_py_require_command() { print -r -- probe >> "$HOME/probes"; return 97; }
_py_dispatch_prepare() { print -r -- probe >> "$HOME/probes"; return 97; }
_py_fzf_capture() {
  print -r -- picker >> "$HOME/pickers"
  REPLY="${SCAFFOLD_SELECTION-}"
  return "${SCAFFOLD_PICKER_STATUS:-0}"
}
_py_usage() { print -u2 -r -- 'Usage: py-menu [command]'; }
ZSH
  zsh -n "$HOME/scaffold-support.zsh"
}

@test "new-command: a canonical timed anchor keeps dry-run publication passive" {
  scaffold_timed_anchor valid
  snapshot_copy
  generate_tool_probe --dry-run
  [ "$SURFACE_STATUS" -eq 0 ]
  [ ! -s "$SURFACE_ERR" ]
  grep -Fq 'dispatcher arm' "$SURFACE_OUT"
  assert_copy_unchanged
}

@test "new-command: a generated timed arm reaches the actual command parser" {
  scaffold_timed_anchor valid
  generate_tool_probe
  [ "$SURFACE_STATUS" -eq 0 ]
  # A literal label/target is the narrow code-generation contract. Runtime
  # behavior alone cannot distinguish a fixed label from a variable that
  # happens to contain the same canonical token on this invocation.
  grep -Eq '(^|[[:space:]])_py_timed[[:space:]]+"py:tool-probe"[[:space:]]+tool-probe[[:space:]]+"\$@"([[:space:]]|$)' \
    "$SCAFFOLD_REPO/functions/py-menu.zsh"
  run run_zsh '
    builtin cd -- "$HOME" || exit 80
    export NO_COLOR=1 ZDX_TELEMETRY=1
    tool-upgrade() { return 98; }
    _py_dispatch tool-probe --help > "$HOME/help.out" 2> "$HOME/help.err"
    [[ "$?" == 0 && ! -s "$HOME/help.out" ]] || exit 81
    _py_dispatch tool-probe --bogus > "$HOME/bad.out" 2> "$HOME/bad.err"
    [[ "$?" == 2 && ! -s "$HOME/bad.out" ]] || exit 82
    command jq -s -e "length == 2 and map(.exit_code) == [0,2] and all(.[]; .suite == \"py\" and .command == \"tool-probe\")" \
      "$HOME/.config/zdx/telemetry.json" > /dev/null || exit 83
  '
  [ "$status" -eq 0 ]
  grep -Fq 'Usage: tool-probe [-h|--help]' "$HOME/help.err"
  grep -Fq 'tool-probe accepts no arguments.' "$HOME/bad.err"
}

@test "new-command: a generated timed arm preserves literal operands and command status" {
  scaffold_timed_anchor valid
  generate_tool_probe
  [ "$SURFACE_STATUS" -eq 0 ]
  scaffold_routing_support
  printf '%s\0' '' : 'two words' $'line\nbreak' '; touch canary' '*' \
    '$(touch canary)' > "$HOME/expected.args"
  printf 'payload\n\n' > "$HOME/expected.out"
  run run_zsh '
    builtin cd -- "$HOME" || exit 80
    source "$HOME/scaffold-support.zsh" || exit 81
    _py_dispatch tool-probe "" : "two words" $'"'"'line\nbreak'"'"' \
      "; touch canary" "*" "\$(touch canary)" > "$HOME/actual.out" 2> "$HOME/actual.err"
    [[ "$?" == 7 && ! -e "$HOME/canary" ]] || exit 82
    [[ "$(<"$HOME/timer.labels")" == py:tool-probe ]] || exit 83
    [[ ! -e "$HOME/forbidden" && ! -e "$HOME/probes" && ! -e "$HOME/pickers" ]] || exit 84
    command jq -s -e "length == 1 and .[0].suite == \"py\" and .[0].command == \"tool-probe\" and .[0].exit_code == 7" \
      "$HOME/.config/zdx/telemetry.json" > /dev/null || exit 85
  '
  [ "$status" -eq 0 ]
  cmp "$HOME/expected.args" "$HOME/actual.args"
  cmp "$HOME/expected.out" "$HOME/actual.out"
  [ "$(wc -l < "$HOME/actual.err")" -eq 1 ]
  [[ "$(cat "$HOME/actual.err")" == "  py:tool-probe failed after "*" (status 7)" ]]
}

@test "new-command: generated dispatch rejects unknown functions before timing and keeps sections untimed" {
  scaffold_timed_anchor valid
  generate_tool_probe
  [ "$SURFACE_STATUS" -eq 0 ]
  scaffold_routing_support
  run run_zsh '
    builtin cd -- "$HOME" || exit 80
    source "$HOME/scaffold-support.zsh" || exit 81
    local token
    for token in "" tool-plausible-unknown py:tool-probe --unknown; do
      _py_dispatch "$token" > "$HOME/out" 2> "$HOME/err"
      [[ "$?" == 2 && ! -s "$HOME/out" && -s "$HOME/err" ]] || exit 82
    done
    _py_dispatch : > "$HOME/out" 2> "$HOME/err"
    [[ "$?" == 0 && ! -s "$HOME/out" && ! -s "$HOME/err" ]] || exit 83
    [[ ! -e "$HOME/timer.labels" && ! -e "$HOME/.config/zdx/telemetry.json" \
      && ! -e "$HOME/forbidden" && ! -e "$HOME/probes" && ! -e "$HOME/pickers" ]] || exit 84
  '
  [ "$status" -eq 0 ]
}

@test "new-command: malformed timed anchors are refused before any publication" {
  cp "$SCAFFOLD_REPO/functions/py-menu.zsh" "$HOME/original-py-menu.zsh"
  local kind
  for kind in wrong_suite wrong_label wrong_target wrong_wrapper dynamic_label \
    dynamic_target extra_argument extra_logic; do
    cp "$HOME/original-py-menu.zsh" "$SCAFFOLD_REPO/functions/py-menu.zsh"
    scaffold_timed_anchor "$kind"
    snapshot_copy
    generate_tool_probe
    [ "$SURFACE_STATUS" -eq 1 ]
    [ ! -s "$SURFACE_OUT" ]
    [ -s "$SURFACE_ERR" ]
    assert_copy_unchanged
  done
}

@test "new-command: surfaces derives the generated timed action from the dispatcher" {
  scaffold_timed_anchor valid
  generate_tool_probe
  [ "$SURFACE_STATUS" -eq 0 ]
  surface check py
  # Manual docs and frozen-count updates remain pending, as with legacy arms.
  [ "$SURFACE_STATUS" -eq 1 ]
  awk '$1 == "py" && $2 == "tool-probe" { seen++; if ($3 != "ok" || $4 != "ok") exit 1 } END { if (seen != 1) exit 1 }' \
    "$SURFACE_OUT"
  [[ "$(cat "$SURFACE_ERR")" != *"tool-probe: no dispatcher arm"* ]]
}

# These composed tests instantiate the published canonical entrypoint/selection
# examples over the REAL generated dispatcher. They prove template compatibility,
# not migration of the maintained py-menu public entrypoint in this core PR.
@test "new-command: the canonical entrypoint rejects empty colon and unknown tokens before timing" {
  scaffold_timed_anchor valid
  generate_tool_probe
  [ "$SURFACE_STATUS" -eq 0 ]
  scaffold_contract_templates
  scaffold_routing_support
  run run_zsh '
    builtin cd -- "$HOME" || exit 80
    source "$HOME/scaffold-entry.zsh" || exit 81
    source "$HOME/scaffold-selection.zsh" || exit 82
    source "$HOME/scaffold-support.zsh" || exit 83
    local token arity help_form
    for token in "" : py:tool-probe tool-plausible-unknown --unknown; do
      for arity in sole trailing; do
        if [[ "$arity" == sole ]]; then
          py-menu "$token" > "$HOME/out" 2> "$HOME/err"
        else
          py-menu "$token" "later operand" > "$HOME/out" 2> "$HOME/err"
        fi
        [[ "$?" == 2 && ! -s "$HOME/out" && -s "$HOME/err" ]] || exit 84
        [[ ! -e "$HOME/timer.labels" && ! -e "$HOME/.config/zdx/telemetry.json" \
          && ! -e "$HOME/forbidden" && ! -e "$HOME/probes" && ! -e "$HOME/pickers" ]] || exit 85
      done
    done
    for help_form in -h --help; do
      py-menu "$help_form" extra > "$HOME/out" 2> "$HOME/err"
      [[ "$?" == 2 && ! -s "$HOME/out" && -s "$HOME/err" ]] || exit 86
      py-menu "$help_form" > "$HOME/out" 2> "$HOME/err"
      [[ "$?" == 0 && ! -s "$HOME/out" && -s "$HOME/err" ]] || exit 87
    done
    [[ ! -e "$HOME/timer.labels" && ! -e "$HOME/.config/zdx/telemetry.json" \
      && ! -e "$HOME/forbidden" && ! -e "$HOME/probes" && ! -e "$HOME/pickers" ]] || exit 88
  '
  [ "$status" -eq 0 ]
}

@test "new-command: canonical no-argument selection keeps sections cancellation and forgeries untimed" {
  scaffold_timed_anchor valid
  generate_tool_probe
  [ "$SURFACE_STATUS" -eq 0 ]
  scaffold_contract_templates
  scaffold_routing_support
  run run_zsh '
    builtin cd -- "$HOME" || exit 80
    source "$HOME/scaffold-entry.zsh" || exit 81
    source "$HOME/scaffold-selection.zsh" || exit 82
    source "$HOME/scaffold-support.zsh" || exit 83
    SCAFFOLD_SELECTION="Section|:|Select an action."
    py-menu > "$HOME/out" 2> "$HOME/err"
    [[ "$?" == 0 && ! -s "$HOME/out" && ! -s "$HOME/err" ]] || exit 84
    SCAFFOLD_SELECTION="Forged label|tool-probe|Show which backend owns one isolated tool."
    py-menu > "$HOME/out" 2> "$HOME/err"
    [[ "$?" == 1 && ! -s "$HOME/out" && -s "$HOME/err" ]] || exit 85
    local picker_rc
    for picker_rc in 1 130; do
      SCAFFOLD_PICKER_STATUS=$picker_rc
      py-menu > "$HOME/out" 2> "$HOME/err"
      [[ "$?" == 0 && ! -s "$HOME/out" && ! -s "$HOME/err" ]] || exit 86
    done
    SCAFFOLD_PICKER_STATUS=17
    py-menu > "$HOME/out" 2> "$HOME/err"
    [[ "$?" == 1 && ! -s "$HOME/out" && -s "$HOME/err" ]] || exit 87
    [[ "$(<"$HOME/pickers")" == $'"'"'picker\npicker\npicker\npicker\npicker'"'"' ]] || exit 88
    [[ ! -e "$HOME/timer.labels" && ! -e "$HOME/.config/zdx/telemetry.json" \
      && ! -e "$HOME/forbidden" && ! -e "$HOME/probes" && ! -e "$HOME/actual.args" ]] || exit 89
  '
  [ "$status" -eq 0 ]
}

@test "new-command: canonical direct and interactive adapters time the generated action once" {
  scaffold_timed_anchor valid
  generate_tool_probe
  [ "$SURFACE_STATUS" -eq 0 ]
  scaffold_contract_templates
  scaffold_routing_support
  printf '%s\0' '' : 'two words' '$(touch canary)' > "$HOME/expected.args"
  printf 'payload\n\n' > "$HOME/expected.out"
  run run_zsh '
    builtin cd -- "$HOME" || exit 80
    source "$HOME/scaffold-entry.zsh" || exit 81
    source "$HOME/scaffold-selection.zsh" || exit 82
    source "$HOME/scaffold-support.zsh" || exit 83
    py-menu tool-probe "" : "two words" "\$(touch canary)" \
      > "$HOME/direct.out" 2> "$HOME/direct.err"
    [[ "$?" == 7 && ! -e "$HOME/canary" ]] || exit 84
    command cmp "$HOME/expected.args" "$HOME/actual.args" || exit 85
    SCAFFOLD_SELECTION="  Probe Tool Backend|tool-probe|Show which backend owns one isolated tool."
    py-menu > "$HOME/interactive.out" 2> "$HOME/interactive.err"
    [[ "$?" == 7 && "$(<"$HOME/pickers")" == picker ]] || exit 86
    [[ "$(<"$HOME/actual.argc")" == 0 && ! -s "$HOME/actual.args" ]] || exit 90
    [[ "$(<"$HOME/timer.labels")" == $'"'"'py:tool-probe\npy:tool-probe'"'"' ]] || exit 87
    [[ ! -e "$HOME/forbidden" && ! -e "$HOME/probes" ]] || exit 88
    command jq -s -e "length == 2 and all(.[]; .suite == \"py\" and .command == \"tool-probe\" and .exit_code == 7)" \
      "$HOME/.config/zdx/telemetry.json" > /dev/null || exit 89
  '
  [ "$status" -eq 0 ]
  cmp "$HOME/expected.out" "$HOME/direct.out"
  cmp "$HOME/expected.out" "$HOME/interactive.out"
  [ "$(wc -l < "$HOME/direct.err")" -eq 1 ]
  [ "$(wc -l < "$HOME/interactive.err")" -eq 1 ]
}
