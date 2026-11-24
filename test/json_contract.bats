#!/usr/bin/env bats
# Public JSON producers and the Workspace repository-object builder.

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "json contract: shipped emitters capture compact monochrome jq output before publication" {
  python3 -B -I -S - "$TEST_SUITE_ROOT" <<'PY'
from pathlib import Path
import re
import shlex
import sys

root = Path(sys.argv[1]) / "functions"
owners = (
    ("status", "zdx-status.zsh", "_zdx_status_render_json", "document", '_zdx_probe_tool 5 "$jq_path"'),
    ("git-status", "git/git-repo.zsh", "_git_status_json", "json_document", "command jq"),
    ("git-identity-check", "git/git-identity.zsh", "_git_identity_check_json", "json_document", "command jq"),
    ("sys-info", "sys/sys-diag.zsh", "_sys_info_json", "document", "_sys_jq"),
    ("sys-wsl", "sys/sys-wsl-config.zsh", "_sys_wsl_review_json", "document", "_sys_jq"),
    ("sys-wsl", "sys/sys-wsl-config.zsh", "sys-wsl", "document", "_sys_jq"),
    ("env-dotenv", "env/env-dotenv.zsh", "_env_dotenv_print_json", "json", "command jq"),
    ("file-trash", "file/file-trash.zsh", "_file_trash_list_json", "document", "command jq"),
    ("vpn-mtu-probe", "vpn/vpn-mtu.zsh", "_vpn_mtu_render_json", "document", 'command "$jq_program"'),
    ("ws-status", "ws/ws-status.zsh", "ws-status", "document", 'command "$jq_path"'),
)


def function_body(path, name):
    source = (root / path).read_text(encoding="utf-8")
    match = re.search(rf"(?ms)^{re.escape(name)}\(\) \{{\n(.*?)^\}}$", source)
    assert match, f"{path}: missing {name}"
    return match[1].replace("\\\n", " ")


def require_flags(source, backend, where):
    option = r"(?:-[a-zA-Z]+|--(?:compact-output|monochrome-output|null-input|raw-input|slurp))"
    calls = re.findall(rf"(?m)(?:^|\|)[ \t]*{re.escape(backend)}((?:[ \t]+{option}(?=\s|$))*)", source)
    assert len(calls) == 1, f"{where}: expected one {backend} call in the producer"
    flags = calls[0].split()
    short = "".join(flag[1:] for flag in flags if not flag.startswith("--"))
    assert "c" in short or "--compact-output" in flags, f"{where}: missing jq -c"
    assert "M" in short or "--monochrome-output" in flags, f"{where}: missing jq -M"


def require_balanced_producer(producer, where):
    # Count only unquoted delimiter tokens within the proposed capture.
    tokens = shlex.shlex(producer, posix=False, punctuation_chars="()")
    tokens.commenters = ""
    depth = 0
    for token in tokens:
        if token.strip("()"):
            continue
        for character in token:
            depth += 1 if character == "(" else -1
            assert depth >= 0, f"{where}: capture spans statements"
    assert depth == 0, f"{where}: unbalanced producer"


def require_capture(path, name, variable, backend, publish=True):
    body = function_body(path, name)
    where = f"{path}:{name}:{variable}"
    failure_action = r"\{|return [^\n]+|[a-z_][a-z0-9_]*=\$\?"
    capture = re.search(rf"(?ms)^([ \t]*){variable}=\$\((.*?)\)\s+\|\| ({failure_action})$", body)
    assert capture, f"{where}: missing guarded producer capture"
    indent, producer, failure = capture.groups()
    require_balanced_producer(producer, where)
    tail = body[capture.end():]
    if failure == "{":
        end = re.search(rf"(?m)^{indent}\}}$", tail)
        assert end and re.search(r"(?m)^\s+return \S+", tail[:end.start()]), where
        tail = tail[end.end():]
    elif failure.endswith("=$?"):
        status = re.escape(failure.split("=", 1)[0])
        guard = re.search(rf"(?ms)^{indent}if \(\( {status} != 0[^\n]*then\n(.*?)^{indent}fi$", tail)
        assert guard and re.search(r"(?m)^\s+return \S+", guard[1]), where
        tail = tail[guard.end():]
    else:
        assert failure.startswith("return "), f"{where}: producer failure can fall through"
    if backend != "_sys_jq":
        require_flags(producer, backend, where)
    else:
        assert producer.startswith("_sys_jq "), f"{where}: expected the shared jq producer"
    publication = rf'(?m)^[ \t]*print -r -- "\${variable}"$'
    assert len(re.findall(publication, body)) == int(publish), f"{where}: unexpected publication count"
    if publish:
        assert re.search(publication, tail), f"{where}: publication precedes the failure guard"


schemas = {f"zdx.{command}.v1" for command, *_ in owners}
shipped_sources = [root.parent / "functions.zsh"]
shipped_sources.extend(path for path in root.rglob("*.zsh") if path != root / "zdir.zsh")
declared = {
    schema for path in shipped_sources
    for schema in re.findall(r"\bzdx\.[a-z][a-z0-9_-]*\.v[1-9][0-9]*\b", path.read_text(encoding="utf-8"))
}
assert declared == schemas, f"JSON schema inventory changed: {sorted(declared ^ schemas)}"
for _, path, name, variable, backend in owners:
    require_capture(path, name, variable, backend)
require_flags(function_body("sys-common.zsh", "_sys_jq"), "command jq", "_sys_jq")
require_capture("ws/ws-status.zsh", "ws-status", "object", 'command "$jq_path"', publish=False)
PY
}
