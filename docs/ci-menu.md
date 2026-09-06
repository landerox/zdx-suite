# CI suite contract

This document defines the implemented public contract for `ci-menu`. The
repository-wide engineering, menu, loader, testing, and security rules remain
authoritative in [`development.md`](development.md),
[`menu-spec.md`](menu-spec.md), [`headers.md`](headers.md),
[`testing.md`](testing.md), and
[`security-assessment.md`](security-assessment.md).

Implementation baseline: 2026-07-26.

## Ownership

The CI suite owns repository-bound GitHub Actions inspection, workflow
dispatch, workflow-run cleanup, deployment cleanup, release cleanup, and
notification state associated with the current repository.

It does not own local or remote Git tags, GitHub issues, or pull requests.
Those resources belong to the Git suite. The historical `ci-clean-tags` and
`ci-clean-issues` names remain public compatibility adapters, but contain no
independent lifecycle implementation:

```text
ci-clean-tags   -> git-menu git-tag-list
ci-clean-issues -> git-menu git-issues
```

The adapters emit a deprecation warning and preserve the Git owner's result.
They do not source Git-private helpers.

## Architecture and loading

```text
functions/ci-menu.zsh
  -> functions/ci-common.zsh
    -> functions/ci/ci-actions.zsh
    -> functions/ci/ci-clean.zsh
```

The entrypoint derives one module root from its own path and loads only the
exact readable, non-symlink files below that root. It has no home-directory
fallback and no dependency on `git-common.zsh`. A failure names the exact
module, preserves its status, removes temporary loader state, and leaves
`_CI_MENU_SOURCED` unset.

Sourcing defines functions and state only. It does not inspect a repository,
contact GitHub, authenticate, open `fzf`, or mutate local or remote state.
Repeated sourcing is silent and idempotent.

## Frozen public surface

The fixture [`../test/fixtures/ci-public-commands.tsv`](../test/fixtures/ci-public-commands.tsv)
freezes eight public command tokens:

| Command | Effect | Operational boundary |
| --- | --- | --- |
| `ci-status` | Read-only | Current repository and authenticated `gh` |
| `ci-run` | Remote-code execution | One active workflow and one matched branch |
| `ci-clean-actions` | Destructive remote mutation | Exact non-latest run IDs |
| `ci-clean-deployments` | Destructive remote mutation | Exact non-latest deployment IDs |
| `ci-clean-releases` | Destructive remote mutation | Exact non-latest release IDs |
| `ci-clean-notifications` | Remote mutation | Exact repository notification thread IDs |
| `ci-clean-tags` | Delegated | Public Git tag manager |
| `ci-clean-issues` | Delegated | Public Git issue manager |

The fixture, loaded functions, dispatcher, menu, help, direct completion
bindings, and nested completion entries must agree on this inventory.

## Direct grammar

```text
ci-status [--limit N] [--list]
ci-status [--limit N] --run ID

ci-run [--workflow ID|PATH] [--ref BRANCH] [--dry-run] [--yes]

ci-clean-actions [--run ID]... [--limit N] [--dry-run] [--yes]
ci-clean-deployments [--deployment ID]... [--dry-run] [--yes]
ci-clean-releases [--release ID]... [--dry-run] [--yes]
ci-clean-notifications [--thread ID]... [--dry-run] [--yes]

ci-clean-tags
ci-clean-issues
```

Every public parser handles `-h|--help`, invalid flags, missing values,
cardinality, numeric bounds, and incompatible flags before a repository,
dependency, authentication, or network probe. Unknown or invalid input returns
`2`. Repeated exact target IDs are rejected, and each cleanup accepts at most
100 direct targets. `--dry-run` and `--yes` are mutually exclusive.

When exact target flags are omitted, the command uses interactive foreground
selection. A non-interactive mutation is possible only with exact target
flags and `--yes`, or as a non-mutating dry run.

## Repository and authentication boundary

An operational command requires:

- Git and a current worktree;
- an authenticated GitHub CLI;
- Python 3 for strict JSON schema validation;
- `timeout` or `gtimeout` for read-only GitHub probes;
- `head` for pre-capture byte ceilings; and
- `fzf` only when interactive selection is requested.

The suite resolves the repository through `gh repo view` into an opaque
repository ID, host, `owner/name`, and canonical local root. It validates every
field before use. Remote API calls carry the frozen host and repository name
explicitly instead of relying on whichever repository the process might infer
later.

Before a write, the suite verifies that the current worktree root is unchanged
and re-fetches the frozen repository ID through its explicit GitHub target.
Each selected resource inventory is then fetched again and the complete
validated record must still match and remain unprotected.

## Bounded records and streams

GitHub JSON is treated as untrusted data. The suite validates type, cardinality,
field length, control characters, identifiers, repository association, and
record bounds before any record reaches stdout, `fzf`, a plan, or a mutation.
Invalid batches fail closed; partially valid data is not published.
Temporary picker results must also match the expected owned direct-child name
before they can be opened or removed. A non-zero picker exit carrying record
data is an integrity error, not a cancellation.

Every internal inventory record carries a trailing SHA-256 identity over its
validated raw semantic fields. That identity is never rendered by a picker or
plan and is removed from the public `ci-status --list` stream. It lets
post-review revalidation detect changes even when two sensitive-looking remote
values are both displayed as `[redacted]`. Duplicate resource IDs are rejected
as an invalid batch.

Read-only API probes have a 20-second deadline and are piped through a
`maximum + 1` byte guard before shell capture, with at most 2 MiB accepted.
The direct `ci-status` detail view has a 30-second deadline. Inventory bounds
are:

| Inventory | Record bound |
| --- | --- |
| Workflow runs | Caller-selected `1..100` |
| Workflows | 100 |
| Deployments | 100 |
| Releases | 100 |
| Repository notifications | 100 |

`ci-status --list` emits one validated TSV record per run:

```text
run-id<TAB>workflow-id<TAB>state<TAB>workflow-name<TAB>branch<TAB>created-at<TAB>event<TAB>display-title
```

`ci-status --run ID` reads that exact run through the repository-bound
[workflow-run endpoint](https://docs.github.com/en/rest/actions/workflow-runs#get-a-workflow-run).
Its response must match the numeric run ID, frozen repository `node_id`, and
exact `owner/name` before the native detail view starts. REST `node_id` is the
[global GraphQL identity](https://docs.github.com/en/graphql/guides/using-global-node-ids)
used by repository discovery. Exact inspection shares the inventory schema,
byte ceiling, and redaction policy. `--limit` bounds recent listing and
interactive discovery; an explicit ID can inspect an older run outside that
window. This read-only lookup does not expand cleanup eligibility or remove
its inventory limits and newest-run protection.

`ci-status --list` is the suite's only structured stdout mode. A selected `gh run view`
retains its native read-only stdout. Help, plans, warnings, progress, errors,
and mutation results use stderr.

Sensitive-looking remote display fields are redacted before they enter a
record rendered by ZDX. The suite does not print authentication output, tokens,
remote URLs, request headers, raw API errors, or environment values.

## Interactive boundary

The top-level menu uses fixed `label|command|description` records. Rows reject
delimiters and control characters, selection must belong to the current
snapshot, and the dispatcher is an explicit `case`.

The compact presentation follows [`menu-spec.md`](menu-spec.md). The directory
and keyboard legend occupy separate header lines; `Ctrl-/` toggles command
details. Inspection and repository actions precede Git adapters, with remote
deletion last. Section details describe the group without a command token.

Every picker runs `fzf` synchronously in the terminal foreground. Selection
stdout is captured in an owner-only, bounded, invocation-owned result file
below a validated temporary root. The file and directory identities are
checked before reading and before cleanup. Cancellation statuses `1` and `130`
return success without a mutation.

Remote data is never interpolated into an `fzf` preview program. Content
pickers disable previews and omit internal record identities from their visible
fields; the top-level preview contains only fixed, suite-owned command records.

## Mutation plans

Every CI-owned write follows this sequence:

1. Resolve and validate the current GitHub repository.
2. Fetch one bounded typed inventory.
3. Resolve exact numeric IDs from direct flags or a snapshot-bound picker.
4. Reject duplicates, missing targets, protected targets, and empty plans.
5. Show the repository, complete selected records, count, and consequence.
6. Return after `--dry-run`, or require confirmation immediately before use.
7. Fail closed without a terminal unless `--yes` is present.
8. Revalidate the repository and complete selected records.
9. Execute fixed API endpoints sequentially.
10. Report each failure and return non-zero for any partial transaction.

`--yes` skips only confirmation. It never skips schema validation, repository
identity, target protection, post-review revalidation, or exact endpoint
construction. Mutating API calls are deliberately not wrapped in a timeout:
once accepted, they run to their reported result. Ordinary target failures
allow subsequent reviewed targets to proceed. An interrupted backend or
revalidation (`130` or `143`) stops subsequent targets, preserves that status,
and reports the remaining unattempted count. The current remote operation may
already have been accepted; inspect its result before retrying. No interrupted
mutation is automatically retried.

### Workflow dispatch

Only an active workflow from the current 100-record inventory is dispatchable.
The target is frozen by numeric workflow ID even when the caller specifies its
validated `.github/workflows/*.yml` path. The ref must be an exact local branch.
The suite resolves its local commit and the corresponding GitHub branch through
the repository-bound API; both commits must match before the plan is shown and
again after confirmation.

Dispatch executes repository workflow code under its configured GitHub
permissions and secret availability. The plan states that remote-code effect
before authorization; `--yes` is appropriate only after the caller trusts the
reviewed workflow and ref. A failed or interrupted dispatch does not prove
that GitHub rejected it; the suite reports that acceptance could not be
confirmed and preserves an interruption status.

GitHub resolves the named branch again while accepting `workflow_dispatch`.
Another actor can move the remote branch between the final comparison and
GitHub acceptance. The plan states this residual semantic explicitly rather
than claiming an unavailable remote lease.

### Run cleanup

Runs are ordered by creation timestamp and ID. The newest run for every numeric
workflow ID is protected. Only records marked non-latest in both the original
and post-confirmation inventories can be deleted.

### Deployment cleanup

The newest deployment per environment is protected. Each selected deployment
is first marked inactive and then deleted. GitHub exposes these as two API
transactions; deactivation can succeed while deletion fails. The suite reports
that partial outcome and returns non-zero. An interrupted deactivation skips
deletion; an interrupted deletion explicitly reports the completed
deactivation and stops subsequent deployments.

### Release cleanup

The newest release in the bounded repository inventory is protected. Release
deletion uses the numeric release ID. Associated Git tags are outside the CI
plan and are never deleted implicitly.

### Notification cleanup

Only unread threads returned by the current repository-specific endpoint are
eligible. Every record must repeat the exact frozen `owner/name`. The final
write uses the exact numeric thread ID.

## Exit statuses

| Status | Meaning |
| --- | --- |
| `0` | Success, deliberate cancellation, dry run, or documented empty inventory |
| `1` | Operational failure, unsafe response, unmet precondition, or partial mutation |
| `2` | Invalid arguments, option combination, or dispatch token |
| `124` | A bounded read-only GitHub probe timed out where the distinction is preserved |
| `130` / `143` | An interrupted backend or revalidation; no subsequent cleanup target is attempted |

An unexpected `fzf` failure is operational failure, not cancellation.

## Verification and residual limits

Focused verification is defined in:

- `test/ci.bats`;
- `test/ci_contract.bats`;
- `test/ci_safety.bats`;
- `test/ci_recovery.bats`;
- `test/fixtures/ci-gh-mock.sh`;
- `test/fixtures/ci-public-commands.tsv`.

The GitHub fixture is deny-by-default for writes and records exact arguments.
It does not contact GitHub or mutate the repository under test.

Real-host acceptance still requires a disposable GitHub repository with
Actions, deployments, releases, and notifications. Mocked tests cannot prove
remote permission configuration, GitHub Enterprise API compatibility, or
concurrent changes by another authorized actor. GitHub may materialize one API
response internally before ZDX applies its byte bound. The unavoidable final
network race after the last userspace revalidation also remains.

Temporary-root ownership checks compare numeric UIDs. As elsewhere in ZDX,
platforms that expose an overflow UID for an unmapped namespace require manual
acceptance testing before interactive capture is trusted there.

Last reviewed: 2026-09-06.
