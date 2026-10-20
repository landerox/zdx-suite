#!/usr/bin/env bats

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "git GitHub safety: PR publishing honors pushRemote and local branch" {
  run run_zsh '
    local repo_dir="$HOME/repository"
    command git init -q -b topic "$repo_dir" || return 1
    cd "$repo_dir" || return 1
    command git remote add tracking \
      "https://github.example.invalid/team/tracking.git"
    command git remote add publish \
      "https://github.example.invalid/team/publish.git"
    command git config branch.topic.remote tracking
    command git config branch.topic.merge refs/heads/different-destination
    command git config branch.topic.pushRemote publish

    _git_gh_push_remote topic || return 1
    [[ "$REPLY" == "publish" ]] || return 1
    local -a reply=()
    _git_gh_remote_identity "$REPLY" || return 1
    [[ "${reply[2]}" == \
      "https://github.example.invalid/team/publish.git" ]]
  '

  [ "$status" -eq 0 ]
}

@test "git GitHub safety: PR publishing rejects multiple push URLs" {
  run run_zsh '
    local repo_dir="$HOME/repository"
    command git init -q -b topic "$repo_dir" || return 1
    cd "$repo_dir" || return 1
    command git remote add publish \
      "https://github.example.invalid/team/repository.git"
    command git remote set-url --add --push publish \
      "https://github.example.invalid/team/first.git"
    command git remote set-url --add --push publish \
      "https://github.example.invalid/team/second.git"

    local -a reply=()
    _git_gh_remote_identity publish
  '

  [ "$status" -ne 0 ]
  [[ "$output" == *"exactly one push URL"* ]]
}
