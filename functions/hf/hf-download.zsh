#!/usr/bin/env zsh
# =============================================================================
# Hugging Face Download: validated snapshot and individual-file downloads
# =============================================================================
#
# Loaded by hf-menu.zsh after hf-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_HF_DOWNLOAD_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# One download owner for direct commands and follow-up actions from search.
# Vendor output stays hidden; only fixed progress and classified results cross
# the UI boundary. Existing Hub cache entries are left available for retries.
_hf_download_run() {
  local repo_id="$1" repo_type="$2" mode="$3" filename="${4:-}"
  _hf_validate_repo_id "$repo_id" && _hf_validate_repo_type "$repo_type" || return 2
  case "$mode" in
    snapshot) [[ -z "$filename" ]] || return 2 ;;
    file) _hf_validate_filename "$filename" || return 2 ;;
    *) return 2 ;;
  esac

  local -a backend=()
  _hf_backend_command || return $?
  backend=("${reply[@]}")
  _hf_info "Starting $mode download for $(_hf_display_escape "$repo_id")..."
  local download_output=""
  local -i download_rc=0
  download_output=$("${backend[@]}" -c '
import errno
import os
import sys
import threading
from pathlib import Path

repo_id, repo_type, mode, filename = sys.argv[1:5]
# Keep bounded result records separate from library stdout and stderr. FD 3
# receives only fixed ZDX progress, never exception text or remote filenames.
result_stream = os.fdopen(os.dup(1), "w", buffering=1)
progress_stream = os.fdopen(os.dup(3), "w", buffering=1)
os.close(3)
with open(os.devnull, "w") as hidden:
    os.dup2(hidden.fileno(), 1)
finished = threading.Event()

def report_wait():
    while not finished.wait(5):
        try:
            progress_stream.write("  Download is still running; Ctrl-C interrupts.\n")
        except OSError:
            return

worker = threading.Thread(target=report_wait, daemon=True)
worker.start()
try:
    from huggingface_hub import hf_hub_download, snapshot_download
    if mode == "snapshot":
        cache_path = snapshot_download(repo_id=repo_id, repo_type=repo_type)
    else:
        cache_path = hf_hub_download(
            repo_id=repo_id, repo_type=repo_type, filename=filename,
        )
    if (
        not isinstance(cache_path, str)
        or not cache_path.startswith("/")
        or len(cache_path) > 4096
        or any(ord(char) < 32 or ord(char) == 127 for char in cache_path)
    ):
        raise ValueError("invalid result path")
    target = Path(cache_path)
    if not (target.is_dir() if mode == "snapshot" else target.is_file()):
        raise ValueError("missing result")
    result_stream.write(f"OK\t{cache_path}\n")
except KeyboardInterrupt:
    sys.exit(130)
except Exception as error:
    classes = {kind.__name__ for kind in type(error).__mro__}
    response = getattr(error, "response", None)
    status_code = getattr(response, "status_code", None)
    if "GatedRepoError" in classes or status_code in (401, 403):
        reason = "access"
    elif classes & {"ConnectionError", "ConnectError", "Timeout", "TimeoutError", "TimeoutException", "OfflineModeIsEnabled", "LocalEntryNotFoundError"}:
        reason = "network"
    elif classes & {"RepositoryNotFoundError", "EntryNotFoundError", "RevisionNotFoundError"}:
        reason = "not-found"
    elif isinstance(error, OSError) and error.errno in (errno.ENOSPC, errno.EDQUOT, errno.EACCES, errno.EROFS):
        reason = "storage"
    else:
        reason = "backend"
    result_stream.write(f"ERROR\t{reason}\n")
    sys.exit(1)
finally:
    finished.set()
    worker.join(timeout=1)
    if not worker.is_alive():
        progress_stream.close()
    result_stream.close()
' "$repo_id" "$repo_type" "$mode" "$filename" 3>&2 2>/dev/null) || download_rc=$?

  if (( download_rc == 130 || download_rc == 143 )); then
    _hf_warn "Download interrupted; existing cached files were retained."
    _hf_download_retry "$repo_id" "$repo_type" "$mode" "$filename"
    return $download_rc
  fi
  local download_path="${download_output#OK$'\t'}"
  if (( download_rc == 0 )) && [[ "$download_output" == OK$'\t'* \
    && "$download_path" == /* && ${#download_path} -le 4096 \
    && "$download_path" != *[[:cntrl:]]* && -r "$download_path" ]] \
    && { [[ "$mode" == snapshot && -d "$download_path" && -x "$download_path" ]] \
      || [[ "$mode" == file && -f "$download_path" ]]; }; then
    _hf_success "Download completed."
    _hf_dim "Cached at: $(_hf_display_escape "$download_path")"
    return 0
  fi
  case "$download_output" in
    ERROR$'\t'access)
      _hf_error "Hub access was denied; check authorization and repository terms." ;;
    ERROR$'\t'not-found)
      _hf_error "The repository or file was not found, or is not visible to this account." ;;
    ERROR$'\t'network)
      _hf_error "The Hub connection failed or the requested content is unavailable offline." ;;
    ERROR$'\t'storage)
      _hf_error "The cache could not be written; check free space and access permissions." ;;
    *) _hf_error "The download failed or returned an unusable cache path." ;;
  esac
  _hf_download_retry "$repo_id" "$repo_type" "$mode" "$filename"
  return 1
}

_hf_download_retry() {
  local -a retry=(hf-download --type "$2" --repo "$1")
  if [[ "$3" == snapshot ]]; then
    retry+=(--snapshot)
  else
    retry+=(--file "$4")
  fi
  _hf_dim "Retry: ${(j: :)${(@q)retry}}"
  _hf_dim "ZDX keeps cached files; the installed Hub backend decides what can be reused."
}

_hf_download_snapshot() {
  _hf_download_run "$1" "$2" snapshot
}

_hf_download_file() {
  _hf_download_run "$1" "$2" file "$3"
}

_hf_download_file_interactive() {
  local repo_id="$1"
  local repo_type="$2"
  _hf_validate_repo_id "$repo_id" \
    && _hf_validate_repo_type "$repo_type" || return 2
  command -v fzf &>/dev/null || {
    _hf_error "Selecting a repository file interactively requires fzf."
    return 1
  }

  local -a backend=()
  _hf_backend_command || return $?
  backend=("${reply[@]}")

  _hf_info "Fetching a bounded file list for $(_hf_display_escape "$repo_id")..."
  local files_output=""
  files_output=$(_hf_run_probe 15 "${backend[@]}" -c '
import sys
from huggingface_hub import HfApi
from huggingface_hub.hf_api import RepoFile, RepoFolder

repo_id, repo_type = sys.argv[1:3]
tree = HfApi().list_repo_tree(
    repo_id=repo_id,
    repo_type=repo_type,
    recursive=True,
    expand=False,
)
files = []
records_seen = 0
for entry in tree:
    records_seen += 1
    if records_seen > 4096:
        sys.exit(4)
    if isinstance(entry, RepoFolder):
        continue
    if not isinstance(entry, RepoFile):
        sys.exit(5)
    filename = getattr(entry, "path", None)
    if (
        not isinstance(filename, str)
        or not filename
        or len(filename) > 1024
        or filename.startswith("/")
        or any(ord(character) < 32 or ord(character) == 127 for character in filename)
        or any(component in ("", ".", "..") for component in filename.split("/"))
    ):
        sys.exit(6)
    files.append(filename)
    if len(files) > 2000:
        sys.exit(7)
for filename in files:
    print(filename)
' "$repo_id" "$repo_type" 2>/dev/null) || {
    local -i list_rc=$?
    (( list_rc != 130 && list_rc != 143 )) || return $list_rc
    _hf_error \
      "Could not obtain a safe file list (maximum 2,000 files and 4,096 tree records)."
    return 1
  }
  [[ -n "$files_output" ]] \
    && (( ${#files_output} <= 2 * 1024 * 1024 )) || {
    _hf_error "The repository file list was empty or oversized."
    return 1
  }

  local -a filenames=("${(@f)files_output}")
  local -a rows=()
  local -i index=0
  local filename=""
  for filename in "${filenames[@]}"; do
    _hf_validate_filename "$filename" || return 1
    (( index++ ))
    rows+=("$(_hf_display_escape "$filename")"$'\t'"$index")
  done

  local -i fzf_rc=0
  _hf_fzf_capture \
    --height=50% \
    --delimiter=$'\t' \
    --with-nth=1 \
    --prompt='hf files > ' \
    --header='Up/Down navigate | Enter download | Esc cancel' \
    < <(printf "%s\n" "${rows[@]}") || fzf_rc=$?
  local selected="$REPLY"
  if (( fzf_rc != 0 )); then
    _hf_fzf_rc_is_cancel "$fzf_rc" && return 0
    _hf_error "Unable to select a repository file (status $fzf_rc)."
    return 1
  fi
  [[ -z "$selected" ]] && return 0
  _hf_array_contains_literal "$selected" "${rows[@]}" || {
    _hf_error "The selected file was not in the current snapshot."
    return 1
  }
  index="${selected##*$'\t'}"
  [[ "$index" == <-> && index -ge 1 && index -le ${#filenames} ]] || return 1
  filename="${filenames[index]}"

  _hf_download_file "$repo_id" "$repo_type" "$filename"
}

_hf_download_interactive() {
  _hf_prompt "Repository ID" ""
  local -i prompt_rc=$?
  (( prompt_rc == 130 )) && return 0
  (( prompt_rc == 0 )) || return 1
  local repo_id="$REPLY"
  _hf_validate_repo_id "$repo_id" || {
    _hf_error "Invalid Hugging Face repository ID."
    return 1
  }

  _hf_pick_repo_type "hf download type"
  local -i selection_rc=$?
  (( selection_rc == 130 )) && return 0
  (( selection_rc == 0 )) || return 1
  local repo_type="$REPLY"
  command -v fzf &>/dev/null || {
    _hf_error "Selecting a download mode interactively requires fzf."
    return 1
  }

  local -a modes=(
    "Whole repository snapshot"$'\t'"snapshot"
    "One repository file"$'\t'"file"
  )
  local -i fzf_rc=0
  _hf_fzf_capture \
    --height=20% \
    --delimiter=$'\t' \
    --with-nth=1 \
    --prompt='hf download > ' \
    --header='Up/Down choose | Enter download | Esc cancel' \
    < <(printf "%s\n" "${modes[@]}") || fzf_rc=$?
  local selected="$REPLY"

  if (( fzf_rc != 0 )); then
    _hf_fzf_rc_is_cancel "$fzf_rc" && return 0
    _hf_error "Unable to select a download mode (status $fzf_rc)."
    return 1
  fi
  [[ -z "$selected" ]] && return 0
  _hf_array_contains_literal "$selected" "${modes[@]}" || return 1

  case "${selected##*$'\t'}" in
    snapshot) _hf_download_snapshot "$repo_id" "$repo_type" ;;
    file)     _hf_download_file_interactive "$repo_id" "$repo_type" ;;
    *)        return 1 ;;
  esac
}

hf-download() {
  local repo_type="" repo_id="" filename=""
  local mode=""

  if (( $# == 0 )); then
    _hf_download_interactive
    local -i interactive_rc=$?
    return $interactive_rc
  fi
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
      --snapshot)
        [[ -z "$mode" ]] || {
          _hf_error "Choose exactly one download mode."
          return 2
        }
        mode="snapshot"
        ;;
      --file)
        shift
        [[ -z "$mode" ]] || {
          _hf_error "Choose exactly one download mode."
          return 2
        }
        mode="file"
        filename="${1:-}"
        ;;
      -h|--help)
        (( $# == 1 )) || return 2
        print -u2 -r -- 'Usage:'
        print -u2 -r -- \
          '  hf-download --type model|dataset --repo REPOSITORY --snapshot'
        print -u2 -r -- \
          '  hf-download --type model|dataset --repo REPOSITORY --file FILENAME'
        return 0
        ;;
      *)
        _hf_error "Unknown hf-download argument: $(_hf_display_escape "$1")"
        return 2
        ;;
    esac
    shift
  done

  _hf_validate_repo_type "$repo_type" \
    && _hf_validate_repo_id "$repo_id" || {
    _hf_error "hf-download requires a valid --type and --repo."
    return 2
  }
  [[ -n "$mode" ]] || {
    _hf_error "Direct downloads require either --snapshot or --file."
    return 2
  }
  case "$mode" in
    snapshot)
      [[ -z "$filename" ]] || return 2
      _hf_download_snapshot "$repo_id" "$repo_type"
      ;;
    file)
      _hf_validate_filename "$filename" || {
        _hf_error "--file requires a safe repository-relative filename."
        return 2
      }
      _hf_download_file "$repo_id" "$repo_type" "$filename"
      ;;
  esac
}

typeset -g _HF_DOWNLOAD_SOURCED=1
