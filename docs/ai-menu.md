# AI Suite

`ai-menu` is the canonical entry point for local AI-assistant inspection,
recoverable cache quarantine, project-instruction bootstrap, configuration
snapshots, passive MCP audits, and reviewed installed-CLI updates.

## Menu presentation

The command menu uses an 80% height, label-only rows, and four lines of details
below the list. Sections show only their description. Its header identifies
local AI assistants and advertises
`Type to filter | Enter run | Esc cancel | Ctrl-/ details`.
Multi-selection keeps the existing six inspection commands and adds
`Tab mark | Read-only tasks only`; no select-all shortcuts are added.
MCP compatibility inspection appears with diagnostics. Cleanup labels and
descriptions distinguish recoverable moves from Cursor and Amp commands that
preserve all their data.

## Grammar and status

```text
ai-menu
ai-menu --multi
ai-menu COMMAND [COMMAND-OPTIONS]
ai-menu --help
```

Direct command names are also registered after completion initialization. The
public surface is frozen in `test/fixtures/ai-public-commands.tsv`; `aip-menu`
is not part of it.

- `0`: completed command, empty plan, informational doctor result, or user
  cancellation.
- `1`: runtime, validation, trust, or partial-operation failure.
- `2`: unknown command, option, or operand.
- `125` and `130`: internal adapter/integrity and FZF-cancellation statuses;
  public `ai-menu` normalizes an ordinary cancellation to `0`.
- `130` and `143` from an executing updater are preserved as interruption
  statuses through direct and interactive routing; later updates do not run.

`--multi` contains only `ai-doctor`, `ai-disk-usage`, `ai-versions`,
`ai-log-tail`, `ai-mcp-list`, and `ai-mcp-doctor`. Mutating commands cannot
enter a multi-select snapshot.

## Command options

| Commands | Accepted options |
| --- | --- |
| `global-clean-*` | `--dry-run`, `--yes`/`-y`, `--verbose`/`-v`, `--help` |
| `project-sweep-ai` | cleanup options plus `--root PATH`, `--depth 1..8`, `--xdev` |
| `ai-init-agents` | `--dry-run`, `--yes`/`-y`, `--minimal`, `--verbose`/`-v`, `--help` |
| `ai-update*` | `--dry-run`, `--yes`/`-y`, `--skip-homebrew-managed`, `--result-tsv`, `--help` |
| `ai-mcp-list`, `ai-mcp-doctor` | `--help` |
| `ai-mcp-update` | `--dry-run`, `--yes`/`-y`, `--help` (audit-only) |
| `ai-config-backup` | `--dry-run`, `--yes`/`-y`, `--verbose`/`-v`, `--help` |
| `ai-config-restore [SNAPSHOT]` | `--dry-run`, `--yes`/`-y`, `--verbose`/`-v`, `--help` |
| `ai-doctor` | `--report`, `--verbose`/`-v`, `--help` |
| `ai-disk-usage` | `--verbose`/`-v`, `--help` |
| `ai-versions` | `--json`, `--verbose`/`-v`, `--help` |
| `ai-log-tail` | `--lines 1..500`, `--verbose`/`-v`, `--help` |

Human help, plans, diagnostics, and progress use `stderr`. Machine-readable
stdout is limited to `ai-versions --json` and the opt-in updater protocol
described below. Color is disabled when `NO_COLOR` is non-empty, when
`TERM=dumb`, or when `stderr` is not a terminal.

`ai-versions --json` prints one object keyed by the canonical assistant IDs
`claude`, `codex`, `antigravity`, `opencode`, `cursor`, `copilot`, `amp`, and
`hermes`, plus `runtime`. Every assistant record uses exactly one of these
shapes:

| State | Record |
| --- | --- |
| Installed and probed | `{"label", "installed": true, "version", "binary"}` |
| Installed, bounded probe failed | `{"label", "installed": true, "version": "unavailable", "binary", "probeStatus": "failed"}` |
| Shell wrapper only | `{"label", "installed": false, "available": true, "state": "wrapper-only"}` |
| Absent | `{"label", "installed": false}` |

`runtime` carries the bounded `node` and `npm` version strings, empty when the
runtime is absent. Version strings are control-escaped and never contain `|`.
The human table on `stderr` lists the same assistants in the same order.

## Safety and trust boundaries

The loader resolves one source-derived module root and accepts only regular,
readable, non-symlink modules from that exact root. Sourcing defines functions
only: it does not probe tools, modify `PATH`, install packages, start timers,
or register global traps. Dispatch uses fixed `case` arms and forwards
arguments without evaluation.

Cleanup plans contain at most 256 owned, canonical, non-symlink targets below
`HOME`. They exclude durable task, conversation, plan, session, all Cursor
installation/project state, and Amp recovery state. Root identity is frozen
before review and revalidated immediately before relocation. Every accepted
target is moved on the same filesystem to an invocation-owned directory below
the private `~/.local/share/zdx/ai-trash` quarantine. Cross-filesystem targets and trees
with nested mounts are refused. Each entry includes a private `.zdx-origin`
file containing its reviewed original path for manual recovery. There is no
automatic purge, so these commands
remove stale paths from active tool locations but do not reclaim disk.
`global-clean-ai` builds one combined plan and asks once. `--dry-run` creates
no quarantine path and performs no relocation.

OpenCode roots honor an absolute `XDG_CONFIG_HOME` or `XDG_DATA_HOME`. The
cleanup, disk-usage, doctor, and log commands resolve the same canonical
directories, a relative or empty override falls back to the default below
`HOME`, and cleanup still refuses a resolved data root outside `HOME`.

`project-sweep-ai` accepts only a canonical owned root inside `HOME`. It
searches only known assistant-owned debug, log, cache, and temporary directories;
name-only temporary-file patterns are deliberately excluded. Depth is at most
eight; the inventory is private,
NUL-delimited, limited to 8 MiB and 256 targets, and the scan requires
`timeout` or `gtimeout` with a 15-second deadline. Root and target identities
are revalidated after authorization and before each quarantine relocation.
`--xdev` constrains discovery; the independent `findmnt` and device checks
protect relocation.

Configuration backups copy only allowlisted top-level owned regular config
files, cap each file at 16 MiB, reserve a no-clobber mode-`0700` token directory
under `~/.ai-suite-backups`, and verify every copied checksum in its manifest.
`--dry-run` creates no backup path. Snapshots are not auto-rotated. Restore
takes one validated token. When the token is omitted, the command inventories
the owner-only, mode-`0700` snapshot directories below the private backup root,
newest first, and offers them in the suite's private foreground picker; the
picker reads directory names and manifest line counts only, and the selected
row must match the rendered inventory before its token is revalidated.
Cancellation returns `0`; an empty inventory, an unsafe backup root, or a
selection outside the rendered inventory returns `1`; and a missing `fzf`
prints the available tokens and returns `2`. Zsh completion offers the same
directory names without opening any snapshot file. Restore then rejects
traversal and duplicate manifest paths,
validates private parent chains, stages each file in its destination directory,
publishes absent files with a no-clobber hard link, and preserves an existing
file as the atomic hard-link rollback `FILE.bak.SNAPSHOT`. Existing-file
replacement uses `mv -T` where the host `mv` supports it (probed per
invocation) and otherwise falls back to Zsh's rename builtin behind an
explicit directory recheck; it fails closed only when neither path is
available.

Version and doctor probes walk only absolute, control-free runtime `path`
entries and invoke the exact external executable under a deadline. They ignore
aliases, functions, and stale command hashes. When a supported Node-based CLI
is absent from `PATH`, discovery may passively resolve the strict standard
`~/.nvm/alias/default` layout. That fallback accepts only an exact `vX.Y.Z`
default alias from a singly linked file of at most 64 bytes. The NVM directory
chain and alias file must be current-user-owned, non-symlink, and not
group/world writable; the resolved launcher, canonical target, and exact Node
interpreter must remain inside that one version directory and pass their type,
ownership, and mode constraints; the Node interpreter is also size-bounded.
Aliases such as `lts/*` fail closed, and ZDX does not scan other installed
versions. It never sources `nvm.sh`, evaluates shell text, or executes a lazy
wrapper. The validated NVM `bin` prefix is added only to the probe or updater
child environment for an `env node` shebang; the caller's `PATH` is unchanged.

Cursor Agent and Amp can initialize runtime cache data even for a version
request, so their probes keep `HOME` unchanged but set `XDG_CACHE_HOME` to an
invocation-owned mode-`0700` directory below the validated private probe root.
That exact cache root is identity-checked and removed after the probe, so
version discovery does not populate the assistant's persistent cache. Amp's
passive version action is `amp --version` (`amp -v` is its equivalent short
form). Its Bun runtime receives a fixed 16 MiB per-file ceiling so it can
materialize its native module; the five-second deadline and independent
64 KiB stdout/stderr limits remain unchanged. A wrapper-only name and an
external executable whose version probe failed are reported separately from a
genuinely absent command.

Hermes is probed with its official `--version` flag and child-local
`PYTHONUNBUFFERED=1`. A complete first-line `Hermes Agent vX.Y.Z` banner,
optionally followed by whitespace and vendor detail, is accepted after status
`0` or a status-`124` deadline reached by its subsequent upstream-status lookup.
Other nonzero statuses, malformed banners, and oversized output fail closed.
This establishes the installed version only. All CLI version probes receive
closed stdin, independently cap stdout and stderr at 64 KiB, and use a
five-second process-group deadline with a one-second termination grace period.
Hermes itself may fetch update metadata and write `~/.hermes/.update_check`
during `--version`, including a ZDX dry run; ZDX does not invoke its updater
as part of that probe.

`ai-update` reviews and invokes the official self-updaters of every supported
installed assistant. The individual commands retain the same boundary:

| Command | Fixed delegated action |
| --- | --- |
| `ai-update-claude` | `claude update` |
| `ai-update-codex` | `codex update` |
| `ai-update-antigravity` | `agy update` |
| `ai-update-opencode` | `opencode upgrade` |
| `ai-update-cursor` | `cursor-agent update` |
| `ai-update-copilot` | `copilot update` |
| `ai-update-amp` | `amp update` |
| `ai-update-hermes` | `hermes update --backup --yes` |

No update command installs a missing assistant. ZDX uses the same exact
external-executable resolver described above, requires the launcher and its
canonical target to be current-user- or root-owned and not group/world
writable, and freezes the launch object, canonical target, metadata, and
checksum. An NVM-resolved update also fingerprints the exact Node interpreter,
including metadata and checksum. The bounded version probe must establish a
validated version before the target enters the plan. The exact path and
arguments are shown before one
confirmation; `--dry-run` performs no updater mutation. Identity and checksum
are revalidated immediately before delegation, then the resulting executable
and version are checked again. Ordinary failures continue independent targets
and make the aggregate return nonzero. An updater or its output sink returning
`130` or `143` stops further updates and preserves that interruption status
after private-output cleanup, with the updater's interruption taking priority.
An ordinary sink failure remains an output-integrity failure. Later eligible
targets retain ledger entries as `not-run` with reason `interrupted` and the
same status; already completed and initially skipped or failed entries remain
unchanged. A cancellation remains successful only
when planning found no failure before the prompt. After a successful self-updater, ZDX
compares the bounded pre/post version and validated executable fingerprint. A
changed version or changed executable counts as `updated`; `already current`
requires both values to remain unchanged. Every invocation ends with an
`AI updater results` ledger containing exactly one terminal human-readable line
for every requested assistant, including missing, skipped, planned, cancelled,
and failed targets. Execution summaries keep updated, already-current, failed,
and skipped totals separate; dry-run and authorization summaries also account
for `planned` and `not run` outcomes. Partial-success timing requires at least
one updated or already-current target; absent or otherwise skipped tools do
not turn an entirely failed execution into a partial success.

`--result-tsv` adds a versioned data channel without changing that stderr UI.
It emits exactly one bounded stdout row per requested target, in request order:

```text
ai-update-result-v1<TAB>id<TAB>label<TAB>outcome<TAB>reason<TAB>rc
```

`outcome` is one of `updated`, `already-current`, `failed`, `skipped`,
`planned`, or `not-run`. `reason` is a fixed code owned by the AI suite, and
`rc` is a decimal status from `0` through `255` consistent with that outcome.
The aggregate command emits the canonical eight IDs from `claude` through
`hermes` exactly once. Labels, outcomes, and reasons are synthesized by ZDX;
vendor output, versions, paths, and credentials never enter the records. A
record-publication error makes the command fail. `update-system` consumes this
public protocol rather than parsing human messages or private `_ai_*` state.

Updater output is drained into a private tail capped at 256 KiB and is not
replayed because vendor diagnostics can contain credentials. A recognized
`unauthenticated` result is reported as an authentication precondition, a
recognized `failed_precondition` result is reported as a distinct unmet vendor
precondition, and other nonzero results remain updater failures with their exit
status. ZDX provides an explicit next step but never runs a login, logout, or
reinstallation command on the user's behalf. The delegated updater receives
`/dev/null` as stdin, so it cannot silently consume input hidden by the private
output capture.

OpenCode can emit a complete `Upgrade failed` terminal line while returning
status `0`. For that specific updater, the private capture recognizes the
anchored failure line, including terminal decoration, and returns `1` with the
existing `updater-failed` result reason. A recognized authentication or vendor
precondition remains the more specific failure category. Other vendors' text
and a genuine OpenCode already-current result do not trigger this rule.

These are remote-code operations: each installed vendor updater selects its
latest release dynamically and owns artifact transport and signature
verification. `--yes` accepts that displayed trust boundary; it does not bypass
validation. `--skip-homebrew-managed` leaves canonical paths below a Homebrew
`Cellar` or `Caskroom` to the System suite's Homebrew step and prevents a
second updater in `update-system`.

MCP configuration is treated only as data. Claude user and local declarations
are read from `~/.claude.json` (or the exact `CLAUDE_CONFIG_DIR` equivalent),
shared project declarations from the current project's `.mcp.json`,
Antigravity declarations from `~/.gemini/config/mcp_config.json` and the
current workspace's `.agents/mcp_config.json`, and Cursor user declarations
from `~/.cursor/mcp.json`. The `.gemini` directory name is Antigravity's current
vendor-defined storage layout and is retained only for those official
Antigravity files. Both typed `url` transports and Antigravity `serverUrl`
transports are classified without printing their value. Linked, non-owned,
writable, oversized, or unstable config files are refused. Local commands are
resolved without execution; remote URLs and headers are neither contacted nor
printed.
`ai-mcp-update` is a compatibility name for the same passive audit and never
changes configuration or package caches.

Log discovery is deadline- and byte-bounded and considers at most 512 owned,
canonical, single-link files,
rejects files over 64 MiB, revalidates the selected file, reads at most the
last 256 KiB, prints at most 500 lines, truncates each line to 4096
characters, escapes controls, and redacts common key/token forms.

## Residual risks

- A filesystem operation stuck in uninterruptible kernel I/O can outlive a
  userspace timeout. Cleanup also requires `findmnt`; without it, directory
  relocation fails closed.
- Log redaction is heuristic. An unknown secret format can remain visible, so
  excerpts must still be handled as sensitive data.
- Restore is atomic per file, not across the complete manifest. A later
  failure returns nonzero; earlier replacements remain visible with rollback
  copies. Where the host `mv` lacks `-T`, replacement uses Zsh's rename
  builtin behind a directory recheck, so the final same-EUID window is a
  contained pathname race rather than an unconditional refusal; the digest
  postcondition still fails a misdirected publication.
- Snapshots are deliberately never pruned automatically and can consume disk
  until the operator removes reviewed snapshots separately.
- Quarantine has no automated retention or purge policy and will grow until
  the operator separately reviews and removes it.
- A vendor self-updater resolves a mutable latest release after authorization.
  ZDX freezes the installed launcher, not the remote artifact, and therefore
  cannot independently prove the selected release digest. Use `--dry-run`,
  review the vendor origin, and use System `--safe-only` when that upstream
  trust is not acceptable.
- A same-EUID process can still replace a path after the final userspace
  revalidation. Executable identity checks narrow but cannot eliminate that
  race without platform-specific descriptor execution.
