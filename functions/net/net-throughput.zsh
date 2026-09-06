#!/usr/bin/env zsh
# =============================================================================
# Network Throughput: explicit bounded speed-test and HTTPS transfer workflow
# =============================================================================
#
# Loaded by net-menu.zsh after net-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_NET_THROUGHPUT_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_net_speedtest_usage() {
  print -u2 -r -- 'Usage:'
  print -u2 -r -- '  net-speedtest [--dry-run] [--yes]'
  print -u2 -r -- '  net-speedtest -h|--help'
  print -u2 -r -- ''
  print -u2 -r -- 'Options:'
  print -u2 -r -- '  --dry-run   Show the selected backend and transfer scope only'
  print -u2 -r -- '  --yes       Skip the transfer confirmation'
  print -u2 -r -- ''
  print -u2 -r -- \
    'Backend order: speedtest-cli, Ookla speedtest, fixed 10 MiB HTTPS transfer.'
  print -u2 -r -- \
    'CLI backends require timeout/gtimeout and have a 180-second deadline.'
  print -u2 -r -- \
    'The HTTPS fallback starts at speed.cloudflare.com and stops at 60 seconds.'
}

# stdout: one fixed backend identifier.
_net_speedtest_backend() {
  local cli_without_deadline=""
  if command -v speedtest-cli &>/dev/null; then
    if _net_have_timeout; then
      print -r -- "speedtest-cli"
      return 0
    fi
    cli_without_deadline="speedtest-cli"
  fi
  if command -v speedtest &>/dev/null; then
    if _net_have_timeout; then
      print -r -- "speedtest"
      return 0
    fi
    [[ -n "$cli_without_deadline" ]] || cli_without_deadline="speedtest"
  fi
  if command -v curl &>/dev/null; then
    print -r -- "curl"
    return 0
  fi
  [[ -z "$cli_without_deadline" ]] || return 2
  return 1
}

_net_speedtest_cli() {
  local backend="$1"
  [[ "$backend" == "speedtest-cli" || "$backend" == "speedtest" ]] \
    || return 2
  _net_have_timeout || {
    _net_error "The selected speed-test CLI requires timeout or gtimeout."
    _net_dim "Install GNU coreutils and retry."
    return 1
  }

  local output=""
  local -i backend_rc=0
  if [[ "$backend" == "speedtest-cli" ]]; then
    _net_capture_probe 1048576 180 speedtest-cli --secure || backend_rc=$?
  else
    _net_capture_probe 1048576 180 \
      speedtest --progress=no --format=human-readable || backend_rc=$?
  fi
  output="$REPLY"

  local line=""
  for line in "${(@f)output}"; do
    _net_dim "$(_net_display_escape "$line")"
  done
  return $backend_rc
}

_net_speedtest_curl() {
  local LC_ALL=C
  local speedtest_url="https://speed.cloudflare.com/__down?bytes=10485760"
  _net_safe_provider_url "$speedtest_url" || {
    _net_error "The fixed throughput endpoint failed validation."
    return 1
  }

  local start_ms=""
  local end_ms=""
  local curl_output=""
  _net_now_ms && start_ms="$REPLY"
  curl_output=$(command curl \
    --disable \
    --fail \
    --silent \
    --show-error \
    --location \
    --max-redirs 1 \
    --proto '=https' \
    --proto-redir '=https' \
    --connect-timeout 5 \
    --max-time 60 \
    --max-filesize 10485760 \
    --output /dev/null \
    --write-out 'zdx-net-size:%{size_download}\n' \
    --url "$speedtest_url" 2>&1)
  local -i curl_rc=$?
  _net_now_ms && end_ms="$REPLY"
  (( curl_rc != 130 && curl_rc != 143 )) || return $curl_rc
  (( ${#curl_output} <= 65536 )) || return 125
  local line=""
  local downloaded_bytes=""
  for line in "${(@f)curl_output}"; do
    if [[ "$line" == zdx-net-size:* ]]; then
      [[ -z "$downloaded_bytes" ]] || return 1
      downloaded_bytes="${line#zdx-net-size:}"
    else
      _net_dim "$(_net_display_escape "$line")"
    fi
  done
  (( curl_rc == 0 )) || return 1
  _net_valid_uint_range "$downloaded_bytes" 10485760 10485760 || return 1

  local elapsed_ms=""
  if [[ "$start_ms" =~ '^[0-9]{1,16}$' \
    && "$end_ms" =~ '^[0-9]{1,16}$' ]] \
    && (( end_ms >= start_ms )); then
    elapsed_ms="$(( end_ms - start_ms ))"
  fi
  if [[ -z "$elapsed_ms" ]] || (( elapsed_ms <= 0 )); then
    _net_label "Payload" "10.00 MiB"
    _net_warn "Transfer completed, but elapsed time and rate are unavailable."
    return 0
  fi

  local -F 2 megabits_per_second=$(( \
    (downloaded_bytes * 8.0 * 1000.0) / (elapsed_ms * 1000000.0) ))
  _net_label "Payload" "10.00 MiB"
  _net_label "Elapsed" "$(printf '%.3f' $(( elapsed_ms / 1000.0 ))) seconds"
  _net_label "Estimated Rate" \
    "$(printf '%.2f' "$megabits_per_second") Mbps"
}

net-speedtest() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    (( $# == 1 )) || {
      _net_error "--help accepts no arguments."
      return 2
    }
    _net_speedtest_usage
    return 0
  fi

  local dry_run="no"
  local auto_yes="no"
  local end_options="no"
  while (( $# )); do
    if [[ "$end_options" == "yes" ]]; then
      _net_error "Unexpected argument: $(_net_display_escape "$1")"
      return 2
    fi
    case "$1" in
      --dry-run) dry_run="yes" ;;
      --yes)     auto_yes="yes" ;;
      --)        end_options="yes" ;;
      -*)
        _net_error "Unknown option: $(_net_display_escape "$1")"
        return 2
        ;;
      *)
        _net_error "Unexpected argument: $(_net_display_escape "$1")"
        return 2
        ;;
    esac
    shift
  done

  local backend=""
  local -i backend_rc=0
  backend=$(_net_speedtest_backend) || backend_rc=$?
  if (( backend_rc == 2 )); then
    _net_error "Installed speed-test CLIs cannot run without timeout or gtimeout."
    _net_dim "Install GNU coreutils or curl, then retry."
    return 1
  elif (( backend_rc != 0 )); then
    _net_error "No supported throughput backend was found."
    _net_dim "Install curl, speedtest-cli, or the Ookla speedtest CLI."
    return 1
  fi

  _net_header "Throughput Test Plan"
  _net_label "Backend" "$backend"
  if [[ "$backend" == "curl" ]]; then
    _net_label "Provider" "speed.cloudflare.com"
    _net_label "Transfer" "10 MiB download to /dev/null"
    _net_label "Deadline" "60 seconds"
  else
    _net_label "Transfer" "Backend-defined latency, download, and upload probes"
    _net_label "Deadline" "180 seconds"
  fi
  _net_warn "This test consumes network bandwidth and exposes your public IP to the provider."

  if [[ "$dry_run" == "yes" ]]; then
    _net_success "Dry run complete; no network transfer started."
    return 0
  fi

  local -i confirm_rc=0
  _net_confirm_network_transfer \
    "Start the displayed throughput test?" "$auto_yes" || confirm_rc=$?
  case "$confirm_rc" in
    0) ;;
    1)
      _net_info "Cancelled."
      return 0
      ;;
    *)
      _net_error "Confirmation requires a terminal; pass --yes to proceed."
      return 2
      ;;
  esac

  _net_header "Throughput Test"
  local -i test_rc=0
  if [[ "$backend" == "curl" ]]; then
    _net_speedtest_curl || test_rc=$?
  else
    _net_speedtest_cli "$backend" || test_rc=$?
  fi
  (( test_rc != 130 && test_rc != 143 )) || return $test_rc
  if (( test_rc != 0 )); then
    if (( test_rc == 124 )); then
      _net_error "The throughput test timed out."
      return 124
    elif (( test_rc == 125 )); then
      _net_error "The throughput test exceeded its capture safety boundary."
      return 125
    fi
    _net_error "The throughput test failed (status $test_rc)."
    return 1
  fi
  _net_success "Throughput test completed."
}

typeset -g _NET_THROUGHPUT_SOURCED=1
