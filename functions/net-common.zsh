#!/usr/bin/env zsh
# =============================================================================
# Network Common: validation, bounded probes, UI, and foreground selection
# =============================================================================
#
# Loaded by net-menu.zsh before every module under functions/net/.
# Private helpers only; not a standalone public command.
#

if [[ -n "${_NET_COMMON_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_net_color_enabled() {
  [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" && -t 2 ]]
}

_net_header() {
  if _net_color_enabled; then
    printf "\n\033[1;35m════ %s ════\033[0m\n\n" "$1" >&2
  else
    printf "\n════ %s ════\n\n" "$1" >&2
  fi
}

_net_success() {
  if _net_color_enabled; then
    printf "\033[1;32m✔ %s\033[0m\n" "$1" >&2
  else
    printf "✔ %s\n" "$1" >&2
  fi
}

_net_warn() {
  if _net_color_enabled; then
    printf "\033[1;33m⚠ %s\033[0m\n" "$1" >&2
  else
    printf "⚠ %s\n" "$1" >&2
  fi
}

_net_info() {
  if _net_color_enabled; then
    printf "\033[0;36m➜ %s\033[0m\n" "$1" >&2
  else
    printf "➜ %s\n" "$1" >&2
  fi
}

_net_error() {
  if _net_color_enabled; then
    printf "\033[1;31m✘ %s\033[0m\n" "$1" >&2
  else
    printf "✘ %s\n" "$1" >&2
  fi
}

_net_dim() {
  if _net_color_enabled; then
    printf "\033[0;90m  %s\033[0m\n" "$1" >&2
  else
    printf "  %s\n" "$1" >&2
  fi
}

_net_label() {
  local label="$1"
  local value="$2"
  if _net_color_enabled; then
    printf "\033[1;35m%-20s\033[0m %s\n" "$label" "$value" >&2
  else
    printf "%-20s %s\n" "$label" "$value" >&2
  fi
}

# stdout: a terminal-safe visible representation of arbitrary data.
_net_display_escape() {
  print -r -- "${(V)1}"
}

_net_visible_value_safe() {
  local value="${1:-}"
  local -i maximum_length="${2:-4096}"
  (( maximum_length >= 1 && maximum_length <= 65536 )) || return 1
  (( ${#value} <= maximum_length )) \
    && [[ "$value" != *[[:cntrl:]]* ]]
}

_net_trim() {
  setopt LOCAL_OPTIONS EXTENDED_GLOB
  REPLY="${${1##[[:space:]]#}%%[[:space:]]#}"
}

# reply: non-empty fields split only on spaces and horizontal tabs.
_net_split_words() {
  local value="${1:-}"
  value="${value//$'\t'/ }"
  reply=("${(@s: :)value}")
  reply=("${(@)reply:#}")
}

_net_valid_uint_range() {
  local value="${1:-}"
  local -i minimum="${2:-0}"
  local -i maximum="${3:-2147483647}"
  [[ ${#value} -le 10 \
    && ( "$value" == "0" || "$value" =~ '^[1-9][0-9]*$' ) ]] || return 1
  local -i numeric_value=$(( 10#$value ))
  (( numeric_value >= minimum && numeric_value <= maximum ))
}

_net_valid_decimal() {
  local value="${1:-}"
  [[ ${#value} -le 24 \
    && "$value" =~ '^[0-9]+([.][0-9]+)?$' ]]
}

_net_valid_ipv4() {
  local value="${1:-}"
  [[ ${#value} -le 15 \
    && "$value" =~ '^[0-9]{1,3}([.][0-9]{1,3}){3}$' ]] || return 1

  local -a octets=("${(@s:.:)value}")
  (( ${#octets[@]} == 4 )) || return 1
  local octet=""
  for octet in "${octets[@]}"; do
    _net_valid_uint_range "$octet" 0 255 || return 1
  done
}

_net_valid_ipv6() {
  local value="${1:-}"
  [[ ${#value} -ge 2 && ${#value} -le 45 \
    && "$value" == *:* \
    && "$value" =~ '^[0-9A-Fa-f:.]+$' \
    && "$value" != *:::* ]] || return 1

  local working="$value"
  if [[ "$working" == *.* ]]; then
    local ipv4_tail="${working##*:}"
    _net_valid_ipv4 "$ipv4_tail" || return 1
    working="${working%:*}:0:0"
  fi
  [[ "$working" != :* || "$working" == ::* ]] || return 1
  [[ "$working" != *: || "$working" == *:: ]] || return 1

  local -i compressed=0
  if [[ "$working" == *::* ]]; then
    compressed=1
    local after_double="${working#*::}"
    [[ "$after_double" != *::* ]] || return 1
  fi

  local -i segments=0
  local segment=""
  local -a pieces=("${(@s.:.)working}")
  for segment in "${pieces[@]}"; do
    [[ -z "$segment" ]] && continue
    [[ ${#segment} -le 4 && "$segment" =~ '^[0-9A-Fa-f]+$' ]] || return 1
    (( segments++ ))
  done

  if (( compressed )); then
    (( segments < 8 ))
  else
    (( segments == 8 ))
  fi
}

_net_valid_ip_literal() {
  _net_valid_ipv4 "$1" || _net_valid_ipv6 "$1"
}

_net_valid_dns_name() {
  local value="${1:-}"
  [[ ${#value} -ge 1 && ${#value} -le 253 \
    && "$value" != -* \
    && "$value" != *[[:cntrl:][:space:]]* ]] || return 1

  local candidate="${value%.}"
  [[ -n "$candidate" && "$candidate" != *..* ]] || return 1
  local label=""
  local -a labels=("${(@s:.:)candidate}")
  for label in "${labels[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 \
      && "$label" =~ '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$' ]] \
      || return 1
  done
}

_net_valid_target() {
  _net_valid_ip_literal "$1" || _net_valid_dns_name "$1"
}

_net_valid_ip_cidr() {
  local value="${1:-}"
  [[ "$value" == */* ]] || return 1
  local address="${value%/*}"
  local prefix="${value##*/}"
  _net_valid_ip_literal "$address" || return 1
  if _net_valid_ipv4 "$address"; then
    _net_valid_uint_range "$prefix" 0 32
  else
    _net_valid_uint_range "$prefix" 0 128
  fi
}

_net_valid_interface_name() {
  local value="${1:-}"
  [[ ${#value} -ge 1 && ${#value} -le 64 \
    && "$value" != -* \
    && "$value" =~ '^[A-Za-z0-9_.:@-]+$' ]]
}

_net_safe_provider_url() {
  local url="${1:-}"
  [[ ${#url} -ge 10 && ${#url} -le 512 \
    && "$url" == https://* \
    && "$url" != *[[:cntrl:][:space:]]* \
    && "$url" != *'@'* \
    && "$url" != *'#'* \
    && "$url" != *\\* ]] || return 1

  local remainder="${url#https://}"
  local authority="${remainder%%/*}"
  [[ -n "$authority" && "$authority" != .* && "$authority" != *. \
    && "$authority" != *..* \
    && "$authority" =~ '^[A-Za-z0-9.-]+$' ]]
}

_net_provider_name() {
  _net_safe_provider_url "$1" || return 1
  local remainder="${1#https://}"
  REPLY="${remainder%%/*}"
}

_net_check_command() {
  local command_name="${1:-}"
  local next_step="${2:-Install it and retry.}"
  command -v "$command_name" &>/dev/null && return 0
  _net_error "Required command '$command_name' was not found."
  _net_dim "$next_step"
  return 1
}

_net_have_timeout() {
  command -v timeout &>/dev/null || command -v gtimeout &>/dev/null
}

_net_run_probe() {
  local seconds="${1:-}"
  shift
  _net_valid_uint_range "$seconds" 1 300 || {
    _net_error "Invalid network probe deadline."
    return 2
  }
  (( $# > 0 )) || return 2

  if command -v timeout &>/dev/null; then
    command timeout -k 2s "${seconds}s" "$@"
  elif command -v gtimeout &>/dev/null; then
    command gtimeout -k 2s "${seconds}s" "$@"
  else
    _net_error "Bounded probes require timeout or gtimeout."
    _net_dim "Install GNU coreutils and retry."
    return 1
  fi
}

# Executes one read-only command with a deadline and a file-size limit. REPLY
# is bounded combined output; the command status is preserved unless the
# output or capture identity exceeds the safety boundary.
_net_capture_probe() {
  emulate -L zsh
  local maximum_bytes="${1:-}"
  local seconds="${2:-}"
  shift 2
  _net_valid_uint_range "$maximum_bytes" 1 1048576 || return 2
  _net_valid_uint_range "$seconds" 1 300 || return 2
  (( $# > 0 )) || return 2

  REPLY=""
  zmodload zsh/stat zsh/system 2>/dev/null || {
    _net_error "Zsh file-descriptor support is required for bounded probes."
    return 125
  }
  _net_validate_temp_parent "${TMPDIR:-/tmp}" || {
    _net_error "Refusing an unsafe temporary root for a network probe."
    return 125
  }
  local temp_root="$REPLY"

  local capture_file=""
  local file_identity=""
  local output=""
  local -i write_fd=-1 read_fd=-1
  local -i probe_rc=125 operation_rc=125 cleanup_failed=0
  local -i block_limit=$(( (maximum_bytes + 512) / 512 ))
  local -A file_state=() current_file_state=()

  {
    capture_file=$(umask 077; command mktemp \
      "$temp_root/zdx-net-probe.XXXXXX" 2>/dev/null)
    if [[ -z "$capture_file" \
      || "$capture_file" != "${capture_file:a}" \
      || "$capture_file" != "${capture_file:A}" \
      || "${capture_file:h}" != "$temp_root" \
      || "${capture_file:t}" != zdx-net-probe.* \
      || ! -f "$capture_file" || -L "$capture_file" ]] \
      || ! zstat -LH file_state -- "$capture_file" 2>/dev/null \
      || (( file_state[uid] != EUID || file_state[nlink] != 1 \
        || (file_state[mode] & 8#77) != 0 \
        || file_state[size] != 0 )); then
      _net_error "Refusing an unsafe network probe capture."
    else
      file_identity="${file_state[device]}:${file_state[inode]}:${file_state[mode]}:${file_state[uid]}:${file_state[nlink]}"
      if ! sysopen -w -o nofollow,cloexec -u write_fd \
        -- "$capture_file" 2>/dev/null; then
        _net_error "Could not open the network probe capture safely."
      else
        (
          builtin ulimit -f "$block_limit" 2>/dev/null || return 125
          _net_run_probe "$seconds" "$@" 2>&1
        ) 1>&$(( write_fd ))
        probe_rc=$?
        exec {write_fd}>&-
        write_fd=-1

        if ! zstat -LH current_file_state -- "$capture_file" 2>/dev/null \
          || [[ "${current_file_state[device]}:${current_file_state[inode]}:${current_file_state[mode]}:${current_file_state[uid]}:${current_file_state[nlink]}" \
            != "$file_identity" ]]; then
          _net_error "The network probe capture changed identity."
        elif (( current_file_state[size] > maximum_bytes )); then
          _net_error \
            "A network probe exceeded its ${maximum_bytes}-byte output limit."
        elif ! sysopen -r -o nofollow,cloexec -u read_fd \
          -- "$capture_file" 2>/dev/null; then
          _net_error "Could not read the network probe capture safely."
        else
          output=$(<&$(( read_fd )))
          exec {read_fd}>&-
          read_fd=-1
          operation_rc=$probe_rc
        fi
      fi
    fi
  } always {
    (( write_fd >= 0 )) && exec {write_fd}>&-
    (( read_fd >= 0 )) && exec {read_fd}>&-
    if [[ -n "$capture_file" && ( -e "$capture_file" || -L "$capture_file" ) ]]; then
      current_file_state=()
      if [[ -n "$file_identity" && -f "$capture_file" \
        && ! -L "$capture_file" && "${capture_file:h}" == "$temp_root" ]] \
        && zstat -LH current_file_state -- "$capture_file" 2>/dev/null \
        && [[ "${current_file_state[device]}:${current_file_state[inode]}:${current_file_state[mode]}:${current_file_state[uid]}:${current_file_state[nlink]}" \
          == "$file_identity" ]]; then
        command rm -f -- "$capture_file" 2>/dev/null || cleanup_failed=1
      else
        cleanup_failed=1
      fi
    fi
    (( cleanup_failed == 0 )) || operation_rc=125
  }

  if (( probe_rc == 130 || probe_rc == 143 )); then
    output=""
    operation_rc=$probe_rc
  fi
  REPLY="$output"
  return $operation_rc
}

# Fetches one bounded HTTPS response without reading curl configuration.
# REPLY contains response bytes only after the transfer and size checks pass.
_net_fetch_url() {
  local LC_ALL=C
  local url="${1:-}"
  local maximum_bytes="${2:-131072}"
  _net_safe_provider_url "$url" || return 2
  _net_valid_uint_range "$maximum_bytes" 1 1048576 || return 2
  command -v curl &>/dev/null || return 1

  REPLY=""
  local response=""
  response=$(command curl \
    --disable \
    --fail \
    --silent \
    --show-error \
    --location \
    --max-redirs 2 \
    --proto '=https' \
    --proto-redir '=https' \
    --connect-timeout 2 \
    --max-time 5 \
    --max-filesize "$maximum_bytes" \
    --url "$url" 2>/dev/null) || return $?
  (( ${#response} <= maximum_bytes )) || return 125
  REPLY="$response"
}

_net_now_ms() {
  zmodload zsh/datetime 2>/dev/null || return 1
  local -F 6 now="$EPOCHREALTIME"
  local -F 0 milliseconds=$(( now * 1000.0 ))
  REPLY="$milliseconds"
}

# Status: 0 confirmed, 1 declined, 2 no usable terminal.
_net_confirm_network_transfer() {
  local prompt="${1:-Proceed?}"
  local auto_yes="${2:-no}"
  [[ "$auto_yes" == "yes" ]] && return 0
  [[ -t 0 && -t 2 ]] || return 2

  if _net_color_enabled; then
    printf '\033[1;33m? %s [y/N]: \033[0m' "${(V)prompt}" >&2
  else
    printf '? %s [y/N]: ' "${(V)prompt}" >&2
  fi
  local answer=""
  IFS= read -r answer || return 2
  print -u2 -r -- ""
  [[ "$answer" =~ ^[Yy]$ ]]
}

_net_menu_field_safe() {
  local value="${1:-}"
  local maximum_length="${2:-1024}"
  [[ "$value" != *'|'* ]] \
    && _net_visible_value_safe "$value" "$maximum_length"
}

_net_menu_section() {
  local title="$1"
  local description="${2:-}"
  if ! _net_menu_field_safe "$title" 256 \
    || ! _net_menu_field_safe "$description" 1024; then
    _net_error "Invalid menu section fields."
    return 2
  fi
  printf "── %s ──|:|%s\n" "$title" "$description"
}

_net_menu_entry() {
  local label="$1"
  local command_name="$2"
  local description="$3"
  if ! _net_menu_field_safe "$label" 256 \
    || ! _net_menu_field_safe "$command_name" 128 \
    || ! _net_menu_field_safe "$description" 1024; then
    _net_error "Invalid menu entry fields."
    return 2
  fi
  [[ "$command_name" =~ '^[a-z][a-z0-9-]*$' ]] || {
    _net_error "Invalid Network command token."
    return 2
  }
  printf "  %s|%s|%s\n" "$label" "$command_name" "$description"
}

_net_fzf() {
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

_net_system_root_uid() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local -A root_state=()
  [[ -d / && ! -L / ]] \
    && zstat -LH root_state -- / 2>/dev/null \
    && (( (root_state[mode] & 8#170000) == 8#040000 )) || return 1
  REPLY="${root_state[uid]}"
}

_net_validate_ancestor_chain() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local child_path="${1:-}"
  [[ "$child_path" == /* && "$child_path" == "${child_path:A}" ]] || return 1

  _net_system_root_uid || return 1
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

_net_validate_temp_parent() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local requested_parent="${1:-}"
  REPLY=""
  while [[ "$requested_parent" != "/" && "$requested_parent" == */ ]]; do
    requested_parent="${requested_parent%/}"
  done
  [[ -n "$requested_parent" && "$requested_parent" == /* \
    && -d "$requested_parent" && ! -L "$requested_parent" \
    && "$requested_parent" == "${requested_parent:a}" \
    && "$requested_parent" == "${requested_parent:A}" ]] || return 1

  _net_system_root_uid || return 1
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
  _net_validate_ancestor_chain "$requested_parent" || return 1
  REPLY="$requested_parent"
}

# Runs fzf synchronously in the terminal foreground. Its bounded stdout is
# captured in a private invocation-owned file and returned through REPLY.
_net_fzf_capture() {
  emulate -L zsh
  REPLY=""

  zmodload zsh/stat zsh/system 2>/dev/null || {
    _net_error "Zsh file-descriptor support is required for Network menus."
    return 125
  }
  _net_validate_temp_parent "${TMPDIR:-/tmp}" || {
    _net_error "Refusing an unsafe temporary root for the Network menu."
    return 125
  }
  local temp_root="$REPLY"

  local capture_dir=""
  capture_dir=$(umask 077; command mktemp -d \
    "$temp_root/zdx-net-fzf.XXXXXX" 2>/dev/null) || {
    _net_error "Could not create a private Network menu directory."
    return 125
  }

  local -A directory_state=()
  if [[ "$capture_dir" != "${capture_dir:a}" \
    || "$capture_dir" != "${capture_dir:A}" \
    || "${capture_dir:h}" != "$temp_root" \
    || "${capture_dir:t}" != zdx-net-fzf.* \
    || ! -d "$capture_dir" || -L "$capture_dir" ]] \
    || ! zstat -LH directory_state -- "$capture_dir" 2>/dev/null \
    || (( directory_state[uid] != EUID \
      || (directory_state[mode] & 8#77) != 0 )); then
    _net_error "Refusing an unsafe Network menu directory."
    return 125
  fi
  local directory_identity="${directory_state[device]}:${directory_state[inode]}:${directory_state[mode]}:${directory_state[uid]}"

  local capture_file=""
  local file_identity=""
  local selection=""
  local -i write_fd=-1 read_fd=-1
  local -i fzf_rc=125 operation_rc=125 cleanup_failed=0
  local -A file_state=() current_directory_state=() current_file_state=()

  {
    capture_file=$(umask 077; command mktemp \
      "$capture_dir/.result.XXXXXX" 2>/dev/null)
    if [[ -z "$capture_file" ]]; then
      _net_error "Could not create a private Network menu result."
    elif [[ "$capture_file" != "${capture_file:a}" \
      || "$capture_file" != "${capture_file:A}" \
      || "${capture_file:h}" != "$capture_dir" \
      || "${capture_file:t}" != .result.* \
      || ! -f "$capture_file" || -L "$capture_file" ]] \
      || ! zstat -LH file_state -- "$capture_file" 2>/dev/null \
      || (( file_state[uid] != EUID || file_state[nlink] != 1 \
        || (file_state[mode] & 8#77) != 0 )); then
      _net_error "Refusing an unsafe Network menu result."
    else
      file_identity="${file_state[device]}:${file_state[inode]}:${file_state[mode]}:${file_state[uid]}:${file_state[nlink]}"
      if ! sysopen -w -o nofollow,cloexec -u write_fd \
        -- "$capture_file" 2>/dev/null; then
        _net_error "Could not open the Network menu result safely."
      else
        _net_fzf "$@" 1>&$(( write_fd ))
        fzf_rc=$?
        exec {write_fd}>&-
        write_fd=-1

        if ! zstat -LH current_directory_state -- "$capture_dir" 2>/dev/null \
          || [[ "${current_directory_state[device]}:${current_directory_state[inode]}:${current_directory_state[mode]}:${current_directory_state[uid]}" \
            != "$directory_identity" ]] \
          || ! zstat -LH current_file_state -- "$capture_file" 2>/dev/null \
          || [[ "${current_file_state[device]}:${current_file_state[inode]}:${current_file_state[mode]}:${current_file_state[uid]}:${current_file_state[nlink]}" \
            != "$file_identity" ]] \
          || (( current_file_state[size] < 0 \
            || current_file_state[size] > 1024 * 1024 )); then
          _net_error "The Network menu result changed or is oversized."
        elif ! sysopen -r -o nofollow,cloexec -u read_fd \
          -- "$capture_file" 2>/dev/null; then
          _net_error "Could not read the Network menu result safely."
        else
          selection=$(<&$(( read_fd )))
          exec {read_fd}>&-
          read_fd=-1
          if (( fzf_rc != 0 )) && [[ -n "$selection" ]]; then
            _net_error "The cancelled Network menu returned unexpected data."
            selection=""
            operation_rc=125
          elif [[ "$selection" == *$'\n'* ]]; then
            _net_error \
              "The single-select Network menu returned multiple records."
            selection=""
            operation_rc=125
          else
            operation_rc=$fzf_rc
          fi
        fi
      fi
    fi
  } always {
    (( write_fd >= 0 )) && exec {write_fd}>&-
    (( read_fd >= 0 )) && exec {read_fd}>&-

    if [[ -n "$capture_file" && ( -e "$capture_file" || -L "$capture_file" ) ]]; then
      current_file_state=()
      if [[ -n "$file_identity" && -f "$capture_file" \
        && ! -L "$capture_file" && "${capture_file:h}" == "$capture_dir" ]] \
        && zstat -LH current_file_state -- "$capture_file" 2>/dev/null \
        && [[ "${current_file_state[device]}:${current_file_state[inode]}:${current_file_state[mode]}:${current_file_state[uid]}:${current_file_state[nlink]}" \
          == "$file_identity" ]]; then
        command rm -f -- "$capture_file" 2>/dev/null || cleanup_failed=1
      else
        cleanup_failed=1
      fi
    fi

    current_directory_state=()
    if [[ -d "$capture_dir" && ! -L "$capture_dir" ]] \
      && zstat -LH current_directory_state -- "$capture_dir" 2>/dev/null \
      && [[ "${current_directory_state[device]}:${current_directory_state[inode]}:${current_directory_state[mode]}:${current_directory_state[uid]}" \
        == "$directory_identity" ]]; then
      command rmdir -- "$capture_dir" 2>/dev/null || cleanup_failed=1
    else
      cleanup_failed=1
    fi
    (( cleanup_failed == 0 )) || operation_rc=125
  }

  REPLY="$selection"
  return $operation_rc
}

_net_fzf_rc_is_cancel() {
  (( ${1:-0} == 1 || ${1:-0} == 130 ))
}

typeset -g _NET_COMMON_SOURCED=1
