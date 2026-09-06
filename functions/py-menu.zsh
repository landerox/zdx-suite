#!/usr/bin/env zsh
# =============================================================================
# Py Menu: public loader and command router
# =============================================================================
#
# Public entrypoint for Python environment, package, and tool workflows.
# Usage: py-menu [command [args...]]
#

if [[ -n "${_PY_MENU_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset _py_menu_root="${${(%):-%x}:A:h}"
typeset _py_menu_common="$_py_menu_root/py-common.zsh"
typeset -i _py_menu_source_rc=0

if [[ -z "${_PY_COMMON_SOURCED:-}" ]]; then
  if [[ ! -f "$_py_menu_common" || -L "$_py_menu_common" \
    || ! -r "$_py_menu_common" \
    || "${_py_menu_common:A}" != "$_py_menu_common" \
    || "${_py_menu_common:A:h}" != "$_py_menu_root" ]]; then
    print -u2 -r -- "py-menu.zsh: failed to load py-common.zsh"
    unset _py_menu_root _py_menu_common _py_menu_source_rc
    return 1 2>/dev/null || exit 1
  fi

  source "$_py_menu_common"
  _py_menu_source_rc=$?
  if (( _py_menu_source_rc != 0 )) \
    || [[ -z "${_PY_COMMON_SOURCED:-}" ]]; then
    print -u2 -r -- "py-menu.zsh: failed to load py-common.zsh"
    unset _py_menu_root _py_menu_common
    {
      (( _py_menu_source_rc == 0 )) && _py_menu_source_rc=1
      return $_py_menu_source_rc 2>/dev/null || exit $_py_menu_source_rc
    } always {
      unset _py_menu_source_rc
    }
  fi
fi

typeset -a _py_menu_modules=(
  py-venv.zsh
  py-pypi.zsh
  py-tools.zsh
)
typeset _py_menu_module _py_menu_module_path

for _py_menu_module in "${_py_menu_modules[@]}"; do
  _py_menu_module_path="$_py_menu_root/py/$_py_menu_module"
  if [[ ! -f "$_py_menu_module_path" || -L "$_py_menu_module_path" \
    || ! -r "$_py_menu_module_path" \
    || "${_py_menu_module_path:A}" != "$_py_menu_module_path" \
    || "${_py_menu_module_path:A:h}" != "$_py_menu_root/py" ]]; then
    print -u2 -r -- "py-menu.zsh: failed to load $_py_menu_module"
    unset _py_menu_root _py_menu_common _py_menu_source_rc
    unset _py_menu_modules _py_menu_module _py_menu_module_path
    return 1 2>/dev/null || exit 1
  fi

  source "$_py_menu_module_path"
  _py_menu_source_rc=$?
  if (( _py_menu_source_rc == 0 )); then
    case "$_py_menu_module" in
      py-venv.zsh)
        [[ -n "${_PY_VENV_SOURCED:-}" ]] || _py_menu_source_rc=1
        ;;
      py-pypi.zsh)
        [[ -n "${_PY_PYPI_SOURCED:-}" ]] || _py_menu_source_rc=1
        ;;
      py-tools.zsh)
        [[ -n "${_PY_TOOLS_SOURCED:-}" ]] || _py_menu_source_rc=1
        ;;
    esac
  fi
  if (( _py_menu_source_rc != 0 )); then
    print -u2 -r -- "py-menu.zsh: failed to load $_py_menu_module"
    unset _py_menu_root _py_menu_common
    unset _py_menu_modules _py_menu_module _py_menu_module_path
    {
      return $_py_menu_source_rc 2>/dev/null || exit $_py_menu_source_rc
    } always {
      unset _py_menu_source_rc
    }
  fi
done

unset _py_menu_root _py_menu_common _py_menu_source_rc
unset _py_menu_modules _py_menu_module _py_menu_module_path

_py_menu_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- "  py-menu                       Open the interactive Py menu"
  print -u2 -r -- "  py-menu --multi               Run selected read-only tasks"
  print -u2 -r -- "  py-menu <command> [args...]   Run one command directly"
  print -u2 -r -- "  py-menu -h|--help             Show this help"
  print -u2 -r -- ""
  print -u2 -r -- "Canonical commands:"
  print -u2 -r -- "  venv-list"
  print -u2 -r -- "  venv-create"
  print -u2 -r -- "  venv-activate"
  print -u2 -r -- "  venv-info"
  print -u2 -r -- "  venv-rebuild"
  print -u2 -r -- "  venv-remove"
  print -u2 -r -- "  venv-python-list"
  print -u2 -r -- "  venv-python-install"
  print -u2 -r -- "  venv-python-pin"
  print -u2 -r -- "  package-search"
  print -u2 -r -- "  package-install"
  print -u2 -r -- "  package-uninstall"
  print -u2 -r -- "  tool-list"
  print -u2 -r -- "  tool-install"
  print -u2 -r -- "  tool-uninstall"
  print -u2 -r -- "  tool-upgrade"
  print -u2 -r -- ""
  print -u2 -r -- "Compatibility command:"
  print -u2 -r -- "  venv-python <list|install|pin> [args...]"
}

_py_dispatch() {
  local command_name="${1:-}"
  (( $# > 0 )) && shift

  case "$command_name" in
    venv-list)           venv-list "$@" ;;
    venv-create)         venv-create "$@" ;;
    venv-activate)       venv-activate "$@" ;;
    venv-info)           venv-info "$@" ;;
    venv-rebuild)        venv-rebuild "$@" ;;
    venv-remove)         venv-remove "$@" ;;
    venv-python-list)    venv-python-list "$@" ;;
    venv-python-install) venv-python-install "$@" ;;
    venv-python-pin)     venv-python-pin "$@" ;;
    package-search)      package-search "$@" ;;
    package-install)     package-install "$@" ;;
    package-uninstall)   package-uninstall "$@" ;;
    tool-list)           tool-list "$@" ;;
    tool-install)        tool-install "$@" ;;
    tool-uninstall)      tool-uninstall "$@" ;;
    tool-upgrade)        tool-upgrade "$@" ;;
    venv-python)         _py_venv_python "$@" ;;
    :)                   return 0 ;;
    "")
      _py_error "A Py command is required."
      return 2
      ;;
    *)
      _py_error "Unknown command: $command_name"
      return 2
      ;;
  esac
}

_py_command_is_canonical() {
  case "${1:-}" in
    venv-list|venv-create|venv-activate|venv-info|venv-rebuild|venv-remove|\
    venv-python-list|venv-python-install|venv-python-pin|\
    package-search|package-install|package-uninstall|\
    tool-list|tool-install|tool-uninstall|tool-upgrade)
      return 0
      ;;
    *) return 1 ;;
  esac
}

_py_command_is_multi_safe() {
  case "${1:-}" in
    venv-list|venv-python-list|tool-list)
      return 0
      ;;
    *) return 1 ;;
  esac
}

_py_menu_rows() {
  local mode="${1:-all}"
  local -a rows=()
  local row=""

  if [[ "$mode" == read-only ]]; then
    row=$(_py_menu_entry \
      "List Environments" "venv-list" \
      "List virtual environments belonging to the current project.") || return $?
    rows+=("$row")
    row=$(_py_menu_entry \
      "List Python Versions" "venv-python-list" \
      "List Python runtimes already installed through uv.") || return $?
    rows+=("$row")
    row=$(_py_menu_entry \
      "List Global Tools" "tool-list" \
      "List tools managed by uv and pipx.") || return $?
    rows+=("$row")
    print -rl -- "${rows[@]}"
    return 0
  fi

  row=$(_py_menu_section \
    "Virtual Environments" "Inspect and manage project-local environments.") \
    || return $?
  rows+=("$row")
  row=$(_py_menu_entry \
    "List Environments" "venv-list" \
    "List virtual environments belonging to the current project.") || return $?
  rows+=("$row")
  row=$(_py_menu_entry \
    "Show Environment Details" "venv-info" \
    "Inspect the interpreter and location of a project-local environment.") || return $?
  rows+=("$row")
  [[ "$mode" == read-only ]] || {
    row=$(_py_menu_entry \
      "Create Project Environment" "venv-create" \
      "Create .venv with uv or Python venv; Poetry creation is currently unavailable.") || return $?
    rows+=("$row")
    row=$(_py_menu_entry \
      "Activate Environment" "venv-activate" \
      "Activate a project-local environment in the current shell.") || return $?
    rows+=("$row")
  }
  [[ "$mode" == read-only ]] || {
    row=$(_py_menu_entry \
      "Review Environment Rebuild" "venv-rebuild" \
      "Show a rebuild plan; replacing the environment is currently unavailable.") \
      || return $?
    rows+=("$row")
  }
  row=$(_py_menu_entry \
    "List Python Versions" "venv-python-list" \
    "List Python runtimes already installed through uv.") || return $?
  rows+=("$row")
  [[ "$mode" == read-only ]] || {
    row=$(_py_menu_entry \
      "Install Python Version" "venv-python-install" \
      "Choose and install a Python version through uv.") || return $?
    rows+=("$row")
    row=$(_py_menu_entry \
      "Pin Python Version" "venv-python-pin" \
      "Set the project's Python version in .python-version through uv.") || return $?
    rows+=("$row")
  }

  row=$(_py_menu_section \
    "Packages" "Inspect package information or manage project dependencies.") || return $?
  rows+=("$row")
  row=$(_py_menu_entry \
    "Inspect Package" "package-search" \
    "Show package versions and metadata from PyPI without installing.") || return $?
  rows+=("$row")
  [[ "$mode" == read-only ]] || {
    row=$(_py_menu_entry \
      "Install Package" "package-install" \
      "Review and install a package in the current project.") \
      || return $?
    rows+=("$row")
  }

  row=$(_py_menu_section \
    "Global Tools" "Inspect or manage isolated uv and pipx tools.") || return $?
  rows+=("$row")
  row=$(_py_menu_entry \
    "List Global Tools" "tool-list" \
    "List tools managed by uv and pipx.") || return $?
  rows+=("$row")
  [[ "$mode" == read-only ]] || {
    row=$(_py_menu_entry \
      "Install Global Tool" "tool-install" \
      "Review and install an isolated command-line tool with uv or pipx.") \
      || return $?
    rows+=("$row")
    row=$(_py_menu_entry \
      "Upgrade Global Tools" "tool-upgrade" \
      "Upgrade one or all isolated tools after reviewing the plan.") \
      || return $?
    rows+=("$row")
  }

  row=$(_py_menu_section \
    "Removal" "Review before removing an environment, package, or global tool.") || return $?
  rows+=("$row")
  row=$(_py_menu_entry \
    "Remove Environment" "venv-remove" \
    "Remove a selected project-local environment after confirmation.") || return $?
  rows+=("$row")
  row=$(_py_menu_entry \
    "Uninstall Package" "package-uninstall" \
    "Remove a package from the current project after confirmation.") || return $?
  rows+=("$row")
  row=$(_py_menu_entry \
    "Uninstall Global Tool" "tool-uninstall" \
    "Uninstall one isolated tool after confirmation.") || return $?
  rows+=("$row")

  print -rl -- "${rows[@]}"
}

_py_menu_interactive() {
  local -i multi_select=${1:-0}
  _py_check_command fzf || {
    _py_error "fzf is required for the interactive Py menu."
    return 1
  }

  local row_mode=all
  (( multi_select )) && row_mode=read-only
  local rows=""
  rows=$(_py_menu_rows "$row_mode") || return $?
  local -a snapshot=("${(@f)rows}")

  local active_env="${VIRTUAL_ENV:-${CONDA_PREFIX:-none}}"
  [[ "$active_env" == none ]] || active_env="${active_env:t}"
  _py_value_is_safe "$active_env" || active_env="untrusted-value"
  local backend=""
  backend=$(_py_detect_venv_backend) || backend=unknown
  _py_value_is_safe "$backend" || backend=unknown

  local header="Active: $active_env | Backend: $backend"$'\n'
  header+='Type to filter | Enter run | Esc cancel | Ctrl-/ details'
  if (( multi_select )); then
    header+=$'\n''Tab mark | Ctrl-A all | Ctrl-D none | Read-only tasks only'
  fi

  local -a picker_options=(
    '--prompt=py > '
    "--header=$header"
    '--preview=case {2} in :) printf "%s\n" {3} ;; *) printf "Command: %s\n\n%s\n" {2} {3} ;; esac'
    '--preview-window=down:4:wrap'
    '--bind=ctrl-/:toggle-preview'
  )
  (( multi_select )) && picker_options+=(
    --multi
    '--marker=✓'
    '--bind=ctrl-a:select-all,ctrl-d:deselect-all'
  )

  local -i picker_rc=0
  _py_fzf_capture "${picker_options[@]}" \
    < <(print -r -- "$rows") || picker_rc=$?
  local selected="$REPLY"

  if (( picker_rc != 0 )); then
    if _py_fzf_rc_is_cancel "$picker_rc"; then
      (( multi_select )) \
        && _py_info \
          "Batch summary: passed=0 failed=0 skipped=0 cancelled=1"
      return 0
    fi
    _py_error "Unable to open the interactive Py menu (status $picker_rc)."
    return 1
  fi
  [[ -n "$selected" ]] || return 0

  local -a selected_rows=("${(@f)selected}")
  local selected_row="" command_name=""
  local -i failures=0 passed=0 skipped=0 cancelled=0 runnable=0
  for selected_row in "${selected_rows[@]}"; do
    _py_array_contains_literal "$selected_row" "${snapshot[@]}" || {
      _py_error "A selected Py action was not in the menu snapshot."
      return 1
    }
    command_name="${${selected_row#*|}%%|*}"
    if [[ "$command_name" == : ]]; then
      (( skipped++ ))
      continue
    fi
    _py_command_is_canonical "$command_name" || {
      _py_error "Refusing an unknown Py menu action."
      return 1
    }
    if (( multi_select )) && ! _py_command_is_multi_safe "$command_name"; then
      _py_error "Refusing a mutating action in multi-select mode."
      return 1
    fi
    (( runnable++ ))
    _py_info "Executing: $command_name"
    if _py_timed "py:$command_name" _py_dispatch "$command_name"; then
      (( passed++ ))
    else
      (( failures++ ))
    fi
  done

  if (( multi_select )); then
    _py_info \
      "Batch summary: passed=$passed failed=$failures skipped=$skipped cancelled=$cancelled"
  fi
  (( runnable > 0 )) || {
    _py_info "No runnable tasks selected."
    return 0
  }
  (( failures == 0 )) || {
    _py_error "$failures of $runnable Py task(s) failed."
    return 1
  }
  return 0
}

py-menu() {
  emulate -L zsh

  case "${1:-}" in
    "")
      (( $# == 0 )) || return 2
      _py_menu_interactive 0
      ;;
    -m|--multi)
      (( $# == 1 )) || {
        _py_error "--multi accepts no additional arguments."
        return 2
      }
      _py_menu_interactive 1
      ;;
    -h|--help)
      (( $# == 1 )) || {
        _py_error "--help accepts no additional arguments."
        return 2
      }
      _py_menu_usage
      ;;
    -*)
      _py_error "Unknown option: $1"
      return 2
      ;;
    *)
      local command_name="$1"
      shift
      _py_timed "py:$command_name" _py_dispatch "$command_name" "$@"
      ;;
  esac
}

typeset -g _PY_MENU_SOURCED=1

if [[ "${zsh_eval_context[-1]}" == toplevel ]]; then
  py-menu "$@"
fi
