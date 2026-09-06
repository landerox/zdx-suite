# Developer suite contract

This document is the public contract for the `dev` suite. It defines the frozen
command surface, the ownership boundaries, the safety model for cleanup and
update workflows, the remote-code policy, and the persisted state layout.

The general engineering contract is in [`development.md`](development.md), the
interactive UI contract is in [`menu-spec.md`](menu-spec.md), and the file and
loader conventions are in [`headers.md`](headers.md). Where this document and
those disagree, they win.

Audit and migration baseline: 2026-07-25. Last full contract review:
2026-09-05.

## Ownership

The `dev` suite owns **project-scoped** maintenance for the working directory:
dependency specifiers, lockfiles, quality gates, tests, security scans,
distribution artifacts, and project-local cleanup.

It does **not** own:

| Domain | Owner | How `dev` relates to it |
| --- | --- | --- |
| Virtual environments and Python runtimes | `py` (`py-menu`) | Nine `venv-*` entries and runtime installation without an existing `.venv` are forwarded to `py-menu`; Dev retains only its documented locked replacement transaction for an existing project `.venv` |
| Docker lifecycle and pruning | `docker` (`docker-menu`) | `clean-docker` and `docker-prune-all` are deprecated bridges that call `docker-menu docker-clean` |
| Host packages, services, and system cleanup | `sys` (`sys-menu`) | `dev-update-toolchain` delegates the targeted `uv` operation; ambient `pip` is never invoked; Terraform and TFLint report package-manager ownership |
| Cross-suite dependency installation | `zdx-doctor` | `dev` explains how to install a missing tool and never installs it |

A forwarded command is a documented delegation, not a second implementation.
New work MUST NOT reintroduce a general `dev`-local implementation of a
delegated lifecycle. The existing `.venv` replacement is a narrow project
maintenance exception: it is coupled to the current `pyproject.toml` and
`uv.lock`, and it is not exposed as another environment lifecycle command.

## Architecture

```text
functions/dev-menu.zsh          public loader, router, menu model
  -> functions/dev-common.zsh   logging, prompts, capabilities, dispatch, fzf
    -> functions/dev/dev-state.zsh      validated state dirs, backups, restore
    -> functions/dev/dev-report.zsh     Markdown report buffer
    -> functions/dev/dev-pypi.zsh       PEP 503, pyproject parsing, PyPI queries
    -> functions/dev/dev-export.zsh     dependency export, package build
    -> functions/dev/dev-update.zsh     specifiers, lockfile, toolchain, runtime
    -> functions/dev/dev-checks.zsh     linters, type checkers, tests, health
    -> functions/dev/dev-security.zsh   pip-audit, Bandit
    -> functions/dev/dev-clean.zsh      planned, confirmable removal
    -> functions/dev/dev-profiles.zsh   reusable named task selections
    -> functions/dev/dev-compat.zsh     deprecated unprefixed names
```

Load order is explicit in the entrypoint. `dev-compat.zsh` loads last because
every wrapper it defines forwards to a command declared by an earlier module.

## Invocation order and effect metadata

Argument parsing always precedes operational probes. The dispatcher does not
preflight dependencies before calling a public command: each public function
first accepts `--help` or rejects invalid arguments, then asks for its first
required file, project capability, or executable. The central dependency
metadata remains useful for menu annotations, but those annotations are
advisory; the command performs the authoritative check at first use.
Aggregates have no blanket backend requirement: a missing `uv` must not block
an independent Terraform ownership inspection or cleanup.

This order has two user-visible guarantees:

- `dev-menu <command> --help` works even when the command's backend is absent;
- a malformed invocation or invalid suite-owned option returns status `2`
  without probing the project, network, package manager, or optional tools.

Commands whose contract explicitly forwards arguments to pytest, TFLint, or
another backend still leave those backend-owned options for that tool to
validate after the suite parser has consumed its own flags.

Commands documented as argument-free share one exact parser: zero arguments
runs the command, exactly one `-h` or `--help` prints usage, and every other
vector returns status `2` before an operational probe.

Commands also carry an explicit batch-eligibility classification.
`dev-menu --multi`, `dev-profile-save`, and `dev-profile-run` all enforce the
same allowlist of independent, argument-free tasks. Nested orchestrators,
formatters that rewrite files, exports, builds, cleanup, environment lifecycle,
and profile management are excluded. Batch-eligible means independently
runnable with no explicit suite-owned source mutation; it does not promise
that a test, compiler, configured plugin, or project hook executes no project
code or creates no documented cache or build artifact. A selected row is
checked again before dispatch, while a stored profile is validated in full
before its first task runs. A forged row or legacy profile therefore cannot
widen the executable batch surface.

## Interactive selection

The command menu uses the common compact presentation in
[`menu-spec.md`](menu-spec.md): 80% height, a four-line bottom description,
and `Ctrl-/` to toggle details. The profile-save task selector uses the same
details control. Labels distinguish dependency edits, lockfile and environment
updates, and project cleanup; forwarded environment actions retain Py's
documented limitations.

Every Dev picker — the top-level menu, `--multi`, the interactive
confirmation prompt, the profile-save task selector, and the profile run and
delete pickers — runs `fzf` synchronously in the terminal foreground through
`_dev_fzf_capture`. Selection stdout is captured in a private, owner-only,
bounded (64 KiB) invocation-owned result file below a validated temporary
root: a current-user directory without group/world write access, or a
root-owned sticky shared directory. A child file-size limit caps growth while
`fzf` is writing, and identity plus size are checked again before reading. The
exact `fzf` status is preserved, a failed picker cannot carry selection data,
and the result file is removed by exact identity on every path.

A selected record must also belong to the invocation's row snapshot. The
single-select menu refuses a selection outside that snapshot; `--multi` and
the profile-save selector skip such rows with a warning after the
batch-eligibility allowlist has already excluded ineligible commands. The profile run and
delete pickers revalidate the returned name against the discovered profile
inventory.

Menu capability annotations are built from an invocation-local probe cache.
Each shallow command-or-path availability key runs at most once per rendered
snapshot; no result persists into a later menu invocation. Rendering does not
parse TOML, start Python, or execute a project tool. These annotations remain
advisory: no missing-tool annotation is not a readiness guarantee. They never
replace the public command's post-parser capability checks.
Menu section and entry helpers also reject pipe, newline, and NUL characters,
so every emitted record remains an exact three-field fzf record.

## Public command surface

The surface is frozen by `test/fixtures/dev-public-commands.tsv` and checked by
`test/dev_contract.bats`, which proves that these five sets are identical:

1. non-sentinel command fields in the top-level menu;
2. dispatcher arms;
3. commands named by `dev-menu --help`;
4. entries in `completions/_dev-menu`;
5. rows in the contract fixture.

49 commands are frozen: 40 owned by `dev` plus 9 forwarded to `py`.

Only the `dev-menu` entrypoint is registered as a lazy stub by the core runtime.
`dev-menu <command> [arguments...]` therefore works from a cold shell, while
the individual public functions become callable once the suite has loaded (or
immediately under `ZDX_EAGER_LOAD=1`). Workspace is a deliberate exception
that registers its direct commands too. Scripts should use the Developer
entrypoint form.

### Inspection (read-only unless `--report`)

| Command | Behavior |
| --- | --- |
| `dev-check-health` | Diagnose Python/uv environment, lockfile, hook, and toolchain state. Returns `1` on an issue; a project with no Python/uv marker is a clean no-op. |
| `dev-check-outdated` | Compare declared direct dependencies against `.venv`, explicitly passing its interpreter and `UV_SYSTEM_PYTHON=0`. |
| `dev-check-licenses` | Report installed licenses; `--strict` classifies only the structured JSON `License` field. |

All three are read-only by default. `--report` additionally writes a private,
atomically published Markdown report. Project metadata parsing refuses
`pyproject.toml` above 2 MiB or a combined direct-dependency inventory above
1,000 entries. Structured license classification requires a JSON array whose
records contain string `Name`, `Version`, and `License` fields, classifies only
`License`, and refuses malformed JSON. Both table and JSON streams stop at
10 MiB plus one byte and fail before unbounded output is materialized.

Health applies when the project has `pyproject.toml`, `.venv`, `uv.lock`,
`.python-version`, or a discovered Python source file. Without any such marker,
it reports that Python/uv health is not applicable and returns `0` without
probing PyPI or treating absent Python metadata as a failure. Once a marker
exists, the full diagnostic remains strict.

### Quality gates

| Command | Mutates files? |
| --- | --- |
| `dev-run-all-checks` | May rewrite through configured hooks and create compiler artifacts such as `target/` |
| `dev-run-hooks` | Yes — hooks rewrite files by design; their runner is frozen and cannot sync implicitly |
| `dev-check-types` | No |
| `dev-run-ruff` | No — fixing/output flags are refused and `RUFF_OUTPUT_FILE` is removed from its environment |
| `dev-run-ruff-format` | Yes, by design |
| `dev-run-ty` | No |
| `dev-run-pyright` | No — `--createstub` is refused |
| `dev-run-eslint` | No |
| `dev-run-prettier` | No — verification only, never `--write` |
| `dev-run-clippy` | Yes — Cargo may populate `target/`; `--locked` prevents `Cargo.lock` changes and `--fix` is refused |
| `dev-run-shellcheck` | No |
| `dev-run-markdownlint` | Only with the explicit `--fix` flag |
| `dev-run-tflint` | No by default; `--init` may download plugins and requires explicit authorization |

`dev-run-markdownlint` passes `.config/markdownlint.yaml` explicitly when that
project-local file exists. Otherwise, Markdownlint retains its normal
configuration discovery behavior.

`dev-run-all-checks` accepts `--verbose`. Without it, each gate's output is
suppressed and only the result table is shown.

`dev-run-tflint` runs `tflint --recursive` without initializing plugins.
Plugin initialization is a separate remote-code action selected with `--init`;
it displays that effect and requires confirmation, or `--yes` in a
non-interactive shell. Initialization failure is returned and linting is not
reported as successful.

Read-only gate parsers reject backend flags known to enable source or state
rewrites, such as Ruff `--fix`, ESLint `--fix`/`--cache`, Prettier `--write`,
Pyright `--createstub`, Clippy `--fix`, and TFLint `--fix`. Clippy is
effect-classified as mutating because ordinary compilation still creates or
updates `target/`.

Quality gates, tests, configured hooks, and package builds are explicit local
trust boundaries. They can load project-controlled configuration or code even
when the Dev wrapper itself is classified read-only. `dev-run-hooks` can also
initialize hook environments, and `dev-run-all-checks` inherits those effects.

Bandit and ShellCheck share one NUL-safe project-file collector. It prunes
generated trees and nested repositories before traversal, propagates discovery
failure, caps each inventory at 512 files, and invokes each backend in batches
of at most 64 paths.

### Tests

`dev-run-tests` and `dev-run-coverage` require a real project `.venv` whose
interpreter reports that exact environment as `sys.prefix`. Both report a clean
no-op when the project declares no tests. Root detection recognizes
`pytest.toml`, `.pytest.toml`, `pytest.ini`, `.pytest.ini`, qualifying
`pyproject.toml`, `tox.ini`, and `setup.cfg` configuration in pytest precedence
order, in addition to conventional test filenames. A no-argument pytest run that
collects no tests (status `5`) is also a documented no-op; status `5` is
preserved when the caller supplied explicit pytest arguments.
`dev-run-coverage` accepts `--html` and `--fail-under=N`; every other argument
is forwarded to pytest unchanged. Tests execute pytest only through the exact
project interpreter or an executable proven to remain inside `.venv`.
Coverage additionally requires either `pytest-cov` or `coverage` to be
installed in that same environment; it never reports a plain pytest run as
successful coverage. None of these commands consults a global pytest,
coverage, or pre-commit executable.

### Security

`dev-run-audit` (`--fix`) and `dev-run-bandit` (`--high-only`).
Audit is an installed-environment inventory: its module must be importable from
`.venv`, and it never uses a global binary, declared-but-unsynced dependency,
overlay, or ephemeral environment. Bandit is a source-code gate and follows the
quality-gate runner policy: a declared dependency must be exact-project; only
an undeclared Bandit may fall back to a global binary or opt-in `uvx`.
`dev-run-audit --fix` shows the remediation effect and confirms before
upgrading `.venv`; non-interactive use requires `--fix --yes`.

### Dependencies and toolchain

| Command | Class | Notes |
| --- | --- | --- |
| `dev-update-deps-dry` | read-only | Equivalent to `dev-update-deps --dry-run` |
| `dev-update-deps` | mutating | Builds and fingerprints a private plan, confirms, backs up, atomically publishes, and re-locks only bumped packages |
| `dev-update-lock` | mutating | Refreshes `uv.lock`; never edits `pyproject.toml` |
| `dev-update-precommit` | mutating | Continues usable package and hook backends after a PyPI query failure; plans frozen revisions privately, rejects regressions, installs every planned hook environment, publishes atomically, reinstalls the Git hooks, and reports findings or incomplete updates |
| `dev-update-toolchain` | mutating | Delegates host `uv` maintenance to `sys`; never invokes ambient `pip` |
| `dev-update-python` | destructive | With an existing `.venv`, confirms before any uv mutation, stages a locked replacement, and publishes with verified rollback; without one, delegates installation to `py-menu` |
| `dev-update-terraform` | read-only | Proves and reports the `tfenv` or host package-manager workflow; Dev never executes `tfenv install latest` |
| `dev-update-tflint` | read-only | Proves and reports Homebrew ownership; otherwise prints the verified procedure |

`dev-update-deps` flags: `--dry-run`, `--yes`, `--verbose`, and one of
`--major-only`, `--minor-only`, `--patch-only`.

Specifier planning binds each change to an actual dependency string in
`project.dependencies`, `project.optional-dependencies`, or
`dependency-groups`. It matches normalized package names and handles several
requirements on one line, literal quotes, extras, and repeated declarations.
Comments, descriptions, unrelated tool settings, whitespace, and newline style
are preserved. Compound constraints and environment markers remain unchanged;
an unorderable version is skipped and an existing newer minimum is never
downgraded. The parsed candidate must match only the intended dependency
changes before publication.
At most 64 matching strings per package may be examined to bind source spans;
an excess is a planning failure before any live project-file change.

Terraform and TFLint ownership claims are bound to the canonical active
executable. A separately installed APT or Homebrew package never claims a
different binary that appears earlier in `PATH`. A tfenv claim requires the
resolved `tfenv` and `terraform` launchers to be siblings; inherited
`TFENV_ROOT` cannot manufacture ownership.

### Packaging and export

`dev-export-deps` (`--dev`, `--all`, `--output=FILE`, `-o FILE`, `--yes`),
`dev-build-package`, and `dev-backup-pyproject`.

`dev-build-package` invokes the project-selected PEP 517 build backend through
`uv build` or isolated `python3 -I -m build`. The backend is project-controlled
code. Its isolated `build-system.requires` dependencies can be resolved and
executed outside `uv.lock` before it writes `dist/` artifacts.

Dependency export requires project metadata and `uv export --locked`. It
deliberately has no `uv pip freeze` fallback: freezing the active environment
could include undeclared packages and would not represent the reviewed project
and lockfile. The uv format is `requirements.txt`. The default adds
`--no-default-groups` for production-only output; `--dev` adds exactly the
`dev` group while still excluding defaults, and `--all` selects
`--all-groups`.

### Python environments (forwarded to `py-menu`)

`venv-list`, `venv-create`, `venv-activate`, `venv-info`, `venv-rebuild`,
`venv-remove`, `venv-python-list`, `venv-python-install`, `venv-python-pin`.

### Task profiles

`dev-profile-run`, `dev-profile-save`, `dev-profile-list`,
`dev-profile-delete`. The save picker is generated from the live menu model, so
a new batch-eligible menu entry becomes selectable without a second
hand-maintained list. Saving and running use the same effect allowlist as
`dev-menu --multi`; the inventory is capped at 100 files, each profile at 8,192
bytes and 64 tasks.
The complete file is read through a stable descriptor, validated as a private
regular file, and accepted only when every stored token is batch-eligible.

### Destructive maintenance

`dev-clean-py`, `dev-clean-repo`, `dev-clean-terraform`, `dev-clean-all`, and
`dev-update-all`.

## Update transactions and aggregate authorization

`dev-update-all` freezes its applicable scope once, shows that aggregate
maintenance plan, and requests authorization before any mutating child
starts. The frozen scope is:

| Step | Runs when | Child command |
| --- | --- | --- |
| Host toolchain | always | `dev-update-toolchain` |
| Dependency specifiers | `pyproject.toml` exists | `dev-update-deps --yes` |
| Lockfile refresh | `uv.lock` exists | `dev-update-lock` |
| Pre-commit hooks | `pyproject.toml` and `.pre-commit-config.yaml` exist | `dev-update-precommit` |
| Terraform ownership | `terraform` is installed | `dev-update-terraform` |
| TFLint ownership | `tflint` is installed | `dev-update-tflint` |
| Project cleanup | always | `dev-clean-all [--yes]` |

A step whose project files are absent is listed as not applicable in the plan
and as skipped in the final summary; it is never counted as a failure. When
`pyproject.toml` exists, one PyPI reachability probe runs before the prompt
and its result is reused only within that aggregate invocation. A failure
blocks the direct dependency-specifier queries and counts that step as failed.
The lockfile and pre-commit workflows still try their configured backends:
uv may use another index or cached packages, and Git remotes are independent
of public PyPI. Pre-commit skips its package-specifier query when PyPI is
unreachable, retains that failure in its final result, and continues the
remaining stages. The plan displays this distinction before authorization.
A decline returns `0` without starting a toolchain, project-file, hook,
ownership inspection, or cleanup step. Interactive cleanup computes and shows
its exact target set later, then requests its own confirmation immediately
before removal; no second prompt is needed when that set is empty. `--yes`
explicitly authorizes both the aggregate and child prompts without bypassing
planning, identity checks, or validation. `--dry-run` invokes only the
dependency and cleanup previews, skipping the dependency preview when
`pyproject.toml` is absent.

The aggregate continues after independent failures, prints a per-step summary
(completed, failed with status, blocked, or skipped with its reason), lists
direct `dev-menu` commands to retry pending steps, and returns `1` when any
step failed. Retry commands preserve dry-run previews and require normal
confirmation for mutations. When other steps completed or were inapplicable, the core timing
message identifies partial failures while preserving the failure status.
It skips the pre-commit update only when the dependency
step reports an inconsistent lockfile: `pyproject.toml` was published, the lock
failed, and the exact rollback also failed. A dependency failure that left the
project files untouched or restored (PyPI unreachable, a refused backup, a
declined plan, a rolled-back lock) does not block the pre-commit update, and a
later successful lockfile refresh restores trust. `dev-update-deps` exposes
that state through `_DEV_UPDATE_DEPS_OUTCOME` (`unchanged`, `restored`,
`inconsistent`, `locked`, or `applied`) for orchestrators. This is
orchestration, not a global filesystem transaction: package managers,
downloaded runtimes, hooks, and other external tools retain their own side
effects and rollback capabilities.

Project-file changes do have exact transaction boundaries:

1. Dependency updates are constructed in an invocation-owned private workspace.
   The completed plan and live `pyproject.toml` identities are fingerprinted
   before authorization.
2. After authorization, the command creates and validates the exact
   invocation-owned backup before publishing the planned file atomically.
3. A lock failure restores that exact backup, including the original mode. A
   failed or unverifiable rollback remains visible and never produces a
   success message. A later sync failure leaves the published metadata and
   lockfile in place and reports that the environment may be partial; rolling
   back only one of those three objects would create a different inconsistency.
4. Pre-commit specifier changes follow the same plan, backup, publication, and
   lock-failure rollback sequence. Hook revisions are autoupdated with
   `--freeze` in a separate private candidate. An ordinary non-zero autoupdate
   result may still leave usable proposals, such as when one repository has
   incompatible hooks; these changes proceed through the complete guard and
   environment installation. A Git transport failure can abort upstream
   before it writes a candidate, so partial recovery is not guaranteed for
   every repository failure.
   Interrupted autoupdate statuses `130` and `143` abort publication.
   The guard permits changes only
   to revision lines, requires changed targets to be immutable Git object IDs,
   and retains an existing immutable revision when the proposed tag is older,
   incomparable, or moved to another object. An initial mutable non-version
   reference can be frozen only when its exact original label appears in the
   frozen provenance comment. Before atomic publication, the command validates
   the candidate and installs every planned hook environment (including hooks
   assigned only to `commit-msg` or `pre-push`). After publication and Git
   hook installation, it runs every applicable file-stage hook against all
   files with the published configuration and reports the result. Hook
   findings are project findings: they return status `1` but never discard
   the published revisions. An incomplete autoupdate or package query also
   returns `1` and prints a retry command without discarding validated updates.
   A lint finding or a fixer rewrite is not
   evidence that the frozen revision is unsafe, and refusing publication would
   leave the repository on stale hooks indefinitely. If the live configuration
   changes during the external update, ZDX refuses to overwrite it and retains
   the original snapshot for manual comparison; it cannot safely distinguish a
   tool write from a concurrent user or editor write.

The exact rollback guarantee covers a ZDX-published `pyproject.toml` whose lock
step fails. Hook configuration publication is compare-and-swap atomic; a live
file changed by another actor is never automatically replaced or rolled back.
`uv.lock`, the active environment, installed tools, and hook-managed files
remain external-tool effects; their owners may have changed them before
returning a failure.

Temporary update workspaces freeze the configured temporary root and workspace
identities. Cleanup first moves the proven workspace inode to an unpredictable
quarantine name, revalidates it, and only then removes it. A changed root or
workspace is retained for manual recovery instead of recursively removed.
The temporary root must be either safely owned by the current EUID or
root-owned with the sticky bit; a foreign-owned sticky root and a non-sticky
group/world-writable root are refused.

`dev-update-python` has a separate directory transaction for an existing
`.venv`. It requires `pyproject.toml` and `uv.lock`, refuses a link or
non-directory `.venv`, freezes project and environment identities, displays the
replacement plan, fingerprints both project inputs, and confirms before
`uv python install --upgrade <X.Y>` or another mutating uv command. A sole
simple `X.Y` project pin selects that minor; without a pin, the command derives
the current `.venv` interpreter minor.
Multiple pin files or values, exact `X.Y.Z` pins, and complex or ambiguous pins
are refused before mutation and delegated to
`dev-menu venv-python-pin <major.minor>`. A non-CPython `.venv` is likewise
refused and delegated to an explicit `venv-python-pin` selection because the
automatic patch-upgrade transaction supports CPython only. After authorization
it:

1. creates and validates a private mode-`700` workspace below the project, on
   the same filesystem;
2. revalidates the interpreter version and implementation, pin selection, and
   both input fingerprints after authorization, then checks both input
   fingerprints again immediately before the first uv mutation;
3. runs `uv python install --upgrade X.Y`, builds a new environment with
   `uv venv --clear --managed-python --python X.Y --relocatable <staged>`;
4. checks both input fingerprints again, then synchronizes through
   `UV_PROJECT_ENVIRONMENT=<staged> uv sync --all-groups --locked`;
5. verifies that the staged interpreter is CPython in the requested `X.Y`
   minor and revalidates both input fingerprints plus
   the project, original environment, and staging identities before either
   rename;
6. preserves the original inside the workspace, publishes the staged
   directory, and verifies the published identity;
7. restores the exact original after a publication failure when that identity
   remains trustworthy, otherwise retains the recovery workspace.

The explicit relocatable flag keeps standard console entrypoints and
activation scripts valid after the staging directory is renamed and removed.
It does not promise that arbitrary package scripts or binaries are relocatable;
see [uv's relocatable environment contract](https://docs.astral.sh/uv/reference/cli/#uv-venv--relocatable).

An interrupt between renames also retains the recovery workspace. After
success, the preserved original is removed only through validated quarantine.
When `.venv` is absent, the command performs no runtime mutation itself. It
delegates to `py-menu venv-python-install`, forwarding `--yes` when present, so
the owning suite selects, previews, and authorizes the runtime installation.
Because no version operand is forwarded, selection remains interactive even
with `--yes`. Unattended callers use
`dev-menu venv-python-install VERSION --yes` after reviewing that exact runtime.

The PyPI reachability probe is a bounded HTTPS `HEAD` request that reports
the most specific cause curl can prove: an HTTP status other than 200, a DNS
failure, a refused or unreachable TCP port, a timeout before TCP connected, or
a connection that was accepted while the TLS/HTTP exchange stalled. The last
case is the signature of large packets dropped by a VPN or tunnel with a
smaller MTU, so the probe also prints the `eth0` MTU remedy on WSL2, where the
guest never learns the tunnel MTU. `dev-update-precommit` uses this probe only
to decide whether its public-PyPI specifier query can run. Its Git children
receive invocation-local `GIT_HTTP_LOW_SPEED_LIMIT=1` and
`GIT_HTTP_LOW_SPEED_TIME=DEV_PYPI_TIMEOUT`, allowing Git to abort stalled HTTP
transfers through its [native low-speed controls](https://git-scm.com/docs/git-config#Documentation/git-config.txt-httplowSpeedLimit).
This is an HTTP stall limit, not a total operation deadline. SSH transports,
package-manager transactions, and hooks retain their own timeout policies;
ZDX does not kill an in-progress mutating transaction to enforce this limit.

Dependency and pre-commit update parsers require Python 3.11+ with `tomllib`.
After synchronization, pre-commit autoupdate, candidate validation, hook
execution, and installation run only through the exact project environment.
Test, coverage, and normal hook runs use the same provenance boundary and
never invoke `uv run`, so a missing project backend cannot fall through to
`PATH`. `dev-update-toolchain` delegates the targeted host `uv` update to
`sys-menu update-uv-system`; it does not probe or mutate an ambient Python or
`pip`, including an externally managed PEP 668 installation.

## Safety model for cleanup

Every `dev-clean-*` command implements the destructive sequence from
`development.md` in this order:

1. **Freeze and validate the root.** `_dev_scan_root` refuses `/` and the
   user's home directory before any target is calculated. The literal root may
   not be a symlink. Its resolved path, device, inode, and type are captured and
   matched against the open working-directory anchor.
2. **Compute the exact target set without mutating.** Discovery uses bounded,
   NUL-delimited `find` records, so filenames containing spaces or newlines stay
   data. It does not follow links and prunes `.git`, `*.git`, `.venv`,
   `node_modules`, `vendor`, `vendored`, and nested repository roots discovered
   from `.git` file or directory markers. Each discovery stream and nested
   repository-marker inventory stops at one beyond the configured target limit
   instead of materializing unbounded output. Associative first-seen
   deduplication preserves deterministic plan order. Each cleanup category is
   also capped after combining its bounded streams.
3. **Freeze each target.** Every candidate becomes a literal path relative to
   the original working-directory anchor plus its device, inode, and type. The
   workflow never recanonicalizes that relative target through a movable root.
   If the combined plan exceeds `DEV_CLEAN_MAX_TARGETS` unique targets, cleanup
   fails closed before displaying, confirming, or mutating.
4. **Show the plan.** The first 25 targets are listed with their type, then a
   count of the remainder.
5. **Stop for `--dry-run`.** No confirmation is requested and nothing is
   removed.
6. **Confirm immediately before execution.** A declined confirmation returns
   `0` and removes nothing. When no terminal is attached and `--yes` was not
   passed, the command **fails closed** with status `1`.
7. **Revalidate the root after authorization.** A renamed, replaced, or
   symlinked root stops execution before the first removal.
8. **Revalidate and report per target.** The target identity and frozen root
   identity must still match immediately before each relative `rm`; root
   identity is checked again after each removal. A changed target is refused,
   and partial failures are named and return `1`.

`--yes` bypasses only the prompt. It never bypasses root validation, scope
proof, or the plan. User-derived confirmation text is visibly escaped before
fzf or the terminal fallback renders it, so control characters in a path cannot
reshape the authorization UI.

### Deliberate scope decisions

- `build/`, `dist/`, and Cargo `target/` are removed **only at the project
  root**. Nested directories with those names usually belong to vendored
  sources. Cargo `target/` participates only in `dev-clean-all`.
- Python cleanup includes root `.coverage`, `.coverage.*`, and `htmlcov/`.
  `--keep-build` preserves root `build/` and `dist/` for `dev-clean-py`, and
  additionally preserves root `target/` for `dev-clean-all`.
- `.terraform.lock.hcl` is always preserved: it pins provider versions and
  belongs in version control.
- Stale Terraform artifacts remain discoverable even when no `.tf` source file
  survives in the project.
- Discovery uses `find` exclusively. The previous implementation had a second
  `fd` code path with different exclusions, which made the reported count
  disagree with what was actually deleted.

## Remote-code policy

Downloading and executing code is treated as a distinct risk class.

**Installers are never piped to a shell.** `dev-update-toolchain` and
`dev-update-tflint` previously ran `curl … | sh` and `curl … | bash`.
Toolchain maintenance now delegates to the targeted public `sys` owner, while
TFLint reports a proven Homebrew owner or refuses and prints the documented,
verifiable procedure. There is no flag that re-enables either installer pipe.

**TFLint plugin initialization is separate from linting.**
`dev-run-tflint` does not run `tflint --init` implicitly. The caller must pass
`--init`, review the remote-code warning, and confirm or add `--yes`; only then
does initialization run, and its status is checked before recursive linting.

**Ephemeral runners are opt-in.** `uvx` and `npx` can fetch and execute an
index-selected package version. Runner selection has three explicit contracts:

| Helper | Resolution order |
| --- | --- |
| `_dev_python_tool_runner` | declared dependency: runnable module through `.venv/bin/python -I -m`, then a proven `.venv/bin` executable; undeclared tool: installed binary, then `uvx` |
| `_dev_node_tool_runner` | `./node_modules/.bin/<tool>` → installed binary → `npx` |
| `_dev_project_python_tool_runner` | importable module through `.venv/bin/python -I -m`; otherwise refuse |

Declared Python quality gates never use `uv run`: even `--frozen --no-sync`
can discover a global executable when the project copy is absent. The project
interpreter must report the exact, non-symlink `.venv` as `sys.prefix`, with a
different `sys.base_prefix`. Runnable modules and their `__main__.py` must
resolve inside that environment. Executable fallback is also confined to
`.venv`; scripts are accepted only when their shebang names the exact project
interpreter, so `#!/usr/bin/env python3` cannot escape through `PATH`.
Installed-environment inventories, such as licenses or vulnerability data,
have a stricter boundary: they never fall back to a global binary or an
isolated/overlay environment, because that would inspect packages other than
the project's. The `.venv` probe and execution both use Python isolated mode
(`-I`) so the current directory, `PYTHONPATH`, and the user site cannot
manufacture a module match outside the installed environment. A declared but
unsynchronized tool is refused with the exact `uv sync --all-groups` remedy.

Each quality-gate ephemeral step runs only when `DEV_ALLOW_EPHEMERAL=1` and the
corresponding `uvx` or `npx` executable is actually available;
installed-environment inventories ignore that opt-in and remain local-only. An
executable present in `node_modules/.bin` is project-local, so the Dev runner
does not invoke `npx` for it. That executable and its target remain
project-controlled code; their own behavior is not a download guarantee.

## Persisted state

State defaults stay inside the project so a backup sits next to the file it
restores. An override may instead name a dedicated directory below the project
or the user's home. Every path is validated on **every** use, because a
relative default resolves against the caller's current directory.

| Variable | Default | Contents |
| --- | --- | --- |
| `DEV_BACKUP_DIR` | `.dev-suite-backups` | Timestamped `pyproject.toml` copies |
| `DEV_PROFILE_DIR` | `.dev-suite-profiles` | One `<name>.profile` per saved task list |
| `DEV_REPORT_DIR` | `dev-suite-reports` | Markdown reports from `--report` |
| `DEV_BACKUP_RETENTION` | `5` | Current invocation backup plus the newest `N-1` prior backups kept; older ones pruned |

Validation rules, enforced by `functions/dev/dev-state.zsh`:

- a path containing a `..` segment is refused;
- the filesystem root, the project root itself, and the home directory itself
  are refused as state directories;
- the resolved path must live inside the project or the user's home;
- a symlinked component or final state directory is refused before it can be
  followed;
- the directory must be owned by the current user, mode `700`, and retain the
  same device and inode throughout an operation;
- a state file must be an owned, singly linked regular file immediately below
  that directory with no group or other permission bits. Writers create new
  files mode `600`.

Read-only access requires exact mode `700`. A mutating state operation may
repair the mode of an already owner-controlled, non-symlinked dedicated state
directory to `700`; creation and replacement fail closed when permissions
cannot be enforced.
Backups, reports, and profiles are written to private temporary files and
checked for owner, type, link count, mode, and parent identity. Backups and
reports use atomic no-clobber names; an absent profile does the same, while an
authorized existing profile uses identity-checked atomic replacement.
Same-second backup and report names receive a unique suffix rather than
overwriting another invocation. Backup pruning always excludes the backup just
published, regardless of clock skew or manipulated modification times, and
keeps it plus the newest `DEV_BACKUP_RETENTION - 1` prior backups. Pruning is
best effort and never fails the update that just published its backup: a stale
copy is removed only when it is an owned, singly linked regular file directly
below the directory, and a world-readable copy written before state files were
hardened still qualifies. A stale copy that cannot be proven prunable is left
in place with a warning; restore never relaxes the private-mode rule.

`dev-backup-pyproject` records the exact published backup and the original
`pyproject.toml` mode. Automatic rollback accepts only that invocation-owned
path, fingerprints the destination's metadata and content, revalidates source,
destination, and both directory identities, and compares the staged bytes with
the backup immediately before publishing through a same-directory atomic
replacement. An in-place destination edit or replacement during staging is
refused. It never falls back to selecting the newest shared backup or to
restoring from Git.

Report buffers are cleared on every save exit path, including failure, so
content from one report cannot leak into the next.

Profile names are restricted to letters, digits, `.`, `_`, and `-`, must start
with a letter or digit, and are capped at 64 characters. That restriction is
what keeps a stored profile from resolving outside its directory. A name given
on the command line is validated before anything else, so an unsafe value is an
invalid argument rather than a silent no-op.

At most 100 profile files are inventoried. Each file is limited to 8,192 bytes
and 64 non-empty tasks, opened once, and matched by device, inode, size,
timestamps, mode, link count, and owner before and after the complete read.
Every line must pass the batch-eligibility allowlist before `_dev_dispatch` can
run it. An unrecognized, non-eligible, nested, or argument-bearing stored token
causes the profile to be refused before any task executes. Eligible tests and
compilers may still execute project code and create their documented artifacts.

### Export publication

An export destination must be a regular file or absent, live below the project
or home, and contain no symlinked path component. Before asking to overwrite,
the suite validates the direct write parent against unsafe group/world-write
permissions, freezes parent and destination identities, fingerprints the
destination's metadata and content, and holds the same fingerprinted inode open
through a read-only descriptor. `uv export --locked` writes through a held
read/write descriptor to a same-directory mode-`600` temporary without
resolving or updating the lockfile. Parent, destination, held inode, temporary
path, temporary descriptor, ownership, link count, metadata, and content are
revalidated before publication. A previously absent destination uses atomic
no-clobber hard-link publication; an authorized existing destination uses an
identity-checked atomic replacement.

This protects the reviewed destination and prevents a failed exporter from
truncating a working file. It does not preserve filesystem-specific ACLs or
extended attributes when replacing an existing file.

### PyPI query cache

The per-invocation cache is created mode `700` below a validated `TMPDIR`.
The temporary root must be writable, non-symlinked, and either safely owned by
the current EUID or root-owned with the sticky bit. A foreign-owned sticky root
and a non-sticky group/world-writable root are refused. Root, cache-directory,
and mode-`600` cache-file identities are checked throughout use. Cache entries
use atomic no-clobber publication, cache-hit read failures retain their
non-zero status, and cleanup quarantines the exact proven directory,
revalidates its inode, and only then recursively removes it.

The dependency inventory is capped at 1,000 entries and extracts only the
distribution name before extras, specifiers, markers, or a direct-URL `@`.
Every parser refuses `pyproject.toml` above 2 MiB. Package names then use PEP
503 normalization. Requests follow redirects, fail on HTTP errors, enforce the
configured timeout and retry count, and cap a response at 20 MiB. PyPI still
supplies network metadata rather than a cryptographic attestation of the
package release; the cache controls do not change that trust boundary.

## Configuration

| Variable | Default | Effect |
| --- | --- | --- |
| `DEV_ALLOW_EPHEMERAL` | `0` | Remote-runner opt-in; must be exactly `0` or `1` |
| `DEV_SCAN_DEPTH` | `3` | Project detection depth; integer `1`–`32` |
| `DEV_CLEAN_DEPTH` | `12` | Cleanup discovery depth; integer `1`–`64` |
| `DEV_CLEAN_MAX_TARGETS` | `10000` | Unique combined cleanup-plan limit; integer `1`–`50000` |
| `DEV_PYPI_TIMEOUT` | `15` | Per-request seconds; integer `1`–`300` |
| `DEV_PYPI_RETRIES` | `2` | Retries per query; integer `0`–`10` |
| `DEV_PYPI_JOBS` | `8` | Concurrent prefetch jobs; integer `1`–`32` |
| `DEV_SUITE_DEBUG` | `0` | Verbose diagnostics on stderr |

Empty is not a valid override for a state directory: the suite refuses it
rather than falling back to the project root. Invalid numeric and boolean
configuration also fails closed; values are syntax-checked before arithmetic so
configuration text is never evaluated as an expression.

## Exit statuses

| Status | Meaning |
| --- | --- |
| `0` | Success, deliberate cancellation, or a documented no-op |
| `1` | Operational failure, unmet precondition, or a refused unsafe request |
| `2` | Invalid arguments, unknown flag, or unknown dispatch token |

A declined confirmation and "this project has no Python files" are both `0`.
"No terminal available to confirm a mutation" is `1`.

## Deprecated compatibility surface

Before this migration the suite exported generic global names such as
`clean-py`, `run-tests`, `update-all`, and `check-health` into every
interactive shell. Each is kept in `dev-compat.zsh` as a thin forwarder that
emits **one** deprecation notice per shell session, and each is also accepted as
a dispatcher token so `dev-menu clean-py` keeps working.

They are deliberately absent from the menu, `--help`, and the completion, and
they are scheduled for removal in **v0.3.0**.

| Deprecated | Canonical |
| --- | --- |
| `update-all`, `update-deps`, `update-deps-dry`, `update-lock`, `update-precommit`, `update-terraform`, `update-tflint`, `update-toolchain`, `update-python` | the same name with a `dev-` prefix |
| `check-outdated`, `check-health`, `check-licenses`, `check-types` | the same name with a `dev-` prefix |
| `run-hooks`, `run-ruff`, `run-ruff-format`, `run-ty`, `run-pyright`, `run-tflint`, `run-markdownlint`, `run-eslint`, `run-prettier`, `run-clippy`, `run-shellcheck`, `run-all-checks`, `run-tests`, `run-coverage`, `run-audit`, `run-bandit` | the same name with a `dev-` prefix |
| `clean-py`, `clean-repo`, `clean-terraform`, `clean-all` | the same name with a `dev-` prefix |
| `export-deps`, `build-package`, `backup-pyproject` | the same name with a `dev-` prefix |
| `profile-save`, `profile-list`, `profile-delete` | the same name with a `dev-` prefix |
| `clean-docker`, `docker-prune-all` | `docker-menu docker-clean` |
| `venv-python` | `py-menu venv-python` |

`venv-init` and `venv-sync` appeared in the previous help text and completion
but never existed in any dispatcher or module. They are removed rather than
implemented.

## Test coverage

| File | Covered boundary |
| --- | --- |
| `dev.bats` | Polyglot gate behavior, the no-applicable-gate no-op, deprecation notices, and delegation to the `py` and `docker` suites |
| `dev_alignment.bats` | Parser-before-probe ordering, project-bound runners, batch metadata, private and bounded profiles, fzf errors, bounded configuration, project-probe exclusions, loader safety, and owner-aligned completion grammar |
| `dev_cleanup_safety.bats` | Root and target replacement, per-removal revalidation, generated and nested-repository exclusions, bounded depth, and stale Terraform cleanup |
| `dev_contract.bats` | The frozen 49-command fixture, five-way surface parity, dispatcher coverage, deprecated-alias forwarding, cancellation, timing label, exact no-argument grammar, and invalid-argument statuses |
| `dev_interface.bats` | Double sourcing, standalone sourcing without the core runtime, loader failure without a false sentinel, stream separation, `NO_COLOR`, NUL-safe record validation, cached advisory probes, keyboard-legend accuracy, foreground private picker capture and cleanup, snapshot-validated selection and multi-select dispatch, argument forwarding, and lazy/eager parity |
| `dev_io_safety.bats` | Private state/report publication, exact restore, no-clobber export, stream and failure propagation, exact project-runner provenance, source-read-only flags, TFLint initialization, normalized direct dependencies, and PyPI cache identity |
| `dev_maintenance.bats` | Cleanup plans, dry runs, confirmations, awkward filenames, partial failures, remote-installer refusal, exact state modes and boundaries, best-effort pruning of legacy and unprunable backups, profiles, PyPI helpers and probe diagnosis, and export behavior |
| `dev_security_safety.bats` | Structured license classification and bounds, local-only project inventories, bounded/pruned scanner discovery, audit remediation authorization, and mutating-gate classification |
| `dev_update_safety.bats` | Frozen aggregate applicability (project files and infrastructure), PyPI failures isolated from independent backends, the per-step summary, pre-commit skipping only for an inconsistent lockfile, immediate cleanup authorization, private dependency and frozen-hook plans, downgrade retention, all-stage environment installation, post-publication hook findings, exact backup and concurrent hook-config preservation, host-owner delegation, hostile Zsh option output, safe temporary roots, staged `.venv` replacement/recovery, exact-project hook execution, and stderr-only tool output |
| `dev_update_dispatch.bats` | Missing uv isolated from Terraform inspection and cleanup, child-specific dependency enforcement, and parser-before-probe maintenance routing |
| `dev_update_recovery.bats` | Validated partial hook updates, refused unsafe or interrupted candidates, failed environment installation, independent package and Git backends, scoped native HTTP stall limits, inapplicable dry-run steps, and direct retry guidance |
| `dev_update_specifiers.bats` | Parsed dependency-span rewriting, normalized names and repeated declarations, preserved unrelated TOML and formatting, no downgrades, bounded span matching, dry-run behavior, and failed query output |
| `dev_python_relocation.bats` | Offline real-uv publication of console entrypoints and activation scripts with spaced paths, scoped relocation controls, and rejection of staged interpreters with a different minor or implementation |

## Residual gaps

1. **Network paths are mocked.** No test exercises a live PyPI response. Rate
   limiting, redirects, partial bodies, proxy behavior, and index metadata
   remain integration boundaries despite bounded response size, timeout, and
   retries.
2. **External tools are not one transaction.** Most `uv`, `pre-commit`, owning
   host package-manager, TFLint, and linter tests use deterministic mocks;
   relocation coverage additionally uses real uv offline with a local wheel.
   ZDX can
   atomically restore the project files it owns and propagate tool failures,
   but it cannot roll back every side effect performed inside an external
   package manager, hook, plugin, or runtime installer. Native Git low-speed
   settings bound stalled HTTP transfers, but do not bound SSH, an entire
   transfer that continues making progress, or arbitrary hook execution.
3. **Non-Linux hosts are unverified.** The implementation uses Zsh filesystem
   modules and portable command forms where practical, but CI runs on
   `ubuntu-latest`. A real macOS or BSD verification run is not recorded.
4. **Portable path operations retain same-EUID race windows.** Root, target,
   workspace, state, export, and environment identities are checked at narrow
   userspace boundaries, write parents reject unsafe cross-UID permissions, and
   export temporaries stay open by descriptor. A hostile process with the same
   EUID still shares ownership authority and can compete between a final check
   and `rm` or `rename`. The `.venv` directory identity also cannot freeze
   every file below it against a same-user process. Eliminating these windows
   would require platform-specific handle-relative APIs.
5. **Private atomic publication assumes normal POSIX filesystem semantics.**
   Filesystems without reliable ownership, modes, atomic rename, or hard links
   fail closed and are not a supported state backend. Replacing an export does
   not preserve arbitrary ACLs or extended attributes.
6. **External Python installation is not reversible.** With an existing
   `.venv`, `dev-update-python` authorizes before starting and can recover the
   project environment transaction. The preceding
   `uv python install --upgrade X.Y` may still change uv-managed global Python
   installations, which ZDX cannot roll back.
7. **`dev-run-hooks`, `dev-run-ruff-format`, and the post-publication hook
   run of `dev-update-precommit` rewrite files without a confirmation.** That
   is their documented purpose and matches how the underlying tools are
   normally invoked, but it means a `dev-run-all-checks` or `dev-update-all`
   run on a project with formatting hooks can modify the working tree.
8. **The deprecated alias surface doubles the suite's global function count**
   until v0.3.0. It is the deliberate cost of not breaking existing scripts.

## Maintenance triggers

Update this document when any of the following happens:

- a public command is added, renamed, or removed — also update the fixture;
- a command's batch-eligibility classification changes;
- a new external tool or ephemeral runner is introduced;
- a cleanup pattern, depth bound, or protected root changes;
- an update authorization, backup, publication, or rollback boundary changes;
- a persisted-state path, permission, or retention rule changes;
- a temporary-workspace, PyPI-cache, or export identity rule changes;
- a delegation to another suite is added or withdrawn;
- the deprecated compatibility surface is reduced or removed.
