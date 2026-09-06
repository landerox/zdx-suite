#!/usr/bin/env zsh
# =============================================================================
# WS Clone: clone repos and batch-clone via list, paste or GitHub org
# =============================================================================
#
# Loaded by ws-menu.zsh after ws-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_WS_CLONE_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_ws_clone_normalize_repo() {
  local input_repo="${1:-}"
  local repo_path="$input_repo"
  local component=""
  if [[ "$repo_path" == *://* || "$repo_path" == *@*:* ]]; then
    repo_path=$(_tk_extract_repo_path "$repo_path") || return 1
  fi

  [[ "$repo_path" != /* && "$repo_path" != */ ]] || return 1
  repo_path="${repo_path%.git}"

  [[ -n "$repo_path" && "$repo_path" == */* \
    && "$repo_path" != *//* \
    && "$repo_path" != /* && "$repo_path" != */ \
    && "$repo_path" != *$'\n'* && "$repo_path" != *$'\r'* \
    && "$repo_path" != *'|'* && "$repo_path" != -* ]] || return 1

  for component in ${(s:/:)repo_path}; do
    [[ -n "$component" && "$component" != "." && "$component" != ".." \
      && "$component" =~ '^[A-Za-z0-9._-]+$' ]] || return 1
  done

  REPLY="$repo_path"
}

_ws_clone_confirmation_available() {
  [[ -t 0 && -t 2 ]]
}

# Creating a clone child changes the directory link count, including when Git
# leaves an incomplete destination. Refresh that count only for the same owned
# directory object and mode reviewed before this invocation's clone attempt.
_ws_clone_refresh_workspace() {
  emulate -L zsh

  local workspace_name="$1" workspace_dir="$2" expected_fingerprint="$3"
  _ws_resolve_workspace "$workspace_name" || return 1
  [[ "$REPLY" == "$workspace_dir" ]] || return 1
  _ws_directory_fingerprint "$workspace_dir" || return 1
  [[ "${REPLY%:*}" == "${expected_fingerprint%:*}" ]]
}

ws-clone() {
  emulate -L zsh

  local REPLY=""
  _ws_parse_operands ws-clone 1 "[REPOSITORY]" \
    "Normalize one repository and clone it through the selected workspace alias." \
    "$@" || return 2
  [[ "$REPLY" == "help" ]] && return 0
  _tk_check_deps git ssh-keygen fzf || return 1

  local input_repo="${1:-}"

  # --- Parse input if provided as argument ---
  local parsed_repo=""
  local detected_platform=""

  if [[ -n "$input_repo" ]]; then
    # Extract owner/repo from any format
    if [[ "$input_repo" == http* || "$input_repo" == git@* ]]; then
      # Detect platform from URL/SSH
      if [[ "$input_repo" == *"github.com"* ]]; then
        detected_platform="github"
      elif [[ "$input_repo" == *"gitlab.com"* || "$input_repo" == *"gitlab"* ]]; then
        detected_platform="gitlab"
      fi
      _ws_clone_normalize_repo "$input_repo" || {
        _tk_error "Invalid repository operand."
        return 2
      }
      parsed_repo="$REPLY"
    else
      _ws_clone_normalize_repo "$input_repo" || {
        _tk_error "Invalid repository operand."
        return 2
      }
      parsed_repo="$REPLY"
    fi

    _tk_info "Repo: $parsed_repo"
  fi

  # --- Resolve workspace ---
  local ws=""
  # Try to auto-detect from current directory first
  local current_ws=""
  current_ws=$(_tk_detect_workspace)

  if [[ -n "$current_ws" ]]; then
    _tk_info "Detected workspace: $current_ws"
    if ! _ws_clone_confirmation_available; then
      ws="$current_ws"
    elif ! _tk_confirm "Clone into $current_ws?"; then
      _ws_capture_workspace_selection "Clone into" || return $?
      ws="$REPLY"
      [[ -z "$ws" ]] && return 0
    else
      ws="$current_ws"
    fi
  elif [[ -n "$detected_platform" ]]; then
    # Auto-match workspace from URL platform
    local matching_ws=()
    local all_ws=""
      all_ws=$(_tk_list_workspaces)
    local w=""
      for w in ${(f)all_ws}; do
      [[ "$w" == "${detected_platform}/"* ]] && matching_ws+=("$w")
    done

    if (( ${#matching_ws[@]} == 1 )); then
      ws="${matching_ws[1]}"
      _tk_info "Auto-selected workspace: $ws"
    elif (( ${#matching_ws[@]} > 1 )); then
      _tk_info "Multiple $detected_platform workspaces found:"
      local -i fzf_rc=0
      _ws_fzf_capture \
        --height=20% --layout=reverse --border \
        --prompt="Clone into > " \
        < <(printf "%s\n" "${matching_ws[@]}") || fzf_rc=$?
      ws="$REPLY"
      if (( fzf_rc != 0 )); then
        _ws_fzf_rc_is_cancel "$fzf_rc" && return 0
        _tk_error "Unable to select a workspace (status $fzf_rc)."
        return 1
      fi
      [[ -z "$ws" ]] && return 0
    else
      _ws_capture_workspace_selection "Clone into" || return $?
      ws="$REPLY"
      [[ -z "$ws" ]] && return 0
    fi
  else
    _ws_capture_workspace_selection "Clone into" || return $?
    ws="$REPLY"
    [[ -z "$ws" ]] && return 0
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
    _tk_error "Refusing an unsafe or foreign-owned workspace."
    return 1
  }
  local workspace_fingerprint="$REPLY"
  local host_alias=""
  host_alias=$(_tk_host_alias "$platform" "$identity")
  local hostname=""
  hostname=$(_tk_hostname "$platform" "$ws_dir")

  _tk_header "Clone into $ws"

  # --- Get repo path (interactive if not provided as argument) ---
  local repo_path=""
  if [[ -n "$parsed_repo" ]]; then
    repo_path="$parsed_repo"
  else
    _ws_clone_confirmation_available || {
      _tk_error "A repository operand is required outside an interactive terminal."
      return 2
    }
    print -u2 -r -- \
      "  Format: owner/repo (e.g. torvalds/linux)"
    print -u2 -r -- \
      "  Also accepts: full URL or git@host:owner/repo.git"
    print -u2 -r -- \
      "  Will clone as: git@${host_alias}:owner/repo.git"
    print -u2 -r -- ""
    print -u2 -nr -- \
      "➜ repo (owner/repo or URL): "
    local raw_input=""
      read -r raw_input

    if [[ -z "$raw_input" ]]; then
      _tk_info "Cancelled."
      return 0
    fi

    # Parse interactive input the same way
    if [[ "$raw_input" == http* || "$raw_input" == git@* ]]; then
      _ws_clone_normalize_repo "$raw_input" || {
        _tk_error "Invalid repository operand."
        return 2
      }
      repo_path="$REPLY"
    else
      _ws_clone_normalize_repo "$raw_input" || {
        _tk_error "Invalid repository operand."
        return 2
      }
      repo_path="$REPLY"
    fi
  fi

  # Final validation
  if ! _ws_clone_normalize_repo "$repo_path"; then
    _tk_error "Invalid format. Use owner/repo (e.g. torvalds/linux)"
    return 2
  fi
  repo_path="$REPLY"

  # Extract repo name for the directory (last segment)
  local repo_name="${repo_path##*/}"

  if [[ -e "$ws_dir/$repo_name" || -L "$ws_dir/$repo_name" ]]; then
    _tk_error "Directory '$repo_name' already exists in $ws_dir"
    return 1
  fi

  local clone_url="git@${host_alias}:${repo_path}.git"
  _tk_info "Cloning: $clone_url"
  print -u2 -r -- ""

  _ws_resolve_workspace "$ws" || return $?
  [[ "$REPLY" == "$ws_dir" ]] \
    && _ws_directory_fingerprint "$ws_dir" \
    && [[ "$REPLY" == "$workspace_fingerprint" ]] \
    && [[ ! -e "$ws_dir/$repo_name" && ! -L "$ws_dir/$repo_name" ]] || {
    _tk_error "Workspace or clone target changed before cloning."
    return 1
  }
  if git clone "$clone_url" "$ws_dir/$repo_name"; then
    _ws_clone_refresh_workspace "$ws" "$ws_dir" "$workspace_fingerprint" || {
      _tk_error "Workspace changed after cloning $repo_name; inspect the destination."
      return 1
    }
    _ws_validate_repo_dir "$ws_dir" "$ws_dir/$repo_name" || {
      _tk_error "Clone completed, but the destination failed validation."
      return 1
    }
    print -u2 -r -- ""
    _tk_success "Cloned into $ws_dir/$repo_name"

    # Verify git identity
    local effective_email=$(git -C "$ws_dir/$repo_name" config user.email 2>/dev/null)
    if [[ -n "$effective_email" ]]; then
      _tk_info "Git identity: $effective_email"
    fi

    if _ws_clone_confirmation_available \
      && _tk_confirm "cd into $ws_dir/$repo_name?"; then
      cd "$ws_dir/$repo_name" || { _tk_error "Could not cd into $ws_dir/$repo_name"; return 1; }
    fi
  else
    local -i clone_rc=$?
    if (( clone_rc == 130 || clone_rc == 143 )); then
      _tk_error "Clone interrupted (exit $clone_rc); inspect any partial destination before retrying."
      return "$clone_rc"
    fi
    _tk_error "Clone failed. Check your SSH key is added to $hostname"
    _tk_info "Use ws-show-key to inspect the validated public key."
    return 1
  fi
}


# =============================================================================
# BATCH CLONE INTO WORKSPACE
# =============================================================================

ws-clone-multi() {
  emulate -L zsh

  local REPLY=""
  _ws_parse_operands ws-clone-multi -1 "[REPOSITORY...]" \
    "Clone a reviewed repository list sequentially into one workspace." \
    "$@" || return 2
  [[ "$REPLY" == "help" ]] && return 0
  _tk_check_deps git ssh-keygen fzf || return 1

  local repo_urls=()

  # --- Collect repos: args or interactive ---
  if (( $# > 0 )); then
    # Mode: arguments
    repo_urls=("$@")
  else
    _ws_clone_confirmation_available || {
      _tk_error \
        "Repository operands are required outside an interactive terminal."
      return 2
    }
    # Mode: interactive — choose input method
    local methods=("Paste URLs (one per line)")
    _tk_check_cmd gh && methods+=("Fetch from GitHub org/user (gh)")

    local method=""
      local -i method_fzf_rc=0
    _ws_fzf_capture \
      --height=15% --layout=reverse --border \
      --prompt="Input method > " \
      < <(printf "%s\n" "${methods[@]}") || method_fzf_rc=$?
    method="$REPLY"
    if (( method_fzf_rc != 0 )); then
      _ws_fzf_rc_is_cancel "$method_fzf_rc" && return 0
      _tk_error "Unable to select an input method (status $method_fzf_rc)."
      return 1
    fi
    [[ -z "$method" ]] && { _tk_info "Cancelled."; return 0; }

    if [[ "$method" == "Paste URLs"* ]]; then
      # --- Paste mode ---
      _tk_info "Paste repo URLs (one per line). Empty line or Ctrl-D to finish."
      _tk_dim "Accepts: git@host:owner/repo.git | https://host/owner/repo | owner/repo"
      print -u2 -r -- ""
      local line=""
          while IFS= read -r line; do
        [[ -z "$line" ]] && break
        # Strip whitespace
        line="${line## }"
        line="${line%% }"
        [[ -n "$line" ]] && repo_urls+=("$line")
      done

    elif [[ "$method" == "Fetch from GitHub"* ]]; then
      # --- GH org/user mode ---
      _tk_check_gh || return 1
      print -u2 -nr -- "➜ GitHub org or username: "
      local gh_owner=""
          read -r gh_owner
      [[ -z "$gh_owner" ]] && { _tk_info "Cancelled."; return 0; }
      [[ "$gh_owner" =~ '^[A-Za-z0-9][A-Za-z0-9._-]*$' ]] || {
        _tk_error "Invalid GitHub organization or username."
        return 2
      }

      _tk_info "Fetching repos from $gh_owner..."
      local gh_repos=""
      gh_repos=$(gh repo list "$gh_owner" --limit 200 --json nameWithOwner,description \
        --template '{{range .}}{{.nameWithOwner}}{{"\t"}}{{.description}}{{"\n"}}{{end}}' 2>/dev/null)

      if [[ -z "$gh_repos" ]]; then
        _tk_error "No repos found for '$gh_owner' (or access denied)."
        return 1
      fi

      local -a gh_repo_lines=("${(f)gh_repos}")
      local -i repo_count=${#gh_repo_lines[@]}
      _tk_info "Found $repo_count repo(s). Select with TAB, confirm with ENTER."
      print -u2 -r -- ""

      local selected=""
      local -i repo_fzf_rc=0
      _ws_fzf_capture -m \
        --height=60% --layout=reverse --border \
        --delimiter="\t" \
        --with-nth=1,2 \
        --header="TAB to select | ENTER to confirm" \
        --prompt="Repos > " \
        < <(print -r -- "$gh_repos") || repo_fzf_rc=$?
      selected="$REPLY"

      if (( repo_fzf_rc != 0 )); then
        _ws_fzf_rc_is_cancel "$repo_fzf_rc" && return 0
        _tk_error "Unable to select repositories (status $repo_fzf_rc)."
        return 1
      fi
      [[ -z "$selected" ]] && { _tk_info "No repos selected."; return 0; }

      # Extract owner/repo from each selected line
      local sel_line=""
          for sel_line in ${(f)selected}; do
        local owner_repo="${sel_line%%	*}"
        [[ -n "$owner_repo" ]] && repo_urls+=("$owner_repo")
      done
    fi
  fi

  if (( ${#repo_urls[@]} == 0 )); then
    _tk_warn "No repos to clone."
    return 0
  fi

  # --- Parse all URLs into owner/repo format ---
  local -a parsed_repos=()
  local -A destination_sources=()
  local detected_platform=""
  local url=""
  for url in "${repo_urls[@]}"; do
    local repo_path=""
      if [[ "$url" == http* || "$url" == git@* ]]; then
      # Detect platform from first URL
      if [[ -z "$detected_platform" ]]; then
        [[ "$url" == *"github.com"* ]] && detected_platform="github"
        [[ "$url" == *"gitlab.com"* || "$url" == *"gitlab"* ]] && detected_platform="gitlab"
      fi
    fi

    if _ws_clone_normalize_repo "$url"; then
      repo_path="$REPLY"
      local destination_name="${repo_path##*/}"
      if (( ${+destination_sources[$destination_name]} )); then
        if [[ "${destination_sources[$destination_name]}" != "$repo_path" ]]; then
          _tk_error \
            "Repository operands collide on destination ${(V)destination_name}."
          return 2
        fi
        _tk_warn \
          "Ignoring duplicate repository operand ${(V)repo_path}."
        continue
      fi
      destination_sources[$destination_name]="$repo_path"
      parsed_repos+=("$repo_path")
    else
      _tk_warn "Skipping an invalid repository operand."
    fi
  done

  if (( ${#parsed_repos[@]} == 0 )); then
    _tk_error "No valid repos after parsing."
    return 1
  fi

  # --- Select workspace (once) ---
  local ws=""
  local current_ws=""
  current_ws=$(_tk_detect_workspace)

  if [[ -n "$current_ws" ]]; then
    _tk_info "Detected workspace: $current_ws"
    if ! _ws_clone_confirmation_available; then
      _tk_error \
        "Batch cloning requires an interactive confirmation; no repositories were cloned."
      return 1
    elif ! _tk_confirm "Clone ${#parsed_repos[@]} repo(s) into $current_ws?"; then
      _ws_capture_workspace_selection "Clone into" || return $?
      ws="$REPLY"
      [[ -z "$ws" ]] && return 0
    else
      ws="$current_ws"
    fi
  elif [[ -n "$detected_platform" ]]; then
    local matching_ws=()
    local all_ws=""
      all_ws=$(_tk_list_workspaces)
    local w=""
      for w in ${(f)all_ws}; do
      [[ "$w" == "${detected_platform}/"* ]] && matching_ws+=("$w")
    done

    if (( ${#matching_ws[@]} == 1 )); then
      ws="${matching_ws[1]}"
      _tk_info "Auto-selected workspace: $ws"
    elif (( ${#matching_ws[@]} > 1 )); then
      _tk_info "Multiple $detected_platform workspaces found:"
      local -i workspace_fzf_rc=0
      _ws_fzf_capture \
        --height=20% --layout=reverse --border \
        --prompt="Clone into > " \
        < <(printf "%s\n" "${matching_ws[@]}") || workspace_fzf_rc=$?
      ws="$REPLY"
      if (( workspace_fzf_rc != 0 )); then
        _ws_fzf_rc_is_cancel "$workspace_fzf_rc" && return 0
        _tk_error "Unable to select a workspace (status $workspace_fzf_rc)."
        return 1
      fi
      [[ -z "$ws" ]] && return 0
    else
      _ws_capture_workspace_selection "Clone into" || return $?
      ws="$REPLY"
      [[ -z "$ws" ]] && return 0
    fi
  else
    _ws_capture_workspace_selection "Clone into" || return $?
    ws="$REPLY"
    [[ -z "$ws" ]] && return 0
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
    _tk_error "Refusing an unsafe or foreign-owned workspace."
    return 1
  }
  local workspace_fingerprint="$REPLY"
  local host_alias=""
  host_alias=$(_tk_host_alias "$platform" "$identity")
  local hostname=""
  hostname=$(_tk_hostname "$platform" "$ws_dir")

  # --- Preview and confirm ---
  _tk_header "Batch Clone into $ws"
  _tk_info "${#parsed_repos[@]} repo(s) → $ws_dir"
  _tk_dim "SSH alias: $host_alias"
  print -u2 -r -- ""

  local rp=""
  for rp in "${parsed_repos[@]}"; do
    local rname="${rp##*/}"
    if [[ -e "$ws_dir/$rname" || -L "$ws_dir/$rname" ]]; then
      print -u2 -r -- \
        "    ⏭ ${(V)rp} (already exists — will skip)"
    else
      print -u2 -r -- "    ● ${(V)rp}"
    fi
  done
  print -u2 -r -- ""

  _ws_clone_confirmation_available || {
    _tk_error \
      "Batch cloning requires an interactive confirmation; no repositories were cloned."
    return 1
  }
  if ! _tk_confirm "Clone ${#parsed_repos[@]} repo(s)?"; then
    _tk_info "Cancelled."
    return 0
  fi

  # --- Clone loop ---
  local cloned=0 skipped=0 failed=0
  local -i item_index=0 not_run=0 interruption_rc=0 workspace_changed=0
  local -a failed_repos=()
  local -a cloned_dirs=()

  for rp in "${parsed_repos[@]}"; do
    (( item_index++ ))
    local rname="${rp##*/}"

    if [[ -e "$ws_dir/$rname" || -L "$ws_dir/$rname" ]]; then
      _tk_dim "⏭ Skipping $rname (already exists)"
      ((skipped++))
      continue
    fi

    local clone_url="git@${host_alias}:${rp}.git"
    _tk_info "Cloning: $rname"

    _ws_resolve_workspace "$ws" || {
      _tk_error "Workspace changed before cloning $rname."
      ((failed++))
      failed_repos+=("$rp")
      continue
    }
    if [[ "$REPLY" != "$ws_dir" ]] \
      || ! _ws_directory_fingerprint "$ws_dir" \
      || [[ "$REPLY" != "$workspace_fingerprint" ]] \
      || [[ -e "$ws_dir/$rname" || -L "$ws_dir/$rname" ]]; then
      _tk_error "Workspace or destination changed before cloning $rname."
      ((failed++))
      failed_repos+=("$rp")
      continue
    fi
    local clone_output=""
    local -i clone_rc=0
    clone_output=$(git clone "$clone_url" "$ws_dir/$rname" 2>&1) \
      || clone_rc=$?
    [[ -n "$clone_output" ]] \
      && print -u2 -r -- "${${(f)clone_output}[-1]}"

    if _ws_clone_refresh_workspace "$ws" "$ws_dir" "$workspace_fingerprint"; then
      workspace_fingerprint="$REPLY"
    else
      workspace_changed=1
      _tk_error "Workspace changed after cloning $rname; remaining repositories will not run."
    fi

    if (( clone_rc == 130 || clone_rc == 143 || workspace_changed )); then
      ((failed++))
      failed_repos+=("$rp")
      not_run=$(( ${#parsed_repos[@]} - item_index ))
      if (( clone_rc == 130 || clone_rc == 143 )); then
        interruption_rc=$clone_rc
        _tk_warn "Batch cloning interrupted (exit $clone_rc); remaining repositories will not run."
      fi
      break
    fi

    if (( clone_rc == 0 )) \
      && _ws_validate_repo_dir "$ws_dir" "$ws_dir/$rname"; then
      cloned_dirs+=("$REPLY")
      _tk_success "$rname"
      ((cloned++))
    else
      (( clone_rc == 0 )) && clone_rc=1
      _tk_error "Failed: $rname"
      if [[ -e "$ws_dir/$rname" || -L "$ws_dir/$rname" ]]; then
        _tk_info "Partial destination retained at $ws_dir/$rname; inspect it before retrying."
      fi
      failed_repos+=("$rp")
      ((failed++))
    fi
  done

  # --- Summary ---
  print -u2 -r -- ""
  print -u2 -r -- "────────────────────────────────────────"
  print -u2 -r -- "  Batch Clone Summary"
  print -u2 -r -- "────────────────────────────────────────"
  print -u2 -r -- ""
  _tk_label "Workspace" "$ws"
  _tk_label "Cloned"    "$cloned"
  [[ $skipped -gt 0 ]] && _tk_label "Skipped" "$skipped (already existed)"
  [[ $failed -gt 0 ]]  && _tk_label "Failed"  "$failed"
  (( not_run > 0 )) && _tk_label "Not run" "$not_run"
  print -u2 -r -- ""

  if (( failed > 0 )); then
    _tk_warn "Failed repos:"
    for rp in "${failed_repos[@]}"; do
      _tk_dim "  • $rp"
    done
    print -u2 -r -- ""
    if (( interruption_rc == 0 && ! workspace_changed )); then
      _tk_info "Check your SSH key is added to $hostname"
      _tk_info "Use ws-show-key to inspect the validated public key."
    fi
    print -u2 -r -- ""
  fi

  (( interruption_rc != 0 )) && return "$interruption_rc"
  (( workspace_changed )) && return 1

  # Verify git identity on first cloned repo
  if (( ${#cloned_dirs[@]} > 0 )); then
    local first_cloned_dir="${cloned_dirs[1]}"
    if _ws_validate_repo_dir "$ws_dir" "$first_cloned_dir"; then
      local effective_email=""
      effective_email=$(git -C "$REPLY" config user.email 2>/dev/null)
      [[ -n "$effective_email" ]] && _tk_info "Git identity: $effective_email"
    fi
  fi

  # Offer to cd into workspace
  if (( cloned > 0 )) && _ws_clone_confirmation_available \
    && _tk_confirm "cd into $ws_dir?"; then
    cd "$ws_dir" || { _tk_error "Could not cd into $ws_dir"; return 1; }
    _tk_success "You are now in $ws_dir"
  fi

  (( failed == 0 ))
}

typeset -g _WS_CLONE_SOURCED=1
