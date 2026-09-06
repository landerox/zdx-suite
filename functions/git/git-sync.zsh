#!/usr/bin/env zsh
# =============================================================================
# Git Sync: explicit, planned fetch, pull, and push transactions
# =============================================================================
#
# Loaded by git-menu.zsh after git-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_GIT_SYNC_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# --- Shared remote and interaction helpers ----------------------------------

_git_sync_validate_remote() {
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

# Sets REPLY to one fixed option. A picker cancellation is a successful empty
# selection; any other picker failure is preserved.
_git_sync_select_fixed() {
  local prompt="$1"
  shift
  local -a options=("$@")
  REPLY=""

  _git_require_interactive || return 1

  local selected=""
  local -i picker_rc=0
  selected=$(printf '%s\n' "${options[@]}" | _git_fzf \
    --preview='' \
    --preview-window=hidden \
    --header='Up/Down navigate | Enter select | Esc cancel' \
    --prompt="$prompt > ") || picker_rc=$?

  if (( picker_rc != 0 )); then
    _git_fzf_rc_is_cancel "$picker_rc" && return 0
    _git_error "fzf failed while selecting a sync action (exit $picker_rc)."
    return $picker_rc
  fi

  local option
  for option in "${options[@]}"; do
    if [[ "$selected" == "$option" ]]; then
      REPLY="$selected"
      return 0
    fi
  done
  _git_error "fzf returned an action outside the frozen option set."
  return 1
}

# Sets REPLY to confirmed, cancelled, unavailable, or error.
_git_sync_confirm_outcome() {
  _git_confirm_outcome "$@"
}

_git_sync_authorize() {
  local -i assume_yes="$1"
  local prompt="$2"
  (( assume_yes )) && return 0

  local REPLY=""
  _git_sync_confirm_outcome "$prompt" || return 1
  case "$REPLY" in
    confirmed)
      return 0
      ;;
    cancelled)
      _git_info "Cancelled. No sync mutation was performed."
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

# Sets reply to validated full-ref records returned by the remote:
#   object-id<TAB>full-ref
# An empty successful reply means the exact pattern is absent.
_git_sync_remote_snapshot() {
  local remote="$1"
  local pattern="$2"
  reply=()

  local output=""
  local -i remote_rc=0
  output=$(command git ls-remote --refs -- "$remote" "$pattern" 2>/dev/null) \
    || remote_rc=$?
  if (( remote_rc != 0 )); then
    _git_error \
      "Unable to inspect remote '$(_git_redact_remote_url "$remote")' (exit $remote_rc)."
    return $remote_rc
  fi
  [[ -z "$output" ]] && return 0

  local line oid ref
  for line in "${(@f)output}"; do
    [[ -n "$line" && "$line" == *$'\t'* ]] || {
      _git_error "The remote returned a malformed ref record."
      return 1
    }
    oid="${line%%$'\t'*}"
    ref="${line#*$'\t'}"
    _git_validate_oid "$oid" && _git_validate_full_ref "$ref" || {
      _git_error "The remote returned an invalid ref or object ID."
      return 1
    }
    reply+=("${oid}"$'\t'"${ref}")
  done
  return 0
}

# Finds an exact full ref in oid<TAB>ref records and sets REPLY to its OID or
# the literal `absent`.
_git_sync_find_remote_oid() {
  local wanted_ref="$1"
  shift
  local -a records=("$@")
  REPLY="absent"

  local record oid ref
  for record in "${records[@]}"; do
    oid="${record%%$'\t'*}"
    ref="${record#*$'\t'}"
    if [[ "$ref" == "$wanted_ref" ]]; then
      REPLY="$oid"
      return 0
    fi
  done
  return 0
}

# Sets reply to local full-ref records:
#   object-id<TAB>full-ref
_git_sync_local_snapshot() {
  local pattern="$1"
  reply=()

  local output
  output=$(command git for-each-ref \
    --format='%(objectname)%09%(refname)' "$pattern" 2>/dev/null) || {
    _git_error "Unable to inspect local refs matching '$pattern'."
    return 1
  }

  local line oid ref
  for line in "${(@f)output}"; do
    [[ -n "$line" && "$line" == *$'\t'* ]] || continue
    oid="${line%%$'\t'*}"
    ref="${line#*$'\t'}"
    _git_validate_oid "$oid" && _git_validate_full_ref "$ref" || {
      _git_error "Git returned an invalid local ref record."
      return 1
    }
    reply+=("${oid}"$'\t'"${ref}")
  done
  return 0
}

_git_sync_ref_oid() {
  local ref="$1"
  REPLY=$(command git rev-parse --verify "${ref}^{object}" 2>/dev/null) \
    || return 1
  _git_validate_oid "$REPLY"
}

# Sets REPLY to the direct OID stored in an exact ref, or to `absent`.
# Symbolic refs are rejected so a later --no-deref compare-and-swap cannot
# silently replace an alias with a direct ref.
_git_sync_direct_ref_oid() {
  local wanted_ref="$1"
  _git_validate_full_ref "$wanted_ref" || {
    _git_error "Invalid local reference."
    return 2
  }
  REPLY="absent"

  local output=""
  output=$(command git for-each-ref \
    --format='%(objectname)%09%(refname)%09%(symref)' \
    "$wanted_ref" 2>/dev/null) || {
    _git_error \
      "Unable to inspect local ref '$(_git_display_escape "$wanted_ref")'."
    return 1
  }

  local line oid remainder ref symbolic_target
  for line in "${(@f)output}"; do
    [[ -n "$line" && "$line" == *$'\t'*$'\t'* ]] || continue
    oid="${line%%$'\t'*}"
    remainder="${line#*$'\t'}"
    ref="${remainder%%$'\t'*}"
    symbolic_target="${remainder#*$'\t'}"
    [[ "$ref" == "$wanted_ref" ]] || continue
    [[ -z "$symbolic_target" ]] || {
      _git_error \
        "Ref '$(_git_display_escape "$wanted_ref")' is symbolic; refusing to replace it."
      return 1
    }
    _git_validate_oid "$oid" || {
      _git_error "Git returned an invalid local ref object ID."
      return 1
    }
    REPLY="$oid"
    return 0
  done
  return 0
}

# Allocates an unused ref prefix owned by this invocation. No ref is created
# until the authorized fetch begins.
_git_sync_allocate_temp_prefix() {
  REPLY=""

  local -i attempt=0
  local candidate occupied
  while (( attempt < 32 )); do
    attempt=$(( attempt + 1 ))
    candidate="refs/zdx-suite/fetch/${$}-${RANDOM}-${RANDOM}"
    _git_validate_full_ref "$candidate" || continue
    occupied=$(command git for-each-ref \
      --count=1 --format='%(refname)' "$candidate" 2>/dev/null) || {
      _git_error "Unable to inspect the temporary fetch namespace."
      return 1
    }
    if [[ -z "$occupied" ]]; then
      REPLY="$candidate"
      return 0
    fi
  done

  _git_error "Unable to allocate an unused temporary fetch namespace."
  return 1
}

# Fetches only the caller's explicit temporary refspec. Every configurable
# ref-writing side channel is disabled so canonical tracking refs, tags,
# FETCH_HEAD, submodules, and maintenance state stay outside this operation.
_git_sync_fetch_temp() {
  local remote="$1"
  local refspec="$2"
  local -a fetch_cmd=(
    command git fetch
    --atomic
    --no-auto-maintenance
    --no-prune
    --no-prune-tags
    --no-recurse-submodules
    --no-tags
    --no-write-commit-graph
    --no-write-fetch-head
    --refmap=
    --
    "$remote"
    "$refspec"
  )
  "${fetch_cmd[@]}" >&2
}

# Sets reply to exact oid<TAB>ref records beneath an owned temporary prefix.
_git_sync_temp_snapshot() {
  local temp_prefix="$1"
  _git_validate_full_ref "$temp_prefix" || {
    _git_error "Invalid temporary fetch namespace."
    return 1
  }

  _git_sync_local_snapshot "$temp_prefix" || return 1
  local -a records=("${reply[@]}")
  reply=()

  local record oid ref
  for record in "${records[@]}"; do
    oid="${record%%$'\t'*}"
    ref="${record#*$'\t'}"
    [[ "$ref" == "${temp_prefix}/"* ]] || {
      _git_error "A ref escaped the temporary fetch namespace."
      return 1
    }
    reply+=("${oid}"$'\t'"${ref}")
  done
  reply=("${(@o)reply}")
  return 0
}

# Verifies that every fetched branch target is a direct commit object.
_git_sync_validate_temp_commits() {
  local -a records=("$@")
  local record oid ref object_type
  for record in "${records[@]}"; do
    oid="${record%%$'\t'*}"
    ref="${record#*$'\t'}"
    _git_validate_oid "$oid" && _git_validate_full_ref "$ref" || {
      _git_error "Refusing an invalid fetched branch record."
      return 1
    }
    object_type=$(command git --no-replace-objects \
      cat-file -t "$oid" 2>/dev/null) || {
      _git_error \
        "Fetched ref '$(_git_display_escape "$ref")' is not a commit."
      return 1
    }
    [[ "$object_type" == "commit" ]] || {
      _git_error \
        "Fetched ref '$(_git_display_escape "$ref")' is not a direct commit."
      return 1
    }
  done
  return 0
}

# Deletes only exact temporary refs whose OIDs still match the fetch result.
# A concurrent change makes the whole cleanup transaction fail closed.
_git_sync_cleanup_temp_refs() {
  local temp_prefix="$1"
  shift
  local -a records=("$@")
  (( ${#records[@]} > 0 )) || return 0

  local -a transaction=(start "option no-deref")
  local record oid ref
  for record in "${records[@]}"; do
    oid="${record%%$'\t'*}"
    ref="${record#*$'\t'}"
    _git_validate_oid "$oid" \
      && _git_validate_full_ref "$ref" \
      && [[ "$ref" == "${temp_prefix}/"* ]] || {
      _git_error "Refusing an invalid temporary-ref cleanup plan."
      return 1
    }
    transaction+=("delete ${ref} ${oid}")
  done
  transaction+=(prepare commit)

  printf '%s\n' "${transaction[@]}" \
    | command git update-ref \
      -m "zdx-suite temporary fetch cleanup" --stdin >/dev/null
  local -i cleanup_rc=$?
  if (( cleanup_rc != 0 )); then
    _git_error \
      "Unable to remove every temporary fetch ref (exit $cleanup_rc)."
    return 1
  fi
  return 0
}

# Promotes one fetched OID to a canonical tracking ref with an exact old-value
# lease. The all-zero OID means the ref must still be absent.
_git_sync_promote_tracking_ref() {
  local tracking_ref="$1"
  local new_oid="$2"
  local old_oid="$3"

  _git_validate_full_ref "$tracking_ref" \
    && _git_validate_oid "$new_oid" \
    && {
      [[ "$old_oid" == "absent" ]] || _git_validate_oid "$old_oid"
    } || {
    _git_error "Refusing an invalid tracking-ref promotion plan."
    return 1
  }

  local expected_old="$old_oid"
  [[ "$expected_old" != "absent" ]] \
    || expected_old="${new_oid//?/0}"

  command git update-ref --no-deref \
    -m "zdx-suite git-pull" \
    "$tracking_ref" "$new_oid" "$expected_old" >/dev/null
  local -i update_rc=$?
  if (( update_rc != 0 )); then
    _git_error \
      "The tracking ref changed during fetch; no planned ref was promoted."
    return 1
  fi
  return 0
}

# Resolves the current branch, its exact local ref, the configured destination
# ref, and a concrete remote. Caller-supplied remote/ref overrides are honored.
_git_sync_resolve_branch_target() {
  local requested_remote="$1"
  local requested_ref="$2"
  local direction="${3:-fetch}"

  _git_sync_branch=$(command git symbolic-ref --quiet --short HEAD \
    2>/dev/null) || {
    _git_error "A named current branch is required; detached HEAD is unsupported."
    return 1
  }
  _git_validate_branch_name "$_git_sync_branch" || {
    _git_error "The current branch name is invalid."
    return 1
  }
  _git_sync_local_ref="refs/heads/${_git_sync_branch}"
  _git_validate_full_ref "$_git_sync_local_ref" || return 1
  _git_sync_ref_oid "$_git_sync_local_ref" || {
    _git_error "Unable to resolve the current branch object ID."
    return 1
  }
  _git_sync_local_oid="$REPLY"

  local configured_remote=""
  configured_remote=$(command git config --get \
    "branch.${_git_sync_branch}.remote" 2>/dev/null) || configured_remote=""
  if [[ -n "$requested_remote" ]]; then
    _git_sync_remote="$requested_remote"
  elif [[ "$direction" == "push" ]]; then
    _git_sync_remote=$(_git_current_remote 2>/dev/null) \
      || _git_sync_remote=""
  elif [[ -n "$configured_remote" && "$configured_remote" != "." ]]; then
    _git_sync_remote="$configured_remote"
  else
    _git_sync_remote=$(_git_current_remote 2>/dev/null) \
      || _git_sync_remote=""
  fi
  [[ -n "$_git_sync_remote" ]] || {
    _git_error "No current remote is configured; pass --remote NAME."
    return 1
  }
  _git_sync_validate_remote "$_git_sync_remote" || return $?

  if [[ -n "$requested_ref" ]]; then
    _git_sync_remote_ref="$requested_ref"
  elif [[ "$direction" == "push" ]]; then
    _git_sync_remote_ref="refs/heads/${_git_sync_branch}"
  elif [[ -z "$requested_remote" || "$requested_remote" == "$configured_remote" ]]; then
    _git_sync_remote_ref=$(command git config --get \
      "branch.${_git_sync_branch}.merge" 2>/dev/null) \
      || _git_sync_remote_ref=""
    [[ -n "$_git_sync_remote_ref" ]] \
      || _git_sync_remote_ref="refs/heads/${_git_sync_branch}"
  else
    _git_sync_remote_ref="refs/heads/${_git_sync_branch}"
  fi

  _git_validate_full_ref "$_git_sync_remote_ref" \
    && [[ "$_git_sync_remote_ref" == refs/heads/* ]] || {
    _git_error "The destination must be a full refs/heads/... reference."
    return 2
  }

  _git_sync_tracking_ref="refs/remotes/${_git_sync_remote}/${_git_sync_remote_ref#refs/heads/}"
  _git_validate_full_ref "$_git_sync_tracking_ref" || {
    _git_error "The derived remote-tracking reference is invalid."
    return 1
  }

  _git_sync_push_url=""
  if [[ "$direction" == "push" ]]; then
    _git_remote_push_url "$_git_sync_remote" || return 1
    _git_sync_push_url="$REPLY"
  fi
  _git_sync_fetch_url=$(command git remote get-url \
    "$_git_sync_remote" 2>/dev/null) || {
    _git_error "Unable to resolve the fetch URL for '$_git_sync_remote'."
    return 1
  }
  return 0
}

_git_sync_revalidate_context() {
  local root="$1"
  local head_oid="$2"
  local fingerprint="$3"
  local local_ref="$4"
  local local_oid="$5"
  local remote="$6"
  local expected_url="$7"
  local url_kind="$8"

  _git_require_same_context "$root" "$head_oid" "$fingerprint" || return 1

  local current_ref=""
  current_ref=$(command git symbolic-ref --quiet HEAD 2>/dev/null) \
    || current_ref=""
  [[ "$current_ref" == "$local_ref" ]] || {
    _git_error "The current branch changed after planning."
    return 1
  }

  local REPLY=""
  _git_sync_ref_oid "$local_ref" && [[ "$REPLY" == "$local_oid" ]] || {
    _git_error "The current branch moved after planning."
    return 1
  }

  _git_sync_validate_remote "$remote" || return 1
  local current_url
  if [[ "$url_kind" == "push" ]]; then
    local push_urls_output
    push_urls_output=$(command git remote get-url --push --all \
      "$remote" 2>/dev/null) || push_urls_output=""
    local -a push_urls=()
    [[ -n "$push_urls_output" ]] \
      && push_urls=("${(@f)push_urls_output}")
    (( ${#push_urls[@]} == 1 )) || {
      _git_error "Remote '$remote' no longer has one exact push URL."
      return 1
    }
    current_url="${push_urls[1]}"
  else
    current_url=$(command git remote get-url "$remote" 2>/dev/null) \
      || return 1
  fi
  [[ "$current_url" == "$expected_url" ]] || {
    _git_error "The $url_kind URL for '$remote' changed after planning."
    return 1
  }
  return 0
}

# --- Push -------------------------------------------------------------------

_git_push_usage() {
  print -u2 -r -- \
    "Usage: git-push [options]"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Push explicit full refs to a validated remote after showing a frozen plan."
  print -u2 -r -- ""
  print -u2 -r -- "  --remote NAME       Select a configured remote."
  print -u2 -r -- \
    "  --ref FULL_REF      Destination refs/heads/... ref for the current branch."
  print -u2 -r -- \
    "  --set-upstream      Record the explicit destination as the branch upstream."
  print -u2 -r -- \
    "  --force-with-lease  Rewrite one remote branch with an exact OID lease."
  print -u2 -r -- "  --tags              Push every changed local tag."
  print -u2 -r -- "  --all               Push every local branch."
  print -u2 -r -- \
    "  --dry-run           Display the exact push plan without writing the remote."
  print -u2 -r -- \
    "  --yes, -y           Skip confirmation; revalidation still runs."
  print -u2 -r -- ""
  print -u2 -r -- \
    "Raw --force is intentionally unsupported."
  print -u2 -r -- \
    "Normal branch updates must be provable fast-forwards from locally available remote tips."
  print -u2 -r -- \
    "Every ref is pushed from its frozen OID with an exact remote OID-or-absence lease."
}

# Sets dynamically scoped _git_push_opt_* variables.
_git_push_parse_options() {
  _git_push_opt_remote=""
  _git_push_opt_ref=""
  _git_push_opt_mode="current"
  _git_push_opt_dry_run=0
  _git_push_opt_yes=0
  _git_push_opt_explicit=0
  local -i argument_count=$#
  local -i mode_count=0

  while (( $# > 0 )); do
    _git_push_opt_explicit=1
    case "$1" in
      -h|--help)
        (( argument_count == 1 )) || {
          _git_error "--help accepts no additional arguments."
          return 2
        }
        _git_push_usage
        return 3
        ;;
      --remote)
        (( $# >= 2 )) || {
          _git_error "--remote requires a configured remote name."
          return 2
        }
        [[ -n "$2" ]] || {
          _git_error "--remote requires a non-empty remote name."
          return 2
        }
        [[ -z "$_git_push_opt_remote" ]] || {
          _git_error "--remote may be specified only once."
          return 2
        }
        _git_push_opt_remote="$2"
        shift
        ;;
      --ref)
        (( $# >= 2 )) || {
          _git_error "--ref requires a full refs/heads/... reference."
          return 2
        }
        [[ -n "$2" ]] || {
          _git_error "--ref requires a non-empty full reference."
          return 2
        }
        [[ -z "$_git_push_opt_ref" ]] || {
          _git_error "--ref may be specified only once."
          return 2
        }
        _git_push_opt_ref="$2"
        shift
        ;;
      --set-upstream)
        _git_push_opt_mode="set-upstream"
        mode_count=$(( mode_count + 1 ))
        ;;
      --force-with-lease)
        _git_push_opt_mode="force"
        mode_count=$(( mode_count + 1 ))
        ;;
      --tags)
        _git_push_opt_mode="tags"
        mode_count=$(( mode_count + 1 ))
        ;;
      --all)
        _git_push_opt_mode="all"
        mode_count=$(( mode_count + 1 ))
        ;;
      --dry-run)
        _git_push_opt_dry_run=1
        ;;
      -y|--yes)
        _git_push_opt_yes=1
        ;;
      --force)
        _git_error \
          "Raw --force is unsupported; use --force-with-lease."
        return 2
        ;;
      *)
        _git_error "Unknown argument for git-push: $1"
        return 2
        ;;
    esac
    shift
  done

  (( mode_count <= 1 )) || {
    _git_error \
      "Choose only one of --set-upstream, --force-with-lease, --tags, or --all."
    return 2
  }
  if [[ -n "$_git_push_opt_remote" ]] \
    && ! _git_validate_remote_token "$_git_push_opt_remote"; then
    _git_error "Invalid remote name."
    return 2
  fi
  if [[ -n "$_git_push_opt_ref" ]] \
    && {
      ! _git_validate_full_ref "$_git_push_opt_ref" \
        || [[ "$_git_push_opt_ref" != refs/heads/* ]]
    }; then
    _git_error "--ref must be a full refs/heads/... reference."
    return 2
  fi
  if [[ "$_git_push_opt_mode" == (tags|all) \
    && -n "$_git_push_opt_ref" ]]; then
    _git_error "--ref cannot be combined with a broad push mode."
    return 2
  fi
  if (( _git_push_opt_dry_run && _git_push_opt_yes )); then
    _git_error "--dry-run and --yes cannot be combined."
    return 2
  fi
  return 0
}

# Builds exact push records:
#   local-ref<TAB>local-oid<TAB>remote-ref<TAB>remote-oid-or-absent
_git_push_require_fast_forward() {
  local remote_ref="$1"
  local remote_oid="$2"
  local local_oid="$3"
  [[ "$remote_oid" != "absent" ]] || return 0
  local displayed_ref="$(_git_display_escape "$remote_ref")"

  local remote_type=""
  remote_type=$(command git --no-replace-objects \
    cat-file -t "$remote_oid" 2>/dev/null) || {
    _git_error \
      "Cannot prove a fast-forward for $displayed_ref; fetch the remote ref first."
    return 1
  }
  [[ "$remote_type" == "commit" ]] || {
    _git_error "The planned remote branch target is not a direct commit."
    return 1
  }
  local local_type=""
  local_type=$(command git --no-replace-objects \
    cat-file -t "$local_oid" 2>/dev/null) || {
    _git_error "The planned local branch target is not a commit."
    return 1
  }
  [[ "$local_type" == "commit" ]] || {
    _git_error "The planned local branch target is not a direct commit."
    return 1
  }

  command git --no-replace-objects \
    merge-base --is-ancestor "$remote_oid" "$local_oid" 2>/dev/null
  local -i ancestor_rc=$?
  case "$ancestor_rc" in
    0)
      return 0
      ;;
    1)
      _git_error \
        "Refusing non-fast-forward $displayed_ref; review explicit --force-with-lease first."
      return 1
      ;;
    *)
      _git_error \
        "Unable to verify fast-forward ancestry for $(_git_display_escape "$remote_ref")."
      return 1
      ;;
  esac
}

_git_push_build_plan() {
  local mode="$1"
  local remote="$2"
  local local_ref="$3"
  local local_oid="$4"
  local remote_ref="$5"
  reply=()

  local -a remote_records=()
  local REPLY=""
  if [[ "$mode" == (tags|all) ]]; then
    local pattern local_pattern
    if [[ "$mode" == "tags" ]]; then
      pattern='refs/tags/*'
      local_pattern='refs/tags'
    else
      pattern='refs/heads/*'
      local_pattern='refs/heads'
    fi
    _git_sync_remote_snapshot "$remote" "$pattern" || return $?
    remote_records=("${reply[@]}")

    local -a local_records=()
    _git_sync_local_snapshot "$local_pattern" || return $?
    local_records=("${reply[@]}")
    reply=()

    local local_record candidate_oid candidate_ref remote_oid
    for local_record in "${local_records[@]}"; do
      candidate_oid="${local_record%%$'\t'*}"
      candidate_ref="${local_record#*$'\t'}"
      _git_sync_find_remote_oid "$candidate_ref" "${remote_records[@]}"
      remote_oid="$REPLY"
      [[ "$remote_oid" == "$candidate_oid" ]] && continue
      if [[ "$mode" == "tags" && "$remote_oid" != "absent" ]]; then
        _git_error \
          "Refusing to overwrite remote tag $(_git_display_escape "$candidate_ref")."
        return 1
      fi
      if [[ "$mode" == "all" ]]; then
        _git_push_require_fast_forward \
          "$candidate_ref" "$remote_oid" "$candidate_oid" || return 1
      fi
      reply+=("${candidate_ref}"$'\t'"${candidate_oid}"$'\t'"${candidate_ref}"$'\t'"${remote_oid}")
    done
    return 0
  fi

  _git_sync_remote_snapshot "$remote" "$remote_ref" || return $?
  local -a exact_remote_records=("${reply[@]}")
  _git_sync_find_remote_oid "$remote_ref" "${exact_remote_records[@]}"
  local remote_oid="$REPLY"
  if [[ "$mode" == "force" && "$remote_oid" == "absent" ]]; then
    _git_error \
      "A force-with-lease push requires an existing remote object ID."
    return 1
  fi
  if [[ "$mode" == "force" ]]; then
    local remote_type=""
    remote_type=$(command git --no-replace-objects \
      cat-file -t "$remote_oid" 2>/dev/null) || {
      _git_error \
        "Cannot validate the force lease; fetch the remote ref first."
      return 1
    }
    [[ "$remote_type" == "commit" ]] || {
      _git_error "The force-push destination is not a direct commit."
      return 1
    }
  else
    _git_push_require_fast_forward \
      "$remote_ref" "$remote_oid" "$local_oid" || return 1
  fi
  reply=("${local_ref}"$'\t'"${local_oid}"$'\t'"${remote_ref}"$'\t'"${remote_oid}")
  return 0
}

_git_push_show_plan() {
  local root="$1"
  local head_oid="$2"
  local mode="$3"
  local remote="$4"
  local push_url="$5"
  shift 5
  local -a plan=("$@")

  _git_label "Repository:" "$root"
  _git_label "HEAD:" "$head_oid"
  _git_label "Mode:" "$mode"
  _git_label "Remote:" "$remote"
  _git_label "Push URL:" "$(_git_redact_remote_url "$push_url")"
  _git_label "Ref updates:" "${#plan[@]}"
  _git_blank

  local record remainder local_ref local_oid remote_ref remote_oid
  for record in "${plan[@]}"; do
    local_ref="${record%%$'\t'*}"
    remainder="${record#*$'\t'}"
    local_oid="${remainder%%$'\t'*}"
    remainder="${remainder#*$'\t'}"
    remote_ref="${remainder%%$'\t'*}"
    remote_oid="${remainder##*$'\t'}"
    _git_dim \
      "$local_ref @ $local_oid -> $remote/$remote_ref @ $remote_oid"
  done
}

_git_push_apply_plan() {
  local mode="$1"
  local remote="$2"
  local push_url="$3"
  shift 3
  local -a plan=("$@")

  local -i pushed=0 failed=0
  local record remainder local_ref local_oid remote_ref expected_remote_oid
  local current_url actual_local_oid actual_remote_oid
  local -a remote_records=()
  local REPLY=""

  for record in "${plan[@]}"; do
    local_ref="${record%%$'\t'*}"
    remainder="${record#*$'\t'}"
    local_oid="${remainder%%$'\t'*}"
    remainder="${remainder#*$'\t'}"
    remote_ref="${remainder%%$'\t'*}"
    expected_remote_oid="${remainder##*$'\t'}"

    _git_validate_full_ref "$local_ref" \
      && _git_validate_oid "$local_oid" \
      && _git_validate_full_ref "$remote_ref" \
      && {
        [[ "$expected_remote_oid" == "absent" ]] \
          || _git_validate_oid "$expected_remote_oid"
      } || {
      _git_error "Refusing an invalid push-plan record."
      failed=$(( failed + 1 ))
      continue
    }

    case "$mode" in
      current|set-upstream|force)
        [[ "$local_ref" == refs/heads/* \
          && "$remote_ref" == refs/heads/* ]] || {
          _git_error "Refusing a non-branch record in a branch push."
          failed=$(( failed + 1 ))
          continue
        }
        ;;
      all)
        [[ "$local_ref" == refs/heads/* \
          && "$remote_ref" == "$local_ref" ]] || {
          _git_error "Refusing an invalid all-branches push record."
          failed=$(( failed + 1 ))
          continue
        }
        ;;
      tags)
        [[ "$local_ref" == refs/tags/* \
          && "$remote_ref" == "$local_ref" ]] || {
          _git_error "Refusing an invalid tags push record."
          failed=$(( failed + 1 ))
          continue
        }
        ;;
      *)
        _git_error "Refusing an unknown push-plan mode."
        return 1
        ;;
    esac

    local push_urls_output
    push_urls_output=$(command git remote get-url --push --all \
      "$remote" 2>/dev/null) || push_urls_output=""
    local -a push_urls=()
    [[ -n "$push_urls_output" ]] \
      && push_urls=("${(@f)push_urls_output}")
    if (( ${#push_urls[@]} == 1 )); then
      current_url="${push_urls[1]}"
    else
      current_url=""
    fi
    if [[ "$current_url" != "$push_url" ]]; then
      _git_error "The push URL for '$remote' changed during the transaction."
      failed=$(( failed + 1 ))
      continue
    fi

    _git_sync_ref_oid "$local_ref" || REPLY=""
    actual_local_oid="$REPLY"
    if [[ "$actual_local_oid" != "$local_oid" ]]; then
      _git_error \
        "Refused moved local ref: $(_git_display_escape "$local_ref")"
      failed=$(( failed + 1 ))
      continue
    fi

    _git_sync_remote_snapshot "$push_url" "$remote_ref" || {
      failed=$(( failed + 1 ))
      continue
    }
    remote_records=("${reply[@]}")
    _git_sync_find_remote_oid "$remote_ref" "${remote_records[@]}"
    actual_remote_oid="$REPLY"
    if [[ "$actual_remote_oid" != "$expected_remote_oid" ]]; then
      _git_error \
        "Refused changed remote ref: $(_git_display_escape "$remote_ref")"
      failed=$(( failed + 1 ))
      continue
    fi

    case "$mode" in
      current|set-upstream|all)
        _git_push_require_fast_forward \
          "$remote_ref" "$expected_remote_oid" "$local_oid" || {
          failed=$(( failed + 1 ))
          continue
        }
        ;;
      tags)
        if [[ "$expected_remote_oid" != "absent" ]]; then
          _git_error \
            "Refusing to overwrite an existing tag through a leased push."
          failed=$(( failed + 1 ))
          continue
        fi
        ;;
      force)
        if [[ "$expected_remote_oid" == "absent" ]]; then
          _git_error \
            "A force-with-lease push requires an existing remote object ID."
          failed=$(( failed + 1 ))
          continue
        fi
        local force_local_type="" force_remote_type=""
        force_local_type=$(command git --no-replace-objects cat-file -t \
          "$local_oid" 2>/dev/null) || force_local_type=""
        force_remote_type=$(command git --no-replace-objects cat-file -t \
          "$expected_remote_oid" 2>/dev/null) || force_remote_type=""
        if [[ "$force_local_type" != "commit" \
          || "$force_remote_type" != "commit" ]]; then
          _git_error \
            "The planned force-push source or destination is not a direct commit."
          failed=$(( failed + 1 ))
          continue
        fi
        ;;
    esac

    local lease_arg=""
    if [[ "$expected_remote_oid" == "absent" ]]; then
      lease_arg="--force-with-lease=${remote_ref}:"
    else
      lease_arg="--force-with-lease=${remote_ref}:${expected_remote_oid}"
    fi

    local -a push_cmd=(command git push "$lease_arg")
    [[ "$mode" == "force" ]] && push_cmd+=(--force-if-includes)
    push_cmd+=(-- "$push_url" "${local_oid}:${remote_ref}")

    "${push_cmd[@]}" >&2
    local -i push_rc=$?
    if (( push_rc == 0 )); then
      pushed=$(( pushed + 1 ))
      if [[ "$mode" == "set-upstream" ]]; then
        _git_sync_ref_oid "$local_ref" || REPLY=""
        if [[ "$REPLY" != "$local_oid" ]]; then
          _git_error \
            "Remote push succeeded, but the local branch moved before upstream configuration."
          return 1
        fi
        push_urls_output=$(command git remote get-url --push --all \
          "$remote" 2>/dev/null) || push_urls_output=""
        push_urls=()
        [[ -n "$push_urls_output" ]] \
          && push_urls=("${(@f)push_urls_output}")
        if (( ${#push_urls[@]} == 1 )); then
          current_url="${push_urls[1]}"
        else
          current_url=""
        fi
        if [[ "$current_url" != "$push_url" ]]; then
          _git_error \
            "Remote push succeeded, but the push URL changed before upstream configuration."
          return 1
        fi
        _git_sync_remote_snapshot "$push_url" "$remote_ref" || {
          _git_error \
            "Remote push succeeded, but its exact result could not be verified."
          return 1
        }
        remote_records=("${reply[@]}")
        _git_sync_find_remote_oid "$remote_ref" "${remote_records[@]}"
        if [[ "$REPLY" != "$local_oid" ]]; then
          _git_error \
            "Remote push succeeded, but the destination changed before upstream configuration."
          return 1
        fi
        local tracking_ref="refs/remotes/${remote}/${remote_ref#refs/heads/}"
        _git_sync_direct_ref_oid "$tracking_ref" || {
          _git_error \
            "Remote push succeeded, but the tracking ref could not be inspected."
          return 1
        }
        local tracking_oid="$REPLY"
        _git_sync_promote_tracking_ref \
          "$tracking_ref" "$local_oid" "$tracking_oid" || {
          _git_error \
            "Remote push succeeded, but the tracking ref changed locally."
          return 1
        }
        command git branch \
          "--set-upstream-to=${remote}/${remote_ref#refs/heads/}" \
          "${local_ref#refs/heads/}" >&2 || {
          _git_error \
            "Remote push succeeded, but upstream configuration failed."
          return 1
        }
      fi
      local displayed_local="$(_git_display_escape "$local_ref")"
      local displayed_remote="$(_git_display_escape "$remote_ref")"
      _git_success "Pushed $displayed_local to $remote/$displayed_remote."
    else
      _git_error \
        "Push failed for $(_git_display_escape "$remote_ref") (exit $push_rc)."
      failed=$(( failed + 1 ))
    fi
  done

  if (( failed > 0 )); then
    _git_error "Push incomplete: $pushed succeeded, $failed failed."
    return 1
  fi
  _git_success "Push complete: $pushed ref update(s)."
  return 0
}

git-push() {
  emulate -L zsh

  local _git_push_opt_remote="" _git_push_opt_ref=""
  local _git_push_opt_mode="current"
  local -i _git_push_opt_dry_run=0 _git_push_opt_yes=0
  local -i _git_push_opt_explicit=0 parse_rc=0

  _git_push_parse_options "$@" || parse_rc=$?
  (( parse_rc == 3 )) && return 0
  (( parse_rc != 0 )) && return $parse_rc

  _git_require_repo || return 1
  _git_header "Push Refs"

  if (( ! _git_push_opt_explicit )); then
    local REPLY=""
    _git_sync_select_fixed "push action" \
      "Push current branch" \
      "Push current branch and set upstream" \
      "Force current branch with exact lease" \
      "Push all changed tags" \
      "Push all branches" \
      "Dry-run current branch" || return $?
    [[ -n "$REPLY" ]] || {
      _git_info "Cancelled. No push action was selected."
      return 0
    }
    case "$REPLY" in
      "Push current branch")
        _git_push_opt_mode="current"
        ;;
      "Push current branch and set upstream")
        _git_push_opt_mode="set-upstream"
        ;;
      "Force current branch with exact lease")
        _git_push_opt_mode="force"
        ;;
      "Push all changed tags")
        _git_push_opt_mode="tags"
        ;;
      "Push all branches")
        _git_push_opt_mode="all"
        ;;
      "Dry-run current branch")
        _git_push_opt_mode="current"
        _git_push_opt_dry_run=1
        ;;
    esac
  fi

  _git_context_refresh || return 1
  local root="${_GIT_CONTEXT[root]}"
  local head_oid="${_GIT_CONTEXT[head]}"
  local fingerprint="${_GIT_CONTEXT[fingerprint]}"

  local _git_sync_branch="" _git_sync_local_ref="" _git_sync_local_oid=""
  local _git_sync_remote="" _git_sync_remote_ref=""
  local _git_sync_tracking_ref="" _git_sync_push_url=""
  local _git_sync_fetch_url=""
  local REPLY=""
  _git_sync_resolve_branch_target \
    "$_git_push_opt_remote" "$_git_push_opt_ref" push || return $?

  if [[ "$_git_push_opt_mode" == "force" ]]; then
    _git_warn \
      "Force mode can rewrite remote history; the exact remote OID is leased."
  fi

  local -a reply=()
  local -a plan=()
  _git_push_build_plan \
    "$_git_push_opt_mode" "$_git_sync_push_url" \
    "$_git_sync_local_ref" "$_git_sync_local_oid" \
    "$_git_sync_remote_ref" || return $?
  plan=("${reply[@]}")
  if (( ${#plan[@]} == 0 )); then
    _git_success "The remote already matches every planned ref."
    return 0
  fi

  _git_push_show_plan \
    "$root" "$head_oid" "$_git_push_opt_mode" "$_git_sync_remote" \
    "$_git_sync_push_url" "${plan[@]}"

  if (( _git_push_opt_dry_run )); then
    _git_warn "DRY-RUN — no remote refs were changed."
    return 0
  fi

  local -i authorize_rc=0
  _git_sync_authorize "$_git_push_opt_yes" \
    "Push ${#plan[@]} exact ref update(s) to '$_git_sync_remote'?" \
    || authorize_rc=$?
  (( authorize_rc == 3 )) && return 0
  (( authorize_rc != 0 )) && return $authorize_rc

  _git_sync_revalidate_context \
    "$root" "$head_oid" "$fingerprint" "$_git_sync_local_ref" \
    "$_git_sync_local_oid" "$_git_sync_remote" "$_git_sync_push_url" push \
    || return 1

  _git_push_apply_plan \
    "$_git_push_opt_mode" "$_git_sync_remote" "$_git_sync_push_url" \
    "${plan[@]}"
}

# --- Pull and fetch ----------------------------------------------------------

_git_pull_usage() {
  print -u2 -r -- "Usage: git-pull [options]"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Fetch an explicit remote branch, then apply its frozen object ID locally."
  print -u2 -r -- ""
  print -u2 -r -- "  --remote NAME   Select a configured remote."
  print -u2 -r -- \
    "  --ref FULL_REF  Fetch a full refs/heads/... source ref."
  print -u2 -r -- "  --merge         Merge the fetched object (default direct mode)."
  print -u2 -r -- "  --rebase        Rebase local commits onto the fetched object."
  print -u2 -r -- "  --ff-only       Require a fast-forward merge."
  print -u2 -r -- "  --fetch         Fetch the exact ref without changing HEAD."
  print -u2 -r -- \
    "  --fetch-prune   Fetch remote branches and prune stale tracking refs."
  print -u2 -r -- \
    "  --dry-run       Display the exact plan without fetching or changing HEAD."
  print -u2 -r -- \
    "  --yes, -y       Skip confirmation; revalidation still runs."
}

# Sets dynamically scoped _git_pull_opt_* variables.
_git_pull_parse_options() {
  _git_pull_opt_remote=""
  _git_pull_opt_ref=""
  _git_pull_opt_mode="merge"
  _git_pull_opt_dry_run=0
  _git_pull_opt_yes=0
  _git_pull_opt_explicit=0
  local -i argument_count=$#
  local -i mode_count=0

  while (( $# > 0 )); do
    _git_pull_opt_explicit=1
    case "$1" in
      -h|--help)
        (( argument_count == 1 )) || {
          _git_error "--help accepts no additional arguments."
          return 2
        }
        _git_pull_usage
        return 3
        ;;
      --remote)
        (( $# >= 2 )) || {
          _git_error "--remote requires a configured remote name."
          return 2
        }
        [[ -n "$2" ]] || {
          _git_error "--remote requires a non-empty remote name."
          return 2
        }
        [[ -z "$_git_pull_opt_remote" ]] || {
          _git_error "--remote may be specified only once."
          return 2
        }
        _git_pull_opt_remote="$2"
        shift
        ;;
      --ref)
        (( $# >= 2 )) || {
          _git_error "--ref requires a full refs/heads/... reference."
          return 2
        }
        [[ -n "$2" ]] || {
          _git_error "--ref requires a non-empty full reference."
          return 2
        }
        [[ -z "$_git_pull_opt_ref" ]] || {
          _git_error "--ref may be specified only once."
          return 2
        }
        _git_pull_opt_ref="$2"
        shift
        ;;
      --merge)
        _git_pull_opt_mode="merge"
        mode_count=$(( mode_count + 1 ))
        ;;
      --rebase)
        _git_pull_opt_mode="rebase"
        mode_count=$(( mode_count + 1 ))
        ;;
      --ff-only)
        _git_pull_opt_mode="ff-only"
        mode_count=$(( mode_count + 1 ))
        ;;
      --fetch)
        _git_pull_opt_mode="fetch"
        mode_count=$(( mode_count + 1 ))
        ;;
      --fetch-prune)
        _git_pull_opt_mode="fetch-prune"
        mode_count=$(( mode_count + 1 ))
        ;;
      --dry-run)
        _git_pull_opt_dry_run=1
        ;;
      -y|--yes)
        _git_pull_opt_yes=1
        ;;
      *)
        _git_error "Unknown argument for git-pull: $1"
        return 2
        ;;
    esac
    shift
  done

  (( mode_count <= 1 )) || {
    _git_error \
      "Choose only one of --merge, --rebase, --ff-only, --fetch, or --fetch-prune."
    return 2
  }
  if [[ -n "$_git_pull_opt_remote" ]] \
    && ! _git_validate_remote_token "$_git_pull_opt_remote"; then
    _git_error "Invalid remote name."
    return 2
  fi
  if [[ -n "$_git_pull_opt_ref" ]] \
    && {
      ! _git_validate_full_ref "$_git_pull_opt_ref" \
        || [[ "$_git_pull_opt_ref" != refs/heads/* ]]
    }; then
    _git_error "--ref must be a full refs/heads/... reference."
    return 2
  fi
  if [[ "$_git_pull_opt_mode" == "fetch-prune" \
    && -n "$_git_pull_opt_ref" ]]; then
    _git_error "--ref cannot be combined with --fetch-prune."
    return 2
  fi
  if (( _git_pull_opt_dry_run && _git_pull_opt_yes )); then
    _git_error "--dry-run and --yes cannot be combined."
    return 2
  fi
  return 0
}

# Builds fetch-prune records:
#   tracking-ref<TAB>old-oid-or-absent<TAB>remote-ref-or-absent<TAB>new-oid-or-absent
# Also freezes the complete remote and local snapshots in the dynamically
# scoped _git_pull_prune_remote_records and _git_pull_prune_local_records
# arrays so callers can verify more than the displayed delta.
_git_pull_build_prune_plan() {
  local remote="$1"
  local tracking_prefix="refs/remotes/${remote}/"
  reply=()
  _git_pull_prune_remote_records=()
  _git_pull_prune_local_records=()

  local -a remote_records=()
  _git_sync_remote_snapshot "$remote" 'refs/heads/*' || return $?
  remote_records=("${reply[@]}")
  _git_pull_prune_remote_records=("${(@o)remote_records}")

  local -a local_records=()
  _git_sync_local_snapshot "$tracking_prefix" || return $?
  local_records=("${reply[@]}")
  _git_pull_prune_local_records=("${(@o)local_records}")
  reply=()

  local remote_record remote_oid remote_ref tracking_ref
  local local_record local_oid local_ref
  local REPLY=""
  for local_record in "${local_records[@]}"; do
    local_oid="${local_record%%$'\t'*}"
    local_ref="${local_record#*$'\t'}"
    [[ "$local_ref" == "${tracking_prefix}HEAD" ]] && continue
    _git_sync_direct_ref_oid "$local_ref" || return $?
    [[ "$REPLY" == "$local_oid" ]] || {
      _git_error \
        "A remote-tracking ref changed while the plan was being built."
      return 1
    }
  done

  for remote_record in "${remote_records[@]}"; do
    remote_oid="${remote_record%%$'\t'*}"
    remote_ref="${remote_record#*$'\t'}"
    tracking_ref="${tracking_prefix}${remote_ref#refs/heads/}"
    [[ "$tracking_ref" != "${tracking_prefix}HEAD" ]] || {
      _git_error \
        "Remote branch 'HEAD' collides with the reserved tracking alias."
      return 1
    }
    local_oid="absent"
    for local_record in "${local_records[@]}"; do
      [[ "${local_record#*$'\t'}" == "$tracking_ref" ]] || continue
      local_oid="${local_record%%$'\t'*}"
      break
    done
    [[ "$local_oid" == "$remote_oid" ]] && continue
    reply+=("${tracking_ref}"$'\t'"${local_oid}"$'\t'"${remote_ref}"$'\t'"${remote_oid}")
  done

  for local_record in "${local_records[@]}"; do
    local_oid="${local_record%%$'\t'*}"
    local_ref="${local_record#*$'\t'}"
    [[ "$local_ref" == "${tracking_prefix}HEAD" ]] && continue
    remote_ref="refs/heads/${local_ref#$tracking_prefix}"
    _git_sync_find_remote_oid "$remote_ref" "${remote_records[@]}"
    [[ "$REPLY" != "absent" ]] && continue
    reply+=("${local_ref}"$'\t'"${local_oid}"$'\t'"absent"$'\t'"absent")
  done
  reply=("${(@o)reply}")
  return 0
}

# Converts temporary oid<TAB>ref records back into
# oid<TAB>refs/heads/... records.
_git_pull_normalize_temp_records() {
  local temp_prefix="$1"
  shift
  local -a temp_records=("$@")
  reply=()

  local record oid temp_ref branch_name remote_ref
  for record in "${temp_records[@]}"; do
    oid="${record%%$'\t'*}"
    temp_ref="${record#*$'\t'}"
    branch_name="${temp_ref#${temp_prefix}/}"
    [[ -n "$branch_name" && "$branch_name" != "$temp_ref" ]] || {
      _git_error "The temporary fetch returned an invalid branch mapping."
      return 1
    }
    remote_ref="refs/heads/${branch_name}"
    _git_validate_full_ref "$remote_ref" || {
      _git_error "The temporary fetch returned an invalid remote ref."
      return 1
    }
    reply+=("${oid}"$'\t'"${remote_ref}")
  done
  reply=("${(@o)reply}")
  return 0
}

# Applies every canonical tracking-ref change as one compare-and-swap
# transaction. No ref is updated if any old OID no longer matches.
_git_pull_apply_prune_plan() {
  local remote="$1"
  shift
  local -a plan=("$@")
  (( ${#plan[@]} > 0 )) || return 0

  local tracking_prefix="refs/remotes/${remote}/"
  local -a transaction=(start "option no-deref")
  local record remainder tracking_ref old_oid remote_ref new_oid
  local expected_old
  for record in "${plan[@]}"; do
    tracking_ref="${record%%$'\t'*}"
    remainder="${record#*$'\t'}"
    old_oid="${remainder%%$'\t'*}"
    remainder="${remainder#*$'\t'}"
    remote_ref="${remainder%%$'\t'*}"
    new_oid="${remainder##*$'\t'}"

    _git_validate_full_ref "$tracking_ref" \
      && [[ "$tracking_ref" == "${tracking_prefix}"* \
        && "$tracking_ref" != "${tracking_prefix}HEAD" ]] || {
      _git_error "Refusing an invalid fetch-prune tracking ref."
      return 1
    }

    if [[ "$remote_ref" == "absent" && "$new_oid" == "absent" ]]; then
      _git_validate_oid "$old_oid" || {
        _git_error "Refusing an invalid fetch-prune deletion lease."
        return 1
      }
      transaction+=("delete ${tracking_ref} ${old_oid}")
      continue
    fi

    _git_validate_full_ref "$remote_ref" \
      && [[ "$remote_ref" == refs/heads/* ]] \
      && _git_validate_oid "$new_oid" \
      && {
        [[ "$old_oid" == "absent" ]] || _git_validate_oid "$old_oid"
      } \
      && [[ "$tracking_ref" \
        == "${tracking_prefix}${remote_ref#refs/heads/}" ]] || {
      _git_error "Refusing an invalid fetch-prune update lease."
      return 1
    }
    expected_old="$old_oid"
    [[ "$expected_old" != "absent" ]] \
      || expected_old="${new_oid//?/0}"
    transaction+=(
      "update ${tracking_ref} ${new_oid} ${expected_old}"
    )
  done
  transaction+=(prepare commit)

  printf '%s\n' "${transaction[@]}" \
    | command git update-ref \
      -m "zdx-suite git-pull --fetch-prune" --stdin >/dev/null
  local -i update_rc=$?
  if (( update_rc != 0 )); then
    _git_error \
      "Tracking refs changed during fetch; the prune transaction was aborted."
    return 1
  fi
  return 0
}

_git_pull_show_plan() {
  local root="$1"
  local head_oid="$2"
  local local_ref="$3"
  local mode="$4"
  local remote="$5"
  local fetch_url="$6"
  local remote_ref="$7"
  local remote_oid="$8"
  local tracking_ref="$9"
  local tracking_oid="${10}"

  _git_label "Repository:" "$root"
  _git_label "HEAD:" "$head_oid"
  _git_label "Current ref:" "$local_ref"
  _git_label "Mode:" "$mode"
  _git_label "Remote:" "$remote"
  _git_label "Fetch URL:" "$(_git_redact_remote_url "$fetch_url")"
  _git_label "Source ref:" "$remote_ref"
  _git_label "Source OID:" "$remote_oid"
  _git_label "Tracking ref:" "$tracking_ref"
  _git_label "Tracking OID:" "$tracking_oid"
}

_git_pull_show_prune_plan() {
  local root="$1"
  local head_oid="$2"
  local local_ref="$3"
  local remote="$4"
  local fetch_url="$5"
  shift 5
  local -a plan=("$@")

  _git_label "Repository:" "$root"
  _git_label "HEAD:" "$head_oid"
  _git_label "Current ref:" "$local_ref"
  _git_label "Mode:" "fetch and prune"
  _git_label "Remote:" "$remote"
  _git_label "Fetch URL:" "$(_git_redact_remote_url "$fetch_url")"
  _git_label "Tracking changes:" "${#plan[@]}"
  _git_blank

  local record remainder tracking_ref old_oid remote_ref new_oid
  for record in "${plan[@]}"; do
    tracking_ref="${record%%$'\t'*}"
    remainder="${record#*$'\t'}"
    old_oid="${remainder%%$'\t'*}"
    remainder="${remainder#*$'\t'}"
    remote_ref="${remainder%%$'\t'*}"
    new_oid="${remainder##*$'\t'}"
    _git_dim \
      "$tracking_ref @ $old_oid <- $remote_ref @ $new_oid"
  done
}

git-pull() {
  emulate -L zsh

  local _git_pull_opt_remote="" _git_pull_opt_ref=""
  local _git_pull_opt_mode="merge"
  local -i _git_pull_opt_dry_run=0 _git_pull_opt_yes=0
  local -i _git_pull_opt_explicit=0 parse_rc=0

  _git_pull_parse_options "$@" || parse_rc=$?
  (( parse_rc == 3 )) && return 0
  (( parse_rc != 0 )) && return $parse_rc

  _git_require_repo || return 1
  _git_header "Pull or Fetch"

  if (( ! _git_pull_opt_explicit )); then
    local REPLY=""
    _git_sync_select_fixed "pull action" \
      "Pull with merge" \
      "Pull with rebase" \
      "Pull fast-forward only" \
      "Fetch exact upstream only" \
      "Fetch and prune all tracking refs" \
      "Dry-run pull with merge" || return $?
    [[ -n "$REPLY" ]] || {
      _git_info "Cancelled. No pull action was selected."
      return 0
    }
    case "$REPLY" in
      "Pull with merge") _git_pull_opt_mode="merge" ;;
      "Pull with rebase") _git_pull_opt_mode="rebase" ;;
      "Pull fast-forward only") _git_pull_opt_mode="ff-only" ;;
      "Fetch exact upstream only") _git_pull_opt_mode="fetch" ;;
      "Fetch and prune all tracking refs")
        _git_pull_opt_mode="fetch-prune"
        ;;
      "Dry-run pull with merge")
        _git_pull_opt_mode="merge"
        _git_pull_opt_dry_run=1
        ;;
    esac
  fi

  _git_context_refresh || return 1
  local root="${_GIT_CONTEXT[root]}"
  local head_oid="${_GIT_CONTEXT[head]}"
  local fingerprint="${_GIT_CONTEXT[fingerprint]}"

  local _git_sync_branch="" _git_sync_local_ref="" _git_sync_local_oid=""
  local _git_sync_remote="" _git_sync_remote_ref=""
  local _git_sync_tracking_ref="" _git_sync_push_url=""
  local _git_sync_fetch_url=""
  local REPLY=""
  _git_sync_resolve_branch_target \
    "$_git_pull_opt_remote" "$_git_pull_opt_ref" fetch || return $?

  local -a reply=()
  local -a prune_plan=()
  local -a _git_pull_prune_remote_records=()
  local -a _git_pull_prune_local_records=()
  local -a frozen_prune_remote_records=()
  local -a frozen_prune_local_records=()
  local remote_oid=""
  local tracking_oid="absent"
  if [[ "$_git_pull_opt_mode" == "fetch-prune" ]]; then
    _git_pull_build_prune_plan "$_git_sync_remote" || return $?
    prune_plan=("${reply[@]}")
    frozen_prune_remote_records=(
      "${_git_pull_prune_remote_records[@]}"
    )
    frozen_prune_local_records=(
      "${_git_pull_prune_local_records[@]}"
    )
    if (( ${#prune_plan[@]} == 0 )); then
      _git_success "Remote-tracking refs already match the remote."
      return 0
    fi
    _git_pull_show_prune_plan \
      "$root" "$head_oid" "$_git_sync_local_ref" "$_git_sync_remote" \
      "$_git_sync_fetch_url" "${prune_plan[@]}"
  else
    _git_sync_remote_snapshot \
      "$_git_sync_remote" "$_git_sync_remote_ref" || return $?
    local -a remote_records=("${reply[@]}")
    _git_sync_find_remote_oid \
      "$_git_sync_remote_ref" "${remote_records[@]}"
    remote_oid="$REPLY"
    [[ "$remote_oid" != "absent" ]] || {
      _git_error \
        "Remote ref '$(_git_display_escape "$_git_sync_remote_ref")' does not exist."
      return 1
    }
    _git_sync_direct_ref_oid "$_git_sync_tracking_ref" || return $?
    tracking_oid="$REPLY"
    _git_pull_show_plan \
      "$root" "$head_oid" "$_git_sync_local_ref" \
      "$_git_pull_opt_mode" "$_git_sync_remote" "$_git_sync_fetch_url" \
      "$_git_sync_remote_ref" "$remote_oid" \
      "$_git_sync_tracking_ref" "$tracking_oid"
  fi

  if (( _git_pull_opt_dry_run )); then
    _git_warn "DRY-RUN — no refs or worktree state were changed."
    return 0
  fi

  local -i authorize_rc=0
  _git_sync_authorize "$_git_pull_opt_yes" \
    "Apply the displayed $_git_pull_opt_mode plan?" || authorize_rc=$?
  (( authorize_rc == 3 )) && return 0
  (( authorize_rc != 0 )) && return $authorize_rc

  _git_sync_revalidate_context \
    "$root" "$head_oid" "$fingerprint" "$_git_sync_local_ref" \
    "$_git_sync_local_oid" "$_git_sync_remote" "$_git_sync_fetch_url" fetch \
    || return 1

  if [[ "$_git_pull_opt_mode" == "fetch-prune" ]]; then
    local -a refreshed_plan=()
    _git_pull_build_prune_plan "$_git_sync_remote" || return $?
    refreshed_plan=("${reply[@]}")
    [[ "${(j:$'\n':)refreshed_plan}" \
      == "${(j:$'\n':)prune_plan}" \
      && "${(j:$'\n':)_git_pull_prune_remote_records}" \
      == "${(j:$'\n':)frozen_prune_remote_records}" \
      && "${(j:$'\n':)_git_pull_prune_local_records}" \
      == "${(j:$'\n':)frozen_prune_local_records}" ]] || {
      _git_error "Remote or tracking refs changed after planning."
      return 1
    }

    _git_sync_allocate_temp_prefix || return 1
    local prune_temp_prefix="$REPLY"
    local prune_refspec="refs/heads/*:${prune_temp_prefix}/*"
    _git_sync_fetch_temp "$_git_sync_remote" "$prune_refspec"
    local -i prune_fetch_rc=$?

    local -a prune_temp_records=()
    _git_sync_temp_snapshot "$prune_temp_prefix" || {
      _git_error \
        "Unable to inventory the temporary refs; inspect '$prune_temp_prefix'."
      return 1
    }
    prune_temp_records=("${reply[@]}")
    if (( prune_fetch_rc != 0 )); then
      _git_sync_cleanup_temp_refs \
        "$prune_temp_prefix" "${prune_temp_records[@]}" || return 1
      _git_error \
        "Fetch and prune failed for '$_git_sync_remote' (exit $prune_fetch_rc)."
      return $prune_fetch_rc
    fi

    _git_pull_normalize_temp_records \
      "$prune_temp_prefix" "${prune_temp_records[@]}" || {
      _git_sync_cleanup_temp_refs \
        "$prune_temp_prefix" "${prune_temp_records[@]}" || true
      return 1
    }
    local -a fetched_remote_records=("${reply[@]}")
    if [[ "${(j:$'\n':)fetched_remote_records}" \
      != "${(j:$'\n':)frozen_prune_remote_records}" ]]; then
      _git_sync_cleanup_temp_refs \
        "$prune_temp_prefix" "${prune_temp_records[@]}" || true
      _git_error \
        "The fetched remote snapshot does not match the frozen prune plan."
      return 1
    fi
    _git_sync_validate_temp_commits "${prune_temp_records[@]}" || {
      _git_sync_cleanup_temp_refs \
        "$prune_temp_prefix" "${prune_temp_records[@]}" || true
      return 1
    }

    _git_sync_revalidate_context \
      "$root" "$head_oid" "$fingerprint" "$_git_sync_local_ref" \
      "$_git_sync_local_oid" "$_git_sync_remote" \
      "$_git_sync_fetch_url" fetch || {
      _git_sync_cleanup_temp_refs \
        "$prune_temp_prefix" "${prune_temp_records[@]}" || true
      return 1
    }

    local -i prune_apply_rc=0
    _git_pull_apply_prune_plan \
      "$_git_sync_remote" "${prune_plan[@]}" || prune_apply_rc=$?
    local -i prune_cleanup_rc=0
    _git_sync_cleanup_temp_refs \
      "$prune_temp_prefix" "${prune_temp_records[@]}" \
      || prune_cleanup_rc=$?
    (( prune_apply_rc == 0 )) || return $prune_apply_rc
    (( prune_cleanup_rc == 0 )) || return $prune_cleanup_rc

    _git_success "Fetched and pruned '$_git_sync_remote'."
    return 0
  fi

  _git_sync_remote_snapshot \
    "$_git_sync_remote" "$_git_sync_remote_ref" || return $?
  local -a current_remote_records=("${reply[@]}")
  _git_sync_find_remote_oid \
    "$_git_sync_remote_ref" "${current_remote_records[@]}"
  [[ "$REPLY" == "$remote_oid" ]] || {
    _git_error "The remote source ref changed after planning."
    return 1
  }

  _git_sync_direct_ref_oid "$_git_sync_tracking_ref" || return $?
  [[ "$REPLY" == "$tracking_oid" ]] || {
    _git_error "The tracking ref changed after planning."
    return 1
  }

  _git_sync_allocate_temp_prefix || return 1
  local exact_temp_prefix="$REPLY"
  local exact_temp_ref="${exact_temp_prefix}/source"
  local fetch_refspec="${_git_sync_remote_ref}:${exact_temp_ref}"
  _git_sync_fetch_temp "$_git_sync_remote" "$fetch_refspec"
  local -i exact_fetch_rc=$?

  local -a exact_temp_records=()
  _git_sync_temp_snapshot "$exact_temp_prefix" || {
    _git_error \
      "Unable to inventory the temporary refs; inspect '$exact_temp_prefix'."
    return 1
  }
  exact_temp_records=("${reply[@]}")
  if (( exact_fetch_rc != 0 )); then
    _git_sync_cleanup_temp_refs \
      "$exact_temp_prefix" "${exact_temp_records[@]}" || return 1
    _git_error "Fetch failed (exit $exact_fetch_rc)."
    return $exact_fetch_rc
  fi

  local fetched_oid=""
  if (( ${#exact_temp_records[@]} == 1 )) \
    && [[ "${exact_temp_records[1]#*$'\t'}" == "$exact_temp_ref" ]]; then
    fetched_oid="${exact_temp_records[1]%%$'\t'*}"
  fi
  [[ "$fetched_oid" == "$remote_oid" ]] || {
    _git_sync_cleanup_temp_refs \
      "$exact_temp_prefix" "${exact_temp_records[@]}" || true
    _git_error "The fetched object does not match the frozen remote plan."
    return 1
  }

  _git_sync_validate_temp_commits "${exact_temp_records[@]}" || {
    _git_sync_cleanup_temp_refs \
      "$exact_temp_prefix" "${exact_temp_records[@]}" || true
    return 1
  }

  _git_sync_revalidate_context \
    "$root" "$head_oid" "$fingerprint" "$_git_sync_local_ref" \
    "$_git_sync_local_oid" "$_git_sync_remote" "$_git_sync_fetch_url" fetch \
    || {
    _git_sync_cleanup_temp_refs \
      "$exact_temp_prefix" "${exact_temp_records[@]}" || true
    return 1
  }
  _git_sync_direct_ref_oid "$_git_sync_tracking_ref" || {
    _git_sync_cleanup_temp_refs \
      "$exact_temp_prefix" "${exact_temp_records[@]}" || true
    return 1
  }
  [[ "$REPLY" == "$tracking_oid" ]] || {
    _git_sync_cleanup_temp_refs \
      "$exact_temp_prefix" "${exact_temp_records[@]}" || true
    _git_error "The tracking ref changed during fetch."
    return 1
  }

  local -i promote_rc=0
  _git_sync_promote_tracking_ref \
    "$_git_sync_tracking_ref" "$remote_oid" "$tracking_oid" \
    || promote_rc=$?
  local -i exact_cleanup_rc=0
  _git_sync_cleanup_temp_refs \
    "$exact_temp_prefix" "${exact_temp_records[@]}" \
    || exact_cleanup_rc=$?
  (( promote_rc == 0 )) || return $promote_rc
  (( exact_cleanup_rc == 0 )) || return $exact_cleanup_rc

  if [[ "$_git_pull_opt_mode" == "fetch" ]]; then
    _git_success \
      "Fetched $_git_sync_remote_ref at $remote_oid into $_git_sync_tracking_ref."
    return 0
  fi

  local -a apply_cmd=()
  local success_message=""
  case "$_git_pull_opt_mode" in
    merge)
      apply_cmd=(command git merge --no-edit "$remote_oid")
      success_message="Merged $remote_oid into $_git_sync_local_ref."
      ;;
    rebase)
      apply_cmd=(command git rebase "$remote_oid")
      success_message="Rebased $_git_sync_local_ref onto $remote_oid."
      ;;
    ff-only)
      apply_cmd=(command git merge --ff-only "$remote_oid")
      success_message="Fast-forwarded $_git_sync_local_ref to $remote_oid."
      ;;
    *)
      _git_error "Internal pull mode error."
      return 1
      ;;
  esac

  "${apply_cmd[@]}" >&2
  local -i apply_rc=$?
  if (( apply_rc == 0 )); then
    _git_success "$success_message"
  else
    _git_error \
      "Local $_git_pull_opt_mode operation failed (exit $apply_rc)."
  fi
  return $apply_rc
}

typeset -g _GIT_SYNC_SOURCED=1
