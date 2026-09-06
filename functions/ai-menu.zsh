#!/usr/bin/env zsh
# =============================================================================
# AI Suite: public loader and command router
# =============================================================================
#
# Public loader and command router for local AI assistant maintenance.
# Usage: ai-menu [-m|--multi | subcommand [arguments...]]
#

if [[ -n "${_AI_MENU_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset _ai_menu_loader_dir="${${(%):-%x}:A:h}"

_ai_menu_source_module() {
  local module_name="$1"
  local module_file="$_ai_menu_loader_dir/ai/$module_name"
  [[ "$module_name" == "ai-common.zsh" ]] \
    && module_file="$_ai_menu_loader_dir/ai-common.zsh"

  [[ "$module_file" == "${module_file:A}" \
    && -f "$module_file" && ! -L "$module_file" && -r "$module_file" ]] \
    || return 1
  builtin source "$module_file"
}

typeset -i _ai_menu_load_rc=0
_ai_menu_source_module "ai-common.zsh" || _ai_menu_load_rc=$?
if (( _ai_menu_load_rc != 0 )); then
  print -u2 -r -- "ai-menu.zsh: failed to load ai-common.zsh"
  {
    return $_ai_menu_load_rc 2>/dev/null || exit $_ai_menu_load_rc
  } always {
    unset -f _ai_menu_source_module
    unset _ai_menu_load_rc _ai_menu_loader_dir
  }
fi

typeset _ai_menu_module=""
for _ai_menu_module in \
  ai-clean.zsh \
  ai-init.zsh \
  ai-sweep.zsh \
  ai-update.zsh \
  ai-mcp.zsh \
  ai-config.zsh \
  ai-log.zsh \
  ai-doctor.zsh \
  ai-disk.zsh; do
  _ai_menu_load_rc=0
  _ai_menu_source_module "$_ai_menu_module" || _ai_menu_load_rc=$?
  if (( _ai_menu_load_rc != 0 )); then
    print -u2 -r -- \
      "ai-menu.zsh: failed to load $_ai_menu_module"
    {
      return $_ai_menu_load_rc 2>/dev/null || exit $_ai_menu_load_rc
    } always {
      unset -f _ai_menu_source_module
      unset _ai_menu_load_rc _ai_menu_loader_dir _ai_menu_module
    }
  fi
done

unset -f _ai_menu_source_module
unset _ai_menu_load_rc _ai_menu_loader_dir _ai_menu_module

_ai_usage() {
  cat >&2 <<'EOF'
Usage:
  ai-menu
  ai-menu -m|--multi
  ai-menu <subcommand> [arguments...]
  ai-menu --help

Recoverable cleanup:
  global-clean-ai          Quarantine all eligible assistant cache targets.
  global-clean-claude      Quarantine bounded Claude Code cache targets.
  global-clean-codex       Quarantine bounded Codex cache targets.
  global-clean-antigravity Quarantine bounded Antigravity log targets.
  global-clean-opencode    Quarantine bounded OpenCode log targets.
  global-clean-copilot     Quarantine bounded Copilot log targets.
  global-clean-cursor      Report eligible Cursor targets (currently none).
  global-clean-amp         Report eligible Amp targets (currently none).
  project-sweep-ai         Quarantine known project AI cache directories.

Configuration:
  ai-init-agents           Create and link project instruction files.
  ai-config-backup         Create a private configuration snapshot.
  ai-config-restore        Restore one validated snapshot; pick when no token.

Updates:
  ai-update                Update every installed supported assistant.
  ai-update-claude         Update Claude Code to the latest version.
  ai-update-codex          Update Codex CLI to the latest version.
  ai-update-antigravity    Update Antigravity CLI to the latest version.
  ai-update-opencode       Update OpenCode to the latest version.
  ai-update-cursor         Update Cursor Agent to the latest version.
  ai-update-copilot        Update Copilot CLI to the latest version.
  ai-update-amp            Update Amp CLI to the latest version.
  ai-update-hermes         Update Hermes Agent with an upstream backup.
  ai-mcp-update            Run the passive MCP compatibility audit.

Inspection:
  ai-mcp-list              List configured MCP servers.
  ai-mcp-doctor            Resolve local MCP command availability only.
  ai-doctor                Inspect assistant health and configuration.
  ai-disk-usage            Show assistant disk usage.
  ai-versions              Show installed versions; supports --json.
  ai-log-tail              Print a bounded recent-log excerpt.

Use '<subcommand> --help' for common safety flags. Interactive --multi is
limited to read-only inspection commands.
EOF
}

_ai_build_menu_rows() {
  reply=()
  local row=""

  row=$(_ai_menu_section "Inspection" \
    "Read-only health, storage, version, log, and MCP information.") || return
  reply+=("$row")
  row=$(_ai_menu_entry "Run Diagnostics" "ai-doctor" \
    "Inspect installed assistants, configuration paths, and runtime health.") || return
  reply+=("$row")
  row=$(_ai_menu_entry "Show Disk Usage" "ai-disk-usage" \
    "Show storage used by supported local assistants.") || return
  reply+=("$row")
  row=$(_ai_menu_entry "Show Versions" "ai-versions" \
    "Print installed assistant and runtime versions.") || return
  reply+=("$row")
  row=$(_ai_menu_entry "Read Recent Logs" "ai-log-tail" \
    "Show excerpts from the latest supported assistant logs.") || return
  reply+=("$row")
  row=$(_ai_menu_entry "List MCP Servers" "ai-mcp-list" \
    "List configured MCP servers without changing their configuration.") || return
  reply+=("$row")
  row=$(_ai_menu_entry "Diagnose MCP Servers" "ai-mcp-doctor" \
    "Check MCP configuration and local command availability without starting servers.") || return
  reply+=("$row")

  row=$(_ai_menu_entry "Inspect MCP Compatibility" "ai-mcp-update" \
    "Check MCP declarations and installed command compatibility; servers are not updated.") || return
  reply+=("$row")

  row=$(_ai_menu_section "Configuration" \
    "Create instruction links and manage private configuration snapshots.") || return
  reply+=("$row")
  row=$(_ai_menu_entry "Initialize Instructions" "ai-init-agents" \
    "Create AGENTS.md and reviewed assistant instruction links.") || return
  reply+=("$row")
  row=$(_ai_menu_entry "Back Up Configurations" "ai-config-backup" \
    "Back up supported configuration files privately; snapshots may contain credentials.") || return
  reply+=("$row")
  row=$(_ai_menu_entry "Restore Configurations" "ai-config-restore" \
    "Choose a configuration backup to restore, keeping copies of replaced files.") || return
  reply+=("$row")

  row=$(_ai_menu_section "Updates" \
    "Review and run official self-updaters for installed assistants.") || return
  reply+=("$row")
  local update_command update_label
  for update_command update_label in \
    ai-update "Update All Assistants" \
    ai-update-claude "Update Claude Code" \
    ai-update-codex "Update Codex" \
    ai-update-antigravity "Update Antigravity" \
    ai-update-opencode "Update OpenCode" \
    ai-update-cursor "Update Cursor Agent" \
    ai-update-copilot "Update Copilot" \
    ai-update-amp "Update Amp" \
    ai-update-hermes "Update Hermes"; do
    local update_description="Preview, confirm, and run the installed CLI self-updater."
    row=$(_ai_menu_entry "$update_label" "$update_command" \
      "$update_description") || return
    reply+=("$row")
  done

  row=$(_ai_menu_section "Recoverable Cleanup" \
    "Review cache and artifact moves to a private recovery directory.") || return
  reply+=("$row")
  local clean_command clean_label
  for clean_command clean_label in \
    global-clean-ai "Clean All Assistant Caches" \
    global-clean-claude "Clean Claude Cache" \
    global-clean-codex "Clean Codex Cache" \
    global-clean-antigravity "Clean Antigravity Cache" \
    global-clean-opencode "Clean OpenCode Cache" \
    global-clean-copilot "Clean Copilot Cache" \
    global-clean-cursor "Show Cursor Cleanup Limits" \
    global-clean-amp "Show Amp Cleanup Limits" \
    project-sweep-ai "Clean Project AI Artifacts"; do
    local clean_description="Review and move eligible cache data to a private recovery directory."
    case "$clean_command" in
      project-sweep-ai)
        clean_description="Review and move generated AI artifacts from selected project directories to recovery."
        ;;
      global-clean-cursor)
        clean_description="Show why Cursor data is preserved; this command does not remove data."
        ;;
      global-clean-amp)
        clean_description="Show why Amp recovery data is preserved; this command does not remove data."
        ;;
    esac
    row=$(_ai_menu_entry "$clean_label" "$clean_command" \
      "$clean_description") || return
    reply+=("$row")
  done
}

_ai_interactive() {
  local multi="${1:-no}"
  command -v fzf &>/dev/null || {
    _ai_error "fzf is required for the interactive AI menu."
    return 1
  }

  _ai_build_menu_rows || return $?
  local -a rows=("${reply[@]}")
  if [[ "$multi" == "yes" ]]; then
    local -a read_only_rows=()
    local row command_name
    for row in "${rows[@]}"; do
      command_name="${${row#*|}%%|*}"
      _ai_multi_safe_command "$command_name" && read_only_rows+=("$row")
    done
    rows=("${read_only_rows[@]}")
  fi

  local header='Local AI assistants'\
$'\n''Type to filter | Enter run | Esc cancel | Ctrl-/ details'
  [[ "$multi" == "yes" ]] \
    && header+=$'\n''Tab mark | Read-only tasks only'
  local -a fzf_options=(
    --prompt='ai > '
    --header="$header"
    --preview='case {2} in :) printf "%s\n" {3} ;; *) printf "Command: %s\n\n%s\n" {2} {3} ;; esac'
    --preview-window='down:4:wrap'
    --bind='ctrl-/:toggle-preview'
  )
  [[ "$multi" == "yes" ]] && fzf_options+=(--multi)

  local -i fzf_rc=0
  _ai_fzf_capture "${fzf_options[@]}" \
    < <(print -rl -- "${rows[@]}") || fzf_rc=$?
  local selection="$REPLY"
  if (( fzf_rc != 0 )); then
    _ai_fzf_cancelled "$fzf_rc" && return 0
    _ai_error "Unable to open the AI menu (status $fzf_rc)."
    return 1
  fi
  [[ -n "$selection" ]] || return 0

  local -a selected_rows=("${(@f)selection}")
  [[ "$multi" == "yes" || ${#selected_rows[@]} == 1 ]] || {
    _ai_error "The single-select AI menu returned multiple rows."
    return 1
  }

  local selected_row command_name snapshot_row
  local -i failures=0
  for selected_row in "${selected_rows[@]}"; do
    local -i snapshot_match=0
    for snapshot_row in "${rows[@]}"; do
      if [[ "$snapshot_row" == "$selected_row" ]]; then
        snapshot_match=1
        break
      fi
    done
    (( snapshot_match )) || {
      _ai_error "The selected AI action was not in the menu snapshot."
      return 1
    }
    command_name="${${selected_row#*|}%%|*}"
    [[ "$command_name" == ":" ]] && continue
    if [[ "$multi" == "yes" ]] && ! _ai_multi_safe_command "$command_name"; then
      _ai_error "The selected command is not eligible for multi-select."
      (( failures += 1 ))
      continue
    fi
    local -i command_rc=0
    _ai_timed "ai:$command_name" _ai_dispatch "$command_name" \
      || command_rc=$?
    (( command_rc == 130 || command_rc == 143 )) && return $command_rc
    (( command_rc == 0 )) || (( failures += 1 ))
  done
  (( failures == 0 )) || return 1
}

ai-menu() {
  emulate -L zsh
  case "${1:-}" in
    "")
      (( $# == 0 )) || {
        _ai_error "An empty command name is not valid."
        return 2
      }
      _ai_interactive no
      ;;
    -m|--multi)
      (( $# == 1 )) || {
        _ai_error "--multi accepts no additional arguments."
        return 2
      }
      _ai_interactive yes
      ;;
    -h|--help)
      (( $# == 1 )) || {
        _ai_error "--help accepts no additional arguments."
        return 2
      }
      _ai_usage
      ;;
    -*)
      _ai_error "Unknown option: $1"
      return 2
      ;;
    *)
      local command_name="$1"
      shift
      _ai_timed "ai:$command_name" _ai_dispatch "$command_name" "$@"
      ;;
  esac
}

typeset -g _AI_MENU_SOURCED=1
