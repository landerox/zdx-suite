#!/usr/bin/env bats

setup() {
  load test_helper

  cat <<'EOF' > "$TEST_MOCK_BIN/python3"
#!/usr/bin/env bash
script="${3:-}"
shift 3 || true

case "$script" in
  *'huggingface_hub.__version__'*|\
  *'getattr(huggingface_hub, "__version__", "")'*)
    printf '%s\n' "0.36.0"
    ;;
  *'api.list_models'*)
    printf '%s\n' \
      $'acme/gpt2\t15344092\t3293' \
      $'acme/gpt2-large\t1999478\t352'
    ;;
  *'api.list_datasets'*)
    printf '%s\n' $'acme/squad\t138741\t367'
    ;;
  *'records = ('*)
    printf '%s\n' \
      $'repository\tacme/gpt2' \
      $'type\tMODEL' \
      $'author\tAcme Team' \
      $'downloads\t15344092' \
      $'likes\t3293' \
      $'last_modified\t2026-01-01' \
      $'gated\tno' \
      $'sha\t123456' \
      $'tags\ttext-generation'
    ;;
  *'repos = sorted(cache_info.repos'*|\
  *'for repo in cache_info.repos'*)
    printf '%s\n' $'acme/gpt2\tmodel\t1200\t1.2 KB\t10'
    ;;
  *)
    printf 'mock python3: unsupported backend script\n' >&2
    exit 97
    ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/python3"
}

teardown() {
  cleanup_sandbox
}

@test "hf: entrypoint and public wrappers are loaded in the eager test runtime" {
  run run_zsh '
    local command_name
    for command_name in hf-menu hf-search hf-repo-stats \
      hf-cache-inspect hf-cache-clear hf-download; do
      typeset -f "$command_name" >/dev/null || return 1
    done
  '
  [ "$status" -eq 0 ]
}

@test "hf: help is stderr-only and discloses installed-backend policy" {
  run run_zsh '
    hf-menu --help >"$HOME/stdout" 2>"$HOME/stderr"
    [[ ! -s "$HOME/stdout" ]]
    grep -q "hf-cache-clear" "$HOME/stderr"
    grep -q "never installs or executes a Python package implicitly" \
      "$HOME/stderr"
  '
  [ "$status" -eq 0 ]
}

@test "hf: search list emits validated TSV data only" {
  run run_zsh '
    hf-search --type model --query gpt2 --limit 2 --list \
      >"$HOME/stdout" 2>"$HOME/stderr"
    [[ "$(<"$HOME/stdout")" == \
      $'\''acme/gpt2\t15344092\t3293\nacme/gpt2-large\t1999478\t352'\'' ]]
  '
  [ "$status" -eq 0 ]
}

@test "hf: repository statistics render UI on stderr only" {
  run run_zsh '
    NO_COLOR=1 hf-repo-stats --type model --repo acme/gpt2 \
      >"$HOME/stdout" 2>"$HOME/stderr"
    [[ ! -s "$HOME/stdout" ]]
    grep -q "Acme Team" "$HOME/stderr"
    grep -q "123456" "$HOME/stderr"
  '
  [ "$status" -eq 0 ]
}

@test "hf: invalid arguments and unknown dispatch tokens return status 2" {
  run run_zsh 'hf-menu unknown-command'
  [ "$status" -eq 2 ]

  run run_zsh 'hf-search --type invalid --query gpt2'
  [ "$status" -eq 2 ]
}

@test "hf: missing installed backend never falls through to uv" {
  cat <<'EOF' > "$TEST_MOCK_BIN/uv"
#!/usr/bin/env bash
printf 'uv called\n' >> "$HOME/uv-called"
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  run run_zsh '
    HF_PYTHON="$HOME/missing-python" \
      hf-search --type model --query gpt2 --list
  '
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/uv-called" ]
  [[ "$output" == *"does not download or execute a Python package implicitly"* ]]
}

@test "hf: menu cancellation is success and private capture is removed" {
  export MOCK_FZF_MODE="cancel"
  export MOCK_FZF_STATUS="130"

  run run_zsh '
    export TMPDIR="$HOME/tmp"
    mkdir -p "$TMPDIR"
    hf-menu
    local menu_rc=$?
    (( menu_rc == 0 )) || return 1
    local -a leftovers=("$TMPDIR"/zdx-hf-fzf.*(N))
    (( ${#leftovers} == 0 ))
  '
  [ "$status" -eq 0 ]
}

@test "hf: an fzf record outside the current menu snapshot is refused" {
  export MOCK_FZF_MODE="response"
  export MOCK_FZF_RESPONSE="Injected|hf-cache-clear|forged"

  run run_zsh 'hf-menu'
  [ "$status" -eq 1 ]
  [[ "$output" == *"not in the menu snapshot"* ]]
}
