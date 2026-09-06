#!/usr/bin/env bats

setup() {
  load test_helper

  # Setup dummy git repo inside TEST_TEMP_DIR for local git config testing
  export REPO_DIR="$TEST_TEMP_DIR/dummy-repo"
  mkdir -p "$REPO_DIR"
  cd "$REPO_DIR"
  git init -b main 2>/dev/null || git init 2>/dev/null
  git config user.name "Initial Name"
  git config user.email "initial@email.com"
}

teardown() {
  cleanup_sandbox
}

@test "git-identity: --help works" {
  run run_zsh "git-identity-switcher --help"
  [ "$status" -eq 0 ]
  [[ "$output" == *"git-identity-switcher --switch"* ]]
}

@test "git-identity: --status displays local and global settings" {
  run run_zsh "
    cd '$REPO_DIR'
    git-identity-switcher --status
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"Initial Name"* ]]
  [[ "$output" == *"initial@email.com"* ]]
}

@test "git-identity: --switch fails on missing profile name" {
  run run_zsh "
    cd '$REPO_DIR'
    git-identity-switcher --switch
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"Profile name is required"* ]]
}

@test "git-identity: --switch fails on non-existent profile name" {
  run run_zsh "
    cd '$REPO_DIR'
    git-identity-switcher --switch non-existent
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not defined in \$ZDX_GIT_IDENTITIES"* ]]
}

@test "git-identity: --switch applies a valid local identity profile successfully" {
  run run_zsh "
    cd '$REPO_DIR'
    # Define test profile in local environment
    typeset -gA ZDX_GIT_IDENTITIES
    ZDX_GIT_IDENTITIES=(
      'test-personal' 'Name|Test Jane;Email|test-jane@doe.dev;GpgKey|A1B2C3D4;SshKey|~/.ssh/test_id'
    )
    git-identity-switcher --switch test-personal local
    echo '---'
    git config user.name
    git config user.email
    git config user.signingkey
    git config core.sshCommand
  "
  if [ "$status" -ne 0 ]; then
    echo "STATUS: $status"
    echo "OUTPUT: $output"
    return 1
  fi
  [[ "$output" == *"Profile 'test-personal' successfully applied"* ]]
  [[ "$output" == *"Test Jane"* ]]
  [[ "$output" == *"test-jane@doe.dev"* ]]
  [[ "$output" == *"A1B2C3D4"* ]]
  [[ "$output" == *"ssh -i "* ]]
}

@test "git-identity: --switch applies a valid global identity profile successfully" {
  run run_zsh "
    cd '$REPO_DIR'
    typeset -gA ZDX_GIT_IDENTITIES
    ZDX_GIT_IDENTITIES=(
      'test-global' 'Name|Global Jane;Email|global-jane@doe.dev'
    )
    git-identity-switcher --switch test-global global
    echo '---'
    git config --global user.name
    git config --global user.email
  "
  if [ "$status" -ne 0 ]; then
    echo "STATUS: $status"
    echo "OUTPUT: $output"
    return 1
  fi
  [[ "$output" == *"Profile 'test-global' successfully applied"* ]]
  [[ "$output" == *"Global Jane"* ]]
  [[ "$output" == *"global-jane@doe.dev"* ]]
}
