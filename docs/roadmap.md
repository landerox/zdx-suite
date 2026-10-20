# Roadmap: ZDX (Zsh Developer Experience)

This document is the official project roadmap for `ZDX`. It records the
`v0.1.0` release baseline and the work that remains for the current suites.
Roadmap presence does not reserve ownership or waive the requirements in
[`suites.md`](suites.md) and [`development.md`](development.md).

---

## Release baseline: v0.1.0

`v0.1.0` freezes 120 public commands across eight suites behind per-suite
contracts and surface-parity fixtures in
`test/fixtures/<suite>-public-commands.tsv`. See
[`CHANGELOG.md`](../CHANGELOG.md) for the release notes.

| Suite | Commands | Scope |
| --- | ---: | --- |
| `ws-menu` | 3 | Workspace navigation, staged clones with SSH alias rewriting and delegated identity profiles, and read-only multi-repository status with an opt-in bounded fetch and `--json` data, over the `$WS_BASE_DIR/<platform>/<identity>/<repository>` layout |
| `git-menu` | 21 | Repository, local-change, branch, tag, and pull-request commands with exact plans, remote leases, identity checks, `--json` status data, and post-authorization revalidation |
| `dev-menu` | 25 | Project maintenance, quality, security, update, and bounded cleanup commands, including SHA-pinned GitHub Actions updates, with the Python lifecycle delegated to `py-menu` |
| `sys-menu` | 25 | Capability-based diagnostics with a read-only WSL configuration review, plus resource, maintenance, cleanup, and telemetry commands, including exclusive update aggregation with per-step results, default continuation after ordinary failures, optional `--fail-fast`, zero-timeout APT lock arbitration, and a not-applicable result for commands the host cannot run |
| `vpn-menu` | 22 | WireGuard commands with private profiles, precomputed previews, least privilege, exact mutation plans, and a bounded, unprivileged path MTU probe |
| `py-menu` | 16 | Validated project-local environments with a staged, rollback-safe `.venv` rebuild for uv projects, uv-managed Python runtimes, project packages, and isolated tools; ambient and external lifecycle ownership is refused |
| `file-menu` | 5 | Archive, large-file, trash, and junk-file commands with current-directory mutation boundaries, staged publication (TAR including zstd, ZIP, and 7z), a rename-only trash with no-clobber restore, quarantined deletion, and fail-closed GNU TAR extraction with a configurable expansion limit |
| `env-menu` | 3 | Masked session variables, explicit `PATH` deduplication, and read-only dotenv key, hygiene, and sops and static storage credential checks, with fully withheld values and no persisted state |

The release also includes the `zdx` / `zdx-menu` core router, deferred
loading of every public command, `zdx status`, the command-line insert
widgets, `zdx-plugins` with lazily loaded plugins on the plugin API v1, and
`zdx-doctor` with its exact install plan, plus the sandboxed BATS, `just`,
`uv`, pre-commit, and CI/CD toolchain. The name `zdir` and its alias `wsj` are
registered only when an ignored user-local `functions/zdir.zsh` exists, and
that file is not a release artifact; `ws-jump` supersedes it.

Every suite runs on Linux, WSL, and macOS. The suite contracts record each
platform's differences, such as GNU tar as `gtar` for `file-extract` on macOS
or refused Windows drives without DrvFs metadata on WSL, and which of them only
mocks verify.

The master catalog groups the suites by responsibility and exposes their
route tokens for filtering. Command menus use compact details, while VPN
retains its tunnel view. Rendering uses terminal foreground and background
colors, explicit plain-mode controls, and invocation-local fzf defaults. See
[`menu-design.md`](menu-design.md) for the decision and measured Linux
terminal acceptance.

Acceptance is contract-level. The full BATS suite runs on Ubuntu in the
Quality Gates workflow and on an Apple Silicon runner in the macOS workflow,
and the VPN smoke workflow brings a real test tunnel up and down on Ubuntu and
macOS runners when VPN code changes. External services and host-only behavior
remain mocked; the real-host acceptance items below remain open.

---

## Remaining work

### Security residuals

The residual-risk priorities of
[`security-assessment.md`](security-assessment.md) list what remains: the
real-host verification below, which code and tests alone cannot close.

### External data plugins

`k8s` (fixed-context port-forwards and read-only facts) and `lake` (an
rclone-backed, read-only object-storage browser with a verified, confined
download) are designed as separate plugin repositories on the plugin API v1.
They start only after four weeks of measured use show a weekly need and,
for `lake`, after the storage server enforces read-only access to
`warehouse/`, aborts incomplete multipart uploads, and versions `landing/`
and `backups/`.

### Real-host acceptance

The tests mock these boundaries, and the suite contracts list them in detail:

- WSL2 and WSL1 hosts: DrvFs metadata, Windows OpenSSH and `ssh.exe` key
  paths, `clip.exe`, and the VPN DNS hardening and networking gate;
- the `sys-wsl` review on WSL1, with interop disabled, and against a real
  `.wslconfig`;
- a real Mac: launchd, `softwareupdate`, Homebrew casks, Command Line Tools
  placeholders, Intel Macs, APFS case-sensitive volumes, pinentry prompts, a
  python.org Python installation, and native Terminal.app and iTerm2
  rendering;
- real sudo timestamp renewal by the System refresher on any host;
- real clipboards;
- live PyPI, package-manager, and linter boundaries, including an end-to-end
  Developer update;
- real archive-backend and cross-filesystem smoke tests for the File suite,
  including the trash;
- live package-manager and shell-activation behavior for the Python suite,
  including a `venv-rebuild` against a real uv-managed runtime;
- the `zdx doctor` installer with a real package manager and interactive
  `sudo`;
- `zdx-plugins` installs and updates from real HTTPS and SSH origins,
  including credential helpers, SSH agents, and signed commits; the tests use
  local bare origins;
- live GitHub writes for the Git suite: pull-request creation and checkout,
  remote branch deletion, and pushes to a real remote;
- real clones and fetches against remote hosts for the Workspace suite,
  workspace SSH aliases read from a Windows SSH configuration by `ssh.exe`,
  and BSD `mv` publication on a Mac.

No new suite should copy a legacy pattern merely to match current code. See
[`menus.md`](menus.md) for the menu audit findings.
