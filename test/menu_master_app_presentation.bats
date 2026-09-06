#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  PRESENTATION_REAL_FZF=$(command -v fzf || true)
  load test_helper
  cat > "$TEST_MOCK_BIN/fzf" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK_FZF_ARGS_FILE"
cat > "$MOCK_FZF_INPUT_FILE"
exit 130
MOCK
  chmod +x "$TEST_MOCK_BIN/fzf"
}

teardown() { cleanup_sandbox; }

@test "master presentation: real label filtering finds every built-in route" {
  [ -n "$PRESENTATION_REAL_FZF" ] || skip "real fzf is not installed"
  run zsh -f -c '
    source "$1/functions/zdx-menu.zsh" || exit
    model=$(_zdx_menu_model) || exit
    local route="" filtered=""
    for route in git ws dev app ci file env py sys docker net vpn ai hf gpu doctor plugins; do
      filtered=$(env -u FZF_DEFAULT_OPTS -u FZF_DEFAULT_OPTS_FILE \
        -u FZF_DEFAULT_COMMAND "$2" --delimiter="[|]" --with-nth=1 \
        --filter="$route" <<< "$model") || exit 1
      [[ "$filtered" == *"|$route|"* ]] || exit 1
    done

    local candidate="Visible label|private-route-token|private-description-token"
    filtered=$(env -u FZF_DEFAULT_OPTS -u FZF_DEFAULT_OPTS_FILE \
      -u FZF_DEFAULT_COMMAND "$2" --delimiter="[|]" --with-nth=1 \
      --filter=Visible <<< "$candidate") || exit
    [[ "$filtered" == "$candidate" ]] || exit 1
    local query="" filter_rc=0
    for query in private-route-token private-description-token; do
      filter_rc=0
      filtered=$(env -u FZF_DEFAULT_OPTS -u FZF_DEFAULT_OPTS_FILE \
        -u FZF_DEFAULT_COMMAND "$2" --delimiter="[|]" --with-nth=1 \
        --filter="$query" <<< "$candidate") || filter_rc=$?
      (( filter_rc == 1 )) && [[ -z "$filtered" ]] || exit 1
    done
  ' _ "$TEST_SUITE_ROOT" "$PRESENTATION_REAL_FZF"
  [ "$status" -eq 0 ]
}

@test "master presentation: compact details distinguish sections from commands" {
  run zsh -f -c '
    source "$1/functions/zdx-menu.zsh" || exit
    cd "$HOME" || exit
    zdx-menu >"$HOME/stdout" || exit
    local preview="" option="" route=":" description="Section overview"
    for option in "${(@f)$(<"$MOCK_FZF_ARGS_FILE")}"; do
      [[ "$option" == --preview=* ]] && preview="${option#--preview=}"
    done
    [[ -n "$preview" ]] || exit 1
    preview="${preview//\{2\}/${(q)route}}"
    preview="${preview//\{3\}/${(q)description}}"
    command zsh -f -c "$preview" >"$HOME/section-preview" || exit
    [[ "$(<"$HOME/section-preview")" == "$description" ]]
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/stdout" ]
  grep -Fxq -- '--height=80%' "$MOCK_FZF_ARGS_FILE"
  grep -Fxq -- '--with-nth=1' "$MOCK_FZF_ARGS_FILE"
  grep -Fxq -- '--preview-window=down:4:wrap' "$MOCK_FZF_ARGS_FILE"
  grep -Fxq -- '--bind=ctrl-/:toggle-preview' "$MOCK_FZF_ARGS_FILE"
  grep -Fxq -- "--header=Directory: $HOME" "$MOCK_FZF_ARGS_FILE"
  grep -Fxq 'Type to filter | Enter open | Esc cancel | Ctrl-/ details' "$MOCK_FZF_ARGS_FILE"
}

@test "master presentation: only dispatchable loaded plugins create a custom section" {
  run zsh -f -c '
    source "$1/functions/zdx-menu.zsh" || exit
    typeset -ga ZDX_LOADED_PLUGINS=(missing git help "bad.name")
    model=$(_zdx_menu_model 2>/dev/null) || exit
    [[ "$model" != *"── Custom Plugins ──|"* ]] || exit 1
    sample-menu() { return 0; }
    orphan-menu() { return 0; }
    ZDX_LOADED_PLUGINS+=(sample sample)
    model=$(_zdx_menu_model 2>/dev/null) || exit
    local -a plugin_rows=("${(@M)${(@f)model}:#*|sample|*}")
    (( ${#plugin_rows} == 1 )) || exit 1
    [[ "$model" == *"── Custom Plugins ──|"* \
      && "$model" == *"Loaded in this shell."* \
      && "$model" != *"reviewed custom plugin"* \
      && "$model" != *"|orphan|"* ]] || exit 1
    unfunction sample-menu
    model=$(_zdx_menu_model 2>/dev/null) || exit
    [[ "$model" != *"── Custom Plugins ──|"* ]]
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
}

@test "master presentation: lazy completion lists only exact loaded available plugins" {
  run zsh -f -c '
    typeset -ga ZDX_LOADED_PLUGINS=(sample sample-extra missing git help version sample "bad.name")
    sample-menu() { print -r -- UNEXPECTED_MENU; }
    sample-extra-menu() { print -r -- UNEXPECTED_MENU; }
    orphan-menu() { print -r -- UNEXPECTED_MENU; }
    help-menu() { print -r -- UNEXPECTED_MENU; }
    _arguments() { state=suite; }
    _describe() {
      local array_name="$4"
      print -rl -- "${(@P)array_name}"
    }
    _test_completion() { source "$1/completions/_zdx-menu"; }
    service=zdx
    _test_completion "$1" || exit
    [[ -z "${_ZDX_COMMON_SOURCED:-}" ]]
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^sample:')" -eq 1 ]
  [[ "$output" == *"sample-extra:Loaded custom plugin"* ]]
  [[ "$output" != *"missing:"* && "$output" != *"orphan:"* ]]
  [[ "$output" != *"bad.name:"* && "$output" != *"UNEXPECTED_MENU"* ]]
  [ "$(printf '%s\n' "$output" | grep -c '^help:')" -eq 1 ]
}

@test "master presentation: nested plugin completion shares loaded membership checks" {
  run zsh -f -c '
    typeset -ga ZDX_LOADED_PLUGINS=(sample missing help "bad.name")
    sample-menu() { print -r -- UNEXPECTED_MENU; }
    orphan-menu() { print -r -- UNEXPECTED_MENU; }
    _sample-menu() {
      [[ "$service" == sample-menu && "$words[1]" == sample-menu ]] || return 1
      printf "literal=%s\n" "$words[2]"
    }
    _orphan-menu() { print -r -- UNEXPECTED_COMPLETION; }
    _missing-menu() { print -r -- UNEXPECTED_COMPLETION; }
    _help-menu() { print -r -- UNEXPECTED_COMPLETION; }
    _arguments() { state=suite-arguments; }
    _test_completion() { source "$1/completions/_zdx-menu"; }
    service=zdx
    words=(sample "semi;literal space")
    _test_completion "$1" || exit
    local route=""
    for route in orphan missing help "bad.name"; do
      service=zdx
      words=("$route" "literal")
      _test_completion "$1"
    done
    [[ -z "${_ZDX_COMMON_SOURCED:-}" ]]
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = 'literal=semi;literal space' ]
}

@test "app presentation: task details expose metadata and preserve private indexes" {
  run run_zsh '
    cd "$HOME" || return
    mkdir "project space" || return
    cd "project space" || return
    print -r -- "build:" > Justfile
    print -r -- "    echo PRIVATE_RECIPE_BODY" >> Justfile
    app-menu >"$HOME/stdout"
  '
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/stdout" ]
  grep -Fxq -- '--with-nth=1,3' "$MOCK_FZF_ARGS_FILE"
  grep -Fxq -- '--preview-window=down:4:wrap' "$MOCK_FZF_ARGS_FILE"
  grep -Fxq -- '--bind=ctrl-/:toggle-preview' "$MOCK_FZF_ARGS_FILE"
  grep -Fxq 'Type to filter | Enter review | Esc cancel | Ctrl-/ details' "$MOCK_FZF_ARGS_FILE"
  grep -Fq 'Run build|app-run|' "$MOCK_FZF_INPUT_FILE"
  grep -Fq 'just: Justfile in current directory (project space)' "$MOCK_FZF_INPUT_FILE"
  awk -F '|' 'NF != 4 || $2 != "app-run" || $4 !~ /^[1-9][0-9]*$/ { exit 1 }' "$MOCK_FZF_INPUT_FILE"
  run grep -Fq 'PRIVATE_RECIPE_BODY' "$MOCK_FZF_INPUT_FILE" "$MOCK_FZF_ARGS_FILE"
  [ "$status" -eq 1 ]
}

@test "app presentation: multi selection advertises only its actual marking bindings" {
  run run_zsh '
    cd "$HOME" || return
    print -r -- "build:" > Justfile
    app-menu --multi >"$HOME/stdout"
  '
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/stdout" ]
  grep -Fxq -- '--multi' "$MOCK_FZF_ARGS_FILE"
  grep -Fxq 'Tab mark | Tasks run in selection order' "$MOCK_FZF_ARGS_FILE"
  grep -Fq 'Enter review' "$MOCK_FZF_ARGS_FILE"
  run grep -Eq 'Ctrl-A|Ctrl-D|select-all|deselect-all' "$MOCK_FZF_ARGS_FILE"
  [ "$status" -eq 1 ]
}

@test "app presentation: homonymous workspaces remain distinct before task review" {
  mkdir -p "$HOME/repo/repo"
  printf 'build:\n' > "$HOME/repo/Justfile"
  printf 'build:\n' > "$HOME/repo/repo/Justfile"
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "$#" -eq 4 && "$1" == -C && "$2" == "$HOME/repo/repo" \
  && "$3" == rev-parse && "$4" == --show-toplevel ]]; then
  printf '%s\n' "$HOME/repo"
  exit 0
fi
exit 97
MOCK
  chmod +x "$TEST_MOCK_BIN/git"
  run zsh -f -c '
    source "$1/functions/app-menu.zsh" || exit
    cd "$HOME/repo/repo" || exit
    app-menu >"$HOME/stdout"
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/stdout" ]
  [ "$(cut -d '|' -f 1,3 "$MOCK_FZF_INPUT_FILE" | sort -u | wc -l)" -eq 2 ]
  grep -Fq 'in current directory (repo)' "$MOCK_FZF_INPUT_FILE"
  grep -Fq 'in repository root (repo)' "$MOCK_FZF_INPUT_FILE"
}
