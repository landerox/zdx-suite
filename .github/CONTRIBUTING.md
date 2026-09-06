# Contributing to ZDX

Thanks for your interest. This is a small but opinionated project; the
quickest way to land a change is to follow these conventions.

## Before you start

- Read **[AGENTS.md](../AGENTS.md)** — the source of truth for code rules,
  suite architecture, and validation. Don't skip it.
- For deeper context check [`docs/`](../docs/). Start with
  [`development.md`](../docs/development.md) (suite engineering contract),
  [`suites.md`](../docs/suites.md) (ownership map), and
  [`menu-spec.md`](../docs/menu-spec.md) (canonical menu contract).

## Quick checklist

1. **Branch**: `feat/<short-topic>`, `fix/<short-topic>`,
   `docs/<short-topic>`, `chore/<short-topic>`, or `refactor/<short-topic>`.
2. **Code**: zsh-first. Use the suite's existing prefix (`_<suite>_*`) and
   helpers. Public names in kebab-case.
3. **Validate**: `just check` (first rejects a stale `uv.lock` without
   rewriting it, then runs `zsh -n`, every file-stage pre-commit check, the
   locked Python dependency audit, and the complete BATS suite). It must be
   green before opening the PR.
4. **Commit message**: [Conventional Commits](https://www.conventionalcommits.org)
   with a suite scope — e.g. `feat(git): add PR checkout flow`.
   Valid scopes: `git`, `vpn`, `docker`, `sys`, `dev`, `init`, `docs`,
   `repo`, and `deps`. Use `deps` for reviewed dependency and toolchain
   maintenance.
5. **DCO sign-off**: every commit MUST include a `Signed-off-by:` trailer
   asserting you have the legal right to contribute the change under the
   project's [DCO](https://developercertificate.org/). Use `git commit -s`
   (or `git commit -s --amend` if you forgot one). The `dco` CI check
   blocks merges that miss a sign-off.
6. **PR description**: explain *why*, not *what* (the diff already shows
   what). The PR template will load automatically.

## Local setup

Install Git, Zsh, BATS, Just, and uv on the host before running repository
checks. `just sync` installs the locked Python contributor tools; pre-commit
installs its versioned hook environments on first use.

```sh
# Synchronize the locked Python contributor environment
just sync

# Install commit, commit-message, and pre-push hooks (one-time)
just pre-commit-install

# Validate before every commit / PR
just check
```

The pre-push hook runs that same complete aggregate automatically. GitHub's
Quality Gates workflow delegates to it as well, so changes to that aggregate
start in the `Justfile`.

## Modifying workflows

Workflows under `.github/workflows/` consume third-party Actions pinned by
commit SHA. When you change a workflow or upgrade a pinned action:

1. **Read the upstream README** for the action you are touching. Step
   dependencies (for example `tim-actions/dco` requires
   `tim-actions/get-pr-commits` to run first and pipe its output via the
   `commits:` input) are not catchable by `actionlint` or `zizmor` — they
   are semantic and need human review.
2. **Optional smoke test**: `just check-ci <workflow-name>` runs the
   workflow locally via [`act`](https://github.com/nektos/act) against a
   synthesized event. Useful for syntactic and runtime errors. Workflows
   that depend on real PR context (DCO commit list, release tag,
   `GITHUB_TOKEN` scopes) may behave differently locally than in CI;
   treat it as a smoke test, not a guarantee.
3. **SHA-pin every action** with a `# vX.Y.Z` annotation, per repo policy.
   `zizmor` enforces this in CI.

## Reporting issues

- **Bugs**: open a [bug report](ISSUE_TEMPLATE/bug_report.yml).
- **Feature ideas**: open a [feature request](ISSUE_TEMPLATE/feature_request.yml).
- **Security**: see [SECURITY.md](SECURITY.md). Do not file public issues
  for vulnerabilities.

## Project continuity

ZDX is currently maintained as a personal hobby project (bus factor of 1). To ensure long-term availability and continuity:

- If the primary maintainer becomes inactive or unreachable for more than 6 months, community members are encouraged to fork the repository.
- The community can nominate a new maintainer. If consensus is reached, the fork may be designated as the new active upstream repository.
- Under the MIT License, users have full rights to copy, modify, and distribute forks of the project.

## Accessibility guidelines

To ensure ZDX remains usable for all developers, including those using screen readers or assistive technologies:

- **Terminal Contrast**: Avoid hardcoded ANSI colors that may clash with different terminal color schemes (light or dark backgrounds). Use standard terminal color variables.
- **Screen Reader Support**: All interactive `fzf` menus must output descriptive headers and clearly labeled prompt strings so screen readers can parse the current context.
- **Keyboard Navigation**: Ensure all features are fully accessible via keyboard shortcuts, conforming to standard terminal workflows.
- **Documentation**: Any image or animation in the documentation must include descriptive alt text.

## Code of conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). By
participating you agree to abide by its terms.
