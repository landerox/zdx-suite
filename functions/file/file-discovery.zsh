#!/usr/bin/env zsh
# =============================================================================
# File Discovery: bounded search, large-file inspection, and diff
# =============================================================================
#
# Loaded by file-menu.zsh after file-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_FILE_DISCOVERY_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_file_find_large_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- \
    "  file-find-large --min-size SIZE [--delete] [--dry-run] [--yes]"
  print -u2 -r -- "  file-find-large"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Without --delete, matching paths are written to stdout."
}

_file_find_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- "  file-find --name GLOB"
  print -u2 -r -- "  file-find --extension EXTENSION"
  print -u2 -r -- "  file-find --content TEXT"
  print -u2 -r -- "  file-find --days NUMBER"
  print -u2 -r -- "  file-find"
  print -u2 -r -- ""
  print -u2 -r -- "Matching paths are written one per line to stdout."
  print -u2 -r -- \
    "Paths containing control characters are excluded from interactive output."
}

_file_diff_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- "  file-diff -- LEFT RIGHT"
  print -u2 -r -- "  file-diff LEFT RIGHT"
  print -u2 -r -- "  file-diff"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Diff output is written to stdout; status 1 means differences were found."
}

_file_size_to_bytes() {
  local value="${1:u}"
  [[ ${#value} -le 16 && "$value" =~ '^[0-9]+[KMGT]?$' ]] || {
    _file_error "Invalid size: $1"
    return 2
  }
  local number="${value%%[KMGT]}"
  local suffix="${value#$number}"
  local -i multiplier=1 maximum_number=1125899906842624
  case "$suffix" in
    K)
      multiplier=1024
      maximum_number=1099511627776
      ;;
    M)
      multiplier=$(( 1024 * 1024 ))
      maximum_number=1073741824
      ;;
    G)
      multiplier=$(( 1024 * 1024 * 1024 ))
      maximum_number=1048576
      ;;
    T)
      multiplier=$(( 1024 * 1024 * 1024 * 1024 ))
      maximum_number=1024
      ;;
  esac
  local -i numeric_value=$(( 10#$number ))
  (( numeric_value >= 1 && numeric_value <= maximum_number )) || {
    _file_error "Requested size is outside the supported range."
    return 2
  }
  REPLY="$(( numeric_value * multiplier ))"
}

_file_validate_days() {
  local value="${1:-}"
  [[ "$value" == <-> && ${#value} -le 5 ]] || return 1
  local -i numeric_value=$(( 10#$value ))
  (( numeric_value >= 0 && numeric_value <= 36500 ))
}

_file_large_inventory() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local minimum_bytes="$1"
  reply=()
  _file_collect_paths files "." || return $?
  local -a candidates=("${reply[@]}")
  reply=()
  local candidate=""
  local -A state=()
  for candidate in "${candidates[@]}"; do
    state=()
    zstat -LH state -- "$candidate" 2>/dev/null || {
      _file_warn "Skipped a file that changed during inspection: $candidate"
      continue
    }
    (( state[size] >= minimum_bytes )) && reply+=("$candidate")
  done
  return 0
}

file-find-large() {
  emulate -L zsh
  _file_header "Workspace Size Inspector"

  if (( $# == 0 )); then
    _file_read_line "Minimum file size" "10M" || return $?
    _file_size_to_bytes "$REPLY" || return $?
    _file_large_inventory "$REPLY" || return $?
    local -a candidates=("${reply[@]}")
    (( ${#candidates[@]} > 0 )) || {
      _file_success "No files meet the requested size."
      return 0
    }
    _file_select_from_snapshot "Select large files" yes candidates
    local -i select_rc=$?
    if (( select_rc != 0 )); then
      (( select_rc == 130 )) && return 0
      return $select_rc
    fi
    local -a selected_files=("${reply[@]}")
    _file_choose_fixed "Large-file action" "show" "delete"
    local -i action_rc=$?
    if (( action_rc != 0 )); then
      (( action_rc == 130 )) && return 0
      return $action_rc
    fi
    if [[ "$REPLY" == "delete" ]]; then
      _file_bulk_execute delete "" "" "" no no "${selected_files[@]}"
    else
      print -rl -- "${selected_files[@]}"
    fi
    return $?
  fi

  local minimum="" delete_mode=no dry_run=no auto_yes=no
  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        (( $# == 1 )) || return 2
        _file_find_large_usage
        return 0
        ;;
      --min-size)
        (( $# >= 2 )) || return 2
        minimum="$2"
        shift 2
        ;;
      --delete) delete_mode=yes; shift ;;
      --dry-run) dry_run=yes; shift ;;
      --yes) auto_yes=yes; shift ;;
      *)
        _file_error "Unknown option: $1"
        return 2
        ;;
    esac
  done
  [[ -n "$minimum" ]] || {
    _file_error "--min-size is required."
    return 2
  }
  _file_size_to_bytes "$minimum" || return $?
  _file_large_inventory "$REPLY" || return $?
  local -a matches=("${reply[@]}")
  (( ${#matches[@]} > 0 )) || return 0
  if [[ "$delete_mode" == "yes" ]]; then
    _file_bulk_execute delete "" "" "" \
      "$dry_run" "$auto_yes" "${matches[@]}"
  else
    print -rl -- "${matches[@]}"
  fi
}

_file_find_inventory() {
  emulate -L zsh
  zmodload zsh/stat zsh/datetime 2>/dev/null || return 1
  local mode="$1"
  local query="$2"
  [[ -n "$query" && ${#query} -le 256 \
    && "$query" != *[[:cntrl:]]* ]] || {
    _file_error "Search values must be 1-256 control-free characters."
    return 2
  }
  reply=()
  _file_collect_paths files "." || return $?
  local -a candidates=("${reply[@]}")
  reply=()
  local candidate=""
  local base_name=""
  local -A state=()
  local -i age_limit=0
  if [[ "$mode" == "days" ]]; then
    _file_validate_days "$query" || return 2
    age_limit=$(( 10#$query * 86400 ))
  fi

  for candidate in "${candidates[@]}"; do
    base_name="${candidate:t}"
    case "$mode" in
      name)
        [[ "$base_name" == ${~query} ]] && reply+=("$candidate")
        ;;
      extension)
        [[ "${base_name:e}" == "${query#.}" ]] && reply+=("$candidate")
        ;;
      content)
        _file_require_cmd grep "content search" || return 1
        local -i grep_rc=0
        LC_ALL=C command grep -FIl -- "$query" "$candidate" \
          >/dev/null 2>&1 || grep_rc=$?
        case "$grep_rc" in
          0) reply+=("$candidate") ;;
          1) ;;
          *)
            _file_error "Content search failed while reading: $candidate"
            return 1
            ;;
        esac
        ;;
      days)
        state=()
        zstat -LH state -- "$candidate" 2>/dev/null || continue
        (( EPOCHSECONDS - state[mtime] <= age_limit )) \
          && reply+=("$candidate")
        ;;
      *)
        return 2
        ;;
    esac
  done
  return 0
}

file-find() {
  emulate -L zsh
  _file_header "File Search"

  if (( $# == 0 )); then
    _file_choose_fixed "Search mode" "name" "extension" "content" "days"
    local -i mode_rc=$?
    if (( mode_rc != 0 )); then
      (( mode_rc == 130 )) && return 0
      return $mode_rc
    fi
    local mode="$REPLY"
    _file_read_line "Search value" || return $?
    local query="$REPLY"
    [[ -n "$query" ]] || return 0
    if [[ "$mode" == "days" ]] && ! _file_validate_days "$query"; then
      _file_error "Days must be a non-negative integer."
      return 2
    fi
    _file_find_inventory "$mode" "$query" || return $?
    local -a matches=("${reply[@]}")
    (( ${#matches[@]} > 0 )) || {
      _file_warn "No results found."
      return 0
    }
    _file_select_from_snapshot "Search results" yes matches
    local -i select_rc=$?
    if (( select_rc != 0 )); then
      (( select_rc == 130 )) && return 0
      return $select_rc
    fi
    print -rl -- "${reply[@]}"
    return 0
  fi

  local mode="" query=""
  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        (( $# == 1 )) || return 2
        _file_find_usage
        return 0
        ;;
      --name|--extension|--content|--days)
        (( $# >= 2 )) || return 2
        [[ -z "$mode" ]] || {
          _file_error "Choose exactly one search mode."
          return 2
        }
        mode="${1#--}"
        query="$2"
        shift 2
        ;;
      *)
        _file_error "Unknown option: $1"
        return 2
        ;;
    esac
  done
  [[ -n "$mode" && -n "$query" ]] || {
    _file_error "Exactly one search mode and a non-empty value are required."
    return 2
  }
  if [[ "$mode" == "days" ]] && ! _file_validate_days "$query"; then
    _file_error "Days must be a non-negative integer."
    return 2
  fi
  _file_find_inventory "$mode" "$query" || return $?
  print -rl -- "${reply[@]}"
}

_file_diff_execute() {
  local left_arg="$1"
  local right_arg="$2"
  _file_require_cmd diff "file comparison" || return 1
  _file_validate_base "$PWD" || return 1
  local base_dir="$REPLY"

  _file_validate_mutation_target "$left_arg" "$base_dir" || return 1
  local left_plan="$REPLY"
  local left_absolute="${left_plan%%|*}"
  local left_identity="${left_plan#*|}"
  _file_validate_mutation_target "$right_arg" "$base_dir" || return 1
  local right_plan="$REPLY"
  local right_absolute="${right_plan%%|*}"
  local right_identity="${right_plan#*|}"

  [[ ! -d "$left_absolute" ]] \
    || _file_validate_tree_for_transfer "$left_absolute" || return 1
  [[ ! -d "$right_absolute" ]] \
    || _file_validate_tree_for_transfer "$right_absolute" || return 1

  _file_revalidate_mutation_target "$left_absolute" "$left_identity" || return 1
  _file_revalidate_mutation_target "$right_absolute" "$right_identity" || return 1
  command diff -ru -- "$left_absolute" "$right_absolute"
}

file-diff() {
  emulate -L zsh
  _file_header "File / Directory Diff"

  if (( $# == 0 )); then
    _file_select_paths "Select the left path" no all
    local -i left_rc=$?
    if (( left_rc != 0 )); then
      (( left_rc == 130 )) && return 0
      return $left_rc
    fi
    local left_arg="${reply[1]}"
    _file_select_paths "Select the right path" no all
    local -i right_rc=$?
    if (( right_rc != 0 )); then
      (( right_rc == 130 )) && return 0
      return $right_rc
    fi
    _file_diff_execute "$left_arg" "${reply[1]}"
    return $?
  fi
  [[ "${1:-}" != "-h" && "${1:-}" != "--help" ]] || {
    (( $# == 1 )) || return 2
    _file_diff_usage
    return 0
  }
  [[ "${1:-}" != -* || "${1:-}" == "--" ]] || {
    _file_error "Unknown option: $1"
    return 2
  }
  [[ "${1:-}" != "--" ]] || shift
  (( $# == 2 )) || {
    _file_error "Exactly two paths are required."
    return 2
  }
  _file_diff_execute "$1" "$2"
}

typeset -g _FILE_DISCOVERY_SOURCED=1
