# Workspace suite contract

This document freezes the public Workspace interface and the safety boundary
implemented by `functions/ws-menu.zsh`, `functions/ws-common.zsh`, and the
modules under `functions/ws/`. The general contracts are
[`development.md`](development.md), [`menu-spec.md`](menu-spec.md),
[`output-spec.md`](output-spec.md), [`headers.md`](headers.md), and
[`testing.md`](testing.md); they take precedence if this document conflicts
with them.

## Ownership

The Workspace suite owns the workspace layout:

```text
$WS_BASE_DIR/<platform>/<identity>/<repository>     default: ~/workspaces
```

It owns navigation between the repositories in that layout, the placement of
new clones, and a read-only status across all of them.

It does not own:

| Domain | Owner | Workspace boundary |
| --- | --- | --- |
| Repository operations, local changes, remotes, and pull requests | `git` | Workspace reads repository state for its status and preview; it never stages, commits, pulls, pushes, or rewrites history |
| Git identity profiles (`ZDX_GIT_IDENTITIES`) and their configuration | `git` | `ws-clone` applies a profile only by calling `git-menu git-identity-switcher --switch NAME local`; it never writes Git configuration itself |
| SSH host aliases, keys, and credential helpers | the user's SSH and Git configuration | Workspace resolves an alias read-only with `ssh -G`; it creates no alias or key |
| Installing Git, `fd`, or `jq` | `zdx-doctor` and `sys` | Workspace reports a missing tool and stops |

The Git suite reads the same layout for display only: inside it, `git-auth`
shows the workspace SSH alias, host name, and key fingerprint
([`git-menu.md`](git-menu.md#ownership)). The two suites share the naming
convention described under [SSH host aliases](#ssh-host-aliases), and each
keeps its own private implementation of it.

The ignored, user-local `functions/zdir.zsh` prototype and its `wsj` alias keep
their conditional registration in `functions.zsh`. `ws-jump` supersedes that
prototype and shares no code with it.

## Public surface

| Command | Purpose | Highest effect |
| --- | --- | --- |
| `ws-status` | One row per repository: workspace, branch, changes, ahead/behind, stashes, and last commit | read-only; `--fetch` updates remote-tracking refs over the network |
| `ws-jump` | Change the current shell to a repository | changes the shell's directory |
| `ws-clone` | Clone a URL into its `<platform>/<identity>` workspace and apply the matching identity profile | network, new directories |

The fixture `test/fixtures/ws-public-commands.tsv` is the machine-readable
surface. Menu rows, help, the dispatcher, lazy stubs, completion, modules, and
public functions must remain aligned with it. `ws-menu`, `ws-status`,
`ws-jump`, and `ws-clone` are registered as cold-shell lazy stubs, and
`zdx ws [arguments...]` routes to `ws-menu`.

There is no `ws-list`: `ws-status --json` already lists every repository's
absolute `path` for scripts, so a second inventory command would only repeat
it.

`ws-menu` with no arguments opens the interactive menu. It also accepts one
canonical command followed by that command's unchanged arguments. Invalid
syntax returns `2`; interactive cancellation returns `0`.

## Menu presentation

The menu follows [`menu-spec.md`](menu-spec.md): the `ws >` prompt, the 80%
preset, label-only rows, and a four-line details pane that `Ctrl-/` toggles.
Its context block never scans the workspace:

```text
Workspace: ~/workspaces
Root: present | Discovery: fd | Profiles: 2
Type to filter | Enter run | Esc cancel | Ctrl-/ details
```

`Root` is `present`, `missing`, or `invalid`; `Discovery` is `fd`, `find`, or
`none`;
`Profiles` counts the loaded `ZDX_GIT_IDENTITIES` entries. Sections are
Inspection (`ws-status`), Navigation (`ws-jump`), and Repositories
(`ws-clone`). Without Git, `ws-status` and `ws-clone` stay listed as
`○ … (missing: git)`. The menu dispatches in the current shell, so choosing
`ws-jump` changes the directory of the shell that opened the menu.

## Command grammar

```text
ws-status [--fetch] [--json]
ws-jump [QUERY]
ws-jump -- QUERY
ws-clone [URL] [--platform NAME] [--identity NAME] [--name DIR] [--dry-run] [--yes]
```

Every command also accepts `-h` or `--help` alone. `--platform`, `--identity`,
and `--name` take one directory name: letters, digits, `.`, `_`, or `-`,
starting with a letter or digit.

## Layout and discovery

| Setting | Default | Rule |
| --- | --- | --- |
| `WS_BASE_DIR` | `${HOME:A}/workspaces` | Absolute path to an existing directory; never `/`. An explicit empty value is kept and refused |
| `WS_MAX_DEPTH` | `3` | Integer from 1 to 10: the deepest repository level below the root |
| `WS_EXCLUDE` | empty array | Relative subtrees below the root, such as `github/archive`; not patterns. Absolute, `.`, and `..` entries are refused |
| `WS_FETCH_JOBS` | `4` | Integer from 1 to 16: concurrent fetches for `ws-status --fetch` |

A repository is a directory at most `WS_MAX_DEPTH` levels below the root that
contains a `.git` entry: a directory, or the `.git` file of a linked worktree
or submodule. Discovery lists repositories only. The private prototype listed
every directory; navigation to a platform or identity directory is a plain
`cd`, and repositories are the only targets the preview and `ws-status` can
describe.

Discovery never lists:

- hidden directories or anything below them;
- symbolic links, which are neither followed nor listed;
- `WS_EXCLUDE` subtrees;
- a repository inside another listed repository, such as a submodule checkout
  or a vendored clone;
- a directory whose relative path contains a control character or `|`, which
  cannot be shown as one record. These are counted in one warning, such as
  `Skipped 2 directories whose names cannot be shown safely.`

`fd` is preferred, including the `fdfind` name that Debian and Ubuntu install,
with `--no-ignore` so `.gitignore` files cannot hide repositories. `find`
(GNU or BSD) is the fallback and produces the same list. The scan is bounded
to 30 seconds and 8 MiB of output, and more than 2,000 repositories fail
closed with advice to lower `WS_MAX_DEPTH` or add `WS_EXCLUDE` entries.
Unreadable directories produce a warning; the rest of the scan still counts.

The read-only commands accept a root reached through symbolic links, such as
`~/workspaces` linked to another disk. `ws-clone` applies stricter ownership
rules before it writes; see [Destination checks](#destination-checks).

## `ws-jump`

`ws-jump` changes the directory of the shell that runs it, as
`venv-activate` changes its environment, so it is a shell function and runs
in the caller's shell, including through `ws-menu ws-jump` and `zdx ws
ws-jump`. In a subshell or command substitution it warns that the change
cannot reach the caller.

Without `QUERY`, it opens a picker of every repository. `QUERY` selects the
repositories named exactly `QUERY`; when none is, it selects those whose
relative path contains `QUERY` with any letter case. One match changes
directory at once; several open the picker with only those repositories; none
returns `1`. `ws-jump -- QUERY` accepts a query that starts with `-`.

The picker is a content browser with the `ws jump >` prompt, the
`Workspace: ~/workspaces` scope line, and `Type to filter | Enter jump | Esc
cancel | Ctrl-/ details`. Each record is `relative-path|index`; only the path
is shown. A selection must be an exact row of the snapshot, and its index maps
back to the frozen path.

The preview pane shows the branch (or `detached at <commit>`), the number of
uncommitted changes (`clean` for none), and the last commit's age and subject.
Its program text is constant: fzf supplies only the integer row index `{n}`,
and the program reads the matching path from an owner-only snapshot file in a
private directory below the validated `TMPDIR`. No path, name, or selected
text is ever part of the program. It runs only read-only Git commands
(`symbolic-ref`, `rev-parse`, `--no-optional-locks status --porcelain`, and
`log -1`), and removes control characters from the commit subject. The
preview has no timeout of its own; fzf replaces it when the cursor moves.

After a selection, the target must still be a real, non-symlink directory at
the same canonical path below the root with a `.git` entry; otherwise
`ws-jump` refuses it with status `1`. It then runs `builtin cd`, so `chpwd`
hooks run as for any directory change, and prints `Now in <path>` on stderr.
Cancellation leaves the directory unchanged and returns `0`. stdout stays
empty.

## `ws-status`

Each repository is described from local refs only, with three Git commands
bounded to 15 seconds each:

```text
git --no-optional-locks -C <repository> status --porcelain=v2 --branch --untracked-files=normal
git -C <repository> -c log.showSignature=false log -1 --format=%ct
git -C <repository> rev-list --walk-reflogs --count refs/stash
```

`--no-optional-locks` keeps the status probe from rewriting the index, and
`log.showSignature=false` keeps signature checks out of the timestamp. The
text report prints the `Workspace Status` heading, the root and repository
count as key-value lines, and one table:

```text
  Workspace        Repository  Branch               Changes  Sync               Stashes  Last commit
  github/personal  dirty       main                 2        up to date         0        2 days ago
  gitlab/work      detached    detached at 5e3d5ee  clean    no upstream        0        3 weeks ago
  github/personal  clean       main                 clean    up to date         0        5 hours ago
```

`Sync` is `up to date`, `ahead N`, `behind N`, `ahead N, behind N`,
`no upstream`, or `upstream gone`, and gains `(fetch failed)` after a failed
`--fetch`. A repository at depth one shows `.` as its workspace.

A repository needs attention when it has uncommitted changes (`changes`),
unpushed commits (`ahead`), unmerged upstream commits (`behind`), stashes
(`stashes`), a detached `HEAD` (`detached`), a configured upstream that no
longer exists (`upstream-gone`), a failed probe (`error`), or a failed fetch
(`fetch-failed`). A branch without an upstream does not need attention by
itself. Repositories that need attention are listed first; each group keeps
the sorted path order. An inventory with findings ends with one verdict, such
as `⚠ 4 of 6 repositories need attention.`; a probe failure adds one error
line per repository.

### `--fetch`

`--fetch` is the only network access of `ws-status`. Before any status is
computed, it:

1. lists the repositories that have at least one remote (`git remote`); the
   others are reported as `skipped`;
2. discloses the scope, for example
   `⚠ Fetching 6 repositories over the network with git fetch --prune (at most 4 at a time, 60s each).`;
3. runs `git -C <repository> fetch --prune --quiet` with `GIT_TERMINAL_PROMPT=0`
   and `GCM_INTERACTIVE=Never`, closed stdin, and discarded output, at most
   `WS_FETCH_JOBS` at a time and each bounded to 60 seconds;
4. reports each failure or timeout and one summary, such as
   `⚠ Fetched 5 of 6 repositories; 1 failed.`

Every started job is stopped and waited for on every exit path. Fetch output,
which can contain remote URLs, is never shown. A fetch updates only
remote-tracking refs; local branches and working trees are never changed.

### `--json`

`--json` follows the shared JSON convention: it never opens fzf or prompts,
stdout carries exactly one compact JSON object on a single line, built with
`jq -c -n` from `--arg` values and jq-built objects on stdin, never from text
spliced into the jq program, and warnings, errors, and the timing line stay
on stderr. Without `jq`, the command reports the missing capability and
returns `1`. The document is shown expanded here:

```json
{
  "schema": "zdx.ws-status.v1",
  "base": "/home/jane/workspaces",
  "fetched": false,
  "counts": { "repositories": 6, "attention": 4, "errors": 0 },
  "repositories": [
    {
      "path": "/home/jane/workspaces/github/personal/dirty",
      "relative_path": "github/personal/dirty",
      "workspace": "github/personal",
      "platform": "github",
      "identity": "personal",
      "repository": "dirty",
      "branch": "main",
      "detached": false,
      "head": "835584f",
      "upstream": "origin/main",
      "upstream_state": "tracking",
      "ahead": 0,
      "behind": 0,
      "changes": 2,
      "stashes": 0,
      "last_commit_at": "2026-10-05T18:59:38Z",
      "attention": true,
      "attention_reasons": ["changes"],
      "fetch": null,
      "error": null
    }
  ]
}
```

- `base` and `path` are canonical absolute paths. `platform` and `identity`
  are set only for a repository at depth three and `workspace` is `null` at
  depth one.
- `branch` is `null` for a detached `HEAD`, and `head` is `null` before the
  first commit. `upstream_state` is `none`, `tracking`, or `gone`; `ahead` and
  `behind` are `null` unless it is `tracking`.
- `last_commit_at` is an ISO-8601 UTC timestamp or `null`.
- `fetch` is `null` without `--fetch`, and otherwise `ok`, `failed`,
  `timed-out`, or `skipped`. `error` names a failed probe, such as
  `git status failed (status 128)`.
- Remote URLs are never included, so no credential can leak through them.

Repositories are ordered as in the text report. Exit statuses match the text
mode.

## `ws-clone`

### URL validation

`ws-clone` accepts exactly three address forms:

- `https://host/path`, without any user information: a token pasted before
  `@` is refused;
- `ssh://[user@]host[:port]/path`, without a password;
- `user@host:path`, the scp-like form, with exactly one user.

It refuses option-looking values, local paths (`/`, `./`, `../`, `~`),
`file://`, transport helpers such as `ext::`, other schemes such as `http://`
and `git://`, embedded credentials, queries and fragments, whitespace and
control characters, invalid hosts and ports, and path components that are
empty, `.`, `..`, or start with `-` or `.`. A refused URL returns `2` before
any probe or clone. The repository directory defaults to the URL's last
component without `.git`; `--name DIR` replaces it.

Without a URL, a terminal session prompts for one and an empty answer
cancels; with `--yes` or without a terminal, a missing URL is a usage error.

### Platform and identity

The platform comes from `--platform`, or else, in order:

1. a URL host that is already a workspace alias `<platform>-<identity>` of
   an existing identity directory, which also selects the identity;
2. `github.com` → `github` and `gitlab.com` → `gitlab`;
3. the `.ws-hostname` files of existing `<platform>/<identity>` directories
   that name the URL's host, when they all belong to one platform.

Otherwise `ws-clone` returns `2` and asks for `--platform NAME`.

The identity comes from `--identity`, the alias, or the matching
`.ws-hostname` workspaces; otherwise the candidates are the existing
`<platform>/*` directories that serve the URL's host and the
`ZDX_GIT_IDENTITIES` profile names without a directory, which serve the
platform's default host. One candidate is used; several open a picker in a
terminal and are a usage error (`2`) with `--yes` or without a terminal; none
asks for `--identity NAME`. A new identity directory has no `.ws-hostname`
file, so create one yourself for a self-hosted platform.

### SSH host aliases

Workspaces share one convention with `git-auth`:

- the SSH host alias of a workspace is `<platform>-<identity>`, such as
  `github-personal`;
- its host is `github.com` for the `github` platform, otherwise the first line
  of a regular `<platform>/<identity>/.ws-hostname` file (a trailing CR is
  ignored), otherwise `gitlab.com`.

For an `ssh://` or scp-like URL, `ws-clone` resolves the alias with the SSH
program Git itself runs: `GIT_SSH_COMMAND`, the global `core.sshCommand`
(through `/bin/sh`, with the alias passed as an argument), `GIT_SSH`, then
`ssh`. It runs only `-G -- <alias>`, which prints configuration and opens no
connection, bounded to 10 seconds. PuTTY variants have no `-G`, so their
aliases are never used. The URL host is replaced by the alias only when the
alias's configured `HostName` equals the URL's host, so the clone
authenticates with that workspace's key. HTTPS URLs are never rewritten:
they authenticate through credential helpers.

### Destination checks

- `WS_BASE_DIR` must already exist; `ws-clone` never creates the root. It is
  resolved with the trusted-directory rules (a symbolic link only as a
  root-owned system alias or a link the user owns above the final
  component), must be owned by the current user and not writable by group or
  others, and its ancestors must not be replaceable by another user.
- Existing `<platform>` and `<platform>/<identity>` directories must be real
  directories with the same ownership and mode rules; missing ones are planned
  as new directories and created with the umask plus `022`.
- The destination must not exist in any form, including a symbolic link.

On WSL, a root on a Windows drive without DrvFs metadata reports mode `777`
and is refused with the `/etc/wsl.conf` remedy.

### Plan and authorization

```text
════ Workspace Clone Plan ════

  Repository:        app
  URL:               git@github-personal:acme/app.git
  Requested URL:     git@github.com:acme/app.git
  Workspace:         github/personal (inferred)
  Destination:       ~/workspaces/github/personal/app
  SSH alias:         github-personal (HostName github.com)
  Identity profile:  git-menu git-identity-switcher --switch personal local
⚠ git clone downloads github.com content that ZDX does not review.
```

The workspace line says whether the identity came from an option, was
inferred, or was selected. New directories are listed as `New directory`
lines. `--dry-run` stops with `Dry run: 1 clone planned; nothing was cloned.`
Otherwise `ws-clone` asks `Clone app into ~/workspaces/github/personal?`; a
decline prints `Cancelled: nothing was cloned.` and returns `0`, and without a
terminal and without `--yes` it fails closed with status `2`. `--yes` skips
only the prompt.

After authorization, the root and every existing workspace directory must
keep the device and inode they had while planning, planned directories must
still be absent, and the destination must still not exist.

### Staged clone

1. Missing workspace directories are created and checked.
2. A private staging directory `.ws-clone.XXXXXX` (mode `700`) is created in
   the identity directory, on the destination's file system.
3. `git clone -- <url> <staging>/<name>` runs in the foreground, so Git can
   ask for credentials, with repository variables such as `GIT_DIR`,
   `GIT_WORK_TREE`, and `GIT_INDEX_FILE` removed. Its output goes to stderr.
   The clone has no timeout: a large repository may legitimately take long,
   and `Ctrl-C` stops it.
4. On a failure or interruption, the staging directory is removed only while
   it is still the exact directory this clone created, and nothing is
   published. An interruption keeps its status, `130` or `143`.
5. On success, the clone is renamed into place without replacing anything:
   GNU and uutils `mv -T -n`, otherwise BSD `mv -n`, followed by a check that
   the destination is the staged directory. If another directory appeared
   there, everything is left in place for inspection and the status is `1`.

A clone does not include the repository's hooks, and Git does not clone
submodules unless asked, so cloning does not execute the repository's
content. Hooks and filters from your own Git configuration, such as an
`init.templateDir` hook or Git LFS, still run as they would for any clone.

### Identity delegation

When `ZDX_GIT_IDENTITIES` has an entry named like the identity, `ws-clone`
then runs, in a subshell inside the new repository:

```zsh
git-menu git-identity-switcher --switch <identity> local
```

The Git suite validates the profile and writes the local configuration; that
command has no prompt of its own, and the clone plan already named it. If it
fails, or `git-menu` is not loaded, the clone is kept, the exact retry command
is printed, and the status is `1`. The caller's directory never changes.

On success `ws-clone` prints the destination's absolute path on stdout, so
`cd "$(ws-clone URL --yes)"` works.

## Streams and exit statuses

| Status | Meaning |
| --- | --- |
| `0` | Success, an empty workspace, a dry run, or a cancellation |
| `1` | A missing or unsafe root, a failed probe, fetch, clone, or identity step, a refused selection, or no matching repository |
| `2` | Invalid arguments, a refused URL, or a choice that needs a terminal |
| `130`, `143` | An interrupted clone; nothing was published |

UI, plans, warnings, prompts, picker chrome, and child-tool output use stderr.
Documented stdout data is limited to the `ws-status --json` document and the
path printed by a successful `ws-clone`.

## Platform support

| Behavior | Linux | WSL | macOS |
| --- | --- | --- | --- |
| Discovery | `fd`, `fdfind`, or GNU `find` | the same; Windows programs below `/mnt/<drive>` never count as tools | Homebrew `fd` or BSD `find` |
| Bounded probes | `timeout` | `timeout` | `gtimeout` or the core watchdog |
| Git | 2.31 or newer | 2.31 or newer | 2.31 or newer; Apple's `/usr/bin/git` placeholder is refused, not run |
| Alias resolution | `ssh -G` | the configured `ssh.exe` reads the Windows SSH configuration | `ssh -G` |
| Publishing a clone | `mv -T -n` | `mv -T -n` | `mv -n` plus an identity check |
| Clone into a Windows drive | not applicable | refused without DrvFs metadata, with the remedy | not applicable |

On a case-insensitive file system, such as APFS by default, a destination that
differs from an existing directory only in letter case already exists and is
refused. The macOS, WSL, and `ssh.exe` branches run on Linux through mocks;
real clones and fetches against remote hosts, a real Windows SSH
configuration, and BSD `mv` on a Mac remain manual acceptance.

## Security notes

- **Network surface:** `ws-clone` contacts the URL's host through Git, and
  `ws-status --fetch` contacts each repository's configured remote. No other
  command uses the network.
- **Write locations:** below `WS_BASE_DIR` (new workspace directories, the
  transient staging directory, and the clone), and owner-only private
  directories below the validated `TMPDIR` for picker results, the
  `ws-jump` snapshot, and fetch statuses, removed on every exit path.
- **Code execution:** no selected path, name, URL, or query is evaluated or
  placed in program text. Dispatch uses fixed `case` arms. The SSH command
  from `GIT_SSH_COMMAND` or `core.sshCommand` is the user's own Git
  configuration and runs as Git would run it.
- **Secrets:** URLs with credentials are refused, remote URLs never appear in
  JSON, and fetch output is discarded.

See [`security-assessment.md`](security-assessment.md) for the threat entries.

## Test coverage

| File | Covered boundary |
| --- | --- |
| `test/ws.bats` | Standalone and double sourcing, side-effect-free loading, loader failure, help streams, grammar statuses before probes, literal dispatch, menu context, cancellation, current-shell dispatch, forged and failed selections, missing-Git marks, the `zdx ws` route and reserved name, the catalog row, the doctor `fd` row, and lazy stubs |
| `test/ws_contract.bats` | Fixture, module, menu, dispatcher, help, completion, compinit registration, lazy-stub, and documentation parity, and the absence of an evaluator |
| `test/ws_jump.bats` | `fd` and `find` parity, depth, exclusions and their validation, hidden, nested, linked, and worktree entries, direct and picker jumps, exact-name precedence, cancellation, forged and stale selections, hostile names, the index-only preview, and routing through `ws-menu` and `zdx` |
| `test/ws_status.bats` | Clean, dirty, diverged, detached, stashed, and unborn repositories in text and JSON, attention order, stdout reserved for one JSON document, bounded and disclosed `--fetch` with a mocked fetch, failures and timeouts, unreadable repositories, an empty root, and a missing `jq` |
| `test/ws_clone.bats` | URL refusals, the exact dry-run plan, new workspaces, existing destinations, staging cleanup after a failed clone, SSH alias rewriting with a mocked `ssh`, alias hosts, delegated identity application with exact arguments and real configuration, non-interactive refusal, declines, the identity picker, `.ws-hostname` inference, and unsafe roots and directories |

`git clone` is mocked: the URL rules refuse the local transports a test could
otherwise use.
