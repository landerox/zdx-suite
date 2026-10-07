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
  local seconds="${1:-3}" program="${2:-}" output="" line=""
  local MATCH MBEGIN MEND
  local -a match=() mbegin=() mend=()
  REPLY=""
  shift 2 2>/dev/null || return 2
  program=$(builtin whence -p -- "$program" 2>/dev/null) || return 1
  output=$(_sys_run_bounded_probe "$seconds" 65536 "$program" "$@" \
    </dev/null 2>/dev/null) || return 1
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
    _sys_error "Google Cloud SDK update failed."
    return 1
  fi
}

update-awscli() {
  local REPLY
  _sys_update_parse_no_args update-awscli "$@" || return $?
  [[ "$REPLY" == "help" ]] && return 0
  _sys_header "Updating AWS CLI v2"

  if command -v brew &>/dev/null \
    && _sys_brew list awscli &>/dev/null 2>&1; then
    local aws_before="" aws_after=""
    _sys_update_probe_version 5 aws --version && aws_before="$REPLY"
    _sys_info "AWS CLI is managed by Homebrew; upgrading that formula."
    HOMEBREW_NO_AUTO_UPDATE=1 _sys_brew upgrade --no-ask awscli \
      </dev/null >&2 || {
      _sys_error "Homebrew failed to update AWS CLI."
      return 1
    }
    _sys_update_probe_version 5 aws --version && aws_after="$REPLY"
    _sys_update_report_version "AWS CLI" "$aws_before" "$aws_after" Homebrew
    return 0
  fi

  if command -v snap &>/dev/null \
    && command snap list aws-cli &>/dev/null 2>&1; then
    _sys_report_result delegated "Snap → sys-menu update-snap" \
      "AWS CLI is managed by Snap; run update-snap instead."
    return 0
  fi

  local current_version="not installed"
  command -v aws &>/dev/null \
    && current_version=$(command aws --version 2>&1 | command awk '{print $1}')
  _sys_label "Current:" "$current_version"
  _sys_error "Automatic AWS CLI bundle installation is disabled."
  _sys_dim "AWS publishes detached signatures rather than a pinned checksum."
  _sys_dim "Follow the official verification procedure before installing:"
  _sys_dim "https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
  _sys_report_result blocked "manual installation required"
  return 1
}

update-starship() {
  local REPLY
  _sys_update_parse_no_args update-starship "$@" || return $?
  [[ "$REPLY" == "help" ]] && return 0
  _sys_header "Updating Starship"

  local -i program_rc=0
  _sys_update_tool_program starship Starship || program_rc=$?
  (( program_rc == 3 )) && return 0
  (( program_rc == 0 )) || return 1
  local starship_before="" starship_after=""
  _sys_update_probe_version 3 starship --version \
    && starship_before="$REPLY"

  if command -v brew &>/dev/null \
    && _sys_brew list starship &>/dev/null 2>&1; then
    _sys_info "Starship is managed by Homebrew."
    HOMEBREW_NO_AUTO_UPDATE=1 _sys_brew upgrade --no-ask starship \
      </dev/null >&2 || {
      _sys_error "Homebrew failed to update Starship."
      return 1
    }
    _sys_update_probe_version 3 starship --version \
      && starship_after="$REPLY"
    _sys_update_report_version Starship "$starship_before" "$starship_after" \
      Homebrew
    return 0
  fi

  if _sys_tool_available cargo \
    && command cargo install --list 2>/dev/null \
      | command grep -q '^starship '; then
    _sys_info "Starship is managed by Cargo."
    command env CARGO_NET_RETRY=0 \
      cargo install --locked starship >&2 || {
      _sys_error "Cargo failed to update Starship."
      return 1
    }
    _sys_update_probe_version 3 starship --version \
      && starship_after="$REPLY"
    _sys_update_report_version Starship "$starship_before" "$starship_after" \
      Cargo
    return 0
  fi

  _sys_error "Starship's installation owner could not be verified."
  _sys_dim "Update it with its original package manager."
  _sys_dim "Official options: https://starship.rs/installing/"
  _sys_report_result blocked "installation owner unknown"
  return 1
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
    _sys_error "uv self-update failed or is managed externally."
    return 1
  fi
}

update-pipx() {
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
    _sys_error "pipx upgrade-all failed."
    return 1
  fi
}

# Reports the Node.js LTS result from the versions before and after.
_sys_update_report_node() {
  local before="${1:-}" after="${2:-}"
  if [[ -n "$before" && "$before" == "$after" ]]; then
    _sys_report_result current "$after (default)" \
      "Node.js LTS ($after) is already installed and active as the default."
  elif [[ -n "$before" ]]; then
    _sys_report_result updated "$before → $after (default)" \
      "Node.js LTS ($after) installed and set as default (was $before)."
  else
    _sys_report_result updated "$after (default)" \
      "Node.js LTS ($after) installed and set as default."
  fi
}

update-node() {
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
      if ! command "$fnm_program" use lts-latest </dev/null >&2; then
        _sys_error "Node.js LTS was installed, but activation failed."
        _sys_dim "Retry activation after checking fnm shell setup: fnm use lts-latest"
        phase_failures=$(( phase_failures + 1 ))
      fi
      if ! command "$fnm_program" default lts-latest </dev/null >&2; then
        _sys_error "Node.js LTS was installed, but default selection failed."
        _sys_dim "Retry the default selection: fnm default lts-latest"
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
      _sys_error "fnm failed to install Node.js LTS."
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

    local nvm_before=""
    nvm_before=$(nvm current </dev/null 2>/dev/null) || nvm_before=""
    [[ "$nvm_before" == v<->.<->.<-> ]] || nvm_before=""
    _sys_info "Installing latest Node.js LTS via nvm..."
    if _sys_run_logged "nvm install --lts" nvm install --lts; then
      local lts_version
      lts_version=$(nvm version "lts/*" 2>/dev/null) || lts_version=""

      [[ "$lts_version" == v<->.<->.<-> ]] || {
        _sys_error "Node.js LTS installation completed, but could not verify its installed version."
        return 1
      }
      local -i phase_failures=0
      if ! _sys_run_logged_here "nvm alias default $lts_version" \
        nvm alias default "$lts_version"; then
        _sys_error "Node.js LTS was installed, but default selection failed."
        _sys_dim "Retry the default selection: nvm alias default $lts_version"
        phase_failures=$(( phase_failures + 1 ))
      fi
      # Keep activation in the invoking shell: output capture through a pipeline
      # would discard nvm's PATH/session changes even when it returned success.
      if ! _sys_run_logged_here "nvm use $lts_version" \
        nvm use "$lts_version"; then
        _sys_error "Node.js LTS was installed, but activation failed."
        _sys_dim "Retry activation: nvm use $lts_version"
        phase_failures=$(( phase_failures + 1 ))
      fi
      (( phase_failures == 0 )) || return 1
      local active_version=""
      active_version=$(nvm current 2>/dev/null) || active_version=""
      [[ "$active_version" == "$lts_version" ]] || {
        _sys_error "Node.js LTS was installed, but could not verify nvm's active version."
        return 1
      }
      _sys_update_report_node "$nvm_before" "$lts_version"
    else
      _sys_error "nvm failed to install Node.js LTS."
      return 1
    fi

  else
    _sys_report_result skipped "fnm and nvm not detected" \
      "Neither fnm nor nvm detected, skipping."
    return 0
  fi
}

update-rust() {
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
    _sys_error "Rust update failed."
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
  _sys_update_tool_applies starship \
    && ! { command -v brew &>/dev/null \
      && _sys_brew list starship &>/dev/null 2>&1; } \
    && _sys_tool_available cargo \
    && command cargo install --list 2>/dev/null \
      | command grep -q '^starship '
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
