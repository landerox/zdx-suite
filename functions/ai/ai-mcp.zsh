#!/usr/bin/env zsh
# =============================================================================
# AI MCP: passive Model Context Protocol declaration audits
# =============================================================================
#
# Loaded by ai-menu.zsh after ai-common.zsh.
# Safe to re-source; defines functions only.
#
# Configured commands, arguments, environment variables, URLs and headers are
# untrusted data. This module never executes or contacts an MCP server.
#

if [[ -n "${_AI_MCP_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset -gi _AI_MCP_MAX_CONFIG_BYTES=2097152
typeset -gi _AI_MCP_MAX_OUTPUT_BYTES=1048576
typeset -gi _AI_MCP_MAX_SERVERS=512
typeset -gi _AI_MCP_HELP=0

# Claude keeps user and local MCP declarations in one JSON file. Honor the
# vendor override directory but accept only a canonical regular file.
_ai_claude_config_file() {
  local cfg_dir="${CLAUDE_CONFIG_DIR:-$HOME}"
  local cfg="$cfg_dir/.claude.json"
  [[ "$cfg" == "${cfg:A}" && -f "$cfg" && ! -L "$cfg" ]] || return 1
  print -r -- "$cfg"
}

_ai_mcp_usage() {
  local command_name="$1"
  print -u2 -r -- "Usage: $command_name"
  if [[ "$command_name" == ai-mcp-update ]]; then
    print -u2 -r -- \
      "       ai-mcp-update [--dry-run] [--yes]"
    print -u2 -r -- ""
    print -u2 -r -- \
      "Compatibility audit only: no config, package, URL, or server is changed."
  fi
  print -u2 -r -- ""
  print -u2 -r -- "  --help, -h      Show this help"
}

_ai_mcp_parse_flags() {
  local command_name="$1" allow_compat_flags="$2"
  shift 2
  _AI_DRY_RUN=0
  _AI_YES=0
  _AI_MCP_HELP=0

  while (( $# )); do
    case "$1" in
      --dry-run)
        (( allow_compat_flags )) || {
          _ai_error "Option not supported by $command_name: $1"
          return 2
        }
        _AI_DRY_RUN=1
        ;;
      --yes|-y)
        (( allow_compat_flags )) || {
          _ai_error "Option not supported by $command_name: $1"
          return 2
        }
        _AI_YES=1
        ;;
      --help|-h)
        _AI_MCP_HELP=1
        ;;
      --)
        shift
        (( $# == 0 )) || {
          _ai_error "Unexpected argument: $1"
          return 2
        }
        break
        ;;
      -*)
        _ai_error "Unknown option: $1"
        return 2
        ;;
      *)
        _ai_error "Unexpected argument: $1"
        return 2
        ;;
    esac
    shift
  done
  (( _AI_MCP_HELP )) && _ai_mcp_usage "$command_name"
  return 0
}

_ai_mcp_config_fingerprint() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local cfg="${1:-}"
  [[ -n "$cfg" && "$cfg" == /* && "$cfg" == "${cfg:A}" \
    && "$cfg" != *'|'* && "$cfg" != *[[:cntrl:]]* \
    && -f "$cfg" && ! -L "$cfg" && -O "$cfg" ]] || return 1

  local -A before=() after=()
  zstat -LH before -- "$cfg" 2>/dev/null || return 1
  (( (before[mode] & 8#170000) == 8#100000 \
    && before[uid] == EUID && before[nlink] == 1 \
    && (before[mode] & 8#022) == 0 \
    && before[size] >= 0 && before[size] <= _AI_MCP_MAX_CONFIG_BYTES )) \
    || return 1

  local checksum=""
  checksum=$(command cksum < "$cfg" 2>/dev/null) || return 1
  zstat -LH after -- "$cfg" 2>/dev/null || return 1
  local before_identity="${before[device]}:${before[inode]}:${before[mode]}:"\
"${before[uid]}:${before[nlink]}:${before[size]}:${before[mtime]}:"\
"${before[ctime]}"
  local after_identity="${after[device]}:${after[inode]}:${after[mode]}:"\
"${after[uid]}:${after[nlink]}:${after[size]}:${after[mtime]}:"\
"${after[ctime]}"
  [[ "$before_identity" == "$after_identity" ]] || return 1
  local -a fields=(${=checksum})
  (( ${#fields[@]} == 2 )) \
    && [[ "$fields[1]" == <-> && "$fields[2]" == <-> ]] || return 1
  print -r -- "$after_identity:${fields[1]}:${fields[2]}"
}

_ai_mcp_timeout_bin() {
  if command -v timeout >/dev/null 2>&1; then
    command -v timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    command -v gtimeout
  else
    return 1
  fi
}

_ai_mcp_records() {
  emulate -L zsh
  local cfg="$1" layout="$2" project_key="${3:-}" timeout_bin="" output=""
  timeout_bin=$(_ai_mcp_timeout_bin) || return 1
  case "$layout" in
    root|local) ;;
    *) return 1 ;;
  esac
  [[ -n "$project_key" ]] || project_key="."

  output=$(
    command "$timeout_bin" --foreground --kill-after=1s 5s \
      jq -r --arg layout "$layout" --arg project "$project_key" \
      --argjson max "$_AI_MCP_MAX_SERVERS" '
        (if $layout == "local"
          then (.projects[$project].mcpServers // {})
          else (.mcpServers // {})
        end) as $servers
        | if ($servers | type) != "object" or ($servers | length) > $max
          then error("invalid MCP server map")
          else $servers
          end
        | to_entries[]
        | .key as $name
        | .value as $server
        | if (($name | type) != "string")
            or ($name | utf8bytelength) > 256
            or ($name | contains("|"))
            or ($name | test("[\u0000-\u001f\u007f]"))
          then error("invalid MCP server name")
          elif ($server | type) != "object"
          then [$name, "invalid", ""]
          elif (($server.command? | type) == "string")
            and (($server.command | utf8bytelength) > 0)
            and (($server.command | utf8bytelength) <= 4096)
            and (($server.command | contains("|")) | not)
            and (($server.command | test("[\u0000-\u001f\u007f]")) | not)
          then [$name, "local", $server.command]
          elif (($server.url? | type) == "string")
            and (($server.url | utf8bytelength) > 0)
            and (($server.url | utf8bytelength) <= 8192)
            and (($server.type? // "") | IN("http", "sse", "ws", "streamable-http"))
          then [$name, "remote", $server.type]
          elif (($server.serverUrl? | type) == "string")
            and (($server.serverUrl | utf8bytelength) > 0)
            and (($server.serverUrl | utf8bytelength) <= 8192)
          then [$name, "remote", "serverUrl"]
          else [$name, "invalid", ""]
          end
        | @tsv
      ' "$cfg" 2>/dev/null
  ) || return 1
  (( ${#output} <= _AI_MCP_MAX_OUTPUT_BYTES )) || return 1
  print -r -- "$output"
}

_ai_mcp_safe_command_label() {
  local server_command="${1:-}"
  if [[ "$server_command" == */* ]]; then
    [[ "$server_command" == /* && "$server_command" != *'/../'* \
      && "$server_command" != */.. ]] || return 1
    print -r -- "${server_command:t}"
  else
    [[ "$server_command" =~ '^[A-Za-z0-9._+-]+$' ]] || return 1
    print -r -- "$server_command"
  fi
}

_ai_mcp_command_available() {
  local server_command="${1:-}"
  if [[ "$server_command" == /* ]]; then
    [[ -f "$server_command" && -x "$server_command" && ! -L "$server_command" ]]
  else
    command -v -- "$server_command" >/dev/null 2>&1
  fi
}

_ai_mcp_audit_config() {
  emulate -L zsh
  local label="$1" cfg="$2" layout="$3" audit_mode="$4"
  local project_key="${5:-}" fingerprint="" records=""
  fingerprint=$(_ai_mcp_config_fingerprint "$cfg") || {
    _ai_error "$label config is unsafe, linked, oversized, or unstable."
    return 1
  }
  records=$(_ai_mcp_records "$cfg" "$layout" "$project_key") || {
    _ai_error "$label config contains invalid or excessive MCP metadata."
    return 1
  }

  _ai_info "  $label: ${(V)cfg}"
  if [[ -z "$records" ]]; then
    _ai_dim "    No MCP servers declared."
  else
    local name="" kind="" detail="" extra="" command_label=""
    local -i failures=0 count=0
    while IFS=$'\t' read -r name kind detail extra; do
      (( count += 1 ))
      [[ -z "$extra" && "$count" -le _AI_MCP_MAX_SERVERS ]] || {
        (( failures += 1 ))
        continue
      }
      case "$kind" in
        local)
          command_label=$(_ai_mcp_safe_command_label "$detail") || {
            _ai_error "    ${(q)name}: invalid local command metadata"
            (( failures += 1 ))
            continue
          }
          if [[ "$audit_mode" == doctor ]]; then
            if _ai_mcp_command_available "$detail"; then
              _ai_success \
                "    ${(q)name}: ${(q)command_label} available (not executed)"
            else
              _ai_error "    ${(q)name}: ${(q)command_label} not found"
              (( failures += 1 ))
            fi
          else
            _ai_info "    ${(q)name}: local ${(q)command_label} (not executed)"
          fi
          ;;
        remote)
          _ai_info "    ${(q)name}: remote ${(q)detail} declared (not contacted)"
          ;;
        *)
          _ai_error "    ${(q)name}: invalid MCP transport declaration"
          (( failures += 1 ))
          ;;
      esac
    done <<< "$records"
    (( failures == 0 )) || return 1
  fi

  local current=""
  current=$(_ai_mcp_config_fingerprint "$cfg") \
    && [[ "$current" == "$fingerprint" ]] || {
    _ai_error "$label config changed while it was audited."
    return 1
  }
  return 0
}

_ai_mcp_claude_sources() {
  reply=()
  local cfg="" project_cfg="${PWD:A}/.mcp.json"
  if cfg=$(_ai_claude_config_file 2>/dev/null); then
    reply+=("User|$cfg|root")
    reply+=("Local|$cfg|local")
  fi
  if [[ "$PWD" == "${PWD:A}" && -f "$project_cfg" && ! -L "$project_cfg" ]]; then
    reply+=("Shared project|$project_cfg|root")
  fi
}

_ai_mcp_run_audit() {
  emulate -L zsh
  local audit_mode="${1:-list}"
  local -i failures=0 found=0
  _ai_info "── Claude Code ──"
  _ai_mcp_claude_sources
  local record="" label="" rest="" cfg="" layout=""
  for record in "${reply[@]}"; do
    label="${record%%|*}"
    rest="${record#*|}"
    cfg="${rest%%|*}"
    layout="${rest#*|}"
    (( found += 1 ))
    _ai_mcp_audit_config "$label" "$cfg" "$layout" "$audit_mode" "$PWD" \
      || (( failures += 1 ))
  done
  (( found )) || _ai_dim "  No safe Claude MCP config file found."

  print -u2 -r -- ""
  _ai_info "── Antigravity CLI ──"
  local -a antigravity_labels=(
    "User"
    "Workspace"
  )
  local -a antigravity_configs=(
    "${HOME:A}/.gemini/config/mcp_config.json"
    "${PWD:A}/.agents/mcp_config.json"
  )
  local source_label="" source_cfg=""
  local -i antigravity_found=0 source_index=0
  for (( source_index = 1;
    source_index <= ${#antigravity_configs[@]};
    source_index++ )); do
    source_label="${antigravity_labels[source_index]}"
    source_cfg="${antigravity_configs[source_index]}"
    if [[ -f "$source_cfg" && ! -L "$source_cfg" ]]; then
      (( antigravity_found += 1 ))
      _ai_mcp_audit_config \
        "$source_label" "$source_cfg" root "$audit_mode" \
        || (( failures += 1 ))
    fi
  done
  (( antigravity_found )) \
    || _ai_dim "  No safe Antigravity MCP config file found."

  print -u2 -r -- ""
  _ai_info "── Cursor Agent ──"
  local cursor_cfg="${HOME:A}/.cursor/mcp.json"
  if [[ -f "$cursor_cfg" && ! -L "$cursor_cfg" ]]; then
    _ai_mcp_audit_config "User" "$cursor_cfg" root "$audit_mode" \
      || (( failures += 1 ))
  else
    _ai_dim "  No ~/.cursor/mcp.json found."
  fi

  print -u2 -r -- ""
  _ai_info "── OpenCode ──"
  _ai_dim "  No passive, documented OpenCode config adapter is enabled."
  (( failures == 0 ))
}

ai-mcp-list() {
  emulate -L zsh
  _ai_mcp_parse_flags "ai-mcp-list" 0 "$@" || return $?
  (( _AI_MCP_HELP )) && return 0
  command -v jq >/dev/null 2>&1 || {
    _ai_error "jq is required for MCP declaration audits."
    return 1
  }
  _ai_header "MCP Declarations"
  _ai_mcp_run_audit list
}

ai-mcp-doctor() {
  emulate -L zsh
  _ai_mcp_parse_flags "ai-mcp-doctor" 0 "$@" || return $?
  (( _AI_MCP_HELP )) && return 0
  command -v jq >/dev/null 2>&1 || {
    _ai_error "jq is required for MCP declaration audits."
    return 1
  }
  _ai_header "MCP Passive Diagnostics"
  _ai_info "Local commands are resolved only; remote transports are not contacted."
  _ai_mcp_run_audit doctor
}

ai-mcp-update() {
  emulate -L zsh
  _ai_mcp_parse_flags "ai-mcp-update" 1 "$@" || return $?
  (( _AI_MCP_HELP )) && return 0
  command -v jq >/dev/null 2>&1 || {
    _ai_error "jq is required for MCP declaration audits."
    return 1
  }
  _ai_header "MCP Compatibility Audit"
  _ai_info "No package, cache, configuration, URL, or server will be changed."
  local -i audit_rc=0
  _ai_mcp_run_audit doctor || audit_rc=1
  (( _AI_DRY_RUN )) && _ai_info "--dry-run acknowledged; this command is always passive."
  (( _AI_YES )) && _ai_info "--yes acknowledged; this command is always passive."
  return $audit_rc
}

typeset -g _AI_MCP_SOURCED=1
