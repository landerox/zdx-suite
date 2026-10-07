#!/usr/bin/env zsh
# =============================================================================
# Git Identity: inspect, check, and apply configured repository identities
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

# REPLY: the signing format of an expanded GpgKey: the profile's GpgFormat, or
# else ssh for an SSH key path or literal key and openpgp otherwise.
# Usage: _git_identity_signing_format GPG_KEY [GPG_FORMAT]
_git_identity_signing_format() {
  local gpg_key="${1-}"
  local gpg_format="${2-}"
  if [[ -z "$gpg_format" ]]; then
    if [[ "$gpg_key" == ssh-* \
      || "$gpg_key" == */.ssh/* \
      || "$gpg_key" == *.pub ]]; then
      gpg_format="ssh"
    else
      gpg_format="openpgp"
    fi
  fi
  REPLY="$gpg_format"
}

# Git executes core.sshCommand through a shell. Quote the identity path as one
# POSIX shell word so profile data cannot add SSH options or commands. BASE is
# the SSH command that receives the key, plain ssh by default.
# Usage: _git_identity_ssh_command KEY_PATH [BASE]
_git_identity_ssh_command() {
  local identity_path="${1:-}"
  local base_command="${2:-ssh}"
  [[ "$identity_path" != *"'"* ]] || return 1
  REPLY="$base_command -i '$identity_path' -o IdentitiesOnly=yes"
}

# Succeeds for an ssh -o value that selects an identity.
_git_identity_ssh_option_selects() {
  emulate -L zsh
  [[ "${(L)1}" == (identityfile|identitiesonly)([[:space:]=]*|) ]]
}

# Splits an SSH command into shell words and removes the options that select
# an identity: -i FILE (or -iFILE) and -o IdentityFile or IdentitiesOnly. Sets
# reply to (program command selects): the unquoted program word after any
# NAME=value assignments, the remaining words with their original quoting,
# and "yes" when an identity option was removed. Other options, such as
# -o IdentityAgent, stay.
_git_identity_ssh_parts() {
  emulate -L zsh

  local -a ssh_words=("${(z)1}")
  local -a kept_words=()
  local ssh_word=""
  local plain_word=""
  local program_name=""
  local selects="no"
  local -i word_index=1

  while (( word_index <= ${#ssh_words} )) \
    && [[ "${(Q)ssh_words[word_index]}" =~ '^[A-Za-z_][A-Za-z0-9_]*=' ]]; do
    kept_words+=("${ssh_words[word_index]}")
    (( word_index++ ))
  done
  if (( word_index <= ${#ssh_words} )); then
    program_name="${(Q)ssh_words[word_index]}"
    kept_words+=("${ssh_words[word_index]}")
    (( word_index++ ))
  fi

  for (( ; word_index <= ${#ssh_words}; word_index++ )); do
    ssh_word="${ssh_words[word_index]}"
    plain_word="${(Q)ssh_word}"
    case "$plain_word" in
      -i)
        selects="yes"
        (( word_index++ ))
        continue
        ;;
      -i?*)
        selects="yes"
        continue
        ;;
      -o)
        if _git_identity_ssh_option_selects "${(Q)ssh_words[word_index + 1]-}"; then
          selects="yes"
          (( word_index++ ))
          continue
        fi
        ;;
      -o?*)
        if _git_identity_ssh_option_selects "${plain_word#-o}"; then
          selects="yes"
          continue
        fi
        ;;
    esac
    kept_words+=("$ssh_word")
  done

  reply=("$program_name" "${(j: :)kept_words}" "$selects")
}

# REPLY: KEY_PATH as Windows ssh.exe reads it. A Windows path is kept as
# given; a WSL path is converted with wslpath -w.
_git_identity_windows_key_path() {
  emulate -L zsh

  local key_path="$1"
  local converted_path=""
  REPLY=""
  if [[ "$key_path" == [A-Za-z]:[\\/]* || "$key_path" == '\\'* ]]; then
    REPLY="$key_path"
    return 0
  fi
  _git_check_cmd wslpath || return 1
  converted_path=$(command wslpath -w "$key_path" </dev/null 2>/dev/null) ||
    return 1
  converted_path="${converted_path%$'\r'}"
  [[ -n "$converted_path" && "$converted_path" != *[$'\n\r']* ]] || return 1
  REPLY="$converted_path"
}

# REPLY: the last core.sshCommand value set below SCOPE, which applies when
# SCOPE sets none: system and global values for local, system for global.
_git_identity_inherited_ssh_command() {
  emulate -L zsh

  local target_scope="$1"
  local value_scope=""
  local config_value=""
  REPLY=""
  while IFS= read -r -d $'\0' value_scope \
    && IFS= read -r -d $'\0' config_value; do
    case "$value_scope" in
      system) REPLY="$config_value" ;;
      global) [[ "$target_scope" == "local" ]] && REPLY="$config_value" ;;
    esac
  done < <(
    command git config --show-scope --null --get-all core.sshCommand 2>/dev/null
  )
  return 0
}

# Plans core.sshCommand for a profile in one scope. The profile keeps the SSH
# program and options the scope already uses -- its own value, else the
# inherited one -- so an agent or program choice such as WSL ssh.exe or
# -o IdentityAgent survives; only that command's key selection is replaced.
# A profile key is added with IdentitiesOnly, converted for ssh.exe. Without
# a key, an inherited command that selects no key stays in effect, and one
# that selects another key is overridden by the same command without it.
# Sets the caller's _git_identity_ssh_present, _git_identity_ssh_value, and
# _git_identity_ssh_label. Usage:
#   _git_identity_plan_ssh PROFILE KEY_PATH SCOPE_VALUE INHERITED_VALUE
_git_identity_plan_ssh() {
  emulate -L zsh

  local profile_name="$1"
  local ssh_key="$2"
  local scope_value="$3"
  local inherited_value="$4"
  local source_value="${scope_value:-$inherited_value}"
  local program_name="ssh"
  local base_command="ssh"
  local selects="no"
  local -a reply=()

  _git_identity_ssh_present=0
  _git_identity_ssh_value=""
  _git_identity_ssh_label="(default SSH selection)"
  if [[ -n "$source_value" ]]; then
    _git_identity_ssh_parts "$source_value"
    program_name="${reply[1]}"
    base_command="${reply[2]}"
    selects="${reply[3]}"
    [[ -n "$program_name" && -n "$base_command" ]] || {
      program_name="ssh"
      base_command="ssh"
    }
  fi

  if [[ -n "$ssh_key" ]]; then
    local key_argument="$ssh_key"
    if [[ "${${program_name##*[/\\]}:l}" == "ssh.exe" ]]; then
      _git_identity_windows_key_path "$ssh_key" || {
        _git_error \
          "Profile '$profile_name' sets SshKey, but core.sshCommand runs ssh.exe, which needs a Windows path, and wslpath -w could not convert it."
        _git_info \
          "Give SshKey as a Windows path such as C:/Users/you/.ssh/id_ed25519, or point core.sshCommand at the Linux ssh, then retry."
        return 1
      }
      key_argument="$REPLY"
    fi
    _git_identity_ssh_command "$key_argument" "$base_command" || {
      _git_error \
        "Profile '$profile_name' uses an unsupported quote in its SSH key path."
      return 1
    }
    _git_identity_ssh_present=1
    _git_identity_ssh_value="$REPLY"
    _git_identity_ssh_label="$ssh_key"
    return 0
  fi

  [[ -n "$source_value" ]] || return 0
  if [[ "$selects" == "no" ]]; then
    if [[ -n "$scope_value" ]]; then
      _git_identity_ssh_present=1
      _git_identity_ssh_value="$scope_value"
    else
      _git_identity_ssh_label="(default SSH selection through the inherited core.sshCommand)"
    fi
    return 0
  fi

  # The command selects another identity: keep only its program and options,
  # unless the scope inherits exactly that without a key anyway.
  if [[ -n "$inherited_value" ]]; then
    _git_identity_ssh_parts "$inherited_value"
    if [[ "${reply[3]}" == "no" && "${reply[2]}" == "$base_command" ]]; then
      _git_identity_ssh_label="(default SSH selection through the inherited core.sshCommand)"
      return 0
    fi
    _git_identity_ssh_label="(default SSH selection; overrides inherited core.sshCommand)"
  elif [[ "$base_command" == "ssh" ]]; then
    return 0
  fi
  _git_identity_ssh_present=1
  _git_identity_ssh_value="$base_command"
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
    _git_identity_signing_format "$gpg_key" "$gpg_format"
    gpg_format="$REPLY"
  fi

  if [[ -n "$ssh_key" ]]; then
    _git_identity_expand_home_path "$ssh_key" || {
      _git_error "Profile '$profile_name' has an invalid SSH key value."
      return 1
    }
    ssh_key="$REPLY"
    [[ "$ssh_key" != *"'"* ]] || {
      _git_error \
        "Profile '$profile_name' uses an unsupported quote in its SSH key path."
      return 1
    }
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
    core.sshCommand 0
  )
  local -A desired_values=(
    user.name "${profile[Name]}"
    user.email "${profile[Email]}"
    user.signingkey "$gpg_key"
    commit.gpgSign true
    tag.gpgSign true
    gpg.format "$gpg_format"
    core.sshCommand ""
  )

  # A local profile must not inherit signing from another scope: write
  # explicit overrides so the plan matches the effective result. SSH
  # selection is planned below from the configured command.
  if [[ "$scope" == "local" ]] && (( ${#gpg_key} == 0 )); then
    desired_present[commit.gpgSign]=1
    desired_values[commit.gpgSign]=false
    desired_present[tag.gpgSign]=1
    desired_values[tag.gpgSign]=false
  fi

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

  local -i _git_identity_ssh_present=0
  local _git_identity_ssh_value=""
  local _git_identity_ssh_label=""
  _git_identity_inherited_ssh_command "$scope"
  _git_identity_plan_ssh "$profile_name" "$ssh_key" \
    "${previous_values[core.sshCommand]}" "$REPLY" || return 1
  desired_present[core.sshCommand]=$_git_identity_ssh_present
  desired_values[core.sshCommand]="$_git_identity_ssh_value"

  _git_header "Git Identity Plan"
  _git_label "Profile:" "$profile_name"
  _git_label "Scope:" "$scope"
  _git_label "Name:" "${profile[Name]}"
  _git_label "Email:" "${profile[Email]}"
  _git_label "Signing:" "${gpg_key:-(disabled)}"
  _git_label "SSH identity:" "$_git_identity_ssh_label"
  (( _git_identity_ssh_present )) &&
    _git_label "SSH command:" "$_git_identity_ssh_value"

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

# --- Workspace identity check ------------------------------------------------

_git_identity_check_usage() {
  print -u2 -r -- "Usage: git-identity-check [--json|--quiet]"
  print -u2 -r -- "       git-identity-check --help"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Compare a repository below \$WS_BASE_DIR/<platform>/<identity> with the profile"
  print -u2 -r -- \
    "named after its identity directory in ZDX_GIT_IDENTITIES: the effective"
  print -u2 -r -- \
    "user.email, user.signingkey, gpg.format, commit.gpgSign, and the SSH key that"
  print -u2 -r -- \
    "core.sshCommand selects. It never changes configuration or prints key material."
  print -u2 -r -- \
    "A mismatch names each field and the fix command and returns 1. Outside that"
  print -u2 -r -- \
    "layout, or without a matching profile, it reports not applicable and returns 0."
  print -u2 -r -- \
    "  --json   Write one zdx.git-identity-check.v1 JSON object to stdout."
  print -u2 -r -- \
    "  --quiet  Print nothing unless the identity differs; then print one warning."
}

# REPLY: "true" or "false" for a Git boolean value, an unset value meaning
# false, or "invalid" for a value Git would reject.
_git_identity_bool() {
  emulate -L zsh
  case "${(L)1}" in
    true|yes|on) REPLY="true" ;;
    false|no|off|"") REPLY="false" ;;
    <->) (( 10#$1 != 0 )) && REPLY="true" || REPLY="false" ;;
    *) REPLY="invalid" ;;
  esac
}

# Fills the caller's `effective` association with the effective value of each
# compared key, read in one Git process under its lowercase name. As for Git,
# the last value wins, and a key written without "=" means true.
_git_identity_effective_config() {
  local config_entry=""
  effective=()
  while IFS= read -r -d $'\0' config_entry; do
    if [[ "$config_entry" == *$'\n'* ]]; then
      effective[${config_entry%%$'\n'*}]="${config_entry#*$'\n'}"
    else
      effective[$config_entry]="true"
    fi
  done < <(
    command git config --null --get-regexp \
      '^(user\.email|user\.signingkey|gpg\.format|commit\.gpgsign|core\.sshcommand)$' \
      2>/dev/null
  )
  return 0
}

# Sets the caller's _git_identity_ssh_keys array to the identity files that an
# SSH command selects -- -i FILE, -iFILE, or -o IdentityFile -- unquoted and
# with a leading ~ expanded, and REPLY to its program word. The command is
# split into shell words and never run.
_git_identity_ssh_selected_keys() {
  emulate -L zsh

  local ssh_command="${1-}"
  local -a ssh_words=()
  local plain_word="" option_text="" key_path="" program_name=""
  local -i word_index=1
  _git_identity_ssh_keys=()
  REPLY=""
  [[ -n "$ssh_command" ]] || return 0
  ssh_words=("${(z)ssh_command}")

  while (( word_index <= ${#ssh_words} )) \
    && [[ "${(Q)ssh_words[word_index]}" =~ '^[A-Za-z_][A-Za-z0-9_]*=' ]]; do
    (( word_index++ ))
  done
  program_name="${(Q)ssh_words[word_index]-}"
  (( word_index++ ))

  for (( ; word_index <= ${#ssh_words}; word_index++ )); do
    plain_word="${(Q)ssh_words[word_index]}"
    key_path=""
    option_text=""
    case "$plain_word" in
      -i)
        key_path="${(Q)ssh_words[word_index + 1]-}"
        (( word_index++ ))
        ;;
      -i?*)
        key_path="${plain_word#-i}"
        ;;
      -o)
        option_text="${(Q)ssh_words[word_index + 1]-}"
        (( word_index++ ))
        ;;
      -o?*)
        option_text="${plain_word#-o}"
        ;;
      *)
        continue
        ;;
    esac
    if [[ -n "$option_text" \
      && "$option_text" =~ '^[Ii][Dd][Ee][Nn][Tt][Ii][Tt][Yy][Ff][Ii][Ll][Ee]([[:space:]]*=[[:space:]]*|[[:space:]]+)(.+)$' ]]; then
      key_path="${match[2]}"
    fi
    [[ -n "$key_path" ]] || continue
    _git_identity_expand_home_path "$key_path" && key_path="$REPLY"
    _git_identity_ssh_keys+=("$key_path")
  done
  REPLY="$program_name"
}

# Compares the current repository's effective configuration with PROFILE as
# `git-identity-switcher --switch PROFILE local` would set it. Sets the
# caller's _git_identity_fields and _git_identity_reasons arrays to each
# mismatching field and why. Reasons show email addresses and signing formats
# but never a key, key ID, or key path.
_git_identity_compare() {
  emulate -L zsh

  local profile_name="$1"
  local -A reply=()
  _git_identity_parse_profile "$profile_name" || return 1
  local -A profile=("${(@kv)reply}")
  local -A effective=()
  _git_identity_effective_config
  _git_identity_fields=()
  _git_identity_reasons=()
  local REPLY=""

  local expected_email="${profile[Email]}"
  if [[ "${effective[user.email]-}" != "$expected_email" ]]; then
    _git_identity_fields+=("user.email")
    if (( ${+effective[user.email]} )); then
      _git_identity_reasons+=(
        "is ${effective[user.email]}; the profile expects $expected_email"
      )
    else
      _git_identity_reasons+=("is not set; the profile expects $expected_email")
    fi
  fi

  _git_identity_bool "${effective[commit.gpgsign]-}"
  local actual_signing="$REPLY"
  local gpg_key="${profile[GpgKey]:-}"
  if [[ -n "$gpg_key" ]]; then
    _git_identity_expand_home_path "$gpg_key" || {
      _git_error "Profile '$profile_name' has an invalid GPG key value."
      return 1
    }
    gpg_key="$REPLY"
    _git_identity_signing_format "$gpg_key" "${profile[GpgFormat]:-}"
    local expected_format="$REPLY"
    local actual_key="${effective[user.signingkey]-}"
    [[ -n "$actual_key" ]] && _git_identity_expand_home_path "$actual_key" &&
      actual_key="$REPLY"
    if [[ -z "$actual_key" ]]; then
      _git_identity_fields+=("user.signingkey")
      _git_identity_reasons+=("is not set; the profile signs with its own key")
    elif [[ "$actual_key" != "$gpg_key" ]]; then
      _git_identity_fields+=("user.signingkey")
      _git_identity_reasons+=("names a different key than the profile")
    fi
    local actual_format="${effective[gpg.format]:-openpgp}"
    if [[ "$actual_format" != "$expected_format" ]]; then
      _git_identity_fields+=("gpg.format")
      _git_identity_reasons+=(
        "is $actual_format; the profile expects $expected_format"
      )
    fi
    if [[ "$actual_signing" != "true" ]]; then
      _git_identity_fields+=("commit.gpgSign")
      _git_identity_reasons+=("is $actual_signing; the profile signs every commit")
    fi
  elif [[ "$actual_signing" != "false" ]]; then
    _git_identity_fields+=("commit.gpgSign")
    _git_identity_reasons+=("is $actual_signing; the profile has no signing key")
  fi

  local -a _git_identity_ssh_keys=()
  _git_identity_ssh_selected_keys "${effective[core.sshcommand]-}"
  local ssh_program="$REPLY"
  local ssh_key="${profile[SshKey]:-}"
  if [[ -n "$ssh_key" ]]; then
    _git_identity_expand_home_path "$ssh_key" || {
      _git_error "Profile '$profile_name' has an invalid SSH key value."
      return 1
    }
    local -a accepted_keys=("$REPLY")
    # The switcher hands ssh.exe the key as a Windows path.
    if [[ "${${ssh_program##*[/\\]}:l}" == "ssh.exe" ]] &&
      _git_identity_windows_key_path "${accepted_keys[1]}"; then
      accepted_keys+=("$REPLY")
    fi
    if (( ${#_git_identity_ssh_keys} == 0 )); then
      _git_identity_fields+=("core.sshCommand")
      _git_identity_reasons+=("selects no SSH key; the profile uses its own key")
    elif (( ${#_git_identity_ssh_keys} > 1 )); then
      _git_identity_fields+=("core.sshCommand")
      _git_identity_reasons+=(
        "selects ${#_git_identity_ssh_keys} SSH keys; the profile uses one"
      )
    elif (( ! ${accepted_keys[(Ie)${_git_identity_ssh_keys[1]}]} )); then
      _git_identity_fields+=("core.sshCommand")
      _git_identity_reasons+=("selects a different SSH key than the profile")
    fi
  elif (( ${#_git_identity_ssh_keys} > 0 )); then
    _git_identity_fields+=("core.sshCommand")
    _git_identity_reasons+=("selects an SSH key, but the profile has none")
  fi
  return 0
}

# Writes the zdx.git-identity-check.v1 document. MATCHES is true, false, or
# empty when the check does not apply; the remaining arguments are flat
# field/reason pairs. Usage: _git_identity_check_json APPLICABLE REASON ROOT
#   PLATFORM IDENTITY PROFILE MATCHES FIX_COMMAND [FIELD REASON]...
_git_identity_check_json() {
  emulate -L zsh

  command jq -n -c -M \
    --arg schema "zdx.git-identity-check.v1" \
    --argjson applicable "$1" \
    --arg reason "$2" \
    --arg repository "$3" \
    --arg platform "$4" \
    --arg identity "$5" \
    --arg profile "$6" \
    --arg matches "$7" \
    --arg fix_command "$8" \
    'def text: if . == "" then null else . end;
     $ARGS.positional as $pairs
     | {
         schema: $schema,
         applicable: $applicable,
         reason: ($reason | text),
         repository: $repository,
         platform: ($platform | text),
         identity: ($identity | text),
         profile: ($profile | text),
         matches: (if $matches == "" then null else $matches == "true" end),
         mismatches: [
           range(0; $pairs | length; 2) as $index
           | {field: $pairs[$index], reason: $pairs[$index + 1]}
         ],
         fix_command: ($fix_command | text)
       }' \
    --args "${@:9}" || {
    _git_error "Unable to write the JSON identity document."
    return 1
  }
}

git-identity-check() {
  emulate -L zsh

  if (( $# == 1 )) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
    _git_identity_check_usage
    return 0
  fi
  local output_mode="text"
  while (( $# > 0 )); do
    case "$1" in
      --json|--quiet)
        if [[ "$output_mode" != "text" ]]; then
          if [[ "$output_mode" == "${1#--}" ]]; then
            _git_error "Duplicate option: $1"
          else
            _git_error "--json and --quiet cannot be combined."
          fi
          return 2
        fi
        output_mode="${1#--}"
        ;;
      -h|--help)
        _git_error "--help does not accept additional arguments."
        return 2
        ;;
      *)
        _git_error "Unknown argument for git-identity-check: $1"
        return 2
        ;;
    esac
    shift
  done

  if [[ "$output_mode" == "json" ]]; then
    _git_require_jq || return 1
  fi
  _git_require_repo || return 1
  local repo_root=""
  repo_root=$(command git rev-parse --path-format=absolute --show-toplevel \
    2>/dev/null) || {
    _git_error "Unable to locate the repository root."
    return 1
  }
  repo_root="${repo_root:A}"

  local platform="" identity="" profile_name="" skip_reason=""
  local -a reply=()
  if _git_workspace_layout "$repo_root"; then
    platform="${reply[1]}"
    identity="${reply[2]}"
    if _git_identity_profiles_available \
      && (( ${+ZDX_GIT_IDENTITIES[$identity]} )); then
      profile_name="$identity"
    else
      skip_reason="no profile named $identity in ZDX_GIT_IDENTITIES"
    fi
  else
    skip_reason="the repository is not below \$WS_BASE_DIR/<platform>/<identity>"
  fi

  if [[ -n "$skip_reason" ]]; then
    case "$output_mode" in
      json)
        _git_identity_check_json false "$skip_reason" "$repo_root" \
          "$platform" "$identity" "" "" ""
        return
        ;;
      text)
        _git_ui_heading "Git Identity Check"
        _git_ui_label "Repository" "${repo_root:t}"
        [[ -n "$platform" ]] &&
          _git_ui_label "Workspace" "$platform/$identity"
        _git_info "Not applicable: $skip_reason."
        ;;
    esac
    return 0
  fi

  local -a _git_identity_fields=() _git_identity_reasons=()
  _git_identity_compare "$profile_name" || return 1
  local fix_command="git-identity-switcher --switch ${(q-)profile_name} local"
  local -i mismatch_count=${#_git_identity_fields}
  local -i field_index=0

  if [[ "$output_mode" == "json" ]]; then
    local -a mismatch_pairs=()
    for (( field_index = 1; field_index <= mismatch_count; field_index++ )); do
      mismatch_pairs+=(
        "${_git_identity_fields[field_index]}"
        "${_git_identity_reasons[field_index]}"
      )
    done
    if (( mismatch_count == 0 )); then
      _git_identity_check_json true "" "$repo_root" "$platform" "$identity" \
        "$profile_name" true "" || return 1
      return 0
    fi
    _git_identity_check_json true "" "$repo_root" "$platform" "$identity" \
      "$profile_name" false "$fix_command" "${mismatch_pairs[@]}" || return 1
    return 1
  fi

  if [[ "$output_mode" == "quiet" ]]; then
    (( mismatch_count > 0 )) || return 0
    _git_warn "Git identity mismatch in ${repo_root:t} for profile ${profile_name}: ${(j:, :)_git_identity_fields}"
    _git_info "Fix: $fix_command"
    return 1
  fi

  _git_ui_heading "Git Identity Check"
  _git_ui_label "Repository" "${repo_root:t}"
  _git_ui_label "Workspace" "$platform/$identity"
  _git_ui_label "Profile" "$profile_name"
  if (( mismatch_count == 0 )); then
    _git_success "The repository identity matches profile ${profile_name}."
    return 0
  fi
  for (( field_index = 1; field_index <= mismatch_count; field_index++ )); do
    _git_warn "${_git_identity_fields[field_index]} ${_git_identity_reasons[field_index]}."
  done
  local REPLY=""
  _git_count_noun "$mismatch_count" field
  _git_error "The repository identity differs from profile ${profile_name} in $REPLY."
  _git_info "Fix: $fix_command"
  return 1
}

typeset -g _GIT_IDENTITY_SOURCED=1
