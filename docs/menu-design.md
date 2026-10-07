# Menu presentation decision

This document explains the suite-wide menu presentation, the alternatives
considered, and the measured rendering behavior behind it.
[`menu-spec.md`](menu-spec.md) remains the normative contract.

## Problem

Every command menu carries the same kinds of information: an action label, a
public command, a one-sentence description, local context, and keyboard help.
Without one shared presentation the same information looks unrelated from
suite to suite:

| Area | Risk without a shared frame | Effect |
| --- | --- | --- |
| Description placement | Bottom panes of different heights and side panes for some suites | A single sentence receives very different amounts of space |
| Overall height | Different menu heights per suite | Moving between suites changes the available list area |
| Descriptions | Some explain an outcome; others emphasize internal validation, bounds, or publication mechanics | Similar actions require different amounts of interpretation |
| Context and keys | Context mixed with keys, prompts that do not name the suite, unadvertised multi-selection keys | Orientation and keyboard help vary |
| Section preview | A section that displays `Command: :` or `Command: zdx :` | A navigation heading looks executable |
| Master catalog | Suites grouped or described by implementation rather than ownership | Ownership and available capabilities are harder to discover |

VPN has different information needs. It selects actions against current
tunnel state using a private target and a precomputed status preview. This is
a documented exception.

## Alternatives considered

| Alternative | Advantages | Costs | Decision |
| --- | --- | --- | --- |
| Let each suite choose its own layout | No shared constraints | Produces the inconsistencies above | Rejected |
| Show label and description in every list row | Descriptions can be scanned and searched together | At 80 columns, ordinary action names truncate most descriptions; the same text also occupies the preview | Rejected |
| Compact action list with one selected description below | Stable scanning width, complete selected description, follows the command-menu record contract | Filtering searches visible labels, not hidden descriptions | Selected for command menus and ZDX |
| Add a shared UI framework and nested navigation | Centralized rendering and more presentation options | Introduces loader coupling and changes navigation without solving a demonstrated functional need | Rejected |

The label-only and inline alternatives were exercised with real `fzf` in
isolated 80- and 120-column terminal sessions. At 80 columns, displaying fields
`1,3` truncated descriptions for comparison, extraction, and permissions. A
four-line bottom preview displayed the selected command and short description;
a fifth line consumed list space without adding useful information for those
records. These observations support the compact preset rather than a new
display protocol.

Filtering was also checked with `fzf --filter`: `--with-nth=1` filters the
visible label. Adding `--nth=1,2,3` does not make hidden command and description
fields searchable. The interface must not promise that behavior. ZDX puts the
suite token in each built-in label so typing `git`, `py`, or `vpn` works.

## Selected presentation

Command menus use the following common presentation, implemented by their
suite-owned wrappers and invocation options:

- 80% height, reverse layout, rounded border, and the `▶` pointer.
- The `label|command|description` record and visible label field.
- A `down:4:wrap` preview containing the public command, a blank line, and its
  description. Sections show their description without a fake command.
- `Ctrl-/` toggles details, allowing a short terminal to devote more rows to
  the list. The binding is explicitly advertised wherever it is enabled.
- A `<suite> >` prompt. Content browsers may name their current activity.
- Useful local context, when available, on separate header lines, followed by
  `Type to filter | Enter run | Esc cancel | Ctrl-/ details`.
- Multi-selection menus, Developer and Python, describe marking and their
  actual select-all and deselect-all bindings on a separate line. The toggle
  does not add multi-selection to any other menu.

ZDX uses `Enter open` because it opens a suite. VPN keeps its stateful actions
and larger status preview; its context and keyboard help use the same
vocabulary. A preview that is unavailable must not advertise a details toggle.

The optional core helpers for the theme and the field template are the only
shared runtime presentation dependencies, and every suite still works when
sourced on its own. The presentation adds no helper namespace, runtime
package, terminal-width probe, or public command.

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

Examples from the current menus:

| Action | Description |
| --- | --- |
| Inspect Large Files | Find files above a chosen size and optionally review their deletion. |
| Extract TAR Archive | Check and unpack a TAR archive into a new directory. |
| Compress Files | Create a TAR, ZIP, or 7z archive from selected local paths. |
| Push Tags | Review and publish selected tags without overwriting remote tags. |
| Create Project Environment | Create .venv with uv or Python venv; Poetry creation is currently unavailable. |

Inspection comes before common actions, followed by configuration or updates,
then destructive maintenance. Sections describe domain tasks; suites do not
need identical section names or counts. A one-action menu needs no decorative
section. Command membership and action semantics come from each suite
contract.

## ZDX catalog

The catalog uses recognizable action labels with visible route tokens, for
example `Maintain Projects (dev)` and `Manage WireGuard VPN (vpn)`.

| Group | Routes |
| --- | --- |
| Projects | `ws`, `git`, `dev` |
| Files and Environments | `file`, `env`, `py` |
| System and VPN | `sys`, `vpn` |
| ZDX Tools | `status`, `doctor`, `plugins` |

Descriptions distinguish ownership: Workspaces own the repository layout,
Git owns repository actions, Dev handles
project maintenance, Py owns project Python environments, and Sys maintains
host tools.

The header identifies the current directory without probing services, GitHub,
or authentication. Custom plugins appear only when the current runtime can
dispatch them; an empty filtered group is omitted. Their text says they are
loaded in this shell, without claiming an audit or trust record. Custom route
completion uses the same loaded-name, namespace, and function checks as routing.

## Exceptions and boundaries

- VPN keeps `label|command|description|target`, its precomputed preview,
  refresh loop, and interruption cleanup.
- Resource browsers, file pickers, confirmation dialogs, and telemetry views
  retain the space, fields, and bindings their content needs.
- Nested command selectors follow the same copy and details rules when they
  show only an action and a short description; compact decision dialogs may
  use smaller heights.
- The plugin manager's install/update trust lifecycle is a separate runtime
  concern. Catalog wording must not imply guarantees that it does not enforce.

The presentation adds no service probes. Context providers keep their
documented behavior, and capture files, foreground execution, exact snapshot
validation, fixed dispatch, dependency checks, authorization, and exit-status
propagation do not depend on it.

Dev's project name and its runtime state occupy separate context lines, so a
long project name cannot push the ephemeral-runner setting past the edge of an
80-column window.

Every top-level command menu, Git's included, reads its selection through
private foreground capture and checks the complete selected row against the
menu snapshot, not only its command token. Some nested pickers still read
their selection through command substitution; `menu-spec.md` lists them.

## Validation

The decision keeps the record format, helper signatures, theme ownership,
dispatch rules, and compact-preview recommendation in `menu-spec.md`, makes
that recommendation the default for all command menus, and adds explicit rules
for section previews, a details toggle, copy, and the master catalog. Suite
contracts continue to own behavior; this document does not broaden them.

Automated tests cover effective `fzf` options and cancellation across the
built-in menus and ZDX, specialized VPN records, and master filtering and
plugin routes. Interface and safety tests verify that presentation does not
alter dispatch or mutation boundaries, and completion and documentation are
checked against the implemented catalog.

Real `fzf` acceptance passed for Dev, File, and ZDX at both 80x24 and 160x32,
including Dev at 80 columns with its scope and state lines. Details toggled
correctly, Esc returned success, and cancellation produced no stdout data.

## Terminal compatibility

Two copies of ZDX can render differently simply because the shell loaded an
older installed copy rather than the checkout. Doctor reports the loaded
source location, and the user guide distinguishes updating a checkout from
loading that checkout in a new shell. The `<120(...)` preview threshold
concerns available preview space; terminal width alone does not establish
which layout fzf selected.

Three failure mechanisms shape the preset. A fixed light foreground such as
`fg:#c0c0c0` combined with `bg:-1` can make text disappear into a light
terminal background. Inherited `FZF_DEFAULT_OPTS` can hide records or alter
selection, and an unreadable `FZF_DEFAULT_OPTS_FILE` can stop fzf before any
UI appears. A version probe that ignores its status can report success with
an empty version.

| Alternative | Benefit | Tradeoff | Decision |
| --- | --- | --- | --- |
| Fixed RGB foreground and background | Predictable pair on a truecolor terminal | Overrides the user's profile and assumes truecolor | Rejected as the default |
| Query terminal colors and capabilities | Could adapt a custom theme | Adds terminal I/O, timeouts, and emulator-specific behavior | Rejected |
| Native foreground/background with ANSI accents | Uses the terminal's own text contrast on light and dark profiles | Palette and bold settings remain controlled by the terminal | Selected |
| Always remove colors and Unicode | Simple fallback | Removes useful presentation even when supported | Explicit plain mode |

The core and suite-owned wrappers use
`--color=16,fg:-1,bg:-1,fg+:-1,bg+:-1,border:-1:dim,info:yellow`; the final
two entries are explained under [Older fzf releases](#older-fzf-releases). An
explicit core theme remains available.
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
plugin manager's private capture and staged lifecycle are separate from
rendering.

Doctor reports rendering configuration presence, its loaded source location,
and failed version probes without reading fzf option files or revealing their
contents.

The preset uses established fzf options rather than the newer `--with-shell`
flag. Adaptive previews require fzf 0.31 or newer; the presentation does not
promise full suite support on older releases. The version history is
documented in the [upstream fzf changelog](https://github.com/junegunn/fzf/blob/master/CHANGELOG.md).

Real Linux PTY checks confirm native foreground/background output without RGB
SGR sequences for the default under both `xterm` and `xterm-256color`.
Plain mode removes color and changes picker controls to ASCII. It still uses
cursor movement: `TERM=dumb`, unsuitable terminfo, pathological palettes, and
missing font glyphs cannot be repaired universally by a preset. Native macOS
Terminal and iTerm2 acceptance remains a manual requirement in `testing.md`;
Linux tests with a different `TERM` do not establish macOS rendering.

The acceptance matrix passed 14 real Linux PTY cases with fzf 0.74.3: File,
Dev, Git, and ZDX at 80x24 and 160x32, core and standalone loading, hostile
inherited defaults, a missing options file, incompatible login shells, plain
mode, `NO_COLOR`, and a `C` locale. Rows remained visible, details toggled,
Esc returned success, section selection dispatched nothing, and cancellation
left stdout empty and removed the private capture. Light/dark comparisons
modelled the captured ANSI output; they were not native macOS sessions.

fzf's numeric field transformation retains the trailing `|` after a label.
Short labels make that boundary obvious; long dependency annotations can push
it beyond the visible width. Real fzf checks confirmed that escaping the
delimiter does not remove it. Template formatting (`--with-nth='{1}'`) removes
it while preserving the original selected record, but requires fzf 0.60.0.
Wrappers therefore keep numeric formatting for the 0.31 baseline and add the
template only after `_tk_fzf_nth_template_option` confirms that the installed
fzf accepts it; `ZDX_FZF_TEMPLATES` replaces that probe. Requiring the newer
flag unconditionally would make fzf fail to start on older installations.

Ubuntu 24.04's fzf 0.44.1 treats a bare `--delimiter='|'` as
regular-expression alternation. With `--with-nth=1`, label filtering can then
return no matches. The same input succeeds on fzf 0.74.3, so testing only a
newer binary hides the defect. Upstream
[fzf 0.58.0](https://github.com/junegunn/fzf/releases/tag/v0.58.0) introduced
literal handling for single-character delimiters. All pipe-delimited pickers
use `--delimiter='[|]'`, a literal pipe expression that works on both
versions without raising the minimum. This preserves the record format,
selected bytes, and numeric field transformation. CI installs its
distribution fzf so the native filtering regressions execute rather than skip.

### Older fzf releases

Releases before
[fzf 0.66.0](https://github.com/junegunn/fzf/releases/tag/v0.66.0), such as
Ubuntu's packaged 0.44.1, resolve the `16` base scheme's border, and the
separator, scrollbar, and preview border derived from it, to ANSI black and
the match counter to ANSI white; 0.66.0 and newer use the dim default
foreground and yellow. A terminal profile whose black equals its background
therefore hides that chrome on an older release, leaving no visible outer
border, info separator, scrollbar, or preview frame. The same release
introduced the `▌` gutter beside unselected rows.

Captured tmux output of the real System menu measures the difference: 0.44.1
emitted 29 `ESC[30m` sequences for chrome, 0.74.4 emitted `ESC[2m`. The
shared preset pins `border:-1:dim,info:yellow`, which fzf 0.28.0 and newer
parse, covering the 0.31 baseline. With it, 0.44.1 emits no black chrome and
a yellow counter, and the 0.74.4 capture is byte-identical to the capture
without the pinned entries. The gutter glyph has no equivalent before 0.66.0,
so identical rendering on an older host still requires a newer fzf; that
remains the user's installation choice rather than a raised minimum.

## Cross-suite consistency

A side-by-side capture of the System and Developer menus with real fzf 0.74.4
in an isolated 120 by 40 tmux session, and through the presentation tests'
recording fzf for every command menu, shows byte-identical chrome sequences
for the border, prompt, counter, separator, legend, section rows, and preview,
because every command menu uses the contract preset. The remaining shared
rules cover content that the frame alone leaves open:

| Area | Decision | Reason |
| --- | --- | --- |
| Context lines | An optional scope line (`Project:`, `Repository:`, `Directory:`) above a state line of `Key: value` facts | Suites that act on a location name it; host-wide suites need no scope line |
| Unavailable actions | One canonical form, `○ <label> (missing: …)`, with short requirement tokens and no nested parentheses | The row stays identifiable when truncated, and its meaning stays readable without the glyph |
| Key-value lines | One core service, `_zdx_ui_label`: 18-column keys with one colon, bold in the terminal's own foreground | Facts align across suites, and no forced color disappears on a light theme |
| Open failure | The error names fzf's exit status | System, Developer, File, Environment, Python, and ZDX report it; Git and VPN print the error without it |

The scope line is a deliberate difference. Dev and Git actions modify the
current project or repository, so naming it on its own line reduces
wrong-directory mistakes; System acts on the host, which needs no scope line.
Remediation, such as Dev's ephemeral-runner opt-in, stays in the header's
state line, the command's focused error, and the suite contract.

`test/menu_presentation.bats` checks the context-block grammar for every
command menu and the canonical availability marks for Developer,
Environment, File, Python, and System. Git's text-only marks are the
remaining gap listed in `menu-spec.md`.
