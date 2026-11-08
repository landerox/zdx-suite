#!/usr/bin/env bats
# shellcheck disable=SC2016
# Dotenv Git probes and physical-file attribution in disposable repositories.

setup() {
  load test_helper
  export DOTENV_GIT_PROJECT="$HOME/project"
  export GIT_CEILING_DIRECTORIES="$TEST_TEMP_DIR"
  mkdir -p "$DOTENV_GIT_PROJECT"
  printf 'A=private-value\n' > "$DOTENV_GIT_PROJECT/.env"
  chmod -- 600 "$DOTENV_GIT_PROJECT/.env"
}

teardown() { cleanup_sandbox; }

dotenv_git_init() {
  git -C "$DOTENV_GIT_PROJECT" -c init.defaultBranch=main init -q
  git -C "$DOTENV_GIT_PROJECT" add -f -- .env
}

dotenv_git_monitor() {
  export DOTENV_GIT_MONITOR="$HOME/monitor"
  export DOTENV_GIT_MONITOR_LOG="$HOME/monitor.log"
  printf '#!%s\n' "$BASH" > "$DOTENV_GIT_MONITOR"
  cat >> "$DOTENV_GIT_MONITOR" <<'MONITOR'
[[ "$DOTENV_GIT_MONITOR_LOG" == "$HOME/monitor.log" ]] || exit 97
printf 'repository monitor ran\n' >> "$DOTENV_GIT_MONITOR_LOG"
printf 'private-token\0'
MONITOR
  chmod -- 700 "$DOTENV_GIT_MONITOR"
}

run_dotenv_git() {
  run run_zsh '
    builtin cd -- "$DOTENV_GIT_PROJECT" || return 97
    NO_COLOR=1 env-dotenv --json >"$HOME/data" 2>"$HOME/ui"
  '
}

assert_dotenv_git_unknown() {
  jq -e '.dotenv.git == {repository:null, tracked:null, ignored:null}' "$HOME/data"
  grep -Fq -- 'Git could not check tracking and ignore rules' "$HOME/ui"
  run grep -Fq -- 'is not in a Git repository' "$HOME/ui"
  [ "$status" -eq 1 ]
}

@test "env dotenv git safety: a repository fsmonitor never executes" {
  dotenv_git_init
  dotenv_git_monitor
  git -C "$DOTENV_GIT_PROJECT" config core.fsmonitor "$DOTENV_GIT_MONITOR"
  run_dotenv_git
  [ "$status" -eq 1 ]
  jq -e '.dotenv.git == {repository:true, tracked:true, ignored:false}' "$HOME/data"
  [ ! -e "$DOTENV_GIT_MONITOR_LOG" ]
}

@test "env dotenv git safety: command-line config disables an inherited fsmonitor" {
  dotenv_git_init
  dotenv_git_monitor
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsmonitor
  export GIT_CONFIG_VALUE_0="$DOTENV_GIT_MONITOR"
  run_dotenv_git
  [ "$status" -eq 1 ]
  jq -e '.dotenv.git.tracked == true' "$HOME/data"
  [ ! -e "$DOTENV_GIT_MONITOR_LOG" ]
}

@test "env dotenv git safety: a real ownership refusal leaves unknown facts" {
  dotenv_git_init
  export GIT_TEST_ASSUME_DIFFERENT_OWNER=1
  run_dotenv_git
  [ "$status" -eq 0 ]
  assert_dotenv_git_unknown
}

@test "env dotenv git safety: corrupt repository metadata is unknown without diagnostic disclosure" {
  dotenv_git_init
  printf '[private-zdx-config-canary\n' > "$DOTENV_GIT_PROJECT/.git/config"
  run_dotenv_git
  [ "$status" -eq 0 ]
  assert_dotenv_git_unknown
  run grep -Fq -- private-zdx-config-canary "$HOME/data" "$HOME/ui"
  [ "$status" -eq 1 ]
}

@test "env dotenv git safety: an invalid gitdir file is an unknown repository observation" {
  printf 'gitdir: %s\n' "$HOME/missing-private-gitdir" > "$DOTENV_GIT_PROJECT/.git"
  run_dotenv_git
  [ "$status" -eq 0 ]
  assert_dotenv_git_unknown
}

@test "env dotenv git safety: a dangling git entry cannot establish repository absence" {
  ln -s "$HOME/missing-private-gitdir" "$DOTENV_GIT_PROJECT/.git"
  run_dotenv_git
  [ "$status" -eq 0 ]
  assert_dotenv_git_unknown
}

@test "env dotenv git safety: a genuine non-repository keeps a known negative fact" {
  run_dotenv_git
  [ "$status" -eq 0 ]
  jq -e '.dotenv.git == {repository:false, tracked:null, ignored:null}' "$HOME/data"
  run grep -Fq -- 'Git could not check' "$HOME/ui"
  [ "$status" -eq 1 ]
}

@test "env dotenv git safety: a discovery ceiling excludes metadata above the checked directory" {
  mkdir -p "$HOME/ceiling/.git" "$HOME/ceiling/project"
  printf 'A=private-value\n' > "$HOME/ceiling/project/.env"
  chmod -- 600 "$HOME/ceiling/project/.env"
  export DOTENV_GIT_PROJECT="$HOME/ceiling/project"
  export GIT_CEILING_DIRECTORIES="$HOME/ceiling"
  run_dotenv_git
  [ "$status" -eq 0 ]
  jq -e '.dotenv.git == {repository:false, tracked:null, ignored:null}' "$HOME/data"
  [ ! -s "$HOME/ui" ]
}

@test "env dotenv git safety: a discovery ceiling never hides current-directory metadata" {
  mkdir -p "$DOTENV_GIT_PROJECT/.git"
  export GIT_CEILING_DIRECTORIES="$DOTENV_GIT_PROJECT"
  run_dotenv_git
  [ "$status" -eq 0 ]
  assert_dotenv_git_unknown
}

@test "env dotenv git safety: physical dot-dot paths bind parsing Git sops and counterparts" {
  dotenv_git_init
  mkdir -p "$HOME/elsewhere/child"
  ln -s "$HOME/elsewhere/child" "$DOTENV_GIT_PROJECT/link"
  printf 'A=private-one\nB=private-two\n' > "$HOME/elsewhere/.env"
  printf 'A=\nB=\n' > "$HOME/elsewhere/.env.example"
  printf 'data-only\n' > "$HOME/elsewhere/.sops.yaml"
  printf 'data-only\n' > "$HOME/elsewhere/.env.enc"
  chmod -- 600 "$HOME/elsewhere/.env" "$HOME/elsewhere/.env.example"
  run run_zsh '
    builtin cd -- "$DOTENV_GIT_PROJECT" || return 97
    NO_COLOR=1 env-dotenv link/../.env --json >"$HOME/data" 2>"$HOME/ui"
  '
  [ "$status" -eq 0 ]
  jq -e --arg directory "$HOME/elsewhere" '
    .dotenv.path == ($directory + "/.env") and .dotenv.key_count == 2
    and .example.path == ($directory + "/.env.example")
    and .dotenv.git == {repository:false,tracked:null,ignored:null}
    and .dotenv.sops.config_path == ($directory + "/.sops.yaml")
    and .dotenv.sops.encrypted_counterpart_paths == [($directory + "/.env.enc")]
    and .missing == [] and .extra == []
  ' "$HOME/data"
  run grep -Fq -- private- "$HOME/data" "$HOME/ui"
  [ "$status" -eq 1 ]
}

@test "env dotenv git safety: explicit example paths retain physical dot-dot resolution" {
  mkdir -p "$HOME/elsewhere/child"
  ln -s "$HOME/elsewhere/child" "$DOTENV_GIT_PROJECT/link"
  printf 'A=private-example\n' > "$HOME/elsewhere/example"
  chmod -- 600 "$HOME/elsewhere/example"
  run run_zsh '
    builtin cd -- "$DOTENV_GIT_PROJECT" || return 97
    NO_COLOR=1 env-dotenv --example link/../example --json >"$HOME/data" 2>"$HOME/ui"
  '
  [ "$status" -eq 0 ]
  jq -e --arg example "$HOME/elsewhere/example" '
    .example.path == $example and .example.key_count == 1 and .in_sync == true
  ' "$HOME/data"
}

@test "env dotenv git safety: later alias replacement cannot move counterpart facts to another file" {
  mkdir -p "$HOME/first/child" "$HOME/second/child"
  printf 'A=private-first\n' > "$HOME/first/.env"
  printf 'A=private-second\n' > "$HOME/second/.env"
  printf 'data-only\n' > "$HOME/second/.env.enc"
  chmod -- 600 "$HOME/first/.env" "$HOME/second/.env"
  ln -s "$HOME/first/child" "$DOTENV_GIT_PROJECT/link"
  run run_zsh '
    builtin cd -- "$DOTENV_GIT_PROJECT" || return 97
    _env_dotenv_git_facts() {
      [[ -L "$DOTENV_GIT_PROJECT/link" ]] || return 98
      command rm -- "$DOTENV_GIT_PROJECT/link" || return 99
      command ln -s "$HOME/second/child" "$DOTENV_GIT_PROJECT/link" || return 99
      reply=(no unknown unknown "")
    }
    NO_COLOR=1 env-dotenv link/../.env --json >"$HOME/data" 2>"$HOME/ui"
  '
  [ "$status" -eq 0 ]
  [ -f "$HOME/first/.env" ]
  [ -f "$HOME/second/.env.enc" ]
  jq -e --arg path "$HOME/first/.env" '
    .dotenv.path == $path and .dotenv.key_count == 1
    and .dotenv.sops.encrypted_counterpart == false
    and .dotenv.sops.encrypted_counterpart_paths == []
  ' "$HOME/data"
}

@test "env dotenv git safety: physical parent resolution still refuses a symbolic-link leaf" {
  mkdir -p "$HOME/elsewhere/child"
  ln -s "$HOME/elsewhere/child" "$DOTENV_GIT_PROJECT/link"
  ln -s "$DOTENV_GIT_PROJECT/.env" "$HOME/elsewhere/.env"
  run run_zsh '
    builtin cd -- "$DOTENV_GIT_PROJECT" || return 97
    NO_COLOR=1 env-dotenv link/../.env --json >"$HOME/data" 2>"$HOME/ui"
  '
  [ "$status" -eq 1 ]
  [ ! -s "$HOME/data" ]
  grep -Fq -- 'it is a symbolic link' "$HOME/ui"
}

prepare_example_alias() {
  mkdir -p "$HOME/first/child" "$HOME/second/child"
  printf 'A=private-first\n' > "$HOME/first/.env"
  printf 'A=\n' > "$HOME/first/.env.example"
  printf 'A=private-second\n' > "$HOME/second/.env"
  printf 'B=\n' > "$HOME/second/.env.example"
  chmod -- 600 "$HOME/first/.env" "$HOME/first/.env.example" \
    "$HOME/second/.env" "$HOME/second/.env.example"
  ln -s "$HOME/first/child" "$DOTENV_GIT_PROJECT/link"
}

@test "env dotenv git safety: automatic example retains the dotenv frozen physical parent" {
  prepare_example_alias
  run run_zsh '
    builtin cd -- "$DOTENV_GIT_PROJECT" || return 97
    source "$ZSH_CUSTOM/functions/env-menu.zsh" || return
    functions[_review_physical_path]="${functions[_env_dotenv_physical_path]}"
    _env_dotenv_physical_path() {
      _review_physical_path "$@" || return
      if [[ "$1" == link/../.env ]]; then
        command rm -- "$DOTENV_GIT_PROJECT/link" || return 98
        command ln -s "$HOME/second/child" "$DOTENV_GIT_PROJECT/link" || return 98
      fi
    }
    NO_COLOR=1 env-dotenv link/../.env --json > "$HOME/data" 2> "$HOME/ui"
  '
  printf 'returned=%s\n' "$status" >&2
  jq '{dotenv_path:.dotenv.path,example_path:.example.path,missing,extra}' "$HOME/data" >&2
  [ "$status" -eq 0 ]
  jq -e --arg path "$HOME/first/.env.example" '.example.path == $path and .in_sync == true' "$HOME/data"
}

@test "env dotenv git safety control: an unchanged alias uses its physical default example" {
  prepare_example_alias
  run run_zsh '
    builtin cd -- "$DOTENV_GIT_PROJECT" || return 97
    NO_COLOR=1 env-dotenv link/../.env --json > "$HOME/data" 2> "$HOME/ui"
  '
  [ "$status" -eq 0 ]
  jq -e --arg path "$HOME/first/.env.example" '.example.path == $path and .in_sync == true' "$HOME/data"
}
