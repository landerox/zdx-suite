#!/usr/bin/env bats
# Literal Zsh programs and per-test controls are intentional.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  export DOTENV_SCOPE_DIR="$HOME/dotenv-scope"
  export DOTENV_SCOPE_FILE="$DOTENV_SCOPE_DIR/input.env"
  export DOTENV_SCOPE_MARKER=ZdxCanarySecretKeyMaterial0q3x9ZkTgLwPcVbN2mY8sRfH0aJ
  export GIT_CEILING_DIRECTORIES="$TEST_TEMP_DIR"
  mkdir -m 700 "$DOTENV_SCOPE_DIR"
}

teardown() { cleanup_sandbox; }

scope_parse() {
  run run_zsh '
    source "$TEST_SUITE_ROOT/functions/env-menu.zsh" || return 90
    _env_dotenv_read "$DOTENV_SCOPE_FILE" "dotenv file" || return 91
    _env_dotenv_parse "$REPLY"
  '
}

scope_report_private() {
  export DOTENV_SCOPE_LOCATION="$1"
  printf 'SAFE=ok\n' > "$DOTENV_SCOPE_DIR/other.env"
  chmod -- 600 "$DOTENV_SCOPE_FILE" "$DOTENV_SCOPE_DIR/other.env"
  run run_zsh '
    builtin cd -- "$DOTENV_SCOPE_DIR" || return 90
    local first="$DOTENV_SCOPE_FILE" second="$DOTENV_SCOPE_DIR/other.env"
    [[ "$DOTENV_SCOPE_LOCATION" != example ]] || { first="$second"; second="$DOTENV_SCOPE_FILE"; }
    env-dotenv "$first" --example "$second" >"$HOME/text.out" 2>"$HOME/text.err"
    local text_rc=$?
    env-dotenv "$first" --example "$second" --json >"$HOME/report.json" 2>"$HOME/json.err"
    local json_rc=$?
    [[ $text_rc == 1 && $json_rc == 1 ]] || return 92
  '
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/text.out" ]
  ! grep -Fq -- "$DOTENV_SCOPE_MARKER" "$HOME/text.err" "$HOME/report.json" "$HOME/json.err" || false
  jq -e '(.dotenv.malformed_lines + (.example.malformed_lines // [])) | length > 0' "$HOME/report.json"
}

scope_pem() {
  printf 'SAFE=ok\n%s\n%s==\n%s\nAFTER=ok\n' "$1" "$DOTENV_SCOPE_MARKER" "$2" > "$DOTENV_SCOPE_FILE"
}

@test "env dotenv privacy: unquoted PEM payload is never a reported key" {
  scope_pem 'TLS_KEY=-----BEGIN PRIVATE'' KEY-----' '-----END PRIVATE'' KEY-----'
  scope_report_private dotenv
}

@test "env dotenv privacy: an unterminated quoted PEM is consumed without leaking its payload" {
  scope_pem 'TLS_KEY="-----BEGIN PRIVATE'' KEY-----' '-----END PRIVATE'' KEY-----'
  scope_report_private dotenv
}

@test "env dotenv privacy: malformed example PEM receives the same name protection" {
  scope_pem 'TLS_KEY=-----BEGIN PRIVATE'' KEY-----' '-----END PRIVATE'' KEY-----'
  scope_report_private example
}

@test "env dotenv privacy: a standalone PEM opener quarantines subsequent assignments" {
  scope_pem '-----BEGIN PRIVATE'' KEY-----' '-----END PRIVATE'' KEY-----'
  scope_parse
  [ "$status" -eq 0 ]
  [ "$output" = $'key\tSAFE\nkey\tAFTER\nmalformed\t2' ]
}

@test "env dotenv privacy: a missing PEM end quarantines through EOF" {
  scope_pem 'TLS_KEY=-----BEGIN PRIVATE'' KEY-----' '# no end marker'
  scope_parse
  [ "$status" -eq 0 ]
  [ "$output" = $'key\tSAFE\nmalformed\t2' ]
}

@test "env dotenv privacy: a mismatched PEM end cannot expose later body names" {
  scope_pem 'TLS_KEY=-----BEGIN PRIVATE'' KEY-----' '-----END CERTIFICATE-----'
  scope_parse
  [ "$status" -eq 0 ]
  [ "$output" = $'key\tSAFE\nmalformed\t2' ]
}

@test "env dotenv privacy: a malformed assignment still quarantines its PEM body" {
  scope_pem 'BAD-NAME=-----BEGIN PRIVATE'' KEY-----' '-----END PRIVATE'' KEY-----'
  scope_parse
  [ "$status" -eq 0 ]
  [ "$output" = $'key\tSAFE\nkey\tAFTER\nmalformed\t2' ]
}

@test "env dotenv privacy: valid quoted PEM remains one set value" {
  scope_pem 'TLS_KEY="-----BEGIN PRIVATE'' KEY-----' '-----END PRIVATE'' KEY-----"'
  scope_parse
  [ "$status" -eq 0 ]
  [ "$output" = $'key\tSAFE\nkey\tTLS_KEY\nkey\tAFTER' ]
}

@test "env dotenv privacy: a valid PEM quote may close on the following line" {
  printf 'TLS_KEY="-----BEGIN PRIVATE'' KEY-----\n%s==\n-----END PRIVATE'' KEY-----\n"\nAFTER=ok\n' "$DOTENV_SCOPE_MARKER" > "$DOTENV_SCOPE_FILE"
  scope_parse
  [ "$status" -eq 0 ]
  [ "$output" = $'key\tTLS_KEY\nkey\tAFTER' ]
}

@test "env dotenv privacy: encoded-looking orphan names stay out of text and JSON" {
  printf 'SAFE=ok\n%s==\n%s=\n' "$DOTENV_SCOPE_MARKER" "$DOTENV_SCOPE_MARKER" > "$DOTENV_SCOPE_FILE"
  scope_report_private dotenv
  jq -e '.dotenv.key_count == 1 and .dotenv.duplicates == [] and .extra == [] and .dotenv.malformed_lines == [2,3]' "$HOME/report.json"
}

@test "env dotenv privacy: encoded-looking example names cannot appear as missing keys" {
  printf 'SAFE=ok\n%s==\n' "$DOTENV_SCOPE_MARKER" > "$DOTENV_SCOPE_FILE"
  scope_report_private example
  jq -e '.example.key_count == 1 and .missing == [] and .example.malformed_lines == [2]' "$HOME/report.json"
}

@test "env dotenv privacy: ordinary long and underscore key names remain supported" {
  printf 'K%s=ok\nLONG_UppercaseKeyNameWithDigits0123456789=ok\n' "$(printf 'x%.0s' {1..127})" > "$DOTENV_SCOPE_FILE"
  scope_parse
  [ "$status" -eq 0 ]
  [[ "$output" == *$'key\tLONG_UppercaseKeyNameWithDigits0123456789' ]]
  [[ "$output" != *malformed* ]]
}

scope_nul_span() {
  printf '%b' "$1" > "$DOTENV_SCOPE_FILE"
  scope_parse
  [ "$status" -eq 0 ]
  [ "$output" = $'key\tAFTER\nmalformed\t1' ]
}

@test "env dotenv privacy: NUL on an intermediate continuation invalidates its logical assignment" {
  scope_nul_span 'KEY="first\nsec\000ond\nclosing"\nAFTER=ok\n'
}

@test "env dotenv privacy: NUL on the closing continuation invalidates its logical assignment" {
  scope_nul_span 'KEY="first\nsec\000ond"\nAFTER=ok\n'
}

@test "env dotenv privacy: NUL on the opener still consumes its quoted body" {
  scope_nul_span 'KEY="fi\000rst\nFAKE=not-a-key\nclosing"\nAFTER=ok\n'
}

@test "env dotenv privacy: NUL quoted spans in an example do not leak body names" {
  printf 'KEY="first\nsec\000ond\n%s==\nclosing"\nSAFE=ok\n' "$DOTENV_SCOPE_MARKER" > "$DOTENV_SCOPE_FILE"
  scope_report_private example
  jq -e '.example.key_count == 1 and .example.malformed_lines == [1]' "$HOME/report.json"
}

@test "env dotenv privacy: never-closed ordinary quotes retain next-line recovery" {
  printf 'A="unclosed\nB=ok\n' > "$DOTENV_SCOPE_FILE"
  scope_parse
  [ "$status" -eq 0 ]
  [ "$output" = $'key\tB\nmalformed\t1' ]
}

@test "env dotenv privacy: a later matching quote still consumes its closing line" {
  printf 'A="unclosed\nB="ok"\nAFTER=ok\n' > "$DOTENV_SCOPE_FILE"
  scope_parse
  [ "$status" -eq 0 ]
  [ "$output" = $'key\tAFTER\nmalformed\t1' ]
}

scope_bounded_parse() {
  export DOTENV_SCOPE_PROGRAM="$HOME/parse-bounded.zsh"
  export DOTENV_SCOPE_DEADLINE="${1:-3}"
  cat > "$DOTENV_SCOPE_PROGRAM" <<'ZSH'
emulate -R zsh
source "$TEST_SUITE_ROOT/functions/env-menu.zsh" || exit 90
_env_dotenv_read "$DOTENV_SCOPE_FILE" "dotenv file" || exit 91
_env_dotenv_parse "$REPLY"
ZSH
  run run_zsh '_zdx_run_with_timeout "$DOTENV_SCOPE_DEADLINE" zsh -f "$DOTENV_SCOPE_PROGRAM"'
  if [ "$status" -ne 0 ]; then
    printf 'actual-status=%s deadline=%s\n' "$status" "$DOTENV_SCOPE_DEADLINE" >&2
    false
  fi
  [ "$output" = $'key\tKEY' ]
}

@test "env dotenv privacy: a long unquoted value completes within an owned deadline" {
  printf 'KEY=%s\n' "$(printf 'x%.0s' {1..131072})" > "$DOTENV_SCOPE_FILE"
  scope_bounded_parse
}

@test "env dotenv privacy: dense quoted escapes complete within an owned deadline" {
  command perl -e 'print "KEY=\"", "\\a" x 24576, "\"\n"' > "$DOTENV_SCOPE_FILE"
  scope_bounded_parse
}

@test "env dotenv privacy: near-limit quoted escapes need no extra value-size cap" {
  command perl -e 'print "KEY=\"", "\\a" x 524284, "\"\n"' > "$DOTENV_SCOPE_FILE"
  [ "$(file_size "$DOTENV_SCOPE_FILE")" -le 1048576 ]
  scope_bounded_parse 12
}

@test "env dotenv privacy: ten thousand duplicate assignments retain every line and final state" {
  command perl -e 'print "KEY=value\n" x 9999, "KEY=\n"' > "$DOTENV_SCOPE_FILE"
  export DOTENV_SCOPE_PROGRAM="$HOME/parse-many.zsh"
  cat > "$DOTENV_SCOPE_PROGRAM" <<'ZSH'
emulate -R zsh
source "$TEST_SUITE_ROOT/functions/env-menu.zsh" || exit 90
_env_dotenv_read "$DOTENV_SCOPE_FILE" "dotenv file" || exit 91
_env_dotenv_parse "$REPLY" > "$HOME/parsed.records" || exit 92
local expected="${(j:,:)${(s: :)$(print -r -- {1..10000})}}"
[[ "$(<"$HOME/parsed.records")" == $'key\tKEY\nempty\tKEY\nduplicate\tKEY\t'"$expected" ]]
ZSH
  run run_zsh '_zdx_run_with_timeout 12 zsh -f "$DOTENV_SCOPE_PROGRAM"'
  [ "$status" -eq 0 ]
}

@test "env dotenv privacy: an unquoted initial hash needs a preceding blank to be a comment" {
  printf 'HASH=#literal\nCOMMENT= #comment\nVALUE=a #comment\nBLANK= \t\n' > "$DOTENV_SCOPE_FILE"
  scope_parse
  [ "$status" -eq 0 ]
  [ "$output" = $'key\tHASH\nkey\tCOMMENT\nkey\tVALUE\nkey\tBLANK\nempty\tCOMMENT\nempty\tBLANK' ]
}

@test "env dotenv privacy: odd and even backslash runs preserve both quote grammars" {
  cat > "$DOTENV_SCOPE_FILE" <<'ENV'
ODD="a\"b"
EVEN="a\\"
SINGLE='a\'b'
AFTER=ok
ENV
  scope_parse
  [ "$status" -eq 0 ]
  [ "$output" = $'key\tODD\nkey\tEVEN\nkey\tSINGLE\nkey\tAFTER' ]
}

@test "env dotenv privacy: nested PEM labels cannot end the outer quarantine" {
  printf '%s\n' \
    'SAFE=ok' \
    'TLS_KEY=-----BEGIN PRIVATE'' KEY-----' \
    '-----BEGIN CERTIFICATE-----' \
    'SHORT=payload' \
    '-----END CERTIFICATE-----' \
    'MORE=payload' \
    '-----END PRIVATE'' KEY-----' \
    'AFTER=ok' > "$DOTENV_SCOPE_FILE"

  scope_parse
  [ "$status" -eq 0 ]
  [ "$output" = $'key\tSAFE\nkey\tAFTER\nmalformed\t2' ]
}

@test "env dotenv privacy: an equals sign in a standalone PEM header cannot hide its opener" {
  printf '%s\n' \
    'SAFE=ok' \
    '-----BEGIN PRIVATE'' KEY----- # note=value' \
    'SHORT=payload' \
    '-----END PRIVATE'' KEY-----' \
    'AFTER=ok' > "$DOTENV_SCOPE_FILE"

  scope_parse
  [ "$status" -eq 0 ]
  [ "$output" = $'key\tSAFE\nkey\tAFTER\nmalformed\t2' ]
}

@test "env dotenv privacy: a PEM opener on the first quoted continuation quarantines its body" {
  printf '%s\n' \
    'KEY="' \
    '-----BEGIN PRIVATE'' KEY-----' \
    'prefix"' \
    'SHORT=payload' \
    '-----END PRIVATE'' KEY-----' \
    'AFTER=ok' > "$DOTENV_SCOPE_FILE"

  scope_parse
  [ "$status" -eq 0 ]
  [ "$output" = $'key\tAFTER\nmalformed\t1' ]
}

@test "env dotenv privacy: a valid PEM may begin after a blank quoted opener" {
  printf '%s\n' \
    'KEY="' \
    '' \
    '-----BEGIN PRIVATE'' KEY-----' \
    'SHORT=payload' \
    '-----END PRIVATE'' KEY-----"' \
    'AFTER=ok' > "$DOTENV_SCOPE_FILE"

  scope_parse
  [ "$status" -eq 0 ]
  [ "$output" = $'key\tKEY\nkey\tAFTER' ]
}
