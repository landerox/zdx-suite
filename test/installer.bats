#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  INSTALLER_BASH=$(command -v bash)
  INSTALLER_ZSH=$(command -v zsh)
  INSTALLER_PYTHON=$(python3 -I -c 'import sys; print(sys.executable)')
  INSTALLER_ENV=$(command -v env)
  load test_helper

  INSTALLER_HOME="$HOME"
  INSTALLER_SOURCE="$TEST_TEMP_DIR/reviewed checkout"
  INSTALLER_SHELL_ROOT="$HOME/.oh-my-zsh"
  INSTALLER_CUSTOM="$INSTALLER_SHELL_ROOT/custom"
  INSTALLER_ZDOTDIR="$HOME"
  INSTALLER_PATH="$TEST_TEMP_DIR/installer-bin"
  INSTALLER_STDOUT="$TEST_TEMP_DIR/installer.stdout"
  INSTALLER_STDERR="$TEST_TEMP_DIR/installer.stderr"
  INSTALLER_CALLS="$TEST_TEMP_DIR/forbidden-calls"
  INSTALLER_SEND_ZSH=1
  INSTALLER_SEND_CUSTOM=1

  mkdir -p "$INSTALLER_SOURCE/scripts" "$INSTALLER_SOURCE/.config/zdx" \
    "$INSTALLER_SHELL_ROOT" "$INSTALLER_PATH"
  cp "$TEST_SUITE_ROOT/scripts/install.sh" \
    "$TEST_SUITE_ROOT/scripts/install.zsh" \
    "$TEST_SUITE_ROOT/scripts/install_fs.py" "$INSTALLER_SOURCE/scripts/"
  cp "$TEST_SUITE_ROOT/functions.zsh" \
    "$TEST_SUITE_ROOT/zdx-suite.plugin.zsh" "$INSTALLER_SOURCE/"
  cp "$TEST_SUITE_ROOT/.config/zdx/config.zsh.example" \
    "$INSTALLER_SOURCE/.config/zdx/"
  INSTALLER_SCRIPT="$INSTALLER_SOURCE/scripts/install.sh"
  printf '# Controlled Oh My Zsh entrypoint fixture.\n' \
    > "$INSTALLER_SHELL_ROOT/oh-my-zsh.sh"
  printf '# Preserve this exact file.\nplugins=(git)\n' > "$HOME/.zshrc"
  cp "$HOME/.zshrc" "$TEST_TEMP_DIR/zshrc.before"

  ln -s "$INSTALLER_ZSH" "$INSTALLER_PATH/zsh"
  ln -s "$INSTALLER_PYTHON" "$INSTALLER_PATH/python3"
  : > "$INSTALLER_CALLS"
  local forbidden_command
  for forbidden_command in git curl wget sudo apt apt-get dnf brew; do
    cat > "$INSTALLER_PATH/$forbidden_command" <<'SH'
#!/bin/sh
printf '%s\n' "$0 $*" >> "$ZDX_INSTALLER_FORBIDDEN_CALLS"
exit 97
SH
    chmod +x "$INSTALLER_PATH/$forbidden_command"
  done
}

teardown() {
  cleanup_sandbox
}

_installer_exec() {
  local -a installer_environment=(
    "HOME=$INSTALLER_HOME" "PATH=$INSTALLER_PATH" "LC_ALL=C" "TERM=dumb"
    "ZDOTDIR=$INSTALLER_ZDOTDIR"
    "ZDX_INSTALLER_FORBIDDEN_CALLS=$INSTALLER_CALLS"
  )
  if [[ "$INSTALLER_SEND_ZSH" == 1 ]]; then
    installer_environment+=("ZSH=$INSTALLER_SHELL_ROOT")
  fi
  if [[ "$INSTALLER_SEND_CUSTOM" == 1 ]]; then
    installer_environment+=("ZSH_CUSTOM=$INSTALLER_CUSTOM")
  fi
  "$INSTALLER_ENV" -i "${installer_environment[@]}" \
    "$INSTALLER_BASH" "$INSTALLER_SCRIPT" "$@" \
    </dev/null > "$INSTALLER_STDOUT" 2> "$INSTALLER_STDERR"
}

_installer_with_umask() (
  umask "$1"
  shift
  _installer_exec "$@"
)

_installer_no_publication() {
  [ ! -e "$INSTALLER_CUSTOM/plugins/zdx-suite" ]
  [ ! -L "$INSTALLER_CUSTOM/plugins/zdx-suite" ]
  [ ! -e "$INSTALLER_HOME/.config/zdx/config.zsh" ]
  [ ! -L "$INSTALLER_HOME/.config/zdx/config.zsh" ]
  [ ! -s "$INSTALLER_CALLS" ]
}

_installer_stderr_only() {
  [ ! -s "$INSTALLER_STDOUT" ]
  [ -s "$INSTALLER_STDERR" ]
  [ ! -s "$INSTALLER_CALLS" ]
}

_installer_interactive_exec() {
  "$INSTALLER_PYTHON" -I - "$INSTALLER_BASH" "$INSTALLER_SCRIPT" \
    "$INSTALLER_HOME" "$INSTALLER_PATH" "$INSTALLER_SHELL_ROOT" \
    "$INSTALLER_CUSTOM" "$INSTALLER_ZDOTDIR" "$INSTALLER_CALLS" \
    "$TEST_TEMP_DIR/installer.pty" "$1" <<'PY'
import errno
import os
import pathlib
import pty
import select
import signal
import sys
import time

shell, script, home, search_path, framework, custom, dotdir, calls, log, action = sys.argv[1:]
environment = {
    'HOME': home, 'PATH': search_path, 'ZSH': framework, 'ZSH_CUSTOM': custom,
    'ZDOTDIR': dotdir, 'LC_ALL': 'C', 'TERM': 'dumb',
    'ZDX_INSTALLER_FORBIDDEN_CALLS': calls,
}
child, terminal = pty.fork()
if child == 0:
    os.execve(shell, [shell, script], environment)
captured = bytearray()
answered = False
wait_status = None
deadline = time.monotonic() + 10
try:
    while time.monotonic() < deadline:
        if select.select([terminal], [], [], 0.05)[0]:
            try:
                chunk = os.read(terminal, 65536)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                chunk = b''
            captured.extend(chunk)
        if b'[y/N]' in captured and not answered:
            if action == 'config-race':
                config_directory = pathlib.Path(home) / '.config/zdx'
                config_directory.mkdir(mode=0o700, parents=True)
                config_file = config_directory / 'config.zsh'
                descriptor = os.open(config_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(descriptor, 'w') as stream:
                    stream.write('# Published independently during confirmation.\n')
            os.write(terminal, b'n' if action == 'decline' else b'y')
            answered = True
        finished, observed = os.waitpid(child, os.WNOHANG)
        if finished:
            wait_status = observed
            break
    if wait_status is None:
        os.killpg(child, signal.SIGKILL)
        _, wait_status = os.waitpid(child, 0)
        raise RuntimeError('installer confirmation exceeded the bounded PTY deadline')
finally:
    os.close(terminal)
    pathlib.Path(log).write_bytes(captured)
if not answered:
    raise RuntimeError('installer never displayed its confirmation prompt')
if os.WIFSIGNALED(wait_status):
    sys.exit(128 + os.WTERMSIG(wait_status))
sys.exit(os.WEXITSTATUS(wait_status))
PY
}

@test "installer: direct Zsh help needs no Python and writes UI only to stderr" {
  rm "$INSTALLER_PATH/zsh" "$INSTALLER_PATH/python3"
  INSTALLER_BASH="$INSTALLER_ZSH"
  INSTALLER_SCRIPT="$INSTALLER_SOURCE/scripts/install.zsh"
  run _installer_exec --help
  [ "$status" -eq 0 ]
  _installer_stderr_only
  _installer_no_publication
  grep -Fq -- '--dry-run' "$INSTALLER_STDERR"
  grep -Fq -- '--yes' "$INSTALLER_STDERR"
}

@test "installer: Bash help needs neither Zsh nor Python and does not write files" {
  rm "$INSTALLER_PATH/zsh" "$INSTALLER_PATH/python3"
  run _installer_exec --help
  [ "$status" -eq 0 ]
  _installer_stderr_only
  _installer_no_publication
}

@test "installer: invalid grammar returns 2 before dependency probes or writes" {
  rm "$INSTALLER_PATH/zsh" "$INSTALLER_PATH/python3"
  local invalid_argument
  for invalid_argument in --unknown update -- ''; do
    run _installer_exec "$invalid_argument"
    [ "$status" -eq 2 ]
    _installer_stderr_only
    _installer_no_publication
  done
  run _installer_exec --help --yes
  [ "$status" -eq 2 ]
  run _installer_exec --dry-run --unexpected
  [ "$status" -eq 2 ]
  _installer_no_publication
}

@test "installer: missing Zsh fails before any publication" {
  rm "$INSTALLER_PATH/zsh"
  run _installer_exec --yes
  [ "$status" -eq 1 ]
  _installer_stderr_only
  _installer_no_publication
}

@test "installer: missing Python fails before dry-run or installation writes" {
  rm "$INSTALLER_PATH/python3"
  run _installer_exec --dry-run
  [ "$status" -eq 1 ]
  _installer_no_publication
  run _installer_exec --yes
  [ "$status" -eq 1 ]
  _installer_stderr_only
  _installer_no_publication
}

@test "installer: redirected input requires explicit yes before creating parents" {
  run _installer_exec
  [ "$status" -eq 1 ]
  _installer_stderr_only
  _installer_no_publication
  [ ! -e "$INSTALLER_CUSTOM" ]
  [ ! -e "$HOME/.config" ]
  cmp "$HOME/.zshrc" "$TEST_TEMP_DIR/zshrc.before"
}

@test "installer: dry-run describes the local plan without creating parents" {
  run _installer_exec --dry-run
  [ "$status" -eq 0 ]
  _installer_stderr_only
  _installer_no_publication
  [ ! -e "$INSTALLER_CUSTOM" ]
  [ ! -e "$HOME/.config" ]
  cmp "$HOME/.zshrc" "$TEST_TEMP_DIR/zshrc.before"
  grep -Fq "$INSTALLER_SOURCE" "$INSTALLER_STDERR"
}

@test "installer: declining a real terminal confirmation succeeds without writes" {
  run _installer_interactive_exec decline
  [ "$status" -eq 0 ]
  _installer_no_publication
  [ ! -e "$INSTALLER_CUSTOM" ]
  [ ! -e "$HOME/.config" ]
  cmp "$HOME/.zshrc" "$TEST_TEMP_DIR/zshrc.before"
}

@test "installer: config published during confirmation is never overwritten" {
  run _installer_interactive_exec config-race
  [ "$status" -eq 1 ]
  [ "$(cat "$HOME/.config/zdx/config.zsh")" = '# Published independently during confirmation.' ]
  [ ! -e "$INSTALLER_CUSTOM/plugins/zdx-suite" ]
  [ ! -L "$INSTALLER_CUSTOM/plugins/zdx-suite" ]
  [ ! -s "$INSTALLER_CALLS" ]
}

@test "installer: local installation needs no Git and preserves shell startup bytes" {
  run _installer_exec --yes
  [ "$status" -eq 0 ]
  _installer_stderr_only
  [ -L "$INSTALLER_CUSTOM/plugins/zdx-suite" ]
  [ "$(readlink "$INSTALLER_CUSTOM/plugins/zdx-suite")" = "$INSTALLER_SOURCE" ]
  cmp "$INSTALLER_SOURCE/.config/zdx/config.zsh.example" \
    "$HOME/.config/zdx/config.zsh"
  cmp "$HOME/.zshrc" "$TEST_TEMP_DIR/zshrc.before"
  run "$INSTALLER_PYTHON" -I - "$HOME/.config/zdx" <<'PY'
import pathlib
import stat
import sys

directory = pathlib.Path(sys.argv[1])
assert stat.S_IMODE(directory.stat().st_mode) == 0o700
assert stat.S_IMODE((directory / 'config.zsh').stat().st_mode) == 0o600
PY
  [ "$status" -eq 0 ]
}

@test "installer: permissive and restrictive caller umasks still create usable private files" {
  local caller_mask
  for caller_mask in 000 0777; do
    INSTALLER_HOME="$HOME/umask-$caller_mask"
    INSTALLER_CUSTOM="$INSTALLER_HOME/custom"
    mkdir -m 700 "$INSTALLER_HOME"
    run _installer_with_umask "$caller_mask" --yes
    [ "$status" -eq 0 ]
    _installer_stderr_only
    run "$INSTALLER_PYTHON" -I - "$INSTALLER_HOME" <<'PY'
import pathlib
import stat
import sys

home = pathlib.Path(sys.argv[1])
for relative in ('.config', '.config/zdx', 'custom', 'custom/plugins'):
    assert stat.S_IMODE((home / relative).stat().st_mode) == 0o700
config = home / '.config/zdx/config.zsh'
assert stat.S_IMODE(config.stat().st_mode) == 0o600
assert config.read_bytes()
assert (home / 'custom/plugins/zdx-suite').is_symlink()
PY
    [ "$status" -eq 0 ]
  done
}

@test "installer: a second installation preserves the existing link and private config" {
  run _installer_exec --yes
  [ "$status" -eq 0 ]
  printf '# Keep user configuration.\n' > "$HOME/.config/zdx/config.zsh"
  local before
  before=$("$INSTALLER_PYTHON" -I -c \
    'import os,sys; print(os.lstat(sys.argv[1]).st_ino, os.stat(sys.argv[2]).st_ino)' \
    "$INSTALLER_CUSTOM/plugins/zdx-suite" "$HOME/.config/zdx/config.zsh")
  run _installer_exec --yes
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.config/zdx/config.zsh")" = '# Keep user configuration.' ]
  [ "$("$INSTALLER_PYTHON" -I -c \
    'import os,sys; print(os.lstat(sys.argv[1]).st_ino, os.stat(sys.argv[2]).st_ino)' \
    "$INSTALLER_CUSTOM/plugins/zdx-suite" "$HOME/.config/zdx/config.zsh")" = "$before" ]
  _installer_stderr_only
}

@test "installer: running from the installed checkout never replaces or deletes itself" {
  mkdir -p "$INSTALLER_CUSTOM/plugins"
  mv "$INSTALLER_SOURCE" "$INSTALLER_CUSTOM/plugins/zdx-suite"
  INSTALLER_SOURCE="$INSTALLER_CUSTOM/plugins/zdx-suite"
  INSTALLER_SCRIPT="$INSTALLER_SOURCE/scripts/install.sh"
  run _installer_exec --yes
  [ "$status" -eq 0 ]
  [ -d "$INSTALLER_SOURCE" ]
  [ ! -L "$INSTALLER_SOURCE" ]
  cmp "$TEST_SUITE_ROOT/scripts/install.zsh" "$INSTALLER_SOURCE/scripts/install.zsh"
  cmp "$TEST_SUITE_ROOT/functions.zsh" "$INSTALLER_SOURCE/functions.zsh"
  [ -f "$HOME/.config/zdx/config.zsh" ]
  _installer_stderr_only
}

@test "installer: an existing plugin directory is preserved and blocks config creation" {
  mkdir -p "$INSTALLER_CUSTOM/plugins/zdx-suite"
  printf 'valuable content\n' > "$INSTALLER_CUSTOM/plugins/zdx-suite/keep"
  run _installer_exec --yes
  [ "$status" -eq 1 ]
  [ "$(cat "$INSTALLER_CUSTOM/plugins/zdx-suite/keep")" = 'valuable content' ]
  [ ! -L "$INSTALLER_CUSTOM/plugins/zdx-suite" ]
  [ ! -e "$HOME/.config" ]
  _installer_stderr_only
}

@test "installer: an existing plugin file is never removed" {
  mkdir -p "$INSTALLER_CUSTOM/plugins"
  printf 'valuable file\n' > "$INSTALLER_CUSTOM/plugins/zdx-suite"
  run _installer_exec --yes
  [ "$status" -eq 1 ]
  [ "$(cat "$INSTALLER_CUSTOM/plugins/zdx-suite")" = 'valuable file' ]
  [ ! -e "$HOME/.config" ]
  _installer_stderr_only
}

@test "installer: a foreign plugin symlink is preserved with its destination" {
  mkdir -p "$INSTALLER_CUSTOM/plugins" "$TEST_TEMP_DIR/other-checkout"
  printf 'valuable content\n' > "$TEST_TEMP_DIR/other-checkout/keep"
  ln -s "$TEST_TEMP_DIR/other-checkout" "$INSTALLER_CUSTOM/plugins/zdx-suite"
  run _installer_exec --yes
  [ "$status" -eq 1 ]
  [ "$(readlink "$INSTALLER_CUSTOM/plugins/zdx-suite")" = "$TEST_TEMP_DIR/other-checkout" ]
  [ "$(cat "$TEST_TEMP_DIR/other-checkout/keep")" = 'valuable content' ]
  [ ! -e "$HOME/.config" ]
  _installer_stderr_only
}

@test "installer: a dangling plugin symlink is preserved" {
  mkdir -p "$INSTALLER_CUSTOM/plugins"
  ln -s "$TEST_TEMP_DIR/absent-checkout" "$INSTALLER_CUSTOM/plugins/zdx-suite"
  run _installer_exec --yes
  [ "$status" -eq 1 ]
  [ "$(readlink "$INSTALLER_CUSTOM/plugins/zdx-suite")" = "$TEST_TEMP_DIR/absent-checkout" ]
  [ ! -e "$HOME/.config" ]
  _installer_stderr_only
}

@test "installer: unsafe config permissions fail before publishing a plugin link" {
  mkdir -p "$HOME/.config/zdx"
  printf '# Preserve permissions and contents.\n' > "$HOME/.config/zdx/config.zsh"
  chmod 640 "$HOME/.config/zdx/config.zsh"
  run _installer_exec --yes
  [ "$status" -eq 1 ]
  [ ! -e "$INSTALLER_CUSTOM" ]
  [ "$(cat "$HOME/.config/zdx/config.zsh")" = '# Preserve permissions and contents.' ]
  run "$INSTALLER_PYTHON" -I -c \
    'import os,stat,sys; assert stat.S_IMODE(os.stat(sys.argv[1]).st_mode) == 0o640' \
    "$HOME/.config/zdx/config.zsh"
  [ "$status" -eq 0 ]
}

@test "installer: existing read-only private config and safe directory modes are preserved" {
  mkdir -p "$HOME/.config/zdx"
  chmod 755 "$HOME/.config/zdx"
  printf '# User-owned private config.\n' > "$HOME/.config/zdx/config.zsh"
  chmod 400 "$HOME/.config/zdx/config.zsh"
  run _installer_exec --yes
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.config/zdx/config.zsh")" = '# User-owned private config.' ]
  run "$INSTALLER_PYTHON" -I - "$HOME/.config/zdx" <<'PY'
import os
import stat
import sys

assert stat.S_IMODE(os.stat(sys.argv[1]).st_mode) == 0o755
assert stat.S_IMODE(os.stat(sys.argv[1] + '/config.zsh').st_mode) == 0o400
PY
  [ "$status" -eq 0 ]
}

@test "installer: config symlinks are refused without touching their destination" {
  mkdir -p "$HOME/.config/zdx"
  printf '# Victim remains intact.\n' > "$TEST_TEMP_DIR/victim"
  chmod 600 "$TEST_TEMP_DIR/victim"
  ln -s "$TEST_TEMP_DIR/victim" "$HOME/.config/zdx/config.zsh"
  run _installer_exec --yes
  [ "$status" -eq 1 ]
  [ ! -e "$INSTALLER_CUSTOM" ]
  [ -L "$HOME/.config/zdx/config.zsh" ]
  [ "$(cat "$TEST_TEMP_DIR/victim")" = '# Victim remains intact.' ]
  _installer_stderr_only
}

@test "installer: dangling config symlinks are refused without creating their destination" {
  mkdir -p "$HOME/.config/zdx"
  ln -s "$TEST_TEMP_DIR/absent-config" "$HOME/.config/zdx/config.zsh"
  run _installer_exec --yes
  [ "$status" -eq 1 ]
  [ ! -e "$INSTALLER_CUSTOM" ]
  [ ! -e "$TEST_TEMP_DIR/absent-config" ]
  [ -L "$HOME/.config/zdx/config.zsh" ]
  _installer_stderr_only
}

@test "installer: hardlinked config files are refused without chmod or replacement" {
  mkdir -p "$HOME/.config/zdx"
  printf '# Shared inode remains intact.\n' > "$TEST_TEMP_DIR/victim"
  chmod 600 "$TEST_TEMP_DIR/victim"
  ln "$TEST_TEMP_DIR/victim" "$HOME/.config/zdx/config.zsh"
  run _installer_exec --yes
  [ "$status" -eq 1 ]
  [ ! -e "$INSTALLER_CUSTOM" ]
  [ "$(cat "$TEST_TEMP_DIR/victim")" = '# Shared inode remains intact.' ]
  [ "$TEST_TEMP_DIR/victim" -ef "$HOME/.config/zdx/config.zsh" ]
  _installer_stderr_only
}

@test "installer: special config files are rejected without opening a FIFO" {
  mkdir -p "$HOME/.config/zdx"
  mkfifo "$HOME/.config/zdx/config.zsh"
  run _installer_exec --yes
  [ "$status" -eq 1 ]
  [ ! -e "$INSTALLER_CUSTOM" ]
  [ -p "$HOME/.config/zdx/config.zsh" ]
  _installer_stderr_only
}

@test "installer: config-directory symlinks cannot redirect or chmod writes" {
  mkdir -p "$HOME/.config" "$TEST_TEMP_DIR/victim-directory"
  chmod 755 "$TEST_TEMP_DIR/victim-directory"
  ln -s "$TEST_TEMP_DIR/victim-directory" "$HOME/.config/zdx"
  run _installer_exec --yes
  [ "$status" -eq 1 ]
  [ ! -e "$INSTALLER_CUSTOM" ]
  [ ! -e "$TEST_TEMP_DIR/victim-directory/config.zsh" ]
  run "$INSTALLER_PYTHON" -I -c \
    'import os,stat,sys; assert stat.S_IMODE(os.stat(sys.argv[1]).st_mode) == 0o755' \
    "$TEST_TEMP_DIR/victim-directory"
  [ "$status" -eq 0 ]
}

@test "installer: unsafe writable parents fail before any publication" {
  mkdir -p "$HOME/.config"
  chmod 777 "$HOME/.config"
  run _installer_exec --yes
  [ "$status" -eq 1 ]
  [ ! -e "$INSTALLER_CUSTOM" ]
  _installer_no_publication
  _installer_stderr_only
}

@test "installer: plugin-parent symlinks are rejected without writing through them" {
  mkdir -p "$INSTALLER_CUSTOM" "$TEST_TEMP_DIR/victim-plugins"
  ln -s "$TEST_TEMP_DIR/victim-plugins" "$INSTALLER_CUSTOM/plugins"
  run _installer_exec --yes
  [ "$status" -eq 1 ]
  [ ! -e "$TEST_TEMP_DIR/victim-plugins/zdx-suite" ]
  [ ! -e "$HOME/.config" ]
  _installer_stderr_only
}

@test "installer: custom Oh My Zsh and plugin paths outside HOME work with spaces" {
  INSTALLER_SHELL_ROOT="$TEST_TEMP_DIR/custom framework"
  INSTALLER_CUSTOM="$TEST_TEMP_DIR/external custom/plugins root"
  mkdir -p "$INSTALLER_SHELL_ROOT"
  printf '# Controlled framework.\n' > "$INSTALLER_SHELL_ROOT/oh-my-zsh.sh"
  run _installer_exec --yes
  [ "$status" -eq 0 ]
  [ "$(readlink "$INSTALLER_CUSTOM/plugins/zdx-suite")" = "$INSTALLER_SOURCE" ]
  [ -f "$HOME/.config/zdx/config.zsh" ]
  _installer_stderr_only
}

@test "installer: default framework and custom paths resolve from HOME" {
  INSTALLER_SEND_ZSH=0
  INSTALLER_SEND_CUSTOM=0
  run _installer_exec --yes
  [ "$status" -eq 0 ]
  [ -L "$HOME/.oh-my-zsh/custom/plugins/zdx-suite" ]
  _installer_stderr_only
}

@test "installer: custom ZSH determines the default custom directory" {
  INSTALLER_SHELL_ROOT="$TEST_TEMP_DIR/alternative framework"
  INSTALLER_CUSTOM="$INSTALLER_SHELL_ROOT/custom"
  INSTALLER_SEND_CUSTOM=0
  mkdir -p "$INSTALLER_SHELL_ROOT"
  printf '# Controlled framework.\n' > "$INSTALLER_SHELL_ROOT/oh-my-zsh.sh"
  run _installer_exec --yes
  [ "$status" -eq 0 ]
  [ -L "$INSTALLER_CUSTOM/plugins/zdx-suite" ]
  [ ! -e "$HOME/.oh-my-zsh/custom" ]
  _installer_stderr_only
}

@test "installer: ZDOTDIR receives manual startup instructions but no file edits" {
  INSTALLER_ZDOTDIR="$TEST_TEMP_DIR/shell startup"
  mkdir "$INSTALLER_ZDOTDIR"
  printf '# Do not parse or rewrite me.\nplugins=(git)\n' > "$INSTALLER_ZDOTDIR/.zshrc"
  cp "$INSTALLER_ZDOTDIR/.zshrc" "$TEST_TEMP_DIR/zdotdir.before"
  run _installer_exec --yes
  [ "$status" -eq 0 ]
  local quoted_profile
  quoted_profile=$("$INSTALLER_ZSH" -f -c 'print -r -- "${(q)1}/.zshrc"' _ "$INSTALLER_ZDOTDIR")
  grep -Fq "$quoted_profile" "$INSTALLER_STDERR"
  cmp "$INSTALLER_ZDOTDIR/.zshrc" "$TEST_TEMP_DIR/zdotdir.before"
  cmp "$HOME/.zshrc" "$TEST_TEMP_DIR/zshrc.before"
  _installer_stderr_only
}

@test "installer: absent shell startup files are not created" {
  rm "$HOME/.zshrc"
  run _installer_exec --yes
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.zshrc" ]
  _installer_stderr_only
}

@test "installer: shell-startup symlinks and their contents are never edited" {
  mv "$HOME/.zshrc" "$TEST_TEMP_DIR/startup-victim"
  ln -s "$TEST_TEMP_DIR/startup-victim" "$HOME/.zshrc"
  run _installer_exec --yes
  [ "$status" -eq 0 ]
  [ -L "$HOME/.zshrc" ]
  cmp "$TEST_TEMP_DIR/startup-victim" "$TEST_TEMP_DIR/zshrc.before"
  _installer_stderr_only
}

@test "installer: an explicit HOME alias resolves to the same private installation" {
  ln -s "$HOME" "$TEST_TEMP_DIR/home-alias"
  INSTALLER_HOME="$TEST_TEMP_DIR/home-alias"
  run _installer_exec --yes
  [ "$status" -eq 0 ]
  [ -L "$INSTALLER_CUSTOM/plugins/zdx-suite" ]
  [ -f "$HOME/.config/zdx/config.zsh" ]
  _installer_stderr_only
}

@test "installer: relative custom paths are rejected before any publication" {
  INSTALLER_CUSTOM='relative-custom'
  run _installer_exec --yes
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/.config" ]
  _installer_stderr_only
}

@test "installer: missing Oh My Zsh entrypoint fails before writes" {
  rm "$INSTALLER_SHELL_ROOT/oh-my-zsh.sh"
  run _installer_exec --yes
  [ "$status" -eq 1 ]
  _installer_no_publication
  [ ! -e "$INSTALLER_CUSTOM" ]
  [ ! -e "$HOME/.config" ]
  _installer_stderr_only
}

@test "installer: missing local checkout files never fall back to downloading" {
  rm "$INSTALLER_SOURCE/functions.zsh"
  run _installer_exec --yes
  [ "$status" -eq 1 ]
  _installer_no_publication
  _installer_stderr_only
}

@test "installer: a copied launcher cannot clone an unreviewed checkout" {
  cp "$INSTALLER_SCRIPT" "$TEST_TEMP_DIR/install.sh"
  INSTALLER_SCRIPT="$TEST_TEMP_DIR/install.sh"
  run _installer_exec --yes
  [ "$status" -eq 1 ]
  _installer_no_publication
  _installer_stderr_only
}

@test "installer: writable checkout files are rejected before publication" {
  chmod 666 "$INSTALLER_SOURCE/.config/zdx/config.zsh.example"
  run _installer_exec --yes
  [ "$status" -eq 1 ]
  _installer_no_publication
  _installer_stderr_only
}

@test "installer: symlinked checkout files are rejected before publication" {
  mv "$INSTALLER_SOURCE/.config/zdx/config.zsh.example" "$TEST_TEMP_DIR/template"
  ln -s "$TEST_TEMP_DIR/template" "$INSTALLER_SOURCE/.config/zdx/config.zsh.example"
  run _installer_exec --yes
  [ "$status" -eq 1 ]
  _installer_no_publication
  _installer_stderr_only
}

@test "installer: hardlinked checkout files are rejected before publication" {
  ln "$INSTALLER_SOURCE/.config/zdx/config.zsh.example" "$TEST_TEMP_DIR/shared-template"
  run _installer_exec --yes
  [ "$status" -eq 1 ]
  _installer_no_publication
  _installer_stderr_only
}

@test "installer: a symlinked launcher is rejected before publication" {
  ln -s "$INSTALLER_SCRIPT" "$TEST_TEMP_DIR/launcher-link"
  INSTALLER_SCRIPT="$TEST_TEMP_DIR/launcher-link"
  run _installer_exec --yes
  [ "$status" -eq 1 ]
  _installer_no_publication
  _installer_stderr_only
}

@test "installer: bash command strings and stdin execution cannot install" {
  local installer_contents
  installer_contents=$(cat "$INSTALLER_SCRIPT")
  run "$INSTALLER_ENV" -i "HOME=$HOME" "PATH=$INSTALLER_PATH" \
    "ZDX_INSTALLER_FORBIDDEN_CALLS=$INSTALLER_CALLS" \
    "$INSTALLER_BASH" -c "$installer_contents" -- --yes
  [ "$status" -eq 1 ]
  _installer_no_publication
  run "$INSTALLER_ENV" -i "HOME=$HOME" "PATH=$INSTALLER_PATH" \
    "ZDX_INSTALLER_FORBIDDEN_CALLS=$INSTALLER_CALLS" \
    "$INSTALLER_BASH" -s -- --yes < "$INSTALLER_SCRIPT"
  [ "$status" -eq 1 ]
  _installer_no_publication
}

@test "installer: sourcing the Bash launcher does not exit or alter shell options" {
  run "$INSTALLER_ENV" -i "HOME=$HOME" "PATH=$INSTALLER_PATH" \
    "$INSTALLER_BASH" -c '
      before=$-
      source "$1" --yes >/dev/null 2>&1
      source_rc=$?
      [[ "$source_rc" == 1 && "$-" == "$before" ]] || exit 9
      printf "caller survived\n"
    ' _ "$INSTALLER_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = 'caller survived' ]
  _installer_no_publication
}

@test "installer: sourcing the Zsh implementation is passive and preserves caller options" {
  run "$INSTALLER_ENV" -i "HOME=$HOME" "PATH=$INSTALLER_PATH" \
    "$INSTALLER_ZSH" -f -c '
      before=$-
      source "$1" --yes || exit
      [[ "$-" == "$before" ]] || exit 9
      print -r -- "caller survived"
    ' _ "$INSTALLER_SOURCE/scripts/install.zsh"
  [ "$status" -eq 0 ]
  [ "$output" = 'caller survived' ]
  _installer_no_publication
}

# Inject faults only at native filesystem calls. The transaction still operates
# on real disposable files, and production code has no test-only bypass hooks.
_installer_transaction_fault() {
  "$INSTALLER_PYTHON" -I - "$INSTALLER_SOURCE/scripts/install_fs.py" \
    "$INSTALLER_SOURCE" "$INSTALLER_HOME" "$INSTALLER_SHELL_ROOT" \
    "$INSTALLER_CUSTOM" "$INSTALLER_ZDOTDIR" "$1" <<'PY'
import importlib.util
import io
import json
import os
import pathlib
import signal
import sys

helper, source, home, framework, custom, profile, action = sys.argv[1:]
spec = importlib.util.spec_from_file_location('isolated_installer', helper)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
inputs = [source, home, framework, custom, profile]
config_directory = pathlib.Path(home) / '.config/zdx'
config = config_directory / 'config.zsh'
target = pathlib.Path(custom) / 'plugins/zdx-suite'
original_fsync = os.fsync
original_symlink = os.symlink

def apply():
    plan = module._zdx_install_plan(inputs)
    sys.argv = [helper, 'apply']
    sys.stdin = io.StringIO(json.dumps(plan))
    return module._zdx_install_main()

def independent_config():
    descriptor = os.open(config, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        stream.write('# Independently published config.\n')

try:
    if action == 'signals':
        for signum, expected_status in ((signal.SIGINT, 130), (signal.SIGTERM, 143)):
            def interrupt_after_flush(descriptor):
                original_fsync(descriptor)
                os.kill(os.getpid(), signum)
            os.fsync = interrupt_after_flush
            assert apply() == expected_status
            assert not config.exists() and not target.is_symlink()
            assert not list(config_directory.glob('.zdx-install-*'))
    elif action == 'staging-replacement':
        def replace_then_interrupt(descriptor):
            original_fsync(descriptor)
            staging, = config_directory.glob('.zdx-install-*')
            staging.unlink()
            staging.write_text('independent staging replacement\n')
            os.kill(os.getpid(), signal.SIGTERM)
        os.fsync = replace_then_interrupt
        assert apply() == 143
        staging, = config_directory.glob('.zdx-install-*')
        assert staging.read_text() == 'independent staging replacement\n'
        assert not config.exists() and not target.is_symlink()
    elif action == 'config-collision':
        def publish_before_link(descriptor):
            original_fsync(descriptor)
            independent_config()
        os.fsync = publish_before_link
        assert apply() == 1
        assert config.read_text() == '# Independently published config.\n'
        assert not target.is_symlink()
        assert not list(config_directory.glob('.zdx-install-*'))
    elif action == 'partial-retry':
        def reject_plugin_link(*arguments, **keywords):
            raise OSError('injected plugin publication failure')
        os.symlink = reject_plugin_link
        assert apply() == 1
        assert config.is_file() and not target.is_symlink()
        assert not list(config_directory.glob('.zdx-install-*'))
        published_inode = config.stat().st_ino
        published_bytes = config.read_bytes()
        os.symlink = original_symlink
        assert apply() == 0
        assert target.is_symlink() and os.readlink(target) == source
        assert config.stat().st_ino == published_inode
        assert config.read_bytes() == published_bytes
        assert config.stat().st_nlink == 1
    else:
        raise AssertionError('unknown controlled filesystem fault')
finally:
    os.fsync = original_fsync
    os.symlink = original_symlink
PY
}

@test "installer: INT and TERM clean owned staging and preserve interruption statuses" {
  run _installer_transaction_fault signals
  [ "$status" -eq 0 ]
  [[ "$output" == *'interrupted'* ]]
  [ ! -s "$INSTALLER_CALLS" ]
}

@test "installer: interruption cleanup retains a replaced staging object" {
  run _installer_transaction_fault staging-replacement
  [ "$status" -eq 0 ]
  [[ "$output" == *'staging identity changed'* ]]
  [ ! -s "$INSTALLER_CALLS" ]
}

@test "installer: atomic config publication does not overwrite a concurrent file" {
  run _installer_transaction_fault config-collision
  [ "$status" -eq 0 ]
  [ ! -s "$INSTALLER_CALLS" ]
}

@test "installer: retry preserves a published config after plugin publication fails" {
  run _installer_transaction_fault partial-retry
  [ "$status" -eq 0 ]
  [[ "$output" == *'failed after creating'* ]]
  [ ! -s "$INSTALLER_CALLS" ]
}
