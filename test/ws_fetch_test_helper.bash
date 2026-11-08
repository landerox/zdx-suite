# These protocol models execute no timeout, guardian, Git fetch or signal.
# READY is deliberately synthetic: they prove coordinator/status/IPC behavior,
# not native process-group ownership or descendant cleanup.
# NATIVE_EXIT is synthetic test data; no native monitor wait is executed.
# Extra fixture-only control readers prevent SIGPIPE in malformed-frame models.
# shellcheck disable=SC2016
run_fetch_protocol_model() {
  export WFI_CASE="$1"
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws-menu.zsh" || exit 90
    _ws_fetch_load_helpers || exit 91
    # A recorder, never a native wait. The v4 coordinator must not call it.
    wait() { print -r -- "$*" >> "$WFI_CALLER_WAIT"; return 97; }
    if [[ "$WFI_CASE" == (startfail|earlyack) ]]; then
      functions[_wfi_send]="${functions[_ws_fetch_send]}"
      _ws_fetch_send() {
        if [[ "$3" == START ]]; then
          print -r -- "${_wsf_started[$key]:-0}" > "$WFI_START_FLAG"
          [[ "$WFI_CASE" == startfail ]] && return 1
        fi
        _wfi_send "$@"
      }
    fi
    case "$WFI_CASE" in
      preflight_jobs130) _ws_fetch_jobs() { _wsf_interrupt=130; return 1; } ;;
      preflight_load143) _ws_fetch_load_helpers() { _wsf_interrupt=143; return 1; } ;;
      preflight_directory143) _ws_private_dir_create() { _wsf_interrupt=143; return 1; } ;;
      preflight_object130) _ws_fetch_object_id() { _wsf_interrupt=130; return 1; } ;;
    esac
    if [[ "$WFI_CASE" == (pairfail|pairmismatch|pairinterrupt) ]]; then
      functions[_wfi_actual_launch]="${functions[_ws_fetch_launch]}"
    fi
    if [[ "$WFI_CASE" == pairinterrupt ]]; then
      functions[_wfi_pair]="${functions[_ws_fetch_pair]}"
      _ws_fetch_pair() {
        _wfi_pair "$@" || return
        # Even a regressed launcher cannot execute the real worker here.
        _wsf_tools[zsh]=/fixture/not-a-worker
        _wsf_interrupt=143
        return 0
      }
    fi
    if [[ "$WFI_CASE" == pairfail ]]; then
      functions[_wfi_pair]="${functions[_ws_fetch_pair]}"
      _ws_fetch_pair() {
        _wfi_pair "$@" || return
        print -r -- "${_wsf_cr[$1]} ${_wsf_cw[$1]} ${_wsf_sr[$1]} ${_wsf_sw[$1]}" > "$WFI_FDS"
        _wfi_control_id="${_wsf_objects[$_wsf_dir/$1.control]}"
        _wfi_status_id="${_wsf_objects[$_wsf_dir/$1.status]}"
        return 1
      }
    fi
    if [[ "$WFI_CASE" == pairmismatch ]]; then
      sysopen() {
        local target="${@[-1]}"
        if [[ "$_wfi_swapped" == 0 && "$target" == *.control ]]; then
          command mv -- "$target" "$HOME/original-control.fifo" || return 1
          command mkfifo -m 600 -- "$target" || return 1
          _ws_fetch_object_id "$target" fifo || return 1
          _wfi_control_id="$REPLY"
          _wfi_swapped=1
          builtin sysopen "$@" || return
          print -r -- "$fd" > "$WFI_FDS"
          return 0
        fi
        builtin sysopen "$@"
      }
    fi
    if [[ "$WFI_CASE" == lost ]]; then
      functions[_wfi_read]="${functions[_ws_fetch_read]}"
      _ws_fetch_read() {
        # Inject an observation failure while keeping the actual reader open;
        # the stand-in never receives SIGPIPE in this no-signal model.
        [[ "$1" != 3 ]] && return 4
        _wfi_read "$@"
      }
    fi
    WS_FETCH_JOBS=1
    _ws_git_command() {
      local _wfi_discovery_repository=""
      if (( $# == 5 )) && [[ "$3" == -C && "$5" == remote ]]; then
        _wfi_discovery_repository="$4"
      elif (( $# == 7 )) && [[ "$3" == -c && "$4" == core.fsmonitor=false \
        && "$5" == -C && "$7" == remote ]]; then
        _wfi_discovery_repository="$6"
      else
        return 98
      fi
      print -r -- "${_wfi_discovery_repository:t}" >> "$WFI_DISCOVERY"
      case "$WFI_CASE" in
        discovery130) return 130 ;;
        discovery143) return 143 ;;
        discovery1) return 1 ;;
        empty) return 0 ;;
      esac
      print -r -- fixture-origin
    }
    functions[_wfi_native_path]="${functions[_ws_fetch_native_path]}"
    _ws_fetch_native_path() {
      if [[ "$WFI_CASE" == preflight_native130 ]]; then
        _wsf_interrupt=130
        return 1
      fi
      if [[ "$1" == (timeout|gtimeout) ]]; then
        [[ "$WFI_CASE" != nobackend ]] || return 1
        REPLY="/fixture/$1"
        [[ "$WFI_CASE" == capinterrupt ]] && _wsf_interrupt=143
        return 0
      fi
      _wfi_native_path "$@"
    }
    _ws_fetch_launch() {
      if [[ "$WFI_CASE" == (pairfail|pairmismatch|pairinterrupt) ]]; then
        _wfi_actual_launch "$@"
        local launch_result=$?
        if [[ "$WFI_CASE" == pairinterrupt ]]; then
          print -r -- "${#_wsf_active}" > "$WFI_FDS_CHECK"
        fi
        return "$launch_result"
      fi
      local key="$1" mode="$2" program="$3" repository="${4-}" descriptor=""
      print -r -- "$mode" >> "$WFI_LAUNCHED"
      local nonce="model.$key" REPLY=""
      _wsf_nonce[$key]="$nonce"
      _wsf_mode[$key]="$mode"
      _ws_fetch_pair "$key" || return 1
      (
        local control="${_wsf_cr[$key]}" result="${_wsf_sw[$key]}" frame="" REPLY=""
        local -a reply=()
        local -A _wsf_buffers=() _wsf_bytes=()
        local -A _wsf_read_ids=([3]="${_wsf_objects[$_wsf_dir/$key.control]}")
        local -A _wsf_write_ids=([4]="${_wsf_objects[$_wsf_dir/$key.status]}")
        local -i tick=0 read_rc=0
        exec 3<&$control 4>&$result
        for descriptor in "${(@v)_wsf_cr}" "${(@v)_wsf_cw}" "${(@v)_wsf_sr}" "${(@v)_wsf_sw}" "${(@v)_wsf_gr}" "${(@v)_wsf_gw}"; do
          (( descriptor >= 10 )) && exec {descriptor}>&-
        done
        if [[ "$mode" == capability ]]; then
          case "$WFI_CASE" in
            capearlyack)
              _ws_fetch_send 4 "$nonce" NATIVE_EXIT 0
              _ws_fetch_send 4 "$nonce" CAPABILITY 0
              exit 0 ;;
            cap130|cap143)
              _ws_fetch_send 4 "$nonce" OWNER_INTERRUPT "${WFI_CASE#cap}"
              _ws_fetch_send 4 "$nonce" NATIVE_EXIT "${WFI_CASE#cap}"
              exit 0 ;;
            captimeout|capoverflow|cap127)
              _ws_fetch_send 4 "$nonce" OWNER_ERROR 1
              [[ "$WFI_CASE" == cap127 ]] && read_rc=127 || read_rc=137
              _ws_fetch_send 4 "$nonce" NATIVE_EXIT "$read_rc"
              exit 0 ;;
            capmissing) _ws_fetch_send 4 "$nonce" NATIVE_EXIT 0; exit 0 ;;
            capunavailable)
              if [[ "${program:t}" == timeout ]]; then
                _ws_fetch_send 4 "$nonce" CAPABILITY 1
                _ws_fetch_send 4 "$nonce" NATIVE_EXIT 1
                exit 0
              fi ;;
          esac
          _ws_fetch_send 4 "$nonce" CAPABILITY 0 || exit 91
          [[ "$WFI_CASE" == capfailed ]] && read_rc=1 || read_rc=0
          _ws_fetch_send 4 "$nonce" NATIVE_EXIT "$read_rc"
          exit 0
        fi
        if [[ "${repository:t}" == first && "$WFI_CASE" == nochild ]]; then
          _ws_fetch_send 4 "$nonce" OWNER_INTERRUPT 130
          _ws_fetch_send 4 "$nonce" NO_CHILD 1
          exit 0
        fi
        _ws_fetch_send 4 "$nonce" MONITOR 314159 || exit 92
        _ws_fetch_send 4 "$nonce" BOOT 0 || exit 92
        for frame in BIND START; do
          tick=0
          while (( tick++ < 200 )); do
            read_rc=0; _ws_fetch_read 3 || read_rc=$?
            if (( read_rc == 0 )); then
              _ws_fetch_decode "$nonce" "$REPLY" || exit 93
              if [[ "${reply[1]}" == CANCEL ]]; then
                [[ "${reply[2]}" == (130|143) ]] \
                  && _ws_fetch_send 4 "$nonce" CANCELLED "${reply[2]}"
                [[ "${reply[2]}" == 1 ]] && _ws_fetch_send 4 "$nonce" ERROR 1
                [[ "$WFI_CASE" == startfail ]] && read_rc=1 || read_rc=137
                _ws_fetch_send 4 "$nonce" NATIVE_EXIT "$read_rc"
                exit 0
              fi
              [[ "${reply[1]}" == "$frame" ]] || exit 94
              if [[ "$frame" == BIND ]]; then
                print -r -- "${reply[2]}" >> "$WFI_BIND_LOG"
                [[ "${reply[2]}" == 314159 ]] || exit 98
              fi
              break
            fi
            (( read_rc == 1 )) || exit 95
            zselect -t 1 2>/dev/null || true
          done
          (( tick <= 200 )) || exit 96
          if [[ "$frame" == BIND ]]; then
            if [[ "$WFI_CASE" == (queryps130|queryps143) ]]; then
              _ws_fetch_send 4 "$nonce" QUERY_INTERRUPT "${WFI_CASE#queryps}"
              _ws_fetch_send 4 "$nonce" ERROR 1
              _ws_fetch_send 4 "$nonce" NATIVE_EXIT 1
              exit 0
            fi
            if [[ "$WFI_CASE" == prestart ]]; then
              _ws_fetch_send 4 "$nonce" OWNER_INTERRUPT 143
              _ws_fetch_send 4 "$nonce" NATIVE_EXIT 1
              exit 0
            fi
            [[ "$WFI_CASE" == earlyack ]] && _ws_fetch_send 4 "$nonce" NATIVE_EXIT 137
            _ws_fetch_send 4 "$nonce" READY 0
          fi
        done
        print -r -- "${repository:t}" >> "$WFI_LOG"
        if [[ "${repository:t}" == first ]]; then
          case "$WFI_CASE" in
            130|143|1) _ws_fetch_send 4 "$nonce" RESULT "$WFI_CASE" ;;
            deadline) _ws_fetch_send 4 "$nonce" DEADLINE 124 ;;
            missing) exit 0 ;;
            malformed) syswrite -o 4 "$nonce BAD 0"$'\''\n'\'' ;;
            duplicate)
              _ws_fetch_send 4 "$nonce" RESULT 0
              _ws_fetch_send 4 "$nonce" RESULT 0
              ;;
            duplicatecancel)
              _ws_fetch_send 4 "$nonce" RESULT 0
              _ws_fetch_send 4 "$nonce" CANCELLED 143
              ;;
            badteardown)
              _ws_fetch_send 4 "$nonce" RESULT 0
              _ws_fetch_send 4 "$nonce" NATIVE_EXIT 1
              exit 0
              ;;
            *) _ws_fetch_send 4 "$nonce" RESULT 0 ;;
          esac
        else
          _ws_fetch_send 4 "$nonce" RESULT 0
        fi
        if [[ "$WFI_CASE" == ownererror ]]; then _ws_fetch_send 4 "$nonce" OWNER_ERROR 1; fi
        if [[ "$WFI_CASE" == ownerint ]]; then _ws_fetch_send 4 "$nonce" OWNER_INTERRUPT 143; fi
        [[ "$WFI_CASE" == noack ]] || _ws_fetch_send 4 "$nonce" NATIVE_EXIT 137
        exit 0
      ) </dev/null >/dev/null 2>&1 &
      # Keep one test-only read end to avoid a SIGPIPE when a deliberately
      # failed producer exits before the coordinator sends its CANCEL data.
      descriptor="${_wsf_cr[$key]}"
      exec {fixture_reader}<&$descriptor
      _wfi_readers+=("$fixture_reader")
      for descriptor in "${_wsf_cr[$key]}" "${_wsf_sw[$key]}" \
        "${_wsf_gr[$key]:--1}" "${_wsf_gw[$key]:--1}"; do
        (( descriptor >= 0 )) && exec {descriptor}>&-
      done
      _wsf_cr[$key]=-1; _wsf_sw[$key]=-1; _wsf_gr[$key]=-1; _wsf_gw[$key]=-1
      [[ "$mode" == guard ]] && _wsf_phase[$key]=owner || _wsf_phase[$key]=capability
      _wsf_active+=("$key")
    }
    local -A fetch_outcomes=()
    local _wfi_control_id="" _wfi_status_id="" descriptor="" _wfi_swapped=0
    local -a opened=() _wfi_readers=()
    local fixture_reader=""
    local -i result=0 retained=0
    _ws_status_fetch /fixture/git "$HOME/workspaces" first later
    result=$?
    print -r -- "$REPLY ${fetch_outcomes[first]-} ${fetch_outcomes[later]-}" > "$WFI_RESULT"
    if [[ "$WFI_CASE" == (pairfail|pairmismatch) ]]; then
      opened=(${=:-$(<"$WFI_FDS")})
      for descriptor in "${opened[@]}"; do
        if _ws_fetch_fd_matches "$descriptor" "$_wfi_control_id" \
          || _ws_fetch_fd_matches "$descriptor" "$_wfi_status_id"; then
          (( ++retained ))
        fi
      done
      print -r -- "$retained" > "$WFI_FDS_CHECK"
    fi
    return "$result"
  '
}

# Exercise policy callers only. Capture/read/send are literal data stand-ins:
# no query, owner process, native child, wait, ps, fetch or signal is executed.
run_query_priority_model() {
  export WFI_QUERY_MODE="$1" WFI_QUERY_STATUS="$2"
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws/ws-fetch-worker.zsh" || exit 90
    _ws_fetch_modules || exit 91
    local _wsf_nonce=nonce
    _ws_fetch_capture() {
      _wsf_query_started=1
      _wsf_query_status="$WFI_QUERY_STATUS"
      _wsf_cause=error:1
      return 1
    }
    _ws_fetch_read() { REPLY="nonce BIND 314159"; return 0; }
    _ws_fetch_send() { print -r -- "$3 $4"; }
    if [[ "$WFI_QUERY_MODE" == capability ]]; then
      _ws_fetch_capability_owner /fixture/version
    else
      _ws_fetch_guard /fixture/git /fixture/repository /fixture/ps
    fi
  '
}

# Attribute and admission models only. Pairing always fails before a physical
# lifecycle fork, including on the original source without the readonly guard.
run_fetch_environment_model() {
  export WFI_ENV_CASE="$1"
  export WFI_ENV_RESULT="$HOME/fetch-environment-result"
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws-menu.zsh" || exit 90
    () {
      local diagnostic="Read-only repository variables prevent safe --fetch."
      local original="" original_type="" carrier="" mode="" REPLY="unchanged"
      local -i rc=0 native_calls=0 directory_calls=0 pair_calls=0 launch_calls=0 discoveries=0
      local -A fetch_outcomes=() _wsf_nonce=() _wsf_mode=()
      local _wsf_dir="$HOME/not-created" _wsf_interrupt=""
      local -i _wsf_fatal=0
      case "$WFI_ENV_CASE" in
        mutable)
          local GIT_DIR="" GIT_WORK_TREE="ordinary readonly value"
          local -a GIT_CONFIG_PARAMETERS=(first " readonly " last)
          local -A GIT_NAMESPACE=([first]="ordinary" [second]="readonly")
          local -i GIT_CONFIG_COUNT=2
          original="${(t)GIT_DIR}|${(t)GIT_WORK_TREE}|${(t)GIT_CONFIG_PARAMETERS}|${(t)GIT_NAMESPACE}|${(t)GIT_CONFIG_COUNT}"
          _ws_fetch_env_clearable || exit 91
          [[ "$original" == "${(t)GIT_DIR}|${(t)GIT_WORK_TREE}|${(t)GIT_CONFIG_PARAMETERS}|${(t)GIT_NAMESPACE}|${(t)GIT_CONFIG_COUNT}" \
            && -z "$GIT_DIR" && "$GIT_WORK_TREE" == "ordinary readonly value" \
            && "${(j:|:)GIT_CONFIG_PARAMETERS}" == "first| readonly |last" \
            && "${GIT_NAMESPACE[first]}:${GIT_NAMESPACE[second]}" == ordinary:readonly \
            && "$GIT_CONFIG_COUNT" == 2 && "$REPLY" == unchanged ]] || exit 92
          ;;
        absent)
          for carrier in "${_WS_GIT_LOCAL_ENV_VARS[@]}"; do
            [[ -z "${(tP)carrier}" ]] || exit 91
          done
          _ws_fetch_env_clearable || exit 92
          for carrier in "${_WS_GIT_LOCAL_ENV_VARS[@]}"; do
            [[ -z "${(tP)carrier}" ]] || exit 93
          done
          [[ "$REPLY" == unchanged ]] || exit 94
          ;;
        allreadonly)
          for carrier in "${_WS_GIT_LOCAL_ENV_VARS[@]}"; do
            () {
              local carrier="$1"
              local -rx "$carrier=ENV_SECRET_CANARY"
              local original_type="${(tP)carrier}" original="${(P)carrier}"
              local -i rc=0
              _ws_fetch_env_clearable || rc=$?
              print -r -- "$carrier:$rc" >> "$WFI_ENV_RESULT"
              (( rc == 1 )) && [[ "${(tP)carrier}" == "$original_type" \
                && "${(P)carrier}" == "$original" ]] || return 91
            } "$carrier" || exit 92
          done
          ;;
        scalar|empty|declared|array|association|integer)
          case "$WFI_ENV_CASE" in
            scalar) local -rx GIT_DIR=ENV_SECRET_CANARY ;;
            empty) local -rx GIT_DIR="" ;;
            declared) setopt typeset_to_unset; local -r GIT_DIR ;;
            array) local -ar GIT_DIR=(first ENV_SECRET_CANARY last) ;;
            association) local -Ar GIT_CONFIG_PARAMETERS=([first]=ENV_SECRET_CANARY [second]=other) ;;
            integer) local -ir GIT_NAMESPACE=42 ;;
          esac
          case "$WFI_ENV_CASE" in
            association) carrier=GIT_CONFIG_PARAMETERS ;;
            integer) carrier=GIT_NAMESPACE ;;
            *) carrier=GIT_DIR ;;
          esac
          original_type="${(tP)carrier}"
          original="${(j:|:)${(P)carrier}}"
          if [[ "$WFI_ENV_CASE" == declared ]]; then
            (( ! ${+GIT_DIR} )) || exit 92
          fi
          _ws_fetch_env_clearable || rc=$?
          print -r -- "helper=$rc" > "$WFI_ENV_RESULT"
          (( rc == 1 )) && [[ "${(tP)carrier}" == "$original_type" \
            && "${(j:|:)${(P)carrier}}" == "$original" \
            && "$REPLY" == unchanged ]] || exit 91
          if [[ "$WFI_ENV_CASE" == declared ]]; then
            (( ! ${+GIT_DIR} )) || exit 92
          fi
          ;;
        entry|emptyremotes)
          local -rx GIT_DIR=ENV_SECRET_CANARY
          original_type="${(t)GIT_DIR}"
          _ws_git_command() {
            print -r -- remote >> "$HOME/environment-discovery"
            [[ "$WFI_ENV_CASE" == emptyremotes ]] || print -r -- fixture-origin
            return 0
          }
          _ws_fetch_native_path() { (( ++native_calls )); return 1; }
          _ws_private_dir_create() { (( ++directory_calls )); return 1; }
          _ws_fetch_launch() { (( ++launch_calls )); return 1; }
          _ws_status_fetch /fixture/git "$HOME/workspaces" first later \
            >"$HOME/environment-data" 2>"$HOME/environment-ui" || rc=$?
          print -r -- "rc=$rc native=$native_calls directory=$directory_calls launch=$launch_calls" > "$WFI_ENV_RESULT"
          [[ "${(t)GIT_DIR}" == "$original_type" && "$GIT_DIR" == ENV_SECRET_CANARY \
            && ! -s "$HOME/environment-data" ]] || exit 91
          (( native_calls == 0 && directory_calls == 0 && launch_calls == 0 )) \
            || { print -u2 -r -- "environment-entry: rc=$rc native=$native_calls directory=$directory_calls launch=$launch_calls"; exit 92; }
          if [[ "$WFI_ENV_CASE" == emptyremotes ]]; then
            (( rc == 0 )) && [[ "$(<"$HOME/environment-ui")" == *"No repository has a remote to fetch."* ]] || exit 93
          else
            (( rc == 1 )) && [[ "$(<"$HOME/environment-ui")" == *"$diagnostic"* ]] || exit 94
          fi
          [[ "$(<"$HOME/environment-ui")" != *ENV_SECRET_CANARY* \
            && "$(<"$HOME/environment-ui")" != *"Fetching "* \
            && "$(<"$HOME/environment-ui")" != *"Fetched "* \
            && "$(<"$HOME/environment-ui")" != *retained* \
            && "$(<"$HOME/environment-ui")" != *unverified* ]] || exit 95
          ;;
        launchcapability|launchguard|changed)
          if [[ "$WFI_ENV_CASE" == changed ]]; then
            _ws_fetch_env_clearable || exit 91
            _wfi_environment_callback() { typeset -grx GIT_DIR=ENV_SECRET_CANARY; }
            _wfi_environment_callback || exit 92
          else
            local -rx GIT_DIR=ENV_SECRET_CANARY
          fi
          original_type="${(t)GIT_DIR}"
          _ws_fetch_pair() { (( ++pair_calls )); return 1; }
          [[ "$WFI_ENV_CASE" == launchguard ]] && mode=guard || mode=capability
          _ws_fetch_launch job "$mode" /fixture/program /fixture/repository \
            >"$HOME/environment-data" 2>"$HOME/environment-ui" || rc=$?
          print -r -- "rc=$rc pair=$pair_calls nonce=${#_wsf_nonce} mode=${#_wsf_mode}" > "$WFI_ENV_RESULT"
          (( rc == 1 && pair_calls == 0 && ${#_wsf_nonce} == 0 && ${#_wsf_mode} == 0 )) \
            || { print -u2 -r -- "environment-launch: rc=$rc pair=$pair_calls nonce=${#_wsf_nonce} mode=${#_wsf_mode}"; exit 93; }
          [[ "${(t)GIT_DIR}" == "$original_type" && "$GIT_DIR" == ENV_SECRET_CANARY \
            && ! -s "$HOME/environment-data" \
            && "$(<"$HOME/environment-ui")" == *"$diagnostic"* \
            && "$(<"$HOME/environment-ui")" != *ENV_SECRET_CANARY* ]] || exit 94
          ;;
        *) exit 99 ;;
      esac
    }
  '
}

# Initial identity-failure models only. Directory creation is fixture setup;
# pairing always refuses before a physical lifecycle fork on every source.
run_fetch_initial_identity_model() {
  export WFI_IDENTITY_STATUS="$1"
  export WFI_IDENTITY_DIR="$HOME/unverified fetch"$'\t'"state"
  export WFI_IDENTITY_MUTATIONS="$HOME/identity-mutations"
  export WFI_IDENTITY_RESULT="$HOME/identity-result"
  mkdir -m 700 -- "$WFI_IDENTITY_DIR"
  : > "$WFI_IDENTITY_MUTATIONS"
  cat > "$TEST_MOCK_BIN/identity-mutation" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WFI_IDENTITY_MUTATIONS"
exit 99
EOF
  chmod +x "$TEST_MOCK_BIN/identity-mutation"
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws-menu.zsh" || exit 90
    _ws_fetch_load_helpers || exit 91
    () {
      local -x GIT_DIR=CALLER_IDENTITY_CANARY
      local original_type="${(t)GIT_DIR}" before_options="${(kv)options}"
      local before_traps="$(trap)" before_mask="$(umask)"
      local _wsf_interrupt=caller-state
      local -A fetch_outcomes=()
      local -i rc=0 identity_calls=0 launch_calls=0 pair_calls=0
      _ws_git_command() { print -r -- fixture-origin; }
      _ws_fetch_native_path() {
        if [[ "$1" == (rm|rmdir) ]]; then
          REPLY="$TEST_MOCK_BIN/identity-mutation"
        else
          REPLY="/fixture/$1"
        fi
      }
      _ws_private_dir_create() { reply=("$WFI_IDENTITY_DIR" fixture-unverified); }
      _ws_fetch_object_id() {
        (( ++identity_calls ))
        case "$WFI_IDENTITY_STATUS" in
          130|143) _wsf_interrupt="$WFI_IDENTITY_STATUS" ;;
        esac
        return 1
      }
      _ws_fetch_pair() { (( ++pair_calls )); return 1; }
      _ws_fetch_launch() { (( ++launch_calls )); return 1; }
      _ws_status_fetch /fixture/git "$HOME/workspaces" first \
        >"$HOME/identity-data" 2>"$HOME/identity-ui" || rc=$?
      print -r -- "rc=$rc identity=$identity_calls launch=$launch_calls pair=$pair_calls" > "$WFI_IDENTITY_RESULT"
      (( rc == WFI_IDENTITY_STATUS && identity_calls == 1 && launch_calls == 0 && pair_calls == 0 )) || exit 91
      [[ "$GIT_DIR" == CALLER_IDENTITY_CANARY && "${(t)GIT_DIR}" == "$original_type" \
        && "$_wsf_interrupt" == caller-state && "${(kv)options}" == "$before_options" \
        && "$(trap)" == "$before_traps" && "$(umask)" == "$before_mask" \
        && ! -s "$HOME/identity-data" && ! -s "$WFI_IDENTITY_MUTATIONS" ]] || exit 92
      local warning="Private fetch state could not be verified and was retained: ${(V)WFI_IDENTITY_DIR}"
      [[ "$(<"$HOME/identity-ui")" == *"$warning"* ]] \
        || { print -u2 -r -- "missing-retention-warning: rc=$rc identity=$identity_calls launch=$launch_calls pair=$pair_calls"; exit 93; }
      [[ "$(<"$HOME/identity-ui")" != *"$WFI_IDENTITY_DIR"* \
        && "$(<"$HOME/identity-ui")" != *"changed and was retained"* \
        && "$(<"$HOME/identity-ui")" != *"Fetching "* \
        && "$(<"$HOME/identity-ui")" != *"Fetched "* ]] || exit 94
    }
  '
}
