#!/usr/bin/env zsh
# =============================================================================
# ZDX Plugins: Dynamic and safe decentralized plugin manager
# =============================================================================
#
# Manages user-defined custom plugins under ~/.config/zdx/plugins/
# complies with the specifications defined in docs/plugins.md.
# Sourced automatically by zdx. Safe to re-source (idempotent).
#

if [[ -n "${_ZDX_PLUGINS_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
typeset -g _ZDX_PLUGINS_SOURCED=1

# --- Local Logging Helpers ---------------------------------------------------
_zdx_plugins_info()    { echo -e "\033[1;34mℹ [info]\033[0m $1" >&2; }
_zdx_plugins_success() { echo -e "\033[1;32m✔ [success]\033[0m $1" >&2; }
_zdx_plugins_warn()    { echo -e "\033[1;33m⚠ [warning]\033[0m $1" >&2; }
_zdx_plugins_error()   { echo -e "\033[1;31m✘ [error]\033[0m $1" >&2; }
_zdx_plugins_dim()     { echo -e "\033[0;90m$1\033[0m" >&2; }

_zdx_plugins_header() {
  echo -e "\n\033[1;35m════ $1 ════\033[0m\n" >&2
}

_zdx_plugins_menu_section() {
  local title="$1" description="${2:-}"
  printf "── %s ──|:|%s\n" "$title" "$description"
}

_zdx_plugins_menu_entry() {
  local label="$1" command="$2" description="$3"
  printf "  %s|%s|%s\n" "$label" "$command" "$description"
}

# Keep picker rendering independent of the user's standalone fzf defaults.
_zdx_plugins_fzf() {
  local -a options=('--color=16,fg:-1,bg:-1,fg+:-1,bg+:-1')
  if typeset -f _tk_fzf_color_opts &>/dev/null; then
    local theme_option=""
    theme_option=$(_tk_fzf_color_opts)
    [[ -n "$theme_option" ]] && options+=("$theme_option")
  fi

  local -a terminal_options=()
  local terminal_locale="${LC_ALL:-${LC_CTYPE:-${LANG:-C}}}"
  if [[ -n "${ZDX_FZF_PLAIN:-}" || "$terminal_locale" == C \
    || "$terminal_locale" == POSIX || "${TERM:-}" == dumb ]]; then
    terminal_options+=(--no-unicode '--pointer=>' '--marker=+')
  fi
  if [[ -n "${NO_COLOR:-}" || -n "${ZDX_FZF_PLAIN:-}" \
    || "${TERM:-}" == dumb ]]; then
    terminal_options+=(--no-color)
  fi

  FZF_DEFAULT_OPTS='' FZF_DEFAULT_OPTS_FILE='' FZF_DEFAULT_COMMAND='' \
    SHELL=/bin/sh fzf "${options[@]}" "$@" "${terminal_options[@]}"
}

# --- Interactive Confirmation -------------------------------------------------
_zdx_plugins_confirm() {
  local prompt="$1"
  local selected
  if [[ -t 0 && -t 1 ]] && command -v fzf &>/dev/null; then
    selected=$(printf "No\nYes\n" | _zdx_plugins_fzf \
      --height=20% \
      --layout=reverse \
      --border=rounded \
      --prompt="$prompt > " \
      --header="Use arrow keys to select, Enter to confirm" \
      --pointer="▶")
    [[ "$selected" == "Yes" ]]
  else
    local reply
    printf "\033[1;33m? %s [y/N]: \033[0m" "$prompt" >&2
    read -r reply
    [[ "$reply" =~ ^[Yy]$ ]]
  fi
}

# --- Core Plugin Management Logic ---------------------------------------------

_zdx_plugins_list() {
  local plugins_dir="${ZDX_PLUGINS_DIR:-$HOME/.config/zdx/plugins}"
  mkdir -p "$plugins_dir" 2>/dev/null

  # Enable extended globbing locally
  setopt localoptions extendedglob
  local -a subdirs
  subdirs=("${plugins_dir}"/*(N/))

  if (( ${#subdirs} == 0 )); then
    echo "No plugins installed." >&2
    return 0
  fi

  printf "\033[1;34m%-20s %-10s %s\033[0m\n" "Plugin Name" "Status" "Git Remote Origin" >&2
  printf "\033[0;90m%s\033[0m\n" "────────────────────────────────────────────────────────────────────────────────" >&2

  local subdir plugin_name menu_file plugin_status origin git_origin
  for subdir in "${subdirs[@]}"; do
    plugin_name="${subdir:t}"
    menu_file="${subdir}/${plugin_name}-menu.zsh"
    plugin_status="Invalid"
    origin="Local"

    if [[ "$plugin_name" =~ '^[a-z0-9_-]+$' ]]; then
      if [[ -f "$menu_file" && -r "$menu_file" ]]; then
        plugin_status="Inactive"
        # Check if registered in ZDX_LOADED_PLUGINS
        if [[ " ${ZDX_LOADED_PLUGINS[*]} " == *" ${plugin_name} "* ]]; then
          plugin_status="Active"
        fi
      fi
    fi

    if [[ -d "${subdir}/.git" ]]; then
      git_origin=$(git -C "$subdir" remote get-url origin 2>/dev/null)
      if [[ -n "$git_origin" ]]; then
        origin="$git_origin"
      fi
    fi

    local status_color="\033[1;31m" # Red for invalid
    if [[ "$plugin_status" == "Active" ]]; then
      status_color="\033[1;32m" # Green for active
    elif [[ "$plugin_status" == "Inactive" ]]; then
      status_color="\033[1;33m" # Yellow for inactive
    fi

    printf "%-20s ${status_color}%-10s\033[0m %s\n" "$plugin_name" "$plugin_status" "$origin" >&2
  done
}

_zdx_plugins_install() {
  local url="$1"
  local custom_name="$2"

  if [[ -z "$url" ]]; then
    _zdx_plugins_error "Git repository URL is required."
    return 1
  fi

  local plugins_dir="${ZDX_PLUGINS_DIR:-$HOME/.config/zdx/plugins}"
  mkdir -p "$plugins_dir" 2>/dev/null

  local plugin_name
  if [[ -n "$custom_name" ]]; then
    plugin_name="$custom_name"
  else
    # Extract basename from Git URL
    plugin_name="${url:t}"
    plugin_name="${plugin_name%.git}"
  fi

  # Validate naming rules matching specs (lowercase letters, numbers, hyphens, underscores)
  if ! [[ "$plugin_name" =~ '^[a-z0-9_-]+$' ]]; then
    _zdx_plugins_error "Plugin name '$plugin_name' is invalid. Must match '^[a-z0-9_-]+$' (lowercase, numbers, dashes, underscores)."
    return 1
  fi

  local target_dir="${plugins_dir}/${plugin_name}"
  if [[ -d "$target_dir" ]]; then
    _zdx_plugins_warn "Directory '$target_dir' already exists. Use '--update' to refresh it."
    return 1
  fi

  _zdx_plugins_info "Cloning plugin into ${target_dir}..."

  # Wrap git clone in _tk_spinner if available for async UI feedback
  local clone_cmd=(git clone --depth 1 "$url" "$target_dir")
  if typeset -f _tk_spinner &>/dev/null; then
    if ! _tk_spinner "Cloning repository..." "${clone_cmd[@]}" 2>&1; then
      _zdx_plugins_error "Failed to clone Git repository."
      rm -rf "$target_dir" 2>/dev/null
      return 1
    fi
  else
    if ! "${clone_cmd[@]}" 2>&1; then
      _zdx_plugins_error "Failed to clone Git repository."
      rm -rf "$target_dir" 2>/dev/null
      return 1
    fi
  fi

  # Contract checks
  local menu_file="${target_dir}/${plugin_name}-menu.zsh"
  if [[ ! -f "$menu_file" ]]; then
    _zdx_plugins_error "Ecosystem Contract Violation: Entrypoint script '${plugin_name}-menu.zsh' not found in repo."
    _zdx_plugins_dim "Deleting cloned files..."
    rm -rf "$target_dir" 2>/dev/null
    return 1
  fi

  # Syntax parse check
  if ! zsh -n "$menu_file" 2>&1; then
    _zdx_plugins_error "Ecosystem Contract Violation: Syntax error in '${plugin_name}-menu.zsh'."
    _zdx_plugins_dim "Deleting cloned files..."
    rm -rf "$target_dir" 2>/dev/null
    return 1
  fi

  # Source and dynamic load
  if ! source "$menu_file" 2>/dev/null; then
    _zdx_plugins_error "Failed to source entrypoint file."
    _zdx_plugins_dim "Deleting cloned files..."
    rm -rf "$target_dir" 2>/dev/null
    return 1
  fi

  if ! typeset -f "${plugin_name}-menu" &>/dev/null; then
    _zdx_plugins_error "Ecosystem Contract Violation: Function '${plugin_name}-menu' was not defined after sourcing."
    _zdx_plugins_dim "Deleting cloned files..."
    rm -rf "$target_dir" 2>/dev/null
    return 1
  fi

  # Register dynamic load
  if [[ " ${ZDX_LOADED_PLUGINS[*]} " != *" ${plugin_name} "* ]]; then
    ZDX_LOADED_PLUGINS+=("$plugin_name")
  fi

  _zdx_plugins_success "Plugin '${plugin_name}' successfully installed and activated."
  return 0
}

_zdx_plugins_update() {
  local name="$1"
  local plugins_dir="${ZDX_PLUGINS_DIR:-$HOME/.config/zdx/plugins}"

  if [[ -n "$name" ]]; then
    local target_dir="${plugins_dir}/${name}"
    if [[ ! -d "$target_dir" ]]; then
      _zdx_plugins_error "Plugin '$name' is not installed."
      return 1
    fi
    if [[ ! -d "${target_dir}/.git" ]]; then
      _zdx_plugins_warn "Plugin '$name' is not git-tracked. Skipping update."
      return 0
    fi

    _zdx_plugins_info "Updating plugin '$name'..."
    local update_cmd=(git -C "$target_dir" pull)
    local update_status=0

    if typeset -f _tk_spinner &>/dev/null; then
      _tk_spinner "Pulling updates..." "${update_cmd[@]}" 2>&1 || update_status=1
    else
      "${update_cmd[@]}" 2>&1 || update_status=1
    fi

    if (( update_status == 0 )); then
      local menu_file="${target_dir}/${name}-menu.zsh"
      if [[ -f "$menu_file" ]]; then
        source "$menu_file" 2>/dev/null
        _zdx_plugins_success "Plugin '$name' successfully updated and reloaded."
      else
        _zdx_plugins_warn "Entrypoint script '${name}-menu.zsh' not found after update."
      fi
    else
      _zdx_plugins_error "Failed to pull updates from git repository."
      return 1
    fi
  else
    # Update all
    setopt localoptions extendedglob
    local -a subdirs
    subdirs=("${plugins_dir}"/*(N/))
    if (( ${#subdirs} == 0 )); then
      _zdx_plugins_info "No plugins found to update."
      return 0
    fi

    local subdir plugin_name updated_count=0
    for subdir in "${subdirs[@]}"; do
      plugin_name="${subdir:t}"
      if [[ -d "${subdir}/.git" ]]; then
        _zdx_plugins_info "Checking updates for '${plugin_name}'..."
        local pull_cmd=(git -C "$subdir" pull)
        local pull_status=0

        if typeset -f _tk_spinner &>/dev/null; then
          _tk_spinner "Updating ${plugin_name}..." "${pull_cmd[@]}" &>/dev/null || pull_status=1
        else
          "${pull_cmd[@]}" &>/dev/null || pull_status=1
        fi

        if (( pull_status == 0 )); then
          local menu_file="${subdir}/${plugin_name}-menu.zsh"
          if [[ -f "$menu_file" ]]; then
            source "$menu_file" 2>/dev/null
            (( updated_count++ ))
          fi
        fi
      fi
    done
    _zdx_plugins_success "Successfully checked/updated ${updated_count} plugin(s)."
  fi
  return 0
}

_zdx_plugins_remove() {
  local name="$1"
  if [[ -z "$name" ]]; then
    _zdx_plugins_error "Plugin name is required."
    return 1
  fi

  local plugins_dir="${ZDX_PLUGINS_DIR:-$HOME/.config/zdx/plugins}"
  local target_dir="${plugins_dir}/${name}"

  if [[ ! -d "$target_dir" ]]; then
    _zdx_plugins_error "Plugin '$name' is not installed."
    return 1
  fi

  # Path safety traversal protection
  local real_target
  real_target=$(cd "$target_dir" 2>/dev/null && pwd)
  local real_base
  real_base=$(cd "$plugins_dir" 2>/dev/null && pwd)

  if [[ "$real_target" != "${real_base}/"* ]]; then
    _zdx_plugins_error "Security Alert: Invalid plugin path '$target_dir'."
    return 1
  fi

  if _zdx_plugins_confirm "Are you sure you want to permanently delete plugin '${name}'?"; then
    _zdx_plugins_info "Deleting files..."
    rm -rf "$target_dir" 2>/dev/null

    # Remove from registration list
    local -a updated_list
    updated_list=()
    local p
    for p in "${ZDX_LOADED_PLUGINS[@]}"; do
      if [[ "$p" != "$name" ]]; then
        updated_list+=("$p")
      fi
    done
    ZDX_LOADED_PLUGINS=("${updated_list[@]}")

    _zdx_plugins_success "Plugin '${name}' removed successfully."
  else
    _zdx_plugins_info "Uninstallation canceled."
  fi
  return 0
}

_zdx_plugins_menu() {
  local plugins_dir="${ZDX_PLUGINS_DIR:-$HOME/.config/zdx/plugins}"
  while true; do
    local -a options=(
      "$(_zdx_plugins_menu_section "Plugin Manager" "List, install, update, and remove system plugins.")"
      "$(_zdx_plugins_menu_entry "List Installed Plugins" "list" "Show active plugins and their status.")"
      "$(_zdx_plugins_menu_entry "Install New Plugin" "install" "Clone and register a custom plugin from a Git URL.")"
      "$(_zdx_plugins_menu_entry "Update Installed Plugins" "update" "Pull the latest changes for your plugins.")"
      "$(_zdx_plugins_menu_entry "Uninstall Plugin" "remove" "Safely remove an installed plugin from your system.")"
    )

    local -a fzf_opts=(
      --height=50%
      --layout=reverse
      --border=rounded
      --delimiter='[|]'
      --with-nth=1
      --pointer='▶'
      --prompt='Plugins > '
      --header=$'Select a plugin action\n[Enter] Select  [Esc] Exit'
    )

    # In-loop locals keep an initializer: re-declaring an existing local
    # without one makes zsh print the variable on every later iteration.
    local selected=""
    selected=$(printf "%s\n" "${options[@]}" | _zdx_plugins_fzf "${fzf_opts[@]}")

    [[ -z "$selected" ]] && return 0

    local action="${${selected#*|}%%|*}"
    [[ "$action" == ":" ]] && continue

    case "$action" in
      list)
        _zdx_plugins_header "Installed Plugins"
        _zdx_plugins_list
        ;;
      install)
        _zdx_plugins_header "Install New Plugin"
        echo -n "\033[1;33m? Enter Git Repository URL: \033[0m" >&2
        local url=""
        read -r url
        if [[ -n "$url" ]]; then
          echo -n "\033[1;33m? Enter Custom Name (optional): \033[0m" >&2
          local custom_name=""
          read -r custom_name
          _zdx_plugins_install "$url" "$custom_name"
        else
          _zdx_plugins_warn "No URL entered. Installation canceled."
        fi
        ;;
      update)
        _zdx_plugins_header "Update Plugins"
        _zdx_plugins_update
        ;;
      remove)
        _zdx_plugins_header "Uninstall Plugin"
        setopt localoptions extendedglob
        local -a subdirs=("${plugins_dir}"/*(N/))
        local -a plugin_names=()
        local d=""
        for d in "${subdirs[@]}"; do
          plugin_names+=("${d:t}")
        done

        if (( ${#plugin_names} == 0 )); then
          _zdx_plugins_info "No plugins installed to remove."
        else
          local chosen=""
          chosen=$(printf "%s\n" "${plugin_names[@]}" | _zdx_plugins_fzf \
            --height=40% \
            --layout=reverse \
            --border=rounded \
            --prompt='Uninstall > ' \
            --header='Select a plugin to uninstall' \
            --pointer='▶')

          if [[ -n "$chosen" ]]; then
            _zdx_plugins_remove "$chosen"
          fi
        fi
        ;;
    esac

    echo "\n\033[0;90mPress any key to return to Plugins menu...\033[0m" >&2
    read -k1
  done
}

# --- Public API Command -------------------------------------------------------

zdx-plugins() {
  if [[ -n "$1" ]]; then
    case "$1" in
      -h|--help)
        cat <<'EOF'
Usage:
  zdx-plugins              Interactive menu (list, install, update, remove)
  zdx-plugins --list       Print installed plugins cleanly
  zdx-plugins --install <url> [name]  Clone, validate and register a plugin
  zdx-plugins --update [name]  Pull updates and hot-reload specific or all plugins
  zdx-plugins --remove <name>  Delete plugin safely under confirmation gate

Notes:
  This tool manages custom packages located under ~/.config/zdx/plugins/.
EOF
        return 0
        ;;
      --list)
        _zdx_plugins_list
        return $?
        ;;
      --install)
        if [[ -z "$2" ]]; then
          _zdx_plugins_error "Missing Git URL for --install flag."
          return 1
        fi
        _zdx_plugins_install "$2" "$3"
        return $?
        ;;
      --update)
        _zdx_plugins_update "$2"
        return $?
        ;;
      --remove)
        if [[ -z "$2" ]]; then
          _zdx_plugins_error "Missing plugin name for --remove flag."
          return 1
        fi
        _zdx_plugins_remove "$2"
        return $?
        ;;
      *)
        _zdx_plugins_error "Unknown flag: $1"
        return 1
        ;;
    esac
  fi

  if ! command -v fzf &>/dev/null; then
    _zdx_plugins_error "fzf not found. Plugin manager interactive menu requires fzf."
    return 1
  fi

  _zdx_plugins_menu
}
