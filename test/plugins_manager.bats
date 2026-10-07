#!/usr/bin/env bats
# shellcheck disable=SC2016

# zdx-plugins grammar, listing, removal, and interactive pickers. Staged
# installs and updates are covered in plugins_lifecycle.bats.

setup() {
  load test_helper
  load plugins_test_helper
  plugins_git_recorder
}

teardown() {
  cleanup_sandbox
}

# --- Grammar and help -----------------------------------------------------------

@test "zdx-plugins: --help documents every action and flag on stderr" {
  run run_zsh "zdx-plugins --help 2>/dev/null"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run run_zsh "zdx-plugins --help"
  [ "$status" -eq 0 ]
  [[ "$output" == *"zdx-plugins --list"* ]]
  [[ "$output" == *"zdx-plugins --install <url> [name] [--dry-run] [--yes]"* ]]
  [[ "$output" == *"zdx-plugins --update [name] [--dry-run] [--yes]"* ]]
  [[ "$output" == *"zdx-plugins --remove <name> [--dry-run] [--yes]"* ]]
  [[ "$output" == *"not sandboxed"* ]]
}

@test "zdx-plugins: invalid grammar returns 2 before any probe" {
  local -a cases=(
    "--bogus"
    "--list extra"
    "--install"
    "--install url name extra"
    "--install url --force"
    "--update one two"
    "--remove"
    "--remove one two"
  )
  local case_args
  for case_args in "${cases[@]}"; do
    run run_zsh "zdx-plugins $case_args"
    [ "$status" -eq 2 ]
  done
  [ ! -s "$PLUGINS_GIT_LOG" ]
  [ ! -e "$PLUGINS_ROOT" ]
}

@test "zdx-plugins: --install rejects invalid names and option-like URLs" {
  run run_zsh "zdx-plugins --install https://github.com/example/invalid@name --yes"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Plugin name 'invalid@name' is invalid"* ]]

  run run_zsh "zdx-plugins --install -- --upload-pack=evil --yes"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Invalid Git URL"* ]]
  [ ! -s "$PLUGINS_GIT_LOG" ]
}

@test "zdx-plugins: origin display redacts credentials, queries, and fragments" {
  run run_zsh '
    local url=""
    for url in \
      "https://user:token@example.com/org/plugin.git" \
      "https://token@example.com/org/plugin@v1.git" \
      "ssh://git@example.com/org/plugin.git" \
      "git@example.com:org/plugin.git" \
      "https://example.com/org/plugin.git?access_token=secret#frag"; do
      _zdx_plugins_redact_url "$url"
      print -r -- "$REPLY"
    done
  '
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "https://***@example.com/org/plugin.git" ]
  [ "${lines[1]}" = "https://***@example.com/org/plugin@v1.git" ]
  [ "${lines[2]}" = "ssh://***@example.com/org/plugin.git" ]
  [ "${lines[3]}" = "git@example.com:org/plugin.git" ]
  [ "${lines[4]}" = "https://example.com/org/plugin.git (query or fragment redacted)" ]
  [[ "$output" != *token* && "$output" != *secret* ]]
}

@test "zdx-plugins: completion offers actions, installed names, and unused flags" {
  mkdir -p "$PLUGINS_ROOT/alpha" "$PLUGINS_ROOT/beta" "$PLUGINS_ROOT/bad.name"
  run zsh -f -c '
    _describe() { local array_name="$4"; print -rl -- "${(@P)array_name}"; }
    _message() { print -r -- "message: $1"; }
    _test_completion() { source "$1/completions/_zdx-menu"; }
    service=zdx-plugins
    words=(zdx-plugins ""); CURRENT=2
    _test_completion "$1" || exit
    print -r -- ---
    words=(zdx-plugins --update --yes ""); CURRENT=4
    _test_completion "$1" || exit
    print -r -- ---
    words=(zdx-plugins --install ""); CURRENT=3
    _test_completion "$1" || exit
    print -r -- ---
    # The master route reaches the same grammar without loading any suite.
    _arguments() { state=suite-arguments; }
    service=zdx
    words=(plugins --remove ""); CURRENT=3
    _test_completion "$1" || exit
    [[ -z "${_ZDX_COMMON_SOURCED:-}${_ZDX_PLUGINS_SOURCED:-}" ]]
  ' _ "$TEST_SUITE_ROOT"

  [ "$status" -eq 0 ]
  local expected
  expected=$(cat <<'EXPECTED'
--list:list installed plugins
--install:fetch, review, and activate a plugin from a Git URL
--update:stage, review, and activate plugin updates
--remove:review and remove one installed plugin
--help:show plugin manager help
---
alpha
beta
--dry-run:fetch and validate, or plan, without changing anything
---
message: Git URL or local repository path
---
alpha
beta
--dry-run:fetch and validate, or plan, without changing anything
--yes:trust or confirm without a prompt
EXPECTED
)
  [ "$output" = "$expected" ]
}

@test "zdx-plugins: the plugin wrapper registers zdx-plugins completion" {
  head -n 1 "$TEST_SUITE_ROOT/completions/_zdx-menu" \
    | grep -qx '#compdef zdx zdx-menu zdx-status zdx-plugins'
}

# --- List ---------------------------------------------------------------------------

@test "zdx-plugins: --list reports an empty root without creating it" {
  run run_zsh "zdx-plugins --list"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No plugins installed."* ]]
  [ ! -e "$PLUGINS_ROOT" ]
}

@test "zdx-plugins: --list shows status and a redacted origin on stderr only" {
  plugin_origin_create alpha
  plugins_install alpha
  git -C "$PLUGINS_ROOT/alpha" remote set-url origin \
    "https://user:secret-token@example.com/org/alpha.git"
  mkdir -p "$PLUGINS_ROOT/broken"

  run run_zsh "zdx-plugins --list 2>/dev/null"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run run_zsh "zdx-plugins --list"
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha"*"Active"*"https://***@example.com/org/alpha.git"* ]]
  [[ "$output" == *"broken"*"Invalid"* ]]
  [[ "$output" != *"secret-token"* ]]
  [[ "$output" != *".zdx-plugins.lock"* ]]
}

@test "zdx-plugins: a root created under a permissive umask still loads" {
  plugin_origin_create umask-plugin
  run run_zsh "
    umask 002
    zdx-plugins --install '$(plugin_origin_url umask-plugin)' --yes >/dev/null 2>&1 \
      || return 90
    zmodload -F zsh/stat b:zstat || return 91
    local -A state=()
    zstat -LH state -- \"\$HOME/.config/zdx/plugins\" || return 92
    print -r -- \"root-mode=\$(( [##8] state[mode] & 8#777 ))\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "root-mode=700" ]

  run run_zsh '
    umask-plugin-menu
    print -r -- "loaded=${ZDX_LOADED_PLUGINS[*]}"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"umask-plugin v1"* ]]
  [[ "$output" == *"loaded=umask-plugin"* ]]
  [[ "$output" != *"refusing unsafe plugin root"* ]]
}

# --- Remove ---------------------------------------------------------------------------

@test "zdx-plugins: --remove --dry-run prints the exact plan and deletes nothing" {
  plugin_origin_create alpha
  plugins_install alpha
  local before head
  before=$(plugin_tree_fingerprint "$PLUGINS_ROOT/alpha")
  head=$(plugin_origin_head alpha)

  run run_zsh "zdx-plugins --remove alpha --dry-run"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Plugin:"*"alpha"* ]]
  [[ "$output" == *"Path:"*"~/.config/zdx/plugins/alpha"* ]]
  [[ "$output" == *"Origin:"*"$(plugin_origin_url alpha)"* ]]
  [[ "$output" == *"Commit:"*"${head:0:7}"* ]]
  [[ "$output" == *"Loaded:"*"yes"* ]]
  [[ "$output" == *"Dry run: 1 plugin planned; nothing was removed."* ]]
  [ "$(plugin_tree_fingerprint "$PLUGINS_ROOT/alpha")" = "$before" ]
}

@test "zdx-plugins: --remove without a terminal or --yes refuses" {
  plugin_origin_create alpha
  plugins_install alpha

  run run_zsh "echo y | zdx-plugins --remove alpha"

  [ "$status" -eq 1 ]
  [[ "$output" == *"--yes"* ]]
  [ -d "$PLUGINS_ROOT/alpha" ]
}

@test "zdx-plugins: --remove --yes deletes the plugin and unregisters it" {
  plugin_origin_create alpha
  plugins_install alpha

  run run_zsh "
    alpha-menu
    zdx-plugins --remove alpha --yes || return
    (( \${+functions[alpha-menu]} )) && print -r -- DEFINED
    print -r -- \"loaded=\${ZDX_LOADED_PLUGINS[*]}\"
    zdx-plugins --list
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha v1"* ]]
  [[ "$output" == *"Plugin 'alpha' removed."* ]]
  [[ "$output" != *DEFINED* ]]
  [[ "$output" == *"loaded="* && "$output" != *"loaded=alpha"* ]]
  [[ "$output" == *"No plugins installed"* ]]
  [ ! -e "$PLUGINS_ROOT/alpha" ]
  [ -z "$(plugins_staging_left)" ]
}

@test "zdx-plugins: a declined removal keeps the plugin" {
  plugin_origin_create alpha
  plugins_install alpha

  run run_zsh "
    _zdx_plugins_terminal() { return 0; }
    _zdx_plugins_confirm() { print -u2 -r -- \"PROMPT: \$1\"; return 1; }
    zdx-plugins --remove alpha
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"PROMPT: Remove plugin 'alpha'?"* ]]
  [[ "$output" == *"Cancelled: nothing was removed."* ]]
  [ -d "$PLUGINS_ROOT/alpha" ]
}

@test "zdx-plugins: --remove revalidates the reviewed directory after confirmation" {
  plugin_origin_create alpha
  plugins_install alpha

  run run_zsh "
    _zdx_plugins_terminal() { return 0; }
    _zdx_plugins_confirm() {
      command mv -- '$PLUGINS_ROOT/alpha' '$PLUGINS_ROOT/alpha-reviewed'
      command mkdir -m 700 -- '$PLUGINS_ROOT/alpha'
      return 0
    }
    zdx-plugins --remove alpha
  "

  [ "$status" -eq 1 ]
  [[ "$output" == *"changed after review; nothing was removed."* ]]
  [ -d "$PLUGINS_ROOT/alpha" ]
  [ -d "$PLUGINS_ROOT/alpha-reviewed/.git" ]
}

@test "zdx-plugins: --remove refuses names that could leave the plugin root" {
  mkdir -p "$PLUGINS_ROOT"
  printf 'keep\n' > "$HOME/.config/zdx/keep"

  local name
  for name in '../../..' '..' 'a/b' '.zdx-staging.x.AbC123'; do
    run run_zsh "zdx-plugins --remove '$name' --yes"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Invalid plugin name"* ]]
  done
  [ -f "$HOME/.config/zdx/keep" ]
  [ -d "$PLUGINS_ROOT" ]
}

@test "zdx-plugins: --remove refuses a plugin directory reached through a link" {
  mkdir -p "$PLUGINS_ROOT" "$HOME/elsewhere"
  printf 'keep\n' > "$HOME/elsewhere/keep"
  ln -s "$HOME/elsewhere" "$PLUGINS_ROOT/linked"

  run run_zsh "zdx-plugins --remove linked --yes"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Plugin 'linked' is not installed."* ]]
  [ -L "$PLUGINS_ROOT/linked" ]
  [ -f "$HOME/elsewhere/keep" ]
}

# --- Interactive pickers ------------------------------------------------------------

# A stateful fzf mock: each call consumes the next response line from
# $PLUGINS_FZF_RESPONSES; an empty line or no line cancels with status 130.
_plugins_fzf_script() {
  export PLUGINS_FZF_RESPONSES="$TEST_TEMP_DIR/fzf-responses"
  export PLUGINS_FZF_CALLS="$TEST_TEMP_DIR/fzf-calls"
  : > "$PLUGINS_FZF_CALLS"
  cat > "$TEST_MOCK_BIN/fzf" <<'MOCK'
#!/usr/bin/env bash
cat > /dev/null
call=$(( $(wc -l < "$PLUGINS_FZF_CALLS") + 1 ))
printf '%s\n' "${*//$'\n'/ }" >> "$PLUGINS_FZF_CALLS"
response=$(sed -n "${call}p" "$PLUGINS_FZF_RESPONSES")
[[ -n "$response" ]] || exit 130
printf '%s\n' "$response"
MOCK
  chmod +x "$TEST_MOCK_BIN/fzf"
}

@test "zdx-plugins: the menu dispatches only an exact snapshot row" {
  _plugins_fzf_script
  printf '%s\n' '  List Installed Plugins|list|Show installed plugins, their status, and their origin.' \
    > "$PLUGINS_FZF_RESPONSES"

  run run_zsh "zdx-plugins"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Installed Plugins"* ]]
  [[ "$output" == *"No plugins installed."* ]]
  [ "$(wc -l < "$PLUGINS_FZF_CALLS")" -eq 2 ]

  printf '%s\n' '  Forged|remove|Not in the snapshot' > "$PLUGINS_FZF_RESPONSES"
  : > "$PLUGINS_FZF_CALLS"
  run run_zsh "zdx-plugins"

  [ "$status" -eq 1 ]
  [[ "$output" == *"was not in the plugin menu snapshot"* ]]
  [[ "$output" != *"Uninstall Plugin"* ]]
}

@test "zdx-plugins: the menu returns 0 on cancellation and leaves no capture file" {
  _plugins_fzf_script
  : > "$PLUGINS_FZF_RESPONSES"

  run run_zsh "zdx-plugins"

  [ "$status" -eq 0 ]
  [ -z "$(find "$TMPDIR" -name 'zdx-plugins-fzf.*' -print)" ]
}

@test "zdx-plugins: the uninstall picker refuses a name outside its snapshot" {
  plugin_origin_create alpha
  plugins_install alpha
  _plugins_fzf_script
  printf '%s\n' \
    '  Uninstall Plugin|remove|Review and remove one installed plugin.' \
    'other-plugin' > "$PLUGINS_FZF_RESPONSES"

  run run_zsh "zdx-plugins"

  [ "$status" -eq 0 ]
  [[ "$output" == *"The selected plugin was not in the picker snapshot."* ]]
  [ -d "$PLUGINS_ROOT/alpha" ]
  [ -z "$(find "$TMPDIR" -name 'zdx-plugins-fzf.*' -print)" ]
}

@test "zdx-plugins: the menu refuses an unsafe temporary root before fzf runs" {
  _plugins_fzf_script
  printf '%s\n' '  List Installed Plugins|list|Show installed plugins, their status, and their origin.' \
    > "$PLUGINS_FZF_RESPONSES"
  chmod 777 "$TMPDIR"

  run run_zsh "zdx-plugins"

  chmod 700 "$TMPDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Refusing an unsafe temporary root for the plugin menu."* ]]
  [ ! -s "$PLUGINS_FZF_CALLS" ]
}

@test "zdx-plugins: the picker capture works below an aliased TMPDIR and cleans up" {
  mkdir -m 700 "$TEST_TEMP_DIR/physical" "$TEST_TEMP_DIR/physical/tmp"
  ln -s "$TEST_TEMP_DIR/physical" "$TEST_TEMP_DIR/alias"
  export MOCK_FZF_MODE=response MOCK_FZF_RESPONSE=picked

  run run_zsh '
    export TMPDIR="$TEST_TEMP_DIR/alias/tmp"
    local -i capture_rc=0
    _zdx_plugins_fzf_capture </dev/null >/dev/null 2>&1 || capture_rc=$?
    print -r -- "rc=$capture_rc reply=$REPLY"
  '

  [ "$status" -eq 0 ]
  [ "$output" = "rc=0 reply=picked" ]
  [ -z "$(find "$TEST_TEMP_DIR/physical/tmp" -mindepth 1 -print)" ]
}

@test "zdx-plugins: sourcing the manager twice is silent and defines no workflow" {
  run zsh -fc '
    source "$1/functions/zdx-plugins.zsh" || exit 1
    source "$1/functions/zdx-plugins.zsh" || exit 1
    (( ${+functions[zdx-plugins]} )) || exit 2
    print -r -- "ok"
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
}

@test "zdx-plugins: lifecycle actions fail closed without the core runtime" {
  plugin_origin_create alpha
  run zsh -fc '
    source "$1/functions/zdx-plugins.zsh" || exit 1
    zdx-plugins --install "$2" --yes
  ' _ "$TEST_SUITE_ROOT" "$(plugin_origin_url alpha)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"needs the ZDX core runtime"* ]]
  [ ! -e "$PLUGINS_ROOT/alpha" ]
}
