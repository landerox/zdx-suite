#!/usr/bin/env zsh
# =============================================================================
# ZDX Common: master-menu UI, capture, and fixed dispatch helpers
# =============================================================================
#
# Loaded by zdx-menu.zsh before defining the public ZDX wrapper.
# Private helpers only; not a standalone public command.
#

if [[ -n "${_ZDX_COMMON_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# --- Private Logging & UI Helpers ---------------------------------------------

_zdx_color_enabled() {
  [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" && -t 2 ]]
}

_zdx_header() {
  local message="${1:-}"
  if _zdx_color_enabled; then
    printf '\n\033[1;35m════ %s ════\033[0m\n\n' "${(V)message}" >&2
  else
    printf '\n════ %s ════\n\n' "${(V)message}" >&2
  fi
}

_zdx_info() {
  local message="${1:-}"
  if _zdx_color_enabled; then
    printf '\033[1;34mℹ [info]\033[0m %s\n' "${(V)message}" >&2
  else
    printf 'ℹ [info] %s\n' "${(V)message}" >&2
  fi
}

_zdx_success() {
  local message="${1:-}"
  if _zdx_color_enabled; then
    printf '\033[1;32m✔ [success]\033[0m %s\n' "${(V)message}" >&2
  else
    printf '✔ [success] %s\n' "${(V)message}" >&2
  fi
}

_zdx_warn() {
  local message="${1:-}"
  if _zdx_color_enabled; then
    printf '\033[1;33m⚠ [warning]\033[0m %s\n' "${(V)message}" >&2
  else
    printf '⚠ [warning] %s\n' "${(V)message}" >&2
  fi
}

_zdx_error() {
  local message="${1:-}"
  if _zdx_color_enabled; then
    printf '\033[1;31m✘ [error]\033[0m %s\n' "${(V)message}" >&2
  else
    printf '✘ [error] %s\n' "${(V)message}" >&2
  fi
}

_zdx_dim() {
  local message="${1:-}"
  if _zdx_color_enabled; then
    printf '\033[0;90m%s\033[0m\n' "${(V)message}" >&2
  else
    printf '%s\n' "${(V)message}" >&2
  fi
}

_zdx_menu_field_safe() {
  local value="${1:-}"
  local -i maximum_length="${2:-2048}"

  (( maximum_length >= 1 && maximum_length <= 65536 \
    && ${#value} <= maximum_length )) \
    && [[ "$value" != *'|'* \
      && "$value" != *$'\n'* \
      && "$value" != *$'\0'* ]]
}

_zdx_plugin_name_valid() {
  local plugin_name="${1:-}"
  (( ${#plugin_name} >= 1 && ${#plugin_name} <= 128 )) \
    && [[ "$plugin_name" =~ '^[a-z0-9_-]+$' ]]
}

_zdx_wrapper_name_reserved() {
  case "${1:-}" in
    ai|app|ci|dev|docker|env|file|git|gpu|hf|net|plugins|py|sys|vpn|ws|\
doctor|help|version)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

_zdx_plugin_loaded() {
  local plugin_name="${1:-}"
  _zdx_plugin_name_valid "$plugin_name" || return 1
  (( ${+ZDX_LOADED_PLUGINS} )) || return 1

  local loaded_name=""
  for loaded_name in "${ZDX_LOADED_PLUGINS[@]}"; do
    [[ "$loaded_name" == "$plugin_name" ]] && return 0
  done
  return 1
}

_zdx_menu_section() {
  local title="${1:-}"
  local description="${2:-}"

  if ! _zdx_menu_field_safe "$title" 256 \
    || ! _zdx_menu_field_safe "$description" 2048; then
    _zdx_error "Invalid menu section fields."
    return 2
  fi

  printf '── %s ──|:|%s\n' "$title" "$description"
}

_zdx_menu_entry() {
  local label="${1:-}"
  local command_name="${2:-}"
  local description="${3:-}"

  if ! _zdx_menu_field_safe "$label" 256 \
    || ! _zdx_menu_field_safe "$command_name" 128 \
    || ! _zdx_menu_field_safe "$description" 2048 \
    || [[ ! "$command_name" =~ '^[a-z0-9_-]+$' ]]; then
    _zdx_error "Invalid menu entry fields."
    return 2
  fi

  printf '  %s|%s|%s\n' "$label" "$command_name" "$description"
}

_zdx_fzf() {
  local -a fzf_options=(
    --height=80%
    --layout=reverse
    --border=rounded
    --delimiter='[|]'
    --with-nth=1
    --pointer='▶'
  )

  fzf_options+=('--color=16,fg:-1,bg:-1,fg+:-1,bg+:-1')

  if typeset -f _tk_fzf_color_opts &>/dev/null; then
    local theme_option=""
    theme_option=$(_tk_fzf_color_opts)
    [[ -n "$theme_option" ]] && fzf_options+=("$theme_option")
  fi

  # Compatibility settings are local to this picker and never change the shell.
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
    SHELL=/bin/sh command fzf "${fzf_options[@]}" "$@" "${terminal_options[@]}"
}

_zdx_root_uid() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1

  local -A root_state=()
  [[ -d / && ! -L / ]] \
    && zstat -LH root_state -- / 2>/dev/null \
    && (( (root_state[mode] & 8#170000) == 8#040000 )) || return 1
  REPLY="${root_state[uid]}"
}

_zdx_temp_parent_safe() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local temp_parent="${1:-}"
  REPLY=""

  while [[ "$temp_parent" != "/" && "$temp_parent" == */ ]]; do
    temp_parent="${temp_parent%/}"
  done
  [[ -n "$temp_parent" && "$temp_parent" == /* \
    && "$temp_parent" == "${temp_parent:a}" \
    && "$temp_parent" == "${temp_parent:A}" \
    && -d "$temp_parent" && ! -L "$temp_parent" ]] || return 1

  _zdx_root_uid || return 1
  local -i root_uid=$REPLY
  local -A parent_state=()
  zstat -LH parent_state -- "$temp_parent" 2>/dev/null || return 1
  if (( parent_state[uid] == EUID \
    && (parent_state[mode] & 8#22) == 0 )); then
    :
  elif (( parent_state[uid] == root_uid \
    && (parent_state[mode] & 8#1000) != 0 \
    && (parent_state[mode] & 8#2) != 0 )); then
    :
  else
    return 1
  fi
  REPLY="$temp_parent"
}

# Runs fzf synchronously in the terminal foreground. Selection stdout is
# captured in one private bounded file and returned through REPLY.
_zdx_fzf_capture() {
  emulate -L zsh
  REPLY=""

  zmodload zsh/stat zsh/system 2>/dev/null || {
    _zdx_error "Zsh file-descriptor support is required for the ZDX menu."
    return 125
  }
  _zdx_temp_parent_safe "${TMPDIR:-/tmp}" || {
    _zdx_error "Refusing an unsafe temporary root for the ZDX menu."
    return 125
  }
  local temp_parent="$REPLY"

  local capture_file=""
  capture_file=$(umask 077; command mktemp \
    "${temp_parent%/}/zdx-menu-fzf.XXXXXX" 2>/dev/null) || {
    _zdx_error "Could not create a private ZDX menu result."
    return 125
  }

  local selection=""
  local file_identity=""
  local -i write_fd=-1 read_fd=-1
  local -i fzf_rc=125 operation_rc=125 cleanup_failed=0
  local -A file_state=() current_file_state=()

  {
    if [[ "$capture_file" != "${capture_file:a}" \
      || "$capture_file" != "${capture_file:A}" \
      || "${capture_file:h}" != "$temp_parent" \
      || "${capture_file:t}" != zdx-menu-fzf.* \
      || ! -f "$capture_file" || -L "$capture_file" ]] \
      || ! zstat -LH file_state -- "$capture_file" 2>/dev/null \
      || (( file_state[uid] != EUID || file_state[nlink] != 1 \
        || (file_state[mode] & 8#77) != 0 \
        || (file_state[mode] & 8#170000) != 8#100000 \
        || file_state[size] != 0 )); then
      _zdx_error "Refusing an unsafe ZDX menu result."
    else
      file_identity="${file_state[device]}:${file_state[inode]}:"\
"${file_state[mode]}:${file_state[uid]}:${file_state[nlink]}"
      if ! sysopen -w -o nofollow,cloexec -u write_fd \
        -- "$capture_file" 2>/dev/null; then
        _zdx_error "Could not open the ZDX menu result safely."
      else
        _zdx_fzf "$@" 1>&$(( write_fd ))
        fzf_rc=$?
        exec {write_fd}>&-
        write_fd=-1

        if ! zstat -LH current_file_state -- "$capture_file" 2>/dev/null \
          || [[ "${current_file_state[device]}:"\
"${current_file_state[inode]}:${current_file_state[mode]}:"\
"${current_file_state[uid]}:${current_file_state[nlink]}" \
            != "$file_identity" ]] \
          || (( current_file_state[size] < 0 \
            || current_file_state[size] > 65536 )); then
          _zdx_error "The ZDX menu result changed or exceeded its limit."
        elif ! sysopen -r -o nofollow,cloexec -u read_fd \
          -- "$capture_file" 2>/dev/null; then
          _zdx_error "Could not read the ZDX menu result safely."
        else
          selection=$(<&$(( read_fd )))
          exec {read_fd}>&-
          read_fd=-1
          if (( fzf_rc != 0 )) && [[ -n "$selection" ]]; then
            _zdx_error "A failed ZDX picker returned unexpected data."
            selection=""
          else
            operation_rc=$fzf_rc
          fi
        fi
      fi
    fi
  } always {
    (( write_fd >= 0 )) && exec {write_fd}>&-
    (( read_fd >= 0 )) && exec {read_fd}>&-

    current_file_state=()
    if [[ -n "$file_identity" \
      && -f "$capture_file" && ! -L "$capture_file" \
      && "${capture_file:h}" == "$temp_parent" ]] \
      && zstat -LH current_file_state -- "$capture_file" 2>/dev/null \
      && [[ "${current_file_state[device]}:"\
"${current_file_state[inode]}:${current_file_state[mode]}:"\
"${current_file_state[uid]}:${current_file_state[nlink]}" \
        == "$file_identity" ]]; then
      command rm -f -- "$capture_file" 2>/dev/null || cleanup_failed=1
    else
      cleanup_failed=1
    fi
    (( cleanup_failed == 0 )) || operation_rc=125
  }

  REPLY="$selection"
  return $operation_rc
}

_zdx_fzf_rc_is_cancel() {
  (( ${1:-0} == 1 || ${1:-0} == 130 ))
}

# --- Fixed Suite & Plugin Dispatch -------------------------------------------

_zdx_dispatch_plugin() {
  local plugin_name="${1:-}"
  shift 2>/dev/null || true

  _zdx_plugin_name_valid "$plugin_name" || {
    _zdx_error "Invalid custom plugin identifier: '$plugin_name'."
    return 2
  }
  _zdx_wrapper_name_reserved "$plugin_name" && {
    _zdx_error "Custom plugin name '$plugin_name' is reserved by ZDX."
    return 2
  }
  _zdx_plugin_loaded "$plugin_name" || {
    _zdx_error "Unknown suite or command: '$plugin_name'."
    return 2
  }

  local plugin_function="${plugin_name}-menu"
  (( ${+functions[$plugin_function]} )) || {
    _zdx_error \
      "Loaded plugin '$plugin_name' no longer defines '$plugin_function'."
    return 1
  }

  # The function name is derived only after identifier and exact-membership
  # validation. Arguments remain individual literal array elements.
  local -a literal_arguments=("$@")
  "$plugin_function" "${literal_arguments[@]}"
}

_zdx_require_suite_function() {
  local function_name="${1:-}"
  (( ${+functions[$function_name]} )) && return 0
  _zdx_error \
    "Suite entrypoint '$function_name' is unavailable in this shell."
  return 1
}

_zdx_dispatch_suite() {
  local suite_name="${1:-}"
  shift 2>/dev/null || true

  case "$suite_name" in
    ai)
      _zdx_require_suite_function ai-menu || return
      ai-menu "$@"
      ;;
    app)
      _zdx_require_suite_function app-menu || return
      app-menu "$@"
      ;;
    ci)
      _zdx_require_suite_function ci-menu || return
      ci-menu "$@"
      ;;
    dev)
      _zdx_require_suite_function dev-menu || return
      dev-menu "$@"
      ;;
    docker)
      _zdx_require_suite_function docker-menu || return
      docker-menu "$@"
      ;;
    env)
      _zdx_require_suite_function env-menu || return
      env-menu "$@"
      ;;
    file)
      _zdx_require_suite_function file-menu || return
      file-menu "$@"
      ;;
    git)
      _zdx_require_suite_function git-menu || return
      git-menu "$@"
      ;;
    gpu)
      _zdx_require_suite_function gpu-menu || return
      gpu-menu "$@"
      ;;
    hf)
      _zdx_require_suite_function hf-menu || return
      hf-menu "$@"
      ;;
    net)
      _zdx_require_suite_function net-menu || return
      net-menu "$@"
      ;;
    plugins)
      _zdx_require_suite_function zdx-plugins || return
      zdx-plugins "$@"
      ;;
    py)
      _zdx_require_suite_function py-menu || return
      py-menu "$@"
      ;;
    sys)
      _zdx_require_suite_function sys-menu || return
      sys-menu "$@"
      ;;
    vpn)
      _zdx_require_suite_function vpn-menu || return
      vpn-menu "$@"
      ;;
    ws)
      _zdx_require_suite_function ws-menu || return
      ws-menu "$@"
      ;;
    doctor)
      _zdx_require_suite_function zdx-doctor || return
      zdx-doctor "$@"
      ;;
    :)       return 0 ;;
    *)       _zdx_dispatch_plugin "$suite_name" "$@" ;;
  esac
}

# --- Menu Model ---------------------------------------------------------------

_zdx_menu_model() {
  local -a definitions=(
    $'section\tProjects\tWork with repositories, workspace profiles, project tasks, and CI.'
    $'entry\tManage Git Repositories (git)\tgit\tStage changes, manage branches and commits, sync remotes, and review pull requests.'
    $'entry\tManage Workspaces (ws)\tws\tOrganize workspace profiles, Git identities, repository roots, and SSH access.'
    $'entry\tMaintain Projects (dev)\tdev\tUpdate project dependencies, run quality checks, inspect security, and clean caches.'
    $'entry\tRun Project Tasks (app)\tapp\tDiscover and review Just, package scripts, Make, and Compose tasks before running them.'
    $'entry\tManage GitHub CI (ci)\tci\tInspect workflow runs, review failures, and manage repository CI resources.'

    $'section\tFiles and Environments\tManage local files, environment settings, and project Python environments.'
    $'entry\tManage Files and Archives (file)\tfile\tSearch and compare local files, manage permissions, and create or extract archives.'
    $'entry\tManage Environment Profiles (env)\tenv\tInspect dotenv values, compare profiles, and apply selected settings to this shell.'
    $'entry\tManage Python Environments (py)\tpy\tCreate project environments and manage Python packages, runtimes, and tools.'

    $'section\tSystem and Network\tMaintain host tools, inspect Docker resources, and manage network connections.'
    $'entry\tMaintain System Tools (sys)\tsys\tInspect services, ports, and processes; update host tools and clean system caches.'
    $'entry\tManage Docker Resources (docker)\tdocker\tInspect containers, images, and Compose stacks; review cleanup on the selected daemon.'
    $'entry\tDiagnose Networks (net)\tnet\tInspect interfaces, DNS, latency, public IP, and connection throughput.'
    $'entry\tManage WireGuard VPN (vpn)\tvpn\tInspect tunnel status, connect saved profiles, and manage WSL DNS protection.'

    $'section\tAI and Hardware\tMaintain AI assistants, explore model artifacts, and inspect GPU activity.'
    $'entry\tMaintain AI Assistants (ai)\tai\tUpdate installed AI CLIs, inspect MCP servers and logs, and manage assistant caches.'
    $'entry\tBrowse Hugging Face (hf)\thf\tSearch models and datasets, download artifacts, and manage local Hub caches.'
    $'entry\tInspect NVIDIA GPUs (gpu)\tgpu\tView GPU utilization, memory, temperature, and process activity.'

    $'section\tZDX Tools\tCheck suite dependencies and manage custom plugins.'
    $'entry\tCheck Dependencies (doctor)\tdoctor\tInspect missing dependencies and choose whether to install supported packages.'
    $'entry\tManage Custom Plugins (plugins)\tplugins\tList, install, update, or remove custom ZDX plugins.'
  )

  local -a menu_rows=()
  local definition=""
  local row_kind="" label="" command_name="" description="" extra="" row=""
  for definition in "${definitions[@]}"; do
    row_kind=""
    label=""
    command_name=""
    description=""
    extra=""
    IFS=$'\t' read -r \
      row_kind label command_name description extra <<< "$definition"
    [[ -z "$extra" ]] || {
      _zdx_error "Invalid internal ZDX menu definition."
      return 1
    }

    case "$row_kind" in
      section)
        row=$(_zdx_menu_section "$label" "$command_name") || return
        ;;
      entry)
        row=$(_zdx_menu_entry \
          "$label" "$command_name" "$description") || return
        ;;
      *)
        _zdx_error "Invalid internal ZDX menu definition type."
        return 1
        ;;
    esac
    menu_rows+=("$row")
  done

  local -a loaded_plugins=()
  if (( ${+ZDX_LOADED_PLUGINS} )); then
    loaded_plugins=("${ZDX_LOADED_PLUGINS[@]}")
  fi
  if (( ${#loaded_plugins[@]} > 0 )); then
    local plugin_name=""
    local -a included_plugins=() plugin_rows=()
    for plugin_name in "${loaded_plugins[@]}"; do
      if ! _zdx_plugin_name_valid "$plugin_name"; then
        _zdx_warn "Skipping invalid loaded plugin identifier: '$plugin_name'."
        continue
      fi
      if _zdx_wrapper_name_reserved "$plugin_name"; then
        _zdx_warn "Skipping loaded plugin with reserved name: '$plugin_name'."
        continue
      fi
      if (( ${included_plugins[(Ie)$plugin_name]} )); then
        continue
      fi
      if (( ! ${+functions[${plugin_name}-menu]} )); then
        _zdx_warn \
          "Skipping loaded plugin '$plugin_name' because its menu is unavailable."
        continue
      fi
      row=$(_zdx_menu_entry \
        "Open $plugin_name" "$plugin_name" \
        "Loaded in this shell. Open the custom plugin menu.") || return
      plugin_rows+=("$row")
      included_plugins+=("$plugin_name")
    done

    if (( ${#plugin_rows[@]} > 0 )); then
      row=$(_zdx_menu_section \
        "Custom Plugins" "Open custom suites loaded in this shell.") || return
      menu_rows+=("$row" "${plugin_rows[@]}")
    fi
  fi

  printf '%s\n' "${menu_rows[@]}"
}

_zdx_selected_row_in_snapshot() {
  local selected="${1:-}"
  shift 2>/dev/null || true

  local snapshot_row=""
  for snapshot_row in "$@"; do
    [[ "$selected" == "$snapshot_row" ]] && return 0
  done
  return 1
}

_zdx_interactive() {
  command -v fzf &>/dev/null || {
    _zdx_error \
      "fzf is required for the interactive menu; use 'zdx <suite>' directly."
    return 1
  }

  local menu_data=""
  menu_data=$(_zdx_menu_model) || return
  local -a menu_rows=("${(@f)menu_data}")
  (( ${#menu_rows[@]} > 0 )) || {
    _zdx_error "The ZDX menu model is empty."
    return 1
  }

  local selected=""
  local -i fzf_rc=0
  local menu_header="Directory: ${(V)PWD}"$'\n'\
'Type to filter | Enter open | Esc cancel | Ctrl-/ details'
  _zdx_fzf_capture \
    --prompt='zdx > ' \
    --header="$menu_header" \
    --bind='ctrl-/:toggle-preview' \
    --preview='case {2} in :) printf "%s\n" {3} ;; *) printf "Command: zdx %s\n\n%s\n" {2} {3} ;; esac' \
    --preview-window='down:4:wrap' \
    < <(printf '%s\n' "${menu_rows[@]}") || fzf_rc=$?
  selected="$REPLY"

  if (( fzf_rc != 0 )); then
    _zdx_fzf_rc_is_cancel "$fzf_rc" && return 0
    _zdx_error "Unable to open the ZDX menu (status $fzf_rc)."
    return 1
  fi
  [[ -z "$selected" ]] && return 0
  _zdx_selected_row_in_snapshot "$selected" "${menu_rows[@]}" || {
    _zdx_error "The selected suite was not in the ZDX menu snapshot."
    return 1
  }

  local selected_fields="${selected#*|}"
  local suite_name="${selected_fields%%|*}"
  [[ "$suite_name" == ":" ]] && return 0
  _zdx_dispatch_suite "$suite_name"
}

typeset -g _ZDX_COMMON_SOURCED=1
