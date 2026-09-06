#!/usr/bin/env zsh
# =============================================================================
# WS Create: create a new workspace with isolated identity, SSH key, gitconfig
# =============================================================================
#
# Loaded by ws-menu.zsh after ws-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_WS_CREATE_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_ws_create_ensure_owned_config() {
  emulate -L zsh

  local file_path="${1:-}"
  local parent_dir="${file_path:h}"
  REPLY=""
  _ws_directory_fingerprint "$parent_dir" || return 1

  if [[ -e "$file_path" || -L "$file_path" ]]; then
    _ws_owned_file_fingerprint "$file_path" || return 1
    return 0
  fi

  zmodload zsh/system 2>/dev/null || return 1
  local -i config_fd=-1
  sysopen -w -o creat,excl,nofollow,cloexec -m 600 \
    -u config_fd -- "$file_path" 2>/dev/null || return 1
  exec {config_fd}>&-
  _ws_owned_file_fingerprint "$file_path"
}

# A deliberately small passive lexer for ssh_config values. It accepts plain
# arguments and double quotes, never shell expansion or command evaluation.
_ws_create_ssh_words() {
  emulate -L zsh
  local value="$1" word="" char="" escaped=""
  local -i quoted=0 started=0 index=0
  reply=()
  for (( index=1; index<=${#value}; index++ )); do
    char="${value[index]}"
    case "$char" in
      '"') quoted=$(( !quoted )); started=1 ;;
      '\')
        (( ++index <= ${#value} )) || return 1
        escaped="${value[index]}"
        [[ "$escaped" == '"' || "$escaped" == '\' ]] || return 1
        word+="$escaped"; started=1
        ;;
      '#')
        if (( quoted || started )); then word+="$char"; else break; fi
        ;;
      ' '|$'\t')
        if (( quoted )); then
          word+="$char"
        elif (( started )); then
          reply+=("$word"); word=""; started=0
        fi
        ;;
      *) word+="$char"; started=1 ;;
    esac
  done
  (( quoted == 0 )) || return 1
  (( started )) && reply+=("$word")
  return 0
}

# Sets reply to alias state, config fingerprint, and SSH-directory fingerprint.
# This is a bounded check of the user file, not an effective SSH configuration
# evaluator: Include/Match and dynamic routing require manual review. SSH -G
# is deliberately avoided because Match exec can execute commands even there.
_ws_create_ssh_alias_plan() {
  emulate -L zsh
  setopt extendedglob
  local config="$1" alias_name="$2" hostname="$3" key_path="$4"
  local directory="${config:h}" directory_fingerprint=missing
  local REPLY="" config_fingerprint=missing
  if [[ -e "$directory" || -L "$directory" ]]; then
    _ws_directory_fingerprint "$directory" || return 1
    directory_fingerprint="$REPLY"
  fi
  if [[ ! -e "$config" && ! -L "$config" ]]; then
    reply=(absent missing "$directory_fingerprint")
    return 0
  fi
  _ws_owned_file_fingerprint "$config" || return 1
  config_fingerprint="$REPLY"
  local -A metadata=()
  zstat -LH metadata "$config" 2>/dev/null || return 1
  (( metadata[size] <= 1024 * 1024 )) || return 1
  local content=""
  content=$(command head -c 1048577 -- "$config" 2>/dev/null) || return 1
  [[ "$content" != *$'\0'* ]] || return 1
  local -a lines=("${(@f)content}")
  (( ${#lines[@]} <= 4096 )) || return 1
  local -A values=()
  local -i active=1 explicit_blocks=0 identities=0
  local line="" keyword="" value="" pattern="" plain_pattern=""
  reply=()
  for line in "${lines[@]}"; do
    (( ${#line} <= 16384 )) || return 1
    line="${line%$'\r'}"
    line="${line##[[:blank:]]#}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "${line//$'\t'/}" != *[[:cntrl:]]* ]] || return 1
    keyword="${line%%[[:blank:]=]*}"
    [[ "$keyword" == [A-Za-z]## ]] || return 1
    value="${line#"$keyword"}"
    value="${value##[[:blank:]]#}"
    if [[ "$value" == '='* ]]; then
      value="${value#=}"; value="${value##[[:blank:]]#}"
    fi
    keyword="${keyword:l}"
    case "$keyword" in
      include|match) return 1 ;;
      host)
        _ws_create_ssh_words "$value" || return 1
        (( ${#reply[@]} > 0 )) || return 1
        local -i matched=0 negated=0 explicit=0
        for pattern in "${reply[@]}"; do
          plain_pattern="${pattern#!}"
          [[ -n "$plain_pattern" \
            && "$plain_pattern" != *[^A-Za-z0-9._*?-]* ]] || return 1
          if [[ "$alias_name" == ${~plain_pattern} ]]; then
            if [[ "$pattern" == !* ]]; then
              negated=1
            else
              matched=1
              [[ "$pattern" == "$alias_name" ]] && explicit=1
            fi
          fi
        done
        active=$(( matched && !negated ))
        (( active && explicit )) && (( ++explicit_blocks ))
        (( explicit_blocks <= 1 )) || return 1
        ;;
      hostname|user|identityfile|identitiesonly|canonicalizehostname|proxycommand|proxyjump|certificatefile)
        (( active )) || continue
        _ws_create_ssh_words "$value" || return 1
        (( ${#reply[@]} == 1 )) || return 1
        value="${reply[1]}"
        case "$keyword" in
          identityfile)
            [[ "$value" != *'${'* ]] || return 1
            local percent_marker=$'\1'
            value="${value//\%\%/$percent_marker}"
            [[ "$value" != *'%'* ]] || return 1
            value="${value//$percent_marker/%}"
            [[ "$value" == '~/'* ]] && value="$HOME/${value#\~/}"
            [[ "$value" == "$key_path" ]] || return 1
            (( ++identities == 1 )) || return 1
            ;;
          hostname|user|identitiesonly)
            [[ "$keyword" == identitiesonly ]] && value="${value:l}"
            (( ${+values[$keyword]} )) || values[$keyword]="$value"
            ;;
          canonicalizehostname) [[ "${value:l}" == no ]] || return 1 ;;
          *) [[ "$value" == none ]] || return 1 ;;
        esac
        ;;
    esac
  done
  [[ "${values[hostname]-$hostname}" == "$hostname" \
    && "${values[user]-git}" == git \
    && "${values[identitiesonly]-yes}" == yes ]] || return 1
  local alias_state=absent
  if (( explicit_blocks )); then
    [[ "${values[hostname]-}" == "$hostname" \
      && "${values[user]-}" == git \
      && "${values[identitiesonly]-}" == yes ]] \
      && (( identities == 1 )) || return 1
    alias_state=compatible
  else
    (( identities == 0 )) || return 1
  fi
  _ws_owned_file_fingerprint "$config" \
    && [[ "$REPLY" == "$config_fingerprint" ]] \
    && _ws_directory_fingerprint "$directory" \
    && [[ "$REPLY" == "$directory_fingerprint" ]] || return 1
  reply=("$alias_state" "$config_fingerprint" "$directory_fingerprint")
}

# =============================================================================
# WORKSPACE CREATION
# =============================================================================

ws-create() {
  local REPLY=""
  _ws_parse_no_args ws-create \
    "Interactively create one workspace, identity, SSH key, alias, and Git route." \
    "$@" || return 2
  [[ "$REPLY" == "help" ]] && return 0
  _tk_check_deps git ssh-keygen fzf || return 1
  _ws_validate_base_dir || return $?

  _tk_header "Create New Workspace"

  # --- Step 1: Platform ---
  _tk_info "Step 1/5: Select platform"
  local platform=""
  local -i fzf_rc=0
  _ws_fzf_capture \
    --height=15% --layout=reverse --border \
    --prompt="Platform > " \
    < <(printf "%s\n" "github" "gitlab") || fzf_rc=$?
  platform="$REPLY"
  if (( fzf_rc != 0 )); then
    if _ws_fzf_rc_is_cancel "$fzf_rc"; then
      _tk_info "Cancelled."
      return 0
    fi
    _tk_error "Platform selection failed (status $fzf_rc)."
    return 1
  fi
  [[ -z "$platform" ]] && { _tk_info "Cancelled."; return 0; }
  [[ "$platform" == "github" || "$platform" == "gitlab" ]] || {
    _tk_error "Invalid platform selection."
    return 2
  }

  # --- Step 2: Hostname (GitLab only) ---
  local hostname=""
  if [[ "$platform" == "github" ]]; then
    hostname="github.com"
  else
    _tk_info "Step 2/5: GitLab hostname"
    print -u2 -nr -- "➜ Hostname [gitlab.com]: "
    local custom_host=""
    read -r custom_host
    hostname="${custom_host:-gitlab.com}"
    [[ "$hostname" =~ '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' \
      && "$hostname" != *..* ]] || {
      _tk_error "Invalid GitLab hostname."
      return 2
    }
  fi

  # --- Step 3: Identity name ---
  _tk_info "Step 3/5: Identity name (e.g. personal, acme-corp, client-x)"
  _tk_dim "This becomes your SSH alias (${platform}-<identity>) and directory name."
  print -u2 -nr -- "➜ Identity: "
  local identity=""
  read -r identity
  if [[ -z "$identity" ]]; then
    _tk_error "Identity name is required."
    return 1
  fi
  # Sanitize: lowercase, replace spaces with dashes
  identity="${identity:l}"
  identity="${identity// /-}"
  [[ "$identity" != "." && "$identity" != ".." && "$identity" != -* \
    && "$identity" =~ '^[a-z0-9][a-z0-9._-]*$' ]] || {
    _tk_error "Identity must use lowercase letters, numbers, dots, underscores, or dashes."
    return 2
  }

  _ws_resolve_workspace "$platform/$identity" || return $?
  local ws_dir="$REPLY"
  if [[ -e "$ws_dir" || -L "$ws_dir" ]]; then
    _tk_error "Workspace '$platform/$identity' already exists."
    return 1
  fi

  local host_alias="${platform}-${identity}"
  local key_path="$ws_dir/.ssh/id_ed25519"
  local home_ssh_dir="$HOME/.ssh" ssh_config="$HOME/.ssh/config"
  [[ "$key_path" != *'${'* ]] || {
    _tk_error "The workspace key path contains unsupported SSH environment syntax."
    return 1
  }
  local -a reply=()
  _ws_create_ssh_alias_plan "$ssh_config" "$host_alias" "$hostname" "$key_path" || {
    _tk_error "SSH alias '$host_alias' conflicts with existing or ambiguous configuration."
    _tk_info "Review ~/.ssh/config before creating this workspace. No files were created."
    return 1
  }
  local ssh_alias_state="${reply[1]}"
  local ssh_config_before="${reply[2]}" ssh_dir_before="${reply[3]}"

  # --- Step 4: Git identity ---
  _tk_info "Step 4/5: Git identity for this workspace"
  _tk_dim "This is what appears in your commits for repos inside this workspace."

  local git_name="" git_email="" git_gpgkey=""
  local -a profile_options=()
  local pk=""
  if (( ${#ZDX_GIT_IDENTITIES[@]} > 0 )); then
    for pk in "${(k)ZDX_GIT_IDENTITIES[@]}"; do
      local profile_val="${ZDX_GIT_IDENTITIES[$pk]}"
      local name="" email=""
      local item="" key="" val=""
      for item in ${(s:;:)profile_val}; do
        key="${item%%|*}"
        val="${item#*|}"
        [[ "$key" == "Name" ]] && name="$val"
        [[ "$key" == "Email" ]] && email="$val"
      done
      profile_options+=("$pk|$name|$email")
    done
  fi

  if (( ${#profile_options[@]} > 0 )); then
    local -a menu_items=()
    local item="" rest="" pname="" pemail="" pkey=""
    for item in "${profile_options[@]}"; do
      pkey="${item%%|*}"
      rest="${item#*|}"
      pname="${rest%%|*}"
      pemail="${rest#*|}"
      menu_items+=("👤 Profile: $pkey ($pname <$pemail>)")
    done
    menu_items+=("✏️  Custom (Enter manually)")

    local selected_choice=""
    fzf_rc=0
    _ws_fzf_capture \
      --height=25% --layout=reverse --border \
      --prompt="Select profile or manual > " \
      < <(printf "%s\n" "${menu_items[@]}") || fzf_rc=$?
    selected_choice="$REPLY"
    if (( fzf_rc != 0 )); then
      if _ws_fzf_rc_is_cancel "$fzf_rc"; then
        _tk_info "Cancelled."
        return 0
      fi
      _tk_error "Git identity selection failed (status $fzf_rc)."
      return 1
    fi
    [[ -z "$selected_choice" ]] && {
      _tk_info "Cancelled."
      return 0
    }

    if [[ "$selected_choice" != "✏️  Custom (Enter manually)" ]]; then
      local sel_key="${selected_choice#👤 Profile: }"
      sel_key="${sel_key%% \(*}"

      local pval="${ZDX_GIT_IDENTITIES[$sel_key]}"
      for item in ${(s:;:)pval}; do
        key="${item%%|*}"
        val="${item#*|}"
        [[ "$key" == "Name" ]] && git_name="$val"
        [[ "$key" == "Email" ]] && git_email="$val"
        [[ "$key" == "GpgKey" ]] && git_gpgkey="$val"
      done
      _tk_info "Imported Git identity from profile: $sel_key ($git_name <$git_email>)"
    fi
  fi

  # Fallback to manual prompt if git_name or git_email is empty
  if [[ -z "$git_name" || -z "$git_email" ]]; then
    local global_name="" global_email=""
    global_name=$(git config --global user.name 2>/dev/null)
    global_email=$(git config --global user.email 2>/dev/null)

    _tk_dim "(e.g. \"Jane Doe\", \"Acme Team\")"
    if [[ -n "$global_name" ]]; then
      print -u2 -nr -- "➜ user.name [$global_name]: "
    else
      print -u2 -nr -- "➜ user.name: "
    fi
    read -r git_name
    [[ -z "$git_name" && -n "$global_name" ]] && git_name="$global_name"
    [[ -z "$git_name" ]] && { _tk_error "Name is required."; return 1; }

    _tk_dim "(should match an email registered on $hostname)"
    if [[ -n "$global_email" ]]; then
      print -u2 -nr -- "➜ user.email [$global_email]: "
    else
      print -u2 -nr -- "➜ user.email: "
    fi
    read -r git_email
    [[ -z "$git_email" && -n "$global_email" ]] && git_email="$global_email"
    [[ -z "$git_email" ]] && { _tk_error "Email is required."; return 1; }
  fi

  # --- Step 5: SSH Key ---
  _tk_info "Step 5/5: SSH Key"

  local key_action=""
  # Check if there are existing keys in ~/.ssh
  local existing_keys=()
  local -A allowed_keys=()
  local f=""
  for f in "$HOME"/.ssh/id_*(N); do
    [[ "$f" == *.pub ]] && continue
    [[ -f "$f" && ! -L "$f" && -O "$f" ]] || continue
    existing_keys+=("$f")
    allowed_keys[$f]=1
  done

  if (( ${#existing_keys[@]} > 0 )); then
    fzf_rc=0
    _ws_fzf_capture \
      --height=15% --layout=reverse --border \
      --prompt="SSH Key > " \
      < <(printf "%s\n" \
        "Generate new key" "Import existing key from ~/.ssh") || fzf_rc=$?
    key_action="$REPLY"
    if (( fzf_rc != 0 )); then
      if _ws_fzf_rc_is_cancel "$fzf_rc"; then
        _tk_info "Cancelled."
        return 0
      fi
      _tk_error "SSH key action selection failed (status $fzf_rc)."
      return 1
    fi
  else
    key_action="Generate new key"
  fi
  [[ -z "$key_action" ]] && { _tk_info "Cancelled."; return 0; }
  [[ "$key_action" == "Generate new key" \
    || "$key_action" == "Import existing key from ~/.ssh" ]] || {
    _tk_error "Invalid SSH key action."
    return 2
  }

  local selected_key=""
  if [[ "$key_action" == "Import existing key from ~/.ssh" ]]; then
    fzf_rc=0
    _ws_fzf_capture \
      --height=30% --layout=reverse --border \
      --prompt="Select key to import > " \
      < <(printf "%s\n" "${existing_keys[@]}") || fzf_rc=$?
    selected_key="$REPLY"
    if (( fzf_rc != 0 )); then
      if _ws_fzf_rc_is_cancel "$fzf_rc"; then
        _tk_info "Cancelled."
        return 0
      fi
      _tk_error "SSH key selection failed (status $fzf_rc)."
      return 1
    fi
    [[ -z "$selected_key" ]] && {
      _tk_info "Cancelled."
      return 0
    }
    if (( ! ${+allowed_keys[$selected_key]} )); then
      _tk_error "Invalid SSH key selection."
      return 2
    fi
  fi

  # --- Create workspace ---
  _ws_create_ssh_alias_plan "$ssh_config" "$host_alias" "$hostname" "$key_path" \
    && [[ "${reply[1]}" == "$ssh_alias_state" \
      && "${reply[2]}" == "$ssh_config_before" \
      && "${reply[3]}" == "$ssh_dir_before" ]] || {
    _tk_error "SSH configuration changed while workspace creation was planned."
    return 1
  }
  _tk_info "Creating workspace: $platform/$identity"
  command mkdir -p -- "$ws_dir/.ssh" || {
    _tk_error "Could not create workspace directory."
    return 1
  }
  command chmod 700 "$ws_dir/.ssh" || return 1
  _ws_resolve_workspace "$platform/$identity" || return $?
  [[ "$REPLY" == "$ws_dir" ]] || {
    _tk_error "Workspace target changed during creation."
    return 1
  }

  # Save hostname for GitLab (only if not default)
  if [[ "$platform" == "gitlab" && "$hostname" != "gitlab.com" ]]; then
    print -r -- "$hostname" > "$ws_dir/.ws-hostname" || return 1
  fi

  # Create .gitconfig
  : > "$ws_dir/.gitconfig" || return 1
  command chmod 600 "$ws_dir/.gitconfig" || return 1
  git config --file "$ws_dir/.gitconfig" user.name "$git_name" \
    && git config --file "$ws_dir/.gitconfig" user.email "$git_email" \
    || {
      _tk_error "Could not write the workspace Git identity."
      return 1
    }

  if [[ -n "$git_gpgkey" ]]; then
    git config --file "$ws_dir/.gitconfig" user.signingkey "$git_gpgkey" \
      && git config --file "$ws_dir/.gitconfig" commit.gpgSign true \
      || {
        _tk_error "Could not write the workspace signing configuration."
        return 1
      }
    _tk_success "Created .gitconfig with GPG signing (name=$git_name, email=$git_email, signingkey=$git_gpgkey)"
  else
    _tk_success "Created .gitconfig (name=$git_name, email=$git_email)"
  fi

  # Handle SSH key
  if [[ "$key_action" == "Generate new key" ]]; then
    ssh-keygen -t ed25519 -C "$git_email" -f "$key_path" -N "" -q \
      || {
        _tk_error "Could not generate the workspace SSH key."
        return 1
      }
    _tk_success "Generated new SSH key"
  else
    # Import existing key
    command cp -- "$selected_key" "$key_path" || {
      _tk_error "Could not import the selected private key."
      return 1
    }
    command cp -- "${selected_key}.pub" "${key_path}.pub" 2>/dev/null \
      || ssh-keygen -y -f "$key_path" >"${key_path}.pub" 2>/dev/null \
      || {
        _tk_error "Could not derive a public key from the selected key."
        return 1
      }
    _tk_success "Imported key from $selected_key"
    _tk_warn "Note: the original key at $selected_key still exists."
  fi

  command chmod 600 "$key_path" || return 1
  command chmod 644 "${key_path}.pub" 2>/dev/null || return 1

  # --- Update ~/.ssh/config ---
  _ws_create_ssh_alias_plan "$ssh_config" "$host_alias" "$hostname" "$key_path" \
    && [[ "${reply[1]}" == "$ssh_alias_state" \
      && "${reply[2]}" == "$ssh_config_before" \
      && "${reply[3]}" == "$ssh_dir_before" ]] || {
    _tk_error "SSH configuration changed before routing publication."
    return 1
  }
  if [[ -e "$home_ssh_dir" || -L "$home_ssh_dir" ]]; then
    _ws_directory_fingerprint "$home_ssh_dir" || {
      _tk_error "Refusing an unsafe or foreign-owned ~/.ssh directory."
      return 1
    }
  else
    command mkdir -m 700 -- "$home_ssh_dir" || {
      _tk_error "Could not create ~/.ssh safely."
      return 1
    }
  fi
  command chmod 700 "$home_ssh_dir" || return 1
  _ws_directory_fingerprint "$home_ssh_dir" || {
    _tk_error "Refusing an unsafe or foreign-owned ~/.ssh directory."
    return 1
  }
  local ssh_dir_fingerprint="$REPLY"
  _ws_create_ensure_owned_config "$ssh_config" || {
    _tk_error "Refusing unsafe SSH configuration file."
    return 1
  }
  local ssh_config_fingerprint="$REPLY"
  _ws_directory_fingerprint "$ws_dir" || {
    _tk_error "Workspace target changed before routing publication."
    return 1
  }
  local workspace_fingerprint="$REPLY"

  if [[ "$ssh_alias_state" == compatible ]]; then
    _tk_info "Reusing the verified SSH alias '$host_alias' in ~/.ssh/config."
  else
    local temp_ssh_config=""
    temp_ssh_config=$(mktemp "$home_ssh_dir/.zdx-ws-ssh.XXXXXX") || {
      _tk_error "Could not create a temporary SSH configuration."
      return 1
    }
    {
      command cp -- "$ssh_config" "$temp_ssh_config" || return 1
      command chmod 600 "$temp_ssh_config" || return 1
      {
        print -r -- ""
        print -r -- "# BEGIN ws:${platform}/${identity}"
        print -r -- "Host ${host_alias}"
        print -r -- "    HostName $hostname"
        print -r -- "    User git"
        local quoted_key="" key_character=""
        for key_character in "${(@s::)key_path}"; do
          case "$key_character" in
            '"'|'\') quoted_key+="\\$key_character" ;;
            '%') quoted_key+='%%' ;;
            *) quoted_key+="$key_character" ;;
          esac
        done
        print -r -- "    IdentityFile \"$quoted_key\""
        print -r -- "    IdentitiesOnly yes"
        print -r -- "# END ws:${platform}/${identity}"
      } >> "$temp_ssh_config" || return 1
      _ws_owned_file_fingerprint "$ssh_config" \
        && [[ "$REPLY" == "$ssh_config_fingerprint" ]] \
        && _ws_directory_fingerprint "$home_ssh_dir" \
        && [[ "$REPLY" == "$ssh_dir_fingerprint" ]] \
        && _ws_directory_fingerprint "$ws_dir" \
        && [[ "$REPLY" == "$workspace_fingerprint" ]] || {
        _tk_error \
          "SSH configuration or workspace state changed before publication."
        return 1
      }
      command mv -- "$temp_ssh_config" "$ssh_config" || return 1
      temp_ssh_config=""
    } always {
      [[ -n "$temp_ssh_config" && -f "$temp_ssh_config" ]] \
        && command rm -f -- "$temp_ssh_config"
    }
    _tk_success "Added Host '$host_alias' to ~/.ssh/config"
  fi

  # --- Update ~/.gitconfig with includeIf ---
  local global_gitconfig="$HOME/.gitconfig"
  local include_path="$ws_dir/.gitconfig"
  local gitdir_pattern="$ws_dir/"
  local include_key="includeIf.gitdir:${gitdir_pattern}.path"
  _ws_create_ensure_owned_config "$global_gitconfig" || {
    _tk_error "Refusing unsafe global Git configuration file."
    return 1
  }
  local gitconfig_fingerprint="$REPLY"
  local temp_gitconfig=""
  temp_gitconfig=$(mktemp "${global_gitconfig:h}/.zdx-ws-git.XXXXXX") || {
    _tk_error "Could not create a temporary Git configuration."
    return 1
  }
  local -i include_added=0
  {
    command cp -- "$global_gitconfig" "$temp_gitconfig" || return 1
    command chmod 600 "$temp_gitconfig" || return 1
    local existing_include_values=""
    local -i include_query_rc=0
    existing_include_values=$(command git config --file "$temp_gitconfig" \
      --get-all "$include_key" 2>/dev/null) || include_query_rc=$?
    case "$include_query_rc" in
      0)
        local -a include_values=("${(f)existing_include_values}")
        if (( ${#include_values[@]} != 1 )) \
          || [[ "${include_values[1]}" != "$include_path" ]]; then
          _tk_error \
            "A conflicting includeIf entry already exists for this workspace."
          return 1
        fi
        ;;
      1)
        command git config --file "$temp_gitconfig" \
          "$include_key" "$include_path" 2>/dev/null || {
          _tk_error "Could not add includeIf to ~/.gitconfig"
          return 1
        }
        include_added=1
        ;;
      *)
        _tk_error \
          "Could not parse ~/.gitconfig safely; workspace creation is incomplete."
        return 1
        ;;
    esac
    _ws_owned_file_fingerprint "$global_gitconfig" \
      && [[ "$REPLY" == "$gitconfig_fingerprint" ]] \
      && _ws_directory_fingerprint "$ws_dir" \
      && [[ "$REPLY" == "$workspace_fingerprint" ]] || {
      _tk_error \
        "Global Git configuration or workspace state changed before publication."
      return 1
    }
    if (( include_added )); then
      command mv -- "$temp_gitconfig" "$global_gitconfig" || return 1
      temp_gitconfig=""
    fi
  } always {
    [[ -n "$temp_gitconfig" && -f "$temp_gitconfig" ]] \
      && command rm -f -- "$temp_gitconfig"
  }
  if (( include_added )); then
    _tk_success "Added includeIf to ~/.gitconfig"
  else
    _tk_warn "includeIf for '$ws_dir/' already exists in ~/.gitconfig — skipping"
  fi

  # --- Summary ---
  print -u2 -r -- ""
  print -u2 -r -- "────────────────────────────────────────"
  print -u2 -r -- "  Workspace created successfully!"
  print -u2 -r -- "────────────────────────────────────────"
  print -u2 -r -- ""
  _tk_label "Platform"   "$platform ($hostname)"
  _tk_label "Identity"   "$identity"
  _tk_label "Directory"  "$ws_dir"
  _tk_label "Git User"   "$git_name <$git_email>"
  _tk_label "SSH Alias"  "$host_alias"
  print -u2 -r -- ""
  print -u2 -r -- "  📋 Public key (copy this to $hostname):"
  print -u2 -r -- ""
  local public_key=""
  _ws_read_workspace_public_key "$ws_dir" || {
    _tk_error "The workspace public key could not be revalidated."
    return 1
  }
  public_key="$REPLY"
  print -u2 -r -- "  $public_key"
  print -u2 -r -- ""
  print -u2 -r -- "  To clone repos use:"
  print -u2 -r -- "    cd $ws_dir"
  print -u2 -r -- "    git clone git@${host_alias}:owner/repo.git"
  print -u2 -r -- ""

  # Offer to test connection
  local -i create_rc=0
  if _tk_confirm "Test SSH connection to $hostname now?"; then
    _tk_info "Testing: ssh -T git@${host_alias}"
    if ! _ws_check_deps ssh; then
      create_rc=1
    else
      local connect_timeout="${WS_SSH_CONNECT_TIMEOUT:-10}"
      if [[ "$connect_timeout" == <-> \
        && ${#connect_timeout} -le 2 ]] \
        && (( connect_timeout >= 1 && connect_timeout <= 60 )); then
        local -i ssh_probe_rc=0
        _ws_ssh_probe "$host_alias" "$connect_timeout" \
          "$(( connect_timeout + 5 ))" || ssh_probe_rc=$?
        case "$ssh_probe_rc" in
          0)
            _tk_success "SSH authentication accepted for '$host_alias'."
            ;;
          124)
            _tk_error \
              "SSH connection test timed out; the workspace was still created."
            create_rc=124
            ;;
          *)
            _tk_error \
              "SSH authentication was not accepted; the workspace was still created."
            create_rc=$ssh_probe_rc
            ;;
        esac
      else
        _tk_error \
          "WS_SSH_CONNECT_TIMEOUT must be between 1 and 60 seconds."
        create_rc=2
      fi
    fi
    print -u2 -r -- ""
  fi

  # Offer to cd into workspace
  if _tk_confirm "cd into $ws_dir now?"; then
    cd "$ws_dir" || { _tk_error "Could not cd into $ws_dir"; return 1; }
    _tk_success "You are now in $ws_dir"
  fi
  return $create_rc
}

typeset -g _WS_CREATE_SOURCED=1
