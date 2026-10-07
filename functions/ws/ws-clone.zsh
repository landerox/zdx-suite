#!/usr/bin/env zsh
# =============================================================================
# Ws Clone: planned clones into the workspace layout
# =============================================================================
#
# Loaded by ws-menu.zsh after ws-common.zsh.
# Safe to re-source; defines functions only.
#
# A clone runs in a private hidden staging directory next to its destination
# and is renamed into place without replacing anything. A matching Git
# identity profile is then applied through the Git suite's public command;
# this module never writes Git configuration itself.
#

if [[ -n "${_WS_CLONE_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_ws_clone_usage() {
  print -u2 -r -- "Usage: ws-clone [URL] [--platform NAME] [--identity NAME] [--name DIR]"
  print -u2 -r -- "                [--dry-run] [--yes]"
  print -u2 -r -- "       ws-clone --help"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Clone URL into WS_BASE_DIR/<platform>/<identity>/<repository> after showing"
  print -u2 -r -- \
    "the exact plan. Accepted URLs are https://host/path, ssh://[user@]host[:port]/path,"
  print -u2 -r -- \
    "and user@host:path. Local paths, file://, ext::, and credentials in the URL"
  print -u2 -r -- "are refused."
  print -u2 -r -- ""
  print -u2 -r -- \
    "  --platform NAME  Workspace platform. Inferred for github.com, gitlab.com,"
  print -u2 -r -- \
    "                   <platform>-<identity> SSH aliases, and .ws-hostname files."
  print -u2 -r -- \
    "  --identity NAME  Workspace identity. Otherwise chosen from existing"
  print -u2 -r -- \
    "                   <platform>/* directories and ZDX_GIT_IDENTITIES profiles."
  print -u2 -r -- \
    "  --name DIR       Repository directory; defaults to the name in the URL."
  print -u2 -r -- "  --dry-run        Print the plan and stop."
  print -u2 -r -- \
    "  --yes            Accept the plan without a prompt; required without a terminal."
  print -u2 -r -- ""
  print -u2 -r -- \
    "An SSH URL uses the <platform>-<identity> host alias when your SSH configuration"
  print -u2 -r -- \
    "maps it to the URL's host. A ZDX_GIT_IDENTITIES profile named like the identity"
  print -u2 -r -- \
    "is applied with: git-menu git-identity-switcher --switch NAME local."
  print -u2 -r -- \
    "On success the repository path is printed on stdout."
}

# reply: (kind user host port path) for a validated repository URL. kind is
# https, ssh, or scp (user@host:path); path is the text after the host as
# written. Status 2 refuses the URL with the reason on stderr.
# Usage: _ws_clone_parse_url <url>
_ws_clone_parse_url() {
  emulate -L zsh
  local url="${1-}" kind="" user="" host="" port="" repository_path=""
  local rest="" authority="" userinfo="" user_host=""
  reply=()

  if [[ -z "$url" || "$url" == -* ]]; then
    _ws_error "Refusing an empty or option-like repository URL."
    return 2
  fi
  if (( ${#url} > 2048 )) || [[ "$url" == *[[:cntrl:][:space:]]* ]]; then
    _ws_error "Refusing a repository URL with spaces or control characters."
    return 2
  fi
  if [[ "$url" == *::* ]]; then
    _ws_error "Refusing a Git transport-helper address such as ext::."
    return 2
  fi
  if [[ "$url" == *[?#]* ]]; then
    _ws_error "Refusing a repository URL with a query or fragment."
    return 2
  fi

  case "$url" in
    https://*)
      kind=https
      rest="${url#https://}"
      ;;
    ssh://*)
      kind=ssh
      rest="${url#ssh://}"
      ;;
    file://*)
      _ws_error "Refusing a file:// URL; ws-clone clones remote repositories only."
      return 2
      ;;
    *://*)
      _ws_error "Unsupported URL scheme '${url%%://*}'; use https://, ssh://, or user@host:path."
      return 2
      ;;
    /*|./*|../*|'~'*)
      _ws_error "Refusing a local path; ws-clone clones remote repositories only."
      return 2
      ;;
    *@*:*)
      kind=scp
      ;;
    *)
      _ws_error "Unsupported repository address; use https://, ssh://, or user@host:path."
      return 2
      ;;
  esac

  if [[ "$kind" == scp ]]; then
    # user:password@host:path carries a credential before the user's @.
    if [[ "${url%%@*}" == *:* ]]; then
      _ws_error "Refusing a URL with embedded credentials; use a credential helper or an SSH key."
      return 2
    fi
    user_host="${url%%:*}"
    repository_path="${url#*:}"
    user="${user_host%%@*}"
    host="${user_host#*@}"
    [[ -n "$user" && "$host" != *@* ]] || {
      _ws_error "Use the user@host:path form with exactly one user."
      return 2
    }
  else
    [[ "$rest" == */* ]] || {
      _ws_error "The repository URL has no repository path."
      return 2
    }
    authority="${rest%%/*}"
    repository_path="${rest#*/}"
    if [[ "$authority" == *@* ]]; then
      userinfo="${authority%@*}"
      authority="${authority##*@}"
      # HTTPS user information is where tokens are pasted; SSH allows a user.
      if [[ "$kind" == https || "$userinfo" == *:* ]]; then
        _ws_error "Refusing a URL with embedded credentials; use a credential helper or an SSH key."
        return 2
      fi
      user="$userinfo"
    fi
    host="${authority%%:*}"
    if [[ "$authority" == *:* ]]; then
      port="${authority#*:}"
      [[ "$port" == <1-65535> && "$port" != 0* ]] || {
        _ws_error "The repository URL has an invalid port."
        return 2
      }
    fi
  fi

  [[ ${#host} -le 253 \
    && "$host" =~ '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?([.][A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$' ]] || {
    _ws_error "The repository URL has an invalid host."
    return 2
  }
  [[ -z "$user" || "$user" =~ '^[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$' ]] || {
    _ws_error "The repository URL has an invalid user name."
    return 2
  }

  local checked_path="${repository_path#/}" component=""
  checked_path="${checked_path%/}"
  [[ -n "$checked_path" ]] || {
    _ws_error "The repository URL has no repository path."
    return 2
  }
  for component in "${(@s:/:)checked_path}"; do
    [[ "$component" =~ '^[A-Za-z0-9_][A-Za-z0-9._-]{0,99}$' ]] || {
      _ws_error "The repository path has an unsupported component: ${component}"
      return 2
    }
  done

  reply=("$kind" "$user" "$host" "$port" "$repository_path")
}

# REPLY: the repository directory name from a URL path: its final component
# without a trailing .git. Usage: _ws_clone_url_name <path>
_ws_clone_url_name() {
  local repository_path="${1#/}"
  repository_path="${repository_path%/}"
  REPLY="${${repository_path:t}%.git}"
  _ws_name_valid "$REPLY"
}

# REPLY: the host a workspace serves, by the convention git-auth also reads:
# github.com for the github platform, else the first line of a regular
# .ws-hostname file in the identity directory, else gitlab.com. REPLY is
# empty when the file holds an invalid name.
# Usage: _ws_workspace_hostname <root> <platform> <identity>
_ws_workspace_hostname() {
  local root="$1" platform="$2" identity="$3" hostname=""
  local hostname_file="$root/$platform/$identity/.ws-hostname"
  if [[ "$platform" == github ]]; then
    hostname="github.com"
  elif [[ -f "$hostname_file" && ! -L "$hostname_file" ]]; then
    IFS= read -r hostname < "$hostname_file" 2>/dev/null
    # A file saved by a Windows editor ends its line with CRLF.
    hostname="${hostname%$'\r'}"
  else
    hostname="gitlab.com"
  fi
  [[ "$hostname" =~ '^[A-Za-z0-9.-]+$' ]] || hostname=""
  REPLY="${hostname:l}"
}

# reply: the identities that can receive a clone from <host> on <platform>,
# sorted: existing <platform>/<identity> directories that serve the host, and
# ZDX_GIT_IDENTITIES profiles without a directory, which would be created and
# serve the platform's default host.
# Usage: _ws_clone_identity_candidates <root> <platform> <host>
_ws_clone_identity_candidates() {
  emulate -L zsh
  local root="$1" platform="$2" host="${3:l}" directory="" identity=""
  local REPLY=""
  local -A candidates=()
  reply=()
  if [[ -d "$root/$platform" && ! -L "$root/$platform" ]]; then
    for directory in "$root/$platform"/*(N/); do
      identity="${directory:t}"
      _ws_name_valid "$identity" || continue
      _ws_workspace_hostname "$root" "$platform" "$identity"
      [[ "$REPLY" == "$host" ]] && candidates[$identity]=1
    done
  fi
  if [[ "${(t)ZDX_GIT_IDENTITIES-}" == *association* ]]; then
    for identity in "${(@k)ZDX_GIT_IDENTITIES}"; do
      _ws_name_valid "$identity" || continue
      [[ -e "$root/$platform/$identity" || -L "$root/$platform/$identity" ]] \
        && continue
      if [[ "$platform" == github ]]; then
        [[ "$host" == github.com ]] || continue
      else
        [[ "$host" == gitlab.com ]] || continue
      fi
      candidates[$identity]=1
    done
  fi
  reply=("${(@ko)candidates}")
}

# REPLY: the identity chosen in the picker. Status 130 is a cancellation.
# Usage: _ws_clone_choose_identity <platform> <identity...>
_ws_clone_choose_identity() {
  emulate -L zsh
  local platform="$1"
  shift
  local -a choices=("$@")
  REPLY=""
  _ws_require_cmd fzf "the identity picker" || return 1
  local selected=""
  local -i fzf_rc=0
  _ws_fzf_capture \
    --height='40%' \
    --prompt='ws identity > ' \
    --header="Platform: ${(V)platform}"$'\n''Type to filter | Enter select | Esc cancel' \
    < <(print -rl -- "${choices[@]}") || fzf_rc=$?
  selected="$REPLY"
  REPLY=""
  if (( fzf_rc != 0 )); then
    _ws_fzf_rc_is_cancel "$fzf_rc" && return 130
    _ws_error "The identity picker failed (status $fzf_rc)."
    return 1
  fi
  [[ -n "$selected" ]] || return 130
  [[ "$selected" != *$'\n'* ]] \
    && _ws_array_contains_literal "$selected" "${choices[@]}" || {
    _ws_error "The selected identity was not in the picker snapshot."
    return 1
  }
  REPLY="$selected"
}

# REPLY: the HostName that SSH configures for <alias>, or empty when the
# alias is not configured. The alias is resolved by the SSH program Git runs
# (GIT_SSH_COMMAND, the global core.sshCommand, GIT_SSH, then ssh), so WSL's
# ssh.exe reads the Windows SSH configuration. Like Git, a command is run
# through /bin/sh with the alias as an argument, never as program text. ssh -G
# only prints configuration; it opens no connection. PuTTY variants have no
# -G, so their aliases are never used. Usage: _ws_ssh_alias_hostname <git> <alias>
_ws_ssh_alias_hostname() {
  emulate -L zsh
  local git_path="$1" alias_host="$2"
  local ssh_command="${GIT_SSH_COMMAND:-}" ssh_program="" ssh_variant=""
  local output="" line="" resolved="" ssh_path=""

  if [[ -z "$ssh_command" ]]; then
    ssh_command=$(_ws_run_with_timeout "$_WS_PROBE_TIMEOUT" "$git_path" \
      config --global --get core.sshCommand </dev/null 2>/dev/null) \
      || ssh_command=""
  fi
  if [[ -n "$ssh_command" ]]; then
    local -a ssh_words=("${(z)ssh_command}")
    ssh_program="${(Q)ssh_words[1]}"
  else
    ssh_program="${GIT_SSH:-ssh}"
  fi
  ssh_variant=$(_ws_run_with_timeout "$_WS_PROBE_TIMEOUT" "$git_path" \
    config --global --get ssh.variant </dev/null 2>/dev/null) || ssh_variant=""
  if [[ -z "$ssh_variant" || "$ssh_variant" == auto ]]; then
    ssh_variant="${${${ssh_program##*[/\\]}:l}%.exe}"
  fi
  if [[ "$ssh_variant" != (plink|putty|tortoiseplink|simple) ]]; then
    if [[ -n "$ssh_command" ]]; then
      output=$(_ws_run_with_timeout "$_WS_PROBE_TIMEOUT" /bin/sh -c \
        "$ssh_command \"\$@\"" "$ssh_command" -G -- "$alias_host" \
        </dev/null 2>/dev/null) || output=""
    elif _ws_command_path "$ssh_program"; then
      ssh_path="$REPLY"
      output=$(_ws_run_with_timeout "$_WS_PROBE_TIMEOUT" "$ssh_path" \
        -G -- "$alias_host" </dev/null 2>/dev/null) || output=""
    fi
  fi
  for line in "${(@f)output}"; do
    # Windows OpenSSH ends its lines with CRLF.
    line="${line%$'\r'}"
    if [[ "$line" == "hostname "* ]]; then
      line="${line#hostname }"
      [[ "$line" =~ '^[A-Za-z0-9][A-Za-z0-9.-]*$' \
        && "${line:l}" != "${alias_host:l}" ]] && resolved="$line"
      break
    fi
  done
  REPLY="$resolved"
}

# REPLY: device:inode of a real directory that the current user owns.
_ws_clone_directory_identity() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local directory="${1-}"
  REPLY=""
  local -A state=()
  [[ -d "$directory" && ! -L "$directory" ]] \
    && zstat -LH state -- "$directory" 2>/dev/null \
    && (( (state[mode] & 8#170000) == 8#040000 && state[uid] == EUID )) \
    || return 1
  REPLY="${state[device]}:${state[inode]}"
}

# reply is the mv command that refuses to replace a destination. GNU and
# uutils mv take -T -n, so an existing directory is never entered. Other
# implementations, such as BSD mv on macOS, take -n only; the caller verifies
# the moved identity afterwards, which detects a destination directory that
# appeared after the last check.
_ws_clone_mv_command() {
  reply=()
  local mv_command="" version_text=""
  mv_command=$(whence -p mv 2>/dev/null) || mv_command=""
  [[ "$mv_command" == /* && -x "$mv_command" ]] || {
    _ws_error "mv is required to publish the clone."
    return 1
  }
  version_text=$(LC_ALL=C _ws_run_with_timeout "$_WS_PROBE_TIMEOUT" \
    "$mv_command" --version </dev/null 2>/dev/null) || version_text=""
  version_text="${version_text%%$'\n'*}"
  if [[ "$version_text" == *"GNU coreutils"* \
    || "$version_text" == *"uutils coreutils"* ]]; then
    reply=("$mv_command" -T -n)
  else
    reply=("$mv_command" -n)
  fi
}

# Removes the private staging directory only while it is still the directory
# this clone created. Usage: _ws_clone_remove_staging <staging> <identity>
_ws_clone_remove_staging() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local staging="$1" identity="$2" REPLY=""
  local -A state=()
  _ws_command_display "$staging"
  local staging_display="$REPLY"
  if [[ -d "$staging" && ! -L "$staging" \
    && "${staging:t}" == .ws-clone.?????? ]] \
    && zstat -LH state -- "$staging" 2>/dev/null \
    && [[ "${state[device]}:${state[inode]}" == "$identity" ]] \
    && (( state[uid] == EUID )); then
    command rm -rf -- "$staging" 2>/dev/null && return 0
    _ws_warn "Could not remove the staging directory: $staging_display"
    return 1
  fi
  _ws_warn "The staging directory changed; it was not removed: $staging_display"
  return 1
}

# Explains a refusal of a workspace on a Windows drive under WSL, where every
# file reports mode 777 unless WSL mounts the drive with DrvFs metadata.
_ws_clone_wsl_drive_hint() {
  local refused="${1-}"
  [[ "$refused" == /mnt/[[:alpha:]] || "$refused" == /mnt/[[:alpha:]]/* ]] \
    || return 0
  _ws_host_is_wsl || return 0
  _ws_info "Windows drives under /mnt report mode 777 unless WSL mounts them with DrvFs metadata."
  _ws_dim "Keep workspaces in the Linux filesystem, such as ~/workspaces, or add [automount] options=\"metadata,umask=22,fmask=11\" to /etc/wsl.conf and restart WSL."
}

ws-clone() {
  emulate -L zsh
  setopt local_options local_traps

  local url="" platform="" identity="" name=""
  local -i dry_run=0 assume_yes=0 have_url=0 argument_count=$#
  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        (( argument_count == 1 )) || {
          _ws_error "--help accepts no additional arguments."
          return 2
        }
        _ws_clone_usage
        return 0
        ;;
      --platform|--identity|--name)
        (( $# >= 2 )) || {
          _ws_error "$1 requires a value."
          return 2
        }
        _ws_name_valid "$2" || {
          _ws_error "$1 takes one directory name of letters, digits, '.', '_', or '-' that starts with a letter or digit."
          return 2
        }
        case "$1" in
          --platform) platform="$2" ;;
          --identity) identity="$2" ;;
          --name) name="$2" ;;
        esac
        shift
        ;;
      --dry-run) dry_run=1 ;;
      --yes) assume_yes=1 ;;
      -*)
        _ws_error "Unknown ws-clone option: $1"
        return 2
        ;;
      *)
        (( ! have_url )) || {
          _ws_error "ws-clone accepts one repository URL."
          return 2
        }
        url="$1"
        have_url=1
        ;;
    esac
    shift
  done

  local REPLY=""
  local -a reply=()
  if (( ! have_url )); then
    if (( assume_yes )) || ! _ws_interactive_available; then
      _ws_error "A repository URL is required."
      _ws_info "Usage: ws-clone URL [--platform NAME] [--identity NAME] [--name DIR] [--dry-run] [--yes]"
      return 2
    fi
    _ws_read_line "Repository URL" || return 0
    url="$REPLY"
    [[ -n "$url" ]] || {
      _ws_info "Cancelled: nothing was cloned."
      return 0
    }
  fi

  _ws_clone_parse_url "$url" || return
  local url_kind="${reply[1]}" url_user="${reply[2]}" url_host="${reply[3]}"
  local url_port="${reply[4]}" url_path="${reply[5]}"
  local host_folded="${url_host:l}"
  if [[ -z "$name" ]]; then
    _ws_clone_url_name "$url_path" || {
      _ws_error "Cannot derive a directory name from the URL; pass --name DIR."
      return 2
    }
    name="$REPLY"
  fi

  _ws_git_command || return 1
  local git_path="$REPLY"

  # The root must already exist: a mistyped WS_BASE_DIR never creates a tree.
  local base="${WS_BASE_DIR-}"
  [[ -n "$base" && "$base" == /* && "$base" != *[[:cntrl:]]* ]] || {
    _ws_error "WS_BASE_DIR must be an absolute path."
    return 1
  }
  while [[ "$base" != / && "$base" == */ ]]; do
    base="${base%/}"
  done
  [[ "$base" != / && "$base" == "${base:a}" ]] || {
    _ws_error "WS_BASE_DIR must be a normalized path below the filesystem root."
    return 1
  }
  _ws_command_display "$base"
  local base_display="$REPLY"
  [[ -d "$base" ]] || {
    _ws_error "The workspace root does not exist: $base_display"
    _ws_info "Create it first, or set WS_BASE_DIR in ~/.config/zdx/config.zsh."
    return 1
  }
  _ws_resolve_trusted_dir "$base" || {
    _ws_error "The workspace root must be a real directory reached without untrusted symbolic links: $base_display"
    return 1
  }
  local root="$REPLY"
  _ws_owned_directory "$root" || {
    _ws_error "The workspace root must be owned by you and not writable by group or other users: $base_display"
    _ws_clone_wsl_drive_hint "$root"
    return 1
  }
  local root_identity="$REPLY"
  _ws_validate_ancestor_chain "$root" || return 1

  # A URL host may already be a <platform>-<identity> alias of a workspace.
  local candidate_directory="" candidate_platform="" candidate_identity=""
  local -a alias_matches=()
  for candidate_directory in "$root"/*(N/); do
    candidate_platform="${candidate_directory:t}"
    _ws_name_valid "$candidate_platform" || continue
    [[ "$url_host" == "$candidate_platform"-?* ]] || continue
    candidate_identity="${url_host#$candidate_platform-}"
    _ws_name_valid "$candidate_identity" || continue
    [[ -d "$candidate_directory/$candidate_identity" \
      && ! -L "$candidate_directory/$candidate_identity" ]] || continue
    alias_matches+=("$candidate_platform/$candidate_identity")
  done
  local alias_platform="" alias_identity=""
  if (( ${#alias_matches[@]} == 1 )); then
    alias_platform="${alias_matches[1]%%/*}"
    alias_identity="${alias_matches[1]#*/}"
  fi

  local -a hostname_matches=()
  if [[ -z "$platform" ]]; then
    if [[ -n "$alias_platform" ]]; then
      platform="$alias_platform"
    elif [[ "$host_folded" == github.com ]]; then
      platform="github"
    elif [[ "$host_folded" == gitlab.com ]]; then
      platform="gitlab"
    else
      local hostname_file=""
      local -a matched_platforms=()
      for hostname_file in "$root"/*/*/.ws-hostname(N.); do
        candidate_platform="${hostname_file:h:h:t}"
        candidate_identity="${hostname_file:h:t}"
        _ws_name_valid "$candidate_platform" \
          && _ws_name_valid "$candidate_identity" || continue
        _ws_workspace_hostname "$root" "$candidate_platform" "$candidate_identity"
        [[ -n "$REPLY" && "$REPLY" == "$host_folded" ]] || continue
        hostname_matches+=("$candidate_platform/$candidate_identity")
        matched_platforms+=("$candidate_platform")
      done
      matched_platforms=("${(@u)matched_platforms}")
      if (( ${#matched_platforms[@]} == 1 )); then
        platform="${matched_platforms[1]}"
      elif (( ${#matched_platforms[@]} > 1 )); then
        _ws_error "Several platforms serve $url_host: ${(j:, :)matched_platforms}; pass --platform NAME."
        return 2
      else
        _ws_error "Cannot infer the workspace platform for $url_host; pass --platform NAME."
        _ws_dim "A .ws-hostname file in <platform>/<identity> names the host a workspace serves."
        return 2
      fi
    fi
  fi

  local identity_source="option"
  if [[ -z "$identity" ]]; then
    local -a identity_candidates=()
    if [[ -n "$alias_identity" && "$platform" == "$alias_platform" ]]; then
      identity_candidates=("$alias_identity")
    elif (( ${#hostname_matches[@]} > 0 )); then
      local hostname_match=""
      for hostname_match in "${hostname_matches[@]}"; do
        [[ "${hostname_match%%/*}" == "$platform" ]] \
          && identity_candidates+=("${hostname_match#*/}")
      done
    else
      _ws_clone_identity_candidates "$root" "$platform" "$host_folded"
      identity_candidates=("${reply[@]}")
    fi
    if (( ${#identity_candidates[@]} == 0 )); then
      _ws_error "No identity is known for $platform and $url_host; pass --identity NAME."
      return 2
    elif (( ${#identity_candidates[@]} == 1 )); then
      identity="${identity_candidates[1]}"
      identity_source="inferred"
    elif (( assume_yes )) || ! _ws_interactive_available; then
      _ws_error "Several identities can receive this clone: ${(j:, :)identity_candidates}; pass --identity NAME."
      return 2
    else
      local -i choose_rc=0
      _ws_clone_choose_identity "$platform" "${identity_candidates[@]}" \
        || choose_rc=$?
      if (( choose_rc == 130 )); then
        _ws_info "Cancelled: nothing was cloned."
        return 0
      fi
      (( choose_rc == 0 )) || return $choose_rc
      identity="$REPLY"
      identity_source="selected"
    fi
  fi

  local platform_dir="$root/$platform"
  local identity_dir="$platform_dir/$identity"
  local destination="$identity_dir/$name"
  _ws_command_display "$base/$platform/$identity"
  local identity_display="$REPLY"
  _ws_command_display "$base/$platform/$identity/$name"
  local destination_display="$REPLY"

  local -a create_dirs=() existing_dirs=() existing_identities=()
  local directory=""
  for directory in "$platform_dir" "$identity_dir"; do
    if [[ -e "$directory" || -L "$directory" ]]; then
      _ws_owned_directory "$directory" || {
        _ws_command_display "$directory"
        _ws_error "Workspace directories must be real directories that you own and that group and other users cannot write: $REPLY"
        return 1
      }
      existing_dirs+=("$directory")
      existing_identities+=("$REPLY")
    else
      create_dirs+=("$directory")
    fi
  done
  if [[ -e "$destination" || -L "$destination" ]]; then
    _ws_error "The destination already exists: $destination_display"
    return 1
  fi

  # SSH and scp-like URLs use the workspace alias when SSH maps it to the
  # URL's own host; HTTPS URLs authenticate through credential helpers.
  local clone_url="$url" alias_note=""
  if [[ "$url_kind" != https ]]; then
    local alias_host="${platform}-${identity}"
    if [[ "$url_host" == "$alias_host" ]]; then
      alias_note="$alias_host (used by the URL)"
    elif [[ "$alias_host" =~ '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' ]]; then
      _ws_ssh_alias_hostname "$git_path" "$alias_host"
      local alias_target="$REPLY"
      if [[ -n "$alias_target" && "${alias_target:l}" == "$host_folded" ]]; then
        if [[ "$url_kind" == scp ]]; then
          clone_url="${url_user}@${alias_host}:${url_path}"
        else
          clone_url="ssh://${url_user:+${url_user}@}${alias_host}${url_port:+:${url_port}}/${url_path}"
        fi
        alias_note="$alias_host (HostName $url_host)"
      else
        alias_note="none ($alias_host does not resolve to $url_host)"
      fi
    fi
  fi

  local -i apply_profile=0
  if [[ "${(t)ZDX_GIT_IDENTITIES-}" == *association* ]] \
    && (( ${+ZDX_GIT_IDENTITIES[$identity]} )); then
    apply_profile=1
  fi

  _ws_header "Workspace Clone Plan"
  _ws_label "Repository" "$name"
  _ws_label "URL" "$clone_url"
  [[ "$clone_url" != "$url" ]] && _ws_label "Requested URL" "$url"
  _ws_label "Workspace" "$platform/$identity ($identity_source)"
  _ws_label "Destination" "$destination_display"
  [[ -n "$alias_note" ]] && _ws_label "SSH alias" "$alias_note"
  if (( apply_profile )); then
    _ws_label "Identity profile" \
      "git-menu git-identity-switcher --switch $identity local"
  else
    _ws_label "Identity profile" "none (ZDX_GIT_IDENTITIES has no $identity)"
  fi
  for directory in "${create_dirs[@]}"; do
    _ws_command_display "$base/${directory#$root/}"
    _ws_label "New directory" "$REPLY"
  done
  _ws_warn "git clone downloads $url_host content that ZDX does not review."

  if (( dry_run )); then
    _ws_count_noun 1 clone
    _ws_info "Dry run: $REPLY planned; nothing was cloned."
    return 0
  fi

  local auto_yes="no"
  (( assume_yes )) && auto_yes="yes"
  local -i confirm_rc=0
  _ws_confirm_mutation "Clone $name into $identity_display?" "$auto_yes" \
    "Cancelled: nothing was cloned." || confirm_rc=$?
  (( confirm_rc == 130 )) && return 0
  (( confirm_rc == 0 )) || return $confirm_rc

  # Revalidate after authorization: the tree may have changed meanwhile.
  local -i check_index=0
  _ws_owned_directory "$root" && [[ "$REPLY" == "$root_identity" ]] || {
    _ws_error "The workspace root changed after planning; nothing was cloned."
    return 1
  }
  for (( check_index = 1; check_index <= ${#existing_dirs[@]}; check_index++ )); do
    _ws_owned_directory "${existing_dirs[check_index]}" \
      && [[ "$REPLY" == "${existing_identities[check_index]}" ]] || {
      _ws_error "A workspace directory changed after planning; nothing was cloned."
      return 1
    }
  done
  for directory in "${create_dirs[@]}"; do
    [[ ! -e "$directory" && ! -L "$directory" ]] || {
      _ws_error "A planned workspace directory appeared after planning; nothing was cloned."
      return 1
    }
  done
  [[ ! -e "$destination" && ! -L "$destination" ]] || {
    _ws_error "The destination appeared after planning; nothing was cloned."
    return 1
  }

  local staging="" staging_identity="" staged_identity="" current_umask=""
  local -i clone_rc=0 keep_staging=0 operation_rc=0
  {
    trap 'operation_rc=130; return 130' INT
    trap 'operation_rc=143; return 143' TERM HUP

    # New workspace directories never become writable by group or others.
    current_umask=$(umask)
    for directory in "${create_dirs[@]}"; do
      (umask "$(( [##8] 8#$current_umask | 8#022 ))"; command mkdir -- "$directory") \
        2>/dev/null && _ws_owned_directory "$directory" || {
        _ws_command_display "$directory"
        _ws_error "Could not create the workspace directory: $REPLY"
        operation_rc=1
        return 1
      }
    done

    staging=$(umask 077; command mktemp -d \
      "$identity_dir/.ws-clone.XXXXXX" 2>/dev/null) || staging=""
    if [[ -z "$staging" || "${staging:h}" != "$identity_dir" \
      || "${staging:t}" != .ws-clone.?????? ]] \
      || ! _ws_owned_directory "$staging"; then
      staging=""
      _ws_error "Could not create a private staging directory for the clone."
      operation_rc=1
      return 1
    fi
    staging_identity="$REPLY"

    _ws_command_display git clone -- "$clone_url" "$staging/$name"
    _ws_dim "\$ $REPLY"
    # Repository variables inherited from a hook or another tool would
    # redirect the clone; the clone gets a clean repository environment.
    (
      unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
        GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
        GIT_PREFIX GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE GIT_SHALLOW_FILE
      command "$git_path" clone -- "$clone_url" "$staging/$name"
    ) >&2 || clone_rc=$?
    if (( clone_rc == 130 || clone_rc == 143 )); then
      _ws_error "git clone was interrupted; nothing was published."
      operation_rc=$clone_rc
      return $clone_rc
    elif (( clone_rc != 0 )); then
      _ws_error "git clone failed (status $clone_rc); nothing was published."
      operation_rc=1
      return 1
    fi

    if [[ ! -d "$staging/$name" || -L "$staging/$name" ]] \
      || [[ ! -e "$staging/$name/.git" ]] \
      || ! _ws_clone_directory_identity "$staging/$name"; then
      _ws_error "The clone did not produce a repository; nothing was published."
      operation_rc=1
      return 1
    fi
    staged_identity="$REPLY"

    [[ ! -e "$destination" && ! -L "$destination" ]] || {
      _ws_error "The destination appeared during the clone; nothing was published."
      operation_rc=1
      return 1
    }
    _ws_clone_mv_command || {
      operation_rc=1
      return 1
    }
    "${reply[@]}" -- "$staging/$name" "$destination" 2>/dev/null || {
      _ws_error "Could not move the clone into place; nothing was published."
      operation_rc=1
      return 1
    }
    if ! _ws_clone_directory_identity "$destination" \
      || [[ "$REPLY" != "$staged_identity" ]]; then
      # A directory that appeared at the destination may now hold the clone;
      # leave everything for the user to inspect.
      keep_staging=1
      _ws_command_display "$staging"
      _ws_error "The destination changed while the clone was published; inspect $destination_display and $REPLY."
      operation_rc=1
      return 1
    fi
    command rmdir -- "$staging" 2>/dev/null && staging=""
  } always {
    trap - INT TERM HUP
    if [[ -n "$staging" ]] && (( ! keep_staging )); then
      _ws_clone_remove_staging "$staging" "$staging_identity" || true
    fi
  }
  (( operation_rc == 0 )) || return $operation_rc

  _ws_success "Cloned $name into $destination_display."

  local -i final_rc=0 identity_rc=0
  if (( apply_profile )); then
    if (( ! ${+functions[git-menu]} )); then
      _ws_warn "git-menu is not loaded, so the identity profile was not applied."
      _ws_dim "Apply it with: cd $destination_display && git-menu git-identity-switcher --switch $identity local"
      final_rc=1
    else
      # The Git suite owns identity configuration; it runs inside the new
      # repository in a subshell, so this shell keeps its directory.
      ( builtin cd -q -- "$destination" \
        && git-menu git-identity-switcher --switch "$identity" local ) \
        || identity_rc=$?
      if (( identity_rc != 0 )); then
        _ws_error "The identity profile was not applied (status $identity_rc); the clone is kept."
        _ws_dim "Retry with: cd $destination_display && git-menu git-identity-switcher --switch $identity local"
        final_rc=1
      fi
    fi
  fi
  (( final_rc == 0 )) || _ws_mark_partial
  print -r -- "$destination"
  return $final_rc
}

typeset -g _WS_CLONE_SOURCED=1
