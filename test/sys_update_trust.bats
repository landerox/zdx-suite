#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  load test_helper
  mkdir -p "$HOME/brew/bin" "$HOME/.cargo/bin" \
    "$HOME/brew/Cellar/awscli/2.20.0/bin" "$HOME/brew/Cellar/starship/1.20.0/bin"
  export TRUST_OWNER=homebrew
  export TRUST_PROBE_FAIL=0
  export TRUST_MUTATION_RC=0
  cat >"$TEST_MOCK_BIN/brew" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  --version) printf 'Homebrew 4.5.0\n' ;;
  --prefix) printf '%s\n' "${TRUST_PREFIX:-$HOME/brew}" ;;
  'list awscli'|'list starship') [[ "$TRUST_OWNER" == homebrew ]] ;;
  'outdated --quiet') : ;;
  'autoremove --dry-run'|'cleanup --dry-run') printf 'advisory: %s\n' "$*" ;;
  update|'upgrade --no-ask'|'upgrade --no-ask awscli'|'upgrade --no-ask starship'|autoremove|cleanup)
    printf 'brew %s\n' "$*" >>"$HOME/mutations"; exit "$TRUST_MUTATION_RC" ;;
  *) printf 'unexpected brew argv: %s\n' "$*" >&2; exit 91 ;;
esac
MOCK
  cat >"$TEST_MOCK_BIN/cargo" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  --version) printf 'cargo 1.80.0\n' ;;
  'install --list') [[ "$TRUST_OWNER" == cargo ]] && printf 'starship v1.20.0:\n' ;;
  'install --locked starship') printf 'cargo %s\n' "$*" >>"$HOME/mutations"; exit "$TRUST_MUTATION_RC" ;;
  *) exit 92 ;;
esac
MOCK
  cat >"$HOME/brew/Cellar/awscli/2.20.0/bin/aws" <<'MOCK'
#!/usr/bin/env bash
[[ "$*" == --version ]] || exit 93
[[ "$TRUST_PROBE_FAIL" == 0 ]] || exit 1
printf 'aws-cli/2.20.0 Python/3.12.0\n'
MOCK
  cat >"$HOME/brew/Cellar/starship/1.20.0/bin/starship" <<'MOCK'
#!/usr/bin/env bash
[[ "$*" == --version ]] || exit 94
[[ "$TRUST_PROBE_FAIL" == 0 ]] || exit 1
printf 'starship 1.20.0\n'
MOCK
  ln -s ../Cellar/awscli/2.20.0/bin/aws "$HOME/brew/bin/aws"
  ln -s ../Cellar/starship/1.20.0/bin/starship "$HOME/brew/bin/starship"
  chmod -- 755 "$TEST_MOCK_BIN/brew" "$TEST_MOCK_BIN/cargo" \
    "$HOME/brew/bin/aws" "$HOME/brew/bin/starship"
  ln -s "$HOME/brew/bin/aws" "$TEST_MOCK_BIN/aws"
  ln -s "$HOME/brew/bin/starship" "$TEST_MOCK_BIN/starship"
  local denied
  for denied in snap curl wget; do
    printf '#!/usr/bin/env bash\nexit 97\n' >"$TEST_MOCK_BIN/$denied"
    chmod -- 755 "$TEST_MOCK_BIN/$denied"
  done
}

teardown() { cleanup_sandbox; }

run_trust_zsh() {
  run_zsh '
    source "$ZSH_CUSTOM/functions/sys-menu.zsh" || return 98
    _SYS_CAPABILITIES=(os linux environment native package_manager brew privilege direct)
    _SYS_CAPABILITIES_READY=1
    _sys_capabilities_refresh() { return 0; }
  '"$1"
}

@test "sys trust: aggregate risk predicate matches every current fixture row" {
  run run_trust_zsh '
    sys-menu --help >/dev/null 2>&1
    local name module risk owner actual
    while IFS=$'"'"'\t'"'"' read -r name module risk owner; do
      [[ "$name" == \#* || -z "$name" ]] && continue
      actual=mutating
      _sys_update_step_remote_code "$name" && actual=remote-code
      if [[ "$risk" == remote-code || "$actual" == remote-code ]]; then
        [[ "$risk" == "$actual" ]] || { print -r -- "$name:$risk:$actual"; return 1; }
      fi
    done <"$ZSH_CUSTOM/test/fixtures/sys-public-commands.tsv"
  '
  [ "$status" -eq 0 ]
}

@test "sys trust: aggregate forwards authorization to all three reviewed owners" {
  run run_trust_zsh '
    sys-menu --help >/dev/null 2>&1
    update-brew() { print -r -- "brew:$*"; }
    update-awscli() { print -r -- "aws:$*"; }
    update-starship() { print -r -- "starship:$*"; }
    local name
    for name in update-brew update-awscli update-starship; do
      _sys_run_update_step "$name" 1 0 0 || return
    done
  '
  [ "$status" -eq 0 ]
  [ "$output" = $'brew:--yes\naws:--yes\nstarship:--yes' ]
}

@test "sys trust: aggregate sends passive previews to all three reviewed owners" {
  run run_trust_zsh '
    sys-menu --help >/dev/null 2>&1
    _sys_step_exec() { print -r -- "$*" >>"$HOME/previews"; reply=(planned "" 0); }
    _sys_update_run_previews 0 0 0 "Brew;update-brew" "AWS;update-awscli" "Starship;update-starship"
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/previews")" = $'update-brew --dry-run\nupdate-awscli --dry-run\nupdate-starship --dry-run' ]
}

@test "sys trust: Homebrew refuses mutation without a terminal or yes" {
  run run_trust_zsh 'update-brew'
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/mutations" ]
}

@test "sys trust: AWS refuses mutation without a terminal or yes" {
  run run_trust_zsh 'update-awscli'
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/mutations" ]
}

@test "sys trust: Starship refuses mutation without a terminal or yes" {
  run run_trust_zsh 'update-starship'
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/mutations" ]
}

@test "sys trust: three owner previews are passive and describe fixed arguments" {
  run run_trust_zsh '
    update-brew --dry-run || return
    update-awscli --dry-run || return
    update-starship --dry-run
  '
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/mutations" ]
  [[ "$output" == *"upgrade --no-ask awscli"* ]]
  [[ "$output" == *"upgrade --no-ask starship"* ]]
  [[ "$output" == *"autoremove"* && "$output" == *"cleanup"* ]]
}

@test "sys trust: explicit yes delegates to reviewed absolute owners" {
  run run_trust_zsh '
    update-brew --yes || return
    update-awscli --yes || return
    update-starship --yes
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/mutations")" = $'brew update\nbrew upgrade --no-ask\nbrew autoremove\nbrew cleanup\nbrew upgrade --no-ask awscli\nbrew upgrade --no-ask starship' ]
}

@test "sys trust: failed installed version probes refuse delegation" {
  export TRUST_PROBE_FAIL=1
  run run_trust_zsh '
    update-awscli --yes; local aws_rc=$?
    update-starship --yes; local starship_rc=$?
    [[ "$aws_rc" == 1 && "$starship_rc" == 1 ]]
  '
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/mutations" ]
}

@test "sys trust: changing an owner after review blocks delegation" {
  run run_trust_zsh '
    sys-menu --help >/dev/null 2>&1
    _sys_confirm_ask() { print -r -- "# changed after review" >>"$TEST_MOCK_BIN/brew"; return 0; }
    update-awscli
  '
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/mutations" ]
  [[ "$output" == *"changed"* || "$output" == *"revalidat"* ]]
}

@test "sys trust: declining a reviewed owner is a successful cancellation" {
  run run_trust_zsh '
    sys-menu --help >/dev/null 2>&1
    _sys_confirm_ask() { return 1; }
    update-starship
  '
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/mutations" ]
}

@test "sys trust: safe-only omits both installed remote-code owners and disclosure counts both" {
  run run_trust_zsh '
    _sys_step_applies() { [[ "$1" == update-starship || "$1" == update-awscli ]]; }
    update-system --safe-only --dry-run >"$HOME/safe.stdout" 2>"$HOME/safe.stderr" || return
    _sys_update_render_disclosures 0 "Starship;update-starship" "AWS;update-awscli"
  '
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/safe.stdout" ]
  [[ "$output" == *"2 steps run mutable upstream code"* ]]
  run grep -Eq -- 'Starship|AWS CLI' "$HOME/safe.stderr"
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/mutations" ]
}

@test "sys trust: Cargo-owned Starship supports passive review and explicit delegation" {
  export TRUST_OWNER=cargo
  cp "$HOME/brew/bin/starship" "$HOME/.cargo/bin/starship"
  ln -sf "$HOME/.cargo/bin/starship" "$TEST_MOCK_BIN/starship"
  run run_trust_zsh '
    update-starship --dry-run || return
    [[ ! -e "$HOME/mutations" ]] || return 96
    update-starship --yes
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"install --locked starship"* ]]
  [ "$(cat "$HOME/mutations")" = 'cargo install --locked starship' ]
}

@test "sys trust: retargeting the reviewed active binary blocks delegation" {
  cp "$HOME/brew/bin/aws" "$HOME/brew/bin/other-aws"
  run run_trust_zsh '
    _sys_confirm_ask() {
      command ln -sf "$HOME/brew/bin/other-aws" "$TEST_MOCK_BIN/aws"
      return 0
    }
    update-awscli
  '
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/mutations" ]
}

@test "sys trust: PATH substitution after review blocks an owner" {
  mkdir "$HOME/shadow"
  cp "$TEST_MOCK_BIN/brew" "$HOME/shadow/brew"
  run run_trust_zsh '
    _sys_confirm_ask() { path=("$HOME/shadow" "${path[@]}"); return 0; }
    update-awscli
  '
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/mutations" ]
}

@test "sys trust: group-writable active executables fail closed" {
  chmod -- 775 "$HOME/brew/bin/aws" "$HOME/brew/bin/starship"
  run run_trust_zsh '
    update-awscli --yes; local aws_rc=$?
    update-starship --yes; local starship_rc=$?
    [[ "$aws_rc" == 1 && "$starship_rc" == 1 ]]
  '
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/mutations" ]
}

@test "sys trust: checksum binds content even if identity observations are held equal" {
  run run_trust_zsh '
    # Isolate the checksum requirement from the independent stat checks.
    _sys_update_program_state() { REPLY=fixed-observation; }
    _sys_update_program_fingerprint "$TEST_MOCK_BIN/brew" || return
    local before="$REPLY"
    print -r -- "# changed bytes" >>"$TEST_MOCK_BIN/brew"
    _sys_update_program_fingerprint "$TEST_MOCK_BIN/brew" || return
    [[ "$REPLY" != "$before" ]]
  '
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/mutations" ]
}

@test "sys trust: missing checksum provider blocks installed delegation" {
  run run_trust_zsh '
    functions[_sys_trust_original_tool_program]=$functions[_sys_tool_program]
    _sys_tool_program() {
      [[ "$1" == sha256sum || "$1" == shasum ]] && return 1
      _sys_trust_original_tool_program "$@"
    }
    update-brew --yes
  '
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/mutations" ]
}

@test "sys trust: removal observation failure blocks Homebrew before metadata refresh" {
  run run_trust_zsh '
    functions[_sys_trust_original_probe]=$functions[_sys_run_bounded_probe]
    _sys_run_bounded_probe() {
      [[ "$*" == *"autoremove --dry-run"* ]] && return 1
      _sys_trust_original_probe "$@"
    }
    update-brew --yes
  '
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/mutations" ]
  [[ "$output" == *"autoremove preview failed"* ]]
}

@test "sys trust: confirmation interruptions preserve 130 and 143 without mutation" {
  local signal_rc
  for signal_rc in 130 143; do
    export TRUST_CONFIRM_RC="$signal_rc"
    run run_trust_zsh '
      _sys_confirm_ask() { return "$TRUST_CONFIRM_RC"; }
      update-brew; local brew_rc=$?
      update-awscli; local aws_rc=$?
      update-starship; local starship_rc=$?
      [[ "$brew_rc" == "$TRUST_CONFIRM_RC" && "$aws_rc" == "$brew_rc" && "$starship_rc" == "$brew_rc" ]]
    '
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/mutations" ]
  done
}

@test "sys trust: remote owner mutation interruptions preserve 130 and 143" {
  local signal_rc
  for signal_rc in 130 143; do
    export TRUST_MUTATION_RC="$signal_rc"
    run run_trust_zsh 'update-starship --yes'
    [ "$status" -eq "$signal_rc" ]
  done
}

@test "sys trust: new grammars reject extra input before any operational probe" {
  run run_trust_zsh '
    _sys_tool_program() { print unexpected >>"$HOME/probes"; return 98; }
    local name
    for name in update-brew update-awscli update-starship; do
      "$name" --help || return
      "$name" --help --yes; [[ $? == 2 ]] || return 97
      "$name" --unexpected; [[ $? == 2 ]] || return 96
      sys-menu "$name" --dry-run extra; [[ $? == 2 ]] || return 95
    done
  '
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/probes" ]
}

@test "sys trust: owner and version observation interruptions stop delegation" {
  local signal_rc observation
  for signal_rc in 130 143; do
    for observation in --prefix --version; do
      export TRUST_OBSERVATION_RC="$signal_rc" TRUST_OBSERVATION="$observation"
      run run_trust_zsh '
        functions[_sys_trust_original_probe]=$functions[_sys_run_bounded_probe]
        _sys_run_bounded_probe() {
          [[ "$*" == *" $TRUST_OBSERVATION" ]] && return "$TRUST_OBSERVATION_RC"
          _sys_trust_original_probe "$@"
        }
        update-awscli --yes; local aws_rc=$?
        update-starship --yes; local starship_rc=$?
        update-brew --yes; local brew_rc=$?
        [[ "$aws_rc" == "$TRUST_OBSERVATION_RC" && "$starship_rc" == "$aws_rc" && "$brew_rc" == "$aws_rc" ]]
      '
      [ "$status" -eq 0 ]
      [ ! -e "$HOME/mutations" ]
    done
  done
}

@test "sys trust: ordinary owner failures normalize to public status one" {
  export TRUST_MUTATION_RC=7
  run run_trust_zsh 'update-starship --yes'
  [ "$status" -eq 1 ]
}

@test "sys trust: Homebrew root cannot expand after authorization" {
  mkdir "$HOME/other-prefix"
  run run_trust_zsh '
    _sys_confirm_ask() { export TRUST_PREFIX="$HOME/other-prefix"; return 0; }
    update-brew
  '
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/mutations" ]
  [[ "$output" == *"prefix changed"* ]]
}

@test "sys trust: a Homebrew entrypoint changed by refresh blocks later phases" {
  run run_trust_zsh '
    functions[_sys_trust_original_timeout]=$functions[_sys_run_with_timeout]
    _sys_run_with_timeout() {
      _sys_trust_original_timeout "$@" || return $?
      if [[ "$1" == 120 && "${3:-}" == update ]]; then
        print -r -- "# refreshed entrypoint" >>"$TEST_MOCK_BIN/brew"
      fi
      return 0
    }
    update-brew --yes
  '
  [ "$status" -eq 1 ]
  [ "$(cat "$HOME/mutations")" = 'brew update' ]
  [[ "$output" == *"refusing upgrade"* ]]
}

@test "sys trust seam: an unrelated executable inside the Brew prefix never borrows a formula owner" {
  mkdir -p "$HOME/brew/share/unowned"
  cp "$HOME/brew/Cellar/awscli/2.20.0/bin/aws" "$HOME/brew/share/unowned/aws"
  cp "$HOME/brew/Cellar/starship/1.20.0/bin/starship" "$HOME/brew/share/unowned/starship"
  chmod -- 755 "$HOME/brew/share/unowned/aws" "$HOME/brew/share/unowned/starship"
  local tool command_name
  for tool in aws starship; do
    command_name=update-starship
    [ "$tool" != aws ] || command_name=update-awscli
    ln -sf "$HOME/brew/share/unowned/$tool" "$TEST_MOCK_BIN/$tool"
    export TRUST_EXTRA_COMMAND="$command_name"
    run run_trust_zsh '"$TRUST_EXTRA_COMMAND" --yes'
    [ "$status" -eq 1 ]
    [[ "$output" != *"Update Plan"* ]]
    [ ! -e "$HOME/mutations" ]
  done
}

@test "sys trust seam: successful mutation cannot report an unowned replacement or execute its version" {
  mkdir -p "$HOME/brew/share/unowned"
  local tool formula command_name
  for tool in aws starship; do
    cat >"$HOME/brew/share/unowned/$tool" <<'MOCK'
#!/usr/bin/env bash
printf 'unowned executable ran: %s\n' "$*" >>"$HOME/unowned-version-ran"
printf '9.99.0\n'
MOCK
    chmod -- 755 "$HOME/brew/share/unowned/$tool"
  done
  cat >"$TEST_MOCK_BIN/brew" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  --version) printf 'Homebrew 4.5.0\n' ;;
  --prefix) printf '%s\n' "$HOME/brew" ;;
  'list awscli'|'list starship') [[ "$TRUST_OWNER" == homebrew ]] ;;
  'upgrade --no-ask awscli'|'upgrade --no-ask starship')
    [[ "$3" == "$TRUST_EXTRA_FORMULA" ]] || exit 95
    printf 'brew %s\n' "$*" >>"$HOME/mutations.$TRUST_EXTRA_TOOL"
    ln -sf "$HOME/brew/share/unowned/$TRUST_EXTRA_TOOL" \
      "$TEST_MOCK_BIN/$TRUST_EXTRA_TOOL" || exit 96
    exit 0 ;;
  *) printf 'unexpected Brew argv: %s\n' "$*" >&2; exit 91 ;;
esac
MOCK
  chmod -- 755 "$TEST_MOCK_BIN/brew"
  for tool in aws starship; do
    formula=starship
    command_name=update-starship
    if [ "$tool" = aws ]; then
      formula=awscli
      command_name=update-awscli
    fi
    export TRUST_EXTRA_TOOL="$tool" TRUST_EXTRA_FORMULA="$formula"
    export TRUST_EXTRA_COMMAND="$command_name"
    run run_trust_zsh '"$TRUST_EXTRA_COMMAND" --yes'
    [ "$status" -eq 1 ]
    [ "$(cat "$HOME/mutations.$tool")" = "brew upgrade --no-ask $formula" ]
    [[ "$output" == *"active "*" owner could not be verified"* ]]
    [[ "$output" != *"updated through"* ]]
    [[ "$output" != *"already up to date"* ]]
    [ ! -e "$HOME/unowned-version-ran" ]
  done
}

review_changed_owner() {
  export REVIEW_COMMAND="$1" REVIEW_MANAGER="$2"
  if [[ "$REVIEW_MANAGER" == cargo ]]; then
    export TRUST_OWNER=cargo
    cp "$HOME/brew/bin/starship" "$HOME/.cargo/bin/starship"
    ln -sf "$HOME/.cargo/bin/starship" "$TEST_MOCK_BIN/starship"
  fi
  cat > "$HOME/changed-manager" <<'MOCK'
#!/usr/bin/env bash
printf 'changed manager executed: %s\n' "$*" >> "$HOME/changed-manager-ran"
case "$*" in
  --prefix) printf '%s\n' "$HOME/brew" ;;
  'list awscli'|'list starship') exit 0 ;;
  'install --list') printf 'starship v1.20.0:\n' ;;
  --version) printf 'manager 9.0.0\n' ;;
  *) exit 97 ;;
esac
MOCK
  chmod -- 755 "$HOME/changed-manager"
  run run_trust_zsh '
    _sys_confirm_ask() {
      command cp -- "$HOME/changed-manager" "$TEST_MOCK_BIN/$REVIEW_MANAGER" || return 2
      return 0
    }
    "$REVIEW_COMMAND"
  '
  printf 'observed status=%s changed-owner-calls=%s\n' "$status" \
    "$(cat "$HOME/changed-manager-ran" 2>/dev/null || printf absent)" >&2
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/mutations" ]
  [ ! -e "$HOME/changed-manager-ran" ]
}

@test "sys trust: changed Brew cannot execute post-consent ownership probes for AWS" {
  review_changed_owner update-awscli brew
}

@test "sys trust: changed Brew cannot execute post-consent ownership probes for Starship" {
  review_changed_owner update-starship brew
}

@test "sys trust: changed Cargo cannot execute post-consent ownership inventory for Starship" {
  review_changed_owner update-starship cargo
}
