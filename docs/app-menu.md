# App suite contract

This document freezes the public App interface and records the executable-code
boundary implemented by `functions/app-menu.zsh`, `functions/app-common.zsh`,
and `functions/app/app-tasks.zsh`.

## Public surface

The canonical commands are:

| Command | Purpose |
| --- | --- |
| `app-list` | Emit the bounded task inventory as typed tab-separated data |
| `app-run` | Rediscover and run one exact task through a fixed backend |

`app-menu` with no arguments opens the task browser. `-m|--multi` permits a
reviewed ordered selection. It also accepts either canonical command followed
by that command's unchanged arguments. Invalid syntax returns `2`; picker or
confirmation cancellation returns success without executing project code.

The fixture `test/fixtures/app-public-commands.tsv` freezes the direct surface.
The interactive browser is an intentional content-browser exception to the
three-field command-menu model: every task row uses
`label|app-run|description|index`, and the index resolves only into the current
private task snapshot. `app-list` powers inspection and is not itself a task
row.

The browser shows the task label and its backend, descriptor filename, and
workspace name. It distinguishes the current directory from the repository
root even when both directories have the same name. Action labels distinguish
running a task, starting or removing a Compose stack, and inspecting service
status or logs. The four-line bottom
preview repeats the selected task metadata in full when the list is narrow;
`Ctrl-/` toggles those details. It never reads or displays project script bodies.
The current directory appears above the keyboard legend, and `Enter review`
leads to the unchanged execution plan and authorization. Multi-selection adds
`Tab mark` and identifies the existing selection-order execution behavior.

## Command grammar

```text
app-list

app-run --backend BACKEND --task TASK
        [--action ACTION] [--directory DIRECTORY]
        [--dry-run] [--yes]
```

`BACKEND` is one of `just`, `npm`, `pnpm`, `yarn`, `bun`, `make`, or
`compose`. Non-Compose backends accept only the `run` action. Compose accepts
`up`, `down`, `ps`, `up-service`, `restart-service`, and `logs-service`.
The whole-project actions `up`, `down`, and `ps` require `--task all`; service
actions require the exact discovered service name.

`app-list` writes:

```text
backend<TAB>task<TAB>action<TAB>workspace<TAB>descriptor
```

UI, plans, warnings, summaries, and help remain on stderr.

## Discovery and execution boundary

Discovery examines only the canonical current directory and, when different,
its canonical Git root. Within each workspace it accepts one direct-child
descriptor for each supported family:

- `Justfile` or `justfile`;
- `package.json`;
- `Makefile` or `makefile`; and
- `compose.yaml`, `compose.yml`, `docker-compose.yaml`, or
  `docker-compose.yml`.

The workspace and every ancestor must be protected against replacement by an
untrusted user. A descriptor must be an owned, singly linked, non-symlink
regular file without group or other write permission and no larger than
2 MiB. Discovery caps the combined inventory at 512 tasks and 1 MiB of typed
records. Task tokens are grammar-checked and cannot begin with an option.
Node routing accepts at most one safe lockfile family; ambiguous package
manager markers fail closed instead of relying on precedence.

Direct `app-run` lookup and task revalidation inspect only the requested
backend family. A malformed unrelated descriptor or its missing parser cannot
block a valid task. Node tasks still validate the complete lockfile-family
selection. The full `app-list` and browser inventories remain strict: a
descriptor failure prevents publication of an incomplete inventory.

The descriptor's device, inode, size, modification time, mode, owner, link
count, and SHA-256 content digest form the frozen task identity. After
selection or direct lookup, App rediscovers the task and compares that complete
record before authorization and immediately before execution.

App never executes a discovered command string. A fixed `case` maps each
validated record to an argument-vector invocation of `just`, a selected Node
package manager, `make`, or `docker compose`. Package script bodies and
descriptor comments are not displayed, interpolated into previews, or passed
to a shell by ZDX. Compose log inspection is finite (`--tail 100`) rather than
an unbounded follow process.

## Authorization and interactive behavior

Task descriptors contain project-defined executable code with effects that ZDX
cannot classify generically. Every invocation shows the exact workspace and
fixed backend argument vector, including the exact descriptor path where the
backend accepts one. `--dry-run` performs discovery and revalidation without
execution. A terminal invocation asks for confirmation; non-interactive
execution requires `--yes`, which bypasses only that prompt.

The task picker runs synchronously in the terminal foreground. Its output is
captured in an owner-only, bounded, invocation-owned file below a validated
temporary parent. Every temporary result must first match the expected direct
child name and owned object type before it is opened or removed. The selection
must match the current row snapshot, and a non-zero picker exit may not carry
selection data. Multi-selection authorizes once, executes sequentially,
continues after an ordinary individual failure, reports the failed invocation,
workspace, and a command to review it before retrying, and returns non-zero if
any task failed. Execution or revalidation interruption (`130` or `143`) stops
later tasks, reports the completed and unstarted counts, and preserves the
interruption status. Previously executed project effects are not rolled back.

## Dependencies and residual limits

Only the backend selected for a task is required at execution. Reading
`package.json` requires an installed `python3`; it runs a fixed isolated JSON
parser and never imports project modules. `sha256sum` or `shasum` is required
for descriptor identity.

Task execution intentionally transfers authority to code already present in
the reviewed project descriptor. ZDX does not sandbox a recipe, package
script, Make target, Compose image, or backend configuration, and cannot undo
its external effects. Descriptor identity does not freeze every file the task
backend may read. A hostile process with the same EUID may still race the final
userspace check, and user namespaces retain the system-root ownership caveat
documented in `security-assessment.md`.

Focused coverage lives in `test/app.bats`, `test/app_contract.bats`,
`test/app_safety.bats`, `test/app_recovery.bats`, and
`test/menu_master_app_presentation.bats`. Live package managers,
container engines, and cross-platform behavior remain manual smoke-test
boundaries.
