# Plugin runtime contract

This document defines the format and trust model for user-defined ZDX plugins.
Plugins also follow [`development.md`](development.md) and
[`menu-spec.md`](menu-spec.md), except where this document explicitly requires
self-containment.

## Trust model

A plugin entrypoint is executable Zsh sourced into the user's current shell. It
has the user's files, environment, credentials, network access, and command
permissions. ZDX does not sandbox plugins.

Syntax validation and checking for a named function prove only structural
compatibility. They do not prove that a plugin is safe.

Users MUST review and trust a plugin's source and update origin before loading
it. The plugin manager MUST present installation and update as arbitrary code
execution, not as a harmless data import.

## Installation directory

Plugins live under:

```text
${ZDX_PLUGINS_DIR:-$HOME/.config/zdx/plugins}/
└── <plugin-name>/
    └── <plugin-name>-menu.zsh
```

Example:

```text
~/.config/zdx/plugins/infra/infra-menu.zsh
```

The directory name, entrypoint basename, and public menu function must agree:

```text
infra/
infra/infra-menu.zsh
infra-menu()
```

## Identifier and naming rules

New plugin identifiers MUST be kebab-case and match:

```text
^[a-z0-9]+(-[a-z0-9]+)*$
```

The loader and plugin manager accept the wider pattern `^[a-z0-9_-]+$`, but
new plugins must not use underscores or other non-kebab forms because public
commands are kebab-case.

Names owned by the `zdx` wrapper are reserved for built-in routing. A custom
plugin must not use a built-in suite name (`dev`, `env`, `file`, `git`, `py`,
`sys`, `vpn`, or `ws`), `zdx`, `status`, `doctor`, `plugins`, `help`,
`version`, or `tk`, nor a name that begins with one of them followed by `-` or
`_`, such as `git-extra` or `ws_tools`, because its `<name>-*` commands or
`_<name>_*` helpers would fall inside a built-in namespace. The loader and
`zdx-plugins --install` refuse these names, and `zdx-plugins` refuses to
activate one.

The loader enforces the namespace while it sources an entrypoint. It records
every function definition first; afterwards, a plugin may have added or
changed only `<plugin-name>-*` and `_<plugin_name>_*` functions, plus new
autoload stubs such as `add-zsh-hook`, which replace nothing. A plugin that
defines another name, or replaces or removes an existing function (a ZDX
command, a lazy stub, a core helper, or anything else already defined), is
refused: every function its source added is removed, every function it
replaced is restored, and the offending names are printed. The check also runs
when the source fails and when `zdx-plugins` activates an install or update.
It covers functions only; aliases, widgets, hooks, options, and parameters set
at source time are not restored.

- Public functions use `<plugin-name>-<action>`.
- Private helpers use `_<plugin_name>_*`, replacing hyphens with underscores.
- Global configuration uses an uppercase plugin prefix.
- The idempotency sentinel uses the uppercase underscore form.

For `mytool`, examples are `mytool-menu`, `mytool-status`, `_mytool_error`, and
`MYTOOL_CACHE_DIR`. The sentinel is `_MYTOOL_MENU_SOURCED`; the plugin manager
clears exactly this name before it sources an updated entrypoint, so a plugin
that guards re-sourcing under another name keeps its previous definitions in
the running shell until a new shell starts.

Plugins MUST NOT define generic names such as `log`, `confirm`, `cleanup`, or
`dispatch` in the global shell namespace.

## Self-contained boundary

A plugin may use:

- Zsh builtins and modules;
- external commands it declares and checks;
- its own namespaced helpers and configuration;
- the core services of the plugin API v1 below, after checking
  `ZDX_PLUGIN_API`.

A plugin MUST NOT source a built-in suite common file or call undocumented
suite-private helpers. In particular, it must not source `git-common.zsh` or
any other suite common file to obtain picker or helper behavior.

Sourcing the entrypoint never needs a core service, so a plugin file can be
sourced on its own for review or testing. Its commands check
`ZDX_PLUGIN_API` before they call one and fail with a clear message when the
API is missing.

## Plugin API v1

The core sets the read-only parameter `ZDX_PLUGIN_API=1` and keeps the
services below stable for API v1. Their contracts are the ones documented in
`output-spec.md`, `development.md`, and the function comments in
`functions.zsh`; the read-only array `_ZDX_PLUGIN_API_SERVICES` lists the same
names, and `test/plugins_api.bats` keeps both in step. Any other core or suite
function is private and may change without notice.

<!-- plugin-api-v1-services -->
| Service | Purpose |
| --- | --- |
| `_zdx_ui_heading` | A command heading on stderr |
| `_zdx_ui_section` | A report section heading |
| `_zdx_ui_label` | One key-value line in the shared label layout |
| `_zdx_ui_say` | A `success`, `info`, `warn`, `error`, or `dim` message |
| `_zdx_ui_table` | An aligned table from tab-separated rows |
| `_zdx_ui_step_banner` | A numbered step banner |
| `_zdx_ui_step_result` | One step result with the outcome vocabulary |
| `_zdx_ui_step_summary` | The summary table of an aggregate run |
| `_zdx_count_noun` | A count with its singular or plural noun |
| `_zdx_format_duration` | The shared duration format |
| `_zdx_run_with_timeout` | Runs one program with a deadline |
| `_zdx_run_captured` | Runs a command with its output captured privately |
| `_zdx_picker_capture` | Runs a picker in the foreground and captures its selection |
| `_zdx_confirm_prompt` | Asks one yes/no question |
| `_zdx_fzf_color_opts` | The fzf color option for the current theme |
| `_zdx_fzf_nth_template_option` | The single-field `--with-nth` template option |
| `_zdx_core_fzf` | Runs fzf with the shared theme and isolated defaults |
| `_zdx_resolve_trusted_dir` | Resolves a directory through trusted aliases only |
| `_zdx_capture_parent_safe` | The validated temporary root for private files |
<!-- /plugin-api-v1-services -->

The earlier `_tk_fzf_color_opts`, `_tk_fzf_nth_template_option`, `_tk_fzf`,
and `_tk_spinner` names remain as wrappers for older plugins and are not part
of API v1.

The picker follows the terminal-color, plain-mode, and invocation-local fzf
environment rules in `menu-spec.md`. These rules apply to custom plugin code
through this contract and template; the loader cannot enforce rendering inside
an arbitrary trusted plugin.

## Source-time contract

Sourcing a plugin may define functions and namespaced defaults only. It MUST
NOT:

- open a menu or prompt;
- access the network;
- read secrets or enumerate the filesystem;
- mutate files or environment state;
- request `sudo`;
- install dependencies;
- invoke a public action.

It must be idempotent and must never call `exit`. A source failure returns
non-zero without closing the shell.

## Stream and return contract

- Menu row builders and documented data functions emit only data on stdout.
- Help, prompts, progress, status, warnings, and errors go to stderr.
- Esc and declined confirmation return `0` without mutation.
- Operational failure returns `1`.
- Invalid flags, arguments, or dispatch tokens return `2`.

Plugins follow the destructive, privileged, download, path, temporary-resource,
and secret-handling rules in `development.md` without exception.

## Dependencies

Check `fzf` only when opening the interactive menu. Direct commands that do not
need it remain available.

Each direct action checks its own external commands and runtime capabilities.
A missing optional dependency must not prevent the plugin from being sourced or
unrelated actions from running.

Plugins MUST NOT install a missing dependency automatically. They may print a
safe manual next step.

## Loader behavior

An eager shell (`ZDX_EAGER_LOAD=1` or test mode) loads every plugin at
startup with the steps below. A lazy shell, the default, runs only the cheap
name, reservation, root, and entrypoint checks at startup: it records the
plugin in `ZDX_DISCOVERED_PLUGINS` and registers stubs for `<plugin-name>-menu`
and for the commands of the optional manifest. The first call of any stub runs
every step below, records the plugin in `ZDX_LOADED_PLUGINS`, removes the
plugin's remaining stubs, and runs the requested command. Startup therefore
runs no `zsh -n` and sources no plugin code, and a plugin changed after
discovery is refused on first use.

The manifest `<plugin-name>/commands` lists the plugin's direct commands, one
`<plugin-name>-<action>` name per line, with blank lines and `#` comments
allowed. It must be a regular file that you own, with one link, no group or
other write permission, at most 16 KiB, and at most 128 commands; any other
line refuses the whole manifest, and only the menu stub remains. A name that
is already a function is not registered. A plugin without a manifest keeps
its direct commands available after its menu has run once.

The optional completion `<plugin-name>/_<plugin-name>-menu` follows the same
file rule (1 byte to 1 MiB). Its `#compdef` line may name only
`<plugin-name>-menu` and `<plugin-name>-<action>` commands. The plugin
wrapper autoloads it from its absolute path after the built-in completions,
so nothing in it runs until completion calls it, and `zdx <plugin-name>`
completion delegates to it.

The core loader:

1. scans direct child directories of `ZDX_PLUGINS_DIR`;
2. resolves the plugin root through trusted aliases only (a root-owned system
   link such as Fedora Atomic's `/home`, or a link owned by the current user
   above the root inside a directory that group and other users cannot write),
   then requires a non-symlink canonical root that the current user owns and
   that group and other users cannot write, below ancestors owned by root or
   the current user that group and other users cannot write (a root-owned
   sticky directory such as `/tmp` is allowed); scanning and sourcing use only
   that canonical root;
3. validates the directory-name pattern accepted by the runtime;
4. requires an owned, singly linked regular entrypoint that is an exact child
   of its plugin directory, with no symlink in its path, and neither the
   entrypoint nor the plugin directory may be writable by group or other
   users (files the plugin sources itself are not checked);
5. runs `zsh -n` and repeats the path validation immediately before sourcing
   `<plugin-name>-menu.zsh`;
6. checks that `<plugin-name>-menu` is defined and that the source stayed in
   the plugin's namespace (see "Identifier and naming rules");
7. records the plugin for the master menu; and
8. requires exact loaded-name membership again before the `zdx` wrapper calls
   the validated `<plugin-name>-menu` function with literal arguments.

The loader is not a sandbox, linter, signature verifier, or permission
boundary. A plugin can execute code while it is being sourced, before the
function check completes.

Loader diagnostics go to stderr, and useful plugin errors are preserved rather
than suppressed. Secret-bearing output must still be avoided by the plugin
itself.

## Install and update requirements

A plugin manager handling a Git URL MUST:

- validate the requested identifier and canonical destination path;
- clone into a private temporary staging directory first;
- show the origin URL and resolved commit before activation;
- require an explicit trust confirmation;
- run `zsh -n` on the entrypoint;
- reject missing or mismatched entrypoints;
- prevent symlink or path traversal outside the plugin root;
- move the validated tree into place atomically where possible;
- source it only after the trust decision;
- leave the existing plugin intact if an update validation fails.

An update is new code execution and repeats the validation and trust boundary.
`git pull` followed immediately by `source` is not sufficient rollback design.

Removal canonicalizes the target and proves it is a strict child of the plugin
base before confirmation and deletion.

## Plugin manager lifecycle

The core `zdx-plugins` manager meets the requirements above:

```text
zdx-plugins --install <url> [name] [--dry-run] [--yes]
zdx-plugins --update [name] [--dry-run] [--yes]
zdx-plugins --remove <name> [--dry-run] [--yes]
zdx-plugins --list
```

Install, update, and remove run as one locked transaction per plugin:

1. **Lock.** The manager takes an exclusive, non-blocking `fcntl` lock on
   `<root>/.zdx-plugins.lock`, an owner-only file it validates and keeps. A
   second run, from any shell, is refused instead of waiting. The kernel
   releases the lock when its descriptor closes or the shell exits, so an
   interrupted run leaves no stale lock. A nested run from the same shell,
   such as one a plugin starts while it is being sourced, is refused too.
2. **Recovery.** Under the lock, leftover staging from an interrupted run is
   recovered first. A previous version that was moved aside while its plugin
   directory is absent is restored. A previous version is never deleted
   automatically: when the plugin directory exists again, its staging is kept
   and named. Any other leftover, such as a partial clone, is removed.
   Unexpected entries named like staging make the run fail closed.
3. **Staging.** Each transaction creates a private, mode `700` directory,
   `<root>/.zdx-staging.<name>.<random>`, inside the canonical plugin root, so
   publication is a same-filesystem rename. Its dot name never matches the
   loader's identifier pattern. An install clones `--depth 1`; an update
   clones the installed branch's upstream with full history into staging, so
   the transition can be counted. Clones never recurse into submodules.
4. **Network boundary.** Git runs with routing and configuration-injection
   variables removed, terminal prompts and askpass helpers disabled, the
   transports limited to `file`, `git`, `http`, `https`, and `ssh`, an SSH
   batch-mode default with connect and keepalive timeouts unless the user
   configures SSH, and a low-speed abort for a stalled HTTP transfer.
   Credentials must come from a credential helper or an SSH agent. The clone
   is announced as a `$ git clone …` line with a redacted origin, and its
   output is shown, escaped and credential-redacted, only on failure.
5. **Validation.** The staged tree passes the loader's own entrypoint rule,
   `_zdx_plugin_entrypoint_safe`, with the staging directory as its root: a
   real, owned plugin directory and an owned, singly linked regular
   `<name>-menu.zsh` that is an exact child of it. A checkout that contains
   any symbolic link is refused, and `zsh -n` must accept the entrypoint.
   A commit with a bad signature is refused whatever the decision.
6. **Trust decision.** The review shows the redacted origin, the branch, the
   installed commit and subject, the new commit and subject, the full new
   object ID, the number of commits and whether the update fast-forwards or
   rewrites history, the signature verdict from `git` (`%G?`: good, unknown
   validity, expired, revoked, bad, unverifiable, or unsigned; an unsigned
   commit is a verdict, not a failure), up to ten incoming commit subjects,
   and the arbitrary-code warning. Origin text is escaped display data. An
   unchanged commit is reported as `current` without a decision.
   `--dry-run` stops after the review. Otherwise the user confirms, or
   `--yes` trusts the reviewed plan. Without a terminal and without `--yes`,
   the command refuses before any fetch.
7. **Revalidation.** After the decision the manager proves again that the
   root, the staging directory, and the staged tree keep their identities,
   that the staged `HEAD` is the reviewed commit, that its files are clean
   against that commit, and that the loader rule and link check still pass.
   An update also proves that the installed checkout keeps its identity,
   commit, and clean state.
8. **Publication.** An install renames the staged tree into the root. An
   update first renames the installed version into staging as `previous`,
   then the staged tree into the root. Every rename goes to an absent
   destination with a no-clobber `mv` and is verified by directory identity.
   A failed second rename restores the first.
9. **Activation.** The manager repeats the loader's path checks and `zsh -n`,
   clears the conventional `_<NAME>_MENU_SOURCED` sentinel so the plugin's
   guard does not skip the new code, and sources the entrypoint in the
   current shell with its output on stderr, the way the loader would.
   Activation succeeds only when `source` returns `0` and
   `<plugin-name>-menu` is defined.
10. **Rollback.** A failed activation moves the new tree back into staging
    and, for an update, the previous version back into the root, verified by
    identity, so the previous commit is restored exactly. The menu function
    and the sentinel that activation replaced are restored. Other definitions
    the failed source made cannot be undone, so the manager says to open a new
    shell. It never reports a successful reload after a failed source. An
    interruption after publication rolls back the same way, and an
    interruption between the two renames restores the previous version.
11. **Cleanup.** Staging is removed by exact identity once the transaction
    ends. The previous version therefore stays until the new one is active.

An update refuses a plugin that is not the root of its own Git checkout, has
no commit, is on a detached `HEAD`, tracks an invalid branch, has no usable
`origin`, or has modified, untracked, or ignored files, because replacing the
tree would discard them. A plugin without `.git` is skipped. `--update` with
no name runs one aggregate step per plugin, each with its own staging and its
own trust decision, followed by a summary table, a verdict, and retry hints.

Removal prints an exact plan (name, path, redacted origin, commit, and
whether the plugin is loaded), supports `--dry-run`, and confirms or requires
`--yes`. After the decision it proves that the root and the plugin directory
keep their identities, renames the directory into staging so it leaves the
root atomically, unregisters the plugin and its menu function, and deletes
the quarantined tree by identity. A partial deletion is reported with the
remaining path.

The plugin-manager menu captures every picker selection through a private,
byte-bounded file below the validated temporary root, and dispatches only a
row of the current snapshot.

These controls do not sandbox a plugin or prove that it is harmless; the
trust decision does. `--yes` trusts every reviewed change without a prompt,
and a rewritten history is disclosed but not refused. A process with the same
user ID can still race the final path operations. See
[`security-assessment.md`](security-assessment.md) (T6).

## Compliant single-file template

This is the minimum template for a non-destructive plugin on the plugin API
v1. Replace names and actions deliberately; do not leave placeholder behavior
in an installed plugin. Save it as `mytool/mytool-menu.zsh`, and list
`mytool-status` in `mytool/commands` so the direct command works before the
menu has run.

<!-- plugin-template -->
```zsh
#!/usr/bin/env zsh
# =============================================================================
# MyTool Plugin: a read-only status action on the ZDX plugin API v1
# =============================================================================
#
# Loaded by the ZDX user-plugin loader.
# Safe to re-source; defines functions only. Commands need ZDX_PLUGIN_API=1.
#

if [[ -n "${_MYTOOL_MENU_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_mytool_error() { print -u2 -r -- "mytool: ${(V)1}"; }

# Status 1, with a message, when the ZDX plugin API v1 is not loaded.
_mytool_require_api() {
  [[ "${ZDX_PLUGIN_API:-}" == 1 ]] && return 0
  _mytool_error "MyTool needs the ZDX plugin API v1; load it through ZDX."
  return 1
}

# The fzf preset of MyTool pickers: the shared theme over invocation-local
# defaults, showing the label field of "label|command|description" rows.
_mytool_fzf() {
  _zdx_core_fzf --height=40% --border=rounded --delimiter='[|]' \
    --with-nth=1 "$@"
}

mytool-status() {
  (( $# == 0 )) || {
    _mytool_error "mytool-status accepts no arguments."
    return 2
  }
  _mytool_require_api || return 1
  _zdx_ui_heading "MyTool Status"
  _zdx_ui_label "Directory" "$PWD"
  _zdx_ui_label "Shell" "zsh $ZSH_VERSION"
}

_mytool_usage() {
  print -u2 -r -- "Usage: mytool-menu [--help | mytool-status]"
}

_mytool_dispatch() {
  local command_name="$1"
  shift
  case "$command_name" in
    mytool-status) mytool-status "$@" ;;
    *)
      _mytool_error "Unknown command: $command_name"
      return 2
      ;;
  esac
}

# The menu: a picker captured privately in the foreground, and only a row of
# the displayed snapshot is dispatched.
_mytool_interactive() {
  _mytool_require_api || return 1
  local -a rows=("Show Status|mytool-status|Read-only directory and shell facts.")
  local REPLY="" selected=""
  local -i picker_rc=0
  _zdx_picker_capture --tag mytool --noun MyTool --error _mytool_error \
    --picker _mytool_fzf --temp-root _zdx_capture_parent_safe -- \
    --prompt='mytool > ' --preview='printf "%s\n" {3}' \
    --preview-window='down:3:wrap' < <(print -rl -- "${rows[@]}") \
    || picker_rc=$?
  selected="$REPLY"
  (( picker_rc == 1 || picker_rc == 130 )) && return 0
  (( picker_rc == 0 )) || return 1
  (( ${rows[(Ie)$selected]} )) || {
    _mytool_error "The selected action was not in the menu snapshot."
    return 1
  }
  _mytool_dispatch "${${selected#*|}%%|*}"
}

mytool-menu() {
  case "${1:-}" in
    "") _mytool_interactive ;;
    -h|--help) _mytool_usage ;;
    -*)
      _mytool_error "Unknown option: $1"
      return 2
      ;;
    *) _mytool_dispatch "$@" ;;
  esac
}

typeset -g _MYTOOL_MENU_SOURCED=1
```
<!-- /plugin-template -->

## Plugin review checklist

- [ ] Directory, entrypoint, public function, and identifier agree.
- [ ] New identifier is kebab-case.
- [ ] Every private symbol is namespaced.
- [ ] Sourcing twice is silent and side-effect free.
- [ ] No runtime path calls `exit`.
- [ ] Direct commands work without `fzf` when they do not need it.
- [ ] Menu rows, dispatch, help, and public commands agree.
- [ ] UI goes to stderr and data records stay clean on stdout.
- [ ] Missing dependencies fail locally without auto-installing.
- [ ] `fzf` runs in the foreground and its exact snapshot row is revalidated.
- [ ] Previews are read-only and secret-safe.
- [ ] Destructive or privileged additions implement the full safety contract.
- [ ] Downloads are pinned and integrity-verified.
- [ ] BATS tests use an isolated `ZDX_PLUGINS_DIR`.
- [ ] The user has reviewed and trusts the source and update origin.
