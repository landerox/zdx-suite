#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "zdx contract: master loader is standalone, idempotent, and evaluator-free" {
  local source_file
  for source_file in zdx-common.zsh zdx-menu.zsh; do
    run zsh -n "$TEST_SUITE_ROOT/functions/$source_file"
    [ "$status" -eq 0 ]
  done

  run grep -Eq \
    '(^|[[:space:]])eval([[:space:]]|$)|git-common[.]zsh' \
    "$TEST_SUITE_ROOT/functions/zdx-common.zsh" \
    "$TEST_SUITE_ROOT/functions/zdx-menu.zsh"
  [ "$status" -eq 1 ]
  grep -Fq \
    'source "$_zdx_menu_common_file"' \
    "$TEST_SUITE_ROOT/functions/zdx-menu.zsh"

  run zsh -f -c '
    emulate -R zsh
    source "$1/functions/zdx-menu.zsh" || exit
    first_definition="${functions[zdx]}"
    source "$1/functions/zdx-menu.zsh" || exit
    [[ -n "${_ZDX_MENU_SOURCED:-}" \
      && "${functions[zdx]}" == "$first_definition" ]]
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "zdx contract: missing exact-root common fails without a loaded sentinel" {
  local broken_root="$TEST_TEMP_DIR/broken-functions"
  mkdir -p "$broken_root"
  cp "$TEST_SUITE_ROOT/functions/zdx-menu.zsh" \
    "$broken_root/zdx-menu.zsh"

  run zsh -f -c '
    emulate -R zsh
    source "$1/zdx-menu.zsh"
    loader_rc=$?
    (( loader_rc != 0 )) || exit 1
    [[ -z "${_ZDX_MENU_SOURCED:-}" ]]
  ' _ "$broken_root"

  [ "$status" -eq 0 ]
  [[ "$output" == *"failed to load zdx-common.zsh"* ]]
}

@test "zdx contract: a forged common sentinel cannot bypass loader checks" {
  run zsh -f -c '
    emulate -R zsh
    typeset -g _ZDX_COMMON_SOURCED=1
    source "$1/functions/zdx-menu.zsh"
    loader_rc=$?
    (( loader_rc != 0 )) || exit 1
    [[ -z "${_ZDX_MENU_SOURCED:-}" ]]
  ' _ "$TEST_SUITE_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"zdx-common.zsh loaded incompletely"* ]]
}

@test "zdx contract: help uses stderr and invalid grammar returns status 2" {
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions/zdx-menu.zsh" || exit
    zdx --help >"$2/help.stdout" 2>"$2/help.stderr" || exit
    [[ ! -s "$2/help.stdout" && -s "$2/help.stderr" ]] || exit 1

    zdx-menu --help >"$2/menu-help.stdout" 2>"$2/menu-help.stderr" || exit
    [[ ! -s "$2/menu-help.stdout" && -s "$2/menu-help.stderr" ]] || exit 1

    zdx --unknown >/dev/null 2>&1
    (( $? == 2 )) || exit 1
    zdx-menu unexpected >/dev/null 2>&1
    (( $? == 2 )) || exit 1
    zdx help extra >/dev/null 2>&1
    (( $? == 2 ))
  ' _ "$TEST_SUITE_ROOT" "$TEST_TEMP_DIR"
  [ "$status" -eq 0 ]
}

@test "zdx contract: release version agrees across metadata CLI lock and changelog" {
  local project_version=""
  local commitizen_version=""
  local locked_version=""
  local changelog_version=""

  project_version=$(awk -F '"' '
    /^version = "/ { print $2; exit }
  ' "$TEST_SUITE_ROOT/pyproject.toml")
  commitizen_version=$(awk -F '"' '
    /^\[tool[.]commitizen\]$/ { in_commitizen=1; next }
    in_commitizen && /^version = "/ { print $2; exit }
  ' "$TEST_SUITE_ROOT/pyproject.toml")
  locked_version=$(awk -F '"' '
    /^name = "zdx-suite"$/ { in_zdx=1; next }
    in_zdx && /^version = "/ { print $2; exit }
  ' "$TEST_SUITE_ROOT/uv.lock")
  changelog_version=$(awk '
    /^## \[[0-9]+[.][0-9]+[.][0-9]+\]/ {
      version=$2
      gsub(/^\[|\]$/, "", version)
      print version
      exit
    }
  ' "$TEST_SUITE_ROOT/CHANGELOG.md")

  [ -n "$project_version" ]
  [ "$commitizen_version" = "$project_version" ]
  [ "$locked_version" = "$project_version" ]
  [ "$changelog_version" = "$project_version" ]
  grep -Fqx \
    "[$project_version]: https://github.com/landerox/zdx-suite/releases/tag/$project_version" \
    "$TEST_SUITE_ROOT/CHANGELOG.md"

  local release_notes=""
  release_notes=$(awk -v marker="## [${project_version}]" '
    index($0, marker) == 1 { flag=1; next }
    flag && (index($0, "## [") == 1 \
      || index($0, "[Unreleased]:") == 1) { exit }
    flag { print }
  ' "$TEST_SUITE_ROOT/CHANGELOG.md")
  [[ "$release_notes" == *"### Overview"* ]]

  run zsh -f -c '
    emulate -R zsh
    source "$1/functions/zdx-menu.zsh" || exit
    zdx --version
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "ZDX (Zsh Developer Experience) v$project_version" ]
}

@test "zdx contract: release checksum remains portable after asset download" {
  local workflow="$TEST_SUITE_ROOT/.github/workflows/release.yml"

  grep -Fq 'archive_name="zdx-${version}.tar.gz"' "$workflow"
  grep -Fq 'archive="dist/${archive_name}"' "$workflow"
  grep -Fq 'cd dist' "$workflow"
  grep -Fq \
    'sha256sum "${archive_name}" > "${archive_name}.sha256"' \
    "$workflow"
  grep -Fq \
    'sha256sum --check "${archive_name}.sha256"' \
    "$workflow"
  run grep -Fq \
    'sha256sum "${archive}" > "${archive}.sha256"' \
    "$workflow"
  [ "$status" -eq 1 ]
}

@test "zdx contract: local push and CI share the full quality gate" {
  local justfile="$TEST_SUITE_ROOT/Justfile"
  local pre_commit="$TEST_SUITE_ROOT/.pre-commit-config.yaml"
  local workflow="$TEST_SUITE_ROOT/.github/workflows/lint.yml"

  grep -Fqx 'check: lock-check lint primitives-check pre-commit-run audit test' "$justfile"
  grep -Fqx '    uv lock --check' "$justfile"
  grep -Fqx \
    '    uv run --locked pre-commit run --all-files' "$justfile"
  grep -Fq \
    'uv export --locked --quiet --format requirements-txt' "$justfile"
  grep -Fq \
    'uv run --locked pip-audit --disable-pip --requirement' "$justfile"
  grep -Fqx '    typeset -a bats_options=(--print-output-on-failure)' "$justfile"
  grep -Fqx '    (( $# > 0 )) || set -- test/' "$justfile"
  grep -Fqx '    bats "${bats_options[@]}" "$@"' "$justfile"
  grep -Fqx \
    'default_install_hook_types: [pre-commit, commit-msg, pre-push]' \
    "$pre_commit"
  grep -Fqx 'minimum_pre_commit_version: "3.2.0"' "$pre_commit"
  grep -Fqx 'default_stages: [pre-commit]' "$pre_commit"
  awk '
    function verify() {
      if (hook_id == "") return
      if (hook_id == "conventional-pre-commit") {
        if (hook_stage != "commit-msg") invalid=1
      } else if (hook_id == "repository-quality-gates") {
        if (hook_stage != "pre-push") invalid=1
      } else if (hook_stage != "pre-commit") {
        invalid=1
      }
    }
    /^      - id: / {
      verify()
      hook_id=$3
      hook_stage=""
      hook_count++
      next
    }
    /^        stages: \[[a-z-]+\]$/ {
      hook_stage=$2
      gsub(/^\[|\]$/, "", hook_stage)
    }
    END {
      verify()
      exit invalid || hook_count != 21
    }
  ' "$pre_commit"
  grep -Fq 'entry: just check' "$pre_commit"
  grep -Fq 'stages: [pre-push]' "$pre_commit"
  grep -Fq 'run: uv sync --locked' "$workflow"
  grep -Fq 'run: just check' "$workflow"
  # GNU parallel lets the CI gate run the suite with `bats --jobs`.
  grep -Fq 'sudo apt-get install -y bats fzf just parallel zsh' "$workflow"
}

@test "zdx contract: just test runs BATS in parallel only with GNU parallel" {
  local project="$TEST_TEMP_DIR/just-test"
  local tools="$TEST_TEMP_DIR/just-test-tools"
  local with_gnu="$TEST_TEMP_DIR/just-test-gnu"
  local with_other="$TEST_TEMP_DIR/just-test-other"
  local just_bin="" tool=""
  just_bin=$(command -v just)
  mkdir -p "$project/test" "$tools" "$with_gnu" "$with_other"
  cp "$TEST_SUITE_ROOT/Justfile" "$project/"
  # The recipe needs only zsh and getconf; the real GNU parallel stays off
  # PATH so each case controls which `parallel` the recipe finds.
  for tool in zsh getconf; do
    ln -s "$(command -v "$tool")" "$tools/$tool"
  done
  printf '#!/bin/sh\nprintf "[%%s]" "$@"\nprintf "\\n"\n' > "$tools/bats"
  printf '#!/bin/sh\nprintf "GNU parallel 20231122\\n"\n' > "$with_gnu/parallel"
  printf '#!/bin/sh\nprintf "usage: parallel [OPTIONS] command -- arguments\\n" >&2\nexit 1\n' \
    > "$with_other/parallel"
  chmod +x "$tools/bats" "$with_gnu/parallel" "$with_other/parallel"

  run env PATH="$with_gnu:$tools" BATS_JOBS=3 \
    "$just_bin" --justfile "$project/Justfile" --working-directory "$project" test
  [ "$status" -eq 0 ]
  [ "$output" = "[--print-output-on-failure][--jobs][3][test/]" ]

  run env PATH="$with_gnu:$tools" BATS_JOBS=1 \
    "$just_bin" --justfile "$project/Justfile" --working-directory "$project" \
    test test/a.bats 'test/b c.bats'
  [ "$status" -eq 0 ]
  [ "$output" = "[--print-output-on-failure][test/a.bats][test/b c.bats]" ]

  run env PATH="$with_other:$tools" BATS_JOBS=4 \
    "$just_bin" --justfile "$project/Justfile" --working-directory "$project" test
  [ "$status" -eq 0 ]
  [[ "$output" == *"GNU parallel is not installed; running the BATS suite serially."* ]]
  [ "${lines[${#lines[@]}-1]}" = "[--print-output-on-failure][test/]" ]

  run env PATH="$with_gnu:$tools" BATS_JOBS=two \
    "$just_bin" --justfile "$project/Justfile" --working-directory "$project" test
  [ "$status" -eq 2 ]
  [[ "$output" == *"BATS_JOBS must be a positive integer, not 'two'."* ]]
  [[ "$output" != *"[--print-output-on-failure]"* ]]
}

@test "zdx contract: the local gate rejects a stale lock without rewriting it" {
  local stale_project="$TEST_TEMP_DIR/stale-lock-project"
  mkdir -p "$stale_project"
  cp "$TEST_SUITE_ROOT/Justfile" \
    "$TEST_SUITE_ROOT/README.md" \
    "$TEST_SUITE_ROOT/pyproject.toml" \
    "$TEST_SUITE_ROOT/uv.lock" \
    "$stale_project/"
  # Change only the first matching line, the project version, to one that no
  # release uses, so the copied lock is stale whatever the current version is.
  perl -0pi -e 's/^version = "[^"]*"/version = "999.0.0"/m' \
    "$stale_project/pyproject.toml"
  grep -qx 'version = "999.0.0"' "$stale_project/pyproject.toml"

  local lock_before=""
  lock_before=$(sha256_file "$stale_project/uv.lock")

  run bash -c 'cd "$1" && just lock-check' _ "$stale_project"

  [ "$status" -ne 0 ]
  [ "$(sha256_file "$stale_project/uv.lock")" = "$lock_before" ]
  [[ "$output" == *"lock"* || "$output" == *"Lock"* ]]
}

@test "zdx contract: the centralized user-config template remains installable" {
  local template_path="$TEST_SUITE_ROOT/.config/zdx/config.zsh.example"
  local installer_home="$TEST_TEMP_DIR/installer-home"
  local custom_root="$installer_home/.oh-my-zsh/custom"

  [ -f "$template_path" ]
  [ ! -e "$TEST_SUITE_ROOT/config.zsh.example" ]
  run zsh -n "$template_path"
  [ "$status" -eq 0 ]
  run grep -Eq 'ZDX_AUTO_UPDATE|ZDX_KEY_VPN|ZDX_KEY_SYS|WS_SSH_CONNECT_TIMEOUT|HF_PYTHON|DOCKER_CONTEXT' "$template_path"
  [ "$status" -eq 1 ]
  grep -Fq '# WS_BASE_DIR=' "$template_path"
  grep -Fq '# VPN_MENU_REPORT_RETENTION=20' "$template_path"
  grep -Fq \
    '.config/zdx/config.zsh.example' \
    "$TEST_SUITE_ROOT/README.md"

  mkdir -p "$custom_root/plugins"
  printf '# Controlled Oh My Zsh entrypoint fixture.\n' \
    > "$installer_home/.oh-my-zsh/oh-my-zsh.sh"
  run env HOME="$installer_home" ZSH="$installer_home/.oh-my-zsh" \
    ZSH_CUSTOM="$custom_root" \
    bash "$TEST_SUITE_ROOT/scripts/install.sh" --yes

  [ "$status" -eq 0 ]
  [ -L "$custom_root/plugins/zdx-suite" ]
  cmp "$template_path" "$installer_home/.config/zdx/config.zsh"

  run zsh -f -c '
    emulate -R zsh
    zmodload zsh/stat || exit 1
    local -A directory_state=() file_state=()
    zstat -LH directory_state -- "$1" || exit 1
    zstat -LH file_state -- "$2" || exit 1
    printf "%03o:%03o\n" \
      $(( directory_state[mode] & 8#777 )) \
      $(( file_state[mode] & 8#777 ))
  ' _ "$installer_home/.config/zdx" \
    "$installer_home/.config/zdx/config.zsh"

  [ "$status" -eq 0 ]
  [ "$output" = "700:600" ]
}

@test "zdx contract: built-in dispatch forwards shell-bearing arguments literally" {
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions/zdx-menu.zsh" || exit
    git-menu() {
      printf "count=%d\n" "$#"
      local argument=""
      for argument in "$@"; do
        printf "<%s>\n" "$argument"
      done
    }
    zdx git "$(printf "%s" "\$(touch $2/evaluated)")" \
      "semi; touch $2/separated" "two words"
  ' _ "$TEST_SUITE_ROOT" "$TEST_TEMP_DIR"

  [ "$status" -eq 0 ]
  [[ "$output" == *"count=3"* ]]
  [[ "$output" == *'<$(touch '*"/evaluated)>"* ]]
  [[ "$output" == *"<semi; touch "*"separated>"* ]]
  [[ "$output" == *"<two words>"* ]]
  [ ! -e "$TEST_TEMP_DIR/evaluated" ]
  [ ! -e "$TEST_TEMP_DIR/separated" ]
}

@test "zdx contract: plugin dispatch requires exact loaded membership and a function" {
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions/zdx-menu.zsh" || exit
    typeset -ga ZDX_LOADED_PLUGINS=(sample-extra sample)
    sample-menu() {
      printf "plugin-count=%d\n" "$#"
      local argument=""
      for argument in "$@"; do
        printf "[%s]\n" "$argument"
      done
    }
    zdx sample "\$(touch $2/plugin-eval)" "a; touch $2/plugin-split" \
      "literal space" || exit

    ZDX_LOADED_PLUGINS=(sample-extra)
    zdx sample >/dev/null 2>&1
    (( $? == 2 )) || exit 1

    ZDX_LOADED_PLUGINS=(missing)
    zdx missing >/dev/null 2>&1
    (( $? == 1 ))
  ' _ "$TEST_SUITE_ROOT" "$TEST_TEMP_DIR"

  [ "$status" -eq 0 ]
  [[ "$output" == *"plugin-count=3"* ]]
  [[ "$output" == *'[$(touch '*"/plugin-eval)]"* ]]
  [[ "$output" == *"[a; touch "*"plugin-split]"* ]]
  [[ "$output" == *"[literal space]"* ]]
  [ ! -e "$TEST_TEMP_DIR/plugin-eval" ]
  [ ! -e "$TEST_TEMP_DIR/plugin-split" ]
}

@test "zdx contract: custom plugins cannot collide with reserved wrapper names" {
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions/zdx-menu.zsh" || exit
    typeset -ga ZDX_LOADED_PLUGINS=(git help)
    help-menu() {
      print -r -- "UNEXPECTED_HELP_PLUGIN"
    }
    _zdx_menu_model >/dev/null
    model_rc=$?
    (( model_rc == 0 )) || exit 1
    _zdx_dispatch_plugin help >/dev/null 2>&1
    (( $? == 2 ))
  ' _ "$TEST_SUITE_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping loaded plugin with reserved name: 'git'."* ]]
  [[ "$output" == *"Skipping loaded plugin with reserved name: 'help'."* ]]
  [[ "$output" != *"UNEXPECTED_HELP_PLUGIN"* ]]
}

@test "zdx contract: forged menu selection is outside the exact snapshot" {
  run zsh -f -c '
    emulate -R zsh
    export PATH="$2:$PATH"
    source "$1/functions/zdx-menu.zsh" || exit
    _zdx_fzf_capture() {
      REPLY="Injected|git|not from the model"
      return 0
    }
    git-menu() {
      print -r -- "UNEXPECTED_DISPATCH"
    }
    zdx-menu
  ' _ "$TEST_SUITE_ROOT" "$TEST_MOCK_BIN"

  [ "$status" -eq 1 ]
  [[ "$output" == *"not in the ZDX menu snapshot"* ]]
  [[ "$output" != *"UNEXPECTED_DISPATCH"* ]]
}

@test "zdx contract: exact menu row reaches the fixed built-in dispatcher" {
  run zsh -f -c '
    emulate -R zsh
    export PATH="$2:$PATH"
    source "$1/functions/zdx-menu.zsh" || exit
    _zdx_fzf_capture() {
      local menu_input=""
      menu_input=$(<&0)
      local menu_row=""
      for menu_row in "${(@f)menu_input}"; do
        if [[ "$menu_row" == *"|git|"* ]]; then
          REPLY="$menu_row"
          return 0
        fi
      done
      return 1
    }
    git-menu() {
      print -r -- "fixed-git-route"
    }
    zdx-menu
  ' _ "$TEST_SUITE_ROOT" "$TEST_MOCK_BIN"

  [ "$status" -eq 0 ]
  [[ "$output" == *"fixed-git-route"* ]]
}

@test "zdx contract: cancellation succeeds and private capture is removed" {
  export MOCK_FZF_MODE="cancel"
  export MOCK_FZF_STATUS="130"

  run zsh -f -c '
    emulate -R zsh
    export HOME="$2"
    export PATH="$3:$PATH"
    export TMPDIR="$HOME/tmp"
    mkdir -p "$TMPDIR"
    source "$1/functions/zdx-menu.zsh" || exit
    zdx-menu || exit
    local -a leftovers=("$TMPDIR"/zdx-menu-fzf.*(N))
    (( ${#leftovers[@]} == 0 ))
  ' _ "$TEST_SUITE_ROOT" "$HOME" "$TEST_MOCK_BIN"

  [ "$status" -eq 0 ]
}

@test "zdx contract: NO_COLOR and dumb-terminal diagnostics contain no ANSI" {
  run zsh -f -c '
    emulate -R zsh
    export NO_COLOR=1
    source "$1/functions/zdx-menu.zsh" || exit
    _zdx_error "unsafe %s text"
  ' _ "$TEST_SUITE_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[error] unsafe %s text"* ]]
  [[ "$output" != *$'\033'* ]]

  run zsh -f -c '
    emulate -R zsh
    unset NO_COLOR
    export TERM=dumb
    source "$1/functions/zdx-menu.zsh" || exit
    _zdx_error "plain dumb terminal"
  ' _ "$TEST_SUITE_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[error] plain dumb terminal"* ]]
  [[ "$output" != *$'\033'* ]]
  grep -Fq \
    '"${TERM:-}" != "dumb"' \
    "$TEST_SUITE_ROOT/functions/zdx-common.zsh"
}

@test "zdx contract: row helpers reject delimiter and newline injection" {
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions/zdx-menu.zsh" || exit
    _zdx_menu_entry "Unsafe|Label" git "description" >/dev/null 2>&1
    (( $? == 2 )) || exit 1
    _zdx_menu_section "Unsafe"$'\''\n'\''"Title" "description" \
      >/dev/null 2>&1
    (( $? == 2 ))
  ' _ "$TEST_SUITE_ROOT"

  [ "$status" -eq 0 ]
}

@test "zdx doctor: loading is silent, idempotent, and completes before its sentinel" {
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions/zdx-doctor.zsh" || exit
    first_definition="${functions[zdx-doctor]}"
    source "$1/functions/zdx-doctor.zsh" || exit
    [[ -n "${_ZDX_DOCTOR_SOURCED:-}" \
      && "${functions[zdx-doctor]}" == "$first_definition" ]]
  ' _ "$TEST_SUITE_ROOT"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(awk 'NF { line=$0 } END { print line }' \
    "$TEST_SUITE_ROOT/functions/zdx-doctor.zsh")" \
    = "typeset -g _ZDX_DOCTOR_SOURCED=1" ]
}

@test "zdx doctor: help uses stderr and invalid grammar stops before probes" {
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions/zdx-doctor.zsh" || exit
    zdx-doctor --help >"$2/help.stdout" 2>"$2/help.stderr" || exit
    [[ ! -s "$2/help.stdout" && -s "$2/help.stderr" ]] || exit 1

    zdx-doctor --unknown >"$2/invalid.stdout" 2>"$2/invalid.stderr"
    (( $? == 2 )) || exit 1
    [[ ! -s "$2/invalid.stdout" ]] || exit 1
    grep -q "Unknown zdx-doctor option" "$2/invalid.stderr" || exit 1
    ! grep -q "Core Dependencies" "$2/invalid.stderr" || exit 1

    zdx-doctor help extra >/dev/null 2>&1
    (( $? == 2 ))
  ' _ "$TEST_SUITE_ROOT" "$TEST_TEMP_DIR"

  [ "$status" -eq 0 ]
}

@test "zdx doctor: diagnostics honor plain terminals and render controls visibly" {
  run zsh -f -c '
    emulate -R zsh
    export NO_COLOR=1
    export TERM=xterm-256color
    source "$1/functions/zdx-doctor.zsh" || exit
    _zdx_doctor_error "unsafe %s"$'\''\n'\''"value"
    _zdx_doctor_header "plain"
  ' _ "$TEST_SUITE_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"unsafe %s"* ]]
  [[ "$output" != *$'\033'* ]]

  run zsh -f -c '
    emulate -R zsh
    unset NO_COLOR
    export TERM=dumb
    source "$1/functions/zdx-doctor.zsh" || exit
    _zdx_doctor_warn "plain dumb terminal"
  ' _ "$TEST_SUITE_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"plain dumb terminal"* ]]
  [[ "$output" != *$'\033'* ]]
}

# Doctor install fixtures: a logging apt-get and brew in the mock bin. The
# trust predicate is replaced only where a test says so, because mock programs
# belong to the test user rather than root.
doctor_install_fixture() {
  export MOCK_APT_LOG="$TEST_TEMP_DIR/apt-get.log"
  : > "$MOCK_APT_LOG"
  local manager
  for manager in apt-get brew; do
    cat > "$TEST_MOCK_BIN/$manager" <<EOF
#!/usr/bin/env bash
{
  printf '$manager'
  printf ' <%s>' "\$@"
  printf '\n'
} >> "\${MOCK_APT_LOG:?}"
[[ "\${MOCK_APT_FAIL:-}" != "\$1" ]]
EOF
    chmod +x "$TEST_MOCK_BIN/$manager"
  done
}

doctor_install_prelude() {
  cat <<'ZSH'
    emulate -R zsh
    source "$ZDX_ROOT/functions/zdx-doctor.zsh" || exit 90
    _zdx_doctor_program_trusted() { [[ "$1" == /* && -x "$1" ]]; }
    _zdx_doctor_confirm() { return 0; }
ZSH
}

@test "zdx doctor: package installation uses validated literal arrays without eval" {
  doctor_install_fixture
  export ZDX_ROOT="$TEST_SUITE_ROOT"
  export MOCK_SUDO_ALLOW="__validate__,true,apt-get"

  run grep -Eq '(^|[[:space:]])eval([[:space:]]|$)' \
    "$TEST_SUITE_ROOT/functions/zdx-doctor.zsh"
  [ "$status" -eq 1 ]

  run zsh -f -c "$(doctor_install_prelude)"'
    _zdx_doctor_install_plan apt "safe;touch $1/package-evaluated" 2>/dev/null
  ' _ "$TEST_TEMP_DIR"
  [ "$status" -eq 2 ]
  [ ! -e "$TEST_TEMP_DIR/package-evaluated" ]
  [ ! -s "$MOCK_APT_LOG" ]
  [ ! -s "$MOCK_SUDO_LOG" ]

  run zsh -f -c "$(doctor_install_prelude)"'
    local -a missing=(one two)
    _zdx_doctor_run_install 0 apt missing pkg.one pkg-two
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_APT_LOG")" = $'apt-get <update>\napt-get <install> <-y> <pkg.one> <pkg-two>' ]
  # Only sudo -v and sudo -n are used, each package command by absolute path.
  run grep -c '' "$MOCK_SUDO_LOG"
  [ "$output" -eq 5 ]
  [ "$(sed -n 1p "$MOCK_SUDO_LOG")" = "sudo -v" ]
  [ "$(grep -cvE '^sudo (-v|-n true|-n /[^ ]+/apt-get (update|install -y pkg\.one pkg-two))$' "$MOCK_SUDO_LOG")" -eq 0 ]
}

@test "zdx doctor: the install plan names absolute programs and dry runs install nothing" {
  doctor_install_fixture
  export ZDX_ROOT="$TEST_SUITE_ROOT"
  run zsh -f -c "$(doctor_install_prelude)"'
    _zdx_doctor_install_plan apt jq || exit 91
    print -r -- "sudo=$REPLY"
    print -rl -- "${reply[@]}"
    _zdx_doctor_install_plan brew jq || exit 92
    print -r -- "brew-sudo=[$REPLY]"
    print -rl -- "${reply[@]}"
    local -a missing=(zdx-absent-tool)
    _zdx_doctor_run_install 1 apt missing jq
  '
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "sudo=$TEST_MOCK_BIN/sudo" ]
  [ "${lines[1]}" = "$TEST_MOCK_BIN/sudo -n $TEST_MOCK_BIN/apt-get update" ]
  [ "${lines[2]}" = "$TEST_MOCK_BIN/sudo -n $TEST_MOCK_BIN/apt-get install -y jq" ]
  [ "${lines[3]}" = "brew-sudo=[]" ]
  [ "${lines[4]}" = "$TEST_MOCK_BIN/brew install jq" ]
  [[ "$output" == *"Dry run: 2 commands planned; nothing was installed."* ]]
  [ ! -s "$MOCK_APT_LOG" ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "zdx doctor: user-owned package managers and sudo are refused" {
  doctor_install_fixture
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions/zdx-doctor.zsh" || exit 90
    _zdx_doctor_confirm() { return 0; }
    local -a missing=(zdx-absent-tool)
    _zdx_doctor_run_install 0 apt missing jq
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Refusing apt-get: it must be a root-owned executable"* ]]
  [ ! -s "$MOCK_APT_LOG" ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "zdx doctor: a plan that changes after the review is refused" {
  doctor_install_fixture
  export ZDX_ROOT="$TEST_SUITE_ROOT"
  export MOCK_SUDO_ALLOW="__validate__,true,apt-get"
  mkdir -p "$TEST_TEMP_DIR/other-bin"
  cp "$TEST_MOCK_BIN/apt-get" "$TEST_TEMP_DIR/other-bin/apt-get"
  run zsh -f -c "$(doctor_install_prelude)"'
    other_bin="$1/other-bin"
    _zdx_doctor_confirm() { path=("$other_bin" "${path[@]}"); return 0; }
    local -a missing=(zdx-absent-tool)
    _zdx_doctor_run_install 0 apt missing jq
    print -r -- "manager=$?"
    _zdx_doctor_confirm() { return 0; }
    rm -f "$1/other-bin/apt-get"
    print "#!/bin/sh" > "$1/other-bin/zdx-absent-tool"
    chmod +x "$1/other-bin/zdx-absent-tool"
    path=("${path[@]:1}" "$1/other-bin")
    _zdx_doctor_run_install 0 apt missing jq
    print -r -- "appeared=$?"
  ' _ "$TEST_TEMP_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"The install plan changed after the review; nothing was installed."* ]]
  [[ "$output" == *"manager=1"* ]]
  [[ "$output" == *"zdx-absent-tool appeared after the review; nothing was installed."* ]]
  [[ "$output" == *"appeared=1"* ]]
  [ ! -s "$MOCK_APT_LOG" ]
  [ "$(grep -c '^sudo -n /' "$MOCK_SUDO_LOG")" -eq 0 ]
}

@test "zdx doctor: an expired sudo timestamp prints the remaining commands" {
  doctor_install_fixture
  export ZDX_ROOT="$TEST_SUITE_ROOT"
  export MOCK_SUDO_ALLOW="__validate__,apt-get"
  run zsh -f -c "$(doctor_install_prelude)"'
    local -a missing=(zdx-absent-tool)
    _zdx_doctor_run_install 0 apt missing jq
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"sudo no longer accepts the authentication without a prompt"* ]]
  [[ "$output" == *"$TEST_MOCK_BIN/sudo -n $TEST_MOCK_BIN/apt-get update"* ]]
  [[ "$output" == *"$TEST_MOCK_BIN/sudo -n $TEST_MOCK_BIN/apt-get install -y jq"* ]]
  [ ! -s "$MOCK_APT_LOG" ]
  [ "$(grep -c '^sudo -v$' "$MOCK_SUDO_LOG")" -eq 1 ]
}

@test "zdx doctor: a failed step stops the plan and declined or headless runs install nothing" {
  doctor_install_fixture
  export ZDX_ROOT="$TEST_SUITE_ROOT"
  export MOCK_SUDO_ALLOW="__validate__,true,apt-get"
  run env MOCK_APT_FAIL=update zsh -f -c "$(doctor_install_prelude)"'
    local -a missing=(zdx-absent-tool)
    _zdx_doctor_run_install 0 apt missing jq
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"[1/2] apt-get update — failed: exit 1"* ]]
  [[ "$output" == *"[2/2] apt-get install -y jq — not run: an earlier step failed"* ]]
  [ "$(cat "$MOCK_APT_LOG")" = "apt-get <update>" ]

  : > "$MOCK_APT_LOG"
  : > "$MOCK_SUDO_LOG"
  run zsh -f -c "$(doctor_install_prelude)"'
    _zdx_doctor_confirm() { return 1; }
    local -a missing=(zdx-absent-tool)
    _zdx_doctor_run_install 0 apt missing jq; print -r -- "declined=$?"
    unfunction _zdx_doctor_confirm
    source "$ZDX_ROOT/functions/zdx-doctor.zsh"
    _zdx_doctor_run_install 0 apt missing jq </dev/null; print -r -- "headless=$?"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"declined=1"* ]]
  [[ "$output" == *"confirmation needs a terminal"* ]]
  [[ "$output" == *"headless=1"* ]]
  [ ! -s "$MOCK_APT_LOG" ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "zdx doctor: --dry-run is the only option and completes" {
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions/zdx-doctor.zsh" || exit
    zdx-doctor --dry-run extra 2>/dev/null; print -r -- "extra=$?"
    zdx-doctor --help 2>&1 | grep -c -- "--dry-run"
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "extra=2" ]
  [ "${lines[1]}" -ge 1 ]
  grep -Fq -- "--dry-run[print the exact install plan; install nothing]" \
    "$TEST_SUITE_ROOT/completions/_zdx-menu"
}
