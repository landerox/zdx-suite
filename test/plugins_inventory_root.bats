#!/usr/bin/env bats
# shellcheck disable=SC2016
# Initial-root observations through a real first core source, without mocks.

setup() {
  load test_helper
  F307_ROOT_ZSH=$(command -v zsh)
}

teardown() {
  cleanup_sandbox
}

f307_root_boundary_matrix() {
  local kind="$1" initial trace out
  for initial in unset seeded; do
    for trace in off on; do
      out="$HOME/root-boundary/$kind-$initial-$trace"
      mkdir -p "$out"
      run env -u TEST_TEMP_DIR -u BATS_TEST_DIRNAME \
        ZDX_EAGER_LOAD=0 ZDX_LAZY_LOAD=1 ZDX_PLUGINS_DIR="$F307_ROOT_CONFIG" \
        F307_ROOT_INITIAL="$initial" F307_ROOT_TRACE="$trace" F307_ROOT_OUT="$out" \
        "$F307_ROOT_ZSH" -f -c '
          emulate -R zsh
          exec 2>"$F307_ROOT_OUT/launcher.stderr"
          cd "$HOME" || exit 89
          zmodload -F zsh/system p:errnos || exit 90
          typeset -i F307_ROOT_SEED="${errnos[(Ie)EIO]}" F307_ROOT_SOURCE_RC=0
          (( F307_ROOT_SEED > 0 )) || exit 31
          PS4="F307_ROOT_TRACE "
          if [[ "$F307_ROOT_TRACE" == on ]]; then
            setopt xtrace
          fi
          typeset -A F307_ROOT_BEFORE_OPTIONS=("${(@kv)options}")
          unset ERRNO
          if [[ "$F307_ROOT_INITIAL" == seeded ]]; then
            ERRNO=$F307_ROOT_SEED
          fi
          source "$1/functions.zsh" >"$F307_ROOT_OUT/startup.stdout" \
            2>"$F307_ROOT_OUT/startup.stderr" || F307_ROOT_SOURCE_RC=$?
          typeset F307_ROOT_AFTER_ERRNO_EXISTS="${+ERRNO}"
          typeset -A F307_ROOT_AFTER_OPTIONS=("${(@kv)options}")
          unsetopt xtrace
          (( F307_ROOT_SOURCE_RC == 0 )) || exit 32
          if [[ "$F307_ROOT_INITIAL" == unset ]]; then
            [[ "$F307_ROOT_AFTER_ERRNO_EXISTS" == 0 ]] || exit 33
          else
            [[ "$F307_ROOT_AFTER_ERRNO_EXISTS" == 1 ]] || exit 34
          fi
          typeset F307_ROOT_OPTION=""
          for F307_ROOT_OPTION in "${(@k)F307_ROOT_BEFORE_OPTIONS}"; do
            [[ "${F307_ROOT_BEFORE_OPTIONS[$F307_ROOT_OPTION]}" \
              == "${F307_ROOT_AFTER_OPTIONS[$F307_ROOT_OPTION]-}" ]] || exit 35
          done
          (( ${#ZDX_LOADED_PLUGINS} == 0 && ${#ZDX_DISCOVERED_PLUGINS} == 0 \
            && ${#_ZDX_PLUGIN_STUBS} == 0 )) || exit 36
          [[ ! -s "$F307_ROOT_OUT/startup.stdout" ]] || exit 37
          env-menu --help >"$F307_ROOT_OUT/builtin.stdout" \
            2>"$F307_ROOT_OUT/builtin.stderr" || exit 38
          [[ ! -s "$F307_ROOT_OUT/builtin.stdout" && -s "$F307_ROOT_OUT/builtin.stderr" ]] || exit 39
          (( ${#ZDX_LOADED_PLUGINS} == 0 && ${#ZDX_DISCOVERED_PLUGINS} == 0 \
            && ${#_ZDX_PLUGIN_STUBS} == 0 )) || exit 40
          print -r -- root-boundary-ok
        ' _ "$TEST_SUITE_ROOT"
      [ "$status" -eq 0 ]
      [ "$output" = root-boundary-ok ]
      # Caller-requested trace is not a loader diagnostic. Retain its raw file.
      awk 'index($0, "F307_ROOT_TRACE ") != 1' "$out/startup.stderr" > "$out/startup.ui"
      if [[ "$kind" == missing ]]; then
        [ ! -s "$out/startup.ui" ]
      else
        grep -Eiq -- 'inventory' "$out/startup.ui"
        [ "$(wc -l < "$out/startup.ui")" -eq 1 ]
      fi
    done
  done
}

@test "plugin root: genuinely missing configured root stays quiet across errno and trace states" {
  F307_ROOT_CONFIG="$HOME/not-created/plugins"
  [ ! -e "$HOME/not-created" ]
  f307_root_boundary_matrix missing
}

@test "plugin root: a loop in a parent component reports inventory failure across errno and trace states" {
  ln -s -- "$HOME/root-loop-b" "$HOME/root-loop-a"
  ln -s -- "$HOME/root-loop-a" "$HOME/root-loop-b"
  [ -L "$HOME/root-loop-a" ]
  [ -L "$HOME/root-loop-b" ]
  F307_ROOT_CONFIG="$HOME/root-loop-a/plugins"
  f307_root_boundary_matrix loop
}
