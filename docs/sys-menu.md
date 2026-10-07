# System suite contract

This document is the public contract for `sys-menu` on Linux, WSL, and macOS:
the frozen command surface, the capability runtime, the platform command
matrix, the not-applicable contract, and the update, cleanup, and resource
safety models. The repository-wide contracts in
[`development.md`](development.md) and [`menu-spec.md`](menu-spec.md) remain
authoritative.

Darwin routing is covered with mocks, and the macOS CI job runs the System
tests on an Apple Silicon runner; launchd, `softwareupdate`, Homebrew casks,
and real sudo timestamps are exercised there only through mocks. Residual
gaps are recorded in [`security-assessment.md`](security-assessment.md).

## Menu presentation

The command menu uses an 80% height, label-only rows, and four lines of details
below the list. Sections show only their description. Host context appears
above `Type to filter | Enter run | Esc cancel | Ctrl-/ details`.
The telemetry action menu uses the same details toggle and retains its compact
50% height. Resource browsers keep their own fields and action keys; the
details binding is not inherited by process, port, or service browsers.

## Public command surface

The inventory is
[`test/fixtures/sys-public-commands.tsv`](../test/fixtures/sys-public-commands.tsv).
It contains 25 commands with four fields:

```text
command<TAB>owning-module<TAB>risk<TAB>current-capability
```

The inventory is non-executable test data. The BATS contract proves that every
command is present in all public surfaces and is defined by its declared
module.

### Functional groups

| Group | Commands |
| --- | --- |
| Aggregate maintenance | `update-system`, `clean-system` |
| Package and tool updates | `update-apt`, `update-brew`, `update-snap`, `update-gcloud`, `update-awscli`, `update-node`, `update-rust`, `update-uv-system`, `update-pipx`, `update-starship`, `update-fzf`, `update-omz`, `update-zsh-plugins` |
| Focused cleanup | `clean-journal`, `clean-snaps` |
| Diagnostics | `sys-info`, `sys-health`, `sys-wsl`, `sys-startup` |
| User state | `sys-telemetry` |
| Host resources | `sys-ports`, `sys-services`, `sys-processes` |

### Public-surface invariant

These sets must remain identical:

1. command records in the fixture;
2. loaded public functions;
3. non-sentinel top-level menu records;
4. `_sys_dispatch` arms;
5. commands shown by `sys-menu --help`;
6. entries in `completions/_sys-menu`.

An intentional addition, rename, compatibility alias, or removal updates all
six surfaces and its contract tests in one change.

### Routing behavior

- `sys-menu` with no arguments opens the interactive command menu.
- Esc or an empty `fzf` selection returns `0` without dispatching an action.
- A direct canonical token is timed with the `sys:<command>` label.
- The direct route preserves the dispatched command's status.
- Mandatory feature modules load before `_SYS_MENU_SOURCED` is set.
- Re-sourcing the completed suite is silent and harmless.
- Unknown options and dispatcher tokens print an error and return `2`.

### Risk classification

Each command has one highest relevant risk:

| Risk | Meaning |
| --- | --- |
| `read-only` | Inspects state without an intended mutation |
| `mutating` | Changes user or tool state but is not primarily destructive |
| `destructive` | Deletes, overwrites, clears, or terminates a target |
| `privileged` | Can cross the `sudo` or host-service boundary |
| `remote-code` | Installs, updates, or sources code obtained from a remote origin |

## Loader and capabilities

The loader and the capability layer provide:

- standalone `sys-menu.zsh` sourcing without requiring `functions.zsh`;
- explicit, readable module loading with exact failure status preservation;
- owner-specific sentinels set only after each mandatory file completes;
- a single module root derived from the loader's own source path;
- a lazy capability registry with no host probes at source time;
- native Linux, WSL overlay, and macOS read-only adapters;
- registry-backed predicates for the systemd and Snap consumers;
- optional wrappers for the core timer and fzf theme.

Diagnostics and resource control run behind these capabilities, and update
and cleanup behavior is explicitly capability-gated.

### Load order and failure contract

`sys-menu.zsh` derives one trusted installation root from its own source path.
It resolves common and feature files only below that root, then loads them in
this order:

1. `sys-common.zsh`;
2. `sys-capabilities.zsh`;
3. Linux, WSL, and macOS adapters;
4. the feature modules in explicit dependency order.

Every candidate must be a readable regular file. A failed source operation
returns its original status, names the failed module on stderr, removes loader
temporary state, and leaves `_SYS_MENU_SOURCED` unset. Re-sourcing a completed
loader is silent.

The core lazy loader follows the same ownership rule: its explicit
command-to-file map resolves below the one source-derived `functions/` root.
It installs and restores stubs through Zsh's `functions` table rather than
constructing definitions with `eval`. The completion sentinel is set only
after configuration, module registration, plugins, telemetry helpers, and
overrides have loaded successfully, so a failed load can be retried.

The core `_timed` and `_tk_fzf_color_opts` functions are optional integrations.
When the suite is sourced directly, `_sys_timed` preserves execution and status
without telemetry, and `_sys_fzf` applies the local preset without a core
theme. The suite never creates global compatibility shims for missing core
functions.

### Capability registry

The registry is private implementation data. Detection occurs on first access
through `_sys_capabilities_ensure`, or explicitly through
`_sys_capabilities_refresh`. `sys-menu` refreshes it immediately before a
workflow so a long-lived shell does not retain stale host decisions.

| Key | Values |
| --- | --- |
| `os` | `linux`, `darwin`, `unknown` |
| `environment` | `native`, `wsl` |
| `architecture` | Lowercase `uname -m` result or `unknown` |
| `package_manager` | `apt`, `dnf`, `pacman`, `zypper`, `apk`, `brew`, `softwareupdate`, `unavailable` |
| `os_updates_backend` | `softwareupdate`, `unavailable` |
| `service_manager` | `systemd`, `launchd`, `unavailable` |
| `process_backend` | `procps`, `bsd-ps`, `unavailable` |
| `ports_backend` | `lsof`, `ss`, `unavailable` |
| `privilege` | `direct`, `sudo`, `unavailable` |
| `snapd` | `available`, `unavailable` |
| `wsl_interop` | `available`, `unavailable` |

`_sys_capability_value <key>` and `_sys_capabilities_print` emit data only on
stdout. `_sys_has_capability <namespace:value>` is the control-flow API and
supports the `os`, `environment`, `package`, `os-updates`, `service`,
`process`, `ports`, `privilege`, and `runtime` namespaces. It returns:

- `0` when a recognized predicate is satisfied;
- `1` when it is recognized but unavailable;
- `2` when its namespace or value is unsupported.

Feature code must use these accessors rather than reading
`_SYS_CAPABILITIES` directly. Tests may inject the map to isolate predicate
behavior.

### Adapter boundary

Adapters are private and read-only: they provide capability probes and typed
diagnostic collectors. They do not render UI, dispatch
public commands, request privilege, or perform maintenance. WSL is a Linux
overlay, not a third base OS: it reuses Linux collectors, then independently
detects systemd, Snap, and Windows interop. macOS support uses Darwin-native
backend names and does not emulate GNU or systemd behavior.

### Capability model

The registry detects a base operating system and independent
capabilities:

```text
base OS:       linux | darwin | unknown
environment:   native | wsl
packages:      apt | dnf | pacman | zypper | apk | brew | softwareupdate | unavailable
OS updates:    softwareupdate | unavailable
services:      systemd | launchd | unavailable
process data:  procps | bsd-ps | unavailable
ports:         lsof | ss | unavailable
privilege:     direct | sudo | unavailable
```

The registry also distinguishes direct root execution from `sudo`
and records `architecture`, an independent macOS update backend, Snap daemon
readiness, and WSL interoperability.

Public commands ask for capabilities rather than platform names. For example,
`sys-services` selects a systemd or launchd backend instead of wrapping its
workflow in one large operating-system conditional.

## Diagnostics

Host and shell diagnostics run on the capability layer:

- Linux, WSL, and macOS collectors for OS, memory, swap, CPU, uptime, load,
  packages, zombie processes, and service health;
- fixed capability routing between collectors and public commands;
- separate host and shell diagnostic modules with explicit loader ownership;
- platform-neutral disk and inode checks;
- portable Zsh startup timing that does not parse shell-specific `time` text;
- an isolated `zprof` subprocess that leaves no temporary profile file;
- bounded, schema-validated telemetry inspection;
- stderr-only human UI with control characters escaped before display.

### Diagnostic command contracts

| Command | Accepted interface | stdout | Notes |
| --- | --- | --- | --- |
| `sys-info` | No arguments, `--json`; `-h`, `--help` | Empty; with `--json`, one `zdx.sys-info.v1` document | Renders available host, tool, and package data on stderr |
| `sys-health` | No arguments; `-h`, `--help` | Empty | Runs every available read-only check; unsupported checks are reported as unavailable |
| `sys-wsl` | No arguments, `--json`; `-h`, `--help` | Empty; with `--json`, one `zdx.sys-wsl.v1` document | Reviews the WSL configuration read-only; see [WSL configuration review](#wsl-configuration-review) |
| `sys-startup` | No arguments; `-h`, `--help` | Empty | Runs ten bounded samples, then an isolated `zprof` pass; startup files may retain external side effects |
| `sys-telemetry` | `--dashboard`, `--browse`, `--clear [--dry-run] [--yes]`, help, or menu | Empty | Dashboard and browse are read-only; clear uses the [telemetry state](#telemetry-state) controls |

Unknown options return `2`. `sys-health` and `sys-wsl` return `0` when the
diagnostic run completes even if it reports findings; findings are not
operational failures. They return `1` only when the command cannot establish
its required runtime state; `sys-wsl` on a host that is not WSL follows the
[not-applicable contract](#not-applicable-contract).

### JSON output

`sys-info --json` and `sys-wsl --json` follow the repository JSON output
convention in [`output-spec.md`](output-spec.md). Only these read-only
commands accept `--json`, and with it a command never opens fzf or prompts:

- stdout carries exactly one compact JSON object followed by a newline and
  nothing else, with no ANSI sequences; warnings, errors, and the timing line
  stay on stderr;
- the first key is `"schema"`: `zdx.sys-info.v1` or `zdx.sys-wsl.v1`;
- keys are snake_case; an unknown or unavailable value is `null`, never an
  empty string or `unknown`; booleans are JSON booleans; counts and sizes in
  bytes are numbers;
- the document is built only by `jq -n` from `--arg` values; lists travel to
  jq as rows whose fields are proven free of control characters, never as
  concatenated JSON text;
- without a usable `jq`, the command names the missing capability on stderr
  and returns `1` before any host probe;
- the exit status equals the text mode's. A `sys-wsl` that does not apply
  prints `{"schema":"zdx.sys-wsl.v1","applicable":false,"reason":"not a WSL host"}`
  and returns `1`.

`zdx.sys-info.v1` maps the same typed facts as the text report: `os` (name,
kernel, architecture, environment), `wsl` (generation and Windows version, or
`null` outside WSL), `memory` and `swap` in bytes, `cpu`, `disks.root` and
`disks.home` (path, file system, total, used, and available bytes, and used
percent), `uptime_seconds`, `load_average`, `shell`, `oh_my_zsh`, `tools`
(every reported tool, with `null` when it is not usable), and `packages`
(counts per present manager, such as `apt`, `snap`, `npm_global`, and
`pipx`). The text report is unchanged.

### Platform collection matrix

| Data | Linux and WSL | macOS |
| --- | --- | --- |
| OS identity | `/etc/os-release`, optional `lsb_release` | `sw_vers` |
| Memory and swap | `/proc/meminfo` | `sysctl hw.memsize`; available memory from `kern.memorystatus_level`, falling back to free, inactive, and speculative `vm_stat` pages; `vm.swapusage` |
| CPU | `getconf`/`nproc`, `/proc/cpuinfo` | `sysctl` |
| Uptime and load | `/proc/uptime`, `/proc/loadavg` | `kern.boottime`, `vm.loadavg` |
| Main disk and inodes | `/` | The Data volume, `/System/Volumes/Data`; `/` is a sealed system snapshot |
| Packages | APT, RPM, Pacman, APK, Brew, optional Snap | Brew or Installer package receipts |
| Zombie processes | procps fields | BSD `ps` fields |
| Service health | systemd failed units when systemd is active | launchd jobs that are not running and last exited with a positive status; jobs ended by a signal are advisory; `com.apple.*` jobs are skipped unless `SYS_HEALTH_INCLUDE_APPLE_JOBS=1` |
| Kernel OOM events | `dmesg`, when readable | Not applicable: macOS has no kernel OOM log |
| Tool versions | The executable `PATH` selects; on WSL a program below `/mnt/<drive>/` (the appended Windows `PATH`) is skipped | The executable `PATH` selects; the `/usr/bin` `git`, `python3`, and `pip3` Command Line Tools placeholders are skipped unless `xcode-select -p` names an installed developer directory |
| WSL metadata | WSL generation and Windows version when interop works (`WSLInterop` or `WSLInterop-late`, `cmd.exe` from `PATH` or `/mnt/c/Windows/System32`) | Not applicable |

Missing optional data does not trigger a similarly named command from another
platform. It produces an unavailable or not-applicable result, and the
remaining checks continue. A world-writable tool executable is never probed or
run on any platform. Darwin decision and parser behavior is protected with
mocks, which the macOS workflow also runs on an Apple Silicon runner; the real
Darwin collectors are not host-verified until a documented manual run exists.

### Data and UI boundary

Adapter collectors emit one scalar or a documented TSV record. `sys-diag.zsh`,
`sys-wsl-config.zsh`, and `sys-shell-diag.zsh` format these values for people.
Public diagnostic UI, help, headings, blank layout lines, and findings go to
stderr, so the diagnostic commands emit no stdout data except the documented
`--json` document.

External values pass through a Zsh visible-character renderer before terminal
display. This prevents control characters in paths, command output, service
descriptions, or persisted records from becoming terminal instructions.
System UI enables ANSI color only on a stderr terminal when `TERM` is not
`dumb` and `NO_COLOR` is unset. The core timer and shared fzf theme honor the
same `NO_COLOR` opt-out.

### WSL configuration review

`sys-wsl` reviews how WSL is configured for the current distribution. It is
read-only: it changes no file, setting, or service, and it never runs a Windows
maintenance step. On a host that is not WSL it follows the
[not-applicable contract](#not-applicable-contract). Its report has these
sections:

| Section | Facts |
| --- | --- |
| Distribution | WSL generation (WSL1 or WSL2), kernel release, `WSL_DISTRO_NAME`, OS name, and the command name of PID 1 |
| `/etc/wsl.conf` | The reviewed settings `[automount]` `enabled`, `root`, and `options`; `[boot]` `systemd` and `command`; `[network]` `generateResolvConf`, `generateHosts`, and `hostname`; `[interop]` `enabled` and `appendWindowsPath`; and `[user]` `default`, each with its source line, the WSL default where one is documented, or `not set`. Other keys are listed as written without interpretation, and malformed lines by number and reason |
| Network | The IPv4 default-route interface from `/proc/net/route` and its MTU from `/sys/class/net`, an MTU pinned by a `[boot]` `command` of the form `ip link set [dev] <interface> mtu <value>`, whether WSL generated `/etc/resolv.conf`, the networking mode, and WireGuard (`DEVTYPE=wireguard`) and tun/tap interfaces |
| Windows `.wslconfig` | The Windows user profile and `%UserProfile%\.wslconfig` with `[wsl2]` `memory`, `processors`, `swap`, `networkingMode`, `dnsTunneling`, `autoProxy`, `firewall`, and `sparseVhd`, and `[experimental]` `autoMemoryReclaim` and `sparseVhd` |
| Virtual disk | The documented manual compaction steps for `ext4.vhdx`: `wsl.exe --shutdown`, locating the disk through the `Lxss` registry key, then `Optimize-VHD` or `diskpart` `compact vdisk`. Linux cannot read the disk's size reliably, so the size is not reported and the steps are never run |

Both configuration files are data. Each must be a readable regular file of at
most 64 KiB that contains no NUL byte, so a UTF-16 file is reported as not
read; the read is bounded by time and bytes. The INI parser accepts `#` and `;`
comments, a CRLF line ending, and a UTF-8 byte-order mark; it trims keys and
values and removes one pair of surrounding double quotes. Keys match without
letter case, and the last occurrence wins. A setting outside a section, under
an invalid header, with an invalid key, without `=`, with a control character
in its value, or with a boolean or count that does not parse is malformed and
stays unset. Nothing is sourced, expanded, or executed: a value such as
`$(touch x)` is shown as text. A value that contains a common credential
indicator, such as `password=` in a mount command, is withheld from the report
and from JSON.

The Windows profile comes from `wslvar USERPROFILE` when it is installed,
otherwise from `cmd.exe /c echo %USERPROFILE%` started in the directory of
`cmd.exe` so that it does not warn about a UNC working directory, and is
converted with `wslpath -u`, or else below the `[automount]` `root`. Each query
runs only when Windows interop is available and is bounded to five seconds;
when interop is disabled or a query fails or times out, the Windows section is
reported as unavailable. The networking mode comes from `.wslconfig`: the
`[wsl2]` value, then the `[experimental]` one that earlier WSL releases read,
and otherwise the default `nat`. It is unknown when `.wslconfig` was not
read and not applicable on WSL 1.

The review ends with factual findings and a verdict. Findings never change the
exit status. `appendWindowsPath` is reported only as a setting, because the
suites already skip Windows programs on `PATH`:

| Finding | Condition |
| --- | --- |
| `wsl-conf-unreadable`, `wslconfig-unreadable` | A configuration file exists but was not read |
| `wsl-conf-malformed`, `wslconfig-malformed` | Malformed lines, by number |
| `automount-metadata` | Automount is enabled without the DrvFs `metadata` option, so the File, Python, and Developer suites refuse projects on Windows drives |
| `boot-mtu-mismatch` | The interface MTU differs from the value a `[boot]` command pins |
| `tunnel-mtu` | The default-route interface uses MTU 1500 or more while a tunnel interface exists; the remedy names `vpn-menu vpn-mtu-probe` only when that command is defined or registered for completion in the shell |
| `systemd-not-running` | `[boot] systemd = true`, but PID 1 is not systemd |
| `systemd-disabled` | PID 1 is not systemd while service units are enabled for `multi-user.target` |
| `no-memory-limit` | WSL 2 with a readable or absent `.wslconfig` that sets no `[wsl2]` `memory` |

`zdx.sys-wsl.v1` carries `applicable`, `host`, `wsl_conf` and
`windows.wslconfig` (each with `state`, `reason`, the reviewed `settings` by
section in snake_case with `null` for an unset value, `withheld_keys`,
`other_keys`, and `malformed_lines`), `network` (including `boot_mtu_pin` and
`tunnel_interfaces`), `disk` (`vhdx_size_bytes` is always `null`, plus
`compaction_steps`), and `findings` with `id`, `message`, and `remedy`.

### Bounded diagnostics and telemetry

Optional version and package probes have short deadlines. GNU `timeout` or
`gtimeout` is used with a TERM deadline and KILL grace period; GNU timeout's
default process-group behavior also targets descendants. BusyBox-compatible
timeout remains supported, and a Zsh-native watchdog terminates the descendant
tree and reaps its direct child when neither implementation exists. Startup
samples use a 15-second deadline. The ten samples and isolated profile pass
execute startup files in eleven subprocesses; those files may still perform
their usual external side effects.

Timeouts bound observation, download, and archive-inspection work. A command
that has begun a package, cache, service, process, or other
mutating transaction runs directly to its reported result. ZDX does not return
from a timed-out mutation while descendants may still be changing state.

Telemetry dashboard and browser paths:

- accept only a readable, user-owned regular file, never a symbolic link;
- refuse files larger than `SYS_TELEMETRY_MAX_READ_BYTES`, which defaults to
  5 MiB;
- parse only the five documented fields and validate their character and
  numeric domains;
- reject implausible durations above one year and skip malformed or unsafe
  records, including a partial final record;
- send derived TSV fields to fzf instead of raw JSON;
- never display arguments, paths, environment values, output, or unknown JSON
  fields.

These reader controls are complemented by the owner-only writer, bounded
retention, atomic replacement, and hardened clear operation described under
[Telemetry state](#telemetry-state).

## Resources

Resource commands act on typed discovery records and exact targets, never on
formatted rows:

- procps and BSD `ps` process collectors;
- `lsof` and `ss` listening-port collectors;
- systemd and launchd service collectors and actions;
- stderr-only interactive browsers with read-only `fzf` selection;
- exact direct targets, confirmation, and post-confirmation revalidation;
- `SIGTERM` as the process default and explicit `--force` for `SIGKILL`;
- least-privilege `sudo` only for a foreign process or systemd action.

### Resource command contracts

| Command | Read-only interface and stdout schema | Mutation interface |
| --- | --- | --- |
| `sys-processes` | `--list` emits `process<TAB>pid<TAB>uid<TAB>cpu<TAB>memory<TAB>command` | `--terminate PID [--force] [--yes]` |
| `sys-ports` | `--list` emits `port<TAB>protocol<TAB>port<TAB>address<TAB>pid<TAB>command` | `--kill-port PORT` or `--kill port:PORT`, followed by optional `--protocol tcp\|udp`, `--force`, and `--yes` |
| `sys-services` | `--list` emits `service<TAB>backend<TAB>id<TAB>state<TAB>detail<TAB>description`; `--show ID` renders details | `--start`, `--stop`, `--restart`, `--enable`, or `--disable ID [--yes]` |

Human UI and help for the resource commands above use stderr. Only their
documented `--list` modes emit stdout data. A `sys-ports --kill` target must
carry the `port:` prefix; a bare number or a `pid:` target is rejected with
status `2`. Signaling a process by PID belongs to `sys-processes --terminate`,
so `sys-ports` resolves only listener targets.

### Resource identity and privilege controls

Process mutations capture a fingerprint containing the PID, UID, start value,
and command name. The complete fingerprint is compared again after
confirmation and immediately before signaling. PID 1, the current shell, and
its parent are protected. A process owned by another UID uses only
`sudo kill -s <SIGNAL> <PID>` after the final check. ZDX first revalidates the
fingerprint, runs `sudo -v` to authenticate, revalidates again in case the
prompt consumed time, and executes the final signal with `sudo -n`.

A port mutation must resolve to exactly one visible PID. After confirmation, a
port target is resolved again under the same rule and must still name the
same PID; the protocol, address, port, and PID record is rescanned, and the
process fingerprint is revalidated before the signal is sent. Hidden owners,
multiple owners, and changed listeners fail closed. Linux prefers `ss`, which
lists sockets whose owning process is not visible to the current user. A
non-root `lsof`, the only macOS backend and the Linux fallback, omits those
sockets entirely, so it cannot detect a hidden owner.

Systemd identifiers and launchd labels have separate validators. A service
action captures its backend state, confirms the exact operation, and compares
that state again before execution. Systemd crosses `sudo` only for the final
`systemctl` action. Its privileged path uses the same
revalidate/`sudo -v`/revalidate/`sudo -n` sequence. Launchd targets the job in
the domain of the current user that holds it, `gui/<uid>` for the login
session or else `user/<uid>`, without pretending to provide system-wide
launchd control. The state record carries that domain, so revalidation also
detects a job that moved. `--start` runs `launchctl kickstart`, `--restart`
runs `launchctl kickstart -k`, and `--stop` runs
`launchctl kill SIGTERM <domain>/<label>`: the job stays loaded, so a later
`--start` finds it again, and launchd restarts a job whose `KeepAlive` policy
asks for it. ZDX never runs `launchctl bootout`, which would unload the job.
BSD `ps` listings use `ps -axro`, sorted by current CPU usage like the procps
`--sort=-pcpu` listing.

Interactive resource browsers use `fzf --expect` only to return an action to
Zsh. They never place `kill`, `sudo`, `systemctl`, or `launchctl` inside an
`fzf` preview or binding. They run through the same foreground private capture
helper as the top-level menu rather than inside command substitution.

## Updates

The update orchestrator never runs an unverifiable upstream installer
automatically. Its contract covers:

- a capability-filtered `update-system` step plan with advisory package
  snapshots;
- `--dry-run`, `--yes`, `--fail-fast`, `--verbose`, and the explicit
  `--include-phased-updates` APT policy on the aggregate;
- maximum-scope default execution of every applicable installed updater,
  including Git-owned fzf, Oh My Zsh, and custom Zsh plugin updates;
- an explicit `--safe-only` mode that excludes those mutable-code origins,
  while `--include-remote-code` remains an explicit affirmation of the default;
- direct plan, dry-run, and confirmation controls for APT, Snap, Git-owned
  fzf, Oh My Zsh, and custom Zsh plugin updates;
- fast-forward-only pulls for Git-owned update paths;
- origin and current-commit display before executable-code updates;
- one aggregate authorization over a frozen set of applicable step entries:
  the interactive plan confirmation grants the same per-step consent as
  `--yes`, and execution neither replans nor inserts a newly applicable step;
- one persistent, owner-bound, non-blocking aggregate lock at the single
  canonical-home path, held by the invoking file descriptor for the authorized
  mutating execution;
- one APT entry first, immediately after aggregate pre-authentication, with an
  adjacent authorized cooperative yield request for an exactly validated
  automatic `unattended-upgrade` immediately before the single APT mutation
  sequence and no polling, sleep, or retry;
- prompt-free bounded Git transport for Git-owned updates: terminal and
  askpass credential prompts are disabled, SSH runs in batch mode with connect
  and keepalive deadlines unless the caller provides `GIT_SSH_COMMAND`, and
  Git aborts a transfer that stays below 1 KiB/s for 60 seconds;
- a Homebrew metadata refresh bounded to 120 seconds with curl-level retries
  set to zero through `HOMEBREW_CURL_RETRIES=0`, plus
  `HOMEBREW_NO_AUTO_UPDATE=1` on the mutating upgrade, autoremove, and cleanup
  phases;
- fixed zero-retry settings for the supported network controls of suite-owned
  uv, pipx/pip, Cargo, and rustup update clients, plus non-interactive pip
  input, without claiming control over Cargo's package-cache lock;
- visible Snap preview errors and deadlines, a `$ <command>` announcement
  whenever a step runs a privately captured command, closed stdin for every
  aggregate step and privately captured command, plus closed stdin on direct
  APT, Homebrew, native-package, and DNF-wrapper execution, and a per-step
  result with elapsed time in the aggregate summary table;
- reuse of a valid non-interactive sudo timestamp or one announced `sudo -v`
  after aggregate authorization, followed during the consecutive privileged
  entries by an invocation-owned `sudo -n -v` timestamp refresher every 30
  seconds and `sudo -n` for every ZDX-constructed package or signal operation
  that requires sudo;
- exact UI rendering of the resolved privilege prefix, including `sudo -n`
  when escalation is required and no prefix for direct-root execution;
- separate core-package and optional-tool outcome summaries, plus explicit
  `completed with partial failures` wording and non-zero aggregate status.

During planning, `update-system` validates and displays the single stable lock
path `${HOME:A}/.zdx-update-system.lock`. The canonical home directory must be
effective-user-owned, symlink-free, searchable, and not group/world writable;
runtime and cache directories are deliberately not alternate lock domains.
After authorization and before pre-authentication or any update entry, a
mutating run opens the persistent file as mode `0600`, validates its
effective-user ownership, single-link state, and descriptor/path identity, and
requests `zsystem flock -t 0`. An overlapping mutating execution fails
immediately as already running, without polling, retrying, or starting an
update entry. The owned descriptor is closed on every exit path. A nested invocation that
is refused because this shell already holds the lock leaves the outer
descriptor untouched. The lock file is never
unlinked and remains safely reusable by a later run. Dry-run performs only its
read-only plan and previews and does not acquire the execution lock.

The aggregate freezes the applicable step entries that it displays before
authorization. It executes those entries without a second applicability pass,
substitution, or insertion; by default each entry is attempted once, while
`--fail-fast` deliberately stops at the first failure. Package candidate lists
remain advisory snapshots rather than immutable transactions. A package
manager refreshes its metadata and resolves the final dynamic transaction at
execution. `--yes` authorizes the displayed entries and their documented
dynamic scopes; it does not bypass capability, dependency, owner, origin, or
target validation. The interactive aggregate confirmation grants that same
authorization, so entries do not prompt individually. The aggregate dry-run
runs non-mutating detailed previews for APT, Snap, and applicable remote-code
steps. A Snap preview error or deadline is a visible failed step, never a
successful "no pending updates" result. Direct update commands that do not
advertise `--dry-run` retain their narrower command-specific interface; the
aggregate flags must not be inferred to exist on every updater.

An entry returning `130` or `143` stops all subsequent System updates
regardless of `--fail-fast`. The summary reports the interruption and
remaining not-run counts, and preserves that status instead of treating it as
an ordinary partial failure.

APT's pre-refresh simulation is advisory. If it fails or times out, the plan
labels package candidates as unavailable and an authorized execution can still
refresh the indexes and resolve the real transaction. A dry run returns `1`
for that unavailable preview without mutating package state. Capability,
authorization, trusted-program validation, and dpkg audit checks still apply
before an executing APT entry.

The final aggregate summary separates core package steps—APT, the applicable
native package backend, Snap, and Homebrew—from all remaining optional tool
steps. Each denominator is the applicable frozen plan for that category;
completed successes, failures, and entries not run because of `--fail-fast`
are reported independently. For example, a continued partial failure can show
`Core package steps: 1/2 succeeded; 1 failed`, while fail-fast can show
`Core package steps: 0/2 succeeded; 1 failed; 1 not run`. The equivalent
`Optional tool steps` line uses the same accounting. Any failed entry still
makes the aggregate return non-zero. When at least one step succeeds, the final
line and outer timer say `completed with partial failures` while preserving
status `1`; an all-failed plan remains an ordinary failure.

### Aggregate output

The `update-system` plan considers 14 entries in this fixed order: APT, the
native package backend, Snap, Homebrew, Starship, fzf, Google Cloud SDK, AWS
CLI, uv, pipx, Node.js, Rust, Oh My Zsh, and Zsh plugins. Planning omits each
entry that does not apply to the host; the AWS CLI entry never applies
because its bundle installation is manual, and `--safe-only` also omits fzf,
Oh My Zsh, and Zsh plugins.

`update-system` renders its run as specified in
[`output-spec.md`](output-spec.md):

- The plan is a numbered `# · Step · Scope` table. The scope column is static
  text per entry, so planning still evaluates each entry's applicability
  exactly once. The APT scope reads
  `APT packages · sudo · key renewal for known repositories` unless
  `SYS_APT_KEY_RENEWAL=0` removes the renewal. At most two disclosures follow it: how many steps run mutable
  upstream code, and that one authorization runs every step with sudo
  requested at most once. APT's zero-wait policy, phased-update eligibility,
  and the lock path appear only with `--verbose` or `--dry-run`.
- Each entry prints a `── [n/N] Label ──` banner and one result line. A
  child's own heading is omitted inside the step; `--verbose` demotes it to a
  `▸` sub-heading and streams privately captured tool output live. A dry run
  shows each detailed preview the same way under `Detailed Previews`, followed
  by a `Preview Summary` table.
- Results follow the change-evidence rule. APT parses its transaction counts;
  Homebrew lists outdated packages before upgrading; Snap counts its pending
  refreshes; Git-owned checkouts compare HEAD before and after the pull; uv,
  Starship, Homebrew-owned AWS CLI, Rust, and Node.js compare versions; and
  pipx compares its application inventory. A step without such evidence
  reports `done`, and an entry that hands work to another owner reports
  `delegated`.
- The `Update Summary` table lists every entry with its result, time, and
  detail. The core and optional category lines, the verdict, each failed
  entry with its cause, and the public commands that retry them follow. The
  outer timer prints the only total time.
- APT's own output stays visible while it runs. A failed index refresh is
  diagnosed from a bounded copy of that output: a `Repository · Problem` table
  names each failing source, such as a missing or expired signing key, an
  expired or missing Release file, or a failed fetch. One next step and the
  number of candidates left pending follow. Displayed sources have URI
  credentials removed. A signing-key problem of a known repository is first
  renewed as described under [APT signing-key renewal](#apt-signing-key-renewal);
  the diagnosis covers what remains.

APT is the first authorized aggregate entry, immediately after authorization
and the single applicable pre-authentication. Before sending any signal, ZDX
requires an empty dpkg transaction journal and a clean bounded `dpkg --audit`.
The audit resolves absolute `env` and `dpkg` programs whose files and directory
chains are root-owned and not group- or world-writable, then runs them through
a fixed `env -i`. A dirty or unverifiable state fails the APT entry immediately
without signaling the current owner, which may be the only process able to
finish that transaction.

APT planning does not call the generic package-manager process-busy detector
and never treats a process-name scan as lock ownership. Its only optional
process discovery is the exact unattended-upgrade fingerprint described below.
If no eligible fingerprint exists, ZDX still makes the one native zero-timeout
APT attempt; only APT's own lock acquisition decides whether that attempt can
start.

Only after that state is clean, immediately before the single mutation
sequence, ZDX may request one cooperative yield when all of these properties
validate: the root-owned, non-link, bounded
`/run/unattended-upgrades.pid` file identifies a root process; its exact
command is `/usr/bin/unattended-upgrade`; its argv contains no effective
`--no-minimal-upgrade-steps` opt-out, including accepted abbreviations; its
kernel name is `unattended-upgr`; its start identity is stable; its cgroup
belongs to
`apt-daily.service` or `apt-daily-upgrade.service`; the packaged program is
root-owned and not group/world writable; `/proc/<pid>/status` has a valid
`SigCgt` mask with the SIGTERM bit set; and the version-appropriate
`MinimalSteps` rules permit a graceful boundary. The signal-caught mask is
part of every fingerprint reconstruction, so initial discovery and every
identity revalidation fail closed if the real process does not report a
SIGTERM handler.

The `MinimalSteps` decision itself is queried and revalidated through resolved
absolute `env` and `apt-config` programs whose files and directory chains are
root-owned and not group- or world-writable. Each query is time- and
output-bounded and runs under fixed `env -i` with nonexistent HOME/XDG roots,
`LC_ALL=C`, the system `PATH`, and `TERM=dumb`. Caller `APT_CONFIG`, `PATH`,
proxy, and exported-function state therefore cannot authorize a signal.

Signal eligibility also has an explicit package-version gate. A
bounded, single-record `dpkg-query` must prove that `unattended-upgrades` is
installed and return an unambiguous version; trusted absolute `env`,
`dpkg-query`, and `dpkg` programs then perform the query and Debian version
comparisons under fixed `env -i`, fixed `PATH`, and closed stdin. A leading
numeric Debian epoch is validated and removed before comparing the upstream
version against 0.94 and 0.95, so an epoch cannot falsely satisfy a feature
gate. Versions older than 0.94, missing packages, and malformed or ambiguous
results never authorize a signal. On the normalized 0.94 line, the two
supported `MinimalSteps` spellings follow upstream OR semantics with a false
default: at least one must be explicitly true. On 0.95 and newer, they follow
AND semantics with a true default: both effective values must be true, while
either absent key defaults to true. The version and configuration gates are
repeated immediately before signaling. This boundary follows upstream commits
`5f013f8` (TERM handling released in 0.94) and `16fb837` (`MinimalSteps`
defaulting to true in 0.95).

The process identity is revalidated before privilege, after `sudo -v`, and
immediately before the fixed, root-owned
`sudo -n /usr/bin/kill -s TERM` operation. At most that one signal is sent.
ZDX does not signal `apt`, `apt-get`, `dpkg`, a manually launched updater, or
any owner that fails the exact fingerprint. It does not stop or disable the
systemd timers or delete a lock file. `SYS_APT_AUTOMATIC_TAKEOVER=0` disables
the cooperative signal without enabling a wait; the default is `1`, and any
other value fails closed before signaling.

No independent aggregate entry runs between the optional yield request and the
single APT mutation sequence. There is no package-lock polling, sleep,
deferred retry, or second APT entry. The only repeated APT call is the single
index refresh that verifies a renewed signing key. Before simulation or mutation, `update-apt`
resolves a trusted absolute `env` executable whose file and directory chain is
root-owned and not group- or world-writable. Every APT invocation runs through
that executable's `env -i` with only `HOME=/nonexistent`, the XDG cache,
configuration, and data roots set to `/nonexistent`, `LC_ALL=C`,
`PATH=/usr/sbin:/usr/bin:/sbin:/bin`, `TERM=dumb`,
`DEBIAN_FRONTEND=noninteractive`, and `APT_LISTCHANGES_FRONTEND=none`. Caller
and post-sudo state—including `APT_CONFIG`, proxies, and exported-function
records—therefore cannot reach `apt-get`. Required proxy policy belongs in
root-owned APT configuration.

Normal APT phased-rollout policy is preserved by default. The explicit
`--include-phased-updates` flag is accepted by both `update-apt` and
`update-system`; the aggregate forwards it only to its APT entry. When present,
APT appends `-o APT::Get::Always-Include-Phased-Updates=true` to the advisory
simulation, index update, full upgrade, and autoremove. Omitting the flag does
not disable phased updates; it leaves APT's normal eligibility decision
unchanged.

The index refresh uses `apt-get update --error-on=any`, so even a transient
repository error fails the entry instead of silently retaining old indexes
and reporting success. A failed refresh skips full-upgrade and autoremove but
still reaches the post-transaction dpkg audit. An APT version that does not
support this option fails visibly; there is no fallback that ignores index
errors.

Every `update-apt` `apt-get` invocation sets `DPkg::Lock::Timeout=0`,
`Acquire::Retries=0`, `Dpkg::Use-Pty=0`,
`Dpkg::Options::=--force-confdef`, and
`Dpkg::Options::=--force-confold`; simulation and mutation receive `/dev/null`
as stdin. The frontend and PTY controls prevent hidden terminal prompts; the
paired conffile policy takes dpkg's defined default and otherwise keeps the
installed configuration. Normal output announces only the effective operation,
such as `sudo -n apt-get full-upgrade -y`; during a non-dry-run execution,
`update-apt --verbose` also renders the complete isolated `env -i` invocation
and policy arguments. A verbose dry run remains target-oriented and does not
render mutation commands that will not execute.
`update-system --verbose` forwards that display choice only to its APT entry.
APT's own transaction output remains visible in both modes. Observing a generic
process owner cannot gate the
attempt; if APT's native acquisition finds a lock after the one yield request,
that attempt fails immediately. No post-signal process-name scan gates
execution. Without `--fail-fast`, the aggregate records that partial failure
and then attempts each subsequent authorized entry; with `--fail-fast`, it
stops at the APT failure. Repair is never started implicitly. No
already-started package mutation is placed inside a timeout.

After the mutation sequence finishes, including after a failed mutation skips
its remaining phases, APT repeats the trusted dpkg journal and bounded
`dpkg --audit` validation in post-transaction mode. A dirty or unverifiable
result is a visible failure, returns non-zero, and suppresses the APT-completed
message and any reboot-marker inspection. When the post-audit is clean, reboot
status is inspected even if a package mutation failed: a stable, root-owned,
non-link `/run/reboot-required` marker produces a reboot-required warning,
while an unsafe marker produces an unknown-status warning. Both are advisory:
ZDX never reboots automatically, and the warning does not change the
transaction's success or failure status.

The aggregate's sudo timestamp refresher starts only after successful
pre-authentication and is scoped to the initial consecutive privileged entries
(APT, the applicable native package backend, Snap, and on macOS the adjacent
Homebrew entry because casks can require sudo). It invokes only `sudo -n -v`
with closed stdin, once when it starts and then every 30 seconds, so it cannot
open another credential prompt.

sudo keeps its timestamps per terminal session by default (sudoers
`timestamp_type=tty`): a refresh counts only when it runs on the controlling
terminal, and in the session, of the authentication. The refresher therefore
runs as a process substitution of the invoking shell rather than in a `zpty`
pseudo-terminal, which is a separate session and terminal and could never
renew the user's timestamp. The worker shares the caller's session and
terminal, never enters the interactive job table, so it cannot emit
`[n] ... terminated` or `done` notifications, and in an interactive shell runs
in its own process group, so terminal signals do not reach it. Its only output
is a private status pipe to the caller. Its first refresh happens before it
reports ready; when that refresh fails, for example under sudoers
`timestamp_type=ppid`, ZDX stops the worker and prints a warning that a step
outlasting sudo's timestamp timeout will fail rather than reprompt. A later
failed refresh is not retried; the worker then only waits for its stop, and
cleanup prints the same kind of warning. The worker checks its caller before
every refresh and exits without refreshing once that shell has exited.

The handle names the worker PID, the caller's descriptor for the status pipe,
and that pipe's device and inode. Cleanup acts only while the descriptor is
still that pipe and the open pipe proves the worker still runs, so the PID
cannot belong to another process. It sends one `SIGTERM` stop request,
requires the worker's acknowledgement and the end of the pipe within five
seconds, and closes the descriptor after the last privileged entry; an
`always` block performs the same lifecycle on an early failure, return, or
interruption. Every privileged command constructed by ZDX uses `sudo -n`, and
its UI line displays that exact resolved prefix. Homebrew is the external
exception described below. A direct `update-apt` invocation authenticates
once; its timestamp refresher uses only `sudo -n -v`, every later signal or APT
operation that requires elevation uses `sudo -n`, and the worker is owned only
for that APT sequence with the same `always` cleanup. That the refresher
renews a real sudo timestamp is verified only by session and terminal identity
and by a sudo mock; no run against real sudo is recorded.

System first parses a bounded DNF major-version record. The version probe, and
the DNF5 main-configuration probe described below, run through a resolved
absolute `env` executable whose file and directory chain must be root-owned and
not group- or world-writable. They use `env -i` with only
`HOME=/nonexistent`, `XDG_CACHE_HOME=/nonexistent`,
`XDG_CONFIG_HOME=/nonexistent`, `XDG_DATA_HOME=/nonexistent`, `LC_ALL=C`,
`PATH=/usr/sbin:/usr/bin:/sbin:/bin`, `TERM=dumb`,
`DNF5_FORCE_INTERACTIVE=0`, and `PYTHONNOUSERSITE=1`. The probes therefore do
not inherit `DNF5_PLUGINS_DIR`, loader or Python variables, or user
configuration roots.

Both DNF5 mutation paths elevate the same fixed wrapper under a trusted
root-owned Zsh. The privileged command first runs the trusted absolute `env -i`
with the fixed assignments above, then starts the Zsh wrapper. Its positional
argv contains only lock mode, lock path, frozen persist directory (empty for
DNF5 5.0/5.1), and the validated absolute DNF and `env` programs. No secret
assignment is serialized across `sudo` or shown in UI, and no inherited
environment reaches Zsh. The only Zsh startup-file trust boundary is the
root-owned system `/etc/zshenv`. Inside the wrapper, both programs are
revalidated and a second trusted `env -i` starts DNF with the same fixed
environment. No caller or post-sudo variable survives either boundary,
including proxies and exported-function records whose names Zsh cannot
reliably enumerate. A required proxy must be configured in root-owned DNF
configuration; caller environment settings are intentionally ignored.

For DNF4, both the bounded `check-update` preview and the mutating
`upgrade --refresh` command pass `--setopt=exit_on_lock=True` and
`--setopt=retries=1`. The former refuses a held DNF4 lock. The latter is DNF4's
minimum finite network policy: one retry permits up to two attempts. Zero is
not used because DNF4 defines zero retries as unlimited.

DNF5 does not use its candidate preview because the read path in lock-capable
versions can wait on the system-repository lock. Instead, the bounded version
probe records the canonical minor version. The resulting compatibility matrix
is explicit:

- The DNF5 5.0/5.1 compatibility path deliberately does not depend on
  `--dump-main-config`, including on 5.1 builds that provide it. Those versions
  predate the system-repository wait lock. System issues no configuration
  probe, freezes no `persistdir`, and invokes sanitized wrapper mode `0`. Its trusted
  `env -i` child runs `dnf --installroot=/ --assumeyes --refresh upgrade`, and
  the transaction lock remains non-blocking.
- DNF5 5.2 and 5.3 use the bounded `--dump-main-config` probe, which must yield
  exactly one `installroot=/` and one normalized absolute `persistdir`, with no
  `skip_system_repo_lock` capability. Wrapper mode `0` uses the trusted
  `env -i` child to run
  `dnf --installroot=/ --setopt=persistdir=<frozen-absolute-path> --assumeyes --refresh upgrade`.
  These versions have no system-repository wait lock, and their transaction
  lock remains non-blocking.
- DNF5 5.4 or newer must additionally yield exactly one valid boolean
  `skip_system_repo_lock` capability or the entry fails before mutation.

For DNF5 5.4 or newer, the wrapper runs in mode `1`, revalidates the paths and
absolute DNF5 program, then attempts the same whole-file `fcntl` write lock through
`zsystem flock -t 0`. If another owner holds it, the step fails immediately
before DNF5
starts. While holding that lock, the wrapper invokes DNF5 through the trusted
fixed `env -i` environment as
`dnf --installroot=/ --setopt=persistdir=<frozen-absolute-path> --setopt=skip_system_repo_lock=True --assumeyes --refresh upgrade`; all global flags precede the command. The
specific override avoids reacquiring only the system-repository lock already
held by the guard; DNF5's separate transaction lock remains enabled. ZDX does
not time out or kill either active mutation path. DNF5's `retries` setting is
deprecated and has no effect; it exposes no effective supported replacement
that disables network retries. Those upstream retries therefore remain an
external residual rather than a package-lock wait.

Where an updater exposes a public finite retry setting with zero meaning
disabled, System fixes it for the suite-owned invocation:
`UV_HTTP_RETRIES=0` for uv, `PIP_RETRIES=0` with `PIP_NO_INPUT=1` for
pipx/pip, `CARGO_NET_RETRY=0` for Cargo, and `RUSTUP_MAX_RETRIES=0` for
rustup. These settings remove the supported client-level retries; they do not
place an already-started mutation inside a timeout or claim control over an
underlying tool's undocumented behavior. In particular, `CARGO_NET_RETRY=0` does not stop
Cargo from waiting for its package-cache lock, for which Cargo exposes no
supported zero-wait switch.

APK receives `--wait 0` on both the mutating `apk update` and `apk upgrade`
commands, so ZDX does not ask APK to wait for its database lock. Pacman has no
supported zero-retry switch for its mirror traversal and package-download
retries; `pacman -Syu --noconfirm` retains that upstream behavior without a
mutation watchdog.

Direct APT, Homebrew, and native-backend commands, plus the outer DNF5 wrapper
and its inner DNF child, receive `/dev/null` as stdin even outside the
aggregate, so an upstream prompt cannot consume the caller's terminal.

Zypper's `--non-interactive` mode prevents prompts, but upstream hardcodes up
to three soft-media retries with 30-second sleeps and exposes no supported
override. ZDX reports that limitation at runtime. It does not place an
already-started `zypper refresh` or `zypper update` mutation inside a watchdog.
The package-update no-wait/no-retry guarantee is limited to lock or acquisition
waits and retries constructed by ZDX plus controls that upstream tools actually
support; it is not universal over package-manager internals.

Homebrew resource locking is left to Homebrew itself. ZDX never treats a
process merely containing `brew` or `Linuxbrew` in its arguments as a lock and
never renders another process's full argument vector. Suite-owned Homebrew
execution resolves `brew` once to an absolute executable and invokes that path
directly. Retry, analytics, Darwin askpass, and no-auto-update controls are
local exported Zsh parameters rather than `env NAME=value ...` arguments; a
caller-defined `env` function therefore cannot intercept the timeout fallback
or discard them. `update-brew` locally shadows and unsets inherited
`HOMEBREW_NO_AUTO_UPDATE` and `SUDO_ASKPASS` before the explicit metadata
refresh. It then applies only its phase-owned no-auto-update and Darwin
root-validated false-askpass values. Suite-owned probes and mutations set
`HOMEBREW_NO_ANALYTICS=1`, and `_sys_brew`, every `update-brew` phase, and the
Homebrew uv upgrade set `HOMEBREW_NO_ENV_HINTS=1`, which removes only
Homebrew's `Hide these hints with HOMEBREW_NO_ENV_HINTS=1` advice and its
cleanup hint while Homebrew's normal output stays visible. Every `update-brew`
phase also sets `HOMEBREW_CURL_RETRIES=0`, and the metadata refresh has a
120-second deadline.
Every Homebrew phase also receives `/dev/null` as stdin. That variable disables
only curl-level retries. Homebrew 6 retains
internal `DownloadQueue` retry behavior and download-lock waiting, with no
public option to disable either. The 120-second outer deadline bounds
`brew update`, but the mutating Homebrew phases retain those external
transaction semantics. ZDX does not claim a global no-retry or no-wait
guarantee for Homebrew and does not kill an active Homebrew mutation. Every
Homebrew phase on macOS also receives a fixed askpass program that always
fails: `SUDO_ASKPASS=/usr/bin/false` when that file is a root-owned, singly
linked, executable regular file that group and other users cannot write.
Otherwise ZDX creates a private fallback, `zdx-sys-askpass.XXXXXX/false-askpass`
below the validated temporary root, mode `0700`, whose only content is
`#!/bin/sh` and `exit 1`; `/bin/sh` must itself be root-owned and not
group- or world-writable. An `always` block removes that exact file and
directory after the Homebrew run. Without either program, the Homebrew run is
refused. Homebrew can invoke its own `sudo -A` for casks rather than ZDX's
`sudo -n`; the failing askpass program makes an unavailable cached credential
fail without a prompt. Linuxbrew does not use this Darwin-only guard. The
related pre-authentication guidance is rendered only when a Darwin plan
actually includes Homebrew; Linux never shows
the macOS askpass warning. On macOS the Homebrew entry is adjacent to the
other privileged package entries and remains within their bounded sudo
timestamp scope. The authorized mutation always uses
`brew upgrade --no-ask`: current Homebrew defaults to ask mode and can otherwise
skip an upgrade without a TTY while returning success. A real Homebrew failure
is reported for that step while later independent updates continue.

The aggregate assigns each installation to one updater. For fzf, the active
executable decides: when the `fzf` found in `PATH` lies inside a discovered
Git checkout, that checkout is updated even if an inactive APT or Homebrew
package is also installed; otherwise an installed package owns it.
Homebrew-owned AWS CLI, Starship, fzf, uv, and Google Cloud SDK
installations are covered by `update-brew` rather than repeated by a
tool-specific step. The uv decision is bound to the active external
executable: System resolves it canonically and attributes it to Homebrew only
when that path is the uv formula below the resolved Homebrew prefix. A
separately installed Homebrew formula therefore does not hide an earlier
self-managed uv in `PATH`; `update-uv-system` invokes that exact resolved
executable. A direct `update-uv-system` call for the active Homebrew formula
performs only `brew upgrade --no-ask uv`, using local retry, analytics,
no-auto-update, and Darwin askpass controls with closed stdin. It resolves the
launcher again after Homebrew may have replaced its Cellar target and requires
a successful bounded version probe before reporting success. The self-managed
path also requires that post-update probe. The Google Cloud SDK follows the
same active-executable rule: Homebrew owns the active `gcloud` when it, or the
file it resolves to, lies in the `gcloud-cli` or `google-cloud-sdk` cask
under `Caskroom`, or in `share/google-cloud-sdk`, below the
Homebrew prefix; APT owns it when it resolves below `/usr/lib/google-cloud-sdk`
and `google-cloud-cli` is installed; otherwise `update-gcloud` runs that exact
executable's `components update`. Aggregate deduplication remains unchanged.
On macOS, the native `softwareupdate` step remains independently applicable
when Homebrew is the primary package backend, so operating-system and formula
updates can both run. Homebrew is ordered next to that privileged native step
so cask installers remain inside the bounded sudo refresher window.

Every tool step acts on the executable that the user's `PATH` selects. On WSL
a program below `/mnt/<drive>/`, such as the Windows Cloud SDK's `gcloud`
script on the appended Windows `PATH`, is not this host's tool: its step does
not apply, and a direct command reports it as skipped. A world-writable tool
executable is refused on every platform: its step stays in the plan and
reports `blocked`. On macOS the `git`, `python3`, and `pip3` Command Line Tools
placeholders in `/usr/bin` count as absent unless `xcode-select -p` names an
installed developer directory, because running one opens an installation
dialog. A WSL distribution that mounts drives elsewhere through
`automount.root` is not recognized by this path rule.

The macOS native step parses a bounded `softwareupdate --list` (120 seconds,
stdout and stderr together) in its current `* Label:` layout and its older
indented `* <label>` layout into labels with their restart flag. When the list
reports `No new software available.`, the step is `current` and runs no
privileged command. An update that needs a restart or shutdown (`Action:` in
the current layout, `[restart]` in the older one) and every macOS update or
upgrade are not installed: they need a restart and, on Apple silicon, the
credentials of a volume owner, which ZDX never passes. A pending restart is a
normal state of a Mac rather than a failure, so the step lists those labels as
`⊘ skipped`, prints a warning that names them, and points to System Settings >
General > Software Update or to running
`sudo softwareupdate --install --restart <label>` yourself. Only the remaining
labels are installed, with
`sudo -n softwareupdate --install --no-scan <label>...`; ZDX never uses
`--all`, `--restart`, `--user`, or `--stdinpass`. With only restart labels
pending, the step reports `skipped` and returns `0` without requesting
privilege; after installing the other labels it reports `updated`, with the
exact pre-listed labels as its change evidence and the pending restart labels
in its detail. Real failures still fail the step: a list probe that fails,
times out, or returns an unrecognized list; a label that is empty, overlong,
contains a control character, or starts with `-` or whitespace, which is
refused before anything is installed; and a failed installation. The
aggregate's single pre-authentication still covers this step when its plan is
frozen, because the list is read only at execution.

Git-owned fzf, Oh My Zsh, and custom plugin updates require owned,
symlink-free checkouts below `HOME`. Their plans show the origin and current
commit, repository identity and origin are revalidated after authorization,
and mutation uses `git pull --ff-only origin`. Naming the displayed remote
makes Git refuse a branch whose upstream is another remote or a bare URL,
instead of fetching from a source the plan never showed. The transport exports
an empty `GIT_ASKPASS`, which also disables a configured `core.askPass`. The
fzf integration installer must be an owned, singly linked executable whose
content matches the checked-out Git blob. Oh My Zsh does not execute the
mutable `tools/upgrade.sh` helper.

There is one non-mutating discovery exception for the installation layout
created when the ZDX installer runs from a local checkout. An exact
`plugins/zdx-suite` symbolic link is recognized only when its canonical target
is the active ZDX root derived from the validated `_ZDX_FUNCTIONS_DIR`. The
link must be current-user-owned, singly linked, and identity-stable around
canonical resolution; the active root, its source markers, and its real
`.git` directory remain owner-bound and symlink-free below `HOME`. The System
updater reports that linked development checkout as managed from its source
checkout, skips it without running Git, and does not count the omission as an
update failure. A regular `zdx-suite` clone remains an ordinary update
candidate. Every other symbolic link, including the same basename targeting
another checkout, fails safety validation; the generic Git updater never
follows it.

`update-awscli` upgrades an existing Homebrew-owned installation and redirects
a Snap-owned installation to `update-snap`. Otherwise it refuses automatic
bundle installation and points to AWS's detached-signature procedure.
`update-starship` updates only a Homebrew- or Cargo-owned installation and
refuses an installation whose owner cannot be established. Neither command
downloads and executes an unverified installer script.

`update-node` resolves an external fnm to one absolute path, or uses an
already-loaded nvm installation. Installation, default selection, and activation
are checked separately. A failed default or activation phase preserves the
installed runtime, reports the remaining action, and returns `1`; independent
default and activation phases still run. A success message requires fnm's
bounded current-version probe to report `vX.Y.Z`, or nvm's current version to
match the validated installed LTS version. NVM activation runs in the calling
shell so its session and `PATH` changes persist; discovery never loads shell
code implicitly.

System update and cleanup helpers that capture tool output keep only a
configurable byte-bounded tail in an owner-only temporary directory. On
failure, at most the final 80 lines are rendered with control characters made
visible; a line containing a common credential indicator is replaced by a
redaction notice. Captured commands receive `/dev/null` as stdin so an
unseen prompt cannot consume terminal input or block the aggregate. The
temporary capture is removed on every exit path.

### APT signing-key renewal

A third-party repository can rotate its signing key or let it expire. APT then
refuses the repository with `NO_PUBKEY` or `EXPKEYSIG`. `update-apt`, and therefore the
APT step of `update-system`, renews such a key for a curated registry of known
repositories and gives plain guidance for every other one.

| Repository | Source URI (`https` only) | Key URL |
| --- | --- | --- |
| GitHub CLI | `cli.github.com/packages` | `https://cli.github.com/packages/githubcli-archive-keyring.gpg` |
| Google Cloud SDK | `packages.cloud.google.com/apt` | `https://packages.cloud.google.com/apt/doc/apt-key.gpg` |
| Charm | `repo.charm.sh/apt` | `https://repo.charm.sh/apt/gpg.key` |
| Docker | `download.docker.com/linux/debian` or `/linux/ubuntu` | `https://download.docker.com/linux/<distro>/gpg` |
| HashiCorp | `apt.releases.hashicorp.com` | `https://apt.releases.hashicorp.com/gpg` |
| Microsoft | `packages.microsoft.com` | `https://packages.microsoft.com/keys/microsoft.asc` |
| NodeSource | `deb.nodesource.com` | `https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key` |
| Google Chrome | `dl.google.com/linux` | `https://dl.google.com/linux/linux_signing_key.pub` |

A source matches on its scheme, its exact host, and a whole path prefix; a URI
with credentials, a port, or percent-encoding never matches. ZDX reads
`/etc/apt/sources.list` and the `*.list` and `*.sources` files of
`/etc/apt/sources.list.d` (one-line entries with `[signed-by=/path]` and deb822
stanzas with `Signed-By: /path`; disabled stanzas are skipped) to find the
keyring of the failing `<uri> <suite>`. Only a dedicated keyring is renewable:
one absolute `.gpg` or `.asc` path directly in `/etc/apt/keyrings` or
`/usr/share/keyrings`, a regular, singly linked file that is not a link, owned
by root and not group- or world-writable, in a root-owned directory that only
root can write. A source without `signed-by` (global trust), a deb822 stanza
with an inline key block such as a Launchpad PPA, a fingerprint or several
keyrings, a keyring shared with another publisher's repository, and an
unknown repository are never changed.

One renewal is one transaction for one keyring:

1. The plan facts are shown: repository, source file, keyring, key URL, the
   current keys with their expiry, and the key ID APT asked for.
2. The trusted curl downloads the key URL as the user with `-q`,
   `--proto =https --proto-redir =https --tlsv1.2`, at most five redirects,
   10 seconds to connect, 30 seconds and 1 MiB in total, into a private
   `zdx-sys-apt-key.XXXXXX` directory below the validated temporary root.
3. gpg parses the key with `--show-keys --with-colons` in a private throwaway
   home inside that directory; the user's keyring is never read or changed.
   An armored key is converted with `gpg --dearmor` for a `.gpg` keyring; an
   `.asc` keyring keeps armored text and refuses a binary key.
4. The staged key is accepted only when it holds a currently valid,
   signing-capable key or subkey whose fingerprint ends with a key ID that
   APT reported (`NO_PUBKEY`, `EXPKEYSIG`, or APT 3's sqv `Missing key`, at
   least 16 hexadecimal digits). A proactive renewal has no key ID and
   requires a valid signing key that the old keyring does not hold as valid.
   The accepted key is shown as `New key: 7F38 BBB5 … 6231 3325`.
5. A private copy of the current keyring is kept, the keyring is checked
   again, and the staged file is installed with the announced
   `sudo -n <trusted install> -m 0644 -o 0 -g 0 <staged-key> <keyring>`,
   then compared byte for byte.
6. APT refreshes its indexes once more. The key is kept only when that
   refresh succeeds, or fetches every repository of the keyring without a
   failure; ZDX then prints
   `✔ Renewed the GitHub CLI signing key (7F38 BBB5 … 6231 3325)`. Otherwise
   the previous keyring is reinstalled with the same argv and its previous
   mode, and ZDX reports that APT still cannot verify the repository. An
   interruption before that check also restores it.

Before `apt-get update`, ZDX renews every dedicated keyring of a known
repository whose signing keys have all expired; that refresh is its
verification. After a failed refresh, it renews each known repository whose
key APT reported missing or expired, at most once per keyring, and retries
`apt-get update --error-on=any` exactly once; when the retry succeeds the step
continues normally. A renewed key is change evidence: the step reports
`updated`, and its summary detail ends with, for example,
`GitHub CLI key renewed`.

Disclosure follows the authorization model. The `update-system` plan shows
the renewal in the APT scope column, which its single authorization covers.
Standalone `update-apt` prints `Key renewal:` and one `Renew key:` and
`Key URL:` line per expired keyring before its confirmation. `--dry-run` may
read local sources and keyrings only: it names the keys a run would renew,
adds `1 signing key to renew` to its result, and downloads and installs
nothing. Missing or replaced keys are known only after APT reports them, so a
dry run cannot list those. `SYS_APT_KEY_RENEWAL=0` in `config.zsh` disables
renewal and keeps the diagnosis; the default is `1`, and any other value
fails closed with status `2` before APT runs.

When ZDX cannot fix a key problem — an unknown repository, an inline key,
global trust, an unsafe keyring, renewal disabled, or a failed download or
verification — the diagnosis says plainly that the problem is the
repository's signing key, not ZDX; names the repository, its source file,
and the key ID APT wants; gives the cause, including the list of repositories
that ZDX renews automatically; and offers the two ways forward: install the
publisher's current key into the named keyring with
`sudo install -m 0644 -o 0 -g 0 <downloaded-key> <keyring>`, using the
publisher's documentation, or disable the source, for example with
`sudo mv <file> <file>.disabled`. `APT index update failed.` and
`After fixing the cause, run: sys-menu update-apt` remain.

## Cleanup and user state

Cleanup and telemetry follow the destructive-operation and persisted-state
contracts in [`development.md`](development.md).

### Cleanup

`clean-system` calculates and displays its applicable steps before
execution. It accepts `--quick` or `--deep`, `--dry-run`, and `--yes`; without
a mode, an interactive shell prompts for one. A non-interactive mutation
requires an explicit mode and `--yes`; a dry run requires the mode but not
confirmation. Focused `clean-journal` and `clean-snaps` expose the same
dry-run and confirmation model for their exact targets.

Generic cleanup is deliberately bounded to detected package and language
caches, journal records older than three days when systemd is available,
`~/.cache/thumbnails`, and `~/.cache/tmp`. It never sweeps shared `/tmp` and
never prunes Docker resources. Execution accepts only the unique typed records
in the confirmed plan, passes each recorded scope to its owning helper, and
revalidates dynamic cache paths before mutation. Each failed step is reported
and makes the aggregate return non-zero; that includes a cache entry that `rm`
could not remove. A cache whose directory probe fails or times out, such as
`pip cache dir` with the cache disabled or a tool that is only a lazy shell
function, is omitted from the plan with a warning; nothing is removed for it.
The pip cache belongs to the first usable `pip`, then `pip3`, which is all
that Homebrew Python provides, then `python3 -m pip` when that module answers a
bounded `--version` probe; the purge uses the same command. A `python3` without
pip is no pip cache and no warning. The mode prompt and confirmation name only
targets that exist on the platform: old journal logs only with systemd,
thumbnails only on Linux, and Homebrew cleanup only with Homebrew.

The plan is a numbered `# · Step · Target` table with home paths shown as `~`.
Execution follows the aggregate structure in [`output-spec.md`](output-spec.md):
a banner and one result line per step, a `Cleanup Summary` table, and a
verdict that counts failed steps. A step reports `current` when it found
nothing to clean, `done` with what it freed when it can measure that, and
`skipped` when its tool is not installed when the step runs. An interrupted step (status
`130` or `143`) stops the cleanup, lists the remaining steps as not run, and
preserves that status.

Disabled Snap revisions are treated as dynamic privileged targets. The helper
authenticates once with `sudo -v`, re-queries each recorded snap and revision,
confirms it is still disabled, and runs only the final `snap remove` through
`sudo -n`. A revision is disabled only when the `Notes` column says so. A
changed or missing revision fails closed and is reported as a partial failure.
Snap's own progress output goes to stderr.

### Telemetry state

The opt-in core writer accepts only the five documented fields: suite,
canonical command, duration, exit status, and timestamp. It rejects unsafe
identifiers, malformed or unbounded durations, symbolic links, non-owned files,
and oversized existing logs. It never appends a new record to an unterminated
partial final line; only preceding complete records can be retained.
The containing directory and file use owner-only modes, writes use a lock and
same-directory temporary file, and replacement is atomic. Retention defaults
to the newest 1,000 records and the existing-log read limit defaults to 5 MiB.

`sys-telemetry --clear [--dry-run] [--yes]` shows the exact file and size,
fails closed non-interactively, locks the telemetry directory, revalidates the
file's device and inode, and atomically replaces it with an owner-only empty
file. Dashboard and browse remain read-only.

## Interface

The public interface follows these rules:

- `sys-menu <command> [arguments...]` forwards arguments without flattening or
  dropping them;
- core lazy stubs use an explicit map below one source-derived module root and
  never require `eval`;
- help and all human UI use stderr;
- unknown `sys-menu` options and command tokens return `2`; System-owned public
  parsers use the same invalid-argument status;
- menu rows are validated `label|command|description` records;
- `fzf` behavior and the optional core theme are built locally at invocation;
- every System picker, including the top-level menu, confirmations, the
  telemetry browser, and the process, listener, and service browsers, runs
  `fzf` synchronously in the terminal foreground through the suite-owned
  private capture helper; the bounded, identity-checked result file is
  removed on every path, a failed picker cannot carry selection data, and a
  nested selection must belong to the invocation's row snapshot before its
  fields are used;
- `NO_COLOR` disables System and shared fzf/timer color output;
- the top-level header is plain text and reports current OS, environment,
  package, and service capabilities;
- read-only diagnostics appear first, host control is separated from updates,
  and destructive maintenance appears last;
- unavailable optional capabilities annotate only the affected entry;
- completion exposes command-specific flags and typed resource targets through
  both `sys-menu <command>` and every direct public command.

Interactive cancellation returns `0` without dispatching an action. Menu
dependency annotations are advisory; direct commands repeat authoritative
capability and target checks.

The Node update entry requires an external `fnm`, or both an existing NVM
directory and a callable `nvm` already loaded in the shell. An unloaded NVM
installation is annotated as `missing: loaded nvm`; discovery never sources
`nvm.sh` or executes either version manager.

## Platform support

| Platform | System behavior | Verification boundary |
| --- | --- | --- |
| Linux | Native collectors plus independent package, systemd, procps/BSD `ps`, `lsof`/`ss`, privilege, and Snap capabilities | Primary automated environment; a capability can still be unavailable on an individual host |
| WSL | Linux base with an overlay for systemd, Snap, Windows interop (`WSLInterop` or `WSLInterop-late`), WSL metadata, the `sys-wsl` configuration review, and the exclusion of Windows programs on the appended Windows `PATH` | Mocked overlay decisions and Linux behavior; host facilities remain independently gated; WSL1 has no recorded run |
| macOS | Darwin diagnostics, BSD `ps`, launchd user-domain services, primary Homebrew package detection, and independent `softwareupdate` | Decision and parser behavior is mocked; no real macOS host run is recorded |

The Quality Gates workflow runs the BATS suite on Ubuntu, and the macOS
workflow runs it on an Apple Silicon runner with the BSD userland. Mocked
capability tests protect branch selection on both, but the System commands'
host behavior on macOS is not considered host-verified until a documented
repeatable manual run exists.

### Platform command matrix

Each command decides its platform behavior from the capability registry at
run time. "Mocks" means that the behavior is covered only by deterministic
BATS mocks of the named tools; "Linux host" means that the Linux runner also
exercises the real code path against real tools.

| Command | Linux | WSL | macOS | Verification |
| --- | --- | --- | --- | --- |
| `sys-info` | `/proc`, `/etc/os-release`, `/` | Linux data plus WSL generation and Windows version; Windows programs skipped | `sw_vers`, `sysctl`, `kern.memorystatus_level`, Data volume; CLT placeholders skipped | Linux collectors on the host; rendering, WSL, and macOS by mocks |
| `sys-health` | systemd failed units, `dmesg` OOM count, reboot marker | As Linux; systemd only when enabled | launchd failed jobs, signal exits advisory, Data volume, OOM not applicable | Rendering and every platform's findings by mocks |
| `sys-wsl` | Not applicable | `/etc/wsl.conf`, `/proc/net/route`, `/sys/class/net`, PID 1, and `.wslconfig` through bounded `wslvar` or `cmd.exe` and `wslpath` | Not applicable | Fixture trees and mocked interop on every platform; one manual run on WSL2 |
| `sys-startup`, `sys-telemetry` | Portable Zsh | Portable Zsh | Portable Zsh | Linux host and the macOS runner |
| `sys-processes` | procps, sorted by CPU | procps | BSD `ps -axro`, sorted by CPU | Linux host; BSD `ps` by mocks |
| `sys-ports` | `ss`, else `lsof` | `ss`, else `lsof` | `lsof` | Linux host; `lsof` by mocks |
| `sys-services` | systemd with least-privilege `sudo` | systemd when enabled | launchd in the job's `gui/<uid>` or `user/<uid>` domain; `--stop` is `launchctl kill SIGTERM` | systemd and launchd by mocks |
| `update-system` | APT or a native backend, Snap, Linuxbrew, and tool steps | As Linux; Windows tool programs excluded | `softwareupdate` without restart updates, Homebrew with the failing askpass guard, and tool steps | Plans and dispatch by mocks on every platform |
| `update-apt` | APT | APT | Not applicable | Mocks |
| `update-snap` | Snap with a running snapd | Snap with a running snapd | Not applicable | Mocks |
| `update-brew` | Linuxbrew | Linuxbrew | Homebrew, failing askpass guard | Mocks |
| Tool updaters (`update-gcloud`, `update-awscli`, `update-node`, `update-rust`, `update-uv-system`, `update-pipx`, `update-starship`) | Active executable | Active executable that is not a Windows program | Active executable; Homebrew ownership by path | Mocks |
| `update-fzf`, `update-omz`, `update-zsh-plugins` | Owned Git checkouts | Owned Git checkouts | Owned Git checkouts | Linux host with real Git |
| `clean-system` | Package, language, journal, thumbnail, and temporary caches | As Linux; journal only with systemd | Language, Homebrew, and temporary caches; no journal or thumbnails | Linux host with mocked tools; macOS by mocks |
| `clean-journal` | systemd journal | systemd journal when enabled | Not applicable | Mocks |
| `clean-snaps` | Snap with a running snapd | Snap with a running snapd | Not applicable | Mocks |

Not verified on a real host: a Mac (launchd, `softwareupdate`, Homebrew
casks, `/usr/bin/false` metadata, BSD `ps` and `lsof` output, the Data volume),
a real sudo timestamp renewal by the refresher, and WSL1.

### Not-applicable contract

A platform-specific command whose capability is absent on the host
(`update-apt` without APT, `update-snap` and `clean-snaps` without Snap or a
running snapd, `clean-journal` without an active systemd journal, and
`sys-wsl` outside WSL) follows
one contract after its arguments are parsed, so `--help` still returns `0` and
an unknown option still returns `2`:

- run directly, it prints
  `✘ <command> is not applicable on this host: <reason>.` without a heading
  and returns `1`, because its runtime precondition is unmet;
- inside an aggregate step it reports `skipped: not applicable (<reason>)`
  and returns `0`, so a plan that changed under it does not count a failure.

The aggregate plans omit these steps on hosts where they do not apply. The
same contract covers the APT cache and journal steps of `clean-system`.

## Module boundaries

The capability layer and adapters retain the following feature ownership:

```text
functions/
├── sys-menu.zsh
├── sys-common.zsh
└── sys/
    ├── sys-capabilities.zsh
    ├── sys-update-apt-keys.zsh  APT signing-key registry, renewal, and guidance
    ├── sys-update-apt.zsh       dpkg audits, unattended-upgrade yield, update-apt
    ├── sys-update-packages.zsh  Homebrew, Snap, native backends, DNF5 guard
    ├── sys-update-git.zsh       owned Git checkouts: fzf, Oh My Zsh, Zsh plugins
    ├── sys-update-tools.zsh     SDK, runtime, and CLI updaters
    ├── sys-update.zsh           update-system plan, lock, and step runner
    ├── sys-clean.zsh
    ├── sys-diag.zsh
    ├── sys-wsl-config.zsh       read-only WSL configuration review
    ├── sys-shell-diag.zsh
    ├── sys-ports.zsh
    ├── sys-processes.zsh
    ├── sys-services.zsh
    ├── sys-telemetry.zsh
    └── adapters/
        ├── sys-linux.zsh
        ├── sys-wsl.zsh
        └── sys-macos.zsh
```

The update modules are split by backend and safety model. The step modules
load before the `sys-update.zsh` orchestrator and expose a fixed step protocol:

1. Step commands are the public `update-*` functions plus the private
   `_sys_update_platform_packages` entry. The aggregate invokes them only
   through `_sys_run_update_step`.
2. Each step module defines a `_sys_update_<step>_applies` predicate beside its
   command. The orchestrator reaches them only through the `_sys_step_applies`
   dispatcher, exactly once per plan entry.
3. APT planning uses `_sys_apt_plan_blocker`, with the authorized fingerprint
   handed over through dynamic scope.
4. Step modules never call the orchestrator or each other.
   `sys-update-apt-keys.zsh` is not a step module: it holds the APT key
   renewal helpers that only `sys-update-apt.zsh` calls.

Update primitives used by more than one of these files live in
`sys-common.zsh`: the shared argument grammars, the trusted-program and
askpass validators, and the privileged update session (sudo
pre-authentication and its owned keepalive). The owner-bound path validator
serves only the Git-owned checkouts, so it lives in `sys-update-git.zsh`.
The invariants are:

- capability detection is read-only and separately testable;
- feature orchestration does not embed platform command construction;
- adapters return data or execute one validated backend operation;
- menu, safety, and logging behavior remain outside platform adapters;
- adapter files do not define public commands.

## Test coverage

All network clients, privilege escalation, package mutations, shell
installers, Docker commands, and process signals are deny-by-default mocks.
These tests use only sandboxed state and deterministic mocks; real-host smoke
tests remain separate acceptance requirements.

[`test/sys_contract.bats`](../test/sys_contract.bats) verifies:

- fixture schema, count, uniqueness, module ownership, and risk metadata;
- definition of all 25 public functions in Zsh;
- exact menu, dispatcher, help, and completion parity, plus a direct
  completion binding for every command;
- contextual completion with typed `port:` targets and without `--kill-pid` or
  a `sys-processes --kill` form;
- interactive cancellation without dispatch, foreground private picker
  capture, and refusal of a row outside the menu snapshot;
- timing label and status preservation for direct routing;
- status `2` for an unknown dispatcher token;
- silent, idempotent re-sourcing.

[`test/sys_capabilities.bats`](../test/sys_capabilities.bats) verifies:

- silent standalone loading without core helpers;
- one source-derived module root and no fallback to an unrelated tree;
- timer fallback status preservation;
- loader cleanup and exact module failure status;
- lazy detection and explicit refresh behavior;
- native Linux, WSL overlay, and Darwin adapter selection;
- WSL interop through `WSLInterop` or `WSLInterop-late`, and the Windows
  version through `cmd.exe` on the system drive when the Windows `PATH` is
  absent, never through a symbolic link;
- predicate success, capability absence, and invalid-input statuses;
- registry-backed compatibility helpers;
- stable, data-only registry output.

[`test/sys_diagnostics.bats`](../test/sys_diagnostics.bats) verifies:

- fixed collector routing for native Linux, WSL, and macOS;
- Linux record schemas and mocked Darwin parsers;
- WSL information and launchd health rendering;
- launchd health that counts only jobs that are not running with a positive
  exit status, skips `com.apple.*` unless `SYS_HEALTH_INCLUDE_APPLE_JOBS=1`,
  and lists signal exits as advisory;
- the macOS Data volume for disk and inode checks, the not-applicable kernel
  OOM log, and available memory from `kern.memorystatus_level` with its
  `vm_stat` fallback;
- `sys-info` tool rows that skip Command Line Tools placeholders unless
  `xcode-select -p` succeeds and skip Windows programs on WSL, without running
  either;
- the unchanged `sys-info` text layout, the typed `zdx.sys-info.v1` document
  on WSL and native hosts, extra-argument refusal, and the missing-`jq`
  failure before any probe;
- healthy and issue-bearing health reports with counted nouns;
- strict UI/data stream separation;
- portable startup measurements, process-group timeout behavior where GNU
  timeout is available, cleanup, and complete failure;
- telemetry schema filtering, malformed records, symlinks, size limits, and
  raw-JSON exclusion from fzf;
- status `2` for invalid public options.

[`test/sys_wsl.bats`](../test/sys_wsl.bats) verifies `sys-wsl` against
fixture trees for `/etc`, `/proc`, and `/sys` and mocked `cmd.exe`, `wslvar`,
`wslpath`, and `uname`:

- help and status `2` for invalid or repeated flags;
- the not-applicable result on native Linux and macOS in text and JSON, without
  reading configuration;
- every finding on stderr with empty stdout, and a clean configuration without
  findings;
- the exact `zdx.sys-wsl.v1` document: typed settings, `null` for unset values,
  other keys, malformed lines, network facts, and finding identifiers;
- hostile `$(…)`, backtick, and `${…}` values shown as text and never executed;
- credential-bearing values withheld from text and JSON;
- INI line numbering and every malformed-line reason, CRLF and a byte-order
  mark, and files refused for size or NUL bytes;
- disabled interop without any Windows call, a slow `cmd.exe` bounded by the
  interop deadline, `wslvar` preferred over `cmd.exe`, and conversion below a
  relocated automount root without `wslpath`;
- the `vpn-mtu-probe` hint only when the shell defines the command;
- systemd enabled but not running, the missing-`jq` failure, the
  `(unavailable: WSL)` menu mark, and `--json` completion.

[`test/sys_resources.bats`](../test/sys_resources.bats) verifies:

- stderr-only help and status `2` for invalid resource options;
- typed procps, BSD `ps`, `lsof`, `ss`, systemd, and launchd records;
- protected PIDs, non-interactive fail-closed behavior, and the
  `SIGTERM`/`SIGKILL` distinction;
- process fingerprint changes before signaling;
- typed port targets, rejection of unprefixed and PID targets, multiple-owner
  rejection, and changed listener ownership;
- preservation of each PID-to-command association in multi-owner `ss` rows;
- process and systemd revalidation around `sudo -v`, non-interactive final
  `sudo -n`, launchd targeting in the job's `gui` or `user` domain,
  `launchctl kill SIGTERM` for `--stop`, and backend failure propagation;
- BSD `ps -axro` listings sorted by CPU;
- read-only `fzf --expect` adapters with accurate legends.

These are deterministic mocked backend tests. The macOS CI job runs them on a
real Mac, but the mocked backends do not verify launchd, `softwareupdate`, or
Homebrew behavior on that host.

[`test/sys_maintenance.bats`](../test/sys_maintenance.bats) verifies:

- side-effect-free aggregate and APT dry-run plans;
- applicability and exact sandboxed dispatch for dnf, pacman, zypper, apk, and
  macOS `softwareupdate`, including Darwin with Homebrew as the primary package
  backend; the macOS plan with its `softwareupdate`, Homebrew, and tool steps;
  `softwareupdate` list parsing in both layouts, a `current` result without
  privilege, restart and macOS updates left uninstalled as `skipped` with a
  warning that names them and points to System Settings, a failed installation
  as a failure,
  exact `--install --no-scan <label>` arguments for the remaining labels, and
  refusal of an unrecognized list or an unsafe label;
- default inclusion of every applicable updater and explicit `--safe-only`
  exclusion of fzf, Oh My Zsh, and Zsh plugin mutable-code updates;
- exact execution of the frozen authorized entry set, the prompt-free Git
  update transport environment with preserved caller SSH overrides, and
  bounded Homebrew metadata-refresh failure isolation;
- refusal of unverified AWS CLI and Starship installer pipelines;
- non-zero aggregate status with continued execution and explicit partial
  wording after mixed results;
- the single canonical-home lock path, persistent mode-`0600` file without
  unlink, owner-bound descriptor lifetime, zero-second
  `zsystem flock -t 0` overlap refusal, and later reuse;
- separate core-package and optional-tool summary totals, including explicit
  not-run counts after `--fail-fast`;
- one first-entry APT attempt immediately after pre-authentication, an adjacent
  cooperative yield for an exact automatic-updater fingerprint,
  post-authentication identity revalidation, zero polling or retry, immediate
  native-lock failure without a generic process-busy gate, exact
  zero-wait/no-retry APT options, compact default and complete `--verbose`
  operation announcements, explicit phased-update propagation to every
  APT call only, pre- and post-transaction dpkg audits, and reboot-required
  advisory reporting;
- one aggregate sudo authentication decision; the invocation-owned 30-second
  `sudo -n -v` refresher as a process substitution that shares the caller's
  session and controlling terminal in a real PTY without job-completion UI,
  its visible warning and stopped worker when the first refresh fails, no
  retry after a failed refresh, no refresh after its caller exited, and its
  acknowledged `always` cleanup; exact displayed privilege prefixes; and
  direct APT's single authentication followed by `sudo -n`;
- closed stdin for aggregate, captured, direct APT, Homebrew, native-backend,
  and DNF-wrapper commands; visible Snap preview failures; trusted APT `env -i`
  isolation from `APT_CONFIG`, proxies, and caller/post-sudo state; exact APT
  PTY, conffile, frontend, lock, and acquisition controls; trusted bounded
  `apt-config` reads and Debian package-version gates for the
  signal-authorizing version-specific `MinimalSteps` semantics, a mocked
  packaged-program trust boundary independent of host package installation,
  numeric epoch normalization, rejection of the command-line minimal-step
  opt-out including accepted abbreviations, and the process's caught-SIGTERM
  mask; DNF4 lock and
  minimum finite retry options; and the hermetic bounded
  DNF5 compatibility matrix (the 5.0/5.1 path deliberately independent of
  config dumping and without persistdir, 5.2/5.3 with frozen persistdir in
  sanitized mode `0`, and 5.4+ with required
  lock capability in zero-second guarded mode `1`), trusted outer and inner `env -i`
  execution with only the fixed environment, exact non-secret wrapper argv,
  and rejection of all caller/post-sudo proxy and exported-function state,
  plus APK's exact
  `--wait 0` mutations and the 120-second Homebrew metadata deadline with
  curl-level retries disabled;
- exact uv, pipx/pip, Cargo, and rustup retry environments; active-path
  ownership and Homebrew/self-managed coexistence for uv; active-path gcloud
  ownership for the `gcloud-cli` and `google-cloud-sdk` casks,
  `share/google-cloud-sdk`, the APT package, and an earlier self-managed SDK;
  tool steps on WSL that never select a Windows program; a world-writable
  tool executable reported as blocked; DNF's intentionally distinct DNF4 and
  DNF5 network-retry semantics; and pip's no-input policy;
- Homebrew analytics and environment-hint suppression, inherited
  auto-update/askpass rejection,
  false-lock rejection, and continued execution after a native Homebrew
  failure, with its internal download-queue
  retry and lock-wait behavior retained as an external residual, plus absolute
  executable dispatch with local exports rather than an interceptable `env`
  command, plus Darwin-only pre-authentication guidance;
- the visible Zypper warning for its non-configurable soft-media retries and
  30-second sleeps, without a mutation watchdog or universal no-retry claim;
- Pacman's mirror/download retries and Cargo's package-cache lock wait retained
  as explicit upstream residuals without a supported zero switch;
- macOS Homebrew adjacency within the privileged refresher scope and the fixed
  false askpass guard for Homebrew's internal `sudo -A`, its private failing
  fallback below the validated temporary root, removed after the run, and the
  refused run without either, plus mandatory `brew upgrade --no-ask`
  execution;
- the shared not-applicable contract of `update-apt`, `update-snap`,
  `clean-journal`, and `clean-snaps`, run directly and inside a step;
- cleanup plans that preserve shared temporary and Docker resources, the
  `pip3` and `python3 -m pip` cache probes, and platform-specific mode
  wording;
- exact cleanup dispatch from confirmed records, cache-path revalidation, and
  partial-failure propagation without abandoning later steps.

[`test/sys_apt_recovery.bats`](../test/sys_apt_recovery.bats) additionally
verifies failed or timed-out advisory simulations, dry-run failure without
mutation, preserved authorization and dpkg guards, strict index-refresh
failure, and continuation of independent aggregate entries.
[`test/sys_apt_keys.bats`](../test/sys_apt_keys.bats) verifies signing-key
renewal with mocked APT, curl, gpg, sudo, and install and a sandboxed APT
layout: reactive renewal of a `NO_PUBKEY` repository verified by one retry,
proactive renewal of an expired keyring, refusal of a download without the
requested key ID and of a failed download, rollback when APT still rejects
the repository, plain guidance without a download for an unknown repository,
an inline deb822 key, and global trust, refusal of a symlinked or
group-writable keyring, `SYS_APT_KEY_RENEWAL=0` and an invalid value, a dry
run that downloads and installs nothing, the plan disclosure and step summary
detail in `update-system`, the exact `install` argv and curl options, the
registry's exact host and path matching, and sqv's `Missing key` report.
[`test/sys_update_interface.bats`](../test/sys_update_interface.bats) covers
Node readiness annotations for an external fnm, loaded or unloaded NVM, absent
NVM directories, and shell functions that cannot substitute for fnm.
[`test/sys_toolchain_recovery.bats`](../test/sys_toolchain_recovery.bats)
verifies Node installation/default/activation failures and current-version
postconditions, plus exact direct Homebrew uv upgrades, relocated Cellar
targets, version-probe failures, and preserved aggregate deduplication.

[`test/sys_state.bats`](../test/sys_state.bats) verifies telemetry
owner-only permissions, duration, record, final-byte, and partial final-line
bounds, symlink component and oversized log refusal, and fail-closed clear
behavior. Cleanup plans and their exact dispatch are covered by
`sys_maintenance.bats`, including the `clean-system` mode grammar.

[`test/sys_interface.bats`](../test/sys_interface.bats) verifies:

- stderr-only help without eager host probes;
- status `2` for unknown options and command tokens;
- exact argument forwarding and one timing wrapper;
- validated three-field menu records;
- local, plain, capability-aware `fzf` behavior;
- foreground private capture for every nested picker, with status `0` on
  cancellation, no stdout data, and no leftover result files;
- `NO_COLOR` behavior and source-derived module resolution;
- deterministic dispatch of one real action;
- silent, idempotent, probe-free standalone sourcing;
- lazy and eager exposure of the same 25-command surface.

[`test/sys_update_interruptions.bats`](../test/sys_update_interruptions.bats)
verifies that an interrupted Node.js step stops later System updates and
preserves its status with or without `--fail-fast`. The core lazy-loading
tests in [`test/lazy_loading.bats`](../test/lazy_loading.bats) cover stub
registration and replacement. `sys.bats`,
`sys_ports.bats`, `sys_doctor.bats`, and `telemetry.bats` are behavior
regression suites; [`testing.md`](testing.md) lists what each covers.
