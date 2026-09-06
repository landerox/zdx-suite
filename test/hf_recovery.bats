#!/usr/bin/env bats
# Single-quoted scripts execute in Zsh; exports are isolated by BATS.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  export HF_RECOVERY_PYTHON
  HF_RECOVERY_PYTHON=$(command -v python3)
  export HF_RECOVERY_SCRIPT="$TEST_TEMP_DIR/hub_fixture.py"
  export HF_RECOVERY_MODE=success
  cat <<'PY' > "$HF_RECOVERY_SCRIPT"
import errno
import json
import os
import sys
import threading
import time
import types
from pathlib import Path

script = sys.argv[2]
sys.argv = ["-c", *sys.argv[3:]]
home = Path(os.environ["HOME"])
mode = os.environ["HF_RECOVERY_MODE"]
hub = types.ModuleType("huggingface_hub")
hub_api = types.ModuleType("huggingface_hub.hf_api")

class RepoFile:
    path = "nested/weights.safetensors"

class RepoFolder:
    pass

class HfApi:
    def list_repo_tree(self, **kwargs):
        return iter([RepoFile()])

def download(**kwargs):
    (home / "download-args").write_text(json.dumps(kwargs))
    print("VENDOR_SECRET_OUTPUT")
    print("VENDOR_SECRET_ERROR", file=sys.stderr)
    if mode == "interrupt":
        raise KeyboardInterrupt()
    if mode == "terminate":
        raise SystemExit(143)
    if mode == "access":
        raise type("GatedRepoError", (Exception,), {})("TOKEN_SHOULD_STAY_HIDDEN")
    if mode == "network":
        raise type("ConnectError", (Exception,), {})("TOKEN_SHOULD_STAY_HIDDEN")
    if mode == "storage":
        raise OSError(errno.ENOSPC, "TOKEN_SHOULD_STAY_HIDDEN")
    if mode == "missing":
        return str(home / "missing-result")
    if mode == "progress":
        deadline = time.monotonic() + 2
        while "Download is still running" not in (home / "err").read_text():
            if time.monotonic() > deadline:
                raise RuntimeError("missing progress before completion")
            time.sleep(0.005)
    target = home / "cache" / "snapshot"
    target.mkdir(parents=True, exist_ok=True)
    if "filename" in kwargs:
        blob = home / "cache" / "blob"
        blob.write_text("fixture data")
        target = target / "weights.safetensors"
        target.symlink_to(blob)
    return str(target)

# Accelerate only the download heartbeat event, leaving Thread internals intact.
if mode == "progress":
    real_event = threading.Event
    event_count = 0
    def event_factory():
        global event_count
        event_count += 1
        event = real_event()
        if event_count == 1:
            real_wait = event.wait
            event.wait = lambda timeout=None: real_wait(0.005 if timeout == 5 else timeout)
        return event
    threading.Event = event_factory

hub.snapshot_download = download
hub.hf_hub_download = download
hub.HfApi = HfApi
hub_api.RepoFile = RepoFile
hub_api.RepoFolder = RepoFolder
sys.modules["huggingface_hub"] = hub
sys.modules["huggingface_hub.hf_api"] = hub_api
exec(compile(script, "<hf-production-script>", "exec"), {"__name__": "__main__"})
PY
}

teardown() {
  cleanup_sandbox
}

run_hf_fixture() {
  run_zsh '
    _hf_backend_command() { reply=("$HF_RECOVERY_PYTHON" -I "$HF_RECOVERY_SCRIPT"); }
  '"$1"
}

@test "hf recovery: non-gated repository statistics return success" {
  run run_zsh '
    _hf_repo_stats_data() {
      printf "%s\n" $'\''repository\tacme/model'\'' $'\''type\tMODEL'\'' \
        $'\''author\tAcme'\'' $'\''downloads\t42'\'' $'\''likes\t3'\'' \
        $'\''last_modified\t2026-01-01'\'' $'\''gated\tno'\'' \
        $'\''sha\tabc123'\'' $'\''tags\ttext-generation'\''
    }
    hf-repo-stats --type model --repo acme/model
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"Acme"*"abc123"* ]]
}

@test "hf recovery: real Python download adapter validates snapshots and cache symlinks" {
  run run_hf_fixture '
    hf-download --type model --repo acme/model --snapshot \
      >"$HOME/out" 2>"$HOME/err" || return
    hf-download --type model --repo acme/model --file "nested/weights.safetensors" \
      >>"$HOME/out" 2>>"$HOME/err" || return
    [[ ! -s "$HOME/out" && -d "$HOME/cache/snapshot" \
      && -f "$HOME/cache/snapshot/weights.safetensors" ]] || return 1
    grep -q "Download completed" "$HOME/err" || return 1
    ! grep -q "VENDOR_SECRET" "$HOME/err"
  '
  [ "$status" -eq 0 ]
}

@test "hf recovery: missing cache results never report a completed download" {
  export HF_RECOVERY_MODE=missing
  run run_hf_fixture 'hf-download --type model --repo acme/model --snapshot'
  [ "$status" -eq 1 ]
  [[ "$output" != *"Download completed"* ]]
  [[ "$output" == *"Retry: hf-download --type model --repo acme/model --snapshot"* ]]
}

@test "hf recovery: download failures explain access network and storage without vendor text" {
  for mode in access network storage; do
    export HF_RECOVERY_MODE="$mode"
    run run_hf_fixture 'hf-download --type model --repo acme/model --snapshot'
    [ "$status" -eq 1 ]
    [[ "$output" != *"TOKEN_SHOULD_STAY_HIDDEN"* ]]
    [[ "$output" != *"VENDOR_SECRET"* ]]
    [[ "$output" == *"Retry:"* ]]
    case "$mode" in
      access) [[ "$output" == *"Hub access was denied"* ]] ;;
      network) [[ "$output" == *"Hub connection failed"* ]] ;;
      storage) [[ "$output" == *"check free space"* ]] ;;
    esac
  done
}

@test "hf recovery: activity is visible before completion without exposing backend progress" {
  export HF_RECOVERY_MODE=progress
  run run_hf_fixture '
    hf-download --type model --repo acme/model --snapshot \
      >"$HOME/out" 2>"$HOME/err" || return
    [[ ! -s "$HOME/out" ]] || return 1
    grep -q "Download is still running" "$HOME/err" || return 1
    grep -q "Download completed" "$HOME/err" || return 1
    ! grep -q "VENDOR_SECRET" "$HOME/err"
  '
  [ "$status" -eq 0 ]
}

@test "hf recovery: direct and interactive download interruptions preserve their status" {
  for mode in interrupt terminate; do
    export HF_RECOVERY_MODE="$mode"
    local expected=130
    [[ "$mode" == terminate ]] && expected=143
    run run_hf_fixture 'hf-download --type model --repo acme/model --snapshot'
    [ "$status" -eq "$expected" ]
    [[ "$output" == *"Download interrupted"* ]]
    run run_hf_fixture '
      _hf_prompt() { REPLY=acme/model; }
      _hf_pick_repo_type() { REPLY=model; }
      _hf_fzf_capture() { REPLY=$'\''Whole repository snapshot\tsnapshot'\''; }
      hf-download
    '
    [ "$status" -eq "$expected" ]
    [[ "$output" == *"Download interrupted"* ]]
  done
}

@test "hf recovery: picker cancellation remains success and never starts a download" {
  run run_hf_fixture '
    _hf_prompt() { REPLY=acme/model; }
    _hf_pick_repo_type() { return 130; }
    hf-download || return
    [[ ! -e "$HOME/download-args" ]]
  '
  [ "$status" -eq 0 ]
}

@test "hf recovery: search file selection uses the same validated download executor" {
  run run_hf_fixture '
    _hf_fzf_capture() { REPLY=$'\''nested/weights.safetensors\t1'\''; }
    _hf_download_file_interactive acme/model model \
      >"$HOME/out" 2>"$HOME/err" || return
    [[ ! -s "$HOME/out" && -f "$HOME/cache/snapshot/weights.safetensors" ]] || return 1
    grep -q "Download completed" "$HOME/err" || return 1
    ! grep -q "VENDOR_SECRET" "$HOME/err"
  '
  [ "$status" -eq 0 ]
}

@test "hf recovery: interrupted backend discovery stops before downloading or fallback" {
  run run_zsh '
    HF_PYTHON="$HF_RECOVERY_PYTHON"
    _hf_run_probe() { return 143; }
    hf-download --type model --repo acme/model --snapshot
  '
  [ "$status" -eq 143 ]
  [ ! -e "$HOME/download-args" ]
}

@test "hf recovery: file list interruption exits before selection or download" {
  for code in 130 143; do
    export HF_RECOVERY_RC="$code"
    run run_hf_fixture '
      _hf_run_probe() { return "$HF_RECOVERY_RC"; }
      _hf_fzf_capture() { print -r called > "$HOME/picker"; return 97; }
      _hf_download_file_interactive acme/model model
    '
    [ "$status" -eq "$code" ]
    [ ! -e "$HOME/picker" ]
    [ ! -e "$HOME/download-args" ]
  done
}

@test "hf recovery: retry commands quote each argument without changing literal filenames" {
  run run_zsh '
    local filename="nested/weights \$(touch sentinel).safetensors"
    _hf_download_retry acme/model model file "$filename" 2>"$HOME/retry"
    local line="${${(f)$(<"$HOME/retry")}[1]}"
    line="${line#*Retry: }"
    local -a args=("${(@Q)${(z)line}}")
    (( ${#args} == 7 )) || return 1
    [[ "$args[1]" == hf-download && "$args[2]" == --type \
      && "$args[3]" == model && "$args[4]" == --repo \
      && "$args[5]" == acme/model && "$args[6]" == --file \
      && "$args[7]" == "$filename" ]]
  '
  [ "$status" -eq 0 ]
}
