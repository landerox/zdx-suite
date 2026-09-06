#!/usr/bin/env zsh
# =============================================================================
# Docker Registry: validated login without a daemon dependency
# =============================================================================
#
# Loaded by docker-menu.zsh after docker-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_DOCKER_REGISTRY_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_docker_login_usage() {
  print -u2 -r -- 'Usage:'
  print -u2 -r -- \
    '  docker-login [REGISTRY] [--username USER] [--password-stdin]'
  print -u2 -r -- \
    '  docker-login --registry REGISTRY [--username USER] [--password-stdin]'
  print -u2 -r -- ''
  print -u2 -r -- \
    'Credentials are handled only by Docker and are never printed by ZDX.'
  print -u2 -r -- \
    'Docker Hub is used when REGISTRY is omitted.'
}

_docker_registry_valid() {
  local registry_name="${1:-}"
  [[ -z "$registry_name" ]] && return 0
  (( ${#registry_name} <= 259 )) || return 1
  [[ "$registry_name" != -* \
    && "$registry_name" != *[[:space:]]* \
    && "$registry_name" != *[[:cntrl:]]* \
    && "$registry_name" != *'/'* \
    && "$registry_name" != *:*:* ]] || return 1

  local host_name="$registry_name"
  local port_number=""
  if [[ "$registry_name" == *:* ]]; then
    host_name="${registry_name%:*}"
    port_number="${registry_name##*:}"
    _docker_validate_uint "$port_number" 65535 \
      && (( 10#$port_number >= 1 )) || return 1
  fi
  (( ${#host_name} >= 1 && ${#host_name} <= 253 )) || return 1
  [[ "$host_name" != *..* \
    && "$host_name" =~ \
      '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' ]] || return 1

  local label=""
  local -a labels=("${(@s:.:)host_name}")
  (( ${#labels[@]} >= 1 )) || return 1
  for label in "${labels[@]}"; do
    (( ${#label} >= 1 && ${#label} <= 63 )) \
      && [[ "$label" =~ \
        '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$' ]] || return 1
  done
  return 0
}

_docker_registry_user_valid() {
  local user_name="${1:-}"
  (( ${#user_name} >= 1 && ${#user_name} <= 256 )) \
    && [[ "$user_name" != *[[:space:]]* \
      && "$user_name" != *[[:cntrl:]]* ]]
}

docker-login() {
  local registry_name=""
  local user_name=""
  local -i password_stdin=0 registry_seen=0 positional_seen=0

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        (( $# == 1 )) || return 2
        _docker_login_usage
        return 0
        ;;
      --registry)
        (( $# >= 2 )) || {
          _docker_error "--registry requires a value."
          return 2
        }
        (( positional_seen == 0 && registry_seen == 0 )) || {
          _docker_error "Specify the registry exactly once."
          return 2
        }
        registry_name="$2"
        registry_seen=1
        shift 2
        ;;
      --username)
        (( $# >= 2 )) || {
          _docker_error "--username requires a value."
          return 2
        }
        user_name="$2"
        shift 2
        ;;
      --password-stdin)
        password_stdin=1
        shift
        ;;
      --)
        shift
        if (( $# > 1 || positional_seen || registry_seen )); then
          _docker_error "Specify at most one registry."
          return 2
        fi
        if (( $# == 1 )); then
          registry_name="$1"
          positional_seen=1
          shift
        fi
        ;;
      -*)
        _docker_error "Unknown docker-login option: $1"
        return 2
        ;;
      *)
        (( positional_seen == 0 && registry_seen == 0 )) || {
          _docker_error "Specify at most one registry."
          return 2
        }
        registry_name="$1"
        positional_seen=1
        shift
        ;;
    esac
  done

  if (( (registry_seen || positional_seen) && ${#registry_name} == 0 )); then
    _docker_error "The registry value cannot be empty."
    return 2
  fi
  _docker_registry_valid "$registry_name" || {
    _docker_error "The registry must be a hostname or hostname:port."
    return 2
  }
  if [[ -n "$user_name" ]]; then
    _docker_registry_user_valid "$user_name" || {
      _docker_error "The registry username is malformed."
      return 2
    }
  elif (( password_stdin )); then
    _docker_error "--password-stdin requires --username."
    return 2
  fi
  if (( ! password_stdin )) && [[ ! -t 0 || ! -t 2 ]]; then
    _docker_error \
      "Interactive registry login requires a terminal; use --password-stdin."
    return 1
  fi
  _docker_require_cmd docker "registry authentication" || return 1
  _docker_require_cmd jq "registry credential configuration validation" \
    || return 1
  _docker_require_cmd head "bounded registry configuration validation" \
    || return 1
  _docker_timeout_command || {
    _docker_error \
      "A timeout or gtimeout command is required before registry login."
    return 1
  }
  _docker_config_dir_ensure || {
    _docker_error \
      "Refusing an unsafe Docker credential configuration directory."
    return 1
  }
  local config_dir="$REPLY"
  _docker_config_cli_valid "$config_dir" || {
    _docker_error \
      "Refusing a Docker credential configuration that the client cannot parse."
    return 1
  }

  _docker_header "Docker Registry Authentication"
  if [[ -n "$registry_name" ]]; then
    _docker_info "Registry: $registry_name"
  else
    _docker_info "Registry: Docker Hub"
  fi
  _docker_info "Credential config directory: $config_dir"
  _docker_info "Docker will handle credentials directly."

  local -a login_command=(docker --config "$config_dir" login)
  [[ -n "$user_name" ]] && login_command+=(--username "$user_name")
  (( password_stdin )) && login_command+=(--password-stdin)
  [[ -n "$registry_name" ]] && login_command+=("$registry_name")

  (umask 077; command "${login_command[@]}" >&2)
  local -i login_rc=$?
  _docker_config_dir_safe \
    && [[ "$REPLY" == "$config_dir" ]] \
    && _docker_config_cli_valid "$config_dir" || {
    _docker_error \
      "Docker left an unsafe credential configuration directory or file."
    return 1
  }
  if (( login_rc == 0 )); then
    _docker_success "Registry authentication completed."
  else
    _docker_error "Registry authentication failed (status $login_rc)."
  fi
  return $login_rc
}

typeset -g _DOCKER_REGISTRY_SOURCED=1
