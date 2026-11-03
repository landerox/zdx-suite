# Private Apple-identity fixtures for real CLT consumer chains.
# Load after test_helper and the earlier core_probe_test_helper proposal.

f308c_setup() {
  export F308C_BIN="$CORE_PROBE_BIN" F308C_MODULES="$HOME/clt-modules"
  export F308C_XCODE_RC=0 F308C_GIT_MODE=not-repo
  export F308C_XCODE_AFTER_FIRST=""
  export F308C_REAL_JQ F308C_REAL_CAT F308C_REAL_PYTHON
  F308C_REAL_JQ=$(type -P jq) || return 1
  F308C_REAL_CAT=$(type -P cat) || return 1
  F308C_REAL_PYTHON=$(type -P python3) || return 1
  local real_program
  for real_program in "$F308C_REAL_JQ" "$F308C_REAL_CAT" "$F308C_REAL_PYTHON"; do
    [[ "$real_program" == /* && -f "$real_program" && -x "$real_program" ]] || return 1
  done
  mkdir -p "$F308C_MODULES" "$HOME/developer" "$HOME/release/functions" \
    "$HOME/release/.git" "$HOME/plugins" || return 1
  # Only the disposable copies' Apple path identity is remapped. No actual
  # /usr/bin/git or /usr/bin/python3 can enter the execution path.
  "$F308C_REAL_PYTHON" -B -I - "$TEST_SUITE_ROOT" "$F308C_MODULES" <<'PY' || return 1
from pathlib import Path
import hashlib, json, sys
root, out = map(Path, sys.argv[1:])
manifest = {}
for name in ('zdx-doctor.zsh', 'zdx-status.zsh', 'zdx-widgets.zsh',
             'zdx-version.zsh', 'zdx-plugins.zsh', 'zdx-menu.zsh', 'zdx-common.zsh'):
    source = root / 'functions' / name
    original = source.read_bytes()
    text = original.decode()
    rewritten = text.replace('/usr/bin/$cmd', '${F308C_BIN}/$cmd')
    rewritten = rewritten.replace('/usr/bin/git', '${F308C_BIN}/git')
    rewritten = rewritten.replace('/usr/bin/python3', '${F308C_BIN}/python3')
    result = rewritten.encode()
    (out / name).write_bytes(result)
    manifest[name] = {'original_sha256': hashlib.sha256(original).hexdigest(),
                      'copy_sha256': hashlib.sha256(result).hexdigest(),
                      'identity_replacements': sum(text.count(x) for x in
                          ('/usr/bin/$cmd', '/usr/bin/git', '/usr/bin/python3'))}
(out / 'identity-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
PY
  cat > "$HOME/remap-core-observers.py" <<'PY'
from pathlib import Path
import hashlib, json, sys
root = Path(sys.argv[1])
manifest, definitions = {}, ['emulate -R zsh\n']
for name in ('_zdx_probe_resolve', '_zdx_probe_tool', '_zdx_probe_clt_placeholder'):
    original = (root / (name + '.zsh')).read_bytes()
    text = original.decode()
    rewritten = text.replace('/usr/bin/$cmd', '${F308C_BIN}/$cmd')
    rewritten = rewritten.replace('/usr/bin/git', '${F308C_BIN}/git')
    rewritten = rewritten.replace('/usr/bin/python3', '${F308C_BIN}/python3')
    definitions.append(rewritten + '\n')
    manifest[name] = {'original_sha256': hashlib.sha256(original).hexdigest(),
                      'copy_sha256': hashlib.sha256(rewritten.encode()).hexdigest(),
                      'identity_replacements': sum(text.count(x) for x in
                          ('/usr/bin/$cmd', '/usr/bin/git', '/usr/bin/python3'))}
(root / 'remapped.zsh').write_text(''.join(definitions))
(root / 'identity-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
PY
  core_probe_program xcode-select <<'MOCK'
[[ "$#" -eq 1 && "$1" == -p ]] || exit 97
count=0
if [[ -f "$HOME/clt-count" ]]; then read -r count < "$HOME/clt-count"; fi
count=$((count + 1))
printf '%s\n' "$count" > "$HOME/clt-count"
printf '%s\0' "$0" "$@" >> "$HOME/clt.argv"
if IFS= read -r unexpected; then
  : > "$HOME/clt-stdin-consumed"
  exit 98
fi
rc=${F308C_XCODE_RC:-0}
if [[ "$count" -gt 1 && -n "${F308C_XCODE_AFTER_FIRST:-}" ]]; then
  rc=$F308C_XCODE_AFTER_FIRST
fi
[[ "$rc" == 0 ]] || exit "$rc"
printf '%s\n' "$HOME/developer"
MOCK
  core_probe_program git <<'MOCK'
printf '%s\n' "$*" >> "$HOME/candidate-git.calls"
if [[ "$#" -eq 1 && "$1" == --version ]]; then
  printf 'git version 2.43.0\n'
  exit 0
fi
[[ "${F308C_GIT_MODE:-not-repo}" == not-repo ]] && exit 1
exit 97
MOCK
  core_probe_program python3 <<'MOCK'
printf '%s\n' "$*" >> "$HOME/candidate-python.calls"
printf 'Python 3.12.3\n'
MOCK
  core_probe_program fzf <<'MOCK'
if [[ "$#" -eq 1 && "$1" == --version ]]; then
  printf '0.74.3 (fixture)\n'
  exit 0
fi
: > "$HOME/picker-ran"
exit 130
MOCK
  core_probe_program jq <<'MOCK'
printf '%s\n' "$*" >> "$HOME/jq.calls"
if [[ "$#" -eq 1 && "$1" == --version ]]; then
  printf 'jq-1.7.1\n'
  exit 0
fi
exec "$F308C_REAL_JQ" "$@"
MOCK
  core_probe_program cat <<'MOCK'
exec "$F308C_REAL_CAT" "$@"
MOCK
  local tool
  for tool in gh curl uv pipx wg wg-quick brew apt-get dnf pacman apk sudo; do
    core_probe_program "$tool" <<'MOCK'
printf '%s\n' "$0 $*" >> "$HOME/other-tool.calls"
exit 97
MOCK
  done
  cat > "$HOME/clt-owned-fixtures.zsh" <<'ZSH'
emulate -R zsh
_zdx_doctor_detect_os() { print -r -- macOS; }
_zdx_doctor_detect_pkg_manager() { print -r -- none; }
_zdx_doctor_visual_diagnostics() { return 0; }
_zdx_doctor_timeout_command() { REPLY=fixture; return 0; }
_zdx_doctor_fd_command() { REPLY=fixture; return 0; }
_zdx_doctor_sha256_command() { REPLY=fixture; return 0; }
_zdx_doctor_gnu_tar() { reply=(fixture "GNU tar fixture"); return 0; }
_zdx_doctor_run_install() { print -r -- install > "$HOME/install-ran"; return 97; }
_zdx_doctor_confirm() { print -r -- prompt > "$HOME/prompt-ran"; return 97; }
_zdx_status_wireguard_interfaces() { reply=(); return 1; }
_zdx_status_kubernetes() { return 0; }
_zdx_status_platform() { REPLY=macOS; }
_zdx_status_reboot_required() { REPLY=null; }
_zdx_status_home_filesystem() { reply=(1024 256 768 25); }
_zdx_status_load_average() {
  print -r -- independent > "$HOME/independent-fact-ran"
  reply=(0.50 0.40 0.30)
}
zle() {
  case "${1-}" in
    -M) print -r -- "${2-}" >> "$HOME/widget.messages" ;;
    reset-prompt) ;;
    *) return 97 ;;
  esac
}
_zdx_plugins_require_authorization() {
  print -r -- authorization > "$HOME/authorization-ran"
  return 97
}
_zdx_plugins_session_open() {
  print -r -- session > "$HOME/session-ran"
  return 97
}
ZSH
  printf '%s\n' 'Readable CLT input must remain with its caller.' > "$HOME/clt.stdin"
}

# Real core first, then owned fixture copies; fake Darwin starts only after
# loading. The real source boundary remains emulated as in normal module loads.
run_f308c_zsh() {
  local program="$1"
  # A BATS case may launch several independent shells. Reset only this
  # fixture's explicit observation files between them, never its mock tools.
  rm -f -- "$HOME/clt-count" "$HOME/clt.argv" \
    "$HOME/candidate-git.calls" "$HOME/candidate-python.calls" \
    "$HOME/jq.calls" "$HOME/other-tool.calls" "$HOME/picker-ran" \
    "$HOME/independent-fact-ran" "$HOME/install-ran" "$HOME/prompt-ran" \
    "$HOME/authorization-ran" "$HOME/session-ran" "$HOME/widget.messages" || return 1
  rm -f -- "$HOME/clt-timeout.argv" "$HOME/xcode-function-ran" "$HOME/clt-stdin-consumed" || return 1
  zsh -f -c '
    emulate -R zsh
    source "$1/functions.zsh" || exit 90
    cd "$HOME" || exit 91
    for module in DOCTOR STATUS WIDGETS VERSION MENU PLUGINS; do
      unset "_ZDX_${module}_SOURCED"
    done
    for module in zdx-doctor zdx-status zdx-widgets zdx-version zdx-plugins zdx-menu; do
      () {
        emulate -L zsh
        unsetopt aliases
        builtin source "$1"
      } "$F308C_MODULES/$module.zsh" || exit 92
    done
    # Fresh F308 may move the real observers into core. Copy their actual
    # bodies, changing ONLY Apple identity spellings; never fabricate policy.
    local observer="" observer_count=0
    command mkdir -p -- "$HOME/core-observer-original" || exit 99
    for observer in _zdx_probe_resolve _zdx_probe_tool _zdx_probe_clt_placeholder; do
      if (( ${+functions[$observer]} )); then
        printf "%s() {\n%s\n}\n" "$observer" "${functions[$observer]}" \
          > "$HOME/core-observer-original/$observer.zsh" || exit 99
        (( ++observer_count ))
      fi
    done
    (( observer_count == 0 || observer_count == 3 )) || exit 99
    if (( observer_count == 3 )); then
      "$F308C_REAL_PYTHON" -B -I "$HOME/remap-core-observers.py" \
        "$HOME/core-observer-original" || exit 99
      () {
        emulate -L zsh
        unsetopt aliases
        builtin source "$1"
      } "$HOME/core-observer-original/remapped.zsh" || exit 99
    fi
    path=("$CORE_PROBE_BIN")
    rehash
    OSTYPE=darwin23
    _ZDX_FUNCTIONS_DIR="$HOME/release/functions"
    ZDX_PLUGINS_DIR="$HOME/plugins"
    source "$HOME/clt-owned-fixtures.zsh" || exit 93
    # Trace only the real timeout service and delegate its unchanged body.
    functions[_f308c_real_timeout]="${functions[_zdx_run_with_timeout]}"
    _zdx_run_with_timeout() {
      if [[ "${2:t}" == xcode-select ]]; then
        printf "%s\0" "$@" >> "$HOME/clt-timeout.argv"
      fi
      _f308c_real_timeout "$@"
    }
    xcode-select() { print -r -- shadow > "$HOME/xcode-function-ran"; return 97; }
    exec < "$HOME/clt.stdin" || exit 94
    '"$program"'
    local f308c_unread=""
    IFS= read -r f308c_unread || exit 95
    [[ "$f308c_unread" == "Readable CLT input must remain with its caller." \
      && ! -e "$HOME/xcode-function-ran" && ! -e "$HOME/clt-stdin-consumed" ]] || exit 96
    local f308c_raw="$(<"$HOME/clt-timeout.argv")" f308c_nul="${(#):-0}"
    [[ -n "$f308c_raw" && "$f308c_raw" == *"$f308c_nul" \
      && "$f308c_raw" != "$f308c_nul"* && "$f308c_raw" != *"$f308c_nul$f308c_nul"* ]] || exit 97
    f308c_raw="${f308c_raw%"$f308c_nul"}"
    local -a f308c_trace=("${(@0)f308c_raw}")
    local -i f308c_index=1
    (( ${#f308c_trace} > 0 && ${#f308c_trace} % 3 == 0 )) || exit 97
    for (( f308c_index=1; f308c_index <= ${#f308c_trace}; f308c_index+=3 )); do
      [[ "${f308c_trace[$f308c_index]}" == <1-600> \
        && "${f308c_trace[$((f308c_index+1))]}" == "$CORE_PROBE_BIN/xcode-select" \
        && "${f308c_trace[$((f308c_index+2))]}" == -p ]] || exit 98
    done
  ' _ "$TEST_SUITE_ROOT" </dev/null
}

# A genuinely bounded test-only timeout executable. All payloads are inert
# leaf fixtures; the slow control executes Python directly with no children.
# This is not a product dependency or proof of the core watchdog.
f308c_timeout_backend() {
  [[ ! -e "$CORE_PROBE_BIN/timeout" && ! -L "$CORE_PROBE_BIN/timeout" ]] || return 1
  cat > "$HOME/standalone-timeout.py" <<'PY'
import json, os, pathlib, re, subprocess, sys
args = sys.argv[1:]
pathlib.Path(os.environ['HOME'], 'standalone-timeout.argv').open('a').write(json.dumps(args) + '\n')
if len(args) < 4 or args[:2] != ['-k', '2s']:
    raise SystemExit(97)
match = re.fullmatch(r'([1-9][0-9]{0,2})s', args[2])
if not match:
    raise SystemExit(97)
program = pathlib.Path(args[3])
if not program.is_absolute() or not program.is_file() or not os.access(program, os.X_OK):
    raise SystemExit(97)
if program.parent != pathlib.Path(os.environ['CORE_PROBE_BIN']) and str(program) != os.environ['F308C_REAL_PYTHON']:
    raise SystemExit(97)
try:
    result = subprocess.run(args[3:], stdin=sys.stdin.buffer, timeout=int(match[1]), check=False)
except subprocess.TimeoutExpired:
    raise SystemExit(124)
raise SystemExit(result.returncode if result.returncode >= 0 else 128 - result.returncode)
PY
  core_probe_program timeout <<'MOCK'
exec "$F308C_REAL_PYTHON" -B -I "$HOME/standalone-timeout.py" "$@"
MOCK
}

f308c_complete_tools() {
  local name
  for name in fzf git jq gh python3 curl wg wg-quick uv pipx tar sha256sum fd ip; do
    core_probe_program "$name" <<'MOCK'
printf '%s\n' "$0 $*" >> "$HOME/standalone-probes.calls"
if IFS= read -r unexpected; then : > "$HOME/standalone-stdin-consumed"; exit 98; fi
case "${0##*/}" in
  fzf) printf '0.74.3\n' ;;
  git) printf 'git version 2.43.0\n' ;;
  jq) printf 'jq-1.7.1\n' ;;
  gh) printf 'gh version 2.45.0\n' ;;
  python3) printf 'Python 3.12.3\n' ;;
  curl) printf 'curl 8.7.1\n' ;;
  wg|wg-quick) printf 'wireguard-tools v1.0.20210914\n' ;;
  uv) printf 'uv 0.4.0\n' ;;
  pipx) printf '1.4.3\n' ;;
  tar) printf 'tar (GNU tar) 1.35\n' ;;
  fd) printf 'fd 10.2.0\n' ;;
  sha256sum) printf 'sha256sum (GNU coreutils) 9.5\n' ;;
  ip) printf 'ip utility, iproute2-6.8.0\n' ;;
  *) exit 97 ;;
esac
MOCK
  done
}

# Standalone really means only this module: do not source functions.zsh.
run_f308c_standalone() {
  local program="$1"
  zsh -f -c '
    emulate -R zsh
    source "$F308C_MODULES/zdx-doctor.zsh" || exit 90
    path=("$CORE_PROBE_BIN")
    rehash
    OSTYPE=linux-gnu
    typeset -gi F308C_STANDALONE_RETURN=0
    exec < "$HOME/clt.stdin" || exit 91
    '"$program"'
    local unread=""
    IFS= read -r unread || exit 92
    [[ "$unread" == "Readable CLT input must remain with its caller." \
      && ! -e "$HOME/standalone-stdin-consumed" ]] || exit 93
    (( ! ${+_ZDX_FUNCTIONS_SOURCED} && ! ${+functions[_zdx_run_with_timeout]} )) || exit 94
    exit "$F308C_STANDALONE_RETURN"
  ' </dev/null
}
