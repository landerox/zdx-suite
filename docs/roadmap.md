# Roadmap: ZDX (Zsh Developer Experience)

This document serves as the official project roadmap and planning guide for `ZDX`. It records the initial release baseline and catalogs future interactive suites structured by logical phases.

---

## Current release: v0.1.0

The current repository baseline is consolidated under `v0.1.0`. It freezes 251
public commands across 15 suites behind per-suite contracts and surface-parity
fixtures, with exact safety and platform boundaries documented for every
surface. See [`CHANGELOG.md`](../CHANGELOG.md) for the initial release notes
and compatibility boundaries.

Acceptance is local and contract-level. External boundaries remain mocked, and
the real-host, live-service, hardware, WSL, and macOS verification items in the
suite contracts remain open. The Workspace contract also records the controls
that remain outside its targeted hardening pass.

### Included runtime

The `v0.1.0` baseline includes the complete current suite catalog:

* **`git-menu`:** 39 repository and GitHub commands with exact plans, remote
  leases, identity checks, and post-authorization revalidation.
* **`vpn-menu`:** 22 WireGuard commands for Linux and WSL with private profiles,
  precomputed previews, least privilege, and exact mutation plans.
* **`docker-menu`:** Eight context-bound container, image, Compose, registry,
  and exact cleanup commands that use complete resource identities.
* **`sys-menu`:** 34 capability-based diagnostics, resource, maintenance,
  cleanup, dotfile, and telemetry commands, including exclusive update
  aggregation with per-step results, default continuation after ordinary
  failures, optional `--fail-fast`, and zero-timeout APT lock arbitration.
* **`ws-menu`:** 15 workspace identity, SSH, repository, migration, and
  recoverable removal commands with its remaining transactional gaps documented.
* **`file-menu`:** Ten bounded file and data commands, current-directory
  mutation boundaries, staged publication, and fail-closed GNU TAR extraction.
* **`app-menu`:** Two bounded task-discovery commands with fixed backend
  dispatch and explicit project-code authorization.
* **`ci-menu`:** Eight repository-bound GitHub Actions and exact cleanup
  commands; tag and issue ownership delegates to the Git suite.
* **`env-menu`:** Eight explicit dotenv and profile commands with passive
  parsing, fully withheld values, and private atomic state.
* **`py-menu`:** 16 commands for validated project-local environments, Python
  runtimes, packages, and isolated tools; ambient and external lifecycle
  ownership is refused.
* **`dev-menu`:** 49 project maintenance, quality, security, update, export,
  and bounded cleanup commands, with Python and Docker lifecycles delegated to
  their owners.
* **`net-menu`:** Six bounded local and remote diagnostics with fixed HTTPS
  providers and explicit throughput authorization.
* **`gpu-menu`:** One bounded NVIDIA telemetry command with explicit simulation.
* **`hf-menu`:** Five installed-backend Hub and cache commands with bounded
  records and exact recoverable cache quarantine.
* **`ai-menu`:** 28 passive inspection, quarantine, snapshot, MCP, diagnostics,
  and reviewed installed-CLI update commands.

The release also includes the `zdx` / `zdx-menu` core router, deferred loading,
`zdx-plugins`, and `zdx-doctor`, plus the sandboxed BATS, `just`, `uv`,
pre-commit, and CI/CD toolchain. Compatibility names for user-local `zdir` /
`wsj` and `zclean` implementations remain registered, but their ignored local
files are not release artifacts.

The master catalog groups these suites by responsibility and exposes their
route tokens for filtering. Command menus use compact details, while App and
VPN retain their task and tunnel views. Rendering uses terminal foreground
and background colors, explicit plain-mode controls, and invocation-local fzf
defaults. See [`menu-design.md`](menu-design.md) for the decision and measured
Linux terminal acceptance; native macOS rendering remains unverified.

---

## 🚀 Upcoming Phases & Interactive Suites

The future roadmap is structured into 4 upcoming phases, prioritizing local AI execution, HTTP endpoints testing, local database dashboards, cloud native cluster orchestration, security operations (IaC/SOPS), and remote cloud environments.

### Architecture hardening record (completed for v0.1.0)

Before expanding the suite catalog, the existing runtime was brought under the
contracts in [`development.md`](development.md) and
[`menu-spec.md`](menu-spec.md). The work was completed incrementally as a
release-quality gate:

1. **Documentation baseline:** establish ownership, loader, menu, stream,
   safety, testing, plugin, and threat-model contracts.
2. **System suite:** froze its 34-command public surface, introduced capability
   adapters, verified downloads, least-privilege execution, cleanup plans/dry
   runs, and consolidated plugin ownership. The implementation now covers
   phases 0 through 6 recorded in [`sys-menu.md`](sys-menu.md):

   - the frozen public contract, standalone loader, and capability registry;
   - portable, stream-safe host and shell diagnostics;
   - typed process, port, systemd, and launchd records with target
     revalidation;
   - explicit maximum and safe-only update plans, fail-fast APT lock
     arbitration, refusal of unverified AWS and Starship installers, and
     checksum-verified Nerd Fonts;
   - bounded cleanup, safe dotfile archives and restore, and owner-only atomic
     telemetry state;
   - argument-forwarding routing, stderr-only UI, local capability-aware
     `fzf`, command-specific completion, and `sys-plugins` delegation.

   The high-risk update, cleanup, archive, font, telemetry, and plugin-state
   paths have focused BATS coverage. Real-host smoke tests remain separate;
   Darwin routing is mocked and a real macOS verification is not yet recorded.
3. **Developer suite:** migrated. The suite now has a frozen 49-command surface
   recorded in [`dev-menu.md`](dev-menu.md) and
   `test/fixtures/dev-public-commands.tsv`:

   - public commands namespaced under `dev-*`, with the previous unprefixed
     global names kept as one-shot-warning compatibility wrappers scheduled for
     removal in v0.3.0;
   - ownership corrected: `venv-*` forwards to `py-menu`, and `clean-docker` /
     `docker-prune-all` are deprecated bridges to `docker-menu docker-clean`
     rather than a second Docker implementation;
   - public parsers run before dependency, project, or network probes, while
     menu capability annotations remain advisory; the Python `tomllib`
     capability is checked at each use rather than cached across `PATH` or
     interpreter changes;
   - `--multi`, profile save, and profile run share one effect-aware allowlist
     of independent argument-free tasks; source-rewriting, destructive, and
     nested actions are revalidated and refused before dispatch, while
     generated compiler artifacts are classified and disclosed;
   - `curl | sh` and `curl | bash` installer paths removed; host `uv`
     maintenance delegates to `sys`, ambient `pip` is never invoked, and
     Homebrew-owned TFLint updates are reported instead of executed by `dev`;
     declared Python checks use frozen/no-sync execution, project inventories
     require an installed `.venv` module and never fall back to a global,
     overlay, or ephemeral environment, and `uvx` or `npx` quality-gate
     fallbacks require `DEV_ALLOW_EPHEMERAL=1`. TFLint plugin
     initialization requires explicit `--init` authorization;
   - `dev-update-all` freezes and authorizes its aggregate scope before
     mutation, while interactive cleanup separately confirms exact targets
     immediately before removal. Dependency changes use private fingerprinted
     plans, exact invocation backups, atomic publication, and verified rollback
     on lock failure. Pre-commit revisions use a frozen private candidate and
     monotonic pin guard; every planned environment is installed before atomic
     publication, and applicable file-stage hooks run afterward. Hook findings
     and incomplete autoupdates return failure without discarding validated
     published revisions. A changed live hook config is preserved, never
     overwritten by recovery, and the original snapshot is retained for manual
     comparison;
   - every cleanup workflow freezes the root and each relative target by
     device, inode, and type, revalidates after authorization and around each
     removal, refuses `/`, `$HOME`, and changed or symlinked roots, and prunes
     Git metadata, generated dependencies, vendor trees, and nested
     repositories; discovery streams stop at one above the configured unique
     target limit, each category has the same post-combination cap, and the
     unique first-seen final plan fails closed before display or mutation when
     exceeded;
   - state, reports, profiles, backups, PyPI caches, update workspaces, and
     exports use owner-only paths, stable identity checks, and private atomic
     or no-clobber publication. Dependency export uses `uv export --locked`
     with exact group selection and never freezes an ambient environment;
   - outdated inspection pins `.venv/bin/python` with `UV_SYSTEM_PYTHON=0`;
     license policy validates the bounded JSON record schema and classifies only
     its `License` field; project metadata and dependency inventories have
     explicit size/count limits; Python/uv health is an explicit clean no-op
     for projects without a matching marker and remains strict once applicable;
   - Bandit and ShellCheck share bounded, pruned, NUL-safe discovery and batched
     execution; Ruff neutralizes inherited output paths, Pyright refuses stub
     generation, and Clippy discloses `target/` writes while protecting
     `Cargo.lock` with `--locked`; tests, coverage, and hooks use frozen no-sync
     execution;
   - audit remediation confirms or requires `--yes`; an existing `.venv` Python
     update accepts only a sole simple `X.Y` pin or the current interpreter
     minor, rejects ambiguous selection or a non-CPython environment before
     mutation, and is authorized before `uv python install --upgrade X.Y`; the
     replacement is built with a managed `X.Y` interpreter, locked-synced
     privately, identity-swapped, and either verified, restored, or retained
     for recovery, while the interpreter selection plus `pyproject.toml` and
     `uv.lock` fingerprints are revalidated across authorization, install, and
     sync boundaries;
   - write parents reject unsafe cross-UID modes, temporary roots accept only a
     safe current-EUID directory or root-owned sticky directory, and export
     holds and fingerprints destination and staging descriptors; confirmation
     prompts visibly escape user-derived control characters;
   - depth, retention, PyPI concurrency and deadline values, and boolean
     configuration are strictly bounded before arithmetic use;
   - loader, stream, record, dispatch, and legend contracts brought in line with
     `headers.md` and `menu-spec.md`, with focused contract, interface,
     alignment, cleanup, I/O, maintenance, and update-safety BATS suites.

   Live PyPI, package-manager, and linter boundaries are mocked; a real
   end-to-end update and a real macOS host remain manual verification items.
   The documented `pyproject.toml` and `.venv` transactions have verified
   rollback paths; project findings do not roll back published hook revisions.
   ZDX cannot generically reverse every side effect of an external tool, including a
   `uv python install --upgrade X.Y` global installation. Portable userspace
   identity checks cannot eliminate the final race against a hostile process
   with the same EUID or freeze every file below `.venv`. Live-network,
   real-host, and macOS acceptance remains separate.
4. **VPN suite:** migrated. The suite now has a frozen 22-command surface
   recorded in [`vpn-menu.md`](vpn-menu.md) and
   `test/fixtures/vpn-public-commands.tsv`:

   - a direct CLI mode, which did not exist: the entrypoint previously ignored
     every argument except `--help` and opened the menu instead;
   - the `fzf --preview` script that interpolated the selected record into shell
     program text, and called `sudo` from the preview, replaced by panes
     precomputed in Zsh and addressed by fzf's integer row index;
   - `sudo $EDITOR` replaced by `sudoedit`, so the editor never runs as root;
   - the resolver value written into the root-executed WSL hook now validated as
     a plain IP list and refused otherwise, closing an injection path from an
     imported profile;
   - `_vpn_confirm` split into three outcomes, so a scripted destructive command
     without `--yes` fails closed instead of silently doing nothing;
   - a four-field record format carrying the target as an opaque field that is
     revalidated immediately before dispatch, replacing data encoded into the
     command token;
   - an explicit Linux and WSL platform contract with a validated
     `VPN_CONFIG_DIR` override, owner-only validated state, the state snapshot
     moved out of the entrypoint, a first completion file, and stream, colour,
     and loader conformance;
   - private, bounded profile inputs that reject symlinks, hard links, public
     modes, oversized files, and every imported root-executed `wg-quick` hook;
     identity-and-content fingerprints around authentication; same-directory
     atomic profile, cache, restore, and report publication; and unique
     no-clobber report names;
   - exact parser/completion grammar, including `--dry-run` for bulk disconnect
     and profile rename, plus a workflow-ordered capability-aware menu whose
     per-profile labels remain semantic without color;
   - `vpn-disconnect-active` retired as a duplicate of `vpn-off`; it plus
     `vpn-status` and `vpn-public-ip` remain deprecated forwarders;
   - 128 focused BATS tests across `vpn.bats`, `vpn_contract.bats`,
     `vpn_interface.bats`, `vpn_privilege.bats`, `vpn_grammar.bats`, and
     `vpn_hardening.bats`, plus the cross-boundary regressions in
     `vpn_regressions.bats`.

   `wg`, `sudo`, `sudoedit`, and the network are mocked; a real WSL host
   verification is not yet recorded.
5. **Git suite — completed 2026-07-25:** froze the 39-command public interface,
   separated Git-private runtime behavior, removed dynamic shell construction,
   hardened local, remote, and GitHub mutations with exact plans and
   revalidation, and synchronized menu, help, direct and nested completion,
   tests, and documentation. The implemented contract and residual boundaries
   are recorded in [`git-menu.md`](git-menu.md).
6. **Workspace suite — hardening pass completed 2026-07-26:** froze the
   15-command surface in [`ws-menu.md`](ws-menu.md) and
   `test/fixtures/ws-public-commands.tsv`:

   - exact direct routing, command-menu/help/completion parity, all-command lazy
     loading, one source-derived module root, contextual `ws-remove`
     completion, and stderr-only feature UI;
   - synchronous foreground `fzf`, validated three-field rows, snapshot-checked
     selection, and clean cancellation;
   - absolute canonical `WS_BASE_DIR` and strict `platform/identity`
     descendants, checked before creation or deletion;
   - credential-redacted remote displays, propagated single and batch clone
     failures, branch/upstream object snapshots, exact fetched-object
     fast-forwarding, exact invocation-owned recovery stashes, and
     non-interactive bounded SSH probes;
   - staged key rotation with rollback, same-filesystem fingerprinted
     repository migration, and stale-branch expected-OID compare-and-delete
     with linked-worktree revalidation;
   - an exact `ws-remove` plan with `--dry-run`, `--yes`,
     content-and-metadata configuration fingerprints, atomic rewrites, and
     verified quarantine deletion; and
   - focused contract, interface, and safety regressions.

   This remains a targeted hardening milestone, not full suite migration.
   Per-command parsers, uniform dry-run and non-interactive controls, one
   transactional workspace-creation publication, external remote-rewrite
   rollback, bounded inventories, the `ws -> git` compatibility dependency,
   and real-host acceptance remain open.
7. **File suite — hardening pass implemented 2026-07-26:** froze ten public
   commands, split archive/operations/discovery/data ownership, added direct
   routing and completion, moved `fzf` to foreground private capture, bounded
   all inventories, constrained mutations below the current directory, staged
   generated outputs, and replaced broad archive extraction with a preflighted
   GNU TAR-only transaction. The contract and residual GNU portability and
   same-user race boundaries are recorded in
   [`file-menu.md`](file-menu.md). Focused tests were authored; aggregate local
   acceptance and real archive-backend smoke tests remain to be recorded.
8. **Python suite — hardening pass implemented 2026-07-26:** froze 16 canonical
   commands, limited environment ownership to validated project-local venvs,
   removed ambient `pip` and external Conda/Poetry lifecycle assumptions,
   added exact mutation plans and revalidation, bounded PyPI and tool
   inventories, and made rebuild and Poetry creation fail closed until a safe
   transaction exists. See [`py-menu.md`](py-menu.md). Focused tests were
   authored; live package-manager and shell-activation acceptance remains
   manual.
9. **Hugging Face suite — hardening pass implemented 2026-07-26:** froze five
   commands, removed implicit package bootstrap, required an installed
   compatible `huggingface_hub`, bounded inspection probes and records, made
   download modes explicit, separated structured stdout, and introduced exact
   fingerprinted cache quarantine deletion. See
   [`hf-menu.md`](hf-menu.md). Mocked coverage was authored; live Hub,
   authentication, download, and real-cache acceptance remains manual.
10. **GPU suite — hardening pass implemented 2026-07-26:** froze the
    `gpu-visualizer` command, made simulation explicit, bounded `nvidia-smi`
    probes, validated metrics and process rows, removed process-control
    actions, and aligned foreground selection, streams, completion, and lazy
    loading. See [`gpu-menu.md`](gpu-menu.md). Mocked coverage was authored;
    real multi-GPU hardware acceptance remains manual.
11. **App suite — hardening pass implemented 2026-07-26:** froze two public
    commands, replaced descriptor-derived execution strings with fixed backend
    argument vectors, bounded and fingerprinted task discovery, moved the
    picker to foreground private capture, and made every project-code
    invocation an explicit plan with dry-run and non-interactive authorization.
    See [`app-menu.md`](app-menu.md). Live task backends and cross-platform
    descriptor behavior remain manual acceptance boundaries.
12. **CI suite — hardening pass implemented 2026-07-26:** froze eight public
    commands, bound every GitHub record and endpoint to the validated current
    repository, added bounded typed JSON parsing and post-authorization
    revalidation, protected newest resources, and delegated tags and issues to
    their Git owner through compatibility adapters. See
    [`ci-menu.md`](ci-menu.md). Live GitHub mutation and remote branch-race
    acceptance remain manual.
13. **Environment suite — hardening pass implemented 2026-07-26:** froze eight
    public commands, replaced executable dotenv loading with a passive literal
    parser, fully withheld variable values from UI records, removed automatic
    directory-entry loading, and added private atomic profile and dotenv
    transactions with explicit session authorization. See
    [`env-menu.md`](env-menu.md). Clipboard and cross-platform filesystem
    behavior remain manual.
14. **Network suite — hardening pass implemented 2026-07-26:** froze six public
    commands, separated local and remote capabilities, bounded every probe and
    parsed record, restricted public-IP and throughput requests to fixed HTTPS
    providers, added a local-only dashboard, and required explicit
    authorization before bandwidth tests. See [`net-menu.md`](net-menu.md).
    Real providers, resolver variants, and network hardware remain manual.
15. **Docker suite — hardening pass implemented 2026-07-27:** froze eight
    public commands, pinned every daemon operation to a reviewed context and
    daemon identity, replaced short display targets and broad prune calls with
    complete typed IDs and exact cleanup plans, moved every picker to private
    foreground capture, and added strict Compose and registry boundaries.
    Remote mutations require explicit authorization and the `all` cleanup
    scope excludes volumes. See [`docker-menu.md`](docker-menu.md). Real
    remote contexts, Docker Desktop, rootless Docker, Podman compatibility,
    image execution, and cross-platform Compose remain manual acceptance
    boundaries.
16. **AI suite — hardening pass implemented 2026-07-28:** froze the supported
    assistant-maintenance surface, preserved durable conversations and project
    state during cleanup, constrained project sweeps to exact reviewed targets,
    quarantined eligible targets instead of recursively deleting them, added
    private manifest-backed configuration snapshots, made log and MCP
    inspection passive and bounded, replaced the retired assistant executable
    with Antigravity, and constrained every update entry point to an installed,
    fingerprinted official self-updater with dry-run, confirmation, and
    post-update validation.
    See [`ai-menu.md`](ai-menu.md). Assistant-specific layout changes,
    upstream latest-release integrity, quarantine retention, and real-host CLI
    behavior remain manual acceptance boundaries.
17. **Suite catalog closure:** all 15 built-in suites now have frozen public
   surfaces, explicit contracts, and surface-parity fixtures. Workspace remains
   a documented targeted hardening pass rather than a claim of full migration.
   Frozen command names do not imply identical capture controls: Git's nested
   pickers retain local capture implementations, and the core plugin manager
   retains its documented legacy capture and lifecycle gaps. Shared rendering
   controls do not close those separate boundaries.
18. **Core follow-up:** remove remaining compatibility-only coupling when its
   consumers can move without breaking the frozen public interfaces.

No new suite should copy a legacy pattern merely to match current code. See
[`menus.md`](menus.md) for the audit findings and staged migration notes.

### 🧠 Phase 2: AI Execution, APIs & Database Dashboards (v0.2.0 - Next Milestone)

*Focus: Bringing LLMs, REST/gRPC clients, and local databases directly to the command line to boost backend and data development workflows.*

* **`ollama-menu` (AI Engineering):**
  - **Local LLM Manager:** Interactively list, pull (`ollama pull`), and run local models.
  - **Runner Controls:** Monitor model memory allocation, configure temperature/context parameters, and terminate active model runs.
* **`prompt-menu` (AI Engineering):**
  - **Prompt Templates Library:** Fuzzy-search a catalog of system prompts, preview their structures, and copy them to clipboard or pipe them to other commands.
* **`api-menu` (Interactive HTTP Client - NEW):**
  - **FZF HTTP Client:** Discover and execute `.http` / `.rest` files found in the workspace (standard VS Code HTTP format).
  - **Context-Aware Headers:** Automatically load authentication tokens or API keys from active `env-menu` profiles.
  - **Interactive Viewer:** Run requests, select request variables, format JSON responses with `jq`, and tail response bodies.
* **`db-menu` (Database Dashboards):**
  - **Unified Database Client:** A unified FZF frontend for managing local/remote databases:
    - `sqlite-menu`: Browse local databases, inspect table schemas, and execute quick SQL queries.
    - `postgres-menu` & `mysql-menu`: Monitor running queries, check database sizes, and list tables.
    - `redis-menu`: Search keys, inspect database types, and monitor live Redis calls.
  - **Context-Aware Dotenv Auto-config:** Auto-extract connection URIs, hosts, and credentials from active `env-menu` contexts or loaded `.env` profiles.

---

### 💾 Phase 3: Local SaaS Backends, Kubernetes & Data Engineering (v0.3.0 - Planned)

*Focus: Seamlessly coordinate local cloud-native stack services, orchestrate Kubernetes namespaces, and run data models.*

* **`supabase-menu` (SaaS Dev):**
  - **Supabase Manager:** Control local supabase environments, run migrations, database seeding, and deploy edge functions.
* **`k8s-menu` (Kubernetes):**
  - **Context & Namespace Switcher:** Swap active cluster contexts and target namespaces.
  - **Pod logs & shell:** Search pods in namespaces, stream real-time logs, and drop into container shells.
  - **Cleanup tool:** Safely delete evicted, failed, or problematic pods.
* **`helm-menu` (Kubernetes):**
  - **Helm Manager:** List active releases, inspect values, rollback to previous revisions, and search charts.
* **`dbt-menu` & `spark-menu` (Data Engineering):**
  - **DBT Runner & Spark Monitor:** Interactively execute dbt models, review compile history, inspect logs, and monitor Spark executor statistics.

---

### 🔒 Phase 4: IaC, Secrets Encryption & Automation (v0.4.0 - Planned)

*Focus: Scaling local infrastructure automation, securing secrets inside the git tree, and managing playbook flows.*

* **`tf-menu` (Terraform / OpenTofu):**
  - **State Explorer:** Browse resources in Terraform states and target specific items for taint or destruction.
  - **Workspace Manager:** Swap active workspaces and environments.
* **`sops-menu` (Secrets Encryption - NEW):**
  - **Interactive SOPS Encryptor:** Encrypt and decrypt `.env` and `.yaml` secrets files in-place using SOPS (Secrets Operational Support) with age, AWS KMS, or GPG.
  - **Key Manager:** List local GPG/SSH/age keys and verify configurations before committing secrets.
* **`ansible-menu` (Automation):**
  - **Ansible Runner:** Fuzzy-search and run playbooks against dynamic inventories, and encrypt/decrypt values using Ansible Vault.

---

### ☁️ Phase 5: Public Cloud Workspace Integrations (v0.5.0 - Planned)

*Focus: Dedicated workspace suites for cloud provider operations, storage buckets, and remote VMs. Kept as the final phase due to API and credential complexities.*

* **`aws-menu` (Cloud Ops):**
  - **Credential profile switcher:** Swap active AWS CLI profiles and session tokens.
  - **S3 Browser:** List, search, and download files from S3 buckets.
  - **EC2 & SSM:** Check VM status and start secure SSM tunnels.
* **`gcp-menu` (Cloud Ops):**
  - **Project Switcher:** Swap active Google Cloud projects.
  - **GKE & GCS:** Inspect Kubernetes clusters and browse Cloud Storage buckets.
