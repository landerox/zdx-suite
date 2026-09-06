# GPU suite contract

This document freezes the public GPU interface and records the telemetry,
timeout, validation, and simulation boundaries.

## Public surface

The only canonical command is:

```text
gpu-visualizer [--once] [--simulate] [--gpu INDEX]
```

`gpu-menu` opens the interactive menu or routes this command directly.
`INDEX` is an integer from 0 through 255. Invalid syntax returns `2`;
interactive menu cancellation returns success.

The machine-readable surface is
`test/fixtures/gpu-public-commands.tsv`. Menu rows, help, dispatcher, lazy
loading, direct completion, and the public function must stay aligned with the
fixture.

## Hardware and simulation modes

Hardware mode is NVIDIA-only and requires both `nvidia-smi` and either
`timeout` or `gtimeout`. Each metrics and process probe has a three-second
deadline. Timeout status `124` is preserved; a missing runtime dependency is
an operational failure with status `1`.

Metrics and process occupancy have separate availability. When metrics are
valid but the process query fails, the frame retains those metrics and labels
the process inventory unavailable. It never substitutes an empty inventory or
synthetic data. `--once` returns the process-query failure status. Continuous
mode tries again on the next frame; quitting returns the most recent frame's
status, so a recovered frame can complete successfully. Backend interruption
statuses `130` and `143` stop the monitor immediately.

Simulation is never an automatic fallback. It runs only when the caller
explicitly supplies `--simulate`, and every rendered frame labels itself as
synthetic. `--once` renders one frame. Continuous mode requires both stdin and
stderr to identify the same usable terminal endpoint and the current process
group to own the terminal foreground; otherwise the command selects a single
frame. Screen clearing is emitted only while that foreground-terminal condition
still holds. Zsh reserves TTIN/TTOU handling while an interactive shell has
`MONITOR` enabled, so the visualizer locally disables `MONITOR` before ignoring
those signals. `LOCAL_OPTIONS` and `LOCAL_TRAPS` restore the caller's job-control
and signal state on return. This preserves the foreground-to-background race
protection without changing the long-lived interactive shell.

## Data and terminal boundary

GPU metrics are parsed as a fixed typed record. Temperature, fan, memory,
utilization, power, GPU identity, and driver values have explicit numeric or
length bounds. Process inventory is limited to 256 rows and 256 KiB, and each
PID, name, and memory value is validated before rendering.

All visualizer output is UI and goes to stderr. No process-control action is
offered. Numeric records use canonical decimal text before Zsh arithmetic, and
untrusted arguments are visibly escaped before diagnostics. Menu rows reject
controls, `fzf` runs in the foreground with a static read-only preview, and the
privately captured result must match the current menu snapshot. Picker
temporary roots and their ancestors are ownership- and mode-validated against
the current EUID or the namespace-visible owner of `/` (normally UID 0).

The command menu follows [`menu-spec.md`](menu-spec.md), with one monitoring
action and no decorative section. `Ctrl-/` toggles its compact command details;
the live visualizer retains its own telemetry layout and controls.

The suite does not support AMD, Intel, or non-NVIDIA telemetry. A real driver,
multi-GPU host, long-running pseudo-terminal refresh loop, and macOS host remain
manual acceptance boundaries. If overflow UID mapping collapses multiple host
owners into the visible owner of `/`, temporary-root trust additionally
depends on the namespace and mount configuration.

Focused coverage lives in `test/gpu.bats`, `test/gpu_contract.bats`, and
`test/gpu_recovery.bats`. Recovery fixtures exercise unavailable process data,
preserved interruption statuses, and a subsequent successful refresh without
querying real hardware.
