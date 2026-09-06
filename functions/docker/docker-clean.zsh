#!/usr/bin/env zsh
# =============================================================================
# Docker Clean: exact, reviewable cleanup plans without prune
# =============================================================================
#
# Loaded by docker-menu.zsh after docker-common.zsh and inventory modules.
# Safe to re-source; defines functions only.
#

if [[ -n "${_DOCKER_CLEAN_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_docker_clean_usage() {
  print -u2 -r -- 'Usage:'
  print -u2 -r -- '  docker-clean'
  print -u2 -r -- \
    '  docker-clean --scope SCOPE [--dry-run] [--yes] [--allow-remote]'
  print -u2 -r -- ''
  print -u2 -r -- 'Scopes:'
  print -u2 -r -- '  stopped-containers  Stopped container IDs'
  print -u2 -r -- '  dangling-images     Dangling full image IDs'
  print -u2 -r -- '  unused-networks     Unused custom network IDs'
  print -u2 -r -- '  unused-volumes      Unused volume names; never included by all'
  print -u2 -r -- '  all                 Containers, images, and networks only'
  print -u2 -r -- ''
  print -u2 -r -- \
    'Execution removes only the exact frozen records; it never invokes Docker prune.'
}

_docker_clean_scope_valid() {
  case "${1:-}" in
    stopped-containers|dangling-images|unused-networks|unused-volumes|all)
      return 0
      ;;
    *) return 1 ;;
  esac
}

_docker_clean_record_valid() {
  local record="${1:-}"
  local kind="${record%%|*}"
  local target="" field3="" field4="" field5="" field6="" field7="" extra=""
  case "$kind" in
    container)
      IFS='|' read -r kind target field3 field4 field5 extra <<< "$record"
      [[ -z "$extra" ]] \
        && _docker_validate_container_id "$target" \
        && _docker_validate_name "$field3" \
        && [[ "$field4" =~ '^(created|exited|dead)$' ]] \
        && _docker_visible_safe "$field5" 1024
      ;;
    image)
      IFS='|' read -r kind target field3 field4 field5 \
        field6 field7 extra <<< "$record"
      [[ -z "$extra" ]] \
        && _docker_validate_image_id "$target" \
        && _docker_visible_safe "$field3" 4096 \
        && _docker_visible_safe "$field4" 256 \
        && [[ "$field5" == <-> && ${#field5} -le 18 ]] \
        && _docker_visible_safe "$field6" 64 \
        && _docker_visible_safe "$field7" 64
      ;;
    network)
      IFS='|' read -r kind target field3 field4 field5 extra <<< "$record"
      [[ -z "$extra" && "$target" =~ '^[0-9a-f]{64}$' ]] \
        && _docker_validate_name "$field3" \
        && _docker_visible_safe "$field4" 128 \
        && _docker_visible_safe "$field5" 128
      ;;
    volume)
      IFS='|' read -r kind target field3 field4 field5 extra <<< "$record"
      [[ -z "$extra" ]] \
        && _docker_validate_name "$target" \
        && _docker_visible_safe "$field3" 128 \
        && [[ -n "$field3" && "$field3" != "<no value>" ]] \
        && _docker_visible_safe "$field4" 256 \
        && [[ -n "$field4" && "$field4" != "<no value>" ]] \
        && [[ "$field5" =~ '^[0-9a-f]{64}$' ]]
      ;;
    *) return 1 ;;
  esac
}

_docker_volume_identity() {
  local -a context_snapshot=("${(@)argv[1,6]}")
  local volume_name="${7:-}"
  REPLY=""
  _docker_validate_name "$volume_name" || return 2
  _docker_context_command \
    "${context_snapshot[1]}" "${context_snapshot[2]}" || return $?
  local -a docker_command=("${reply[@]}")

  local complete_record=""
  _docker_capture_probe_bounded 65536 10 \
    "${docker_command[@]}" volume inspect \
    --format '{{.Name}}|{{.Driver}}|{{.Scope}}|{{.CreatedAt}}|{{json .Labels}}|{{json .Options}}|{{.Mountpoint}}' \
    -- "$volume_name" 2>/dev/null || {
    local -i probe_rc=$?
    _docker_error "The requested Docker volume is unavailable."
    return $probe_rc
  }
  complete_record="$REPLY"
  _docker_visible_safe "$complete_record" 65536 || {
    _docker_error "Docker returned malformed volume identity data."
    return 1
  }

  local returned_name="${complete_record%%|*}"
  local remaining="${complete_record#*|}"
  [[ "$remaining" != "$complete_record" ]] || return 1
  local driver_name="${remaining%%|*}"
  remaining="${remaining#*|}"
  local volume_scope="${remaining%%|*}"
  remaining="${remaining#*|}"
  local created_at="${remaining%%|*}"
  local protected_metadata="${remaining#*|}"
  [[ "$returned_name" == "$volume_name" \
    && -n "$driver_name" && -n "$volume_scope" && -n "$created_at" \
    && "$driver_name" != "<no value>" \
    && "$volume_scope" != "<no value>" \
    && "$created_at" != "<no value>" \
    && "$protected_metadata" != "$remaining" \
    && -n "$protected_metadata" ]] \
    && _docker_validate_name "$returned_name" \
    && _docker_visible_safe "$driver_name" 128 \
    && _docker_visible_safe "$volume_scope" 128 \
    && _docker_visible_safe "$created_at" 256 || {
    _docker_error "Docker returned malformed volume identity data."
    return 1
  }

  _docker_sha256_text "$complete_record" || return $?
  local identity_digest="$REPLY"
  REPLY="$returned_name|$driver_name|$created_at|$identity_digest"
}

_docker_clean_collect_containers() {
  local -a context_snapshot=("$@")
  _docker_context_command \
    "${context_snapshot[1]}" "${context_snapshot[2]}" || return $?
  local -a docker_command=("${reply[@]}")
  local inventory_output=""
  _docker_capture_probe_bounded "$_DOCKER_MAX_PICKER_BYTES" 10 \
    "${docker_command[@]}" \
    container ls -a --no-trunc \
    --filter status=created --filter status=exited --filter status=dead \
    --format '{{.ID}}|{{.Names}}|{{.State}}|{{.Image}}' \
    2>/dev/null || {
    local -i probe_rc=$?
    _docker_error "Could not discover stopped containers."
    return $probe_rc
  }
  inventory_output="$REPLY"
  local raw_record="" plan_record=""
  local -i record_count=0 output_bytes=0
  for raw_record in "${(@f)inventory_output}"; do
    [[ -n "$raw_record" ]] || continue
    plan_record="container|$raw_record"
    _docker_clean_record_valid "$plan_record" || {
      _docker_error "Docker returned a malformed stopped-container record."
      return 1
    }
    (( record_count += 1 ))
    (( output_bytes += ${#plan_record} + 1 ))
    (( record_count <= _DOCKER_MAX_RECORDS \
      && output_bytes <= _DOCKER_MAX_PICKER_BYTES )) || return 1
    print -r -- "$plan_record"
  done
}

_docker_clean_collect_images() {
  local -a context_snapshot=("$@")
  _docker_context_command \
    "${context_snapshot[1]}" "${context_snapshot[2]}" || return $?
  local -a docker_command=("${reply[@]}")
  local inventory_output=""
  _docker_capture_probe_bounded "$_DOCKER_MAX_PICKER_BYTES" 10 \
    "${docker_command[@]}" \
    image ls -a --no-trunc --filter dangling=true \
    --format '{{.ID}}' 2>/dev/null || {
    local -i probe_rc=$?
    _docker_error "Could not discover dangling images."
    return $probe_rc
  }
  inventory_output="$REPLY"
  local image_id="" identity_record="" plan_record=""
  local -A seen=()
  local -i image_count=0 output_bytes=0
  for image_id in "${(@f)inventory_output}"; do
    [[ -n "$image_id" && -z "${seen[$image_id]:-}" ]] || continue
    (( image_count += 1 ))
    (( image_count <= _DOCKER_MAX_RECORDS )) || {
      _docker_error "The dangling-image inventory exceeded its record limit."
      return 1
    }
    _docker_validate_image_id "$image_id" || {
      _docker_error "Docker returned a malformed dangling-image ID."
      return 1
    }
    seen[$image_id]=1
    _docker_image_identity "${context_snapshot[@]}" "$image_id" || return $?
    identity_record="$REPLY"
    plan_record="image|$identity_record"
    _docker_clean_record_valid "$plan_record" || return 1
    (( output_bytes += ${#plan_record} + 1 ))
    (( output_bytes <= _DOCKER_MAX_PICKER_BYTES )) || {
      _docker_error "The dangling-image plan exceeded its byte limit."
      return 1
    }
    print -r -- "$plan_record"
  done
}

_docker_clean_collect_networks() {
  local -a context_snapshot=("$@")
  _docker_context_command \
    "${context_snapshot[1]}" "${context_snapshot[2]}" || return $?
  local -a docker_command=("${reply[@]}")
  local inventory_output=""
  _docker_capture_probe_bounded "$_DOCKER_MAX_PICKER_BYTES" 10 \
    "${docker_command[@]}" \
    network ls --no-trunc --filter dangling=true \
    --format '{{.ID}}|{{.Name}}|{{.Driver}}|{{.Scope}}' \
    2>/dev/null || {
    local -i probe_rc=$?
    _docker_error "Could not discover unused Docker networks."
    return $probe_rc
  }
  inventory_output="$REPLY"
  local raw_record="" plan_record="" network_name=""
  local -i record_count=0 output_bytes=0
  for raw_record in "${(@f)inventory_output}"; do
    [[ -n "$raw_record" ]] || continue
    network_name="${${raw_record#*|}%%|*}"
    case "$network_name" in
      bridge|host|none) continue ;;
    esac
    plan_record="network|$raw_record"
    _docker_clean_record_valid "$plan_record" || {
      _docker_error "Docker returned a malformed unused-network record."
      return 1
    }
    (( record_count += 1 ))
    (( output_bytes += ${#plan_record} + 1 ))
    (( record_count <= _DOCKER_MAX_RECORDS \
      && output_bytes <= _DOCKER_MAX_PICKER_BYTES )) || return 1
    print -r -- "$plan_record"
  done
}

_docker_clean_collect_volumes() {
  local -a context_snapshot=("$@")
  _docker_context_command \
    "${context_snapshot[1]}" "${context_snapshot[2]}" || return $?
  local -a docker_command=("${reply[@]}")
  local inventory_output=""
  _docker_capture_probe_bounded "$_DOCKER_MAX_PICKER_BYTES" 10 \
    "${docker_command[@]}" \
    volume ls --filter dangling=true \
    --format '{{.Name}}' 2>/dev/null || {
    local -i probe_rc=$?
    _docker_error "Could not discover unused Docker volumes."
    return $probe_rc
  }
  inventory_output="$REPLY"
  local volume_name="" plan_record=""
  local -A seen=()
  local -i record_count=0 output_bytes=0
  for volume_name in "${(@f)inventory_output}"; do
    [[ -n "$volume_name" && -z "${seen[$volume_name]:-}" ]] || continue
    _docker_validate_name "$volume_name" || {
      _docker_error "Docker returned a malformed unused-volume name."
      return 1
    }
    seen[$volume_name]=1
    _docker_volume_identity \
      "${context_snapshot[@]}" "$volume_name" || return $?
    plan_record="volume|$REPLY"
    _docker_clean_record_valid "$plan_record" || {
      _docker_error "Docker returned a malformed unused-volume record."
      return 1
    }
    (( record_count += 1 ))
    (( output_bytes += ${#plan_record} + 1 ))
    (( record_count <= _DOCKER_MAX_RECORDS \
      && output_bytes <= _DOCKER_MAX_PICKER_BYTES )) || return 1
    print -r -- "$plan_record"
  done
}

# stdout is a bounded list of exact cleanup plan records.
_docker_clean_plan_data() {
  local scope_name="$1"
  local -a context_snapshot=("${(@)argv[2,7]}")
  _docker_clean_scope_valid "$scope_name" || return 2
  (( ${#context_snapshot[@]} == 6 )) || return 2

  local -a requested_scopes=()
  if [[ "$scope_name" == "all" ]]; then
    requested_scopes=(
      stopped-containers
      dangling-images
      unused-networks
    )
  else
    requested_scopes=("$scope_name")
  fi

  local child_scope="" scope_output="" record=""
  local -a records=()
  local -A seen=()
  local -i total_bytes=0
  for child_scope in "${requested_scopes[@]}"; do
    case "$child_scope" in
      stopped-containers)
        scope_output=$(_docker_clean_collect_containers \
          "${context_snapshot[@]}") || return $?
        ;;
      dangling-images)
        scope_output=$(_docker_clean_collect_images \
          "${context_snapshot[@]}") || return $?
        ;;
      unused-networks)
        scope_output=$(_docker_clean_collect_networks \
          "${context_snapshot[@]}") || return $?
        ;;
      unused-volumes)
        scope_output=$(_docker_clean_collect_volumes \
          "${context_snapshot[@]}") || return $?
        ;;
    esac
    for record in "${(@f)scope_output}"; do
      [[ -n "$record" && -z "${seen[$record]:-}" ]] || continue
      _docker_clean_record_valid "$record" || return 1
      seen[$record]=1
      records+=("$record")
      (( total_bytes += ${#record} + 1 ))
      (( ${#records[@]} <= _DOCKER_MAX_RECORDS \
        && total_bytes <= _DOCKER_MAX_PICKER_BYTES )) || {
        _docker_error "The Docker cleanup plan exceeded its safety limit."
        return 1
      }
    done
  done
  print -rl -- "${records[@]}"
}

_docker_clean_record_scope() {
  case "${1%%|*}" in
    container) REPLY="stopped-containers" ;;
    image)     REPLY="dangling-images" ;;
    network)   REPLY="unused-networks" ;;
    volume)    REPLY="unused-volumes" ;;
    *)         return 1 ;;
  esac
}

_docker_clean_record_revalidate() {
  local expected_record="$1"
  local -a context_snapshot=("${(@)argv[2,7]}")
  _docker_clean_record_valid "$expected_record" || return 1
  _docker_context_revalidate "${context_snapshot[@]}" || return $?
  _docker_context_command \
    "${context_snapshot[1]}" "${context_snapshot[2]}" || return $?
  local -a docker_command=("${reply[@]}")
  local kind="${expected_record%%|*}"
  local target="${${expected_record#*|}%%|*}"
  local current_record=""

  case "$kind" in
    container)
      _docker_capture_probe_bounded 4096 10 \
        "${docker_command[@]}" container inspect \
        --format '{{.Id}}|{{.Name}}|{{.State.Status}}|{{.Config.Image}}' \
        -- "$target" 2>/dev/null || return $?
      current_record="$REPLY"
      local raw_name="${${current_record#*|}%%|*}"
      [[ "$raw_name" == /* ]] || return 1
      current_record="${current_record%%|*}|${raw_name#/}|"\
"${${current_record#*|}#*|}"
      current_record="container|$current_record"
      ;;
    image)
      _docker_image_identity \
        "${context_snapshot[@]}" "$target" || return $?
      current_record="image|$REPLY"
      ;;
    network)
      _docker_capture_probe_bounded 4096 10 \
        "${docker_command[@]}" network inspect \
        --format '{{.Id}}|{{.Name}}|{{.Driver}}|{{.Scope}}|{{len .Containers}}' \
        -- "$target" 2>/dev/null || return $?
      local network_record="$REPLY"
      local network_id="" network_name="" network_driver=""
      local network_scope="" connection_count="" extra=""
      IFS='|' read -r network_id network_name network_driver network_scope \
        connection_count extra <<< "$network_record"
      [[ -z "$extra" && "$connection_count" == "0" ]] || return 1
      current_record="network|$network_id|$network_name|$network_driver|$network_scope"
      ;;
    volume)
      _docker_volume_identity \
        "${context_snapshot[@]}" "$target" || return $?
      current_record="volume|$REPLY"
      _docker_capture_probe_bounded 4096 10 \
        "${docker_command[@]}" container ls -a \
        --filter "volume=$target" --format '{{.ID}}' \
        2>/dev/null || return $?
      [[ -z "$REPLY" ]] || return 1
      ;;
    *) return 1 ;;
  esac

  [[ "$current_record" == "$expected_record" ]] || {
    _docker_error "A cleanup target changed or is no longer eligible."
    return 1
  }
}

_docker_clean_batch_revalidate() {
  local scope_name="$1"
  local expected_output="$2"
  local -a context_snapshot=("${(@)argv[3,8]}")
  _docker_context_revalidate "${context_snapshot[@]}" || return $?
  local current_output=""
  current_output=$(_docker_clean_plan_data \
    "$scope_name" "${context_snapshot[@]}") || return $?

  local -A expected_set=() current_set=()
  local record=""
  local -i expected_count=0 current_count=0
  for record in "${(@f)expected_output}"; do
    [[ -n "$record" ]] || continue
    expected_set[$record]=1
    (( expected_count += 1 ))
  done
  for record in "${(@f)current_output}"; do
    [[ -n "$record" ]] || continue
    current_set[$record]=1
    (( current_count += 1 ))
  done
  (( expected_count == current_count )) || {
    _docker_error "The Docker cleanup plan changed after review."
    return 1
  }
  for record in "${(@k)expected_set}"; do
    [[ -n "${current_set[$record]:-}" ]] || {
      _docker_error "The Docker cleanup plan changed after review."
      return 1
    }
  done
}

_docker_clean_render_plan() {
  local scope_name="$1"
  local plan_output="$2"
  local -a context_snapshot=("${(@)argv[3,8]}")
  _docker_context_label "${context_snapshot[@]}" || return 1
  _docker_header "Docker Cleanup Plan"
  _docker_info "Context: $REPLY"
  _docker_info "Scope: $scope_name"
  [[ "$scope_name" == "all" ]] \
    && _docker_warn "The all scope deliberately excludes every volume."

  local record="" kind="" target="" description=""
  local -i count=0
  for record in "${(@f)plan_output}"; do
    [[ -n "$record" ]] || continue
    kind="${record%%|*}"
    target="${${record#*|}%%|*}"
    description="${record#*|*|}"
    _docker_info "$kind | $target | $description"
    (( count += 1 ))
  done
  _docker_info "Exact target count: $count"
}

_docker_clean_execute_record() {
  local record="$1"
  local -a context_snapshot=("${(@)argv[2,7]}")
  _docker_clean_record_revalidate \
    "$record" "${context_snapshot[@]}" || return $?
  _docker_context_command \
    "${context_snapshot[1]}" "${context_snapshot[2]}" || return $?
  local -a docker_command=("${reply[@]}")
  local kind="${record%%|*}"
  local target="${${record#*|}%%|*}"
  local -a operation=()
  case "$kind" in
    container) operation=("${docker_command[@]}" container rm -- "$target") ;;
    image)     operation=("${docker_command[@]}" image rm -- "$target") ;;
    network)   operation=("${docker_command[@]}" network rm -- "$target") ;;
    volume)    operation=("${docker_command[@]}" volume rm -- "$target") ;;
    *)         return 2 ;;
  esac
  command "${operation[@]}" >&2
}

_docker_clean_select_scope() {
  REPLY=""
  _docker_require_cmd fzf "interactive Docker cleanup" || return 1
  local -a rows=(
    $'Stopped containers\tstopped-containers'
    $'Dangling images\tdangling-images'
    $'Unused custom networks\tunused-networks'
    $'Unused volumes (data loss risk)\tunused-volumes'
    $'All except volumes\tall'
  )
  local -i fzf_rc=0
  _docker_fzf_capture \
    --height=40% \
    --delimiter=$'\t' \
    --with-nth=1 \
    --prompt='docker clean > ' \
    --header='Up/Down navigate | Enter build exact plan | Esc cancel' \
    < <(printf '%s\n' "${rows[@]}") || fzf_rc=$?
  local selected="$REPLY"
  if (( fzf_rc != 0 )); then
    _docker_fzf_rc_is_cancel "$fzf_rc" && return 130
    return 1
  fi
  [[ -n "$selected" ]] || return 130
  _docker_array_contains_literal "$selected" "${rows[@]}" || return 1
  REPLY="${selected##*$'\t'}"
  _docker_clean_scope_valid "$REPLY"
}

docker-clean() {
  local scope_name=""
  local -i dry_run=0 assume_yes=0 allow_remote=0

  if (( $# == 0 )); then
    _docker_clean_select_scope
    local -i select_rc=$?
    (( select_rc == 130 )) && return 0
    (( select_rc == 0 )) || {
      _docker_error "Could not select a Docker cleanup scope."
      return 1
    }
    scope_name="$REPLY"
  else
    while (( $# > 0 )); do
      case "$1" in
        -h|--help)
          (( $# == 1 )) || return 2
          _docker_clean_usage
          return 0
          ;;
        --scope)
          (( $# >= 2 )) || {
            _docker_error "--scope requires a value."
            return 2
          }
          scope_name="$2"
          shift 2
          ;;
        --dry-run)      dry_run=1; shift ;;
        --yes)          assume_yes=1; shift ;;
        --allow-remote) allow_remote=1; shift ;;
        --)
          shift
          (( $# == 0 )) || return 2
          ;;
        -*)
          _docker_error "Unknown docker-clean option: $1"
          return 2
          ;;
        *)
          _docker_error "Unexpected docker-clean operand: $1"
          return 2
          ;;
      esac
    done
  fi

  _docker_clean_scope_valid "$scope_name" || {
    _docker_error "A valid Docker cleanup --scope is required."
    return 2
  }
  _docker_context_snapshot || return $?
  local -a context_snapshot=("${reply[@]}")

  local plan_output=""
  plan_output=$(_docker_clean_plan_data \
    "$scope_name" "${context_snapshot[@]}") || {
    local -i probe_rc=$?
    _docker_error "Could not build an exact Docker cleanup plan."
    return $probe_rc
  }
  _docker_clean_render_plan \
    "$scope_name" "$plan_output" "${context_snapshot[@]}" || return 1
  [[ -n "$plan_output" ]] || {
    _docker_success "No eligible Docker resources were found."
    return 0
  }
  (( dry_run )) && {
    _docker_success "Dry run complete; no Docker resource was removed."
    return 0
  }
  _docker_require_mutation_context \
    "${context_snapshot[6]}" "$allow_remote" || return 1

  if (( ! assume_yes )); then
    local -i confirm_rc=0
    _docker_confirm "Remove every exact resource in this plan?" \
      || confirm_rc=$?
    case "$confirm_rc" in
      0) ;;
      130)
        _docker_info "Docker cleanup cancelled."
        return 0
        ;;
      *)
        _docker_error "Non-interactive Docker cleanup requires --yes."
        return 1
        ;;
    esac
  fi

  _docker_clean_batch_revalidate \
    "$scope_name" "$plan_output" "${context_snapshot[@]}" || return $?
  local record=""
  local -a planned_records=("${(@f)plan_output}")
  local -i passed=0 failed=0 processed=0 operation_rc=0
  for record in "${planned_records[@]}"; do
    [[ -n "$record" ]] || continue
    (( processed += 1 ))
    if _docker_clean_execute_record "$record" "${context_snapshot[@]}"; then
      (( passed += 1 ))
    else
      operation_rc=$?
      if (( operation_rc == 130 || operation_rc == 143 )); then
        _docker_warn "Docker cleanup interrupted at ${${record#*|}%%|*}."
        _docker_info "Docker cleanup summary: removed $passed, failed $failed, interrupted 1, not attempted: $(( ${#planned_records[@]} - processed ))."
        _docker_warn "Verify the interrupted target before retrying."
        return $operation_rc
      fi
      (( failed += 1 ))
      _docker_error "Failed cleanup target: ${${record#*|}%%|*}"
    fi
  done
  _docker_info "Docker cleanup summary: removed $passed, failed $failed."
  (( failed == 0 )) || return 1
  _docker_success "Docker cleanup completed."
}

typeset -g _DOCKER_CLEAN_SOURCED=1
