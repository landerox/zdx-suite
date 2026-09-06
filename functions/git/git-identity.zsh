#!/usr/bin/env zsh
# =============================================================================
# Git Identity: inspect and apply configured repository identities
# =============================================================================
#
# Loaded by git-menu.zsh after git-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_GIT_IDENTITY_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_git_identity_usage() {
  print -u2 -r -- "Usage: git-identity-switcher"
  print -u2 -r -- "       git-identity-switcher --status"
  print -u2 -r -- \
    "       git-identity-switcher --switch <profile> [local|global]"
  print -u2 -r -- "       git-identity-switcher --help"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Profiles are read from the loaded ZDX_GIT_IDENTITIES associative array:"
  print -u2 -r -- \
    "  typeset -gA ZDX_GIT_IDENTITIES"
  print -u2 -r -- \
    "  ZDX_GIT_IDENTITIES=(personal 'Name|Jane;Email|jane@example.com')"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Supported fields: Name, Email, GpgKey, GpgFormat, and SshKey."
}

_git_identity_profiles_available() {
  [[ "${(t)ZDX_GIT_IDENTITIES}" == *association* ]]
}

# Sets the caller's `reply` associative array. Profile values are configuration
# data, never code: delimiters and supported field names are validated here.
_git_identity_parse_profile() {
  local profile_name="${1:-}"
  local profile_value=""
  local -A parsed=()

  _git_identity_profiles_available || {
    _git_error \
      "Profile '$profile_name' is not defined in \$ZDX_GIT_IDENTITIES."
    return 1
  }
  (( ${+ZDX_GIT_IDENTITIES[$profile_name]} )) || {
    _git_error \
      "Profile '$profile_name' is not defined in \$ZDX_GIT_IDENTITIES."
    return 1
  }
  profile_value="${ZDX_GIT_IDENTITIES[$profile_name]}"
  [[ -n "$profile_value" ]] || {
    _git_error "Profile '$profile_name' is empty."
    return 1
  }

  local item field value
  for item in ${(s:;:)profile_value}; do
    [[ "$item" == *'|'* ]] || {
      _git_error "Profile '$profile_name' contains a malformed field."
      return 1
    }
    field="${item%%|*}"
    value="${item#*|}"
    case "$field" in
      Name|Email|GpgKey|GpgFormat|SshKey)
        ;;
      *)
        _git_error \
          "Profile '$profile_name' contains unsupported field '$field'."
        return 1
        ;;
    esac
    (( ${+parsed[$field]} )) && {
      _git_error "Profile '$profile_name' repeats field '$field'."
      return 1
    }
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || {
      _git_error "Profile '$profile_name' contains a control character."
      return 1
    }
    parsed[$field]="$value"
  done

  [[ -n "${parsed[Name]:-}" && -n "${parsed[Email]:-}" ]] || {
    _git_error "Profile '$profile_name' requires Name and Email."
    return 1
  }
  if [[ -n "${parsed[GpgFormat]:-}" \
    && "${parsed[GpgFormat]}" != "openpgp" \
    && "${parsed[GpgFormat]}" != "ssh" ]]; then
    _git_error \
      "Profile '$profile_name' has invalid GpgFormat; use openpgp or ssh."
    return 1
  fi

  reply=("${(@kv)parsed}")
}

_git_identity_expand_home_path() {
  local identity_path="${1:-}"
  case "$identity_path" in
    "~")
      identity_path="$HOME"
      ;;
    "~/"*)
      identity_path="$HOME/${identity_path#\~/}"
      ;;
  esac
  [[ -n "$identity_path" \
    && "$identity_path" != *$'\n'* \
    && "$identity_path" != *$'\r'* ]] \
    || return 1
  REPLY="$identity_path"
}

# Git executes core.sshCommand through a shell. Quote the identity path as one
# POSIX shell word so profile data cannot add SSH options or commands.
_git_identity_ssh_command() {
  local identity_path="${1:-}"
  [[ "$identity_path" != *"'"* ]] || return 1
  REPLY="ssh -i '$identity_path' -o IdentitiesOnly=yes"
}

# Sets the caller's indexed `reply_values` array to every configured value.
_git_identity_config_values() {
  local scope_flag="$1"
  local key="$2"
  local value
  reply_values=()
  while IFS= read -r -d $'\0' value; do
    reply_values+=("$value")
  done < <(
    command git config "$scope_flag" --null --get-all "$key" 2>/dev/null
  )
}

_git_identity_restore_config() {
  local scope_flag="$1"
  local -a keys=("${(@P)2}")
  local present_name="$3"
  local values_name="$4"
  local key
  local -i rollback_failed=0

  for key in "${keys[@]}"; do
    command git config "$scope_flag" --unset-all "$key" &>/dev/null || true
    if (( ${${(P)present_name}[$key]:-0} )); then
      command git config "$scope_flag" --add \
        "$key" "${${(P)values_name}[$key]}" &>/dev/null \
        || rollback_failed=1
    fi
  done
  (( rollback_failed == 0 ))
}

_git_identity_apply() {
  local profile_name="$1"
  local scope="${2:-local}"
  [[ "$scope" == (local|global) ]] || {
    _git_error "Identity scope must be 'local' or 'global'."
    return 2
  }
  _git_require_git || return 1
  if [[ "$scope" == "local" ]]; then
    _git_require_repo || {
      _git_info \
        "Use: git-identity-switcher --switch ${(q)profile_name} global"
      return 1
    }
  fi

  local -A reply=()
  _git_identity_parse_profile "$profile_name" || return 1
  local -A profile=("${(@kv)reply}")

  local gpg_key="${profile[GpgKey]:-}"
  local gpg_format="${profile[GpgFormat]:-}"
  local ssh_key="${profile[SshKey]:-}"
  if [[ -n "$gpg_key" ]]; then
    _git_identity_expand_home_path "$gpg_key" || {
      _git_error "Profile '$profile_name' has an invalid GPG key value."
      return 1
    }
    gpg_key="$REPLY"
    if [[ -z "$gpg_format" ]]; then
      if [[ "$gpg_key" == ssh-* \
        || "$gpg_key" == */.ssh/* \
        || "$gpg_key" == *.pub ]]; then
        gpg_format="ssh"
      else
        gpg_format="openpgp"
      fi
    fi
  fi

  local ssh_command=""
  if [[ -n "$ssh_key" ]]; then
    _git_identity_expand_home_path "$ssh_key" || {
      _git_error "Profile '$profile_name' has an invalid SSH key value."
      return 1
    }
    ssh_key="$REPLY"
    _git_identity_ssh_command "$ssh_key" || {
      _git_error \
        "Profile '$profile_name' uses an unsupported quote in its SSH key path."
      return 1
    }
    ssh_command="$REPLY"
  fi

  local scope_flag="--$scope"
  local -a keys=(
    user.name
    user.email
    user.signingkey
    commit.gpgSign
    tag.gpgSign
    gpg.format
    core.sshCommand
  )
  local -A desired_present=(
    user.name 1
    user.email 1
    user.signingkey $(( ${#gpg_key} > 0 ))
    commit.gpgSign $(( ${#gpg_key} > 0 ))
    tag.gpgSign $(( ${#gpg_key} > 0 ))
    gpg.format $(( ${#gpg_key} > 0 ))
    core.sshCommand $(( ${#ssh_command} > 0 ))
  )
  local -A desired_values=(
    user.name "${profile[Name]}"
    user.email "${profile[Email]}"
    user.signingkey "$gpg_key"
    commit.gpgSign true
    tag.gpgSign true
    gpg.format "$gpg_format"
    core.sshCommand "$ssh_command"
  )

  local -A previous_present=() previous_values=()
  local -a current_values=()
  local -a reply_values=()
  local key
  for key in "${keys[@]}"; do
    _git_identity_config_values "$scope_flag" "$key"
    current_values=("${reply_values[@]}")
    if (( ${#current_values[@]} > 1 )); then
      _git_error \
        "Refusing to replace multi-valued '$key'; normalize it first."
      return 1
    fi
    if (( ${#current_values[@]} == 1 )); then
      previous_present[$key]=1
      previous_values[$key]="${current_values[1]}"
    else
      previous_present[$key]=0
      previous_values[$key]=""
    fi
  done

  _git_header "Git Identity Plan"
  _git_label "Profile:" "$profile_name"
  _git_label "Scope:" "$scope"
  _git_label "Name:" "${profile[Name]}"
  _git_label "Email:" "${profile[Email]}"
  _git_label "Signing:" "${gpg_key:-(disabled)}"
  _git_label "SSH identity:" "${ssh_key:-(default SSH selection)}"

  local -i apply_failed=0
  for key in "${keys[@]}"; do
    if (( desired_present[$key] )); then
      command git config "$scope_flag" --replace-all \
        "$key" "${desired_values[$key]}" || {
        apply_failed=1
        break
      }
    elif (( previous_present[$key] )); then
      command git config "$scope_flag" --unset-all "$key" || {
        apply_failed=1
        break
      }
    fi
  done

  if (( apply_failed )); then
    _git_error "Identity update failed; restoring the previous configuration."
    _git_identity_restore_config \
      "$scope_flag" keys previous_present previous_values || {
      _git_error \
        "Rollback was incomplete; inspect the $scope Git configuration."
      return 1
    }
    _git_info "Previous identity configuration restored."
    return 1
  fi

  _git_success "Profile '$profile_name' successfully applied ($scope)."
}

_git_identity_status_section() {
  local scope="$1"
  local scope_flag="--$scope"
  local name email signing format ssh_command
  name=$(command git config "$scope_flag" --get user.name 2>/dev/null)
  email=$(command git config "$scope_flag" --get user.email 2>/dev/null)
  signing=$(command git config "$scope_flag" --get user.signingkey 2>/dev/null)
  format=$(command git config "$scope_flag" --get gpg.format 2>/dev/null)
  ssh_command=$(command git config "$scope_flag" --get core.sshCommand \
    2>/dev/null)

  _git_label "Scope:" "$scope"
  _git_label "Name:" "${name:-(not set)}"
  _git_label "Email:" "${email:-(not set)}"
  _git_label "Signing key:" "${signing:-(not set)}"
  _git_label "GPG format:" "${format:-openpgp}"
  _git_label "SSH command:" "${ssh_command:-(not set)}"
}

_git_identity_status() {
  _git_require_git || return 1
  _git_header "Git Identity"
  if command git rev-parse --is-inside-work-tree &>/dev/null; then
    _git_identity_status_section local
    _git_blank
  else
    _git_info "Outside a worktree; local identity is unavailable."
  fi
  _git_identity_status_section global
}

_git_identity_menu() {
  _git_require_git || return 1
  _git_require_interactive || return 1
  _git_identity_profiles_available || {
    _git_warn "No associative ZDX_GIT_IDENTITIES configuration is loaded."
    _git_info "See: git-identity-switcher --help"
    return 0
  }
  (( ${#ZDX_GIT_IDENTITIES[@]} > 0 )) || {
    _git_warn "ZDX_GIT_IDENTITIES contains no profiles."
    return 0
  }

  local -a profile_names=() rows=()
  local profile_name
  local -i index=0 invalid_count=0
  for profile_name in "${(@on)${(k)ZDX_GIT_IDENTITIES}}"; do
    local -A reply=()
    if ! _git_identity_parse_profile "$profile_name"; then
      (( invalid_count++ ))
      continue
    fi
    local -A profile=("${(@kv)reply}")
    profile_names+=("$profile_name")
    (( index++ ))
    rows+=(
      "$(_git_record_escape "$profile_name")|$index|$(_git_record_escape "${profile[Name]} <${profile[Email]}>")"
    )
  done
  (( invalid_count == 0 )) \
    || _git_warn "$invalid_count invalid identity profile(s) were omitted."
  (( ${#rows[@]} > 0 )) || return 1

  local selected
  local -i fzf_rc=0
  selected=$(printf '%s\n' "${rows[@]}" | _git_fzf \
    --delimiter='[|]' \
    --with-nth=1,3 \
    --height=40% \
    --prompt='Identity > ' \
    --header='Up/Down navigate | Enter select | Esc cancel' \
    --preview='' \
    --preview-window=hidden) || fzf_rc=$?
  if (( fzf_rc != 0 )); then
    _git_fzf_rc_is_cancel "$fzf_rc" && return 0
    _git_error "fzf failed while selecting an identity."
    return 1
  fi

  local selected_index="${${selected#*|}%%|*}"
  [[ "$selected_index" == <-> \
    && selected_index -ge 1 \
    && selected_index -le ${#profile_names[@]} ]] || {
    _git_error "Invalid identity selection."
    return 1
  }

  local scope="global"
  if command git rev-parse --is-inside-work-tree &>/dev/null; then
    fzf_rc=0
    scope=$(printf 'local\nglobal\n' | _git_fzf \
      --height=20% \
      --prompt='Identity scope > ' \
      --header='Up/Down navigate | Enter select | Esc cancel' \
      --preview='' \
      --preview-window=hidden) || fzf_rc=$?
    if (( fzf_rc != 0 )); then
      _git_fzf_rc_is_cancel "$fzf_rc" && return 0
      _git_error "fzf failed while selecting an identity scope."
      return 1
    fi
  fi
  [[ "$scope" == (local|global) ]] || return 1
  _git_identity_apply "${profile_names[$selected_index]}" "$scope"
}

git-identity-switcher() {
  emulate -L zsh

  case "${1:-}" in
    "")
      (( $# == 0 )) || return 2
      _git_identity_menu
      ;;
    -h|--help)
      (( $# == 1 )) || {
        _git_error "--help accepts no additional arguments."
        return 2
      }
      _git_identity_usage
      ;;
    --status)
      (( $# == 1 )) || {
        _git_error "--status accepts no additional arguments."
        return 2
      }
      _git_identity_status
      ;;
    --switch)
      (( $# >= 2 && $# <= 3 )) || {
        (( $# < 2 )) \
          && _git_error "Profile name is required for --switch." \
          || _git_error "--switch accepts a profile and optional scope."
        return 2
      }
      _git_identity_apply "$2" "${3:-local}"
      ;;
    *)
      _git_error "Unknown git-identity-switcher argument: $1"
      return 2
      ;;
  esac
}

typeset -g _GIT_IDENTITY_SOURCED=1
