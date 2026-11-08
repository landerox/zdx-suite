#!/usr/bin/env zsh
# =============================================================================
# File Trash: rename-only trash with no-clobber restore and quarantined purge
# =============================================================================
#
# Loaded by file-menu.zsh after file-common.zsh, file-archive.zsh, and
# file-operations.zsh.
# Safe to re-source; defines functions only.
#
# Trashed items live in ${XDG_DATA_HOME:-~/.local/share}/zdx/trash as
# files/<id>, each described by an info/<id>.trashinfo record in the
# freedesktop.org Trash format. Items move by the suite's no-clobber rename
# only and never by copy and delete, so a source on another filesystem is
# refused. Purge deletes through the quarantined File deletion engine. The
# suite has no lock: IDs are reserved by a no-clobber publication of their
# record, and every move revalidates the reviewed identities first, so a
# concurrent invocation can make an operation fail but never clobber an item.
#

if [[ -n "${_FILE_TRASH_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# A record holds one encoded path of at most 4,096 bytes plus two short lines.
typeset -gi _FILE_TRASH_MAX_INFO_BYTES=16384
typeset -gi _FILE_TRASH_MAX_PATH_BYTES=4096
typeset -gi _FILE_TRASH_MAX_DAYS=36500

_file_trash_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- "  file-trash [--dry-run] [--yes]"
  print -u2 -r -- "  file-trash put [--dry-run] [--yes] [--] PATH..."
  print -u2 -r -- "  file-trash list [--json]"
  print -u2 -r -- "  file-trash restore [--dry-run] [--yes] [--] [ID...]"
  print -u2 -r -- \
    "  file-trash purge [--dry-run] [--yes] [ID... | --older-than DAYS | --all]"
  print -u2 -r -- ""
  print -u2 -r -- \
    "put moves files, directories, and symbolic links below the current"
  print -u2 -r -- \
    "directory into \${XDG_DATA_HOME:-~/.local/share}/zdx/trash by rename;"
  print -u2 -r -- \
    "a path on another filesystem is refused, never copied. restore moves"
  print -u2 -r -- \
    "items back without replacing anything, and purge deletes them for good."
  print -u2 -r -- \
    "Without an action, or without IDs, pick trashed items interactively."
  print -u2 -r -- ""
  print -u2 -r -- "  --dry-run          Show the exact plan without changing anything."
  print -u2 -r -- "  --yes              Confirm the reviewed plan non-interactively."
  print -u2 -r -- "  --json             With list: print one JSON document on stdout."
  print -u2 -r -- "  --older-than DAYS  With purge: items trashed more than DAYS days ago."
  print -u2 -r -- "  --all              With purge: every trash entry."
}

# --- Location ----------------------------------------------------------------

# True for an ID this suite generates: local creation time plus six
# hexadecimal digits, such as 20261005-143012-a1b2c3.
_file_trash_is_id() {
  [[ "${1-}" =~ '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$' ]]
}

# REPLY is the literal trash path, ${XDG_DATA_HOME:-$HOME/.local/share}/zdx/
# trash. It must be absolute and normalized; it need not exist yet.
_file_trash_configured_path() {
  emulate -L zsh
  local data_home="${XDG_DATA_HOME:-}"
  REPLY=""
  if [[ -z "$data_home" ]]; then
    [[ "${HOME:-}" == /* ]] || {
      _file_error "HOME must be an absolute path to locate the trash."
      return 1
    }
    data_home="${HOME%/}/.local/share"
  fi
  while [[ "$data_home" != / && "$data_home" == */ ]]; do
    data_home="${data_home%/}"
  done
  [[ "$data_home" == /* ]] || {
    _file_error "XDG_DATA_HOME must be an absolute path to locate the trash."
    return 1
  }
  [[ "$data_home" != *[[:cntrl:]]* && "$data_home" != *'|'* \
    && "$data_home" == "${data_home:a}" ]] || {
    _file_error "The trash location must be a normalized path without control characters."
    return 1
  }
  REPLY="${data_home%/}/zdx/trash"
}

# Status 0 for a real, canonical directory that the current user owns and
# that grants no group or other permission.
_file_trash_private_dir() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local directory="$1"
  local -A state=()
  [[ -d "$directory" && ! -L "$directory" \
    && "$directory" == "${directory:A}" ]] \
    && zstat -LH state -- "$directory" 2>/dev/null \
    && (( state[uid] == EUID && (state[mode] & 8#77) == 0 )) || {
    _file_error "Trash directories must be real, owned by you, and private (mode 700): $directory"
    _file_wsl_drive_hint "$directory"
    return 1
  }
}

# Locates the trash without changing anything. REPLY is its canonical path,
# whether or not it exists yet, and reply is "present" or "absent". The
# nearest existing directory resolves through trusted aliases only
# (_file_resolve_trusted_dir) and needs trusted ancestors. A missing trash
# must be creatable below a directory that the current user owns and others
# cannot write; an existing trash and its files and info directories must
# be private.
_file_trash_locate() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  reply=()
  _file_trash_configured_path || return 1
  local existing="$REPLY"
  local -a missing=()
  while [[ ! -e "$existing" && ! -L "$existing" ]]; do
    missing=("${existing:t}" "${missing[@]}")
    existing="${existing:h}"
  done
  _file_resolve_trusted_dir "$existing" || {
    _file_error "The trash location is not a directory reached through trusted links: $existing"
    return 1
  }
  local canonical="$REPLY"
  REPLY=""
  if (( ${#missing[@]} > 0 )); then
    local -A state=()
    zstat -LH state -- "$canonical" 2>/dev/null || return 1
    (( state[uid] == EUID && (state[mode] & 8#22) == 0 )) || {
      _file_error "The trash cannot be created below a directory that is not yours or that others can write: $canonical"
      _file_wsl_drive_hint "$canonical"
      return 1
    }
    _file_validate_ancestor_chain "$canonical" || return 1
    REPLY="${canonical%/}/${(j:/:)missing}"
    reply=(absent)
    return 0
  fi
  _file_trash_private_dir "$canonical" || return 1
  _file_validate_ancestor_chain "$canonical" || return 1
  local subdirectory=""
  for subdirectory in files info; do
    [[ -e "$canonical/$subdirectory" || -L "$canonical/$subdirectory" ]] \
      || continue
    _file_trash_private_dir "$canonical/$subdirectory" || return 1
  done
  REPLY="$canonical"
  reply=(present)
}

# Creates the missing trash directories, each mode 700, and validates the
# result. REPLY is the canonical trash; reply is the identity of its info
# and files directories, which every publication and move revalidate.
_file_trash_prepare() {
  emulate -L zsh
  _file_trash_locate || return 1
  local trash_dir="$REPLY"
  reply=()
  local -a pending=()
  local probe="$trash_dir" directory=""
  while [[ ! -e "$probe" && ! -L "$probe" ]]; do
    pending=("$probe" "${pending[@]}")
    probe="${probe:h}"
  done
  pending+=("$trash_dir/files" "$trash_dir/info")
  local -A state=()
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  for directory in "${pending[@]}"; do
    if [[ ! -e "$directory" && ! -L "$directory" ]]; then
      # mkdir -m sets the exact mode regardless of the umask. A directory
      # created concurrently by another invocation is validated instead.
      command mkdir -m 700 -- "$directory" 2>/dev/null \
        || [[ -d "$directory" && ! -L "$directory" ]] || {
        _file_error "Could not create the trash directory: $directory"
        return 1
      }
    fi
    state=()
    [[ -d "$directory" && ! -L "$directory" \
      && "$directory" == "${directory:A}" ]] \
      && zstat -LH state -- "$directory" 2>/dev/null \
      && (( state[uid] == EUID && (state[mode] & 8#22) == 0 )) || {
      _file_error "A trash directory is not a real directory that you own: $directory"
      return 1
    }
  done
  for directory in "$trash_dir" "$trash_dir/files" "$trash_dir/info"; do
    _file_trash_private_dir "$directory" || return 1
  done
  _file_validate_ancestor_chain "$trash_dir" || return 1
  _file_directory_identity "$trash_dir/info" || return 1
  local info_identity="$REPLY"
  _file_directory_identity "$trash_dir/files" || return 1
  reply=("$info_identity" "$REPLY")
  REPLY="$trash_dir"
}

# --- Same-filesystem boundary ---------------------------------------------------

# REPLY is the nearest mount point at or above a canonical path in the pass
# snapshot (table mode only).
_file_trash_mount_root() {
  local candidate="$1" mount_point=""
  REPLY=/
  for mount_point in "${(@k)_file_mount_targets}"; do
    [[ "$candidate" == "$mount_point" || "$candidate" == "${mount_point%/}"/* ]] \
      || continue
    (( ${#mount_point} > ${#REPLY} )) && REPLY="$mount_point"
  done
}

# Status 0 when a canonical node and a destination directory share one
# filesystem, so a rename cannot fall back to copying. Devices must match
# (lstat, as the mount checks compare them); on Linux and WSL the nearest
# mount point of each path in the pass snapshot must match too, because a
# bind mount keeps the device number but still refuses a rename. A missing
# destination is represented by its nearest existing ancestor. Prints the
# refusal.
_file_trash_same_filesystem() {
  local node="$1" destination="$2" probe="$2" node_device="" REPLY=""
  _file_path_device "$node" || return 1
  node_device="$REPLY"
  while [[ ! -e "$probe" && ! -L "$probe" && "$probe" != / ]]; do
    probe="${probe:h}"
  done
  _file_path_device "$probe" || return 1
  local same=yes
  [[ -n "$node_device" && "$REPLY" == "$node_device" ]] || same=no
  if [[ "$same" == yes ]]; then
    if (( ! ${+_file_mount_mode} )); then
      local _file_mount_mode=""
      local -A _file_mount_targets=()
    fi
    if [[ -z "$_file_mount_mode" ]]; then
      _file_mount_snapshot || return 1
    fi
    if [[ "$_file_mount_mode" == table ]]; then
      _file_trash_mount_root "$node"
      local node_root="$REPLY"
      _file_trash_mount_root "$destination"
      [[ "$REPLY" == "$node_root" ]] || same=no
    fi
  fi
  [[ "$same" == yes ]] && return 0
  _file_path_display "$node"
  _file_error "Refusing to move across filesystems: $REPLY"
  _file_dim "The trash renames items and never copies them. Move it with another tool, or set XDG_DATA_HOME to a directory on the same filesystem."
  return 1
}

# --- Records -------------------------------------------------------------------

# REPLY is a path percent-encoded for a Path= value: every byte outside
# A-Z, a-z, 0-9, and /._~- becomes %XX.
_file_trash_encode_path() {
  emulate -L zsh
  setopt local_options no_multibyte
  local raw="${1-}" encoded="" byte="" escape=""
  local -i index=0
  for (( index = 1; index <= ${#raw}; index++ )); do
    byte="${raw[index]}"
    if [[ "$byte" == [A-Za-z0-9/._~-] ]]; then
      encoded+="$byte"
    else
      printf -v escape '%%%02X' "'$byte"
      encoded+="$escape"
    fi
  done
  REPLY="$encoded"
}

# REPLY is a decoded Path= value. Status 1 for anything but the unreserved
# characters above and %XX escapes; the caller validates the decoded bytes.
_file_trash_decode_path() {
  emulate -L zsh
  setopt local_options no_multibyte
  local rest="${1-}" decoded="" plain=""
  REPLY=""
  [[ -n "$rest" && "$rest" != *[^A-Za-z0-9/._~%-]* ]] || return 1
  while [[ -n "$rest" ]]; do
    plain="${rest%%\%*}"
    decoded+="$plain"
    rest="${rest#"$plain"}"
    [[ -n "$rest" ]] || break
    [[ "$rest" == %[0-9A-Fa-f][0-9A-Fa-f]* ]] || return 1
    decoded+="${(#)$(( 16#${rest[2,3]} ))}"
    rest="${rest[4,-1]}"
  done
  REPLY="$decoded"
}

# Status 0 when a decoded original path is one this suite could have
# trashed: absolute, normalized (no ., .., or empty segments), within the
# length bound, free of control characters and the plan delimiter, and
# outside the trash and the protected roots.
_file_trash_valid_original() {
  emulate -L zsh
  local original="${1-}" trash_dir="${2-}"
  [[ "$original" == /?* && "$original" != *[[:cntrl:]]* \
    && "$original" != *$'\0'* && "$original" != *'|'* \
    && "$original" == "${original:a}" \
    && "/$original/" != */../* && "/$original/" != */./* ]] || return 1
  () {
    setopt local_options no_multibyte
    (( ${#original} <= _FILE_TRASH_MAX_PATH_BYTES ))
  } || return 1
  [[ "$original" != "$trash_dir" && "$original" != "$trash_dir"/* \
    && "$trash_dir" != "$original"/* \
    && "$original" != "${HOME:A}" \
    && "$original" != "$_FILE_SUITE_ROOT" ]]
}

# REPLY is the epoch of a DeletionDate value, which is local time; status 1
# unless it is a real YYYY-MM-DDThh:mm:ss time.
_file_trash_date_epoch() {
  emulate -L zsh
  zmodload -F zsh/datetime b:strftime 2>/dev/null || return 1
  local value="${1-}" epoch="" round_trip=""
  REPLY=""
  [[ "$value" =~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$' ]] \
    || return 1
  strftime -r -s epoch '%Y-%m-%dT%H:%M:%S' "$value" 2>/dev/null || return 1
  [[ "$epoch" == <-> ]] || return 1
  # A normalized impossible date, such as February 30, does not round-trip.
  strftime -s round_trip '%Y-%m-%dT%H:%M:%S' "$epoch" 2>/dev/null || return 1
  [[ "$round_trip" == "$value" ]] || return 1
  REPLY="$epoch"
}

# Reads one record strictly as data: exactly "[Trash Info]", one Path= line,
# and one DeletionDate= line. REPLY is "<epoch><TAB><date><TAB><path>".
# Status 1 rejects the record: a link, a special or foreign-owned file, a
# hard-linked or non-private file, oversized content, a NUL or control
# character, a missing, repeated, or unknown key, a malformed escape, or a
# path that _file_trash_valid_original refuses.
# Usage: _file_trash_read_info <record> <trash-dir>
_file_trash_read_info() {
  emulate -L zsh
  { zmodload -F zsh/stat b:zstat && zmodload zsh/system; } 2>/dev/null \
    || return 1
  local info_file="$1" trash_dir="$2"
  REPLY=""
  local -A link_state=() open_state=()
  [[ -f "$info_file" && ! -L "$info_file" ]] \
    && zstat -LH link_state -- "$info_file" 2>/dev/null \
    && (( link_state[uid] == EUID && link_state[nlink] == 1 \
      && (link_state[mode] & 8#77) == 0 \
      && link_state[size] <= _FILE_TRASH_MAX_INFO_BYTES )) || return 1

  local content="" chunk=""
  local -i info_fd=-1 read_rc=0
  sysopen -r -o nofollow,nonblock,cloexec -u info_fd \
    -- "$info_file" 2>/dev/null || return 1
  {
    zstat -H open_state -f "$info_fd" 2>/dev/null \
      && [[ "${open_state[device]}:${open_state[inode]}" \
        == "${link_state[device]}:${link_state[inode]}" ]] || return 1
    while true; do
      chunk=""
      sysread -s 4096 -i "$info_fd" chunk
      read_rc=$?
      (( read_rc == 0 )) || break
      content+="$chunk"
      (( ${#content} <= _FILE_TRASH_MAX_INFO_BYTES )) || return 1
    done
  } always {
    exec {info_fd}<&-
  }
  # sysread returns 5 at the end of the file.
  (( read_rc == 5 )) || return 1

  [[ "$content" != *$'\0'* ]] || return 1
  content="${content%$'\n'}"
  local -a lines=("${(@ps:\n:)content}")
  (( ${#lines[@]} == 3 )) && [[ "${lines[1]}" == "[Trash Info]" ]] \
    || return 1
  local line="" encoded_path="" deletion_date=""
  local -i path_lines=0 date_lines=0
  for line in "${(@)lines[2,-1]}"; do
    [[ "$line" != *[[:cntrl:]]* ]] || return 1
    case "$line" in
      Path=*)
        (( ++path_lines ))
        encoded_path="${line#Path=}"
        ;;
      DeletionDate=*)
        (( ++date_lines ))
        deletion_date="${line#DeletionDate=}"
        ;;
      *) return 1 ;;
    esac
  done
  (( path_lines == 1 && date_lines == 1 )) || return 1
  _file_trash_decode_path "$encoded_path" || return 1
  local original="$REPLY"
  REPLY=""
  _file_trash_valid_original "$original" "$trash_dir" || return 1
  _file_trash_date_epoch "$deletion_date" || return 1
  REPLY="${REPLY}"$'\t'"${deletion_date}"$'\t'"${original}"
}

# REPLY is the apparent size in bytes of the regular files in a directory
# tree, without following links, or "-" when the tree exceeds the inventory
# bound or cannot be read.
_file_trash_tree_bytes() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local -a pending=("$1") next=() entries=()
  local directory="" entry=""
  local -A state=()
  local -i total=0 count=0
  REPLY="-"
  while (( ${#pending[@]} > 0 )); do
    next=()
    for directory in "${pending[@]}"; do
      [[ -r "$directory" && -x "$directory" ]] || return 0
      entries=("$directory"/*(DN))
      for entry in "${entries[@]}"; do
        (( ++count <= _FILE_MAX_CANDIDATES )) || return 0
        state=()
        zstat -LH state -- "$entry" 2>/dev/null || return 0
        case $(( state[mode] & 8#170000 )) in
          $(( 8#100000 ))) (( total += state[size] )) ;;
          $(( 8#040000 ))) next+=("$entry") ;;
        esac
      done
    done
    pending=("${next[@]}")
  done
  REPLY="$total"
}

# Loads every trash entry. reply holds one record per ID:
#   id, state, epoch, date, type, size, item fingerprint, record
#   fingerprint, original path
# joined by TABs, with "-" for an unknown field. The state is valid,
# missing-item (a record without an item), missing-info (an item without a
# record), invalid-info (a record that _file_trash_read_info rejects), or
# unsafe-item (not a file, directory, or link you own). Valid entries come
# first, newest first; the rest follow by ID. Names that are not IDs, such
# as staging and quarantine files, are ignored.
# Usage: _file_trash_load <trash-dir>
_file_trash_load() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local trash_dir="$1"
  local files_dir="$trash_dir/files" info_dir="$trash_dir/info"
  reply=()
  local -a item_names=() info_names=()
  [[ -d "$files_dir" ]] && item_names=("$files_dir"/*(DN:t))
  [[ -d "$info_dir" ]] && info_names=("$info_dir"/*(DN:t))
  (( ${#item_names[@]} <= _FILE_MAX_CANDIDATES \
    && ${#info_names[@]} <= _FILE_MAX_CANDIDATES )) || {
    _file_error "The trash holds more than $_FILE_MAX_CANDIDATES entries; purge older items first."
    return 1
  }
  local -A has_item=() has_info=()
  local name=""
  for name in "${item_names[@]}"; do
    _file_trash_is_id "$name" && has_item[$name]=1
  done
  for name in "${info_names[@]}"; do
    [[ "$name" == *.trashinfo ]] || continue
    _file_trash_is_id "${name%.trashinfo}" && has_info[${name%.trashinfo}]=1
  done

  local -aU ids=("${(@k)has_item}" "${(@k)has_info}")
  local -a valid_keys=() other_records=()
  local id="" item="" info="" entry_state="" item_type="" size="" record=""
  local item_fp="" info_fp="" epoch="" deletion_date="" original=""
  local -A state=()
  for id in "${ids[@]}"; do
    item="$files_dir/$id"
    info="$info_dir/$id.trashinfo"
    entry_state=valid item_type=missing size=- item_fp=- info_fp=-
    epoch=- deletion_date=- original=-
    if (( ${+has_item[$id]} )); then
      state=()
      if zstat -LH state -- "$item" 2>/dev/null \
        && _file_path_fingerprint "$item"; then
        item_fp="$REPLY"
        case $(( state[mode] & 8#170000 )) in
          $(( 8#100000 ))) item_type=file size="${state[size]}" ;;
          $(( 8#040000 )))
            item_type=directory
            _file_trash_tree_bytes "$item" && size="$REPLY"
            ;;
          $(( 8#120000 ))) item_type=symlink size="${state[size]}" ;;
          *) item_type=other ;;
        esac
        [[ "$item_type" != other ]] && (( state[uid] == EUID )) \
          || entry_state=unsafe-item
      else
        entry_state=missing-item
      fi
    else
      entry_state=missing-item
    fi
    if (( ${+has_info[$id]} )); then
      _file_path_fingerprint "$info" && info_fp="$REPLY"
      if _file_trash_read_info "$info" "$trash_dir"; then
        epoch="${REPLY%%$'\t'*}"
        deletion_date="${${REPLY#*$'\t'}%%$'\t'*}"
        original="${REPLY#*$'\t'*$'\t'}"
      else
        entry_state=invalid-info
      fi
    elif [[ "$entry_state" == valid ]]; then
      entry_state=missing-info
    fi
    record="${id}"$'\t'"${entry_state}"$'\t'"${epoch}"$'\t'"${deletion_date}"
    record+=$'\t'"${item_type}"$'\t'"${size}"$'\t'"${item_fp}"$'\t'"${info_fp}"
    record+=$'\t'"${original}"
    if [[ "$entry_state" == valid ]]; then
      # A zero-padded epoch key sorts the newest entry first.
      valid_keys+=("${(l:16::0:)epoch}"$'\t'"${record}")
    else
      other_records+=("$record")
    fi
  done
  local key=""
  for key in "${(@O)valid_keys}"; do
    reply+=("${key#*$'\t'}")
  done
  reply+=("${(@o)other_records}")
  return 0
}

# --- Presentation ----------------------------------------------------------------

# REPLY is a byte count with a binary unit, such as 512 B or 1.5 MiB, or
# "unknown". Integer arithmetic keeps LC_NUMERIC out of the decimal point.
_file_trash_size_display() {
  local bytes="${1-}"
  if [[ "$bytes" != <-> ]]; then
    REPLY=unknown
    return 0
  fi
  if (( bytes < 1024 )); then
    REPLY="$bytes B"
    return 0
  fi
  local -a units=(KiB MiB GiB TiB)
  local -i divisor=1 index=0 scaled=0
  while (( index < ${#units} && bytes >= divisor * 1024 )); do
    (( divisor *= 1024, ++index ))
  done
  scaled=$(( (bytes * 10 + divisor / 2) / divisor ))
  REPLY="$(( scaled / 10 )).$(( scaled % 10 )) ${units[index]}"
}

# REPLY describes why an entry cannot be restored.
_file_trash_state_text() {
  case "${1-}" in
    missing-item) REPLY="record without an item" ;;
    missing-info) REPLY="item without a record" ;;
    invalid-info) REPLY="invalid record" ;;
    unsafe-item) REPLY="unsafe item" ;;
    *) REPLY="${1-}" ;;
  esac
}

# REPLY is one picker or plan summary of an entry record: its deletion time,
# type, and original path with HOME shown as ~, or why it cannot be restored.
_file_trash_entry_summary() {
  emulate -L zsh
  zmodload -F zsh/datetime b:strftime 2>/dev/null || return 1
  local -a fields=("${(@ps:\t:)1}")
  local shown=""
  if [[ "${fields[2]}" != valid ]]; then
    _file_trash_state_text "${fields[2]}"
    REPLY="($REPLY)"
    return 0
  fi
  strftime -s shown '%Y-%m-%d %H:%M' "${fields[3]}" || return 1
  _file_path_display "${fields[9]}"
  REPLY="${shown}  ${fields[5]}  ${REPLY}"
}

# Prints the counted verdict of a trash batch; status 1 when any item failed.
# Usage: _file_trash_verdict <subject> <verb> <failures> <total>
_file_trash_verdict() {
  local subject="$1" verb="$2"
  local -i failures="$3" total="$4"
  _file_count_noun "$total" item
  local planned="$REPLY"
  if (( failures == 0 )); then
    _file_success "$subject completed: $planned $verb."
    return 0
  fi
  if (( failures < total )); then
    _file_error \
      "$subject completed with partial failures: $failures of $planned failed."
    _file_mark_partial
  else
    _file_error "$subject failed: $failures of $planned failed."
  fi
  return 1
}

# Reports an interrupted batch and the items it did not reach.
# Usage: _file_trash_interrupted <subject> <index> <total>
_file_trash_interrupted() {
  local subject="$1"
  local -i index="$2" total="$3"
  _file_warn "$subject interrupted; later items were not changed."
  (( index < total )) || return 0
  _file_count_noun "$(( total - index ))" item
  _file_info "Not run: $REPLY"
}

# reply is the IDs picked from entry records; status 130 on cancellation.
# Rows show the ID, deletion time, type, and original path; only the row
# index returns from fzf, so no displayed text becomes a target.
# Usage: _file_trash_pick <prompt> <record...>
_file_trash_pick() {
  emulate -L zsh
  local prompt="$1"
  shift
  reply=()
  _file_require_cmd fzf "the trash picker" || return 1
  local -a displays=()
  local record=""
  for record in "$@"; do
    _file_trash_entry_summary "$record" || return 1
    displays+=("${record%%$'\t'*}  $REPLY")
  done
  _file_select_from_snapshot "$prompt" yes displays || return $?
  local -a picked=("${reply[@]}")
  local item=""
  reply=()
  for item in "${picked[@]}"; do
    _file_trash_is_id "${item%%  *}" || return 1
    reply+=("${item%%  *}")
  done
}

# --- List ----------------------------------------------------------------------

# Prints the zdx.file-trash.v1 document on stdout as one compact line. jq
# encodes every value: the records reach it as raw TAB-separated lines on
# stdin, never as program text, and no field contains a TAB or a newline of
# its own.
# Usage: _file_trash_list_json <trash-dir> <record...>
_file_trash_list_json() {
  emulate -L zsh
  zmodload -F zsh/datetime b:strftime 2>/dev/null || return 1
  local trash_dir="$1"
  shift
  local -a lines=() fields=()
  local record="" deleted_at="" line=""
  for record in "$@"; do
    fields=("${(@ps:\t:)record}")
    if [[ "${fields[2]}" == valid ]]; then
      () {
        local -x TZ=UTC
        strftime -s deleted_at '%Y-%m-%dT%H:%M:%SZ' "${fields[3]}"
      } || return 1
      line="item"$'\t'"${fields[1]}"$'\t'"${fields[9]}"$'\t'"${deleted_at}"
      line+=$'\t'"${fields[6]}"$'\t'"${fields[5]}"
      lines+=("$line")
    else
      lines+=("skipped"$'\t'"${fields[1]}"$'\t'"${fields[2]//-/_}")
    fi
  done
  {
    (( ${#lines[@]} == 0 )) || print -rl -- "${lines[@]}"
  } | command jq -c -n -R \
    --arg schema zdx.file-trash.v1 \
    --arg trash_dir "$trash_dir" '
      [inputs | split("\t")] as $rows
      | {
          schema: $schema,
          trash_dir: $trash_dir,
          item_count: ([$rows[] | select(.[0] == "item")] | length),
          items: [$rows[] | select(.[0] == "item") | {
            id: .[1],
            original_path: .[2],
            deleted_at: .[3],
            size_bytes: (if .[4] == "-" then null else (.[4] | tonumber) end),
            type: .[5]
          }],
          skipped: [$rows[] | select(.[0] == "skipped") | {
            id: .[1],
            reason: .[2]
          }]
        }'
}

# Prints the trash inventory as a table on stderr, followed by one counted
# warning for entries that cannot be restored.
# Usage: _file_trash_list_text <trash-dir> <record...>
_file_trash_list_text() {
  emulate -L zsh
  zmodload -F zsh/datetime b:strftime 2>/dev/null || return 1
  local trash_dir="$1"
  shift
  _file_path_display "$trash_dir"
  _file_label "Trash" "$REPLY"
  local -a rows=() skipped=() fields=()
  local record="" shown="" size_shown="" row=""
  for record in "$@"; do
    fields=("${(@ps:\t:)record}")
    if [[ "${fields[2]}" != valid ]]; then
      _file_trash_state_text "${fields[2]}"
      skipped+=("${fields[1]} ($REPLY)")
      continue
    fi
    strftime -s shown '%Y-%m-%d %H:%M' "${fields[3]}" || return 1
    _file_trash_size_display "${fields[6]}"
    size_shown="$REPLY"
    _file_path_display "${fields[9]}"
    row="${fields[1]}"$'\t'"${shown}"$'\t'"${fields[5]}"
    row+=$'\t'"${size_shown}"$'\t'"${REPLY}"
    rows+=("$row")
  done
  if (( ${#rows[@]} > 0 )); then
    print -u2 -r -- ""
    _file_table $'ID\tDeleted\tType\tSize\tOriginal path' "${rows[@]}"
  fi
  if (( ${#skipped[@]} > 0 )); then
    _file_count_noun "${#skipped[@]}" "trash entry" "trash entries"
    _file_warn "Skipped $REPLY that cannot be restored; file-trash purge ID removes one."
    local entry=""
    if (( ${#skipped[@]} <= 3 )) || _file_verbose; then
      for entry in "${skipped[@]}"; do
        _file_dim "$entry"
      done
    else
      _file_dim "Set ZDX_VERBOSE=1 to list them."
    fi
  fi
  if (( ${#rows[@]} == 0 && ${#skipped[@]} == 0 )); then
    _file_info "The trash is empty."
  elif (( ${#rows[@]} == 0 )); then
    _file_info "The trash has no restorable items."
  fi
  return 0
}

# Inventories only the deletion engine's reserved recovery namespace in the
# validated private trash containers. A matching name is a bounded recovery
# candidate, not historical proof of which invocation created it. No new ID or
# record format is assigned. reply holds exact paths, never their contents.
_file_trash_recovery_paths() {
  emulate -L zsh
  setopt local_options no_multibyte
  local LC_ALL=C trash_dir="$1" directory="" candidate=""
  local MATCH="" MBEGIN="" MEND=""
  local -a match=() mbegin=() mend=() candidates=() recovered=()
  local -i count=0 bytes=0
  reply=()
  _file_trash_private_dir "$trash_dir" || return 1
  _file_validate_ancestor_chain "$trash_dir" || return 1
  for directory in "$trash_dir/files" "$trash_dir/info"; do
    [[ -e "$directory" || -L "$directory" ]] || continue
    _file_trash_private_dir "$directory" || return 1
    _file_directory_identity "$directory" || return 1
    local directory_identity="$REPLY"
    candidates=("$directory"/.zdx-file-delete.*(DN))
    for candidate in "${candidates[@]}"; do
      (( ++count <= _FILE_MAX_CANDIDATES )) || return 1
      (( bytes += ${#candidate} + 1 ))
      (( bytes <= _FILE_MAX_PICKER_BYTES )) || return 1
      if [[ ! "${candidate:t}" =~ '^\.zdx-file-delete\.((0|[1-9][0-9]*)-[0-9]+)?\.(0|[1-9][0-9]{0,4})\.[1-9][0-9]{0,2}$' ]]; then
        _file_error "An unrecognized trash recovery name needs manual review: $candidate"
        return 1
      fi
      local -a name_fields=("${(@s:.:)${candidate:t}}")
      # Empty timestamps came from the historical standalone engine before it
      # enabled EPOCHREALTIME. The numeric suffix remains strictly bounded.
      # The engine uses Zsh RANDOM and a bounded 1..128 reservation loop.
      (( 10#${name_fields[4]} <= 32767 \
        && 10#${name_fields[5]} >= 1 && 10#${name_fields[5]} <= 128 )) || {
        _file_error "An unrecognized trash recovery name needs manual review: $candidate"
        return 1
      }
      recovered+=("$candidate")
    done
    _file_revalidate_parent "$directory/inventory" "$directory_identity" \
      || return 1
  done
  reply=("${recovered[@]}")
}

# Usage: _file_trash_list JSON_MODE
_file_trash_list() {
  emulate -L zsh
  local json_mode="$1"
  if [[ "$json_mode" == yes ]]; then
    _file_require_cmd jq "file-trash list --json" || return 1
  else
    _file_header "Trash"
  fi
  _file_trash_locate || return 1
  local trash_dir="$REPLY"
  local -a entries=() recoveries=()
  if [[ "${reply[1]}" == present ]]; then
    _file_trash_load "$trash_dir" || return 1
    entries=("${reply[@]}")
    _file_trash_recovery_paths "$trash_dir" || return 1
    recoveries=("${reply[@]}")
  fi
  local recovery=""
  for recovery in "${recoveries[@]}"; do
    _file_warn "Retained trash recovery data needs review; purge --all includes it."
    _file_path_display "$recovery"
    _file_label "Recovery path" "$REPLY"
  done
  if [[ "$json_mode" == yes ]]; then
    _file_trash_list_json "$trash_dir" "${entries[@]}"
  else
    _file_trash_list_text "$trash_dir" "${entries[@]}"
  fi
}

# --- Put -----------------------------------------------------------------------

# Validates a symbolic link below the operation base as the link itself,
# never its target. Its parent must be a canonical directory trusted like
# every other mutation parent. REPLY is "<path>|<fingerprint>", as from
# _file_validate_mutation_target.
_file_trash_validate_link() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local target="$1" base="$2"
  REPLY=""
  [[ -n "$target" && "$target" != *[[:cntrl:]]* \
    && "$target" != *'|'* ]] || {
    _file_error "Refusing an empty or unrepresentable path."
    return 1
  }
  _file_path_in_base "$target" "$base" || return 1
  local lexical="$REPLY" parent="${REPLY:h}"
  REPLY=""
  [[ "$lexical" == "$base"/* ]] || {
    _file_error "Refusing a target outside the operation base: $target"
    return 1
  }
  [[ -L "$lexical" && -d "$parent" && ! -L "$parent" \
    && "$parent" == "${parent:A}" ]] || {
    _file_error "A symbolic link must be named through real directories: $target"
    return 1
  }
  _file_system_root_uid || return 1
  local -i system_root_uid=$REPLY
  local -A parent_state=() link_state=()
  zstat -LH parent_state -- "$parent" 2>/dev/null \
    && zstat -LH link_state -- "$lexical" 2>/dev/null || {
    _file_error "Could not inspect mutation target: $target"
    return 1
  }
  # The parent passes the rule that _file_validate_ancestor_chain applies to
  # every ancestor of a regular target.
  if (( (parent_state[uid] != system_root_uid \
      && parent_state[uid] != EUID) \
    || ((parent_state[mode] & 8#22) != 0 \
      && ! (parent_state[uid] == system_root_uid \
        && (parent_state[mode] & 8#1000) != 0 \
        && (parent_state[mode] & 8#2) != 0)) )); then
    _file_error \
      "A parent directory is not trusted against replacement: $parent"
    _file_wsl_drive_hint "$parent"
    return 1
  fi
  _file_validate_ancestor_chain "$parent" || return 1
  (( link_state[uid] == EUID && link_state[nlink] == 1 )) || {
    _file_error "Mutation target ownership or permissions are unsafe: $target"
    return 1
  }
  _file_path_fingerprint "$lexical" || {
    _file_error "Could not fingerprint mutation target: $target"
    return 1
  }
  REPLY="${lexical}|${REPLY}"
}

# REPLY is the type of a fingerprinted node: file, directory, or symlink.
_file_trash_fingerprint_type() {
  local -a fields=("${(@s/:/)1}")
  case $(( ${fields[3]:-0} & 8#170000 )) in
    $(( 8#040000 ))) REPLY=directory ;;
    $(( 8#120000 ))) REPLY=symlink ;;
    *) REPLY=file ;;
  esac
}

# Plans exact trash targets below one operation base. reply holds the
# canonical targets and REPLY their newline-joined fingerprints. A symbolic
# link is planned as the link itself. A directory must pass the recursive
# validation that the purge engine applies later, so everything trashed can
# also be purged. Callers declare the mount pass (_file_mount_snapshot).
# Usage: _file_trash_put_plan <base> <trash-dir> <path...>
_file_trash_put_plan() {
  local base_dir="$1" trash_dir="$2"
  shift 2
  reply=()
  (( $# <= _FILE_MAX_CANDIDATES )) || {
    _file_error "Trash plans accept at most $_FILE_MAX_CANDIDATES targets."
    return 2
  }
  local -a identities=() target_ancestors=()
  # Planned targets and every directory between each target and the base,
  # so duplicate and containment checks stay linear in the plan size.
  local -A planned_targets=() planned_ancestors=()
  local requested="" validation="" absolute="" ancestor=""
  for requested in "$@"; do
    _file_path_in_base "$requested" "$base_dir" || return 1
    if [[ -L "$REPLY" ]]; then
      _file_trash_validate_link "$requested" "$base_dir" || return 1
    else
      _file_validate_mutation_target "$requested" "$base_dir" || return 1
    fi
    validation="$REPLY"
    absolute="${validation%%|*}"
    if [[ "$absolute" == "$trash_dir" || "$absolute" == "$trash_dir"/* \
      || "$trash_dir" == "$absolute"/* ]]; then
      _file_error "Refusing to move the trash into itself: $requested"
      return 1
    fi
    if (( ${+planned_targets[$absolute]} )); then
      _file_error "Duplicate target in plan: $requested"
      return 1
    fi
    target_ancestors=()
    ancestor="${absolute:h}"
    while [[ "$ancestor" == "$base_dir"/* ]]; do
      target_ancestors+=("$ancestor")
      ancestor="${ancestor:h}"
    done
    if (( ${+planned_ancestors[$absolute]} )); then
      _file_error "Trash targets may not contain one another."
      return 1
    fi
    for ancestor in "${target_ancestors[@]}"; do
      if (( ${+planned_targets[$ancestor]} )); then
        _file_error "Trash targets may not contain one another."
        return 1
      fi
    done
    if [[ -d "$absolute" && ! -L "$absolute" ]]; then
      _file_validate_tree_for_transfer "$absolute" yes || {
        _file_dim "A directory moves to the trash only when it holds no links, special or hard-linked files, or mounts, so that purge can delete it later."
        return 1
      }
    else
      _file_mountpoint_clear "$absolute" || return 1
    fi
    _file_trash_same_filesystem "$absolute" "$trash_dir/files" || return 1
    planned_targets[$absolute]=1
    for ancestor in "${target_ancestors[@]}"; do
      planned_ancestors[$ancestor]=1
    done
    reply+=("$absolute")
    identities+=("${validation#*|}")
  done
  (( ${#reply[@]} > 0 )) || {
    _file_error "At least one path is required."
    return 2
  }
  REPLY="${(F)identities}"
}

# Revalidates every reviewed trash target and directory tree after
# authorization, before the first move.
# Usage: _file_trash_put_revalidate <targets-array-name> <fingerprints>
_file_trash_put_revalidate() {
  local targets_name="$1" identities_text="$2"
  local -a targets=("${(@P)targets_name}")
  local -a identities=("${(@f)identities_text}")
  (( ${#targets[@]} == ${#identities[@]} )) || return 1
  local -i index=1
  while (( index <= ${#targets[@]} )); do
    _file_revalidate_mutation_target \
      "${targets[index]}" "${identities[index]}" || return 1
    if [[ -d "${targets[index]}" && ! -L "${targets[index]}" ]]; then
      _file_validate_tree_for_transfer "${targets[index]}" yes || return 1
    fi
    (( ++index ))
  done
}

# Publishes one record without clobbering: private same-directory staging,
# then the suite's hard-link publication, which fails when the name exists,
# so the record also reserves its ID. REPLY is the record's node identity.
# Usage: _file_trash_write_info <record> <content> <info-dir-identity>
_file_trash_write_info() {
  emulate -L zsh
  zmodload zsh/system 2>/dev/null || return 1
  local info_file="$1" content="$2" info_identity="$3"
  REPLY=""
  _file_make_sibling_temp "$info_file" || return 1
  local staged="$REPLY" staged_identity=""
  if ! _file_node_identity "$staged"; then
    command rm -f -- "$staged" 2>/dev/null
    return 1
  fi
  staged_identity="$REPLY"
  local -i write_fd=-1 publish_rc=1
  {
    sysopen -w -o nofollow,cloexec -u write_fd -- "$staged" 2>/dev/null || {
      _file_error "Could not open the private trash record."
      return 1
    }
    print -rn -u $write_fd -- "$content" || return 1
    exec {write_fd}>&-
    write_fd=-1
    _file_publish_staged_file "$staged" "$info_file" absent "$info_identity" \
      || { publish_rc=$?; return $publish_rc; }
    _file_node_identity "$info_file" || return 1
    [[ "$REPLY" == "$staged_identity" ]] || return 1
    publish_rc=0
  } always {
    (( write_fd >= 0 )) && exec {write_fd}>&-
    local REPLY="" staged_inode="${(j/:/)${(@s/:/)staged_identity}[1,2]}"
    if [[ -e "$staged" || -L "$staged" ]]; then
      if _file_node_identity "$staged" \
        && [[ "${(j/:/)${(@s/:/)REPLY}[1,2]}" == "$staged_inode" ]]; then
        command rm -f -- "$staged" 2>/dev/null
      else
        _file_warn "The private trash record changed; it was kept: $staged"
      fi
    fi
    # A publication that failed after its hard link withdraws that link.
    if (( publish_rc != 0 )) && [[ -f "$info_file" && ! -L "$info_file" ]] \
      && _file_node_identity "$info_file" \
      && [[ "${(j/:/)${(@s/:/)REPLY}[1,2]}" == "$staged_inode" ]]; then
      command rm -f -- "$info_file" 2>/dev/null
    fi
  }
  return $publish_rc
}

# Removes a record this invocation published, only while it keeps its
# published identity.
# Usage: _file_trash_discard_info <record> <node-identity> <parent-identity>
_file_trash_discard_info() {
  local info_file="$1" expected_identity="$2" parent_identity="$3" REPLY=""
  _file_revalidate_parent "$info_file" "$parent_identity" || return 1
  [[ -e "$info_file" || -L "$info_file" ]] || return 0
  _file_node_identity "$info_file" \
    && [[ "$REPLY" == "$expected_identity" ]] || {
    _file_warn "A trash record changed; it was kept: $info_file"
    return 1
  }
  command rm -f -- "$info_file" 2>/dev/null
}

# Checks the exact reserved record through its reviewed directory, fingerprint,
# and content digest. These checks bound races; they do not lock the pathname.
_file_trash_reservation_valid() {
  local info_file="$1" fingerprint="$2" digest="$3" parent_identity="$4"
  local REPLY=""
  local -i check_rc=0
  _file_revalidate_parent "$info_file" "$parent_identity" \
    && _file_revalidate_mutation_target "$info_file" "$fingerprint" || {
    _file_error "The trash reservation changed before the move completed."
    return 1
  }
  _file_sha256_digest "$info_file" || check_rc=$?
  if (( check_rc != 0 )); then
    _file_error "Could not verify the reserved trash record."
    return $check_rc
  fi
  [[ "$REPLY" == "$digest" ]] \
    && _file_revalidate_mutation_target "$info_file" "$fingerprint" || {
    _file_error "The trash reservation changed before the move completed."
    return 1
  }
}

# Moves one reviewed target into the trash, binding both destination directories
# and its published reservation before and after the no-clobber move. If the
# reservation disappears after the move, compensate only to a still-vacant,
# reviewed original parent; otherwise retain and name the exact recovery item.
# Usage: _file_trash_put_one <target> <fingerprint> <trash-dir>
#          <info-dir-identity> <files-dir-identity> <mv-command...>
_file_trash_put_one() {
  emulate -L zsh
  zmodload -F zsh/datetime b:strftime p:EPOCHSECONDS 2>/dev/null || return 1
  local target="$1" expected_identity="$2" trash_dir="$3" info_identity="$4"
  local files_identity="$5"
  shift 5
  local -a mv_command=("$@")
  local files_dir="$trash_dir/files" info_dir="$trash_dir/info"
  REPLY=""
  _file_fingerprint_node_identity "$expected_identity" || return 1
  local expected_node_identity="$REPLY"
  _file_directory_identity "${target:h}" || return 1
  local parent_identity="$REPLY"
  _file_revalidate_parent "$files_dir/reservation" "$files_identity" || return 1

  local stamp="" suffix="" id=""
  local -i attempt=0
  strftime -s stamp '%Y%m%d-%H%M%S' "$EPOCHSECONDS" || return 1
  while (( ++attempt <= 64 )); do
    printf -v suffix '%06x' $(( ((RANDOM << 15) ^ RANDOM ^ (attempt << 9)) & 16#ffffff ))
    id="${stamp}-${suffix}"
    [[ ! -e "$files_dir/$id" && ! -L "$files_dir/$id" \
      && ! -e "$info_dir/$id.trashinfo" \
      && ! -L "$info_dir/$id.trashinfo" ]] && break
    id=""
  done
  [[ -n "$id" ]] || {
    _file_error "Could not reserve a unique trash ID."
    return 1
  }
  local deletion_date=""
  strftime -s deletion_date '%Y-%m-%dT%H:%M:%S' "$EPOCHSECONDS" || return 1
  _file_trash_encode_path "$target"
  local content="[Trash Info]"$'\n'"Path=${REPLY}"$'\n'
  content+="DeletionDate=${deletion_date}"$'\n'
  local info_file="$info_dir/$id.trashinfo" item="$files_dir/$id"
  _file_trash_write_info "$info_file" "$content" "$info_identity" || return $?
  local info_node_identity="$REPLY" info_fingerprint="" info_digest=""
  local -i operation_rc=1 reservation_lost=0 cleanup_rc=0
  {
    () {
      _file_trash_read_info "$info_file" "$trash_dir" || return 1
      local -a record_fields=("${(@ps:\t:)REPLY}")
      [[ "${record_fields[3]}" == "$target" \
        && "${record_fields[2]}" == "$deletion_date" ]] || return 1
      _file_path_fingerprint "$info_file" || return 1
      info_fingerprint="$REPLY"
      _file_fingerprint_node_identity "$info_fingerprint" \
        && [[ "$REPLY" == "$info_node_identity" ]] || {
        _file_error "The published trash reservation was replaced."
        return 1
      }
      _file_sha256_digest "$info_file" || return $?
      info_digest="$REPLY"
      _file_revalidate_mutation_target "$target" "$expected_identity" || return 1
      [[ -d "$target" && ! -L "$target" ]] && _file_mount_mode=""
      _file_delete_mounts_clear "$target" yes || return 1
      _file_revalidate_parent "$target" "$parent_identity" || return 1
      _file_trash_same_filesystem "$target" "$files_dir" || return 1
      _file_trash_private_dir "$trash_dir" || return 1
      _file_revalidate_parent "$item" "$files_identity" || return 1
      _file_trash_reservation_valid "$info_file" "$info_fingerprint" \
        "$info_digest" "$info_identity" || return $?
      command "${mv_command[@]}" -- "$target" "$item" 2>/dev/null || {
        operation_rc=$?
        _file_error "Could not move the exact target into the trash."
        return $operation_rc
      }
      [[ ! -e "$target" && ! -L "$target" ]] || {
        _file_error "The trash target remained after the move."
        return 1
      }
      _file_trash_private_dir "$trash_dir" || return 1
      _file_revalidate_parent "$item" "$files_identity" || return 1
      _file_path_fingerprint "$item" \
        && _file_fingerprint_node_identity "$REPLY" \
        && [[ "$REPLY" == "$expected_node_identity" ]] || {
        _file_error "The trashed item changed identity during the move."
        return 1
      }
      _file_trash_reservation_valid "$info_file" "$info_fingerprint" \
        "$info_digest" "$info_identity" || {
        operation_rc=$?
        reservation_lost=1
        return $operation_rc
      }
      return 0
    }
    operation_rc=$?
  } always {
    if (( operation_rc != 0 )); then
      local REPLY=""
      if _file_revalidate_parent "$item" "$files_identity" \
        && [[ -e "$item" || -L "$item" ]] \
        && _file_path_fingerprint "$item" \
        && _file_fingerprint_node_identity "$REPLY" \
        && [[ "$REPLY" == "$expected_node_identity" ]]; then
        if (( reservation_lost )) \
          && [[ ! -e "$target" && ! -L "$target" ]] \
          && _file_revalidate_parent "$target" "$parent_identity" \
          && _file_trash_same_filesystem "$item" "${target:h}"; then
          cleanup_rc=0
          command "${mv_command[@]}" -- "$item" "$target" 2>/dev/null \
            || cleanup_rc=$?
          if (( cleanup_rc == 0 )) && [[ ! -e "$item" && ! -L "$item" ]] \
            && _file_path_fingerprint "$target" \
            && _file_fingerprint_node_identity "$REPLY" \
            && [[ "$REPLY" == "$expected_node_identity" ]]; then
            _file_warn "The reservation was lost; the reviewed item was returned."
          elif [[ ! -e "$item" && ! -L "$item" \
            && -d "$target" && ! -L "$target" \
            && "$target" == "${target:A}" ]] \
            && _file_validate_ancestor_chain "$target" \
            && _file_path_fingerprint "$target/${item:t}" \
            && _file_fingerprint_node_identity "$REPLY" \
            && [[ "$REPLY" == "$expected_node_identity" ]]; then
            # BSD mv -n can receive the item inside a newly appeared directory.
            # The identity-bound nested item is retained, never moved again.
            _file_error "Compensation did not return the item to its original path."
            _file_path_display "$target/${item:t}"
            _file_label "Recovery path" "$REPLY"
            _file_path_display "$target"
            _file_label "Original path" "$REPLY"
          fi
        fi
        if [[ -e "$item" || -L "$item" ]] \
          && _file_path_fingerprint "$item" \
          && _file_fingerprint_node_identity "$REPLY" \
          && [[ "$REPLY" == "$expected_node_identity" ]]; then
          _file_error "Trash did not complete; the reviewed item was retained."
          _file_path_display "$item"
          _file_label "Recovery path" "$REPLY"
          _file_path_display "$target"
          _file_label "Original path" "$REPLY"
        fi
      elif [[ -e "$item" || -L "$item" ]]; then
        _file_warn "The trash destination changed; its replacement was kept."
        _file_path_display "$item"
        _file_label "Unverified path" "$REPLY"
      fi
      if [[ -e "$target" || -L "$target" ]]; then
        local -i discard_rc=0
        _file_trash_discard_info "$info_file" "$info_node_identity" "$info_identity" \
          || discard_rc=$?
        (( discard_rc == 130 || discard_rc == 143 )) && cleanup_rc=$discard_rc
      fi
    fi
  }
  REPLY="$id"
  (( cleanup_rc == 130 || cleanup_rc == 143 )) && return $cleanup_rc
  return $operation_rc
}

# Usage: _file_trash_put_execute DRY_RUN AUTO_YES PATH...
_file_trash_put_execute() {
  emulate -L zsh
  local dry_run="$1" auto_yes="$2"
  shift 2
  _file_header "Move to Trash"
  local _file_operation_base="${_file_operation_base-}"
  local _file_operation_base_identity="${_file_operation_base_identity-}"
  _file_validate_base "$PWD" || return 1
  local base_dir="$REPLY"
  _file_directory_identity "$base_dir" || return 1
  _file_operation_base="$base_dir"
  _file_operation_base_identity="$REPLY"
  _file_trash_locate || return 1
  local trash_dir="$REPLY"
  # One mount snapshot serves the plan; execution takes a fresh one.
  local _file_mount_mode=""
  local -A _file_mount_targets=()
  _file_trash_put_plan "$base_dir" "$trash_dir" "$@" || return $?
  local -a targets=("${reply[@]}")
  local identities_text="$REPLY"
  local -a identities=("${(@f)identities_text}")
  local -A _file_reviewed_parent_ids=()
  _file_snapshot_parent_identities targets || return 1

  local -a plan_rows=()
  local -i index=1
  local target=""
  for target in "${targets[@]}"; do
    _file_trash_fingerprint_type "${identities[index]}"
    plan_rows+=("${index}"$'\t'"${target#"$base_dir"/}"$'\t'"${REPLY}")
    (( ++index ))
  done
  _file_path_display "$base_dir"
  _file_label "Directory" "$REPLY"
  _file_path_display "$trash_dir"
  _file_label "Trash" "$REPLY"
  print -u2 -r -- ""
  _file_table $'#\tPath\tType' "${plan_rows[@]}"
  _file_count_noun "${#targets[@]}" item
  local planned="$REPLY"
  if [[ "$dry_run" == yes ]]; then
    _file_info "Dry run: $planned planned; nothing was moved."
    return 0
  fi

  _file_confirm_mutation "Move ${planned} to the trash?" "$auto_yes" \
    "Cancelled: nothing was moved."
  local -i confirm_rc=$?
  (( confirm_rc == 0 )) || {
    (( confirm_rc == 130 )) && return 0
    return $confirm_rc
  }
  _file_mount_mode=""
  _file_trash_put_revalidate targets "$identities_text" || return 1
  _file_trash_prepare || return 1
  [[ "$REPLY" == "$trash_dir" ]] || {
    _file_error "The trash location changed after review."
    return 1
  }
  local info_identity="${reply[1]}" files_identity="${reply[2]}"
  local -a mv_command=()
  _file_mv_no_clobber_command || return 1
  mv_command=("${reply[@]}")

  local display=""
  local -i failures=0 action_rc=0
  index=1
  while (( index <= ${#targets[@]} )); do
    target="${targets[index]}"
    display="${target#"$base_dir"/}"
    action_rc=0
    _file_trash_put_one "$target" "${identities[index]}" "$trash_dir" \
      "$info_identity" "$files_identity" "${mv_command[@]}" || action_rc=$?
    if (( action_rc == 0 )); then
      _file_success "Trashed $display as $REPLY"
    else
      _file_error "Failed (status $action_rc): $display"
      (( ++failures ))
      if (( action_rc == 130 || action_rc == 143 )); then
        _file_trash_interrupted "Trash" "$index" "${#targets[@]}"
        return $action_rc
      fi
    fi
    (( ++index ))
  done
  _file_trash_verdict "Trash" moved "$failures" "${#targets[@]}"
}

# --- Restore -------------------------------------------------------------------

# Validates the original path of a trashed item as a restore destination:
# nothing may exist there, and its parent must still exist as a canonical
# directory that the current user owns and others cannot write, below
# trusted ancestors. reply is (destination parent-identity).
_file_trash_restore_destination() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local destination="$1" parent="${1:h}"
  reply=()
  local REPLY=""
  if [[ -e "$destination" || -L "$destination" ]]; then
    _file_path_display "$destination"
    _file_error "Refusing to replace an existing path: $REPLY"
    _file_dim "Move it away, then restore again; the item stays in the trash."
    return 1
  fi
  if [[ ! -e "$parent" && ! -L "$parent" ]]; then
    _file_path_display "$parent"
    _file_error "The original parent directory no longer exists: $REPLY"
    _file_dim "Recreate it, then restore again; the item stays in the trash."
    return 1
  fi
  local -A parent_state=()
  [[ -d "$parent" && ! -L "$parent" && "$parent" == "${parent:A}" ]] \
    && zstat -LH parent_state -- "$parent" 2>/dev/null || {
    _file_path_display "$parent"
    _file_error "The original parent is not a real directory reached without symbolic links: $REPLY"
    return 1
  }
  (( parent_state[uid] == EUID && (parent_state[mode] & 8#22) == 0 )) || {
    _file_path_display "$parent"
    _file_error "The original parent must be owned by you and not group/world-writable: $REPLY"
    _file_wsl_drive_hint "$parent"
    return 1
  }
  _file_validate_ancestor_chain "$parent" || return 1
  _file_directory_identity "$parent" || return 1
  reply=("$destination" "$REPLY")
}

# Moves one reviewed item back to its original path without clobbering,
# verifies the restored identity, and then deletes its record through the
# quarantine engine. A record that cannot be deleted is reported, and the
# restore still counts.
# Usage: _file_trash_restore_one <item> <item-fingerprint> <record>
#          <record-fingerprint> <destination> <parent-identity> <mv-command...>
_file_trash_restore_one() {
  emulate -L zsh
  local item="$1" item_identity="$2" info_file="$3" info_identity="$4"
  local destination="$5" parent_identity="$6"
  shift 6
  local -a mv_command=("$@")
  _file_fingerprint_node_identity "$item_identity" || return 1
  local expected_node_identity="$REPLY"
  _file_revalidate_mutation_target "$item" "$item_identity" || return 1
  _file_revalidate_mutation_target "$info_file" "$info_identity" || return 1
  _file_revalidate_parent "$destination" "$parent_identity" || return 1
  [[ ! -e "$destination" && ! -L "$destination" ]] || {
    _file_path_display "$destination"
    _file_error "A path appeared at the original location: $REPLY"
    return 1
  }
  _file_trash_same_filesystem "$item" "${destination:h}" || return 1
  local -i move_rc=0
  command "${mv_command[@]}" -- "$item" "$destination" 2>/dev/null \
    || move_rc=$?
  if (( move_rc != 0 )); then
    _file_error "Could not move the trashed item back."
    return $move_rc
  fi
  [[ ! -e "$item" && ! -L "$item" ]] || {
    _file_error "The trashed item remained after the move."
    return 1
  }
  _file_path_fingerprint "$destination" \
    && _file_fingerprint_node_identity "$REPLY" \
    && [[ "$REPLY" == "$expected_node_identity" ]] || {
    _file_error "The restored path does not match the trashed item."
    # Without mv -T, a directory that appeared at the destination receives
    # the item instead of being replaced.
    if [[ -e "$destination/${item:t}" || -L "$destination/${item:t}" ]]; then
      _file_dim "The item was moved into: $destination/${item:t}"
    fi
    return 1
  }
  local -i cleanup_rc=0
  _file_quarantine_delete "$info_file" "$info_identity" "${mv_command[@]}" \
    || cleanup_rc=$?
  if (( cleanup_rc != 0 )); then
    _file_warn "Restored, but its trash record could not be removed: $info_file"
  fi
  REPLY=restored
  (( cleanup_rc == 130 || cleanup_rc == 143 )) && return $cleanup_rc
  return 0
}

# Usage: _file_trash_restore_execute DRY_RUN AUTO_YES [ID...]
# Without IDs, the restorable entries open in a picker.
_file_trash_restore_execute() {
  emulate -L zsh
  local dry_run="$1" auto_yes="$2"
  shift 2
  local -a requested_ids=("$@")
  # A picked plan prints its heading after the picker closes.
  (( ${#requested_ids[@]} == 0 )) || _file_header "Restore From Trash"
  _file_trash_locate || return 1
  local trash_dir="$REPLY"
  local -a entries=()
  if [[ "${reply[1]}" == present ]]; then
    _file_trash_load "$trash_dir" || return 1
    entries=("${reply[@]}")
  fi
  local -A records=()
  local record=""
  for record in "${entries[@]}"; do
    records[${record%%$'\t'*}]="$record"
  done
  if (( ${#requested_ids[@]} == 0 )); then
    local -a restorable=()
    for record in "${entries[@]}"; do
      [[ "${${record#*$'\t'}%%$'\t'*}" == valid ]] && restorable+=("$record")
    done
    if (( ${#restorable[@]} == 0 )); then
      _file_info "The trash has no items to restore."
      return 0
    fi
    _file_trash_pick "Select items to restore" "${restorable[@]}"
    local -i pick_rc=$?
    (( pick_rc == 0 )) || {
      (( pick_rc == 130 )) && return 0
      return $pick_rc
    }
    requested_ids=("${reply[@]}")
    _file_header "Restore From Trash"
  fi

  local _file_mount_mode=""
  local -A _file_mount_targets=() planned_destinations=()
  local -a items=() item_ids=() infos=() info_ids=() destinations=()
  local -a parent_ids=() plan_rows=() fields=()
  local id="" destination=""
  local -i index=1
  for id in "${requested_ids[@]}"; do
    record="${records[$id]-}"
    [[ -n "$record" ]] || {
      _file_error "Unknown trash ID: $id"
      return 1
    }
    fields=("${(@ps:\t:)record}")
    if [[ "${fields[2]}" != valid ]]; then
      _file_trash_state_text "${fields[2]}"
      _file_error "Trash entry $id cannot be restored: $REPLY."
      return 1
    fi
    destination="${fields[9]}"
    if (( ${+planned_destinations[$destination]} )); then
      _file_path_display "$destination"
      _file_error "Two trash entries restore to the same path: $REPLY"
      return 1
    fi
    _file_trash_restore_destination "$destination" || return 1
    parent_ids+=("${reply[2]}")
    _file_trash_same_filesystem "$trash_dir/files/$id" "${destination:h}" \
      || return 1
    planned_destinations[$destination]=1
    items+=("$trash_dir/files/$id")
    item_ids+=("${fields[7]}")
    infos+=("$trash_dir/info/$id.trashinfo")
    info_ids+=("${fields[8]}")
    destinations+=("$destination")
    _file_path_display "$destination"
    plan_rows+=("${index}"$'\t'"${id}"$'\t'"${REPLY}")
    (( ++index ))
  done

  local -A _file_reviewed_parent_ids=()
  _file_snapshot_parent_identities items || return 1
  _file_snapshot_parent_identities infos || return 1
  _file_path_display "$trash_dir"
  _file_label "Trash" "$REPLY"
  print -u2 -r -- ""
  _file_table $'#\tID\tRestore to' "${plan_rows[@]}"
  _file_count_noun "${#items[@]}" item
  local planned="$REPLY"
  if [[ "$dry_run" == yes ]]; then
    _file_info "Dry run: $planned planned; nothing was restored."
    return 0
  fi
  _file_confirm_mutation "Restore ${planned}?" "$auto_yes" \
    "Cancelled: nothing was restored."
  local -i confirm_rc=$?
  (( confirm_rc == 0 )) || {
    (( confirm_rc == 130 )) && return 0
    return $confirm_rc
  }
  # Revalidate the complete plan before the first move.
  _file_mount_mode=""
  index=1
  while (( index <= ${#items[@]} )); do
    _file_revalidate_mutation_target "${items[index]}" "${item_ids[index]}" \
      && _file_revalidate_mutation_target "${infos[index]}" "${info_ids[index]}" \
      && _file_revalidate_parent "${destinations[index]}" "${parent_ids[index]}" \
      || return 1
    [[ ! -e "${destinations[index]}" && ! -L "${destinations[index]}" ]] || {
      _file_path_display "${destinations[index]}"
      _file_error "A path appeared at the original location: $REPLY"
      return 1
    }
    (( ++index ))
  done
  local -a mv_command=()
  _file_mv_no_clobber_command || return 1
  mv_command=("${reply[@]}")

  local -i failures=0 action_rc=0
  index=1
  while (( index <= ${#items[@]} )); do
    action_rc=0
    REPLY=""
    _file_trash_restore_one "${items[index]}" "${item_ids[index]}" \
      "${infos[index]}" "${info_ids[index]}" "${destinations[index]}" \
      "${parent_ids[index]}" "${mv_command[@]}" || action_rc=$?
    local restored_result="$REPLY"
    _file_path_display "${destinations[index]}"
    if (( action_rc == 0 )); then
      _file_success "Restored $REPLY"
    else
      [[ "$restored_result" == restored ]] && _file_success "Restored $REPLY"
      _file_error "Failed (status $action_rc): $REPLY"
      (( ++failures ))
      if (( action_rc == 130 || action_rc == 143 )); then
        _file_trash_interrupted "Restore" "$index" "${#items[@]}"
        return $action_rc
      fi
    fi
    (( ++index ))
  done
  _file_trash_verdict "Restore" restored "$failures" "${#items[@]}"
}

# --- Purge ---------------------------------------------------------------------

# Deletes one entry, its item and then its record, through the quarantined
# File deletion engine. Either part may be absent for a damaged entry.
# Usage: _file_trash_purge_one <item> <item-fingerprint> <record>
#          <record-fingerprint> <mv-command...>
_file_trash_purge_one() {
  local item="$1" item_identity="$2" info_file="$3" info_identity="$4"
  shift 4
  if [[ "$item_identity" != - ]]; then
    _file_quarantine_delete --require-owner-rwx "$item" "$item_identity" "$@" \
      || return $?
  fi
  if [[ "$info_identity" != - ]]; then
    _file_quarantine_delete "$info_file" "$info_identity" "$@" || return $?
  fi
  return 0
}

# Validates one complete purge target, including its entire recursive tree,
# before the plan and again after consent. Links remain links, never targets.
_file_trash_purge_target_valid() {
  local target="$1" fingerprint="$2" container="$3" REPLY=""
  _file_trash_private_dir "${container:h}" || return 1
  _file_trash_private_dir "$container" || return 1
  if [[ -L "$target" ]]; then
    _file_trash_validate_link "$target" "$container" || return 1
  else
    _file_validate_mutation_target "$target" "$container" || return 1
  fi
  _file_revalidate_mutation_target "$target" "$fingerprint" || return 1
  _file_delete_mounts_clear "$target" yes || return 1
}

# Callers keep the four parallel arrays local to the complete purge plan.
_file_trash_purge_revalidate() {
  local -i check_index=1
  while (( check_index <= ${#items[@]} )); do
    if [[ "${item_ids[check_index]}" != - ]]; then
      _file_trash_purge_target_valid "${items[check_index]}" \
        "${item_ids[check_index]}" "${items[check_index]:h}" || return 1
    fi
    if [[ "${info_ids[check_index]}" != - ]]; then
      _file_trash_purge_target_valid "${infos[check_index]}" \
        "${info_ids[check_index]}" "${infos[check_index]:h}" || return 1
    fi
    (( ++check_index ))
  done
}

# Usage: _file_trash_purge_execute DRY_RUN AUTO_YES SELECTOR DAYS [ID...]
# SELECTOR is ids, older (DAYS), all, or pick, which opens every entry in a
# picker. Damaged entries can be purged by ID, by --all, or from the picker.
_file_trash_purge_execute() {
  emulate -L zsh
  zmodload -F zsh/datetime p:EPOCHSECONDS 2>/dev/null || return 1
  local dry_run="$1" auto_yes="$2" selector="$3" days="$4"
  shift 4
  local -a requested_ids=("$@")
  # A picked plan prints its heading after the picker closes.
  [[ "$selector" == pick ]] || _file_header "Purge Trash"
  _file_trash_locate || return 1
  local trash_dir="$REPLY"
  local -a entries=() selected=() fields=() recoveries=()
  if [[ "${reply[1]}" == present ]]; then
    _file_trash_load "$trash_dir" || return 1
    entries=("${reply[@]}")
    if [[ "$selector" == all ]]; then
      _file_trash_recovery_paths "$trash_dir" || return 1
      recoveries=("${reply[@]}")
    fi
  fi
  local -A records=()
  local record="" id=""
  for record in "${entries[@]}"; do
    records[${record%%$'\t'*}]="$record"
  done
  case "$selector" in
    ids)
      for id in "${requested_ids[@]}"; do
        [[ -n "${records[$id]-}" ]] || {
          _file_error "Unknown trash ID: $id"
          return 1
        }
        selected+=("${records[$id]}")
      done
      ;;
    older)
      local -i cutoff=$(( EPOCHSECONDS - days * 86400 ))
      for record in "${entries[@]}"; do
        fields=("${(@ps:\t:)record}")
        [[ "${fields[2]}" == valid ]] && (( fields[3] < cutoff )) \
          && selected+=("$record")
      done
      if (( ${#selected[@]} == 0 )); then
        _file_count_noun "$days" day
        _file_info "No trashed items are older than $REPLY."
        return 0
      fi
      ;;
    all|pick)
      selected=("${entries[@]}")
      if (( ${#selected[@]} == 0 && ${#recoveries[@]} == 0 )); then
        _file_info "The trash is empty."
        return 0
      fi
      if [[ "$selector" == pick ]]; then
        _file_trash_pick "Select items to purge" "${selected[@]}"
        local -i pick_rc=$?
        (( pick_rc == 0 )) || {
          (( pick_rc == 130 )) && return 0
          return $pick_rc
        }
        selected=()
        for id in "${reply[@]}"; do
          [[ -n "${records[$id]-}" ]] || return 1
          selected+=("${records[$id]}")
        done
        _file_header "Purge Trash"
      fi
      ;;
    *) return 2 ;;
  esac

  local -a plan_rows=() items=() item_ids=() infos=() info_ids=() ids=()
  local shown="" path_shown=""
  local -i index=1
  for record in "${selected[@]}"; do
    fields=("${(@ps:\t:)record}")
    id="${fields[1]}"
    if [[ "${fields[2]}" == valid ]]; then
      _file_trash_entry_summary "$record" || return 1
      shown="${REPLY%%  *}"
      _file_path_display "${fields[9]}"
      path_shown="$REPLY"
    else
      shown=unknown
      _file_trash_state_text "${fields[2]}"
      path_shown="($REPLY)"
    fi
    plan_rows+=("${index}"$'\t'"${id}"$'\t'"${shown}"$'\t'"${path_shown}")
    ids+=("$id")
    items+=("$trash_dir/files/$id")
    item_ids+=("${fields[7]}")
    infos+=("$trash_dir/info/$id.trashinfo")
    info_ids+=("${fields[8]}")
    (( ++index ))
  done
  local recovery=""
  for recovery in "${recoveries[@]}"; do
    _file_path_fingerprint "$recovery" || return 1
    items+=("$recovery")
    item_ids+=("$REPLY")
    infos+=("")
    info_ids+=(-)
    ids+=("$recovery")
    _file_path_display "$recovery"
    plan_rows+=("${index}"$'\t'"(retained)"$'\t'"unknown"$'\t'"${REPLY}")
    (( ++index ))
  done
  local -A _file_reviewed_parent_ids=()
  local -a planned_infos=()
  local info=""
  for info in "${infos[@]}"; do
    [[ -n "$info" ]] && planned_infos+=("$info")
  done
  _file_snapshot_parent_identities items || return 1
  _file_snapshot_parent_identities planned_infos || return 1
  local _file_mount_mode=""
  local -A _file_mount_targets=()
  _file_trash_purge_revalidate || return 1
  _file_path_display "$trash_dir"
  _file_label "Trash" "$REPLY"
  print -u2 -r -- ""
  _file_table $'#\tID\tDeleted\tOriginal path' "${plan_rows[@]}"
  _file_warn "Purged items cannot be restored."
  _file_count_noun "${#ids[@]}" item
  local planned="$REPLY"
  if [[ "$dry_run" == yes ]]; then
    _file_info "Dry run: $planned planned; nothing was deleted."
    return 0
  fi
  _file_confirm_mutation "Permanently delete ${planned}?" "$auto_yes" \
    "Cancelled: nothing was deleted."
  local -i confirm_rc=$?
  (( confirm_rc == 0 )) || {
    (( confirm_rc == 130 )) && return 0
    return $confirm_rc
  }
  # Renew every tree before deleting the first item, including retained data.
  _file_mount_mode=""
  _file_trash_purge_revalidate || return 1
  local -a mv_command=()
  _file_mv_no_clobber_command || return 1
  mv_command=("${reply[@]}")

  local -i failures=0 action_rc=0
  index=1
  while (( index <= ${#ids[@]} )); do
    action_rc=0
    _file_trash_purge_one "${items[index]}" "${item_ids[index]}" \
      "${infos[index]}" "${info_ids[index]}" "${mv_command[@]}" \
      || action_rc=$?
    if (( action_rc == 0 )); then
      _file_success "Deleted ${ids[index]}"
    else
      _file_error "Failed (status $action_rc): ${ids[index]}"
      (( ++failures ))
      if (( action_rc == 130 || action_rc == 143 )); then
        _file_trash_interrupted "Purge" "$index" "${#ids[@]}"
        return $action_rc
      fi
    fi
    (( ++index ))
  done
  _file_trash_verdict "Purge" deleted "$failures" "${#ids[@]}"
}

# --- Interactive manager -------------------------------------------------------

# Picks trashed items, then restores or purges them through the same plans
# as the direct actions.
# Usage: _file_trash_manager DRY_RUN AUTO_YES
_file_trash_manager() {
  emulate -L zsh
  local dry_run="$1" auto_yes="$2"
  _file_require_cmd fzf "the trash picker" || return 1
  _file_trash_locate || return 1
  local trash_dir="$REPLY"
  local -a entries=()
  if [[ "${reply[1]}" == present ]]; then
    _file_trash_load "$trash_dir" || return 1
    entries=("${reply[@]}")
  fi
  if (( ${#entries[@]} == 0 )); then
    _file_info "The trash is empty."
    _file_dim "Move paths there with: file-trash put PATH..."
    return 0
  fi
  _file_trash_pick "Select trashed items" "${entries[@]}"
  local -i pick_rc=$?
  (( pick_rc == 0 )) || {
    (( pick_rc == 130 )) && return 0
    return $pick_rc
  }
  local -a picked_ids=("${reply[@]}")
  _file_choose_fixed "Trash action" "restore" "purge"
  local -i action_rc=$?
  (( action_rc == 0 )) || {
    (( action_rc == 130 )) && return 0
    return $action_rc
  }
  case "$REPLY" in
    restore)
      _file_trash_restore_execute "$dry_run" "$auto_yes" "${picked_ids[@]}"
      ;;
    purge)
      _file_trash_purge_execute "$dry_run" "$auto_yes" ids "" \
        "${picked_ids[@]}"
      ;;
    *) return 1 ;;
  esac
}

# file-trash
#   Arguments: [put PATH... | list [--json] | restore [ID...] |
#              purge [ID... | --older-than DAYS | --all]]
#              [--dry-run] [--yes]
#   stdout:    one zdx.file-trash.v1 JSON document for list --json;
#              otherwise none.
#   Effects:   put renames paths below the current directory into the
#              trash; restore renames items back to their original paths
#              without replacing anything; purge deletes through the
#              quarantined File deletion engine. See docs/file-menu.md.
#   Status:    0 success, empty, dry run, or declined; 1 refused or failed;
#              2 invalid arguments or no terminal without --yes;
#              130/143 interrupted.
file-trash() {
  emulate -L zsh
  if (( $# == 1 )) && [[ "$1" == (-h|--help) ]] \
    || { (( $# == 2 )) && [[ "$1" == (put|list|restore|purge) \
      && "$2" == (-h|--help) ]]; }; then
    _file_trash_usage
    return 0
  fi

  local action="" dry_run=no auto_yes=no json_mode=no all=no
  local older_than="" older_set=no
  local -a operands=()
  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        _file_error "--help accepts no additional arguments."
        return 2
        ;;
      --dry-run) dry_run=yes ;;
      --yes) auto_yes=yes ;;
      --json) json_mode=yes ;;
      --all) all=yes ;;
      --older-than)
        (( $# >= 2 )) || {
          _file_error "--older-than requires a number of days."
          return 2
        }
        [[ "$older_set" == no ]] || {
          _file_error "Duplicate option: --older-than"
          return 2
        }
        older_than="$2"
        older_set=yes
        shift
        ;;
      --)
        [[ -n "$action" ]] || {
          _file_error "Name an action before --."
          return 2
        }
        shift
        operands+=("$@")
        break
        ;;
      -*)
        _file_error "Unknown option: $1"
        return 2
        ;;
      *)
        if [[ -z "$action" ]]; then
          action="$1"
        else
          operands+=("$1")
        fi
        ;;
    esac
    shift
  done

  if [[ "$json_mode" == yes && "$action" != list ]]; then
    _file_error "--json is valid only with 'file-trash list'."
    return 2
  fi
  if [[ ( "$all" == yes || "$older_set" == yes ) && "$action" != purge ]]; then
    _file_error "--all and --older-than are valid only with 'file-trash purge'."
    return 2
  fi
  local operand=""
  local -A seen_ids=()
  if [[ "$action" == (restore|purge) ]]; then
    for operand in "${operands[@]}"; do
      _file_trash_is_id "$operand" || {
        _file_error "Invalid trash ID: $operand"
        return 2
      }
      (( ! ${+seen_ids[$operand]} )) || {
        _file_error "Duplicate trash ID: $operand"
        return 2
      }
      seen_ids[$operand]=1
    done
  fi

  case "$action" in
    "")
      _file_trash_manager "$dry_run" "$auto_yes"
      ;;
    put)
      (( ${#operands[@]} > 0 )) || {
        _file_error "put requires at least one path."
        return 2
      }
      _file_trash_put_execute "$dry_run" "$auto_yes" "${operands[@]}"
      ;;
    list)
      (( ${#operands[@]} == 0 )) && [[ "$dry_run" == no \
        && "$auto_yes" == no ]] || {
        _file_error "list accepts only --json."
        return 2
      }
      _file_trash_list "$json_mode"
      ;;
    restore)
      _file_trash_restore_execute "$dry_run" "$auto_yes" "${operands[@]}"
      ;;
    purge)
      local -i selectors=0
      (( ${#operands[@]} > 0 )) && (( ++selectors ))
      [[ "$all" == yes ]] && (( ++selectors ))
      [[ "$older_set" == yes ]] && (( ++selectors ))
      (( selectors <= 1 )) || {
        _file_error "Choose one of: trash IDs, --older-than DAYS, or --all."
        return 2
      }
      if [[ "$older_set" == yes ]]; then
        [[ "$older_than" == <-> && ${#older_than} -le 5 ]] \
          && (( 10#$older_than <= _FILE_TRASH_MAX_DAYS )) || {
          _file_error "--older-than takes a whole number of days from 0 to $_FILE_TRASH_MAX_DAYS."
          return 2
        }
        _file_trash_purge_execute "$dry_run" "$auto_yes" older \
          "$(( 10#$older_than ))"
      elif [[ "$all" == yes ]]; then
        _file_trash_purge_execute "$dry_run" "$auto_yes" all ""
      elif (( ${#operands[@]} > 0 )); then
        _file_trash_purge_execute "$dry_run" "$auto_yes" ids "" \
          "${operands[@]}"
      else
        _file_trash_purge_execute "$dry_run" "$auto_yes" pick ""
      fi
      ;;
    *)
      _file_error "Unknown file-trash action: $action"
      return 2
      ;;
  esac
}

typeset -g _FILE_TRASH_SOURCED=1
