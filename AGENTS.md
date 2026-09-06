# AGENTS.md — System Instructions for AI Assistants

> **Target Audience:** Claude Code, Codex CLI, Antigravity CLI, OpenCode, Copilot CLI, etc.

This document serves as the root system instruction for any AI agent interacting with this repository. You must read and follow the constraints below before modifying any files.

## 📂 Source of Truth: The `docs/` Directory

Do not guess architectural patterns or rely on external general Zsh knowledge. The strict, repository-specific rules are documented in the `docs/` folder. You **MUST** consult these documents when working on their respective domains:

- **[`docs/suites.md`](docs/suites.md)**: Sitemap of every suite in the repo. Read this to understand where features belong, how they are grouped, and entry points.
- **[`docs/development.md`](docs/development.md)**: The **canonical suite engineering contract**. Read this before changing architecture, loaders, public commands, streams, dependencies, platform behavior, destructive actions, privileges, downloads, persisted state, or completions.
- **[`docs/menu-spec.md`](docs/menu-spec.md)**: The **canonical normative specification** for building interactive menus. You must follow the helper signatures, fzf presets, and dispatch patterns exactly as described here.
- **[`docs/menu-design.md`](docs/menu-design.md)**: The presentation decision and measured rendering behavior, including terminal compatibility and remaining manual acceptance. Explanatory context; `menu-spec.md` remains normative.
- **[`docs/menus.md`](docs/menus.md)**: Descriptive audit and migration notes derived from the current Git/System menus. Note: `menu-spec.md` overrides this.
- **[`docs/headers.md`](docs/headers.md)**: Strict rules for file headers, docblocks, idempotency guards, and the sourced-or-executed pattern.
- **[`docs/security-assessment.md`](docs/security-assessment.md)**: Consolidated threat model and assurance case, including current controls, residual gaps, and maintenance triggers. Update this whenever a new surface, control, or threat appears.
- **[`docs/plugins.md`](docs/plugins.md)**: The **runtime contract for user-defined plugins**. Custom plugins must adhere to this specification (layout, naming conventions, namespace protection, safe loader integration, and the AI assistant scaffolding guide/boilerplate).
- **[`docs/roadmap.md`](docs/roadmap.md)**: The official project roadmap, version milestones, and pending features.
- **[`docs/testing.md`](docs/testing.md)**: Guide to BATS (Bash Automated Testing System) unit testing architecture, test layout, sandbox isolation environment, and mocking practices.
- **[`docs/installation.md`](docs/installation.md)**: The local installer contract, reviewed-source boundary, supported paths, confirmation, configuration publication, manual shell activation, and update ownership. Read it before changing bootstrap or installation guidance.
- **[`docs/demo.md`](docs/demo.md)**: The README demo transcript, isolated recording workflow, and artifact checks. Consult it when changing the demo or its documentation.
- **[`docs/git-menu.md`](docs/git-menu.md)**: Public contract for the Git suite — frozen command surface, exact routing, completion grammar, mutation plans, remote leases, and GitHub safety model.
- **[`docs/sys-menu.md`](docs/sys-menu.md)**: Public contract, capability runtime, and staged Linux, WSL, and macOS refactor plan for the System suite.
- **[`docs/vpn-menu.md`](docs/vpn-menu.md)**: Public contract for the VPN suite — frozen command surface, platform contract, privilege model, four-field record format, precomputed preview design, and WSL hardening validation.
- **[`docs/ws-menu.md`](docs/ws-menu.md)**: Public contract for the Workspace suite — frozen command surface, routing, completion, path boundaries, Git/SSH transactions, and residual safety limits.
- **[`docs/dev-menu.md`](docs/dev-menu.md)**: Public contract for the Developer suite — frozen command surface, ownership boundaries and delegations, cleanup safety model, remote-code policy, and persisted-state rules.
- **[`docs/file-menu.md`](docs/file-menu.md)**: Public contract for the File suite — frozen command surface, current-directory mutation boundary, staged publication, and fail-closed GNU TAR extraction.
- **[`docs/app-menu.md`](docs/app-menu.md)**: Public contract for the App suite — frozen command surface, bounded descriptor discovery, fixed backend dispatch, and executable-project-code authorization.
- **[`docs/ci-menu.md`](docs/ci-menu.md)**: Public contract for the CI suite — frozen command surface, repository-bound GitHub records, exact remote mutation plans, and Git ownership adapters.
- **[`docs/env-menu.md`](docs/env-menu.md)**: Public contract for the Environment suite — passive dotenv parsing, secret masking, private atomic profiles, and explicit session mutation.
- **[`docs/py-menu.md`](docs/py-menu.md)**: Public contract for the Python suite — frozen command surface, project-local environment ownership, package and tool backends, and fail-closed lifecycle rules.
- **[`docs/hf-menu.md`](docs/hf-menu.md)**: Public contract for the Hugging Face suite — frozen command surface, installed-backend policy, bounded Hub records, and exact cache deletion.
- **[`docs/net-menu.md`](docs/net-menu.md)**: Public contract for the Network suite — frozen command surface, bounded local and remote diagnostics, provider privacy, and throughput authorization.
- **[`docs/gpu-menu.md`](docs/gpu-menu.md)**: Public contract for the GPU suite — frozen command surface, explicit simulation, bounded NVIDIA probes, foreground job-control behavior, and telemetry validation.
- **[`docs/docker-menu.md`](docs/docker-menu.md)**: Public contract for the Docker suite — frozen command surface, daemon-context binding, typed resource records, exact cleanup plans, and Compose trust boundaries.
- **[`docs/ai-menu.md`](docs/ai-menu.md)**: Public contract for the AI suite — frozen command surface, recoverable cache quarantine, private snapshots, passive NVM-aware discovery, reviewed installed-CLI updates, and MCP inspection controls.
- **[`docs/user-guide.md`](docs/user-guide.md)**: The end-user workflows and usage guide for all interactive suites and utility commands (including `git-menu`, `vpn-menu`, `docker-menu`, `sys-menu`, `ws-menu`, `file-menu`, `app-menu`, `ci-menu`, `env-menu`, `py-menu`, `dev-menu`, `net-menu`, `gpu-menu`, `hf-menu`, `ai-menu`, the `zdx` master control, `zdx doctor` / `zdx-doctor`, and `zdx-plugins`).

## 🛠️ Core AI Operational Mandates

When executing a task or generating code, adhere strictly to the following parameters:

1. **Zsh Exclusivity:** Write Zsh-first. Do not use Bash-isms or attempt to write POSIX-sh compliant code if a native Zsh feature is cleaner. Rely on `local` and arrays. The installer implementation is Zsh; `scripts/install.sh` is a minimal Bash 3.2 compatibility launcher only. Keep installation orchestration in `scripts/install.zsh`; `scripts/install_fs.py` is the narrow Python 3.8+ filesystem helper for validation and atomic no-clobber publication. BATS remains a Bash test harness.
2. **Naming Conventions:** Use `kebab-case` for public commands. Private helpers must stay namespaced with their suite-specific prefix (e.g., `_zdx_*`, `_ai_*`, `_git_*`, `_vpn_*`, `_docker_*`, `_sys_*`, `_file_*`, `_app_*`, `_ci_*`, `_env_*`, `_py_*`, `_dev_*`, `_net_*`, `_gpu_*`, `_hf_*`).
3. **Data vs. UI Streams:** Function `stdout` is strictly for data. All UI messages, warnings, or prompts must go to `stderr`. Use existing suite-specific logging helpers (`_..._info`, `_..._error`, `_..._warn`, `_..._success`).
4. **Safety & Security:** Never hardcode credentials. For destructive commands (e.g., deletions, cleanups), you MUST implement dry-run support or explicit `read -q` confirmations.
5. **Validation:** Before declaring a task complete, run `just check` — it checks lockfile freshness, runs `zsh -n` on every tracked `.zsh` file, executes all file-stage pre-commit hooks (including gitleaks, markdownlint, actionlint, zizmor, and shellcheck), audits the locked Python dependencies, and runs the full BATS suite. Syntax-check new untracked Zsh files explicitly until they enter the tracked inventory. The conventional-commit scope guard runs separately at `commit-msg`; the commit and DCO requirements below still apply.
6. **Git Protocol:** Follow conventional commits with a valid scope: `git`, `vpn`, `docker`, `sys`, `dev`, `init`, `docs`, `repo`, `deps`. Example: `feat(git): add branch cleanup`. Branches follow `feat/`, `fix/`, `docs/`, `refactor/`, `chore/`. Every commit MUST include a Developer Certificate of Origin sign-off (`Signed-off-by:` trailer) — use `git commit -s`. The DCO status check is enforced by branch protection. **CRITICAL:** Do NOT execute `git add`, `git commit`, or `git push` commands yourself unless explicitly requested by the USER. Instead, propose the command and the conventional commit message for the USER to execute.
7. **Language Preference:** Converse with the user in Spanish. However, all generated code, comments, documentation, commit messages, and PR templates must be written in English.
8. **Pull Request Automation:** When requested to create a Pull Request, complete the pull request template in English and save it as a `.txt` file inside the `.tmp/` directory of the workspace.

If you are unsure of how to implement a feature, refer back to the `docs/` folder or search for existing patterns within the `functions/` directory before writing novel logic.
