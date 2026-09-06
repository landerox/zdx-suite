#!/usr/bin/env bash
# =============================================================================
# ZDX Installer: launch the reviewed local checkout with Zsh
# =============================================================================
# Bash 3.2 compatibility entrypoint; never downloads code or edits shell profiles.
# Usage: bash scripts/install.sh [--help | --dry-run | --yes]

if [[ -z "${BASH_SOURCE[0]-}" || "${BASH_SOURCE[0]}" != "$0" ]]; then
    printf '%s\n' 'installer: run the local scripts/install.sh file; do not source, pipe, or use bash -c.' >&2
    if [[ -n "${BASH_SOURCE[0]-}" ]]; then
        return 1
    fi
    exit 1
fi

if [[ $# -gt 1 ]]; then
    printf '%s\n' 'Usage: bash scripts/install.sh [--help | --dry-run | --yes]' >&2
    exit 2
fi
case "$#:${1-}" in
    0: | 1:--dry-run | 1:--yes) ;;
    1:--help)
        printf '%s\n' \
            'Usage: bash scripts/install.sh [--help | --dry-run | --yes]' \
            'Integrate a reviewed local checkout; requires installed Zsh, Python 3.8+, and Oh My Zsh.' \
            '--dry-run validates without writes; --yes applies without prompting. Flags are exclusive.' \
            'No downloads, updates, or shell-profile edits. With no flag, terminal confirmation is required.' >&2
        exit 0 ;;
    *) printf '%s\n' 'installer: unknown option; use --help.' >&2; exit 2 ;;
esac

installer_file="${BASH_SOURCE[0]}"
if [[ -L "$installer_file" || ! -f "$installer_file" ]]; then
    printf '%s\n' 'installer: the launcher must be a regular file in a reviewed local checkout.' >&2
    exit 1
fi
installer_dir="${installer_file%/*}"
[[ "$installer_dir" != "$installer_file" ]] || installer_dir=.
installer_dir="$(cd -P -- "$installer_dir" && pwd -P)" || exit 1
installer_root="${installer_dir%/*}"
for installer_part in scripts/install.zsh scripts/install_fs.py functions.zsh zdx-suite.plugin.zsh .config/zdx/config.zsh.example; do
    if [[ ! -f "$installer_root/$installer_part" || -L "$installer_root/$installer_part" ]]; then
        printf '%s\n' "installer: incomplete local checkout: $installer_part" >&2
        exit 1
    fi
done
if ! command -v zsh >/dev/null 2>&1; then
    printf '%s\n' 'installer: Zsh is required; install it with your package manager, then retry.' >&2
    exit 1
fi
exec zsh -f "$installer_dir/install.zsh" "$@"
