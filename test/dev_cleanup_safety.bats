#!/usr/bin/env bats

setup() {
  load test_helper

  export DEV_PROJECT="$HOME/project"
  export DEV_MOVED="$HOME/project-moved"
  export DEV_VICTIM="$HOME/victim"
  mkdir -p "$DEV_PROJECT" "$DEV_VICTIM"

  export REAL_RM REAL_MV REAL_LN
  REAL_RM=$(command -v rm)
  REAL_MV=$(command -v mv)
  REAL_LN=$(command -v ln)
}

teardown() {
  cleanup_sandbox
}

@test "dev cleanup safety: a symlinked project root is refused" {
  local real_project="$HOME/real-project"
  local project_link="$HOME/project-link"
  mkdir -p "$real_project/pkg/__pycache__"
  printf '%s\n' "keep" > "$real_project/pkg/__pycache__/keep.pyc"
  ln -s "$real_project" "$project_link"
  export project_link

  run run_zsh 'cd "$project_link" && dev-clean-py --yes'

  [ "$status" -eq 1 ]
  [[ "$output" == *"symlinked cleanup root"* ]]
  [ -f "$real_project/pkg/__pycache__/keep.pyc" ]
}

@test "dev cleanup safety: a root swap during confirmation changes nothing" {
  mkdir -p \
    "$DEV_PROJECT/pkg/__pycache__" \
    "$DEV_VICTIM/pkg/__pycache__"
  printf '%s\n' "project" > "$DEV_PROJECT/pkg/__pycache__/target.pyc"
  printf '%s\n' "victim" > "$DEV_VICTIM/pkg/__pycache__/target.pyc"

  run run_zsh '
    cd "$DEV_PROJECT" || return 90
    _dev_confirm_outcome() {
      command mv "$DEV_PROJECT" "$DEV_MOVED" || return 91
      command ln -s "$DEV_VICTIM" "$DEV_PROJECT" || return 92
      print -r -- confirmed
    }
    dev-clean-py
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"root pathname"* ]]
  [ -L "$DEV_PROJECT" ]
  [ "$(cat "$DEV_MOVED/pkg/__pycache__/target.pyc")" = "project" ]
  [ "$(cat "$DEV_VICTIM/pkg/__pycache__/target.pyc")" = "victim" ]
}

@test "dev cleanup safety: every rm revalidates the frozen root" {
  printf '%s\n' "project-a" > "$DEV_PROJECT/.DS_Store"
  printf '%s\n' "project-b" > "$DEV_PROJECT/Thumbs.db"
  printf '%s\n' "victim-a" > "$DEV_VICTIM/.DS_Store"
  printf '%s\n' "victim-b" > "$DEV_VICTIM/Thumbs.db"

  export DEV_SWAP_MARKER="$HOME/root-swapped"
  cat > "$TEST_MOCK_BIN/rm" <<'EOF'
#!/usr/bin/env bash
set -u

"$REAL_RM" "$@"
rc=$?
if [[ ! -e "$DEV_SWAP_MARKER" ]]; then
  : > "$DEV_SWAP_MARKER"
  "$REAL_MV" "$DEV_PROJECT" "$DEV_MOVED"
  "$REAL_LN" -s "$DEV_VICTIM" "$DEV_PROJECT"
fi
exit "$rc"
EOF
  chmod +x "$TEST_MOCK_BIN/rm"

  run run_zsh 'cd "$DEV_PROJECT" && dev-clean-repo --yes'
  "$REAL_RM" -f -- "$TEST_MOCK_BIN/rm"

  [ "$status" -eq 1 ]
  [[ "$output" == *"root pathname"* ]]
  [[ "$output" == *"1 removed"* ]]
  [ -L "$DEV_PROJECT" ]
  [ "$(cat "$DEV_VICTIM/.DS_Store")" = "victim-a" ]
  [ "$(cat "$DEV_VICTIM/Thumbs.db")" = "victim-b" ]
  [ "$(find "$DEV_MOVED" -maxdepth 1 -type f | wc -l)" -eq 1 ]
}

@test "dev cleanup safety: a replaced target is not the reviewed target" {
  printf '%s\n' "planned" > "$DEV_PROJECT/.DS_Store"

  run run_zsh '
    cd "$DEV_PROJECT" || return 90
    _dev_confirm_outcome() {
      command mv .DS_Store .DS_Store.planned || return 91
      print -r -- replacement > .DS_Store
      print -r -- confirmed
    }
    dev-clean-repo
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"target changed after planning"* ]]
  [ "$(cat "$DEV_PROJECT/.DS_Store")" = "replacement" ]
  [ "$(cat "$DEV_PROJECT/.DS_Store.planned")" = "planned" ]
}

@test "dev cleanup safety: generated vendored and nested repositories are excluded" {
  mkdir -p \
    "$DEV_PROJECT/pkg/__pycache__" \
    "$DEV_PROJECT/.terraform" \
    "$DEV_PROJECT/.git/deep/__pycache__" \
    "$DEV_PROJECT/component/.git/deep/__pycache__" \
    "$DEV_PROJECT/.venv/lib/__pycache__" \
    "$DEV_PROJECT/node_modules/pkg/__pycache__" \
    "$DEV_PROJECT/src/vendor/lib/__pycache__" \
    "$DEV_PROJECT/src/vendored/lib/__pycache__" \
    "$DEV_PROJECT/nested/repo/.git" \
    "$DEV_PROJECT/nested/repo/pkg/__pycache__" \
    "$DEV_PROJECT/worktree/pkg/__pycache__" \
    "$DEV_PROJECT/archive.git/pkg/__pycache__"
  printf '%s\n' "gitdir: ../worktree-metadata" \
    > "$DEV_PROJECT/worktree/.git"
  printf '%s\n' "terraform {}" > "$DEV_PROJECT/main.tf"
  printf '%s\n' "remove" > "$DEV_PROJECT/pkg/__pycache__/remove.pyc"
  printf '%s\n' "remove" > "$DEV_PROJECT/.DS_Store"

  local preserved
  while IFS= read -r preserved; do
    printf '%s\n' "keep" > "$preserved"
  done <<EOF
$DEV_PROJECT/.git/deep/__pycache__/keep.pyc
$DEV_PROJECT/component/.git/deep/__pycache__/keep.pyc
$DEV_PROJECT/.venv/lib/__pycache__/keep.pyc
$DEV_PROJECT/node_modules/pkg/__pycache__/keep.pyc
$DEV_PROJECT/src/vendor/lib/__pycache__/keep.pyc
$DEV_PROJECT/src/vendored/lib/__pycache__/keep.pyc
$DEV_PROJECT/nested/repo/pkg/__pycache__/keep.pyc
$DEV_PROJECT/worktree/pkg/__pycache__/keep.pyc
$DEV_PROJECT/archive.git/pkg/__pycache__/keep.pyc
EOF
  printf '%s\n' "keep" > "$DEV_PROJECT/src/vendor/.DS_Store"
  mkdir -p "$DEV_PROJECT/src/vendored/.terraform"

  run run_zsh 'cd "$DEV_PROJECT" && dev-clean-all --yes'

  [ "$status" -eq 0 ]
  [ ! -e "$DEV_PROJECT/pkg/__pycache__" ]
  [ ! -e "$DEV_PROJECT/.terraform" ]
  [ ! -e "$DEV_PROJECT/.DS_Store" ]
  [ -f "$DEV_PROJECT/.git/deep/__pycache__/keep.pyc" ]
  [ -f "$DEV_PROJECT/component/.git/deep/__pycache__/keep.pyc" ]
  [ -f "$DEV_PROJECT/.venv/lib/__pycache__/keep.pyc" ]
  [ -f "$DEV_PROJECT/node_modules/pkg/__pycache__/keep.pyc" ]
  [ -f "$DEV_PROJECT/src/vendor/lib/__pycache__/keep.pyc" ]
  [ -f "$DEV_PROJECT/src/vendored/lib/__pycache__/keep.pyc" ]
  [ -f "$DEV_PROJECT/nested/repo/pkg/__pycache__/keep.pyc" ]
  [ -f "$DEV_PROJECT/worktree/pkg/__pycache__/keep.pyc" ]
  [ -f "$DEV_PROJECT/archive.git/pkg/__pycache__/keep.pyc" ]
  [ -f "$DEV_PROJECT/src/vendor/.DS_Store" ]
  [ -d "$DEV_PROJECT/src/vendored/.terraform" ]
}

@test "dev cleanup safety: a nested repository at the depth boundary is excluded" {
  mkdir -p "$DEV_PROJECT/__pycache__/.git"
  printf '%s\n' "keep" > "$DEV_PROJECT/__pycache__/KEEP"

  run run_zsh '
    cd "$DEV_PROJECT"
    export DEV_CLEAN_DEPTH=1
    dev-clean-py --dry-run
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to clean"* ]]
  [[ "$output" != *"Removal plan"* ]]
  [ -f "$DEV_PROJECT/__pycache__/KEEP" ]
}

@test "dev cleanup safety: invalid discovery depths fail closed" {
  mkdir -p "$DEV_PROJECT/pkg/__pycache__"

  run run_zsh '
    cd "$DEV_PROJECT"
    export DEV_CLEAN_DEPTH="1+1"
    dev-clean-py --yes
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"DEV_CLEAN_DEPTH"* ]]
  [ -d "$DEV_PROJECT/pkg/__pycache__" ]
}

@test "dev cleanup safety: invalid target limits fail closed" {
  printf '%s\n' "keep" > "$DEV_PROJECT/stale.pyc"

  run run_zsh '
    cd "$DEV_PROJECT"
    export DEV_CLEAN_MAX_TARGETS="1+1"
    dev-clean-py --yes
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"DEV_CLEAN_MAX_TARGETS"* ]]
  [[ "$output" != *"Removal plan"* ]]
  [ -f "$DEV_PROJECT/stale.pyc" ]
}

@test "dev cleanup safety: discovery stops beyond the configured target limit" {
  printf '%s\n' "keep" > "$DEV_PROJECT/one.pyc"
  printf '%s\n' "keep" > "$DEV_PROJECT/two.pyc"
  printf '%s\n' "keep" > "$DEV_PROJECT/three.pyc"

  run run_zsh '
    cd "$DEV_PROJECT"
    export DEV_CLEAN_MAX_TARGETS=2
    dev-clean-py --yes
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"safe limit of 2 entries"* ]]
  [[ "$output" != *"Removal plan"* ]]
  [ -f "$DEV_PROJECT/one.pyc" ]
  [ -f "$DEV_PROJECT/two.pyc" ]
  [ -f "$DEV_PROJECT/three.pyc" ]
}

@test "dev cleanup safety: the unique combined plan is bounded before mutation" {
  printf '%s\n' "keep" > "$DEV_PROJECT/stale.pyc"
  printf '%s\n' "keep" > "$DEV_PROJECT/.DS_Store"
  mkdir -p "$DEV_PROJECT/target"

  run run_zsh '
    cd "$DEV_PROJECT"
    export DEV_CLEAN_MAX_TARGETS=2
    dev-clean-all --yes
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"Combined cleanup plan exceeds"* ]]
  [[ "$output" != *"Removal plan"* ]]
  [ -f "$DEV_PROJECT/stale.pyc" ]
  [ -f "$DEV_PROJECT/.DS_Store" ]
  [ -d "$DEV_PROJECT/target" ]
}

@test "dev cleanup safety: stale Terraform artifacts need no surviving tf file" {
  mkdir -p "$DEV_PROJECT/.terraform/providers"
  printf '%s\n' "stale" > "$DEV_PROJECT/old.tfstate.backup"

  run run_zsh 'cd "$DEV_PROJECT" && dev-clean-all --yes'

  [ "$status" -eq 0 ]
  [ ! -d "$DEV_PROJECT/.terraform" ]
  [ ! -f "$DEV_PROJECT/old.tfstate.backup" ]
}
