# Changelog

This document records user-visible changes by release. The `0.1.0` entry
describes the complete initial release: its implemented behavior,
verification, and remaining limitations.

## [Unreleased]

### Security

- Timing footers and new telemetry records use registered identifiers and their
  owning suite, replacing unknown or mismatched labels with fixed unknown
  values. Telemetry persistence refuses unsafe ancestors and linked or
  non-private logs, and publishes private staging without chmodding the
  destination after replacement.
- Core capture and master pickers refuse temporary roots below writable
  non-sticky ancestors and use the UID reported for `/`. Core and standalone
  System watchdog claims refuse changed, linked, or unsafe markers and keep
  replacement paths during cleanup instead of writing through them.
- VPN: profile import refuses `wg-quick` lifecycle hooks in any section and
  letter case, and a second `[Interface]`, whatever options the calling shell
  sets. Before, an inherited `PIPE_FAIL` let a padded profile carry a `PreUp`
  hook that `wg-quick` then ran as root.
- System: `clean-system` runs its pip probes and the pip cache purge from
  the root directory, so pip code planted in the working directory no longer
  runs, not even in a dry run.
- System: a project's `uv.toml`, `.npmrc`, or `go.mod` can no longer choose
  what `clean-system` deletes or make a dry run download a Go toolchain, and a
  cache that is or contains the ZDX suite or the current repository, bare ones
  included, is refused.
- Files: 7z creation no longer treats a literal `*` or `?` in a reviewed name
  as a wildcard, so it cannot add unplanned files to the archive; it requires a
  7-Zip that accepts `-spd` and `-sae`.
- Git: no cleanup, tag, recovery, switch, stash, or push command follows a
  symbolic ref any more. Before, a `master -> main` alias made
  `clean-branches`, `clean-remote-merged`, and `git-tag-delete` delete `main`
  itself, and a push could move `main` through an aliased tracking ref. Remote
  branch and tag deletion now refuse when the server cannot report its
  symbolic refs over protocol v2.

### Fixed

- Keep lazy command identities literal, compile owned modules without caller
  aliases, and isolate internal option, numeric, and regex state. Plugin
  activation retains its current-shell effects while registry and manager
  bookkeeping remain valid after option changes. Picker descriptors, duration
  labels, and native watchdog tick counts also work with `FORCE_FLOAT`.
- System maintenance tests compare complete privileged-call records, so words
  in a temporary path cannot look like extra operations. The checks still
  require exactly one validated TERM and reject additional calls.
- Clarify the engineering contract for local Zsh options and regex state,
  caller-command and persistent plugin execution boundaries, and public
  confirmation statuses. Runtime adoption follows the corresponding
  core and suite fixes.
- Observe interrupted BATS workers for a bounded exit interval after their
  leader stops, instead of treating asynchronous shutdown as an immediate
  failure. A worker that survives the interval still fails the test.
- Failed opt-in telemetry recording reports one generic warning per shell
  while preserving the command's status and allowing later writes. Writer
  and System clear operations retain their shared lock protocol; recovery of
  a lock left by a killed shell remains manual after checking no writer or
  clearer is active.
- Enforce assertions in BATS safety and contract tests, record Python backend
  calls through PATH mocks, and reject unchecked non-final literal Zsh
  assertions with a portable scanner and ShellCheck gates.
- Run BATS in a separate session so parallel Zsh NUL readers cannot stop the
  suite on a terminal; forward INT, TERM, and HUP and wait for BATS to exit.
- System: `clean-system` plans and dry runs list every superseded Codex,
  Cursor Agent, Claude CLI, AWS CLI bundle, and nvm runtime version they
  remove, instead of the first three and a count.
- Plugins: under Oh My Zsh, lazy plugins load on first use, and eager plugins
  show as active and are counted, because the loaded-plugin list stays global
  when the core is sourced from a function.
- VPN: every command behaves the same whatever options the calling shell
  sets. Under an inherited `KSH_ARRAYS`, `NO_UNSET`, `SH_WORD_SPLIT`, or
  `emulate sh`, commands crashed, refused every profile directory, or picked
  the wrong profile to rename or remove.
- Widgets: `Ctrl-G` runs `git-menu` as a typed command line, so its
  confirmations and text prompts work, the line you were editing comes back at
  the next prompt, and the prompt refreshes; before, every confirmation and text
  prompt reached through `Ctrl-G` failed for lack of a terminal.
- Workspace: `ws-status`, its `--fetch`, the `ws-jump` preview, and
  `ws-clone` ignore inherited repository variables such as `GIT_DIR`,
  `GIT_WORK_TREE`, and `GIT_CONFIG_PARAMETERS`, so `ws-clone` no longer writes
  the identity profile into the repository an exported `GIT_DIR` names. The
  clone and the fetches also stop inheriting `GIT_CONFIG`,
  `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_n`, and `GIT_CONFIG_PARAMETERS`. A
  `ws-clone` interrupted with Ctrl-C at a terminal now returns 130 instead
  of 0.
- Git: `git-unstage` and `git-amend` refuse a plan when HEAD, the index, or
  the working tree changes while the picker or action dialog is open, and plan
  the whole repository when run from a subdirectory with `diff.relative`;
  before, an unstage could drop the only copy of a staged version without the
  confirmation, and an amend could commit files its plan never listed.
- Files: `file-compress` and `file-extract` ignore inherited `TAR_OPTIONS`,
  `ZIPOPT`, `GZIP`, and similar default-option variables, so
  `TAR_OPTIONS=--remove-files` can no longer delete the inputs; when the inputs
  change during creation, the unpublished archive is kept and reported as a
  recovery path instead of deleted.
- Files: 7z and zip outputs keep exactly the reviewed name and `--format`
  alone selects the format; an output name without an extension no longer
  fails after confirmation.
- Pickers: every suite reads the picker result with the Zsh `sysread`
  builtin instead of an external `cat`, so a result that cannot be read fails
  with status 125 on every host; on Ubuntu 26.04, whose uutils `cat` reported
  the failure as an empty success, the capture returned 0 with an empty
  selection. A result whose size changes after the post-picker check is
  refused too.
- Git: `git-pull`, `git-stash branch`, and `git-pr-checkout` no longer
  overwrite untracked or ignored local files that the target tree tracks: they
  refuse and list them before any change. `git-pr-checkout` fetches the
  reviewed pull-request head itself from a configured remote and checks out
  only that commit, instead of running `gh pr checkout`, and a rebase pull is
  refused when the configuration asks it to recreate merges.
- Core: the Zsh timeout watchdog, used without `timeout` or `gtimeout` as on
  stock macOS, now delivers each TERM and KILL pass to the whole visible
  process tree of a timed-out command, even when the command exits on the
  first signal; in a stress test on a loaded host, a descendant kept running
  in 46 of 100 timeouts. The standalone System fallback now signals every
  process of a multi-process tree instead of none, a `TRAPTERM` function in
  the user's shell no longer keeps a finished bounded command waiting until its
  deadline, and a stalled process listing can no longer hold a bounded
  command.

## [0.1.0] — 2026-10-22

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
  menu. Every public command works in a new shell, and command-specific
  completions cover each command typed directly, every suite menu, and the
  launcher.
- Linux, WSL, and macOS are supported on the same code paths, with
  capability checks where the platforms differ.
- Project metadata and `zdx --version` report `0.1.0`.

### Suite catalog

| Suite | Commands | Scope |
| --- | ---: | --- |
| Workspace (`ws-menu`) | 3 | Navigation across the `$WS_BASE_DIR/<platform>/<identity>/<repository>` layout, staged clones with identity delegation, and read-only multi-repository status |
| Git (`git-menu`) | 21 | Repository context, local changes (stash manager, unstage, amend, undo, discard), branch switching and commit recovery, pull and fetch, pushes and tags with remote leases, GitHub pull requests, identities and identity checks, and branch cleanup |
| Developer (`dev-menu`) | 25 | Python and Terraform project health with data and infrastructure project markers, quality gates, tests and coverage, security audits, dependency, lockfile, pre-commit, Python, Terraform, TFLint, and GitHub Actions updates, and bounded cleanup, including dbt build output |
| System (`sys-menu`) | 25 | Host information and health (including the OpenTofu version), a WSL configuration review, services, processes, ports, package and toolchain updates, cleanup of caches and superseded tool versions, shell startup timing, and telemetry |
| VPN (`vpn-menu`) | 22 | WireGuard profiles, connection state, protected editing, validated imports, private state, diagnostics, a path MTU probe, and WSL DNS leak protection |
| Python (`py-menu`) | 16 | Project-local virtual environments with a staged, rollback-safe rebuild for uv projects, uv-managed runtimes, project packages, PyPI inspection, and isolated `uv tool` or `pipx` applications |
| File (`file-menu`) | 5 | Staged archive creation (TAR, including zstd, ZIP, and 7z), fail-closed TAR extraction with a configurable expansion limit, large-file inspection, a recoverable trash, and junk-file cleanup below the current directory |
| Environment (`env-menu`) | 3 | Masked variable inspection, an explicit, reviewed `PATH` deduplication, and a value-free dotenv key, hygiene, and secret-handling check |

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
  `zdx env`, and completion. As advisory facts that never change the issue
  count or exit status, it also reports the nearest `.sops.yaml` up to the
  Git work-tree root (bounded, never in an enclosing repository) and an
  encrypted counterpart next to the file (`NAME.enc`, `NAME.sops`, or
  `STEM.sops.env`), testing names only without decrypting or running `sops`,
  and warns by name when the file sets `AWS_SECRET_ACCESS_KEY`,
  `MINIO_ROOT_PASSWORD`, or `MINIO_SECRET_KEY`, pointing to `sops exec-env`
  or short-lived credentials vended by the catalog, such as Polaris;
  `zdx.env-dotenv.v1` carries them as `dotenv.sops` and
  `dotenv.static_storage_credential_keys`.
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
- `file-compress` and `file-extract` handle zstd TAR archives (`tar.zst`,
  alias `tzst`, extension `.tzst`) when a GNU tar that accepts `--zstd`
  (1.31 or newer) and `zstd` are installed. A bounded probe checks both, and
  a host without them gets an error, and a `○ tar.zst (missing: …)` picker
  row, naming each missing tool. Extraction takes the same snapshot,
  preflight, and realized-tree checks as every TAR archive.
  `FILE_EXTRACT_MAX_GIB` (integer 1–64, default 1) sets the declared
  expansion limit, and any other value refuses extraction. Each compression
  format's backend is checked before planning, so `--dry-run` also reports a
  missing `zip` or 7z.
- `venv-rebuild` rebuilds the project `.venv` of a uv project from its
  `pyproject.toml` and `uv.lock` in one staged transaction: a private
  workspace below the project,
  `uv venv --clear --managed-python --no-python-downloads --python <minor> --relocatable`,
  `uv sync --locked --all-groups` into that staged environment, interpreter
  verification, and a swap by rename after every reviewed identity and input
  is revalidated. A failure keeps or restores the original, and an
  interrupted swap keeps a reported recovery workspace. It keeps the current
  Python minor, or the pinned request of that minor, and never installs or
  downloads a runtime. Any other environment, a project without `uv.lock`, a
  Poetry project, and a non-CPython `.venv` fail closed with the
  `venv-remove` then `venv-create` alternative.
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
- Every public command is registered at startup as a lazy stub whose first
  call loads its suite, so commands such as `git-status`, `update-system`, and
  `dev-run-all-checks` work in a new shell. `ZDX_DIRECT_COMMANDS=0` registers
  only the suite menus and the `zdx` commands.
- Lazy loading and the eager test mode expose the same public surface.
  Loading a module defines functions only: it never opens a menu, prompts,
  touches the network, or asks for privilege.
- `zdx doctor` (`zdx-doctor`) reports command and platform capabilities,
  marks rows that cannot apply on the host as not applicable, lists public
  command names that hide an executable on `PATH` and user files refused at
  startup, and never installs anything without an explicit decision. Its
  installer prints the exact numbered command lines, with the package
  manager and `sudo` as absolute paths that must be root-owned and not
  writable by other users (Homebrew may belong to the user and never runs
  through `sudo` or as root); `--dry-run` stops there. After the
  confirmation it rebuilds the plan and requires it unchanged, with every
  planned tool still missing, authenticates once with an announced `sudo -v`,
  checks again, and runs each line with `sudo -n` and closed stdin, with one
  result per step. A failed step stops the plan, and when `sudo -n` stops
  working after `sudo -v`, as with `timestamp_timeout=0`, the remaining
  commands are printed instead of prompting again.
- `~/.config/zdx/config.zsh` and `overrides.zsh` load only when they are
  regular files owned by the user or root, with one hard link and no group or
  other write permission, in directories only the user or root can write;
  symbolic links are followed and checked hop by hop, and a root-owned,
  read-only file below `/nix/store` is accepted for home-manager. A refused
  file is announced with a `chmod` remedy, ZDX keeps loading with its
  defaults, and `zdx doctor` lists it.
- Functions that `overrides.zsh` defines or replaces stay in effect after a
  suite loads on first use, as they do in an eager shell.
- The release version lives in one place, `functions/zdx-version.zsh`.
  `zdx --version` and `zdx status` add the checkout's abbreviated commit, and
  `modified` when tracked files differ, when the ZDX directory is exactly the
  top level of a Git work tree, as in
  `ZDX (Zsh Developer Experience) v0.1.0 (8ccb9d3, modified)`.
- `zdx status` (also `zdx-status`), a read-only one-screen summary of the
  repository (branch, upstream ahead/behind from local refs, change counts,
  operation in progress, `user.email`, workspace platform and identity), the
  project (detected project files, active virtual environment, `uv.lock`
  age, and a dbt project with its validated `DBT_TARGET` name), the current
  Kubernetes context and namespace from one local
  `kubectl config view --minify` call and whether the kubeconfig is private,
  kernel WireGuard interfaces, the host (Linux, WSL1, WSL2, or macOS, reboot
  flag, `HOME` filesystem usage, load average), and ZDX (the version with the
  checkout commit, loaded and available plugins, and settings). Every probe is
  local and bounded; `--json` prints a `zdx.status.v1` document. It
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
  `Ctrl-G` opens `git-menu`; `ZDX_KEY_GIT` moves it, and an empty value
  unbinds it.
- `zdx-plugins` manages custom plugin discovery and lifecycle under
  `${ZDX_PLUGINS_DIR:-$HOME/.config/zdx/plugins}`.

### Interactive interface

- Every menu shares one frame: a compact layout with the selected row's
  details below, `Ctrl-/` to toggle them, filtering by label, and `Esc` to go
  back. Section headings group rows without being executable.
- A context block shows at most a scope line, such as `Repository:` or
  `Project:`, and a state line of `Key: value` facts. An action that cannot
  run yet appears as `○ <label> (missing: …)` in every suite, Git included.
- The default theme uses the terminal's own colors with ANSI accents and pins
  border and info colors so older fzf releases, such as Ubuntu 24.04's 0.44.1,
  render like current ones. `ZDX_FZF_TEMPLATES` controls whether rows use fzf
  field templates.
- `NO_COLOR` disables colors; `ZDX_FZF_PLAIN` and C/POSIX locales use ASCII
  controls. Inherited fzf defaults are isolated from every picker.
- Completion works for every public command typed directly, with the same
  arguments as through its suite menu; for example, `vpn-on <Tab>` offers the
  VPN profiles.

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
- Git follows the same contract: its labels use the shared layout, counts use
  counted nouns, every dry run ends with `Dry run: … planned; nothing was …`,
  and `clean-branches` and `clean-remote-merged` show their plans as tables,
  one result per branch, and a complete, partial, or failed verdict, with the
  remote deletion's output captured and its URL redacted.
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
  are unchanged. `sys-info` reports the OpenTofu version (`tofu --version`,
  under the same 3-second bounded probe as Terraform) as an `OpenTofu` row and
  `tools.opentofu`, which is `null` when `tofu` is absent.

### Maintenance and updates

- `update-system` runs a numbered plan of the steps that apply to the host:
  APT, native packages (DNF, pacman, zypper, apk, or macOS software updates
  that need no restart), Snap, Homebrew, Starship, fzf, Google Cloud SDK, uv,
  pipx, Node.js, Rust, Oh My Zsh, and Zsh plugins; the AWS CLI bundle updates
  only through `update-awscli`. It
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
  show exact cleanup plans and a `Cleanup Summary`. The `clean-system` plan
  table follows the execution order, so each number matches its step banner,
  and names the steps that run through `sudo`. The policy that shared `/tmp`
  content and Docker resources are never removed appears with `--dry-run`,
  `ZDX_VERBOSE=1`, and `--help`, and a failed cleanup ends with deduplicated
  retry commands that never add `--yes`.
- Package managers arbitrate their own locks: no System workflow infers a
  lock from a process name. `apt-get clean` takes APT's non-blocking locks, so
  a busy APT fails only the APT cache step, with APT's message, while every
  other step still runs.
- Both `clean-system` modes remove superseded tool versions, planned by exact
  name and listed in the plan table, such as
  `~/.local/share/claude/versions (superseded: 2.1.290, 2.1.293)`:
  - releases of Codex, Cursor Agent, and Claude CLI, keeping every selected,
    newer, and previous release and every Claude version that a live session
    has locked;
  - AWS CLI v2 bundles that the bundled installer's `--update` leaves behind,
    keeping the active version; a root-owned installation requires a trusted
    directory chain and is removed through the disclosed `sudo` prefix;
  - nvm runtimes older than the default on its major release line, unless an
    alias, a workspace project pin, the current `PATH`, or global packages that
    the default lacks still need them; other release lines and newer runtimes
    always stay, and the plan discloses that open shells using a removed
    runtime need `nvm use default`.

  A version that a running process uses always stays: Linux reads
  `/proc/<pid>/exe`, and other platforms use a bounded `lsof`; when neither
  answers, nothing is removed. Execution resolves the candidates again and
  removes only planned names that are still superseded.
- `clean-system` runs `pre-commit gc`, which removes the hook repositories that
  no known configuration still uses, against the cache that
  `PRE_COMMIT_HOME` or `XDG_CACHE_HOME` selects.
- `update-node` carries the previous default's global npm packages into a new
  nvm default that has none of its own, through `nvm reinstall-packages` at
  the same versions, so their commands stay on the default `PATH`. A default
  with its own packages is never changed, a failed reinstall keeps the update
  and prints the command that finishes it, and no runtime is uninstalled.
- `update-awscli` points to `clean-system` for the bundle versions that an
  `--update` supersedes.
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
  as a CI gate. In every project it also lists the data and infrastructure
  markers at the project root (dbt, Airflow `dags/`, SQLFluff, Helm,
  Kustomize, Dockerfile, Terraform, and OpenTofu) and, in a dbt project,
  whether the `sqlfluff-lint` and `dbt-parse` hooks are declared, without
  changing its status.
- `dev-clean-py` and `dev-clean-all` remove notebook checkpoints and, beside
  a root `dbt_project.yml`, dbt's root `target/`, `dbt_packages/`, and
  `logs/dbt.log*`; `--keep-build` keeps `target/`, and DuckDB databases, WAL
  files, and temporary files are never removed.
- `dev-run-tflint` warns that OpenTofu `.tofu` files are not linted, and the
  Developer menu header recognizes OpenTofu projects.
- `dev-update-python` upgrades the uv-managed runtime's patch release and
  delegates the environment rebuild to `py-menu venv-rebuild --yes`; its
  `--dry-run` shows both steps without running uv or `py-menu`.
- Developer backups and reports live in state directories that carry their
  own `.gitignore`, so they never appear in `git status`; a pre-existing
  custom state directory is left untouched.

### Safety and execution model

- Public commands, menu rows, dispatchers, help, completions, tests, and
  documentation form one synchronized interface, frozen per suite by a
  public-command fixture.
- User data never becomes shell program text. Dispatch uses allowlisted
  functions and literal argument arrays without `eval`.
- Every picker outside the VPN suite, including the nested Git resource and
  decision pickers, captures its selection through one core service: in the
  foreground, into a private, bounded, identity-checked file inside a private
  directory, with data from a failed or cancelled picker refused. Only a row
  from the displayed snapshot is accepted, and targets are revalidated before
  mutation. Every confirmation goes through one core service that accepts only
  an explicit yes; a picker failure declines instead of falling back to a
  typed prompt.
- `git-recover --deep` bounds its `git fsck` search to 60 seconds, also when
  the Git suite is sourced without the core.
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
- A new shell discovers custom plugins without running their code: each
  `<plugin>-menu`, and the direct commands listed in an optional, validated
  `<plugin>/commands` manifest, start as stubs, and the first call runs every
  loader check before it sources the plugin. `ZDX_DISCOVERED_PLUGINS` lists
  them, `ZDX_LOADED_PLUGINS` keeps the loaded ones, and an eager shell still
  loads plugins at startup.
- The loader and `zdx-plugins` refuse names reserved for ZDX (a built-in
  suite, a `zdx` route, or one of those followed by `-` or `_`), and a
  namespace guard refuses a plugin that defines a function outside
  `<plugin>-*` and `_<plugin>_*` or replaces an existing one, removing what it
  added and restoring what it replaced. The plugin directory and entrypoint
  must not be writable by group or other users, and `zdx-plugins` clones with
  umask `022`.
- Plugins use the plugin API v1: the read-only `ZDX_PLUGIN_API=1` and a closed
  list of core output, execution, picker, confirmation, and path services.
  The documented single-file template is under 100 lines, and a plugin may
  ship its own completion, `<plugin>/_<plugin>-menu`, checked like the plugin
  and limited to the plugin's own commands.
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
  in CI: a lockfile freshness check, Zsh syntax checks, a check that every
  generated suite copy of a core primitive matches `functions.zsh`
  (`just sync-primitives` rewrites them), every file-stage hook
  (gitleaks, markdownlint, actionlint, zizmor, ShellCheck, and repository
  hygiene), the locked dependency audit, and the full BATS suite.
- `just test` runs the BATS suite in parallel when GNU parallel is installed,
  with `BATS_JOBS` jobs (by default the online processor count, at most 8;
  `BATS_JOBS=1` runs serially), and accepts test files as arguments.
- CI runs the gate on Ubuntu with GNU parallel installed, the BATS suite on an
  Apple Silicon macOS runner through the same `just test` recipe, CodeQL, a
  DCO check, and a path-filtered VPN smoke test that brings a real WireGuard
  tunnel up and down on Ubuntu and macOS. Scheduled workflows publish a
  dependency report, link checks, and an OpenSSF Scorecard.
- Dependabot proposes GitHub Actions updates weekly in one grouped pull
  request with a seven-day cooldown; the DCO check accepts it only when every
  commit is Dependabot's own and verified.
- Workflows use least-privilege tokens, persist no checkout credentials, and
  pin every action to a commit SHA.
- Tagged releases publish a source archive, its SHA-256 checksum, and
  Sigstore-backed build provenance, only for a tag whose commit is reachable
  from `main`.

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
- The suite contains 1,839 BATS cases across 113 files that run production
  code in real Zsh processes inside isolated sandboxes.

### Known limitations

- Live macOS routing, a real WSL VPN host, live GitHub writes, external
  package-manager behavior, interactive sudo, and cross-filesystem races are
  verified manually; tests mock them.
- CodeQL analyzes the repository's Python helpers, not the Zsh runtime.
- User plugins, local Zsh configuration, vendor self-updaters, and project
  task descriptors are trusted code, not sandboxed data. The plugin namespace
  guard covers functions only, not aliases, widgets, hooks, options, or
  parameters set at source time.
- Poetry environments are never created or rebuilt by the Python suite.
- The VPN menu captures its selection into its own private result file, and
  its profile and interface picker still reads through command substitution.

[Unreleased]: https://github.com/landerox/zdx-suite/compare/0.1.0...HEAD
[0.1.0]: https://github.com/landerox/zdx-suite/releases/tag/0.1.0
