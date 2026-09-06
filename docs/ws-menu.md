# Workspace suite contract

This document is the public contract and current assurance record for the
`ws` suite. It freezes the 15-command surface and defines loading, direct
routing, completion, workspace boundaries, menu behavior, repository and SSH
safety, and the remaining migration work.

The general engineering contract is in [`development.md`](development.md), the
interactive UI contract is in [`menu-spec.md`](menu-spec.md), and the file
conventions are in [`headers.md`](headers.md). Those documents take precedence
where this implementation still has a recorded legacy gap.

Audit and hardening baseline: 2026-07-26.

## Menu presentation

The command menu uses an 80% height and label-only rows. A four-line pane below
the list shows the selected command and description; sections show only their
description. `Ctrl-/` toggles details. Workspace context appears above
`Type to filter | Enter run | Esc cancel | Ctrl-/ details`. Repository inspection
precedes creation and synchronization. Content pickers keep their own fields,
selection modes, and previews.

## Implementation status

The Workspace hardening pass is implemented:

- the public surface is frozen by a checked-in fixture;
- the entrypoint has an explicit direct router and dispatcher;
- every public command parses `-h|--help` and rejects unknown options and
  excess operands with status `2` before any dependency or host probe;
- lazy and eager loading expose all 15 commands;
- the loader uses one source-derived module root and does not execute an
  arbitrary argument when run as a file;
- every picker is synchronous, remains in the terminal foreground, captures
  its result privately, and treats cancellation as success;
- workspace roots and identities are validated before creation or deletion;
- feature-command UI is isolated on stderr, while internal record helpers keep
  stdout for data;
- displayed repository remotes redact URL credentials;
- clone failures propagate;
- `ws-sync` freezes and revalidates branch, HEAD, upstream, and upstream-object
  state, and restores only the stash object created by that invocation;
- SSH tests are non-interactive and bounded;
- key rotation stages the replacement before backing up the active pair and
  rolls back a failed installation;
- `ws-remove` fingerprints configuration content and metadata, publishes
  rewrites atomically, and quarantines the exact workspace before deletion;
- `ws-migrate` fingerprints both directory boundaries and repository identities
  and refuses cross-filesystem moves; and
- `ws-autoclean` revalidates stale state, object IDs, and linked worktrees and
  deletes through an expected-object compare-and-delete.

This is not yet a claim that every feature command satisfies the complete
parser, planning, bounded-inventory, and atomic multi-file transaction
requirements in `development.md`. The remaining gaps are explicit below.

## Ownership

The Workspace suite owns:

- workspace directories and the `platform/identity` naming model;
- workspace-local Git identity files;
- workspace SSH keys and host aliases;
- Git `includeIf` routing for repositories below a workspace;
- placing, inspecting, synchronizing, migrating, and removing repositories as
  members of a workspace; and
- workspace-wide stale-branch maintenance.

It does not own:

| Domain | Owner | Relationship |
| --- | --- | --- |
| General repository and GitHub workflows | `git` (`git-menu`) | Workspace orchestration uses a documented legacy identity coupling; ordinary branch, commit, tag, issue, and pull-request workflows remain in `git` |
| Directory navigation | User-local compatibility names `zdir` / `wsj` | The core loader recognizes an ignored local implementation, but none ships with the release or belongs to the 15-command Workspace suite |
| Installing `git`, `ssh`, `ssh-keygen`, `fzf`, or `gh` | `zdx-doctor` | Workspace commands report missing capabilities and never install them |
| General network diagnostics | `net` (`net-menu`) | Workspace probes are limited to configured Git hosts and SSH routes |

`ws-common.zsh` currently sources the exact sibling `git-common.zsh`. This is
the sole cross-suite exception recorded in [`suites.md`](suites.md). New
Workspace work must not add another Git-private dependency; shared identity
primitives should move to a deliberately owned domain in a later refactor.

## Architecture and load contract

```text
functions/ws-menu.zsh          exact-root loader, direct router, menu model
  -> functions/ws-common.zsh   validation, rows, fzf, dependencies, dispatch
    -> functions/ws/ws-create.zsh     workspace creation
    -> functions/ws/ws-info.zsh       auth, list, info, doctor
    -> functions/ws/ws-clone.zsh      single and batch clone
    -> functions/ws/ws-sync.zsh       sync and repository inspection
    -> functions/ws/ws-keys.zsh       key display, rotation, SSH test
    -> functions/ws/ws-danger.zsh     migration and workspace removal
    -> functions/ws/ws-autoclean.zsh  stale-branch cleanup
```

The entrypoint derives its module root from `${(%):-%x}` and accepts only
readable, non-symlink common and feature files below that root. It sets
`_WS_MENU_SOURCED` only after every required module loads successfully. A
missing or failed module therefore returns non-zero without leaving a false
loaded sentinel.

Sourcing defines functions only. Executing `functions/ws-menu.zsh` routes its
arguments through `ws-menu`; it never treats the first argument as an arbitrary
executable.

The core lazy map registers `ws-menu` and every frozen public command to the
same entrypoint. A direct command therefore works from a cold shell:

```zsh
ws-menu ws-list
ws-list
```

Both forms load the same functions. Scripts should prefer
`ws-menu <command> [arguments...]` because it makes the owning router explicit.

## Frozen public command surface

`test/fixtures/ws-public-commands.tsv` is the machine-readable inventory.
`test/ws_contract.bats` proves parity among the fixture, functions, dispatcher,
top-level menu, help, and completion command entries.

### Inspection and authentication

| Command | Class | Accepted input | Behavior |
| --- | --- | --- | --- |
| `ws-auth` | network read | none | Check key presence, GitHub CLI authentication when `gh` exists, and each workspace SSH route |
| `ws-list` | read-only | none | Display configured workspaces, identities, repository counts, key state, and optional GitHub CLI state |
| `ws-info` | read-only | interactive workspace selection | Display one workspace's path, identity, key fingerprint, routing, and redacted repository remotes |
| `ws-doctor` | network read | none | Diagnose workspace files, permissions, SSH aliases, Git includes, and repository remote alignment |
| `ws-repos` | read-only | interactive workspace selection | Display branch, dirty count, and redacted origin for each repository |

### Workspace and repository lifecycle

| Command | Class | Accepted input | Behavior |
| --- | --- | --- | --- |
| `ws-create` | mutating | interactive only | Create one GitHub or GitLab workspace, identity file, SSH key, SSH alias, and Git `includeIf` route |
| `ws-clone [REPOSITORY]` | mutating | optional `owner/name`, HTTPS URL, or SSH URL | Normalize one repository and clone it through the selected workspace alias |
| `ws-clone-multi [REPOSITORY...]` | multi-target mutation | zero or more repository operands | Clone a reviewed list sequentially; with no operands, paste lines or select GitHub repositories with `gh` |
| `ws-sync` | multi-repository mutation | interactive workspace resolution | Fetch every repository, revalidate frozen branch/upstream object state, fast-forward clean behind branches, and offer invocation-owned stash handling for dirty repositories |
| `ws-migrate` | destructive migration | interactive only | Select direct-child repositories in one source directory, move them into a workspace, and optionally rewrite origins to the workspace alias |

### SSH keys and destructive maintenance

| Command | Class | Accepted input | Behavior |
| --- | --- | --- | --- |
| `ws-show-key` | read-only | interactive workspace selection | Display and optionally copy the public key; never display the private key |
| `ws-rotate-key` | destructive | interactive workspace selection | Back up the current keypair, generate a replacement, and optionally prune older backups |
| `ws-test` | network read | interactive workspace selection | Test one SSH alias in batch mode with strict host-key checking |
| `ws-autoclean` | destructive | interactive workspace resolution | Fetch/prune, select merged or gone branches, and compare-and-delete the exact selected branch object IDs |
| `ws-remove [--dry-run] [--yes] [platform/identity]` | destructive | zero or one workspace plus the two safety flags | Atomically remove the exact SSH block and Git include, then quarantine and delete the revalidated workspace |

No other suite-owned flags are implemented. In particular, this baseline does
not invent `--dry-run` or `--yes` for migration, key rotation, synchronization,
or branch cleanup. Those missing controls are migration work, not hidden
options.

## Direct router and exit statuses

`ws-menu` accepts:

```text
ws-menu
ws-menu -h|--help
ws-menu <command> [arguments...]
```

The router parses help and top-level options before dependency or workspace
probes. It rejects an unknown option or command with status `2`, forwards the
remaining argument array without flattening it, and times direct and
interactive dispatch exactly once under `ws:<command>`.

The shared status meanings are:

| Status | Meaning |
| --- | --- |
| `0` | Success, deliberate picker cancellation, declined confirmation, or documented no-op |
| `1` | Operational failure, missing dependency, failed network or Git operation, or refused unsafe state |
| `2` | Invalid top-level arguments, unknown dispatch token, or malformed workspace/repository input |
| `130`, `143` | Interrupted clone or migration origin operation; remaining batch targets are not attempted |

An underlying clone, batch clone, migration, synchronization, SSH, or removal
failure must not be converted into success. A multi-target operation returns
non-zero when any required item fails, while preserving successful work and
reporting the partial result.

Every public command parses a sole `-h|--help` before any dependency,
base-directory, or host probe, writes one usage line plus a one-sentence
description to stderr, and rejects unknown options and unexpected operands
with status `2`. `ws-clone` accepts at most one repository operand and
`ws-clone-multi` accepts any number; operands may not begin with a dash,
matching the repository grammar. `ws-menu --help` remains the canonical
command inventory, and only the operands and flags documented above exist.

## Completion contract

`completions/_ws-menu` binds `#compdef` to `ws-menu` and all 15 direct commands.
Its subcommand descriptions must remain identical to the fixture and dispatcher
surface.

Current completion supports:

- `-h` and `--help` for `ws-menu` and for every direct command;
- all 15 direct subcommands; and
- repository operands for `ws-clone` and `ws-clone-multi`; and
- contextual `--dry-run`, `-y`/`--yes`, `--help`, and validated workspace
  candidates for `ws-remove`.

No completion entry may advertise an unimplemented safety flag.

## Menu and fzf contract

The top-level menu uses the canonical three-field record:

```text
label|command|description
```

`_ws_menu_section` and `_ws_menu_entry` reject empty required values and any
pipe, newline, carriage return, or NUL. Command fields must match the canonical
`ws-*` token grammar. Static ordering follows the workflow: inspection first,
workspace and repository lifecycle next, SSH keys after that, and destructive
maintenance last.

Only the label is visible. The preview program is constant and displays the
fixed command and description fields; it never compiles a path, repository URL,
key, or selected command into shell program text. The selected record must
belong to the invocation's row snapshot before its command field is dispatched.

Every Workspace picker runs through `_ws_fzf_capture`. Record producers may
use process substitution, but `fzf` itself runs synchronously in the shell's
foreground process group and never inside command substitution or a background
job. This is required because a backgrounded `fzf` that writes terminal control
output is suspended by the shell with `suspended (tty output)`.

The helper redirects selection output into a validated mode-`600`, singly
linked file below a validated mode-`700` invocation directory. It bounds the
result at 4 MiB, reads it through a no-follow descriptor, removes the exact file
and directory in an `always` block, returns the unchanged `fzf` status, and
places the selection in `REPLY`. Multi-select output and caller-specific
options, including delimiters and visible fields, therefore use the same
foreground path without contaminating command stdout.

Picker cancellation rules are exact:

- `fzf` status `1` or `130`, an empty result, or a selected section returns `0`;
- no command is dispatched after cancellation; and
- any other `fzf` failure reports the status and returns non-zero.

The plain header advertises only active keys:

```text
Type to filter | Enter run | Esc cancel | Ctrl-/ details
```

## Streams, color, and data

At the entrypoint boundary:

- `ws-menu --help`, diagnostics, timers, prompts, and errors use `stderr`;
- menu rows are internal machine-readable stdout consumed by the picker;
- cancellation leaves public stdout empty; and
- setting `NO_COLOR`, using `TERM=dumb`, or redirecting stderr disables
  Workspace color through the shared Git compatibility theme.

The feature modules remain primarily human-facing interactive workflows. Their
UI is emitted on stderr, and they do not currently expose a documented stable
data-output mode. Internal helpers may use stdout for records consumed within
the suite; those records are not a public interface.

## Workspace identity and path boundary

`WS_BASE_DIR` defaults to `$HOME/workspaces`. `_ws_validate_base_dir` requires
it to be:

- non-empty and absolute;
- free of control characters, `.` components, and `..` traversal;
- neither `/` nor the home directory itself;
- a canonical path with no symbolic-link component; and
- a real non-symlink directory when it already exists.

The validation runs before `ws-create` opens `fzf` and before `ws-remove`
selects or deletes anything.

A workspace identifier has exactly two fields:

```text
github/identity
gitlab/identity
```

The platform is allowlisted. The identity is at most 64 characters, begins
with an alphanumeric, and then contains only letters, numbers, dots,
underscores, or dashes. Empty values, extra path components, leading options,
`.` and `..` are refused. `_ws_resolve_workspace` proves the resulting
canonical path remains a non-symlink descendant of the validated base.

The managed layout is:

```text
$WS_BASE_DIR/<platform>/<identity>/
├── .gitconfig
├── .ssh/
│   ├── id_ed25519
│   ├── id_ed25519.pub
│   └── id_ed25519.bak.<timestamp>    optional rotation backups
├── .ws-hostname                     optional custom GitLab host
└── <repository>/                    direct-child repositories
```

Workspace creation also manages one marked Host block in `~/.ssh/config` and
one exact `includeIf.gitdir:<workspace>/.path` entry in `~/.gitconfig`.

## Credentials and remote display

Private SSH key contents are never part of menu rows, remote listings, or
authentication summaries. `ws-show-key` intentionally displays only the
public key and may send that public value to `clip.exe`, `xclip`, or `pbcopy`.

Every audited remote display in `ws-info`, `ws-doctor`, `ws-repos`, and
`ws-migrate` passes through `_ws_redact_remote_url`. URL user information is
replaced, and query strings or fragments are removed before display. Clone
errors may show a public key as the recovery step, but never the private key.

The workspace `.gitconfig`, `.ssh` directory, private key, SSH config, and
global Git config are permission-sensitive executable or authentication state.
Creation applies mode `700` to `.ssh`, `600` to private keys and configuration
files it creates, and `644` to public keys. Removal refuses a symlinked or
foreign-owned `~/.ssh/config` or `~/.gitconfig`.

## Clone and repository-input safety

`ws-clone` and `ws-clone-multi` normalize an HTTPS URL, SSH URL, or direct
operand to `owner/repository`. The normalized value:

- contains at least two non-empty slash-separated components;
- contains only letters, numbers, dots, underscores, and dashes per component;
- contains no `.` or `..` component, control, record delimiter, or leading
  option marker; and
- is converted to the fixed
  `git@<validated-workspace-alias>:<owner/repository>.git` form.

The destination is a direct child of the validated workspace. An existing
directory is not overwritten. Batch clone presents the repository set, asks
once, runs sequentially, counts cloned, skipped, and failed repositories, and
returns non-zero if any clone failed. Invalid inputs are reported and skipped;
if no valid repository remains, the command fails.

A failed clone may leave a partial destination, which is retained for manual
inspection. After each clone attempt, the workspace device, inode, mode, and
owner must still match before accepting its changed child-directory link
count. This lets later independent clones run after ordinary failure while
rejecting workspace replacement or permission changes. Full directory
fingerprints remain mandatory between attempts. Interruptions (`130` or `143`)
stop later clones, preserve the status, and report unattempted entries.

Cloning retrieves repository content but does not execute it. The user remains
responsible for trusting the selected origin before running code, hooks,
installers, or project tasks from the clone.

## Synchronization and stash ownership

`ws-sync` fetches every direct-child repository and records the current branch,
HEAD object ID, upstream ref, and fetched upstream object ID. It fast-forwards
only when that exact snapshot still matches, the branch is behind without local
commits, and the worktree is clean. The operation uses
`git merge --ff-only -- <fetched-upstream-object-id>` rather than the mutable
upstream ref or a second network pull, then verifies that HEAD reached the
planned upstream object. Detached, upstream-less, dirty, and ahead branches are
not automatically fast-forwarded. Diverged repositories are left for manual
resolution.

For a dirty repository, the optional stash workflow tags
`git stash push --include-untracked` with an invocation-unique marker and
resolves exactly one matching stash object ID. Repository identity and the
branch/upstream snapshot are checked before and after stashing, around the
fast-forward, and before restoration. Restoration applies that exact object ID
with `--index`.

It never calls a generic `git stash pop` and deliberately does not run
`git stash drop`: stash selectors are positional and can race another process.
The exact invocation-owned recovery stash therefore remains after a successful
apply as well as after a conflict. If stash ownership cannot be proved, no
merge or restore is attempted and the unique marker is reported for inspection.

## SSH routing and key safety

Workspace aliases are fixed as `<platform>-<identity>`. GitHub maps to
`github.com`; GitLab uses `gitlab.com` unless a validated custom hostname is
stored in `.ws-hostname`.

`ws-create` generates an Ed25519 key or imports one selected from owned,
non-symlink private keys directly below `~/.ssh`. It copies the key into the
workspace and derives a public key when necessary. The original imported key
is retained. Picker cancellation occurs before workspace creation, while an
unexpected picker failure is reported as an operational error instead of
being treated as cancellation.

Existing SSH and global Git configuration files must pass the owned-file
fingerprint checks. Each changed configuration is staged in a private
same-directory file, revalidated with the workspace immediately before
publication, and replaced atomically. These individual publications still do
not form one rollback-capable transaction with all newly created workspace
files.

Before creating workspace files, `ws-create` passively checks the prospective
SSH alias. A compatible explicit Host block can be reused only when its
hostname, Git user, single identity file, and `IdentitiesOnly yes` match the
workspace. Conflicting or ambiguous routing fails before creation. The bounded
parser handles indentation, keyword case, quoted values, multiple Host names,
and wildcard/negated patterns; it does not execute SSH or evaluate `Match exec`.
`Include`, `Match`, unsupported dynamic routing, and oversized configuration
require manual review. The configuration and SSH-directory fingerprints are
rechecked before creation and publication. Generated identity paths are quoted
and escape SSH token syntax so spaces and literal percent signs are retained.
This check reads only `~/.ssh/config`; it does not evaluate
`/etc/ssh/ssh_config` or the effective configuration used by SSH. System routing
and connection-specific options remain a manual verification boundary.

`ws-test` uses:

- `BatchMode=yes`;
- `NumberOfPasswordPrompts=0`;
- `StrictHostKeyChecking=yes`; and
- `ConnectTimeout=WS_SSH_CONNECT_TIMEOUT`.

`WS_SSH_CONNECT_TIMEOUT` defaults to `10` and accepts only integers from 1
through 60. A missing known-host entry is therefore a visible failure rather
than an automatic host-key trust decision.

`ws-auth` tests every alias with batch mode, one connection attempt, a
three-second SSH connection deadline, and a five-second whole-probe deadline.
`ws-test` applies a whole-probe deadline five seconds beyond its configured
connection deadline. GNU `timeout` or `gtimeout` is used when available; the
Zsh fallback owns, terminates, and reaps the exact child tree. Probe output is
captured privately and capped at 4 KiB.

Key rotation asks before replacing the pair, generates and validates a new
Ed25519 pair in a private workspace-local staging directory, and only then
moves the old pair to a unique timestamped backup. A failed installation or
permission update attempts to restore the prior active pair. When more than two
complete safe backup pairs exist, a second confirmation can remove all but the
most recent pair; incomplete or unsafe backups are never pruned automatically.

## Removal, migration, and branch cleanup

### Workspace removal

`ws-remove --dry-run [platform/identity]` shows:

- the exact SSH Host alias block;
- the exact Git `includeIf` entry;
- the canonical workspace directory; and
- the count of direct-child repositories that will be deleted.

Without `--yes`, the interactive command requires the exact workspace name.
`--yes` bypasses only that typed prompt. It does not bypass base validation,
workspace resolution, configuration-file ownership checks, or revalidation.

The workspace and platform directories are frozen by device, inode, ownership,
mode, and link metadata. Existing SSH and global Git configuration files are
frozen by that metadata plus a bounded content checksum and are revalidated
during each staged rewrite. SSH and Git configuration updates use private
same-directory mode-`600` temporaries and atomic rename; Git removal addresses
the exact `includeIf` key and refuses parser failure instead of publishing an
uncertain result or deleting the workspace.

Immediately before deletion, the directory fingerprints are checked again.
The workspace is first renamed to an unpredictable quarantine sibling, its
identity is verified there, and only that quarantined path is passed to
`rm -rf --`. A deletion failure restores remaining data to the original name
when safe; otherwise it reports the quarantine for recovery. The parent
platform directory is removed only with `rmdir` after it is proven empty.

### Repository migration

`ws-migrate` accepts only an interactive, absolute, canonical, owned,
non-symlink source directory that is neither `/` nor the home directory.
Candidates are direct-child repositories with a real non-symlink `.git`
directory and names that pass the repository-name grammar. Source, target, each
repository, and each `.git` directory are fingerprinted; a selected row must
belong to the discovery snapshot, duplicates are refused, and identities are
revalidated around each move.

The source and workspace must be on the same filesystem. A device mismatch is
refused before any repository moves, so `mv` remains a same-filesystem rename.
An existing destination is skipped. Optional origin rewriting uses a normalized
repository path and the validated workspace alias, and the old URL is redacted
in the report. A remote rewrite failure does not move the repository back; it
is reported as a partial failure. Origin inspection distinguishes a confirmed
missing remote from a failed Git query. After a rewrite, the effective URL must
match the intended workspace URL before success is reported. Ordinary failures
allow independent later repositories to proceed; origin inspection or rewrite
interruption (`130` or `143`) stops later moves and preserves that status.
Deleting an emptied source is a separate
confirmation and uses only `rmdir`.

### Stale-branch cleanup

`ws-autoclean` protects the current branch, the detected default, `main`, and
`master`. It offers only merged or upstream-gone branches and freezes the
repository identity and exact selected branch object ID. After confirmation it
revalidates repository identity, current/default/stale state, the object ID,
and every linked worktree before deleting with:

```text
git update-ref -d refs/heads/<branch> <expected-object-id>
```

That compare-and-delete is atomic with respect to a concurrent branch repoint.
The command checks linked worktrees again afterwards. If a branch became active
during the deletion window, it attempts to restore the exact prior object only
while the ref remains absent and reports failure either way. Every scan,
revalidation, deletion, or restoration uncertainty makes the aggregate fail.

Migration, key rotation, stale-branch cleanup, and the optional broad sync
actions do not yet implement uniform `--dry-run` and `--yes` controls. Those
limitations remain security-relevant residual gaps.

## Configuration

Set these values in `~/.config/zdx/config.zsh`:

| Variable | Default | Contract |
| --- | --- | --- |
| `WS_BASE_DIR` | `$HOME/workspaces` | Absolute, canonical, non-symlink managed workspace root; cannot be `/` or the home directory |
| `WS_SSH_CONNECT_TIMEOUT` | `10` | SSH connection deadline for `ws-test`; integer `1`–`60` |

## Test coverage

| File | Covered boundary |
| --- | --- |
| `ws_contract.bats` | Frozen 15-command fixture; function, menu, help, dispatcher, completion, cancellation, timing, and argument-forwarding parity |
| `ws_interface.bats` | Stderr-only entrypoint UI, invalid statuses, per-command help and unknown-option parsers before probes, validated three-field rows, fzf options, private result capture, exact statuses and cleanup, standalone exact-root source, and lazy/eager parity |
| `ws_safety.bats` | Arbitrary-command execution regression, Git-before-Workspace loading, unsafe roots, creation-picker failure, exact and quarantined removal, configuration parse and replacement failure, clone status propagation and collisions, exact stash preservation, frozen-upstream ref races, synchronization inspection failure, migration and repository-link boundaries, compare-and-delete OID races, remote redaction, key rollback, bounded SSH, and top-level plus nested foreground terminal ownership |
| `ws_migration_recovery.bats` | Absent versus unreadable origins, verified remote rewrites, retained moved repositories after partial failure, preserved interruptions, and independent later moves |
| `ws_clone_recovery.bats` | Retained partial clones, independent continuation, stable workspace identity, replacement and mode races, preserved interruptions, and destination collisions |
| `ws_create_recovery.bats` | Passive alias conflicts and compatibility, exact identity fields, wildcard defaults, literal SSH values and quoted paths, unsupported dynamic routing, and configuration changes before publication |
| `git_ws.bats` | Legacy Git/Workspace compatibility without expanding the cross-suite dependency |

The focused Workspace tests use disposable home and workspace roots. Network,
GitHub CLI, SSH, `fzf`, and targeted failure paths are mocked. They do not
establish behavior against a real GitHub or GitLab account, a real SSH agent,
a real cross-filesystem mount, or a hostile same-user process.

## Residual gaps

1. **Broad mutations need uniform controls.** `ws-migrate`, `ws-autoclean`,
   `ws-rotate-key`, and the optional broad parts of `ws-sync` need exact dry-run
   plans and explicit non-interactive authorization. Current legacy prompt
   behavior does not yet distinguish a decline from an unavailable terminal
   for every command.
2. **Workspace creation remains a partial transaction.** A late failure can
   leave some workspace files or one routing configuration update published.
   SSH and global Git configuration creation do not yet form one
   fingerprinted, atomic, rollback-capable transaction.
3. **Remote rewriting has an external transaction limit.** Same-filesystem
   repository placement is completed before the optional external Git remote
   rewrite. A rewrite failure leaves the repository moved, reports partial
   failure, and has no generic rollback.
4. **Inventories are not explicitly bounded.** Workspace, repository, branch,
   GitHub organization, and SSH backup scans need count and byte limits for
   hostile or unusually large local state.
5. **The Git coupling remains.** Workspace still inherits compatibility
   helpers and theme behavior from `git-common.zsh`; the eventual shared
   identity-domain extraction is not complete.
6. **No real-host acceptance is recorded.** Focused mocks do not replace live
   GitHub/GitLab, WSL clipboard, macOS permission, or real SSH verification.

## Maintenance triggers

Update this document when:

- a public command, operand, or flag changes;
- a command moves between Workspace and Git ownership;
- the `platform/identity` grammar or `WS_BASE_DIR` boundary changes;
- SSH key, Host block, Git include, or repository layout changes;
- a remote URL or credential-bearing display surface is added;
- clone, stash, migration, branch deletion, or removal semantics change;
- completion, direct routing, menu records, preview, or cancellation changes;
- a residual gap is closed or a new threat appears; or
- a real-host verification is recorded.
