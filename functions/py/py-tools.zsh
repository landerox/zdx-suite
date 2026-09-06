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

# Data record: backend<TAB>validated-package-name
_py_tool_backend_inventory() {
  local backend="$1"
  local raw_output=""
  local -a producer_args=()
  case "$backend" in
    uv)
      producer_args=(uv tool list)
      _py_timeout_prefix 15 || return $?
      producer_args=("${reply[@]}" "${producer_args[@]}")
      raw_output=$(_py_capture_bounded_output \
        $(( 1024 * 1024 )) "uv tool inventory" \
        "${producer_args[@]}") || return $?
      ;;
    pipx)
      producer_args=(pipx list --short)
      _py_timeout_prefix 15 || return $?
      producer_args=("${reply[@]}" "${producer_args[@]}")
      raw_output=$(_py_capture_bounded_output \
        $(( 1024 * 1024 )) "pipx tool inventory" \
        "${producer_args[@]}") || return $?
      ;;
    *) return 2 ;;
  esac

  local line="" package_name=""
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
    print -r -- "$backend"$'\t'"$package_name"
  done
}

_py_tool_inventory() {
  local requested_backend="${1:-}"
  local backend="" backend_records="" record=""
  local -a eligible_backends=(uv pipx)
  if [[ -n "$requested_backend" ]]; then
    _py_check_command "$requested_backend" || return $?
    eligible_backends=("$requested_backend")
  fi
  local -A seen=()
  for backend in "${eligible_backends[@]}"; do
    command -v "$backend" &>/dev/null || continue
    backend_records=$(_py_tool_backend_inventory "$backend") || return $?
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
    return "$picker_rc"
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
  records=$(_py_tool_inventory) || {
    local inventory_rc=$?
    return "$inventory_rc"
  }
  [[ -n "$records" ]] || {
    _py_info "No tools managed by uv or pipx were found."
    return 0
  }
  local record="" backend="" package_name=""
  for record in "${(@f)records}"; do
    backend="${record%%$'\t'*}"
    package_name="${record#*$'\t'}"
    _py_info "$package_name ($backend)"
  done
}

_py_tool_confirm_change() {
  local message="$1"
  local -i assume_yes=$2
  local _PY_AUTO_YES=$assume_yes
  _py_confirm "$message"
  local confirm_rc=$?
  case "$confirm_rc" in
    0) return 0 ;;
    130)
      _py_info "Cancelled."
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
  _py_info "Plan: install $package_name with $backend"
  _py_warn "This operation downloads and installs executable package code."
  (( dry_run )) && {
    _py_success "Dry run complete; no tool state changed."
    return 0
  }
  _py_tool_confirm_change \
    "Proceed with this reviewed tool installation?" "$assume_yes"
  local confirm_rc=$?
  (( confirm_rc == 130 )) && return 0
  (( confirm_rc == 0 )) || return "$confirm_rc"

  local -i operation_rc=0
  if [[ "$backend" == uv ]]; then
    command uv tool install "$package_name" >&2 || operation_rc=$?
  else
    command pipx install "$package_name" >&2 || operation_rc=$?
  fi
  (( operation_rc == 0 )) || {
    _py_error "Tool installation failed (status $operation_rc)."
    return "$operation_rc"
  }
  _py_success "Installed $package_name with $backend."
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
  _py_info "Plan: uninstall $package_name from $backend"
  (( dry_run )) && {
    _py_success "Dry run complete; no tool state changed."
    return 0
  }
  _py_tool_confirm_change \
    "Proceed with this tool uninstallation?" "$assume_yes"
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
    command uv tool uninstall "$package_name" >&2 || operation_rc=$?
  else
    command pipx uninstall "$package_name" >&2 || operation_rc=$?
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

  _py_header "Upgrade Isolated Python Tools"
  if (( upgrade_all )); then
    _py_info "Plan: upgrade this exact frozen set (${#operations[@]} tool(s)):"
    local planned_record="" planned_backend="" planned_package=""
    for planned_record in "${operations[@]}"; do
      planned_backend="${planned_record%%$'\t'*}"
      planned_package="${planned_record#*$'\t'}"
      _py_info "  $planned_package ($planned_backend)"
    done
  else
    _py_info "Plan: upgrade $package_name in ${operations[1]%%$'\t'*}"
  fi
  _py_warn "Upgrades download and install executable package code."
  (( dry_run )) && {
    _py_success "Dry run complete; no tool state changed."
    return 0
  }
  _py_tool_confirm_change \
    "Proceed with this reviewed tool upgrade?" "$assume_yes"
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

  local operation="" backend="" candidate=""
  local -i operation_rc=0 failures=0 passed=0 attempted=0
  for operation in "${operations[@]}"; do
    (( ++attempted ))
    backend="${operation%%$'\t'*}"
    candidate="${operation#*$'\t'}"
    if [[ "$backend" == uv ]]; then
      command uv tool upgrade "$candidate" >&2 || operation_rc=$?
    else
      command pipx upgrade "$candidate" >&2 || operation_rc=$?
    fi
    if (( operation_rc == 130 || operation_rc == 143 )); then
      _py_warn "Tool upgrade interrupted: $candidate ($backend, status $operation_rc)."
      _py_info "Inspect its state before retrying: tool-upgrade $candidate --backend $backend"
      _py_info \
        "Upgrade summary: passed=$passed failed=$failures interrupted=1 not-run=$((${#operations[@]} - attempted))"
      return "$operation_rc"
    elif (( operation_rc != 0 )); then
      (( failures++ ))
      _py_error "Tool upgrade failed: $candidate ($backend, status $operation_rc)."
      _py_info "Review and retry this target: tool-upgrade $candidate --backend $backend"
    else
      (( ++passed ))
      _py_success "Upgraded $candidate ($backend)."
    fi
    operation_rc=0
  done
  _py_info "Upgrade summary: passed=$passed failed=$failures interrupted=0 not-run=0"
  (( failures == 0 )) || return 1
  _py_success "Tool upgrade completed."
}

typeset -g _PY_TOOLS_SOURCED=1
