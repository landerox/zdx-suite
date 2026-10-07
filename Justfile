### Justfile for zdx
# Common tasks for linting and validating Zsh sources.
# Run `just` (no args) to list available recipes.

set shell := ["zsh", "-cu"]
# Pass recipe arguments as positional parameters, so `"$@"` keeps arguments
# with spaces intact. The global setting works with just 1.21 (Ubuntu 24.04),
# which predates the per-recipe `[positional-arguments]` attribute.
set positional-arguments := true

# Default recipe: show the recipe list.
default:
    @just --list

# Parse-check every tracked .zsh file with `zsh -n`.
lint:
    #!/usr/bin/env zsh
    set -u
    typeset -a files
    files=("${(@f)$(git ls-files '*.zsh')}")
    if (( ${#files} == 0 )); then
        print -u2 "no .zsh files tracked"
        exit 0
    fi
    typeset -i failed=0
    for f in "${files[@]}"; do
        [[ -f "$f" ]] || continue
        if ! zsh -n -- "$f" 2>&1; then
            print -u2 "FAIL: $f"
            (( failed++ ))
        fi
    done
    if (( failed > 0 )); then
        print -u2 "$failed of $#files files failed the parse check"
        exit 1
    fi
    print "$#files files OK"

# Run BATS test suite.
test:
    #!/usr/bin/env zsh
    if ! command -v bats >/dev/null 2>&1; then
        print -u2 "bats is not installed; install bats-core (apt install bats, or brew install bats-core on macOS)."
        exit 1
    fi
    bats --print-output-on-failure test/

# Run the complete local and CI quality gate.
check: lock-check lint pre-commit-run audit test

# Refuse stale project metadata without rewriting the committed lockfile.
lock-check:
    uv lock --check

# Format .zsh sources with shfmt (skipped if shfmt is not installed).
fmt:
    #!/usr/bin/env zsh
    if ! command -v shfmt >/dev/null 2>&1; then
        print -u2 "shfmt not installed; skipping"
        exit 0
    fi
    typeset -a files=("${(@f)$(git ls-files '*.zsh')}")
    (( ${#files:#} == 0 )) || shfmt -ln=bash -i 2 -ci -bn -w -- "${(@)files:#}"

# Dry-run of `fmt`: show files that would change.
fmt-check:
    #!/usr/bin/env zsh
    if ! command -v shfmt >/dev/null 2>&1; then
        print -u2 "shfmt not installed; skipping"
        exit 0
    fi
    typeset -a files=("${(@f)$(git ls-files '*.zsh')}")
    (( ${#files:#} == 0 )) || shfmt -ln=bash -i 2 -ci -bn -d -- "${(@)files:#}"

# Scan the working tree for committed secrets via gitleaks (no-op if missing).
secrets:
    #!/usr/bin/env zsh
    if ! command -v gitleaks >/dev/null 2>&1; then
        print -u2 "gitleaks not installed; skipping"
        exit 0
    fi
    gitleaks detect --no-banner --redact --source .

# Checks, per public command, the function, dispatcher arm, menu record,
# --help entry, completion entry and binding, lazy stub, interactive
# allowlist, contract doc, and user guide, plus each suite's registrations.
# The table goes to stdout; each missing surface goes to stderr with a file
# hint. A user-guide gap is a warning unless --strict is given.
#
# Usage: just surfaces [--strict] [SUITE...]
# Report which public-command surfaces exist (read-only parity check).
surfaces *args:
    @zsh -f scripts/command-surface.zsh check "$@"

# Adds the fixture row, a function stub in MODULE, and the dispatcher arm,
# menu record, --help entry, completion entry and binding, allowlist entry,
# and lazy stub where the suite uses them, after --after COMMAND (default:
# the module's last menu command). Then prints the manual checklist with
# file:line hints. --dry-run prints the planned edits and writes nothing.
# See docs/development.md, "Adding a public command".
#
# Usage: just new-command [--dry-run] SUITE COMMAND MODULE RISK
#          --label TEXT --description TEXT [--after COMMAND]
#          [--capability VALUE | --privilege VALUE]
# Scaffold a public command across its uniform surfaces.
new-command *args:
    @zsh -f scripts/command-surface.zsh new "$@"

# Install / refresh dev dependencies via uv (commitizen, pre-commit, pip-audit).
sync:
    uv sync --locked

# Install commit, commit-message, and pre-push hooks into .git/hooks.
pre-commit-install:
    uv run --locked pre-commit install --install-hooks

# Run every file-stage pre-commit hook against the full tree.
pre-commit-run:
    uv run --locked pre-commit run --all-files

# Smoke-run a GitHub Actions workflow locally with `act` (skipped if act or
# Docker are missing). Catches syntactic and runtime errors in workflows
# before pushing — useful when modifying anything under .github/workflows/.
# Synthesizes a pull_request event payload, so workflows that depend on real
# PR context (e.g. DCO commit list, release tag, GITHUB_TOKEN scopes) may
# behave differently locally than in CI. Treat it as a smoke test, not a
# guarantee.
#
# Usage:
#   just check-ci            # runs lint.yml (default)
#   just check-ci dco        # runs dco.yml
#   just check-ci release    # runs release.yml
#
# Requires: nektos/act + a running Docker daemon.
check-ci workflow="lint":
    #!/usr/bin/env zsh
    set -euo pipefail
    if ! command -v act >/dev/null 2>&1; then
        print -u2 "act not installed (https://github.com/nektos/act); skipping"
        exit 0
    fi
    if ! docker info >/dev/null 2>&1; then
        print -u2 "Docker daemon not reachable; skipping"
        exit 0
    fi
    wf=".github/workflows/{{workflow}}.yml"
    if [[ ! -f "$wf" ]]; then
        print -u2 "workflow not found: $wf"
        exit 1
    fi
    print "running act on $wf"
    act pull_request -W "$wf" --pull=false

# The exported requirements are fully pinned and hashed, so `--disable-pip`
# audits them directly: no throwaway virtualenv, no unpinned download of
# `pip`/`setuptools`/`wheel`, and the vulnerability service is the only
# network dependency. `--quiet` keeps the 400-line export off the gate log.
# Audit Python dev dependencies for known CVEs (pip-audit on exported reqs).
audit:
    #!/usr/bin/env zsh
    set -euo pipefail
    req=$(mktemp "${TMPDIR:-/tmp}/pip-audit.XXXXXX")
    trap 'rm -f "$req"' EXIT
    uv export --locked --quiet --format requirements-txt --output-file "$req"
    uv run --locked pip-audit --disable-pip --requirement "$req"

# Regenerate the README GIF and PNG from real menus in a private workspace.
# See docs/demo.md for prerequisites, isolation, and the visible sequence.
demo:
    #!/usr/bin/env -S zsh -f
    zsh -f .demo/record.zsh

# Install vhs + ttyd + ffmpeg: Homebrew on macOS, or the charm.sh apt repo on
# Debian and Ubuntu (requires sudo). Idempotent.
demo-install:
    #!/usr/bin/env zsh
    set -euo pipefail

    if command -v vhs >/dev/null 2>&1 \
        && command -v ttyd >/dev/null 2>&1 \
        && command -v ffmpeg >/dev/null 2>&1; then
      print "All demo tools already installed:"
      print "  vhs:    $(vhs --version 2>&1 | head -1)"
      print "  ttyd:   $(ttyd --version 2>&1 | head -1)"
      print "  ffmpeg: $(ffmpeg -version 2>&1 | head -1)"
      exit 0
    fi

    if [[ "$OSTYPE" == darwin* ]]; then
      if ! command -v brew >/dev/null 2>&1; then
        print -u2 "Homebrew is required on macOS; see https://brew.sh, then retry."
        exit 1
      fi
      print "Installing vhs, ttyd and ffmpeg with Homebrew..."
      brew install vhs ttyd ffmpeg
      exit 0
    fi
    if ! command -v apt-get >/dev/null 2>&1; then
      print -u2 "This recipe supports Homebrew and APT; install vhs, ttyd, and ffmpeg with your package manager."
      exit 1
    fi

    print "Adding charm.sh apt repo (one-time)..."
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.charm.sh/apt/gpg.key \
      | sudo gpg --dearmor --yes -o /etc/apt/keyrings/charm.gpg
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" \
      | sudo tee /etc/apt/sources.list.d/charm.list >/dev/null

    print "Installing vhs, ttyd and ffmpeg..."
    sudo apt update
    sudo apt install -y vhs ttyd ffmpeg

    print ""
    print "Installation complete:"
    print "  vhs:    $(vhs --version 2>&1 | head -1)"
    print "  ttyd:   $(ttyd --version 2>&1 | head -1)"
    print "  ffmpeg: $(ffmpeg -version 2>&1 | head -1)"
