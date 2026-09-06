#!/usr/bin/env zsh
# =============================================================================
# Dev Clean: planned, confirmable removal of project build and cache artifacts
# =============================================================================
#
# Loaded by dev-menu.zsh after dev-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_DEV_CLEAN_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# Recursive scans are bounded. An unbounded descent through a deeply nested or
# symlink-heavy tree turns a cleanup into an unpredictable operation.
typeset -g DEV_CLEAN_DEPTH="${DEV_CLEAN_DEPTH-12}"

# Cleanup inventories and the final combined plan are bounded independently
# from traversal depth. The value remains a string until strict validation so
# configuration content is never evaluated as an arithmetic expression.
typeset -g DEV_CLEAN_MAX_TARGETS="${DEV_CLEAN_MAX_TARGETS-10000}"

# Number of plan entries shown before the preview is summarized.
typeset -gi _DEV_CLEAN_PREVIEW_LIMIT=25

# Set only by dev-clean-py and dev-clean-all from their --keep-build flag.
typeset -gi _DEV_CLEAN_KEEP_BUILD=0

_dev_validate_clean_depth() {
  _dev_validate_bounded_integer DEV_CLEAN_DEPTH "$DEV_CLEAN_DEPTH" 1 64
}

_dev_validate_clean_limit() {
  _dev_validate_bounded_integer \
    DEV_CLEAN_MAX_TARGETS "$DEV_CLEAN_MAX_TARGETS" 1 50000
}

# --- Stable filesystem identities ------------------------------------------

# Sets `reply` to device, inode, and object type using lstat semantics. The
# Zsh stat module avoids GNU/BSD `stat` flag differences.
_dev_clean_lstat() {
  local target="$1"
  reply=()

  zmodload zsh/stat 2>/dev/null || {
    _dev_error "The Zsh stat module is required for safe cleanup."
    return 1
  }

  local -A stat_info=()
  zstat -L -H stat_info -- "$target" 2>/dev/null || return 1

  local object_type=""
  local -i type_bits=$(( stat_info[mode] & 8#170000 ))
  if (( type_bits == 8#40000 )); then
    object_type="directory"
  elif (( type_bits == 8#100000 )); then
    object_type="file"
  elif (( type_bits == 8#120000 )); then
    object_type="symlink"
  else
    object_type="other"
  fi

  reply=(
    "${stat_info[device]}"
    "${stat_info[inode]}"
    "$object_type"
  )
}

# Captures one immutable cleanup-root snapshot:
#   real-path, device, inode, type
# The literal final path component may not be a symlink. Ancestor links are
# resolved once; all planned removals are subsequently anchored to the open
# working directory rather than recanonicalized through the pathname.
_dev_clean_capture_root() {
  reply=()

  local literal_root="${PWD:a}"
  [[ ! -L "$literal_root" ]] || {
    _dev_error "Refusing a symlinked cleanup root."
    return 1
  }

  _dev_scan_root >/dev/null || return 1
  local real_root="${PWD:A}"

  local -a root_identity=()
  _dev_clean_lstat "$real_root" || {
    _dev_error "Unable to inspect the cleanup root."
    return 1
  }
  root_identity=("${reply[@]}")
  [[ "${root_identity[3]}" == "directory" ]] || {
    _dev_error "The cleanup root is not a real directory."
    return 1
  }

  local -a cwd_identity=()
  _dev_clean_lstat . || {
    _dev_error "Unable to inspect the current working directory."
    return 1
  }
  cwd_identity=("${reply[@]}")
  [[ "${cwd_identity[1]}" == "${root_identity[1]}" \
    && "${cwd_identity[2]}" == "${root_identity[2]}" \
    && "${cwd_identity[3]}" == "${root_identity[3]}" ]] || {
    _dev_error "The cleanup root changed while it was being resolved."
    return 1
  }

  reply=("$real_root" "${root_identity[@]}")
}

# Revalidates both the open working-directory anchor and its original absolute
# pathname without following a replacement final symlink.
_dev_clean_revalidate_root() {
  local root="$1"
  local expected_device="$2"
  local expected_inode="$3"
  local expected_type="$4"

  local -a current=()
  _dev_clean_lstat . || {
    _dev_error "The cleanup root anchor is no longer inspectable."
    return 1
  }
  current=("${reply[@]}")
  [[ "${current[1]}" == "$expected_device" \
    && "${current[2]}" == "$expected_inode" \
    && "${current[3]}" == "$expected_type" ]] || {
    _dev_error "The cleanup root anchor changed after planning."
    return 1
  }

  _dev_clean_lstat "$root" || {
    _dev_error "The cleanup root pathname changed after planning."
    return 1
  }
  current=("${reply[@]}")
  [[ "${current[1]}" == "$expected_device" \
    && "${current[2]}" == "$expected_inode" \
    && "${current[3]}" == "$expected_type" ]] || {
    _dev_error \
      "The cleanup root pathname was replaced after planning."
    return 1
  }
  return 0
}

# Converts an absolute discovered target into a literal path relative to the
# frozen root. No symlink or canonical-path resolution occurs here.
_dev_clean_relative_is_safe() {
  local relative="$1"
  [[ -n "$relative" && "$relative" != /* \
    && "$relative" != "." && "$relative" != "./"* \
    && "$relative" != */./* && "$relative" != */. \
    && "$relative" != ".." && "$relative" != ../* \
    && "$relative" != */../* && "$relative" != */.. ]]
}

_dev_clean_relative_target() {
  local root="$1"
  local candidate="$2"
  local prefix="${root}/"
  REPLY=""

  [[ "$candidate" == "${prefix}"* ]] || return 1
  local relative="${candidate#"$prefix"}"
  _dev_clean_relative_is_safe "$relative" || return 1
  REPLY="$relative"
}

# --- Target discovery -------------------------------------------------------

# Escapes a literal pathname for find's -path pattern language.
_dev_clean_find_path_pattern() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\*/\\*}"
  value="${value//\?/\\?}"
  value="${value//\[/\\[}"
  REPLY="$value"
}

# Copies at most `limit` NUL-delimited records from stdin to stdout. Returning
# as soon as record limit+1 is observed also terminates the producer through
# its pipe instead of first materializing an unbounded command substitution.
_dev_clean_limit_nul_stream() {
  local label="$1"
  local -i limit="$2"
  local candidate
  local -i count=0

  while IFS= read -r -d '' candidate; do
    count=$(( count + 1 ))
    if (( count > limit )); then
      _dev_error "$label exceeds the safe limit of $limit entries."
      return 1
    fi
    print -rn -- "$candidate"$'\0'
  done
  return 0
}

# Sets `reply` to nested repository roots discovered from .git markers.
# Generated dependency and vendored trees are pruned before marker discovery.
_dev_clean_repository_roots() {
  local root="$1"
  local depth="$2"
  reply=()

  _dev_validate_clean_limit || return 1
  local -i limit=$(( 10#$DEV_CLEAN_MAX_TARGETS ))
  # A repository root at the target scan boundary has its .git marker one
  # level deeper. Inspect exactly that extra level so the boundary itself
  # cannot be selected as a cleanup artifact.
  local -i marker_depth=$(( depth + 1 ))
  local markers=""
  markers=$(
    command find "$root" -mindepth 1 -maxdepth "$marker_depth" \
      \( -name '.git' -print0 -prune \) -o \
      \( -type d \( \
        -name '.venv' -o -name 'node_modules' \
        -o -name 'vendor' -o -name 'vendored' \
        -o -name '*.git' \
      \) -prune \) 2>/dev/null \
      | _dev_clean_limit_nul_stream \
        "Nested repository marker inventory" "$limit"
    local -a pipeline_status=("${pipestatus[@]}")
    (( pipeline_status[1] == 0 && pipeline_status[2] == 0 ))
  ) || {
    _dev_error "Unable to discover nested repository boundaries."
    return 1
  }

  local -a marker_paths=(${(0)markers})
  local -A seen=()
  local marker repository_root
  for marker in "${marker_paths[@]}"; do
    [[ -n "$marker" ]] || continue
    repository_root="${marker:h}"
    [[ "$repository_root" != "$root" ]] || continue
    _dev_clean_relative_target "$root" "$repository_root" || continue

    (( ${+seen[$repository_root]} )) && continue
    seen[$repository_root]=1
    reply+=("$repository_root")
  done
  return 0
}

# Emits NUL-delimited absolute paths so filenames containing newlines, spaces,
# or leading dashes survive as data. Generated, vendored, Git metadata, and
# nested-repository trees are never traversed.
_dev_clean_find() {
  local root="$1"
  local node_type="$2"
  local depth="$3"
  shift 3

  local -a name_expression=()
  local pattern
  for pattern in "$@"; do
    (( ${#name_expression[@]} > 0 )) && name_expression+=(-o)
    name_expression+=(-name "$pattern")
  done
  (( ${#name_expression[@]} > 0 )) || return 0

  local -a repository_roots=()
  if (( ${+parameters[_dev_clean_pruned_repositories]} )); then
    repository_roots=("${_dev_clean_pruned_repositories[@]}")
  else
    local -a reply=()
    _dev_clean_repository_roots "$root" "$depth" || return 1
    repository_roots=("${reply[@]}")
  fi

  local -a exclusions=(
    \( -type d \( \
      -name '.git' -o -name '*.git' \
      -o -name '.venv' -o -name 'node_modules' \
      -o -name 'vendor' -o -name 'vendored' \
    \) -prune \) -o
  )
  local repository_root
  for repository_root in "${repository_roots[@]}"; do
    _dev_clean_find_path_pattern "$repository_root"
    exclusions+=(\( -path "$REPLY" -prune \) -o)
  done

  _dev_validate_clean_limit || return 1
  local -i limit=$(( 10#$DEV_CLEAN_MAX_TARGETS ))
  command find "$root" -mindepth 1 -maxdepth "$depth" \
    "${exclusions[@]}" \
    -type "$node_type" \( "${name_expression[@]}" \) -print0 \
    2>/dev/null \
    | _dev_clean_limit_nul_stream "Cleanup discovery" "$limit"
  local -a pipeline_status=("${pipestatus[@]}")
  if (( pipeline_status[1] != 0 || pipeline_status[2] != 0 )); then
    return 1
  fi
  return 0
}

# Sets `reply` to every path matching one cleanup category. The category name
# is validated here so a caller cannot introduce an unplanned pattern set.
_dev_clean_collect() {
  local root="$1"
  local category="$2"
  reply=()

  _dev_validate_clean_depth || return 1
  _dev_validate_clean_limit || return 1
  local -i depth=$(( 10#$DEV_CLEAN_DEPTH ))
  local -i limit=$(( 10#$DEV_CLEAN_MAX_TARGETS ))

  local directories="" files=""

  case "$category" in
    py)
      directories=$(_dev_clean_find "$root" d "$depth" \
        '__pycache__' '.pytest_cache' '.mypy_cache' '.ruff_cache' \
        '*.egg-info') || {
        _dev_error "Python directory discovery failed."
        return 1
      }
      files=$(_dev_clean_find "$root" f "$depth" '*.pyc' '*.pyo') || {
        _dev_error "Python file discovery failed."
        return 1
      }

      # Coverage output is only selected at the project root. A nested
      # directory with the same name may belong to a fixture or vendored tree.
      local coverage_dirs="" coverage_files=""
      coverage_dirs=$(_dev_clean_find "$root" d 1 'htmlcov') || {
        _dev_error "Coverage directory discovery failed."
        return 1
      }
      coverage_files=$(_dev_clean_find "$root" f 1 \
        '.coverage' '.coverage.*') || {
        _dev_error "Coverage data discovery failed."
        return 1
      }
      directories="${directories}${coverage_dirs}"
      files="${files}${coverage_files}"

      # build/ and dist/ are only removed at the project root. Nested
      # directories with those names usually belong to vendored sources.
      if (( ! _DEV_CLEAN_KEEP_BUILD )); then
        local build_dirs=""
        build_dirs=$(_dev_clean_find "$root" d 1 'build' 'dist') || {
          _dev_error "Root build-artifact discovery failed."
          return 1
        }
        directories="${directories}${build_dirs}"
      fi
      ;;
    repo)
      files=$(_dev_clean_find "$root" f "$depth" \
        '*:Zone.Identifier' '.DS_Store' '._*' 'Thumbs.db' 'desktop.ini') || {
        _dev_error "Repository-junk discovery failed."
        return 1
      }
      ;;
    terraform)
      directories=$(_dev_clean_find "$root" d "$depth" '.terraform') || {
        _dev_error "Terraform directory discovery failed."
        return 1
      }
      # .terraform.lock.hcl is deliberately preserved: it pins provider
      # versions and belongs in version control.
      files=$(_dev_clean_find "$root" f "$depth" \
        '*.tfplan' 'crash.log' 'crash.*.log' '*.tfstate.backup') || {
        _dev_error "Terraform file discovery failed."
        return 1
      }
      ;;
    rust)
      if (( ! _DEV_CLEAN_KEEP_BUILD )); then
        directories=$(_dev_clean_find "$root" d 1 'target') || {
          _dev_error "Cargo build-artifact discovery failed."
          return 1
        }
      fi
      ;;
    *)
      _dev_error "Unknown cleanup category: $category"
      return 2
      ;;
  esac

  local -a collected=(${(0)directories} ${(0)files})
  if (( ${#collected[@]} > limit )); then
    _dev_error \
      "Cleanup category inventory exceeds the safe limit of $limit entries."
    return 1
  fi

  local candidate
  for candidate in "${collected[@]}"; do
    [[ -n "$candidate" ]] || continue
    # Scope is a literal prefix proof. Recanonicalizing here could resolve a
    # replacement root and turn an old plan into a different target set.
    _dev_clean_relative_target "$root" "$candidate" || {
      _dev_warn "Skipping out-of-scope target: $candidate"
      continue
    }
    reply+=("$candidate")
  done

  return 0
}

_dev_clean_category_label() {
  case "$1" in
    py)        print -r -- "Python caches and build artifacts" ;;
    repo)      print -r -- "OS and editor junk files" ;;
    terraform) print -r -- "Terraform caches, plans, and state backups" ;;
    rust)      print -r -- "Cargo build artifacts" ;;
    *)         print -r -- "$1" ;;
  esac
}

# --- Plan presentation ------------------------------------------------------

# Converts discovered absolute paths into immutable interleaved records:
#   relative-path, device, inode, type
# Relative paths keep every mutation anchored to the original open working
# directory even if its pathname is renamed after confirmation.
_dev_clean_build_plan() {
  local root="$1"
  shift
  local -a candidates=("$@")
  reply=()
  local -a plan=()
  local -A seen=()

  _dev_validate_clean_limit || return 1
  local -i limit=$(( 10#$DEV_CLEAN_MAX_TARGETS ))

  local candidate relative
  local -a identity=()
  for candidate in "${candidates[@]}"; do
    _dev_clean_relative_target "$root" "$candidate" || {
      _dev_error "Refusing an out-of-scope cleanup target."
      return 1
    }
    relative="$REPLY"

    (( ${+seen[$relative]} )) && continue
    seen[$relative]=1
    if (( ${#seen} > limit )); then
      _dev_error \
        "Combined cleanup plan exceeds the safe limit of $limit targets."
      reply=()
      return 1
    fi

    if [[ ! -e "$relative" && ! -L "$relative" ]]; then
      _dev_dim \
        "Skipping target that disappeared before planning: $(_dev_display_escape "$relative")"
      continue
    fi

    _dev_clean_lstat "$relative" || {
      _dev_error \
        "Unable to inspect target: $(_dev_display_escape "$relative")"
      return 1
    }
    identity=("${reply[@]}")
    [[ "${identity[3]}" == (directory|file) ]] || {
      _dev_error \
        "Target changed to an unsafe type: $(_dev_display_escape "$relative")"
      return 1
    }
    plan+=("$relative" "${identity[@]}")
  done
  reply=("${plan[@]}")
  return 0
}

_dev_clean_show_plan() {
  local root="$1"
  shift
  (( $# % 4 == 0 )) || {
    _dev_error "Internal cleanup plan is malformed."
    return 1
  }
  local -a records=("$@")
  local -i target_count=$(( ${#records[@]} / 4 ))

  _dev_info "Removal plan ($target_count target(s)) under $root:"

  local -i shown=0
  local relative device inode object_type
  while (( ${#records[@]} > 0 )); do
    relative="${records[1]}"
    device="${records[2]}"
    inode="${records[3]}"
    object_type="${records[4]}"
    records=("${records[@]:4}")

    if (( shown >= _DEV_CLEAN_PREVIEW_LIMIT )); then
      _dev_dim "... and $(( target_count - shown )) more."
      break
    fi
    if [[ "$object_type" == "directory" ]]; then
      _dev_dim "dir   $(_dev_display_escape "$relative")"
    else
      _dev_dim "file  $(_dev_display_escape "$relative")"
    fi
    shown=$(( shown + 1 ))
  done
}

# --- Plan execution --------------------------------------------------------

# Returns non-zero when any target could not be removed. Targets are
# revalidated immediately before deletion because the plan was calculated
# earlier and the tree may have changed since.
_dev_clean_apply() {
  local root="$1"
  local expected_root_device="$2"
  local expected_root_inode="$3"
  local expected_root_type="$4"
  shift 4
  (( $# % 4 == 0 )) || {
    _dev_error "Internal cleanup plan is malformed."
    return 1
  }
  local -a records=("$@")

  local -i removed=0 skipped=0 failed=0
  local relative expected_device expected_inode expected_type
  local -a current_identity=()
  local result_summary=""

  while (( ${#records[@]} > 0 )); do
    relative="${records[1]}"
    expected_device="${records[2]}"
    expected_inode="${records[3]}"
    expected_type="${records[4]}"
    records=("${records[@]:4}")

    if ! _dev_clean_relative_is_safe "$relative"; then
      _dev_warn \
        "Refusing unsafe target: $(_dev_display_escape "$relative")"
      failed=$(( failed + 1 ))
      continue
    fi

    if [[ ! -e "$relative" && ! -L "$relative" ]]; then
      # Already gone, usually because a parent directory was removed first.
      skipped=$(( skipped + 1 ))
      continue
    fi

    _dev_clean_lstat "$relative" || {
      _dev_warn \
        "Could not inspect target: $(_dev_display_escape "$relative")"
      failed=$(( failed + 1 ))
      continue
    }
    current_identity=("${reply[@]}")
    if [[ "${current_identity[1]}" != "$expected_device" \
      || "${current_identity[2]}" != "$expected_inode" \
      || "${current_identity[3]}" != "$expected_type" ]]; then
      _dev_warn \
        "Refusing target changed after planning: $(_dev_display_escape "$relative")"
      failed=$(( failed + 1 ))
      continue
    fi

    # This is deliberately the final operation before rm. The deletion uses
    # the relative record through the original cwd anchor, never the movable
    # absolute root pathname.
    _dev_clean_revalidate_root \
      "$root" "$expected_root_device" "$expected_root_inode" \
      "$expected_root_type" || {
      result_summary="$removed removed, $failed failed, $skipped skipped"
      _dev_error "Cleanup stopped because the project root changed ($result_summary)."
      return 1
    }

    if [[ "$expected_type" == "directory" ]]; then
      if command rm -rf -- "$relative" 2>/dev/null; then
        removed=$(( removed + 1 ))
      else
        _dev_warn \
          "Could not remove directory: $(_dev_display_escape "$relative")"
        failed=$(( failed + 1 ))
      fi
    else
      if command rm -f -- "$relative" 2>/dev/null; then
        removed=$(( removed + 1 ))
      else
        _dev_warn \
          "Could not remove file: $(_dev_display_escape "$relative")"
        failed=$(( failed + 1 ))
      fi
    fi

    _dev_clean_revalidate_root \
      "$root" "$expected_root_device" "$expected_root_inode" \
      "$expected_root_type" || {
      result_summary="$removed removed, $failed failed, $skipped skipped"
      _dev_error "Cleanup stopped after the project root changed ($result_summary)."
      return 1
    }
  done

  if (( failed > 0 )); then
    _dev_error "Removed $removed target(s); $failed failed, $skipped skipped."
    return 1
  fi

  _dev_success "Removed $removed target(s) ($skipped already absent)."
  return 0
}

# --- Shared cleanup workflow ------------------------------------------------

# Implements the destructive-command sequence for every dev cleanup: compute
# the exact target set without mutating, reject an unusable root, show the
# scope, then require confirmation immediately before execution.
_dev_clean_workflow() {
  local title="$1"
  local -i dry_run="$2"
  local -i auto_yes="$3"
  shift 3
  local -a categories=("$@")

  _dev_header "$title"
  _dev_validate_clean_depth || return 1
  _dev_validate_clean_limit || return 1

  local -a reply=()
  _dev_clean_capture_root || return 1
  local root="${reply[1]}"
  local root_device="${reply[2]}"
  local root_inode="${reply[3]}"
  local root_type="${reply[4]}"

  local -i depth=$(( 10#$DEV_CLEAN_DEPTH ))

  local -a _dev_clean_pruned_repositories=()
  _dev_clean_repository_roots "$root" "$depth" || return 1
  _dev_clean_pruned_repositories=("${reply[@]}")
  _dev_clean_revalidate_root \
    "$root" "$root_device" "$root_inode" "$root_type" || return 1

  local -a targets=()
  local category
  for category in "${categories[@]}"; do
    reply=()
    _dev_clean_collect "$root" "$category" || return $?
    if (( ${#reply[@]} > 0 )); then
      _dev_info "$(_dev_clean_category_label "$category"): ${#reply[@]} target(s)"
      targets+=("${reply[@]}")
    else
      _dev_dim "$(_dev_clean_category_label "$category"): nothing to remove"
    fi
  done

  _dev_clean_revalidate_root \
    "$root" "$root_device" "$root_inode" "$root_type" || return 1

  reply=()
  _dev_clean_build_plan "$root" "${targets[@]}" || return 1
  local -a plan=("${reply[@]}")
  _dev_clean_revalidate_root \
    "$root" "$root_device" "$root_inode" "$root_type" || return 1

  local -i target_count=$(( ${#plan[@]} / 4 ))
  if (( target_count == 0 )); then
    _dev_success "Nothing to clean under $root."
    return 0
  fi

  _dev_clean_show_plan "$root" "${plan[@]}" || return 1

  if (( dry_run )); then
    _dev_warn "DRY-RUN — no files were removed."
    return 0
  fi

  local -i previous_auto_yes=$_DEV_AUTO_YES
  local outcome="declined"
  {
    (( auto_yes )) && _DEV_AUTO_YES=1
    outcome=$(_dev_confirm_outcome \
      "Remove $target_count target(s) under $root?")
  } always {
    _DEV_AUTO_YES=$previous_auto_yes
  }

  case "$outcome" in
    confirmed) ;;
    unavailable)
      # Fail closed rather than reporting a cancellation: a scripted caller
      # that omitted --yes asked for a removal and did not get one.
      _dev_error \
        "Interactive confirmation requires a terminal; pass --yes to remove these targets."
      return 1
      ;;
    *)
      _dev_info "Cancelled. Nothing was removed."
      return 0
      ;;
  esac

  _dev_clean_revalidate_root \
    "$root" "$root_device" "$root_inode" "$root_type" || return 1

  _dev_clean_apply \
    "$root" "$root_device" "$root_inode" "$root_type" "${plan[@]}"
}

_dev_clean_usage() {
  local command_name="$1"
  local extra="${2:-}"

  print -u2 -r -- "Usage: $command_name [options]"
  print -u2 -r -- "  --dry-run    Show the removal plan and exit without deleting."
  print -u2 -r -- "  --yes, -y    Skip the confirmation prompt (validation still runs)."
  [[ -n "$extra" ]] && print -u2 -r -- "$extra"
}

# Shared option parser. Sets _dev_clean_opt_dry_run, _dev_clean_opt_auto_yes,
# and _dev_clean_opt_keep_build for the calling public command.
_dev_clean_parse_options() {
  local command_name="$1"
  local -i allow_keep_build="$2"
  shift 2

  _dev_clean_opt_dry_run=0
  _dev_clean_opt_auto_yes=0
  _dev_clean_opt_keep_build=0

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        if (( allow_keep_build )); then
          if [[ "$command_name" == "dev-clean-all" ]]; then
            _dev_clean_usage "$command_name" \
              "  --keep-build Preserve root build/, dist/, and Cargo target/."
          else
            _dev_clean_usage "$command_name" \
              "  --keep-build Preserve root build/ and dist/."
          fi
        else
          _dev_clean_usage "$command_name"
        fi
        return 3
        ;;
      --dry-run) _dev_clean_opt_dry_run=1 ;;
      --yes|-y)  _dev_clean_opt_auto_yes=1 ;;
      --keep-build)
        if (( ! allow_keep_build )); then
          _dev_error "Unknown option: $1"
          return 2
        fi
        _dev_clean_opt_keep_build=1
        ;;
      *)
        _dev_error "Unknown option: $1"
        return 2
        ;;
    esac
    shift
  done
  return 0
}

# --- Public commands --------------------------------------------------------

# dev-clean-py
#   Arguments: --dry-run | --yes | --keep-build | --help
#   stdout:    none. Plan, prompts, and results go to stderr.
#   Effects:   removes Python caches, compiled files, and root build artifacts.
#   Status:    0 on success or cancellation, 1 on partial failure, 2 bad args.
dev-clean-py() {
  emulate -L zsh

  local -i _dev_clean_opt_dry_run=0 _dev_clean_opt_auto_yes=0
  local -i _dev_clean_opt_keep_build=0
  local -i parse_status=0

  _dev_clean_parse_options dev-clean-py 1 "$@" || parse_status=$?
  (( parse_status == 3 )) && return 0
  (( parse_status != 0 )) && return $parse_status

  local -i previous_keep_build=$_DEV_CLEAN_KEEP_BUILD
  {
    _DEV_CLEAN_KEEP_BUILD=$_dev_clean_opt_keep_build
    (( _DEV_CLEAN_KEEP_BUILD )) \
      && _dev_info "Preserving root build/ and dist/ (--keep-build)."

    _dev_clean_workflow "Cleaning Python Artifacts" \
      "$_dev_clean_opt_dry_run" "$_dev_clean_opt_auto_yes" py
  } always {
    _DEV_CLEAN_KEEP_BUILD=$previous_keep_build
  }
}

# dev-clean-repo
#   Arguments: --dry-run | --yes | --help
#   Effects:   removes OS and editor junk files such as Zone.Identifier files,
#              .DS_Store, AppleDouble forks, Thumbs.db, and desktop.ini.
dev-clean-repo() {
  emulate -L zsh

  local -i _dev_clean_opt_dry_run=0 _dev_clean_opt_auto_yes=0
  local -i _dev_clean_opt_keep_build=0
  local -i parse_status=0

  _dev_clean_parse_options dev-clean-repo 0 "$@" || parse_status=$?
  (( parse_status == 3 )) && return 0
  (( parse_status != 0 )) && return $parse_status

  _dev_clean_workflow "Cleaning Repository Artifacts" \
    "$_dev_clean_opt_dry_run" "$_dev_clean_opt_auto_yes" repo
}

# dev-clean-terraform
#   Arguments: --dry-run | --yes | --help
#   Effects:   removes .terraform directories, plan files, crash logs, and
#              state backups. .terraform.lock.hcl is always preserved.
dev-clean-terraform() {
  emulate -L zsh

  local -i _dev_clean_opt_dry_run=0 _dev_clean_opt_auto_yes=0
  local -i _dev_clean_opt_keep_build=0
  local -i parse_status=0

  _dev_clean_parse_options dev-clean-terraform 0 "$@" || parse_status=$?
  (( parse_status == 3 )) && return 0
  (( parse_status != 0 )) && return $parse_status

  _dev_clean_workflow "Cleaning Terraform Artifacts" \
    "$_dev_clean_opt_dry_run" "$_dev_clean_opt_auto_yes" terraform
}

# dev-clean-all
#   Arguments: --dry-run | --yes | --keep-build | --help
#   Effects:   one combined plan across Python, repository, Terraform, and
#              root Cargo build artifacts, confirmed once.
dev-clean-all() {
  emulate -L zsh

  local -i _dev_clean_opt_dry_run=0 _dev_clean_opt_auto_yes=0
  local -i _dev_clean_opt_keep_build=0
  local -i parse_status=0

  _dev_clean_parse_options dev-clean-all 1 "$@" || parse_status=$?
  (( parse_status == 3 )) && return 0
  (( parse_status != 0 )) && return $parse_status

  local -a categories=(py repo terraform rust)

  local -i previous_keep_build=$_DEV_CLEAN_KEEP_BUILD
  {
    _DEV_CLEAN_KEEP_BUILD=$_dev_clean_opt_keep_build
    (( _DEV_CLEAN_KEEP_BUILD )) \
      && _dev_info \
        "Preserving root build/, dist/, and Cargo target/ (--keep-build)."

    _dev_clean_workflow "Cleaning All Project Artifacts" \
      "$_dev_clean_opt_dry_run" "$_dev_clean_opt_auto_yes" "${categories[@]}"
  } always {
    _DEV_CLEAN_KEEP_BUILD=$previous_keep_build
  }
}

typeset -g _DEV_CLEAN_SOURCED=1
