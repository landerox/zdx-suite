#!/usr/bin/env bats

setup() {
  load test_helper
  export PY_DISCOVERY_PROJECT="$HOME/projects/demo"
  mkdir -p "$PY_DISCOVERY_PROJECT"
}

teardown() {
  cleanup_sandbox
}

write_venv() {
  mkdir -p "$1"
  printf 'version = 3.12.1\n' > "$1/pyvenv.cfg"
}

@test "py discovery: an empty virtualenvs directory leaves ordinary projects usable" {
  mkdir "$PY_DISCOVERY_PROJECT/.virtualenvs"
  run --separate-stderr run_zsh 'cd "$PY_DISCOVERY_PROJECT" || return; venv-list'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *'No validated project-local virtual environments found.'* ]]

  write_venv "$PY_DISCOVERY_PROJECT/.venv"
  : > "$PY_DISCOVERY_PROJECT/.virtualenvs/README.txt"
  run --separate-stderr run_zsh 'cd "$PY_DISCOVERY_PROJECT" || return; venv-list'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  printf '%s\n' "$stderr" | grep -Eq '^  [.]venv +3[.]12[.]1 +inactive$'
  [[ "$stderr" != *README.txt* ]]
}

@test "py discovery: refused entries leave healthy siblings visible and unchanged" {
  local container="$PY_DISCOVERY_PROJECT/.virtualenvs" rejected=$'bad\nname'
  write_venv "$PY_DISCOVERY_PROJECT/.venv"
  write_venv "$container/healthy"
  write_venv "$container/$rejected"
  mkdir "$PY_DISCOVERY_PROJECT/venv"
  write_venv "$HOME/foreign"
  ln -s "$HOME/foreign" "$container/linked"

  run --separate-stderr run_zsh 'cd "$PY_DISCOVERY_PROJECT" || return; venv-list'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  printf '%s\n' "$stderr" | grep -Eq '^  [.]venv +3[.]12[.]1 +inactive$'
  printf '%s\n' "$stderr" | grep -Eq '^  [.]virtualenvs/healthy +3[.]12[.]1 +inactive$'
  [[ "$stderr" == *'bad\nname'* ]]
  [[ "$stderr" != *"$rejected"* ]]
  [[ "$stderr" == *'.virtualenvs/linked'* ]]
  [[ "$stderr" == *'/demo/venv'* ]]
  [[ "$stderr" == *'ownership, permissions, and pyvenv.cfg'* ]]
  [ -f "$container/$rejected/pyvenv.cfg" ]
  [ -L "$container/linked" ]
  [ -f "$HOME/foreign/pyvenv.cfg" ]
}

@test "py discovery: a refused virtualenvs container does not hide the default environment" {
  write_venv "$PY_DISCOVERY_PROJECT/.venv"
  write_venv "$HOME/foreign/foreign-only"
  ln -s "$HOME/foreign" "$PY_DISCOVERY_PROJECT/.virtualenvs"

  run --separate-stderr run_zsh 'cd "$PY_DISCOVERY_PROJECT" || return; venv-list'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  printf '%s\n' "$stderr" | grep -Eq '^  [.]venv +3[.]12[.]1 +inactive$'
  [[ "$stderr" == *'Skipping unsafe .virtualenvs directory'* ]]
  [[ "$stderr" != *'foreign-only'* ]]
  [ -L "$PY_DISCOVERY_PROJECT/.virtualenvs" ]
}

@test "py discovery: incomplete and failed inventories do not publish an environment" {
  write_venv "$PY_DISCOVERY_PROJECT/.venv"
  write_venv "$PY_DISCOVERY_PROJECT/.virtualenvs/healthy"
  cat > "$TEST_MOCK_BIN/find" <<'EOF'
#!/bin/sh
[ "$1" = "$PY_DISCOVERY_PROJECT/.virtualenvs" ] || exit 97
if [ "$PY_DISCOVERY_FIND_MODE" = incomplete ]; then
  printf '%s' "$1/healthy"
else
  printf '%s\000' "$1/healthy"
  exit 17
fi
EOF
  chmod -- 700 "$TEST_MOCK_BIN/find"

  export PY_DISCOVERY_FIND_MODE=incomplete
  run --separate-stderr run_zsh 'cd "$PY_DISCOVERY_PROJECT" || return; venv-list'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *'contained an incomplete record'* ]]
  [[ "$stderr" != *'inactive'* ]]

  export PY_DISCOVERY_FIND_MODE=failed
  run --separate-stderr run_zsh 'cd "$PY_DISCOVERY_PROJECT" || return; venv-list'
  [ "$status" -eq 17 ]
  [ -z "$output" ]
  [[ "$stderr" == *'failed (status 17)'* ]]
  [[ "$stderr" != *'inactive'* ]]
}

@test "py discovery: info uses local selection for implicit foreign activation" {
  write_venv "$PY_DISCOVERY_PROJECT/.venv"
  write_venv "$HOME/foreign"

  run --separate-stderr run_zsh '
    cd "$PY_DISCOVERY_PROJECT" || return
    VIRTUAL_ENV="$HOME/foreign" venv-info
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  printf '%s\n' "$stderr" | grep -Eq '^  Environment: +.*/demo/[.]venv$'
  printf '%s\n' "$stderr" | grep -Eq '^  State: +inactive$'

  run --separate-stderr run_zsh '
    cd "$PY_DISCOVERY_PROJECT" || return
    venv-info --path "$HOME/foreign"
  '
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *'not in the validated discovery snapshot'* ]]
}

@test "py discovery: activation accepts a trusted parent alias for bin and python" {
  write_venv "$PY_DISCOVERY_PROJECT/.venv"
  mkdir "$PY_DISCOVERY_PROJECT/.venv/bin"
  ln -s "$HOME/projects" "$HOME/projects-alias"
  export PY_DISCOVERY_ALIAS="$HOME/projects-alias/demo/.venv"
  printf '#!/bin/sh\nexit 97\n' > "$PY_DISCOVERY_PROJECT/.venv/bin/python"
  chmod -- 700 "$PY_DISCOVERY_PROJECT/.venv/bin/python"
  cat > "$PY_DISCOVERY_PROJECT/.venv/bin/activate" <<'EOF'
export VIRTUAL_ENV="$PY_DISCOVERY_ALIAS"
export PATH="$VIRTUAL_ENV/bin:$PATH"
EOF

  run --separate-stderr run_zsh '
    cd "$PY_DISCOVERY_PROJECT" || return
    venv-activate --path .venv --yes || return
    [[ "$VIRTUAL_ENV" == "$PY_DISCOVERY_ALIAS" ]] || return 91
    [[ "$(builtin whence -p python)" == "$PY_DISCOVERY_ALIAS/bin/python" ]] || return 92
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *'Activated:'* ]]
}

@test "py discovery: create and pin use safe writer modes without changing the caller" {
  {
    printf '#!%s\n' "$BASH"
    cat <<'EOF'
[[ "$PWD" == "$PY_DISCOVERY_PROJECT" ]] || exit 97
case "$*" in
  "venv --no-python-downloads $PWD/.venv")
    mkdir "$PWD/.venv" || exit 98
    printf 'version = 3.12.1\n' > "$PWD/.venv/pyvenv.cfg"
    ;;
  "--directory $PWD python pin --no-project --no-python-downloads 3.12")
    printf '3.12\n' > "$PWD/.python-version"
    ;;
  *) exit 97 ;;
esac
EOF
  } > "$TEST_MOCK_BIN/uv"
  chmod -- 700 "$TEST_MOCK_BIN/uv"

  run --separate-stderr run_zsh '
    cd "$PY_DISCOVERY_PROJECT" || return
    umask 002
    venv-create --uv --yes || return
    [[ "$(umask)" == 002 ]] || return 91
    venv-python-pin 3.12 --yes || return
    [[ "$(umask)" == 002 ]] || return 92
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(file_mode "$PY_DISCOVERY_PROJECT/.venv")" = 755 ]
  [ "$(file_mode "$PY_DISCOVERY_PROJECT/.venv/pyvenv.cfg")" = 644 ]
  [ "$(file_mode "$PY_DISCOVERY_PROJECT/.python-version")" = 644 ]

  export PY_DISCOVERY_PROJECT="$HOME/projects/private"
  mkdir "$PY_DISCOVERY_PROJECT"
  run --separate-stderr run_zsh '
    cd "$PY_DISCOVERY_PROJECT" || return
    umask 077
    venv-python-pin 3.12 --yes || return
    [[ "$(umask)" == 077 ]]
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(file_mode "$PY_DISCOVERY_PROJECT/.python-version")" = 600 ]
}

@test "py discovery: Apple Python is invoked only after a developer directory is verified" {
  export PY_DISCOVERY_CLT_DIR="$HOME/developer-tools"
  mkdir "$PY_DISCOVERY_CLT_DIR"
  cat > "$TEST_MOCK_BIN/python3" <<'EOF'
#!/bin/sh
printf '%s\n' invoked >> "$HOME/python-probes"
if [ "$#" -eq 5 ] && [ "$1" = -B ] && [ "$2" = -I ] \
  && [ "$3" = -S ] && [ "$4" = -c ]; then
  printf '3.12.1\n'
else
  exit 97
fi
EOF
  cat > "$TEST_MOCK_BIN/xcode-select" <<'EOF'
#!/bin/sh
[ "$#" -eq 1 ] && [ "$1" = -p ] || exit 97
[ "${PY_DISCOVERY_CLT_READY:-0}" = 1 ] || exit 1
printf '%s\n' "$PY_DISCOVERY_CLT_DIR"
EOF
  chmod -- 700 "$TEST_MOCK_BIN/python3" "$TEST_MOCK_BIN/xcode-select"

  export TEST_ZSH_OSTYPE=darwin-test
  run --separate-stderr run_zsh '
    cd "$PY_DISCOVERY_PROJECT" || return
    _py_is_clt_python() { [[ "$1" == "$TEST_MOCK_BIN/python3" ]]; }
    venv-create --venv --dry-run
  '
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ ! -e "$HOME/python-probes" ]
  [[ "$stderr" == *'Command Line Tools'* ]]

  export PY_DISCOVERY_CLT_READY=1
  run --separate-stderr run_zsh '
    cd "$PY_DISCOVERY_PROJECT" || return
    _py_is_clt_python() { [[ "$1" == "$TEST_MOCK_BIN/python3" ]]; }
    venv-create --venv --dry-run
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$HOME/python-probes")" = invoked ]
  [ ! -e "$PY_DISCOVERY_PROJECT/.venv" ]
  [[ "$stderr" == *'3.12.1'* ]]
}
