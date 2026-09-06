# Suite development standard

This document is the canonical engineering contract for every built-in ZDX
suite and utility. It defines how code is owned, loaded, invoked, tested, and
made safe. The menu-specific UI contract lives in
[`menu-spec.md`](menu-spec.md), and the file-opening conventions live in
[`headers.md`](headers.md).

## Normative language and precedence

The words **MUST**, **MUST NOT**, **SHOULD**, and **MAY** are normative.

When repository documents overlap, use this order:

1. `AGENTS.md` for repository-wide operational mandates.
2. This document for suite architecture and command behavior.
3. `menu-spec.md` for interactive menu behavior.
4. `headers.md`, `testing.md`, and `plugins.md` for their named domains.
5. `menus.md` for migration context only; it is not normative.

Existing code can predate this contract. A legacy implementation is evidence
to study, not permission to copy a non-conforming pattern.

## Architectural boundaries

ZDX has four code layers:

```text
zdx-suite.plugin.zsh
  -> functions.zsh                  core runtime services
    -> functions/<suite>-menu.zsh   public loader and command router
      -> functions/<suite>-common.zsh
        -> functions/<suite>/*.zsh  cohesive feature modules
```

Dependencies MUST point down this diagram:

- The plugin wrapper MAY source the core runtime.
- The core runtime MAY register suite entrypoints, but MUST NOT source a
  suite common file to obtain generic behavior.
- A suite MAY use documented core runtime services and its own common file.
- A feature module MAY use its suite common file and documented core services.
- A suite MUST NOT source another suite's private helpers.

The current `git`/`ws` relationship is a documented legacy exception because
workspace identity is coupled to Git configuration. New work MUST NOT expand
that exception. Shared primitives should eventually move to a deliberately
named domain or core module instead of making one suite inherit another.

## Ownership before implementation

Every feature has exactly one owning suite. Choose ownership by the resource
whose lifecycle is being managed, not by the executable used to implement it.
For example, GitHub pull requests belong to `git`, operating-system services
belong to `sys`, and custom ZDX plugins belong to the core plugin manager.

Before adding a command:

1. Search public commands, dispatchers, completions, tests, and documentation.
2. Confirm that another suite does not already own the workflow.
3. Define the command's inputs, output, side effects, dependencies, platforms,
   cancellation behavior, and return codes.
4. Decide whether it is a public command, a private helper, or a core service.

Compatibility aliases MAY delegate to an owner, but two suites MUST NOT keep
independent implementations of the same lifecycle.

## File responsibilities

### Core runtime

`functions.zsh` owns only cross-cutting runtime services:

- configuration loading;
- lazy entrypoint registration;
- the shared visual theme;
- timing and opt-in telemetry;
- plugin discovery;
- final user overrides.

New core-private functions use the `_zdx_*` prefix. The existing `_tk_*` core
helpers are compatibility names, not a namespace for new unrelated helpers.
No helper from `git-common.zsh` is a core API merely because it starts with
`_tk_`.

### Suite entrypoint

`functions/<suite>-menu.zsh` owns:

- deterministic loading of the suite common and feature modules;
- `<suite>-menu` argument routing;
- the top-level menu model;
- the suite dispatcher call.

It MUST stay small. Business logic, network calls, filesystem mutations, and
long preview scripts do not belong in the entrypoint.

### Suite common

`functions/<suite>-common.zsh` owns stable private primitives used by two or
more modules in the same suite:

- logging and prompt helpers;
- dependency and capability checks;
- menu row builders and the suite `fzf` wrapper;
- the explicit dispatcher;
- small, pure data helpers.

It MUST NOT become a miscellaneous dumping ground. A helper used by one module
stays in that module.

### Feature module

`functions/<suite>/<suite>-<feature>.zsh` owns one cohesive capability. Split a
feature when it has a distinct dependency set, safety model, persisted state,
or test fixture. Line count is a warning signal, not the primary boundary.

Feature modules MUST NOT contain unrelated section remnants or duplicate
public commands left over from previous moves.

### Completions and tests

`completions/_<suite>-menu` and the relevant BATS files are part of the public
interface. They MUST change in the same patch as command names, flags, or
dispatch behavior. Contract coverage must verify not only the declaration text
but also registration after the normal Oh My Zsh ordering where `compinit`
precedes plugin loading. The wrapper must register new declarations explicitly;
it must not rerun global `compinit`.

## Naming and visibility

- Public commands use `kebab-case`: `git-branch-create`, `sys-health`.
- Private helpers use the owning prefix: `_git_*`, `_sys_*`, `_zdx_*`.
- Global configuration uses an uppercase suite prefix: `SYS_DOTFILES`.
- Idempotency sentinels use `_SUITE_COMPONENT_SOURCED`.
- Function-local variables use `local`; shared arrays and maps use explicit
  `typeset -g`, `typeset -ga`, or `typeset -gA` only when global state is
  necessary.
- Do not use Zsh special parameter names such as `path`, `status`, `fpath`,
  `commands`, or `functions` for local variables.

A public function MUST have a stable, documented purpose. Internal orchestration
helpers remain private even if a menu invokes them indirectly.

## Function contracts

Every public command MUST define:

- accepted arguments and flags;
- whether it can run non-interactively;
- stdout data, if any;
- user-visible side effects;
- required and optional dependencies;
- supported capability or platform constraints;
- exit status behavior.

Use these exit statuses unless an invoked tool's status must be preserved:

| Status | Meaning |
| --- | --- |
| `0` | Success, deliberate cancellation, or an explicitly documented no-op |
| `1` | Operational failure or unmet runtime precondition |
| `2` | Invalid arguments, unknown flag, or unknown dispatch token |
| `124` | Timeout when the timeout distinction is useful to the caller |

Cancellation is not an error. A user pressing Esc or declining a confirmation
returns `0` without performing the mutation.

An inventory builder MUST return success explicitly after a successful scan,
including when no candidates match. Its status MUST NOT depend on candidate
order or the final filter comparison. Collection and read failures still
propagate before callers consume partial results.

### Argument routing

Parse help and options before dispatching. Unknown options MUST fail closed.
Forward remaining arguments without flattening them:

```zsh
case "${1:-}" in
  "")
    _example_interactive
    ;;
  -h|--help)
    _example_usage >&2
    ;;
  -*)
    _example_error "Unknown option: $1"
    return 2
    ;;
  *)
    local command_name="$1"
    shift
    _example_dispatch "$command_name" "$@"
    ;;
esac
```

Do not build a function name from user input. Dispatch through a `case` whose
arms call fixed functions.

### Quoting and command construction

- Use Zsh arrays for commands and flags: `local -a cmd=(git commit ...)`.
- Expand argument arrays with `"${cmd[@]}"`.
- Keep data and shell program text separate.
- Do not use `eval` for dispatch, rendering, configuration parsing, or pager
  composition.
- Do not interpolate untrusted selections into `sh -c`, `zsh -c`, `fzf
  --preview`, or `fzf --bind` snippets.
- Terminate option parsing with `--` before user-controlled paths when the
  called program supports it.
- Capture a command's status separately from its output when both matter.

Human-readable display rows are not a reliable data store. Preserve opaque
identifiers in a separate field and validate them again immediately before a
mutation.

## Stream contract

`stdout` is reserved for documented data. Menu row builders, scanners, and
other composable functions MAY emit machine-readable records there.

Everything intended only for a person goes to `stderr`:

- headings, labels, progress, timers, warnings, success messages, and errors;
- prompts and confirmation text;
- help and usage text;
- blank lines used only for UI layout.

Never let UI output contaminate command substitution. A function that produces
data MUST document its record format and MUST produce no extra stdout text.
Callers MUST check its exit status before consuming the data.

Use `print -r --` or `printf` instead of portable-shell-oriented `echo -e`.
Logging helpers MUST accept arbitrary text as data, not as format strings.

## Dependencies and capabilities

Dependencies are checked at the narrowest useful boundary:

- the entrypoint checks only what the interactive menu itself requires;
- the dispatcher checks command-specific external binaries;
- the public command checks runtime state such as authentication, daemon
  availability, repository context, or permissions.

`command -v` proves only that a binary exists. When relevant, also check the
service, socket, authentication state, API access, or minimum version.

Optional dependencies SHOULD disable or annotate only the affected menu entry.
They MUST NOT prevent unrelated commands from loading. The dispatcher MUST
repeat the dependency check because direct CLI invocation bypasses the menu.

Missing-dependency errors include the dependency name and a safe next step.
They MUST NOT launch an installer without a separate, explicit user choice.

## Platform behavior

Do not infer platform support from the repository's overall support statement.
Support is command-specific and capability-based.

- Detect operating systems and facilities explicitly.
- Prefer a capability check over a distribution-name check.
- Keep Linux, WSL, macOS, BSD, and Termux branches isolated and testable.
- Never run a Linux-only command merely because a similarly named binary exists.
- An unsupported capability returns a clear no-op or failure according to the
  public contract; it does not hang, request unnecessary `sudo`, or emit a
  cascade of command-not-found messages.

Adding a platform claim requires a test or a documented manual verification
procedure for that platform.

## Mutation and safety model

Classify each public command before implementing it:

| Class | Examples | Minimum control |
| --- | --- | --- |
| Read-only | status, list, preview | Validate inputs and avoid secret exposure |
| Reversible mutation | stage, start service | Show target and resulting action |
| Destructive mutation | delete, reset, prune, kill | Preview plus explicit confirmation |
| Privileged mutation | package update, system service | Destructive controls plus least-privilege `sudo` |
| Remote-code or installer action | plugin install, downloaded installer | Explicit trust decision plus integrity verification |

### Destructive commands

Destructive and multi-target commands MUST:

1. calculate the exact target set without mutating it;
2. reject empty, malformed, ambiguous, or out-of-bound targets;
3. show a preview or count that identifies the scope;
4. offer `--dry-run` when more than one target or a broad cleanup is involved;
5. require an explicit confirmation immediately before execution;
6. fail closed in a non-interactive shell unless an explicit `--yes` flag is
   documented;
7. report partial failures and return non-zero if any required target failed.

`--yes` bypasses only the prompt. It MUST NOT bypass validation, path
boundaries, dependency checks, integrity checks, or dry-run planning.

Canonicalize deletion targets and prove they are descendants of the expected
base. Protect `/`, `$HOME`, the suite root, the repository root, and an empty
path explicitly. Avoid broad shared-directory globs such as `/tmp/*`.

### Privilege elevation

- Request `sudo` as late as possible and only around the command that needs it.
- Never run selection, parsing, preview, downloads, or user-provided hooks as
  root.
- A keepalive process MUST be scoped with Zsh `always` cleanup.
- Revalidate the selected resource immediately before the privileged action.
- Print the intended privileged operation before requesting credentials.

### Downloads and installers

TLS alone does not establish artifact integrity. Code that downloads an
executable, archive, plugin, or installer MUST use a pinned version and verify
an upstream checksum or signature before execution or installation.

Do not use `curl | sh`, execute an unpinned `latest` installer, or pass a
freshly downloaded script to `sudo`. If upstream provides no verifiable
artifact, print official manual instructions and stop.

An already-installed package manager or vendor CLI self-updater may own a
dynamic "latest available" transaction when the public command classifies it
as remote code and all of these controls apply:

- ZDX resolves one external executable, validates its owner and writable mode,
  and freezes its path, target identity, and content checksum before review;
- the plan names the dynamic upstream scope and prints the exact fixed
  self-updater arguments;
- `--dry-run` is passive, execution requires an explicit trust decision, and
  the executable is revalidated immediately before delegation;
- an absent tool is never installed, and a failed identity or version probe
  fails closed; and
- aggregate safe-only modes exclude the dynamic updater.

In this delegated case, artifact selection, transport, and release-signature
verification remain the installed updater's responsibility and MUST be
documented as a residual upstream trust boundary. This exception does not
permit ZDX to download or execute an unverified installer script itself.

Downloads use a private `mktemp -d` directory, clean it with `always`, reject
unsafe archive paths before extraction, and validate the expected files before
moving them into their destination.

## Temporary resources and background processes

- Use `mktemp` rather than predictable names containing only `$$`.
- Register cleanup before the first fallible operation.
- Use a Zsh `always` block when cleanup must happen after return or interrupt.
- Store background PIDs or ownership-preserving runtime handles in local or
  suite-namespaced state.
- Stop and `wait` for background processes on every exit path. A runtime module
  may own the process instead only when cleanup addresses an exact private
  handle, obtains a bounded stop acknowledgement, confirms exit, and deletes
  that handle before returning.
- Apply timeouts only where a bounded operation is meaningful, and distinguish
  timeout from ordinary failure when the caller needs that information.

## Configuration, secrets, and persisted state

`config.zsh`, `overrides.zsh`, and plugin entrypoints are executable Zsh, not
passive data. They are explicit local trust boundaries.

- Never source a file obtained from an untrusted selection or network response.
- Do not parse generated assignments with `eval`; return records and assign
  fields explicitly.
- Restrict persisted credentials and sensitive state to the user's home with
  owner-only permissions.
- Mask secrets in status, previews, error logs, telemetry, tests, and demos.
- Backups that can include credentials MUST document their contents and use
  restrictive permissions.

Telemetry remains opt-in. Telemetry records MUST contain only the suite,
canonical command identifier, duration, exit status, and timestamp. They MUST
NOT contain arguments, paths, environment values, command output, repository
URLs, or credentials. Writers must use owner-only files and a bounded retention
strategy.

## Loading and shell-session safety

All tracked Zsh files are sourced into a long-lived interactive shell.
Therefore:

- sourcing a file MUST define state and functions only;
- sourcing MUST NOT open `fzf`, prompt, perform network access, mutate files,
  request `sudo`, or execute a public workflow;
- every file MUST be safe to source more than once;
- no sourced file may call `exit` on a runtime path;
- suite-local option changes use `setopt LOCAL_OPTIONS` inside a function;
- temporary aliases, functions, variables, and traps are cleaned up;
- loader failures name the exact missing module and return non-zero without
  leaving a false "loaded" sentinel.

Lazy and eager loading MUST expose the same public commands and behavior.
Directly sourcing a suite in a clean Zsh process MUST not depend on another
suite having been invoked first.

## Performance and observability

Shell startup is a product requirement. Top-level loading should perform only
constant-time registration work. Defer external commands, filesystem scans,
network calls, and dynamic previews until invocation.

Interactive commands SHOULD:

- avoid repeating expensive discovery between the menu label, preview, and
  dispatcher;
- cache only within a single invocation unless invalidation is defined;
- bound network calls and daemon probes;
- preserve the invoked command's status through timing wrappers;
- emit telemetry only through the opt-in core service.

`_timed` preserves the wrapped status. A continued aggregate that genuinely
contains both failed and non-failed terminal results may call
`_zdx_timed_mark_partial`; this changes only the human timing phrase to
`completed with partial failures`. It does not convert the non-zero status or
telemetry record to success, and the marker fails closed outside the dynamic
scope of `_timed`.

Performance work must not weaken validation, confirmations, or integrity
checks.

## Public-interface synchronization

A public command change is incomplete until these surfaces agree:

1. public function and direct CLI routing;
2. dispatcher arm;
3. interactive menu entry;
4. `--help` output;
5. Zsh completion;
6. BATS contract tests;
7. `docs/user-guide.md` when user behavior changes;
8. `docs/suites.md` when ownership or structure changes.

Do not maintain a second executable allowlist. Tests SHOULD derive and compare
the documented surfaces so drift is detected automatically.

## Change workflow

Use this sequence for a suite refactor or feature:

1. Inventory the current public surface and side effects.
2. Assign ownership and classify safety risk.
3. Write or update contract tests for current intentional behavior.
4. Define the desired direct CLI before designing the menu.
5. Implement pure discovery and validation helpers.
6. Implement mutations behind the safety boundary.
7. Connect explicit dispatch and the menu model.
8. Update completions and documentation.
9. Run focused tests, then `just check`.
10. Inspect the final diff for generated changes and unrelated churn.

Refactors SHOULD be behavior-preserving unless the behavior change is named,
tested, and documented. Do not combine a large structural rewrite with
unrelated feature expansion.

## Definition of done

A suite change is complete only when:

- [ ] ownership and dependencies follow the architecture above;
- [ ] public and private names follow their namespaces;
- [ ] sourcing is idempotent and side-effect free;
- [ ] direct CLI, dispatcher, menu, help, and completion agree;
- [ ] stdout contains only documented data;
- [ ] cancellation and failures return the documented statuses;
- [ ] destructive, privileged, and remote-code paths meet their controls;
- [ ] platform and dependency branches are explicit;
- [ ] new behavior has isolated BATS coverage;
- [ ] user and security documentation is updated when applicable;
- [ ] `just check` passes after the final edit.
