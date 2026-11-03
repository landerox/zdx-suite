# Secondary-probe fixtures layered on the existing core_probe_test_helper.
# Every executable is a sandbox mock; no native timeout/gtimeout is present.

f308_probe_setup() {
  export F308_REAL_ENV F308_REAL_JQ F308_REAL_SLEEP F308_TRACE
  F308_REAL_ENV=$(command -v env)
  F308_REAL_JQ=$(command -v jq || true)
  F308_REAL_SLEEP=$(command -v sleep)
  F308_TRACE="$TEST_TEMP_DIR/secondary-timeout-trace"
  : > "$F308_TRACE"
  export F308_STDIN_CANARY="Readable secondary probe input must remain untouched."
  printf '%s\n' "$F308_STDIN_CANARY" > "$HOME/secondary-probe.stdin"
  make_core_probe_path
  mkdir -p "$HOME/developer"
  cat > "$HOME/secondary-trace.zsh" <<'ZSH'
emulate -R zsh
functions[_f308_actual_timeout]="${functions[_zdx_run_with_timeout]}"
_zdx_run_with_timeout() {
  print -r -- "$1"$'\t'"$2" >> "$F308_TRACE"
  _f308_actual_timeout "$@"
}
ZSH
}

f308_wireguard() {
  core_probe_program wg-quick <<'MOCK'
exit 0
MOCK
  core_probe_program wg <<'MOCK'
printf '%s\0' "$0" "$@" > "$HOME/wg.argv"
[[ "$#" -eq 1 && "$1" == --version ]] || exit 97
if IFS= read -r unexpected; then exit 98; fi
if [[ "${F308_WG_SLEEP:-0}" != 0 ]]; then
  "$F308_REAL_SLEEP" "$F308_WG_SLEEP"
  : > "$HOME/wg-completed"
fi
printf 'wireguard-tools v1.0.20210914\n'
exit "${F308_WG_RC:-0}"
MOCK
}

f308_xcode_select() {
  core_probe_program xcode-select <<'MOCK'
printf '%s\0' "$0" "$@" > "$HOME/xcode-select.argv"
[[ "$#" -eq 1 && "$1" == -p ]] || exit 97
if IFS= read -r unexpected; then exit 98; fi
if [[ "${F308_XCODE_SLEEP:-0}" != 0 ]]; then
  "$F308_REAL_SLEEP" "$F308_XCODE_SLEEP"
  : > "$HOME/xcode-select-completed"
fi
printf '%s\n' "$HOME/developer"
exit "${F308_XCODE_RC:-0}"
MOCK
}

# make_core_probe_path creates env as a symlink to the real executable.
# Unlink ONLY that private symlink before opening a new mock: never truncate
# through it. The original executable is called through its saved absolute path.
f308_pr_tools() {
  [[ -L "$CORE_PROBE_BIN/env" ]] || return 1
  rm -- "$CORE_PROBE_BIN/env" || return 1
  core_probe_program env <<'MOCK'
printf '%s\0' "$0" "$@" > "$HOME/env.argv"
if IFS= read -r unexpected; then exit 98; fi
[[ "${F308_ENV_RC:-0}" == 0 ]] || exit "$F308_ENV_RC"
exec "$F308_REAL_ENV" "$@"
MOCK
  core_probe_program gh <<'MOCK'
printf '%s\0' "$0" "$@" > "$HOME/gh.argv"
[[ "${GH_PROMPT_DISABLED:-}" == 1 && "${GH_NO_UPDATE_NOTIFIER:-}" == 1 ]] || exit 96
if IFS= read -r unexpected; then exit 98; fi
[[ "${F308_GH_RC:-0}" == 0 ]] || exit "$F308_GH_RC"
if [[ "${F308_BAD_PR_JSON:-0}" == 1 ]]; then
  printf '{invalid json\n'
else
  printf '[{"number":42,"headRefName":"topic","title":"Fixture PR"}]\n'
fi
MOCK
  core_probe_program jq <<'MOCK'
printf '%s\0' "$0" "$@" > "$HOME/jq.argv"
[[ "${F308_JQ_RC:-0}" == 0 ]] || exit "$F308_JQ_RC"
if [[ "${F308_JQ_SLEEP:-0}" != 0 ]]; then
  "$F308_REAL_SLEEP" "$F308_JQ_SLEEP"
  : > "$HOME/jq-completed"
fi
exec "$F308_REAL_JQ" "$@"
MOCK
}

f308_doctor_prompt_fixture() {
  core_probe_program brew <<'MOCK'
: > "$HOME/package-manager-ran"
exit 97
MOCK
  cat > "$HOME/doctor-prompt-fixture.zsh" <<'ZSH'
emulate -R zsh
_zdx_doctor_detect_os() { print -r -- Linux; }
_zdx_doctor_detect_pkg_manager() { print -r -- brew; }
_zdx_doctor_visual_diagnostics() { return 0; }
_zdx_doctor_report_dependency() {
  if [[ "$1" == jq\|* ]]; then
    missing_cmds+=(jq)
    missing_pkgs+=(jq)
    (( issues_count += 1 ))
  fi
  return 0
}
_zdx_doctor_timeout_command() { REPLY=fixture; return 0; }
_zdx_doctor_fd_command() { REPLY=fixture; return 0; }
_zdx_doctor_sha256_command() { return 1; }
_zdx_doctor_gnu_tar() { reply=(fixture "GNU tar fixture"); return 0; }
_zdx_doctor_program_trusted() {
  [[ "$1" == "$CORE_PROBE_BIN"/* && -f "$1" && -x "$1" ]]
}
_zdx_confirm_prompt() {
  print -r -- "$F308_PROMPT_RC" >> "$HOME/shared-prompt-calls"
  return "$F308_PROMPT_RC"
}
ZSH
}

f308_status_tools() {
  export F308_REPO="$HOME/project" F308_GIT_DIR="$HOME/git-metadata"
  mkdir -p "$F308_REPO" "$F308_GIT_DIR"
  : > "$F308_REPO/pyproject.toml"
  core_probe_program git <<'MOCK'
printf '%s\0' "$0" "$@" >> "$HOME/status-git.argv"
if IFS= read -r unexpected; then exit 98; fi
for argument in "$@"; do
  case "$argument" in
    rev-parse) printf '%s\n%s\n' "$F308_REPO" "$F308_GIT_DIR"; exit 0 ;;
    status)
      if [[ "${F308_STATUS_KIND:-malformed}" == timeout ]]; then
        "$F308_REAL_SLEEP" 8
        : > "$HOME/git-status-completed"
      fi
      printf '# branch.head main\0# branch.oid invalid-oid\0# branch.ab +oops -bad\0'
      exit 0
      ;;
    config) printf 'fixture@example.invalid\n'; exit 0 ;;
  esac
done
exit 97
MOCK
  core_probe_program jq <<'MOCK'
[[ "${F308_STATUS_JQ_RC:-0}" == 0 ]] || {
  printf 'partial output that is not a JSON document\n'
  exit "$F308_STATUS_JQ_RC"
}
exec "$F308_REAL_JQ" "$@"
MOCK
  cat > "$HOME/status-secondary-fixture.zsh" <<'ZSH'
emulate -R zsh
OSTYPE=linux-gnu
_zdx_status_platform() { REPLY=Linux; }
_zdx_status_reboot_required() { REPLY=false; }
_zdx_status_home_filesystem() { reply=(1024 256 768 25); }
_zdx_status_load_average() {
  if [[ "${F308_STATUS_KIND:-malformed}" == malformed ]]; then
    reply=("0,5" "malformed" "-99")
  else
    reply=(0.50 0.40 0.30)
  fi
}
_zdx_status_wireguard_interfaces() { reply=(); }
_zdx_status_kubernetes() { return 0; }
# Exact-root checkout behavior is covered by the previous proposal. Keep it
# out of this local-repository/JSON test so it cannot consume its slow Git mock.
_zdx_release_checkout() { reply=(); return 1; }
ZSH
}
