#!/usr/bin/env zsh
# =============================================================================
# System Suite: public loader and command router
# =============================================================================
#
# Public loader and command router for host maintenance workflows.
# Usage: sys-menu [subcommand]
#

if [[ -n "${_SYS_MENU_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset _sys_menu_loader_dir="${${(%):-%x}:A:h}"

_sys_menu_source_module() {
  local module_name="$1"
  local candidate
  local -a candidates=(
    "${_sys_menu_loader_dir}/${module_name}"
    "${_sys_menu_loader_dir}/sys/${module_name}"
  )

  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" && -r "$candidate" ]]; then
      source "$candidate"
      return $?
    fi
  done

  return 1
}

# --- Load common helpers first ----------------------------------------------

typeset -i _sys_menu_load_rc=0
_sys_menu_source_module "sys-common.zsh" || _sys_menu_load_rc=$?
if (( _sys_menu_load_rc != 0 )); then
  print -u2 -r -- "sys-menu.zsh: failed to load sys-common.zsh"
  {
    return $_sys_menu_load_rc 2>/dev/null || exit $_sys_menu_load_rc
  } always {
    unset -f _sys_menu_source_module
    unset _sys_menu_load_rc _sys_menu_loader_dir
  }
fi

# --- Load capability adapters and feature modules ---------------------------

typeset _sys_menu_module
for _sys_menu_module in \
  sys-capabilities.zsh \
  adapters/sys-linux.zsh \
  adapters/sys-wsl.zsh \
  adapters/sys-macos.zsh \
  sys-update.zsh \
  sys-clean.zsh \
  sys-diag.zsh \
  sys-shell-diag.zsh \
  sys-dots.zsh \
  sys-fonts.zsh \
  sys-telemetry.zsh \
  sys-plugins.zsh \
  sys-services.zsh \
  sys-processes.zsh \
  sys-ports.zsh; do
  _sys_menu_load_rc=0
  _sys_menu_source_module "$_sys_menu_module" || _sys_menu_load_rc=$?
  if (( _sys_menu_load_rc != 0 )); then
    print -u2 -r -- \
      "sys-menu.zsh: failed to load ${_sys_menu_module}"
    {
      return $_sys_menu_load_rc 2>/dev/null || exit $_sys_menu_load_rc
    } always {
      unset -f _sys_menu_source_module
      unset _sys_menu_load_rc _sys_menu_loader_dir _sys_menu_module
    }
  fi
done

unset -f _sys_menu_source_module
unset _sys_menu_load_rc _sys_menu_module _sys_menu_loader_dir

# =============================================================================
# SYSTEM MENU
# =============================================================================

_sys_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- "  sys-menu"
  print -u2 -r -- "  sys-menu <subcommand> [arguments...]"
  print -u2 -r -- "  sys-menu -h|--help"
  print -u2 -r -- ""
  print -u2 -r -- "Inspection:"
  print -u2 -r -- \
    "  sys-info, sys-health, sys-startup, sys-path, sys-aliases"
  print -u2 -r -- ""
  print -u2 -r -- "System updates:"
  print -u2 -r -- \
    "  update-system, update-apt, update-brew, update-snap"
  print -u2 -r -- ""
  print -u2 -r -- "Developer tools:"
  print -u2 -r -- \
    "  update-gcloud, update-awscli, update-node, update-rust,"
  print -u2 -r -- \
    "  update-uv-system, update-pipx, update-starship, update-fzf,"
  print -u2 -r -- \
    "  update-omz, update-zsh-plugins, update-hermes, update-repomix"
  print -u2 -r -- ""
  print -u2 -r -- "User environment:"
  print -u2 -r -- \
    "  sys-backup-dots, sys-fonts, sys-plugins"
  print -u2 -r -- ""
  print -u2 -r -- "Host control:"
  print -u2 -r -- \
    "  sys-services, sys-ports, sys-processes"
  print -u2 -r -- ""
  print -u2 -r -- "Destructive maintenance:"
  print -u2 -r -- \
    "  sys-restore-dots, sys-telemetry, clean-system,"
  print -u2 -r -- \
    "  clean-system-quick, clean-system-deep, clean-journal, clean-snaps"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Arguments after a subcommand are forwarded unchanged to that command."
  print -u2 -r -- \
    "Use '<subcommand> --help' for command-specific modes and safety flags."
  print -u2 -r -- \
    "Broad destructive workflows provide --dry-run and explicit confirmation."
  print -u2 -r -- \
    "update-system includes remote-code updates; use --safe-only to exclude them."
}

# stdout records: label|command|description
_sys_menu_rows_build() {
  _sys_menu_section \
    "Inspection" "Read-only host and shell diagnostics." || return $?
  _sys_menu_entry \
    "Show System Info" "sys-info" \
    "Inspect OS, kernel, memory, tools, packages, and WSL state." || return $?
  _sys_menu_entry \
    "Run Health Check" "sys-health" \
    "Check disk, memory, processes, and service health." \
    || return $?
  _sys_menu_entry \
    "Measure Startup Time" "sys-startup" \
    "Benchmark and profile interactive Zsh startup." || return $?
  _sys_menu_entry \
    "Inspect PATH Environment" "sys-path" \
    "Find duplicate, missing, and empty PATH entries without editing files." \
    || return $?
  _sys_menu_entry \
    "Browse Aliases and Functions" "sys-aliases" \
    "Browse alias and function names; definitions stay private." \
    || return $?

  _sys_menu_entry \
    "Browse Command History" "sys-telemetry" \
    "View command timing and outcomes, browse history, or confirm clearing the log." || return $?

  _sys_menu_section \
    "Services and Processes" "Inspect services and processes before changing their state." \
    || return $?
  _sys_menu_entry \
    "Manage Services" "sys-services" \
    "Inspect or control services through the systemd or launchd backend." \
    || return $?
  _sys_menu_entry \
    "Resolve Locked Ports" "sys-ports" \
    "Inspect listeners and confirm process termination when needed." || return $?
  _sys_menu_entry \
    "Manage Processes" "sys-processes" \
    "Inspect processes and confirm SIGTERM or SIGKILL actions." || return $?

  _sys_menu_section \
    "Shell Configuration" "Back up dotfiles, install fonts, and manage plugins." \
    || return $?
  _sys_menu_entry \
    "Back Up Dotfiles" "sys-backup-dots" \
    "Archive configured dotfiles and retain the newest backups." || return $?
  _sys_menu_entry \
    "Manage Nerd Fonts" "sys-fonts" \
    "List Nerd Fonts or review and install an available font family." \
    || return $?
  _sys_menu_entry \
    "Manage Custom Plugins" "sys-plugins" \
    "Manage custom ZDX plugins; installation and updates execute reviewed Git code." \
    || return $?

  _sys_menu_section \
    "System Updates" "Update installed packages and tools." || return $?
  _sys_menu_entry \
    "Update System and Tools" "update-system" \
    "Update installed packages and tools; --safe-only excludes remote-code updates." \
    || return $?
  _sys_menu_entry \
    "Update APT Packages" "update-apt" \
    "Refresh indexes, upgrade packages, and remove unused dependencies." \
    || return $?
  _sys_menu_entry \
    "Update Homebrew Packages" "update-brew" \
    "Refresh formulae, upgrade installed packages, and clean old versions." \
    || return $?
  _sys_menu_entry \
    "Update Snap Packages" "update-snap" \
    "Refresh installed snaps when the snapd runtime is available." || return $?

  _sys_menu_section \
    "Developer Tools" "SDK, runtime, shell, prompt, and CLI updates." \
    || return $?
  _sys_menu_entry \
    "Update Google Cloud SDK" "update-gcloud" \
    "Update installed gcloud components when not package-managed." || return $?
  _sys_menu_entry \
    "Update AWS CLI" "update-awscli" \
    "Update through the package manager, or show the official manual procedure." \
    || return $?
  _sys_menu_entry \
    "Update Node.js" "update-node" \
    "Install and activate the latest LTS, then set it as default through fnm or nvm." || return $?
  _sys_menu_entry \
    "Update Rust Toolchains" "update-rust" \
    "Update rustup and installed Rust toolchains." || return $?
  _sys_menu_entry \
    "Update uv" "update-uv-system" \
    "Update uv through Homebrew or its supported self-updater." || return $?
  _sys_menu_entry \
    "Update pipx Packages" "update-pipx" \
    "Upgrade every globally installed pipx package." || return $?
  _sys_menu_entry \
    "Update Starship" "update-starship" \
    "Update the Starship prompt using its detected installation method." \
    || return $?
  _sys_menu_entry \
    "Update fzf" "update-fzf" \
    "Update the fuzzy finder; Git-owned copies require explicit trust." \
    || return $?
  _sys_menu_entry \
    "Update Oh My Zsh" "update-omz" \
    "Review the upstream source and update the Oh My Zsh checkout." \
    || return $?
  _sys_menu_entry \
    "Update Zsh Plugins" "update-zsh-plugins" \
    "Review upstream sources and update Git-installed plugins and themes." \
    || return $?
  _sys_menu_entry \
    "Update Hermes Agent" "update-hermes" \
    "Review and update Hermes through the AI suite." \
    || return $?
  _sys_menu_entry \
    "Update Repomix CLI" "update-repomix" \
    "Update npm-managed Repomix; use package updates for Homebrew installations." || return $?

  _sys_menu_section \
    "Destructive Maintenance" \
    "Review restores and cleanup before changing local data." || return $?
  _sys_menu_entry \
    "Restore Dotfiles" "sys-restore-dots" \
    "Preview and overwrite dotfiles from a selected backup archive." \
    || return $?
  _sys_menu_entry \
    "Choose System Cleanup" "clean-system" \
    "Choose a quick or deep cleanup path before removing local data." \
    || return $?
  _sys_menu_entry \
    "Run Quick Cleanup" "clean-system-quick" \
    "Remove common caches, logs, thumbnails, and temporary files." || return $?
  _sys_menu_entry \
    "Run Deep Cleanup" "clean-system-deep" \
    "Run quick cleanup plus slower package and runtime maintenance." \
    || return $?
  _sys_menu_entry \
    "Clean Systemd Journal" "clean-journal" \
    "Remove systemd journal entries older than three days." || return $?
  _sys_menu_entry \
    "Clean Snap Revisions" "clean-snaps" \
    "Preview and remove disabled Snap revisions." || return $?
}

_sys_menu_rows() {
  local rows_output
  rows_output=$(_sys_menu_rows_build) || return $?

  local -a rows=()
  [[ -n "$rows_output" ]] && rows=("${(@f)rows_output}")
  (( ${#rows[@]} > 0 )) || {
    _sys_error "The System menu did not produce any valid rows."
    return 1
  }

  print -r -- "${(F)rows}"
}

_sys_menu_context() {
  local os_name environment_name package_manager service_manager
  os_name=$(_sys_capability_value "os") || return 1
  environment_name=$(_sys_capability_value "environment") || return 1
  package_manager=$(_sys_capability_value "package_manager") || return 1
  service_manager=$(_sys_capability_value "service_manager") || return 1

  local context="OS: $os_name | Environment: $environment_name"
  context+=" | Packages: $package_manager | Services: $service_manager"
  _sys_display_escape "$context"
}

_sys_interactive() {
  local REPLY
  if ! command -v fzf &>/dev/null; then
    _sys_error "fzf is required for the interactive System menu."
    _sys_info \
      "Install fzf with your platform package manager or run a direct subcommand."
    return 1
  fi

  _sys_capabilities_refresh || {
    _sys_error "Unable to detect host capabilities."
    return 1
  }

  local rows_output
  rows_output=$(_sys_menu_rows) || return $?
  local -a menu_rows=("${(@f)rows_output}")

  local context
  context=$(_sys_menu_context) || {
    _sys_error "Unable to render host capability context."
    return 1
  }
  local header="${context}"$'\n''Type to filter | Enter run | Esc cancel | Ctrl-/ details'

  local selected=""
  local -i fzf_status=0
  _sys_fzf_capture \
    --prompt='sys > ' \
    --header="$header" \
    --bind='ctrl-/:toggle-preview' \
    < <(printf "%s\n" "${menu_rows[@]}") || fzf_status=$?
  selected="$REPLY"

  if (( fzf_status != 0 )); then
    (( fzf_status == 1 || fzf_status == 130 )) && return 0
    _sys_error \
      "Unable to open the interactive System menu (status $fzf_status)."
    return 1
  fi

  [[ -z "$selected" ]] && return 0
  local snapshot_row=""
  local -i snapshot_match=0
  for snapshot_row in "${menu_rows[@]}"; do
    if [[ "$snapshot_row" == "$selected" ]]; then
      snapshot_match=1
      break
    fi
  done
  (( snapshot_match )) || {
    _sys_error "The selected System action was not in the menu snapshot."
    return 1
  }

  local command_name="${${selected#*|}%%|*}"
  [[ "$command_name" == ":" ]] && return 0

  _sys_info "Executing: $command_name"
  _sys_timed "sys:$command_name" _sys_dispatch "$command_name"
}

sys-menu() {
  case "${1:-}" in
    "")
      _sys_interactive
      ;;
    -h|--help)
      (( $# == 1 )) || {
        _sys_error "--help accepts no arguments."
        return 2
      }
      _sys_usage
      ;;
    -*)
      _sys_error "Unknown option: $1"
      return 2
      ;;
    *)
      local command_name="$1"
      shift
      _sys_timed "sys:$command_name" \
        _sys_dispatch "$command_name" "$@"
      ;;
  esac
}

typeset -g _SYS_MENU_SOURCED=1
