#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031
#
# Environment portability: the WSL and macOS clipboard backends and PATH
# entries that differ by a trailing slash or by letter case.

setup() {
  load test_helper
  export ENV_CLIP_LOG="$TEST_TEMP_DIR/clip.bytes"
  # A clipboard program that keeps the exact bytes it receives.
  export ENV_CLIP_RECORDER="$TEST_TEMP_DIR/clip-recorder"
  cat > "$ENV_CLIP_RECORDER" <<'SH'
#!/usr/bin/env bash
cat > "$ENV_CLIP_LOG"
printf 'LC_ALL=%s\n' "${LC_ALL:-unset}" > "$ENV_CLIP_LOG.env"
SH
  chmod +x "$ENV_CLIP_RECORDER"
}

teardown() {
  cleanup_sandbox
}

# stdout: the recorded clipboard bytes as space-separated hex.
clip_hex() {
  od -An -tx1 "$ENV_CLIP_LOG" | tr -s ' \n' ' ' | sed 's/^ //; s/ $//'
}

@test "env platform: clip.exe receives UTF-16LE text with a byte-order mark" {
  cp "$ENV_CLIP_RECORDER" "$TEST_MOCK_BIN/clip.exe"

  run run_zsh '
    OSTYPE=linux-gnu
    unset DISPLAY WAYLAND_DISPLAY
    export ENV_COPY_VALUE=$'"'"'caf\303\251'"'"'
    env-list --copy ENV_COPY_VALUE
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"Copied 'ENV_COPY_VALUE' to the clipboard."* ]]
  [ "$(clip_hex)" = "ff fe 63 00 61 00 66 00 e9 00" ]
}

@test "env platform: invalid UTF-8 never reaches clip.exe and is never printed" {
  cp "$ENV_CLIP_RECORDER" "$TEST_MOCK_BIN/clip.exe"

  run run_zsh '
    OSTYPE=linux-gnu
    unset DISPLAY WAYLAND_DISPLAY
    export ENV_COPY_VALUE=$'"'"'secret\xff'"'"'
    env-list --copy ENV_COPY_VALUE
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"The value is not valid UTF-8 text for the Windows clipboard."* ]]
  [[ "$output" == *"The clipboard backend failed; the value was not printed."* ]]
  [[ "$output" != *"secret"* ]]
  [ ! -e "$ENV_CLIP_LOG" ]
}

@test "env platform: WSL falls back to the Windows clip.exe outside PATH" {
  mkdir -p "$TEST_TEMP_DIR/windows/System32"
  cp "$ENV_CLIP_RECORDER" "$TEST_TEMP_DIR/windows/System32/clip.exe"
  export ENV_WINDOWS_CLIP="$TEST_TEMP_DIR/windows/System32/clip.exe"

  run run_zsh '
    OSTYPE=linux-gnu
    unset DISPLAY WAYLAND_DISPLAY
    # No clip.exe on PATH, as with appendWindowsPath=false.
    whence() {
      [[ "$1" == -p && "$2" == clip.exe ]] && return 1
      builtin whence "$@"
    }
    _env_wsl_windows_clip_path() { REPLY="$ENV_WINDOWS_CLIP"; }
    _env_host_is_wsl() { return 0; }
    export ENV_COPY_VALUE=plain
    env-list --copy ENV_COPY_VALUE || return 91
    _env_host_is_wsl() { return 1; }
    env-list --copy ENV_COPY_VALUE
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"Copied 'ENV_COPY_VALUE' to the clipboard."* ]]
  [[ "$output" == *"No supported clipboard backend is available; the value was not printed."* ]]
  [ "$(clip_hex)" = "ff fe 70 00 6c 00 61 00 69 00 6e 00" ]
}

@test "env platform: WSL is detected from interop, late interop, or the kernel release" {
  run run_zsh '
    OSTYPE=linux-gnu
    unset WSL_DISTRO_NAME WSL_INTEROP
    local case_name fixture release
    for case_name in interop late kernel native; do
      fixture="$HOME/proc-$case_name"
      command mkdir -p "$fixture/sys/fs/binfmt_misc" "$fixture/sys/kernel"
      release="6.8.0-generic"
      case "$case_name" in
        interop) : > "$fixture/sys/fs/binfmt_misc/WSLInterop" ;;
        late) : > "$fixture/sys/fs/binfmt_misc/WSLInterop-late" ;;
        kernel) release="4.4.0-19041-Microsoft" ;;
      esac
      print -r -- "$release" > "$fixture/sys/kernel/osrelease"
      if _env_host_is_wsl "$fixture"; then
        print -r -- "$case_name=WSL"
      else
        print -r -- "$case_name=Linux"
      fi
    done
    OSTYPE=darwin24.0
    WSL_DISTRO_NAME=Ubuntu _env_host_is_wsl || print -r -- "darwin=not-WSL"
  '

  [ "$status" -eq 0 ]
  [ "$output" = $'interop=WSL\nlate=WSL\nkernel=WSL\nnative=Linux\ndarwin=not-WSL' ]
}

@test "env platform: pbcopy runs with a UTF-8 locale on macOS" {
  cp "$ENV_CLIP_RECORDER" "$TEST_MOCK_BIN/pbcopy"

  local locale_name expected
  for locale_name in C en_US.UTF-8; do
    export ENV_TEST_LOCALE="$locale_name"
    run run_zsh '
      OSTYPE=darwin24.0
      export LANG="$ENV_TEST_LOCALE"
      unset LC_ALL LC_CTYPE
      export ENV_COPY_VALUE=$'"'"'caf\303\251'"'"'
      env-list --copy ENV_COPY_VALUE
    '
    [ "$status" -eq 0 ]
    [ "$(clip_hex)" = "63 61 66 c3 a9" ]
    expected="LC_ALL=unset"
    [ "$locale_name" = C ] && expected="LC_ALL=en_US.UTF-8"
    [ "$(cat "$ENV_CLIP_LOG.env")" = "$expected" ]
  done
}

@test "env platform: PATH entries with a trailing slash are duplicates" {
  mkdir -p "$HOME/bin" "$HOME/tools"
  export ENV_TEST_PATH="$HOME/bin:$HOME/tools/:$HOME/bin/:$HOME/tools//:/usr/bin"

  run run_zsh '
    PATH="$ENV_TEST_PATH" env-path --list
  '
  [ "$status" -eq 0 ]
  [ "$(cut -f5 <<< "$output" | tr '\n' ' ')" = "no no yes yes no " ]

  run run_zsh '
    PATH="$ENV_TEST_PATH"
    NO_COLOR=1 env-path --dedupe --yes || return 91
    print -r -- "PATH=$PATH"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"remove later duplicate: $HOME/bin/ (same as $HOME/bin)"* ]]
  [[ "$output" == *"remove later duplicate: $HOME/tools// (same as $HOME/tools/)"* ]]
  [[ "$output" == *"PATH=$HOME/bin:$HOME/tools/:/usr/bin"* ]]
}

@test "env platform: PATH entries that differ only by case are reported and kept" {
  mkdir -p "$HOME/Tools" "$HOME/tools"
  export ENV_TEST_PATH="$HOME/tools:$HOME/Tools:/usr/bin:/USR/BIN/"

  run run_zsh '
    PATH="$ENV_TEST_PATH" NO_COLOR=1 env-path
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"No duplicate PATH entries were detected."* ]]
  [[ "$output" == *"2 PATH entries differ from earlier entries only by letter case; deduplication keeps them."* ]]
  [[ "$output" == *"$HOME/Tools matches $HOME/tools"* ]]
  [[ "$output" == *"/USR/BIN/ matches /usr/bin"* ]]

  run run_zsh '
    PATH="$ENV_TEST_PATH"
    NO_COLOR=1 env-path --dedupe --yes || return 91
    print -r -- "PATH=$PATH"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"PATH is already deduplicated."* ]]
  [[ "$output" == *"PATH=$ENV_TEST_PATH"* ]]

  export ENV_TEST_PATH="$HOME/tools:$HOME/tools:$HOME/Tools"
  run run_zsh 'PATH="$ENV_TEST_PATH" NO_COLOR=1 env-path'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Detected 1 duplicate PATH entry."* ]]
  [[ "$output" == *"1 PATH entry differs from an earlier entry only by letter case; deduplication keeps it."* ]]
}
