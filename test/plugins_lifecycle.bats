#!/usr/bin/env bats
# shellcheck disable=SC2016

# Staged, trust-gated installs and updates against local bare origins.

setup() {
  load test_helper
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

  run run_zsh "zdx-plugins --install '$(plugin_origin_url alpha)' --yes"

  [[ "$output" == *"A zdx-plugins operation is already running in this shell."* ]]
  [[ "$output" == *"NESTED REFUSED"* ]]
}
