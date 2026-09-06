# Menu presentation decision

This document records the comparison and decision behind the suite-wide menu
presentation update. [`menu-spec.md`](menu-spec.md) remains the normative
contract; this document explains the alternatives and their tradeoffs.

## Problem and observed behavior

The built-in suites share safe routing and mostly share visual primitives,
but their command menus make the same information look unrelated:

| Area | Observed behavior | Effect |
| --- | --- | --- |
| Description placement | Dev, Sys, and WS use four lines below the list; Git uses five; nine suites request a 40% side pane | A single sentence receives very different amounts of space |
| Overall height | File uses 70%, Env 75%, and the remaining menus 80% | Moving between suites changes the available list area |
| Descriptions | Some explain an outcome; others emphasize internal validation, bounds, or publication mechanics | Similar actions require different amounts of interpretation |
| Context and keys | Docker combines context and keys; Env uses `environment >`; Py omits active multi-selection keys | Orientation and keyboard help vary |
| Section preview | A section can display `Command: :` or `Command: zdx :` | A navigation heading looks executable |
| Master catalog | Git mentions Workspaces, Sys mentions only services and ports, and Network is grouped under MLOps | Ownership and available capabilities are harder to discover |

App and VPN have different information needs. App selects discovered project
tasks using a private task index. VPN selects actions against current tunnel
state using a private target and a precomputed status preview. These are
documented exceptions, not missing migrations.

## Alternatives considered

| Alternative | Advantages | Costs | Decision |
| --- | --- | --- | --- |
| Keep each suite's current layout | No migration work | Preserves the inconsistencies above | Rejected |
| Show label and description in every list row | Descriptions can be scanned and searched together | At 80 columns, ordinary action names truncate most descriptions; the same text also occupies the preview | Retained for the App task browser only |
| Compact action list with one selected description below | Stable scanning width, complete selected description, follows the existing command-menu contract | Filtering searches visible labels, not hidden descriptions | Selected for command menus and ZDX |
| Add a shared UI framework and nested navigation | Centralized rendering and more presentation options | Introduces loader coupling and changes navigation without solving a demonstrated functional need | Rejected |

The label-only and inline alternatives were exercised with real `fzf` in
isolated 80- and 120-column terminal sessions. At 80 columns, displaying fields
`1,3` truncated descriptions for comparison, extraction, and permissions. A
four-line bottom preview displayed the selected command and short description;
a fifth line consumed list space without adding useful information for those
records. These observations support the existing compact preset rather than
a new display protocol.

Filtering was also checked with `fzf --filter`: `--with-nth=1` filters the
visible label. Adding `--nth=1,2,3` does not make hidden command and description
fields searchable. The interface must not promise that behavior. ZDX will put
the suite token in each built-in label so typing `app`, `ws`, or `net` works.

## Selected presentation

Command menus use the following common presentation, implemented by their
existing suite-owned wrappers and invocation options:

- 80% height, reverse layout, rounded border, and the existing `▶` pointer.
- The unchanged `label|command|description` record and visible label field.
- A `down:4:wrap` preview containing the public command, a blank line, and its
  description. Sections show their description without a fake command.
- `Ctrl-/` toggles details, allowing a short terminal to devote more rows to
  the list. The binding is explicitly advertised wherever it is enabled.
- A `<suite> >` prompt. Content browsers may name their current activity.
- Useful local context, when available, on separate header lines, followed by
  `Type to filter | Enter run | Esc cancel | Ctrl-/ details`.
- Existing multi-selection menus describe marking and their actual select-all
  and deselect-all bindings on a separate line. The toggle does not add multi
  support to any other menu.

ZDX uses `Enter open` because it opens a suite. App uses `Enter review` because
selecting project tasks leads to an execution plan and authorization. VPN keeps
its stateful actions and larger status preview; its context and keyboard help
use the same vocabulary. A preview that is unavailable must not advertise a
details toggle.

The optional core color provider remains the only shared runtime presentation
dependency. Standalone sourcing continues to work. This decision introduces no
new helper namespace, runtime package, terminal-width probe, or public command.

## Copy and ordering rules

Labels name an action and target in title case. Prefer `Show` for a report,
`List` for an inventory, `Browse` for a picker, `Inspect` for analysis, and `Run`
for execution. Keep domain distinctions: deleting, discarding, disconnecting,
restoring, and quarantining are different operations.

Descriptions are one short sentence about the result, scope, prerequisite, or
consequence. Aim for 90 characters or fewer when accuracy allows. Explain
limitations that affect a user's choice, such as TAR-only extraction or an
unsupported replacement operation. Avoid implementation vocabulary such as
"fingerprinted", "bounded", and "atomic publication" unless it changes that
choice. Safety mechanisms remain documented in the suite contracts and shown
in concrete mutation plans.

Examples, subject to each command's actual implementation:

| Action | Description |
| --- | --- |
| Search Files | Find files by name, extension, text, or modification date. |
| Extract TAR Archive | Check and unpack a TAR archive into a new directory. |
| Change Permissions | Review and change access permissions for selected local paths. |
| Stage Files | Choose working-tree files to include in the next commit. |
| Create Project Environment | Create a project-local .venv with an installed supported backend. |

Inspection comes before common actions, followed by configuration or updates,
then destructive maintenance. Sections describe domain tasks; suites do not
need identical section names or counts. A one-action menu needs no decorative
section. Existing command membership and action semantics remain authoritative.

## ZDX catalog

The catalog uses recognizable action labels with visible route tokens, for
example `Run Project Tasks (app)` and `Manage Workspaces (ws)`.

| Group | Routes |
| --- | --- |
| Projects | `git`, `ws`, `dev`, `app`, `ci` |
| Files and Environments | `file`, `env`, `py` |
| System and Network | `sys`, `docker`, `net`, `vpn` |
| AI and Hardware | `ai`, `hf`, `gpu` |
| ZDX Tools | `doctor`, `plugins` |

Descriptions distinguish ownership: Dev handles project maintenance, App runs
project-defined tasks, Py owns project Python environments, and Sys maintains
host tools. Docker owns daemon resources; App's Compose tasks remain delegated
project execution. Git owns repository actions; WS owns workspace profiles.

The header identifies the current directory without probing services, GitHub,
or authentication. Custom plugins appear only when the current runtime can
dispatch them; an empty filtered group is omitted. Their text says they are
loaded in this shell, without claiming an audit or trust record. Custom route
completion uses the same loaded-name, namespace, and function checks as routing.

## Exceptions and boundaries

- App keeps `label|app-run|description|index`, its visible task descriptions,
  current snapshot checks, and execution review. Its descriptions contain
  backend and workspace context, never project script bodies.
- VPN keeps `label|command|description|target`, its precomputed preview,
  refresh loop, and interruption cleanup.
- Resource browsers, logs, diffs, file pickers, confirmation dialogs, and live
  telemetry retain the space, fields, and bindings their content needs.
- Nested command selectors follow the same copy and details rules when they
  show only an action and a short description; compact decision dialogs may
  retain smaller heights.
- The plugin manager's install/update trust lifecycle is a separate runtime
  concern. Catalog wording must not imply guarantees that it does not enforce.

This presentation change introduces no additional service probes. Existing
context providers, including Docker's selected-daemon probe, retain their
documented behavior. Capture files, foreground execution, exact snapshot validation, fixed dispatch,
dependency checks, authorization, and exit-status propagation remain intact.

Real-terminal acceptance identified one further layout issue: Dev's project
name and runtime state together could truncate the ephemeral-runner setting
at 80 columns. They now occupy separate context lines so that a long project
name does not hide that setting.

The implementation review also found that the Git command menu accepted a
valid command token without checking its complete displayed row. Its top-level
selection now uses private foreground capture and full snapshot membership.
Nested Git pickers retain their existing paths; this correction does not imply
that those legacy adapters have been migrated.

## Contract review and validation

The decision retains the record format, helper signatures, theme ownership,
dispatch rules, and compact-preview recommendation in `menu-spec.md`. It makes
that recommendation the default for all command menus and adds explicit rules
for section previews, a details toggle, copy, and the master catalog. Existing
suite contracts continue to own behavior; this document does not broaden them.

Validation covers effective `fzf` options and cancellation across the built-in
menus and ZDX, specialized App/VPN records, and master filtering and plugin
routes. Real terminal checks cover narrow and wide layouts, preview toggling,
and section details. Existing interface and safety tests verify that visual
changes do not alter dispatch or mutation boundaries. Completion and docs are
checked against the implemented catalog, followed by the required `just check`.

The contract and implementation review accepted this design after checking
description accuracy, ownership, optional context, existing service probes,
and the App/VPN exceptions. Real `fzf` acceptance passed for Dev, File, ZDX,
and App at both 80x24 and 160x32. Dev at 80 columns and App at both sizes were
rechecked after the final context changes. Details toggled correctly, Esc
returned success, and cancellation produced no stdout data. App also has a
regression for identically named current and repository-root directories: its
metadata identifies the directory's role rather than relying on its basename.

## Terminal compatibility follow-up

A subsequent File/Dev report exposed two distinct issues: layout differences
between an installed copy and the checkout, and a past incident where option
text was invisible. Inspection found a separate older installed clone. At
80x24 and 160x32, both copies rendered and cancelled successfully; the fixture
did not reproduce missing File labels. File has 10 actions, while Dev has 49
and longer dependency annotations. List density is therefore not evidence of
different description rules. The historical invisible-text incident cannot
be attributed to a specific terminal without its original configuration.

The older File picker requested a 40% side preview with an adaptive fallback.
That fallback also selected a bottom pane in the measured wide fixture. The
`<120(...)` threshold concerns available preview space; terminal width alone
does not establish which layout fzf selected.

Two independent failure mechanisms were reproduced. The old theme combined
`fg:#c0c0c0` with `bg:-1`, which can make light text disappear into a light
terminal background. Inherited `FZF_DEFAULT_OPTS` can hide records or alter
selection, and an unreadable `FZF_DEFAULT_OPTS_FILE` can stop fzf before any UI
appears. The former version probe could then report success with an empty
version. These findings justify preventive changes without claiming to have
identified the exact historical cause.

| Alternative | Benefit | Tradeoff | Decision |
| --- | --- | --- | --- |
| Fixed RGB foreground and background | Predictable pair on a truecolor terminal | Overrides the user's profile and assumes truecolor | Rejected as the default |
| Query terminal colors and capabilities | Could adapt a custom theme | Adds terminal I/O, timeouts, and emulator-specific behavior | Rejected |
| Native foreground/background with ANSI accents | Uses the terminal's own text contrast on light and dark profiles | Palette and bold settings remain controlled by the terminal | Selected |
| Always remove colors and Unicode | Simple fallback | Removes useful presentation even when supported | Explicit plain mode |

The core and suite-owned wrappers now use
`--color=16,fg:-1,bg:-1,fg+:-1,bg+:-1`. An explicit core theme remains available.
`NO_COLOR` is an explicit `--no-color` override, including on fzf versions that
do not understand the environment variable themselves. Non-empty
`ZDX_FZF_PLAIN` adds ASCII borders, pointer, and marker; `C` and `POSIX` locales
select ASCII controls automatically. Record bytes and Unicode content remain
unchanged. These overrides are applied after invocation options.

All built-in suite, master, and plugin-manager pickers locally isolate the
three fzf default variables. They run fixed previews with `SHELL=/bin/sh`,
without changing the caller's shell or environment. VPN uses compatible
single quoting for its private preview-directory path. Custom plugins receive
the same contract and template, but remain trusted executable code. The
plugin manager's legacy capture and lifecycle gaps are separate from these
rendering changes.

Doctor reports rendering configuration presence, its loaded source location,
and failed version probes without reading fzf option files or revealing their
contents. The user guide distinguishes updating a checkout from loading that
checkout in a new shell.

The preset uses established fzf options rather than the newer `--with-shell`
flag. Current adaptive previews already require fzf 0.31 or newer; this change
does not promise full suite support on older releases. The version history is
documented in the [upstream fzf changelog](https://github.com/junegunn/fzf/blob/master/CHANGELOG.md).

Real Linux PTY checks confirm native foreground/background output without RGB
SGR sequences for the new default under both `xterm` and `xterm-256color`.
Plain mode removes color and changes picker controls to ASCII. It still uses
cursor movement: `TERM=dumb`, unsuitable terminfo, pathological palettes, and
missing font glyphs cannot be repaired universally by a preset. Native macOS
Terminal and iTerm2 acceptance remains a manual requirement in `testing.md`;
Linux tests with a different `TERM` do not establish macOS support.

The final acceptance matrix passed 14 real Linux PTY cases with fzf 0.74.3:
File, Dev, Git, and ZDX at 80x24 and 160x32, core and standalone loading,
hostile inherited defaults, a missing options file, incompatible login shells,
plain mode, `NO_COLOR`, and a `C` locale. Rows remained visible, details toggled,
Esc returned success, section selection dispatched nothing, and cancellation
left stdout empty and removed the private capture. Light/dark comparisons
modelled the captured ANSI output; they were not native macOS sessions.

README recording review exposed another visible detail: fzf's numeric field
transformation retains the trailing `|` after a label. File's short labels make
that boundary obvious; long Dev dependency annotations can push it beyond the
visible width. Real fzf checks confirmed that escaping the delimiter does not
remove it. Template formatting (`--with-nth='{1}'`) removes it while preserving
the original selected record, but requires fzf 0.60.0. The decision retains
numeric formatting for the current 0.31 compatibility baseline. A future
formatter change must review that minimum or introduce an explicit capability
contract; silently requiring a newer flag would recreate startup failures on
older installations.

The initial hosted-CI investigation found a separate compatibility defect:
Ubuntu 24.04's fzf 0.44.1 treats a bare `--delimiter='|'` as regular-expression
alternation. With `--with-nth=1`, label filtering can then return no matches.
The same input succeeds on fzf 0.74.3, so testing only the newer local binary
hid the defect. Upstream [fzf 0.58.0](https://github.com/junegunn/fzf/releases/tag/v0.58.0)
introduced literal handling for single-character delimiters. All
pipe-delimited pickers now use `--delimiter='[|]'`, a
literal pipe expression that works on both versions without raising the
minimum. This preserves the record format, selected bytes, and numeric field
transformation. CI installs its distribution fzf so the native filtering
regressions execute rather than skip.
