# ZDX — User & Workflows Guide

This guide provides practical workflows, usage instructions, and guides for the interactive suites in the ZDX ecosystem.

For reviewed local installation, custom Oh My Zsh paths, initial configuration,
and shell activation, follow the [installation contract](installation.md).

---

## ── General Menu Controls (FZF) ──

All interactive menus in ZDX are driven by `fzf`. The following default keybindings apply across all menus:

- **`Up / Down` (or `Ctrl-K / Ctrl-J`)**: Navigate through menu entries.
- **`Enter`**: Run the selected action or open a suite in ZDX.
- **`Esc` (or `Ctrl-C`)**: Close the menu and exit back to the shell cleanly.
- **Typing characters**: Filter visible entry text using fuzzy search.
- **`Ctrl-/`**, where advertised: Hide or show the selected entry's details.

Command menus share a compact list and a description below it. The preview
shows the direct command and its scope; section headings show their description
and perform no action. Hidden commands and descriptions are not search terms.
In the master `zdx` menu, route tokens such as `(dev)` and `(doctor)` appear in
the labels, so those abbreviations can be typed directly.

Context appears above the entries, in at most two lines. Menus whose actions
change a location first name it, such as `Project: zdx-suite` in `dev-menu` or
`Repository: zdx-suite` in `git-menu`; a second line lists facts that change
what the actions can do. Host-wide menus such as `sys-menu` show only that
facts line. An entry that cannot run yet stays listed with a `○` and names what
is missing, for example `○ Run Tests (missing: pytest in .venv)`; the command
itself explains how to provide it. Multi-selection is available only in menus
that advertise it: `Tab` marks entries, and `Ctrl-A` / `Ctrl-D` select all or
none where shown. VPN keeps its tunnel-state preview and refresh loop. File
pickers, logs, and live resource dashboards retain their own controls.

The design rationale and comparison are in [`menu-design.md`](menu-design.md).

### Terminal rendering and recovery

Menus use the terminal's native foreground and background with a 16-color
palette by default. Set `ZDX_FZF_THEME` only for an intentional custom theme.
Any nonempty `NO_COLOR` value forces fzf's `--no-color` as a final option,
including when a theme or a caller-supplied color option is present.

Borders, separators, scrollbars, and the match counter use pinned colors, so
they remain visible with older fzf releases such as Ubuntu 24.04's packaged
0.44.1. fzf 0.66 and newer also draw a thin `▌` gutter beside unselected rows;
older releases leave that column blank. For identical menus on every machine,
install the same current fzf release on each one; `fzf --version` shows which
release a shell uses.

If entries are difficult to see, try one invocation in plain mode:

```zsh
ZDX_FZF_PLAIN=1 file-menu
ZDX_FZF_PLAIN=1 zdx
```

Menu rows hide the `|` that separates their hidden fields when the installed
fzf supports field templates. ZDX asks fzf once per shell; set
`ZDX_FZF_TEMPLATES=0` to keep the plain field, or `1` to force the template
form, for example with an fzf wrapper that answers that probe incorrectly.

Any nonempty `ZDX_FZF_PLAIN` value enables `--no-color --no-unicode`, with `>`
as the pointer and `+` as the selection marker. This changes fzf's borders and
indicators; option text can still contain Unicode. An effective `C` or `POSIX`
locale also selects ASCII borders and indicators automatically. `TERM=dumb`
selects plain rendering, but interactive menus still require a terminal with
cursor control; plain mode cannot provide that capability.

Built-in suite, master, and plugin-manager pickers isolate inherited
`FZF_DEFAULT_OPTS`, `FZF_DEFAULT_OPTS_FILE`, and `FZF_DEFAULT_COMMAND` for each
invocation. Their previews use a scoped `SHELL=/bin/sh`. These settings do not
change your shell or its environment. Custom plugins must follow the plugin
template to obtain the same behavior.

Run `zdx doctor` to inspect display settings and the loaded doctor's source
path. After updating the installed copy, open a new terminal: loading guards
can retain old functions when you only source your shell configuration again.
Responsive previews require fzf 0.31 or newer. Native macOS Terminal.app and
iTerm2 light/dark appearance still need manual validation.

### Command output and verbosity

Long-running commands that run several steps, such as `update-system` and
`dev-update-all`, show a numbered plan, a `── [n/N] Step ──` banner and one
result line per step, a summary table, and a final verdict. Results use one
vocabulary: `updated` and `current` only when the command compared the state
before and after, `done` when a step succeeded without that evidence, plus
`delegated`, `planned`, `skipped`, `not run`, `failed`, `blocked`,
`interrupted`, and `timed out`.

Chatty tool output, such as `uv`, `git pull`, or `pre-commit`, is captured
privately: you see the command as `$ <command>  (output shown on failure)`,
and only a failure replays its final lines, with potential credentials
redacted. Package-manager transactions (APT, Homebrew, Snap) always stream
live. To watch every tool live, set `ZDX_VERBOSE=1` in
`~/.config/zdx/config.zsh` or pass an aggregate's `--verbose` flag for one run;
verbose output is not redacted.

Reports about several subjects, such as `vpn-ip-info`, print one `▸` section
per subject with labelled facts, and a diagnosis such as `sys-health` ends with
one verdict. Commands that change an exact set of files, such as
`vpn-profile-remove`, show a numbered plan of those files, one line per file,
and a counted verdict; `--dry-run` stops after the plan.

The final `<suite>:<command> completed in …` line appears once, for the
command you started. Commands it delegates to, and the steps inside an
aggregate, do not print their own timing lines; opt-in telemetry still records
each of them. Durations read `0.4s`, `24s`, `1m 18s`, or `1h 02m`.
See [`output-spec.md`](output-spec.md) for the full contract.

### Master catalog

| Group | Destinations |
| --- | --- |
| Projects | Workspaces, Git, Developer tools |
| Files and Environments | Files, Environment variables, Python |
| System and VPN | System, VPN |
| ZDX Tools | Status, Doctor, Plugins |

Use `zdx status` for a one-screen summary of where you are and
`zdx doctor` to inspect missing dependencies. Loaded custom plugins appear
in their own group and are available through `zdx <plugin>` and completion.
Selecting a suite runs it once and returns to the shell when it finishes.

### Command-line insert widgets

With the Oh My Zsh plugin loaded in an interactive shell, ZDX registers four
line-editor widgets that open a small fzf picker below the prompt and insert
the chosen value at the cursor. They never run anything: the value is quoted
for the shell, so a name containing spaces, quotes, or `$(...)` stays one
literal word, and you review the line before pressing `Enter`.

| Chord | Widget | Picks | Inserts |
| --- | --- | --- | --- |
| `Ctrl-X b` | `zdx-insert-branch` | Local branches (current one marked `*`), then remote-tracking branches, most recent first | The branch name, such as `main` or `origin/main` |
| `Ctrl-X p` | `zdx-insert-pr` | Open pull requests from `gh pr list` (up to 200, 15-second bound) | The pull-request number |
| `Ctrl-X o` | `zdx-insert-port` | Listening TCP sockets from `ss` on Linux (`lsof` when `ss` is absent) and `lsof` on macOS | `Enter` inserts the owning PID; `Ctrl-O` inserts the port |
| `Ctrl-X v` | `zdx-insert-venv` | `.venv` and `venv` environments in the current directory and its parents, then environments below `WORKON_HOME` | The environment path |

`Esc` closes the picker and leaves the command line untouched. A missing
tool, an unauthenticated `gh`, or an empty list shows one `zdx: …` line below
the prompt instead, such as `zdx: not inside a Git repository`. Without
privileges, a listener owned by another user shows `(process not visible)`;
use `Ctrl-O` to insert its port. The pickers use the same fzf isolation,
`NO_COLOR`, and `ZDX_FZF_PLAIN` behavior as the menus.

A chord is bound only when it is still unbound in your main keymap at plugin
load, so an existing user or Oh My Zsh binding always wins. Choose other
chords with `ZDX_KEY_INSERT_BRANCH`, `ZDX_KEY_INSERT_PR`, `ZDX_KEY_INSERT_PORT`,
and `ZDX_KEY_INSERT_VENV` in `~/.config/zdx/config.zsh`; an empty value leaves
that widget unbound, and you can bind any widget yourself, for example
`bindkey '^[b' zdx-insert-branch`. `ZDX_KEYBINDINGS=0` disables every ZDX
widget, including `Ctrl-G` for `git-menu`. The widget code loads on first
use, so it adds no work to shell startup beyond registering the names and
reading the current bindings once.

### Platforms

ZDX runs on Linux, WSL2, and macOS (Apple Silicon or Intel, with Homebrew
tools); the README lists the prerequisites for each platform. Each suite
section below names its platform differences, and
[`suites.md`](suites.md#platform-support) summarizes them. A command that
cannot apply on a host says so: System commands such as `update-apt` on macOS
report that they are not applicable, and menus mark rows whose tools are
missing. On WSL, keep repositories and projects in the Linux filesystem: on a
Windows drive below `/mnt` that WSL mounts without DrvFs metadata, File refuses
mutations, Python refuses projects, and Developer refuses to write its private
backups, reports, and update workspaces. `sys-wsl` shows whether
`/etc/wsl.conf` enables that metadata.

---

## ── VPN Suite (`vpn-menu`) ──

The VPN suite manages WireGuard tunnels and profiles on Linux, inside WSL, and
on macOS with Homebrew `wireguard-tools`.

Every action has a direct command, so the menu is only a discovery layer:

```sh
vpn-menu                               # interactive tunnel manager
vpn-menu vpn-on wg-office              # arguments are forwarded unchanged
vpn-menu vpn-off-all --dry-run         # exact multi-tunnel plan
vpn-menu vpn-off-all --yes             # non-interactive, explicit
vpn-menu vpn-profile-remove wg0 --dry-run
```

For the frozen command surface, the privilege model, and the persisted-state
rules, see [`vpn-menu.md`](vpn-menu.md).

> [!TIP]
> Only the `vpn-menu` entrypoint is registered at shell start. Once you have
> invoked it in a session — or with `ZDX_EAGER_LOAD=1` — every command is also
> callable on its own, for example `vpn-summary`. In scripts, prefer the
> `vpn-menu <command>` form: it works from a cold shell.

### 🌍 Supported Hosts

The suite supports **Linux, WSL, and macOS**:

- **Linux and WSL** use `/etc/wireguard`, `iproute2`, and `wg`/`wg-quick`; WSL
  adds the DNS hardening and IPv6 compatibility described below.
- **macOS** needs `brew install wireguard-tools bash`: wg-quick runs each
  tunnel through `wireguard-go` on a `utunN` device and needs Bash 4 or newer,
  while `/bin/bash` is 3.2. Without `VPN_CONFIG_DIR`, the suite uses
  `/private/etc/wireguard` when it exists, otherwise Homebrew's
  `etc/wireguard` if it already holds profiles, otherwise
  `/private/etc/wireguard`, created root-owned and private on first use. Menus
  and reports show each tunnel's device beside its profile, such as
  `Disconnect wg0 — utun5`; commands always take the profile name. A missing
  Bash 4 or `wireguard-go` marks the tunnel rows, for example
  `○ Connect Profile (missing: bash 4+)`. Root runs Homebrew's `wg-quick`,
  `wireguard-go`, and Bash, which your account owns; the suite refuses them
  when any other account could change them.

On any other host it stops with the exact next step instead of failing in
pieces:

```console
$ vpn-summary
✘ The VPN suite targets Linux, WSL, and macOS.
➜ Set VPN_CONFIG_DIR to the WireGuard directory for this host to continue.
  For example: VPN_CONFIG_DIR=/usr/local/etc/wireguard
```

Setting `VPN_CONFIG_DIR` is your explicit opt-in. The path is validated, but the
suite cannot vouch for that host's WireGuard integration, and the WSL resolver
pin will not work there. Use an absolute dedicated directory with no `..`
component and no symbolic link other than a root-owned system alias such as
macOS `/etc`; `/`, your home directory, foreign-owned directories, and
group/world-writable directories are refused.

### 🔒 Access & Permissions

Profiles normally live in a root-owned directory, so protected reads and tunnel
changes need `sudo`. A readable unprivileged `VPN_CONFIG_DIR` is inspected
without elevation.

- **Unlock (`vpn-access-unlock`)**: authenticate once so later reads need no
  prompt.
- **Lock (`vpn-access-lock`)**: request invalidation of the current session's
  sudo timestamp. This is not VPN-only: other commands sharing that timestamp
  may need to authenticate again. A `NOPASSWD` policy can keep non-interactive
  sudo available even after successful invalidation, which the command reports.
- **Status (`vpn-access-status`)**: see the platform, the directory mode, whether
  profiles and tunnel state are readable, and the saved pointers.

The suite elevates as little as possible. With a readable profile directory,
listing profiles and rendering previews request **no** privilege at all. Before
any mutation it prints the exact privileged operation, authenticates once, then
**revalidates the target** — a profile that disappeared while the prompt was open
aborts the operation instead of being acted on.

### 📥 Importing a Profile

```sh
vpn-profile-import ~/Downloads/office-vpn.conf
```

To start from scratch instead, `vpn-profile-create [profile]` writes a
skeleton profile with empty `[Interface]` and `[Peer]` sections as a root-owned
mode-600 file; it prompts for the name when you omit it and refuses an
existing profile. Fill it in with `vpn-config-edit`.

The source must be a regular, owner-only file owned by you, with a link count of
one, no symlink indirection, and a maximum size of 1 MiB. It must contain
`[Interface]` and `[Peer]`. `PreUp`, `PostUp`, `PreDown`, and `PostDown` are
refused because `wg-quick` would execute imported hook text as root, and so is
any NUL or control byte other than tab and line breaks. Add a
reviewed hook later with `vpn-config-edit` if needed.

After reviewing a trusted download, restrict it before import if necessary:

```sh
chmod 600 ~/Downloads/office-vpn.conf
```

You are asked for the profile name, and validated content is staged privately
then installed atomically as mode `600` owned by root. An existing profile is
never overwritten. Running `vpn-profile-import` with no path prompts for one;
without a terminal the import fails instead of reporting success. New and
renamed profile names use at most 15 characters, the `wg-quick` interface
limit.

### 💻 WSL DNS Hardening

Inside WSL, Windows routes DNS through a relay that ignores the tunnel resolver,
so DNS leaks unless `/etc/resolv.conf` is pinned. On import, the suite offers to
add `PostUp`/`PostDown` hooks that pin the resolver while the tunnel is up and
restore public fallbacks while it is down.

Hardening needs a regular `/etc/resolv.conf`. WSL generates a symbolic link by
default, which `chattr` cannot pin; set `generateResolvConf = false` under
`[network]` in `/etc/wsl.conf`, replace the link with a regular file, and retry.

> [!IMPORTANT]
> Those hooks are executed **by root on every tunnel transition**, so the
> profile's `DNS =` value must be a plain comma-separated list of IP addresses.
> Anything else is refused rather than escaped:
>
> ```console
> ✘ The profile's DNS value is not a plain list of IP addresses.
> ➜ Refusing to write it into a root-executed hook. Fix the DNS line first.
> ```

When the filesystem cannot hold the pin, as on WSL1, or `chattr` is missing,
hardening warns that WSL may regenerate the resolver while the tunnel is up.

Patching builds a private staged profile and asks `wg-quick` to parse it before
an atomic replacement, so a validation or parse failure leaves the live profile
untouched. Each configured fallback must be exactly one IP address. Idempotency
requires the exact sentinel plus its complete generated `PostUp`/`PostDown`
block; a partial or imitated sentinel is refused for manual review. The separate
WSL IPv6 compatibility rewrite applies only under WSL's NAT networking or
without an IPv6 default route, because mirrored networking carries IPv6, and it
keeps a one-time `.conf.bak-vpn-menu` safety copy.
If requested post-import DNS hardening fails, the command returns non-zero and
reports that the already validated profile remains imported unchanged.
If it cannot retain valid IPv4 `Address`, `DNS`, and `AllowedIPs` values,
`vpn-on` fails before starting the tunnel instead of continuing with a
partially compatible profile.

### ✏️ Editing a Profile

`vpn-config-edit [profile]` opens the file through **`sudoedit`**, which copies
it, runs your editor as your own user, and reinstalls the result as root. Your
editor never runs with root privileges, so a shell escape such as `:!sh` does
not give a root shell. `sudoedit` honors `SUDO_EDITOR`, then `VISUAL`, then
`EDITOR`.

If sudoers forbids `sudoedit`, the command says so and changes nothing. There is
deliberately no fallback to `sudo $EDITOR`.

On macOS, `sudoedit` refuses a directory you own, such as Homebrew's
`etc/wireguard`. There the editor runs as you on a private copy; nothing is
published when you make no change, and a changed copy replaces the profile
atomically only if the profile did not change meanwhile.

### 🔄 Connecting and Disconnecting

- `vpn-on [profile]` — bring a tunnel up and record it as last used.
- `vpn-off [profile]` — bring one down; with no argument it picks among the
  active tunnels.
- `vpn-default-set [profile]` / `vpn-default-connect` / `vpn-default-clear`.
- `vpn-reconnect-last` — bounce the profile you used last.
- `vpn-off-all [--dry-run] [--yes]` — preview or bring everything down after
  one confirmation.

Connecting and disconnecting use the exact profile file in `VPN_CONFIG_DIR`.
If a running interface has no safe matching profile there, disconnect reports
the missing target instead of choosing another directory. Default connection
and reconnection stop if live tunnel state cannot be read.

Each transition prints its privileged operation and then
`$ sudo -n wg-quick up <profile>  (output shown on failure)`: the `wg-quick`
output is kept private and shown only if the transition fails (set
`ZDX_VERBOSE=1` to watch it live). The resulting state follows as one
`▸ <tunnel>` section per active tunnel.

Interrupting a tunnel operation stops the remaining batch and exits the
interactive manager without another pause or picker; `vpn-off-all` lists the
tunnels it did not reach as `not run`. Ordinary failures in `vpn-off-all` are
reported while independent interfaces can still be processed, and the verdict
counts them.

In the menu, the header names the profile directory and then one line of
facts:

```text
Directory: /etc/wireguard
Active: none | Profiles: locked | Sudo: locked | Platform: wsl
```

The **Profiles** section lists each profile and Enter toggles it. Labels begin
with `Connect` or `Disconnect`, so their meaning does not depend on color, and
saved choices follow a dash, as in `Disconnect wg0 — default, backup`. An
action that cannot run yet is marked, for example
`○ Show WireGuard Details (missing: wg)` or
`○ Connect Default Profile (unavailable: default profile)`; diagnostics and
profile management that do not need the missing tool remain usable.

### 🩺 Diagnostics

- `vpn-summary` — access state, profiles, active tunnels, backups, and saved
  pointers. The menu re-reads this state before every pass, so it has no
  separate refresh action.
- `vpn-details` — detailed WireGuard state per active tunnel.
- `vpn-ip-info` — tunnel address, endpoint, handshake, transfer, public exit,
  geolocation, resolvers, and a DNS leak hint. Set `VPN_MENU_IP_CROSSCHECK=1` to
  compare the exit IP across providers. Without `curl` or `jq`, local tunnel
  findings remain available, the public-exit lookup is skipped, and the menu
  row names the missing tools.
- `vpn-mtu-probe` — measure the path MTU: the largest packet that reaches a
  target with Don't Fragment set. It reports the egress interface and its MTU,
  whether the route goes through a WireGuard tunnel, and the tunnel's MTU,
  then prints recommendations it never applies. It sends at most 16 pings,
  stops within 15 seconds, and never uses `sudo`. Linux and WSL need iputils
  `ping`; macOS uses its own `ping`.

  ```sh
  vpn-mtu-probe                          # probe 1.1.1.1, or VPN_MENU_MTU_TARGET
  vpn-mtu-probe --target one.one.one.one --profile wg0
  vpn-mtu-probe --json | jq .path_mtu    # one zdx.vpn-mtu-probe.v1 object
  ```

  When the egress interface MTU is larger than the path MTU, TCP connects but
  HTTPS stalls. On WSL2 the advice is the exact fix, here for a 1392-byte
  path: `sudo ip link set dev eth0 mtu 1392` for the session, and
  `command = /usr/sbin/ip link set dev eth0 mtu 1392` under `[boot]` in
  `/etc/wsl.conf`, followed by `wsl.exe --shutdown`, to keep it. Linux gets
  NetworkManager and systemd-networkd hints and macOS
  `networksetup -setMTU`. For WireGuard, set `MTU =` the path MTU minus 80
  (IPv6-safe; 60 is enough when every endpoint is IPv4) in the profile's
  `[Interface]` section; `--profile` names the profile in that advice. Run it
  with the tunnel down to size the tunnel: through an active full tunnel it
  measures the path inside the tunnel and says so. IPv4 targets only.
- `vpn-report` — atomically publish an owner-only Markdown report of the whole
  picture. Same-second runs receive distinct filenames. After each successful
  report, `VPN_MENU_REPORT_RETENTION` (default 20; `0` keeps everything)
  prunes the oldest reports while always keeping the one just written.
- `vpn-config-dir` — show a bounded inventory of safe private profiles,
  backup availability, and any retained `.conf.pre-restore` undo copies; it
  is not an unrestricted directory listing.

### 🗑️ Destructive Actions

Broad or destructive workflows compute the plan first, show it, and only then
ask:

```sh
vpn-off-all --dry-run             # show every tunnel that would go down
vpn-profile-rename wg0 office --dry-run
vpn-config-restore wg0 --dry-run   # show the plan and the backup excerpt
vpn-profile-remove wg0 --dry-run   # show exactly what would be deleted
vpn-profile-remove wg0 --yes       # skip the prompt, never the validation
```

- The plan is a numbered table of the exact tunnels or files. A dry run ends
  with `Dry run: 2 tunnels planned; nothing was disconnected.`, and after the
  run each target gets one result line and the verdict counts them.
- A declined confirmation changes nothing, says so, as in
  `Cancelled: nothing was removed.`, and returns `0`.
- Without a terminal and without `--yes`, the command **fails closed** with a
  non-zero status rather than silently doing nothing.
- `--yes` skips the prompt but never widens the plan: `vpn-profile-remove --yes`
  **keeps** the backup unless you also pass `--with-backup`.
- A restore keeps the previous profile as `<name>.conf.pre-restore`, so it can
  be undone.
- A rename follows the matching backup, default pointer, and last-used pointer;
  an active profile is included in the plan and disconnected first.

Secrets are never displayed: `PrivateKey` and `PresharedKey` are stripped from
every excerpt, preview pane, and report.

### ⚙️ Configuration

Set these in `~/.config/zdx/config.zsh`:

| Variable | Default | Effect |
| :--- | :--- | :--- |
| `VPN_CONFIG_DIR` | `/etc/wireguard`; selected on macOS | WireGuard profile directory; also the opt-in for other hosts |
| `VPN_CACHE_DIR` | `~/.cache/zdx/vpn` | Owner-only default and last-used pointers |
| `VPN_MENU_REPORT_DIR` | `~/vpn-stats` | Diagnostic report output |
| `VPN_MENU_REPORT_RETENTION` | `20` | Reports kept after a successful `vpn-report`; integer `0`–`1000`, `0` keeps all |
| `VPN_DNS_FALLBACK_PRIMARY` | `1.1.1.1` | Resolver pinned while the tunnel is down |
| `VPN_DNS_FALLBACK_SECONDARY` | `9.9.9.9` | Second resolver pinned while down |
| `VPN_MENU_WSL_IPV6_FIX` | unset | `1` forces the IPv6 tweak on Linux and WSL, `0` disables it; refused on macOS |
| `VPN_MENU_IP_CROSSCHECK` | unset | Set to `1` to cross-check the exit IP |
| `VPN_MENU_IPINFO_URLS` | built-in cascade | Comma-separated JSON IP providers |
| `VPN_MENU_IPINFO_PLAIN_URLS` | built-in cascade | Comma-separated plain-text IP providers |
| `VPN_MENU_IPINFO_TRACE_URLS` | built-in cascade | Comma-separated trace-format IP providers |
| `VPN_MENU_MTU_TARGET` | `1.1.1.1` | Default `vpn-mtu-probe` target: an IPv4 address or host name; anything else is refused |

The cache and report directories are created mode `700` with mode `600` files,
and are validated on every use: a `..` segment, a symlinked directory, or a path
outside your home is refused. Provider overrides accept bounded HTTPS URLs
only; invalid schemes, embedded credentials, whitespace, and option-like data
are ignored. Curl is restricted to HTTPS for both the initial request and
redirects, with response-size, connection-time, and total-time limits.

---

## ── Workspace Suite (`ws-menu`) ──

The Workspace suite manages the layout that keeps each repository below its
platform and identity:

```text
~/workspaces/<platform>/<identity>/<repository>
~/workspaces/github/personal/zdx-suite
~/workspaces/gitlab/work/billing-api
```

Set `WS_BASE_DIR` in `~/.config/zdx/config.zsh` to use another root, and
create the root yourself: ZDX never creates it. Run `ws-menu` (or `zdx ws`) to
choose an action, or call a command directly.

### 🧭 Jump to a Repository

- **Jump (`ws-jump [QUERY]`)**: Changes your current shell to a repository.
  Without a query it opens a picker whose details pane shows the branch, the
  number of uncommitted changes, and the last commit. A query that names one
  repository exactly, or matches one path with any letter case, jumps at once;
  `ws-jump zdx` opens the picker with only the matching repositories. Only
  directories that contain `.git` are listed, down to `WS_MAX_DEPTH` levels
  (3 by default); hidden directories, symbolic links, nested repositories,
  and `WS_EXCLUDE` subtrees are left out. `fd` makes discovery faster;
  without it, `find` produces the same list.

```sh
ws-jump                 # pick from every repository
ws-jump billing-api     # jump straight to one repository
```

`ws-jump` must run in your shell, as it does from `ws-menu`, `zdx ws`, or the
prompt; inside `$(…)` it cannot change your directory and says so. It
supersedes the private `zdir` and `wsj` prototype, which still loads only when
your ignored `functions/zdir.zsh` exists.

### 📥 Clone into the Layout

- **Clone (`ws-clone URL`)**: Clones a repository into
  `<platform>/<identity>/<repository>` after showing the exact plan.
  `github.com` and `gitlab.com` select their platform; other hosts are
  recognized from a `.ws-hostname` file in an existing workspace, or need
  `--platform`. The identity is the only existing workspace or
  `ZDX_GIT_IDENTITIES` profile for that host; with several, a terminal opens a
  picker, and `--identity NAME` chooses one directly. `--name DIR` renames the
  directory.
- **SSH aliases**: for an SSH URL such as `git@github.com:acme/app.git`, ZDX
  uses the workspace's host alias, `github-personal`, when your SSH
  configuration maps that alias to `github.com`, so the clone uses the
  workspace's key. HTTPS URLs are used as given.
- **Identity**: when `ZDX_GIT_IDENTITIES` has a profile with the identity's
  name, the Git suite applies it to the new repository with
  `git-menu git-identity-switcher --switch NAME local`.
- **Safety**: only `https://`, `ssh://`, and `user@host:path` URLs without
  credentials are accepted. An existing destination is never replaced. The
  clone runs in a private staging directory that is removed if Git fails, and
  is renamed into place only when it succeeds. `--dry-run` stops after the
  plan; without a terminal, `--yes` is required. On success the repository
  path is printed on stdout.

```sh
ws-clone git@github.com:acme/app.git --dry-run
cd "$(ws-clone https://gitlab.com/acme/tool.git --identity work --yes)"
```

### 📊 Workspace Status

- **Status (`ws-status`)**: One row per repository with its workspace,
  branch, uncommitted changes, ahead/behind counts from your local refs,
  stashes, and last commit. Repositories with changes, unpushed or unmerged
  commits, stashes, a detached `HEAD`, or an upstream branch that no longer
  exists come first, and a final line counts them.
- **Fetch first (`ws-status --fetch`)**: Runs `git fetch --prune` in every
  repository with a remote, at most `WS_FETCH_JOBS` (4) at a time and 60
  seconds each, after saying so. Fetches never prompt for credentials; load SSH
  keys that need a passphrase into your agent first. Without `--fetch`, the
  status uses no network.
- **For scripts (`ws-status --json`)**: one JSON document with the
  `zdx.ws-status.v1` schema on stdout; it never includes remote URLs.

```sh
ws-status
ws-status --fetch
ws-status --json | jq -r '.repositories[] | select(.attention) | .path'
```

The suite works on Linux, WSL, and macOS. On WSL, clone into the Linux
filesystem: a root on a Windows drive without DrvFs metadata is refused. See
[`ws-menu.md`](ws-menu.md) for the exact grammar, discovery rules, and JSON
fields.

---

## ── Git Suite (`git-menu`) ──

The Git suite helps you manage local changes, branches, repositories, pull requests, and Git identities.

### 👤 Identities & Routing

ZDX allows you to define multiple git profiles (e.g., Personal vs. Work) with different email addresses, GPG signing keys, and SSH keys.

- **Workspace layout**: Inside an existing
  `$WS_BASE_DIR/<platform>/<identity>/<repository>` layout (default
  `~/workspaces`), `git-auth` also shows the workspace, its SSH alias such as
  `github-personal`, and the fingerprint of its `.ssh/id_ed25519` key. The Git
  suite only reads this layout; the Workspace suite owns it and creates
  workspace directories only in a reviewed `ws-clone` plan. Git `includeIf`
  rules and SSH aliases you already have keep applying the matching identity.
- **Checking a workspace repository**: `git-identity-check` compares a
  repository below `$WS_BASE_DIR/<platform>/<identity>` with the profile named
  after its identity directory: the email, signing key, format, and commit
  signing, and the SSH key that `core.sshCommand` selects. A mismatch names
  each field and the fix, `git-identity-switcher --switch <identity> local`,
  and returns 1; it never prints keys or changes configuration. Elsewhere, or
  without such a profile, it reports not applicable. `--json` writes the
  result as data.
- **Opt-in warning on `cd`**: with `ZDX_GIT_IDENTITY_GUARD=1` in
  `~/.config/zdx/config.zsh`, the first `cd` into such a repository in each
  shell session runs that check quietly and prints one warning only when the
  identity differs. Outside the layout it costs well under a millisecond; the
  first visit of a repository runs a few Git processes. It never prompts or
  makes `cd` fail.
- **Local profiles stay isolated**: `git-identity-switcher --switch NAME local`
  writes `commit.gpgSign false` and `tag.gpgSign false` when the profile has no
  signing key, and removes another profile's SSH key from an inherited
  `core.sshCommand`, so a global profile cannot sign or authenticate commits in
  that repository.
- **SSH programs and agents are kept**: a profile adds its `SshKey` to the SSH
  command the scope already uses and replaces only that command's key
  selection, so WSL's `ssh.exe` and `ssh -o IdentityAgent=…` keep working. For
  `ssh.exe` the key path is converted with `wslpath -w`; if that fails, the
  profile is refused unchanged, and a Windows path such as
  `C:/Users/you/.ssh/id_ed25519` works directly. `git-pr-create` resolves SSH
  host aliases with the same SSH program Git uses.
- **Requirements and platforms**: the Git suite needs Git 2.31 or newer. On
  macOS, Apple's `/usr/bin/git` placeholder is reported with installation
  advice instead of being run. With `core.ignorecase` (macOS and Windows
  drives), plans refuse to overwrite an untracked file that differs only in
  letter case and refuse tags or branches that differ from an existing one
  only in letter case. A repository on a WSL Windows drive (`/mnt/c/…`) gets a
  one-line advisory about DrvFs speed and `core.autocrlf` line endings.

### 📝 Contributing to ZDX

These rules apply to changes to the ZDX repository itself, not to repositories
you manage with `git-menu`:

- **Developer Certificate of Origin (DCO)**: Every commit must be signed off.
  Always use the `-s` flag (e.g., `git commit -s -m "..."`).
- **Conventional Commits**: Commit messages are lowercase English with a valid
  scope: `git`, `vpn`, `sys`, `dev`, `py`, `file`, `env`, `ws`, `init`,
  `docs`, `repo`, or `deps`.
  Example: `feat(git): add branch cleanup`. The commit-message hook validates
  the format.
- **Merge flow**: `main` accepts changes only through pull requests, merged
  by squash with linear history, signed (verified) commits, and resolved
  conversations. The `lint`, `DCO`, `CodeQL`, and `bats (macOS)` checks must
  pass. See [`.github/CONTRIBUTING.md`](../.github/CONTRIBUTING.md).

### ⚡ Quick Reference of Git Commands

- `git-menu` — Open the interactive git menu.
- `git-auth` — Show active identity, remote alignment, and authentication
  status without displaying credentials or tokens.
- `git-status [--json]` — Show branch, upstream, changes, stashes, and any
  operation in progress; `--json` writes one `zdx.git-status.v1` document for
  scripts, with ahead and behind counts from local refs.
- `git-switch [BRANCH|-]` — Switch to a local branch, the previous branch, or
  a branch that exists only on a remote (its local tracking branch is created);
  without BRANCH, pick one. A clean tree switches at once. With uncommitted
  changes you review the plan and choose to carry them (`--carry`) or stash
  them first (`--stash`, saved as `zdx git-switch: <from> -> <to>`);
  `--dry-run` shows the plan.
- `git-recover [--deep]` — Pick a commit that no branch or tag reaches any
  more, such as one left behind by a reset, and restore it as a new
  `recover/<short-sha>` branch; `--deep` also finds dropped stashes. Nothing
  else is moved or deleted.
- `git-identity-check [--json|--quiet]` — Compare a workspace repository with
  its identity profile; see above.
- `git-unstage [--all]` — Remove chosen files, or every staged file, from the
  next commit; working-tree files never change.
- `git-stash` — Save current changes from the first row, or choose a stash to
  apply, pop, inspect, branch from, or drop; `Tab` marks several to drop.
  Direct: `git-stash save [-u] [-m TEXT]`, `git-stash apply|pop [TARGET]`
  (newest by default), `git-stash drop TARGET...`, and
  `git-stash branch TARGET NAME`.
- `git-amend -m "new subject"` — Change the last commit's subject and keep its
  body and `Signed-off-by`; without flags, choose Change Message, the editor,
  Add Staged Changes, or Reset Author.
- `git-discard [--all [--include-untracked]]` — Discard the unstaged changes of
  chosen files, or every uncommitted change with `--all`; untracked files are
  deleted only with `--include-untracked`, and ignored files never.
- `git-pull` — Choose pull with merge, rebase, or fast-forward, fetch the
  upstream branch, or fetch all branches and prune; each mode shows its plan
  before asking.
- `git-pr-checkout [NUMBER]` — Check out a pull request branch locally.
- `git-tag-create --name TAG [--target REV]` — Create one tag at a reviewed
  commit, `HEAD` by default, after showing the plan; choose `--annotated`,
  `--signed`, or `--lightweight`, add `--message TEXT`, and publish it right
  away with `--push [--remote NAME]`.
- `git-tag-verify [TAG]` — Verify an annotated or signed tag; without TAG,
  pick one.
- `git-tag-push [TAG ...]` — Publish local tags without overwriting remote
  tags; with no names, `--dry-run` or `--yes` covers every changed local tag.
  `git-push` publishes branches only.
- `git-tag-delete [TAG ...]` — Delete exact local tags after a frozen plan;
  `--delete-remote` (or `--remote NAME`) deletes the same tags on the remote
  first. With `--dry-run` or `--yes` and no names, every local tag is a target.
- `git-undo-commit [--soft|--mixed|--hard]` — Move the current branch back to
  its first parent after showing the exact commits and affected paths;
  without a flag, pick the mode. `--soft` keeps the index and working tree,
  `--mixed` keeps only working-tree changes, and `--hard` discards the listed
  changes.
- `clean-branches` — Preview and remove merged local branches while protecting
  the current and default branches.
- `clean-remote-merged` — Preview and remove merged remote branches with exact
  leases.

Interrupting a discard or a stash drop stops before the remaining targets,
keeps the interruption status, and lists the targets that were not run.

---

## ── System Suite (`sys-menu`) ──

The System suite centralizes capability-aware host diagnostics, updates,
cleanup, resource control, and local telemetry.
Run `sys-menu` for the interactive command menu or invoke any command directly:

```zsh
sys-menu sys-info
sys-menu sys-wsl
sys-menu update-system --dry-run
sys-menu sys-ports --list

# After sys-menu has loaded the suite, direct forms use the same contract.
sys-info
update-system --dry-run
sys-ports --list
```

Arguments after the command are forwarded unchanged. Help and human-readable UI
use stderr. The documented `--list` modes use stdout for TSV data, so they can
be composed safely in scripts. Unknown `sys-menu` options and command tokens
return status `2`. From a cold lazy-loaded shell, use
`sys-menu <command> [arguments...]`; direct System functions become available
after the suite loads or immediately with `ZDX_EAGER_LOAD=1`.

Set `NO_COLOR` to any non-empty value to disable ANSI colors in System UI, the
fzf picker, and core timing messages. System UI and timing messages also
suppress ANSI colors when stderr is not a terminal or `TERM=dumb`. See
[terminal rendering and recovery](#terminal-rendering-and-recovery) for fzf's
plain mode and terminal requirements.

The menu opens even when an optional capability is unavailable. Affected rows
are annotated with the missing dependency or backend, while unrelated actions
remain usable. Its plain header reports the detected OS, environment, package
backend, and service backend.

### 🔎 Portable Diagnostics

- **System Information (`sys-info`)**: Display OS, kernel, architecture,
  memory, swap, CPU, disks, uptime, local tool versions, and available package
  counts. Linux, WSL, and macOS use separate read-only collectors. On macOS the
  main disk is the Data volume (`/System/Volumes/Data`), because `/` is a
  sealed system snapshot, and available memory comes from the kernel's
  memory-status level. A tool version is shown only for the executable your
  `PATH` selects and ZDX may run: on WSL a Windows program from the appended
  Windows `PATH` (below `/mnt/<drive>/`) is skipped, on macOS the `git` and
  `python3` Command Line Tools placeholders are skipped until
  `xcode-select -p` reports an installed developer directory, and a
  world-writable executable is never run.
- **Health Check (`sys-health`)**: Inspect disk and inode pressure, memory and
  swap, zombie processes, service failures, and platform-specific health data.
  Unsupported checks are marked unavailable rather than treated as healthy,
  and checks that do not exist on the platform, such as the kernel OOM log on
  macOS, are marked `⊘` not applicable. On macOS a launchd job counts as
  failed only when it is not running and last exited with a positive status;
  jobs that last ended by a signal are listed as advisory, and Apple's
  `com.apple.*` jobs are skipped unless `SYS_HEALTH_INCLUDE_APPLE_JOBS=1`.
- **WSL Review (`sys-wsl`)**: On WSL, review `/etc/wsl.conf` and the
  Windows `%UserProfile%\.wslconfig` without changing anything: automount and
  DrvFs metadata, systemd and the `[boot]` command, a generated
  `resolv.conf`, interop and the appended Windows `PATH`, the default-route
  MTU and an MTU pinned by `[boot]` next to WireGuard or tun interfaces, the
  networking mode, and the manual steps that compact the distribution's
  `ext4.vhdx`, which ZDX never runs. Findings are factual advisories, such as
  a missing `metadata` option (File, Python, and Developer refuse projects on
  such drives), an MTU pin that is not in effect, MTU 1500 next to a tunnel,
  systemd that is off while services are enabled, or no `.wslconfig` memory
  limit; `appendWindowsPath` is shown as a setting only. Both files are parsed as data and never
  executed, and a value that looks like a credential is withheld. The Windows
  profile comes from bounded `wslvar` or `cmd.exe` and `wslpath` queries,
  which are skipped when interop is disabled. On other hosts the command
  reports that it does not apply.
- **Startup Analysis (`sys-startup`)**: Measure ten interactive Zsh startups
  with a timeout and run an isolated `zprof` report against `~/.zshrc`.
  This starts eleven isolated Zsh subprocesses in total. Startup files execute
  normally inside them and may still perform their usual external side effects.
- **Telemetry (`sys-telemetry --dashboard` / `--browse`)**: Inspect validated,
  bounded local telemetry without passing raw JSON to the terminal preview.
  Malformed records, implausible durations, and an incomplete final line are
  skipped.
  `sys-telemetry --clear --dry-run` previews the exact clear operation;
  `--yes` is required for non-interactive clearing.

For scripts, `sys-info --json` and `sys-wsl --json` print one JSON document
on stdout (`zdx.sys-info.v1` and `zdx.sys-wsl.v1`), with `null` for values
that are not available. They need `jq`, never prompt, and keep messages on
stderr; the text reports are unchanged:

```zsh
sys-info --json | jq '.memory.available_bytes'
sys-wsl --json | jq -r '.findings[].id'
```

To inspect or deduplicate `PATH`, use `env-path` from the Environment suite.

Diagnostic, discovery, and download probes have bounded deadlines. Where GNU
timeout is available, its process-group behavior and KILL grace period also
stop descendants. A transaction that has begun changing packages, caches,
services, processes, or repositories is not abandoned by a watchdog; it runs
to a reported result.

### ⚙️ Services, Processes, and Ports

The three resource browsers use typed records and revalidate live identity
after confirmation. Interactive hotkeys return an action to Zsh; they never
execute a destructive command inside `fzf`.

- **Processes (`sys-processes`)**: `--list` emits process, PID, UID, CPU,
  memory, and command fields as TSV, sorted by CPU usage on Linux and macOS.
  `--terminate PID` sends `SIGTERM`; `--force` explicitly selects `SIGKILL`.
  Protected PIDs are rejected.
- **Ports (`sys-ports`)**: `--list` emits protocol, port, address, PID, and
  command records from `ss` (preferred on Linux) or `lsof`. Use
  `--kill-port PORT` or an explicit `port:PORT` target; a bare number or a
  `pid:` target is rejected, because signaling a process by PID belongs to
  `sys-processes --terminate`.
  A port target must still have exactly one visible owner after confirmation.
  `lsof` without root cannot see sockets owned by other users, so only `ss`
  can refuse a port that has such a hidden owner.
- **Services (`sys-services`)**: `--list` emits systemd or launchd records.
  `--show ID` is read-only. Start, stop, restart, enable, and disable require an
  exact validated identifier and confirmation.

Examples:

```zsh
sys-processes --terminate 4242 --yes
sys-processes --terminate 4242 --force --yes
sys-ports --kill-port 3000 --protocol tcp --yes
sys-services --restart demo.service --yes
```

`--yes` bypasses only the prompt. The process fingerprint, port ownership, or
service state is still checked again immediately before the operation.
For a foreign process or systemd service, ZDX validates the target, runs
`sudo -v` to authenticate, validates again in case state changed while the
prompt was open, and invokes only the final `kill` or `systemctl` operation
with `sudo -n`. Launchd actions target the job in your `gui/<uid>` or
`user/<uid>` domain. On macOS, `--stop` runs `launchctl kill SIGTERM` for that
job: it stays loaded, so `--start` works again later, and launchd restarts it
when its own `KeepAlive` policy says so. ZDX never unloads a job with
`launchctl bootout`. macOS backend logic is covered by deterministic mocks, but
a real macOS host verification has not yet been recorded.

### 🔄 Updates

`update-system` displays only the steps applicable to the current host. It
is the maximum update command: by default it includes every applicable
installed updater, including mutable Git- and script-owned workflows. It
continues after an individual failure and returns non-zero with a summary when
a requested step remains incomplete. Package candidate lists are advisory
snapshots: each package manager refreshes metadata and resolves its final
dynamic transaction at execution.

```zsh
update-system --dry-run
update-system --yes
update-system --fail-fast --yes
update-system --safe-only --yes
update-system --include-remote-code --yes
update-system --include-phased-updates --yes
update-system --verbose --yes
update-apt --include-phased-updates --yes
update-apt --verbose --yes
```

Only one authorized mutating `update-system` execution can enter update steps
per effective user. Its displayed plan uses exactly the canonical-home path
`${HOME:A}/.zdx-update-system.lock`; `/run/user` and cache directories are not
fallback lock domains. The resolved home must be effective-user-owned,
non-group/world-writable, symlink-free, and searchable. After authorization and
before pre-authentication, the persistent mode-`0600` file is held through an
owner-bound descriptor with `zsystem flock -t 0`. A concurrent mutating
execution fails immediately as already running, starts no update step, and does
not wait or retry. The file is never unlinked and remains in place for safe
reuse after the descriptor is released. Dry-run does not acquire this execution
lock.

The aggregate dry-run performs non-mutating detailed previews for applicable
APT, Snap, and remote-code steps. One aggregate authorization covers the whole
plan: confirming it interactively grants the same per-step consent as `--yes`,
so an authorized run proceeds without further per-step consent prompts. The
displayed set of applicable entries is frozen: execution does not replan,
substitute, or insert steps after authorization. `--yes` authorizes those
entries and their documented dynamic scopes; it does not freeze package
candidates or bypass capability, dependency, owner, origin, or target
validation. By default each authorized entry is attempted once;
`--fail-fast` stops after the first failure. `--safe-only` excludes mutable
Git and script origins. `--include-remote-code` explicitly
affirms the maximum default. `--include-phased-updates` is separate and reaches
only APT. It is off by default, which preserves APT's normal phased rollout;
it does not disable phased updates. When explicitly present, the APT preview
and every APT mutation use
`-o APT::Get::Always-Include-Phased-Updates=true`.

The final report has separate `Core package steps` and `Optional tool steps`
lines. Core means APT, the applicable native package backend, Snap, and
Homebrew; every other authorized updater is optional. Each line counts
successes and failures against its applicable frozen plan, and also reports
`not run` when `--fail-fast` stops before later entries. A failed entry still
makes the command return non-zero. Continued mixed results are labeled
`completed with partial failures` in both the summary and timer while retaining
status `1`. If every applicable step fails, the command reports an ordinary
failure instead.

Each step shows one result line, such as
`✔ [4/11] fzf — current: 0.74.4 (b1be3a8) (3.0s)`. A step says `updated` only
when it compared the state before and after, for example two versions or two
commits; `current` means nothing changed, and `done` means the step succeeded
without such evidence. The closing `Update Summary` table repeats every
result with its time and detail, and the failed steps are followed by the
exact commands that retry them. When APT cannot refresh a repository, for
example because a host is unreachable, the run names the repository and the
problem and states that no package was upgraded.

When a repository's signing key expired or the publisher started signing with
a new key, ZDX renews it for these known repositories: GitHub CLI, Google
Cloud SDK, Charm, Docker, HashiCorp, Microsoft, NodeSource, and Google Chrome.
Before refreshing, it renews a dedicated keyring whose signing keys have all
expired; after APT reports `NO_PUBKEY` or `EXPKEYSIG`, it renews that
repository's keyring and refreshes once more. Each renewal shows the
repository, its source file, its keyring, the publisher's HTTPS key URL, the
current keys, and the key APT asked for, then downloads the key, checks that
it contains that key, and installs it with
`sudo -n /usr/bin/install -m 0644 -o 0 -g 0 <staged-key> <keyring>`. ZDX
keeps the new key only after APT verifies the repository with it, for
example:

```text
✔ Renewed the GitHub CLI signing key (7F38 BBB5 … 6231 3325)
✔ [1/11] APT — updated: 3 upgraded, 0 newly installed, 0 removed, GitHub CLI key renewed (41s)
```

If APT still rejects the repository, ZDX restores the previous keyring. The
`update-system` plan shows `key renewal for known repositories` in the APT
scope, standalone `update-apt` lists each expired keyring before you confirm,
and `--dry-run` names the keys a run would renew without downloading or
installing anything. Only a dedicated keyring is renewed: a source without
`signed-by`, a key embedded in a `.sources` file (such as a Launchpad PPA),
and every other repository are left unchanged. For those, ZDX says that the
problem is the repository's signing key rather than ZDX, names the source file
and the key ID APT wants, and shows the two ways forward: install the
publisher's current key into the named keyring, or disable the source. Set
`SYS_APT_KEY_RENEWAL=0` in `config.zsh` to keep only that guidance.

Git-owned fzf, Oh My Zsh, and custom Zsh plugin repositories are included
unless `--safe-only` is present.
The Git-owned repository paths display their origin and current commit,
require owned symlink-free checkouts below `HOME`, repeat identity and origin
checks after authorization, and use fast-forward-only pulls. The fzf installer
must match its tracked Git blob; Oh My Zsh does not execute
`tools/upgrade.sh`.

The aggregate authorization — interactive confirmation or `--yes` —
pre-authorizes these mutable origins, so use `--dry-run` first when their
current origins need review. `update-apt`, `update-snap`, `update-fzf`,
`update-omz`, and `update-zsh-plugins` provide their own review controls when
invoked directly. Other direct updater commands keep their command-specific
interface; do not assume the aggregate flags apply to every updater.
`update-system` itself emits no stdout data.

APT operation announcements are compact by default (`sudo -n apt-get update`,
`full-upgrade -y`, and `autoremove -y`). During an actual execution, add
`--verbose` to direct APT or the aggregate to show the complete fixed `env -i`
command and every APT policy argument; APT's own output is unchanged. A verbose
dry run remains a target review and does not print mutation commands that will
not execute. The aggregate forwards `--verbose` only to APT.

ZDX-owned orchestration avoids hidden prompts and open-ended APT waits, while
external package tools retain the transaction semantics described below.
Git-owned steps never prompt for credentials: terminal prompts and every
askpass helper, including a configured `core.askPass`, are disabled, SSH runs
in batch mode with a connect deadline unless you export your own
`GIT_SSH_COMMAND`, and Git aborts a transfer stalled below 1 KiB/s for 60
seconds. They pull only from the displayed `origin`; a branch that tracks
another remote fails instead of updating from it. The Homebrew metadata
refresh has a 120-second deadline and sets `HOMEBREW_CURL_RETRIES=0` for
curl-level retries. A Snap preview error or deadline is reported as a failed
step rather than "no pending updates". Every aggregate step reports its
elapsed time so a slow step is visible in the final summary.

When the confirmed plan contains privileged package steps, ZDX reuses a valid
non-interactive sudo timestamp or announces and runs one `sudo -v` right after
your authorization. While the initial consecutive privileged entries run, an
invocation-owned worker refreshes that timestamp with `sudo -n -v` and closed
stdin when it starts and then every 30 seconds. It cannot prompt. sudo keeps
its timestamp per terminal session by default, so the worker runs as a
background process substitution of your own shell: it shares your terminal and
session, which sudo requires, but never enters your job table, so it does not
produce `[n] ... terminated` or `done` notifications. If its first refresh
fails, for example because sudoers sets `timestamp_type=ppid`, ZDX warns that a
step outlasting sudo's timestamp timeout will fail rather than reprompt, and
stops the worker; a later failed refresh is reported when the worker stops.
ZDX sends the worker one stop request, confirms its exit after the last
privileged entry or through `always` cleanup on failure, return, or
interruption, and the worker never refreshes for a shell that has exited. Each
package or signal operation that requires sudo still uses
`sudo -n` when ZDX constructs it; the UI shows that exact prefix, or no prefix
for direct-root execution. Homebrew's internal sudo path is the exception
described below. A direct `update-apt` run authenticates once and then uses
`sudo -n` for every later privileged action. Its timestamp refresher uses only
`sudo -n -v`, is non-interactive, and uses the same acknowledged owned
`always` cleanup. Every aggregate step and privately captured command, plus
direct APT, Homebrew, native-package, and DNF-wrapper execution, receives
`/dev/null` as stdin, so an unseen prompt cannot consume terminal input or
block the aggregate.

When the installer was run from a local ZDX checkout, its Oh My Zsh entry is an
intentional `plugins/zdx-suite` symbolic link. If that link resolves to the
active ZDX source root, `update-zsh-plugins` reports it as a linked development
checkout and skips it without running Git or marking the update step failed.
Manage that checkout explicitly from its source directory. A normal cloned ZDX
installation is still updated with the other repositories. Any unknown plugin
link, including a `zdx-suite` link to a different checkout, remains a safety
error.

Immediately after aggregate authorization and its one applicable
pre-authentication, APT is the first update entry. Before any signal, ZDX
requires an empty dpkg journal and a clean bounded `dpkg --audit`. The audit
uses validated absolute, root-owned, non-group/world-writable `env` and `dpkg`
programs under a fixed `env -i`. A dirty or unverifiable state fails APT
immediately without signaling the current owner, which may be the process able
to complete that transaction. ZDX never starts an implicit repair.

APT planning does not use the generic package-manager process-busy detector as
a lock oracle. It looks only for the exact eligible unattended owner described
next; whether one is found or not, ZDX proceeds to the single native APT
attempt. APT's own zero-timeout lock acquisition is the only lock decision.

Only after that check passes, immediately before the single mutation sequence,
an automatic
`unattended-upgrade` may receive one cooperative `SIGTERM` only when its
root-owned pidfile, exact command, stable start identity,
`apt-daily.service` or `apt-daily-upgrade.service` cgroup, installed program,
kernel-reported `SigCgt` mask with the SIGTERM bit set, and minimal-step
configuration all pass the exact validator. A process argv containing the
`--no-minimal-upgrade-steps` opt-out, including accepted abbreviations, is not
eligible. ZDX checks that caught-signal bit
again during each fingerprint revalidation around pre-authentication and sends
the one request only through the validated root-owned `/usr/bin/kill` program
with `sudo -n`. A missing, malformed, or cleared bit prevents the signal.

The signal is version-gated as well. Trusted absolute `env`, `dpkg-query`, and
`dpkg` programs, fixed `env -i`/`PATH`, closed stdin, and bounded package-record
capture must prove that `unattended-upgrades` is installed. Debian package
versions before 0.94, or any missing or ambiguous version result, are never
signaled. ZDX validates and strips a leading numeric Debian epoch before the
0.94/0.95 comparison. On the normalized 0.94 line, `MinimalSteps` uses OR with
a false default, so at least one of the two supported spellings must be
explicitly true. Starting with 0.95 it uses AND with a true default: both
effective values must be true, and an absent key defaults to true. ZDX repeats
the version and configuration checks directly before the signal. These cutoffs
correspond to upstream commits `5f013f8`
(TERM support in 0.94) and `16fb837` (the true default in 0.95).

Every other APT owner, including `apt`, `apt-get`, `dpkg`, and a manually
launched updater, is never signaled. No independent update entry runs between
the optional signal and the single APT mutation sequence; there is no polling,
sleep, deferred retry, or second APT entry. The only repeated APT call is the
single index refresh that verifies a renewed signing key. Every `apt-get` invocation within
`update-apt` sets `DPkg::Lock::Timeout=0`, `Acquire::Retries=0`,
`Dpkg::Use-Pty=0`, `Dpkg::Options::=--force-confdef`, and
`Dpkg::Options::=--force-confold`. Its simulation, index update, full upgrade,
and autoremove run through a validated, root-owned absolute `env -i` with only
nonexistent HOME/XDG roots, `LC_ALL=C`, a fixed system `PATH`, `TERM=dumb`,
`DEBIAN_FRONTEND=noninteractive`, and `APT_LISTCHANGES_FRONTEND=none`; all
receive closed stdin. Caller and post-sudo environment state, including
`APT_CONFIG`, proxy variables, and exported shell functions, does not reach
APT. Put any required proxy in root-owned APT configuration instead. These
controls prevent hidden terminal, debconf, apt-listchanges, and
configuration-file prompts: dpkg applies its defined default and otherwise
keeps the installed configuration. Observing a generic process owner cannot
gate the attempt; if APT's native acquisition finds a lock after the signal,
that attempt fails immediately. No post-signal process-name scan gates
execution. Without `--fail-fast`, the aggregate records that partial failure and
proceeds through the subsequent authorized entries; with `--fail-fast`, it
stops at APT. ZDX does not stop or disable APT timers, delete lock files, or
time out an already-started package transaction. Set
`SYS_APT_AUTOMATIC_TAKEOVER=0` to disable the signal; it does not enable
waiting. The default is `1`, and any other value is rejected.

If APT cannot calculate its advisory preview, it reports candidates as
unavailable. An authorized update can still refresh indexes before resolving
the package transaction; `--dry-run` reports failure without mutation. Index
refresh uses `--error-on=any`, so a failed repository download stops the APT
entry before full-upgrade or autoremove and still receives the final dpkg
audit. Older APT versions lacking this flag fail visibly instead of silently
ignoring index errors.

After the mutation sequence finishes—even when a failed mutation causes its
remaining phases to be skipped—ZDX repeats the trusted dpkg journal and bounded
`dpkg --audit` validation. A failed post-transaction audit is visible, returns
non-zero, prevents the success message, and suppresses reboot-marker
inspection. When the post-audit is clean, reboot status is inspected even if a
package mutation failed: a safe root-owned `/run/reboot-required` marker
produces a reboot-required advisory, while an unsafe marker is reported as
unknown status. ZDX does not reboot, and the advisory does not alter the
transaction's success or failure.

System detects DNF4 or DNF5 from a bounded version record. The version probe
and DNF5 configuration probe run through a trusted absolute, root-owned
`env -i` executable with `HOME` and the XDG roots set to `/nonexistent`,
`LC_ALL=C`, a fixed system `PATH`, `TERM=dumb`,
`DNF5_FORCE_INTERACTIVE=0`, and `PYTHONNOUSERSITE=1`. They do not inherit
`DNF5_PLUGINS_DIR`, loader or Python variables, or user configuration roots.

Both DNF5 mutation paths run through the same privileged trusted-Zsh wrapper.
After the resolved privilege prefix, a trusted absolute `env -i` installs only
the fixed system environment and starts Zsh. The wrapper's positional argv
contains only its mode, lock path, optional frozen persist directory, and
validated absolute DNF and `env` programs—never secrets. No inherited variable
reaches the wrapper; the remaining startup-file trust boundary is root-owned
`/etc/zshenv`. Inside, the wrapper revalidates both programs and uses a second
trusted `env -i` to start DNF with the same fixed environment. No caller or
post-sudo variable survives, including proxies and exported shell functions.
If DNF requires a proxy, put it in root-owned DNF configuration; caller
environment variables are deliberately ignored.

DNF4 preview and mutation use `--setopt=exit_on_lock=True` and
`--setopt=retries=1`: a held lock fails, while the minimum finite network
setting allows one retry, for up to two attempts. ZDX never sets DNF4 retries
to zero, because DNF4 defines zero as unlimited.

DNF5 candidate preview is intentionally omitted because lock-capable versions
can wait on the system-repository lock. ZDX uses a bounded main-configuration
probe only for the 5.2-and-newer paths that require it:

- The DNF5 5.0/5.1 compatibility path deliberately does not depend on
  `--dump-main-config`, including on 5.1 builds that provide it. Those versions
  predate the system-repository wait lock. ZDX skips the configuration probe
  and uses sanitized wrapper mode `0` without a persist-directory override. Its trusted `env -i` child
  runs `dnf --installroot=/ --assumeyes --refresh upgrade`. The transaction
  lock is non-blocking.
- DNF5 5.2 and 5.3 must return exactly one `installroot=/` and one normalized
  absolute `persistdir`, with no `skip_system_repo_lock` capability. Wrapper
  mode `0` uses the trusted `env -i` child to invoke
  `dnf --installroot=/ --setopt=persistdir=<frozen-absolute-path> --assumeyes --refresh upgrade`.
  These versions have no system-repository wait lock, and the transaction lock
  remains non-blocking.
- DNF5 5.4 or newer must also expose exactly one valid boolean
  `skip_system_repo_lock` capability or the update fails before mutation.

For DNF5 5.4 or newer, wrapper mode `1` revalidates the paths and absolute DNF5
program, then attempts the same whole-file `fcntl` write lock with
`zsystem flock -t 0`. A busy lock fails immediately before DNF5 starts. The
held-lock command is
`dnf --installroot=/ --setopt=persistdir=<frozen-absolute-path> --setopt=skip_system_repo_lock=True --assumeyes --refresh upgrade`. That specific option skips only the
system-repository lock already held by the guard; DNF5's separate transaction
lock remains active. The UI displays the exact resolved privilege prefix and
guard without environment values. An active mutation is not killed. DNF5 does not
expose an effective supported network-retry disable setting: its `retries`
setting is deprecated and has no effect. Its upstream network retries
therefore remain a residual.

Other suite-owned update clients use zero only where their public setting
defines it as disabled: `UV_HTTP_RETRIES=0` for uv, `PIP_RETRIES=0` and
`PIP_NO_INPUT=1` for pipx/pip, `CARGO_NET_RETRY=0` for Cargo, and
`RUSTUP_MAX_RETRIES=0` for rustup. These settings prevent the supported
client-level retries and pip input prompts; an active package mutation still
runs to its reported result. Cargo can still wait for its package-cache lock,
for which it has no supported zero-wait switch.

APK mutations use `apk --wait 0 update` followed by
`apk --wait 0 upgrade`, so they do not request a database-lock wait. Pacman has
no supported zero switch for trying configured mirrors or retrying package
downloads; its active `pacman -Syu --noconfirm` transaction retains those
upstream semantics. Direct native-package commands and both the outer DNF5
wrapper and its inner DNF child receive closed stdin.

Zypper's `--non-interactive` mode prevents prompts, but its upstream
soft-media policy can retry up to three times with 30-second sleeps and has no
supported override. ZDX warns when it selects this backend. A started
`zypper refresh` or `zypper update` mutation has no general watchdog.

Homebrew decides its own resource locks. ZDX does not infer a lock from process
arguments containing `brew` or `Linuxbrew`, does not display those arguments,
and disables Homebrew analytics for suite-owned calls during the run. It
resolves `brew` to an absolute executable once, exports its retry, analytics,
Darwin askpass, and no-auto-update controls locally, and invokes that executable
directly rather than through `env`. A caller-defined `env` function therefore
cannot intercept the timeout fallback or remove those controls. Every
`update-brew` phase sets `HOMEBREW_CURL_RETRIES=0`, which disables only
curl-level retries, receives closed stdin, and its metadata refresh uses the
120-second outer deadline described above. Every ZDX Homebrew call also sets
`HOMEBREW_NO_ENV_HINTS=1`, so Homebrew does not print its
`Hide these hints with HOMEBREW_NO_ENV_HINTS=1` advice; its normal output stays
visible. Homebrew 6 still has internal
`DownloadQueue` retry behavior
and download-lock waiting with no public option to disable them. Mutating
Homebrew phases may therefore exercise those external waits or retries and are
not killed after mutation starts. On macOS only, every phase receives a fixed
askpass program that always fails: `SUDO_ASKPASS=/usr/bin/false` when that
file is root-owned, singly linked, and not writable by other users, or else a
private script containing only `exit 1` that ZDX creates in your validated
temporary directory and removes after the run. Homebrew may call its own
`sudo -A` for a cask; if the shared timestamp is unavailable, that askpass
guard fails instead of prompting. Without either program, ZDX refuses the
Homebrew run. Linuxbrew does not receive the guard.
The corresponding pre-authentication guidance is shown only for a Darwin plan
that includes Homebrew, never on Linux. On macOS, Homebrew is adjacent to the
native privileged package step and
remains inside the aggregate's sudo refresher scope for casks. The authorized
upgrade is always `brew upgrade --no-ask`: current Homebrew ask mode can
otherwise skip the mutation without a TTY and still return success. If
Homebrew itself returns an error, later update steps still continue and the
final summary identifies Homebrew.

The package-update no-wait/no-retry guarantee covers lock or acquisition waits
and retries constructed by ZDX plus the supported backend controls described
above. It is not a universal guarantee over undocumented or non-configurable
behavior inside Homebrew, Zypper, DNF, Pacman, or Cargo, and ZDX does not kill
an active package mutation to simulate one.

Update and cleanup failures show only a bounded tail of captured output from a
private temporary directory. Terminal control characters are escaped, and
lines containing common credential indicators are replaced with a redaction
notice. The configurable `SYS_COMMAND_CAPTURE_MAX_BYTES` limit defaults to
256 KiB and accepts values from 4 KiB through 16 MiB. Captured commands always
receive closed stdin.

`update-awscli` updates only an existing package-manager-owned installation.
It refuses automatic use of the upstream bundle when artifact identity cannot
be established and prints the official signature-verification path instead.
`update-starship` similarly updates only a Homebrew- or Cargo-owned binary and
refuses an unknown installation owner.

The aggregate avoids updating one installation twice. Homebrew-owned AWS CLI,
Starship, fzf, uv, and Google Cloud SDK installations are handled by
`update-brew`; their tool-specific aggregate steps are omitted. For uv, this
decision follows the canonical path of the active external executable, not the
mere presence of a Homebrew formula. If a self-managed uv earlier in `PATH`
coexists with Homebrew's uv, `update-uv-system` updates that exact active path
and the aggregate retains the uv step. Calling `update-uv-system` directly for
the active Homebrew formula upgrades only `uv`, then verifies its resulting
version. The self-managed path also reports failure if its version cannot be
verified after the updater completes. Google Cloud SDK ownership also follows
the active `gcloud`: the `gcloud-cli` or `google-cloud-sdk` cask
belongs to `update-brew`, the `google-cloud-cli` APT package below
`/usr/lib/google-cloud-sdk` belongs to `update-apt`, and any other active SDK
updates its own components. On WSL every tool step ignores Windows programs
from the appended Windows `PATH`, such as the Windows Cloud SDK's `gcloud`
script, and a world-writable tool executable is reported as `blocked` instead
of being run.

On macOS, `softwareupdate` remains a separate operating-system step even when
Homebrew is the primary package backend. It lists the available updates first:
with nothing listed it reports `current` and runs nothing privileged. Updates
that need a restart, and every macOS update or upgrade, are not installed,
because they need a restart and, on Apple silicon, your credentials, which ZDX
never passes. A pending restart is normal on a Mac, so the step does not fail:
it reports them as `skipped` with a warning that names them, and you install
them from System Settings > General > Software Update or with
`sudo softwareupdate --install --restart <label>` yourself. Only the remaining
updates are installed, by exact label, with
`sudo -n softwareupdate --install --no-scan <label>...`, and the step reports
`updated` with the pending restart updates in its detail. A list that cannot
be read or recognized, or an installation that fails, still fails the step.

Platform commands that cannot apply to the host, such as `update-apt` on
macOS or `update-snap` without a running snapd, fail directly with
`<command> is not applicable on this host: <reason>.` and status `1`. Inside an
aggregate they would report `skipped: not applicable (<reason>)`, but
`update-system` omits them from the plan.

`update-node` uses external fnm or an existing nvm installation already loaded
in your shell. The menu marks unloaded NVM as `missing: loaded nvm`. A runtime
installation can succeed while activation or default selection fails; the
command preserves the installed runtime, reports that incomplete phase with a
retry command, and returns failure. It reports complete success only after
those phases and the active-version check pass. NVM activation changes the
current shell's `PATH` as expected.

`update-gcloud` runs `gcloud components update` only for an SDK that manages
its own components, as described above; `update-rust` runs `rustup update` for
an existing rustup installation; and `update-pipx` runs `pipx upgrade-all` for
the applications pipx already manages. Each acts on the executable your
`PATH` selects; when that tool is not installed it reports `skipped` and
returns success.

### 🧹 Cleanup

Use `clean-system --quick` for common package and language caches, the systemd
journal when available, the Linux thumbnail cache, and `~/.cache/tmp`. Deep
mode adds slower Homebrew, Rust, and Go cleanup. The mode prompt names only the
targets your platform has. The pip cache is found through `pip`, `pip3` (all
that Homebrew Python provides), or `python3 -m pip`:

```zsh
clean-system --quick --dry-run
clean-system --deep --yes
clean-journal --dry-run
clean-snaps --dry-run
```

Every broad cleanup displays its typed target plan. Execution runs only those
confirmed records, forwards their recorded scopes to the owning helpers, and
revalidates dynamic cache paths before mutation. A non-interactive mutation
fails closed without `--yes`; dry-run does not require confirmation. Partial
failures are reported and return non-zero. Each step shows one result line and
the closing `Cleanup Summary` table lists every step; `current` means there was
nothing to clean. Ctrl-C stops the cleanup and leaves the remaining targets
untouched. Generic cleanup never removes shared
`/tmp` content and never prunes Docker resources.

For disabled Snap revisions, ZDX authenticates once, re-queries every selected
name and revision immediately before removal, and uses non-interactive `sudo`
only for the final validated `snap remove`. If that state changes, the item is
not removed and the command reports a partial failure. `clean-journal` without
an active systemd journal and `clean-snaps` without Snap or a running snapd
report that they are not applicable on this host and return `1`.

---

## ── File Suite (`file-menu`) ──

The File suite provides a frozen five-command interface for archives,
large-file inspection, a recoverable trash, and junk-file cleanup. Run
`file-menu` to choose an action or call any `file-*` command directly.

### 📦 Archive Management

- **Compress (`file-compress`)**: Create `tar.gz`, `tar.xz`, `tar.bz2`,
  ZIP, or 7z output through private staging. Existing outputs require
  `--overwrite`; the reviewed file is fingerprinted before replacement.
- **Extract (`file-extract`)**: The hardened extractor intentionally accepts
  only GNU TAR archives and needs GNU tar as `tar` or `gtar`; on macOS,
  install Homebrew `gnu-tar`, which adds `gtar`. It rejects traversal,
  duplicates, links, special files, oversized inventories, more than 4,096
  entries, and more than 1 GiB of declared expanded data; on macOS it also
  rejects names that differ only by letter case. It extracts privately and
  publishes only to a new destination. ZIP, RAR, and 7z extraction fail
  closed.

### 📁 Large Files

- **Large files (`file-find-large`)**: Emit matching paths, or add `--delete`
  to review their exact deletion plan.

### 🗑️ Trash

- **Trash (`file-trash`)**: Move files, directories, and symbolic links below
  the current directory into a private trash in
  `${XDG_DATA_HOME:-~/.local/share}/zdx/trash`, then restore them to their
  original paths or delete them permanently. A link is trashed as the link
  itself, never what it points to.

```sh
file-trash put --dry-run -- old-notes.txt build/   # review the move
file-trash put --yes -- old-notes.txt build/       # move both to the trash
file-trash list                                    # IDs, dates, sizes, paths
file-trash restore 20261005-143012-a1b2c3          # put one item back
file-trash purge --older-than 30 --dry-run         # review old items
file-trash purge --all --yes                       # empty the trash
file-trash                                         # pick items, then restore or purge
```

Items move by rename only, so the trash must be on the same filesystem as
what you trash: a path on another disk or mount is refused rather than
copied. A directory is accepted only when it holds no links, special or
hard-linked files, or mounts, so it can always be purged later. A restore
never replaces anything: if something now exists at the original path, or
its parent directory is gone, the item stays in the trash and the message
says what to fix. `file-trash list --json` prints one machine-readable
document (schema `zdx.file-trash.v1`) for scripts. This trash is separate
from your desktop's trash, which does not show these items.

### 🧹 Junk Files

- **Junk files (`file-clean-junk`)**: Delete the `*:Zone.Identifier` files
  Windows leaves when files reach WSL, macOS `.DS_Store` and `._*`
  (AppleDouble) files, and Windows `Thumbs.db` and `desktop.ini` files below
  the current directory, including inside every repository below it, so you
  can run it from a folder such as `~/workspaces`. Only regular files with
  exactly those names match. Links, directories, `.git` directories,
  `node_modules`, `.venv`, and vendored or installed-package trees are
  skipped. A junk file that is not yours, is writable by others, or is
  hard-linked is skipped with a counted warning; set `ZDX_VERBOSE=1` to list
  many. The rest are deleted after you review the exact plan.

```sh
file-clean-junk --dry-run   # list the junk files that would be deleted
file-clean-junk --yes       # delete them without a prompt
```

Mutating commands show a plan and support `--dry-run` and `--yes`. Without
`--yes`, a non-interactive mutation fails closed. The suite works on Linux,
WSL, and macOS: archives made on macOS carry no AppleDouble `._*` members, and
the working directory may be reached through trusted links such as macOS
`/tmp`. On WSL, Windows drives below `/mnt` are refused unless WSL mounts them
with DrvFs metadata; the refusal explains the `/etc/wsl.conf` option. See
[`file-menu.md`](file-menu.md) for exact grammar and the platform table.

For example, `file-find-large --min-size 100M --delete --dry-run` shows the
exact deletion plan; run it again with `--yes` instead of `--dry-run` to apply
it. To keep a way back, move the files with `file-trash put` instead and
purge them once you are sure. An interrupted batch stops before later targets and reports a non-zero
status; completed changes remain. If deletion reports a recovery path, inspect
that quarantine before retrying the original operation.

---

## ── Environment Suite (`env-menu`) ──

The Environment suite inspects the current session's exported variables and
`PATH`, and checks a project's dotenv file against its example. It never
prints a variable value, reads dotenv files only as data and never loads them
into the shell, reads no profile files, persists no state, and registers no
automatic `chpwd` hook.

### 🔍 Variable Diagnostics & Search

- **Active variables (`env-list`)**: List names with `********` or `<hidden>`;
  raw values never enter rows, previews, logs, plans, or fallback output. An
  explicit copy action sends one frozen value only to a supported clipboard
  backend and never prints it on failure. Under WSL, `clip.exe` receives
  UTF-16 text, so accented characters survive, even when the Windows
  directories are not on `PATH`. On macOS, `pbcopy` receives the value under a
  UTF-8 locale.
- **PATH (`env-path`)**: Inspect typed PATH entries. `--dedupe` preserves order
  and empty components, treats `/x/` as a duplicate of `/x`, shows the exact
  removals, and compares the current PATH with the reviewed snapshot before
  changing the session. Entries that differ only by letter case are reported
  and kept.

`env-path --dedupe` supports `--dry-run` and `--yes`; without a terminal and
without `--yes`, it fails closed and leaves `PATH` unchanged. See
[`env-menu.md`](env-menu.md) for the exact grammar and the stdout records of
`--list`.

### 🧾 Dotenv Files

- **Dotenv check (`env-dotenv`)**: Compare `.env` in the current directory
  with the first of `.env.example`, `.env.sample`, `.env.template`, or
  `.env.dist` next to it, or pass `env-dotenv FILE --example FILE`. The report
  lists keys that are missing, extra, empty, or assigned twice, and malformed
  lines by number; it shows key names only, never a value, its length, or a
  digest. It also warns when the file is tracked by Git (with the exact
  `git rm --cached -- .env` hint), is not ignored, is readable or writable by
  other users (with a `chmod -- 600 .env` hint), or belongs to another user.
  Hints are printed, never run.

```zsh
env-dotenv                          # .env against its discovered example
env-dotenv config/.env --example config/.env.example
env-dotenv --json | jq '.missing'   # one zdx.env-dotenv.v1 object on stdout
```

`env-dotenv` returns `0` when it finds no issue, `1` when it finds one or
cannot read the files, and `2` for invalid arguments, so it can gate a script
or CI step. Links, non-regular files, files above 1 MiB, and files longer than
10,000 lines are refused. The supported syntax, including `export`, quotes,
multi-line values, and comments, is listed in
[`env-menu.md`](env-menu.md#supported-syntax).

---

## ── Python Suite (`py-menu`) ──

The Python suite owns validated project-local environments, uv-managed Python
runtimes, project package changes, and isolated global tools. The menu header
shows the project and the active environment and backend. `py-menu --multi`
offers only the read-only `venv-list`, `venv-python-list`, and `tool-list`
actions and runs the selection as one batch with a result line per command, a
summary, and a verdict.

### 🐍 Virtual Environment Lifecycle

- **Create (`venv-create`)**: Create a previously absent `.venv` with `uv` or
  standard-library `venv`. uv creation never downloads a missing Python
  runtime implicitly; install it explicitly first. Poetry creation currently
  fails closed instead of assuming an external target.
- **List, activate, and inspect (`venv-list`, `venv-activate`,
  `venv-info`)**: Operate only on `.venv`, `venv`, or one direct child of
  `.virtualenvs/` that is owned, symlink-free, and contains `pyvenv.cfg`.
- **Remove (`venv-remove`)**: Review, fingerprint, confirm, and remove one
  exact project-local environment after a timeout-bounded structured mount
  check. External Poetry and Conda environments are never adopted.
- **Rebuild (`venv-rebuild`)**: Prints the intended boundary and fails closed;
  automatic replacement remains disabled until a transactional rollback path
  exists.

Activation verifies that `VIRTUAL_ENV`, `PATH`, and the selected Python refer
to the reviewed environment before announcing success. Relocatable uv
environments use a stable descriptor path from `/proc/<pid>/fd` on Linux and
WSL. macOS has no `/proc`, so such an environment is refused before review,
with the exact command to source it yourself; a failed activation restores the
previous standard activation state. Customized activation scripts remain
authorized project code whose other effects cannot be undone generically.

### 📦 Python Version Management (via `uv`)

- **List (`venv-python-list`)**: List installed uv-managed runtimes and their
  interpreters as a table.
- **Install (`venv-python-install`)**: Review and install one validated Python
  version through `uv`; the result names the version it added, or says that it
  was already installed.
- **Pin (`venv-python-pin`)**: Review and write a simple project Python pin
  through `uv`.

### 📦 PyPI Package Management

- **Search (`package-search`)**: Fetch bounded HTTPS metadata for one simple
  package name without installing it, shown as name, version, summary,
  supported Python, and project URL.
- **Install/uninstall (`package-install`, `package-uninstall`)**: Use the
  detected uv/Poetry project or a validated local environment. Ambient `pip`
  is never a fallback. The root and metadata are frozen across authorization;
  a uv member whose workspace root is above the reviewed project is refused.

### 🧰 Isolated Python Tools

- **List (`tool-list`)**: Inspect bounded `uv tool` and `pipx` inventories as
  a table of tools, backends, and versions.
- **Install/remove/upgrade (`tool-install`, `tool-uninstall`,
  `tool-upgrade`)**: Review the exact backend and target, then confirm.
  Installation defaults to `uv` and then `pipx` when no backend is named;
  ambiguous installed names require `--backend`.
  `tool-upgrade --all` freezes both installed inventories by default, while
  `--backend` narrows the exact set.

Tool upgrades compare each tool's version before and after, so a result says
`updated: 1.0.0 → 1.1.0` or `current`, and a summary table follows when
several tools are upgraded. Each failed target is listed with its retry
command. Ordinary failures permit later planned upgrades; interruption stops
them, preserves status `130` or `143`, and lists the targets that did not
run. Inspect the interrupted tool before retrying it. Backend output is shown
only when a command fails.

Py inventories and removal's mount check run under deadlines through the ZDX
core, which needs neither `timeout` nor `gtimeout`, so they work on stock
macOS. Recursive environment removal requires Python 3 and runs on Linux, WSL,
and macOS. On WSL, a project on a Windows drive below `/mnt` is refused unless
WSL mounts it with DrvFs metadata, and the refusal explains the
`/etc/wsl.conf` option. Every mutation supports `--dry-run` and `--yes` where
documented. See
[`py-menu.md`](py-menu.md) for the exact command grammar and residual package
manager limits.

---

## ── Developer Suite (`dev-menu`) ──

The Developer suite (`dev-menu`) runs project-scoped maintenance in the current
directory: quality gates, tests, security scans, dependency updates, and
project-local cleanup. Virtual environments and Python runtimes belong to
`py-menu`; the Developer menu has no `venv-*` entries.

Every action has a direct command, so the menu is only a discovery layer:

```sh
dev-menu                                  # interactive menu
dev-menu --multi                          # mark tasks with Tab and run them
dev-menu dev-clean-all --dry-run          # arguments are forwarded unchanged
dev-menu dev-run-all-checks --verbose
```

Direct commands parse their arguments before checking project files, tools, or
network capabilities. This means `--help` remains available on an incomplete
machine, while an invalid suite-owned option returns status `2` without
starting a probe. Documented pytest and TFLint passthrough arguments are
validated later by their owning tools.
`--multi` is effect-aware: it offers only independent, argument-free tasks and
excludes formatters, dependency and lockfile updates, cleanup, environment
lifecycle, and nested orchestrators such as `dev-check-types` and
`dev-run-all-checks`.

> [!TIP]
> Only the `dev-menu` entrypoint is registered at shell start. Once you have
> invoked it in a session — or if you set
> `ZDX_EAGER_LOAD=1` — every command is also callable on its own, for example
> `dev-run-all-checks --verbose`. In scripts, prefer the `dev-menu <command>`
> form: it works from a cold shell.

For the frozen command surface, the safety model, and the persisted-state rules,
see [`dev-menu.md`](dev-menu.md).

The interactive menu annotates dependencies it can prove missing through
shallow command and path checks. A row without that annotation is not a
readiness guarantee; the selected command revalidates metadata, environment,
and backend provenance before it runs.

Project metadata such as `pyproject.toml` and `uv.lock` is read with Python
3.11 or newer, for `tomllib`. The suite looks for `python3`, then `python3.14`
through `python3.11`, then a uv-managed Python, then the project's validated
`.venv`, so Apple's Python 3.9 or the 3.10 of Ubuntu 22.04 can stay the
default `python3`; a missing interpreter is reported with Homebrew, uv, or
deadsnakes installation advice for your platform. On WSL, Windows programs
reached through the Windows `PATH`, such as npm's `markdownlint` under
`/mnt/c`, do not count as installed tools, and a project on a Windows drive
cannot hold the suite's private backups and reports unless DrvFs metadata is
enabled. On macOS, the Command Line Tools placeholders for `git` and `python3`
are never run. See [Platform support](dev-menu.md#platform-support).

### 🔎 Project Inspection

- **Python/uv Health (`dev-check-health`)**: Diagnose `pyproject.toml`, `.venv`, the pinned interpreter versus `requires-python`, lockfile freshness, hook installation, required and optional tooling, and package-index reachability. A project with none of `pyproject.toml`, `.venv`, `uv.lock`, `.python-version`, or discovered Python source is an explicit clean no-op and does not probe PyPI. Once any marker exists, diagnostics remain strict and return non-zero when an issue is found, so the command works as a Python/uv CI gate.
- **Outdated Dependencies (`dev-check-outdated`)**: Compare the direct dependencies declared across `[project.dependencies]`, `[dependency-groups]`, and `[project.optional-dependencies]` against exactly `.venv/bin/python`. ZDX passes that interpreter to `uv pip list` with `UV_SYSTEM_PYTHON=0`.

Both accept `--report`, which also writes a timestamped Markdown report.
Metadata parsing refuses `pyproject.toml` above 2 MiB or more than 1,000
combined direct dependencies.

### 🧼 Linters, Formatters & Quality Gates

- **All Checks (`dev-run-all-checks`)**: Detect the project's stack and run every applicable gate as a numbered step, then print a `Check Results` table. A failing gate shows the last lines of its output right away; add `--verbose` to see each tool's complete output as it runs.
- **Pre-commit Hooks (`dev-run-hooks`)**: Run the configured file-stage hooks across all files by default, or forward an explicit pre-commit selection. Hooks rewrite files by design. The runner must already be installed in the exact project `.venv`; a global pre-commit executable is never used.
- **Type Checkers (`dev-check-types`)**: Run every type checker the project declares (`ty` or `pyright` in its dependencies, or a `pyrightconfig.json`), falling back to an installed `ty` or `pyright` only when neither is declared, and fail if any of them does.
- **Ruff (`dev-run-ruff` / `dev-run-ruff-format`)**: Fast linting, and separately, in-place formatting. Lint mode rejects writing flags and removes inherited `RUFF_OUTPUT_FILE`.
- **Other gates**: `dev-run-shellcheck` (ShellCheck for sh/bash plus `zsh -n` for `.zsh`), `dev-run-markdownlint`, and `dev-run-tflint`. A `package.json` or `Cargo.toml` adds no gate; run the project's own JavaScript or Rust tooling.

> [!IMPORTANT]
> `dev-run-markdownlint` only checks by default. Pass `--fix` when you actually
> want Markdown files rewritten.

`dev-run-tflint` similarly keeps its remote-code effect explicit. Its default
mode only runs recursive linting; `--init` is required to download or initialize
plugins, and that step asks for confirmation. Use `--init --yes` only when the
configuration is trusted and the command must run non-interactively.
`dev-check-types` accepts no arguments, so no caller option can reach its type
checkers.

Bandit and ShellCheck share one NUL-safe collector that prunes generated trees
and nested repositories, fails on discovery errors, limits the inventory to 512
files, and calls each backend in batches of at most 64 paths.

Each gate resolves its backend in a fixed order. A declared Python dependency
must exist in the exact project `.venv`, as an isolated runnable module or a
proven in-environment executable; it never falls through to `PATH`. Only an
undeclared Python tool may use an installed binary and then opt-in `uvx`.
Markdownlint, the only Node gate, uses `node_modules/.bin`, then an installed
binary, then opt-in `npx`. Falling back to `uvx`/`npx` downloads and executes
remote code, so it requires `export DEV_ALLOW_EPHEMERAL=1` and the
corresponding runner executable. A project-local `node_modules/.bin` entry
avoids the `npx` fallback, but remains project-controlled executable code
rather than an integrity guarantee.

Quality gates, pytest, and configured hooks can load or execute
project-controlled code and configuration. Their read-only classification
describes the wrapper's intended file effects, not a sandbox around the
project.

Installed-package inventories use a stricter project boundary: first an
importable module through `.venv/bin/python -I -m`. The isolated probe and
execution exclude the current directory, `PYTHONPATH`, and the user site.
Inventories never use a global binary, a declared-but-unsynchronized
dependency, or an isolated/overlay/ephemeral runner because those would report
the wrong packages. Install the module into `.venv`; if it is already declared,
synchronize the environment first.

### 🧪 Tests

- **Test Runner (`dev-run-tests`)**: Run pytest without coverage instrumentation. Extra arguments are forwarded to pytest unchanged. Pytest must be installed in the exact project `.venv`.
- **Coverage (`dev-run-coverage`)**: Use the project's installed `pytest-cov` or `coverage` backend, with `--html` for an HTML report and `--fail-under=N` to enforce a threshold. Missing coverage tooling is an error; the command never substitutes a plain pytest success.

These commands do not invoke `uv run`, so a missing project dependency cannot
fall through to a global executable. A no-argument pytest status `5` is treated
as the documented no-tests no-op; explicit pytest arguments preserve that
status. Test detection also recognizes `pytest.toml`, `.pytest.toml`,
`pytest.ini`, `.pytest.ini`, and qualifying pytest tables or sections in
`pyproject.toml`, `tox.ini`, and `setup.cfg`.

### 🛡️ Security Audits

- **Dependency Audit (`dev-run-audit`)**: Check installed packages against known vulnerability advisories. `--fix` shows the remediation effect and asks before upgrading `.venv`; use `--fix --yes` for authorized non-interactive remediation.
- **Static Analysis (`dev-run-bandit`)**: Scan the bounded project inventory for insecure Python patterns; `--high-only` narrows the report to high severity and high confidence. Bandit is a code gate, not an installed-package inventory: declared Bandit must come from `.venv`, while an undeclared tool retains the normal global and opt-in `uvx` fallbacks.

### 🔄 Dependencies & Toolchain

- **Update Dependencies (`dev-update-deps`)**: Build a private candidate `pyproject.toml`, show its summary and diff, then confirm before changing the live project. Changes target actual dependency strings, including several requirements on one line, literal quotes, normalized names, extras, and repeated declarations; comments and unrelated metadata remain intact. Publication requires an exact invocation-owned backup and re-locks *only the bumped packages*. A lock failure restores and verifies that backup and its original mode; a later sync failure leaves the updated metadata and lockfile in place and reports a possibly partial environment. Compound constraints and environment markers are left alone, and a newer minimum is never downgraded. Filter with `--major-only`, `--minor-only`, or `--patch-only`; preview with `--dry-run`, which shows exactly which `>=` specifiers would change and writes nothing; skip the prompt with `--yes`.
- **Update Lockfile Only (`dev-update-lock`)**: Refresh `uv.lock` and sync without touching `pyproject.toml`.
- **Update Pre-commit (`dev-update-precommit`)**: Update the package specifier when PyPI is reachable, then synchronize the project and plan `autoupdate --freeze` against a private hook candidate. If PyPI is unavailable, the package query is reported as incomplete while the configured package and hook backends still run. An updater failure such as an incompatible hook can leave usable proposals from other repositories: ZDX keeps those changes only after validating the complete candidate and installing every planned hook environment, including `commit-msg` and `pre-push` hooks. A Git transport failure can stop upstream before it produces any candidate, so recovery depends on what the updater leaves. The guard preserves existing immutable revisions when proposals are older, incomparable, or move the same tag; interrupted autoupdates are never published. Git receives a native HTTP stall limit using `DEV_PYPI_TIMEOUT`; this is not a total workflow or SSH timeout. After atomic publication, ZDX reinstalls Git hooks and runs applicable file-stage hooks through the exact project `.venv`. Findings and incomplete updates return status `1` with retry guidance, while validated revisions remain published. A concurrent live-config edit is preserved and the original snapshot retained for comparison.
- **Update GitHub Actions (`dev-update-actions`)**: Pin the actions that the project's CI uses to the commit SHA of a newer release. It reads every `*.yml`/`*.yaml` directly below `.github/workflows`, whatever its name, and every `action.yml`/`action.yaml` below `.github/actions`, and finds their `uses:` lines, including reusable workflows such as `owner/repo/.github/workflows/build.yml@main`; `run: |` script text is never touched, and local (`./…`) and `docker://` references are listed as skipped. A SHA-pinned reference takes its current version from a comment such as `# v4.2.2` (or from the tag that points to the SHA); `@v4` or `@main` is unpinned. For each action repository, `git ls-remote --tags` over HTTPS lists the stable `vX.Y.Z` or `X.Y.Z` releases without a token or prompt; prereleases are ignored, annotated tags resolve to their commit, and nothing is downgraded. Updates stay within the current major version unless you pass `--major`, and the plan marks a major update. With an authenticated `gh`, a release younger than `DEV_ACTIONS_COOLDOWN_DAYS` (default 7, `0` disables) is held back and the next older one is used; without `gh` the command says once that release ages were not checked. Each updated line becomes `owner/repo@<sha> # vX.Y.Z` with its indentation, quotes, and other comment text unchanged, and an unpinned reference is pinned (kind `pin`). The plan is a `# · Action · Current · New · Kind · Files` table; `--dry-run` stops there, otherwise ZDX asks `Update N action references?` (`--yes` skips only the prompt), backs up each file it changes, publishes atomically, and runs `actionlint` and `zizmor --offline` on the changed files when they are installed. A validator that passed before and fails after the update restores every file; findings the original files already had are reported and the update is kept. An action whose tags or release age cannot be read is left unchanged and makes the command return `1` while the other actions are still updated.
- **Update Python Runtime (`dev-update-python`)**: Safely replace an existing project `.venv` without invoking ambient Python or `pip`. Replacement requires `pyproject.toml` and `uv.lock`, validates the existing path, shows the plan, and confirms before any mutating uv call. A sole simple `X.Y` project pin selects that minor, with comment lines and Windows line endings read as uv reads them; without a pin, ZDX derives the current `.venv` minor. Multiple, exact `X.Y.Z`, complex, or ambiguous pins are refused before mutation and delegated to `py-menu venv-python-pin <major.minor>`; a non-CPython `.venv` is also delegated because the automatic transaction supports CPython only. The command fingerprints `pyproject.toml` and `uv.lock`, rechecks them plus the interpreter implementation/version and pin selection after consent, and validates the inputs again before install, before locked sync, and after sync. ZDX runs `uv python install --upgrade X.Y`, builds a private same-filesystem environment with `uv venv --clear --managed-python --python X.Y --relocatable <staged>`, synchronizes it through `UV_PROJECT_ENVIRONMENT=<staged> uv sync --all-groups --locked`, verifies that the staged interpreter is CPython in the requested minor, and then swaps directories. Standard console entrypoints and activation scripts remain valid after publication and staging cleanup; arbitrary package scripts and binaries retain their own relocation limits. A publication failure restores the exact original when safe; an unverifiable failure or interrupt retains a reported recovery workspace. Without `.venv`, Dev performs no runtime mutation and forwards to `py-menu venv-python-install`, which owns version selection, preview, and authorization. `--yes` skips its confirmation but not the version selector; unattended callers use `py-menu venv-python-install VERSION --yes`. Installing or upgrading a global uv-managed Python remains an external effect that ZDX cannot roll back.
- **Inspect Terraform / TFLint ownership (`dev-update-terraform` / `dev-update-tflint`)**: Both commands are read-only owner inspections. Terraform reports a proven `tfenv`, Homebrew, or APT owner; otherwise it labels the active binary manual and prints a reproducible update path. It never executes the dynamic `tfenv install latest` path. Every claim is tied to the canonical active executable; tfenv also requires resolved sibling launchers and ignores inherited `TFENV_ROOT`, so a separately installed package cannot claim another binary earlier in `PATH`. A Homebrew claim follows the installation that owns the binary: a second prefix, such as an Intel `/usr/local` beside `/opt/homebrew`, is reported with its own `<prefix>/bin/brew upgrade <formula>`, because `sys-menu update-brew` drives only the brew on `PATH`. TFLint never invokes Homebrew from the Developer suite. An unproven manual TFLint installation gets the verified download procedure and a failure status.

Host `uv` maintenance belongs to `sys-menu update-uv-system`; `dev-update-all`
runs it directly as its host toolchain step.

> [!WARNING]
> This suite never pipes a remote installer into a shell. When no verifiable
> upgrade path exists, it prints the official procedure and stops.

Exact rollback covers a `pyproject.toml` whose downstream lock operation fails.
Pre-commit configuration publication is atomic and refuses a live file changed
by another actor; it never rolls that file back automatically because doing so
could erase a concurrent edit. A later sync failure leaves the published
metadata and lockfile in place and reports a possibly partial environment.
`uv.lock`, installed environments and tools, and files rewritten by hooks
retain the transaction semantics of their external tools and cannot be
generically rolled back by the suite. Before publishing a
`pyproject.toml` rollback, ZDX compares the staged bytes with the exact
invocation-owned backup one final time and refuses a destination whose
metadata or content changed while rollback was staged. Restore and update run
only after their direct write directory passes owner, identity, and
safe-write-mode validation. A group/world-writable directory without sticky
protection is refused.

Dependency and pre-commit updates take their own owner-only `pyproject.toml`
backup after authorization and before publication, and `dev-update-actions`
backs up each workflow file it changes, such as
`.dev-suite-backups/github%workflows%ci.yml.<timestamp>.bak`; there is no
separate backup command. Retention always preserves the backup made by the
current invocation despite clock skew or manipulated mtimes, plus the newest
`DEV_BACKUP_RETENTION - 1` prior copies of the same file (default total: 5).

### 🧹 Cleanup

All cleanup commands compute the exact target set first, show the plan, and only
then ask for confirmation:

- **Clean Python (`dev-clean-py`)**: `__pycache__`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `*.egg-info`, and compiled files, plus root-level `.coverage`, `.coverage.*`, `htmlcov/`, `build/`, and `dist/`; `--keep-build` preserves the build directories.
- **Clean Terraform (`dev-clean-terraform`)**: `.terraform` directories, plan files, crash logs, and state backups. `.terraform.lock.hcl` is always preserved.
- **Clean Everything (`dev-clean-all`)**: One combined plan across all of the above plus root-level Cargo `target/`, confirmed once. `--keep-build` preserves root `build/`, `dist/`, and `target/`. Operating-system junk files such as `.DS_Store` are not a Developer category; remove them with `file-clean-junk` from the File suite.
- **Full Maintenance (`dev-update-all`)**: Freeze and show the applicable scope before authorization: host toolchain, dependency specifiers (`pyproject.toml`), lockfile refresh (`uv.lock`), pre-commit hooks (`pyproject.toml` plus `.pre-commit-config.yaml`), GitHub Actions (`.github/workflows`, run as `dev-update-actions --yes` under the aggregate authorization), installed Terraform and TFLint ownership inspections, and cleanup. Missing project files make a step inapplicable, including during dry-run. Each step checks its own backend, so missing `uv` does not block infrastructure inspection or cleanup. One PyPI probe is reused within the run: failure blocks specifier queries, while lockfile and hook updates still try their own backends and caches. A decline starts no step. Interactive cleanup later shows and confirms its exact targets; `--yes` authorizes both prompt boundaries. The final summary records partial failures and gives the direct commands that retry only pending steps: `sys-menu update-uv-system` for the host toolchain and a `dev-menu` command for every other step. Pre-commit is skipped if the dependency update left project metadata and the lockfile inconsistent and the lockfile refresh could not recover.

Every one of them supports `--dry-run` (plan only) and `--yes` (skip the prompt,
never the validation). Cleanup freezes the root's path, device, inode, and type,
then records each target as a relative path with its own device, inode, and
type. Root and target identities are checked after authorization and around
each removal. The filesystem root, your home directory, and a symlinked or
replaced project root are refused.

Discovery is NUL-delimited and never traverses `.git`, `*.git`, `.venv`,
`node_modules`, `vendor`, `vendored`, or a nested repository discovered from a
`.git` marker. Every discovery stream and nested-repository marker inventory
stops at `DEV_CLEAN_MAX_TARGETS + 1`; the combined plan is deduplicated in
first-seen order. Each category also fails if its combined bounded streams
exceed the limit, and the final plan fails before display, confirmation, or
mutation when it exceeds the configured number of unique targets. `build/`,
`dist/`, and Cargo `target/` are removed only at the project root, while
`.terraform.lock.hcl` is always preserved.

For `dev-update-all`, dry-run invokes only the dependency-update, GitHub
Actions, and cleanup previews, skipping the dependency preview without
`pyproject.toml` and the actions preview without `.github/workflows`; no
toolchain, hook, Terraform, or TFLint workflow is started. A real run shows a
numbered plan, one result line per step, and a `Maintenance Summary`: the
lockfile step lists the packages whose locked versions changed, and the
pre-commit step shows each hook repository's revision as current, updated, or
kept. Add `--verbose` to stream every tool's output. A normal
interactive run first confirms its frozen aggregate scope. If cleanup later
finds targets, it shows the exact set and asks again immediately before removal.
`--yes` explicitly bypasses both prompts while preserving all planning and
revalidation.

```sh
dev-clean-all --dry-run   # see the exact removal plan first
dev-clean-all --yes       # then run it non-interactively
```

### ⚙️ Configuration

Set these in `~/.config/zdx/config.zsh`:

| Variable | Default | Effect |
| :--- | :--- | :--- |
| `DEV_ALLOW_EPHEMERAL` | `0` | Remote-runner opt-in; accepts only `0` or `1` |
| `DEV_BACKUP_DIR` | `.dev-suite-backups` | Where `pyproject.toml` and workflow file backups are stored |
| `DEV_REPORT_DIR` | `dev-suite-reports` | Where `--report` output is written |
| `DEV_BACKUP_RETENTION` | `5` | Backups to keep; integer `1`–`100` |
| `DEV_CLEAN_DEPTH` | `12` | Cleanup discovery depth; integer `1`–`64` |
| `DEV_CLEAN_MAX_TARGETS` | `10000` | Unique cleanup targets; integer `1`–`50000` |
| `DEV_SCAN_DEPTH` | `3` | Stack-detection depth for the menu header; integer `1`–`32`. Gates and file inventories look up to 32 levels |
| `DEV_PYPI_TIMEOUT` | `15` | Per-request seconds; integer `1`–`300` |
| `DEV_PYPI_RETRIES` | `2` | Retries per query; integer `0`–`10` |
| `DEV_PYPI_JOBS` | `8` | Concurrent prefetch jobs; integer `1`–`32` |
| `DEV_ACTIONS_COOLDOWN_DAYS` | `7` | `dev-update-actions` holds back releases younger than this when an authenticated `gh` can read their age; integer `0`–`90`, `0` disables |
| `DEV_ACTIONS_TIMEOUT` | `30` | Seconds for each github.com tag query or `gh api` call; integer `1`–`300` |
| `DEV_SUITE_DEBUG` | `0` | Verbose diagnostics on stderr |

State directories are owned mode `700`; state, report, backup, and cache
temporaries are mode `600`. Publication is atomic and revalidates
directory and file ownership, type, link count, mode, and identity. A path
containing `..`, a symlinked component, or a location outside the project and
your home is refused. Invalid bounds and explicitly empty state overrides fail
closed instead of silently selecting a default.

PyPI query caches are per-invocation private directories below a validated
`TMPDIR`. The suite freezes the temporary-root and cache identities, publishes
entries without clobbering, caps each response at 20 MiB, and quarantines the
exact cache inode before recursive cleanup. Dependency inventories are capped
at 1,000 names and keep only the distribution name before extras, specifiers,
markers, or a direct-URL `@`. Prefer a private `TMPDIR` or a correctly
configured root-owned sticky shared root such as `/tmp`. A non-sticky
group/world-writable root and a sticky root owned by a non-root foreign UID are
refused by both the PyPI cache and update workspace. Cache-hit read failures
propagate. Project metadata is limited to 2 MiB and 1,000 combined direct
dependencies; each PyPI response is limited to 20 MiB.

---

## ── Status Dashboard (`zdx status` / `zdx-status`) ──

`zdx status` prints a read-only, one-screen summary of the current directory
and host on stderr. Every fact comes from a local probe bounded by a timeout:
it never fetches, uses the network, asks for `sudo`, writes a file, or loads
a suite. From the master menu, choose **Show Status Dashboard (status)**.

| Section | Facts |
| --- | --- |
| Repository | Root; branch or detached commit; upstream with ahead/behind counts from local refs (nothing is fetched); staged, unstaged, untracked, and conflicted counts; a merge, rebase, cherry-pick, revert, bisect, or `git am` in progress; the effective `user.email`; and the workspace platform and identity when the repository is below `$WS_BASE_DIR/<platform>/<identity>` (`~/workspaces` by default) |
| Project | The nearest directory, from the current one up to the repository root, that holds `pyproject.toml`, `uv.lock`, `package.json`, `Cargo.toml`, `go.mod`, `Justfile`/`justfile`, or `Makefile`; whether a virtual environment is active and whether it is that project's `.venv`; whether `uv.lock` is older than `pyproject.toml` |
| VPN | Kernel WireGuard interfaces on Linux and WSL, read from sysfs without privilege; unknown on macOS, where `utun` devices are not attributed to WireGuard |
| Host | Linux, WSL1, WSL2, or macOS; whether a reboot is required (the Debian-family `/var/run/reboot-required` flag, unknown elsewhere); usage of the filesystem holding `HOME`; load average |
| ZDX | Version, loaded custom plugins, and whether telemetry and verbose output are on |

The status shows facts only. Whether a repository's identity matches its
workspace is the Git suite's decision, and a stale lockfile is updated with
the Developer or Python suites.

`zdx status --json` prints one `zdx.status.v1` document on stdout instead,
following the [JSON output convention](output-spec.md#json-output). The
document is a single line; it is shown indented here:

```json
{
  "schema": "zdx.status.v1",
  "generated_at": "2026-10-05T12:00:00Z",
  "repository": {
    "root": "/home/jane/workspaces/github/personal/demo",
    "branch": "main", "detached": false, "commit": "<40 hex>",
    "upstream": "origin/main", "ahead": 1, "behind": 0,
    "staged": 1, "unstaged": 0, "untracked": 2, "conflicted": 0,
    "operation": null, "user_email": "jane@example.com",
    "workspace": { "platform": "github", "identity": "personal" }
  },
  "project": {
    "directory": "/home/jane/workspaces/github/personal/demo",
    "files": ["pyproject.toml", "uv.lock"],
    "virtual_env_active": true, "project_venv_present": true,
    "project_venv_active": true, "uv_lock_older_than_pyproject": false
  },
  "vpn": { "wireguard_interfaces": ["wg0"] },
  "host": {
    "platform": "WSL2", "reboot_required": false,
    "home_filesystem": { "size_bytes": 1081101176832,
      "used_bytes": 94007345152, "available_bytes": 932101476352,
      "used_percent": 10 },
    "load_average": [0.17, 0.28, 0.36]
  },
  "zdx": { "version": "0.1.0", "custom_plugins": 0,
    "telemetry": false, "verbose": false }
}
```

`repository` is `null` outside a Git work tree, and each unknown fact is
`null`: an upstream that is missing, a probe that timed out (with a warning on
stderr), `wireguard_interfaces` on macOS, or `reboot_required` where the host
keeps no flag. The document carries no environment values; the active
virtual environment is reported only as booleans. Both modes return `0`, `1`
when the core runtime or, for `--json`, `jq` is missing, and `2` for invalid
arguments.

---

## ── Dependency Doctor (`zdx doctor` / `zdx-doctor`) ──

The Dependency Doctor checks required and optional tools, reports display
settings, and offers a platform-aware installer with explicit confirmation.

### 🔍 Diagnostic Scans

When you run the doctor, it groups system requirements into three categories:

- **Core Requirements**: Fundamental tools required for ZDX core operations (e.g., `fzf`, `git`, `jq`).
- **Optional Suite Requirements**: Specialized tools associated with advanced suites (e.g., `gh`, `wg-quick`, `uv`, `pipx`).
- **Operational Capabilities**: Alternative or semantic requirements that are
  not one package token: `timeout` or `gtimeout`, `sha256sum` or `shasum`,
  `ip`, and GNU `tar` as `tar` or `gtar`. Without `timeout` and `gtimeout`,
  a slower Zsh watchdog enforces the same bounds, so that row is advisory.
  Rows that cannot apply on the platform, such as `ip` on macOS, are shown as
  not applicable and are not counted.

For each tool, the doctor displays:

- Its presence (Installed with version vs. Missing). On macOS, Apple's
  Command Line Tools placeholders for `git` and `python3` are reported as
  missing rather than run, because running them opens an installation
  dialog.
- Its installation path (if present).
- The associated ZDX suite that relies on it (if missing).

Its rendering diagnostics report the terminal, color/plain mode, whether a
theme or inherited fzf options are configured, and the loaded doctor's source
path. Theme and fzf option values are not printed, and option files are not
read. The fzf version probe isolates inherited fzf defaults; failed or malformed probes are
reported as version-check failures, and interruptions stop later diagnostics.

### 🛠️ Platform-Aware Interactive Installer

If missing dependencies are detected, the doctor identifies your active Operating System (Linux, macOS, or WSL) and your system package manager (`brew`, `apt-get`, `dnf`, `pacman`, `apk`). Linux and WSL prefer the system package manager over a Linuxbrew `brew`; WSL is recognized from its interop registration or its Microsoft kernel release even when `WSL_DISTRO_NAME` is not exported.

- **Opt-in Installation**: It lists the exact command it intends to run and asks for your confirmation before executing anything.
- **Official Documentation**: If your package manager doesn't support a specific binary, or if you decline the installation, it prints the official installation link or setup instructions.
- **Manual capabilities**: Missing operational capabilities are reported for
  you to resolve manually; the doctor never adds them to the batch package
  transaction.
- **Safety First**: It never runs commands in the background without explicit verification.

### ⚡ Quick Reference Commands

- `zdx doctor` — Run the dependency diagnostics and installer assistant.
- `zdx-doctor` — Direct function wrapper for the doctor assistant.

---

## ── Plugin Manager CLI (`zdx-plugins`) ──

ZDX features a dynamic plugin manager for custom interactive menus located in `~/.config/zdx/plugins/`, keeping personal extensions outside the tracked repository.

> [!WARNING]
> Plugins are executable Zsh sourced into the current shell and are not
> sandboxed. Review and trust a plugin's source, Git origin, and updates before
> loading it. Syntax and contract checks establish structure, not safety.

### 🔌 Custom Menu Ecosystem

Custom plugins must adhere to the **Plugin Ecosystem Contract** (see [docs/plugins.md](plugins.md)) to enforce:

- **Namespace Safety**: Helper functions prefixed with `_<plugin-name>_*`.
- **Exit Prevention**: Early returns instead of shell-killing `exit` calls.
- **Visual Emitters**: Directing stderr (`>&2`) for prompts and stdout for clean data.

### 🕹️ CLI Actions & Dynamic Loading

- **Interactive Manager (`zdx-plugins` or `zdx plugins`)**: Opens a dedicated
  FZF control screen to list, install, update, or uninstall custom plugins.
  Selections are captured privately and must match the current menu.
- **Install Plugin (`zdx-plugins --install <git-url> [name] [--dry-run] [--yes]`)**:
  Clones the repository into a private staging directory inside the plugin
  root, checks it with the loader's rules (layout, ownership, no symbolic
  links, entrypoint, and Zsh syntax), and shows the origin with any
  credentials hidden, the commit, its full ID, and its signature status. The
  plugin is published and sourced only after you trust it; if sourcing fails,
  it is removed again.
- **Update Plugins (`zdx-plugins --update [name] [--dry-run] [--yes]`)**:
  Fetches each Git-tracked plugin's branch into staging, validates it, and
  shows the exact transition: installed and new commits with subjects, the
  number of commits, whether the history was rewritten, up to ten incoming
  commits, and the signature status. A plugin that is already current needs
  no decision. Once you trust the update, the installed version moves aside,
  the new one takes its place, and the plugin is sourced again. If sourcing
  fails, the previous commit is restored exactly and the failure is reported;
  open a new shell to drop anything the failed version defined. Without a
  name, every plugin is a step with its own decision, followed by a summary.
  A plugin with local, untracked, or ignored files is not updated, so no work
  is lost.
- **Uninstall Plugin (`zdx-plugins --remove <name> [--dry-run] [--yes]`)**:
  Shows the plugin's path, origin, and commit, asks for confirmation, checks
  that nothing changed, and then deletes the directory. Its menu function is
  unregistered; other functions it defined stay until a new shell.
- **Review and automation**: `--dry-run` fetches and validates, or plans a
  removal, without changing anything. Without a terminal, a change needs
  `--yes`, which trusts every reviewed change without a prompt; review with
  `--dry-run` first. Git never prompts for credentials here, so private
  origins need a credential helper or an SSH agent.
- **One operation at a time**: A lock in the plugin root refuses a second
  install, update, or removal while one is running. If a run is interrupted,
  the next one restores a plugin left between versions and removes leftover
  staging; it never deletes a previous version on its own.

---

## ── Unified Master Control (`zdx`) ──

The core **`zdx`** executable serves as the centralized orchestrator and wrapper command for your entire shell workspace.

### 🕹️ Functional Operations

- **Master dashboard (`zdx`)**: A bare invocation opens the unified foreground
  FZF menu. Selection output is captured in a private bounded file, cancellation
  is a no-op, and the complete selected row must belong exactly to the current
  menu snapshot before dispatch.
- **Built-in dispatch (`zdx <suite> [args]`)**: Each built-in suite has a fixed
  dispatcher arm. ZDX never evaluates the selected command as shell text and
  forwards every trailing argument as its original literal array element.
- **Custom-plugin dispatch (`zdx <plugin-name> [args]`)**: A dynamic plugin name
  must satisfy the loader identifier grammar, match one exact entry in
  `ZDX_LOADED_PLUGINS`, and still define its expected menu function. Literal
  arguments are then forwarded without flattening or evaluation. This boundary
  does not sandbox the already trusted plugin code.
- **Status dashboard (`zdx status [--json]`)**: A read-only summary of the
  repository, project, VPN, host, and ZDX settings; see the Status Dashboard
  section above.
  `status` is a reserved route, so a custom plugin cannot use that name.
- **Predictable parser behavior**: `zdx --help` and `zdx-menu --help` write
  usage text to stderr. Unknown options, unexpected master-menu arguments, and
  unknown dispatch names return status `2`.
- **Deferred autoloading (lazy load)**: The core wrapper registers lightweight
  stubs and loads an allowlisted module on first invocation. The loader derives
  one `functions/` root from its own source file, installs stubs through Zsh's
  function table without `eval`, and is idempotent when sourced again. A failed
  module load restores its stub so the command can be retried. The master
  entrypoint loads only its adjacent, regular `zdx-common.zsh`; it has no
  current-directory or home-directory fallback.
