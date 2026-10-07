#!/usr/bin/env zsh
# =============================================================================
# ZDX Status: read-only repository, project, VPN, host, and ZDX summary
# =============================================================================
#
# Loaded lazily by functions.zsh and routed by zdx-menu.zsh; requires the core
# output and timeout services of functions.zsh at invocation.
# Safe to re-source; defines functions only.
#
# Every fact comes from a local probe: a Zsh file test, a /proc or sysfs read,
# or an external command bounded by _zdx_run_with_timeout with closed stdin.
# The command never fetches, uses the network, requests privilege, writes a
# file, or loads a suite module.
#

if [[ -n "${_ZDX_STATUS_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# REPLY: the release reported by zdx status. Commitizen bumps this line with
# the `zdx --version` string (version_files in pyproject.toml).
_zdx_status_release() { REPLY="0.1.0"; } # ZDX (Zsh Developer Experience)

_zdx_status_usage() {
  cat >&2 <<'EOF'
Usage:
  zdx status [--json]      Show a read-only repository, project, and host summary
  zdx-status [--json]      Same command, called directly

Options:
  --json                   Print one zdx.status.v1 JSON document on stdout
  -h, --help               Show this help

Facts come from bounded local probes only: no fetch, network, or privilege.
EOF
}

# Errors work before the core check, so they keep a plain fallback.
_zdx_status_error() {
  if (( ${+functions[_zdx_ui_say]} )); then
    _zdx_ui_say error "${1-}"
  else
    print -u2 -r -- "✘ ${(V)1-}"
  fi
}

_zdx_status_core_ready() {
  local service=""
  for service in _zdx_run_with_timeout _zdx_ui_say _zdx_ui_color_enabled \
    _zdx_ui_heading _zdx_ui_section _zdx_ui_label _zdx_ui_command_display \
    _zdx_count_noun; do
    (( ${+functions[$service]} )) || return 1
  done
}

# Private: run one bounded probe with closed stdin and hidden stderr. REPLY is
# its stdout; the status is the probe's own, or 124 when the bound expired.
_zdx_status_probe() {
  local seconds="${1-}"
  shift
  REPLY=""
  local probe_output=""
  local -i probe_rc=0
  probe_output=$(_zdx_run_with_timeout "$seconds" "$@" </dev/null 2>/dev/null) \
    || probe_rc=$?
  REPLY="$probe_output"
  return $probe_rc
}

# A dim, two-space detail line inside a report section.
_zdx_status_note() {
  if _zdx_ui_color_enabled; then
    printf '  \033[0;90m%s\033[0m\n' "${(V)1-}" >&2
  else
    printf '  %s\n' "${(V)1-}" >&2
  fi
}

# --- Probes ------------------------------------------------------------------

# True when git can run without side effects. On macOS, /usr/bin/git is a
# Command Line Tools placeholder that opens an installation dialog while
# xcode-select reports no developer directory, so it counts as missing.
_zdx_status_git_usable() {
  emulate -L zsh
  local git_path="${commands[git]-}" developer_dir=""
  [[ -n "$git_path" ]] || return 1
  [[ "${OSTYPE:-}" == darwin* && "$git_path" == /usr/bin/git ]] || return 0
  (( ${+commands[xcode-select]} )) || return 1
  local REPLY=""
  _zdx_status_probe 3 xcode-select -p || return 1
  developer_dir="${REPLY%%$'\n'*}"
  [[ -n "$developer_dir" && -d "$developer_dir" ]]
}

# REPLY: Linux, WSL1, WSL2, or macOS; empty for another kernel. WSL counts
# only on a Linux kernel, from its session variables, its interop
# registration, or a Microsoft kernel release; WSL1 has the synthetic
# "-Microsoft" release. The optional argument replaces /proc for fixtures.
_zdx_status_platform() {
  emulate -L zsh
  local proc_root="${1:-/proc}" kernel_release=""
  REPLY=""
  case "${OSTYPE:-}" in
    darwin*) REPLY=macOS; return 0 ;;
    linux*) ;;
    *) return 0 ;;
  esac
  if [[ -f "$proc_root/sys/kernel/osrelease" \
    && -r "$proc_root/sys/kernel/osrelease" ]]; then
    IFS= read -r kernel_release < "$proc_root/sys/kernel/osrelease" \
      2>/dev/null || true
  fi
  if [[ -n "${WSL_DISTRO_NAME:-}" || -n "${WSL_INTEROP:-}" \
    || -e "$proc_root/sys/fs/binfmt_misc/WSLInterop" \
    || -e "$proc_root/sys/fs/binfmt_misc/WSLInterop-late" \
    || "${kernel_release:l}" == *microsoft* ]]; then
    if [[ "$kernel_release" == *-Microsoft ]]; then
      REPLY=WSL1
    else
      REPLY=WSL2
    fi
  else
    REPLY=Linux
  fi
}

# REPLY: true when the Debian-family reboot flag exists, false when the host
# maintains that flag and it is absent, and null where no such flag exists.
# The optional argument is a fixture root.
_zdx_status_reboot_required() {
  emulate -L zsh
  local root="${1-}"
  REPLY=null
  [[ "${OSTYPE:-}" == linux* ]] || return 0
  if [[ -e "$root/var/run/reboot-required" ]]; then
    REPLY=true
  elif [[ -e "$root/etc/debian_version" ]]; then
    REPLY=false
  fi
}

# reply: the 1, 5, and 15 minute load averages, or nothing when unknown.
# Linux reads /proc (or the fixture root in the argument); macOS asks sysctl.
_zdx_status_load_average() {
  emulate -L zsh
  local proc_root="${1:-/proc}" line="" value=""
  local -a fields=()
  reply=()
  case "${OSTYPE:-}" in
    linux*)
      [[ -f "$proc_root/loadavg" && -r "$proc_root/loadavg" ]] || return 0
      IFS= read -r line < "$proc_root/loadavg" 2>/dev/null || true
      ;;
    darwin*)
      local REPLY=""
      _zdx_status_probe 3 sysctl -n vm.loadavg || return 0
      line="${REPLY//[\{\}]/ }"
      ;;
    *)
      return 0
      ;;
  esac
  fields=(${=line})
  (( ${#fields} >= 3 )) || return 0
  for value in "${(@)fields[1,3]}"; do
    [[ ${#value} -le 16 \
      && "$value" =~ '^(0|[1-9][0-9]*)([.][0-9]+)?$' ]] || return 0
  done
  reply=("${(@)fields[1,3]}")
}

# reply: size, used, and available bytes and the used percentage of the
# filesystem that holds HOME, from POSIX `df -P -k`; nothing when unknown.
# The filesystem and mount names can contain spaces, so the numbers are found
# before the first percentage field.
_zdx_status_home_filesystem() {
  emulate -L zsh
  reply=()
  [[ -n "${HOME:-}" && -d "$HOME" ]] || return 0
  local REPLY=""
  _zdx_status_probe 3 df -P -k -- "$HOME" || return 0
  local -a rows=("${(@f)REPLY}")
  (( ${#rows} >= 2 )) || return 0
  local -a fields=(${=rows[2]})
  local -i index=0
  for (( index = 4; index <= ${#fields}; index++ )); do
    [[ "${fields[index]}" == <->% ]] || continue
    [[ "${fields[index-3]}" == <-> && "${fields[index-2]}" == <-> \
      && "${fields[index-1]}" == <-> \
      && ${#fields[index-3]} -le 15 ]] || return 0
    reply=(
      "$(( fields[index-3] * 1024 ))"
      "$(( fields[index-2] * 1024 ))"
      "$(( fields[index-1] * 1024 ))"
      "$(( ${fields[index]%\%} ))"
    )
    return 0
  done
}

# reply: kernel WireGuard interfaces present on Linux, sorted. Status 1 means
# the answer is unknown: macOS (utun ownership is not inspected) or a host
# without sysfs or ip. The optional argument replaces /sys/class/net.
_zdx_status_wireguard_interfaces() {
  emulate -L zsh
  local net_root="${1:-/sys/class/net}"
  local interface_dir="" interface_name="" line=""
  local -a found=()
  reply=()
  [[ "${OSTYPE:-}" == linux* ]] || return 1
  if [[ -d "$net_root" ]]; then
    for interface_dir in "$net_root"/*(N); do
      [[ -f "$interface_dir/uevent" && -r "$interface_dir/uevent" ]] \
        || continue
      while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == DEVTYPE=wireguard ]]; then
          found+=("${interface_dir:t}")
          break
        fi
      done < "$interface_dir/uevent"
    done
  elif (( ${+commands[ip]} )); then
    local REPLY=""
    _zdx_status_probe 3 ip -o -d link show type wireguard || return 1
    for line in "${(@f)REPLY}"; do
      [[ "$line" =~ '^[0-9]+: ([^:@ ]+)[:@]' ]] && found+=("${match[1]}")
    done
  else
    return 1
  fi
  for interface_name in "${found[@]}"; do
    [[ "$interface_name" =~ '^[A-Za-z0-9_.-]{1,15}$' ]] \
      && reply+=("$interface_name")
  done
  # Byte order keeps the list identical under every locale.
  local LC_ALL=C
  reply=("${(@o)reply}")
  return 0
}

# Sets the repository facts in the caller's zdx_status_facts map from three
# bounded git probes. Status 1 means no Git work tree contains the current
# directory, or git is unusable.
_zdx_status_repository() {
  emulate -L zsh
  _zdx_status_git_usable || return 1
  local REPLY=""
  local -i probe_rc=0
  _zdx_status_probe 3 git rev-parse --show-toplevel --absolute-git-dir \
    || probe_rc=$?
  if (( probe_rc == 124 )); then
    _zdx_ui_say warn "git rev-parse timed out after 3s; repository facts are unknown."
    return 1
  fi
  (( probe_rc == 0 )) || return 1
  local -a locations=("${(@f)REPLY}")
  (( ${#locations} == 2 )) \
    && [[ "${locations[1]}" == /* && "${locations[2]}" == /* ]] || return 1
  local root="${locations[1]}" git_dir="${locations[2]}"
  zdx_status_facts[repo]=true
  zdx_status_facts[repo_root]="$root"

  # The operation markers live in the per-worktree Git directory.
  local operation=""
  if [[ -d "$git_dir/rebase-merge" ]]; then
    operation=rebase
  elif [[ -d "$git_dir/rebase-apply" ]]; then
    if [[ -e "$git_dir/rebase-apply/applying" ]]; then
      operation=am
    else
      operation=rebase
    fi
  elif [[ -e "$git_dir/MERGE_HEAD" ]]; then
    operation=merge
  elif [[ -e "$git_dir/CHERRY_PICK_HEAD" ]]; then
    operation=cherry-pick
  elif [[ -e "$git_dir/REVERT_HEAD" ]]; then
    operation=revert
  elif [[ -e "$git_dir/BISECT_LOG" ]]; then
    operation=bisect
  fi
  zdx_status_facts[operation]="$operation"

  # Porcelain v2 reports ahead/behind from local refs; nothing is fetched,
  # and --no-optional-locks keeps status from refreshing the index on disk.
  probe_rc=0
  _zdx_status_probe 5 git --no-optional-locks status --porcelain=v2 \
    --branch -z || probe_rc=$?
  if (( probe_rc == 0 )); then
    _zdx_status_parse_porcelain "$REPLY"
  elif (( probe_rc == 124 )); then
    _zdx_ui_say warn "git status timed out after 5s; branch and change counts are unknown."
  else
    _zdx_ui_say warn "git status failed (status $probe_rc); branch and change counts are unknown."
  fi

  # Effective configuration, including include and includeIf files.
  probe_rc=0
  _zdx_status_probe 3 git config --get user.email || probe_rc=$?
  if (( probe_rc == 0 )); then
    zdx_status_facts[user_email]="${REPLY%%$'\n'*}"
  elif (( probe_rc == 124 )); then
    _zdx_ui_say warn "git config timed out after 3s; the user email is unknown."
  fi

  # $WS_BASE_DIR/<platform>/<identity>/... names the workspace. This is a
  # fact only; deciding whether the identity matches belongs to the Git suite.
  local base="${WS_BASE_DIR-${HOME:A}/workspaces}" relative=""
  if [[ -n "$base" && "$base" == /* ]]; then
    base="${base:A}"
    if [[ "$base" != / && "$root" == "$base"/?*/?* ]]; then
      relative="${root#"$base"/}"
      zdx_status_facts[ws_platform]="${relative%%/*}"
      relative="${relative#*/}"
      zdx_status_facts[ws_identity]="${relative%%/*}"
    fi
  fi
  return 0
}

# Parses `git status --porcelain=v2 --branch -z` into the caller's
# zdx_status_facts map. A renamed or copied entry carries its original path
# in the following NUL-separated field, which is skipped.
_zdx_status_parse_porcelain() {
  emulate -L zsh
  local record="" oid="" head="" upstream="" xy=""
  local -a records=("${(@0)1}")
  local -i skip_next=0 staged=0 unstaged=0 untracked=0 conflicted=0
  local ahead=null behind=null
  for record in "${records[@]}"; do
    if (( skip_next )); then
      skip_next=0
      continue
    fi
    # The shortest match ends at the header word, never inside a value.
    case "$record" in
      '# branch.oid '*)      oid="${record#*branch.oid }" ;;
      '# branch.head '*)     head="${record#*branch.head }" ;;
      '# branch.upstream '*) upstream="${record#*branch.upstream }" ;;
      '# branch.ab '*)
        if [[ "${record#*branch.ab }" =~ '^[+]([0-9]{1,9}) -([0-9]{1,9})$' ]]; then
          ahead="$(( match[1] ))"
          behind="$(( match[2] ))"
        fi
        ;;
      '1 '*|'2 '*)
        xy="${record[3,4]}"
        [[ "${xy[1]}" != . ]] && (( staged++ ))
        [[ "${xy[2]}" != . ]] && (( unstaged++ ))
        [[ "$record" == '2 '* ]] && skip_next=1
        ;;
      'u '*) (( conflicted++ )) ;;
      '? '*) (( untracked++ )) ;;
    esac
  done
  zdx_status_facts[status_known]=true
  if [[ "$head" == '(detached)' ]]; then
    zdx_status_facts[detached]=true
  elif [[ -n "$head" ]]; then
    zdx_status_facts[detached]=false
    zdx_status_facts[branch]="$head"
  fi
  [[ "$oid" =~ '^[0-9a-f]{40,64}$' ]] && zdx_status_facts[commit]="$oid"
  zdx_status_facts[upstream]="$upstream"
  zdx_status_facts[ahead]="$ahead"
  zdx_status_facts[behind]="$behind"
  zdx_status_facts[staged]="$staged"
  zdx_status_facts[unstaged]="$unstaged"
  zdx_status_facts[untracked]="$untracked"
  zdx_status_facts[conflicted]="$conflicted"
}

# Sets the project facts and the caller's zdx_status_files array. The project
# directory is the nearest directory, from the current one up to the
# repository root given as the argument, that holds a project file; outside a
# repository only the current directory is inspected.
_zdx_status_project() {
  emulate -L zsh
  local stop="${1-}" directory="${PWD:A}" name=""
  local -a found=()
  while true; do
    found=("$directory"/(pyproject.toml|uv.lock|package.json|Cargo.toml|go.mod|[Jj]ustfile|Makefile)(N))
    (( ${#found} > 0 )) && break
    if [[ -n "$stop" && "$directory" != "$stop" && "$directory" == "$stop"/* ]]; then
      directory="${directory:h}"
    else
      directory=""
      break
    fi
  done

  zdx_status_facts[venv_active]=false
  [[ -n "${VIRTUAL_ENV:-}" ]] && zdx_status_facts[venv_active]=true
  [[ -n "$directory" ]] || return 0

  zdx_status_facts[project_dir]="$directory"
  for name in pyproject.toml uv.lock package.json Cargo.toml go.mod \
    Justfile justfile Makefile; do
    (( ${found[(Ie)$directory/$name]} )) && zdx_status_files+=("$name")
  done

  zdx_status_facts[project_venv_present]=false
  [[ -d "$directory/.venv" ]] && zdx_status_facts[project_venv_present]=true
  zdx_status_facts[project_venv_active]=false
  [[ -n "${VIRTUAL_ENV:-}" && "${VIRTUAL_ENV:A}" == "$directory/.venv" ]] \
    && zdx_status_facts[project_venv_active]=true

  if [[ -f "$directory/pyproject.toml" && -f "$directory/uv.lock" ]] \
    && zmodload -F zsh/stat b:zstat 2>/dev/null; then
    local -A pyproject_state=() lock_state=()
    if zstat -H pyproject_state -- "$directory/pyproject.toml" 2>/dev/null \
      && zstat -H lock_state -- "$directory/uv.lock" 2>/dev/null; then
      if (( lock_state[mtime] < pyproject_state[mtime] )); then
        zdx_status_facts[uv_lock_older]=true
      else
        zdx_status_facts[uv_lock_older]=false
      fi
    fi
  fi
}

# Collects every fact into the caller's zdx_status_facts map and arrays.
# Strings are empty when unknown; numbers and booleans hold JSON literals.
_zdx_status_collect() {
  emulate -L zsh
  local REPLY=""
  local -a reply=()
  zdx_status_facts=(
    repo false repo_root "" branch "" detached null commit "" upstream ""
    ahead null behind null status_known false staged null unstaged null
    untracked null conflicted null operation "" user_email ""
    ws_platform "" ws_identity ""
    project_dir "" venv_active false project_venv_present null
    project_venv_active null uv_lock_older null
    wireguard_known false platform "" reboot_required null
    disk_size null disk_used null disk_available null disk_percent null
    load_1 null load_5 null load_15 null
    version "" plugins 0 telemetry false verbose false
  )
  zdx_status_files=()
  zdx_status_wireguard=()

  _zdx_status_repository || true
  _zdx_status_project "${zdx_status_facts[repo_root]}"

  if _zdx_status_wireguard_interfaces; then
    zdx_status_facts[wireguard_known]=true
    zdx_status_wireguard=("${reply[@]}")
  fi

  _zdx_status_platform
  zdx_status_facts[platform]="$REPLY"
  _zdx_status_reboot_required
  zdx_status_facts[reboot_required]="$REPLY"
  _zdx_status_home_filesystem
  if (( ${#reply} == 4 )); then
    zdx_status_facts[disk_size]="${reply[1]}"
    zdx_status_facts[disk_used]="${reply[2]}"
    zdx_status_facts[disk_available]="${reply[3]}"
    zdx_status_facts[disk_percent]="${reply[4]}"
  fi
  _zdx_status_load_average
  if (( ${#reply} == 3 )); then
    zdx_status_facts[load_1]="${reply[1]}"
    zdx_status_facts[load_5]="${reply[2]}"
    zdx_status_facts[load_15]="${reply[3]}"
  fi

  _zdx_status_release
  zdx_status_facts[version]="$REPLY"
  (( ${+ZDX_LOADED_PLUGINS} )) \
    && zdx_status_facts[plugins]="${#ZDX_LOADED_PLUGINS[@]}"
  [[ "${ZDX_TELEMETRY:-}" == 1 || "${ZDX_TELEMETRY:-}" == true ]] \
    && zdx_status_facts[telemetry]=true
  [[ "${ZDX_VERBOSE:-0}" == 1 ]] && zdx_status_facts[verbose]=true
  return 0
}

# --- Rendering -----------------------------------------------------------------

# REPLY: a byte count with one decimal in KiB, MiB, GiB, TiB, or PiB. Integer
# arithmetic keeps LC_NUMERIC from changing the decimal point.
_zdx_status_format_bytes() {
  emulate -L zsh
  local -i bytes="${1:-0}" unit_size=1 tenths=0 exponent=0
  local -a units=(B KiB MiB GiB TiB PiB)
  while (( exponent < 5 && bytes >= unit_size * 1024 )); do
    (( unit_size *= 1024, exponent++ ))
  done
  if (( exponent == 0 )); then
    REPLY="$bytes B"
    return 0
  fi
  (( tenths = (bytes * 10 + unit_size / 2) / unit_size ))
  REPLY="$(( tenths / 10 )).$(( tenths % 10 )) ${units[exponent + 1]}"
}

# REPLY: a path for display, with HOME shown as ~.
_zdx_status_display_path() {
  _zdx_ui_command_display "${1-}"
}

_zdx_status_render_repository() {
  emulate -L zsh
  local REPLY="" value=""
  _zdx_ui_section --first "Repository"
  if [[ "${zdx_status_facts[repo]}" != true ]]; then
    _zdx_status_note "Not inside a Git work tree."
    return 0
  fi
  _zdx_status_display_path "${zdx_status_facts[repo_root]}"
  _zdx_ui_label "Root" "$REPLY"

  if [[ "${zdx_status_facts[status_known]}" != true ]]; then
    value="unknown"
  elif [[ "${zdx_status_facts[detached]}" == true ]]; then
    value="detached at ${zdx_status_facts[commit][1,12]}"
    [[ -n "${zdx_status_facts[commit]}" ]] || value="detached"
  elif [[ -z "${zdx_status_facts[commit]}" ]]; then
    value="${zdx_status_facts[branch]} (no commits yet)"
  else
    value="${zdx_status_facts[branch]}"
    if [[ -n "${zdx_status_facts[upstream]}" ]]; then
      value+=" → ${zdx_status_facts[upstream]}"
      if [[ "${zdx_status_facts[ahead]}" != null ]]; then
        value+=", ahead ${zdx_status_facts[ahead]}, behind ${zdx_status_facts[behind]}"
      else
        value+=", upstream branch missing"
      fi
    else
      value+=" (no upstream)"
    fi
  fi
  _zdx_ui_label "Branch" "$value"

  if [[ "${zdx_status_facts[status_known]}" != true ]]; then
    value="unknown"
  else
    local -a parts=()
    local count_key=""
    for count_key in staged unstaged untracked conflicted; do
      (( zdx_status_facts[$count_key] > 0 )) \
        && parts+=("${zdx_status_facts[$count_key]} $count_key")
    done
    value="${(j:, :)parts}"
    [[ -n "$value" ]] || value="clean"
  fi
  _zdx_ui_label "Changes" "$value"

  [[ -n "${zdx_status_facts[operation]}" ]] \
    && _zdx_ui_label "Operation" "${zdx_status_facts[operation]} in progress"
  value="${zdx_status_facts[user_email]}"
  _zdx_ui_label "User email" "${value:-not set}"
  [[ -n "${zdx_status_facts[ws_platform]}" ]] \
    && _zdx_ui_label "Workspace" \
      "${zdx_status_facts[ws_platform]} / ${zdx_status_facts[ws_identity]}"
  return 0
}

_zdx_status_render_project() {
  emulate -L zsh
  local REPLY="" value=""
  _zdx_ui_section "Project"
  if [[ -z "${zdx_status_facts[project_dir]}" ]]; then
    if [[ "${zdx_status_facts[repo]}" == true ]]; then
      _zdx_status_note "No project file between here and the repository root."
    else
      _zdx_status_note "No project file in the current directory."
    fi
  else
    _zdx_status_display_path "${zdx_status_facts[project_dir]}"
    _zdx_ui_label "Directory" "$REPLY"
    _zdx_ui_label "Files" "${(j:, :)zdx_status_files}"
  fi

  if [[ "${zdx_status_facts[venv_active]}" == true ]]; then
    case "${zdx_status_facts[project_venv_active]}" in
      true)  value="active: project .venv" ;;
      false) value="active: outside this project" ;;
      *)     value="active" ;;
    esac
  else
    value="inactive"
    [[ "${zdx_status_facts[project_venv_present]}" == true ]] \
      && value+="; project .venv present"
  fi
  _zdx_ui_label "Virtualenv" "$value"

  case "${zdx_status_facts[uv_lock_older]}" in
    true)  _zdx_ui_label "Lockfile" "uv.lock is older than pyproject.toml" ;;
    false) _zdx_ui_label "Lockfile" "uv.lock is not older than pyproject.toml" ;;
  esac
  return 0
}

_zdx_status_render_host() {
  emulate -L zsh
  local REPLY="" value=""
  _zdx_ui_section "VPN"
  if [[ "${zdx_status_facts[wireguard_known]}" != true ]]; then
    if [[ "${zdx_status_facts[platform]}" == macOS ]]; then
      value="unknown on macOS (utun devices are not attributed)"
    else
      value="unknown"
    fi
  elif (( ${#zdx_status_wireguard} == 0 )); then
    value="no active interface"
  else
    value="${(j:, :)zdx_status_wireguard}"
  fi
  _zdx_ui_label "WireGuard" "$value"

  _zdx_ui_section "Host"
  value="${zdx_status_facts[platform]}"
  _zdx_ui_label "Platform" "${value:-unknown}"
  case "${zdx_status_facts[reboot_required]}" in
    true)  value="yes" ;;
    false) value="no" ;;
    *)     value="unknown" ;;
  esac
  _zdx_ui_label "Reboot required" "$value"
  if [[ "${zdx_status_facts[disk_size]}" != null ]]; then
    local available="" size=""
    _zdx_status_format_bytes "${zdx_status_facts[disk_available]}"
    available="$REPLY"
    _zdx_status_format_bytes "${zdx_status_facts[disk_size]}"
    size="$REPLY"
    value="${zdx_status_facts[disk_percent]}% used, $available free of $size"
  else
    value="unknown"
  fi
  _zdx_ui_label "Home filesystem" "$value"
  if [[ "${zdx_status_facts[load_1]}" != null ]]; then
    value="${zdx_status_facts[load_1]} ${zdx_status_facts[load_5]} ${zdx_status_facts[load_15]}"
  else
    value="unknown"
  fi
  _zdx_ui_label "Load average" "$value"
  return 0
}

_zdx_status_render_zdx() {
  emulate -L zsh
  local REPLY="" telemetry=off verbose=off
  _zdx_ui_section "ZDX"
  _zdx_ui_label "Version" "${zdx_status_facts[version]}"
  _zdx_count_noun "${zdx_status_facts[plugins]}" "custom plugin"
  _zdx_ui_label "Plugins" "$REPLY loaded"
  [[ "${zdx_status_facts[telemetry]}" == true ]] && telemetry=on
  [[ "${zdx_status_facts[verbose]}" == true ]] && verbose=on
  _zdx_ui_label "Settings" "telemetry $telemetry, verbose $verbose"
  return 0
}

_zdx_status_render_text() {
  _zdx_ui_heading "ZDX Status"
  _zdx_status_render_repository
  _zdx_status_render_project
  _zdx_status_render_host
  _zdx_status_render_zdx
}

# Prints one zdx.status.v1 document as a single compact line. The filter is a
# constant program and every value enters it through --arg or --argjson; -c
# keeps the document on one line and -M keeps jq from coloring a terminal.
_zdx_status_render_json() {
  emulate -L zsh
  local generated_at="" document=""
  if zmodload zsh/datetime 2>/dev/null; then
    generated_at=$(TZ=UTC strftime '%Y-%m-%dT%H:%M:%SZ' "$EPOCHSECONDS")
  fi
  local fact=""
  # Numbers and booleans must be JSON literals before --argjson sees them.
  for fact in detached ahead behind staged unstaged untracked conflicted \
    venv_active project_venv_present project_venv_active uv_lock_older \
    reboot_required disk_size disk_used disk_available disk_percent \
    load_1 load_5 load_15 plugins telemetry verbose repo wireguard_known; do
    [[ "${zdx_status_facts[$fact]}" == (null|true|false) \
      || "${zdx_status_facts[$fact]}" =~ '^(0|[1-9][0-9]*)([.][0-9]+)?$' ]] \
      || zdx_status_facts[$fact]=null
  done

  local -a jq_arguments=(
    --arg generated_at "$generated_at"
    --argjson in_repo "${zdx_status_facts[repo]}"
    --arg repo_root "${zdx_status_facts[repo_root]}"
    --arg branch "${zdx_status_facts[branch]}"
    --argjson detached "${zdx_status_facts[detached]}"
    --arg commit "${zdx_status_facts[commit]}"
    --arg upstream "${zdx_status_facts[upstream]}"
    --argjson ahead "${zdx_status_facts[ahead]}"
    --argjson behind "${zdx_status_facts[behind]}"
    --argjson staged "${zdx_status_facts[staged]}"
    --argjson unstaged "${zdx_status_facts[unstaged]}"
    --argjson untracked "${zdx_status_facts[untracked]}"
    --argjson conflicted "${zdx_status_facts[conflicted]}"
    --arg operation "${zdx_status_facts[operation]}"
    --arg user_email "${zdx_status_facts[user_email]}"
    --arg ws_platform "${zdx_status_facts[ws_platform]}"
    --arg ws_identity "${zdx_status_facts[ws_identity]}"
    --arg project_dir "${zdx_status_facts[project_dir]}"
    --arg project_files "${(pj:\n:)zdx_status_files}"
    --argjson venv_active "${zdx_status_facts[venv_active]}"
    --argjson project_venv_present "${zdx_status_facts[project_venv_present]}"
    --argjson project_venv_active "${zdx_status_facts[project_venv_active]}"
    --argjson uv_lock_older "${zdx_status_facts[uv_lock_older]}"
    --argjson wireguard_known "${zdx_status_facts[wireguard_known]}"
    --arg wireguard "${(pj:\n:)zdx_status_wireguard}"
    --arg platform "${zdx_status_facts[platform]}"
    --argjson reboot_required "${zdx_status_facts[reboot_required]}"
    --argjson disk_size "${zdx_status_facts[disk_size]}"
    --argjson disk_used "${zdx_status_facts[disk_used]}"
    --argjson disk_available "${zdx_status_facts[disk_available]}"
    --argjson disk_percent "${zdx_status_facts[disk_percent]}"
    --argjson load_1 "${zdx_status_facts[load_1]}"
    --argjson load_5 "${zdx_status_facts[load_5]}"
    --argjson load_15 "${zdx_status_facts[load_15]}"
    --arg version "${zdx_status_facts[version]}"
    --argjson plugins "${zdx_status_facts[plugins]}"
    --argjson telemetry "${zdx_status_facts[telemetry]}"
    --argjson verbose "${zdx_status_facts[verbose]}"
  )
  local filter='
    def text: if . == "" then null else . end;
    def lines: if . == "" then [] else split("\n") end;
    {
      schema: "zdx.status.v1",
      generated_at: ($generated_at | text),
      repository: (if $in_repo then {
        root: $repo_root,
        branch: ($branch | text),
        detached: $detached,
        commit: ($commit | text),
        upstream: ($upstream | text),
        ahead: $ahead,
        behind: $behind,
        staged: $staged,
        unstaged: $unstaged,
        untracked: $untracked,
        conflicted: $conflicted,
        operation: ($operation | text),
        user_email: ($user_email | text),
        workspace: (if $ws_platform == "" then null
          else {platform: $ws_platform, identity: $ws_identity} end)
      } else null end),
      project: {
        directory: ($project_dir | text),
        files: ($project_files | lines),
        virtual_env_active: $venv_active,
        project_venv_present: $project_venv_present,
        project_venv_active: $project_venv_active,
        uv_lock_older_than_pyproject: $uv_lock_older
      },
      vpn: {
        wireguard_interfaces: (if $wireguard_known
          then ($wireguard | lines) else null end)
      },
      host: {
        platform: ($platform | text),
        reboot_required: $reboot_required,
        home_filesystem: (if $disk_size == null then null else {
          size_bytes: $disk_size,
          used_bytes: $disk_used,
          available_bytes: $disk_available,
          used_percent: $disk_percent
        } end),
        load_average: (if $load_1 == null then null
          else [$load_1, $load_5, $load_15] end)
      },
      zdx: {
        version: $version,
        custom_plugins: $plugins,
        telemetry: $telemetry,
        verbose: $verbose
      }
    }'
  document=$(command jq -c -n -M "${jq_arguments[@]}" "$filter" 2>/dev/null) \
    && [[ -n "$document" ]] || {
    _zdx_ui_say error "jq could not build the zdx.status.v1 document."
    return 1
  }
  print -r -- "$document"
}

# Private: collect once, then render the requested mode.
_zdx_status_run() {
  local mode="${1:-text}"
  local -A zdx_status_facts=()
  local -a zdx_status_files=() zdx_status_wireguard=()
  _zdx_status_collect
  if [[ "$mode" == json ]]; then
    _zdx_status_render_json
  else
    _zdx_status_render_text
  fi
}

# Public: zdx-status [--json]. Read-only; never opens fzf or prompts, so it
# runs non-interactively. Text goes to stderr; --json prints one document on
# stdout. Status 0 on success, 1 without the core runtime or (for --json) jq,
# and 2 for invalid arguments. See docs/user-guide.md.
zdx-status() {
  local mode=text
  case "${1-}" in
    "")
      if (( $# > 0 )); then
        _zdx_status_error "Unexpected empty zdx status argument."
        return 2
      fi
      ;;
    --json)
      (( $# == 1 )) || {
        _zdx_status_error "zdx status --json accepts no additional arguments."
        return 2
      }
      mode=json
      ;;
    -h|--help)
      (( $# == 1 )) || {
        _zdx_status_error "zdx status help accepts no additional arguments."
        return 2
      }
      _zdx_status_usage
      return 0
      ;;
    -*)
      _zdx_status_error "Unknown zdx status option: '$1'."
      return 2
      ;;
    *)
      _zdx_status_error "Unexpected zdx status argument: '$1'."
      return 2
      ;;
  esac

  _zdx_status_core_ready || {
    _zdx_status_error \
      "zdx status needs the ZDX core runtime; load zdx-suite.plugin.zsh or functions.zsh."
    return 1
  }
  if [[ "$mode" == json ]] && (( ! ${+commands[jq]} )); then
    _zdx_status_error "jq is required for zdx status --json; run zdx doctor."
    return 1
  fi

  if (( ${+functions[_timed]} )); then
    _timed "zdx:status" _zdx_status_run "$mode"
  else
    _zdx_status_run "$mode"
  fi
}

typeset -g _ZDX_STATUS_SOURCED=1
