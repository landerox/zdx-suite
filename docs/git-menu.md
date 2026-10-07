# Git suite contract

This document defines the public contract for the Git suite: its frozen
21-command surface, exact routing, completion grammar, mutation plans, remote
leases, structured data, and GitHub safety model. The suite supports Linux,
WSL, and macOS; see [Platform notes](#platform-notes).

The authoritative general contracts are
[`development.md`](development.md), [`menu-spec.md`](menu-spec.md),
[`headers.md`](headers.md), and [`testing.md`](testing.md). Ownership boundaries
are defined in [`suites.md`](suites.md), and cross-suite threats are tracked in
[`security-assessment.md`](security-assessment.md). Those documents take
precedence if this contract conflicts with them.

## Menu presentation and capture

The top-level command menu uses an 80% height and label-only rows, with a
four-line details pane below the list. `Ctrl-/` toggles details. Section rows
show their description without an executable command. Context appears above
`Type to filter | Enter run | Esc cancel | Ctrl-/ details`.

The top-level picker runs through Git's private `_git_fzf_capture` helper in
the foreground. It captures selection stdout in an owned mode-600 result file,
checks its identity and 64 KiB read limit, and removes only the unchanged
invocation-owned file. Non-zero picker status with data is refused. A complete
selected row must match the current snapshot before its command is dispatched.
`test/git_menu_capture.bats` covers forged rows, failed selections, private
capture cleanup, changed objects, oversized output, and a foreground PTY.

The local-change pickers (the `git-unstage`, `git-discard`, and `git-stash`
record pickers and the `git-amend`, stash-action, and `git-pull` mode dialogs)
and the branch pickers (the `git-switch` branch picker and change dialog and
the `git-recover` commit picker) use the same foreground capture through
`_git_select_ids` and `_git_select_action`, and they also require the
complete selected row to be in their snapshot. A large multi-selection that exceeds the 64 KiB result limit
fails closed; the first-row all-files choices and `--all` cover broad
selections. The other nested Git resource and decision pickers (tag,
pull-request, identity, push, branch-cleanup, reset-mode, and the No/Yes
confirmation) capture their selection through command substitution and are
not covered by the private-file assurance. They still use typed records,
selection checks, and authorization after the picker exits.

## Ownership

The Git suite owns:

- repository status and authentication context;
- local changes: unstaging files, stashes, amending the last commit, planned
  discard of selected files or of every uncommitted change, and undo of the
  last commit;
- switching to an existing local branch or a remote-tracking branch, and
  restoring a commit that no branch or tag reaches as a new branch;
- branch synchronization (fetch, pull, and push) and merged-branch cleanup;
- tag creation, verification, publication, and deletion;
- configured Git identity profiles applied locally or globally, a read-only
  check of a workspace repository against its profile, and the opt-in
  identity guard that runs that check on a directory change;
- GitHub pull-request creation and checkout performed through authenticated
  `gh`;
- the `git-menu` discovery layer and the direct routing of its canonical
  commands.

Staging, new commits, history and diff browsing, branch creation and
integration, GitHub issues, and repository creation are not provided; use Git
or `gh` directly for them. Branch creation has two narrow exceptions:
`git-switch` creates the local branch that tracks a chosen remote-tracking
branch of the same name, and `git-recover` creates a new branch at a commit
that no branch or tag reaches. `git-recover` lists only such unreachable
commits; it is not a history browser.

It does not own:

| Domain | Owner | Git-suite boundary |
| --- | --- | --- |
| Cross-suite dependency installation | `zdx-doctor` | Git reports a missing dependency and a safe installation direction |
| Host Git installation and updates | `sys` | Git checks for the executable but does not install or update it |
| Core timing, telemetry, and shared fzf theme | core runtime | Git consumes optional documented services and defines no competing global shim |

`git-auth` reports identity, remote alignment, and authentication state. It
MUST NOT display authentication tokens, private-key contents, credential
helpers' secrets, or unmasked sensitive configuration.

When the current directory lies inside an existing
`$WS_BASE_DIR/<platform>/<identity>` layout (`WS_BASE_DIR` defaults to
`~/workspaces`), `git-auth` reads that layout only to display a workspace SSH
host alias, hostname, and key fingerprint. It uses the platform and identity
directory names, an optional `.ws-hostname` file, and `.ssh/id_ed25519.pub`.
`git-identity-check` and `git-status --json` read the platform and identity
directory names of a repository root strictly below that layout. Git never
creates, changes, or removes workspace directories or their keys.

The Workspace suite owns that layout: navigation with `ws-jump`, clone
placement with `ws-clone`, and a multi-repository `ws-status`
([`ws-menu.md`](ws-menu.md)). Both suites follow the same convention: the SSH
alias of a workspace is `<platform>-<identity>`, and its host is `github.com`
for the `github` platform, otherwise the first line of `.ws-hostname`,
otherwise `gitlab.com`. After a clone, `ws-clone` applies a matching profile
only through `git-menu git-identity-switcher --switch NAME local`, so this
suite remains the only writer of identity configuration.

## Architecture

```text
functions/git-menu.zsh           loader, public router, top-level menu model
  -> functions/git-common.zsh    Git-private UI, records, dependencies, dispatch
    -> functions/git/git-changes.zsh
    -> functions/git/git-stash.zsh
    -> functions/git/git-branch.zsh   uses git-stash.zsh helpers at run time
    -> functions/git/git-sync.zsh
    -> functions/git/git-tags.zsh
    -> functions/git/git-clean.zsh
    -> functions/git/git-pr.zsh
    -> functions/git/git-identity.zsh
    -> functions/git/git-repo.zsh
```

The entrypoint derives one trusted module root from its own source path. Every
mandatory file must be a readable, non-symlink regular file whose resolved path
is the exact expected path below that root. There is no fallback to an
unrelated `$HOME/.oh-my-zsh` tree. A source failure names the exact module on
stderr, preserves its status, removes temporary loader state, and leaves
`_GIT_MENU_SOURCED` unset so loading can be retried.

Source files define state and functions only. They do not probe a repository,
run Git or `gh`, open fzf, prompt, mutate configuration, or perform network
access. Each component sets its idempotency sentinel only after its complete
definition succeeds. Re-sourcing a completed component is silent.

Git-private helpers use `_git_*`, and Git defines no `_tk_*` function. The
optional core `_timed` and `_tk_fzf_color_opts` services are consumed through
Git-owned wrappers so standalone suite sourcing remains functional without
defining global substitutes.

Only `git-menu` is guaranteed as a cold-shell lazy entrypoint. Individual
public functions are available after the suite loads, or immediately under
eager loading. Scripts SHOULD use `git-menu <command> [arguments...]`.

## Frozen command inventory

The canonical surface contains exactly 21 command tokens. The highest-effect
classification controls review priority; a command is classified by its
most dangerous selectable action, not its most common action.

| Command | Owning module | Highest effect | Required context |
| --- | --- | --- | --- |
| `git-auth` | `git-common.zsh` | read-only | repository |
| `git-status` | `git/git-repo.zsh` | read-only | repository |
| `git-unstage` | `git/git-changes.zsh` | mutating | repository |
| `git-stash` | `git/git-stash.zsh` | destructive | repository |
| `git-amend` | `git/git-changes.zsh` | destructive | repository |
| `git-switch` | `git/git-branch.zsh` | mutating | repository |
| `git-recover` | `git/git-branch.zsh` | mutating | repository |
| `git-pull` | `git/git-sync.zsh` | destructive | repository and remote |
| `git-push` | `git/git-sync.zsh` | destructive | repository and remote |
| `git-tag-create` | `git/git-tags.zsh` | mutating | repository; remote is optional |
| `git-tag-verify` | `git/git-tags.zsh` | read-only | repository |
| `git-tag-push` | `git/git-tags.zsh` | mutating | repository and remote |
| `git-pr-create` | `git/git-pr.zsh` | mutating | repository and authenticated `gh` |
| `git-pr-checkout` | `git/git-pr.zsh` | mutating | repository and authenticated `gh` |
| `git-identity-check` | `git/git-identity.zsh` | read-only | repository |
| `git-identity-switcher` | `git/git-identity.zsh` | mutating | Git configuration; repository only for local scope |
| `git-discard` | `git/git-changes.zsh` | destructive | repository |
| `git-undo-commit` | `git/git-changes.zsh` | destructive | repository |
| `git-tag-delete` | `git/git-tags.zsh` | destructive | repository; remote is optional |
| `clean-branches` | `git/git-clean.zsh` | destructive | repository |
| `clean-remote-merged` | `git/git-clean.zsh` | destructive | repository and remote |

The canonical inventory is
`test/fixtures/git-public-commands.tsv`, with one record per row:

```text
command<TAB>owning-module<TAB>risk<TAB>current-capability
```

Risk is one of `read-only`, `mutating`, `destructive`, or the reserved
`remote-code` class. `current-capability` names the narrowest base condition
for opening the command; an optional remote or GitHub action still performs its
own narrower check.

That fixture is non-executable data. Contract tests compare it with every public
surface so this document does not become a second unchecked allowlist.

## Public-surface invariant

These sets MUST contain the same 21 canonical tokens:

1. records in `test/fixtures/git-public-commands.tsv`;
2. public functions loaded from their declared modules;
3. non-sentinel command fields in the top-level menu;
4. fixed arms in `_git_dispatch`;
5. commands named by `git-menu --help`;
6. nested entries in `completions/_git-menu`;
7. direct completion bindings for every public command.

An addition, rename, compatibility alias, or removal updates the fixture,
function, menu, dispatcher, help, nested and direct completion, focused tests,
and [`user-guide.md`](user-guide.md) in one coherent change.

A command is not complete merely because it can be selected interactively. Its
direct interface, status behavior, stream contract, safety boundary, tests, and
documentation must agree.

## Direct and nested routing contract

`git-menu` has three top-level modes:

| Invocation | Required behavior |
| --- | --- |
| `git-menu` | Open the single-select top-level menu |
| `git-menu -h` or `git-menu --help` | Write concise usage to stderr and return `0` without runtime probes |
| `git-menu <command> [arguments...]` | Dispatch the fixed command and forward every remaining argument exactly |

Unknown top-level options fail closed with status `2`. Unknown command tokens
also return `2`. Help is parsed before repository, dependency, authentication,
remote, or fzf checks.

The router shifts the canonical token once and calls:

```zsh
_git_timed "git:$command_name" \
  _git_dispatch "$command_name" "$@"
```

The dispatcher shifts once and uses an explicit `case` whose arms call fixed
functions with `"$@"`. It does not construct function names, invoke an
allowlist element indirectly, flatten arguments, or use `eval`. Each public
command parses help and invalid input before performing its own narrow
dependency, repository, authentication, or remote checks.

Nested and loaded direct forms are behaviorally equivalent:

```text
git-menu git-identity-switcher --status
git-identity-switcher --status
```

Both forms preserve empty arguments, whitespace, leading dashes after the
command token, underlying status, and stream placement. Timing is applied
exactly once in the nested route and preserves the dispatched status.

Every public command provides `-h` and `--help`, parses options before runtime
checks, and rejects unknown or extra arguments with status `2`. Each help
contract states whether the command is interactive-only, accepts an exact
direct target, or supports a complete non-interactive mutation plan. The
`git-identity-switcher` interface is:

```text
git-identity-switcher
git-identity-switcher --status
git-identity-switcher --switch NAME [local|global]
```

Its invalid scope, missing name, extra arguments, and unknown options return
`2`. Every remaining public interface is documented by its direct `--help`
output and rejects invalid combinations before runtime probes.

Selection-first workflows are intentionally interactive when no exact
target grammar is documented. `git-discard` and `git-unstage` select their
files, or a first all-changes row, in a picker unless `--all` is given;
reset-mode, tag, pull-request, stash, amend-action, and pull-mode pickers open
only when the corresponding target or flag is omitted. Each public command is
still directly invocable; “interactive-only” means that it requires a TTY and
`fzf`, not that the action exists only as a top-level menu binding.

Exact direct targets are available for reset mode; discarding every change;
unstaging every file; stash save, apply, pop, drop, and branch; the last
commit's subject, staged content, and author; branch switching; pull and
push; tag creation, verification, publication and deletion; merged-branch
cleanup; pull-request creation and checkout; and identity application.
`git-recover` is interactive-only: its commit picker always needs a terminal
and `fzf`. Commands that accept `--yes` still build and display the same
plan, revalidate it, and bypass only the final prompt.

`git-push` publishes branches only: the current branch, optionally with
`--set-upstream` or `--force-with-lease`, or every local branch with `--all`.
It has no tag mode: `git-push --tags` is rejected as an unknown argument with
status `2`. Tags are published with `git-tag-push`, which with `--yes` and no
tag names publishes every changed local tag with an absence lease;
`--dry-run` reviews that plan first.

The implemented non-interactive pull-request creation interface is:

```text
git-pr-create [--base BRANCH]
              [--title TEXT [--body TEXT] | --fill]
              [--draft] [--dry-run] [-y|--yes]
```

With no arguments, it retains its interactive adapter. Direct mode validates
every value before dependency or mutation work. `--fill` and `--title` are
exclusive, `--body` requires `--title`, and `--dry-run` cannot be combined
with `-y` or `--yes`.

`git-pull` without arguments opens a mode dialog whose header names the
current branch and upstream: Pull and Merge, Pull and Rebase, Pull
Fast-Forward Only, Fetch Upstream Branch, and Fetch All Branches and Prune.
Each mode still shows its exact plan before the confirmation, so the dialog
has no separate dry-run row; `git-pull --dry-run` is the direct preview.

## Local changes

The Local Changes menu section groups `git-unstage`, `git-stash`, and
`git-amend`. `git-discard` and `git-undo-commit` belong to Destructive
Maintenance. The direct grammar is:

```text
git-unstage [--dry-run|-y|--yes]
git-unstage --all [--dry-run|-y|--yes]

git-stash [--dry-run|-y|--yes]
git-stash save [-u|--include-untracked|--keep-index] [-m|--message TEXT]
               [--dry-run|-y|--yes]
git-stash apply [TARGET] [--dry-run|-y|--yes]
git-stash pop [TARGET] [--dry-run|-y|--yes]
git-stash drop TARGET... [--dry-run|-y|--yes]
git-stash branch TARGET NAME [--dry-run|-y|--yes]

git-amend [--dry-run|-y|--yes]
git-amend [-m|--message TEXT] [--staged] [--reset-author]
          [--dry-run|-y|--yes]

git-discard [--dry-run|-y|--yes]
git-discard --all [--include-untracked] [--dry-run|-y|--yes]
```

`--dry-run` cannot be combined with `-y` or `--yes`, and every invalid
combination returns `2` before a repository or dependency probe. Plans follow
the exact-target form of [`output-spec.md`](output-spec.md): a numbered table,
`Dry run: … planned; nothing was …`, `Cancelled: nothing was …`, one result
line per target, and a counted verdict.

### Unstaging

`git-unstage` removes paths from the index and never changes working-tree
files. Its picker lists an `All staged files` row before one row per staged
path, and its preview shows the staged diff. A path whose staged content
differs from both HEAD and the working tree, such as a file edited again after
`git add` or a staged new file deleted from disk, loses that staged content
when it is unstaged. The plan names those paths and then requires confirmation
or `--yes`; a batch without them is reversible and runs without a question.
The batch is one index write (`git restore --staged`, or `git rm --cached`
before the first commit), so every target or none is unstaged. Conflicted
paths are not offered.

### Stashes

`git-stash` without an action opens the stash manager. Its first row saves the
current changes, and its preview shows what would be saved. Each stash row
shows its selector, message, and age, with a preview of its diffstat and
untracked files. `Tab` marks several stashes, which are then dropped together
after one reviewed plan. A single stash opens an action dialog: Apply Stash,
Pop Stash, Show Stash Diff, Browse Stash Files, Create Branch From Stash, and
Drop Stash. The manager returns to the shell after a save, apply, pop, or
branch, and refreshes the list after a view, a drop, a dry run, or a
cancelled action.

Saving asks for an optional one-line message and, only when untracked files
exist, whether to include them. `save --include-untracked` stores untracked,
non-ignored files; nested repositories, which `git stash -u` leaves in place,
are not part of the plan. `--keep-index` keeps staged changes in the working
tree. `create` is accepted as another name for `save`. Without a TARGET,
`apply` and `pop` use the newest stash, `stash@{0}`. A TARGET is a full stash
OID or a current `stash@{N}` selector; a missing, ambiguous, or duplicated
target fails closed.

Every stash plan names the exact paths and stash identity. Apply, pop, and
branch refuse untracked or ignored paths that collide with the stash content.
The working tree, index, and stash list are fingerprinted at review and again
after confirmation, and any change refuses the action. Stashes are bound to
their object IDs, so drop and pop resolve the current selector of the reviewed
OID immediately before they run, and pop drops the stash only after a
successful apply. Saving needs at least one commit. `git stash branch` output
is captured and replayed only on failure.

### Amending the last commit

`git-amend` without an action flag shows the commit and opens an action
dialog whose first choice is Change Message, followed by Edit Message in
Editor, Add Staged Changes, Add Staged Changes and Change Message, and Reset
Author. Change Message edits the subject line in place, prefilled when the Zsh
line editor is available. `--message TEXT` (or `-m`) replaces the subject line
and keeps the body and trailers such as `Signed-off-by`; it must be one
non-empty line, and a multi-line message is edited with the editor action.
`--staged` adds the staged changes, and `--reset-author` sets the author to
the current identity. Without `--staged`, staged changes stay staged and the
commit tree is unchanged.

The plan binds the commit and its branch. A branch switch, a new commit, or an
index or working-tree change after confirmation refuses the amend. When a
remote-tracking branch already contains the commit, the plan says so and the
result names `git-push --force-with-lease`; this is a disclosure, not a
refusal. The amended commit must keep the old parents, keep the old tree
unless `--staged` was requested, and stay on the same branch.

### Discarding changes

Without `--all`, `git-discard` opens a picker whose first rows are
`Discard all changes` and, when untracked files exist, `Discard all changes
and delete untracked files`. The remaining rows are files with unstaged
changes; marking files restores only their unstaged changes from the index
and keeps staged changes. The preview shows what each row would discard, and
a marked all-changes row covers every file row.

`--all` plans every staged and unstaged tracked change back to HEAD: a path in
HEAD is restored in the index and working tree, and a staged new file is
deleted. `--include-untracked` also deletes untracked, non-ignored files.
Ignored files are never deleted, nested repositories and submodule checkouts
are left in place, and directories left empty by deleting untracked files are
removed. The plan lists every path with its change and action. An unborn
HEAD, a merge, rebase, cherry-pick, or revert in progress, and an untracked or
ignored path that a restore would overwrite all refuse the plan. After
confirmation the complete reviewed state, including the identity and
timestamps of every untracked target, is compared again before the first
change, and each target is revalidated immediately before it is restored or
deleted.

## Branches

The Branches menu section groups `git-switch` and `git-recover`. The direct
grammar is:

```text
git-switch [BRANCH|-] [--stash|--carry] [--dry-run|-y|--yes]
git-recover [--deep] [--dry-run|-y|--yes]
```

`--stash` and `--carry` are exclusive, `--dry-run` cannot be combined with
`-y` or `--yes`, and an invalid branch name returns `2`.

### Switching branches

`git-switch BRANCH` switches to the local branch BRANCH. When no local branch
has that name and exactly one remote-tracking ref `REMOTE/BRANCH` exists, it
creates the local branch BRANCH at that ref's reviewed object ID, switches to
it, and sets its upstream to the full `refs/remotes/REMOTE/BRANCH` name; this
is the only branch it ever creates. `REMOTE/BRANCH` chooses one remote
explicitly, and a name found on several remotes is refused with each
candidate. A local branch of the same name is used only when it already
points at the same commit; one that differs is refused, never moved. `-`
switches to the branch checked out before. Lookups use one exact,
case-preserving ref listing, and with `core.ignorecase` a new tracking branch
that differs from a local branch only in letter case is refused.

Without BRANCH, a picker lists local branches first (the current branch is
left out) and then branches that exist only on a remote, each newest first
with its last-commit date and its upstream with the ahead and behind counts
that `git for-each-ref` computes from local refs. Its preview is a constant
`git log` of the row's hexadecimal object ID.

A merge, rebase, cherry-pick, revert, or bisect in progress, conflicted
paths, and a target branch checked out in another worktree (named by its path)
refuse the switch. Untracked or ignored paths that the target would overwrite
or remove are refused too, because Git silently replaces ignored files on
checkout; with `core.ignorecase` they are compared without letter case. An
untracked directory may receive new target files that do not exist yet.

A switch with no uncommitted tracked changes is reversible: it shows the
target and runs at once, without a question, after checking that the target
ref still points at the reviewed commit. Uncommitted tracked changes (staged
or unstaged; untracked files stay where they are) need a reviewed plan: the
changed-file counts and table, and the choices that are possible.

- **Carry** keeps the changes in the working tree. It is offered only when
  the target branch does not change any of the changed paths; should Git
  still find a conflict, `git switch` refuses atomically and nothing changes.
- **Stash** first saves the tracked changes with `git stash push` as
  `zdx git-switch: <from> -> <to>`, verifies the new stash and a clean tracked
  tree, and then switches. It needs a commit on the current branch.

`--carry` or `--stash` chooses directly and asks for confirmation unless
`--yes` is given; without a terminal and `--yes` the switch fails closed.
Without either flag, a terminal dialog offers the possible choices and Cancel,
and the choice authorizes the plan; `--yes` alone is refused because it names
no choice. After authorization, HEAD, the index and working tree, the stash
list, the target ref, its worktree, and the obstacles are compared again. When
a switch fails after a stash was saved, the stash is kept and its object ID is
printed with the `git-stash pop` command that restores it.

### Recovering lost commits

`git-recover` lists the commits named by the HEAD and local-branch reflogs that
no local branch, remote-tracking branch, or tag reaches any more, newest
first, with the short object ID, author date, author, subject, and the reflog
entry. Live stashes are never listed. `--deep` adds the dangling commits that
`git fsck --connectivity-only` reports, such as dropped stashes, bounded to 60
seconds by the core timeout service; a timeout or fsck error is a warning, and
the reflog candidates stay listed. Lists are capped at 500 commits. The
preview is a constant `git show --stat` of the row's hexadecimal object ID.

The selected commit is restored only by creating a new branch, named
`recover/<short-sha>` unless another name is entered. A name that is taken,
that is a directory of an existing branch or has one below it, or that differs
from a branch only in letter case under `core.ignorecase` is refused. The
plan shows the commit and the new ref; after confirmation or `--yes`, the
repository, the commit's existence, and the free name are checked again, and
`git update-ref` creates the branch with an empty old value, so Git refuses it
if the ref appeared in the meantime. No existing ref is moved, reset, or
deleted, and HEAD does not change.

## Workspace identity

`git-identity-check [--json|--quiet]` is read-only. For a repository whose
root lies strictly below `$WS_BASE_DIR/<platform>/<identity>`, it compares the
effective configuration with the profile `ZDX_GIT_IDENTITIES[<identity>]`, as
`git-identity-switcher --switch <identity> local` would set it:

- `user.email` equals the profile's `Email`;
- with a `GpgKey`, `user.signingkey` names that key (a leading `~` is
  expanded on both sides), `gpg.format` is the profile's format (default
  `openpgp`), and `commit.gpgSign` is true; without one, `commit.gpgSign` is
  not true;
- the SSH key that `core.sshCommand` selects (`-i FILE`, `-iFILE`, or
  `-o IdentityFile`) is exactly the profile's `SshKey`, or its `wslpath -w`
  form for `ssh.exe`; without an `SshKey`, the command selects no key.

The command is split into shell words and never run. A mismatch names each
field with the expected and actual email addresses or signing formats, but
never a key, key ID, or key path, prints the fix command
`git-identity-switcher --switch <profile> local`, and returns `1`. Outside the
layout, or when no profile is named after the identity directory, it reports
not applicable and returns `0`. `--quiet` prints nothing unless the identity
differs, and then one warning and the fix command. `--json` and `--quiet` are
exclusive.

The opt-in identity guard is a `chpwd` hook that the plugin wrapper registers
only in an interactive shell with `ZDX_GIT_IDENTITY_GUARD=1`. Outside the
layout it does parameter work only. Inside, it finds the repository root from
`.git` entries without running Git, checks each root once per shell session
with `git-identity-check --quiet`, never prompts, ignores the result, and
returns `0`, so a directory change never fails. Subshells, such as command
substitutions that change directory, are skipped. In a lazy shell the first
check loads the Git suite through `git-menu --help`, whose usage text is
discarded.

## Structured data

`git-status --json` and `git-identity-check --json` write exactly one JSON
object and a newline to stdout, built with `jq -n` from `--arg` and
`--argjson` values; jq is checked after the arguments are parsed, and its
absence returns `1` with an error. JSON mode never opens fzf or prompts,
keeps warnings and errors on stderr, has the same exit status as text mode,
and never contains key material. Keys are snake_case, an unknown or
unavailable value is `null`, and the first key names the schema.

`zdx.git-status.v1` holds `repository` (the absolute root), `branch` (`null`
when detached), `detached`, `head` (`null` before the first commit),
`upstream`, `ahead` and `behind` (from local refs only; `null` without an
upstream), `operation` (`null`, `merge`, `rebase`, `cherry-pick`, `revert`,
or `bisect`), `changes` with `staged`, `unstaged`, `untracked`, and
`conflicted` path counts (a conflicted path counts only as conflicted),
`stashes`, and `workspace` (`{platform, identity}`, or `null` outside the
layout). Text mode is unchanged.

`zdx.git-identity-check.v1` holds `applicable`, `reason` (why it does not
apply, else `null`), `repository`, `platform`, `identity`, `profile`,
`matches` (`null` when not applicable), `mismatches` (a list of `field` and
`reason` objects), and `fix_command` (`null` unless a field differs).

## Dependencies and context

Dependencies are enforced at the narrowest useful boundary:

- `git` 2.31 or newer is the suite's base dependency. Every command that
  needs a repository or the Git configuration checks it after parsing its
  arguments, and the menu checks it before it runs Git for its context; see
  [Platform notes](#platform-notes).
- `fzf` is required only by an interactive adapter. Help and a complete
  non-interactive command do not require it.
- Authenticated `gh` is required only by `git-pr-create` and
  `git-pr-checkout`.
- `jq` is required only by the `--json` modes.
- Git transport credentials and a configured remote are checked only by the
  remote action that needs them.

`clean-remote-merged` uses Git transport rather than the GitHub API, so it does
not require `gh`. Moving it to an API operation would be a public change that
updates the inventory's capability metadata.

The top-level menu does not reject the caller merely because the current
directory is outside a repository. `git-identity-switcher --status` and a
global identity switch are valid without one. Repository-only entries are
annotated as unavailable, while the remaining actions stay discoverable. The
dispatcher only routes; each public command repeats the authoritative context
check after parsing its arguments.

Missing optional tools annotate only affected entries using text such as
`missing: gh`; color or a glyph is never the sole signal. Dependency checks do
not launch an installer or authentication flow without a separate explicit
choice. One menu build looks each dependency up on `PATH` once, so a missing
`gh` is not searched for again in every row and in the header.

## Platform notes

The suite supports Linux, WSL, and macOS. Besides Git, `gh`, `fzf`, and SSH,
it runs only Zsh builtins, `/bin/sh` for previews and configured SSH
commands, and options of `mktemp`, `rm`, `rmdir`, `awk`, `cat`, `grep`,
`less`, `readlink`, `tty`, and `ssh-keygen` that BSD and GNU userlands share,
plus `xcode-select` on macOS and `wslpath` on WSL. It loads only `zstat` from
`zsh/stat`, so the shell's own `stat` command is never replaced, and it
resolves `TMPDIR` behind the macOS `/var` alias with the shared trusted-root
rule in [`development.md`](development.md).

### Git release

Git 2.31 or newer is required: pull and fetch transactions use
`git fetch --atomic --no-write-fetch-head --no-auto-maintenance`, path
commands use `git rev-parse --path-format=absolute`, forced pushes use
`--force-if-includes`, and identity planning uses `git config --show-scope`.
Ubuntu 20.04's Git 2.25 is too old, while Apple's Git in current Command Line
Tools is new enough. The check runs `git --version` once for each Git
executable and repeats it when the executable is replaced or upgraded. A Git
that is missing, too old, or fails to run produces one error with
installation advice, naming the version found when it is too old, instead of
a later `Not inside a Git worktree` or unknown-option failure.

### macOS

Without the Command Line Tools, `/usr/bin/git` is only a placeholder that
opens an installation dialog. When `xcode-select -p` names no installed
developer directory, the suite reports that placeholder and suggests
`xcode-select --install` or `brew install git` without running it, including
in the menu and before a path command looks for the repository root.

### Case-insensitive file systems

APFS and HFS+ in their default modes and Windows drives under WSL are
case-insensitive, and Git records this as `core.ignorecase`. When it is set,
the suite compares paths and ref names without letter case:

- The untracked and ignored obstacle checks of `git-discard`,
  `git-discard --all`, `git-undo-commit --hard`, and stash apply, pop, and
  branch compare lowercase paths, including the directory checks, so restoring
  `notes.txt` cannot replace an untracked `Notes.TXT`, and restoring
  `docs/a.txt` cannot remove an untracked file named `Docs`.
- `git-switch` compares untracked and ignored obstacles without letter case.
- `git-tag-create`, `git-stash branch`, `git-switch` (the tracking branch it
  creates), `git-recover`, `git-pull` (each fetch mode, including
  `--fetch-prune`), and `git-push --set-upstream` refuse a new tag, branch, or
  remote-tracking ref whose name, or a directory of it, differs only in letter
  case from another planned or existing ref. Such loose refs
  would share one file: a new `V1.0` would shadow a packed `v1.0`, and remote
  branches `Feature` and `feature` would otherwise fail the fetch transaction
  with an unrelated error. The refusal names both refs; renaming one or
  deleting a stale tracking ref resolves it.

Unicode normalization differences (`core.precomposeUnicode`) are not compared.

### WSL

- A repository on a Windows drive (`/mnt/<letter>` on WSL, detected from the
  WSL environment, interop registration, or kernel release) is reached through
  DrvFs. The menu header counts an untracked directory as one change there
  instead of listing every untracked file, and the menu and `git-status`
  print one advisory: Git is slower there, and Windows and WSL Git can
  disagree on line endings (`core.autocrlf`). Keeping repositories in the
  Linux file system avoids both.
- An identity profile keeps the SSH program and options that the scope already
  uses: the scope's own `core.sshCommand`, else the inherited one. Only that
  command's key selection (`-i`, `IdentityFile`, `IdentitiesOnly`) is
  replaced, so `ssh.exe`, which uses the Windows SSH agent, and
  `ssh -o IdentityAgent=…`, which uses an agent such as 1Password's, keep
  working. A profile key is passed to `ssh.exe` as a Windows path converted
  with `wslpath -w`; when the conversion fails, the profile is refused before
  any change, with guidance to give `SshKey` as a Windows path or to point
  `core.sshCommand` at the Linux `ssh`. A local profile without a key keeps an
  inherited command that selects no key and overrides one that selects
  another profile's key with the same command without it.
- `git-pr-create` resolves an SSH host alias such as `github-work` with the SSH
  program Git uses for the push: `GIT_SSH_COMMAND`, then `core.sshCommand`
  (run through `/bin/sh`, as Git does), then `GIT_SSH`, then `ssh`, always as
  `-G -- HOST` with stdin closed. `ssh.exe` therefore reads the Windows SSH
  configuration, and its CRLF output is accepted. PuTTY variants have no `-G`
  and keep the alias.
- A `.ws-hostname` file saved with Windows line endings is read without its
  trailing carriage return.

### Signing

`git-tag-create` and the commits that `git-amend` and a merging or rebasing
`git-pull` create may be signed (`--signed`, `tag.gpgSign`, or
`commit.gpgSign`). When `GPG_TTY` is unset and standard input is a terminal,
those Git commands receive `GPG_TTY` set to that terminal, so GnuPG's
pinentry can prompt there; the shell's environment is not changed.

### Verification boundary

`test/git_platform.bats` and `test/git_identity.bats` select every platform
branch through fixtures and mocks on the host that runs them:
case-insensitive behavior through `core.ignorecase` on a case-sensitive file
system, WSL through `/proc` fixtures and an overridden detector, `ssh.exe`,
`wslpath`, and `xcode-select` through recorded mocks, old and failing Git
through fake executables, and pinentry through a fake `gpg.program` under a
Zsh pseudo-terminal. The macOS CI job runs the same tests on an Apple Silicon
runner with BSD tools, a `TMPDIR` behind a symbolic link, and a real
case-insensitive APFS volume. None of this replaces a run on a real
Windows drive, with Windows OpenSSH, or with a real pinentry; in
particular, whether Windows OpenSSH accepts a key converted to a
`\\wsl.localhost\…` path is unverified, so keys that `ssh.exe` uses are best
kept on the Windows side.

## Streams and exit statuses

Help, headings, prompts, progress, previews, status summaries, success
messages, warnings, errors, and layout-only blank lines go to stderr.

The stash manager's Show Stash Diff and Browse Stash Files actions page native
Git diff content on stdout, through `less -R` when stdout is a terminal. That
content is repository data, not a stable record schema. The `--json` modes of
`git-status` and `git-identity-check` write the documented
[structured data](#structured-data) to stdout. Every other Git command only
reports suite status or performs a mutation, so stdout stays empty. Output
from Git and `gh` that a command shows as context, such as `git verify-tag`
diagnostics or push progress, goes to stderr. Human suite UI must never be
mixed into data.

| Status | Meaning |
| --- | --- |
| `0` | Success, deliberate cancellation, or a documented no-op |
| `1` | Operational failure, unmet precondition, refused unsafe request, or partial failure |
| `2` | Invalid arguments, unknown option, or unknown dispatch token |

An invoked tool's distinct status may be preserved when callers need it, but a
success or logging helper must never mask a failure. A failed Git mutation,
signature verification, `gh` operation, or fzf invocation returns non-zero.

Esc, Ctrl-C in an interactive picker, an empty deliberate selection, or a
declined confirmation performs no mutation and returns `0`. An fzf execution
error is not cancellation. A destructive command without a usable terminal and
without its documented `--yes` authorization fails closed with status `1`.

## Color, accessibility, and terminal behavior

Git logging helpers apply color only when stderr is a terminal, `TERM` is not
`dumb`, and `NO_COLOR` is unset. `NO_COLOR` suppresses all Git-owned ANSI and
the optional shared fzf theme without changing text, data, or status.

Headers, prompts, menu rows, and fzf keyboard legends contain no raw ANSI.
Meaning is expressed in text rather than only through color, glyphs, or emoji.
Labels remain understandable under a narrow terminal and without special glyph
support.

ANSI is allowed in source content such as `git diff --color=always` only when
the receiving picker or pager explicitly supports it. It is not allowed in UI
chrome.

## Menu rows and fzf contract

The top-level command menu uses exactly:

```text
label|command|description
```

`_git_menu_section TITLE [DESCRIPTION]` and
`_git_menu_entry LABEL COMMAND DESCRIPTION` use arguments in output-field
order. They reject a newline, NUL, or `|` in any field, write the diagnostic to
stderr, and return `2`. Menu construction stops on a helper failure instead of
inserting a malformed row.

Section rows use `:` and dispatch to a no-op. The command field remains the
canonical token even when a label is decorated with a missing prerequisite.
Formatted display text is never reused as a branch, path, revision,
pull-request, or tag mutation target.

The menu order follows user risk and frequency, with read-only context first
and destructive cleanup and history rewriting last:

1. Repository Context: `git-auth` and `git-status`;
2. Local Changes: `git-unstage`, `git-stash`, and `git-amend`;
3. Branches: `git-switch` and `git-recover`;
4. Synchronization: `git-pull` and `git-push`;
5. Tags and Pull Requests: `git-tag-create`, `git-tag-verify`,
   `git-tag-push`, `git-pr-create`, and `git-pr-checkout`;
6. Configuration: `git-identity-check` and `git-identity-switcher`;
7. Destructive Maintenance: `git-discard`, `git-undo-commit`,
   `git-tag-delete`, `clean-branches`, and `clean-remote-merged`.

`git-menu --help` lists the same groups in the same order.

The top-level picker is single-select. Its plain header reports available
repository, branch, change count, identity, remote, and `gh` context as
`Key: value` facts without exposing credentials. Its exact active legend is:

```text
Type to filter | Enter run | Esc cancel | Ctrl-/ details
```

Additional keys appear only in the invocation where their binding is active.
Typing filters; `Tab` is advertised only for a real multi-select or binding.

Git owns a local `_git_fzf` wrapper whose functional options are assembled at
invocation time. It may consume `_tk_fzf_color_opts` only when that documented
core compatibility helper already exists. It does not source another suite,
freeze a global theme array, or require the core runtime during standalone
sourcing.

Command previews are read-only and use the canonical command plus description
unless additional context materially helps the decision. Preview and binding
programs do not interpolate unvalidated values, use `eval`, expose secrets, or
perform a mutation. Destructive bindings return an action identifier to Zsh;
validation, confirmation, and mutation happen only after fzf exits.

Content browsers may use a typed TSV or NUL-delimited schema appropriate to
their records. Multi-select headers state that `Tab` selects, preserve opaque
identifiers, and define execution order. A picker error is propagated; only a
recognized cancellation is normalized to `0`.

The local-change pickers use TAB-separated records that start with a numeric
identifier and a row kind or stash object ID and end with the display text;
the identifier, not the text, maps back to the target. Action rows, such as the
stash manager's save row and the discard and unstage all-changes rows, come
before item rows, and targets run in list order. Their previews are constant
read-only programs: fzf quotes the kind and path placeholders, only a
hexadecimal object ID reaches a stash diff, and Git runs without external diff
drivers, text conversion, or optional index locks. Their headers state
`Tab mark` on a separate line, and `Ctrl-/` toggles the preview.

## Completion contract

`completions/_git-menu` completes both:

- `git-menu <command> [command-specific arguments...]`;
- every loaded direct public command.

Nested and direct grammars are identical. Completion exposes all 21 tokens and
their `-h` and `--help` options. Its contextual contract covers bounded local
discovery of branches, revisions, tags, remotes, stash selectors and OIDs,
configured identity profiles and scope, cached pull-request numbers, and the
documented flags and positional grammar of each mutation command.

Completion is advisory and read-only. It does not contact the network, mutate
Git state, request authentication, or evaluate repository data as shell code.
Local discovery is capped at 500 records per source. After `--help`, an
exclusive mode, or a complete positional target, unrelated suggestions are
suppressed.

At minimum, the contextual grammar must distinguish:

- `git-identity-switcher --status` from
  `--switch NAME [local|global]`;
- a pull-request number from interactive checkout;
- the `git-push` modes `--set-upstream`, `--force-with-lease`, and `--all`,
  with no tag mode;
- the stash `save` (or `create`), `apply`, `pop`, `drop`, and `branch`
  grammars, with save options only after `save`;
- `git-discard --include-untracked` only after `--all`;
- the exclusive `git-switch` change modes `--stash` and `--carry`, and its
  local or uniquely cached remote branch names;
- `--json` only on `git-status` and `git-identity-check`, and the exclusive
  `--json` and `--quiet` of `git-identity-check`;
- local branches and revisions from full branch refs, tags, and remotes;
- `--dry-run` and `--yes` only on commands that document them.

## Mutation and remote safety

Every selected identifier remains data. File discovery is NUL-delimited where
Git supports `-z`; external commands receive arrays and an option terminator
before user-controlled paths. Revisions, refs, remotes, stash references, and
numeric GitHub identifiers are validated independently of their display row.

Destructive or multi-target commands:

1. compute the exact target set without mutation;
2. reject empty, malformed, ambiguous, protected, or out-of-scope targets;
3. show the repository, remote, current branch, target identifiers, and
   consequence;
4. support `--dry-run` for broad or multi-target operations;
5. require confirmation immediately before execution, or documented `--yes`;
6. revalidate repository identity, current branch, HEAD, upstream, remote, and
   target existence after confirmation;
7. report every failed target and return non-zero on partial failure.

The current branch, default branch, remote default branch, and protected
repository branches are never deleted by a bulk cleanup. A name derived from a
formatted row is resolved back to a canonical ref before use.

History rewriting and force pushing show both old and intended commits. The
default force mode is an exact `--force-with-lease=<ref>:<oid>` transaction.
Normal pushes also use frozen source OIDs and exact OID-or-absence leases, and
must prove a fast-forward before execution. Raw `--force` is unsupported.
Push planning rejects multiple push URLs and uses the one frozen URL for
snapshot, execution, and postcondition checks.
Tag publication and deletion, including no-op detection, use that same single
push destination. Publication uses the frozen local OID and an absence lease;
remote branch cleanup also rejects multiple push URLs before mutation.
Every push passes `--no-follow-tags --recurse-submodules=no`, so
`push.followTags` and `push.recurseSubmodules` cannot add refs that the plan
never listed. The `git-pr-create` publication is an exact lease on the
reviewed remote head (or its absence) after proving a fast-forward. Because a
push to the frozen URL bypasses the remote's fetch refspec,
`clean-remote-merged` deletes the matching remote-tracking ref with an exact
OID lease, and `clean-branches` removes the deleted branch's configuration
section as `git branch -d` does. Upstreams are configured from full
`refs/remotes/<remote>/<branch>` names. `git ls-remote` matches patterns
against the tail of each ref, so remote snapshots keep only refs that match
the requested exact ref or literal prefix.

Path-based local commands (`git-unstage`, `git-stash`, `git-discard`, and
`git-undo-commit`) run from the repository root, because Git lists
root-relative paths but resolves pathspecs from the current directory. Their
path lists disable rename detection so both sides of a rename are listed. The
plan HEAD identity is the commit plus its symbolic ref: `git-undo-commit` and
`git-amend` show the current branch and refuse to continue when another branch
was checked out, even at the same commit.

Pull and fetch operations download reviewed refs into an invocation-owned
temporary namespace with implicit ref mappings, tags, pruning, submodules,
`FETCH_HEAD`, commit-graph writes, and maintenance disabled. Fetched OIDs must
match the frozen remote snapshot before canonical tracking refs are promoted
with compare-and-swap updates. Temporary refs are removed with exact OID
leases.

Fetch and pull do not require a single push URL: their reviewed fetch source
is independent of publication configuration.

Discard of selected files or all changes, stash deletion, multi-ref pushes,
tag publication, tag deletion, and remote branch cleanup stop before later
targets on interruption (`130` or `143`), preserve that status, list the
targets that were not run, and report completed work. Ordinary target
failures still allow independent selected targets to run.

GitHub writes re-fetch the repository, pull request, or branch state after
confirmation. Multi-target writes run sequentially unless concurrency is
proven safe, retain the association between each identifier and result, and
return non-zero when any required operation fails.

No Git path uses `eval`, computed shell text, or `sh -c` with selected data.

## Design controls

Each row names a risk that a shell menu suite is prone to and the control
this suite applies. The focused tests below keep every control from
regressing.

| Risk | Control |
| --- | --- |
| Nested routing drops arguments after the command token | `git-menu` forwards `"$@"` exactly, including empty and leading-dash arguments, so nested and direct invocation are equivalent |
| An unknown option is treated as a command name, or invalid input looks like an operational failure | Invalid options and dispatch tokens fail before probes with status `2` |
| A command without its own parser accepts or misreports invalid input | Every public command has direct help, validates its grammar first, and returns `2` for invalid input |
| Help, layout lines, or tool output reach stdout | Help and human UI use stderr; stdout carries only documented data |
| Raw ANSI reaches logs or fzf chrome | Terminal-aware Git helpers and the local fzf wrapper honor `NO_COLOR` and `TERM=dumb` |
| A failed fzf, Git, `gh`, or verification run is mistaken for cancellation or masked by logging | Only a recognized picker cancellation becomes `0`; operational and tool statuses propagate |
| The menu refuses to open outside a repository | The menu opens anywhere, computes repository context once, annotates repository-only rows, and keeps canonical command fields |
| A shared picker advertises keys that are not bound | Git owns its fzf wrapper, text-first context, and invocation-specific keyboard legend; it defines no `_tk_*` helper |
| Menu rows carry delimiters or control characters | Three-field row helpers validate every field and fail closed with status `2` |
| Completion drifts from the command inventory | Nested and direct completion expose every canonical token and bounded command-specific contexts, and contract tests compare them with the fixture |
| Loading falls back to an unrelated installation or leaves a false sentinel | Loading derives one exact root, sets each sentinel only after success, fails closed, and supports a clean retry |
| Selected data reaches `eval`, dynamic shell text, or a reparsed display row | Arrays, typed records, opaque identifiers, and post-selection validation keep data out of shell programs |
| A destructive path runs without a plan, revalidation, dry run, or partial-failure status | Local, remote Git, and GitHub mutations follow the [mutation safety sequence](#mutation-and-remote-safety) |
| A Git transport operation demands GitHub authentication | `clean-remote-merged` depends on Git and the configured remote, not `gh` |
| Public surfaces, streams, or statuses change without a failing test | Contract and interface suites freeze them and run production code in isolated Zsh sandboxes |
| User documentation advertises behavior the suite does not provide | [`user-guide.md`](user-guide.md) lists only Git-owned commands, direct pull-request-number checkout, and redacted authentication status, and changes with the code |

## Verification files

| File | Contract boundary |
| --- | --- |
| `test/fixtures/git-public-commands.tsv` | Required frozen 21-command inventory, module ownership, risk, and capability metadata |
| `test/git_contract.bats` | Exact fixture, module, menu, help, dispatcher, nested-completion, and direct-completion parity, including a `git-push` grammar without a tag mode, the stash action grammars, `git-discard --include-untracked` only after `--all`, the amend and unstage flags, the exclusive `git-switch` change modes, and `--json` only on read-only commands |
| `test/git_branches.bats` | Clean, previous, and remote-tracking switches with exact tracking-branch creation; refusals for unknown, ambiguous, invalid, differing, and case-colliding names, operations in progress, other worktrees, and untracked or ignored obstacles; dirty-tree plans, the carry and stash choices and dialog, dry runs, declined and non-terminal confirmations, and revalidation after confirmation; the branch and commit pickers with constant previews; and recovery that only creates a new branch, refuses taken and conflicting names, revalidates after confirmation, and adds dropped but never live stashes with `--deep` |
| `test/git_identity_check.bats` | Matching and mismatching profiles without key material or configuration changes, keyless profiles, `IdentityFile` and `ssh.exe` key selection, not-applicable repositories, grammar errors, and the identity guard: off by default and outside interactive shells, one warning per repository, silent outside the layout and in subshells, and lazy loading |
| `test/git_json.bats` | Exact `zdx.git-status.v1` and `zdx.git-identity-check.v1` documents validated with `jq -e`, null and boolean typing, single-document stdout through the nested route, and missing-`jq`, invalid-argument, and no-repository failures with empty stdout |
| `test/git_interface.bats` | Exact routing and timing, all direct help streams, outside-repository annotations, standalone and double sourcing, exact-root loader failure and retry, `NO_COLOR`, row validation, fzf behavior, the Local Changes and Branches sections and help groups, the pull-mode dialog, and rejection of a `git-push --tags` mode |
| `test/git_safety.bats` | Credential redaction, non-TTY refusal on the local-change and shared confirmation paths, literal pathspec isolation, identity-data non-execution, exact PR OID comparison, SSH host-alias PR remotes, detached checkout of the reviewed PR head, subdirectory path selections for discard, unstage, and stash, nested-repository stashes with stdout diffs, staged-rename unstaging, untracked discard obstacles, and branch-bound undo plans |
| `test/git_local_changes.bats` | Discard of every change with and without untracked files, kept ignored files and nested repositories, unstage batches and staged versions missing from the working tree, subject-only and editor amends with kept trailers, published-commit disclosure, stash save, apply, pop, drop, and branch, the stash manager and action dialog, constant read-only previews, dry runs, declined and unavailable confirmations, and refusal after post-confirmation changes |
| `test/git_github_safety.bats` | Push-remote precedence, local PR head naming, exact single push-URL enforcement, and deny-by-default GitHub write calls |
| `test/git_remote.bats` | Disposable local-remote verification for exact pushes, isolated fetch and pull, tag publication and deletion, leased branch cleanup with tracking-ref and branch-configuration removal, `push.followTags` isolation, clean multi-ref stdout, ls-remote tail-match filtering, and full-ref upstreams |
| `test/git_sync_recovery.bats`, `test/git_tag_recovery.bats` | Independent fetch configuration, exact publication destinations, absence leases, moved local tags, and rejection of multiple push URLs before and after review |
| `test/git_local_recovery.bats` | Interruption versus ordinary failure in local discard batches, all-changes discard of tracked and untracked files, and stash drops |
| `test/git_identity.bats` | Identity status, local/global profile behavior, local overrides of inherited signing and SSH key selection, inherited `ssh.exe` and `IdentityAgent` commands kept with or without a profile key, Windows key paths for `ssh.exe` through `wslpath`, and refusal when that conversion fails |
| `test/git_platform.bats` | Case-insensitive obstacles for hard undo, discard, discard of every change, and stash apply; case-colliding tags, stash branches, fetched and pruned tracking refs, and upstream pushes; WSL detection, the Windows-drive badge and advisory, and one `PATH` lookup per menu dependency; SSH alias resolution with the SSH program Git uses; CRLF `.ws-hostname` files; the macOS Command Line Tools placeholder; Git older than 2.31 or failing to run; and `GPG_TTY` for signed tags |
| `test/lazy_loading.bats` | Lazy and eager loading plus caller-owned `ZSH_CUSTOM` preservation |

Focused GitHub verification uses a deny-by-default `gh` mock that records every
argument and fails unexpected writes. Git tests may use a real disposable
repository inside the BATS sandbox, but never mutate the repository under test.
Remote deletion, force push, and pull-request creation use isolated mocks or
disposable local remotes unless a separately documented manual smoke test
targets a disposable remote.

The contract suite must derive and compare surfaces rather than copy a second
executable allowlist. Interface tests capture stdout and stderr separately and
exercise production code in Zsh. Any new high-risk regression test covers
cancellation, dry run, non-interactive refusal, protected refs, leading-dash and
newline-containing names, post-confirmation changes, and partial failure.

Final acceptance requires the focused Git tests, `zsh -n` for every modified
Zsh file, and `just check`. Because the Markdown hook can rewrite files, inspect
the diff and repeat the gate after any automatic change.

## Maintenance triggers

Update this contract, its fixture, and focused tests whenever:

- a public command, flag, positional argument, or compatibility alias changes;
- an action changes risk class or gains a destructive, remote, or multi-target
  mode;
- a new dependency, authentication boundary, remote API, pager, or preview
  program is introduced;
- a menu row, fzf binding, keyboard legend, record schema, or completion
  grammar changes;
- Git identity ownership moves between suites, or the workspace layout that
  `git-auth` reads changes;
- a new persisted credential or configuration field can reach output;
- a real-host or real-GitHub verification expands the supported baseline.
