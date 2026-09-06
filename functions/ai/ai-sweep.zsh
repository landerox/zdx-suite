#!/usr/bin/env zsh
# =============================================================================
# AI Sweep: bounded project-artifact cleanup
# =============================================================================
#
# Loaded by ai-menu.zsh after ai-common.zsh and ai-clean.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_AI_SWEEP_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset -gi _AI_SWEEP_MAX_TARGETS=256
typeset -gi _AI_SWEEP_MAX_SCAN_BYTES=8388608

_ai_sweep_warn_if_mnt() {
  [[ "$1" == /mnt/* ]] \
    && _ai_warn "Scanning /mnt/* is slow on WSL (NTFS). Consider ~/src instead."
}

_ai_sweep_root_identity() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local root="${1:-}"
  local home_root="${HOME:A}"
  [[ -n "$root" && "$root" == "${root:A}" && "$root" != "/" \
    && ( "$root" == "$home_root" || "$root" == "$home_root"/* ) \
    && -d "$root" && ! -L "$root" && -O "$root" ]] || return 1
  local -A state=()
  zstat -LH state -- "$root" 2>/dev/null || return 1
  REPLY="${state[device]}:${state[inode]}:${state[mode]}:${state[uid]}"
}

_ai_sweep_validate_root() {
  emulate -L zsh
  local requested="${1:-}"
  local home_root="${HOME:A}"
  REPLY=""

  [[ -n "$requested" && "$requested" == /* \
    && "$requested" != "/" && "$requested" != *[[:cntrl:]]* \
    && -d "$requested" && ! -L "$requested" && -O "$requested" ]] || {
    _ai_error "Sweep root must be an owned, absolute, non-symlink directory."
    return 1
  }

  local canonical="${requested:A}"
  [[ "$requested" == "$canonical" \
    && ( "$canonical" == "$home_root" || "$canonical" == "$home_root"/* ) ]] || {
    _ai_error "Sweep root must be canonical and remain inside HOME: $requested"
    return 1
  }
  REPLY="$canonical"
}

_ai_sweep_known_target() {
  local root="$1" target="$2"
  [[ "$target" == "$root"/* ]] || return 1
  local relative="${target#$root/}"
  case "$relative" in
    .claude/debug|*/.claude/debug|.claude/tmp|*/.claude/tmp|\
    .claude/cache|*/.claude/cache|\
    .codex/logs|*/.codex/logs|.codex/tmp|*/.codex/tmp|\
    .opencode/logs|*/.opencode/logs|.opencode/tmp|*/.opencode/tmp)
      [[ -d "$target" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

_ai_sweep_scan() {
  emulate -L zsh
  setopt local_options pipe_fail
  local root="$1" depth="$2" expected_root="$3"
  reply=()

  local temp_parent="${TMPDIR:-/tmp}"
  [[ "$temp_parent" == /* ]] || {
    _ai_error "Refusing a relative temporary root for the sweep."
    return 1
  }
  temp_parent="${temp_parent:A}"
  [[ "$temp_parent" == /* && -d "$temp_parent" && ! -L "$temp_parent" ]] || {
    _ai_error "Refusing an unsafe temporary root for the sweep."
    return 1
  }

  local -A parent_state=() scan_dir_state=() scan_dir_cleanup=()
  local -A before=() after=() cleanup_state=()
  local -i scan_rc=1 operation_rc=1 cleanup_rc=0
  zmodload zsh/stat 2>/dev/null || return 1
  _ai_temp_parent_check "$temp_parent" || {
    _ai_error "Temporary root must be current-user safe or root-owned sticky."
    return 1
  }
  local temp_parent_identity="$REPLY"
  local scan_dir=""
  scan_dir=$(umask 077; command mktemp -d \
    "$temp_parent/zdx-ai-sweep.XXXXXX" 2>/dev/null) || {
    _ai_error "Could not create a private sweep directory."
    return 1
  }
  local scan_file="$scan_dir/candidates"
  [[ "$scan_dir" == "${scan_dir:A}" && "${scan_dir:h}" == "$temp_parent" \
    && "${scan_dir:t}" == zdx-ai-sweep.* && -d "$scan_dir" \
    && ! -L "$scan_dir" && -O "$scan_dir" ]] \
    && zstat -LH scan_dir_state -- "$scan_dir" 2>/dev/null \
    && (( scan_dir_state[uid] == EUID && scan_dir_state[nlink] == 2 \
      && (scan_dir_state[mode] & 8#170000) == 8#040000 \
      && (scan_dir_state[mode] & 8#077) == 0 )) || {
    _ai_error "Refusing an unsafe private sweep directory."
    return 1
  }

  {
    (umask 077; : > "$scan_file") || {
      _ai_error "Could not create the private sweep inventory."
      return 1
    }
    [[ -f "$scan_file" && ! -L "$scan_file" && -O "$scan_file" ]] \
      && zstat -LH before -- "$scan_file" 2>/dev/null || {
      _ai_error "Refusing an unsafe sweep inventory."
      return 1
    }

    local -a xdev_args=()
    (( _AI_SWEEP_XDEV )) && xdev_args=(-xdev)
    (
      # Bound the private inventory even if an adversarial tree contains an
      # extreme number of matching names.
      ulimit -f 16384 2>/dev/null || exit 1
      local timeout_bin=""
      if command -v timeout >/dev/null 2>&1; then
        timeout_bin="$(command -v timeout)"
      elif command -v gtimeout >/dev/null 2>&1; then
        timeout_bin="$(command -v gtimeout)"
      else
        exit 124
      fi
      command "$timeout_bin" --foreground --kill-after=1s 15s \
        find "$root" "${xdev_args[@]}" \
        -mindepth 1 -maxdepth "$depth" \
        \( -type d \( \
          -name .git -o -name node_modules -o -name .venv -o -name venv -o \
          -name .cache -o -name dist -o -name build -o -name target -o \
          -name .next -o -name .turbo -o -name .pnpm-store \
        \) -prune \) -o \
        \( -type d \( \
          -path '*/.claude/debug' -o -path '*/.claude/tmp' -o \
          -path '*/.claude/cache' -o -path '*/.codex/logs' -o \
          -path '*/.codex/tmp' -o -path '*/.opencode/logs' -o \
          -path '*/.opencode/tmp' \
        \) -print0 \) > "$scan_file" 2>/dev/null
    )
    scan_rc=$?

    zstat -LH after -- "$scan_file" 2>/dev/null \
      && [[ "${before[device]}:${before[inode]}:${before[uid]}:${before[nlink]}" \
        == "${after[device]}:${after[inode]}:${after[uid]}:${after[nlink]}" ]] \
      && (( after[size] >= 0 && after[size] <= _AI_SWEEP_MAX_SCAN_BYTES )) || {
      _ai_error "The sweep inventory changed or exceeded its byte bound."
      return 1
    }
    (( scan_rc == 0 )) || {
      if (( scan_rc == 124 || scan_rc == 137 )); then
        _ai_error "Project sweep timed out or no timeout utility is available."
      else
        _ai_error "The bounded project sweep did not complete."
      fi
      return 1
    }

    _ai_sweep_root_identity "$root" \
      && [[ "$REPLY" == "$expected_root" ]] || {
      _ai_error "Sweep root changed while it was scanned."
      return 1
    }

    local candidate=""
    local -A seen=()
    while IFS= read -r -d '' candidate; do
      [[ -z "${seen[$candidate]:-}" ]] || continue
      _ai_sweep_known_target "$root" "$candidate" || {
        _ai_error "The sweep produced an unexpected target: $candidate"
        return 1
      }
      _ai_clean_capture_target "$candidate" || return 1
      seen[$candidate]=1
      reply+=("$candidate")
      (( ${#reply[@]} <= _AI_SWEEP_MAX_TARGETS )) || {
        _ai_error "Sweep exceeds $_AI_SWEEP_MAX_TARGETS cleanup targets."
        return 1
      }
    done < "$scan_file"
    operation_rc=0
  } always {
    if [[ -f "$scan_file" && ! -L "$scan_file" ]] \
      && zstat -LH cleanup_state -- "$scan_file" 2>/dev/null \
      && [[ "${before[device]}:${before[inode]}:${before[uid]}:${before[nlink]}" \
        == "${cleanup_state[device]}:${cleanup_state[inode]}:"\
"${cleanup_state[uid]}:${cleanup_state[nlink]}" ]]; then
      command rm -f -- "$scan_file" 2>/dev/null || cleanup_rc=1
    else
      cleanup_rc=1
    fi
    if [[ -d "$scan_dir" && ! -L "$scan_dir" ]] \
      && zstat -LH scan_dir_cleanup -- "$scan_dir" 2>/dev/null \
      && [[ "${scan_dir_state[device]}:${scan_dir_state[inode]}:"\
"${scan_dir_state[uid]}:${scan_dir_state[nlink]}" \
        == "${scan_dir_cleanup[device]}:${scan_dir_cleanup[inode]}:"\
"${scan_dir_cleanup[uid]}:${scan_dir_cleanup[nlink]}" ]]; then
      command rmdir -- "$scan_dir" 2>/dev/null || cleanup_rc=1
    else
      cleanup_rc=1
    fi
    _ai_temp_parent_check "$temp_parent" \
      && [[ "$REPLY" == "$temp_parent_identity" ]] || cleanup_rc=1
    (( cleanup_rc == 0 )) || operation_rc=1
  }

  return $operation_rc
}

_ai_sweep_execute_plan() {
  local root="$1" root_identity="$2"
  shift 2
  local -a plan=("$@")
  (( ${#plan[@]} > 0 )) || {
    _ai_info "Project artifact: no eligible targets found."
    return 0
  }

  _ai_header "Project Artifact Cleanup Plan"
  local record="" target="" fingerprint=""
  for record in "${plan[@]}"; do
    target="${record%%|*}"
    _ai_info "$target"
  done
  if (( _AI_DRY_RUN )); then
    _ai_info "Dry run: no project artifact was removed."
    return 0
  fi
  _ai_authorize "Remove ${#plan[@]} reviewed project artifact(s)?"
  local authorize_rc=$?
  (( authorize_rc == 130 )) && return 0
  (( authorize_rc == 0 )) || return $authorize_rc
  _ai_sweep_root_identity "$root" && [[ "$REPLY" == "$root_identity" ]] || {
    _ai_error "Sweep root changed after authorization."
    return 1
  }

  local -i removed=0 failures=0
  for record in "${plan[@]}"; do
    target="${record%%|*}"
    fingerprint="${record#*|}"
    _ai_sweep_root_identity "$root" && [[ "$REPLY" == "$root_identity" ]] || {
      _ai_error "Sweep root changed before target removal."
      return 1
    }
    _ai_sweep_known_target "$root" "$target" \
      && _ai_clean_target_matches "$target" "$fingerprint" || {
      _ai_error "Project artifact changed after review: $target"
      (( failures += 1 ))
      continue
    }
    _ai_no_nested_mounts "$target" || {
      (( failures += 1 ))
      continue
    }
    _ai_clean_target_matches "$target" "$fingerprint" || {
      _ai_error "Project artifact changed during mount validation: $target"
      (( failures += 1 ))
      continue
    }
    _ai_move_to_trash "$target" "$target" "$fingerprint" || {
      (( failures += 1 ))
      continue
    }
    (( removed += 1 ))
  done
  _ai_info "Project sweep quarantined $removed of ${#plan[@]} target(s)."
  (( failures == 0 ))
}

project-sweep-ai() {
  emulate -L zsh
  _ai_parse_flags sweep "project-sweep-ai" "$@" || return $?
  if (( _AI_HELP_ONLY )); then
    return 0
  fi

  _ai_sweep_validate_root "$_AI_SWEEP_ROOT" || return 1
  local root="$REPLY"
  _ai_sweep_root_identity "$root" || {
    _ai_error "Could not freeze the sweep-root identity."
    return 1
  }
  local root_identity="$REPLY"

  _ai_header "Project AI Artifact Sweep"
  _ai_info "Root: $root"
  _ai_info "Maximum depth: $_AI_SWEEP_DEPTH"
  (( _AI_SWEEP_XDEV )) && _ai_info "Filesystem boundary: enabled"
  _ai_sweep_warn_if_mnt "$root"

  _ai_sweep_scan "$root" "$_AI_SWEEP_DEPTH" "$root_identity" || return 1
  local -a targets=("${reply[@]}")
  _ai_clean_build_plan "${targets[@]}" || return 1
  _ai_sweep_execute_plan "$root" "$root_identity" "${reply[@]}"
}

typeset -g _AI_SWEEP_SOURCED=1
