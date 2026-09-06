#!/usr/bin/env bats

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "file safety: leading-dash delete target remains data" {
  run run_zsh '
    cd "$HOME"
    touch -- -victim
    file-bulk-ops delete --yes -- ./-victim
    [[ ! -e ./-victim ]]
  '
  [ "$status" -eq 0 ]
}

@test "file safety: invalid Base64 never truncates an existing output" {
  run run_zsh '
    cd "$HOME"
    print -r -- invalid%%% > encoded
    print -r -- preserved > output
    file-encode-decode \
      --decode-file encoded --output output --overwrite --yes
  '
  [ "$status" -ne 0 ]
  [ "$(cat "$HOME/output")" = "preserved" ]
}

@test "file safety: input and Base64 output cannot be identical" {
  run run_zsh '
    cd "$HOME"
    print -r -- content > input
    file-encode-decode \
      --encode-file input --output input --overwrite --yes
  '
  [ "$status" -ne 0 ]
  [ "$(cat "$HOME/input")" = "content" ]
}

@test "file safety: extractor rejects an unvalidated backend" {
  run run_zsh '
    cd "$HOME"
    touch archive.zip
    file-extract --destination extracted --yes -- archive.zip
  '
  [ "$status" -ne 0 ]
  [ ! -e "$HOME/extracted" ]
  [[ "$output" == *"only TAR archives"* ]]
}

@test "file safety: bulk targets cannot contain one another" {
  run run_zsh '
    cd "$HOME"
    mkdir -p parent/child
    file-bulk-ops delete --dry-run -- parent parent/child
  '
  [ "$status" -ne 0 ]
  [ -d "$HOME/parent/child" ]
}

@test "file safety: output destinations remain inside the current base" {
  run run_zsh '
    cd "$HOME"
    print -r -- content > input
    file-encode-decode \
      --encode-file input --output ../escape.b64 --yes
  '
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_TEMP_DIR/escape.b64" ]
}
