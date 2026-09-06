# Repository configuration

This directory contains repository-owned configuration that its consumers can
load through an explicit path.

| Path | Consumer |
| --- | --- |
| `markdownlint.yaml` | The pre-commit Markdownlint hook and `dev-run-markdownlint` |
| `zdx/config.zsh.example` | The installer and the documented user-configuration workflow |

Some files must remain in their canonical discovery locations:

| Path | Why it stays outside `.config` |
| --- | --- |
| `.pre-commit-config.yaml` | Pre-commit autodiscovery and the Developer suite transaction contract |
| `pyproject.toml`, `uv.lock`, `.python-version` | Python and uv project discovery |
| `Justfile` | Default `just` discovery |
| `.gitignore`, `.gitattributes` | Git path and attribute semantics |
| `.github/` | GitHub Actions, templates, and repository metadata discovery |
| `AGENTS.md`, `CLAUDE.md`, `GEMINI.md` | Assistant instruction discovery |

The reproducible `.demo/demo.tape` and its isolated `.demo/git-demo.conf`
fixture remain next to the generated asset they own. Gitleaks, Actionlint,
Zizmor, and ShellCheck currently use their defaults or inline pre-commit
settings, so the repository does not carry empty standalone configuration files
for them.
