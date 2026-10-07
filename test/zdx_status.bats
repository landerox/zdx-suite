#!/usr/bin/env bats
# `zdx status`: router parity, read-only probes, text rendering, and the
# zdx.status.v1 JSON document. Quoted programs are passed literally to an
# isolated Zsh process; fixture paths arrive as positional arguments.
# shellcheck disable=SC2016

setup() {
  load test_helper
  STATUS_REAL_JQ=$(command -v jq || true)
  export STATUS_REAL_JQ
  export STATUS_ROOT="$TEST_SUITE_ROOT"
  export WS_BASE_DIR="$HOME/workspaces"
  # Fixture repositories are found below the sandbox; nothing above it is.
  export GIT_CEILING_DIRECTORIES="$TEST_TEMP_DIR"
  export STATUS_PROBE_LOG="$TEST_TEMP_DIR/probes"
  : > "$STATUS_PROBE_LOG"
}

teardown() {
  cleanup_sandbox
}

# A repository with one pushed commit, one unpushed commit, and one staged,
# one unstaged, and one untracked change, below the workspace layout.
make_status_repo() {
  local repo="$1" remote="$TEST_TEMP_DIR/remote.git"
  mkdir -p "$repo"
  git init -q -b main "$repo"
  git -C "$repo" config user.email "jane@example.com"
  git -C "$repo" config user.name "Jane Doe"
  git -C "$repo" config commit.gpgsign false
  printf 'one\n' > "$repo/tracked.txt"
  git -C "$repo" add tracked.txt
  git -C "$repo" commit -q -m "first"
  git init -q --bare "$remote"
  git -C "$repo" remote add origin "$remote"
  git -C "$repo" push -q -u origin main 2>/dev/null
  printf 'two\n' >> "$repo/tracked.txt"
  git -C "$repo" commit -q -am "second"
  printf 'staged\n' > "$repo/staged.txt"
  git -C "$repo" add staged.txt
  printf 'three\n' >> "$repo/tracked.txt"
  printf 'new\n' > "$repo/untracked.txt"
}

# Loads the core from this checkout, pins every host fact that does not
# belong to the test, and runs the program given first from the directory
# given second. Inside the program that directory is $1, and further
# arguments are $2 and later.
status_zsh() {
  local program="$1"
  shift
  zsh -f -c '
    source "$STATUS_ROOT/functions.zsh" || exit 90
    cd "$1" || exit 91
    OSTYPE=linux-gnu
    _zdx_status_platform() { REPLY=Linux; }
    _zdx_status_reboot_required() { REPLY=false; }
    _zdx_status_load_average() { reply=(0.50 0.40 0.30); }
    _zdx_status_wireguard_interfaces() { reply=(); }
    unset VIRTUAL_ENV ZDX_TELEMETRY ZDX_VERBOSE
    '"$program"'
  ' zdx-status-test "$@"
}

@test "zdx status: the module loads silently, idempotently, and evaluator-free" {
  run zsh -f -c '
    source "$1/functions/zdx-status.zsh" || exit
    first_definition="${functions[zdx-status]}"
    source "$1/functions/zdx-status.zsh" || exit
    [[ -n "${_ZDX_STATUS_SOURCED:-}" \
      && "${functions[zdx-status]}" == "$first_definition" ]]
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(awk 'NF { line=$0 } END { print line }' \
    "$TEST_SUITE_ROOT/functions/zdx-status.zsh")" \
    = "typeset -g _ZDX_STATUS_SOURCED=1" ]
  run grep -Eq '(^|[[:space:]])eval([[:space:]]|$)|-common[.]zsh' \
    "$TEST_SUITE_ROOT/functions/zdx-status.zsh"
  [ "$status" -eq 1 ]
}

@test "zdx status: help uses stderr and invalid grammar fails before any probe" {
  run zsh -f -c '
    source "$1/functions.zsh" || exit 90
    _zdx_status_collect() { print -r -- UNEXPECTED_PROBE; }
    zdx-status --help >"$2/help.out" 2>"$2/help.err" || exit 1
    [[ ! -s "$2/help.out" ]] && grep -q -- "--json" "$2/help.err" || exit 2
    local arguments=""
    for arguments in "--unknown" "extra" "--json extra" "--help extra" "--json --json"; do
      zdx-status ${=arguments} >"$2/bad.out" 2>"$2/bad.err"
      (( $? == 2 )) || exit 3
      [[ ! -s "$2/bad.out" ]] || exit 4
    done
    zdx-status "" >/dev/null 2>&1
    (( $? == 2 ))
  ' _ "$TEST_SUITE_ROOT" "$TEST_TEMP_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" != *UNEXPECTED_PROBE* ]]
}

@test "zdx status: router, help, completion, catalog, reserved name, and lazy stub agree" {
  run zsh -f -c '
    source "$1/functions/zdx-menu.zsh" || exit 90
    _zdx_usage 2>&1 | grep -Eq "^  status \[--json\] " || exit 1
    _zdx_menu_model | grep -Fq "|status|" || exit 2
    _zdx_menu_model | grep -Fq "Show Status Dashboard (status)|status|" || exit 3
    _zdx_wrapper_name_reserved status || exit 4
    zdx-status() {
      printf "count=%d\n" "$#"
      local argument=""
      for argument in "$@"; do printf "<%s>\n" "$argument"; done
    }
    zdx status --json "\$(touch $2/evaluated)"
  ' _ "$TEST_SUITE_ROOT" "$TEST_TEMP_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"count=2"* && "$output" == *"<--json>"* ]]
  [ ! -e "$TEST_TEMP_DIR/evaluated" ]

  # The ZDX Tools group lists status before the doctor and plugin manager.
  run zsh -f -c '
    source "$1/functions/zdx-menu.zsh" || exit 90
    _zdx_menu_model | awk -F "|" "/ZDX Tools/ { in_tools=1; next }
      in_tools && \$2 != \":\" { print \$2 }"
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | head -n 3 | tr '\n' ' ')" = "status doctor plugins " ]

  run zsh -f -c '
    _arguments() { state=suite; }
    _describe() { local array_name="$4"; print -rl -- "${(@P)array_name}"; }
    _test_completion() { source "$1/completions/_zdx-menu"; }
    service=zdx
    _test_completion "$1"
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^status:')" -eq 1 ]

  # `zdx status <TAB>` and `zdx-status <TAB>` offer the same two options.
  run zsh -f -c '
    _arguments() {
      if [[ "$1" == -C ]]; then state=suite-arguments; return 0; fi
      print -rl -- "$@"
    }
    _test_completion() { source "$1/completions/_zdx-menu"; }
    service=zdx
    words=(status "")
    _test_completion "$1" || exit 1
    service=zdx-status
    _test_completion "$1"
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c -- '--json\[')" -eq 2 ]
  [ "$(printf '%s\n' "$output" | grep -c -- '--help\[')" -eq 2 ]
  head -n 1 "$TEST_SUITE_ROOT/completions/_zdx-menu" \
    | grep -Fqx '#compdef zdx zdx-menu zdx-status zdx-plugins'

  run zsh -f -c '
    unset TEST_TEMP_DIR BATS_TEST_DIRNAME
    export HOME="$2"
    source "$1/functions.zsh" || exit 90
    [[ "${_ZDX_LAZY_FILES[zdx-status]-}" == zdx-status.zsh ]] || exit 1
    (( ! ${+functions[_zdx_status_collect]} )) || exit 2
    zdx status --help 2>/dev/null || exit 3
    (( ${+functions[_zdx_status_collect]} ))
  ' _ "$TEST_SUITE_ROOT" "$HOME"
  [ "$status" -eq 0 ]
}

@test "zdx status: the reported release matches the project version" {
  local project_version=""
  project_version=$(awk -F '"' '/^version = "/ { print $2; exit }' \
    "$TEST_SUITE_ROOT/pyproject.toml")
  [ -n "$project_version" ]
  grep -Fq '"functions/zdx-status.zsh:Developer Experience",' \
    "$TEST_SUITE_ROOT/pyproject.toml"
  grep -Eq "^_zdx_status_release\(\) \{ REPLY=\"$project_version\"; \} # ZDX \(Zsh Developer Experience\)$" \
    "$TEST_SUITE_ROOT/functions/zdx-status.zsh"
}

@test "zdx status: JSON reports a repository with an upstream, changes, and workspace" {
  [ -n "$STATUS_REAL_JQ" ] || skip "jq is not installed"
  local repo="$HOME/workspaces/github/personal/demo"
  make_status_repo "$repo"

  run status_zsh '
    zdx-status --json >"$2/status.json" 2>"$2/status.err"
  ' "$repo" "$TEST_TEMP_DIR"
  [ "$status" -eq 0 ]
  local document="$TEST_TEMP_DIR/status.json"
  # Exactly one compact document on one line, no ANSI, and the schema key
  # first.
  [ "$("$STATUS_REAL_JQ" -s 'length' "$document")" -eq 1 ]
  [ "$(wc -l < "$document")" -eq 1 ]
  [ "$(head -c 1 "$document")" = "{" ]
  [ "$(tail -c 2 "$document" | od -An -c | tr -d ' ')" = '}\n' ]
  run grep -c $'\033' "$document"
  [ "$output" -eq 0 ]
  [ "$("$STATUS_REAL_JQ" -r 'keys_unsorted[0]' "$document")" = schema ]
  "$STATUS_REAL_JQ" -e --arg root "$repo" '
    .schema == "zdx.status.v1"
    and (.generated_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and .repository.root == $root
    and .repository.branch == "main"
    and .repository.detached == false
    and (.repository.commit | test("^[0-9a-f]{40}$"))
    and .repository.upstream == "origin/main"
    and .repository.ahead == 1 and .repository.behind == 0
    and .repository.staged == 1 and .repository.unstaged == 1
    and .repository.untracked == 1 and .repository.conflicted == 0
    and .repository.operation == null
    and .repository.user_email == "jane@example.com"
    and .repository.workspace == {platform: "github", identity: "personal"}
    and .project.directory == null and .project.files == []
    and .project.virtual_env_active == false
    and .project.project_venv_active == null
    and .vpn.wireguard_interfaces == []
    and .host.platform == "Linux" and .host.reboot_required == false
    and .host.home_filesystem == {size_bytes: 1024000000,
      used_bytes: 512000000, available_bytes: 512000000, used_percent: 50}
    and .host.load_average == [0.5, 0.4, 0.3]
    and .zdx.custom_plugins == 0 and .zdx.telemetry == false
    and .zdx.verbose == false and (.zdx.version | type) == "string"
  ' "$document"
  # The index was not refreshed on disk by the read-only status probe.
  [ ! -e "$repo/.git/index.lock" ]
}

@test "zdx status: text mode prints one report on stderr and nothing on stdout" {
  local repo="$HOME/workspaces/github/personal/demo"
  make_status_repo "$repo"

  run status_zsh '
    export NO_COLOR=1
    zdx-status >"$2/text.out" 2>"$2/text.err"
  ' "$repo" "$TEST_TEMP_DIR"
  [ "$status" -eq 0 ]
  [ ! -s "$TEST_TEMP_DIR/text.out" ]
  local report="$TEST_TEMP_DIR/text.err"
  run grep -c $'\033' "$report"
  [ "$output" -eq 0 ]
  [ "$(grep -c '^════ ZDX Status ════$' "$report")" -eq 1 ]
  grep -Fxq '▸ Repository' "$report"
  grep -Fxq '  Root:              ~/workspaces/github/personal/demo' "$report"
  grep -Fxq '  Branch:            main → origin/main, ahead 1, behind 0' "$report"
  grep -Fxq '  Changes:           1 staged, 1 unstaged, 1 untracked' "$report"
  grep -Fxq '  User email:        jane@example.com' "$report"
  grep -Fxq '  Workspace:         github / personal' "$report"
  grep -Fxq '  WireGuard:         no active interface' "$report"
  grep -Fxq '  Home filesystem:   50% used, 488.3 MiB free of 976.6 MiB' "$report"
  grep -Fxq '  Load average:      0.50 0.40 0.30' "$report"
  grep -Fxq '  Plugins:           0 custom plugins loaded' "$report"
  grep -Fxq '  Settings:          telemetry off, verbose off' "$report"
  grep -Fq 'zdx:status completed in' "$report"
  run grep -F '(s)' "$report"
  [ "$status" -eq 1 ]
}

@test "zdx status: outside a repository the repository is null and the project is local" {
  [ -n "$STATUS_REAL_JQ" ] || skip "jq is not installed"
  local project="$TEST_TEMP_DIR/plain project"
  mkdir -p "$project/.venv"
  : > "$project/pyproject.toml"
  : > "$project/uv.lock"
  : > "$project/Justfile"
  : > "$project/Makefile"
  touch -t 202001010000 "$project/uv.lock"
  touch -t 202101010000 "$project/pyproject.toml"

  run status_zsh '
    export VIRTUAL_ENV="$1/.venv"
    zdx-status --json >"$2/out.json" 2>"$2/err" || exit
    unset VIRTUAL_ENV
    zdx-status 2>"$2/text.err"
  ' "$project" "$TEST_TEMP_DIR"
  [ "$status" -eq 0 ]
  "$STATUS_REAL_JQ" -e --arg dir "$project" '
    .repository == null
    and .project.directory == $dir
    and .project.files == ["pyproject.toml", "uv.lock", "Justfile", "Makefile"]
    and .project.virtual_env_active == true
    and .project.project_venv_present == true
    and .project.project_venv_active == true
    and .project.uv_lock_older_than_pyproject == true
  ' "$TEST_TEMP_DIR/out.json"
  grep -Fq 'Not inside a Git work tree.' "$TEST_TEMP_DIR/text.err"
  grep -Fq 'Virtualenv:        inactive; project .venv present' \
    "$TEST_TEMP_DIR/text.err"
  grep -Fq 'Lockfile:          uv.lock is older than pyproject.toml' \
    "$TEST_TEMP_DIR/text.err"

  # Another active environment is not the project's.
  mkdir -p "$TEST_TEMP_DIR/elsewhere"
  run status_zsh '
    export VIRTUAL_ENV="$2/elsewhere"
    zdx-status --json 2>/dev/null
  ' "$project" "$TEST_TEMP_DIR"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | "$STATUS_REAL_JQ" -e '
    .project.virtual_env_active == true
    and .project.project_venv_active == false'
}

@test "zdx status: a detached HEAD, a merge in progress, and hostile names stay data" {
  [ -n "$STATUS_REAL_JQ" ] || skip "jq is not installed"
  local repo="$TEST_TEMP_DIR/repo"
  # Git refuses spaces in a branch name but accepts every other character
  # here, including command substitution, quotes, and separators.
  local hostile='feat/$(>pwned);"q'"'"'s|`id`'
  mkdir -p "$repo"
  git init -q -b main "$repo"
  git -C "$repo" config user.email "jane@example.com"
  git -C "$repo" config user.name "Jane Doe"
  printf 'base\n' > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -q -m base
  git -C "$repo" checkout -q -b "$hostile"
  printf 'theirs\n' > "$repo/file.txt"
  git -C "$repo" commit -q -am theirs

  run status_zsh 'zdx-status --json 2>/dev/null' "$repo"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" \
    | "$STATUS_REAL_JQ" -e --arg branch "$hostile" '.repository.branch == $branch'
  run status_zsh 'NO_COLOR=1 zdx-status' "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Branch:            $hostile (no upstream)"* ]]
  [ ! -e "$repo/pwned" ]

  git -C "$repo" checkout -q main
  printf 'ours\n' > "$repo/file.txt"
  git -C "$repo" commit -q -am ours
  run git -C "$repo" merge -q "$hostile"
  [ "$status" -ne 0 ]
  run status_zsh 'zdx-status --json 2>/dev/null' "$repo"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | "$STATUS_REAL_JQ" -e '
    .repository.operation == "merge" and .repository.conflicted == 1'
  run status_zsh 'NO_COLOR=1 zdx-status' "$repo"
  [[ "$output" == *"Operation:         merge in progress"* ]]

  git -C "$repo" merge --abort
  git -C "$repo" checkout -q --detach HEAD
  run status_zsh 'zdx-status --json 2>/dev/null' "$repo"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | "$STATUS_REAL_JQ" -e '
    .repository.detached == true and .repository.branch == null
    and (.repository.commit | test("^[0-9a-f]{40}$"))
    and .repository.upstream == null and .repository.ahead == null'
  run status_zsh 'NO_COLOR=1 zdx-status' "$repo"
  [[ "$output" == *"Branch:            detached at "* ]]
}

@test "zdx status: every external probe is bounded and a timeout leaves null facts" {
  [ -n "$STATUS_REAL_JQ" ] || skip "jq is not installed"
  local repo="$HOME/workspaces/github/personal/demo"
  make_status_repo "$repo"

  run status_zsh '
    _zdx_run_with_timeout() {
      print -r -- "$1 $2 $3" >> "$STATUS_PROBE_LOG"
      if [[ "$2 $3 $4" == "git --no-optional-locks status" ]]; then
        return 124
      fi
      shift
      "$@"
    }
    zdx-status --json
  ' "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"git status timed out after 5s"* ]]
  printf '%s\n' "$output" | grep '^{' | "$STATUS_REAL_JQ" -e '
    .repository.root != null and .repository.branch == null
    and .repository.staged == null and .repository.ahead == null
    and .repository.user_email == "jane@example.com"'
  grep -Eq '^[1-9][0-9]* git rev-parse$' "$STATUS_PROBE_LOG"
  grep -Eq '^[1-9][0-9]* git --no-optional-locks$' "$STATUS_PROBE_LOG"
  grep -Eq '^[1-9][0-9]* git config$' "$STATUS_PROBE_LOG"
  grep -Eq '^[1-9][0-9]* df -P$' "$STATUS_PROBE_LOG"
  # Nothing reaches the network or asks for privilege.
  run grep -Eq ' (fetch|pull|ls-remote|sudo|curl|gh) ' "$STATUS_PROBE_LOG"
  [ "$status" -eq 1 ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "zdx status: --json without jq reports the capability and prints nothing" {
  run zsh -f -c '
    source "$1/functions.zsh" || exit 90
    _zdx_status_collect() { print -r -- UNEXPECTED_PROBE; }
    path=("$2")
    zdx-status --json >"$3/out" 2>"$3/err"
    rc=$?
    path=(/usr/bin /bin)
    print -r -- "rc=$rc"
    cat "$3/err"
    [[ ! -s "$3/out" ]]
  ' _ "$TEST_SUITE_ROOT" "$TEST_TEMP_DIR/empty-bin" "$TEST_TEMP_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=1"* ]]
  [[ "$output" == *"jq is required for zdx status --json"* ]]
  [[ "$output" != *UNEXPECTED_PROBE* ]]
}

@test "zdx status: jq builds one compact monochrome line from arguments only" {
  [ -n "$STATUS_REAL_JQ" ] || skip "jq is not installed"
  cat > "$TEST_MOCK_BIN/jq" <<EOF
#!$BASH
printf '%s\n' "\$@" > "$TEST_TEMP_DIR/jq-arguments"
exec "$STATUS_REAL_JQ" "\$@"
EOF
  chmod +x "$TEST_MOCK_BIN/jq"
  local project="$TEST_TEMP_DIR/project"
  mkdir -p "$project"

  run status_zsh 'zdx-status --json 2>/dev/null' "$project"
  [ "$status" -eq 0 ]
  grep -Fxq -- '-c' "$TEST_TEMP_DIR/jq-arguments"
  grep -Fxq -- '-n' "$TEST_TEMP_DIR/jq-arguments"
  grep -Fxq -- '-M' "$TEST_TEMP_DIR/jq-arguments"
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
  grep -Fxq -- '--arg' "$TEST_TEMP_DIR/jq-arguments"
  grep -Fxq -- '--argjson' "$TEST_TEMP_DIR/jq-arguments"
  # No JSON text is printed by hand.
  run grep -E "(printf|print -r --) +['\"][{[]" \
    "$TEST_SUITE_ROOT/functions/zdx-status.zsh"
  [ "$status" -eq 1 ]
}

@test "zdx status: WireGuard interfaces come from sysfs device types on Linux" {
  local net="$TEST_TEMP_DIR/net"
  mkdir -p "$net/wg0" "$net/eth0" "$net/wg-office"
  printf 'DEVTYPE=wireguard\nINTERFACE=wg0\n' > "$net/wg0/uevent"
  printf 'INTERFACE=eth0\n' > "$net/eth0/uevent"
  printf 'INTERFACE=wg-office\nDEVTYPE=wireguard' > "$net/wg-office/uevent"

  run zsh -f -c '
    source "$1/functions.zsh" || exit 90
    OSTYPE=linux-gnu
    _zdx_status_wireguard_interfaces "$2" || exit 1
    print -r -- "present:${(j:,:)reply}"
    _zdx_status_wireguard_interfaces "$2/eth0" || exit 2
    print -r -- "absent:${#reply}"
    OSTYPE=darwin23
    _zdx_status_wireguard_interfaces "$2" && exit 3
    print -r -- "darwin:unknown"
  ' _ "$TEST_SUITE_ROOT" "$net"
  [ "$status" -eq 0 ]
  [[ "$output" == *"present:wg-office,wg0"* ]]
  [[ "$output" == *"absent:0"* ]]
  [[ "$output" == *"darwin:unknown"* ]]
}

@test "zdx status: platform, reboot flag, and load average read fixtures" {
  local root="$TEST_TEMP_DIR/root"
  mkdir -p "$root/proc/sys/kernel" "$root/proc/sys/fs/binfmt_misc" \
    "$root/var/run" "$root/etc"
  printf '6.6.87.2-microsoft-standard-WSL2\n' \
    > "$root/proc/sys/kernel/osrelease"
  printf '0.25 0.50 1.75 1/100 42\n' > "$root/proc/loadavg"

  run zsh -f -c '
    source "$1/functions.zsh" || exit 90
    unset WSL_DISTRO_NAME WSL_INTEROP
    OSTYPE=linux-gnu
    _zdx_status_platform "$2/proc"; print -r -- "wsl2:$REPLY"
    print -r -- "4.4.0-19041-Microsoft" > "$2/proc/sys/kernel/osrelease"
    _zdx_status_platform "$2/proc"; print -r -- "wsl1:$REPLY"
    print -r -- "6.8.0-45-generic" > "$2/proc/sys/kernel/osrelease"
    _zdx_status_platform "$2/proc"; print -r -- "linux:$REPLY"
    WSL_DISTRO_NAME=Ubuntu _zdx_status_platform "$2/proc"
    print -r -- "variable:$REPLY"
    _zdx_status_reboot_required "$2"; print -r -- "unmaintained:$REPLY"
    : > "$2/etc/debian_version"
    _zdx_status_reboot_required "$2"; print -r -- "clear:$REPLY"
    : > "$2/var/run/reboot-required"
    _zdx_status_reboot_required "$2"; print -r -- "required:$REPLY"
    _zdx_status_load_average "$2/proc"; print -r -- "load:${(j: :)reply}"
    print -r -- "1.0 nope 2.0" > "$2/proc/loadavg"
    _zdx_status_load_average "$2/proc"; print -r -- "bad:${#reply}"
    OSTYPE=freebsd14
    _zdx_status_platform "$2/proc"; print -r -- "other:[$REPLY]"
    OSTYPE=darwin23
    WSL_DISTRO_NAME=Ubuntu _zdx_status_platform "$2/proc"
    print -r -- "darwin:$REPLY"
    _zdx_status_reboot_required "$2"; print -r -- "darwin-reboot:$REPLY"
  ' _ "$TEST_SUITE_ROOT" "$root"
  [ "$status" -eq 0 ]
  local expected
  for expected in wsl2:WSL2 wsl1:WSL1 linux:Linux variable:WSL2 \
    unmaintained:null clear:false required:true "load:0.25 0.50 1.75" \
    bad:0 "other:[]" darwin:macOS darwin-reboot:null; do
    [[ "$output" == *"$expected"* ]] || {
      printf 'missing %s in:\n%s\n' "$expected" "$output"
      false
    }
  done
}

@test "zdx status: macOS reports null where facts are not knowable without privilege" {
  [ -n "$STATUS_REAL_JQ" ] || skip "jq is not installed"
  cat > "$TEST_MOCK_BIN/sysctl" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "-n vm.loadavg" ]] || exit 1
printf '{ 1.50 1.25 1.00 }\n'
EOF
  # A recording git proves the Command Line Tools placeholder never runs.
  cat > "$TEST_MOCK_BIN/git" <<EOF
#!/usr/bin/env bash
printf 'git %s\n' "\$*" >> "$STATUS_PROBE_LOG"
exit 1
EOF
  # xcode-select reports no developer directory, as before a CLT install.
  printf '#!/usr/bin/env bash\nexit 2\n' > "$TEST_MOCK_BIN/xcode-select"
  chmod +x "$TEST_MOCK_BIN/sysctl" "$TEST_MOCK_BIN/git" \
    "$TEST_MOCK_BIN/xcode-select"
  local repo="$TEST_TEMP_DIR/repo"
  mkdir -p "$repo"

  run zsh -f -c '
    source "$1/functions.zsh" || exit 90
    cd "$2" || exit 91
    OSTYPE=darwin23
    hash git=/usr/bin/git
    unset VIRTUAL_ENV
    zdx-status --json 2>/dev/null
  ' _ "$TEST_SUITE_ROOT" "$repo"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | "$STATUS_REAL_JQ" -e '
    .repository == null
    and .vpn.wireguard_interfaces == null
    and .host.platform == "macOS"
    and .host.reboot_required == null
    and .host.load_average == [1.5, 1.25, 1]'
  [ ! -s "$STATUS_PROBE_LOG" ]

  run zsh -f -c '
    source "$1/functions.zsh" || exit 90
    cd "$2" || exit 91
    OSTYPE=darwin23
    NO_COLOR=1 zdx-status
  ' _ "$TEST_SUITE_ROOT" "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WireGuard:         unknown on macOS"* ]]
  [[ "$output" == *"Reboot required:   unknown"* ]]
}

@test "zdx status: settings, plugins, and the byte formatter are exact" {
  run zsh -f -c '
    source "$1/functions.zsh" || exit 90
    local REPLY=""
    for bytes in 0 1023 1024 1536 1048576 1073741824 5497558138880; do
      _zdx_status_format_bytes "$bytes"
      print -r -- "$bytes=$REPLY"
    done
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0=0 B"* && "$output" == *"1023=1023 B"* ]]
  [[ "$output" == *"1024=1.0 KiB"* && "$output" == *"1536=1.5 KiB"* ]]
  [[ "$output" == *"1048576=1.0 MiB"* && "$output" == *"1073741824=1.0 GiB"* ]]
  [[ "$output" == *"5497558138880=5.0 TiB"* ]]

  [ -n "$STATUS_REAL_JQ" ] || skip "jq is not installed"
  mkdir -p "$TEST_TEMP_DIR/here"
  run status_zsh '
    ZDX_TELEMETRY=true ZDX_VERBOSE=1
    typeset -ga ZDX_LOADED_PLUGINS=(alpha)
    zdx-status --json 2>/dev/null
  ' "$TEST_TEMP_DIR/here"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | "$STATUS_REAL_JQ" -e '
    .zdx.telemetry == true and .zdx.verbose == true
    and .zdx.custom_plugins == 1'
}
