#!/usr/bin/env zsh
# =============================================================================
# WS Info: authenticate, list, inspect, and diagnose workspaces
# =============================================================================
#
# Loaded by ws-menu.zsh after ws-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_WS_INFO_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# --- Authentication status -------------------------------------------------

ws-auth() {
  local REPLY=""
  _ws_parse_no_args ws-auth \
    "Check key presence, GitHub CLI authentication, and each workspace SSH route." \
    "$@" || return 2
  [[ "$REPLY" == "help" ]] && return 0
  _ws_check_deps git ssh-keygen ssh || return 1

  _ws_validate_base_dir || return $?
  _ws_header "Authentication Status"

  local workspaces=""
  workspaces=$(_ws_list_workspaces) || return $?
  if [[ -z "$workspaces" ]]; then
    _ws_warn "No workspaces found."
    return 0
  fi

  printf '%-22s %-18s %-12s %-14s %-10s\n' \
    "WORKSPACE" "HOST" "SSH KEY" "GH CLI" "SSH TEST" >&2
  printf '%-22s %-18s %-12s %-14s %-10s\n' \
    "----------------------" "------------------" "------------" \
    "--------------" "----------" >&2

  local -i overall_rc=0
  local workspace_name=""
  for workspace_name in ${(f)workspaces}; do
    REPLY=""
    _ws_resolve_workspace "$workspace_name" || return $?
    local workspace_dir="$REPLY"
    [[ -d "$workspace_dir" && ! -L "$workspace_dir" ]] || {
      _ws_error "Workspace changed during authentication inspection."
      return 1
    }

    local platform="${workspace_name%%/*}"
    local identity="${workspace_name#*/}"
    local host_alias=""
      host_alias=$(_tk_host_alias "$platform" "$identity")
    local hostname=""
      hostname=$(_tk_hostname "$platform" "$workspace_dir")

    local key_state="missing"
    [[ -f "$workspace_dir/.ssh/id_ed25519" \
      && ! -L "$workspace_dir/.ssh/id_ed25519" ]] \
      && key_state="present"

    local gh_state="unavailable"
    if _ws_check_cmd gh; then
      command gh auth status --hostname "$hostname" &>/dev/null \
        && gh_state="authenticated" \
        || gh_state="not authenticated"
    fi

    local ssh_state="failed"
    local -i ssh_probe_rc=0
    _ws_ssh_probe "$host_alias" 3 5 || ssh_probe_rc=$?
    case "$ssh_probe_rc" in
      0)
        ssh_state="accepted"
        ;;
      124)
        ssh_state="timed out"
        overall_rc=124
        ;;
      *)
        (( overall_rc == 0 )) && overall_rc=1
        ;;
    esac

    printf '%-22s %-18s %-12s %-14s %-10s\n' \
      "$workspace_name" "$hostname" "$key_state" "$gh_state" "$ssh_state" >&2
  done

  _ws_blank
  _ws_dim "SSH test uses batch mode and a bounded connection attempt."
  _ws_dim "GitHub CLI status is checked independently for each hostname."
  return $overall_rc
}

ws-list() {
  local REPLY=""
  _ws_parse_no_args ws-list \
    "Display configured workspaces, identities, repository counts, and key state." \
    "$@" || return 2
  [[ "$REPLY" == "help" ]] && return 0
  _tk_check_deps git ssh-keygen fzf || return 1

  _ws_validate_base_dir || return $?

  _tk_header "Workspaces"

  local workspaces=""
  workspaces=$(_tk_list_workspaces)

  if [[ -z "$workspaces" ]]; then
    _tk_warn "No workspaces found in $WS_BASE_DIR"
    _tk_info "Create one with: ws-create"
    return 0
  fi

  # Table header
  printf "%-24s %-20s %-30s %-8s %-12s\n" \
    "WORKSPACE" "HOST" "EMAIL" "REPOS" "KEY" >&2
  printf "%-24s %-20s %-30s %-8s %-12s\n" \
    "────────────────────────" "────────────────────" \
    "──────────────────────────────" "────────" "────────────" >&2

  local ws=""
  for ws in ${(f)workspaces}; do
    local platform="${ws%%/*}"
    local identity="${ws#*/}"
    REPLY=""
    _ws_resolve_workspace "$ws" || return $?
    local ws_dir="$REPLY"

    # Get hostname
    local hostname=""
    hostname=$(_tk_hostname "$platform" "$ws_dir")

    # Get email
    local email="-"
    if [[ -f "$ws_dir/.gitconfig" ]]; then
      email=$(git config --file "$ws_dir/.gitconfig" user.email 2>/dev/null)
      [[ -z "$email" ]] && email="-"
    fi

    # Count repos
    local repo_count=0
    for r in "$ws_dir"/*(DN/); do
      [[ "${r:t}" == ".ssh" ]] && continue
      _ws_validate_repo_dir "$ws_dir" "$r" \
        && repo_count=$((repo_count + 1))
    done

    # Key status
    local key_status="✘ none"
    if [[ -f "$ws_dir/.ssh/id_ed25519" ]]; then
      key_status="✔ ed25519"
    fi

    # GH CLI status for this host
    local gh_col="\u2014"
    if _tk_check_cmd gh; then
      if gh auth status --hostname "$hostname" &>/dev/null; then
        local gh_acct=""
        local gh_out=""
        gh_out=$(gh auth status --hostname "$hostname" 2>&1)
        if [[ "$gh_out" =~ 'as ([^ ]+)' ]]; then
          gh_acct="${match[1]}"
        fi
        gh_col="\u2714 ${gh_acct:-ok}"
      else
        gh_col="\u2718 none"
      fi
    fi

    printf "%-24s %-20s %-30s %-8s %-12s %-14s\n" \
      "${(V)ws}" "${(V)hostname}" "${(V)email}" "$repo_count" \
      "$key_status" "${(V)gh_col}" >&2
  done
  print -u2 -r -- ""
}


# =============================================================================
# WORKSPACE INFO
# =============================================================================

ws-info() {
  local REPLY=""
  _ws_parse_no_args ws-info \
    "Select one workspace and display its identity, key, routing, and repositories." \
    "$@" || return 2
  [[ "$REPLY" == "help" ]] && return 0
  _tk_check_deps git ssh-keygen fzf || return 1

  local ws=""
  _ws_capture_workspace_selection "Show info for" || return $?
  ws="$REPLY"
  [[ -z "$ws" ]] && return 0

  local REPLY=""
  _ws_resolve_workspace "$ws" || return $?
  local ws_dir="$REPLY"
  [[ -d "$ws_dir" && ! -L "$ws_dir" ]] || {
    _ws_error "Workspace does not exist: $ws"
    return 1
  }

  local platform="${ws%%/*}"
  local identity="${ws#*/}"
  local hostname=""
  hostname=$(_tk_hostname "$platform" "$ws_dir")
  local host_alias=""
  host_alias=$(_tk_host_alias "$platform" "$identity")

  _tk_header "Workspace: $ws"

  print -u2 -r -- "  Directory:  ${(V)ws_dir}"
  print -u2 -r -- "  Platform:   ${(V)platform}"
  print -u2 -r -- "  Hostname:   ${(V)hostname}"
  print -u2 -r -- "  SSH Alias:  ${(V)host_alias}"
  print -u2 -r -- ""

  # Git identity
  if [[ -f "$ws_dir/.gitconfig" ]]; then
    local name=$(git config --file "$ws_dir/.gitconfig" user.name 2>/dev/null)
    local email=$(git config --file "$ws_dir/.gitconfig" user.email 2>/dev/null)
    local signingkey=$(git config --file "$ws_dir/.gitconfig" user.signingkey 2>/dev/null)
    local gpgsign=$(git config --file "$ws_dir/.gitconfig" commit.gpgSign 2>/dev/null)
    print -u2 -r -- "  👤 Git Identity:"
    print -u2 -r -- "     Name:  ${(V)name}"
    print -u2 -r -- "     Email: ${(V)email}"
    if [[ -n "$signingkey" ]]; then
      print -u2 -r -- \
        "     GPG Key: ${(V)signingkey} (signing: ${(V)${gpgsign:-false}})"
    fi
  fi
  print -u2 -r -- ""

  # SSH Key
  print -u2 -r -- "  🔑 SSH Key:"
  if [[ -f "$ws_dir/.ssh/id_ed25519" ]]; then
    local fingerprint=$(ssh-keygen -lf "$ws_dir/.ssh/id_ed25519.pub" 2>/dev/null)
    print -u2 -r -- "     Path:        ${(V)ws_dir}/.ssh/id_ed25519"
    print -u2 -r -- "     Fingerprint: ${(V)fingerprint}"
    local perms=""
    perms=$(_tk_file_perms "$ws_dir/.ssh/id_ed25519")
    if [[ "$perms" == "600" ]]; then
      print -u2 -r -- "     Permissions: $perms (correct)"
    else
      print -u2 -r -- "     Permissions: $perms (should be 600!)"
    fi
  else
    print -u2 -r -- "     (no key found)"
  fi
  print -u2 -r -- ""

  # SSH config check
  print -u2 -r -- "  ⚙️  SSH Config:"
  if command grep -Fqx -- "Host ${host_alias}" \
    "$HOME/.ssh/config" 2>/dev/null; then
    print -u2 -r -- "     ✔ Host '$host_alias' found in ~/.ssh/config"
  else
    print -u2 -r -- "     ✘ Host '$host_alias' NOT found in ~/.ssh/config"
  fi

  # includeIf check
  if command git config --global --get-all \
    "includeIf.gitdir:${ws_dir}/.path" &>/dev/null; then
    print -u2 -r -- "     ✔ includeIf found in ~/.gitconfig"
  else
    print -u2 -r -- "     ✘ includeIf NOT found in ~/.gitconfig"
  fi
  print -u2 -r -- ""

  # Repos
  print -u2 -r -- "  📦 Repositories:"
  local repo_count=0
  for r in "$ws_dir"/*(DN/); do
    [[ "${r:t}" == ".ssh" ]] && continue
    if _ws_validate_repo_dir "$ws_dir" "$r"; then
      local safe_repo_dir="$REPLY"
      local remote=""
      remote=$(git -C "$safe_repo_dir" remote get-url origin 2>/dev/null) \
        || remote="(no remote)"
      remote=$(_ws_redact_remote_url "$remote")
      print -u2 -r -- \
        "     • ${(V)${safe_repo_dir:t}}  ${(V)remote}"
      repo_count=$((repo_count + 1))
    fi
  done
  [[ $repo_count -eq 0 ]] && print -u2 -r -- "     (none)"
  print -u2 -r -- ""

  # Clone hint
  print -u2 -r -- "  Clone command:"
  print -u2 -r -- "    git clone git@${host_alias}:owner/repo.git"
  print -u2 -r -- ""
}
# =============================================================================
# WORKSPACE DOCTOR
# =============================================================================

ws-doctor() {
  local REPLY=""
  _ws_parse_no_args ws-doctor \
    "Diagnose workspace files, permissions, SSH aliases, Git includes, and remotes." \
    "$@" || return 2
  [[ "$REPLY" == "help" ]] && return 0
  _tk_check_deps git ssh-keygen fzf || return 1

  _ws_validate_base_dir || return $?

  _tk_header "Workspace Doctor"

  local workspaces=""
  workspaces=$(_tk_list_workspaces)

  if [[ -z "$workspaces" ]]; then
    _tk_warn "No workspaces found."
    return 0
  fi

  local total_issues=0

  local ws=""
  for ws in ${(f)workspaces}; do
    REPLY=""
    _ws_resolve_workspace "$ws" || return $?
    local ws_dir="$REPLY"
    [[ -d "$ws_dir" && ! -L "$ws_dir" ]] || {
      _ws_error "Workspace changed during diagnostics: $ws"
      return 1
    }

    local platform="${ws%%/*}"
    local identity="${ws#*/}"
    local host_alias=""
    host_alias=$(_tk_host_alias "$platform" "$identity")

    print -u2 -r -- "🔍 Checking: ${(V)ws}"

    # Check .gitconfig exists
    if [[ -f "$ws_dir/.gitconfig" ]]; then
      _tk_dim "✔ .gitconfig exists"
    else
      _tk_error "  ✘ Missing .gitconfig in $ws_dir"
      ((total_issues++))
    fi

    # Check SSH key exists
    if [[ -f "$ws_dir/.ssh/id_ed25519" ]]; then
      _tk_dim "✔ SSH key exists"

      # Check permissions
      local perms=""
      perms=$(_tk_file_perms "$ws_dir/.ssh/id_ed25519")
      if [[ "$perms" == "600" ]]; then
        _tk_dim "✔ Key permissions correct (600)"
      else
        _tk_error "  ✘ Key permissions are $perms (should be 600)"
        _tk_info "  Fix: chmod 600 $ws_dir/.ssh/id_ed25519"
        ((total_issues++))
      fi

      # Check .ssh dir permissions
      local dir_perms=""
      dir_perms=$(_tk_file_perms "$ws_dir/.ssh")
      if [[ "$dir_perms" == "700" ]]; then
        _tk_dim "✔ .ssh/ permissions correct (700)"
      else
        _tk_error "  ✘ .ssh/ permissions are $dir_perms (should be 700)"
        _tk_info "  Fix: chmod 700 $ws_dir/.ssh"
        ((total_issues++))
      fi
    else
      _tk_error "  ✘ Missing SSH key in $ws_dir/.ssh/"
      ((total_issues++))
    fi

    # Check ~/.ssh/config entry
    if command grep -Fqx -- "Host ${host_alias}" \
      "$HOME/.ssh/config" 2>/dev/null; then
      _tk_dim "✔ Host '$host_alias' in ~/.ssh/config"
    else
      _tk_error "  ✘ Host '$host_alias' missing from ~/.ssh/config"
      ((total_issues++))
    fi

    # Check includeIf
    if command git config --global --get-all \
      "includeIf.gitdir:${ws_dir}/.path" &>/dev/null; then
      _tk_dim "✔ includeIf in ~/.gitconfig"
    else
      _tk_error "  ✘ includeIf missing for $ws_dir/ in ~/.gitconfig"
      ((total_issues++))
    fi

    # Check repos have correct remote alias
    for r in "$ws_dir"/*(DN/); do
      [[ "${r:t}" == ".ssh" ]] && continue
      if _ws_validate_repo_dir "$ws_dir" "$r"; then
        local safe_repo_dir="$REPLY"
        local remote_url=""
        remote_url=$(git -C "$safe_repo_dir" remote get-url origin \
          2>/dev/null) \
          || remote_url=""
        if [[ -n "$remote_url" ]]; then
          if [[ "$remote_url" == *"git@${host_alias}:"* ]]; then
            _tk_dim "✔ ${safe_repo_dir:t} remote uses correct alias"
          else
            _tk_warn "  ⚠ ${safe_repo_dir:t} remote doesn't use alias '$host_alias'"
            _tk_dim "  Current:  $(_ws_redact_remote_url "$remote_url")"
            _tk_dim "  Expected: git@${host_alias}:..."
          fi
        fi
      fi
    done

    print -u2 -r -- ""
  done

  if [[ $total_issues -eq 0 ]]; then
    _tk_success "All workspaces healthy! No issues found."
  else
    _tk_warn "$total_issues issue(s) found. Review and fix above."
  fi
}

typeset -g _WS_INFO_SOURCED=1
