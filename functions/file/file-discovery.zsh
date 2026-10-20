#!/usr/bin/env zsh
# =============================================================================
# File Discovery: bounded large-file inspection and junk-file cleanup
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

_file_large_inventory() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
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
      _file_delete_execute no no "${selected_files[@]}"
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
    _file_delete_execute "$dry_run" "$auto_yes" "${matches[@]}"
  else
    print -rl -- "${matches[@]}"
  fi
}

_file_clean_junk_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- "  file-clean-junk [--dry-run] [--yes]"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Deletes these regular files below the current directory after review:"
  print -u2 -r -- \
    "  *:Zone.Identifier, .DS_Store, ._* (AppleDouble), Thumbs.db, desktop.ini"
  print -u2 -r -- \
    "Links and directories are never deleted, and .git, node_modules, .venv,"
  print -u2 -r -- \
    "vendored, and installed-package trees are not searched. Files that are"
  print -u2 -r -- \
    "not yours, are writable by others, or are hard-linked are skipped."
  print -u2 -r -- ""
  print -u2 -r -- "  --dry-run    Show the exact deletion plan without deleting."
  print -u2 -r -- "  --yes        Confirm the reviewed plan non-interactively."
}

# Sets reply to the junk files below the current directory as bytewise-sorted
# relative paths. Nested repositories and linked worktrees are searched like
# any other directory; their .git directories are pruned by the inventory.
# Prints only warnings.
_file_junk_inventory() {
  emulate -L zsh
  reply=()
  _file_collect_paths junk "." || return $?
  local -a records=("${reply[@]}") junk_files=()
  reply=()

  local record=""
  for record in "${records[@]}"; do
    if [[ "$record" == */ ]]; then
      _file_warn "Skipped a directory that cannot be read: ${record%/}"
      continue
    fi
    # The deletion plan uses '|' as its record delimiter.
    if [[ "$record" == *'|'* ]]; then
      _file_warn "Skipped a junk file whose name contains '|': $record"
      continue
    fi
    junk_files+=("$record")
  done

  # A bytewise sort keeps each directory's files together in the plan.
  () {
    local LC_ALL=C
    reply=("${(@o)junk_files}")
  }
  return 0
}

# Splits junk candidates by the File per-target mutation boundary.
# Usage: _file_junk_screen_targets BASE SKIPPED_ARRAY_NAME CANDIDATE...
# Sets reply to the candidates that pass it and the named array to
# "<path><TAB><reason>" records for the files it skips: gone or no longer a
# regular file, owned by another user, writable by group or others, or
# hard-linked. A directory above any candidate that is unsafe or changed
# refuses the whole run with status 1, as an unsafe base does. Prints only
# that refusal.
_file_junk_screen_targets() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local base_dir="$1" skipped_name="$2"
  shift 2
  local -a passed_targets=() skipped_records=()
  local candidate="" absolute="" reason=""
  local -A state=()
  for candidate in "$@"; do
    absolute="${base_dir}/${candidate}"
    _file_validate_ancestor_chain "$absolute" || {
      _file_error "Refusing the plan: a directory above $candidate is unsafe or changed."
      return 1
    }
    state=()
    reason=""
    if ! zstat -LH state -- "$absolute" 2>/dev/null; then
      reason="no longer exists"
    elif (( (state[mode] & 8#170000) != 8#100000 )); then
      reason="no longer a regular file"
    elif (( state[uid] != EUID )); then
      reason="owned by another user"
    elif (( (state[mode] & 8#22) != 0 )); then
      reason="writable by group or others"
    elif (( state[nlink] != 1 )); then
      reason="hard-linked"
    fi
    if [[ -n "$reason" ]]; then
      skipped_records+=("${candidate}"$'\t'"${reason}")
    else
      passed_targets+=("$candidate")
    fi
  done
  reply=("${passed_targets[@]}")
  set -A "$skipped_name" "${skipped_records[@]}"
  return 0
}

# Sets reply to plan disclosures for skipped junk files: one counted warning
# naming every reason, then each file and its reason when at most three were
# skipped or ZDX_VERBOSE=1 is set, otherwise a hint to list them.
# Usage: _file_junk_skip_disclosures "<path><TAB><reason>"...
_file_junk_skip_disclosures() {
  emulate -L zsh
  local -a records=("$@") reasons=(
    "owned by another user"
    "writable by group or others"
    "hard-linked"
    "no longer a regular file"
    "no longer exists"
  ) counted=()
  local record="" reason=""
  local -i count=0
  for reason in "${reasons[@]}"; do
    count=0
    for record in "${records[@]}"; do
      [[ "${record#*$'\t'}" == "$reason" ]] && (( ++count ))
    done
    (( count == 0 )) || counted+=("$count $reason")
  done
  _file_count_noun "${#records[@]}" "junk file"
  reply=(--warn "Skipped $REPLY that cannot be deleted safely: ${(j:, :)counted}.")
  if (( ${#records[@]} <= 3 )) || _file_verbose; then
    for record in "${records[@]}"; do
      reply+=(--note "${record%%$'\t'*} (${record#*$'\t'})")
    done
  else
    reply+=(--note "Set ZDX_VERBOSE=1 to list them.")
  fi
}

# file-clean-junk
#   Arguments: --dry-run | --yes | --help
#   stdout:    none. The plan, prompt, and results go to stderr.
#   Effects:   deletes *:Zone.Identifier, .DS_Store, ._*, Thumbs.db, and
#              desktop.ini regular files below the current directory through
#              the quarantined File deletion engine.
#              A file that fails the per-target boundary is skipped with a
#              counted warning instead of refusing the plan.
#   Status:    0 deleted, nothing found or deletable, dry run, or declined;
#              1 refused or failed; 2 invalid arguments or no terminal
#              without --yes; 130/143 interrupted.
file-clean-junk() {
  emulate -L zsh

  local dry_run=no auto_yes=no argument=""
  for argument in "$@"; do
    case "$argument" in
      -h|--help)
        (( $# == 1 )) || {
          _file_error "--help accepts no additional arguments."
          return 2
        }
        _file_clean_junk_usage
        return 0
        ;;
      --dry-run) dry_run=yes ;;
      --yes) auto_yes=yes ;;
      *)
        _file_error "Unknown option: $argument"
        return 2
        ;;
    esac
  done

  _file_header "Junk File Cleanup"
  _file_validate_base "$PWD" || return 1
  local base_dir="$REPLY"
  _file_junk_inventory || return $?
  local -a candidates=("${reply[@]}")
  if (( ${#candidates[@]} == 0 )); then
    _file_success "No junk files found."
    return 0
  fi

  local -a skipped_junk=()
  _file_junk_screen_targets "$base_dir" skipped_junk "${candidates[@]}" \
    || return $?
  local -a junk_files=("${reply[@]}") disclosures=()
  if (( ${#skipped_junk[@]} > 0 )); then
    _file_junk_skip_disclosures "${skipped_junk[@]}"
    disclosures=("${reply[@]}")
  fi

  if (( ${#junk_files[@]} == 0 )); then
    _file_print_disclosures "${disclosures[@]}"
    _file_info "No junk files can be deleted safely."
    return 0
  fi
  _file_delete_execute "${disclosures[@]}" \
    "$dry_run" "$auto_yes" "${junk_files[@]}"
}

typeset -g _FILE_DISCOVERY_SOURCED=1
