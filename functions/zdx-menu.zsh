#!/usr/bin/env zsh
# =============================================================================
# ZDX Master Menu: public wrapper and suite router
# =============================================================================
#
# Public loader and command router for the unified ZDX wrapper.
# Usage: zdx [suite] [args]
#

if [[ -n "${_ZDX_MENU_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset _zdx_menu_loader_dir="${${(%):-%x}:A:h}"
typeset _zdx_menu_common_file="$_zdx_menu_loader_dir/zdx-common.zsh"
if [[ ! -f "$_zdx_menu_common_file" || -L "$_zdx_menu_common_file" \
  || ! -r "$_zdx_menu_common_file" \
  || "${_zdx_menu_common_file:A:h}" != "$_zdx_menu_loader_dir" ]]; then
  print -u2 -r -- "zdx-menu.zsh: failed to load zdx-common.zsh"
  unset _zdx_menu_loader_dir _zdx_menu_common_file
  return 1 2>/dev/null || exit 1
fi

if [[ -z "${_ZDX_COMMON_SOURCED:-}" ]]; then
  source "$_zdx_menu_common_file" || {
    typeset -i _zdx_menu_source_rc=$?
    print -u2 -r -- "zdx-menu.zsh: failed to load zdx-common.zsh"
    unset _zdx_menu_loader_dir _zdx_menu_common_file
    {
      return $_zdx_menu_source_rc 2>/dev/null || exit $_zdx_menu_source_rc
    } always {
      unset _zdx_menu_source_rc
    }
  }
fi

if [[ -z "${_ZDX_COMMON_SOURCED:-}" ]] \
  || ! typeset -f _zdx_interactive _zdx_dispatch_suite &>/dev/null; then
  print -u2 -r -- "zdx-menu.zsh: zdx-common.zsh loaded incompletely"
  unset _zdx_menu_loader_dir _zdx_menu_common_file
  return 1 2>/dev/null || exit 1
fi

_zdx_menu_usage() {
  cat >&2 <<'EOF'
Usage:
  zdx-menu                 Open the interactive master menu

Options:
  -h, --help               Show this help

Use `zdx <suite> [args]` for direct suite dispatch.
EOF
}

_zdx_usage() {
  cat >&2 <<'EOF'
Usage:
  zdx                      Open the interactive master menu
  zdx <suite> [args]       Run one built-in or loaded custom suite directly

Projects:
  git                      Git workflows
  ws                       Workspace profiles and Git identities
  dev                      Project maintenance and dependency updates
  app                      Discover and run project tasks
  ci                       GitHub workflows and CI resources

Files and Environments:
  file                     File and archive utilities
  env                      Environment and dotenv profiles
  py                       Python environments, packages, and tools

System and Network:
  sys                      System diagnostics and maintenance
  docker                   Docker resources and Compose
  net                      Network diagnostics
  vpn                      WireGuard VPN

AI and Hardware:
  ai                       AI assistants and MCP
  hf                       Hugging Face Hub
  gpu                      NVIDIA GPU telemetry

ZDX Tools:
  doctor                   Dependency diagnostics
  plugins                  ZDX plugin manager

Options:
  -h, --help, help         Show this help
  -v, --version, version   Show the installed ZDX version

Loaded custom plugins are available as `zdx <plugin-name> [args]`.
EOF
}

zdx-menu() {
  case "${1:-}" in
    "")
      _zdx_interactive
      ;;
    -h|--help)
      (( $# == 1 )) || {
        _zdx_error "zdx-menu help does not accept additional arguments."
        return 2
      }
      _zdx_menu_usage
      ;;
    -*)
      _zdx_error "Unknown zdx-menu option: '$1'."
      return 2
      ;;
    *)
      _zdx_error "Unexpected zdx-menu argument: '$1'."
      return 2
      ;;
  esac
}

zdx() {
  case "${1:-}" in
    "")
      zdx-menu
      ;;
    -h|--help|help)
      (( $# == 1 )) || {
        _zdx_error "zdx help does not accept additional arguments."
        return 2
      }
      _zdx_usage
      ;;
    -v|--version|version)
      (( $# == 1 )) || {
        _zdx_error "zdx version does not accept additional arguments."
        return 2
      }
      printf 'ZDX (Zsh Developer Experience) v0.1.0\n'
      ;;
    -*)
      _zdx_error "Unknown zdx option: '$1'."
      return 2
      ;;
    *)
      local suite_name="$1"
      shift
      _zdx_dispatch_suite "$suite_name" "$@"
      ;;
  esac
}

unset _zdx_menu_loader_dir _zdx_menu_common_file
typeset -g _ZDX_MENU_SOURCED=1
