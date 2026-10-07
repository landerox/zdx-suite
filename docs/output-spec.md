# Command output specification

This is the canonical contract for what ZDX commands print while they work:
plans, step progress, child-tool output, results, summaries, and timing. The
general engineering and stream rules live in
[`development.md`](development.md); interactive menus live in
[`menu-spec.md`](menu-spec.md). This document covers everything a command
prints after it is dispatched, whether it was started from a menu or directly.

The words **MUST**, **MUST NOT**, **SHOULD**, and **MAY** are normative.
The System `update-system` and `clean-system` aggregates and the Developer
`dev-update-all`, `dev-run-all-checks`, and multi-select batch aggregates are
the reference implementations. The VPN suite is the reference
for [report sections](#report-sections) and
[exact-target plans](#exact-target-plans).

System, Developer, Python, VPN, File, and Workspace print their headings and
any key-value lines through the core services. The remaining gaps are:

- Git and Environment print headings with their own `_git_header` and
  `_env_header`, and `_git_label` does not delegate to `_zdx_ui_label`.
- Git and `zdx-doctor` still print some hand-rolled `(s)` plurals.
- The master `zdx` menu prints its own `ℹ [info]` and `✘ [error]` message
  forms instead of the glyphs below.

The [adoption checklist](#adoption-checklist) lists what closing a gap needs.

## Streams

- `stdout` carries only documented data. Every element described here is UI
  and MUST go to `stderr`.
- Child-tool output is UI. It is captured or streamed to `stderr` and MUST
  NOT reach `stdout` unless the command documents it as data.
- Caller and tool text is data: escape it with `${(V)…}` and print it with
  `printf '%s'` or `print -r`, never as a format string.
- A read-only command MAY offer machine output with `--json`; its `stdout`
  then follows [JSON output](#json-output) instead of carrying no data.

## Color and terminal behavior

- Color is used only when `stderr` is a terminal, `NO_COLOR` is empty, and
  `TERM` is not `dumb` (`_zdx_ui_color_enabled`). Without color, no escape
  sequence is printed at all.
- Meaning MUST NOT depend on color alone. Every glyph is paired with a word.
- Commands MUST NOT use cursor control or spinners when `stderr` is not a
  terminal.
- Glyphs are UTF-8. In a C or POSIX locale, display width is counted in bytes,
  so tables stay readable but can drift out of alignment.

## Glyphs and message kinds

| Glyph | Meaning | Typical helper |
| --- | --- | --- |
| `➜` | progress or information | `_<prefix>_info` |
| `✔` | success | `_<prefix>_success` |
| `⚠` | non-fatal warning or required disclosure | `_<prefix>_warn` |
| `✘` | failure | `_<prefix>_error` |
| `⊘` | skipped or not applicable | outcome rendering |
| `–` | not run | outcome rendering |
| `→` | handed to another owner | outcome rendering |
| `$` | a command whose output is captured or streamed | captured execution |

Detail lines are indented two spaces and dimmed. A message is written once:
a step that reports its outcome to an aggregate MUST NOT also print its own
success line (see [step results](#step-results-and-the-result-slot)).

## Key-value lines

A labelled fact, such as a repository origin or a version, is one key-value
line rendered by `_zdx_ui_label <key> <value>` through the suite
`_<prefix>_label`:

```text
  Origin:            https://github.com/junegunn/fzf.git
  Current commit:    b1be3a8
```

- The line is indented two spaces. The key ends in exactly one colon, which the
  service adds when the caller omits it, and is padded to 18 display columns
  plus one space; a longer key is followed by a single space.
- The key is bold in the terminal's own foreground color. A forced color such
  as bright white disappears on a light theme.
- Every suite uses the same width so facts align across suites. A list of more
  than a few records with several fields is a table instead.

## Headings

- A command's top-level heading is `════ Title ════`, surrounded by one blank
  line (`_zdx_ui_heading`, used through the suite `_<prefix>_header`).
- Inside an aggregate step the step banner already names the work, so a child
  heading is omitted. With `ZDX_VERBOSE=1` it is printed as a demoted
  `▸ Title` sub-heading instead.
- A command prints one heading. Context that introduces a plan, such as a
  sweep root, is a key-value line under that heading, not a second heading.

## Report sections

A read-only report about several subjects, such as one section per tunnel,
groups them under sub-headings rendered by `_zdx_ui_section [--first] <title>`:

```text
════ VPN IP & Exit Info ════

▸ wg0
  Internal IP:       10.0.0.2/24
  Endpoint:          203.0.113.7:51820
  Handshake:         42s ago

▸ Public exit
➜ Querying public IP providers...
  IP:                198.51.100.9
  Provider:          ipinfo.io
```

- A section is one blank line and `▸ Title`, indented by the step depth. It is
  content, so a step never omits it.
- The section that directly follows a heading passes `--first`, because the
  heading already ends with a blank line.
- Inside a section, a state uses one glyph line, facts are key-value lines,
  repeated records are a table, and notes are dim detail lines. Raw excerpts,
  such as log lines, are indented behind a `│` gutter.
- A diagnosis ends with one verdict line, such as
  `Project health: all checks passed.` or
  `Project health: 2 issues found — review the output above.`.
  An inventory prints a verdict only when it found a problem.
- Paths are shown with `HOME` as `~` (`_zdx_ui_command_display`). A persisted
  report MAY keep the complete path.

## Aggregate commands

An aggregate runs several independent steps under one authorization. Its
output has this order:

1. **Heading and plan.** A numbered table of the frozen applicable steps. The
   numbers, labels, banners, and summary rows MUST match. Steps that do not
   apply are either omitted or listed without a number as
   `⊘ not applicable (<reason>)`; a step that cannot start is listed as
   `✘ blocked (<reason>)`.
2. **Disclosures.** At most three short warning lines for facts the user must
   accept before authorizing: privileged steps, mutable upstream code, and the
   fact that one authorization covers every step. Static policy explanations
   (lock paths, retry and lock policies, phased rollouts) belong in
   `--verbose`, `--dry-run`, and `--help`, not in the default plan.
3. **Authorization.** One aggregate question that names the scope, or the
   documented `--yes`. A decline prints `Cancelled.` with a short note, starts
   no step, and returns `0`. A non-interactive run without `--yes` fails
   closed and names the flag. Children that must confirm an exact target set
   keep the terminal for that confirmation.
4. **Steps.** For each step: a banner `── [n/N] Label ──…`
   (`_zdx_ui_step_banner`), the step's own progress, then exactly one result
   line `<glyph> [n/N] Label — <outcome>[: <detail>] (<duration>)`
   (`_zdx_ui_step_result`).
5. **Summary table.** `Step | Result | Time | Detail` in execution order,
   including skipped and not-run rows, rendered by `_zdx_ui_step_summary`
   from `label<TAB>outcome<TAB>seconds<TAB>detail` records. An aggregate that
   runs inside an enclosing step prints no table unless `ZDX_VERBOSE=1`: the
   enclosing summary already has its row.
6. **Verdict.** One line with counts, for example
   `System update completed with partial failures: 1 of 11 steps failed.`
   The verdict carries no total time: the outermost timer prints it.
7. **Retry hints.** Exact public commands for failed, blocked, timed-out, and
   interrupted-before-start steps. Hints MUST NOT add `--yes`; they keep
   `--dry-run` for a dry run and are deduplicated.

A read-only gate, such as `dev-run-all-checks`, or a batch the user selected,
such as `dev-menu --multi`, needs no plan, disclosures, or authorization. It
starts with its steps and keeps the summary, verdict, and retry hints.

A step returning `130` or `143` stops the aggregate. Later steps are listed as
`not run`, and that status is returned. `--fail-fast` lists later steps as
`not run` with the detail `stopped by --fail-fast`. Any failed step makes the
aggregate return non-zero; when others succeeded, the aggregate calls
`_zdx_timed_mark_partial` so the timer says `completed with partial failures`.

## Exact-target plans

A command that changes an exact set of files or directories, such as a
cleanup, a snapshot, a restore, or a project initialization, follows the
aggregate order with targets instead of steps:

1. **Plan.** A numbered table of the reviewed targets with `~` paths, and an
   action column when actions differ. A column that would repeat one value
   for every row, such as the action of a plan that only deletes, is
   omitted.
2. **Facts and disclosures.** Key-value lines for shared context, such as the
   profile directory, and at most three disclosure lines, such as
   `The backup wg0.conf.bak-vpn-menu is kept; pass --with-backup to delete it.`
3. **Dry run or authorization.** A dry run stops with
   `Dry run: <count> planned; nothing was <verb>.` The question names the
   counted scope, such as `Disconnect 2 tunnels?`; a decline prints
   `Cancelled: nothing was <verb>.` and returns `0`.
4. **Results.** One line per target in plan order, such as
   `✔ wg0.conf → office.conf`.
5. **Verdict.** `<Subject> completed: <count> <verb>.`,
   `<Subject> completed with partial failures: F of T <noun> failed.`, or
   `<Subject> failed: F of T <noun> failed.` A partial failure calls
   `_zdx_timed_mark_partial`.

An empty plan prints one line, such as
`No VPN interfaces are currently active.`, and returns `0`.

## Outcome vocabulary

| Token | Rendered | Class | Meaning |
| --- | --- | --- | --- |
| `updated` | `✔ updated` | success | before/after evidence shows a change |
| `current` | `✔ current` | success | evidence shows nothing needed to change |
| `done` | `✔ done` | success | the step succeeded without change evidence |
| `passed` | `✔ passed` | success | a check or gate passed |
| `delegated` | `→ delegated` | info | another owner is responsible; nothing ran here |
| `planned` | `➜ planned` | info | a dry run or preview computed the work |
| `skipped` | `⊘ skipped` | neutral | not applicable or declined |
| `not-run` | `– not run` | neutral | stopped by an interruption or `--fail-fast` |
| `failed` | `✘ failed` | failure | the step failed |
| `blocked` | `✘ blocked` | failure | a precondition prevented the step from starting |
| `interrupted` | `✘ interrupted` | failure | the step received INT or TERM |
| `timed-out` | `✘ timed out` | failure | a bounded step reached its deadline |

**Change evidence.** A step reports `updated` only when it can compare a
stable identity before and after: a normalized version, a commit, a content
checksum, or a parsed count. Equal evidence is `current`. Success without
evidence is `done`. A zero exit status alone MUST NOT be presented as an
update.

A suite's machine protocol keeps its own vocabulary, and its consumer maps it
to these tokens.

## Step results and the result slot

`_zdx_step_exec <command...>` runs one step in the current shell with a
dynamically scoped result slot, measures it, and sets
`reply=(outcome detail seconds)`. It never redirects the step's input or
output; the caller decides whether a step gets closed stdin.

A command reports its result with the suite wrapper
`_<prefix>_report_result <outcome> <detail> <standalone message>`:

- inside a step in the same shell, the outcome and detail are recorded
  (`_zdx_step_report` returns `0`) and nothing is printed;
- outside a step, or from a subshell where the slot is unreachable, the
  standalone message is printed instead.

The last report wins. A delegating parent that only hands work to another
command SHOULD report `delegated` first, so a child's more specific report
replaces it, or check `_zdx_step_reported`. The exit status is authoritative:

| Exit status | Reported outcome | Final outcome and detail |
| --- | --- | --- |
| `130`, `143` | any | `interrupted`, `status N` unless a failure detail was reported |
| `124` | not a failure | `timed-out`, `status 124` |
| other non-zero | not a failure | `failed`, `status N` |
| non-zero | a failure outcome | kept |
| `0` | none | `done` |
| `0` | any valid outcome | kept |

## Captured child-tool output

`_zdx_run_captured <display> <max_bytes> <replay_lines> <command...>` is the
default for chatty tools:

- It prints `$ <display>  (output shown on failure)`. The display is the
  human-readable command, such as `git -C ~/.fzf pull --ff-only origin`,
  never an internal identifier.
- The command runs with closed stdin. Its stdout and stderr go to a private
  owner-only directory below a validated `TMPDIR`, bounded to the final
  `max_bytes` (default 256 KiB).
- On success nothing more is printed. On failure the final `replay_lines`
  lines (default 80) are replayed as `│ <line>`: control characters escaped,
  color removed, progress-bar carriage returns collapsed, and lines that look
  like credentials replaced by `[redacted potentially sensitive output]`.
- `replay_lines 0` never shows the output, in any mode. Use it for vendor
  updaters whose output may contain secrets.
- The directory and log are identity-checked and removed on every exit path.

`_zdx_run_captured_here` has the same contract but runs the command without a
pipeline, so a shell function such as `nvm use` can change the current shell.
It bounds only what it reads back, so it is for small outputs.

Package-manager transactions (APT, Homebrew, Snap, native backends) stream
their output live and are not captured. Interactive children are never
captured.

## Durations

`_zdx_format_duration <seconds>` is the only display format:

| Elapsed | Display |
| --- | --- |
| under 10 s | one decimal, `0.4s`, `9.9s` |
| 10 s to under 60 s | whole seconds, `24s` |
| 1 min to under 1 h | `1m 18s` |
| 1 h or more | `1h 02m` |

Rounding never produces `60s` or `60m`, and `LC_NUMERIC` cannot change the
decimal point. Telemetry records keep their own machine format.

## Counted nouns

Use `_zdx_count_noun <count> <singular> [plural]`. Text such as `(s)` or
`(ies)` MUST NOT be printed.

## Timing footer

`_timed` prints its `<suite>:<command> completed in …` footer only when it is
the outermost timer and no aggregate step is active. Nested timers, such as a
command delegated to another suite or a step wrapped for telemetry, print
nothing but still write their opt-in telemetry record. The record schema is
defined in `development.md` and does not change.

## Verbosity

- `ZDX_VERBOSE=1` (a configuration or environment value; any other value is
  off) streams captured tool output live and shows demoted child headings.
- An aggregate's `--verbose` flag sets `ZDX_VERBOSE=1` for that run only. It
  MAY also show plan policy lines and complete invocations.
- A child's explanatory notes that the aggregate plan already states, and
  detail that its result line already conveys, are printed in a standalone run
  but omitted inside a step unless `ZDX_VERBOSE=1`.
- Verbosity never changes stdout data, exit statuses, prompts, telemetry, or
  `replay_lines 0` outputs. Verbose streaming is raw: it is not filtered by the
  credential redaction, which is an explicit operator choice.

## JSON output

A read-only command can print its result as one JSON document for scripts
and other tools. Human output keeps every rule above; these rules govern
`--json`:

- Only read-only commands accept `--json`. With `--json` a command never
  opens fzf and never prompts; when a required selection is missing it fails
  as a usage error (status `2`).
- `stdout` carries exactly one JSON object followed by a newline and nothing
  else; no ANSI. Warnings and errors still go to `stderr`, and the timing
  line (the `_timed` footer) stays on `stderr`.
- The document is compact: jq MUST run with `-c` (and `-M`, for example
  `jq -cMn …`), so `stdout` is exactly one line followed by a newline, ready
  for status lines, tmux, and other line-based tools.
- Build JSON only with jq (jq is a core prerequisite), never by string
  concatenation or `printf` of data. Data reaches jq only as `--arg` or
  `--argjson` values of `jq -n`, or as raw data on standard input or through
  `--rawfile`, such as TAB-separated records read with `--raw-input` and
  `--slurp` when a list could exceed the argument size limit. Data is never
  interpolated into the jq program text, and jq performs all JSON encoding.
  If jq is missing, report the missing capability on `stderr` and return
  `1`.
- The first key is `"schema": "zdx.<command>.v<N>"`, for example
  `zdx.git-status.v1`.
- Keys are snake_case. Unknown or unavailable values are `null`, never `""`
  or `"unknown"`. Booleans are JSON booleans. Counts, sizes (bytes), and
  durations (milliseconds) are numbers; timestamps are ISO-8601 UTC strings.
- Not applicable on this host: the same exit status as text mode, with
  `"applicable": false` and `"reason": "<text>"`.
- Never include secrets: the same masking rules as text mode apply; key
  material, credentials, environment values, and file contents are never
  emitted.
- The exit status equals the text mode's.
- Tests validate the shape with `jq -e` and assert that `stdout` contains only
  the JSON document.

Clarifications that keep these rules mechanical:

- Parse `--json` with the other arguments, before any probe, and check for jq
  after parsing, as for any command-specific dependency. A usage error prints
  nothing on `stdout`.
- `-M` keeps the document monochrome even when `stdout` is a terminal, and
  `-c` keeps it on one line. Build the filter as one constant program and
  pass every value through `--arg` (strings), `--argjson` (numbers, booleans,
  and `null` validated before the call), or raw input that the filter splits
  and converts itself; a filter never interpolates data.
- Capture the document before printing it, so a failed jq call prints no
  partial output.
- `N` starts at `1`. Adding a key is compatible; renaming or removing a key,
  or changing a value's type or meaning, increments `N`.
- `"applicable"` and `"reason"` follow `"schema"` at the top level of a
  document whose command does not apply. An unknown fact inside an
  applicable document is `null`, not `"applicable": false`.
- The reference implementation is `zdx status --json`
  (`zdx.status.v1`, documented in [`user-guide.md`](user-guide.md)).

## Service reference

| Service | Contract |
| --- | --- |
| `_zdx_ui_color_enabled` | color policy predicate |
| `_zdx_ui_verbose` | true only for `ZDX_VERBOSE=1` |
| `_zdx_format_duration <seconds>` | `REPLY` duration; status `2` for invalid input |
| `_zdx_count_noun <n> <singular> [plural]` | `REPLY` counted noun; status `2` for invalid input |
| `_zdx_outcome_class <token>` | `REPLY` class; status `2` for an unknown token |
| `_zdx_ui_outcome <token>` | `REPLY` glyph and word |
| `_zdx_ui_command_display <argv...>` | `REPLY` display-only quoted command with `~` |
| `_zdx_ui_heading <title>` | heading, omitted or demoted inside a step |
| `_zdx_ui_label <key> <value>` | key-value line; status `2` for an empty key |
| `_zdx_ui_section [--first] <title>` | report sub-heading; status `2` for an empty title |
| `_zdx_ui_step_banner [--first] <i> <n> <label>` | step banner; `--first` directly after a heading |
| `_zdx_ui_step_result <i> <n> <label> <outcome> <detail> <seconds>` | one result line |
| `_zdx_ui_table [--outcome-column N] <header-tsv> [row-tsv...]` | aligned table; status `2` prints nothing |
| `_zdx_ui_step_summary [--first-column NAME] <title> <record...>` | summary heading and table; omitted inside a step unless verbose; status `2` for a malformed record |
| `_zdx_step_exec <command...>` | runs a step; `reply=(outcome detail seconds)` |
| `_zdx_step_report <outcome> [detail]` | `0` recorded, `1` no reachable slot, `2` invalid |
| `_zdx_step_reported` / `_zdx_step_active` | slot predicates |
| `_zdx_run_captured` / `_zdx_run_captured_here` | captured execution |

These services live in `functions.zsh`. Suites call them through thin
`_<prefix>_*` wrappers that check `${+functions[...]}` at call time and fall
back to plain output, so a suite sourced without the core still works.

## Adoption checklist

1. Route the suite heading and label helpers through `_zdx_ui_heading` and
   `_zdx_ui_label`.
2. Replace bespoke capture with a `_<prefix>_run_captured` wrapper that passes
   a human-readable display string.
3. Replace `(s)` and `(ies)` with `_zdx_count_noun`.
4. Use `_zdx_format_duration` for every displayed duration.
5. Make each child report its terminal outcome through
   `_<prefix>_report_result` with change evidence, and never both print a
   success line and report.
6. Rebuild each aggregate loop as plan → authorization → banner,
   `_<prefix>_step_exec`, result line → summary table → verdict → retry hints.
   Render multi-subject reports with [sections](#report-sections) and
   file-changing commands as [exact-target plans](#exact-target-plans).
7. Have `--verbose` set `ZDX_VERBOSE=1` for the run.
8. Test empty stdout, `NO_COLOR`, the standalone fallback, compact versus
   verbose output, and slot versus standalone reporting.
9. Give a read-only command machine output only through `--json` and the
   [JSON output](#json-output) rules: a `zdx.<command>.v<N>` schema, one
   compact line built by jq from arguments or raw input, and `jq -e` shape
   tests that also prove `stdout` holds that line and nothing else.
10. Update the suite contract, `user-guide.md`, `testing.md`, and the
    changelog.

## Prohibited patterns

- Printing internal identifiers such as `fzf-pull` as user-facing labels.
- Announcing that output is captured and then printing it anyway.
- Reporting `updated` without before/after evidence.
- A second heading, success line, or footer for work already summarized by
  its aggregate step.
- Inline pseudo-headings such as `── Title ──` inside a report, or an info
  glyph on every line of a listing.
- Mixed duration formats or hand-rolled plural suffixes.
- Replaying vendor or credential-bearing output that the owner declared
  private.
