#!/usr/bin/env zsh
# =============================================================================
# AI Clean: bounded home-level cleanup plans
# =============================================================================
#
# Loaded by ai-menu.zsh after ai-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_AI_CLEAN_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset -gi _AI_CLEAN_MAX_TARGETS=256

_ai_clean_capture_target() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local target="${1:-}"
  REPLY=""

  local home_root="${HOME:A}"
  [[ -n "$target" && "$target" == /* && "$target" != "/" \
    && "$target" != "$home_root" && "$target" == "$home_root"/* \
    && "$target" != *'|'* && "$target" != *[[:cntrl:]]* \
    && ( -e "$target" || -L "$target" ) \
    && ! -L "$target" && "$target" == "${target:A}" && -O "$target" ]] || {
    _ai_error "Refusing an unsafe cleanup target: $target"
    return 1
  }

  local -A state=()
  zstat -LH state -- "$target" 2>/dev/null || return 1
  local -i object_type=$(( state[mode] & 8#170000 ))
  (( object_type == 8#040000 || object_type == 8#100000 )) || {
    _ai_error "Cleanup targets must be regular files or directories: $target"
    return 1
  }
  if (( object_type == 8#100000 && state[nlink] != 1 )); then
    _ai_error "Refusing a multiply linked cleanup file: $target"
    return 1
  fi
  REPLY="${state[device]}:${state[inode]}:${state[mode]}:"\
"${state[uid]}:${state[nlink]}:${state[size]}:${state[mtime]}"
}

_ai_clean_target_matches() {
  local target="$1" expected="$2"
  _ai_clean_capture_target "$target" || return 1
  [[ "$REPLY" == "$expected" ]]
}

_ai_clean_build_plan() {
  reply=()
  local target fingerprint
  local -A seen=()
  for target in "$@"; do
    [[ -e "$target" || -L "$target" ]] || continue
    [[ -z "${seen[$target]:-}" ]] || continue
    _ai_clean_capture_target "$target" || return 1
    fingerprint="$REPLY"
    seen[$target]=1
    reply+=("$target|$fingerprint")
    (( ${#reply[@]} <= _AI_CLEAN_MAX_TARGETS )) || {
      _ai_error "Cleanup plan exceeds $_AI_CLEAN_MAX_TARGETS targets."
      return 1
    }
  done
}

_ai_clean_execute_plan() {
  local label="$1"
  shift
  local -a plan=("$@")
  (( ${#plan[@]} > 0 )) || {
    _ai_info "$label: no eligible targets found."
    return 0
  }

  _ai_header "$label Cleanup Plan"
  local record target fingerprint
  for record in "${plan[@]}"; do
    target="${record%%|*}"
    _ai_info "$target"
  done
  if (( _AI_DRY_RUN )); then
    _ai_info "Dry run: no cleanup target was removed."
    return 0
  fi

  _ai_authorize "Remove ${#plan[@]} reviewed $label cleanup target(s)?"
  local authorize_rc=$?
  (( authorize_rc == 130 )) && return 0
  (( authorize_rc == 0 )) || return $authorize_rc

  local -i removed=0 failures=0
  for record in "${plan[@]}"; do
    target="${record%%|*}"
    fingerprint="${record#*|}"
    if ! _ai_clean_target_matches "$target" "$fingerprint"; then
      _ai_error "Cleanup target changed after review: $target"
      (( failures += 1 ))
      continue
    fi

    _ai_no_nested_mounts "$target" || {
      (( failures += 1 ))
      continue
    }
    _ai_clean_target_matches "$target" "$fingerprint" || {
      _ai_error "Cleanup target changed during mount validation: $target"
      (( failures += 1 ))
      continue
    }
    if ! _ai_move_to_trash "$target" "$target" "$fingerprint"; then
      (( failures += 1 ))
      continue
    fi
    (( removed += 1 ))
  done
  _ai_info "$label cleanup quarantined $removed of ${#plan[@]} target(s)."
  (( failures == 0 ))
}

_ai_clean_parse() {
  local command_name="$1"
  shift
  _ai_parse_flags clean "$command_name" "$@" || return $?
  if (( _AI_HELP_ONLY )); then
    return 64
  fi
}

_ai_clean_targets_claude() {
  local root="${HOME:A}/.claude"
  reply=(
    "${HOME:A}/.cache/claude-cli-nodejs" \
    "$root/debug" "$root/cache" "$root/paste-cache" "$root/session-env" \
    "$root/shell-snapshots" "$root/telemetry"
  )
}

_ai_clean_targets_codex() {
  local root="${HOME:A}/.codex"
  reply=("$root/log" "$root/tmp" "$root/shell_snapshots" "$root/models_cache.json")
}

_ai_clean_targets_antigravity() {
  local root="${HOME:A}/.gemini/antigravity-cli"
  reply=("$root/log")
}

_ai_clean_targets_opencode() {
  reply=("$(_ai_opencode_data_dir)/logs")
}

_ai_clean_targets_copilot() {
  reply=("${HOME:A}/.copilot/logs")
}

_ai_clean_targets_cursor() {
  # Cursor project logs and installed versions are preserved until a stable,
  # bounded vendor-owned identity model is available.
  reply=()
}

_ai_clean_targets_amp() {
  # file-changes can contain recovery material; no Amp target is currently
  # proven ephemeral enough for unattended cleanup.
  reply=()
}

_ai_clean_public() {
  local label="$1" collector="$2" command_name="$3"
  shift 3
  _ai_clean_parse "$command_name" "$@"
  local rc=$?
  (( rc == 64 )) && return 0
  (( rc == 0 )) || return $rc
  "$collector" || return 1
  local -a targets=("${reply[@]}")
  _ai_clean_build_plan "${targets[@]}" || return 1
  _ai_clean_execute_plan "$label" "${reply[@]}"
}

global-clean-claude() {
  _ai_clean_public "Claude Code" _ai_clean_targets_claude \
    "global-clean-claude" "$@"
}
global-clean-codex() {
  _ai_clean_public "Codex" _ai_clean_targets_codex "global-clean-codex" "$@"
}
global-clean-antigravity() {
  _ai_clean_public "Antigravity" _ai_clean_targets_antigravity \
    "global-clean-antigravity" "$@"
}
global-clean-opencode() {
  _ai_clean_public "OpenCode" _ai_clean_targets_opencode \
    "global-clean-opencode" "$@"
}
global-clean-copilot() {
  _ai_clean_public "Copilot" _ai_clean_targets_copilot \
    "global-clean-copilot" "$@"
}
global-clean-cursor() {
  _ai_clean_public "Cursor Agent" _ai_clean_targets_cursor \
    "global-clean-cursor" "$@"
}
global-clean-amp() {
  _ai_clean_public "Amp" _ai_clean_targets_amp "global-clean-amp" "$@"
}

global-clean-ai() {
  _ai_clean_parse "global-clean-ai" "$@"
  local rc=$?
  (( rc == 64 )) && return 0
  (( rc == 0 )) || return $rc

  local -a targets=()
  local collector
  for collector in \
    _ai_clean_targets_claude \
    _ai_clean_targets_codex \
    _ai_clean_targets_antigravity \
    _ai_clean_targets_opencode \
    _ai_clean_targets_copilot \
    _ai_clean_targets_cursor \
    _ai_clean_targets_amp; do
    "$collector" || return 1
    targets+=("${reply[@]}")
  done
  _ai_clean_build_plan "${targets[@]}" || return 1
  _ai_clean_execute_plan "All assistants" "${reply[@]}"
}

typeset -g _AI_CLEAN_SOURCED=1
