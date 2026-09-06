#!/usr/bin/env zsh
# =============================================================================
# Network Menu: public loader and command router for network diagnostics
# =============================================================================
#
# Public loader and command router for bounded network diagnostics.
# Usage: net-menu [subcommand]
#

if [[ -n "${_NET_MENU_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset _net_loader_dir="${${(%):-%x}:A:h}"

_net_source_module() {
  local relative_name="$1"
  local module_path="${_net_loader_dir}/${relative_name}"
  [[ -f "$module_path" && ! -L "$module_path" && -r "$module_path" ]] \
    || return 1
  [[ "${module_path:A}" == "$module_path" \
    && "${module_path:A:h}" == "${module_path:h}" ]] || return 1
  builtin source "$module_path"
}

typeset -i _net_source_rc=0
typeset _net_failed_module="net-common.zsh"
_net_source_module "$_net_failed_module" || _net_source_rc=$?
if (( _net_source_rc == 0 )); then
  typeset _net_module=""
  for _net_module in \
    net/net-public.zsh \
    net/net-diagnostics.zsh \
    net/net-interfaces.zsh \
    net/net-throughput.zsh \
    net/net-dashboard.zsh; do
    _net_failed_module="$_net_module"
    _net_source_module "$_net_module" || {
      _net_source_rc=$?
      break
    }
  done
fi
if (( _net_source_rc != 0 )); then
  print -u2 -r -- \
    "net-menu.zsh: failed to load $_net_failed_module (status $_net_source_rc)"
  unset -f _net_source_module
  unset _net_loader_dir _net_module _net_failed_module
  {
    return $_net_source_rc 2>/dev/null || exit $_net_source_rc
  } always {
    unset _net_source_rc
  }
fi

unset -f _net_source_module
unset _net_loader_dir _net_module _net_failed_module _net_source_rc

_net_usage() {
  print -u2 -r -- 'Usage:'
  print -u2 -r -- '  net-menu'
  print -u2 -r -- '  net-menu COMMAND [arguments]'
  print -u2 -r -- '  net-menu -h|--help'
  print -u2 -r -- ''
  print -u2 -r -- 'Commands:'
  print -u2 -r -- '  net-dashboard     Render a bounded connectivity snapshot'
  print -u2 -r -- '  net-public-ip     Resolve and optionally cross-check the public exit IP'
  print -u2 -r -- '  net-interfaces    Inspect bounded local interface state'
  print -u2 -r -- '  net-ping          Measure bounded ICMP latency'
  print -u2 -r -- '  net-dns           Resolve bounded A, AAAA, and MX records'
  print -u2 -r -- '  net-speedtest     Run an explicitly authorized throughput transfer'
  print -u2 -r -- ''
  print -u2 -r -- 'Network and privacy:'
  print -u2 -r -- \
    '  Public-IP and throughput commands contact the providers named in their help.'
  print -u2 -r -- \
    '  net-speedtest requires confirmation; non-interactive use requires --yes.'
  print -u2 -r -- \
    '  Local command probes require timeout or gtimeout.'
  print -u2 -r -- ''
  print -u2 -r -- 'Use COMMAND --help for command-specific flags.'
}

_net_dispatch() {
  local command_name="${1:-}"
  shift 2>/dev/null || true

  case "$command_name" in
    net-dashboard)  net-dashboard "$@" ;;
    net-public-ip)  net-public-ip "$@" ;;
    net-interfaces) net-interfaces "$@" ;;
    net-ping)       net-ping "$@" ;;
    net-dns)        net-dns "$@" ;;
    net-speedtest)  net-speedtest "$@" ;;
    :)              return 0 ;;
    *)
      _net_error "Unknown command: $(_net_display_escape "$command_name")"
      return 2
      ;;
  esac
}

# stdout: fixed label|command|description records for the top-level menu.
_net_menu_rows() {
  local row=""
  row=$(_net_menu_section \
    "Inspection" \
    "Inspect local interfaces or check connectivity and your public IP.") || return
  print -r -- "$row"
  row=$(_net_menu_entry \
    "Show Network Dashboard" \
    "net-dashboard" \
    "Summarize local interfaces, routes, DNS, connectivity, and public IP.") || return
  print -r -- "$row"
  row=$(_net_menu_entry \
    "Show Public IP Information" \
    "net-public-ip" \
    "Look up your public IP and location through an HTTPS provider.") \
    || return
  print -r -- "$row"
  row=$(_net_menu_entry \
    "Inspect Local Interfaces" \
    "net-interfaces" \
    "Show local interface status, addresses, and traffic counters.") \
    || return
  print -r -- "$row"
  row=$(_net_menu_section \
    "Active Probes" \
    "Send diagnostic traffic to a chosen host or provider.") || return
  print -r -- "$row"
  row=$(_net_menu_entry \
    "Measure Ping Latency" \
    "net-ping" \
    "Measure latency and packet loss with up to twenty probes to one host.") || return
  print -r -- "$row"
  row=$(_net_menu_entry \
    "Resolve DNS Records" \
    "net-dns" \
    "Look up IPv4, IPv6, and mail-server records for one domain.") || return
  print -r -- "$row"
  row=$(_net_menu_entry \
    "Run Throughput Test" \
    "net-speedtest" \
    "Confirm a speed-test CLI run or a 10 MiB HTTPS download before measuring speed.") \
    || return
  print -r -- "$row"
}

_net_interactive() {
  command -v fzf &>/dev/null || {
    _net_error "Interactive Network menus require fzf."
    _net_dim "Use a direct net-* command or install fzf."
    return 1
  }

  local rows_output=""
  rows_output=$(_net_menu_rows) || return
  local -a menu_rows=("${(@f)rows_output}")
  (( ${#menu_rows[@]} > 0 )) || {
    _net_error "The Network menu has no actions."
    return 1
  }

  local -i fzf_rc=0
  _net_fzf_capture \
    --delimiter='[|]' \
    --with-nth=1 \
    --prompt='net > ' \
    --header='Type to filter | Enter run | Esc cancel | Ctrl-/ details' \
    --preview='case {2} in :) printf "%s\n" {3} ;; *) printf "Command: %s\n\n%s\n" {2} {3} ;; esac' \
    --preview-window='down:4:wrap' \
    --bind='ctrl-/:toggle-preview' \
    < <(printf "%s\n" "${menu_rows[@]}") || fzf_rc=$?
  local selected="$REPLY"

  if (( fzf_rc != 0 )); then
    if _net_fzf_rc_is_cancel "$fzf_rc"; then
      [[ -z "$selected" ]] && return 0
      _net_error "The cancelled Network menu returned unexpected data."
      return 125
    fi
    _net_error "Unable to open the Network menu (status $fzf_rc)."
    (( fzf_rc == 125 )) && return 125
    return 1
  fi
  [[ -z "$selected" ]] && return 0
  local -i selected_index="${menu_rows[(Ie)$selected]}"
  (( selected_index > 0 && selected_index <= ${#menu_rows[@]} )) || {
    _net_error "The selected Network action was not in the menu snapshot."
    return 1
  }

  local command_name="${${selected#*|}%%|*}"
  [[ "$command_name" == ":" ]] && return 0
  if typeset -f _timed &>/dev/null; then
    _timed "net:$command_name" _net_dispatch "$command_name"
  else
    _net_dispatch "$command_name"
  fi
}

net-menu() {
  case "${1:-}" in
    "")
      (( $# == 0 )) || return 2
      _net_interactive
      ;;
    -h|--help)
      (( $# == 1 )) || {
        _net_error "--help accepts no arguments."
        return 2
      }
      _net_usage
      ;;
    -*)
      _net_error "Unknown option: $(_net_display_escape "$1")"
      return 2
      ;;
    *)
      local command_name="$1"
      shift
      if typeset -f _timed &>/dev/null; then
        _timed "net:$command_name" _net_dispatch "$command_name" "$@"
      else
        _net_dispatch "$command_name" "$@"
      fi
      ;;
  esac
}

typeset -g _NET_MENU_SOURCED=1
