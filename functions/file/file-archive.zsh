#!/usr/bin/env zsh
# =============================================================================
# File Archive: compression and fail-closed TAR extraction
# =============================================================================
#
# Loaded by file-menu.zsh after file-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_FILE_ARCHIVE_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_file_compress_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- \
    "  file-compress --format FORMAT --output FILE [options] -- PATH..."
  print -u2 -r -- "  file-compress"
  print -u2 -r -- ""
  print -u2 -r -- "Formats: tar.gz, tar.xz, tar.bz2, zip, 7z"
  print -u2 -r -- "Options:"
  print -u2 -r -- "  --overwrite  Replace one unchanged regular output file"
  print -u2 -r -- "  --dry-run    Print the exact plan without creating an archive"
  print -u2 -r -- "  --yes        Confirm the reviewed plan non-interactively"
  print -u2 -r -- "  -h, --help   Show this help"
}

_file_extract_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- \
    "  file-extract --destination DIRECTORY [options] -- ARCHIVE"
  print -u2 -r -- "  file-extract"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Only GNU TAR archives are accepted by the hardened extractor."
  print -u2 -r -- "Options:"
  print -u2 -r -- "  --dry-run    Validate and print the plan without extracting"
  print -u2 -r -- "  --yes        Confirm the reviewed plan non-interactively"
  print -u2 -r -- "  -h, --help   Show this help"
}

_file_archive_normalize_format() {
  local format="${1#.}"
  case "$format" in
    tgz) format="tar.gz" ;;
    txz) format="tar.xz" ;;
    tbz|tbz2) format="tar.bz2" ;;
  esac
  case "$format" in
    tar.gz|tar.xz|tar.bz2|zip|7z)
      REPLY="$format"
      ;;
    *)
      _file_error "Unsupported archive format: $1"
      return 2
      ;;
  esac
}

_file_archive_stage_dir() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  _file_validate_temp_parent "$1" "archive staging" || return 1
  local parent_dir="$REPLY"
  reply=()

  local stage_dir=""
  stage_dir=$(umask 077; command mktemp -d \
    "${parent_dir}/.zdx-file-archive.XXXXXX" 2>/dev/null) || {
    _file_error "Could not create a private archive staging directory."
    return 1
  }
  _file_validate_private_temp \
    "$stage_dir" "$parent_dir" ".zdx-file-archive." directory || {
    _file_error "Refusing an unsafe archive staging directory."
    return 1
  }

  local -A state=()
  if [[ "$stage_dir" != "${stage_dir:a}" \
    || "$stage_dir" != "${stage_dir:A}" \
    || "${stage_dir:h}" != "$parent_dir" \
    || "${stage_dir:t}" != .zdx-file-archive.* \
    || ! -d "$stage_dir" || -L "$stage_dir" ]] \
    || ! zstat -LH state -- "$stage_dir" 2>/dev/null \
    || (( (state[mode] & 8#170000) != 8#040000 \
      || state[uid] != EUID \
      || (state[mode] & 8#77) != 0 )); then
    _file_error "Refusing an unsafe archive staging directory."
    return 1
  fi

  reply=(
    "$stage_dir"
    "${state[device]}:${state[inode]}:${state[mode]}:${state[uid]}"
  )
}

_file_archive_cleanup_stage() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local stage_dir="$1"
  local expected_identity="$2"
  [[ -n "$stage_dir" && -n "$expected_identity" ]] || return 0
  [[ -d "$stage_dir" && ! -L "$stage_dir" \
    && "$stage_dir" == "${stage_dir:a}" \
    && "$stage_dir" == "${stage_dir:A}" \
    && "${stage_dir:t}" == .zdx-file-archive.* ]] || {
    _file_warn "The archive staging path changed; refusing cleanup."
    return 1
  }
  local -A state=()
  zstat -LH state -- "$stage_dir" 2>/dev/null || return 1
  [[ "${state[device]}:${state[inode]}:${state[mode]}:${state[uid]}" \
    == "$expected_identity" ]] || {
    _file_warn "The archive staging identity changed; refusing cleanup."
    return 1
  }
  command rm -rf -- "$stage_dir" 2>/dev/null
}

_file_archive_inputs_plan() {
  local base_dir="$1"
  shift
  reply=()
  (( $# <= _FILE_MAX_CANDIDATES )) || {
    _file_error \
      "Archive plans accept at most $_FILE_MAX_CANDIDATES explicit inputs."
    return 2
  }
  local -a identities=()
  local candidate=""
  local validation=""
  local absolute=""
  local existing=""
  for candidate in "$@"; do
    _file_validate_mutation_target "$candidate" "$base_dir" || return 1
    validation="$REPLY"
    absolute="${validation%%|*}"
    if _file_array_contains_literal "$absolute" "${reply[@]}"; then
      _file_error "Duplicate archive input: $candidate"
      return 1
    fi
    for existing in "${reply[@]}"; do
      if [[ "$absolute" == "$existing"/* || "$existing" == "$absolute"/* ]]; then
        _file_error "Archive inputs may not contain one another."
        return 1
      fi
    done
    if [[ -d "$absolute" ]]; then
      _file_validate_tree_for_transfer "$absolute" || return 1
    fi
    reply+=("$absolute")
    identities+=("${validation#*|}")
  done
  (( ${#reply[@]} > 0 )) || {
    _file_error "At least one input path is required."
    return 2
  }
  REPLY="${(F)identities}"
}

_file_archive_revalidate_inputs() {
  local inputs_name="$1"
  local identities_text="$2"
  local -a inputs=("${(@P)inputs_name}")
  local -a identities=("${(@f)identities_text}")
  (( ${#inputs[@]} == ${#identities[@]} )) || return 1

  local -i index=1
  while (( index <= ${#inputs[@]} )); do
    _file_revalidate_mutation_target \
      "${inputs[index]}" "${identities[index]}" || return 1
    if [[ -d "${inputs[index]}" ]]; then
      _file_validate_tree_for_transfer "${inputs[index]}" || return 1
    fi
    (( ++index ))
  done
}

_file_compress_execute() {
  local format="$1"
  local output_file="$2"
  local overwrite="$3"
  local dry_run="$4"
  local auto_yes="$5"
  shift 5
  local -a requested_inputs=("$@")

  _file_archive_normalize_format "$format" || return $?
  format="$REPLY"
  _file_validate_base "$PWD" || return 1
  local base_dir="$REPLY"

  _file_archive_inputs_plan "$base_dir" "${requested_inputs[@]}" || return $?
  local -a inputs=("${reply[@]}")
  local identities_text="$REPLY"

  _file_validate_destination_parent "$output_file" || {
    _file_error "Invalid archive output: $output_file"
    return 1
  }
  local destination="$REPLY"
  local destination_parent_identity="${reply[2]}"
  local input=""
  for input in "${inputs[@]}"; do
    if [[ -d "$input" && "$destination" == "$input"/* ]]; then
      _file_error "The archive output cannot be inside an input directory."
      return 1
    fi
    [[ "$destination" != "$input" ]] || {
      _file_error "The archive output cannot replace an input path."
      return 1
    }
  done

  _file_output_snapshot "$destination" || return 1
  local output_state="$REPLY"
  if [[ "$output_state" != "absent" && "$overwrite" != "yes" ]]; then
    _file_error "Output already exists; pass --overwrite to replace it."
    return 1
  fi

  _file_header "Archive Creation Plan"
  _file_info "Format: $format"
  _file_info "Output: $destination"
  _file_info "Inputs: ${#inputs[@]}"
  for input in "${inputs[@]}"; do
    _file_dim "$input"
  done
  if [[ "$dry_run" == "yes" ]]; then
    _file_success "Dry run complete; no archive was created."
    return 0
  fi

  local confirmation_prompt="Create this archive?"
  [[ "$output_state" == "absent" ]] \
    || confirmation_prompt="Create this archive and replace the existing output?"
  _file_confirm_mutation "$confirmation_prompt" "$auto_yes"
  local -i confirm_rc=$?
  (( confirm_rc == 0 )) || {
    (( confirm_rc == 130 )) && return 0
    return $confirm_rc
  }

  _file_archive_revalidate_inputs inputs "$identities_text" || return 1
  _file_revalidate_output_snapshot "$destination" "$output_state" || return 1

  _file_archive_stage_dir "${destination:h}" || return 1
  local stage_dir="${reply[1]}"
  local stage_identity="${reply[2]}"
  local staged_file="${stage_dir}/${destination:t}"
  local -a archive_operands=()
  for input in "${inputs[@]}"; do
    archive_operands+=("./${input#$base_dir/}")
  done

  local -i archive_rc=1 operation_rc=1 cleanup_rc=0
  {
    case "$format" in
      tar.gz)
        _file_require_cmd tar "tar.gz creation" || return 1
        (
          builtin cd -- "$base_dir" || return 1
          command tar -czf "$staged_file" -- "${archive_operands[@]}"
        ) >&2
        archive_rc=$?
        ;;
      tar.xz)
        _file_require_cmd tar "tar.xz creation" || return 1
        (
          builtin cd -- "$base_dir" || return 1
          command tar -cJf "$staged_file" -- "${archive_operands[@]}"
        ) >&2
        archive_rc=$?
        ;;
      tar.bz2)
        _file_require_cmd tar "tar.bz2 creation" || return 1
        (
          builtin cd -- "$base_dir" || return 1
          command tar -cjf "$staged_file" -- "${archive_operands[@]}"
        ) >&2
        archive_rc=$?
        ;;
      zip)
        _file_require_cmd zip "ZIP creation" || return 1
        (
          builtin cd -- "$base_dir" || return 1
          command zip -q -r "$staged_file" -- "${archive_operands[@]}"
        ) >&2
        archive_rc=$?
        ;;
      7z)
        _file_require_cmd 7z "7z creation" || return 1
        (
          builtin cd -- "$base_dir" || return 1
          command 7z a -- "$staged_file" "${archive_operands[@]}"
        ) >&2
        archive_rc=$?
        ;;
    esac

    if (( archive_rc != 0 )) || [[ ! -f "$staged_file" || -L "$staged_file" ]]; then
      _file_error "Archive creation failed before publication."
      (( archive_rc == 0 )) || operation_rc=$archive_rc
    else
      operation_rc=0
      command chmod 600 -- "$staged_file" 2>/dev/null || {
        operation_rc=$?
        _file_error "Could not protect the staged archive."
      }
      if (( operation_rc == 0 )); then
        _file_archive_revalidate_inputs inputs "$identities_text" || {
          operation_rc=$?
          _file_error "Archive inputs changed during creation."
        }
      fi
      if (( operation_rc == 0 )); then
        _file_publish_staged_file \
          "$staged_file" "$destination" "$output_state" \
          "$destination_parent_identity" || operation_rc=$?
      fi
      if (( operation_rc == 0 )); then
        _file_success "Created archive: $destination"
      fi
    fi
  } always {
    if [[ -d "$stage_dir" ]]; then
      _file_archive_cleanup_stage "$stage_dir" "$stage_identity" \
        || cleanup_rc=$?
    fi
    if (( cleanup_rc != 0 && operation_rc != 130 && operation_rc != 143 )); then
      operation_rc=$cleanup_rc
    fi
  }
  return $operation_rc
}

file-compress() {
  emulate -L zsh
  _file_header "Compress Files"

  if (( $# == 0 )); then
    _file_select_paths "Select files to compress" yes all
    local -i select_rc=$?
    if (( select_rc != 0 )); then
      (( select_rc == 130 )) && return 0
      return $select_rc
    fi
    local -a interactive_inputs=("${reply[@]}")

    _file_choose_fixed "Archive format" \
      "tar.gz" "zip" "tar.xz" "tar.bz2" "7z"
    local -i format_rc=$?
    if (( format_rc != 0 )); then
      (( format_rc == 130 )) && return 0
      return $format_rc
    fi
    local format="$REPLY"
    local default_output="${interactive_inputs[1]:t}.${format}"
    _file_read_line "Output archive" "$default_output" || return $?
    _file_compress_execute \
      "$format" "$REPLY" no no no "${interactive_inputs[@]}"
    return $?
  fi

  local format="" output_file=""
  local overwrite=no dry_run=no auto_yes=no
  local -a inputs=()
  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        (( $# == 1 )) || return 2
        _file_compress_usage
        return 0
        ;;
      --format)
        (( $# >= 2 )) || {
          _file_error "--format requires a value."
          return 2
        }
        format="$2"
        shift 2
        ;;
      --output)
        (( $# >= 2 )) || {
          _file_error "--output requires a value."
          return 2
        }
        output_file="$2"
        shift 2
        ;;
      --overwrite) overwrite=yes; shift ;;
      --dry-run) dry_run=yes; shift ;;
      --yes) auto_yes=yes; shift ;;
      --)
        shift
        inputs+=("$@")
        break
        ;;
      -*)
        _file_error "Unknown option: $1"
        return 2
        ;;
      *)
        inputs+=("$1")
        shift
        ;;
    esac
  done

  [[ -n "$format" && -n "$output_file" && ${#inputs[@]} -gt 0 ]] || {
    _file_error "--format, --output, and at least one input are required."
    return 2
  }
  _file_compress_execute \
    "$format" "$output_file" "$overwrite" "$dry_run" "$auto_yes" \
    "${inputs[@]}"
}

_file_tar_preflight() {
  emulate -L zsh
  local archive_file="$1"
  reply=()
  _file_require_cmd tar "TAR extraction" || return 1
  _file_sha256_digest "$archive_file" || {
    _file_error "Could not fingerprint archive content."
    return 1
  }
  local archive_digest="$REPLY"

  local version_text=""
  version_text=$(command tar --version 2>/dev/null) || return 1
  [[ "$version_text" == *"GNU tar"* ]] || {
    _file_error "Extraction requires GNU tar for bounded preflight checks."
    return 1
  }

  local list_dir=""
  _file_archive_stage_dir "${TMPDIR:-/tmp}" || return 1
  list_dir="${reply[1]}"
  local list_identity="${reply[2]}"
  local names_file="${list_dir}/names"
  local verbose_file="${list_dir}/verbose"
  local -i preflight_rc=1 cleanup_rc=0
  {
    _file_require_cmd head "bounded TAR preflight" || return 1
    setopt local_options pipefail
    local -i producer_rc=1
    LC_ALL=C command tar --list --file="$archive_file" \
      --quoting-style=escape 2>/dev/null \
      | command head -c "$(( _FILE_MAX_PICKER_BYTES + 1 ))" \
        > "$names_file"
    producer_rc=$?

    local -A list_state=()
    zmodload zsh/stat 2>/dev/null || return 1
    zstat -LH list_state -- "$names_file" 2>/dev/null || return 1
    (( list_state[size] <= _FILE_MAX_PICKER_BYTES )) || {
      _file_error "The TAR name inventory is oversized."
      return 1
    }
    (( producer_rc == 0 )) || {
      _file_error "Could not produce a bounded TAR name inventory."
      return 1
    }
    LC_ALL=C command tar --list --verbose --numeric-owner \
      --file="$archive_file" --quoting-style=escape 2>/dev/null \
      | command head -c "$(( _FILE_MAX_PICKER_BYTES + 1 ))" \
        > "$verbose_file"
    producer_rc=$?
    list_state=()
    zstat -LH list_state -- "$verbose_file" 2>/dev/null || return 1
    (( list_state[size] <= _FILE_MAX_PICKER_BYTES )) || {
      _file_error "The TAR metadata inventory is oversized."
      return 1
    }
    (( producer_rc == 0 )) || {
      _file_error "Could not produce a bounded TAR metadata inventory."
      return 1
    }

    local -a member_names=()
    local -A normalized_seen=()
    local member_name=""
    local normalized_name=""
    local component=""
    local -i member_count=0
    while IFS= read -r member_name || [[ -n "$member_name" ]]; do
      (( ++member_count <= _FILE_MAX_ARCHIVE_ENTRIES )) || {
        _file_error "Archive exceeds the $_FILE_MAX_ARCHIVE_ENTRIES entry limit."
        return 1
      }
      [[ -n "$member_name" \
        && "$member_name" != /* \
        && "$member_name" != *'|'* \
        && "$member_name" != *\\* \
        && "$member_name" != *[[:cntrl:]]* ]] || {
        _file_error "Archive contains an unsafe or unrepresentable member name."
        return 1
      }
      for component in "${(@s:/:)member_name}"; do
        [[ "$component" != ".." ]] || {
          _file_error "Archive contains a parent-directory traversal."
          return 1
        }
      done
      normalized_name="${member_name#./}"
      normalized_name="${normalized_name%/}"
      [[ -n "$normalized_name" && -z "${normalized_seen[$normalized_name]:-}" ]] \
        || {
          _file_error "Archive contains duplicate or colliding member names."
          return 1
        }
      normalized_seen[$normalized_name]=1
      member_names+=("$normalized_name")
    done < "$names_file"
    (( member_count > 0 )) || {
      _file_error "Refusing an empty archive."
      return 1
    }

    local verbose_line=""
    local -a fields=()
    local -a member_types=()
    local -a member_sizes=()
    local -i expanded_bytes=0 verbose_count=0
    while IFS= read -r verbose_line || [[ -n "$verbose_line" ]]; do
      fields=("${(z)verbose_line}")
      (( ${#fields[@]} >= 3 )) || {
        _file_error "Could not parse the TAR inventory."
        return 1
      }
      [[ "${fields[1][1]}" == "-" || "${fields[1][1]}" == "d" ]] || {
        _file_error "Archive links and special files are not accepted."
        return 1
      }
      member_types+=("${fields[1][1]}")
      local size_text="${fields[3]}"
      [[ "$size_text" == <-> && ${#size_text} -le 10 ]] || {
        _file_error "Could not parse an archived file size."
        return 1
      }
      local -i member_size=$(( 10#$size_text ))
      if [[ "${fields[1][1]}" == "d" ]] && (( member_size != 0 )); then
        _file_error "Archive directory entries must declare zero content bytes."
        return 1
      fi
      (( member_size >= 0 \
        && member_size <= _FILE_MAX_ARCHIVE_BYTES - expanded_bytes )) || {
        _file_error "Archive exceeds the expanded-size limit."
        return 1
      }
      (( expanded_bytes += member_size ))
      member_sizes+=("$member_size")
      (( ++verbose_count ))
    done < "$verbose_file"
    (( verbose_count == member_count )) || {
      _file_error "TAR inventories disagreed during preflight."
      return 1
    }
    _file_sha256_digest "$archive_file" || return 1
    [[ "$REPLY" == "$archive_digest" ]] || {
      _file_error "Archive content changed during preflight."
      return 1
    }

    local -a member_records=()
    local -i member_index=1
    while (( member_index <= member_count )); do
      member_records+=(
        "${member_types[member_index]}|${member_sizes[member_index]}|${member_names[member_index]}"
      )
      (( ++member_index ))
    done
    reply=("${member_records[@]}")
    REPLY="${expanded_bytes}|${archive_digest}"
    preflight_rc=0
  } always {
    _file_archive_cleanup_stage "$list_dir" "$list_identity" \
      || cleanup_rc=$?
    (( cleanup_rc == 0 )) || preflight_rc=1
  }
  return $preflight_rc
}

_file_extract_tree_validate() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local extraction_dir="$1"
  local expected_name="$2"
  local -a expected_members=("${(@P)expected_name}")
  local -A expected_set=()
  local -A expected_sizes=()
  local -A expected_seen=()
  local expected_record=""
  local expected_member=""
  local expected_type=""
  local expected_size=""
  local expected_body=""
  local -i expected_bytes=0
  for expected_record in "${expected_members[@]}"; do
    expected_type="${expected_record%%|*}"
    expected_body="${expected_record#*|}"
    expected_size="${expected_body%%|*}"
    expected_member="${expected_body#*|}"
    [[ ( "$expected_type" == "-" || "$expected_type" == "d" ) \
      && "$expected_size" == <-> && ${#expected_size} -le 10 \
      && -n "$expected_member" ]] || return 1
    local -i numeric_expected_size=$(( 10#$expected_size ))
    (( numeric_expected_size >= 0 \
      && numeric_expected_size <= _FILE_MAX_ARCHIVE_BYTES - expected_bytes )) \
      || return 1
    (( expected_bytes += numeric_expected_size ))
    expected_set[$expected_member]="$expected_type"
    expected_sizes[$expected_member]="$numeric_expected_size"
  done
  local entry=""
  local -A state=()
  local relative_entry=""
  local -i entry_count=0 file_count=0 expanded_bytes=0
  _file_archive_stage_dir "${TMPDIR:-/tmp}" || return 1
  local inventory_dir="${reply[1]}"
  local inventory_identity="${reply[2]}"
  local inventory_file="${inventory_dir}/tree"
  local -i validation_rc=1 cleanup_rc=0 find_rc=1
  {
    _file_require_cmd head "bounded extracted-tree inspection" || return 1
    setopt local_options pipefail
    command find "$extraction_dir" -mindepth 1 -print0 2>/dev/null \
      | command head -c "$(( _FILE_MAX_PICKER_BYTES + 1 ))" \
        > "$inventory_file"
    find_rc=$?
    local -A inventory_state=()
    zstat -LH inventory_state -- "$inventory_file" 2>/dev/null || return 1
    (( inventory_state[size] <= _FILE_MAX_PICKER_BYTES )) || {
      _file_error "The extracted-tree inventory is oversized."
      return 1
    }
    (( find_rc == 0 )) || {
      _file_error "Could not inventory the extracted tree."
      return 1
    }
    while IFS= read -r -d '' entry; do
      (( ++entry_count <= _FILE_MAX_ARCHIVE_ENTRIES )) || return 1
      [[ "$entry" == "$extraction_dir"/* && ! -L "$entry" ]] || return 1
      zstat -LH state -- "$entry" 2>/dev/null || return 1
      relative_entry="${entry#$extraction_dir/}"
      _file_path_is_displayable "$relative_entry" || return 1
      [[ "$relative_entry" != *'|'* ]] || return 1
      if [[ -f "$entry" ]]; then
        (( state[nlink] == 1 )) || return 1
        [[ "${expected_set[$relative_entry]:-}" == "-" ]] || {
          _file_error "The extracted tree contains an unplanned file."
          return 1
        }
        (( state[size] == expected_sizes[$relative_entry] )) || {
          _file_error "An extracted file size differs from the reviewed TAR."
          return 1
        }
        expected_seen[$relative_entry]=1
        (( ++file_count ))
        (( state[size] >= 0 \
          && state[size] <= _FILE_MAX_ARCHIVE_BYTES - expanded_bytes )) \
          || return 1
        (( expanded_bytes += state[size] ))
      elif [[ -d "$entry" ]]; then
        if [[ "${expected_set[$relative_entry]:-}" == "d" ]]; then
          expected_seen[$relative_entry]=1
        elif [[ -n "${expected_set[$relative_entry]:-}" ]]; then
          _file_error "An extracted member changed type."
          return 1
        else
          local implicit_parent=no
          for expected_member in "${(@k)expected_set}"; do
            if [[ "$expected_member" == "$relative_entry"/* ]]; then
              implicit_parent=yes
              break
            fi
          done
          [[ "$implicit_parent" == "yes" ]] || {
            _file_error "The extracted tree contains an unplanned directory."
            return 1
          }
        fi
      else
        return 1
      fi
    done < "$inventory_file"
    (( entry_count > 0 && file_count <= ${#expected_members[@]} )) || return 1
    for expected_member in "${(@k)expected_set}"; do
      [[ -n "${expected_seen[$expected_member]:-}" ]] || {
        _file_error "An expected archive member was not realized."
        return 1
      }
    done
    (( expanded_bytes == expected_bytes )) || {
      _file_error "Extracted bytes differ from the reviewed TAR inventory."
      return 1
    }
    validation_rc=0
  } always {
    _file_archive_cleanup_stage "$inventory_dir" "$inventory_identity" \
      || cleanup_rc=$?
    (( cleanup_rc == 0 )) || validation_rc=1
  }
  return $validation_rc
}

_file_extract_snapshot_run() {
  local archive_absolute="$1"
  local archive_identity="$2"
  local archive_snapshot="$3"
  local snapshot_identity="$4"
  local destination="$5"
  local destination_parent_identity="$6"
  local dry_run="$7"
  local auto_yes="$8"

  _file_tar_preflight "$archive_snapshot" || return 1
  local -a members=("${reply[@]}")
  local expanded_bytes="${REPLY%%|*}"
  local archive_digest="${REPLY#*|}"
  _file_header "Archive Extraction Plan"
  _file_info "Archive: $archive_absolute"
  _file_info "Destination: $destination"
  _file_info "Members: ${#members[@]}"
  _file_info "Declared bytes: $expanded_bytes"
  if [[ "$dry_run" == "yes" ]]; then
    _file_success "Dry run complete; no files were extracted."
    return 0
  fi

  _file_confirm_mutation "Extract this archive into a new directory?" "$auto_yes"
  local -i confirm_rc=$?
  (( confirm_rc == 0 )) || {
    (( confirm_rc == 130 )) && return 0
    return $confirm_rc
  }
  _file_revalidate_mutation_target \
    "$archive_absolute" "$archive_identity" || return 1
  _file_sha256_digest "$archive_absolute" || return 1
  [[ "$REPLY" == "$archive_digest" ]] || {
    _file_error "Archive content changed after confirmation."
    return 1
  }
  _file_path_fingerprint "$archive_snapshot" || return 1
  [[ "$REPLY" == "$snapshot_identity" ]] || {
    _file_error "The private archive snapshot changed after confirmation."
    return 1
  }
  _file_sha256_digest "$archive_snapshot" || return 1
  [[ "$REPLY" == "$archive_digest" ]] || return 1
  _file_revalidate_parent "$destination" "$destination_parent_identity" \
    || return 1
  [[ ! -e "$destination" && ! -L "$destination" ]] || {
    _file_error "The extraction destination appeared after planning."
    return 1
  }

  _file_archive_stage_dir "${destination:h}" || return 1
  local stage_dir="${reply[1]}"
  local stage_identity="${reply[2]}"
  local -i operation_rc=1 cleanup_rc=0
  {
    LC_ALL=C command tar --extract --file="$archive_snapshot" \
      --directory="$stage_dir" \
      --no-same-owner --no-same-permissions >&2 || {
      operation_rc=$?
      _file_error "Archive extraction failed in staging."
      return $operation_rc
    }
    _file_extract_tree_validate "$stage_dir" members || {
      _file_error "Extracted tree failed post-extraction validation."
      return 1
    }
    _file_revalidate_mutation_target \
      "$archive_absolute" "$archive_identity" || return 1
    _file_sha256_digest "$archive_absolute" || return 1
    [[ "$REPLY" == "$archive_digest" ]] || {
      _file_error "Archive content changed before publication."
      return 1
    }
    _file_path_fingerprint "$archive_snapshot" || return 1
    [[ "$REPLY" == "$snapshot_identity" ]] || return 1
    _file_sha256_digest "$archive_snapshot" || return 1
    [[ "$REPLY" == "$archive_digest" ]] || return 1
    _file_revalidate_parent "$destination" "$destination_parent_identity" \
      || return 1
    [[ ! -e "$destination" && ! -L "$destination" ]] || {
      _file_error "The extraction destination appeared before publication."
      return 1
    }
    command mv -T -n -- "$stage_dir" "$destination" 2>/dev/null || {
      operation_rc=$?
      _file_error "Could not publish the validated extraction."
      return $operation_rc
    }
    _file_directory_identity "$destination" || return 1
    [[ "$REPLY" == "$stage_identity" ]] || {
      _file_error "Published extraction identity does not match staging."
      return 1
    }
    _file_revalidate_parent "$destination" "$destination_parent_identity" \
      || return 1
    stage_dir=""
    _file_success "Extracted archive to: $destination"
    operation_rc=0
  } always {
    if [[ -n "$stage_dir" && -d "$stage_dir" ]]; then
      _file_archive_cleanup_stage "$stage_dir" "$stage_identity" \
        || cleanup_rc=$?
    fi
    (( cleanup_rc == 0 )) || operation_rc=1
  }
  return $operation_rc
}

_file_extract_execute() {
  local archive_file="$1"
  local destination_dir="$2"
  local dry_run="$3"
  local auto_yes="$4"

  _file_validate_base "$PWD" || return 1
  local base_dir="$REPLY"
  _file_validate_mutation_target "$archive_file" "$base_dir" || return 1
  local archive_plan="$REPLY"
  local archive_absolute="${archive_plan%%|*}"
  local archive_identity="${archive_plan#*|}"
  [[ -f "$archive_absolute" ]] || {
    _file_error "The archive must be a regular file."
    return 1
  }
  case "$archive_absolute" in
    *.tar|*.tar.gz|*.tgz|*.tar.xz|*.tar.bz2) ;;
    *)
      _file_error \
        "This backend is not safely validated; only TAR archives are accepted."
      return 1
      ;;
  esac

  _file_validate_destination_parent "$destination_dir" || return 1
  local destination="${REPLY%/}"
  local destination_parent_identity="${reply[2]}"
  [[ "$destination" != "/" \
    && "$destination" != "${HOME:A}" \
    && "$destination" != "$base_dir" \
    && "$destination" != "$_FILE_SUITE_ROOT" ]] || {
    _file_error "Refusing a protected extraction destination."
    return 1
  }
  [[ ! -e "$destination" && ! -L "$destination" ]] || {
    _file_error "Extraction destination already exists; refusing to merge or overwrite."
    return 1
  }

  _file_revalidate_mutation_target \
    "$archive_absolute" "$archive_identity" || return 1
  _file_sha256_digest "$archive_absolute" || return 1
  local original_digest="$REPLY"
  _file_make_sibling_temp "${destination}.archive-snapshot" || return 1
  local archive_snapshot="$REPLY"
  _file_node_identity "$archive_snapshot" || return 1
  local snapshot_node_identity="$REPLY"
  local snapshot_identity=""
  local -i snapshot_rc=1 snapshot_cleanup_rc=0
  {
    command cp -- "$archive_absolute" "$archive_snapshot" 2>/dev/null || {
      _file_error "Could not create a private archive snapshot."
      return 1
    }
    command chmod 600 -- "$archive_snapshot" 2>/dev/null || return 1
    _file_revalidate_mutation_target \
      "$archive_absolute" "$archive_identity" || return 1
    _file_sha256_digest "$archive_absolute" || return 1
    [[ "$REPLY" == "$original_digest" ]] || {
      _file_error "Archive content changed while it was snapshotted."
      return 1
    }
    _file_sha256_digest "$archive_snapshot" || return 1
    [[ "$REPLY" == "$original_digest" ]] || {
      _file_error "The private archive snapshot does not match its source."
      return 1
    }
    _file_path_fingerprint "$archive_snapshot" || return 1
    snapshot_identity="$REPLY"

    _file_extract_snapshot_run \
      "$archive_absolute" "$archive_identity" \
      "$archive_snapshot" "$snapshot_identity" \
      "$destination" "$destination_parent_identity" \
      "$dry_run" "$auto_yes"
    snapshot_rc=$?
  } always {
    if [[ -f "$archive_snapshot" && ! -L "$archive_snapshot" ]]; then
      _file_node_identity "$archive_snapshot" || snapshot_cleanup_rc=1
      if (( snapshot_cleanup_rc == 0 )) \
        && [[ "$REPLY" == "$snapshot_node_identity" ]]; then
        command rm -f -- "$archive_snapshot" 2>/dev/null \
          || snapshot_cleanup_rc=1
      else
        _file_warn "The private archive snapshot changed; refusing cleanup."
        snapshot_cleanup_rc=1
      fi
    fi
    (( snapshot_cleanup_rc == 0 )) || snapshot_rc=1
  }
  return $snapshot_rc
}

file-extract() {
  emulate -L zsh
  _file_header "Extract Archive"

  if (( $# == 0 )); then
    _file_select_paths "Select a TAR archive" no files
    local -i select_rc=$?
    if (( select_rc != 0 )); then
      (( select_rc == 130 )) && return 0
      return $select_rc
    fi
    local archive_file="${reply[1]}"
    local default_destination="${archive_file:t}"
    default_destination="${default_destination%.tar.gz}"
    default_destination="${default_destination%.tar.xz}"
    default_destination="${default_destination%.tar.bz2}"
    default_destination="${default_destination%.tgz}"
    default_destination="${default_destination%.tar}"
    default_destination="${default_destination:-extracted}"
    _file_read_line "New extraction directory" "$default_destination" \
      || return $?
    _file_extract_execute "$archive_file" "$REPLY" no no
    return $?
  fi

  local destination_dir="" archive_file=""
  local dry_run=no auto_yes=no
  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        (( $# == 1 )) || return 2
        _file_extract_usage
        return 0
        ;;
      --destination)
        (( $# >= 2 )) || {
          _file_error "--destination requires a value."
          return 2
        }
        destination_dir="$2"
        shift 2
        ;;
      --dry-run) dry_run=yes; shift ;;
      --yes) auto_yes=yes; shift ;;
      --)
        shift
        (( $# == 1 )) && [[ -z "$archive_file" ]] || {
          _file_error "Exactly one archive is required."
          return 2
        }
        archive_file="$1"
        shift
        ;;
      -*)
        _file_error "Unknown option: $1"
        return 2
        ;;
      *)
        [[ -z "$archive_file" ]] || {
          _file_error "Exactly one archive is required."
          return 2
        }
        archive_file="$1"
        shift
        ;;
    esac
  done
  [[ -n "$destination_dir" && -n "$archive_file" ]] || {
    _file_error "--destination and exactly one archive are required."
    return 2
  }
  _file_extract_execute "$archive_file" "$destination_dir" "$dry_run" "$auto_yes"
}

typeset -g _FILE_ARCHIVE_SOURCED=1
