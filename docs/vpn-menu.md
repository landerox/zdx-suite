# VPN suite contract

This document is the public contract for the `vpn` suite. It defines the frozen
command surface, the platform contract, the privilege model, the record format,
the preview design, and the persisted state layout.

The general engineering contract is in [`development.md`](development.md), the
interactive UI contract is in [`menu-spec.md`](menu-spec.md), and the file and
loader conventions are in [`headers.md`](headers.md). Where this document and
those disagree, they win.

Audit and migration baseline: 2026-07-26.

## Menu presentation

The manager retains its four-field records, state refresh, and larger private
status preview. Context and capability information precede
`Type to filter | Enter run | Esc cancel`. When preview generation succeeds,
`Ctrl-/ details` and its toggle binding are added together. If no preview is
available, neither the binding nor its legend is advertised. Ordinary profile
and interface pickers retain their compact layout and behavior.

## Ownership

The `vpn` suite owns the WireGuard lifecycle on the local host: profile files,
tunnel state, the default and last-used pointers, diagnostics, and the WSL DNS
and IPv6 workarounds.

It does **not** own:

| Domain | Owner | How `vpn` relates to it |
| --- | --- | --- |
| Installing `wireguard-tools`, `curl`, `jq`, `fzf` | `zdx-doctor` | `vpn` reports a missing dependency with a safe next step and never installs it |
| Host packages and services | `sys` (`sys-menu`) | `vpn` never touches a package manager or unit file |
| Network diagnostics beyond the tunnel | `net` (`net-menu`) | `vpn-ip-info` reports only the tunnel and its exit; general connectivity belongs to `net` |

## Platform contract

Support is capability based, not a repository-wide claim. This suite depends on
Linux conventions: a system profile directory, `iproute2`, `wg`/`wg-quick`, and
Linux file attributes for the WSL resolver pin.

- **Linux and WSL** are supported. `_vpn_platform` distinguishes them so the WSL
  workarounds apply only where they are needed.
- **Any other host** is refused by `_vpn_require_platform` with the exact next
  step, rather than emitting a cascade of missing-command and permission errors.
- Setting `VPN_CONFIG_DIR` is the documented opt-in for another host. It is read
  as a deliberate decision by the user, and the profile workflows then proceed:

```console
$ vpn-summary            # on macOS, with the default directory
✘ The VPN suite targets Linux and WSL.
➜ Set VPN_CONFIG_DIR to the WireGuard directory for this host to continue.
  For example: VPN_CONFIG_DIR=/opt/homebrew/etc/wireguard
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
    -> functions/vpn/vpn-preview.zsh  precomputed preview panes
    -> functions/vpn/vpn-access.zsh   sudo authentication and access reporting
    -> functions/vpn/vpn-control.zsh  connect, disconnect, defaults, refresh
    -> functions/vpn/vpn-info.zsh     summary, details, IP info, report
    -> functions/vpn/vpn-config.zsh   edit, restore, inspect
    -> functions/vpn/vpn-profile.zsh  create, import, rename, remove
    -> functions/vpn/vpn-compat.zsh   deprecated command names
```

Load order is explicit in the entrypoint. `vpn-compat.zsh` loads last because
every wrapper it defines forwards to a command declared by an earlier module.

The state snapshot previously lived in the entrypoint while `vpn-info.zsh` and
`vpn-config.zsh` called it, which inverted the dependency direction and broke a
standalone source of the modules. It now lives in `vpn-state.zsh`, so no feature
module depends on the entrypoint.

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
Workspace is a deliberate exception that registers its direct commands too.
Scripts should use the VPN entrypoint form.

### Access

| Command | Class | Behavior |
| --- | --- | --- |
| `vpn-access-unlock` | privileged | Authenticate once so later reads need no prompt |
| `vpn-access-lock` | privileged | Invalidate the current session's sudo timestamp; other sudo commands sharing it are affected too |
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

`vpn-refresh` (read-only state re-read), `vpn-summary`, `vpn-details`,
`vpn-ip-info`, and `vpn-report`.

`vpn-refresh` is a real command, not a menu-only pseudo-action, so the menu's
refresh row maps to a working direct call.

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
validated interface name. Only the label is shown (`--with-nth=1`).

The previous implementation encoded the profile into the command token itself
(`vpn-on:wg0`) and recovered it with string surgery in the dispatcher. Carrying
the target as its own opaque field is what lets the entrypoint revalidate it
with `_vpn_validate_iface_name` immediately before dispatch, which is the
behavior `menu-spec.md` asks for: a display row is never a trusted data store.

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
without relying on state color. The plain header reports platform, tunnel and
profile access, backup count, non-interactive sudo availability, default
profile, WSL handling, and the availability of tunnel and exit-lookup tools.
Missing command-specific tools annotate only affected rows; they never prevent
the rest of the menu opening.

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
rendering previews record no `sudo` call at all. A protected system directory
can be read only after the user explicitly unlocks access; previews themselves
never request credentials.

Tunnel transitions execute `wg-quick up|down` with the absolute validated
`VPN_CONFIG_DIR/<profile>.conf` path. Both directions bind the directory and
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
before reconnecting; it never falls back to the unverified stored name.

### The editor never runs as root

`vpn-config-edit` previously ran `sudo $EDITOR`, so a shell escape such as
`:!sh` in Vim yielded a root shell, and `$EDITOR` was subject to word splitting.

It now uses `sudoedit`, which copies the file, runs the editor **as the invoking
user**, and reinstalls the result as root with the correct mode. `sudoedit`
honors `SUDO_EDITOR`, then `VISUAL`, then `EDITOR` itself; the suite never passes
an editor name to `sudo`. If sudoers forbids `sudoedit`, the command reports the
failure and leaves the profile unchanged.

### Imported profiles cannot introduce root hooks

`wg-quick` executes `PreUp`, `PostUp`, `PreDown`, and `PostDown` as root. An
imported profile is therefore accepted only when it is a private, singly linked
regular file owned by the current user, at most 1 MiB, containing
`[Interface]` and `[Peer]`, and containing none of those lifecycle hooks.
Symlinks, hard links, public modes, oversized files, and hook-bearing profiles
are refused before sudo. A user can add a reviewed hook later through
`vpn-config-edit`; the suite never elevates unreviewed imported shell text.

Accepted content is copied into an owner-only staging directory, fingerprinted
before and after staging, and installed mode `600` through a same-directory
temporary. Existing profiles are never overwritten by import.

### WSL DNS hardening validates, never escapes

`_vpn_apply_wsl_dns_hooks` writes `PostUp`/`PostDown` hooks containing an
`sh -c` body that **root executes on every tunnel transition**. The resolver
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
staged file **before** an atomic same-directory replacement. A parse or
validation failure therefore leaves the live profile untouched. An existing
sentinel is idempotent only when the exact complete generated hook block follows
it; a partial or imitated sentinel is refused. The separate WSL IPv6
compatibility rewrite keeps a one-time `.bak-vpn-menu` safety copy, and a
connect fails before `wg-quick up` if the rewrite cannot retain the required
IPv4 values. If requested DNS hardening fails after a validated import, the
public command returns non-zero and reports that the imported profile remains
unchanged.

## Preview design

`fzf --preview` previously received a ~400-line POSIX script beginning with
`cmd={2}` and `desc={3}`, so fzf substituted the selected record into shell
program text, unquoted, and the script called `sudo -n` in six places. Both are
forbidden by `menu-spec.md`.

Panes are now rendered in Zsh by `vpn-preview.zsh` from the already-loaded state
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
> directory unreachable by cleanup — that leak was caught by
> `test/vpn_interface.bats` and is guarded by it.

## The manager loop

The VPN menu is a stateful manager, which `menu-spec.md` allows: connection
state changes as a direct result of the selected action. The loop reloads the
snapshot on every iteration, pauses after a mutation so its result stays visible,
and returns `0` on Esc. `vpn-refresh` and `vpn-config-edit` skip the pause
because they already leave the screen in a readable state.
An action returning `130` or `143` exits the manager with that status, cleans
its private preview state, and does not pause or open another picker. Picker
cancellation still returns `0`, and ordinary action failures remain visible
before the manager refreshes.

## Persisted state

| Variable | Default | Contents |
| --- | --- | --- |
| `VPN_CONFIG_DIR` | `/etc/wireguard` | WireGuard profiles (root-owned) |
| `VPN_CACHE_DIR` | `${XDG_CACHE_HOME:-~/.cache}/zdx/vpn` | Default and last-used pointers |
| `VPN_MENU_REPORT_DIR` | `~/vpn-stats` | Markdown diagnostic reports |

Both user-owned directories are validated on **every** use by
`_vpn_state_resolve` and `_vpn_state_prepare`:

- a path containing a `..` segment is refused;
- the filesystem root and the home directory itself are refused;
- the resolved path must live inside the user's home;
- a symlinked directory is refused, checked on the **unresolved** path so a link
  pointing elsewhere cannot be followed;
- directories are created mode `700` and files mode `600`.

Cache entry names are an internal allowlist (`last-iface`, `default-iface`),
never user input. A pointer to a profile that no longer exists is *peeked* so the
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

Ephemeral staging accepts an explicit `TMPDIR` only when it is writable,
non-symlinked, and controlled by the current user, or is a root-owned sticky
directory. Without `TMPDIR`, the suite prefers a safe per-user runtime or cache
root and falls back to the user's home before considering `/tmp`; a
foreign-owned sticky `/tmp` is not trusted.

`VPN_CONFIG_DIR` has a separate system-profile policy: it must be absolute,
contain no `..` or control characters, name neither `/` nor the user's home,
and contain no symlink component. An existing directory must be owned by root
or the current user and must not be group/world writable. A usable profile or
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
available to confirm a mutation" is `1`. `_vpn_confirm` returns three distinct
statuses (`0` confirmed, `1` declined, `2` cannot prompt) so no caller can
conflate them; the previous `read -q` implementation returned non-zero without a
terminal, which made a scripted `vpn-off-all` silently do nothing and report
success.

`--yes` bypasses only the prompt. It never widens the plan: `vpn-profile-remove
--yes` keeps the backup unless `--with-backup` is also given.

## Deprecated compatibility surface

Kept in `vpn-compat.zsh` as thin forwarders that emit one deprecation notice per
shell session, accepted as dispatcher tokens, and absent from the menu, help, and
completion. Scheduled for removal in **v0.3.0**.

| Deprecated | Canonical | Why |
| --- | --- | --- |
| `vpn-public-ip` | `vpn-ip-info` | Superseded by the richer view |
| `vpn-status` | `vpn-details` then `vpn-ip-info` | Was a two-command wrapper |
| `vpn-disconnect-active` | `vpn-off` | `vpn-off` with no argument already picks among the active tunnels, so this was a second implementation of the same action |

## Test coverage

| File | Covered boundary |
| --- | --- |
| `vpn.bats` | Shared helpers: resolv.conf preflight, directory writability, name validation, cache pointers, WSL detection, and DNS hook idempotency |
| `vpn_contract.bats` | The frozen 22-command fixture, five-way parity, a host-independent command set, dispatcher coverage, deprecated forwarding, cancellation, timing label, argument forwarding, invalid-argument statuses |
| `vpn_interface.bats` | Double sourcing, standalone sourcing without the core runtime, loader failure without a false sentinel, one derived module root, stream separation, `${(V)}` label escaping, `NO_COLOR`, four-field records, `fzf` options, foreground process-group ownership in a pseudo-terminal, the index-only preview, pane permissions and cleanup, selection and target revalidation, the second-iteration loop-local reprint regression, per-command `--help` and bad-option status, lazy/eager parity |
| `vpn_privilege.bats` | DNS hook injection refusal, `sudoedit` instead of a root editor, target revalidation after authentication, the restore undo copy, least privilege on read paths, announcement ordering, destructive controls (`--dry-run`, declined, no-terminal, `--yes` scope), secret redaction in excerpts and panes, state permissions and traversal/symlink refusal, stale pointers, and the platform gate |
| `vpn_grammar.bats` | Exact completion grammar, parser-before-probe behavior, option terminators, operand cardinality, and safety-flag parity |
| `vpn_hardening.bats` | Profile-directory boundaries, unsafe profile and import sources, lifecycle-hook refusal, strict DNS literals, picker ambiguity, atomic cache and report publication, cleanup on failure, and no-privilege dry runs |
| `vpn_regressions.bats` | Provider URL and curl restrictions, exact WSL hook ownership, single-IP fallbacks, atomic IPv6 rewrite, fail-closed connect, stream isolation, sudo timestamp failure, cache/report bounds, and signal-safe preview cleanup |
| `vpn_control_recovery.bats` | Exact profile paths for both transitions, post-authentication revalidation, missing profiles, interrupted batches, ordinary partial failures, and unknown live-state refusal |
| `vpn_probe_recovery.bats` | Preserved sudo, WireGuard, and protected-profile inspection interruptions, no fallback after interruption, bounded capture statuses, and warm-cache-only ordinary probe recovery |
| `vpn_menu_recovery.bats` | Action interruption without pause or rediscovery, private preview cleanup, ordinary failure recovery, picker cancellation, and literal POSIX preview paths with control characters or shell text |
| `vpn_state_recovery.bats` | Interrupted saved-profile validation without fallback or connection, ordinary stale-pointer behavior, and missing-pointer no-ops |

`wg`, `wg-quick`, `sudo`, `sudoedit`, `uname`, `grep`, and the network are all
mocked. The `sudo` mock is a deny-by-default recorder, so a test that asserts on
`$MOCK_SUDO_LOG` proves what the production code actually elevated.
These focused files cover the interface, privilege, recovery, and hardening
contracts without changing host tunnels.

## Residual gaps

1. **No real-host acceptance run is recorded.** CI is `ubuntu-latest` only. The
   WSL branches (`_vpn_is_wsl`, resolver pinning, IPv6 stripping) are exercised
   with mocks; a real WSL verification has not been recorded.
2. **`sudoedit` availability is host policy.** If sudoers forbids it, editing is
   unavailable and the command says so. There is deliberately no fallback to
   `sudo $EDITOR`, because that is the vulnerability being removed.
3. **Setting `VPN_CONFIG_DIR` on an unsupported host is a user decision.** The
   directory is validated, but the suite cannot vouch for that host's WireGuard
   integration, and `chattr`-based resolver pinning will not work there.
4. **`.conf.pre-restore` accumulates one file per profile.** It is the undo copy
   for the last restore and is overwritten on the next one, so it is bounded, but
   nothing removes it automatically. It does not appear in the profile list
   because listing matches `*.conf` only; `vpn-config-dir` now reports each
   profile's undo copy so the retained state stays visible.
5. **Report retention runs only after a successful `vpn-report`.** Publication
   is private, atomic, and no-clobber, and a validated
   `VPN_MENU_REPORT_RETENTION` (default keep-newest 20; `0` disables) prunes
   older reports after each publication while always protecting the report just
   published and skipping any entry that fails owner-only validation. Reports
   left behind when retention is disabled, or when `vpn-report` is never run
   again, still require manual cleanup.
6. **Privileged tool lookup relies on the host's sudo policy.** `_vpn_sudo_exec`
   passes fixed command names and validated arguments to `sudo -n`; deployments
   should retain sudo's normal trusted `secure_path`. A sudoers policy that
   preserves an attacker-controlled `PATH` is outside the suite's trust model.

## Maintenance triggers

Update this document when any of the following happens:

- a public command is added, renamed, or removed — also update the fixture;
- the record format, the target field, or the preview mechanism changes;
- a new privileged operation is introduced, or the four-step sequence changes;
- the WSL hardening validation rule changes;
- a persisted-state path, permission, or allowlist changes;
- the platform contract or `VPN_CONFIG_DIR` semantics change;
- the deprecated compatibility surface is reduced or removed.
