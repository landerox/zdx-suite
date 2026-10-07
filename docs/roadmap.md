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
| `py-menu` | 16 | Validated project-local environments, uv-managed Python runtimes, project packages, and isolated tools; ambient and external lifecycle ownership is refused |
| `file-menu` | 5 | Archive, large-file, trash, and junk-file commands with current-directory mutation boundaries, staged publication, a rename-only trash with no-clobber restore, quarantined deletion, and fail-closed GNU TAR extraction |
| `env-menu` | 3 | Masked session variables, explicit `PATH` deduplication, and read-only dotenv key and hygiene checks, with fully withheld values and no persisted state |

The release also includes the `zdx` / `zdx-menu` core router, deferred
loading, `zdx status`, the command-line insert widgets, `zdx-plugins`, and
`zdx-doctor`, plus the sandboxed BATS, `just`,
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

### Git presentation and output conformance

[`output-spec.md`](output-spec.md) and the shared-presentation rules in
[`menu-spec.md`](menu-spec.md) define one look for every suite. System,
Developer, Python, VPN, File, Environment, and the master menu follow them.
Git is the remaining suite, and its pass applies the output-spec adoption
checklist:

- mark unavailable menu rows with the canonical `○` form; Git rows still use
  the text-only `(missing: …)` and `(unavailable: …)` annotations;
- route `_git_label` through `_zdx_ui_label`;
- replace the 14 remaining `(s)` counted-noun sites with `_zdx_count_noun`;
- rebuild the `clean-branches` and `clean-remote-merged` workflows on the core
  step services.

`test/menu_presentation.bats` excludes Git from the availability-mark check
until this pass lands.

### Python lifecycle

`venv-rebuild` and Poetry environment creation fail closed. Each needs a
transactional, rollback-safe implementation before it can mutate an
environment; see [`py-menu.md`](py-menu.md).

### Core coupling

The `_tk_*` helpers in `functions.zsh` keep a legacy prefix. Move them to the
`_zdx_*` owner prefix when their consumers, including the plugin template, can
change without breaking the frozen public interfaces.

### Security residuals

The ordered implementation gaps live in the residual-risk priorities of
[`security-assessment.md`](security-assessment.md). They require code and
tests, not documentation-only mitigations.

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
- real archive-backend smoke tests for the File suite;
- live package-manager and shell-activation behavior for the Python suite;
- `zdx-plugins` installs and updates from real HTTPS and SSH origins,
  including credential helpers, SSH agents, and signed commits; the tests use
  local bare origins.
- real clones and fetches against remote hosts for the Workspace suite,
  workspace SSH aliases read from a Windows SSH configuration by `ssh.exe`,
  and BSD `mv` publication on a Mac.

No new suite should copy a legacy pattern merely to match current code. See
[`menus.md`](menus.md) for the menu audit findings.
