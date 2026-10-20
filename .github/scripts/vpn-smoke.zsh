#!/usr/bin/env zsh
# =============================================================================
# VPN Smoke: real-host tunnel check for disposable CI runners
# =============================================================================
#
# Run with ZDX_VPN_SMOKE=1 zsh -f .github/scripts/vpn-smoke.zsh in CI only.
# Safe to source; defines private smoke-test helpers only.
#
# Brings one private test tunnel up and down through the VPN suite on a GitHub
# Actions Ubuntu or macOS runner with passwordless sudo, and checks what the
# mocked BATS suite cannot: the live device listing, the macOS runtime record
# and its ownership, the profile-to-device pairing, and the tunnel route. The
# profile routes only 10.123.45.0/24 to the TEST-NET-1 endpoint 192.0.2.1 and
# has no DNS line, so the runner's own traffic and resolvers are not changed.
#
# Requirements: zsh and `sudo -n` without a password, plus on Linux
# wireguard-tools, iproute2, and a kernel with WireGuard, and on macOS
# Homebrew wireguard-tools (which installs wireguard-go) and bash.
# Status: 0 every check passed, 1 a check failed, 2 the host is not eligible.
#

if [[ -n "${_ZDX_VPN_SMOKE_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_zdx_vpn_smoke_note() { print -u2 -r -- "➜ $*"; }
_zdx_vpn_smoke_pass() { print -u2 -r -- "✔ $*"; }

# Records one failed check in the caller's `failures` counter.
_zdx_vpn_smoke_fail() {
  print -u2 -r -- "✘ $*"
  (( ++failures ))
  return 1
}

# REPLY: the live device of the smoke profile, from the suite's own mapping.
_zdx_vpn_smoke_device() {
  REPLY=""
  local -a reply=()
  _vpn_active_interfaces 2>/dev/null || return 1
  (( ${reply[(Ie)$profile]} )) || return 1
  REPLY="${_VPN_ACTIVE_DEVICES[$profile]-}"
  [[ -n "$REPLY" ]]
}

# Checks the live tunnel: listing, pairing, root-only state, and routes.
_zdx_vpn_smoke_check_up() {
  local device="" listing="" route="" REPLY=""
  if ! _zdx_vpn_smoke_device; then
    _zdx_vpn_smoke_fail "The suite does not list $profile as active."
    return 1
  fi
  device="$REPLY"
  listing=$(command wg show interfaces 2>/dev/null) || listing=""

  if [[ "$kernel" == Linux ]]; then
    [[ "$device" == "$profile" ]] \
      || _zdx_vpn_smoke_fail "Linux device $device is not named after the profile."
    [[ " $listing " == *" $profile "* ]] \
      || _zdx_vpn_smoke_fail "wg show interfaces does not list $profile."
    route=$(command ip route get "$probe" 2>/dev/null) || route=""
    [[ "$route" == *" dev $profile "* ]] \
      || _zdx_vpn_smoke_fail "The route to $probe does not use $profile: $route"
    route=$(command ip route get 1.1.1.1 2>/dev/null) || route=""
    [[ "$route" != *" dev $profile "* ]] \
      || _zdx_vpn_smoke_fail "The default route moved into the test tunnel: $route"
  else
    [[ "$device" =~ '^utun[0-9]+$' ]] \
      || _zdx_vpn_smoke_fail "macOS device $device is not a utun device."
    # Listing devices needs no privilege on macOS; device state needs root.
    [[ " $listing " == *" $device "* ]] \
      || _zdx_vpn_smoke_fail "Unprivileged wg show interfaces does not list $device."
    if command wg show "$device" >/dev/null 2>&1; then
      _zdx_vpn_smoke_fail "wg show $device worked without root; the suite assumes it needs root."
    fi
    command sudo -n "$(whence -p wg)" show "$device" >/dev/null 2>&1 \
      || _zdx_vpn_smoke_fail "wg show $device failed through sudo."

    # wireguard-go records the device as root, mode 0400, in the suite's
    # runtime directory (/private/var/run/wireguard).
    local record="$_VPN_DARWIN_RUN_DIR/$profile.name" recorded=""
    local -A state=()
    zmodload -F zsh/stat b:zstat
    if zstat -LH state -- "$record" 2>/dev/null; then
      (( state[uid] == 0 )) \
        || _zdx_vpn_smoke_fail "$record is owned by uid ${state[uid]}, not root."
      (( (state[mode] & 8#7777) == 8#400 )) \
        || _zdx_vpn_smoke_fail "$record has mode $(( [##8] state[mode] & 8#7777 )), not 400."
      [[ ! -r "$record" ]] \
        || _zdx_vpn_smoke_fail "$record is readable without privileges."
      recorded=$(command sudo -n /usr/bin/head -c 32 -- "$record") || recorded=""
      [[ "${recorded%%$'\n'*}" == "$device" ]] \
        || _zdx_vpn_smoke_fail "$record names ${recorded%%$'\n'*}, not $device."
    else
      _zdx_vpn_smoke_fail "The wg-quick runtime record $record is missing."
    fi

    route=$(command route -n get "$probe" 2>/dev/null) || route=""
    [[ "$route" == *"interface: $device"* ]] \
      || _zdx_vpn_smoke_fail "The route to $probe does not use $device."
    route=$(command route -n get 1.1.1.1 2>/dev/null) || route=""
    [[ "$route" != *"interface: $device"* ]] \
      || _zdx_vpn_smoke_fail "The default route moved into the test tunnel."
  fi
  (( failures == 0 )) && _zdx_vpn_smoke_pass "$profile is up on $device."
  return 0
}

# Waits briefly for the tunnel to disappear: wireguard-go leaves after wg-quick
# removes its socket.
_zdx_vpn_smoke_check_down() {
  local -i attempt=0
  local REPLY=""
  while (( attempt++ < 50 )); do
    if ! _zdx_vpn_smoke_device; then
      _zdx_vpn_smoke_pass "$profile is down."
      return 0
    fi
    command sleep 0.1
  done
  _zdx_vpn_smoke_fail "$profile is still active after vpn-off."
}

# Brings the tunnel down with wg-quick itself when the suite could not.
_zdx_vpn_smoke_force_down() {
  if [[ "$kernel" == Linux ]]; then
    command sudo -n wg-quick down "$conf" >/dev/null 2>&1
    return 0
  fi
  local -a reply=()
  _vpn_darwin_tunnel_tools 2>/dev/null || return 0
  command sudo -n "${reply[@]}" down "$conf" >/dev/null 2>&1
  return 0
}

# Writes the private test profile: no default route and no DNS line.
_zdx_vpn_smoke_profile() {
  local target="$1" local_key="" peer_key="" peer_public=""
  local_key=$(command wg genkey) && peer_key=$(command wg genkey) \
    && peer_public=$(print -r -- "$peer_key" | command wg pubkey) || return 1
  (
    umask 077
    print -r -- "[Interface]"
    print -r -- "PrivateKey = $local_key"
    print -r -- "Address = 10.123.45.2/32"
    print -r -- ""
    print -r -- "[Peer]"
    print -r -- "PublicKey = $peer_public"
    print -r -- "AllowedIPs = 10.123.45.0/24"
    print -r -- "Endpoint = 192.0.2.1:51820"
  ) > "$target" || return 1
  ! command grep -Eq '0\.0\.0\.0/0|::/0|^DNS' "$target"
}

# Runs the smoke test from a repository root. Usage: _zdx_vpn_smoke_main <root>
_zdx_vpn_smoke_main() {
  emulate -L zsh
  local root="$1"
  local profile=zdxsmoke0 profile_dir=/etc/wireguard probe=10.123.45.1
  local kernel="" canonical_dir="" conf="" work_dir="" tool="" REPLY=""
  local -i failures=0 created_dir=0 installed=0 started=0

  if [[ "${ZDX_VPN_SMOKE:-}" != 1 || "${CI:-}" != true ]]; then
    print -u2 -r -- \
      "Refusing: this test changes system networking; set ZDX_VPN_SMOKE=1 on a disposable CI runner."
    return 2
  fi
  if ! command sudo -n true 2>/dev/null; then
    print -u2 -r -- "Refusing: passwordless sudo is required."
    return 2
  fi
  kernel=$(command uname -s)
  if [[ "$kernel" != (Linux|Darwin) ]]; then
    print -u2 -r -- "Refusing: unsupported kernel $kernel."
    return 2
  fi
  for tool in wg wg-quick; do
    if ! whence -p "$tool" >/dev/null; then
      print -u2 -r -- "Refusing: $tool is not installed."
      return 2
    fi
  done

  # Load the plugin core first, as an installed shell does, so the suite uses
  # the shared output services instead of its standalone fallbacks.
  source "$root/functions.zsh" || return 1
  source "$root/functions/vpn-menu.zsh" || return 1
  export VPN_CONFIG_DIR="$profile_dir" NO_COLOR=1
  # macOS reaches /etc through the root-owned /etc -> private/etc alias.
  if ! _vpn_config_dir_canonical "$profile_dir"; then
    print -u2 -r -- "Refusing: $profile_dir does not resolve to a trusted directory."
    return 2
  fi
  canonical_dir="$REPLY"
  conf="$canonical_dir/$profile.conf"
  if command sudo -n test -e "$conf"; then
    print -u2 -r -- "Refusing: $conf already exists."
    return 2
  fi

  {
    work_dir=$(umask 077; command mktemp -d "${TMPDIR:-/tmp}/zdx-vpn-smoke.XXXXXX") \
      || { _zdx_vpn_smoke_fail "Could not create a private work directory."; return 1; }
    _zdx_vpn_smoke_profile "$work_dir/$profile.conf" || {
      _zdx_vpn_smoke_fail "Could not write a private profile without a default route or DNS."
      return 1
    }

    # The suite installs profiles through these same primitives;
    # vpn-profile-import needs a terminal for its name prompt.
    if ! command sudo -n test -d "$canonical_dir"; then
      command sudo -n install -d -m 700 -o 0 -g 0 -- "$canonical_dir" \
        || { _zdx_vpn_smoke_fail "Could not create $canonical_dir."; return 1; }
      created_dir=1
    fi
    command sudo -n install -m 600 -o 0 -g 0 -- "$work_dir/$profile.conf" "$conf" \
      || { _zdx_vpn_smoke_fail "Could not install $conf."; return 1; }
    installed=1
    _zdx_vpn_smoke_pass "Installed $conf (root, mode 600)."

    _zdx_vpn_smoke_note "Connecting through the suite: vpn-menu vpn-on $profile"
    started=1
    if vpn-menu vpn-on "$profile"; then
      _zdx_vpn_smoke_check_up
      vpn-menu vpn-summary || _zdx_vpn_smoke_fail "vpn-summary failed."
      vpn-menu vpn-details || _zdx_vpn_smoke_fail "vpn-details failed."
    else
      _zdx_vpn_smoke_fail "vpn-on $profile failed."
    fi

    _zdx_vpn_smoke_note "Disconnecting through the suite: vpn-menu vpn-off $profile"
    if vpn-menu vpn-off "$profile"; then
      _zdx_vpn_smoke_check_down && started=0
    else
      _zdx_vpn_smoke_fail "vpn-off $profile failed."
    fi
  } always {
    # Cleanup runs on success, failure, and interruption.
    if (( started )); then
      _zdx_vpn_smoke_note "Forcing the test tunnel down with wg-quick."
      _zdx_vpn_smoke_force_down
    fi
    if (( installed )); then
      command sudo -n rm -f -- "$conf" \
        || _zdx_vpn_smoke_fail "Could not remove $conf."
    fi
    if (( created_dir )); then
      command sudo -n rmdir -- "$canonical_dir" 2>/dev/null || true
    fi
    if [[ -n "$work_dir" && -d "$work_dir" ]]; then
      command rm -rf -- "$work_dir"
    fi
  }

  if (( failures > 0 )); then
    local noun=checks
    (( failures == 1 )) && noun=check
    print -u2 -r -- "✘ VPN smoke failed: $failures $noun failed."
    return 1
  fi
  print -u2 -r -- "✔ VPN smoke passed on $kernel."
  return 0
}

typeset -g _ZDX_VPN_SMOKE_SOURCED=1
# Run only when executed: a sourced file sees "toplevel:file" here.
if [[ "${ZSH_EVAL_CONTEXT:-}" == toplevel ]]; then
  (( $# == 0 )) || {
    print -u2 -r -- 'Usage: ZDX_VPN_SMOKE=1 zsh -f .github/scripts/vpn-smoke.zsh'
    exit 2
  }
  trap 'exit 130' INT
  trap 'exit 143' TERM
  _zdx_vpn_smoke_main "${0:A:h:h:h}"
  exit $?
fi
