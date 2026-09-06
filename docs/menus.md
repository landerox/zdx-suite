# Menu architecture audit and migration notes

This document records what was learned from the current menu implementations.
It is descriptive, not normative. [`development.md`](development.md) and
[`menu-spec.md`](menu-spec.md) override it.

Audit baseline: 2026-07-11. The Git migration described below was completed on
2026-07-25; [`git-menu.md`](git-menu.md) records the implemented contract. The
Developer hardening was completed on the same date and is recorded in
[`dev-menu.md`](dev-menu.md); its full contract was reviewed again on
2026-08-28. Targeted File, Python, Hugging Face, and GPU
hardening passes were implemented on 2026-07-26; their current contracts and
manual acceptance boundaries are recorded in
[`file-menu.md`](file-menu.md), [`py-menu.md`](py-menu.md),
[`hf-menu.md`](hf-menu.md), and [`gpu-menu.md`](gpu-menu.md). The legacy
evidence remains here to explain why the normative standards exist.

## Suite-wide presentation review

The September 2026 presentation review compares all 15 built-in suites and
the master catalog in [`menu-design.md`](menu-design.md). It retains the
canonical command records and local wrappers, standardizes command menus on
80% height and a four-line bottom preview, and adds a documented details
toggle. Descriptions explain outcomes and material limitations; section
previews no longer present the sentinel as a command.

The master groups destinations by ownership and includes route tokens in
visible labels. App and VPN retain their documented task/state views; content
browsers and live dashboards keep layouts appropriate to their data. The
historical layouts below describe the audit baseline, not the current preset.

The terminal compatibility follow-up replaces fixed light RGB text with the
terminal's paired foreground/background, isolates inherited fzf defaults, and
adds an explicit plain picker mode. It also documents the difference between
an updated checkout and an older copy still loaded by a shell. See the
decision's [compatibility review](menu-design.md#terminal-compatibility-follow-up)
for reproduced failures and the native macOS acceptance boundary.

## Why Git and System were reviewed first

`git-menu` and `sys-menu` exercise most of the repository's hard design
problems:

- direct commands and interactive discovery;
- large, split suites with explicit loaders;
- local, remote, privileged, and destructive mutations;
- optional dependencies and runtime capabilities;
- nested `fzf` content browsers;
- aggregation, timing, telemetry, and partial failures;
- platform-specific behavior;
- long-lived shell-session safety.

They are useful design inputs, but neither is a template to copy verbatim.

## Patterns worth preserving

### Cohesive suite modules

Both suites have a small top-level loader, a common file, and feature modules.
This is easier to reason about than a monolithic menu file and gives destructive
areas such as Git history editing or system cleanup their own review boundary.

The target architecture keeps this shape while tightening module ownership and
removing historical section remnants.

### Explicit dispatchers

Both commons use `case` dispatchers. The arms are readable executable
allowlists and reject unknown commands. This is safer than evaluating a selected
string and is the required direction for every suite.

### Direct and interactive surfaces

Both top-level menus accept direct subcommands. This makes actions scriptable,
testable, and accessible without `fzf`. The target standard makes the direct
command the primary behavior and treats the menu as a thin adapter.

### Capability annotations

Menu row helpers can annotate commands whose optional dependencies are missing,
and dispatchers recheck dependencies. Keeping unrelated commands usable when an
optional tool is absent is a good capability-oriented design.

### Safety intent

The suites already contain confirmation gates for high-risk actions such as
discarding changes, force pushing, deleting branches, clearing telemetry,
restoring dotfiles, and terminating processes. System update and cleanup
aggregators also retain per-step results and summarize failures.

The migration should preserve that intent while adding consistent dry-run,
path-boundary, privilege, and non-interactive rules.

## Cross-cutting gaps found

### Public-surface drift

Menu entries, help, dispatchers, completions, tests, and implementations are
maintained manually and can diverge. The phase 0 System audit found
`update-hermes` in the function, menu, help, and completion surfaces but missing
from the dispatcher. Phase 0 corrected the arm and added an exact parity test
across every public surface.

### Over-broad entrypoint preconditions

At the audit baseline, the interactive Git entrypoint required an existing
repository before it built the menu. That blocked actions whose own direct
contract could work outside a repository, such as repository creation or some
global identity operations.

Entrypoints should check only `fzf`; individual commands own repository,
authentication, daemon, platform, and permission checks.

### Core and suite namespace leakage

At the audit baseline, the `_tk_*` prefix was split between `functions.zsh` and
`git-common.zsh`. The master menu sourced Git common to obtain generic UI, and
some suites evaluated core theme helpers while their common file was sourced.

This makes standalone sourcing order-dependent and turns Git into an accidental
core library. New core services use `_zdx_*`; suites keep their own prefix; the
few existing core compatibility helpers must be guarded at invocation time.

### `fzf` behavior duplication

Many nested browsers construct independent color, border, header, prompt, and
preview options. The result is inconsistent legends, terminal layouts, and
dependency behavior.

The target keeps visual theme in core and functional behavior in one wrapper
per suite. Content browsers can extend that wrapper for their record type.

### ANSI in UI chrome

Several headers embed escape sequences, including `$'...\e[...]...'` strings.
Some terminals display those sequences literally, and screen readers cannot
derive meaning from color.

Headers, prompts, labels, and descriptions become plain text. ANSI remains
valid only in content intentionally rendered with `--ansi`, such as a Git diff.

### Inaccurate keyboard legends

Some menus advertise `Tab` as search even though typing performs filtering, or
show suite-wide bindings that are not active in a nested picker. Each `fzf`
call must describe only its actual bindings.

### UI text on stdout

Legacy functions mix blank layout lines, help, dashboards, and status output
with data-producing helpers. This makes command substitution and automation
fragile.

The migration classifies every function as a data producer or UI command and
enforces the stream contract in tests.

### Dynamic shell construction

At the audit baseline, the Git suite and master router contained legacy `eval`
paths for pager composition or selected command invocation. Some previews also
interpolated selected values into shell snippets. Git and the master router no
longer contain those paths; remaining legacy suites continue as separate
migration work.

The target uses argument arrays, fixed `case` dispatch, validated identifiers,
and read-only preview programs. A selected display row is never shell code.

### Destructive scope and path boundaries

Confirmations exist, but broad cleanup and multi-target operations do not all
offer a plan or dry run. Shared temporary-directory globs and archive restores
need stronger boundary validation. PID-based actions also need a final identity
check to reduce process-ID reuse races.

The general development standard now defines a common destructive-action
sequence for every suite.

### Privilege and remote installers

At the audit baseline, the System suite contained legitimate privileged
workflows alongside download-and-install flows that fetched current remote
artifacts or installer scripts without a pinned checksum. One path executed a
freshly downloaded installer through `sudo`.

The completed System hardening now pins and verifies supported artifacts or
refuses automatic installation when it cannot establish artifact identity.
New implementations must preserve that boundary: pin versions, verify checksums
or signatures, extract safely, and elevate only the final verified installation
step.

### Platform assumptions

System diagnostics and maintenance combine Linux `/proc`, systemd, APT, Snap,
GNU command options, Homebrew, WSL, and macOS fallbacks. A repository-wide
platform badge does not prove every command works everywhere.

The target dispatches by capability, isolates platform adapters, and requires a
test or manual verification record for each claimed platform branch.

### Duplicate ownership

`sys-plugins` and `zdx-plugins` both manage the same plugin directory and
lifecycle. Independent implementations create contract and security drift.

The core plugin manager is the owner. A temporary compatibility command should
delegate to it rather than maintain a second implementation.

## Git migration sequence

The completed Git rewrite followed this order:

1. Freeze and test the intentional public command inventory.
2. Separate true core services from Git-only `_tk_*` helpers.
3. Define pure repository, branch, remote, identity, and GitHub discovery
   records.
4. Rebuild direct commands by feature module, starting with read-only paths.
5. Replace `eval`, formatted-row parsing, and duplicated `fzf` calls.
6. Add explicit safety contracts for reset, discard, force push, branch/tag
   deletion, issue deletion, stash deletion, merge, rebase, and cherry-pick.
7. Rebuild the top-level menu from the verified direct surface.
8. Synchronize completion, help, tests, user documentation, and telemetry labels.

Repository context must be checked per command so non-repository operations
remain available directly and interactively.

## System migration sequence

The System suite has been selected as the first production migration of the new
contract. It proceeds in this order:

1. Assign ownership and delegate/remove plugin-manager duplication.
2. Introduce explicit platform and capability adapters.
3. Centralize least-privilege execution and remove the suite-wide keepalive.
4. Replace remote installer flows with pinned, verified artifacts.
5. Make cleanup produce an exact plan and support `--dry-run` consistently.
6. Harden archive restoration, temp paths, process identity, services, and
   package-manager lock handling.
7. Rebuild aggregators with clear skipped, passed, failed, and timed-out states.
8. Rebuild the menu and synchronize completion, help, tests, and user docs.

The Git migration followed System and reused its capability, safety, and
contract-test lessons while adding remote-ref and GitHub transaction controls.

## Developer suite audit findings

The Developer suite was migrated after System. Its audit surfaced problem
classes the Git and System reviews had not, and they are worth recording for the
suites still queued.

### Generic public command names leak into the shell

The suite exported roughly forty unprefixed global functions — `clean-py`,
`run-tests`, `update-all`, `check-health`, `build-package`, `profile-save` — into
every interactive shell. Two of them, `clean-docker` and `docker-prune-all`, also
claimed a lifecycle owned by another suite.

Public commands are now namespaced under `dev-*`, with the old names kept as
one-shot-warning forwarders in a dedicated compatibility module and excluded from
the menu, help, and completion. The forwarders are written out explicitly because
generating them would require `eval` or a computed function name.

### A menu-only pseudo-command

`update-deps-dry` existed as a dispatcher arm that appended `--dry-run` to
another command, so the menu row had no direct equivalent. The fix is a real
one-line public command, `dev-update-deps-dry`, which keeps the
direct-CLI-first principle intact without duplicating logic.

### Two discovery paths with different semantics

Cleanup had an `fd` branch and a `find` branch whose exclusions did not match.
The count came from one and the deletion from the other, so the reported scope
could disagree with what was removed. Prefer one deterministic, testable
discovery path over an optional faster one.

### A capability probe at source time

`dev-common.zsh` ran `python3 -c "import tomllib"` while being sourced, adding a
process to every shell start and printing an error into the user's session.
Capability probes belong at the point of use. This one is deliberately repeated
rather than cached because `PATH` and installed interpreters can change during
a long-lived interactive shell.

### Confirmation conflated two outcomes

The confirmation helper returned non-zero both for "the user declined" and for
"there is no terminal to ask". Callers treated both as a cancellation, so a
scripted cleanup that omitted `--yes` reported success while removing nothing.
The helper now reports three distinct outcomes, and every call site maps
"unavailable" to a hard failure naming the flag to pass.

### Filters consumed and forwarded at once

`export-deps` tried to implement `-o FILE` inside `for arg in "$@"`, where
`shift` cannot work. A `while (( $# ))` loop with an explicit `shift` handles
value-taking flags correctly and lets unknown options fail closed.

### Dispatcher preflights ran before public parsers

Central dependency metadata was treated as an authoritative dispatcher
preflight. That made a missing optional tool hide `--help` and caused an invalid
argument to probe the host before being rejected. The dispatcher now invokes
the public command first. Each public parser handles help and validation, then
the first operational dependency request activates the centralized check.
Menu capability annotations remain advisory rather than becoming a second
runtime contract.

### Multi-select treated every menu action as equivalent

A menu row proves that a command is discoverable, not that it is safe to run
without arguments inside a batch. Formatting, cleanup, environment lifecycle,
profile management, and nested orchestrators have different effects.
Developer now has one explicit batch-eligibility allowlist shared by `--multi`,
profile saving, and profile execution. Selected rows are checked before
dispatch, and every stored token is accepted before the first profile task
runs, so a forged selection or an old profile cannot smuggle a destructive,
source-rewriting, argument-bearing, or nested command into the batch. Eligible
tests and compilers may still execute project code and create documented
artifacts.

### Aggregate consent was silently manufactured

`dev-update-all` checked for a terminal but did not ask the user before passing
`--yes` to destructive children. The repaired aggregate freezes project-file
and infrastructure applicability, shows that scope, and obtains authorization
before any child mutation. A decline starts no step. Interactive cleanup later
shows and confirms its exact targets immediately before removal; explicit
`--yes` authorizes both prompt boundaries while validation still runs. Dry-run
invokes only non-mutating dependency and cleanup previews.

### Full maintenance stopped at the first project-level hiccup

The aggregate failed a whole repository maintenance run for reasons that left
the project consistent: it counted a missing `pyproject.toml` as a failed
dependency step, it skipped the pre-commit update after any dependency
failure (including an unreachable PyPI or a refused backup), it never
refreshed transitive dependencies in `uv.lock`, and the only diagnosis was a
failure count. It now lists inapplicable steps as skipped, refreshes the
lockfile when `uv.lock` exists, skips pre-commit only for an inconsistent
lockfile, and ends with a per-step summary. The generic "cannot reach PyPI"
error also hid the real cause on WSL2 behind a VPN, where TCP connects but
every TLS exchange stalls because `eth0` keeps MTU 1500; the probe now names
the failing layer and the MTU remedy, and pre-commit runs it before touching
anything so a dead network cannot hang `git ls-remote`. Backup pruning also refused any
world-readable copy created before state files became private and aborted the
update that had already published its backup; pruning is now best effort and
removes owned legacy copies.

### A live file was used as its own update plan

Dependency specifiers were rewritten in `pyproject.toml` while the summary was
still being calculated. Rollback then chose the newest file in a shared backup
directory, so a concurrent invocation could restore the wrong snapshot.
Dependency and pre-commit specifiers are now planned and fingerprinted in an
invocation-owned private workspace. Publication requires the exact backup made
for that invocation, and a lock failure restores and verifies the original
content and mode. The staged rollback bytes are compared with that backup
immediately before atomic publication. Hook autoupdate runs with frozen
revisions against a separate private candidate; a monotonicity guard retains
newer immutable pins. Every planned hook environment is installed before
publication. The applicable file-stage hooks run after publication and Git
hook installation with the published configuration, and their findings are
reported without discarding the validated revisions: running them before
publication refused every safe update on a repository with a single lint
finding or fixer rewrite. If the live configuration changes during the
external update, ZDX does not overwrite it: the original snapshot is retained
for manual comparison because an external-tool write cannot be distinguished
safely from a concurrent user edit.

This transaction boundary covers ZDX-owned project files. It cannot make an
external package manager, runtime installer, hook, or linter globally
reversible; those tools retain their own side effects and statuses.

### Canonical descendant checks did not freeze cleanup identity

Re-resolving both a root and candidate after confirmation lets both move
together when the root pathname is replaced. Cleanup now freezes the root path,
device, inode, and type, matches it to the open working directory, and records
each target as a relative path with its own device, inode, and type. The root is
checked after authorization and around every relative removal; a changed target
is refused.

The scan also prunes `.git`, `*.git`, `.venv`, `node_modules`, `vendor`,
`vendored`, and nested repositories found through `.git` markers. NUL-delimited
records and bounded depth keep awkward names as data. A portable userspace
check cannot completely remove the final same-EUID race before `rm`, so the
contract states that residual limit instead of claiming race freedom.
Discovery streams and nested-repository marker inventories now stop at one
beyond the configured plan limit. The combined cleanup plan uses associative
first-seen deduplication; each category is capped after combining its streams,
and the final plan fails before display, authorization, or mutation above
10,000 unique targets by default, with a validated `1..50000` override.
Same-directory publication now applies the corresponding cross-UID rule:
restore, export, and update write parents must be current-user-owned and reject
group/world write without sticky protection. Path and object identities are
revalidated around publication; the unavoidable same-EUID userspace window
remains explicit.

### Private modes did not make state publication safe

Creating a directory and later calling `chmod` did not prove ownership, type,
link count, or stable identity, and direct writes could expose a partial file.
Developer state directories now fail closed unless they are dedicated, owned,
non-symlinked, mode `700`, and identity-stable. Backup, report, and profile
files are private regular files published atomically after owner, mode, link,
parent, and identity checks. Backups, reports, and newly created profiles use
no-clobber publication; an authorized profile overwrite revalidates and
atomically replaces the exact destination. Same-second names do not overwrite
one another, and rollback requires an exact invocation-owned backup. Retention
always protects the backup just published, even under clock skew or manipulated
mtimes, then keeps the newest configured number minus one of the prior backups.

Profile inventory is also bounded: at most 100 files, 8,192 bytes per file, and
64 tasks. The whole file is read through a stable descriptor and every token
must be batch-eligible before the first task is dispatched.

Dependency export applies the same lesson to a caller-selected destination. It
rejects symlink components, freezes the parent and destination, holds an
existing destination inode open while authorization is pending, and writes
through a private same-directory temporary. `uv export --locked` refuses
resolution instead of rewriting the lockfile. An absent destination is
published with atomic no-clobber semantics; an authorized existing destination
uses an identity-checked atomic replacement. The old `uv pip freeze` fallback
was removed because an ambient environment is not the reviewed project lock.
Both the authorized destination and the generated temporary are held open and
fingerprinted across metadata and content, so inode replacement and in-place
edits are detected before publication.

### Temporary caches and numeric configuration are security boundaries

PyPI concurrency previously made its temporary cache an implementation detail.
The cache now validates bounded decimal timeout, retry, and worker settings;
freezes the temporary root, cache directory, and file identities; publishes
entries without clobbering; and quarantines the exact cache inode before
recursive removal. Non-sticky group/world-writable roots are refused and cache
reads propagate their status. Cleanup refuses a replaced path. PyPI and update
workspaces accept only a safe current-EUID root or a root-owned sticky shared
root; a foreign non-root owner is refused.

The same strict parsing applies to scan depth, cleanup depth, cleanup target
count, backup retention, and the ephemeral-runner switch. Expression-like
configuration text is rejected before arithmetic evaluation, and an explicitly
empty state override remains empty so it fails closed rather than falling back
to a dangerous default. Project parsing adds independent 2 MiB and
1,000-dependency bounds, and structured license classification is capped at
10 MiB.

### Read-only labels must include indirect effects

`dev-run-tflint` used to initialize plugins implicitly even though the row was
described as a read-only linter. It now lints without initialization by default;
the remote-code step requires `--init` and confirmation or `--yes`.
State-writing passthrough such as `--fix` is refused.
`dev-run-clippy` similarly refuses source-rewriting `--fix`, passes `--locked`
to protect `Cargo.lock`, and is described as mutating because Cargo may still
create or update generated artifacts below `target/`.

Python runner choice also carries an effect. Declared read-only gates use
`uv run --frozen --no-sync` so they cannot synchronize the project as a side
effect. Installed-package inventories never fall back to a global tool or an
isolated or overlay environment, which would describe the wrong package set.
Their only backend is an importable module under `.venv`; probe and execution
use `python -I` to exclude the current directory, `PYTHONPATH`, and user site.
Pytest, coverage, and pre-commit hook invocations also use frozen no-sync
execution; missing installed dependencies fail rather than silently changing
the lockfile or environment.

Effect review must also include environment variables and backend-specific
options, not only the most familiar command-line flags. Ruff lint removes
`RUFF_OUTPUT_FILE`, Pyright rejects `--createstub`, and audit remediation
requires confirmation or `--yes`.

Confirmation text is also untrusted display data. Developer renders
user-derived prompt text through Zsh's visible escaping before passing it to
fzf or the terminal fallback, so a path containing newlines, escape bytes, or
other controls cannot alter the confirmation UI.

### Display parsing and discovery are contracts too

A human-readable table is not a stable policy format. License strictness now
parses bounded JSON, requires string `Name`, `Version`, and `License` fields,
and classifies only `License`; a malformed schema fails closed. Outdated-package
inspection explicitly passes `.venv/bin/python` and neutralizes
`UV_SYSTEM_PYTHON`.

Likewise, `find -not -path` filters output but does not prune traversal.
Bandit and ShellCheck now share one NUL-delimited collector that prunes
generated and nested-repository trees, propagates discovery errors, caps the
inventory at 512 files, and batches backends in groups of at most 64 paths.

Suite-wide discoverability does not make every check applicable to every
project. Developer labels health as Python/uv health and returns a clean,
explicit no-op without PyPI or metadata failures when no `pyproject.toml`,
`.venv`, `uv.lock`, `.python-version`, or Python source marker exists. Once a
marker exists, the diagnostic keeps its strict failure semantics.

### Environment replacement is a directory transaction

Deleting `.venv` before proving a replacement would turn an update failure into
an outage. `dev-update-python` now authorizes before any mutating uv command,
selects either the sole simple `X.Y` project pin or the current `.venv` minor,
and rejects multiple, exact, complex, or ambiguous pins before mutation. A
non-CPython `.venv` is also delegated to explicit runtime selection before
mutation. The command runs `uv python install --upgrade X.Y`, builds the private
same-filesystem replacement with
`uv venv --clear --managed-python --python X.Y <staged>`, locked-syncs it,
revalidates original and staged directory identities, then swaps by rename.
Publication failure restores the proven original when safe; interruption or an
unverifiable rollback retains a reported recovery workspace rather than
deleting the only recoverable copy. Pin changes remain delegated to
`dev-menu venv-python-pin <major.minor>`; without `.venv`, Dev performs no
runtime mutation and delegates selection, preview, and authorization to
`py-menu venv-python-install`.

The replacement transaction also freezes the `pyproject.toml` and `uv.lock`
content fingerprints. It rechecks those inputs, the interpreter
version/implementation, and the selected minor after authorization; the input
fingerprints are checked again before the global Python upgrade, before locked
sync, and after sync. Any mismatch prevents `.venv` publication.

## VPN suite audit findings

The VPN suite was migrated after Developer. It contributed problem classes the
earlier audits had not surfaced.

### A menu with no direct mode at all

`vpn-menu` iterated its arguments looking only for `-h/--help`. Every other
argument fell through and the interactive menu opened, so `vpn-menu vpn-on wg0`
silently connected nothing and an unknown option did not fail. The dispatcher
existed but only the menu loop could reach it. Check both modes explicitly; a
present dispatcher is not evidence that the CLI is wired to it.

### The preview as an injection sink

A large POSIX script was passed to `--preview` starting with `cmd={2}`, so fzf
substituted the selected record into shell program text, unquoted, and the
script called `sudo -n` six times to gather state.

Rendering panes in Zsh before opening fzf and addressing them by the integer row
index `{n}` removes both problems at once: the program text becomes a constant,
and the privileged reads happen in the suite where they can be gated.

### Data encoded into the command token

Rows used tokens such as `vpn-on:wg0`, and the dispatcher recovered the profile
with string surgery. A documented extra field carrying the target keeps the
command token canonical and gives the entrypoint something to revalidate before
dispatch.

### A dynamic menu defeats surface parity

Because rows depended on live state, a host with no profiles rendered a smaller
command set than a configured one, so no fixture could describe the surface.
Keeping the command set constant and letting state change only labels and extra
per-profile rows makes the surface testable — and the contract test now renders
the menu under two mocked hosts and diffs the sets.

### Feature modules depending on the entrypoint

`vpn-info.zsh` and `vpn-config.zsh` called state helpers defined in
`vpn-menu.zsh`, so the modules could not be sourced without the entrypoint.
Shared state belongs in a module below both.

### Interactive editors and generated hooks are privilege boundaries

Two paths handed attacker-influenced content to root: `sudo $EDITOR`, where a
shell escape yields a root shell, and a generated `PostUp` hook that
interpolated a profile's `DNS` value into an `sh -c` body run by root on every
tunnel transition. `sudoedit` fixes the first by design. The second is fixed by
validating the value as an IP list and refusing anything else — escaping is the
wrong tool when a strict format is available.

The follow-up hardening found a broader version of the hook boundary:
`wg-quick` also runs `PreUp`, `PostUp`, `PreDown`, and `PostDown` copied
verbatim from an imported profile. Import now refuses all four directives by
default and accepts only a private, singly linked, bounded source owned by the
current user. Reviewed hooks can be added later through `sudoedit`.

The final UI follows the normative workflow order rather than the historical
implementation order: read-only status first, connection actions next, profile
workflows after that, and maintenance last. Per-profile rows begin with
`Connect` or `Disconnect`, unsafe profile-directory state is explicit, and
missing command-specific tools are visible without hiding unrelated actions.

## App, CI, Environment, and Network audit findings

The 2026-07-26 hardening passes extended the earlier lessons to four distinct
boundaries.

### Discovery does not authorize execution

App formerly treated descriptor command text as something the menu could
execute. Its inventory now contains only validated task tokens and descriptor
identity. A fixed backend/action `case` constructs the invocation, while a
separate plan and confirmation authorize the project-defined code. Descriptor
text never becomes a preview program or computed command.

### Remote cleanup needs repository-bound typed records

CI now validates bounded GitHub JSON into typed records, binds every API path to
the frozen current repository, protects the newest resource in each relevant
group, and fetches the complete plan again after authorization. Tags and issues
were duplicate ownership; the historical CI names now forward to their public
Git owner instead of retaining a second implementation.

### Dotenv is data, not a shell fragment

Environment no longer sources or expands dotenv/profile bytes. Its literal
parser freezes the full input before any session change, shows names but never
values, and publishes owner-only profiles atomically. Automatic `chpwd`
loading was removed because entering a directory is not authorization to
import its environment.

### Diagnostics must disclose and bound traffic

Network separates local-only inspection from active probes. Each host,
provider response, subprocess, and record batch has a grammar and a byte/time
ceiling. Public-IP requests use a fixed HTTPS provider set, and throughput
testing presents the transfer plan and requires explicit authorization.
Unavailable dashboard sections do not prevent independent diagnostics from
continuing.

## Migration rule

Do not rewrite every suite at once. Migrate one suite in reviewable stages,
keep focused tests green, and use the resulting lessons to amend the canonical
documents before starting the next suite.

A migration is complete only when it passes the checklists in
`development.md`, `menu-spec.md`, `headers.md`, and `testing.md`.
