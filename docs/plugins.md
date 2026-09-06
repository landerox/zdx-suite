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

The current loader accepts underscores for backward compatibility, but new
plugins must not use them because public commands are kebab-case.

Names owned by the `zdx` wrapper are reserved for built-in routing. A custom
plugin must not use a built-in suite name, `doctor`, `plugins`, `help`, or
`version`; the master menu skips such collisions.

- Public functions use `<plugin-name>-<action>`.
- Private helpers use `_<plugin_name>_*`, replacing hyphens with underscores.
- Global configuration uses an uppercase plugin prefix.
- The idempotency sentinel uses the uppercase underscore form.

For `mytool`, examples are `mytool-menu`, `mytool-status`, `_mytool_error`, and
`MYTOOL_CACHE_DIR`.

Plugins MUST NOT define generic names such as `log`, `confirm`, `cleanup`, or
`dispatch` in the global shell namespace.

## Self-contained boundary

A plugin may use:

- Zsh builtins and modules;
- external commands it declares and checks;
- its own namespaced helpers and configuration;
- an already-loaded, documented optional core visual helper with a fallback.

A plugin MUST NOT source a built-in suite common file or call undocumented
suite-private helpers. In particular, it must not source `git-common.zsh` to
obtain `_tk_*` behavior.

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
2. requires an owned, non-symlink plugin root whose lexical and canonical paths
   agree;
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
    SHELL=/bin/sh command fzf "${options[@]}" "$@" "${terminal_options[@]}"
}

# Run fzf in the terminal foreground and return its complete selection in
# REPLY. The private result is byte-bounded and removed only by exact identity.
_mytool_fzf_capture() {
  emulate -L zsh
  REPLY=""
  zmodload zsh/stat zsh/system 2>/dev/null || {
    _mytool_error "Zsh file-descriptor support is required."
    return 125
  }

  local temp_root="${TMPDIR:-/tmp}"
  while [[ "$temp_root" != "/" && "$temp_root" == */ ]]; do
    temp_root="${temp_root%/}"
  done
  local -A root_state=() temp_state=()
  [[ -n "$temp_root" && "$temp_root" == /* \
    && "$temp_root" == "${temp_root:a}" \
    && "$temp_root" == "${temp_root:A}" \
    && -d "$temp_root" && ! -L "$temp_root" ]] \
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
