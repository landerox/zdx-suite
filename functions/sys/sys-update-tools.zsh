#!/usr/bin/env zsh
# =============================================================================
# System Update Tools: SDK, runtime, and CLI updaters plus the AI adapter
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

update-gcloud() {
  local REPLY
  _sys_update_parse_no_args update-gcloud "$@" || return $?
  [[ "$REPLY" == "help" ]] && return 0
  _sys_header "Updating Google Cloud SDK"

  if ! command -v gcloud &>/dev/null; then
    _sys_report_result skipped "not installed" "gcloud not installed, skipping."
    return 0
  fi

  if command -v dpkg &>/dev/null \
    && dpkg -s google-cloud-cli &>/dev/null; then
    _sys_report_result delegated "APT → sys-menu update-apt" \
      "Managed by APT — use update-apt instead."
    return 0
  fi
  if command -v brew &>/dev/null \
    && { _sys_brew list --formula google-cloud-sdk &>/dev/null \
      || _sys_brew list --cask google-cloud-sdk &>/dev/null; }; then
    _sys_report_result delegated "Homebrew → sys-menu update-brew" \
      "Managed by Homebrew — use update-brew instead."
    return 0
  fi

  local gcloud_before="" gcloud_after=""
  _sys_update_probe_version 15 gcloud version && gcloud_before="$REPLY"
  _sys_info "Updating components..."
  if command gcloud components update --quiet </dev/null >&2; then
    _sys_update_probe_version 15 gcloud version \
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

_sys_repomix_program() {
  local program=""
  program=$(builtin whence -p repomix 2>/dev/null) || return 1
  [[ "$program" == /* && "$program" != *[[:cntrl:]]* \
    && -f "$program" && -x "$program" ]] || return 2
  REPLY="${program:A}"
}

_sys_repomix_homebrew_managed() {
  local program="$1" brew_prefix=""
  command -v brew &>/dev/null || return 1
  brew_prefix=$(_sys_brew --prefix 2>/dev/null) || return 1
  [[ "$brew_prefix" == /* && "$brew_prefix" != *[[:cntrl:]]* \
    && -d "$brew_prefix" ]] || return 1
  [[ "$program" == "${brew_prefix:A}"/Cellar/repomix/* \
    || "$program" == "${brew_prefix:A}"/opt/repomix/* ]]
}

# Bind the active launcher to the installed package's passive bin descriptor.
# A separate npm installation cannot claim an earlier custom executable in PATH.
_sys_repomix_npm_binding() {
  local program="$1" npm_program="$2" node_program="$3"
  local npm_prefix="" npm_root=""
  npm_prefix=$(
    _sys_run_bounded_probe 3 65536 "$npm_program" config get prefix 2>/dev/null
  ) || return 1
  npm_root=$(
    _sys_run_bounded_probe 3 65536 "$npm_program" root -g 2>/dev/null
  ) || return 1
  [[ "$npm_prefix" == /* && "$npm_prefix" != / \
    && "$npm_prefix" != *[[:cntrl:]]* \
    && "$npm_root" == "$npm_prefix/lib/node_modules" ]] || return 1
  local package_dir="$npm_root/repomix"
  local descriptor="$package_dir/package.json"
  _sys_update_validate_owned_path "$npm_prefix" "$descriptor" file || return 1
  local bin_relative=""
  bin_relative=$(
    _sys_run_bounded_probe 3 65536 "$node_program" --input-type=commonjs -e '
const fs = require("node:fs");
const file = process.argv[1];
const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
const before = fs.fstatSync(fd);
if (!before.isFile() || before.nlink !== 1 ||
    before.size > 65536 || before.uid !== process.getuid() || (before.mode & 0o22)) {
  process.exit(1);
}
const buffer = Buffer.alloc(65537);
const bytes = fs.readSync(fd, buffer, 0, buffer.length, 0);
const after = fs.fstatSync(fd);
const live = fs.lstatSync(file);
fs.closeSync(fd);
if (bytes > 65536 || live.isSymbolicLink() ||
    live.dev !== before.dev || live.ino !== before.ino) process.exit(1);
if (before.dev !== after.dev || before.ino !== after.ino ||
    before.size !== after.size || before.mtimeMs !== after.mtimeMs ||
    before.ctimeMs !== after.ctimeMs) process.exit(1);
const data = JSON.parse(buffer.subarray(0, bytes).toString("utf8"));
const bin = typeof data.bin === "string" ? data.bin : data.bin?.repomix;
if (data.name !== "repomix" || typeof bin !== "string" || bin.length > 4096 ||
    !bin || bin.startsWith("/") || /[\x00-\x1f\x7f]/.test(bin) ||
    bin.split("/").some(part => !part || part === "..")) process.exit(1);
process.stdout.write(bin);
' "$descriptor" 2>/dev/null
  ) || return 1
  _sys_update_validate_owned_path \
    "$package_dir" "$package_dir/$bin_relative" file || return 1
  [[ "$REPLY" == "$program" && -x "$REPLY" ]] || return 1
  REPLY="$npm_prefix"
}

_sys_repomix_version() {
  local program="$1" version_output=""
  version_output=$(
    _sys_run_bounded_probe 3 65536 "$program" --version 2>/dev/null
  ) || return 1
  [[ -n "$version_output" && ${#version_output} -le 256 \
    && "$version_output" != *[[:cntrl:]]* ]] || return 1
  REPLY="$version_output"
}

update-repomix() {
  local REPLY
  _sys_update_parse_no_args update-repomix "$@" || return $?
  [[ "$REPLY" == "help" ]] && return 0
  _sys_header "Updating Repomix CLI"

  local -i resolve_rc=0
  _sys_repomix_program || resolve_rc=$?
  if (( resolve_rc == 1 )); then
    _sys_report_result skipped "not installed" \
      "No external Repomix executable is installed, skipping."
    return 0
  elif (( resolve_rc != 0 )); then
    _sys_error "The active Repomix executable could not be resolved safely."
    return 1
  fi
  local current_binary="$REPLY"
  if _sys_repomix_homebrew_managed "$current_binary"; then
    _sys_report_result delegated "Homebrew → sys-menu update-brew" \
      "Managed by Homebrew — use update-brew instead."
    return 0
  fi

  local node_program="" npm_program=""
  node_program=$(builtin whence -p node 2>/dev/null)
  npm_program=$(builtin whence -p npm 2>/dev/null)
  [[ "$node_program" == /* && "$node_program" != *[[:cntrl:]]* \
    && -f "$node_program" && -x "$node_program" ]] || {
    _sys_error "An external Node.js executable is required to update Repomix."
    return 1
  }
  [[ "$npm_program" == /* && "$npm_program" != *[[:cntrl:]]* \
    && -f "$npm_program" && -x "$npm_program" ]] || {
    _sys_error "An external npm executable is required to update Repomix."
    return 1
  }
  node_program="${node_program:A}"
  npm_program="${npm_program:A}"
  local node_version=""
  node_version=$(
    _sys_run_bounded_probe 3 65536 "$node_program" --version 2>/dev/null
  ) || node_version=""
  [[ "$node_version" == v<->.<->.<-> ]] || {
    _sys_error "Could not verify the Node.js version required by Repomix."
    return 1
  }
  local node_major="${${node_version#v}%%.*}"
  (( node_major >= 20 )) || {
    _sys_error "Repomix requires Node.js 20 or newer. Current: $node_version"
    return 1
  }

  _sys_repomix_npm_binding \
    "$current_binary" "$npm_program" "$node_program" || {
    _sys_error "The active Repomix executable does not belong to the selected npm global package."
    _sys_dim "Update it through its original installation method; no npm package was changed."
    return 1
  }
  local npm_prefix="$REPLY"
  _sys_repomix_version "$current_binary" || {
    _sys_error "Could not verify the installed Repomix version."
    return 1
  }
  local current_version="$REPLY"
  _sys_info "Current: $current_version"
  _sys_info "Binary: $current_binary"

  _sys_repomix_program && [[ "$REPLY" == "$current_binary" ]] \
    && _sys_repomix_npm_binding "$current_binary" "$npm_program" "$node_program" \
    && [[ "$REPLY" == "$npm_prefix" ]] || {
    _sys_error "The Repomix installation changed before its update."
    return 1
  }
  if ! _sys_npm_install_g repomix@latest "$npm_prefix" "$npm_program"; then
    _sys_warn "Repomix update failed."
    return 1
  fi
  _sys_repomix_program || {
    _sys_error "npm completed, but the updated Repomix executable is unavailable."
    return 1
  }
  local new_binary="$REPLY"
  _sys_repomix_npm_binding "$new_binary" "$npm_program" "$node_program" \
    && [[ "$REPLY" == "$npm_prefix" ]] \
    && _sys_repomix_version "$new_binary" || {
    _sys_error "npm completed, but could not verify the updated Repomix installation."
    return 1
  }
  local new_version="$REPLY"
  if [[ "$current_version" == "$new_version" ]]; then
    _sys_report_result current "$new_version" \
      "Repomix already at latest ($new_version)."
  else
    _sys_report_result updated "$current_version → $new_version" \
      "Repomix updated to $new_version."
  fi
  _sys_info "Binary: $new_binary"
}

update-starship() {
  local REPLY
  _sys_update_parse_no_args update-starship "$@" || return $?
  [[ "$REPLY" == "help" ]] && return 0
  _sys_header "Updating Starship"

  if ! command -v starship &>/dev/null; then
    _sys_report_result skipped "not installed" "Starship not installed, skipping."
    return 0
  fi
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

  if command -v cargo &>/dev/null \
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
    local SUDO_ASKPASS
    unset SUDO_ASKPASS
    if _sys_has_capability "os:darwin"; then
      _sys_brew_askpass_program || {
        _sys_error "The trusted Homebrew askpass guard is unavailable."
        return 1
      }
      local -x SUDO_ASKPASS="$REPLY"
    fi
    _sys_brew upgrade --no-ask uv </dev/null >&2 || {
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

  if ! command -v pipx &>/dev/null; then
    _sys_report_result skipped "not installed" "pipx not installed, skipping."
    return 0
  fi

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

  local fnm_program=""
  fnm_program=$(builtin whence -p fnm 2>/dev/null)
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

  if ! command -v rustup &>/dev/null; then
    _sys_report_result skipped "not installed" "rustup not installed, skipping."
    return 0
  fi

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

_sys_update_ai_load_owner() {
  if typeset -f ai-menu &>/dev/null; then
    return 0
  fi

  local module_dir="${${(%):-%x}:A:h:h}"
  local owner_file="${module_dir}/ai-menu.zsh"
  if [[ "$owner_file" != "${owner_file:A}" \
    || ! -f "$owner_file" || -L "$owner_file" || ! -r "$owner_file" ]]; then
    _sys_error "The AI suite owner is unavailable."
    return 1
  fi

  builtin source "$owner_file" || {
    _sys_error "Failed to load the AI suite owner."
    return 1
  }
  if ! typeset -f ai-menu &>/dev/null; then
    _sys_error "The AI suite owner did not define ai-menu."
    return 1
  fi
}

_sys_update_ai_failure_detail() {
  local label="${1:-}" reason="${2:-}" result_rc="${3:-}"
  case "$reason" in
    metadata-invalid)                 REPLY="$label: updater metadata is invalid" ;;
    executable-validation-failed)     REPLY="$label: executable validation failed" ;;
    version-probe-failed)             REPLY="$label: version probe failed" ;;
    executable-changed)               REPLY="$label: executable changed after review" ;;
    updated-executable-unsafe)        REPLY="$label: updated executable is unsafe" ;;
    post-update-version-probe-failed) REPLY="$label: post-update version probe failed" ;;
    authentication-required)          REPLY="$label: authentication required" ;;
    vendor-precondition)              REPLY="$label: vendor precondition not met" ;;
    result-capture-failed)            REPLY="$label: result capture failed" ;;
    updater-failed)                   REPLY="$label: updater failed (status $result_rc)" ;;
    *) return 2 ;;
  esac
}

# Parse the AI owner's public, bounded result protocol. Human stderr is never
# parsed as data, and vendor output never enters these synthesized records.
_sys_update_ai_parse_results() {
  local report="${1:-}"
  reply=()
  (( ${#report} > 0 && ${#report} <= 16384 )) || return 2
  local -a result_lines=("${(@f)report}")
  local -a expected_ids=(
    claude codex antigravity opencode cursor copilot amp hermes
  )
  local -A expected_labels=(
    claude "Claude Code"
    codex "Codex CLI"
    antigravity "Antigravity CLI"
    opencode "OpenCode"
    cursor "Cursor Agent"
    copilot "GitHub Copilot CLI"
    amp "Amp CLI"
    hermes "Hermes Agent"
  )
  (( ${#result_lines[@]} == ${#expected_ids[@]} )) || return 2

  local -A seen_ids=()
  local line schema id label outcome reason result_rc extra expected_id
  local -i result_index=0
  for line in "${result_lines[@]}"; do
    (( ++result_index ))
    expected_id="${expected_ids[result_index]}"
    schema=""
    id=""
    label=""
    outcome=""
    reason=""
    result_rc=""
    extra=""
    IFS=$'\t' read -r \
      schema id label outcome reason result_rc extra <<< "$line"
    [[ "$schema" == "ai-update-result-v1" \
      && -n "$id" && -n "$label" && -n "$outcome" \
      && -n "$reason" && -n "$result_rc" && -z "$extra" ]] || return 2
    [[ "$id" =~ '^[a-z][a-z0-9-]{0,31}$' \
      && "$label" =~ '^[[:alnum:]][[:alnum:] .()+/_-]{0,63}$' \
      && "$result_rc" == <-> && ${#result_rc} -le 3 ]] || return 2
    [[ "$id" == "$expected_id" \
      && "$label" == "${expected_labels[$expected_id]}" ]] || return 2
    (( result_rc >= 0 && result_rc <= 255 )) || return 2
    (( ! ${+seen_ids[$id]} )) || return 2
    seen_ids[$id]=1

    case "$outcome:$reason" in
      updated:version-changed|updated:executable-content-changed|\
      already-current:unchanged|skipped:not-installed|\
      skipped:homebrew-managed|planned:eligible)
        (( result_rc == 0 )) || return 2
        ;;
      not-run:cancelled)
        (( result_rc == 0 )) || return 2
        ;;
      not-run:interrupted)
        (( result_rc == 130 || result_rc == 143 )) || return 2
        ;;
      not-run:authorization-not-granted)
        (( result_rc != 0 )) || return 2
        ;;
      failed:metadata-invalid|failed:executable-validation-failed|\
      failed:version-probe-failed|failed:executable-changed|\
      failed:updated-executable-unsafe|\
      failed:post-update-version-probe-failed|\
      failed:authentication-required|failed:vendor-precondition|\
      failed:result-capture-failed|failed:updater-failed)
        (( result_rc != 0 )) || return 2
        _sys_update_ai_failure_detail "$label" "$reason" "$result_rc" \
          || return 2
        reply+=("$REPLY")
        ;;
      *)
        return 2
        ;;
    esac
  done
}

# REPLY: the aggregate outcome; reply=(detail) built only from the validated
# records' canonical labels and fixed outcomes.
# Usage: _sys_update_ai_result_summary <report> <dry-run>
_sys_update_ai_result_summary() {
  local report="${1:-}" dry_run="${2:-0}" line outcome label
  local -a fields=() updated_labels=() parts=()
  local -i updated=0 current=0 failed=0 skipped=0 planned=0 not_run=0
  for line in "${(@f)report}"; do
    fields=("${(@ps:	:)line}")
    label="${fields[3]:-}"
    outcome="${fields[4]:-}"
    case "$outcome" in
      updated)         (( ++updated )); updated_labels+=("$label") ;;
      already-current) (( ++current )) ;;
      failed)          (( ++failed )) ;;
      skipped)         (( ++skipped )) ;;
      planned)         (( ++planned )) ;;
      not-run)         (( ++not_run )) ;;
    esac
  done
  if (( dry_run )); then
    (( planned )) && parts+=("$planned planned")
  else
    (( updated )) && parts+=("$updated updated (${(j:, :)updated_labels})")
    (( current )) && parts+=("$current current")
  fi
  (( failed )) && parts+=("$failed failed")
  (( skipped )) && parts+=("$skipped skipped")
  (( not_run )) && parts+=("$not_run not run")
  reply=("${(j: · :)parts}")
  if (( failed )); then
    REPLY=failed
  elif (( dry_run )); then
    REPLY=planned
  elif (( updated )); then
    REPLY=updated
  elif (( current )); then
    REPLY=current
  else
    REPLY=skipped
  fi
}

# Private aggregate adapter. AI lifecycle and updater validation remain owned
# by the public AI suite; System forwards aggregate authorization flags and
# consumes only the owner's versioned result records.
_sys_update_ai_tools() {
  local REPLY
  local -a reply=()
  _sys_update_ai_load_owner || return 1
  local result_report=""
  local -i ai_rc=0
  result_report=$(ai-menu ai-update --skip-homebrew-managed \
    --result-tsv "$@") || ai_rc=$?

  local -a failure_details=()
  local -i report_valid=0
  if _sys_update_ai_parse_results "$result_report"; then
    report_valid=1
    failure_details=("${reply[@]}")
  else
    _sys_error "The AI updater returned an invalid result report."
    failure_details=("result report is invalid")
    # An interrupted owner cannot publish its report; keep the interruption
    # status so the aggregate stops instead of treating it as a failure.
    (( ai_rc == 130 || ai_rc == 143 )) || ai_rc=1
  fi
  if (( ai_rc == 0 && ${#failure_details[@]} > 0 )); then
    _sys_error "The AI updater result report contradicts its success status."
    failure_details=("result report contradicts the updater status")
    ai_rc=1
  elif (( ai_rc != 0 && ${#failure_details[@]} == 0 )); then
    failure_details=("aggregate updater failed (status $ai_rc)")
  fi
  if (( ${+_SYS_UPDATE_STEP_FAILURE_DETAILS} )); then
    _SYS_UPDATE_STEP_FAILURE_DETAILS=("${failure_details[@]}")
  fi
  if (( report_valid )); then
    local -i ai_dry_run=0
    (( ${@[(Ie)--dry-run]} )) && ai_dry_run=1
    _sys_update_ai_result_summary "$result_report" "$ai_dry_run"
    _sys_report_result "$REPLY" "${reply[1]}"
  else
    _sys_report_result failed "result report is invalid"
  fi
  return $ai_rc
}

# Compatibility command retained from the frozen System public surface.
update-hermes() {
  _sys_update_ai_load_owner || return 1
  _sys_warn \
    "update-hermes is a compatibility command; delegating to ai-menu."
  ai-menu ai-update-hermes "$@"
}

# Aggregate applicability predicates. update-system calls them only through
# _sys_step_applies while it freezes the plan; each mirrors its step's own
# skip conditions.

_sys_update_gcloud_applies() {
  command -v gcloud &>/dev/null \
    && ! { command -v dpkg &>/dev/null \
      && dpkg -s google-cloud-cli &>/dev/null; } \
    && ! { command -v brew &>/dev/null \
      && { _sys_brew list --formula google-cloud-sdk &>/dev/null \
        || _sys_brew list --cask google-cloud-sdk &>/dev/null; }; }
}

# AWS CLI bundle installation is manual, so the aggregate never selects it.
_sys_update_awscli_applies() {
  return 1
}

_sys_update_repomix_applies() {
  local REPLY
  _sys_repomix_program && ! _sys_repomix_homebrew_managed "$REPLY"
}

_sys_update_starship_applies() {
  command -v starship &>/dev/null \
    && ! { command -v brew &>/dev/null \
      && _sys_brew list starship &>/dev/null 2>&1; } \
    && command -v cargo &>/dev/null \
    && command cargo install --list 2>/dev/null \
      | command grep -q '^starship '
}

_sys_update_uv_applies() {
  local REPLY
  _sys_uv_resolved_program \
    && ! _sys_uv_homebrew_managed "$REPLY"
}

_sys_update_pipx_applies() {
  command -v pipx &>/dev/null
}

_sys_update_node_applies() {
  builtin whence -p fnm &>/dev/null \
    || { [[ -d "${NVM_DIR:-$HOME/.nvm}" ]] \
      && command -v nvm &>/dev/null; }
}

_sys_update_rust_applies() {
  command -v rustup &>/dev/null
}

_sys_update_ai_applies() {
  _sys_update_ai_load_owner
}

typeset -g _SYS_UPDATE_TOOLS_SOURCED=1
