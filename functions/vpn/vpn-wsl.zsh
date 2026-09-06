#!/usr/bin/env zsh
# =============================================================================
# VPN WSL: IPv6 stripping and DNS leak hardening for WireGuard under WSL
# =============================================================================
#
# Loaded by vpn-menu.zsh after vpn-common.zsh.
# Safe to re-source; defines functions only.
#
# WSL routes WireGuard traffic through a Windows relay that ignores the tunnel
# resolver, so DNS leaks unless /etc/resolv.conf is pinned while the tunnel is
# up. The hooks installed here run as root on every tunnel transition, which is
# why every value written into them is validated rather than escaped.
#

if [[ -n "${_VPN_WSL_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# Bumping the version invalidates older hooks and triggers a fresh rewrite.
typeset -g _VPN_DNS_HOOK_SENTINEL='# zdx: wsl-dns-hooks v1'

typeset -g VPN_DNS_FALLBACK_PRIMARY="${VPN_DNS_FALLBACK_PRIMARY:-1.1.1.1}"
typeset -g VPN_DNS_FALLBACK_SECONDARY="${VPN_DNS_FALLBACK_SECONDARY:-9.9.9.9}"

_vpn_should_apply_wsl_ipv6_fix() {
  [[ -n "${WSL_DISTRO_NAME-}" ]] || [[ "${VPN_MENU_WSL_IPV6_FIX:-}" == 1 ]]
}

# --- resolv.conf preflight --------------------------------------------------

_vpn_test_resolv_conf() {
  local target="/etc/resolv.conf"

  if [[ ! -e "$target" ]]; then
    _vpn_error "$target does not exist."
    return 1
  fi

  if [[ -L "$target" ]]; then
    _vpn_dim \
      "$target is a symlink to $(command readlink -f -- "$target" 2>/dev/null)."
  fi

  [[ -w "$target" ]] && return 0

  if command -v lsattr &>/dev/null; then
    local attrs
    attrs=$(command lsattr "$target" 2>/dev/null | command awk '{print $1}')
    if [[ "$attrs" == *i* ]]; then
      _vpn_dim "$target carries the immutable flag (chattr +i)."
      if ! command -v chattr &>/dev/null; then
        _vpn_warn "chattr is missing, so $target attributes cannot be changed."
        return 1
      fi
      return 0
    fi
  fi

  _vpn_sudo_probe test -w "$target" && return 0

  _vpn_error "No write access to $target."
  return 1
}

# --- DNS leak hardening -----------------------------------------------------

# Builds the PostUp/PostDown hook lines for a validated resolver set.
# stdout: the hook block, one line per record.
_vpn_wsl_hook_lines() {
  local tunnel_dns="$1"
  local primary="$2"
  local secondary="$3"

  # Every operand reaching this point has been validated as an IP literal, so
  # the generated sh -c body cannot carry shell metacharacters.
  print -r -- "$_VPN_DNS_HOOK_SENTINEL"
  print -r -- "PostUp = sh -c 'chattr -i /etc/resolv.conf 2>/dev/null || true; printf \"nameserver ${tunnel_dns}\\n\" > /etc/resolv.conf; chattr +i /etc/resolv.conf 2>/dev/null || true'"
  print -r -- "PostDown = sh -c 'chattr -i /etc/resolv.conf 2>/dev/null || true; printf \"nameserver ${primary}\\nnameserver ${secondary}\\n\" > /etc/resolv.conf; chattr +i /etc/resolv.conf 2>/dev/null || true'"
  print -r -- ""
}

# Checks whether an existing sentinel is the exact complete hook block this
# suite owns. Status 0 means valid and idempotent, 1 means absent, and 2 means a
# sentinel-like or incomplete block that must be reviewed instead of trusted.
_vpn_wsl_existing_hook_state() {
  local content="$1"
  REPLY=""

  local -a lines=("${(@f)content}")
  local -i index sentinel_count=0 sentinel_index=0
  for (( index = 1; index <= ${#lines[@]}; ++index )); do
    if [[ "${lines[index]}" == "$_VPN_DNS_HOOK_SENTINEL" ]]; then
      (( ++sentinel_count ))
      sentinel_index=$index
    fi
  done

  if (( sentinel_count == 0 )); then
    [[ "$content" == *"$_VPN_DNS_HOOK_SENTINEL"* ]] && return 2
    return 1
  fi
  (( sentinel_count == 1 && sentinel_index + 2 <= ${#lines[@]} )) || return 2

  local post_up="${lines[sentinel_index + 1]}"
  local up_prefix="PostUp = sh -c 'chattr -i /etc/resolv.conf 2>/dev/null || true; printf \"nameserver "
  local up_suffix="\\n\" > /etc/resolv.conf; chattr +i /etc/resolv.conf 2>/dev/null || true'"
  [[ "$post_up" == "$up_prefix"* && "$post_up" == *"$up_suffix" ]] || return 2

  local tunnel_dns="${post_up#$up_prefix}"
  tunnel_dns="${tunnel_dns%$up_suffix}"
  _vpn_validate_ip_literal "$tunnel_dns" || return 2

  local -a expected=("${(@f)$(_vpn_wsl_hook_lines \
    "$tunnel_dns" "$VPN_DNS_FALLBACK_PRIMARY" \
    "$VPN_DNS_FALLBACK_SECONDARY")}")
  (( ${#expected[@]} >= 3 )) || return 2
  [[ "${lines[sentinel_index]}" == "${expected[1]}" \
    && "${lines[sentinel_index + 1]}" == "${expected[2]}" \
    && "${lines[sentinel_index + 2]}" == "${expected[3]}" ]] || return 2

  REPLY="$tunnel_dns"
  return 0
}

# Patches a WireGuard profile so /etc/resolv.conf is pinned to the tunnel
# resolver while the tunnel is up and to public fallbacks while it is down.
#
#   Arguments: $1 absolute path to a .conf inside the profile directory.
#   Effects:   rewrites the profile through a temporary and an atomic install,
#              keeping a safety copy until wg-quick has parsed the result.
#   Status:    0 on success or when the profile is already hardened,
#              1 on any validation, permission, or parse failure.
_vpn_apply_wsl_dns_hooks() {
  local conf="${1:-}"
  [[ -n "$conf" ]] || return 1

  if ! _vpn_validate_ip_literal "$VPN_DNS_FALLBACK_PRIMARY" \
    || ! _vpn_validate_ip_literal "$VPN_DNS_FALLBACK_SECONDARY"; then
    _vpn_error "Each configured DNS fallback must be one plain IP address."
    return 1
  fi

  local config_dir
  config_dir=$(_vpn_config_dir_resolve) || return 1
  if [[ "${conf:a:h}" != "$config_dir" \
    || "${conf:a}" != "${conf:A}" \
    || "${conf:t}" != *.conf ]]; then
    _vpn_error "WSL hardening accepts only a direct profile in VPN_CONFIG_DIR."
    return 1
  fi
  local iface_name="${${conf:t}%.conf}"
  _vpn_validate_iface_name "$iface_name" || return 1

  _vpn_ensure_profile_access || return 1
  local directory_identity profile_fingerprint
  directory_identity=$(_vpn_config_dir_identity) || return 1
  profile_fingerprint=$(
    _vpn_profile_file_fingerprint "$conf" "$iface_name profile"
  ) || return 1

  # Profile size is bounded by the safe-file contract before materialization.
  local content
  if [[ -r "$conf" ]]; then
    content=$(command head -c "$_VPN_MAX_PROFILE_BYTES" -- "$conf" 2>/dev/null)
  else
    content=$(
      _vpn_sudo_probe head -c "$_VPN_MAX_PROFILE_BYTES" -- "$conf"
    ) || {
      _vpn_error "Could not read $conf."
      return 1
    }
  fi
  local current_fingerprint
  current_fingerprint=$(
    _vpn_profile_file_fingerprint "$conf" "$iface_name profile"
  ) || return 1
  [[ "$current_fingerprint" == "$profile_fingerprint" ]] || {
    _vpn_error "The profile changed while it was read."
    return 1
  }

  local -i existing_hook_status=0
  _vpn_wsl_existing_hook_state "$content" || existing_hook_status=$?
  case "$existing_hook_status" in
    0) return 0 ;;
    1) ;;
    *)
      _vpn_error \
        "The WSL DNS hook sentinel exists without its exact complete hook block."
      _vpn_info "Review the profile manually before applying hardening again."
      return 1
      ;;
  esac

  _vpn_check_wg_quick || {
    _vpn_error \
      "WSL DNS hardening needs wg-quick to validate the staged profile."
    return 1
  }
  _vpn_test_resolv_conf || return 1

  # The DNS value is written into a hook that root executes, so an unsafe value
  # is rejected outright rather than quoted.
  local declared_dns tunnel_dns
  declared_dns=$(print -r -- "$content" \
    | command sed -n 's/^[[:space:]]*DNS[[:space:]]*=[[:space:]]*//p' \
    | command head -1)
  declared_dns="${declared_dns%$'\r'}"

  if [[ -n "$declared_dns" ]]; then
    if ! tunnel_dns=$(_vpn_first_dns_entry "$declared_dns"); then
      _vpn_error "The profile's DNS value is not a plain list of IP addresses."
      _vpn_dim "Found: $(_vpn_display_escape "$declared_dns")"
      _vpn_info \
        "Refusing to write it into a root-executed hook. Fix the DNS line first."
      return 1
    fi
  else
    tunnel_dns="$VPN_DNS_FALLBACK_PRIMARY"
  fi

  local stage_dir stage_identity temp_file
  stage_dir=$(_vpn_make_private_temp_dir "zdx-vpn-wsl") || return 1
  stage_identity=$(
    _vpn_private_dir_identity "$stage_dir" "WSL staging directory"
  ) || return 1
  temp_file="${stage_dir}/${iface_name}.conf"

  {
    local -a lines=("${(@f)content}")
    local line
    local -i inserted=0
    local -a output=()

    for line in "${lines[@]}"; do
      # The declared DNS is replaced by the hooks, so drop the original line.
      if [[ "$line" =~ '^[[:space:]]*DNS[[:space:]]*=' ]]; then
        continue
      fi
      if (( ! inserted )) && [[ "$line" =~ '^[[:space:]]*\[Peer\]' ]]; then
        output+=("${(@f)$(_vpn_wsl_hook_lines \
          "$tunnel_dns" "$VPN_DNS_FALLBACK_PRIMARY" \
          "$VPN_DNS_FALLBACK_SECONDARY")}")
        inserted=1
      fi
      output+=("$line")
    done

    if (( ! inserted )); then
      _vpn_error "The profile has no [Peer] section; refusing to patch it."
      return 1
    fi

    print -rl -- "${output[@]}" > "$temp_file" || {
      _vpn_error "Could not stage the patched profile."
      return 1
    }
    command chmod 600 -- "$temp_file" 2>/dev/null || return 1

    if ! command grep -q '^\[Interface\]' "$temp_file" \
      || ! command grep -q '^\[Peer\]' "$temp_file"; then
      _vpn_error "WSL DNS hardening produced an invalid profile — aborted."
      return 1
    fi

    local staged_fingerprint
    staged_fingerprint=$(
      _vpn_user_file_fingerprint "$temp_file" "patched profile"
    ) || return 1

    # Parse the staged file before publication, so a bad transformation never
    # needs a rollback after touching the live profile.
    if ! command wg-quick strip "$temp_file" >/dev/null 2>&1; then
      _vpn_error \
        "wg-quick could not parse the patched profile; the original is unchanged."
      return 1
    fi

    _vpn_announce_privileged \
      "atomically install <validated WSL profile> as $conf"
    _vpn_ensure_sudo_access "Hardening the WireGuard profile" || return 1
    _vpn_atomic_install_staged "$temp_file" "$conf" \
      "$staged_fingerprint" "$profile_fingerprint" "$directory_identity" \
      "wsl-hooks"
  } always {
    if _vpn_assert_private_dir_identity \
      "$stage_dir" "WSL staging directory" "$stage_identity" 2>/dev/null; then
      [[ -f "$temp_file" && ! -L "$temp_file" ]] \
        && command rm -f -- "$temp_file" 2>/dev/null
      command rmdir -- "$stage_dir" 2>/dev/null
    else
      _vpn_warn "The WSL staging directory changed; refusing cleanup."
    fi
  }
}

# --- IPv6 stripping ---------------------------------------------------------

# WSL's relay cannot carry the IPv6 half of a dual-stack tunnel, so Address,
# DNS, and AllowedIPs lose their IPv6 entries. A one-time backup is kept.
_vpn_wsl_backup_once() {
  local source_file="$1"
  local backup_file="$2"
  local expected_source="$3"
  local directory_identity="$4"

  [[ "$(_vpn_profile_path_state "$backup_file")" == "missing" ]] || return 1
  _vpn_assert_config_dir_identity "$directory_identity" || return 1

  local temp_file=""
  temp_file=$(
    _vpn_privileged_temp_create "${source_file:h}" "wsl-backup"
  ) || return 1
  {
    _vpn_sudo_exec install -m 600 -o root -g root -- \
      "$source_file" "$temp_file" || return 1
    local current_source
    current_source=$(
      _vpn_profile_file_fingerprint "$source_file" "WSL source profile"
    ) || return 1
    [[ "$current_source" == "$expected_source" ]] || {
      _vpn_error "The profile changed while its WSL backup was staged."
      return 1
    }
    [[ "$(_vpn_profile_path_state "$backup_file")" == "missing" ]] || return 1
    _vpn_sudo_exec ln -- "$temp_file" "$backup_file" || return 1
    _vpn_sudo_exec rm -- "$temp_file" || {
      _vpn_sudo_exec rm -- "$backup_file" >/dev/null 2>&1
      return 1
    }
    temp_file=""
    [[ "$(_vpn_profile_path_state "$backup_file")" == "safe" ]]
  } always {
    _vpn_privileged_temp_cleanup "$temp_file" || true
  }
}

_vpn_fix_ipv6_config() {
  local iface="${1:-}"
  _vpn_check_wg_quick || return 1

  local conf_file
  conf_file=$(_vpn_conf_path "$iface") || return 1

  _vpn_ensure_profile_access || return 1
  [[ "$(_vpn_profile_path_state "$conf_file")" == "safe" ]] || return 1
  local directory_identity profile_fingerprint
  directory_identity=$(_vpn_config_dir_identity) || return 1
  profile_fingerprint=$(
    _vpn_profile_file_fingerprint "$conf_file" "$iface profile"
  ) || return 1

  local content
  if [[ -r "$conf_file" ]]; then
    content=$(
      command head -c "$_VPN_MAX_PROFILE_BYTES" -- "$conf_file" 2>/dev/null
    )
  else
    content=$(
      _vpn_sudo_probe head -c "$_VPN_MAX_PROFILE_BYTES" -- "$conf_file"
    ) || return 1
  fi
  local current_fingerprint
  current_fingerprint=$(
    _vpn_profile_file_fingerprint "$conf_file" "$iface profile"
  ) || return 1
  [[ "$current_fingerprint" == "$profile_fingerprint" ]] || {
    _vpn_error "The profile changed while IPv6 compatibility was planned."
    return 1
  }

  local -a lines=("${(@f)content}")
  local -a output=()
  local line key value
  local -i changed=0

  for line in "${lines[@]}"; do
    if [[ "$line" =~ '^[[:space:]]*(Address|DNS|AllowedIPs)[[:space:]]*=' ]]; then
      key="${line%%=*}"
      value="${line#*=}"

      local -a entries=("${(@s:,:)value}")
      local -a kept=()
      local entry trimmed
      for entry in "${entries[@]}"; do
        trimmed="${entry//[[:space:]]/}"
        [[ -n "$trimmed" ]] || continue
        # Drop IPv6 literals and the IPv6 default route.
        [[ "$trimmed" == *:* ]] && continue
        kept+=("$trimmed")
      done

      if (( ${#kept[@]} == 0 )); then
        _vpn_error \
          "WSL compatibility cannot retain an IPv4 value for ${key//[[:space:]]/}."
        return 1
      fi

      local rebuilt="${key}= ${(j:, :)kept}"
      [[ "$rebuilt" != "$line" ]] && changed=1
      output+=("$rebuilt")
      continue
    fi
    output+=("$line")
  done

  (( changed )) || return 0

  local backup_file
  backup_file=$(_vpn_backup_path "$iface") || return 1

  local backup_state backup_fingerprint=""
  backup_state=$(_vpn_profile_path_state "$backup_file")
  case "$backup_state" in
    safe)
      backup_fingerprint=$(
        _vpn_profile_file_fingerprint "$backup_file" "$iface backup"
      ) || return 1
      ;;
    missing) ;;
    *)
      _vpn_error "The WSL backup target is unsafe or unreadable."
      return 1
      ;;
  esac

  local stage_dir stage_identity temp_file
  stage_dir=$(_vpn_make_private_temp_dir "zdx-vpn-ipv6") || return 1
  stage_identity=$(
    _vpn_private_dir_identity "$stage_dir" "IPv6 staging directory"
  ) || return 1
  temp_file="${stage_dir}/${iface}.conf"

  {
    print -rl -- "${output[@]}" > "$temp_file" || return 1
    command chmod 600 -- "$temp_file" 2>/dev/null || return 1
    local staged_fingerprint
    staged_fingerprint=$(
      _vpn_user_file_fingerprint "$temp_file" "IPv6-stripped profile"
    ) || return 1

    if ! command wg-quick strip "$temp_file" >/dev/null 2>&1; then
      _vpn_error "wg-quick rejected the IPv6-stripped profile."
      return 1
    fi

    _vpn_announce_privileged \
      "atomically install <IPv6-stripped profile> as $conf_file"
    _vpn_ensure_sudo_access "Applying the WSL IPv6 tweak" || return 1

    if [[ "$backup_state" == "missing" ]]; then
      _vpn_wsl_backup_once "$conf_file" "$backup_file" \
        "$profile_fingerprint" "$directory_identity" || {
        _vpn_error "Could not create $backup_file; leaving the profile untouched."
        return 1
      }
    else
      current_fingerprint=$(
        _vpn_profile_file_fingerprint "$backup_file" "$iface backup"
      ) || return 1
      [[ "$current_fingerprint" == "$backup_fingerprint" ]] || {
        _vpn_error "The WSL backup changed while the tweak was prepared."
        return 1
      }
    fi

    _vpn_atomic_install_staged "$temp_file" "$conf_file" \
      "$staged_fingerprint" "$profile_fingerprint" "$directory_identity" \
      "wsl-ipv6" || {
      _vpn_error "Failed to apply the IPv6 tweak to $conf_file."
      return 1
    }
  } always {
    if _vpn_assert_private_dir_identity \
      "$stage_dir" "IPv6 staging directory" "$stage_identity" 2>/dev/null; then
      [[ -f "$temp_file" && ! -L "$temp_file" ]] \
        && command rm -f -- "$temp_file" 2>/dev/null
      command rmdir -- "$stage_dir" 2>/dev/null
    else
      _vpn_warn "The IPv6 staging directory changed; refusing cleanup."
    fi
  }
}

typeset -g _VPN_WSL_SOURCED=1
