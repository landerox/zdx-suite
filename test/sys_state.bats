#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper

  export MOCK_CURL_LOG="$TEST_TEMP_DIR/curl_calls"
  export MOCK_CURL_MODE="deny"
  export MOCK_FONT_ARTIFACT="$TEST_TEMP_DIR/font-artifact.tar.xz"
  export MOCK_FONT_SHA256=""
  : > "$MOCK_CURL_LOG"
  printf 'deliberately invalid font artifact\n' > "$MOCK_FONT_ARTIFACT"

  cat > "$TEST_MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -u

{
  printf 'curl'
  printf ' %q' "$@"
  printf '\n'
} >> "${MOCK_CURL_LOG:?}"

output_file=""
request_url=""
arguments=("$@")
index=0
while (( index < ${#arguments[@]} )); do
  case "${arguments[index]}" in
    -o)
      (( index + 1 < ${#arguments[@]} )) || exit 98
      output_file="${arguments[index + 1]}"
      (( index += 2 ))
      ;;
    https://*)
      request_url="${arguments[index]}"
      (( index += 1 ))
      ;;
    *)
      (( index += 1 ))
      ;;
  esac
done

case "${MOCK_CURL_MODE:-deny}" in
  font-valid)
    [[ -n "$output_file" && -n "$request_url" ]] || exit 98
    case "$request_url" in
      */CascadiaCode.tar.xz)
        cp -- "${MOCK_FONT_ARTIFACT:?}" "$output_file"
        ;;
      */SHA-256.txt)
        printf '%s  CascadiaCode.tar.xz\n' "${MOCK_FONT_SHA256:?}" \
          > "$output_file"
        ;;
      *)
        exit 98
        ;;
    esac
    ;;
  font-mismatch)
    [[ -n "$output_file" && -n "$request_url" ]] || exit 98
    case "$request_url" in
      */CascadiaCode.tar.xz)
        cp -- "${MOCK_FONT_ARTIFACT:?}" "$output_file"
        ;;
      */SHA-256.txt)
        printf '%064d  CascadiaCode.tar.xz\n' 0 > "$output_file"
        ;;
      *)
        exit 98
        ;;
    esac
    ;;
  deny)
    printf 'mock curl denied network access\n' >&2
    exit 97
    ;;
  *)
    printf 'mock curl: unsupported mode: %s\n' "$MOCK_CURL_MODE" >&2
    exit 98
    ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/curl"
}

teardown() {
  cleanup_sandbox
}

# Load only the common services and state modules. This keeps eager suite
# loading from polluting mock call records before the command under test.
run_sys_state_zsh() {
  local command_text="$1"

  zsh -c "
    export HOME='$HOME'
    export PATH='$PATH'
    export ZSH_CUSTOM='$TEST_SUITE_ROOT'
    export TEST_MOCK_BIN='$TEST_MOCK_BIN'

    source '$TEST_SUITE_ROOT/functions/sys-common.zsh' || exit 90
    source '$TEST_SUITE_ROOT/functions/sys/sys-capabilities.zsh' || exit 91
    source '$TEST_SUITE_ROOT/functions/sys/sys-dots.zsh' || exit 92
    source '$TEST_SUITE_ROOT/functions/sys/sys-fonts.zsh' || exit 93
    source '$TEST_SUITE_ROOT/functions/sys/sys-telemetry.zsh' || exit 94
    source '$TEST_SUITE_ROOT/functions/sys/sys-plugins.zsh' || exit 95

    $command_text
  " < /dev/null
}

# The telemetry writer is core-owned. Load functions.zsh lazily so no suite
# entrypoint or feature module is sourced as a side effect of the fixture.
run_core_state_zsh() {
  local command_text="$1"

  zsh -c "
    export HOME='$HOME'
    export PATH='$PATH'
    export ZSH_CUSTOM='$TEST_SUITE_ROOT'
    export ZDX_LAZY_LOAD=1
    unset TEST_TEMP_DIR BATS_TEST_DIRNAME ZDX_EAGER_LOAD

    source '$TEST_SUITE_ROOT/functions.zsh' || exit 90

    $command_text
  " < /dev/null
}

write_dot_archive_metadata() {
  local archive="$1"
  local digest

  tar -tzf "$archive" > "${archive}.manifest"
  digest=$(sha256sum "$archive")
  digest="${digest%% *}"
  printf '%s\n' "$digest" > "${archive}.sha256"
  chmod 600 "$archive" "${archive}.manifest" "${archive}.sha256"
}

make_dot_archive() {
  local source_root="$1"
  local archive="$2"
  shift 2

  mkdir -p "$(dirname "$archive")"
  tar -czf "$archive" -C "$source_root" -- "$@"
  write_dot_archive_metadata "$archive"
}

prepare_valid_font_artifact() {
  local content="$1"
  local artifact_root="$TEST_TEMP_DIR/valid-font-artifact"
  mkdir -p "$artifact_root"
  printf '%s\n' "$content" \
    > "$artifact_root/CaskaydiaCoveNerdFont-Regular.ttf"
  tar -cJf "$MOCK_FONT_ARTIFACT" -C "$artifact_root" \
    CaskaydiaCoveNerdFont-Regular.ttf
  MOCK_FONT_SHA256=$(sha256sum "$MOCK_FONT_ARTIFACT")
  export MOCK_FONT_SHA256="${MOCK_FONT_SHA256%% *}"
  export MOCK_CURL_MODE="font-valid"
}

prepare_control_name_font_artifact() {
  local artifact_root="$TEST_TEMP_DIR/control-font-artifact"
  local unsafe_name=$'Caskaydia\nNerdFont-Regular.ttf'
  mkdir -p "$artifact_root"
  printf 'must-not-install\n' > "$artifact_root/$unsafe_name"
  tar -cJf "$MOCK_FONT_ARTIFACT" -C "$artifact_root" -- "$unsafe_name"
  MOCK_FONT_SHA256=$(sha256sum "$MOCK_FONT_ARTIFACT")
  export MOCK_FONT_SHA256="${MOCK_FONT_SHA256%% *}"
  export MOCK_CURL_MODE="font-valid"
}

@test "sys state dots: backup dry-run creates no backup directory" {
  printf 'export SAFE_VALUE=1\n' > "$HOME/.zshrc"

  run run_sys_state_zsh '
    typeset -ga SYS_DOTFILES=("$HOME/.zshrc")
    SYS_DOTFILES_BACKUP_DIR="$HOME/state/backups"
    sys-backup-dots --dry-run \
      >"$HOME/dots.stdout" 2>"$HOME/dots.stderr"
  '

  [ "$status" -eq 0 ]
  [ ! -e "$HOME/state/backups" ]
  [ ! -s "$HOME/dots.stdout" ]
  grep -q "Dry run complete" "$HOME/dots.stderr"
  [ ! -s "$MOCK_CURL_LOG" ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "sys state dots: backup dry-run enforces entry limits before mutation" {
  printf 'first\n' > "$HOME/.zshrc"
  printf 'second\n' > "$HOME/.gitconfig"

  run run_sys_state_zsh '
    typeset -ga SYS_DOTFILES=("$HOME/.zshrc" "$HOME/.gitconfig")
    SYS_DOTFILES_BACKUP_DIR="$HOME/state/backups"
    SYS_DOTFILES_BACKUP_MAX_ENTRIES=1
    sys-backup-dots --dry-run \
      >"$HOME/dots.stdout" 2>"$HOME/dots.stderr"
  '

  [ "$status" -eq 1 ]
  [ ! -e "$HOME/state" ]
  [ ! -s "$HOME/dots.stdout" ]
  grep -q "entry count exceeds" "$HOME/dots.stderr"
  [ ! -s "$MOCK_CURL_LOG" ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "sys state dots: backup publishes a mode-0600 archive manifest and checksum" {
  printf 'export SAFE_VALUE=1\n' > "$HOME/.zshrc"
  printf '[user]\n\tname = Sandbox\n' > "$HOME/.gitconfig"

  run run_sys_state_zsh '
    typeset -ga SYS_DOTFILES=("$HOME/.zshrc" "$HOME/.gitconfig")
    SYS_DOTFILES_BACKUP_DIR="$HOME/backups"
    sys-backup-dots --yes \
      >"$HOME/dots.stdout" 2>"$HOME/dots.stderr"
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/dots.stdout" ]
  [ "$(stat -c '%a' "$HOME/backups")" = "700" ]

  local archives=("$HOME"/backups/dotfiles_*.tar.gz)
  [ "${#archives[@]}" -eq 1 ]
  local archive="${archives[0]}"
  [ -f "$archive" ]
  [ -f "${archive}.manifest" ]
  [ -f "${archive}.sha256" ]
  [ "$(stat -c '%a' "$archive")" = "600" ]
  [ "$(stat -c '%a' "${archive}.manifest")" = "600" ]
  [ "$(stat -c '%a' "${archive}.sha256")" = "600" ]

  tar -tzf "$archive" | cmp -s - "${archive}.manifest"
  local expected_digest actual_digest
  read -r expected_digest < "${archive}.sha256"
  actual_digest=$(sha256sum "$archive")
  actual_digest="${actual_digest%% *}"
  [ "$actual_digest" = "$expected_digest" ]
  grep -qx '.zshrc' "${archive}.manifest"
  grep -qx '.gitconfig' "${archive}.manifest"
}

@test "sys state dots: restore rejects a tampered archive before changing HOME" {
  printf 'original\n' > "$HOME/.zshrc"

  run run_sys_state_zsh '
    typeset -ga SYS_DOTFILES=("$HOME/.zshrc")
    SYS_DOTFILES_BACKUP_DIR="$HOME/backups"
    sys-backup-dots --yes >/dev/null 2>"$HOME/backup.stderr" || exit
    archives=("$HOME"/backups/dotfiles_*.tar.gz(N))
    archive="${archives[1]}"
    print -rn -- x >> "$archive"
    print -r -- current > "$HOME/.zshrc"
    sys-restore-dots --archive "$archive" --yes \
      >"$HOME/restore.stdout" 2>"$HOME/restore.stderr"
  '

  [ "$status" -eq 1 ]
  [ "$(cat "$HOME/.zshrc")" = "current" ]
  [ ! -s "$HOME/restore.stdout" ]
  grep -q "checksum verification failed" "$HOME/restore.stderr"
}

@test "sys state dots: restore rejects archive path traversal" {
  local backup_dir="$HOME/backups"
  local source_dir="$TEST_TEMP_DIR/traversal-source"
  local archive="$backup_dir/dotfiles_20260101_010101.tar.gz"
  mkdir -p "$backup_dir" "$source_dir"
  printf 'escaped\n' > "$source_dir/safe"
  tar -czf "$archive" \
    --transform='s#^safe$#../escaped#' \
    -C "$source_dir" safe
  write_dot_archive_metadata "$archive"
  printf 'current\n' > "$HOME/.zshrc"

  run run_sys_state_zsh '
    SYS_DOTFILES_BACKUP_DIR="$HOME/backups"
    sys-restore-dots \
      --archive "$HOME/backups/dotfiles_20260101_010101.tar.gz" \
      --yes >"$HOME/restore.stdout" 2>"$HOME/restore.stderr"
  '

  [ "$status" -eq 1 ]
  [ "$(cat "$HOME/.zshrc")" = "current" ]
  [ ! -e "$TEST_TEMP_DIR/escaped" ]
  [ ! -s "$HOME/restore.stdout" ]
  grep -q "path traversal" "$HOME/restore.stderr"
}

@test "sys state dots: restore rejects an actual control character after extraction" {
  local source_dir="$TEST_TEMP_DIR/control-name-source"
  local archive="$HOME/backups/dotfiles_20260101_011111.tar.gz"
  local unsafe_name=$'unsafe\nname'
  mkdir -p "$source_dir"
  printf 'must-not-publish\n' > "$source_dir/$unsafe_name"
  make_dot_archive "$source_dir" "$archive" "$unsafe_name"

  run run_sys_state_zsh '
    SYS_DOTFILES_BACKUP_DIR="$HOME/backups"
    sys-restore-dots \
      --archive "$HOME/backups/dotfiles_20260101_011111.tar.gz" \
      --yes >"$HOME/restore.stdout" 2>"$HOME/restore.stderr"
  '

  [ "$status" -eq 1 ]
  [ ! -e "$HOME/$unsafe_name" ]
  [ ! -s "$HOME/restore.stdout" ]
  grep -q "unsafe filename" "$HOME/restore.stderr"
  [ -z "$(find "$HOME/backups" \
    -name 'dotfiles_*_pre-restore.tar.gz' -print -quit)" ]
}

@test "sys state dots: restore rejects excessive expanded archive data" {
  local source_dir="$TEST_TEMP_DIR/expanded-source"
  local archive="$HOME/backups/dotfiles_20260101_015151.tar.gz"
  mkdir -p "$source_dir"
  printf 'restored-content-exceeds-limit\n' > "$source_dir/.zshrc"
  printf 'current\n' > "$HOME/.zshrc"
  make_dot_archive "$source_dir" "$archive" .zshrc

  run run_sys_state_zsh '
    SYS_DOTFILES_BACKUP_DIR="$HOME/backups"
    SYS_DOTFILES_RESTORE_MAX_EXPANDED_BYTES=4
    sys-restore-dots \
      --archive "$HOME/backups/dotfiles_20260101_015151.tar.gz" \
      --yes >"$HOME/restore.stdout" 2>"$HOME/restore.stderr"
  '

  [ "$status" -eq 1 ]
  [ "$(cat "$HOME/.zshrc")" = "current" ]
  [ -z "$(find "$HOME/backups" \
    -name 'dotfiles_*_pre-restore.tar.gz' -print -quit)" ]
  grep -q "Expanded archive data exceeds" "$HOME/restore.stderr"
}

@test "sys state dots: restore rejects an existing destination symlink" {
  local source_dir="$TEST_TEMP_DIR/destination-source"
  local archive="$HOME/backups/dotfiles_20260101_020202.tar.gz"
  mkdir -p "$source_dir/.config/demo" "$HOME/external"
  printf 'restored\n' > "$source_dir/.config/demo/settings"
  printf 'sentinel\n' > "$HOME/external/sentinel"
  make_dot_archive "$source_dir" "$archive" .config/demo/settings
  ln -s "$HOME/external" "$HOME/.config"

  run run_sys_state_zsh '
    SYS_DOTFILES_BACKUP_DIR="$HOME/backups"
    sys-restore-dots \
      --archive "$HOME/backups/dotfiles_20260101_020202.tar.gz" \
      --yes >"$HOME/restore.stdout" 2>"$HOME/restore.stderr"
  '

  [ "$status" -eq 1 ]
  [ -L "$HOME/.config" ]
  [ "$(cat "$HOME/external/sentinel")" = "sentinel" ]
  [ ! -e "$HOME/external/demo/settings" ]
  grep -q "crosses an existing symbolic link" "$HOME/restore.stderr"
}

@test "sys state dots: restore rejects a multiply-linked destination" {
  local source_dir="$TEST_TEMP_DIR/hardlink-source"
  local archive="$HOME/backups/dotfiles_20260101_021212.tar.gz"
  local external="$HOME/external-hardlink"
  mkdir -p "$source_dir"
  printf 'restored\n' > "$source_dir/.zshrc"
  printf 'current\n' > "$external"
  ln "$external" "$HOME/.zshrc"
  make_dot_archive "$source_dir" "$archive" .zshrc
  local before_inode
  before_inode=$(stat -c '%d:%i' "$external")

  run run_sys_state_zsh '
    SYS_DOTFILES_BACKUP_DIR="$HOME/backups"
    sys-restore-dots \
      --archive "$HOME/backups/dotfiles_20260101_021212.tar.gz" \
      --yes >"$HOME/restore.stdout" 2>"$HOME/restore.stderr"
  '

  [ "$status" -eq 1 ]
  [ "$(cat "$external")" = "current" ]
  [ "$(cat "$HOME/.zshrc")" = "current" ]
  [ "$(stat -c '%d:%i' "$HOME/.zshrc")" = "$before_inode" ]
  grep -q "multiply-linked destination" "$HOME/restore.stderr"
  [ -z "$(find "$HOME/backups" \
    -name 'dotfiles_*_pre-restore.tar.gz' -print -quit)" ]
}

@test "sys state dots: restore revalidates a destination changed after safety backup" {
  local source_dir="$TEST_TEMP_DIR/destination-race-source"
  local archive="$HOME/backups/dotfiles_20260101_022222.tar.gz"
  mkdir -p "$source_dir/.config/demo" "$HOME/.config/demo" \
    "$HOME/external-race"
  printf 'restored\n' > "$source_dir/.config/demo/settings"
  printf 'current\n' > "$HOME/.config/demo/settings"
  printf 'sentinel\n' > "$HOME/external-race/sentinel"
  make_dot_archive "$source_dir" "$archive" .config/demo/settings

  run run_sys_state_zsh '
    functions[_sys_dotfiles_create_archive_before_race]=\
"${functions[_sys_dotfiles_create_archive]}"
    _sys_dotfiles_create_archive() {
      _sys_dotfiles_create_archive_before_race "$@" || return
      command mv "$HOME/.config" "$HOME/.config-before-race" || return
      command ln -s "$HOME/external-race" "$HOME/.config"
    }
    SYS_DOTFILES_BACKUP_DIR="$HOME/backups"
    sys-restore-dots \
      --archive "$HOME/backups/dotfiles_20260101_022222.tar.gz" \
      --yes >"$HOME/restore.stdout" 2>"$HOME/restore.stderr"
  '

  [ "$status" -eq 1 ]
  [ -L "$HOME/.config" ]
  [ "$(readlink "$HOME/.config")" = "$HOME/external-race" ]
  [ "$(cat "$HOME/external-race/sentinel")" = "sentinel" ]
  [ ! -e "$HOME/external-race/demo/settings" ]
  [ "$(cat "$HOME/.config-before-race/demo/settings")" = "current" ]
  [ -n "$(find "$HOME/backups" \
    -name 'dotfiles_*_pre-restore.tar.gz' -print -quit)" ]
  grep -q "crosses an existing symbolic link" "$HOME/restore.stderr"
}

@test "sys state dots: non-interactive restore without yes fails closed" {
  local source_dir="$TEST_TEMP_DIR/noninteractive-source"
  local archive="$HOME/backups/dotfiles_20260101_030303.tar.gz"
  mkdir -p "$source_dir"
  printf 'restored\n' > "$source_dir/.zshrc"
  printf 'current\n' > "$HOME/.zshrc"
  make_dot_archive "$source_dir" "$archive" .zshrc

  run run_sys_state_zsh '
    SYS_DOTFILES_BACKUP_DIR="$HOME/backups"
    sys-restore-dots \
      --archive "$HOME/backups/dotfiles_20260101_030303.tar.gz" \
      >"$HOME/restore.stdout" 2>"$HOME/restore.stderr"
  '

  [ "$status" -eq 1 ]
  [ "$(cat "$HOME/.zshrc")" = "current" ]
  grep -q "requires --yes" "$HOME/restore.stderr"
}

@test "sys state dots: restore creates a verified safety backup before overwrite" {
  local source_dir="$TEST_TEMP_DIR/safety-source"
  local archive="$HOME/backups/dotfiles_20260101_040404.tar.gz"
  mkdir -p "$source_dir"
  printf 'restored\n' > "$source_dir/.zshrc"
  printf 'current\n' > "$HOME/.zshrc"
  make_dot_archive "$source_dir" "$archive" .zshrc

  run run_sys_state_zsh '
    SYS_DOTFILES_BACKUP_DIR="$HOME/backups"
    sys-restore-dots \
      --archive "$HOME/backups/dotfiles_20260101_040404.tar.gz" \
      --yes >"$HOME/restore.stdout" 2>"$HOME/restore.stderr"
  '

  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.zshrc")" = "restored" ]
  local safety_archives=("$HOME"/backups/dotfiles_*_pre-restore.tar.gz)
  [ "${#safety_archives[@]}" -eq 1 ]
  local safety_archive="${safety_archives[0]}"
  [ "$(stat -c '%a' "$safety_archive")" = "600" ]
  [ -f "${safety_archive}.manifest" ]
  [ -f "${safety_archive}.sha256" ]
  [ "$(tar -xOzf "$safety_archive" .zshrc)" = "current" ]
  grep -q "Safety backup:" "$HOME/restore.stderr"
}

@test "sys state dots: restore aborts when the mandatory safety backup cannot be written" {
  local source_dir="$TEST_TEMP_DIR/safety-failure-source"
  local archive="$HOME/backups/dotfiles_20260101_050505.tar.gz"
  mkdir -p "$source_dir"
  printf 'restored\n' > "$source_dir/.zshrc"
  printf 'current\n' > "$HOME/.zshrc"
  make_dot_archive "$source_dir" "$archive" .zshrc
  chmod 500 "$HOME/backups"

  run run_sys_state_zsh '
    SYS_DOTFILES_BACKUP_DIR="$HOME/backups"
    sys-restore-dots \
      --archive "$HOME/backups/dotfiles_20260101_050505.tar.gz" \
      --yes >"$HOME/restore.stdout" 2>"$HOME/restore.stderr"
  '

  chmod 700 "$HOME/backups"
  [ "$status" -eq 1 ]
  [ "$(cat "$HOME/.zshrc")" = "current" ]
  grep -q "mandatory pre-restore backup" "$HOME/restore.stderr"
}

@test "sys state fonts: unsupported family is rejected without network access" {
  run run_sys_state_zsh '
    _sys_capability_value() {
      [[ "$1" == "fonts_backend" ]] && print -r -- fontconfig
    }
    : > "$MOCK_CURL_LOG"
    sys-fonts --install "../Hack" --yes \
      >"$HOME/fonts.stdout" 2>"$HOME/fonts.stderr"
  '

  [ "$status" -eq 2 ]
  [ ! -s "$MOCK_CURL_LOG" ]
  [ ! -e "$HOME/.local/share/fonts" ]
  [ ! -s "$HOME/fonts.stdout" ]
  grep -q "Unsupported Nerd Font family" "$HOME/fonts.stderr"
}

@test "sys state fonts: dry-run performs no download or filesystem mutation" {
  run run_sys_state_zsh '
    _sys_capability_value() {
      [[ "$1" == "fonts_backend" ]] && print -r -- fontconfig
    }
    : > "$MOCK_CURL_LOG"
    sys-fonts --install CascadiaCode --dry-run --yes \
      >"$HOME/fonts.stdout" 2>"$HOME/fonts.stderr"
  '

  [ "$status" -eq 0 ]
  [ ! -s "$MOCK_CURL_LOG" ]
  [ ! -e "$HOME/.local/share/fonts" ]
  [ ! -s "$HOME/fonts.stdout" ]
  grep -q "no network access or filesystem mutation" "$HOME/fonts.stderr"
}

@test "sys state fonts: list rejects a symbolic-link component without reading outside" {
  local external_share="$HOME/external-share"
  mkdir -p "$external_share/fonts/CascadiaCode" "$HOME/.local"
  printf 'outside-font\n' \
    > "$external_share/fonts/CascadiaCode/OutsideNerdFont.ttf"
  ln -s "$external_share" "$HOME/.local/share"

  run run_sys_state_zsh '
    _sys_capability_value() {
      [[ "$1" == "fonts_backend" ]] && print -r -- fontconfig
    }
    sys-fonts --list \
      >"$HOME/fonts.stdout" 2>"$HOME/fonts.stderr"
  '

  [ "$status" -eq 1 ]
  [ -L "$HOME/.local/share" ]
  [ ! -s "$HOME/fonts.stdout" ]
  grep -q "crosses a symbolic link" "$HOME/fonts.stderr"
  [ "$(cat "$external_share/fonts/CascadiaCode/OutsideNerdFont.ttf")" = \
    "outside-font" ]
  [ ! -s "$MOCK_CURL_LOG" ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "sys state fonts: checksum mismatch never replaces the installed family" {
  local destination="$HOME/.local/share/fonts/CascadiaCode"
  mkdir -p "$destination"
  printf 'original-font\n' > "$destination/original.ttf"
  export MOCK_CURL_MODE="font-mismatch"

  run run_sys_state_zsh '
    _sys_capability_value() {
      [[ "$1" == "fonts_backend" ]] && print -r -- fontconfig
    }
    sys-fonts --install CascadiaCode --yes \
      >"$HOME/fonts.stdout" 2>"$HOME/fonts.stderr"
  '

  [ "$status" -eq 1 ]
  [ "$(cat "$destination/original.ttf")" = "original-font" ]
  [ "$(find "$destination" -type f | wc -l)" -eq 1 ]
  [ "$(wc -l < "$MOCK_CURL_LOG")" -eq 2 ]
  grep -q '/v3.4.0/CascadiaCode.tar.xz' "$MOCK_CURL_LOG"
  grep -q '/v3.4.0/SHA-256.txt' "$MOCK_CURL_LOG"
  grep -q "checksum mismatch" "$HOME/fonts.stderr"
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "sys state fonts: actual control character in archive is rejected after extraction" {
  prepare_control_name_font_artifact

  run run_sys_state_zsh '
    _sys_capability_value() {
      [[ "$1" == "fonts_backend" ]] && print -r -- fontconfig
    }
    sys-fonts --install CascadiaCode --yes \
      >"$HOME/fonts.stdout" 2>"$HOME/fonts.stderr"
  '

  [ "$status" -eq 1 ]
  [ ! -e "$HOME/.local/share/fonts/CascadiaCode" ]
  grep -q "unsafe filename" "$HOME/fonts.stderr"
  [ "$(wc -l < "$MOCK_CURL_LOG")" -eq 2 ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "sys state fonts: excessive expanded data preserves installed family" {
  local destination="$HOME/.local/share/fonts/CascadiaCode"
  mkdir -p "$destination"
  printf 'original-font\n' > "$destination/original.ttf"
  prepare_valid_font_artifact "replacement-font-exceeds-limit"

  run run_sys_state_zsh '
    _sys_capability_value() {
      [[ "$1" == "fonts_backend" ]] && print -r -- fontconfig
    }
    SYS_NERD_FONTS_MAX_EXPANDED_BYTES=4
    sys-fonts --install CascadiaCode --yes \
      >"$HOME/fonts.stdout" 2>"$HOME/fonts.stderr"
  '

  [ "$status" -eq 1 ]
  [ "$(cat "$destination/original.ttf")" = "original-font" ]
  [ "$(find "$destination" -type f | wc -l)" -eq 1 ]
  grep -q "Expanded font data exceeds" "$HOME/fonts.stderr"
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "sys state fonts: unmanaged prior tree is preserved and managed updates are retired" {
  local destination="$HOME/.local/share/fonts/CascadiaCode"
  mkdir -p "$destination"
  printf 'original-font\n' > "$destination/original.ttf"
  prepare_valid_font_artifact "replacement-one"

  run run_sys_state_zsh '
    _sys_capability_value() {
      [[ "$1" == "fonts_backend" ]] && print -r -- fontconfig
    }
    _sys_has_capability() {
      return 1
    }
    sys-fonts --install CascadiaCode --yes \
      >"$HOME/fonts-first.stdout" 2>"$HOME/fonts-first.stderr"
  '

  [ "$status" -eq 0 ]
  [ "$(cat "$destination/CaskaydiaCoveNerdFont-Regular.ttf")" = \
    "replacement-one" ]
  grep -qx "zdx-managed-font-family-v1" \
    "$destination/.zdx-managed-font-family"
  grep -qx "family=CascadiaCode" "$destination/.zdx-managed-font-family"
  local recovery_trees=(
    "$HOME"/.local/share/.zdx-font-previous-CascadiaCode.*
  )
  [ "${#recovery_trees[@]}" -eq 1 ]
  local unmanaged_recovery="${recovery_trees[0]}"
  [ -d "$unmanaged_recovery" ]
  [ "$(cat "$unmanaged_recovery/original.ttf")" = "original-font" ]
  [ ! -e "$unmanaged_recovery/.zdx-managed-font-family" ]
  grep -q "preserved instead of being deleted" "$HOME/fonts-first.stderr"

  prepare_valid_font_artifact "replacement-two"
  run run_sys_state_zsh '
    _sys_capability_value() {
      [[ "$1" == "fonts_backend" ]] && print -r -- fontconfig
    }
    _sys_has_capability() {
      return 1
    }
    sys-fonts --install CascadiaCode --yes \
      >"$HOME/fonts-second.stdout" 2>"$HOME/fonts-second.stderr"
  '

  [ "$status" -eq 0 ]
  [ "$(cat "$destination/CaskaydiaCoveNerdFont-Regular.ttf")" = \
    "replacement-two" ]
  grep -qx "zdx-managed-font-family-v1" \
    "$destination/.zdx-managed-font-family"
  recovery_trees=(
    "$HOME"/.local/share/.zdx-font-previous-CascadiaCode.*
  )
  [ "${#recovery_trees[@]}" -eq 1 ]
  [ "${recovery_trees[0]}" = "$unmanaged_recovery" ]
  [ "$(cat "$unmanaged_recovery/original.ttf")" = "original-font" ]
  [ "$(wc -l < "$MOCK_CURL_LOG")" -eq 4 ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "sys state fonts: failed publication and restore preserve recovery tree" {
  local destination="$HOME/.local/share/fonts/CascadiaCode"
  mkdir -p "$destination"
  printf 'original-font\n' > "$destination/original.ttf"
  prepare_valid_font_artifact "replacement-font"

  export MOCK_MV_LOG="$TEST_TEMP_DIR/mv_calls"
  export REAL_MV
  REAL_MV=$(command -v mv)
  : > "$MOCK_MV_LOG"
  cat > "$TEST_MOCK_BIN/mv" <<'EOF'
#!/usr/bin/env bash
set -u

{
  printf 'mv'
  printf ' %q' "$@"
  printf '\n'
} >> "${MOCK_MV_LOG:?}"

source_path="${1:-}"
destination_path="${2:-}"
source_name="${source_path##*/}"
destination_name="${destination_path##*/}"

if [[ "$source_name" == ".zdx-font-previous-CascadiaCode."* \
  && "$destination_name" == "CascadiaCode" ]]; then
  exit 73
fi
if [[ "$source_name" == ".zdx-font."* \
  && "$destination_name" == "CascadiaCode" ]]; then
  exit 72
fi
exec "${REAL_MV:?}" "$@"
EOF
  chmod +x "$TEST_MOCK_BIN/mv"

  run run_sys_state_zsh '
    _sys_capability_value() {
      [[ "$1" == "fonts_backend" ]] && print -r -- fontconfig
    }
    sys-fonts --install CascadiaCode --yes \
      >"$HOME/fonts.stdout" 2>"$HOME/fonts.stderr"
  '

  [ "$status" -eq 1 ]
  [ ! -e "$destination" ]
  local recovery_trees=(
    "$HOME"/.local/share/.zdx-font-previous-CascadiaCode.*
  )
  [ "${#recovery_trees[@]}" -eq 1 ]
  local recovery_tree="${recovery_trees[0]}"
  [ -d "$recovery_tree" ]
  [ "$(cat "$recovery_tree/original.ttf")" = "original-font" ]
  [[ "$(cat "$HOME/fonts.stderr")" == *"$recovery_tree"* ]]
  [ -z "$(find "$HOME/.local/share/fonts" \
    -maxdepth 1 -name '.zdx-font.*' -print -quit)" ]
  [ "$(grep -Ec -- '^mv .*[.]zdx-font[.].* /.*[/]CascadiaCode$' \
    "$MOCK_MV_LOG")" -eq 1 ]
  [ "$(grep -Ec -- '^mv .*[.]zdx-font-previous-CascadiaCode[.].* /.*[/]CascadiaCode$' \
    "$MOCK_MV_LOG")" -ge 1 ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "sys state telemetry: writer creates owner-only directory and file" {
  run run_core_state_zsh '
    _log_telemetry "sys:permissions" 0.001 0
  '

  [ "$status" -eq 0 ]
  [ -d "$HOME/.config/zdx" ]
  [ -f "$HOME/.config/zdx/telemetry.json" ]
  [ "$(stat -c '%a' "$HOME/.config/zdx")" = "700" ]
  [ "$(stat -c '%a' "$HOME/.config/zdx/telemetry.json")" = "600" ]
  [ ! -e "$HOME/.config/zdx/.telemetry.lock" ]
}

@test "sys state telemetry: huge duration is omitted without arithmetic errors" {
  run run_core_state_zsh '
    _log_telemetry \
      "sys:duration-out-of-range" \
      "999999999999999999999999999999999999" 0
  '

  [ "$status" -eq 1 ]
  [ ! -e "$HOME/.config/zdx/telemetry.json" ]
  [[ "$output" != *"bad math expression"* ]]
  [[ "$output" != *"number truncated after 64 bits"* ]]
  [[ "$output" != *"integer expression expected"* ]]
}

@test "sys state telemetry: writer discards a final partial JSON line" {
  mkdir -p "$HOME/.config/zdx"
  chmod 700 "$HOME/.config/zdx"
  printf '%s\n' \
    '{"suite":"sys","command":"complete","duration_ms":1,"exit_code":0,"timestamp":"2026-01-01T00:00:00Z"}' \
    > "$HOME/.config/zdx/telemetry.json"
  printf '%s' '{"suite":"sys","command":"partial"' \
    >> "$HOME/.config/zdx/telemetry.json"
  chmod 600 "$HOME/.config/zdx/telemetry.json"

  run run_core_state_zsh '
    _log_telemetry "sys:after-partial" 0.001 0
  '

  [ "$status" -eq 0 ]
  local log_file="$HOME/.config/zdx/telemetry.json"
  [ "$(wc -l < "$log_file")" -eq 2 ]
  grep -q '"command":"complete"' "$log_file"
  grep -q '"command": "after-partial"' "$log_file"
  [ "$(grep -c '"command":"partial"' "$log_file" || true)" -eq 0 ]
  [ "$(grep -c '}{' "$log_file" || true)" -eq 0 ]
  [ "$(tail -c 1 "$log_file" | wc -l)" -eq 1 ]
  [ ! -e "$HOME/.config/zdx/.telemetry.lock" ]
}

@test "sys state telemetry: writer enforces bounded record retention" {
  run run_core_state_zsh '
    ZDX_TELEMETRY_MAX_RECORDS=3
    for command_name in one two three four five; do
      _log_telemetry "sys:${command_name}" 0.001 0 || exit
    done
  '

  [ "$status" -eq 0 ]
  local log_file="$HOME/.config/zdx/telemetry.json"
  [ "$(wc -l < "$log_file")" -eq 3 ]
  [ "$(grep -c '"command": "one"' "$log_file" || true)" -eq 0 ]
  [ "$(grep -c '"command": "two"' "$log_file" || true)" -eq 0 ]
  grep -q '"command": "three"' "$log_file"
  grep -q '"command": "four"' "$log_file"
  grep -q '"command": "five"' "$log_file"
}

@test "sys state telemetry: writer keeps the published file within byte limit" {
  run run_core_state_zsh '
    ZDX_TELEMETRY_MAX_BYTES=160
    _log_telemetry "sys:one" 0.001 0 || exit
    _log_telemetry "sys:two" 0.001 0 || exit
    _log_telemetry "sys:three" 0.001 0 || exit
  '

  [ "$status" -eq 0 ]
  local log_file="$HOME/.config/zdx/telemetry.json"
  [ "$(wc -c < "$log_file")" -le 160 ]
  [ "$(wc -l < "$log_file")" -eq 1 ]
  grep -q '"command": "three"' "$log_file"
  [ "$(grep -c '"command": "one"' "$log_file" || true)" -eq 0 ]
  [ "$(grep -c '"command": "two"' "$log_file" || true)" -eq 0 ]
  [ ! -e "$HOME/.config/zdx/.telemetry.lock" ]
  [ -z "$(find "$HOME/.config/zdx" -name '.telemetry.*' -print -quit)" ]
}

@test "sys state telemetry: writer refuses a symbolic-link log" {
  mkdir -p "$HOME/.config/zdx"
  printf 'sentinel\n' > "$HOME/telemetry-target"
  ln -s "$HOME/telemetry-target" "$HOME/.config/zdx/telemetry.json"

  run run_core_state_zsh '
    _log_telemetry "sys:must-not-write" 0.001 0
  '

  [ "$status" -eq 1 ]
  [ -L "$HOME/.config/zdx/telemetry.json" ]
  [ "$(cat "$HOME/telemetry-target")" = "sentinel" ]
  [ ! -e "$HOME/.config/zdx/.telemetry.lock" ]
  [ -z "$(find "$HOME/.config/zdx" -name '.telemetry.*' -print -quit)" ]
}

@test "sys state telemetry: writer reader and clear reject symlinked parent" {
  local real_config="$HOME/real-config"
  mkdir -p "$real_config/zdx"
  chmod 700 "$real_config/zdx"
  printf '%s\n' \
    '{"suite":"sys","command":"sentinel","duration_ms":1,"exit_code":0,"timestamp":"2026-01-01T00:00:00Z"}' \
    > "$real_config/zdx/telemetry.json"
  chmod 600 "$real_config/zdx/telemetry.json"
  ln -s "$real_config" "$HOME/.config"
  local before_digest
  before_digest=$(sha256sum "$real_config/zdx/telemetry.json")

  run run_core_state_zsh '
    _log_telemetry "sys:must-not-follow-parent" 0.001 0
  '
  [ "$status" -eq 1 ]

  run run_sys_state_zsh '
    sys-telemetry --dashboard
  '
  [ "$status" -eq 1 ]

  run run_sys_state_zsh '
    sys-telemetry --clear --yes
  '
  [ "$status" -eq 1 ]

  [ -L "$HOME/.config" ]
  [ "$(readlink "$HOME/.config")" = "$real_config" ]
  [ "$(sha256sum "$real_config/zdx/telemetry.json")" = "$before_digest" ]
  [ ! -e "$real_config/zdx/.telemetry.lock" ]
  [ -z "$(find "$real_config/zdx" -name '.telemetry.*' -print -quit)" ]
}

@test "sys state telemetry: writer refuses an oversized existing log" {
  mkdir -p "$HOME/.config/zdx"
  printf '0123456789abcdef\n' > "$HOME/.config/zdx/telemetry.json"
  chmod 600 "$HOME/.config/zdx/telemetry.json"
  local before_digest
  before_digest=$(sha256sum "$HOME/.config/zdx/telemetry.json")

  run run_core_state_zsh '
    ZDX_TELEMETRY_MAX_BYTES=8
    _log_telemetry "sys:must-not-append" 0.001 0
  '

  [ "$status" -eq 1 ]
  [ "$(sha256sum "$HOME/.config/zdx/telemetry.json")" = "$before_digest" ]
  [ ! -e "$HOME/.config/zdx/.telemetry.lock" ]
  [ -z "$(find "$HOME/.config/zdx" -name '.telemetry.*' -print -quit)" ]
}

@test "sys state telemetry: clear dry-run preserves content and identity" {
  mkdir -p "$HOME/.config/zdx"
  printf 'telemetry-data\n' > "$HOME/.config/zdx/telemetry.json"
  chmod 600 "$HOME/.config/zdx/telemetry.json"
  local before_inode
  before_inode=$(stat -c '%d:%i' "$HOME/.config/zdx/telemetry.json")

  run run_sys_state_zsh '
    sys-telemetry --clear --dry-run \
      >"$HOME/clear.stdout" 2>"$HOME/clear.stderr"
  '

  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.config/zdx/telemetry.json")" = "telemetry-data" ]
  [ "$(stat -c '%d:%i' "$HOME/.config/zdx/telemetry.json")" = "$before_inode" ]
  [ ! -e "$HOME/.config/zdx/.telemetry.lock" ]
  grep -q "Dry run complete" "$HOME/clear.stderr"
}

@test "sys state telemetry: non-interactive clear without yes fails closed" {
  mkdir -p "$HOME/.config/zdx"
  printf 'telemetry-data\n' > "$HOME/.config/zdx/telemetry.json"
  chmod 600 "$HOME/.config/zdx/telemetry.json"
  local before_inode
  before_inode=$(stat -c '%d:%i' "$HOME/.config/zdx/telemetry.json")

  run run_sys_state_zsh '
    sys-telemetry --clear \
      >"$HOME/clear.stdout" 2>"$HOME/clear.stderr"
  '

  [ "$status" -eq 1 ]
  [ "$(cat "$HOME/.config/zdx/telemetry.json")" = "telemetry-data" ]
  [ "$(stat -c '%d:%i' "$HOME/.config/zdx/telemetry.json")" = "$before_inode" ]
  [ ! -e "$HOME/.config/zdx/.telemetry.lock" ]
  grep -q "requires --yes" "$HOME/clear.stderr"
}

@test "sys state telemetry: clear refuses a symbolic-link log" {
  mkdir -p "$HOME/.config/zdx"
  printf 'sentinel\n' > "$HOME/telemetry-target"
  ln -s "$HOME/telemetry-target" "$HOME/.config/zdx/telemetry.json"

  run run_sys_state_zsh '
    sys-telemetry --clear --yes \
      >"$HOME/clear.stdout" 2>"$HOME/clear.stderr"
  '

  [ "$status" -eq 1 ]
  [ -L "$HOME/.config/zdx/telemetry.json" ]
  [ "$(cat "$HOME/telemetry-target")" = "sentinel" ]
  [ ! -e "$HOME/.config/zdx/.telemetry.lock" ]
  grep -q "not a link" "$HOME/clear.stderr"
}

@test "sys state plugins: compatibility bridge preserves arguments and owner status" {
  run run_sys_state_zsh '
    zdx-plugins() {
      {
        print -r -- "$#"
        local owner_argument
        for owner_argument in "$@"; do
          print -r -- "<${owner_argument}>"
        done
      } > "$HOME/plugin-owner.args"
      return 37
    }

    sys-plugins --install \
      "https://example.test/repository with spaces.git" \
      "-leading-name"
  '

  [ "$status" -eq 37 ]
  [ "$(sed -n '1p' "$HOME/plugin-owner.args")" = "3" ]
  [ "$(sed -n '2p' "$HOME/plugin-owner.args")" = "<--install>" ]
  [ "$(sed -n '3p' "$HOME/plugin-owner.args")" = \
    "<https://example.test/repository with spaces.git>" ]
  [ "$(sed -n '4p' "$HOME/plugin-owner.args")" = "<-leading-name>" ]
}

@test "sys state plugins: compatibility module defines no duplicate lifecycle" {
  run run_sys_state_zsh '
    private_name=""
    for private_name in \
      _sys_plugins_list \
      _sys_plugins_install \
      _sys_plugins_update \
      _sys_plugins_remove; do
      if typeset -f "$private_name" >/dev/null; then
        print -u2 -r -- "unexpected duplicate lifecycle: $private_name"
        exit 1
      fi
    done
  '

  [ "$status" -eq 0 ]
}

@test "sys state dots: backup names a missing tar dependency before planning" {
  printf 'export SAFE_VALUE=1\n' > "$HOME/.zshrc"

  run run_sys_state_zsh '
    command() {
      if [[ "$1" == "-v" && "${2:-}" == "tar" ]]; then
        return 1
      fi
      builtin command "$@"
    }
    typeset -ga SYS_DOTFILES=("$HOME/.zshrc")
    SYS_DOTFILES_BACKUP_DIR="$HOME/state/backups"
    sys-backup-dots --yes \
      >"$HOME/dots.stdout" 2>"$HOME/dots.stderr"
  '

  [ "$status" -eq 1 ]
  [ ! -e "$HOME/state" ]
  [ ! -s "$HOME/dots.stdout" ]
  grep -q "Missing required dependency: tar" "$HOME/dots.stderr"
  ! grep -q "Dotfile Backup Plan" "$HOME/dots.stderr"
}

@test "sys state dots: backup works when HOME is a symbolic link and restore needs the canonical HOME" {
  printf 'export SAFE_VALUE=1\n' > "$HOME/.zshrc"
  ln -s "$HOME" "$TEST_TEMP_DIR/home-link"

  run run_sys_state_zsh '
    export HOME="$TEST_TEMP_DIR/home-link"
    typeset -ga SYS_DOTFILES=("$HOME/.zshrc")
    SYS_DOTFILES_BACKUP_DIR="$HOME/backups"
    sys-backup-dots --yes \
      >"$HOME/dots.stdout" 2>"$HOME/dots.stderr" || return 1
    local -a archives=("$HOME"/backups/dotfiles_*.tar.gz(N))
    (( ${#archives[@]} == 1 )) || return 2

    # Restore keeps refusing a link HOME destination by policy.
    local -i linked_rc=0
    sys-restore-dots --archive "${archives[1]}" --dry-run \
      >"$HOME/linked.stdout" 2>"$HOME/linked.stderr" || linked_rc=$?
    (( linked_rc == 1 )) || return 3
    grep -q "not a link" "$HOME/linked.stderr" || return 4

    # The same archive restores once HOME names the canonical directory.
    export HOME="$TEST_TEMP_DIR/home"
    SYS_DOTFILES_BACKUP_DIR="$HOME/backups"
    archives=("$HOME"/backups/dotfiles_*.tar.gz(N))
    sys-restore-dots --archive "${archives[1]}" --dry-run \
      >"$HOME/restore.stdout" 2>"$HOME/restore.stderr"
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/dots.stdout" ]
  [ ! -s "$HOME/linked.stdout" ]
  [ ! -s "$HOME/restore.stdout" ]
  grep -q "Backup created" "$HOME/dots.stderr"
  grep -q "Dry run complete" "$HOME/restore.stderr"
  local archives=("$HOME"/backups/dotfiles_*.tar.gz)
  [ "${#archives[@]}" -eq 1 ]
  grep -qx '.zshrc' "${archives[0]}.manifest"
}

@test "sys state dots: restore accepts a sidecar digest without a trailing newline" {
  printf 'export SAFE_VALUE=1\n' > "$HOME/.zshrc"

  run run_sys_state_zsh '
    typeset -ga SYS_DOTFILES=("$HOME/.zshrc")
    SYS_DOTFILES_BACKUP_DIR="$HOME/backups"
    sys-backup-dots --yes >/dev/null 2>&1 || return 1
  '
  [ "$status" -eq 0 ]

  local archives=("$HOME"/backups/dotfiles_*.tar.gz)
  [ "${#archives[@]}" -eq 1 ]
  local archive="${archives[0]}"
  local digest
  read -r digest < "${archive}.sha256"
  printf '%s' "$digest" > "${archive}.sha256"
  [ "$(tail -c 1 "${archive}.sha256" | od -An -c | tr -d ' ')" != '\n' ]

  run run_sys_state_zsh "
    SYS_DOTFILES_BACKUP_DIR=\"\$HOME/backups\"
    sys-restore-dots --archive '$archive' --dry-run \
      >\"\$HOME/restore.stdout\" 2>\"\$HOME/restore.stderr\"
  "

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/restore.stdout" ]
  grep -q "Dry run complete" "$HOME/restore.stderr"
}
