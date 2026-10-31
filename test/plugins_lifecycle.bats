#!/usr/bin/env bats
# shellcheck disable=SC2016

# Staged, trust-gated installs and updates against local bare origins.

setup() {
  load test_helper
  load core_options_test_helper
  load plugins_test_helper
  plugins_git_recorder
}

teardown() {
  if [[ -n "${PLUGINS_LOCK_HOLDER:-}" ]]; then
    kill "$PLUGINS_LOCK_HOLDER" 2>/dev/null || true
    wait "$PLUGINS_LOCK_HOLDER" 2>/dev/null || true
  fi
  cleanup_sandbox
}

# --- Install --------------------------------------------------------------------

@test "plugins lifecycle: --install --yes stages, validates, reviews, and activates" {
  plugin_origin_create alpha
  local origin head
  origin=$(plugin_origin_url alpha)
  head=$(plugin_origin_head alpha)

  run run_zsh "
    zdx-plugins --install '$origin' --yes || return
    alpha-menu
    print -r -- \"loaded=\${ZDX_LOADED_PLUGINS[*]}\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"Origin:"*"$origin"* ]]
  [[ "$output" == *"New commit:"*"${head:0:7} Initial plugin"* ]]
  [[ "$output" == *"Commit ID:"*"$head"* ]]
  [[ "$output" == *"Signature:"*"unsigned"* ]]
  [[ "$output" == *"Validation:"*"passed"* ]]
  [[ "$output" == *"runs this plugin's code in your current shell"* ]]
  [[ "$output" == *"Trusted with --yes."* ]]
  [[ "$output" == *"Plugin 'alpha' installed and activated at ${head:0:7}."* ]]
  [[ "$output" == *"alpha v1"* ]]
  [[ "$output" == *"loaded=alpha"* ]]
  [ "$(plugin_installed_head alpha)" = "$head" ]
  [ -z "$(plugins_staging_left)" ]
  [ "$(file_mode "$PLUGINS_ROOT")" = 700 ]
  [ "$(file_mode "$PLUGINS_ROOT/.zdx-plugins.lock")" = 600 ]
}

@test "plugins lifecycle: the staged clone lives in a private directory inside the root" {
  plugin_origin_create alpha
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PLUGINS_GIT_LOG"
if [[ "$1" == clone ]]; then
  destination="${*: -1}"
  ls -ld "$(dirname "$destination")" >> "$TEST_TEMP_DIR/stage-mode"
  printf '%s\n' "$(dirname "$destination")" >> "$TEST_TEMP_DIR/stage-path"
fi
exec "$PLUGINS_REAL_GIT" "$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/git"

  run run_zsh "zdx-plugins --install '$(plugin_origin_url alpha)' --yes"

  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_TEMP_DIR/stage-mode")" == drwx------* ]]
  local stage
  stage=$(cat "$TEST_TEMP_DIR/stage-path")
  [[ "$stage" == "$PLUGINS_ROOT/.zdx-staging.alpha."* ]]
  [ ! -e "$stage" ]
}

@test "plugins lifecycle: --install without a terminal or --yes refuses before any fetch" {
  plugin_origin_create alpha

  run run_zsh "zdx-plugins --install '$(plugin_origin_url alpha)'"

  [ "$status" -eq 1 ]
  [[ "$output" == *"need a terminal for the trust decision"*"--yes"* ]]
  [ ! -e "$PLUGINS_ROOT/alpha" ]
  [ ! -s "$PLUGINS_GIT_LOG" ]
}

@test "plugins lifecycle: --install --dry-run reviews the commit and installs nothing" {
  plugin_origin_create alpha
  local head
  head=$(plugin_origin_head alpha)

  run run_zsh "
    zdx-plugins --install '$(plugin_origin_url alpha)' --dry-run || return
    (( \${+functions[alpha-menu]} )) && print -r -- DEFINED
    return 0
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"New commit:"*"${head:0:7} Initial plugin"* ]]
  [[ "$output" == *"Dry run: 'alpha' at ${head:0:7} planned; nothing was installed."* ]]
  [[ "$output" != *DEFINED* ]]
  [ ! -e "$PLUGINS_ROOT/alpha" ]
  [ -z "$(plugins_staging_left)" ]
}

@test "plugins lifecycle: a declined trust decision installs nothing" {
  plugin_origin_create alpha

  run run_zsh "
    _zdx_plugins_terminal() { return 0; }
    _zdx_plugins_confirm() { print -u2 -r -- \"PROMPT: \$1\"; return 1; }
    zdx-plugins --install '$(plugin_origin_url alpha)'
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"PROMPT: Trust and activate 'alpha' at "* ]]
  [[ "$output" == *"Cancelled: nothing was installed."* ]]
  [ ! -e "$PLUGINS_ROOT/alpha" ]
  [ -z "$(plugins_staging_left)" ]
}

@test "plugins lifecycle: install validation failures publish nothing" {
  local case_name
  for case_name in missing syntax link; do
    plugin_origin_create "bad-$case_name"
    local work="$TEST_TEMP_DIR/work/bad-$case_name"
    case "$case_name" in
      missing)
        git -C "$work" rm -q "bad-$case_name-menu.zsh"
        git -C "$work" commit -q -m "Remove entrypoint"
        ;;
      syntax)
        printf 'bad-syntax-menu() {\n  print "broken\n}\n' > "$work/bad-syntax-menu.zsh"
        git -C "$work" commit -q -am "Break syntax"
        ;;
      link)
        ln -s /etc/hosts "$work/hosts"
        git -C "$work" add hosts
        git -C "$work" commit -q -m "Add link"
        ;;
    esac
    git -C "$work" push -q origin main

    run run_zsh "zdx-plugins --install '$(plugin_origin_url "bad-$case_name")' --yes"

    [ "$status" -eq 1 ]
    case "$case_name" in
      missing) [[ "$output" == *"Entrypoint script 'bad-missing-menu.zsh' not found"* ]] ;;
      syntax)  [[ "$output" == *"Syntax error in 'bad-syntax-menu.zsh'"* ]] ;;
      link)    [[ "$output" == *"contains symbolic links, such as hosts"* ]] ;;
    esac
    [[ "$output" != *"installed and activated"* ]]
    [ ! -e "$PLUGINS_ROOT/bad-$case_name" ]
    [ -z "$(plugins_staging_left)" ]
  done
}

@test "plugins lifecycle: a failed entrypoint source rolls an install back" {
  plugin_origin_create alpha
  plugin_origin_commit alpha "Fail at source time" \
    "$(plugin_source alpha v2)"$'\n''return 4'

  run run_zsh "
    zdx-plugins --install '$(plugin_origin_url alpha)' --yes
    local rc=\$?
    (( \${+functions[alpha-menu]} )) && print -r -- DEFINED
    print -r -- \"rc=\$rc loaded=\${ZDX_LOADED_PLUGINS[*]}\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"Sourcing 'alpha-menu.zsh' failed with status 4."* ]]
  [[ "$output" == *"Rolled back: 'alpha' was not installed."* ]]
  [[ "$output" == *"rc=1 loaded="* ]]
  [[ "$output" != *"installed and activated"* ]]
  [[ "$output" != *DEFINED* ]]
  [ ! -e "$PLUGINS_ROOT/alpha" ]
  [ -z "$(plugins_staging_left)" ]
}

@test "plugins lifecycle: an entrypoint that defines no menu function is rolled back" {
  plugin_origin_create alpha
  plugin_origin_commit alpha "No menu" 'print -u2 -r -- "no menu here"'

  run run_zsh "zdx-plugins --install '$(plugin_origin_url alpha)' --yes"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Function 'alpha-menu' was not defined after sourcing"* ]]
  [ ! -e "$PLUGINS_ROOT/alpha" ]
  [ -z "$(plugins_staging_left)" ]
}

@test "plugins lifecycle: a clone failure leaves no plugin or staging" {
  run run_zsh "zdx-plugins --install '$TEST_TEMP_DIR/origins/missing.git' --yes"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not fetch the plugin from its origin."* ]]
  [ ! -e "$PLUGINS_ROOT/missing" ]
  [ -z "$(plugins_staging_left)" ]
}

@test "plugins lifecycle: a bad commit signature is refused even with --yes" {
  plugin_origin_create alpha

  run run_zsh "
    _zdx_plugins_signature() { REPLY='BAD signature'; reply=(bad); }
    zdx-plugins --install '$(plugin_origin_url alpha)' --yes
  "

  [ "$status" -eq 1 ]
  [[ "$output" == *"bad signature; refusing to activate it"* ]]
  [ ! -e "$PLUGINS_ROOT/alpha" ]
  [ -z "$(plugins_staging_left)" ]
}

@test "plugins lifecycle: install keeps source-time plugin output off stdout" {
  plugin_origin_create alpha
  plugin_origin_commit alpha "Noisy source" \
    'print -r -- "SOURCE STDOUT"'$'\n'"$(plugin_source alpha v2)"

  run run_zsh "zdx-plugins --install '$(plugin_origin_url alpha)' --yes 2>/dev/null"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -d "$PLUGINS_ROOT/alpha" ]
}

# --- Update ---------------------------------------------------------------------

@test "plugins lifecycle: --update --yes shows the exact transition and activates it" {
  plugin_origin_create alpha
  plugins_install alpha
  local old new origin
  old=$(plugin_origin_head alpha)
  plugin_origin_commit alpha "Add second feature" "$(plugin_source alpha v2)"
  new=$(plugin_origin_head alpha)
  origin=$(plugin_origin_url alpha)

  run run_zsh "
    alpha-menu
    zdx-plugins --update alpha --yes || return
    alpha-menu
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"Origin:"*"$origin"* ]]
  [[ "$output" == *"Branch:"*"main"* ]]
  [[ "$output" == *"Installed:"*"${old:0:7} Initial plugin"* ]]
  [[ "$output" == *"New commit:"*"${new:0:7} Add second feature"* ]]
  [[ "$output" == *"Commit ID:"*"$new"* ]]
  [[ "$output" == *"Commits:"*"1 commit (fast-forward)"* ]]
  [[ "$output" == *"${new:0:7} Add second feature"* ]]
  [[ "$output" == *"Signature:"*"unsigned"* ]]
  [[ "$output" == *"runs this plugin's code in your current shell"* ]]
  [[ "$output" == *"Plugin 'alpha' updated (${old:0:7} → ${new:0:7} · 1 commit) and sourced in this shell."* ]]
  [[ "$output" == *"alpha v1"*"alpha v2"* ]]
  [ "$(plugin_installed_head alpha)" = "$new" ]
  [ -z "$(plugins_staging_left)" ]
}

@test "plugins lifecycle: --update without a terminal or --yes refuses and changes nothing" {
  plugin_origin_create alpha
  plugins_install alpha
  plugin_origin_commit alpha "Second" "$(plugin_source alpha v2)"
  local before
  before=$(plugin_tree_fingerprint "$PLUGINS_ROOT/alpha")
  : > "$PLUGINS_GIT_LOG"

  run run_zsh "zdx-plugins --update alpha"

  [ "$status" -eq 1 ]
  [[ "$output" == *"--yes"* ]]
  [ "$(plugin_tree_fingerprint "$PLUGINS_ROOT/alpha")" = "$before" ]
  ! grep -q clone "$PLUGINS_GIT_LOG" || false
}

@test "plugins lifecycle: --update --dry-run reviews the transition without activating" {
  plugin_origin_create alpha
  plugins_install alpha
  local old new before
  old=$(plugin_origin_head alpha)
  plugin_origin_commit alpha "Second" "$(plugin_source alpha v2)"
  plugin_origin_commit alpha "Third" "$(plugin_source alpha v3)"
  new=$(plugin_origin_head alpha)
  before=$(plugin_tree_fingerprint "$PLUGINS_ROOT/alpha")

  run run_zsh "zdx-plugins --update alpha --dry-run"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Commits:"*"2 commits (fast-forward)"* ]]
  [[ "$output" == *"Third"*"Second"* ]]
  [[ "$output" == *"Dry run: 'alpha' ${old:0:7} → ${new:0:7} · 2 commits planned; nothing was activated."* ]]
  [ "$(plugin_tree_fingerprint "$PLUGINS_ROOT/alpha")" = "$before" ]
  [ -z "$(plugins_staging_left)" ]
}

@test "plugins lifecycle: an unchanged origin reports the plugin as current" {
  plugin_origin_create alpha
  plugins_install alpha
  local head
  head=$(plugin_origin_head alpha)

  run run_zsh "zdx-plugins --update alpha --yes"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Plugin 'alpha' is current at ${head:0:7}."* ]]
  [[ "$output" != *"Trust decision"* ]]
  [ -z "$(plugins_staging_left)" ]
}

@test "plugins lifecycle: update validation failure leaves the active plugin byte-identical" {
  plugin_origin_create alpha
  plugins_install alpha
  plugin_origin_commit alpha "Broken" $'alpha-menu() {\n  print "broken\n}'
  local before
  before=$(plugin_tree_fingerprint "$PLUGINS_ROOT/alpha")

  run run_zsh "
    zdx-plugins --update alpha --yes
    local rc=\$?
    alpha-menu
    return \$rc
  "

  [ "$status" -eq 1 ]
  [[ "$output" == *"Syntax error in 'alpha-menu.zsh'"* ]]
  [[ "$output" == *"failed validation; 'alpha' is unchanged."* ]]
  [[ "$output" == *"alpha v1"* ]]
  [ "$(plugin_tree_fingerprint "$PLUGINS_ROOT/alpha")" = "$before" ]
  [ -z "$(plugins_staging_left)" ]
}

@test "plugins lifecycle: a failed source during update rolls back to the exact previous commit" {
  plugin_origin_create alpha
  plugins_install alpha
  local old before
  old=$(plugin_origin_head alpha)
  # The failing version also overwrites a common caller variable name.
  plugin_origin_commit alpha "Fails while sourcing" \
    "$(plugin_source alpha v2)"$'\n''plugin_name=clobbered'$'\n''return 3'
  before=$(plugin_tree_fingerprint "$PLUGINS_ROOT/alpha")

  run run_zsh "
    zdx-plugins --update alpha --yes
    local rc=\$?
    alpha-menu
    print -r -- \"rc=\$rc loaded=\${ZDX_LOADED_PLUGINS[*]}\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"Sourcing 'alpha-menu.zsh' failed with status 3."* ]]
  [[ "$output" == *"Rolled back 'alpha' to ${old:0:7}; its files are unchanged."* ]]
  [[ "$output" == *"open a new shell"* ]]
  [[ "$output" != *"sourced in this shell"* ]]
  # The menu function the failed source replaced is restored.
  [[ "$output" == *"alpha v1"* && "$output" != *"alpha v2"* ]]
  [[ "$output" == *"rc=1 loaded=alpha"* ]]
  [ "$(plugin_installed_head alpha)" = "$old" ]
  [ "$(plugin_tree_fingerprint "$PLUGINS_ROOT/alpha")" = "$before" ]
  [ -z "$(plugins_staging_left)" ]
}

@test "plugins lifecycle: an update reload clears the conventional source sentinel" {
  plugin_origin_create alpha
  plugin_origin_commit alpha "Guarded" \
    $'if [[ -n "${_ALPHA_MENU_SOURCED:-}" ]]; then\n  return 0\nfi\n'"$(plugin_source alpha v1)"$'\ntypeset -g _ALPHA_MENU_SOURCED=1'
  plugins_install alpha
  plugin_origin_commit alpha "Guarded v2" \
    $'if [[ -n "${_ALPHA_MENU_SOURCED:-}" ]]; then\n  return 0\nfi\n'"$(plugin_source alpha v2)"$'\ntypeset -g _ALPHA_MENU_SOURCED=1'

  run run_zsh "
    [[ -n \"\${_ALPHA_MENU_SOURCED:-}\" ]] || return 90
    zdx-plugins --update alpha --yes || return
    alpha-menu
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha v2"* ]]
}

@test "plugins lifecycle: an update refuses a checkout with local or ignored files" {
  plugin_origin_create alpha
  plugins_install alpha
  plugin_origin_commit alpha "Second" "$(plugin_source alpha v2)"
  printf 'local state\n' > "$PLUGINS_ROOT/alpha/notes.txt"
  local before
  before=$(plugin_tree_fingerprint "$PLUGINS_ROOT/alpha")
  : > "$PLUGINS_GIT_LOG"

  run run_zsh "zdx-plugins --update alpha --yes"

  [ "$status" -eq 1 ]
  [[ "$output" == *"?? notes.txt"* ]]
  [[ "$output" == *"has local, untracked, or ignored files"* ]]
  [ "$(plugin_tree_fingerprint "$PLUGINS_ROOT/alpha")" = "$before" ]
  ! grep -q clone "$PLUGINS_GIT_LOG" || false
}

@test "plugins lifecycle: a rewritten origin history is disclosed before the decision" {
  plugin_origin_create alpha
  plugins_install alpha
  local work="$TEST_TEMP_DIR/work/alpha"
  plugin_source alpha rewritten > "$work/alpha-menu.zsh"
  git -C "$work" commit -q --amend -am "Rewritten history"
  git -C "$work" push -q --force origin main

  run run_zsh "zdx-plugins --update alpha --dry-run"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Commits:"*"(history rewritten)"* ]]
  [[ "$output" == *"does not descend from the installed commit"* ]]
}

@test "plugins lifecycle: a non-Git plugin is skipped by a single update" {
  mkdir -p "$PLUGINS_ROOT/local"
  chmod 700 "$HOME/.config" "$HOME/.config/zdx" "$PLUGINS_ROOT"
  plugin_source local v1 > "$PLUGINS_ROOT/local/local-menu.zsh"

  run run_zsh "zdx-plugins --update local --yes"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Plugin 'local' is not Git-tracked; nothing to update."* ]]
}

@test "plugins lifecycle: --update all reports one step per plugin with a summary" {
  plugin_origin_create alpha
  plugin_origin_create beta
  plugins_install alpha
  plugins_install beta
  mkdir -p "$PLUGINS_ROOT/local"
  plugin_source local v1 > "$PLUGINS_ROOT/local/local-menu.zsh"
  local old new
  old=$(plugin_origin_head alpha)
  plugin_origin_commit alpha "Second" "$(plugin_source alpha v2)"
  new=$(plugin_origin_head alpha)

  run run_zsh "zdx-plugins --update --yes"

  [ "$status" -eq 0 ]
  [[ "$output" == *"--yes trusts every changed plugin without a prompt."* ]]
  [[ "$output" == *"[1/3] alpha — updated: ${old:0:7} → ${new:0:7} · 1 commit"* ]]
  [[ "$output" == *"[2/3] beta — current"* ]]
  [[ "$output" == *"[3/3] local — skipped: not Git-tracked"* ]]
  [[ "$output" == *"Plugin Update Summary"* ]]
  [[ "$output" == *"Plugin update completed: 1 updated, 1 current, 1 skipped."* ]]
  [[ "$output" != *"(s)"* ]]
  [ "$(plugin_installed_head alpha)" = "$new" ]
  # Each step ends its own transaction before the next plugin starts.
  [ -z "$(plugins_staging_left)" ]
}

@test "plugins lifecycle: --update all reports partial failures with a retry hint" {
  plugin_origin_create alpha
  plugin_origin_create beta
  plugins_install alpha
  plugins_install beta
  plugin_origin_commit alpha "Broken" $'alpha-menu() {\n  print "broken\n}'
  plugin_origin_commit beta "Second" "$(plugin_source beta v2)"

  run run_zsh "zdx-plugins --update --yes"

  [ "$status" -eq 1 ]
  [[ "$output" == *"[1/2] alpha — failed: validation failed"* ]]
  [[ "$output" == *"[2/2] beta — updated"* ]]
  [[ "$output" == *"Plugin update completed with partial failures: 1 of 2 plugins failed."* ]]
  [[ "$output" == *"Retry: zdx-plugins --update alpha"* ]]
  [ -z "$(plugins_staging_left)" ]
}

@test "plugins lifecycle: --update all without a terminal or --yes refuses before any fetch" {
  plugin_origin_create alpha
  plugins_install alpha
  : > "$PLUGINS_GIT_LOG"

  run run_zsh "zdx-plugins --update"

  [ "$status" -eq 1 ]
  [[ "$output" == *"--yes"* ]]
  [ ! -s "$PLUGINS_GIT_LOG" ]
}

# --- Concurrency and interruption -------------------------------------------------

@test "plugins lifecycle: a concurrent operation holding the lock is refused" {
  plugin_origin_create alpha
  plugins_install alpha
  plugin_origin_commit alpha "Second" "$(plugin_source alpha v2)"
  local before
  before=$(plugin_tree_fingerprint "$PLUGINS_ROOT/alpha")
  zsh -fc '
    emulate -R zsh
    zmodload zsh/system || exit 1
    zsystem flock -f fd "$1" || exit 1
    print -r -- held > "$2"
    sleep 60
  ' zdx-test-lock "$PLUGINS_ROOT/.zdx-plugins.lock" "$TEST_TEMP_DIR/held" \
    >/dev/null 2>&1 &
  PLUGINS_LOCK_HOLDER=$!
  local tries=0
  while [[ ! -s "$TEST_TEMP_DIR/held" ]] && (( tries++ < 200 )); do
    sleep 0.05
  done
  [ -s "$TEST_TEMP_DIR/held" ]
  : > "$PLUGINS_GIT_LOG"

  run run_zsh "zdx-plugins --update alpha --yes"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Another zdx-plugins operation holds the plugin lock"* ]]
  [ "$(plugin_tree_fingerprint "$PLUGINS_ROOT/alpha")" = "$before" ]
  [ ! -s "$PLUGINS_GIT_LOG" ]
}

@test "plugins lifecycle: an interrupted fetch removes its staging and keeps the plugin" {
  plugin_origin_create alpha
  plugins_install alpha
  plugin_origin_commit alpha "Second" "$(plugin_source alpha v2)"
  local before
  before=$(plugin_tree_fingerprint "$PLUGINS_ROOT/alpha")
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == clone ]]; then
  "$PLUGINS_REAL_GIT" "$@" >/dev/null 2>&1
  kill -INT "$ZDX_TEST_SHELL_PID"
  exit 130
fi
exec "$PLUGINS_REAL_GIT" "$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/git"

  run run_zsh '
    export ZDX_TEST_SHELL_PID=$$
    TRAPINT() { return $(( 128 + $1 )); }
    zdx-plugins --update alpha --yes
  '

  # A non-interactive shell reports the interrupt with a non-zero status.
  [ "$status" -ne 0 ]
  [ "$(plugin_tree_fingerprint "$PLUGINS_ROOT/alpha")" = "$before" ]
  [ -z "$(plugins_staging_left)" ]
}

@test "plugins lifecycle: an interruption while sourcing rolls the update back" {
  plugin_origin_create alpha
  plugins_install alpha
  local old before
  old=$(plugin_origin_head alpha)
  plugin_origin_commit alpha "Interrupts its own source" \
    "$(plugin_source alpha v2)"$'\n''kill -INT $$'
  before=$(plugin_tree_fingerprint "$PLUGINS_ROOT/alpha")

  run run_zsh '
    TRAPINT() { return $(( 128 + $1 )); }
    zdx-plugins --update alpha --yes
  '

  # A non-interactive shell reports the interrupt with a non-zero status.
  [ "$status" -ne 0 ]
  [[ "$output" == *"Rolled back 'alpha' after an interrupted activation."* ]]
  [ "$(plugin_installed_head alpha)" = "$old" ]
  [ "$(plugin_tree_fingerprint "$PLUGINS_ROOT/alpha")" = "$before" ]
  [ -z "$(plugins_staging_left)" ]
}

@test "plugins lifecycle: the next run restores a version stranded between renames" {
  plugin_origin_create alpha
  plugins_install alpha
  local before stage
  before=$(plugin_tree_fingerprint "$PLUGINS_ROOT/alpha")
  # A hard kill after the first rename leaves the previous version in staging.
  stage="$PLUGINS_ROOT/.zdx-staging.alpha.AbC123"
  mkdir -m 700 "$stage"
  mkdir -m 700 "$stage/alpha"
  mv "$PLUGINS_ROOT/alpha" "$stage/previous"
  # A second leftover holds only a partial clone and is discarded.
  mkdir -m 700 "$PLUGINS_ROOT/.zdx-staging.beta.XyZ789"
  mkdir -m 700 "$PLUGINS_ROOT/.zdx-staging.beta.XyZ789/beta"

  run run_zsh 'zdx-plugins --list'
  [ "$status" -eq 0 ]
  [[ "$output" == *"An interrupted plugin transaction left staging"* ]]

  run run_zsh "zdx-plugins --update alpha --dry-run"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Restored plugin 'alpha' from an interrupted transaction."* ]]
  [[ "$output" == *"Removed staging left by an interrupted transaction"* ]]
  [[ "$output" == *"Plugin 'alpha' is current at"* ]]
  [ -z "$(plugins_staging_left)" ]
  # Both renames keep the directory itself, so even its identity is unchanged.
  [ "$(plugin_tree_fingerprint "$PLUGINS_ROOT/alpha")" = "$before" ]
}

@test "plugins lifecycle: recovery never deletes a previous version automatically" {
  plugin_origin_create alpha
  plugins_install alpha
  # A hard kill after publication leaves the new version in place and the
  # previous one in staging; only the user decides when to delete it.
  local stage="$PLUGINS_ROOT/.zdx-staging.alpha.AbC123"
  mkdir -m 700 "$stage" "$stage/previous"
  printf 'old\n' > "$stage/previous/alpha-menu.zsh"

  run run_zsh "zdx-plugins --update alpha --dry-run"

  [ "$status" -eq 0 ]
  [[ "$output" == *"kept its previous version in ~/.config/zdx/plugins/.zdx-staging.alpha.AbC123/previous"* ]]
  [ -f "$stage/previous/alpha-menu.zsh" ]
  [ -d "$PLUGINS_ROOT/alpha/.git" ]
}

@test "plugins lifecycle: unexpected staging in the root fails closed" {
  plugin_origin_create alpha
  plugins_install alpha
  printf 'not a directory\n' > "$PLUGINS_ROOT/.zdx-staging.alpha.AbC123"

  run run_zsh "zdx-plugins --update alpha --yes"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Refusing unexpected staging in the plugin root"* ]]
  [ -f "$PLUGINS_ROOT/.zdx-staging.alpha.AbC123" ]
}

@test "plugins lifecycle: a nested run inside an active operation is refused" {
  plugin_origin_create alpha
  plugin_origin_commit alpha "Reenters the manager" \
    "$(plugin_source alpha v1)"$'\n''zdx-plugins --update alpha --yes || print -u2 -r -- "NESTED REFUSED"'

  run -0 run_zsh "zdx-plugins --install '$(plugin_origin_url alpha)' --yes"

  [[ "$output" == *"A zdx-plugins operation is already running in this shell."* ]]
  [[ "$output" == *"NESTED REFUSED"* ]]
}

@test "F3-04 invariant: plugin installation activates outside emulated transaction preparation" {
  f304_mock_local_probes
  plugin_origin_create alpha
  plugin_origin_commit alpha "Option-changing plugin" \
    $'setopt null_glob\ntypeset -g ALPHA_SOURCE_OPTION=on\nalpha-menu() { print -r -- alpha; }'
  export F304_ORIGIN
  F304_ORIGIN=$(plugin_origin_url alpha)
  [[ "$F304_ORIGIN" == "$TEST_TEMP_DIR/origins/"*.git ]]
  run run_zsh '
    builtin cd -- "$HOME" || exit 80
    unsetopt null_glob
    zdx-plugins --install "$F304_ORIGIN" --yes || exit 31
    [[ -o null_glob && "$ALPHA_SOURCE_OPTION" == on ]] || exit 32
    alpha-menu
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *alpha* ]]
}


@test "F3-04 invariant: plugin update activates outside emulated transaction preparation" {
  f304_mock_local_probes
  [[ "$(plugin_origin_url alpha)" == "$TEST_TEMP_DIR/origins/"*.git ]]
  plugin_origin_create alpha
  plugins_install alpha || false
  plugin_origin_commit alpha "Option-changing update" \
    $'setopt null_glob\ntypeset -g ALPHA_SOURCE_OPTION=on\nalpha-menu() { print -r -- alpha-updated; }'
  run run_zsh '
    builtin cd -- "$HOME" || exit 80
    unsetopt null_glob
    zdx-plugins --update alpha --yes || exit 31
    [[ -o null_glob && "$ALPHA_SOURCE_OPTION" == on ]] || exit 32
    alpha-menu
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *alpha-updated* ]]
}

# Additional F3-04 acceptance cases for test/plugins_lifecycle.bats.
# Its setup already loads test_helper and plugins_test_helper.
# shellcheck disable=SC2016

f304a_plugin_sandbox() {
  [[ "$TEST_TEMP_DIR" == /* && "$HOME" == "$TEST_TEMP_DIR/home" \
    && "$PLUGINS_ROOT" == "$HOME/.config/zdx/plugins" \
    && "$PLUGINS_REAL_GIT" == /* && -x "$PLUGINS_REAL_GIT" ]] || return 98
  cd "$HOME" || return 99
}

f304a_plugin_programs() {
  cat > "$HOME/f304a-clean.zsh" <<'ZSH'
emulate -R zsh
_f304a_assert_runtime_clean() {
  (( ! ${+_zdx_plugins_session} && ! ${+_zdx_plugins_tx} \
    && ! ${+_ZDX_PLUGINS_LOCK_FD} )) || return 71
  local -a stages=("$PLUGINS_ROOT"/.zdx-staging.*(DN))
  (( ${#stages} == 0 )) || return 72
  # A different process must be able to take the persistent lock immediately.
  # Merely clearing the descriptor variable would not establish this.
  command zsh -f -c '
    emulate -R zsh
    zmodload zsh/system || exit 73
    local probe_fd=""
    zsystem flock -t 0 -f probe_fd "$1" || exit 74
    zsystem flock -u "$probe_fd"
  ' _ "$PLUGINS_ROOT/.zdx-plugins.lock" || return 75
}
ZSH
  cat > "$HOME/f304a-manager.zsh" <<'ZSH'
emulate -R zsh
builtin cd -- "$HOME" || exit 80
source "$HOME/f304a-clean.zsh" || exit 81
typeset -gi F304A_PICK_COUNT=0
_zdx_plugins_fzf_capture() {
  (( F304A_PICK_COUNT += 1 ))
  if (( F304A_PICK_COUNT > 1 )); then
    REPLY=""
    return 130
  fi
  local row=""
  while IFS= read -r row; do
    if [[ "$row" == *'|install|'* ]]; then
      REPLY="$row"
      print -r -- install >> "$HOME/manager.selections"
      return 0
    fi
  done
  return 1
}
# Availability and trust are the only authorization boundaries mocked.
# After source entered, skip the manager's return-to-menu key prompt.
_zdx_plugins_terminal() { [[ ! -e "$HOME/alpha-entered" ]]; }
_zdx_plugins_confirm() { return 0; }
unsetopt ksh_arrays
zdx-plugins < "$HOME/manager.input" > "$HOME/manager.stdout" 2> "$HOME/manager.stderr"
local operation_rc=$? kept="${options[ksharrays]}"
unsetopt ksh_arrays
[[ "$operation_rc" == 0 && "$kept" == "$F304A_EXPECT_KSH" ]] || exit 31
[[ "$ALPHA_SOURCE_OPTION" == "$F304A_EXPECT_KSH" && "$F304A_PICK_COUNT" == 2 ]] || exit 32
[[ "${ZDX_LOADED_PLUGINS[(Ie)alpha]}" != 0 && "${ZDX_DISCOVERED_PLUGINS[(Ie)alpha]}" != 0 ]] || exit 33
alpha-menu "one two" --literal > "$HOME/alpha.data" || exit 34
[[ "$(<"$HOME/alpha.data")" == "alpha-v2:<one two>${(#):-10}alpha-v2:<--literal>" \
  && ! -s "$HOME/manager.stdout" ]] || exit 35
_f304a_assert_runtime_clean || exit $?
print -r -- manager-complete
ZSH
  cat > "$HOME/f304a-aggregate.zsh" <<'ZSH'
emulate -R zsh
builtin cd -- "$HOME" || exit 80
source "$HOME/f304a-clean.zsh" || exit 81
unsetopt ksh_arrays
zdx-plugins --update --yes > "$HOME/aggregate.stdout" 2> "$HOME/aggregate.stderr"
local operation_rc=$? kept="${options[ksharrays]}"
unsetopt ksh_arrays
[[ "$operation_rc" == 0 && "$kept" == "$F304A_EXPECT_KSH" ]] || exit 31
[[ "$ALPHA_SOURCE_OPTION" == "$F304A_EXPECT_KSH" && "$BETA_SOURCE_OPTION" == "$F304A_EXPECT_KSH" ]] || exit 32
[[ "${ZDX_LOADED_PLUGINS[(Ie)alpha]}" != 0 && "${ZDX_LOADED_PLUGINS[(Ie)beta]}" != 0 ]] || exit 33
alpha-menu "one two" > "$HOME/alpha.data" || exit 34
beta-menu "three four" > "$HOME/beta.data" || exit 35
[[ "$(<"$HOME/alpha.data")" == "alpha-v2:<one two>" \
  && "$(<"$HOME/beta.data")" == "beta-v2:<three four>" \
  && ! -s "$HOME/aggregate.stdout" ]] || exit 36
local report="$(<"$HOME/aggregate.stderr")"
[[ "$report" == *'[1/2] alpha — updated'* && "$report" == *'[2/2] beta — updated'* ]] || exit 37
_f304a_assert_runtime_clean || exit $?
print -r -- aggregate-complete
ZSH
  cat > "$HOME/f304a-rollback.zsh" <<'ZSH'
emulate -R zsh
builtin cd -- "$HOME" || exit 80
source "$HOME/f304a-clean.zsh" || exit 81
f304a-protected() { print -r -- original; }
unsetopt ksh_arrays
zdx-plugins --update alpha --yes > "$HOME/rollback.stdout" 2> "$HOME/rollback.stderr"
local operation_rc=$? kept="${options[ksharrays]}"
unsetopt ksh_arrays
[[ "$operation_rc" == 1 && "$kept" == "$F304A_EXPECT_KSH" ]] || exit 31
[[ "$ALPHA_SOURCE_OPTION" == "$F304A_EXPECT_KSH" ]] || exit 32
[[ "${ZDX_LOADED_PLUGINS[(Ie)alpha]}" != 0 ]] || exit 33
alpha-menu > "$HOME/alpha.data" || exit 34
f304a-protected > "$HOME/protected.data" || exit 35
[[ "$(<"$HOME/alpha.data")" == "alpha v1" \
  && "$(<"$HOME/protected.data")" == original && ! -s "$HOME/rollback.stdout" ]] || exit 36
(( ! ${+functions[f304a-leaked]} )) || exit 37
if [[ "$F304A_ROLLBACK_KIND" == source ]]; then
  local report="$(<"$HOME/rollback.stderr")"
  [[ "$report" == *"Sourcing 'alpha-menu.zsh' failed with status 3."* ]] || exit 38
fi
_f304a_assert_runtime_clean || exit $?
print -r -- rollback-complete
ZSH
  local program
  for program in "$HOME/f304a-clean.zsh" "$HOME/f304a-manager.zsh" \
    "$HOME/f304a-aggregate.zsh" "$HOME/f304a-rollback.zsh"; do
    zsh -n "$program" || return 96
  done
}

# The name and mode arguments are fixed fixture values; every path is below
# TEST_TEMP_DIR and every origin is a local bare repository.
f304a_plugin_source() {
  local name="$1" mode="$2"
  case "$mode" in
    on) printf '%s\n' 'setopt ksh_arrays' ;;
    off) printf '%s\n' 'unsetopt ksh_arrays' ;;
    inherit) ;;
    *) return 97 ;;
  esac
  printf 'if [[ -o ksh_arrays ]]; then typeset -g %s_SOURCE_OPTION=on; else typeset -g %s_SOURCE_OPTION=off; fi\n' "${name^^}" "${name^^}"
  printf 'print -r -- "$%s_SOURCE_OPTION" > "$HOME/%s-entered"\n' "${name^^}" "$name"
  printf '%s-menu() { printf '\''%s-v2:<%%s>\\n'\'' "$@"; }\n' "$name" "$name"
}

f304a_plugin_diagnostic() {
  local label="$1" child_status="$2"
  if [[ "$child_status" -ne 0 ]]; then
    printf '# %s shell status=%s; alpha-entered=%s; beta-entered=%s\n' \
      "$label" "$child_status" \
      "$(cat "$HOME/alpha-entered" 2>/dev/null || printf absent)" \
      "$(cat "$HOME/beta-entered" 2>/dev/null || printf absent)"
    printf '%s\n' "$output"
    local report
    for report in manager aggregate rollback; do
      [[ ! -f "$HOME/$report.stderr" ]] || cat "$HOME/$report.stderr"
    done
  fi
}

f304a_manager_workflow() {
  f304a_plugin_sandbox || return
  f304a_plugin_programs || return
  local mode="$1"
  export F304A_EXPECT_KSH="$mode"
  plugin_origin_create alpha
  plugin_origin_commit alpha "Option mode $mode" "$(f304a_plugin_source alpha "$mode")"
  local expected_head origin
  expected_head=$(plugin_origin_head alpha)
  origin=$(plugin_origin_url alpha)
  [[ "$origin" == "$TEST_TEMP_DIR/origins/alpha.git" ]] || return 90
  printf '%s\n\n' "$origin" > "$HOME/manager.input"
  run run_zsh 'source "$HOME/f304a-manager.zsh"'
  f304a_plugin_diagnostic manager "$status"
  [ "$status" -eq 0 ]
  [ "$output" = manager-complete ]
  [ "$(plugin_installed_head alpha)" = "$expected_head" ]
  [ "$(cat "$HOME/manager.selections")" = install ]
  [ -z "$(plugins_staging_left)" ]
  [ "$(file_mode "$PLUGINS_ROOT/.zdx-plugins.lock")" = 600 ]
}

f304a_aggregate_workflow() {
  f304a_plugin_sandbox || return
  f304a_plugin_programs || return
  local mode="$1"
  export F304A_EXPECT_KSH="$mode"
  local name
  for name in alpha beta; do
    plugin_origin_create "$name"
    plugins_install "$name" || return 90
  done
  plugin_origin_commit alpha "Option mode $mode" "$(f304a_plugin_source alpha "$mode")"
  plugin_origin_commit beta "Observe inherited option" "$(f304a_plugin_source beta inherit)"
  local alpha_head beta_head
  alpha_head=$(plugin_origin_head alpha)
  beta_head=$(plugin_origin_head beta)
  run run_zsh 'source "$HOME/f304a-aggregate.zsh"'
  f304a_plugin_diagnostic aggregate "$status"
  [ "$status" -eq 0 ]
  [ "$output" = aggregate-complete ]
  [ "$(plugin_installed_head alpha)" = "$alpha_head" ]
  [ "$(plugin_installed_head beta)" = "$beta_head" ]
  [ -z "$(plugins_staging_left)" ]
  [ "$(file_mode "$PLUGINS_ROOT/.zdx-plugins.lock")" = 600 ]
}

f304a_rollback_workflow() {
  f304a_plugin_sandbox || return
  f304a_plugin_programs || return
  local mode="$1"
  export F304A_EXPECT_KSH="$mode"
  plugin_origin_create alpha
  plugins_install alpha || return 90
  local old_head before content kind
  old_head=$(plugin_installed_head alpha)
  # First isolate source failure3 with an otherwise allowed namespace.
  # Then independently exercise changed/added foreign function restoration.
  for kind in source namespace; do
    export F304A_ROLLBACK_KIND="$kind"
    content="$(f304a_plugin_source alpha "$mode")"
    if [[ "$kind" == namespace ]]; then
      content+=$'\n''f304a-protected() { print -r -- replaced; }'$'\n''f304a-leaked() { print -r -- leaked; }'
    fi
    content+=$'\n''return 3'
    plugin_origin_commit alpha "Fail $kind with option mode $mode" "$content"
    before=$(plugin_tree_fingerprint "$PLUGINS_ROOT/alpha")
    run run_zsh 'source "$HOME/f304a-rollback.zsh"'
    f304a_plugin_diagnostic "rollback-$kind" "$status"
    [ "$status" -eq 0 ]
    [ "$output" = rollback-complete ]
    [ "$(plugin_installed_head alpha)" = "$old_head" ]
    [ "$(plugin_tree_fingerprint "$PLUGINS_ROOT/alpha")" = "$before" ]
    [ -z "$(plugins_staging_left)" ]
    [ "$(file_mode "$PLUGINS_ROOT/.zdx-plugins.lock")" = 600 ]
  done
}

@test "F3-04 workflow control: actual manager installation without an option change" {
  f304a_manager_workflow off
}

@test "F3-04 acceptance: actual manager installation preserves changed KSH_ARRAYS" {
  f304a_manager_workflow on
}

@test "F3-04 workflow control: actual two-plugin aggregate without an option change" {
  f304a_aggregate_workflow off
}

@test "F3-04 acceptance: actual two-plugin aggregate preserves changed KSH_ARRAYS" {
  f304a_aggregate_workflow on
}

@test "F3-04 workflow control: failed activation restores the namespace without an option change" {
  f304a_rollback_workflow off
}

@test "F3-04 acceptance: failed activation keeps changed KSH_ARRAYS while restoring the namespace" {
  f304a_rollback_workflow on
}
