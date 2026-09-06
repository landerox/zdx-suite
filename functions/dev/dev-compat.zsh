#!/usr/bin/env zsh
# =============================================================================
# Dev Compat: deprecated unprefixed command names, scheduled for removal
# =============================================================================
#
# Loaded by dev-menu.zsh after every other module under functions/dev/.
# Safe to re-source; defines functions only.
#
# Before the suite adopted the dev- namespace it exported generic global names
# such as clean-py and run-tests into every interactive shell. Each one is kept
# here as a thin forwarder that emits one deprecation notice per shell session.
# These names are NOT part of the menu, help, or completion surfaces, and they
# are scheduled for removal in v0.3.0.
#
# Each wrapper is written out explicitly: building function names from data
# would require eval or a computed function name, which the suite contract
# forbids.
#

if [[ -n "${_DEV_COMPAT_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# --- Updates ----------------------------------------------------------------

update-all() {
  _dev_deprecated_alias update-all dev-update-all
  dev-update-all "$@"
}

update-deps() {
  _dev_deprecated_alias update-deps dev-update-deps
  dev-update-deps "$@"
}

update-deps-dry() {
  _dev_deprecated_alias update-deps-dry dev-update-deps-dry
  dev-update-deps-dry "$@"
}

update-lock() {
  _dev_deprecated_alias update-lock dev-update-lock
  dev-update-lock "$@"
}

update-precommit() {
  _dev_deprecated_alias update-precommit dev-update-precommit
  dev-update-precommit "$@"
}

update-terraform() {
  _dev_deprecated_alias update-terraform dev-update-terraform
  dev-update-terraform "$@"
}

update-tflint() {
  _dev_deprecated_alias update-tflint dev-update-tflint
  dev-update-tflint "$@"
}

update-toolchain() {
  _dev_deprecated_alias update-toolchain dev-update-toolchain
  dev-update-toolchain "$@"
}

update-python() {
  _dev_deprecated_alias update-python dev-update-python
  dev-update-python "$@"
}

# --- Inspection -------------------------------------------------------------

check-outdated() {
  _dev_deprecated_alias check-outdated dev-check-outdated
  dev-check-outdated "$@"
}

check-health() {
  _dev_deprecated_alias check-health dev-check-health
  dev-check-health "$@"
}

check-licenses() {
  _dev_deprecated_alias check-licenses dev-check-licenses
  dev-check-licenses "$@"
}

check-types() {
  _dev_deprecated_alias check-types dev-check-types
  dev-check-types "$@"
}

# --- Quality gates ----------------------------------------------------------

run-hooks() {
  _dev_deprecated_alias run-hooks dev-run-hooks
  dev-run-hooks "$@"
}

run-ruff() {
  _dev_deprecated_alias run-ruff dev-run-ruff
  dev-run-ruff "$@"
}

run-ruff-format() {
  _dev_deprecated_alias run-ruff-format dev-run-ruff-format
  dev-run-ruff-format "$@"
}

run-ty() {
  _dev_deprecated_alias run-ty dev-run-ty
  dev-run-ty "$@"
}

run-pyright() {
  _dev_deprecated_alias run-pyright dev-run-pyright
  dev-run-pyright "$@"
}

run-tflint() {
  _dev_deprecated_alias run-tflint dev-run-tflint
  dev-run-tflint "$@"
}

run-markdownlint() {
  _dev_deprecated_alias run-markdownlint dev-run-markdownlint
  dev-run-markdownlint "$@"
}

run-eslint() {
  _dev_deprecated_alias run-eslint dev-run-eslint
  dev-run-eslint "$@"
}

run-prettier() {
  _dev_deprecated_alias run-prettier dev-run-prettier
  dev-run-prettier "$@"
}

run-clippy() {
  _dev_deprecated_alias run-clippy dev-run-clippy
  dev-run-clippy "$@"
}

run-shellcheck() {
  _dev_deprecated_alias run-shellcheck dev-run-shellcheck
  dev-run-shellcheck "$@"
}

run-all-checks() {
  _dev_deprecated_alias run-all-checks dev-run-all-checks
  dev-run-all-checks "$@"
}

run-tests() {
  _dev_deprecated_alias run-tests dev-run-tests
  dev-run-tests "$@"
}

run-coverage() {
  _dev_deprecated_alias run-coverage dev-run-coverage
  dev-run-coverage "$@"
}

# --- Security ---------------------------------------------------------------

run-audit() {
  _dev_deprecated_alias run-audit dev-run-audit
  dev-run-audit "$@"
}

run-bandit() {
  _dev_deprecated_alias run-bandit dev-run-bandit
  dev-run-bandit "$@"
}

# --- Cleanup ----------------------------------------------------------------

clean-py() {
  _dev_deprecated_alias clean-py dev-clean-py
  dev-clean-py "$@"
}

clean-repo() {
  _dev_deprecated_alias clean-repo dev-clean-repo
  dev-clean-repo "$@"
}

clean-terraform() {
  _dev_deprecated_alias clean-terraform dev-clean-terraform
  dev-clean-terraform "$@"
}

clean-all() {
  _dev_deprecated_alias clean-all dev-clean-all
  dev-clean-all "$@"
}

# --- Packaging --------------------------------------------------------------

export-deps() {
  _dev_deprecated_alias export-deps dev-export-deps
  dev-export-deps "$@"
}

build-package() {
  _dev_deprecated_alias build-package dev-build-package
  dev-build-package "$@"
}

backup-pyproject() {
  _dev_deprecated_alias backup-pyproject dev-backup-pyproject
  dev-backup-pyproject "$@"
}

# --- Profiles ---------------------------------------------------------------

profile-save() {
  _dev_deprecated_alias profile-save dev-profile-save
  dev-profile-save "$@"
}

profile-list() {
  _dev_deprecated_alias profile-list dev-profile-list
  dev-profile-list "$@"
}

profile-delete() {
  _dev_deprecated_alias profile-delete dev-profile-delete
  dev-profile-delete "$@"
}

# --- Python runtime compatibility (ownership moved to the py suite) ---------

if ! typeset -f venv-python &>/dev/null; then
  venv-python() {
    _dev_dispatch venv-python "$@"
  }
fi

# --- Docker cleanup (ownership moved to the docker suite) -------------------
# These never belonged to the dev suite: the Docker lifecycle is owned by
# docker-menu. They forward there and are not part of the dev menu.

clean-docker() {
  _dev_delegate_docker clean-docker "$@"
}

docker-prune-all() {
  _dev_delegate_docker docker-prune-all "$@"
}

typeset -g _DEV_COMPAT_SOURCED=1
