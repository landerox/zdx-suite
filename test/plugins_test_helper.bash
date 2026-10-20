# plugins_test_helper.bash - local Git origins for the plugin-manager tests
#
# Every origin is a bare repository inside the sandbox, so installs and updates
# exercise real Git clones, commits, and history without any network access.
# Load after test_helper, which provides the sandbox and portable helpers.

export GIT_AUTHOR_NAME="Jane Doe" GIT_AUTHOR_EMAIL="jane.doe@example.com"
export GIT_COMMITTER_NAME="Jane Doe" GIT_COMMITTER_EMAIL="jane.doe@example.com"

export PLUGINS_ROOT="$HOME/.config/zdx/plugins"
export PLUGINS_GIT_LOG="$TEST_TEMP_DIR/git-calls"
PLUGINS_REAL_GIT=$(command -v git)
export PLUGINS_REAL_GIT

# Record every Git invocation, then run the real Git. Tests read the log to
# prove that a refused operation never reached the network.
plugins_git_recorder() {
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PLUGINS_GIT_LOG"
exec "$PLUGINS_REAL_GIT" "$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/git"
  : > "$PLUGINS_GIT_LOG"
}

# plugin_source NAME MARKER: a valid entrypoint whose menu prints MARKER.
plugin_source() {
  printf '%s-menu() {\n  print -r -- "%s %s"\n}\n' "$1" "$1" "$2"
}

plugin_origin_url() {
  printf '%s\n' "$TEST_TEMP_DIR/origins/$1.git"
}

# plugin_origin_commit NAME MESSAGE CONTENT: replace the entrypoint, commit,
# and push to the bare origin.
plugin_origin_commit() {
  local name="$1" message="$2" content="$3"
  local work="$TEST_TEMP_DIR/work/$name"
  printf '%s\n' "$content" > "$work/$name-menu.zsh"
  "$PLUGINS_REAL_GIT" -C "$work" add -A
  "$PLUGINS_REAL_GIT" -C "$work" commit -q -m "$message"
  "$PLUGINS_REAL_GIT" -C "$work" push -q origin main
}

# plugin_origin_create NAME: a bare origin with one valid commit.
plugin_origin_create() {
  local name="$1"
  local origin work="$TEST_TEMP_DIR/work/$name"
  origin=$(plugin_origin_url "$name")
  mkdir -p "$TEST_TEMP_DIR/origins" "$TEST_TEMP_DIR/work"
  "$PLUGINS_REAL_GIT" init -q --bare -b main "$origin"
  "$PLUGINS_REAL_GIT" init -q -b main "$work"
  "$PLUGINS_REAL_GIT" -C "$work" remote add origin "$origin"
  plugin_origin_commit "$name" "Initial plugin" "$(plugin_source "$name" v1)"
}

# plugin_origin_head NAME: the commit at the tip of the origin's main branch.
plugin_origin_head() {
  "$PLUGINS_REAL_GIT" -C "$TEST_TEMP_DIR/work/$1" rev-parse HEAD
}

# plugin_installed_head NAME: the commit checked out in the installed plugin.
plugin_installed_head() {
  "$PLUGINS_REAL_GIT" -C "$PLUGINS_ROOT/$1" rev-parse HEAD
}

# plugin_tree_fingerprint DIR: every regular file below DIR, including .git,
# with its content digest, plus the directory identity. Any byte change in
# the tree, or a replaced directory, changes the fingerprint.
plugin_tree_fingerprint() {
  local dir="$1" file
  file_identity "$dir"
  while IFS= read -r file; do
    printf '%s %s\n' "${file#"$dir"/}" "$(sha256_file "$file")"
  done < <(find "$dir" -type f -print | LC_ALL=C sort)
}

# plugins_staging_left: prints any staging directory left in the root.
plugins_staging_left() {
  find "$PLUGINS_ROOT" -maxdepth 1 -name '.zdx-staging.*' -print 2>/dev/null
}

# plugins_install NAME: install NAME's origin non-interactively.
plugins_install() {
  run_zsh "zdx-plugins --install '$(plugin_origin_url "$1")' --yes" \
    >/dev/null 2>&1
}
