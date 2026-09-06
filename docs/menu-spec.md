# Interactive menu specification

This is the canonical contract for interactive ZDX menus. General command,
safety, stream, and architecture rules are defined in
[`development.md`](development.md). Existing menus remain legacy until they
meet both documents.

The comparison, rejected alternatives, and suite-wide presentation decision
are recorded in [`menu-design.md`](menu-design.md).

## Scope

This specification applies to:

- the master `zdx` menu;
- every built-in `<suite>-menu`;
- nested action dashboards inside a suite;
- custom plugin menus, together with [`plugins.md`](plugins.md).

Content browsers such as file pickers, commit logs, process tables, and live
dashboards may use a data format suited to their records. The canonical
`label|command|description` format below is specifically for command menus.

## Design principles

1. **Direct CLI first.** Every selectable action maps to a working direct
   command. The menu is a discoverability layer, not the only interface.
2. **One action identifier.** Menu rows, dispatcher arms, help, completion,
   tests, and telemetry use the same canonical public command token.
3. **Explicit dispatch.** A `case` calls fixed functions. User-controlled text
   is never evaluated as shell code.
4. **State is visible.** Context, dependencies, and consequences are shown
   before selection or mutation.
5. **Cancellation is safe.** Esc, Ctrl-C at `fzf`, or a declined confirmation
   performs no mutation and returns `0`.
6. **Appearance is shared; behavior is local.** The core runtime owns theme
   colors. Each suite owns its prompt, fields, preview, bindings, height, and
   capability behavior.
7. **Accessibility is semantic.** Meaning cannot depend only on color, glyphs,
   alignment, or terminal width.

## Command menu record format

Each row sent to `fzf` is one newline-terminated record:

```text
label|command|description
```

The fields are:

- `label`: concise visible action text;
- `command`: the canonical public command token dispatched on Enter;
- `description`: one sentence that adds prerequisites, scope, or outcome.

Only the label is shown in the list (`--with-nth=1`). The other fields remain
available to the preview and dispatcher, but are not searchable through that
display transformation. Do not promise filtering by hidden fields. The master
catalog includes the route token in each built-in label, for example
`Run Project Tasks (app)`.

Pipe-delimited pickers MUST pass `--delimiter='[|]'`. The bracket expression
matches a literal pipe on both older and newer fzf releases. A bare `|` is
regular-expression alternation on older releases, including Ubuntu 24.04's
fzf 0.44.1, and can split labels into characters instead of fields. Shell
quoting alone does not make a regular-expression metacharacter literal.

The numeric `--with-nth=1` transformation retains the field's trailing `|` in
fzf's display. Short labels make this separator more apparent than long
capability annotations. It is not part of the action identifier. The cleaner
`--with-nth='{1}'` template requires fzf 0.60.0; the current preset retains
numeric fields to preserve compatibility with the existing 0.31 baseline.
Do not hide separators by injecting terminal escape sequences into records.

Fields MUST NOT contain a newline, NUL, or `|`. A suite that needs arbitrary
content uses a different, explicitly documented record format rather than
trying to escape this one.

Do not pad labels with trailing spaces. Alignment belongs to a content browser,
not to the command record.

### Section rows

A visual section uses `:` as a non-action sentinel:

```text
── Branching ──|:|Branch navigation and lifecycle actions.
```

Selecting a section is a no-op. Every dispatcher MUST include the `:)` arm.
Sections are navigation aids, not decorative walls: keep their number low and
put related actions together.

### Labels and descriptions

Labels begin with a verb and name the target: `Switch Branch`, `Clean Journal`,
`Browse Pull Requests`. Use title case consistently, while retaining canonical
product and command spelling. Prefer `Show` for reports, `List` for inventories,
`Browse` for pickers, `Inspect` for analysis, and `Run` for execution.

Descriptions complement the label. Prefer:

```text
Delete selected local branches while protecting the default branch.
```

Avoid:

```text
Clean local branches.
```

Use consistent vocabulary across the suite. `Remove`, `delete`, `discard`,
`reset`, `terminate`, and `clear` are not interchangeable when their recovery
properties differ.

Keep descriptions short enough to read in a compact preview; aim for at most
90 characters when accuracy allows. State relevant limitations and effects,
such as TAR-only extraction or rewriting project files. Internal details such
as identity fingerprints and atomic publication belong in implementation
contracts and concrete operation plans unless they affect the user's choice.
Delegated entries name the owning suite when that helps explain their scope.

## Canonical row helpers

Every suite with a command menu defines these private helpers in its common
file:

```zsh
_<prefix>_menu_section() {
  local title="$1"
  local description="${2:-}"

  if [[ "$title" == *'|'* || "$title" == *$'\n'* \
    || "$description" == *'|'* || "$description" == *$'\n'* ]]; then
    _<prefix>_error "Invalid menu section fields."
    return 2
  fi

  printf "── %s ──|:|%s\n" "$title" "$description"
}

_<prefix>_menu_entry() {
  local label="$1"
  local command_name="$2"
  local description="$3"

  if [[ "$label" == *'|'* || "$label" == *$'\n'* \
    || "$command_name" == *'|'* || "$command_name" == *$'\n'* \
    || "$description" == *'|'* || "$description" == *$'\n'* ]]; then
    _<prefix>_error "Invalid menu entry fields."
    return 2
  fi

  printf "  %s|%s|%s\n" "$label" "$command_name" "$description"
}
```

Arguments appear in the same order as output fields. The helpers emit data to
stdout and diagnostics to stderr.

Dependency-aware suites MAY decorate a label, for example
`○ Create Pull Request (missing: gh)`. The missing dependency MUST be written
in text; a glyph or color alone is insufficient. Decoration MUST NOT change the
command field.

## Explicit dispatcher

The dispatcher is the executable allowlist:

```zsh
_<prefix>_dispatch() {
  local command_name="${1:-}"
  shift 2>/dev/null || true

  _<prefix>_verify_command "$command_name" || return 1

  case "$command_name" in
    example-status) example-status "$@" ;;
    example-clean)  example-clean "$@" ;;
    :)              return 0 ;;
    *)
      _<prefix>_error "Unknown command: $command_name"
      return 2
      ;;
  esac
}
```

The verifier checks command-specific dependencies and runtime capabilities.
The public command still validates its concrete target immediately before use.

The following are forbidden:

- allowlist arrays followed by `"$command_name"` invocation;
- computed function names;
- `eval`, `source`, `sh -c`, or `zsh -c` for dispatch;
- separate interactive and direct implementations of the same action.

## Entrypoint routing

Every `<suite>-menu` provides both interactive and direct modes:

```zsh
<suite>-menu() {
  case "${1:-}" in
    "")
      _<prefix>_interactive
      ;;
    -h|--help)
      _<prefix>_usage >&2
      ;;
    -*)
      _<prefix>_error "Unknown option: $1"
      return 2
      ;;
    *)
      local command_name="$1"
      shift
      _timed "<suite>:$command_name" \
        _<prefix>_dispatch "$command_name" "$@"
      ;;
  esac
}
```

The timing wrapper is applied exactly once. It MUST preserve the dispatched
command's exit status. If the core timing service is unavailable during a
standalone source test, the suite invokes the dispatcher directly or uses a
documented core fallback; it MUST NOT define a competing global `_timed`.

Help is concise and includes syntax, flags, direct-command behavior, destructive
flags, and important prerequisites. Under the repository stream policy, usage
text is written to stderr.

## Building the menu model

Build rows in a local array. Do not concatenate shell code or parse formatted
terminal output:

```zsh
local -a options=(
  "$( _<prefix>_menu_section \
    "Inspection" "Read-only state and diagnostics." )"
  "$( _<prefix>_menu_entry \
    "Show Status" "example-status" \
    "Inspect the active context without changing it." )"
  "$( _<prefix>_menu_section \
    "Maintenance" "State-changing workflows with confirmation." )"
  "$( _<prefix>_menu_entry \
    "Clean Cache" "example-clean" \
    "Preview and remove selected cache entries." )"
)
```

If a row helper fails, menu construction MUST stop instead of inserting a
partial or malformed record.

Static menu order follows the user's workflow:

1. context and read-only inspection;
2. common reversible actions;
3. advanced or remote actions;
4. destructive maintenance last.

Within a section, use task order when a workflow exists; otherwise sort by the
user's likely frequency, then alphabetically for ties.

## `fzf` ownership and theme

The core runtime provides the visual theme. The currently exported compatibility
helper is `_tk_fzf_color_opts`. A suite may consume it only when it is already
defined; a suite MUST NOT source `git-common.zsh` to obtain it.

The default is `--color=16,fg:-1,bg:-1,fg+:-1,bg+:-1`: ANSI palette accents
with foreground and background inherited together from the terminal, including
the current row. Do not combine a fixed light RGB foreground with an inherited
background. This keeps ordinary text consistent with both light and dark
terminal profiles without requiring truecolor or a terminal query.

The core honors an explicit `ZDX_FZF_THEME` override. Non-empty `NO_COLOR` or
`ZDX_FZF_PLAIN`, and `TERM=dumb`, take precedence and return `--no-color`.
Standalone wrappers use the same native-color fallback without loading core.

Functional options are constructed at invocation time in a suite wrapper:

```zsh
_<prefix>_fzf() {
  local -a options=(
    --height=80%
    --layout=reverse
    --border=rounded
    --delimiter='[|]'
    --with-nth=1
    --pointer='▶'
    --color=16,fg:-1,bg:-1,fg+:-1,bg+:-1
  )

  if typeset -f _tk_fzf_color_opts &>/dev/null; then
    local theme_option
    theme_option=$(_tk_fzf_color_opts)
    [[ -n "$theme_option" ]] && options+=("$theme_option")
  fi

  local -a terminal_options=()
  local terminal_locale="${LC_ALL:-${LC_CTYPE:-${LANG:-C}}}"
  if [[ -n "${ZDX_FZF_PLAIN:-}" || "$terminal_locale" == C \
    || "$terminal_locale" == POSIX || "${TERM:-}" == dumb ]]; then
    terminal_options+=(--no-unicode '--pointer=>' '--marker=+')
  fi
  if [[ -n "${NO_COLOR:-}" || -n "${ZDX_FZF_PLAIN:-}" \
    || "${TERM:-}" == dumb ]]; then
    terminal_options+=(--no-color)
  fi

  FZF_DEFAULT_OPTS='' FZF_DEFAULT_OPTS_FILE='' FZF_DEFAULT_COMMAND='' \
    SHELL=/bin/sh fzf "${options[@]}" "$@" "${terminal_options[@]}"
}
```

Do not store command-substitution results in a global `fzf` option array at
source time. That breaks standalone sourcing and freezes configuration before
invocation.

The wrapper empties `FZF_DEFAULT_OPTS`, `FZF_DEFAULT_OPTS_FILE`, and
`FZF_DEFAULT_COMMAND` only for its `fzf` invocation. Inherited options can hide
rows, change the output protocol, supply executable bindings, or fail before
the picker opens. Suite options remain explicit; the caller's environment and
standalone `fzf` configuration remain intact. Pass the theme as one quoted
array element, never by shell word splitting.

Compatibility overrides come last so callers cannot accidentally re-enable
color or Unicode controls under an explicit opt-out. Non-empty
`ZDX_FZF_PLAIN` selects colorless ASCII picker controls; effective `C` and
`POSIX` locales select ASCII controls automatically, including when no locale
variable is set. This changes borders,
pointer, and marker, not row content or selected record bytes. It does not
transliterate filenames or section labels. `NO_COLOR` disables picker colors
without changing Unicode controls.

These settings do not make a cursorless terminal interactive. Full menus need
a working terminal, suitable terminfo, and `fzf`; direct commands remain the
fallback for `TERM=dumb`. Current responsive previews require `fzf` 0.31 or
newer. The portable preset avoids newer shell-selection flags and does not
require a patched font. Native macOS rendering must be checked in Terminal and
iTerm2; rendering portability does not expand an action's platform support.

Suites own their behavior options, including:

- prompt and header;
- delimiter and visible fields;
- preview program and placement;
- multi-select and expected keys;
- reload, execute, and toggle bindings;
- responsive layout.

Top-level command menus and the master catalog use the 80% preset above.
Compact decision dialogs may use a smaller height, and content browsers retain
the layout needed by their records. Do not place command-menu bindings in a
wrapper also used by content browsers unless every invocation supports them.

## Header, prompt, and keyboard legend

The top-level prompt identifies the suite: `git >`, `env >`. A content browser
may identify its current activity: `git branches >`, `sys services >`.
The header separates useful context from keyboard help:

1. optional current context, such as repository, branch, host, or authentication state;
2. an accurate keyboard legend for bindings active in that exact `fzf` call;
3. additional multi-selection keys, only when enabled.

Example:

```text
Repository: zdx-suite | Branch: main | Identity: configured
Type to filter | Enter run | Esc cancel | Ctrl-/ details
```

Rules:

- No raw ANSI escapes in headers, prompts, labels, or descriptive previews.
- Use plain text and restrained repo-standard Unicode.
- Do not claim `Tab` performs search; typing filters. Mention `Tab` only when
  multi-select or a real binding is enabled.
- Do not advertise inactive keys.
- Command menus bind `--bind='ctrl-/:toggle-preview'` and advertise it as
  above. The master uses `Enter open`; App uses `Enter review` before its
  execution plan and authorization. A browser with no preview advertises no
  details toggle.
- Multi-selection menus retain their existing authorized action scope. Show
  `Tab mark` and any bound `Ctrl-A all | Ctrl-D none` keys on a separate line.
- Avoid emoji as the sole carrier of meaning.

ANSI is allowed in source content such as `git diff --color=always` only when
the corresponding `fzf` call uses `--ansi`. UI chrome remains plain.

## Previews

The default command-menu preview shows the canonical command and description:

```zsh
--preview='case {2} in :) printf "%s\n" {3} ;; *) printf "Command: %s\n\n%s\n" {2} {3} ;; esac'
```

The sentinel branch displays a section's description without presenting `:` as
an executable command. ZDX's action branch displays `Command: zdx <route>`.
The program remains constant: placeholders are shell-quoted by `fzf`, never
assembled from selected text by ZDX.

Wrappers scope `SHELL=/bin/sh` to `fzf`, so fixed POSIX preview programs do not
depend on the user's login shell. ZDX implementation remains Zsh. A validated
path embedded in a preview must use quoting compatible with `/bin/sh`; Zsh's
`${(qq)value}` preserves literal single quotes and newlines. Do not assume
`${(q)value}` always produces POSIX shell syntax. This does not authorize
embedding selected record text in a program.

A custom preview earns its space by showing current state, prerequisites,
scope, consequences, or a read-only sample. It must not paraphrase the
description.

Preview programs MUST be read-only. They MUST NOT:

- prompt, mutate state, request `sudo`, or access a write API;
- expose tokens, environment secrets, private keys, or unmasked config;
- execute a command name taken from a row;
- interpolate an unvalidated path, revision, PID, URL, or identifier into
  shell program text;
- rely on `eval`.

For arbitrary filenames or records, prefer NUL-delimited input with
`--read0/--print0` and carry an opaque validated identifier. Revalidate the
identifier after selection because state may change while `fzf` is open.

## Preview layout

Use the smallest preview that answers the decision:

- `down:4:wrap` for all command menus with one-sentence descriptions;
- `right:40%:wrap,<120(down:4:wrap)` for compact contextual content;
- `right:50%:wrap,<120(down:8:wrap)` for diffs, logs, JSON, or file content;
- a hidden preview only when a documented binding toggles it.

The `<120(...)` fallback is preferred for narrow terminals. Do not allocate a
large right pane to duplicated copy.

App retains its four-field task browser with visible label and description.
VPN retains its four-field target records and larger precomputed status pane.
These exceptions are governed by their suite contracts. Toggling details must
not change selection, snapshot validation, or dispatch behavior.

## Selection and cancellation

An interactive `fzf` process MUST run synchronously in the terminal foreground.
Do not place it inside command substitution or launch its pipeline as a
background job. A suite-owned capture helper MUST:

- call the suite `fzf` wrapper as a plain foreground command;
- redirect only selection stdout into a private, bounded, invocation-owned
  result file;
- return the exact `fzf` status and place the selection in `REPLY`; and
- clean up the exact validated result on every normal control path, while
  refusing to remove a target whose identity changed.

The input producer may use process substitution because it does not access the
terminal. Capture the complete selected record, distinguish cancellation from
failure, verify that it belongs to the current row snapshot, and only then
extract the command field:

```zsh
local selected=""
local -i fzf_rc=0
_<prefix>_fzf_capture \
  --prompt='<suite> > ' \
  --header='Type to filter | Enter run | Esc cancel | Ctrl-/ details' \
  --bind='ctrl-/:toggle-preview' \
  --preview='case {2} in :) printf "%s\n" {3} ;; *) printf "Command: %s\n\n%s\n" {2} {3} ;; esac' \
  --preview-window='down:4:wrap' \
  < <(printf "%s\n" "${options[@]}") || fzf_rc=$?
selected="$REPLY"

if (( fzf_rc != 0 )); then
  (( fzf_rc == 1 || fzf_rc == 130 )) && return 0
  _<prefix>_error "Unable to open the interactive menu (status $fzf_rc)."
  return 1
fi
[[ -z "$selected" ]] && return 0
local snapshot_row=""
local -i snapshot_match=0
for snapshot_row in "${options[@]}"; do
  if [[ "$snapshot_row" == "$selected" ]]; then
    snapshot_match=1
    break
  fi
done
(( snapshot_match )) || {
  _<prefix>_error "The selected action was not in the menu snapshot."
  return 1
}

local command_name="${${selected#*|}%%|*}"
[[ "$command_name" == ":" ]] && return 0

_timed "<suite>:$command_name" _<prefix>_dispatch "$command_name"
```

Do not infer the action from the label. Do not use `cut` on a record when Zsh
parameter expansion is sufficient.

## Dependencies in the menu

Menu rendering MAY check lightweight dependency presence so unavailable actions
are explained before selection. This is advisory only.

The dispatcher MUST perform the authoritative dependency check for both menu
and direct invocation. A binary that is missing, unauthenticated, too old, or
backed by an unavailable daemon produces a focused error and returns non-zero.

Unrelated missing optional tools do not prevent the menu from opening.

## Multi-select

Multi-select is opt-in. Use it only when actions are independent, order is
defined, and a combined summary is useful.

When enabled:

- expose `-m|--multi` in help and completion;
- use `--multi` and an accurate Tab legend;
- discard section sentinel rows;
- preserve selection order or document the execution order;
- run actions sequentially unless parallel safety is proven;
- continue or fail fast according to an explicit flag;
- report passed, failed, skipped, and cancelled counts;
- return non-zero when a required selected action fails.

Transactional Git history operations, privileged operations, and actions that
change the context needed by later actions SHOULD remain single-select.

## Stateful and nested menus

A loop is allowed only when the screen is a stateful manager whose visible
state must refresh after an action, such as a connection, stash, service, or
plugin manager.

Every loop MUST:

- offer an obvious Esc path that returns `0`;
- refresh discovery after a mutation;
- avoid repeating confirmations or expensive authentication unnecessarily;
- clear per-iteration local state explicitly, and declare every in-loop
  `local` with an initializer: re-declaring an existing same-scope local
  without one makes Zsh print the variable's value on every later iteration;
- stop on an unrecoverable failure;
- avoid trapping the user in a top-level suite menu.

A normal suite menu executes one selected command and returns to the shell.

## Destructive actions and bindings

An `fzf --bind=execute(...)` action MUST NOT perform a destructive or privileged
mutation directly. The binding may return an action identifier to Zsh, where
the normal validation, preview, confirmation, and return-status path runs.

Never bind a single key directly to `rm`, `kill`, `git reset`, `git push
--force`, a write API, or `sudo`.

## Accessibility and terminal resilience

- Every menu has a descriptive prompt and header.
- Status is expressed in text, not color alone.
- Keys have textual labels.
- Rows remain understandable without glyph support.
- Narrow-terminal fallbacks keep the selection list usable.
- Long labels and descriptions wrap in the preview rather than being manually
  padded or truncated into ambiguity.
- Screen-reader users can invoke every action through the direct CLI.

## Contract synchronization

For a suite, these sets MUST be identical unless an intentional exception is
documented:

- public direct subcommands accepted by `<suite>-menu`;
- non-sentinel command fields in the top-level menu;
- dispatcher arms;
- Zsh completion entries;
- public commands named in help.

Tests SHOULD compare these surfaces automatically. A menu entry without a
dispatcher arm, such as a displayed action that always reaches `Unknown
command`, is a release-blocking defect.

## Validation checklist

Before declaring a menu conforming:

- [ ] Direct CLI behavior is implemented and tested before menu wiring.
- [ ] Row fields follow `label|command|description` and reject delimiters.
- [ ] Section rows dispatch to a no-op.
- [ ] The dispatcher is an explicit `case` and forwards arguments safely.
- [ ] Help, menu, dispatcher, completion, and tests expose the same commands.
- [ ] `fzf` options are built at invocation time.
- [ ] The core theme is optional during standalone suite sourcing.
- [ ] Headers and prompts contain no raw ANSI and advertise only active keys.
- [ ] Previews are read-only, masked, responsive, and non-duplicative.
- [ ] Esc and declined confirmations return `0` without mutation.
- [ ] Direct invocation repeats dependency and capability checks.
- [ ] Destructive actions leave `fzf` before confirmation and mutation.
- [ ] Focused BATS tests cover selection, cancellation, unknown dispatch, and
      missing dependencies.
- [ ] `just check` passes.

## Prohibited patterns

- Sourcing another suite's common file for UI helpers.
- Treating a suite-private `_tk_*` helper as a core service.
- A global `fzf` array evaluated while the file is sourced.
- Raw ANSI inside `--header`, `--prompt`, labels, or descriptions.
- Help, progress, prompts, or blank UI lines on stdout.
- Allowlist arrays plus indirect execution.
- `eval` or computed function names.
- Mutation inside preview or `execute(...)` bindings.
- Unvalidated formatted rows reused as mutation targets.
- A menu-only action with no direct command.
- Silent unknown commands or missing dependencies.
- `set -e` in a sourced interactive workflow.
