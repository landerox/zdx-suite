#!/usr/bin/env zsh
# =============================================================================
# Ws Jump: change the current shell to a workspace repository
# =============================================================================
#
# Loaded by ws-menu.zsh after ws-common.zsh.
# Safe to re-source; defines functions only.
#
# ws-jump changes the directory of the shell that runs it, as venv-activate
# changes its environment, so it runs as a function in that shell. Its
# picker preview is a constant program that receives only fzf's row index and
# reads the matching path from a private snapshot file.
#

if [[ -n "${_WS_JUMP_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_ws_jump_usage() {
  print -u2 -r -- "Usage: ws-jump [QUERY]"
  print -u2 -r -- "       ws-jump --help"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Change the current shell to a repository below WS_BASE_DIR."
  print -u2 -r -- \
    "Without QUERY, pick from every repository. QUERY selects the repositories"
  print -u2 -r -- \
    "named exactly QUERY or, when none is, those whose relative path contains"
  print -u2 -r -- \
    "it, ignoring case. One match changes directory at once; several open the"
  print -u2 -r -- "picker with only those repositories."
  print -u2 -r -- ""
  print -u2 -r -- \
    "Settings: WS_BASE_DIR, WS_MAX_DEPTH (1-10, default 3), and WS_EXCLUDE."
}

# reply: the repositories that QUERY selects: those whose final component
# equals it exactly, or else those whose relative path contains it with any
# letter case. Usage: _ws_jump_matches <query> <relative-path...>
_ws_jump_matches() {
  emulate -L zsh
  local query="$1" relative=""
  shift
  local -a exact=() partial=()
  local folded="${query:l}"
  for relative in "$@"; do
    [[ "${relative:t}" == "$query" ]] && exact+=("$relative")
    [[ "${relative:l}" == *"$folded"* ]] && partial+=("$relative")
  done
  if (( ${#exact[@]} > 0 )); then
    reply=("${exact[@]}")
  else
    reply=("${partial[@]}")
  fi
}

# REPLY: the relative path chosen in the picker. Status 130 is a cancellation.
# Usage: _ws_jump_pick <canonical-root> <root-display> <relative-path...>
_ws_jump_pick() {
  emulate -L zsh
  local root="$1" root_display="$2"
  shift 2
  local -a candidates=("$@")
  REPLY=""
  _ws_require_cmd fzf "the repository picker" || return 1

  local -a reply=()
  _ws_private_dir_create jump || return 1
  local snapshot_dir="${reply[1]}" snapshot_identity="${reply[2]}"
  local snapshot_file="$snapshot_dir/paths"
  local selected="" relative=""
  local -a rows=() absolute_paths=()
  local -i index=0 fzf_rc=0 operation_rc=0
  for relative in "${candidates[@]}"; do
    (( ++index ))
    rows+=("${relative}|${index}")
    absolute_paths+=("$root/$relative")
  done

  # The preview program is constant: fzf supplies only the row index {n},
  # and the snapshot path is a validated private file quoted for /bin/sh.
  local preview="s=${(qq)snapshot_file}"$'\n'
  preview+='n={n}
case "$n" in ""|*[!0-9]*) exit 0 ;; esac
d=$(sed -n "$((n + 1))p" "$s" 2>/dev/null)
if [ -z "$d" ] || [ ! -d "$d" ]; then printf "%s\n" "Repository unavailable."; exit 0; fi
if ! command -v git >/dev/null 2>&1; then printf "%s\n" "Git is not installed."; exit 0; fi
b=$(git -C "$d" symbolic-ref --quiet --short HEAD 2>/dev/null) || b="detached at $(git -C "$d" rev-parse --short HEAD 2>/dev/null)"
c=$(git --no-optional-locks -C "$d" status --porcelain 2>/dev/null | wc -l | tr -d " ")
[ "$c" = 0 ] && c=clean
l=$(git -C "$d" -c log.showSignature=false log -1 --format="%cr: %s" 2>/dev/null | LC_ALL=C tr -d "\000-\037\177")
printf "Branch:      %s\nChanges:     %s\nLast commit: %s\n" "$b" "${c:-unknown}" "${l:-none}"'

  {
    if ! (umask 077; print -rl -- "${absolute_paths[@]}" >| "$snapshot_file") \
      2>/dev/null; then
      _ws_error "Could not write the private repository snapshot."
      operation_rc=1
    else
      _ws_fzf_capture \
        --height='80%' \
        --delimiter='[|]' \
        --with-nth=1 \
        --prompt='ws jump > ' \
        --header="Workspace: ${(V)root_display}"$'\n''Type to filter | Enter jump | Esc cancel | Ctrl-/ details' \
        --bind='ctrl-/:toggle-preview' \
        --preview="$preview" \
        --preview-window='right:40%:wrap,<120(down:4:wrap)' \
        < <(print -rl -- "${rows[@]}") || fzf_rc=$?
      selected="$REPLY"
      REPLY=""
      if (( fzf_rc != 0 )); then
        if _ws_fzf_rc_is_cancel "$fzf_rc"; then
          operation_rc=130
        else
          _ws_error "The repository picker failed (status $fzf_rc)."
          operation_rc=1
        fi
      elif [[ -z "$selected" ]]; then
        operation_rc=130
      elif [[ "$selected" == *$'\n'* ]] \
        || ! _ws_array_contains_literal "$selected" "${rows[@]}"; then
        _ws_error "The selected repository was not in the picker snapshot."
        operation_rc=1
      fi
    fi
  } always {
    _ws_private_dir_remove "$snapshot_dir" "$snapshot_identity" \
      || (( operation_rc != 0 )) || operation_rc=1
  }
  (( operation_rc == 0 )) || return $operation_rc

  index="${selected##*|}"
  [[ "$index" == <-> ]] && (( index >= 1 && index <= ${#candidates[@]} )) || {
    _ws_error "The selected repository index is invalid."
    return 1
  }
  REPLY="${candidates[index]}"
}

ws-jump() {
  emulate -L zsh

  local query=""
  local -i have_query=0
  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        (( $# == 1 && ! have_query )) || {
          _ws_error "--help accepts no additional arguments."
          return 2
        }
        _ws_jump_usage
        return 0
        ;;
      --)
        shift
        (( $# <= 1 && ! (have_query && $# == 1) )) || {
          _ws_error "ws-jump accepts at most one QUERY."
          return 2
        }
        if (( $# == 1 )); then
          query="$1"
          have_query=1
        fi
        break
        ;;
      -*)
        _ws_error "Unknown ws-jump option: $1"
        return 2
        ;;
      *)
        (( ! have_query )) || {
          _ws_error "ws-jump accepts at most one QUERY."
          return 2
        }
        query="$1"
        have_query=1
        ;;
    esac
    shift
  done
  if (( have_query )); then
    [[ -n "$query" && "$query" != *[[:cntrl:]]* && ${#query} -le 256 ]] || {
      _ws_error "QUERY must be non-empty text of at most 256 characters."
      return 2
    }
  fi

  (( ${ZSH_SUBSHELL:-0} == 0 )) || _ws_warn \
    "ws-jump is running in a subshell; the directory change will not reach your shell."

  local REPLY=""
  local -a reply=()
  _ws_workspace_root || return 1
  local root_literal="${reply[1]}" root="${reply[2]}"
  _ws_command_display "$root_literal"
  local root_display="$REPLY"
  _ws_collect_repositories "$root" || return 1
  local -a repositories=("${reply[@]}")
  local -i skipped=$REPLY
  if (( skipped > 0 )); then
    _ws_count_noun "$skipped" directory directories
    _ws_warn "Skipped $REPLY whose names cannot be shown safely."
  fi
  (( ${#repositories[@]} > 0 )) || {
    _ws_warn "No repositories were found below $root_display."
    return 1
  }

  local -a candidates=("${repositories[@]}")
  if (( have_query )); then
    _ws_jump_matches "$query" "${repositories[@]}"
    candidates=("${reply[@]}")
    (( ${#candidates[@]} > 0 )) || {
      _ws_error "No repository below $root_display matches '$query'."
      return 1
    }
  fi

  local relative=""
  if (( have_query && ${#candidates[@]} == 1 )); then
    relative="${candidates[1]}"
  else
    local -i pick_rc=0
    _ws_jump_pick "$root" "$root_display" "${candidates[@]}" || pick_rc=$?
    (( pick_rc == 130 )) && return 0
    (( pick_rc == 0 )) || return $pick_rc
    relative="$REPLY"
  fi

  # The tree may have changed while the picker was open: the target must
  # still be the same real repository directory below the root.
  local target="$root_literal/$relative"
  _ws_command_display "$target"
  local target_display="$REPLY"
  if [[ ! -d "$target" || -L "$target" \
    || "${target:A}" != "$root/$relative" ]] \
    || [[ ! -e "$target/.git" && ! -L "$target/.git" ]]; then
    _ws_error "The repository changed or no longer exists: $target_display"
    return 1
  fi
  builtin cd -- "$target" || {
    _ws_error "Could not change to $target_display"
    return 1
  }
  _ws_success "Now in $target_display"
}

typeset -g _WS_JUMP_SOURCED=1
