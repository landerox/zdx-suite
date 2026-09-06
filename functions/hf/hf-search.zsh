#!/usr/bin/env zsh
# =============================================================================
# Hugging Face Search: bounded Hub search and repository metadata
# =============================================================================
#
# Loaded by hf-menu.zsh after hf-common.zsh and hf-download.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_HF_SEARCH_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# stdout TSV: repo_id, downloads, likes.
_hf_search_data() {
  local repo_type="$1"
  local query="$2"
  local limit="$3"
  _hf_validate_repo_type "$repo_type" \
    && _hf_validate_query "$query" \
    && _hf_validate_limit "$limit" || return 2

  local -a backend=()
  _hf_backend_command || return $?
  backend=("${reply[@]}")

  _hf_run_probe 15 "${backend[@]}" -c '
import re
import sys
from huggingface_hub import HfApi

repo_type, query, limit_text = sys.argv[1:4]
limit = int(limit_text)
api = HfApi()
items = (
    api.list_models(search=query, limit=limit, sort="downloads")
    if repo_type == "model"
    else api.list_datasets(search=query, limit=limit, sort="downloads")
)
valid_id = re.compile(
    r"^[A-Za-z0-9][A-Za-z0-9._-]{0,95}"
    r"(?:/[A-Za-z0-9][A-Za-z0-9._-]{0,95})?$"
)
records = []
repo_ids = set()
for item in items:
    if len(records) >= limit:
        sys.exit(4)
    repo_id = str(getattr(item, "id", ""))
    if not valid_id.fullmatch(repo_id):
        sys.exit(5)
    if repo_id in repo_ids:
        sys.exit(6)
    downloads = getattr(item, "downloads", 0)
    likes = getattr(item, "likes", 0)
    downloads = 0 if downloads is None else downloads
    likes = 0 if likes is None else likes
    if type(downloads) is not int or not 0 <= downloads <= 9_999_999_999_999_999_999:
        sys.exit(7)
    if type(likes) is not int or not 0 <= likes <= 9_999_999_999_999_999_999:
        sys.exit(8)
    repo_ids.add(repo_id)
    records.append(f"{repo_id}\t{downloads}\t{likes}")
for record in records:
    print(record)
' "$repo_type" "$query" "$limit" 2>/dev/null
}

# stdout TSV: fixed metadata key and terminal-safe value.
_hf_repo_stats_data() {
  local repo_type="$1"
  local repo_id="$2"
  _hf_validate_repo_type "$repo_type" \
    && _hf_validate_repo_id "$repo_id" || return 2

  local -a backend=()
  _hf_backend_command || return $?
  backend=("${reply[@]}")

  _hf_run_probe 15 "${backend[@]}" -c '
import sys
from huggingface_hub import HfApi

repo_type, repo_id = sys.argv[1:3]
api = HfApi()
info = (
    api.model_info(repo_id=repo_id)
    if repo_type == "model"
    else api.dataset_info(repo_id=repo_id)
)

def safe(value, limit):
    text = str(value if value is not None else "N/A")
    text = "".join(
        character if ord(character) >= 32 and ord(character) != 127 else "?"
        for character in text
    )
    return text[:limit]

tags = getattr(info, "tags", []) or []
tag_text = ", ".join(safe(tag, 80) for tag in tags[:8])
if len(tags) > 8:
    tag_text += f" (+{len(tags) - 8} more)"

records = (
    ("repository", safe(getattr(info, "id", repo_id), 193)),
    ("type", repo_type.upper()),
    ("author", safe(getattr(info, "author", "N/A"), 193)),
    ("downloads", str(max(0, getattr(info, "downloads", 0) or 0))),
    ("likes", str(max(0, getattr(info, "likes", 0) or 0))),
    ("last_modified", safe(getattr(info, "last_modified", "N/A"), 128)),
    ("gated", "yes" if bool(getattr(info, "gated", False)) else "no"),
    ("sha", safe(getattr(info, "sha", "N/A"), 128)),
    ("tags", tag_text[:1024]),
)
for key, value in records:
    print(f"{key}\t{value}")
' "$repo_type" "$repo_id" 2>/dev/null
}

_hf_render_repo_stats() {
  local repo_type="$1"
  local repo_id="$2"
  _hf_info "Fetching detailed stats for $repo_type '$(_hf_display_escape "$repo_id")'..."

  local stats_output=""
  stats_output=$(_hf_repo_stats_data "$repo_type" "$repo_id") || {
    _hf_error "Could not fetch repository statistics."
    return 1
  }
  [[ -n "$stats_output" && ${#stats_output} -le 8192 ]] || {
    _hf_error "The repository statistics response was empty or oversized."
    return 1
  }

  local -A values=()
  local line key value
  local -a lines=("${(@f)stats_output}")
  (( ${#lines} <= 16 )) || return 1
  for line in "${lines[@]}"; do
    IFS=$'\t' read -r key value <<< "$line"
    case "$key" in
      repository|type|author|downloads|likes|last_modified|gated|sha|tags)
        [[ -z "${values[$key]+present}" ]] || return 1
        values[$key]="$value"
        ;;
      *) return 1 ;;
    esac
  done
  for key in repository type author downloads likes last_modified gated sha tags; do
    [[ -n "${values[$key]+present}" ]] || return 1
  done

  _hf_header "Hugging Face Repository"
  _hf_label "Repository" "$(_hf_display_escape "${values[repository]}")"
  _hf_label "Type" "$(_hf_display_escape "${values[type]}")"
  _hf_label "Author" "$(_hf_display_escape "${values[author]}")"
  _hf_label "Downloads" "${values[downloads]}"
  _hf_label "Likes" "${values[likes]}"
  _hf_label "Last Modified" "$(_hf_display_escape "${values[last_modified]}")"
  _hf_label "Gated" "${values[gated]}"
  _hf_label "Commit SHA" "$(_hf_display_escape "${values[sha]}")"
  [[ -n "${values[tags]}" ]] \
    && _hf_label "Tags" "$(_hf_display_escape "${values[tags]}")"
  [[ "${values[gated]}" == "yes" ]] \
    && _hf_warn "This repository requires accepted terms and an authorized HF_TOKEN."
  return 0
}

_hf_search_browse() {
  local repo_type="$1"
  local query="$2"
  local limit="$3"
  command -v fzf &>/dev/null || {
    _hf_error "Browsing search results interactively requires fzf."
    return 1
  }

  _hf_info "Searching Hugging Face Hub for '$(_hf_display_escape "$query")'..."
  local search_output=""
  search_output=$(_hf_search_data "$repo_type" "$query" "$limit") || {
    _hf_error "The Hub search failed."
    return 1
  }
  [[ -n "$search_output" && ${#search_output} -le 65536 ]] || {
    _hf_warn "The Hub search returned no bounded results."
    return 0
  }

  local -a repo_ids=() rows=()
  local line repo_id downloads likes extra
  local -i index=0
  for line in "${(@f)search_output}"; do
    IFS=$'\t' read -r repo_id downloads likes extra <<< "$line"
    _hf_validate_repo_id "$repo_id" \
      && _hf_validate_uint "$downloads" 19 \
      && _hf_validate_uint "$likes" 19 \
      && [[ -z "$extra" ]] \
      || return 1
    repo_ids+=("$repo_id")
    (( index++ ))
    rows+=("$repo_id (downloads: $downloads, likes: $likes)"$'\t'"$index")
  done
  (( ${#rows} > 0 && ${#rows} <= limit )) || return 1

  local -i fzf_rc=0
  _hf_fzf_capture \
    --height=50% \
    --delimiter=$'\t' \
    --with-nth=1 \
    --prompt='hf search > ' \
    --header='Up/Down navigate | Enter inspect | Esc cancel' \
    < <(printf "%s\n" "${rows[@]}") || fzf_rc=$?
  local selected="$REPLY"
  if (( fzf_rc != 0 )); then
    _hf_fzf_rc_is_cancel "$fzf_rc" && return 0
    _hf_error "Unable to browse Hub results (status $fzf_rc)."
    return 1
  fi
  [[ -z "$selected" ]] && return 0
  _hf_array_contains_literal "$selected" "${rows[@]}" || return 1
  index="${selected##*$'\t'}"
  [[ "$index" == <-> && index -ge 1 && index -le ${#repo_ids} ]] || return 1
  repo_id="${repo_ids[index]}"

  local -a actions=(
    "View repository statistics"$'\t'"stats"
    "Download repository snapshot"$'\t'"snapshot"
    "Download one repository file"$'\t'"file"
  )
  fzf_rc=0
  _hf_fzf_capture \
    --height=30% \
    --delimiter=$'\t' \
    --with-nth=1 \
    --prompt='hf action > ' \
    --header='Up/Down choose | Enter run | Esc cancel' \
    < <(printf "%s\n" "${actions[@]}") || fzf_rc=$?
  selected="$REPLY"
  if (( fzf_rc != 0 )); then
    _hf_fzf_rc_is_cancel "$fzf_rc" && return 0
    return 1
  fi
  [[ -z "$selected" ]] && return 0
  _hf_array_contains_literal "$selected" "${actions[@]}" || return 1

  case "${selected##*$'\t'}" in
    stats)    _hf_render_repo_stats "$repo_type" "$repo_id" ;;
    snapshot) _hf_download_snapshot "$repo_id" "$repo_type" ;;
    file)     _hf_download_file_interactive "$repo_id" "$repo_type" ;;
    *)        return 1 ;;
  esac
}

_hf_search_interactive() {
  _hf_pick_repo_type "hf search type"
  local -i selection_rc=$?
  (( selection_rc == 130 )) && return 0
  (( selection_rc == 0 )) || return 1
  local repo_type="$REPLY"
  _hf_prompt "Search query" ""
  local -i prompt_rc=$?
  (( prompt_rc == 130 )) && return 0
  (( prompt_rc == 0 )) || return 1
  local query="$REPLY"
  _hf_validate_query "$query" || {
    _hf_error "Search query must be 1-256 characters without controls."
    return 1
  }
  _hf_search_browse "$repo_type" "$query" 15
}

_hf_repo_stats_interactive() {
  _hf_prompt "Repository ID" ""
  local -i prompt_rc=$?
  (( prompt_rc == 130 )) && return 0
  (( prompt_rc == 0 )) || return 1
  local repo_id="$REPLY"
  _hf_validate_repo_id "$repo_id" || {
    _hf_error "Invalid Hugging Face repository ID."
    return 1
  }
  _hf_pick_repo_type "hf repository type"
  local -i selection_rc=$?
  (( selection_rc == 130 )) && return 0
  (( selection_rc == 0 )) || return 1
  _hf_render_repo_stats "$REPLY" "$repo_id"
}

hf-search() {
  local repo_type="" query="" limit="15"
  local -i list_only=0

  if (( $# == 0 )); then
    _hf_search_interactive
    local -i interactive_rc=$?
    return $interactive_rc
  fi
  while (( $# > 0 )); do
    case "$1" in
      --type)
        shift
        repo_type="${1:-}"
        ;;
      --query)
        shift
        query="${1:-}"
        ;;
      --limit)
        shift
        limit="${1:-}"
        ;;
      --list)
        list_only=1
        ;;
      -h|--help)
        (( $# == 1 )) || return 2
        print -u2 -r -- \
          'Usage: hf-search --type model|dataset --query TEXT [--limit N] [--list]'
        return 0
        ;;
      *)
        _hf_error "Unknown hf-search argument: $(_hf_display_escape "$1")"
        return 2
        ;;
    esac
    shift
  done
  _hf_validate_repo_type "$repo_type" \
    && _hf_validate_query "$query" \
    && _hf_validate_limit "$limit" || {
    _hf_error "hf-search requires a valid --type, --query, and --limit (1-100)."
    return 2
  }
  if (( list_only )); then
    _hf_search_data "$repo_type" "$query" "$limit"
  else
    _hf_search_browse "$repo_type" "$query" "$limit"
    local -i browse_rc=$?
    return $browse_rc
  fi
}

hf-repo-stats() {
  local repo_type="" repo_id=""
  if (( $# == 0 )); then
    _hf_repo_stats_interactive
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
      -h|--help)
        (( $# == 1 )) || return 2
        print -u2 -r -- \
          'Usage: hf-repo-stats --type model|dataset --repo REPOSITORY'
        return 0
        ;;
      *)
        _hf_error \
          "Unknown hf-repo-stats argument: $(_hf_display_escape "$1")"
        return 2
        ;;
    esac
    shift
  done
  _hf_validate_repo_type "$repo_type" \
    && _hf_validate_repo_id "$repo_id" || {
    _hf_error "hf-repo-stats requires a valid --type and --repo."
    return 2
  }
  _hf_render_repo_stats "$repo_type" "$repo_id"
}

typeset -g _HF_SEARCH_SOURCED=1
