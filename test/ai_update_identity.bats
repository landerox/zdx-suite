#!/usr/bin/env bats
# AI updater result identity: version tokens and executable content.
# Quoted programs are passed literally to the isolated Zsh process.
# shellcheck disable=SC2016

setup() {
  load test_helper
  export TMPDIR="$TEST_TEMP_DIR/tmp"
  mkdir -m 700 "$TMPDIR"
}

teardown() {
  cleanup_sandbox
}

@test "ai update identity: version tokens ignore vendor decorations" {
  run run_zsh '
    local -a cases=(
      claude "2.1.288 (Claude Code)" 2.1.288
      codex "codex-cli 0.160.0" 0.160.0
      amp "0.0.1791014446-g764146 (released 2026-10-03T08:00:46.000Z, 4h ago)" 0.0.1791014446-g764146
      cursor "2026.10.01-e373342" 2026.10.01-e373342
      copilot "GitHub Copilot CLI 0.0.354." 0.0.354
      hermes "Hermes Agent v0.20.6 (2026.8.27)" v0.20.6
      hermes "Hermes Agent vgit.ddc0e65.dirty (2026.9.24) · upstream ddc0e659" vgit.ddc0e65.dirty
      claude "claude 1" "claude 1"
    )
    local id line expected
    for id line expected in "${cases[@]}"; do
      _ai_update_version_token "$id" "$line"
      [[ "$REPLY" == "$expected" ]] || { print -r -- "bad:$id:$REPLY"; return 1; }
    done
    print -r -- ok
  '
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "ai update identity: a changing relative release age is already current" {
  cat <<'EOF' > "$TEST_MOCK_BIN/amp"
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then
  count=$(( $(cat "$HOME/amp-probes" 2>/dev/null || print 0) + 1 ))
  printf '%s\n' "$count" > "$HOME/amp-probes"
  printf '%s\n' "0.0.1791014446-g764146 (released 2026-10-03T08:00:46.000Z, ${count}h ago)"
  exit 0
fi
[[ "$1" == "update" ]] && exit 0
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/amp"

  run run_zsh 'ai-update-amp --yes --result-tsv'
  [ "$status" -eq 0 ]
  [[ "$output" == *$'ai-update-result-v1\tamp\tAmp CLI\talready-current\tunchanged\t0'* ]]
  [[ "$output" == *"Amp CLI is already at the latest reported version (0.0.1791014446-g764146)."* ]]
  [[ "$output" != *"h ago"* ]]
}

@test "ai update identity: a launcher re-created for the same release is already current" {
  local release="$HOME/opt/codex/releases/0.160.0"
  mkdir -p "$release/bin"
  cat <<'EOF' > "$release/bin/codex"
#!/usr/bin/env bash
root="$HOME/opt/codex"
if [[ "$1" == "--version" ]]; then
  echo "codex-cli 0.160.0"
  exit 0
fi
if [[ "$1" == "update" ]]; then
  # Re-create both links for the same release, as the vendor updater does.
  # Renaming each new link over the old one guarantees a new inode, which a
  # remove-then-create sequence may reuse.
  ln -s "$root/releases/0.160.0" "$root/current.new"
  mv -fT "$root/current.new" "$root/current"
  ln -s "$root/current/bin/codex" "$TEST_MOCK_BIN/codex.new"
  mv -fT "$TEST_MOCK_BIN/codex.new" "$TEST_MOCK_BIN/codex"
  exit 0
fi
exit 97
EOF
  chmod +x "$release/bin/codex"
  ln -s "$release" "$HOME/opt/codex/current"
  ln -s "$HOME/opt/codex/current/bin/codex" "$TEST_MOCK_BIN/codex"
  local before_inode
  before_inode=$(stat -c '%i' "$TEST_MOCK_BIN/codex")

  run run_zsh 'ai-update-codex --yes --result-tsv'
  [ "$status" -eq 0 ]
  [ "$(stat -c '%i' "$TEST_MOCK_BIN/codex")" != "$before_inode" ]
  [[ "$output" == *$'ai-update-result-v1\tcodex\tCodex CLI\talready-current\tunchanged\t0'* ]]
  [[ "$output" == *"Codex CLI is already at the latest reported version (0.160.0)."* ]]
  [[ "$output" != *"executable changed"* ]]
}

@test "ai update identity: a same-version build in a new release directory is updated" {
  local root="$HOME/opt/codex"
  mkdir -p "$root/releases/a/bin" "$root/releases/b/bin"
  cat <<'EOF' > "$root/releases/a/bin/codex"
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then echo "codex-cli 0.160.0"; exit 0; fi
if [[ "$1" == "update" ]]; then
  rm -f "$HOME/opt/codex/current"
  ln -s "$HOME/opt/codex/releases/b" "$HOME/opt/codex/current"
  exit 0
fi
exit 97
EOF
  cat <<'EOF' > "$root/releases/b/bin/codex"
#!/usr/bin/env bash
# rebuilt
if [[ "$1" == "--version" ]]; then echo "codex-cli 0.160.0"; exit 0; fi
exit 97
EOF
  chmod +x "$root/releases/a/bin/codex" "$root/releases/b/bin/codex"
  ln -s "$root/releases/a" "$root/current"
  ln -s "$root/current/bin/codex" "$TEST_MOCK_BIN/codex"

  run run_zsh 'ai-update-codex --yes --result-tsv'
  [ "$status" -eq 0 ]
  [[ "$output" == *$'ai-update-result-v1\tcodex\tCodex CLI\tupdated\texecutable-content-changed\t0'* ]]
  [[ "$output" == *"executable changed while reporting the same version (0.160.0)"* ]]
}

@test "ai update identity: a Hermes Git build is planned, noted, and compared by commit" {
  cat <<'EOF' > "$TEST_MOCK_BIN/hermes"
#!/usr/bin/env bash
case "$*" in
  --version)
    if [[ -e "$HOME/hermes-updated" ]]; then
      echo "Hermes Agent vgit.abcdef1 (2026.10.3) · upstream abcdef1"
    else
      echo "Hermes Agent vgit.ddc0e65.dirty (2026.9.24) · upstream ddc0e659"
    fi
    ;;
  'update --backup --yes') printf '%s\n' "$*" > "$HOME/hermes-updated" ;;
  *) exit 97 ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/hermes"

  run run_zsh 'ai-update-hermes --yes --result-tsv'
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/hermes-updated")" = "update --backup --yes" ]
  [[ "$output" == *"the Git checkout has local changes"* ]]
  [[ "$output" == *"Hermes Agent updated: vgit.ddc0e65.dirty -> vgit.abcdef1"* ]]
  [[ "$output" == *$'ai-update-result-v1\thermes\tHermes Agent\tupdated\tversion-changed\t0'* ]]
}
