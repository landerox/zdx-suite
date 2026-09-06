# Git suite contract

This document defines the implemented public contract for the Git suite. It
freezes the current 39-command surface and records the migration that brought
the suite into conformance with the repository-wide engineering, safety, and
interactive-menu standards.

The authoritative general contracts are
[`development.md`](development.md), [`menu-spec.md`](menu-spec.md),
[`headers.md`](headers.md), and [`testing.md`](testing.md). Ownership boundaries
are defined in [`suites.md`](suites.md), and cross-suite threats are tracked in
[`security-assessment.md`](security-assessment.md). Those documents take
precedence if this migration record conflicts with them.

Audit and implementation baseline: 2026-07-25.

The pre-migration implementation was legacy. Freezing a command name did not
preserve dropped arguments, mixed streams, unsafe shell construction,
inaccurate keyboard legends, incorrect statuses, or insufficient
destructive-operation controls. The current implementation replaces those
behaviors; the resolved findings remain recorded below as regression context.

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

This capture migration covers only `git-menu`. Existing nested Git resource
and decision pickers retain their local capture implementations, including
command substitution; they are not covered by the top-level private-file
assurance. Their typed records, selection checks, and mutation authorization
remain unchanged.

## Implementation status

| Phase | Status | Required focused verification |
| --- | --- | --- |
| 0 — contract baseline | Complete in the current worktree | `git_contract.bats` |
| 1 — loader and common runtime | Complete in the current worktree | `git_interface.bats`; `lazy_loading.bats` |
| 2 — routing, menu, and completion | Complete in the current worktree | `git_contract.bats`; `git_interface.bats` |
| 3 — local read and mutation workflows | Implemented | focused local Git verification |
| 4 — destructive local and remote Git workflows | Implemented | destructive-path verification |
| 5 — GitHub workflows | Implemented | deny-by-default `gh` verification |
| 6 — interface and documentation closure | Complete in the current worktree | all focused tests; `just check` |

Implementation status is not inferred merely because a command can be selected
interactively. Its direct interface, status behavior, stream contract, safety
boundary, tests, and documentation must agree.

## Ownership

The Git suite owns:

- local repository inspection and local Git object or worktree workflows;
- branches, commits, diffs, stashes, tags, remotes, and repository-local
  identity overrides;
- GitHub issues, pull requests, and repository creation performed through
  authenticated `gh`;
- the `git-menu` discovery layer and the direct routing of its canonical
  commands.

It does not own:

| Domain | Owner | Git-suite boundary |
| --- | --- | --- |
| Workspace placement, profiles, and SSH host-alias lifecycle | `ws` | Git may consume a resolved identity; it does not manage workspace directories |
| Cross-suite dependency installation | `zdx-doctor` | Git reports a missing dependency and a safe installation direction |
| CI run and artifact lifecycle | `ci` | GitHub issues and pull requests remain Git-owned; Actions lifecycle does not |
| Host Git installation and updates | `sys` | Git checks for the executable but does not install or update it |
| Core timing, telemetry, and shared fzf theme | core runtime | Git consumes optional documented services and defines no competing global shim |

The existing `ws -> git` private-helper dependency is the repository's one
documented legacy ownership exception. Future work must reduce that coupling or
extract deliberately shared identity primitives; new Git work must not expand
the `_tk_*` compatibility namespace.

`git-auth` reports identity, remote alignment, and authentication state. It
MUST NOT display authentication tokens, private-key contents, credential
helpers' secrets, or unmasked sensitive configuration.

## Architecture

```text
functions/git-menu.zsh           loader, public router, top-level menu model
  -> functions/git-common.zsh    Git-private UI, records, dependencies, dispatch
    -> functions/git/git-clean.zsh
    -> functions/git/git-issues.zsh
    -> functions/git/git-branch.zsh
    -> functions/git/git-tags.zsh
    -> functions/git/git-changes.zsh
    -> functions/git/git-history.zsh
    -> functions/git/git-stash.zsh
    -> functions/git/git-sync.zsh
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

Git-private helpers use `_git_*`. Existing `_tk_*` functions are compatibility
names shared with the legacy workspace implementation; they are not a namespace
for new Git helpers and are not core APIs. The optional core `_timed` and
`_tk_fzf_color_opts` services are consumed through Git-owned wrappers so
standalone suite sourcing remains functional without defining global
substitutes.

Only `git-menu` is guaranteed as a cold-shell lazy entrypoint. Individual
public functions are available after the suite loads, or immediately under
eager loading. Scripts SHOULD use `git-menu <command> [arguments...]`.

## Frozen command inventory

The canonical surface contains exactly 39 command tokens. The highest-effect
classification controls review priority; a command is classified by its
most dangerous selectable action, not its most common action.

| Command | Owning module | Highest effect | Required context |
| --- | --- | --- | --- |
| `git-auth` | `git-common.zsh` | read-only | repository |
| `git-status` | `git/git-repo.zsh` | read-only | repository |
| `git-switch` | `git/git-branch.zsh` | mutating | repository |
| `git-branch-create` | `git/git-branch.zsh` | mutating | repository |
| `git-branch-rename` | `git/git-branch.zsh` | mutating | repository |
| `git-stage` | `git/git-changes.zsh` | mutating | repository |
| `git-staged` | `git/git-changes.zsh` | read-only | repository |
| `git-unstage` | `git/git-changes.zsh` | mutating | repository |
| `git-discard` | `git/git-changes.zsh` | destructive | repository |
| `git-restore-from` | `git/git-changes.zsh` | destructive | repository |
| `git-commit` | `git/git-changes.zsh` | mutating | repository |
| `git-amend` | `git/git-changes.zsh` | destructive | repository |
| `git-undo-commit` | `git/git-changes.zsh` | destructive | repository |
| `git-cherry-pick` | `git/git-changes.zsh` | mutating | repository |
| `git-commit-verify` | `git/git-changes.zsh` | read-only | repository |
| `git-merge` | `git/git-branch.zsh` | mutating | repository |
| `git-rebase` | `git/git-branch.zsh` | destructive | repository |
| `git-diff` | `git/git-history.zsh` | read-only | repository |
| `git-blame` | `git/git-history.zsh` | read-only | repository |
| `git-stash` | `git/git-stash.zsh` | destructive | repository |
| `git-push` | `git/git-sync.zsh` | destructive | repository and remote |
| `git-pull` | `git/git-sync.zsh` | destructive | repository and remote |
| `git-log-search` | `git/git-history.zsh` | read-only | repository |
| `git-reflog` | `git/git-history.zsh` | read-only | repository |
| `git-file-history` | `git/git-history.zsh` | read-only | repository |
| `git-tag-create` | `git/git-tags.zsh` | mutating | repository; remote is optional |
| `git-tag-list` | `git/git-tags.zsh` | destructive | repository; remote is optional |
| `git-tag-verify` | `git/git-tags.zsh` | read-only | repository |
| `git-tag-push` | `git/git-tags.zsh` | mutating | repository and remote |
| `git-tag-delete` | `git/git-tags.zsh` | destructive | repository; remote is optional |
| `clean-branches` | `git/git-clean.zsh` | destructive | repository |
| `clean-remote-merged` | `git/git-clean.zsh` | destructive | repository and remote |
| `git-issues` | `git/git-issues.zsh` | destructive | repository and authenticated `gh` |
| `git-prs` | `git/git-issues.zsh` | destructive | repository and authenticated `gh` |
| `git-pr-create` | `git/git-issues.zsh` | mutating | repository and authenticated `gh` |
| `git-pr-checkout` | `git/git-issues.zsh` | mutating | repository and authenticated `gh` |
| `git-repo-create` | `git/git-repo.zsh` | mutating | working directory and authenticated `gh` |
| `git-identity-switcher` | `git/git-identity.zsh` | mutating | Git configuration; repository only for local scope |
| `git-config-edit` | `git/git-repo.zsh` | mutating | repository |

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

These sets MUST contain the same 39 canonical tokens:

1. records in `test/fixtures/git-public-commands.tsv`;
2. public functions loaded from their declared modules;
3. non-sentinel command fields in the top-level menu;
4. fixed arms in `_git_dispatch`;
5. commands named by `git-menu --help`;
6. nested entries in `completions/_git-menu`;
7. direct completion bindings for every public command.

At the audited baseline, the functions, menu, dispatcher, and top-level help
agreed on all 39 tokens while completion exposed only 34. It omitted:

- `git-commit-verify`;
- `git-tag-list`;
- `git-tag-verify`;
- `git-tag-push`;
- `git-tag-delete`.

It also had no direct-command bindings. The current worktree closes that
surface gap: nested and direct completion expose the same exact 39-token
inventory. The baseline mismatch remains recorded here so a regression is not
mistaken for an intentional exception.

An addition, rename, compatibility alias, or removal updates the fixture,
function, menu, dispatcher, help, nested and direct completion, focused tests,
and [`user-guide.md`](user-guide.md) in one coherent change.

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
existing `git-identity-switcher` interface remains:

```text
git-identity-switcher
git-identity-switcher --status
git-identity-switcher --switch NAME [local|global]
```

Its invalid scope, missing name, extra arguments, and unknown options return
`2`. Every remaining public interface is documented by its direct `--help`
output and rejects invalid combinations before runtime probes.

The read-only browsers and selection-first managers remain intentionally
interactive when no exact target grammar is documented. This includes file
selection for stage, unstage, discard, restore, and staged-diff workflows;
commit, amend, cherry-pick, issue, and pull-request managers; and the diff,
log, reflog, file-history, blame, and signature browsers. Their public command
is still directly invocable; “interactive-only” means that it requires a TTY
and `fzf`, not that the action exists only as a top-level menu binding.

Exact direct targets are available for branch switching, creation, rename,
merge and rebase; reset mode; pull and push; tag creation, display,
verification, publication and deletion; merged-branch cleanup; pull-request
checkout; identity application; local configuration; and GitHub repository or
pull-request creation. Commands that accept `--yes` still build and display the
same plan, revalidate it, and bypass only the final prompt.

The implemented non-interactive creation and local-configuration interfaces
are:

```text
git-pr-create [--base BRANCH]
              [--title TEXT [--body TEXT] | --fill]
              [--draft] [--dry-run] [-y|--yes]

git-repo-create [--name NAME]
                [--private|--public|--internal]
                [--description TEXT]
                [--remote NAME] [--push|--no-push]
                [--dry-run] [-y|--yes]

git-config-edit [--name VALUE] [--email VALUE]
                [--dry-run] [-y|--yes]

git-stash [--dry-run] [--yes]
git-stash create [--include-untracked|--keep-index]
                 [--message TEXT] [--dry-run] [--yes]
git-stash apply|pop TARGET [--dry-run] [--yes]
git-stash drop TARGET... [--dry-run] [--yes]
git-stash branch TARGET NAME [--dry-run] [--yes]
```

With no arguments, these commands retain their interactive adapter. Direct
mode validates every value before dependency or mutation work. `--fill` and
`--title` are exclusive, `--body` requires `--title`, visibility and push modes
are exclusive, and `--dry-run` cannot be combined with `-y` or `--yes`.

## Dependencies and context

Dependencies are enforced at the narrowest useful boundary:

- `git` is the suite's base dependency.
- `fzf` is required only by an interactive adapter. Help and a complete
  non-interactive command do not require it.
- Authenticated `gh` is required only by `git-issues`, `git-prs`,
  `git-pr-create`, `git-pr-checkout`, and `git-repo-create`.
- Git transport credentials and a configured remote are checked only by the
  remote action that needs them.
- An editor, pager, `delta`, or `diff-so-fancy` is optional and affects only
  the action that consumes it.

`clean-remote-merged` currently uses Git transport rather than the GitHub API;
it therefore must not require `gh` unless its implementation is deliberately
migrated to an API operation and the inventory is updated.

The top-level menu does not reject the caller merely because the current
directory is outside a repository. `git-repo-create`,
`git-identity-switcher --status`, and a global identity switch are valid
without one. Repository-only entries are annotated as unavailable, while the
remaining actions stay discoverable. The dispatcher and public command repeat
the authoritative context check.

Missing optional tools annotate only affected entries using text such as
`missing: gh`; color or a glyph is never the sole signal. Dependency checks do
not launch an installer or authentication flow without a separate explicit
choice.

## Streams and exit statuses

Help, headings, prompts, progress, previews, status summaries, success
messages, warnings, errors, and layout-only blank lines go to stderr.

Native repository content is data and remains on stdout when a browser renders
it. This includes Git diff, show, blame, log, reflog, and tag content, plus a
pull-request diff. That output preserves the underlying tool's presentation;
it is not a stable machine-readable record schema. Commands that only report
suite status or perform a mutation leave stdout empty. Human suite UI must
never be mixed into native content.

A future structured data mode may emit stdout only after documenting and
testing an exact record schema.

| Status | Meaning |
| --- | --- |
| `0` | Success, deliberate cancellation, or a documented no-op |
| `1` | Operational failure, unmet precondition, refused unsafe request, or partial failure |
| `2` | Invalid arguments, unknown option, or unknown dispatch token |

An invoked tool's distinct status may be preserved when callers need it, but a
success or logging helper must never mask a failure. A failed Git mutation,
signature verification, `gh` operation, pager, or fzf invocation returns
non-zero.

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
Formatted display text is never reused as a branch, path, revision, issue,
pull-request, tag, or stash mutation target.

The menu order follows user risk and frequency:

1. context and read-only inspection;
2. common reversible local actions;
3. remote and advanced actions;
4. destructive cleanup and history rewriting last.

The top-level picker is single-select. Its plain header reports available
repository, branch, identity, remote, and `gh` context without exposing
credentials. Its exact active legend is:

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

## Completion contract

`completions/_git-menu` completes both:

- `git-menu <command> [command-specific arguments...]`;
- every loaded direct public command.

Nested and direct grammars are identical. Completion exposes all 39 tokens and
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
- stash `create`, `apply`, `pop`, `drop`, and `branch` action grammars;
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

Pull and fetch operations download reviewed refs into an invocation-owned
temporary namespace with implicit ref mappings, tags, pruning, submodules,
`FETCH_HEAD`, commit-graph writes, and maintenance disabled. Fetched OIDs must
match the frozen remote snapshot before canonical tracking refs are promoted
with compare-and-swap updates. Temporary refs are removed with exact OID
leases.

Fetch and pull do not require a single push URL: their reviewed fetch source
is independent of publication configuration.

Multiple cherry-picks run as one native Git sequence in oldest-first order.
After a conflict, continue and skip retain the remaining reviewed commits;
abort restores the start of the sequence. Stash deletion, discard, and restore
stop before later targets on interruption (`130` or `143`), preserve that
status, and report completed, failed, and unattempted targets. Ordinary target
failures still allow independent selected targets to run.

GitHub writes re-fetch the issue, pull request, repository, or branch state
after confirmation. Multi-target writes run sequentially unless concurrency is
proven safe, retain the association between each identifier and result, and
return non-zero when any required operation fails.

After an accepted pull-request merge request, `git-prs` reads the PR once more
and verifies the reviewed identity and head. It reports a completed merge only
for `MERGED`. An unchanged `OPEN` PR is reported as an accepted request still
pending on GitHub, where checks or a merge queue may defer completion. A closed
unmerged PR, changed head, or unreadable final state returns nonzero and asks
for inspection before another attempt. ZDX does not poll or resubmit the write.

No Git path uses `eval`, computed shell text, or `sh -c` with selected data.
Pager and diff-viewer composition uses command arrays or fixed cases.

## Resolved migration findings

The findings below preserve the audited legacy evidence and the implemented
resolution. They are regression history, not expected failures. Production
behavior and the shared documentation are aligned at this snapshot.

| ID | Audited legacy behavior | Implemented resolution |
| --- | --- | --- |
| `GIT-EF-01` | `git-menu` and `_git_dispatch` dropped every argument after the command token | Nested routing forwards `"$@"` exactly, including empty and leading-dash arguments, and is equivalent to direct invocation |
| `GIT-EF-02` | Unknown dispatcher tokens returned `1`; top-level unknown options were treated as command names | Invalid options and dispatch tokens fail before probes with status `2` |
| `GIT-EF-03` | Only `git-identity-switcher` had a parser and help, and invalid arguments returned `1` | Every public command has direct help, validates its grammar first, and uses status `2` for invalid input |
| `GIT-EF-04` | Top-level help and human-only blank lines or tool output reached stdout | Help and human UI use stderr; stdout is reserved for documented data |
| `GIT-EF-05` | Logging always emitted ANSI, including raw color in fzf chrome | Terminal-aware Git helpers and the local fzf wrapper honor `NO_COLOR` and `TERM=dumb` |
| `GIT-EF-06` | Failed fzf, Git, `gh`, and verification operations could be mistaken for cancellation or masked by logging | Known picker cancellation is normalized to `0`; operational and tool statuses propagate |
| `GIT-EF-07` | The top-level menu required a repository before opening | The menu opens anywhere, computes repository context once, annotates repository-only labels, and preserves canonical command fields |
| `GIT-EF-08` | The shared picker advertised inaccurate keys and owned Git behavior through `_tk_*` helpers | Git owns its wrapper, text-first context, and invocation-specific keyboard legend |
| `GIT-EF-09` | Menu-row helpers accepted delimiters and controls | Three-field row helpers validate every field and fail closed with status `2` |
| `GIT-EF-10` | Completion exposed 34 of 39 tokens without direct bindings or contextual grammar | Nested and direct completion freeze all 39 tokens and bounded command-specific contexts |
| `GIT-EF-11` | Loading could fall back to an unrelated home installation and depended on generic state | Loading derives one exact root, uses owner sentinels, fails closed, and supports a clean retry |
| `GIT-EF-12` | Pager, preview, auth, and cleanup paths used `eval`, dynamic shell snippets, or reparsed display rows | Arrays, typed records, opaque identifiers, and post-selection validation keep data out of shell programs |
| `GIT-EF-13` | Destructive paths lacked consistent plans, non-interactive controls, revalidation, dry runs, and partial-failure status | High-risk local, remote Git, and GitHub paths implement the mutation safety sequence |
| `GIT-EF-14` | `clean-remote-merged` required authenticated `gh` for a Git transport operation | It depends on Git and the configured remote, not the GitHub API |
| `GIT-EF-15` | Tests did not freeze public surfaces, streams, statuses, direct completion, or menu safety boundaries | Contract and interface suites freeze those boundaries and run production code in isolated Zsh sandboxes |
| `GIT-EF-16` | The guide advertised an absent direct PR number, token display, and a command outside the inventory | Direct PR-number checkout is implemented; the guide now describes redacted auth status and lists only commands owned by Git |

## Verification files

| File | Contract boundary |
| --- | --- |
| `test/fixtures/git-public-commands.tsv` | Required frozen 39-command inventory, module ownership, risk, and capability metadata |
| `test/git_contract.bats` | Exact fixture, module, menu, help, dispatcher, nested-completion, and direct-completion parity |
| `test/git_interface.bats` | Exact routing and timing, all direct help streams, outside-repository annotations, standalone and double sourcing, exact-root loader failure and retry, `NO_COLOR`, row validation, and fzf behavior |
| `test/git_safety.bats` | Credential redaction, non-TTY refusal, post-review configuration revalidation, literal pathspec isolation, identity-data non-execution, renamed-file history, and exact PR OID comparison |
| `test/git_github_safety.bats` | Push-remote precedence, local PR head naming, exact single push-URL enforcement, and deny-by-default GitHub write calls |
| `test/git_pr_merge_recovery.bats` | Verified merge completion, accepted pending requests, changed or unreadable final states, backend failure, and declined authorization |
| `test/git_remote.bats` | Disposable local-remote verification for exact pushes, isolated fetch and pull, tag publication and deletion, and leased branch cleanup |
| `test/git_sync_recovery.bats`, `test/git_tag_recovery.bats` | Independent fetch configuration, exact publication destinations, absence leases, moved local tags, and rejection of multiple push URLs before and after review |
| `test/git_local_recovery.bats` | Multi-commit sequence ordering, conflict continuation and complete abort, cancellation, and interruption versus ordinary failure in local batches |
| `test/git_identity.bats` | Identity status and local/global profile behavior |
| `test/git_ws.bats` | Existing legacy Git/workspace compatibility checks; must not become permission to expand cross-suite coupling |
| `test/lazy_loading.bats` | Lazy and eager loading plus caller-owned `ZSH_CUSTOM` preservation |

Focused GitHub verification uses a deny-by-default `gh` mock that records every
argument and fails unexpected writes. Git tests may use a real disposable
repository inside the BATS sandbox, but never mutate the repository under test.
Remote deletion, force push, issue deletion, pull-request merge, and repository
creation use isolated mocks unless a separately documented manual smoke test
targets a disposable remote.

The contract suite must derive and compare surfaces rather than copy a second
executable allowlist. Interface tests capture stdout and stderr separately and
exercise production code in Zsh. Any new high-risk regression test covers
cancellation, dry run, non-interactive refusal, protected refs, leading-dash and
newline-containing names, post-confirmation changes, and partial failure.

Final acceptance requires the focused Git tests, `zsh -n` for every modified
Zsh file, and `just check`. Because the Markdown hook can rewrite files, inspect
the diff and repeat the gate after any automatic change.

## Implemented migration sequence

1. Added the fixture and contract assertions for the audited surface.
2. Replaced fallback loading and false sentinels with one source-derived loader
   root and optional core wrappers.
3. Established Git-owned logging, confirmation, row, dependency, dispatch, and
   fzf primitives.
4. Fixed exact argument forwarding, invalid status `2`, stderr-only help, and
   nested and direct completions.
5. Migrated read-only browsers and reversible local actions to typed records
   and safe previews.
6. Migrated destructive local history, branch, stash, tag, and file workflows
   behind plans, confirmation, and revalidation.
7. Migrated remote Git and GitHub writes with exact targets, sequential result
   accounting, and deny-by-default verification.
8. Updated this suite contract, shared guide, assurance wording, and focused
   verification, closing the integration item tracked by `GIT-EF-16`.

Every phase keeps the 39-token inventory stable unless a deliberate public
change is approved and synchronized across every surface.

## Maintenance triggers

Update this contract, its fixture, and focused tests whenever:

- a public command, flag, positional argument, or compatibility alias changes;
- an action changes risk class or gains a destructive, remote, or multi-target
  mode;
- a new dependency, authentication boundary, remote API, pager, or preview
  program is introduced;
- a menu row, fzf binding, keyboard legend, record schema, or completion
  grammar changes;
- Git identity or workspace ownership moves between suites;
- a new persisted credential or configuration field can reach output;
- a real-host or real-GitHub verification expands the supported baseline.
