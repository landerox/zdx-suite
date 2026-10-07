#!/usr/bin/env bats
# Quoted programs execute in Zsh; each BATS test owns its exported mock state.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  export DEV_PROJECT="$HOME/project"
  mkdir -p "$DEV_PROJECT"
}

teardown() {
  cleanup_sandbox
}

run_specifier_update() {
  run run_zsh '
    source "$TEST_SUITE_ROOT/functions/dev-menu.zsh"
    cd "$DEV_PROJECT" || exit
    _dev_pypi_latest() {
      print -r -- "${MOCK_LATEST_VERSION:-2.0.0}"
      return "${MOCK_QUERY_STATUS:-0}"
    }
    _dev_update_specifier "${MOCK_PACKAGE:-target}" \
      "${MOCK_DRY_RUN:-0}" "${MOCK_BUMP_FILTER:-all}" 1
    result=$?
    print -r -- "$_DEV_UPDATE_RESULT"
    exit "$result"
  '
}

@test "dev specifier: inline arrays update only the requested dependency" {
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
dependencies = ["other>=1.0.0", "target>=1.0.0"]
EOF
  run_specifier_update
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated|target|1.0.0|2.0.0|"* ]]
  [ "$(cat "$DEV_PROJECT/pyproject.toml")" = '[project]
dependencies = ["other>=1.0.0", "target>=2.0.0"]' ]
}

@test "dev specifier: single quotes and spaced operators preserve formatting" {
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
dependencies = ['target >= 1.0.0'] # Preserve this comment.
EOF
  run_specifier_update
  [ "$status" -eq 0 ]
  [[ "$(cat "$DEV_PROJECT/pyproject.toml")" == *"'target >= 2.0.0'] # Preserve this comment."* ]]
}

@test "dev specifier: normalized names update every eligible declaration only" {
  export MOCK_PACKAGE="target-pkg"
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
description = "Target_Pkg>=1.0.0"
dependencies = ["Target_Pkg>=1.0.0"]
[project.optional-dependencies]
extras = ["target.pkg[extra]>=1.5.0", "target-pkg>=1.0.0,<2"]
[dependency-groups]
dev = ['target-pkg >= 1.2.0', {include-group = "quality"}]
quality = ["target-pkg>=1.0.0; python_version >= '3.11'"]
[tool.demo]
value = "Target_Pkg>=1.0.0"
EOF
  run_specifier_update
  [ "$status" -eq 0 ]
  run python3 -I -c '
import pathlib, tomllib, os
data = tomllib.loads((pathlib.Path(os.environ["DEV_PROJECT"]) / "pyproject.toml").read_text())
assert data["project"]["description"] == "Target_Pkg>=1.0.0"
assert data["project"]["dependencies"] == ["Target_Pkg>=2.0.0"]
assert data["project"]["optional-dependencies"]["extras"] == ["target.pkg[extra]>=2.0.0", "target-pkg>=1.0.0,<2"]
assert data["dependency-groups"]["dev"][0] == "target-pkg >= 2.0.0"
assert data["dependency-groups"]["quality"] == ["target-pkg>=1.0.0; python_version >= '\''3.11'\''"]
assert data["tool"]["demo"]["value"] == "Target_Pkg>=1.0.0"
'
  [ "$status" -eq 0 ]
}

@test "dev specifier: unrelated constraints on the same line do not block an update" {
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
dependencies = ["other>=1.0.0,<2", "target>=1.0.0"]
EOF
  run_specifier_update
  [ "$status" -eq 0 ]
  [[ "$(cat "$DEV_PROJECT/pyproject.toml")" == *'"other>=1.0.0,<2", "target>=2.0.0"'* ]]
}

@test "dev specifier: a lower upstream version never weakens the current minimum" {
  export MOCK_LATEST_VERSION="1.9.0"
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
dependencies = ["target>=2.0.0"]
EOF
  cp "$DEV_PROJECT/pyproject.toml" "$DEV_PROJECT/original"
  run_specifier_update
  [ "$status" -eq 1 ]
  [[ "$output" == *"skipped|target|2.0.0|1.9.0|"* ]]
  cmp "$DEV_PROJECT/pyproject.toml" "$DEV_PROJECT/original"
}

@test "dev specifier: query failure with output cannot publish a version" {
  export MOCK_QUERY_STATUS=7
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
dependencies = ["target>=1.0.0"]
EOF
  cp "$DEV_PROJECT/pyproject.toml" "$DEV_PROJECT/original"
  run_specifier_update
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed|target|1.0.0|—|PyPI query failed"* ]]
  cmp "$DEV_PROJECT/pyproject.toml" "$DEV_PROJECT/original"
}

@test "dev specifier: dry run preserves bytes and only includes the selected bump" {
  export MOCK_LATEST_VERSION="1.2.1"
  export MOCK_BUMP_FILTER=patch
  export MOCK_DRY_RUN=1
  printf '[project]\r\ndependencies = ["target>=1.2.0"]' > "$DEV_PROJECT/pyproject.toml"
  cp "$DEV_PROJECT/pyproject.toml" "$DEV_PROJECT/original"
  run_specifier_update
  [ "$status" -eq 0 ]
  cmp "$DEV_PROJECT/pyproject.toml" "$DEV_PROJECT/original"

  export MOCK_DRY_RUN=0
  export MOCK_BUMP_FILTER=minor
  run_specifier_update
  [ "$status" -eq 1 ]
  [[ "$output" == *"filtered by --minor-only"* ]]
  cmp "$DEV_PROJECT/pyproject.toml" "$DEV_PROJECT/original"

  export MOCK_BUMP_FILTER=patch
  run_specifier_update
  [ "$status" -eq 0 ]
  printf '[project]\r\ndependencies = ["target>=1.2.1"]' > "$DEV_PROJECT/expected"
  cmp "$DEV_PROJECT/pyproject.toml" "$DEV_PROJECT/expected"
}

@test "dev specifier: repeated declarations retain newer minima and metadata keys" {
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
dependencies = ["target>=3.0.0", "target>=1.0.0"]
[tool.demo]
"target>=1.0.0" = "unchanged"
"ZDX dependency span" = "existing key"
threshold = nan
EOF
  run_specifier_update
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated|target|1.0.0|2.0.0|"* ]]
  [[ "$(cat "$DEV_PROJECT/pyproject.toml")" == *'dependencies = ["target>=3.0.0", "target>=2.0.0"]'* ]]
  [[ "$(cat "$DEV_PROJECT/pyproject.toml")" == *'"target>=1.0.0" = "unchanged"'* ]]
}

@test "dev specifier: equivalent releases and prereleases do not cause downgrades" {
  export MOCK_LATEST_VERSION="2.0"
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
dependencies = ["target>=2.0.0"]
EOF
  run_specifier_update
  [ "$status" -eq 1 ]
  [[ "$output" == *"latest|target|2.0.0|2.0|"* ]]

  export MOCK_LATEST_VERSION="2.0rc1"
  run_specifier_update
  [ "$status" -eq 1 ]
  [[ "$output" == *"no downgrade"* ]]
  [[ "$(cat "$DEV_PROJECT/pyproject.toml")" == *'target>=2.0.0'* ]]
}

@test "dev specifier: matching span discovery is bounded without partial writes" {
  python3 -I -c '
import os, pathlib
path = pathlib.Path(os.environ["DEV_PROJECT"]) / "pyproject.toml"
path.write_text("[project]\ndependencies = [" + ", ".join(["\"target>=1.0.0\""] * 65) + "]\n")
'
  cp "$DEV_PROJECT/pyproject.toml" "$DEV_PROJECT/original"
  run_specifier_update
  [ "$status" -eq 1 ]
  [[ "$output" == *"more than 64 matching dependency strings"* ]]
  cmp "$DEV_PROJECT/pyproject.toml" "$DEV_PROJECT/original"
}
