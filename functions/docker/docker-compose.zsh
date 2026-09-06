#!/usr/bin/env zsh
# =============================================================================
# Docker Compose: fixed descriptor, resolved-config, and context execution
# =============================================================================
#
# Loaded by docker-menu.zsh after docker-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_DOCKER_COMPOSE_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_docker_compose_usage() {
  local command_name="$1"
  print -u2 -r -- 'Usage:'
  if [[ "$command_name" == "docker-compose-logs" ]]; then
    print -u2 -r -- \
      "  $command_name [--file FILE] [--tail N] [--follow]"
    print -u2 -r -- ''
    print -u2 -r -- 'Logs are written to stdout; all UI remains on stderr.'
  else
    print -u2 -r -- \
      "  $command_name [--file FILE] [--dry-run] [--yes] [--allow-remote]"
    print -u2 -r -- ''
    print -u2 -r -- \
      'Non-interactive project mutation requires --yes.'
  fi
  print -u2 -r -- \
    'FILE must be one safe direct-child YAML descriptor of the current directory.'
}

_docker_compose_sha256_file() {
  local input_file="$1"
  REPLY=""
  local digest_output=""
  if command -v sha256sum &>/dev/null; then
    digest_output=$(command sha256sum -- "$input_file") || return 1
  elif command -v shasum &>/dev/null; then
    digest_output=$(command shasum -a 256 -- "$input_file") || return 1
  else
    _docker_error "sha256sum or shasum is required for Compose revalidation."
    return 1
  fi
  local digest="${digest_output%%[[:space:]]*}"
  digest="${digest:l}"
  [[ "$digest" =~ '^[0-9a-f]{64}$' ]] || return 1
  REPLY="$digest"
}

_docker_compose_sha256_text() {
  _docker_sha256_text "$1"
}

_docker_compose_semantic_environment() {
  local variable_name=""
  local -A seen=()
  reply=(DOCKER_DEFAULT_PLATFORM)
  seen[DOCKER_DEFAULT_PLATFORM]=1
  for variable_name in ${(k)parameters}; do
    [[ "$variable_name" == COMPOSE_* ]] || continue
    [[ -n "${seen[$variable_name]:-}" ]] || {
      reply+=("$variable_name")
      seen[$variable_name]=1
    }
    (( ${#reply[@]} <= 128 )) || {
      _docker_error "Too many ambient Compose parameters to audit safely."
      return 1
    }
  done
  reply=("${(@on)reply}")
}

_docker_compose_reject_ambient() {
  _docker_compose_semantic_environment || return 1
  local variable_name=""
  for variable_name in "${reply[@]}"; do
    if [[ -n "${(P)variable_name}" ]]; then
      _docker_error \
        "Refusing ambient $variable_name for a reviewed Compose action."
      return 1
    fi
  done
}

_docker_compose_sanitized_command() {
  local -a base_command=("$@")
  (( ${#base_command[@]} > 0 )) || return 2
  _docker_compose_semantic_environment || return 1
  local -a semantic_variables=("${reply[@]}")
  local variable_name=""
  reply=(env)
  for variable_name in "${semantic_variables[@]}"; do
    reply+=(-u "$variable_name")
  done
  reply+=("${base_command[@]}")
}

_docker_compose_workspace_safe() {
  local workspace="${1:-}"
  [[ -n "$workspace" && "$workspace" == /* \
    && -d "$workspace" && ! -L "$workspace" \
    && "$workspace" == "${workspace:a}" \
    && "$workspace" == "${workspace:A}" ]] || return 1

  zmodload zsh/stat 2>/dev/null || return 1
  _docker_system_root_uid || return 1
  local -i system_root_uid=$REPLY
  local current_path="$workspace"
  local -i is_workspace=1
  local -A path_state=()
  while true; do
    [[ -d "$current_path" && ! -L "$current_path" \
      && "$current_path" == "${current_path:A}" ]] || return 1
    path_state=()
    zstat -LH path_state -- "$current_path" 2>/dev/null || return 1
    (( (path_state[mode] & 8#170000) == 8#040000 )) || return 1

    if (( is_workspace )); then
      (( path_state[uid] == EUID \
        && (path_state[mode] & 8#22) == 0 )) || return 1
      is_workspace=0
    elif (( (path_state[uid] == EUID \
        || path_state[uid] == system_root_uid) \
      && (path_state[mode] & 8#22) == 0 )); then
      :
    elif (( path_state[uid] == system_root_uid \
      && (path_state[mode] & 8#1000) != 0 \
      && (path_state[mode] & 8#2) != 0 )); then
      :
    else
      return 1
    fi

    [[ "$current_path" == "/" ]] && break
    current_path="${current_path:h}"
  done
}

# reply: workspace descriptor descriptor-fingerprint
_docker_compose_descriptor_snapshot() {
  local requested_file="${1:-}"
  reply=()
  zmodload zsh/stat 2>/dev/null || return 1
  _docker_compose_reject_ambient || return 1

  local workspace="${PWD:A}"
  _docker_compose_workspace_safe "$workspace" || {
    _docker_error "The current Compose workspace is unsafe."
    return 1
  }

  local descriptor=""
  if [[ -n "$requested_file" ]]; then
    if [[ "$requested_file" == /* ]]; then
      descriptor="${requested_file:a}"
    else
      descriptor="${workspace}/${requested_file}"
      descriptor="${descriptor:a}"
    fi
  else
    local candidate=""
    local -a matches=()
    for candidate in \
      compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
      [[ -e "$workspace/$candidate" || -L "$workspace/$candidate" ]] \
        && matches+=("$workspace/$candidate")
    done
    (( ${#matches[@]} == 1 )) || {
      if (( ${#matches[@]} == 0 )); then
        _docker_error "No Compose descriptor was found in the current directory."
      else
        _docker_error \
          "Multiple Compose descriptors are ambiguous; select one with --file."
      fi
      return 1
    }
    descriptor="${matches[1]}"
  fi

  local descriptor_name="${descriptor:t}"
  [[ "${descriptor:h}" == "$workspace" \
    && "$descriptor_name" =~ '^[A-Za-z0-9][A-Za-z0-9_.-]*[.](yml|yaml)$' \
    && -f "$descriptor" && ! -L "$descriptor" \
    && "$descriptor" == "${descriptor:A}" ]] || {
    _docker_error \
      "The Compose descriptor must be a real YAML child of the current directory."
    return 1
  }

  local -A descriptor_state=()
  zstat -LH descriptor_state -- "$descriptor" 2>/dev/null || return 1
  (( descriptor_state[uid] == EUID \
    && descriptor_state[nlink] == 1 \
    && (descriptor_state[mode] & 8#22) == 0 \
    && (descriptor_state[mode] & 8#170000) == 8#100000 \
    && descriptor_state[size] >= 1 \
    && descriptor_state[size] <= 2 * 1024 * 1024 )) || {
    _docker_error \
      "The Compose descriptor has unsafe ownership, links, mode, or size."
    return 1
  }
  _docker_compose_sha256_file "$descriptor" || return 1
  local digest="$REPLY"
  local fingerprint="${descriptor_state[device]}:${descriptor_state[inode]}:"\
"${descriptor_state[size]}:${descriptor_state[mtime]}:"\
"${descriptor_state[mode]}:${descriptor_state[uid]}:"\
"${descriptor_state[nlink]}:${digest}"
  reply=("$workspace" "$descriptor" "$fingerprint")
}

_docker_compose_descriptor_revalidate() {
  local expected_workspace="$1"
  local expected_descriptor="$2"
  local expected_fingerprint="$3"
  _docker_compose_descriptor_snapshot "$expected_descriptor" || return 1
  [[ "${reply[1]}" == "$expected_workspace" \
    && "${reply[2]}" == "$expected_descriptor" \
    && "${reply[3]}" == "$expected_fingerprint" ]] || {
    _docker_error "The Compose descriptor changed after review."
    return 1
  }
}

_docker_compose_require_plugin() {
  local -a context_snapshot=("$@")
  _docker_context_command \
    "${context_snapshot[1]}" "${context_snapshot[2]}" || return 1
  local -a docker_command=("${reply[@]}")
  _docker_compose_sanitized_command \
    "${docker_command[@]}" compose version || return 1
  local -a compose_command=("${reply[@]}")
  _docker_run_probe 5 "${compose_command[@]}" \
    >/dev/null 2>&1 || {
    _docker_error "The Docker Compose plugin is unavailable."
    return 1
  }
}

# REPLY is a SHA-256 digest of the fully resolved Compose configuration.
_docker_compose_config_digest() {
  local descriptor="$1"
  local -a context_snapshot=("${(@)argv[2,7]}")
  REPLY=""
  _docker_context_command \
    "${context_snapshot[1]}" "${context_snapshot[2]}" || return 1
  local -a docker_command=("${reply[@]}")
  _docker_compose_sanitized_command "${docker_command[@]}" || return 1
  local -a compose_command=("${reply[@]}")
  local config_output=""
  _docker_capture_probe_bounded $(( 2 * 1024 * 1024 )) 10 \
    "${compose_command[@]}" compose \
    --ansi never -f "$descriptor" config 2>/dev/null || {
    _docker_error "The reviewed Compose descriptor did not resolve safely."
    return 1
  }
  config_output="$REPLY"
  (( ${#config_output} <= 2 * 1024 * 1024 )) || {
    _docker_error "The resolved Compose configuration exceeded 2 MiB."
    return 1
  }
  _docker_compose_sha256_text "$config_output"
}

_docker_compose_plan() {
  local action_name="$1"
  local workspace="$2"
  local descriptor="$3"
  local config_digest="$4"
  local -a context_snapshot=("${(@)argv[5,10]}")
  _docker_context_label "${context_snapshot[@]}" || return 1
  _docker_header "Docker Compose Plan"
  _docker_info "Context: $REPLY"
  _docker_info "Workspace: $workspace"
  _docker_info "Descriptor: $descriptor"
  _docker_info "Resolved config SHA-256: $config_digest"
  _docker_info "Action: $action_name"
  _docker_warn \
    "Compose descriptors and images are project-defined executable trust boundaries."
}

_docker_compose_action() {
  local action_name="$1"
  local command_name="$2"
  shift 2
  local requested_file=""
  local -i dry_run=0 assume_yes=0 allow_remote=0
  local -i tail_lines=100 follow_logs=0
  local -i dry_seen=0 yes_seen=0 remote_seen=0 tail_seen=0 follow_seen=0

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        (( $# == 1 )) || return 2
        _docker_compose_usage "$command_name"
        return 0
        ;;
      --file)
        (( $# >= 2 )) || {
          _docker_error "--file requires a descriptor path."
          return 2
        }
        requested_file="$2"
        shift 2
        ;;
      --tail)
        (( $# >= 2 )) || return 2
        _docker_validate_uint "$2" 10000 && (( 10#$2 >= 1 )) || {
          _docker_error "--tail must be between 1 and 10000."
          return 2
        }
        tail_lines=$(( 10#$2 ))
        tail_seen=1
        shift 2
        ;;
      --follow)       follow_logs=1; follow_seen=1; shift ;;
      --dry-run)      dry_run=1; dry_seen=1; shift ;;
      --yes)          assume_yes=1; yes_seen=1; shift ;;
      --allow-remote) allow_remote=1; remote_seen=1; shift ;;
      --)
        shift
        (( $# == 0 )) || return 2
        ;;
      -*)
        _docker_error "Unknown $command_name option: $1"
        return 2
        ;;
      *)
        _docker_error "Unexpected $command_name operand: $1"
        return 2
        ;;
    esac
  done

  if [[ "$action_name" == "logs" ]]; then
    (( dry_seen == 0 && yes_seen == 0 && remote_seen == 0 )) || {
      _docker_error \
        "Compose logs accepts only --file, --tail, and --follow."
      return 2
    }
  else
    (( tail_seen == 0 && follow_seen == 0 )) || {
      _docker_error \
        "Compose mutations do not accept --tail or --follow."
      return 2
    }
  fi

  _docker_compose_descriptor_snapshot "$requested_file" || return 1
  local -a descriptor_snapshot=("${reply[@]}")
  _docker_context_snapshot || return 1
  local -a context_snapshot=("${reply[@]}")
  _docker_compose_require_plugin "${context_snapshot[@]}" || return 1
  _docker_compose_config_digest \
    "${descriptor_snapshot[2]}" "${context_snapshot[@]}" || return 1
  local config_digest="$REPLY"

  if [[ "$action_name" == "logs" ]]; then
    _docker_compose_descriptor_revalidate \
      "${descriptor_snapshot[@]}" || return 1
    _docker_context_revalidate "${context_snapshot[@]}" || return 1
    _docker_compose_config_digest \
      "${descriptor_snapshot[2]}" "${context_snapshot[@]}" || return 1
    [[ "$REPLY" == "$config_digest" ]] || {
      _docker_error "The resolved Compose configuration changed before logs."
      return 1
    }
    _docker_context_command \
      "${context_snapshot[1]}" "${context_snapshot[2]}" || return 1
    local -a docker_command=("${reply[@]}")
    _docker_compose_sanitized_command "${docker_command[@]}" || return 1
    local -a compose_command=("${reply[@]}")
    local -a log_command=(
      "${compose_command[@]}" compose --ansi never
      -f "${descriptor_snapshot[2]}" logs --tail "$tail_lines"
    )
    (( follow_logs )) && log_command+=(--follow)
    command "${log_command[@]}"
    return $?
  fi

  _docker_compose_plan "$action_name" \
    "${descriptor_snapshot[1]}" "${descriptor_snapshot[2]}" \
    "$config_digest" "${context_snapshot[@]}" || return 1
  (( dry_run )) && {
    _docker_success "Dry run complete; Compose was not executed."
    return 0
  }
  _docker_require_mutation_context \
    "${context_snapshot[6]}" "$allow_remote" || return 1

  if (( ! assume_yes )); then
    local -i confirm_rc=0
    _docker_confirm "Execute this reviewed Compose project action?" \
      || confirm_rc=$?
    case "$confirm_rc" in
      0) ;;
      130)
        _docker_info "Compose action cancelled."
        return 0
        ;;
      *)
        _docker_error "Non-interactive Compose mutation requires --yes."
        return 1
        ;;
    esac
  fi

  _docker_compose_descriptor_revalidate \
    "${descriptor_snapshot[@]}" || return 1
  _docker_context_revalidate "${context_snapshot[@]}" || return 1
  _docker_compose_config_digest \
    "${descriptor_snapshot[2]}" "${context_snapshot[@]}" || return 1
  [[ "$REPLY" == "$config_digest" ]] || {
    _docker_error "The resolved Compose configuration changed after review."
    return 1
  }

  _docker_context_command \
    "${context_snapshot[1]}" "${context_snapshot[2]}" || return 1
  local -a docker_command=("${reply[@]}")
  _docker_compose_sanitized_command "${docker_command[@]}" || return 1
  local -a compose_command=("${reply[@]}")
  local -a operation=(
    "${compose_command[@]}" compose --ansi never
    -f "${descriptor_snapshot[2]}"
  )
  case "$action_name" in
    up)      operation+=(up -d) ;;
    down)    operation+=(down) ;;
    restart) operation+=(restart) ;;
    *)       return 2 ;;
  esac

  (
    builtin cd -q -- "${descriptor_snapshot[1]}" || return 1
    command "${operation[@]}" >&2
  )
  local -i operation_rc=$?
  if (( operation_rc == 0 )); then
    _docker_success "Compose action completed."
  else
    _docker_error "Compose action failed (status $operation_rc)."
  fi
  return $operation_rc
}

docker-compose-up() {
  _docker_compose_action up docker-compose-up "$@"
}

docker-compose-down() {
  _docker_compose_action down docker-compose-down "$@"
}

docker-compose-restart() {
  _docker_compose_action restart docker-compose-restart "$@"
}

docker-compose-logs() {
  _docker_compose_action logs docker-compose-logs "$@"
}

typeset -g _DOCKER_COMPOSE_SOURCED=1
