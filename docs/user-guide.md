# ZDX — User & Workflows Guide

This guide provides practical workflows, usage instructions, and guides for the interactive suites in the ZDX ecosystem.

For reviewed local installation, custom Oh My Zsh paths, initial configuration,
and shell activation, follow the [installation contract](installation.md).

---

## ── General Menu Controls (FZF) ──

All interactive menus in ZDX are driven by `fzf`. The following default keybindings apply across all menus:

- **`Up / Down` (or `Ctrl-K / Ctrl-J`)**: Navigate through menu entries.
- **`Enter`**: Run the selected action, open a suite in ZDX, or review tasks in App.
- **`Esc` (or `Ctrl-C`)**: Close the menu and exit back to the shell cleanly.
- **Typing characters**: Filter visible entry text using fuzzy search.
- **`Ctrl-/`**, where advertised: Hide or show the selected entry's details.

Command menus share a compact list and a description below it. The preview
shows the direct command and its scope; section headings show their description
and perform no action. Hidden commands and descriptions are not search terms.
In the master `zdx` menu, route tokens such as `(app)` and `(ws)` appear in the
labels, so those abbreviations can be typed directly.

Context appears above the entries. Multi-selection is available only in menus
that advertise it: `Tab` marks entries, and `Ctrl-A` / `Ctrl-D` select all or
none where shown. App keeps its task descriptions visible and reviews project
execution before authorization. VPN keeps its tunnel-state preview and refresh
loop. File pickers, logs, and live resource dashboards retain their own controls.

The design rationale and comparison are in [`menu-design.md`](menu-design.md).

### Terminal rendering and recovery

Menus use the terminal's native foreground and background with a 16-color
palette by default. Set `ZDX_FZF_THEME` only for an intentional custom theme.
Any nonempty `NO_COLOR` value forces fzf's `--no-color` as a final option,
including when a theme or a caller-supplied color option is present.

If entries are difficult to see, try one invocation in plain mode:

```zsh
ZDX_FZF_PLAIN=1 file-menu
ZDX_FZF_PLAIN=1 zdx
```

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
iTerm2 light/dark appearance still need manual validation; the rendering
changes do not expand any suite's operating-system command support.

### Master catalog

| Group | Destinations |
| --- | --- |
| Projects | Git, Workspaces, Developer tools, Project tasks, CI |
| Files and Environments | Files, Environment variables, Python |
| System and Network | System, Docker, Network, VPN |
| AI and Hardware | AI assistants, Hugging Face, GPU |
| ZDX Tools | Doctor, Plugins |

Use `zdx doctor` to inspect missing dependencies. Loaded custom plugins appear
in their own group and are available through `zdx <plugin>` and completion.
Selecting a suite runs it once and returns to the shell when it finishes.

---

## ── VPN Suite (`vpn-menu`) ──

The VPN suite manages WireGuard tunnels and profiles on Linux and inside WSL.

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

The suite targets **Linux and WSL**: it relies on a system profile directory,
`iproute2`, `wg`/`wg-quick`, and Linux file attributes. On any other host it
stops with the exact next step instead of failing in pieces:

```console
$ vpn-summary
✘ The VPN suite targets Linux and WSL.
➜ Set VPN_CONFIG_DIR to the WireGuard directory for this host to continue.
  For example: VPN_CONFIG_DIR=/opt/homebrew/etc/wireguard
```

Setting `VPN_CONFIG_DIR` is your explicit opt-in. The path is validated, but the
suite cannot vouch for that host's WireGuard integration, and the WSL resolver
pin will not work there. Use an absolute dedicated directory with no symlink or
`..` component; `/`, your home directory, foreign-owned directories, and
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

The source must be a regular, owner-only file owned by you, with a link count of
one, no symlink indirection, and a maximum size of 1 MiB. It must contain
`[Interface]` and `[Peer]`. `PreUp`, `PostUp`, `PreDown`, and `PostDown` are
refused because `wg-quick` would execute imported hook text as root. Add a
reviewed hook later with `vpn-config-edit` if needed.

After reviewing a trusted download, restrict it before import if necessary:

```sh
chmod 600 ~/Downloads/office-vpn.conf
```

You are asked for the profile name, and validated content is staged privately
then installed atomically as mode `600` owned by root. An existing profile is
never overwritten. Running `vpn-profile-import` with no path prompts for one.

### 💻 WSL DNS Hardening

Inside WSL, Windows routes DNS through a relay that ignores the tunnel resolver,
so DNS leaks unless `/etc/resolv.conf` is pinned. On import, the suite offers to
add `PostUp`/`PostDown` hooks that pin the resolver while the tunnel is up and
restore public fallbacks while it is down.

> [!IMPORTANT]
> Those hooks are executed **by root on every tunnel transition**, so the
> profile's `DNS =` value must be a plain comma-separated list of IP addresses.
> Anything else is refused rather than escaped:
>
> ```console
> ✘ The profile's DNS value is not a plain list of IP addresses.
> ➜ Refusing to write it into a root-executed hook. Fix the DNS line first.
> ```

Patching builds a private staged profile and asks `wg-quick` to parse it before
an atomic replacement, so a validation or parse failure leaves the live profile
untouched. Each configured fallback must be exactly one IP address. Idempotency
requires the exact sentinel plus its complete generated `PostUp`/`PostDown`
block; a partial or imitated sentinel is refused for manual review. The separate
WSL IPv6 compatibility rewrite keeps a one-time `.conf.bak-vpn-menu` safety copy.
If requested post-import DNS hardening fails, the command returns non-zero and
reports that the already validated profile remains imported unchanged.
If it cannot retain valid IPv4 `Address`, `DNS`, and `AllowedIPs` values,
`vpn-on` fails before starting the tunnel instead of continuing with a
partially compatible profile.

### ✏️ Editing a Profile

`vpn-config-edit [profile]` opens the file through **`sudoedit`**, which copies
it, runs your editor as your own user, and reinstalls the result as root. Your
editor never runs with root privileges, so a shell escape such as `:!sh` no
longer gives a root shell. `sudoedit` honors `SUDO_EDITOR`, then `VISUAL`, then
`EDITOR`.

If sudoers forbids `sudoedit`, the command says so and changes nothing. There is
deliberately no fallback to `sudo $EDITOR`.

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

Interrupting a tunnel operation stops the remaining batch and exits the
interactive manager without another pause or picker. Ordinary failures in
`vpn-off-all` are reported while independent interfaces can still be processed.

In the menu, the **Profiles** section lists each profile with its live state
(`active`, `default`, `last used`, `backup`) and Enter toggles it. Labels begin
with `Connect` or `Disconnect`, so their meaning does not depend on color. The
header shows platform, access, saved state, and whether the tunnel and exit-IP
tools are available. Missing tools annotate only affected actions; diagnostics
and profile management that do not need them remain usable.

### 🩺 Diagnostics

- `vpn-refresh` — re-read access, profile, tunnel, and pointer state.
- `vpn-summary` — profiles, active tunnels, backups, and saved pointers.
- `vpn-details` — detailed WireGuard state per active tunnel.
- `vpn-ip-info` — tunnel address, endpoint, handshake, transfer, public exit,
  geolocation, resolvers, and a DNS leak hint. Set `VPN_MENU_IP_CROSSCHECK=1` to
  compare the exit IP across providers. Without `curl` or `jq`, local tunnel
  findings remain available and the public-exit lookup is marked unavailable.
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

- A declined confirmation removes nothing and returns `0`.
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
| `VPN_CONFIG_DIR` | `/etc/wireguard` | WireGuard profile directory; also the opt-in for non-Linux hosts |
| `VPN_CACHE_DIR` | `~/.cache/zdx/vpn` | Owner-only default and last-used pointers |
| `VPN_MENU_REPORT_DIR` | `~/vpn-stats` | Diagnostic report output |
| `VPN_MENU_REPORT_RETENTION` | `20` | Reports kept after a successful `vpn-report`; integer `0`–`1000`, `0` keeps all |
| `VPN_DNS_FALLBACK_PRIMARY` | `1.1.1.1` | Resolver pinned while the tunnel is down |
| `VPN_DNS_FALLBACK_SECONDARY` | `9.9.9.9` | Second resolver pinned while down |
| `VPN_MENU_WSL_IPV6_FIX` | unset | Set to `1` to apply the IPv6 tweak outside WSL |
| `VPN_MENU_IP_CROSSCHECK` | unset | Set to `1` to cross-check the exit IP |
| `VPN_MENU_IPINFO_URLS` | built-in cascade | Comma-separated JSON IP providers |
| `VPN_MENU_IPINFO_PLAIN_URLS` | built-in cascade | Comma-separated plain-text IP providers |
| `VPN_MENU_IPINFO_TRACE_URLS` | built-in cascade | Comma-separated trace-format IP providers |

The cache and report directories are created mode `700` with mode `600` files,
and are validated on every use: a `..` segment, a symlinked directory, or a path
outside your home is refused. Provider overrides accept bounded HTTPS URLs
only; invalid schemes, embedded credentials, whitespace, and option-like data
are ignored. Curl is restricted to HTTPS for both the initial request and
redirects, with response-size, connection-time, and total-time limits.

> [!NOTE]
> `vpn-status`, `vpn-public-ip`, and `vpn-disconnect-active` still work, print a
> one-time deprecation notice, and will be removed in v0.3.0. Use `vpn-details`
> plus `vpn-ip-info`, `vpn-ip-info`, and `vpn-off` respectively.

---

## ── Git Suite (`git-menu`) ──

The Git suite helps you manage your repositories, pull requests, and workspace identities.

### 👤 Workspace Identities & Routing

ZDX allows you to define multiple git profiles (e.g., Personal vs. Work) with different email addresses, GPG signing keys, and SSH keys.

- **Context-aware Switcher**: When you switch into a directory configured for a specific workspace, ZDX routes your SSH agent and commits using the correct identities.
- **Contribution checks**: The commit-message hook validates Conventional Commits, while the CI DCO check verifies the required `Signed-off-by:` trailer.

### 📝 Commit & Push Conventions

All commits must satisfy the repository's strict quality rules:

- **Developer Certificate of Origin (DCO)**: Every commit must be signed off. Always use the `-s` flag (e.g., `git commit -s -m "..."`).
- **Conventional Commits**: Commits must start with a valid scope (such as `deps`, `docs`, `git`, `vpn`). Example: `feat(git): add branch cleanup`.

### ⚡ Quick Reference of Git Commands

- `git-menu` — Open the interactive git menu.
- `git-auth` — Show active identity, remote alignment, and authentication
  status without displaying credentials or tokens.
- `git-prs` — List open pull requests for the current repository.
- `git-pr-checkout [NUMBER]` — Check out a pull request branch locally.
- `clean-branches` — Preview and remove merged local branches while protecting
  the current and default branches.
- `clean-remote-merged` — Preview and remove merged remote branches with exact
  leases.

After a merge request, `git-prs` checks the PR again. It distinguishes a verified
merge from an accepted request that remains open for GitHub checks or a merge
queue. If the final state cannot be verified, inspect the PR before retrying;
ZDX does not automatically submit the request again.

When selecting several commits in `git-cherry-pick`, Git keeps one sequence so
you can continue or skip after resolving a conflict, or abort the whole
sequence. Interrupting stash deletion, discard, or restore stops the remaining
targets and reports which ones were not attempted.

---

## ── Docker Suite (`docker-menu`) ──

The Docker suite provides foreground dashboards and a strict direct CLI for
containers, images, Compose projects, registry authentication, and exact
cleanup. It freezes the Docker context, endpoint, daemon identity, and server
version for each workflow. Remote mutations require `--allow-remote`.

```zsh
docker-menu docker-containers --action list
docker-menu docker-images --action remove --id sha256:FULL_ID --dry-run
docker-menu docker-clean --scope stopped-containers --dry-run
docker-menu docker-compose-up --file compose.yaml --dry-run
docker-menu docker-login registry.example.test --username USER --password-stdin
```

Container and image list modes emit typed records with complete opaque IDs.
Interactive pickers retain those IDs in a private snapshot rather than
recovering a target from a display label. Structured inventories and explicit
container/Compose logs use stdout. Interactive container exec and image run
also retain their attached terminal session on stdout. Feature UI, plans, and
non-interactive mutation output use stderr.

Cleanup never invokes `docker prune`. It previews and revalidates exact stopped
container, dangling image, unused custom-network, or unused-volume targets.
The `all` scope deliberately excludes volumes. Every removal requires a
terminal confirmation or `--yes`; `--dry-run` is side-effect free.
Multi-resource plans execute each unchanged reviewed record. Ordinary failures
allow later targets to proceed; interruptions stop them and report completed,
failed, interrupted, and unattempted counts. Inspect an interrupted target
before retrying because Docker may already have accepted its removal.

Compose accepts one owned, non-symlink direct-child YAML descriptor, refuses
every non-empty ambient `COMPOSE_*` parameter plus
`DOCKER_DEFAULT_PLATFORM`, removes them from the Compose subprocess
environment, fingerprints the file and resolved configuration, and requires
review before `up`, `down`, or `restart`. Dockerfiles, build contexts,
`env_file` content, image code, the Docker socket, and live remote backends
remain explicit trust boundaries.

Registry login does not require a reachable daemon. ZDX validates the registry
and an owner-only Docker configuration below `HOME`, pins it with
`docker --config`, refuses malformed or warning-producing `config.json`
content, then passes credentials directly to Docker; it never reads or prints
a password. See the full grammar, controls, and manual acceptance boundaries
in [`docker-menu.md`](docker-menu.md).

---

## ── System Suite (`sys-menu`) ──

The System suite centralizes capability-aware host diagnostics, updates,
cleanup, resource control, dotfile recovery, user fonts, and local telemetry.
Run `sys-menu` for the interactive command menu or invoke any command directly:

```zsh
sys-menu sys-info
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
  counts. Linux, WSL, and macOS use separate read-only collectors.
- **Health Check (`sys-health`)**: Inspect disk and inode pressure, memory and
  swap, zombie processes, service failures, and platform-specific health data.
  Unsupported checks are marked unavailable rather than treated as healthy.
- **Startup Analysis (`sys-startup`)**: Measure ten interactive Zsh startups
  with a timeout and run an isolated `zprof` report against `~/.zshrc`.
  This starts eleven isolated Zsh subprocesses in total. Startup files execute
  normally inside them and may still perform their usual external side effects.
- **PATH Inspector (`sys-path`)**: Report duplicate, missing, and empty PATH
  entries. This command is strictly read-only and never edits `.zshrc`.
- **Symbol Browser (`sys-aliases`)**: Browse aliases and public functions with
  fzf. Use `sys-aliases --list [all|aliases|functions]` for names-only TSV
  output in scripts. Definitions are not rendered in the browser, which avoids
  exposing secrets embedded in shell functions.
- **Telemetry (`sys-telemetry --dashboard` / `--browse`)**: Inspect validated,
  bounded local telemetry without passing raw JSON to the terminal preview.
  Malformed records, implausible durations, and an incomplete final line are
  skipped.
  `sys-telemetry --clear --dry-run` previews the exact clear operation;
  `--yes` is required for non-interactive clearing.

Diagnostic, discovery, download, and archive-inspection probes have bounded
deadlines. Where GNU timeout is available, its process-group behavior and KILL
grace period also stop descendants. A transaction that has begun changing
packages, caches, services, processes, fonts, or repositories is not abandoned
by a watchdog; it runs to a reported result.

### ⚙️ Services, Processes, and Ports

The three resource browsers use typed records and revalidate live identity
after confirmation. Interactive hotkeys return an action to Zsh; they never
execute a destructive command inside `fzf`.

- **Processes (`sys-processes`)**: `--list` emits process, PID, UID, CPU,
  memory, and command fields as TSV. `--terminate PID` sends `SIGTERM`;
  `--force` explicitly selects `SIGKILL`. Protected PIDs are rejected.
- **Ports (`sys-ports`)**: `--list` emits protocol, port, address, PID, and
  command records from `lsof` or `ss`. Use an explicit PID or port target; a
  bare number is intentionally ambiguous and rejected.
- **Services (`sys-services`)**: `--list` emits systemd or launchd records.
  `--show ID` is read-only. Start, stop, restart, enable, and disable require an
  exact validated identifier and confirmation.

Examples:

```zsh
sys-processes --terminate 4242 --yes
sys-processes --terminate 4242 --force --yes
sys-ports --kill-port 3000 --protocol tcp --yes
sys-ports --kill pid:4242 --yes
sys-services --restart demo.service --yes
```

`--yes` bypasses only the prompt. The process fingerprint, port ownership, or
service state is still checked again immediately before the operation.
For a foreign process or systemd service, ZDX validates the target, runs
`sudo -v` to authenticate, validates again in case state changed while the
prompt was open, and invokes only the final `kill` or `systemctl` operation
with `sudo -n`. Launchd actions target the current user's launchd domain.
macOS backend logic is covered by deterministic mocks, but a real macOS host
verification has not yet been recorded.

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
Git, script, and AI self-updater origins. `--include-remote-code` explicitly
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
status `1`. Nested AI failures name the responsible updater, for example
`AI assistants — Cursor Agent: authentication required`. If every applicable
step fails, the command reports an ordinary failure instead.

Git-owned fzf, Oh My Zsh, custom Zsh plugin repositories, and the AI suite's
installed-assistant update plan are included unless `--safe-only` is present.
The Git-owned repository paths display their origin and current commit,
require owned symlink-free checkouts below `HOME`, repeat identity and origin
checks after authorization, and use fast-forward-only pulls. The fzf installer
must match its tracked Git blob; Oh My Zsh does not execute
`tools/upgrade.sh`.

System delegates assistants to
`ai-menu ai-update --skip-homebrew-managed --result-tsv`, so Homebrew-owned installations
stay with the earlier Homebrew step and Hermes is not run twice.
`update-hermes` remains a compatibility bridge to `ai-update-hermes`. The
aggregate authorization — interactive confirmation or `--yes` — pre-authorizes
these mutable origins, so use `--dry-run` first when their current origins
need review. `update-apt`, `update-snap`, `update-fzf`, `update-omz`,
`update-zsh-plugins`, and `update-hermes` provide their own review controls
when invoked directly. Other direct updater commands keep their
command-specific interface; do not assume the aggregate flags apply to every
updater. The structured result channel is captured internally; AI progress and
the final one-line result for every assistant remain visible on stderr, while
`update-system` itself emits no stdout data. The report must contain all eight
canonical targets or the AI step fails closed. The AI-owned summary counts a successful version or validated-binary
fingerprint change as `updated`. `Already current` requires both version and
fingerprint to remain unchanged; failed and skipped counts stay independent.

APT operation announcements are compact by default (`sudo -n apt-get update`,
`full-upgrade -y`, and `autoremove -y`). During an actual execution, add
`--verbose` to direct APT or the aggregate to show the complete fixed `env -i`
command and every APT policy argument; APT's own output is unchanged. A verbose
dry run remains a target review and does not print mutation commands that will
not execute. The aggregate forwards `--verbose` only to APT.

ZDX-owned orchestration avoids hidden prompts and open-ended APT waits, while
external package tools retain the transaction semantics described below.
Git-owned steps never prompt for credentials: terminal and askpass prompts are
disabled, SSH runs in batch mode with a connect deadline unless you export your
own `GIT_SSH_COMMAND`, and Git aborts a transfer stalled below 1 KiB/s for 60
seconds. The Homebrew metadata refresh has a 120-second deadline and sets
`HOMEBREW_CURL_RETRIES=0` for curl-level retries. A Snap preview error or
deadline is reported as a failed step rather than "no pending updates". Every
aggregate step reports its elapsed time so a slow step is visible in the final
summary.

When the confirmed plan contains privileged package steps, ZDX reuses a valid
non-interactive sudo timestamp or announces and runs one `sudo -v` right after
your authorization. While the initial consecutive privileged entries run, an
invocation-owned worker refreshes that timestamp with `sudo -n -v` and closed
stdin every 30 seconds. It cannot prompt. A private Zsh handle carries the stop
request and bounded acknowledgement; ZDX confirms exit and deletes that exact
handle after the last privileged entry or through `always` cleanup on failure,
return, or interruption. The worker never enters the caller's job table, so it
does not produce `[n] ... terminated` or `done` notifications. Each package or
signal operation that requires sudo still uses
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
sleep, deferred retry, or second APT entry. Every `apt-get` invocation within
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
defines it as disabled: `npm_config_fetch_retries=0` for npm global installs,
`UV_HTTP_RETRIES=0` for uv, `PIP_RETRIES=0` and `PIP_NO_INPUT=1` for pipx/pip,
`CARGO_NET_RETRY=0` for Cargo, and `RUSTUP_MAX_RETRIES=0` for rustup. These
settings prevent the supported client-level retries and pip input prompts; an
active package mutation still runs to its reported result. Cargo can still
wait for its package-cache lock, for which it has no supported zero-wait
switch.

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
120-second outer deadline described above. Homebrew 6 still has internal
`DownloadQueue` retry behavior
and download-lock waiting with no public option to disable them. Mutating
Homebrew phases may therefore exercise those external waits or retries and are
not killed after mutation starts. Every phase receives the validated fixed
`SUDO_ASKPASS=/usr/bin/false` only on macOS. Homebrew may call its own
`sudo -A` for a cask; if the shared timestamp is unavailable, that fixed
askpass guard fails instead of prompting. Linuxbrew does not receive the guard.
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

`update-repomix` also checks the active executable's installation owner. It
updates only the matching npm global installation, or leaves a proven
Homebrew installation to `update-brew`. A custom executable or shell wrapper
cannot cause an unrelated global npm copy to be installed or updated. The
command verifies its runtime, exact prefix, and resulting executable before
reporting success.

The aggregate avoids updating one installation twice. Homebrew-owned AWS CLI,
Starship, fzf, uv, Google Cloud SDK, and Repomix installations are handled by
`update-brew`; their tool-specific aggregate steps are omitted. For uv, this
decision follows the canonical path of the active external executable, not the
mere presence of a Homebrew formula. If a self-managed uv earlier in `PATH`
coexists with Homebrew's uv, `update-uv-system` updates that exact active path
and the aggregate retains the uv step. Calling `update-uv-system` directly for
the active Homebrew formula upgrades only `uv`, then verifies its resulting
version. The self-managed path also reports failure if its version cannot be
verified after the updater completes. On macOS, `softwareupdate` remains a
separate operating-system step even when Homebrew is the primary package
backend.

`update-node` uses external fnm or an existing nvm installation already loaded
in your shell. The menu marks unloaded NVM as `missing: loaded nvm`. A runtime
installation can succeed while activation or default selection fails; the
command preserves the installed runtime, reports that incomplete phase with a
retry command, and returns failure. It reports complete success only after
those phases and the active-version check pass. NVM activation changes the
current shell's `PATH` as expected.

### 🧹 Cleanup

Use `clean-system --quick` for common package and language caches, the systemd
journal when available, thumbnails, and `~/.cache/tmp`. Deep mode adds slower
Homebrew, Rust, and Go cleanup:

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
failures are reported and return non-zero. Generic cleanup never removes shared
`/tmp` content and never prunes Docker resources; use the Docker suite for
Docker lifecycle operations.

For disabled Snap revisions, ZDX authenticates once, re-queries every selected
name and revision immediately before removal, and uses non-interactive `sudo`
only for the final validated `snap remove`. If that state changes, the item is
not removed and the command reports a partial failure.

### 💾 Dotfile Backup and Restore

`sys-backup-dots` creates an owner-only archive below
`~/.dotfiles-backups`, plus an exact manifest and SHA-256 sidecar. Only
existing non-link paths below `HOME` are included. The workflow warns because
configured files can include authentication data. Configured entry, logical
size, compressed size, manifest size, and path-length limits are enforced
before the archive triple is published. Both commands stop with the name of a
missing `tar` or SHA-256 tool before planning. If `HOME` is a symbolic link,
backups still work; restore refuses a link destination, so run it with `HOME`
set to the canonical directory.

```zsh
sys-backup-dots --dry-run
sys-backup-dots --yes
sys-restore-dots --archive ~/.dotfiles-backups/dotfiles_YYYYMMDD_HHMMSS.tar.gz --dry-run
sys-restore-dots --archive ~/.dotfiles-backups/dotfiles_YYYYMMDD_HHMMSS.tar.gz --yes
```

Restore verifies ownership, archive size, digest, the exact manifest, entry
types, traversal boundaries, destination links, and archive identity after
confirmation. It extracts into a private staging directory, then walks the
actual tree with NUL-delimited records so control characters, symbolic links,
special files, foreign-owned entries, and hardlinks cannot hide behind an
escaped tar listing. The actual extracted paths, including implicit parent
directories, must match the verified manifest exactly.

Before publication, ZDX creates a mandatory pre-restore safety archive. Because
that backup can take time, it revalidates the staged files and every
destination afterwards. Each file is copied into a same-directory temporary,
revalidated, and installed with an atomic rename. A destination link detected
before publication is rejected; one introduced after the last validation is
replaced as a directory entry, so its linked inode is never followed or
truncated.

### 🔤 Verified Nerd Fonts

`sys-fonts --list` emits installed user-font files as
`family<TAB>absolute-path` TSV. Installation accepts one allowlisted family:
`CascadiaCode`, `FiraCode`, `Hack`, `JetBrainsMono`, or `Meslo`.

```zsh
sys-fonts --install JetBrainsMono --dry-run
sys-fonts --install JetBrainsMono --yes
```

The default artifact is the pinned Nerd Fonts v3.4.0 release. The archive is
verified against the release SHA-256 manifest before extraction. ZDX then
walks the real extracted tree with NUL-delimited records and rejects unsafe
names, links, special or multiply linked files, duplicate destination names,
and configured entry, path, and size limit violations before publication.

New installations contain a ZDX management marker. ZDX automatically removes
an older family only when that marker and family identity validate. If an
existing directory is not ZDX-managed, it is moved to a reported sibling
recovery directory outside the active font directory and is never
automatically deleted. `sys-fonts --list` validates the user-font base and
uses a bounded NUL-delimited inventory of owned regular files without
traversing symbolic-link directories. Linux uses the user fontconfig directory;
macOS uses the user `Library/Fonts` directory.

### 🔌 Plugin Compatibility

`sys-plugins` is retained for compatibility and delegates its arguments to the
canonical `zdx-plugins` manager. Plugins remain arbitrary Zsh code sourced into
the current shell; review their origin and commits before installation or
update.

---

## ── File Suite (`file-menu`) ──

The File suite provides a frozen ten-command interface for archives, bounded
search, local file mutation, conversion, and integrity checks. Run `file-menu`
to choose an action or call any `file-*` command directly.

### 📦 Archive Management

- **Compress (`file-compress`)**: Create `tar.gz`, `tar.xz`, `tar.bz2`,
  ZIP, or 7z output through private staging. Existing outputs require
  `--overwrite`; the reviewed file is fingerprinted before replacement.
- **Extract (`file-extract`)**: The hardened extractor intentionally accepts
  only GNU TAR archives. It rejects traversal, duplicates, links, special
  files, oversized inventories, more than 4,096 entries, and more than 1 GiB
  of declared expanded data. It extracts privately and publishes only to a new
  destination. ZIP, RAR, and 7z extraction fail closed.

### 📁 File & Bulk Operations

- **Bulk operations (`file-bulk-ops`)**: Copy, move, delete, rename, or
  duplicate validated paths. Targets must remain owned, symlink-free children
  of the current directory; overlapping trees and destination collisions are
  refused.
- **Permissions (`file-permissions`)**: Apply `+x`, `-x`, or a validated
  three/four-digit octal mode.
- **Large files (`file-find-large`)**: Emit matching paths, or add `--delete`
  to review their exact deletion plan.
- **Search and compare (`file-find`, `file-diff`)**: Search by name,
  extension, literal content, or age; compare two validated local paths.

### 🔏 Data Converter & Integrity

- **Base64 (`file-encode-decode`)**: Encode or decode bounded text on stdout,
  or convert a file through staging without truncating an existing output on
  failure.
- **Checksums (`file-checksum`)**: Generate SHA-256 or legacy MD5 on stdout,
  or verify one expected digest.
- **Line endings (`file-line-endings`)**: Convert regular files to LF or CRLF
  through same-directory staging and atomic replacement.

Mutating commands show a plan and support `--dry-run` and `--yes`. Without
`--yes`, a non-interactive mutation fails closed. See
[`file-menu.md`](file-menu.md) for exact grammar and residual GNU portability
limits.

Pass multiple paths after `--` to apply one reviewed plan. For example,
`file-line-endings --to lf --yes -- first.txt second.txt` converts both files.
An interrupted batch stops before later targets and reports a non-zero status;
completed changes remain. If deletion reports a recovery path, inspect that
quarantine before retrying the original operation.

---

## ── App Suite (`app-menu`) ──

The App suite discovers project tasks without turning descriptor text into
shell code. It examines only the canonical current directory and, when
different, its Git root.

### 🏃 Project Tasks (`app-menu`)

- **List (`app-list`)**: Emit bounded typed records for tasks declared in a
  direct-child `Justfile`, `package.json`, `Makefile`, or Compose descriptor.
- **Run (`app-run`)**: Rediscover and execute one exact task through a fixed
  `just`, Node package-manager, `make`, or `docker compose` argument vector.
- **Interactive browser (`app-menu`)**: Select one task, or use `--multi` to
  authorize an ordered batch that continues and reports partial failure.

Descriptors are limited to safe owned regular files no larger than 2 MiB.
Their identity and SHA-256 content are checked during discovery, before
authorization, and immediately before execution. Script bodies and comments
are never inserted into a preview or evaluated by ZDX. Because the selected
backend still executes project-defined code, App displays the exact fixed
invocation and asks for confirmation; non-interactive execution requires
`--yes`, while `--dry-run` executes no task. See
[`app-menu.md`](app-menu.md) for the exact grammar and residual trust boundary.

Direct execution checks the requested backend family, so a broken unrelated
descriptor does not prevent `app-run --backend just --task build --dry-run`.
The full browser still requires a valid inventory. Ordinary task failures show
the failed invocation and a command to review before retrying; execution
interruptions stop the remaining tasks and preserve status `130` or `143`.

---

## ── CI Suite (`ci-menu`) ──

The CI suite binds every GitHub read and write to the validated current
repository. It requires Git, an authenticated `gh`, Python 3, and
`timeout`/`gtimeout`; `fzf` is needed only for interactive selection.

### 🧹 GitHub Workspace Cleanups

- **Status (`ci-status`)**: Render one run or emit a bounded typed run list.
- **Dispatch (`ci-run`)**: Freeze one active workflow, local branch, and
  matching GitHub commit before authorizing remote workflow code.
- **Actions (`ci-clean-actions`)**: Delete exact selected run IDs while
  protecting the newest run per workflow.
- **Deployments (`ci-clean-deployments`)**: Deactivate and delete exact
  non-latest deployments, reporting either half of a partial transaction.
- **Releases (`ci-clean-releases`)**: Delete exact non-latest releases without
  implicitly deleting their Git tags.
- **Notifications (`ci-clean-notifications`)**: Mark exact unread
  repository-specific notification thread IDs.

Every owned mutation supports `--dry-run` and `--yes`, re-fetches its complete
validated records after authorization, and reports partial failure. Tags and
issues belong to Git; `ci-clean-tags` and `ci-clean-issues` are deprecated
public adapters to that owner. See [`ci-menu.md`](ci-menu.md) for the frozen
grammar and remote-race boundary.

Use `ci-status --run ID` to inspect an older execution directly; `--limit`
continues to bound recent listings and interactive discovery. Cleanup keeps
its own inventory limits and newest-resource protection. Interrupted remote
mutations stop later targets; inspect the affected resource before retrying,
because the service may have accepted the request before the client stopped.

---

## ── Environment Suite (`env-menu`) ──

The Environment suite treats dotenv and profile content as passive data. It
never runs their contents through `source`, `eval`, shell expansion, or command
substitution.

### 📁 Dotenv File Switching & Creation

- **Load (`env-switch`)**: Parse one explicit or bounded-discovered dotenv
  file into a frozen snapshot, show key names without values, revalidate the
  file, and apply only ordinary exported scalar variables.
- **Create (`env-create`)**: Publish a mode-`600` dotenv file atomically,
  optionally from one validated template, without clobbering an unreviewed
  destination.

Quoted multiline values are preserved literally; quotes, backslashes, `$`,
and inline comment text never become executable syntax. Loading is always an
explicit action. ZDX registers no automatic `chpwd` dotenv hook.
Creation preserves literal quote characters in template defaults and entered
values when the generated file is loaded again.

### 🔍 Variable Diagnostics & Search

- **Active variables (`env-list`)**: List names with `********` or `<hidden>`;
  raw values never enter rows, previews, logs, plans, or fallback output. An
  explicit copy action sends one frozen value only to a supported clipboard
  backend and never prints it on failure.
- **PATH (`env-path`)**: Inspect typed PATH entries. `--dedupe` preserves order
  and empty components, shows the exact removals, and compares the current
  PATH with the reviewed snapshot before changing the session.

### 💾 Named Profile Manager

Save a snapshot of specific environment variables and restore them anytime:

- **Save (`env-profile-save`)**: Atomically publish selected exported scalars
  in an owner-only profile.
- **List (`env-profile-list`)**: Emit or browse bounded validated profile
  metadata without initializing state.
- **Load (`env-profile-load`)**: Passively parse, review, and apply one
  unchanged profile.
- **Delete (`env-profile-delete`)**: Quarantine and remove one exact unchanged
  profile after confirmation.

Profile directories are mode `700`, files are mode `600`, and every mutating
command supports dry-run and explicit non-interactive authorization. See
[`env-menu.md`](env-menu.md) for the exact format and filesystem boundary.
Overwrite and deletion distinguish their own rename from an external change.
If publication fails, an unchanged original is restored; unexpected changes
retain a reported recovery path for inspection.

---

## ── Python Suite (`py-menu`) ──

The Python suite owns validated project-local environments, uv-managed Python
runtimes, project package changes, and isolated global tools. `py-menu --multi`
offers only the read-only `venv-list`, `venv-python-list`, and `tool-list`
actions.

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
environments use a stable descriptor path on supported hosts. An unsupported
host fails with guidance before sourcing; a failed activation restores the
previous standard activation state. Customized activation scripts remain
authorized project code whose other effects cannot be undone generically.

### 📦 Python Version Management (via `uv`)

- **List (`venv-python-list`)**: List installed uv-managed runtimes.
- **Install (`venv-python-install`)**: Review and install one validated Python
  version through `uv`.
- **Pin (`venv-python-pin`)**: Review and write a simple project Python pin
  through `uv`. The compatibility form is
  `venv-python <list|install|pin>`.

### 📦 PyPI Package Management

- **Search (`package-search`)**: Fetch bounded HTTPS metadata for one simple
  package name without installing it.
- **Install/uninstall (`package-install`, `package-uninstall`)**: Use the
  detected uv/Poetry project or a validated local environment. Ambient `pip`
  is never a fallback. The root and metadata are frozen across authorization;
  a uv member whose workspace root is above the reviewed project is refused.

### 🧰 Isolated Python Tools

- **List (`tool-list`)**: Inspect bounded `uv tool` and `pipx` inventories.
- **Install/remove/upgrade (`tool-install`, `tool-uninstall`,
  `tool-upgrade`)**: Review the exact backend and target, then confirm.
  Installation defaults to `uv` and then `pipx` when no backend is named;
  ambiguous installed names require `--backend`.
  `tool-upgrade --all` freezes both installed inventories by default, while
  `--backend` narrows the exact set.

Tool upgrades report each failed target and its retry command. Ordinary
failures permit later planned upgrades; interruption stops them, preserves
status `130` or `143`, and reports how many targets were not started. Inspect
the interrupted tool before retrying it.

Py inventories require `timeout` or `gtimeout`; recursive environment removal
also requires Python 3 and Linux `findmnt`. Every mutation supports `--dry-run`
and `--yes` where documented. See
[`py-menu.md`](py-menu.md) for the exact command grammar and residual package
manager limits.

---

## ── Developer Suite (`dev-menu`) ──

The Developer suite (`dev-menu`) runs project-scoped maintenance in the current
directory: quality gates, tests, security scans, dependency updates,
distribution artifacts, and project-local cleanup.

Every action has a direct command, so the menu is only a discovery layer:

```sh
dev-menu                                  # interactive menu
dev-menu --multi                          # mark tasks with Tab and run them
dev-menu --profile nightly                # run a saved task profile
dev-menu dev-clean-all --dry-run          # arguments are forwarded unchanged
dev-menu dev-run-all-checks --verbose
```

Direct commands parse their arguments before checking project files, tools, or
network capabilities. This means `--help` remains available on an incomplete
machine, while an invalid suite-owned option returns status `2` without
starting a probe. Documented pytest and TFLint passthrough arguments are
validated later by their owning tools.
`--multi` is effect-aware: it offers only independent, argument-free tasks and
excludes formatters, cleanup, environment lifecycle, profiles, and nested
orchestrators.

> [!TIP]
> Only the `dev-menu` entrypoint is registered at shell start. Once you have
> invoked it in a session — or if you set
> `ZDX_EAGER_LOAD=1` — every command is also callable on its own, for example
> `dev-run-all-checks --verbose`. In scripts, prefer the `dev-menu <command>`
> form: it works from a cold shell. Workspace is a deliberate exception that
> registers all of its direct commands for lazy loading.

For the frozen command surface, the safety model, and the persisted-state rules,
see [`dev-menu.md`](dev-menu.md).

> [!NOTE]
> Public commands are prefixed with `dev-`. The old unprefixed names
> (`clean-py`, `run-tests`, `update-deps`, …) still work, print a one-time
> deprecation notice, and will be removed in v0.3.0.

The interactive menu annotates dependencies it can prove missing through
shallow command and path checks. A row without that annotation is not a
readiness guarantee; the selected command revalidates metadata, environment,
and backend provenance before it runs.

### 🔎 Project Inspection

- **Python/uv Health (`dev-check-health`)**: Diagnose `pyproject.toml`, `.venv`, the pinned interpreter versus `requires-python`, lockfile freshness, hook installation, required and optional tooling, and package-index reachability. A project with none of `pyproject.toml`, `.venv`, `uv.lock`, `.python-version`, or discovered Python source is an explicit clean no-op and does not probe PyPI. Once any marker exists, diagnostics remain strict and return non-zero when an issue is found, so the command works as a Python/uv CI gate.
- **Outdated Dependencies (`dev-check-outdated`)**: Compare the direct dependencies declared across `[project.dependencies]`, `[dependency-groups]`, and `[project.optional-dependencies]` against exactly `.venv/bin/python`. ZDX passes that interpreter to `uv pip list` with `UV_SYSTEM_PYTHON=0`.
- **Dependency Licenses (`dev-check-licenses`)**: List installed licenses and flag restrictive copyleft terms. `--strict` classifies only the `License` field from bounded structured JSON, never package or author text.

All three accept `--report`, which also writes a timestamped Markdown report.
Metadata parsing refuses `pyproject.toml` above 2 MiB, more than 1,000 combined
direct dependencies, or either license-backend output above 10 MiB. License records
must contain string `Name`, `Version`, and `License` fields; strict policy
classifies only `License` and refuses a malformed schema.

### 🧼 Linters, Formatters & Quality Gates

- **All Checks (`dev-run-all-checks`)**: Detect the project's stack and run every applicable gate, then print a consolidated pass/fail table with timings. Add `--verbose` to see each tool's own output instead of just the summary.
- **Pre-commit Hooks (`dev-run-hooks`)**: Run the configured file-stage hooks across all files by default, or forward an explicit pre-commit selection. Hooks rewrite files by design. The runner must already be installed in the exact project `.venv`; a global pre-commit executable is never used.
- **Type Checkers (`dev-check-types`)**: Detect and run whichever of `ty` and `pyright` the project configures, and fail if either does.
- **Ruff (`dev-run-ruff` / `dev-run-ruff-format`)**: Fast linting, and separately, in-place formatting. Lint mode rejects writing flags and removes inherited `RUFF_OUTPUT_FILE`.
- **Polyglot gates**: `dev-run-eslint`, `dev-run-prettier` (verification only, never `--write`), `dev-run-clippy` (may write generated `target/` artifacts, runs with `--locked`, and refuses `--fix`), `dev-run-shellcheck` (ShellCheck for sh/bash plus `zsh -n` for `.zsh`), `dev-run-markdownlint`, and `dev-run-tflint`.

> [!IMPORTANT]
> `dev-run-markdownlint` only checks by default. Pass `--fix` when you actually
> want Markdown files rewritten.

`dev-run-tflint` similarly keeps its remote-code effect explicit. Its default
mode only runs recursive linting; `--init` is required to download or initialize
plugins, and that step asks for confirmation. Use `--init --yes` only when the
configuration is trusted and the command must run non-interactively.
Pyright refuses `--createstub` so its public check remains read-only.

Bandit and ShellCheck share one NUL-safe collector that prunes generated trees
and nested repositories, fails on discovery errors, limits the inventory to 512
files, and calls each backend in batches of at most 64 paths.

Each gate resolves its backend in a fixed order. A declared Python dependency
must exist in the exact project `.venv`, as an isolated runnable module or a
proven in-environment executable; it never falls through to `PATH`. Only an
undeclared Python tool may use an installed binary and then opt-in `uvx`. Node
gates use `node_modules/.bin`, then an installed binary, then opt-in `npx`.
Falling back to `uvx`/`npx` downloads and executes remote code, so it requires
`export DEV_ALLOW_EPHEMERAL=1` and the corresponding runner executable. A
project-local `node_modules/.bin` entry avoids the `npx` fallback, but remains
project-controlled executable code rather than an integrity guarantee.

Quality gates, pytest, configured hooks, and package builds can load or execute
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

- **Preview Updates (`dev-update-deps-dry`)**: See exactly which `>=` specifiers would change, writing nothing.
- **Update Dependencies (`dev-update-deps`)**: Build a private candidate `pyproject.toml`, show its summary and diff, then confirm before changing the live project. Changes target actual dependency strings, including several requirements on one line, literal quotes, normalized names, extras, and repeated declarations; comments and unrelated metadata remain intact. Publication requires an exact invocation-owned backup and re-locks *only the bumped packages*. A lock failure restores and verifies that backup and its original mode; a later sync failure leaves the updated metadata and lockfile in place and reports a possibly partial environment. Compound constraints and environment markers are left alone, and a newer minimum is never downgraded. Filter with `--major-only`, `--minor-only`, or `--patch-only`; skip the prompt with `--yes`.
- **Update Lockfile Only (`dev-update-lock`)**: Refresh `uv.lock` and sync without touching `pyproject.toml`.
- **Update Pre-commit (`dev-update-precommit`)**: Update the package specifier when PyPI is reachable, then synchronize the project and plan `autoupdate --freeze` against a private hook candidate. If PyPI is unavailable, the package query is reported as incomplete while the configured package and hook backends still run. An updater failure such as an incompatible hook can leave usable proposals from other repositories: ZDX keeps those changes only after validating the complete candidate and installing every planned hook environment, including `commit-msg` and `pre-push` hooks. A Git transport failure can stop upstream before it produces any candidate, so recovery depends on what the updater leaves. The guard preserves existing immutable revisions when proposals are older, incomparable, or move the same tag; interrupted autoupdates are never published. Git receives a native HTTP stall limit using `DEV_PYPI_TIMEOUT`; this is not a total workflow or SSH timeout. After atomic publication, ZDX reinstalls Git hooks and runs applicable file-stage hooks through the exact project `.venv`. Findings and incomplete updates return status `1` with retry guidance, while validated revisions remain published. A concurrent live-config edit is preserved and the original snapshot retained for comparison.
- **Update Toolchain (`dev-update-python`, `dev-update-toolchain`)**: Delegate host `uv` maintenance to `sys-menu update-uv-system` without invoking ambient Python or `pip`, or safely replace an existing project `.venv`. Replacement requires `pyproject.toml` and `uv.lock`, validates the existing path, shows the plan, and confirms before any mutating uv call. A sole simple `X.Y` project pin selects that minor; without a pin, ZDX derives the current `.venv` minor. Multiple, exact `X.Y.Z`, complex, or ambiguous pins are refused before mutation and delegated to `dev-menu venv-python-pin <major.minor>`; a non-CPython `.venv` is also delegated because the automatic transaction supports CPython only. The command fingerprints `pyproject.toml` and `uv.lock`, rechecks them plus the interpreter implementation/version and pin selection after consent, and validates the inputs again before install, before locked sync, and after sync. ZDX runs `uv python install --upgrade X.Y`, builds a private same-filesystem environment with `uv venv --clear --managed-python --python X.Y --relocatable <staged>`, synchronizes it through `UV_PROJECT_ENVIRONMENT=<staged> uv sync --all-groups --locked`, verifies that the staged interpreter is CPython in the requested minor, and then swaps directories. Standard console entrypoints and activation scripts remain valid after publication and staging cleanup; arbitrary package scripts and binaries retain their own relocation limits. A publication failure restores the exact original when safe; an unverifiable failure or interrupt retains a reported recovery workspace. Without `.venv`, Dev performs no runtime mutation and forwards to `py-menu venv-python-install`, which owns version selection, preview, and authorization. `--yes` skips its confirmation but not the version selector; unattended callers use `dev-menu venv-python-install VERSION --yes`. Installing or upgrading a global uv-managed Python remains an external effect that ZDX cannot roll back.
- **Inspect Terraform / TFLint ownership (`dev-update-terraform` / `dev-update-tflint`)**: Both commands are read-only owner inspections. Terraform reports a proven `tfenv`, Homebrew, or APT owner; otherwise it labels the active binary manual and prints a reproducible update path. It never executes the dynamic `tfenv install latest` path. Every claim is tied to the canonical active executable; tfenv also requires resolved sibling launchers and ignores inherited `TFENV_ROOT`, so a separately installed package cannot claim another binary earlier in `PATH`. TFLint never invokes Homebrew from the Developer suite. An unproven manual TFLint installation gets the verified download procedure and a failure status.

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
metadata or content changed while rollback was staged. Run restore, export, and
update only after their direct write directory passes owner, identity, and
safe-write-mode validation. A group/world-writable directory without sticky
protection is refused.

### 📦 Packaging & Export

- **Export Dependencies (`dev-export-deps`)**: Write `requirements.txt` format from project metadata and the lockfile through `uv export --locked`. The default uses `--no-default-groups` for production only; `--dev` selects exactly the `dev` group without defaults, and `--all` selects every group. Choose a destination with `--output=FILE` or `-o FILE`. There is deliberately no `uv pip freeze` fallback, because an active environment can contain undeclared packages. The locked export refuses resolution rather than updating `uv.lock`. ZDX fingerprints destination metadata and content, holds that inode open while authorization is pending, writes the private temporary through its own held descriptor, and compares path and descriptor fingerprints before publication. In-place edits and replacement races are refused. An absent destination uses atomic no-clobber publication; an authorized existing destination uses identity-checked atomic replacement.
- **Build Package (`dev-build-package`)**: Run the project-selected PEP 517 backend through `uv build` or isolated `python3 -I -m build`, writing a wheel and sdist. Build backends are project-controlled code; isolated `build-system.requires` dependencies may be resolved and executed outside `uv.lock`.
- **Backup pyproject.toml (`dev-backup-pyproject`)**: Store a timestamped, owner-only copy before a risky edit. Retention always preserves the backup made by the current invocation despite clock skew or manipulated mtimes, plus the newest `DEV_BACKUP_RETENTION - 1` prior copies (default total: 5).

### 🐍 Python Environments

The nine `venv-*` entries are forwarded to `py-menu`, which owns the
environment lifecycle. They appear here for discoverability only. Poetry
creation and environment rebuild currently expose reviewed fail-closed plans;
runtime listing shows installed uv-managed versions, removal targets one
fingerprinted environment, and pinning writes only the reviewed project pin.

### 💾 Task Profiles

- **Save Profile (`dev-profile-save <name>`)**: Mark tasks with Tab and store them as a reusable named profile. The picker is generated from the live menu, so it can never drift out of date.
- **Run Profile (`dev-profile-run [name]`)**, **List (`dev-profile-list`)**, **Delete (`dev-profile-delete [name]`)**.

Profiles run sequentially through the same allowlist the menu uses, so a stored
entry that is unknown, argument-bearing, nested, or otherwise not
batch-eligible is reported rather than executed. Eligible tests and compilers
can still execute project code and create documented artifacts. Profile
directories and files are private;
save and run revalidate their ownership, type, link count, mode, size, task
count, and identity. The inventory is limited to 100 profiles; each file may
contain at most 8,192 bytes and 64 tasks. The whole profile is validated before
its first task runs.

### 🧹 Cleanup

All cleanup commands compute the exact target set first, show the plan, and only
then ask for confirmation:

- **Clean Python (`dev-clean-py`)**: `__pycache__`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `*.egg-info`, and compiled files, plus root-level `.coverage`, `.coverage.*`, `htmlcov/`, `build/`, and `dist/`; `--keep-build` preserves the build directories.
- **Clean Repository (`dev-clean-repo`)**: Zone.Identifier files, `.DS_Store`, AppleDouble forks, `Thumbs.db`, and `desktop.ini`.
- **Clean Terraform (`dev-clean-terraform`)**: `.terraform` directories, plan files, crash logs, and state backups. `.terraform.lock.hcl` is always preserved.
- **Clean Everything (`dev-clean-all`)**: One combined plan across all of the above plus root-level Cargo `target/`, confirmed once. `--keep-build` preserves root `build/`, `dist/`, and `target/`.
- **Full Maintenance (`dev-update-all`)**: Freeze and show the applicable scope before authorization: host toolchain, dependency specifiers (`pyproject.toml`), lockfile refresh (`uv.lock`), pre-commit hooks (`pyproject.toml` plus `.pre-commit-config.yaml`), installed Terraform and TFLint ownership inspections, and cleanup. Missing project files make a step inapplicable, including during dry-run. Each step checks its own backend, so missing `uv` does not block infrastructure inspection or cleanup. One PyPI probe is reused within the run: failure blocks specifier queries, while lockfile and hook updates still try their own backends and caches. A decline starts no step. Interactive cleanup later shows and confirms its exact targets; `--yes` authorizes both prompt boundaries. The final summary records partial failures and gives direct `dev-menu` commands for retrying only pending steps. Pre-commit is skipped if the dependency update left project metadata and the lockfile inconsistent and the lockfile refresh could not recover.

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

For `dev-update-all`, dry-run invokes only the dependency-update and cleanup
previews, skipping the dependency preview without `pyproject.toml`; no
toolchain, hook, Terraform, or TFLint workflow is started. A normal
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
| `DEV_BACKUP_DIR` | `.dev-suite-backups` | Where `pyproject.toml` backups are stored |
| `DEV_PROFILE_DIR` | `.dev-suite-profiles` | Where task profiles are stored |
| `DEV_REPORT_DIR` | `dev-suite-reports` | Where `--report` output is written |
| `DEV_BACKUP_RETENTION` | `5` | Backups to keep; integer `1`–`100` |
| `DEV_CLEAN_DEPTH` | `12` | Cleanup discovery depth; integer `1`–`64` |
| `DEV_CLEAN_MAX_TARGETS` | `10000` | Unique cleanup targets; integer `1`–`50000` |
| `DEV_SCAN_DEPTH` | `3` | Stack-detection depth; integer `1`–`32` |
| `DEV_PYPI_TIMEOUT` | `15` | Per-request seconds; integer `1`–`300` |
| `DEV_PYPI_RETRIES` | `2` | Retries per query; integer `0`–`10` |
| `DEV_PYPI_JOBS` | `8` | Concurrent prefetch jobs; integer `1`–`32` |
| `DEV_SUITE_DEBUG` | `0` | Verbose diagnostics on stderr |

State directories are owned mode `700`; state, report, profile, backup, cache,
and export temporaries are mode `600`. Publication is atomic and revalidates
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
dependencies; each PyPI response is limited to 20 MiB and both license table
and JSON streams to 10 MiB.

---

## ── Network Suite (`net-menu`) ──

The Network suite provides bounded read-only local and remote diagnostics.
Public commands render human output on stderr; private collectors validate
typed data before it is displayed.

### 📊 Diagnostics Dashboard

- **Dashboard (`net-dashboard`)**: Continue across independent route,
  interface, DNS, latency, and public-IP sections even when one is unavailable.
  Use `--local-only` to make no ICMP, DNS, or public-provider request.

### 🌐 Footprint Geolocation & Multi-Provider IP Cross-check

- **Public exit (`net-public-ip`)**: Query a fixed HTTPS provider cascade with
  strict redirects, connection/total deadlines, response limits, and semantic
  IP validation.
- **Cross-check (`net-public-ip --cross-check`)**: Explicitly contact every
  applicable fixed provider sequentially to compare exit addresses. Each
  provider necessarily observes the caller's address; no credential or
  authorization header is sent by ZDX.

### 💻 Local Adapter Statistics

- **Interfaces (`net-interfaces`)**: Inspect a bounded Linux sysfs inventory
  with `ip` augmentation, or a bounded `ifconfig` fallback when supported.

### ⚡ Interactive Latency & Resolver Testing

- **Latency (`net-ping`)**: Send between one and twenty deadline-bound probes
  to a validated hostname or IP literal.
- **DNS (`net-dns`)**: Query bounded A, AAAA, and MX records through `dig` or
  `host`.
- **Throughput (`net-speedtest`)**: Review an installed speed-test backend or
  the fixed 10 MiB Cloudflare HTTPS fallback. `--dry-run` sends no traffic;
  actual transfer requires terminal confirmation or `--yes`.

All subprocess output is byte-bounded before parsing. Direct timeout statuses
remain distinguishable, and `fzf` runs in the terminal foreground. See
[`net-menu.md`](net-menu.md) for provider privacy, platform capabilities, and
manual real-network acceptance.

A domain may have address records without MX records. A failed ping can still
show its validated packet summary while returning failure. Interruptions stop
remaining providers and dashboard sections. Throughput without a reliable
elapsed-time measurement reports its rate as unavailable.

---

## ── GPU Suite (`gpu-menu`) ──

The GPU suite provides validated NVIDIA telemetry. Hardware mode requires
`nvidia-smi` plus `timeout` or `gtimeout`; every probe has a three-second
deadline.

### 📊 Real-Time NVIDIA Visualizer

- **NVIDIA GPU Visualizer (`gpu-visualizer`)**: Launch a live visual dashboard
  with `gpu-visualizer [--once] [--simulate] [--gpu INDEX]`:
  - **Memory Allocation (VRAM)**: Visual bar representation of active memory usage versus total capacity.
  - **Thermal & Hardware Health**: Real-time core temperatures with safe/warn/critical threshold color mappings, and fan speed percentages.
  - **Power Consumed**: Instantaneous wattage draw.
  - **Process Occupancy Table**: Lists active process names, PIDs, and exact VRAM allocations on the graphics hardware.
  - **Explicit Simulation**: `--simulate` uses clearly labelled synthetic
    metrics. Missing hardware never activates simulation automatically.
  - **Foreground Safety**: Continuous refresh runs only while stdin and stderr
    identify the same usable foreground terminal; redirected or background
    starts render one frame without terminal-clearing control sequences, and a
    later loss of foreground ownership exits without suspending the shell.

All visualizer output goes to stderr. See [`gpu-menu.md`](gpu-menu.md).

If process inspection fails while GPU metrics remain valid, the metrics stay
visible and the process table is marked unavailable. Continuous mode retries
on the next frame. `--once`, or quitting the monitor, returns the most recent
frame's status; a later successful frame clears the partial failure.

---

## ── Hugging Face Suite (`hf-menu`) ──

The Hugging Face suite searches the Hub, renders repository metadata, downloads
explicit targets, and manages one exact local cache entry. It requires an
already-installed `huggingface_hub` from version 0.23 through the 1.x series.
Set `HF_PYTHON` to choose its interpreter. ZDX never installs the backend
implicitly.

### 🔎 Hugging Face Hub Explorer

- **Search (`hf-search`)**: Search models or datasets with a validated query
  and a limit from 1 to 100. The complete unique result batch and its numeric
  counters are validated before `--list` emits bounded TSV data on stdout.
- **Statistics (`hf-repo-stats`)**: Render downloads, likes, author, update
  time, tags, commit identity, and gated state on stderr.

### 📦 Local Cache Management

- **Inspect (`hf-cache-inspect`)**: Render a bounded inventory, or use
  `--list` for TSV records. Space caches are ignored by this model/dataset
  surface rather than invalidating the inventory.
- **Clear (`hf-cache-clear`)**: Select or name one repository, review its exact
  owned path below the independently resolved configured Hub cache root, and
  use `--dry-run` or confirm the deletion. The target is revalidated against
  its expected cache name and quarantined before recursive removal; an
  incomplete or interrupted removal reports its recovery path.

### 📥 Direct Downloads

- **Download (`hf-download`)**: Direct mode requires either `--snapshot` or
  `--file FILENAME`; it never assumes a full snapshot. Metadata probes are
  timeout-bounded. Interactive file discovery streams at most 4,096 tree
  records and accepts at most 2,000 files, while an authorized large transfer
  is allowed to complete.

UI is stderr-only. Structured stdout exists only for the two explicit `--list`
modes. See [`hf-menu.md`](hf-menu.md) for exact grammar and cache limits.

Downloads show an immediate start message and a fixed activity notice every
five seconds. This indicates that the backend is still running, not measured
byte progress. Completion requires a readable result on disk. Failures show
access, network, target, or storage guidance and an exact retry command;
existing cache data is retained for the backend to reuse where possible.

---

## ── Dependency Doctor (`zdx doctor` / `zdx-doctor`) ──

The Dependency Doctor checks required and optional tools, reports display
settings, and offers a platform-aware installer with explicit confirmation.

### 🔍 Diagnostic Scans

When you run the doctor, it groups system requirements into three categories:

- **Core Requirements**: Fundamental tools required for ZDX core operations (e.g., `fzf`, `git`, `jq`).
- **Optional Suite Requirements**: Specialized tools associated with advanced suites (e.g., `docker`, `gh`, `wg-quick`, `uv`, `pipx`, `nvidia-smi`).
- **Operational Capabilities**: Alternative or semantic requirements that are
  not one package token: `timeout` or `gtimeout`, `findmnt`, the active command
  resolving to GNU `tar`, and an installed compatible `huggingface_hub`.

For each tool, the doctor displays:

- Its presence (Installed with version vs. Missing).
- Its installation path (if present).
- The associated ZDX suite that relies on it (if missing).

Its rendering diagnostics report the terminal, color/plain mode, whether a
theme or inherited fzf options are configured, and the loaded doctor's source
path. Theme and fzf option values are not printed, and option files are not
read. The fzf version probe isolates inherited fzf defaults; failed or malformed probes are
reported as version-check failures, and interruptions stop later diagnostics.

### 🛠️ Platform-Aware Interactive Installer

If missing dependencies are detected, the doctor identifies your active Operating System (Linux, macOS, or WSL) and your system package manager (`brew`, `apt-get`, `dnf`, `pacman`, `apk`).

- **Opt-in Installation**: It lists the exact command it intends to run and asks for your confirmation before executing anything.
- **Official Documentation**: If your package manager doesn't support a specific binary, or if you decline the installation, it prints the official installation link or setup instructions.
- **No implicit Python bootstrap**: The doctor reports a missing or incompatible
  Hugging Face backend but does not install it, run an ephemeral environment,
  or add operational capabilities to the batch package transaction.
- **Safety First**: It never runs commands in the background without explicit verification.

### ⚡ Quick Reference Commands

- `zdx doctor` — Run the dependency diagnostics and installer assistant.
- `zdx-doctor` — Direct function wrapper for the doctor assistant.

---

## ── Workspace Suite (`ws-menu`) ──

The Workspace suite manages isolated Git identities, SSH aliases, repository
placement, and workspace-wide maintenance. Its public surface is frozen at 15
commands; see [`ws-menu.md`](ws-menu.md) for the complete contract and residual
safety limits.

Every command is registered for lazy loading, so both forms work from a cold
shell:

```zsh
ws-menu                              # interactive command menu
ws-menu ws-list                      # explicit direct routing
ws-list                              # equivalent direct command
ws-menu ws-clone owner/repository
ws-menu ws-remove --dry-run github/personal
```

`ws-menu --help` is the canonical command inventory, and every command also
answers `-h|--help` directly with one usage line and description. Unknown
options, unexpected operands, and unknown commands return status `2` before
any dependency or workspace probe, and arguments after the command are
forwarded unchanged. Help and all feature-command UI, prompts, and errors use
stderr. Workspace does not currently expose a documented stable data-output
mode, so do not parse its formatted displays as an interface. Completion
offers `-h/--help` for every command plus the implemented `ws-remove` flags
and validated workspace candidates contextually.

### 👤 Identity Model and Managed Layout

Every workspace has the exact form `github/<identity>` or
`gitlab/<identity>`. An identity begins with a letter or number and then uses
letters, numbers, dots, underscores, or dashes.

The default root is `$HOME/workspaces`:

```text
$WS_BASE_DIR/<platform>/<identity>/
├── .gitconfig
├── .ssh/
│   ├── id_ed25519
│   └── id_ed25519.pub
├── .ws-hostname          optional custom GitLab host
└── <repository>/
```

ZDX adds one matching Host block to `~/.ssh/config` and one Git
`includeIf` entry to `~/.gitconfig`. Repositories below that workspace then use
the workspace-local Git name, email, optional signing key, and SSH alias.

The workspace root must be absolute and canonical. ZDX refuses an empty root,
`/`, the home directory itself, `.` or `..` traversal, and any symbolic-link
component. The check happens before creation opens a picker and before removal
selects or deletes a target.

### 🔎 Inspection and Authentication

- `ws-auth` checks key presence, optional GitHub CLI authentication, and every
  configured SSH route.
- `ws-list` shows all configured workspaces, identities, repository counts,
  key state, and optional GitHub CLI state.
- `ws-info` selects one workspace and displays its directory, identity, key
  fingerprint, routing state, and repositories.
- `ws-doctor` checks configuration files, key permissions, Host aliases, Git
  includes, and repository remote alignment.
- `ws-repos` shows each repository's branch, dirty count, and origin.

Repository URLs displayed by `ws-info`, `ws-doctor`, `ws-repos`, and
`ws-migrate` redact URL credentials and remove query strings and fragments.
Authentication summaries never display tokens or private-key contents.

### 🏗️ Creation and Cloning

`ws-create` is an interactive five-step workflow:

1. choose GitHub or GitLab and, for GitLab, an optional custom hostname;
2. choose the workspace identity;
3. select a configured Git identity or enter a name and email;
4. generate an Ed25519 key or import an owned non-symlink key from `~/.ssh`;
5. publish the workspace files and routing entries.

Private keys and configuration files created by the workflow use mode `600`,
the workspace `.ssh` directory uses `700`, and the public key uses `644`.
Cancellation during key selection occurs before workspace files are created,
and unexpected picker failures are not treated as cancellation. Existing
global SSH and Git configuration files are fingerprinted and each rewrite is
published atomically. Workspace creation is still not one all-or-nothing
transaction: a late failure can leave some workspace files or one routing
configuration update published. Review `ws-doctor` after a failed creation
before retrying.

Creation checks an existing SSH alias before writing workspace files. It
reuses only a compatible route to the expected host and key. Conflicts or
configuration that cannot be checked passively, including `Include` and
`Match`, require reviewing `~/.ssh/config` first.
This check covers that user file; system SSH configuration and effective
connection routing still need separate verification.

Clone one repository with:

```zsh
ws-clone owner/repository
ws-clone https://github.com/owner/repository.git
ws-clone git@github.com:owner/repository.git
```

The input is normalized to `owner/repository`, validated component by
component, and cloned through the selected workspace alias. The destination
must not already exist. A failed clone returns non-zero and never prints a
success result.

`ws-clone-multi [REPOSITORY...]` clones a list sequentially. With no operands,
it can accept pasted lines or, when authenticated `gh` is available, select
repositories from a GitHub organization or user. It shows the list, asks once,
counts cloned, skipped, and failed entries, and returns non-zero when a clone
failed. A partial clone remains available for inspection; later clones still
run if the workspace identity and permissions remain unchanged. An interruption
stops the remaining entries and reports them as not run.
Cloning retrieves code but does not establish that the origin is
trusted; review it before running hooks, installers, or project tasks.

### 🔄 Synchronization

`ws-sync` fetches and prunes every direct-child repository in one workspace.
For an update candidate it freezes the current branch, HEAD object ID, upstream
ref, and fetched upstream object ID. It revalidates that snapshot and the clean
worktree immediately before
`git merge --ff-only -- <fetched-upstream-object-id>`, then checks that HEAD
reached the planned object. The mutable upstream ref is not used as the merge
operand, and the command does not start a second network pull. Detached,
upstream-less, ahead, and diverged repositories are left for explicit handling.

For dirty behind repositories, the optional stash workflow restores only the
stash object created by that invocation and revalidates the branch/upstream
snapshot around stashing, fast-forwarding, and restoration. It never runs a
generic `git stash pop`. It also deliberately keeps the exact recovery stash
after a successful `stash apply --index`, because selector-based deletion can
race a concurrent stash push. Verify the restored worktree before removing that
stash manually. A restore conflict preserves it and makes the command fail.

The command can also offer to check out newly discovered remote branches. These
are interactive mutations; `ws-sync` does not currently implement
`--dry-run` or `--yes`.

### 🔑 SSH Keys and Connection Tests

- `ws-show-key` displays and optionally copies only the public key.
- `ws-rotate-key` generates and validates a new Ed25519 pair in private staging
  before backing up the active pair, installs the replacement, and attempts to
  restore the old pair if publication fails. It can prune older complete safe
  backup pairs after a second confirmation.
- `ws-test` checks the selected alias with `BatchMode=yes`, no password
  prompts, strict host-key checking, and a bounded connection attempt.

`WS_SSH_CONNECT_TIMEOUT` defaults to 10 seconds and accepts integers from 1
through 60. Because strict host-key checking is enabled, a new or changed host
key fails visibly instead of being trusted automatically.

### ⚠️ Migration and Destructive Maintenance

`ws-remove` is the only Workspace feature command with suite-owned flags:

```zsh
ws-remove --dry-run github/client
ws-remove --yes github/client
ws-remove --help
```

The dry run names the exact SSH Host block, Git `includeIf` entry, canonical
directory, and repository count. Without `--yes`, type the exact workspace
name. `--yes` skips only that prompt: path boundaries, ownership checks, and
target revalidation still run. Existing SSH and Git configuration files are
frozen by bounded content and metadata fingerprints; each rewrite is staged
privately and published with a same-directory atomic rename. Malformed SSH
markers or a Git-config parse failure stop the removal rather than publishing
an uncertain rewrite or deleting the workspace.

The workspace is revalidated, renamed to a random quarantine sibling, and
verified there before recursive deletion. If deletion fails, ZDX restores the
remaining data to the original path when safe; otherwise it reports the
quarantine path for recovery.

`ws-migrate` is interactive. It accepts one absolute, canonical, non-symlink
source directory that is neither `/` nor your home, selects direct-child Git
repositories with real non-symlink `.git` directories, and fingerprints the
source, target, repository, and Git-directory identities. Source and target
must be on the same filesystem; a device mismatch is refused before any move.
It then moves selected repositories into the validated workspace and can
rewrite origins to the workspace alias. Existing destinations are skipped.
A remote rewrite failure leaves the repository moved and returns a partial
failure. An unreadable origin is reported as a failure, and a rewrite is
checked before success is announced. Interrupting origin inspection or
rewriting stops the remaining moves; ordinary failures allow independent
repositories to continue. Deleting an emptied source is a separate confirmation and uses
`rmdir`.

`ws-autoclean` fetches/prunes repositories, offers branches that appear merged
or whose upstream is gone, protects the current and detected default branches
plus `main` and `master`, and freezes each selected branch object ID. After
confirmation it rechecks stale state, object identity, repository identity, and
all linked worktrees. Deletion uses an expected-object `git update-ref`, so a
branch repointed concurrently is preserved. A final worktree check can restore
the exact prior object if the branch became active during the deletion window.
Any uncertainty returns non-zero.

Migration, branch cleanup, and key rotation do not yet support `--dry-run` or
`--yes`. Run them only interactively after reviewing their displayed targets.

### ⚙️ Configuration

Set these in `~/.config/zdx/config.zsh`:

| Variable | Default | Effect |
| :--- | :--- | :--- |
| `WS_BASE_DIR` | `$HOME/workspaces` | Validated root for managed workspace profiles and repositories |
| `WS_SSH_CONNECT_TIMEOUT` | `10` | `ws-test` SSH connection deadline; integer `1`–`60` |

## ── AI Suite (`ai-menu`) ──

The AI suite provides a frozen 28-command interface for local assistant
diagnostics, recoverable cache quarantine, project instruction bootstrap,
private configuration snapshots, redacted log excerpts, passive MCP audits,
and reviewed updates of installed assistants. Run `ai-menu` interactively or
invoke a command directly.

### 🧹 Recoverable cache quarantine

`global-clean-ai` and its assistant-specific variants show a bounded plan and
require confirmation before moving eligible targets to the private
`~/.local/share/zdx/ai-trash` quarantine. Durable conversations, tasks, todos,
plans, sessions, prompts, skills, Cursor installation/project state, and Amp
recovery state are never selected. This removes paths from active tool
locations but does not reclaim disk. Each entry records its original path in
a private `.zdx-origin` file for manual recovery; quarantine has no automatic
purge.

`project-sweep-ai` accepts one canonical owned root inside `HOME` and searches
only recognized assistant-owned debug, log, cache, and temporary directories.
Name-only lookalikes are excluded. `--xdev` constrains discovery, while
independent mount and device checks fail closed before relocation.

### 🔌 Passive MCP audits and reviewed CLI updates

`ai-mcp-list` and `ai-mcp-doctor` parse bounded Claude, Antigravity, and Cursor
declarations as untrusted data. They resolve a local command's availability
without executing it and report remote transports without contacting or
printing their URLs or headers. Claude user/local declarations come from
`~/.claude.json`; the current project's shared declarations come from
`.mcp.json`. Antigravity uses `~/.gemini/config/mcp_config.json` globally and
`.agents/mcp_config.json` in a workspace; `.gemini` is its current
vendor-defined storage directory for those official Antigravity files.
`ai-mcp-update` is retained as an audit-only compatibility name.

`ai-update` updates every eligible installed Claude, Codex, Antigravity,
OpenCode, Cursor, Copilot, Amp, and Hermes CLI through its fixed official
self-updater action. Individual `ai-update-*` commands narrow the plan to one
tool. The executable path, current version, and exact action are displayed;
`--dry-run` invokes no updater, while execution requires confirmation or `--yes`.
Missing tools are skipped and an unprobeable or changed executable fails
closed. If a supported Node CLI is hidden behind a lazy NVM alias, ZDX reads
only a protected, exact `~/.nvm/alias/default` version and invokes that
version's validated executable and Node runtime; it never executes the wrapper,
loads `nvm.sh`, or scans older installed versions. These commands authorize
vendor-managed remote code targeting the latest release. Use
`--skip-homebrew-managed` when Homebrew owns those paths.
Cursor and Amp version checks redirect only their incidental runtime cache to
a private temporary probe directory; they do not change `HOME` or persistent
assistant state. Failed updaters suppress potentially sensitive vendor output
while distinguishing authentication, other vendor preconditions, and generic
updater failures. ZDX suggests an explicit next step but never logs in or
reinstalls a CLI automatically. After a successful self-updater, ZDX compares
the bounded pre/post version and validated executable fingerprint. A changed
version or executable counts as `updated`; `already current` requires both to
remain unchanged. The final AI summary reports updated, already-current,
failed, and skipped tools separately.

Hermes version discovery uses `--version`. If its later update-status lookup
times out after printing a valid installed-version banner, that version remains
usable for the update plan. The vendor version command may fetch update
metadata and write its own `.update_check` cache, including during a dry run.
The probe keeps its deadline and output limits and never starts the updater.
OpenCode's known `Upgrade failed` result is treated as failure even when its
process returns success; other assistants can still continue. An interrupted
updater stops remaining updates, preserves status `130` or `143`, and leaves a
complete result ledger identifying the tools that did not run. Skipped tools
alone do not make an all-failed update count as partial success.

### ⚡ Configuration, diagnostics, and logs

- `ai-config-backup` creates a private checksum-manifest snapshot of a small
  exact allowlist; `ai-config-restore [SNAPSHOT]` restores per file with
  no-clobber publication and an existing-file rollback link. Omit the token,
  or choose the menu entry, to pick one validated snapshot interactively; Esc
  cancels without touching any file, and Tab completion offers the same
  tokens.
- `ai-init-agents` creates `AGENTS.md` plus the `CLAUDE.md` compatibility link;
  Antigravity reads `AGENTS.md` directly, so no legacy instruction link is
  created.
- `ai-doctor`, `ai-disk-usage`, and `ai-versions` use bounded local probes.
  Disk usage includes the snapshot and quarantine roots, and OpenCode roots
  follow an absolute `XDG_CONFIG_HOME` or `XDG_DATA_HOME` consistently across
  commands. `ai-versions --json` emits one documented record per assistant.
- `ai-log-tail` discovers a bounded eligible inventory and prints a finite,
  control-escaped excerpt. Credential-indicator lines and partial first lines
  from a byte window are redacted or discarded; output remains sensitive.

See [`ai-menu.md`](ai-menu.md) for exact options, status behavior, trust
boundaries, and platform limits.

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

- **Interactive Manager (`zdx-plugins` or `zdx plugins`)**: Opens a beautiful, dedicated FZF control screen to view, install, update, or safely uninstall custom plugins.
- **Install Plugin (`zdx-plugins --install <git-url> [custom-name]`)**: Clones a structurally compliant Git repository, checks its entrypoint and Zsh syntax, and registers it. Review and trust the URL before invoking this command; the structural checks do not prove safety.
- **Update Plugins (`zdx-plugins --update [name]`)**: Pulls the latest commits from upstream git origins and hot-reloads plugin contexts.
- **Uninstall Plugin (`zdx-plugins --remove <name>`)**: Safely purges directories and cleans active function scopes under an explicit confirmation gate.

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
