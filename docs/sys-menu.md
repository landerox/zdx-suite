# System suite refactor contract

This document records the public contract for `sys-menu` and the staged Linux,
WSL, and macOS refactor that established it. The repository-wide contracts in
[`development.md`](development.md) and [`menu-spec.md`](menu-spec.md) remain
authoritative.

Baseline date: 2026-07-11.
Implementation review: 2026-07-25.
Maintenance review: 2026-09-05.

| Phase | Implementation status | Focused verification |
| --- | --- | --- |
| 0 — contract baseline | Complete | `sys_contract.bats` |
| 1 — loader and capabilities | Complete | `sys_capabilities.bats` |
| 2 — read-only diagnostics | Complete | `sys_diagnostics.bats` |
| 3 — resources | Complete in the current worktree | `sys_resources.bats` |
| 4 — updates | Complete in the current worktree | `sys_maintenance.bats` |
| 5 — cleanup and user state | Complete in the current worktree | `sys_maintenance.bats`; `sys_state.bats` |
| 6 — interface closure | Complete in the current worktree | `sys_interface.bats`; real-host verification remains pending |

Final acceptance of the combined worktree still requires the repository-wide
gate. Darwin routing is covered with mocks, but no real macOS host verification
is recorded.

## Menu presentation

The command menu uses an 80% height, label-only rows, and four lines of details
below the list. Sections show only their description. Host context appears
above `Type to filter | Enter run | Esc cancel | Ctrl-/ details`.
The telemetry action menu uses the same details toggle and retains its compact
50% height. Resource browsers keep their own fields and action keys; the
details binding is not inherited by process, port, or service browsers.

## Phase 0 purpose

Phase 0 protects intentional public behavior before production modules move.
It does not claim that the current implementation is portable or conforming.

The phase establishes:

- one machine-readable inventory of public commands;
- parity tests for functions, menu rows, dispatcher arms, help, and completion;
- baseline routing, cancellation, timing, and idempotency behavior;
- an explicit risk and current-capability classification;
- a list of legacy behavior that is not a compatibility promise.

Capability modularization began in phase 1. Later phases retained the frozen
surface while replacing the unsafe or platform-coupled implementation behind
it.

## Phase 1 result

Phase 1 establishes a portable decision layer without claiming that every
legacy workflow is portable yet. It delivers:

- standalone `sys-menu.zsh` sourcing without requiring `functions.zsh`;
- explicit, readable module loading with exact failure status preservation;
- owner-specific sentinels set only after each mandatory file completes;
- a single module root derived from the loader's own source path;
- a lazy capability registry with no host probes at source time;
- native Linux, WSL overlay, and macOS read-only adapters;
- compatibility predicates for the legacy systemd and Snap consumers;
- optional wrappers for the core timer and fzf theme;
- deterministic mocked tests for Linux, WSL, and Darwin decisions.

The public surface remains the same 34 commands frozen in phase 0. Later phases
migrate diagnostics and resource control behind these capabilities while
keeping update and state behavior explicitly capability-gated.

### Load order and failure contract

`sys-menu.zsh` derives one trusted installation root from its own source path.
It resolves common and feature files only below that root, then loads them in
this order:

1. `sys-common.zsh`;
2. `sys-capabilities.zsh`;
3. Linux, WSL, and macOS adapters;
4. the existing feature modules in explicit dependency order.

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
| `fonts_backend` | `fontconfig`, `macos-user-fonts`, `unavailable` |
| `snapd` | `available`, `unavailable` |
| `wsl_interop` | `available`, `unavailable` |

`_sys_capability_value <key>` and `_sys_capabilities_print` emit data only on
stdout. `_sys_has_capability <namespace:value>` is the control-flow API and
supports the `os`, `environment`, `package`, `os-updates`, `service`,
`process`, `ports`, `privilege`, `fonts`, and `runtime` namespaces. It returns:

- `0` when a recognized predicate is satisfied;
- `1` when it is recognized but unavailable;
- `2` when its namespace or value is unsupported.

Feature code must use these accessors rather than reading
`_SYS_CAPABILITIES` directly. Tests may inject the map to isolate predicate
behavior.

### Adapter boundary

Adapters are private and read-only. Phase 1 introduced capability probes;
phase 2 adds typed diagnostic collectors. They do not render UI, dispatch
public commands, request privilege, or perform maintenance. WSL is a Linux
overlay, not a third base OS: it reuses Linux collectors, then independently
detects systemd, Snap, and Windows interop. macOS support uses Darwin-native
backend names and does not emulate GNU or systemd behavior.

## Phase 2 result

Phase 2 migrates host and shell diagnostics onto the capability layer. It
delivers:

- Linux, WSL, and macOS collectors for OS, memory, swap, CPU, uptime, load,
  packages, zombie processes, and service health;
- fixed capability routing between collectors and public commands;
- separate host and shell diagnostic modules with explicit loader ownership;
- platform-neutral disk and inode checks;
- portable Zsh startup timing that does not parse shell-specific `time` text;
- an isolated `zprof` subprocess that leaves no temporary profile file;
- strictly read-only PATH inspection;
- a names-only, non-interactive alias/function inventory;
- bounded, schema-validated telemetry inspection;
- stderr-only human UI with control characters escaped before display.

The public command inventory remains unchanged. At the phase 2 boundary,
process termination, port handling, service mutation, telemetry clearing, and
telemetry writing were deliberately deferred; phases 3 and 5 now own those
controls.

### Diagnostic command contracts

| Command | Accepted interface | stdout | Notes |
| --- | --- | --- | --- |
| `sys-info` | No arguments; `-h`, `--help` | Empty | Renders available host, tool, and package data on stderr |
| `sys-health` | No arguments; `-h`, `--help` | Empty | Runs every available read-only check; unsupported checks are reported as unavailable |
| `sys-startup` | No arguments; `-h`, `--help` | Empty | Runs ten bounded samples, then an isolated `zprof` pass; startup files may retain external side effects |
| `sys-path` | No arguments; `-h`, `--help` | Empty | Reports duplicates, missing directories, and empty entries without editing `.zshrc` |
| `sys-aliases` | `[all\|aliases\|functions]`, `--list [mode]`, help | TSV only with `--list` | TSV schema is `kind<TAB>name`; interactive inspection requires fzf |
| `sys-telemetry` | `--dashboard`, `--browse`, `--clear [--dry-run] [--yes]`, help, or menu | Empty | Dashboard and browse are read-only; clear uses the phase 5 state controls |

Unknown options return `2`. `sys-health` returns `0` when the diagnostic run
completes even if it reports findings; findings are not operational failures.
It returns `1` only when the command cannot establish its required runtime
state. A future machine-readable health mode may define a finding-specific
status without changing this UI contract.

### Platform collection matrix

| Data | Linux and WSL | macOS |
| --- | --- | --- |
| OS identity | `/etc/os-release`, optional `lsb_release` | `sw_vers` |
| Memory and swap | `/proc/meminfo` | `sysctl`, `vm_stat` |
| CPU | `getconf`/`nproc`, `/proc/cpuinfo` | `sysctl` |
| Uptime and load | `/proc/uptime`, `/proc/loadavg` | `kern.boottime`, `vm.loadavg` |
| Packages | APT, RPM, Pacman, APK, Brew, optional Snap | Brew or Installer package receipts |
| Zombie processes | procps fields | BSD `ps` fields |
| Service health | systemd when active | launchd last-exit state |
| WSL metadata | WSL generation and Windows version when interop works | Not applicable |

Missing optional data does not trigger a similarly named command from another
platform. It produces an unavailable result and the remaining checks continue.
Darwin decision and parser behavior is protected with mocks; macOS support is
not considered host-verified until macOS CI or a documented manual run exists.

### Data and UI boundary

Adapter collectors emit one scalar or a documented TSV record. `sys-diag.zsh`
and `sys-shell-diag.zsh` format these values for people. Public diagnostic UI,
help, headings, blank layout lines, and findings go to stderr.

`sys-aliases --list` is the intentional data exception. It emits validated
symbol names only, excludes private `_` functions, and never emits definitions.
Interactive inspection has no shell preview; a sensitive-looking symbol name
hides its definition.

External values pass through a Zsh visible-character renderer before terminal
display. This prevents control characters in paths, command output, service
descriptions, or persisted records from becoming terminal instructions.
System UI enables ANSI color only on a stderr terminal when `TERM` is not
`dumb` and `NO_COLOR` is unset. The core timer and shared fzf theme honor the
same `NO_COLOR` opt-out.

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
that has begun a package, cache, service, process, font-cache, or other
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

These reader controls are complemented by the phase 5 owner-only writer,
bounded retention, atomic replacement, and hardened clear operation.

## Phase 3 result

Phase 3 replaces formatted-row mutation with typed discovery records and exact
resource targets. It delivers:

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
| `sys-processes` | `--list` emits `process<TAB>pid<TAB>uid<TAB>cpu<TAB>memory<TAB>command` | `--terminate PID [--force] [--yes]`; `--kill` is a compatibility spelling |
| `sys-ports` | `--list` emits `port<TAB>protocol<TAB>port<TAB>address<TAB>pid<TAB>command` | `--kill-pid PID`, `--kill-port PORT [--protocol tcp\|udp]`, or `--kill pid:PID\|port:PORT`, followed by optional `--force` and `--yes` |
| `sys-services` | `--list` emits `service<TAB>backend<TAB>id<TAB>state<TAB>detail<TAB>description`; `--show ID` renders details | `--start`, `--stop`, `--restart`, `--enable`, or `--disable ID [--yes]` |

Human UI and help for the resource commands above use stderr. Only their
documented `--list` modes emit stdout data. The `update-hermes` compatibility
bridge separately preserves the AI owner's documented `--result-tsv` stdout
contract. A bare numeric `sys-ports --kill` target is rejected because it could be
either a PID or a port.

### Resource identity and privilege controls

Process mutations capture a fingerprint containing the PID, UID, start value,
and command name. The complete fingerprint is compared again after
confirmation and immediately before signaling. PID 1, the current shell, and
its parent are protected. A process owned by another UID uses only
`sudo kill -s <SIGNAL> <PID>` after the final check. ZDX first revalidates the
fingerprint, runs `sudo -v` to authenticate, revalidates again in case the
prompt consumed time, and executes the final signal with `sudo -n`.

A port mutation must resolve to exactly one visible PID. The protocol, address,
port, and PID record is rescanned, and the process fingerprint is revalidated
before the signal is sent. Hidden owners, multiple owners, and changed
listeners fail closed.

Systemd identifiers and launchd labels have separate validators. A service
action captures its backend state, confirms the exact operation, and compares
that state again before execution. Systemd crosses `sudo` only for the final
`systemctl` action. Its privileged path uses the same
revalidate/`sudo -v`/revalidate/`sudo -n` sequence. Launchd targets the current
`gui/<uid>` or `user/<uid>` domain without pretending to provide system-wide
launchd control.

Interactive resource browsers use `fzf --expect` only to return an action to
Zsh. They never place `kill`, `sudo`, `systemctl`, or `launchctl` inside an
`fzf` preview or binding. They run through the same foreground private capture
helper as the top-level menu rather than inside command substitution.

## Phase 4 result

Phase 4 hardens the update orchestrator and removes automatic use of
unverifiable upstream installers. It delivers:

- a capability-filtered `update-system` step plan with advisory package
  snapshots;
- `--dry-run`, `--yes`, `--fail-fast`, `--verbose`, and the explicit
  `--include-phased-updates` APT policy on the aggregate;
- maximum-scope default execution of every applicable installed updater,
  including Git-owned fzf, Oh My Zsh, custom Zsh plugin, and the AI suite's
  installed-assistant update plan;
- an explicit `--safe-only` mode that excludes those mutable-code origins,
  while `--include-remote-code` remains an explicit affirmation of the default;
- direct plan, dry-run, and confirmation controls for APT, Snap, Git-owned
  fzf, Oh My Zsh, and custom Zsh plugin updates, plus public delegation to the
  AI suite's equivalent controls;
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
  npm, uv, pipx/pip, Cargo, and rustup update clients, plus non-interactive pip
  input, without claiming control over Cargo's package-cache lock;
- visible Snap preview errors and deadlines, an announcement whenever a step
  runs with privately captured output, closed stdin for every aggregate step
  and privately captured command, plus closed stdin on direct APT, Homebrew,
  native-package, and DNF-wrapper execution, and per-step elapsed reporting in
  the aggregate summary;
- reuse of a valid non-interactive sudo timestamp or one announced `sudo -v`
  after aggregate authorization, followed during the consecutive privileged
  entries by an invocation-owned `sudo -n -v` timestamp refresher every 30
  seconds and `sudo -n` for every ZDX-constructed package or signal operation
  that requires sudo;
- exact UI rendering of the resolved privilege prefix, including `sudo -n`
  when escalation is required and no prefix for direct-root execution;
- separate core-package and optional-tool outcome summaries, plus visible
  nested AI failure details, explicit `completed with partial failures`
  wording, and non-zero aggregate status.

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

An entry returning `130` or `143`, including the delegated AI update step,
stops all subsequent System updates regardless of `--fail-fast`. The summary
reports the interruption and remaining not-run counts, and preserves that
status instead of treating it as an ordinary partial failure.

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
status `1`; an all-failed plan remains an ordinary failure. A validated nested
AI result is attributed directly, for example
`AI assistants — Cursor Agent: authentication required`, instead of losing the
sub-updater cause behind the aggregate label.

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
identity revalidation fail closed if the real process no longer reports a
SIGTERM handler.

The `MinimalSteps` decision itself is queried and revalidated through resolved
absolute `env` and `apt-config` programs whose files and directory chains are
root-owned and not group- or world-writable. Each query is time- and
output-bounded and runs under fixed `env -i` with nonexistent HOME/XDG roots,
`LC_ALL=C`, the system `PATH`, and `TERM=dumb`. Caller `APT_CONFIG`, `PATH`,
proxy, and exported-function state therefore cannot authorize a signal.

Signal eligibility also has an explicit historical package-version gate. A
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
deferred retry, or second APT entry. Before simulation or mutation, `update-apt`
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
with closed stdin every 30 seconds, so it cannot open another credential
prompt. The aggregate owns the worker through a private `zpty` handle. Cleanup
sends a fixed stop request, requires the worker's bounded acknowledgement and
exit, and then deletes that exact handle after the last privileged entry; an
`always` block performs the same lifecycle on an early failure, return, or
interruption. Every privileged command constructed by ZDX uses
`sudo -n`, and its UI line displays that exact resolved prefix. Homebrew is the
external exception described below. A direct `update-apt` invocation
authenticates once; its timestamp refresher uses only `sudo -n -v`, every later
signal or APT operation that requires elevation uses `sudo -n`, and the worker
is owned only for that APT sequence with the same `always` cleanup. The private
worker never enters the caller's interactive job table, so it cannot emit
`[n] ... terminated` or `done` notifications. A failed refresh is not retried;
the worker remains controllable until owned cleanup.

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
`npm_config_fetch_retries=0` for npm global installs, `UV_HTTP_RETRIES=0` for
uv, `PIP_RETRIES=0` with `PIP_NO_INPUT=1` for pipx/pip,
`CARGO_NET_RETRY=0` for Cargo, and `RUSTUP_MAX_RETRIES=0` for rustup. These
settings remove the supported client-level retries; they do not place an
already-started mutation inside a timeout or claim control over an underlying
tool's undocumented behavior. In particular, `CARGO_NET_RETRY=0` does not stop
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
`HOMEBREW_NO_ANALYTICS=1`; every `update-brew` phase also sets
`HOMEBREW_CURL_RETRIES=0`, and the metadata refresh has a 120-second deadline.
Every Homebrew phase also receives `/dev/null` as stdin. That variable disables
only curl-level retries. Homebrew 6 retains
internal `DownloadQueue` retry behavior and download-lock waiting, with no
public option to disable either. The 120-second outer deadline bounds
`brew update`, but the mutating Homebrew phases retain those external
transaction semantics. ZDX does not claim a global no-retry or no-wait
guarantee for Homebrew and does not kill an active Homebrew mutation. Every
Homebrew phase on macOS also receives `SUDO_ASKPASS=/usr/bin/false` after that
fixed program passes the root-owner and mode validator. Homebrew can invoke its
own `sudo -A` for casks rather than ZDX's `sudo -n`; the false askpass program
makes an unavailable cached credential fail without a prompt. Linuxbrew does
not use this Darwin-only guard. The related pre-authentication guidance is
rendered only when a Darwin plan actually includes Homebrew; Linux never shows
the macOS askpass warning. On macOS the Homebrew entry is adjacent to the
other privileged package entries and remains within their bounded sudo
timestamp scope. The authorized mutation always uses
`brew upgrade --no-ask`: current Homebrew defaults to ask mode and can otherwise
skip an upgrade without a TTY while returning success. A real Homebrew failure
is reported for that step while later independent updates continue.

The aggregate assigns each installation to one updater. Homebrew-owned AWS
CLI, Starship, fzf, uv, Google Cloud SDK, Repomix, and supported AI assistant
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
path also requires that post-update probe. Aggregate deduplication remains
unchanged. System always passes
`--skip-homebrew-managed --result-tsv` to the public `ai-menu ai-update` owner.
It captures only that protocol's stdout while leaving AI-owned stderr progress
visible. On macOS, the native `softwareupdate` step
remains independently applicable when Homebrew is the primary package backend,
so operating-system and formula updates can both run. Homebrew is ordered next
to that privileged native step so cask installers remain inside the bounded
sudo refresher window.

Git-owned fzf, Oh My Zsh, and custom plugin updates require owned,
symlink-free checkouts below `HOME`. Their plans show the origin and current
commit, repository identity and origin are revalidated after authorization,
and mutation uses `git pull --ff-only`. The fzf integration installer must be
an owned, singly linked executable whose content matches the checked-out Git
blob. Oh My Zsh does not execute the mutable `tools/upgrade.sh` helper.

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

`update-repomix` updates only an installed external executable whose package
owner can be tied to that active canonical path. Homebrew attribution requires
the active formula path; a separate formula does not hide an earlier npm
installation. For npm, a bounded passive `package.json` read must link its
declared Repomix binary to that active executable under the exact global
prefix. An absent command or shell wrapper never triggers installation; a
custom executable that cannot be matched fails before its version command or
an unrelated npm installation is changed. The npm program and prefix are
revalidated before an upgrade with explicit `--prefix`, and Node 20+, version
probes, and post-update ownership must validate before success is reported.

`update-node` resolves an external fnm to one absolute path, or uses an
already-loaded nvm installation. Installation, default selection, and activation
are checked separately. A failed default or activation phase preserves the
installed runtime, reports the remaining action, and returns `1`; independent
default and activation phases still run. A success message requires fnm's
bounded current-version probe to report `vX.Y.Z`, or nvm's current version to
match the validated installed LTS version. NVM activation runs in the calling
shell so its session and `PATH` changes persist; discovery never loads shell
code implicitly.

The aggregate AI step is part of the maximum plan by default and is omitted by
`--safe-only`. System delegates only through
`ai-menu ai-update --skip-homebrew-managed --result-tsv`, forwards aggregate
`--dry-run` and `--yes`, and preserves the AI owner's status. System requires
the versioned report to contain the canonical eight IDs and labels exactly once
and in order, with bounded fields, known outcome/reason pairs, and consistent
statuses. Missing, duplicate, reordered, mislabeled, or malformed records fail
closed without being interpolated into UI. It never calls an `_ai_*` private
helper or reimplements assistant detection, executable validation, update
arguments, or human-output parsing. The AI owner compares each successful
self-updater's bounded pre/post version and executable fingerprint. A changed
version or changed validated executable counts as `updated`; `already current`
requires both to remain unchanged. Independent `failed` and `skipped` counts
complete its own summary, and every target receives a terminal ledger entry.

`update-hermes` remains only as a frozen compatibility command. It forwards
all arguments to the public `ai-menu ai-update-hermes` owner and preserves that
command's option, trust, backup, and status contract. Hermes is therefore not a
second aggregate step and cannot be updated twice by one `update-system` run.

System update and cleanup helpers that capture tool output keep only a
configurable byte-bounded tail in an owner-only temporary directory. On
failure, at most the final 80 lines are rendered with control characters made
visible; a line containing a common credential indicator is replaced by a
redaction notice. Captured commands receive `/dev/null` as stdin so an
unseen prompt cannot consume terminal input or block the aggregate. The
temporary capture is removed on every exit path.

The verified artifact path used by `sys-fonts` defaults to Nerd Fonts v3.4.0.
`--install` names a missing `curl`, `tar`, or SHA-256 tool before asking for
authorization, so a confirmed plan cannot fail on a known precondition.
It downloads the named allowlisted family archive and the release
`SHA-256.txt` and verifies the exact artifact digest. Tar listing checks are
only a preflight: after private extraction, a NUL-delimited filesystem
inventory validates the real names, boundaries, ownership, object types, link
counts, duplicate destination basenames, and configured path and inventory
limits before publication.

Every newly published family contains a ZDX management marker. A prior family
is removed automatically only when that marker and family identity validate.
An unmarked prior tree is moved to a reported sibling recovery directory
outside the active font directory and is never deleted automatically.
`sys-fonts --list` validates the user-font base and emits
`family<TAB>absolute-path` records for only owned regular font files that
remain below it; it does not follow symbolic-link directories.

## Phase 5 result

Phase 5 applies the destructive-operation and persisted-state contracts to
cleanup, dotfiles, fonts, and telemetry.

### Cleanup

`clean-system`, `clean-system-quick`, and `clean-system-deep` calculate and
display their applicable steps before execution. They accept `--dry-run` and
`--yes`; `clean-system` also accepts `--quick` or `--deep`. A non-interactive
mutation requires an explicit mode and `--yes`; a dry run requires the mode but
not confirmation. Focused `clean-journal` and `clean-snaps` expose the same
dry-run and confirmation model for their exact targets.

Generic cleanup is deliberately bounded to detected package and language
caches, journal records older than three days when systemd is available,
`~/.cache/thumbnails`, and `~/.cache/tmp`. It never sweeps shared `/tmp` and
never prunes Docker resources. Docker lifecycle remains owned by the Docker
suite. Execution accepts only the unique typed records in the confirmed plan,
passes each recorded scope to its owning helper, and revalidates dynamic cache
paths before mutation. Each failed step is reported and makes the aggregate
return non-zero.

Disabled Snap revisions are treated as dynamic privileged targets. The helper
authenticates once with `sudo -v`, re-queries each recorded snap and revision,
confirms it is still disabled, and runs only the final `snap remove` through
`sudo -n`. A changed or missing revision fails closed and is reported as a
partial failure.

### Dotfile backup and restore

Both dotfile commands name a missing `tar` or SHA-256 tool and stop before
planning, mirroring the advisory menu annotation. Backup validates source
trees through the canonical home path, so a home directory reached through a
symbolic link can be backed up; restore still refuses a link `HOME`
destination and must run with `HOME` set to the canonical directory. A
sidecar digest without a trailing newline is still read.
`SYS_DOTFILES_BACKUP_DIR` overrides the default `~/.dotfiles-backups`
location; it must be an absolute path below `HOME`, trailing slashes are
ignored, and a relative value is refused before any filesystem check.

`sys-backup-dots [--dry-run] [--yes]` accepts only existing, non-link paths
below `HOME`; a directory containing symbolic links is skipped. It creates an
owner-only archive, an exact tar manifest, and a SHA-256 sidecar below the
owner-only backup directory. Creation enforces configured limits on source
entries, logical bytes, compressed bytes, manifest bytes, and path length
before publishing the backup triple. Retention pruning targets only validated
backup triples and is separately confirmed unless `--yes` is present.

`sys-restore-dots [--archive FILE] [--dry-run] [--yes]` accepts only an
owner-owned archive below that backup directory. Before extraction it enforces
size and entry limits, verifies the sidecar digest and exact manifest, rejects
absolute paths, traversal, links, and special files, and checks that no
destination component is an existing symbolic link. Archive identity and
contents are checked again after confirmation.

Extraction occurs in a private staging directory. A NUL-delimited walk then
validates names and actual filesystem objects rather than trusting escaped tar
listings; it rejects control or delimiter characters, symbolic links, special
files, foreign ownership, multiply linked regular files, and any extracted
path missing from the verified manifest. Implicit parent directories are
derived from that manifest, so the actual extracted set must match exactly.
ZDX validates every destination before creating a mandatory pre-restore
archive. Because that safety backup can take time, it revalidates the staging
and destination trees again afterwards. Each regular file is copied to a
same-directory temporary, revalidated, and published with an atomic rename.
A destination link detected before publication is rejected; one introduced
after the final check is replaced as a directory entry rather than followed or
truncated.

Backups can contain authentication configuration or credentials. The workflow
warns about that sensitivity and uses restrictive permissions, but users
remain responsible for protecting and eventually removing old backup media.

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

## Phase 6 result

Phase 6 closes the public interface without changing its 34-command inventory:

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
  symbol and telemetry browsers, the process, listener, and service browsers,
  and the Nerd Font and dotfile backup selectors, runs `fzf` synchronously in
  the terminal foreground through the suite-owned private capture helper; the
  bounded, identity-checked result file is removed on every path, a failed
  picker cannot carry selection data, and a nested selection must belong to
  the invocation's row snapshot before its fields are used;
- `NO_COLOR` disables System and shared fzf/timer color output;
- the top-level header is plain text and reports current OS, environment,
  package, and service capabilities;
- read-only diagnostics appear first, host control is separated from updates,
  and destructive maintenance appears last;
- unavailable optional capabilities annotate only the affected entry;
- completion exposes command-specific flags and typed resource targets through
  both `sys-menu <command>` and every direct public command;
- `sys-plugins` and `update-hermes` are compatibility bridges that forward all
  arguments to the core plugin and AI suite owners, respectively.

Interactive cancellation returns `0` without dispatching an action. Menu
dependency annotations are advisory; direct commands repeat authoritative
capability and target checks. Because `sys-plugins` and `update-hermes`
delegate rather than reimplementing their lifecycles, they preserve their
owners' option and status contracts.

The Node update entry requires an external `fnm`, or both an existing NVM
directory and a callable `nvm` already loaded in the shell. An unloaded NVM
installation is annotated as `missing: loaded nvm`; discovery never sources
`nvm.sh` or executes either version manager.

## Canonical command inventory

The phase 0 inventory is
[`test/fixtures/sys-public-commands.tsv`](../test/fixtures/sys-public-commands.tsv).
It contains 34 commands with four fields:

```text
command<TAB>owning-module<TAB>risk<TAB>current-capability
```

The inventory is non-executable test data. The BATS contract proves that every
command is present in all public surfaces and is defined by its declared
module.

### Functional groups

| Group | Commands |
| --- | --- |
| Aggregate maintenance | `update-system`, `clean-system`, `clean-system-quick`, `clean-system-deep` |
| Package and tool updates | `update-apt`, `update-brew`, `update-snap`, `update-gcloud`, `update-awscli`, `update-node`, `update-rust`, `update-uv-system`, `update-pipx`, `update-starship`, `update-fzf`, `update-omz`, `update-zsh-plugins`, `update-repomix` |
| Focused cleanup | `clean-journal`, `clean-snaps` |
| Diagnostics | `sys-info`, `sys-health`, `sys-startup`, `sys-path`, `sys-aliases` |
| User state | `sys-backup-dots`, `sys-restore-dots`, `sys-fonts`, `sys-telemetry` |
| Host resources | `sys-ports`, `sys-services`, `sys-processes` |
| Compatibility surface | `sys-plugins`, `update-hermes` |

`sys-plugins` and `update-hermes` remain in the phase 0 public inventory for
compatibility, but their lifecycle ownership belongs to `zdx-plugins` and
`ai-menu`, respectively. Each compatibility command loads its public owner
when needed and delegates all arguments to it.

## Public-surface invariant

These sets must remain identical throughout the refactor:

1. command records in the phase 0 fixture;
2. loaded public functions;
3. non-sentinel top-level menu records;
4. `_sys_dispatch` arms;
5. commands shown by `sys-menu --help`;
6. entries in `completions/_sys-menu`.

An intentional addition, rename, compatibility alias, or removal updates all
six surfaces and its contract tests in one change.

The phase 0 audit found `update-hermes` in every surface except the dispatcher.
The baseline corrects that routing defect and locks the fix with the parity
test.

## Preserved baseline behavior

The completed refactor preserves the following phase 0 behavior:

- `sys-menu` with no arguments opens the interactive command menu.
- Esc or an empty `fzf` selection returns `0` without dispatching an action.
- A direct canonical token is timed with the `sys:<command>` label.
- The direct route preserves the dispatched command's status.
- Mandatory feature modules load before `_SYS_MENU_SOURCED` is set.
- Re-sourcing the completed suite is silent and harmless.
- Unknown options and dispatcher tokens print an error and return `2`.

The phase 0 snapshot also recorded several legacy behaviors solely so the
refactor could change them deliberately. They were never compatibility
promises. Phases 1 through 6 replace source-time theme evaluation, inaccurate
headers, mixed UI streams, dropped arguments, duplicate System plugin
lifecycle code, unverified AWS and Starship installers, broad cleanup targets,
weak restore validation, and untyped resource mutation.

Remaining gaps are recorded in
[`security-assessment.md`](security-assessment.md); tests must not be weakened
to restore retired legacy behavior.

## Risk classification

Each command has one highest relevant phase 0 risk:

| Risk | Meaning |
| --- | --- |
| `read-only` | Inspects state without an intended mutation |
| `mutating` | Changes user or tool state but is not primarily destructive |
| `destructive` | Deletes, overwrites, clears, or terminates a target |
| `privileged` | Can cross the `sudo` or host-service boundary |
| `remote-code` | Installs, updates, or sources code obtained from a remote origin |

This classification controls migration order. Read-only commands move first;
remote-code and privileged commands move only after their shared safety and
integrity primitives exist.

## Current platform baseline

| Platform | Implemented System behavior | Verification boundary |
| --- | --- | --- |
| Linux | Native collectors plus independent package, systemd, procps/BSD `ps`, `lsof`/`ss`, privilege, fontconfig, and Snap capabilities | Primary automated environment; a capability can still be unavailable on an individual host |
| WSL | Linux base with an overlay for systemd, Snap, Windows interop, and WSL metadata | Mocked overlay decisions and Linux behavior; host facilities remain independently gated |
| macOS | Darwin diagnostics, BSD `ps`, launchd user-domain services, primary Homebrew package detection, independent `softwareupdate`, and user-font paths | Decision and parser behavior is mocked; no real macOS host run is recorded |

The current CI environment is Ubuntu-only. Mocked capability tests protect
branch selection, but macOS support is not considered host-verified until a
macOS CI job or a documented repeatable manual run exists.

## Capability model

The implemented registry detects a base operating system and independent
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
fonts:         fontconfig | macos-user-fonts | unavailable
```

The implemented registry also distinguishes direct root execution from `sudo`
and records `architecture`, an independent macOS update backend, Snap daemon
readiness, and WSL interoperability.

Public commands ask for capabilities rather than platform names. For example,
`sys-services` selects a systemd or launchd backend instead of wrapping its
workflow in one large operating-system conditional.

## Module boundaries

The capability layer and adapters retain the following feature ownership:

```text
functions/
├── sys-menu.zsh
├── sys-common.zsh
└── sys/
    ├── sys-capabilities.zsh
    ├── sys-update.zsh
    ├── sys-clean.zsh
    ├── sys-diag.zsh
    ├── sys-shell-diag.zsh
    ├── sys-dots.zsh
    ├── sys-fonts.zsh
    ├── sys-plugins.zsh
    ├── sys-ports.zsh
    ├── sys-processes.zsh
    ├── sys-services.zsh
    ├── sys-telemetry.zsh
    └── adapters/
        ├── sys-linux.zsh
        ├── sys-wsl.zsh
        └── sys-macos.zsh
```

Later phases may split package and backend execution further. The invariants
are:

- capability detection is read-only and separately testable;
- feature orchestration does not embed platform command construction;
- adapters return data or execute one validated backend operation;
- menu, safety, and logging behavior remain outside platform adapters;
- adapter files do not define public commands.

## Phase sequence

1. **Phase 0 — contract baseline:** freeze public surfaces and intentional
   routing behavior.
2. **Phase 1 — loader and capabilities (complete):** make standalone sourcing
   safe, add the capability model, and isolate platform adapters.
3. **Phase 2 — read-only diagnostics (complete):** port info, health, startup,
   PATH, aliases, and telemetry inspection.
4. **Phase 3 — resources (implemented):** port process and service workflows
   with target revalidation and systemd/launchd backends.
5. **Phase 4 — updates (complete in the current worktree):** add explicit
   maximum and safe-only update plans, fail-fast package-lock handling, verified
   artifacts, and refusal paths for unverifiable installers.
6. **Phase 5 — cleanup and user state (complete in the current worktree):** add
   exact plans, `--dry-run`, path boundaries, safe archives, verified fonts,
   and hardened telemetry state.
7. **Phase 6 — interface closure (implemented):** rebuild the menu and
   completion, forward arguments, delegate compatibility surfaces, and remove
   obsolete System internals.

Each phase keeps the public-surface contract green unless an intentional
interface change is explicitly approved and synchronized.

## Phase 0 verification

[`test/sys_contract.bats`](../test/sys_contract.bats) verifies:

- fixture schema, count, uniqueness, module ownership, and risk metadata;
- definition of all 34 public functions in Zsh;
- exact menu, dispatcher, help, and completion parity;
- interactive cancellation without dispatch;
- timing label and status preservation for direct routing;
- status `2` for an unknown dispatcher token;
- silent, idempotent re-sourcing.

Existing `sys.bats`, `sys_ports.bats`, `sys_doctor.bats`, and `telemetry.bats`
remain behavior regression suites.

## Phase 1 verification

[`test/sys_capabilities.bats`](../test/sys_capabilities.bats) verifies:

- silent standalone loading without core helpers;
- one source-derived module root and no fallback to an unrelated tree;
- timer fallback status preservation;
- loader cleanup and exact module failure status;
- lazy detection and explicit refresh behavior;
- native Linux, WSL overlay, and Darwin adapter selection;
- predicate success, capability absence, and invalid-input statuses;
- registry-backed compatibility helpers;
- stable, data-only registry output.

Repository acceptance still requires this suite to pass together with the
phase 0 surface contract, existing System regressions, syntax checks, and the
aggregate repository gate.

## Phase 2 verification

[`test/sys_diagnostics.bats`](../test/sys_diagnostics.bats) verifies:

- fixed collector routing for native Linux, WSL, and macOS;
- Linux record schemas and mocked Darwin parsers;
- WSL information and launchd health rendering;
- healthy and issue-bearing health reports;
- strict UI/data stream separation;
- portable startup measurements, process-group timeout behavior where GNU
  timeout is available, cleanup, and complete failure;
- PATH diagnostics without prompts or `.zshrc` mutation;
- names-only symbol records and sensitive-definition suppression;
- telemetry schema filtering, malformed records, symlinks, size limits, and
  raw-JSON exclusion from fzf;
- status `2` for invalid public options.

Repository acceptance still requires these tests to pass together with all
earlier System contracts, syntax checks, and the aggregate repository gate.

## Phase 3 verification

[`test/sys_resources.bats`](../test/sys_resources.bats) verifies:

- stderr-only help and status `2` for invalid resource options;
- typed procps, BSD `ps`, `lsof`, `ss`, systemd, and launchd records;
- protected PIDs, non-interactive fail-closed behavior, and the
  `SIGTERM`/`SIGKILL` distinction;
- process fingerprint changes before signaling;
- typed port targets, ambiguous and multiple-owner rejection, and changed
  listener ownership;
- preservation of each PID-to-command association in multi-owner `ss` rows;
- process and systemd revalidation around `sudo -v`, non-interactive final
  `sudo -n`, launchd user-domain targeting, and backend failure propagation;
- read-only `fzf --expect` adapters with accurate legends.

These are deterministic mocked backend tests. They do not constitute a real
macOS host verification.

## Phase 4 verification

[`test/sys_maintenance.bats`](../test/sys_maintenance.bats) verifies:

- side-effect-free aggregate and APT dry-run plans;
- applicability and exact sandboxed dispatch for dnf, pacman, zypper, apk, and
  macOS `softwareupdate`, including Darwin with Homebrew as the primary package
  backend;
- default inclusion of every applicable updater and explicit `--safe-only`
  exclusion of fzf, Oh My Zsh, Zsh plugin, and AI mutable-code updates;
- exact execution of the frozen authorized entry set, the prompt-free Git
  update transport environment with preserved caller SSH overrides, and
  bounded Homebrew metadata-refresh failure isolation;
- exact aggregate flag forwarding to the public AI owner, complete ordered
  eight-target result validation, nested failure attribution, Hermes
  compatibility delegation, and refusal of unverified AWS CLI and Starship
  installer pipelines;
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
- one aggregate sudo authentication decision, the invocation-owned 30-second
  `sudo -n -v` worker under a private `zpty` handle, its acknowledged
  `always` cleanup without job-completion UI, exact displayed privilege
  prefixes, and direct APT's single authentication followed by `sudo -n`;
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
- exact npm, uv, pipx/pip, Cargo, and rustup retry environments; active-path
  ownership and Homebrew/self-managed coexistence for uv; DNF's intentionally
  distinct DNF4 and DNF5 network-retry semantics; and pip's no-input policy;
- Homebrew analytics suppression, inherited auto-update/askpass rejection,
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
  false askpass guard for Homebrew's internal `sudo -A`, plus mandatory
  `brew upgrade --no-ask` execution;
- cleanup plans that preserve shared temporary and Docker resources;
- exact cleanup dispatch from confirmed records, cache-path revalidation, and
  partial-failure propagation without abandoning later steps.

All network clients, privilege escalation, package mutations, shell installers,
Docker commands, and process signals are deny-by-default mocks.

[`test/sys_apt_recovery.bats`](../test/sys_apt_recovery.bats) additionally
verifies failed or timed-out advisory simulations, dry-run failure without
mutation, preserved authorization and dpkg guards, strict index-refresh
failure, and continuation of independent aggregate entries.
[`test/sys_update_interface.bats`](../test/sys_update_interface.bats) covers
Node readiness annotations for an external fnm, loaded or unloaded NVM, absent
NVM directories, and shell functions that cannot substitute for fnm.
[`test/sys_toolchain_recovery.bats`](../test/sys_toolchain_recovery.bats)
verifies Node installation/default/activation failures and current-version
postconditions, plus exact direct Homebrew uv upgrades, relocated Cellar
targets, version-probe failures, and preserved aggregate deduplication.
[`test/sys_repomix_recovery.bats`](../test/sys_repomix_recovery.bats) covers
active-executable ownership, exact npm prefix dispatch and revalidation,
wrapper/custom-installation refusal, Homebrew coexistence, and post-update
verification.

## Phase 5 verification

[`test/sys_state.bats`](../test/sys_state.bats) verifies:

- dotfile backup dry-run behavior and owner-only archive, manifest, and
  checksum publication through staged files and ordered renames;
- checksum tampering, path traversal, NUL-safe post-extraction inspection,
  hardlink and destination-symlink rejection, and configured limits;
- non-interactive restore refusal, mandatory verified pre-restore safety
  backup, post-backup revalidation, and same-directory atomic publication;
- font family allowlisting, network-free dry-run behavior, pinned downloads,
  checksum and expanded-data rejection, real-tree NUL inspection, managed
  markers, non-following list behavior, preservation of unmarked prior trees,
  and recoverable rollback;
- telemetry owner-only permissions, duration, record, final-byte, and partial
  final-line bounds, symlink component and oversized log refusal, and
  fail-closed clear behavior;
- exact plugin argument and status delegation without duplicate lifecycle
  ownership.

These tests use only sandboxed state and deterministic mocks. Real-host smoke
tests and the repository-wide aggregate gate remain separate acceptance
requirements.

## Phase 6 verification

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
- lazy and eager exposure of the same 34-command surface.

The phase 4 and phase 5 high-risk paths are covered by their focused suites.
Core lazy/eager tests also verify idempotency and function-table stubs without
`eval`. The repository-wide gate and real-host smoke tests remain separate
completion requirements.
