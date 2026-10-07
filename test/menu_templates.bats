#!/usr/bin/env bats
# shellcheck disable=SC2016
#
# fzf shows a field together with its trailing delimiter, so `--with-nth=1`
# rendered every menu row as `Label|`. Wrappers add a template form that drops
# the delimiter when the installed fzf supports templates, and only then.

setup() {
  load test_helper
  export ZDX_FZF_TEMPLATES=auto
  export TEMPLATE_ARGS="$TEST_TEMP_DIR/fzf-args"
  export TEMPLATE_PROBES="$TEST_TEMP_DIR/fzf-probes"
  cat > "$TEST_MOCK_BIN/fzf" <<'MOCK'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == --filter=probe ]]; then
    printf 'probe\n' >> "$TEMPLATE_PROBES"
    if [[ "${MOCK_FZF_TEMPLATES:-1}" == 1 ]]; then
      cat
      exit 0
    fi
    printf 'invalid field index expression\n' >&2
    exit 2
  fi
done
printf '%s\n' "$@" > "$TEMPLATE_ARGS"
cat > /dev/null
exit 130
MOCK
  chmod +x "$TEST_MOCK_BIN/fzf"
}

teardown() {
  cleanup_sandbox
}

@test "menu templates: a single shown field drops its trailing delimiter" {
  run run_zsh '
    local suite=""
    for suite in dev sys; do
      source "$ZSH_CUSTOM/functions/$suite-menu.zsh" || exit 1
    done
    _dev_fzf --prompt=dev < /dev/null
    grep -Fxq -- "--with-nth=1" "$TEMPLATE_ARGS" || exit 2
    grep -Fxq -- "--with-nth={1}" "$TEMPLATE_ARGS" || exit 3
    _sys_fzf --prompt=sys < /dev/null
    grep -Fxq -- "--with-nth={1}" "$TEMPLATE_ARGS" || exit 4
    _tk_fzf --delimiter="[|]" --with-nth=2 < /dev/null
    grep -Fxq -- "--with-nth={2}" "$TEMPLATE_ARGS" || exit 5
  '
  [ "$status" -eq 0 ]
  # One probe per fzf executable for the whole shell session.
  [ "$(wc -l < "$TEMPLATE_PROBES")" -eq 1 ]
}

@test "menu templates: fzf without templates keeps the plain field" {
  export MOCK_FZF_TEMPLATES=0
  run run_zsh '
    source "$ZSH_CUSTOM/functions/dev-menu.zsh" || exit 1
    _dev_fzf --prompt=dev < /dev/null
    grep -Fxq -- "--with-nth=1" "$TEMPLATE_ARGS" || exit 2
    ! grep -Fq -- "--with-nth={" "$TEMPLATE_ARGS" || exit 3
  '
  [ "$status" -eq 0 ]
}

@test "menu templates: pickers that show several fields are left unchanged" {
  run run_zsh '
    _tk_fzf --delimiter="[|]" --with-nth=1,3 < /dev/null
    grep -Fxq -- "--with-nth=1,3" "$TEMPLATE_ARGS" || exit 2
    ! grep -Fq -- "--with-nth={" "$TEMPLATE_ARGS" || exit 3
  '
  [ "$status" -eq 0 ]
  [ ! -e "$TEMPLATE_PROBES" ]
}

@test "menu templates: ZDX_FZF_TEMPLATES forces or disables the template without a probe" {
  run run_zsh '
    ZDX_FZF_TEMPLATES=1 _tk_fzf --delimiter="[|]" --with-nth=1 < /dev/null
    grep -Fxq -- "--with-nth={1}" "$TEMPLATE_ARGS" || exit 2
    ZDX_FZF_TEMPLATES=0 _tk_fzf --delimiter="[|]" --with-nth=1 < /dev/null
    ! grep -Fq -- "--with-nth={" "$TEMPLATE_ARGS" || exit 3
  '
  [ "$status" -eq 0 ]
  [ ! -e "$TEMPLATE_PROBES" ]
}
