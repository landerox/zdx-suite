#!/usr/bin/env zsh
# =============================================================================
# Docker Containers: typed inventory and exact container actions
# =============================================================================
#
# Loaded by docker-menu.zsh after docker-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_DOCKER_CONTAINERS_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_docker_containers_usage() {
  print -u2 -r -- 'Usage:'
  print -u2 -r -- '  docker-containers'
  print -u2 -r -- '  docker-containers --action list'
  print -u2 -r -- \
    '  docker-containers --action exec|logs|start|stop|remove --id FULL_ID [options]'
  print -u2 -r -- ''
  print -u2 -r -- 'Options:'
  print -u2 -r -- '  --shell /bin/sh|/bin/bash  Shell used by exec'
  print -u2 -r -- '  --tail N                    Log lines, from 1 through 10000'
  print -u2 -r -- '  --follow                    Follow logs after the initial tail'
  print -u2 -r -- '  --dry-run                   Show a mutation without executing it'
  print -u2 -r -- '  --yes                       Confirm removal non-interactively'
  print -u2 -r -- '  --force                     Allow removal of an active container'
  print -u2 -r -- '  --allow-remote              Allow mutation of a remote endpoint'
  print -u2 -r -- ''
  print -u2 -r -- \
    'Exec requires terminal stdin/stdout and keeps session output on stdout.'
  print -u2 -r -- 'List output: id|name|state|image|ports'
}

_docker_container_record_valid() {
  local record="${1:-}"
  local container_id="" container_name="" container_state=""
  local image_name="" ports="" extra=""
  IFS='|' read -r container_id container_name container_state \
    image_name ports extra <<< "$record"
  [[ -z "$extra" ]] \
    && _docker_validate_container_id "$container_id" \
    && _docker_validate_name "$container_name" \
    && [[ "$container_state" =~ \
      '^(created|running|paused|restarting|removing|exited|dead)$' ]] \
    && _docker_visible_safe "$image_name" 1024 \
    && _docker_visible_safe "$ports" 2048
}

# stdout records: id|name|state|image|ports
_docker_container_inventory_data() {
  local -a context_snapshot=("$@")
  (( ${#context_snapshot[@]} == 6 )) || return 2
  _docker_context_command \
    "${context_snapshot[1]}" "${context_snapshot[2]}" || return 1
  local -a docker_command=("${reply[@]}")

  local inventory_output=""
  _docker_capture_probe_bounded "$_DOCKER_MAX_PICKER_BYTES" 10 \
    "${docker_command[@]}" \
    container ls -a --no-trunc \
    --format '{{.ID}}|{{.Names}}|{{.State}}|{{.Image}}|{{.Ports}}' \
    2>/dev/null || {
    _docker_error "Could not read the Docker container inventory."
    return 1
  }
  inventory_output="$REPLY"
  [[ -n "$inventory_output" ]] || return 0

  local record=""
  local -a records=()
  local -i record_count=0 total_bytes=0
  for record in "${(@f)inventory_output}"; do
    _docker_container_record_valid "$record" || {
      _docker_error "Docker returned a malformed container record."
      return 1
    }
    records+=("$record")
    (( record_count += 1 ))
    (( total_bytes += ${#record} + 1 ))
    (( record_count <= _DOCKER_MAX_RECORDS \
      && total_bytes <= _DOCKER_MAX_PICKER_BYTES )) || {
      _docker_error "The Docker container inventory exceeded its safety limit."
      return 1
    }
  done
  print -rl -- "${records[@]}"
}

_docker_container_lookup() {
  local -a context_snapshot=("${(@)argv[1,6]}")
  local requested_id="${7:-}"
  REPLY=""
  _docker_validate_container_id "$requested_id" || return 2

  local inventory_output=""
  inventory_output=$(_docker_container_inventory_data \
    "${context_snapshot[@]}") || return 1
  local record="" container_id=""
  local -i matches=0
  for record in "${(@f)inventory_output}"; do
    container_id="${record%%|*}"
    if [[ "$container_id" == "$requested_id" ]]; then
      REPLY="$record"
      (( matches += 1 ))
    fi
  done
  (( matches == 1 )) || {
    _docker_error "The requested container is absent or ambiguous."
    return 1
  }
}

_docker_container_revalidate() {
  local -a context_snapshot=("${(@)argv[1,6]}")
  local expected_record="${7:-}"
  _docker_container_record_valid "$expected_record" || return 1
  local container_id="${expected_record%%|*}"
  _docker_context_revalidate "${context_snapshot[@]}" || return 1
  _docker_container_lookup "${context_snapshot[@]}" "$container_id" || return 1
  [[ "$REPLY" == "$expected_record" ]] || {
    _docker_error "The selected container changed after review."
    return 1
  }
}

_docker_container_plan() {
  local action_name="$1"
  local expected_record="$2"
  local -a context_snapshot=("${(@)argv[3,8]}")
  local container_id="" container_name="" container_state=""
  local image_name="" ports="" extra=""
  IFS='|' read -r container_id container_name container_state \
    image_name ports extra <<< "$expected_record"
  _docker_context_label "${context_snapshot[@]}" || return 1
  _docker_header "Docker Container Plan"
  _docker_info "Context: $REPLY"
  _docker_info "Action: $action_name"
  _docker_info "Container: $container_name"
  _docker_info "Full ID: $container_id"
  _docker_info "State: $container_state"
  _docker_info "Image: $image_name"
}

_docker_container_execute_action() {
  local action_name="$1"
  local expected_record="$2"
  local -a context_snapshot=("${(@)argv[3,8]}")
  local -i dry_run="${9:-0}"
  local -i assume_yes="${10:-0}"
  local -i force_remove="${11:-0}"
  local -i allow_remote="${12:-0}"
  local -i follow_logs="${13:-0}"
  local -i tail_lines="${14:-100}"
  local shell_name="${15:-/bin/sh}"

  local container_id="" container_name="" container_state=""
  local image_name="" ports="" extra=""
  IFS='|' read -r container_id container_name container_state \
    image_name ports extra <<< "$expected_record"
  _docker_container_record_valid "$expected_record" || return 1

  _docker_context_command \
    "${context_snapshot[1]}" "${context_snapshot[2]}" || return 1
  local -a docker_command=("${reply[@]}")

  case "$action_name" in
    logs)
      _docker_container_revalidate \
        "${context_snapshot[@]}" "$expected_record" || return 1
      local -a log_command=(
        "${docker_command[@]}" container logs --tail "$tail_lines"
      )
      (( follow_logs )) && log_command+=(--follow)
      log_command+=(-- "$container_id")
      command "${log_command[@]}"
      return $?
      ;;
    exec)
      _docker_require_mutation_context \
        "${context_snapshot[6]}" "$allow_remote" || return 1
      [[ "$container_state" == "running" ]] || {
        _docker_error "Only a running container can open an interactive shell."
        return 1
      }
      [[ -t 0 && -t 1 ]] || {
        _docker_error "Container exec requires an interactive terminal."
        return 1
      }
      _docker_container_plan "$action_name" "$expected_record" \
        "${context_snapshot[@]}" || return 1
      _docker_container_revalidate \
        "${context_snapshot[@]}" "$expected_record" || return 1
      command "${docker_command[@]}" container exec -it \
        -- "$container_id" "$shell_name"
      return $?
      ;;
    start|stop|remove) ;;
    *)
      _docker_error "Unsupported container action: $action_name"
      return 2
      ;;
  esac

  if [[ "$action_name" == "start" \
    && "$container_state" != "created" \
    && "$container_state" != "exited" ]]; then
    _docker_error "Container $container_name is not in a startable state."
    return 1
  fi
  if [[ "$action_name" == "stop" && "$container_state" != "running" ]]; then
    _docker_error "Container $container_name is not running."
    return 1
  fi
  if [[ "$action_name" == "remove" \
    && "$container_state" == (running|paused|restarting) \
    && force_remove -ne 1 ]]; then
    _docker_error \
      "Refusing to remove an active container without explicit --force."
    return 1
  fi

  _docker_container_plan "$action_name" "$expected_record" \
    "${context_snapshot[@]}" || return 1
  (( dry_run )) && {
    _docker_success "Dry run complete; no container was changed."
    return 0
  }
  _docker_require_mutation_context \
    "${context_snapshot[6]}" "$allow_remote" || return 1

  if [[ "$action_name" == "remove" && assume_yes -ne 1 ]]; then
    local -i confirm_rc=0
    _docker_confirm "Remove this exact container?" || confirm_rc=$?
    case "$confirm_rc" in
      0) ;;
      130)
        _docker_info "Container removal cancelled."
        return 0
        ;;
      *)
        _docker_error "Non-interactive container removal requires --yes."
        return 1
        ;;
    esac
  fi

  _docker_container_revalidate \
    "${context_snapshot[@]}" "$expected_record" || return 1
  local -a operation=("${docker_command[@]}" container)
  case "$action_name" in
    start) operation+=(start -- "$container_id") ;;
    stop)  operation+=(stop -- "$container_id") ;;
    remove)
      operation+=(rm)
      (( force_remove )) && operation+=(--force)
      operation+=(-- "$container_id")
      ;;
  esac

  command "${operation[@]}" >&2
  local -i operation_rc=$?
  if (( operation_rc == 0 )); then
    _docker_success "Container action completed."
  else
    _docker_error "Container action failed (status $operation_rc)."
  fi
  return $operation_rc
}

_docker_containers_interactive() {
  _docker_require_cmd fzf "the container dashboard" || return 1
  _docker_context_snapshot || return 1
  local -a context_snapshot=("${reply[@]}")

  local inventory_output=""
  inventory_output=$(_docker_container_inventory_data \
    "${context_snapshot[@]}") || return 1
  [[ -n "$inventory_output" ]] || {
    _docker_info "No containers found in the selected Docker context."
    return 0
  }

  local -a records=("${(@f)inventory_output}")
  local -a rows=()
  local record="" container_id="" container_name="" container_state=""
  local image_name="" ports="" extra=""
  local -i index=0
  for record in "${records[@]}"; do
    IFS='|' read -r container_id container_name container_state \
      image_name ports extra <<< "$record"
    (( index += 1 ))
    rows+=("$container_name [$container_state] $image_name"$'\t'"$index")
  done

  _docker_context_label "${context_snapshot[@]}" || return 1
  local context_header="$REPLY"
  local -i fzf_rc=0
  _docker_fzf_capture \
    --height=70% \
    --delimiter=$'\t' \
    --with-nth=1 \
    --expect='enter,ctrl-l,ctrl-s,ctrl-d' \
    --prompt='docker containers > ' \
    --header="$context_header | Enter shell | Ctrl-L logs | Ctrl-S start/stop | Ctrl-D remove | Esc cancel" \
    < <(printf '%s\n' "${rows[@]}") || fzf_rc=$?
  local selected="$REPLY"
  if (( fzf_rc != 0 )); then
    _docker_fzf_rc_is_cancel "$fzf_rc" && return 0
    _docker_error "Unable to open the container dashboard (status $fzf_rc)."
    return 1
  fi
  [[ -n "$selected" ]] || return 0

  local -a selected_lines=("${(@f)selected}")
  (( ${#selected_lines[@]} == 2 )) || {
    _docker_error "The container dashboard returned a malformed selection."
    return 1
  }
  local selected_key="${selected_lines[1]}"
  local selected_row="${selected_lines[2]}"
  _docker_array_contains_literal "$selected_row" "${rows[@]}" || {
    _docker_error "The selected container was not in the inventory snapshot."
    return 1
  }
  index="${selected_row##*$'\t'}"
  _docker_validate_uint "$index" "${#records[@]}" \
    && (( index >= 1 )) || return 1
  record="${records[index]}"

  local action_name=""
  local -i follow_logs=0
  case "$selected_key" in
    enter)  action_name="exec" ;;
    ctrl-l) action_name="logs"; follow_logs=0 ;;
    ctrl-s)
      container_state="${${record#*|}#*|}"
      container_state="${container_state%%|*}"
      [[ "$container_state" == "running" ]] \
        && action_name="stop" || action_name="start"
      ;;
    ctrl-d) action_name="remove" ;;
    *)
      _docker_error "Unknown container dashboard action."
      return 1
      ;;
  esac

  _docker_container_execute_action "$action_name" "$record" \
    "${context_snapshot[@]}" 0 0 0 0 "$follow_logs" 100 /bin/sh
}

docker-containers() {
  local action_name=""
  local requested_id=""
  local shell_name="/bin/sh"
  local -i tail_lines=100 follow_logs=0 dry_run=0 assume_yes=0
  local -i force_remove=0 allow_remote=0
  local -i id_seen=0 shell_seen=0 tail_seen=0 follow_seen=0
  local -i dry_run_seen=0 yes_seen=0 force_seen=0 remote_seen=0

  (( $# == 0 )) && {
    _docker_containers_interactive
    return $?
  }

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        (( $# == 1 )) || return 2
        _docker_containers_usage
        return 0
        ;;
      --action)
        (( $# >= 2 )) || {
          _docker_error "--action requires a value."
          return 2
        }
        action_name="$2"
        shift 2
        ;;
      --id)
        (( $# >= 2 )) || {
          _docker_error "--id requires a full container ID."
          return 2
        }
        requested_id="$2"
        id_seen=1
        shift 2
        ;;
      --shell)
        (( $# >= 2 )) || return 2
        shell_name="$2"
        shell_seen=1
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
      --dry-run)      dry_run=1; dry_run_seen=1; shift ;;
      --yes)          assume_yes=1; yes_seen=1; shift ;;
      --force)        force_remove=1; force_seen=1; shift ;;
      --allow-remote) allow_remote=1; remote_seen=1; shift ;;
      --)
        shift
        (( $# == 0 )) || return 2
        ;;
      -*)
        _docker_error "Unknown docker-containers option: $1"
        return 2
        ;;
      *)
        _docker_error "Unexpected docker-containers operand: $1"
        return 2
        ;;
    esac
  done

  case "$action_name" in
    list) ;;
    exec|logs|start|stop|remove)
      _docker_validate_container_id "$requested_id" || {
        _docker_error "A full 64-character container ID is required."
        return 2
      }
      ;;
    *)
      _docker_error "A valid --action is required."
      return 2
      ;;
  esac
  [[ "$shell_name" == "/bin/sh" || "$shell_name" == "/bin/bash" ]] || {
    _docker_error "--shell accepts only /bin/sh or /bin/bash."
    return 2
  }
  case "$action_name" in
    list)
      (( id_seen == 0 && shell_seen == 0 && tail_seen == 0 \
        && follow_seen == 0 && dry_run_seen == 0 && yes_seen == 0 \
        && force_seen == 0 && remote_seen == 0 )) || {
        _docker_error "The list action accepts no action-specific flags."
        return 2
      }
      ;;
    logs)
      (( shell_seen == 0 && dry_run_seen == 0 && yes_seen == 0 \
        && force_seen == 0 && remote_seen == 0 )) || {
        _docker_error \
          "The logs action accepts only --id, --tail, and --follow."
        return 2
      }
      ;;
    exec)
      (( tail_seen == 0 && follow_seen == 0 && dry_run_seen == 0 \
        && yes_seen == 0 && force_seen == 0 )) || {
        _docker_error \
          "The exec action accepts only --id, --shell, and --allow-remote."
        return 2
      }
      ;;
    start|stop)
      (( shell_seen == 0 && tail_seen == 0 && follow_seen == 0 \
        && yes_seen == 0 && force_seen == 0 )) || {
        _docker_error \
          "Start and stop accept only --id, --dry-run, and --allow-remote."
        return 2
      }
      ;;
    remove)
      (( shell_seen == 0 && tail_seen == 0 && follow_seen == 0 )) || {
        _docker_error \
          "Remove accepts only --id, --dry-run, --yes, --force, and --allow-remote."
        return 2
      }
      ;;
  esac

  _docker_context_snapshot || return 1
  local -a context_snapshot=("${reply[@]}")
  if [[ "$action_name" == "list" ]]; then
    _docker_container_inventory_data "${context_snapshot[@]}"
    return $?
  fi

  _docker_container_lookup "${context_snapshot[@]}" "$requested_id" || return 1
  local expected_record="$REPLY"
  _docker_container_execute_action "$action_name" "$expected_record" \
    "${context_snapshot[@]}" "$dry_run" "$assume_yes" "$force_remove" \
    "$allow_remote" "$follow_logs" "$tail_lines" "$shell_name"
}

typeset -g _DOCKER_CONTAINERS_SOURCED=1
