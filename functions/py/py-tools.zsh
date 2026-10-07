#!/usr/bin/env zsh
# =============================================================================
# Py Tools: isolated global tool inventory and reviewed mutations
# =============================================================================
#
# Sourced by py-menu.zsh. Depends on py-common.
# Idempotent and free of source-time capability probes.
#

if [[ -n "${_PY_TOOLS_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# Data record: backend<TAB>validated-package-name. With "versions" as the
# second argument a third field holds the reported version, or is empty.
_py_tool_backend_inventory() {
  local backend="$1" with_versions="${2:-}"
  local raw_output=""
  local -a producer_args=()
  case "$backend" in
    uv)
      producer_args=(uv tool list)
      raw_output=$(_py_capture_bounded_output \
        $(( 1024 * 1024 )) "uv tool inventory" 15 \
        "${producer_args[@]}") || return $?
      ;;
    pipx)
      producer_args=(pipx list --short)
      raw_output=$(_py_capture_bounded_output \
        $(( 1024 * 1024 )) "pipx tool inventory" 15 \
        "${producer_args[@]}") || return $?
      ;;
    *) return 2 ;;
  esac

  local line="" package_name="" version=""
  local -i raw_count=0 record_count=0
  local -A seen=()
  for line in "${(@f)raw_output}"; do
    (( raw_count++ ))
    (( raw_count <= 2048 )) || {
      _py_error "$backend tool inventory exceeded 2048 records."
      return 1
    }
    if [[ "$backend" == uv && "$line" == [[:space:]]* ]]; then
      continue
    fi
    package_name="${line%%[[:space:]]*}"
    [[ "$backend" == uv ]] && package_name="${package_name%%@*}"
    _py_validate_package_name "$package_name" || continue
    [[ -z "${seen[$package_name]:-}" ]] || continue
    seen[$package_name]=1
    (( record_count++ ))
    (( record_count <= 500 )) || {
      _py_error "$backend tool inventory exceeded 500 eligible tools."
      return 1
    }
    if [[ "$with_versions" == versions ]]; then
      version=""
      if [[ "$line" == *[[:space:]]* ]]; then
        version="${line#*[[:space:]]}"
        version="${version#"${version%%[^[:space:]]*}"}"
        version="${version%%[[:space:]]*}"
      fi
      version="${version#v}"
      [[ "$version" =~ '^[0-9][0-9A-Za-z.+!_-]{0,63}$' ]] || version=""
      print -r -- "$backend"$'\t'"$package_name"$'\t'"$version"
    else
      print -r -- "$backend"$'\t'"$package_name"
    fi
  done
}

# Usage: _py_tool_inventory [backend] [versions]
_py_tool_inventory() {
  local requested_backend="${1:-}" with_versions="${2:-}"
  local backend="" backend_records="" record=""
  local -a eligible_backends=(uv pipx)
  if [[ -n "$requested_backend" ]]; then
    _py_check_command "$requested_backend" || return $?
    eligible_backends=("$requested_backend")
  fi
  local -A seen=()
  for backend in "${eligible_backends[@]}"; do
    command -v "$backend" &>/dev/null || continue
    backend_records=$(_py_tool_backend_inventory "$backend" "$with_versions") \
      || return $?
    for record in "${(@f)backend_records}"; do
      [[ -n "$record" && -z "${seen[$record]:-}" ]] || continue
      seen[$record]=1
      print -r -- "$record"
    done
  done
}

_py_tool_usage() {
  case "$1" in
    tool-list)
      print -u2 -r -- "Usage: py-menu tool-list"
      ;;
    tool-install)
      print -u2 -r -- \
        "Usage: py-menu tool-install [TOOL] [--backend uv|pipx] [--dry-run] [--yes]"
      ;;
    tool-uninstall)
      print -u2 -r -- \
        "Usage: py-menu tool-uninstall [TOOL] [--backend uv|pipx] [--dry-run] [--yes]"
      ;;
    tool-upgrade)
      print -u2 -r -- \
        "Usage: py-menu tool-upgrade [TOOL|--all] [--backend uv|pipx] [--dry-run] [--yes]"
      ;;
  esac
}

_py_validate_tool_backend() {
  case "${1:-}" in
    uv|pipx) return 0 ;;
    *) return 1 ;;
  esac
}

_py_select_tool_record() {
  local records="$1" prompt="${2:-Tool > }"
  local -a snapshot=("${(@f)records}")
  (( ${#snapshot[@]} > 0 )) || return 1
  if (( ${#snapshot[@]} == 1 )); then
    REPLY="${snapshot[1]}"
    return 0
  fi

  local record="" backend="" package_name=""
  local -a rows=()
  for record in "${snapshot[@]}"; do
    backend="${record%%$'\t'*}"
    package_name="${record#*$'\t'}"
    rows+=("$package_name ($backend)|$record|Isolated tool managed by $backend")
  done

  _py_check_command fzf || return 1
  local -i picker_rc=0
  _py_fzf_capture \
    "--prompt=$prompt" \
    '--header=Select one isolated Python tool' \
    --no-preview \
    < <(print -rl -- "${rows[@]}") || picker_rc=$?
  local selected="$REPLY"
  if (( picker_rc != 0 )); then
    _py_fzf_rc_is_cancel "$picker_rc" && return 130
    _py_error "The Py picker failed (status $picker_rc)."
    return 1
  fi
  [[ -n "$selected" && ${rows[(Ie)$selected]} -gt 0 ]] || {
    _py_error "The selected tool was not in the inventory snapshot."
    return 1
  }
  REPLY="${${selected#*|}%%|*}"
}

_py_resolve_tool_record() {
  local records="$1" package_name="${2:-}" requested_backend="${3:-}"
  local record="" backend="" candidate=""
  local -a matches=()
  for record in "${(@f)records}"; do
    backend="${record%%$'\t'*}"
    candidate="${record#*$'\t'}"
    [[ -z "$requested_backend" || "$backend" == "$requested_backend" ]] \
      || continue
    [[ -z "$package_name" || "$candidate" == "$package_name" ]] || continue
    matches+=("$record")
  done
  if [[ -z "$package_name" ]]; then
    (( ${#matches[@]} > 0 )) || {
      _py_error "No tools are installed in the requested backend."
      return 1
    }
    _py_select_tool_record "${(F)matches}" "Tool > "
    return $?
  fi
  case "${#matches[@]}" in
    0)
      _py_error "Tool is not installed in the requested isolated backend: $package_name"
      return 1
      ;;
    1)
      REPLY="${matches[1]}"
      return 0
      ;;
    *)
      _py_error "Tool exists in multiple backends; specify --backend uv or --backend pipx."
      return 2
      ;;
  esac
}

tool-list() {
  emulate -L zsh
  case "${1:-}" in
    "") (( $# == 0 )) || return 2 ;;
    -h|--help)
      (( $# == 1 )) || return 2
      _py_tool_usage tool-list
      return 0
      ;;
    *)
      _py_error "tool-list accepts no arguments."
      return 2
      ;;
  esac

  _py_header "Isolated Python Tools"
  local records=""
  records=$(_py_tool_inventory "" versions) || {
    local inventory_rc=$?
    return "$inventory_rc"
  }
  [[ -n "$records" ]] || {
    _py_info "No tools managed by uv or pipx were found."
    return 0
  }
  local record="" backend="" package_name="" version=""
  local -a rows=()
  for record in "${(@f)records}"; do
    backend="${record%%$'\t'*}"
    package_name="${${record#*$'\t'}%%$'\t'*}"
    version="${record##*$'\t'}"
    rows+=("$package_name"$'\t'"$backend"$'\t'"${version:-—}")
  done
  _py_table $'Tool\tBackend\tVersion' "${rows[@]}"
}

# REPLY: the version one backend reports for a tool, or an empty string.
# Usage: _py_tool_version <backend> <tool>
_py_tool_version() {
  local backend="$1" package_name="$2" records="" record=""
  REPLY=""
  records=$(_py_tool_backend_inventory "$backend" versions 2>/dev/null) \
    || return 1
  for record in "${(@f)records}"; do
    [[ "${${record#*$'\t'}%%$'\t'*}" == "$package_name" ]] || continue
    REPLY="${record##*$'\t'}"
    return 0
  done
  return 1
}

# Usage: _py_tool_confirm_change <question> <assume-yes> [cancel-note]
_py_tool_confirm_change() {
  local message="$1" cancel_note="${3:-}"
  local -i assume_yes=$2
  local _PY_AUTO_YES=$assume_yes
  _py_confirm "$message"
  local confirm_rc=$?
  case "$confirm_rc" in
    0) return 0 ;;
    130)
      if [[ -n "$cancel_note" ]]; then
        _py_info "Cancelled: $cancel_note"
      else
        _py_info "Cancelled."
      fi
      return 130
      ;;
    *) return "$confirm_rc" ;;
  esac
}

tool-install() {
  emulate -L zsh
  local package_name="" backend=""
  local -i dry_run=0 assume_yes=0
  while (( $# > 0 )); do
    case "$1" in
      --backend)
        (( $# >= 2 )) || {
          _py_error "--backend requires uv or pipx."
          return 2
        }
        [[ -n "$2" ]] || {
          _py_error "--backend requires uv or pipx."
          return 2
        }
        backend="$2"
        shift
        ;;
      --backend=*)
        backend="${1#*=}"
        [[ -n "$backend" ]] || {
          _py_error "--backend requires uv or pipx."
          return 2
        }
        ;;
      --dry-run) dry_run=1 ;;
      --yes) assume_yes=1 ;;
      -h|--help)
        (( $# == 1 )) || return 2
        _py_tool_usage tool-install
        return 0
        ;;
      -*)
        _py_error "Unknown tool-install option: $1"
        return 2
        ;;
      *)
        [[ -z "$package_name" ]] || {
          _py_error "Only one tool may be installed."
          return 2
        }
        [[ -n "$1" ]] || {
          _py_error "Tool operands may not be empty."
          return 2
        }
        package_name="$1"
        ;;
    esac
    shift
  done

  if [[ -z "$package_name" ]]; then
    _py_prompt_package_name "Tool to install"
    local prompt_rc=$?
    (( prompt_rc == 130 )) && return 0
    (( prompt_rc == 0 )) || return "$prompt_rc"
    package_name="$REPLY"
  fi
  _py_validate_package_name "$package_name" || {
    _py_error "Invalid tool package name."
    return 2
  }
  if [[ -z "$backend" ]]; then
    if command -v uv &>/dev/null; then
      backend=uv
    elif command -v pipx &>/dev/null; then
      backend=pipx
    else
      _py_error "Neither uv nor pipx is available."
      return 1
    fi
  fi
  _py_validate_tool_backend "$backend" || {
    _py_error "Tool backend must be uv or pipx."
    return 2
  }
  _py_check_command "$backend" || return 1

  _py_header "Install Isolated Python Tool"
  _py_label "Tool" "$package_name"
  _py_label "Backend" "$backend"
  _py_warn "This operation downloads and installs executable package code."
  (( dry_run )) && {
    _py_info "Dry run: nothing was installed."
    return 0
  }
  _py_tool_confirm_change \
    "Install $package_name with $backend?" "$assume_yes" \
    "nothing was installed."
  local confirm_rc=$?
  (( confirm_rc == 130 )) && return 0
  (( confirm_rc == 0 )) || return "$confirm_rc"

  local -i operation_rc=0
  if [[ "$backend" == uv ]]; then
    _py_run_captured "uv tool install $package_name" \
      command uv tool install "$package_name" || operation_rc=$?
  else
    _py_run_captured "pipx install $package_name" \
      command pipx install "$package_name" || operation_rc=$?
  fi
  (( operation_rc == 0 )) || {
    _py_error "Tool installation failed (status $operation_rc)."
    return "$operation_rc"
  }
  local REPLY
  _py_tool_version "$backend" "$package_name"
  _py_success "Installed $package_name${REPLY:+ $REPLY} with $backend."
}

tool-uninstall() {
  emulate -L zsh
  local package_name="" requested_backend=""
  local -i dry_run=0 assume_yes=0
  while (( $# > 0 )); do
    case "$1" in
      --backend)
        (( $# >= 2 )) || return 2
        [[ -n "$2" ]] || {
          _py_error "--backend requires uv or pipx."
          return 2
        }
        requested_backend="$2"
        shift
        ;;
      --backend=*)
        requested_backend="${1#*=}"
        [[ -n "$requested_backend" ]] || {
          _py_error "--backend requires uv or pipx."
          return 2
        }
        ;;
      --dry-run) dry_run=1 ;;
      --yes) assume_yes=1 ;;
      -h|--help)
        (( $# == 1 )) || return 2
        _py_tool_usage tool-uninstall
        return 0
        ;;
      -*)
        _py_error "Unknown tool-uninstall option: $1"
        return 2
        ;;
      *)
        [[ -z "$package_name" ]] || return 2
        [[ -n "$1" ]] || {
          _py_error "Tool operands may not be empty."
          return 2
        }
        package_name="$1"
        ;;
    esac
    shift
  done
  [[ -z "$requested_backend" ]] \
    || _py_validate_tool_backend "$requested_backend" || {
    _py_error "Tool backend must be uv or pipx."
    return 2
  }
  [[ -z "$package_name" ]] || _py_validate_package_name "$package_name" || {
    _py_error "Invalid tool package name."
    return 2
  }

  local records=""
  records=$(_py_tool_inventory "$requested_backend") || {
    local inventory_rc=$?
    return "$inventory_rc"
  }
  [[ -n "$records" ]] || {
    _py_info "No isolated Python tools are installed."
    return 0
  }
  _py_resolve_tool_record "$records" "$package_name" "$requested_backend"
  local resolve_rc=$?
  (( resolve_rc == 130 )) && {
    _py_info "Cancelled."
    return 0
  }
  (( resolve_rc == 0 )) || return "$resolve_rc"
  local record="$REPLY"
  local backend="${record%%$'\t'*}"
  package_name="${record#*$'\t'}"

  _py_header "Uninstall Isolated Python Tool"
  _py_label "Tool" "$package_name"
  _py_label "Backend" "$backend"
  (( dry_run )) && {
    _py_info "Dry run: nothing was uninstalled."
    return 0
  }
  _py_tool_confirm_change \
    "Uninstall $package_name from $backend?" "$assume_yes" \
    "nothing was uninstalled."
  local confirm_rc=$?
  (( confirm_rc == 130 )) && return 0
  (( confirm_rc == 0 )) || return "$confirm_rc"

  local current_records=""
  current_records=$(_py_tool_inventory "$requested_backend") || {
    local inventory_rc=$?
    return "$inventory_rc"
  }
  (( ${${(@f)current_records}[(Ie)$record]} > 0 )) || {
    _py_error "The selected tool changed after review."
    return 1
  }

  local -i operation_rc=0
  if [[ "$backend" == uv ]]; then
    _py_run_captured "uv tool uninstall $package_name" \
      command uv tool uninstall "$package_name" || operation_rc=$?
  else
    _py_run_captured "pipx uninstall $package_name" \
      command pipx uninstall "$package_name" || operation_rc=$?
  fi
  (( operation_rc == 0 )) || {
    _py_error "Tool uninstallation failed (status $operation_rc)."
    return "$operation_rc"
  }
  _py_success "Uninstalled $package_name from $backend."
}

tool-upgrade() {
  emulate -L zsh
  local package_name="" requested_backend=""
  local -i upgrade_all=0 dry_run=0 assume_yes=0
  while (( $# > 0 )); do
    case "$1" in
      --all) upgrade_all=1 ;;
      --backend)
        (( $# >= 2 )) || return 2
        [[ -n "$2" ]] || {
          _py_error "--backend requires uv or pipx."
          return 2
        }
        requested_backend="$2"
        shift
        ;;
      --backend=*)
        requested_backend="${1#*=}"
        [[ -n "$requested_backend" ]] || {
          _py_error "--backend requires uv or pipx."
          return 2
        }
        ;;
      --dry-run) dry_run=1 ;;
      --yes) assume_yes=1 ;;
      -h|--help)
        (( $# == 1 )) || return 2
        _py_tool_usage tool-upgrade
        return 0
        ;;
      -*)
        _py_error "Unknown tool-upgrade option: $1"
        return 2
        ;;
      *)
        [[ -z "$package_name" ]] || return 2
        [[ -n "$1" ]] || {
          _py_error "Tool operands may not be empty."
          return 2
        }
        package_name="$1"
        ;;
    esac
    shift
  done
  if (( upgrade_all )) && [[ -n "$package_name" ]]; then
    _py_error "Choose one tool or --all, not both."
    return 2
  fi
  [[ -z "$requested_backend" ]] \
    || _py_validate_tool_backend "$requested_backend" || {
    _py_error "Tool backend must be uv or pipx."
    return 2
  }
  [[ -z "$package_name" ]] || _py_validate_package_name "$package_name" || {
    _py_error "Invalid tool package name."
    return 2
  }

  local records=""
  records=$(_py_tool_inventory "$requested_backend") || {
    local inventory_rc=$?
    return "$inventory_rc"
  }
  [[ -n "$records" ]] || {
    _py_info "No isolated Python tools are installed."
    return 0
  }

  local -a operations=()
  if (( upgrade_all )); then
    local record="" backend=""
    for record in "${(@f)records}"; do
      backend="${record%%$'\t'*}"
      [[ -z "$requested_backend" || "$backend" == "$requested_backend" ]] \
        || continue
      operations+=("$record")
    done
    (( ${#operations[@]} > 0 )) || {
      _py_error "No tools are installed in the requested backend."
      return 1
    }
  else
    _py_resolve_tool_record "$records" "$package_name" "$requested_backend"
    local resolve_rc=$?
    (( resolve_rc == 130 )) && {
      _py_info "Cancelled."
      return 0
    }
    (( resolve_rc == 0 )) || return "$resolve_rc"
    local record="$REPLY"
    operations+=("$record")
    package_name="${record#*$'\t'}"
  fi
  local frozen_operations="${(F)operations}"

  # Versions are display evidence only; the frozen set compares names.
  local version_records="" version_record=""
  local -A before_versions=()
  version_records=$(_py_tool_inventory "$requested_backend" versions \
    2>/dev/null) || version_records=""
  for version_record in "${(@f)version_records}"; do
    [[ -n "$version_record" ]] || continue
    before_versions[${version_record%$'\t'*}]="${version_record##*$'\t'}"
  done

  _py_header "Upgrade Isolated Python Tools"
  local planned_record="" REPLY planned=""
  local -a plan_rows=()
  local -i plan_index=0
  for planned_record in "${operations[@]}"; do
    plan_rows+=("$(( ++plan_index ))"$'\t'"${planned_record#*$'\t'}"$'\t'"${planned_record%%$'\t'*}"$'\t'"${before_versions[$planned_record]:-—}")
  done
  _py_table $'#\tTool\tBackend\tVersion' "${plan_rows[@]}"
  _py_warn "Upgrades download and install executable package code."
  _py_count_noun "${#operations[@]}" tool
  planned="$REPLY"
  (( dry_run )) && {
    _py_info "Dry run: $planned planned; nothing was upgraded."
    return 0
  }
  _py_tool_confirm_change "Upgrade $planned?" "$assume_yes" \
    "nothing was upgraded."
  local confirm_rc=$?
  (( confirm_rc == 130 )) && return 0
  (( confirm_rc == 0 )) || return "$confirm_rc"

  local current_records=""
  current_records=$(_py_tool_inventory "$requested_backend") || {
    local inventory_rc=$?
    return "$inventory_rc"
  }
  if (( upgrade_all )); then
    local -a current_operations=()
    local current_record="" current_backend=""
    for current_record in "${(@f)current_records}"; do
      current_backend="${current_record%%$'\t'*}"
      [[ -z "$requested_backend" \
        || "$current_backend" == "$requested_backend" ]] || continue
      current_operations+=("$current_record")
    done
    [[ "${(F)current_operations}" == "$frozen_operations" ]] || {
      _py_error "The reviewed isolated tool set changed after review."
      return 1
    }
  else
    (( ${${(@f)current_records}[(Ie)${operations[1]}]} > 0 )) || {
      _py_error "The selected tool changed after review."
      return 1
    }
  fi

  # Each target is one step: a [n/N] banner and result line when several
  # run, version evidence for updated versus current, and one verdict.
  local operation="" backend="" candidate="" step_label="" before=""
  local step_start="" step_seconds="" outcome="" detail=""
  local -a summary_records=() retry_commands=()
  local -i operation_rc=0 failures=0 index=0 total=${#operations[@]}
  local -i interrupted_status=0 updated=0 current=0 not_run=0
  for operation in "${operations[@]}"; do
    (( ++index ))
    backend="${operation%%$'\t'*}"
    candidate="${operation#*$'\t'}"
    step_label="$candidate ($backend)"
    if (( interrupted_status )); then
      (( ++not_run ))
      summary_records+=("$step_label"$'\tnot-run\t\tupgrade interrupted')
      continue
    fi
    (( total > 1 )) && _py_step_banner "$index" "$total" "$step_label"
    step_start="${EPOCHREALTIME:-$SECONDS}"
    operation_rc=0
    if [[ "$backend" == uv ]]; then
      _py_run_captured "uv tool upgrade $candidate" \
        command uv tool upgrade "$candidate" || operation_rc=$?
    else
      _py_run_captured "pipx upgrade $candidate" \
        command pipx upgrade "$candidate" || operation_rc=$?
    fi
    step_seconds=$(( ${EPOCHREALTIME:-$SECONDS} - step_start ))
    (( step_seconds >= 0 )) || step_seconds=0
    before="${before_versions[$operation]:-}"
    if (( operation_rc == 130 || operation_rc == 143 )); then
      outcome=interrupted detail="status $operation_rc"
      interrupted_status=$operation_rc
      retry_commands+=("tool-upgrade $candidate --backend $backend")
    elif (( operation_rc != 0 )); then
      outcome=failed detail="status $operation_rc"
      (( ++failures ))
      retry_commands+=("tool-upgrade $candidate --backend $backend")
    elif [[ -n "$before" ]] && _py_tool_version "$backend" "$candidate" \
      && [[ -n "$REPLY" ]]; then
      if [[ "$REPLY" == "$before" ]]; then
        outcome=current detail="$REPLY"
        (( ++current ))
      else
        outcome=updated detail="$before → $REPLY"
        (( ++updated ))
      fi
    else
      # Without a comparable version the upgrade is only known to succeed.
      outcome=done detail="version unavailable"
    fi
    (( total > 1 )) && _py_step_result "$index" "$total" "$step_label" \
      "$outcome" "$detail" "$step_seconds"
    summary_records+=("$step_label"$'\t'"$outcome"$'\t'"$step_seconds"$'\t'"$detail")
  done

  (( total > 1 )) \
    && _py_print_step_summary --first-column Tool "Tool Upgrade Summary" \
      "${summary_records[@]}"
  local -a counts=()
  (( updated )) && counts+=("$updated updated")
  (( current )) && counts+=("$current current")
  local -i done_count=$(( index - updated - current - failures - not_run ))
  (( interrupted_status )) && (( done_count -= 1 ))
  (( done_count > 0 )) && counts+=("$done_count done")
  (( failures )) && counts+=("$failures failed")
  (( interrupted_status )) && counts+=("1 interrupted")
  (( not_run )) && counts+=("$not_run not run")
  local count_text="${(j: · :)counts}"
  print -u2 -r -- ""
  if (( interrupted_status )); then
    _py_error "Tool upgrades interrupted (status $interrupted_status): $count_text."
  elif (( failures == 0 )); then
    _py_success "Tool upgrades completed: $count_text."
  elif (( failures < total )); then
    _py_error "Tool upgrades completed with partial failures: $count_text."
    (( ${+functions[_zdx_timed_mark_partial]} )) \
      && { _zdx_timed_mark_partial || true; }
  else
    _py_error "Tool upgrades failed: $count_text."
  fi
  if (( ${#retry_commands[@]} > 0 )); then
    _py_info "Inspect each tool, then retry:"
    local retry_command=""
    for retry_command in "${(@u)retry_commands}"; do
      _py_dim "$retry_command"
    done
  fi
  (( interrupted_status )) && return "$interrupted_status"
  (( failures == 0 )) || return 1
  return 0
}

typeset -g _PY_TOOLS_SOURCED=1
