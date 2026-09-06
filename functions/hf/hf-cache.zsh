#!/usr/bin/env zsh
# =============================================================================
# Hugging Face Cache: bounded inventory and identity-bound deletion
# =============================================================================
#
# Loaded by hf-menu.zsh after hf-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_HF_CACHE_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# stdout TSV: repo_id, repo_type, size_bytes, size_display, file_count.
_hf_cache_inventory_data() {
  local -a backend=()
  _hf_backend_command || return $?
  backend=("${reply[@]}")

  _hf_run_probe 15 "${backend[@]}" -c '
import re
import sys
from huggingface_hub import CacheNotFound, scan_cache_dir

valid_id = re.compile(
    r"^[A-Za-z0-9][A-Za-z0-9._-]{0,95}"
    r"(?:/[A-Za-z0-9][A-Za-z0-9._-]{0,95})?$"
)
try:
    cache_info = scan_cache_dir()
except CacheNotFound:
    sys.exit(0)

repos = []
for repo in cache_info.repos:
    discovered_type = str(repo.repo_type)
    if discovered_type == "space":
        continue
    if discovered_type not in ("model", "dataset"):
        sys.exit(5)
    repos.append(repo)
repos.sort(key=lambda item: item.size_on_disk, reverse=True)
if len(repos) > 1000:
    sys.exit(4)
for repo in repos:
    repo_id = str(repo.repo_id)
    repo_type = str(repo.repo_type)
    size_bytes = int(repo.size_on_disk)
    file_count = int(repo.nb_files)
    size_display = str(repo.size_on_disk_str)
    if (
        not valid_id.fullmatch(repo_id)
        or repo_type not in ("model", "dataset")
        or size_bytes < 0
        or size_bytes > 9_000_000_000_000_000
        or file_count < 0
        or file_count > 1_000_000
        or len(size_display) > 64
        or any(ord(character) < 32 or ord(character) == 127 for character in size_display)
    ):
        sys.exit(5)
    print(
        f"{repo_id}\t{repo_type}\t{size_bytes}\t"
        f"{size_display}\t{file_count}"
    )
' 2>/dev/null
}

_hf_cache_render_inventory() {
  local inventory_output="$1"
  _hf_header "Hugging Face Local Cache"

  if [[ -z "$inventory_output" ]]; then
    _hf_dim "No repositories are present in the Hugging Face Hub cache."
    return 0
  fi
  (( ${#inventory_output} <= 512 * 1024 )) || return 1

  local -a lines=("${(@f)inventory_output}")
  (( ${#lines} <= 1000 )) || return 1
  printf "  %-50s  %-10s  %-12s  %-10s\n" \
    "REPOSITORY" "TYPE" "SIZE" "FILES" >&2
  _hf_dim "  --------------------------------------------------------------------------------"

  local line repo_id repo_type size_bytes size_display file_count extra
  local -i total_bytes=0
  for line in "${lines[@]}"; do
    IFS=$'\t' read -r repo_id repo_type size_bytes size_display file_count extra \
      <<< "$line"
    _hf_validate_repo_id "$repo_id" \
      && _hf_validate_repo_type "$repo_type" \
      && _hf_validate_uint "$size_bytes" 16 \
      && _hf_validate_uint "$file_count" 7 \
      && (( 10#$file_count <= 1000000 )) \
      && [[ -n "$size_display" && -z "$extra" ]] \
      && _hf_visible_value_safe "$size_display" 64 || return 1
    (( total_bytes <= 9000000000000000000 - size_bytes )) || {
      _hf_error "Cache inventory aggregate exceeds the supported size."
      return 1
    }
    (( total_bytes += size_bytes ))
    printf "  %-50s  %-10s  %-12s  %-10s\n" \
      "$(_hf_display_escape "$repo_id")" \
      "${repo_type:u}" \
      "$(_hf_display_escape "$size_display")" \
      "$file_count" >&2
  done
  print -u2 -r -- ""
  _hf_label "Repositories" "${#lines}"
  _hf_label "Accounted Bytes" "$total_bytes"
}

hf-cache-inspect() {
  local -i list_only=0
  case "${1:-}" in
    "")
      (( $# == 0 )) || return 2
      ;;
    --list)
      (( $# == 1 )) || return 2
      list_only=1
      ;;
    -h|--help)
      (( $# == 1 )) || return 2
      print -u2 -r -- 'Usage: hf-cache-inspect [--list]'
      print -u2 -r -- \
        '--list emits repo_id<TAB>type<TAB>bytes<TAB>size<TAB>files.'
      return 0
      ;;
    *)
      _hf_error \
        "Unknown hf-cache-inspect argument: $(_hf_display_escape "$1")"
      return 2
      ;;
  esac

  local inventory_output=""
  inventory_output=$(_hf_cache_inventory_data) || {
    _hf_error "Could not scan a bounded Hugging Face cache inventory."
    return 1
  }
  (( ${#inventory_output} <= 512 * 1024 )) || {
    _hf_error "The Hugging Face cache inventory is oversized."
    return 1
  }
  if (( list_only )); then
    [[ -n "$inventory_output" ]] && print -r -- "$inventory_output"
    return 0
  fi
  _hf_cache_render_inventory "$inventory_output"
}

_hf_cache_select_repo() {
  reply=()
  command -v fzf &>/dev/null || {
    _hf_error "Selecting a cached repository interactively requires fzf."
    return 1
  }

  local inventory_output=""
  inventory_output=$(_hf_cache_inventory_data) || return 1
  (( ${#inventory_output} <= 512 * 1024 )) || return 1
  [[ -n "$inventory_output" ]] || {
    _hf_warn "No bounded Hugging Face cache entries are available."
    return 0
  }

  local -a repo_ids=() repo_types=() rows=()
  local line repo_id repo_type size_bytes size_display file_count extra
  local -i index=0
  for line in "${(@f)inventory_output}"; do
    IFS=$'\t' read -r repo_id repo_type size_bytes size_display file_count extra \
      <<< "$line"
    _hf_validate_repo_id "$repo_id" \
      && _hf_validate_repo_type "$repo_type" \
      && _hf_validate_uint "$size_bytes" 16 \
      && _hf_validate_uint "$file_count" 7 \
      && (( 10#$file_count <= 1000000 )) \
      && [[ -n "$size_display" && -z "$extra" ]] \
      && _hf_visible_value_safe "$size_display" 64 || return 1
    repo_ids+=("$repo_id")
    repo_types+=("$repo_type")
    (( index++ ))
    rows+=("$repo_id (${repo_type:u}) - $size_display"$'\t'"$index")
  done
  (( ${#rows} > 0 && ${#rows} <= 1000 )) || return 1

  local -i fzf_rc=0
  _hf_fzf_capture \
    --height=50% \
    --delimiter=$'\t' \
    --with-nth=1 \
    --prompt='hf cache > ' \
    --header='Up/Down navigate | Enter plan deletion | Esc cancel' \
    < <(printf "%s\n" "${rows[@]}") || fzf_rc=$?
  local selected="$REPLY"
  if (( fzf_rc != 0 )); then
    _hf_fzf_rc_is_cancel "$fzf_rc" && return 130
    return 1
  fi
  [[ -n "$selected" ]] || return 130
  _hf_array_contains_literal "$selected" "${rows[@]}" || return 1
  index="${selected##*$'\t'}"
  [[ "$index" == <-> && index -ge 1 && index -le ${#repo_ids} ]] || return 1
  reply=("${repo_types[index]}" "${repo_ids[index]}")
}

# stdout TSV:
# PLAN, repo_id, repo_type, size_bytes, cache_root, target_path,
# root_identity, target_identity.
_hf_cache_plan_data() {
  local repo_type="$1"
  local repo_id="$2"
  _hf_validate_repo_type "$repo_type" \
    && _hf_validate_repo_id "$repo_id" || return 2

  local -a backend=()
  _hf_backend_command || return $?
  backend=("${reply[@]}")

  _hf_run_probe 15 "${backend[@]}" -c '
import os
import stat
import sys
from huggingface_hub import CacheNotFound, scan_cache_dir
from huggingface_hub.constants import HF_HUB_CACHE
from pathlib import Path

repo_type, repo_id = sys.argv[1:3]
root = Path(HF_HUB_CACHE)
try:
    cache_info = scan_cache_dir(cache_dir=root)
except CacheNotFound:
    sys.exit(3)
matches = [
    repo for repo in cache_info.repos
    if str(repo.repo_type) == repo_type and str(repo.repo_id) == repo_id
]
if len(matches) != 1:
    sys.exit(4)
repo = matches[0]
target = Path(repo.repo_path)
home = Path.home().resolve(strict=True)
if not target.is_absolute() or not root.is_absolute():
    sys.exit(5)
if target.resolve(strict=True) != target or root.resolve(strict=True) != root:
    sys.exit(6)
if root in (Path("/"), home) or os.path.commonpath((str(root), str(home))) != str(home):
    sys.exit(7)
if target.parent != root:
    sys.exit(8)
prefix = {"model": "models", "dataset": "datasets"}[repo_type]
normalized_id = repo_id.replace("/", "--")
expected_name = f"{prefix}--{normalized_id}"
if target.name != expected_name:
    sys.exit(8)
root_stat = os.lstat(root)
target_stat = os.lstat(target)
if (
    not stat.S_ISDIR(root_stat.st_mode)
    or stat.S_ISLNK(root_stat.st_mode)
    or root_stat.st_uid != os.geteuid()
    or root_stat.st_mode & 0o022
    or not stat.S_ISDIR(target_stat.st_mode)
    or stat.S_ISLNK(target_stat.st_mode)
    or target_stat.st_uid != os.geteuid()
    or target_stat.st_mode & 0o022
):
    sys.exit(9)
for value in (str(root), str(target)):
    if len(value) > 4096 or any(ord(character) < 32 or ord(character) == 127 for character in value):
        sys.exit(10)
root_identity = (
    f"{root_stat.st_dev}:{root_stat.st_ino}:"
    f"{root_stat.st_mode}:{root_stat.st_uid}"
)
target_identity = (
    f"{target_stat.st_dev}:{target_stat.st_ino}:"
    f"{target_stat.st_mode}:{target_stat.st_uid}"
)
size_bytes = int(repo.size_on_disk)
if size_bytes < 0 or size_bytes > 9_000_000_000_000_000:
    sys.exit(11)
print(
    f"PLAN\t{repo_id}\t{repo_type}\t{size_bytes}\t"
    f"{root}\t{target}\t{root_identity}\t{target_identity}"
)
' "$repo_type" "$repo_id" 2>/dev/null
}

_hf_cache_path_identity() {
  REPLY=""
  local target_path="$1"
  zmodload zsh/stat 2>/dev/null || return 1
  local -A file_state=()
  zstat -LH file_state -- "$target_path" 2>/dev/null || return 1
  REPLY="${file_state[device]}:${file_state[inode]}:${file_state[mode]}:${file_state[uid]}"
}

_hf_cache_root_permissions_safe() {
  local cache_root="$1"
  zmodload zsh/stat 2>/dev/null || return 1
  local -A root_state=()
  zstat -LH root_state -- "$cache_root" 2>/dev/null || return 1
  (( root_state[uid] == EUID && (root_state[mode] & 8#22) == 0 ))
}

_hf_cache_assert_no_mounts() {
  local target_path="$1"
  local findmnt_command=""
  findmnt_command=$(whence -p findmnt 2>/dev/null) || findmnt_command=""
  [[ -n "$findmnt_command" && -x "$findmnt_command" ]] || {
    _hf_error "findmnt is required before recursive cache deletion."
    return 1
  }
  local -a backend=()
  _hf_backend_command || return $?
  backend=("${reply[@]}")

  local inspection_output=""
  local -i inspection_rc=0
  inspection_output=$(_hf_run_probe 15 "${backend[@]}" -c '
import json
import os
import selectors
import subprocess
import sys
import time
from pathlib import Path

target = Path(sys.argv[1]).resolve(strict=True)
findmnt = sys.argv[2]
maximum_bytes = 4 * 1024 * 1024
process = None

def stop_process():
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()

try:
    environment = os.environ.copy()
    environment["LC_ALL"] = "C"
    process = subprocess.Popen(
        [findmnt, "--json", "--list", "--output", "TARGET"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        env=environment,
    )
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + 10
    output = bytearray()
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not selector.select(remaining):
            raise subprocess.TimeoutExpired(findmnt, 10)
        chunk = os.read(
            process.stdout.fileno(),
            min(65536, maximum_bytes + 1 - len(output)),
        )
        if not chunk:
            break
        output.extend(chunk)
        if len(output) > maximum_bytes:
            raise ValueError("oversized findmnt output")
    return_code = process.wait(timeout=max(0.1, deadline - time.monotonic()))
except (OSError, subprocess.TimeoutExpired, ValueError):
    stop_process()
    sys.exit(2)
finally:
    if process is not None and process.stdout is not None:
        process.stdout.close()
if return_code != 0:
    sys.exit(2)
try:
    payload = json.loads(output)
except (UnicodeDecodeError, json.JSONDecodeError):
    sys.exit(3)

if not isinstance(payload, dict):
    sys.exit(3)
filesystems = payload.get("filesystems")
if not isinstance(filesystems, list) or not filesystems:
    sys.exit(3)
stack = list(filesystems)
count = 0
while stack:
    item = stack.pop()
    count += 1
    if count > 4096 or not isinstance(item, dict):
        sys.exit(3)
    children = item.get("children", [])
    if not isinstance(children, list):
        sys.exit(3)
    stack.extend(children)
    raw_mount = item.get("target")
    if not isinstance(raw_mount, str):
        sys.exit(3)
    if (
        len(raw_mount) > 4096
        or not raw_mount.startswith("/")
        or any(ord(character) < 32 or ord(character) == 127 for character in raw_mount)
    ):
        sys.exit(3)
    mount_path = Path(raw_mount).resolve(strict=False)
    if mount_path == target or target in mount_path.parents:
        print(f"MOUNT\t{mount_path}")
        sys.exit(4)
sys.exit(0)
' "$target_path" "$findmnt_command" 2>/dev/null) || inspection_rc=$?

  case "$inspection_rc" in
    0)
      [[ -z "$inspection_output" ]] || return 1
      ;;
    4)
      if [[ "$inspection_output" == MOUNT$'\t'* \
        && "$inspection_output" != *$'\n'* \
        && ${#inspection_output} -le 8192 ]]; then
        _hf_error "Refusing a cache tree containing a mount."
        _hf_dim \
          "Mount: $(_hf_display_escape "${inspection_output#*$'\t'}")"
      else
        _hf_error "A cache mount boundary was reported with invalid data."
      fi
      return 1
      ;;
    *)
      _hf_error "Could not inspect cache mount boundaries."
      return 1
      ;;
  esac
}

_hf_cache_validate_plan() {
  local repo_id="$1"
  local repo_type="$2"
  local size_bytes="$3"
  local cache_root="$4"
  local target_path="$5"
  local root_identity="$6"
  local target_identity="$7"
  local home_root="${HOME:A}"

  _hf_validate_repo_id "$repo_id" \
    && _hf_validate_repo_type "$repo_type" \
    && _hf_validate_uint "$size_bytes" 16 || return 1
  [[ "$cache_root" == /* && "$target_path" == /* \
    && ${#cache_root} -le 4096 && ${#target_path} -le 4096 \
    && "$cache_root" != *[[:cntrl:]]* \
    && "$target_path" != *[[:cntrl:]]* ]] || return 1
  [[ "$cache_root" == "${cache_root:a}" \
    && "$cache_root" == "${cache_root:A}" \
    && "$target_path" == "${target_path:a}" \
    && "$target_path" == "${target_path:A}" \
    && "$cache_root" != "/" && "$cache_root" != "$home_root" \
    && "$cache_root" == "$home_root"/* \
    && "${target_path:h}" == "$cache_root" \
    && -d "$cache_root" && ! -L "$cache_root" && -O "$cache_root" \
    && -d "$target_path" && ! -L "$target_path" && -O "$target_path" ]] \
    || return 1
  _hf_cache_root_permissions_safe "$cache_root" || return 1
  _hf_cache_root_permissions_safe "$target_path" || return 1
  _hf_validate_ancestor_chain "$target_path" || return 1

  local expected_prefix="${repo_type}s"
  local expected_name="${expected_prefix}--${repo_id%%/*}"
  if [[ "$repo_id" == */* ]]; then
    expected_name+="--${repo_id#*/}"
  fi
  [[ "${target_path:t}" == "$expected_name" ]] || return 1

  _hf_cache_path_identity "$cache_root" || return 1
  [[ "$REPLY" == "$root_identity" ]] || return 1
  _hf_cache_path_identity "$target_path" || return 1
  [[ "$REPLY" == "$target_identity" ]]
}

_hf_cache_execute_plan() {
  local repo_type="$1"
  local repo_id="$2"
  local cache_root="$3"
  local target_path="$4"
  local root_identity="$5"
  local target_identity="$6"

  local -a backend=()
  _hf_backend_command || return $?
  backend=("${reply[@]}")

  local execution_output=""
  execution_output=$("${backend[@]}" -c '
import os
import secrets
import shutil
import stat
import sys
from pathlib import Path

repo_type, repo_id, expected_root_text, expected_target_text, expected_root_id, expected_target_id = sys.argv[1:7]
expected_root = Path(expected_root_text)
expected_target = Path(expected_target_text)

def identity(file_stat):
    return (
        f"{file_stat.st_dev}:{file_stat.st_ino}:"
        f"{file_stat.st_mode}:{file_stat.st_uid}"
    )

target = expected_target
root = expected_root
if target.parent != root:
    sys.exit(3)
if target.resolve(strict=True) != target or root.resolve(strict=True) != root:
    sys.exit(4)
root_stat = os.lstat(root)
target_stat = os.lstat(target)
if (
    identity(root_stat) != expected_root_id
    or identity(target_stat) != expected_target_id
    or not stat.S_ISDIR(root_stat.st_mode)
    or stat.S_ISLNK(root_stat.st_mode)
    or root_stat.st_uid != os.geteuid()
    or root_stat.st_mode & 0o022
    or not stat.S_ISDIR(target_stat.st_mode)
    or stat.S_ISLNK(target_stat.st_mode)
    or target_stat.st_uid != os.geteuid()
    or target_stat.st_mode & 0o022
):
    sys.exit(5)

quarantine = root / f".zdx-hf-delete.{secrets.token_hex(16)}"
if quarantine.exists() or quarantine.is_symlink():
    sys.exit(6)
try:
    os.rename(target, quarantine)
    if target.exists() or target.is_symlink():
        raise RuntimeError("original target remained after quarantine")
    if identity(os.lstat(quarantine)) != expected_target_id:
        raise RuntimeError("quarantine identity changed")
    shutil.rmtree(quarantine)
except BaseException as error:
    if os.path.lexists(quarantine):
        print(f"RECOVERY\t{quarantine}", flush=True)
    if isinstance(error, KeyboardInterrupt):
        sys.exit(130)
    sys.exit(9)
print("DELETED")
' "$repo_type" "$repo_id" "$cache_root" "$target_path" \
    "$root_identity" "$target_identity" 2>/dev/null)
  local -i execution_rc=$?
  if (( execution_rc == 0 )) && [[ "$execution_output" == "DELETED" ]]; then
    return 0
  fi
  if [[ "$execution_output" == RECOVERY$'\t'* ]]; then
    local recovery_path="${execution_output#*$'\t'}"
    _hf_error "Cache deletion was incomplete; recovery data was retained."
    _hf_dim "Recovery path: $(_hf_display_escape "$recovery_path")"
  fi
  return 1
}

hf-cache-clear() {
  local repo_type="" repo_id=""
  local -i dry_run=0 assume_yes=0

  while (( $# > 0 )); do
    case "$1" in
      --type)
        shift
        repo_type="${1:-}"
        ;;
      --repo)
        shift
        repo_id="${1:-}"
        ;;
      --dry-run)
        dry_run=1
        ;;
      --yes)
        assume_yes=1
        ;;
      -h|--help)
        (( $# == 1 )) || return 2
        print -u2 -r -- 'Usage:'
        print -u2 -r -- \
          '  hf-cache-clear [--type model|dataset --repo REPOSITORY] [--dry-run] [--yes]'
        print -u2 -r -- \
          'Recursive deletion requires findmnt plus timeout or gtimeout.'
        return 0
        ;;
      *)
        _hf_error \
          "Unknown hf-cache-clear argument: $(_hf_display_escape "$1")"
        return 2
        ;;
    esac
    shift
  done

  if [[ -z "$repo_type" && -z "$repo_id" ]]; then
    _hf_cache_select_repo
    local -i select_rc=$?
    (( select_rc == 130 )) && return 0
    (( select_rc == 0 )) || {
      _hf_error "Could not select a cache entry."
      return 1
    }
    (( ${#reply} == 0 )) && return 0
    (( ${#reply} == 2 )) || return 1
    repo_type="${reply[1]}"
    repo_id="${reply[2]}"
  elif ! _hf_validate_repo_type "$repo_type" \
    || ! _hf_validate_repo_id "$repo_id"; then
    _hf_error "Both --type and --repo must identify one valid cache entry."
    return 2
  fi

  local plan_output=""
  plan_output=$(_hf_cache_plan_data "$repo_type" "$repo_id") || {
    _hf_error "Could not build a safe cache deletion plan."
    return 1
  }
  [[ -n "$plan_output" && ${#plan_output} -le 16384 \
    && "$plan_output" != *$'\n'* ]] || {
    _hf_error "The cache deletion plan was malformed or oversized."
    return 1
  }

  local record_type plan_repo_id plan_repo_type size_bytes
  local cache_root target_path root_identity target_identity extra
  IFS=$'\t' read -r record_type plan_repo_id plan_repo_type size_bytes \
    cache_root target_path root_identity target_identity extra <<< "$plan_output"
  [[ "$record_type" == "PLAN" && -z "$extra" \
    && "$plan_repo_id" == "$repo_id" \
    && "$plan_repo_type" == "$repo_type" ]] || return 1
  _hf_cache_validate_plan "$plan_repo_id" "$plan_repo_type" "$size_bytes" \
    "$cache_root" "$target_path" "$root_identity" "$target_identity" || {
    _hf_error "The cache deletion target failed local boundary validation."
    return 1
  }
  _hf_cache_assert_no_mounts "$target_path" || return 1

  _hf_header "Hugging Face Cache Deletion Plan"
  _hf_label "Repository" "$(_hf_display_escape "$plan_repo_id")"
  _hf_label "Type" "${plan_repo_type:u}"
  _hf_label "Bytes" "$size_bytes"
  _hf_label "Cache Root" "$(_hf_display_escape "$cache_root")"
  _hf_label "Exact Target" "$(_hf_display_escape "$target_path")"

  (( dry_run )) && {
    _hf_success "Dry run complete; no cache data was removed."
    return 0
  }

  if (( ! assume_yes )); then
    [[ -t 0 && -t 2 ]] || {
      _hf_error "Non-interactive cache deletion requires --yes."
      return 1
    }
    _hf_confirm "Delete this exact cached repository?"
    local -i confirm_rc=$?
    (( confirm_rc == 130 )) && {
      _hf_info "Cache deletion cancelled."
      return 0
    }
    (( confirm_rc == 0 )) || {
      _hf_error "Could not obtain deletion confirmation."
      return 1
    }
  fi

  _hf_cache_validate_plan "$plan_repo_id" "$plan_repo_type" "$size_bytes" \
    "$cache_root" "$target_path" "$root_identity" "$target_identity" || {
    _hf_error "The cache target changed after authorization."
    return 1
  }
  _hf_cache_assert_no_mounts "$target_path" || return 1
  _hf_cache_execute_plan "$plan_repo_type" "$plan_repo_id" \
    "$cache_root" "$target_path" "$root_identity" "$target_identity" || {
    _hf_error "Failed to remove the authorized cache entry."
    return 1
  }
  _hf_success "Removed the authorized cache entry."
}

typeset -g _HF_CACHE_SOURCED=1
