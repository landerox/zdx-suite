#!/usr/bin/env zsh
# =============================================================================
# App Tasks: bounded discovery and fixed-backend project task execution
# =============================================================================
#
# Loaded by app-menu.zsh after app-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_APP_TASKS_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_app_list_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- "  app-list"
  print -u2 -r -- "  app-list --help"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Outputs: backend<TAB>task<TAB>action<TAB>workspace<TAB>descriptor"
  print -u2 -r -- \
    "Discovery covers the current directory and, when different, its Git root."
}

_app_run_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- \
    "  app-run --backend BACKEND --task TASK [--action ACTION]"
  print -u2 -r -- \
    "          [--directory DIRECTORY] [--dry-run] [--yes]"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Backends: just, npm, pnpm, yarn, bun, make, compose"
  print -u2 -r -- \
    "Actions: run; or compose up, down, ps, up-service,"
  print -u2 -r -- "         restart-service, logs-service"
  print -u2 -r -- \
    "Compose up, down, and ps use --task all; service actions use a service name."
  print -u2 -r -- ""
  print -u2 -r -- \
    "Project task descriptors are executable-code trust boundaries."
  print -u2 -r -- \
    "Use --dry-run to review the fixed backend invocation."
  print -u2 -r -- \
    "Non-interactive execution requires --yes."
}

_app_record_byte_count() {
  emulate -L zsh
  unsetopt MULTIBYTE
  REPLY=$(( ${#1} + 1 ))
}

_app_package_manager_for_workspace() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local workspace="${1:-}"
  REPLY="npm"
  local marker="" manager=""
  local -a markers=(
    package-lock.json
    npm-shrinkwrap.json
    pnpm-lock.yaml
    yarn.lock
    bun.lock
    bun.lockb
  )
  local -a marker_managers=(npm npm pnpm yarn bun bun)
  local -a managers=()
  local -A marker_state=() seen=()
  local -i marker_index=0
  for (( marker_index = 1; marker_index <= ${#markers[@]}; marker_index++ )); do
    marker="${markers[$marker_index]}"
    manager="${marker_managers[$marker_index]}"
    [[ -e "$workspace/$marker" || -L "$workspace/$marker" ]] || continue
    marker_state=()
    [[ -f "$workspace/$marker" && ! -L "$workspace/$marker" ]] \
      && zstat -LH marker_state -- "$workspace/$marker" 2>/dev/null \
      && (( marker_state[uid] == EUID \
        && marker_state[nlink] == 1 \
        && (marker_state[mode] & 8#22) == 0 \
        && (marker_state[mode] & 8#170000) == 8#100000 )) || {
      _app_error "A package-manager marker has unsafe identity or permissions."
      return 1
    }
    [[ -n "${seen[$manager]:-}" ]] && continue
    seen[$manager]=1
    managers+=("$manager")
  done

  (( ${#managers[@]} <= 1 )) || {
    _app_error "Multiple package-manager lock families make task routing ambiguous."
    return 1
  }
  if (( ${#managers[@]} == 1 )); then
    REPLY="${managers[1]}"
  fi
  return 0
}

_app_descriptor_for_backend() {
  local workspace="${1:-}"
  local backend="${2:-}"
  REPLY=""

  case "$backend" in
    just)
      if [[ -f "$workspace/Justfile" || -L "$workspace/Justfile" ]]; then
        REPLY="$workspace/Justfile"
      elif [[ -f "$workspace/justfile" || -L "$workspace/justfile" ]]; then
        REPLY="$workspace/justfile"
      fi
      ;;
    npm|pnpm|yarn|bun)
      [[ -e "$workspace/package.json" || -L "$workspace/package.json" ]] \
        && REPLY="$workspace/package.json"
      ;;
    make)
      if [[ -f "$workspace/Makefile" || -L "$workspace/Makefile" ]]; then
        REPLY="$workspace/Makefile"
      elif [[ -f "$workspace/makefile" || -L "$workspace/makefile" ]]; then
        REPLY="$workspace/makefile"
      fi
      ;;
    compose)
      local candidate=""
      for candidate in \
        compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
        if [[ -f "$workspace/$candidate" || -L "$workspace/$candidate" ]]; then
          REPLY="$workspace/$candidate"
          break
        fi
      done
      ;;
    *) return 2 ;;
  esac
  [[ -n "$REPLY" ]]
}

_app_discover_line_tasks() {
  emulate -L zsh
  setopt LOCAL_OPTIONS EXTENDED_GLOB
  local backend="$1"
  local workspace="$2"
  local descriptor="$3"
  local fingerprint="$4"
  local line="" candidate="" task_name="" record=""
  local -A seen=()
  local -i task_count=0 output_bytes=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" && "$line" != [[:space:]]* && "$line" != \#* ]] || continue
    [[ "$line" == *:* ]] || continue

    candidate="${line%%:*}"
    if [[ "$backend" == "just" ]]; then
      [[ "$line" != *':='* ]] || continue
      candidate="${candidate#@}"
      task_name="${candidate%%[[:space:]]*}"
    else
      [[ "$candidate" != *[[:space:]]* \
        && "$candidate" != .* && "$candidate" != *'%'* ]] || continue
      task_name="$candidate"
    fi

    _app_validate_task_token "$task_name" || continue
    [[ -z "${seen[$task_name]:-}" ]] || continue
    seen[$task_name]=1
    (( task_count += 1 ))
    (( task_count <= _APP_MAX_TASKS )) || {
      _app_error "The descriptor task inventory exceeds $_APP_MAX_TASKS records."
      return 1
    }
    record=$(_app_task_record "$backend" "$workspace" "$descriptor" \
      "$task_name" "run" "$fingerprint") || return $?
    _app_record_byte_count "$record"
    (( output_bytes += REPLY ))
    (( output_bytes <= _APP_MAX_PICKER_BYTES )) || {
      _app_error "The descriptor task records exceed their byte limit."
      return 1
    }
    print -r -- "$record"
  done < "$descriptor"
}

_app_package_script_names() {
  local descriptor="${1:-}"
  _app_require_cmd python3 "reading package.json scripts" || return 1

  command python3 -I -S -c '
import json
import re
import sys

path = sys.argv[1]
maximum_count = int(sys.argv[2])
maximum_length = int(sys.argv[3])
token = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:@/+:-]*$")

try:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(3)

if not isinstance(data, dict):
    raise SystemExit(4)
scripts = data.get("scripts", {})
if not isinstance(scripts, dict) or len(scripts) > maximum_count:
    raise SystemExit(4)

names = []
for name, body in scripts.items():
    if not isinstance(name, str) or not isinstance(body, str):
        raise SystemExit(5)
    if not 1 <= len(name) <= maximum_length or not token.fullmatch(name):
        raise SystemExit(5)
    names.append(name)

for name in names:
    print(name)
' "$descriptor" "$_APP_MAX_TASKS" "$_APP_MAX_TASK_TOKEN"
}

_app_discover_package_tasks() {
  local workspace="$1"
  local descriptor="$2"
  local fingerprint="$3"
  _app_package_manager_for_workspace "$workspace" || return 1
  local backend="$REPLY"
  local names_output=""
  local -i package_rc=0

  names_output=$(_app_package_script_names "$descriptor") || package_rc=$?
  if (( package_rc != 0 )); then
    _app_error "Could not parse the bounded package.json task inventory."
    return 1
  fi

  local task_name="" record=""
  local -i output_bytes=0
  for task_name in "${(@f)names_output}"; do
    [[ -n "$task_name" ]] || continue
    record=$(_app_task_record "$backend" "$workspace" "$descriptor" \
      "$task_name" "run" "$fingerprint") || return $?
    _app_record_byte_count "$record"
    (( output_bytes += REPLY ))
    (( output_bytes <= _APP_MAX_PICKER_BYTES )) || {
      _app_error "The package task records exceed their byte limit."
      return 1
    }
    print -r -- "$record"
  done
}

_app_discover_compose_tasks() {
  emulate -L zsh
  setopt LOCAL_OPTIONS EXTENDED_GLOB
  local workspace="$1"
  local descriptor="$2"
  local fingerprint="$3"
  local record="" line="" indentation="" service_name=""
  local -i service_indent=-1 in_services=0 task_count=0 output_bytes=0
  local -A seen_services=()

  for service_name in up down ps; do
    (( task_count += 1 ))
    record=$(_app_task_record "compose" "$workspace" "$descriptor" \
      "all" "$service_name" "$fingerprint") || return $?
    _app_record_byte_count "$record"
    (( output_bytes += REPLY ))
    (( output_bytes <= _APP_MAX_PICKER_BYTES )) || {
      _app_error "The Compose task records exceed their byte limit."
      return 1
    }
    print -r -- "$record"
  done

  while IFS= read -r line || [[ -n "$line" ]]; do
    if (( ! in_services )); then
      [[ "$line" =~ '^services:[[:space:]]*(#.*)?$' ]] \
        && in_services=1
      continue
    fi

    [[ -z "${line//[[:space:]]/}" || "$line" == [[:space:]]#\#* ]] \
      && continue
    [[ "$line" == [[:space:]]* ]] || break
    if [[ "$line" =~ '^([ ]+)([A-Za-z0-9][A-Za-z0-9_.-]*):[ ]*(#.*)?$' ]]; then
      indentation="$match[1]"
      service_name="$match[2]"
      (( service_indent < 0 )) && service_indent=${#indentation}
      (( ${#indentation} == service_indent )) || continue
      _app_validate_task_token "$service_name" || continue
      [[ -z "${seen_services[$service_name]:-}" ]] || continue
      seen_services[$service_name]=1

      local action=""
      for action in up-service restart-service logs-service; do
        (( task_count += 1 ))
        (( task_count <= _APP_MAX_TASKS )) || {
          _app_error \
            "The Compose task inventory exceeds $_APP_MAX_TASKS records."
          return 1
        }
        record=$(_app_task_record "compose" "$workspace" "$descriptor" \
          "$service_name" "$action" "$fingerprint") || return $?
        _app_record_byte_count "$record"
        (( output_bytes += REPLY ))
        (( output_bytes <= _APP_MAX_PICKER_BYTES )) || {
          _app_error "The Compose task records exceed their byte limit."
          return 1
        }
        print -r -- "$record"
      done
    fi
  done < "$descriptor"
}

_app_discover_workspace_tasks() {
  local requested_workspace="${1:-}"
  local requested_backend="${2:-}"
  [[ -z "$requested_backend" ]] \
    || _app_validate_backend "$requested_backend" || return 2
  _app_validate_workspace "$requested_workspace" || return 1
  local workspace="$REPLY"
  local descriptor="" fingerprint="" tasks_output="" record=""
  local -a records=()
  local -i record_bytes=0

  REPLY=""
  if [[ -z "$requested_backend" || "$requested_backend" == just ]]; then
    _app_descriptor_for_backend "$workspace" just
  fi
  descriptor="$REPLY"
  if [[ -n "$descriptor" ]]; then
    _app_fingerprint_descriptor "$workspace" "$descriptor" || return $?
    fingerprint="$REPLY"
    tasks_output=$(_app_discover_line_tasks just "$workspace" "$descriptor" \
      "$fingerprint") || return $?
    _app_fingerprint_descriptor "$workspace" "$descriptor" || return $?
    [[ "$REPLY" == "$fingerprint" ]] || {
      _app_error "The Just descriptor changed during discovery."
      return 1
    }
    for record in "${(@f)tasks_output}"; do
      [[ -n "$record" ]] || continue
      records+=("$record")
      _app_record_byte_count "$record"
      (( record_bytes += REPLY ))
    done
    (( ${#records[@]} <= _APP_MAX_TASKS \
      && record_bytes <= _APP_MAX_PICKER_BYTES )) || {
      _app_error "The workspace task inventory exceeds its safety limit."
      return 1
    }
  fi

  REPLY=""
  case "$requested_backend" in
    ""|npm|pnpm|yarn|bun) _app_descriptor_for_backend "$workspace" npm ;;
  esac
  descriptor="$REPLY"
  if [[ -n "$descriptor" ]]; then
    _app_fingerprint_descriptor "$workspace" "$descriptor" || return $?
    fingerprint="$REPLY"
    tasks_output=$(_app_discover_package_tasks "$workspace" "$descriptor" \
      "$fingerprint") || return $?
    _app_fingerprint_descriptor "$workspace" "$descriptor" || return $?
    [[ "$REPLY" == "$fingerprint" ]] || {
      _app_error "package.json changed during discovery."
      return 1
    }
    for record in "${(@f)tasks_output}"; do
      [[ -n "$record" ]] || continue
      records+=("$record")
      _app_record_byte_count "$record"
      (( record_bytes += REPLY ))
    done
    (( ${#records[@]} <= _APP_MAX_TASKS \
      && record_bytes <= _APP_MAX_PICKER_BYTES )) || {
      _app_error "The workspace task inventory exceeds its safety limit."
      return 1
    }
  fi

  REPLY=""
  if [[ -z "$requested_backend" || "$requested_backend" == make ]]; then
    _app_descriptor_for_backend "$workspace" make
  fi
  descriptor="$REPLY"
  if [[ -n "$descriptor" ]]; then
    _app_fingerprint_descriptor "$workspace" "$descriptor" || return $?
    fingerprint="$REPLY"
    tasks_output=$(_app_discover_line_tasks make "$workspace" "$descriptor" \
      "$fingerprint") || return $?
    _app_fingerprint_descriptor "$workspace" "$descriptor" || return $?
    [[ "$REPLY" == "$fingerprint" ]] || {
      _app_error "The Make descriptor changed during discovery."
      return 1
    }
    for record in "${(@f)tasks_output}"; do
      [[ -n "$record" ]] || continue
      records+=("$record")
      _app_record_byte_count "$record"
      (( record_bytes += REPLY ))
    done
    (( ${#records[@]} <= _APP_MAX_TASKS \
      && record_bytes <= _APP_MAX_PICKER_BYTES )) || {
      _app_error "The workspace task inventory exceeds its safety limit."
      return 1
    }
  fi

  REPLY=""
  if [[ -z "$requested_backend" || "$requested_backend" == compose ]]; then
    _app_descriptor_for_backend "$workspace" compose
  fi
  descriptor="$REPLY"
  if [[ -n "$descriptor" ]]; then
    _app_fingerprint_descriptor "$workspace" "$descriptor" || return $?
    fingerprint="$REPLY"
    tasks_output=$(_app_discover_compose_tasks "$workspace" "$descriptor" \
      "$fingerprint") || return $?
    _app_fingerprint_descriptor "$workspace" "$descriptor" || return $?
    [[ "$REPLY" == "$fingerprint" ]] || {
      _app_error "The Compose descriptor changed during discovery."
      return 1
    }
    for record in "${(@f)tasks_output}"; do
      [[ -n "$record" ]] || continue
      records+=("$record")
      _app_record_byte_count "$record"
      (( record_bytes += REPLY ))
    done
    (( ${#records[@]} <= _APP_MAX_TASKS \
      && record_bytes <= _APP_MAX_PICKER_BYTES )) || {
      _app_error "The workspace task inventory exceeds its safety limit."
      return 1
    }
  fi

  (( ${#records[@]} <= _APP_MAX_TASKS )) || {
    _app_error "The workspace task inventory exceeds $_APP_MAX_TASKS records."
    return 1
  }
  print -rl -- "${records[@]}"
}

_app_discovery_roots() {
  local current_workspace="${PWD:A}"
  _app_validate_workspace "$current_workspace" || return 1
  current_workspace="$REPLY"
  print -r -- "$current_workspace"

  command -v git &>/dev/null || return 0
  local git_root=""
  git_root=$(command git -C "$current_workspace" rev-parse \
    --show-toplevel 2>/dev/null) || return 0
  [[ -n "$git_root" && "$git_root" != *$'\n'* ]] || return 0
  git_root="${git_root:A}"
  [[ "$git_root" != "$current_workspace" ]] || return 0
  _app_validate_workspace "$git_root" || {
    _app_warn "Skipping an unsafe Git-root task workspace."
    return 0
  }
  print -r -- "$REPLY"
}

_app_discover_tasks() {
  local -a roots=()
  if (( $# == 1 )); then
    _app_validate_workspace "${1:a}" || return 1
    roots=("$REPLY")
  elif (( $# == 0 )); then
    local roots_output=""
    roots_output=$(_app_discovery_roots) || return $?
    roots=("${(@f)roots_output}")
  else
    _app_error "Task discovery accepts at most one workspace."
    return 2
  fi

  local workspace="" workspace_output="" record=""
  local -a records=()
  local -A seen=()
  local -i record_bytes=0
  for workspace in "${roots[@]}"; do
    workspace_output=$(_app_discover_workspace_tasks "$workspace") || return $?
    for record in "${(@f)workspace_output}"; do
      [[ -n "$record" && -z "${seen[$record]:-}" ]] || continue
      seen[$record]=1
      records+=("$record")
      _app_record_byte_count "$record"
      (( record_bytes += REPLY ))
      (( ${#records[@]} <= _APP_MAX_TASKS \
        && record_bytes <= _APP_MAX_PICKER_BYTES )) || {
        _app_error "The combined task inventory exceeds its safety limit."
        return 1
      }
    done
  done
  print -rl -- "${records[@]}"
}

_app_find_task_record() {
  local workspace="$1"
  local backend="$2"
  local task_name="$3"
  local action="$4"
  REPLY=""

  local records_output=""
  records_output=$(_app_discover_workspace_tasks "${workspace:a}" "$backend") \
    || return $?
  local record=""
  local -a fields=()
  local -i matches=0
  for record in "${(@f)records_output}"; do
    [[ -n "$record" ]] || continue
    fields=()
    _app_parse_task_record "$record" || return 1
    fields=("${reply[@]}")
    if [[ "${fields[1]}" == "$backend" \
      && "${fields[4]}" == "$task_name" \
      && "${fields[5]}" == "$action" ]]; then
      REPLY="$record"
      (( matches += 1 ))
    fi
  done
  (( matches == 1 )) || {
    _app_error "The requested task is absent or ambiguous in the current snapshot."
    return 1
  }
}

_app_revalidate_task_record() {
  local expected_record="${1:-}"
  local -a fields=()
  _app_parse_task_record "$expected_record" || return 1
  fields=("${reply[@]}")

  _app_fingerprint_descriptor "${fields[2]}" "${fields[3]}" || return $?
  [[ "$REPLY" == "${fields[6]}" ]] || {
    _app_error "The task descriptor changed after discovery."
    return 1
  }

  _app_find_task_record "${fields[2]}" "${fields[1]}" \
    "${fields[4]}" "${fields[5]}" || return $?
  [[ "$REPLY" == "$expected_record" ]] || {
    _app_error "The task record changed after discovery."
    return 1
  }
}

_app_backend_command_name() {
  case "${1:-}" in
    just|npm|pnpm|yarn|bun|make) REPLY="$1" ;;
    compose) REPLY="docker" ;;
    *) return 2 ;;
  esac
}

_app_build_task_command() {
  local record="${1:-}"
  local -a fields=()
  reply=()
  _app_parse_task_record "$record" || return 1
  fields=("${reply[@]}")
  local backend="${fields[1]}"
  local descriptor="${fields[3]}"
  local task_name="${fields[4]}"
  local action="${fields[5]}"

  case "$backend:$action" in
    just:run)
      reply=(just --justfile "$descriptor" "$task_name")
      ;;
    npm:run|pnpm:run|yarn:run|bun:run)
      reply=("$backend" run "$task_name")
      ;;
    make:run)
      reply=(make -f "$descriptor" "$task_name")
      ;;
    compose:up)
      reply=(docker compose -f "$descriptor" up -d)
      ;;
    compose:down)
      reply=(docker compose -f "$descriptor" down)
      ;;
    compose:ps)
      reply=(docker compose -f "$descriptor" ps)
      ;;
    compose:up-service)
      reply=(docker compose -f "$descriptor" up -d "$task_name")
      ;;
    compose:restart-service)
      reply=(docker compose -f "$descriptor" restart "$task_name")
      ;;
    compose:logs-service)
      reply=(docker compose -f "$descriptor" logs --tail 100 "$task_name")
      ;;
    *)
      return 1
      ;;
  esac
}

_app_describe_invocation() {
  local record="${1:-}"
  _app_build_task_command "$record" || return 1
  local -a command_parts=("${reply[@]}")
  local command_part=""
  local -a rendered_parts=()
  for command_part in "${command_parts[@]}"; do
    rendered_parts+=("${(q)command_part}")
  done
  REPLY="${(j: :)rendered_parts}"
}

_app_execute_task_record() {
  local record="${1:-}"
  local -a fields=()
  _app_parse_task_record "$record" || return 1
  fields=("${reply[@]}")
  local backend="${fields[1]}"
  local workspace="${fields[2]}"
  local task_name="${fields[4]}"
  _app_build_task_command "$record" || {
    _app_error "Refusing an unsupported App backend action."
    return 1
  }
  local -a task_command=("${reply[@]}")

  _app_info "Running $backend task '$task_name' in $workspace"
  (
    builtin cd -q -- "$workspace" || return 1
    command "${task_command[@]}"
  )
}

_app_execute_task_records() {
  local dry_run="${1:-no}"
  local auto_yes="${2:-no}"
  shift 2
  local -a records=("$@")
  (( ${#records[@]} >= 1 && ${#records[@]} <= _APP_MAX_TASKS )) || return 2

  _app_header "Project Task Plan"
  _app_warn "Task descriptors contain project-defined executable code."
  local record="" dependency="" invocation=""
  local -a fields=()
  for record in "${records[@]}"; do
    _app_revalidate_task_record "$record" || return $?
    fields=()
    _app_parse_task_record "$record" || return 1
    fields=("${reply[@]}")
    _app_backend_command_name "${fields[1]}" || return 1
    dependency="$REPLY"
    if [[ "$dry_run" != "yes" ]]; then
      _app_require_cmd "$dependency" "running ${fields[1]} tasks" || return 1
    fi
    _app_describe_invocation "$record" || return 1
    invocation="$REPLY"
    _app_info "${fields[2]} | $invocation"
  done

  [[ "$dry_run" == "yes" ]] && {
    _app_info "Dry run: no project task was executed."
    return 0
  }

  if [[ "$auto_yes" != "yes" ]]; then
    local -i confirm_rc=0
    _app_confirm "Run ${#records[@]} reviewed project task(s)?" \
      || confirm_rc=$?
    case "$confirm_rc" in
      0) ;;
      130)
        _app_warn "Project task execution cancelled."
        return 0
        ;;
      *)
        _app_error "Confirmation requires a terminal; use --yes explicitly."
        return 1
        ;;
    esac
  fi

  local -i passed=0 failed=0 action_rc=0 interrupt_rc=0
  for record in "${records[@]}"; do
    action_rc=0
    _app_revalidate_task_record "$record" || action_rc=$?
    if (( action_rc == 0 )); then
      _app_execute_task_record "$record" || action_rc=$?
    fi
    if (( action_rc == 0 )); then
      (( passed += 1 ))
    else
      (( failed += 1 ))
      _app_describe_invocation "$record" || return 1
      _app_error "Failed (status $action_rc): $REPLY"
      _app_parse_task_record "$record" || return 1
      fields=("${reply[@]}")
      _app_info "Workspace: ${fields[2]}"
      _app_info "Review before retry: app-run --backend ${(q)fields[1]} --task ${(q)fields[4]} --action ${(q)fields[5]} --directory ${(q)fields[2]} --dry-run"
      if (( action_rc == 130 || action_rc == 143 )); then
        interrupt_rc=$action_rc
        _app_warn "Execution interrupted; remaining project tasks were not started."
        break
      fi
    fi
  done

  _app_header "Execution Summary"
  _app_success "Tasks completed: $passed / ${#records[@]}"
  local -i ordinary_failures=$(( failed - (interrupt_rc != 0) ))
  if (( ordinary_failures > 0 )); then
    _app_error "Tasks failed: $ordinary_failures / ${#records[@]}"
  fi
  if (( interrupt_rc != 0 )); then
    _app_warn "Tasks interrupted: 1"
    _app_warn "Tasks not run: $(( ${#records[@]} - passed - failed ))"
    return $interrupt_rc
  fi
  if (( failed > 0 )); then
    return 1
  fi
}

app-list() {
  emulate -L zsh
  case "${1:-}" in
    "")
      (( $# == 0 )) || return 2
      ;;
    -h|--help)
      (( $# == 1 )) || {
        _app_error "--help accepts no additional arguments."
        return 2
      }
      _app_list_usage
      return 0
      ;;
    *)
      _app_error "Unknown app-list argument: $1"
      return 2
      ;;
  esac

  local records_output=""
  records_output=$(_app_discover_tasks) || return $?
  local record=""
  local -a fields=()
  for record in "${(@f)records_output}"; do
    fields=()
    _app_parse_task_record "$record" || return 1
    fields=("${reply[@]}")
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "${fields[1]}" "${fields[4]}" "${fields[5]}" \
      "${fields[2]}" "${fields[3]}"
  done
}

app-run() {
  emulate -L zsh
  local backend=""
  local task_name=""
  local action="run"
  local requested_workspace="${PWD:A}"
  local dry_run="no"
  local auto_yes="no"

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        (( $# == 1 )) || {
          _app_error "--help accepts no additional arguments."
          return 2
        }
        _app_run_usage
        return 0
        ;;
      --backend)
        (( $# >= 2 )) && [[ -n "$2" ]] || {
          _app_error "--backend requires a value."
          return 2
        }
        backend="$2"
        shift 2
        ;;
      --task)
        (( $# >= 2 )) && [[ -n "$2" ]] || {
          _app_error "--task requires a value."
          return 2
        }
        task_name="$2"
        shift 2
        ;;
      --action)
        (( $# >= 2 )) && [[ -n "$2" ]] || {
          _app_error "--action requires a value."
          return 2
        }
        action="$2"
        shift 2
        ;;
      --directory)
        (( $# >= 2 )) && [[ -n "$2" ]] || {
          _app_error "--directory requires a value."
          return 2
        }
        requested_workspace="${2:a}"
        shift 2
        ;;
      --dry-run)
        dry_run="yes"
        shift
        ;;
      --yes)
        auto_yes="yes"
        shift
        ;;
      --)
        shift
        (( $# == 0 )) || {
          _app_error "app-run accepts no positional operands."
          return 2
        }
        ;;
      -*)
        _app_error "Unknown app-run option: $1"
        return 2
        ;;
      *)
        _app_error "Unexpected app-run operand: $1"
        return 2
        ;;
    esac
  done

  _app_validate_backend "$backend" || {
    _app_error "A valid --backend is required."
    return 2
  }
  _app_validate_task_token "$task_name" || {
    _app_error "A valid --task is required."
    return 2
  }
  _app_validate_action "$action" || {
    _app_error "A valid --action is required."
    return 2
  }
  if [[ "$backend" == "compose" ]]; then
    [[ "$action" != "run" ]] || {
      _app_error "Compose tasks require an explicit compose --action."
      return 2
    }
    if [[ "$action" == "up" || "$action" == "down" || "$action" == "ps" ]]; then
      [[ "$task_name" == "all" ]] || {
        _app_error "Compose up, down, and ps require --task all."
        return 2
      }
    fi
  elif [[ "$action" != "run" ]]; then
    _app_error "Only the compose backend accepts a non-run action."
    return 2
  fi
  _app_validate_backend_action "$backend" "$task_name" "$action" || {
    _app_error "The backend, task, and action combination is invalid."
    return 2
  }

  _app_validate_workspace "$requested_workspace" || return 1
  requested_workspace="$REPLY"
  _app_find_task_record "$requested_workspace" "$backend" "$task_name" \
    "$action" || return $?
  local record="$REPLY"
  _app_execute_task_records "$dry_run" "$auto_yes" "$record"
}

_app_menu_label() {
  local record="${1:-}"
  local -a fields=()
  _app_parse_task_record "$record" || return 1
  fields=("${reply[@]}")
  case "${fields[5]}" in
    run) REPLY="Run ${fields[4]}" ;;
    up) REPLY="Start Compose Stack" ;;
    down) REPLY="Remove Compose Stack" ;;
    ps) REPLY="Show Compose Services" ;;
    up-service) REPLY="Start ${fields[4]}" ;;
    restart-service) REPLY="Restart ${fields[4]}" ;;
    logs-service) REPLY="Show ${fields[4]} Logs" ;;
  esac
}

_app_menu_description() {
  local record="${1:-}"
  local -a fields=()
  _app_parse_task_record "$record" || return 1
  fields=("${reply[@]}")
  local workspace_role="repository root"
  [[ "${fields[2]}" == "${PWD:A}" ]] && workspace_role="current directory"
  REPLY="${fields[1]}: ${fields[3]:t} in $workspace_role (${fields[2]:t})"
}

_app_interactive() {
  local multi="${1:-no}"
  _app_require_cmd fzf "the interactive App menu" || return 1

  local records_output=""
  records_output=$(_app_discover_tasks) || return $?
  local -a records=("${(@f)records_output}")
  (( ${#records[@]} > 0 )) || {
    _app_warn "No supported tasks were discovered in the current workspace."
    return 0
  }

  local -a rows=()
  local record="" label="" description="" row=""
  local -i task_index=0
  for record in "${records[@]}"; do
    (( task_index += 1 ))
    _app_menu_label "$record" || return 1
    label="$REPLY"
    _app_menu_description "$record" || return 1
    description="$REPLY"
    row=$(_app_task_menu_row "$label" "$description" "$task_index") \
      || return $?
    rows+=("$row")
  done

  local menu_header="Workspace: ${(V)PWD}"$'\n'\
'Type to filter | Enter review | Esc cancel | Ctrl-/ details'
  [[ "$multi" == "yes" ]] && menu_header+=$'\n'\
'Tab mark | Tasks run in selection order'

  local -a fzf_options=(
    --delimiter='[|]'
    --with-nth=1,3
    --prompt='app tasks > '
    --header="$menu_header"
    --bind='ctrl-/:toggle-preview'
    --preview='printf "Task: %s\n\n%s\n" {1} {3}'
    --preview-window='down:4:wrap'
  )
  if [[ "$multi" == "yes" ]]; then
    fzf_options+=(--multi)
  fi

  local -i fzf_rc=0
  _app_fzf_capture "${fzf_options[@]}" \
    < <(print -rl -- "${rows[@]}") || fzf_rc=$?
  local selection="$REPLY"
  if (( fzf_rc != 0 )); then
    _app_fzf_rc_is_cancel "$fzf_rc" && return 0
    _app_error "Unable to open the interactive App menu (status $fzf_rc)."
    return 1
  fi
  [[ -n "$selection" ]] || return 0

  local selected_row="" selected_index=""
  local -i selected_row_match=0
  local -a selected_rows=("${(@f)selection}")
  if [[ "$multi" != "yes" && ${#selected_rows[@]} -ne 1 ]]; then
    _app_error "The single-select App menu returned multiple task rows."
    return 1
  fi
  local -a selected_records=()
  local -A selected_indexes=()
  for selected_row in "${selected_rows[@]}"; do
    selected_row_match="${rows[(Ie)$selected_row]}"
    (( selected_row_match >= 1 \
      && selected_row_match <= ${#rows[@]} )) || {
      _app_error "The selected task was not in the App menu snapshot."
      return 1
    }
    selected_index="${selected_row##*|}"
    [[ "$selected_index" =~ '^[1-9][0-9]*$' \
      && selected_index -le ${#records[@]} ]] || {
      _app_error "The selected task index is invalid."
      return 1
    }
    [[ -z "${selected_indexes[$selected_index]:-}" ]] || continue
    selected_indexes[$selected_index]=1
    selected_records+=("${records[$selected_index]}")
  done
  (( ${#selected_records[@]} > 0 )) || return 0
  _app_timed "app:app-run" \
    _app_execute_task_records "no" "no" "${selected_records[@]}"
}

typeset -g _APP_TASKS_SOURCED=1
