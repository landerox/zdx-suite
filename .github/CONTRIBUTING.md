# Contributing to ZDX

Thanks for your interest. This is a small but opinionated project; the
quickest way to land a change is to follow these conventions.

## Before you start

- Read **[AGENTS.md](../AGENTS.md)** — the source of truth for code rules,
  suite architecture, and validation. Don't skip it.
- For deeper context check [`docs/`](../docs/). Start with
  [`development.md`](../docs/development.md) (suite engineering contract),
  [`suites.md`](../docs/suites.md) (ownership map),
  [`menu-spec.md`](../docs/menu-spec.md) (canonical menu contract), and
  [`output-spec.md`](../docs/output-spec.md) (canonical command-output
  contract).

## Quick checklist

1. **Branch**: `feat/<short-topic>`, `fix/<short-topic>`,
   `docs/<short-topic>`, `chore/<short-topic>`, or `refactor/<short-topic>`.
2. **Code**: zsh-first. Use the suite's existing prefix (`_<suite>_*`) and
   helpers. Public names in kebab-case.
3. **Validate**: `just check` (first rejects a stale `uv.lock` without
   rewriting it, then runs `zsh -n`, every file-stage pre-commit check, the
   locked Python dependency audit, and the complete BATS suite). It must be
   green before opening the PR.
4. **Commit message**: lowercase English
   [Conventional Commits](https://www.conventionalcommits.org) in the form
   `type(scope): subject`, for example `fix(sys): keep apt keys in place`.
   The scope is required. Valid types: `feat`, `fix`, `docs`, `refactor`,
   `perf`, `test`, `build`, `ci`, `chore`, and `revert`. Valid scopes are the
   suites `git`, `vpn`, `sys`, `dev`, `py`, `file`, `env`, and `ws`, plus
   `init` for the core runtime, `docs`, `repo`, and `deps`. Use `deps` for
   reviewed dependency and toolchain maintenance. The `commit-msg` hook
   enforces this format.
5. **Signed commits**: every commit must carry a verified signature, made
   with an SSH or GPG key that is registered on your GitHub account as a
   signing key. See [Signing and sign-off](#signing-and-sign-off).
6. **DCO sign-off**: every commit must also include a `Signed-off-by:`
   trailer asserting you have the legal right to contribute the change under
   the project's [DCO](https://developercertificate.org/). The `DCO` check
   blocks merges that miss a sign-off. Dependabot's own commits are the only
   exception; see [Dependabot pull requests](#dependabot-pull-requests).
7. **PR title**: use the same `type(scope): subject` format. Pull requests
   merge by squash, and the PR title becomes the subject of the squash commit
   on `main`.
8. **PR description**: explain *why*, not *what* (the diff already shows
   what). The PR template will load automatically.

## Signing and sign-off

Sign and sign off every commit in one step:

```sh
git commit -s -S -m "fix(sys): keep apt keys in place"
```

`-S` signs the commit with your configured key, and `-s` adds the DCO
`Signed-off-by:` trailer. To sign every commit automatically, set
`commit.gpgsign=true` and keep using `git commit -s`. For an SSH signing key:

```sh
git config gpg.format ssh
git config user.signingkey ~/.ssh/id_ed25519.pub
git config commit.gpgsign true
```

Register the same public key on GitHub as a **signing key** (an
authentication key alone does not verify commits). If you forgot either
part on the last commit, run `git commit --amend -s -S --no-edit`.

## How changes reach `main`

`main` changes only through pull requests, under a ruleset with no bypass:

- **Squash merges only.** The PR title becomes the squash commit subject,
  and the squash commit message keeps the commit messages, so their
  `Signed-off-by:` trailers survive. GitHub signs the squash commit.
- **Required checks**: `lint`, `DCO`, `CodeQL`, and `bats (macOS)` must pass,
  and the branch must be up to date with `main`. A new CodeQL alert of high or
  critical severity, or an error-level alert, also blocks the merge.
- **Signed commits** with verified signatures, linear history, and resolved
  review conversations are required. New commits dismiss earlier reviews.
- No approving review is required, because the project has a single
  maintainer, who reviews and merges each pull request.
- Force pushes to `main` and its deletion are blocked.
- Commits made in the GitHub web interface require a sign-off as well.
- Workflow runs on pull requests from external contributors' forks wait for
  maintainer approval.

## Local setup

Install Git, Zsh, BATS, Just, and uv on the host before running repository
checks. `just sync` installs the locked Python contributor tools; pre-commit
installs its versioned hook environments on first use. The contributor
environment uses Python 3.14.8 from `.python-version` (`requires-python` is
`>=3.14`), which uv can provide. The product itself needs Python only for
the installer's filesystem helper (3.8 or newer) and for Developer metadata
features (3.11 or newer).

```sh
# Synchronize the locked Python contributor environment
just sync

# Install commit, commit-message, and pre-push hooks (one-time)
just pre-commit-install

# Validate before every commit / PR
just check
```

The pre-push hook runs that same complete aggregate automatically. GitHub's
Quality Gates workflow (the required `lint` check) delegates to it as well,
so changes to that aggregate start in the `Justfile`.

## Adding a public command

A public command is one contract across nine surfaces: its function, the
suite dispatcher, the menu, `--help`, completion and its registration, BATS
contract tests, and the documentation (see
[`suites.md`](../docs/suites.md#public-command-inventory-rules)). Two
recipes keep them in step:

```sh
# Preview, then scaffold the uniform surfaces and print the manual checklist
just new-command --dry-run py tool-example py-tools.zsh read-only \
  --capability tool --label "Show Tool Example" \
  --description "Show one example for an isolated tool."

# Report which surfaces exist for each command of a suite (read-only)
just surfaces py
```

`new-command` adds the fixture row, a function stub, the dispatcher arm, the
menu record, the `--help` entry, the completion entry and binding, and the
lazy stub where the suite uses them. Implement the stub, then finish the
checklist it prints: argument completion, the suite contract document, the
user guide, frozen counts, and tests. The details are in
[`development.md`](../docs/development.md#adding-a-public-command).

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
   `zizmor` enforces this in CI, and the repository's Actions policy refuses
   an action that is not pinned to a full commit SHA.
4. **Stay within the Actions allowlist.** Only GitHub-owned actions and
   `astral-sh/setup-uv`, `lycheeverse/lychee-action`, `ossf/scorecard-action`,
   `tim-actions/get-pr-commits`, and `tim-actions/dco` may run. A new
   third-party action needs the maintainer to extend that allowlist first.
5. **Keep token permissions minimal.** The default `GITHUB_TOKEN` is
   read-only; grant write scopes per job only where a workflow needs them.

## Dependabot pull requests

[Dependabot](dependabot.yml) checks the workflows' GitHub Actions every Monday
and opens one grouped pull request titled `ci(deps): …`. It keeps each
reference pinned to a commit SHA with its version comment, and it proposes a
release only after it is seven days old. Review it like any workflow change:
read the release notes of every action it moves, and merge only when the
required checks pass.

GitHub signs Dependabot's commits, so they meet the signed-commit rule, and
GitHub also signs the squash merge. Dependabot cannot add a DCO sign-off, so
the `DCO` check accepts its pull request only when every commit is authored by
`dependabot[bot]` and verified by GitHub. Do not push to a Dependabot branch;
a commit from anyone else fails that check. Make follow-up changes in a separate pull request, or ask
Dependabot to `@dependabot rebase` or `@dependabot recreate` it.
`dev-menu dev-update-actions` applies the same kind of update locally to any
project without waiting for the schedule.

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
