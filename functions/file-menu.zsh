#!/usr/bin/env zsh
# =============================================================================
# File Suite: public loader and command router
# =============================================================================
#
# Public loader and command router for local file workflows.
# Usage: file-menu [subcommand]
#

if [[ -n "${_FILE_MENU_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset _file_menu_loader_dir="${${(%):-%x}:A:h}"

_file_menu_source_module() {
  local module_name="$1"
  local module_file="${_file_menu_loader_dir}/file/${module_name}"
  [[ "$module_name" == "file-common.zsh" ]] \
    && module_file="${_file_menu_loader_dir}/file-common.zsh"

  local resolved_file="${module_file:A}"
  [[ ! -L "$module_file" \
    && -f "$module_file" \
    && -r "$module_file" \
    && "$resolved_file" == "$module_file" ]] || return 1

  builtin source "$module_file"
}

typeset -i _file_menu_load_rc=0
_file_menu_source_module "file-common.zsh" || _file_menu_load_rc=$?
if (( _file_menu_load_rc != 0 )); then
  print -u2 -r -- "file-menu.zsh: failed to load file-common.zsh"
  {
    return $_file_menu_load_rc 2>/dev/null || exit $_file_menu_load_rc
  } always {
    unset -f _file_menu_source_module
    unset _file_menu_load_rc _file_menu_loader_dir
  }
fi

typeset _file_menu_module
for _file_menu_module in \
  file-archive.zsh \
  file-operations.zsh \
  file-discovery.zsh \
  file-data.zsh; do
  _file_menu_load_rc=0
  _file_menu_source_module "$_file_menu_module" || _file_menu_load_rc=$?
  if (( _file_menu_load_rc != 0 )); then
    print -u2 -r -- \
      "file-menu.zsh: failed to load ${_file_menu_module}"
    {
      return $_file_menu_load_rc 2>/dev/null || exit $_file_menu_load_rc
    } always {
      unset -f _file_menu_source_module
      unset _file_menu_load_rc _file_menu_loader_dir _file_menu_module
    }
  fi
done

unset -f _file_menu_source_module
unset _file_menu_load_rc _file_menu_loader_dir _file_menu_module

_file_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- "  file-menu"
  print -u2 -r -- "  file-menu <subcommand> [arguments...]"
  print -u2 -r -- "  file-menu --help"
  print -u2 -r -- ""
  print -u2 -r -- "Archive management:"
  print -u2 -r -- \
    "  file-compress, file-extract"
  print -u2 -r -- ""
  print -u2 -r -- "File management:"
  print -u2 -r -- \
    "  file-bulk-ops, file-permissions, file-find-large, file-find, file-diff"
  print -u2 -r -- ""
  print -u2 -r -- "Data conversion:"
  print -u2 -r -- \
    "  file-encode-decode, file-checksum, file-line-endings"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Arguments after a subcommand are forwarded unchanged to that command."
  print -u2 -r -- \
    "Use '<subcommand> --help' for command-specific syntax and safety flags."
  print -u2 -r -- \
    "Broad and destructive mutations support --dry-run and --yes."
}

# stdout records: label|command|description
_file_menu_rows() {
  local -a rows=()
  local row=""

  row=$(_file_menu_section \
    "Inspection" "Find and compare files in the current directory.") \
    || return $?
  rows+=("$row")
  row=$(_file_menu_entry \
    "Search Files" "file-find" \
    "Find files by name, extension, text, or modification date.") \
    || return $?
  rows+=("$row")
  row=$(_file_menu_entry \
    "Compare Files or Directories" "file-diff" \
    "Review differences between two local files or directories.") \
    || return $?
  rows+=("$row")
  row=$(_file_menu_entry \
    "Inspect Large Files" "file-find-large" \
    "Find files above a chosen size and optionally review their deletion.") \
    || return $?
  rows+=("$row")
  row=$(_file_menu_entry \
    "Check File Integrity" "file-checksum" \
    "Generate SHA-256 or MD5 checksums, or verify a file against a known digest.") \
    || return $?
  rows+=("$row")

  row=$(_file_menu_section \
    "Archives" "Package local files or unpack supported TAR archives.") \
    || return $?
  rows+=("$row")
  row=$(_file_menu_entry \
    "Compress Files" "file-compress" \
    "Create a TAR, ZIP, or 7z archive from selected local paths.") \
    || return $?
  rows+=("$row")
  row=$(_file_menu_entry \
    "Extract TAR Archive" "file-extract" \
    "Check and unpack a TAR archive into a new directory.") \
    || return $?
  rows+=("$row")

  row=$(_file_menu_section \
    "Data Conversion" "Encode data or change text-file line endings.") \
    || return $?
  rows+=("$row")
  row=$(_file_menu_entry \
    "Convert Base64 Data" "file-encode-decode" \
    "Encode or decode Base64 text, or write the result to a file.") \
    || return $?
  rows+=("$row")
  row=$(_file_menu_entry \
    "Convert Line Endings" "file-line-endings" \
    "Review and convert selected text files to Unix LF or Windows CRLF.") \
    || return $?
  rows+=("$row")

  row=$(_file_menu_section \
    "File Changes" "Review path and permission changes before applying them.") \
    || return $?
  rows+=("$row")
  row=$(_file_menu_entry \
    "Change Permissions" "file-permissions" \
    "Review and change access permissions for selected local paths.") \
    || return $?
  rows+=("$row")
  row=$(_file_menu_entry \
    "Run Bulk File Operations" "file-bulk-ops" \
    "Review a copy, move, rename, duplicate, or delete operation on selected paths.") \
    || return $?
  rows+=("$row")

  print -rl -- "${rows[@]}"
}

_file_menu_interactive() {
  _file_require_cmd fzf "the interactive File menu" || return 1

  local rows_output=""
  rows_output=$(_file_menu_rows) || return $?
  local -a rows=("${(@f)rows_output}")
  (( ${#rows[@]} <= _FILE_MAX_MENU_ROWS )) || {
    _file_error "The File menu exceeds its row limit."
    return 1
  }

  local selected=""
  local directory_label="${${PWD:A}:t}"
  directory_label="${(V)directory_label}"
  local -i fzf_rc=0
  _file_fzf_capture \
    --height='80%' \
    --delimiter='[|]' \
    --with-nth=1 \
    --prompt='file > ' \
    --header="Directory: ${directory_label}"$'\n'\
'Type to filter | Enter run | Esc cancel | Ctrl-/ details' \
    --bind='ctrl-/:toggle-preview' \
    --preview='case {2} in :) printf "%s\n" {3} ;; *) printf "Command: %s\n\n%s\n" {2} {3} ;; esac' \
    --preview-window='down:4:wrap' \
    < <(print -rl -- "${rows[@]}") || fzf_rc=$?
  selected="$REPLY"

  if (( fzf_rc != 0 )); then
    _file_fzf_rc_is_cancel "$fzf_rc" && return 0
    _file_error "Unable to open the interactive File menu (status $fzf_rc)."
    return 1
  fi
  [[ -n "$selected" ]] || return 0
  [[ "$selected" != *$'\n'* && "$selected" != *$'\r'* ]] || {
    _file_error "Refusing malformed File menu output."
    return 1
  }
  _file_array_contains_literal "$selected" "${rows[@]}" || {
    _file_error "The selected File action was not in the menu snapshot."
    return 1
  }

  local command_name="${${selected#*|}%%|*}"
  [[ "$command_name" == ":" ]] && return 0
  _file_timed "file:$command_name" _file_dispatch "$command_name"
}

file-menu() {
  emulate -L zsh

  case "${1:-}" in
    "")
      (( $# == 0 )) || return 2
      _file_menu_interactive
      ;;
    -h|--help)
      (( $# == 1 )) || {
        _file_error "--help accepts no additional arguments."
        return 2
      }
      _file_usage
      ;;
    -*)
      _file_error "Unknown option: $1"
      return 2
      ;;
    *)
      local command_name="$1"
      shift
      _file_timed "file:$command_name" \
        _file_dispatch "$command_name" "$@"
      ;;
  esac
}

typeset -g _FILE_MENU_SOURCED=1
