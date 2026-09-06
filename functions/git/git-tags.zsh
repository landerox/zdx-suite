#!/usr/bin/env zsh
# =============================================================================
# Git Tags: planned creation, inspection, verification, push, and deletion
# =============================================================================
#
# Loaded by git-menu.zsh after git-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_GIT_TAGS_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# --- Tag, remote, and interaction primitives --------------------------------

# Accepts a short tag name or a full refs/tags/... ref and sets REPLY to the
# canonical full ref.
_git_tag_normalize_ref() {
  local input="${1:-}"
  [[ -n "$input" && "$input" != -* \
    && "$input" != *$'\n'* && "$input" != *$'\r'* \
    && "$input" != *$'\t'* ]] || {
    _git_error "Invalid tag name."
    return 2
  }

  if [[ "$input" == refs/tags/* ]]; then
    REPLY="$input"
  elif [[ "$input" == refs/* ]]; then
    _git_error "A tag must be below refs/tags/."
    return 2
  else
    REPLY="refs/tags/${input}"
  fi

  _git_validate_full_ref "$REPLY" && [[ "$REPLY" == refs/tags/* ]] || {
    _git_error "Invalid tag ref: $(_git_display_escape "$input")"
    return 2
  }
  return 0
}

_git_tag_ref_oid() {
  local ref="$1"
  REPLY=$(command git rev-parse --verify "${ref}^{object}" 2>/dev/null) \
    || return 1
  _git_validate_oid "$REPLY"
}

# Sets reply to:
#   short-name<TAB>full-ref<TAB>object-id
_git_tag_collect_local() {
  reply=()
  local output
  output=$(command git for-each-ref \
    --sort=-version:refname \
    --format='%(refname:strip=2)%09%(refname)%09%(objectname)' \
    refs/tags 2>/dev/null) || {
    _git_error "Unable to enumerate local tags."
    return 1
  }

  local record short_name remainder ref oid
  for record in "${(@f)output}"; do
    [[ -n "$record" && "$record" == *$'\t'* ]] || continue
    short_name="${record%%$'\t'*}"
    remainder="${record#*$'\t'}"
    ref="${remainder%%$'\t'*}"
    oid="${remainder##*$'\t'}"
    local REPLY=""
    _git_tag_normalize_ref "$short_name" \
      && [[ "$REPLY" == "$ref" ]] \
      && _git_validate_oid "$oid" || {
      _git_error "Git returned an invalid tag record."
      return 1
    }
    reply+=("${short_name}"$'\t'"${ref}"$'\t'"${oid}")
  done
  return 0
}

# Filters local tag records by short or full names. With no requested names,
# every local record is retained.
_git_tag_filter_local() {
  local -i record_count="$1"
  shift
  local -a records=("${@:1:$record_count}")
  shift "$record_count"
  local -a requested=("$@")

  if (( ${#requested[@]} == 0 )); then
    reply=("${records[@]}")
    return 0
  fi

  reply=()
  local input normalized record short_name full_ref matched
  local existing existing_ref
  for input in "${requested[@]}"; do
    local REPLY=""
    _git_tag_normalize_ref "$input" || return $?
    normalized="$REPLY"
    matched=""

    for record in "${records[@]}"; do
      short_name="${record%%$'\t'*}"
      full_ref="${${record#*$'\t'}%%$'\t'*}"
      if [[ "$input" == "$short_name" || "$normalized" == "$full_ref" ]]; then
        matched="$record"
        break
      fi
    done
    [[ -n "$matched" ]] || {
      _git_error "Local tag '$(_git_display_escape "$input")' does not exist."
      return 1
    }

    full_ref="${${matched#*$'\t'}%%$'\t'*}"
    local -i duplicate=0
    for existing in "${reply[@]}"; do
      existing_ref="${${existing#*$'\t'}%%$'\t'*}"
      [[ "$existing_ref" == "$full_ref" ]] && {
        duplicate=1
        break
      }
    done
    (( duplicate )) || reply+=("$matched")
  done
  return 0
}

# Sets reply to selected canonical tag records. Cancellation is a successful
# empty selection; a picker execution failure remains non-zero.
_git_tag_select_records() {
  local prompt="$1"
  local -i multi="$2"
  shift 2
  local -a records=("$@")
  reply=()

  _git_require_interactive || return 1

  local -a picker_options=(
    --delimiter=$'\t'
    --with-nth=1,3
    --preview=''
    --preview-window=hidden
    --prompt="$prompt > "
  )
  if (( multi )); then
    picker_options+=(
      --multi
      --header='Tab select | Enter accept | Esc cancel'
    )
  else
    picker_options+=(
      --header='Up/Down navigate | Enter select | Esc cancel'
    )
  fi

  local selected=""
  local -i picker_rc=0
  selected=$(printf '%s\n' "${records[@]}" \
    | _git_fzf "${picker_options[@]}") || picker_rc=$?
  if (( picker_rc != 0 )); then
    _git_fzf_rc_is_cancel "$picker_rc" && return 0
    _git_error "fzf failed while selecting tags (exit $picker_rc)."
    return $picker_rc
  fi
  [[ -n "$selected" ]] || return 0

  local -a selected_records=("${(@f)selected}")
  local selected_record candidate
  local -i matched=0
  for selected_record in "${selected_records[@]}"; do
    matched=0
    for candidate in "${records[@]}"; do
      [[ "$selected_record" == "$candidate" ]] && {
        matched=1
        break
      }
    done
    if (( ! matched )); then
      _git_error "fzf returned a tag record outside the frozen candidate set."
      return 1
    fi
    reply+=("$selected_record")
  done
  return 0
}

# Sets REPLY to one exact fixed action.
_git_tag_select_action() {
  local prompt="$1"
  shift
  local -a actions=("$@")
  REPLY=""

  _git_require_interactive || return 1
  local selected=""
  local -i picker_rc=0
  selected=$(printf '%s\n' "${actions[@]}" | _git_fzf \
    --preview='' \
    --preview-window=hidden \
    --header='Up/Down navigate | Enter select | Esc cancel' \
    --prompt="$prompt > ") || picker_rc=$?
  if (( picker_rc != 0 )); then
    _git_fzf_rc_is_cancel "$picker_rc" && return 0
    _git_error "fzf failed while selecting a tag action (exit $picker_rc)."
    return $picker_rc
  fi

  local action
  for action in "${actions[@]}"; do
    [[ "$selected" == "$action" ]] && {
      REPLY="$selected"
      return 0
    }
  done
  _git_error "fzf returned an action outside the frozen option set."
  return 1
}

# Sets REPLY to confirmed, cancelled, unavailable, or error.
_git_tag_confirm_outcome() {
  _git_confirm_outcome "$@"
}

_git_tag_authorize() {
  local -i assume_yes="$1"
  local prompt="$2"
  (( assume_yes )) && return 0

  local REPLY=""
  _git_tag_confirm_outcome "$prompt" || return 1
  case "$REPLY" in
    confirmed)
      return 0
      ;;
    cancelled)
      _git_info "Cancelled. No tag mutation was performed."
      return 3
      ;;
    unavailable)
      _git_error \
        "Interactive confirmation requires a terminal; pass --yes after reviewing the plan."
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

_git_tag_validate_remote() {
  local requested="${1:-}"
  [[ -n "$requested" && "$requested" != -* \
    && "$requested" != *$'\n'* && "$requested" != *$'\r'* \
    && "$requested" != *$'\t'* ]] || {
    _git_error "Invalid remote name."
    return 2
  }

  local output
  output=$(command git remote 2>/dev/null) || {
    _git_error "Unable to list configured remotes."
    return 1
  }
  local candidate
  for candidate in "${(@f)output}"; do
    [[ "$candidate" == "$requested" ]] && return 0
  done
  _git_error "Remote '$(_git_display_escape "$requested")' is not configured."
  return 1
}

# Sets reply to oid<TAB>full-ref records. An empty reply means no matching ref.
_git_tag_remote_snapshot() {
  local remote="$1"
  local pattern="$2"
  reply=()

  local output=""
  local -i remote_rc=0
  output=$(command git ls-remote --refs -- "$remote" "$pattern" 2>/dev/null) \
    || remote_rc=$?
  if (( remote_rc != 0 )); then
    _git_error \
      "Unable to inspect tags on '$(_git_redact_remote_url "$remote")' (exit $remote_rc)."
    return $remote_rc
  fi
  [[ -z "$output" ]] && return 0

  local record oid ref
  for record in "${(@f)output}"; do
    [[ -n "$record" && "$record" == *$'\t'* ]] || {
      _git_error "The remote returned a malformed tag record."
      return 1
    }
    oid="${record%%$'\t'*}"
    ref="${record#*$'\t'}"
    _git_validate_oid "$oid" && _git_validate_full_ref "$ref" \
      && [[ "$ref" == refs/tags/* ]] || {
      _git_error "The remote returned an invalid tag ref or object ID."
      return 1
    }
    reply+=("${oid}"$'\t'"${ref}")
  done
  return 0
}

_git_tag_find_remote_oid() {
  local wanted_ref="$1"
  shift
  local -a records=("$@")
  REPLY="absent"

  local record oid ref
  for record in "${records[@]}"; do
    oid="${record%%$'\t'*}"
    ref="${record#*$'\t'}"
    [[ "$ref" == "$wanted_ref" ]] && {
      REPLY="$oid"
      return 0
    }
  done
  return 0
}

_git_tag_revalidate_context() {
  local root="$1"
  local head_oid="$2"
  local fingerprint="$3"
  _git_require_same_context "$root" "$head_oid" "$fingerprint"
}

_git_tag_resolve_remote() {
  local requested="${1:-}"
  if [[ -n "$requested" ]]; then
    REPLY="$requested"
  else
    REPLY=$(_git_current_remote 2>/dev/null) || REPLY=""
  fi
  [[ -n "$REPLY" ]] || {
    _git_error "No current remote is configured; pass --remote NAME."
    return 1
  }
  _git_tag_validate_remote "$REPLY"
}

_git_tag_remote_url() {
  _git_remote_push_url "$1"
}

_git_tag_revalidate_remote() {
  local remote="$1"
  local expected_url="$2"
  _git_tag_validate_remote "$remote" || return 1
  _git_remote_push_url "$remote" || return 1
  [[ "$REPLY" == "$expected_url" ]] || {
    _git_error "The push URL for '$remote' changed after planning."
    return 1
  }
}

# --- Create -----------------------------------------------------------------

_git_tag_create_usage() {
  print -u2 -r -- \
    "Usage: git-tag-create [options]"
  print -u2 -r -- ""
  print -u2 -r -- "Create one exact refs/tags/... ref at a frozen commit OID."
  print -u2 -r -- ""
  print -u2 -r -- "  --name TAG          Tag name or full refs/tags/... ref."
  print -u2 -r -- "  --target REV        Commit to tag (default: HEAD)."
  print -u2 -r -- "  --message TEXT      Annotation or signature message."
  print -u2 -r -- "  --annotated         Create an annotated tag."
  print -u2 -r -- "  --signed            Create a signed tag."
  print -u2 -r -- "  --lightweight       Create a lightweight tag."
  print -u2 -r -- "  --push              Push the new tag after local creation."
  print -u2 -r -- "  --remote NAME       Remote used with --push."
  print -u2 -r -- \
    "  --dry-run           Display the plan without creating or pushing."
  print -u2 -r -- \
    "  --yes, -y           Skip confirmation; revalidation still runs."
}

# Sets dynamically scoped _git_tag_create_opt_* variables.
_git_tag_create_parse() {
  _git_tag_create_opt_name=""
  _git_tag_create_opt_target="HEAD"
  _git_tag_create_opt_message=""
  _git_tag_create_opt_type=""
  _git_tag_create_opt_remote=""
  _git_tag_create_opt_push=0
  _git_tag_create_opt_dry_run=0
  _git_tag_create_opt_yes=0
  _git_tag_create_opt_explicit=0
  local -i type_count=0

  while (( $# > 0 )); do
    _git_tag_create_opt_explicit=1
    case "$1" in
      -h|--help)
        (( $# == 1 )) || {
          _git_error "--help accepts no additional arguments."
          return 2
        }
        _git_tag_create_usage
        return 3
        ;;
      --name)
        (( $# >= 2 )) || {
          _git_error "--name requires a tag name."
          return 2
        }
        [[ -z "$_git_tag_create_opt_name" ]] || {
          _git_error "--name may be specified only once."
          return 2
        }
        _git_tag_create_opt_name="$2"
        shift
        ;;
      --target)
        (( $# >= 2 )) || {
          _git_error "--target requires a revision."
          return 2
        }
        _git_tag_create_opt_target="$2"
        shift
        ;;
      --message)
        (( $# >= 2 )) || {
          _git_error "--message requires text."
          return 2
        }
        _git_tag_create_opt_message="$2"
        shift
        ;;
      --annotated)
        _git_tag_create_opt_type="annotated"
        type_count=$(( type_count + 1 ))
        ;;
      --signed)
        _git_tag_create_opt_type="signed"
        type_count=$(( type_count + 1 ))
        ;;
      --lightweight)
        _git_tag_create_opt_type="lightweight"
        type_count=$(( type_count + 1 ))
        ;;
      --push)
        _git_tag_create_opt_push=1
        ;;
      --remote)
        (( $# >= 2 )) || {
          _git_error "--remote requires a configured remote name."
          return 2
        }
        [[ -z "$_git_tag_create_opt_remote" ]] || {
          _git_error "--remote may be specified only once."
          return 2
        }
        _git_tag_create_opt_remote="$2"
        shift
        ;;
      --dry-run)
        _git_tag_create_opt_dry_run=1
        ;;
      -y|--yes)
        _git_tag_create_opt_yes=1
        ;;
      *)
        _git_error "Unknown argument for git-tag-create: $1"
        return 2
        ;;
    esac
    shift
  done

  (( type_count <= 1 )) || {
    _git_error "Choose only one tag type."
    return 2
  }
  if (( _git_tag_create_opt_explicit )) \
    && [[ -z "$_git_tag_create_opt_name" ]]; then
    _git_error "Direct mode requires --name TAG."
    return 2
  fi
  if [[ -n "$_git_tag_create_opt_name" ]]; then
    local REPLY=""
    _git_tag_normalize_ref "$_git_tag_create_opt_name" || return 2
  fi
  [[ -n "$_git_tag_create_opt_target" \
    && "$_git_tag_create_opt_target" != -* \
    && "$_git_tag_create_opt_target" != *$'\n'* \
    && "$_git_tag_create_opt_target" != *$'\r'* ]] || {
    _git_error "Invalid tag target revision."
    return 2
  }
  if [[ -n "$_git_tag_create_opt_remote" ]] \
    && ! _git_validate_remote_token "$_git_tag_create_opt_remote"; then
    _git_error "Invalid remote name."
    return 2
  fi
  if [[ -n "$_git_tag_create_opt_remote" ]] \
    && (( ! _git_tag_create_opt_push )); then
    _git_error "--remote requires --push."
    return 2
  fi
  if (( _git_tag_create_opt_dry_run && _git_tag_create_opt_yes )); then
    _git_error "--dry-run and --yes cannot be combined."
    return 2
  fi
  return 0
}

git-tag-create() {
  emulate -L zsh

  local _git_tag_create_opt_name="" _git_tag_create_opt_target="HEAD"
  local _git_tag_create_opt_message="" _git_tag_create_opt_type=""
  local _git_tag_create_opt_remote=""
  local -i _git_tag_create_opt_push=0 _git_tag_create_opt_dry_run=0
  local -i _git_tag_create_opt_yes=0 _git_tag_create_opt_explicit=0
  local -i parse_rc=0

  _git_tag_create_parse "$@" || parse_rc=$?
  (( parse_rc == 3 )) && return 0
  (( parse_rc != 0 )) && return $parse_rc

  _git_require_repo || return 1
  _git_header "Create Tag"

  if (( ! _git_tag_create_opt_explicit )); then
    _git_require_interactive || return 1
    printf 'Tag name: ' >&2
    IFS= read -r _git_tag_create_opt_name || {
      _git_error "Unable to read a tag name."
      return 1
    }
    [[ -n "$_git_tag_create_opt_name" ]] || {
      _git_info "Cancelled. No tag name was provided."
      return 0
    }

    local REPLY=""
    _git_tag_select_action "tag type" \
      "Annotated tag" \
      "Signed tag" \
      "Lightweight tag" || return $?
    [[ -n "$REPLY" ]] || {
      _git_info "Cancelled. No tag type was selected."
      return 0
    }
    case "$REPLY" in
      "Annotated tag") _git_tag_create_opt_type="annotated" ;;
      "Signed tag") _git_tag_create_opt_type="signed" ;;
      "Lightweight tag") _git_tag_create_opt_type="lightweight" ;;
    esac

    if [[ "$_git_tag_create_opt_type" != "lightweight" ]]; then
      printf 'Tag message: ' >&2
      IFS= read -r _git_tag_create_opt_message || {
        _git_error "Unable to read a tag message."
        return 1
      }
      [[ -n "$_git_tag_create_opt_message" ]] || {
        _git_info "Cancelled. Annotated and signed tags require a message."
        return 0
      }
    fi
  else
    [[ -n "$_git_tag_create_opt_name" ]] || {
      _git_error "Direct mode requires --name TAG."
      return 2
    }
  fi

  [[ -n "$_git_tag_create_opt_type" ]] || {
    [[ -n "$_git_tag_create_opt_message" ]] \
      && _git_tag_create_opt_type="annotated" \
      || _git_tag_create_opt_type="lightweight"
  }
  if [[ "$_git_tag_create_opt_type" != "lightweight" \
    && -z "$_git_tag_create_opt_message" ]]; then
    _git_error "Annotated and signed tags require --message TEXT."
    return 2
  fi
  if [[ "$_git_tag_create_opt_type" == "lightweight" \
    && -n "$_git_tag_create_opt_message" ]]; then
    _git_error "--message cannot be combined with --lightweight."
    return 2
  fi

  local REPLY=""
  _git_tag_normalize_ref "$_git_tag_create_opt_name" || return $?
  local tag_ref="$REPLY"
  local tag_name="${tag_ref#refs/tags/}"
  if command git show-ref --verify --quiet "$tag_ref"; then
    _git_error "Tag '$(_git_display_escape "$tag_name")' already exists."
    return 1
  fi

  local target_oid
  target_oid=$(command git rev-parse --verify --end-of-options \
    "${_git_tag_create_opt_target}^{commit}" 2>/dev/null) || {
    _git_error \
      "Target '$(_git_display_escape "$_git_tag_create_opt_target")' is not a commit."
    return 1
  }
  _git_validate_oid "$target_oid" || return 1

  _git_context_refresh || return 1
  local root="${_GIT_CONTEXT[root]}"
  local head_oid="${_GIT_CONTEXT[head]}"
  local fingerprint="${_GIT_CONTEXT[fingerprint]}"

  local remote="" remote_url="" expected_remote_oid="absent"
  local -a reply=()
  if (( _git_tag_create_opt_push )); then
    _git_tag_resolve_remote "$_git_tag_create_opt_remote" || return $?
    remote="$REPLY"
    _git_tag_remote_url "$remote" || return 1
    remote_url="$REPLY"
    _git_tag_remote_snapshot "$remote_url" "$tag_ref" || return $?
    local -a remote_records=("${reply[@]}")
    _git_tag_find_remote_oid "$tag_ref" "${remote_records[@]}"
    expected_remote_oid="$REPLY"
    [[ "$expected_remote_oid" == "absent" ]] || {
      _git_error \
        "Remote tag '$(_git_display_escape "$tag_ref")' already exists at $expected_remote_oid."
      return 1
    }
  fi

  _git_label "Repository:" "$root"
  _git_label "Tag ref:" "$tag_ref"
  _git_label "Target OID:" "$target_oid"
  _git_label "Type:" "$_git_tag_create_opt_type"
  if (( _git_tag_create_opt_push )); then
    _git_label "Remote:" "$remote"
    _git_label "Push URL:" "$(_git_redact_remote_url "$remote_url")"
    _git_label "Remote state:" "$expected_remote_oid"
  fi

  if (( _git_tag_create_opt_dry_run )); then
    _git_warn "DRY-RUN — no tag was created or pushed."
    return 0
  fi

  local -i authorize_rc=0
  _git_tag_authorize "$_git_tag_create_opt_yes" \
    "Create $tag_ref at $target_oid?" || authorize_rc=$?
  (( authorize_rc == 3 )) && return 0
  (( authorize_rc != 0 )) && return $authorize_rc

  _git_tag_revalidate_context "$root" "$head_oid" "$fingerprint" \
    || return 1
  command git show-ref --verify --quiet "$tag_ref" && {
    _git_error "The tag appeared after planning; refusing to overwrite it."
    return 1
  }
  local current_target_oid
  current_target_oid=$(command git rev-parse --verify --end-of-options \
    "${_git_tag_create_opt_target}^{commit}" 2>/dev/null) \
    || current_target_oid=""
  [[ "$current_target_oid" == "$target_oid" ]] || {
    _git_error "The selected target moved after planning."
    return 1
  }
  if (( _git_tag_create_opt_push )); then
    _git_tag_revalidate_remote "$remote" "$remote_url" || return 1
    _git_tag_remote_snapshot "$remote_url" "$tag_ref" || return $?
    local -a current_remote_records=("${reply[@]}")
    _git_tag_find_remote_oid "$tag_ref" "${current_remote_records[@]}"
    [[ "$REPLY" == "absent" ]] || {
      _git_error "The remote tag appeared after planning."
      return 1
    }
  fi

  local -a create_cmd=(command git tag)
  case "$_git_tag_create_opt_type" in
    annotated)
      create_cmd+=(-a -m "$_git_tag_create_opt_message")
      ;;
    signed)
      create_cmd+=(-s -m "$_git_tag_create_opt_message")
      ;;
    lightweight)
      ;;
    *)
      _git_error "Internal tag type error."
      return 1
      ;;
  esac
  create_cmd+=(-- "$tag_name" "$target_oid")
  "${create_cmd[@]}" >&2
  local -i create_rc=$?
  if (( create_rc != 0 )); then
    _git_error "Failed to create $tag_ref (exit $create_rc)."
    return $create_rc
  fi

  _git_tag_ref_oid "$tag_ref" || {
    _git_error "The new tag could not be resolved after creation."
    return 1
  }
  local created_oid="$REPLY"
  _git_success "Created $tag_ref at object $created_oid."

  if (( ! _git_tag_create_opt_push )); then
    return 0
  fi

  _git_tag_revalidate_remote "$remote" "$remote_url" || {
    _git_error "The local tag remains available at $created_oid."
    return 1
  }
  _git_tag_remote_snapshot "$remote_url" "$tag_ref" || {
    _git_error "The local tag remains available at $created_oid."
    return 1
  }
  local -a before_push_records=("${reply[@]}")
  _git_tag_find_remote_oid "$tag_ref" "${before_push_records[@]}"
  [[ "$REPLY" == "absent" ]] || {
    _git_error \
      "The remote tag changed before push; the local tag remains at $created_oid."
    return 1
  }

  local -a push_cmd=(
    command git push
    "--force-with-lease=${tag_ref}:"
    --
    "$remote_url"
    "${created_oid}:${tag_ref}"
  )
  "${push_cmd[@]}" >&2
  local -i push_rc=$?
  if (( push_rc == 0 )); then
    _git_success "Pushed $tag_ref to '$remote'."
  else
    _git_error \
      "Push failed (exit $push_rc); the local tag remains at $created_oid."
  fi
  return $push_rc
}

# --- Browse and verify -------------------------------------------------------

_git_tag_list_usage() {
  print -u2 -r -- "Usage: git-tag-list [TAG]"
  print -u2 -r -- "       git-tag-list --help"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Browse tags interactively, or display one exact tag when TAG is provided."
  print -u2 -r -- \
    "Mutating manager actions delegate to their planned public commands."
}

_git_tag_show() {
  local ref="$1"
  local oid="$2"
  local current_oid
  current_oid=$(command git rev-parse --verify "${ref}^{object}" \
    2>/dev/null) || {
    _git_error "Tag '$(_git_display_escape "$ref")' no longer exists."
    return 1
  }
  [[ "$current_oid" == "$oid" ]] || {
    _git_error "Tag '$(_git_display_escape "$ref")' moved before display."
    return 1
  }

  command git show --show-signature --color=always "$ref" \
    | _git_page
  local -a command_rcs=("${pipestatus[@]}")
  (( command_rcs[1] == 0 )) || return ${command_rcs[1]}
  return ${command_rcs[2]}
}

_git_tag_checkout_detached() {
  local ref="$1"
  local oid="$2"
  _git_context_refresh || return 1
  local root="${_GIT_CONTEXT[root]}"
  local head_oid="${_GIT_CONTEXT[head]}"
  local fingerprint="${_GIT_CONTEXT[fingerprint]}"

  _git_label "Repository:" "$root"
  _git_label "Tag ref:" "$ref"
  _git_label "Tag object:" "$oid"
  _git_label "Effect:" "switch HEAD to a detached commit"

  local -i authorize_rc=0
  _git_tag_authorize 0 "Switch to detached HEAD at $ref?" \
    || authorize_rc=$?
  (( authorize_rc == 3 )) && return 0
  (( authorize_rc != 0 )) && return $authorize_rc

  _git_tag_revalidate_context "$root" "$head_oid" "$fingerprint" \
    || return 1
  local REPLY=""
  _git_tag_ref_oid "$ref" && [[ "$REPLY" == "$oid" ]] || {
    _git_error "The tag moved after planning."
    return 1
  }

  command git switch --detach "$oid" >&2
  local -i switch_rc=$?
  if (( switch_rc == 0 )); then
    _git_success "Switched to detached HEAD at $oid."
  else
    _git_error "Unable to switch to $oid (exit $switch_rc)."
  fi
  return $switch_rc
}

git-tag-list() {
  emulate -L zsh

  local requested=""
  case "${1:-}" in
    "")
      (( $# == 0 )) || return 2
      ;;
    -h|--help)
      (( $# == 1 )) || {
        _git_error "--help accepts no additional arguments."
        return 2
      }
      _git_tag_list_usage
      return 0
      ;;
    -*)
      _git_error "Unknown option for git-tag-list: $1"
      return 2
      ;;
    *)
      (( $# == 1 )) || {
        _git_error "git-tag-list accepts at most one tag."
        return 2
      }
      requested="$1"
      ;;
  esac

  if [[ -n "$requested" ]]; then
    local REPLY=""
    _git_tag_normalize_ref "$requested" || return 2
  fi
  _git_require_repo || return 1
  _git_header "Browse Tags"

  local -a reply=()
  local -a tags=()
  _git_tag_collect_local || return $?
  tags=("${reply[@]}")
  if (( ${#tags[@]} == 0 )); then
    _git_success "No local tags were found."
    return 0
  fi

  local record=""
  if [[ -n "$requested" ]]; then
    _git_tag_filter_local "${#tags[@]}" "${tags[@]}" "$requested" \
      || return $?
    record="${reply[1]}"
  else
    _git_tag_select_records "tags" 0 "${tags[@]}" || return $?
    (( ${#reply[@]} > 0 )) || {
      _git_info "Cancelled. No tag was selected."
      return 0
    }
    record="${reply[1]}"
  fi

  local short_name="${record%%$'\t'*}"
  local remainder="${record#*$'\t'}"
  local tag_ref="${remainder%%$'\t'*}"
  local tag_oid="${remainder##*$'\t'}"

  if [[ -n "$requested" ]]; then
    _git_tag_show "$tag_ref" "$tag_oid"
    return $?
  fi

  local REPLY=""
  _git_tag_select_action "tag action" \
    "View exact tag details" \
    "Checkout detached at tag" \
    "Verify tag signature" \
    "Push tag" \
    "Delete local tag" \
    "Delete local and remote tag" || return $?
  [[ -n "$REPLY" ]] || {
    _git_info "Cancelled. No tag action was selected."
    return 0
  }

  case "$REPLY" in
    "View exact tag details")
      _git_tag_show "$tag_ref" "$tag_oid"
      ;;
    "Checkout detached at tag")
      _git_tag_checkout_detached "$tag_ref" "$tag_oid"
      ;;
    "Verify tag signature")
      git-tag-verify "$tag_ref"
      ;;
    "Push tag")
      git-tag-push "$tag_ref"
      ;;
    "Delete local tag")
      git-tag-delete --local-only "$tag_ref"
      ;;
    "Delete local and remote tag")
      git-tag-delete --delete-remote "$tag_ref"
      ;;
  esac
}

_git_tag_verify_usage() {
  print -u2 -r -- "Usage: git-tag-verify [TAG]"
  print -u2 -r -- "       git-tag-verify --help"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Verify one annotated or signed tag; select interactively when TAG is omitted."
}

git-tag-verify() {
  emulate -L zsh

  local requested=""
  case "${1:-}" in
    "")
      (( $# == 0 )) || return 2
      ;;
    -h|--help)
      (( $# == 1 )) || {
        _git_error "--help accepts no additional arguments."
        return 2
      }
      _git_tag_verify_usage
      return 0
      ;;
    -*)
      _git_error "Unknown option for git-tag-verify: $1"
      return 2
      ;;
    *)
      (( $# == 1 )) || {
        _git_error "git-tag-verify accepts at most one tag."
        return 2
      }
      requested="$1"
      ;;
  esac

  if [[ -n "$requested" ]]; then
    local REPLY=""
    _git_tag_normalize_ref "$requested" || return 2
  fi
  _git_require_repo || return 1
  _git_header "Verify Tag Signature"

  local -a reply=()
  local -a tags=()
  _git_tag_collect_local || return $?
  tags=("${reply[@]}")
  if (( ${#tags[@]} == 0 )); then
    _git_success "No local tags were found."
    return 0
  fi

  local record=""
  if [[ -n "$requested" ]]; then
    _git_tag_filter_local "${#tags[@]}" "${tags[@]}" "$requested" \
      || return $?
    record="${reply[1]}"
  else
    _git_tag_select_records "tag to verify" 0 "${tags[@]}" || return $?
    (( ${#reply[@]} > 0 )) || {
      _git_info "Cancelled. No tag was selected."
      return 0
    }
    record="${reply[1]}"
  fi

  local remainder="${record#*$'\t'}"
  local tag_ref="${remainder%%$'\t'*}"
  local tag_oid="${remainder##*$'\t'}"
  local REPLY=""
  _git_tag_ref_oid "$tag_ref" && [[ "$REPLY" == "$tag_oid" ]] || {
    _git_error "The selected tag moved before verification."
    return 1
  }

  _git_info "Verifying $tag_ref at $tag_oid."
  command git verify-tag -- "$tag_ref" >&2
  local -i verify_rc=$?
  if (( verify_rc == 0 )); then
    _git_success "Tag signature verified successfully."
  else
    _git_error "Tag signature verification failed (exit $verify_rc)."
  fi
  return $verify_rc
}

# --- Push -------------------------------------------------------------------

_git_tag_push_usage() {
  print -u2 -r -- \
    "Usage: git-tag-push [--remote REMOTE] [--dry-run] [--yes] [TAG ...]"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Push exact local tag refs without overwriting an existing remote tag."
  print -u2 -r -- \
    "With --dry-run or --yes and no names, target every changed local tag."
  print -u2 -r -- ""
  print -u2 -r -- "  --remote NAME   Select a configured remote."
  print -u2 -r -- \
    "  --dry-run       Display the frozen plan without pushing."
  print -u2 -r -- \
    "  --yes, -y       Skip confirmation; revalidation still runs."
}

# Sets dynamically scoped _git_tag_push_opt_* variables.
_git_tag_push_parse() {
  _git_tag_push_opt_remote=""
  _git_tag_push_opt_dry_run=0
  _git_tag_push_opt_yes=0
  _git_tag_push_opt_explicit=0
  _git_tag_push_opt_targets=()

  while (( $# > 0 )); do
    _git_tag_push_opt_explicit=1
    case "$1" in
      -h|--help)
        (( $# == 1 )) || {
          _git_error "--help accepts no additional arguments."
          return 2
        }
        _git_tag_push_usage
        return 3
        ;;
      --remote)
        (( $# >= 2 )) || {
          _git_error "--remote requires a configured remote name."
          return 2
        }
        [[ -z "$_git_tag_push_opt_remote" ]] || {
          _git_error "--remote may be specified only once."
          return 2
        }
        _git_tag_push_opt_remote="$2"
        shift
        ;;
      --dry-run)
        _git_tag_push_opt_dry_run=1
        ;;
      -y|--yes)
        _git_tag_push_opt_yes=1
        ;;
      --)
        shift
        _git_tag_push_opt_targets+=("$@")
        break
        ;;
      -*)
        _git_error "Unknown option for git-tag-push: $1"
        return 2
        ;;
      *)
        _git_tag_push_opt_targets+=("$1")
        ;;
    esac
    shift
  done
  if [[ -n "$_git_tag_push_opt_remote" ]] \
    && ! _git_validate_remote_token "$_git_tag_push_opt_remote"; then
    _git_error "Invalid remote name."
    return 2
  fi
  local target REPLY=""
  for target in "${_git_tag_push_opt_targets[@]}"; do
    _git_tag_normalize_ref "$target" || return 2
  done
  if (( _git_tag_push_opt_dry_run && _git_tag_push_opt_yes )); then
    _git_error "--dry-run and --yes cannot be combined."
    return 2
  fi
  return 0
}

# Builds:
#   full-ref<TAB>local-oid<TAB>remote-oid-or-absent
_git_tag_build_push_plan() {
  local remote="$1"
  shift
  local -a local_records=("$@")
  reply=()

  local -a remote_records=()
  _git_tag_remote_snapshot "$remote" 'refs/tags/*' || return $?
  remote_records=("${reply[@]}")
  reply=()

  local record remainder ref local_oid remote_oid
  local REPLY=""
  for record in "${local_records[@]}"; do
    remainder="${record#*$'\t'}"
    ref="${remainder%%$'\t'*}"
    local_oid="${remainder##*$'\t'}"
    _git_tag_find_remote_oid "$ref" "${remote_records[@]}"
    remote_oid="$REPLY"
    [[ "$remote_oid" == "$local_oid" ]] && continue
    if [[ "$remote_oid" != "absent" ]]; then
      _git_error \
        "Refusing to overwrite remote tag $(_git_display_escape "$ref") at $remote_oid."
      return 1
    fi
    reply+=("${ref}"$'\t'"${local_oid}"$'\t'"${remote_oid}")
  done
  return 0
}

git-tag-push() {
  emulate -L zsh

  local _git_tag_push_opt_remote=""
  local -i _git_tag_push_opt_dry_run=0 _git_tag_push_opt_yes=0
  local -i _git_tag_push_opt_explicit=0 parse_rc=0
  local -a _git_tag_push_opt_targets=()

  _git_tag_push_parse "$@" || parse_rc=$?
  (( parse_rc == 3 )) && return 0
  (( parse_rc != 0 )) && return $parse_rc

  _git_require_repo || return 1
  _git_header "Push Tags"
  _git_context_refresh || return 1
  local root="${_GIT_CONTEXT[root]}"
  local head_oid="${_GIT_CONTEXT[head]}"
  local fingerprint="${_GIT_CONTEXT[fingerprint]}"

  local -a reply=()
  local -a all_tags=()
  _git_tag_collect_local || return $?
  all_tags=("${reply[@]}")
  if (( ${#all_tags[@]} == 0 )); then
    _git_success "No local tags were found."
    return 0
  fi

  local -a selected_tags=()
  if (( ${#_git_tag_push_opt_targets[@]} > 0 \
    || _git_tag_push_opt_dry_run || _git_tag_push_opt_yes )); then
    _git_tag_filter_local "${#all_tags[@]}" "${all_tags[@]}" \
      "${_git_tag_push_opt_targets[@]}" || return $?
    selected_tags=("${reply[@]}")
  else
    _git_tag_select_records "tags to push" 1 "${all_tags[@]}" || return $?
    selected_tags=("${reply[@]}")
    if (( ${#selected_tags[@]} == 0 )); then
      _git_info "Cancelled. No tags were selected."
      return 0
    fi
  fi

  local REPLY=""
  _git_tag_resolve_remote "$_git_tag_push_opt_remote" || return $?
  local remote="$REPLY"
  _git_tag_remote_url "$remote" || return 1
  local remote_url="$REPLY"

  local -a plan=()
  _git_tag_build_push_plan "$remote_url" "${selected_tags[@]}" || return $?
  plan=("${reply[@]}")
  if (( ${#plan[@]} == 0 )); then
    _git_success "Every selected tag already matches '$remote'."
    return 0
  fi

  _git_label "Repository:" "$root"
  _git_label "HEAD:" "$head_oid"
  _git_label "Remote:" "$remote"
  _git_label "Push URL:" "$(_git_redact_remote_url "$remote_url")"
  _git_label "Tag updates:" "${#plan[@]}"
  _git_blank
  local record ref remainder local_oid remote_oid
  for record in "${plan[@]}"; do
    ref="${record%%$'\t'*}"
    remainder="${record#*$'\t'}"
    local_oid="${remainder%%$'\t'*}"
    remote_oid="${remainder##*$'\t'}"
    _git_dim "$ref @ $local_oid -> $remote @ $remote_oid"
  done

  if (( _git_tag_push_opt_dry_run )); then
    _git_warn "DRY-RUN — no remote tags were changed."
    return 0
  fi

  local -i authorize_rc=0
  _git_tag_authorize "$_git_tag_push_opt_yes" \
    "Push ${#plan[@]} exact tag ref(s) to '$remote'?" \
    || authorize_rc=$?
  (( authorize_rc == 3 )) && return 0
  (( authorize_rc != 0 )) && return $authorize_rc

  _git_tag_revalidate_context "$root" "$head_oid" "$fingerprint" \
    || return 1
  _git_tag_revalidate_remote "$remote" "$remote_url" || return 1

  local -i pushed=0 failed=0
  local actual_local_oid actual_remote_oid
  local -a current_remote_records=()
  for record in "${plan[@]}"; do
    ref="${record%%$'\t'*}"
    remainder="${record#*$'\t'}"
    local_oid="${remainder%%$'\t'*}"
    remote_oid="${remainder##*$'\t'}"

    _git_tag_ref_oid "$ref" || REPLY=""
    actual_local_oid="$REPLY"
    if [[ "$actual_local_oid" != "$local_oid" ]]; then
      _git_error "Refused moved local tag: $(_git_display_escape "$ref")"
      failed=$(( failed + 1 ))
      continue
    fi

    _git_tag_revalidate_remote "$remote" "$remote_url" || {
      failed=$(( failed + 1 ))
      continue
    }
    _git_tag_remote_snapshot "$remote_url" "$ref" || {
      failed=$(( failed + 1 ))
      continue
    }
    current_remote_records=("${reply[@]}")
    _git_tag_find_remote_oid "$ref" "${current_remote_records[@]}"
    actual_remote_oid="$REPLY"
    if [[ "$actual_remote_oid" != "$remote_oid" ]]; then
      _git_error "Refused changed remote tag: $(_git_display_escape "$ref")"
      failed=$(( failed + 1 ))
      continue
    fi

    local -a push_cmd=(
      command git push "--force-with-lease=${ref}:"
      -- "$remote_url" "${local_oid}:${ref}"
    )
    "${push_cmd[@]}" >&2
    local -i push_rc=$?
    if (( push_rc == 0 )); then
      _git_success "Pushed $ref at $local_oid."
      pushed=$(( pushed + 1 ))
    else
      _git_error "Failed to push $ref (exit $push_rc)."
      failed=$(( failed + 1 ))
    fi
  done

  if (( failed > 0 )); then
    _git_error "Tag push incomplete: $pushed succeeded, $failed failed."
    return 1
  fi
  _git_success "Tag push complete: $pushed tag(s)."
  return 0
}

# --- Delete -----------------------------------------------------------------

_git_tag_delete_usage() {
  print -u2 -r -- \
    "Usage: git-tag-delete [options] [TAG ...]"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Delete exact local refs and optionally their exact remote refs."
  print -u2 -r -- \
    "With --dry-run or --yes and no names, target every local tag."
  print -u2 -r -- ""
  print -u2 -r -- "  --local-only       Delete only local tag refs (default)."
  print -u2 -r -- \
    "  --delete-remote    Delete from the current remote before local deletion."
  print -u2 -r -- \
    "  --remote NAME      Delete from this remote before local deletion."
  print -u2 -r -- \
    "  --dry-run          Display the frozen deletion plan without mutating."
  print -u2 -r -- \
    "  --yes, -y          Skip confirmation; revalidation still runs."
}

# Sets dynamically scoped _git_tag_delete_opt_* variables.
_git_tag_delete_parse() {
  _git_tag_delete_opt_remote=""
  _git_tag_delete_opt_delete_remote=0
  _git_tag_delete_opt_local_only=0
  _git_tag_delete_opt_dry_run=0
  _git_tag_delete_opt_yes=0
  _git_tag_delete_opt_explicit=0
  _git_tag_delete_opt_targets=()

  while (( $# > 0 )); do
    _git_tag_delete_opt_explicit=1
    case "$1" in
      -h|--help)
        (( $# == 1 )) || {
          _git_error "--help accepts no additional arguments."
          return 2
        }
        _git_tag_delete_usage
        return 3
        ;;
      --local-only)
        _git_tag_delete_opt_local_only=1
        ;;
      --delete-remote)
        _git_tag_delete_opt_delete_remote=1
        ;;
      --remote)
        (( $# >= 2 )) || {
          _git_error "--remote requires a configured remote name."
          return 2
        }
        [[ -z "$_git_tag_delete_opt_remote" ]] || {
          _git_error "--remote may be specified only once."
          return 2
        }
        _git_tag_delete_opt_remote="$2"
        _git_tag_delete_opt_delete_remote=1
        shift
        ;;
      --dry-run)
        _git_tag_delete_opt_dry_run=1
        ;;
      -y|--yes)
        _git_tag_delete_opt_yes=1
        ;;
      --)
        shift
        _git_tag_delete_opt_targets+=("$@")
        break
        ;;
      -*)
        _git_error "Unknown option for git-tag-delete: $1"
        return 2
        ;;
      *)
        _git_tag_delete_opt_targets+=("$1")
        ;;
    esac
    shift
  done

  if (( _git_tag_delete_opt_local_only \
    && _git_tag_delete_opt_delete_remote )); then
    _git_error "--local-only cannot be combined with remote deletion."
    return 2
  fi
  if [[ -n "$_git_tag_delete_opt_remote" ]] \
    && ! _git_validate_remote_token "$_git_tag_delete_opt_remote"; then
    _git_error "Invalid remote name."
    return 2
  fi
  local target REPLY=""
  for target in "${_git_tag_delete_opt_targets[@]}"; do
    _git_tag_normalize_ref "$target" || return 2
  done
  if (( _git_tag_delete_opt_dry_run && _git_tag_delete_opt_yes )); then
    _git_error "--dry-run and --yes cannot be combined."
    return 2
  fi
  return 0
}

# Builds:
#   full-ref<TAB>local-oid<TAB>remote-oid-or-not-requested-or-absent
_git_tag_build_delete_plan() {
  local -i delete_remote="$1"
  local remote="$2"
  shift 2
  local -a local_records=("$@")

  local -a remote_records=()
  if (( delete_remote )); then
    _git_tag_remote_snapshot "$remote" 'refs/tags/*' || return $?
    remote_records=("${reply[@]}")
  fi
  reply=()

  local record remainder ref local_oid remote_oid="not-requested"
  local REPLY=""
  for record in "${local_records[@]}"; do
    remainder="${record#*$'\t'}"
    ref="${remainder%%$'\t'*}"
    local_oid="${remainder##*$'\t'}"
    if (( delete_remote )); then
      _git_tag_find_remote_oid "$ref" "${remote_records[@]}"
      remote_oid="$REPLY"
    fi
    reply+=("${ref}"$'\t'"${local_oid}"$'\t'"${remote_oid}")
  done
  return 0
}

git-tag-delete() {
  emulate -L zsh

  local _git_tag_delete_opt_remote=""
  local -i _git_tag_delete_opt_delete_remote=0
  local -i _git_tag_delete_opt_local_only=0
  local -i _git_tag_delete_opt_dry_run=0 _git_tag_delete_opt_yes=0
  local -i _git_tag_delete_opt_explicit=0 parse_rc=0
  local -a _git_tag_delete_opt_targets=()

  _git_tag_delete_parse "$@" || parse_rc=$?
  (( parse_rc == 3 )) && return 0
  (( parse_rc != 0 )) && return $parse_rc

  _git_require_repo || return 1
  _git_header "Delete Tags"
  _git_context_refresh || return 1
  local root="${_GIT_CONTEXT[root]}"
  local head_oid="${_GIT_CONTEXT[head]}"
  local fingerprint="${_GIT_CONTEXT[fingerprint]}"

  local -a reply=()
  local -a all_tags=()
  _git_tag_collect_local || return $?
  all_tags=("${reply[@]}")
  if (( ${#all_tags[@]} == 0 )); then
    _git_success "No local tags were found."
    return 0
  fi

  local -a selected_tags=()
  if (( ${#_git_tag_delete_opt_targets[@]} > 0 \
    || _git_tag_delete_opt_dry_run || _git_tag_delete_opt_yes )); then
    _git_tag_filter_local "${#all_tags[@]}" "${all_tags[@]}" \
      "${_git_tag_delete_opt_targets[@]}" || return $?
    selected_tags=("${reply[@]}")
  else
    _git_tag_select_records "tags to delete" 1 "${all_tags[@]}" || return $?
    selected_tags=("${reply[@]}")
    if (( ${#selected_tags[@]} == 0 )); then
      _git_info "Cancelled. No tags were selected."
      return 0
    fi

    local REPLY=""
    _git_tag_select_action "deletion scope" \
      "Delete local tags only" \
      "Delete remote tags, then local tags" || return $?
    [[ -n "$REPLY" ]] || {
      _git_info "Cancelled. No deletion scope was selected."
      return 0
    }
    [[ "$REPLY" == "Delete remote tags, then local tags" ]] \
      && _git_tag_delete_opt_delete_remote=1
  fi

  local remote="" remote_url=""
  local REPLY=""
  if (( _git_tag_delete_opt_delete_remote )); then
    _git_tag_resolve_remote "$_git_tag_delete_opt_remote" || return $?
    remote="$REPLY"
    _git_tag_remote_url "$remote" || return 1
    remote_url="$REPLY"
  fi

  local -a plan=()
  _git_tag_build_delete_plan \
    "$_git_tag_delete_opt_delete_remote" "$remote_url" "${selected_tags[@]}" \
    || return $?
  plan=("${reply[@]}")

  _git_label "Repository:" "$root"
  _git_label "HEAD:" "$head_oid"
  _git_label "Local deletions:" "${#plan[@]}"
  if (( _git_tag_delete_opt_delete_remote )); then
    _git_label "Remote:" "$remote"
    _git_label "Push URL:" "$(_git_redact_remote_url "$remote_url")"
  fi
  _git_blank

  local record ref remainder local_oid remote_oid
  for record in "${plan[@]}"; do
    ref="${record%%$'\t'*}"
    remainder="${record#*$'\t'}"
    local_oid="${remainder%%$'\t'*}"
    remote_oid="${remainder##*$'\t'}"
    _git_dim "$ref | local $local_oid | remote $remote_oid"
  done

  if (( _git_tag_delete_opt_dry_run )); then
    _git_warn "DRY-RUN — no local or remote tags were deleted."
    return 0
  fi

  local -i authorize_rc=0
  _git_tag_authorize "$_git_tag_delete_opt_yes" \
    "Delete ${#plan[@]} exact tag ref(s)?" || authorize_rc=$?
  (( authorize_rc == 3 )) && return 0
  (( authorize_rc != 0 )) && return $authorize_rc

  _git_tag_revalidate_context "$root" "$head_oid" "$fingerprint" \
    || return 1
  if (( _git_tag_delete_opt_delete_remote )); then
    _git_tag_revalidate_remote "$remote" "$remote_url" || return 1
  fi

  local -i deleted=0 failed=0
  local actual_local_oid actual_remote_oid
  local -a current_remote_records=()
  for record in "${plan[@]}"; do
    ref="${record%%$'\t'*}"
    remainder="${record#*$'\t'}"
    local_oid="${remainder%%$'\t'*}"
    remote_oid="${remainder##*$'\t'}"

    _git_tag_ref_oid "$ref" || REPLY=""
    actual_local_oid="$REPLY"
    if [[ "$actual_local_oid" != "$local_oid" ]]; then
      _git_error "Refused moved or missing local tag: $(_git_display_escape "$ref")"
      failed=$(( failed + 1 ))
      continue
    fi

    if (( _git_tag_delete_opt_delete_remote )) \
      && [[ "$remote_oid" != "absent" ]]; then
      _git_tag_revalidate_remote "$remote" "$remote_url" || {
        failed=$(( failed + 1 ))
        continue
      }
      _git_tag_remote_snapshot "$remote_url" "$ref" || {
        failed=$(( failed + 1 ))
        continue
      }
      current_remote_records=("${reply[@]}")
      _git_tag_find_remote_oid "$ref" "${current_remote_records[@]}"
      actual_remote_oid="$REPLY"
      if [[ "$actual_remote_oid" != "$remote_oid" ]]; then
        _git_error \
          "Refused changed remote tag: $(_git_display_escape "$ref")"
        failed=$(( failed + 1 ))
        continue
      fi

      local -a delete_remote_cmd=(
        command git push
        "--force-with-lease=${ref}:${remote_oid}"
        --
        "$remote_url"
        ":${ref}"
      )
      "${delete_remote_cmd[@]}" >&2
      local -i remote_delete_rc=$?
      if (( remote_delete_rc != 0 )); then
        _git_error \
          "Remote deletion failed for $ref (exit $remote_delete_rc); local tag retained."
        failed=$(( failed + 1 ))
        continue
      fi
      _git_success "Deleted $ref from '$remote' at $remote_oid."
    fi

    if command git update-ref -d "$ref" "$local_oid" 2>/dev/null; then
      _git_success "Deleted local $ref at $local_oid."
      deleted=$(( deleted + 1 ))
    else
      _git_error "Failed to delete local $ref."
      failed=$(( failed + 1 ))
    fi
  done

  if (( failed > 0 )); then
    _git_error "Tag deletion incomplete: $deleted deleted, $failed failed."
    return 1
  fi
  _git_success "Tag deletion complete: $deleted local tag(s)."
  return 0
}

typeset -g _GIT_TAGS_SOURCED=1
