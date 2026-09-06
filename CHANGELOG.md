# Changelog

This document describes the complete initial `v0.1.0` repository baseline,
including implemented behavior, verification, and remaining limitations.

## [0.1.0] — 2026-09-06

### Overview

ZDX (Zsh Developer Experience Suite) is a modular, `fzf`-powered toolkit and
custom plugin loader for Zsh. Version `0.1.0` provides 251 public commands
across 15 interactive suites for developer, workspace, system, infrastructure,
network, cloud, AI, and hardware workflows.

- Production code is Zsh-first and integrates with Oh My Zsh through
  `zdx-suite.plugin.zsh`.
- The `zdx` command routes through an explicit built-in suite allowlist,
  dependency diagnostics,
  plugin management, and validated user plugins.
- Every suite supports direct command routing in addition to its interactive
  menu.
- Command-specific completions cover all 15 suites and the master router.
- Project metadata, the lockfile, and `zdx --version` report `0.1.0`.

### Runtime and entry points

- `functions.zsh` provides configuration loading, lazy command registration,
  shared interface services, opt-in telemetry, plugin discovery, and final
  user overrides.
- Suite entrypoints own deterministic loading, argument parsing, explicit
  dispatch, and top-level menu models. Suite-common files and feature modules
  keep implementation details within their owning namespace.
- Lazy runtime loading and the eager test mode expose the same public command
  surface.
- Built-in suite modules are idempotent and define behavior without opening menus,
  prompting, accessing the network, requesting privilege, or running public
  workflows.
- `zdx-doctor` reports command and platform capabilities. Dependency
  installation always requires an explicit user decision.
- `zdx-plugins` manages custom plugin discovery and lifecycle under
  `${ZDX_PLUGINS_DIR:-$HOME/.config/zdx/plugins}`.
- The loader retains compatibility registrations for user-local `zdir` /
  `wsj` and `zclean` implementations. Those ignored local files are not part
  of the `0.1.0` release artifact or assurance surface.

### Suite catalog

| Suite | Commands | Current scope |
| --- | ---: | --- |
| Git (`git-menu`) | 39 | Local repositories, identities, SSH/GPG routing, changes, history, branches, stashes, tags, synchronization, GitHub issues and pull requests, and lease-protected remote operations |
| Workspace (`ws-menu`) | 15 | Workspace profiles, repository placement, cloning, synchronization, migration, SSH aliases, key rotation, diagnostics, and validated removal |
| VPN (`vpn-menu`) | 22 | WireGuard profiles, tunnel state, diagnostics, protected editing, validated imports, private state, and WSL DNS leak protection |
| Docker (`docker-menu`) | 8 | Daemon-bound container and image inventories, exact cleanup plans, reviewed Compose operations, registry authentication, and remote-context authorization |
| System (`sys-menu`) | 34 | Capability-aware diagnostics, package maintenance, services, processes, ports, cleanup, dotfile backup and restore, fonts, shell diagnostics, and telemetry inspection |
| File (`file-menu`) | 10 | Staged archives, fail-closed GNU TAR extraction, bounded discovery and bulk operations, permissions, checksums, Base64, diffs, and line-ending conversion |
| App (`app-menu`) | 2 | Bounded task discovery from Just, npm, Make, and Compose descriptors, with fingerprinted execution plans and explicit authorization |
| CI (`ci-menu`) | 8 | Repository-bound GitHub Actions inspection and dispatch, plus exact cleanup plans for runs, deployments, releases, and notifications |
| Environment (`env-menu`) | 8 | Passive dotenv parsing, value-free variable inspection, explicit PATH maintenance, and private atomic environment profiles |
| Python (`py-menu`) | 16 | Validated project-local virtual environments, uv-managed Python runtimes, project package operations, PyPI inspection, and isolated `uv tool` or `pipx` applications |
| Developer (`dev-menu`) | 49 | Project inspection, polyglot quality gates, tests, security audits, dependency and toolchain maintenance, reports, exports, task profiles, and bounded cleanup |
| Network (`net-menu`) | 6 | Local interfaces and routing, DNS and latency probes, public-IP inspection through allowlisted HTTPS providers, and explicitly authorized throughput tests |
| GPU (`gpu-menu`) | 1 | Timeout-bounded NVIDIA telemetry and process occupancy, with explicit synthetic simulation |
| Hugging Face (`hf-menu`) | 5 | Bounded Hub search and metadata, explicit downloads, cache inspection, and exact cache-entry quarantine |
| AI (`ai-menu`) | 28 | Assistant diagnostics, recoverable cache quarantine, workspace instructions, private configuration snapshots, redacted logs, passive MCP audits, and reviewed official CLI self-updates |

### Interactive interface and terminal rendering

- All 15 suites and the master catalog share concise action labels and
  consistent keyboard help. Command menus use a compact 80% layout with
  selected details below the list, with the App/VPN exceptions described
  below. `Ctrl-/` toggles details where advertised; section headings explain
  their group without presenting an executable command.
- The master catalog groups destinations by responsibility and includes route
  tokens in visible labels. App retains its task descriptions and execution
  review; VPN retains precomputed tunnel-state previews. Resource browsers
  keep layouts suited to their data.
- The default uses the terminal's paired foreground and background with ANSI
  palette accents, avoiding fixed light text on an inherited light background.
  Explicit custom themes remain available through the core helper.
- Non-empty `NO_COLOR` explicitly disables picker colors. Non-empty
  `ZDX_FZF_PLAIN` also selects ASCII picker controls. C/POSIX and unset locales
  use ASCII controls automatically, without changing Unicode record bytes.
- Built-in suite, master, plugin-manager, and core picker wrappers locally
  isolate inherited fzf defaults and use `/bin/sh` for fixed preview programs.
  The caller's environment remains unchanged. VPN preview paths remain literal
  even when they contain quotes or newlines.
- Doctor reports display configuration presence and its loaded source path;
  fzf version failures and interruptions cannot become an empty successful
  version report. The user guide includes recovery from stale loaded copies
  and difficult-to-read terminal profiles.
- Real Linux terminal acceptance covers narrow/wide layouts, filtering,
  details, cancellation, and hostile inherited settings. Native macOS fonts,
  keyboard behavior, and light/dark profiles remain manual acceptance items.
  Plain mode does not provide cursor control to a cursorless terminal.

### Maintenance and recovery

- Developer and System aggregates continue independent steps after ordinary
  failures, retain per-step results, and return a failure for an incomplete
  operation. System exposes `--fail-fast`; cancellation and interruption keep
  their documented stop boundaries. Developer summaries show commands to retry
  pending steps without bypassing normal authorization.
- Developer dependency updates validate dependency specifiers and preserve an
  exact `pyproject.toml` snapshot for verified rollback when lock generation
  fails. A later sync failure preserves published metadata and the lockfile
  while reporting that the environment may be partial. Project Python
  relocation and lifecycle operations retain their owning Python boundaries.
- System package-manager and toolchain paths preserve actionable failures,
  reject invalid metadata, and distinguish interruption from completion.
- AI updates use passive NVM-aware discovery and the installed official CLI's
  supported version and update interfaces. Ordinary independent failures remain
  visible in the result ledger; interruption stops later updates. Authorization
  requires a validated version; Hermes accepts its complete typed version banner
  when only a later ancillary query times out with status 124.
- Git and Workspace report failed synchronization, merge, clone, tag, and
  migration steps and retain invocation-owned recovery state. Partial clones
  and completed portions of migrations can remain for manual recovery; there
  is no universal rollback. VPN failures retain protected state and clean up
  private preview resources.
- File, App, CI, Environment, Python, Hugging Face, Network, GPU, and Docker
  include targeted recovery checks for their documented publication, backend,
  interruption, timeout, and cleanup boundaries. Their suite contracts record
  the exact controls and remaining external verification limits.
- File discovery reports successful scans independently of candidate order or
  empty results, while preserving inventory failures and content-read errors.

### Safety and execution model

- Public commands, menu actions, dispatchers, help, completions, tests, and
  documentation form one synchronized interface.
- Suite contracts reserve `stdout` for structured data and route prompts,
  plans, progress, warnings, and errors to `stderr`. The plugin manager retains
  documented legacy stream and capture exceptions.
- User-controlled data is kept separate from shell program text. Dispatch uses
  allowlisted functions and literal argument arrays without `eval`.
- Audited command menus use private foreground capture, exact displayed-row
  validation, and target revalidation before mutation. Nested Git pickers and
  the plugin manager retain documented legacy capture paths; presentation
  consistency does not imply that every picker has the same assurance level.
- Audited destructive paths use protected-path checks, bounded target plans,
  dry-run support or explicit confirmation, and fail-closed non-interactive
  authorization. Workspace broad mutations and plugin lifecycle operations
  retain the exceptions and migration work recorded in their contracts.
- Privileged workflows keep selection and review unprivileged and restrict
  mutations to exact validated operations. Documented exceptions include
  bounded protected VPN reads after explicitly unlocking access. Profile
  editing uses `sudoedit`.
- Filesystem state uses owner-controlled locations, bounded content, identity
  checks, locking where required, and atomic or no-clobber publication.
- Recoverable quarantine protects eligible cache and removal workflows.
- Secrets, credentials, private keys, dotenv values, authenticated URLs, and
  sensitive log content are withheld or redacted from menus, previews,
  diagnostics, telemetry, tests, and reports.
- Network access, downloads, remote mutations, privilege escalation, package
  installation, and remote-code execution remain explicit capability and trust
  boundaries.
- Developer host-tool maintenance delegates the targeted `uv` operation to
  `sys-menu`, never invokes ambient Python or `pip`, and reports Homebrew-owned
  TFLint updates without mutating the host package manager. Terraform, TFLint,
  and uv package-owner claims are tied to the canonical active executable.
- System pickers, including the nested symbol, telemetry, process, listener,
  service, font, and backup selectors, run `fzf` in the terminal foreground
  with private bounded capture and snapshot-validated selection. Dotfile and
  font workflows name a missing `tar`, `curl`, or SHA-256 tool before planning
  or authorization, dotfile backups validate source trees through the
  canonical home directory, and a refused nested `update-system` run leaves
  the outer execution lock untouched.
- Pre-commit maintenance freezes remote hooks to immutable Git object IDs,
  plans changes outside the live configuration, preserves newer pins when
  upstream tag topology proposes a downgrade or retag, freezes mutable
  non-version refs only at their exact provenance label, and installs every
  planned hook environment before atomic publication. Applicable file-stage
  hooks then run against the published configuration; hook findings or a
  partial autoupdate remain failures without discarding validated revisions.
  Concurrent live-file edits are never overwritten by recovery.
- Telemetry is opt-in, bounded, owner-only, and limited to command identity,
  suite, duration, result, and timestamp.

### Plugins and customization

- User configuration, theme settings, telemetry controls, and workspace
  defaults live under `~/.config/zdx`.
- `~/.config/zdx/overrides.zsh` is loaded last for update-safe function and
  alias customization.
- Custom plugins use matching kebab-case directory, entrypoint, and menu
  function names, plus plugin-owned public and private namespaces.
- The plugin loader accepts canonical, owned, non-symlink roots and singly
  linked regular entrypoints, validates Zsh syntax, rechecks file identity, and
  registers only the expected menu function.
- Plugins execute with the user's full shell authority and are not sandboxed.
  Source review and trust in the origin and selected commit are mandatory.
  The manager still needs staged update validation, rollback, renewed trust,
  and correct propagation of entrypoint source failures; its improved rendering
  does not complete that lifecycle migration.

### Onboarding and demonstration

- `README.md` introduces the complete `0.1.0` surface through task-oriented
  installation, usage, configuration, security, support, and contribution
  guidance.
- `.config/zdx/config.zsh.example` is an all-optional, commented Zsh template
  containing implemented settings, their defaults and bounds, and the trust
  implications of local configuration, plugins, telemetry, remote package
  runners, Docker endpoints, and VPN providers.
- The Zsh installer integrates a reviewed local source tree, with a small Bash
  compatibility launcher. It previews the exact plan through `--dry-run` and
  requires explicit authorization for writes. It preserves identical existing
  integrations and refuses unrelated destinations without replacing them.
  Initial configuration is published privately without clobbering existing
  names, with new directories at mode `700` and `config.zsh` at mode `600`.
  Activation in `.zshrc` is manual; Git and System retain update ownership.
- `.demo/demo.tape` tours the current ZDX, Developer, System, AI, Git, and File
  menus with filtering, selected descriptions, and cancellation. The
  README includes a GIF with 16 px typography, a static Developer PNG
  alternative, and a text description of the tour. A fixed FFmpeg conversion
  limits the animation to 10 fps and
  64 colors. The demo GIF has a dedicated 2 MiB repository budget; the PNG
  and other files retain the 1 MiB budget.
- `just demo` runs the recorder with private startup, HOME, XDG, and temporary
  state. The demo uses synthetic project files and performs no project task,
  update, remote operation, or destructive menu action. Failed recording leaves
  the existing published assets intact.
- `docs/demo.md` compares recording alternatives, explains why VHS remains the
  reproducible README format, and documents the script, environment isolation,
  asset limits, and validation procedure.

### Repository toolchain and automation

- Contributor tooling is managed with `uv`, `just`, pre-commit, and a locked
  Python dependency set.
- All seven remote pre-commit hook repositories are pinned to immutable Git
  object IDs (full SHAs) with human-readable version comments.
- Explicitly addressable repository configuration lives under `.config`,
  including the Markdownlint policy and the installable ZDX user-configuration
  template. Location-bound metadata remains in its canonical discovery path.
- `just check` is the shared acceptance aggregate used locally, by the
  pre-push hook, and by the CI Quality Gates workflow. It first rejects stale
  project metadata without rewriting `uv.lock`, then combines Zsh syntax
  validation, all file-stage pre-commit quality and security hooks, the locked
  Python dependency audit, and the complete BATS suite. `uv lock --check`
  verifies freshness; uv runners and dependency exports use `--locked`.
- Every file hook is explicitly restricted to `pre-commit`; the `pre-push`
  stage invokes the complete gate exactly once instead of repeating manifest
  hooks before it. The declared minimum pre-commit version is `3.2.0`, the
  first release supporting the configured stage names.
- The CI Quality Gates workflow synchronizes the locked Python dependency set,
  installs Zsh, BATS, fzf, and Just from the Ubuntu runner distribution, and runs
  `just check` for pushes and pull requests targeting `main`, manual
  dispatches, and the daily security schedule. Its 30-minute job bound covers
  the complete serial suite without turning a healthy run into a timeout.
  Native fzf filtering checks run with the installed binary. Push run titles
  show the branch name without including the commit's DCO trailer.
- Pipe-delimited pickers use an explicit literal-pipe expression so field
  display and filtering work with Ubuntu's fzf 0.44.1 and newer releases.
- Gitleaks, Markdownlint, Actionlint, Zizmor, ShellCheck, CodeQL, OpenSSF
  Scorecard, DCO verification, and repository hygiene checks cover their
  documented source and workflow surfaces.
- Workflow permissions follow least privilege, checkout credentials are not
  persisted, and third-party actions are pinned to commit SHAs.
- Dependency maintenance is informational and manually reviewed. The weekly
  report evaluates `uv lock --upgrade --dry-run`, validates the committed
  lockfile, and writes a bounded job summary without modifying the repository
  or opening a pull request.
- The GitHub dependency graph and Dependabot alerts provide informational
  findings. Dependabot security-update pull requests are disabled.
- Vulnerability reports use GitHub's private reporting channel, with the
  security-policy email address retained as a fallback.
- `pip-audit` evaluates locked Python dependencies every day.
- Lychee checks documentation links weekly and publishes failures to the job
  summary without creating issues.
- Tag-based releases publish a source archive, SHA-256 checksum, and
  Sigstore-backed build provenance under release-specific permissions.

### Documentation and verification

- `docs/development.md`, `docs/menu-spec.md`, and `docs/headers.md` define the
  architecture, interactive interface, and source-file contracts.
- `docs/installation.md` defines local integration, path validation, private
  configuration publication, manual activation, and update ownership.
- Each built-in suite has a normative contract covering its public surface,
  routing, completion grammar, safety model, platforms, and residual limits.
- `docs/plugins.md` defines the executable plugin trust model and layout.
- `docs/security-assessment.md` records the threat model, implemented controls,
  assurance evidence, residual risks, and maintenance triggers.
- `docs/testing.md` defines the isolated BATS architecture and mocking policy,
  while `docs/user-guide.md` documents end-user workflows.
- Fifteen public-command fixtures keep functions, routing, menus, help,
  completions, tests, and documentation aligned.
- The baseline contains 1,584 BATS cases across 111 files. Tests execute
  production behavior through real Zsh processes inside isolated sandboxes.

### Compatibility surface

- Unprefixed Developer command wrappers delegate to the canonical `dev-*`
  commands and emit a one-time compatibility warning.
- `clean-docker` and `docker-prune-all` delegate to `docker-clean`.
- `vpn-status` and `vpn-public-ip` delegate to their canonical VPN owners.
- CI tag and issue compatibility commands delegate to the Git suite.
- `sys-plugins` delegates plugin lifecycle management to `zdx-plugins`.

### Platforms and verification boundaries

- Linux is the primary platform and the automated test environment.
- WSL2 is supported through capability-gated Linux and WSL paths.
- macOS support is conditional on each command's documented capabilities.
- FreeBSD and Android/Termux are experimental and have no dedicated CI.
- Oh My Zsh is the primary integration; direct Zsh sourcing is also supported.
  Interactive menus require `fzf`, with version 0.31 or newer for responsive
  previews. Direct workflows check their own tools at the point of use.
- Live macOS routing, a real WSL VPN host, physical multi-GPU hardware, remote
  Docker contexts, authenticated Hugging Face downloads, live GitHub writes,
  external package-manager behavior, and cross-filesystem races remain manual
  verification boundaries.
- CodeQL analyzes Python, including the contributor helper and the installer's
  filesystem helper. It does not analyze the Zsh runtime.
- User plugins, local Zsh configuration, vendor self-updaters, and executable
  project task descriptors are trusted code surfaces rather than sandboxed
  data.

[0.1.0]: https://github.com/landerox/zdx-suite/releases/tag/v0.1.0
