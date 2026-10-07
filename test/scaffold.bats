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
  # Developer binds its commands but registers no individual lazy stubs and
  # has no interactive allowlist, so those columns do not apply.
  grep -Eq '^dev +dev-run-tests +ok +ok +ok +ok +ok +ok +- +- +ok +ok$' "$SURFACE_OUT"
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
  grep -Fxq '    tool-probe py-menu.zsh' "$SCAFFOLD_REPO/functions.zsh"

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
  run zsh -c '
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
  run awk -F '\t' '!/^#/ && NF { print $1 }' \
    "$SCAFFOLD_REPO/test/fixtures/dev-public-commands.tsv"
  [ "$output" = "$(printf '%s\n' "${lines[@]}" | LC_ALL=C sort)" ]
  [[ "$output" == *"dev-run-probe"* ]]

  surface check dev
  [ "$SURFACE_STATUS" -eq 1 ]
  grep -Eq '^dev +dev-run-probe +ok +ok +ok +ok +ok +ok +- +- +MISS +warn$' "$SURFACE_OUT"
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
