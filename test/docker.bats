#!/usr/bin/env bats

setup() {
  load test_helper

  export MOCK_DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
  export MOCK_DOCKER_INFO_COUNT="$TEST_TEMP_DIR/docker-info-count"
  export MOCK_CONTAINER_FILE="$TEST_TEMP_DIR/containers"
  export MOCK_STOPPED_FILE="$TEST_TEMP_DIR/stopped-containers"
  export MOCK_IMAGE_FILE="$TEST_TEMP_DIR/images"
  export MOCK_DANGLING_IMAGE_FILE="$TEST_TEMP_DIR/dangling-images"
  export MOCK_IMAGE_IDENTITY_FILE="$TEST_TEMP_DIR/image-identity"
  export MOCK_NETWORK_FILE="$TEST_TEMP_DIR/networks"
  export MOCK_VOLUME_FILE="$TEST_TEMP_DIR/volumes"
  export MOCK_VOLUME_IDENTITY_FILE="$TEST_TEMP_DIR/volume-identity"
  export MOCK_VOLUME_USERS_FILE="$TEST_TEMP_DIR/volume-users"
  export MOCK_COMPOSE_CONFIG_FILE="$TEST_TEMP_DIR/compose-config"
  export MOCK_DOCKER_CONTEXT="local-test"
  export MOCK_DOCKER_ENDPOINT="unix:///var/run/docker.sock"
  export MOCK_DOCKER_DAEMON_ID="daemon-one"
  export MOCK_DOCKER_DAEMON_ID_AFTER=""
  export MOCK_DOCKER_MUTATION_RC="0"
  export MOCK_FAIL_INFO="0"
  export MOCK_DOCKER_HOSTILE_STDERR="0"
  export MOCK_DOCKER_CONFIG_WARNING=""
  export MOCK_DOCKER_LOGIN_CONFIG_JSON=""
  export TMPDIR="$HOME"

  printf -v CONTAINER_ID 'a%.0s' {1..64}
  printf -v IMAGE_HEX 'b%.0s' {1..64}
  printf -v NETWORK_ID 'c%.0s' {1..64}
  export CONTAINER_ID
  export IMAGE_ID="sha256:$IMAGE_HEX"
  export NETWORK_ID

  : > "$MOCK_DOCKER_LOG"
  printf '0\n' > "$MOCK_DOCKER_INFO_COUNT"
  printf '%s|demo|exited|alpine:3.20|\n' "$CONTAINER_ID" \
    > "$MOCK_CONTAINER_FILE"
  printf '%s|demo|exited|alpine:3.20\n' "$CONTAINER_ID" \
    > "$MOCK_STOPPED_FILE"
  printf '%s|alpine|3.20|8MB|2 days ago\n' "$IMAGE_ID" \
    > "$MOCK_IMAGE_FILE"
  printf '%s\n' "$IMAGE_ID" > "$MOCK_DANGLING_IMAGE_FILE"
  printf '%s|alpine:3.20|2026-01-01T00:00:00Z|8388608|linux|amd64\n' \
    "$IMAGE_ID" > "$MOCK_IMAGE_IDENTITY_FILE"
  printf '%s|test-network|bridge|local\n' "$NETWORK_ID" \
    > "$MOCK_NETWORK_FILE"
  printf 'test-volume\n' > "$MOCK_VOLUME_FILE"
  printf '%s\n' \
    'test-volume|local|local|2026-01-01T00:00:00Z|{"team":"safe|ops"}|{}|/var/lib/docker/volumes/test-volume/_data' \
    > "$MOCK_VOLUME_IDENTITY_FILE"
  : > "$MOCK_VOLUME_USERS_FILE"
  printf 'services:\n  app:\n    image: alpine:3.20\n' \
    > "$MOCK_COMPOSE_CONFIG_FILE"
  mkdir -p "$HOME/.docker"
  chmod 700 "$HOME/.docker"

  cat > "$TEST_MOCK_BIN/docker" <<'EOF'
#!/usr/bin/env bash
set -u

{
  printf 'docker'
  printf ' %s' "$@"
  printf '\n'
} >> "$MOCK_DOCKER_LOG"

args=("$@")
docker_config=""
while [[ "${args[0]:-}" == "--context" \
  || "${args[0]:-}" == "--host" \
  || "${args[0]:-}" == "--config" ]]; do
  if [[ "${args[0]}" == "--config" ]]; then
    docker_config="${args[1]:-}"
  fi
  args=("${args[@]:2}")
done
command_name="${args[0]:-}"
subcommand="${args[1]:-}"

if [[ "${MOCK_DOCKER_HOSTILE_STDERR:-0}" == "1" ]]; then
  case "$command_name:$subcommand" in
    container:ls|image:ls|network:ls|volume:ls)
      printf '\033[31mHOSTILE_DOCKER_SECRET\033[0m\n' >&2
      ;;
  esac
fi

case "$command_name:$subcommand" in
  context:show)
    if [[ -n "${MOCK_DOCKER_CONFIG_WARNING:-}" ]]; then
      printf '%s\n' "$MOCK_DOCKER_CONFIG_WARNING" >&2
    fi
    printf '%s\n' "$MOCK_DOCKER_CONTEXT"
    exit 0
    ;;
  context:inspect)
    printf '%s\n' "$MOCK_DOCKER_ENDPOINT"
    exit 0
    ;;
  info:*)
    [[ "${MOCK_FAIL_INFO:-0}" != "1" ]] || exit 92
    count=$(<"$MOCK_DOCKER_INFO_COUNT")
    count=$((count + 1))
    printf '%s\n' "$count" > "$MOCK_DOCKER_INFO_COUNT"
    if [[ -n "${MOCK_DOCKER_DAEMON_ID_AFTER:-}" && "$count" -ge 2 ]]; then
      printf '%s\n' "$MOCK_DOCKER_DAEMON_ID_AFTER"
    else
      printf '%s\n' "$MOCK_DOCKER_DAEMON_ID"
    fi
    exit 0
    ;;
  version:*)
    printf '26.1.0\n'
    exit 0
    ;;
  container:ls)
    joined=" ${args[*]} "
    if [[ "$joined" == *" volume="* ]]; then
      cat "$MOCK_VOLUME_USERS_FILE"
    elif [[ "$joined" == *" status=created "* ]]; then
      cat "$MOCK_STOPPED_FILE"
    else
      cat "$MOCK_CONTAINER_FILE"
    fi
    exit 0
    ;;
  container:inspect)
    target="${args[${#args[@]}-1]}"
    record=$(
      awk -F '|' -v target="$target" '$1 == target { print; exit }' \
        "$MOCK_CONTAINER_FILE" "$MOCK_STOPPED_FILE"
    )
    [[ -n "$record" ]] || exit 1
    IFS='|' read -r object_id object_name object_state object_image _ \
      <<< "$record"
    printf '%s|/%s|%s|%s\n' \
      "$object_id" "$object_name" "$object_state" "$object_image"
    exit 0
    ;;
  container:logs)
    printf 'mock container log\n'
    exit 0
    ;;
  container:start|container:stop|container:rm|container:exec)
    exit "${MOCK_DOCKER_MUTATION_RC:-0}"
    ;;
  image:ls)
    joined=" ${args[*]} "
    if [[ "$joined" == *" dangling=true "* ]]; then
      cat "$MOCK_DANGLING_IMAGE_FILE"
    else
      cat "$MOCK_IMAGE_FILE"
    fi
    exit 0
    ;;
  image:inspect)
    cat "$MOCK_IMAGE_IDENTITY_FILE"
    exit 0
    ;;
  image:rm)
    exit "${MOCK_DOCKER_MUTATION_RC:-0}"
    ;;
  network:ls)
    cat "$MOCK_NETWORK_FILE"
    exit 0
    ;;
  network:inspect)
    record=$(head -n 1 "$MOCK_NETWORK_FILE")
    [[ -n "$record" ]] || exit 1
    printf '%s|0\n' "$record"
    exit 0
    ;;
  network:rm)
    exit "${MOCK_DOCKER_MUTATION_RC:-0}"
    ;;
  volume:ls)
    cat "$MOCK_VOLUME_FILE"
    exit 0
    ;;
  volume:inspect)
    cat "$MOCK_VOLUME_IDENTITY_FILE"
    exit 0
    ;;
  volume:rm)
    exit "${MOCK_DOCKER_MUTATION_RC:-0}"
    ;;
  compose:version)
    printf 'Docker Compose version v2.29.0\n'
    exit 0
    ;;
  login:*)
    [[ " ${args[*]} " != *" --password-stdin "* ]] || cat >/dev/null
    if [[ -n "${MOCK_DOCKER_LOGIN_CONFIG_JSON:-}" ]]; then
      printf '%s\n' "$MOCK_DOCKER_LOGIN_CONFIG_JSON" \
        > "$docker_config/config.json"
      chmod 600 "$docker_config/config.json"
    fi
    printf 'Login Succeeded\n'
    exit "${MOCK_DOCKER_MUTATION_RC:-0}"
    ;;
esac

if [[ "$command_name" == "compose" ]]; then
  if [[ "${MOCK_REQUIRE_CLEAN_COMPOSE_ENV:-0}" == "1" \
    && ( -n "${COMPOSE_REMOVE_ORPHANS+x}" \
      || -n "${DOCKER_DEFAULT_PLATFORM+x}" ) ]]; then
    exit 96
  fi
  joined=" ${args[*]} "
  if [[ "$joined" == *" config "* ]]; then
    cat "$MOCK_COMPOSE_CONFIG_FILE"
  elif [[ "$joined" == *" logs "* ]]; then
    printf 'mock compose log\n'
  else
    exit "${MOCK_DOCKER_MUTATION_RC:-0}"
  fi
  exit 0
fi
if [[ "$command_name" == "run" ]]; then
  exit "${MOCK_DOCKER_MUTATION_RC:-0}"
fi

printf 'unexpected mock docker invocation: %s\n' "${args[*]}" >&2
exit 98
EOF
  chmod +x "$TEST_MOCK_BIN/docker"
}

teardown() {
  cleanup_sandbox
}

@test "docker: help uses stderr and router preserves arguments and status" {
  run run_zsh '
    docker-menu --help >"$HOME/help.out" 2>"$HOME/help.err" || return
    [[ ! -s "$HOME/help.out" && -s "$HOME/help.err" ]] || return 1
    _timed() { shift; "$@"; }
    docker-clean() {
      print -r -- "${(j: :)@}"
      return 37
    }
    docker-menu docker-clean --scope all --yes
  '
  [ "$status" -eq 37 ]
  [ "$output" = "--scope all --yes" ]
}

@test "docker: invalid grammar returns usage status before probing Docker" {
  run run_zsh 'docker-menu not-a-command'
  [ "$status" -eq 2 ]

  : > "$MOCK_DOCKER_LOG"
  run run_zsh 'docker-containers --action exec --id "'"$CONTAINER_ID"'" --dry-run'
  [ "$status" -eq 2 ]
  [ ! -s "$MOCK_DOCKER_LOG" ]

  run run_zsh 'docker-images --action remove --id sha256:abc --yes'
  [ "$status" -eq 2 ]
}

@test "docker: bounded probes fail closed without a timeout capability" {
  run run_zsh '
    _docker_timeout_command() { reply=(); return 1; }
    _docker_capture_probe_bounded 128 2 print -r -- data
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"timeout or gtimeout"* ]]
}

@test "docker: bounded capture preserves and rejects boundary newlines" {
  run run_zsh '
    _docker_run_probe() {
      shift
      command "$@"
    }
    _docker_capture_probe_bounded 4 2 /usr/bin/printf "abc\n" || return
    [[ "$REPLY" == "abc" ]] || return 1
    _docker_capture_probe_bounded 4 2 /usr/bin/printf "abcd\n"
    [[ $? -eq 1 && -z "$REPLY" ]]
  '
  [ "$status" -eq 0 ]
}

@test "docker: read probes suppress hostile daemon stderr" {
  export MOCK_DOCKER_HOSTILE_STDERR="1"
  run run_zsh '
    docker-containers --action list || return
    docker-images --action list || return
    docker-clean --scope stopped-containers --dry-run || return
    docker-clean --scope dangling-images --dry-run || return
    docker-clean --scope unused-networks --dry-run || return
    docker-clean --scope unused-volumes --yes
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *"HOSTILE_DOCKER_SECRET"* ]]
  [[ "$output" != *$'\033[31mHOSTILE_DOCKER_SECRET'* ]]
}

@test "docker: interactive stopped-container action avoids readonly status collisions" {
  export MOCK_FZF_MODE="response"
  export MOCK_FZF_EXPECT_KEY="ctrl-s"
  export MOCK_FZF_RESPONSE=$'demo [exited] alpine:3.20\t1'

  run run_zsh 'docker-containers'
  [ "$status" -eq 0 ]
  grep -q "container start -- $CONTAINER_ID" "$MOCK_DOCKER_LOG"
  [[ "$output" != *"read-only variable"* ]]
}

@test "docker: interactive Ctrl-L uses a bounded log tail without follow" {
  export MOCK_FZF_MODE="response"
  export MOCK_FZF_EXPECT_KEY="ctrl-l"
  export MOCK_FZF_RESPONSE=$'demo [exited] alpine:3.20\t1'

  run run_zsh 'docker-containers'
  [ "$status" -eq 0 ]
  grep -q "container logs --tail 100 -- $CONTAINER_ID" "$MOCK_DOCKER_LOG"
  ! grep -q "container logs .* --follow" "$MOCK_DOCKER_LOG"
}

@test "docker: picker capture is private and rejects failed output" {
  export TMPDIR="$HOME"
  export MOCK_FZF_MODE="response"
  export MOCK_FZF_RESPONSE="safe-row"
  export MOCK_FZF_EXPECT_KEY=""

  run run_zsh '
    docker-menu --help &>/dev/null
    _docker_fzf_capture <<< "safe-row" || return
    print -r -- "$REPLY"
    [[ -z "$(<$MOCK_FZF_INPUT_FILE)" || "$(<$MOCK_FZF_INPUT_FILE)" == safe-row ]]
    [[ -z "$(command find "$TMPDIR" -maxdepth 1 -name "zdx-docker-fzf.*" -print -quit)" ]]
  '
  [ "$status" -eq 0 ]
  [ "$output" = "safe-row" ]

  export MOCK_FZF_STATUS="2"
  cat > "$TEST_MOCK_BIN/fzf" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'forged-row\n'
exit "${MOCK_FZF_STATUS:-2}"
EOF
  chmod +x "$TEST_MOCK_BIN/fzf"
  run run_zsh '
    docker-menu --help &>/dev/null
    _docker_fzf_capture <<< "real-row"
  '
  [ "$status" -eq 125 ]
  [[ "$output" == *"failed Docker picker"* ]]
}

@test "docker: picker validates forged mktemp paths before mutation" {
  mkdir "$HOME/forged-target"
  chmod 755 "$HOME/forged-target"
  export MOCK_MKTEMP_FORGED_PATH="$HOME/forged-target"
  cat > "$TEST_MOCK_BIN/mktemp" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$MOCK_MKTEMP_FORGED_PATH"
EOF
  chmod +x "$TEST_MOCK_BIN/mktemp"

  run run_zsh '
    docker-menu --help &>/dev/null
    _docker_fzf_capture <<< "row"
  '
  [ "$status" -eq 125 ]
  [[ "$output" == *"unsafe Docker menu directory"* ]]
  [ -d "$HOME/forged-target" ]
  [ "$(stat -c %a "$HOME/forged-target")" = "755" ]

  printf 'do-not-touch\n' > "$HOME/forged-file"
  chmod 644 "$HOME/forged-file"
  export MOCK_MKTEMP_FORGED_PATH="$HOME/forged-file"
  cat > "$TEST_MOCK_BIN/mktemp" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-d" ]]; then
  exec /usr/bin/mktemp "$@"
fi
printf '%s\n' "$MOCK_MKTEMP_FORGED_PATH"
EOF
  chmod +x "$TEST_MOCK_BIN/mktemp"

  run run_zsh '
    docker-menu --help &>/dev/null
    _docker_fzf_capture <<< "row"
  '
  [ "$status" -eq 125 ]
  [[ "$output" == *"unsafe Docker menu result"* ]]
  [ "$(cat "$HOME/forged-file")" = "do-not-touch" ]
  [ "$(stat -c %a "$HOME/forged-file")" = "644" ]
}

@test "docker: option-like context names fail before context inspection" {
  export DOCKER_CONTEXT="--help"
  run run_zsh 'docker-containers --action list'
  [ "$status" -eq 1 ]
  [[ "$output" == *"context name is malformed"* ]]
  ! grep -q "context inspect" "$MOCK_DOCKER_LOG"
}

@test "docker: remote mutations require an explicit gate but dry runs do not" {
  export MOCK_DOCKER_ENDPOINT="tcp://docker.example.test:2376"

  run run_zsh \
    'docker-containers --action start --id "'"$CONTAINER_ID"'"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"--allow-remote"* ]]
  ! grep -q "container start" "$MOCK_DOCKER_LOG"

  : > "$MOCK_DOCKER_LOG"
  run run_zsh \
    'docker-containers --action start --id "'"$CONTAINER_ID"'" --dry-run'
  [ "$status" -eq 0 ]
  ! grep -q "container start" "$MOCK_DOCKER_LOG"
}

@test "docker: daemon identity changes abort before container mutation" {
  export MOCK_DOCKER_DAEMON_ID_AFTER="daemon-two"
  run run_zsh \
    'docker-containers --action start --id "'"$CONTAINER_ID"'"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"daemon identity changed"* ]]
  ! grep -q "container start" "$MOCK_DOCKER_LOG"
}

@test "docker: cleanup dry-run and noninteractive authorization never prune" {
  run run_zsh 'docker-clean --scope stopped-containers --dry-run'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Exact target count: 1"* ]]
  ! grep -Eq ' prune|container rm' "$MOCK_DOCKER_LOG"

  : > "$MOCK_DOCKER_LOG"
  run run_zsh 'docker-clean --scope stopped-containers'
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires --yes"* ]]
  ! grep -Eq ' prune|container rm' "$MOCK_DOCKER_LOG"
}

@test "docker: cleanup removes only the reviewed exact target" {
  run run_zsh 'docker-clean --scope stopped-containers --yes'
  [ "$status" -eq 0 ]
  grep -q "container rm -- $CONTAINER_ID" "$MOCK_DOCKER_LOG"
  ! grep -q " prune" "$MOCK_DOCKER_LOG"
}

@test "docker: cleanup plan changes fail revalidation and all excludes volumes" {
  run run_zsh '
    docker-clean --help >/dev/null
    _docker_clean_render_plan() {
      : > "$MOCK_STOPPED_FILE"
      return 0
    }
    docker-clean --scope stopped-containers --yes
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"plan changed"* ]]
  ! grep -q "container rm" "$MOCK_DOCKER_LOG"

  : > "$MOCK_DOCKER_LOG"
  run run_zsh 'docker-clean --scope all --dry-run'
  [ "$status" -eq 0 ]
  ! grep -q "volume ls" "$MOCK_DOCKER_LOG"
}

@test "docker: volume cleanup freezes creation and hidden metadata identity" {
  run run_zsh 'docker-clean --scope unused-volumes --dry-run'
  [ "$status" -eq 0 ]
  [[ "$output" == *"2026-01-01T00:00:00Z"* ]]
  [[ "$output" != *"safe|ops"* ]]
  [[ "$output" != *"/var/lib/docker/volumes"* ]]

  : > "$MOCK_DOCKER_LOG"
  run run_zsh '
    docker-clean --help >/dev/null
    _docker_clean_render_plan() {
      printf "%s\n" \
        "test-volume|local|local|2026-01-01T00:00:00Z|{\"team\":\"changed\"}|{}|/var/lib/docker/volumes/test-volume/_data" \
        > "$MOCK_VOLUME_IDENTITY_FILE"
      return 0
    }
    docker-clean --scope unused-volumes --yes
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"plan changed"* ]]
  ! grep -q "volume rm" "$MOCK_DOCKER_LOG"

  printf '%s\n' \
    'test-volume|local|local|2026-01-01T00:00:00Z|{}|{}|/var/lib/docker/volumes/test-volume/_data' \
    > "$MOCK_VOLUME_IDENTITY_FILE"
  : > "$MOCK_DOCKER_LOG"
  run run_zsh '
    docker-clean --help >/dev/null
    _docker_clean_render_plan() {
      printf "%s\n" \
        "test-volume|local|local|2026-02-02T00:00:00Z|{}|{}|/var/lib/docker/volumes/test-volume/_data" \
        > "$MOCK_VOLUME_IDENTITY_FILE"
      return 0
    }
    docker-clean --scope unused-volumes --yes
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"plan changed"* ]]
  ! grep -q "volume rm" "$MOCK_DOCKER_LOG"

  printf '%s\n' \
    'test-volume|local|local||{}|{}|/var/lib/docker/volumes/test-volume/_data' \
    > "$MOCK_VOLUME_IDENTITY_FILE"
  run run_zsh 'docker-clean --scope unused-volumes --dry-run'
  [ "$status" -eq 1 ]
  [[ "$output" == *"malformed volume identity"* ]]
}

@test "docker: Compose requires review and revalidates its descriptor" {
  mkdir "$HOME/compose"
  printf 'services:\n  app:\n    image: alpine:3.20\n' \
    > "$HOME/compose/compose.yaml"

  run run_zsh '
    cd "$HOME/compose" || return
    docker-compose-up --dry-run
  '
  [ "$status" -eq 0 ]
  ! grep -q " compose .* up " "$MOCK_DOCKER_LOG"

  : > "$MOCK_DOCKER_LOG"
  run run_zsh '
    cd "$HOME/compose" || return
    docker-compose-up
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires --yes"* ]]

  : > "$MOCK_DOCKER_LOG"
  run run_zsh '
    cd "$HOME/compose" || return
    docker-compose-up --yes
  '
  [ "$status" -eq 0 ]
  grep -q " compose --ansi never -f .* up -d" "$MOCK_DOCKER_LOG"

  : > "$MOCK_DOCKER_LOG"
  run run_zsh '
    cd "$HOME/compose" || return
    docker-compose-up --help >/dev/null
    _docker_compose_plan() {
      print "# changed" >> "$3"
      return 0
    }
    docker-compose-up --yes
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"descriptor changed"* ]]
  ! grep -q " compose .* up " "$MOCK_DOCKER_LOG"
}

@test "docker: Compose rejects semantic ambient state and unsafe workspaces" {
  mkdir "$HOME/compose"
  printf 'services:\n  app:\n    image: alpine:3.20\n' \
    > "$HOME/compose/compose.yaml"

  export COMPOSE_REMOVE_ORPHANS="1"
  run run_zsh '
    cd "$HOME/compose" || return
    docker-compose-down --yes
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"Refusing ambient COMPOSE_REMOVE_ORPHANS"* ]]
  ! grep -q " compose .* down" "$MOCK_DOCKER_LOG"

  unset COMPOSE_REMOVE_ORPHANS
  export COMPOSE_BAKE="1"
  run run_zsh '
    cd "$HOME/compose" || return
    docker-compose-up --dry-run
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"Refusing ambient COMPOSE_BAKE"* ]]

  unset COMPOSE_BAKE
  export COMPOSE_REMOVE_ORPHANS=""
  export DOCKER_DEFAULT_PLATFORM=""
  export MOCK_REQUIRE_CLEAN_COMPOSE_ENV="1"
  run run_zsh '
    cd "$HOME/compose" || return
    docker-compose-up --dry-run
  '
  [ "$status" -eq 0 ]

  unset COMPOSE_REMOVE_ORPHANS DOCKER_DEFAULT_PLATFORM
  chmod 775 "$HOME/compose"
  run run_zsh '
    cd "$HOME/compose" || return
    docker-compose-up --dry-run
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"workspace is unsafe"* ]]
}

@test "docker: login is daemon-independent and validates credential boundaries" {
  export MOCK_FAIL_INFO="1"
  run run_zsh \
    'print -r -- secret | docker-login registry.example.test:5000 --username tester --password-stdin'
  [ "$status" -eq 0 ]
  grep -q "docker --config $HOME/.docker login --username tester --password-stdin registry.example.test:5000" \
    "$MOCK_DOCKER_LOG"
  ! grep -q " info " "$MOCK_DOCKER_LOG"
  [[ "$output" == *"Credential config directory: $HOME/.docker"* ]]
  [[ "$output" != *"secret"* ]]

  run run_zsh 'docker-login foo::bar --username tester --password-stdin'
  [ "$status" -eq 2 ]

  run run_zsh 'docker-login registry.example.test'
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires a terminal"* ]]
}

@test "docker: every client command pins a safe unexported config directory" {
  mkdir "$HOME/custom-docker"
  chmod 700 "$HOME/custom-docker"

  run run_zsh '
    unset DOCKER_CONFIG
    typeset -g DOCKER_CONFIG="$HOME/custom-docker"
    typeset +x DOCKER_CONFIG
    docker-containers --action list || return
    print -r -- secret \
      | docker-login registry.example.test \
        --username tester --password-stdin
  '
  [ "$status" -eq 0 ]
  grep -q \
    "^docker --config $HOME/custom-docker context show" \
    "$MOCK_DOCKER_LOG"
  grep -q \
    "^docker --config $HOME/custom-docker --context local-test container ls" \
    "$MOCK_DOCKER_LOG"
  grep -q \
    "^docker --config $HOME/custom-docker login --username tester --password-stdin registry.example.test" \
    "$MOCK_DOCKER_LOG"
}

@test "docker: fresh HOME stays read-only until login creates private config" {
  rmdir "$HOME/.docker"

  run run_zsh 'docker-containers --action list'
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.docker" ]
  grep -q \
    "^docker --config $HOME/.docker context show" \
    "$MOCK_DOCKER_LOG"

  run run_zsh \
    'print -r -- secret | docker-login registry.example.test --username tester --password-stdin'
  [ "$status" -eq 0 ]
  [ -d "$HOME/.docker" ]
  [ "$(stat -c %a "$HOME/.docker")" = "700" ]
  grep -q \
    "^docker --config $HOME/.docker login --username tester --password-stdin registry.example.test" \
    "$MOCK_DOCKER_LOG"
}

@test "docker: malformed config JSON fails closed before daemon access" {
  printf '{not-json\n' > "$HOME/.docker/config.json"
  chmod 600 "$HOME/.docker/config.json"

  run run_zsh 'docker-containers --action list'
  [ "$status" -eq 1 ]
  [[ "$output" == *"not one valid JSON object"* ]]
  [[ "$output" != *"{not-json"* ]]
  ! grep -q " context show" "$MOCK_DOCKER_LOG"
  ! grep -q " container ls" "$MOCK_DOCKER_LOG"

  printf '{}\n{}\n' > "$HOME/.docker/config.json"
  : > "$MOCK_DOCKER_LOG"
  run run_zsh 'docker-containers --action list'
  [ "$status" -eq 1 ]
  [[ "$output" == *"not one valid JSON object"* ]]
  ! grep -q " context show" "$MOCK_DOCKER_LOG"
}

@test "docker: malformed config JSON fails closed before registry login" {
  printf '[]\n' > "$HOME/.docker/config.json"
  chmod 600 "$HOME/.docker/config.json"

  run run_zsh \
    'print -r -- secret | docker-login registry.example.test --username tester --password-stdin'
  [ "$status" -eq 1 ]
  [[ "$output" == *"not one valid JSON object"* ]]
  [[ "$output" != *"secret"* ]]
  ! grep -q " context show" "$MOCK_DOCKER_LOG"
  ! grep -q " login " "$MOCK_DOCKER_LOG"
}

@test "docker: login preflights post-write validation capabilities" {
  run run_zsh '
    _docker_require_cmd() {
      if [[ "$1" == jq ]]; then
        _docker_error "jq is unavailable for this test."
        return 1
      fi
      command -v "$1" &>/dev/null
    }
    print -r -- secret \
      | docker-login registry.example.test --username tester --password-stdin
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"jq is unavailable"* ]]
  ! grep -q " login " "$MOCK_DOCKER_LOG"

  : > "$MOCK_DOCKER_LOG"
  run run_zsh '
    _docker_timeout_command() {
      reply=()
      return 1
    }
    print -r -- secret \
      | docker-login registry.example.test --username tester --password-stdin
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"timeout or gtimeout"* ]]
  ! grep -q " login " "$MOCK_DOCKER_LOG"
}

@test "docker: registry login revalidates JSON written by Docker" {
  export MOCK_DOCKER_LOGIN_CONFIG_JSON="{broken-after-login"

  run run_zsh \
    'print -r -- secret | docker-login registry.example.test --username tester --password-stdin'
  [ "$status" -eq 1 ]
  [[ "$output" == *"unsafe credential configuration"* ]]
  [[ "$output" != *"{broken-after-login"* ]]
  [[ "$output" != *"secret"* ]]
  grep -q " login " "$MOCK_DOCKER_LOG"
}

@test "docker: client parse warnings fail closed before daemon or login" {
  printf '{"currentContext":[]}\n' > "$HOME/.docker/config.json"
  chmod 600 "$HOME/.docker/config.json"
  export MOCK_DOCKER_CONFIG_WARNING="mock Docker config parse warning"

  run run_zsh 'docker-containers --action list'
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid or unsafe config.json"* ]]
  [[ "$output" != *"mock Docker config parse warning"* ]]
  grep -q " context show" "$MOCK_DOCKER_LOG"
  ! grep -q " container ls" "$MOCK_DOCKER_LOG"

  : > "$MOCK_DOCKER_LOG"
  run run_zsh \
    'print -r -- secret | docker-login registry.example.test --username tester --password-stdin'
  [ "$status" -eq 1 ]
  [[ "$output" == *"client cannot parse"* ]]
  [[ "$output" != *"mock Docker config parse warning"* ]]
  grep -q " context show" "$MOCK_DOCKER_LOG"
  ! grep -q " login " "$MOCK_DOCKER_LOG"
}

@test "docker: client config rejects outside, permissive, linked, and oversized state" {
  mkdir "$TEST_TEMP_DIR/outside-docker"
  chmod 700 "$TEST_TEMP_DIR/outside-docker"
  export DOCKER_CONFIG="$TEST_TEMP_DIR/outside-docker"
  run run_zsh 'docker-containers --action list'
  [ "$status" -eq 1 ]
  [[ "$output" == *"unsafe Docker client configuration"* ]]
  ! grep -q " context show" "$MOCK_DOCKER_LOG"

  export DOCKER_CONFIG="$HOME/.docker"
  chmod 755 "$HOME/.docker"
  run run_zsh 'docker-containers --action list'
  [ "$status" -eq 1 ]
  chmod 700 "$HOME/.docker"

  printf '{}\n' > "$HOME/config-source.json"
  chmod 600 "$HOME/config-source.json"
  ln -s "$HOME/config-source.json" "$HOME/.docker/config.json"
  run run_zsh 'docker-containers --action list'
  [ "$status" -eq 1 ]
  rm "$HOME/.docker/config.json"

  ln "$HOME/config-source.json" "$HOME/.docker/config.json"
  run run_zsh \
    'print -r -- secret | docker-login registry.example.test --username tester --password-stdin'
  [ "$status" -eq 1 ]
  [[ "$output" == *"unsafe Docker credential configuration"* ]]
  rm "$HOME/.docker/config.json"

  cp "$HOME/config-source.json" "$HOME/.docker/config.json"
  chmod 644 "$HOME/.docker/config.json"
  run run_zsh 'docker-containers --action list'
  [ "$status" -eq 1 ]

  chmod 600 "$HOME/.docker/config.json"
  truncate -s 1048577 "$HOME/.docker/config.json"
  run run_zsh 'docker-containers --action list'
  [ "$status" -eq 1 ]
}

@test "docker: unsafe credential config symlinks are rejected" {
  mkdir "$HOME/real-config"
  ln -s "$HOME/real-config" "$HOME/config-link"
  export DOCKER_CONFIG="$HOME/config-link"

  run run_zsh \
    'print -r -- secret | docker-login registry.example.test --username tester --password-stdin'
  [ "$status" -eq 1 ]
  [[ "$output" == *"unsafe Docker credential"* ]]
  ! grep -q " login " "$MOCK_DOCKER_LOG"
}
