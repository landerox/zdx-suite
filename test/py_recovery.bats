#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  export PY_RECOVERY_REAL_PYTHON PY_RECOVERY_REAL_UV
  PY_RECOVERY_REAL_PYTHON="$(type -P python3)"
  PY_RECOVERY_REAL_UV="$(type -P uv || true)"
  load test_helper
  export PY_RECOVERY_LOG="$HOME/python.calls"
  export PY_RECOVERY_FAILURE=alpha PY_RECOVERY_STATUS=130
  export PY_RECOVERY_PROJECT="$HOME/project"
  mkdir -m 700 "$PY_RECOVERY_PROJECT"
  : > "$PY_RECOVERY_LOG"
  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env zsh
case "$*" in
  'tool list')
    local tool_name
    for tool_name in alpha beta gamma; do
      if [[ -e "$HOME/upgraded-$tool_name" ]]; then
        print -r -- "$tool_name v1.1.0"
      else
        print -r -- "$tool_name v1.0.0"
      fi
      print -r -- "- $tool_name"
    done
    ;;
  'tool upgrade '* )
    print -r -- "uv:$3" >> "$PY_RECOVERY_LOG"
    print -r -- "Resolved 1 package for $3"
    [[ "$3" != "$PY_RECOVERY_FAILURE" ]] || exit "$PY_RECOVERY_STATUS"
    if [[ "${PY_RECOVERY_BUMP:-0}" == 1 ]]; then
      : > "$HOME/upgraded-$3"
    fi
    ;;
  *) exit 97 ;;
esac
EOF
  cat > "$TEST_MOCK_BIN/pipx" <<'EOF'
#!/usr/bin/env zsh
case "$*" in
  'list --short') print -rl -- 'alpha 1.0.0' 'beta 1.0.0' 'gamma 1.0.0' ;;
  'upgrade '* )
    print -r -- "pipx:$2" >> "$PY_RECOVERY_LOG"
    [[ "$2" != "$PY_RECOVERY_FAILURE" ]] || exit "$PY_RECOVERY_STATUS"
    ;;
  *) exit 97 ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/uv" "$TEST_MOCK_BIN/pipx"
  export PY_RECOVERY_SETUP="$HOME/python-setup.zsh"
  cat > "$PY_RECOVERY_SETUP" <<'EOF'
source "$ZSH_CUSTOM/functions/py-menu.zsh"
unfunction command
cd "$PY_RECOVERY_PROJECT" || return
EOF
}

teardown() {
  cleanup_sandbox
}

create_activation_fixture() {
  mkdir -m 700 "$PY_RECOVERY_PROJECT/.venv" "$PY_RECOVERY_PROJECT/.venv/bin"
  printf 'version = 3.12.3\nrelocatable = true\n' > "$PY_RECOVERY_PROJECT/.venv/pyvenv.cfg"
  ln -s "$PY_RECOVERY_REAL_PYTHON" "$PY_RECOVERY_PROJECT/.venv/bin/python"
  cat > "$PY_RECOVERY_PROJECT/.venv/bin/activate" <<'EOF'
# Model uv's relocatable activation: a child resolves the sourced filename.
SCRIPT_PATH="${(%):-%x}"
VIRTUAL_ENV="$(dirname -- "$(dirname -- "$(realpath -- "$SCRIPT_PATH")")")"
export VIRTUAL_ENV
_OLD_VIRTUAL_PATH="$PATH"
export PATH="$VIRTUAL_ENV/bin:$PATH"
unset SCRIPT_PATH
EOF
  chmod 600 "$PY_RECOVERY_PROJECT/.venv/pyvenv.cfg" "$PY_RECOVERY_PROJECT/.venv/bin/activate"
}

@test "py recovery: tool upgrade interruptions preserve status and stop later targets" {
  local backend expected
  for backend in uv pipx; do
    export PY_RECOVERY_BACKEND="$backend"
    for expected in 130 143; do
      export PY_RECOVERY_STATUS="$expected"
      : > "$PY_RECOVERY_LOG"
      run run_zsh '
        source "$PY_RECOVERY_SETUP"
        tool-upgrade --all --backend "$PY_RECOVERY_BACKEND" --yes
      '

      [ "$status" -eq "$expected" ]
      [ "$(cat "$PY_RECOVERY_LOG")" = "$backend:alpha" ]
      [[ "$output" == *"Tool upgrades interrupted (status $expected): 1 interrupted · 2 not run."* ]]
      printf '%s\n' "$output" | grep -Eq '^  (gamma|beta) [(]'"$backend"'[)] +– not run +upgrade interrupted$'
      [[ "$output" == *"tool-upgrade alpha --backend $backend"* ]]
    done
  done
}

@test "py recovery: ordinary tool failures continue and report each failed target" {
  export PY_RECOVERY_STATUS=47
  run run_zsh 'source "$PY_RECOVERY_SETUP"; tool-upgrade --all --backend uv --yes'

  [ "$status" -eq 1 ]
  [ "$(cat "$PY_RECOVERY_LOG")" = $'uv:alpha\nuv:beta\nuv:gamma' ]
  [[ "$output" == *'Tool upgrades completed with partial failures: 2 current · 1 failed.'* ]]
  printf '%s\n' "$output" | grep -Eq '^✘ \[1/3\] alpha \(uv\) — failed: status 47 '
  [[ "$output" == *'tool-upgrade alpha --backend uv'* ]]
  # The captured backend output is replayed only for the failed target.
  [[ "$output" == *'│ Resolved 1 package for alpha'* ]]
  [[ "$output" != *'│ Resolved 1 package for beta'* ]]
}

@test "py recovery: interruption after prior success counts the remaining frozen tools" {
  export PY_RECOVERY_FAILURE=beta PY_RECOVERY_STATUS=143
  run run_zsh 'source "$PY_RECOVERY_SETUP"; tool-upgrade --all --backend pipx --yes'

  [ "$status" -eq 143 ]
  [ "$(cat "$PY_RECOVERY_LOG")" = $'pipx:alpha\npipx:beta' ]
  [[ "$output" == *'Tool upgrades interrupted (status 143): 1 current · 1 interrupted · 1 not run.'* ]]
}

@test "py recovery: a single interrupted tool keeps the backend interruption status" {
  run run_zsh 'source "$PY_RECOVERY_SETUP"; tool-upgrade alpha --backend uv --yes'

  [ "$status" -eq 130 ]
  [ "$(cat "$PY_RECOVERY_LOG")" = 'uv:alpha' ]
  [[ "$output" == *'Tool upgrades interrupted (status 130): 1 interrupted.'* ]]
  # A single target has no step banner or summary table.
  [[ "$output" != *'[1/1]'* && "$output" != *'Tool Upgrade Summary'* ]]
}

@test "py recovery: successful tool upgrades retain complete success accounting" {
  export PY_RECOVERY_FAILURE=none
  run run_zsh 'source "$PY_RECOVERY_SETUP"; tool-upgrade --all --backend uv --yes'

  [ "$status" -eq 0 ]
  [ "$(cat "$PY_RECOVERY_LOG")" = $'uv:alpha\nuv:beta\nuv:gamma' ]
  [[ "$output" == *'Tool upgrades completed: 3 current.'* ]]
  [[ "$output" != *'Resolved 1 package'* ]]
}

@test "py recovery: tool upgrades report a changed version as updated" {
  export PY_RECOVERY_FAILURE=none PY_RECOVERY_BUMP=1
  run run_zsh 'source "$PY_RECOVERY_SETUP"; NO_COLOR=1 tool-upgrade --all --backend uv --yes'

  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Eq '^  1  alpha +uv +1[.]0[.]0$'
  printf '%s\n' "$output" | grep -Eq '^✔ \[2/3\] beta \(uv\) — updated: 1[.]0[.]0 → 1[.]1[.]0 '
  printf '%s\n' "$output" | grep -Eq '^  gamma \(uv\) +✔ updated +[0-9.]+s +1[.]0[.]0 → 1[.]1[.]0$'
  [[ "$output" == *'Tool upgrades completed: 3 updated.'* ]]
}

@test "py recovery: relocatable activation resolves the reviewed descriptor in an actual subshell" {
  skip_on_darwin "relocatable activation needs /proc/<pid>/fd for a stable descriptor path"
  create_activation_fixture
  run run_zsh '
    source "$PY_RECOVERY_SETUP"
    (
      venv-activate --path .venv --yes || return
      [[ "$VIRTUAL_ENV" == "$PWD/.venv" ]] || return 91
      [[ "${PATH%%:*}" == "$PWD/.venv/bin" ]] || return 92
      [[ "$(builtin whence -p python)" == "$PWD/.venv/bin/python" ]] || return 93
    )
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *'Activated:'* ]]
}

@test "py recovery: real offline uv relocatable environments activate through the reviewed descriptor" {
  skip_on_darwin "relocatable activation needs /proc/<pid>/fd for a stable descriptor path"
  [ -n "$PY_RECOVERY_REAL_UV" ] || skip 'uv is not installed'
  export UV_CACHE_DIR="$HOME/uv-cache" UV_PYTHON_INSTALL_DIR="$HOME/managed-python"
  "$PY_RECOVERY_REAL_UV" venv --no-config --no-project --offline \
    --no-python-downloads --relocatable --python "$PY_RECOVERY_REAL_PYTHON" \
    "$PY_RECOVERY_PROJECT/.venv"
  run run_zsh '
    source "$PY_RECOVERY_SETUP"
    venv-activate --path .venv --yes || return
    [[ "$VIRTUAL_ENV" == "$PWD/.venv" ]] || return 91
    [[ "$(builtin whence -p python)" == "$PWD/.venv/bin/python" ]] || return 92
    python -I -c "import sys; print(sys.prefix)"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"$PY_RECOVERY_PROJECT/.venv"* ]]
}

@test "py recovery: an unsuccessful activation restores prior variables functions and aliases" {
  # The fixture is a relocatable environment, which activates only through
  # /proc/<pid>/fd; macOS refuses it before the restoration under test.
  skip_on_darwin "relocatable activation needs /proc/<pid>/fd for a stable descriptor path"
  create_activation_fixture
  cat > "$PY_RECOVERY_PROJECT/.venv/bin/activate" <<'EOF'
export PATH="/wrong/bin:$PATH" VIRTUAL_ENV=/wrong VIRTUAL_ENV_PROMPT=wrong
export PYTHONHOME=/wrong SCRIPT_PATH=/wrong
PS1=wrong
_OLD_VIRTUAL_PATH=wrong
deactivate() { return 99; }
unalias pydoc 2>/dev/null || true
pydoc() { return 99; }
return "${PY_RECOVERY_STATUS}"
EOF
  local expected
  for expected in 0 130 143; do
    export PY_RECOVERY_STATUS="$expected"
    run run_zsh '
      source "$PY_RECOVERY_SETUP"
      export VIRTUAL_ENV=/previous VIRTUAL_ENV_PROMPT=previous PYTHONHOME=/previous
      _OLD_VIRTUAL_PATH=previous
      PS1=previous
      deactivate() { return 13; }
      pydoc() { return 14; }
      alias pydoc="print original-doc"
      typeset original_path="$PATH"
      typeset original_deactivate="$functions[deactivate]" original_pydoc="$functions[pydoc]"
      venv-activate --path .venv --yes
      typeset -i activation_rc=$?
      (( activation_rc == (PY_RECOVERY_STATUS == 0 ? 1 : PY_RECOVERY_STATUS) )) || return 90
      [[ "$PATH" == "$original_path" && "$VIRTUAL_ENV" == /previous \
        && "$VIRTUAL_ENV_PROMPT" == previous && "$PYTHONHOME" == /previous \
        && "$PS1" == previous && "$_OLD_VIRTUAL_PATH" == previous ]] || return 91
      [[ "$functions[deactivate]" == "$original_deactivate" \
        && "$functions[pydoc]" == "$original_pydoc" \
        && "$aliases[pydoc]" == "print original-doc" ]] || return 92
      (( ! ${+SCRIPT_PATH} )) || return 93
    '

    [ "$status" -eq 0 ]
    [[ "$output" != *'Activated:'* ]]
    [[ "$output" == *'Restored the previous activation state'* ]]
  done
}

@test "py recovery: relocatable activation refuses an unavailable stable descriptor before sourcing" {
  create_activation_fixture
  cat >> "$PY_RECOVERY_PROJECT/.venv/bin/activate" <<'EOF'
print -r -- unexpected >> "$PY_RECOVERY_LOG"
EOF
  run run_zsh '
    source "$PY_RECOVERY_SETUP"
    _py_activation_descriptor_path() { REPLY="/dev/fd/$2"; return 3; }
    typeset original_path="$PATH"
    venv-activate --path .venv --yes
    typeset -i activation_rc=$?
    [[ "$PATH" == "$original_path" ]] || return 91
    return "$activation_rc"
  '

  [ "$status" -eq 1 ]
  [ ! -s "$PY_RECOVERY_LOG" ]
  [[ "$output" == *'stable descriptor path'* ]]
}

@test "py recovery: ordinary activation retains the descriptor fallback without proc support" {
  create_activation_fixture
  printf 'version = 3.12.3\n' > "$PY_RECOVERY_PROJECT/.venv/pyvenv.cfg"
  cat > "$PY_RECOVERY_PROJECT/.venv/bin/activate" <<'EOF'
export VIRTUAL_ENV="$PY_RECOVERY_PROJECT/.venv"
_OLD_VIRTUAL_PATH="$PATH"
export PATH="$VIRTUAL_ENV/bin:$PATH"
EOF
  run run_zsh '
    source "$PY_RECOVERY_SETUP"
    _py_activation_descriptor_path() { REPLY="/dev/fd/$2"; return 3; }
    venv-activate --path .venv --yes || return
    [[ "$VIRTUAL_ENV" == "$PWD/.venv" \
      && "$(builtin whence -p python)" == "$PWD/.venv/bin/python" ]]
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *'Activated:'* ]]
}
