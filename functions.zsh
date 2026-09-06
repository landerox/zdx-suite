#!/usr/bin/env zsh
# =============================================================================
# ZDX Core: configuration, suite loading, plugins, timing, and telemetry
# =============================================================================
#
# Sourced by zdx-suite.plugin.zsh or directly by a Zsh startup file.
# Registers suite entrypoints and owner-local runtime helpers.
#

if [[ -n "${_ZDX_FUNCTIONS_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# Load optional user configuration
if [[ -f "$HOME/.config/zdx/config.zsh" \
  && -r "$HOME/.config/zdx/config.zsh" ]]; then
  source "$HOME/.config/zdx/config.zsh" || {
    typeset -i _zdx_config_rc=$?
    print -u2 -r -- "zdx: failed to load user configuration"
    {
      return $_zdx_config_rc 2>/dev/null || exit $_zdx_config_rc
    } always {
      unset _zdx_config_rc
    }
  }
fi

# --- Centralized FZF Theme Helpers -------------------------------------------

_tk_fzf_color_opts() {
  if [[ -n "${NO_COLOR:-}" || -n "${ZDX_FZF_PLAIN:-}" \
    || "${TERM:-}" == dumb ]]; then
    print -r -- '--no-color'
  elif [[ -n "${ZDX_FZF_THEME:-}" ]]; then
    print -r -- "--color=${ZDX_FZF_THEME}"
  else
    # Keep foreground and background paired with the terminal's own palette.
    print -r -- '--color=16,fg:-1,bg:-1,fg+:-1,bg+:-1'
  fi
}

_tk_fzf() {
  local -a default_opts
  default_opts=(
    "$(_tk_fzf_color_opts)"
    --layout=reverse
    --border
  )
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
    SHELL=/bin/sh fzf "${default_opts[@]}" "$@" "${terminal_options[@]}"
}

# --- Native Zsh Spinner ------------------------------------------------------

_tk_spinner() {
  local msg="$1"
  shift

  # Hide cursor using ANSI escape
  printf "\e[?25l" >&2

  # Run the command in the background
  "$@" &
  local pid=$!

  {
    local delay=0.1
    local -a frames
    frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local frame_count=${#frames[@]}
    local i=1

    while kill -0 $pid 2>/dev/null; do
      printf "\r\033[0;36m%s\033[0m %s" "${frames[i]}" "$msg" >&2
      i=$(( (i % frame_count) + 1 ))
      sleep $delay
    done
  } always {
    # Ensure background process is terminated if interrupted/completed
    if kill -0 $pid 2>/dev/null; then
      kill -TERM $pid 2>/dev/null
    fi
    # Restore cursor and clear the spinner line
    printf "\r\e[?25h\033[K" >&2
  }

  wait $pid 2>/dev/null
  return $?
}

_tk_check_cmd() {
  command -v "$1" &>/dev/null
}

# --- Optimized Lazy Loading (Autoloading Diferido) ---------------------------
# To minimize shell startup time, we define lightweight stubs for public commands.
# The real implementation file is only sourced on first execution of the command.
# Under test environments or when explicitly disabled, we fall back to eager loading.

typeset _zdx_core_dir="${${(%):-%x}:A:h}"
typeset -g _ZDX_FUNCTIONS_DIR="$_zdx_core_dir/functions"

# Check if eager loading is requested or if we are in a test sandbox
typeset -i _zdx_eager_load=0
if [[ "${ZDX_EAGER_LOAD:-}" == "1" || "${ZDX_LAZY_LOAD:-}" == "0" || -n "${TEST_TEMP_DIR:-}" || -n "${BATS_TEST_DIRNAME:-}" ]]; then
  _zdx_eager_load=1
fi

if (( _zdx_eager_load )); then
  # Eager Loading: Source all top-level .zsh files immediately (fallback / test mode)
  if [[ -d "$_ZDX_FUNCTIONS_DIR" ]]; then
    typeset _zdx_function_file
    for _zdx_function_file in "$_ZDX_FUNCTIONS_DIR"/*.zsh(N); do
      if [[ -f "$_zdx_function_file" && -r "$_zdx_function_file" ]]; then
        source "$_zdx_function_file" || {
          typeset -i _zdx_source_rc=$?
          print -u2 -r -- \
            "zdx: failed to load ${_zdx_function_file:t}"
          unset _zdx_core_dir _zdx_eager_load _zdx_function_file
          {
            return $_zdx_source_rc 2>/dev/null || exit $_zdx_source_rc
          } always {
            unset _zdx_source_rc
          }
        }
      fi
    done
    unset _zdx_function_file
  fi
else
  # Lazy Loading: Register stubs for public commands to avoid shell startup penalties

  typeset -gA _ZDX_LAZY_FILES=(
    ai-menu ai-menu.zsh
    global-clean-ai ai-menu.zsh
    global-clean-claude ai-menu.zsh
    global-clean-codex ai-menu.zsh
    global-clean-antigravity ai-menu.zsh
    global-clean-opencode ai-menu.zsh
    global-clean-copilot ai-menu.zsh
    global-clean-cursor ai-menu.zsh
    global-clean-amp ai-menu.zsh
    project-sweep-ai ai-menu.zsh
    ai-init-agents ai-menu.zsh
    ai-update ai-menu.zsh
    ai-update-claude ai-menu.zsh
    ai-update-codex ai-menu.zsh
    ai-update-antigravity ai-menu.zsh
    ai-update-opencode ai-menu.zsh
    ai-update-cursor ai-menu.zsh
    ai-update-copilot ai-menu.zsh
    ai-update-amp ai-menu.zsh
    ai-update-hermes ai-menu.zsh
    ai-mcp-list ai-menu.zsh
    ai-mcp-doctor ai-menu.zsh
    ai-mcp-update ai-menu.zsh
    ai-config-backup ai-menu.zsh
    ai-config-restore ai-menu.zsh
    ai-doctor ai-menu.zsh
    ai-disk-usage ai-menu.zsh
    ai-versions ai-menu.zsh
    ai-log-tail ai-menu.zsh
    app-menu app-menu.zsh
    app-list app-menu.zsh
    app-run app-menu.zsh
    ci-menu ci-menu.zsh
    ci-clean-actions ci-menu.zsh
    ci-clean-deployments ci-menu.zsh
    ci-clean-issues ci-menu.zsh
    ci-clean-notifications ci-menu.zsh
    ci-clean-releases ci-menu.zsh
    ci-clean-tags ci-menu.zsh
    ci-run ci-menu.zsh
    ci-status ci-menu.zsh
    dev-menu dev-menu.zsh
    docker-menu docker-menu.zsh
    docker-containers docker-menu.zsh
    docker-images docker-menu.zsh
    docker-clean docker-menu.zsh
    docker-login docker-menu.zsh
    docker-compose-up docker-menu.zsh
    docker-compose-down docker-menu.zsh
    docker-compose-restart docker-menu.zsh
    docker-compose-logs docker-menu.zsh
    env-menu env-menu.zsh
    env-create env-menu.zsh
    env-list env-menu.zsh
    env-path env-menu.zsh
    env-profile-delete env-menu.zsh
    env-profile-list env-menu.zsh
    env-profile-load env-menu.zsh
    env-profile-save env-menu.zsh
    env-switch env-menu.zsh
    file-menu file-menu.zsh
    file-bulk-ops file-menu.zsh
    file-checksum file-menu.zsh
    file-compress file-menu.zsh
    file-diff file-menu.zsh
    file-encode-decode file-menu.zsh
    file-extract file-menu.zsh
    file-find file-menu.zsh
    file-find-large file-menu.zsh
    file-line-endings file-menu.zsh
    file-permissions file-menu.zsh
    git-menu git-menu.zsh
    gpu-menu gpu-menu.zsh
    gpu-visualizer gpu-menu.zsh
    hf-menu hf-menu.zsh
    hf-cache-clear hf-menu.zsh
    hf-cache-inspect hf-menu.zsh
    hf-download hf-menu.zsh
    hf-repo-stats hf-menu.zsh
    hf-search hf-menu.zsh
    net-menu net-menu.zsh
    net-dashboard net-menu.zsh
    net-dns net-menu.zsh
    net-interfaces net-menu.zsh
    net-ping net-menu.zsh
    net-public-ip net-menu.zsh
    net-speedtest net-menu.zsh
    py-menu py-menu.zsh
    package-install py-menu.zsh
    package-search py-menu.zsh
    package-uninstall py-menu.zsh
    tool-install py-menu.zsh
    tool-list py-menu.zsh
    tool-uninstall py-menu.zsh
    tool-upgrade py-menu.zsh
    venv-activate py-menu.zsh
    venv-create py-menu.zsh
    venv-info py-menu.zsh
    venv-list py-menu.zsh
    venv-python py-menu.zsh
    venv-python-install py-menu.zsh
    venv-python-list py-menu.zsh
    venv-python-pin py-menu.zsh
    venv-rebuild py-menu.zsh
    venv-remove py-menu.zsh
    sys-menu sys-menu.zsh
    vpn-menu vpn-menu.zsh
    ws-menu ws-menu.zsh
    ws-auth ws-menu.zsh
    ws-create ws-menu.zsh
    ws-list ws-menu.zsh
    ws-info ws-menu.zsh
    ws-doctor ws-menu.zsh
    ws-clone ws-menu.zsh
    ws-clone-multi ws-menu.zsh
    ws-sync ws-menu.zsh
    ws-repos ws-menu.zsh
    ws-migrate ws-menu.zsh
    ws-show-key ws-menu.zsh
    ws-rotate-key ws-menu.zsh
    ws-test ws-menu.zsh
    ws-autoclean ws-menu.zsh
    ws-remove ws-menu.zsh
    zclean zclean.zsh
    zdir zdir.zsh
    zdx-doctor zdx-doctor.zsh
    zdx-menu zdx-menu.zsh
    zdx zdx-menu.zsh
    zdx-plugins zdx-plugins.zsh
  )

  _zdx_lazy_dispatch() {
    local function_name="$1"
    shift
    local file_name="${_ZDX_LAZY_FILES[$function_name]:-}"
    local module_file="$_ZDX_FUNCTIONS_DIR/$file_name"
    [[ -n "$file_name" && "$function_name" =~ '^[a-z0-9-]+$' \
      && "$file_name" =~ '^[a-z0-9-]+[.]zsh$' \
      && -f "$module_file" && ! -L "$module_file" \
      && -r "$module_file" ]] || {
      print -u2 -r -- \
        "zdx: failed to resolve lazy command ${(V)function_name}"
      return 1
    }

    unset -f "$function_name"
    source "$module_file"
    local source_rc=$?
    if (( source_rc != 0 )) \
      || (( ! ${+functions[$function_name]} )); then
      # Restore the stub so a transient or repaired load failure can be retried.
      functions[$function_name]='_zdx_lazy_dispatch "${funcstack[1]}" "$@"'
      (( source_rc == 0 )) && source_rc=1
      print -u2 -r -- \
        "zdx: failed to load ${(V)function_name} from ${(V)file_name}"
      return $source_rc
    fi
    "$function_name" "$@"
  }

  typeset _zdx_lazy_name
  for _zdx_lazy_name in ${(k)_ZDX_LAZY_FILES}; do
    functions[$_zdx_lazy_name]='_zdx_lazy_dispatch "${funcstack[1]}" "$@"'
  done
  unset _zdx_lazy_name

  # Eagerly register aliases that point to lazy-loaded functions
  alias wsj='zdir'
fi

unset _zdx_core_dir _zdx_eager_load

# --- Safe Plugin Loader ------------------------------------------------------
# Scans external directories under ~/.config/zdx/plugins/ and sources
# their entrypoint scripts safely.
typeset -a ZDX_LOADED_PLUGINS
ZDX_LOADED_PLUGINS=()

_zdx_plugin_root_safe() {
  local plugins_dir="$1"

  [[ -d "$plugins_dir" && ! -L "$plugins_dir" && -O "$plugins_dir" \
    && "${plugins_dir:a}" == "${plugins_dir:A}" ]]
}

_zdx_plugin_entrypoint_safe() {
  local plugins_dir="$1"
  local plugin_dir="$2"
  local menu_file="$3"
  local plugins_abs="${plugins_dir:A}"
  local plugin_abs="${plugin_dir:A}"
  local menu_abs="${menu_file:A}"
  local -A menu_state=()

  zmodload zsh/stat 2>/dev/null \
    && zstat -H menu_state "$menu_file" 2>/dev/null \
    && _zdx_plugin_root_safe "$plugins_dir" \
    && [[ -d "$plugin_dir" && ! -L "$plugin_dir" && -O "$plugin_dir" \
      && "${plugin_dir:a}" == "$plugin_abs" \
      && "${plugin_abs:h}" == "$plugins_abs" \
      && -f "$menu_file" && ! -L "$menu_file" && -O "$menu_file" \
      && -r "$menu_file" && "${menu_file:a}" == "$menu_abs" \
      && "${menu_abs:h}" == "$plugin_abs" ]] \
    && (( menu_state[nlink] == 1 ))
}

_zdx_load_plugins() {
  local plugins_dir="${ZDX_PLUGINS_DIR:-$HOME/.config/zdx/plugins}"
  [[ -d "$plugins_dir" ]] || return 0
  _zdx_plugin_root_safe "$plugins_dir" || {
    print -u2 -r -- \
      "zdx: refusing unsafe plugin root ${(V)plugins_dir}"
    return 0
  }

  local plugin_dir plugin_name menu_file
  for plugin_dir in "$plugins_dir"/*(N/); do
    plugin_name="${plugin_dir:t}"
    if [[ "$plugin_name" =~ ^[a-z0-9_-]+$ ]]; then
      menu_file="$plugin_dir/${plugin_name}-menu.zsh"
      if [[ -e "$menu_file" || -L "$menu_file" ]]; then
        _zdx_plugin_entrypoint_safe \
          "$plugins_dir" "$plugin_dir" "$menu_file" || {
          print -u2 -r -- \
            "zdx: refusing unsafe plugin entrypoint '${plugin_name}'"
          continue
        }
        if ! command zsh -n -- "$menu_file"; then
          print -u2 -r -- \
            "zdx: failed to load plugin '${plugin_name}' (invalid Zsh syntax)"
          continue
        fi
        # Repeat the path boundary after validation, immediately before source.
        _zdx_plugin_entrypoint_safe \
          "$plugins_dir" "$plugin_dir" "$menu_file" || {
          print -u2 -r -- \
            "zdx: plugin '${plugin_name}' changed during validation"
          continue
        }
        if source "$menu_file"; then
          if (( ${+functions[${plugin_name}-menu]} )); then
            ZDX_LOADED_PLUGINS+=("$plugin_name")
          else
            print -u2 -r -- \
              "zdx: plugin '${plugin_name}' loaded but failed to define function '${plugin_name}-menu'"
          fi
        else
          print -u2 -r -- \
            "zdx: failed to load plugin '${plugin_name}'"
        fi
      fi
    fi
  done
}
_zdx_load_plugins

# --- Timing & Telemetry Helpers ----------------------------------------------

# Measures wall-clock duration of any command, logs it, and aggregates it
# to a local-only JSON log at ~/.config/zdx/telemetry.json if opted in.

# Ensure zsh/datetime is loaded for EPOCHREALTIME
zmodload zsh/datetime 2>/dev/null

_tk_date_iso8601() {
  if zmodload zsh/datetime 2>/dev/null; then
    local tz
    tz=$(strftime "%z" $EPOCHSECONDS)
    if [[ "$tz" == "Z" ]]; then
      strftime "%Y-%m-%dT%H:%M:%SZ" $EPOCHSECONDS
    elif [[ "$tz" =~ '^([+-][0-9]{2})([0-9]{2})$' ]]; then
      local hours="${match[1]}"
      local mins="${match[2]}"
      local base
      base=$(strftime "%Y-%m-%dT%H:%M:%S" $EPOCHSECONDS)
      echo "${base}${hours}:${mins}"
    else
      strftime "%Y-%m-%dT%H:%M:%S%z" $EPOCHSECONDS
    fi
  else
    date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S"
  fi
}

_zdx_telemetry_dir_safe() {
  local target_dir="$1"
  local home_abs="${HOME:A}"
  local relative_dir="${target_dir#$HOME/}"
  local current_dir="$HOME"
  local component

  [[ "$target_dir" == "$HOME"/* && -n "$relative_dir" ]] || return 1
  for component in "${(@s:/:)relative_dir}"; do
    [[ -n "$component" && "$component" != "." && "$component" != ".." ]] \
      || return 1
    current_dir+="/$component"
    [[ ! -L "$current_dir" ]] || return 1
    if [[ -e "$current_dir" ]]; then
      [[ -d "$current_dir" && -O "$current_dir" ]] || return 1
    fi
  done
  [[ "${target_dir:A}" == "$home_abs"/* ]]
}

_log_telemetry() {
  setopt LOCAL_OPTIONS PIPE_FAIL
  local label="$1"
  local elapsed="$2"
  local exit_code="$3"

  local log_dir="$HOME/.config/zdx"
  local log_file="$log_dir/telemetry.json"
  local lock_dir="$log_dir/.telemetry.lock"
  local max_records="${ZDX_TELEMETRY_MAX_RECORDS:-1000}"
  local max_bytes="${ZDX_TELEMETRY_MAX_BYTES:-5242880}"

  [[ "$max_records" =~ '^[0-9]+$' \
    && "$max_records" != 0[0-9]* \
    && ${#max_records} -le 7 ]] \
    && (( max_records > 0 && max_records <= 1000000 )) || return 1
  [[ "$max_bytes" =~ '^[0-9]+$' \
    && "$max_bytes" != 0[0-9]* \
    && ${#max_bytes} -le 9 ]] \
    && (( max_bytes > 0 && max_bytes <= 134217728 )) || return 1
  [[ "$elapsed" =~ '^[0-9]{1,8}([.][0-9]{1,9})?$' ]] || return 1
  [[ "$elapsed" != 0[0-9]* ]] || return 1

  # ISO-8601 UTC timestamp
  local timestamp
  if zmodload zsh/datetime 2>/dev/null; then
    timestamp=$(TZ=UTC strftime "%Y-%m-%dT%H:%M:%SZ" $EPOCHSECONDS)
  else
    if command -v date >/dev/null 2>&1; then
      timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
    fi
    timestamp="${timestamp:-$(date)}"
  fi


  # Calculate duration in ms
  local elapsed_ms
  elapsed_ms=$(printf "%.0f" $(( elapsed * 1000 )))

  # Infer suite from label (e.g., "sys:update-system")
  local suite="unknown"
  if [[ "$label" == *":"* ]]; then
    suite="${label%%:*}"
    label="${label#*:}"
  else
    # Fallback heuristics
    if [[ "$label" == vpn-* || "$label" == _vpn_* ]]; then
      suite="vpn"
    elif [[ "$label" == ws-* || "$label" == _ws_* ]]; then
      suite="ws"
    elif [[ "$label" == git-* || "$label" == _git_* ]]; then
      suite="git"
    elif [[ "$label" == sys-* || "$label" == _sys_* ]]; then
      suite="sys"
    elif [[ "$label" == dev-* || "$label" == _dev_* ]]; then
      suite="dev"
    elif [[ "$label" == gcp-* || "$label" == _gcp_* ]]; then
      suite="gcp"
    elif [[ "$label" == bq-* || "$label" == _bq_* ]]; then
      suite="bq"
    elif [[ "$label" == gcs-* || "$label" == _gcs_* ]]; then
      suite="gcs"
    fi
  fi

  # Telemetry identifiers are deliberately narrow: arguments, paths, URLs,
  # environment values, and command output never belong in this record.
  [[ "$suite" =~ '^[[:alnum:]_-]{1,32}$' ]] || return 1
  [[ "$label" =~ '^[[:alnum:]_.:@+-]{1,96}$' ]] || return 1
  [[ "$elapsed_ms" =~ '^[0-9]+$' \
    && ${#elapsed_ms} -le 11 \
    && "$elapsed_ms" -le 31536000000 ]] || return 1
  [[ "$exit_code" =~ '^[0-9]+$' \
    && "$exit_code" != 0[0-9]* ]] \
    && (( exit_code <= 255 )) || return 1
  [[ "$timestamp" =~ '^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$' ]] \
    || return 1

  local previous_umask
  previous_umask=$(umask)
  local telemetry_tmp=""
  local telemetry_trim=""
  local -i lock_acquired=0 write_rc=0

  {
    umask 077
    _zdx_telemetry_dir_safe "$log_dir" || return 1
    if [[ -e "$log_dir" ]]; then
      [[ -d "$log_dir" && ! -L "$log_dir" && -O "$log_dir" ]] || return 1
    else
      command mkdir -p "$log_dir" 2>/dev/null || return 1
    fi
    _zdx_telemetry_dir_safe "$log_dir" || return 1
    command chmod 700 "$log_dir" 2>/dev/null || return 1

    command mkdir "$lock_dir" 2>/dev/null || return 1
    lock_acquired=1

    if [[ -e "$log_file" ]]; then
      [[ -f "$log_file" && ! -L "$log_file" && -O "$log_file" ]] || return 1
      local existing_bytes
      existing_bytes=$(command wc -c < "$log_file" 2>/dev/null) || return 1
      existing_bytes="${existing_bytes//[[:space:]]/}"
      [[ "$existing_bytes" =~ '^[0-9]+$' \
        && ${#existing_bytes} -le 9 ]] \
        && (( existing_bytes <= max_bytes )) || return 1
    fi

    telemetry_tmp=$(mktemp "$log_dir/.telemetry.XXXXXX") || return 1
    command chmod 600 "$telemetry_tmp" 2>/dev/null || return 1

    if [[ -s "$log_file" ]]; then
      local final_newline_count
      final_newline_count=$(
        command tail -c 1 "$log_file" 2>/dev/null | command wc -l
      ) || return 1
      final_newline_count="${final_newline_count//[[:space:]]/}"
      if [[ "$final_newline_count" == "1" ]]; then
        command tail -n $(( max_records - 1 )) "$log_file" \
          > "$telemetry_tmp" 2>/dev/null || return 1
      else
        # A crash may leave one partial JSON line. Never join a new record to
        # that fragment; retain only preceding complete records.
        command sed '$d' "$log_file" 2>/dev/null \
          | command tail -n $(( max_records - 1 )) \
            > "$telemetry_tmp" 2>/dev/null || return 1
      fi
    fi
    printf '{"suite": "%s", "command": "%s", "duration_ms": %d, "exit_code": %d, "timestamp": "%s"}\n' \
      "$suite" "$label" "$elapsed_ms" "$exit_code" "$timestamp" \
      >> "$telemetry_tmp" || return 1

    local pending_bytes
    pending_bytes=$(command wc -c < "$telemetry_tmp" 2>/dev/null) || return 1
    pending_bytes="${pending_bytes//[[:space:]]/}"
    [[ "$pending_bytes" =~ '^[0-9]+$' ]] || return 1
    if (( pending_bytes > max_bytes )); then
      telemetry_trim=$(mktemp "$log_dir/.telemetry-trim.XXXXXX") || return 1
      command chmod 600 "$telemetry_trim" 2>/dev/null || return 1
      command tail -c "$(( max_bytes + 1 ))" "$telemetry_tmp" 2>/dev/null \
        | command sed '1d' > "$telemetry_trim" || return 1
      [[ -s "$telemetry_trim" ]] || return 1
      pending_bytes=$(command wc -c < "$telemetry_trim" 2>/dev/null) \
        || return 1
      pending_bytes="${pending_bytes//[[:space:]]/}"
      [[ "$pending_bytes" =~ '^[0-9]+$' ]] \
        && (( pending_bytes <= max_bytes )) || return 1
      command mv -f "$telemetry_trim" "$telemetry_tmp" 2>/dev/null \
        || return 1
      telemetry_trim=""
    fi

    command mv -f "$telemetry_tmp" "$log_file" 2>/dev/null || return 1
    telemetry_tmp=""
    command chmod 600 "$log_file" 2>/dev/null || return 1
  } always {
    write_rc=$?
    [[ -n "$telemetry_tmp" && -f "$telemetry_tmp" ]] \
      && command rm -f "$telemetry_tmp" 2>/dev/null
    [[ -n "$telemetry_trim" && -f "$telemetry_trim" ]] \
      && command rm -f "$telemetry_trim" 2>/dev/null
    (( lock_acquired )) && command rmdir "$lock_dir" 2>/dev/null
    umask "$previous_umask"
  }

  return $write_rc
}

_zdx_timed_mark_partial() {
  (( ${+_ZDX_TIMED_OUTCOME} )) || return 1
  _ZDX_TIMED_OUTCOME="partial"
}

_timed() {
  local label="$1"
  shift
  local _ZDX_TIMED_OUTCOME=""

  local start_time=$EPOCHREALTIME
  if [[ -z "$start_time" ]]; then
    start_time=$(date +%s)
  fi

  "$@"
  local exit_code=$?

  local end_time=$EPOCHREALTIME
  if [[ -z "$end_time" ]]; then
    end_time=$(date +%s)
  fi

  local elapsed
  elapsed=$(( end_time - start_time ))
  local elapsed_str
  elapsed_str=$(printf "%.1f" $elapsed)

  # Print a status-aware timing message in dim gray.
  local timing_message
  if (( exit_code == 0 )); then
    timing_message="${(V)label} completed in ${elapsed_str}s"
  elif [[ "$_ZDX_TIMED_OUTCOME" == "partial" ]]; then
    timing_message="${(V)label} completed with partial failures in ${elapsed_str}s (status $exit_code)"
  else
    timing_message="${(V)label} failed after ${elapsed_str}s (status $exit_code)"
  fi

  if [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
    printf '\033[0;90m  %s\033[0m\n' "$timing_message" >&2
  else
    printf '  %s\n' "$timing_message" >&2
  fi

  # Log to telemetry if user has opted in
  if [[ "${ZDX_TELEMETRY:-}" == "1" || "${ZDX_TELEMETRY:-}" == "true" ]]; then
    local telemetry_elapsed
    printf -v telemetry_elapsed '%.9f' "$elapsed"
    _log_telemetry "$label" "$telemetry_elapsed" "$exit_code"
  fi

  return $exit_code
}

# --- Safe User Overrides Loader ----------------------------------------------
# Safely sources user-defined overrides that take precedence over core functions
if [[ -f "$HOME/.config/zdx/overrides.zsh" && -r "$HOME/.config/zdx/overrides.zsh" ]]; then
  source "$HOME/.config/zdx/overrides.zsh" || {
    typeset -i _zdx_overrides_rc=$?
    print -u2 -r -- "zdx: failed to load user overrides"
    {
      return $_zdx_overrides_rc 2>/dev/null || exit $_zdx_overrides_rc
    } always {
      unset _zdx_overrides_rc
    }
  }
fi

typeset -g _ZDX_FUNCTIONS_SOURCED=1
