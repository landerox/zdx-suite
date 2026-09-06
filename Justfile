### Justfile for zdx
# Common tasks for linting and validating Zsh sources.
# Run `just` (no args) to list available recipes.

set shell := ["zsh", "-cu"]

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
        print -u2 "$failed file(s) failed parse check"
        exit 1
    fi
    print "$#files file(s) OK"

# Run BATS test suite.
test:
    #!/usr/bin/env zsh
    if ! command -v bats >/dev/null 2>&1; then
        print -u2 "bats is not installed. Install via: apt install bats"
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
    git ls-files '*.zsh' | xargs -r shfmt -ln=bash -i 2 -ci -bn -w

# Dry-run of `fmt`: show files that would change.
fmt-check:
    #!/usr/bin/env zsh
    if ! command -v shfmt >/dev/null 2>&1; then
        print -u2 "shfmt not installed; skipping"
        exit 0
    fi
    git ls-files '*.zsh' | xargs -r shfmt -ln=bash -i 2 -ci -bn -d

# Scan the working tree for committed secrets via gitleaks (no-op if missing).
secrets:
    #!/usr/bin/env zsh
    if ! command -v gitleaks >/dev/null 2>&1; then
        print -u2 "gitleaks not installed; skipping"
        exit 0
    fi
    gitleaks detect --no-banner --redact --source .

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
    req=$(mktemp -t pip-audit-XXXXXX.txt)
    trap 'rm -f "$req"' EXIT
    uv export --locked --quiet --format requirements-txt --output-file "$req"
    uv run --locked pip-audit --disable-pip --requirement "$req"

# Regenerate the README GIF and PNG from real menus in a private workspace.
# See docs/demo.md for prerequisites, isolation, and the visible sequence.
demo:
    #!/usr/bin/env -S zsh -f
    zsh -f .demo/record.zsh

# Install vhs + ttyd + ffmpeg via charm.sh apt repo. Idempotent. Requires sudo.
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

# Retag VERSION at HEAD; release.yml workflow regenerates the GitHub release.
retag version:
    #!/usr/bin/env zsh
    # Deletes the existing tag and GitHub release (remote + local), then
    # recreates the tag at the current HEAD and pushes it. The
    # `.github/workflows/release.yml` workflow picks up the tag push,
    # extracts notes from the matching CHANGELOG.md section, generates
    # the source tarball plus SHA-256, and publishes the release
    # atomically. The release title is the tag name itself.
    #
    # Requirements:
    #   - Working tree clean.
    #   - CHANGELOG.md has a `## [X.Y.Z]` section matching VERSION.
    #   - gh CLI authenticated with `workflow` scope.
    #
    # Example: just retag v0.1.0
    set -euo pipefail

    tag='{{version}}'
    if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
      print -u2 "ERROR: '$tag' is not a SemVer tag (expected vMAJOR.MINOR.PATCH)"
      exit 2
    fi

    if [[ -n "$(git status --porcelain)" ]]; then
      print -u2 "ERROR: working tree not clean - commit or stash first"
      exit 2
    fi

    version="${tag#v}"
    if ! awk -v marker="## [${version}]" 'BEGIN{f=0} index($0, marker) == 1 { f=1; exit } END{ exit !f }' CHANGELOG.md; then
      print -u2 "ERROR: CHANGELOG.md has no '## [${version}]' section. Add release notes first."
      exit 2
    fi

    head=$(git rev-parse HEAD)
    head_short=$(git rev-parse --short HEAD)
    print "Retag $tag -> $head_short"

    if gh release view "$tag" >/dev/null 2>&1; then
      gh release delete "$tag" --cleanup-tag --yes
      print "  deleted GitHub release and remote tag"
    fi

    if git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
      git tag -d "$tag" >/dev/null
      print "  deleted local tag"
    fi

    git tag -a "$tag" -m "$tag" "$head"
    git push origin "$tag"
    print "  pushed new tag — release.yml will publish the release"

    print ""
    print "Done: $tag = $head_short"
    print "Watch the workflow:  gh run watch --repo \$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
