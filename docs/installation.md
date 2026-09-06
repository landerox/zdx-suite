# Installation contract

The installer integrates an already-reviewed local ZDX checkout with Oh My
Zsh. It owns the `plugins/zdx-suite` entry and the initial optional user
configuration. It does not fetch source, run Git, install packages, invoke
`sudo`, edit `.zshrc`, or load ZDX into the caller's shell.

The implementation is [scripts/install.zsh](../scripts/install.zsh).
[scripts/install.sh](../scripts/install.sh) is a minimal Bash 3.2-compatible
launcher that forwards installation arguments to that adjacent Zsh file.
[scripts/install_fs.py](../scripts/install_fs.py) contains the private filesystem
validation and publication primitives and runs with isolated Python flags.
Both installation entrypoints require a local checkout; downloaded standalone
scripts, `bash -c`, and `curl | bash`
are not installation interfaces.

## Source review and prerequisites

Obtain the source separately, for example:

```sh
git clone https://github.com/landerox/zdx-suite.git "$HOME/zdx-suite"
cd "$HOME/zdx-suite"
```

Review the checkout before running the installer or enabling the plugin.
`main` is mutable, and cloning a repository over HTTPS is not cryptographic
verification of its author or a guarantee that its code is safe. Inspect the
selected revision and source you intend to load. If you rely on release
signatures, establish the signing identity independently; a locally computed
checksum alone does not authenticate a download. The installer neither
selects a remote revision nor verifies a Git signature on your behalf.

Zsh, Python 3.8 or newer, and an existing Oh My Zsh installation are required for planning
and installation. Python runs a local filesystem helper for validation and
atomic publication; no Python packages are installed. Bash is needed only for
the compatibility launcher. Git is needed to clone or maintain a checkout,
not for the local installation transaction. Interactive menus additionally
need fzf; per-suite dependencies remain owned by the respective commands and
reported by `zdx doctor` after activation.

## Paths

Set custom paths in the shell before invoking the installer:

```zsh
export ZSH="${ZSH:-$HOME/.oh-my-zsh}"
export ZSH_CUSTOM="${ZSH_CUSTOM:-$ZSH/custom}"
export ZDOTDIR="${ZDOTDIR:-$HOME}"
```

Exporting matters: shell variables that are not exported do not reach an
external Zsh or Bash process. The installer uses these locations:

| Purpose | Location |
| --- | --- |
| Reviewed source | Checkout containing the actual `scripts/install.zsh` file |
| Oh My Zsh | `${ZSH:-$HOME/.oh-my-zsh}` |
| Plugin entry | `${ZSH_CUSTOM:-${ZSH:-$HOME/.oh-my-zsh}/custom}/plugins/zdx-suite` |
| Initial user configuration | `$HOME/.config/zdx/config.zsh` |
| Manual activation instructions | `${ZDOTDIR:-$HOME}/.zshrc` |

The core runtime reads `$HOME/.config/zdx/config.zsh`; `XDG_CONFIG_HOME` does
not relocate this executable configuration. It is optional, and defaults work
without it. The template contains commented examples rather than credentials.

HOME and the reviewed source are canonicalized. A trusted alias to HOME is
resolved at that boundary, including layouts that use a macOS path alias.
Other traversed components must satisfy ownership, type, and writable-mode
checks; unexpected symbolic-link components are refused. An absolute custom
plugin location outside HOME is permitted only when its ancestors are safe.
These checks do not establish native macOS compatibility: the automated
fixtures run on Linux, and macOS installation remains manual acceptance.

## Preview, authorization, and repeat runs

```zsh
zsh -f scripts/install.zsh --help
zsh -f scripts/install.zsh --dry-run
zsh -f scripts/install.zsh
```

Alternatively, use `bash scripts/install.sh` with the same flags. Flags are
exclusive. `--help` performs no dependency or installation-path preflight;
the Bash launcher's help also works without Zsh or Python. `--dry-run`
validates the proposed installation and prints its plan without creating
files, links, or directories. It requires the planning dependencies, including
Python 3.8 or newer. Unknown options and unexpected operands return `2` before
probes.

Execution displays the exact source, plugin entry, and configuration action
before confirmation. A declined prompt returns `0` without writes. Without a
terminal on both stdin and stderr, mutation requires `--yes` explicitly:

```zsh
zsh -f scripts/install.zsh --yes
```

`--yes` authorizes the displayed local plan and bypasses only the prompt. It
does not bypass safety checks or permit replacing another installation.

The supported destination states are:

- An absent plugin entry receives a symbolic link to the reviewed source.
- An owned link already pointing exactly to that source is preserved.
- A checkout already located at the plugin destination is preserved in place.
- Any unrelated existing destination is preserved and refused. Move or repair
  it explicitly after reviewing its contents; the installer never deletes it.

When configuration is absent, the installer creates new private directories
with mode `700` and publishes the template with mode `600` without clobbering
an existing name. Existing configuration must be owned, readable, regular,
singly linked, and inaccessible to group and other users; modes `400` and
`600` are valid. Unsafe existing configuration is refused, not rewritten or
silently chmodded. Existing safe directories retain their permissions.
Read source markers, the template, and existing configuration each have a
1 MiB bound. The apply step revalidates the planned identities and content
digests before publication.

Publication is atomic for each new object, not across the whole plan. A later
failure can leave an earlier valid object installed. The command reports
failure and retained progress rather than announcing completion; rerun after
resolving the problem to reuse those exact objects. Validation, dependency,
and ordinary application failures return `1`; interruptions preserve `130`
or `143`. Existing user files and unrelated links are not rollback targets.

## Activate manually

Edit the `.zshrc` path printed in the installation instructions. Keep the
existing plugins and add `zdx-suite` **before** Oh My Zsh is sourced:

```zsh
plugins=(git zdx-suite)
source "$ZSH/oh-my-zsh.sh"
```

This illustrates ordering; do not replace your other plugins or add a second
Oh My Zsh source line. The installer never parses or rewrites this shell code,
and installation success does not claim that activation has happened.

Open a fresh terminal or run `exec zsh`. Re-sourcing `.zshrc` after an update
can retain old definitions because the loaders use idempotency guards. Then
run `zdx --help` and `zdx doctor` to inspect the active installation and its
available capabilities. The doctor does not install dependencies without a
separate explicit choice.

## Updates and removal

Re-running the installer repairs only its local integration; it never pulls
new commits. System's `update-zsh-plugins` recognizes an exact development link
to the active source when its owner and source checks pass, including a real
`.git` directory in an owned checkout below HOME. It skips Git operations
through that link. Review and update the source checkout explicitly with Git.
Other source layouts do not gain automatic System update support merely by
passing installation checks. For a normal clone placed
directly in the Oh My Zsh plugin directory, System owns the supported plugin
update workflow and its authorization. See [System](sys-menu.md) for its
checkout and origin checks. Start a fresh shell after either update path.

There is no installer removal command. Disable `zdx-suite` in the appropriate
plugins array first. Review the plugin entry before removing a link or
checkout manually, and keep user configuration unless you explicitly intend
to delete it.

## Trust and validation limits

The installer runs reviewed local code with the user's privileges. It is not
a sandbox, an updater, or a source-authentication mechanism. Python and Zsh
executables, system startup behavior, and filesystem semantics remain trusted
platform dependencies. Structural validation cannot prove that a checkout,
configuration, or override is harmless. Portable path checks cannot rule out
every concurrent same-user filesystem race.

Installer tests use disposable HOME and Oh My Zsh trees, local fixtures, and
mocked external boundaries. They must cover side-effect-free help/dry-run,
non-interactive authorization, identical versus unrelated destinations,
private no-clobber configuration publication, partial recovery, and launchers.
See [testing.md](testing.md) for executed coverage and remaining platform limits.
