#!/usr/bin/env zsh
# =============================================================================
# AI Disk: disk usage and version reports across supported tools
# =============================================================================
#
# Loaded by ai-menu.zsh after ai-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_AI_DISK_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# --- Disk Usage Report -------------------------------------------------------

ai-disk-usage() {
  emulate -L zsh
  _ai_parse_flags disk "ai-disk-usage" "$@" || return $?
  if (( _AI_HELP_ONLY )); then
    return 0
  fi
  {
  _ai_header "AI CLI Disk Usage"
  local -a roots=(
    "Claude Code|$HOME/.claude"
    "Claude cache|$HOME/.cache/claude-cli-nodejs"
    "OpenAI Codex|$HOME/.codex"
    "Antigravity CLI|$HOME/.gemini/antigravity-cli"
    "OpenCode config|$(_ai_opencode_config_dir)"
    "OpenCode data|$(_ai_opencode_data_dir)"
    "GitHub Copilot|$HOME/.copilot"
    "Cursor config|$HOME/.cursor"
    "Cursor installation|$HOME/.local/share/cursor-agent"
    "Amp config/cache|$HOME/.amp"
    "Amp durable data|$HOME/.local/share/amp"
    "AI config snapshots|$HOME/.ai-suite-backups"
    "AI quarantine|$HOME/.local/share/zdx/ai-trash"
  )
  local row="" label="" root_path="" size=""
  for row in "${roots[@]}"; do
    label="${row%%|*}"
    root_path="${row#*|}"
    if [[ -e "$root_path" || -L "$root_path" ]]; then
      size=$(_ai_du "$root_path") || true
      printf '  %-22s %s  %s\n' "$label" "$size" "${(V)root_path}"
    else
      printf '  %-22s %s\n' "$label" "(not found)"
    fi
  done
  _ai_dim "Each filesystem probe is capped at three seconds."
  } >&2
}

# --- Version Report ----------------------------------------------------------

# id|label|executable for every supported assistant, in the canonical order
# shared with ai-doctor and ai-update. The id is the stable JSON key;
# Antigravity and Cursor ship executables named differently from the product.
typeset -ga _AI_VERSION_TOOLS=(
  "claude|Claude Code|claude"
  "codex|Codex CLI|codex"
  "antigravity|Antigravity CLI|agy"
  "opencode|OpenCode|opencode"
  "cursor|Cursor Agent|cursor-agent"
  "copilot|GitHub Copilot|copilot"
  "amp|Amp CLI|amp"
  "hermes|Hermes Agent|hermes"
)

# Probe a CLI's version and binary path. Echoes "version|binary" on success.
# The return status preserves absent (1) versus present-but-unavailable (2).
_ai_probe_version() {
  local cmd="$1"
  local ver bin
  ver=$(_ai_probe_cli "$cmd") || return $?
  ver="${(V)ver}"
  ver="${ver//|/\\x7c}"
  if _ai_resolve_cli "$cmd"; then
    bin="$REPLY"
  else
    bin=""
  fi
  printf '%s|%s\n' "$ver" "$bin"
}

# Build the JSON object for one assistant. Every supported tool uses the same
# four shapes, documented in docs/ai-menu.md: installed with a version,
# installed with a failed probe, wrapper-only, or absent.
_ai_versions_json_entry() {
  local id="$1" label="$2" cmd="$3" probe="" ver="" bin=""
  local -i probe_rc=0
  probe=$(_ai_probe_version "$cmd")
  probe_rc=$?
  REPLY=""
  if (( probe_rc == 0 )); then
    ver="${probe%|*}"
    bin="${probe#*|}"
    REPLY=$(jq -cn \
      --arg label "$label" --arg ver "$ver" --arg bin "$bin" \
      '{label: $label, installed: true, version: $ver, binary: $bin}')
  elif (( probe_rc == 2 )) && _ai_resolve_cli "$cmd"; then
    bin="$REPLY"
    REPLY=$(jq -cn --arg label "$label" --arg bin "$bin" \
      '{label: $label, installed: true, version: "unavailable",
        binary: $bin, probeStatus: "failed"}')
  elif (( probe_rc == 2 )); then
    REPLY=$(jq -cn --arg label "$label" \
      '{label: $label, installed: false, available: true,
        state: "wrapper-only"}')
  else
    REPLY=$(jq -cn --arg label "$label" '{label: $label, installed: false}')
  fi
  [[ -n "$REPLY" ]]
}

_ai_versions_table_row() {
  local label="$1" cmd="$2" probe="" state=""
  local -i probe_rc=0
  probe=$(_ai_probe_version "$cmd")
  probe_rc=$?
  if (( probe_rc == 0 )); then
    state="${probe%|*}"
  elif (( probe_rc == 2 )) && _ai_resolve_cli "$cmd"; then
    state="(version unavailable)"
  elif (( probe_rc == 2 )); then
    state="(shell wrapper only)"
  else
    state="(not installed)"
  fi
  printf "  %-18s %s\n" "$label" "$state"
}

ai-versions() {
  emulate -L zsh
  _ai_parse_flags versions "ai-versions" "$@" || return $?
  if (( _AI_HELP_ONLY )); then
    return 0
  fi

  local entry="" id="" rest="" label="" cmd=""
  if (( _AI_JSON )); then
    command -v jq >/dev/null 2>&1 || {
      _ai_error "jq is required for --json output."
      return 1
    }

    # Build the payload incrementally so every object passes through jq.
    local payload='{}' tool_json="" node_ver="" npm_ver=""
    for entry in "${_AI_VERSION_TOOLS[@]}"; do
      id="${entry%%|*}"
      rest="${entry#*|}"
      label="${rest%%|*}"
      cmd="${rest#*|}"
      _ai_versions_json_entry "$id" "$label" "$cmd" || {
        _ai_error "Could not build the version record for $label."
        return 1
      }
      tool_json="$REPLY"
      payload=$(jq -c --arg id "$id" --argjson tool "$tool_json" \
        '. + {($id): $tool}' <<< "$payload") || return 1
    done

    node_ver=$(_ai_probe_cli node 2>/dev/null) || node_ver=""
    npm_ver=$(_ai_probe_cli npm 2>/dev/null) || npm_ver=""
    payload=$(jq -c --arg node "$node_ver" --arg npm "$npm_ver" \
      '. + {runtime: {node: $node, npm: $npm}}' <<< "$payload") || return 1

    jq '.' <<< "$payload"
    return 0
  fi

  {
  _ai_header "AI CLI Versions"
  printf "  %-18s %s\n" "Tool" "Version"
  printf "  %-18s %s\n" "────────────────" "──────────────────────"
  for entry in "${_AI_VERSION_TOOLS[@]}"; do
    rest="${entry#*|}"
    label="${rest%%|*}"
    cmd="${rest#*|}"
    _ai_versions_table_row "$label" "$cmd"
  done

  print -r -- ""
  printf "  %-18s %s\n" "── Runtime ──" ""
  local runtime_version=""
  if command -v node >/dev/null 2>&1; then
    runtime_version=$(_ai_probe_cli node 2>/dev/null) \
      || runtime_version="unavailable"
    printf "  %-18s %s\n" "Node.js" "${(V)runtime_version}"
  else
    printf "  %-18s %s\n" "Node.js" "(not installed)"
  fi
  if command -v npm >/dev/null 2>&1; then
    runtime_version=$(_ai_probe_cli npm 2>/dev/null) \
      || runtime_version="unavailable"
    printf "  %-18s %s\n" "npm" "${(V)runtime_version}"
  fi
  } >&2
}

typeset -g _AI_DISK_SOURCED=1
