# Security assessment

This document is the consolidated threat model and assurance case for ZDX. It
supports OpenSSF Best Practices Baseline-2 criterion `osps_sa_03_01` and the
commitments in [`SECURITY.md`](../.github/SECURITY.md).

The engineering controls required for new code are normative in
[`development.md`](development.md). This assessment distinguishes implemented
controls from residual gaps discovered during the suite audits.

## Scope

ZDX consists of:

- Zsh code sourced into a long-lived interactive shell;
- interactive menus and direct commands that invoke local and remote tools;
- privileged system-maintenance workflows;
- a local Zsh installer with a minimal Bash compatibility launcher;
- user configuration, overrides, plugins, backups, and opt-in telemetry;
- GitHub Actions and Python-based contributor tooling.

ZDX does not ship a daemon or network server and does not implement its own
cryptography. It can nevertheless exercise the user's full account privileges
and can request `sudo`, so shell integrity and target validation are primary
security properties.

## Assets to protect

- The user's interactive shell and account integrity.
- Source repositories, uncommitted work, branches, tags, and remote resources.
- Home-directory configuration, SSH/GPG material, tokens, and environment
  secrets.
- System packages, services, processes, ports, logs, and privileged paths.
- Plugin and update provenance.
- CI tokens, protected branches, release artifacts, and project reputation.
- Local telemetry and backups that may reveal behavior or configuration.

## Trust boundaries

### Trusted repository code

Tracked ZDX source is trusted after review and repository quality gates. It
runs with the user's privileges when sourced.

### Local executable configuration

`~/.config/zdx/config.zsh` and `overrides.zsh` are executable Zsh. They are
trusted local code, not inert configuration data. An attacker who can modify
them can execute code on the next shell load.

### User plugins

Plugin entrypoints are arbitrary code sourced into the same shell without a
sandbox. Trusting the origin and reviewed commit is the security boundary;
syntax checks do not establish safety.

### External commands and services

Git, GitHub CLI, package managers, Docker, systemd, WireGuard, cloud CLIs,
language toolchains, pagers, editors, and network utilities have their own
configuration, credentials, and security posture. ZDX passes validated
arguments to them but does not replace their authorization model.

### Privilege boundary

Commands invoked through `sudo` cross from the user account into root
authority. Selection, parsing, downloads, and preview rendering remain
unprivileged. A suite contract may allow disclosed, bounded protected-read
probes through narrow, non-prompting `sudo`, as VPN does after access is
unlocked. Mutations elevate only exact, validated transaction primitives.

### Network and supply chain

Remote APIs, Git repositories, release archives, installer scripts, GitHub
Actions, pre-commit hooks, and Python dependencies can change or be compromised.
TLS protects transport but does not by itself prove artifact identity.

## Attack surface

| Surface | Exposure | Location |
| --- | --- | --- |
| Core and suite Zsh | Executes in the current shell with user privileges | `functions.zsh`, `functions/**/*.zsh` |
| Interactive shell adapters | Converts selected rows, keys, previews, and user input into commands | `functions/**/*menu*.zsh`, `fzf` calls |
| Privileged workflows | Packages, services, processes, networking, logs, and system files | primarily `functions/sys/`, `functions/vpn/` |
| Destructive local/remote workflows | Deletes or rewrites files, Git history, branches, tags, issues, caches, and plugins | multiple suites |
| Installer | Integrates reviewed local source and publishes initial user configuration; prints manual shell activation instructions | `scripts/install.sh`, `scripts/install.zsh`, `scripts/install_fs.py` |
| Remote artifact installers | Downloads archives or scripts and installs tools or fonts | selected System and doctor workflows |
| Local configuration and overrides | Executes user-controlled Zsh at shell load | `~/.config/zdx/*.zsh` |
| Plugin loader and manager | Sources third-party code and updates Git origins | core loader and `zdx-plugins`; `sys-plugins` delegates to that owner |
| Local persistence | Telemetry, profiles, caches, backups, and plugin trees | `~/.config/zdx`, `~/.cache/zdx`, suite-specific paths |
| CI and release workflows | Executes repository and third-party automation with GitHub tokens | `.github/workflows/*.yml` |
| Contributor tooling | Executes pinned hooks and locked Python dependencies | `.pre-commit-config.yaml`, `.config/markdownlint.yaml`, `pyproject.toml`, `uv.lock` |
| Release distribution | Publishes archives, checksums, and attestations | `release.yml`, GitHub Releases |

## Required security invariants

Every conforming implementation preserves these properties:

1. No selected label, path, identifier, config value, or remote response is
   evaluated as shell code.
2. Sourcing is idempotent and performs no workflow side effect.
3. UI output cannot contaminate machine-readable stdout.
4. Destructive targets are exact, bounded, previewed, and confirmed.
5. Non-interactive destructive execution fails closed without explicit intent.
6. `sudo` wraps only contract-authorized protected probes or exact, validated
   transaction primitives.
7. Downloaded executable content is pinned and integrity-verified before use.
8. Secrets never enter previews, telemetry, logs, tests, demos, or errors.
9. Plugins and executable local configuration are presented as trusted code,
   never as sandboxed data.
10. A partial failure is visible and returns non-zero when the requested
    operation is incomplete.
11. Timeouts bound probes and transfers, not an already-started mutating
    transaction that may continue after the caller returns.

## Threat register

### T1. Credential or private-data disclosure

**Risk.** A secret is committed, printed in a preview, captured in telemetry,
included in a backup, or exposed through an error log.

**Current controls.**

- `gitleaks` runs through pre-commit and the CI pre-commit job.
- GitHub private vulnerability reporting provides a non-public disclosure
  channel, with the address in `SECURITY.md` retained as a fallback.
- `.gitignore` excludes common local secret and assistant-state paths.
- Environment browsing publishes names plus only `********` or `<hidden>`.
  Raw values never enter rows, previews, diagnostics, plans, or fallback
  output. An explicit copy sends one frozen value directly to a supported
  clipboard backend and never prints it on failure. Environment profiles are
  owner-only and plans reveal keys, not values.
- CI validates and redacts every remote display field before publication. It
  does not print authentication output, tokens, remote URLs, request headers,
  raw API errors, or environment values.
- Network providers receive no ZDX authorization or credential header. The
  local-only dashboard mode performs no public-IP, DNS, or ICMP request, while
  remote modes document that providers necessarily observe the caller's
  address.
- README demo regeneration uses an explicit `env -i` allowlist, private
  HOME/ZDOTDIR/XDG/TMPDIR paths, and a synthetic project. Git receives only the
  reserved `.invalid` identity fixture, disabled system configuration, and a
  ceiling at the private runtime root, so a temporary directory inside another
  repository cannot expose that ancestor's Git state. Canonical temporary
  parent paths containing `:` are refused because Git uses that character to
  separate ceiling directories. Inherited credentials, startup settings, fzf
  options, and plugin-directory overrides are not passed to the recorded
  process. The visible sequence browses Dev, System, AI, Git, and File menus;
  backend dispatch is disabled rather than exercising personal repositories.
- `git-auth` reports identity, remote alignment, and authentication state
  without printing tokens. Git remote rendering strips URL user information,
  query strings, and fragments before the value reaches UI output.
- Workspace repository displays use the same redaction boundary in
  `ws-info`, `ws-doctor`, `ws-repos`, and `ws-migrate`. Authentication summaries
  report only state, key paths, and public fingerprints; `ws-show-key`
  intentionally exposes only the public key.
- Telemetry currently records command labels and timing rather than command
  output.
- System symbol listing emits names only, and interactive inspection hides
  definitions whose names appear sensitive.
- The telemetry writer validates its five fields, excludes arguments and
  output, enforces owner-only state, and bounds record retention.
- Audited System commands capture only a configurable byte-bounded tail in a
  private temporary directory. Failure rendering is line-bounded,
  control-escaped, and replaces lines containing common credential indicators
  with a redaction notice.
- APT planning does not inspect generic package-manager process arguments or
  use a process-name scan as a lock oracle. Only the bounded fields required by
  the exact automatic-updater fingerprint are read to authorize a cooperative
  yield; APT itself arbitrates locks with its native zero-timeout acquisition.
  Homebrew process arguments are not inspected, and suite-owned Homebrew calls
  disable per-run analytics.
- Dotfile archives are owner-only, remain below `HOME`, include a digest and
  exact manifest, and warn that authentication configuration may be included.

**Residual requirements.**

- Masking must remain effective across every suite preview and diagnostic
  surface, not only the audited System paths, and be tested against case,
  delimiters, multiline values, and common token names. Preview and diagnostic
  code must never display raw credential files.
- Dotfile backups may still contain GitHub, SSH, or other sensitive
  configuration. Owner-only modes reduce local exposure but do not protect a
  copied archive, compromised account, or forgotten backup; retention and
  recovery need dedicated security tests.

### T2. Shell injection through dispatch, previews, or parsed output

**Risk.** A branch, filename, plugin name, URL, process row, or config value is
embedded into `eval`, a computed function name, `sh -c`, or an `fzf` shell
snippet and executes unintended code.

**Current controls.**

- Top-level Git and System dispatchers use explicit `case` arms.
- The Git command menu additionally requires the complete selected row to
  match its current snapshot. Its suite-owned foreground capture refuses data
  returned with a failed picker status, reads at most a validated 64 KiB result,
  and removes only the unchanged private result file. The size limit is checked
  after the picker exits; it does not cap writes while the picker runs. Nested
  Git resource pickers and confirmation dialogs retain their legacy capture
  paths and are not covered by this top-level migration.
- The Git loader accepts only the exact readable, non-symlink modules below its
  source-derived root. Git dispatch, pager composition, previews, and mutation
  targets use fixed cases, argument arrays, typed records, and validated opaque
  identifiers rather than `eval` or computed shell text.
- The idempotent core lazy loader uses an explicit command-to-file map below
  one source-derived module root and installs stubs through Zsh's function
  table; it does not use `eval`.
- AI executable discovery walks only validated absolute runtime `PATH` entries.
  If a supported Node CLI exists only behind a lazy NVM wrapper, it may
  passively read the protected standard `~/.nvm/alias/default` layout and
  accepts only a singly linked, 64-byte-bounded exact version alias and an
  owned, non-writable path chain. Ambiguous aliases and multiversion scans fail
  closed. It never sources `nvm.sh`, evaluates the alias, or invokes the
  wrapper. The exact Node interpreter is validated, and the NVM `bin` prefix is
  scoped only to the probe or updater child.
- The master router loads one exact adjacent common module, routes built-in
  suites through fixed `case` arms, and forwards arguments as literal array
  elements. Dynamic plugin dispatch requires a bounded identifier, exact
  membership in `ZDX_LOADED_PLUGINS`, and an already-defined matching function.
  Its foreground picker captures into a private bounded file, distinguishes
  cancellation from failure, and accepts only an exact row from the current
  menu snapshot.
- The unified command-menu preview uses a constant `case` and `printf` with
  fzf-quoted fields. Sections display explanatory text instead of an executable
  sentinel. The details toggle changes presentation only. App previews contain
  task labels and validated backend/descriptor/workspace metadata, never
  project command bodies. Master plugin completion applies loaded membership,
  identifier, reserved-name, and function-availability checks without sourcing
  plugins or executing their menus.
- Built-in suite, master, and plugin-manager picker wrappers locally empty
  `FZF_DEFAULT_OPTS`, `FZF_DEFAULT_OPTS_FILE`, and `FZF_DEFAULT_COMMAND`. This
  prevents ambient fzf settings from injecting executable bindings, hiding
  records, or changing the selection protocol. The parent environment remains
  intact. This is an integration boundary, not a sandbox for trusted user
  configuration, replaced helpers, or custom plugins.
- Picker previews use invocation-local `SHELL=/bin/sh` with fixed POSIX
  programs. VPN's validated private preview-directory path uses POSIX-safe
  single quoting, including for paths containing quotes and newlines. Its
  selected row contributes only fzf's integer index. Terminal plain mode
  changes picker controls without rewriting selected data.
- The Workspace entrypoint loads its exact sibling common file and fixed module
  inventory, routes only through an explicit 15-command dispatcher, and treats
  an executed file's arguments as `ws-menu` tokens rather than arbitrary
  commands. Its top-level menu uses validated fixed three-field records, a
  constant preview program, and a selection that must belong to the current row
  snapshot.
- The Developer dispatcher calls the public parser before any authoritative
  dependency or project probe. Menu availability metadata is advisory; the
  command checks it dynamically at first operational use. A missing backend
  required by one aggregate step does not gate independent steps. The absence
  of a shallow missing-tool annotation is not a readiness or provenance claim.
  Advisory probes are cached only for one rendered snapshot. `--multi`, profile save, and profile
  run share one explicit batch-eligibility allowlist and revalidate a
  selected row before dispatch or a complete stored profile before its first
  task, excluding destructive, source-rewriting, and nested orchestration
  commands. A compiler gate such as Clippy may remain eligible while its
  metadata discloses generated `target/` writes and project-code execution.
  Developer menu, confirmation,
  and profile pickers run `fzf` synchronously in the terminal foreground and
  capture selection stdout in a private, bounded, invocation-owned result file
  below a validated temporary root; a failed picker cannot carry selection
  data. A child file-size limit caps the file during picker output, followed by
  identity and size validation before reading. A selected record must belong
  to the invocation's row snapshot before its command field is used.
- Developer argument-free commands share one exact-arity parser: only zero
  arguments or one help flag is accepted before operational probes. Menu row
  builders reject pipe, newline, and NUL delimiters before emitting fzf data.
- Developer confirmation prompts visibly escape user-derived text before
  rendering it in fzf or the terminal fallback, preventing control characters
  in a path from changing the authorization UI.
- Many external calls quote targets and use arrays for complex commands.
- `zsh -n` parses tracked Zsh files.
- System telemetry browsing derives fzf rows from validated fields and never
  sends raw persisted JSON to a preview.
- System resource collectors emit typed TSV, preserve opaque identifiers, and
  revalidate the selected process, listener, or service state before mutation.
- Every System picker, including the nested symbol, telemetry, process,
  listener, service, font, and backup selectors, runs `fzf` synchronously in
  the terminal foreground and captures selection stdout in a private, bounded,
  invocation-owned result file that is identity-checked before reading and
  removed on every path. A selected nested row must belong to the invocation's
  snapshot before its fields are used.
- File, Py, Hugging Face, and GPU loaders source only fixed, exact-root modules
  and route through explicit `case` dispatchers. Their top-level menus accept
  only a row from the fixed suite-owned snapshot; user paths, remote metadata,
  environment records, cache records, and GPU process data never become shell
  preview text or computed commands. Foreground picker results are captured in
  private bounded files and revalidated before dispatch.
- The App loader sources only its exact module inventory and exposes an
  explicit two-command dispatcher. Project descriptors produce typed records,
  not command strings. Dynamic task rows carry only `app-run` plus a
  snapshot-local integer, and each backend/action combination maps through a
  fixed `case` to an argument-vector invocation. Package script bodies and
  descriptor comments never become preview or shell program text.
- CI, Environment, and Network now use exact-root module loaders, explicit
  dispatch, fixed menu previews, foreground private picker capture, and
  snapshot membership checks. CI treats GitHub JSON as bounded typed records;
  Environment parses dotenv/profile bytes passively without `source`, `eval`,
  or expansion; Network validates every host, interface, provider response,
  and backend token before a fixed invocation.
- The Oh My Zsh wrapper does not assume that adding a nested completion
  directory after `compinit` is sufficient. It validates owned, canonical
  completion files, accepts only safe `#compdef` command tokens, loads the
  functions without executing them, and binds them explicitly without rerunning
  global completion initialization. The master wrapper delegates nested
  completion to the registered suite completion.

**Residual gaps.**

- Several unaudited suite previews interpolate contextual values into shell
  program strings.
- Display rows in remaining unaudited suites may still be reparsed and reused
  as mutation targets.
- ShellCheck is configured for `.sh` and `.bash`, not `.zsh`; it is not a Zsh
  injection control. Zsh safety depends on review, BATS, explicit dispatch, and
  removal of dynamic shell construction.

**Required treatment.** Use fixed `case` dispatch, argument arrays, opaque
validated identifiers, option terminators, and post-selection revalidation.
Remove `eval` from interactive and configuration paths.

- The VPN suite no longer builds a preview program from selected data. It
  previously passed a large POSIX script to `fzf --preview` beginning with
  `cmd={2}` and `desc={3}`, so `fzf` substituted the selected record into shell
  program text unquoted, and that script also invoked `sudo -n` six times.
  Preview panes are now rendered in Zsh before `fzf` opens, written to one file
  per row in an owner-only private directory, and addressed by `fzf`'s integer
  row index `{n}`. The program text is therefore a constant, no record field
  reaches a shell, and no preview process holds privileges.
- VPN menu rows no longer encode data in the command token. A documented fourth
  field carries the target profile as an opaque value, which the entrypoint
  revalidates with the interface-name validator immediately before dispatch.
  Interface names must begin with an alphanumeric, so a validated name cannot be
  parsed as an option by `wg-quick`, a filename, or a device name.

### T3. Excessive or misdirected deletion

**Risk.** An empty variable, broad glob, traversal, symlink, archive member, or
wrong base directory causes deletion or overwrite outside the intended scope.

**Current controls.**

- High-risk workflows commonly request confirmation.
- Plugin removal performs a base-path descendant check.
- Several Git cleanup paths protect default branches.
- Audited Git mutations build typed plans from canonical refs, object IDs,
  repository and remote identity, then confirm and revalidate before execution.
  Broad operations support dry-run; normal and forced pushes use exact
  OID-or-absence leases; pulls fetch into invocation-owned temporary refs and
  promote reviewed object IDs with compare-and-swap updates. GitHub writes
  re-fetch selected state after confirmation and report partial failure.
  Tag publication and deletion inspect and mutate the same single frozen push
  URL; remote branch cleanup also rejects multiple push destinations. Stash
  drop, discard, and restore-from stop before later targets on interruption.
  After an accepted GitHub merge request, one final PR read verifies identity,
  head, and state, distinguishing a completed merge from a still-open pending
  request without polling or submitting another write.
- System cleanup displays an applicable plan, supports dry-run, fails closed
  non-interactively, executes only unique typed confirmed records, revalidates
  cache scopes, reports partial failure, and excludes shared `/tmp` and Docker
  resources.
- System dotfile restore verifies an owner-only archive, digest, exact
  manifest, size and entry limits, member types, traversal, destination links,
  and archive identity. It extracts privately, walks the real staging tree
  with NUL delimiters, rejects symbolic links, special files, foreign entries,
  and multiply linked files, and creates a mandatory pre-restore safety
  archive. Staging and destinations are revalidated after that backup, and
  regular files publish through same-directory temporaries and atomic renames.
- Nerd Font installation validates both the archive preflight and the actual
  extracted tree. Only a prior directory carrying the expected ZDX management
  marker is automatically deleted; an unmarked tree is retained outside the
  active font directory and reported for manual recovery.
- Developer cleanup freezes the literal and resolved project root plus its
  device, inode, and type, and matches it to the open working-directory anchor.
  Each reviewed target is stored as a relative path plus device, inode, and
  type; root and target identities are revalidated after authorization and
  around each relative removal. Discovery is bounded and NUL-delimited, does
  not follow links, and prunes `.git`, `*.git`, `.venv`, `node_modules`,
  `vendor`, `vendored`, and nested repositories discovered from `.git`
  markers. Each discovery stream and marker inventory stops at one above the
  configured plan bound; each category is capped after its streams are
  combined, and associative first-seen deduplication caps the final plan at
  10,000 unique targets by default. An excess fails before display,
  authorization, or mutation. The filesystem root, home directory, symlinked
  or replaced roots, and changed targets are refused. Root `build/`, `dist/`,
  and Cargo `target/` are the only build directories selected,
  `.terraform.lock.hcl` is preserved, and `--keep-build` preserves all three.
- Developer dependency updates construct and fingerprint a private plan before
  authorization. Specifier edits bind to parsed dependency-array elements and
  verify the complete resulting TOML, preserving unrelated strings, comments,
  and formatting. Normalized-name matching supports repeated declarations;
  compound constraints, markers, and newer existing minima are not rewritten.
  Publication requires the exact invocation-owned backup;
  a lock failure restores and verifies that backup and original mode. A later
  sync failure leaves the published metadata and lockfile visible and reports
  that the environment may be partial. Pre-commit autoupdate runs with
  `--freeze` against a private candidate. Its guard accepts only revision-line
  changes to immutable objects, preserves an existing object ID when the
  proposed version regresses, is incomparable, or moves the same tag, and
  installs every planned hook environment before atomic publication. Following
  an ordinary partial autoupdate failure, those same checks may publish usable
  proposals left by the updater while retaining the incomplete result and
  retry guidance. A Git transport failure may prevent candidate generation
  entirely. A failed
  environment installation or interrupted autoupdate prevents publication.
  After publication and Git hook installation it runs the applicable file-stage
  hooks with the published configuration and reports their findings; a hook
  finding returns a failure status without discarding the validated
  publication, so a repository cannot be held on stale hook revisions by a
  lint finding. A mutable non-version reference is frozen only when the
  candidate retains its exact original provenance label. If the live config
  changes during the external update,
  the command refuses to overwrite it and retains its original snapshot rather
  than risking loss of a concurrent edit. Pre-commit execution after
  synchronization uses only the exact project environment.
- Backup pruning is best effort: an owned, singly linked, regular stale copy
  is removed even when it predates the private-mode rule, and a copy that
  cannot be proven prunable is retained with a warning. Restore never relaxes
  the private-mode requirement, and pruning never fails the update whose
  backup was just published.
- `dev-update-all` freezes project-file and infrastructure applicability and
  reuses one PyPI reachability probe within its authorized invocation. It
  reports inapplicable steps as skipped and failed specifier queries as
  failures, and prints a per-step summary with direct retry commands. A PyPI
  failure does not block uv's configured index/cache or independent Git hook
  repositories. The probe distinguishes DNS, TCP,
  and stalled-TLS failures so an MTU mismatch behind a VPN is named instead of
  reported as a generic network error. Pre-commit skips only its public-PyPI
  package query when that probe fails. Its child Git processes use native HTTP
  low-speed limits scoped to the invocation; these are not total transaction
  or SSH deadlines and never justify terminating a mutating child. The
  aggregate skips the pre-commit
  update only when dependency publication left `pyproject.toml` and `uv.lock`
  inconsistent. A decline starts no step and non-interactive use requires
  `--yes`. Interactive cleanup independently previews and confirms its exact
  targets immediately before removal; `--yes` bypasses both prompts without
  bypassing validation.
- Developer temporary update workspaces freeze both the configured temporary
  root and workspace identities. Cleanup renames the proven inode to an
  unpredictable quarantine path, checks it again, and only then removes it.
  Changed paths are retained for recovery rather than recursively deleted.
  PyPI and update temporary roots must be safely owned by the current EUID or
  root-owned and sticky; non-sticky group/world-writable roots and sticky roots
  owned by another non-root UID are refused.
- Developer restore, export, and update publication validate the direct write
  directory owner, identity, and mode. A group/world-writable parent without
  sticky protection is refused before a pathname-based temporary is created.
- `dev-update-python` confirms before any mutating uv command when `.venv`
  exists. It requires current metadata and lock state and selects either the
  sole simple `X.Y` project pin or the current `.venv` minor; multiple, exact,
  complex, or ambiguous pins fail before mutation, and a non-CPython `.venv`
  is delegated to explicit runtime selection. It fingerprints
  `pyproject.toml` and `uv.lock`, then rechecks those inputs plus the interpreter
  implementation/version and pin selection after authorization. After another
  input check it runs `uv python install --upgrade X.Y`, builds a mode-`700`
  replacement on the same filesystem with
  `uv venv --clear --managed-python --python X.Y --relocatable <staged>`, synchronizes only
  through `UV_PROJECT_ENVIRONMENT=<staged> uv sync --all-groups --locked`,
  with input checks immediately before and after sync, verifies original and
  staged identities and CPython minor version, then swaps directories.
  Relocatable activation and standard entrypoint scripts survive publication
  and staging cleanup; arbitrary scripts and binaries retain upstream limits.
  Publication failure restores the
  exact original when safe; an interrupt or unverifiable rollback retains the
  recovery workspace. Without `.venv`, Dev performs no runtime mutation and
  delegates selection, preview, and authorization to the owning
  `py-menu venv-python-install` workflow.
- `dev-run-audit --fix` discloses that it upgrades the project environment and
  confirms before remediation. Non-interactive remediation requires
  `--fix --yes`.
- Developer read-only gates reject known writing flags. Ruff also removes
  `RUFF_OUTPUT_FILE`, Pyright refuses `--createstub`, and TFLint refuses
  `--fix`. Clippy refuses `--fix`, passes `--locked` to protect `Cargo.lock`,
  and is explicitly classified as mutating because Cargo writes `target/`.
- Developer persisted state is validated on every use rather than at load time.
  Dedicated state directories must be literal, owned, mode `700`, identity
  stable, inside the project or home, and free of symlink components. State
  files must be owned, singly linked regular files with no group or other
  access. Backups, reports, and new profiles use private no-clobber
  publication. Readers require exact mode `700`; a writer may restrict an
  already owner-controlled dedicated directory to that exact mode. An
  authorized profile overwrite revalidates and atomically
  replaces the exact destination.
  Automatic restore accepts only the exact invocation backup. Profile names,
  file bounds, and batch-eligible task tokens are validated before dispatch.

- Every destructive or multi-object VPN workflow computes its plan first,
  prints it, and only then confirms. `vpn-off-all`, `vpn-profile-rename`,
  `vpn-config-restore`, and `vpn-profile-remove` support `--dry-run` and
  `--yes`; a declined confirmation changes nothing and returns `0`, while a
  missing terminal without `--yes` fails closed with a non-zero status.
  `--yes` skips only the prompt: `vpn-profile-remove --yes` keeps the backup
  unless `--with-backup` is also given, so the flag can never widen the target
  set. Rename follows its matching backup and cached pointers and reports any
  partial failure. Restore publishes one bounded
  `<name>.conf.pre-restore` undo copy and the restored profile through
  same-directory atomic operations.
- VPN tunnel up and down execute the exact absolute validated profile path,
  binding its directory and file identity across authentication. A missing or
  unsafe profile refuses disconnection rather than selecting a same-name file
  from another directory. Reconnection and default connection fail when live
  state is unreadable. Interrupted sudo authentication and WireGuard probes
  do not trigger fallback work; protected profile existence, metadata, and
  checksum reads retain their interruption status through tunnel control.
  Tunnel interruptions stop later batch targets
  and exit the manager while cleaning its private preview state.
- Workspace roots are absolute, canonical, non-symlink paths that cannot be
  `/` or the home directory; `platform/identity` targets are allowlisted,
  grammar-checked descendants. Creation and removal validate that boundary
  before selection. `ws-remove` shows the exact SSH block, Git include,
  repository count, and canonical directory and supports `--dry-run` and
  `--yes`. It freezes directory identities and bounded content-and-metadata
  fingerprints for owned configuration files, refuses malformed SSH markers
  and Git-config parse failure, and publishes each configuration rewrite
  through a private same-directory atomic rename. It then renames the exact
  workspace into an unpredictable quarantine sibling, verifies its identity,
  and recursively deletes only that quarantine. On deletion failure it restores
  remaining data when safe or reports the recovery path.
- Workspace migration accepts only direct-child repositories with a real
  non-symlink `.git` directory from an owned canonical source. It fingerprints
  source, target, repositories, and Git directories around each move and
  refuses a cross-filesystem source and destination before any mutation.
  Selection rows are exact and unique. Optional origin rewriting remains a
  reported external partial transaction after the same-filesystem move. A
  failed origin query is not treated as absence, and a successful rewrite must
  pass an effective-URL postcondition. Interrupted origin operations stop later
  moves while retaining the already moved repository for inspection.
- A Workspace sync never uses generic `git stash pop`. It records the stash
  object created by the invocation and applies only that exact object. It
  deliberately preserves the recovery stash even after a successful apply
  because selector-based drop can race another process. Branch, HEAD, upstream,
  and fetched upstream object IDs are frozen and revalidated around stash,
  fast-forward, and restoration; fast-forward passes the exact already fetched
  object ID to `merge --ff-only --`, never the mutable upstream ref, and checks
  an exact postcondition on HEAD. Single and batch clone failures propagate,
  and batch clone returns non-zero after any failed repository. A retained
  partial clone does not block independent later clones: only the parent link
  count may refresh after each attempt, with device, inode, mode, and owner
  unchanged. Replacement or permission changes stop the remaining batch;
  interruptions preserve their status and stop later clones.
- Workspace stale-branch cleanup freezes repository and branch object identity,
  revalidates current/default/stale state and linked worktrees after
  confirmation, and uses `git update-ref -d` with the expected object ID.
  A repointed branch therefore survives atomically. A final worktree check
  reports the race and attempts to restore the exact prior object only while
  the ref remains absent.
- Workspace key rotation generates and validates the replacement before moving
  the active pair, installs through a private workspace-local staging
  directory, and attempts exact rollback after a publication or permission
  failure. Automatic backup cleanup accepts only complete, owned,
  non-symlink private/public pairs.
- File mutations are confined below an owned, non-group/world-writable current
  directory. Exact plans reject links, special files, hard-linked regular
  files, overlapping trees, unsafe destination parents, and mount crossings.
  Output overwrites freeze both metadata and SHA-256 content. Copies, moves,
  and extraction verify publication postconditions; deletion renames the exact
  reviewed object to a sibling quarantine and deletes only that identity,
  retaining and reporting recovery data on failure. TAR extraction first
  matches a private source snapshot, then uses that same object for preflight
  and extraction; it limits names, exact file sizes, total bytes, entries,
  types, traversal, links, and realized members before a new destination is
  published.
- Py lifecycle mutations accept only `.venv`, `venv`, or one safe direct child
  of `.virtualenvs` below an owned project. Creation freezes the absent target;
  automatic rebuild fails closed. Removal fingerprints the target and parent,
  rejects nested mounts, renames into a private same-parent quarantine, and
  revalidates the exact environment before recursive deletion. Package
  mutations freeze project metadata, lock state, backend, or the exact local
  environment interpreter after authorization. Poetry detection fails closed
  and ambient `pip` is never a fallback.
- Hugging Face cache removal targets one scanner-derived model or dataset
  directly below the independently resolved configured `HF_HUB_CACHE` in
  `HOME`. It requires the exact cache-directory name for the repository type
  and ID, prints the exact target, supports dry-run and explicit
  non-interactive authorization, revalidates trusted ancestors plus root and
  target identity, parses a bounded JSON mount inventory, and moves the target
  to a random sibling quarantine before recursive removal. Failure or an
  interrupt after quarantine reports the retained recovery path. Space entries
  are skipped without invalidating the supported inventory.
- App treats every project task as potentially mutating executable code. It
  prints the fixed backend plan, supports a side-effect-free dry run, confirms
  one interactive task or batch, and requires `--yes` outside a terminal.
  Authorization never bypasses descriptor, workspace, dependency, or
  post-authorization task-record revalidation. Multi-task execution is
  sequential and reports partial failure.
- CI-owned writes resolve exact numeric resource IDs from one bounded
  repository-bound snapshot, protect the newest run, deployment, or release,
  show the complete plan, support dry-run, fail closed non-interactively, and
  re-fetch both repository identity and complete target records after
  authorization. Sequential GitHub API failures remain visible as partial
  transactions. Tag and issue lifecycle is delegated to the public Git owner.
- Environment file publication freezes destination and parent identity,
  stages mode-`600` content in the same directory, and uses no-clobber or exact
  authorized replacement. Profile deletion moves one unchanged mode-`600`
  owner file into a private same-directory quarantine and deletes only that
  identity, retaining and reporting recovery data on failure. Picker,
  inventory, publication, and deletion temporary paths must prove that they
  are owned direct children of the expected root before permission changes or
  cleanup can touch them; malformed multiline output from a single-select
  picker fails closed.

**Residual gaps.**

- Dry-run and exact-plan support remains inconsistent outside the audited Git,
  System, Developer, VPN, File, Py lifecycle, Hugging Face cache, App, CI,
  Environment, and targeted Workspace removal paths.
- Workspace migration, stale-branch cleanup, key rotation, and optional broad
  sync actions still need uniform dry-run and explicit non-interactive
  authorization controls. Workspace creation can leave partial state after a
  late failure because its workspace, SSH configuration, and Git include
  publications are not one rollback-capable transaction.
- Migration's optional remote rewrite occurs after the repository move. An
  external Git failure leaves the repository placed in the workspace and is
  reported as a partial transaction; there is no generic rollback of that
  external update.
- Other destructive suites still need protected-root, traversal, symlink,
  cancellation, and partial-failure tests appropriate to their deletion
  surfaces. The new File, Py, and Hugging Face controls have focused tests
  authored, but the combined gate was deliberately left for the maintainer and
  repository-wide and real-host acceptance remains pending.
- `dev-run-hooks` and `dev-run-ruff-format` rewrite files without a separate
  confirmation. That is their documented purpose, but it means a
  `dev-run-all-checks` run on a project with formatting hooks can modify the
  working tree.
- The audited System cleanup and restore controls have focused high-risk BATS
  coverage; the combined repository gate and real-host smoke tests remain
  separate acceptance requirements.
- Developer identity checks narrow but cannot eliminate the final race between
  the last userspace comparison and `rm` or atomic rename when a hostile process
  runs with the same EUID. Portable Zsh does not expose a common
  handle-relative unlink API for every supported host.
- External package managers, hook runners, runtimes, and linters retain their
  own transaction semantics. Developer can restore the project files it owns
  and propagate failure, but cannot generically reverse every external-tool
  side effect. In particular, `uv python install --upgrade X.Y` can change
  uv-managed global Python installations and is not part of the recoverable
  `.venv` directory transaction.

**Required treatment.** Build an immutable plan, canonicalize targets, reject
protected roots, show exact scope, support dry-run for broad operations, fail
closed non-interactively, and report partial failure.

### T4. Privilege escalation or confused-deputy behavior

**Risk.** Unvalidated input, a downloaded file, or a broad command is executed
through `sudo`, or a keepalive outlives its operation.

**Current controls.**

- Privileged operations generally call `sudo` only when required.
- System resource actions retain per-operation authentication without a
  keepalive. The update aggregate is the bounded exception: after
  authorization it reuses a valid non-interactive sudo timestamp or announces
  and performs one `sudo -v` when an interactive prompt is required. During
  the initial consecutive privileged entries, an invocation-owned child runs
  only `sudo -n -v` with closed stdin every 30 seconds. On macOS this scope
  includes the adjacent Homebrew entry because casks can require sudo. The
  refresher cannot prompt, and every privileged command constructed by ZDX
  uses `sudo -n`. A private `zpty` handle owns the worker outside the caller's
  job table. Cleanup sends a fixed stop request, requires a bounded
  acknowledgement and confirmed exit, and deletes that exact handle after the
  last privileged entry; an `always` block performs the same ownership-scoped
  lifecycle on early failure, return, or interruption. This prevents
  asynchronous `[n] ... terminated` or `done` UI without relying on a
  potentially reused PID. A direct `update-apt` invocation
  authenticates once; its refresher uses only `sudo -n -v`, every later signal
  or package operation that requires elevation uses `sudo -n`, and the worker
  is owned only for that APT sequence with the same `always` cleanup.
- `update-system` validates and displays the single stable
  `${HOME:A}/.zdx-update-system.lock` path while planning. The canonical home
  must be effective-user-owned, symlink-free, searchable, and not group/world
  writable. Neither shared `/tmp` nor runtime/cache availability can select a
  second lock domain. The persistent mode-`0600` file is a single-link regular
  file whose descriptor/path identity is checked.
  After authorization, it opens the persistent mode-`0600` file and
  `zsystem flock -t 0` refuses overlap immediately before any update entry.
  Descriptor cleanup releases the lock on every exit path while the file is
  never unlinked and remains reusable. A nested invocation refused because
  this shell already holds the lock leaves the outer descriptor untouched.
- System process, listener, and service actions show an exact target, confirm
  it, and revalidate identity or state before the final operation.
- Foreign-process signals and systemd mutations scope `sudo` to the final
  validated `kill` or `systemctl` call. They revalidate before `sudo -v`,
  revalidate after authentication, and execute the final action with
  `sudo -n`. Launchd uses the current user domain.
- APT is the first entry immediately after aggregate authorization and
  pre-authentication. Planning never calls the generic package-manager busy
  detector: its only process discovery is the exact unattended fingerprint,
  and the single native APT attempt remains the sole lock arbiter.
  Before any signal, a non-link dpkg journal must be empty and a bounded
  `dpkg --audit` must be clean. The audit resolves absolute `env` and `dpkg`
  programs whose files and directory chains are root-owned and not
  group/world-writable, then runs them under fixed `env -i`. A dirty or
  unverifiable state fails without signaling the current owner, avoiding
  abandonment of the process that may be able to finish the transaction. Only
  after that check, immediately before the single mutation sequence, a
  root-owned pidfile, exact command, stable start identity, automatic apt-daily
  cgroup, safe packaged program, and enabled minimal-step behavior permit one
  cooperative `SIGTERM` through the validated root-owned `/usr/bin/kill`.
  An argv containing the `--no-minimal-upgrade-steps` opt-out, including any
  abbreviation accepted by `optparse`, makes the process ineligible.
  The real process's `/proc/<pid>/status` must also contain a valid `SigCgt`
  mask with SIGTERM marked as caught. Every fingerprint reconstruction and
  revalidation checks that bit; a missing, malformed, or cleared mask prevents
  the signal rather than trusting package version alone.
  Both supported `MinimalSteps` spellings are queried and revalidated by
  bounded, fixed-`env -i` calls to absolute `env` and `apt-config` programs
  whose files and directory chains are root-owned and not group/world writable.
  Caller `APT_CONFIG`, `PATH`, proxies, and exported-function state cannot
  authorize the signal. A separate bounded, single-record package query uses
  trusted absolute `env`, `dpkg-query`, and `dpkg`, fixed `env -i`/`PATH`, and
  closed stdin to prove the package is installed and compare its Debian
  version. A validated leading numeric Debian epoch is removed before the
  upstream-version comparison, preventing an epoch from falsely satisfying the
  feature gate. TERM is allowed only at normalized 0.94 or newer. The 0.94
  line implements OR/default-false semantics, requiring at least one supported
  `MinimalSteps` spelling to be explicitly true. Version 0.95 and newer use
  AND/default-true semantics: both effective values must be true, with each
  absent key treated as true. Missing, old, or ambiguous package state cannot
  authorize a signal. The gates encode upstream commits `5f013f8`
  (TERM support in tag 0.94) and `16fb837` (true-by-default `MinimalSteps` in
  tag 0.95), and are repeated immediately before signaling.
  Identity is checked before and after `sudo -v`, and the signal uses
  `sudo -n`; every other owner is left untouched. A validated opt-out disables
  the signal without selecting a wait. The single APT entry uses
  `DPkg::Lock::Timeout=0`, `Acquire::Retries=0`, `Dpkg::Use-Pty=0`,
  `Dpkg::Options::=--force-confdef`, and
  `Dpkg::Options::=--force-confold`. Simulation and mutation use a validated,
  absolute, root-owned, non-group/world-writable `env -i` with only fixed
  nonexistent HOME/XDG roots, locale, system path, terminal, debconf, and
  apt-listchanges settings, plus closed stdin. `APT_CONFIG`, proxy variables,
  exported-function encodings, and all other caller or post-sudo state cannot
  reach APT; required proxies must live in root-owned APT configuration. These
  controls prevent terminal, debconf, apt-listchanges, and conffile prompts.
  There is no polling, sleep, or retry. A native lock refusal therefore fails
  that entry immediately; the default aggregate then continues with its
  subsequent authorized entries. The path never stops timers, deletes lock
  files, or automatically repairs an uncertain dpkg state. Normal APT phased
  policy remains the default. Explicit `--include-phased-updates` consent adds
  only `APT::Get::Always-Include-Phased-Updates=true` to the APT simulation and
  every APT mutation; the aggregate does not forward it to other entries.
  After the mutation sequence, including when a failed mutation skips later
  phases, the trusted dpkg journal and audit checks run again. Failure
  suppresses the completion message and reboot-marker inspection and returns
  non-zero. A clean post-audit permits advisory inspection of the safe
  `/run/reboot-required` marker even after a mutation failure; ZDX does not
  reboot or alter the transaction result.
- DNF5 elevation always runs the same fixed wrapper under a trusted root-owned
  Zsh. Bounded version and main-config probes separately use a validated
  absolute, root-owned, non-group/world-writable `env -i` executable with
  non-existent HOME/XDG
  roots, a fixed system `PATH`, `LC_ALL=C`, `TERM=dumb`,
  `DNF5_FORCE_INTERACTIVE=0`, and `PYTHONNOUSERSITE=1`; inherited plugin,
  loader, Python, and user-config inputs cannot affect those probes. The
  version parser selects a fixed compatibility path. DNF5 5.0/5.1 deliberately
  do not depend on or run the main-config probe, including on 5.1 builds that
  provide it, and pass no persist directory. DNF5 5.2/5.3
  require one `installroot=/` and normalized absolute `persistdir`, with no
  lock capability. DNF5 5.4+ additionally requires one unambiguous boolean
  `skip_system_repo_lock` capability or fails closed. The privileged command
  starts the trusted absolute `env -i` with only the fixed environment, then
  invokes Zsh. Wrapper positional argv contains only mode, lock path, optional
  frozen persist directory, and validated absolute DNF and `env` programs; no
  secret assignment appears in argv or UI. No inherited environment reaches
  Zsh; root-owned `/etc/zshenv` is the remaining system startup-file trust
  boundary. The wrapper revalidates both programs, then a second trusted
  `env -i` starts DNF with the same fixed environment. This discards all caller
  and post-sudo variables, including proxies and exported-function encodings
  with names that Zsh cannot enumerate through `$parameters`. Required proxy
  policy must live in root-owned DNF configuration. DNF5 5.0/5.1 use sanitized wrapper mode `0`
  with only `--installroot=/`; DNF5 5.2/5.3 use mode `0` with the frozen persist
  directory. Their transaction locks remain non-blocking.
  Wrapper mode `1` for DNF5 5.4+ revalidates the path, its components, lock
  file, and absolute DNF5 program, acquires the same whole-file `fcntl` write
  lock through `zsystem flock -t 0` before starting DNF5, and holds it while
  passing only `skip_system_repo_lock=True`; the separate transaction lock
  remains enabled. The outer wrapper and inner DNF process both receive closed
  stdin. The exact fixed wrapper path and resolved `sudo -n` prefix are shown
  without elevating computed shell text or environment values.
- Homebrew performs its own resource-lock arbitration; ZDX does not infer a
  lock from process-name or argument substrings. A native Homebrew failure is
  isolated to that aggregate step. `update-brew` resolves one absolute
  executable path and invokes it directly; retry, analytics, askpass, and
  no-auto-update policy use local exports, not an `env` command that a caller
  function could intercept. On Darwin, the validated fixed
  `SUDO_ASKPASS=/usr/bin/false` makes Homebrew's internal `sudo -A` fail instead
  of prompting when the shared timestamp is unavailable. The mandatory
  `brew upgrade --no-ask` avoids Homebrew ask mode silently skipping an
  authorized non-TTY mutation while returning success. Linuxbrew does not use
  the Darwin-only askpass guard. Every Homebrew phase receives closed stdin.
- Audited System package operations resolve direct-root versus narrow `sudo`
  execution immediately before the final package-manager command. Their UI
  renders the exact resolved prefix: `sudo -n` when escalation is required and
  no prefix for direct-root execution.

**Residual gaps.**

- Privileged actions outside the migrated System resource paths have not all
  adopted equivalent post-confirmation revalidation.
- Package-manager paths outside the audited System flow, VPN, Docker, and other
  suite-specific privilege paths still require individual review and tests.
- A PID or service can still change after the final userspace comparison and
  before the kernel or service manager receives the operation; the smallest
  possible command scope limits but cannot eliminate that race.

**Required treatment.** Keep discovery unprivileged, validate twice, display the
exact operation, scope `sudo` narrowly, clean keepalives on every path, and
never elevate downloaded or user-computed shell text.

- The VPN suite elevates through four primitives with one sequence: announce the
  exact privileged operation, authenticate once with `sudo -v`, revalidate the
  target, then run each narrow transaction primitive with `sudo -n --`, which
  cannot prompt. Revalidation after authentication is tested by removing the
  profile between the two calls. Directly readable paths never escalate:
  listing profiles, checking backups, and rendering previews record no `sudo`
  call at all.
- `vpn-config-edit` no longer runs `sudo $EDITOR`. That gave any editor shell
  escape, such as `:!sh` in Vim, a root shell, and `$EDITOR` was additionally
  subject to word splitting. It now uses `sudoedit`, which copies the file, runs
  the editor as the invoking user, and reinstalls the result as root. There is
  deliberately no fallback to `sudo $EDITOR`; when sudoers forbids `sudoedit`
  the command reports the failure and changes nothing.
- Imported profiles can no longer introduce commands that `wg-quick` would
  execute as root. Import accepts only a private, singly linked, current-user
  regular file no larger than 1 MiB, verifies `[Interface]` and `[Peer]`, and
  refuses every `PreUp`, `PostUp`, `PreDown`, or `PostDown` assignment. It
  fingerprints the source around a private staging copy and atomically installs
  validated mode-`600` content without replacing an existing profile.
- The WSL DNS hooks the VPN suite writes are executed by root on every tunnel
  transition, and their resolver address came from an imported profile's `DNS =`
  line with no validation, which was an injection path from a downloaded profile
  into a root-executed `sh -c` body. The value is now validated as a strict
  comma-separated list of at most eight semantically valid IP literals and
  refused otherwise; each configured fallback must be exactly one valid IP.
  A sentinel is trusted only when its exact complete generated hook block is
  present, so a partial or imitated marker cannot bypass hardening.
  Patching fingerprints the profile and directory, builds an owner-only staged
  result, asks `wg-quick strip` to parse it before publication, revalidates
  after authentication, and replaces the live profile atomically. The original
  remains untouched on validation or parse failure. The IPv6 compatibility
  rewrite is also staged and parsed, keeps a one-time backup, and prevents
  `wg-quick up` when no required IPv4 value can be retained.

**Residual requirement.** VPN privileged helpers pass fixed command names and
validated arguments to `sudo -n`. They rely on the host retaining sudo's normal
trusted `secure_path`; a sudoers policy that preserves an attacker-controlled
`PATH` is outside the suite's trust model.

### T5. Compromised remote installer or artifact

**Risk.** A moving `latest` archive or installer script is replaced upstream or
in a compromised release channel and then installed, potentially as root.

**Current controls.**

- Downloads use HTTPS and generally fail on HTTP errors.
- Private temporary locations are used for audited System artifact flows.
- `sys-fonts` defaults to the pinned Nerd Fonts v3.4.0 release, verifies the
  exact archive against the upstream SHA-256 manifest, validates bounded tar
  metadata as a preflight, then performs a NUL-delimited inspection of actual
  extracted names and objects. Controls reject invalid paths, control and
  delimiter characters, links, special or foreign-owned objects,
  multiply-linked files, duplicate basenames, and excessive inventories before
  staging replacement without `sudo`.
- New font families carry a family/version management marker. Automatic
  cleanup is limited to a prior tree with a valid marker; unmarked content is
  moved to a reported sibling recovery directory rather than deleted.
- `update-awscli` refuses automatic bundle installation when the detached
  signature procedure has not been performed.
- `update-starship` updates only an installation owned by Homebrew or Cargo and
  refuses an unknown owner instead of executing the upstream installer.
- The aggregate deduplicates Homebrew-owned AWS CLI, Starship, fzf, uv, Google
  Cloud SDK, and Repomix installations under `update-brew`. uv ownership is
  bound to the canonical active executable below the resolved Homebrew prefix;
  the mere presence of a second Homebrew uv formula cannot suppress the active
  self-managed updater. Direct self-update uses that same resolved path. Native
  macOS `softwareupdate` remains a separate operating-system scope.
  A direct Homebrew-owned uv update targets only its formula with
  `upgrade --no-ask uv`, child-local Homebrew controls, and closed stdin. It
  resolves the launcher again after a possible Cellar replacement and verifies
  the resulting version; self-managed uv updates also require a successful
  bounded post-update version probe.
- Node updates resolve external fnm once, or require nvm to be already loaded
  from an existing installation. Discovery does not source `nvm.sh`.
  Installation, default selection, activation, and current-version checks have
  independent failure handling. A later failed phase preserves the installed
  runtime and returns nonzero instead of claiming a complete update. NVM
  activation stays in the invoking shell to preserve its intended session
  changes.
- Repomix updates bind the active external executable to its package owner.
  A bounded passive package descriptor must match the declared npm binary to
  that canonical path below the exact global prefix; Homebrew attribution
  likewise requires its active formula path. Unknown custom launchers fail
  before version execution or mutation, and wrappers do not trigger a new
  installation. The npm program and prefix are revalidated before explicit
  `--prefix` dispatch, with runtime, version, and ownership checks after the
  update.
- The aggregate freezes the applicable entry set before authorization and
  executes only those exact records without rediscovery, substitution, or
  insertion. By default each authorized entry is attempted once;
  `--fail-fast` stops at the first failure.
- Package candidate lists are advisory snapshots. The package manager refreshes
  metadata and resolves the final transaction at execution, so confirmation
  authorizes that documented dynamic scope rather than a frozen candidate set.
  An unavailable APT simulation does not bypass authorization or dpkg guards:
  execution can still attempt its own index refresh, while dry-run reports
  failure without mutation. The refresh uses `--error-on=any`; any index error
  prevents full-upgrade and autoremove, preserves post-transaction audit, and
  makes the entry fail. Older APT versions without this option fail visibly
  instead of falling back to accepting incomplete indexes.
- The maximum aggregate includes mutable Git-owned and Hermes updates by
  default; `--safe-only` excludes them. Direct Git-owned fzf, Oh My Zsh, and
  custom-plugin updates require owned, symlink-free checkouts below `HOME`,
  display origin and HEAD, fingerprint the repository and `.git` directory,
  revalidate after authorization, and pull fast-forward only. The fzf installer
  must also match its tracked blob and pass file-identity checks immediately
  before execution. One aggregate authorization — the interactive plan
  confirmation or `--yes` — pre-authorizes every applicable mutable origin,
  and the dry run is the review path before unattended execution.
  `update-hermes` discloses its broad effects, requires an explicit origin
  trust decision, and requests the upstream full pre-update backup.
- AI CLI updates resolve only installed external launchers, require a
  validated bounded version result, validate current-user/root ownership and
  writable mode, and freeze the launcher, canonical target, metadata, and
  checksum before review. Their plan displays exact fixed self-updater
  arguments, requires one explicit remote-code decision, and revalidates
  immediately before delegation. Missing tools are skipped without
  installation; detected but unprobeable tools fail closed. The System
  aggregate excludes the AI step under `--safe-only` and passes
  `--skip-homebrew-managed` after its Homebrew step. An NVM-resolved plan also
  freezes and revalidates the exact Node interpreter's metadata and checksum.
  After a successful self-updater, the bounded pre/post version and validated
  executable fingerprint determine whether the result is `updated` or
  `already current`; the latter requires both to remain unchanged. Failed and
  skipped targets remain separate summary outcomes. A zero exit status alone
  therefore cannot overstate an unchanged CLI as updated. With `--result-tsv`,
  the AI owner emits one versioned, bounded record for every requested target.
  System captures only that stdout protocol, requires all eight canonical IDs
  and labels once and in order, validates fixed outcomes, reasons, and statuses,
  and fails closed on incomplete or malformed data. The synthesized records
  contain no vendor output, paths, versions, or credentials.
  Updater or output-sink statuses `130` and `143` stop later mutations and are
  preserved through public routing after private-output cleanup. An updater
  interruption takes priority when both pipeline children are interrupted;
  ordinary sink failures remain integrity failures. Remaining eligible targets
  receive fixed `not-run:interrupted` records with that same status, accepted by the System
  parser only for those interruption codes. Skipped targets do not count as
  successful work for partial-result timing.
- Cursor and Amp version probes leave `HOME` unchanged while redirecting
  incidental runtime cache writes to an identity-checked private probe
  directory. Amp's Bun runtime has a fixed 16 MiB per-file ceiling while probe
  stdout and stderr remain independently limited to 64 KiB. AI updater output
  is drained into a private 256 KiB tail and is never replayed verbatim; the
  updater receives `/dev/null` as stdin. Only fixed authentication and
  precondition markers are classified for actionable diagnostics; ZDX does
  not invoke a vendor login, logout, or reinstall operation.
- Hermes version discovery invokes `--version` with child-local unbuffered
  Python output. It accepts only a complete typed installed-version banner
  after success or status `124` from the subsequent ancillary lookup deadline;
  other failures and output-limit violations remain failures. All CLI probes
  receive closed stdin and a process-group deadline. Hermes may itself fetch
  metadata and write `~/.hermes/.update_check`, including during dry-run; that
  vendor side effect is bounded but is not an updater authorization.
- OpenCode's known zero-status failure is classified only when its private
  capture contains the complete anchored `Upgrade failed` terminal line.
  It becomes a nonzero result with a fixed reason rather than an unchanged-CLI
  success. Specific authentication and precondition classifications take
  precedence; vendor output is still withheld.
- Local installation may expose the active ZDX source root through the exact
  Oh My Zsh `plugins/zdx-suite` symbolic link created by the installer. Update
  discovery derives that active root from the validated `_ZDX_FUNCTIONS_DIR`,
  verifies the link's owner and stable `lstat` identity around canonical
  resolution, and requires owner-bound, symlink-free source markers and a real
  `.git` directory below `HOME`. Only an exact target match is classified as
  an externally managed development checkout, and no Git operation runs
  through the link. The exception is non-mutating and exact: an unknown link
  or the same basename targeting another checkout remains a visible safety
  failure. It does not weaken the no-symlink plugin loader or generic
  Git-checkout contracts.
- The Developer suite no longer pipes a remote installer to a shell. The former
  `curl -LsSf https://astral.sh/uv/install.sh | sh` fallback in
  `dev-update-toolchain` and the `curl … install_linux.sh | bash` fallback in
  `dev-update-tflint` were removed. Host `uv` maintenance delegates to the
  targeted public `sys-menu update-uv-system` owner. Developer maintenance
  never invokes ambient Python or `pip`, so PEP 668 externally managed
  environments remain intact. Terraform binds tfenv, Homebrew, and APT claims
  to the resolved active binary. tfenv additionally requires its canonical
  launcher to be the active Terraform launcher's sibling and ignores inherited
  `TFENV_ROOT` for attribution. Developer reports the proven owner workflow
  without executing the dynamic `tfenv install latest` path; TFLint applies
  the same rule to Homebrew and reports `sys-menu update-brew`. A separately
  installed package cannot claim a different active executable. An unproven
  owner gets the documented download-and-verify procedure and no host
  mutation. No flag re-enables either installer pipe.
- TFLint plugin initialization is no longer an implicit part of linting.
  `dev-run-tflint` runs recursive linting by default; the caller must select
  `--init`, review the remote-code effect, and confirm or pass `--yes`.
  Initialization status is propagated before linting proceeds.
- Ephemeral runners are an explicit trust decision. Declared Python quality
  gates must resolve inside the exact project `.venv`; they never fall through
  to a local binary or opt-in `uvx`. Only undeclared Python tools retain those
  fallbacks. Node gates use the project binary, then a local binary, then
  opt-in `npx`. Project-local Node executables remain project-controlled code;
  their presence avoids the `npx` fallback but is not an integrity guarantee.
  Installed-package inventories use only an
  importable module through `.venv/bin/python -I -m`; global,
  declared-but-unsynchronized, isolated, overlay, and ephemeral backends are
  refused. The project interpreter must report that exact non-symlink
  environment as `sys.prefix`; isolated probes exclude the current directory,
  `PYTHONPATH`, and the user site. Runnable modules and executable fallbacks
  are confined to `.venv`, and a script fallback must name the exact project
  interpreter in its shebang. Every index-selected ephemeral step requires
  `DEV_ALLOW_EPHEMERAL=1` and the actual `uvx` or `npx` runner executable.
- Developer pytest, coverage, and pre-commit hook invocations use that exact
  project-environment boundary. A missing installed dependency fails visibly;
  global pytest, coverage, and pre-commit binaries cannot manufacture success.
  Tests, configured hooks, and PEP 517 builds remain deliberate
  project-controlled-code boundaries; effect labels do not claim to sandbox
  them. `dev-build-package` may also resolve and execute isolated
  `build-system.requires` dependencies outside `uv.lock`; the command discloses
  that boundary but does not establish artifact provenance.
- The Py suite never bootstraps a package backend or invokes ambient `pip`.
  Project package and isolated-tool mutations disclose that index content is
  executable code, require an explicit reviewed plan, and bind execution to the
  frozen uv, Poetry, pipx, or project-environment scope. Poetry metadata or
  backend ambiguity fails closed.
- Hugging Face operations require an already-installed, API-compatible
  `huggingface_hub` below major version 2 through an isolated Python probe.
  The suite never invokes `pip`, `uvx`, `uv run --with`, or a remote installer.
  Downloads populate the library-managed cache and are not executed by ZDX.
- App never executes a descriptor-provided shell string. It transfers control
  only to an installed fixed backend after the user reviews and authorizes the
  exact task plan. That backend still executes trusted project code by design;
  ZDX does not claim to sandbox recipes, package scripts, Make targets,
  Compose images, or backend configuration.
- CI workflow dispatch authorizes remote repository code explicitly. It
  freezes one active numeric workflow ID, exact local branch, local commit,
  and matching GitHub branch commit before the plan and revalidates them after
  confirmation. GitHub still resolves the branch when accepting the dispatch,
  so a final concurrent remote ref movement remains outside a local lease.
- The dependency doctor treats `timeout`/`gtimeout`, `findmnt`, the active GNU
  `tar`, and compatible installed `huggingface_hub` as semantic capabilities.
  Its Python probe is isolated and deadline-bound; none of these capabilities
  is silently added to the batch installer.

**Residual gap.** Network and installer workflows outside these audited System
and Developer paths have not all been shown to pin and verify artifact identity.
Enabling `DEV_ALLOW_EPHEMERAL=1` reintroduces unpinned, unverified remote
execution by the user's own decision: an ephemeral runner resolves whatever the
index currently publishes. TFLint initialization is explicit, but its plugin
artifacts and trust policy belong to TFLint; authorization is not provenance
verification. The manual TFLint update path tells the user to choose a pinned
release and verify its checksum, but the suite does not download or verify that
artifact on the user's behalf. Git-owned updates also remain mutable remote
code even when their origin and current commit are displayed. Hermes follows
its configured branch rather than a ZDX-pinned release, so confirmation and
rollback reduce impact but do not prove publisher authenticity.
Py package and tool installation still executes mutable index content by the
user's explicit decision. PEP 517 builds can resolve isolated backend
requirements outside the contributor lock, so reviewing `uv.lock` alone does
not cover that build-time supply chain. Hugging Face authentication, repository
content, and cache behavior remain external library and service trust
boundaries.

**Required treatment.** Pin versions, verify an upstream checksum or signature,
use a private temporary directory, validate archive members and expected files,
and elevate only the verified final install step. If upstream provides no
verifiable artifact, show official manual instructions instead of executing it.

### T6. Malicious or compromised plugin and override code

**Risk.** A plugin Git origin, plugin update, `config.zsh`, or `overrides.zsh`
executes arbitrary code in the user's shell.

**Current controls.**

- The runtime loader requires an owned, non-symlink plugin root and an owned,
  singly linked regular entrypoint that remains an exact child of that root.
- Plugin directory names and required entrypoint/function names are checked.
- Plugin installation and runtime loading perform a Zsh syntax check; runtime
  path validation repeats immediately before source.
- The local installer accepts a reviewed checkout, validates its exact plugin
  destination, and preserves an identical source or owned link. It refuses an
  unrelated destination instead of deleting or replacing it. It performs no
  download, Git update, dependency installation, or `.zshrc` rewrite. Its
  side-effect-free preview precedes confirmation; non-interactive mutation
  requires explicit `--yes`.
- The installer creates new private configuration directories with mode `700`
  and publishes the initial executable `config.zsh` with mode `600` through a
  local Python 3.8+ no-clobber filesystem helper. Existing configuration is
  preserved only after ownership, regular-file, single-link, readability, and
  owner-only permission checks. Unsafe objects are refused rather than
  silently adopted or chmodded. Publication is per object: partial progress
  is reported on failure and can be reused by a subsequent exact rerun.
  The tracked template and README present configuration, overrides, and
  plugins as trusted Zsh rather than passive data. See
  [`installation.md`](installation.md) for paths, activation, and update
  ownership.
- Loader diagnostics preserve useful plugin stderr instead of hiding every
  source-time error.
- Plugin removal contains a path-boundary check and confirmation.
- The plugin contract requires namespacing and source safety.
- `zdx-plugins` is the single lifecycle owner; `sys-plugins` is a compatibility
  bridge that delegates to it instead of maintaining a second implementation.

**Residual risk.** There is no sandbox. Obtaining a checkout from mutable
`main` does not authenticate its source; review and any independently trusted
signature verification happen before local installation. The installer cannot
prove that the selected code is harmless or exclude every same-user filesystem
race. Its Linux fixtures do not establish native macOS installation behavior.
The runtime loader sources plugins at shell load, and structural validation
cannot identify malicious behavior.
The core `zdx-plugins` manager still installs, updates, and sources user plugin
code by design. Its structural checks do not prove trust, and its update path
still needs staged validation, atomic rollback, and a renewed origin/commit
trust decision.

The manager's update path also ignores a non-zero entrypoint `source` result
and can announce a successful reload after loading failed. Its interactive
capture and stream behavior still require migration. The catalog therefore
describes custom plugins only as loaded in the current shell; it does not
claim an audit or successful lifecycle transaction. These manager defects are
outside the menu-presentation change and remain part of the treatment below.

**Required treatment.** Present plugins as arbitrary code, stage and validate
updates before activation, show origin and commit, require trust, preserve the
previous version on failure, and maintain one owning plugin manager.

### T7. Local persisted-state tampering or leakage

**Risk.** Telemetry, profiles, backups, or caches are readable by other users,
grow without bound, contain malformed records, or are replaced with links to
unintended targets.

**Current controls.**

- State is generally kept under the user's home.
- Telemetry is opt-in.
- Several writers use suite-specific directories.
- System telemetry readers refuse symlinks, non-regular files, files not owned
  by the current user, unreadable files, and files above a configurable 5 MiB
  default limit.
- Readers validate the five-field telemetry schema, skip malformed records,
  cap a single duration at one year, and tolerate a partial final record
  without evaluating it.
- The opt-in core writer validates the same five fields, rejects unsafe or
  oversized state, enforces owner-only directory and file modes, uses a lock
  and atomic replacement, and retains a bounded number of records and bytes.
  A partial final input line is discarded before the next complete record is
  published, so records are never concatenated across a crash boundary.
- Telemetry clearing supports dry-run, fails closed non-interactively,
  revalidates device and inode under the writer lock, and atomically installs
  an owner-only empty file.
- System dotfile archives and sidecars use owner-only permissions and restore
  validates ownership, links, digest, manifest, limits, and destination
  boundaries.
- Developer backups, profiles, and reports resolve and validate their directory
  on every use, refuse `..` segments, protected roots, symlink components, and
  paths outside the project or the user's home. Directories must remain owned
  mode `700`; files must remain owned, singly linked regular files with no
  group or other permission bits, and writers create them mode `600`.
  Permission failures are fatal. Publication uses validated private
  temporaries with parent identity checks before and after publication.
  Backups, reports, and absent profile destinations use atomic no-clobber
  names; an authorized profile overwrite uses identity-checked atomic
  replacement. Backups have bounded retention, same-second names remain unique,
  and pruning always preserves the current invocation backup despite clock skew
  or manipulated mtimes, plus the newest configured count minus one of the
  prior backups.
- Developer profile inventory is capped at 100 files, 8,192 bytes per file,
  and 64 tasks. A profile is opened once and its full owner, inode, size,
  timestamps, mode, and link identity is checked before and after reading.
  Every line must be batch-eligible, so one invalid token refuses the complete
  profile before any task executes. Eligible tests and compilers may still run
  project code and create documented artifacts.
- Developer reports are rendered from a line array and written with
  `print -rl`, replacing a buffer that embedded `\n` escapes and required the
  non-portable `echo -e`. The buffer is reset on every save outcome.
- Developer automatic restore requires the exact invocation-owned backup,
  validates the backup directory, project directory, source, destination, and
  modes and immutable backup fingerprint, fingerprints destination metadata and
  content, compares the staged bytes with the backup immediately before
  publication, and publishes a same-directory replacement atomically. It
  refuses an in-place destination edit or replacement while staging, never
  guesses the newest backup, and never falls back to Git.
- Developer dependency export refuses destination or parent symlinks, freezes
  parent identity, validates safe write permissions, fingerprints destination
  metadata and content, and holds the same fingerprinted inode open while
  overwrite authorization is pending. `uv export --locked` writes a private
  same-directory temporary through its held descriptor without resolving or
  updating the lockfile. Path and descriptor fingerprints are revalidated
  before publication, detecting replacement and in-place edits. An absent
  destination uses atomic no-clobber hard-link publication; an authorized
  existing destination uses identity-checked atomic replacement. There is no
  environment-freeze fallback.
- The Developer PyPI cache validates bounded numeric configuration and a
  writable, non-symlinked temporary root. It accepts a safe current-EUID root or
  a root-owned sticky shared root and refuses other foreign owners or unsafe
  non-sticky shared modes.
  It freezes temporary-root, private cache-directory, and private cache-file
  identities, publishes entries atomically without clobber, and quarantines the
  exact cache inode before recursive cleanup. Cache-hit read failures propagate.
  `pyproject.toml` is limited to 2 MiB, the combined dependency inventory to
  1,000 entries, each response to 20 MiB, and cache cleanup runs on every
  public-command exit path.
- Developer `pyproject.toml` specifier rewrites are prepared in a private,
  identity-checked workspace and publish through a same-directory atomic
  replacement only after a reviewed fingerprint and exact backup. Literal
  source spans are bound to parsed dependency elements, candidate semantics
  are checked before writing, and version text remains data. Matching spans
  are capped at 64 per package before repeated TOML parsing.
- File, Py, Hugging Face, and GPU picker captures and private staging roots
  accept only a protected current-EUID directory or a sticky shared root owned
  by the namespace-visible owner of `/` (normally UID 0). Their ancestor chains
  must be owned by that system-root identity or the current EUID and protected
  against unguarded replacement. Capture files are owner-only, bounded, opened
  without following links, identity-checked, and cleaned only while the exact
  expected object remains.
- App and CI use the same protected temporary-root and foreground-capture
  boundary for their pickers. A temporary result must be an owned object with
  the exact expected direct-child name before it can be opened or removed, and
  a non-zero picker result cannot carry selection data.
  App task descriptors are direct-child, owned, singly linked regular files
  with no group/other write permission; their complete metadata identity and
  SHA-256 digest are checked during discovery, before authorization, and
  immediately before backend execution.
- Network probe and picker captures also require the exact expected owned
  direct-child name before opening or cleanup. A forged `mktemp` result cannot
  redirect a permission change, write, or removal to another caller path.
- Amp and Cursor version probes redirect `XDG_CACHE_HOME` to an
  invocation-owned mode-`0700` directory below the validated private probe
  root. The exact cache root is identity-checked before cleanup, so passive
  version discovery does not populate either assistant's persistent cache.
- Environment profile state remains below `HOME` in a validated mode-`700`
  owner directory. Profile files are singly linked mode-`600` owner files with
  a bounded passive schema. Save and overwrite publish atomically; read-only
  listing never creates state; load and delete revalidate the complete file
  identity after review. Dotenv creation uses the same private
  same-directory publication boundary.
  Overwrite and deletion accept only the ctime change caused by their own
  reviewed rename, preserve all other metadata and content checks, and freeze
  the complete resulting fingerprint for cleanup or restoration. Failed
  publication restores an unchanged original; unexpected quarantine changes
  retain recovery data. Dotenv serialization preserves literal leading quotes
  under the passive parser without introducing shell evaluation.
- File output publication uses private same-directory staging, content and
  metadata snapshots, no-clobber publication for absent targets, and exact
  identity replacement for authorized overwrites. Archive extraction uses one
  private source snapshot for both preflight and extraction.
- Py project state, environment markers, lockfiles, exact interpreters, and
  removal quarantines are ownership-, mode-, boundary-, and identity-checked.
  Activation sources the reviewed open descriptor. A stable path through the
  actual Zsh PID permits relocatable uv scripts to resolve their location;
  unsupported relocatable descriptor resolution fails before sourcing.
  Postconditions verify the selected environment and interpreter. Failure
  restores standard activation state, while explicitly authorized customized
  scripts can still have effects outside that restoration boundary.
  Hugging Face cache deletion derives no ZDX-owned persistent pointer: it
  re-discovers one exact installed-library cache record for every plan.

- Workspace creation applies mode `700` to its `.ssh` directory, `600` to the
  private key and configuration files it creates, and `644` to the public key.
  A bounded passive SSH alias preflight rejects conflicting or ambiguous
  routing before creating files. It checks first-value Host routing and the
  exact identity path, refuses `Include`/`Match` rather than evaluating them,
  and revalidates configuration identity before creation and publication.
  This preflight reads only `~/.ssh/config`; system SSH configuration and
  effective routing remain outside its verification boundary.
  Imported key candidates must be owned, non-symlink regular files directly
  below the user's `.ssh` directory. Existing global SSH and Git configuration
  files are fingerprinted and each changed file is published through a private
  same-directory atomic replacement after workspace revalidation. Workspace
  removal refuses a symlinked,
  multiply linked, foreign-owned, or oversized global SSH or Git configuration
  file, fingerprints its content and metadata through a no-follow descriptor,
  and publishes each rewrite through a private same-directory temporary and
  atomic rename. Git-config parser failure is fatal. Public-key display and
  clipboard publication revalidate the owned, singly linked, bounded public key
  instead of following a replacement link.
- Workspace key rotation builds the replacement in a private directory before
  backing up the active pair, restores that pair after a failed installation
  when safe, and prunes only validated complete backup pairs.
- The VPN cache and report directories resolve and validate on every use, refuse
  `..` segments, the filesystem root, the home directory itself, symlinked
  directories checked on the unresolved path, and any path outside the user's
  home. They are created mode `700` with mode `600` files. Cache entry names are
  an internal allowlist rather than user input, and a pointer to a profile that
  no longer exists is displayed for clearing but never acted on.
- VPN cache entries use private same-directory temporary files and no-clobber or
  atomic replacement; a publication failure preserves the prior pointer.
  Reports are staged privately and published under unique no-clobber names, so
  simultaneous same-second runs do not overwrite one another. A failed report
  clears its invocation-local target and removes the staged file. Cache entries
  are capped at 128 bytes, preview panes at 64 KiB, and completed reports at
  1 MiB; external diagnostic sections are bounded before publication.
- `VPN_CONFIG_DIR` must be absolute, must not contain traversal, controls,
  protected roots, or symlink components, and an existing directory must be
  owned by root or the current user without group/world write access. Profile
  and backup inventories accept only private, singly linked regular files owned
  by root or the current user and bounded to 1 MiB; unsafe entries are neither
  displayed nor acted on.
- VPN staging accepts only a writable non-symlinked temporary root controlled
  by the current EUID, or a root-owned sticky shared root. It prefers standard
  per-user runtime/cache locations when a host's `/tmp` has a foreign owner;
  an explicitly unsafe `TMPDIR` fails closed.
- VPN preview panes live in an owner-only `mktemp` directory removed through an
  `always` block and local signal handlers, and never contain `PrivateKey` or
  `PresharedKey`. The fzf selection is captured privately and must match the
  current menu snapshot before dispatch. Reports contain the public exit IP,
  geolocation, endpoints, the hostname, and resolver addresses, but never
  profile file contents. After each successful publication, a validated
  `VPN_MENU_REPORT_RETENTION` bound (default keep-newest 20; `0` disables)
  prunes older reports while always protecting the report just published and
  never deleting an entry that fails owner-only validation; invalid retention
  configuration fails the command closed before any report work.

**Residual requirements.** Persisted state outside the audited telemetry,
System, Developer, VPN, File, Py, Hugging Face, GPU, and hardened Workspace
paths still needs equivalent ownership, symlink, size, retention, and atomicity
review. Workspace backup and repository inventories remain unbounded, and
`ws-create` does not yet combine workspace files, SSH configuration, and the
global Git include into one fingerprinted rollback transaction. Developer
publication assumes a filesystem with meaningful POSIX ownership and modes,
hard links, and atomic
same-directory rename; an incompatible filesystem fails closed. Atomic
replacement does not promise to preserve arbitrary ACLs or extended attributes.
A hostile process with the same EUID still shares the authority to race final
path operations, even though open descriptors, identity checks, no-clobber
publication, expected-object updates, and atomic rename make that window narrow.
A `.venv` directory identity does not freeze every descendant file against a
hostile same-user process. In user namespaces, an overflow UID can represent
multiple unmapped host owners as the same namespace-visible owner of `/`; the
File, Py, Hugging Face, and GPU trust decision therefore also relies on the
namespace and mount configuration not exposing hostile bind mounts under that
identity. Focused tests do not replace live-network, real-host, or
repository-wide verification.

### T8. Malicious contribution merged into the repository

**Risk.** A contribution introduces exfiltration, injection, unsafe deletion,
or a backdoor.

**Current repository controls.**

- `CODEOWNERS` requests maintainer review.
- CI runs pre-commit and BATS on pull requests.
- The Ubuntu quality gate installs fzf so native input-row visibility and
  inherited-option isolation checks run instead of skipping for a missing tool.
- The installed pre-push hook and the CI Quality Gates workflow execute the
  same `just check` aggregate. It first runs `uv lock --check`, then executes
  syntax, file-stage pre-commit, dependency-audit, and BATS gates through locked
  uv operations. A stale lock fails without being rewritten after the commit.
  Every file hook is explicitly restricted to `pre-commit`; pre-push executes
  only the single complete aggregate regardless of upstream manifest defaults.
- The shared test sandbox clears inherited package-manager control variables;
  System regressions inject hostile values explicitly and mock the fixed
  unattended-upgrade program validator instead of depending on host packages.
- DCO sign-off is checked by a dedicated workflow.
- Gitleaks, Zizmor, Actionlint, Markdownlint, syntax checks, and repository
  hygiene hooks are pinned in repository configuration.
- Fork pull-request workflows use read-oriented permissions in tracked workflow
  files.

Branch-protection, required-review, MFA, and repository-ruleset settings live
outside Git and must be verified periodically in GitHub; this document must not
treat an unverified remote setting as permanently guaranteed.

**Residual requirement.** Focused System interface, resource, maintenance, and
state suites now cover stdout/stderr, surface behavior, typed records,
post-confirmation revalidation, update and cleanup plans, archive and font
attacks, telemetry publication, and standalone sourcing. Those deterministic
mocks do not establish real macOS behavior, remote governance, or the result of
the combined repository gate. Large refactors should remain staged so review
can reason about behavior changes.

### T9. Workflow token or GitHub Actions compromise

**Risk.** A workflow or third-party action exfiltrates a token, changes
protected content, or publishes an unauthorized release.

**Current controls.**

- Tracked workflows declare minimal workflow-level permissions and elevate
  release permissions only where needed.
- Scheduled dependency and link maintenance workflows are read-only: they
  publish bounded job summaries and cannot create pull requests or issues.
- Checkout steps use `persist-credentials: false`.
- Third-party actions are pinned by commit SHA with version comments.
- Zizmor and Actionlint run in local/CI checks.
- Workflow concurrency and timeouts limit duplicate or stuck execution where
  configured.

**Residual requirement.** Action semantics and remote repository settings still
require human review. A SHA pin protects against tag movement, not against a
compromised pinned release. SHA-pinned GitHub Actions are outside the Python
dependency report and require periodic manual version and advisory review;
Dependabot alerts do not provide complete coverage for SHA references.

### T10. Compromised contributor dependency

**Risk.** A Python dependency, pre-commit hook, or system CLI contains a known
vulnerability or malicious update.

**Current controls.**

- Python dependencies are locked with `uv.lock`; local and CI gates require a
  fresh lock and install or execute contributor tools with `--locked`.
- `pip-audit` is part of `just check`, so it runs whenever the local aggregate
  is invoked, through the installed pre-push hook, and in CI, including the
  scheduled workflow.
- The audit runs `pip-audit --disable-pip` over the hashed, fully pinned
  `uv export --locked` output. It never builds a throwaway virtualenv or
  downloads unpinned `pip`, `setuptools`, or `wheel` inside the gate, so the
  vulnerability service is its only network dependency.
- Developer installed-package license and vulnerability inventories require an
  importable module under `.venv/bin/python -I`; no global, overlay, or
  ephemeral backend can contaminate the observed environment.
- `dev-check-outdated` passes `.venv/bin/python` explicitly to `uv pip list`
  with `UV_SYSTEM_PYTHON=0`.
- Developer license strictness bounds both backend output streams, parses JSON,
  and classifies only the
  string `License` field after validating a record schema with string `Name`,
  `Version`, and `License` values. A malformed schema or either output above
  10 MiB is refused before unbounded materialization.
- The scheduled dependency-report workflow runs `uv lock --upgrade --dry-run`
  and publishes a bounded job summary without modifying the repository.
- Remote pre-commit hooks are pinned to immutable Git object IDs (full SHAs)
  and GitHub Actions to immutable commit SHAs, with version comments in tracked
  configuration. The Developer updater validates frozen hook candidates before
  publication and retains a newer existing pin when upstream default-branch
  tag topology proposes a downgrade.
- OpenSSF Scorecard reports supply-chain posture.

**Residual requirement.** Dependency upgrades are reviewed and applied
manually. The GitHub dependency graph and Dependabot alerts should remain
enabled for informational findings, while Dependabot security updates should
remain disabled to prevent automatic remediation pull requests. These remote
settings require periodic verification. OpenSSF Scorecard's
`Dependency-Update-Tool` check does not credit this intentional report-only and
manual policy. PEP 517 `build-system.requires` entries and their transitive
dependencies also require explicit review or build constraints because an
ordinary package build does not bind them to `uv.lock`. Runtime system CLIs are
supplied by the user's host and are outside the lockfile. ZDX must not imply
that presence alone establishes integrity or compatibility. Advisory and
license databases can also be incomplete or stale even when the local
environment boundary is exact. A full Git object ID prevents tag movement
after review, but does not make the pinned release trustworthy; hook pins and
the version comments used for monotonicity still require manual release and
advisory review.

### T11. Tampered release artifact

**Risk.** A source archive is substituted or published from an unauthorized
workflow.

**Current controls.**

- The release workflow creates the archive from Git, publishes a SHA-256 file,
  and requests Sigstore-backed build provenance.
- The checksum manifest records the downloadable asset basename rather than a
  runner-local staging path and is verified before publication, so consumers
  can validate both downloaded assets in one directory.
- Release publication uses scoped write and identity-token permissions.
- Consumers can compare the checksum and verify the GitHub attestation.

**Residual requirement.** Release procedure changes must preserve artifact,
checksum, and attestation linkage and be smoke-tested without weakening token
permissions.

### T12. Opaque binary committed to the repository

**Risk.** A binary cannot be meaningfully reviewed or reproduced.

**Current controls.**

- The README GIF and PNG are generated from `.demo/demo.tape` through the
  reviewable `.demo/record.zsh` and `.demo/session.zsh` scripts. The documented
  `just demo` task uses installed rendering tools and a synthetic project;
  it does not initialize a Git repository, stage Git changes, or create commits.
- The recorded shell uses `zsh -f`, private startup/state directories, and the
  closed environment described in T1. It sources the reviewed checkout, not
  the operator's installed copy or personal Zsh configuration. The tape
  navigates real menu rows and previews, and cancels Dev,
  System, AI, Git, and File. Dispatch guards reject backend actions and restrict
  master-menu routing to those suites without command arguments. A completion
  marker requires all five successful menu returns and no denied action before
  publication.
- Rendering writes to a fresh mode-`700` temporary workspace. The GIF passes
  one fixed FFmpeg conversion in the same closed environment, with stdin
  disabled and overwrite refused, into a new private output. Both final staged
  media files must be owned, regular, singly linked, and nonempty. The demo GIF
  has a specific 2 MiB limit; the PNG retains the 1 MiB limit. `ffprobe` must
  identify the expected GIF or PNG codec. A failed
  renderer, conversion, or pre-publication validation preserves existing media.
  Destinations are checked before staging and before each replacement;
  directories, symlinks, unowned files, and hard links are refused.
- Cleanup compares the temporary root's device, inode, owner, mode, and marker.
  A replaced root is retained and reported instead of adopted for deletion.
  `test/demo_recording.bats` covers hostile environment isolation through the
  real session initializer, the tour's route and backend guards, refusal of
  incomplete or denied tours and ambiguous Git ceiling paths, preservation
  after renderer or conversion failure or oversized output, and a real
  rename/replacement of the invocation's temporary root.
- The large-file hook retains the 1 MiB limit for other files and gives only
  `.demo/demo.gif` a 2 MiB exception.

**Residual limits.** The clean environment is not an operating-system or
network sandbox: the reviewed checkout, installed tools, system startup code,
and rendering dependencies retain the caller's privileges. Mocked renderer
tests do not establish browser safety or visual correctness. Review generated
frames as well as source; rendering versions and fonts can change the binary
without changing the tape. GIF and PNG publication uses separate renames, so
an interruption or failure during final publication can leave a mixed pair
that needs regeneration. The synthetic workflow does not demonstrate real
backend operations or native macOS terminal behavior. See
[`demo.md`](demo.md) for regeneration and review steps.

Any new generated binary requires a reproducible source, documented generation
command, license review, and a reason it cannot remain outside Git.

### T13. Stale maintenance and security controls

**Risk.** Dependencies, links, platform assumptions, or remote governance
settings become stale while the repository remains unchanged.

**Current controls.**

- Scheduled CI audits Python dependencies.
- A read-only scheduled workflow reports available direct and transitive
  lockfile updates for manual review.
- The scheduled link checker publishes failures to its job summary without
  opening issues.
- The MIT license permits continuity through forks.

**Residual requirement.** Read-only reports do not apply updates. Maintainers
must inspect scheduled summaries and alerts and manually review Python
dependencies, pre-commit hooks, and GitHub Actions. The security assessment,
remote branch settings, supported-platform claims, and installer integrity
metadata also require periodic human review.
GitHub may disable scheduled workflows after prolonged inactivity in a public
repository, so maintainers must also verify that each maintenance schedule
remains enabled.
The core loader still registers `zdir` / `wsj` and `zclean`, but their
implementations are explicitly ignored user-local files and do not ship in the
release artifact. They remain outside repository review and assurance until a
contract-compliant implementation is versioned; release documentation must not
present those local files as included functionality.

### T14. Unbounded local diagnostic execution

**Risk.** A slow, wedged, or unexpectedly interactive local CLI blocks the
user's long-lived shell, while an oversized persisted log consumes excessive
memory or CPU during inspection.

**Current controls.**

- System diagnostic version, package, and startup probes use bounded execution.
- GNU `timeout` and `gtimeout` use a TERM deadline and KILL grace period, with
  process-group termination for descendants under GNU semantics. BusyBox-style
  timeout is supported, with a Zsh-native direct-child watchdog when no timeout
  binary exists.
- System process, port, and service collectors use bounded local probes.
- Nerd Font downloads and non-mutating archive inspection use explicit
  deadlines appropriate to their boundary.
- Telemetry inspection refuses files above its configured byte limit before
  loading records into shell arrays.
- Developer scan depth, cleanup depth, cleanup unique-target count, backup
  retention, PyPI timeout, retry count, and worker count are bounded decimal
  configuration values. Cleanup discovery streams stop at `limit + 1`, category
  inventories are capped after streams combine, and the unique final plan is
  independently capped before user interaction or mutation. Validation rejects
  empty, signed, expression-like, or out-of-range text before arithmetic
  evaluation; the ephemeral-runner switch accepts only `0` or `1`.
- Developer project parsing refuses `pyproject.toml` above 2 MiB or more than
  1,000 combined direct dependencies. Bandit and ShellCheck share a
  NUL-delimited collector that prunes generated and nested-repository trees,
  propagates discovery failure, caps inventories at 512 files, and batches
  backends in groups of at most 64 paths.
- VPN profile and active-interface inventories, profile bytes, preview panes,
  cache entries, and report output have fixed suite limits.
  Exit-IP providers must be bounded HTTPS URLs; curl restricts protocol,
  response bytes, redirect protocol, connect time, and total time, and returned
  public addresses are validated semantically before display or persistence.
- The VPN interactive picker runs synchronously in the terminal's foreground
  process group. A pseudo-terminal regression compares its process group with
  the terminal foreground group, preventing `fzf` terminal setup from stopping
  as a background job. Local signal handlers and an `always` block remove its
  private preview and result files.
- Every Workspace picker runs synchronously in the terminal's foreground
  process group, never in command substitution or a background job. Its output
  is bounded and captured through a no-follow descriptor in an invocation-owned
  mode-`600` file below a mode-`700` directory, then removed by exact-identity
  cleanup. A pseudo-terminal regression exercises both the top-level menu and a
  nested picker for the original `suspended (tty output)` failure. Workspace SSH
  probes use batch mode, one connection attempt, no keyboard-interactive or
  password authentication, strict host-key checking, and a private 4 KiB output
  bound. `ws-test`
  validates a one-to-60-second connection deadline and adds five seconds for
  the whole probe; `ws-auth` uses three and five seconds respectively. GNU
  `timeout` or `gtimeout` is preferred, while a Zsh watchdog owns, terminates,
  and reaps the exact child tree when neither exists.
- APT has no package-lock polling or sleep. It is the first aggregate entry
  immediately after authorization and pre-authentication. Within that entry,
  planning does not call the generic package-manager busy detector; only an
  exact eligible unattended fingerprint can be discovered, and the native
  zero-timeout APT call is the sole lock arbiter. The shared trusted-program
  resolver first validates absolute, root-owned,
  non-group/world-writable `env` and `dpkg` paths. A bounded fixed-`env -i`
  `dpkg --audit` and the dpkg journal must both be clean before any signal. A
  dirty state fails immediately without signaling the current owner. Only then,
  adjacent to the single mutation sequence, may the aggregate send one
  cooperative `SIGTERM` through fixed `/usr/bin/kill` to the fully
  fingerprinted automatic updater. Its two `MinimalSteps` configuration reads
  are bounded and revalidated through trusted absolute `env`/`apt-config`
  programs under fixed `env -i`, so inherited `APT_CONFIG` or `PATH` cannot
  authorize the signal. A bounded, closed-stdin package-record probe and Debian
  version comparisons likewise use trusted absolute `env`, `dpkg-query`, and
  `dpkg` under fixed `env -i`/`PATH`. A numeric Debian epoch is removed before
  comparison. Versions below normalized 0.94 and any missing or ambiguous state
  cannot authorize TERM. The 0.94 line follows OR/default-false semantics and
  needs at least one `MinimalSteps` spelling explicitly true; 0.95+ follows
  AND/default-true semantics and requires both effective values true, with
  absent keys defaulting to true. These historical gates correspond to
  upstream commits `5f013f8` and `16fb837` and are rechecked before signaling.
  The process fingerprint and every revalidation also require SIGTERM's bit in
  the kernel `SigCgt` mask and reject the command-line
  `--no-minimal-upgrade-steps` opt-out, including accepted abbreviations. A
  validated suite opt-out disables that request without enabling a wait. Every
  `apt-get` invocation within `update-apt` sets
  `DPkg::Lock::Timeout=0`, `Acquire::Retries=0`, `Dpkg::Use-Pty=0`,
  `Dpkg::Options::=--force-confdef`, and
  `Dpkg::Options::=--force-confold`. Simulation and mutation run through the
  shared trusted-program resolver's absolute `env -i`, fixed only to
  nonexistent HOME/XDG roots, `LC_ALL=C`, the system `PATH`, `TERM=dumb`,
  `DEBIAN_FRONTEND=noninteractive`, and `APT_LISTCHANGES_FRONTEND=none`, and
  receive `/dev/null` as stdin. No inherited `APT_CONFIG`, proxy, or other
  caller/post-sudo state reaches APT; proxy policy must be in root-owned APT
  configuration. A generic process-owner observation cannot gate the attempt;
  an actual native lock refusal fails immediately,
  and no post-signal process-name scan gates execution. Normal APT phased
  rollout remains the default. Explicit `--include-phased-updates` consent adds
  `APT::Get::Always-Include-Phased-Updates=true` to the simulation, index
  update, full upgrade, and autoremove, and the aggregate forwards that flag
  only to APT. After the mutation sequence, including after a failed phase, the
  trusted dpkg journal/audit validation runs again; failure is non-zero and
  suppresses completion and reboot-marker inspection. A clean post-audit gates
  the advisory marker check, which may still report after a mutation failure
  and never initiates a reboot. The default aggregate proceeds with
  subsequent authorized entries; `--fail-fast` stops at the APT failure. DNF4
  preview and mutation commands both set
  `--setopt=exit_on_lock=True` and `--setopt=retries=1`, refusing a held lock
  with the minimum finite network setting: one retry and up to two attempts.
  Zero is not used because DNF4 defines it as unlimited. DNF5 candidate preview
  is omitted. Bounded version and main-config probes run through a validated
  trusted `env -i`, discard inherited plugin/loader/Python and user-config
  inputs. DNF5 5.0/5.1 deliberately skip the main-config probe, including when
  a 5.1 build provides it, and freeze no persist directory. DNF5 5.2/5.3
  require one unambiguous `installroot=/` and
  normalized absolute `persistdir`, with no lock capability. DNF5 5.4+ also
  requires exactly one valid boolean `skip_system_repo_lock` capability. Both
  mutation paths first run trusted `env -i` with the fixed environment and then
  the fixed Zsh wrapper; no inherited environment reaches Zsh beyond the
  root-owned `/etc/zshenv` trust boundary. Wrapper argv has only mode, lock
  path, optional persist directory, and absolute DNF/`env` programs. The
  wrapper revalidates both programs and a second trusted `env -i` starts DNF;
  caller, post-sudo, proxy, and exported-function state is absent from both
  wrapper and DNF. UI output contains no environment values. DNF5
  5.0/5.1 use wrapper
  mode `0` to run `dnf --installroot=/ --assumeyes --refresh upgrade`, without
  a persistdir option or system-repository wait lock. DNF5 5.2/5.3 use mode `0`
  to run
  `dnf --installroot=/ --setopt=persistdir=<frozen-absolute-path> --assumeyes --refresh upgrade`;
  their transaction lock remains non-blocking. Wrapper mode `1` for DNF5 5.4+
  revalidates the absolute DNF5 program and
  attempts the same whole-file `fcntl` write lock through
  `zsystem flock -t 0`. A busy lock fails immediately before DNF5 starts. The guard
  holds the lock while the trusted fixed `env -i` runs
  `dnf --installroot=/ --setopt=persistdir=<frozen-absolute-path> --setopt=skip_system_repo_lock=True --assumeyes --refresh upgrade`; that option bypasses only the
  system-repository lock already held by the guard, and the separate
  transaction lock remains enabled. Active mutation is not timed out or
  killed.
- APK mutation uses `--wait 0` for both its repository update and package
  upgrade, so the suite requests no APK database-lock wait. Pacman exposes no
  supported zero switch for mirror traversal or package-download retries; its
  mutation retains those upstream behaviors and has no watchdog.
- Zypper receives `--non-interactive`, so its preview and mutation cannot ask
  questions. Upstream nevertheless hardcodes up to three soft-media retries
  with 30-second sleeps and exposes no supported override. System warns about
  that residual at runtime; an already-started `refresh` or `update` mutation
  is not placed inside a watchdog.
- The aggregate sudo timestamp refresher waits for either a private stop request
  or a fixed 30-second interval between non-interactive `sudo -n -v` checks
  while the consecutive privileged entry prefix remains active. The invocation
  owns its private `zpty` handle, and its `always` block requires the worker's
  bounded acknowledgement and exit before deleting that handle on every
  aggregate exit path. It never enters the caller's job table and cannot emit
  asynchronous job-completion UI.
- During planning, `update-system` validates the only lock path,
  `${HOME:A}/.zdx-update-system.lock`. It never selects shared `/tmp`, runtime,
  or cache alternatives and never unlinks the file, so directory availability
  cannot split concurrent invocations across lock domains. After authorization,
  it holds the persistent mode-`0600` file through an owner-bound descriptor.
  Its `zsystem flock -t 0` request rejects overlapping mutating execution
  before any entry runs, with no
  polling or retry; closing the descriptor releases the lock and leaves the
  file reusable.
- The aggregate accounts for the frozen authorized plan in separate core
  package (APT, native, Snap, and Homebrew) and optional-tool summaries.
  Failures and entries not run after `--fail-fast` are explicit, rather than
  being hidden by an aggregate success count.
- System Git-owned update transport disables terminal and askpass credential
  prompts, applies batch-mode SSH with connect and keepalive deadlines unless
  the caller supplies `GIT_SSH_COMMAND`, and instructs Git to abort a transfer
  below 1 KiB/s for 60 seconds, so a credential request or remote stall fails
  that step visibly instead of blocking the aggregate. The Homebrew metadata
  refresh has a 120-second deadline, and every `update-brew` phase sets
  `HOMEBREW_CURL_RETRIES=0`. That setting controls only curl-level retries.
  Homebrew 6 retains internal `DownloadQueue` retry behavior and download-lock
  waiting with no public disable option; mutating Homebrew phases therefore
  retain those external transaction semantics while running to their reported
  result; ZDX does not kill an active Homebrew mutation. All phases invoke the
  once-resolved absolute `brew` executable under local exported policy; no
  `env ... brew` fallback is exposed to caller-function interception. On macOS
  the adjacent Homebrew entry stays within the bounded sudo refresher scope for
  casks, and every phase receives the validated
  `SUDO_ASKPASS=/usr/bin/false` guard for Homebrew's internal `sudo -A`.
  Linuxbrew does not receive that Darwin-only guard. The upgrade phase requires
  `--no-ask` so non-TTY ask mode cannot omit the authorized mutation and report
  success.
  `HOMEBREW_NO_AUTO_UPDATE=1` prevents mutating phases from starting a second
  metadata refresh but does not remove the internal queue behavior. A Snap
  preview error or deadline is a visible failure. Aggregate steps report
  per-step elapsed time and receive `/dev/null` as stdin. Direct APT, Homebrew,
  native-package, and both outer-wrapper and inner-child DNF calls also receive
  closed stdin. Commands with privately captured output announce that they are
  running and receive closed stdin; probe capture plus watchdog marker files
  are created under `umask 077`.
- Suite-owned clients with a public zero-means-disabled retry control receive
  `npm_config_fetch_retries=0`, `UV_HTTP_RETRIES=0`, `PIP_RETRIES=0`,
  `CARGO_NET_RETRY=0`, or `RUSTUP_MAX_RETRIES=0` as applicable. pipx/pip also
  receives `PIP_NO_INPUT=1`. These controls remove the supported client-level
  retries and pip input prompt; they do not terminate an active mutation or
  claim equivalent semantics for DNF, Pacman, Zypper, or Homebrew internals.
  Cargo can still wait for its package-cache lock because it exposes no
  supported zero-wait control for that separate resource.
- File inventories enforce byte and entry ceilings before selection or broad
  mutation. Transfer trees are bounded and re-inventoried, and GNU TAR
  extraction caps members at 4,096 and declared expansion at 1 GiB before
  publication. Mutating archive and filesystem backends are not killed after
  they begin; failures are propagated and recovery state is reported.
  File multi-target operations stop later mutations when copy, move, removal,
  permission, or conversion backends return an interruption status. Partial
  staged copies and conversions are cleaned without publication; incomplete
  deletion retains its exact quarantine. Temporary staging results must match
  the expected parent, name template, private ownership, type, and regular-file
  link count before use; unexpected paths are neither chmodded nor removed.
- Py environment, managed-runtime, and tool inventories require
  `timeout`/`gtimeout` and have explicit byte and record ceilings;
  `.virtualenvs` accepts at most 128 direct children, PyPI responses use a
  private bounded file with network deadlines, and recursive removal parses a
  bounded JSON `findmnt` result. Environment package plans freeze project
  metadata presence/content and project-root identity, while uv project
  mutations reject external workspaces and bind both project and working
  directory to the reviewed root. Pin writes freeze the root identity, disable
  workspace discovery, and remove uv target-redirection variables. External
  package mutations are intentionally allowed to run to their reported
  transaction result.
- Hugging Face backend/version, search, metadata, file-list, cache inventory,
  plan, and mount probes require `timeout` or `gtimeout` and use a 15-second
  deadline plus record and byte ceilings. Search records are validated as one
  bounded batch before stdout publication; repository-file discovery consumes
  the paginated tree iterator incrementally and stops at 2,001 files or 4,097
  total records. Authorized large downloads and cache deletion are not killed
  mid-transaction. One download executor serves direct and search actions;
  fixed activity messages use a separate progress descriptor while vendor
  stdout and stderr remain hidden. Its Python activity thread stops with the
  operation. Results must identify a readable existing file or directory;
  classified errors and safely quoted retry guidance disclose no raw vendor
  exception text. Existing cache data is retained for explicit retries.
  GPU hardware and process probes use three-second deadlines,
  cap process output at 256 rows and 256 KiB, and force one-frame rendering
  unless stdin/stderr identify the same usable foreground terminal. Foreground
  ownership is rechecked around rendering and input. The visualizer locally
  disables Zsh `MONITOR` before ignoring TTIN/TTOU, then restores the caller's
  job-control and trap state at function return; this prevents a transition
  race from suspending the interactive shell without changing its lasting
  configuration. A failed process query leaves valid metrics visible with an
  unavailable label and a non-zero frame status. Continuous mode can recover
  on the next frame; interruption stops the monitor.
- App limits every descriptor to 2 MiB, each task token to 128 bytes, and the
  combined typed inventory to 512 records and 1 MiB. The isolated
  `package.json` parser rejects malformed schemas and excessive or unsafe
  names before printing them. Just, Make, and Compose collectors enforce their
  task ceiling while reading, so an oversized descriptor cannot first
  materialize an unbounded shell array. App picker output is separately
  bounded to 1 MiB.
  Direct App lookup and revalidation inspect only the requested backend
  family, while complete inventories remain strict. Interrupted execution or
  revalidation stops later tasks; retry guidance identifies the exact reviewed
  invocation without re-executing it automatically.
- CI read-only GitHub probes have 20- or 30-second deadlines, a pre-capture
  `maximum + 1` byte guard with 2 MiB response caps, strict JSON schemas, and
  100-record inventory ceilings. Accepted remote writes are not wrapped in a
  watchdog; each fixed endpoint runs to its reported result so the caller
  cannot return while hiding a mutation.
  Exact historical run inspection additionally matches its numeric ID and
  repository identity before opening the detail view; cleanup eligibility
  remains bounded by the original inventories. Interrupted remote writes or
  revalidation stop subsequent targets and report uncertain acceptance instead
  of implying that the service rejected the current request.
- Environment accepts at most 512 dotenv records and 1 MiB per parsed input;
  discovery is limited to three levels, 512 candidates, and 4,096 visited
  nodes. Profile, variable, PATH, and picker records are bounded before shell
  arrays or UI rendering.
- Network bounds every local and remote subprocess by capability-specific
  deadlines and byte ceilings. Ping accepts at most 20 packets, DNS accepts at
  most 64 records per type, interface inventories stop at 256 entries,
  speed-test CLI output stops at 1 MiB, and the fixed curl fallback transfers
  exactly 10 MiB only after authorization.
- Package, cache, service, signal, font-cache, Git, and other mutating
  transactions are not wrapped in `_sys_run_with_timeout`; once started, they
  run to a reported result rather than allowing the caller to return while a
  descendant may still mutate state.

**Residual requirement.** Remaining maintenance workflows and other suites
must adopt deadlines where an external operation has a meaningful bound.
Timeout fallbacks cannot offer identical descendant control on every host.
Remaining probes need the narrowest supported cleanup semantics, and timeouts
must never hide partial mutations. Homebrew 6 can retry through its internal
`DownloadQueue` and wait on download locks; it exposes no public option to
disable those behaviors. `HOMEBREW_CURL_RETRIES=0` controls only curl-level
retries, and the 120-second outer deadline applies only to the metadata refresh,
not mutating Homebrew phases. DNF4's minimum finite `retries=1` still permits
one retry and up to two attempts. DNF5's `retries` setting is deprecated and
has no effect, and it exposes no effective supported replacement that disables
its upstream network retries. Those retries remain external. DNF5 5.0/5.1
deliberately omit the config probe and persistdir override; 5.2/5.3 freeze the
persistdir, and all four use sanitized mode `0` with a non-blocking transaction
lock. DNF5 5.4+ uses the non-blocking root guard before mutation. Pacman can
traverse mirrors and retry package downloads, and Cargo can wait for its
package-cache lock;
neither exposes a supported zero switch for that behavior. Zypper hardcodes up
to three soft-media retries with 30-second sleeps and offers no supported
override; `--non-interactive` removes
prompts, not that policy. These external behaviors are not covered by a
universal no-wait/no-retry guarantee, and an active package mutation is not
killed by a general watchdog.

The Hub library can materialize cache iterables and individual remote
pagination pages internally before ZDX applies its record limits, and
authorized downloads remain intentionally unbounded by ZDX. Workspace
inventories and GitHub organization results still need explicit count and byte
bounds.

## Docker and AI audit closure

The 2026-07-27 Docker pass addresses T2, T3, T7, and T14 with an exact
eight-command dispatcher, one source-derived fixed module inventory, private
foreground picker capture, typed full container and image identities, and
bounded daemon probes. Each workflow pins the client to a frozen context or
host selector and records the endpoint, daemon ID, server version, and
locality. Mutations against a remote endpoint require `--allow-remote`, and the
context plus exact resource is revalidated after authorization. Cleanup uses
explicit per-resource removals instead of `prune`; volumes have a separate
scope and are excluded from `all`. Compose fingerprints one constrained
descriptor and its resolved configuration, while registry login validates the
owner-only credential-directory and config-file boundary, pins it through
Docker's global `--config`, rejects malformed JSON and Docker parse warnings,
and passes password bytes only between stdin and Docker.

The subsequent recovery pass corrects exact membership checks for multi-target
cleanup, preserves interruption statuses through diagnostic capture and
removal, and stops subsequent targets after interruption. Read-only probes
include a two-second forced-kill grace after their deadline; resource mutations
remain outside that watchdog. An interrupted client may leave an accepted
daemon operation, which must be inspected before any explicit retry.

Docker-focused BATS tests freeze public-surface parity and exercise parser
ordering, output separation, cancellation, context replacement, exact cleanup,
Compose replacement, non-interactive refusal, and daemon-independent registry
login with a fully mocked client. They do not prove live daemon, remote
context, Docker Desktop, rootless, Podman, registry, or cross-platform Compose
behavior. Docker socket access remains administrator-equivalent, image and
Compose execution remain trusted-code boundaries, referenced Dockerfiles,
build contexts, and `env_file` content are not frozen by the descriptor digest,
and a same-EUID process can still race the final userspace check.

The 2026-07-28 AI pass addresses T1, T2, T3, T5, T7, and T14. Exact-root
loading and case dispatch replace computed execution. Cache cleanup and project
sweeps construct bounded, canonical, owned target plans, preserve conversations,
sessions, prompts, plans, tasks, todos, skills, and other durable state, then
revalidate before same-filesystem relocation to private recoverable quarantine.
Cursor installation/project state and Amp recovery data are excluded.
Configuration backup and restore use owner-only
manifest-backed snapshots, allowlisted relative paths, size and count limits,
content digests, no-clobber publication, and rollback copies. When no token is
given, restore selects from the same owner-only snapshot directories through
the private foreground picker; the picker reads directory names and manifest
line counts only, rejects a selection outside its rendered inventory, and
revalidates the token before the unchanged restore transaction. Recent-log output
uses deadline- and byte-bounded discovery, is selected from constrained files,
control-escaped, and redacts credential-indicator lines; a partial first line
from the bounded byte window is discarded. MCP inspection parses current
Claude user/local/shared-project, Antigravity user/workspace, and Cursor user
configuration passively: it does not execute configured commands, contact
remote URLs, or print arguments, headers, environment, or URLs.

The `ai-update*` entry points now delegate to fixed self-updater actions for
installed Claude, Codex, Antigravity, OpenCode, Cursor, Copilot, Amp, and
Hermes CLIs. They resolve only external executables, reject unsafe ownership
and writable modes, freeze launch and canonical-target identities plus content
checksum, require a bounded version probe and explicit authorization, and
revalidate immediately before execution. Dry runs invoke no updater; missing tools
are not installed; post-update identity and version are checked; partial
failures return nonzero. `ai-mcp-update` remains a passive compatibility audit.
No `curl | shell`, `npx @latest`, or equivalent floating installer is invoked
by ZDX.

Cursor and Amp version probes use an invocation-owned `XDG_CACHE_HOME` below
the private probe root because both runtimes can write cache data before
printing a version. The probe root is identity-checked and removed without
changing `HOME`, authentication state, or the executable fingerprint.
Amp alone receives a fixed 16 MiB per-file runtime ceiling; its stdout and
stderr remain independently limited to 64 KiB under the common deadline.
Self-updater output is retained only as a bounded private tail and is not
rendered, and the updater reads from `/dev/null`; fixed `unauthenticated` and
`failed_precondition` markers select actionable categories, while every other
nonzero status remains a generic updater failure. No classification branch
performs login or reinstallation.

The installed vendor updater still resolves a mutable latest artifact and owns
its transport and release-signature verification, so ZDX cannot independently
bind the remote digest. Focused tests mock assistant CLIs, MCP state, and
updaters; future layouts and real-host updater behavior remain manual trust and
acceptance boundaries. Quarantine has no automatic purge or retention policy,
restore is atomic per file rather than across a manifest, and portable checks
cannot eliminate the last same-EUID pathname or executable replacement race.

## Residual-risk priorities

The highest-priority implementation gaps before declaring the audited suites
conforming are:

1. remove remaining selected-command execution and contextual preview
   interpolation outside the hardened master router, core, Git, System,
   Developer, VPN, Docker, File, App, CI, Environment, Py, Network, Hugging
   Face, GPU, and AI loaders;
2. stage and validate core plugin updates with rollback and a renewed trust
   decision while preserving the explicit arbitrary-code warning;
3. inventory and pin or refuse remaining unverified remote installers outside
   the audited System and Developer paths;
4. add uniform dry-run and non-interactive authorization to Workspace
   migration, key, branch, and sync mutations; make workspace creation one
   rollback-capable configuration transaction and bound Workspace inventories;
5. extend exact plans, dry-run, protected-path checks, and resource
   revalidation to destructive and privileged suites outside the audited
   System, Developer, VPN, Workspace, File, App, CI, Environment, Py, Docker,
   AI, and Hugging Face paths;
6. remove remaining preview interpolation and extend stream-contract tests;
7. verify Developer live-network and external-tool paths and Darwin behavior on
   real hosts or CI runners.

These are not documentation-only mitigations. They require code and tests in the
future suite rewrites.

## Assurance summary

ZDX has meaningful repository and supply-chain controls: pinned automation,
secret scanning, locked contributor dependencies, BATS isolation, DCO checks,
minimal tracked workflow permissions, checksummed releases, and provenance
attestation.

The System refactor now demonstrates explicit dispatch, an idempotent
non-`eval` loader, foreground private picker capture, typed resource records,
authentication-aware
post-confirmation revalidation, refusal of unverified installers, real-tree
font and dotfile validation, advisory package snapshots with dynamically
resolved transactions, exact typed cleanup scope, atomic publication,
owner-only bounded telemetry, bounded and redacted failure capture, `NO_COLOR`
handling, and stream isolation.

The Git refactor applies those standards to local and remote repository state:
an exact 39-command surface, parser-before-probe routing, exact-root loading,
credential-redacted context, typed records, fixed previews, direct and nested
completion, immutable mutation plans, OID leases, isolated fetch refs,
post-confirmation revalidation, and deny-by-default GitHub verification.
After a successful `gh pr merge`, the suite also re-reads the reviewed PR and
head: a pending request is reported separately from a completed merge, and
unreadable or inconsistent final state fails without resubmitting the write.

The Developer refactor applies the same standards to an unprivileged,
project-scoped suite: a frozen surface, parser-before-probe dispatch,
effect-aware batch and profile execution, frozen aggregate maintenance scope,
immediate exact cleanup authorization, private fingerprinted update plans,
exact invocation rollback, stable cleanup-root and target identities,
generated and nested-repository exclusions, private atomic state/report/export
publication, bounded configuration, explicit TFLint initialization, hardened
ephemeral PyPI caches, and removal of both `curl | shell` installer paths. Its
update recovery additionally isolates independent backends, validates partial
hook candidates, bounds dependency-span matching, and creates relocatable
staged environments. Live PyPI and most external tools remain mocked;
relocation tests use real uv offline with a local wheel. macOS is unverified,
external tool transactions cannot be rolled back generically, and portable
userspace identity checks cannot fully exclude a hostile same-EUID race.
`uv python install --upgrade X.Y` also remains an external global effect outside
the recoverable staged `.venv` swap.

The VPN refactor closes the two remaining paths that handed
attacker-influenced content to root — an editor run as root, and a generated
root-executed hook carrying an unvalidated profile value — and removes the one
preview that compiled selected data into a shell program. It also adds a direct
CLI where none existed, an explicit Linux and WSL platform gate, and owner-only
validated state.

The File refactor freezes a ten-command surface, uses exact routing and private
foreground picker capture, confines mutations to trusted owned trees, separates
the permission-repair exception from stricter transfer policy, and adds
identity/content-bound publication, same-filesystem moves, quarantine deletion,
bounded tree inventories, and one-snapshot GNU TAR extraction with exact
realized-member checks. GNU utility portability and the final same-EUID
pathname race remain explicit limits.

The App, CI, Environment, and Network refactors extend those controls to four
different trust boundaries. App fingerprints bounded task descriptors and maps
validated task tokens only to fixed backend argument vectors before separately
authorizing project code. CI binds bounded typed GitHub records and fixed
endpoints to one validated repository, protects newest resources, revalidates
after authorization, and delegates Git-owned objects. Environment treats
dotenv and profile bytes only as passive literal data, withholds all values
from UI records, performs explicit session changes, and publishes private state
atomically without an automatic directory hook. Network separates local-only
inspection from bounded active probes, restricts remote contact to fixed HTTPS
providers, and requires explicit authorization before throughput traffic.
Live backends, GitHub, clipboard/filesystem variants, public providers, and
real-host command formats remain manual acceptance boundaries.

The Py refactor freezes sixteen canonical commands plus one compatibility
adapter, limits ownership to project-local environments, sources activation
through a fingerprinted no-follow descriptor, refuses ambiguous Poetry state
and ambient pip, binds package mutations to exact project metadata and
interpreters, freezes exact isolated-tool inventories, and removes environments
through mount-aware quarantine. External package managers remain
non-transactional and real index behavior is a manual acceptance boundary.

The Hugging Face and GPU refactors establish small typed public surfaces with
installed-only backends, exact loaders, foreground private selection, escaped
terminal data, canonical decimal parsing, and bounded probes. Hugging Face
deletion proves one model/dataset cache target against the configured cache
root and reports quarantine recovery; GPU never silently substitutes
simulation and prevents unattended continuous refresh outside a foreground
terminal, including same-TTY identity and foreground-loss checks. Live Hub
behavior, large transfers, and physical multi-GPU hosts remain manual
boundaries.

The Workspace hardening pass freezes 15 commands, replaces arbitrary execution
with exact routing and loading, keeps every picker in the terminal foreground
with private result capture, isolates feature UI on stderr, validates workspace
descendants, redacts remote credentials, propagates clone failures, preserves
and restores only the exact invocation-owned stash, bounds SSH probes, and
makes key rotation recoverable.
Synchronization revalidates branch and upstream object snapshots; migration
refuses cross-filesystem and link escapes; stale cleanup uses expected-object
compare-and-delete; and removal fingerprints configuration content, publishes
rewrites atomically, and deletes through a verified quarantine. Every public
Workspace command now parses `-h|--help` and rejects unknown options and
excess operands before probes. It remains a partial migration: uniform
broad-mutation controls, transactional workspace creation, bounded
inventories, and the private Git compatibility dependency are still open.

The Docker pass binds complete resource identities to one explicit daemon
snapshot, replaces prune with exact removal plans, separates high-value volume
cleanup, constrains Compose input, and keeps registry credentials outside ZDX
output. The AI pass separates disposable cache from durable assistant state,
uses reviewed filesystem and configuration transactions, makes log and MCP
inspection passive and bounded, quarantines rather than recursively deleting
eligible targets, and confines remote-code updates to reviewed, fingerprinted
installed-CLI self-updaters. Their mutable upstream latest selection, live
external backends, quarantine retention, and same-EUID final races remain
explicit manual boundaries.

Repository controls do not prove those runtime properties by themselves, and
equivalent gaps remain in the suites that have not yet been migrated. Because
ZDX runs in the user's shell and sometimes as root, these controls remain
required parts of the assurance case.

## Maintenance triggers

Review and update this document whenever:

- a suite adds a privileged, destructive, network, installer, browser, editor,
  process-control, or remote-write action;
- a new executable config, plugin path, backup, cache, or telemetry record is
  persisted;
- a workflow, dependency ecosystem, install path, language runtime, or release
  channel is added or changed;
- a control is removed, replaced, or found ineffective;
- a vulnerability, audit, incident, or community report identifies a new
  threat;
- remote GitHub security settings or supported-platform claims are reviewed.

For each change, record the threat, implemented control, tests, and remaining
risk. Do not describe a planned control as already present.

Last reviewed: 2026-09-05.
