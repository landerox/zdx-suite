#!/usr/bin/env zsh
# =============================================================================
# AI Init: no-clobber project instruction bootstrap
# =============================================================================
#
# Loaded by ai-menu.zsh after ai-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_AI_INIT_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset -gi _AI_INIT_MINIMAL=0

_ai_init_usage() {
  print -u2 -r -- \
    "Usage: ai-init-agents [--dry-run] [--yes] [--minimal] [--verbose]"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Create AGENTS.md, the CLAUDE.md link, and .gitattributes without clobbering."
  print -u2 -r -- ""
  print -u2 -r -- "Flags:"
  print -u2 -r -- "  --dry-run       Show the exact no-clobber plan without creating files"
  print -u2 -r -- "  --yes, -y       Skip the confirmation prompt"
  print -u2 -r -- "  --minimal       Use the shortest neutral AGENTS.md template"
  print -u2 -r -- "  --verbose, -v   Show additional diagnostics"
  print -u2 -r -- "  --help, -h      Show this help"
}

_ai_init_parse() {
  _AI_DRY_RUN=0
  _AI_YES=0
  _AI_VERBOSE=0
  _AI_INIT_MINIMAL=0
  while (( $# )); do
    case "$1" in
      --dry-run) _AI_DRY_RUN=1 ;;
      --yes|-y) _AI_YES=1 ;;
      --verbose|-v) _AI_VERBOSE=1 ;;
      --minimal) _AI_INIT_MINIMAL=1 ;;
      --help|-h)
        _ai_init_usage
        return 64
        ;;
      --)
        shift
        (( $# == 0 )) || {
          _ai_error "Unexpected init operand: $1"
          return 2
        }
        break
        ;;
      -*)
        _ai_error "Unknown init option: $1"
        return 2
        ;;
      *)
        _ai_error "Unexpected init operand: $1"
        return 2
        ;;
    esac
    shift
  done
}

_ai_init_root_identity() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local root="$1"
  local -A state=()
  [[ "$root" == "${root:A}" && -d "$root" && ! -L "$root" && -O "$root" ]] \
    && zstat -LH state -- "$root" 2>/dev/null || return 1
  (( (state[mode] & 8#022) == 0 )) || return 1
  REPLY="${state[device]}:${state[inode]}:${state[mode]}:${state[uid]}"
}

_ai_init_path_state() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local target_file="$1"
  REPLY="absent"
  [[ ! -e "$target_file" && ! -L "$target_file" ]] && return 0
  [[ -f "$target_file" && ! -L "$target_file" && -O "$target_file" ]] \
    || return 1
  local -A state=()
  zstat -LH state -- "$target_file" 2>/dev/null || return 1
  (( state[nlink] == 1 && state[size] >= 0 && state[size] <= 1048576 )) \
    || return 1
  REPLY="${state[device]}:${state[inode]}:${state[mode]}:${state[uid]}:"\
"${state[nlink]}:${state[size]}:${state[mtime]}"
}

_ai_init_publish_file() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local destination="$1" content="$2"
  local parent="${destination:h}"
  [[ "$parent" == "${PWD:A}" && ! -e "$destination" && ! -L "$destination" ]] \
    || return 1
  local staging=""
  staging=$(umask 077; command mktemp "$parent/.zdx-ai-init.XXXXXX" 2>/dev/null) \
    || return 1
  local -A before=() after=()
  local -i operation_rc=1 cleanup_rc=0
  {
    [[ "$staging" == "${staging:A}" && "${staging:h}" == "$parent" \
      && "${staging:t}" == .zdx-ai-init.* \
      && -f "$staging" && ! -L "$staging" && -O "$staging" ]] \
      && zstat -LH before -- "$staging" 2>/dev/null || return 1
    (( before[uid] == EUID && before[nlink] == 1 \
      && (before[mode] & 8#170000) == 8#100000 \
      && (before[mode] & 8#077) == 0 )) || return 1
    print -r -- "$content" > "$staging" || return 1
    command chmod 644 -- "$staging" || return 1
    # A hard-link publication is atomic and fails if the destination appeared.
    command ln -- "$staging" "$destination" 2>/dev/null || return 1
    operation_rc=0
  } always {
    if [[ -f "$staging" && ! -L "$staging" ]] \
      && zstat -LH after -- "$staging" 2>/dev/null \
      && [[ "${before[device]}:${before[inode]}:${before[uid]}" \
        == "${after[device]}:${after[inode]}:${after[uid]}" ]]; then
      command rm -f -- "$staging" 2>/dev/null || cleanup_rc=1
    else
      cleanup_rc=1
    fi
    (( cleanup_rc == 0 )) || operation_rc=1
  }
  return $operation_rc
}

_ai_init_agents_template() {
  if (( _AI_INIT_MINIMAL )); then
    REPLY=$'# AGENTS.md\n\nTODO: Add project-specific instructions for coding agents.'
  else
    REPLY=$'# AGENTS.md\n\n## Project context\n\nTODO: Describe this repository and its boundaries.\n\n## Development and validation\n\nTODO: Document the project-specific commands contributors should run.\n\n## Repository-specific constraints\n\nTODO: Record conventions and safety constraints that are specific to this project.'
  fi
}

ai-init-agents() {
  emulate -L zsh
  _ai_init_parse "$@"
  local parse_rc=$?
  (( parse_rc == 64 )) && return 0
  (( parse_rc == 0 )) || return $parse_rc

  local root="${PWD:A}"
  [[ "$PWD" == "$root" && -w "$root" \
    && "$root" != *'|'* && "$root" != *[[:cntrl:]]* ]] || {
    _ai_error "The current directory must be canonical and writable."
    return 1
  }
  _ai_init_root_identity "$root" || {
    _ai_error "The current directory must be owned and not group/world writable."
    return 1
  }
  local root_identity="$REPLY"

  local agents="$root/AGENTS.md"
  if [[ -e "$agents" || -L "$agents" ]]; then
    [[ -f "$agents" && ! -L "$agents" && -O "$agents" ]] || {
      _ai_error "AGENTS.md exists but is not an owned regular file."
      return 1
    }
  fi

  local -a plan=()
  [[ -e "$agents" ]] || plan+=("file|$agents|absent")
  local link_name="" link_path="" link_target=""
  for link_name in CLAUDE.md; do
    link_path="$root/$link_name"
    if [[ -L "$link_path" ]]; then
      link_target=$(command readlink -- "$link_path" 2>/dev/null)
      [[ "$link_target" == "AGENTS.md" ]] || {
        _ai_error "$link_name already points somewhere else; refusing to replace it."
        return 1
      }
    elif [[ -e "$link_path" ]]; then
      _ai_error "$link_name already exists; refusing to overwrite or back it up."
      return 1
    else
      plan+=("link|$link_path|absent")
    fi
  done

  local attributes="$root/.gitattributes"
  local attributes_content=$'# AI instruction symlinks\nCLAUDE.md symlink=true'
  if [[ -e "$attributes" || -L "$attributes" ]]; then
    _ai_init_path_state "$attributes" || {
      _ai_error ".gitattributes exists but is not an owned regular file."
      return 1
    }
    if ! command grep -qxF 'CLAUDE.md symlink=true' "$attributes"; then
      _ai_error ".gitattributes exists without the required entries."
      _ai_info "Add the CLAUDE.md symlink=true entry manually."
      return 1
    fi
  else
    plan+=("file|$attributes|absent")
  fi

  if (( ${#plan[@]} == 0 )); then
    _ai_info "Project instruction files are already initialized."
    return 0
  fi

  _ai_header "Project Instruction Initialization Plan"
  local record="" kind="" destination=""
  for record in "${plan[@]}"; do
    kind="${record%%|*}"
    destination="${${record#*|}%%|*}"
    if [[ "$kind" == link ]]; then
      _ai_info "Create symlink: $destination -> AGENTS.md"
    else
      _ai_info "Create file without clobbering: $destination"
    fi
  done
  if (( _AI_DRY_RUN )); then
    _ai_info "Dry run: no project file was created."
    return 0
  fi
  _ai_authorize "Create these ${#plan[@]} project instruction artifact(s)?"
  local authorize_rc=$?
  (( authorize_rc == 130 )) && return 0
  (( authorize_rc == 0 )) || return $authorize_rc

  local -i failures=0 created=0
  for record in "${plan[@]}"; do
    kind="${record%%|*}"
    destination="${${record#*|}%%|*}"
    _ai_init_root_identity "$root" && [[ "$REPLY" == "$root_identity" ]] || {
      _ai_error "Project root changed after review."
      return 1
    }
    _ai_init_path_state "$destination" && [[ "$REPLY" == "absent" ]] || {
      _ai_error "Initialization target changed after review: $destination"
      (( failures += 1 ))
      continue
    }
    case "$destination:t" in
      AGENTS.md)
        _ai_init_agents_template
        _ai_init_publish_file "$destination" "$REPLY"
        ;;
      .gitattributes)
        _ai_init_publish_file "$destination" "$attributes_content"
        ;;
      CLAUDE.md)
        command ln -s -- AGENTS.md "$destination" 2>/dev/null
        ;;
      *)
        return 1
        ;;
    esac
    if (( $? == 0 )); then
      _ai_success "Created $destination"
      (( created += 1 ))
    else
      _ai_error "Could not create $destination without clobbering."
      (( failures += 1 ))
    fi
  done
  _ai_info "Initialization created $created of ${#plan[@]} artifact(s)."
  (( failures == 0 ))
}

typeset -g _AI_INIT_SOURCED=1
