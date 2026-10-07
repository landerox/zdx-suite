# VPN suite contract

This document is the public contract for the `vpn` suite. It defines the frozen
command surface, the platform contract, the privilege model, the record format,
the preview design, and the persisted state layout.

The general engineering contract is in [`development.md`](development.md), the
interactive UI contract is in [`menu-spec.md`](menu-spec.md), and the file and
loader conventions are in [`headers.md`](headers.md). Where this document and
those disagree, they win.

## Menu presentation

The manager retains its four-field records, state refresh, and larger private
status preview. Its header has a scope line, `Directory: <path>` with `HOME`
shown as `~`, naming the profile directory that profile actions change, and
one state line of short facts, most decision-relevant first:

```text
Directory: /etc/wireguard
Active: none | Profiles: locked | Sudo: locked | Platform: wsl
Type to filter | Enter run | Esc cancel | Ctrl-/ details
```

`Active` is `none`, the one active tunnel, a tunnel count, `locked`, or
`unknown`. `Profiles` is a count, `missing`, `locked`, `unsafe`, or `unknown`.
`Sudo` is `unlocked` when non-interactive access is available, otherwise
`locked`, or `missing`. `Platform` is `linux`, `wsl`, `darwin`, or `other`.
`WSL fix: on` or `WSL fix: off` is appended only when it differs from the
platform default: on WSL that default follows the networking mode. When preview generation succeeds,
`Ctrl-/ details` and its toggle binding are added together. If no preview is
available, neither the binding nor its legend is advertised. Ordinary profile
and interface pickers retain their compact layout and behavior.

Labels carry no state in parentheses. A missing tool or absent context marks a
row as `○ <label> (missing: …)` or `(unavailable: …)` and keeps its command:
tunnel actions need `wg-quick`, `wg`, and `sudo`, and on macOS also
`wireguard-go` beside `wg-quick` and `bash 4+`; privileged profile actions
need `sudo`; WireGuard details need `wg`; IP and exit info and the report need
`curl` and `jq`; the path MTU probe needs `ping`. Context marks name a default
or last-used profile that is not saved or not listed, an active tunnel when
none is up, profiles when the
directory is empty, missing, or unsafe, and backups when none exists. Unknown
state, such as locked profiles, marks nothing. Saved choices follow an em
dash: `Connect Default Profile — wg0`, `Disconnect wg0 — default, backup`. On
macOS an active profile names its device first: `Disconnect wg0 — utun5,
default`. The row's target is always the profile, never the device.

## Output presentation

Human output follows [`output-spec.md`](output-spec.md):

- **One heading per command.** `vpn-on`, `vpn-off`, `vpn-off-all`,
  `vpn-reconnect-last`, and `vpn-default-connect` show the resulting tunnel
  state under their own heading instead of a nested `VPN Details` heading.
- **Reports.** `vpn-details` and the tunnel commands print one `▸ <tunnel>`
  section per active tunnel with its bounded `wg show` output behind a `│`
  gutter; on macOS a `Device:` line names the tunnel's utun device first.
  `vpn-ip-info` prints a section per tunnel, then `Public exit` and
  `DNS resolvers`; the opt-in cross-check is a `Provider | IP | Result` table.
  `vpn-mtu-probe` prints its facts, an optional `Recommendations` section,
  and one verdict line.
  `vpn-summary` ends with a `Profile | State | Device | Backup | Notes` table
  and `vpn-config-dir` with `Profile | Backup | Pre-restore copy`; a column
  that would be empty in every row is omitted, and `Device` appears only when
  a device differs from its profile name. `vpn-report` keeps one heading and
  ends with the report's `File` and `View` lines.
- **Tunnel transitions.** After the `Privileged operation:` announcement,
  `wg-quick` runs as `$ sudo -n wg-quick up <profile>  (output shown on
  failure)`; on macOS the line shows the exact absolute interpreter and script,
  `$ sudo -n /opt/homebrew/bin/bash /opt/homebrew/bin/wg-quick up <profile>`.
  Its output is captured privately and only a failed transition replays its
  final lines; `ZDX_VERBOSE=1` streams it live.
- **Exact-target plans.** `vpn-off-all`, `vpn-profile-rename`,
  `vpn-profile-remove`, and `vpn-config-restore` print a numbered table of the
  tunnels or files they change (`vpn-off-all` adds a `Device` column on macOS),
  their disclosures, and then
  `Dry run: <count> planned; nothing was <verb>.` or one question. A decline
  prints `Cancelled: nothing was <verb>.` Results are one line per target,
  followed by a counted verdict. A partial `vpn-off-all` failure marks the
  timing line, and an interruption lists each remaining tunnel as `not run`.

## Ownership

The `vpn` suite owns the WireGuard lifecycle on the local host: profile files,
tunnel state, the default and last-used pointers, diagnostics, the WSL DNS
and IPv6 workarounds, and the macOS mapping between profiles and utun devices.

It does **not** own:

| Domain | Owner | How `vpn` relates to it |
| --- | --- | --- |
| Installing `wireguard-tools`, `curl`, `jq`, `fzf` | `zdx-doctor` | `vpn` reports a missing dependency with a safe next step and never installs it |
| Host packages and services | `sys` (`sys-menu`) | `vpn` never touches a package manager or unit file |

## Platform contract

Support is capability based, not a repository-wide claim. `_vpn_platform`
reads `uname -s` once per shell and reports `linux`, `wsl`, `darwin`, or
`other`; every platform branch is chosen at call time from that value, so
Linux and WSL never reach the macOS collectors and macOS never reaches the WSL
workarounds.

| Host | Profile directory | Tunnel runtime | Network collectors | Privileged tools |
| --- | --- | --- | --- | --- |
| Linux | `/etc/wireguard` | kernel WireGuard, device named after the profile | `ip`, `/etc/resolv.conf`, `resolvectl` | names resolved by sudo's `secure_path` |
| WSL | `/etc/wireguard` | as Linux, plus the WSL DNS hooks and IPv6 rewrite | as Linux | as Linux |
| macOS | selected, see below | Homebrew `wireguard-go` on a `utunN` device | `ifconfig`, `route`, `netstat`, `scutil` | absolute validated paths |
| Other | `VPN_CONFIG_DIR` required | as Linux, unverified | as Linux | as Linux |

### Linux and WSL

WSL is detected by one rule, `_vpn_is_wsl`: a Linux kernel with
`WSL_DISTRO_NAME` set or a Microsoft kernel in `/proc/version`. The platform
check, the IPv6 rewrite, the import's DNS-hardening offer, and the report all
use it through `_vpn_platform`, so a WSL session without `WSL_DISTRO_NAME`
(a service or `su` session) is still WSL, and the variable alone does not
make another kernel WSL.

The IPv6 compatibility rewrite exists because WSL's NAT networking cannot
carry IPv6. Under mirrored networking with an IPv6 default route, stripping
`AllowedIPs = ::/0` would send IPv6 outside the tunnel, so the rewrite applies
only when `wslinfo --networking-mode` reports `nat`, or when the host has no
IPv6 default route (`ip -6 route show default`, which also covers WSL builds
without `wslinfo`). `VPN_MENU_WSL_IPV6_FIX=1` forces it on Linux and WSL, and
`VPN_MENU_WSL_IPV6_FIX=0` disables it.

The DNS hooks pin `/etc/resolv.conf` with `chattr +i`. On a filesystem without
Linux file attributes, such as WSL1's, or without `chattr`, hardening warns
that the pin cannot hold; the hooks still rewrite the resolver on each
transition, and WSL may regenerate it while the tunnel is up.

### macOS

macOS is supported with Homebrew `wireguard-tools`, which installs
`wireguard-go`, and Homebrew `bash`.

- **Profile directory.** An explicit `VPN_CONFIG_DIR` always wins. Otherwise
  the suite uses `/private/etc/wireguard` when it exists; else
  `$(brew --prefix)/etc/wireguard` when it already holds `*.conf` profiles
  (`/opt/homebrew` on Apple silicon, `/usr/local` on Intel); else
  `/private/etc/wireguard`, which profile creation makes with
  `install -d -m 700 -o 0 -g 0`. A symbolic link in `VPN_CONFIG_DIR` is
  accepted only as a root-owned system alias inside a root-owned directory
  that group and other users cannot write, so `VPN_CONFIG_DIR=/etc/wireguard`
  resolves through `/etc -> private/etc`; the canonical path is used
  everywhere afterwards. The completion mirrors both rules.
- **Profiles and devices.** wg-quick runs one `wireguard-go` per tunnel on a
  `utunN` device and records it in `/var/run/wireguard/<profile>.name`
  (root, mode `0400`) beside the device's `<device>.sock`. wg-quick pairs the
  two by that record and by modification times less than two seconds apart.
  `wg show interfaces` lists devices without privileges, so the suite pairs
  by the times alone when the pairing is unambiguous, reads the record through
  `sudo -n head -c 32` only when it is not and a sudo timestamp is warm, and
  otherwise reports live state as `locked`. A recorded name must match
  `utun` plus up to four digits. A device without a record is reported as
  having no wg-quick profile and is never targeted. Active state, pointers,
  plans, and menu targets always use profile names; the device appears in
  labels, `Device:` lines, and the `Device` column. A disconnect freezes the
  device and the identity of its record before authentication and aborts when
  either changed afterwards.
- **Tools.** wg-quick on macOS needs Bash 4 or newer, and `/bin/bash` is 3.2.
  The suite resolves `wg-quick` from `PATH`, and the `bash` that runs it from
  `PATH`, beside `wg-quick`, or in Homebrew's prefix, choosing the first that
  reports major version 4 or newer. wg-quick prepends its own directory to
  `PATH`, so the `wg` and `wireguard-go` that root runs are the ones beside
  it. Each of these files, every link on its path, and every directory above
  them must be owned by root or the current user and not writable by other
  users; group write is accepted only for `wheel` and `admin`, because
  Homebrew makes its prefix directories writable by `admin`, whose members can
  already use sudo. Anything else is refused before the announcement.
- **Collectors.** Internal addresses come from `ifconfig <device>`
  (link-local IPv6 omitted), the effective route from `route -n get`, the
  report's tables from bounded `netstat -rn -f inet` and `-f inet6`, and the
  resolvers from `scutil --dns` (the default resolver #1, then every scoped
  resolver). Per-device `wg show` needs root, so details appear only with a
  warm timestamp or after the user unlocks access.
- **Not applicable.** The WSL DNS hardening and IPv6 rewrite never run on
  macOS; `vpn-on` refuses `VPN_MENU_WSL_IPV6_FIX=1` there instead of
  stripping IPv6 from a tunnel that carries it.

### Other hosts

Any other kernel is refused by `_vpn_require_platform` with the exact next
step, rather than emitting a cascade of missing-command and permission errors.
Setting `VPN_CONFIG_DIR` is the documented opt-in for such a host. It is read
as a deliberate decision by the user, and the profile workflows then proceed
with the Linux tools:

```console
$ vpn-summary            # on FreeBSD, with the default directory
✘ The VPN suite targets Linux, WSL, and macOS.
➜ Set VPN_CONFIG_DIR to the WireGuard directory for this host to continue.
  For example: VPN_CONFIG_DIR=/usr/local/etc/wireguard
```

Enabling that override on an unsupported host is recorded as a user decision in
[`security-assessment.md`](security-assessment.md): the suite validates the
directory but cannot vouch for the host's WireGuard integration.

## Architecture

```text
functions/vpn-menu.zsh          public loader, router, menu model, manager loop
  -> functions/vpn-common.zsh   logging, prompts, platform, privilege, access,
                                records, fzf, dispatch
    -> functions/vpn/vpn-state.zsh    validated cache/report dirs, snapshot
    -> functions/vpn/vpn-wsl.zsh      DNS leak hardening, IPv6 stripping
    -> functions/vpn/vpn-darwin.zsh   macOS tools, utun mapping, collectors
    -> functions/vpn/vpn-preview.zsh  precomputed preview panes
    -> functions/vpn/vpn-access.zsh   sudo authentication and access reporting
    -> functions/vpn/vpn-control.zsh  connect, disconnect, defaults
    -> functions/vpn/vpn-info.zsh     summary, details, IP info, report
    -> functions/vpn/vpn-mtu.zsh      path MTU probe and MTU advice
    -> functions/vpn/vpn-config.zsh   edit, restore, inspect
    -> functions/vpn/vpn-profile.zsh  create, import, rename, remove
```

Load order is explicit in the entrypoint: the state, WSL, and macOS
primitives load before the modules that consume them. The platform-dispatching
helpers in `vpn-common.zsh` call into `vpn-darwin.zsh` only after
`_vpn_platform_is darwin`.

The state snapshot that `vpn-info.zsh` and `vpn-config.zsh` consume lives in
`vpn-state.zsh`, not in the entrypoint, so no feature module depends on the
entrypoint and the modules can be sourced standalone.

## Public command surface

The surface is frozen by `test/fixtures/vpn-public-commands.tsv` and checked by
`test/vpn_contract.bats`, which proves that these five sets are identical:

1. non-sentinel command fields in the top-level menu;
2. dispatcher arms;
3. commands named by `vpn-menu --help`;
4. entries in `completions/_vpn-menu`;
5. rows in the contract fixture.

22 commands are frozen.

Only the `vpn-menu` entrypoint is registered as a lazy stub by the core runtime.
`vpn-menu <command> [arguments...]` therefore works from a cold shell, while
the individual public functions become callable once the suite has loaded.
Scripts should use the VPN entrypoint form.

### Access

| Command | Class | Behavior |
| --- | --- | --- |
| `vpn-access-unlock` | mutating | Authenticate once so later reads need no prompt |
| `vpn-access-lock` | mutating | Invalidate the current session's sudo timestamp; other sudo commands sharing it are affected too |
| `vpn-access-status` | read-only | Report platform, directory mode, access state, pointers |

### Connection control

| Command | Class | Behavior |
| --- | --- | --- |
| `vpn-on [PROFILE]` | mutating | Apply the WSL tweak when applicable, bring the tunnel up, record it as last used |
| `vpn-off [PROFILE]` | mutating | Bring one tunnel down; with no argument it picks among the active ones |
| `vpn-off-all [--dry-run] [--yes]` | destructive | Preview and bring every active interface down after one confirmation |
| `vpn-reconnect-last` | mutating | Bring the recorded profile down if up, then back up |
| `vpn-default-connect` | mutating | Bring the configured default up, or report it is already active |
| `vpn-default-set [PROFILE]` | mutating | Record one profile as the default |
| `vpn-default-clear` | mutating | Remove the default pointer after confirmation |

### Diagnostics

`vpn-summary`, `vpn-details`, `vpn-ip-info`,
`vpn-mtu-probe [--target HOST] [--profile NAME] [--json]`, and `vpn-report`.

The manager reloads its state before every menu pass, so it has no separate
refresh action. `vpn-summary` prints the same access, tunnel, and pointer state
on demand, together with the profile table.

### Path MTU probe

`vpn-mtu-probe` measures the largest IPv4 packet that reaches one target with
Don't Fragment set, which is the path MTU of the tunnel or of the network
underneath it. A path MTU below the egress interface MTU silently drops large
packets: TCP connects, then HTTPS stalls. The command is read-only and
unprivileged: it never calls `sudo`, never opens a profile file, and only
prints its recommendations.

- **Target.** `--target HOST`, else `VPN_MENU_MTU_TARGET`, else `1.1.1.1`. A
  target is a dotted-quad IPv4 literal without leading zeros or a DNS host
  name of letters, digits, and hyphens whose last label starts with a letter.
  Anything else, including option-like values, shell metacharacters, IPv6
  literals, and numeric forms such as `1.2.3` or `0x7f000001`, is refused with
  status `2` before any probe. The target reaches `ping` as one argument after
  `--`. A host name is resolved by the first probe; later probes and the route
  lookup use the address that probe printed.
- **Probes.** Linux and WSL require iputils `ping` and run
  `ping -4 -n -c 1 -W 1 -M do -s <payload> -- <target>`; `ping -V` must name
  iputils, so BusyBox and GNU inetutils `ping`, which cannot set Don't
  Fragment, are reported as unsupported before any probe. macOS runs BSD
  `ping -n -c 1 -t 1 -D -s <payload> -- <target>`. A 56-byte probe first
  proves the target answers at all. The search then tries the largest payload
  the egress interface can send (its MTU minus 28, at most 8972, or 1472 when
  the MTU is unknown), so a healthy path costs two probes, and otherwise
  bisects. When iputils reports the MTU it learned (`mtu=1392`), that value is
  tried next and confirmed by one byte more failing. Path MTU = payload + 28
  (the IPv4 and ICMP headers).
- **Lost replies.** A failure with explicit evidence, a local "message too
  long" or an ICMP "fragmentation needed" report, is final. A silent failure,
  no reply or the deadline, may be a lost reply, so it is retried once: at
  once when it would discard more than 32 payload sizes from the search, and
  otherwise before it decides the result; when the retry passes, the search
  resumes above it. The 56-byte probe is retried once too. Retries count
  toward the probe and time limits.
- **Bounds.** Every program runs through the core timeout service with a
  three-second deadline; no probe starts once it could end after 15 seconds
  of accounted program time, in which an impossible wall-clock reading, such
  as a WSL clock resynchronization, counts the whole deadline and kill grace;
  and no run sends more than 16 probes. A run stopped by a bound reports a
  lower bound (`at least …`), and so does a run whose egress MTU is unknown
  and whose 1472-byte probe passed; neither yields advice.
- **Route and tunnel.** The egress interface comes from `ip -4 route get` on
  Linux and WSL and `route -n get` on macOS, and its MTU from
  `ip -o link show dev` or `ifconfig`. The route goes through a tunnel when
  the egress interface is one of the devices `wg show interfaces` lists
  without privileges; the WireGuard tunnel reported is that device, else the
  named profile's device on Linux and WSL, else the first active device.
- **Advice.** Only an exact measurement yields advice. When the egress MTU
  exceeds the path MTU, WSL2 gets the session command
  `sudo ip link set dev eth0 mtu 1392` and the persistent `[boot]` line for
  `/etc/wsl.conf`, `command = /usr/sbin/ip link set dev eth0 mtu 1392`,
  followed by `wsl.exe --shutdown`; WSL1, which shares the Windows network
  stack, is pointed at the Windows adapter; Linux gets the session command
  and NetworkManager and systemd-networkd hints; macOS gets
  `sudo networksetup -setMTU <device> <mtu>`. When a profile is named or a
  tunnel is up, and the tunnel's MTU, when known, exceeds the path MTU minus
  80, the advice is `MTU = <path MTU − 80>` in the profile's `[Interface]`
  section: WireGuard adds 80 bytes over IPv6 endpoints and 60 over IPv4
  endpoints, and the IPv4-only value is named too. `--profile` labels this
  advice and, on Linux and WSL, selects that profile's active device; it
  never reads the profile file. When the
  route itself goes through the tunnel, the probe measured the inner path:
  the advice says to disconnect and probe the underlying network, and sizes
  the tunnel to the inner path when its MTU is larger.
- **JSON.** `--json` prints one compact object on stdout and nothing else,
  built with `jq`; the human report is omitted, while errors and the timing
  line stay on stderr. Its keys are `schema` (`zdx.vpn-mtu-probe.v1`),
  `applicable`, `supported`, `reachable`, `target`, `address`, `profile`,
  `platform`, `path_mtu`, `exact`, `egress_interface`, `egress_mtu`,
  `through_tunnel`, `tunnel_interface`, `tunnel_mtu`, `probes`, `duration_ms`,
  `recommendations` (strings), and `reason`; unknown values are `null`. Without
  `jq`, `--json` fails on stderr with status `1` and prints nothing.
- **Statuses.** `0` when a path MTU was measured, exactly or as a lower bound;
  `1` when the host is not Linux, WSL, or macOS (not applicable, with no
  heading), when `ping` is missing or unsupported, or when the target does not
  answer; `2` for invalid arguments; `130` or `143` when interrupted. JSON
  mode keeps the same statuses and still prints its object for `1`.

### Profile management

`vpn-profile-create [PROFILE]`, `vpn-profile-import [PATH]`,
`vpn-profile-rename [OLD] [NEW] [--dry-run] [--yes]`,
`vpn-config-edit [PROFILE]`, and `vpn-config-dir`.

### Destructive maintenance

`vpn-config-restore [PROFILE]` and `vpn-profile-remove [PROFILE]`. Both accept
`--dry-run` and `--yes`; `vpn-profile-remove` also accepts `--with-backup`.

`vpn-default-clear` accepts `--yes` because it removes a saved pointer, but it
is a single small reversible state change rather than a broad operation and
therefore has no `--dry-run`.

## Menu record format

The `dev` and `sys` suites use the canonical `label|command|description`. This
suite documents a **fourth field** because several actions target one specific
profile:

```text
label|command|description|target
```

`target` is empty for actions that pick their own target, and otherwise holds a
validated profile name, which is also the interface name on Linux and WSL. On
macOS it is never the `utunN` device. Only the label is shown
(`--with-nth=1`).

The profile is never encoded into the command token. Carrying the target as
its own opaque field lets the entrypoint revalidate it with
`_vpn_validate_iface_name` immediately before dispatch, which is the behavior
`menu-spec.md` asks for: a display row is never a trusted data store.

`_vpn_menu_entry` rejects a pipe, newline, carriage return, or NUL in any field
and rejects a target that is not a valid interface name, so a malformed record
can never be built.

### A state-independent command set

Live state changes labels, adds per-profile rows, and annotates context. It never
changes **which** commands exist: every command always has a row, so the public
surface stays testable on a host with no profiles, no `wg`, and no
non-interactive sudo access.
`test/vpn_contract.bats` asserts this by rendering the menu twice under two very
different mocked hosts and diffing the command sets.

The static order follows the workflow in `menu-spec.md`: read-only status and
diagnostics first, common connection actions next, profiles and profile
management after that, and planned maintenance last. Per-profile labels say
`Connect <name>` or `Disconnect <name>` so their action remains understandable
without relying on state color. The plain header reports the profile
directory, active tunnels, profile access, sudo, and the platform. Missing
command-specific tools mark only the affected rows; they never prevent the
rest of the menu opening.

## Privilege model

Least privilege is enforced by four primitives in `vpn-common.zsh`:

| Helper | Purpose |
| --- | --- |
| `_vpn_have_sudo_cache` | `sudo -n true`; probes cached or `NOPASSWD` non-interactive access without elevation |
| `_vpn_ensure_sudo_access` | The one interactive `sudo -v`, after the operation is announced |
| `_vpn_sudo_exec` | Runs one already-authorized narrow command with `sudo -n --` |
| `_vpn_sudo_probe` | Read-only privileged probe; failure is expected and silent |

Every mutation follows the same sequence:

1. **Announce** the exact privileged operation with `_vpn_announce_privileged`,
   before credentials are requested.
2. **Authenticate** once with `_vpn_ensure_sudo_access`.
3. **Revalidate the target**, because the plan was made before the prompt. A
   profile that disappeared, or a target that appeared, aborts the operation.
4. **Execute** each required narrow filesystem or WireGuard primitive through
   `_vpn_sudo_exec`, which cannot prompt. A transaction may need more than one
   primitive, but it does not regain interactive privilege between them.

Directly readable paths never escalate: listing profiles, checking backups, and
rendering previews record no `sudo` call at all. A protected profile's
metadata is read by one fixed program, `zsh -f -c <program> zdx-vpn-stat
<path>`, run by a root-owned zsh whose file and directories only root can
change. The path is a positional argument, never program text, and the record
uses the unprivileged fingerprint format, so a profile fingerprinted directly
and through sudo compares equal on every platform; no GNU `find -printf` or
`-perm /` remains. A host without a root-owned zsh (for example one whose only
zsh is a user-owned Homebrew build) cannot inspect protected profiles, which
are then treated as unavailable rather than run through a user-owned shell. Privileged installs use a numeric owner and group,
`install -m 600 -o 0 -g 0`, because macOS has no group named `root`.

On macOS the default sudoers keeps the caller's `PATH` instead of a
`secure_path`, so the fixed file primitives (`cat`, `cksum`, `find`, `head`,
`install`, `ln`, `mktemp`, `mv`, `rm`, `test`, `true`) run from their system
locations in `/bin` and `/usr/bin`, and any other bare name is refused before
sudo. Linux and WSL pass the names unchanged to sudo's `secure_path`. Access is direct only when the
directory and every profile in it are readable; a user-owned directory holding
root-owned mode-`600` profiles, as the suite's own installer creates, uses the
announced sudo path instead. An empty inventory read through sudo is a
successful empty result. A protected system directory
can be read only after the user explicitly unlocks access; previews themselves
never request credentials.

Tunnel transitions execute `wg-quick up|down` with the absolute validated
`VPN_CONFIG_DIR/<profile>.conf` path. On Linux and WSL the argv is
`sudo -n -- wg-quick up|down <profile>`; on macOS it is
`sudo -n -- <bash 4+> <wg-quick> up|down <profile>` with both paths absolute
and validated as described in the [platform contract](#macos), and the
announcement prints that exact argv. Both directions bind the directory and
profile fingerprints and revalidate them after authentication. Protected
profiles may require announced profile-access authentication before their
contents can be fingerprinted. Disconnecting an active interface without a
safe corresponding profile fails explicitly; it does not fall back to a
similarly named profile in `/etc/wireguard` or another directory.

Default connection and last-profile reconnection require a successful live
interface query before deciding whether a tunnel is inactive. When live state
requires privileges, they first use the existing access/authentication flow.
Unknown state
does not authorize a new connection. Within these tunnel-control paths,
interrupted operations, sudo authentication, and active-state queries preserve
`130` or `143`; interrupted
disconnect-all batches stop before later interfaces and report unattempted
targets. Ordinary per-interface failures still allow independent targets to
run and make the aggregate result nonzero.
Profile existence, metadata, and checksum inspection also retain interruption
statuses through the tunnel callers, including protected reads through sudo.
An interrupted profile check of a saved default or last-used pointer stops
before reconnecting; it never falls back to the unverified stored name. When
the profile directory is merely locked, `vpn-reconnect-last` uses the recorded
pointer, as `vpn-default-connect` does, and `vpn-on` then authenticates and
validates it. Picker cancellation is internal status `3`, distinct from an
interrupted authentication, so a bare `vpn-on` or menu selection preserves
`130` or `143`.

### The editor never runs as root

`vpn-config-edit` never runs `sudo $EDITOR`, which would turn a shell escape
such as `:!sh` in Vim into a root shell and subject `$EDITOR` to word
splitting.

It uses `sudoedit`, which copies the file, runs the editor **as the invoking
user**, and reinstalls the result as root with the correct mode. `sudoedit`
honors `SUDO_EDITOR`, then `VISUAL`, then `EDITOR` itself; the suite never passes
an editor name to `sudo`. If sudoers forbids `sudoedit`, the command reports the
failure and leaves the profile unchanged.

`sudoedit` refuses a file in a directory the invoking user can write, which is
the normal state of Homebrew's `etc/wireguard`. On macOS, a profile in a
directory the user owns is therefore edited without `sudoedit`: the editor,
chosen in the same order and split on whitespace as `sudoedit` splits it, runs
as the user on a private copy in a mode-700 staging directory. An unchanged
copy publishes nothing. A changed copy must still be a private, singly linked
regular file of at most 1 MiB, and the live profile must still match its
fingerprint from before editing; a profile the user owns is then replaced by
an atomic rename without any privilege, and a root-owned profile is read and
reinstalled through the announced `install -m 600 -o 0 -g 0` path. A failed
publication keeps the edited copy and names it. The editor needs a terminal.
Linux keeps `sudoedit` for every directory.

### Imported profiles cannot introduce root hooks

`wg-quick` executes `PreUp`, `PostUp`, `PreDown`, and `PostDown` as root. An
imported profile is therefore accepted only when it is a private, singly linked
regular file owned by the current user, at most 1 MiB, containing
`[Interface]` and `[Peer]`, and containing none of those lifecycle hooks.
Symlinks, hard links, public modes, oversized files, and hook-bearing profiles
are refused before sudo. A NUL or any control byte other than tab, line feed,
and carriage return is refused first: wg-quick's bash `read` silently drops
NUL bytes, so `Post<NUL>Up` would evade a text search and still run as
`PostUp`. A user can add a reviewed hook later through
`vpn-config-edit`; the suite never elevates unreviewed imported shell text.

Accepted content is copied into an owner-only staging directory, fingerprinted
before and after staging, and installed mode `600` through a same-directory
temporary. Existing profiles are never overwritten by import.

### WSL DNS hardening validates, never escapes

`_vpn_apply_wsl_dns_hooks`, offered after an import on WSL only, writes
`PostUp`/`PostDown` hooks containing an `sh -c` body that **root executes on
every tunnel transition**. The resolver
address in that body comes from the profile's `DNS =` line, which for an
imported profile is untrusted input.

The value is therefore validated by `_vpn_validate_dns_list` as a strict
comma-separated list of at most eight IPv4 or IPv6 literals. A value carrying
shell metacharacters is **refused, not escaped**:

```console
$ vpn-profile-import ./hostile.conf     # DNS = 1.1.1.1'; curl … | sh; '
✘ The profile's DNS value is not a plain list of IP addresses.
  Found: 1.1.1.1'; curl … | sh; '
➜ Refusing to write it into a root-executed hook. Fix the DNS line first.
```

Each configured fallback (`VPN_DNS_FALLBACK_PRIMARY`,
`VPN_DNS_FALLBACK_SECONDARY`) must be exactly one valid IP literal. Patching
builds an owner-only staged profile and asks `wg-quick strip` to parse that
staged file **before** an atomic same-directory replacement. Because wg-quick
re-executes itself through sudo for `strip`, that parse runs through
`_vpn_sudo_exec` after the announcement and authentication, never as an
unannounced escalation. Hardening refuses a symlinked `/etc/resolv.conf`
(WSL's generated default): `chattr` cannot pin a link and the hook would write
through it, so the user is told to set `generateResolvConf = false` and replace
the link first. A parse or
validation failure therefore leaves the live profile untouched. An existing
sentinel is idempotent only when the exact complete generated hook block follows
it; a partial or imitated sentinel is refused. The separate WSL IPv6
compatibility rewrite keeps a one-time `.bak-vpn-menu` safety copy, and a
connect fails before `wg-quick up` if the rewrite cannot retain the required
IPv4 values. If requested DNS hardening fails after a validated import, the
public command returns non-zero and reports that the imported profile remains
unchanged.

## Preview design

`menu-spec.md` forbids substituting a selected record into shell program text
and calling `sudo` from a preview. The VPN preview command therefore contains
no record field and only reads a precomputed pane.

Panes are rendered in Zsh by `vpn-preview.zsh` from the already-loaded state
snapshot, written to one file per row in a private mode-700 directory, and
addressed by fzf's **integer row index**:

```zsh
--preview="command cat -- ${(qq)_VPN_PREVIEW_DIR}/{n}"
```

The directory is single-quoted for the picker's `/bin/sh` preview executor,
including spaces, quotes, tabs, and newlines in an allowed temporary root.
This avoids Zsh-specific dollar quoting and keeps path text literal. The
executor is selected only for the picker; the caller's `SHELL` is unchanged.

`{n}` is generated by fzf, not taken from a record, so no untrusted value ever
reaches a shell program and no preview process needs privileges. Panes are
rendered with `${(V)}` escaping and never include `PrivateKey` or
`PresharedKey`. The `fzf` pipeline runs synchronously, which keeps it in the
terminal's foreground process group while it configures and reads the TTY.
Backgrounding that pipeline would stop `fzf` with `SIGTTOU` instead of opening
the menu. The directory is removed in an `always` block when the menu exits and
by local `INT`, `HUP`, and `TERM` handlers. The fzf result is captured in a
private bounded file, and a returned action must exactly match the current menu
snapshot before dispatch.

> `_vpn_preview_build` publishes its directory in `_VPN_PREVIEW_DIR` and
> deliberately prints nothing. A caller writing `dir=$(_vpn_preview_build …)`
> would run it in a subshell, leaving the parent's variable empty and the
> directory unreachable by cleanup. `test/vpn_interface.bats` guards against
> that leak.

## The manager loop

The VPN menu is a stateful manager, which `menu-spec.md` allows: connection
state changes as a direct result of the selected action. The loop reloads the
snapshot on every iteration, pauses after a mutation so its result stays visible,
and returns `0` on Esc. `vpn-config-edit` skips the pause because the editor
already leaves the screen in a readable state.
An action returning `130` or `143` exits the manager with that status, cleans
its private preview state, and does not pause or open another picker. Picker
cancellation still returns `0`, and ordinary action failures remain visible
before the manager refreshes.

## Persisted state

| Variable | Default | Contents |
| --- | --- | --- |
| `VPN_CONFIG_DIR` | `/etc/wireguard`; selected on macOS | WireGuard profiles (root-owned by default) |
| `VPN_CACHE_DIR` | `${XDG_CACHE_HOME:-~/.cache}/zdx/vpn` | Default and last-used pointers |
| `VPN_MENU_REPORT_DIR` | `~/vpn-stats` | Markdown diagnostic reports |

Both user-owned directories are validated on **every** use by
`_vpn_state_resolve` and `_vpn_state_prepare`:

- a path containing a `..` segment is refused;
- the filesystem root and the home directory itself are refused;
- the resolved path must live inside the user's home;
- a symlinked directory component below the home is refused, checked on the
  **unresolved** path so a link pointing elsewhere cannot be followed; the home
  itself may traverse a symlink (for example `/home -> var/home`), and the
  canonical path is used;
- directories are created mode `700` and files mode `600`.

Cache entry names are an internal allowlist (`last-iface`, `default-iface`),
never user input. Writes into invocation-created temporaries use `>|`, so a
user's `NO_CLOBBER` option cannot break them. A pointer to a profile that does not exist is *peeked* so the
menu can show and clear it, but `_vpn_read_cached_iface` refuses it, so a stale
pointer is never acted on.

A report contains the public exit IP, geolocation, endpoints, the hostname, and
resolver addresses. It never contains profile file contents. Cache entries and
reports are written to owner-only temporary files and published atomically;
same-second reports receive distinct no-clobber names rather than overwriting
one another. After each successful publication, the validated
`VPN_MENU_REPORT_RETENTION` bound (integer `0..1000`, default `20`, `0`
disables) keeps the newest reports, always protecting the one just published
and never deleting an entry that fails owner-only validation. Failed report generation removes its staged output and clears the
invocation-local target. Cache entries are capped at 128 bytes; preview panes
at 64 KiB; and a completed report at 1 MiB. External `wg`, routing, resolver,
and provider output is bounded before it reaches a report.

Ephemeral staging resolves an explicit `TMPDIR` through trusted aliases only,
such as macOS `/var/folders`, and accepts the canonical directory only when it
is writable and controlled by the current user, or is a root-owned sticky
directory. Without `TMPDIR`, the suite prefers a safe per-user runtime or cache
root and falls back to the user's home before considering `/tmp`; a
foreign-owned sticky `/tmp` is not trusted.

`VPN_CONFIG_DIR` has a separate system-profile policy: it must be absolute,
contain no `..` or control characters, name neither `/` nor the user's home,
and contain no symlink component other than a root-owned system alias inside a
root-owned directory that group and other users cannot write, such as macOS
`/etc`; the canonical path is used afterwards. An existing directory must be
owned by root or the current user and must not be group/world writable. A usable profile or
backup must be a private, singly linked regular file owned by root or the
current user and no larger than 1 MiB. Inventory commands omit unsafe entries
instead of displaying or acting on them.

## Exit statuses

| Status | Meaning |
| --- | --- |
| `0` | Success, deliberate cancellation, or a documented no-op |
| `1` | Operational failure, unmet precondition, or a refused unsafe request |
| `2` | Invalid arguments, unknown flag, or unknown dispatch token |
| `130`, `143` | Interrupted tunnel control, including its authentication or active-state query; no later batch mutation is attempted |

A declined confirmation and "no interface is active" are both `0`. "No terminal
available to confirm a mutation" is `1`, and so is a profile name or import
path that cannot be prompted for without a terminal. `_vpn_confirm` returns three distinct
statuses (`0` confirmed, `1` declined, `2` cannot prompt) so no caller can
conflate them: a scripted `vpn-off-all` without a terminal fails instead of
doing nothing and reporting success.

`--yes` bypasses only the prompt. It never widens the plan: `vpn-profile-remove
--yes` keeps the backup unless `--with-backup` is also given.

## Test coverage

| File | Covered boundary |
| --- | --- |
| `vpn.bats` | Shared helpers: resolv.conf preflight including symlink refusal, directory writability, name validation, cache pointers, WSL detection, and DNS hook idempotency |
| `vpn_contract.bats` | The frozen 22-command fixture, five-way parity including exact dispatcher arms, a host-independent command set, dispatcher coverage, cancellation, timing label, argument forwarding, invalid-argument statuses |
| `vpn_interface.bats` | Double sourcing, standalone sourcing without the core runtime, loader failure without a false sentinel, one derived module root, stream separation, `${(V)}` label escaping, `NO_COLOR`, four-field records, `fzf` options, foreground process-group ownership in a pseudo-terminal, the index-only preview, pane permissions and cleanup, selection and target revalidation, the second-iteration loop-local reprint regression, per-command `--help` and bad-option status, lazy/eager parity, the header context block, canonical unavailable marks, and em-dash profile notes |
| `vpn_privilege.bats` | DNS hook injection refusal, `sudoedit` instead of a root editor, target revalidation after authentication, the restore undo copy, least privilege on read paths, announcement ordering, destructive controls (`--dry-run`, declined, no-terminal, `--yes` scope), secret redaction in excerpts and panes, state permissions and traversal/symlink refusal, stale pointers, and the platform gate |
| `vpn_grammar.bats` | Exact completion grammar, parser-before-probe behavior, option terminators, operand cardinality, and safety-flag parity |
| `vpn_hardening.bats` | Profile-directory boundaries, unsafe profile and import sources, lifecycle-hook refusal, strict DNS literals, picker ambiguity, atomic cache and report publication, cleanup on failure, and no-privilege dry runs |
| `vpn_regressions.bats` | Provider URL and curl restrictions, exact WSL hook ownership, single-IP fallbacks, atomic IPv6 rewrite, fail-closed connect, stream isolation, sudo timestamp failure, cache/report bounds, signal-safe preview cleanup, NUL-hidden import hooks, the profile summary, `NO_CLOBBER` state writes, locked reconnect fallback, unreadable-profile access, empty privileged inventories, sudo-bound `wg-quick strip`, stdout-clean details and IPv6 rewrites, picker interruption status, whitespace-split secret redaction, aligned IP-info columns, terminal-less import failure, symlinked homes, and 15-character new profile names |
| `vpn_control_recovery.bats` | Exact profile paths for both transitions, post-authentication revalidation, missing profiles, interrupted batches with not-run tunnels, ordinary partial failures, tunnel-tool output replayed only on failure, and unknown live-state refusal |
| `vpn_probe_recovery.bats` | Preserved sudo, WireGuard, and protected-profile inspection interruptions, no fallback after interruption, bounded capture statuses, and warm-cache-only ordinary probe recovery |
| `vpn_menu_recovery.bats` | Action interruption without pause or rediscovery, private preview cleanup, ordinary failure recovery, picker cancellation, and literal POSIX preview paths with control characters or shell text |
| `vpn_state_recovery.bats` | Interrupted saved-profile validation without fallback or connection, ordinary stale-pointer behavior, missing-pointer no-ops, and a cache directory that does not exist yet |
| `vpn_darwin.bats` | The macOS directory policy and the root-owned system-alias rule; unambiguous, ambiguous, locked, stale, and unmanaged profile-to-device pairings; exact absolute Bash and `wg-quick` argv for connect, disconnect, and reconnect; device revalidation after authentication; the `vpn-off-all` Device column only when devices differ; summary, header, and menu rows with devices; details, IP info, and the report from `ifconfig`, `route`, `netstat`, and `scutil`; numeric owner and group for installs and directory creation; pinned system tools and refused bare names; the privileged metadata probe matching the unprivileged fingerprint on Darwin and Linux; the unprivileged edit path in a pseudo-terminal; the missing Bash 4 mark; the refused IPv6 tweak; and a group-writable tool directory refused before sudo |
| `vpn_wsl.bats` | IPv6 rewrite gating by `wslinfo` networking mode and IPv6 default route, the `0`/`1` overrides, plain Linux, one WSL detector shared by the platform, the IPv6 gate, and the report, a WSL variable on another kernel, the unsupported-pin warning for WSL1 and a missing `chattr`, and platform-specific DNS leak hints and WSL fix labels |
| `vpn_mtu.bats` | The path MTU probe: exact bisection boundaries (1392 behind a 1500-byte `eth0`, and others), the two-probe healthy path, the iputils MTU hint, retries of silent failures that keep a lost reply from lowering the result while explicit too-large evidence is never retried, one host-name resolution, a lower bound without an egress MTU, unreachable and unresolvable targets, BusyBox, option-rejecting, permission-denied, and missing `ping`, the not-applicable kernel, a hanging ping bounded by the probe deadline, the time budget, wall-clock jumps, and the probe cap, hostile and ambiguous targets refused before any probe, `VPN_MENU_MTU_TARGET`, argument statuses, WSL2, WSL1, Linux, and macOS advice including the exact `/etc/wsl.conf` line, BSD `ping` flags, WireGuard sizing for a named profile, a split tunnel, and a full tunnel, no `sudo`, the menu mark, and the JSON document, its failures, and missing `jq` |

`test/vpn_test_helper.bash` pins every VPN file to a kernel through a `uname`
mock (Linux unless a test chooses Darwin or FreeBSD), so the same assertions
hold on a Linux runner and on a macOS host; a WSL host is still detected as
WSL. Its macOS fixture provides a sandbox Homebrew prefix with a real Bash 4+
link and recording `wg-quick`, `wg`, `wireguard-go`, and `brew --prefix`
mocks; `ifconfig`, `route`, `netstat`, and `scutil` mocks; a private wg-quick
runtime directory with `.name` records and real Unix sockets at chosen times;
and a setup file that points the suite's private macOS locations at them.

`wg`, `wg-quick`, `wireguard-go`, `brew`, `bash` version probes, `sudo`,
`sudoedit`, `uname`, `grep`, `wslinfo`, `ip`, `ifconfig`, `route`, `netstat`,
`scutil`, `lsattr`, `chattr`, `ping`, and the network are all mocked. The `sudo` mock
is a deny-by-default recorder, so a test that asserts on `$MOCK_SUDO_LOG`
proves what the production code actually elevated; it allowlists the fixed
metadata probe by its `zdx-vpn-stat` name, never `zsh` in general. These
focused files cover the interface, privilege, recovery, hardening, and
platform contracts without changing host tunnels.

### What only mocks verify

In the BATS suite, the macOS branch, the WSL networking gate, and the WSL1
warning are verified with mocks only. In particular, no BATS test runs
wg-quick, `wireguard-go`, or sudo on a real Mac, even on the macOS runner: the
`.name` and socket timing rule, the root ownership of
the runtime record, unprivileged `wg show interfaces` listing utun devices,
the macOS sudoers `PATH` behavior, `/etc -> private/etc`, BSD `ifconfig`,
`route`, `netstat`, and `scutil` output, Homebrew ownership and modes, and
whether sudo's `use_pty` ends wg-quick's background route monitor are
modelled from upstream sources. `.github/scripts/vpn-smoke.zsh` is the
real-host acceptance check for a disposable Ubuntu or macOS CI runner with
passwordless sudo: it installs a private `zdxsmoke0` profile that routes only
`10.123.45.0/24` to the TEST-NET-1 endpoint `192.0.2.1:51820` and has no DNS
line, connects and disconnects it through `vpn-menu`, checks the device
listing, the profile-to-device pairing, the macOS `.name` record's root
ownership and mode `0400`, root-only `wg show <device>`, the route to
`10.123.45.1`, and an unchanged route to `1.1.1.1`, and always brings the
tunnel down and removes the profile. It refuses to run unless
`ZDX_VPN_SMOKE=1` and `CI=true`. The `vpn-smoke` workflow runs it on
`ubuntu-latest` and `macos-15` runners for pull requests to `main` that change
VPN files, and on manual dispatch.

## Residual gaps

1. **Real-host acceptance is limited to the smoke workflow.** The BATS suite
   runs on Ubuntu and on an Apple Silicon macOS runner, but its VPN files mock
   `wg`, `wg-quick`, `sudo`, and the networking tools. The `vpn-smoke` workflow
   brings one private tunnel up and down through the suite on Ubuntu and macOS
   runners with passwordless sudo. The WSL branches (`_vpn_is_wsl`, the
   networking-mode gate, resolver pinning, IPv6 stripping, the WSL1 warning),
   profile import and editing, and an interactive sudo are exercised with mocks
   only; a real WSL, WSL1, or interactive macOS verification has not been
   recorded.
2. **`sudoedit` availability is host policy.** If sudoers forbids it, editing is
   unavailable and the command says so. There is deliberately no fallback to
   `sudo $EDITOR`, because an editor running as root turns a shell escape into
   a root shell.
3. **Setting `VPN_CONFIG_DIR` on an unsupported host is a user decision.** The
   directory is validated, but the suite cannot vouch for that host's WireGuard
   integration, and `chattr`-based resolver pinning will not work there.
4. **`.conf.pre-restore` accumulates one file per profile.** It is the undo copy
   for the last restore and is overwritten on the next one, so it is bounded, but
   nothing removes it automatically. It does not appear in the profile list
   because listing matches `*.conf` only; `vpn-config-dir` reports each
   profile's undo copy so the retained state stays visible.
5. **Report retention runs only after a successful `vpn-report`.** Publication
   is private, atomic, and no-clobber, and a validated
   `VPN_MENU_REPORT_RETENTION` (default keep-newest 20; `0` disables) prunes
   older reports after each publication while always protecting the report just
   published and skipping any entry that fails owner-only validation. Reports
   left behind when retention is disabled, or when `vpn-report` is never run
   again, still require manual cleanup.
6. **Privileged tool lookup relies on the host's sudo policy on Linux.**
   `_vpn_sudo_exec` passes fixed command names and validated arguments to
   `sudo -n`; Linux and WSL deployments should retain sudo's normal trusted
   `secure_path`. A sudoers policy that preserves an attacker-controlled `PATH`
   is outside the suite's trust model there. macOS keeps the caller's `PATH`
   by default, so the suite pins its file primitives to `/bin` and `/usr/bin`
   and refuses other bare names.
7. **On macOS, root runs Homebrew files the user can change.** `wg-quick`,
   `wg`, `wireguard-go`, and Homebrew's Bash are owned by the user. The suite
   refuses them when any other account could change them, but any process
   running as the user can, and its code then runs as root on the next tunnel
   transition. A user-owned profile directory has the same property for
   `PostUp` hooks. This trust boundary is the user account; see
   [`security-assessment.md`](security-assessment.md).
8. **Profiles in a user-owned Linux directory still use `sudoedit`.** sudoedit
   refuses a directory the user can write; only macOS uses the private-copy
   edit path, so editing in such a Linux directory reports the `sudoedit`
   failure and changes nothing.
9. **The path MTU probe measures one IPv4 path with ICMP echo.** A target or
   network that filters ICMP reads as unreachable, and a path that drops ICMP
   "fragmentation needed" messages costs one second per oversized probe and
   its retries. A silent failure is retried once, so one lost reply cannot
   produce a smaller exact result; when the retries exhaust the 16-probe cap
   or the time budget, the result is reported as a lower bound (`exact`
   false) without advice, and a path that loses replies repeatedly can still
   measure low. IPv6 paths are not measured. The probe cannot see the underlying network
   through an active full tunnel, so it says so instead of sizing the tunnel
   from that path, and the WireGuard advice assumes the path to the target
   matches the path to the endpoint. Real `ping` behavior is verified on this
   project's WSL2 host only; BusyBox, BSD `ping`, and WSL1 are mocked.

## Maintenance triggers

Update this document when any of the following happens:

- a public command is added, renamed, or removed — also update the fixture;
- the record format, the target field, or the preview mechanism changes;
- a new privileged operation is introduced, or the four-step sequence changes;
- the WSL hardening validation rule changes;
- a persisted-state path, permission, or allowlist changes;
- the platform contract or `VPN_CONFIG_DIR` semantics change, including the
  macOS directory policy, tool resolution, or profile-to-device rule.
