#!/usr/bin/env zsh
# =============================================================================
# Docker Common: shared context, records, prompts, capture, and dispatch
# =============================================================================
#
# Loaded by docker-menu.zsh before every module under functions/docker/.
# Private helpers only; not a standalone public command.
#

if [[ -n "${_DOCKER_COMMON_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset -gi _DOCKER_MAX_PICKER_BYTES=1048576
typeset -gi _DOCKER_MAX_RECORDS=2048

# --- UI ----------------------------------------------------------------------

_docker_color_enabled() {
  [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" && -t 2 ]]
}

_docker_log() {
  local level="$1"
  local message="${2:-}"
  local color="" marker=""

  case "$level" in
    success) color='1;32'; marker='OK' ;;
    warn)    color='1;33'; marker='WARN' ;;
    info)    color='0;36'; marker='INFO' ;;
    error)   color='1;31'; marker='ERROR' ;;
    dim)     color='0;90'; marker='·' ;;
    *)       color='0'; marker='INFO' ;;
  esac

  if _docker_color_enabled; then
    printf '\033[%sm%s\033[0m %s\n' \
      "$color" "$marker" "${(V)message}" >&2
  else
    printf '%s %s\n' "$marker" "${(V)message}" >&2
  fi
}

_docker_header() {
  local title="${1:-Docker}"
  print -u2 -r -- ""
  if _docker_color_enabled; then
    printf '\033[1;35m════ %s ════\033[0m\n' "${(V)title}" >&2
  else
    printf '════ %s ════\n' "${(V)title}" >&2
  fi
  print -u2 -r -- ""
}

_docker_success() { _docker_log success "${1:-}"; }
_docker_warn()    { _docker_log warn "${1:-}"; }
_docker_info()    { _docker_log info "${1:-}"; }
_docker_error()   { _docker_log error "${1:-}"; }
_docker_dim()     { _docker_log dim "${1:-}"; }

_docker_visible_safe() {
  local value="${1:-}"
  local -i maximum="${2:-1024}"
  (( ${#value} <= maximum )) \
    && [[ "$value" != *$'\n'* && "$value" != *$'\r'* \
      && "$value" != *$'\t'* && "$value" != *[[:cntrl:]]* ]]
}

_docker_confirm() {
  local prompt="${1:-Continue?}"
  [[ -t 0 && -t 2 ]] || return 2

  if _docker_color_enabled; then
    printf '\033[1;33m? %s [y/N]: \033[0m' "${(V)prompt}" >&2
  else
    printf '? %s [y/N]: ' "${(V)prompt}" >&2
  fi

  local answer=""
  IFS= read -r answer || {
    print -u2 -r -- ""
    return 2
  }
  print -u2 -r -- ""
  [[ "$answer" =~ '^[Yy]$' ]] && return 0
  return 130
}

# --- Dependencies and bounded probes ----------------------------------------

_docker_require_cmd() {
  local command_name="$1"
  local purpose="${2:-this Docker workflow}"
  command -v "$command_name" &>/dev/null && return 0
  _docker_error "$command_name is required for $purpose."
  return 1
}

_docker_timeout_command() {
  reply=()
  if command -v timeout &>/dev/null; then
    reply=(timeout)
  elif command -v gtimeout &>/dev/null; then
    reply=(gtimeout)
  fi
  (( ${#reply[@]} > 0 ))
}

_docker_run_probe() {
  local -i seconds="$1"
  shift
  local -a probe_command=("$@")
  local -a timeout_command=()

  (( seconds >= 1 && seconds <= 60 && ${#probe_command[@]} > 0 )) \
    || return 2
  _docker_timeout_command || {
    _docker_error \
      "A timeout or gtimeout command is required for bounded Docker probes."
    return 1
  }
  timeout_command=("${reply[@]}")
  command "${timeout_command[@]}" -k 2s "${seconds}s" "${probe_command[@]}"
}

# Executes a read-only probe while bounding bytes before shell materialization.
# REPLY contains stdout only when the complete probe succeeds within the limit.
_docker_capture_probe_bounded() {
  emulate -L zsh
  setopt LOCAL_OPTIONS PIPE_FAIL
  unsetopt MULTIBYTE MULTIOS
  local -i maximum_bytes="$1"
  local -i seconds="$2"
  shift 2
  (( maximum_bytes >= 1 && maximum_bytes <= 16 * 1024 * 1024 )) || return 2
  local captured_with_status=""
  captured_with_status=$(
    _docker_run_probe "$seconds" "$@" \
      | command head -c $(( maximum_bytes + 1 ))
    local -a probe_status=("${pipestatus[@]}")
    printf 'ZDXRC%08x%08x' \
      "${probe_status[1]:-255}" "${probe_status[2]:-255}"
  )
  local -i substitution_rc=$?
  local -i status_length=21
  local -i captured_length=${#captured_with_status}
  (( substitution_rc == 0 && captured_length >= status_length )) || {
    REPLY=""
    (( substitution_rc == 130 || substitution_rc == 143 )) && return $substitution_rc
    return 1
  }

  local -i payload_length=$(( captured_length - status_length ))
  local status_suffix="${captured_with_status[$(( payload_length + 1 )),-1]}"
  [[ "$status_suffix" =~ '^ZDXRC[0-9a-f]{16}$' ]] || {
    REPLY=""
    return 1
  }
  local probe_hex="${status_suffix[6,13]}"
  local head_hex="${status_suffix[14,21]}"
  local -i probe_rc=$(( 16#$probe_hex ))
  local -i head_rc=$(( 16#$head_hex ))
  local captured_output=""
  (( payload_length == 0 )) \
    || captured_output="${captured_with_status[1,$payload_length]}"
  (( probe_rc == 0 && head_rc == 0 \
    && payload_length <= maximum_bytes )) || {
    REPLY=""
    (( probe_rc == 130 || probe_rc == 143 )) && return $probe_rc
    (( head_rc == 130 || head_rc == 143 )) && return $head_rc
    return 1
  }
  while [[ "$captured_output" == *$'\n' ]]; do
    captured_output="${captured_output%$'\n'}"
  done
  REPLY="$captured_output"
}

# Executes a read-only probe while bounding stderr before shell materialization.
# REPLY contains stderr only when the complete probe succeeds within the limit.
_docker_capture_probe_stderr_bounded() {
  emulate -L zsh
  setopt LOCAL_OPTIONS PIPE_FAIL
  unsetopt MULTIBYTE MULTIOS
  local -i maximum_bytes="$1"
  local -i seconds="$2"
  shift 2
  (( maximum_bytes >= 1 && maximum_bytes <= 16 * 1024 * 1024 )) || return 2
  local captured_with_status=""
  captured_with_status=$(
    _docker_run_probe "$seconds" "$@" 2>&1 >/dev/null \
      | command head -c $(( maximum_bytes + 1 ))
    local -a probe_status=("${pipestatus[@]}")
    printf 'ZDXRC%08x%08x' \
      "${probe_status[1]:-255}" "${probe_status[2]:-255}"
  )
  local -i substitution_rc=$?
  local -i status_length=21
  local -i captured_length=${#captured_with_status}
  (( substitution_rc == 0 && captured_length >= status_length )) || {
    REPLY=""
    (( substitution_rc == 130 || substitution_rc == 143 )) && return $substitution_rc
    return 1
  }

  local -i payload_length=$(( captured_length - status_length ))
  local status_suffix="${captured_with_status[$(( payload_length + 1 )),-1]}"
  [[ "$status_suffix" =~ '^ZDXRC[0-9a-f]{16}$' ]] || {
    REPLY=""
    return 1
  }
  local probe_hex="${status_suffix[6,13]}"
  local head_hex="${status_suffix[14,21]}"
  local -i probe_rc=$(( 16#$probe_hex ))
  local -i head_rc=$(( 16#$head_hex ))
  local captured_output=""
  (( payload_length == 0 )) \
    || captured_output="${captured_with_status[1,$payload_length]}"
  (( probe_rc == 0 && head_rc == 0 \
    && payload_length <= maximum_bytes )) || {
    REPLY=""
    (( probe_rc == 130 || probe_rc == 143 )) && return $probe_rc
    (( head_rc == 130 || head_rc == 143 )) && return $head_rc
    return 1
  }
  while [[ "$captured_output" == *$'\n' ]]; do
    captured_output="${captured_output%$'\n'}"
  done
  REPLY="$captured_output"
}

_docker_sha256_text() {
  local input_text="$1"
  REPLY=""
  local digest_output=""
  if command -v sha256sum &>/dev/null; then
    digest_output=$(printf '%s' "$input_text" | command sha256sum) \
      || {
        local -i digest_rc=$?
        (( digest_rc == 130 || digest_rc == 143 )) && return $digest_rc
        return 1
      }
  elif command -v shasum &>/dev/null; then
    digest_output=$(printf '%s' "$input_text" | command shasum -a 256) \
      || {
        local -i digest_rc=$?
        (( digest_rc == 130 || digest_rc == 143 )) && return $digest_rc
        return 1
      }
  else
    _docker_error "sha256sum or shasum is required for identity checks."
    return 1
  fi
  local digest="${digest_output%%[[:space:]]*}"
  digest="${digest:l}"
  [[ "$digest" =~ '^[0-9a-f]{64}$' ]] || return 1
  REPLY="$digest"
}

_docker_context_name_valid() {
  local context_name="${1:-}"
  (( ${#context_name} >= 1 && ${#context_name} <= 255 )) \
    && [[ "$context_name" != -* \
      && "$context_name" =~ '^[A-Za-z0-9][A-Za-z0-9_.+-]*$' ]]
}

_docker_config_json_object_valid() {
  local config_file="${1:-}"
  [[ -f "$config_file" && ! -L "$config_file" ]] || return 1
  command -v jq &>/dev/null || {
    _docker_error "jq is required to validate Docker config.json safely."
    return 1
  }
  command jq -e -s \
    'length == 1 and (.[0] | type == "object")' \
    -- "$config_file" >/dev/null 2>&1 || {
    _docker_error "Docker config.json is not one valid JSON object."
    return 1
  }
}

_docker_config_cli_valid() {
  local config_dir="${1:-}"
  local config_file="$config_dir/config.json"
  [[ -e "$config_file" || -L "$config_file" ]] || return 0

  _docker_capture_probe_stderr_bounded 8192 5 \
    docker --config "$config_dir" context show || {
    local -i probe_rc=$?
    _docker_error "Docker could not parse config.json safely."
    return $probe_rc
  }
  [[ -z "$REPLY" ]] || {
    _docker_error "Docker reported an invalid or unsafe config.json."
    return 1
  }
}

_docker_config_dir_safe() {
  emulate -L zsh
  REPLY=""
  zmodload zsh/stat 2>/dev/null || return 1

  local home_dir="${HOME:-}"
  [[ -n "$home_dir" && "$home_dir" == /* \
    && "$home_dir" != "/" \
    && -d "$home_dir" && ! -L "$home_dir" \
    && "$home_dir" == "${home_dir:a}" \
    && "$home_dir" == "${home_dir:A}" ]] || return 1

  local config_dir="${DOCKER_CONFIG:-$home_dir/.docker}"
  _docker_visible_safe "$config_dir" 4096 \
    && [[ -n "$config_dir" && "$config_dir" == /* \
      && "$config_dir" != "/" \
      && "$config_dir" == "${config_dir:a}" \
      && "$config_dir" == "${config_dir:A}" \
      && "$config_dir" == "$home_dir"/* ]] || return 1

  if [[ -e "$config_dir" || -L "$config_dir" ]]; then
    [[ -d "$config_dir" && ! -L "$config_dir" ]] || return 1
    local -A config_state=()
    zstat -LH config_state -- "$config_dir" 2>/dev/null || return 1
    (( (config_state[mode] & 8#170000) == 8#040000 \
      && config_state[uid] == EUID \
      && (config_state[mode] & 8#777) == 8#700 )) || return 1
  else
    local parent_dir="${config_dir:h}"
    [[ -d "$parent_dir" && ! -L "$parent_dir" \
      && "$parent_dir" == "${parent_dir:A}" ]] || return 1
    local -A parent_state=()
    zstat -LH parent_state -- "$parent_dir" 2>/dev/null || return 1
    (( (parent_state[mode] & 8#170000) == 8#040000 \
      && parent_state[uid] == EUID \
      && (parent_state[mode] & 8#22) == 0 )) || return 1
  fi
  _docker_validate_ancestor_chain "$config_dir" || return 1

  local config_file="$config_dir/config.json"
  if [[ -e "$config_file" || -L "$config_file" ]]; then
    [[ -f "$config_file" && ! -L "$config_file" \
      && "$config_file" == "${config_file:A}" ]] || return 1
    local -A file_state=()
    zstat -LH file_state -- "$config_file" 2>/dev/null || return 1
    (( (file_state[mode] & 8#170000) == 8#100000 \
      && file_state[uid] == EUID \
      && file_state[nlink] == 1 \
      && (file_state[mode] & 8#777) == 8#600 \
      && file_state[size] >= 0 \
      && file_state[size] <= 1024 * 1024 )) || return 1
    _docker_config_json_object_valid "$config_file" || return 1
  fi

  REPLY="$config_dir"
}

_docker_config_dir_ensure() {
  _docker_config_dir_safe || return 1
  local config_dir="$REPLY"
  if [[ ! -e "$config_dir" && ! -L "$config_dir" ]]; then
    (umask 077; command mkdir -m 700 -- "$config_dir") 2>/dev/null || {
      _docker_error "Could not create the private Docker config directory."
      return 1
    }
  fi
  _docker_config_dir_safe || {
    _docker_error "The Docker config directory failed creation validation."
    return 1
  }
  REPLY="$config_dir"
}

_docker_client_command() {
  reply=()
  _docker_config_dir_safe || {
    _docker_error \
      "Refusing an unsafe Docker client configuration directory or file."
    return 1
  }
  local config_dir="$REPLY"
  _docker_config_cli_valid "$config_dir" || return $?
  reply=(docker --config "$config_dir")
}

# `reply` becomes:
#   mode selector endpoint daemon-id server-version locality
# mode is `context` or `host`; locality is `local` or `remote`.
_docker_context_snapshot() {
  reply=()
  _docker_require_cmd docker "Docker commands" || return 1
  _docker_client_command || return $?
  local -a client_command=("${reply[@]}")

  local mode="" selector="" endpoint=""
  if [[ -n "${DOCKER_CONTEXT:-}" ]]; then
    mode="context"
    selector="$DOCKER_CONTEXT"
  elif [[ -n "${DOCKER_HOST:-}" ]]; then
    mode="host"
    selector="$DOCKER_HOST"
    endpoint="$DOCKER_HOST"
  else
    mode="context"
    _docker_capture_probe_bounded 256 5 \
      "${client_command[@]}" context show 2>/dev/null || {
      local -i probe_rc=$?
      _docker_error "Could not resolve the active Docker context."
      return $probe_rc
    }
    selector="$REPLY"
  fi

  _docker_visible_safe "$selector" 2048 && [[ -n "$selector" ]] || {
    _docker_error "The active Docker selector is malformed."
    return 1
  }

  if [[ "$mode" == "context" ]]; then
    _docker_context_name_valid "$selector" || {
      _docker_error "The active Docker context name is malformed."
      return 1
    }
    _docker_capture_probe_bounded 2048 5 \
      "${client_command[@]}" context inspect \
      --format '{{(index .Endpoints "docker").Host}}' \
      -- "$selector" 2>/dev/null || {
      local -i probe_rc=$?
      _docker_error "Could not inspect Docker context ${(V)selector}."
      return $probe_rc
    }
    endpoint="$REPLY"
  fi
  _docker_visible_safe "$endpoint" 2048 && [[ -n "$endpoint" ]] || {
    _docker_error "The Docker endpoint is malformed or unavailable."
    return 1
  }

  _docker_context_command "$mode" "$selector" || return $?
  local -a docker_command=("${reply[@]}")
  local daemon_id="" server_version=""
  _docker_capture_probe_bounded 256 8 "${docker_command[@]}" info \
    --format '{{.ID}}' 2>/dev/null || {
    local -i probe_rc=$?
    _docker_error "Cannot connect to Docker via ${(V)selector}."
    return $probe_rc
  }
  daemon_id="$REPLY"
  _docker_capture_probe_bounded 128 8 "${docker_command[@]}" version \
    --format '{{.Server.Version}}' 2>/dev/null || {
    local -i probe_rc=$?
    _docker_error "Could not query the Docker server version."
    return $probe_rc
  }
  server_version="$REPLY"
  _docker_visible_safe "$daemon_id" 256 && [[ -n "$daemon_id" ]] \
    && _docker_visible_safe "$server_version" 128 \
    && [[ -n "$server_version" ]] || {
    _docker_error "Docker returned malformed daemon identity data."
    return 1
  }

  local locality="remote"
  case "$endpoint" in
    unix://*|npipe://*|/*) locality="local" ;;
  esac
  reply=("$mode" "$selector" "$endpoint" "$daemon_id" \
    "$server_version" "$locality")
}

_docker_context_command() {
  local mode="$1"
  local selector="$2"
  _docker_client_command || return $?
  local -a client_command=("${reply[@]}")
  case "$mode" in
    context) reply=("${client_command[@]}" --context "$selector") ;;
    host)    reply=("${client_command[@]}" --host "$selector") ;;
    *)       return 2 ;;
  esac
}

_docker_context_revalidate() {
  local -a expected=("$@")
  (( ${#expected[@]} == 6 )) || return 2
  _docker_context_snapshot || return $?
  local -a current=("${reply[@]}")
  local -i index=0
  for (( index = 1; index <= 6; index++ )); do
    [[ "${current[index]}" == "${expected[index]}" ]] || {
      _docker_error "Docker context or daemon identity changed after review."
      return 1
    }
  done
  reply=("${current[@]}")
}

_docker_context_label() {
  local -a context_snapshot=("$@")
  (( ${#context_snapshot[@]} == 6 )) || return 2
  REPLY="${context_snapshot[2]} | ${context_snapshot[3]} | "\
"${context_snapshot[6]} | engine ${context_snapshot[5]}"
}

_docker_require_mutation_context() {
  local locality="$1"
  local -i allow_remote="${2:-0}"
  if [[ "$locality" == "remote" && allow_remote -ne 1 ]]; then
    _docker_error \
      "Refusing to mutate a remote Docker endpoint without --allow-remote."
    return 1
  fi
}

_docker_diagnose() {
  _docker_error "Cannot connect to the selected Docker daemon."
  _docker_info "Verify the active Docker context or DOCKER_HOST."
  if ! command -v docker &>/dev/null; then
    _docker_dim "The docker command is not installed or is not in PATH."
    return 1
  fi
  _docker_dim "Run: docker context show"
  _docker_dim "Run: docker context inspect <context>"
  _docker_dim "Run: docker info"
  return 1
}

_docker_require_daemon() {
  _docker_context_snapshot || {
    _docker_diagnose
    return 1
  }
}

# --- Menu records and foreground fzf capture --------------------------------

_docker_menu_section() {
  local title="$1"
  local description="${2:-}"
  if [[ "$title" == *'|'* || "$description" == *'|'* ]] \
    || ! _docker_visible_safe "$title" 256 \
    || ! _docker_visible_safe "$description" 1024; then
    _docker_error "Invalid Docker menu section fields."
    return 2
  fi
  printf '── %s ──|:|%s\n' "$title" "$description"
}

_docker_menu_entry() {
  local label="$1"
  local command_name="$2"
  local description="$3"
  if [[ "$label" == *'|'* || "$command_name" == *'|'* \
    || "$description" == *'|'* ]] \
    || ! _docker_visible_safe "$label" 256 \
    || ! _docker_visible_safe "$command_name" 128 \
    || ! _docker_visible_safe "$description" 1024 \
    || [[ ! "$command_name" =~ '^[a-z][a-z0-9-]*$' ]]; then
    _docker_error "Invalid Docker menu entry fields."
    return 2
  fi
  printf '  %s|%s|%s\n' "$label" "$command_name" "$description"
}

_docker_array_contains_literal() {
  local needle="${1-}" candidate=""
  shift 2>/dev/null || return 2
  for candidate in "$@"; do
    [[ "$candidate" == "$needle" ]] && return 0
  done
  return 1
}

_docker_fzf() {
  local -a fzf_options=(
    --height=80%
    --layout=reverse
    --border=rounded
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

_docker_system_root_uid() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local -A root_state=()
  [[ -d / && ! -L / ]] \
    && zstat -LH root_state -- / 2>/dev/null \
    && (( (root_state[mode] & 8#170000) == 8#040000 )) || return 1
  REPLY="${root_state[uid]}"
}

_docker_validate_ancestor_chain() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local child_path="${1:-}"
  [[ "$child_path" == /* && "$child_path" == "${child_path:A}" ]] || return 1

  _docker_system_root_uid || return 1
  local -i system_root_uid=$REPLY
  local parent_path=""
  local -A parent_state=()
  while [[ "$child_path" != "/" ]]; do
    parent_path="${child_path:h}"
    parent_state=()
    [[ -d "$parent_path" && ! -L "$parent_path" ]] \
      && zstat -LH parent_state -- "$parent_path" 2>/dev/null || return 1
    if (( (parent_state[uid] != system_root_uid \
        && parent_state[uid] != EUID) \
      || ((parent_state[mode] & 8#22) != 0 \
        && ! (parent_state[uid] == system_root_uid \
          && (parent_state[mode] & 8#1000) != 0 \
          && (parent_state[mode] & 8#2) != 0)) )); then
      return 1
    fi
    child_path="$parent_path"
  done
}

_docker_temp_parent_safe() {
  local requested_parent="${1:-/tmp}"
  REPLY=""
  while [[ "$requested_parent" != "/" && "$requested_parent" == */ ]]; do
    requested_parent="${requested_parent%/}"
  done
  [[ -d "$requested_parent" && ! -L "$requested_parent" \
    && "$requested_parent" == /* \
    && "$requested_parent" == "${requested_parent:a}" \
    && "$requested_parent" == "${requested_parent:A}" ]] || return 1

  zmodload zsh/stat 2>/dev/null || return 1
  _docker_system_root_uid || return 1
  local -i system_root_uid=$REPLY
  local -A parent_state=()
  zstat -LH parent_state -- "$requested_parent" 2>/dev/null || return 1
  if (( parent_state[uid] == EUID \
    && (parent_state[mode] & 8#22) == 0 )); then
    :
  elif (( parent_state[uid] == system_root_uid \
    && (parent_state[mode] & 8#1000) != 0 \
    && (parent_state[mode] & 8#2) != 0 )); then
    :
  else
    return 1
  fi
  _docker_validate_ancestor_chain "$requested_parent" || return 1
  REPLY="$requested_parent"
}

_docker_temp_child_state() {
  emulate -L zsh
  local child_path="${1:-}"
  local parent_path="${2:-}"
  local object_kind="${3:-}"
  local name_pattern="${4:-}"
  reply=()

  [[ -n "$child_path" && -n "$parent_path" \
    && "$child_path" == /* \
    && "${child_path:h}" == "$parent_path" \
    && "$child_path" == "${child_path:a}" \
    && "$child_path" == "${child_path:A}" \
    && "${child_path:t}" =~ "$name_pattern" \
    && ! -L "$child_path" ]] || return 1

  local -A child_state=()
  zstat -LH child_state -- "$child_path" 2>/dev/null || return 1
  case "$object_kind" in
    directory)
      [[ -d "$child_path" ]] \
        && (( (child_state[mode] & 8#170000) == 8#040000 \
          && child_state[uid] == EUID \
          && child_state[nlink] >= 1 \
          && (child_state[mode] & 8#777) == 8#700 )) || return 1
      ;;
    file)
      [[ -f "$child_path" ]] \
        && (( (child_state[mode] & 8#170000) == 8#100000 \
          && child_state[uid] == EUID \
          && child_state[nlink] == 1 \
          && (child_state[mode] & 8#777) == 8#600 \
          && child_state[size] == 0 )) || return 1
      ;;
    *) return 2 ;;
  esac
  reply=(
    "${child_state[device]}"
    "${child_state[inode]}"
    "${child_state[uid]}"
    "${child_state[nlink]}"
    "${child_state[mode]}"
  )
}

# Runs fzf synchronously in the foreground and returns its exact status.
# The complete selection is returned through REPLY.
_docker_fzf_capture() {
  emulate -L zsh
  REPLY=""
  zmodload zsh/stat zsh/system 2>/dev/null || {
    _docker_error "Zsh file-descriptor support is required for Docker menus."
    return 125
  }
  _docker_temp_parent_safe "${TMPDIR:-/tmp}" || {
    _docker_error "Refusing an unsafe temporary root for Docker menus."
    return 125
  }
  local temp_parent="$REPLY"

  local capture_dir=""
  capture_dir=$(umask 077; command mktemp -d \
    "$temp_parent/zdx-docker-fzf.XXXXXX" 2>/dev/null) || {
    _docker_error "Could not create a private Docker menu directory."
    return 125
  }
  _docker_temp_child_state "$capture_dir" "$temp_parent" directory \
    '^zdx-docker-fzf[.][A-Za-z0-9]+$' || {
    _docker_error "Refusing an unsafe Docker menu directory."
    return 125
  }

  local capture_file=""
  local selection=""
  local file_identity=""
  local -i write_fd=-1 read_fd=-1
  local -i fzf_rc=125 cleanup_failed=0
  local -A current_state=()
  local directory_identity="${(j.:.)reply}"

  {
    capture_file=$(umask 077; command mktemp \
      "$capture_dir/result.XXXXXX" 2>/dev/null)
    if [[ -z "$capture_file" ]]; then
      _docker_error "Could not create a private Docker menu result."
    elif ! _docker_temp_child_state \
      "$capture_file" "$capture_dir" file \
      '^result[.][A-Za-z0-9]+$'; then
      _docker_error "Refusing an unsafe Docker menu result."
    else
      file_identity="${(j.:.)reply}"
      if ! sysopen -w -o nofollow,cloexec -u write_fd \
        -- "$capture_file" 2>/dev/null; then
        _docker_error "Could not open the Docker menu result safely."
      else
        _docker_fzf "$@" 1>&$(( write_fd ))
        fzf_rc=$?
        exec {write_fd}>&-
        write_fd=-1
        current_state=()
        if ! zstat -LH current_state -- "$capture_file" 2>/dev/null \
          || [[ "${current_state[device]}:${current_state[inode]}:"\
"${current_state[uid]}:${current_state[nlink]}:${current_state[mode]}" \
            != "$file_identity" ]] \
          || (( current_state[size] < 0 \
            || current_state[size] > _DOCKER_MAX_PICKER_BYTES )); then
          _docker_error "The Docker menu result changed or exceeded its limit."
          fzf_rc=125
        elif ! sysopen -r -o nofollow,cloexec -u read_fd \
          -- "$capture_file" 2>/dev/null; then
          _docker_error "Could not read the Docker menu result safely."
          fzf_rc=125
        else
          selection=$(<&$(( read_fd )))
          exec {read_fd}>&-
          read_fd=-1
          if (( fzf_rc != 0 )) && [[ -n "$selection" ]]; then
            _docker_error "A failed Docker picker returned selection data."
            selection=""
            fzf_rc=125
          fi
        fi
      fi
    fi
  } always {
    (( write_fd >= 0 )) && exec {write_fd}>&-
    (( read_fd >= 0 )) && exec {read_fd}>&-
    current_state=()
    if [[ -n "$capture_file" ]] \
      && zstat -LH current_state -- "$capture_file" 2>/dev/null \
      && [[ -f "$capture_file" && ! -L "$capture_file" \
        && "${current_state[device]}:${current_state[inode]}:"\
"${current_state[uid]}:${current_state[nlink]}:${current_state[mode]}" \
        == "$file_identity" ]]; then
      command rm -f -- "$capture_file" 2>/dev/null || cleanup_failed=1
    elif [[ -n "$capture_file" ]]; then
      cleanup_failed=1
    fi
    current_state=()
    if _docker_temp_child_state "$capture_dir" "$temp_parent" directory \
      '^zdx-docker-fzf[.][A-Za-z0-9]+$' \
      && [[ "${(j.:.)reply}" == "$directory_identity" ]]; then
      command rmdir -- "$capture_dir" 2>/dev/null || cleanup_failed=1
    else
      cleanup_failed=1
    fi
  }

  (( cleanup_failed == 0 )) || {
    _docker_error "Could not clean the private Docker menu result."
    return 125
  }
  REPLY="$selection"
  return $fzf_rc
}

_docker_fzf_rc_is_cancel() {
  (( ${1:-0} == 1 || ${1:-0} == 130 ))
}

_docker_menu_header() {
  if _docker_context_snapshot 2>/dev/null; then
    local -a context_snapshot=("${reply[@]}")
    _docker_context_label "${context_snapshot[@]}" || return 1
    printf 'Docker: %s' "$REPLY"
  else
    printf 'Docker daemon unavailable; registry login remains available'
  fi
}

_docker_credentials_configured() {
  local config_file="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
  [[ -f "$config_file" && ! -L "$config_file" && -O "$config_file" \
    && -r "$config_file" && -s "$config_file" ]]
}

# --- Validation shared by feature modules -----------------------------------

_docker_validate_container_id() {
  [[ "${1:-}" =~ '^[0-9a-f]{64}$' ]]
}

_docker_validate_image_id() {
  [[ "${1:-}" =~ '^sha256:[0-9a-f]{64}$' ]]
}

_docker_validate_object_id() {
  [[ "${1:-}" =~ '^[0-9a-f]{12,64}$' ]]
}

_docker_validate_name() {
  local value="${1:-}"
  (( ${#value} >= 1 && ${#value} <= 255 )) \
    && [[ "$value" =~ '^[A-Za-z0-9][A-Za-z0-9_.-]*$' ]]
}

_docker_validate_uint() {
  local value="${1:-}"
  local -i maximum="${2:-1000000}"
  [[ "$value" == <-> && ${#value} -le 18 ]] \
    && (( 10#$value >= 0 && 10#$value <= maximum ))
}

_docker_inventory_limit() {
  local output="${1:-}"
  local -i row_count="${2:-0}"
  (( ${#output} <= _DOCKER_MAX_PICKER_BYTES \
    && row_count <= _DOCKER_MAX_RECORDS ))
}

# --- Explicit public dispatcher ---------------------------------------------

_docker_dispatch() {
  local command_name="${1:-}"
  shift 2>/dev/null || true

  case "$command_name" in
    docker-containers)      docker-containers "$@" ;;
    docker-images)          docker-images "$@" ;;
    docker-clean)           docker-clean "$@" ;;
    docker-login)           docker-login "$@" ;;
    docker-compose-up)      docker-compose-up "$@" ;;
    docker-compose-down)    docker-compose-down "$@" ;;
    docker-compose-restart) docker-compose-restart "$@" ;;
    docker-compose-logs)    docker-compose-logs "$@" ;;
    :)                      return 0 ;;
    "")
      _docker_error "A Docker command is required."
      return 2
      ;;
    *)
      _docker_error "Unknown Docker command: $command_name"
      return 2
      ;;
  esac
}

typeset -g _DOCKER_COMMON_SOURCED=1
