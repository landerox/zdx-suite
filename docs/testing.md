# Testing standard

This document defines the required test strategy for ZDX. Tests enforce the
contracts in [`development.md`](development.md),
[`menu-spec.md`](menu-spec.md), and [`headers.md`](headers.md).

## Tooling boundary

ZDX runtime and installer orchestration are Zsh. The installer has two narrow
exceptions: a Bash 3.2 compatibility launcher and a Python 3.8+ filesystem helper
for validation and no-clobber publication. Installer tests exercise those
boundaries through the real entrypoints.

The test harness uses BATS, whose test files and helpers are Bash. BATS MUST
launch Zsh code under test in an actual Zsh process; passing a test in Bash is
not evidence that Zsh behavior is correct.

The repository gates are:

- `uv lock --check` for read-only lockfile freshness before any runner starts;
- `zsh -n` for tracked `.zsh` syntax;
- BATS for isolated command and loader behavior;
- `pip-audit` for the locked Python contributor dependency set;
- pre-commit for Markdown, YAML, JSON, shell, workflow, secret, and repository
  policy checks;
- `just check` as the required local aggregate.

## Test layout

Tests live under `test/`:

```text
test/
├── test_helper.bash       shared sandbox and process launcher
├── lazy_loading.bats      core lazy/eager loading parity
├── sys_contract.bats      frozen System public-surface parity
├── sys_capabilities.bats  System loader and host decision matrix
├── sys_diagnostics.bats   portable System diagnostics and stream safety
├── sys_interface.bats     System routing, menu, and load-mode behavior
├── sys_maintenance.bats   System update and cleanup safety
├── sys_resources.bats     typed process, port, and service safety behavior
├── sys_state.bats         System persisted-state and compatibility safety
├── git_contract.bats      frozen Git public-surface parity
├── git_interface.bats     Git routing, menu, completion, and loader behavior
├── git_safety.bats        local Git mutation and data-safety boundaries
├── git_remote.bats        disposable local/remote transaction verification
├── ws_contract.bats       frozen Workspace public-surface parity
├── ws_interface.bats      Workspace routing, menu, and load-mode behavior
├── ws_safety.bats         Workspace path, Git, SSH, and terminal regressions
├── vpn_contract.bats      frozen VPN public-surface parity
├── vpn_interface.bats     VPN routing, menu, preview, and load-mode behavior
├── vpn_privilege.bats     VPN privilege, secret, and destructive safety
├── vpn_grammar.bats       VPN parser and completion grammar parity
├── vpn_hardening.bats     VPN filesystem, import, state, and report hardening
├── vpn_regressions.bats   VPN WSL, network, stream, bound, and signal regressions
├── dev_contract.bats      frozen Developer public-surface parity
├── dev_interface.bats     Developer routing, menu, and load-mode behavior
├── dev_maintenance.bats   Developer cleanup, remote-code, and state safety
├── file_contract.bats     frozen File public-surface parity
├── file_safety.bats       File output, path, bulk, and extraction boundaries
├── app_contract.bats      frozen App public-surface parity
├── app_safety.bats        App descriptor, dispatch, and execution boundaries
├── ci_contract.bats       frozen CI public-surface parity
├── ci_safety.bats         CI repository, record, and remote-write boundaries
├── env_contract.bats      frozen Environment public-surface parity
├── env_safety.bats        Environment secret, parser, state, and path boundaries
├── py_contract.bats       frozen Python public-surface parity
├── py_safety.bats         Python environment, package, and tool boundaries
├── net_contract.bats      frozen Network public-surface parity
├── net_safety.bats        Network input, privacy, bound, and transfer controls
├── docker_contract.bats   frozen Docker public-surface parity
├── docker.bats            Docker context, target, Compose, and login safety
├── ai_contract.bats       frozen AI public-surface parity
├── ai.bats                AI cleanup, update, state, and inspection safety
├── hf_contract.bats       frozen Hugging Face public-surface parity
├── hf_safety.bats         Hugging Face backend and cache deletion safety
├── gpu_contract.bats      frozen GPU public-surface parity
├── <suite>.bats           primary suite contract and behavior
├── <suite>_<area>.bats    focused high-risk or complex feature area
└── telemetry.bats         cross-cutting persisted telemetry contract
```

Use a focused file when an area has its own mocks or safety model, such as Git
identity, System ports, plugin management, or the dependency doctor. Do not
create a separate test file merely because a production file exists.

### Current System refactor coverage

| File | Covered boundary |
| --- | --- |
| `sys.bats` | Shared System helpers, exact APT-owner discovery separated from native zero-timeout lock arbitration, Homebrew false-lock and analytics regressions, non-interactive privilege resolution, probe timeout portability and cleanup, closed-stdin bounded/redacted command capture, color policy, advisory menu dependency annotations, and npm safety |
| `sys_contract.bats` | The frozen 34-command fixture, public-surface parity, and Nerd Font family completion parity |
| `sys_capabilities.bats` | Standalone loader, one source-derived module root, lazy capability registry, and mocked Linux, WSL, and Darwin routing |
| `sys_diagnostics.bats` | Portable collectors, stream separation, bounded probes, symbol privacy, and telemetry readers |
| `sys_interface.bats` | Stderr help, invalid status `2`, exact argument forwarding, validated menu rows, local `fzf`, cancellation, foreground private capture for every nested picker with snapshot-checked rows, `--expect` key routing, preserved caller `REPLY`, and lazy/eager parity |
| `sys_update_interface.bats` | Node readiness annotations for external fnm, loaded versus unloaded NVM, missing NVM directories, and shell functions that cannot substitute for fnm; discovery never invokes a version manager |
| `sys_update_interruptions.bats` | AI-step INT/TERM statuses stop later System updates, preserve interruption status with or without fail-fast, and report remaining category counts without real updates or signals |
| `sys_apt_recovery.bats` | Failed or timed-out APT advisory previews, dry-run failure without mutation, preserved authorization and dpkg guards, strict index-refresh failure, and continuation of independent aggregate entries |
| `sys_toolchain_recovery.bats` | Node installation, default-selection, activation, and current-version failure handling; exact direct Homebrew uv upgrades, replaced Cellar targets, post-update version verification, and aggregate deduplication |
| `sys_repomix_recovery.bats` | Active Repomix executable ownership, exact npm prefix dispatch and revalidation, absent/wrapper/custom refusal, Homebrew coexistence, and runtime/version/post-update checks |
| `sys_maintenance.bats` | Maximum and safe-only update plans, exact frozen-entry execution after one aggregate authorization with closed stdin, one gated sudo pre-authentication, an invocation-owned 30-second `sudo -n -v` worker held by a private `zpty` handle, limited to consecutive privileged entries, covered by acknowledged `always` cleanup, and verified in a real interactive PTY without job-completion UI, direct APT single authentication followed by non-interactive privilege, exact UI privilege prefixes, compact default versus complete `--verbose` APT announcements, Linux and mocked macOS package dispatch, platform-specific Homebrew pre-authentication guidance, macOS Homebrew/cask privilege adjacency, Darwin-only false askpass for internal `sudo -A`, mandatory `brew upgrade --no-ask`, absolute Homebrew dispatch with local exports immune to caller `env` functions, and closed stdin for direct APT, Homebrew, native-package, and outer/inner DNF execution, the shared trusted-program resolver with its DNF compatibility alias, exact APT simulation/mutation `env -i` isolation from `APT_CONFIG`, proxies, exported functions, and caller/post-sudo state, trusted absolute `env`/`dpkg` audit programs, dirty-journal/audit refusal before any unattended-owner signal, bounded fixed-`env -i` `apt-config` revalidation immune to caller `APT_CONFIG`/`PATH`, the installed-package/version matrix using trusted `dpkg-query`/`dpkg` with numeric Debian-epoch removal (pre-0.94 denied, 0.94 OR/default-false, and 0.95+ AND/default-true), and initial/revalidated `SigCgt` SIGTERM-bit enforcement, exact DNF4 lock and minimum finite retry options, hermetic bounded DNF version/config probes, the DNF5 5.0/5.1 compatibility path deliberately independent of config dumping and without persistdir (including 5.1 builds that provide config dumping), 5.2/5.3 frozen-persistdir path, and 5.4+ required lock-capability path, privileged sanitized mode-0 and zero-second `zsystem flock -t 0` guarded mode-1 wrappers, exact version-specific `--installroot=/`/persistdir/`skip_system_repo_lock` argv, trusted absolute `env` revalidation, outer and inner fixed `env -i` barriers, non-secret wrapper argv, `/etc/zshenv` trust boundary, and rejection of caller/post-sudo proxy and exported-function state, exact APK `--wait 0` mutations, documented Pacman mirror/download and Cargo package-cache-lock residuals, the visible Zypper retry-policy warning, exact `npm_config_fetch_retries`, `UV_HTTP_RETRIES`, `PIP_RETRIES`/`PIP_NO_INPUT`, `CARGO_NET_RETRY`, and `RUSTUP_MAX_RETRIES` environments, owner deduplication boundaries, mutation-without-timeout, an adjacent automatic-updater yield and single first-entry APT attempt, generic process owners unable to gate the native no-wait attempt, immediate native-lock failure, and default continuation, exact zero-wait/no-retry and PTY/conffile/frontend APT controls, explicit phased-update propagation, pre/post dirty-dpkg refusal, and reboot-required advisories, visible Snap preview failures, prompt-free bounded Git transport, a 120-second Homebrew metadata deadline with the curl-only retry override, Homebrew failure isolation, exact local-ZDX-link classification, partial-failure timing, strict eight-target AI result parsing with nested causes, persistent owner-bound aggregate-lock overlap refusal and reuse, re-entrant refusal that preserves the outer lock descriptor, separate core/optional summary accounting including not-run entries, and shared-resource safety |
| `sys_resources.bats` | Typed procps/BSD `ps`, `lsof`/`ss`, systemd/launchd records, explicit targets, fingerprint/state revalidation around `sudo -v`, final `sudo -n`, signals, and minimal privilege |
| `sys_state.bats` | NUL-safe dotfile and font extraction, hardlink and path attacks, atomic publication, managed-font recovery, named missing dependencies before planning, symlinked-HOME backup with canonical-HOME restore, newline-less sidecar digests, telemetry bounds, and plugin delegation |
| `sys_ports.bats` | Compatibility and regression behavior for public port workflows |
| `sys_doctor.bats` | Dependency-doctor regressions kept with the System suite: `zdx-doctor` help, an installed-versus-missing scan with declined installation, OS and package-manager detection, and Docker-owned timeout and SHA-256 capability metadata |
| `telemetry.bats` | Opt-in recording and public telemetry dashboard/clear regressions |
| `plugins.bats` | Runtime plugin-root and entrypoint boundaries, syntax failures, preserved diagnostics, and registration |
| `plugins_manager.bats` | `zdx-plugins` help, empty listing, validated installation that refuses invalid names, clone failures, missing entrypoints, syntax errors, and missing menu functions, single and all-plugin updates with re-sourcing, and confirmed removal that blocks path traversal |

The APT takeover cases in `sys_maintenance.bats` also reject an unattended
process whose argv selects `--no-minimal-upgrade-steps`, including abbreviations
accepted by `optparse`.

The same suite proves that APT planning never calls the generic busy detector,
that the native lock attempt still runs with or without an eligible unattended
fingerprint, and that `--include-phased-updates` reaches the preview and all
three mutations only when explicit. It verifies the exact
pre-audit/index/full-upgrade/autoremove/post-audit/reboot-report ordering, a
post-audit that still runs when a failed mutation has skipped later phases, a
visible non-zero post-audit failure that suppresses marker inspection, and
advisory-only reboot markers after a clean post-audit. Aggregate tests also
require the single `${HOME:A}/.zdx-update-system.lock` domain under
canonical owner-safe home validation, regardless of runtime/cache directory
availability; hold and reuse the persistent mode-`0600` file without unlink;
reject overlap through `zsystem flock -t 0` before any step; keep the sudo
refresher out of `jobs -p` and job-completion UI; and assert separate
core-package and optional-tool success/failure/not-run totals.

### Current Git refactor coverage

| File | Covered boundary |
| --- | --- |
| `git_contract.bats` | Frozen 39-command fixture; module, function, menu, help, dispatcher, nested-completion, and direct-completion parity |
| `git_interface.bats` | Exact routing and timing, parser-before-probe behavior, stream separation, standalone and repeat sourcing, exact-root loader failure and retry, `NO_COLOR`, row validation, and fzf behavior |
| `git_safety.bats` | Credential redaction, non-TTY refusal, post-review configuration revalidation, literal pathspec isolation, identity-data non-execution, renamed-file history, and exact pull-request OID comparison |
| `git_github_safety.bats` | Deny-by-default GitHub writes, push-remote precedence, local pull-request head identity, and rejection of multiple push URLs |
| `git_pr_merge_recovery.bats` | Complete versus pending GitHub merge requests, final identity/head/state verification, failed post-queries, preserved backend errors, and cancellation without a write |
| `git_remote.bats` | Real disposable repositories and remotes for exact pushes, isolated pull/fetch, tag publication and deletion, and leased branch cleanup |
| `git_sync_recovery.bats`, `git_tag_recovery.bats` | Independent fetch configuration, exact publication destinations, frozen tag OIDs and leases, and rejection of multiple push URLs before and after review |
| `git_local_recovery.bats` | Ordered multi-commit cherry-picks, conflict continuation and full-sequence abort, cancellation, preserved interruptions, and independent ordinary failures |
| `git_identity.bats` | Local and global identity status, validation, and profile application |
| `git_ws.bats` | Legacy Git/workspace compatibility without expanding the documented cross-suite dependency |

GitHub writes use a deny-by-default `gh` recorder, while transport workflows
use disposable local remotes. No focused Git test contacts GitHub or mutates the
repository under test. See [`git-menu.md`](git-menu.md) for the frozen interface
and manual-smoke-test boundary.

### Current Workspace hardening coverage

| File | Covered boundary |
| --- | --- |
| `ws_contract.bats` | The frozen 15-command fixture; function, menu, help, dispatcher, completion, cancellation, timing, and argument-forwarding parity |
| `ws_interface.bats` | Stderr-only entrypoint UI, invalid statuses, per-command help and unknown-option parsers before probes, validated three-field records, canonical fzf behavior, private capture permissions, multi-select output, exact statuses and cleanup, standalone exact-root loading, and lazy/eager parity |
| `ws_safety.bats` | Arbitrary-command and Git-first loader regressions; unsafe workspace roots and creation-picker failures; exact removal, configuration parse failure, and replacement races; clone failures and destination collisions; migration remote/link boundaries; invocation-owned stash preservation; frozen-upstream and synchronization inspection races; stale-branch expected-OID races; credential-redacted remotes; keypair rollback; bounded SSH; constant previews; and top-level plus nested foreground process-group ownership |
| `ws_migration_recovery.bats` | Confirmed absent versus unreadable origins, remote rewrite verification, partial results, preserved interruption statuses, and independent later moves |
| `ws_clone_recovery.bats` | Independent cloning after partial failure, stable workspace identity and permissions, changes between attempts, preserved interruptions, and destination collisions |
| `ws_create_recovery.bats` | Passive SSH alias preflight, exact host/user/key/identity policy, Host pattern and value parsing, quoted paths, and configuration revalidation before publication |
| `git_ws.bats` | Legacy Git/Workspace compatibility without expanding the documented cross-suite dependency |

The Workspace tests redirect `HOME` and `WS_BASE_DIR` into the disposable
sandbox and mock `fzf`, SSH, GitHub CLI, and targeted Git failures. They do not
contact a real GitHub or GitLab host, exercise a real SSH agent, or establish
behavior on a real cross-filesystem mount. The migration implementation refuses
different source and target devices before moving anything. See
[`ws-menu.md`](ws-menu.md) for the implemented controls and residual gaps.

### Current Developer refactor coverage

| File | Covered boundary |
| --- | --- |
| `dev.bats` | Polyglot gate behavior, the no-applicable-gate no-op, one-shot deprecation notices, and delegation to the `py` and `docker` suites |
| `dev_contract.bats` | The frozen 49-command fixture, five-way surface parity, dispatcher coverage, deprecated-alias forwarding, cancellation, timing label, and invalid-argument statuses |
| `dev_interface.bats` | Double sourcing, standalone sourcing without the core runtime, loader failure without a false sentinel, stream separation, `NO_COLOR`, record validation, keyboard-legend accuracy, foreground private picker capture and cleanup, snapshot-validated selection and multi-select dispatch, argument forwarding, and lazy/eager parity |
| `dev_maintenance.bats` | Cleanup plans, dry runs, declined versus unavailable confirmations, protected roots, `.git` exclusion, awkward filenames, partial failures, owner delegation without installer fallback, ephemeral gating, state-directory validation, profile-name validation, PyPI helpers, and atomic export publication |
| `dev_update_safety.bats` | Frozen aggregate applicability, aggregate and exact-cleanup authorization, exact dependency rollback, hostile-option stream isolation, host tool ownership, frozen private hook plans, revision downgrade retention, all-stage environment installation, concurrent live-config preservation, temporary workspace identity, and staged Python replacement |
| `dev_update_dispatch.bats` | Child-specific dependency gates, missing uv with independent Terraform inspection and cleanup, and maintenance help/error routing before probes |
| `dev_update_recovery.bats` | Validated partial hook updates, refusal of unsafe or interrupted candidates and failed environment installation, independent package/Git backends, native HTTP stall settings, dry-run applicability, and retry summaries |
| `dev_update_specifiers.bats` | Dependency-only TOML rewrites with normalized names, repeated and inline declarations, preserved formatting and unrelated content, version ordering, bounded matching, dry-run behavior, and failed queries |
| `dev_python_relocation.bats` | Real offline uv with a local wheel, usable console/activation scripts after publication and staging cleanup, spaced paths, and staged minor/implementation validation |
| `dev_alignment.bats` | Parser-before-probe ordering, project-aware Python and Node runners, batch-eligibility metadata with injected-row refusal, bounded private profiles with identity revalidation and snapshot-checked saves, deprecated-alias forwarding, bounded configuration, pruned project and test discovery, stream separation, symlinked-module loader refusal, direct and nested completion coverage, TOML dependency parsing, and fail-closed project health checks |
| `dev_cleanup_safety.bats` | Symlinked-root refusal, frozen-root revalidation before every removal, replaced-target detection, generated and nested-repository exclusion at the depth boundary, fail-closed discovery depth and target limits, and one bounded unique combined plan |
| `dev_io_safety.bats` | Unique same-second backups and reports, rollback that requires an exact backup, refusal of untrusted date and `mktemp` output as paths, export destinations revalidated after confirmation and at publication, stderr-only backend output, propagated report and coverage failures, project-only test and hook runners, fail-closed tool arguments, and bounded HTTPS-only PyPI metadata handling |
| `dev_security_safety.bats` | Isolated audit backend with stderr UI, declined and non-interactive remediation that starts no backend, explicit `--fix` authorization, and bounded exact-argument Bandit scans with fail-closed discovery |

The Developer suites run without live network access. Most package-manager
and linter calls (`uv`, `npx`, `cargo`, `shellcheck`, and PyPI) are mocked;
the relocation tests additionally use installed uv offline and a generated
local wheel without downloading a runtime or dependency. A real
`dev-update-deps` run against a live project remains a manual smoke test. See
[`dev-menu.md`](dev-menu.md) for the recorded residual gaps.

### Current VPN refactor coverage

| File | Covered boundary |
| --- | --- |
| `vpn.bats` | Shared helpers: resolv.conf preflight, directory writability, name validation, cache pointers, WSL detection, and DNS hook idempotency |
| `vpn_contract.bats` | The frozen 22-command fixture, five-way surface parity, a host-independent command set, dispatcher coverage, deprecated-token forwarding, cancellation, timing label, argument forwarding, and invalid-argument statuses |
| `vpn_interface.bats` | Double sourcing, standalone sourcing without the core runtime, loader failure without a false sentinel, one derived module root, stream separation, `${(V)}` label escaping, `NO_COLOR`, four-field record validation, `fzf` options, foreground process-group ownership in a pseudo-terminal, the index-only preview, pane permissions and cleanup, selection and target revalidation, per-command `--help` and bad-option status, and lazy/eager parity |
| `vpn_privilege.bats` | DNS hook injection refusal, `sudoedit` instead of a root editor, target revalidation after authentication, the restore undo copy, least privilege on read paths, announcement ordering, destructive controls, secret redaction in excerpts and preview panes, state permissions with traversal and symlink refusal, stale pointers, and the platform gate |
| `vpn_grammar.bats` | Exact completion grammar, parser-before-probe behavior, option terminators, operand cardinality, and safety-flag parity |
| `vpn_hardening.bats` | Protected profile-directory boundaries, unsafe file and import-source refusal, lifecycle-hook rejection, semantic DNS validation, picker ambiguity, private atomic cache/report publication, failure cleanup, and no-privilege dry runs |
| `vpn_regressions.bats` | Default and hostile provider URLs, bounded HTTPS-only curl invocation, exact WSL hook ownership, single-IP fallbacks, atomic IPv6 rewrite and backup, fail-closed connect, raw `wg` stream isolation, sudo timestamp failures, state/report bounds, and signal-safe preview cleanup |
| `vpn_control_recovery.bats` | Exact profile paths, authentication revalidation, missing targets, preserved interruptions, partial batch results, and refusal of unknown active state |
| `vpn_probe_recovery.bats` | Interrupted sudo cache checks and authentication, direct WireGuard probes, protected profile existence/metadata/checksum reads, bounded capture status propagation, and ordinary warm-cache probe recovery |
| `vpn_menu_recovery.bats` | Action interruption and ordinary failure, picker cancellation, real private capture cleanup, and no pause or rediscovery after interruption |
| `vpn_state_recovery.bats` | Saved-profile validation interruption through default and last-profile connection, no fallback after interruption, and ordinary stale or missing pointers |

`wg`, `wg-quick`, `sudo`, `sudoedit`, `uname`, `grep`, and the network are all
mocked, so no test touches a real tunnel. The deny-by-default `sudo` recorder
means a test asserting on `$MOCK_SUDO_LOG` proves what the code actually
elevated. A real WSL host verification is not yet recorded; see
[`vpn-menu.md`](vpn-menu.md).

The focused maintenance and state suites run without live network, privilege,
process signals, or shared-host mutations. They exercise dry-run boundaries,
partial failures, archive attacks, artifact mismatch rollback, and persisted
state refusal paths. Mocked Darwin behavior is not a substitute for a real
macOS host run.

### Current File hardening coverage

| File | Covered boundary |
| --- | --- |
| `file.bats` | Entrypoint, direct help, stream behavior, and representative data and mutation workflows |
| `file_discovery_status.bats` | Matching candidates followed by nonmatches, successful empty inventories, preserved scan and interruption statuses, and suppression of partial paths after content-read failures |
| `file_contract.bats` | Frozen ten-command fixture, menu/help/dispatcher parity, and completion declarations |
| `file_safety.bats` | Leading-dash operands, Base64 no-clobber behavior, input/output separation, unsupported extractor refusal, overlapping bulk targets, and current-directory output boundaries |
| `file_recovery.bats` | Real multi-target copy/move/delete/rename/duplicate, permissions and LF/CRLF conversion, GNU TAR round trip, all-target preflight revalidation, interrupted and ordinary partial operations, retained deletion quarantine, and refusal of unexpected staging paths |

Archive tools are mocked or exercised against disposable files, including a
real multi-input GNU TAR round trip. ZIP, 7z, cross-filesystem, and macOS
behavior remain manual boundaries.

### Current App hardening coverage

| File | Covered boundary |
| --- | --- |
| `app.bats` | Loading, help, typed discovery, fixed backend selection, cancellation, stream behavior, and representative dry-run and execution paths |
| `app_contract.bats` | Frozen two-command fixture, module/function/menu/help/dispatcher/completion parity, and lazy registration |
| `app_safety.bats` | Descriptor ownership and identity, task grammar and inventory bounds, package-manager ambiguity, no-eval dispatch, cancellation-output refusal, authorization, and post-review replacement refusal |
| `app_recovery.bats` | Requested-backend discovery independent of unrelated malformed descriptors, strict complete listing and Node lock ownership, stopped interrupted batches, and continued ordinary failures with exact invocation diagnostics |

Task backends and descriptor parsers are mocked or run only against disposable
projects. Tests do not execute an unreviewed project recipe, start containers,
or establish portability across every installed backend version.

### Current CI hardening coverage

| File | Covered boundary |
| --- | --- |
| `ci.bats` | Loading, help, repository-bound reads, fixed endpoint construction, cleanup plans, adapters, and representative failure propagation |
| `ci_contract.bats` | Frozen eight-command fixture and module/function/menu/help/dispatcher/completion/lazy parity |
| `ci_safety.bats` | Pre-capture byte bounds, typed GitHub records, credential redaction, cancellation-output refusal, newest-resource protection, non-interactive authorization, post-confirmation revalidation, and partial remote transactions |
| `ci_recovery.bats` | Exact historical run lookup with repository and schema binding, unavailable/foreign run refusal, stopped interrupted cleanup and dispatch, independent ordinary failures, and deployment deactivation versus deletion outcomes |

GitHub CLI, authentication, API responses, and every remote write are mocked.
Focused tests do not dispatch live workflow code, delete a real GitHub
resource, or eliminate GitHub's final named-branch resolution race.

### Current Environment hardening coverage

| File | Covered boundary |
| --- | --- |
| `env.bats` | Loading, help, passive dotenv behavior, masked listings, PATH inspection, and representative profile workflows |
| `env_contract.bats` | Frozen eight-command fixture and module/function/menu/help/dispatcher/completion/lazy parity |
| `env_safety.bats` | Literal multiline parsing, injection refusal, secret withholding, file and profile permissions, atomic publication, explicit authorization, malformed picker rejection, pre-mutation temporary-path validation, and revalidation |
| `env_recovery.bats` | Rename-induced ctime transitions, exact overwrite and deletion, restoration after failed publication, changed quarantine refusal, and literal dotenv creation/load round trips |

All files and profiles live below the disposable test home. Clipboard programs
are mocked, no automatic directory hook is registered, and real
cross-platform filesystem semantics remain a manual boundary.

### Current Python hardening coverage

| File | Covered boundary |
| --- | --- |
| `py.bats` | Double/failed sourcing, help and stream behavior, menu-record validation, read-only multi-select, cancellation, and foreground result capture |
| `py_contract.bats` | Frozen 16-command fixture, function/module ownership, menu membership, representative dispatch forwarding, compatibility routing, and completion inclusion |
| `py_safety.bats` | Existing-target create refusal, create/remove dry runs, non-interactive confirmation, external-environment refusal, fail-closed rebuild, activation-script revalidation, option-like package refusal, ambient-pip refusal, tool dry-run, and Python-version validation |
| `py_recovery.bats` | Interrupted and ordinary partial tool upgrades, exact retry summaries, real offline relocatable uv activation, stable descriptor resolution in subshells, ordinary descriptor fallback, unsupported-host refusal, and restoration of known activation state after failure |

Package mutations, Poetry, pipx, and PyPI use mocks. Activation recovery also
creates disposable environments with installed uv offline, without runtime or
package downloads. No host interpreter or package installation is changed.
Poetry/TOML ambiguity, PyPI response bounds, inventory overflow, exact
multi-backend upgrade revalidation, nested-mount quarantine removal, and
`.virtualenvs` count bounds still require focused regression cases.

### Current Hugging Face hardening coverage

| File | Covered boundary |
| --- | --- |
| `hf.bats` | Installed-backend policy, structured search data, stderr metadata, invalid grammar, cancellation, private picker cleanup, and snapshot validation |
| `hf_contract.bats` | Frozen five-command fixture and function/menu/help/dispatcher/direct-completion parity |
| `hf_safety.bats` | Exact cache-plan validation, protected target refusal, non-interactive authorization, post-confirmation replacement refusal, and frozen execution arguments |
| `hf_recovery.bats` | Production Python download adapter against an in-memory Hub module, fixed activity messages, classified errors without vendor output, verified files/directories and cache symlinks, retry quoting, non-gated statistics, and download versus picker interruption |

The Python Hub backend and network are mocked. Tests do not contact the Hub,
download model data, use a real token, or delete a live cache.

### Current GPU hardening coverage

| File | Covered boundary |
| --- | --- |
| `gpu.bats` | Explicit simulation, validated NVIDIA records, missing hardware, malformed telemetry, stream separation, cancellation, private picker cleanup, exact-row selection, and interactive-PTY job-control restoration |
| `gpu_contract.bats` | Frozen one-command fixture, module/menu/help/dispatcher/completion parity, probe status preservation, and control-character rejection |
| `gpu_recovery.bats` | Valid metrics retained when process data fails, unavailable versus empty process inventory, interrupted probes, and recovery on a subsequent frame |

`nvidia-smi` is mocked. A one-frame interactive Zsh test uses a pseudo-terminal
when util-linux `script` is available and verifies that `MONITOR` survives
local TTIN/TTOU handling. Tests do not establish behavior on a real driver,
multi-GPU host, or long-running interactive terminal.

### Current Network hardening coverage

| File | Covered boundary |
| --- | --- |
| `net.bats` | Loading, help, stream behavior, representative local and remote diagnostics, dashboard continuation, and throughput dry-run |
| `net_contract.bats` | Frozen six-command fixture and module/function/menu/help/dispatcher/completion/lazy parity |
| `net_safety.bats` | Parser-before-probe behavior, target validation, provider privacy flags, subprocess and record bounds, local-only mode, throughput authorization, cancellation, and picker snapshot checks |
| `net_recovery.bats` | Empty successful DNS types, partial ping output with failure status, interrupted provider and dashboard cascades, bounded-capture interruption precedence, and unavailable throughput timing |

Every network client is mocked. Focused tests send no packets, query no public
provider, transfer no bandwidth, and do not establish real Linux, WSL, BSD, or
macOS command-output compatibility.

### Current local-installer coverage

The local integration contract is documented in
[`installation.md`](installation.md).

| File | Covered boundary |
| --- | --- |
| `installer.bats` | Local launchers, grammar before probes, read-only planning, explicit non-interactive consent, exact source/link idempotency, unrelated-target refusal, private no-clobber configuration, path ownership and aliases, stderr-only progress, and absence of network, Git, sudo, and startup-file mutation |
| `zdx_contract.bats` | Installation of the centralized commented configuration template and its private initial permissions |

Installer fixtures use disposable HOME, Oh My Zsh, source, and configuration trees. They do not clone a remote
repository, modify the operator's startup files, or install packages.
They exercise the real local publication workflow rather than only asserting
its source text. Native macOS acceptance remains separate from Linux fixtures.

### Current master-router hardening coverage

| File | Covered boundary |
| --- | --- |
| `zdx_contract.bats` | Exact adjacent loader, idempotency, evaluator absence, fixed built-in routing, literal plugin arguments, reserved names, help streams, grammar statuses, private foreground picker cleanup, cancellation, forged-row rejection, color disabling, and local/pre-push/CI quality-gate parity |
| `zdx_doctor_rendering.bats` | Isolated fzf version probes, caller-environment preservation, malformed or failed version reporting, interruption propagation, and escaped display/source diagnostics without configuration values |

The focused router tests replace suite entrypoints and FZF with local mocks.
They do not execute a real plugin or prove the safety of plugin code after its
separate trust decision.

### Current Docker hardening coverage

| File | Covered boundary |
| --- | --- |
| `docker.bats` | Strict parser-before-probe behavior; pinned config/context/daemon identity; private picker capture; bounded-output newline boundaries; hostile-stderr suppression; complete resource and recreated-volume identity; exact no-prune cleanup; Compose environment/workspace constraints; action-aware completion; daemon-independent login; and private config-file refusal |
| `docker_contract.bats` | Frozen eight-command fixture and module/function/menu/help/dispatcher/completion/lazy parity, completion-to-parser value grammar, and destructive-action ordering |
| `docker_recovery.bats` | Exact multi-resource cleanup membership, ordinary partial continuation, stopped interrupted removal/revalidation, and a real timeout against an invocation-owned process that ignores TERM |

The Docker client, daemon, contexts, inventories, Compose output, and registry
login are mocked. Tests do not contact a registry, execute image or project
code, remove a live Docker resource, or establish Docker Desktop, rootless,
Podman, remote-context, and cross-platform Compose compatibility.

### Current AI hardening coverage

| File | Covered boundary |
| --- | --- |
| `ai.bats` | Loader, top-level help, strict routing, representative diagnostics, and current-path passive MCP inspection |
| `ai_contract.bats` | Frozen AI command fixture, module/function/menu/help/dispatcher/completion/lazy parity, empty-command refusal, and private snapshot-token completion |
| `ai_probe_recovery.bats` | Official Hermes version flag, typed banners after ancillary timeout, malformed/nonzero/overflow refusal, closed stdin, child-local unbuffered output, and a real probe deadline using a sandboxed mock |
| `ai_update_interruptions.bats` | INT/TERM exit-status propagation without real signals, no later updater execution, complete eight-target interrupted ledgers, System protocol validation, interactive routing, and partial timing based only on successful targets |
| `ai_update_signal_capture.bats` | Real updater-output capture with external mock exit statuses, updater/sink interruption precedence, complete interrupted ledgers, suppression of later updates, ordinary sink failures, and private-output cleanup |
| `ai_update_recovery.bats` | OpenCode zero-status failure classification with terminal decoration, private-output suppression, consistent TSV failure, continued independent updates, vendor-specific matching, genuine already-current outcomes, and specific authentication precedence |
| `ai_safety.bats` | Strict flag profiles; recoverable quarantine and durable-state exclusions; exact protected NVM-default and Node resolution with caller-`PATH` preservation; private Amp/Cursor XDG probe caches; no-clobber backup/restore; dry-run, consent, identity revalidation, private updater-output classification, version-delta separation of updated versus already-current results, ordered one-per-target result records and human ledger entries, cancellation/failure status consistency, explicit planned/not-run totals, and partial-failure controls; Antigravity and non-executing MCP scopes; bounded redacted logs; snapshot-picker selection, forged-row refusal, cancellation, and picker-less fail-closed behavior; documented version-record shapes; wrapper-only doctor probes and report publication; consistent OpenCode XDG roots; option-terminator parsing; and source-time shell integrity |

Assistant CLIs, self-updaters, package managers, MCP configuration, and local
state are mocked or placed below the disposable test home. Tests do not
contact a registry, update a live package, execute or contact an MCP server,
delete real assistant state, purge quarantine, or prove compatibility with
future assistant-specific storage layouts.

## Isolation requirements

Every test MUST run in a disposable sandbox and MUST NOT depend on or mutate the
developer's live environment.

The shared helper establishes a temporary root, redirects `$HOME`, creates a
mock-bin directory at the front of `$PATH`, and exposes `run_zsh` to source the
repository runtime in Zsh.

Tests MUST isolate:

- `$HOME`, `$ZSH_CUSTOM`, workspace roots, caches, backups, and plugin paths;
- Git global and system configuration;
- telemetry and configuration files;
- external commands, network clients, package managers, `sudo`, `fzf`, pagers,
  editors, browsers, service managers, process signals, and archive tools;
- environment flags that can enable auto-update, telemetry, or live loading.

The shared helper clears inherited Homebrew retry, analytics, auto-update, and
askpass controls. A test that exercises those boundaries exports its hostile
values explicitly after setup rather than depending on the developer or runner
environment.

A test may use a real temporary Git repository inside the sandbox. It may not
use the repository under test as a mutation target.

Teardown removes only the generated sandbox. Cleanup code MUST verify that the
target is the expected temporary root before recursive deletion.

## Mocking rules

Mocks model an external boundary, not the implementation under test.

- Record every received argument in an isolated file when command construction
  matters.
- Return realistic stdout, stderr, and exit statuses.
- Make failure modes selectable through explicit environment variables.
- Do not let the mock fall through to a real privileged, destructive, or
  network command.
- Use the real binary only for read-only behavior that is deliberately part of
  the test, such as Git inside a temporary repository.
- Reset mock state for each test.

Filesystem enumeration order is not a test fixture. Inventory tests must
explicitly cover a match followed by a nonmatch, no matches, and collection or
read failures. Assert both returned data and exit status so an incidental last
comparison cannot turn a successful scan into an environment-dependent failure.

An empty executable created with `touch` is not a sufficient mock when the
caller consumes its output or status semantically.

### `fzf` mocks

An `fzf` mock must be able to represent:

- Esc/cancellation: empty output and the expected non-zero `fzf` status;
- selecting a specific action rather than always returning the first row;
- multi-select output in a defined order;
- `--expect` output with the key on the first line;
- nested pickers with different responses selected by prompt or call order.

Returning the first line blindly often selects a section sentinel and gives a
false menu success. Tests for menu dispatch MUST select a real action record.

### Privilege and process mocks

Mock `sudo` as a recorder with an explicit allowlist of expected subcommands.
It MUST fail on an unexpected privileged command. For an authenticated
resource mutation, model `sudo -v` and the final `sudo -n <command>` as
separate calls and change the mocked resource between them to prove that
post-authentication revalidation fails closed.

Mock process discovery and signaling together. PID tests cover process exit,
permission failure, signal escalation, and PID identity change between
selection and mutation.

Fixtures that shadow cleanup tools such as `rm` or `chmod` must restore the
original `PATH` and clear Bash's command hash before sandbox teardown. BATS
removes its own capture files afterwards; a cached executable inside the
deleted sandbox can make the runner fail even when every test reports `ok`.
Check the runner's exit status as well as its TAP results.

## Required test layers

### 1. Syntax and source safety

For every modified Zsh file:

- `zsh -n` succeeds;
- sourcing in a clean Zsh process succeeds;
- sourcing twice succeeds silently;
- sourcing defines functions but opens no menu, prompts for no input, performs
  no network access, and mutates no files;
- a mandatory module failure returns non-zero and does not leave a false loaded
  sentinel.
- module paths resolve below the one root derived from the owning loader, with
  no fallback to an unrelated installation tree;
- lazy stubs use the Zsh function table and explicit filename allowlist, not
  `eval` or a computed shell program.

### 2. Lazy and eager loading parity

Test the suite through both runtime modes:

- the lazy stub loads the correct entrypoint on first call;
- the real function replaces the stub;
- eager loading exposes the same public surface;
- direct standalone suite sourcing does not require another suite to have run;
- repeated invocation does not duplicate functions, paths, or plugin entries.
- `NO_COLOR`, `TERM=dumb`, and non-terminal stderr suppress ANSI color in UI
  logging without changing command status or data output. This does not prove
  interactive support on terminals without cursor control.

### 3. Public-surface parity

Each suite needs a contract test proving that these sets agree:

- direct subcommands;
- non-sentinel top-level menu commands;
- dispatcher arms;
- completion entries;
- direct completion bindings and contextual option restrictions;
- commands documented by `--help`.

The test may use a checked-in fixture or a small parser, but it must fail when a
displayed action has no dispatcher arm or a completion points to no command.

### 4. Pure helper tests

Test record parsers, formatters, capability maps, path-boundary checks, and
command-plan construction without opening `fzf` or executing mutations.

Include empty values, whitespace, newlines, delimiter characters, leading
dashes, Unicode, malformed records, and Zsh array behavior.

### 5. Direct CLI contract

Every public command covers:

- `--help` and valid options;
- unknown flag or subcommand status;
- missing arguments;
- missing dependency;
- unmet context or capability;
- normal success;
- deliberate cancellation;
- underlying command failure and returned status;
- non-interactive behavior.

The direct CLI is tested before the menu adapter.

### 6. Stream separation

Tests MUST prove that data functions emit only their documented records on
stdout and route UI to stderr.

A robust pattern is to capture both streams inside the sandbox:

```bash
@test "example scan keeps stdout machine-readable" {
  local stdout_file="$TEST_TEMP_DIR/stdout"
  local stderr_file="$TEST_TEMP_DIR/stderr"

  run run_zsh \
    "_example_scan >'$stdout_file' 2>'$stderr_file'"

  [ "$status" -eq 0 ]
  [ "$(cat "$stdout_file")" = 'item-1|ready' ]
  [[ "$(cat "$stderr_file")" == *"Scanning"* ]]
}
```

Do not rely only on BATS' combined `$output` when the stream contract is what
the test is intended to prove.

### 7. Interactive adapter

With a deterministic `fzf` mock, verify:

- Esc returns `0` and dispatches nothing;
- selecting a section returns or refreshes without executing it;
- selecting an action dispatches the canonical command once;
- menu and direct invocation forward identical arguments;
- missing optional dependencies are explained;
- active key output from `--expect` maps to the intended non-destructive action;
- narrow-layout options and the plain header are present where material.

`menu_presentation.bats` captures effective options through each real
command-menu wrapper, checks compact layout and cancellation, and exercises
section/action previews with shell-looking description text. It checks the
shared presentation contract rather than freezing each action's wording.
`menu_domain_presentation.bats` covers existing multi-selection scopes, the
compact telemetry selector, and VPN details with and without preview data.
`menu_master_app_presentation.bats` covers route-token filtering, loaded plugin
discovery and completion, and App's private task-index presentation.
`git_menu_capture.bats` verifies top-level snapshot membership, failed-picker
data refusal, exact private-result cleanup, the post-write size limit, and
foreground terminal ownership.

That private-file capture coverage is specific to the top-level Git menu.
Existing nested Git pickers retain their local capture implementations, and
the plugin manager's rendering coverage does not establish equivalent capture
or lifecycle controls.

`menu_rendering.bats` exercises the suite, master, plugin-manager, and
compatibility wrappers' effective fzf arguments and environment: native
foreground/background with a 16-color palette, custom themes, final
`NO_COLOR` precedence, any nonempty plain-mode value, C/POSIX ASCII chrome
(including an unset locale), inherited fzf-default isolation, caller-state and
exit-status preservation, and scoped preview-shell selection. Plain rendering
preserves row data, including Unicode; it does not promise an entirely ASCII
interface. A real fzf filter
also checks that inherited options cannot hide input rows. External plugin
behavior depends on following the documented template.
`vpn_menu_recovery.bats` executes the actual private-pane preview in `/bin/sh`
with control characters, quotes, and shell-looking text in temporary paths,
then verifies cancellation and private-pane cleanup.

For visual acceptance, use an isolated terminal session at 80 columns and a
wide layout. Check descriptions, section details, preview toggling, and Esc
without selecting a mutating action. Do not use the caller's live services or
project tasks as visual fixtures.

The README's isolated demonstration tours ZDX, Developer, System, AI, Git, and
File, with a static Developer poster. It shows filtering, command descriptions,
and cancellation without running backend actions. Its
GIF/static artifacts have their own transcript and reproduction procedure in
[`demo.md`](demo.md). A recording shows the documented workflow; it does not
replace the regression tests or the platform acceptance matrix.

The manual terminal matrix includes native macOS Terminal.app and iTerm2 in
light and dark appearance, UTF-8 and C/POSIX locales, default and plain modes,
and narrow/wide layouts. That native macOS matrix has not been run here;
Linux PTY checks and mocked options do not establish macOS rendering or extend
suite-specific OS command support. Test responsive previews with fzf 0.31 or
newer; no complete compatibility claim is made for older versions or
`TERM=dumb`/cursorless terminals. Open a fresh shell after changing the
installed source so source guards cannot mask the code under test.

### 8. Mutation safety

Every destructive, privileged, or multi-target workflow tests:

- exact plan or target set;
- cancellation before mutation;
- `--dry-run` performs no mutation;
- non-interactive invocation without `--yes` fails closed;
- `--yes` bypasses only confirmation;
- protected roots and traversal attempts are rejected;
- symlink and archive traversal cases are rejected;
- arguments beginning with `-` remain data;
- partial failures are reported and return non-zero;
- cleanup runs after success, failure, timeout, and interrupt;
- `sudo` wraps only the minimal expected command;
- privileged resource paths authenticate with `sudo -v`, revalidate the target,
  then run only the final operation with `sudo -n`;
- an already-started mutating transaction is not wrapped in a watchdog timeout
  that could return while a child continues changing state.

### 9. Network and artifact integrity

Network-facing commands use mocks and fixtures. Tests cover timeout, offline,
HTTP failure, malformed response, authentication failure, rate limiting, and
partial response where applicable.

Remote artifact installer and download tests additionally prove:

- the requested version is pinned;
- checksum or signature verification happens before extraction or execution;
- a mismatch aborts without installing;
- archive paths stay inside the temporary extraction root;
- a post-extraction NUL-delimited inventory validates actual names and object
  types rather than relying only on an escaped textual archive listing;
- control and delimiter characters, links, hardlinks, special files,
  duplicate flattened names, excessive entries, and excessive bytes fail
  before publication;
- a managed-install marker is required before an old font tree can be removed,
  while an unmarked tree is preserved and reported outside the active
  directory;
- font listing rejects an unsafe base and does not traverse symbolic-link
  directories;
- no downloaded script is executed through `sudo`.

Dotfile restore tests additionally cover publication, not only validation:
archive identity and contents are checked again after confirmation; staging
and destination state are checked after confirmation and again after the
mandatory safety backup. Each regular file is copied into a same-directory
temporary, and the final rename is atomic. Failures must leave the safety
archive usable and must not follow a last-moment destination symlink or
hardlink.

Telemetry tests cover numeric duration limits on both accepted input and read
records, record-count and byte retention, and an unterminated final line. A
writer must discard that fragment before appending the next complete JSON
record; a reader must skip it without evaluating or merging it.

### 10. Platform and capability branches

Test each supported adapter independently by mocking capability detection. An
unsupported host branch must return promptly and clearly. Do not let CI's Ubuntu
runner stand in for macOS, BSD, WSL, Termux, or a system without systemd.

When a branch cannot be automated, document a repeatable manual smoke test and
the last environment on which it was run.

The current Darwin tests exercise routing and parser behavior with mocks. They
do not close the real-macOS acceptance item.

## Standard test shape

```bash
#!/usr/bin/env bats

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "example-menu: help returns success" {
  run run_zsh "example-menu --help"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "example dispatcher: rejects an unknown command" {
  run run_zsh "_example_dispatch unknown-action"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown command"* ]]
}
```

Test names follow `<surface>: <behavior>`. Assert status before inspecting
output. A test expected to fail prints enough captured state to diagnose the
boundary without exposing secrets.

## Avoid command-string injection in the harness

The current `run_zsh` helper accepts a command string for convenience. Treat
every interpolated value as test code, not arbitrary data. Put dynamic values
in exported environment variables or fixture files and quote them inside Zsh.

New helpers SHOULD move toward argument-based invocation for simple public
commands so filenames and user values are not embedded into a shell program
string.

## Running tests

| Goal | Command |
| --- | --- |
| Parse all tracked Zsh files | `just lint` |
| Run all BATS tests | `just test` or `bats test/` |
| Run one file | `bats test/sys.bats` |
| Filter by test name | `bats test/ --filter 'dispatcher'` |
| Run all local gates, including dependency audit | `just check` |
| Run pre-commit only | `just pre-commit-run` |

`bats test/` is not documented as parallel unless a specific job option is
passed and the tests have been proven concurrency-safe.

The pre-commit Markdown hook uses `--fix`, so `just check` can modify Markdown.
After a gate changes files, inspect the diff and run `just check` again.

`just pre-commit-install` installs commit, commit-message, and pre-push hooks.
The pre-push hook runs `just check`; its full-suite cost is deliberate because
it is the last local boundary before GitHub receives the change. Every file
hook is explicitly restricted to `pre-commit`, so upstream manifest defaults
cannot make pre-push run it before the complete aggregate.

## Continuous integration

The current `lint` workflow runs on `ubuntu-latest` with the distribution Zsh,
BATS, fzf, and Just packages under a 30-minute job bound sized for the complete
serial suite. After a locked dependency sync, it invokes the same `just check`
aggregate used by the local pre-push hook. That aggregate rejects a stale
lockfile without rewriting it, then runs syntax, pre-commit, Python dependency
audit, and BATS gates. Its `uv run` and `uv export` calls use `--locked`. This
is one Linux environment, not a multi-platform or multi-Zsh-version matrix.

Installing fzf in CI enables the native label-filtering and inherited-option
regressions; without it those tests explicitly skip, which is not a pass.
Pipe-delimited pickers use the literal expression `[|]`; a bare `|` breaks
field filtering on the Ubuntu 24.04 distribution's fzf 0.44.1 even though it
works on newer local releases. Test the distribution binary when changing
the workflow's system dependencies, alongside the current developer binary.
Check both the runner's exit status and its failed/skipped test counts. Push
run titles use the branch name; the commit's DCO trailer remains in Git and
does not become part of the workflow title.

Platform claims therefore need dedicated tests, an expanded CI job, or a
documented manual verification record. Do not state broader matrix coverage
than CI actually provides.

## Regression rule

Every bug fix starts with a test that fails for the reported behavior and then
passes with the fix. If reproducing the defect requires a live service, extract
the decision logic behind a mockable boundary and keep one documented manual
smoke test for the integration.

## Definition of done for tests

- [ ] The production path executes in Zsh.
- [ ] The sandbox contains all writes.
- [ ] External side effects use deterministic mocks.
- [ ] Source and lazy/eager contracts are covered.
- [ ] Public surfaces are checked for parity.
- [ ] stdout and stderr are asserted separately where relevant.
- [ ] Cancellation and non-interactive behavior are covered.
- [ ] Destructive and privileged controls are proven, not only mocked away.
- [ ] Network and platform failure branches are bounded.
- [ ] The regression fails without the intended fix.
- [ ] Focused tests and `just check` pass.
