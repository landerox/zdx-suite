#!/usr/bin/env zsh
# =============================================================================
# zdx: Oh My Zsh custom plugin wrapper
# =============================================================================

# Loaded by Oh My Zsh.
# Sources the primary functions.zsh entrypoint and registers completions.

if [[ -n "${_ZDX_PLUGIN_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# Find the directory of this plugin (resolving symlinks if any)
typeset _zdx_plugin_dir="${${(%):-%x}:A:h}"

typeset -i _zdx_plugin_source_rc=0
source "$_zdx_plugin_dir/functions.zsh" || _zdx_plugin_source_rc=$?
if (( _zdx_plugin_source_rc != 0 )); then
  print -u2 -r -- "zdx-suite.plugin.zsh: failed to load functions.zsh"
  {
    return $_zdx_plugin_source_rc 2>/dev/null || exit $_zdx_plugin_source_rc
  } always {
    unset _zdx_plugin_dir _zdx_plugin_source_rc
  }
fi

# Oh My Zsh initializes completion before it sources plugin entrypoints. Add
# the directory for direct/manual loaders, then explicitly load and bind each
# owned declaration when compdef is already available.
typeset _zdx_completion_dir="$_zdx_plugin_dir/completions"
typeset -A _zdx_completion_dir_state=()
if ! zmodload -F zsh/stat b:zstat 2>/dev/null \
  || ! zstat -LH _zdx_completion_dir_state \
    -- "$_zdx_completion_dir" 2>/dev/null; then
  print -u2 -r -- \
    "zdx-suite.plugin.zsh: could not inspect the completions directory"
  unset _zdx_plugin_dir _zdx_plugin_source_rc _zdx_completion_dir
  unset _zdx_completion_dir_state
  return 1 2>/dev/null || exit 1
fi
if [[ ! -d "$_zdx_completion_dir" || -L "$_zdx_completion_dir" \
  || ! -O "$_zdx_completion_dir" \
  || "${_zdx_completion_dir:A}" != "$_zdx_completion_dir" ]] \
  || (( (_zdx_completion_dir_state[mode] & 8#170000) != 8#040000 \
    || _zdx_completion_dir_state[uid] != EUID \
    || (_zdx_completion_dir_state[mode] & 8#22) != 0 )); then
  print -u2 -r -- \
    "zdx-suite.plugin.zsh: refusing an unsafe completions directory"
  unset _zdx_plugin_dir _zdx_plugin_source_rc _zdx_completion_dir
  unset _zdx_completion_dir_state
  return 1 2>/dev/null || exit 1
fi
unset _zdx_completion_dir_state
if (( ${fpath[(Ie)$_zdx_completion_dir]} == 0 )); then
  fpath=("$_zdx_completion_dir" "${fpath[@]}")
fi

_zdx_register_completion_file() {
  local completion_file="$1"
  local completion_name="${completion_file:t}"
  local -A completion_state=()
  [[ "$completion_name" =~ '^_[a-z][a-z0-9-]*$' \
    && -f "$completion_file" && ! -L "$completion_file" \
    && -O "$completion_file" && -r "$completion_file" \
    && "${completion_file:A}" == "$completion_file" \
    && "${completion_file:A:h}" == "$_zdx_completion_dir" ]] \
    && zstat -LH completion_state -- "$completion_file" 2>/dev/null \
    && (( (completion_state[mode] & 8#170000) == 8#100000 \
      && completion_state[uid] == EUID \
      && completion_state[nlink] == 1 \
      && (completion_state[mode] & 8#22) == 0 \
      && completion_state[size] >= 1 \
      && completion_state[size] <= 1024 * 1024 )) || return 1

  local declaration=""
  IFS= read -r declaration < "$completion_file" || return 1
  [[ "$declaration" == '#compdef '* \
    && "$declaration" != *[[:cntrl:]]* ]] || return 1
  local -a completion_commands=(
    "${(@s: :)${declaration#\#compdef }}"
  )
  (( ${#completion_commands[@]} > 0 )) || return 1
  local completion_command=""
  for completion_command in "${completion_commands[@]}"; do
    [[ "$completion_command" =~ '^[a-z][a-z0-9-]*$' ]] || return 1
  done

  autoload -Uz "$completion_name" || return 1
  autoload +X "$completion_name" || return 1
  compdef "$completion_name" "${completion_commands[@]}"
}

if (( ${+functions[compdef]} )); then
  typeset _zdx_completion_file=""
  for _zdx_completion_file in "$_zdx_completion_dir"/_*-menu(N); do
    _zdx_register_completion_file "$_zdx_completion_file" || {
      _zdx_plugin_source_rc=$?
      print -u2 -r -- \
        "zdx-suite.plugin.zsh: failed to register ${_zdx_completion_file:t}"
      break
    }
  done
  unset _zdx_completion_file
  if (( _zdx_plugin_source_rc != 0 )); then
    unset -f _zdx_register_completion_file
    unset _zdx_plugin_dir _zdx_plugin_source_rc _zdx_completion_dir
    return 1 2>/dev/null || exit 1
  fi
fi
unset -f _zdx_register_completion_file

# --- Zsh Keyboard Shortcuts & Bindings ----------------------------------------
if [[ "${ZDX_KEYBINDINGS:-1}" == "1" ]] && [[ -o interactive ]] && (( $+widgets )); then
  # Git menu widget (Ctrl+G)
  _zdx_git_menu_widget() {
    zle -I
    git-menu
    zle redisplay
  }
  zle -N git-menu-widget _zdx_git_menu_widget
  typeset _zdx_key_git="${ZDX_KEY_GIT:-^G}"
  [[ -n "$_zdx_key_git" ]] && bindkey "$_zdx_key_git" git-menu-widget
  unset _zdx_key_git

  # Insert pickers (zdx-insert-branch, -pr, -port, -venv). Their bodies live
  # in functions/zdx-widgets.zsh, which the first use loads, so startup only
  # registers names. A chord is bound only while it is unbound in the main
  # keymap, so a user or Oh My Zsh binding always wins; an empty
  # ZDX_KEY_INSERT_* value leaves that widget unbound.
  _zdx_insert_widget() {
    if [[ -z "${_ZDX_WIDGETS_SOURCED:-}" ]]; then
      local widget_file="${_ZDX_FUNCTIONS_DIR:-}/zdx-widgets.zsh"
      if [[ -z "${_ZDX_FUNCTIONS_DIR:-}" || ! -f "$widget_file" \
        || -L "$widget_file" || ! -r "$widget_file" ]] \
        || ! builtin source "$widget_file" \
        || [[ -z "${_ZDX_WIDGETS_SOURCED:-}" ]]; then
        zle -M "zdx: could not load zdx-widgets.zsh"
        return 1
      fi
    fi
    _zdx_widget_insert "$@"
  }
  _zdx_insert_branch_widget() { _zdx_insert_widget branch; }
  _zdx_insert_pr_widget() { _zdx_insert_widget pr; }
  _zdx_insert_port_widget() { _zdx_insert_widget port; }
  _zdx_insert_venv_widget() { _zdx_insert_widget venv; }
  zle -N zdx-insert-branch _zdx_insert_branch_widget
  zle -N zdx-insert-pr _zdx_insert_pr_widget
  zle -N zdx-insert-port _zdx_insert_port_widget
  zle -N zdx-insert-venv _zdx_insert_venv_widget

  # The anonymous function keeps the binding pass local and independent of
  # the caller's options.
  () {
    emulate -L zsh
    local -a chords=(
      zdx-insert-branch "${ZDX_KEY_INSERT_BRANCH-^Xb}"
      zdx-insert-pr "${ZDX_KEY_INSERT_PR-^Xp}"
      zdx-insert-port "${ZDX_KEY_INSERT_PORT-^Xo}"
      zdx-insert-venv "${ZDX_KEY_INSERT_VENV-^Xv}"
    )
    local widget_name="" chord=""
    # One subshell reads every current binding: an unbound chord prints
    # `"<chord>" undefined-key`, and every chord yields exactly one line.
    local -a bindings=("${(@f)$(
      for widget_name chord in "${chords[@]}"; do
        if [[ -z "$chord" ]]; then
          print -r -- disabled
        else
          bindkey -M main -- "$chord" 2>/dev/null || print -r -- invalid
        fi
      done
    )}")
    local -i index=0
    for widget_name chord in "${chords[@]}"; do
      (( ++index ))
      [[ -n "$chord" && "${bindings[index]-}" == *' undefined-key' ]] \
        && bindkey -M main -- "$chord" "$widget_name"
    done
    return 0
  }
fi

# --- Opt-in Git identity guard -------------------------------------------------
# With ZDX_GIT_IDENTITY_GUARD=1 (default off), an interactive shell checks each
# Git repository below $WS_BASE_DIR/<platform>/<identity> once per session, the
# first time a directory change enters it, and prints the warning of
# `git-identity-check --quiet` when its identity differs from the workspace
# profile. Outside that layout the hook does only parameter work. It never
# prompts, ignores the check's status, and returns 0, so a cd cannot fail.
if [[ "${ZDX_GIT_IDENTITY_GUARD:-0}" == "1" ]] && [[ -o interactive ]]; then
  typeset -gA _ZDX_GIT_IDENTITY_GUARD_SEEN=()

  _zdx_git_identity_guard() {
    emulate -L zsh
    [[ "${ZDX_GIT_IDENTITY_GUARD:-0}" == "1" ]] && (( ZSH_SUBSHELL == 0 )) ||
      return 0
    local base_dir="${WS_BASE_DIR-${HOME:A}/workspaces}"
    [[ "$base_dir" == /* ]] || return 0
    base_dir="${base_dir:A}"
    local current_dir="${PWD:A}"
    [[ "$base_dir" != / && "$current_dir" == "$base_dir"/*/*/?* ]] || return 0

    # The repository root is the nearest directory with a .git entry strictly
    # below the <platform>/<identity> directory.
    local relative_dir="${current_dir#$base_dir/}"
    local identity_dir="$base_dir/${relative_dir%%/*}"
    relative_dir="${relative_dir#*/}"
    identity_dir+="/${relative_dir%%/*}"
    local repository_root="$current_dir"
    while [[ "$repository_root" == "$identity_dir"/?* \
      && ! -e "$repository_root/.git" ]]; do
      repository_root="${repository_root:h}"
    done
    [[ "$repository_root" == "$identity_dir"/?* ]] || return 0
    (( ! ${+_ZDX_GIT_IDENTITY_GUARD_SEEN[$repository_root]} )) || return 0
    _ZDX_GIT_IDENTITY_GUARD_SEEN[$repository_root]=1

    # A lazy shell defines only the git-menu stub; its help loads the suite
    # without probes, and the discarded usage text is the only output.
    (( ${+functions[git-identity-check]} )) || git-menu --help >/dev/null 2>&1
    (( ${+functions[git-identity-check]} )) || return 0
    git-identity-check --quiet </dev/null || true
    return 0
  }

  autoload -Uz add-zsh-hook
  add-zsh-hook chpwd _zdx_git_identity_guard
fi

unset _zdx_plugin_dir _zdx_plugin_source_rc _zdx_completion_dir
typeset -g _ZDX_PLUGIN_SOURCED=1
