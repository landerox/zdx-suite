#!/usr/bin/env zsh
# =============================================================================
# System Update Git: owned checkouts for fzf, Oh My Zsh, and Zsh plugins
# =============================================================================
#
# Loaded by sys-menu.zsh after sys-common.zsh and the platform adapters.
# Safe to re-source; defines functions only.
#

if [[ -n "${_SYS_UPDATE_GIT_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_sys_update_counted_noun() {
  local count="${1:-}" singular="${2:-}" plural="${3:-}"
  [[ "$count" == <-> && -n "$singular" && -n "$plural" ]] || return 2
  if (( count == 1 )); then
    REPLY="$singular"
  else
    REPLY="$plural"
  fi
}

# Validate an existing path below an owner-bound trust root. The trust root and
# every child component must be owned by the current user and must not be a
# symbolic link. Set REPLY to the canonical candidate path on success.
_sys_update_validate_owned_path() {
  local allowed_root="${1:-}"
  local candidate_path="${2:-}"
  local expected_type="${3:-directory}"
  [[ -n "$allowed_root" && -n "$candidate_path" \
    && "$allowed_root" == /* && "$candidate_path" == /* \
    && "$allowed_root" != *[[:cntrl:]]* \
    && "$candidate_path" != *[[:cntrl:]]* \
    && ( "$expected_type" == "directory" \
      || "$expected_type" == "file" ) ]] || return 2

  local root_lexical="${allowed_root:a}"
  local candidate_lexical="${candidate_path:a}"
  [[ -d "$root_lexical" && ! -L "$root_lexical" \
    && -O "$root_lexical" && "${root_lexical:A}" == "$root_lexical" \
    && "$candidate_lexical" == "$root_lexical"/* ]] || return 1

  local relative_path="${candidate_lexical#$root_lexical/}"
  local -a path_components=("${(@s:/:)relative_path}")
  (( ${#path_components[@]} > 0 )) || return 1

  local component current_path="$root_lexical"
  for component in "${path_components[@]}"; do
    [[ -n "$component" && "$component" != "." \
      && "$component" != ".." ]] || return 1
    current_path+="/$component"
    [[ -e "$current_path" || -L "$current_path" ]] || return 1
    [[ ! -L "$current_path" && -O "$current_path" ]] || return 1
  done

  case "$expected_type" in
    directory) [[ -d "$candidate_lexical" ]] || return 1 ;;
    file)      [[ -f "$candidate_lexical" ]] || return 1 ;;
  esac
  REPLY="${candidate_lexical:A}"
}

# Keep caller-provided Git routing variables from redirecting validation or
# mutation away from the repository passed with -C.
_sys_update_git_read() {
  (
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
    unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR
    unset GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
    _sys_run_bounded_probe 10 1048576 git "$@"
  )
}

# Usage: _sys_update_git_logged <git arguments...>
_sys_update_git_logged() {
  local REPLY display=""
  if (( ${+functions[_zdx_ui_command_display]} )); then
    _zdx_ui_command_display git "$@"
    display="$REPLY"
  else
    display="git ${(j: :)@}"
  fi
  (
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
    unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR
    unset GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
    # A remote Git transaction must fail visibly instead of stalling the
    # aggregate on a credential prompt, an askpass dialog, or a dead peer.
    export GIT_TERMINAL_PROMPT=0
    # An empty GIT_ASKPASS disables askpass; unsetting it would let Git fall
    # back to core.askPass and then SSH_ASKPASS.
    export GIT_ASKPASS=''
    unset SSH_ASKPASS
    [[ -n "${GIT_SSH_COMMAND:-}" ]] || export GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4'
    # Git aborts its own transfer below 1 KiB/s for 60s. This bounds a
    # stalled download without wrapping the mutating command in an external
    # watchdog that could return while the transaction continues.
    export GIT_CONFIG_COUNT=2
    export GIT_CONFIG_KEY_0=http.lowSpeedLimit GIT_CONFIG_VALUE_0=1024
    export GIT_CONFIG_KEY_1=http.lowSpeedTime GIT_CONFIG_VALUE_1=60
    _sys_run_logged "$display" git "$@"
  )
}

# REPLY: "updated" or "current" for one checkout; reply=(detail).
# Usage: _sys_update_git_change <repository> <before-head> <after-head>
_sys_update_git_change() {
  local repository="${1:-}" before="${2:-}" after="${3:-}" count_output=""
  if [[ -n "$after" && "$after" != "$before" ]]; then
    local detail="${before[1,7]} → ${after[1,7]}"
    if count_output=$(_sys_update_git_read -C "$repository" \
      rev-list --count "$before..$after" 2>/dev/null) \
      && [[ "$count_output" == <-> ]]; then
      _sys_count_noun "$count_output" commit
      detail+=" · $REPLY"
    fi
    reply=("$detail")
    REPLY=updated
  else
    reply=("${before[1,7]}")
    REPLY=current
  fi
}

# Resolve the active ZDX checkout from the core's source-derived functions
# directory. This path is used only to recognize the installer's exact local
# development link; it never authorizes a Git mutation through that link.
_sys_update_active_zdx_checkout_root() {
  local functions_dir="${_ZDX_FUNCTIONS_DIR:-}"
  [[ -n "$functions_dir" \
    && "$functions_dir" == /* \
    && "$functions_dir" != *[[:cntrl:]]* ]] || return 1

  _sys_update_validate_owned_path \
    "$HOME" "$functions_dir" directory || return 1
  local functions_dir_abs="$REPLY"
  local checkout_root="${functions_dir_abs:h}"
  [[ "$functions_dir_abs" == "$checkout_root/functions" ]] || return 1

  _sys_update_validate_owned_path \
    "$HOME" "$checkout_root" directory || return 1
  checkout_root="$REPLY"

  local marker_file
  for marker_file in functions.zsh zdx-suite.plugin.zsh; do
    _sys_update_validate_owned_path \
      "$checkout_root" "$checkout_root/$marker_file" file || return 1
  done
  _sys_update_validate_owned_path \
    "$checkout_root" "$checkout_root/.git" directory || return 1

  REPLY="$checkout_root"
}

# Recognize only the local installer's exact plugins/zdx-suite symlink when it
# resolves to the active, owner-bound ZDX checkout. All other symlinks continue
# through the generic Git validator and fail closed.
_sys_update_linked_zdx_checkout() {
  local custom_dir="${1:-}"
  local repository="${2:-}"
  [[ -n "$custom_dir" && -n "$repository" \
    && "$custom_dir" == /* && "$repository" == /* \
    && "$custom_dir" != *[[:cntrl:]]* \
    && "$repository" != *[[:cntrl:]]* ]] || return 1

  _sys_update_validate_owned_path \
    "$HOME" "$custom_dir" directory || return 1
  local custom_dir_abs="$REPLY"
  local plugins_dir="$custom_dir_abs/plugins"
  _sys_update_validate_owned_path \
    "$custom_dir_abs" "$plugins_dir" directory || return 1
  plugins_dir="$REPLY"

  local expected_link="$plugins_dir/zdx-suite"
  [[ "${repository:a}" == "$expected_link" && -L "$expected_link" ]] \
    || return 1

  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local -A link_before=() link_after=()
  zstat -L -H link_before -- "$expected_link" 2>/dev/null || return 1
  local raw_target="${link_before[link]:-}"
  [[ -n "${link_before[device]:-}" \
    && -n "${link_before[inode]:-}" \
    && -n "$raw_target" \
    && "$raw_target" != *[[:cntrl:]]* ]] || return 1
  (( link_before[uid] == EUID \
    && link_before[nlink] == 1 \
    && link_before[size] > 0 \
    && link_before[size] <= 4096 )) || return 1

  _sys_update_active_zdx_checkout_root || return 1
  local checkout_root="$REPLY"
  [[ "${expected_link:A}" == "$checkout_root" ]] || return 1

  zstat -L -H link_after -- "$expected_link" 2>/dev/null || return 1
  [[ -L "$expected_link" \
    && "${link_after[device]}:${link_after[inode]}:${link_after[size]}:${link_after[mtime]}:${link_after[ctime]}:${link_after[mode]}:${link_after[uid]}:${link_after[nlink]}" \
    == "${link_before[device]}:${link_before[inode]}:${link_before[size]}:${link_before[mtime]}:${link_before[ctime]}:${link_before[mode]}:${link_before[uid]}:${link_before[nlink]}" \
    && "${link_after[link]:-}" == "$raw_target" \
    && "${expected_link:A}" == "$checkout_root" ]] \
    || return 1

  REPLY="$checkout_root"
}

# Capture the complete authorization identity for a user-owned Git checkout.
# reply contains: path, origin, HEAD, repo device/inode, .git device/inode.
_sys_update_git_fingerprint() {
  setopt LOCAL_OPTIONS EXTENDED_GLOB
  local allowed_root="${1:-}"
  local repository="${2:-}"

  _sys_update_validate_owned_path \
    "$allowed_root" "$repository" directory || {
      _sys_error "Git checkout is not an owned, symlink-free child of HOME: $(_sys_display_escape "$repository")"
      return 1
    }
  local repository_abs="$REPLY"
  [[ "$repository_abs" != "${allowed_root:A}" ]] || return 1

  _sys_update_validate_owned_path \
    "$repository_abs" "$repository_abs/.git" directory || {
      _sys_error "Git metadata is not an owned, symlink-free directory: $(_sys_display_escape "$repository_abs/.git")"
      _sys_dim "Linked worktrees and .git indirection files are not supported."
      return 1
    }
  local git_dir_abs="$REPLY"

  local repository_top origin origin_record current_commit
  repository_top=$(_sys_update_git_read -C "$repository_abs" \
    rev-parse --show-toplevel 2>/dev/null) || {
      _sys_error "Unable to verify Git checkout: $(_sys_display_escape "$repository_abs")"
      return 1
    }
  [[ -n "$repository_top" \
    && "$repository_top" != *[[:cntrl:]]* \
    && "${repository_top:A}" == "$repository_abs" ]] || {
      _sys_error "Git checkout root does not match its authorized path: $(_sys_display_escape "$repository_abs")"
      return 1
    }

  origin_record=$(_sys_update_git_read -C "$repository_abs" \
    config --local --null --get-all remote.origin.url 2>/dev/null) || {
      _sys_error "Git checkout has no readable origin: $(_sys_display_escape "$repository_abs")"
      return 1
    }
  [[ "$origin_record" == *$'\0' ]] || return 1
  origin="${origin_record%$'\0'}"
  [[ -n "$origin" && ${#origin} -le 2048 \
    && "$origin" != *[[:cntrl:]]* \
    && "$origin" != *$'\0'* ]] || {
      _sys_error "Git checkout origin is empty or contains unsafe control data: $(_sys_display_escape "$repository_abs")"
      return 1
    }

  current_commit=$(_sys_update_git_read -C "$repository_abs" \
    rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || {
      _sys_error "Git checkout has no verifiable HEAD commit: $(_sys_display_escape "$repository_abs")"
      return 1
    }
  (( ${#current_commit} == 40 || ${#current_commit} == 64 )) \
    && [[ "$current_commit" == [[:xdigit:]]## ]] || {
      _sys_error "Git checkout returned an invalid HEAD identifier: $(_sys_display_escape "$repository_abs")"
      return 1
    }
  current_commit="${current_commit:l}"

  local -A repository_state=() git_dir_state=()
  zmodload -F zsh/stat b:zstat 2>/dev/null \
    && zstat -H repository_state "$repository_abs" 2>/dev/null \
    && zstat -H git_dir_state "$git_dir_abs" 2>/dev/null || {
      _sys_error "Unable to fingerprint Git checkout metadata: $(_sys_display_escape "$repository_abs")"
      return 1
    }
  [[ -n "${repository_state[device]:-}" \
    && -n "${repository_state[inode]:-}" \
    && -n "${git_dir_state[device]:-}" \
    && -n "${git_dir_state[inode]:-}" ]] || return 1

  reply=(
    "$repository_abs"
    "$origin"
    "$current_commit"
    "${repository_state[device]}"
    "${repository_state[inode]}"
    "${git_dir_state[device]}"
    "${git_dir_state[inode]}"
  )
  REPLY="${repository_state[device]}:${repository_state[inode]}:${git_dir_state[device]}:${git_dir_state[inode]}:${#origin}:$origin:$current_commit"
}

# Revalidate the exact Git identity authorized by the displayed update plan.
_sys_update_git_revalidate() {
  local allowed_root="${1:-}"
  local repository="${2:-}"
  local expected_fingerprint="${3:-}"
  [[ -n "$expected_fingerprint" ]] || return 2

  _sys_update_git_fingerprint "$allowed_root" "$repository" || return 1
  [[ "$REPLY" == "$expected_fingerprint" ]] || {
    _sys_error "Git checkout changed after authorization: $(_sys_display_escape "$repository")"
    return 1
  }
}

# After a successful pull, HEAD may advance but the repository and origin must
# retain the stable identity that was authorized.
_sys_update_git_revalidate_stable() {
  local allowed_root="${1:-}"
  local repository="${2:-}"
  local expected_path="${3:-}"
  local expected_origin="${4:-}"
  local expected_repo_device="${5:-}"
  local expected_repo_inode="${6:-}"
  local expected_git_device="${7:-}"
  local expected_git_inode="${8:-}"

  _sys_update_git_fingerprint "$allowed_root" "$repository" || return 1
  [[ "${reply[1]}" == "$expected_path" \
    && "${reply[2]}" == "$expected_origin" \
    && "${reply[4]}" == "$expected_repo_device" \
    && "${reply[5]}" == "$expected_repo_inode" \
    && "${reply[6]}" == "$expected_git_device" \
    && "${reply[7]}" == "$expected_git_inode" ]] || {
      _sys_error "Git checkout identity or origin changed during update: $(_sys_display_escape "$repository")"
      return 1
    }
}

# Validate that fzf's installer is an owner-bound, single-link executable whose
# content exactly matches the installer blob in the authorized HEAD.
_sys_update_fzf_install_fingerprint() {
  setopt LOCAL_OPTIONS EXTENDED_GLOB
  local repository="${1:-}"
  local installer="$repository/install"

  _sys_update_validate_owned_path \
    "$repository" "$installer" file || {
      _sys_error "Refusing an unsafe fzf integration installer."
      return 1
    }
  installer="$REPLY"
  [[ -x "$installer" ]] || {
    _sys_error "fzf's tracked integration installer is not executable."
    return 1
  }

  local expected_blob actual_blob
  expected_blob=$(_sys_update_git_read -C "$repository" \
    rev-parse --verify 'HEAD:install' 2>/dev/null) || {
      _sys_error "fzf's integration installer is not tracked by HEAD."
      return 1
    }
  actual_blob=$(_sys_update_git_read -C "$repository" \
    hash-object -- install 2>/dev/null) || return 1
  (( ${#expected_blob} == 40 || ${#expected_blob} == 64 )) \
    && [[ "$expected_blob" == [[:xdigit:]]## \
      && "$actual_blob" == "$expected_blob" ]] || {
      _sys_error "fzf's integration installer differs from the authorized HEAD."
      return 1
    }

  local -A installer_state=()
  zmodload -F zsh/stat b:zstat 2>/dev/null \
    && zstat -H installer_state "$installer" 2>/dev/null || return 1
  (( installer_state[nlink] == 1 )) || {
    _sys_error "fzf's integration installer has an unsafe hard-link count."
    return 1
  }
  REPLY="${installer_state[device]}:${installer_state[inode]}:${installer_state[size]}:${installer_state[mtime]}:${installer_state[ctime]}:${expected_blob:l}"
}

_sys_update_fzf_install_revalidate() {
  local repository="${1:-}"
  local expected_fingerprint="${2:-}"
  [[ -n "$expected_fingerprint" ]] || return 2
  _sys_update_fzf_install_fingerprint "$repository" || return 1
  [[ "$REPLY" == "$expected_fingerprint" ]] || {
    _sys_error "fzf's integration installer changed before execution."
    return 1
  }
}

_sys_update_fzf_git_dir() {
  local -a candidate_dirs=(
    "$HOME/.fzf"
    "${XDG_DATA_HOME:-$HOME/.local/share}/fzf"
    "$HOME/.local/opt/fzf"
  )
  local candidate_dir
  for candidate_dir in "${candidate_dirs[@]}"; do
    [[ -e "$candidate_dir/.git" || -L "$candidate_dir/.git" ]] || continue
    _sys_update_git_fingerprint "$HOME" "$candidate_dir" || return 2
    REPLY="${reply[1]}"
    return 0
  done
  return 1
}

# Returns 0 when the active fzf executable lives in the discovered Git
# checkout. An installed but shadowed package must not hide that checkout.
_sys_update_fzf_active_in_git_dir() {
  local fzf_dir="${1:-}"
  local active_fzf=""
  [[ -n "$fzf_dir" ]] || return 1
  active_fzf=$(builtin whence -p fzf 2>/dev/null) || return 1
  [[ "$active_fzf" == /* && "$active_fzf" != *[[:cntrl:]]* ]] || return 1
  [[ "${active_fzf:A}" == "${fzf_dir:A}"/* ]]
}

update-fzf() {
  local REPLY
  local -a reply=()
  _sys_update_parse_plan_flags update-fzf "$@" || return $?
  [[ "$REPLY" == "help" ]] && return 0
  local -i dry_run="${reply[1]}" assume_yes="${reply[2]}"
  _sys_header "Updating fzf"

  if ! command -v fzf &>/dev/null; then
    _sys_report_result skipped "not installed" "fzf not installed, skipping."
    return 0
  fi

  local fzf_dir=""
  local -i discovery_rc=0 active_git_owned=0
  _sys_update_fzf_git_dir || discovery_rc=$?
  if (( discovery_rc == 0 )); then
    fzf_dir="$REPLY"
    _sys_update_fzf_active_in_git_dir "$fzf_dir" && active_git_owned=1
  fi

  if (( ! active_git_owned )); then
    # Managed by Homebrew
    if command -v brew &>/dev/null \
      && _sys_brew list fzf &>/dev/null 2>&1; then
      _sys_report_result delegated "Homebrew → sys-menu update-brew" \
        "Managed by Homebrew — use update-brew instead."
      return 0
    fi

    # Managed by APT
    if command -v dpkg &>/dev/null && dpkg -s fzf &>/dev/null; then
      _sys_report_result delegated "APT → sys-menu update-apt" \
        "Managed by APT — use update-apt instead."
      return 0
    fi
  fi

  if (( discovery_rc == 2 )); then
    _sys_error "Refusing an unsafe Git-owned fzf checkout."
    return 1
  fi

  if [[ -n "$fzf_dir" ]]; then
    _sys_update_git_fingerprint "$HOME" "$fzf_dir" || return 1
    fzf_dir="${reply[1]}"
    local origin="${reply[2]}"
    local current_commit="${reply[3]}"
    local expected_repo_device="${reply[4]}"
    local expected_repo_inode="${reply[5]}"
    local expected_git_device="${reply[6]}"
    local expected_git_inode="${reply[7]}"
    local expected_fingerprint="$REPLY"
    _sys_info "Git-owned fzf update plan:"
    _sys_label "Repository:" "${fzf_dir/#$HOME/~}"
    _sys_label "Origin:" "$(_sys_display_escape "$origin")"
    _sys_label "Current commit:" "$current_commit"
    (( dry_run )) && {
      _sys_report_result planned "at ${current_commit[1,7]}" \
        "Dry run complete; the repository was not updated."
      return 0
    }
    if (( ! assume_yes )); then
      if [[ ! -t 0 || ! -t 2 ]]; then
        _sys_error "Non-interactive Git-owned fzf updates require --yes."
        return 1
      fi
      _sys_confirm "Trust this origin and fast-forward fzf?" || {
        _sys_info "Cancelled."
        return 0
      }
    fi

    # Check once after authorization, then again immediately before the pull.
    _sys_update_git_revalidate \
      "$HOME" "$fzf_dir" "$expected_fingerprint" || return 1
    expected_fingerprint="$REPLY"
    _sys_update_git_revalidate \
      "$HOME" "$fzf_dir" "$expected_fingerprint" || return 1

    if _sys_update_git_logged -C "$fzf_dir" pull --ff-only origin; then
      _sys_update_git_revalidate_stable \
        "$HOME" "$fzf_dir" "$fzf_dir" "$origin" \
        "$expected_repo_device" "$expected_repo_inode" \
        "$expected_git_device" "$expected_git_inode" || return 1
      local post_pull_fingerprint="$REPLY"
      local updated_head="${reply[3]}"

      if [[ -e "$fzf_dir/install" || -L "$fzf_dir/install" ]]; then
        _sys_update_fzf_install_fingerprint "$fzf_dir" || return 1
        local installer_fingerprint="$REPLY"
        _sys_info "Refreshing shell integration..."
        _sys_update_git_revalidate \
          "$HOME" "$fzf_dir" "$post_pull_fingerprint" || return 1
        _sys_update_fzf_install_revalidate \
          "$fzf_dir" "$installer_fingerprint" || return 1
        "$fzf_dir/install" --key-bindings --completion --no-update-rc \
          >/dev/null 2>&1 || {
            _sys_error "fzf updated, but shell integration refresh failed."
            return 1
          }
      else
        _sys_dim "No tracked fzf integration installer was present."
      fi
      local version_output updated_version
      version_output=$(
        _sys_run_bounded_probe 3 65536 fzf --version 2>/dev/null
      ) || version_output=""
      updated_version="${version_output%%[[:space:]]*}"
      [[ -n "$updated_version" ]] || updated_version="unknown"
      _sys_update_git_change "$fzf_dir" "$current_commit" "$updated_head"
      if [[ "$REPLY" == updated ]]; then
        _sys_report_result updated "${reply[1]} ($updated_version)" \
          "fzf updated: ${reply[1]} ($updated_version)."
      else
        _sys_report_result current "$updated_version (${reply[1]})" \
          "fzf is already up to date ($updated_version, ${reply[1]})."
      fi
    else
      _sys_warn "fzf git update failed."
      return 1
    fi
    return 0
  fi

  (( dry_run )) && {
    _sys_report_result skipped "no Git-owned checkout" \
      "No Git-owned fzf update applies."
    return 0
  }
  _sys_warn "fzf is installed, but its package manager could not be determined."
  _sys_dim "Update it using the same method you originally used to install it."
  _sys_report_result skipped "installation owner unknown"
}

update-omz() {
  local REPLY
  local -a reply=()
  _sys_update_parse_plan_flags update-omz "$@" || return $?
  [[ "$REPLY" == "help" ]] && return 0
  local -i dry_run="${reply[1]}" assume_yes="${reply[2]}"
  _sys_header "Updating Oh My Zsh"

  if [[ -z "${ZSH:-}" \
    || ( ! -e "$ZSH/.git" && ! -L "$ZSH/.git" ) ]]; then
    _sys_report_result skipped "not detected" "Oh My Zsh not detected."
    return 0
  fi

  local omz_dir="$ZSH"
  _sys_update_git_fingerprint "$HOME" "$omz_dir" || {
    _sys_error "Refusing an unsafe Oh My Zsh checkout."
    return 1
  }
  omz_dir="${reply[1]}"
  local origin="${reply[2]}"
  local current_commit="${reply[3]}"
  local expected_repo_device="${reply[4]}"
  local expected_repo_inode="${reply[5]}"
  local expected_git_device="${reply[6]}"
  local expected_git_inode="${reply[7]}"
  local expected_fingerprint="$REPLY"

  _sys_info "Oh My Zsh update plan:"
  _sys_label "Directory:" "${omz_dir/#$HOME/~}"
  _sys_label "Origin:" "$(_sys_display_escape "$origin")"
  _sys_label "Current commit:" "$current_commit"
  _sys_dim "Uses Git fast-forward only; tools/upgrade.sh will not be executed."
  (( dry_run )) && {
    _sys_report_result planned "at ${current_commit[1,7]}" \
      "Dry run complete; Git pull was not executed."
    return 0
  }
  if (( ! assume_yes )); then
    if [[ ! -t 0 || ! -t 2 ]]; then
      _sys_error "Non-interactive Oh My Zsh updates require --yes."
        return 1
      fi
    _sys_confirm "Trust this origin and fast-forward Oh My Zsh?" || {
      _sys_info "Cancelled."
      return 0
    }
  fi

  # Check once after authorization, then again immediately before the pull.
  _sys_update_git_revalidate \
    "$HOME" "$omz_dir" "$expected_fingerprint" || return 1
  expected_fingerprint="$REPLY"
  _sys_update_git_revalidate \
    "$HOME" "$omz_dir" "$expected_fingerprint" || return 1

  if _sys_update_git_logged -C "$omz_dir" pull --ff-only origin; then
    _sys_update_git_revalidate_stable \
      "$HOME" "$omz_dir" "$omz_dir" "$origin" \
      "$expected_repo_device" "$expected_repo_inode" \
      "$expected_git_device" "$expected_git_inode" || return 1
    _sys_update_git_change "$omz_dir" "$current_commit" "${reply[3]}"
    if [[ "$REPLY" == updated ]]; then
      _sys_report_result updated "${reply[1]}" \
        "Oh My Zsh updated: ${reply[1]}."
    else
      _sys_report_result current "at ${reply[1]}" \
        "Oh My Zsh is already up to date (${reply[1]})."
    fi
  else
    _sys_error "Oh My Zsh update failed."
    return 1
  fi
}

update-zsh-plugins() {
  local REPLY
  local -a reply=()
  _sys_update_parse_plan_flags update-zsh-plugins "$@" || return $?
  [[ "$REPLY" == "help" ]] && return 0
  local -i dry_run="${reply[1]}" assume_yes="${reply[2]}"
  _sys_header "Updating Custom Zsh Plugins"

  local custom_dir="${ZSH_CUSTOM:-${ZSH:-$HOME/.oh-my-zsh}/custom}"
  if [[ ! -e "$custom_dir" && ! -L "$custom_dir" ]]; then
    _sys_info "No custom Git-owned plugins or themes were found."
    return 0
  fi
  _sys_update_validate_owned_path "$HOME" "$custom_dir" directory || {
    _sys_error "Custom Zsh directory must be an owned, symlink-free child of HOME."
    return 1
  }
  custom_dir="$REPLY"

  local plugins_dir="$custom_dir/plugins"
  local themes_dir="$custom_dir/themes"
  local repository_root
  local -a repositories=()
  for repository_root in "$plugins_dir" "$themes_dir"; do
    [[ -e "$repository_root" || -L "$repository_root" ]] || continue
    _sys_update_validate_owned_path \
      "$custom_dir" "$repository_root" directory || {
        _sys_error "Plugin collection is not owner-bound and symlink-free: $(_sys_display_escape "$repository_root")"
        return 1
      }
    repository_root="$REPLY"
    repositories+=( "$repository_root"/*(N) )
  done

  local -a git_repositories=()
  local -a repository_origins=()
  local -a repository_heads=()
  local -a repository_fingerprints=()
  local -a repository_devices=()
  local -a repository_inodes=()
  local -a git_devices=()
  local -a git_inodes=()
  local -a linked_zdx_links=()
  local -a linked_zdx_targets=()
  local repository
  local -i validation_failures=0
  for repository in "${repositories[@]}"; do
    [[ -e "$repository/.git" || -L "$repository/.git" ]] || continue
    if _sys_update_linked_zdx_checkout "$custom_dir" "$repository"; then
      linked_zdx_links+=("${repository:a}")
      linked_zdx_targets+=("$REPLY")
      continue
    fi
    if ! _sys_update_git_fingerprint "$HOME" "$repository"; then
      (( validation_failures++ ))
      _sys_warn "Excluded unsafe repository: $(_sys_display_escape "$repository")"
      continue
    fi
    git_repositories+=("${reply[1]}")
    repository_origins+=("${reply[2]}")
    repository_heads+=("${reply[3]}")
    repository_devices+=("${reply[4]}")
    repository_inodes+=("${reply[5]}")
    git_devices+=("${reply[6]}")
    git_inodes+=("${reply[7]}")
    repository_fingerprints+=("$REPLY")
  done

  local -i linked_zdx_count=${#linked_zdx_links[@]}
  if (( linked_zdx_count > 0 )); then
    local linked_checkout_noun="checkouts"
    local linked_verb="are"
    local linked_source_phrase="their source checkouts"
    if (( linked_zdx_count == 1 )); then
      linked_checkout_noun="checkout"
      linked_verb="is"
      linked_source_phrase="its source checkout"
    fi
    _sys_info \
      "Linked ZDX development $linked_checkout_noun $linked_verb managed from $linked_source_phrase:"
    local -i linked_zdx_index
    for (( linked_zdx_index = 1;
      linked_zdx_index <= linked_zdx_count;
      linked_zdx_index++ )); do
      _sys_dim "$(_sys_display_escape "${linked_zdx_links[linked_zdx_index]}") -> $(_sys_display_escape "${linked_zdx_targets[linked_zdx_index]}")"
    done
    _sys_dim "No Git pull will be attempted by update-zsh-plugins."
  fi

  if (( ${#git_repositories[@]} == 0 )); then
    if (( validation_failures > 0 )); then
      _sys_error "No repository passed executable-code safety validation."
      return 1
    fi
    if (( linked_zdx_count > 0 )); then
      _sys_update_counted_noun \
        "$linked_zdx_count" "checkout" "checkouts" || return 2
      local linked_summary_noun="$REPLY"
      _sys_report_result skipped \
        "$linked_zdx_count linked ZDX development $linked_summary_noun skipped" \
        "$linked_zdx_count linked ZDX development $linked_summary_noun skipped; no managed repository update was required."
      return 0
    fi
    _sys_report_result skipped "no Git-owned plugins or themes" \
      "No custom Git-owned plugins or themes were found."
    return 0
  fi

  _sys_warn "These repositories contain executable shell code."
  _sys_info "Fast-forward update plan:"
  local -i repository_index
  local -a plan_rows=()
  for (( repository_index = 1;
    repository_index <= ${#git_repositories[@]};
    repository_index++ )); do
    repository="${git_repositories[repository_index]}"
    plan_rows+=("${repository:t}"$'\t'"${repository_heads[repository_index][1,7]}"$'\t'"${repository_origins[repository_index]}")
  done
  _sys_table $'Repository\tCommit\tOrigin' "${plan_rows[@]}"
  if (( validation_failures > 0 )); then
    _sys_update_counted_noun \
      "$validation_failures" "repository" "repositories" || return 2
    _sys_warn "$validation_failures $REPLY failed safety validation."
  fi
  (( dry_run )) && {
    _sys_count_noun "${#git_repositories[@]}" repository repositories
    _sys_report_result planned "$REPLY" \
      "Dry run complete; no repository was updated."
    (( validation_failures == 0 ))
    return $?
  }
  if (( ! assume_yes )); then
    if [[ ! -t 0 || ! -t 2 ]]; then
      _sys_error "Non-interactive executable-code updates require --yes."
      return 1
    fi
    _sys_confirm "Trust every listed origin and fast-forward its code?" || {
      _sys_info "Cancelled."
      return 0
    }
  fi

  local -i updated=0 current=0 failed=$validation_failures
  local -a ready_indices=() updated_names=()
  # Revalidate every repository immediately after the shared authorization.
  for (( repository_index = 1;
    repository_index <= ${#git_repositories[@]};
    repository_index++ )); do
    repository="${git_repositories[repository_index]}"
    if _sys_update_git_revalidate \
      "$HOME" "$repository" \
      "${repository_fingerprints[repository_index]}"; then
      ready_indices+=("$repository_index")
    else
      (( failed++ ))
      _sys_warn "${repository:t} changed after authorization and was skipped."
    fi
  done

  for repository_index in "${ready_indices[@]}"; do
    repository="${git_repositories[repository_index]}"
    # This second exact check is adjacent to the mutating Git command.
    if ! _sys_update_git_revalidate \
      "$HOME" "$repository" \
      "${repository_fingerprints[repository_index]}"; then
      (( failed++ ))
      _sys_warn "${repository:t} changed before execution and was skipped."
      continue
    fi
    if ! _sys_update_git_logged \
      -C "$repository" pull --ff-only --quiet origin; then
      (( failed++ ))
      _sys_warn "${repository:t} was left unchanged or requires manual review."
      continue
    fi
    if ! _sys_update_git_revalidate_stable \
      "$HOME" "$repository" "$repository" \
      "${repository_origins[repository_index]}" \
      "${repository_devices[repository_index]}" \
      "${repository_inodes[repository_index]}" \
      "${git_devices[repository_index]}" \
      "${git_inodes[repository_index]}"; then
      (( failed++ ))
      _sys_warn "${repository:t} identity changed during update."
      continue
    fi
    _sys_update_git_change \
      "$repository" "${repository_heads[repository_index]}" "${reply[3]}"
    if [[ "$REPLY" == updated ]]; then
      (( updated++ ))
      updated_names+=("${repository:t}")
    else
      (( current++ ))
    fi
  done
  local -a summary_parts=()
  if (( updated > 0 )); then
    local updated_preview="${(j:, :)updated_names[1,3]}"
    (( ${#updated_names} > 3 )) && updated_preview+=", …"
    summary_parts+=("$updated updated ($updated_preview)")
  fi
  (( current > 0 )) && summary_parts+=("$current current")
  (( failed > 0 )) && summary_parts+=("$failed failed")
  if (( linked_zdx_count > 0 )); then
    _sys_count_noun "$linked_zdx_count" "linked ZDX development checkout"
    summary_parts+=("$REPLY skipped")
  fi
  local summary="${(j: · :)summary_parts}"
  if (( failed > 0 )); then
    _sys_report_result failed "$summary" "Zsh plugins and themes: $summary."
    return 1
  fi
  if (( updated > 0 )); then
    _sys_report_result updated "$summary" "Zsh plugins and themes: $summary."
  else
    _sys_report_result current "$summary" "Zsh plugins and themes: $summary."
  fi
}

# Aggregate applicability predicates. update-system calls them only through
# _sys_step_applies while it freezes the plan; each mirrors its step's own
# skip conditions.

_sys_update_fzf_applies() {
  local REPLY
  command -v fzf &>/dev/null && _sys_update_fzf_git_dir || return 1
  _sys_update_fzf_active_in_git_dir "$REPLY" && return 0
  ! { command -v brew &>/dev/null \
      && _sys_brew list fzf &>/dev/null 2>&1; } \
    && ! { command -v dpkg &>/dev/null \
      && dpkg -s fzf &>/dev/null; }
}

_sys_update_omz_applies() {
  command -v git &>/dev/null \
    && [[ -n "${ZSH:-}" \
      && ( -e "$ZSH/.git" || -L "$ZSH/.git" ) ]]
}

_sys_update_zsh_plugins_applies() {
  local custom_dir="${ZSH_CUSTOM:-${ZSH:-$HOME/.oh-my-zsh}/custom}"
  local -a custom_repositories=(
    "$custom_dir/plugins"/*(N/)
    "$custom_dir/themes"/*(N/)
  )
  local custom_repository
  for custom_repository in "${custom_repositories[@]}"; do
    [[ -d "$custom_repository/.git" ]] && return 0
  done
  return 1
}

typeset -g _SYS_UPDATE_GIT_SOURCED=1
