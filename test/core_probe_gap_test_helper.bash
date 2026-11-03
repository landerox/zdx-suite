# Narrow F308 confirmation and optional manager-metadata fixtures.
# shellcheck disable=SC2016 # Literal Zsh programs expand in the child shell.
# Requires test_helper, core_probe_test_helper and the revised 17-case
# core_clt_consumer_test_helper proposal. No helper from that proposal is edited.

f308g_setup() {
  export F308G_PLUGIN_NAME=gap-fixture
  mkdir -p "$HOME/plugins/$F308G_PLUGIN_NAME/.git" || return 1
  chmod -- 700 "$HOME/plugins" "$HOME/plugins/$F308G_PLUGIN_NAME" \
    "$HOME/plugins/$F308G_PLUGIN_NAME/.git" || return 1
  cat > "$HOME/plugins/$F308G_PLUGIN_NAME/$F308G_PLUGIN_NAME-menu.zsh" <<'ZSH'
print -r -- activated > "$HOME/gap-plugin-sourced"
gap-fixture-menu() { return 0; }
ZSH
  chmod -- 600 "$HOME/plugins/$F308G_PLUGIN_NAME/$F308G_PLUGIN_NAME-menu.zsh" || return 1
  cat > "$HOME/gap-manager-fixture.zsh" <<'ZSH'
emulate -R zsh
# The consumer helper deliberately denies session/authorization for its
# install-preflight cases. Restore the ACTUAL copied manager module here;
# list/remove must reach real authorization, root validation, locking,
# recovery, metadata collection, transaction cleanup and unlocking.
unset _ZDX_PLUGINS_SOURCED
() {
  emulate -L zsh
  unsetopt aliases
  builtin source "$1"
} "$F308C_MODULES/zdx-plugins.zsh" || return 91
[[ "${functions[_zdx_plugins_session_open]}" != *session-ran* \
  && "${functions[_zdx_plugins_require_authorization]}" != *authorization-ran* ]] || return 92
# Only the prompt boundary is a denial canary. Metadata, Git guard and
# session/check coordinators retain the real source bodies.
_zdx_plugins_confirm() {
  print -r -- prompt > "$HOME/prompt-ran"
  return 97
}
ZSH
}

run_f308g_manager_zsh() {
  local program="$1"
  # These are explicit sandbox observation files. The real manager has
  # completed/unlocked before the next independently launched shell.
  rm -f -- "$HOME/gap-plugin-sourced" \
    "$HOME/plugins/.zdx-plugins.lock" || return 1
  run_f308c_zsh '
    source "$HOME/gap-manager-fixture.zsh" || exit 30
    '"$program"
}

f308g_doctor_tools() {
  f308c_complete_tools || return 1
  # pipx is genuinely absent. Every other diagnostic tool is an inert
  # executable; Git/Python keep separate candidate-execution receipts.
  rm -f -- "$CORE_PROBE_BIN/pipx" || return 1
  core_probe_program git <<'MOCK'
printf '%s\n' "$*" >> "$HOME/candidate-git.calls"
printf 'git version 2.43.0\n'
MOCK
  core_probe_program python3 <<'MOCK'
printf '%s\n' "$*" >> "$HOME/candidate-python.calls"
printf 'Python 3.12.3\n'
MOCK
  core_probe_program brew <<'MOCK'
printf '%s\n' "$0 $*" >> "$HOME/gap-package-manager-ran"
exit 97
MOCK
}
