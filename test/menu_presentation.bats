#!/usr/bin/env bats

setup() {
  load test_helper
  export MENU_UI_DIR="$TEST_TEMP_DIR/menu-ui"
  mkdir -p "$MENU_UI_DIR" "$HOME/project"

  cat > "$TEST_MOCK_BIN/fzf" <<'FZF'
#!/usr/bin/env bash
set -eu
printf '%s\0' "$@" > "$MENU_UI_DIR/$MENU_UI_SUITE.argv"
cat > "$MENU_UI_DIR/$MENU_UI_SUITE.rows"
exit 130
FZF
  chmod +x "$TEST_MOCK_BIN/fzf"
}

teardown() {
  cleanup_sandbox
}

capture_command_menus() {
  # shellcheck disable=SC2016
  run run_zsh '
    unfunction command
    cd "$HOME/project" || return 1
    local suite
    for suite in dev file git ws sys py ai docker env ci net gpu hf zdx; do
      source "$ZSH_CUSTOM/functions/${suite}-menu.zsh" || return 1
    done

    # Presentation does not need a live Docker daemon or its network endpoint.
    _docker_menu_header() { print -r -- "Docker context: fixture"; }

    export MENU_UI_SUITE
    for MENU_UI_SUITE in dev file git ws sys py ai docker env ci net gpu hf zdx; do
      "${MENU_UI_SUITE}-menu" >"$MENU_UI_DIR/$MENU_UI_SUITE.stdout" || return 1
      [[ -s "$MENU_UI_DIR/$MENU_UI_SUITE.argv" ]] || return 2
      [[ ! -s "$MENU_UI_DIR/$MENU_UI_SUITE.stdout" ]] || return 3
    done
  '
  [ "$status" -eq 0 ]
}

@test "menu presentation: command menus share effective layout and cancel without data" {
  capture_command_menus

  run python3 - "$MENU_UI_DIR" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for suite in "dev file git ws sys py ai docker env ci net gpu hf zdx".split():
    args = (root / (suite + ".argv")).read_bytes().decode().split("\0")[:-1]
    options = {}
    bindings = []
    for arg in args:
        key, _, value = arg.partition("=")
        options[key] = value
        if key == "--bind":
            bindings.extend(value.split(","))
    for key, value in {
        "--height": "80%",
        "--layout": "reverse",
        "--border": "rounded",
        "--delimiter": "[|]",
        "--with-nth": "1",
        "--pointer": "▶",
        "--preview-window": "down:4:wrap",
        "--prompt": suite + " > ",
    }.items():
        assert options.get(key) == value, (suite, key, options.get(key))
    assert "ctrl-/:toggle-preview" in bindings, (suite, bindings)
    verb = "open" if suite == "zdx" else "run"
    legend = f"Type to filter | Enter {verb} | Esc cancel | Ctrl-/ details"
    assert legend in options.get("--header", "").splitlines(), suite
    assert "--multi" not in options, suite
    assert "Tab mark" not in options["--header"], suite
    for key in ("--prompt", "--header", "--preview"):
        assert "\x1b" not in options[key], (suite, key)

    rows = (root / (suite + ".rows")).read_text().splitlines()
    assert rows, suite
    commands = set()
    for row in rows:
        fields = row.split("|")
        assert len(fields) == 3 and all(fields), (suite, row)
        assert "\x1b" not in row, (suite, row)
        if fields[1] != ":":
            assert fields[1] not in commands, (suite, fields[1])
            commands.add(fields[1])
    assert commands, suite
PY
  [ "$status" -eq 0 ]
}

@test "menu presentation: section details contain no fake command and preview text stays data" {
  capture_command_menus

  run python3 - "$MENU_UI_DIR" <<'PY'
import pathlib
import shlex
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
marker = root / "unexpected-preview-execution"
description = f"Keep literal $(touch {marker}); 'quotes', `code`, and percent %s."
for path in sorted(root.glob("*.argv")):
    args = path.read_bytes().decode().split("\0")[:-1]
    preview = [arg.partition("=")[2] for arg in args if arg.startswith("--preview=")][-1]
    for command in (":", "example-status"):
        # fzf quotes field placeholders before starting its constant preview.
        rendered = preview.replace("{2}", shlex.quote(command))
        rendered = rendered.replace("{3}", shlex.quote(description))
        result = subprocess.run(["zsh", "-f", "-c", rendered], capture_output=True, text=True)
        assert result.returncode == 0 and result.stderr == "", (path, result)
        if command == ":":
            assert result.stdout == description + "\n", (path, result.stdout)
        else:
            prefix = "zdx " if path.stem == "zdx" else ""
            assert result.stdout == f"Command: {prefix}{command}\n\n{description}\n", path
        assert not marker.exists(), path
PY
  [ "$status" -eq 0 ]
}
