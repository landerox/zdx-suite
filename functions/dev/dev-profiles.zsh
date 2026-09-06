#!/usr/bin/env zsh
# =============================================================================
# Dev Profiles: save, list, delete, and run reusable task selections
# =============================================================================
#
# Loaded by dev-menu.zsh after dev-common.zsh and dev-state.zsh. The task
# picker reads the menu model that dev-menu.zsh defines, which exists by the
# time any public command here runs.
# Safe to re-source; defines functions only.
#

if [[ -n "${_DEV_PROFILES_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset -gr _DEV_PROFILE_MAX_FILES=100
typeset -gr _DEV_PROFILE_MAX_TASKS=64
typeset -gr _DEV_PROFILE_MAX_BYTES=8192

# --- Name validation --------------------------------------------------------

# A profile name becomes a filename. Restricting the character set is what
# keeps a stored profile from resolving outside its directory.
_dev_profile_validate_name() {
  # The `##` repetition operator below requires extended globbing, scoped to
  # this function so the caller's options are untouched.
  setopt LOCAL_OPTIONS EXTENDED_GLOB

  local name="$1"

  if [[ -z "$name" ]]; then
    _dev_error "A profile name is required."
    return 2
  fi
  if (( ${#name} > 64 )); then
    _dev_error "Profile names must be 64 characters or fewer."
    return 2
  fi
  if [[ "$name" != [a-zA-Z0-9]* ]]; then
    _dev_error "Profile names must start with a letter or digit: $name"
    return 2
  fi
  if [[ "$name" != ([a-zA-Z0-9_.-]##) ]]; then
    _dev_error \
      "Profile names may contain only letters, digits, '.', '_', and '-': $name"
    return 2
  fi
  return 0
}

# stdout: the validated absolute path for a profile file.
_dev_profile_path() {
  local name="$1"
  local profile_dir="$2"

  local candidate="${profile_dir}/${name}.profile"
  if ! _dev_within_root "$profile_dir" "$candidate"; then
    _dev_error "Refusing a profile path outside the profile directory."
    return 1
  fi
  print -r -- "$candidate"
}

# stdout: a stable identity for one validated, size-bounded profile.
_dev_profile_file_identity() {
  local profile_path="$1"
  local profile_dir="$2"
  local label="${3:-profile}"

  _dev_state_validate_file \
    "$profile_path" "$profile_dir" "$label" || return 1

  zmodload zsh/stat 2>/dev/null || {
    _dev_error "The zsh/stat module is required to validate profile identity."
    return 1
  }

  local -A metadata=()
  zstat -H metadata -- "$profile_path" 2>/dev/null || {
    _dev_error "Could not inspect $label: $profile_path"
    return 1
  }

  if (( metadata[size] > _DEV_PROFILE_MAX_BYTES )); then
    _dev_error \
      "$label exceeds the ${_DEV_PROFILE_MAX_BYTES}-byte safety limit: $profile_path"
    return 1
  fi

  print -r -- \
    "${metadata[device]}:${metadata[inode]}:${metadata[size]}:"\
"${metadata[mtime]}:${metadata[ctime]}:${metadata[mode]}:"\
"${metadata[nlink]}:${metadata[uid]}"
}

# stdout: device:inode for an owner-controlled profile path. Unlike
# _dev_profile_file_identity, this deliberately tolerates a temporary second
# hard link while an invocation-owned temporary file is atomically published.
_dev_profile_inode_identity() {
  local profile_path="$1"
  local label="${2:-profile}"

  if [[ "${profile_path:a}" != "${profile_path:A}" \
    || ! -f "$profile_path" || -L "$profile_path" ]]; then
    _dev_error "Refusing an unsafe $label: ${profile_path:a}"
    return 1
  fi

  zmodload zsh/stat 2>/dev/null || return 1
  local -A metadata=()
  zstat -H metadata -- "$profile_path" 2>/dev/null || return 1
  if (( metadata[uid] != EUID )); then
    _dev_error "Refusing a $label not owned by the current user: ${profile_path:a}"
    return 1
  fi

  print -r -- "${metadata[device]}:${metadata[inode]}"
}

# stdout: "absent" or the validated identity of an existing destination.
_dev_profile_destination_identity() {
  local profile_path="$1"
  local profile_dir="$2"
  local label="${3:-profile}"

  if [[ ! -e "$profile_path" && ! -L "$profile_path" ]]; then
    print -r -- "absent"
    return 0
  fi
  _dev_profile_file_identity "$profile_path" "$profile_dir" "$label"
}

# Sets `reply` to the validated task tokens read from one stable open file.
_dev_profile_read_tasks() {
  local profile_path="$1"
  local profile_dir="$2"
  local label="${3:-profile}"
  reply=()

  local expected_identity
  expected_identity=$(
    _dev_profile_file_identity "$profile_path" "$profile_dir" "$label"
  ) || return 1

  local profile_fd=""
  if ! exec {profile_fd}< "$profile_path"; then
    _dev_error "Could not open $label: $profile_path"
    return 1
  fi

  local -a tasks=()
  local task=""
  local fd_identity current_identity
  {
    zmodload zsh/stat 2>/dev/null || return 1
    local -A metadata=()
    zstat -H metadata -f "$profile_fd" 2>/dev/null || {
      _dev_error "Could not inspect the opened $label."
      return 1
    }
    fd_identity="${metadata[device]}:${metadata[inode]}:${metadata[size]}:"\
"${metadata[mtime]}:${metadata[ctime]}:${metadata[mode]}:"\
"${metadata[nlink]}:${metadata[uid]}"
    if [[ "$fd_identity" != "$expected_identity" ]]; then
      _dev_error "$label changed while it was opened; refusing to read it."
      return 1
    fi

    while IFS= read -r task <&$profile_fd || [[ -n "$task" ]]; do
      if (( ${#tasks[@]} >= _DEV_PROFILE_MAX_TASKS )); then
        _dev_error \
          "$label exceeds the ${_DEV_PROFILE_MAX_TASKS}-task safety limit."
        return 1
      fi
      if [[ -z "$task" ]] || ! _dev_command_batch_safe "$task"; then
        _dev_error \
          "$label contains a non-batch-eligible task: $(_dev_display_escape "$task")"
        return 1
      fi
      tasks+=("$task")
      task=""
    done

    metadata=()
    zstat -H metadata -f "$profile_fd" 2>/dev/null || {
      _dev_error "Could not revalidate the opened $label."
      return 1
    }
    fd_identity="${metadata[device]}:${metadata[inode]}:${metadata[size]}:"\
"${metadata[mtime]}:${metadata[ctime]}:${metadata[mode]}:"\
"${metadata[nlink]}:${metadata[uid]}"
    current_identity=$(
      _dev_profile_file_identity "$profile_path" "$profile_dir" "$label"
    ) || return 1
    if [[ "$fd_identity" != "$expected_identity" \
      || "$current_identity" != "$expected_identity" ]]; then
      _dev_error "$label changed while it was read; refusing its contents."
      return 1
    fi

    reply=("${tasks[@]}")
  } always {
    exec {profile_fd}<&-
  }
}

# Sets `reply` to the saved profile names, sorted.
# Status: 0 names found, 3 no profile state exists, 1 invalid/unusable state.
_dev_profile_names() {
  reply=()

  local profile_dir
  profile_dir=$(_dev_state_resolve "$DEV_PROFILE_DIR" "profile") || return 1

  [[ -e "$profile_dir" || -L "$profile_dir" ]] || return 3
  profile_dir=$(
    _dev_state_existing "$DEV_PROFILE_DIR" "profile"
  ) || return 1

  # Include every matching directory entry, not only regular files: validation
  # must reject a symlink or directory instead of silently hiding it.
  local -a files=("${profile_dir}"/*.profile(Non))
  (( ${#files[@]} > 0 )) || return 3
  if (( ${#files[@]} > _DEV_PROFILE_MAX_FILES )); then
    _dev_error \
      "The profile inventory exceeds the ${_DEV_PROFILE_MAX_FILES}-file safety limit."
    return 1
  fi

  local candidate name
  for candidate in "${files[@]}"; do
    name="${${candidate:t}%.profile}"
    _dev_profile_validate_name "$name" || return 1
    _dev_profile_file_identity \
      "$candidate" "$profile_dir" "profile '$name'" >/dev/null || return 1
    reply+=("$name")
  done
  return 0
}

# --- Public commands --------------------------------------------------------

# dev-profile-save
#   Arguments: [NAME] | --help. Without NAME the name is prompted.
#   stdout:    none. Selection UI and results go to stderr.
#   Effects:   writes one owner-only profile file under $DEV_PROFILE_DIR.
#   Requires:  fzf.
#   Status:    0 on success or cancellation, 1 on failure, 2 on bad arguments.
dev-profile-save() {
  emulate -L zsh

  local name=""
  local -i name_supplied=0

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        print -u2 -r -- "Usage: dev-profile-save [NAME]"
        print -u2 -r -- \
          "  Select tasks with Tab and store them as a reusable profile."
        return 0
        ;;
      -*) _dev_error "Unknown option: $1"; return 2 ;;
      *)
        if (( name_supplied )); then
          _dev_error "dev-profile-save accepts a single profile name."
          return 2
        fi
        name="$1"
        name_supplied=1
        ;;
    esac
    shift
  done

  (( name_supplied )) && {
    _dev_profile_validate_name "$name" || return $?
  }

  _dev_header "Saving a Task Profile"
  _dev_require_command fzf || return 1

  if (( ! name_supplied )); then
    name=$(_dev_read_line "Profile name") || {
      _dev_error "A profile name is required."
      return 2
    }
  fi
  _dev_profile_validate_name "$name" || return $?

  if ! typeset -f _dev_menu_batch_rows &>/dev/null; then
    _dev_error "The dev menu model is unavailable; cannot list selectable tasks."
    return 1
  fi

  local rows_output
  rows_output=$(_dev_menu_batch_rows) || return $?

  # Section sentinels are navigation aids, not tasks.
  local -a selectable=()
  local row command_field
  for row in "${(@f)rows_output}"; do
    [[ -n "$row" ]] || continue
    command_field="${${row#*|}%%|*}"
    [[ "$command_field" == ":" ]] && continue
    selectable+=("$row")
  done

  if (( ${#selectable[@]} == 0 )); then
    _dev_error "No selectable tasks are available."
    return 1
  fi

  local selected=""
  local -i fzf_status=0
  _dev_fzf_capture \
    --multi \
    --marker='✓' \
    --prompt="dev profile ${name} > " \
    --bind='ctrl-/:toggle-preview' \
    --header=$'Type to filter | Enter save | Esc cancel | Ctrl-/ details\nTab mark' \
    < <(printf "%s\n" "${selectable[@]}") || fzf_status=$?
  selected="$REPLY"

  if (( fzf_status != 0 )); then
    (( fzf_status == 1 || fzf_status == 130 )) && {
      _dev_info "Cancelled. No profile was created."
      return 0
    }
    _dev_error "Task selection failed."
    return 1
  fi

  [[ -n "$selected" ]] || {
    _dev_info "Cancelled. No profile was created."
    return 0
  }

  local -a tasks=()
  local snapshot_row=""
  local -i row_in_snapshot=0
  for row in "${(@f)selected}"; do
    [[ -n "$row" ]] || continue
    command_field="${${row#*|}%%|*}"
    [[ -n "$command_field" && "$command_field" != ":" ]] || continue
    if ! _dev_command_batch_safe "$command_field"; then
      _dev_warn \
        "Skipping non-batch-eligible task returned by the selector: $command_field"
      continue
    fi
    # A stored token must come from a row this invocation actually rendered,
    # not merely carry a batch-eligible command name.
    row_in_snapshot=0
    for snapshot_row in "${selectable[@]}"; do
      if [[ "$snapshot_row" == "$row" ]]; then
        row_in_snapshot=1
        break
      fi
    done
    (( row_in_snapshot )) || {
      _dev_warn \
        "Skipping a selection outside the task snapshot: $command_field"
      continue
    }
    tasks+=("$command_field")
  done

  if (( ${#tasks[@]} == 0 )); then
    _dev_info "No runnable tasks were selected. No profile was created."
    return 0
  fi
  if (( ${#tasks[@]} > _DEV_PROFILE_MAX_TASKS )); then
    _dev_error \
      "A profile may contain at most ${_DEV_PROFILE_MAX_TASKS} tasks."
    return 1
  fi

  local profile_dir directory_identity
  profile_dir=$(_dev_profile_dir_path) || return 1
  directory_identity=$(
    _dev_state_directory_identity "$profile_dir" "profile"
  ) || return 1

  local profile_path
  profile_path=$(_dev_profile_path "$name" "$profile_dir") || return 1

  local destination_identity
  destination_identity=$(
    _dev_profile_destination_identity \
      "$profile_path" "$profile_dir" "profile '$name'"
  ) || return 1

  if [[ "$destination_identity" != "absent" ]]; then
    local overwrite_outcome
    overwrite_outcome=$(_dev_confirm_outcome \
      "Overwrite the existing profile '$name'?")
    case "$overwrite_outcome" in
      confirmed) ;;
      unavailable)
        _dev_error \
          "Profile '$name' already exists and it cannot be confirmed without a terminal."
        return 1
        ;;
      *)
        _dev_info "Cancelled. The existing profile was kept."
        return 0
        ;;
    esac
  fi

  _dev_state_assert_directory_identity \
    "$profile_dir" "profile" "$directory_identity" || return 1
  local current_destination_identity
  current_destination_identity=$(
    _dev_profile_destination_identity \
      "$profile_path" "$profile_dir" "profile '$name'"
  ) || return 1
  if [[ "$current_destination_identity" != "$destination_identity" ]]; then
    _dev_error \
      "Profile '$name' changed during confirmation; refusing to overwrite it."
    return 1
  fi

  local temp_path=""
  temp_path=$(
    umask 077
    command mktemp "${profile_dir}/.${name}.profile.XXXXXX" 2>/dev/null
  ) || {
    _dev_error "Could not create a temporary profile."
    return 1
  }

  local temp_inode=""
  {
    temp_inode=$(
      _dev_profile_inode_identity "$temp_path" "temporary profile"
    ) || return 1
    command chmod 600 -- "$temp_path" 2>/dev/null || {
      _dev_error "Could not make the temporary profile owner-only."
      return 1
    }
    print -rl -- "${tasks[@]}" > "$temp_path" || {
      _dev_error "Could not write the temporary profile."
      return 1
    }
    _dev_profile_file_identity \
      "$temp_path" "$profile_dir" "temporary profile" >/dev/null || return 1

    _dev_state_assert_directory_identity \
      "$profile_dir" "profile" "$directory_identity" || return 1
    current_destination_identity=$(
      _dev_profile_destination_identity \
        "$profile_path" "$profile_dir" "profile '$name'"
    ) || return 1
    if [[ "$current_destination_identity" != "$destination_identity" ]]; then
      _dev_error \
        "Profile '$name' changed before publication; refusing to overwrite it."
      return 1
    fi

    if [[ "$destination_identity" == "absent" ]]; then
      if ! command ln -- "$temp_path" "$profile_path" 2>/dev/null; then
        _dev_error \
          "Profile '$name' appeared concurrently; refusing to overwrite it."
        return 1
      fi

      local published_inode
      published_inode=$(
        _dev_profile_inode_identity "$profile_path" "published profile"
      ) || return 1
      if [[ "$published_inode" != "$temp_inode" ]]; then
        _dev_error "The published profile identity is not the invocation-owned file."
        return 1
      fi

      if ! command rm -- "$temp_path" 2>/dev/null; then
        published_inode=$(
          _dev_profile_inode_identity "$profile_path" "published profile"
        ) || published_inode=""
        [[ "$published_inode" == "$temp_inode" ]] \
          && command rm -- "$profile_path" 2>/dev/null
        _dev_error "Could not finalize the atomically published profile."
        return 1
      fi
      temp_path=""
    else
      command mv -f -- "$temp_path" "$profile_path" 2>/dev/null || {
        _dev_error "Could not atomically replace profile '$name'."
        return 1
      }
      temp_path=""
    fi

    _dev_state_assert_directory_identity \
      "$profile_dir" "profile" "$directory_identity" || return 1
    _dev_profile_file_identity \
      "$profile_path" "$profile_dir" "profile '$name'" >/dev/null || return 1
    _dev_success "Profile '$name' saved with ${#tasks[@]} task(s)."
  } always {
    if [[ -n "$temp_path" && ( -e "$temp_path" || -L "$temp_path" ) ]]; then
      local cleanup_inode=""
      cleanup_inode=$(
        _dev_profile_inode_identity "$temp_path" "temporary profile"
      ) 2>/dev/null || cleanup_inode=""
      [[ "$cleanup_inode" == "$temp_inode" ]] \
        && command rm -- "$temp_path" 2>/dev/null
    fi
  }
}

# dev-profile-list
#   Arguments: --help only.
#   stdout:    none. The listing is UI and goes to stderr.
#   Effects:   read-only.
#   Status:    0 always, including when no profile exists.
dev-profile-list() {
  emulate -L zsh

  local REPLY
  _dev_parse_no_arguments dev-profile-list "$@" || return $?
  if [[ "$REPLY" == "help" ]]; then
    print -u2 -r -- "Usage: dev-profile-list"
    print -u2 -r -- "  Show saved profiles and the tasks they run."
    return 0
  fi

  _dev_header "Saved Task Profiles"

  local -a reply=()
  local -i names_status=0
  _dev_profile_names || names_status=$?
  case "$names_status" in
    0) ;;
    3)
      _dev_info "No profiles saved yet. Create one with: dev-profile-save <name>"
      return 0
      ;;
    *) return 1 ;;
  esac
  local -a names=("${reply[@]}")

  local profile_dir
  profile_dir=$(_dev_state_existing "$DEV_PROFILE_DIR" "profile") || return 1

  local name profile_path
  local -a tasks=()
  for name in "${names[@]}"; do
    profile_path=$(_dev_profile_path "$name" "$profile_dir") || return 1
    reply=()
    _dev_profile_read_tasks \
      "$profile_path" "$profile_dir" "profile '$name'" || return 1
    tasks=("${reply[@]}")
    _dev_label "$name" \
      "$(_dev_display_escape "${#tasks[@]} task(s): ${(j:, :)tasks}")"
  done
  return 0
}

# dev-profile-delete
#   Arguments: [NAME] | --yes | --help. Without NAME a picker is shown.
#   Effects:   removes one profile file after confirmation.
#   Status:    0 on success or cancellation, 1 when the profile is missing.
dev-profile-delete() {
  emulate -L zsh

  local name=""
  local -i auto_yes=0
  local -i name_supplied=0

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        print -u2 -r -- "Usage: dev-profile-delete [NAME] [--yes]"
        print -u2 -r -- "  Remove a saved profile after confirmation."
        return 0
        ;;
      --yes|-y) auto_yes=1 ;;
      -*) _dev_error "Unknown option: $1"; return 2 ;;
      *)
        if (( name_supplied )); then
          _dev_error "dev-profile-delete accepts a single profile name."
          return 2
        fi
        name="$1"
        name_supplied=1
        ;;
    esac
    shift
  done

  # An explicitly supplied name is validated before anything else so an unsafe
  # value is rejected as an invalid argument rather than reported as a no-op.
  (( name_supplied )) \
    && { _dev_profile_validate_name "$name" || return $?; }

  _dev_header "Deleting a Task Profile"

  local -a reply=()
  local -i names_status=0
  _dev_profile_names || names_status=$?
  case "$names_status" in
    0) ;;
    3)
      if [[ -n "$name" ]]; then
        _dev_error "Profile '$name' not found."
        return 1
      fi
      _dev_info "No profiles to delete."
      return 0
      ;;
    *) return 1 ;;
  esac
  local -a names=("${reply[@]}")

  if (( ! name_supplied )); then
    _dev_require_command fzf || return 1

    local -i fzf_status=0
    _dev_fzf_capture \
      --with-nth=1 \
      --preview='' \
      --preview-window=hidden \
      --prompt='delete profile > ' \
      --header='Up/Down navigate | Enter select | Esc cancel' \
      < <(printf "%s\n" "${names[@]}") || fzf_status=$?
    name="$REPLY"

    if (( fzf_status != 0 )); then
      if _dev_fzf_rc_is_cancel "$fzf_status"; then
        _dev_info "Cancelled. Nothing was deleted."
        return 0
      fi
      _dev_error "Profile selection failed."
      return 1
    fi
    if [[ -z "$name" ]]; then
      _dev_info "Cancelled. Nothing was deleted."
      return 0
    fi
    _dev_profile_validate_name "$name" || return $?
    if (( ! ${names[(Ie)$name]} )); then
      _dev_error "The selector returned an unavailable profile: $name"
      return 1
    fi
  fi

  local profile_dir directory_identity
  profile_dir=$(_dev_state_existing "$DEV_PROFILE_DIR" "profile") || return 1
  directory_identity=$(
    _dev_state_directory_identity "$profile_dir" "profile"
  ) || return 1

  local profile_path
  profile_path=$(_dev_profile_path "$name" "$profile_dir") || return 1

  if [[ ! -e "$profile_path" && ! -L "$profile_path" ]]; then
    _dev_error "Profile '$name' not found."
    return 1
  fi
  local profile_identity
  profile_identity=$(
    _dev_profile_file_identity \
      "$profile_path" "$profile_dir" "profile '$name'"
  ) || return 1

  local -i previous_auto_yes=$_DEV_AUTO_YES
  local delete_outcome="declined"
  {
    (( auto_yes )) && _DEV_AUTO_YES=1
    delete_outcome=$(_dev_confirm_outcome "Delete profile '$name'?")
  } always {
    _DEV_AUTO_YES=$previous_auto_yes
  }

  case "$delete_outcome" in
    confirmed) ;;
    unavailable)
      _dev_error \
        "Deleting a profile needs confirmation; pass --yes in a non-interactive shell."
      return 1
      ;;
    *)
      _dev_info "Cancelled. Nothing was deleted."
      return 0
      ;;
  esac

  _dev_state_assert_directory_identity \
    "$profile_dir" "profile" "$directory_identity" || return 1
  local current_profile_identity
  current_profile_identity=$(
    _dev_profile_file_identity \
      "$profile_path" "$profile_dir" "profile '$name'"
  ) || return 1
  if [[ "$current_profile_identity" != "$profile_identity" ]]; then
    _dev_error \
      "Profile '$name' changed during confirmation; refusing to delete it."
    return 1
  fi

  command rm -- "$profile_path" || {
    _dev_error "Could not delete the profile: $profile_path"
    return 1
  }
  _dev_state_assert_directory_identity \
    "$profile_dir" "profile" "$directory_identity" || return 1
  if [[ -e "$profile_path" || -L "$profile_path" ]]; then
    _dev_error "Profile '$name' reappeared during deletion."
    return 1
  fi
  _dev_success "Profile '$name' deleted."
}

# dev-profile-run
#   Arguments: [NAME] | --help. Without NAME a picker is shown.
#   stdout:    none. Progress and the summary go to stderr.
#   Effects:   validates the whole file, then runs each batch-eligible stored task
#              through the dispatcher, in file order.
#   Status:    0 when every task succeeded or the run was cancelled, 1 when any
#              task failed, 2 on invalid arguments.
dev-profile-run() {
  emulate -L zsh

  local name=""
  local -i name_supplied=0

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        print -u2 -r -- "Usage: dev-profile-run [NAME]"
        print -u2 -r -- \
          "  Run every task stored in a profile, sequentially, in file order."
        return 0
        ;;
      -*) _dev_error "Unknown option: $1"; return 2 ;;
      *)
        if (( name_supplied )); then
          _dev_error "dev-profile-run accepts a single profile name."
          return 2
        fi
        name="$1"
        name_supplied=1
        ;;
    esac
    shift
  done

  # An explicitly supplied name is validated before anything else so an unsafe
  # value is rejected as an invalid argument rather than reported as a no-op.
  (( name_supplied )) \
    && { _dev_profile_validate_name "$name" || return $?; }

  local -a reply=()
  local -i names_status=0
  _dev_profile_names || names_status=$?
  case "$names_status" in
    0) ;;
    3)
      if [[ -n "$name" ]]; then
        _dev_error "Profile '$name' not found."
        return 1
      fi
      _dev_info "No profiles saved. Create one with: dev-profile-save <name>"
      return 0
      ;;
    *) return 1 ;;
  esac
  local -a names=("${reply[@]}")

  if (( ! name_supplied )); then
    _dev_require_command fzf || return 1

    local -i fzf_status=0
    _dev_fzf_capture \
      --with-nth=1 \
      --preview='' \
      --preview-window=hidden \
      --prompt='run profile > ' \
      --header='Up/Down navigate | Enter run | Esc cancel' \
      < <(printf "%s\n" "${names[@]}") || fzf_status=$?
    name="$REPLY"

    if (( fzf_status != 0 )); then
      if _dev_fzf_rc_is_cancel "$fzf_status"; then
        _dev_info "Cancelled. No profile was run."
        return 0
      fi
      _dev_error "Profile selection failed."
      return 1
    fi
    if [[ -z "$name" ]]; then
      _dev_info "Cancelled. No profile was run."
      return 0
    fi
    _dev_profile_validate_name "$name" || return $?
    if (( ! ${names[(Ie)$name]} )); then
      _dev_error "The selector returned an unavailable profile: $name"
      return 1
    fi
  fi

  local profile_dir
  profile_dir=$(_dev_state_existing "$DEV_PROFILE_DIR" "profile") || return 1

  local profile_path
  profile_path=$(_dev_profile_path "$name" "$profile_dir") || return 1

  if [[ ! -e "$profile_path" && ! -L "$profile_path" ]]; then
    _dev_error "Profile '$name' not found."
    return 1
  fi

  reply=()
  _dev_profile_read_tasks \
    "$profile_path" "$profile_dir" "profile '$name'" || return 1
  local -a tasks=("${reply[@]}")

  if (( ${#tasks[@]} == 0 )); then
    _dev_warn "Profile '$name' contains no tasks."
    return 0
  fi

  _dev_header "Running Profile: $name (${#tasks[@]} task(s))"
  local start_time
  start_time=$(_dev_now)

  local -i index=0 failures=0
  local task
  for task in "${tasks[@]}"; do
    index=$(( index + 1 ))
    _dev_info "[$index/${#tasks[@]}] $(_dev_display_escape "$task")"
    _dev_timed "dev:$task" _dev_dispatch "$task" || failures=$(( failures + 1 ))
  done

  local elapsed
  elapsed=$(_dev_elapsed "$start_time")

  _dev_blank
  if (( failures == 0 )); then
    _dev_success \
      "Profile '$name': all ${#tasks[@]} task(s) completed in ${elapsed}s."
    return 0
  fi

  _dev_warn \
    "Profile '$name': $failures of ${#tasks[@]} task(s) failed (${elapsed}s)."
  return 1
}

typeset -g _DEV_PROFILES_SOURCED=1
