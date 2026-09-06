#!/usr/bin/env zsh
# =============================================================================
# File Data: staged Base64 conversion and checksum verification
# =============================================================================
#
# Loaded by file-menu.zsh after file-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_FILE_DATA_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_file_encode_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- "  file-encode-decode --encode-text TEXT"
  print -u2 -r -- "  file-encode-decode --decode-text BASE64"
  print -u2 -r -- \
    "  file-encode-decode --encode-file FILE --output FILE [options]"
  print -u2 -r -- \
    "  file-encode-decode --decode-file FILE --output FILE [options]"
  print -u2 -r -- "  file-encode-decode"
  print -u2 -r -- ""
  print -u2 -r -- "File-output options: --overwrite, --dry-run, --yes"
}

_file_checksum_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- \
    "  file-checksum --algorithm sha256|md5 -- FILE"
  print -u2 -r -- "  file-checksum --verify HEX_DIGEST -- FILE"
  print -u2 -r -- "  file-checksum"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Generated digests are written to stdout. MD5 is legacy-only."
}

_file_data_temp_file() {
  REPLY=""
  _file_validate_temp_parent "${TMPDIR:-/tmp}" "data staging" || return 1
  local temp_root="$REPLY"
  local temp_file=""
  temp_file=$(umask 077; command mktemp \
    "${temp_root%/}/zdx-file-data.XXXXXX" 2>/dev/null) || {
    _file_error "Could not create a private data staging file."
    return 1
  }
  _file_validate_private_temp \
    "$temp_file" "$temp_root" "zdx-file-data." file || {
    _file_error "Refusing an unsafe data staging file."
    return 1
  }
  REPLY="$temp_file"
}

_file_base64_decode_to() {
  local input_file="$1"
  local output_file="$2"
  command base64 --decode < "$input_file" > "$output_file" 2>/dev/null \
    && return 0
  local -i decode_rc=$?
  (( decode_rc == 130 || decode_rc == 143 )) && return $decode_rc
  : > "$output_file" || return 1
  command base64 -D < "$input_file" > "$output_file" 2>/dev/null
}

_file_base64_text() {
  local action="$1"
  local value="$2"
  _file_require_cmd base64 "Base64 conversion" || return 1
  (( ${#value} <= _FILE_MAX_TEXT_BYTES )) || {
    _file_error "Text input exceeds the $_FILE_MAX_TEXT_BYTES byte limit."
    return 1
  }
  if [[ "$action" == "encode-text" ]]; then
    setopt localoptions pipefail
    print -rn -- "$value" | command base64
    return $?
  fi

  _file_data_temp_file || return 1
  local staged_file="$REPLY"
  local encoded_file=""
  local -i decode_rc=1 cleanup_rc=0
  {
    _file_data_temp_file || return 1
    encoded_file="$REPLY"
    print -rn -- "$value" > "$encoded_file" || return 1
    _file_base64_decode_to "$encoded_file" "$staged_file"
    decode_rc=$?
    command rm -f -- "$encoded_file" 2>/dev/null || return 1
    encoded_file=""
    (( decode_rc == 0 )) || {
      _file_error "Invalid Base64 input."
      return 1
    }
    local -A decoded_state=()
    zmodload zsh/stat 2>/dev/null \
      && zstat -LH decoded_state -- "$staged_file" 2>/dev/null || return 1
    (( decoded_state[size] <= _FILE_MAX_TEXT_BYTES )) || {
      _file_error "Decoded text exceeds the output limit."
      return 1
    }
    command cat -- "$staged_file"
    decode_rc=$?
  } always {
    if [[ -n "$encoded_file" && -f "$encoded_file" \
      && ! -L "$encoded_file" \
      && "${encoded_file:t}" == zdx-file-data.* ]]; then
      command rm -f -- "$encoded_file" 2>/dev/null || cleanup_rc=1
    fi
    if [[ -f "$staged_file" && ! -L "$staged_file" \
      && "${staged_file:t}" == zdx-file-data.* ]]; then
      command rm -f -- "$staged_file" 2>/dev/null || cleanup_rc=1
    fi
    (( cleanup_rc == 0 )) || decode_rc=1
  }
  return $decode_rc
}

_file_base64_file() {
  local action="$1"
  local input_arg="$2"
  local output_arg="$3"
  local overwrite="$4"
  local dry_run="$5"
  local auto_yes="$6"
  _file_require_cmd base64 "Base64 file conversion" || return 1
  _file_validate_base "$PWD" || return 1
  local base_dir="$REPLY"
  _file_validate_mutation_target "$input_arg" "$base_dir" || return 1
  local input_plan="$REPLY"
  local input_file="${input_plan%%|*}"
  local input_identity="${input_plan#*|}"
  [[ -f "$input_file" ]] || {
    _file_error "Base64 input must be a regular file."
    return 1
  }
  _file_sha256_digest "$input_file" || return 1
  local input_digest="$REPLY"

  _file_validate_destination_parent "$output_arg" || return 1
  local output_file="$REPLY"
  local output_parent_identity="${reply[2]}"
  [[ "$output_file" != "$input_file" ]] || {
    _file_error "Input and output must be different files."
    return 1
  }
  _file_output_snapshot "$output_file" || return 1
  local output_state="$REPLY"
  if [[ "$output_state" != "absent" && "$overwrite" != "yes" ]]; then
    _file_error "Output already exists; pass --overwrite to replace it."
    return 1
  fi

  _file_header "Base64 File Plan"
  _file_info "Action: $action"
  _file_info "Input: $input_file"
  _file_info "Output: $output_file"
  if [[ "$dry_run" == "yes" ]]; then
    _file_success "Dry run complete; no output was written."
    return 0
  fi
  if [[ "$output_state" != "absent" ]]; then
    _file_confirm_mutation "Replace the existing output file?" "$auto_yes"
    local -i confirm_rc=$?
    (( confirm_rc == 0 )) || {
      (( confirm_rc == 130 )) && return 0
      return $confirm_rc
    }
  fi

  _file_revalidate_mutation_target "$input_file" "$input_identity" || return 1
  _file_sha256_digest "$input_file" || return 1
  [[ "$REPLY" == "$input_digest" ]] || {
    _file_error "Base64 input content changed after planning."
    return 1
  }
  _file_revalidate_output_snapshot "$output_file" "$output_state" || return 1

  _file_make_sibling_temp "$output_file" || return 1
  local staged_file="$REPLY"
  local -i transform_rc=1 cleanup_rc=0
  {
    if [[ "$action" == "encode-file" ]]; then
      command base64 < "$input_file" > "$staged_file"
      transform_rc=$?
    else
      _file_base64_decode_to "$input_file" "$staged_file"
      transform_rc=$?
    fi
    (( transform_rc == 0 )) || {
      _file_error "Base64 conversion failed before publication."
      return $transform_rc
    }
    _file_revalidate_mutation_target "$input_file" "$input_identity" || return 1
    _file_sha256_digest "$input_file" || return 1
    [[ "$REPLY" == "$input_digest" ]] || {
      _file_error "Base64 input content changed during conversion."
      return 1
    }
    _file_publish_staged_file \
      "$staged_file" "$output_file" "$output_state" \
      "$output_parent_identity" || return $?
    staged_file=""
    _file_success "Published Base64 output: $output_file"
    transform_rc=0
  } always {
    if [[ -n "$staged_file" && -f "$staged_file" && ! -L "$staged_file" \
      && "${staged_file:h}" == "${output_file:h}" \
      && "${staged_file:t}" == ".${output_file:t}.zdx."* ]]; then
      command rm -f -- "$staged_file" 2>/dev/null || cleanup_rc=1
    fi
    (( cleanup_rc == 0 )) || transform_rc=1
  }
  return $transform_rc
}

file-encode-decode() {
  emulate -L zsh
  _file_header "Base64 Converter"

  if (( $# == 0 )); then
    _file_choose_fixed "Base64 action" \
      "encode-text" "decode-text" "encode-file" "decode-file"
    local -i action_rc=$?
    if (( action_rc != 0 )); then
      (( action_rc == 130 )) && return 0
      return $action_rc
    fi
    local action="$REPLY"
    if [[ "$action" == *"-text" ]]; then
      _file_read_line "Input text" || return $?
      _file_base64_text "$action" "$REPLY"
      return $?
    fi
    _file_select_paths "Select Base64 input file" no files
    local -i select_rc=$?
    if (( select_rc != 0 )); then
      (( select_rc == 130 )) && return 0
      return $select_rc
    fi
    local input_file="${reply[1]}"
    local default_output="${input_file}.b64"
    [[ "$action" == "decode-file" ]] && {
      default_output="${input_file%.b64}"
      [[ "$default_output" != "$input_file" ]] \
        || default_output="${input_file}.decoded"
    }
    _file_read_line "Output file" "$default_output" || return $?
    _file_base64_file "$action" "$input_file" "$REPLY" no no no
    return $?
  fi

  local action="" text_value="" input_file="" output_file=""
  local overwrite=no dry_run=no auto_yes=no
  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        (( $# == 1 )) || return 2
        _file_encode_usage
        return 0
        ;;
      --encode-text|--decode-text)
        (( $# >= 2 )) && [[ -z "$action" ]] || return 2
        action="${1#--}"
        text_value="$2"
        shift 2
        ;;
      --encode-file|--decode-file)
        (( $# >= 2 )) && [[ -z "$action" ]] || return 2
        action="${1#--}"
        input_file="$2"
        shift 2
        ;;
      --output)
        (( $# >= 2 )) || return 2
        output_file="$2"
        shift 2
        ;;
      --overwrite) overwrite=yes; shift ;;
      --dry-run) dry_run=yes; shift ;;
      --yes) auto_yes=yes; shift ;;
      *)
        _file_error "Unknown option: $1"
        return 2
        ;;
    esac
  done
  case "$action" in
    encode-text|decode-text)
      [[ -z "$output_file" && "$overwrite" == no \
        && "$dry_run" == no && "$auto_yes" == no ]] || {
        _file_error "File-output flags do not apply to text conversion."
        return 2
      }
      _file_base64_text "$action" "$text_value"
      ;;
    encode-file|decode-file)
      [[ -n "$input_file" && -n "$output_file" ]] || {
        _file_error "File conversion requires an input and --output."
        return 2
      }
      _file_base64_file \
        "$action" "$input_file" "$output_file" \
        "$overwrite" "$dry_run" "$auto_yes"
      ;;
    *)
      _file_error "Choose exactly one Base64 action."
      return 2
      ;;
  esac
}

_file_hash_compute() {
  local algorithm="$1"
  local input_file="$2"
  REPLY=""
  local raw_output=""
  local -i hash_rc=1

  case "$algorithm" in
    sha256)
      if command -v sha256sum &>/dev/null; then
        raw_output=$(command sha256sum -- "$input_file")
        hash_rc=$?
      elif command -v shasum &>/dev/null; then
        raw_output=$(command shasum -a 256 -- "$input_file")
        hash_rc=$?
      else
        _file_error "A SHA-256 tool (sha256sum or shasum) is required."
        return 1
      fi
      ;;
    md5)
      if command -v md5sum &>/dev/null; then
        raw_output=$(command md5sum -- "$input_file")
        hash_rc=$?
      elif command -v md5 &>/dev/null; then
        raw_output=$(command md5 -q "$input_file")
        hash_rc=$?
      else
        _file_error "An MD5 tool (md5sum or md5) is required."
        return 1
      fi
      ;;
    *)
      return 2
      ;;
  esac
  (( hash_rc == 0 )) || {
    _file_error "Hashing failed."
    return 1
  }
  local digest="${raw_output%%[[:space:]]*}"
  digest="${digest:l}"
  if [[ "$algorithm" == "sha256" ]]; then
    [[ "$digest" =~ '^[0-9a-f]{64}$' ]] || return 1
  else
    [[ "$digest" =~ '^[0-9a-f]{32}$' ]] || return 1
  fi
  REPLY="$digest"
}

_file_checksum_execute() {
  local algorithm="$1"
  local expected="$2"
  local input_arg="$3"
  _file_validate_base "$PWD" || return 1
  local base_dir="$REPLY"
  _file_validate_mutation_target "$input_arg" "$base_dir" || return 1
  local input_plan="$REPLY"
  local input_file="${input_plan%%|*}"
  local input_identity="${input_plan#*|}"
  [[ -f "$input_file" ]] || {
    _file_error "Checksum input must be a regular file."
    return 1
  }

  local legacy_warned=no
  if [[ -n "$expected" ]]; then
    expected="${expected:l}"
    if [[ "$expected" =~ '^[0-9a-f]{64}$' ]]; then
      algorithm="sha256"
    elif [[ "$expected" =~ '^[0-9a-f]{32}$' ]]; then
      algorithm="md5"
      _file_warn "MD5 verification is retained only for legacy compatibility."
      legacy_warned=yes
    else
      _file_error "Expected digest must be 32 or 64 hexadecimal characters."
      return 2
    fi
  fi
  [[ "$algorithm" == "sha256" || "$algorithm" == "md5" ]] || return 2
  [[ "$algorithm" != "md5" || "$legacy_warned" == yes ]] \
    || _file_warn "MD5 is retained only for legacy compatibility."

  _file_revalidate_mutation_target "$input_file" "$input_identity" || return 1
  _file_hash_compute "$algorithm" "$input_file" || return 1
  local actual="$REPLY"
  _file_revalidate_mutation_target "$input_file" "$input_identity" || return 1
  _file_hash_compute "$algorithm" "$input_file" || return 1
  [[ "$REPLY" == "$actual" ]] || {
    _file_error "File content changed while it was being hashed."
    return 1
  }

  if [[ -n "$expected" ]]; then
    [[ "$actual" == "$expected" ]] || {
      _file_error "Checksum verification failed."
      return 1
    }
    _file_success "Checksum verified with ${algorithm:u}."
    return 0
  fi
  print -r -- "$actual"
}

file-checksum() {
  emulate -L zsh
  _file_header "File Integrity Checksums"

  if (( $# == 0 )); then
    _file_select_paths "Select checksum input" no files
    local -i select_rc=$?
    if (( select_rc != 0 )); then
      (( select_rc == 130 )) && return 0
      return $select_rc
    fi
    local input_file="${reply[1]}"
    _file_choose_fixed "Checksum action" "sha256" "md5" "verify"
    local -i action_rc=$?
    if (( action_rc != 0 )); then
      (( action_rc == 130 )) && return 0
      return $action_rc
    fi
    local algorithm="$REPLY"
    local expected=""
    if [[ "$algorithm" == "verify" ]]; then
      _file_read_line "Expected digest" || return $?
      expected="$REPLY"
      algorithm=""
    fi
    _file_checksum_execute "$algorithm" "$expected" "$input_file"
    return $?
  fi

  local algorithm="" expected="" input_file=""
  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        (( $# == 1 )) || return 2
        _file_checksum_usage
        return 0
        ;;
      --algorithm)
        (( $# >= 2 )) && [[ -z "$expected" ]] || return 2
        algorithm="${2:l}"
        shift 2
        ;;
      --verify)
        (( $# >= 2 )) && [[ -z "$algorithm" ]] || return 2
        expected="$2"
        shift 2
        ;;
      --)
        shift
        (( $# == 1 )) && [[ -z "$input_file" ]] || return 2
        input_file="$1"
        shift
        ;;
      -*)
        _file_error "Unknown option: $1"
        return 2
        ;;
      *)
        [[ -z "$input_file" ]] || return 2
        input_file="$1"
        shift
        ;;
    esac
  done
  [[ -n "$input_file" \
    && ( -n "$algorithm" || -n "$expected" ) ]] || {
    _file_error "Choose one checksum action and exactly one input file."
    return 2
  }
  _file_checksum_execute "$algorithm" "$expected" "$input_file"
}

typeset -g _FILE_DATA_SOURCED=1
