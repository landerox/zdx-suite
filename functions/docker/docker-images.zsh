#!/usr/bin/env zsh
# =============================================================================
# Docker Images: typed inventory and exact image actions
# =============================================================================
#
# Loaded by docker-menu.zsh after docker-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_DOCKER_IMAGES_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_docker_images_usage() {
  print -u2 -r -- 'Usage:'
  print -u2 -r -- '  docker-images'
  print -u2 -r -- '  docker-images --action list'
  print -u2 -r -- \
    '  docker-images --action run|remove --id sha256:FULL_ID [options]'
  print -u2 -r -- ''
  print -u2 -r -- 'Options:'
  print -u2 -r -- '  --shell /bin/sh|/bin/bash  Shell passed to an ephemeral run'
  print -u2 -r -- '  --dry-run                   Show the exact plan without mutation'
  print -u2 -r -- '  --yes                       Authorize non-interactive execution'
  print -u2 -r -- '  --force                     Force image removal explicitly'
  print -u2 -r -- '  --allow-remote              Allow mutation of a remote endpoint'
  print -u2 -r -- ''
  print -u2 -r -- \
    'Run requires terminal stdin/stdout and keeps session output on stdout.'
  print -u2 -r -- 'List output: id|repository|tag|size|created'
}

_docker_image_inventory_record_valid() {
  local record="${1:-}"
  local image_id="" repository="" tag_name="" size_display=""
  local created_display="" extra=""
  IFS='|' read -r image_id repository tag_name size_display \
    created_display extra <<< "$record"
  [[ -z "$extra" ]] \
    && _docker_validate_image_id "$image_id" \
    && _docker_visible_safe "$repository" 512 \
    && _docker_visible_safe "$tag_name" 256 \
    && _docker_visible_safe "$size_display" 128 \
    && _docker_visible_safe "$created_display" 256
}

# stdout records: id|repository|tag|size|created
_docker_image_inventory_data() {
  local -a context_snapshot=("$@")
  (( ${#context_snapshot[@]} == 6 )) || return 2
  _docker_context_command \
    "${context_snapshot[1]}" "${context_snapshot[2]}" || return 1
  local -a docker_command=("${reply[@]}")

  local inventory_output=""
  _docker_capture_probe_bounded "$_DOCKER_MAX_PICKER_BYTES" 10 \
    "${docker_command[@]}" \
    image ls -a --no-trunc \
    --format '{{.ID}}|{{.Repository}}|{{.Tag}}|{{.Size}}|{{.CreatedSince}}' \
    2>/dev/null || {
    _docker_error "Could not read the Docker image inventory."
    return 1
  }
  inventory_output="$REPLY"
  [[ -n "$inventory_output" ]] || return 0

  local record=""
  local -a records=()
  local -i record_count=0 total_bytes=0
  for record in "${(@f)inventory_output}"; do
    _docker_image_inventory_record_valid "$record" || {
      _docker_error "Docker returned a malformed image record."
      return 1
    }
    records+=("$record")
    (( record_count += 1 ))
    (( total_bytes += ${#record} + 1 ))
    (( record_count <= _DOCKER_MAX_RECORDS \
      && total_bytes <= _DOCKER_MAX_PICKER_BYTES )) || {
      _docker_error "The Docker image inventory exceeded its safety limit."
      return 1
    }
  done
  print -rl -- "${records[@]}"
}

# REPLY: id|repo-tags|created|size-bytes|os|architecture
_docker_image_identity() {
  local -a context_snapshot=("${(@)argv[1,6]}")
  local image_id="${7:-}"
  REPLY=""
  _docker_validate_image_id "$image_id" || return 2
  _docker_context_command \
    "${context_snapshot[1]}" "${context_snapshot[2]}" || return $?
  local -a docker_command=("${reply[@]}")

  local identity_record=""
  _docker_capture_probe_bounded 16384 10 "${docker_command[@]}" \
    image inspect \
    --format '{{.Id}}|{{join .RepoTags ","}}|{{.Created}}|{{.Size}}|{{.Os}}|{{.Architecture}}' \
    -- "$image_id" 2>/dev/null || {
    local -i probe_rc=$?
    _docker_error "The requested image is unavailable."
    return $probe_rc
  }
  identity_record="$REPLY"
  [[ "$identity_record" != *$'\n'* ]] || return 1
  local returned_id="" repo_tags="" created_at="" size_bytes=""
  local operating_system="" architecture="" extra=""
  IFS='|' read -r returned_id repo_tags created_at size_bytes \
    operating_system architecture extra <<< "$identity_record"
  [[ -z "$extra" && "$returned_id" == "$image_id" ]] \
    && _docker_validate_image_id "$returned_id" \
    && _docker_visible_safe "$repo_tags" 4096 \
    && _docker_visible_safe "$created_at" 256 \
    && [[ "$size_bytes" == <-> && ${#size_bytes} -le 18 ]] \
    && _docker_visible_safe "$operating_system" 64 \
    && _docker_visible_safe "$architecture" 64 || {
    _docker_error "Docker returned malformed image identity data."
    return 1
  }
  REPLY="$identity_record"
}

_docker_image_revalidate() {
  local -a context_snapshot=("${(@)argv[1,6]}")
  local expected_identity="${7:-}"
  local image_id="${expected_identity%%|*}"
  _docker_validate_image_id "$image_id" || return 1
  _docker_context_revalidate "${context_snapshot[@]}" || return 1
  _docker_image_identity "${context_snapshot[@]}" "$image_id" || return 1
  [[ "$REPLY" == "$expected_identity" ]] || {
    _docker_error "The selected image changed after review."
    return 1
  }
}

_docker_image_plan() {
  local action_name="$1"
  local expected_identity="$2"
  local -a context_snapshot=("${(@)argv[3,8]}")
  local image_id="" repo_tags="" created_at="" size_bytes=""
  local operating_system="" architecture="" extra=""
  IFS='|' read -r image_id repo_tags created_at size_bytes \
    operating_system architecture extra <<< "$expected_identity"
  _docker_context_label "${context_snapshot[@]}" || return 1
  _docker_header "Docker Image Plan"
  _docker_info "Context: $REPLY"
  _docker_info "Action: $action_name"
  _docker_info "Full ID: $image_id"
  _docker_info "Repository tags: ${repo_tags:-<none>}"
  _docker_info "Size bytes: $size_bytes"
  _docker_info "Platform: $operating_system/$architecture"
}

_docker_image_execute_action() {
  local action_name="$1"
  local expected_identity="$2"
  local -a context_snapshot=("${(@)argv[3,8]}")
  local -i dry_run="${9:-0}"
  local -i assume_yes="${10:-0}"
  local -i force_remove="${11:-0}"
  local -i allow_remote="${12:-0}"
  local shell_name="${13:-/bin/sh}"
  local image_id="${expected_identity%%|*}"

  _docker_image_plan "$action_name" "$expected_identity" \
    "${context_snapshot[@]}" || return 1
  _docker_warn \
    "Running an image or removing it can execute or destroy Docker-managed state."

  (( dry_run )) && {
    _docker_success "Dry run complete; no image action was executed."
    return 0
  }
  _docker_require_mutation_context \
    "${context_snapshot[6]}" "$allow_remote" || return 1

  if (( ! assume_yes )); then
    local -i confirm_rc=0
    _docker_confirm "Execute this exact image action?" || confirm_rc=$?
    case "$confirm_rc" in
      0) ;;
      130)
        _docker_info "Image action cancelled."
        return 0
        ;;
      *)
        _docker_error "Non-interactive image actions require --yes."
        return 1
        ;;
    esac
  fi

  _docker_image_revalidate \
    "${context_snapshot[@]}" "$expected_identity" || return 1
  _docker_context_command \
    "${context_snapshot[1]}" "${context_snapshot[2]}" || return 1
  local -a docker_command=("${reply[@]}")
  local -a operation=()
  case "$action_name" in
    run)
      [[ -t 0 && -t 1 ]] || {
        _docker_error "Interactive image execution requires a terminal."
        return 1
      }
      operation=(
        "${docker_command[@]}" run -it --rm -- "$image_id" "$shell_name"
      )
      ;;
    remove)
      operation=("${docker_command[@]}" image rm)
      (( force_remove )) && operation+=(--force)
      operation+=(-- "$image_id")
      ;;
    *)
      return 2
      ;;
  esac

  if [[ "$action_name" == "run" ]]; then
    command "${operation[@]}"
  else
    command "${operation[@]}" >&2
  fi
  local -i operation_rc=$?
  if (( operation_rc == 0 )); then
    _docker_success "Image action completed."
  else
    _docker_error "Image action failed (status $operation_rc)."
  fi
  return $operation_rc
}

_docker_images_interactive() {
  _docker_require_cmd fzf "the image dashboard" || return 1
  _docker_context_snapshot || return 1
  local -a context_snapshot=("${reply[@]}")
  local inventory_output=""
  inventory_output=$(_docker_image_inventory_data \
    "${context_snapshot[@]}") || return 1
  [[ -n "$inventory_output" ]] || {
    _docker_info "No images found in the selected Docker context."
    return 0
  }

  local -a records=("${(@f)inventory_output}")
  local -a rows=()
  local record="" image_id="" repository="" tag_name=""
  local size_display="" created_display="" extra=""
  local -i index=0
  for record in "${records[@]}"; do
    IFS='|' read -r image_id repository tag_name size_display \
      created_display extra <<< "$record"
    (( index += 1 ))
    rows+=("$repository:$tag_name [$size_display] $created_display"$'\t'"$index")
  done

  _docker_context_label "${context_snapshot[@]}" || return 1
  local context_header="$REPLY"
  local -i fzf_rc=0
  _docker_fzf_capture \
    --height=70% \
    --delimiter=$'\t' \
    --with-nth=1 \
    --expect='enter,ctrl-d' \
    --prompt='docker images > ' \
    --header="$context_header | Enter run after review | Ctrl-D remove | Esc cancel" \
    < <(printf '%s\n' "${rows[@]}") || fzf_rc=$?
  local selected="$REPLY"
  if (( fzf_rc != 0 )); then
    _docker_fzf_rc_is_cancel "$fzf_rc" && return 0
    _docker_error "Unable to open the image dashboard (status $fzf_rc)."
    return 1
  fi
  [[ -n "$selected" ]] || return 0

  local -a selected_lines=("${(@f)selected}")
  (( ${#selected_lines[@]} == 2 )) || {
    _docker_error "The image dashboard returned a malformed selection."
    return 1
  }
  local selected_key="${selected_lines[1]}"
  local selected_row="${selected_lines[2]}"
  _docker_array_contains_literal "$selected_row" "${rows[@]}" || {
    _docker_error "The selected image was not in the inventory snapshot."
    return 1
  }
  index="${selected_row##*$'\t'}"
  _docker_validate_uint "$index" "${#records[@]}" \
    && (( index >= 1 )) || return 1
  record="${records[index]}"
  image_id="${record%%|*}"
  _docker_image_identity "${context_snapshot[@]}" "$image_id" || return 1
  local expected_identity="$REPLY"

  local action_name=""
  case "$selected_key" in
    enter)  action_name="run" ;;
    ctrl-d) action_name="remove" ;;
    *)
      _docker_error "Unknown image dashboard action."
      return 1
      ;;
  esac
  _docker_image_execute_action "$action_name" "$expected_identity" \
    "${context_snapshot[@]}" 0 0 0 0 /bin/sh
}

docker-images() {
  local action_name=""
  local requested_id=""
  local shell_name="/bin/sh"
  local -i dry_run=0 assume_yes=0 force_remove=0 allow_remote=0
  local -i id_seen=0 shell_seen=0 dry_seen=0 yes_seen=0
  local -i force_seen=0 remote_seen=0

  (( $# == 0 )) && {
    _docker_images_interactive
    return $?
  }

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        (( $# == 1 )) || return 2
        _docker_images_usage
        return 0
        ;;
      --action)
        (( $# >= 2 )) || return 2
        action_name="$2"
        shift 2
        ;;
      --id)
        (( $# >= 2 )) || return 2
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
      --dry-run)      dry_run=1; dry_seen=1; shift ;;
      --yes)          assume_yes=1; yes_seen=1; shift ;;
      --force)        force_remove=1; force_seen=1; shift ;;
      --allow-remote) allow_remote=1; remote_seen=1; shift ;;
      --)
        shift
        (( $# == 0 )) || return 2
        ;;
      -*)
        _docker_error "Unknown docker-images option: $1"
        return 2
        ;;
      *)
        _docker_error "Unexpected docker-images operand: $1"
        return 2
        ;;
    esac
  done

  case "$action_name" in
    list) ;;
    run|remove)
      _docker_validate_image_id "$requested_id" || {
        _docker_error "A full sha256 image ID is required."
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
      (( id_seen == 0 && shell_seen == 0 && dry_seen == 0 \
        && yes_seen == 0 && force_seen == 0 && remote_seen == 0 )) || {
        _docker_error "The list action accepts no action-specific flags."
        return 2
      }
      ;;
    run)
      (( force_seen == 0 )) || {
        _docker_error \
          "The run action accepts --shell, --dry-run, --yes, and --allow-remote; not --force."
        return 2
      }
      ;;
    remove)
      (( shell_seen == 0 )) || {
        _docker_error \
          "The remove action does not accept --shell."
        return 2
      }
      ;;
  esac

  _docker_context_snapshot || return 1
  local -a context_snapshot=("${reply[@]}")
  if [[ "$action_name" == "list" ]]; then
    _docker_image_inventory_data "${context_snapshot[@]}"
    return $?
  fi

  _docker_image_identity "${context_snapshot[@]}" "$requested_id" || return 1
  local expected_identity="$REPLY"
  _docker_image_execute_action "$action_name" "$expected_identity" \
    "${context_snapshot[@]}" "$dry_run" "$assume_yes" "$force_remove" \
    "$allow_remote" "$shell_name"
}

typeset -g _DOCKER_IMAGES_SOURCED=1
