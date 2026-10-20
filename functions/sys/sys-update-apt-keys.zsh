#!/usr/bin/env zsh
# =============================================================================
# System Update APT Keys: signing-key renewal for known APT repositories
# =============================================================================
#
# Loaded by sys-menu.zsh after sys-common.zsh, before sys-update-apt.zsh.
# Safe to re-source; defines functions only.
#
# Only update-apt uses these helpers. The renewal transaction runs inside
# _sys_apt_refresh_indexes and reads that caller's dynamically scoped state:
# privilege_prefix and privilege_label (update-apt), plus the renewal records
# apt_key_context, apt_key_pending, apt_key_renewed, and apt_key_outcomes.
#

if [[ -n "${_SYS_UPDATE_APT_KEYS_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# --- Configuration, layout, and registry --------------------------------------

# Status 0 when renewal is enabled (the default), 1 when SYS_APT_KEY_RENEWAL=0,
# and 2 for any other value, which fails closed before any APT work.
_sys_apt_key_renewal_enabled() {
  case "${SYS_APT_KEY_RENEWAL:-1}" in
    1) return 0 ;;
    0) return 1 ;;
    *)
      _sys_error "SYS_APT_KEY_RENEWAL must be exactly 0 or 1."
      return 2
      ;;
  esac
}

# reply=(<sources.list> <sources.list.d> <keyring-owner-uid> <keyring-dir>...)
# The fixed host layout. Tests replace this function with a sandbox layout.
_sys_apt_key_layout() {
  reply=(
    /etc/apt/sources.list
    /etc/apt/sources.list.d
    0
    /etc/apt/keyrings
    /usr/share/keyrings
  )
}

# REPLY: the repositories whose keys ZDX renews automatically, for messages.
_sys_apt_key_registry_summary() {
  REPLY="GitHub CLI, Google Cloud SDK, Charm, Docker, HashiCorp, Microsoft, NodeSource, and Google Chrome"
}

_sys_apt_key_path_within() {
  [[ "${1-}" == "${2-}" || "${1-}" == "${2-}"/* ]]
}

# reply=(<display-name> <key-url>) for an APT source URI that ZDX renews
# automatically. The match uses the URI's scheme, host, and path prefix; the
# key URL is always HTTPS on the publisher's own domain. Status 1: unknown.
_sys_apt_key_registry_match() {
  emulate -L zsh
  local uri="${1-}" rest="" host="" repo_path="/" distro=""
  reply=()
  [[ "$uri" == https://?* \
    && "$uri" != *[[:space:][:cntrl:]\\]* ]] || return 1
  rest="${uri#https://}"
  host="${rest%%/*}"
  [[ "$rest" == */* ]] && repo_path="/${rest#*/}"
  # Credentials, ports, and percent-encoded hosts never match an entry.
  [[ -n "$host" && "$host" != *[@:%]* ]] || return 1
  host="${host:l}"
  [[ "$repo_path" != *[?#%]* \
    && "$repo_path/" != */../* \
    && "$repo_path/" != */./* ]] || return 1
  while [[ "$repo_path" == ?*/ ]]; do
    repo_path="${repo_path%/}"
  done
  case "$host" in
    cli.github.com)
      _sys_apt_key_path_within "$repo_path" /packages || return 1
      reply=("GitHub CLI"
        "https://cli.github.com/packages/githubcli-archive-keyring.gpg")
      ;;
    packages.cloud.google.com)
      _sys_apt_key_path_within "$repo_path" /apt || return 1
      reply=("Google Cloud SDK"
        "https://packages.cloud.google.com/apt/doc/apt-key.gpg")
      ;;
    repo.charm.sh)
      _sys_apt_key_path_within "$repo_path" /apt || return 1
      reply=("Charm" "https://repo.charm.sh/apt/gpg.key")
      ;;
    download.docker.com)
      for distro in debian ubuntu; do
        if _sys_apt_key_path_within "$repo_path" "/linux/$distro"; then
          reply=("Docker" "https://download.docker.com/linux/$distro/gpg")
          return 0
        fi
      done
      return 1
      ;;
    apt.releases.hashicorp.com)
      reply=("HashiCorp" "https://apt.releases.hashicorp.com/gpg")
      ;;
    packages.microsoft.com)
      reply=("Microsoft" "https://packages.microsoft.com/keys/microsoft.asc")
      ;;
    deb.nodesource.com)
      reply=("NodeSource"
        "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key")
      ;;
    dl.google.com)
      _sys_apt_key_path_within "$repo_path" /linux || return 1
      reply=("Google Chrome"
        "https://dl.google.com/linux/linux_signing_key.pub")
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}

# --- APT sources --------------------------------------------------------------

# REPLY: <uri> without trailing slashes, the form APT prints in its messages.
_sys_apt_key_normalize_uri() {
  local uri="${1-}"
  while [[ "$uri" == ?*/ ]]; do
    uri="${uri%/}"
  done
  REPLY="$uri"
}

# REPLY: the signed-by classification of one option value: an absolute
# keyring path, "-" for none, "inline" for an embedded key block, or "other"
# for fingerprints and several keyrings.
_sys_apt_key_signed_by_kind() {
  local value="${1-}"
  local -a words=(${=value})
  if [[ -z "${value//[[:space:]]/}" ]]; then
    REPLY="-"
  elif [[ "$value" == *"BEGIN PGP PUBLIC KEY BLOCK"* ]]; then
    REPLY="inline"
  elif (( ${#words} == 1 )) && [[ "${words[1]}" == /* \
    && "${words[1]}" != *,* ]]; then
    REPLY="${words[1]}"
  else
    REPLY="other"
  fi
}

# Appends one-line-style entries of <file> to the caller's records.
# Record: <uri><TAB><suite><TAB><signed-by><TAB><file>.
_sys_apt_key_parse_one_line() {
  emulate -L zsh
  local source_file="${1-}" line="" option="" option_text="" signed_by=""
  local uri="" suite=""
  local -a words=() options=()
  local -i index=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%\#*}"
    words=(${=line})
    (( ${#words} >= 3 )) || continue
    [[ "${words[1]}" == deb || "${words[1]}" == deb-src ]] || continue
    index=2
    options=()
    if [[ "${words[2]}" == \[* ]]; then
      option_text=""
      while (( index <= ${#words} )); do
        option_text+=" ${words[index]}"
        if [[ "${words[index]}" == *\] ]]; then
          (( ++index ))
          break
        fi
        (( ++index ))
      done
      option_text="${option_text#*\[}"
      option_text="${option_text%\]*}"
      options=(${=option_text})
    fi
    uri="${words[index]:-}"
    suite="${words[index+1]:-}"
    [[ -n "$uri" && -n "$suite" ]] || continue
    signed_by="-"
    for option in "${options[@]}"; do
      if [[ "$option" == signed-by=* ]]; then
        _sys_apt_key_signed_by_kind "${option#signed-by=}"
        signed_by="$REPLY"
      fi
    done
    _sys_apt_key_normalize_uri "$uri"
    records+=("$REPLY"$'\t'"$suite"$'\t'"$signed_by"$'\t'"$source_file")
  done < "$source_file"
  return 0
}

# Appends the entries of one deb822 stanza, held in the caller's stanza map.
_sys_apt_key_emit_stanza() {
  emulate -L zsh
  local uri="" suite="" signed_by=""
  [[ -n "${stanza[uris]-}" && -n "${stanza[suites]-}" ]] || return 0
  [[ " ${stanza[types]-} " == *" deb "* \
    || " ${stanza[types]-} " == *" deb-src "* ]] || return 0
  case "${${stanza[enabled]-yes}:l}" in
    no|false|0) return 0 ;;
  esac
  _sys_apt_key_signed_by_kind "${stanza[signed-by]-}"
  signed_by="$REPLY"
  for uri in ${=stanza[uris]}; do
    _sys_apt_key_normalize_uri "$uri"
    uri="$REPLY"
    for suite in ${=stanza[suites]}; do
      records+=("$uri"$'\t'"$suite"$'\t'"$signed_by"$'\t'"$source_file")
    done
  done
  return 0
}

# Appends the deb822 entries of <file> to the caller's records.
_sys_apt_key_parse_deb822() {
  emulate -L zsh
  setopt EXTENDED_GLOB
  local source_file="${1-}" line="" field="" value="" current=""
  local -A stanza=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" == \#* ]] && continue
    if [[ -z "${line//[[:space:]]/}" ]]; then
      _sys_apt_key_emit_stanza
      stanza=()
      current=""
      continue
    fi
    if [[ "$line" == [[:space:]]* ]]; then
      [[ -n "$current" ]] && stanza[$current]+=$'\n'"${line##[[:space:]]#}"
      continue
    fi
    if [[ "$line" == [A-Za-z][A-Za-z0-9-]#:* ]]; then
      field="${${line%%:*}:l}"
      value="${line#*:}"
      value="${value##[[:space:]]#}"
      value="${value%%[[:space:]]#}"
      stanza[$field]="$value"
      current="$field"
    fi
  done < "$source_file"
  _sys_apt_key_emit_stanza
  return 0
}

# reply: "<uri><TAB><suite><TAB><signed-by><TAB><file>" for every enabled APT
# source entry, read from sources.list and the *.list and *.sources files of
# sources.list.d. Files larger than 1 MiB are skipped; at most 256 files and
# 2048 entries are read. Nothing is written.
_sys_apt_key_source_entries() {
  emulate -L zsh
  setopt EXTENDED_GLOB NULL_GLOB
  local -a layout=() source_files=() records=()
  local source_file=""
  local -A file_state=()
  _sys_apt_key_layout
  layout=("${reply[@]}")
  reply=()
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  [[ -f "${layout[1]}" ]] && source_files+=("${layout[1]}")
  if [[ -d "${layout[2]}" ]]; then
    source_files+=("${layout[2]}"/*.list(N-.) "${layout[2]}"/*.sources(N-.))
  fi
  for source_file in "${(@)source_files[1,256]}"; do
    [[ -r "$source_file" ]] || continue
    file_state=()
    zstat -H file_state -- "$source_file" 2>/dev/null || continue
    (( file_state[size] <= 1048576 )) || continue
    if [[ "$source_file" == *.sources ]]; then
      _sys_apt_key_parse_deb822 "$source_file"
    else
      _sys_apt_key_parse_one_line "$source_file"
    fi
    (( ${#records} <= 2048 )) || break
  done
  reply=("${(@)records[1,2048]}")
  return 0
}

# REPLY: "<signed-by><TAB><file>" of the entry for <repository>, APT's
# "<uri> <suite>" form. An exact suite match wins; otherwise all entries for
# the URI must agree. Usage: _sys_apt_key_source_lookup <repository> <entry>...
_sys_apt_key_source_lookup() {
  emulate -L zsh
  local repository="${1-}" record="" uri="" suite=""
  shift
  local -a fields=() uri_matches=()
  REPLY=""
  uri="${repository%% *}"
  [[ "$repository" == *" "* ]] && suite="${repository#* }"
  _sys_apt_key_normalize_uri "$uri"
  uri="$REPLY"
  REPLY=""
  for record in "$@"; do
    fields=("${(@ps:\t:)record}")
    [[ "${fields[1]}" == "$uri" ]] || continue
    if [[ "${fields[2]}" == "$suite" ]]; then
      REPLY="${fields[3]}"$'\t'"${fields[4]}"
      return 0
    fi
    uri_matches+=("${fields[3]}"$'\t'"${fields[4]}")
  done
  uri_matches=("${(@u)uri_matches}")
  (( ${#uri_matches} == 1 )) || return 1
  REPLY="${uri_matches[1]}"
}

# reply: the "<uri> <suite>" repositories of every entry that uses <keyring>.
# Status 1 when they belong to different registry entries or to a repository
# ZDX does not know. Usage: _sys_apt_key_keyring_repositories <keyring> <url>
#   <entry>...
_sys_apt_key_keyring_repositories() {
  emulate -L zsh
  local keyring="${1-}" key_url="${2-}" record=""
  shift 2
  local -a fields=() repositories=()
  for record in "$@"; do
    fields=("${(@ps:\t:)record}")
    [[ "${fields[3]}" == "$keyring" ]] || continue
    _sys_apt_key_registry_match "${fields[1]}" || return 1
    [[ "${reply[2]}" == "$key_url" ]] || return 1
    repositories+=("${fields[1]} ${fields[2]}")
  done
  reply=("${(@u)repositories}")
  (( ${#reply} > 0 ))
}

# --- Keyring files ------------------------------------------------------------

# Status 0 when <keyring> is a dedicated keyring ZDX may replace: a plain
# absolute .gpg or .asc path directly in an allowed keyring directory, a
# regular single-link file (not a link) owned by root and not writable by
# group or others, inside a real root-owned directory with the same
# restriction. REPLY: its mode as four octal digits, or the refusal reason.
_sys_apt_key_keyring_renewable() {
  emulate -L zsh
  local keyring="${1-}" directory=""
  local -a layout=() keyring_dirs=()
  local -A path_state=()
  REPLY=""
  _sys_apt_key_layout
  layout=("${reply[@]}")
  local owner_uid="${layout[3]}"
  keyring_dirs=("${(@)layout[4,-1]}")
  if [[ "$keyring" != /* || "$keyring" == *[[:cntrl:][:space:]]* \
    || "$keyring" != "${keyring:a}" ]]; then
    REPLY="its signed-by value is not a plain absolute path"
    return 1
  fi
  directory="${keyring:h}"
  if (( ! ${keyring_dirs[(Ie)$directory]} )); then
    REPLY="it is not in ${(j: or :)keyring_dirs}"
    return 1
  fi
  if [[ "$keyring" != *.gpg && "$keyring" != *.asc ]]; then
    REPLY="its name does not end in .gpg or .asc"
    return 1
  fi
  zmodload -F zsh/stat b:zstat 2>/dev/null || {
    REPLY="its metadata cannot be read"
    return 1
  }
  if ! [[ -d "$directory" && ! -L "$directory" \
    && "$directory" == "${directory:A}" ]] \
    || ! zstat -H path_state -- "$directory" 2>/dev/null \
    || (( path_state[uid] != owner_uid \
      || (path_state[mode] & 8#22) != 0 )); then
    REPLY="its directory is not a root-owned directory that only root can write"
    return 1
  fi
  if [[ -L "$keyring" ]]; then
    REPLY="it is a symbolic link"
    return 1
  fi
  path_state=()
  if ! [[ -f "$keyring" ]] \
    || ! zstat -LH path_state -- "$keyring" 2>/dev/null; then
    REPLY="it is missing or not a regular file"
    return 1
  fi
  if (( path_state[uid] != owner_uid )); then
    REPLY="it is not owned by root"
    return 1
  fi
  if (( (path_state[mode] & 8#7022) != 0 )); then
    REPLY="it is group- or world-writable"
    return 1
  fi
  if (( path_state[nlink] != 1 )); then
    REPLY="it has more than one hard link"
    return 1
  fi
  if (( path_state[size] > 1048576 )); then
    REPLY="it is larger than 1 MiB"
    return 1
  fi
  printf -v REPLY '%04o' $(( path_state[mode] & 8#777 ))
}

# REPLY: valid, expired, revoked, or invalid for one gpg colon record.
# Usage: _sys_apt_key_state <validity> <expires> <now>
_sys_apt_key_state() {
  local validity="${1-}" expires="${2-}" now="${3:-0}"
  case "$validity" in
    r) REPLY=revoked ;;
    e) REPLY=expired ;;
    i|d|n) REPLY=invalid ;;
    *)
      if [[ -z "$expires" ]]; then
        REPLY=valid
      elif [[ "$expires" != <-> || ${#expires} -gt 12 ]]; then
        REPLY=invalid
      elif (( expires > 0 && expires <= now )); then
        REPLY=expired
      else
        REPLY=valid
      fi
      ;;
  esac
}

# reply: "<pub|sub><TAB><fingerprint><TAB><state><TAB><signing><TAB><expires>"
# for each key of an OpenPGP keyring file, parsed by gpg in the private
# throwaway <gnupg-home>; the user's own keyring is never read. A subkey is
# no more usable than its primary key. Status 1 when gpg fails, 2 when the
# file holds secret keys, no key, or a malformed record.
# Usage: _sys_apt_key_list <gpg> <gnupg-home> <file>
_sys_apt_key_list() {
  emulate -L zsh
  setopt EXTENDED_GLOB
  local gpg_program="${1-}" gnupg_home="${2-}" key_file="${3-}"
  local listing="" line="" kind="" state="" primary_state="" caps=""
  local expires="" fingerprint=""
  local -a fields=() records=()
  local -i pending=0 now=0
  reply=()
  [[ "$gpg_program" == /* && -d "$gnupg_home" && -f "$key_file" ]] || return 1
  zmodload zsh/datetime 2>/dev/null || return 1
  now=$EPOCHSECONDS
  listing=$(
    _sys_run_bounded_probe 15 262144 \
      "$gpg_program" --batch --no-options --no-autostart \
      --homedir "$gnupg_home" --with-colons --show-keys -- "$key_file" \
      </dev/null 2>/dev/null
  ) || return 1
  for line in "${(@f)listing}"; do
    fields=("${(@s.:.)line}")
    case "${fields[1]}" in
      pub|sub)
        kind="${fields[1]}"
        _sys_apt_key_state "${fields[2]-}" "${fields[7]-}" "$now"
        state="$REPLY"
        if [[ "$kind" == pub ]]; then
          primary_state="$state"
        elif [[ -z "$primary_state" ]]; then
          state=invalid
        elif [[ "$primary_state" != valid ]]; then
          state="$primary_state"
        fi
        caps="${fields[12]-}"
        expires="${fields[7]-}"
        pending=1
        ;;
      fpr)
        (( pending )) || continue
        pending=0
        fingerprint="${${fields[10]-}:u}"
        [[ "$fingerprint" == [0-9A-F](#c40,64) ]] || return 2
        if [[ "$caps" == *s* ]]; then
          records+=("$kind"$'\t'"$fingerprint"$'\t'"$state"$'\t1\t'"$expires")
        else
          records+=("$kind"$'\t'"$fingerprint"$'\t'"$state"$'\t0\t'"$expires")
        fi
        ;;
      sec|ssb)
        return 2
        ;;
    esac
  done
  (( ${#records} > 0 )) || return 2
  reply=("${records[@]}")
}

# Status 0 when the listed keyring has signing keys and every one of them has
# expired by time; a revoked or still valid signing key returns 1.
# REPLY: the latest expiry time. Usage: _sys_apt_key_all_expired <record>...
_sys_apt_key_all_expired() {
  local record=""
  local -a fields=()
  local -i signing=0 latest=0
  REPLY=""
  for record in "$@"; do
    fields=("${(@ps:\t:)record}")
    [[ "${fields[4]}" == 1 ]] || continue
    (( ++signing ))
    [[ "${fields[3]}" == expired ]] || return 1
    if [[ "${fields[5]}" == <-> ]] && (( fields[5] > latest )); then
      latest="${fields[5]}"
    fi
  done
  (( signing > 0 )) || return 1
  REPLY="$latest"
}

# REPLY: "7F38 BBB5 … 6231 3325" for a fingerprint.
_sys_apt_key_short_fingerprint() {
  local fingerprint="${1-}"
  REPLY="${fingerprint[1,4]} ${fingerprint[5,8]} … ${fingerprint[-8,-5]} ${fingerprint[-4,-1]}"
}

# REPLY: a date such as 2026-09-05 for an epoch time.
_sys_apt_key_date() {
  REPLY="${1-}"
  [[ "$REPLY" == <-> ]] || return 1
  zmodload -F zsh/datetime b:strftime 2>/dev/null || return 1
  strftime -s REPLY '%Y-%m-%d' "$1"
}

# REPLY: the primary keys of a listing with their state, such as
# "2C61 0620 … 7571 6059 (expired 2026-09-05)", at most three.
_sys_apt_key_describe() {
  local record="" label="" date=""
  local -a fields=() parts=()
  local -i primaries=0
  for record in "$@"; do
    fields=("${(@ps:\t:)record}")
    [[ "${fields[1]}" == pub ]] || continue
    (( ++primaries <= 3 )) || continue
    _sys_apt_key_short_fingerprint "${fields[2]}"
    label="$REPLY"
    date=""
    _sys_apt_key_date "${fields[5]}" && date="$REPLY"
    case "${fields[3]}" in
      expired) label+=" (expired${date:+ $date})" ;;
      revoked) label+=" (revoked)" ;;
      invalid) label+=" (invalid)" ;;
      *)
        if [[ -n "$date" ]]; then
          label+=" (valid until $date)"
        else
          label+=" (valid, no expiry)"
        fi
        ;;
    esac
    parts+=("$label")
  done
  (( primaries > 3 )) && parts+=("and $(( primaries - 3 )) more")
  REPLY="${(j:, :)parts}"
  [[ -n "$REPLY" ]] || REPLY="none"
}

# --- Private workspace and tools ----------------------------------------------

# REPLY: a new private workspace below the validated temporary root, with an
# owner-only gnupg home for throwaway key parsing. Remove it with
# _sys_apt_key_session_close.
_sys_apt_key_session_open() {
  emulate -L zsh
  local temp_parent="" session=""
  REPLY=""
  _sys_temp_parent_safe "${TMPDIR:-/tmp}" || return 1
  temp_parent="$REPLY"
  REPLY=""
  session=$(umask 077; command mktemp -d \
    "${temp_parent%/}/zdx-sys-apt-key.XXXXXX" 2>/dev/null) || return 1
  if ! [[ "${session:h}" == "$temp_parent" \
    && "${session:t}" == zdx-sys-apt-key.* \
    && -d "$session" && ! -L "$session" && -O "$session" ]] \
    || ! (umask 077; command mkdir -- "$session/gnupg") 2>/dev/null; then
    _sys_apt_key_session_close "$session" 2>/dev/null
    return 1
  fi
  REPLY="$session"
}

# Removes only an exact private workspace created by _sys_apt_key_session_open.
_sys_apt_key_session_close() {
  emulate -L zsh
  local session="${1-}"
  [[ -n "$session" ]] || return 0
  [[ "$session" == /* && "${session:t}" == zdx-sys-apt-key.?????? \
    && "$session" == "${session:A}" \
    && -d "$session" && ! -L "$session" && -O "$session" ]] || return 1
  command rm -rf -- "$session"
}

# Resolves the trusted curl, gpg, and install programs into apt_key_context
# and opens the private workspace on first use. Status 1 names the missing
# piece in REPLY.
_sys_apt_key_prepare() {
  local program_name=""
  if [[ -z "${apt_key_context[install]-}" ]]; then
    for program_name in gpg curl install; do
      _sys_update_resolve_trusted_program "$program_name" || {
        REPLY="a trusted root-owned $program_name program is unavailable"
        return 1
      }
      apt_key_context[$program_name]="$REPLY"
    done
  fi
  if [[ -z "${apt_key_context[session]-}" ]]; then
    _sys_apt_key_session_open || {
      REPLY="no private temporary directory is available"
      return 1
    }
    apt_key_context[session]="$REPLY"
  fi
  REPLY=""
}

# Downloads <url> to <file>: HTTPS only, also across redirects, TLS 1.2 or
# newer, at most 30 seconds and 1 MiB, ignoring any curlrc. REPLY: the
# failure reason.
_sys_apt_key_download() {
  emulate -L zsh
  local curl_program="${1-}" key_url="${2-}" target="${3-}" error_line=""
  local error_file="${target}.curl-error"
  local -a transfer_status=()
  local -A file_state=()
  REPLY=""
  [[ "$key_url" == https://?* && "$curl_program" == /* ]] || {
    REPLY="its key URL is not HTTPS"
    return 1
  }
  _sys_run_with_timeout 35 "$curl_program" -q --silent --show-error \
    --fail --location --max-redirs 5 --proto '=https' --proto-redir '=https' \
    --tlsv1.2 --connect-timeout 10 --max-time 30 --max-filesize 1048576 \
    --output - -- "$key_url" </dev/null 2>"$error_file" \
    | command head -c 1048577 >| "$target"
  transfer_status=("${pipestatus[@]}")
  zmodload -F zsh/stat b:zstat 2>/dev/null \
    && zstat -LH file_state -- "$target" 2>/dev/null || {
    REPLY="the download could not be stored"
    return 1
  }
  if (( file_state[size] > 1048576 )); then
    REPLY="the file at $key_url is larger than 1 MiB"
    return 1
  fi
  if (( transfer_status[1] != 0 || transfer_status[2] != 0 )); then
    IFS= read -r error_line < "$error_file" 2>/dev/null
    error_line="${error_line#curl: }"
    (( ${#error_line} > 100 )) && error_line="${error_line[1,99]}…"
    if (( transfer_status[1] == 124 )); then
      REPLY="downloading $key_url timed out"
    else
      REPLY="downloading $key_url failed${error_line:+ (${(V)error_line})}"
    fi
    return 1
  fi
  if (( file_state[size] == 0 )); then
    REPLY="$key_url returned an empty file"
    return 1
  fi
}

_sys_apt_key_armored() {
  local first_line=""
  IFS= read -r first_line < "${1-}" 2>/dev/null
  first_line="${first_line%$'\r'}"
  [[ "$first_line" == "-----BEGIN PGP PUBLIC KEY BLOCK-----" ]]
}

# Writes the key in the format the keyring path expects: binary for .gpg
# (armored input is converted with gpg --dearmor) and armored text for .asc.
# REPLY: the failure reason. Usage: _sys_apt_key_stage <download> <staged>
#   <keyring>
_sys_apt_key_stage() {
  local download="${1-}" staged="${2-}" keyring="${3-}"
  REPLY=""
  if [[ "$keyring" == *.asc ]]; then
    _sys_apt_key_armored "$download" || {
      REPLY="the publisher's key is binary, but ${keyring:t} expects armored text"
      return 1
    }
    command cat -- "$download" >| "$staged" || {
      REPLY="the key could not be staged"
      return 1
    }
  elif _sys_apt_key_armored "$download"; then
    _sys_run_with_timeout 15 "${apt_key_context[gpg]}" --batch --no-options \
      --no-autostart --homedir "${apt_key_context[session]}/gnupg" \
      --dearmor --output "$staged" -- "$download" </dev/null >/dev/null 2>&1 \
      && [[ -s "$staged" ]] || {
      REPLY="gpg could not convert the armored key"
      return 1
    }
  else
    command cat -- "$download" >| "$staged" || {
      REPLY="the key could not be staged"
      return 1
    }
  fi
}

# REPLY: the fingerprint of a valid signing key in <records> that binds a
# key ID APT reported (the fingerprint ends with the ID), or, with no ID, of
# the first valid signing key that is not a valid signing key of the current
# keyring. One bound key is enough because APT needs one valid signature; the
# index refresh that follows verifies every repository of the keyring.
# Usage: _sys_apt_key_accept <ids> <old-records> <record>...
#   where <ids> and <old-records> are newline-separated.
_sys_apt_key_accept() {
  local key_ids="${1-}" old_records="${2-}" record="" key_id=""
  shift 2
  local -a fields=() old_valid=()
  REPLY=""
  for record in "${(@f)old_records}"; do
    fields=("${(@ps:\t:)record}")
    [[ "${fields[3]}" == valid && "${fields[4]}" == 1 ]] \
      && old_valid+=("${fields[2]}")
  done
  if [[ -n "$key_ids" ]]; then
    for key_id in "${(@f)key_ids}"; do
      [[ -n "$key_id" ]] || continue
      for record in "$@"; do
        fields=("${(@ps:\t:)record}")
        [[ "${fields[3]}" == valid && "${fields[4]}" == 1 \
          && "${fields[2]}" == *"${key_id:u}" ]] || continue
        REPLY="${fields[2]}"
        return 0
      done
    done
    return 1
  fi
  for record in "$@"; do
    fields=("${(@ps:\t:)record}")
    [[ "${fields[3]}" == valid && "${fields[4]}" == 1 ]] || continue
    (( ${old_valid[(Ie)${fields[2]}]} )) && continue
    REPLY="${fields[2]}"
    return 0
  done
  return 1
}

# --- Renewal transaction ------------------------------------------------------

# Renews one dedicated keyring: show the facts, download the publisher's key,
# require the key APT asked for (or, proactively, a new valid signing key),
# keep a private copy of the current keyring, and install the staged key with
# the announced `install -m 0644 -o 0 -g 0`. The key stays pending until
# _sys_apt_key_settle sees APT verify its repositories. Status 1 records the
# reason in apt_key_outcomes.
# Usage: _sys_apt_key_renew <name> <key-url> <keyring> <source-file>
#   <repositories> <key-ids>   (both newline-separated; no ID is proactive)
_sys_apt_key_renew() {
  emulate -L zsh
  local name="${1-}" key_url="${2-}" keyring="${3-}" source_file="${4-}"
  local repositories="${5-}" key_ids="${6-}"
  local mode="" work="" download="" staged="" backup="" fingerprint=""
  local key_id="" requested="" repository="" first_repository=""
  local -a old_records=() new_records=()
  local -i list_rc=0
  apt_key_outcomes[$keyring]="ZDX did not finish the renewal"

  _sys_info "Renewing the $name signing key"
  local -a repository_list=("${(@f)repositories}")
  first_repository="${repository_list[1]}"
  _sys_apt_display_source "$first_repository"
  repository="$REPLY"
  (( ${#repository_list} > 1 )) \
    && repository+=" and $(( ${#repository_list} - 1 )) more"
  _sys_label "Repository:" "$repository"
  _sys_label "Source file:" "$source_file"
  _sys_label "Keyring:" "$keyring"
  _sys_label "Key URL:" "$key_url"

  _sys_apt_key_keyring_renewable "$keyring" || {
    apt_key_outcomes[$keyring]="ZDX does not replace $keyring because $REPLY"
    _sys_error "${apt_key_outcomes[$keyring]}."
    return 1
  }
  mode="$REPLY"
  _sys_apt_key_prepare || {
    apt_key_outcomes[$keyring]="$REPLY"
    _sys_error "The $name key was not renewed: $REPLY."
    return 1
  }
  _sys_apt_key_list "${apt_key_context[gpg]}" \
    "${apt_key_context[session]}/gnupg" "$keyring" \
    && old_records=("${reply[@]}")
  _sys_apt_key_describe "${old_records[@]}"
  _sys_label "Current keys:" "$REPLY"
  for key_id in "${(@f)key_ids}"; do
    [[ -n "$key_id" ]] && requested+="${requested:+, }$key_id"
  done
  [[ -n "$requested" ]] && _sys_label "Requested key:" "$requested"

  (( ++apt_key_context[count] ))
  work="${apt_key_context[session]}/${apt_key_context[count]}"
  (umask 077; command mkdir -- "$work") 2>/dev/null || {
    apt_key_outcomes[$keyring]="no private staging directory could be created"
    _sys_error "The $name key was not renewed: ${apt_key_outcomes[$keyring]}."
    return 1
  }
  download="$work/download"
  staged="$work/${keyring:t}"
  backup="$work/previous"
  _sys_apt_key_download "${apt_key_context[curl]}" "$key_url" "$download" \
    || {
      apt_key_outcomes[$keyring]="$REPLY"
      _sys_error "The $name key was not renewed: $REPLY."
      return 1
    }
  _sys_apt_key_stage "$download" "$staged" "$keyring" || {
    apt_key_outcomes[$keyring]="$REPLY"
    _sys_error "The $name key was not renewed: $REPLY."
    return 1
  }
  _sys_apt_key_list "${apt_key_context[gpg]}" \
    "${apt_key_context[session]}/gnupg" "$staged" || list_rc=$?
  if (( list_rc != 0 )); then
    apt_key_outcomes[$keyring]="the file at $key_url is not a public OpenPGP keyring"
    _sys_error "The $name key was not renewed: ${apt_key_outcomes[$keyring]}."
    return 1
  fi
  new_records=("${reply[@]}")
  if ! _sys_apt_key_accept "$key_ids" "${(F)old_records}" \
    "${new_records[@]}"; then
    if [[ -n "$requested" ]]; then
      apt_key_outcomes[$keyring]="the key at $key_url does not contain a valid signing key $requested"
    else
      apt_key_outcomes[$keyring]="the key at $key_url has no valid signing key that the current keyring lacks"
    fi
    _sys_error "The $name key was not renewed: ${apt_key_outcomes[$keyring]}."
    return 1
  fi
  fingerprint="$REPLY"
  _sys_apt_key_short_fingerprint "$fingerprint"
  _sys_label "New key:" "$REPLY"

  command cat -- "$keyring" >| "$backup" 2>/dev/null \
    && command cmp -s -- "$keyring" "$backup" || {
    apt_key_outcomes[$keyring]="the current keyring could not be copied"
    _sys_error "The $name key was not renewed: ${apt_key_outcomes[$keyring]}."
    return 1
  }
  _sys_apt_key_keyring_renewable "$keyring" || {
    apt_key_outcomes[$keyring]="ZDX does not replace $keyring because $REPLY"
    _sys_error "${apt_key_outcomes[$keyring]}."
    return 1
  }
  _sys_apt_key_install "$staged" "$keyring" 0644 || {
    apt_key_outcomes[$keyring]="installing the new key failed"
    _sys_error "The $name key was not renewed: installing it failed."
    if ! command cmp -s -- "$backup" "$keyring"; then
      _sys_apt_key_restore "$name" "$keyring" "$backup" "$mode"
    fi
    return 1
  }
  apt_key_pending+=("$name"$'\t'"$keyring"$'\t'"$backup"$'\t'"$mode"$'\t'"$fingerprint"$'\t'"${repositories//$'\n'/$'\x1f'}")
  _sys_dim "APT must verify the repository with this key before ZDX keeps it."
}

# Installs <file> as <keyring> with the announced privileged argv, then
# confirms that the keyring holds exactly the installed bytes.
# Usage: _sys_apt_key_install <file> <keyring> <mode>
_sys_apt_key_install() {
  local source_file="${1-}" keyring="${2-}" mode="${3-}"
  local install_program="${apt_key_context[install]-}"
  [[ "$install_program" == /* && "$mode" == 0[0-7][0-7][0-7] ]] || return 2
  _sys_info "Privileged operation: ${privilege_label-}$(_sys_display_escape "$install_program") -m $mode -o 0 -g 0 $(_sys_display_escape "$source_file") $(_sys_display_escape "$keyring")"
  "${privilege_prefix[@]}" "$install_program" -m "$mode" -o 0 -g 0 \
    "$source_file" "$keyring" </dev/null >&2 || return 1
  command cmp -s -- "$source_file" "$keyring"
}

# Restores the private copy of a keyring after APT rejected the new key.
# Usage: _sys_apt_key_restore <name> <keyring> <backup> <mode>
_sys_apt_key_restore() {
  local name="${1-}" keyring="${2-}" backup="${3-}" mode="${4-}"
  if _sys_apt_key_install "$backup" "$keyring" "$mode"; then
    return 0
  fi
  apt_key_context[keep]=1
  _sys_error "Could not restore the previous $name keyring; its copy is kept at $(_sys_display_escape "$backup")."
  return 1
}

# Status 0 when <tail> shows APT fetching <repository> ("<uri> <suite>").
_sys_apt_key_refreshed() {
  emulate -L zsh
  setopt EXTENDED_GLOB
  local tail="${1-}" repository="${2-}" line="" uri="" suite=""
  uri="${repository%% *}"
  suite="${repository#* }"
  for line in "${(@f)tail}"; do
    line="${line%$'\r'}"
    [[ "$line" == (Hit|Get):<->" $uri"(|/)" $suite"(|" "*) ]] && return 0
  done
  return 1
}

# Keeps each pending key whose repositories APT refreshed, either in a
# successful update or as fetched sources without a failure, and restores the
# previous keyring of every other one. Usage: _sys_apt_key_settle <rc> <tail>
_sys_apt_key_settle() {
  local update_rc="${1:-1}" tail="${2-}" record="" repository=""
  local -a fields=() failed=() reply=()
  local -i verified=0
  if (( update_rc != 0 )); then
    _sys_apt_index_failures "$tail" raw
    for record in "${reply[@]}"; do
      fields=("${(@ps:\t:)record}")
      repository="${fields[2]}"
      _sys_apt_key_normalize_uri "${repository%% *}"
      [[ "$repository" == *" "* ]] && REPLY+=" ${repository#* }"
      failed+=("$REPLY")
    done
  fi
  for record in "${apt_key_pending[@]}"; do
    fields=("${(@ps:\t:)record}")
    verified=1
    if (( update_rc != 0 )); then
      for repository in "${(@ps:\x1f:)fields[6]}"; do
        if (( ${failed[(Ie)$repository]} )) \
          || ! _sys_apt_key_refreshed "$tail" "$repository"; then
          verified=0
          break
        fi
      done
    fi
    _sys_apt_key_short_fingerprint "${fields[5]}"
    if (( verified )); then
      _sys_success "Renewed the ${fields[1]} signing key ($REPLY)"
      apt_key_renewed+=("${fields[1]}")
      apt_key_outcomes[${fields[2]}]=renewed
    else
      apt_key_outcomes[${fields[2]}]="APT still could not verify it with the key from its publisher, so ZDX restored the previous keyring"
      if _sys_apt_key_restore "${fields[1]}" "${fields[2]}" \
        "${fields[3]}" "${fields[4]}"; then
        _sys_error "APT still cannot verify ${fields[1]} with the downloaded key; the previous keyring was restored."
      fi
    fi
  done
  apt_key_pending=()
}

# Restores every pending keyring; used when the index phase ends before APT
# could verify them, such as after an interruption.
_sys_apt_key_abandon() {
  local record=""
  local -a fields=()
  for record in "${apt_key_pending[@]}"; do
    fields=("${(@ps:\t:)record}")
    _sys_warn "APT did not verify the new ${fields[1]} key; restoring the previous keyring."
    _sys_apt_key_restore "${fields[1]}" "${fields[2]}" "${fields[3]}" \
      "${fields[4]}"
  done
  apt_key_pending=()
}

# --- Discovery and assessment -------------------------------------------------

# reply: "<name><TAB><key-url><TAB><keyring><TAB><source-file><TAB>
# <repositories><TAB><latest-expiry>" for each dedicated keyring of a known
# repository whose signing keys have all expired, repositories joined by
# newlines. Reads only local sources and keyrings.
# Usage: _sys_apt_key_expired_keyrings <gpg> <gnupg-home>
_sys_apt_key_expired_keyrings() {
  emulate -L zsh
  local gpg_program="${1-}" gnupg_home="${2-}" record="" keyring=""
  local name="" key_url="" latest=""
  local -a entries=() fields=() candidates=() seen=() repositories=()
  _sys_apt_key_source_entries || return 1
  entries=("${reply[@]}")
  for record in "${entries[@]}"; do
    fields=("${(@ps:\t:)record}")
    keyring="${fields[3]}"
    [[ "$keyring" == /* ]] || continue
    (( ${seen[(Ie)$keyring]} )) && continue
    seen+=("$keyring")
    _sys_apt_key_registry_match "${fields[1]}" || continue
    name="${reply[1]}"
    key_url="${reply[2]}"
    _sys_apt_key_keyring_repositories "$keyring" "$key_url" \
      "${entries[@]}" || continue
    repositories=("${reply[@]}")
    _sys_apt_key_keyring_renewable "$keyring" || continue
    _sys_apt_key_list "$gpg_program" "$gnupg_home" "$keyring" || continue
    _sys_apt_key_all_expired "${reply[@]}" || continue
    latest="$REPLY"
    candidates+=("$name"$'\t'"$key_url"$'\t'"$keyring"$'\t'"${fields[4]}"$'\t'"${(F)repositories}"$'\t'"$latest")
  done
  reply=("${candidates[@]}")
  return 0
}

# Renews, before the index update, every dedicated keyring of a known
# repository whose signing keys have all expired.
_sys_apt_key_renew_expired() {
  local record=""
  local -a candidates=() fields=()
  _sys_apt_key_prepare || {
    _sys_verbose_dim "Expired signing keys are not checked: $REPLY."
    return 0
  }
  _sys_apt_key_expired_keyrings "${apt_key_context[gpg]}" \
    "${apt_key_context[session]}/gnupg" || return 0
  candidates=("${reply[@]}")
  for record in "${candidates[@]}"; do
    fields=("${(@ps:\t:)record}")
    _sys_apt_key_renew "${fields[1]}" "${fields[2]}" "${fields[3]}" \
      "${fields[4]}" "${fields[5]}" ""
  done
  return 0
}

# reply=(<status> <name> <key-url> <keyring> <source-file> <repositories>
# <cause>) for one repository key problem, where status is "renewable" or
# "blocked" and cause is the sentence explaining a blocked one.
# Usage: _sys_apt_key_assess <repository> <kind> <key-id> <entry>...
_sys_apt_key_assess() {
  emulate -L zsh
  setopt EXTENDED_GLOB
  local repository="${1-}" kind="${2-}" key_id="${3-}" uri="" summary=""
  local signed_by="" source_file="" name="" key_url=""
  shift 3
  local -a entries=("$@") repositories=()
  _sys_apt_key_registry_summary
  summary="$REPLY"
  uri="${repository%% *}"
  if _sys_apt_key_source_lookup "$repository" "${entries[@]}"; then
    signed_by="${REPLY%%$'\t'*}"
    source_file="${REPLY#*$'\t'}"
  fi
  if ! _sys_apt_key_registry_match "$uri"; then
    reply=(blocked "" "" "$signed_by" "$source_file" ""
      "ZDX renews keys automatically only for $summary.")
    return 0
  fi
  name="${reply[1]}"
  key_url="${reply[2]}"
  reply=(blocked "$name" "$key_url" "$signed_by" "$source_file" "")
  case "$kind" in
    NO_PUBKEY|EXPKEYSIG|"Missing key") ;;
    REVKEYSIG)
      reply+=("The signing key was revoked, and ZDX never replaces a revoked key automatically.")
      return 0
      ;;
    *)
      reply+=("ZDX renews only missing or expired keys, and this is a signature problem.")
      return 0
      ;;
  esac
  if [[ "$key_id" != [0-9A-Fa-f](#c16,64) ]]; then
    reply+=("APT reported only a short key ID, which ZDX cannot bind to a downloaded key.")
    return 0
  fi
  if [[ -z "$source_file" ]]; then
    reply+=("ZDX could not find its entry in the APT sources.")
    return 0
  fi
  case "$signed_by" in
    -)
      reply+=("It has no signed-by keyring, and ZDX renews only dedicated keyrings of $summary.")
      return 0
      ;;
    inline)
      reply+=("Its key is embedded in the source file, and ZDX renews only dedicated keyrings of $summary.")
      return 0
      ;;
    /*) ;;
    *)
      reply+=("Its signed-by value is not one keyring file, and ZDX renews only dedicated keyrings of $summary.")
      return 0
      ;;
  esac
  local -a assessed=("${reply[@]}")
  if ! _sys_apt_key_keyring_repositories "$signed_by" "$key_url" \
    "${entries[@]}"; then
    reply=("${assessed[@]}"
      "Its keyring is shared with another publisher's repository, so ZDX does not replace it.")
    return 0
  fi
  repositories=("${reply[@]}")
  if ! _sys_apt_key_keyring_renewable "$signed_by"; then
    reply=("${assessed[@]}"
      "ZDX does not replace its keyring because $REPLY.")
    return 0
  fi
  reply=(renewable "$name" "$key_url" "$signed_by" "$source_file"
    "${(F)repositories}" "")
}

# reply: "<repository><TAB><kind><TAB><key-id>" for each key problem of a
# failed refresh, in APT's order.
_sys_apt_key_reported() {
  emulate -L zsh
  local tail="${1-}" record="" problem="" MATCH MBEGIN MEND
  local -a match=() mbegin=() mend=() fields=() records=()
  _sys_apt_index_failures "$tail" raw
  for record in "${reply[@]}"; do
    fields=("${(@ps:\t:)record}")
    [[ "${fields[1]}" == key ]] || continue
    problem="${fields[3]}"
    if [[ "$problem" =~ '\((NO_PUBKEY|EXPKEYSIG|EXPSIG|REVKEYSIG|BADSIG|Missing key) ([0-9A-Fa-f]+)\)' ]]; then
      records+=("${fields[2]}"$'\t'"${match[1]}"$'\t'"${match[2]}")
    else
      records+=("${fields[2]}"$'\t'"unsigned"$'\t')
    fi
  done
  reply=("${records[@]}")
}

# Renews, after a failed index update, each dedicated keyring of a known
# repository whose key APT reported missing or expired, once per keyring.
_sys_apt_key_renew_reported() {
  local tail="${1-}" record="" keyring=""
  local -a problems=() entries=() fields=() order=()
  local -A key_ids=() details=()
  _sys_apt_key_reported "$tail"
  problems=("${reply[@]}")
  (( ${#problems} > 0 )) || return 0
  _sys_apt_key_source_entries
  entries=("${reply[@]}")
  for record in "${problems[@]}"; do
    fields=("${(@ps:\t:)record}")
    _sys_apt_key_assess "${fields[1]}" "${fields[2]}" "${fields[3]}" \
      "${entries[@]}"
    [[ "${reply[1]}" == renewable ]] || continue
    keyring="${reply[4]}"
    (( ${+apt_key_outcomes[$keyring]} )) && continue
    if (( ! ${+details[$keyring]} )); then
      order+=("$keyring")
      details[$keyring]="${reply[2]}"$'\t'"${reply[3]}"$'\t'"${reply[5]}"$'\t'"${reply[6]//$'\n'/$'\x1f'}"
      key_ids[$keyring]="${fields[3]:u}"
    elif [[ $'\n'"${key_ids[$keyring]}"$'\n' != *$'\n'"${fields[3]:u}"$'\n'* ]]; then
      key_ids[$keyring]+=$'\n'"${fields[3]:u}"
    fi
  done
  (( ${#order} > 0 )) || return 0
  _sys_count_noun "${#order}" "known repository" "known repositories"
  _sys_info "APT reported a missing or expired signing key for $REPLY."
  for keyring in "${order[@]}"; do
    fields=("${(@ps:\t:)details[$keyring]}")
    _sys_apt_key_renew "${fields[1]}" "${fields[2]}" "$keyring" \
      "${fields[3]}" "${fields[4]//$'\x1f'/$'\n'}" "${key_ids[$keyring]}"
  done
  return 0
}

# REPLY: "<repository><TAB><key-id><TAB><source-file><TAB><keyring><TAB>
# <cause>" for the first key problem ZDX did not fix, or empty.
# Usage: _sys_apt_key_guidance <tail> <renewal-enabled>
_sys_apt_key_guidance() {
  local tail="${1-}" renewal="${2:-1}" record="" cause="" keyring=""
  local summary=""
  local -a problems=() entries=() fields=()
  REPLY=""
  _sys_apt_key_reported "$tail"
  problems=("${reply[@]}")
  (( ${#problems} > 0 )) || return 0
  _sys_apt_key_source_entries
  entries=("${reply[@]}")
  record="${problems[1]}"
  fields=("${(@ps:\t:)record}")
  _sys_apt_key_assess "${fields[1]}" "${fields[2]}" "${fields[3]}" \
    "${entries[@]}"
  keyring="${reply[4]}"
  cause="${reply[7]}"
  if [[ "${reply[1]}" == renewable ]]; then
    _sys_apt_key_registry_summary
    summary="$REPLY"
    if (( ! renewal )); then
      cause="Automatic key renewal is off (SYS_APT_KEY_RENEWAL=0); it covers $summary."
    elif [[ -n "${apt_key_outcomes[$keyring]-}" \
      && "${apt_key_outcomes[$keyring]}" != renewed ]]; then
      cause="ZDX could not renew it: ${apt_key_outcomes[$keyring]}."
    else
      cause="ZDX could not renew it in this run."
    fi
  fi
  REPLY="${fields[1]}"$'\t'"${fields[3]}"$'\t'"${reply[5]}"$'\t'"$keyring"$'\t'"$cause"
}

# Prints the plan's key-renewal disclosure for update-apt and lists each
# expired keyring that the run would renew. Reads only local sources and
# keyrings; nothing is downloaded. REPLY: the number of keyrings to renew.
# Status 2: SYS_APT_KEY_RENEWAL is invalid.
_sys_apt_key_plan() {
  local record="" date="" session="" gpg_program=""
  local -a candidates=() fields=()
  local -i enabled_rc=0 explain=1
  REPLY=0
  _sys_step_active && [[ "${ZDX_VERBOSE:-0}" != 1 ]] && explain=0
  _sys_apt_key_renewal_enabled || enabled_rc=$?
  if (( enabled_rc == 1 )); then
    (( explain )) && _sys_label "Key renewal:" "off (SYS_APT_KEY_RENEWAL=0)"
    return 0
  fi
  (( enabled_rc == 0 )) || return 2
  (( explain )) && _sys_label "Key renewal:" \
    "known repositories; their publisher keys are installed with sudo"
  _sys_update_resolve_trusted_program gpg || {
    _sys_verbose_dim "gpg is unavailable, so expired signing keys are not checked before the refresh."
    return 0
  }
  gpg_program="$REPLY"
  _sys_apt_key_session_open || return 0
  session="$REPLY"
  {
    _sys_apt_key_expired_keyrings "$gpg_program" "$session/gnupg" \
      && candidates=("${reply[@]}")
  } always {
    _sys_apt_key_session_close "$session" || true
  }
  for record in "${candidates[@]}"; do
    fields=("${(@ps:\t:)record}")
    date=""
    _sys_apt_key_date "${fields[6]}" && date=" (expired $REPLY)"
    _sys_label "Renew key:" "${fields[1]}${date}: ${fields[3]}"
    _sys_label "Key URL:" "${fields[2]}"
  done
  REPLY="${#candidates}"
  return 0
}

typeset -g _SYS_UPDATE_APT_KEYS_SOURCED=1
