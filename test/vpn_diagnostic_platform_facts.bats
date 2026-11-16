#!/usr/bin/env bats
# Finite cells finish before assertions and retain separate stream/status evidence.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  load vpn_test_helper
  export TERM=dumb NO_COLOR=1 F512D_ROOT="$HOME/f512-diagnostic"
  export F512D_KERNEL=Linux F512D_RELEASE=fixture-linux F512D_PLATFORM=linux
  export F512D_ROUTE=present F512D_MODE=mirrored F512D_MODE_RC=0 F512D_ROUTE_RC=0
  export F512D_PROVIDER_RC=0 F512D_WG_VERSION_RC=0 F512D_JQ_RC=0 F512D_JQ_MODE=real
  export F512D_LOAD_MODE=core F512D_REAL_WSL=0 F512D_FIXTURE_BASH="$BASH"
  unset WSL_DISTRO_NAME WSL_INTEROP VPN_MENU_WSL_IPV6_FIX HOMEBREW_PREFIX
  mkdir -m 700 "$F512D_ROOT" || return 1
  export F512D_REAL_JQ F512D_REAL_HEAD
  F512D_REAL_JQ=$(command -v jq) || return 1
  F512D_REAL_HEAD=$(command -v head) || return 1
  [[ "$F512D_REAL_JQ" == /* && "$F512D_REAL_HEAD" == /* ]] || return 1
  printf '#!%s\n' "$BASH" > "$F512D_ROOT/backend" || return 1
  cat >> "$F512D_ROOT/backend" <<'MOCK'
tool="${0##*/}"
printf '%s\0' "$#" "$0" "$@" >> "$F512D_CASE/$tool.argv.nul" || exit 97
case "$tool:$*" in
  'uname:-s') printf '%s\n' "$F512D_KERNEL" ;;
  'uname:-r') printf '%s\n' "$F512D_RELEASE" ;;
  'uname:-sr') printf '%s %s\n' "$F512D_KERNEL" "$F512D_RELEASE" ;;
  'wg:show interfaces') printf 'wg0\n' ;;
  'wg:--version')
    [[ "$F512D_WG_VERSION_RC" == 0 ]] && printf 'wireguard-tools fixture-version\n'
    printf '%s\n' "$F512D_WG_VERSION_RC" > "$F512D_CASE/wg.reached-configured-return"
    exit "$F512D_WG_VERSION_RC" ;;
  wg:*) printf 'interface: wg0\n  public key: PUBLIC-FIXTURE\n' ;;
  'wg-quick:--version') printf 'Usage: wg-quick [ up | down | save | strip ]\n' >&2; exit 1 ;;
  wg-quick:*) exit 97 ;;
  'python3:--version') printf 'Python PLACEHOLDER-MODEL\n' ;;
  'curl:--version') printf 'curl fixture-version\n' ;;
  'curl:--f512-provider')
    if [[ "$F512D_PROVIDER_RC" == 0 ]]; then printf '203.0.113.7\tCity\tRegion\tZZ\tOrg\tprovider.example\n'; fi
    printf '%s\n' "$F512D_PROVIDER_RC" > "$F512D_CASE/provider.reached-configured-return"
    exit "$F512D_PROVIDER_RC" ;;
  'resolvectl:dns') printf 'Link 2 (fixture): 192.0.2.53\n' ;;
  'route:-n get default'|'netstat:-rn -f inet'|'netstat:-rn -f inet6'|'scutil:--dns') printf 'FINITE-AUXILIARY-READER\n' ;;
  'hostname:-s'|'hostname:') printf 'fixture-host\n' ;;
  date:+%s) printf '1000\n' ;;
  date:+%Y-%m-%d_%H%M%S) printf '2026-02-01_010203\n' ;;
  date:+*) printf '2026-02-01 01:02:03 UTC\n' ;;
  stat:*) printf 'WRONG-EXTERNAL-STAT-METADATA\n'; exit 17 ;;
  'wslinfo:--networking-mode') printf '%s\n' "$F512D_MODE"; exit "$F512D_MODE_RC" ;;
  'ip:-6 route show default')
    [[ "$F512D_ROUTE" == present ]] && printf 'default via fe80::1 dev eth0\n'
    exit "$F512D_ROUTE_RC" ;;
  'brew:--prefix')
    if IFS= read -r value; then printf 'open:%s\n' "$value" > "$F512D_CASE/brew.stdin"; else printf 'closed\n' > "$F512D_CASE/brew.stdin"; fi
    printf '%s\n' "$F512D_BREW_OUTPUT"
    printf 'PRIVATE-BREW-DIAGNOSTIC\n' >&2
    exit "$F512D_BREW_RC" ;;
  timeout:*|gtimeout:*)
    [[ $# -ge 4 && "$1" == -k && "$2" == 2s && "$3" == [1-9]*s && "$4" == /* ]] || exit 97
    printf '%s\n' "$tool" >> "$F512D_CASE/selected.backend"
    shift 3
    "$@"; code=$?
    printf '%s\n' "$code" >> "$F512D_CASE/backend.child-post-return.status"
    exit "$code" ;;
  'vpn-leaf:literal payload')
    if IFS= read -r value; then printf 'open:%s\n' "$value" > "$F512D_CASE/leaf.stdin"; else printf 'closed\n' > "$F512D_CASE/leaf.stdin"; fi
    printf 'ELIGIBLE-LEAF\n'; exit 0 ;;
  *) exit 97 ;;
esac
MOCK
  local tool
  for tool in uname wg wg-quick python3 curl hostname date stat wslinfo ip brew timeout gtimeout vpn-leaf resolvectl route netstat scutil; do
    cp "$F512D_ROOT/backend" "$TEST_MOCK_BIN/$tool" || return 1
    chmod -- 700 "$TEST_MOCK_BIN/$tool" || return 1
  done
  # A selected jq wrapper observes an actual finite child return, separately
  # from the child's configured exit-site marker and the public primary return.
  printf '#!%s\n' "$BASH" > "$F512D_ROOT/jq-leaf" || return 1
  cat >> "$F512D_ROOT/jq-leaf" <<'MOCK'
if [[ "$F512D_JQ_MODE" == failed ]]; then
  printf '{"partial":'
  printf 'PRIVATE-JQ-DIAGNOSTIC\n' >&2
  printf '%s\n' "$F512D_JQ_RC" > "$F512D_CASE/jq.reached-configured-return"
  exit "$F512D_JQ_RC"
fi
exec "$F512D_REAL_JQ" "$@"
MOCK
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/jq" || return 1
  cat >> "$TEST_MOCK_BIN/jq" <<'MOCK'
printf '%s\0' "$#" "$0" "$@" >> "$F512D_CASE/jq.argv.nul" || exit 97
"$F512D_ROOT/jq-leaf" "$@"
code=$?
printf '%s\n' "$code" >> "$F512D_CASE/jq.child-post-return.status" || exit 97
exit "$code"
MOCK
  chmod -- 700 "$F512D_ROOT/jq-leaf" "$TEST_MOCK_BIN/jq" || return 1
}

teardown() {
  cleanup_sandbox
}

f512d_observe() {
  local name="$1" program="$2" wrapper=0
  export F512D_CASE="$F512D_ROOT/$name"
  export VPN_CONFIG_DIR="$F512D_CASE/profiles" VPN_CACHE_DIR="$F512D_CASE/cache" VPN_MENU_REPORT_DIR="$F512D_CASE/reports"
  mkdir -m 700 "$F512D_CASE" "$VPN_CONFIG_DIR" "$VPN_CACHE_DIR" "$VPN_MENU_REPORT_DIR" || return 1
  printf '[Interface]\nPrivateKey = PRIVATE-FIXTURE=\nDNS = 10.64.0.53\n[Peer]\nPublicKey = PEER=\nAllowedIPs = 0.0.0.0/0\n' > "$VPN_CONFIG_DIR/wg0.conf" || return 1
  chmod -- 600 "$VPN_CONFIG_DIR/wg0.conf" || return 1
  printf '%s\n' "$program" > "$F512D_CASE/action.zsh" || return 1
  cat > "$F512D_CASE/observe.zsh" <<'ZSH'
emulate -R zsh
export ZSH_CUSTOM="$TEST_SUITE_ROOT"
builtin source "$ZSH_CUSTOM/functions/vpn-menu.zsh" || return 90
(( ! ${+functions[command]} )) || unfunction command
if [[ "$F512D_LOAD_MODE" == standalone ]]; then
  (( ! ${+functions[_zdx_run_with_timeout]} && ! ${+functions[_zdx_timeout_watchdog]} && ! ${+functions[_timed]} )) || return 91
  print -r -- NO_CORE_LOADED > "$F512D_CASE/load-mode"
fi
_VPN_PLATFORM="$F512D_PLATFORM"
if [[ "$F512D_REAL_WSL" != 1 ]]; then
  _vpn_is_wsl() { [[ "$F512D_PLATFORM" == wsl ]]; }
fi
_f512d_action() { builtin source "$F512D_CASE/action.zsh"; }
local -i primary=0
_f512d_action > "$F512D_CASE/stdout" 2> "$F512D_CASE/stderr" || primary=$?
print -r -- "$primary" > "$F512D_CASE/primary.status" || return 98
print -rn -- "${REPLY-}" > "$F512D_CASE/reply" || return 98
return 0
ZSH
  if [[ "$F512D_LOAD_MODE" == standalone ]]; then
    if zsh -f -c 'emulate -R zsh; builtin source "$F512D_CASE/observe.zsh"' > "$F512D_CASE/wrapper.stdout" 2> "$F512D_CASE/wrapper.stderr"; then wrapper=0; else wrapper=$?; fi
  else
    if run_zsh 'builtin source "$F512D_CASE/observe.zsh"' > "$F512D_CASE/wrapper.stdout" 2> "$F512D_CASE/wrapper.stderr"; then wrapper=0; else wrapper=$?; fi
  fi
  printf '%s\n' "$wrapper" > "$F512D_CASE/wrapper.status" || return 1
}

f512d_primary() {
  local dir="$1" wanted="$2" name
  for name in primary.status stdout stderr reply wrapper.status wrapper.stdout wrapper.stderr; do
    [[ -f "$dir/$name" && ! -L "$dir/$name" ]] || return 31
  done
  printf '%s\n' "$wanted" > "$dir/expected.status" || return 32
  cmp "$dir/expected.status" "$dir/primary.status" || return 33
  printf '0\n' > "$dir/expected.wrapper" || return 34
  cmp "$dir/expected.wrapper" "$dir/wrapper.status" || return 35
  [[ ! -s "$dir/wrapper.stdout" && ! -s "$dir/wrapper.stderr" ]] || return 36
}

f512d_ui() {
  f512d_primary "$1" "$2" || return $?
  [[ ! -s "$1/stdout" ]] || return 37
}

f512d_argv_exact() {
  local file="$1" program="$2"
  shift 2
  [[ -f "$file" && ! -L "$file" ]] || return 84
  printf '%s\0' "$#" "$program" "$@" > "$file.expected" || return 85
  cmp "$file.expected" "$file" || return 86
}

f512d_native() {
  local dir="$1" backend="$2"
  f512d_primary "$dir" 0 || return $?
  printf 'ELIGIBLE-LEAF\n' > "$dir/expected.stdout" || return 87
  cmp "$dir/expected.stdout" "$dir/stdout" || return 88
  [[ $(cat "$dir/leaf.stdin") == closed && $(cat "$dir/selected.backend") == "$backend" ]] || return 89
  [[ $(cat "$dir/backend.child-post-return.status") == 0 ]] || return 90
  f512d_argv_exact "$dir/vpn-leaf.argv.nul" "$TEST_MOCK_BIN/vpn-leaf" literal payload || return $?
  f512d_argv_exact "$dir/$backend.argv.nul" "$TEST_MOCK_BIN/$backend" -k 2s 3s "$TEST_MOCK_BIN/vpn-leaf" literal payload || return $?
}

f512d_jq_argv() {
  local file="$1" expected_program="$2" item arg compact=0 monochrome=0 null_input=0
  local -a words=()
  [[ -f "$file" && ! -L "$file" ]] || return 91
  while IFS= read -r -d '' item; do words+=("$item"); done < "$file"
  [[ -z "$item" ]] || return 91
  [[ ${words[0]:-} =~ ^[0-9]+$ && ${words[1]:-} == "$expected_program" ]] || return 92
  [[ ${words[0]} == "$((${#words[@]}-2))" ]] || return 93
  for arg in "${words[@]:2}"; do
    [[ "$arg" != --arg ]] || break
    case "$arg" in
      --compact-output) compact=1 ;;
      --monochrome-output) monochrome=1 ;;
      --null-input) null_input=1 ;;
      -[a-zA-Z]*)
        [[ "$arg" != *c* ]] || compact=1
        [[ "$arg" != *M* ]] || monochrome=1
        [[ "$arg" != *n* ]] || null_input=1
        [[ "$arg" != *C* ]] || return 94 ;;
      *) return 95 ;;
    esac
  done
  [[ "$compact:$monochrome:$null_input" == 1:1:1 ]] || return 96
}

f512d_report_context() {
  cat <<'ZSH'
export USER=f512-fixture
_vpn_report_darwin_routing() { print -r -- reached > "$F512D_CASE/aux-darwin-routing.reached"; _vpn_rpt_bullet "Finite routing fixture."; }
_vpn_darwin_bash4() { REPLY="$F512D_FIXTURE_BASH"; return 0; }
_vpn_darwin_bash_version() { REPLY=5; return 0; }
_vpn_have_sudo_cache() { return 1; }
_vpn_configs_access_state() { print -r -- direct; }
_vpn_wg_access_state() { print -r -- direct; }
_vpn_get_active_interfaces() { return 0; }
_vpn_should_apply_wsl_ipv6_fix() { return 1; }
_vpn_dns_resolvers() { print -r -- 192.0.2.53; }
_vpn_get_ip_info() { print -r -- $'203.0.113.7\tCity\tRegion\tZZ\tOrg\tprovider.example'; }
_vpn_get_ip_crosscheck() { return 1; }
vpn-report
ZSH
}

f512d_json() {
  local dir="$1" wanted="$2" route="$3"
  f512d_primary "$dir" "$wanted" || return $?
  [[ $(wc -l < "$dir/stdout" | tr -d ' ') == 1 ]] || return 41
  [[ $(tail -c 1 "$dir/stdout" | od -An -c | tr -d ' ') == '\n' ]] || return 42
  "$F512D_REAL_JQ" -es --arg route "$route" '
    length == 1 and (.[0] | type) == "object" and
    (.[0] | keys_unsorted[0]) == "schema" and
    .[0].schema == "zdx.vpn-mtu-probe.v1" and
    ((.[0] | keys | sort) == (["schema","applicable","supported","reachable","target","address","profile","platform","path_mtu","exact","egress_interface","egress_mtu","through_tunnel","tunnel_interface","tunnel_mtu","probes","duration_ms","recommendations","reason"] | sort)) and
    (.[0].applicable | type) == "boolean" and
    (.[0].supported == null or (.[0].supported | type) == "boolean") and
    (.[0].reachable == null or (.[0].reachable | type) == "boolean") and
    (.[0].path_mtu == null or (.[0].path_mtu | type) == "number") and
    (.[0].exact == null or (.[0].exact | type) == "boolean") and
    (.[0].egress_mtu == null or (.[0].egress_mtu | type) == "number") and
    (.[0].tunnel_mtu == null or (.[0].tunnel_mtu | type) == "number") and
    (.[0].through_tunnel == null or (.[0].through_tunnel | type) == "boolean") and
    ([.[0].target,.[0].address,.[0].profile,.[0].egress_interface,.[0].tunnel_interface,.[0].reason] | all(. == null or (type == "string" and length > 0))) and
    (.[0].platform | type) == "string" and (.[0].platform | length) > 0 and
    (.[0].probes | type) == "number" and (.[0].duration_ms | type) == "number" and
    (.[0].recommendations | type) == "array" and
    (.[0].recommendations | all(type == "string")) and
    .[0].probes >= 0 and .[0].probes <= 16 and .[0].duration_ms >= 0 and
    (.[0] | .target == "192.0.2.1" and .profile == null and
      .tunnel_interface == null and .tunnel_mtu == null and .recommendations == [] and
      if $route == "success" then
        .applicable == true and .platform == "linux" and .supported == true and .reachable == true and
        .address == "192.0.2.1" and .path_mtu == 1500 and .exact == true and
        .egress_interface == "eth0" and .egress_mtu == 1500 and .through_tunnel == false and .probes == 2 and .reason == null
      elif $route == "failed" then
        .applicable == true and .platform == "linux" and .supported == true and .reachable == false and
        .address == null and .path_mtu == null and .exact == null and .egress_interface == null and
        .egress_mtu == null and .through_tunnel == null and .probes == 0 and .reason == "finite no reply"
      elif $route == "unsupported" then
        .applicable == false and .platform == "other" and .supported == null and .reachable == null and
        .address == null and .path_mtu == null and .exact == null and .egress_interface == null and
        .egress_mtu == null and .through_tunnel == null and .probes == 0 and .duration_ms == 0 and
        .reason == "the probe supports Linux, WSL, and macOS"
      elif $route == "no-backend" or $route == "standalone-no-backend" then
        .applicable == true and .platform == "linux" and .supported == false and .reachable == null and
        .address == null and .path_mtu == null and .exact == null and .egress_interface == null and
        .egress_mtu == null and .through_tunnel == null and .probes == 0 and .duration_ms == 0 and
        .reason == "timeout or gtimeout is required without the ZDX core"
      else false end)
  ' "$dir/stdout" >/dev/null || return 43
  if LC_ALL=C grep -Eq $'\033|════|PRIVATE-' "$dir/stdout"; then return 44; fi
}

@test "vpn diagnostic facts: failed public lookups retain local DNS diagnostics" {
  # Dependency absence is modeled at the existing owner seam; no literal
  # installed-tool absence or physical provider failure is inferred.
  local scene program
  for scene in modeled-missing-curl modeled-missing-jq failed healthy; do
    export F512D_PROVIDER_RC=0
    [[ "$scene" == failed ]] && export F512D_PROVIDER_RC=17
    export F512D_SCENE="$scene"
    program='
      _vpn_get_active_interfaces() { print -r -- wg0; }
      _vpn_wg_show() { return 0; }
      _vpn_iface_internal_addrs() { print -r -- 10.0.0.2; }
      _vpn_iface_endpoint() { print -r -- 192.0.2.1:51820; }
      _vpn_iface_latest_handshake() { print -r -- 0; }
      _vpn_iface_transfer() { printf "0\t0\n"; }
      _vpn_default_route() { return 0; }
      _vpn_dns_from_conf() { print -r -- 10.64.0.53; }
      _vpn_have_ip_stack() { [[ "$F512D_SCENE" != modeled-missing-* ]]; }
      _vpn_get_ip_info() { command curl --f512-provider; }
      _vpn_dns_resolvers() { print -r -- reached >> "$F512D_CASE/dns.reached"; print -r -- 192.0.2.53; }
      vpn-ip-info'
    f512d_observe "dns-$scene" "$program" || return 1
  done
  for scene in modeled-missing-curl modeled-missing-jq failed healthy; do
    local dir="$F512D_ROOT/dns-$scene"
    f512d_ui "$dir" 0 || return $?
    [[ -f "$dir/dns.reached" && $(wc -l < "$dir/dns.reached" | tr -d ' ') == 1 ]] || return 45
    [[ $(grep -c 'DNS resolvers' "$dir/stderr") == 1 ]] || return 46
    grep -Fq '192.0.2.53' "$dir/stderr" || return 47
    grep -Fq 'Possible DNS leak' "$dir/stderr" || return 48
    if [[ "$scene" == modeled-missing-* ]]; then [[ ! -e "$dir/curl.argv.nul" ]] || return 49
    else [[ -s "$dir/curl.argv.nul" ]] || return 50; fi
  done
}

@test "vpn platform facts: eligibility agrees with selected native execution and timeout backend" {
  export F512D_REAL_WSL=1 WSL_DISTRO_NAME=Fixture
  # A command-cache entry is not the PATH executable selected by whence -p.
  # Never execute or create any program at a literal Windows drive path.
  f512d_observe eligibility-cachehash '
    if (( ! ${+functions[_vpn_cmd_path]} )); then
      print -r -- UNREACHED_NEW_SELECTOR_ABSENT_ON_M11 > "$F512D_CASE/classification"
      return 0
    fi
    OSTYPE=linux-gnu; export WSL_DISTRO_NAME=Fixture
    local wsl_rc=0
    _vpn_is_wsl || wsl_rc=$?
    print -r -- "$wsl_rc" > "$F512D_CASE/wsl.status"
    hash jq=/mnt/c/Tools/jq curl=/mnt/c/Tools/curl wg=/mnt/c/Tools/wg vpn-leaf=/mnt/c/Tools/vpn-leaf
    local tool selected="" code=0
    for tool in jq curl wg vpn-leaf; do
      command -v "$tool" > "$F512D_CASE/$tool.command-v"; code=$?
      print -r -- "$code" > "$F512D_CASE/$tool.command-v.status"
      builtin whence -p -- "$tool" > "$F512D_CASE/$tool.whence-p"; code=$?
      print -r -- "$code" > "$F512D_CASE/$tool.whence-p.status"
      code=0; _vpn_cmd_path "$tool" || code=$?
      print -r -- "$code" > "$F512D_CASE/$tool.selected.status"
      print -rn -- "$REPLY" > "$F512D_CASE/$tool.selected"
      [[ "$code" == 0 && "$REPLY" == "$TEST_MOCK_BIN/$tool" ]] || return 94
      if [[ "$tool" == vpn-leaf ]]; then selected="$REPLY"; continue; fi
      code=0; _vpn_check_cmd "$tool" || code=$?
      print -r -- "$tool:$code" >> "$F512D_CASE/availability"
      code=0; _vpn_menu_have "$tool" || code=$?
      print -r -- "$tool:$code" >> "$F512D_CASE/menu-availability"
    done
    code=0; _vpn_have_ip_stack || code=$?
    print -r -- "$code" > "$F512D_CASE/ip-stack.status"
    print -r -- CACHE_HASH_NOT_SELECTED_NATIVE_PATH > "$F512D_CASE/classification"
    # Execute only the observed frozen private selection, never the hash.
    _vpn_readonly_exec 3 "$selected" literal payload' || return 1
  local mode
  for mode in core standalone; do
    export F512D_EXEC_MODE="$mode" F512D_LOAD_MODE="$mode"
    f512d_observe "eligibility-native-$mode" '
      _vpn_readonly_exec 3 "$TEST_MOCK_BIN/vpn-leaf" literal payload' || return 1
  done
  # Candidate-only selection companion: qualification rejects a real private
  # timeout recorder; no literal /mnt program exists or executes in this model.
  export F512D_LOAD_MODE=core
  f512d_observe eligibility-selected-backend '
    if (( ! ${+functions[_vpn_tool_path_allowed]} )); then
      print -r -- NEW_PATH_NOT_PRESENT_ON_BASE > "$F512D_CASE/model.classification"
      return 0
    fi
    functions[_f512_path_allowed]=$functions[_vpn_tool_path_allowed]
    _vpn_tool_path_allowed() { [[ "$1" != "$TEST_MOCK_BIN/timeout" ]] && _f512_path_allowed "$@"; }
    print -r -- MODELED_NATIVE_BACKEND_SELECTION > "$F512D_CASE/model.classification"
    _vpn_readonly_exec 3 "$TEST_MOCK_BIN/vpn-leaf" literal payload' || return 1
  export F512D_KERNEL=Darwin
  f512d_observe eligibility-darwin-variable '
    OSTYPE=darwin23.0; export WSL_DISTRO_NAME=Fixture
    local code=0; _vpn_is_wsl || code=$?
    print -r -- "$code" > "$F512D_CASE/wsl.status"
    return 0' || return 1
  export F512D_KERNEL=Linux
  f512d_observe eligibility-pure-policy '
    if (( ! ${+functions[_vpn_tool_path_allowed]} )); then
      print -r -- UNREACHED_NEW_POLICY_ABSENT_ON_M11 > "$F512D_CASE/classification"
      return 0
    fi
    OSTYPE=linux-gnu; export WSL_DISTRO_NAME=Fixture
    local -i code=0
    _vpn_tool_path_allowed /mnt/c/ZDX-F512-VIRTUAL-NOT-CREATED/vpn-leaf || code=$?
    print -r -- "$code" > "$F512D_CASE/logical-drive.status"
    code=0; _vpn_tool_path_allowed "$TEST_MOCK_BIN/vpn-leaf" || code=$?
    print -r -- "$code" > "$F512D_CASE/private-eligible.status"
    command ln -s -- /mnt/c/ZDX-F512-VIRTUAL-NOT-CREATED/vpn-leaf "$F512D_CASE/drive-alias" || return 94
    local alias_path="$F512D_CASE/drive-alias" resolved=""
    resolved="${alias_path:A}"
    print -rn -- "$resolved" > "$F512D_CASE/resolved.path"
    code=0; _vpn_tool_path_allowed "$alias_path" || code=$?
    print -r -- "$code" > "$F512D_CASE/resolved-policy.status"
    if [[ "$resolved" == /mnt/[a-zA-Z]/* ]]; then
      print -r -- RESOLVED_DRIVE_POLICY_OBSERVED > "$F512D_CASE/classification"
    else
      print -r -- UNREACHED_RESOLVED_DRIVE_NOT_OBSERVED > "$F512D_CASE/classification"
    fi
    return 0' || return 1
  f512d_observe eligibility-denied-private-model '
    if (( ! ${+functions[_vpn_tool_path_allowed]} || ! ${+functions[_vpn_cmd_path]} )); then
      print -r -- UNREACHED_NEW_POLICY_ABSENT_ON_M11 > "$F512D_CASE/classification"
      return 0
    fi
    local tool code=0
    for tool in jq curl wg; do
      _vpn_cmd_path "$tool" || return 94
      [[ "$REPLY" == "$TEST_MOCK_BIN/$tool" ]] || return 94
      print -r -- "$REPLY" >> "$F512D_CASE/rejected.selected.paths"
    done
    functions[_f512_path_allowed]=$functions[_vpn_tool_path_allowed]
    _vpn_tool_path_allowed() {
      case "$1" in "$TEST_MOCK_BIN/jq"|"$TEST_MOCK_BIN/curl"|"$TEST_MOCK_BIN/wg") return 1 ;; esac
      _f512_path_allowed "$@"
    }
    for tool in jq curl wg; do
      code=0; _vpn_check_cmd "$tool" || code=$?
      print -r -- "$tool:$code" >> "$F512D_CASE/availability"
      code=0; _vpn_menu_have "$tool" || code=$?
      print -r -- "$tool:$code" >> "$F512D_CASE/menu-availability"
      code=0; _vpn_readonly_exec 3 "$TEST_MOCK_BIN/$tool" --f512-rejected || code=$?
      print -r -- "$tool:$code" >> "$F512D_CASE/execution"
    done
    code=0; _vpn_have_ip_stack || code=$?
    print -r -- "$code" > "$F512D_CASE/ip-stack.status"
    print -r -- MODELED_SELECTED_PRIVATE_PAYLOAD_REJECTION > "$F512D_CASE/classification"
    return 0' || return 1
  f512d_observe eligibility-watchdog-protocol '
    if (( ! ${+functions[_vpn_tool_path_allowed]} )); then
      print -r -- UNREACHED_NEW_POLICY_ABSENT_ON_M11 > "$F512D_CASE/classification"
      return 0
    fi
    (( ${+functions[_zdx_run_with_timeout]} && ${+functions[_zdx_timeout_watchdog]} )) || return 94
    functions[_f512_path_allowed]=$functions[_vpn_tool_path_allowed]
    _vpn_tool_path_allowed() {
      case "$1" in "$TEST_MOCK_BIN/timeout"|"$TEST_MOCK_BIN/gtimeout")
        print -r -- "$1" >> "$F512D_CASE/backends.rejected" || return 94
        return 1 ;;
      esac
      _f512_path_allowed "$@"
    }
    _zdx_timeout_watchdog() {
      printf "%s\0" "$#" _zdx_timeout_watchdog "$@" > "$F512D_CASE/watchdog.argv.nul" || return 94
      [[ $# == 4 && "$1" == 3 && "$2" == "$TEST_MOCK_BIN/vpn-leaf" && "$3" == literal && "$4" == payload ]] || return 97
      local program="$2"
      local -i code=0
      shift 2
      command "$program" "$@" || code=$?
      print -r -- "$code" > "$F512D_CASE/watchdog.child-post-return.status" || return 94
      return "$code"
    }
    print -r -- MODELED_CORE_WATCHDOG_PROTOCOL > "$F512D_CASE/classification"
    _vpn_readonly_exec 3 "$TEST_MOCK_BIN/vpn-leaf" literal payload' || return 1

  local dir="$F512D_ROOT/eligibility-cachehash" tool classification
  f512d_primary "$dir" 0 || return $?
  classification=$(cat "$dir/classification") || return 1
  case "$classification" in
    UNREACHED_NEW_SELECTOR_ABSENT_ON_M11) [[ ! -s "$dir/stdout" && ! -s "$dir/stderr" && ! -e "$dir/vpn-leaf.argv.nul" ]] || return 51 ;;
    CACHE_HASH_NOT_SELECTED_NATIVE_PATH)
      [[ $(cat "$dir/wsl.status") == 0 && $(cat "$dir/ip-stack.status") == 0 ]] || return 51
      for tool in jq curl wg vpn-leaf; do
        [[ $(cat "$dir/$tool.command-v.status") == 0 && $(cat "$dir/$tool.whence-p.status") == 0 && $(cat "$dir/$tool.selected.status") == 0 ]] || return 51
        printf '/mnt/c/Tools/%s\n' "$tool" > "$dir/$tool.command-v.expected" || return 1
        cmp "$dir/$tool.command-v.expected" "$dir/$tool.command-v" || return 51
        printf '%s/%s\n' "$TEST_MOCK_BIN" "$tool" > "$dir/$tool.whence.expected" || return 1
        cmp "$dir/$tool.whence.expected" "$dir/$tool.whence-p" || return 51
        printf '%s/%s' "$TEST_MOCK_BIN" "$tool" > "$dir/$tool.selected.expected" || return 1
        cmp "$dir/$tool.selected.expected" "$dir/$tool.selected" || return 51
      done
      printf 'jq:0\ncurl:0\nwg:0\n' > "$dir/expected.availability" || return 1
      cmp "$dir/expected.availability" "$dir/availability" || return 51
      cmp "$dir/expected.availability" "$dir/menu-availability" || return 52
      f512d_native "$dir" timeout || return $? ;;
    *) return 55 ;;
  esac
  f512d_ui "$F512D_ROOT/eligibility-darwin-variable" 0 || return $?
  [[ $(cat "$F512D_ROOT/eligibility-darwin-variable/wsl.status") == 1 ]] || return 51
  for mode in core standalone; do
    local dir="$F512D_ROOT/eligibility-native-$mode"
    f512d_native "$dir" timeout || return $?
  done
  local dir="$F512D_ROOT/eligibility-selected-backend"
  f512d_primary "$dir" 0 || return $?
  case "$(cat "$dir/model.classification")" in
    NEW_PATH_NOT_PRESENT_ON_BASE) : ;; # Unexercised new-path companion, never a base red.
    MODELED_NATIVE_BACKEND_SELECTION) f512d_native "$dir" gtimeout || return $? ;;
    *) return 55 ;;
  esac
  local dir="$F512D_ROOT/eligibility-pure-policy"
  f512d_ui "$dir" 0 || return $?
  classification=$(cat "$dir/classification") || return 1
  case "$classification" in
    UNREACHED_NEW_POLICY_ABSENT_ON_M11) [[ ! -e "$dir/drive-alias" && ! -e "$dir/logical-drive.status" ]] || return 53 ;;
    RESOLVED_DRIVE_POLICY_OBSERVED|UNREACHED_RESOLVED_DRIVE_NOT_OBSERVED)
      [[ $(cat "$dir/logical-drive.status") == 1 && $(cat "$dir/private-eligible.status") == 0 ]] || return 53
      if [[ "$classification" == RESOLVED_DRIVE_POLICY_OBSERVED ]]; then
        [[ $(cat "$dir/resolved.path") == /mnt/[a-zA-Z]/* && $(cat "$dir/resolved-policy.status") == 1 ]] || return 53
      fi ;;
    *) return 55 ;;
  esac
  local dir="$F512D_ROOT/eligibility-denied-private-model"
  f512d_ui "$dir" 0 || return $?
  classification=$(cat "$dir/classification") || return 1
  case "$classification" in
    UNREACHED_NEW_POLICY_ABSENT_ON_M11) [[ ! -e "$dir/rejected.selected.paths" ]] || return 54 ;;
    MODELED_SELECTED_PRIVATE_PAYLOAD_REJECTION)
      printf '%s\n' "$TEST_MOCK_BIN/jq" "$TEST_MOCK_BIN/curl" "$TEST_MOCK_BIN/wg" > "$dir/rejected.expected.paths" || return 1
      cmp "$dir/rejected.expected.paths" "$dir/rejected.selected.paths" || return 54
      printf 'jq:1\ncurl:1\nwg:1\n' > "$dir/expected.availability" || return 1
      cmp "$dir/expected.availability" "$dir/availability" || return 54
      cmp "$dir/expected.availability" "$dir/menu-availability" || return 54
      printf 'jq:127\ncurl:127\nwg:127\n' > "$dir/expected.execution" || return 1
      cmp "$dir/expected.execution" "$dir/execution" || return 54
      [[ $(cat "$dir/ip-stack.status") == 1 && ! -e "$dir/jq.argv.nul" && ! -e "$dir/curl.argv.nul" && ! -e "$dir/wg.argv.nul" && ! -e "$dir/timeout.argv.nul" && ! -e "$dir/gtimeout.argv.nul" ]] || return 54 ;;
    *) return 55 ;;
  esac
  local dir="$F512D_ROOT/eligibility-watchdog-protocol"
  f512d_primary "$dir" 0 || return $?
  classification=$(cat "$dir/classification") || return 1
  case "$classification" in
    UNREACHED_NEW_POLICY_ABSENT_ON_M11) [[ ! -s "$dir/stdout" && ! -s "$dir/stderr" && ! -e "$dir/watchdog.argv.nul" ]] || return 55 ;;
    MODELED_CORE_WATCHDOG_PROTOCOL)
      printf 'ELIGIBLE-LEAF\n' > "$dir/expected.stdout" || return 1
      cmp "$dir/expected.stdout" "$dir/stdout" || return 55
      [[ ! -s "$dir/stderr" && $(cat "$dir/leaf.stdin") == closed && $(cat "$dir/watchdog.child-post-return.status") == 0 && ! -e "$dir/timeout.argv.nul" && ! -e "$dir/gtimeout.argv.nul" ]] || return 55
      printf '%s\n' "$TEST_MOCK_BIN/timeout" "$TEST_MOCK_BIN/gtimeout" > "$dir/backends.expected.rejected" || return 1
      cmp "$dir/backends.expected.rejected" "$dir/backends.rejected" || return 55
      f512d_argv_exact "$dir/watchdog.argv.nul" _zdx_timeout_watchdog 3 "$TEST_MOCK_BIN/vpn-leaf" literal payload || return $?
      f512d_argv_exact "$dir/vpn-leaf.argv.nul" "$TEST_MOCK_BIN/vpn-leaf" literal payload || return $? ;;
    *) return 55 ;;
  esac
}

@test "vpn platform facts: cold completion resolves a bounded custom Homebrew prefix" {
  export F512D_COLD_PREFIX="$F512D_ROOT/custom-brew"
  mkdir -p "$F512D_COLD_PREFIX/etc/wireguard" || return 1
  chmod -- 700 "$F512D_COLD_PREFIX" "$F512D_COLD_PREFIX/etc" "$F512D_COLD_PREFIX/etc/wireguard" || return 1
  printf '[Interface]\n' > "$F512D_COLD_PREFIX/etc/wireguard/custom.conf" || return 1
  chmod -- 600 "$F512D_COLD_PREFIX/etc/wireguard/custom.conf" || return 1
  local scene
  for scene in healthy failed explicit system failed-fallback first-line cap1024 cap1025; do
    export F512D_COLD_SCENE="$scene" F512D_BREW_RC=0
    export F512D_BREW_OUTPUT="$F512D_COLD_PREFIX"
    export F512D_CASE="$F512D_ROOT/cold-$scene"
    mkdir -m 700 "$F512D_CASE" "$F512D_CASE/private-fallback" || return 1
    case "$scene" in
      failed) export F512D_BREW_RC=17 ;;
      explicit|system|failed-fallback)
        local target="$F512D_CASE/private-fallback" name=fallback
        if [[ "$scene" == explicit ]]; then target="$F512D_CASE/explicit"; name=explicit
        elif [[ "$scene" == system ]]; then target="$F512D_CASE/private-system-directory"; name=system
        else export F512D_BREW_RC=17; fi
        [[ -d "$target" ]] || mkdir -m 700 "$target" || return 1
        printf '[Interface]\n' > "$target/$name.conf" || return 1
        chmod -- 600 "$target/$name.conf" || return 1
        # The explicit directory also wins over an existing private system dir.
        if [[ "$scene" == explicit ]]; then
          mkdir -m 700 "$F512D_CASE/private-system-directory" || return 1
          printf '[Interface]\n' > "$F512D_CASE/private-system-directory/system.conf" || return 1
          chmod -- 600 "$F512D_CASE/private-system-directory/system.conf" || return 1
        fi ;;
      first-line)
        export F512D_BREW_OUTPUT="$F512D_COLD_PREFIX"$'\n'"$F512D_CASE/ignored-prefix"
        mkdir -p "$F512D_CASE/ignored-prefix/etc/wireguard" || return 1
        chmod -- 700 "$F512D_CASE/ignored-prefix" "$F512D_CASE/ignored-prefix/etc" "$F512D_CASE/ignored-prefix/etc/wireguard" || return 1
        printf '[Interface]\n' > "$F512D_CASE/ignored-prefix/etc/wireguard/ignored.conf" || return 1
        chmod -- 600 "$F512D_CASE/ignored-prefix/etc/wireguard/ignored.conf" || return 1 ;;
      cap1024|cap1025)
        local limit="${scene#cap}" prefix_bytes padding filler utf8
        prefix_bytes=$(printf '%s' "$F512D_COLD_PREFIX" | wc -c | tr -d ' ') || return 1
        padding=$((limit-prefix_bytes-4))
        [[ "$padding" -ge 0 ]] || return 1
        printf -v filler '%*s' "$padding" '' || return 1
        utf8=$(printf '\303\251') || return 1
        [[ ${#utf8} == 1 ]] || return 1
        export F512D_BREW_OUTPUT="$F512D_COLD_PREFIX"$'\n'"$filler$utf8"
        printf '%s\n' "$F512D_BREW_OUTPUT" > "$F512D_CASE/brew.expected.stdout" || return 1
        # Verify real raw byte counts before invoking any cold helper.
        [[ $(file_size "$F512D_CASE/brew.expected.stdout") == "$limit" ]] || return 1 ;;
    esac
    local wrapper=0
    if zsh -f -c '
      emulate -R zsh
      unset VPN_CONFIG_DIR HOMEBREW_PREFIX
      OSTYPE=darwin23.0
      typeset -ga words=(vpn-on)
      _f512d_lstat_absent() {
        emulate -L zsh
        unsetopt xtrace force_float
        zmodload -F zsh/system p:errnos || return 90
        local ERRNO=0
        local -i blocked=0 code=0 syserr=0 index=0
        local probe_path
        for probe_path in "$@"; do
          (( index += 1 ))
          : > "$F512D_CASE/lstat.$index.stderr" || return 91
          ERRNO=0
          if [[ -L "$probe_path" ]]; then
            syserr=$ERRNO code=$?
          else
            syserr=$ERRNO code=$?
          fi
          print -r -- "$probe_path:$code:$syserr" >> "$F512D_CASE/lstat.receipts" || return 91
          (( code == 1 && syserr == errnos[(Ie)ENOENT] )) || blocked=1
        done
        (( blocked == 0 ))
      }
      _arguments() {
        local spec
        if (( ${+functions[_vpn_menu_cold_profile_dir]} )); then
          (( ${+functions[_vpn_menu_cold_fallback_dirs]} && ${+functions[_vpn_menu_cold_brew_prefix]} )) || return 93
          functions[_f512_cold_selector]=$functions[_vpn_menu_cold_profile_dir]
          functions[_f512_cold_prefix]=$functions[_vpn_menu_cold_brew_prefix]
          _vpn_menu_cold_profile_dir() { _f512_cold_selector "$F512D_CASE/private-system-directory"; }
          _vpn_menu_cold_fallback_dirs() {
            print -r -- reached > "$F512D_CASE/fallback.reached" || return 94
            reply=("$F512D_CASE/private-fallback")
          }
          _vpn_menu_cold_brew_prefix() {
            local -i code=0
            _f512_cold_prefix || code=$?
            print -r -- "$code" > "$F512D_CASE/prefix.primary.status" || return 94
            print -rn -- "$REPLY" > "$F512D_CASE/prefix.reply" || return 94
            return "$code"
          }
          [[ "$F512D_COLD_SCENE" != explicit ]] || VPN_CONFIG_DIR="$F512D_CASE/explicit"
          print -r -- CANDIDATE_PRIVATE_SYSTEM_AND_FALLBACK_SELECTORS > "$F512D_CASE/classification"
        else
          case "$F512D_COLD_SCENE" in
            healthy|failed) ;;
            *) print -r -- UNREACHED_NEW_COLD_HELPERS_ABSENT_ON_M11 > "$F512D_CASE/classification"; return 0 ;;
          esac
          # Adjacent actual ENOENT proof is required before the M11 callback.
          if ! _f512d_lstat_absent /private/etc/wireguard /opt/homebrew/etc/wireguard /usr/local/etc/wireguard; then
            print -r -- UNREACHED_LITERAL_DIRECTORY_NOT_PROVEN_ABSENT > "$F512D_CASE/classification"
            return 0
          fi
          print -r -- REACHED_FRESH_LITERAL_ENOENT_GATE > "$F512D_CASE/classification"
        fi
        for spec in "$@"; do [[ "$spec" == 1:profile:_vpn_menu_profiles ]] && _vpn_menu_profiles; done
        return 0
      }
      _describe() { print -rl -- "${(@P)${@[-1]}}"; }
      (( ! ${+functions[_vpn_config_dir_resolve]} )) || return 91
      (( ! ${+functions[_zdx_run_with_timeout]} && ! ${+functions[_zdx_timeout_watchdog]} )) || return 91
      builtin source "$TEST_SUITE_ROOT/completions/_vpn-menu" > "$F512D_CASE/stdout" 2> "$F512D_CASE/stderr"
      local primary=$?
      print -r -- "$primary" > "$F512D_CASE/primary.status"
      print -rn -- "" > "$F512D_CASE/reply"
      (( ! ${+functions[_vpn_config_dir_resolve]} )) || return 92
      return 0
    ' > "$F512D_CASE/wrapper.stdout" 2> "$F512D_CASE/wrapper.stderr"; then wrapper=0; else wrapper=$?; fi
    printf '%s\n' "$wrapper" > "$F512D_CASE/wrapper.status" || return 1
  done
  for scene in healthy failed explicit system failed-fallback first-line cap1024 cap1025; do
    local dir="$F512D_ROOT/cold-$scene" classification expected_profile=""
    classification=$(cat "$dir/classification") || return 1
    f512d_primary "$dir" 0 || return $?
    case "$classification" in
      UNREACHED_NEW_COLD_HELPERS_ABSENT_ON_M11)
        case "$scene" in healthy|failed) return 56 ;; esac
        [[ ! -s "$dir/stdout" && ! -s "$dir/stderr" && ! -e "$dir/brew.argv.nul" ]] || return 56
        continue ;;
      REACHED_FRESH_LITERAL_ENOENT_GATE|CANDIDATE_PRIVATE_SYSTEM_AND_FALLBACK_SELECTORS) ;;
      *) return 56 ;;
    esac
    if [[ "$scene" == explicit || "$scene" == system ]]; then
      [[ ! -e "$dir/brew.argv.nul" && ! -e "$dir/timeout.argv.nul" && ! -e "$dir/prefix.primary.status" && ! -e "$dir/fallback.reached" ]] || return 57
      expected_profile="$scene"
    else
      f512d_argv_exact "$dir/brew.argv.nul" "$TEST_MOCK_BIN/brew" --prefix || return $?
      f512d_argv_exact "$dir/timeout.argv.nul" "$TEST_MOCK_BIN/timeout" -k 2s 3s "$TEST_MOCK_BIN/brew" --prefix || return $?
      [[ $(cat "$dir/brew.stdin") == closed ]] || return 57
      local child_code=0
      case "$scene" in failed|failed-fallback) child_code=17 ;; esac
      printf '%s\n' "$child_code" > "$dir/backend.expected.status" || return 1
      cmp "$dir/backend.expected.status" "$dir/backend.child-post-return.status" || return 57
      if [[ "$classification" == CANDIDATE_PRIVATE_SYSTEM_AND_FALLBACK_SELECTORS ]]; then
        local prefix_code=0
        case "$scene" in failed|failed-fallback|cap1025) prefix_code=1 ;; esac
        printf '%s\n' "$prefix_code" > "$dir/prefix.expected.status" || return 1
        cmp "$dir/prefix.expected.status" "$dir/prefix.primary.status" || return 58
        [[ -f "$dir/fallback.reached" ]] || return 58
        if [[ "$prefix_code" == 0 ]]; then
          printf '%s' "$F512D_COLD_PREFIX" > "$dir/prefix.expected.reply" || return 1
          cmp "$dir/prefix.expected.reply" "$dir/prefix.reply" || return 58
        else [[ ! -s "$dir/prefix.reply" ]] || return 58; fi
      fi
      case "$scene" in healthy|first-line|cap1024) expected_profile=custom ;; failed-fallback) expected_profile=fallback ;; esac
    fi
    if [[ -n "$expected_profile" ]]; then
      printf '%s\n' "$expected_profile" > "$dir/expected.stdout" || return 1
    else : > "$dir/expected.stdout" || return 1; fi
    cmp "$dir/expected.stdout" "$dir/stdout" || return 59
    [[ ! -s "$dir/stderr" ]] || return 60
  done
}

@test "vpn diagnostic facts: access metadata uses zstat and preserves caller stat" {
  f512d_observe access-metadata '
    stat() { print -r -- CALLER-STAT; }
    alias stat="print -r -- CALLER-STAT-ALIAS"
    print -r -- "$functions[stat]" > "$F512D_CASE/stat.function.before"
    print -r -- "$aliases[stat]" > "$F512D_CASE/stat.alias.before"
    vpn-access-status
    local primary=$?
    print -r -- "$functions[stat]" > "$F512D_CASE/stat.function.after"
    print -r -- "$aliases[stat]" > "$F512D_CASE/stat.alias.after"
    return "$primary"' || return 1
  local dir="$F512D_ROOT/access-metadata" uid gid
  f512d_ui "$dir" 0 || return $?
  [[ ! -e "$dir/stat.argv.nul" ]] || return 61
  uid=$(file_stat "$dir/profiles" uid) || return 1
  gid=$(file_stat "$dir/profiles" gid) || return 1
  [[ $(grep -c 'Directory mode' "$dir/stderr") == 1 ]] || return 62
  grep -Eq "700.*${uid}.*${gid}" "$dir/stderr" || return 63
  cmp "$dir/stat.function.before" "$dir/stat.function.after" || return 64
  cmp "$dir/stat.alias.before" "$dir/stat.alias.after" || return 65
}

@test "vpn diagnostic facts: every MTU JSON route captures one monochrome document" {
  local route code
  for route in unsupported no-backend failed success standalone-no-backend; do
    for code in 0 17 130 143; do
      export F512D_JSON_ROUTE="$route" F512D_JQ_RC="$code" F512D_JQ_MODE=failed F512D_LOAD_MODE=core
      [[ "$route" == standalone-no-backend ]] && export F512D_LOAD_MODE=standalone
      [[ "$code" == 0 ]] && export F512D_JQ_MODE=real
      f512d_observe "json-$route-$code" '
        _vpn_mtu_measure() {
          print -r -- reached > "$F512D_CASE/measure.reached"
          if [[ "$F512D_JSON_ROUTE" == failed ]]; then mtu[supported]=true; mtu[reachable]=false; mtu[reason]="finite no reply"; return 1; fi
          mtu[supported]=true; mtu[reachable]=true; mtu[address]=192.0.2.1
          mtu[path_mtu]=1500; mtu[exact]=true; mtu[egress_interface]=eth0; mtu[egress_mtu]=1500
          mtu[through_tunnel]=false; mtu[probes]=2
          return 0
        }
        _vpn_mtu_recommend() { return 0; }
        case "$F512D_JSON_ROUTE" in
          unsupported) _VPN_PLATFORM=other ;;
          no-backend) _vpn_bounded_ready() { return 1; } ;;
          standalone-no-backend)
            command mkdir -m 700 -- "$F512D_CASE/no-backend-bin" || return 92
            command cp -- "$TEST_MOCK_BIN/jq" "$F512D_CASE/no-backend-bin/jq" || return 92
            PATH="$F512D_CASE/no-backend-bin"
            rehash
            builtin command -v timeout > "$F512D_CASE/timeout.lookup" 2>&1 && return 93
            builtin command -v gtimeout > "$F512D_CASE/gtimeout.lookup" 2>&1 && return 93
            ;;
        esac
        vpn-mtu-probe --json --target 192.0.2.1' || return 1
    done
  done
  for route in unsupported no-backend failed success standalone-no-backend; do
    for code in 0 17 130 143; do
      local dir="$F512D_ROOT/json-$route-$code" wanted=1
      [[ "$code" == 0 && "$route" == success ]] && wanted=0
      [[ "$code" == 130 || "$code" == 143 ]] && wanted="$code"
      f512d_primary "$dir" "$wanted" || return $?
      if [[ "$route" == standalone-no-backend ]]; then
        [[ $(cat "$dir/load-mode") == NO_CORE_LOADED && ! -s "$dir/timeout.lookup" && ! -s "$dir/gtimeout.lookup" && ! -e "$dir/selected.backend" ]] || return 66
      fi
      [[ -s "$dir/jq.argv.nul" && $(tail -n 1 "$dir/jq.child-post-return.status") == "$code" ]] || return 66
      if [[ "$code" == 0 ]]; then f512d_json "$dir" "$wanted" "$route" || return $?
      else [[ ! -s "$dir/stdout" ]] || return 67; fi
      # Arguments are NUL-delimited, never inferred from a merged UI log.
      local jq_program="$TEST_MOCK_BIN/jq"
      [[ "$route" != standalone-no-backend ]] || jq_program="$dir/no-backend-bin/jq"
      f512d_jq_argv "$dir/jq.argv.nul" "$jq_program" || return $?
    done
  done
}

@test "vpn platform facts: WSL header shows only proven default exceptions" {
  local scene mode route override mode_rc route_rc
  for scene in mirrored-default mirrored-forced nat-disabled unknown-absent unknown-failed; do
    mode=mirrored; route=present; override=''; mode_rc=0; route_rc=0
    case "$scene" in mirrored-forced) override=1 ;; nat-disabled) mode=nat; override=0 ;; unknown-absent) mode=unknown; route=absent ;; unknown-failed) mode=unknown; route=absent; route_rc=17 ;; esac
    export F512D_PLATFORM=wsl F512D_MODE="$mode" F512D_ROUTE="$route" F512D_MODE_RC="$mode_rc" F512D_ROUTE_RC="$route_rc" F512D_OVERRIDE="$override"
    f512d_observe "header-$scene" '
      _vpn_have_sudo_cache() { return 1; }
      _vpn_configs_access_state() { print -r -- direct; }
      _vpn_wg_access_state() { print -r -- direct; }
      _vpn_get_active_interfaces() { return 0; }
      if [[ -n "$F512D_OVERRIDE" ]]; then export VPN_MENU_WSL_IPV6_FIX="$F512D_OVERRIDE"; else unset VPN_MENU_WSL_IPV6_FIX; fi
      _vpn_state_load || return $?
      _vpn_menu_context' || return 1
  done
  for scene in mirrored-default mirrored-forced nat-disabled unknown-absent unknown-failed; do
    local dir="$F512D_ROOT/header-$scene"
    f512d_primary "$dir" 0 || return $?
    [[ $(wc -l < "$dir/stdout" | tr -d ' ') == 2 ]] || return 69
    case "$scene" in
      mirrored-forced) [[ $(grep -o 'WSL fix: on' "$dir/stdout" | wc -l | tr -d ' ') == 1 ]] || return 70 ;;
      nat-disabled) [[ $(grep -o 'WSL fix: off' "$dir/stdout" | wc -l | tr -d ' ') == 1 ]] || return 71 ;;
      *) if grep -Fq 'WSL fix:' "$dir/stdout"; then return 72; fi ;;
    esac
  done
}

@test "vpn diagnostic facts: report distinguishes wg-quick presence from version data" {
  local scene program
  program=$(f512d_report_context) || return 1
  for scene in present version-unavailable; do
    export F512D_WG_VERSION_RC=0
    [[ "$scene" == version-unavailable ]] && export F512D_WG_VERSION_RC=17
    f512d_observe "wgquick-$scene" "$program" || return 1
  done
  for scene in present version-unavailable; do
    local dir="$F512D_ROOT/wgquick-$scene" files
    f512d_ui "$dir" 0 || return $?
    [[ ! -e "$dir/wg-quick.argv.nul" ]] || return 73
    files=("$dir"/reports/vpn-report-*.md)
    [[ ${#files[@]} == 1 && -f "${files[0]}" ]] || return 74
    grep -Fq '**wg-quick:** installed' "${files[0]}" || return 75
    if grep -Fq '**wg-quick:** (not installed)' "${files[0]}"; then return 76; fi
  done
}

@test "vpn diagnostic facts: report never probes or lists unused Python" {
  local program files dir
  program=$(f512d_report_context) || return 1
  export F512D_PLATFORM=darwin F512D_KERNEL=Darwin
  f512d_observe python-removed "$program" || return 1
  dir="$F512D_ROOT/python-removed"
  f512d_ui "$dir" 0 || return $?
  [[ ! -e "$dir/python3.argv.nul" ]] || return 77
  files=("$dir"/reports/vpn-report-*.md)
  [[ ${#files[@]} == 1 && -f "${files[0]}" ]] || return 78
  if grep -Fq '**python3:**' "${files[0]}"; then return 79; fi
  grep -Fq 'Environment' "${files[0]}" || return 80
}

@test "vpn platform facts: disconnect gates unsupported hosts before plans" {
  local owner args
  export F512D_PLATFORM=other F512D_KERNEL=FreeBSD
  f512d_observe unsupported-selector-qualification '
    local private_profile_dir="$VPN_CONFIG_DIR"
    local -i code=0
    VPN_CONFIG_DIR=/etc/wireguard
    _vpn_config_dir_is_default || code=$?
    print -r -- "$code" > "$F512D_CASE/selector.literal.status" || return 94
    VPN_CONFIG_DIR="$private_profile_dir"
    code=0; _vpn_config_dir_is_default || code=$?
    print -r -- "$code" > "$F512D_CASE/selector.private.status" || return 94
    code=0; _vpn_require_platform || code=$?
    print -r -- "$code" > "$F512D_CASE/optin.gate.status" || return 94
    return 0' || return 1
  for owner in vpn-off vpn-off-all; do
    for args in action help invalid; do
      export F512D_OWNER="$owner" F512D_ARGS="$args"
      f512d_observe "unsupported-$owner-$args" '
        # Keep the real default selector; physical consumers use private data.
        local f512_private_profile_dir="$VPN_CONFIG_DIR"
        [[ "$f512_private_profile_dir" == "$F512D_CASE/profiles" ]] || return 94
        _vpn_config_dir() { (( $# == 0 )) || return 94; print -r -- "$f512_private_profile_dir"; }
        VPN_CONFIG_DIR=/etc/wireguard
        _vpn_ensure_wg_access() { print -r -- unexpected >> "$F512D_CASE/access.reached"; return 0; }
        _vpn_active_interfaces() { print -r -- unexpected >> "$F512D_CASE/active.reached"; reply=(wg0 wg1); return 0; }
        _vpn_ensure_sudo_access() { print -r -- unexpected >> "$F512D_CASE/auth.reached"; return 97; }
        case "$F512D_ARGS:$F512D_OWNER" in
          help:*) "$F512D_OWNER" --help ;;
          invalid:*) "$F512D_OWNER" --invalid ;;
          action:vpn-off) vpn-off wg0 ;;
          action:vpn-off-all) vpn-off-all --yes ;;
        esac' || return 1
    done
  done
  f512d_observe unsupported-vpn-summary-action '
    # Keep the real default selector; physical consumers use private data.
    local f512_private_profile_dir="$VPN_CONFIG_DIR"
    [[ "$f512_private_profile_dir" == "$F512D_CASE/profiles" ]] || return 94
    _vpn_config_dir() { (( $# == 0 )) || return 94; print -r -- "$f512_private_profile_dir"; }
    VPN_CONFIG_DIR=/etc/wireguard
    _vpn_state_load() { print -r -- unexpected > "$F512D_CASE/state.reached"; return 97; }
    vpn-summary' || return 1
  local qualification="$F512D_ROOT/unsupported-selector-qualification"
  f512d_ui "$qualification" 0 || return $?
  [[ $(cat "$qualification/selector.literal.status") == 0     && $(cat "$qualification/selector.private.status") == 1     && $(cat "$qualification/optin.gate.status") == 0 ]] || return 84
  for owner in vpn-off vpn-off-all; do
    for args in action help invalid; do
      local dir="$F512D_ROOT/unsupported-$owner-$args" wanted=1
      [[ "$args" == help ]] && wanted=0
      [[ "$args" == invalid ]] && wanted=2
      f512d_ui "$dir" "$wanted" || return $?
      [[ ! -e "$dir/auth.reached" && ! -e "$dir/active.reached" && ! -e "$dir/access.reached" ]] || return 81
      if [[ "$args" == action ]]; then
        [[ $(grep -c 'targets Linux, WSL, and macOS' "$dir/stderr") == 1 ]] || return 82
        if grep -Eq 'Stop VPN|Stop All VPN|Privileged operation:|wg-quick down' "$dir/stderr"; then return 83; fi
      fi
    done
  done
  local summary="$F512D_ROOT/unsupported-vpn-summary-action"
  f512d_ui "$summary" 1 || return $?
  [[ ! -e "$summary/state.reached" ]] || return 85
  [[ $(grep -c 'targets Linux, WSL, and macOS' "$summary/stderr") == 1 ]] || return 86
  if grep -Fq 'VPN Summary' "$summary/stderr"; then return 87; fi
}
