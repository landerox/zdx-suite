# Python suite contract

This document freezes the public Python interface and records the ownership and
safety boundary implemented by `functions/py-menu.zsh`,
`functions/py-common.zsh`, and the modules under `functions/py/`.

## Menu presentation

The command menu uses an 80% height, label-only rows, and a four-line details
pane below the list. Sections show only their description. The header has a
scope line, `Project: <directory name>`, because every environment and package
action targets the current project, then the state line
`Active: <environment> | Backend: <backend>`, above
`Type to filter | Enter run | Esc cancel | Ctrl-/ details`.
Multi-selection offers only its three read-only commands and adds a separate
`Tab mark | Ctrl-A all | Ctrl-D none | Read-only tasks only` legend.
Available rows start with `●`. A row whose command cannot run at all keeps its
command field in the canonical unavailable form: when the suite is sourced
without the ZDX core and neither `timeout` nor `gtimeout` exists, the bounded
`tool-list`, `tool-uninstall`, `tool-upgrade`, `venv-python-list`,
`venv-python-install`, `venv-python-pin`, and `venv-remove` rows read, for
example, `○ List Global Tools (missing: timeout or gtimeout)`. With the core
loaded, its watchdog bounds them on any host, so nothing is marked.
Removal actions follow inspection, environment setup, and tool management.
The create and rebuild descriptions state their Poetry and replacement
limitations.

## Public surface

The 16 canonical commands are:

| Area | Commands |
| --- | --- |
| Local environments | `venv-list`, `venv-create`, `venv-activate`, `venv-info`, `venv-rebuild`, `venv-remove` |
| uv-managed runtimes | `venv-python-list`, `venv-python-install`, `venv-python-pin` |
| Project packages | `package-search`, `package-install`, `package-uninstall` |
| Isolated global tools | `tool-list`, `tool-install`, `tool-uninstall`, `tool-upgrade` |

The frozen machine-readable surface is `test/fixtures/py-public-commands.tsv`;
the menu, help, dispatcher, and completion name exactly these commands, and any
other token, such as `py-menu venv-python`, returns `2` as an unknown
command.

`py-menu` opens the interactive menu, routes one command directly, or accepts
`--multi`. Multi-select is deliberately restricted to the non-interactive,
read-only `venv-list`, `venv-python-list`, and `tool-list` commands. The
selected commands run as one batch: a `[n/N]` banner and one result line per
command, a `Task Summary`, and a counted verdict with the command that reruns
each failure. A cancelled picker runs nothing and returns `0`.

## Output presentation

Human output follows [`output-spec.md`](output-spec.md):

- `venv-list`, `venv-python-list`, and `tool-list` are tables: environment,
  Python version, and state below the project path; runtime version and
  interpreter; tool, backend, and version. `venv-info` and every plan use
  key-value facts with `HOME` shown as `~`.
- Environment, runtime, and tool versions come from `pyvenv.cfg` (`version` or
  uv's `version_info`), `uv python list`, and the tool inventories.
- Plans show the target facts and their disclosures, then
  `Dry run: nothing was <verb>.` or one counted question. A decline prints
  `Cancelled: nothing was <verb>.` Frozen directory and file identities are
  revalidated after authorization but are not displayed.
- Backend commands (`uv`, `pip`, `pipx`, and Poetry) show their command as
  `$ <command>  (output shown on failure)`; their output is captured privately
  and only a failure replays its final lines. Inventory and probe diagnostics
  on stderr are not shown; a failed inventory reports its status.
- `venv-python-install` compares the installed uv runtimes before and after,
  and reports the version it added or that it was already installed.

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

Python owns only validated environments below the current project root. The
working directory may be reached through trusted aliases, such as macOS
`/tmp` or a root-owned `/home` link, under the suite's copy of the core
trusted-directory rule; the ownership, mode, and ancestor checks apply to the
canonical root, and a working directory that is itself a user-owned link is
refused. A relative `--path` is resolved against the canonical root, and an
absolute one through a trusted alias of its parent maps to the canonical
parent. On WSL, a refused project below `/mnt/<drive>`, whose DrvFs files
report mode 777 without metadata, adds a hint to work in the Linux filesystem
or to add `[automount] options="metadata,umask=22,fmask=11"` to
`/etc/wsl.conf`. The environments are:

- `.venv`;
- `venv`; and
- one direct child of `.virtualenvs/`.

An environment must be an owned, symlink-free directory with a regular
`pyvenv.cfg`; roots, parents, and state files must also be owned and not
group/world-writable. Ancestors are accepted only when owned by the current
EUID or the namespace-visible owner of `/` (normally UID 0) and protected
against replacement, except for a sticky shared root owned by that system-root
identity. `.virtualenvs` discovery accepts at most 128 safe direct-child names
under a 10-second deadline (see [Bounded commands](#bounded-commands)).
Discovery and destructive lifecycle
operations do not adopt external Poetry or Conda environments. `venv-create`
freezes the project root, creates a new `.venv` through `uv` or the
standard-library `venv` module, and never replaces an existing target. The uv
path passes `--no-python-downloads`: a missing runtime fails instead of being
downloaded implicitly and must be installed explicitly with
`venv-python-install`. Poetry creation is refused because its target path
cannot be bounded before mutation.

Activation prints a plan, requires confirmation or `--yes`, and fingerprints
the owned activation script before sourcing that exact opened descriptor.
On hosts with `/proc`, its descriptor path includes the actual current Zsh PID
so a relocatable script can resolve its location from a child process, including
when activation runs in a subshell. Ordinary scripts retain the `/dev/fd`
fallback. Environments marked `relocatable = true` cannot be activated without
`/proc/<pid>/fd`, which macOS never provides: they are refused before the plan
with `Relocatable environments cannot be activated on this host: activation
needs a stable descriptor path from /proc/<pid>/fd, and this host has none
(macOS has no /proc).` and the exact `source` command to run after reviewing
the script yourself. A flag that changes after review is refused again before
sourcing. Successful activation requires the
reviewed environment in `VIRTUAL_ENV`, its `bin` first in `PATH`, and its
validated Python executable selected. Failure restores the previous standard
activation variables, `deactivate` and `pydoc` functions, and the `pydoc` alias.
Protected or local activation parameters are refused before sourcing because
they cannot be restored as ordinary session state. Activation remains execution
of explicitly authorized shell code: restoration does not undo arbitrary
filesystem changes or other effects of a customized script.
Removal fingerprints the environment and parent, supports `--dry-run`, and
refuses any mount at or below the target before, during, and after its
quarantine. Python 3 performs that check under a 15-second deadline: on Linux
and WSL it reads the kernel mount table, `/proc/self/mountinfo` (at most
4 MiB and 16,384 records, octal escapes decoded), so bind mounts are found
too; on macOS, which has no bind mounts, it walks the environment with
`lstat` and refuses any node whose device differs from the environment's;
other kernels fail closed. `findmnt` is not required. Removal then moves the
exact object into a private same-parent quarantine before recursive
deletion. An incomplete removal retains and reports its
recovery path. `venv-rebuild` validates and shows the environment, then fails
closed, even with `--yes`, because the suite has no transactional replacement
and rollback path; it names `venv-remove` followed by `venv-create` as the
explicit two-step alternative. Its `--dry-run` changes nothing and returns
`0`.

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
inspection uses a bounded private HTTPS response, visibly escapes remote
metadata, and prints it as key-value facts. It parses JSON only, so any
Python 3 works; project-metadata parsing elsewhere needs Python 3.11's
`tomllib`. Its private response file is
created in a subshell, so the caller's `umask` is unchanged, and both the
file and its directory are removed on every exit path.

Global tools are isolated through `uv tool` or `pipx`. Inventories propagate
producer failures and enforce byte and record bounds under a deadline (see
[Bounded commands](#bounded-commands)). `tool-install` chooses `uv` first and
then `pipx` when
`--backend` is omitted; an explicitly empty backend is invalid, and the chosen
backend is shown before authorization. Uninstall and single-tool upgrade
resolve the exact inventory record and require `--backend` if a name exists in
both backends. `tool-upgrade --all` freezes, prints, revalidates, and upgrades
the exact installed set across both backends by default; `--backend` narrows
that set. It never delegates to an unbounded backend-wide transaction. Every
mutation requires confirmation or `--yes`.
The upgrade plan is a numbered `# | Tool | Backend | Version` table. With
several targets, each upgrade gets a `[n/N]` banner and one result line, and a
`Tool Upgrade Summary` table follows. A target is `updated` when its reported
version changed, `current` when it did not, and `done` when no version is
available to compare. Ordinary tool-upgrade failures permit the remaining
frozen targets to run. Statuses `130` and `143` stop later upgrades, which are
listed as not run, and remain the command's status. The verdict counts every
outcome, and each failed or interrupted target is listed with its exact retry
command. Inspect the affected tool before retrying; the suite does not retry a
mutation automatically.

## Bounded commands

Inventories (`.virtualenvs`, `uv python list`, `uv tool list`,
`pipx list --short`) and removal's mount validation run one resolved program
through `_py_run_with_timeout`. With the ZDX core loaded, it delegates to the
core `_zdx_run_with_timeout`, which prefers `timeout`, then `gtimeout`, and
otherwise uses a Zsh watchdog, so a stock macOS host needs neither. A
standalone source of the suite prefers `timeout`, then `gtimeout`, and fails
closed without either:
`Bounded Py commands need timeout or gtimeout when the ZDX core is not loaded.`
A deadline returns `124`, which the inventory reports as its failure status.

## Interpreter ownership

Environment-backed package plans and activation verify the environment's
`bin/python` target: a regular file owned by the current user or the
namespace-visible owner of `/`, never world-writable, and not group-writable.
python.org's macOS installer leaves its framework writable by group `admin`
(gid 80), the macOS administrators, who can already act as root. On Darwin
only, a group-writable interpreter is therefore accepted in
`/Library/Frameworks/Python.framework/Versions/<version>/bin` when that file
and every directory up to the framework are owned by root, never
world-writable, and group-writable only by `admin`, and the directories above
the framework pass the ordinary ancestor rule. No other location, owner,
group, or kernel gains that exception; Homebrew, uv, and pyenv interpreters
are user-owned and need none.

## Loading, selection, and residual limits

The loader derives one canonical source root, refuses symlinked or unreadable
built-in modules, preserves source failures, and sets sentinels only after
successful loading. No capability or filesystem probe occurs at source time.

`fzf` runs synchronously in the foreground. Results are captured in private,
bounded files below a validated current-user directory or sticky shared
temporary root owned by the namespace-visible owner of `/`, and accepted only
when they match the displayed snapshot. Top-level preview fields come only from
the fixed suite-owned menu snapshot. A picker that cannot be set up, read, or
cleaned up safely returns `125`, never the cancellation statuses `1` or `130`;
the menu reports `Unable to open the interactive Py menu (status 125).` and
other pickers `The Py picker failed (status 125).`, both returning `1`.

External package managers do not offer a generic rollback transaction.
Creation failure can leave a partial `.venv`, which ZDX reports and does not
delete automatically. Recursive removal requires Python 3 and Linux, WSL,
or macOS; bounded discovery uses `find -mindepth 1 -maxdepth 1 -type d`,
which GNU and BSD `find` share. External package-manager mutations do not
become
rollback-capable merely because their inputs are revalidated. A hostile process
with the same EUID retains a narrow final race around external pathname
operations. An overflow UID mapping can collapse multiple host owners into the
namespace-visible owner of `/`; in that case safety additionally depends on the
namespace and mount configuration.

## Platform support

| Capability | Linux | WSL | macOS |
| --- | --- | --- | --- |
| Bounded inventories | `timeout` | as Linux | `gtimeout`, else the core watchdog |
| Removal mount check | `/proc/self/mountinfo` | as Linux | `lstat` device walk |
| Relocatable activation | `/proc/<pid>/fd` | as Linux | refused before review |
| Ordinary activation | `/proc/<pid>/fd` | as Linux | `/dev/fd` |
| python.org framework interpreter | not applicable | not applicable | accepted as above |
| Projects on Windows drives | not applicable | refused, with DrvFs hint | not applicable |

Linux behavior runs natively in every test run. The macOS device walk, the
standalone timeout fallback, the python.org framework rule, the early
relocatable refusal, the WSL hint and detection, and trusted working-directory
aliases are verified on Linux through `uname` mocks, `PATH` shims, function
overrides, and fixtures, and the same tests run on the macOS CI job's Apple Silicon runner. Relocatable activation stays
Linux-only by design, and no WSL1 host run is recorded.

Focused coverage lives in `test/py.bats`, `test/py_contract.bats`,
`test/py_safety.bats`, `test/py_recovery.bats`, and `test/py_platform.bats`,
with trusted working-directory aliases in `test/platform_paths.bats`.
Activation coverage includes an offline relocatable environment when uv is
already installed; no package or runtime is downloaded. Platform tests cover
the core watchdog without `timeout`, the standalone fallback and its refusal,
removal on macOS without a mount table or `findmnt`, real device changes at
and below a target, escaped and malformed Linux mount tables, unsupported
kernels, picker setup failures, the early relocatable refusal,
`package-search` without `tomllib`, the framework interpreter matrix, the WSL
hint and detection, and the menu's unavailable form. Live PyPI,
package-manager mutations, a real python.org installation, and macOS or WSL
host acceptance remain manual boundaries.
