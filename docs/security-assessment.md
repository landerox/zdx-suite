# Security assessment

This document is the consolidated threat model and assurance case for ZDX. It
supports OpenSSF Best Practices Baseline-2 criterion `osps_sa_03_01` and the
commitments in [`SECURITY.md`](../.github/SECURITY.md).

The engineering controls required for new code are normative in
[`development.md`](development.md). This assessment distinguishes implemented
controls from residual gaps.

## Scope

ZDX consists of:

- the core, sourced into a long-lived interactive shell: `functions.zsh`
  (configuration, lazy loading, output services, opt-in telemetry, the plugin
  loader, and overrides), `zdx-common`, the `zdx-menu` launcher, the
  `zdx-status` dashboard, the `zdx-doctor` dependency doctor, the
  `zdx-plugins` manager, and the `zdx-widgets` command-line insert widgets;
- eight suites with interactive menus, direct commands, and completions that
  invoke local and remote tools: Workspace, Git, Developer, File, Environment,
  Python, System, and VPN;
- privileged system-maintenance and VPN workflows;
- a local Zsh installer with a minimal Bash compatibility launcher;
- user configuration, overrides, plugins, backups, and opt-in telemetry;
- the README demo recorder;
- the GitHub CI and release pipeline, its repository governance settings, and
  the Python-based contributor tooling.

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
- CI tokens, the protected `main` branch, release tags, release artifacts,
  and project reputation.
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

Git, GitHub CLI, package managers, systemd, WireGuard, cloud CLIs, language
toolchains, pagers, editors, and network utilities have their own
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

### Repository governance

Rulesets, merge policy, the Actions policy, and GitHub security features are
enforced by GitHub but configured outside Git. Review cannot see them in a
diff, so they must be verified periodically in the repository settings.

## Attack surface

| Surface | Exposure | Location |
| --- | --- | --- |
| Core and suite Zsh | Executes in the current shell with user privileges | `functions.zsh`, `functions/**/*.zsh` |
| Interactive shell adapters | Converts selected rows, keys, previews, and user input into commands | `functions/**/*menu*.zsh`, `fzf` calls |
| Command-line insert widgets | Inserts a picked branch, pull request, PID, port, or path into the user's edit buffer | `zdx-suite.plugin.zsh`, `functions/zdx-widgets.zsh` |
| Privileged workflows | Packages, services, processes, networking, logs, and system files | primarily `functions/sys/`, `functions/vpn/` |
| VPN path MTU probe | Sends at most 16 bounded ICMP echo requests to one validated IPv4 target and reads routes and interface MTUs, unprivileged | `functions/vpn/vpn-mtu.zsh` |
| Destructive local/remote workflows | Deletes or rewrites files, Git history, stashes, branches, tags, caches, and plugins | multiple suites |
| Installer | Integrates reviewed local source and publishes initial user configuration; prints manual shell activation instructions | `scripts/install.sh`, `scripts/install.zsh`, `scripts/install_fs.py` |
| Tool updaters and installers | Runs vendor self-updaters, Git-owned installers, and package managers | System update workflows, `zdx-doctor` batch installer |
| APT signing-key renewal | Downloads a publisher's OpenPGP key over HTTPS and installs it as root into that repository's dedicated APT keyring | `functions/sys/sys-update-apt-keys.zsh` |
| Local configuration and overrides | Executes user-controlled Zsh at shell load | `~/.config/zdx/*.zsh` |
| Opt-in directory hook | With `ZDX_GIT_IDENTITY_GUARD=1`, runs a read-only Git identity check when `cd` first enters a workspace repository | `zdx-suite.plugin.zsh`, `functions/git/git-identity.zsh` |
| Project dotenv files | Reads attacker-controllable bytes, such as a cloned project's `.env.example`, as bounded data and reports key names; never loads them into the shell | `functions/env/env-dotenv.zsh` |
| Plugin loader and manager | Sources third-party code and updates Git origins | core loader and `zdx-plugins` |
| Local persistence | Telemetry, profiles, caches, backups, plugin trees, and trashed files | `~/.config/zdx`, `~/.cache/zdx`, `${XDG_DATA_HOME:-~/.local/share}/zdx/trash`, suite-specific paths |
| CI and release workflows | Executes repository and third-party automation with GitHub tokens | `.github/workflows/*.yml` |
| GitHub Actions updates | Reads release tags from github.com and rewrites the `uses:` references that a project's CI executes | `functions/dev/dev-update-actions.zsh` |
| Workspace clones and fetches | Clones a user-supplied URL into a new directory below `WS_BASE_DIR`, resolves workspace SSH aliases, and on request fetches every workspace repository's remote | `functions/ws/ws-clone.zsh`, `functions/ws/ws-status.zsh` |
| Contributor tooling | Executes pinned hooks and locked Python dependencies | `.pre-commit-config.yaml`, `.config/markdownlint.yaml`, `pyproject.toml`, `uv.lock` |
| Release distribution | Publishes archives, checksums, and attestations | `release.yml`, GitHub Releases |
| Demo recorder | Runs real menus in a synthetic workspace and publishes README media | `.demo/record.zsh`, `.demo/session.zsh`, `.demo/demo.tape` |
| Repository governance | Decides what can merge, run, and publish | GitHub rulesets and repository settings |

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

- `gitleaks` runs through pre-commit and the CI quality gate. GitHub secret
  scanning and push protection are enabled for the repository.
- GitHub private vulnerability reporting provides a non-public disclosure
  channel, with the address in `SECURITY.md` retained as a fallback.
- `.gitignore` excludes local assistant state, backups, logs, and scratch
  directories.
- Environment browsing publishes names plus only `********` or `<hidden>`.
  Raw values never enter rows, previews, diagnostics, plans, or fallback
  output. An explicit copy sends one frozen value directly to a supported
  clipboard backend and never prints it on failure. WSL `clip.exe` receives a
  fully validated UTF-16LE conversion, so invalid UTF-8 reaches no clipboard.
  Its fallback is the fixed Windows system path, used only when WSL is
  detected.
- `env-dotenv` reports a dotenv file and its example by key name and line
  number only. A value's single exposed fact is whether it is set or empty;
  no value, example value, value length, or digest reaches its text report,
  JSON report, errors, or warnings, and a malformed line is identified by its
  number alone. The parser emits key and line-number records, and the file
  bytes are discarded once parsed. `test/env_dotenv.bats` plants canary
  values in both files, including comments, multi-line values, and malformed
  lines, and asserts that none reaches stdout or stderr in text or JSON mode
  or the menu's rows and previews. A tracked, unignored, foreign-owned, or
  group- or world-accessible dotenv file is reported as an issue with a
  printed remedy.
- README demo regeneration uses an explicit `env -i` allowlist, private
  HOME/ZDOTDIR/XDG/TMPDIR paths, and a synthetic project. Git receives only the
  reserved `.invalid` identity fixture, disabled system configuration, and a
  ceiling at the private runtime root, so a temporary directory inside another
  repository cannot expose that ancestor's Git state. Canonical temporary
  parent paths containing `:` are refused because Git uses that character to
  separate ceiling directories. Inherited credentials, startup settings, fzf
  options, telemetry, and plugin-directory overrides are not passed to the
  recorded process. The tour opens the Git, System, and Developer menus and
  runs only three argument-free actions inside the synthetic project; every
  other dispatch is denied, so no personal repository or host state changes.
- `git-auth` reports identity, remote alignment, and authentication state
  without printing tokens. Git remote rendering strips URL user information,
  query strings, and fragments before the value reaches UI output. Inside the
  `WS_BASE_DIR` layout it also shows the workspace SSH alias and only the
  public key's fingerprint. `git-identity-check`, its `--json` document, and
  the opt-in guard name mismatching identity fields with email addresses and
  signing formats only; signing keys, key IDs, and SSH key paths never reach
  their output.
- Telemetry records command labels and timing, not command output.
- `sys-wsl` withholds any `/etc/wsl.conf` or `.wslconfig` value that contains
  a common credential indicator, such as `password=` in a `[boot]` mount
  command, from its report and its JSON document, and names only the key.
- The telemetry writer validates its five fields, excludes arguments and
  output, enforces owner-only state, and bounds record retention.
- Git, Developer, Py, System, and VPN commands capture child-tool output
  through the core `_zdx_run_captured` service: a byte-bounded tail in an
  owner-only, identity-checked directory below an owner-private or root-owned
  sticky `TMPDIR`. Failure replay is line-bounded, color-stripped, and
  control-escaped, and it replaces lines containing credential indicators,
  including URL credentials, with a redaction notice. `ZDX_VERBOSE=1` or an
  aggregate's `--verbose` streams the output live and unredacted as an
  explicit operator choice.
- A failed APT index refresh is diagnosed from a 64 KiB in-memory copy of
  APT's output, which is relayed unchanged as it runs. Displayed sources have
  URI credentials removed and are escaped. The diagnosis itself downloads and
  installs nothing; key renewal for known repositories is a separate,
  disclosed transaction described under T5.
- APT planning does not inspect generic package-manager process arguments or
  use a process-name scan as a lock oracle. Only the bounded fields required by
  the exact automatic-updater fingerprint are read to authorize a cooperative
  yield; APT itself arbitrates locks with its native zero-timeout acquisition.
  Homebrew process arguments are not inspected, and suite-owned Homebrew calls
  disable per-run analytics.
- `ws-clone` refuses URLs that carry credentials: any user information in an
  HTTPS URL and a password in an SSH or scp-like URL. `ws-status --json` never
  includes remote URLs, and `ws-status --fetch` discards fetch output, which
  can contain them.

**Residual requirements.**

- Masking must remain effective across every suite preview and diagnostic
  surface and be tested against case, delimiters, multiline values, and common
  token names. Preview and diagnostic code must never display raw credential
  files.
- The demo's System information scene shows the recording host's real OS,
  kernel, architecture, and resource facts. Review the frames before
  publishing new media.

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
  after the picker exits; it does not cap writes while the picker runs. The
  local-change pickers (`git-unstage`, `git-discard`, `git-stash`, the
  `git-amend` and stash action dialogs, and the `git-pull` mode dialog) and
  the branch pickers (`git-switch` with its change dialog, and `git-recover`)
  use the same foreground private capture and snapshot check, and their
  previews are constant programs that receive only fzf-quoted placeholders and
  hexadecimal object IDs. `git-identity-check` splits `core.sshCommand` into
  words with Zsh's `(z)` flag to find the selected key and never runs it. The nested identity, pull-request, tag, branch-cleanup, and
  push-action pickers and the No/Yes confirmation dialog capture through
  command substitution instead (see residual gaps).
- The Git loader accepts only the exact readable, non-symlink modules below its
  source-derived root. Git dispatch, previews, the fixed `less -R` stash diff
  pager, and mutation targets use fixed cases, argument arrays, typed records,
  and validated opaque identifiers rather than `eval` or computed shell text.
  Pull-request SSH alias resolution runs the SSH program Git itself would run,
  through `/bin/sh` for `GIT_SSH_COMMAND` or `core.sshCommand` as Git does,
  only as `-G -- HOST` with a validated host passed as an argument and stdin
  closed; that command is the user's own Git configuration.
- The idempotent core lazy loader uses an explicit command-to-file map below
  one source-derived module root and installs stubs through Zsh's function
  table; it does not use `eval`.
- The master router loads one exact adjacent common module, routes built-in
  suites through fixed `case` arms, and forwards arguments as literal array
  elements. Dynamic plugin dispatch requires a bounded identifier, exact
  membership in `ZDX_LOADED_PLUGINS`, and an already-defined matching function.
  Its foreground picker captures into a private bounded file, distinguishes
  cancellation from failure, and accepts only an exact row from the current
  menu snapshot.
- The `zdx-plugins` menu and its uninstall picker capture the same way,
  through a private 64 KiB-bounded file below the validated temporary root;
  they refuse data returned with a failed picker status and dispatch only an
  exact row of the current snapshot. The uninstall picker offers only valid
  plugin directory names, and a selection outside its snapshot is refused.
- The unified command-menu preview uses a constant `case` and `printf` with
  fzf-quoted fields. Sections display explanatory text instead of an executable
  sentinel. The details toggle changes presentation only. Master plugin
  completion applies loaded membership, identifier, reserved-name, and
  function-availability checks without sourcing plugins or executing their
  menus.
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
- The Developer dispatcher calls the public parser before any authoritative
  dependency or project probe. Menu availability metadata is advisory; the
  command checks it dynamically at first operational use. A missing backend
  required by one aggregate step does not gate independent steps. The absence
  of a shallow missing-tool annotation is not a readiness or provenance claim.
  Advisory probes are cached only for one rendered snapshot. `--multi` uses
  one explicit batch-eligibility allowlist and revalidates a selected row
  before dispatch, excluding destructive, source-rewriting, and nested
  orchestration commands. The Developer menu, `--multi`, and confirmation
  pickers run `fzf` synchronously in the terminal foreground and capture
  selection stdout in a private, bounded, invocation-owned result file below a
  validated temporary root; a failed picker cannot carry selection data. A
  child file-size limit caps the file during picker output, followed by
  identity and size validation before reading. A selected record must belong
  to the invocation's row snapshot before its command field is used.
- Developer argument-free commands share one exact-arity parser: only zero
  arguments or one help flag is accepted before operational probes. Menu row
  builders reject pipe, newline, and NUL delimiters before emitting fzf data.
- Developer confirmation prompts visibly escape user-derived text before
  rendering it in fzf or the terminal fallback, preventing control characters
  in a path from changing the authorization UI.
- `dev-update-actions` treats every workflow value, tag listing line, and
  `gh api` reply as data. Workflow files are read as bytes by an isolated
  (`-I -S`) parser; owners, repositories, action paths, refs, versions, and
  SHAs must match strict patterns in the parser and again in the shell before
  they reach a `https://github.com/<owner>/<repo>` URL, a `git` argument
  after `--`, or a `gh api` path, and `gh` output must be a plain integer. An
  invalid value is listed as refused and never queried or rewritten. Display
  text from workflows is escaped, and the rewriter accepts only an
  `owner/repo[/path]@<40-hex>` value and a `vX.Y.Z` comment.
- Many external calls quote targets and use arrays for complex commands.
- `zsh -n` parses tracked Zsh files.
- System telemetry browsing derives fzf rows from validated fields and never
  sends raw persisted JSON to a preview.
- `sys-wsl` parses `/etc/wsl.conf` and `.wslconfig` as data with a fixed INI
  grammar into TAB-separated records whose fields cannot contain control
  characters. Values reach only escaped UI and jq `--arg` values: nothing is
  sourced, expanded, evaluated, or executed, and the `[boot]` command is split
  into words only to recognize an `ip link set … mtu` pin. The `--json`
  documents of `sys-info` and `sys-wsl` are built by jq, never by
  concatenating text.
- System resource collectors emit typed TSV, preserve opaque identifiers, and
  revalidate the selected process, listener, or service state before mutation.
- Every System picker, including the nested telemetry, process, listener, and
  service selectors, runs `fzf` synchronously in the terminal foreground and
  captures selection stdout in a private, bounded, invocation-owned result
  file that is identity-checked before reading and removed on every path. A
  selected nested row must belong to the invocation's snapshot before its
  fields are used.
- File and Py loaders source only fixed, exact-root modules and route through
  explicit `case` dispatchers. Their top-level menus accept only a row from the
  fixed suite-owned snapshot; user paths, remote metadata, and environment
  records never become shell preview text or computed commands. Foreground
  picker results are captured in private bounded files and revalidated before
  dispatch.
- Environment uses an exact-root module loader, explicit dispatch, fixed
  menu previews, foreground private picker capture, and snapshot membership
  checks. It reads no profile files. `env-dotenv` reads a dotenv file and its
  example as bytes through a no-follow, non-blocking descriptor whose device
  and inode must match the inspected regular file, and parses them with Zsh
  patterns only: no line is sourced, evaluated, expanded, or exported, and
  only keys matching `[A-Za-z_][A-Za-z0-9_]*` leave the parser. Its Git
  probes run a resolved absolute `git` with fixed arguments after `--`, a
  literal pathspec for the tracking probe, and repository-locating variables
  such as `GIT_DIR` cleared; Apple's placeholder and a Windows `git` on the
  WSL `PATH` are never run. Remedies such as `git rm --cached` and
  `chmod -- 600` are printed as quoted display text and never executed. The
  JSON report is built by `jq` from `--arg` values and typed stdin records,
  never by shell string concatenation.
- The Oh My Zsh wrapper does not assume that adding a nested completion
  directory after `compinit` is sufficient. It validates owned, canonical
  completion files, accepts only safe `#compdef` command tokens, loads the
  functions without executing them, and binds them explicitly without rerunning
  global completion initialization. The master wrapper delegates nested
  completion to the registered suite completion.
- No product code uses `eval`.
- The VPN suite never builds a preview program from selected data. Preview
  panes are rendered in Zsh before `fzf` opens, written to one file per row in
  an owner-only private directory, and addressed by `fzf`'s integer row index
  `{n}`. The program text is therefore a constant, no record field reaches a
  shell, and no preview process holds privileges.
- VPN menu rows keep data out of the command token. A documented fourth
  field carries the target profile as an opaque value, which the entrypoint
  revalidates with the interface-name validator immediately before dispatch.
  Interface names must begin with an alphanumeric, so a validated name cannot be
  parsed as an option by `wg-quick`, a filename, or a device name.
- The command-line insert widgets only edit the line: the chosen branch,
  pull-request number, PID, port, or path is appended to `LBUFFER` quoted with
  `${(q)…}`, and nothing is executed or accepted. Their picker goes through
  the core `_tk_fzf` wrapper with the inherited fzf settings emptied. Each row
  is `<index><TAB><label>`; the selection must be a digit-only index whose
  complete row matches the invocation's snapshot before the value is read
  from a separate array, so a label is never parsed back into data and a
  forged result is never evaluated arithmetically. Labels are escaped with
  `${(V)…}`, `gh` titles arrive through `jq @tsv`, and pull-request numbers
  must be decimal. The plugin wrapper loads `zdx-widgets.zsh` only from the
  core function root as a regular, non-symlink, readable file, and binds a
  chord only when the main keymap reports it unbound.
- `zdx status --json` builds its one-line document with one constant
  `jq -c -n -M` filter; repository paths, branch names, and the user email enter only
  through `--arg`, and numbers and booleans are validated before `--argjson`.
  The document carries no environment values: the active virtual environment
  is reported only as booleans.
- `vpn-mtu-probe` accepts a target from `--target` or `VPN_MENU_MTU_TARGET`
  only as a dotted-quad IPv4 literal without leading zeros or a host name of
  letters, digits, and hyphens whose last label starts with a letter.
  Option-like values, shell metacharacters, IPv6 literals, and other numeric
  notations are refused with status `2` before any program runs, and the
  accepted value reaches `ping` as one argument after `--`. Interface names
  parsed from `ip`, `route`, and `wg` output are validated before they are
  displayed or passed back to `ip` or `ifconfig`. Its recommendations are
  printed text that nothing executes, and its JSON is built by `jq` from
  `--arg` and validated `--argjson` values.
- The Workspace loader sources only fixed, exact-root modules, and `ws-menu`
  dispatches through a fixed `case`. Its menu and pickers capture in the
  foreground into private bounded files and accept only an exact snapshot row.
  The `ws-jump` preview is a constant program: fzf supplies only the integer
  row index `{n}`, which selects a line of an owner-only snapshot file, so no
  directory name, however hostile, reaches program text; names with control
  characters or `|` are skipped. `ws-clone` passes the validated URL to
  `git clone` after `--`, and resolves workspace SSH aliases with the SSH
  program Git would run, as `-G -- ALIAS` with the alias as an argument and
  stdin closed; a `GIT_SSH_COMMAND` or global `core.sshCommand` runs through
  `/bin/sh` exactly as Git runs that user configuration.

**Residual gaps.**

- The nested Git identity, pull-request, tag, branch-cleanup, and push-action
  pickers and the Git No/Yes confirmation dialog capture selections through
  command substitution, without the private bounded result file used by the
  Git command menu and local-change pickers. Their previews are empty or
  constant.
- ShellCheck is configured for `.sh` and `.bash`, not `.zsh`; it is not a Zsh
  injection control. Zsh safety depends on review, BATS, explicit dispatch, and
  the absence of dynamic shell construction.

**Required treatment.** Use fixed `case` dispatch, argument arrays, opaque
validated identifiers, option terminators, and post-selection revalidation.
Keep `eval` out of interactive and configuration paths.

### T3. Excessive or misdirected deletion

**Risk.** An empty variable, broad glob, traversal, symlink, archive member, or
wrong base directory causes deletion or overwrite outside the intended scope.

**Current controls.**

- High-risk workflows commonly request confirmation.
- `zdx-plugins` removal accepts only a validated identifier, so no name can
  leave the canonical plugin root, and refuses a linked or foreign plugin
  directory. It prints an exact plan, supports `--dry-run`, fails closed
  without a terminal unless `--yes` is given, revalidates the root and plugin
  directory identities after confirmation, renames the directory into private
  staging under the manager lock before deleting it by identity, and reports
  a partial deletion with the remaining path.
- Several Git cleanup paths protect default branches.
- Git mutations build typed plans from canonical refs, object IDs,
  repository and remote identity, then confirm and revalidate before execution.
  Broad operations support dry-run; normal and forced pushes use exact
  OID-or-absence leases; pulls fetch into invocation-owned temporary refs and
  promote reviewed object IDs with compare-and-swap updates. GitHub writes
  re-fetch selected state after confirmation and report partial failure.
  Tag publication and deletion inspect and mutate the same single frozen push
  URL; remote branch cleanup also rejects multiple push destinations. Every
  push disables `push.followTags` and submodule recursion so configuration
  cannot publish unplanned refs, and multi-ref plans never print raw push URLs.
  Path commands run from the repository root so a subdirectory cannot redirect
  a root-relative selection to another file; discard refuses untracked or
  ignored obstacles, compared without letter case under `core.ignorecase` so a
  restore cannot replace a case variant on APFS or a Windows drive, and new
  tags, stash branches, and tracking refs that collide by letter case are
  refused instead of shadowing an existing ref; `git-discard --all` plans
  every tracked change back to HEAD, deletes untracked files only with
  `--include-untracked` and through `git clean` without `-x` so ignored files
  and nested repositories are never deleted, and revalidates the complete
  reviewed state after confirmation;
  `git-unstage` requires confirmation or `--yes` before dropping a staged
  version that is not in the working tree; history-rewriting plans bind the
  symbolic branch as well as the commit. Discard, stash deletion, multi-ref
  pushes, tag publication, tag deletion, and remote branch cleanup stop before
  later targets on interruption. A local identity profile writes explicit
  signing and SSH overrides instead of silently inheriting another profile's
  key; it removes only the inherited command's key selection and keeps its
  SSH program and agent options.
- `git-switch` creates a branch only as the local branch that tracks a chosen
  remote-tracking ref, at the reviewed object ID, and refuses a local branch
  of that name that differs instead of moving it. It refuses untracked or
  ignored files that checkout would overwrite, since Git silently replaces
  ignored files. Uncommitted changes need a reviewed plan and an explicit carry
  or stash choice, and HEAD, the index and working tree, the stash list, and
  the target ref are compared again after authorization. `git-recover` only
  adds a branch through `git update-ref` with an empty old value, so Git
  refuses the write if the ref exists; it never moves, resets, or deletes a
  ref.
- System cleanup displays an applicable plan, supports dry-run, fails closed
  non-interactively, executes only unique typed confirmed records, revalidates
  cache scopes, reports partial failure, and excludes shared `/tmp` and Docker
  resources.
- Developer cleanup freezes the literal and resolved project root plus its
  device, inode, and type, and matches it to the open working-directory anchor.
  Each reviewed target is stored as a relative path plus device, inode, and
  type; root and target identities are revalidated after authorization and
  around each relative removal. Discovery is bounded and NUL-delimited, does
  not follow links, and prunes `.git`, `*.git`, `.venv`, `node_modules`,
  `vendor`, `vendored`, installed-package trees of any virtual environment
  (`site-packages`, `dist-packages`, `.tox`, `.nox`), and nested repositories
  discovered from `.git` markers; a directory target containing a nested
  repository is skipped, except `.terraform/`. An unreadable directory is
  skipped with a warning because nothing below it can be discovered or
  removed; other discovery errors fail closed. Each discovery stream and
  marker inventory stops at one above the configured plan bound; each category is capped after its streams are
  combined, and associative first-seen deduplication caps the final plan at
  10,000 unique targets by default. An excess fails before display,
  authorization, or mutation. The filesystem root, home directory, symlinked
  or replaced roots, and changed targets are refused. Root `build/`, `dist/`,
  and Cargo `target/` are the only build directories selected (`target/` only
  with a root `Cargo.toml` or `target/CACHEDIR.TAG`), `.terraform.lock.hcl` is
  preserved, and `--keep-build` preserves all three including their contents.
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
  failures, and prints a per-step summary with direct retry commands. Chatty
  backends run with privately captured, bounded output that is replayed
  redacted only on failure; the lockfile evidence reads `uv.lock` through a
  no-follow descriptor with a 16 MiB bound, and the hook revision table is
  built from the guard's validated records. A PyPI
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
- Developer restore and update publication validate the direct write
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
  `RUFF_OUTPUT_FILE`, and TFLint refuses `--fix`. `dev-check-types` accepts no
  arguments, so no caller option reaches its type checkers.
- Developer persisted state is validated on every use rather than at load time.
  Dedicated state directories must be literal, owned, mode `700`, identity
  stable, inside the project or home, and free of symlink components. State
  files must be owned, singly linked regular files with no group or other
  access. Backups and reports use private no-clobber publication. Readers
  require exact mode `700`; a writer may restrict an already owner-controlled
  dedicated directory to that exact mode. Automatic restore accepts only the
  exact invocation backup.

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
  binding its directory and file identity across authentication. Their
  `wg-quick` output goes to the core's private, bounded, identity-checked
  capture directory and is replayed, with credential-like lines redacted,
  only when the transition fails. A missing or
  unsafe profile refuses disconnection rather than selecting a same-name file
  from another directory. On macOS, where a profile's tunnel runs on a
  `utunN` device, a disconnect freezes the device and the identity of
  wg-quick's root-only `.name` record before authentication and aborts when
  either changed; a device without such a record is reported but never
  targeted, and an ambiguous pairing is read through sudo or reported as
  locked rather than guessed. Reconnection and default connection fail when live
  state is unreadable. Interrupted sudo authentication and WireGuard probes
  do not trigger fallback work; protected profile existence, metadata, and
  checksum reads retain their interruption status through tunnel control.
  Tunnel interruptions stop later batch targets
  and exit the manager while cleaning its private preview state.
- File mutations are confined below an owned, non-group/world-writable current
  directory, which may be reached only through trusted aliases (the core
  trusted-directory rule) and is checked by its canonical path. Exact plans
  reject links, special files, hard-linked regular files, overlapping trees,
  unsafe destination parents, and mount crossings. Linux and WSL compare
  paths with a bounded `/proc/self/mountinfo` snapshot per pass, which also
  lists bind mounts; macOS compares device numbers, which suffices without
  bind mounts; other kernels fail closed. Where `mv` lacks `-T` (BSD), the
  post-move identity checks detect a destination directory that appeared
  after review, and nothing is deleted.
  Output overwrites freeze both metadata and SHA-256 content. Archive creation
  and extraction verify publication postconditions; large-file and junk-file
  deletion rename the exact reviewed object to a sibling quarantine and delete
  only that identity, retaining and reporting recovery data on failure. Junk
  discovery matches only exact regular-file names, never follows links, prunes
  `.git` directories and generated, vendored, and installed-package trees, is
  bounded to 12 levels and the File inventory limits, and skips an unreadable
  directory with a warning. Each candidate is screened against the per-target
  boundary first: a foreign-owned, group- or world-writable, or hard-linked
  junk file is skipped with a counted warning instead of refusing the plan. An
  untrusted or changed directory above any candidate still refuses the whole
  run, and revalidation after authorization stays strict. TAR extraction
  first matches a private source snapshot, then uses that same object for
  preflight and extraction; it limits names, exact file sizes, total bytes,
  entries, types, traversal, links, and realized members before a new
  destination is published.
- `file-trash` is the one File mutation outside the current directory. `put`
  plans its targets under the same per-target boundary, plans a symbolic link
  as the link itself below a canonical trusted parent and never follows it,
  refuses the trash, a directory containing it, and paths inside it, and
  accepts a directory only when the deletion engine's recursive check passes,
  so every trashed item can later be purged. Items move only by the
  no-clobber `mv` adapter after the source and destination match by device
  number and, on Linux and WSL, by nearest mount point, so a cross-filesystem
  or bind-mount move is refused instead of becoming a copy and delete.
  `restore` never replaces an existing path or recreates a missing parent,
  and writes only to a recorded absolute, normalized path whose parent is a
  canonical directory that the user owns and others cannot write, below
  trusted ancestors. `purge` deletes through the same quarantine engine,
  which removes a reviewed link as the link itself. Every plan supports
  `--dry-run`, fails closed without a terminal or `--yes`, and revalidates
  items, records, parents, and absent destinations after authorization and
  before each move.
- Py lifecycle mutations accept only `.venv`, `venv`, or one safe direct child
  of `.virtualenvs` below an owned project. Creation freezes the absent target;
  automatic rebuild fails closed. Removal fingerprints the target and parent,
  rejects nested mounts (a bounded mount-table read on Linux and WSL, an
  `lstat` device walk on macOS, refusal elsewhere), renames into a private
  same-parent quarantine, and
  revalidates the exact environment before recursive deletion. Package
  mutations freeze project metadata, lock state, backend, or the exact local
  environment interpreter after authorization. That interpreter must not be
  group-writable, except a root-owned python.org framework interpreter on
  macOS whose only group writer is `admin`, the administrators who can
  already act as root; the exception is limited to
  `/Library/Frameworks/Python.framework/Versions/<version>/bin` below
  ancestors that pass the ordinary rule. Poetry detection fails closed and
  ambient `pip` is never a fallback.
- Environment changes no user files. Its private picker capture paths must
  prove that they are owned direct children of the expected root before
  permission changes or cleanup can touch them; malformed multiline output from
  a single-select picker fails closed.
- Workspace deletes no user data. `ws-clone` refuses any existing
  destination, including a symbolic link, and never creates `WS_BASE_DIR`
  itself. It clones into a mode-`700` staging directory next to the
  destination, publishes with a no-clobber rename followed by an identity
  check, and recursively removes only that staging directory, after a failed
  or interrupted clone and only while its name, owner, device, and inode still
  match the directory it created. A destination that appears during
  publication leaves everything in place for inspection.

**Residual gaps.**

- `dev-run-hooks` and `dev-run-ruff-format` rewrite files without a separate
  confirmation. That is their documented purpose, but it means a
  `dev-run-all-checks` run on a project with formatting hooks can modify the
  working tree.
- System cleanup, File, and Py deletion controls have focused BATS coverage
  in the repository gate; real macOS, DrvFs, and cross-filesystem behavior is
  verified manually. The trash's cross-filesystem refusal is tested with a
  mocked device change and a fixture bind mount, not a second real
  filesystem.
- The trash's same-filesystem check and its rename are separate steps. A
  same-EUID process that mounts over the trash or a source in between, such
  as with a user FUSE mount, could let `mv` fall back to copying; the
  post-move identity check reports it, and the data stays in the trash.
  `file-trash restore` writes outside the current directory by design, to
  the recorded original path under the checks above.
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
  only `sudo -n -v` with closed stdin, once at start and then every 30
  seconds. On macOS this scope includes the adjacent Homebrew entry because
  casks can require sudo. The refresher cannot prompt, and every privileged
  command constructed by ZDX uses `sudo -n`. Because sudo's default timestamps
  are per terminal session, the worker is a process substitution of the
  invoking shell: it shares that session and controlling terminal, stays out
  of the caller's job table, and so produces no asynchronous
  `[n] ... terminated` or `done` UI. A refresher that cannot renew the
  timestamp in that session (for example under `timestamp_type=ppid`) is
  stopped with a visible warning instead of failing silently, and a worker
  whose caller has exited stops without refreshing. Its handle binds the
  worker PID to the caller's descriptor for a private status pipe and that
  pipe's device and inode. Cleanup signals the PID only while that open pipe
  proves the worker still runs, so a reused PID cannot be signaled, then
  requires a bounded acknowledgement and the end of the pipe after the last
  privileged entry; an `always` block performs the same ownership-scoped
  lifecycle on early failure, return, or interruption. Renewal of a real sudo
  timestamp is verified only through session and terminal identity and a sudo
  mock. A direct `update-apt` invocation
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
- APT signing-key renewal elevates only the exact announced
  `sudo -n <trusted install> -m 0644 -o 0 -g 0 <staged-key> <keyring>`
  argv, and its rollback the same argv with the keyring's previous mode and a
  private copy of the previous content. Download, parsing, conversion, and
  key-ID binding run unprivileged; the trusted `install` program is resolved
  to an absolute, root-owned path that group and other users cannot write.
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
  There is no polling, sleep, or lock retry; the only repeated APT call is the
  single index refresh that verifies a renewed signing key. A native lock
  refusal therefore fails that entry immediately; the default aggregate then continues with its
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
  `SUDO_ASKPASS=/usr/bin/false`, or when that file fails the root-owner, link,
  and mode validator a private mode-`0700` script below the validated
  temporary root that only exits `1` and is removed after the run, makes
  Homebrew's internal `sudo -A` fail instead of prompting when the shared
  timestamp is unavailable. Without either, the Homebrew run is refused. The
  mandatory
  `brew upgrade --no-ask` avoids Homebrew ask mode silently skipping an
  authorized non-TTY mutation while returning success. Linuxbrew does not use
  the Darwin-only askpass guard. Every Homebrew phase receives closed stdin.
- System package operations resolve direct-root versus narrow `sudo`
  execution immediately before the final package-manager command. Their UI
  renders the exact resolved prefix: `sudo -n` when escalation is required and
  no prefix for direct-root execution.
- `zdx-doctor` installs only package names from its fixed dependency table
  that match a strict name pattern, shows the exact package-manager command,
  and requires an interactive confirmation; without a terminal it installs
  nothing.

**Residual gaps.**

- The `zdx-doctor` batch installer runs the host package manager through
  ordinary, possibly prompting `sudo` after its single confirmation. It does
  not use the System suite's frozen plan, post-confirmation revalidation, or
  `sudo -n` model.
- A PID or service can still change after the final userspace comparison and
  before the kernel or service manager receives the operation; the smallest
  possible command scope limits but cannot eliminate that race.

**Required treatment.** Keep discovery unprivileged, validate twice, display the
exact operation, scope `sudo` narrowly, clean keepalives on every path, and
never elevate downloaded or user-computed shell text.

**VPN privilege controls.**

- The VPN suite elevates through four primitives with one sequence: announce the
  exact privileged operation, authenticate once with `sudo -v`, revalidate the
  target, then run each narrow transaction primitive with `sudo -n --`, which
  cannot prompt. Revalidation after authentication is tested by removing the
  profile between the two calls. Directly readable paths never escalate:
  listing profiles, checking backups, and rendering previews record no `sudo`
  call at all.
- `vpn-config-edit` uses `sudoedit`, which copies the file, runs the editor as
  the invoking user, and reinstalls the result as root, so an editor shell
  escape such as `:!sh` in Vim never yields a root shell and `$EDITOR` is not
  word-split into a root command. There is deliberately no fallback to
  `sudo $EDITOR`; when sudoers forbids `sudoedit` the command reports the
  failure and changes nothing.
- Imported profiles cannot introduce commands that `wg-quick` would
  execute as root. Import accepts only a private, singly linked, current-user
  regular file no larger than 1 MiB, verifies `[Interface]` and `[Peer]`, and
  refuses every `PreUp`, `PostUp`, `PreDown`, or `PostDown` assignment. NUL and
  other control bytes are refused first, because wg-quick's bash `read` drops
  NUL bytes and `Post<NUL>Up` would otherwise evade the text check and still run
  as root. It fingerprints the source around a private staging copy and
  atomically installs validated mode-`600` content without replacing an
  existing profile.
- The WSL DNS hooks the VPN suite writes are executed by root on every tunnel
  transition, and their resolver address comes from an imported profile's
  `DNS =` line. The value is validated as a strict comma-separated list of at
  most eight semantically valid IP literals and refused otherwise, so a
  downloaded profile cannot inject code into the root-executed `sh -c` body;
  each configured fallback must be exactly one valid IP.
  A sentinel is trusted only when its exact complete generated hook block is
  present, so a partial or imitated marker cannot bypass hardening.
  Patching fingerprints the profile and directory, builds an owner-only staged
  result, asks `wg-quick strip` to parse it through the announced sudo
  boundary (wg-quick escalates itself for `strip`) before publication,
  revalidates after authentication, and replaces the live profile atomically.
  A symlinked `/etc/resolv.conf`, which `chattr` cannot pin, is refused. The
  original remains untouched on validation or parse failure. The IPv6
  compatibility rewrite is also staged and parsed, keeps a one-time backup, and
  prevents `wg-quick up` when no required IPv4 value can be retained.
- VPN reads protected profile metadata with one fixed program,
  `zsh -f -c <program> zdx-vpn-stat <path>`, run by a root-owned zsh whose
  file and directories only root can change. The path is a positional
  argument, never program text, and the record has the unprivileged
  fingerprint format without GNU-only `find -printf` or `-perm /` probes.
  Privileged installs use `install -o 0 -g 0`.
- The WSL IPv6 compatibility rewrite strips `::/0` only when
  `wslinfo --networking-mode` reports NAT or the host has no IPv6 default
  route; under mirrored networking with IPv6 it would otherwise send IPv6
  outside the tunnel. When the resolver pin cannot hold (no `chattr`, or a
  filesystem without Linux attributes such as WSL1's), hardening warns instead
  of letting the hook's `chattr … || true` fail silently.
- **macOS trust boundary.** Homebrew installs `wg-quick`, `wg`,
  `wireguard-go`, and Bash owned by the user, and root runs them on every
  tunnel transition; a user-owned Homebrew profile directory likewise lets the
  user's processes add `PostUp` hooks that root runs. Any process running as
  the user can therefore obtain root on the next VPN transition. The suite
  narrows this to the user account and makes it explicit: it runs
  `sudo -n -- <bash 4+> <wg-quick> up|down <profile>` with absolute paths and
  announces that exact argv; it resolves `wg` and `wireguard-go` beside
  `wg-quick`, because wg-quick prepends its own directory to `PATH`; it refuses
  each of these files when the file, a link on its path, or any directory
  above them is owned by another account, writable by other users, or
  writable by a group other than `wheel` or `admin` (Homebrew's prefix is
  group-writable by `admin`, whose members can already use sudo); and
  because the default macOS sudoers keeps the caller's `PATH` instead of a
  `secure_path`, it runs its fixed file primitives from `/bin` and `/usr/bin`
  and refuses any other bare command name before sudo. The preferred profile
  directory is the root-owned `/private/etc/wireguard`; a Homebrew directory
  is selected only when it already holds profiles and the system directory
  does not exist. A user who needs a root-only boundary must install the
  tools and profiles where only root can change them.
- On macOS, `sudoedit` refuses a user-writable directory, so a profile there is
  edited as a private copy by the user's editor, never through sudo, and
  published atomically only after it is revalidated; a root-owned profile in
  such a directory is read and reinstalled through the announced
  `install -m 600 -o 0 -g 0` path.
- `vpn-mtu-probe` is unprivileged by construction. It lists WireGuard devices
  with `wg show interfaces` directly, never through the suite's warm-`sudo`
  fallback, reads no profile file, and only prints the MTU changes it
  recommends, including the WSL `[boot]` line; the `sudo` recorder proves no
  elevation in its tests.

**Residual requirement.** On Linux and WSL, VPN privileged helpers pass fixed
command names and validated arguments to `sudo -n`. They rely on the host
retaining sudo's normal trusted `secure_path`; a sudoers policy that preserves
an attacker-controlled `PATH` is outside the suite's trust model. On macOS the
pinned primitives and validated absolute tool paths remove that dependency,
but not the user-account trust boundary above. The VPN smoke workflow brings
one real test tunnel up and down through the suite on Ubuntu and macOS runners
with passwordless sudo, which exercises the macOS runtime record, device
pairing, and routes; WSL networking, the DNS hardening, and interactive or
password-protected sudo remain verified only through mocks.

### T5. Compromised remote installer or artifact

**Risk.** A moving `latest` archive or installer script is replaced upstream or
in a compromised release channel and then installed, potentially as root.

**Current controls.**

- Downloads use HTTPS and generally fail on HTTP errors.
- Without a Homebrew or Snap owner, `update-awscli` refuses automatic bundle
  installation and points to AWS's detached-signature verification procedure.
- `update-starship` updates only an installation owned by Homebrew or Cargo and
  refuses an unknown owner instead of executing the upstream installer.
- The aggregate deduplicates Homebrew-owned AWS CLI, Starship, fzf, uv, and
  Google Cloud SDK installations under `update-brew`. uv ownership is
  bound to the canonical active executable below the resolved Homebrew prefix;
  the mere presence of a second Homebrew uv formula cannot suppress the active
  self-managed updater. Direct self-update uses that same resolved path. Google
  Cloud SDK ownership is bound to its active executable in the same way: the
  `gcloud-cli` or `google-cloud-sdk` cask path below the Homebrew prefix, or
  the APT package path, never merely an installed package. Every tool step
  uses the executable that `PATH` selects, refuses a world-writable one, and on
  WSL never runs a Windows program from the appended Windows `PATH`. Native
  macOS `softwareupdate` remains a separate operating-system scope: it installs
  only listed labels that need no restart, by exact validated label with
  `--no-scan`, and never passes credentials, `--all`, or `--restart`; restart
  and macOS updates are left to System Settings.
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
- The maximum aggregate includes mutable Git-owned updates by default;
  `--safe-only` excludes them. Direct Git-owned fzf, Oh My Zsh, and
  custom-plugin updates require owned, symlink-free checkouts below `HOME`,
  display origin and HEAD, fingerprint the repository and `.git` directory,
  revalidate after authorization, and pull fast-forward only. The fzf installer
  must also match its tracked blob and pass file-identity checks immediately
  before execution. One aggregate authorization — the interactive plan
  confirmation or `--yes` — pre-authorizes every applicable mutable origin,
  and the dry run is the review path before unattended execution.
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
- APT signing-key renewal downloads a publisher's OpenPGP key and installs it
  into an APT keyring, which decides what APT trusts. Its controls are:
  - **Curated registry.** Only eight repositories are renewed: GitHub CLI,
    Google Cloud SDK, Charm, Docker (Debian and Ubuntu paths), HashiCorp,
    Microsoft, NodeSource, and Google Chrome. A source matches on its `https`
    scheme, exact host, and path prefix; a URI with credentials, a port, or
    percent-encoding never matches. Each entry names one fixed HTTPS key URL
    on the publisher's own domain; no URL comes from a source file or from
    APT output.
  - **HTTPS transport.** The trusted, root-owned curl runs as the user with
    `-q` (no curlrc), `--proto =https --proto-redir =https --tlsv1.2`, at most
    five redirects, 30 seconds, and 1 MiB, enforced again by a byte-bounded
    pipe, into a private directory below the validated temporary root.
  - **Key-ID binding.** gpg parses the key unprivileged with
    `--show-keys --with-colons` in a private throwaway home, never the user's
    keyring. A key is accepted only when it holds a currently valid,
    signing-capable key or subkey whose fingerprint ends with a key ID that
    APT reported (`NO_PUBKEY`, `EXPKEYSIG`, or sqv's `Missing key`, at least
    16 hexadecimal digits). Proactive renewal of a keyring whose signing keys
    have all expired, before APT reports anything, requires a valid signing
    key that the old keyring does not hold as valid; HTTPS on the
    publisher's domain is then the only anchor. Secret-key material, an
    unparsable file, and a revoked key are refused.
  - **Dedicated keyring only.** The target is the absolute `signed-by` file
    of the failing source: a `.gpg` or `.asc` regular file, not a link,
    singly linked, root-owned, and not group- or world-writable, directly in
    a root-owned `/etc/apt/keyrings` or `/usr/share/keyrings`. Global
    `trusted.gpg.d` trust, inline deb822 key blocks, fingerprints, several
    keyrings, a keyring shared with another publisher's repository, and
    unknown repositories are never changed. Armored input is converted with
    `gpg --dearmor` for a `.gpg` path; an `.asc` path keeps armored text.
  - **APT re-verification and rollback.** A private copy of the current
    keyring is kept. After installation the index refresh runs once more (or,
    for a proactive renewal, the first refresh follows it); the key is kept
    only when that refresh succeeds or fetches every repository of the
    keyring without a failure. Otherwise, and when the phase is interrupted
    before that check, the previous keyring is reinstalled through the same
    argv. A failed restore keeps the private copy and names its path.
  - **Disclosure and opt-out.** The `update-system` plan shows
    `key renewal for known repositories` in the APT scope that its single
    authorization covers; standalone `update-apt` shows it, and every expired
    keyring it would renew, before its confirmation; `--dry-run` reads only
    local sources and keyrings and downloads and installs nothing.
    `SYS_APT_KEY_RENEWAL=0` keeps diagnosis only; any value other than `0` or
    `1` fails closed before APT runs.
- `dev-update-actions` updates the GitHub Actions a project's CI runs
  without executing any action code. It reaches github.com only through
  `git ls-remote --tags` over HTTPS and, for the optional release-age
  cooldown, `gh api --hostname github.com`. Git runs with prompts disabled, an
  empty askpass, no credential helper, and `protocol.allow=never` except
  HTTPS, so an `insteadOf` rewrite cannot move the query to SSH, a local path,
  or another transport and no token is sent. Every query and API call is
  bounded by `DEV_ACTIONS_TIMEOUT` through the core timeout service, Git's
  HTTP low-speed limit, and a 16 MiB listing limit, and a timed-out batch stops
  later queries. Each updated reference is pinned to a release's commit SHA
  (annotated tags are peeled) with the release named in a comment; moving
  tags, branches, and prereleases are never pinned as such, nothing is
  downgraded, and newer majors need `--major`. With an authenticated `gh`, a
  release younger than `DEV_ACTIONS_COOLDOWN_DAYS` (default 7) is held back,
  and an unreadable age fails that reference closed; without `gh` the plan
  says once that ages were not checked. The rewritten files are built and
  re-parsed in a private workspace, shown as an exact plan, confirmed or
  authorized with `--yes`, backed up, and published by compare-and-swap.
  `actionlint` and `zizmor --offline` then validate the changed files when
  installed; a validator that passed before and fails after restores every
  file from its private original.
- The Developer suite never pipes a remote installer to a shell. The
  `dev-update-all` host toolchain step calls the targeted public
  `sys-menu update-uv-system` owner directly. Developer maintenance never
  invokes ambient Python or `pip`, so PEP 668 externally managed environments
  remain intact. `dev-update-terraform` binds tfenv, Homebrew, and APT claims
  to the resolved active binary. tfenv additionally requires its canonical
  launcher to be the active Terraform launcher's sibling and ignores inherited
  `TFENV_ROOT` for attribution. Developer reports the proven owner workflow
  without executing the dynamic `tfenv install latest` path;
  `dev-update-tflint` applies the same rule to Homebrew and reports
  `sys-menu update-brew`. A separately installed package cannot claim a
  different active executable. An unproven owner gets the documented
  download-and-verify procedure and no host mutation. No flag enables an
  installer pipe.
- TFLint plugin initialization is not an implicit part of linting.
  `dev-run-tflint` runs recursive linting by default; the caller must select
  `--init`, review the remote-code effect, and confirm or pass `--yes`.
  Initialization status is propagated before linting proceeds.
- Ephemeral runners are an explicit trust decision. Declared Python quality
  gates must resolve inside the exact project `.venv`; they never fall through
  to a local binary or opt-in `uvx`. Only undeclared Python tools retain those
  fallbacks. Markdownlint, the only Node gate, uses the project binary, then a
  local binary, then opt-in `npx`. Project-local Node executables remain
  project-controlled code; their presence avoids the `npx` fallback but is not
  an integrity guarantee. Installed-package inventories use only an
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
  Tests and configured hooks remain deliberate project-controlled-code
  boundaries; effect labels do not claim to sandbox them.
- Developer metadata readers (`pyproject.toml`, `uv.lock`, pytest
  configuration, PyPI JSON, the hook revision guard, and update
  fingerprints) run one host interpreter that provides the standard `tomllib`:
  `python3`, then `python3.14` through `python3.11` on `PATH`, then the uv
  installation that `uv python find --system --no-project` reports, then the
  project `.venv` interpreter after the runners' `sys.prefix` validation.
  Every reader and the qualification probe run with `-I -S`, so the working
  directory, `PYTHONPATH`, the user site, and `.pth` files cannot execute code
  while project files are parsed. The choice is remembered only within one
  command run. On macOS the Command Line Tools placeholders for `git` and
  `python3` are never executed, and uv is then limited to its own
  installations so it cannot query the placeholder either. On WSL, a program
  that resolves to a Windows drive is not accepted as a Linux tool, so a
  Windows launcher on the appended `PATH` cannot stand in for a missing
  backend. A project or state directory on a DrvFs drive without metadata
  reports mode `777` and stays refused as private state.
- The Py suite never bootstraps a package backend or invokes ambient `pip`.
  Project package and isolated-tool mutations disclose that index content is
  executable code, require an explicit reviewed plan, and bind execution to the
  frozen uv, Poetry, pipx, or project-environment scope. Poetry metadata or
  backend ambiguity fails closed.
- The dependency doctor treats `timeout`/`gtimeout`, `sha256sum`/`shasum`,
  `ip`, and GNU `tar` (as `tar` or `gtar`) as semantic capabilities; none of
  these capabilities is silently added to the batch installer. Rows that
  cannot apply on the host, such as `ip` on macOS, are shown as not
  applicable, and Apple's Command Line Tools
  placeholders for `git` and `python3` are reported missing without being
  run. The optional `fd`, or Debian's `fdfind`, is reported for faster
  workspace discovery but never counted as an issue or installed.
- `ws-clone` contacts only the host of a validated `https://`, `ssh://`, or
  scp-like URL; local paths, `file://`, `ext::` transport helpers, and other
  schemes are refused before Git runs. It downloads a repository but executes
  none of its content: a clone carries no hooks and recurses into no
  submodules. The plan names the host and states that its content is not
  reviewed, and the clone needs confirmation or `--yes`. `ws-status --fetch`
  is the suite's only other network access; it is opt-in, disclosed, limited to
  each repository's own configured remote, and updates only remote-tracking
  refs.

**Residual gap.** The vendor self-updaters and package managers that System
runs (`uv self update`, `rustup update`, `gcloud components update`,
`pipx upgrade-all`, `cargo install`, the Node version managers, and the host
package managers) and the `zdx-doctor` batch installer rely on those tools'
own artifact verification; ZDX does not pin or verify what they download.
Enabling `DEV_ALLOW_EPHEMERAL=1` permits unpinned, unverified remote
execution by the user's own decision: an ephemeral runner resolves whatever the
index currently publishes. TFLint initialization is explicit, but its plugin
artifacts and trust policy belong to TFLint; authorization is not provenance
verification. The manual TFLint update path tells the user to choose a pinned
release and verify its checksum, but the suite does not download or verify that
artifact on the user's behalf. Git-owned updates are mutable remote code even
when their origin and current commit are displayed.
APT signing-key renewal trusts each registry publisher's own HTTPS domain
exactly as following its official installation instructions would: a
compromised publisher domain or a mis-issued TLS certificate for it can serve
a key that APT then trusts for that repository. Key-ID binding limits a
reactive renewal to the key APT asked for, but the repository's signatures
come from the same publisher, so binding cannot detect a compromise of both.
A proactive renewal has no key ID to bind. Renewal replaces the whole keyring
file with the publisher's published keyring, and a keyring owned by a
publisher package can differ from that package's copy until the package
next updates it.
`dev-update-actions` trusts github.com's tag listing over TLS at resolution
time: a SHA pin prevents later tag movement, but a release that was already
compromised when it was resolved is pinned faithfully, and the cooldown
applies only when an authenticated `gh` can read GitHub's release or commit
date. Advisory review of the pinned actions remains manual.
Py package and tool installation executes mutable index content by the
user's explicit decision. A package built from source during such an
installation, or a packaged project that uv builds while the Developer update
commands synchronize it, can resolve isolated PEP 517 backend requirements
outside the project's `uv.lock`, so reviewing `uv.lock` alone does not cover
that build-time supply chain.
A repository cloned by `ws-clone` is mutable remote content that ZDX does not
verify, and the user's own Git configuration still applies during the clone:
an `init.templateDir` hook, a Git LFS filter, or a credential helper runs as
it would for any clone. Fetches through SSH can still ask for a key
passphrase on the terminal, because the user's SSH command is not changed.

**Required treatment.** Pin versions, verify an upstream checksum or signature,
use a private temporary directory, validate archive members and expected files,
and elevate only the verified final install step. If upstream provides no
verifiable artifact, show official manual instructions instead of executing it.

### T6. Malicious or compromised plugin and override code

**Risk.** A plugin Git origin, plugin update, `config.zsh`, or `overrides.zsh`
executes arbitrary code in the user's shell.

**Current controls.**

- The runtime loader resolves the plugin root through trusted aliases only and
  requires an owned, non-symlink canonical root that group and other users
  cannot write, below trusted ancestors, plus an owned, singly linked regular
  entrypoint that remains an exact child of that root. Scanning and sourcing
  use only the canonical root.
- Plugin directory names and required entrypoint/function names are checked.
- Runtime loading performs a Zsh syntax check, and path validation repeats
  immediately before source.
- `zdx-plugins` installs and updates as one locked, staged transaction (see
  [`plugins.md`](plugins.md#plugin-manager-lifecycle)). An exclusive `fcntl`
  lock that the kernel releases on exit refuses concurrent and nested runs.
  Each transaction clones into a private mode `700` staging directory inside
  the canonical plugin root, with Git prompts, askpass helpers, unusual
  transports, and submodule recursion disabled and a stalled HTTP transfer
  aborted. The staged tree must pass the loader's own entrypoint rule with
  the staging directory as its root, contain no symbolic link, and pass
  `zsh -n`; a bad commit signature is refused.
- Before activation the manager renews the trust decision. It shows the
  credential-redacted origin, the branch, the installed and new commits with
  escaped subjects, the full new object ID, the commit count and whether the
  history fast-forwards or was rewritten, the Git signature verdict (unsigned
  is a verdict, not a failure), up to ten incoming subjects, and the
  arbitrary-code warning. `--dry-run` stops there. A terminal prompt or an
  explicit `--yes` is required; a non-interactive run without `--yes` is
  refused before any fetch.
- After the decision the root, staging, staged tree, reviewed commit, clean
  staged files, and, for an update, the installed checkout's identity, commit,
  and clean state are revalidated. Publication is a verified same-filesystem
  rename to an absent destination; an update first renames the installed
  version into staging, so it stays intact until the new one is active.
- Activation repeats the loader's checks, clears the conventional
  `_<NAME>_MENU_SOURCED` sentinel, and sources the entrypoint with its output
  on stderr. A non-zero `source` status or a missing menu function rolls the
  files back by verified renames, restores the replaced menu function and
  sentinel, reports the failure, and never announces a reload. An
  interruption after publication or between the renames rolls back the same
  way, and the next run restores a previous version that a hard kill left in
  staging without ever deleting one automatically.
- An update refuses a checkout with modified, untracked, or ignored files, a
  detached `HEAD`, or no usable `origin`, so replacing it cannot discard
  local work.
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
  no-group-or-other-write checks; one that other users can read is kept with a
  `chmod 600` warning. Unsafe objects are refused, with the remedy, rather
  than silently adopted or chmodded. Publication is per object: partial progress
  is reported on failure and can be reused by a subsequent exact rerun.
  The tracked template and README present configuration, overrides, and
  plugins as trusted Zsh rather than passive data. See
  [`installation.md`](installation.md) for paths, activation, and update
  ownership.
- Loader diagnostics preserve useful plugin stderr instead of hiding every
  source-time error.
- Plugin removal follows the exact-plan, revalidation, and quarantine model
  described under T3.
- The plugin contract requires namespacing and source safety.
- `zdx-plugins` is the single lifecycle owner; no suite maintains a second
  implementation or a delegating bridge.

**Residual risk.** There is no sandbox. Obtaining a checkout from mutable
`main` does not by itself authenticate its source; review, the release
checksum and attestation described in `SECURITY.md`, or other independently
trusted verification happen before local installation. The installer cannot
prove that the selected code is harmless or exclude every same-user filesystem
race. Its fixtures run on Linux and on the macOS CI runner but do not install
into a real Oh My Zsh or shell startup file.
The runtime loader sources plugins at shell load, and structural validation
cannot identify malicious behavior.
The core `zdx-plugins` manager installs, updates, and sources user plugin code
by design. Its staged lifecycle makes the trust decision informed and the
rollback exact, but the decision itself remains the control: the manager
cannot judge whether a reviewed commit is benign. `--yes` trusts every
reviewed change without a prompt, a rewritten history is disclosed rather
than refused, and an unsigned or unverifiable commit is shown, not blocked.
Signature verdicts depend on the user's own Git and GnuPG or SSH signer
configuration. The clone has no wall-clock deadline; prompts are disabled and
stalled transfers abort, as in System's Git updates (T14). Rollback restores
files and the menu function, not every definition a failed source made in the
running shell. A process with the same user ID can still race the final path
operations between revalidation and rename. Removal and staging cleanup run
`rm -rf` on an identity-checked directory, which narrows but cannot close that
same-user race. The catalog therefore describes custom plugins only as loaded
in the current shell; it does not claim an audit.

**Required treatment.** Present plugins as arbitrary code, stage and validate
updates before activation, show origin and commit, require trust, preserve the
previous version on failure, and maintain one owning plugin manager. The
`zdx-plugins` lifecycle implements this treatment; keep its tests current
when the loader rule, the Git boundary, or the transaction changes.

### T7. Local persisted-state tampering or leakage

**Risk.** Telemetry, profiles, backups, or caches are readable by other users,
grow without bound, contain malformed records, or are replaced with links to
unintended targets.

**Current controls.**

- State is generally kept under the user's home.
- Telemetry is opt-in.
- The opt-in Git identity guard persists nothing: it remembers checked
  repository roots only in the shell's memory for the session, runs only in an
  interactive shell, skips subshells, and never prompts.
- Several writers use suite-specific directories.
- Every suite resolves `TMPDIR` before trusting it. A symbolic link on the
  literal path is accepted only as a root-owned system alias, such as macOS
  `/var` and `/tmp`, or above the final component when the current user owns
  it inside a directory that group and other users cannot write; a `TMPDIR`
  that is itself an owned link stays refused. Ownership, sticky-bit, and
  ancestor checks apply to the canonical directory, and private files are
  created only below it, so a later link swap cannot redirect them. A
  root-owned alias is trusted platform configuration; the residual risk is a
  system administrator or compromised root account.
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
- Developer backups and reports resolve and validate their directory on every
  use, refuse `..` segments, protected roots, symlink components, and paths
  outside the project or the user's home. Directories must remain owned mode
  `700`; files must remain owned, singly linked regular files with no group or
  other permission bits, and writers create them mode `600`. Permission
  failures are fatal. Publication uses validated private temporaries with
  parent identity checks before and after publication. Backups and reports use
  atomic no-clobber names. Backups have bounded retention, same-second names
  remain unique, and pruning always preserves the current invocation backup
  despite clock skew or manipulated mtimes, plus the newest configured count
  minus one of the prior backups.
- Developer reports are rendered from a line array and written with
  `print -rl`, never through `echo -e` escape processing. The buffer is reset
  on every save outcome.
- `dev-update-actions` backs up each workflow file it will change through the
  same private, atomically published backup, named from its project-relative
  path (`github%workflows%ci.yml.<timestamp>.bak`). Retention and pruning
  match only that file's exact timestamped names. Its automatic rollback
  republishes the private original snapshot by compare-and-swap and verifies
  the restored digest; a file changed by another process after publication is
  never overwritten, and the invocation backup is named for recovery.
- Developer automatic restore requires the exact invocation-owned backup,
  validates the backup directory, project directory, source, destination, and
  modes and immutable backup fingerprint, fingerprints destination metadata and
  content, compares the staged bytes with the backup immediately before
  publication, and publishes a same-directory replacement atomically. It
  refuses an in-place destination edit or replacement while staging, never
  guesses the newest backup, and never falls back to Git.
- The Developer PyPI cache validates bounded numeric configuration and a
  writable temporary root resolved through trusted aliases only. It accepts a
  safe current-EUID root or a root-owned sticky shared root and refuses other
  foreign owners or unsafe non-sticky shared modes.
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
- File and Py picker captures and private staging roots accept only a
  protected current-EUID directory or a sticky shared root owned by the
  namespace-visible owner of `/` (normally UID 0). Their ancestor chains must
  be owned by that system-root identity or the current EUID and protected
  against unguarded replacement. Capture files are owner-only, bounded, opened
  without following links, identity-checked, and cleaned only while the exact
  expected object remains.
- File output publication uses private same-directory staging, content and
  metadata snapshots, no-clobber publication for absent targets, and exact
  identity replacement for authorized overwrites. Archive extraction uses one
  private source snapshot for both preflight and extraction.
- The File trash persists moved items and their records in
  `${XDG_DATA_HOME:-~/.local/share}/zdx/trash`. `XDG_DATA_HOME` must be
  absolute and normalized; the nearest existing directory resolves through
  trusted aliases only and needs trusted ancestors, and missing directories
  are created mode `700` below a directory the user owns and others cannot
  write. The trash, `files`, and `info` must stay real, owned, mode-`700`
  directories, or every action refuses them without repair. Records are
  freedesktop.org-style `.trashinfo` files published mode `600` from private
  staging with a no-clobber hard link that also reserves the item ID. Readers
  open them without following links, bound them to 16 KiB, and accept only
  exactly three known lines without NUL or control characters, strict `%XX`
  escapes, an absolute normalized path of at most 4,096 bytes outside the
  trash and protected roots, and a real local time; any other record can be
  purged but never restored. Inventories stop at 4,096 entries per
  directory. Read-only actions never create the trash.
- Py project state, environment markers, lockfiles, exact interpreters, and
  removal quarantines are ownership-, mode-, boundary-, and identity-checked.
  Activation sources the reviewed open descriptor. A stable path through the
  actual Zsh PID permits relocatable uv scripts to resolve their location;
  unsupported relocatable descriptor resolution fails before sourcing.
  Postconditions verify the selected environment and interpreter. Failure
  restores standard activation state, while explicitly authorized customized
  scripts can still have effects outside that restoration boundary.

- The VPN cache and report directories resolve and validate on every use, refuse
  `..` segments, the filesystem root, the home directory itself, symlinked
  directories checked on the unresolved path, and any path outside the user's
  home. They are created mode `700` with mode `600` files. Cache entry names are
  an internal allowlist rather than user input, and a pointer to a missing
  profile is displayed for clearing but never acted on.
- VPN cache entries use private same-directory temporary files and no-clobber or
  atomic replacement; a publication failure preserves the prior pointer.
  Reports are staged privately and published under unique no-clobber names, so
  simultaneous same-second runs do not overwrite one another. A failed report
  clears its invocation-local target and removes the staged file. Cache entries
  are capped at 128 bytes, preview panes at 64 KiB, and completed reports at
  1 MiB; external diagnostic sections are bounded before publication.
- `VPN_CONFIG_DIR` must be absolute, must not contain traversal, controls,
  protected roots, or symlink components other than a root-owned system alias
  inside a root-owned directory nobody else can write (macOS
  `/etc -> private/etc`), and an existing directory must be owned by root or
  the current user without group/world write access. On macOS an unset value
  selects `/private/etc/wireguard`, or a Homebrew `etc/wireguard` that already
  holds profiles when the system directory is absent. Profile
  and backup inventories accept only private, singly linked regular files owned
  by root or the current user and bounded to 1 MiB; unsafe entries are neither
  displayed nor acted on.
- VPN staging accepts only a writable temporary root, resolved through trusted
  aliases only, that the current EUID controls, or a root-owned sticky shared
  root. It prefers standard
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
- The Workspace suite persists no state of its own. `ws-clone` writes only
  below an existing `WS_BASE_DIR` that resolves through trusted aliases, is
  owned by the current user, cannot be written by group or other users, and
  has trusted ancestors; existing platform and identity directories must meet
  the same rules and must not be symbolic links, and new ones are created with
  the umask plus `022`. Picker results, the `ws-jump` path snapshot, and fetch
  statuses live in owner-only directories below a validated `TMPDIR` and are
  removed, after an identity check, on every exit path. Read-only discovery
  never follows symbolic links.

**Residual requirements.** Plugin trees written by `zdx-plugins` are staged
in owner-only directories inside the canonical root, published and rolled
back by identity-verified renames under an owner-only lock file, and
recovered after an interruption (T6); the same-user race below applies to
them too. Developer publication assumes a filesystem with meaningful POSIX
ownership and modes, hard links, and atomic same-directory rename; an incompatible filesystem fails
closed, a refused hard link at the first attempt, and a WSL DrvFs drive
without metadata at its mode checks with the remedy. Atomic replacement does
not promise to preserve arbitrary ACLs or extended attributes.
A hostile process with the same EUID still shares the authority to race final
path operations, even though open descriptors, identity checks, no-clobber
publication, expected-object updates, and atomic rename make that window narrow.
A `.venv` directory identity does not freeze every descendant file against a
hostile same-user process. In user namespaces, an overflow UID can represent
multiple unmapped host owners as the same namespace-visible owner of `/`; the
File and Py trust decision therefore also relies on the namespace and mount
configuration not exposing hostile bind mounts under that identity. Focused
tests do not replace live-network or real-host verification.
Trashed items keep their content, names, and original paths on disk, readable
only by the user, until they are purged; trashing is not secure deletion, and
a purge unlinks data without overwriting it. A same-EUID process can edit
records, which strict parsing and restore validation constrain but cannot
prevent. The trash is separate from the desktop trash, so desktop tools
neither show nor empty it.

### T8. Malicious contribution merged into the repository

**Risk.** A contribution introduces exfiltration, injection, unsafe deletion,
or a backdoor.

**Current repository controls.**

- The `Protect main` ruleset has no bypass actors. It requires a pull request,
  dismisses stale reviews when new commits arrive, requires every review
  conversation to be resolved, allows squash merges only, requires signed
  commits with verified signatures, requires linear history, and blocks force
  pushes and deletion of `main`.
- The same ruleset requires strict status checks: `lint` (the Quality Gates
  workflow), `DCO`, `CodeQL`, and `bats (macOS)` must pass on a branch that is
  up to date with `main`. Its code scanning rule also blocks a merge that
  introduces a CodeQL security alert of high or critical severity or an
  error-level alert.
- `CODEOWNERS` requests the maintainer's review.
- CI runs pre-commit and BATS on pull requests.
- The Ubuntu quality gate installs fzf so native input-row visibility and
  inherited-option isolation checks run instead of skipping for a missing tool.
- The macOS workflow runs the full BATS suite on an Apple Silicon runner with
  the BSD userland and without GNU coreutils, so a GNU-only assumption fails
  in CI instead of reaching a Mac. The path-filtered VPN smoke workflow brings
  a private test tunnel up and down through the suite on Ubuntu and macOS
  runners when VPN code changes.
- The installed pre-push hook and the CI Quality Gates workflow execute the
  same `just check` aggregate. It first runs `uv lock --check`, then executes
  syntax, file-stage pre-commit, dependency-audit, and BATS gates through locked
  uv operations. A stale lock fails without being rewritten after the commit.
  Every file hook is explicitly restricted to `pre-commit`; pre-push executes
  only the single complete aggregate regardless of upstream manifest defaults.
- The shared test sandbox clears inherited package-manager control variables;
  System regressions inject hostile values explicitly and mock the fixed
  unattended-upgrade program validator instead of depending on host packages.
- The `DCO` workflow checks every pull-request commit for a `Signed-off-by`
  trailer. Web commit sign-off is required, and squash merges combine the
  pull-request title with the commit messages, so the trailers survive in the
  squash commit on `main`. GitHub signs the squash commit it creates.
- Gitleaks, Zizmor, Actionlint, Markdownlint, syntax checks, and repository
  hygiene hooks are pinned in repository configuration.
- Fork pull-request workflows use read-oriented permissions in tracked workflow
  files, and workflow runs on fork pull requests from external contributors
  wait for maintainer approval (T9).

These rulesets and repository settings live outside Git and must be verified
periodically in GitHub; this document must not treat an unverified remote
setting as permanently guaranteed.

**Residual requirement.** The ruleset requires zero approving reviews because
the project has a single maintainer: the maintainer's own pull requests merge
on passing checks without independent review, and `CODEOWNERS` only requests
review. CodeQL analyzes the repository's Python helpers, not the Zsh runtime.
Focused System interface, resource, maintenance, and state suites cover
stdout/stderr, surface behavior, typed records, post-confirmation
revalidation, update and cleanup plans, telemetry publication, and standalone
sourcing. Those deterministic mocks do not establish host-only macOS behavior,
such as launchd and `softwareupdate`, even when the macOS workflow runs them
on a Mac, nor remote governance. Large changes should be split so review can
reason about behavior changes.

### T9. Workflow token or GitHub Actions compromise

**Risk.** A workflow or third-party action exfiltrates a token, changes
protected content, or publishes an unauthorized release.

**Current controls.**

- The repository's default `GITHUB_TOKEN` is read-only, and GitHub Actions
  cannot approve pull requests.
- Tracked workflows declare minimal workflow-level permissions. Only the
  release job holds `contents: write`, `id-token: write`, and
  `attestations: write`; CodeQL and Scorecard add `security-events: write`
  for their uploads.
- Scheduled dependency and link maintenance workflows are read-only: they
  publish bounded job summaries and cannot create pull requests or issues.
- Checkout steps use `persist-credentials: false`.
- The Actions policy allows only GitHub-owned actions plus an allowlist:
  `astral-sh/setup-uv`, `lycheeverse/lychee-action`, `ossf/scorecard-action`,
  `tim-actions/get-pr-commits`, and `tim-actions/dco`. It requires every
  action to be pinned to a full commit SHA, and tracked workflows carry a
  version comment beside each pin. `dev-update-actions` keeps those pins
  current within their major version and applies a release-age cooldown when
  `gh` is authenticated; see T5.
- Workflow runs on fork pull requests from external contributors wait for
  maintainer approval.
- Dependabot version updates, enabled for GitHub Actions only through
  `.github/dependabot.yml`, propose this repository's action updates weekly in
  one grouped `ci(deps)` pull request that keeps SHA pins and version comments
  and waits seven days after a release. GitHub signs Dependabot's commits, so
  they satisfy the signed-commit rule, and the pull request runs the required
  checks and needs the maintainer's merge. The DCO workflow accepts a pull
  request opened by `dependabot[bot]` without sign-off only when every commit
  is authored by `dependabot[bot]` with a GitHub-verified signature; any other
  commit fails the check.
- Zizmor and Actionlint run in local/CI checks.
- Workflow concurrency and timeouts limit duplicate or stuck execution where
  configured.
- The VPN smoke workflow changes runner networking with sudo only on
  disposable GitHub-hosted runners and holds a read-only token. Its script
  refuses to run unless `ZDX_VPN_SMOKE=1` and `CI=true` are set and
  passwordless sudo is available, refuses an existing profile, installs a
  private test profile that routes only `10.123.45.0/24` to a TEST-NET-1
  endpoint without a DNS line, and always brings the tunnel down and removes
  the profile.

**Residual requirement.** Action semantics require human review. The
default-token, Actions allowlist, SHA-pinning, and fork-approval settings live
outside Git and must be verified periodically. Every GitHub-owned action is
allowed without an allowlist entry. A SHA pin protects against tag movement,
not against a compromised pinned release. SHA-pinned GitHub Actions are outside the Python
dependency report. Dependabot proposes their new releases but does not review
them, so each grouped update needs a human reading of the release notes;
Dependabot alerts do not provide complete coverage for SHA references. The
seven-day cooldown narrows, but does not close, the window for a compromised
release. The CI jobs install current Homebrew and distribution packages, such as `bats-core`,
`wireguard-tools`, and Bash, without version pins; they hold no write token,
but a compromised package could falsify a test or smoke result.

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
- Developer installed-package vulnerability inventories require an importable
  module under `.venv/bin/python -I`; no global, overlay, or ephemeral backend
  can contaminate the observed environment.
- `dev-check-outdated` passes `.venv/bin/python` explicitly to `uv pip list`
  with `UV_SYSTEM_PYTHON=0`.
- The scheduled dependency-report workflow runs `uv lock --upgrade --dry-run`
  and publishes a bounded job summary without modifying the repository.
- Remote pre-commit hooks are pinned to immutable Git object IDs (full SHAs)
  and GitHub Actions to immutable commit SHAs, with version comments in tracked
  configuration. The Developer updater validates frozen hook candidates before
  publication and retains a newer existing pin when upstream default-branch
  tag topology proposes a downgrade.
- The dependency graph and Dependabot alerts are enabled for informational
  findings. Dependabot security updates are disabled, so Python remediation
  stays in the reviewed `uv.lock` workflow, and Dependabot version updates
  cover only GitHub Actions (T9).
- OpenSSF Scorecard reports supply-chain posture.

**Residual requirement.** Python dependency and pre-commit hook upgrades are
reviewed and applied manually. The Dependabot settings live outside Git and
require periodic verification. PEP 517 `build-system.requires` entries and
their transitive dependencies also require explicit review or build
constraints because an ordinary package build does not bind them to
`uv.lock`. Runtime system CLIs are supplied by the user's host and are outside
the lockfile. ZDX must not imply
that presence alone establishes integrity or compatibility. Advisory
databases can also be incomplete or stale even when the local environment
boundary is exact. A full Git object ID prevents tag movement after review,
but does not make the pinned release trustworthy; hook pins and the version
comments used for monotonicity require manual release and advisory review.

### T11. Tampered release artifact

**Risk.** A source archive is substituted or published from an unauthorized
workflow.

**Current controls.**

- `.github/workflows/release.yml` runs when a release tag such as `0.1.0` is
  pushed, or by manual
  dispatch for an existing tag. It checks out that tag and requires a matching
  `## [X.Y.Z]` section in `CHANGELOG.md` for the release notes.
- It builds `zdx-X.Y.Z.tar.gz` with `git archive` under a `zdx-X.Y.Z/`
  prefix, writes `zdx-X.Y.Z.tar.gz.sha256`, and verifies that file before
  publication. The checksum file records the downloadable asset basename
  rather than a runner-local staging path, so consumers can validate both
  downloaded assets in one directory.
- `actions/attest-build-provenance` creates a Sigstore-backed build provenance
  attestation for the tarball, and the workflow publishes the tarball and its
  checksum to the GitHub release.
- Only the release job holds `contents: write`, `id-token: write`, and
  `attestations: write`; the workflow default is `contents: read`.
- Consumers can compare the checksum and verify the attestation with
  `gh attestation verify`, as described in `SECURITY.md`.

**Residual requirement.** The attestation step runs only while the repository
is public. The workflow does not check that the tag points to a commit on
`main`, and no ruleset protects release tags, so anyone with write access can
push a new release tag and trigger a release, or move or delete an existing
tag. Releases are not immutable either: someone with write access can replace
a release's assets, for example through the workflow's re-upload path, or
delete the release. Both choices are deliberate, so a version number is never
reserved forever. Consumers should verify the checksum and the attestation,
which names the commit the tarball was built from. Release procedure changes must preserve artifact, checksum, and
attestation linkage and be smoke-tested without weakening token permissions.

### T12. Opaque binary committed to the repository

**Risk.** A binary cannot be meaningfully reviewed or reproduced.

**Current controls.**

- The README GIF and PNG are generated from `.demo/demo.tape` through the
  reviewable `.demo/record.zsh` and `.demo/session.zsh` scripts. The documented
  `just demo` task uses installed rendering tools (VHS, ttyd, FFmpeg, and
  Chromium or Chrome) and builds a synthetic workspace inside a fresh mode-`700`
  temporary root: a dependency-free uv project locked and synchronized offline,
  and a Git repository with one commit, unfinished work, and a private bare
  origin in the same root. Git there uses the `.invalid` demo identity, fixed
  dates, no system configuration, and a ceiling at the temporary root; uv
  reads no user configuration and downloads no Python.
- The recorded shell uses `zsh -f`, private startup/state directories, and the
  closed environment described in T1. It sources the reviewed checkout, not
  the operator's installed copy or personal Zsh configuration. The tape
  navigates real Git, System, and Developer menu rows and previews. Dispatch
  guards allow exactly three argument-free actions, `git-stash`, `sys-info`,
  and `dev-check-health`, only from the synthetic project directory, deny
  every other action, and restrict master-menu routing to those three suites
  without command arguments. A completion marker requires three successful
  returns, no denied action, and the expected stash before publication.
- The GIF passes one fixed FFmpeg conversion in the same closed environment,
  with stdin disabled and overwrite refused, into a new private output. Both
  final staged media files must be owned, regular, singly linked, and
  nonempty. The demo GIF has a specific 2 MiB limit; the PNG retains the
  1 MiB limit. `ffprobe` must identify the expected GIF or PNG codec. Both
  outputs are validated before either committed file is replaced, and a failed
  renderer, conversion, or pre-publication validation preserves existing
  media. Destinations are checked before staging and before each replacement;
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
that needs regeneration. Apart from its three private actions, the synthetic
workflow does not demonstrate real backend operations or native macOS
terminal behavior. See [`demo.md`](demo.md) for regeneration and review
steps.

Any new generated binary requires a reproducible source, documented generation
command, license review, and a reason it cannot remain outside Git.

### T13. Stale maintenance and security controls

**Risk.** Dependencies, links, platform assumptions, or remote governance
settings become stale while the repository remains unchanged.

**Current controls.**

- Scheduled CI audits Python dependencies daily.
- A read-only scheduled workflow reports available direct and transitive
  lockfile updates for manual review.
- Dependabot proposes GitHub Actions updates weekly, Dependabot alerts report
  vulnerable dependencies, and CodeQL and OpenSSF Scorecard run weekly as well
  as on changes to `main`.
- The scheduled link checker publishes failures to its job summary without
  opening issues.
- The MIT license permits continuity through forks.

**Residual requirement.** Read-only reports do not apply updates. Maintainers
must inspect scheduled summaries and alerts and manually review Python
dependencies, pre-commit hooks, and GitHub Actions. The security assessment,
rulesets and other remote repository settings, supported-platform claims, and
installer integrity metadata also require periodic human review.
GitHub may disable scheduled workflows after prolonged inactivity in a public
repository, so maintainers must also verify that each maintenance schedule
remains enabled.
The core loader registers the lazy `zdir` name and its `wsj` alias only when
an ignored user-local `functions/zdir.zsh` exists. Eager loading
(`ZDX_EAGER_LOAD=1` or `ZDX_LAZY_LOAD=0`) sources every top-level
`functions/*.zsh` file, so any ignored local file there runs as unreviewed
local code. Such files do not ship in the release artifact and are outside
repository review and assurance; release documentation must not present them
as included functionality.

### T14. Unbounded local diagnostic execution

**Risk.** A slow, wedged, or unexpectedly interactive local CLI blocks the
user's long-lived shell, while an oversized persisted log consumes excessive
memory or CPU during inspection.

**Current controls.**

- System diagnostic version, package, and startup probes use bounded execution.
- GNU `timeout` and `gtimeout` use a TERM deadline and KILL grace period, with
  process-group termination for descendants under GNU semantics. BusyBox-style
  timeout is supported, with a Zsh-native direct-child watchdog when no timeout
  binary exists. The core `_zdx_run_with_timeout` owns this order; its watchdog
  keeps its expiry marker below a validated temporary root and refuses an
  unsafe `TMPDIR` before running the command.
- System process, port, and service collectors use bounded local probes.
- `sys-wsl` reads each configuration file only as a regular file of at most
  64 KiB through a three-second bounded read and refuses NUL bytes. Each
  Windows interop query (`wslvar`, `cmd.exe`) runs only when interop is
  available, has a five-second deadline, and `wslpath` has three seconds; a
  failure or timeout leaves the Windows section unavailable.
- Telemetry inspection refuses files above its configured byte limit before
  loading records into shell arrays.
- Developer scan depth, cleanup depth, cleanup unique-target count, backup
  retention, PyPI timeout, retry count, worker count, GitHub Actions cooldown
  (`0`–`90` days), and GitHub query timeout (`1`–`300` seconds) are bounded
  decimal configuration values. `dev-update-actions` reads at most 256
  workflow files of 1 MiB each, runs at most eight tag queries at once, and
  bounds `actionlint` and `zizmor` to 300 seconds each. Cleanup discovery
  streams stop at `limit + 1`, category inventories are capped after streams
  combine, and the unique final plan is independently capped before user
  interaction or mutation. Validation rejects empty, signed, expression-like,
  or out-of-range text before arithmetic evaluation; the ephemeral-runner
  switch accepts only `0` or `1`.
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
- `vpn-mtu-probe` runs every `ping`, `ip`, `route`, `ifconfig`, and `wg` call
  through the core timeout service with a three-second deadline, reads at most
  4 KiB of each, starts no probe that could end after 15 seconds, and sends at
  most 16 probes. Tests cover a hanging `ping`, the time budget, and the probe
  cap.
- The VPN interactive picker runs synchronously in the terminal's foreground
  process group. A pseudo-terminal regression compares its process group with
  the terminal foreground group, preventing `fzf` terminal setup from stopping
  as a background job. Local signal handlers and an `always` block remove its
  private preview and result files.
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
  absent keys defaulting to true. These version gates correspond to
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
- The aggregate sudo timestamp refresher waits for either its stop request,
  noticed within a quarter of a second, or a fixed 30-second interval between
  non-interactive `sudo -n -v` checks while the consecutive privileged entry
  prefix remains active. The invocation owns its handle to the worker's
  private status pipe, and its `always` block requires the worker's bounded
  acknowledgement and exit before closing that pipe on every aggregate exit
  path. As a process substitution in the caller's session it never enters the
  caller's job table and cannot emit asynchronous job-completion UI.
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
- System Git-owned update transport disables terminal credential prompts and
  exports an empty `GIT_ASKPASS`, which also suppresses a configured
  `core.askPass` and `SSH_ASKPASS`. It pulls with an explicit `origin`, so a
  branch whose upstream is another remote or a bare URL cannot fetch code from
  a source the plan never displayed. It applies batch-mode SSH with connect and
  keepalive deadlines unless
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
  preview error or deadline is a visible failure. Aggregate steps report a
  result line with elapsed time and receive `/dev/null` as stdin. Direct APT, Homebrew,
  native-package, and both outer-wrapper and inner-child DNF calls also receive
  closed stdin. Commands with privately captured output announce the readable
  command as `$ <command>` and receive closed stdin; probe capture plus watchdog marker files
  are created under `umask 077`.
- Suite-owned clients with a public zero-means-disabled retry control receive
  `UV_HTTP_RETRIES=0`, `PIP_RETRIES=0`, `CARGO_NET_RETRY=0`, or
  `RUSTUP_MAX_RETRIES=0` as applicable. pipx/pip also receives
  `PIP_NO_INPUT=1`. These controls remove the supported client-level retries
  and pip input prompt; they do not terminate an active mutation or claim
  equivalent semantics for DNF, Pacman, Zypper, or Homebrew internals.
  Cargo can still wait for its package-cache lock because it exposes no
  supported zero-wait control for that separate resource.
- File inventories enforce byte and entry ceilings before selection or broad
  mutation. Archive input trees are bounded and re-inventoried, and GNU TAR
  extraction caps members at 4,096 and declared expansion at 1 GiB before
  publication. Mutating archive and filesystem backends are not killed after
  they begin; failures are propagated and recovery state is reported.
  Large-file and junk-file deletion stop later targets when a removal returns
  an interruption status, and an incomplete deletion retains its exact
  quarantine. An interrupted archive creation preserves an existing output and
  cleans its private staging; an interrupted extraction publishes no
  destination. Temporary staging results must match the expected parent, name
  template, private ownership, type, and regular-file link count before use;
  unexpected paths are neither chmodded nor removed.
- Py environment, managed-runtime, and tool inventories run under deadlines
  through the core timeout service, whose Zsh watchdog covers hosts without
  `timeout`/`gtimeout`, and have explicit byte and record ceilings;
  `.virtualenvs` accepts at most 128 direct children, PyPI responses use a
  private bounded file with network deadlines, created in a subshell so the
  caller's `umask` is never changed and removed on every exit path, and
  recursive removal parses a bounded `/proc/self/mountinfo` snapshot on Linux
  and WSL or walks device numbers on macOS. Inventory stderr
  is discarded, and captured backend output is replayed only on failure with
  the core credential redaction. Environment package plans freeze project
  metadata presence/content and project-root identity, while uv project
  mutations reject external workspaces and bind both project and working
  directory to the reviewed root. Pin writes freeze the root identity, disable
  workspace discovery, and remove uv target-redirection variables. External
  package mutations are intentionally allowed to run to their reported
  transaction result.
- Environment caps the exported-variable inventory at 4,096 names, limits
  `PATH` to 1 MiB and 512 entries, and refuses picker results above 1 MiB
  before shell arrays or UI rendering. `env-dotenv` refuses a dotenv or
  example file above 1 MiB, by its inspected size and again while reading, or
  above 10,000 lines before reporting, and bounds each Git probe at 10
  seconds with closed stdin; a timed-out probe leaves its facts unknown.
- `zdx status` runs every external probe through `_zdx_run_with_timeout`
  with closed stdin and hidden stderr: `git rev-parse`, `git config`, and
  `df` for 3 seconds and `git status` for 5, plus `sysctl` on macOS and `ip`
  only on a Linux host without sysfs. Other facts are Zsh file tests and
  `/proc` or sysfs reads. `git status` runs with `--no-optional-locks`, so the
  probe does not rewrite the index. A timed-out probe leaves its facts `null`
  with a warning; nothing is fetched, written, or elevated, and no suite
  module is loaded.
- The insert widgets bound `git for-each-ref` (5 s), `ss` (5 s), `lsof`
  (10 s), `gh pr list` (15 s, at most 200 records), and the `jq` decode (5 s),
  and offer at most 2,000 candidates; virtual-environment discovery walks at
  most 64 ancestors and 500 `WORKON_HOME` entries. These bounds keep the line
  editor responsive; a widget never waits on a mutation.
- Workspace discovery runs under a 30-second deadline with an 8 MiB output
  ceiling and fails closed above 2,000 repositories. Each `ws-status` probe and
  each SSH alias or Git configuration probe is bounded through the core timeout
  service, and `ws-status --fetch` runs at most `WS_FETCH_JOBS` fetches at a
  time, each bounded to 60 seconds without prompts and with closed stdin;
  every started job is stopped and waited for on every exit path. The
  `ws-clone` transfer itself is deliberately unbounded, because a large
  repository can legitimately take long and Git may ask for credentials in
  the foreground; `Ctrl-C` stops it and its staging directory is removed.
- Package, cache, service, signal, Git, and other mutating transactions are
  not wrapped in `_sys_run_with_timeout`; once started, they run to a reported
  result rather than allowing the caller to return while a descendant may still
  mutate state.

**Residual requirement.** `zdx-plugins` clones into private staging have no
wall-clock deadline: they disable prompts and askpass helpers, use SSH batch
mode with connect and keepalive timeouts unless the user configures SSH, and
abort an HTTP transfer that stays below 1 KiB/s for 60 seconds, like the
System Git updates; their signature probe is bounded. New external operations
must adopt deadlines where they have a meaningful bound. Timeout fallbacks
cannot offer identical descendant control on every host. Probes need the narrowest supported cleanup
semantics, and timeouts must never hide partial mutations. Homebrew 6 can retry through its internal
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
package-cache lock; neither exposes a supported zero switch for that behavior.
Zypper hardcodes up to three soft-media retries with 30-second sleeps and
offers no supported override; `--non-interactive` removes prompts, not that
policy. These external behaviors are not covered by a
universal no-wait/no-retry guarantee, and an active package mutation is not
killed by a general watchdog.

## Residual-risk priorities

The highest-priority implementation gaps are:

1. move the nested Git resource pickers and the Git confirmation dialog to
   private foreground capture with snapshot validation (T2);
2. bring the `zdx-doctor` batch installer to the exact-plan, revalidation,
   and narrow-`sudo` model of the suites (T3, T4);
3. verify Developer live-network and external-tool paths, and host-only macOS
   and WSL behavior that the tests mock, on real hosts.

These are not documentation-only mitigations. They require code and tests.

## Assurance summary

ZDX has meaningful repository and supply-chain controls. The protected `main`
branch accepts changes only through squash-merged pull requests with signed
commits, linear history, resolved conversations, and strict `lint`, `DCO`,
`CodeQL`, and `bats (macOS)` checks, with no bypass actors. Release tags and
releases are deliberately unprotected, so provenance attestation and checksums
carry release integrity. Automation is SHA-pinned and limited to
GitHub-owned and allowlisted actions under a read-only default token. Secret
scanning with push protection, gitleaks, locked contributor dependencies, BATS
isolation, checksummed releases, and provenance attestation complete the
repository controls. Because the governance settings live outside Git, they
are verified periodically rather than assumed.

The System suite demonstrates explicit dispatch, an idempotent
non-`eval` loader, foreground private picker capture, typed resource records,
authentication-aware
post-confirmation revalidation, refusal of unverified installers, advisory
package snapshots with dynamically resolved transactions, exact typed cleanup
scope, atomic publication, owner-only bounded telemetry, bounded and redacted
failure capture, `NO_COLOR` handling, and stream isolation.

The Git suite applies those standards to local and remote repository state:
an exact 21-command surface, parser-before-probe routing, exact-root loading,
credential-redacted context, typed records, fixed previews, direct and nested
completion, immutable mutation plans, OID leases, isolated fetch refs,
create-only branch recovery, post-confirmation revalidation, jq-built JSON
documents without key material, and deny-by-default GitHub verification.

The Developer suite applies the same standards to an unprivileged,
project-scoped suite: a frozen 25-command surface, parser-before-probe
dispatch, effect-aware batch execution, frozen aggregate maintenance scope,
immediate exact cleanup authorization, private fingerprinted update plans,
exact invocation rollback, stable cleanup-root and target identities,
generated and nested-repository exclusions, private atomic state and report
publication, bounded configuration, explicit TFLint initialization, hardened
ephemeral PyPI caches, no `curl | shell` installer path, and SHA-pinned
GitHub Actions updates with a release-age cooldown and validated rollback. Its
update recovery additionally isolates independent backends, validates partial
hook candidates, bounds dependency-span matching, and creates relocatable
staged environments. Live PyPI, github.com, and most external tools are
mocked in tests; relocation tests use real uv offline with a local wheel.
Host-only macOS and WSL behavior is verified through mocks, external tool
transactions cannot be rolled back generically, and portable userspace
identity checks cannot fully exclude a hostile same-EUID race.
`uv python install --upgrade X.Y` is an external global effect outside the
recoverable staged `.venv` swap.

The VPN suite keeps attacker-influenced content away from root: profiles are
edited through `sudoedit`, never by an editor running as root; generated
root-executed hooks accept only validated resolver addresses; and previews
never compile selected data into a shell program. It provides a direct CLI,
an explicit Linux, WSL, and macOS platform contract, and owner-only validated
state. macOS support maps wg-quick profiles to utun
devices from the runtime directory, runs Homebrew's validated wg-quick through
an explicit Bash 4 with pinned system primitives, and documents that root then
runs user-owned Homebrew code. Its BATS coverage is mock-based, and the VPN
smoke workflow brings a real test tunnel up and down on Ubuntu and macOS
runners.

The File suite freezes a five-command surface, uses exact routing and
private foreground picker capture, confines mutations to trusted owned trees,
and provides identity/content-bound publication, quarantined large-file and
junk-file deletion, a private rename-only trash with strictly parsed records,
no-clobber restore, and quarantined purge, bounded tree inventories, and
one-snapshot GNU TAR extraction with exact realized-member checks. It runs on the BSD userland
with GNU tar as `gtar` for extraction; real macOS and DrvFs hosts and the final
same-EUID pathname race remain explicit limits.

The Environment suite extends those controls to session variables, `PATH`,
and project dotenv files. It freezes a three-command surface, withholds all
values from UI records, copies one exact value only to a clipboard backend,
validates picker selections against a frozen snapshot, and changes the
session only through an explicitly reviewed `PATH` deduplication. Its dotenv
check parses bounded files through a no-follow descriptor as data, reports
key names, line numbers, and set-or-empty facts only, and prints hygiene
remedies without running them. It reads no profile files, persists no state,
and registers no automatic directory hook. Clipboard backends, cross-platform
terminal behavior, and Git and DrvFs behavior on real macOS and WSL hosts
remain manual acceptance boundaries.

The Py suite freezes sixteen canonical commands, limits ownership to
project-local environments, sources activation through a fingerprinted
no-follow descriptor, refuses ambiguous Poetry state and ambient pip, binds
package mutations to exact project metadata and interpreters, freezes exact
isolated-tool inventories, and removes environments through mount-aware
quarantine. External package managers are non-transactional, and real index
behavior is a manual acceptance boundary.

The `zdx-plugins` manager treats installs and updates as remote code under one
exclusive lock: it fetches into private staging inside the plugin root,
applies the loader's own entrypoint rule plus link and syntax checks, renews
the trust decision with the redacted origin, the exact commit transition, and
the signature verdict, revalidates after the decision, publishes by verified
renames that keep the previous version until the new one is active, and
rolls back a failed or interrupted activation without announcing a reload.
Removal uses an exact plan, revalidation, and quarantine, and its pickers use
private foreground capture with snapshot validation. The trust decision
remains a human judgment, and the same-user path race remains.

The Workspace suite freezes three commands around the workspace layout. It
validates clone URLs strictly, refuses embedded credentials and local
transports, stages each clone privately, publishes it without replacing
anything, and leaves identity configuration to the Git suite's public
command. Its discovery is bounded, its `ws-jump` preview receives only a row
index, its network access is limited to an explicit clone and an opt-in,
disclosed, bounded fetch, and its JSON omits remote URLs. Real remote hosts,
a Windows SSH configuration, and BSD `mv` on a Mac are manual acceptance
boundaries.

Repository controls do not prove those runtime properties by themselves. The
nested Git pickers and the `zdx-doctor` batch installer retain the gaps listed
under the residual-risk priorities. Because ZDX runs in the user's shell and
sometimes as root, these controls remain required parts of the assurance case.

## Maintenance triggers

Review and update this document whenever:

- a suite adds a privileged, destructive, network, installer, browser, editor,
  process-control, or remote-write action;
- the APT signing-key registry gains, loses, or changes a repository or key
  URL;
- a new executable config, plugin path, backup, cache, or telemetry record is
  persisted;
- a workflow, dependency ecosystem, install path, language runtime, or release
  channel is added or changed;
- a control is removed, replaced, or found ineffective;
- a vulnerability, audit, incident, or community report identifies a new
  threat;
- a ruleset, the Actions policy, or another remote GitHub security setting
  changes or is reviewed;
- supported-platform claims are reviewed.

For each change, record the threat, implemented control, tests, and remaining
risk. Do not describe a planned control as already present.

Last reviewed: 2026-10-05.
