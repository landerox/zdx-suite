#!/usr/bin/env zsh
# =============================================================================
# Dev Report: Markdown report buffer used by the dev-check-* commands
# =============================================================================
#
# Loaded by dev-menu.zsh after dev-common.zsh and dev-state.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_DEV_REPORT_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# Line buffer. An array avoids embedding "\n" escapes in a single string, which
# previously required the non-portable `echo -e` to render.
typeset -ga _DEV_REPORT_LINES=()
typeset -g _DEV_REPORT_ACTIVE=0

_dev_report_reset() {
  _DEV_REPORT_LINES=()
  _DEV_REPORT_ACTIVE=0
}

_dev_report_init() {
  local title="${1:-Report}"
  _DEV_REPORT_LINES=()
  _DEV_REPORT_ACTIVE=1

  local generated project
  generated=$(command date '+%Y-%m-%d %H:%M:%S' 2>/dev/null) \
    || generated="unavailable"
  if [[ ${#generated} -ne 19 \
    || "${generated[5]}" != "-" || "${generated[8]}" != "-" \
    || "${generated[11]}" != " " \
    || "${generated[14]}" != ":" || "${generated[17]}" != ":" \
    || "${generated//[-: ]/}" != <-> ]]; then
    generated="unavailable"
  fi
  project=$(_dev_display_escape "${PWD:t}")
  title=$(_dev_display_escape "$title")

  _DEV_REPORT_LINES+=("# ${title}")
  _DEV_REPORT_LINES+=("")
  _DEV_REPORT_LINES+=("Generated:")
  _DEV_REPORT_LINES+=("    ${generated}")
  _DEV_REPORT_LINES+=("Project:")
  _DEV_REPORT_LINES+=("    ${project}")
  _DEV_REPORT_LINES+=("")
}

_dev_report_section() {
  (( _DEV_REPORT_ACTIVE )) || return 0
  _DEV_REPORT_LINES+=("## ${1}")
  _DEV_REPORT_LINES+=("")
}

_dev_report_line() {
  (( _DEV_REPORT_ACTIVE )) || return 0
  _DEV_REPORT_LINES+=("${1}")
}

_dev_report_status() {
  (( _DEV_REPORT_ACTIVE )) || return 0
  local kind="$1"
  local text="$2"
  text=$(_dev_display_escape "$text")

  case "$kind" in
    ok)   _DEV_REPORT_LINES+=("- OK — ${text}") ;;
    warn) _DEV_REPORT_LINES+=("- WARN — ${text}") ;;
    fail) _DEV_REPORT_LINES+=("- FAIL — ${text}") ;;
    info) _DEV_REPORT_LINES+=("- INFO — ${text}") ;;
    *)
      _dev_error "Unknown report status kind: $kind"
      return 2
      ;;
  esac
}

# Writes the buffer to DEV_REPORT_DIR and clears it. The buffer is cleared on
# every exit path so a failed save cannot leak into the next report.
_dev_report_save() {
  emulate -L zsh

  local filename="${1:-report.md}"

  (( _DEV_REPORT_ACTIVE )) || return 0

  if [[ ! "$filename" =~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}\.md$' \
    || "$filename" == *..* ]]; then
    _dev_error "Invalid report filename: $filename"
    _dev_report_reset
    return 1
  fi

  local report_dir directory_identity
  report_dir=$(_dev_report_dir_path) || {
    _dev_report_reset
    return 1
  }
  directory_identity=$(
    _dev_state_directory_identity "$report_dir" "report"
  ) || {
    _dev_report_reset
    return 1
  }

  local timestamp
  timestamp=$(_dev_state_timestamp) || {
    _dev_error "Could not generate a report timestamp."
    _dev_report_reset
    return 1
  }

  local temp_file=""
  temp_file=$(command mktemp "${report_dir}/.report.XXXXXX" 2>/dev/null) || {
    _dev_error "Could not create a temporary report file."
    _dev_report_reset
    return 1
  }

  local temp_identity=""
  local -i temp_validated=0
  {
    temp_identity=$(
      _dev_temporary_file_identity \
        "$temp_file" "$report_dir" "new report temporary"
    ) || return 1
    temp_validated=1
    _dev_state_assert_directory_identity \
      "$report_dir" "report" "$directory_identity" || return 1
    command chmod 600 -- "$temp_file" 2>/dev/null || {
      _dev_error "Could not make the report owner-only."
      return 1
    }
    print -rl -- "${_DEV_REPORT_LINES[@]}" > "$temp_file" || {
      _dev_error "Could not write the temporary report."
      return 1
    }
    _dev_state_validate_file \
      "$temp_file" "$report_dir" "temporary report" || return 1
    local current_temp_identity
    current_temp_identity=$(
      _dev_temporary_file_identity \
        "$temp_file" "$report_dir" "temporary report"
    ) || return 1
    if [[ "$current_temp_identity" != "$temp_identity" ]]; then
      _dev_error "The temporary report changed while it was being written."
      return 1
    fi
    _dev_state_assert_directory_identity \
      "$report_dir" "report" "$directory_identity" || return 1

    local filepath=""
    local -i suffix=0 published=0
    while (( suffix < 1000 )); do
      if (( suffix == 0 )); then
        filepath="${report_dir}/${timestamp}_${filename}"
      else
        filepath="${report_dir}/${timestamp}.${suffix}_${filename}"
      fi

      if command ln -- "$temp_file" "$filepath" 2>/dev/null; then
        command rm -f -- "$temp_file" || {
          _dev_error "Could not finalize the report publication."
          return 1
        }
        temp_file=""
        published=1
        break
      fi
      suffix=$(( suffix + 1 ))
    done

    if (( ! published )); then
      _dev_error "Could not allocate a unique report filename."
      return 1
    fi

    _dev_state_assert_directory_identity \
      "$report_dir" "report" "$directory_identity" || return 1
    _dev_state_validate_file \
      "$filepath" "$report_dir" "published report" || return 1
    _dev_success "Report saved: $filepath"
  } always {
    if (( temp_validated )) \
      && [[ -n "$temp_file" && -e "$temp_file" ]]; then
      local cleanup_identity=""
      cleanup_identity=$(
        _dev_temporary_file_identity \
          "$temp_file" "$report_dir" "report temporary cleanup"
      ) 2>/dev/null
      if [[ -n "$cleanup_identity" \
        && "$cleanup_identity" == "$temp_identity" ]]; then
        command rm -f -- "$temp_file" 2>/dev/null
      else
        _dev_warn \
          "The report temporary changed; refusing automatic cleanup: $temp_file"
      fi
    fi
    _dev_report_reset
  }
}

typeset -g _DEV_REPORT_SOURCED=1
