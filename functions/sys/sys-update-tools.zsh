#!/usr/bin/env zsh
# =============================================================================
# System Update Tools: SDK, runtime, and CLI updaters
# =============================================================================
#
# Loaded by sys-menu.zsh after sys-common.zsh and the platform adapters.
# Safe to re-source; defines functions only.
#

if [[ -n "${_SYS_UPDATE_TOOLS_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# REPLY: the first dotted version printed by a bounded version command. The
# program resolves to its external path, so no shell function can stand in.
# Usage: _sys_update_probe_version <seconds> <program> [arguments...]
_sys_update_probe_version() {
  emulate -L zsh
  local seconds="${1:-3}" program="${2:-}" output="" line=""
  local -i probe_rc=0
  local MATCH MBEGIN MEND
  local -a match=() mbegin=() mend=()
  REPLY=""
  shift 2 2>/dev/null || return 2
  program=$(builtin whence -p -- "$program" 2>/dev/null) || return 1
  output=$(_sys_run_bounded_probe "$seconds" 65536 "$program" "$@" \
    </dev/null 2>/dev/null) || probe_rc=$?
  (( probe_rc == 0 )) || return "$probe_rc"
  line="${output%%$'\n'*}"
  [[ "$line" != *[[:cntrl:]]* \
    && "$line" =~ '[0-9]+([.][0-9]+)+([-+][0-9A-Za-z.]+)?' ]] || return 1
  REPLY="$MATCH"
}

# Reports a version comparison as the step result: equal versions are
# current, different ones updated, and a missing version leaves only done.
# Usage: _sys_update_report_version <subject> <before> <after> [owner]
_sys_update_report_version() {
  local subject="${1:-}" before="${2:-}" after="${3:-}" owner="${4:-}"
  local via="${owner:+ through $owner}"
  if [[ -z "$after" ]]; then
    _sys_report_result done "" "$subject update completed$via."
  elif [[ -z "$before" ]]; then
    _sys_report_result done "now $after" \
      "$subject update completed$via (now $after)."
  elif [[ "$before" == "$after" ]]; then
    _sys_report_result current "$after" \
      "$subject is already up to date ($after)."
  else
    _sys_report_result updated "$before → $after" \
      "$subject updated$via: $before → $after."
  fi
}

# Prints "name<TAB>version" records for installed pipx applications.
_sys_update_pipx_inventory() {
  emulate -L zsh
  local output="" line env_program="" MATCH MBEGIN MEND
  local -a match=() mbegin=() mend=()
  env_program=$(builtin whence -p env 2>/dev/null) || return 1
  output=$(_sys_run_bounded_probe 30 262144 \
    "$env_program" PIP_NO_INPUT=1 pipx list --short </dev/null 2>/dev/null) \
    || return 1
  for line in "${(@f)output}"; do
    [[ "$line" =~ '^([A-Za-z0-9._-]+) ([^[:space:]]+)$' ]] || continue
    print -r -- "${match[1]}"$'\t'"${match[2]}"
  done
}

# Resolves a tool step's active executable through _sys_tool_program and
# reports the step result when the step cannot use it: an absent tool, or a
# Windows program that WSL reaches through its appended Windows PATH, is
# skipped; an unsafe executable is blocked. REPLY: the executable. Status 0:
# use it; 1: blocked and reported; 3: skipped and reported.
# Usage: _sys_update_tool_program <tool> <subject>
_sys_update_tool_program() {
  local tool_name="${1:-}" subject="${2:-${1:-}}"
  local -a reply=()
  local -i resolve_rc=0
  _sys_tool_program "$tool_name" || resolve_rc=$?
  case "$resolve_rc" in
    0) return 0 ;;
    1)
      _sys_report_result skipped "not installed" \
        "$subject not installed, skipping."
      return 3
      ;;
    3)
      local reason="${reply[1]:-unusable executable}" program="$REPLY"
      if [[ "$reason" == "world-writable executable" ]]; then
        _sys_error \
          "Refusing the world-writable $subject executable: $(_sys_display_escape "$program")"
        _sys_report_result blocked "$reason"
        return 1
      fi
      _sys_report_result skipped "$reason" \
        "$subject resolves to a $reason ($(_sys_display_escape "$program")); skipping."
      return 3
      ;;
  esac
  return 1
}

# Applicability for tool steps: the active executable is usable, or it is
# unsafe and the step reports it as blocked. An absent tool, a Windows program
# reached through WSL interop, or a Command Line Tools placeholder does not
# apply.
_sys_update_tool_applies() {
  local REPLY
  local -a reply=()
  local -i resolve_rc=0
  _sys_tool_program "${1:-}" || resolve_rc=$?
  (( resolve_rc == 0 )) && return 0
  (( resolve_rc == 3 )) && [[ "${reply[1]:-}" == "world-writable executable" ]]
}

# REPLY: the canonical Homebrew prefix. Status 1 without a usable brew.
_sys_brew_prefix() {
  local brew_prefix=""
  REPLY=""
  command -v brew &>/dev/null || return 1
  brew_prefix=$(_sys_brew --prefix 2>/dev/null) || return 1
  [[ "$brew_prefix" == /* && "$brew_prefix" != *[[:cntrl:]]* \
    && -d "$brew_prefix" ]] || return 1
  REPLY="${brew_prefix:A}"
}

# Homebrew owns a formula only when the active executable resolves inside
# that formula below the resolved prefix and the same native manager lists it.
# REPLY: canonical prefix; reply=(<active executable> <brew executable>).
# Usage: _sys_update_homebrew_owns_program <formula> <active executable>
_sys_update_homebrew_owns_program() {
  local formula="${1:-}" program="${2:-}" manager="" brew_prefix=""
  local -i probe_rc=0
  [[ "$formula" == (awscli|starship) && "$program" == /* \
    && "$program" != *[[:cntrl:]]* && -f "$program" && -x "$program" ]] \
    || return 1
  _sys_tool_program brew || return 1
  manager="$REPLY"
  _sys_update_program_fingerprint "$manager" || return $?
  local -x HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_CURL_RETRIES=0
  local -x HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1
  brew_prefix=$(_sys_run_bounded_probe 10 65536 "$manager" --prefix \
    </dev/null 2>/dev/null) || probe_rc=$?
  (( probe_rc == 0 )) || return "$probe_rc"
  [[ "$brew_prefix" == /* && "$brew_prefix" != *[[:cntrl:]]* \
    && -d "$brew_prefix" ]] || return 1
  brew_prefix="${brew_prefix:A}"
  [[ "${program:A}" == "$brew_prefix"/Cellar/"$formula"/* \
    || "${program:A}" == "$brew_prefix"/opt/"$formula"/* ]] \
    || return 1
  _sys_run_bounded_probe 10 65536 "$manager" list "$formula" \
    </dev/null >/dev/null 2>&1 || return $?
  REPLY="$brew_prefix"
  reply=("$program" "$manager")
}

# Ownership belongs to the active Starship, not another installed copy.
# REPLY: homebrew or cargo; reply=(<active executable> <manager executable>).
# Usage: _sys_update_starship_owner <active executable>
_sys_update_starship_owner() {
  local program="${1:-}" manager="" inventory="" line
  local -i owner_rc=0
  [[ "$program" == /* && "$program" != *[[:cntrl:]]* \
    && -f "$program" && -x "$program" ]] || return 1
  _sys_update_homebrew_owns_program starship "$program" || owner_rc=$?
  if (( owner_rc == 0 )); then
    REPLY=homebrew
    return 0
  fi
  (( owner_rc == 130 || owner_rc == 143 )) && return "$owner_rc"
  local cargo_home="${CARGO_HOME:-$HOME/.cargo}" cargo_program=""
  [[ "$cargo_home" == /* && "$cargo_home" != *[[:cntrl:]]* ]] || return 1
  cargo_program="$cargo_home/bin/starship"
  [[ -f "$cargo_program" && -x "$cargo_program" \
    && "${program:A}" == "${cargo_program:A}" ]] || return 1
  _sys_tool_program cargo || return 1
  manager="$REPLY"
  _sys_update_program_fingerprint "$manager" || return $?
  inventory=$(_sys_run_bounded_probe 10 262144 "$manager" install --list \
    </dev/null 2>/dev/null) || return $?
  for line in "${(@f)inventory}"; do
    [[ "$line" == 'starship v'*: ]] || continue
    REPLY=cargo
    reply=("$program" "$manager")
    return 0
  done
  return 1
}

# True when Homebrew owns the active gcloud: the executable, or the file it
# resolves to, lies in the gcloud-cli cask (formerly google-cloud-sdk) below
# the Homebrew prefix, or in its share/google-cloud-sdk link.
_sys_gcloud_homebrew_managed() {
  local gcloud_program="${1:-}" REPLY
  [[ "$gcloud_program" == /* && "$gcloud_program" != *[[:cntrl:]]* ]] \
    || return 2
  _sys_brew_prefix || return 1
  local brew_prefix="$REPLY" candidate
  for candidate in "$gcloud_program" "${gcloud_program:A}"; do
    [[ "$candidate" == "$brew_prefix"/Caskroom/gcloud-cli/* \
      || "$candidate" == "$brew_prefix"/Caskroom/google-cloud-sdk/* \
      || "$candidate" == "$brew_prefix"/share/google-cloud-sdk/* ]] \
      && return 0
  done
  return 1
}

# REPLY: where the google-cloud-cli APT package installs the SDK.
_sys_gcloud_apt_root() {
  REPLY=/usr/lib/google-cloud-sdk
}

# REPLY: who updates the active gcloud: homebrew, apt, or self (its own
# component manager). Like uv, ownership follows the active executable, so an
# installed cask or package does not hide an earlier self-managed SDK in PATH.
# APT owns it when it resolves below /usr/lib/google-cloud-sdk, where the
# google-cloud-cli package installs it. reply=(<executable>); for status 3,
# as in _sys_tool_program, reply holds the reason instead.
_sys_gcloud_owner() {
  _sys_tool_program gcloud || return $?
  local gcloud_program="$REPLY" apt_root=""
  _sys_gcloud_apt_root
  apt_root="$REPLY"
  if _sys_gcloud_homebrew_managed "$gcloud_program"; then
    REPLY=homebrew
  elif [[ "${gcloud_program:A}" == "$apt_root"/* ]] \
    && command -v dpkg &>/dev/null \
    && dpkg -s google-cloud-cli &>/dev/null; then
    REPLY=apt
  else
    REPLY=self
  fi
  reply=("$gcloud_program")
  return 0
}

update-gcloud() {
  emulate -L zsh
  local REPLY
  local -a reply=()
  _sys_update_parse_no_args update-gcloud "$@" || return $?
  [[ "$REPLY" == "help" ]] && return 0
  _sys_header "Updating Google Cloud SDK"

  local -i program_rc=0
  _sys_update_tool_program gcloud gcloud || program_rc=$?
  (( program_rc == 3 )) && return 0
  (( program_rc == 0 )) || return 1
  _sys_gcloud_owner || return 1
  local gcloud_owner="$REPLY" gcloud_program="${reply[1]}"
  case "$gcloud_owner" in
    apt)
      _sys_report_result delegated "APT → sys-menu update-apt" \
        "Managed by APT — use update-apt instead."
      return 0
      ;;
    homebrew)
      _sys_report_result delegated "Homebrew → sys-menu update-brew" \
        "Managed by Homebrew — use update-brew instead."
      return 0
      ;;
  esac

  local gcloud_before="" gcloud_after=""
  _sys_update_probe_version 15 "$gcloud_program" version \
    && gcloud_before="$REPLY"
  _sys_info "Updating components..."
  if "$gcloud_program" components update --quiet </dev/null >&2; then
    _sys_update_probe_version 15 "$gcloud_program" version \
      && gcloud_after="$REPLY"
    _sys_update_report_version "Google Cloud SDK" \
      "$gcloud_before" "$gcloud_after"
  else
    local -i mutation_rc=$?
    _sys_error "Google Cloud SDK update failed."
    (( mutation_rc == 130 || mutation_rc == 143 )) && return $mutation_rc
    return 1
  fi
}

# Verify the selected installed owner against its reviewed canonical scope.
# Ownership follows the active executable, while the selected native manager
# and root must remain the same before review, after consent, and after update.
# Usage: <tool> <active executable> <Homebrew|Cargo> <manager> <canonical root>
_sys_update_owned_tool_recheck() {
  emulate -L zsh
  local tool="$1" active_program="$2" owner="$3" manager_program="$4"
  local owner_prefix="$5" formula REPLY
  local -a reply=()
  _sys_tool_program "$tool" || return $?
  [[ "$REPLY" == "$active_program" ]] || return 1
  case "$owner" in
    Homebrew)
      case "$tool" in
        aws) formula=awscli ;;
        starship) formula=starship ;;
        *) return 2 ;;
      esac
      _sys_update_homebrew_owns_program "$formula" "$active_program" \
        || return $?
      [[ "$REPLY" == "$owner_prefix" \
        && "${reply[2]}" == "$manager_program" ]] || return 1
      ;;
    Cargo)
      [[ "$tool" == starship ]] || return 2
      _sys_resolve_trusted_dir "${CARGO_HOME:-$HOME/.cargo}" || return 1
      [[ "$REPLY" == "$owner_prefix" ]] || return 1
      _sys_update_starship_owner "$active_program" || return $?
      [[ "$REPLY" == cargo \
        && "${reply[2]}" == "$manager_program" ]] || return 1
      ;;
    *) return 2 ;;
  esac
  return 0
}

# Run one installed owner's fixed argv after a passive, content-bound review.
# Usage: <dry-run> <yes> <tool> <subject> <active> <manager> <owner> <args...>
_sys_update_owned_tool() {
  emulate -L zsh
  local -i dry_run="$1" assume_yes="$2" operation_rc=0
  local tool="$3" subject="$4" active_program="$5"
  local manager_program="$6" owner="$7" REPLY
  local -a reply=()
  shift 7
  local -a owner_args=("$@")
  local active_fingerprint manager_fingerprint before after="" manager_version
  local owner_prefix updated_program
  _sys_update_program_fingerprint "$active_program" || {
    _sys_update_owner_failure "$?" "$subject executable failed identity and checksum validation."
    return $?
  }
  active_fingerprint="$REPLY"
  _sys_update_program_fingerprint "$manager_program" || {
    _sys_update_owner_failure "$?" "$owner executable failed identity and checksum validation."
    return $?
  }
  manager_fingerprint="$REPLY"
  _sys_update_probe_version 5 "$active_program" --version || {
    _sys_update_owner_failure "$?" "$subject version probe failed; refusing delegation."
    return $?
  }
  before="$REPLY"
  _sys_update_probe_version 5 "$manager_program" --version || {
    _sys_update_owner_failure "$?" "$owner version probe failed; refusing delegation."
    return $?
  }
  manager_version="$REPLY"
  if [[ "$owner" == Homebrew ]]; then
    _sys_update_homebrew_prefix "$manager_program" || {
      _sys_update_owner_failure "$?" "Homebrew installation prefix could not be verified."
      return $?
    }
  else
    _sys_resolve_trusted_dir "${CARGO_HOME:-$HOME/.cargo}" || return 1
  fi
  owner_prefix="$REPLY"
  _sys_update_owned_tool_recheck "$tool" "$active_program" "$owner" \
    "$manager_program" "$owner_prefix" || {
    _sys_update_owner_failure "$?" "The selected $subject installation owner could not be verified."
    return $?
  }
  _sys_header "$subject Update Plan"
  _sys_label "Executable:" "$active_program ($before)"
  _sys_label "Owner:" "$manager_program ($manager_version)"
  _sys_label "Prefix:" "$owner_prefix"
  _sys_label "Scope:" "Dynamic latest available $subject release through installed $owner"
  _sys_label "Command:" "${(q)manager_program} ${(j: :)${(@q)owner_args}}"
  _sys_warn "This delegates remote code selection and release verification to the installed owner."
  _sys_dim "The reviewed executable identities and SHA-256 contents are revalidated before delegation."
  if (( dry_run )); then
    _sys_report_result planned "$owner; no mutation executed"
    return 0
  fi
  _sys_update_owner_authorize "$assume_yes" "$subject" || operation_rc=$?
  (( operation_rc == 3 )) && return 0
  (( operation_rc == 0 )) || return "$operation_rc"
  # Ownership observations execute the installed manager too; compare its
  # reviewed bytes before those observations, then again before mutation.
  _sys_update_program_revalidate "$tool" "$active_program" "$active_fingerprint" || {
    _sys_update_owner_failure "$?" "The reviewed $subject executable changed; refusing ownership observations."
    return $?
  }
  _sys_update_program_revalidate "${manager_program:t}" \
    "$manager_program" "$manager_fingerprint" || {
    _sys_update_owner_failure "$?" "The reviewed $owner owner changed; refusing ownership observations."
    return $?
  }
  _sys_update_owned_tool_recheck "$tool" "$active_program" "$owner" \
    "$manager_program" "$owner_prefix" || {
    _sys_update_owner_failure "$?" "The reviewed $subject installation owner changed; refusing delegation."
    return $?
  }
  local -x HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_CURL_RETRIES=0
  local -x HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1 CARGO_NET_RETRY=0
  local -x CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
  [[ "$owner" == Cargo ]] && CARGO_HOME="$owner_prefix"
  _sys_update_program_revalidate "$tool" "$active_program" "$active_fingerprint" || {
    _sys_update_owner_failure "$?" "The reviewed $subject executable changed; refusing delegation."
    return $?
  }
  _sys_update_program_revalidate "${manager_program:t}" \
    "$manager_program" "$manager_fingerprint" || {
    _sys_update_owner_failure "$?" "The reviewed $owner owner changed; refusing delegation."
    return $?
  }
  "$manager_program" "${owner_args[@]}" </dev/null >&2 || operation_rc=$?
  if (( operation_rc != 0 )); then
    _sys_update_owner_failure "$operation_rc" "$owner failed to update $subject."
    return $?
  fi
  _sys_tool_program "$tool" || {
    _sys_update_owner_failure "$?" "The update completed, but the active $subject executable could not be verified."
    return $?
  }
  updated_program="$REPLY"
  _sys_update_owned_tool_recheck "$tool" "$updated_program" "$owner" \
    "$manager_program" "$owner_prefix" || {
    _sys_update_owner_failure "$?" "The update completed, but the active $subject owner could not be verified."
    return $?
  }
  _sys_update_program_fingerprint "$updated_program" || {
    _sys_update_owner_failure "$?" "The updated $subject executable failed identity and checksum validation."
    return $?
  }
  _sys_update_probe_version 5 "$updated_program" --version \
    && after="$REPLY" || operation_rc=$?
  (( operation_rc == 130 || operation_rc == 143 )) && return "$operation_rc"
  _sys_update_report_version "$subject" "$before" "$after" "$owner"
}

update-awscli() {
  emulate -L zsh
  local REPLY
  local -a reply=()
  _sys_update_parse_plan_flags update-awscli "$@" || return $?
  [[ "$REPLY" == "help" ]] && return 0
  local -i dry_run="${reply[1]}" assume_yes="${reply[2]}" program_rc=0

  _sys_tool_program aws || program_rc=$?
  local aws_program="$REPLY"
  if (( program_rc != 0 && program_rc != 1 )); then
    _sys_update_tool_program aws "AWS CLI" || program_rc=$?
    (( program_rc == 3 )) && return 0
    return 1
  fi
  local -i owner_rc=1
  if (( program_rc == 0 )); then
    owner_rc=0
    _sys_update_homebrew_owns_program awscli "$aws_program" || owner_rc=$?
  fi
  (( owner_rc == 130 || owner_rc == 143 )) && return "$owner_rc"
  if (( owner_rc == 0 )); then
    local manager="${reply[2]}"
    _sys_update_owned_tool "$dry_run" "$assume_yes" aws "AWS CLI" \
      "$aws_program" "$manager" Homebrew upgrade --no-ask awscli
    return $?
  fi

  if (( program_rc == 0 )); then
    local snap_program=""
    owner_rc=0
    _sys_tool_program snap || owner_rc=$?
    if (( owner_rc == 0 )); then
      snap_program="$REPLY"
      _sys_update_program_fingerprint "$snap_program" || owner_rc=$?
      if (( owner_rc == 0 )); then
        _sys_run_bounded_probe 10 65536 "$snap_program" list aws-cli \
          </dev/null >/dev/null 2>&1 || owner_rc=$?
        if (( owner_rc == 0 )); then
          _sys_report_result delegated "Snap → sys-menu update-snap" \
            "AWS CLI is managed by Snap; run update-snap instead."
          return 0
        fi
      fi
    fi
    (( owner_rc == 130 || owner_rc == 143 )) && return "$owner_rc"
  fi

  local current_version="not installed"
  local -i version_rc=0
  if (( program_rc == 0 )); then
    _sys_update_program_fingerprint "$aws_program" || version_rc=$?
    if (( version_rc == 0 )); then
      _sys_update_probe_version 5 "$aws_program" --version || version_rc=$?
      (( version_rc == 0 )) && current_version="$REPLY"
    fi
    (( version_rc == 130 || version_rc == 143 )) && return "$version_rc"
  fi
  _sys_label "Current:" "$current_version"
  _sys_error "Automatic AWS CLI bundle installation is disabled."
  _sys_dim "AWS publishes detached signatures rather than a pinned checksum."
  _sys_dim "Follow the official verification procedure before installing:"
  _sys_dim "https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
  _sys_dim "After an --update, clean-system removes the superseded bundle versions."
  _sys_report_result blocked "manual installation required"
  return 1
}

update-starship() {
  emulate -L zsh
  local REPLY
  local -a reply=()
  _sys_update_parse_plan_flags update-starship "$@" || return $?
  [[ "$REPLY" == "help" ]] && return 0
  local -i dry_run="${reply[1]}" assume_yes="${reply[2]}" program_rc=0

  _sys_update_tool_program starship Starship || program_rc=$?
  (( program_rc == 3 )) && return 0
  (( program_rc == 0 )) || return 1
  local starship_program="$REPLY"
  local -i owner_rc=0
  _sys_update_starship_owner "$starship_program" || owner_rc=$?
  (( owner_rc == 130 || owner_rc == 143 )) && return "$owner_rc"
  if (( owner_rc != 0 )); then
    _sys_error "Starship's installation owner could not be verified."
    _sys_dim "Update it with its original package manager."
    _sys_dim "Official options: https://starship.rs/installing/"
    _sys_report_result blocked "installation owner unknown"
    return 1
  fi
  local owner="$REPLY" manager="${reply[2]}"
  if [[ "$owner" == homebrew ]]; then
    _sys_update_owned_tool "$dry_run" "$assume_yes" starship Starship \
      "$starship_program" "$manager" Homebrew upgrade --no-ask starship
  else
    _sys_update_owned_tool "$dry_run" "$assume_yes" starship Starship \
      "$starship_program" "$manager" Cargo install --locked starship
  fi
}

_sys_uv_resolved_program() {
  local uv_program=""
  uv_program=$(whence -p uv 2>/dev/null) || return 1
  [[ "$uv_program" == /* && "$uv_program" != *[[:cntrl:]]* ]] \
    || return 2

  uv_program="${uv_program:A}"
  [[ -f "$uv_program" && -x "$uv_program" ]] || return 2
  REPLY="$uv_program"
}

_sys_uv_homebrew_managed() {
  local uv_program="${1:-}"
  [[ "$uv_program" == /* && "$uv_program" != *[[:cntrl:]]* \
    && -f "$uv_program" && -x "$uv_program" ]] || return 2
  uv_program="${uv_program:A}"
  command -v brew &>/dev/null || return 1

  local brew_prefix=""
  brew_prefix=$(_sys_brew --prefix 2>/dev/null) || return 1
  [[ "$brew_prefix" == /* && "$brew_prefix" != *[[:cntrl:]]* \
    && -d "$brew_prefix" ]] || return 1
  brew_prefix="${brew_prefix:A}"

  [[ "$uv_program" == "$brew_prefix"/Cellar/uv/*/bin/uv \
    || "$uv_program" == "$brew_prefix"/opt/uv/bin/uv ]]
}

# A successful updater status does not prove that the resulting command works.
_sys_uv_updated_version() {
  local uv_program="$1" version_output=""
  REPLY=""
  version_output=$(
    _sys_run_bounded_probe 3 65536 "$uv_program" --version 2>/dev/null
  ) || return 1
  local updated_version="${${version_output#uv }%%[[:space:]]*}"
  [[ "$version_output" == "uv "* \
    && "$version_output" != *[[:cntrl:]]* \
    && "$updated_version" == <->.<->.<->* ]] || return 1
  REPLY="$updated_version"
}

update-uv-system() {
  emulate -L zsh
  local REPLY
  _sys_update_parse_no_args update-uv-system "$@" || return $?
  [[ "$REPLY" == "help" ]] && return 0
  _sys_header "Updating uv"

  local -a reply=()
  local -i program_rc=0
  _sys_update_tool_program uv uv || program_rc=$?
  (( program_rc == 3 )) && return 0
  (( program_rc == 0 )) || return 1
  local -i resolve_rc=0
  _sys_uv_resolved_program || resolve_rc=$?
  if (( resolve_rc == 1 )); then
    _sys_report_result skipped "not installed" "uv not installed, skipping."
    return 0
  elif (( resolve_rc != 0 )); then
    _sys_error "The active uv executable did not resolve to a regular executable path."
    return 1
  fi
  local uv_program="$REPLY" uv_before=""
  _sys_uv_updated_version "$uv_program" && uv_before="$REPLY"

  if _sys_uv_homebrew_managed "$uv_program"; then
    _sys_info "The active uv executable is managed by Homebrew; upgrading the uv formula."
    local -x HOMEBREW_NO_AUTO_UPDATE=1
    local -x HOMEBREW_CURL_RETRIES=0 HOMEBREW_NO_ANALYTICS=1
    local -x HOMEBREW_NO_ENV_HINTS=1
    local SUDO_ASKPASS askpass_program=""
    unset SUDO_ASKPASS
    if _sys_has_capability "os:darwin"; then
      _sys_brew_askpass_program || {
        _sys_error "The trusted Homebrew askpass guard is unavailable."
        return 1
      }
      askpass_program="$REPLY"
      local -x SUDO_ASKPASS="$askpass_program"
    fi
    local -i upgrade_rc=0
    {
      _sys_brew upgrade --no-ask uv </dev/null >&2 || upgrade_rc=$?
    } always {
      _sys_brew_askpass_release "$askpass_program" \
        || _sys_warn "Could not remove the private askpass script: $askpass_program"
    }
    (( upgrade_rc == 0 )) || {
      _sys_error "Homebrew failed to update uv; its self-updater was not invoked."
      (( upgrade_rc == 130 || upgrade_rc == 143 )) && return $upgrade_rc
      return 1
    }
    # Homebrew can replace the Cellar target. Resolve its public launcher again
    # before probing, instead of executing the removed previous version path.
    _sys_uv_resolved_program || {
      _sys_error "Homebrew completed, but could not verify the active uv executable."
      return 1
    }
    uv_program="$REPLY"
    _sys_uv_homebrew_managed "$uv_program" \
      && _sys_uv_updated_version "$uv_program" || {
      _sys_error "Homebrew completed, but could not verify the updated uv version."
      return 1
    }
    _sys_update_report_version uv "$uv_before" "$REPLY" Homebrew
    return 0
  fi

  if _sys_run_logged "uv self update" command env UV_HTTP_RETRIES=0 \
    "$uv_program" self update; then
    _sys_uv_updated_version "$uv_program" || {
      _sys_error "The uv self-update completed, but could not verify its version."
      return 1
    }
    _sys_update_report_version uv "$uv_before" "$REPLY"
  else
    local -i mutation_rc=$?
    _sys_error "uv self-update failed or is managed externally."
    (( mutation_rc == 130 || mutation_rc == 143 )) && return $mutation_rc
    return 1
  fi
}

update-pipx() {
  emulate -L zsh
  local REPLY
  _sys_update_parse_no_args update-pipx "$@" || return $?
  [[ "$REPLY" == "help" ]] && return 0
  _sys_header "Updating pipx & its packages"

  local -i program_rc=0
  _sys_update_tool_program pipx pipx || program_rc=$?
  (( program_rc == 3 )) && return 0
  (( program_rc == 0 )) || return 1

  local inventory_before="" inventory_after=""
  local -i inventory_known=0
  inventory_before=$(_sys_update_pipx_inventory) && inventory_known=1
  _sys_info "Upgrading all pipx packages..."
  if _sys_run_logged "pipx upgrade-all" command env PIP_NO_INPUT=1 PIP_RETRIES=0 \
    pipx upgrade-all; then
    if (( inventory_known )) \
      && inventory_after=$(_sys_update_pipx_inventory); then
      local -A versions_before=()
      local -a changed=() installed=()
      local record
      for record in "${(@f)inventory_before}"; do
        [[ -n "$record" ]] && versions_before[${record%%$'\t'*}]="${record#*$'\t'}"
      done
      for record in "${(@f)inventory_after}"; do
        [[ -n "$record" ]] || continue
        installed+=("${record%%$'\t'*}")
        [[ "${versions_before[${record%%$'\t'*}]:-}" == "${record#*$'\t'}" ]] \
          || changed+=("${record%%$'\t'*}")
      done
      _sys_count_noun "${#installed}" application
      local installed_label="$REPLY"
      if (( ${#installed} == 0 )); then
        _sys_report_result current "no applications installed" \
          "No pipx applications are installed."
      elif (( ${#changed} == 0 )); then
        _sys_report_result current "$installed_label" \
          "pipx applications are already up to date ($installed_label)."
      else
        _sys_report_result updated \
          "${#changed} of $installed_label upgraded (${(j:, :)changed[1,5]})" \
          "pipx applications updated: ${#changed} of $installed_label (${(j:, :)changed[1,5]})."
      fi
    else
      _sys_report_result done "upgrade-all completed" \
        "pipx upgrade-all completed."
    fi
  else
    local -i mutation_rc=$?
    _sys_error "pipx upgrade-all failed."
    (( mutation_rc == 130 || mutation_rc == 143 )) && return $mutation_rc
    return 1
  fi
}

# Reports the Node.js LTS result from the versions before and after. An
# optional note, such as migrated global packages, extends the detail.
# Usage: _sys_update_report_node <before> <after> [note]
_sys_update_report_node() {
  local before="${1:-}" after="${2:-}" note="${3:+; $3}"
  if [[ -n "$before" && "$before" == "$after" ]]; then
    _sys_report_result current "$after (default)$note" \
      "Node.js LTS ($after) is already installed and active as the default."
  elif [[ -n "$before" ]]; then
    _sys_report_result updated "$before → $after (default)$note" \
      "Node.js LTS ($after) installed and set as default (was $before)."
  else
    _sys_report_result updated "$after (default)$note" \
      "Node.js LTS ($after) installed and set as default."
  fi
}

# Carries the global npm packages of the default that update-node replaced
# into the new default, so they stay on the default PATH. Only a new default
# without global packages of its own receives them, through nvm
# reinstall-packages, which installs the same versions; a default that
# already has its own packages is never changed. The previous runtime stays
# installed: clean-system removes it once nothing needs it. REPLY: a short
# note for the step detail, or empty when nothing was carried over. A failed
# migration leaves the update in place and names the command to finish it.
# Usage: _sys_nvm_migrate_global_packages <nvm-dir> <previous> <new-default>
_sys_nvm_migrate_global_packages() {
  local nvm_dir="${1:-}" previous="${2:-}" current="${3:-}"
  local -a reply=() previous_packages=() current_packages=() missing=()
  REPLY=""
  [[ "$previous" == v<->.<->.<-> && "$current" == v<->.<->.<-> \
    && "$previous" != "$current" && "$nvm_dir" == /* ]] || return 0
  local previous_dir="$nvm_dir/versions/node/$previous"
  local current_dir="$nvm_dir/versions/node/$current"
  [[ -d "$previous_dir" && ! -L "$previous_dir" ]] || return 0
  local unreadable=""
  if _sys_nvm_global_packages "$previous_dir"; then
    previous_packages=("${reply[@]}")
  else
    unreadable="$previous"
  fi
  if _sys_nvm_global_packages "$current_dir"; then
    current_packages=("${reply[@]}")
  else
    unreadable="$current"
  fi
  if [[ -n "$unreadable" ]]; then
    _sys_warn "The global npm packages of $unreadable could not be read; none were carried over."
    REPLY="global packages not carried over"
    return 0
  fi
  missing=("${(@)previous_packages:|current_packages}")
  (( ${#missing} > 0 )) || return 0

  if (( ${#current_packages} > 0 )); then
    # Reinstalling into a populated default could change its packages.
    _sys_warn "$current lacks global packages of $previous (${(j:, :)${(@V)missing[1,5]}})."
    _sys_dim "Carry them over if you still need them: nvm use $current && nvm reinstall-packages $previous"
    REPLY="global packages of $previous not carried over"
    return 0
  fi
  _sys_count_noun "${#missing}" "global package"
  _sys_info "Reinstalling $REPLY from $previous into $current..."
  if _sys_run_logged "nvm reinstall-packages $previous" \
    nvm reinstall-packages "$previous"; then
    _sys_nvm_global_packages "$current_dir" || reply=()
    current_packages=("${reply[@]}")
    missing=("${(@)previous_packages:|current_packages}")
    if (( ${#missing} == 0 )); then
      _sys_count_noun "${#previous_packages}" "global package"
      REPLY="$REPLY carried over from $previous"
      return 0
    fi
  else
    local -i migration_rc=$?
    (( migration_rc == 130 || migration_rc == 143 )) && return $migration_rc
  fi
  _sys_warn "Some global npm packages of $previous are missing from $current (${(j:, :)${(@V)missing[1,5]}})."
  _sys_dim "Finish it: nvm use $current && nvm reinstall-packages $previous"
  REPLY="global packages of $previous not carried over"
}

update-node() {
  emulate -L zsh
  local REPLY
  _sys_update_parse_no_args update-node "$@" || return $?
  [[ "$REPLY" == "help" ]] && return 0
  _sys_header "Updating Node.js (via version manager)"

  # A Windows fnm reached through WSL interop is not this host's fnm.
  local fnm_program=""
  local -a reply=()
  local -i fnm_rc=0
  _sys_tool_program fnm || fnm_rc=$?
  if (( fnm_rc == 0 )); then
    fnm_program="$REPLY"
  elif (( fnm_rc == 3 )) \
    && [[ "${reply[1]:-}" == "world-writable executable" ]]; then
    _sys_error \
      "Refusing the world-writable fnm executable: $(_sys_display_escape "$REPLY")"
    _sys_report_result blocked "world-writable executable"
    return 1
  fi
  if [[ -n "$fnm_program" ]]; then
    [[ "$fnm_program" == /* && "$fnm_program" != *[[:cntrl:]]* \
      && -f "$fnm_program" && -x "$fnm_program" ]] || {
      _sys_error "fnm did not resolve to a regular executable path."
      return 1
    }
    fnm_program="${fnm_program:A}"
    if command -v brew &>/dev/null \
      && _sys_brew list fnm &>/dev/null 2>&1; then
      _sys_info "fnm itself is managed by Homebrew — updating Node.js LTS only."
    fi

    local fnm_before=""
    fnm_before=$(
      _sys_run_bounded_probe 3 65536 "$fnm_program" current 2>/dev/null
    ) || fnm_before=""
    [[ "$fnm_before" == v<->.<->.<-> ]] || fnm_before=""
    _sys_info "Installing latest Node.js LTS via fnm..."
    if _sys_run_logged "fnm install --lts" command "$fnm_program" install --lts; then
      local -i phase_failures=0
      if command "$fnm_program" use lts-latest </dev/null >&2; then
        :
      else
        local -i selection_rc=$?
        _sys_error "Node.js LTS was installed, but activation failed."
        _sys_dim "Retry activation after checking fnm shell setup: fnm use lts-latest"
        (( selection_rc == 130 || selection_rc == 143 )) && return $selection_rc
        phase_failures=$(( phase_failures + 1 ))
      fi
      if command "$fnm_program" default lts-latest </dev/null >&2; then
        :
      else
        local -i selection_rc=$?
        _sys_error "Node.js LTS was installed, but default selection failed."
        _sys_dim "Retry the default selection: fnm default lts-latest"
        (( selection_rc == 130 || selection_rc == 143 )) && return $selection_rc
        phase_failures=$(( phase_failures + 1 ))
      fi
      (( phase_failures == 0 )) || return 1

      local lts_version
      lts_version=$(
        _sys_run_bounded_probe 3 65536 "$fnm_program" current 2>/dev/null
      ) || lts_version=""

      [[ "$lts_version" == v<->.<->.<-> ]] || {
        _sys_error "Node.js LTS was installed, but could not verify fnm's active version."
        return 1
      }
      _sys_update_report_node "$fnm_before" "$lts_version"
    else
      local -i mutation_rc=$?
      _sys_error "fnm failed to install Node.js LTS."
      (( mutation_rc == 130 || mutation_rc == 143 )) && return $mutation_rc
      return 1
    fi

  elif [[ -d "${NVM_DIR:-$HOME/.nvm}" ]]; then
    local nvm_dir="${NVM_DIR:-$HOME/.nvm}"

    _sys_info "Using the existing nvm installation..."
    _sys_dim "The nvm Git checkout is not changed by this command."

    if ! command -v nvm &>/dev/null; then
      _sys_error "nvm is installed but is not loaded in this shell."
      _sys_dim "Load nvm through your trusted shell configuration, then retry."
      return 1
    fi

    local nvm_before="" nvm_previous_default=""
    nvm_before=$(nvm current </dev/null 2>/dev/null) || nvm_before=""
    [[ "$nvm_before" == v<->.<->.<-> ]] || nvm_before=""
    # The default before the update holds the global packages to carry over.
    nvm_previous_default=$(nvm version default </dev/null 2>/dev/null) \
      || nvm_previous_default=""
    [[ "$nvm_previous_default" == v<->.<->.<-> ]] || nvm_previous_default=""
    _sys_info "Installing latest Node.js LTS via nvm..."
    if _sys_run_logged "nvm install --lts" nvm install --lts; then
      local lts_version
      lts_version=$(nvm version "lts/*" 2>/dev/null) || lts_version=""

      [[ "$lts_version" == v<->.<->.<-> ]] || {
        _sys_error "Node.js LTS installation completed, but could not verify its installed version."
        return 1
      }
      local -i phase_failures=0
      if _sys_run_logged_here "nvm alias default $lts_version" \
        nvm alias default "$lts_version"; then
        :
      else
        local -i selection_rc=$?
        _sys_error "Node.js LTS was installed, but default selection failed."
        _sys_dim "Retry the default selection: nvm alias default $lts_version"
        (( selection_rc == 130 || selection_rc == 143 )) && return $selection_rc
        phase_failures=$(( phase_failures + 1 ))
      fi
      # Keep activation in the invoking shell: output capture through a pipeline
      # would discard nvm's PATH/session changes even when it returned success.
      if _sys_run_logged_here "nvm use $lts_version" \
        nvm use "$lts_version"; then
        :
      else
        local -i selection_rc=$?
        _sys_error "Node.js LTS was installed, but activation failed."
        _sys_dim "Retry activation: nvm use $lts_version"
        (( selection_rc == 130 || selection_rc == 143 )) && return $selection_rc
        phase_failures=$(( phase_failures + 1 ))
      fi
      (( phase_failures == 0 )) || return 1
      local active_version=""
      active_version=$(nvm current 2>/dev/null) || active_version=""
      [[ "$active_version" == "$lts_version" ]] || {
        _sys_error "Node.js LTS was installed, but could not verify nvm's active version."
        return 1
      }
      _sys_nvm_migrate_global_packages "$nvm_dir" "$nvm_previous_default" \
        "$lts_version" || return $?
      local migration_note="$REPLY"
      if [[ -n "$nvm_previous_default" && "$nvm_previous_default" != "$lts_version" \
        && "${${nvm_previous_default#v}%%.*}" == "${${lts_version#v}%%.*}" ]]; then
        _sys_dim "clean-system removes $nvm_previous_default once nothing needs it."
      fi
      _sys_update_report_node "$nvm_before" "$lts_version" "$migration_note"
    else
      local -i mutation_rc=$?
      _sys_error "nvm failed to install Node.js LTS."
      (( mutation_rc == 130 || mutation_rc == 143 )) && return $mutation_rc
      return 1
    fi

  else
    _sys_report_result skipped "fnm and nvm not detected" \
      "Neither fnm nor nvm detected, skipping."
    return 0
  fi
}

update-rust() {
  emulate -L zsh
  local REPLY
  _sys_update_parse_no_args update-rust "$@" || return $?
  [[ "$REPLY" == "help" ]] && return 0
  _sys_header "Updating Rust Toolchain"

  local -i program_rc=0
  _sys_update_tool_program rustup rustup || program_rc=$?
  (( program_rc == 3 )) && return 0
  (( program_rc == 0 )) || return 1

  local rustc_before="" rustc_after=""
  _sys_update_probe_version 5 rustc --version && rustc_before="$REPLY"
  _sys_info "Updating rustup and toolchains..."
  if _sys_run_logged "rustup update" command env RUSTUP_MAX_RETRIES=0 rustup update; then
    _sys_update_probe_version 5 rustc --version && rustc_after="$REPLY"
    _sys_update_report_version "Rust (rustc)" "$rustc_before" "$rustc_after"
  else
    local -i mutation_rc=$?
    _sys_error "Rust update failed."
    (( mutation_rc == 130 || mutation_rc == 143 )) && return $mutation_rc
    return 1
  fi
}

# Aggregate applicability predicates. update-system calls them only through
# _sys_step_applies while it freezes the plan; each mirrors its step's own
# skip conditions.

_sys_update_gcloud_applies() {
  local REPLY
  local -a reply=()
  _sys_update_tool_applies gcloud || return 1
  _sys_tool_program gcloud || return 0
  _sys_gcloud_owner && [[ "$REPLY" == self ]]
}

# AWS CLI bundle installation is manual, so the aggregate never selects it.
_sys_update_awscli_applies() {
  return 1
}

_sys_update_starship_applies() {
  local REPLY
  local -a reply=()
  _sys_update_tool_applies starship || return 1
  # Keep an unsafe active executable visible as blocked, without probing it.
  _sys_tool_program starship || return 0
  _sys_update_starship_owner "$REPLY" && [[ "$REPLY" == cargo ]]
}

_sys_update_uv_applies() {
  local REPLY
  local -a reply=()
  _sys_update_tool_applies uv || return 1
  # An unsafe executable applies so that the step reports it as blocked.
  _sys_tool_program uv || return 0
  _sys_uv_resolved_program \
    && ! _sys_uv_homebrew_managed "$REPLY"
}

_sys_update_pipx_applies() {
  _sys_update_tool_applies pipx
}

_sys_update_node_applies() {
  _sys_update_tool_applies fnm \
    || { [[ -d "${NVM_DIR:-$HOME/.nvm}" ]] \
      && command -v nvm &>/dev/null; }
}

_sys_update_rust_applies() {
  _sys_update_tool_applies rustup
}

typeset -g _SYS_UPDATE_TOOLS_SOURCED=1
