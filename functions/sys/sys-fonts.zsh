#!/usr/bin/env zsh
# =============================================================================
# System Fonts: pinned and checksum-verified Nerd Font management
# =============================================================================
#
# Loaded by sys-menu.zsh after sys-common.zsh, sys-capabilities.zsh, and the
# platform adapters.
# Safe to re-source; defines functions and configuration defaults only.
#

if [[ -n "${_SYS_FONTS_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset -g SYS_NERD_FONTS_VERSION="${SYS_NERD_FONTS_VERSION:-3.4.0}"
typeset -g SYS_NERD_FONTS_MAX_ARCHIVE_BYTES="${SYS_NERD_FONTS_MAX_ARCHIVE_BYTES:-268435456}"
typeset -g SYS_NERD_FONTS_MAX_EXPANDED_BYTES="${SYS_NERD_FONTS_MAX_EXPANDED_BYTES:-536870912}"
typeset -g SYS_NERD_FONTS_MAX_PATH_BYTES="${SYS_NERD_FONTS_MAX_PATH_BYTES:-4096}"
typeset -g SYS_NERD_FONTS_MAX_INVENTORY_BYTES="${SYS_NERD_FONTS_MAX_INVENTORY_BYTES:-8388608}"
typeset -g SYS_NERD_FONTS_MAX_INSTALLED_FILES="${SYS_NERD_FONTS_MAX_INSTALLED_FILES:-10000}"
typeset -ga _SYS_NERD_FONT_FAMILIES=(
  CascadiaCode
  FiraCode
  Hack
  JetBrainsMono
  Meslo
)

_sys_fonts_usage() {
  print -u2 -r -- 'Usage:'
  print -u2 -r -- '  sys-fonts                         Select a family interactively'
  print -u2 -r -- '  sys-fonts --list                  Emit installed font files as TSV'
  print -u2 -r -- '  sys-fonts --install FAMILY [--dry-run] [-y|--yes]'
  print -u2 -r -- '  sys-fonts -h|--help'
  print -u2 -r -- ''
  print -u2 -r -- 'The --list schema is: family<TAB>absolute-path.'
  print -u2 -r -- "Supported families: ${(j:, :)_SYS_NERD_FONT_FAMILIES}"
  print -u2 -r -- 'Downloads use a pinned Nerd Fonts release and its upstream SHA-256 file.'
}

_sys_fonts_base_dir() {
  local fonts_backend
  fonts_backend=$(_sys_capability_value fonts_backend) || return 1
  case "$fonts_backend" in
    fontconfig)
      print -r -- "$HOME/.local/share/fonts"
      ;;
    macos-user-fonts)
      print -r -- "$HOME/Library/Fonts"
      ;;
    *)
      _sys_error "No supported user-font backend is available on this host."
      return 1
      ;;
  esac
}

_sys_fonts_family_valid() {
  local requested="$1"
  local family
  for family in "${_SYS_NERD_FONT_FAMILIES[@]}"; do
    [[ "$requested" == "$family" ]] && return 0
  done
  return 1
}

_sys_fonts_validate_base_path() {
  local fonts_dir="$1"
  local home_abs="${HOME:A}"
  local current="$HOME"
  local relative_path="${fonts_dir#$HOME/}"
  local component

  [[ "$fonts_dir" == "$HOME"/* && -n "$relative_path" ]] || {
    _sys_error "The user-font directory must remain below HOME."
    return 1
  }
  for component in "${(@s:/:)relative_path}"; do
    current+="/$component"
    [[ ! -L "$current" ]] || {
      _sys_error "The user-font path crosses a symbolic link."
      return 1
    }
    if [[ -e "$current" ]]; then
      [[ -d "$current" && -O "$current" ]] || {
        _sys_error "The user-font path crosses a non-owned directory."
        return 1
      }
    fi
  done
  [[ "${fonts_dir:A}" == "$home_abs"/* ]] || {
    _sys_error "The user-font directory resolves outside HOME."
    return 1
  }
}

_sys_fonts_destination_managed() {
  local destination="$1"
  local family="$2"
  local marker="$destination/.zdx-managed-font-family"
  [[ -d "$destination" && ! -L "$destination" && -O "$destination" \
    && -f "$marker" && ! -L "$marker" && -O "$marker" ]] || return 1
  command grep -qx 'zdx-managed-font-family-v1' "$marker" 2>/dev/null \
    && command grep -qx "family=$family" "$marker" 2>/dev/null
}

_sys_fonts_recovery_managed() {
  local recovery_dir="$1"
  local fonts_dir="$2"
  local family="$3"
  local recovery_root="${fonts_dir:h}"
  [[ -d "$recovery_dir" && ! -L "$recovery_dir" && -O "$recovery_dir" \
    && "${recovery_dir:h:A}" == "${recovery_root:A}" \
    && "${recovery_dir:t}" == .zdx-font-previous-${family}.* ]] \
    && _sys_fonts_destination_managed "$recovery_dir" "$family"
}

# stdout TSV: family, absolute path.
_sys_fonts_records() {
  setopt LOCAL_OPTIONS PIPE_FAIL
  local LC_ALL=C
  local fonts_dir
  fonts_dir=$(_sys_fonts_base_dir) || return 1
  _sys_fonts_validate_base_path "$fonts_dir" || return 1
  [[ -d "$fonts_dir" ]] || return 0
  [[ ! -L "$fonts_dir" && -O "$fonts_dir" ]] || {
    _sys_error "The user-font directory must be user-owned and must not be a link."
    return 1
  }
  [[ "$SYS_NERD_FONTS_MAX_PATH_BYTES" =~ '^[0-9]+$' \
    && "$SYS_NERD_FONTS_MAX_PATH_BYTES" != 0[0-9]* \
    && ${#SYS_NERD_FONTS_MAX_PATH_BYTES} -le 5 \
    && "$SYS_NERD_FONTS_MAX_PATH_BYTES" -gt 0 \
    && "$SYS_NERD_FONTS_MAX_PATH_BYTES" -le 65535 \
    && "$SYS_NERD_FONTS_MAX_INVENTORY_BYTES" =~ '^[0-9]+$' \
    && "$SYS_NERD_FONTS_MAX_INVENTORY_BYTES" != 0[0-9]* \
    && ${#SYS_NERD_FONTS_MAX_INVENTORY_BYTES} -le 8 \
    && "$SYS_NERD_FONTS_MAX_INVENTORY_BYTES" -gt 0 \
    && "$SYS_NERD_FONTS_MAX_INVENTORY_BYTES" -le 67108864 \
    && "$SYS_NERD_FONTS_MAX_INSTALLED_FILES" =~ '^[0-9]+$' \
    && "$SYS_NERD_FONTS_MAX_INSTALLED_FILES" != 0[0-9]* \
    && ${#SYS_NERD_FONTS_MAX_INSTALLED_FILES} -le 6 \
    && "$SYS_NERD_FONTS_MAX_INSTALLED_FILES" -gt 0 \
    && "$SYS_NERD_FONTS_MAX_INSTALLED_FILES" -le 100000 ]] || {
    _sys_error "Installed-font inventory limits must be positive integers."
    return 1
  }

  local inventory_file
  inventory_file=$(command mktemp \
    "${TMPDIR:-/tmp}/zdx-installed-fonts.XXXXXX") || return 1
  command chmod 600 "$inventory_file" 2>/dev/null || {
    command rm -f "$inventory_file" 2>/dev/null
    return 1
  }
  local records_rc=0
  local -a font_records=()
  {
    command find "$fonts_dir" -type f \
      \( -name '*.ttf' -o -name '*.otf' \) -print0 2>/dev/null \
      | command head -c "$(( SYS_NERD_FONTS_MAX_INVENTORY_BYTES + 1 ))" \
        > "$inventory_file"
    local inventory_rc=$?
    local inventory_bytes
    inventory_bytes=$(command wc -c < "$inventory_file" 2>/dev/null) \
      || return 1
    inventory_bytes="${inventory_bytes//[[:space:]]/}"
    [[ "$inventory_bytes" =~ '^[0-9]+$' \
      && "$inventory_bytes" -le "$SYS_NERD_FONTS_MAX_INVENTORY_BYTES" ]] \
      || {
        _sys_error "Installed-font inventory exceeds its configured byte limit."
        return 1
      }
    (( inventory_rc == 0 )) || {
      _sys_error "Unable to inspect the installed-font tree safely."
      return 1
    }

    local font_file family_name
    local -i font_count=0
    while IFS= read -r -d $'\0' font_file; do
      (( ++font_count <= SYS_NERD_FONTS_MAX_INSTALLED_FILES )) || {
        _sys_error "Installed-font inventory exceeds its configured file limit."
        return 1
      }
      [[ ${#font_file} -le SYS_NERD_FONTS_MAX_PATH_BYTES ]] || {
        _sys_error "Installed-font inventory contains an oversized path."
        return 1
      }
      [[ "$font_file" != *[[:cntrl:]]* ]] || continue
      family_name="${font_file:h:t}"
      [[ "$family_name" != *[[:cntrl:]]* ]] || continue
      [[ -f "$font_file" && ! -L "$font_file" && -O "$font_file" \
        && "${font_file:A}" == "${fonts_dir:A}"/* ]] || continue
      font_records+=("$family_name"$'\t'"$font_file")
    done < "$inventory_file"

    local font_record
    font_records=("${(o)font_records}")
    for font_record in "${font_records[@]}"; do
      print -r -- "$font_record"
    done
  } always {
    records_rc=$?
    command rm -f "$inventory_file" 2>/dev/null
  }
  return $records_rc
}

_sys_fonts_render_installed() {
  local records_output
  records_output=$(_sys_fonts_records) || return 1
  if [[ -z "$records_output" ]]; then
    _sys_warn "No user-installed Nerd Font files were found."
    return 0
  fi

  local -a records=("${(@f)records_output}")
  _sys_info "Installed user font files: ${#records[@]}"
  local record family_name font_path
  for record in "${records[@]:0:30}"; do
    IFS=$'\t' read -r family_name font_path <<< "$record"
    _sys_dim "${family_name}: ${font_path:t}"
  done
  (( ${#records[@]} > 30 )) \
    && _sys_dim "... and $(( ${#records[@]} - 30 )) more"
}

_sys_fonts_validate_archive() {
  setopt LOCAL_OPTIONS PIPE_FAIL
  local archive="$1"
  local listing_file
  listing_file=$(command mktemp "${TMPDIR:-/tmp}/zdx-font-listing.XXXXXX") \
    || return 1
  command chmod 600 "$listing_file" 2>/dev/null || {
    command rm -f "$listing_file" 2>/dev/null
    return 1
  }
  local validate_rc=0
  {
    LC_ALL=C _sys_run_with_timeout 120 tar -tJf "$archive" 2>/dev/null \
      | command awk -v max_bytes="$SYS_NERD_FONTS_MAX_INVENTORY_BYTES" '
        BEGIN { bytes = 0; entries = 0 }
        {
          bytes += length($0) + 1
          entries++
          if (bytes > max_bytes || entries > 1000) exit 42
          print
        }
        END { if (entries == 0) exit 43 }
      ' > "$listing_file" || {
        _sys_error "The font archive listing is invalid or exceeds its limits."
        return 1
      }
    local -a entries=("${(@f)$(<"$listing_file")}")

    local entry normalized component
    for entry in "${entries[@]}"; do
      normalized="${entry%/}"
      [[ -n "$normalized" && "$normalized" != /* && "$normalized" != -* \
        && "$normalized" != *[[:cntrl:]]* && "$normalized" != *'|'* \
        && ${#normalized} -le SYS_NERD_FONTS_MAX_PATH_BYTES ]] || {
        _sys_error "The font archive contains an unsafe path."
        return 1
      }
      for component in "${(@s:/:)normalized}"; do
        [[ -n "$component" && "$component" != "." && "$component" != ".." ]] \
          || {
            _sys_error "The font archive contains path traversal."
            return 1
          }
      done
    done

    LC_ALL=C _sys_run_with_timeout 120 tar -tvJf "$archive" 2>/dev/null \
      | command awk -v max_bytes="$SYS_NERD_FONTS_MAX_INVENTORY_BYTES" '
        BEGIN { bytes = 0; entries = 0 }
        {
          bytes += length($0) + 1
          entries++
          if (bytes > max_bytes || entries > 1000) exit 42
          type = substr($0, 1, 1)
          if (type != "-" && type != "d") exit 41
        }
        END { if (entries == 0) exit 43 }
      ' || {
        _sys_error "The font archive contains a link, special file, or oversized listing."
        return 1
      }

    local REPLY
    _sys_tar_measure_expanded_bytes "$archive" \
      "$SYS_NERD_FONTS_MAX_EXPANDED_BYTES" xz
    case $? in
      0) ;;
      2)
        _sys_error "Expanded font data exceeds the configured size limit."
        return 1
        ;;
      *)
        _sys_error "Unable to inspect the expanded font archive within the time limit."
        return 1
        ;;
    esac
  } always {
    validate_rc=$?
    command rm -f "$listing_file" 2>/dev/null
  }
  return $validate_rc
}

_sys_fonts_inspect_extraction() {
  local LC_ALL=C
  local extraction_dir="$1"
  local extraction_abs="${extraction_dir:A}"
  local inventory_file
  inventory_file=$(command mktemp "${TMPDIR:-/tmp}/zdx-font-inventory.XXXXXX") \
    || return 1
  command chmod 600 "$inventory_file" 2>/dev/null || {
    command rm -f "$inventory_file" 2>/dev/null
    return 1
  }

  local inspect_rc=0
  {
    command find "$extraction_dir" -mindepth 1 -print0 > "$inventory_file" \
      2>/dev/null || {
        _sys_error "Unable to inspect the extracted font tree."
        return 1
      }
    local inventory_bytes
    inventory_bytes=$(command wc -c < "$inventory_file" 2>/dev/null) \
      || return 1
    inventory_bytes="${inventory_bytes//[[:space:]]/}"
    [[ "$inventory_bytes" =~ '^[0-9]+$' \
      && "$inventory_bytes" -gt 0 \
      && "$inventory_bytes" -le "$SYS_NERD_FONTS_MAX_INVENTORY_BYTES" ]] \
      || {
        _sys_error "Extracted font path inventory is empty or exceeds its limit."
        return 1
      }

    local -a usable_fonts=()
    local extracted_entry relative_entry component font_name existing_name
    local -a components=() usable_names=()
    local -A entry_state=()
    local -i entry_count=0
    while IFS= read -r -d $'\0' extracted_entry; do
      (( ++entry_count <= 2000 )) || {
        _sys_error "Extracted font entry count exceeds its limit."
        return 1
      }
      [[ "$extracted_entry" == "$extraction_abs"/* ]] || return 1
      relative_entry="${extracted_entry#$extraction_abs/}"
      [[ -n "$relative_entry" && "$relative_entry" != /* \
        && "$relative_entry" != -* \
        && "$relative_entry" != *[[:cntrl:]]* \
        && "$relative_entry" != *'|'* \
        && ${#relative_entry} -le SYS_NERD_FONTS_MAX_PATH_BYTES ]] || {
        _sys_error "Extracted font archive contains an unsafe filename."
        return 1
      }
      components=("${(@s:/:)relative_entry}")
      for component in "${components[@]}"; do
        [[ -n "$component" && "$component" != "." && "$component" != ".." ]] \
          || {
            _sys_error "Extracted font archive contains path traversal."
            return 1
          }
      done
      [[ ! -L "$extracted_entry" && -O "$extracted_entry" ]] || {
        _sys_error "Extracted font archive contains a link or foreign-owned entry."
        return 1
      }
      if [[ -d "$extracted_entry" ]]; then
        continue
      elif [[ ! -f "$extracted_entry" ]]; then
        _sys_error "Extracted font archive contains a special file."
        return 1
      fi

      entry_state=()
      zmodload zsh/stat 2>/dev/null \
        && zstat -H entry_state "$extracted_entry" 2>/dev/null || return 1
      (( entry_state[nlink] == 1 )) || {
        _sys_error "Extracted font archive contains a multiply-linked file."
        return 1
      }
      font_name="${extracted_entry:t}"
      [[ "$font_name" == *.ttf || "$font_name" == *.otf ]] || continue
      [[ "$font_name" != *"NerdFontPropo"* ]] || continue
      for existing_name in "${usable_names[@]}"; do
        [[ "$font_name" != "$existing_name" ]] || {
          _sys_error "The font archive contains duplicate destination names."
          return 1
        }
      done
      usable_names+=("$font_name")
      usable_fonts+=("$extracted_entry")
      (( ${#usable_fonts[@]} <= 500 )) || {
        _sys_error "The font archive contains too many usable font files."
        return 1
      }
    done < "$inventory_file"

    (( ${#usable_fonts[@]} > 0 )) || {
      _sys_error "The verified archive contains no supported font variants."
      return 1
    }
    reply=("${usable_fonts[@]}")
  } always {
    inspect_rc=$?
    command rm -f "$inventory_file" 2>/dev/null
  }
  return $inspect_rc
}

_sys_fonts_install() {
  setopt LOCAL_OPTIONS EXTENDED_GLOB NULL_GLOB
  local family="$1"
  local dry_run="$2"
  local assume_yes="$3"
  local -a reply=()
  _sys_fonts_family_valid "$family" || {
    _sys_error "Unsupported Nerd Font family: $(_sys_display_escape "$family")"
    return 2
  }
  [[ "$SYS_NERD_FONTS_VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || {
    _sys_error "SYS_NERD_FONTS_VERSION must be a pinned semantic version."
    return 1
  }
  [[ "$SYS_NERD_FONTS_MAX_ARCHIVE_BYTES" =~ '^[0-9]+$' \
    && "$SYS_NERD_FONTS_MAX_ARCHIVE_BYTES" != 0[0-9]* \
    && ${#SYS_NERD_FONTS_MAX_ARCHIVE_BYTES} -le 10 \
    && "$SYS_NERD_FONTS_MAX_ARCHIVE_BYTES" -gt 0 \
    && "$SYS_NERD_FONTS_MAX_EXPANDED_BYTES" =~ '^[0-9]+$' \
    && "$SYS_NERD_FONTS_MAX_EXPANDED_BYTES" != 0[0-9]* \
    && ${#SYS_NERD_FONTS_MAX_EXPANDED_BYTES} -le 10 \
    && "$SYS_NERD_FONTS_MAX_EXPANDED_BYTES" -gt 0 \
    && "$SYS_NERD_FONTS_MAX_PATH_BYTES" =~ '^[0-9]+$' \
    && "$SYS_NERD_FONTS_MAX_PATH_BYTES" != 0[0-9]* \
    && ${#SYS_NERD_FONTS_MAX_PATH_BYTES} -le 5 \
    && "$SYS_NERD_FONTS_MAX_PATH_BYTES" -gt 0 \
    && "$SYS_NERD_FONTS_MAX_PATH_BYTES" -le 65535 \
    && "$SYS_NERD_FONTS_MAX_INVENTORY_BYTES" =~ '^[0-9]+$' \
    && "$SYS_NERD_FONTS_MAX_INVENTORY_BYTES" != 0[0-9]* \
    && ${#SYS_NERD_FONTS_MAX_INVENTORY_BYTES} -le 8 \
    && "$SYS_NERD_FONTS_MAX_INVENTORY_BYTES" -gt 0 \
    && "$SYS_NERD_FONTS_MAX_INVENTORY_BYTES" -le 67108864 ]] || {
    _sys_error "Nerd Font archive limits must be positive integers."
    return 1
  }
  local fonts_dir
  fonts_dir=$(_sys_fonts_base_dir) || return 1
  _sys_fonts_validate_base_path "$fonts_dir" || return 1
  local asset="${family}.tar.xz"
  local release_base="https://github.com/ryanoasis/nerd-fonts/releases/download/v${SYS_NERD_FONTS_VERSION}"
  local archive_url="${release_base}/${asset}"
  local checksum_url="${release_base}/SHA-256.txt"
  local destination="$fonts_dir/$family"
  local -i destination_managed=0
  if [[ -e "$destination" || -L "$destination" ]]; then
    [[ -d "$destination" && ! -L "$destination" && -O "$destination" ]] \
      || {
        _sys_error "Existing font destination is unsafe."
        return 1
      }
    _sys_fonts_destination_managed "$destination" "$family" \
      && destination_managed=1
  fi

  _sys_header "Nerd Font Install Plan"
  _sys_label "Family:" "$family"
  _sys_label "Pinned release:" "v${SYS_NERD_FONTS_VERSION}"
  _sys_label "Destination:" "$fonts_dir/$family"
  _sys_dim "The artifact is verified against the release SHA-256 manifest before extraction."
  if [[ -e "$destination" ]] && (( ! destination_managed )); then
    _sys_warn "The existing destination is not ZDX-managed."
    _sys_dim "It will be preserved as a sibling recovery directory, not deleted."
  fi
  if (( dry_run )); then
    _sys_info "Dry run complete; no network access or filesystem mutation occurred."
    return 0
  fi
  # Name a missing download, extraction, or digest tool before asking for
  # authorization, so a confirmed plan cannot fail on a known precondition.
  _sys_require_commands curl tar || return 1
  _sys_require_sha256_tool || return 1
  if (( ! assume_yes )); then
    if [[ ! -t 0 || ! -t 2 ]]; then
      _sys_error "Non-interactive font installation requires --yes."
      return 1
    fi
    _sys_confirm "Download and install this exact verified font release?" || {
      _sys_info "Cancelled."
      return 0
    }
  fi

  local temp_root="${TMPDIR:-/tmp}"
  local download_dir
  download_dir=$(command mktemp -d "$temp_root/zdx-font-download.XXXXXX") \
    || return 1
  [[ -d "$download_dir" && ! -L "$download_dir" \
    && "${download_dir:h:A}" == "${temp_root:A}" \
    && "${download_dir:t}" == zdx-font-download.* ]] || {
      [[ -d "$download_dir" && ! -L "$download_dir" ]] \
        && command rm -rf "$download_dir" 2>/dev/null
      return 1
    }
  local download_archive="$download_dir/$asset"
  local checksum_file="$download_dir/SHA-256.txt"
  local extraction_dir="$download_dir/extracted"
  local installation_stage=""
  local previous_destination=""
  local preserved_previous=""
  local -i previous_was_managed=0
  local -i install_rc=0
  local previous_umask
  previous_umask=$(umask)

  {
    umask 077
    command chmod 700 "$download_dir" 2>/dev/null || return 1
    _sys_info "Downloading the pinned $asset artifact..."
    _sys_run_with_timeout 180 curl --proto '=https' --tlsv1.2 \
      -fL --retry 2 --max-time 170 \
      --max-filesize "$SYS_NERD_FONTS_MAX_ARCHIVE_BYTES" \
      "$archive_url" -o "$download_archive" \
      2>/dev/null || {
        _sys_error "Font artifact download failed."
        return 1
      }
    _sys_run_with_timeout 60 curl --proto '=https' --tlsv1.2 \
      -fL --retry 2 --max-time 50 --max-filesize 5242880 \
      "$checksum_url" -o "$checksum_file" \
      2>/dev/null || {
        _sys_error "Upstream checksum manifest download failed."
        return 1
      }

    local archive_bytes
    archive_bytes=$(command wc -c < "$download_archive" 2>/dev/null) \
      || return 1
    archive_bytes="${archive_bytes//[[:space:]]/}"
    [[ "$archive_bytes" =~ '^[0-9]+$' \
      && "$archive_bytes" -le "$SYS_NERD_FONTS_MAX_ARCHIVE_BYTES" ]] || {
      _sys_error "Font artifact exceeds the configured size limit."
      return 1
    }

    local expected_digest actual_digest
    expected_digest=$(command awk -v asset="$asset" '
      {
        name = $2
        sub(/^\*/, "", name)
        if (name == asset && $1 ~ /^[[:xdigit:]]{64}$/) {
          print tolower($1)
          exit
        }
      }
    ' "$checksum_file" 2>/dev/null)
    [[ "$expected_digest" =~ '^[[:xdigit:]]{64}$' ]] || {
      _sys_error "The upstream manifest has no checksum for $asset."
      return 1
    }
    actual_digest=$(_sys_sha256_file "$download_archive") || return 1
    [[ "$actual_digest" == "$expected_digest" ]] || {
      _sys_error "Font artifact checksum mismatch."
      return 1
    }
    _sys_success "SHA-256 verification passed."
    _sys_fonts_validate_archive "$download_archive" || return 1

    command mkdir "$extraction_dir" 2>/dev/null || return 1
    command tar -xJf "$download_archive" -C "$extraction_dir" \
      --no-same-owner --no-same-permissions 2>/dev/null || return 1
    _sys_fonts_inspect_extraction "$extraction_dir" || return 1
    local -a font_files=("${reply[@]}")

    if [[ -e "$fonts_dir" ]]; then
      [[ -d "$fonts_dir" && ! -L "$fonts_dir" && -O "$fonts_dir" ]] || {
        _sys_error "User font directory is unsafe."
        return 1
      }
    else
      command mkdir -p -m 700 "$fonts_dir" 2>/dev/null || return 1
    fi
    _sys_fonts_validate_base_path "$fonts_dir" || return 1
    local stage_candidate
    stage_candidate=$(command mktemp -d "$fonts_dir/.zdx-font.XXXXXX") \
      || return 1
    [[ -d "$stage_candidate" && ! -L "$stage_candidate" \
      && "${stage_candidate:h:A}" == "${fonts_dir:A}" \
      && "${stage_candidate:t}" == .zdx-font.* ]] || {
        [[ -d "$stage_candidate" && ! -L "$stage_candidate" ]] \
          && command rm -rf "$stage_candidate" 2>/dev/null
        return 1
      }
    installation_stage="$stage_candidate"

    local font_file
    local -i copied_count=0
    local copied_name
    for font_file in "${font_files[@]}"; do
      copied_name="${font_file:t}"
      command cp "$font_file" "$installation_stage/$copied_name" \
        2>/dev/null || return 1
      (( ++copied_count ))
    done
    (( copied_count > 0 )) || {
      _sys_error "The verified archive contains no supported font variants."
      return 1
    }
    {
      print -r -- "zdx-managed-font-family-v1"
      print -r -- "family=$family"
      print -r -- "version=$SYS_NERD_FONTS_VERSION"
    } > "$installation_stage/.zdx-managed-font-family" || return 1
    command chmod 600 "$installation_stage/.zdx-managed-font-family" \
      2>/dev/null || return 1

    if [[ -e "$destination" || -L "$destination" ]]; then
      [[ -d "$destination" && ! -L "$destination" && -O "$destination" ]] \
        || {
          _sys_error "Existing font destination is unsafe."
          return 1
        }
      previous_was_managed=0
      _sys_fonts_destination_managed "$destination" "$family" \
        && previous_was_managed=1
      local previous_candidate
      previous_candidate=$(command mktemp -d \
        "${fonts_dir:h}/.zdx-font-previous-${family}.XXXXXX") \
        || return 1
      [[ -d "$previous_candidate" && ! -L "$previous_candidate" \
        && "${previous_candidate:h:A}" == "${fonts_dir:h:A}" \
        && "${previous_candidate:t}" == .zdx-font-previous-${family}.* ]] || {
          [[ -d "$previous_candidate" && ! -L "$previous_candidate" ]] \
            && command rmdir "$previous_candidate" 2>/dev/null
          return 1
        }
      previous_destination="$previous_candidate"
      command rmdir "$previous_destination" 2>/dev/null || return 1
      command mv "$destination" "$previous_destination" 2>/dev/null || return 1
    fi
    if ! command mv "$installation_stage" "$destination" 2>/dev/null; then
      if [[ -n "$previous_destination" && -d "$previous_destination" ]]; then
        if command mv "$previous_destination" "$destination" 2>/dev/null; then
          previous_destination=""
        else
          _sys_error "Automatic rollback failed; the prior font tree was preserved at:"
          _sys_dim "$previous_destination"
        fi
      fi
      return 1
    fi
    installation_stage=""

    if _sys_has_capability "fonts:fontconfig" && command -v fc-cache &>/dev/null; then
      command fc-cache -f "$fonts_dir" >/dev/null 2>&1 \
        || _sys_warn "Font files installed, but fc-cache refresh failed."
    fi
  } always {
    install_rc=$?
    [[ -n "$installation_stage" && -d "$installation_stage" ]] \
      && command rm -rf "$installation_stage" 2>/dev/null
    if [[ -n "$previous_destination" && -d "$previous_destination" ]]; then
      if (( install_rc != 0 )); then
        if [[ ! -e "$destination" && ! -L "$destination" ]] \
          && command mv "$previous_destination" "$destination" 2>/dev/null; then
          previous_destination=""
        else
          _sys_warn "The prior font tree remains available for manual recovery:"
          _sys_dim "$previous_destination"
        fi
      else
        if (( previous_was_managed )) \
          && _sys_fonts_recovery_managed \
            "$previous_destination" "$fonts_dir" "$family" \
          && command rm -rf "$previous_destination" 2>/dev/null; then
          previous_destination=""
        else
          preserved_previous="$previous_destination"
        fi
      fi
    fi
    command rm -rf "$download_dir" 2>/dev/null
    umask "$previous_umask"
  }

  (( install_rc == 0 )) || {
    _sys_error "Nerd Font installation failed; the prior tree was restored or preserved for recovery."
    return "$install_rc"
  }
  if [[ -n "$preserved_previous" ]]; then
    _sys_warn "The prior font tree was preserved instead of being deleted:"
    _sys_dim "$preserved_previous"
  fi
  _sys_success "$family Nerd Font v${SYS_NERD_FONTS_VERSION} installed."
}

_sys_fonts_select_family() {
  command -v fzf &>/dev/null || {
    _sys_error "fzf is required for interactive font selection."
    return 1
  }
  local family
  local -a records=()
  for family in "${_SYS_NERD_FONT_FAMILIES[@]}"; do
    records+=("$family"$'\t'"Pinned release v${SYS_NERD_FONTS_VERSION}")
  done
  local selected=""
  local -i select_rc=0
  _sys_fzf_capture \
    --delimiter=$'\t' \
    --with-nth=1,2 \
    --prompt='nerd font > ' \
    --header='Up/Down navigate | Type to filter | Enter install | Esc cancel' \
    --no-preview \
    < <(printf '%s\n' "${records[@]}") || select_rc=$?
  selected="$REPLY"
  if (( select_rc == 1 || select_rc == 130 )); then
    return 3
  elif (( select_rc != 0 )); then
    _sys_error \
      "fzf failed while selecting a Nerd Font family (status $select_rc)."
    return 1
  fi
  [[ -n "$selected" ]] || return 3
  (( ${records[(Ie)$selected]} > 0 )) || {
    _sys_error "The selected font family was not in the menu snapshot."
    return 1
  }
  REPLY="${selected%%$'\t'*}"
}

sys-fonts() {
  local mode="interactive" family=""
  local -i mode_selected=0
  local -i dry_run=0 assume_yes=0
  local REPLY
  while (( $# )); do
    case "$1" in
      -h|--help)
        (( $# == 1 && ! mode_selected && ! dry_run && ! assume_yes )) || {
          _sys_error "--help does not accept additional arguments."
          return 2
        }
        _sys_fonts_usage
        return 0
        ;;
      --list)
        (( ! mode_selected )) || {
          _sys_error "Choose exactly one of --list or --install."
          return 2
        }
        mode="list"
        mode_selected=1
        ;;
      --install)
        (( ! mode_selected )) || {
          _sys_error "Choose exactly one of --list or --install."
          return 2
        }
        (( $# >= 2 )) || {
          _sys_error "--install requires a supported family."
          return 2
        }
        mode="install"
        mode_selected=1
        family="$2"
        shift
        ;;
      --dry-run) dry_run=1 ;;
      -y|--yes)  assume_yes=1 ;;
      *)
        _sys_error "Unknown option: $1"
        return 2
        ;;
    esac
    shift
  done

  case "$mode" in
    list)
      (( ! dry_run && ! assume_yes )) || {
        _sys_error "--dry-run and --yes require --install."
        return 2
      }
      _sys_fonts_records
      ;;
    install)
      _sys_fonts_install "$family" "$dry_run" "$assume_yes"
      ;;
    interactive)
      (( ! dry_run && ! assume_yes )) || {
        _sys_error "--dry-run and --yes require --install."
        return 2
      }
      _sys_header "Nerd Fonts"
      _sys_fonts_render_installed || return 1
      _sys_fonts_select_family
      local select_rc=$?
      (( select_rc == 3 )) && return 0
      (( select_rc == 0 )) || return "$select_rc"
      _sys_fonts_install "$REPLY" 0 0
      ;;
  esac
}

typeset -g _SYS_FONTS_SOURCED=1
