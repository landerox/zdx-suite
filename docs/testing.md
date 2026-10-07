# Testing standard

This document defines the required test strategy for ZDX. Tests enforce the
contracts in [`development.md`](development.md),
[`menu-spec.md`](menu-spec.md), and [`headers.md`](headers.md).

## Tooling boundary

ZDX runtime and installer orchestration are Zsh. The installer has two narrow
exceptions: a Bash 3.2 compatibility launcher and a Python 3.8+ filesystem helper
for validation and no-clobber publication. Installer tests exercise those
boundaries through the real entrypoints.

The contributor tools (pre-commit, pip-audit, and commitizen) run in the
uv-managed environment that `pyproject.toml` and `uv.lock` define:
`.python-version` pins Python 3.14.8, and `requires-python` is `>=3.14`.

The test harness uses BATS, whose test files and helpers are Bash. BATS MUST
launch Zsh code under test in an actual Zsh process; passing a test in Bash is
not evidence that Zsh behavior is correct.

The suite requires Bash 4.1 or newer. Older Bash does not apply `set -e` to a
failing `[[ ]]` or `(( ))` that is not a test's last command, so most
assertions would pass without checking anything. `test/setup_suite.bash` stops
the run and `test/test_helper.bash` fails each test with a clear message on an
older Bash. On macOS, `/bin/bash` is 3.2: install Homebrew `bash` and put it
first on `PATH` before running BATS.

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
├── setup_suite.bash       suite-wide Bash floor and per-test timeout default
├── test_helper.bash       shared sandbox, portable assertions, and launcher
├── vpn_test_helper.bash   VPN kernel pin and macOS Homebrew fixtures
├── sandbox_isolation.bats sandbox isolation, canonical roots, and portable helpers
├── lazy_loading.bats      core lazy/eager loading parity and conditional compatibility names
├── output.bats            core command-output services
├── platform_paths.bats    temporary roots and operation bases behind aliases
├── platform_tools.bats    timeout fallback and BSD chmod argument order
├── scaffold.bats          surface checker and command generator on a repository copy
├── file_platform.bats     File mount, tool, and archive branches per platform
├── env_platform.bats      Environment clipboard backends and PATH spellings
├── py_platform.bats       Python timeout, mount, and interpreter branches
├── sys_contract.bats      frozen System public-surface parity
├── sys_capabilities.bats  System loader and host decision matrix
├── sys_diagnostics.bats   portable System diagnostics and stream safety
├── sys_wsl.bats           System WSL configuration review and its JSON document
├── sys_interface.bats     System routing, menu, and load-mode behavior
├── sys_maintenance.bats   System update and cleanup safety
├── sys_apt_keys.bats      APT signing-key renewal and guidance
├── sys_resources.bats     typed process, port, and service safety behavior
├── sys_state.bats         System telemetry state safety
├── git_contract.bats      frozen Git public-surface parity
├── git_interface.bats     Git routing, menu, completion, and loader behavior
├── git_safety.bats        local Git mutation and data-safety boundaries
├── git_local_changes.bats unstage, stash, amend, and discard-all workflows
├── git_branches.bats      branch switching and lost-commit recovery
├── git_identity_check.bats workspace identity check and the opt-in guard
├── git_json.bats          Git --json documents
├── git_platform.bats      Git on case-insensitive, WSL, and macOS hosts
├── git_remote.bats        disposable local/remote transaction verification
├── vpn_contract.bats      frozen VPN public-surface parity
├── vpn_interface.bats     VPN routing, menu, preview, and load-mode behavior
├── vpn_privilege.bats     VPN privilege, secret, and destructive safety
├── vpn_grammar.bats       VPN parser and completion grammar parity
├── vpn_hardening.bats     VPN filesystem, import, state, and report hardening
├── vpn_regressions.bats   VPN WSL, network, stream, bound, and signal regressions
├── vpn_darwin.bats        VPN macOS directory, utun mapping, tools, and collectors
├── vpn_wsl.bats           VPN WSL networking gate, detection, and resolver pin
├── vpn_mtu.bats           VPN path MTU probe, bounds, advice, and JSON
├── dev_contract.bats      frozen Developer public-surface parity
├── dev_interface.bats     Developer routing, menu, and load-mode behavior
├── dev_maintenance.bats   Developer cleanup, remote-code, and state safety
├── dev_output.bats        Developer step results, evidence, and summaries
├── dev_platform.bats      Developer macOS and WSL branches through mocks
├── dev_update_actions.bats Developer GitHub Actions plans, cooldown, and rollback
├── file_contract.bats     frozen File public-surface parity
├── file_safety.bats       File output, path, and extraction boundaries
├── env_contract.bats      frozen Environment public-surface parity
├── env_safety.bats        Environment secret, picker, and PATH boundaries
├── env_dotenv.bats        Environment dotenv parser, hygiene, and JSON report
├── py_contract.bats       frozen Python public-surface parity
├── py_safety.bats         Python environment, package, and tool boundaries
├── zdx_status.bats        zdx status routing, probes, text, and JSON schema
├── zdx_widgets.bats       ZLE insert widgets, quoting, and key binding rules
├── ws_contract.bats       frozen Workspace public-surface parity
├── ws_jump.bats           Workspace discovery, navigation, and preview
├── ws_status.bats         Workspace status, JSON, and bounded fetch
├── ws_clone.bats          Workspace URL validation, staged clone, and identity
├── <suite>.bats           primary suite contract and behavior
├── <suite>_<area>.bats    focused high-risk or complex feature area
└── telemetry.bats         cross-cutting persisted telemetry contract
```

Use a focused file when an area has its own mocks or safety model, such as Git
identity, System ports, plugin management, or the dependency doctor. Do not
create a separate test file merely because a production file exists.

### Core output coverage

| File | Covered boundary |
| --- | --- |
| `output.bats` | Service availability before any suite in lazy and eager loading; the single duration format with rounding edges, invalid input, and a decimal-comma locale; counted nouns; the twelve-token outcome vocabulary and classes; top-level, suppressed, and verbose-demoted headings; key-value lines with one key width, an added colon, and a theme-safe bold key; report sections that follow the step depth and reuse a heading's blank line with `--first`; step summaries omitted inside a step unless verbose; exact step banners and result lines, including a first banner that reuses a heading's blank line; display-width table alignment with all-or-nothing validation; step-slot reconciliation with exit statuses, subshell reports, and caller `REPLY`; captured execution that hides success output, replays a bounded, color-stripped, credential-redacted tail on failure, keeps the caller umask, closes stdin, never runs on invalid arguments or an unsafe `TMPDIR`, streams under `ZDX_VERBOSE=1`, and never shows `replay 0` output; the in-shell capture that keeps shell changes; the outermost-only timing footer with per-level telemetry; and the core `_tk_spinner` helper, which returns its command's output |

### Platform portability coverage

These files reproduce macOS and WSL path and tool differences through mocks
and fixtures, so they pass on any host; the macOS workflow also runs them on an
Apple Silicon runner. They do not replace acceptance of host-only behavior.

| File | Covered boundary |
| --- | --- |
| `platform_paths.bats` | Every suite's temporary-root check (core capture, master menu, Environment, File, Python, Git, System, Developer pickers, update workspaces, and PyPI cache, Workspace, and VPN staging) with `TMPDIR` behind an owned alias, with a trailing slash, behind a simulated root-owned final alias such as macOS `/tmp`, and behind a real root-owned system alias when the host has one (`/var/lock`); each yields the canonical root. A `TMPDIR` that is itself an owned link, an owned alias inside a group-writable directory, a group-writable or foreign-owned canonical root, and a non-normalized path stay refused. Real pickers, VPN preview staging, and captured execution work below the canonical root and leave nothing behind. Every suite's private resolver copy and the master menu's standalone fallback must match the core `_zdx_resolve_trusted_dir` exactly. File and Python operation bases reached through an owned alias or a simulated root-owned alias such as macOS `/tmp` resolve to the canonical project for junk cleanup, relative and absolute archive operands, `venv-list`, and `venv-info --path`, while a working directory that is itself an owned link, or an alias inside a group-writable directory, stays refused |
| `file_platform.bats` | Mount boundaries from one `/proc/self/mountinfo` snapshot per pass on a mocked Linux kernel, including octal-escaped bind mounts, a malformed table, and the snapshot count; device-number comparison on a mocked Darwin kernel with an injected device change and the real `/dev`; refusal on other kernels; the `mv` adapter for GNU, uutils, and BSD `mv`, and deletion through a BSD `mv` shim; extraction through `gtar` behind a bsdtar `tar` (GNU tar required); bsdtar creation with `COPYFILE_DISABLE=1`, `--no-mac-metadata`, and `--no-xattrs`, and GNU tar preferred as `gtar`; 7z creation through `7zz`; digests of backslash names and FIFOs; case-colliding names refused only on Darwin and uppercase TAR extensions accepted; the WSL drive hint and WSL detection from fixtures; junk discovery through the Zsh walker behind a BSD `find` shim; and the menu's `○ Extract TAR Archive (missing: GNU tar)` row |
| `env_platform.bats` | The exact bytes mocked clipboard programs receive: UTF-16LE with a byte-order mark for `clip.exe`, the WSL fallback to the Windows `clip.exe` outside `PATH`, invalid UTF-8 refused before any backend, and `pbcopy` under a UTF-8 locale; WSL detection from fixtures; and PATH entries that differ by a trailing slash (deduplicated) or only by letter case (reported and kept) |
| `py_platform.bats` | Inventories through the core watchdog without `timeout` or `gtimeout`, the standalone refusal and `gtimeout` fallback, removal on a mocked Darwin kernel without a mount table or `findmnt`, real device changes at `/dev` and below `/sys/fs` or `/System/Volumes`, escaped and malformed Linux mount tables, refusal on other kernels, picker setup failures returned as `125` and reported as errors, the early relocatable refusal without `/proc/<pid>/fd`, `package-search` on a Python without `tomllib`, the python.org framework interpreter matrix, the WSL hint and detection, and the menu's unavailable rows in a standalone source |
| `platform_tools.bats` | The core `_zdx_run_with_timeout` argument validation, `timeout` then `gtimeout` preference with a two-second KILL grace, the Zsh watchdog's `124` status, status pass-through, descendant termination, private marker below the canonical root, and refusal of an unsafe `TMPDIR` before running anything; System delegation to the core with its standalone fallback; and private-mode publication through VPN, Python, File, and Developer paths under a BSD-style `chmod` shim, plus a source scan for `chmod MODE --` ordering; the plugin entrypoint and every suite helper keep the external `stat` command |

### System coverage

| File | Covered boundary |
| --- | --- |
| `sys.bats` | Shared System helpers, exact APT-owner discovery separated from native zero-timeout lock arbitration, Homebrew false-lock, analytics, and environment-hint regressions, non-interactive privilege resolution, probe timeout portability and cleanup under `NO_CLOBBER`, bounded probes that merge stderr within the same bound, the active-tool resolver's usable, absent, world-writable, WSL Windows, and macOS placeholder results, closed-stdin bounded/redacted command capture announced as `$ <command>` that keeps the caller's umask, the core duration format with its standalone fallback, color policy, and advisory menu dependency annotations |
| `sys_contract.bats` | The frozen 25-command fixture with update commands mapped to their `sys-update*.zsh` step and orchestrator modules, public-surface parity, and typed `port:` target completion without `--kill-pid` or a `sys-processes --kill` form |
| `sys_capabilities.bats` | Standalone loader, one source-derived module root, lazy capability registry, and mocked Linux, WSL, and Darwin routing; WSL interop through `WSLInterop` or `WSLInterop-late`; `cmd.exe` on the system drive without the Windows `PATH`, never through a symbolic link |
| `sys_diagnostics.bats` | Portable collectors, Homebrew counts through GNU timeout, stream separation, bounded probes, plugin-count startup hints, and telemetry readers; launchd health limited to non-running jobs with a positive exit, without `com.apple.*` jobs by default, and with signal exits as advisory; the macOS Data volume, the not-applicable OOM log, and `kern.memorystatus_level` memory with its `vm_stat` fallback; `sys-info` tool rows that never run Command Line Tools placeholders or WSL Windows programs; the unchanged `sys-info` text layout and its typed `zdx.sys-info.v1` document, with extra arguments refused and a missing `jq` reported before any probe; counted nouns in health findings |
| `sys_wsl.bats` | `sys-wsl` over fixture `/etc`, `/proc`, and `/sys` trees with mocked `cmd.exe`, `wslvar`, `wslpath`, and `uname`: the not-applicable result on native Linux and macOS in text and JSON, every finding on stderr with empty stdout, a clean configuration, the exact `zdx.sys-wsl.v1` document, hostile `$(…)`, backtick, and `${…}` values that never execute, withheld credential-bearing values, INI line numbers and malformed-line reasons with CRLF and a byte-order mark, oversized and UTF-16 files refused, disabled interop without a Windows call, a slow `cmd.exe` bounded by the interop deadline, `wslvar` preferred, conversion below a relocated automount root, the `vpn-mtu-probe` hint only when the command is known, the missing-`jq` failure, the `(unavailable: WSL)` menu mark, and `--json` completion |
| `sys_interface.bats` | Stderr help, invalid status `2`, exact argument forwarding, validated menu rows, local `fzf`, cancellation, foreground private capture for every nested picker with snapshot-checked rows, `--expect` key routing, an action key on an empty filter treated as cancellation, preserved caller `REPLY`, and lazy/eager parity |
| `sys_update_interface.bats` | Node readiness annotations for external fnm, loaded versus unloaded NVM, missing NVM directories, and shell functions that cannot substitute for fnm; discovery never invokes a version manager |
| `sys_update_interruptions.bats` | Node.js-step INT/TERM statuses stop later System updates, preserve interruption status with or without fail-fast, and report remaining category counts without real updates or signals |
| `sys_apt_keys.bats` | APT signing-key renewal with mocked APT, curl, gpg, sudo, and install over a sandboxed APT layout: a reported `NO_PUBKEY` key of a known repository renewed from its exact HTTPS key URL with bounded HTTPS-only curl options, dearmored for a `.gpg` keyring, installed through the exact `sudo -n <install> -m 0644 -o 0 -g 0 <staged> <keyring>` argv, and kept after one verifying retry; an expired keyring renewed before the refresh and verified for every suite that shares it; a download without the requested key ID and a failed download refused before installation; the previous keyring restored when APT still rejects the repository; plain guidance with no download for an unknown repository, an inline deb822 key, and global trust; a symlinked or group-writable keyring never replaced; `SYS_APT_KEY_RENEWAL=0` and an invalid value; a dry run that downloads and installs nothing; the plan disclosure and the `updated` step summary in `update-system`; exact registry host and path matching; and APT 3's sqv `Missing key` report |
| `sys_apt_recovery.bats` | Failed or timed-out APT advisory previews, dry-run failure without mutation, preserved authorization and dpkg guards, strict index-refresh failure, a repository-by-repository diagnosis of a failed refresh with credential-free sources and pending candidates, transaction counts that decide `updated` versus `current`, and continuation of independent aggregate entries |
| `sys_toolchain_recovery.bats` | Node installation, default-selection, activation, and current-version failure handling with before/after active versions and captured nvm output; exact direct Homebrew uv upgrades, replaced Cellar targets, version comparisons, and aggregate deduplication |
| `sys_maintenance.bats` | Maximum and safe-only update plans, one applicability check for each of the 14 plan entries, exact frozen-entry execution after one aggregate authorization with closed stdin, one gated sudo pre-authentication, an invocation-owned 30-second `sudo -n -v` refresher that runs as a process substitution sharing the caller's session and controlling terminal, limited to consecutive privileged entries, warning and stopping when its first refresh fails, never retrying a failed refresh or refreshing for an exited caller, covered by acknowledged `always` cleanup, and verified in a real interactive PTY without job-completion UI, direct APT single authentication followed by non-interactive privilege, exact UI privilege prefixes, compact default versus complete `--verbose` APT announcements, Linux and mocked macOS package dispatch, the macOS plan, `softwareupdate` list parsing in both layouts with a privilege-free `current` result, restart and macOS updates left uninstalled as a `skipped` result with a naming warning and a successful aggregate, exact `--install --no-scan` labels, and failures for an unrecognized list, an unsafe label, or a failed installation, platform-specific Homebrew pre-authentication guidance, macOS Homebrew/cask privilege adjacency, Darwin-only false askpass for internal `sudo -A` with its private failing fallback and refusal without either, active-path gcloud ownership for both cask names, `share/google-cloud-sdk`, the APT package, and an earlier self-managed SDK, Windows executables excluded from WSL tool steps, world-writable tool executables blocked, the shared not-applicable contract of `update-apt`, `update-snap`, `clean-journal`, and `clean-snaps`, `pip3` and `python3 -m pip` cache probes, platform-specific cleanup wording, mandatory `brew upgrade --no-ask`, absolute Homebrew dispatch with local exports immune to caller `env` functions, `HOMEBREW_NO_ENV_HINTS=1` on every `update-brew` phase, and closed stdin for direct APT, Homebrew, native-package, and outer/inner DNF execution, the shared trusted-program resolver with its DNF compatibility alias, exact APT simulation/mutation `env -i` isolation from `APT_CONFIG`, proxies, exported functions, and caller/post-sudo state, trusted absolute `env`/`dpkg` audit programs, dirty-journal/audit refusal before any unattended-owner signal, bounded fixed-`env -i` `apt-config` revalidation immune to caller `APT_CONFIG`/`PATH`, the installed-package/version matrix using trusted `dpkg-query`/`dpkg` with numeric Debian-epoch removal (pre-0.94 denied, 0.94 OR/default-false, and 0.95+ AND/default-true), and initial/revalidated `SigCgt` SIGTERM-bit enforcement, exact DNF4 lock and minimum finite retry options, hermetic bounded DNF version/config probes, the DNF5 5.0/5.1 compatibility path deliberately independent of config dumping and without persistdir (including 5.1 builds that provide config dumping), 5.2/5.3 frozen-persistdir path, and 5.4+ required lock-capability path, privileged sanitized mode-0 and zero-second `zsystem flock -t 0` guarded mode-1 wrappers, exact version-specific `--installroot=/`/persistdir/`skip_system_repo_lock` argv, trusted absolute `env` revalidation, outer and inner fixed `env -i` barriers, non-secret wrapper argv, `/etc/zshenv` trust boundary, and rejection of caller/post-sudo proxy and exported-function state, exact APK `--wait 0` mutations, documented Pacman mirror/download and Cargo package-cache-lock residuals, the visible Zypper retry-policy warning, exact `UV_HTTP_RETRIES`, `PIP_RETRIES`/`PIP_NO_INPUT`, and `RUSTUP_MAX_RETRIES` environments, owner deduplication boundaries, mutation-without-timeout, an adjacent automatic-updater yield and single first-entry APT attempt, generic process owners unable to gate the native no-wait attempt, immediate native-lock failure, and default continuation, exact zero-wait/no-retry and PTY/conffile/frontend APT controls, explicit phased-update propagation, pre/post dirty-dpkg refusal, and reboot-required advisories, visible Snap preview failures, prompt-free bounded Git transport, a 120-second Homebrew metadata deadline with the curl-only retry override, Homebrew failure isolation, exact local-ZDX-link classification, partial-failure timing, persistent owner-bound aggregate-lock overlap refusal and reuse, re-entrant refusal that preserves the outer lock descriptor, separate core/optional summary accounting including not-run entries, step result lines and summary tables, version, inventory, and HEAD evidence for `updated` versus `current` results, readable captured Git commands, shared-resource safety, the `clean-system` mode grammar, cleanup probe omissions, propagated cache-removal failures, stdout-clean Snap removal limited to the `Notes` column, suffix-only journal sizes, active-executable fzf ownership, explicit-origin Git pulls, and an empty `GIT_ASKPASS` |
| `sys_resources.bats` | Typed procps/BSD `ps`, `lsof`/`ss`, systemd/launchd records, BSD `ps -axro` sorted by CPU, launchd `--stop` as `launchctl kill SIGTERM` in the job's `gui` or `user` domain, the Linux `ss` preference, escaped systemd identifiers, explicit targets, post-confirmation port re-resolution against new or hidden owners, fingerprint/state revalidation around `sudo -v`, final `sudo -n`, signals, minimal privilege, and rejection of a `sys-processes --kill` spelling with status `2` |
| `sys_state.bats` | Telemetry writer state: owner-only directory and file, oversized durations omitted without arithmetic errors, a discarded partial final line, bounded record retention and byte limit, symbolic-link log refusal by the writer and clear, symlinked-parent refusal across writer, reader, and clear, oversized-log refusal, clear dry runs that preserve content and identity, non-interactive clear refusal without `--yes`, and decimal-comma locales |
| `sys_ports.bats` | Help, canonical and empty `--list` TSV, invalid and `pid:` targets rejected with status `2` in favor of `sys-processes --terminate`, an unknown `--kill-pid` option, a missing listener, and one consented `SIGTERM` or explicit `--force` `SIGKILL` without automatic escalation |
| `sys_doctor.bats` | Dependency-doctor regressions kept with the System suite: `zdx-doctor` help, an installed-versus-missing scan with declined installation, OS and package-manager detection, and timeout and SHA-256 capability metadata that names the suites using them |
| `telemetry.bats` | Opt-in recording and public telemetry dashboard/clear regressions |
| `plugins.bats` | Runtime plugin-root and entrypoint boundaries, including a root reached through an owned HOME alias that loads from its canonical path, refused group-writable roots and ancestors, and refused aliases inside writable directories; syntax failures, preserved diagnostics, and registration |
| `plugins_manager.bats` | `zdx-plugins` help on stderr, grammar errors returned as `2` before any probe, refused names and option-like URLs, origin redaction of credentials, queries, and fragments, master-registered completion of actions, installed names, and unused flags, a read-only empty listing and a redacted stderr-only listing, a plugin root created mode `700` under a permissive umask that the loader then accepts, removal dry runs, non-interactive refusal, `--yes` removal that unregisters the menu, decline, post-confirmation revalidation, and refused traversal and linked directories, the menu and uninstall picker's private capture with forged-row rejection, cancellation, and an unsafe `TMPDIR`, idempotent standalone sourcing, and lifecycle refusal without the core runtime |
| `plugins_lifecycle.bats` | Staged installs and updates against local bare Git origins: the private staging directory inside the root, the review (origin, commits, full ID, count, fast-forward or rewritten history, signature, incoming subjects, arbitrary-code warning), non-interactive refusal before any fetch, dry runs, declined decisions, missing, syntax-invalid, and symbolic-link trees published nowhere, bad signatures refused, source failures and missing menu functions rolled back to the exact previous commit with the menu function restored, the conventional sentinel cleared on reload, refusal of local or ignored files, current plugins, non-Git plugins skipped, the all-plugin aggregate with its summary, verdict, and retry hints, a concurrent lock holder refused, nested runs refused, interrupted fetches and activations cleaned or rolled back, and recovery of interrupted staging that never deletes a previous version |

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

### Git coverage

| File | Covered boundary |
| --- | --- |
| `git_contract.bats` | Frozen 21-command fixture; module, function, menu, help, dispatcher, nested-completion, and direct-completion parity, including a `git-push` grammar without a tag mode, the stash action grammars, `git-discard --include-untracked` only after `--all`, the amend and unstage flags, the exclusive `git-switch` change modes, and `--json` only on read-only commands |
| `git_interface.bats` | Exact routing and timing, all direct help streams, outside-repository annotations, standalone and double sourcing, exact-root loader failure and retry, `NO_COLOR`, row validation, fzf behavior, the Local Changes and Branches sections and help groups, the pull-mode dialog, and rejection of a `git-push --tags` mode |
| `git_branches.bats` | `git-switch` to local, previous, and remote-only branches with exact tracking-branch creation; refusals for unknown, ambiguous, invalid, differing, and case-colliding names, operations in progress, other worktrees, and untracked or ignored obstacles; dirty-tree plans with the carry and stash choices, dry runs, declined and non-terminal confirmations, and revalidation after confirmation; constant picker previews; and `git-recover`, which only creates a new branch, refuses taken and conflicting names, revalidates after confirmation, and adds dropped but never live stashes with `--deep` |
| `git_identity_check.bats` | `git-identity-check` matches and mismatches without key material or configuration changes, keyless profiles, `IdentityFile` and `ssh.exe` key selection, not-applicable repositories, and grammar errors; the opt-in identity guard off by default and outside interactive shells, warning once per repository, silent outside the layout and in subshells, and loading the suite in a lazy shell |
| `git_json.bats` | Exact `zdx.git-status.v1` and `zdx.git-identity-check.v1` documents validated with `jq -e`, null and boolean typing, one document on stdout through the nested route, and missing-`jq`, invalid-argument, and no-repository failures with empty stdout |
| `git_safety.bats` | Credential redaction, non-TTY refusal on the local-change and shared confirmation paths, literal pathspec isolation, identity-data non-execution, exact PR OID comparison, SSH host-alias PR remotes, detached checkout of the reviewed PR head, subdirectory path selections for discard, unstage, and stash, nested-repository stashes with stdout diffs, staged-rename unstaging, untracked discard obstacles, and branch-bound undo plans |
| `git_local_changes.bats` | Discard of every change with and without untracked files, kept ignored files and nested repositories, unstage batches and staged versions missing from the working tree, subject-only and editor amends with kept trailers, published-commit disclosure, stash save, apply, pop, drop, and branch, the stash manager and action dialog, constant read-only previews, dry runs, declined and unavailable confirmations, and refusal after post-confirmation changes |
| `git_github_safety.bats` | Deny-by-default GitHub writes, push-remote precedence, local pull-request head identity, and rejection of multiple push URLs |
| `git_remote.bats` | Real disposable repositories and remotes for exact pushes, isolated pull/fetch, tag publication and deletion, leased branch cleanup with tracking-ref and branch-configuration removal, `push.followTags` isolation, clean multi-ref stdout, ls-remote tail-match filtering, and full-ref upstreams |
| `git_sync_recovery.bats`, `git_tag_recovery.bats` | Independent fetch configuration, exact publication destinations, frozen tag OIDs and leases, and rejection of multiple push URLs before and after review |
| `git_local_recovery.bats` | Interruption versus ordinary failure in local discard batches, all-changes discard of tracked and untracked files, and stash drops |
| `git_identity.bats` | Local and global identity status, validation, profile application, local overrides of inherited signing and SSH key selection, inherited `ssh.exe` and `IdentityAgent` commands kept with or without a profile key, and `wslpath` key conversion for `ssh.exe` with refusal when it fails |
| `git_platform.bats` | `core.ignorecase` obstacles for hard undo, discard, discard of every change, and stash apply; refused case-colliding tags, stash branches, fetched and pruned tracking refs, and upstream pushes; WSL detection from fixtures, the Windows-drive badge and advisory, and one `PATH` lookup per menu dependency; SSH alias resolution through `GIT_SSH_COMMAND`, `core.sshCommand`, and `GIT_SSH`; CRLF `.ws-hostname` files; the mocked macOS Command Line Tools placeholder; Git older than 2.31 or failing to run; and `GPG_TTY` for signed tags under a pseudo-terminal |

GitHub writes use a deny-by-default `gh` recorder, while transport workflows
use disposable local remotes. No focused Git test contacts GitHub or mutates the
repository under test. Case-insensitive file systems are simulated with
`core.ignorecase`, and WSL, macOS, Windows OpenSSH, and pinentry through
fixtures and mocks; the platform notes in [`git-menu.md`](git-menu.md) record
what that leaves unverified. See [`git-menu.md`](git-menu.md) for the frozen
interface and manual-smoke-test boundary.

### Developer coverage

| File | Covered boundary |
| --- | --- |
| `dev.bats` | Clean sourcing and help, shell and Markdown gates including the opt-in `npx` Markdownlint runner, the multi-gate result table, and the no-applicable-gate no-op |
| `dev_contract.bats` | The frozen 25-command fixture, five-way surface parity, dispatcher coverage, absence of retired names and aliases, cancellation, timing label, exact no-argument grammar, and invalid-argument statuses |
| `dev_interface.bats` | Double sourcing, standalone sourcing without the core runtime, loader failure without a false sentinel, stream separation, `NO_COLOR`, record validation, keyboard-legend accuracy, foreground private picker capture and cleanup, snapshot-validated selection and multi-select dispatch, argument forwarding, and lazy/eager parity |
| `dev_maintenance.bats` | Cleanup plans, dry runs, declined versus unavailable confirmations, protected roots, `.git` exclusion, awkward filenames, partial failures, kept Terraform lock metadata and OS junk files, which belong to `file-clean-junk`, owner delegation without installer fallback across every Developer source file, ephemeral gating, Markdownlint fix and configuration behavior, state-directory validation and best-effort backup pruning, PyPI helpers and probe diagnosis, and aggregate gate selection in which Node and Cargo manifests add no gate |
| `dev_update_safety.bats` | Frozen aggregate applicability, aggregate and exact-cleanup authorization, exact dependency rollback, hostile-option stream isolation, host tool ownership, frozen private hook plans, revision downgrade retention, all-stage environment installation, concurrent live-config preservation, temporary workspace identity, and staged Python replacement; interrupted dependency planning and locking, aggregate stop after an interrupted step, partial hook plans with an unchanged mutable revision, and an interrupted `.venv` rename that keeps the original |
| `dev_output.bats` | A failing check's replayed tail and retry command, changed locked versions read from `uv.lock` and an unchanged refresh, one guard record for every hook revision, installed hook types from a flow-style list, the System owner's result kept through the delegated host toolchain step, and verbose-only policy notes |
| `dev_update_dispatch.bats` | Child-specific dependency gates, missing uv with independent Terraform inspection and cleanup, and maintenance help/error routing before probes |
| `dev_update_recovery.bats` | Validated partial hook updates, refusal of unsafe or interrupted candidates and failed environment installation, independent package/Git backends, native HTTP stall settings, dry-run applicability, and retry summaries and removal of the pre-commit update's PyPI cache |
| `dev_update_actions.bats` | GitHub Actions discovery across odd workflow names and nested composite actions without following links; pinned, tag, branch, reusable-workflow, local, and Docker references with block scalars ignored; annotated-tag peeling and SHA identification; patch, minor, `--major`, prerelease, and no-downgrade selection; the release-age cooldown with an authenticated, unauthenticated, absent, or failing `gh`; dry run, decline, non-interactive refusal, and `--yes`; per-file backups, preserved modes, and byte-for-byte formatting with CRLF and comments; rollback after a newly failing validator or a failed publication, and kept updates with pre-existing findings; an isolated failed query, the timeout batch stop, HTTPS-only credential-free queries, and refused invalid values; and the `dev-update-all` step, its dry-run preview, and the menu, batch, dependency, and completion surfaces. `git ls-remote`, `gh`, `actionlint`, and `zizmor` are PATH mocks, and host copies are hidden from capability probes |
| `dev_update_specifiers.bats` | Dependency-only TOML rewrites with normalized names, repeated and inline declarations, preserved formatting and unrelated content, version ordering, bounded matching, dry-run behavior, and failed queries |
| `dev_python_relocation.bats` | Real offline uv with a local wheel, usable console/activation scripts after publication and staging cleanup, spaced paths, and staged minor/implementation validation |
| `dev_alignment.bats` | Parser-before-probe ordering, project-aware Python and Node runners, batch-eligibility metadata with injected-row refusal, fzf failures distinct from cancellation, bounded configuration, pruned project and test discovery, stream separation, symlinked-module loader refusal, direct and nested completion coverage, TOML dependency parsing, and fail-closed project health checks |
| `dev_cleanup_safety.bats` | Symlinked-root refusal, frozen-root revalidation before every removal, replaced-target detection, generated and nested-repository exclusion at the depth boundary, fail-closed discovery depth and target limits, and one bounded unique combined plan; unreadable directories skipped with a warning, installed-package trees of any virtualenv, `--keep-build` contents, nested repositories inside planned directories, and Cargo evidence for `target/` |
| `dev_io_safety.bats` | Unique same-second backups and reports, rollback that requires an exact backup, refusal of untrusted date and `mktemp` output as paths, propagated report and coverage failures, project-only test and hook runners, fail-closed tool arguments, and bounded HTTPS-only PyPI metadata handling; an unreadable directory that cannot block the menu, deep test detection, the pruned Markdownlint inventory, unwidened Ruff paths, clustered write flags, `.python-version` comments, aggregate gate interruption, and ASCII-only dependency names with leading whitespace |
| `dev_security_safety.bats` | Isolated audit backend with stderr UI, declined and non-interactive remediation that starts no backend, explicit `--fix` authorization, and bounded exact-argument Bandit scans with fail-closed discovery and Bandit inventories of an ordinary `src/` layout at the default depth |
| `dev_platform.bats` | The metadata interpreter's order past an old `python3` (versioned, uv-managed, then the validated `.venv`), one resolution per command run, `-I -S` for every reader, and platform installation advice; WSL1/WSL2 detection from a fixture `/proc`; Windows launchers on the WSL `PATH`, simulated with Zsh `hash`, as missing tools; DrvFs mode refusals with the WSL remedy; macOS Command Line Tools placeholders never run; macOS and WSL1 probe advice; Homebrew ownership by the owning prefix; one hard-link attempt on a filesystem without links; and Darwin and WSL menu marks only where a command cannot run |

The Developer suites run without live network access. Most package-manager
and linter calls (`uv`, `npx`, `shellcheck`, PyPI, `git ls-remote` against
github.com, and `gh api`) are mocked;
the relocation tests additionally use installed uv offline and a generated
local wheel without downloading a runtime or dependency. A real
`dev-update-deps` run against a live project remains a manual smoke test. The
macOS and WSL branches in `dev_platform.bats` are selected through mocks and
fixtures, also on the macOS runner; they do not replace Apple's real Command
Line Tools behavior, a WSL1 distribution, or a project on a DrvFs drive. See
[`dev-menu.md`](dev-menu.md) for the recorded residual gaps.

### VPN coverage

| File | Covered boundary |
| --- | --- |
| `vpn.bats` | Shared helpers: resolv.conf preflight including symlink refusal, directory writability, name validation, cache pointers, WSL detection, and DNS hook idempotency |
| `vpn_contract.bats` | The frozen 22-command fixture, five-way surface parity including exact dispatcher arms, a host-independent command set, dispatcher coverage, cancellation, timing label, argument forwarding, and invalid-argument statuses |
| `vpn_interface.bats` | Double sourcing, standalone sourcing without the core runtime, loader failure without a false sentinel, one derived module root, stream separation, `${(V)}` label escaping, `NO_COLOR`, four-field record validation, `fzf` options, foreground process-group ownership in a pseudo-terminal, the index-only preview, pane permissions and cleanup, selection and target revalidation, per-command `--help` and bad-option status, lazy/eager parity, the header scope and state lines, canonical `○` marks, and em-dash profile notes |
| `vpn_privilege.bats` | DNS hook injection refusal, `sudoedit` instead of a root editor, target revalidation after authentication, the restore undo copy, least privilege on read paths, announcement ordering, destructive controls, secret redaction in excerpts and preview panes, state permissions with traversal and symlink refusal, stale pointers, and the platform gate |
| `vpn_grammar.bats` | Exact completion grammar, parser-before-probe behavior, option terminators, operand cardinality, and safety-flag parity |
| `vpn_hardening.bats` | Protected profile-directory boundaries, unsafe file and import-source refusal, lifecycle-hook rejection, semantic DNS validation, picker ambiguity, private atomic cache/report publication, failure cleanup, and no-privilege dry runs |
| `vpn_regressions.bats` | Default and hostile provider URLs, bounded HTTPS-only curl invocation, exact WSL hook ownership, single-IP fallbacks, atomic IPv6 rewrite and backup, fail-closed connect, raw `wg` stream isolation, sudo timestamp failures, state/report bounds, signal-safe preview cleanup, NUL-hidden import hooks, the profile summary, `NO_CLOBBER` state writes, locked reconnect fallback, unreadable-profile access, empty privileged inventories, sudo-bound `wg-quick strip`, stdout-clean details and IPv6 rewrites, picker interruption status, whitespace-split secret redaction, aligned IP-info columns, terminal-less import failure, symlinked homes, and 15-character new profile names |
| `vpn_control_recovery.bats` | Exact profile paths, authentication revalidation, missing targets, preserved interruptions with not-run tunnels, partial batch verdicts, `wg-quick` output replayed only on failure, and refusal of unknown active state |
| `vpn_probe_recovery.bats` | Interrupted sudo cache checks and authentication, direct WireGuard probes, protected profile existence/metadata/checksum reads, bounded capture status propagation, and ordinary warm-cache probe recovery |
| `vpn_menu_recovery.bats` | Action interruption and ordinary failure, picker cancellation, real private capture cleanup, and no pause or rediscovery after interruption |
| `vpn_state_recovery.bats` | Saved-profile validation interruption through default and last-profile connection, no fallback after interruption, ordinary stale or missing pointers, and a cache directory that does not exist yet |
| `vpn_darwin.bats` | The macOS directory policy and root-owned system-alias rule, profile-to-utun pairing (unambiguous, ambiguous through sudo, locked, stale, unmanaged), exact absolute Bash and `wg-quick` argv, device revalidation after authentication, device-aware plans, summary, and menu rows, BSD `ifconfig`/`route`/`netstat`/`scutil` collectors, numeric install owners, pinned system tools, the privileged metadata probe's fingerprint equality, the unprivileged edit path in a pseudo-terminal, the missing Bash 4 mark, the refused IPv6 tweak, and an untrusted tool directory |
| `vpn_wsl.bats` | WSL IPv6 rewrite gating by networking mode and IPv6 default route, explicit overrides, one shared WSL detector across platform, gate, and report, the unsupported resolver-pin warning, and platform-specific DNS leak hints |
| `vpn_mtu.bats` | The path MTU probe against a recording `ping` mock: exact bisection boundaries, the two-probe healthy path, the iputils MTU hint, lost replies retried and explicit too-large evidence not retried, lower bounds, unreachable, unresolvable, and unsupported pings, the not-applicable kernel, a hanging ping and the time and probe bounds, hostile targets refused before any probe, per-platform advice including the exact `/etc/wsl.conf` line and BSD `ping` flags, WireGuard sizing, no `sudo`, and the `--json` document, failures, and missing `jq` |

`test/vpn_test_helper.bash` pins each VPN file to a kernel with a `uname`
mock (Linux unless a test chooses another), so VPN tests select platform
branches through mocks rather than the host. Its macOS fixture builds a
sandbox Homebrew prefix that leads `PATH`, with a real Bash 4+ link and
recording `wg-quick`, `wg`, `wireguard-go`, and `brew --prefix` mocks, BSD
networking mocks, and a private wg-quick runtime directory holding `.name`
records and real Unix sockets with chosen modification times. `wg`,
`wg-quick`, `sudo`, `sudoedit`, `uname`, `grep`, `wslinfo`, `ip`, `ping`, and
the network are all mocked, so no test touches a real tunnel. The deny-by-default
`sudo` recorder means a test asserting on `$MOCK_SUDO_LOG` proves what the code
actually elevated. The [VPN smoke workflow](#vpn-smoke) brings a real tunnel
up and down on Ubuntu and macOS runners; a real WSL or WSL1 verification is not
recorded. See [`vpn-menu.md`](vpn-menu.md) for the platform boundaries.

The focused maintenance and state suites run without live network, privilege,
process signals, or shared-host mutations. They exercise dry-run boundaries,
partial failures, and persisted state refusal paths. Mocked Darwin behavior is
not a substitute for a real macOS host run.

### File coverage

| File | Covered boundary |
| --- | --- |
| `file.bats` | Split-module loading, top-level help naming all five commands, unknown-command status, a large-file deletion dry run that preserves every target and prints the numbered plan and dry-run line, and non-interactive deletion that fails closed without `--yes` |
| `file_discovery_status.bats` | A matching candidate followed by a smaller one, empty results, and preserved scan and interruption statuses without partial paths |
| `file_contract.bats` | Frozen five-command fixture, literal snapshot membership, junk cleanup as the last menu section naming every junk type with the trash section before it, menu parity, help forwarding through the dispatcher, dispatcher arms, lazy stubs, help entries, and `#compdef` bindings for every command, and completion declarations including the trash actions, flags, and ID completion |
| `file_safety.bats` | Leading-dash large-file targets, large-file deletion that still refuses its whole plan for an unsafe target, unsupported extractor refusal, nested deletion targets, current-directory archive output boundaries, and a directory archive input planned as exactly that directory |
| `file_recovery.bats` | Real multi-target large-file deletion, GNU TAR round trip, all-target preflight revalidation, interrupted deletion that retains its quarantine and leaves later targets untouched, interrupted archive creation and publication that preserve existing output and clean staging, interrupted extraction that publishes no directory, and refusal of unexpected staging paths |
| `file_junk.bats` | The empty result, dry run, non-interactive refusal, decline, exact names including colon and leading-dash names, names the plan cannot represent, links and directories named like junk, pruned Git metadata and generated trees, junk planned across a folder of repositories and worktrees, skipped group-writable, hard-linked, and foreign-owned files with their counted warning and verbosity listing, an unsafe directory above a candidate, the depth bound, unreadable directories, inventory failures, an unsafe base, a target or base changed after confirmation, a counted partial failure, and an interrupted deletion that retains its quarantine |
| `file_trash.bats` | The `file-trash` grammar; a put, list, and restore round trip of files, directories, symbolic links, and names with spaces or a leading dash that keeps each inode; refused control and `\|` names, paths outside or equal to the current directory or through a link, the trash itself, and directories the purge engine could not delete; a link trashed, restored, and purged as the link itself; private modes and the record format; `XDG_DATA_HOME` and an unsafe trash; dry runs, declines, and terminal-less refusals; revalidation after confirmation; a failed or interrupted move that withdraws its record; unique IDs; a mocked device change and a fixture bind mount refused as another filesystem for put and restore; no-clobber and missing-parent restores; purges by age, ID, and `--all` through the quarantine engine; malicious records (relative, `..`, encoded newline or NUL, inside the trash, bad escape or date, raw newline, extra keys, a linked or readable record, and an unsafe parent outside `HOME`) that are never restored; damaged entries; the one-line `zdx.file-trash.v1` document, its UTC dates, and the missing-`jq` refusal; the picker with a forged row; and the DrvFs hint |

Archive tools are mocked or exercised against disposable files, including a
real multi-input GNU TAR round trip, which skips when the host has no GNU tar
as `tar` or `gtar`. `file_platform.bats` reproduces macOS, BSD, and WSL
branches with mocks. Real ZIP and 7z archives, cross-filesystem behavior, and
a macOS or WSL host remain manual boundaries.

### Environment coverage

| File | Covered boundary |
| --- | --- |
| `env.bats` | Loading and canonical help without state probes, read-only PATH inspection with explicit deduplication, and value classifications that withhold every raw value |
| `env_contract.bats` | Frozen three-command fixture, module/function/menu/help/dispatcher/completion/lazy parity, no automatic `chpwd` hook, and explicit stdout modes |
| `env_dotenv.bats` | The dotenv parser's records for `export`, quotes, multi-line values, comments, `=` inside values, empty values, invalid keys, CRLF endings, a byte-order mark, and NUL bytes; canary values from both files absent from stdout, stderr, menu rows, and previews in text and JSON modes; missing, extra, empty, duplicate, and malformed detection; tracked, ignored, and literal-name Git facts in disposable repositories immune to `GIT_DIR`, with hints that are never run; mode warnings that leave the mode unchanged; link, non-regular, size, and line-count refusals; example discovery order; usage statuses; `--json` shape with `jq -e`, a single stdout document, and failure without `jq`; unavailable, placeholder, and timed-out Git; the availability mark and dispatch; and direct and nested completion |
| `env_safety.bats` | Secret withholding in rows, previews, and lists; PATH revalidation after authorization and required `--yes` without a terminal; decline as cancellation; rejection of forged, multi-row, and failed-picker output; exact-string membership; untrusted `mktemp` output refused before `chmod` or cleanup; stdout reserved for documented data; menu-delimiter validation; and picker capture without command substitution |

Tests run below the disposable test home. Clipboard programs are mocked, no
automatic directory hook is registered, and real clipboard backends and
cross-platform terminal behavior remain manual boundaries.

### Python coverage

| File | Covered boundary |
| --- | --- |
| `py.bats` | Double/failed sourcing, help and stream behavior, menu-record validation, the project scope line, read-only multi-select batches with step results, summary, verdict, and rerun hints, cancellation without a batch, and foreground result capture |
| `py_contract.bats` | Frozen 16-command fixture, function/module ownership, menu membership, exact help and dispatcher-arm parity, representative dispatch forwarding, and exact completion coverage |
| `py_safety.bats` | Existing-target create refusal, create/remove dry runs with key-value facts and no displayed identities, non-interactive confirmation, external-environment refusal, fail-closed rebuild, activation-script revalidation, option-like package refusal, ambient-pip refusal, tool dry-run, Python-version validation, uv `version_info` metadata, tool and runtime tables without backend diagnostics, runtime-install version evidence, and PyPI metadata that keeps the caller umask and removes its private files on success and failure |
| `py_recovery.bats` | Interrupted and ordinary partial tool upgrades with step results, summary rows, counted verdicts, and exact retry commands, version evidence for updated versus current tools, failure-only replay of captured backend output, real offline relocatable uv activation, stable descriptor resolution in subshells, ordinary descriptor fallback, unsupported-host refusal, and restoration of known activation state after failure |

Package mutations, Poetry, pipx, and PyPI use mocks. Activation recovery also
creates disposable environments with installed uv offline, without runtime or
package downloads. No host interpreter or package installation is changed.
`py_platform.bats` covers the refusal of a mount below an environment before
removal on both mount-check branches. Poetry/TOML ambiguity, PyPI response
bounds, inventory overflow, exact multi-backend upgrade revalidation, a mount
that appears during quarantine, and `.virtualenvs` count bounds still require
focused regression cases.

### Workspace coverage

| File | Covered boundary |
| --- | --- |
| `ws.bats` | Standalone, double, and side-effect-free sourcing, loader failure, help streams, grammar statuses before probes, literal dispatch, the menu context block, cancellation, current-shell dispatch, forged and failed selections, missing-Git marks, the `zdx ws` route and reserved name, the catalog row, the doctor `fd` row, and lazy stubs that change the calling shell |
| `ws_contract.bats` | Frozen three-command fixture with module, function, menu, dispatcher, help, completion, compinit registration, lazy-stub, and documentation parity, and no evaluator |
| `ws_jump.bats` | `fd` and `find` discovery parity, depth, exclusions and their validation, hidden, nested, linked, and worktree entries, direct and picker jumps, exact-name precedence, no match, cancellation, forged and stale selections, hostile names, the index-only preview rendered by a mocked fzf, and routing through `ws-menu` and `zdx` |
| `ws_status.bats` | Real clean, dirty, diverged, detached, stashed, and unborn fixture repositories with a local bare remote, in text and JSON; attention order; stdout reserved for one compact JSON document on a single line; a mocked `git fetch` that records its bound, arguments, and prompt setting; failed and timed-out fetches; unreadable repositories; an empty root; and a missing `jq` |
| `ws_clone.bats` | URL refusals before any clone, the exact dry-run plan, new workspace directories, existing destinations, staging cleanup after a failed clone, SSH alias rewriting with a mocked `ssh`, alias hosts, identity delegation with exact arguments and a real profile, non-interactive refusal, declines, the identity picker, `.ws-hostname` inference, and unsafe roots and directories |

`git clone` is mocked by a `git` wrapper that delegates every other command
to the real Git: the harness has no test-only transport, and the URL rules
refuse local paths and `file://`. OpenSSH `ssh -G` ignores `HOME`, so alias
tests replace `ssh`. Real remote hosts, `ssh.exe`, and BSD `mv` remain manual
boundaries.

### Local-installer coverage

The local integration contract is documented in
[`installation.md`](installation.md).

| File | Covered boundary |
| --- | --- |
| `installer.bats` | Local launchers, grammar before probes, a `python3` that fails or is older than 3.8 diagnosed before planning, the macOS Command Line Tools placeholder reported without running it, read-only planning, explicit non-interactive consent, exact source/link idempotency, unrelated-target refusal, private no-clobber configuration, an existing configuration that others can read kept with a `chmod 600` warning and one they can modify refused, path ownership and aliases, Oh My Zsh outside HOME behind an owned or root-owned alias versus refused untrusted links, stderr-only progress, and absence of network, Git, sudo, and startup-file mutation |
| `zdx_contract.bats` | Installation of the centralized commented configuration template and its private initial permissions |

Installer fixtures use disposable HOME, Oh My Zsh, source, and configuration trees. They do not clone a remote
repository, modify the operator's startup files, or install packages.
They exercise the real local publication workflow rather than only asserting
its source text. The macOS workflow runs the same fixtures on an Apple Silicon
runner; a first installation on a real Mac and activation in an interactive
shell remain manual acceptance.

### Master-router coverage

| File | Covered boundary |
| --- | --- |
| `zdx_contract.bats` | Exact adjacent loader, idempotency, evaluator absence, fixed built-in routing, literal plugin arguments, reserved names, help streams, grammar statuses, private foreground picker cleanup, cancellation, forged-row rejection, color disabling, and local/pre-push/CI quality-gate parity |
| `zdx_status.bats` | `zdx status` source safety, help and grammar statuses before any probe, router, help, catalog order, completion (`zdx status` and `zdx-status`), reserved-name, and lazy-stub parity, the reported release against `pyproject.toml`; `zdx.status.v1` documents checked with `jq -e` for a repository with upstream, changes, and workspace, outside a repository, a hostile branch name, a merge in progress, and a detached HEAD, with exactly one monochrome document on stdout; the text report on stderr only; every external probe bounded and a timed-out `git status` left `null`; `--json` without jq; WireGuard, platform, reboot-flag, and load-average fixtures; and macOS nulls with the Command Line Tools `git` placeholder never run |
| `zdx_widgets.bats` | Insert-widget source safety and the single quoted `LBUFFER` edit; branch, pull-request, port (`ss` and macOS `lsof`), and virtual-environment candidates with hostile names round-tripped through `${(q)…}`; `Esc`, no match, a failed picker, and forged or arithmetic-bearing rows leaving the buffer untouched; one `zle -M` message for a missing tool, repository, or `gh` authentication without opening fzf; bounded probes, plain-mode and isolated fzf options; unbound-only binding with override, empty, and `ZDX_KEYBINDINGS=0` cases in an interactive shell; and first-use loading in lazy mode |
| `zdx_doctor_rendering.bats` | Isolated fzf version probes, caller-environment preservation, malformed or failed version reporting for every dependency without a `v` placeholder, interruption propagation, and escaped display/source diagnostics without configuration values; WSL detection from interop, late interop, or the kernel release; the Linux system package manager ahead of Linuxbrew; a mocked healthy macOS host that passes with `ip` not applicable and no `findmnt` row, GNU tar found as `gtar`, and the watchdog advisory instead of a missing `timeout`; Apple Command Line Tools placeholders reported missing without being run; and counted Linux capabilities |

The focused router tests replace suite entrypoints and FZF with local mocks.
They do not execute a real plugin or prove the safety of plugin code after its
separate trust decision.

## Isolation requirements

Every test MUST run in a disposable sandbox and MUST NOT depend on or mutate the
developer's live environment.

The shared helper establishes a temporary root, redirects `$HOME`, creates a
mock-bin directory at the front of `$PATH`, and exposes `run_zsh` to source the
repository runtime in Zsh.

The temporary root is created below the caller's `TMPDIR` (or `/tmp`) and
resolved to its physical path. macOS reaches its per-user `TMPDIR` through the
`/var -> /private/var` symbolic link, and production code correctly refuses
symlinked temporary, state, and home paths; a canonical root keeps `$HOME`,
fixtures, and every derived path real. Each test also gets a private,
canonical `TMPDIR` (`$TEST_TEMP_DIR/tmpdir`, mode `700`), so production code
never sees the host's temporary directory. A test that covers a symlinked or
otherwise hostile temporary root sets `TMPDIR` explicitly.

Tests MUST isolate:

- `$HOME`, `$ZSH_CUSTOM`, `WS_BASE_DIR`, caches, backups, and plugin paths;
- Git global and system configuration;
- telemetry and configuration files;
- external commands, network clients, package managers, `sudo`, `fzf`, pagers,
  editors, browsers, service managers, process signals, and archive tools;
- environment flags that can enable auto-update, telemetry, or live loading.

The shared helper clears inherited Homebrew retry, analytics, auto-update, and
askpass controls. A test that exercises those boundaries exports its hostile
values explicitly after setup rather than depending on the developer or runner
environment.

The helper also clears every repository-local Git variable that
`git rev-parse --local-env-vars` reports, such as `GIT_DIR` and
`GIT_INDEX_FILE`. Git exports them to hooks, so without this the pre-push
`just check` would redirect every fixture repository into the real one; from a
linked worktree, that rewrites its shared configuration and refs.
`sandbox_isolation.bats` guards this boundary.

The redirected `$HOME` already isolates global Git configuration. The helper
also exports `GIT_CONFIG_NOSYSTEM=1`, because Homebrew's Git ships a system file
that selects the macOS keychain credential helper, and unsets `ZDOTDIR`, which
would otherwise make every `zsh -c` read the caller's `.zshenv`.

OpenSSH reads the account's home from the password database, not `$HOME`, so
the real client would consult the operator's or runner's configuration. The
helper installs a deny-by-default `ssh` mock that answers only the local
configuration query `ssh -G [--] HOST`, as for a host without configuration,
and fails every other invocation with status `97`. A test that needs host
aliases installs its own `ssh` mock.

A test may use a real temporary Git repository inside the sandbox. It may not
use the repository under test as a mutation target.

Teardown removes only the generated sandbox. Cleanup code MUST verify that the
target is the expected temporary root before recursive deletion. The helper's
`cleanup_sandbox` refuses any root other than the one it created, refuses a
root that is not a real directory, and restores owner access inside the
sandbox, without following symbolic links, before it removes it.

## Portable test code

Test code MUST run unchanged on GNU/Linux and on macOS, whose BSD userland
differs: `stat` has no `-c`, there is no `sha256sum`, `truncate`, `timeout`,
or `findmnt`, `sed -i` takes a suffix argument, `wc` pads its counts, `chmod`
stops parsing options at the mode, `script` is not util-linux, and `/tmp` is a
symbolic link. Test code MUST NOT depend on GNU-only behavior. The shared
helper provides portable replacements:

| Helper | Result |
| --- | --- |
| `file_stat PATH ELEMENT...` | The named `zstat` elements of the path itself (as `lstat`), joined by colons; `mode` prints octal permission bits |
| `file_mode PATH` | Octal permission bits, such as `600` or `1500` (as GNU `stat -c %a`) |
| `file_owner_uid PATH` | Numeric owner |
| `file_inode PATH` | Inode number |
| `file_identity PATH` | `device:inode`, which changes when the path is replaced |
| `file_links PATH` | Hard-link count |
| `file_size PATH` | Size in bytes |
| `sha256_file PATH` | The content's SHA-256 digest through `sha256sum` or `shasum -a 256` |
| `make_sized_file PATH BYTES` | Creates the file or sets its size exactly, like `truncate -s` |
| `has_util_linux_script` | Succeeds only for util-linux `script`, whose `-q -e -f -c` options PTY tests use |
| `host_is_darwin`, `skip_on_darwin REASON` | The host kernel recorded at load, so a `uname` mock cannot change it |

`sandbox_isolation.bats` proves these helpers' results, the canonical root
under a symlinked `TMPDIR` parent, the private `TMPDIR`, and the Git and SSH
isolation on every host that runs the suite.

Inside Zsh code under `run_zsh`, read metadata with `zmodload -F zsh/stat
b:zstat` and `zstat -LH`. Rewrite files with `perl -pi -e` (or a first-match
`perl -0pi -e`) instead of `sed -i`, use `grep -E` for alternation instead of
BRE `\|`, write `chmod -- MODE FILE` rather than `chmod MODE -- FILE`, and
compare `wc` counts numerically. Build out-of-home fixtures inside the sandbox
rather than under `/tmp`. A generated mock that a production path runs with a
fixed `PATH` such as `/usr/bin:/bin` uses `#!$BASH` rather than
`#!/usr/bin/env bash`, which would select Bash 3.2 on macOS.

A negated command (`! cmd`) never trips `set -e`, so in BATS it fails a test
only when it is the test's last command; anywhere else it checks nothing.
Write `! cmd || false`, use `run` and assert `$status`, or fold the negation
into the condition (`[[ "$output" != *x* ]]`). `shellcheck -s bats` reports
the bare form as SC2314 or SC2315; a negated command inside a loop body is
equally inert and is not always reported.

A test that is Linux-only by design calls `skip_on_darwin` with its reason.
Never skip a test because the product currently fails on macOS; that failure
is the evidence the platform work needs. The current Linux-only tests are:

| Test | Reason |
| --- | --- |
| `py_recovery.bats`: relocatable activation in an actual subshell, real offline uv relocatable environments, and restoration after an unsuccessful activation | Relocatable activation needs `/proc/<pid>/fd` for a stable descriptor path; the restoration case uses a relocatable fixture |
| `sys_diagnostics.bats`: Linux collectors emit typed TSV records | The collectors read `/proc/meminfo`, `/proc/cpuinfo`, and `/proc/uptime` |
| `sys_apt_keys.bats`: every APT signing-key renewal case | APT and its signing keyrings exist only on Debian-based Linux |
| `sys_maintenance.bats`: the trusted unattended-upgrade version record and the dirty dpkg audit before takeover signaling | APT, dpkg, and unattended-upgrade exist only on Debian-based Linux |

The two interactive PTY cases in `sys_maintenance.bats` skip unless
`has_util_linux_script` succeeds, which also covers BSD `script` on macOS.

Hardened TAR extraction requires GNU tar, so the File tests that extract a
real archive (the round trip and interrupted extraction in
`file_recovery.bats`, and the `gtar` resolution in `file_platform.bats`) skip
when the host has neither `tar` nor `gtar` as GNU tar. The nested-mount case
of `py_platform.bats` needs a readable directory with a mount directly below
it (`/System/Volumes` on macOS, `/sys/fs` on Linux) and skips without one.

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
It MUST fail on an unexpected privileged command. The shared recorder matches
the basename of the command, allowlists the VPN suite's fixed metadata probe
(`zsh -f -c <program> zdx-vpn-stat <path>`) by the name `zdx-vpn-stat` rather
than permitting `zsh`, and exports `MOCK_SUDO_ROOT=1` to the commands it runs
so a mock can model a root-only answer. For an authenticated
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
section/action previews with shell-looking description text. It also checks
that every context block has at most a scope line and a state line, and that
the Developer, Environment, File, Python, and System menus mark unavailable
rows as `○ <label> (missing: …)` or `(unavailable: …)` without nested
parentheses. It checks the shared presentation contract rather than freezing
each action's wording.
`menu_templates.bats` checks that a picker showing one field drops its trailing
delimiter through an fzf template only when the installed fzf supports
templates, leaves pickers that show several fields unchanged, and lets
`ZDX_FZF_TEMPLATES` force or disable the template without a probe.
`menu_domain_presentation.bats` covers multi-selection scopes, the
compact telemetry selector, and VPN details with and without preview data.
`menu_master_presentation.bats` covers route-token filtering, compact section
and command details, and loaded plugin discovery and completion.
`git_menu_capture.bats` verifies top-level snapshot membership, failed-picker
data refusal, exact private-result cleanup, the post-write size limit, and
foreground terminal ownership.

That private-file capture coverage is specific to the top-level Git menu.
Nested Git pickers use their own capture implementations, and the plugin
manager's rendering coverage does not establish equivalent capture or
lifecycle controls.

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

The README's demonstration opens the `zdx` launcher and tours the Git,
System, and Developer menus, with a static poster of the Git menu. Its three
actions (a stash save, the host summary, and a project health check) run only
inside a private recording workspace, and every other backend action stays
disabled. The GIF and PNG have their own transcript and reproduction procedure
in [`demo.md`](demo.md). `demo_recording.bats` checks that recorder: hostile
startup and backend environment cannot enter the recorded session, failed or
oversized media keep the previous files and clean only the temporary
workspace, a replaced temporary directory is retained rather than adopted for
cleanup, and sourcing the recorder records nothing. A recording shows the
documented workflow; it does not replace the regression tests or the platform
acceptance matrix.

The manual terminal matrix includes native macOS Terminal.app and iTerm2 in
light and dark appearance, UTF-8 and C/POSIX locales, default and plain modes,
and narrow/wide layouts. That native macOS matrix has not been run here:
Linux PTY checks, mocked options, and the headless macOS CI job do not
establish macOS rendering. Test responsive previews with fzf 0.31 or
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
- no downloaded script is executed through `sudo`.

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

The current Darwin tests exercise routing and parser behavior with mocks, and
the [macOS workflow](#macos) runs them on a Mac. They do not close the
acceptance items for host-only macOS behavior.

A mocked platform branch is selected through capability mocks, never by the
host. Host-specific skips follow the rule in
[Portable test code](#portable-test-code): only a test that is Linux-only by
design skips on Darwin.

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

BATS loads `test/setup_suite.bash` whenever it runs a file from `test/`. It
checks the Bash floor once and exports `BATS_TEST_TIMEOUT=300` unless the
caller already set a value, so a hung test fails instead of blocking the run.
The slowest test takes about 20 seconds under `--jobs 6` on Linux; export a
different value for a slower host. BATS arms this timer before `setup`, which
is why the default cannot live in `test_helper.bash`. BATS 1.13 and newer
terminate the timed-out test's whole process tree, including commands under
`run`. Older releases, such as the 1.10 package in Ubuntu 24.04, stop only the
test's direct children, so a command blocked under `run` can still hold the
run open until an outer job limit ends it. BATS 1.13 and 1.14 also lose the
timer's process ID when a test fails, so the timer outlives the test: the run
waits for it, and when it fires it signals a process ID the system may have
reused. `test_helper.bash` copies that ID to a global variable while it is
still visible, which lets BATS stop the timer on every exit path.

The pre-commit Markdown hook uses `--fix`, so `just check` can modify Markdown.
After a gate changes files, inspect the diff and run `just check` again.

`just pre-commit-install` installs commit, commit-message, and pre-push hooks.
The pre-push hook runs `just check`; its full-suite cost is deliberate because
it is the last local boundary before GitHub receives the change. Every file
hook is explicitly restricted to `pre-commit`, so upstream manifest defaults
cannot make pre-push run it before the complete aggregate.

## Continuous integration

Three workflows run the tests: Quality Gates and macOS run the BATS suite on
Linux and on an Apple Silicon Mac, and VPN smoke brings a real tunnel up and
down on Ubuntu and macOS runners. None of them is a multi-Zsh-version matrix.
CodeQL and the DCO check complete the required checks; the remaining
workflows are scheduled maintenance or release automation.

### Required checks

Branch protection on `main` requires the `lint` (Quality Gates), `DCO`,
`CodeQL`, and `bats (macOS)` checks before a pull request merges. Pull
requests merge only by squash, and commits on `main` must be signed. VPN smoke
runs only when VPN files change, so it is not a required check.

### Quality Gates

The `lint` workflow (CI · Quality Gates) runs on pushes and pull requests to
`main`, on manual dispatch, and daily at 08:00 UTC, so a newly published
advisory fails the dependency audit while the repository is idle. Its `lint`
job runs on `ubuntu-latest` with the distribution Zsh, BATS, fzf, and Just
packages under a 30-minute job bound sized for the complete serial suite.
After a locked dependency sync, it invokes the same `just check` aggregate
used by the local pre-push hook. That aggregate rejects a stale lockfile
without rewriting it, then runs syntax, pre-commit, Python dependency audit,
and BATS gates. Its `uv run` and `uv export` calls use `--locked`.

Installing fzf in CI enables the native label-filtering and inherited-option
regressions; without it those tests explicitly skip, which is not a pass.
Pipe-delimited pickers use the literal expression `[|]`; a bare `|` breaks
field filtering on the Ubuntu 24.04 distribution's fzf 0.44.1 even though it
works on newer local releases. Test the distribution binary when changing
the workflow's system dependencies, alongside the current developer binary.
Check both the runner's exit status and its failed/skipped test counts. Every
workflow titles a push run with its branch or tag name and a pull request run with
its title, so a commit's message and trailers never become a run title.

### macOS

The `macos` workflow (CI · macOS) runs on pushes and pull requests to `main`
and on manual dispatch. Its `bats (macOS)` job uses a `macos-15` Apple Silicon
runner under a 45-minute bound, with read-only repository permissions and a
checkout that keeps no credentials. It installs Homebrew `bash`, `bats-core`,
`fzf`, `gnu-tar`, `just`, `parallel` (for `bats --jobs`), and `uv`, prints the
tool versions, puts Homebrew's `bin` first on `PATH`, parse-checks every
tracked Zsh file with `zsh -n`, and runs
`bats --jobs 3 --print-output-on-failure test/` with `GIT_CONFIG_NOSYSTEM=1`.
GNU coreutils stays uninstalled and GNU tar is present only as `gtar`, as on a
typical Mac, so a GNU assumption in product or test code fails there instead
of passing. Do not put GNU coreutils, sed, or tar ahead of the system tools in
this job: that would hide the BSD behavior the suite has to tolerate.

The job does not run `just check` or `uv sync`: pre-commit hooks, the
lockfile check, and the dependency audit run only in Quality Gates. The
installed `uv` lets the offline relocation tests run there. Linux-only tests
skip by design, as listed under
[Portable test code](#portable-test-code). The runner is Apple Silicon only,
and host behavior that the tests mock, such as launchd, `softwareupdate`,
Homebrew casks, Command Line Tools placeholders, and real sudo, is not
exercised.

### VPN smoke

The `vpn-smoke` workflow (CI · VPN smoke) runs `.github/scripts/vpn-smoke.zsh`
on `ubuntu-latest` and `macos-15` runners for pull requests to `main` that
change `functions/vpn-*.zsh`, `functions/vpn/**`, `completions/_vpn-menu`, the
script, or the workflow, and on manual dispatch. Each runner has a 15-minute
bound and read-only repository permissions. Ubuntu installs `wireguard-tools`
and `zsh` with APT; macOS installs Homebrew `bash` and `wireguard-tools`.

With the runner's passwordless sudo, the script installs a private `zdxsmoke0`
profile (owned by root, mode `600`) that routes only `10.123.45.0/24` to the
TEST-NET-1 endpoint `192.0.2.1:51820` and has no DNS line. It connects the
profile with `vpn-menu vpn-on`, checks the suite's active listing, the
profile-to-device pairing, the route to `10.123.45.1`, and an unchanged route
to `1.1.1.1`, and on macOS also the root-owned mode-`0400` runtime record and
root-only `wg show`. It then runs `vpn-summary` and `vpn-details`,
disconnects with `vpn-off`, and always brings the tunnel down and removes the
profile. The script refuses to run unless `ZDX_VPN_SMOKE=1` and `CI=true` are
set, refuses a profile that already exists, and returns `2` on an ineligible
host.

The smoke run does not cover WSL, the WSL DNS hardening or IPv6 rewrite,
profile import or editing, the interactive menu, or an interactive or
password-protected sudo. The endpoint is a documentation address, so it
checks routes rather than traffic through the tunnel.

### Dependabot

[`.github/dependabot.yml`](../.github/dependabot.yml) checks the GitHub Actions
of every workflow each Monday and opens one grouped `ci(deps)` pull request
that keeps SHA pins and version comments, proposing a release only after
seven days. That pull request runs the same required checks as any other. For
a pull request opened by `dependabot[bot]`, the DCO workflow skips the
sign-off check and instead requires every commit to be authored by
`dependabot[bot]` with a signature GitHub verified, so any other commit pushed
to the branch fails it. Dependabot does not update Python dependencies or
pre-commit hooks; `uv.lock` and the hook pins stay in the reviewed manual
workflow.

### CodeQL, DCO, and maintenance workflows

- `codeql` (Security · CodeQL) analyzes the repository's Python code without
  a build on pushes and pull requests to `main`, on Mondays at 09:30 UTC, and
  on manual dispatch, and reports to code scanning.
- `dco` (PR · DCO Check) runs on pull requests to `main` and requires a
  `Signed-off-by:` trailer on every commit, with the Dependabot exception
  described above.
- `links` (Maintenance · Link Check) runs Lychee over the Markdown files
  outside `.venv` and `.demo` on Mondays at 07:00 UTC and on manual dispatch.
- `scorecard` (Security · OpenSSF Scorecard) runs on Mondays at 09:30 UTC, on
  pushes to `main`, and on manual dispatch, and is skipped while the
  repository is private.
- `uv-upgrade` (Maintenance · Dependency Report) runs on Tuesdays at 06:00 UTC
  and on manual dispatch. It verifies `uv.lock` with `uv lock --check` and
  summarizes the changes `uv lock --upgrade --dry-run` would make, without
  changing the repository.
- `release` (CD · Release) builds and checksums the source archive for a
  pushed release tag such as `0.1.0` or a dispatched existing tag, attests its provenance when
  the repository is public, and publishes the tag's `CHANGELOG.md` section as
  the release notes; it runs no tests.

### Platform claims

Platform claims need dedicated tests, an expanded CI job, or a documented
manual verification record. Do not state broader matrix coverage than CI
actually provides.

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
