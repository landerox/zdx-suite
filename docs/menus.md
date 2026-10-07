# Menu architecture audit

This document describes the current menu implementations and the problem
classes that shaped the repository's standards. It is descriptive, not
normative: [`development.md`](development.md) and
[`menu-spec.md`](menu-spec.md) override it, and each suite contract records
its exact behavior. Read it to understand why a rule exists before changing or
relaxing that rule.

## Shared presentation

Every built-in command menu (Workspace, Git, System, Developer, File,
Environment, and Python) keeps canonical `label|command|description` records and a suite-local
fzf wrapper. It uses an 80% height, label-only rows, a four-line details pane
below the list that `Ctrl-/` toggles, and the plain legend
`Type to filter | Enter run | Esc cancel | Ctrl-/ details`. Section previews
show only their description and never present the section sentinel as a
command. Descriptions explain outcomes and material limitations.

The `zdx` master catalog groups destinations by ownership and includes route
tokens in visible labels. VPN keeps its documented state view, with a side
preview that moves below the list on narrow terminals, and content browsers
and dashboards use layouts suited to their data.
[`menu-design.md`](menu-design.md) records the presentation decision.

Pickers pair foreground and background with the terminal's own palette
instead of fixed RGB text, isolate inherited fzf defaults, and offer a plain
mode (`ZDX_FZF_PLAIN=1`) with ASCII chrome. `NO_COLOR` and `TERM=dumb` remove
color without changing text. [`menu-design.md`](menu-design.md) also records
the measured rendering behavior across fzf releases and the remaining manual
terminal acceptance.

## Why Git and System are the reference suites

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

## Patterns the standards adopt

### Cohesive suite modules

Each suite has a small top-level loader, a common file, and feature modules.
This is easier to reason about than a monolithic menu file and gives
destructive areas such as Git history rewriting or system cleanup their own
review boundary.

### Explicit dispatchers

Every suite routes through a `case` dispatcher. The arms are a readable
executable allowlist and reject unknown commands. This is safer than
evaluating a selected string.

### Direct and interactive surfaces

Every top-level menu accepts direct subcommands, which makes actions
scriptable, testable, and accessible without `fzf`. The direct command is the
primary behavior, and the menu is a thin adapter over it.

### Capability annotations

Menu row helpers mark a command whose requirements are missing with a text
annotation, such as `○ <label> (missing: …)`, whose exact forms
[`menu-spec.md`](menu-spec.md) defines, and every command rechecks its own
dependencies. Unrelated commands stay usable when an optional tool is absent.

### Reviewed mutations

High-risk actions such as discarding changes, force pushing, deleting
branches, clearing telemetry, and terminating processes show a plan and
require confirmation or an explicit `--yes`. System update and cleanup
aggregators keep per-step results and summarize failures.
[`development.md`](development.md) generalizes this into one destructive-action
sequence with dry-run, path-boundary, privilege, and non-interactive rules.

## Problem classes and their controls

### Public-surface drift

Menu entries, help, dispatchers, completions, tests, and implementations are
maintained by hand and can diverge: a command can appear in the function,
menu, help, and completion surfaces while missing from the dispatcher. Each
suite therefore has a command fixture under `test/fixtures/` and a contract
test that compares every public surface with it.

### Over-broad entrypoint preconditions

A menu that requires a repository before it opens blocks actions whose own
contract works outside one, such as a global Git identity switch. Entrypoints
check only what the menu itself needs: `fzf`, plus a usable Git where the menu
computes repository context. Individual commands own repository,
authentication, daemon, platform, and permission checks, so operations that
need no repository stay available directly and interactively.

### Core and suite namespace leakage

When one suite's common file supplies generic UI to others, standalone
sourcing becomes order-dependent and that suite becomes an accidental core
library. Core services use `_zdx_*`, suites keep their own prefix, and the few
core compatibility helpers, such as `_tk_fzf_color_opts` and `_timed`, are
consumed through suite wrappers that check for them at invocation time.

### `fzf` behavior duplication

Nested browsers that construct their own color, border, header, prompt, and
preview options produce inconsistent legends, terminal layouts, and dependency
behavior. The visual theme lives in core and functional behavior in one
wrapper per suite; content browsers extend that wrapper for their record type.

### ANSI in UI chrome

Escape sequences embedded in headers, such as `$'...\e[...]...'` strings,
display literally in some terminals, and screen readers cannot derive meaning
from color. Headers, prompts, labels, and descriptions are plain text. ANSI is
valid only in content intentionally rendered with `--ansi`, such as a Git
diff.

### Inaccurate keyboard legends

A legend that advertises `Tab` as search when typing filters, or that shows
suite-wide bindings inactive in a nested picker, misleads the user. Each
`fzf` call describes only its actual bindings.

### UI text on stdout

Mixing blank layout lines, help, dashboards, and status output with data makes
command substitution and automation fragile. Every function is either a data
producer or a UI command, and tests enforce the stream contract.

### Dynamic shell construction

`eval` for pager composition or command invocation, and previews that
interpolate selected values into shell snippets, turn data into code. No
suite uses `eval`: dispatch and previews use argument arrays, fixed `case`
arms, validated identifiers, and read-only preview programs. A selected
display row is never shell code.

### Destructive scope and path boundaries

A confirmation alone does not bound a broad cleanup or a multi-target
operation. Shared temporary-directory globs need boundary validation, and
PID-based actions need a final identity check to reduce process-ID reuse
races; `sys-processes` compares the process start time before it sends a
signal. The destructive-action sequence in [`development.md`](development.md)
requires an exact plan, a dry run for broad operations, confirmation or
`--yes`, revalidation, and per-target results.

### Privilege and remote installers

Fetching a current remote artifact or installer script without a pinned
checksum, and running it through `sudo`, hands remote code to root. The System
suite pins and verifies supported artifacts, or refuses automatic installation
when it cannot establish artifact identity. Any new installer must pin
versions, verify checksums or signatures, extract safely, and elevate only the
final verified installation step.

### Platform assumptions

System diagnostics and maintenance span Linux `/proc`, systemd, APT, Snap, GNU
command options, Homebrew, WSL, and macOS. A repository-wide platform badge
does not prove that every command works everywhere. Suites dispatch by
capability, isolate platform adapters, and need a test or manual verification
record for each claimed platform branch; each suite contract records its
Linux, WSL, and macOS behavior.

### Duplicate ownership

Two commands that manage the same plugin directory and lifecycle drift apart
in contract and security. The core plugin manager, `zdx-plugins`, is the only
owner of plugin management. A compatibility command, if one is ever needed,
delegates to the owner instead of keeping a second implementation.

## Developer suite findings

The Developer suite surfaced problem classes that the Git and System suites
did not.

### Generic command names leak into the shell

Unprefixed global functions such as `clean-py`, `run-tests`, or `update-all`
would collide with user functions in every interactive shell. Every Developer
command is namespaced under `dev-*`.

### Menu-only pseudo-commands

A dispatcher arm that appends `--dry-run` to another command gives a menu row
with no direct equivalent. Every Developer menu row maps to a real public
command, and a preview is a flag of that command, such as
`dev-update-deps --dry-run`.

### One discovery path

A cleanup with two discovery backends whose exclusions differ can count from
one and delete from the other, so the reported scope disagrees with what was
removed. Developer cleanup uses one deterministic, testable discovery path
rather than an optional faster one.

### No capability probes at source time

A probe such as `python3 -c "import tomllib"` that runs while a file is
sourced adds a process to every shell start and can print errors into the
session. Capability probes run at the point of use. They are repeated rather
than cached because `PATH` and installed interpreters can change during a
long-lived interactive shell.

### Confirmation has three outcomes

Treating "the user declined" and "there is no terminal to ask" as the same
cancellation would let a scripted cleanup that omitted `--yes` report success
while removing nothing. The confirmation helper reports `confirmed`,
`declined`, or `unavailable`, and every call site maps `unavailable` to a hard
failure that names the flag to pass.

### Parsers run before preflights

Value-taking flags need a `while (( $# ))` loop with an explicit `shift`,
because `shift` cannot consume a value inside `for arg in "$@"`, and unknown
options must fail closed. Central dependency metadata used as a dispatcher
preflight would hide `--help` when an optional tool is missing and probe the
host before rejecting an invalid argument. The dispatcher therefore invokes
the public command first: each parser handles help and validation, and the
first operational dependency request runs the centralized check. Menu
capability annotations stay advisory rather than becoming a second runtime
contract.

### Batch eligibility is explicit

A menu row proves that a command is discoverable, not that it is safe to run
without arguments inside a batch. Formatting, cleanup, environment lifecycle,
and nested orchestrators have different effects. Developer keeps one explicit
batch-eligibility allowlist for `--multi` and checks selected rows against it
before dispatch, so a forged selection cannot smuggle a destructive,
source-rewriting, argument-bearing, or nested command into the batch.
Eligible tests and compilers may still execute project code and create
documented artifacts.

### Aggregate consent is never manufactured

An aggregate that passes `--yes` to destructive children without asking the
user manufactures consent. `dev-update-all` freezes project-file and
infrastructure applicability, shows that scope, and obtains authorization
before any child mutation; a decline starts no step. Interactive cleanup then
shows and confirms its exact targets immediately before removal. An explicit
`--yes` authorizes both prompt boundaries while validation still runs, and a
dry run invokes only non-mutating dependency and cleanup previews.

### Maintenance continues past project-level gaps

A maintenance run should not fail for reasons that leave the project
consistent. `dev-update-all` lists inapplicable steps, such as a dependency
update without `pyproject.toml`, as skipped, refreshes the lockfile when
`uv.lock` exists, skips the pre-commit update only for an inconsistent
lockfile, and ends with a per-step summary.

A generic "cannot reach PyPI" error would hide the real cause on WSL2 behind a
VPN, where TCP connects but every TLS exchange stalls because `eth0` keeps MTU
1500. The reachability probe names the failing layer and the MTU remedy, and
the pre-commit update runs it before touching anything, so a dead network
cannot hang `git ls-remote`. Backup pruning is best effort and never aborts an
update that has already published its backup.

### A live file is never its own update plan

Rewriting `pyproject.toml` while the summary is still being calculated, and
rolling back to the newest file in a shared backup directory, could let a
concurrent invocation restore the wrong snapshot. Dependency and pre-commit
specifiers are planned and fingerprinted in an invocation-owned private
workspace. Publication requires the exact backup made for that invocation,
and a lock failure restores and verifies the original content and mode. The
staged rollback bytes are compared with that backup immediately before atomic
publication.

Hook autoupdate runs with frozen revisions against a separate private
candidate, and a monotonicity guard retains newer immutable pins. Every
planned hook environment is installed before publication. The applicable
file-stage hooks run after publication and Git hook installation with the
published configuration, and their findings are reported without discarding
the validated revisions; running them before publication would refuse every
safe update on a repository with a single lint finding or fixer rewrite. If
the live configuration changes during the external update, ZDX does not
overwrite it: the original snapshot is retained for manual comparison because
an external-tool write cannot be distinguished safely from a concurrent user
edit.

This transaction boundary covers ZDX-owned project files. It cannot make an
external package manager, runtime installer, hook, or linter globally
reversible; those tools retain their own side effects and statuses.

### Cleanup freezes identity, not only paths

Re-resolving both a root and a candidate after confirmation lets both move
together when the root pathname is replaced. Cleanup freezes the root path,
device, inode, and type, matches it to the open working directory, and
records each target as a relative path with its own device, inode, and type.
The root is checked after authorization and around every relative removal; a
changed target is refused.

The scan prunes `.git`, `*.git`, `.venv`, `node_modules`, `vendor`,
`vendored`, and nested repositories found through `.git` markers.
NUL-delimited records and bounded depth keep awkward names as data. A portable
userspace check cannot completely remove the final same-EUID race before `rm`,
so the contract states that residual limit instead of claiming race freedom.
Discovery streams and nested-repository marker inventories stop at one beyond
the configured plan limit. The combined cleanup plan uses associative
first-seen deduplication; each category is capped after combining its
streams, and the final plan fails before display, authorization, or mutation
above 10,000 unique targets by default, with a validated `1..50000` override
(`DEV_CLEAN_MAX_TARGETS`).

Same-directory publication applies the corresponding cross-UID rule: the
parents that updates write must be current-user-owned and reject group or
world write without sticky protection. Path and object identities are
revalidated around publication, and the unavoidable same-EUID userspace window
remains explicit.

### Private modes do not make state publication safe

Creating a directory and later calling `chmod` does not prove ownership, type,
link count, or stable identity, and direct writes can expose a partial file.
Developer state directories fail closed unless they are dedicated, owned,
non-symlinked, mode `700`, and identity-stable. Backup and report files are
private regular files published atomically with no-clobber semantics after
owner, mode, link, parent, and identity checks. Same-second names do not
overwrite one another, and rollback requires an exact invocation-owned backup.
Retention always protects the backup just published, even under clock skew or
manipulated mtimes, then keeps the newest configured number minus one of the
prior backups.

### Temporary caches and numeric configuration are security boundaries

A temporary cache shared by concurrent PyPI requests is a security boundary,
not an implementation detail. The cache validates bounded decimal timeout,
retry, and worker settings (`DEV_PYPI_TIMEOUT`, `DEV_PYPI_RETRIES`, and
`DEV_PYPI_JOBS`); freezes the temporary root, cache directory, and file
identities; publishes entries without clobbering; and quarantines the exact
cache inode before recursive removal. Non-sticky group/world-writable roots
are refused, cache reads propagate their status, and cleanup refuses a
replaced path. PyPI and update workspaces accept only a safe current-EUID root
or a root-owned sticky shared root; a foreign non-root owner is refused.

The same strict parsing applies to the scan depth, cleanup depth, cleanup
target count, backup retention, and ephemeral-runner settings.
Expression-like configuration text is rejected before arithmetic evaluation,
and an explicitly empty state override stays empty so it fails closed rather
than falling back to a dangerous default. Project parsing adds independent
2 MiB and 1,000-dependency bounds.

### Read-only labels include indirect effects

A linter described as read-only must not initialize plugins implicitly.
`dev-run-tflint` lints without initialization by default; the remote-code
plugin download requires `--init` and confirmation or `--yes`, and
state-writing options such as `--fix` are refused.

The Python runner also carries an effect. A declared Python tool runs only
from the project's own `.venv`, through `python -I -m` when its module allows
it, so a read-only gate cannot synchronize the project as a side effect, and a
missing installed dependency fails instead of changing the lockfile or
environment. Installed-package inventories never fall back to a global tool or
an isolated or overlay environment, which would describe the wrong package
set; probe and execution use `python -I` to exclude the current directory,
`PYTHONPATH`, and the user site.

Effect review also covers environment variables and backend-specific options,
not only the most familiar flags. Ruff lint removes `RUFF_OUTPUT_FILE`,
`dev-check-types` accepts no passthrough arguments, and
`dev-run-audit --fix` requires confirmation or `--yes`.

Confirmation text is untrusted display data too. Developer renders
user-derived prompt text through Zsh's visible escaping before passing it to
fzf or the terminal fallback, so a path containing newlines, escape bytes, or
other controls cannot alter the confirmation UI.

### Discovery and applicability are contracts

`find -not -path` filters output but does not prune traversal. Bandit,
ShellCheck, and markdownlint share one NUL-delimited collector that prunes
generated and nested-repository trees, propagates discovery errors, caps the
inventory at 512 files, and runs backends in batches of at most 64 paths.
Outdated-package inspection passes `.venv/bin/python` explicitly and
neutralizes `UV_SYSTEM_PYTHON`.

Suite-wide discoverability does not make every check applicable to every
project. `dev-check-health` is a Python/uv health check and returns a clean,
explicit no-op without PyPI or metadata failures when no `pyproject.toml`,
`.venv`, `uv.lock`, `.python-version`, or Python source marker exists. Once a
marker exists, the diagnostic keeps its strict failure semantics.

### Environment replacement is a directory transaction

Deleting `.venv` before proving a replacement would turn an update failure
into an outage. `dev-update-python` authorizes before any mutating uv command,
selects either the sole simple `X.Y` project pin or the current `.venv` minor,
and rejects multiple, exact, complex, or ambiguous pins before mutation. A
non-CPython `.venv` is also delegated to explicit runtime selection before
mutation. The command runs `uv python install --upgrade X.Y`, builds the
private same-filesystem replacement with
`uv venv --clear --managed-python --python X.Y <staged>`, locked-syncs it,
revalidates original and staged directory identities, then swaps by rename.
Publication failure restores the proven original when safe; interruption or
an unverifiable rollback retains a reported recovery workspace rather than
deleting the only recoverable copy. Pin changes belong to
`py-menu venv-python-pin <major.minor>`; without `.venv`, Developer performs no
runtime mutation and delegates selection, preview, and authorization to
`py-menu venv-python-install`.

The replacement transaction also freezes the `pyproject.toml` and `uv.lock`
content fingerprints. It rechecks those inputs, the interpreter version and
implementation, and the selected minor after authorization; the input
fingerprints are checked again before the global Python upgrade, before locked
sync, and after sync. Any mismatch prevents `.venv` publication.

## VPN suite findings

The VPN suite contributed problem classes that the other audits did not
surface.

### Both entrypoint modes must be wired

A menu that scans its arguments only for `-h` or `--help` opens the
interactive menu for everything else, so `vpn-menu vpn-on wg0` would connect
nothing and an unknown option would not fail. `vpn-menu` checks both modes
explicitly; a present dispatcher is not evidence that the CLI reaches it.

### Previews are not injection sinks

A preview script that substitutes the selected record into shell program text,
such as `cmd={2}`, and calls `sudo -n` to gather state is both an injection
sink and an ungated privilege use. VPN renders its preview panes in Zsh before
opening fzf and addresses them by the integer row index `{n}`, so the preview
program is constant and privileged reads happen in the suite, where they can
be gated.

### Targets travel in their own field

Encoding a profile into the command token, such as `vpn-on:wg0`, forces string
surgery in the dispatcher. VPN rows carry the target in a documented fourth
field (`label|command|description|target`), so the command token stays
canonical and the entrypoint revalidates the target before dispatch.

### The command set stays constant

Rows that depend on live state make the surface host-dependent, so no fixture
could describe it. VPN keeps the command set constant and lets state change
only labels and extra per-profile rows; the contract test renders the menu
under two mocked hosts and compares the sets.

### Shared state lives below the entrypoint

Feature modules that call helpers defined in the entrypoint cannot be sourced
without it. VPN shared state lives in `vpn-state.zsh`, a module that the
entrypoint loads before the feature modules that use it.

### Editors and hooks are privilege boundaries

`sudo $EDITOR` turns an editor's shell escape into a root shell, and a hook
that interpolates a profile value into an `sh -c` body runs that value as root
on every tunnel transition. VPN edits profiles through `sudoedit`, generates
WSL DNS hooks only from values validated as an IP list, and refuses anything
else: escaping is the wrong tool when a strict format is available.

`wg-quick` also runs `PreUp`, `PostUp`, `PreDown`, and `PostDown` copied
verbatim from an imported profile. Import refuses all four directives and any
NUL or control byte, and accepts only a private, singly linked, bounded source
owned by the current user. A user who has reviewed a hook adds it afterward
with `vpn-config-edit`.

The menu follows the normative workflow order: read-only status first,
connection actions next, profile workflows after that, and maintenance last.
Per-profile rows begin with `Connect` or `Disconnect`, unsafe profile-directory
state is explicit, and missing command-specific tools are visible without
hiding unrelated actions.

## Environment suite findings

### Environment files are data, not shell input

Sourcing or expanding dotenv or profile bytes executes untrusted text, and a
`chpwd` hook that loads them treats entering a directory as authorization to
import its environment. The Environment suite reads no profile files,
persists no state, and registers no shell hook. Its dotenv check parses a
project's dotenv file and example as bounded data, reports key names only,
and never loads either file into the shell. It inspects exported variables
with mandatory masking and changes `PATH` only through an explicit, confirmed
deduplication; see [`env-menu.md`](env-menu.md).

## Change rule

Change one suite at a time in reviewable stages, keep its focused tests green,
and amend the canonical documents with any new lesson before the next suite
changes. A suite change is complete only when it passes the checklists in
[`development.md`](development.md), [`menu-spec.md`](menu-spec.md),
[`headers.md`](headers.md), and [`testing.md`](testing.md).
