# Zsh file and loader conventions

This document defines how tracked `.zsh` files open, declare dependencies, and
behave when sourced. The general suite contract is in
[`development.md`](development.md).

## Base header

Every tracked `.zsh` file starts with:

1. `#!/usr/bin/env zsh`;
2. the three-line banner;
3. one or two exact context lines;
4. the idempotency guard;
5. code.

```zsh
#!/usr/bin/env zsh
# =============================================================================
# Git Branch: switch, create, rename, merge, and rebase branches
# =============================================================================
#
# Loaded by git-menu.zsh after git-common.zsh.
# Safe to re-source; defines functions only.
#
```

The summary names the owner and the behavior actually present in the file. Do
not list features that were moved elsewhere, and do not retain historical names
for dependencies that no longer exist.

## Context by file type

### Suite entrypoint

Name the public command and its role:

```zsh
# Public loader and command router for Git repository workflows.
# Usage: git-menu [subcommand]
```

Keep detailed flags in the command's `--help` output. A header is not a second
manual.

### Suite common

Name its only valid consumers:

```zsh
# Loaded by sys-menu.zsh before every module under functions/sys/.
# Private helpers only; not a standalone public command.
```

### Feature module

Name the exact loader and prerequisite file:

```zsh
# Loaded by sys-menu.zsh after sys-common.zsh.
# Safe to re-source; defines functions only.
```

Do not write vague dependencies such as `common helpers`, and do not refer to a
removed file such as `git-ws-common` when the real dependency is
`git-common.zsh`.

### Core loader or wrapper

Describe the direction of control:

```zsh
# Loaded by Oh My Zsh. Sources functions.zsh and registers completions.
```

### Completion

Completion files use the standard `#compdef` declaration. They do not need the
three-line `.zsh` banner because they are completion definitions, not suite
source modules. Oh My Zsh runs `compinit` before loading plugin entrypoints, so
the ZDX wrapper also validates each owned completion file, loads its function
with `autoload -Uz`/`autoload +X`, and binds the validated declaration with
`compdef`. Do not run global `compinit` a second time from the plugin.

## Idempotency sentinels

Use an owner-specific sentinel. Do not use an arbitrary function's existence as
the guard: a compatibility override or partially loaded dependency can define
that function without proving this file loaded successfully.

```zsh
if [[ -n "${_EXAMPLE_FEATURE_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
```

Set the sentinel only after required top-level loading succeeds:

```zsh
# Function definitions and safe initialization appear here.

typeset -g _EXAMPLE_FEATURE_SOURCED=1
```

For a file containing only function definitions, this prevents a future
top-level failure from leaving a false loaded state. A loader that fails after
setting temporary state MUST unset that state before returning.

The sentinel means "this exact file completed loading". It is not a capability
check and must not be reused as one.

## Entry loader pattern

Split suites load their common file first, then feature modules in explicit
dependency order:

```zsh
if [[ -n "${_EXAMPLE_MENU_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset _example_loader_dir="${${(%):-%x}:A:h}"

_example_source_module() {
  local module_name="$1"
  local -a candidates=(
    "${_example_loader_dir}/${module_name}"
    "${_example_loader_dir}/example/${module_name}"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" && -r "$candidate" ]]; then
      source "$candidate"
      return $?
    fi
  done

  return 1
}

_example_source_module "example-common.zsh" || {
  print -u2 -r -- \
    "example-menu.zsh: failed to load example-common.zsh"
  unset -f _example_source_module
  unset _example_loader_dir
  return 1 2>/dev/null || exit 1
}

typeset _example_module
for _example_module in \
  example-status.zsh \
  example-maintenance.zsh; do
  _example_source_module "$_example_module" || {
    print -u2 -r -- \
      "example-menu.zsh: failed to load $_example_module"
    unset -f _example_source_module
    unset _example_loader_dir _example_module
    return 1 2>/dev/null || exit 1
  }
done

unset -f _example_source_module
unset _example_loader_dir _example_module
typeset -g _EXAMPLE_MENU_SOURCED=1
```

Rules:

- Resolve paths from `${(%):-%x}`, not from the caller's current directory.
- Candidate directories are trusted, documented installation locations.
- Check readability before sourcing.
- Preserve the failing `source` status.
- Name the exact failed file on stderr.
- Load order is explicit and stable.
- Remove temporary loader functions and variables.
- Mark the entrypoint loaded only after every mandatory module succeeds.

Do not discover built-in modules with an unordered recursive scan. A new module
must be deliberately added to the loader.

## Source-only behavior

ZDX files run inside a long-lived interactive shell. At source time they may:

- declare functions;
- declare immutable or configuration-derived global state;
- register a lazy stub or completion path in the owning core loader.

At source time they MUST NOT:

- invoke a public workflow;
- open `fzf`, a pager, editor, or browser;
- prompt or read stdin;
- access the network;
- request `sudo`;
- scan large directories or call slow external tools;
- mutate user files, repositories, services, or environment state beyond the
  documented loader registration.

A test that sources the file twice must observe no duplicate output, mutation,
or error.

## Sourced-or-executed failure

When a tracked source file can be loaded by `source` or invoked directly during
diagnostics, use:

```zsh
return 1 2>/dev/null || exit 1
```

This returns from a source operation and exits only a directly executed
process. Runtime functions themselves use `return`; they never call `exit` and
therefore cannot close the user's shell.

An idempotent success guard may use:

```zsh
return 0 2>/dev/null || exit 0
```

## Top-level state

- Use `typeset`, not `local`, for deliberate file-scope variables.
- Namespace every persistent global.
- Keep temporary loader state private and unset it after loading.
- Do not modify global shell options at file scope.
- Do not install traps at file scope.
- Do not overwrite a user configuration variable merely because it is empty;
  document whether empty is a valid override.

Configuration defaults SHOULD use explicit parameter expansion:

```zsh
typeset -g EXAMPLE_CACHE_DIR="${EXAMPLE_CACHE_DIR:-$HOME/.cache/zdx/example}"
```

For arrays and associative arrays, declare the intended type explicitly.

## Public docblocks

Long docblocks are reserved for a primary public entrypoint when flags,
non-interactive behavior, or safety consequences materially help maintainers.
Keep them below half a screen and point to the canonical document for detail.

Feature modules and loaders use short context lines. Repeating a complete
command list in a file comment creates a drifting public surface and is not
allowed.

## Comment quality

Comments explain invariants, non-obvious Zsh behavior, safety boundaries, and
why a fallback exists. They do not narrate obvious syntax.

Good:

```zsh
# Revalidate the PID after selection because the process may have exited or
# the operating system may have reused the identifier while fzf was open.
```

Avoid:

```zsh
# Set pid variable.
```

## Language

All headers, comments, code examples, help text, prompts, and user-visible
strings in the repository are English. Use universal placeholder identities
such as `Jane Doe` and `Acme Team`; never use a contributor's real identity in
examples or fixtures.

## Avoid cosmetic churn

Update a header when ownership, dependency order, public behavior, or source
safety changes. Do not rewrite headers only to change tone or decoration.
Header accuracy is part of the loader contract; cosmetic churn is not.

## Review checklist

- [ ] The summary matches the functions actually present.
- [ ] Context names the exact loader and prerequisite.
- [ ] The sentinel is unique and set only after successful loading.
- [ ] Re-sourcing is silent and harmless.
- [ ] Source time performs no workflow side effects.
- [ ] Loader paths derive from `%x` and use trusted candidates.
- [ ] Failure reports the exact module on stderr.
- [ ] Temporary loader symbols are removed.
- [ ] Runtime paths use `return`, never `exit`.
- [ ] All prose and examples are English.
