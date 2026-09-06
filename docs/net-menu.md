# Network suite contract

This document freezes the public interface and safety model of the Network
suite. General suite behavior follows
[`development.md`](development.md), interactive behavior follows
[`menu-spec.md`](menu-spec.md), and tests follow
[`testing.md`](testing.md).

## Ownership

Network owns read-only inspection and active diagnostics for:

- default routes and local interfaces;
- bounded ICMP latency;
- bounded A, AAAA, and MX resolution;
- public exit-IP metadata;
- explicitly authorized throughput measurements.

Network does not own VPN lifecycle, host package installation, firewall
configuration, service management, or cloud-specific connectivity. VPN
connection state belongs to `vpn`, dependency installation belongs to
`zdx-doctor`, and host networking mutations belong to `sys`.

## Frozen public surface

| Command | Grammar | Effect | Required capability |
| --- | --- | --- | --- |
| `net-dashboard` | `[--local-only]` | Read-only aggregate snapshot | Per-section capabilities |
| `net-public-ip` | `[--cross-check]` | Bounded HTTPS metadata requests | `curl`; `jq` enriches JSON providers |
| `net-interfaces` | no operands | Read-only local interface inventory | Linux sysfs or `ifconfig`; subprocesses use `timeout`/`gtimeout` |
| `net-ping` | `[--count 1..20] [TARGET]` | Up to 20 bounded ICMP probes | `ping` and `timeout`/`gtimeout` |
| `net-dns` | `[DOMAIN]` | Bounded A, AAAA, and MX queries | `dig` or `host`, plus `timeout`/`gtimeout` |
| `net-speedtest` | `[--dry-run] [--yes]` | Authorized bandwidth-consuming transfer | `speedtest-cli` or `speedtest` plus `timeout`/`gtimeout`, or `curl` |

Every command accepts `-h|--help`. Help is parsed before dependency and host
probes. Unknown flags, excess operands, invalid counts, invalid domains, and
unknown dispatch tokens return status `2`.

The top-level menu, dispatcher, help, completion, direct completion bindings,
fixture, and lazy-loader registrations must expose exactly these six names.

## Entrypoint and loading

`functions/net-menu.zsh` derives one source root from `%x`, refuses symbolic or
unreadable modules, and loads this exact order:

1. `net-common.zsh`;
2. `net/net-public.zsh`;
3. `net/net-diagnostics.zsh`;
4. `net/net-interfaces.zsh`;
5. `net/net-throughput.zsh`;
6. `net/net-dashboard.zsh`.

The menu sentinel is set only after all modules load. A failed module reports
its exact relative name and source status. Re-sourcing is silent and performs
no probe, network request, prompt, or filesystem scan.

## Stream and status contract

Public Network commands render human-facing output on `stderr`. Their `stdout`
is empty. Private discovery helpers may emit the documented TSV records on
`stdout`; callers check status before parsing those records.

Statuses follow the repository defaults:

- `0`: success, deliberate menu cancellation, declined throughput
  authorization, or a rendered dashboard with unavailable sections;
- `1`: missing capability, offline provider set, malformed backend response, or
  operational failure;
- `2`: invalid grammar or unavailable non-interactive authorization;
- `124`: a direct ping, DNS, or speed-test CLI deadline expired;
- `125`: a bounded inventory, probe output, or private picker result exceeded
  its safety boundary or could not be handled safely;
- `130` / `143`: an interrupted backend; remaining providers and dashboard
  sections are not attempted.

`net-dashboard` is a best-effort diagnostic aggregate. Offline state is useful
diagnostic output rather than an aggregate failure. Each unavailable section is
visible and independent sections continue.

An empty successful DNS record type is valid: a domain with A or AAAA records
and no MX records still renders its address results. A failed ping can render
its validated packet summary while retaining failure status; partial output
never turns an interrupted ping into success.

## Input validation

Active probes accept data, never shell syntax:

- packet counts are canonical decimal integers from 1 through 20;
- ping targets are semantic IP literals or DNS names with bounded labels;
- DNS accepts one bounded domain and no option-like operand;
- interface names are bounded to the kernel-oriented
  `[A-Za-z0-9_.:@-]` alphabet and cannot begin with `-`;
- remote IPs are validated before publication;
- metadata fields reject terminal controls, tabs, and oversized values;
- menu fields reject controls and the `|` record delimiter.

No selected row, host, interface, URL, remote field, or backend token is passed
to `eval`, a computed function name, or shell program text. Fixed `case`
dispatch is the executable allowlist.

## Network and privacy boundary

The suite contains no user-configurable provider URL. Public-IP discovery uses
this fixed HTTPS set:

- JSON metadata: `ipapi.co`, `ipinfo.io`, and `freeipapi.com`;
- plain addresses: `icanhazip.com`, `ifconfig.me`, and `api.ipify.org`;
- Cloudflare trace: `1.1.1.1`.

Normal public-IP discovery stops after the first validated response.
`--cross-check` explicitly contacts all applicable fixed providers,
sequentially and at most once each for that invocation. Each request:

- disables curl configuration;
- allows HTTPS and HTTPS redirects only;
- permits at most two redirects;
- uses a two-second connection deadline and five-second total deadline;
- caps the response at 128 KiB, or 4 KiB for plain IP responses;
- sends no ZDX credential or authorization header.

The caller's address is necessarily visible to each contacted provider.
Provider privacy, retention, DNS resolution, TLS trust, proxies, and service
accuracy remain external trust boundaries. `jq` is optional: without it, JSON
providers are skipped and bounded plain or trace providers remain available.
JSON parsing also requires `timeout` or `gtimeout`; the fixed parser receives
at most 128 KiB, runs for at most five seconds, and emits at most 4 KiB. The
dashboard tries at most two public-IP providers; the dedicated `net-public-ip`
command may use the complete seven-provider cascade.

`net-dashboard --local-only` is the privacy-preserving aggregate mode. It skips
ICMP, DNS, and public-IP requests and displays only local route and interface
state.

## Probe and inventory bounds

Read-only local subprocesses use GNU `timeout` or `gtimeout`. Probe output is
captured before parsing and rejected above its command-specific limit:

- ping: 256 KiB, at most 20 packets, at most 63 seconds;
- each DNS type: 128 KiB, eight seconds, at most 64 accepted records;
- interface address and route probes: 64–512 KiB, five to eight seconds;
- speed-test CLI: 1 MiB and 180 seconds.

Linux interface discovery accepts at most 256 sysfs entries. `ifconfig`
fallbacks accept at most 256 parsed interfaces. Values from sysfs and command
output are grammar-checked before becoming TSV fields or terminal text. Local
resolver inspection accepts only a regular `resolv.conf` target up to 64 KiB,
reads at most 64 lines, and rejects an oversized line.

Timeouts apply only to read-only diagnostics. Network has no local mutation
that could continue after a timeout.

## Throughput authorization

`net-speedtest` selects the first usable backend in this order:

1. `speedtest-cli` with `timeout` or `gtimeout`;
2. Ookla `speedtest` with `timeout` or `gtimeout`;
3. a fixed Cloudflare HTTPS fallback.

The plan displays the backend, scope, provider when fixed, and deadline before
traffic starts. An installed CLI without a deadline capability is skipped in
favor of the fixed curl fallback, or refused when curl is unavailable.
`--dry-run` performs no network transfer but still validates that a usable
backend exists. A terminal decline is successful cancellation. A
non-interactive caller must pass `--yes`; authorization does not bypass
dependency, endpoint, output, or deadline validation.

The fixed fallback downloads exactly 10 MiB to `/dev/null` from
`speed.cloudflare.com`, permits HTTPS redirects only, uses a five-second
connection deadline and 60-second total deadline, and reports an elapsed-rate
estimate. CLI output is bounded and terminal-escaped before rendering. ZDX
does not pass flags that silently accept an unaccepted Ookla license; a backend
that requires separate setup fails visibly.
If elapsed time cannot be measured reliably, the completed payload is reported
with its rate unavailable rather than an invented estimate.

## Interactive adapter

The top-level menu is one-shot. Selecting an action runs it once and returns to
the shell. Esc and Ctrl-C at `fzf` return `0`.

`fzf` runs synchronously in the terminal foreground. Its stdout is redirected
to an invocation-owned mode-`600` file below a mode-`700` directory in a
validated temporary root. Directory and file identity, ownership, link count,
size, exact direct-child name, and ancestor safety are checked around use and
cleanup. Probe capture files use the same exact-child rule. Only a complete
record from the current menu snapshot may dispatch; a non-zero picker result
carrying data is an integrity failure rather than cancellation. The compact
presentation follows [`menu-spec.md`](menu-spec.md): `Ctrl-/` toggles the
four-line preview of the canonical command and description. Section previews
show only their description; opening details runs no diagnostic probe.

## Platform contract

The implementation is capability-oriented:

- Linux uses `/sys/class/net` and augments it with bounded `ip` output;
- hosts without safe Linux sysfs may use bounded `ifconfig`;
- route inspection prefers `ip` and has a bounded BSD-style `route` fallback;
- DNS uses installed `dig` or `host`;
- macOS requires GNU coreutils as `gtimeout` for subprocess deadlines.

Mocked branches prove routing and parsing, not real-host compatibility. A
platform claim beyond the exercised capability must be recorded through a
repeatable manual smoke test.

## Test and manual acceptance boundary

Focused BATS coverage is split across:

- `test/net.bats` for loading, help, streams, and representative workflows;
- `test/net_contract.bats` for the frozen six-command surface;
- `test/net_safety.bats` for parser-before-probe, output bounds, privacy flags,
  authorization, cancellation, snapshot validation, and failure statuses;
- `test/net_recovery.bats` for empty DNS types, partial ping summaries,
  interrupted provider/diagnostic chains, and unavailable throughput timing.

Tests mock every network client and do not send packets or transfer bandwidth.
Manual acceptance remains required for:

- real Linux sysfs and BSD/macOS `ifconfig` layouts;
- real IPv4 and IPv6 ping output variants;
- resolver behavior under NXDOMAIN, truncation, and rate limiting;
- provider schema and privacy-policy changes;
- installed `speedtest-cli` and Ookla CLI versions;
- a real 10 MiB throughput transfer.

The final same-EUID pathname window in private picker cleanup and a hostile
replacement of an executable already selected from `PATH` remain outside what
portable userspace identity checks can eliminate.
