# Developer suite contract

This document is the public contract for the `dev` suite. It defines the frozen
command surface, the ownership boundaries, the safety model for cleanup and
update workflows, the remote-code policy, and the persisted state layout.

The general engineering contract is in [`development.md`](development.md), the
interactive UI contract is in [`menu-spec.md`](menu-spec.md), and the file and
loader conventions are in [`headers.md`](headers.md). Where this document and
those disagree, they win.

## Ownership

The `dev` suite owns **project-scoped** maintenance for the working directory:
dependency specifiers, lockfiles, pre-commit hook revisions, the GitHub Actions
references of its workflows, quality gates, tests, security scans, and
project-local cleanup.

It does **not** own:

| Domain | Owner | How `dev` relates to it |
| --- | --- | --- |
| Virtual environments and Python runtimes | `py` (`py-menu`) | Dev exposes no `venv-*` command. `dev-update-python` forwards runtime installation without an existing `.venv` to `py-menu`; Dev retains only its documented locked replacement transaction for an existing project `.venv` |
| Host packages, services, and system cleanup | `sys` (`sys-menu`) | The `dev-update-all` host toolchain step calls `sys-menu update-uv-system` directly; ambient `pip` is never invoked; Terraform and TFLint report package-manager ownership |
| Cross-suite dependency installation | `zdx-doctor` | `dev` explains how to install a missing tool and never installs it |
| Operating-system junk files (`*:Zone.Identifier`, `.DS_Store`, `._*`, `Thumbs.db`, `desktop.ini`) | `file` (`file-clean-junk`) | Dev cleanup plans no junk category; such files appear in any directory, not only in projects |

A delegation is documented forwarding, not a second implementation. New work
MUST NOT add a general `dev`-local implementation of a delegated
lifecycle, or a `dev` command that only forwards to another suite's public
command. The existing `.venv` replacement is a narrow project maintenance
exception: it is coupled to the current `pyproject.toml` and `uv.lock`, and it
is not exposed as another environment lifecycle command.

## Architecture

```text
functions/dev-menu.zsh          public loader, router, menu model
  -> functions/dev-common.zsh   logging, prompts, capabilities, dispatch, fzf
    -> functions/dev/dev-state.zsh      validated state dirs, backups, restore
    -> functions/dev/dev-report.zsh     Markdown report buffer
    -> functions/dev/dev-pypi.zsh       PEP 503, pyproject parsing, PyPI queries
    -> functions/dev/dev-update-transaction.zsh  workspaces, fingerprints, rollback
    -> functions/dev/dev-update-specifiers.zsh   TOML specifier plans, PyPI readiness
    -> functions/dev/dev-update-deps.zsh         specifier updates, lockfile refresh
    -> functions/dev/dev-update-precommit.zsh    guarded frozen hook revisions
    -> functions/dev/dev-update-actions.zsh      SHA-pinned GitHub Actions references
    -> functions/dev/dev-update-python.zsh       staged .venv replacement
    -> functions/dev/dev-update.zsh     ownership reports, full maintenance
    -> functions/dev/dev-checks.zsh     linters, type checkers, tests, health
    -> functions/dev/dev-security.zsh   pip-audit, Bandit
    -> functions/dev/dev-clean.zsh      planned, confirmable removal
```

Load order is explicit in the entrypoint. The update transaction and specifier
helper modules load before the update workflows that consume them, and
`dev-update.zsh` loads after the deps, pre-commit, and actions modules whose
commands and outcome state its `dev-update-all` aggregate orchestrates.

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
`dev-menu --multi` enforces an allowlist of independent, argument-free tasks:
`dev-check-health`, `dev-check-outdated`, `dev-run-ruff`,
`dev-run-shellcheck`, `dev-run-markdownlint`, `dev-run-tflint`,
`dev-run-tests`, `dev-run-audit`, and `dev-run-bandit`. Nested orchestrators
(including `dev-check-types` and `dev-run-all-checks`), formatters that
rewrite files, dependency, lockfile, and GitHub Actions updates, cleanup, and
environment lifecycle are excluded. Batch-eligible means independently
runnable with no explicit suite-owned source mutation; it does not promise
that a test, configured plugin, or project hook executes no project code or
creates no documented cache artifact. A selected row is checked again before
dispatch, so a forged row cannot widen the executable batch surface.

## Interactive selection

The command menu uses the common compact presentation in
[`menu-spec.md`](menu-spec.md): 80% height, a four-line bottom description,
and `Ctrl-/` to toggle details. Labels distinguish dependency edits, lockfile
and environment updates, and project cleanup.

Every Dev picker — the top-level menu, `--multi`, and the interactive
confirmation prompt — runs `fzf` synchronously in the terminal foreground
through `_dev_fzf_capture`. Selection stdout is captured in a private, owner-only,
bounded (64 KiB) invocation-owned result file below a validated temporary
root: a current-user directory without group/world write access, or a
root-owned sticky shared directory. A child file-size limit caps growth while
`fzf` is writing, and identity plus size are checked again before reading. The
exact `fzf` status is preserved, a failed picker cannot carry selection data,
and the result file is removed by exact identity on every path.

A selected record must also belong to the invocation's row snapshot. The
single-select menu refuses a selection outside that snapshot; `--multi` skips
such rows with a warning after the batch-eligibility allowlist has already
excluded ineligible commands.

Menu capability annotations are built from an invocation-local probe cache.
Each shallow command-or-path availability key runs at most once per rendered
snapshot; no result persists into a later menu invocation. Rendering does not
parse TOML, start Python, or execute a project tool. These annotations remain
advisory: no missing-tool annotation is not a readiness guarantee. They never
replace the public command's post-parser capability checks. A command is
marked only where it cannot run: `dev-update-deps`, `dev-update-precommit`,
`dev-update-actions`, and `dev-check-outdated` show `missing: Python 3.11+`
only when no [metadata interpreter](#metadata-interpreter) candidate exists at
all, `dev-update-actions` shows `missing: git` without Git, and a
tool counts as missing when it is a Windows launcher on WSL or a Command Line
Tools placeholder on macOS (see [Platform support](#platform-support)).
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

25 commands are frozen, all owned by `dev`.

Only the `dev-menu` entrypoint is registered as a lazy stub by the core runtime.
`dev-menu <command> [arguments...]` therefore works from a cold shell, while
the individual public functions become callable once the suite has loaded (or
immediately under `ZDX_EAGER_LOAD=1`). Scripts should use the Developer
entrypoint form.

### Inspection (read-only unless `--report`)

| Command | Behavior |
| --- | --- |
| `dev-check-health` | Diagnose Python/uv environment, lockfile, hook, and toolchain state. Returns `1` on an issue; a project with no Python/uv marker is a clean no-op. |
| `dev-check-outdated` | Compare declared direct dependencies against `.venv`, explicitly passing its interpreter and `UV_SYSTEM_PYTHON=0`. |

Both are read-only by default. `--report` additionally writes a private,
atomically published Markdown report. Project metadata parsing refuses
`pyproject.toml` above 2 MiB or a combined direct-dependency inventory above
1,000 entries.

Health applies when the project has `pyproject.toml`, `.venv`, `uv.lock`,
`.python-version`, or a discovered Python source file. Without any such marker,
it reports that Python/uv health is not applicable and returns `0` without
probing PyPI or treating absent Python metadata as a failure. Once a marker
exists, the full diagnostic remains strict. Comment lines and a CRLF line
ending in `.python-version` are read as uv reads them; `dev-update-python`
shares that parser. Health reports the
[metadata interpreter](#metadata-interpreter) under its required tools: when
none qualifies, that is one issue with the platform's installation advice,
and `pyproject.toml` is reported as not parsed rather than as malformed.

### Quality gates

| Command | Mutates files? |
| --- | --- |
| `dev-run-all-checks` | May rewrite through configured hooks |
| `dev-run-hooks` | Yes — hooks rewrite files by design; their runner is frozen and cannot sync implicitly |
| `dev-check-types` | No — runs `ty check` and/or `pyright` through private runners that take no arguments |
| `dev-run-ruff` | No — fixing/output flags are refused and `RUFF_OUTPUT_FILE` is removed from its environment |
| `dev-run-ruff-format` | Yes, by design |
| `dev-run-shellcheck` | No |
| `dev-run-markdownlint` | Only with the explicit `--fix` flag |
| `dev-run-tflint` | No by default; `--init` may download plugins and requires explicit authorization |

`dev-run-markdownlint` passes `.config/markdownlint.yaml` explicitly when that
project-local file exists. Otherwise, Markdownlint retains its normal
configuration discovery behavior. It lints the suite's bounded Markdown
inventory in batches of at most 64 paths, never a `**/*.md` glob, so `--fix`
cannot rewrite files in `node_modules`, vendored or generated trees, or nested
repositories.

`dev-check-types` runs every type checker the project declares (`ty` or
`pyright` in its dependencies, or a `pyrightconfig.json`) and falls back to an
installed `ty` or `pyright` only when neither is declared. Each checker
resolves its backend through `_dev_python_tool_runner`.

`dev-run-all-checks` gates Python sources with Ruff, type checking (when `ty`
or `pyright` is declared), pip-audit (with a `.venv`), and Bandit, then adds
tests, configured pre-commit hooks, TFLint, ShellCheck, and Markdownlint when
their inputs exist. A `package.json` or `Cargo.toml` adds no gate; the suite
has no JavaScript or Rust linter. It runs each applicable gate as a step of
the shared aggregate structure in [`output-spec.md`](output-spec.md): a
banner, the gate's output captured privately, and one result line. A failing gate replays
its bounded, redacted tail under its step, the `Check Results` table lists
every gate, and the verdict names the commands that rerun the failing gates.
`--verbose` streams each gate's output instead. A read-only gate needs no plan
or authorization. A gate that returns `130` or `143` stops the aggregate:
later gates are listed as not run and that status is returned.
`dev-check-types` preserves it the same way.

`dev-run-tflint` runs `tflint --recursive` without initializing plugins.
Plugin initialization is a separate remote-code action selected with `--init`;
it displays that effect and requires confirmation, or `--yes` in a
non-interactive shell. Initialization failure is returned and linting is not
reported as successful.

Read-only gate parsers reject backend flags known to enable source or state
rewrites, such as Ruff `--fix` and TFLint `--fix`, including the forbidden
letter inside a clustered short option such as Ruff `-eo`. Ruff receives only
the caller's paths; with none it uses the current directory, so an explicit
file selection is never widened to the whole project. `dev-check-types`
accepts no arguments, so no caller option can reach its type checkers.

Quality gates, tests, and configured hooks are explicit local trust
boundaries. They can load project-controlled configuration or code even
when the Dev wrapper itself is classified read-only. `dev-run-hooks` can also
initialize hook environments, and `dev-run-all-checks` inherits those effects.

Bandit, ShellCheck, and Markdownlint share one NUL-safe project-file
collector. It prunes generated trees, installed-package trees
(`site-packages`, `dist-packages`, `.tox`, `.nox`), and nested repositories
before traversal, propagates discovery failure, caps each inventory at 512
files, and invokes each backend in batches of at most 64 paths. Gate
applicability probes and these inventories look up to 32 directory levels, so
an ordinary `src/` layout or a deep test tree is covered; `DEV_SCAN_DEPTH`
bounds only the stack summary in the menu header. A directory that `find` can
only report as "Permission denied" is skipped with a warning naming it, since
nothing below it can be listed, discovered, or removed; any other discovery
error still fails closed.

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
| `dev-update-deps` | mutating | Builds and fingerprints a private plan, shows it, confirms, backs up, atomically publishes, and re-locks only bumped packages; `--dry-run` stops after the plan |
| `dev-update-lock` | mutating | Refreshes `uv.lock`; never edits `pyproject.toml` |
| `dev-update-precommit` | mutating | Continues usable package and hook backends after a PyPI query failure; plans frozen revisions privately, rejects regressions, installs every planned hook environment, publishes atomically, reinstalls the Git hooks, and reports findings or incomplete updates |
| `dev-update-actions` | mutating | Pins the workflow and composite-action `uses:` references to the commit SHA of a newer release with a version comment; plans privately, shows the plan, confirms, backs up, publishes atomically, validates with `actionlint` and `zizmor`, and rolls back a newly failing validation; `--dry-run` stops after the plan. See [GitHub Actions updates](#github-actions-updates) |
| `dev-update-python` | destructive | With an existing `.venv`, confirms before any uv mutation, stages a locked replacement, and publishes with verified rollback; without one, delegates installation to `py-menu` |
| `dev-update-terraform` | read-only | Proves and reports the `tfenv` or host package-manager workflow; Dev never executes `tfenv install latest` |
| `dev-update-tflint` | read-only | Proves and reports Homebrew ownership; otherwise prints the verified procedure |

`dev-update-deps` flags: `--dry-run`, `--yes`, `--verbose`, and one of
`--major-only`, `--minor-only`, `--patch-only`. The plan is always shown before
the confirmation, so there is no separate preview command: `--dry-run` is the
read-only preview. Host `uv` maintenance belongs to System; run
`sys-menu update-uv-system`, or let `dev-update-all` run it as its host
toolchain step.

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
`TFENV_ROOT` cannot manufacture ownership. A Homebrew claim is derived from
the resolved executable itself: the brew on `PATH` owns it when the path lies
below that brew's prefix, and another installation, such as an Intel
`/usr/local` beside Apple silicon's `/opt/homebrew`, owns it when the path
lies in that prefix's `Cellar` and the prefix holds its own `bin/brew`. Such
an owner is reported with its own `<prefix>/bin/brew upgrade <formula>`,
because `sys-menu update-brew` drives only the brew on `PATH`; the other brew
is never run.

### GitHub Actions updates

`dev-update-actions [--dry-run] [--yes] [--major]` updates the GitHub Actions
that the project's CI uses. It requires Git and the
[metadata interpreter](#metadata-interpreter), which fingerprints, parses, and
rewrites the files; `gh` is optional. It never executes code from an action
repository, and its `--help` and invalid-argument paths make no network call.

**Scope.** In the project root (the working directory), every `*.yml` and
`*.yaml` directly below `.github/workflows`, whatever its name, and every
`action.yml` or `action.yaml` below `.github/actions`, at any depth. Globs
include dot files but never follow a symbolic link; a symlinked or
non-directory `.github`, `.github/workflows`, or `.github/actions` is refused.
At most 256 files of up to 1 MiB each are read, as bytes, through a no-follow
descriptor. Without either directory the command reports `skipped` and returns
`0` before any probe.

**Parsing.** A line-based parser finds step- and job-level `uses:` keys,
including `- uses:`, single or double quotes, and a trailing comment, and
skips the content of block scalars such as `run: |`, so a script that
mentions `uses:` is never rewritten. Each value is classified:

| Value | Treatment |
| --- | --- |
| `owner/repo[/path]@ref`, including reusable workflows such as `owner/repo/.github/workflows/x.yml@ref` | Queried and planned |
| `./…` (a local action or reusable workflow) | Skipped as `local action` |
| `docker://…` | Skipped as `Docker image` |
| Anything else, such as a value that fails the patterns below | Skipped as `invalid reference; not queried` |

Every parsed value is data. The owner must match
`^[A-Za-z0-9][A-Za-z0-9-]{0,38}$`, the repository `^[A-Za-z0-9._-]{1,100}$`
(not `.` or `..`), each path segment `^[A-Za-z0-9._-]+$` (not `.` or `..`, at
most 255 characters), and the ref `^[A-Za-z0-9][A-Za-z0-9._/-]{0,254}$`
without `..`, `//`, `@{`, `/.`, or a trailing `/`, `.`, or `.lock`. The
parser checks these patterns and the shell checks them again before a value
reaches a URL, a `git` argument, or a `gh api` path. An invalid reference is
listed in the plan, never queried or rewritten, and does not change the exit
status.

**Current version.** A ref of 40 hexadecimal digits is pinned: its version
comes from a trailing comment such as `# v4.2.2`, `# 4.2.2`, or
`# tag=v4.2.2`, and that tag's commit (or its tag object, for an annotated
tag) must equal the pinned SHA. A pinned SHA without a version comment is
identified by the highest stable tag that points to it. A mismatched SHA, a
comment that names no tag, an unidentifiable SHA, an abbreviated SHA, and a
prerelease ref such as `@v5.1.0-rc.1` are skipped with that reason rather than
guessed or downgraded. Any other ref is unpinned: a
version-shaped ref (`v4`, `v4.2`, `v4.2.2`, `4.2.2`) is the current version
and its major, and anything else, such as `main`, is a branch with no current
version.

**Latest version.** For each distinct `owner/repo` (compared without case),
the command runs `git ls-remote --tags -- https://github.com/<owner>/<repo>`.
It needs no token for a public repository. Queries run eight at a time and are
bounded by the core timeout service (`_dev_run_with_timeout`, a fallback that
delegates to `_zdx_run_with_timeout`) with `DEV_ACTIONS_TIMEOUT`, Git's HTTP
low-speed limit, and a 16 MiB listing limit. They run with
`GIT_TERMINAL_PROMPT=0`, an empty `GIT_ASKPASS`, `-c credential.helper=`,
`-c core.askPass=`, and
`-c protocol.allow=never -c protocol.https.allow=always`, so no credential
helper or prompt runs and a `url.<base>.insteadOf` rule that
rewrites the address to SSH or another transport makes the query fail instead
of leaving HTTPS. Only stable `vX.Y.Z` or `X.Y.Z` tags count; prereleases such
as `v5.1.0-rc.1` and non-version tags are ignored. An annotated tag is peeled:
the commit of `refs/tags/<tag>^{}` is the pin, never the tag object.

**Selection.** The candidate is the newest stable release that is not older
than the current version. By default it stays within the current major
version; a newer major is noted as `vN.0.0 needs --major`. `--major` allows
newer majors and the plan marks them `major`. A branch ref has no major and
takes the newest stable release. Nothing is ever downgraded: an unpinned
`@v6` with no `v6` release is skipped as `no stable release matches v6`.

**Cooldown.** When `gh` is installed and `gh auth status --hostname
github.com` succeeds, a candidate newer than the version in use is held back
while it is younger than `DEV_ACTIONS_COOLDOWN_DAYS` (default `7`, an integer
from `0` through `90`; `0` disables the check). Its age is the GitHub release's
`published_at`, or, without a release, its tag commit's committer date, read by
a bounded `gh api --hostname github.com` call whose result must be a plain
integer; the next older eligible release is then considered and the plan
names the held-back one. A version already in use, such as the release a
moving `@v4` tag points to, needs no check. Without `gh`, or when it is not
authenticated, the command says once that release ages were not checked and
proceeds. When `gh` is ready but an age cannot be read, that reference fails
closed: it is not changed and the command returns `1`.

**Pinning.** Every updated reference becomes
`owner/repo[/path]@<40-hex commit SHA> # <tag>`, where the tag is the release
name (`vX.Y.Z` or `X.Y.Z`). Only the value and its version comment change:
indentation, the `-` marker, quotes, spacing, the rest of the comment, line
endings (LF or CRLF), and every other byte of the file are preserved. A
comment that starts with a version has that version replaced; another comment
is kept after the new version, as in `# v4.3.0 # reviewed`. An unpinned
reference that has an equal or newer release is pinned to that release's
commit with kind `pin` (or `major` across a major); a pinned reference changes
as `patch`, `minor`, or `major`. A reference already at the newest allowed
release is current.

**Plan and authorization.** The rewritten files are built in a private update
workspace before anything is shown, and each edited line is parsed again to
prove its new value. The plan is a numbered
`# · Action · Current · New · Kind · Files` table with one row per distinct
change, followed by notes for held-back or newer-major releases, an
`Action · Current · Result · Detail` table for references that are skipped,
failed, or current with a note, and the count of current references. Then:

- `--dry-run` prints `Dry run: N action references planned; nothing was
  changed.` and stops;
- otherwise the command asks `Update N action references?`; a decline prints
  `Cancelled: nothing was changed.` and returns `0`, and a run without a
  terminal fails closed unless `--yes` was passed;
- with nothing to change it reports `current`.

**Transaction.** After authorization the command revalidates the project
directory, the workspace, the private originals and candidates, and the live
files against their planning fingerprints. It backs up each file it will
change into `DEV_BACKUP_DIR` (see [Persisted state](#persisted-state)),
publishes each candidate through the same compare-and-swap atomic
publication as `pyproject.toml`, keeping the live file's mode, and prints one
result line per file. If a publication fails or the run is interrupted, every
file already published is restored from its private original through the same
publication; a file changed by another process meanwhile is never
overwritten, and its backup is named instead.

**Validation.** When installed, `actionlint` runs on the changed workflow
files (it does not lint composite action metadata) and `zizmor --offline` on
every changed file, each bounded to 300 seconds. Each runs once on the
original files before publication and once on the published files, captured
and replayed only on failure. A validator that passed before and fails after
rolls every file back and returns `1`. A validator that already failed on the
original files cannot tell new findings from old ones: the update is kept, the
findings are shown, and the command returns `1`, like a hook finding after
`dev-update-precommit`. A missing validator is reported as skipped.

**Failures.** A failed tag query or unreadable release age fails only the
references of that action: they are listed as `failed` and unchanged while
the other actions are planned and applied, and the command returns `1` with
`completed with partial failures: F of T action references failed.` and the
retry command. After a batch in which a query timed out, later repositories
are not queried and are reported as `not queried after a github.com timeout`,
so an unreachable network costs one deadline rather than one per action.

### Destructive maintenance

`dev-clean-py`, `dev-clean-terraform`, `dev-clean-all`, and `dev-update-all`.
`dev-clean-all` combines the Python, Terraform, and root Cargo categories;
operating-system junk files belong to the File suite's `file-clean-junk`.

### Aggregate output

`dev-update-all [--yes] [--dry-run] [--verbose]` follows
[`output-spec.md`](output-spec.md). Its plan is a numbered `# · Step · Action`
table of the steps that will start; an inapplicable step is listed without a
number as `⊘ not applicable (<reason>)` and a blocked one as
`✘ blocked (<reason>)`. Each step prints a banner and one result line; a
child's own heading and the policy notes that the plan already states appear
only with `--verbose`, which also streams captured tool output. Each child
reports its result with evidence:

| Step | Result |
| --- | --- |
| Host toolchain | The System owner's uv result, such as `current: 0.12.22` |
| Dependency specifiers | `updated` with the bumped specifiers, or `current` |
| Lockfile refresh | A `Package · Previous · Locked` table of changed versions read from `uv.lock` before and after, or `current`; without Python 3.11 or a readable lockfile, `done` |
| Pre-commit hooks | A `Hook repository · Revision · Result · Detail` table from the revision guard, with `current`, `updated`, and kept revisions shown as skipped with the rejected proposal |
| GitHub Actions | `updated` with the count and the first changes, such as `3 action references (actions/checkout v4.1.0 → v4.3.0, …)`, `current`, or `failed` with the references that could not be checked; skipped as `no .github/workflows` when the directory is absent |
| Terraform and TFLint ownership | `delegated` to their owner, such as `Homebrew → sys-menu update-brew`, or `Homebrew at /usr/local → /usr/local/bin/brew upgrade terraform` for a second installation; a manual Terraform is skipped, and an unverified TFLint is blocked |
| Project cleanup | `current: nothing to clean`, `planned` in a dry run, `done` with the removed count, or `skipped` when cancelled |

Chatty backends such as `uv lock`, `uv sync`, and the pre-commit autoupdate,
validation, and installation phases run with their output captured privately
and replayed only on failure. The pre-commit hook run stays visible because
its findings are the project's results. `dev-menu --multi` runs the selected
tasks through one batch runner: a banner and one result line per task, a
`Task Summary` table, and a verdict. A failing task does not stop the batch;
an interruption does.

## Update transactions and aggregate authorization

`dev-update-all` freezes its applicable scope once, shows that aggregate
maintenance plan, and requests authorization before any mutating child
starts. The frozen scope is:

| Step | Runs when | Child command |
| --- | --- | --- |
| Host toolchain | always | `sys-menu update-uv-system` |
| Dependency specifiers | `pyproject.toml` exists | `dev-update-deps --yes` |
| Lockfile refresh | `uv.lock` exists | `dev-update-lock` |
| Pre-commit hooks | `pyproject.toml` and `.pre-commit-config.yaml` exist | `dev-update-precommit` |
| GitHub Actions | `.github/workflows` exists | `dev-update-actions --yes` |
| Terraform ownership | `terraform` is installed | `dev-update-terraform` |
| TFLint ownership | `tflint` is installed | `dev-update-tflint` |
| Project cleanup | always | `dev-clean-all [--yes]` |

A step that returns `130` or `143` stops the aggregate: every later step is
listed as not run, and that status is returned instead of an ordinary failure.
`dev-update-deps` records an interrupt instead of resuming after it. An
interrupt before publication leaves `pyproject.toml` untouched; one during or
after publication takes the same exact backup rollback as a failed lock; in
both cases the signal status is returned.

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
planning, identity checks, or validation. Like the dependency step, the
GitHub Actions step runs with `--yes` under the aggregate authorization; it
still shows its exact plan, backs up, validates, and rolls back. Its workflow
files are independent of the Python metadata, so no dependency outcome blocks
it. `--dry-run` invokes only the `dev-update-deps --dry-run`,
`dev-update-actions --dry-run`, and `dev-clean-all --dry-run` previews,
skipping the dependency preview when `pyproject.toml` is absent and the
actions preview when `.github/workflows` is absent.

The aggregate continues after independent failures and prints one result line
per step, a `Maintenance Summary` table with the result, time, and detail of
every step (including blocked, skipped, and not-run rows), a verdict with
counted steps, each failed step with its cause, and the direct commands that
retry them: `sys-menu update-uv-system` for the host toolchain and a
`dev-menu` command for every other step. It returns `1` when any step failed
or was blocked. Retry commands preserve dry-run previews and require normal
confirmation for mutations. When other steps completed or were inapplicable,
the core timing message identifies partial failures while preserving the
failure status.
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
`TMPDIR` is resolved once to its canonical directory through trusted aliases
only, such as macOS `/var/folders` and `/tmp` (see the temporary-root rule in
[`development.md`](development.md#temporary-resources-and-background-processes));
every later identity check uses that canonical root. It must be either safely
owned by the current EUID or root-owned with the sticky bit; a foreign-owned
sticky root and a non-sticky group/world-writable root are refused.

`dev-update-python` has a separate directory transaction for an existing
`.venv`. It requires `pyproject.toml` and `uv.lock`, refuses a link or
non-directory `.venv`, freezes project and environment identities, displays the
replacement plan, fingerprints both project inputs, and confirms before
`uv python install --upgrade <X.Y>` or another mutating uv command. A sole
simple `X.Y` project pin selects that minor; comment lines and a CRLF line
ending are read as uv reads them, through the parser that health uses.
Without a pin, the command derives the current `.venv` interpreter minor.
Multiple pin files or values, exact `X.Y.Z` pins, and complex or ambiguous pins
are refused before mutation and delegated to
`py-menu venv-python-pin <major.minor>`. A non-CPython `.venv` is likewise
refused and delegated to an explicit `py-menu venv-python-pin` selection because the
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

An interrupt between renames also retains the recovery workspace, decided
from the filesystem as well as from the rename bookkeeping, so a rename that
completed just before an interrupt still keeps the original. After
success, the preserved original is removed only through validated quarantine.
When `.venv` is absent, the command performs no runtime mutation itself. It
delegates to `py-menu venv-python-install`, forwarding `--yes` when present, so
the owning suite selects, previews, and authorizes the runtime installation.
Because no version operand is forwarded, selection remains interactive even
with `--yes`. Unattended callers use
`py-menu venv-python-install VERSION --yes` after reviewing that exact runtime.

The PyPI reachability probe is a bounded HTTPS `HEAD` request that reports
the most specific cause curl can prove: an HTTP status other than 200, a DNS
failure, a refused or unreachable TCP port, a timeout before TCP connected, or
a connection that was accepted while the TLS/HTTP exchange stalled. The last
case is the signature of large packets dropped by a VPN or tunnel with a
smaller MTU, so the probe also prints MTU advice for the host: the `eth0`
remedy on WSL2, where the guest never learns the tunnel MTU; the VPN adapter
in Windows on WSL1, which shares the Windows network stack; and a
don't-fragment ping in the platform's spelling elsewhere, `ping -c1 -M do -s
1364` on Linux and `ping -D -s 1364 -c1` on macOS. A DNS failure points to
`/etc/resolv.conf` on Linux and WSL and to `scutil --dns` on macOS.
`dev-update-precommit` uses this probe only
to decide whether its public-PyPI specifier query can run. Its Git children
receive invocation-local `GIT_HTTP_LOW_SPEED_LIMIT=1` and
`GIT_HTTP_LOW_SPEED_TIME=DEV_PYPI_TIMEOUT`, allowing Git to abort stalled HTTP
transfers through its [native low-speed controls](https://git-scm.com/docs/git-config#Documentation/git-config.txt-httplowSpeedLimit).
This is an HTTP stall limit, not a total operation deadline. SSH transports,
package-manager transactions, and hooks retain their own timeout policies;
ZDX does not kill an in-progress mutating transaction to enforce this limit.

Dependency and pre-commit update parsers require Python 3.11+ with `tomllib`;
see [Metadata interpreter](#metadata-interpreter).
After synchronization, pre-commit autoupdate, candidate validation, hook
execution, and installation run only through the exact project environment.
Test, coverage, and normal hook runs use the same provenance boundary and
never invoke `uv run`, so a missing project backend cannot fall through to
`PATH`. The `dev-update-all` host toolchain step calls
`sys-menu update-uv-system` directly through `_dev_delegate_sys`; it does not
probe or mutate an ambient Python or `pip`, including an externally managed
PEP 668 installation. The System owner reports its uv result into the step and
records its own telemetry, so the step adds no Dev timing record.

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
   `node_modules`, `vendor`, `vendored`, installed-package trees
   (`site-packages`, `dist-packages`, `.tox`, `.nox`) of any virtual
   environment, and nested repository roots discovered from `.git` file or
   directory markers. A directory target that contains such a nested
   repository is skipped with a warning, except `.terraform/`, whose module
   cache legitimately holds Git clones. An unreadable directory is skipped
   with a warning rather than aborting discovery. Each discovery stream and nested
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
  sources. Cargo `target/` participates only in `dev-clean-all`, and only when
  a root `Cargo.toml` or Cargo's `target/CACHEDIR.TAG` proves it is Cargo
  output.
- Python cleanup includes root `.coverage`, `.coverage.*`, and `htmlcov/`.
  `--keep-build` preserves root `build/` and `dist/` for `dev-clean-py`, and
  additionally preserves root `target/` for `dev-clean-all`, including their
  contents: discovery does not descend into a preserved directory.
- `.terraform.lock.hcl` is always preserved: it pins provider versions and
  belongs in version control.
- Stale Terraform artifacts remain discoverable even when no `.tf` source file
  survives in the project.
- Operating-system junk files are not a Dev category. `file-clean-junk` owns
  them in any directory through the File deletion engine.
- Discovery uses `find` exclusively, so one set of exclusions decides both
  the displayed plan and what is removed.

## Remote-code policy

Downloading and executing code is treated as a distinct risk class.

**Installers are never piped to a shell.** No Dev command runs a downloaded
installer through `sh` or `bash`. Host `uv` maintenance delegates to the
targeted public `sys` owner, while `dev-update-tflint` reports a proven
Homebrew owner or refuses and prints the documented, verifiable procedure.
No flag enables an installer pipe.

**TFLint plugin initialization is separate from linting.**
`dev-run-tflint` does not run `tflint --init` implicitly. The caller must pass
`--init`, review the remote-code warning, and confirm or add `--yes`; only then
does initialization run, and its status is checked before recursive linting.

**Action updates change what CI executes.** `dev-update-actions` runs no
action code, but each reference it rewrites is code that the project's CI
will run. It pins every updated reference to an immutable commit SHA with the
release named in a comment, never follows a moving tag or branch, never
downgrades, stays within the current major version unless `--major` is
given, and holds back a release younger than the configured cooldown when
`gh` can prove its age. The tag listing comes from github.com over HTTPS
without credentials; a SHA pin protects against later tag movement, not
against a release that was already malicious when it was pinned.

**Ephemeral runners are opt-in.** `uvx` and `npx` can fetch and execute an
index-selected package version. Runner selection has three explicit contracts:

| Helper | Resolution order |
| --- | --- |
| `_dev_python_tool_runner` | declared dependency: runnable module through `.venv/bin/python -I -m`, then a proven `.venv/bin` executable; undeclared tool: installed binary, then `uvx` |
| `_dev_node_tool_runner` | `./node_modules/.bin/<tool>` → installed binary → `npx` (Markdownlint only) |
| `_dev_project_python_tool_runner` | importable module through `.venv/bin/python -I -m`; otherwise refuse |

Declared Python quality gates never use `uv run`: even `--frozen --no-sync`
can discover a global executable when the project copy is absent. The project
interpreter must report the exact, non-symlink `.venv` as `sys.prefix`, with a
different `sys.base_prefix`. Runnable modules and their `__main__.py` must
resolve inside that environment. Executable fallback is also confined to
`.venv`; scripts are accepted only when their shebang names the exact project
interpreter, so `#!/usr/bin/env python3` cannot escape through `PATH`.
Installed-environment inventories, such as pip-audit's vulnerability data,
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

## Metadata interpreter

The project metadata readers (`pyproject.toml`, `uv.lock`, pytest
configuration in `pyproject.toml`, `tox.ini`, or `setup.cfg`, PyPI JSON
replies, the pre-commit revision guard, and update fingerprints) need Python
3.11+ for `tomllib`. The first `python3` on `PATH` is often older: 3.9 from
Apple's Command Line Tools, 3.10 on Ubuntu 22.04. The readers therefore share
one host interpreter, resolved in this order:

1. `python3`;
2. `python3.14`, `python3.13`, `python3.12`, then `python3.11` on `PATH`;
3. the interpreter that `uv python find --system --no-project '>=3.11'`
   reports. `--system` keeps uv from answering with an unvalidated virtual
   environment in the working directory; when `python3` is a Command Line
   Tools placeholder, uv also receives `--python-preference only-managed`,
   because it would otherwise query that placeholder;
4. the project `.venv` interpreter, after the same validation the project
   runners use.

A candidate qualifies only when `-I -S -c 'import tomllib'` succeeds:
isolated and without the `site` module, the import can come only from the
standard library. Every reader runs the interpreter with the same `-I -S`, so
the working directory, `PYTHONPATH`, the user site, and `.pth` files cannot
inject code into a parser. The dispatcher and the commands that parse more than
once remember the result, including a failure, for the rest of that command
run; nothing is cached across runs, so `PATH` and interpreter changes in a
long-lived shell are seen at the next command. `python3` is therefore not a
hard dependency of any command.

When nothing qualifies, the command names the candidates it looked for and
the platform's installation routes: Homebrew (`brew install python@3.14`) or a
uv-managed Python (`uv python install 3.14`) on macOS; uv or the deadsnakes PPA
on Ubuntu and its derivatives; uv or the distribution's Python 3.11+ package
elsewhere. A uv-managed Python needs no `uv python pin`, which would change
the project's own pin.

## Persisted state

State defaults stay inside the project so a backup sits next to the file it
restores. An override may instead name a dedicated directory below the project
or the user's home. Every path is validated on **every** use, because a
relative default resolves against the caller's current directory.

| Variable | Default | Contents |
| --- | --- | --- |
| `DEV_BACKUP_DIR` | `.dev-suite-backups` | Timestamped copies of `pyproject.toml` and of each workflow file that `dev-update-actions` changes |
| `DEV_REPORT_DIR` | `dev-suite-reports` | Markdown reports from `--report` |
| `DEV_BACKUP_RETENTION` | `5` | Current invocation backup plus the newest `N-1` prior backups kept; older ones pruned; integer `1`–`100` |

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
Backups and reports are written to private temporary files and checked for
owner, type, link count, mode, and parent identity. Both use atomic
no-clobber names: the temporary is hard-linked to its final name, which never
replaces an existing file. A name that is already taken moves on to the next
unique suffix; any other link failure, such as a filesystem without hard
links, stops at the first attempt and names the state variable to move.
On WSL, a project or state directory on a Windows drive (DrvFs) reports every
file as mode `777` unless DrvFs metadata is enabled, so these private-mode
checks refuse it; the refusal adds the remedy (see
[Platform support](#platform-support)).
Same-second backup and report names receive a unique suffix rather than
overwriting another invocation. Backup pruning always excludes the backup just
published, regardless of clock skew or manipulated modification times, and
keeps it plus the newest `DEV_BACKUP_RETENTION - 1` prior backups. Pruning is
best effort and never fails the update that just published its backup: a stale
copy is removed only when it is an owned, singly linked regular file directly
below the directory, whatever its permission bits, because removing an owned
copy discloses nothing. A stale copy that cannot be proven prunable is left
in place with a warning; reading and restoring never relax the private-mode
rule.

There is no public backup command. After authorization, `dev-update-deps`
and `dev-update-precommit` take their own invocation backup through the
private `_dev_backup_pyproject` helper before publication, and
`dev-update-actions` backs up each workflow file it will change through
`_dev_backup_project_file`. A copy is named
`<stem>.<YYYYMMDD_HHMMSS>[.<n>].bak`, where the stem is the file's
project-relative path with `/` written as `%` and leading dots removed, such
as `github%workflows%ci.yml.20261004_101500.bak`; `pyproject.toml` keeps its
own name. Retention and pruning apply per stem, matching only that exact
timestamp shape, so one file's pruning never selects another file's copies.
The backup records the exact published copy and the original file mode.
Automatic `pyproject.toml` rollback accepts only that invocation-owned path,
fingerprints the destination's metadata and content, revalidates source,
destination, and both directory identities, and compares the staged bytes
with the backup immediately before publishing through a same-directory atomic
replacement. An in-place destination edit or replacement during staging is
refused. It never falls back to selecting the newest shared backup or to
restoring from Git. `dev-update-actions` instead rolls back from its private
original snapshots (see [GitHub Actions updates](#github-actions-updates));
its backups are the recovery copies.

Report buffers are cleared on every save exit path, including failure, so
content from one report cannot leak into the next.

### PyPI query cache

The per-invocation cache is created mode `700` below a validated `TMPDIR`.
The temporary root is resolved once to its canonical directory through trusted
aliases only; it must be writable and either safely owned by the current EUID
or root-owned with the sticky bit. A foreign-owned sticky root
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
| `DEV_SCAN_DEPTH` | `3` | Stack-detection depth for the menu header; integer `1`–`32`. Gate probes and file inventories use a fixed depth of 32 |
| `DEV_CLEAN_DEPTH` | `12` | Cleanup discovery depth; integer `1`–`64` |
| `DEV_CLEAN_MAX_TARGETS` | `10000` | Unique combined cleanup-plan limit; integer `1`–`50000` |
| `DEV_PYPI_TIMEOUT` | `15` | Per-request seconds; integer `1`–`300` |
| `DEV_PYPI_RETRIES` | `2` | Retries per query; integer `0`–`10` |
| `DEV_PYPI_JOBS` | `8` | Concurrent prefetch jobs; integer `1`–`32` |
| `DEV_ACTIONS_COOLDOWN_DAYS` | `7` | `dev-update-actions` holds back releases younger than this many days when an authenticated `gh` can read their age; integer `0`–`90`, `0` disables |
| `DEV_ACTIONS_TIMEOUT` | `30` | Total seconds for each github.com tag query or `gh api` call, also Git's HTTP low-speed window; integer `1`–`300` |
| `DEV_SUITE_DEBUG` | `0` | Verbose diagnostics on stderr |

Empty is not a valid override for a state directory: the suite refuses it
rather than falling back to the project root. Invalid numeric and boolean
configuration also fails closed; values are syntax-checked before arithmetic so
configuration text is never evaluated as an expression.

## Platform support

The suite runs on Linux, WSL, and macOS. Platform branches read `OSTYPE` and
the WSL evidence the core doctor uses (the WSL session variables, the interop
registration, or a Microsoft kernel release); WSL1 is told apart by its
synthetic `-Microsoft` kernel release. Tool detection keeps `command -v`
semantics and adds two platform rules, shared by the menu marks, the
dispatcher's dependency gate, the backend runners, and health:

| Area | Linux | WSL | macOS |
| --- | --- | --- | --- |
| Tool detection | A tool on `PATH` is available | A program that resolves to `/mnt/<drive>/`, such as npm's extension-less `markdownlint` or `npx` launcher on the appended Windows `PATH`, is a Windows launcher and counts as missing, with a hint to install a Linux build | `/usr/bin/git` and `/usr/bin/python3` count as missing, and are never run, while `xcode-select -p` reports no developer directory: they are Command Line Tools placeholders that open an installation dialog |
| Metadata interpreter | The [resolution order](#metadata-interpreter) | Same as Linux | Same, skipping the placeholder `python3`; uv then considers only its own installations |
| Private state and workspaces | Owner, mode, link-count, and identity checks | Refused on a Windows drive without DrvFs metadata, followed by the remedy: work in a clone under the Linux home, or add `options = "metadata,umask=22,fmask=11"` under `[automount]` in `/etc/wsl.conf` and run `wsl.exe --shutdown` | Same as Linux; `TMPDIR` below `/var/folders` resolves through the root-owned `/var` alias |
| PyPI probe advice | `ping -c1 -M do -s 1364`, `/etc/resolv.conf` | WSL2: the `eth0` MTU remedy; WSL1: the VPN adapter in Windows | `ping -D -s 1364 -c1`, `scutil --dns` |
| Homebrew ownership | The Linuxbrew prefix that holds the keg | Same as Linux | `/opt/homebrew` and an Intel `/usr/local` each own their own kegs |

Verification: `test/dev_platform.bats` selects every branch above on any host
through mocks and fixtures: an assigned `OSTYPE`, a replaced WSL detector or a
fixture `/proc`, Zsh `hash` entries that stand in for programs on a Windows
drive, an `xcode-select` mock, a no-op `chmod` for DrvFs modes, and fixture
Homebrew prefixes. The macOS CI job runs every Developer test on an Apple
Silicon runner with the BSD userland. No run on a WSL1 distribution or a project
on a DrvFs drive is recorded: Apple's placeholder dialog on a Mac without the
Command Line Tools, uv's handling of the placeholder, BSD `ping -D`, WSL1
networking, and DrvFs metadata modes remain manual checks.

## Exit statuses

| Status | Meaning |
| --- | --- |
| `0` | Success, deliberate cancellation, or a documented no-op |
| `1` | Operational failure, unmet precondition, or a refused unsafe request |
| `2` | Invalid arguments, unknown flag, or unknown dispatch token |

A declined confirmation and "this project has no Python files" are both `0`.
"No terminal available to confirm a mutation" is `1`.

## Test coverage

| File | Covered boundary |
| --- | --- |
| `dev.bats` | Shell and Markdown gates including the opt-in `npx` runner, the multi-gate result table, and the no-applicable-gate no-op |
| `dev_alignment.bats` | Parser-before-probe ordering, project-bound runners, batch metadata, fzf errors, empty and bounded configuration, project-probe exclusions, loader safety, and completion grammar |
| `dev_cleanup_safety.bats` | Root and target replacement, per-removal revalidation, generated and nested-repository exclusions, bounded depth, and stale Terraform cleanup |
| `dev_contract.bats` | The frozen 25-command fixture, five-way surface parity, dispatcher coverage, absence of retired names and aliases, cancellation, timing label, exact no-argument grammar, and invalid-argument statuses |
| `dev_interface.bats` | Double sourcing, standalone sourcing without the core runtime, loader failure without a false sentinel, stream separation, `NO_COLOR`, NUL-safe record validation, cached advisory probes, keyboard-legend accuracy, foreground private picker capture and cleanup, snapshot-validated selection and multi-select dispatch, argument forwarding, and lazy/eager parity |
| `dev_io_safety.bats` | Private state/report publication, exact restore, stream and failure propagation, exact project-runner provenance, source-read-only flags, TFLint initialization, normalized direct dependencies, and PyPI cache identity |
| `dev_maintenance.bats` | Cleanup plans, dry runs, confirmations, awkward filenames, partial failures, remote-installer refusal, an unavailable System owner, exact state modes and boundaries, best-effort pruning of world-readable and unprunable backups, PyPI helpers and probe diagnosis, and aggregate gate selection |
| `dev_output.bats` | Captured gate replay and retry commands, locked-version evidence, the hook revision table, the System owner's host toolchain result, and verbose-only policy notes |
| `dev_security_safety.bats` | Local-only audit inventory, audit remediation authorization, and bounded/pruned Bandit discovery |
| `dev_update_safety.bats` | Frozen aggregate applicability (project files and infrastructure), PyPI failures isolated from independent backends, the per-step summary, pre-commit skipping only for an inconsistent lockfile, immediate cleanup authorization, private dependency and frozen-hook plans, downgrade retention, all-stage environment installation, post-publication hook findings, exact backup and concurrent hook-config preservation, host-owner delegation, hostile Zsh option output, safe temporary roots, staged `.venv` replacement/recovery, exact-project hook execution, and stderr-only tool output |
| `dev_update_dispatch.bats` | Missing uv isolated from Terraform inspection and cleanup, child-specific dependency enforcement, and parser-before-probe maintenance routing |
| `dev_update_recovery.bats` | Validated partial hook updates, refused unsafe or interrupted candidates, failed environment installation, independent package and Git backends, scoped native HTTP stall limits, inapplicable dry-run steps, and direct retry guidance |
| `dev_update_actions.bats` | Discovery of odd workflow names and nested composite actions without following links; pinned, tag, branch, reusable-workflow, local, and Docker references; block scalars ignored; annotated-tag peeling, SHA identification by tag or tag object, and mismatched or abbreviated SHAs; patch, minor, `--major`, prerelease, and no-downgrade selection; the cooldown with an authenticated `gh` (release and commit-date ages), without `gh`, at `0`, and with an unreadable age; dry run, decline, non-interactive refusal, and `--yes`; per-file backups and preserved modes; byte-for-byte formatting with CRLF and comments; rollback after a newly failing validator or a failed publication, and kept updates with pre-existing findings; an isolated failed query, the timeout batch stop, HTTPS-only credential-free queries, refused invalid values; and the `dev-update-all` step, its dry-run preview, and the menu, dependency, batch, and completion surfaces |
| `dev_update_specifiers.bats` | Parsed dependency-span rewriting, normalized names and repeated declarations, preserved unrelated TOML and formatting, no downgrades, bounded span matching, dry-run behavior, and failed query output |
| `dev_python_relocation.bats` | Offline real-uv publication of console entrypoints and activation scripts with spaced paths, scoped relocation controls, and rejection of staged interpreters with a different minor or implementation |
| `dev_platform.bats` | The metadata interpreter's resolution order past an old `python3` (versioned, uv-managed, validated `.venv`), one resolution per command run, `-I -S` for every reader, no hard `python3` dependency, and platform installation advice; WSL1/WSL2 detection; Windows launchers on the WSL `PATH` as missing tools; DrvFs mode refusals with the WSL remedy; macOS Command Line Tools placeholders never run; platform probe advice; Homebrew ownership by the prefix that owns the binary; one hard-link attempt on a filesystem without links; and Darwin and WSL menu marks only where a command cannot run |

## Residual gaps

1. **Network paths are mocked.** No test exercises a live PyPI response, a
   live `git ls-remote` against github.com, or a live `gh api` call. Rate
   limiting, redirects, partial bodies, proxy behavior, and index metadata
   remain integration boundaries despite bounded response size, timeout, and
   retries. A real `dev-update-actions --dry-run` against this repository's
   own workflows is a manual smoke test.
2. **External tools are not one transaction.** Most `uv`, `pre-commit`, owning
   host package-manager, TFLint, and linter tests use deterministic mocks;
   relocation coverage additionally uses real uv offline with a local wheel.
   ZDX can
   atomically restore the project files it owns and propagate tool failures,
   but it cannot roll back every side effect performed inside an external
   package manager, hook, plugin, or runtime installer. Native Git low-speed
   settings bound stalled HTTP transfers, but do not bound SSH, an entire
   transfer that continues making progress, or arbitrary hook execution.
3. **Non-Linux hosts are verified through mocks only.** The implementation uses
   Zsh filesystem modules and portable command forms where practical, and
   [Platform support](#platform-support) lists its macOS and WSL branches,
   which mocks select on any host. CI runs the suite on `ubuntu-latest` and on
   an Apple Silicon `macos-15` runner with the BSD userland; a real-host run
   of the mocked macOS behavior, BSD, WSL1, or DrvFs is not recorded.
4. **Portable path operations retain same-EUID race windows.** Root, target,
   workspace, state, and environment identities are checked at narrow
   userspace boundaries, and write parents reject unsafe cross-UID
   permissions. A hostile process with the same EUID still shares ownership
   authority and can compete between a final check and `rm` or `rename`. The `.venv` directory identity also cannot freeze
   every file below it against a same-user process. Eliminating these windows
   would require platform-specific handle-relative APIs.
5. **Private atomic publication assumes normal POSIX filesystem semantics.**
   Filesystems without reliable ownership, modes, atomic rename, or hard links
   fail closed and are not a supported state backend.
6. **External Python installation is not reversible.** With an existing
   `.venv`, `dev-update-python` authorizes before starting and can recover the
   project environment transaction. The preceding
   `uv python install --upgrade X.Y` may still change uv-managed global Python
   installations, which ZDX cannot roll back.
7. **Action updates trust github.com and a line-based parser.** Tags are
   read from github.com over HTTPS; a compromised release, or a tag that
   pointed to malicious code when it was pinned, is pinned faithfully. The
   cooldown applies only with an authenticated `gh`, and a release's age is
   GitHub metadata. The parser understands block scalars but not multi-line
   flow or quoted scalars, so a `uses:` line inside one could be planned; the
   plan shows every change before authorization. A validator that already
   failed before the update cannot distinguish new findings, so such an
   update is kept and reported rather than rolled back.
8. **`dev-run-hooks`, `dev-run-ruff-format`, and the post-publication hook
   run of `dev-update-precommit` rewrite files without a confirmation.** That
   is their documented purpose and matches how the underlying tools are
   normally invoked, but it means a `dev-run-all-checks` or `dev-update-all`
   run on a project with formatting hooks can modify the working tree.

## Maintenance triggers

Update this document when any of the following happens:

- a public command is added, renamed, or removed — also update the fixture;
- a command's batch-eligibility classification changes;
- a new external tool or ephemeral runner is introduced;
- a cleanup pattern, depth bound, or protected root changes;
- an update authorization, backup, publication, or rollback boundary changes;
- a persisted-state path, permission, or retention rule changes;
- a temporary-workspace or PyPI-cache identity rule changes;
- a delegation to another suite is added or withdrawn.
