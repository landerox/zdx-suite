#!/usr/bin/env zsh
# =============================================================================
# Hugging Face Menu: public loader and command router for Hub workflows
# =============================================================================
#
# Public loader and command router for Hugging Face Hub workflows.
# Usage: hf-menu [subcommand]
#

if [[ -n "${_HF_MENU_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset _hf_loader_dir="${${(%):-%x}:A:h}"

_hf_source_module() {
  local relative_name="$1"
  local module_path="${_hf_loader_dir}/${relative_name}"
  [[ -f "$module_path" && ! -L "$module_path" && -r "$module_path" ]] \
    || return 1
  [[ "${module_path:A}" == "$module_path" \
    && "${module_path:A:h}" == "${module_path:h}" ]] || return 1
  builtin source "$module_path"
}

typeset -i _hf_source_rc=0
typeset _hf_failed_module="hf-common.zsh"
_hf_source_module "$_hf_failed_module" || _hf_source_rc=$?
if (( _hf_source_rc == 0 )); then
  typeset _hf_module=""
  for _hf_module in \
    hf/hf-download.zsh \
    hf/hf-search.zsh \
    hf/hf-cache.zsh; do
    _hf_failed_module="$_hf_module"
    _hf_source_module "$_hf_module" || {
      _hf_source_rc=$?
      break
    }
  done
fi
if (( _hf_source_rc != 0 )); then
  print -u2 -r -- \
    "hf-menu.zsh: failed to load $_hf_failed_module (status $_hf_source_rc)"
  unset -f _hf_source_module
  unset _hf_loader_dir _hf_module _hf_failed_module
  {
    return $_hf_source_rc 2>/dev/null || exit $_hf_source_rc
  } always {
    unset _hf_source_rc
  }
fi

unset -f _hf_source_module
unset _hf_loader_dir _hf_module _hf_failed_module _hf_source_rc

_hf_usage() {
  print -u2 -r -- 'Usage:'
  print -u2 -r -- '  hf-menu'
  print -u2 -r -- '  hf-menu COMMAND [arguments]'
  print -u2 -r -- '  hf-menu -h|--help'
  print -u2 -r -- ''
  print -u2 -r -- 'Commands:'
  print -u2 -r -- '  hf-search          Search models or datasets'
  print -u2 -r -- '  hf-repo-stats      Display repository metadata'
  print -u2 -r -- '  hf-cache-inspect   Inspect the local Hub cache'
  print -u2 -r -- '  hf-cache-clear     Plan and remove one exact cache entry'
  print -u2 -r -- '  hf-download        Download a snapshot or one file'
  print -u2 -r -- ''
  print -u2 -r -- 'Backend:'
  print -u2 -r -- \
    '  Requires an already-installed huggingface_hub 0.23+ and below 2.0.'
  print -u2 -r -- \
    '  Set HF_PYTHON to select its Python interpreter.'
  print -u2 -r -- \
    '  ZDX never installs or executes a Python package implicitly.'
  print -u2 -r -- \
    '  Search and metadata probes require timeout or gtimeout.'
  print -u2 -r -- ''
  print -u2 -r -- 'Use COMMAND --help for command-specific flags.'
}

_hf_dispatch() {
  local command_name="${1:-}"
  shift 2>/dev/null || true

  case "$command_name" in
    hf-search)        hf-search "$@" ;;
    hf-repo-stats)    hf-repo-stats "$@" ;;
    hf-cache-inspect) hf-cache-inspect "$@" ;;
    hf-cache-clear)   hf-cache-clear "$@" ;;
    hf-download)      hf-download "$@" ;;
    :)                return 0 ;;
    *)
      _hf_error "Unknown command: $(_hf_display_escape "$command_name")"
      return 2
      ;;
  esac
}

_hf_interactive() {
  command -v fzf &>/dev/null || {
    _hf_error "Interactive Hugging Face menus require fzf."
    _hf_dim "Use a direct hf-* command or install fzf."
    return 1
  }

  local -a menu_rows=()
  local row=""
  row=$(_hf_menu_section \
    "Inspection" \
    "Explore Hub repositories and inspect the local download cache.") || return
  menu_rows+=("$row")
  row=$(_hf_menu_entry \
    "Search Models or Datasets" \
    "hf-search" \
    "Find Hub repositories, inspect their statistics, or choose files to download.") || return
  menu_rows+=("$row")
  row=$(_hf_menu_entry \
    "Show Repository Statistics" \
    "hf-repo-stats" \
    "Show downloads, likes, tags, access restrictions, and the current revision.") || return
  menu_rows+=("$row")
  row=$(_hf_menu_entry \
    "Inspect Local Cache" \
    "hf-cache-inspect" \
    "Show downloaded repositories and their local storage usage.") || return
  menu_rows+=("$row")
  row=$(_hf_menu_section \
    "Downloads" \
    "Download repository content into the local Hub cache.") || return
  menu_rows+=("$row")
  row=$(_hf_menu_entry \
    "Download Snapshot or File" \
    "hf-download" \
    "Download a repository snapshot or one file; restricted content requires Hub access.") || return
  menu_rows+=("$row")
  row=$(_hf_menu_section \
    "Maintenance" \
    "Review cached content before deleting it from local storage.") || return
  menu_rows+=("$row")
  row=$(_hf_menu_entry \
    "Delete Cached Repository" \
    "hf-cache-clear" \
    "Review and delete one local cached repository; the Hub repository stays unchanged.") \
    || return
  menu_rows+=("$row")

  local -i fzf_rc=0
  _hf_fzf_capture \
    --delimiter='[|]' \
    --with-nth=1 \
    --prompt='hf > ' \
    --header='Type to filter | Enter run | Esc cancel | Ctrl-/ details' \
    --preview='case {2} in :) printf "%s\n" {3} ;; *) printf "Command: %s\n\n%s\n" {2} {3} ;; esac' \
    --preview-window='down:4:wrap' \
    --bind='ctrl-/:toggle-preview' \
    < <(printf "%s\n" "${menu_rows[@]}") || fzf_rc=$?
  local selected="$REPLY"

  if (( fzf_rc != 0 )); then
    _hf_fzf_rc_is_cancel "$fzf_rc" && return 0
    _hf_error "Unable to open the Hugging Face menu (status $fzf_rc)."
    return 1
  fi
  [[ -z "$selected" ]] && return 0
  _hf_array_contains_literal "$selected" "${menu_rows[@]}" || {
    _hf_error "The selected Hugging Face action was not in the menu snapshot."
    return 1
  }

  local command_name="${${selected#*|}%%|*}"
  [[ "$command_name" == ":" ]] && return 0
  if typeset -f _timed &>/dev/null; then
    _timed "hf:$command_name" _hf_dispatch "$command_name"
  else
    _hf_dispatch "$command_name"
  fi
}

hf-menu() {
  case "${1:-}" in
    "")
      (( $# == 0 )) || return 2
      _hf_interactive
      ;;
    -h|--help)
      (( $# == 1 )) || {
        _hf_error "--help accepts no arguments."
        return 2
      }
      _hf_usage
      ;;
    -*)
      _hf_error "Unknown option: $(_hf_display_escape "$1")"
      return 2
      ;;
    *)
      local command_name="$1"
      shift
      if typeset -f _timed &>/dev/null; then
        _timed "hf:$command_name" _hf_dispatch "$command_name" "$@"
      else
        _hf_dispatch "$command_name" "$@"
      fi
      ;;
  esac
}

typeset -g _HF_MENU_SOURCED=1
