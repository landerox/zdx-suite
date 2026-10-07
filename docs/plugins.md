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
`sys`, `vpn`, or `ws`), `status`, `doctor`, `plugins`, `help`, or `version`;
the master menu skips such collisions. Its public functions must not reuse a
built-in suite's `<suite>-*` command prefix either, such as `ws-*` or `git-*`.

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
- an already-loaded, documented optional core visual helper with a fallback.

A plugin MUST NOT source a built-in suite common file or call undocumented
suite-private helpers. In particular, it must not source `git-common.zsh` or
any other suite common file to obtain picker or helper behavior.

Core theme integration is optional. The plugin must remain functional when the
theme helper is absent, including when its file is sourced directly for review
or testing.

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

The current core loader:

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
   of its plugin directory, with no symlink in its path;
5. runs `zsh -n` and repeats the path validation immediately before sourcing
   `<plugin-name>-menu.zsh`;
6. checks that `<plugin-name>-menu` is defined;
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

This is the minimum template for a non-destructive plugin. Replace names and
actions deliberately; do not leave placeholder behavior in an installed
plugin.

```zsh
#!/usr/bin/env zsh
# =============================================================================
# MyTool Plugin: example status and inspection actions
# =============================================================================
#
# Loaded by the ZDX user-plugin loader.
# Safe to re-source; defines functions only.
#

if [[ -n "${_MYTOOL_MENU_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_mytool_info() {
  print -u2 -r -- "[info] $1"
}

_mytool_error() {
  print -u2 -r -- "[error] $1"
}

_mytool_usage() {
  cat >&2 <<'EOF'
Usage:
  mytool-menu                       Open the interactive menu
  mytool-menu mytool-status         Run status directly
  mytool-menu mytool-inspect        Run inspection directly

Options:
  -h, --help                        Show this help
EOF
}

_mytool_require() {
  local dependency="$1"
  if ! command -v "$dependency" &>/dev/null; then
    _mytool_error "Missing required dependency: $dependency"
    return 1
  fi
}

_mytool_menu_section() {
  local title="$1"
  local description="${2:-}"

  if [[ "$title" == *'|'* || "$title" == *$'\n'* \
    || "$description" == *'|'* || "$description" == *$'\n'* ]]; then
    _mytool_error "Invalid menu section fields."
    return 2
  fi

  printf "── %s ──|:|%s\n" "$title" "$description"
}

_mytool_menu_entry() {
  local label="$1"
  local command_name="$2"
  local description="$3"

  if [[ "$label" == *'|'* || "$label" == *$'\n'* \
    || "$command_name" == *'|'* || "$command_name" == *$'\n'* \
    || "$description" == *'|'* || "$description" == *$'\n'* ]]; then
    _mytool_error "Invalid menu entry fields."
    return 2
  fi

  printf "  %s|%s|%s\n" "$label" "$command_name" "$description"
}

_mytool_fzf() {
  local -a options=(
    --height=80%
    --layout=reverse
    --border=rounded
    --delimiter='[|]'
    --with-nth=1
    --pointer='▶'
    --color=16,fg:-1,bg:-1,fg+:-1,bg+:-1,border:-1:dim,info:yellow
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
    SHELL=/bin/sh command fzf "${options[@]}" "$@" "${terminal_options[@]}"
}

# REPLY is the canonical directory for an absolute, already-normalized path.
# A symbolic link on it is accepted only as a root-owned system alias, such as
# macOS /var and /tmp, or above the final component when the current user owns
# it inside a directory owned by root or the current user that group and other
# users cannot write. Never compare TMPDIR with its canonical form instead:
# on macOS they always differ.
_mytool_resolve_trusted_dir() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local requested="${1-}"
  REPLY=""
  while [[ "$requested" != / && "$requested" == */ ]]; do
    requested="${requested%/}"
  done
  [[ -n "$requested" && "$requested" == /* \
    && "$requested" == "${requested:a}" ]] || return 1

  local -A root_state=() link_state=() parent_state=()
  zstat -LH root_state -- / 2>/dev/null || return 1
  local -a components=("${(@s:/:)requested}")
  local prefix="" component=""
  local -i index=0 last=${#components}
  for component in "${components[@]}"; do
    (( ++index ))
    [[ -n "$component" ]] || continue
    prefix+="/$component"
    [[ -L "$prefix" ]] || continue
    link_state=()
    zstat -LH link_state -- "$prefix" 2>/dev/null || return 1
    (( link_state[uid] == root_state[uid] )) && continue
    (( index < last && link_state[uid] == EUID )) || return 1
    parent_state=()
    zstat -H parent_state -- "${prefix:h}" 2>/dev/null || return 1
    (( parent_state[uid] == root_state[uid] || parent_state[uid] == EUID )) \
      && (( (parent_state[mode] & 8#22) == 0 )) || return 1
  done
  local resolved="${requested:A}"
  [[ "$resolved" == /* && -d "$resolved" && ! -L "$resolved" ]] || return 1
  REPLY="$resolved"
}

# Run fzf in the terminal foreground and return its complete selection in
# REPLY. The private result is byte-bounded and removed only by exact identity.
_mytool_fzf_capture() {
  emulate -L zsh
  REPLY=""
  # Load only zstat: a full zsh/stat load replaces the user's stat command.
  { zmodload -F zsh/stat b:zstat && zmodload zsh/system; } 2>/dev/null || {
    _mytool_error "Zsh file-descriptor support is required."
    return 125
  }

  local temp_root="${TMPDIR:-/tmp}"
  local -A root_state=() temp_state=()
  _mytool_resolve_trusted_dir "$temp_root" \
    && temp_root="$REPLY" \
    && zstat -LH root_state -- / 2>/dev/null \
    && zstat -LH temp_state -- "$temp_root" 2>/dev/null \
    && {
      (( temp_state[uid] == EUID \
        && (temp_state[mode] & 8#22) == 0 )) \
        || (( temp_state[uid] == root_state[uid] \
          && (temp_state[mode] & 8#1000) != 0 \
          && (temp_state[mode] & 8#2) != 0 ))
    } || {
    _mytool_error "Refusing an unsafe temporary root."
    return 125
  }
  REPLY=""

  local result_file=""
  result_file=$(umask 077; command mktemp \
    "${temp_root%/}/zdx-mytool-fzf.XXXXXX" 2>/dev/null) || {
    _mytool_error "Could not create a private menu result."
    return 125
  }

  local selection=""
  local identity=""
  local -i write_fd=-1 read_fd=-1
  local -i fzf_rc=125 operation_rc=125 cleanup_failed=0
  local -A file_state=() current_state=()
  {
    if [[ "$result_file" != "${result_file:a}" \
      || "$result_file" != "${result_file:A}" \
      || "${result_file:h}" != "$temp_root" \
      || "${result_file:t}" != zdx-mytool-fzf.* \
      || ! -f "$result_file" || -L "$result_file" ]] \
      || ! zstat -LH file_state -- "$result_file" 2>/dev/null \
      || (( file_state[uid] != EUID || file_state[nlink] != 1 \
        || (file_state[mode] & 8#77) != 0 \
        || (file_state[mode] & 8#170000) != 8#100000 \
        || file_state[size] != 0 )); then
      _mytool_error "Refusing an unsafe menu result."
    else
      identity="${file_state[device]}:${file_state[inode]}:"\
"${file_state[mode]}:${file_state[uid]}:${file_state[nlink]}"
      if ! sysopen -w -o nofollow,cloexec -u write_fd \
        -- "$result_file" 2>/dev/null; then
        _mytool_error "Could not open the menu result safely."
      else
        _mytool_fzf "$@" 1>&$(( write_fd ))
        fzf_rc=$?
        exec {write_fd}>&-
        write_fd=-1

        if ! zstat -LH current_state -- "$result_file" 2>/dev/null \
          || [[ "${current_state[device]}:${current_state[inode]}:"\
"${current_state[mode]}:${current_state[uid]}:"\
"${current_state[nlink]}" != "$identity" ]] \
          || (( current_state[size] < 0 \
            || current_state[size] > 65536 )); then
          _mytool_error "The menu result changed or exceeded its limit."
        elif ! sysopen -r -o nofollow,cloexec -u read_fd \
          -- "$result_file" 2>/dev/null; then
          _mytool_error "Could not read the menu result safely."
        else
          selection=$(<&$(( read_fd )))
          exec {read_fd}>&-
          read_fd=-1
          if (( fzf_rc != 0 )) && [[ -n "$selection" ]]; then
            _mytool_error "A failed picker returned unexpected data."
            selection=""
          else
            operation_rc=$fzf_rc
          fi
        fi
      fi
    fi
  } always {
    (( write_fd >= 0 )) && exec {write_fd}>&-
    (( read_fd >= 0 )) && exec {read_fd}>&-
    current_state=()
    if [[ -n "$identity" \
      && -f "$result_file" && ! -L "$result_file" \
      && "${result_file:h}" == "$temp_root" ]] \
      && zstat -LH current_state -- "$result_file" 2>/dev/null \
      && [[ "${current_state[device]}:${current_state[inode]}:"\
"${current_state[mode]}:${current_state[uid]}:"\
"${current_state[nlink]}" == "$identity" ]]; then
      command rm -f -- "$result_file" 2>/dev/null || cleanup_failed=1
    else
      cleanup_failed=1
    fi
    (( cleanup_failed == 0 )) || operation_rc=125
  }

  REPLY="$selection"
  return $operation_rc
}

mytool-status() {
  _mytool_info "MyTool is available."
}

mytool-inspect() {
  _mytool_info "Inspection completed."
}

_mytool_dispatch() {
  local command_name="${1:-}"
  shift 2>/dev/null || true

  case "$command_name" in
    mytool-status)  mytool-status "$@" ;;
    mytool-inspect) mytool-inspect "$@" ;;
    :)              return 0 ;;
    *)
      _mytool_error "Unknown command: $command_name"
      return 2
      ;;
  esac
}

_mytool_interactive() {
  _mytool_require fzf || return 1

  local -a rows=()
  local row=""
  row=$(_mytool_menu_section \
    "Inspection" "Read-only MyTool information.") || return
  rows+=("$row")
  row=$(_mytool_menu_entry \
    "Show Status" "mytool-status" \
    "Show whether MyTool is available in this shell.") || return
  rows+=("$row")
  row=$(_mytool_menu_entry \
    "Inspect Configuration" "mytool-inspect" \
    "Inspect the active non-secret configuration.") || return
  rows+=("$row")

  local selected=""
  local -i fzf_rc=0
  _mytool_fzf_capture \
    --prompt='mytool > ' \
    --header='Type to filter | Enter run | Esc cancel | Ctrl-/ details' \
    --bind='ctrl-/:toggle-preview' \
    --preview='case {2} in :) printf "%s\n" {3} ;; *) printf "Command: %s\n\n%s\n" {2} {3} ;; esac' \
    --preview-window='down:4:wrap' \
    < <(printf "%s\n" "${rows[@]}") || fzf_rc=$?
  selected="$REPLY"

  if (( fzf_rc != 0 )); then
    (( fzf_rc == 1 || fzf_rc == 130 )) && return 0
    _mytool_error "Unable to open the menu (status $fzf_rc)."
    return 1
  fi
  [[ -z "$selected" ]] && return 0
  local snapshot_row=""
  local -i selected_in_snapshot=0
  for snapshot_row in "${rows[@]}"; do
    if [[ "$selected" == "$snapshot_row" ]]; then
      selected_in_snapshot=1
      break
    fi
  done
  (( selected_in_snapshot )) || {
    _mytool_error "The selected action was not in the menu snapshot."
    return 1
  }

  local command_name="${${selected#*|}%%|*}"
  [[ "$command_name" == ":" ]] && return 0

  _mytool_dispatch "$command_name"
}

mytool-menu() {
  case "${1:-}" in
    "")
      _mytool_interactive
      ;;
    -h|--help)
      _mytool_usage
      ;;
    -*)
      _mytool_error "Unknown option: $1"
      return 2
      ;;
    *)
      local command_name="$1"
      shift
      _mytool_dispatch "$command_name" "$@"
      ;;
  esac
}

typeset -g _MYTOOL_MENU_SOURCED=1
```

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
