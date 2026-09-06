#!/usr/bin/env zsh
# =============================================================================
# WS Danger: remove a workspace and migrate existing local repos into one
# =============================================================================
#
# Loaded by ws-menu.zsh after ws-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_WS_DANGER_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_ws_migrate_repo_name_valid() {
  local repo_name="${1:-}"
  [[ -n "$repo_name" && "$repo_name" != "." && "$repo_name" != ".." \
    && "$repo_name" != -* && "$repo_name" != *$'\n'* \
    && "$repo_name" != *$'\r'* && "$repo_name" != *'|'* \
    && "$repo_name" =~ '^[A-Za-z0-9._-]+$' ]]
}

_ws_remove_ssh_marker_mode() {
  local config_file="${1:-}"
  local begin_marker="${2:-}"
  local end_marker="${3:-}"
  REPLY=""
  [[ -f "$config_file" && ! -L "$config_file" \
    && -n "$begin_marker" && -n "$end_marker" ]] || return 1

  local marker_mode=""
  marker_mode=$(awk -v begin="$begin_marker" -v end="$end_marker" '
    BEGIN { active=0; begin_count=0; end_count=0; invalid=0 }
    $0 == begin {
      begin_count++
      if (active || begin_count > 1) invalid=1
      active=1
      next
    }
    $0 == end {
      end_count++
      if (!active || end_count > 1) invalid=1
      active=0
      next
    }
    END {
      if (begin_count == 0 && end_count == 0) {
        print "legacy"
        exit 0
      }
      if (!invalid && begin_count == 1 && end_count == 1 && !active) {
        print "markers"
        exit 0
      }
      exit 1
    }
  ' "$config_file") || return 1
  [[ "$marker_mode" == "legacy" || "$marker_mode" == "markers" ]] \
    || return 1
  REPLY="$marker_mode"
}

_ws_migrate_interactive_available() {
  [[ -t 0 && -t 2 ]]
}

# An empty successful result means origin is confirmed absent, not unreadable.
_ws_migrate_origin_url() {
  emulate -L zsh

  local repo_dir="$1"
  local remotes="" remote="" origin_url=""
  REPLY=""
  remotes=$(command git -C "$repo_dir" remote 2>/dev/null) || return $?
  for remote in "${(@f)remotes}"; do
    [[ "$remote" == "origin" ]] || continue
    origin_url=$(command git -C "$repo_dir" remote get-url origin 2>/dev/null) \
      || return $?
    [[ -n "$origin_url" && "$origin_url" != *[[:cntrl:]]* ]] || return 1
    REPLY="$origin_url"
    return 0
  done
  return 0
}

ws-remove() {
  emulate -L zsh

  local -i dry_run=0
  local -i assume_yes=0
  local ws=""

  while (( $# > 0 )); do
    case "$1" in
      --dry-run)
        dry_run=1
        ;;
      -y|--yes)
        assume_yes=1
        ;;
      -h|--help)
        print -u2 -r -- \
          "Usage: ws-remove [--dry-run] [--yes] [platform/identity]"
        return 0
        ;;
      -*)
        _tk_error "Unknown option: ${(V)1}"
        return 2
        ;;
      *)
        [[ -z "$ws" ]] || {
          _tk_error "Only one workspace may be removed at a time."
          return 2
        }
        ws="$1"
        ;;
    esac
    shift
  done

  _tk_check_deps git || return 1
  _ws_validate_base_dir || return $?
  if [[ -z "$ws" ]]; then
    _tk_check_cmd fzf || {
      _tk_error "Missing dependency: fzf"
      return 1
    }
    _ws_capture_workspace_selection "Remove workspace" || return $?
    ws="$REPLY"
    [[ -z "$ws" ]] && return 0
  fi

  _ws_resolve_workspace "$ws" || return $?
  local ws_dir="$REPLY"
  [[ -d "$ws_dir" && ! -L "$ws_dir" ]] || {
    _tk_error "Workspace not found: ${(V)ws}"
    return 1
  }
  _ws_directory_fingerprint "$ws_dir" || {
    _tk_error "Refusing an unsafe or foreign-owned workspace directory."
    return 1
  }
  local workspace_fingerprint="$REPLY"
  local platform_dir="${ws_dir:h}"
  _ws_directory_fingerprint "$platform_dir" || {
    _tk_error "Refusing an unsafe workspace platform directory."
    return 1
  }
  local platform_fingerprint="$REPLY"

  local platform="${ws%%/*}"
  local identity="${ws#*/}"
  local host_alias=""
  host_alias=$(_tk_host_alias "$platform" "$identity")
  local ssh_config="$HOME/.ssh/config"
  local global_gitconfig="$HOME/.gitconfig"
  local begin_marker="# BEGIN ws:${platform}/${identity}"
  local end_marker="# END ws:${platform}/${identity}"
  local ssh_marker_mode=""
  local ssh_config_fingerprint="absent"
  local gitconfig_fingerprint="absent"

  if [[ -e "$ssh_config" || -L "$ssh_config" ]]; then
    _ws_owned_file_fingerprint "$ssh_config" || {
      _tk_error "Refusing unsafe SSH configuration file."
      return 1
    }
    ssh_config_fingerprint="$REPLY"
  fi
  if [[ -e "$global_gitconfig" || -L "$global_gitconfig" ]]; then
    _ws_owned_file_fingerprint "$global_gitconfig" || {
      _tk_error "Refusing unsafe global Git configuration file."
      return 1
    }
    gitconfig_fingerprint="$REPLY"
  fi
  if [[ -f "$ssh_config" ]]; then
    _ws_remove_ssh_marker_mode \
      "$ssh_config" "$begin_marker" "$end_marker" || {
      _tk_error \
        "SSH configuration contains incomplete or duplicate workspace markers."
      return 1
    }
    ssh_marker_mode="$REPLY"
  fi

  _tk_header "Remove Workspace: $ws"

  local -i repo_count=0
  local repo_dir=""
  for repo_dir in "$ws_dir"/*(DN/); do
    [[ "${repo_dir:t}" == ".ssh" ]] && continue
    _ws_validate_repo_dir "$ws_dir" "$repo_dir" && ((repo_count++))
  done
  (( repo_count > 0 )) \
    && _tk_warn "This workspace contains $repo_count repo(s)."

  _tk_info "Removal plan:"
  _tk_dim "Remove Host '$host_alias' from ~/.ssh/config."
  _tk_dim "Remove the exact includeIf entry from ~/.gitconfig."
  _tk_dim "Delete workspace directory: $ws_dir"
  _tk_warn "This operation cannot be undone."

  if (( dry_run )); then
    _tk_info "Dry run: no files were changed."
    return 0
  fi

  if (( ! assume_yes )); then
    [[ -t 0 && -t 2 ]] || {
      _tk_error \
        "Removal requires an interactive terminal; pass --yes after reviewing --dry-run."
      return 1
    }
    local confirm_name=""
    print -u2 -nr -- \
      "➜ Type the exact workspace name '$ws' to confirm: "
    IFS= read -r confirm_name
    print -u2 -r -- ""
    if [[ "$confirm_name" != "$ws" ]]; then
      _tk_info "Cancelled."
      return 0
    fi
  fi

  # Revalidate the target immediately before the first mutation.
  _ws_resolve_workspace "$ws" || return $?
  [[ "$REPLY" == "$ws_dir" ]] \
    && _ws_directory_fingerprint "$ws_dir" \
    && [[ "$REPLY" == "$workspace_fingerprint" ]] || {
    _tk_error "Workspace target changed after confirmation."
    return 1
  }

  if [[ "$ssh_config_fingerprint" != "absent" ]]; then
    _ws_owned_file_fingerprint "$ssh_config" \
      && [[ "$REPLY" == "$ssh_config_fingerprint" ]] || {
      _tk_error "SSH configuration changed after confirmation."
      return 1
    }
    _ws_remove_ssh_marker_mode \
      "$ssh_config" "$begin_marker" "$end_marker" || {
      _tk_error "SSH workspace markers changed after confirmation."
      return 1
    }
    [[ "$REPLY" == "$ssh_marker_mode" ]] || {
      _tk_error "SSH workspace marker layout changed after confirmation."
      return 1
    }
    local temp_config=""
    temp_config=$(mktemp "${ssh_config:h}/.zdx-ws-ssh.XXXXXX") || {
      _tk_error "Could not create a temporary SSH configuration."
      return 1
    }
    {
      if [[ "$ssh_marker_mode" == "markers" ]]; then
        awk -v begin="$begin_marker" -v end="$end_marker" '
          $0 == begin { skip=1; next }
          $0 == end { skip=0; next }
          !skip { print }
        ' "$ssh_config" > "$temp_config" || return 1
      else
        awk -v alias="Host ${host_alias}" \
            -v comment="# Workspace: ${platform}/${identity}" '
          BEGIN { skip=0; pending=0; saved="" }
          $0 == comment {
            if (pending) print saved
            pending=1
            saved=$0
            next
          }
          pending {
            if ($0 == alias) {
              pending=0
              saved=""
              skip=1
              next
            }
            print saved
            pending=0
            saved=""
          }
          !skip && $0 == alias { skip=1; next }
          skip && /^[[:space:]]*(Host|Match)[[:space:]]+/ { skip=0 }
          !skip { print }
          END {
            if (pending) print saved
          }
        ' "$ssh_config" > "$temp_config" || return 1
      fi
      command chmod 600 "$temp_config" || return 1
      _ws_owned_file_fingerprint "$ssh_config" \
        && [[ "$REPLY" == "$ssh_config_fingerprint" ]] || {
        _tk_error "SSH configuration changed while preparing the update."
        return 1
      }
      _ws_directory_fingerprint "$ws_dir" \
        && [[ "$REPLY" == "$workspace_fingerprint" ]] || {
        _tk_error "Workspace target changed while preparing the SSH update."
        return 1
      }
      command mv -- "$temp_config" "$ssh_config" || return 1
      temp_config=""
    } always {
      [[ -n "$temp_config" && -f "$temp_config" ]] \
        && command rm -f -- "$temp_config"
    }
    _tk_success "Removed Host '$host_alias' from ~/.ssh/config"
  fi

  if [[ "$gitconfig_fingerprint" != "absent" ]]; then
    local include_key="includeIf.gitdir:${ws_dir}/.path"
    local -i include_removed=0
    _ws_owned_file_fingerprint "$global_gitconfig" \
      && [[ "$REPLY" == "$gitconfig_fingerprint" ]] || {
      _tk_error "Global Git configuration changed after confirmation."
      return 1
    }
    local temp_gitconfig=""
    temp_gitconfig=$(mktemp "${global_gitconfig:h}/.zdx-ws-git.XXXXXX") || {
      _tk_error "Could not create a temporary Git configuration."
      return 1
    }
    {
      command cp -- "$global_gitconfig" "$temp_gitconfig" || return 1
      command chmod 600 "$temp_gitconfig" || return 1
      _ws_owned_file_fingerprint "$global_gitconfig" \
        && [[ "$REPLY" == "$gitconfig_fingerprint" ]] || {
        _tk_error "Global Git configuration changed while preparing the update."
        return 1
      }
      local -i include_query_rc=0
      command git config --file "$temp_gitconfig" \
        --get-all "$include_key" &>/dev/null || include_query_rc=$?
      case "$include_query_rc" in
        0)
          command git config --file "$temp_gitconfig" \
            --unset-all "$include_key" || {
            _tk_error "Could not remove includeIf from ~/.gitconfig"
            return 1
          }
          include_removed=1
          ;;
        1)
          ;;
        *)
          _tk_error \
            "Could not parse ~/.gitconfig safely; workspace removal was aborted."
          return 1
          ;;
      esac
      _ws_owned_file_fingerprint "$global_gitconfig" \
        && [[ "$REPLY" == "$gitconfig_fingerprint" ]] || {
        _tk_error "Global Git configuration changed before publication."
        return 1
      }
      _ws_directory_fingerprint "$ws_dir" \
        && [[ "$REPLY" == "$workspace_fingerprint" ]] || {
        _tk_error "Workspace target changed while preparing the Git update."
        return 1
      }
      command mv -- "$temp_gitconfig" "$global_gitconfig" || return 1
      temp_gitconfig=""
    } always {
      [[ -n "$temp_gitconfig" && -f "$temp_gitconfig" ]] \
        && command rm -f -- "$temp_gitconfig"
    }
    if (( include_removed )); then
      _tk_success "Removed includeIf from ~/.gitconfig"
    else
      _tk_dim "No matching includeIf entry was present in ~/.gitconfig"
    fi
  fi

  _ws_resolve_workspace "$ws" || return $?
  [[ "$REPLY" == "$ws_dir" ]] \
    && _ws_directory_fingerprint "$platform_dir" \
    && [[ "$REPLY" == "$platform_fingerprint" ]] \
    && _ws_directory_fingerprint "$ws_dir" \
    && [[ "$REPLY" == "$workspace_fingerprint" ]] || {
    _tk_error "Workspace target changed before deletion."
    return 1
  }

  local quarantine_dir="${platform_dir}/.${identity}.zdx-remove.$$.$RANDOM"
  [[ ! -e "$quarantine_dir" && ! -L "$quarantine_dir" ]] || {
    _tk_error "Could not allocate a private workspace removal target."
    return 1
  }
  command mv -- "$ws_dir" "$quarantine_dir" || {
    _tk_error "Could not isolate $ws_dir for deletion."
    return 1
  }
  if ! _ws_directory_fingerprint "$quarantine_dir" \
    || [[ "$REPLY" != "$workspace_fingerprint" ]]; then
    if [[ ! -e "$ws_dir" && ! -L "$ws_dir" ]]; then
      command mv -- "$quarantine_dir" "$ws_dir" 2>/dev/null || true
    fi
    _tk_error "Workspace identity changed during removal; nothing was deleted."
    return 1
  fi
  if ! command rm -rf -- "$quarantine_dir"; then
    if [[ -d "$quarantine_dir" && ! -L "$quarantine_dir" \
      && ! -e "$ws_dir" && ! -L "$ws_dir" ]] \
      && command mv -- "$quarantine_dir" "$ws_dir" 2>/dev/null; then
      _tk_error \
        "Workspace deletion failed; remaining data was restored to $ws_dir and may be incomplete."
    else
      _tk_error \
        "Workspace deletion failed partially; inspect ${(V)quarantine_dir} for remaining data."
    fi
    return 1
  fi
  _tk_success "Deleted $ws_dir"

  if [[ -d "$platform_dir" && ! -L "$platform_dir" \
    && "$platform_dir" == "${platform_dir:A}" \
    && -z "$(command ls -A -- "$platform_dir" 2>/dev/null)" ]]; then
    command rmdir -- "$platform_dir" \
      && _tk_dim "Removed empty platform directory: $platform/"
  fi

  _tk_success "Workspace $ws completely removed."
}


# =============================================================================
# MIGRATE EXISTING REPOS
# =============================================================================

ws-migrate() {
  emulate -L zsh

  local REPLY=""
  _ws_parse_no_args ws-migrate \
    "Interactively move direct-child repositories into a validated workspace." \
    "$@" || return 2
  [[ "$REPLY" == "help" ]] && return 0
  _tk_check_deps git ssh-keygen fzf || return 1
  _ws_migrate_interactive_available || {
    _tk_error "Repository migration requires an interactive terminal."
    return 1
  }

  _tk_header "Migrate Existing Repos"

  _tk_info "This will move repos from a source directory into a workspace."
  print -u2 -r -- ""

  # Pick source directory
  print -u2 -nr -- \
    "➜ Source directory (e.g. ~/github): "
  local source_dir=""
  read -r source_dir
  source_dir="${source_dir/#\~/$HOME}"

  [[ -n "$source_dir" && "$source_dir" == /* \
    && "$source_dir" != *$'\n'* && "$source_dir" != *$'\r'* \
    && "$source_dir" != *'|'* ]] || {
    _tk_error "The source directory must be a safe absolute path."
    return 2
  }
  source_dir="${source_dir:a}"
  [[ "$source_dir" != "/" && "$source_dir" != "${HOME:a}" \
    && -d "$source_dir" && ! -L "$source_dir" \
    && "$source_dir" == "${source_dir:A}" ]] || {
    _tk_error "Refusing unsafe source directory: ${(V)source_dir}"
    return 2
  }
  _ws_directory_fingerprint "$source_dir" || {
    _tk_error "Refusing an unsafe or foreign-owned source directory."
    return 1
  }
  local source_fingerprint="$REPLY"

  # Find repos in source
  local -a repos=()
  local -A allowed_repos=()
  local -A source_repo_fingerprints=()
  local r=""
  for r in "$source_dir"/*(DN/); do
    local repo_name="${r:t}"
    _ws_migrate_repo_name_valid "$repo_name" || continue
    _ws_repo_fingerprint "$source_dir" "$r" || continue
    repos+=("$repo_name")
    allowed_repos[$repo_name]=1
    source_repo_fingerprints[$repo_name]="$REPLY"
  done

  if (( ${#repos[@]} == 0 )); then
    _tk_warn "No git repos found in $source_dir"
    return 0
  fi

  _tk_info "Found ${#repos[@]} repo(s):"
  for r in "${repos[@]}"; do
    local remote=""
    if _ws_migrate_origin_url "$source_dir/$r"; then
      remote="${REPLY:-(no origin)}"
    else
      local -i inspect_rc=$?
      (( inspect_rc == 130 || inspect_rc == 143 )) && return "$inspect_rc"
      remote="(origin unavailable)"
    fi
    remote=$(_ws_redact_remote_url "$remote")
    print -u2 -r -- \
      "    • ${(V)r}  ${(V)remote}"
  done
  print -u2 -r -- ""

  # Pick target workspace
  _tk_info "Select target workspace:"
  local ws=""
  _ws_capture_workspace_selection "Migrate into" || return $?
  ws="$REPLY"
  if [[ -z "$ws" ]]; then
    _tk_info "Cancelled."
    return 0
  fi

  local platform="${ws%%/*}"
  local identity="${ws#*/}"
  _ws_resolve_workspace "$ws" || return $?
  local ws_dir="$REPLY"
  [[ -d "$ws_dir" && ! -L "$ws_dir" ]] || {
    _tk_error "Workspace not found: ${(V)ws}"
    return 1
  }
  _ws_directory_fingerprint "$ws_dir" || {
    _tk_error "Refusing an unsafe or foreign-owned target workspace."
    return 1
  }
  local target_fingerprint="$REPLY"
  [[ "${source_fingerprint%%:*}" == "${target_fingerprint%%:*}" ]] || {
    _tk_error \
      "Cross-filesystem migration is not supported; no repositories were moved."
    return 1
  }
  local host_alias=""
  host_alias=$(_tk_host_alias "$platform" "$identity")
  local hostname=""
  hostname=$(_tk_hostname "$platform" "$ws_dir")

  print -u2 -r -- ""
  _tk_info "Target: $ws_dir"
  _tk_info "SSH alias: $host_alias"
  print -u2 -r -- ""

  # Select which repos to migrate
  local selected_repos=""
  local -i fzf_rc=0
  _ws_fzf_capture -m \
    --height=40% --layout=reverse --border \
    --header="TAB to select | ENTER to confirm" \
    --prompt="Migrate repos > " \
    < <(printf "%s\n" "${repos[@]}") || fzf_rc=$?
  selected_repos="$REPLY"

  if (( fzf_rc != 0 )); then
    _ws_fzf_rc_is_cancel "$fzf_rc" && return 0
    _tk_error "Unable to select repositories (status $fzf_rc)."
    return 1
  fi
  if [[ -z "$selected_repos" ]]; then
    _tk_info "No repos selected."
    return 0
  fi

  local -a selected_repo_lines=("${(f)selected_repos}")
  local -i count=${#selected_repo_lines[@]}
  local selected_repo=""
  local -A selected_repo_seen=()
  for selected_repo in "${selected_repo_lines[@]}"; do
    [[ -n "$selected_repo" \
      && ${+allowed_repos[$selected_repo]} -eq 1 \
      && ${+selected_repo_seen[$selected_repo]} -eq 0 ]] || {
      _tk_error "The repository selection is invalid or duplicated."
      return 2
    }
    selected_repo_seen[$selected_repo]=1
  done
  print -u2 -r -- ""
  _tk_info "Will migrate $count repo(s) to $ws_dir"

  local update_remotes=false
  if _tk_confirm "Also update remote URLs to use alias '$host_alias'?"; then
    update_remotes=true
  fi

  if ! _tk_confirm "Proceed with migration?"; then
    _tk_info "Cancelled."
    return 0
  fi

  # Migrate repos (use for loop to avoid subshell)
  local repo=""
  local -i migration_failures=0
  for repo in ${(f)selected_repos}; do
    if (( ! ${+allowed_repos[$repo]} )); then
      _tk_error "Invalid repository selection: ${(V)repo}"
      return 2
    fi

    local src="$source_dir/$repo"
    local dst="$ws_dir/$repo"
    _ws_directory_fingerprint "$source_dir" \
      && [[ "$REPLY" == "$source_fingerprint" ]] \
      && _ws_directory_fingerprint "$ws_dir" \
      && [[ "$REPLY" == "$target_fingerprint" ]] \
      && _ws_repo_fingerprint "$source_dir" "$src" \
      && [[ "$REPLY" == "${source_repo_fingerprints[$repo]:-}" ]] || {
      _tk_error "Repository changed before migration: ${(V)src}"
      ((migration_failures++))
      continue
    }

    if [[ -e "$dst" || -L "$dst" ]]; then
      _tk_warn "Skipping $repo — already exists in target"
      continue
    fi

    _tk_info "Moving: $repo"
    if ! command mv -- "$src" "$dst"; then
      _tk_error "Failed to move $repo"
      ((migration_failures++))
      continue
    fi
    if ! _ws_repo_fingerprint "$ws_dir" "$dst" \
      || [[ "$REPLY" != "${source_repo_fingerprints[$repo]}" ]]; then
      _tk_error \
        "Moved ${(V)repo}, but its identity could not be verified in the target."
      ((migration_failures++))
      continue
    fi
    _ws_directory_fingerprint "$source_dir" \
      && source_fingerprint="$REPLY" || {
      _tk_error "Source directory changed after moving ${(V)repo}."
      ((migration_failures++))
      continue
    }
    _ws_directory_fingerprint "$ws_dir" \
      && target_fingerprint="$REPLY" || {
      _tk_error "Target workspace changed after moving ${(V)repo}."
      ((migration_failures++))
      continue
    }

    if [[ "$update_remotes" == "true" ]]; then
      _ws_repo_fingerprint "$ws_dir" "$dst" \
        && [[ "$REPLY" == "${source_repo_fingerprints[$repo]}" ]] || {
        _tk_error "Moved ${(V)repo}, but its target changed before remote inspection."
        ((migration_failures++))
        continue
      }
      local old_url=""
      if _ws_migrate_origin_url "$dst"; then
        old_url="$REPLY"
      else
        local -i inspect_rc=$?
        _tk_error "Moved ${(V)repo}, but could not inspect its origin."
        ((migration_failures++))
        if (( inspect_rc == 130 || inspect_rc == 143 )); then
          _tk_warn "Migration interrupted; remaining repositories were not attempted."
          return "$inspect_rc"
        fi
        continue
      fi
      if [[ -n "$old_url" ]]; then
        local owner_repo=""
        if _ws_clone_normalize_repo "$old_url"; then
          owner_repo="$REPLY"
          local new_url="git@${host_alias}:${owner_repo}.git"
          if ! _ws_repo_fingerprint "$ws_dir" "$dst" \
            || [[ "$REPLY" != "${source_repo_fingerprints[$repo]}" ]]; then
            _tk_error \
              "Moved ${(V)repo}, but its target changed before remote rewrite."
            ((migration_failures++))
            continue
          elif command git -C "$dst" remote set-url origin "$new_url" >&2; then
            local -i verify_rc=0
            _ws_migrate_origin_url "$dst" || verify_rc=$?
            if (( verify_rc != 0 )) || [[ "$REPLY" != "$new_url" ]]; then
              _tk_error "Moved ${(V)repo}, but could not verify its updated origin."
              ((migration_failures++))
              if (( verify_rc == 130 || verify_rc == 143 )); then
                _tk_warn "Migration interrupted; remaining repositories were not attempted."
                return "$verify_rc"
              fi
              continue
            fi
            _tk_dim "  Remote: $(_ws_redact_remote_url "$old_url") → $new_url"
          else
            local -i rewrite_rc=$?
            _tk_error "Moved $repo, but could not update its remote."
            ((migration_failures++))
            if (( rewrite_rc == 130 || rewrite_rc == 143 )); then
              _tk_warn "Migration interrupted; remaining repositories were not attempted."
              return "$rewrite_rc"
            fi
            continue
          fi
        else
          _tk_error \
            "Moved ${(V)repo}, but its origin is unsafe and was not rewritten."
          ((migration_failures++))
          continue
        fi
      fi
    fi

    _tk_success "Migrated $repo"
  done

  print -u2 -r -- ""
  if (( migration_failures == 0 )); then
    _tk_success "Migration complete!"
  else
    _tk_error \
      "Migration completed with $migration_failures partial failure(s)."
  fi

  # Check if source is now empty
  local remaining=0
  for r in "$source_dir"/*(DN/); do
    [[ -d "$r" ]] && remaining=$((remaining + 1))
  done

  if [[ $remaining -eq 0 ]]; then
    if _tk_confirm "Source directory $source_dir is now empty. Delete it?"; then
      command rmdir -- "$source_dir" 2>/dev/null \
        && _tk_success "Deleted $source_dir" \
        || _tk_warn "Could not delete $source_dir (not empty)"
    fi
  fi

  (( migration_failures == 0 ))
}

typeset -g _WS_DANGER_SOURCED=1
