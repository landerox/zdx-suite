# Python suite contract

This document freezes the public Python interface and records the ownership and
safety boundary implemented by `functions/py-menu.zsh`,
`functions/py-common.zsh`, and the modules under `functions/py/`.

## Menu presentation

The command menu uses an 80% height, label-only rows, and a four-line details
pane below the list. Sections show only their description. Environment and
backend context appears above
`Type to filter | Enter run | Esc cancel | Ctrl-/ details`.
Multi-selection retains its three read-only commands and adds a separate
`Tab mark | Ctrl-A all | Ctrl-D none | Read-only tasks only` legend.
Removal actions follow inspection, environment setup, and tool management.
The create and rebuild descriptions explicitly retain their current Poetry
and replacement limitations. Environment and tool pickers keep their existing
record and preview behavior.

## Public surface

The 16 canonical commands are:

| Area | Commands |
| --- | --- |
| Local environments | `venv-list`, `venv-create`, `venv-activate`, `venv-info`, `venv-rebuild`, `venv-remove` |
| uv-managed runtimes | `venv-python-list`, `venv-python-install`, `venv-python-pin` |
| Project packages | `package-search`, `package-install`, `package-uninstall` |
| Isolated global tools | `tool-list`, `tool-install`, `tool-uninstall`, `tool-upgrade` |

`venv-python <list|install|pin>` is a compatibility adapter owned by this suite;
it is not an additional canonical command. The frozen machine-readable surface
is `test/fixtures/py-public-commands.tsv`.

`py-menu` opens the interactive menu, routes one command directly, or accepts
`--multi`. Multi-select is deliberately restricted to the non-interactive,
read-only `venv-list`, `venv-python-list`, and `tool-list` commands and prints a
passed/failed/skipped/cancelled summary.

Invalid syntax returns `2`. Interactive cancellation returns success. Help and
UI are written to stderr.

## Command grammar

```text
venv-list
venv-create [--uv|--venv|--poetry] [--python VERSION]
            [--dry-run] [--yes]
venv-activate [--path PATH] [--dry-run] [--yes]
venv-info [--path PATH]
venv-rebuild [--path PATH] [--dry-run] [--yes]
venv-remove [--path PATH] [--dry-run] [--yes]

venv-python-list
venv-python-install [VERSION] [--dry-run] [--yes]
venv-python-pin [VERSION] [--dry-run] [--yes]

package-search [PACKAGE]
package-install [PACKAGE] [--dev] [--dry-run] [--yes]
package-uninstall [PACKAGE] [--dry-run] [--yes]

tool-list
tool-install [TOOL] [--backend uv|pipx] [--dry-run] [--yes]
tool-uninstall [TOOL] [--backend uv|pipx] [--dry-run] [--yes]
tool-upgrade [TOOL|--all] [--backend uv|pipx] [--dry-run] [--yes]
```

The same grammar is accepted by each canonical direct command without the
leading `py-menu` token.

## Environment ownership

Python owns only validated environments below the current project root:

- `.venv`;
- `venv`; and
- one direct child of `.virtualenvs/`.

An environment must be an owned, symlink-free directory with a regular
`pyvenv.cfg`; roots, parents, and state files must also be owned and not
group/world-writable. Ancestors are accepted only when owned by the current
EUID or the namespace-visible owner of `/` (normally UID 0) and protected
against replacement, except for a sticky shared root owned by that system-root
identity. `.virtualenvs` discovery accepts at most 128 safe direct-child names
and requires `timeout` or `gtimeout`. Discovery and destructive lifecycle
operations do not adopt external Poetry or Conda environments. `venv-create`
freezes the project root, creates a new `.venv` through `uv` or the
standard-library `venv` module, and never replaces an existing target. The uv
path passes `--no-python-downloads`: a missing runtime fails instead of being
downloaded implicitly and must be installed explicitly with
`venv-python-install`. Poetry creation currently prints the refusal and fails
closed.

Activation prints a plan, requires confirmation or `--yes`, and fingerprints
the owned activation script before sourcing that exact opened descriptor.
On hosts with `/proc`, its descriptor path includes the actual current Zsh PID
so a relocatable script can resolve its location from a child process, including
when activation runs in a subshell. Ordinary scripts retain the `/dev/fd`
fallback; environments marked relocatable are refused before sourcing when no
stable descriptor path is available. Successful activation requires the
reviewed environment in `VIRTUAL_ENV`, its `bin` first in `PATH`, and its
validated Python executable selected. Failure restores the previous standard
activation variables, `deactivate` and `pydoc` functions, and the `pydoc` alias.
Protected or local activation parameters are refused before sourcing because
they cannot be restored as ordinary session state. Activation remains execution
of explicitly authorized shell code: restoration does not undo arbitrary
filesystem changes or other effects of a customized script.
Removal fingerprints the environment and parent, supports `--dry-run`,
requires a timeout-bounded, four-MiB JSON `findmnt` inventory parsed by
Python 3, accepts at most 4,096 decoded mount records with no mount at or below
the target, then moves the exact object into a private same-parent quarantine
before recursive deletion. An incomplete removal retains and reports its
recovery path. Automatic rebuild currently fails closed because the suite does
not yet have a transactional replacement and rollback path.

## Runtime, package, and tool boundary

Runtime install and pin operations use `uv`, validate a simple Python version,
print a plan, support `--dry-run`, require confirmation, and revalidate the
project pin target. Runtime inventory accepts only the exact bounded snapshot;
the installed view is restricted to uv-managed interpreters. Pinning sets the
reviewed directory explicitly, disables project/workspace discovery for that
write, and removes uv project, environment, and working-directory redirection
variables from the child process.

Package mutations target either the detected uv/Poetry project or a validated
project-local virtual environment. Poetry markers, project metadata, lock
state, backend selection, project-root directory identity, and the
environment's exact `bin/python` are frozen and revalidated after
authorization. Environment-backed plans also freeze the presence or exact
content identity of `pyproject.toml`, `poetry.lock`, and `uv.lock`; orphan
lockfiles fail closed. uv project mutations pass the reviewed absolute project
and working directory explicitly, remove uv target-redirection variables, and
reject membership in a workspace rooted above the reviewed project because
such a workspace shares a parent lockfile and environment. An unavailable or
malformed Poetry project never falls through to uv. Package commands never use
ambient `pip`. Package operands are simple package names; extras, direct URLs,
embedded version expressions, and explicit empty operands are refused. PyPI
inspection uses a bounded private HTTPS response and visibly escapes remote
metadata.

Global tools are isolated through `uv tool` or `pipx`. Inventories require
`timeout` or `gtimeout`, propagate producer failures, and enforce byte and
record bounds. `tool-install` chooses `uv` first and then `pipx` when
`--backend` is omitted; an explicitly empty backend is invalid, and the chosen
backend is shown before authorization. Uninstall and single-tool upgrade
resolve the exact inventory record and require `--backend` if a name exists in
both backends. `tool-upgrade --all` freezes, prints, revalidates, and upgrades
the exact installed set across both backends by default; `--backend` narrows
that set. It never delegates to an unbounded backend-wide transaction. Every
mutation requires confirmation or `--yes`.
Ordinary tool-upgrade failures permit the remaining frozen targets to run.
Statuses `130` and `143` stop later upgrades and remain the command's status.
Each failed or interrupted target includes its exact retry command; the final
summary counts passed, failed, interrupted, and not-run targets. Inspect the
affected tool before retrying; the suite does not retry a mutation automatically.

## Loading, selection, and residual limits

The loader derives one canonical source root, refuses symlinked or unreadable
built-in modules, preserves source failures, and sets sentinels only after
successful loading. No capability or filesystem probe occurs at source time.

`fzf` runs synchronously in the foreground. Results are captured in private,
bounded files below a validated current-user directory or sticky shared
temporary root owned by the namespace-visible owner of `/`, and accepted only
when they match the displayed snapshot. Top-level preview fields come only from
the fixed suite-owned menu snapshot.

External package managers do not offer a generic rollback transaction.
Creation failure can leave a partial `.venv`, which ZDX reports and does not
delete automatically. Recursive removal currently requires Linux `findmnt`,
Python 3, and `timeout` or `gtimeout`; bounded discovery relies on GNU-style
`find` options. External package-manager mutations do not become
rollback-capable merely because their inputs are revalidated. A hostile process
with the same EUID retains a narrow final race around external pathname
operations. An overflow UID mapping can collapse multiple host owners into the
namespace-visible owner of `/`; in that case safety additionally depends on the
namespace and mount configuration.

Focused coverage lives in `test/py.bats`, `test/py_contract.bats`,
`test/py_safety.bats`, and `test/py_recovery.bats`. Activation coverage includes
an offline relocatable environment when uv is already installed; no package or
runtime is downloaded. Live PyPI, package-manager mutations, and cross-platform
activation acceptance remain manual boundaries.
