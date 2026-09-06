#!/usr/bin/env zsh
# =============================================================================
# AI Doctor: bounded diagnostics for assistants, runtimes, and API keys
# =============================================================================
#
# Loaded by ai-menu.zsh after ai-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_AI_DOCTOR_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset -gi _AI_DOCTOR_ISSUES=0

_ai_doctor_is_wsl() {
  [[ -r /proc/version ]] && command grep -qi "microsoft" /proc/version
}

# Report one diagnostic line and mirror it into the optional Markdown report.
_ai_doctor_note() {
  local level="$1" message="$2"
  case "$level" in
    ok)   _ai_success "$message" ;;
    warn) _ai_warn "$message" ;;
    fail) _ai_error "$message" ;;
    *)    _ai_info "$message" ;;
  esac
  (( _AI_REPORT )) && _ai_report_status "$level" "$message"
  return 0
}

# Print the section heading for one assistant, run its bounded version probe,
# and report the shared installed/absent/failed outcome. Returns 0 when the
# probe succeeded, 1 when no executable is installed, and 2 when a wrapper or
# installed executable failed the bounded probe (counted as an issue). REPLY
# holds the resolved launch path when one exists.
_ai_doctor_probe() {
  local title="$1" cli="$2" version="" binary=""
  local -i probe_rc=0
  print -u2 -r -- "── $title ──"
  (( _AI_REPORT )) && _ai_report_section "$title"
  version=$(_ai_probe_cli "$cli")
  probe_rc=$?
  REPLY=""
  case "$probe_rc" in
    0)
      _ai_doctor_note ok "Installed: $version"
      ;;
    2)
      _ai_doctor_note fail "Available, but the bounded version probe failed."
      (( _AI_DOCTOR_ISSUES += 1 ))
      ;;
    *)
      # Absence is advisory on the terminal and informational in the report.
      _ai_warn "Not installed"
      (( _AI_REPORT )) && _ai_report_status info "Not installed"
      return 1
      ;;
  esac
  if _ai_resolve_cli "$cli"; then
    binary="$REPLY"
    _ai_doctor_note info "Binary: $binary"
  fi
  REPLY="$binary"
  return $probe_rc
}

_ai_doctor_size_note() {
  local label="$1" target="$2" size=""
  [[ -d "$target" ]] || return 0
  size=$(_ai_du "$target") || true
  _ai_doctor_note info "$label: $size"
}

_ai_doctor_runtime() {
  local label="$1" cli="$2" absent_level="$3" version=""
  if ! command -v -- "$cli" >/dev/null 2>&1; then
    [[ -z "$absent_level" ]] && return 0
    _ai_doctor_note "$absent_level" \
      "$label not found (some assistant installations require it)"
    (( _AI_DOCTOR_ISSUES += 1 ))
    return 0
  fi
  if version=$(_ai_probe_cli "$cli"); then
    _ai_doctor_note ok "$label: $version"
  else
    _ai_doctor_note fail \
      "$label is installed, but the bounded version probe failed."
    (( _AI_DOCTOR_ISSUES += 1 ))
  fi
}

ai-doctor() {
  emulate -L zsh
  _ai_parse_flags doctor "ai-doctor" "$@" || return $?
  if (( _AI_HELP_ONLY )); then
    return 0
  fi

  local home_root="${HOME:A}"
  local opencode_config="" opencode_data="" entry="" var_name="" key_label=""
  local -i report_rc=0
  _AI_DOCTOR_ISSUES=0
  {
  _ai_header "AI CLI Diagnostics"
  (( _AI_REPORT )) && _ai_report_init "AI CLI Diagnostics Report"

  if _ai_doctor_probe "Claude Code" claude; then
    _ai_info "Config: ~/.claude/"
    [[ -f "$home_root/.claude.json" ]] && _ai_info "Prefs: ~/.claude.json"
    _ai_dim "Native diagnostics: claude doctor (interactive)"
    if [[ -d "$home_root/.claude/projects" ]]; then
      _ai_doctor_size_note "Durable session data (preserved)" \
        "$home_root/.claude/projects"
    fi
  fi
  print -u2 -r -- ""

  if _ai_doctor_probe "OpenAI Codex" codex; then
    _ai_info "Config: ~/.codex/config.toml"
    _ai_doctor_size_note "Logs" "$home_root/.codex/log"
  fi
  print -u2 -r -- ""

  if _ai_doctor_probe "Antigravity CLI" agy; then
    _ai_info "Config: ~/.gemini/antigravity-cli/settings.json"
    [[ -d "$home_root/.gemini/antigravity-cli/plugins" ]] \
      && _ai_doctor_note info "Plugins directory present (contents not enumerated)"
    [[ -d "$home_root/.gemini/antigravity-cli/skills" ]] \
      && _ai_doctor_note info "Skills directory present (contents not enumerated)"
  fi
  print -u2 -r -- ""

  if _ai_doctor_probe "OpenCode" opencode; then
    opencode_config=$(_ai_opencode_config_dir)
    opencode_data=$(_ai_opencode_data_dir)
    _ai_info "Config: $opencode_config"
    _ai_info "Data:   $opencode_data"
    _ai_doctor_size_note "Logs" "$opencode_data/logs"
  fi
  print -u2 -r -- ""

  if _ai_doctor_probe "Cursor Agent" cursor-agent; then
    _ai_info "Install base: $home_root/.local/share/cursor-agent"
    _ai_info "Update: ai-update-cursor (delegates to cursor-agent update)"
    _ai_dim "Installed Cursor versions are preserved; active-version resolution is vendor-owned."
  elif (( $? == 1 )); then
    _ai_info "Review installation instructions: https://cursor.com/cli"
  fi
  print -u2 -r -- ""

  if _ai_doctor_probe "GitHub Copilot CLI" copilot; then
    _ai_info "Config: $home_root/.copilot"
  elif (( $? == 1 )); then
    _ai_info "Install with a reviewed package manager: npm install -g @github/copilot"
  fi
  print -u2 -r -- ""

  if _ai_doctor_probe "Amp CLI" amp; then
    _ai_info "Data:   $home_root/.local/share/amp"
    [[ -d "$home_root/.amp" ]] && _ai_info "Cache:  $home_root/.amp"
    _ai_doctor_size_note "Threads" "$home_root/.local/share/amp/threads"
  elif (( $? == 1 )); then
    _ai_info "Install with a reviewed package manager: npm install -g @sourcegraph/amp"
  fi
  print -u2 -r -- ""

  if _ai_doctor_probe "Hermes Agent" hermes; then
    _ai_info "Update: ai-update-hermes (delegates to hermes update --backup --yes)"
  fi
  print -u2 -r -- ""

  (( _AI_REPORT )) && _ai_report_section "Environment"
  _ai_doctor_is_wsl && _ai_doctor_note info "Environment: WSL detected"
  _ai_doctor_runtime "Node.js" node warn
  _ai_doctor_runtime "npm" npm ""

  # API key presence only; values are never read into output.
  print -u2 -r -- ""
  print -u2 -r -- "── API Keys ──"
  (( _AI_REPORT )) && _ai_report_section "API Keys"
  local -a key_checks=(
    "ANTHROPIC_API_KEY|Claude"
    "OPENAI_API_KEY|Codex / OpenCode"
    "GITHUB_TOKEN|GitHub Copilot (alt GH_TOKEN)"
    "GH_TOKEN|GitHub Copilot"
  )
  for entry in "${key_checks[@]}"; do
    var_name="${entry%%|*}"
    key_label="${entry#*|}"
    if [[ -n "${(P)var_name:-}" ]]; then
      _ai_doctor_note ok "$key_label: $var_name is set"
    else
      _ai_dim "$key_label: $var_name not set"
      (( _AI_REPORT )) && _ai_report_status info "$var_name not set"
    fi
  done

  print -u2 -r -- ""
  if (( _AI_DOCTOR_ISSUES == 0 )); then
    _ai_doctor_note ok "Diagnostics: all checks passed."
  else
    _ai_doctor_note warn "Diagnostics: $_AI_DOCTOR_ISSUES issue(s) found."
  fi

  if (( _AI_REPORT )); then
    _ai_report_save "ai-doctor.md" || report_rc=1
  fi
  } >&2
  return $report_rc
}

typeset -g _AI_DOCTOR_SOURCED=1
