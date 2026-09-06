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
if ! zmodload zsh/stat 2>/dev/null \
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
fi

unset _zdx_plugin_dir _zdx_plugin_source_rc _zdx_completion_dir
typeset -g _ZDX_PLUGIN_SOURCED=1
