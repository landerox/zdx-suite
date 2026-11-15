#!/usr/bin/env bats
# Literal Zsh programs and independently collected matrix cells are intentional.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  load vpn_test_helper
  vpn_pin_kernel Linux
  unset WSL_DISTRO_NAME WSL_INTEROP SUDO_EDITOR VISUAL EDITOR
  export VPN_PROFILE_DIR="$HOME/profiles" VPN_CONFIG_DIR="$HOME/profiles"
  export VPN_CACHE_DIR="$HOME/.cache/zdx/vpn" VPN_MENU_REPORT_DIR="$HOME/reports"
  export F510_ROOT="$HOME/f510" F510_PAYLOAD='' F510_FZF_RC=0 F510_SUDO_MODE='' F510_CHECK_FOREGROUND=0
  mkdir -m 700 "$F510_ROOT" || return 1
  local profile
  for profile in wg0 wg1 wg9; do
    vpn_darwin_profile "$VPN_PROFILE_DIR" "$profile" || return 1
    cp "$VPN_PROFILE_DIR/$profile.conf" "$VPN_PROFILE_DIR/$profile.conf.bak-vpn-menu" || return 1
    chmod -- 600 "$VPN_PROFILE_DIR/$profile.conf.bak-vpn-menu" || return 1
  done
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/fzf" || return 1
  cat >> "$TEST_MOCK_BIN/fzf" <<'MOCK'
printf '%s\n' "$0" > "$F510_CASE/selected.program"
printf '%s\0' "$@" > "$F510_CASE/fzf.argv.nul"
cat > "$F510_CASE/offered"
stdout_kind=other
if [[ -p /dev/stdout ]]; then stdout_kind=pipe
elif [[ -f /dev/stdout ]]; then stdout_kind=file; fi
printf '%s\n' "$stdout_kind" > "$F510_CASE/stdout.kind"
if [[ "$F510_CHECK_FOREGROUND" == 1 ]]; then
  current_pgid=$(ps -o pgid= -p "$$" | tr -d '[:space:]')
  terminal_pgid=$(ps -o tpgid= -p "$$" | tr -d '[:space:]')
  printf '%s|%s\n' "$current_pgid" "$terminal_pgid" > "$F510_CASE/process.groups"
  if [[ -z "$current_pgid" || "$current_pgid" != "$terminal_pgid" ]]; then
    printf '97\n' > "$F510_CASE/producer.actual"
    exit 97
  fi
fi
printf '%s' "$F510_PAYLOAD"
printf '%s\n' "$F510_FZF_RC" > "$F510_CASE/producer.actual"
exit "$F510_FZF_RC"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/fzf" || return 1
  cp "$TEST_MOCK_BIN/sudo" "$F510_ROOT/sandbox-sudo" || return 1
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/sudo" || return 1
  cat >> "$TEST_MOCK_BIN/sudo" <<'MOCK'
printf '%s\0' "$@" >> "$F510_CASE/sudo.argv.nul"
if [[ "$F510_SUDO_MODE" == privilege ]]; then
  if (( $# == 2 )) && [[ "$1" == -n && "$2" == true ]]; then
    [[ "$F510_ACCESS" == warm || -f "$F510_CASE/authenticated" ]]; rc=$?
  elif (( $# == 1 )) && [[ "$1" == -v ]]; then
    : > "$F510_CASE/authenticated"; rc=0
  else
    rc=97
  fi
elif [[ "$F510_SUDO_MODE" == editor ]]; then
  if (( $# == 2 )) && [[ "$1" == -n && "$2" == true ]]; then rc=0
  elif (( $# == 4 )) && [[ "$1" == -n && "$2" == -e && "$3" == -- \
    && "$4" == "$VPN_PROFILE_DIR/wg0.conf" ]]; then
    printf 'EDITOR-STDOUT\n'; printf 'EDITOR-STDERR\n' >&2
    printf '%s\n' "$F510_EDITOR_RC" > "$F510_CASE/editor.actual"
    rc="$F510_EDITOR_RC"
  else rc=97; fi
else
  "$F510_ROOT/sandbox-sudo" "$@"; rc=$?
fi
printf '%s\n' "$rc" >> "$F510_CASE/sudo.producer.statuses"
exit "$rc"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/sudo" || return 1
}

teardown() {
  cleanup_sandbox
}

# Capture the public/private primary separately from the finite wrapper. Every
# caller collects all cells before asserting, so a red cannot conceal its tail.
f510_observe() {
  local name="$1" program="$2" child="${3-}" wrapper_rc=0
  export F510_CASE="$F510_ROOT/$name"
  mkdir -m 700 "$F510_CASE" || return 1
  mkdir "$F510_CASE/profiles.before" "$F510_CASE/profiles.after" || return 1
  cp -p "$VPN_PROFILE_DIR/"* "$F510_CASE/profiles.before/" || return 1
  file_stat "$VPN_PROFILE_DIR/wg0.conf" device inode uid gid mode > "$F510_CASE/profile.identity.before" || return 1
  printf '%s\n' "$program" > "$F510_CASE/action.zsh" || return 1
  if [[ -n "$child" ]]; then printf '%s\n' "$child" > "$F510_CASE/child.zsh" || return 1; fi
  if run_zsh '
    _vpn_is_wsl() { return 1; }
    REPLY=stale
    # The existing isolated VPN zpty procedure, confined to this named child.
    _f510_run_pty() {
      zmodload zsh/zpty || return 80
      zmodload zsh/datetime || return 79
      zpty -b f510-pty zsh -dfi "$F510_CASE/child.zsh" || return 81
      {
        local -F deadline=$(( EPOCHREALTIME + 30 ))
        local chunk="" transcript=""
        while [[ ! -s "$F510_CASE/child.status" ]] && (( EPOCHREALTIME < deadline )); do
          if zpty -r -t f510-pty chunk 2>/dev/null; then transcript+="$chunk"; fi
          command sleep 0.01
        done
        while zpty -r -t f510-pty chunk 2>/dev/null; do transcript+="$chunk"; done
        print -rn -- "$transcript" > "$F510_CASE/pty.transcript" || return 82
        [[ -s "$F510_CASE/child.status" ]] || return 83
        local child_rc="$(<"$F510_CASE/child.status")"
        [[ "$child_rc" == <-> ]] || return 84
        return "$child_rc"
      } always {
        zpty -d f510-pty 2>/dev/null || true
      }
    }
    _f510_action() { builtin source "$F510_CASE/action.zsh"; }
    local -i primary_rc=0
    _f510_action > "$F510_CASE/stdout" 2> "$F510_CASE/stderr" || primary_rc=$?
    print -r -- "$primary_rc" > "$F510_CASE/primary.status" || return 98
    print -rn -- "$REPLY" > "$F510_CASE/reply" || return 98
    return 0
  ' > "$F510_CASE/wrapper.stdout" 2> "$F510_CASE/wrapper.stderr"; then
    wrapper_rc=0
  else
    wrapper_rc=$?
  fi
  printf '%s\n' "$wrapper_rc" > "$F510_CASE/wrapper.status" || return 1
  cp -p "$VPN_PROFILE_DIR/"* "$F510_CASE/profiles.after/" || return 1
  file_stat "$VPN_PROFILE_DIR/wg0.conf" device inode uid gid mode > "$F510_CASE/profile.identity.after" || return 1
}

f510_primary() {
  local dir="$1" wanted="$2" file
  for file in primary.status stdout stderr wrapper.status wrapper.stdout wrapper.stderr reply; do
    [[ -f "$dir/$file" && ! -L "$dir/$file" ]] || return 31
  done
  printf '%s\n' "$wanted" > "$dir/expected.status" || return 32
  cmp "$dir/expected.status" "$dir/primary.status" || return 33
  printf '0\n' > "$dir/expected.wrapper" || return 34
  cmp "$dir/expected.wrapper" "$dir/wrapper.status" || return 35
  [[ ! -s "$dir/wrapper.stdout" && ! -s "$dir/wrapper.stderr" ]] || return 36
}

f510_picker_receipt() {
  local dir="$1" wanted="$2" raw="$3"
  f510_primary "$dir" "$wanted" || return $?
  [[ -f "$dir/producer.actual" && -f "$dir/selected.program" \
    && -f "$dir/fzf.argv.nul" && -s "$dir/offered" && -f "$dir/stdout.kind" ]] || return 41
  printf '%s\n' "$TEST_MOCK_BIN/fzf" > "$dir/expected.program" || return 42
  cmp "$dir/expected.program" "$dir/selected.program" || return 43
  [[ ! -s "$dir/stdout" ]] || return 44
  printf '%s\n' "$raw" > "$dir/expected.producer" || return 45
  cmp "$dir/expected.producer" "$dir/producer.actual" || return 46
}

f510_profiles_unchanged() {
  local dir="$1" before name
  local -a originals=("$dir"/profiles.before/*) current=("$dir"/profiles.after/*)
  [[ "${#originals[@]}" == 6 && "${#current[@]}" == 6 ]] || return 47
  cmp "$dir/profile.identity.before" "$dir/profile.identity.after" || return 48
  for before in "${originals[@]}"; do
    name="${before##*/}"
    [[ -f "$before" && -f "$dir/profiles.after/$name" ]] || return 49
    cmp "$before" "$dir/profiles.after/$name" || return 50
  done
}

f510_picker_unreached() {
  local dir="$1" file
  f510_primary "$dir" 1 || return $?
  for file in selected.program fzf.argv.nul offered stdout.kind producer.actual target; do
    [[ ! -e "$dir/$file" && ! -L "$dir/$file" ]] || return 57
  done
  [[ ! -s "$dir/stdout" && ! -s "$dir/reply" ]] || return 58
}

@test "vpn CLI picker: directory decisions distinguish decline errors and returned interruptions" {
  local command_name code name
  for command_name in vpn-profile-create vpn-profile-import; do
    for code in 1 2 3 17 130 143; do
      name="directory-$command_name-$code"
      export F510_COMMAND="$command_name" F510_CONFIRM_RC="$code"
      f510_observe "$name" '
        export VPN_CONFIG_DIR="$F510_CASE/missing"
        _vpn_confirm_ask() {
          print -r -- "$*" > "$F510_CASE/question"
          print -r -- "$F510_CONFIRM_RC" > "$F510_CASE/confirm.actual"
          return "$F510_CONFIRM_RC"
        }
        _vpn_profile_install() { print unexpected > "$F510_CASE/install"; return 97; }
        if [[ "$F510_COMMAND" == vpn-profile-import ]]; then
          "$F510_COMMAND" "$VPN_PROFILE_DIR/wg0.conf"
        else
          "$F510_COMMAND" wg0
        fi
      ' || return 1
    done
  done
  local expected
  for command_name in vpn-profile-create vpn-profile-import; do
    for code in 1 2 3 17 130 143; do
      name="$F510_ROOT/directory-$command_name-$code"
      case "$code" in 1) expected=0 ;; 130|143) expected="$code" ;; *) expected=1 ;; esac
      f510_primary "$name" "$expected" || return $?
      f510_profiles_unchanged "$name" || return $?
      [[ -s "$name/question" && ! -s "$name/stdout" && ! -e "$name/missing" && ! -e "$name/install" ]] || return 51
      printf '%s\n' "$code" > "$name/expected.confirm" || return 52
      cmp "$name/expected.confirm" "$name/confirm.actual" || return 53
      if [[ "$code" == 1 ]]; then
        grep -Fq 'Cancelled.' "$name/stderr" || return 54
      else
        [[ "$(cat "$name/stderr")" != *Cancelled* ]] || return 55
      fi
    done
  done
  [[ ! -s "$MOCK_SUDO_LOG" ]] || return 56
}

@test "vpn CLI picker: missing-terminal advice offers no rejected yes flag" {
  local command_name route name
  for command_name in vpn-profile-create vpn-profile-import; do
    export F510_COMMAND="$command_name"
    f510_observe "unavailable-$command_name" '
      export VPN_CONFIG_DIR="$F510_CASE/missing"
      if [[ "$F510_COMMAND" == vpn-profile-import ]]; then
        "$F510_COMMAND" "$VPN_PROFILE_DIR/wg0.conf"
      else
        "$F510_COMMAND" wg0
      fi
    ' || return 1
    for route in direct nested; do
      export F510_ROUTE="$route"
      f510_observe "yes-$route-$command_name" '
        _vpn_require_platform() { print unexpected > "$F510_CASE/runtime"; return 91; }
        if [[ "$F510_ROUTE" == nested ]]; then vpn-menu "$F510_COMMAND" --yes;
        else "$F510_COMMAND" --yes; fi
      ' || return 1
    done
  done
  for command_name in vpn-profile-create vpn-profile-import; do
    name="$F510_ROOT/unavailable-$command_name"
    f510_primary "$name" 1 || return $?
    f510_profiles_unchanged "$name" || return $?
    [[ ! -s "$name/stdout" && ! -e "$name/missing" && -s "$name/stderr" ]] || return 61
    [[ "$(cat "$name/stderr")" != *--yes* && "$(cat "$name/stderr")" != *Cancelled* ]] || return 62
    for route in direct nested; do
      name="$F510_ROOT/yes-$route-$command_name"
      f510_primary "$name" 2 || return $?
      [[ ! -e "$name/runtime" && ! -s "$name/stdout" && -s "$name/stderr" ]] || return 63
    done
  done
  [[ ! -s "$MOCK_SUDO_LOG" ]] || return 64
}

@test "vpn CLI picker: core and standalone captures validate canonical complete offered rows" {
  local mode scene payload rc
  for mode in core standalone; do
    for scene in offered trailing forged leading embedded duplicate cr space empty cancel nomatch error term failed-data unsafe-private unsafe-public; do
      rc=0
      case "$scene" in
        offered) payload=$'wg0\n' ;; trailing) payload=$'wg0\n\n\n' ;;
        forged) payload=$'wg9\n' ;; leading) payload=$'\nwg0\n' ;;
        embedded) payload=$'wg0\nwg1\n' ;; duplicate) payload=$'wg0\nwg0\n' ;;
        cr) payload=$'wg0\r\n' ;; space) payload=$' wg0\n' ;; empty) payload='' ;;
        cancel) payload=''; rc=130 ;; nomatch) payload=''; rc=1 ;;
        error) payload=''; rc=17 ;; term) payload=''; rc=143 ;;
        failed-data) payload=$'wg0\n'; rc=130 ;;
        unsafe-private|unsafe-public) payload=$'wg0\n' ;;
      esac
      export F510_MODE="$mode" F510_SCENE="$scene" F510_PAYLOAD="$payload" F510_FZF_RC="$rc"
      f510_observe "private-$mode-$scene" '
        if [[ "$F510_MODE" == standalone ]]; then unfunction _zdx_picker_capture; fi
        if [[ "$F510_SCENE" == unsafe-* ]]; then
          command mkdir -m 700 "$F510_CASE/private-target" || return 95
          command ln -s "$F510_CASE/private-target" "$F510_CASE/unsafe-root" || return 96
          export TMPDIR="$F510_CASE/unsafe-root"
        fi
        local -a capture_objects=("$TMPDIR"/zdx-vpn-fzf.??????(DN))
        print -r -- "${#capture_objects}" > "$F510_CASE/capture.before" || return 97
        local -i pick_rc=0
        if [[ "$F510_SCENE" == unsafe-public ]]; then
          _vpn_get_configs() { print -rl -- wg0 wg1; }
          _vpn_set_default_iface() { print -r -- "$1" > "$F510_CASE/target"; return 91; }
          vpn-default-set || pick_rc=$?
        else
          _vpn_pick_from_list "Fixture profiles" wg0 wg1 || pick_rc=$?
        fi
        capture_objects=("$TMPDIR"/zdx-vpn-fzf.??????(DN))
        print -r -- "${#capture_objects}" > "$F510_CASE/capture.after" || return 98
        return "$pick_rc"
      ' || return 1
    done
  done
  local name expected
  for mode in core standalone; do
    for scene in offered trailing forged leading embedded duplicate cr space empty cancel nomatch error term failed-data unsafe-private unsafe-public; do
      name="$F510_ROOT/private-$mode-$scene"
      f510_profiles_unchanged "$name" || return $?
      printf '0\n' > "$name/expected.capture" || return 69
      cmp "$name/expected.capture" "$name/capture.before" || return 70
      cmp "$name/expected.capture" "$name/capture.after" || return 71
      if [[ "$scene" == unsafe-* ]]; then
        f510_picker_unreached "$name" || return $?
        continue
      fi
      case "$scene" in offered|trailing) expected=0 ;; empty|cancel|nomatch) expected=3 ;; *) expected=1 ;; esac
      rc=0
      case "$scene" in cancel|failed-data) rc=130 ;; nomatch) rc=1 ;; error) rc=17 ;; term) rc=143 ;; esac
      f510_picker_receipt "$name" "$expected" "$rc" || return $?
      f510_profiles_unchanged "$name" || return $?
      printf 'wg0\nwg1\n' > "$name/expected.offered" || return 71
      cmp "$name/expected.offered" "$name/offered" || return 72
      printf 'file\n' > "$name/expected.kind" || return 73
      cmp "$name/expected.kind" "$name/stdout.kind" || return 74
      if [[ "$expected" == 0 ]]; then
        printf 'wg0' > "$name/expected.reply" || return 75
        cmp "$name/expected.reply" "$name/reply" || return 76
      else
        [[ ! -s "$name/reply" ]] || return 77
      fi
    done
  done
}

@test "vpn CLI picker: all seven owners reject forged cancelled and failed selections before target work" {
  local owner scene payload rc
  for owner in vpn-config-edit vpn-config-restore vpn-profile-rename vpn-profile-remove vpn-on vpn-off vpn-default-set; do
    for scene in offered forged cancel error failed-data; do
      rc=0
      case "$scene" in
        offered) payload=$'wg0\n' ;; forged) payload=$'wg9\n' ;;
        cancel) payload=''; rc=130 ;; error) payload=''; rc=17 ;;
        failed-data) payload=$'wg0\n'; rc=130 ;;
      esac
      export F510_OWNER="$owner" F510_PAYLOAD="$payload" F510_FZF_RC="$rc"
      f510_observe "owner-$owner-$scene" '
        _vpn_get_configs() { print -rl -- wg0 wg1; }
        _vpn_ensure_wg_access() { return 0; }
        _vpn_active_interfaces() { reply=(wg0 wg1); return 0; }
        _vpn_state_load() { _VPN_MENU_CONFIGS_KNOWN=1; _VPN_MENU_CONFIGS=(wg0 wg1); }
        _vpn_state_iface_backup_state() { print -r -- available; }
        _vpn_prompt_profile_name() { print -r -- wg2; }
        # A finite post-selection boundary, never a filesystem/tunnel action.
        _vpn_conf_path() { print -r -- "$1" > "$F510_CASE/target"; return 91; }
        _vpn_backup_state() { print -r -- "$1" > "$F510_CASE/target"; print -r -- unknown; }
        _vpn_tunnel_down() { print -r -- "$1" > "$F510_CASE/target"; return 91; }
        "$F510_OWNER"
      ' || return 1
    done
  done
  local name expected
  for owner in vpn-config-edit vpn-config-restore vpn-profile-rename vpn-profile-remove vpn-on vpn-off vpn-default-set; do
    for scene in offered forged cancel error failed-data; do
      name="$F510_ROOT/owner-$owner-$scene"
      expected=1
      [[ "$scene" != cancel ]] || expected=0
      [[ "$scene" != offered || "$owner" != vpn-off ]] || expected=91
      rc=0
      case "$scene" in cancel|failed-data) rc=130 ;; error) rc=17 ;; esac
      f510_picker_receipt "$name" "$expected" "$rc" || return $?
      f510_profiles_unchanged "$name" || return $?
      if [[ "$scene" == offered ]]; then
        printf 'wg0\n' > "$name/expected.target" || return 81
        cmp "$name/expected.target" "$name/target" || return 82
      else
        [[ ! -e "$name/target" ]] || return 83
      fi
    done
  done
  [[ ! -s "$MOCK_SUDO_LOG" ]] || return 84
}

@test "vpn CLI picker: empty operands fail before runtime through direct and nested routes" {
  local command_name route form
  local -a forms=()
  for command_name in vpn-config-dir vpn-access-unlock vpn-access-lock vpn-access-status vpn-summary vpn-details vpn-ip-info vpn-report vpn-reconnect-last vpn-default-connect vpn-on vpn-off vpn-default-set; do
    for route in direct nested; do
      forms=(empty extra flag trailing help-only help-extra)
      case "$command_name" in vpn-on|vpn-off|vpn-default-set) forms+=(terminated valid duplicate) ;; esac
      for form in "${forms[@]}"; do
        export F510_COMMAND="$command_name" F510_ROUTE="$route" F510_FORM="$form"
        f510_observe "grammar-$command_name-$route-$form" '
          _vpn_require_platform() { print platform > "$F510_CASE/runtime"; return 91; }
          _vpn_ensure_wg_access() { print access > "$F510_CASE/runtime"; return 91; }
          _vpn_tunnel_down() { print down > "$F510_CASE/runtime"; return 91; }
          local -a args=()
          case "$F510_FORM" in
            empty) args=("") ;; extra) args=("" extra) ;; flag) args=("" --bogus) ;;
            trailing) args=(wg0 "") ;;
            help-only) args=(--help) ;; help-extra) args=(--help extra) ;;
            terminated) args=(-- "") ;; valid) args=(wg0) ;; duplicate) args=(wg0 wg1) ;;
          esac
          if [[ "$F510_ROUTE" == nested ]]; then vpn-menu "$F510_COMMAND" "${args[@]}";
          else "$F510_COMMAND" "${args[@]}"; fi
        ' || return 1
      done
    done
  done
  local name
  for command_name in vpn-config-dir vpn-access-unlock vpn-access-lock vpn-access-status vpn-summary vpn-details vpn-ip-info vpn-report vpn-reconnect-last vpn-default-connect vpn-on vpn-off vpn-default-set; do
    for route in direct nested; do
      forms=(empty extra flag trailing help-only help-extra)
      case "$command_name" in vpn-on|vpn-off|vpn-default-set) forms+=(terminated valid duplicate) ;; esac
      for form in "${forms[@]}"; do
        name="$F510_ROOT/grammar-$command_name-$route-$form"
        local expected=2
        if [[ "$form" == help-only ]]; then expected=0; fi
        if [[ "$form" == valid ]]; then
          expected=1; [[ "$command_name" != vpn-off ]] || expected=91
        fi
        f510_primary "$name" "$expected" || return $?
        f510_profiles_unchanged "$name" || return $?
        [[ ! -s "$name/stdout" ]] || return 91
        if [[ "$form" == valid ]]; then
          [[ -s "$name/runtime" ]] || return 92
        else
          [[ ! -e "$name/runtime" && -s "$name/stderr" ]] || return 93
        fi
        [[ ! -e "$name/sudo.argv.nul" ]] || return 94
      done
    done
  done
  [[ ! -s "$MOCK_SUDO_LOG" ]] || return 92
}

@test "vpn CLI picker: default-set metadata admits observed optional authentication" {
  local fixture="$TEST_SUITE_ROOT/test/fixtures/vpn-public-commands.tsv"
  local access
  for access in direct warm cold; do
    export F510_ACCESS="$access" F510_SUDO_MODE=privilege
    f510_observe "privilege-$access" '
      if [[ "$F510_ACCESS" != direct ]]; then
        _vpn_configs_access_state() {
          if _vpn_have_sudo_cache; then print -r -- sudo; else print -r -- locked; fi
        }
      fi
      vpn-default-set wg0
      local -i public_rc=$?
      local pointer=""
      pointer=$(_vpn_read_default_iface) || return 97
      print -r -- "$pointer" > "$F510_CASE/pointer"
      return "$public_rc"
    ' || return 1
  done
  local command_name module risk privilege extra count=0 selected=0
  local -A seen=()
  while IFS=$'\t' read -r command_name module risk privilege extra; do
    [[ -z "$command_name" || "$command_name" == \#* ]] && continue
    (( count += 1 ))
    [[ -z "$extra" && "$command_name" =~ ^vpn-[a-z0-9-]+$ ]] || return 101
    [[ ! "${seen[$command_name]+present}" ]] || return 101
    seen[$command_name]=1
    if [[ "$command_name" == vpn-default-set ]]; then
      (( selected += 1 ))
      [[ "$module" == vpn-control.zsh && "$risk" == mutating && "$privilege" == privileged ]] || return 102
    fi
  done < "$fixture"
  [[ "$count" == 22 && "$selected" == 1 ]] || return 103
  for access in direct warm cold; do
    f510_primary "$F510_ROOT/privilege-$access" 0 || return $?
    f510_profiles_unchanged "$F510_ROOT/privilege-$access" || return $?
    printf 'wg0\n' > "$F510_ROOT/privilege-$access/expected.pointer" || return 104
    cmp "$F510_ROOT/privilege-$access/expected.pointer" "$F510_ROOT/privilege-$access/pointer" || return 105
    [[ ! -s "$F510_ROOT/privilege-$access/stdout" ]] || return 106
    if [[ "$access" == direct ]]; then
      [[ ! -e "$F510_ROOT/privilege-$access/sudo.argv.nul" ]] || return 107
    elif [[ "$access" == warm ]]; then
      [[ ! -e "$F510_ROOT/privilege-$access/authenticated" ]] || return 108
      [[ -s "$F510_ROOT/privilege-$access/sudo.argv.nul" ]] || return 109
    else
      [[ -f "$F510_ROOT/privilege-$access/authenticated" ]] || return 110
      grep -Fq 'Loading VPN profiles requires sudo authentication.' "$F510_ROOT/privilege-$access/stderr" || return 111
    fi
  done
}

@test "vpn CLI picker: all editor branches keep both channels on UI stderr" {
  local mode code before
  before=$(sha256_file "$VPN_PROFILE_DIR/wg0.conf") || return 1
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/sudoedit" || return 1
  cat >> "$TEST_MOCK_BIN/sudoedit" <<'MOCK'
[[ "$#" == 3 && "$1" == -n && "$2" == -- && "$3" == "$VPN_PROFILE_DIR/wg0.conf" ]] || exit 97
printf '%s\0' "$@" > "$F510_CASE/editor.argv.nul"
printf '%s\n' "$0" > "$F510_CASE/editor.program"
printf 'EDITOR-STDOUT\n'; printf 'EDITOR-STDERR\n' >&2
printf '%s\n' "$F510_EDITOR_RC" > "$F510_CASE/editor.actual"
exit "$F510_EDITOR_RC"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/sudoedit" || return 1
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/fixture-editor" || return 1
  cat >> "$TEST_MOCK_BIN/fixture-editor" <<'MOCK'
[[ "$#" == 1 && "$1" == "$TMPDIR/"* && -f "$1" && ! -L "$1" ]] || exit 97
printf '%s\0' "$@" > "$F510_CASE/editor.argv.nul"
printf '%s\n' "$0" > "$F510_CASE/editor.program"
printf 'EDITOR-STDOUT\n'; printf 'EDITOR-STDERR\n' >&2
printf '%s\n' "$F510_EDITOR_RC" > "$F510_CASE/editor.actual"
exit "$F510_EDITOR_RC"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/fixture-editor" || return 1
  local child='emulate -R zsh
    source "$ZSH_CUSTOM/functions.zsh" || exit 91
    _vpn_is_wsl() { return 1; }
    _vpn_require_platform() { return 0; }
    _vpn_platform_is() { [[ "$1" == darwin ]]; }
    export EDITOR=fixture-editor
    unset SUDO_EDITOR VISUAL
    _VPN_AUTO_YES=1
    vpn-config-edit wg0 > "$F510_CASE/public.stdout" 2> "$F510_CASE/public.stderr"
    child_rc=$?
    print -r -- "$child_rc" > "$F510_CASE/child.status"
    exit "$child_rc"'
  for mode in sudoedit sudo-e staged; do
    for code in 0 17; do
      export F510_EDITOR_MODE="$mode" F510_EDITOR_RC="$code" F510_SUDO_MODE=editor
      f510_observe "editor-$mode-$code" '
        if [[ "$F510_EDITOR_MODE" == staged ]]; then
          _f510_run_pty
          return $?
        fi
        if [[ "$F510_EDITOR_MODE" == sudo-e ]]; then
          command() {
            if [[ "$1" == -v && "$2" == sudoedit ]]; then return 1; fi
            builtin command "$@"
          }
        fi
        _VPN_AUTO_YES=1
        vpn-config-edit wg0 > "$F510_CASE/public.stdout" 2> "$F510_CASE/public.stderr"
      ' "$child" || return 1
    done
  done
  local name expected
  for mode in sudoedit sudo-e staged; do
    for code in 0 17; do
      name="$F510_ROOT/editor-$mode-$code"
      expected=0; [[ "$code" == 0 ]] || expected=1
      f510_primary "$name" "$expected" || return $?
      f510_profiles_unchanged "$name" || return $?
      [[ -f "$name/public.stdout" && ! -s "$name/public.stdout" && -s "$name/public.stderr" ]] || return 121
      grep -Fq 'EDITOR-STDOUT' "$name/public.stderr" || return 122
      grep -Fq 'EDITOR-STDERR' "$name/public.stderr" || return 123
      printf '%s\n' "$code" > "$name/expected.editor" || return 124
      cmp "$name/expected.editor" "$name/editor.actual" || return 125
      [[ "$(sha256_file "$VPN_PROFILE_DIR/wg0.conf")" == "$before" ]] || return 126
    done
  done
}

@test "vpn CLI picker: profile selection stays in its isolated terminal foreground" {
  local mode child='emulate -R zsh
    setopt MONITOR
    source "$ZSH_CUSTOM/functions.zsh" || exit 91
    _vpn_is_wsl() { return 1; }
    if [[ "$F510_MODE" == standalone ]]; then unfunction _zdx_picker_capture; fi
    _vpn_get_configs() { print -rl -- wg0 wg1; }
    vpn-default-set > "$F510_CASE/public.stdout" 2> "$F510_CASE/public.stderr"
    child_rc=$?
    print -r -- "$child_rc" > "$F510_CASE/child.status"
    exit "$child_rc"'
  export F510_CHECK_FOREGROUND=1 F510_PAYLOAD=$'wg0\n' F510_FZF_RC=0
  for mode in core standalone; do
    export F510_MODE="$mode"
    f510_observe "foreground-$mode" '_f510_run_pty' "$child" || return 1
  done
  local name groups current terminal
  for mode in core standalone; do
    name="$F510_ROOT/foreground-$mode"
    f510_picker_receipt "$name" 0 0 || return $?
    f510_profiles_unchanged "$name" || return $?
    [[ ! -s "$name/public.stdout" && -s "$name/public.stderr" ]] || return 131
    [[ -f "$name/process.groups" ]] || return 132
    groups=$(cat "$name/process.groups") || return 133
    current="${groups%%|*}"; terminal="${groups##*|}"
    [[ "$current" =~ ^[0-9]+$ && "$current" == "$terminal" ]] || return 134
    printf 'file\n' > "$name/expected.kind" || return 135
    cmp "$name/expected.kind" "$name/stdout.kind" || return 136
  done
}
