# Changelog

This document records user-visible changes by release. The `0.1.0` entry
describes the complete initial release: its implemented behavior,
verification, and remaining limitations.

## [0.1.0] — 2026-10-07

### Overview

ZDX (Zsh Developer Experience Suite) is a modular, `fzf`-powered toolkit and
custom plugin loader for Zsh. Version `0.1.0` provides 120 public commands
across eight interactive suites for workspaces, Git, Python projects, the host
system, files, the shell environment, Python environments, and WireGuard VPN.

- Production code is Zsh-first and integrates with Oh My Zsh through
  `zdx-suite.plugin.zsh`; direct sourcing from `.zshrc` is also supported.
- The `zdx` launcher routes through an explicit suite allowlist to the eight
  suites, the status dashboard, the dependency doctor, plugin management, and
  validated user plugins.
- Every suite supports direct command routing in addition to its interactive
  menu, and command-specific completions cover every suite and the launcher.
- Linux, WSL, and macOS are supported on the same code paths, with
  capability checks where the platforms differ.
- Project metadata and `zdx --version` report `0.1.0`.

### Suite catalog

| Suite | Commands | Scope |
| --- | ---: | --- |
| Workspace (`ws-menu`) | 3 | Navigation across the `$WS_BASE_DIR/<platform>/<identity>/<repository>` layout, staged clones with identity delegation, and read-only multi-repository status |
| Git (`git-menu`) | 21 | Repository context, local changes (stash manager, unstage, amend, undo, discard), branch switching and commit recovery, pull and fetch, pushes and tags with remote leases, GitHub pull requests, identities and identity checks, and branch cleanup |
| Developer (`dev-menu`) | 25 | Python and Terraform project health, quality gates, tests and coverage, security audits, dependency, lockfile, pre-commit, Python, Terraform, TFLint, and GitHub Actions updates, and bounded cleanup |
| System (`sys-menu`) | 25 | Host information and health, a WSL configuration review, services, processes, ports, package and toolchain updates, cleanup, shell startup timing, and telemetry |
| VPN (`vpn-menu`) | 22 | WireGuard profiles, connection state, protected editing, validated imports, private state, diagnostics, a path MTU probe, and WSL DNS leak protection |
| Python (`py-menu`) | 16 | Project-local virtual environments, uv-managed runtimes, project packages, PyPI inspection, and isolated `uv tool` or `pipx` applications |
| File (`file-menu`) | 5 | Staged archive creation, fail-closed TAR extraction, large-file inspection, a recoverable trash, and junk-file cleanup below the current directory |
| Environment (`env-menu`) | 3 | Masked variable inspection, an explicit, reviewed `PATH` deduplication, and a value-free dotenv key and hygiene check |

### Suite highlights

- Workspace suite (`ws-menu`, `zdx ws`) with three commands that own the
  `$WS_BASE_DIR/<platform>/<identity>/<repository>` layout. `ws-jump`
  changes the current shell to a repository through a picker whose preview
  receives only a row index.
  `ws-clone` validates `https://`, `ssh://`, and `user@host:path` URLs,
  infers the platform and identity, uses the workspace SSH alias when it
  resolves to the URL's host, clones through a private staging directory
  without replacing anything, and applies the matching profile through
  `git-menu git-identity-switcher`. `ws-status` reports branch, changes,
  ahead/behind, stashes, and last commit for every repository from local refs,
  with an opt-in, disclosed, bounded `--fetch` and a `zdx.ws-status.v1` JSON
  document. Discovery prefers `fd`, falls back to `find`, and honors
  `WS_MAX_DEPTH`, `WS_EXCLUDE`, and `WS_FETCH_JOBS`; `zdx-doctor` reports `fd`
  as an optional capability. See [`docs/ws-menu.md`](docs/ws-menu.md).
- `git-switch [BRANCH|-] [--stash|--carry] [--dry-run|-y|--yes]` switches to
  an existing local branch, the previous branch, or a branch that exists only
  as a remote-tracking ref, creating just its local tracking branch at the
  reviewed commit. Without BRANCH, a picker lists local branches before
  remote-only ones with their last-commit date and upstream counts. Operations
  in progress, branches checked out in another worktree, and untracked or
  ignored files the target would overwrite are refused. A dirty tree needs a
  reviewed plan and a choice: carry the changes when the target leaves them
  alone, or stash them as `zdx git-switch: <from> -> <to>` first.
- `git-recover [--deep] [--dry-run|-y|--yes]` restores a commit that no
  branch, remote-tracking branch, or tag reaches, from the HEAD and branch
  reflogs or, with `--deep`, from a bounded `git fsck`, only by creating a new
  `recover/<short-sha>` branch; no existing ref is moved or deleted.
- `git-identity-check [--json|--quiet]` compares a repository below
  `$WS_BASE_DIR/<platform>/<identity>` with its `ZDX_GIT_IDENTITIES` profile
  (email, signing key, format, and commit signing, and the SSH key that
  `core.sshCommand` selects) without printing key material, and names the
  `git-identity-switcher` command that fixes a mismatch.
- `ZDX_GIT_IDENTITY_GUARD=1` registers an opt-in `chpwd` hook that runs that
  check once per repository and shell session and warns about a mismatch; it
  is off by default and never prompts or fails a directory change.
- `env-dotenv [FILE] [--example FILE] [--json]` compares a dotenv file
  (default `.env`) with its example (the first of `.env.example`,
  `.env.sample`, `.env.template`, and `.env.dist`) by key name. It reports
  missing, extra, empty, and duplicate keys and malformed lines by number,
  and warns when the file is tracked by Git, not ignored, readable or
  writable by other users, or owned by another user, printing the exact
  `git rm --cached` or `chmod -- 600` hint without running it. Both files are
  parsed as bounded data through a no-follow descriptor and never loaded into
  the shell; symbolic links, non-regular files, and files above 1 MiB or
  10,000 lines are refused. No value, value length, or digest is ever
  printed. `--json` emits one `zdx.env-dotenv.v1` object built by `jq`. The
  command returns `0` without issues, `1` with issues or when the check
  cannot run, and `2` for invalid arguments, and appears in `env-menu`,
  `zdx env`, and completion.
- `file-trash` gives File deletions a recoverable step. `put` moves files,
  directories, and symbolic links below the current directory into a private,
  mode-`700` `${XDG_DATA_HOME:-~/.local/share}/zdx/trash` by a no-clobber
  rename only,
  refusing a path on another filesystem or mount instead of copying it, with
  a freedesktop.org-style `info/<id>.trashinfo` record for each item.
  `list [--json]` shows IDs, deletion times, types, sizes, and original paths
  (JSON schema `zdx.file-trash.v1`). `restore` moves items back without
  replacing an existing path or recreating a missing parent, and `purge`
  (by ID, `--older-than DAYS`, or `--all`) deletes through the quarantined
  File deletion engine. Every mutation shows an exact plan, supports
  `--dry-run` and `--yes`, fails closed without a terminal, and revalidates
  after confirmation; without an action, a picker selects items to restore or
  purge. Records are parsed strictly as data.
- `sys-wsl` reviews the WSL configuration read-only: `/etc/wsl.conf` parsed as
  data (automount and DrvFs metadata, `[boot]` systemd and command, network,
  interop, and the default user), the default-route MTU and a `[boot]` MTU pin
  next to WireGuard or tun interfaces, a generated `resolv.conf`, the Windows
  `.wslconfig` found through bounded interop queries, and the manual
  `ext4.vhdx` compaction steps, followed by factual findings. Hosts that are
  not WSL get the not-applicable result.
- `vpn-mtu-probe [--target HOST] [--profile NAME] [--json]` measures the
  path MTU to an IPv4 target with bounded don't-fragment pings (iputils
  `ping -M do` on Linux and WSL, `ping -D` on macOS), reports the egress
  interface and its MTU, whether the route goes through a WireGuard tunnel,
  and the tunnel MTU, and prints recommendations it never applies: the exact
  `/etc/wsl.conf` `[boot]` line on WSL2, NetworkManager and systemd-networkd
  hints on Linux, `networksetup -setMTU` on macOS, and `MTU = <path − 80>`
  for a WireGuard profile. It is read-only and unprivileged, sends at most 16
  probes within 15 seconds, refuses targets other than IPv4 literals and
  plain host names, and `--json` prints one `zdx.vpn-mtu-probe.v1` object.
  `VPN_MENU_MTU_TARGET` sets the default target (`1.1.1.1`).

### Runtime and entry points

- `functions.zsh` provides configuration loading, lazy command registration,
  the shared interface and output services, opt-in telemetry, plugin
  discovery, and final user overrides.
- Suite entrypoints own deterministic loading, argument parsing, explicit
  dispatch, and their menu models. Suite-common files and feature modules
  keep implementation details in their own namespace.
- Lazy loading and the eager test mode expose the same public surface.
  Loading a module defines functions only: it never opens a menu, prompts,
  touches the network, or asks for privilege.
- `zdx doctor` (`zdx-doctor`) reports command and platform capabilities,
  marks rows that cannot apply on the host as not applicable, and never
  installs anything without an explicit decision.
- `zdx status` (also `zdx-status`), a read-only one-screen summary of the
  repository (branch, upstream ahead/behind from local refs, change counts,
  operation in progress, `user.email`, workspace platform and identity), the
  project (detected project files, active virtual environment, `uv.lock`
  age), kernel WireGuard interfaces, the host (Linux, WSL1, WSL2, or macOS,
  reboot flag, `HOME` filesystem usage, load average), and ZDX settings. Every
  probe is local and bounded; `--json` prints a `zdx.status.v1` document. It
  is routed by `zdx`, listed in the master catalog under ZDX Tools, and
  completed by `zdx` and `zdx-status`.
- Command-line insert widgets: `Ctrl-X b` (branch), `Ctrl-X p` (open pull
  request number through `gh`), `Ctrl-X o` (PID listening on a port, or the
  port with `Ctrl-O`), and `Ctrl-X v` (virtual environment path) open an fzf
  picker and insert the quoted choice at the cursor without running it. Each
  chord is bound only while it is free in the main keymap, can be changed or
  disabled with `ZDX_KEY_INSERT_BRANCH`, `ZDX_KEY_INSERT_PR`,
  `ZDX_KEY_INSERT_PORT`, and `ZDX_KEY_INSERT_VENV`, and is disabled with the
  other widgets by `ZDX_KEYBINDINGS=0`; the widget code loads on first use.
- `zdx-plugins` manages custom plugin discovery and lifecycle under
  `${ZDX_PLUGINS_DIR:-$HOME/.config/zdx/plugins}`.

### Interactive interface

- Every menu shares one frame: a compact layout with the selected row's
  details below, `Ctrl-/` to toggle them, filtering by label, and `Esc` to go
  back. Section headings group rows without being executable.
- A context block shows at most a scope line, such as `Repository:` or
  `Project:`, and a state line of `Key: value` facts. An action that cannot
  run yet appears as `○ <label> (missing: …)`.
- The default theme uses the terminal's own colors with ANSI accents and pins
  border and info colors so older fzf releases, such as Ubuntu 24.04's 0.44.1,
  render like current ones. `ZDX_FZF_TEMPLATES` controls whether rows use fzf
  field templates.
- `NO_COLOR` disables colors; `ZDX_FZF_PLAIN` and C/POSIX locales use ASCII
  controls. Inherited fzf defaults are isolated from every picker.

### Command output

- [`docs/output-spec.md`](docs/output-spec.md) defines one output contract,
  implemented by shared core services:
  - an outcome vocabulary with a change-evidence rule: `updated` only with
    before-and-after evidence, otherwise `current` or `done`;
  - headings, report sections, step banners, result lines, and summary tables;
  - one duration format, counted nouns instead of `(s)` plurals, and a single
    outermost `<suite>:<command>` timing line;
  - private capture of child-tool output, replayed as a bounded, redacted tail
    only on failure.
- Plans name their exact targets and end with `Dry run: … planned; nothing
  was …` or `Cancelled: nothing was …` when nothing ran.
- `ZDX_VERBOSE=1`, or `--verbose` where offered, streams captured output live
  and shows nested headings.
- `stdout` carries data only; prompts, plans, progress, warnings, and errors
  go to `stderr`.
- A JSON output convention for read-only commands
  ([`output-spec.md`](docs/output-spec.md#json-output)): `--json` prints
  exactly one compact, single-line document built by `jq`, with data passed
  as arguments or raw input and never as program text, whose first key is
  `"schema": "zdx.<command>.v<N>"`; it never opens fzf or prompts, uses
  `null` for unknown values, emits no secrets, and keeps the text mode's exit
  status.
- `git-status --json` writes one `zdx.git-status.v1` document: branch, HEAD,
  upstream with local ahead and behind counts, the operation in progress,
  change and stash counts, and the workspace platform and identity.
  `git-identity-check --json` writes `zdx.git-identity-check.v1`.
- `sys-info --json` and `sys-wsl --json` print one `zdx.sys-info.v1` or
  `zdx.sys-wsl.v1` JSON document on stdout, built with `jq`; the text reports
  are unchanged.

### Maintenance and updates

- `update-system` runs a numbered plan of the steps that apply to the host:
  APT, native packages (DNF, pacman, zypper, apk, or macOS software updates
  that need no restart), Snap, Homebrew, Starship, fzf, Google Cloud SDK, AWS
  CLI, uv, pipx, Node.js, Rust, Oh My Zsh, and Zsh plugins. It
  authenticates sudo once, shows one result per step and an `Update Summary`,
  and names the command that retries each failed step. Independent steps
  continue after an ordinary failure unless `--fail-fast` is given.
- `update-apt` and the APT step renew the expired or replaced signing key of
  a known repository (GitHub CLI, Google Cloud SDK, Charm, Docker, HashiCorp,
  Microsoft, NodeSource, and Google Chrome) from the publisher's HTTPS key URL,
  require the key ID that APT reported, and keep the new key only when APT
  verifies the repository. A repository it cannot renew is named with the
  exact install and disable commands. `SYS_APT_KEY_RENEWAL=0` keeps diagnosis
  only.
- `clean-system --quick` or `--deep`, `clean-journal`, and `clean-snaps`
  show exact cleanup plans and a `Cleanup Summary`.
- `dev-update-all` runs the host toolchain (delegated to `sys-menu`),
  dependency specifiers, the lockfile, pre-commit hooks, GitHub Actions,
  Terraform and TFLint ownership reports, and project cleanup as one plan with
  a `Maintenance Summary`.
- `dev-update-actions` pins the actions used by `.github/workflows` and
  composite actions to the commit SHA of a newer stable release within the
  current major version (`--major` allows newer majors), written as
  `owner/repo@<sha> # vX.Y.Z`. It queries tags with an HTTPS-only,
  credential-free `git ls-remote`, never downgrades, holds back releases
  younger than `DEV_ACTIONS_COOLDOWN_DAYS` (seven) when `gh` is
  authenticated, and validates the result with `actionlint` and `zizmor` when
  they are installed.
- Dependency and pre-commit updates back up `pyproject.toml` and the hook
  configuration, publish atomically, and roll back exactly when a later step
  fails. Remote hooks are frozen to full commit SHAs, and a newer existing pin
  is kept when upstream proposes a downgrade.
- `dev-check-health` checks `pyproject.toml`, the `.venv`, `requires-python`,
  lockfile freshness, hooks, the toolchain, and PyPI reachability, and works
  as a CI gate.

### Safety and execution model

- Public commands, menu rows, dispatchers, help, completions, tests, and
  documentation form one synchronized interface, frozen per suite by a
  public-command fixture.
- User data never becomes shell program text. Dispatch uses allowlisted
  functions and literal argument arrays without `eval`.
- Menus capture selections privately in the foreground and accept only a row
  from the displayed snapshot; targets are revalidated before mutation.
- Destructive commands show an exact plan and support `--dry-run`, require
  confirmation or `--yes`, and fail closed without a terminal. Deletions in
  the File suite first move each target to a same-directory quarantine for
  crash safety; a completed deletion is not recoverable, and only an
  interrupted or failed one keeps its quarantine and reports its path. Use
  `file-trash` when a deletion must stay recoverable.
- Privileged workflows keep selection and review unprivileged, announce each
  privileged command, and restrict mutations to exact validated operations.
- State lives in owner-controlled locations with bounded content, identity
  checks, locking where required, and atomic or no-clobber publication.
- Secrets, credentials, private keys, environment values, authenticated URLs,
  and sensitive log content are masked or redacted in menus, previews,
  diagnostics, telemetry, tests, and reports.
- Network access, downloads, remote mutations, privilege, package
  installation, and remote code run only as explicit, disclosed steps.
- Telemetry is opt-in, bounded, owner-only, and limited to command identity,
  suite, duration, result, and timestamp.

### Platforms

- Linux and WSL 2 run every suite; WSL adds Windows-drive advisories, DNS
  hardening for VPN tunnels, the Windows clipboard, and the Windows version in
  `sys-info`, and ignores Windows programs on the appended `PATH`.
- macOS runs every suite with its BSD userland and Homebrew tools: launchd
  services, `softwareupdate` without restart updates, the Data volume, and
  WireGuard through Homebrew `wireguard-tools` with `utun` devices. Apple's
  Command Line Tools placeholders are reported, never run.
- A command that cannot apply on the host says so and returns 1 when run
  directly; inside an aggregate it is skipped.
- Interactive menus require `fzf`; direct commands check their own tools when
  used. Git commands require Git 2.31 or newer, and project-metadata features
  find a Python 3.11 or newer interpreter automatically.

### Plugins and customization

- User configuration lives under `~/.config/zdx`; `config.zsh.example`
  documents every setting with its default, bounds, and trust implications.
- `~/.config/zdx/overrides.zsh` loads last for update-safe customization.
- Custom plugins use matching kebab-case directory, entrypoint, and menu
  names with plugin-owned namespaces. The loader accepts owned, non-symlink
  roots and singly linked entrypoints, checks Zsh syntax, rechecks file
  identity, and registers only the expected menu function.
- `zdx-plugins` installs and updates plugins as locked, staged transactions.
  It clones into a private directory inside the plugin root, validates the
  tree with the loader's own entrypoint rule plus link and syntax checks, and
  renews the trust decision with the redacted origin, the exact commit
  transition and count, the full commit ID, and the signature verdict. After
  the decision it revalidates, publishes by verified renames, and activates.
  A failed or interrupted `source` rolls back to the exact previous commit
  and is reported, never announced as a reload. Changes need a terminal or
  `--yes`, and `--dry-run` reviews without changing anything. Removal now
  follows an exact plan with revalidation and quarantine, and the manager's
  pickers use private capture with snapshot validation. `zdx-plugins`
  completion is registered with the master completion.
- Plugins run with the user's full shell authority and are not sandboxed.

### Installation and demonstration

- The Zsh installer, with a small Bash launcher, integrates a reviewed local
  checkout. It previews its exact plan with `--dry-run`, requires explicit
  authorization, refuses unrelated destinations, and publishes the initial
  configuration privately without overwriting existing files. Activation in
  `.zshrc` stays manual.
- The README demo tours the `zdx` launcher, a stash saved from the Git menu,
  the System information, and the Developer health check, recorded with VHS in
  a private, offline uv project. `just demo` reproduces it and keeps the
  previous media when recording or validation fails.

### Repository toolchain and automation

- Contributor tooling uses `uv` with a locked Python 3.14 environment,
  `just`, and pre-commit. Remote hooks are pinned to full commit SHAs with
  version comments.
- `just surfaces [--strict] [SUITE...]` reports, for every public command,
  which synchronized surfaces exist: function, dispatcher arm, menu record,
  `--help` entry, completion entry and binding, lazy stub, interactive
  allowlist, suite contract, and user guide, plus each suite's registrations
  and frozen count. It is read-only, names each missing surface with a file
  hint, and fails when a required surface is missing.
- `just new-command` scaffolds a public command: the fixture row, a
  documented function stub, and, where the suite uses them, the dispatcher
  arm, menu record, `--help` entry, completion entry and binding, allowlist
  entry, and lazy stub. It refuses invalid or existing names, unknown suites
  and modules, and target regions it cannot edit unambiguously, writes only
  after every edit validates, supports `--dry-run`, and prints a checklist of
  the remaining manual surfaces.
- `just check` is the acceptance gate used locally, by the pre-push hook, and
  in CI: a lockfile freshness check, Zsh syntax checks, every file-stage hook
  (gitleaks, markdownlint, actionlint, zizmor, ShellCheck, and repository
  hygiene), the locked dependency audit, and the full BATS suite.
- CI runs the gate on Ubuntu, the BATS suite on an Apple Silicon macOS
  runner, CodeQL, a DCO check, and a path-filtered VPN smoke test that brings
  a real WireGuard tunnel up and down on Ubuntu and macOS. Scheduled
  workflows publish a dependency report, link checks, and an OpenSSF
  Scorecard.
- Dependabot proposes GitHub Actions updates weekly in one grouped pull
  request with a seven-day cooldown; the DCO check accepts it only when every
  commit is Dependabot's own and verified.
- Workflows use least-privilege tokens, persist no checkout credentials, and
  pin every action to a commit SHA.
- Tagged releases publish a source archive, its SHA-256 checksum, and
  Sigstore-backed build provenance.

### Documentation and verification

- `docs/development.md`, `docs/menu-spec.md`, `docs/output-spec.md`, and
  `docs/headers.md` define the architecture, menus, command output, and
  source-file rules.
- Each suite has a public contract covering its surface, routing, completion
  grammar, safety model, platforms, and limits.
- `docs/installation.md`, `docs/plugins.md`, `docs/user-guide.md`,
  `docs/security-assessment.md`, and `docs/testing.md` cover installation,
  the plugin trust model, end-user workflows, the threat model, and the test
  architecture.
- The suite contains 1,702 BATS cases across 105 files that run production
  code in real Zsh processes inside isolated sandboxes.

### Known limitations

- Live macOS routing, a real WSL VPN host, live GitHub writes, external
  package-manager behavior, interactive sudo, and cross-filesystem races are
  verified manually; tests mock them.
- CodeQL analyzes the repository's Python helpers, not the Zsh runtime.
- User plugins, local Zsh configuration, vendor self-updaters, and project
  task descriptors are trusted code, not sandboxed data.

[0.1.0]: https://github.com/landerox/zdx-suite/releases/tag/0.1.0
