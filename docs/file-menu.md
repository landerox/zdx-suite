# File suite contract

This document freezes the public File interface and records the safety boundary
implemented by `functions/file-menu.zsh`, `functions/file-common.zsh`, and the
modules under `functions/file/`.

## Public surface

The canonical commands are:

| Command | Purpose |
| --- | --- |
| `file-compress` | Create a staged TAR, ZIP, or 7z archive |
| `file-extract` | Preflight and extract a supported GNU TAR archive |
| `file-find-large` | Find large files and optionally delete them |
| `file-trash` | Move paths to a rename-only trash, then restore or purge them |
| `file-clean-junk` | Find operating-system junk files and delete them after review |

The fixture `test/fixtures/file-public-commands.tsv` is the machine-readable
surface. Menu rows, help, the dispatcher, lazy loading, completion, and public
functions must stay aligned with it.

`file-menu` with no arguments opens the interactive menu. It also accepts one
canonical command followed by that command's unchanged arguments. Invalid
syntax returns `2`; an interactive cancellation returns success.

The interactive menu follows [`menu-spec.md`](menu-spec.md): large-file
inspection comes first, followed by archives and the trash, and junk-file
cleanup comes last as the only purely destructive action. Its 80% layout uses
a four-line bottom description with `Ctrl-/` to toggle details. Copy
distinguishes TAR-only extraction from the broader compression formats, states
that large-file deletion is reviewed before it runs, and names every junk file
type. `Browse Trash` opens the trash picker described under [Trash](#trash). An
action that cannot run at all on the host keeps its row in the canonical
unavailable form: `○ Extract TAR Archive (missing: GNU tar)` when neither
`tar` nor `gtar` is GNU tar, and `○ Compress Files (missing: tar or zip or
7z)` only when no archiver exists. A missing 7z alone leaves compression
unmarked because the other formats still work.

## Command grammar

```text
file-compress --format FORMAT --output FILE
              [--overwrite] [--dry-run] [--yes] -- PATH...
file-extract --destination DIRECTORY [--dry-run] [--yes] -- ARCHIVE
file-find-large --min-size SIZE [--delete] [--dry-run] [--yes]
file-trash [--dry-run] [--yes]
file-trash put [--dry-run] [--yes] [--] PATH...
file-trash list [--json]
file-trash restore [--dry-run] [--yes] [--] [ID...]
file-trash purge [--dry-run] [--yes] [ID... | --older-than DAYS | --all]
file-clean-junk [--dry-run] [--yes]
```

Use `--` before operands when a path begins with `-`. `file-trash` follows
the action grammar of `git-stash`: options may appear anywhere after the
command, `--json` is valid only with `list`, `--older-than` and `--all` only
with `purge`, and IDs, `--older-than`, and `--all` exclude one another. A
malformed or repeated ID, a negative or non-numeric day count, or more than
36,500 days returns `2` before the trash is read.

## Filesystem and mutation boundary

Mutating commands are limited to canonical, owned, symlink-free targets below
an owned, non-group/world-writable invocation directory. The working directory
may be reached through trusted aliases, such as macOS `/tmp` or a root-owned
`/home` link: the base follows the suite's copy of the core trusted-directory
rule (a root-owned link anywhere, or a current-user link above the final
component inside a directory that group and other users cannot write), and
every check applies to its canonical path. A working directory that is itself
a user-owned link stays refused. Relative operands are resolved against the
canonical base, and an absolute operand through a trusted alias of its parent
maps to the canonical parent. Every ancestor must be
owned by the current EUID or by the namespace-visible owner of `/` (normally
UID 0) and must not permit unprotected replacement; a sticky shared directory
owned by that system-root identity is the only shared exception. Regular
mutation targets must have one hard link, and paths containing controls or the
internal plan delimiter are refused. Targets and every member of a recursive
input tree must also be owned and not group/world-writable. Broad or
destructive operations print an exact plan and require an interactive
confirmation or `--yes`; `--dry-run` performs validation without mutation.
The [trash](#trash) is the one mutation outside the current directory:
`put` moves reviewed targets into the user's private trash, and `restore`
moves them back to their recorded, revalidated original paths. `put` is also
the only plan that accepts a symbolic link, as the link itself.

Selections are typed records validated against the current snapshot. `fzf`
runs synchronously in the foreground and writes its result to a private,
bounded capture file. No selected row is interpreted as shell program text.

Generated files use private staging below a validated current-user directory
or a sticky shared temporary root owned by the namespace-visible owner of `/`.
A new output is published without clobbering an entry that appeared after
review. An explicit `--overwrite` applies only to the unchanged, singly linked
regular file whose identity and SHA-256 content digest were frozen in the plan.
Staging results must match the requested parent and temporary-name template,
with the expected owned private object type, before any write or cleanup.
Unexpected `mktemp` output is refused without changing that path.

Large-file deletion, junk-file deletion, and trash purges share one engine.
Large-file and junk-file plans reject symlinks, special files, duplicate
targets, ancestor/descendant target sets, embedded mounts (see
[Mount boundaries](#mount-boundaries)), and hard-linked files; one refused
target stops the whole plan before any deletion. `file-clean-junk` screens
its candidates before planning, as described below, so a junk file that fails
the per-target checks is skipped instead. A trash purge passes the engine a
trashed symbolic link, which it removes as the link itself and never follows;
a directory still gets the full recursive check before removal. Each deletion
first moves the exact reviewed object to an
unpredictable same-directory quarantine, validates that identity, and deletes
only the quarantine. GNU and uutils `mv` perform that move with `-T -n`;
other implementations, such as BSD `mv` on macOS, get `-n` alone, so a
directory that appears at the quarantine name between the last check and the
move could receive the target instead of being refused. The identity check
after every move detects that case, nothing is deleted, and the error names
the recovery path. A failed removal retains and reports the recovery path.
Path inventories are bounded and exclude control-bearing names from
interactive records; archive input trees are bounded and refuse such names.

The deletion plan follows the exact-target form of
[`output-spec.md`](output-spec.md): a `Directory:` fact with `HOME` shown as
`~`, a numbered `# · Path` table relative to that directory, and any
disclosures, such as a warning about skipped files. A dry run ends with
`Dry run: <count> planned; nothing was deleted.`; the confirmation names the
counted scope, such as `Delete 3 files?`, and a decline prints
`Cancelled: nothing was deleted.` and returns `0`. Each target then reports
`Deleted <path>` or its failure status, and the verdict counts the result:
`Deletion completed: 3 files deleted.`, `Deletion completed with partial
failures: 1 of 3 files failed.`, or `Deletion failed: 3 of 3 files failed.`.
A partial failure marks the timing footer as partial. Plans count files, or
targets when a plan includes a directory.

A successful large-file inventory returns `0` independently of the last
candidate or whether any candidate matches. A later smaller candidate cannot
discard earlier results. Collection failures, including interruptions, retain
their status and publish no partial path list.

Multi-target plans preserve one complete identity per selected path, including
archive inputs and deletion targets. All targets are revalidated after
authorization before the first mutation. Independent ordinary deletion failures
are reported while later targets remain eligible; an execution interruption
(`130` or `143`) stops the batch and preserves that status. Completed
deletions remain in place, and an interrupted deletion retains its reported
quarantine when removal did not finish.

## Mount boundaries

A recursive operation must not cross into another filesystem, so deletion
targets, every node of a directory archive input, and their revalidation
refuse a mount at a target or below a directory target:

- **Linux and WSL** read the kernel mount table, `/proc/self/mountinfo` (the
  table `findmnt` reads), decode its octal escapes, and compare canonical
  paths with every mount point, which also catches bind mounts. One snapshot
  serves each pass: the deletion plan, the archive input plan, and each
  revalidation take one, and execution takes a fresh one after authorization
  instead of one probe per path. A directory removed recursively always takes
  its own fresh snapshot immediately before its move. The table is bounded to
  4 MiB and 16,384 records, and an unreadable or malformed table fails
  closed. `findmnt` itself is not required.
- **macOS** has no bind mounts, so a node whose device number differs from
  its parent's (`zstat`, without following links) is a mount point. Every
  node is checked when it is validated, with no snapshot to go stale.
- **Other kernels** fail closed with
  `Recursive mount-boundary validation is not supported on <kernel>.`

## Junk-file cleanup

`file-clean-junk` finds regular files below the current directory whose name
exactly matches `*:Zone.Identifier` (Windows download marks that reach WSL),
`.DS_Store` (macOS Finder), `._*` (AppleDouble forks), `Thumbs.db`, or
`desktop.ini`. Similar names such as `notes.DS_Store.txt` or `thumbs.db` do not
match. Discovery never follows a link, never selects a directory or a link
named like junk, and never enters `.git`, `*.git`, `node_modules`, `.venv`,
`.tmp`, `vendor`, `vendored`, `site-packages`, `dist-packages`, `.tox`, or
`.nox`.

Nested repositories and linked worktrees are searched like any other
directory, so running the command from a folder of repositories, such as
`~/workspaces`, plans the junk in all of them; only their `.git` directories
are never entered. The plan lists every exact path before confirmation, so
junk that a repository tracks is visible before it is deleted. Discovery looks
12 levels deep and shares the suite's inventory bounds of 4,096 matching
entries and 1 MiB of path data; exceeding either fails closed before planning.
A directory that cannot be listed is skipped with a warning instead of failing
the scan, because nothing below it could be deleted. A name containing a
control character or `|` cannot be planned and is skipped with a warning.
With GNU `find`, discovery is one `find` expression using `-readable`,
`-executable`, and `-printf`. A `find` without them, such as BSD `find` on
macOS, is detected by a capability probe, and a Zsh walker applies the same
names, prunes, depth, link, and readability rules (`access(2)`, as GNU
`-readable` uses) and produces the same records; a directory that becomes
unreadable while it is listed fails the scan instead of hiding entries.

The operation base is validated before discovery. Each candidate is then
screened against the per-target mutation boundary: it must still be a regular
file, be owned by the current user, not be writable by group or others, and
have one hard link. A file that fails is skipped rather than refusing the
plan. One counted warning names how many were skipped and why, such as
`Skipped 2 junk files that cannot be deleted safely: 1 writable by group or
others, 1 hard-linked.`, followed by each file and its reason when at most
three were skipped or `ZDX_VERBOSE=1` is set, and otherwise by a hint to set
it. A directory above any candidate that is untrusted against replacement, or
that changed into a link, still refuses the whole run, as an unsafe base does.

The remaining files form one bytewise-sorted plan for the shared deletion
engine above, so `--dry-run`, confirmation, `--yes`, quarantine, and
interruption behave exactly as for large-file deletion, and revalidation after
authorization stays strict: a target that changed refuses the whole plan
before the first deletion. An empty result prints `No junk files found.`, and
a result whose files were all skipped prints the warning and
`No junk files can be deleted safely.`; both return `0` without a prompt.
Skipped files do not change the exit status.

## Trash

`file-trash` gives deletion a recoverable step. It owns one private
directory, `${XDG_DATA_HOME:-~/.local/share}/zdx/trash`, laid out like a
freedesktop.org trash: `files/<id>` holds each item and `info/<id>.trashinfo`
describes it.

```text
[Trash Info]
Path=/home/jane/projects/notes%20old.txt
DeletionDate=2026-10-05T14:30:12
```

`Path` is the canonical absolute original path with every byte outside
`A-Z a-z 0-9 / . _ ~ -` written as `%XX`; `DeletionDate` is local time. An ID
is the local time of the move plus six hexadecimal digits, such as
`20261005-143012-a1b2c3`. The trash is separate from the desktop trash in
`$XDG_DATA_HOME/Trash`, so file managers do not show these items.

### Storage

`XDG_DATA_HOME` must be absolute and normalized; a relative value is refused
rather than ignored. The nearest existing directory of the trash path
resolves through the trusted-directory rule and needs trusted ancestors.
Missing directories are created mode `700`, and only below a directory that
the user owns and others cannot write. The trash and its `files` and `info`
directories must remain real, owned, mode `700` directories: a looser or
linked one is refused, never repaired, and on WSL a trash on a Windows drive
gets the DrvFs hint. Records are published mode `600`. Read-only actions and
dry runs never create the trash.

### Actions

- **`put PATH...`** plans exact targets under the
  [mutation boundary](#filesystem-and-mutation-boundary): each path must
  resolve below the current directory, which itself, `..`, paths outside it
  or through symbolic links, controls, and `|` are refused, as are the trash,
  a directory that contains it, and paths inside it. A symbolic link is
  planned as the link itself, below a canonical trusted parent, and is never
  followed. A directory must pass the recursive check the deletion engine
  applies before a purge (no links, special or hard-linked files, foreign or
  writable entries, or mounts, and at most 4,096 entries), so everything in
  the trash can be purged later. The plan shows `Directory:`, `Trash:`, and a
  `# · Path · Type` table, a dry run ends with
  `Dry run: 2 items planned; nothing was moved.`, and the question is
  `Move 2 items to the trash?`.
- **`list [--json]`** is read-only. It shows `ID`, `Deleted`, `Type`, `Size`,
  and `Original path`, newest first; a directory's size is the apparent size
  of its regular files. Entries that cannot be restored, a record without an
  item, an item without a record, an invalid record, or an unsafe item, are
  counted in one warning and listed when at most three or with
  `ZDX_VERBOSE=1`.
- **`restore [ID...]`** moves valid entries back. Nothing may exist at the
  original path, and its parent must still exist as a canonical directory
  that the user owns and others cannot write, below trusted ancestors; a
  missing parent is explained and never recreated, and one refused item stops
  the whole plan. The plan is `# · ID · Restore to`, and the question is
  `Restore 2 items?`.
- **`purge [ID... | --older-than DAYS | --all]`** deletes an item and then its
  record through the quarantined deletion engine above. `--older-than`
  selects valid entries whose deletion time is more than DAYS × 24 hours ago;
  IDs and `--all` also reach damaged entries. The plan
  (`# · ID · Deleted · Original path`) carries the disclosure
  `Purged items cannot be restored.`, and the question is
  `Permanently delete 2 items?`.
- **No action**, or `restore` and `purge` without a selection, opens a
  picker of the current entries. Rows carry only their snapshot index back
  from `fzf`; the selection must be in the snapshot, and the dispatcher then
  asks whether to restore or purge. `--dry-run` and `--yes` apply to the
  resulting plan.

Every plan is revalidated after authorization and again immediately before
each move: the item, record, target or tree, parent identity, and absent
destination must be unchanged. Results follow the exact-target form of
[`output-spec.md`](output-spec.md), such as `Trashed notes.txt as
20261005-143012-a1b2c3`, with a counted verdict (`Trash completed: 2 items
moved.`, `Restore completed: …`, `Purge completed: …`), partial-failure
timing, and an interruption (`130` or `143`) that stops before later items.
An empty trash prints `The trash is empty.` and returns `0`.

### Moves and records

Every move is the suite's no-clobber `mv` adapter on one filesystem, never a
copy followed by a deletion. Before a move, the source and the destination
directory must report the same device number, and on Linux and WSL the
nearest mount point of each canonical path in the pass's mount-table
snapshot must match too, because a bind mount keeps the device number but
refuses a rename. A source or restore destination on another filesystem is
refused with that explanation. After each move, the moved node must keep its
reviewed device, inode, type, owner, and link count.

`put` reserves an ID by publishing its record first: the record is written
to private staging in `info/` and published with the suite's hard-link
publication, which fails rather than replace an existing name. A failure
before the rename withdraws that record. `restore` deletes the record through
the quarantine engine after the item is back; if that fails, the restore
still counts and the record remains as an entry without an item.

Records are parsed strictly as data. A record must be a private, singly
linked regular file owned by the user, at most 16 KiB, containing exactly
`[Trash Info]`, one `Path=` line, and one `DeletionDate=` line with no NUL,
control character, unknown key, or malformed `%XX` escape. The decoded path
must be absolute and normalized (no `.`, `..`, or empty segments), at most
4,096 bytes, free of controls and `|`, and outside the trash, `HOME` itself,
and the suite root; the date must be a real `YYYY-MM-DDThh:mm:ss` time. Any
other record makes its entry an invalid record that can be purged but never
restored.

### Concurrency

The File suite has no lock primitive, so each trash operation is safe under
concurrency instead: a record reserves its ID with a no-clobber publication,
every move uses a no-clobber rename whose result is identity-checked, and
every plan revalidates after authorization and before each move. A
concurrent invocation can make an operation fail, but it cannot clobber an
item or record or make one item restore twice.

### JSON

`file-trash list --json` prints one compact document, a single line, and
nothing else on stdout; it never opens `fzf` or prompts, and its exit status
equals the text mode's. jq builds the document from the records it reads as
raw lines on stdin, so no data becomes program text. Without `jq`, it
reports the missing capability on stderr and returns `1`. Expanded for
reading, the document looks like this:

```json
{
  "schema": "zdx.file-trash.v1",
  "trash_dir": "/home/jane/.local/share/zdx/trash",
  "item_count": 1,
  "items": [
    {
      "id": "20261005-143012-a1b2c3",
      "original_path": "/home/jane/projects/notes old.txt",
      "deleted_at": "2026-10-05T12:30:12Z",
      "size_bytes": 1234,
      "type": "file"
    }
  ],
  "skipped": [
    { "id": "20261004-090000-0f1e2d", "reason": "missing_item" }
  ]
}
```

`deleted_at` is the record's local time converted to UTC; `type` is `file`,
`directory`, or `symlink`; `size_bytes` is `null` when a directory exceeds the
inventory bound; and `reason` is `missing_item`, `missing_info`,
`invalid_info`, or `unsafe_item`.

## Archive boundary

Compression supports `tar.gz`, `tar.xz`, `tar.bz2`, `zip`, and `7z` when the
corresponding backend is installed. Input trees are bounded, reject links and
special entries, and may not cross a mount or overlap another selected input.
TAR archives are created with GNU tar when `tar` or `gtar` is GNU tar; it
stores no macOS metadata. Otherwise `tar` is used, with `--no-mac-metadata`
and `--no-xattrs` when a capability probe shows it accepts them, as macOS
bsdtar does. Every creation also exports `COPYFILE_DISABLE=1`, so archives
made on macOS carry neither AppleDouble `._*` members nor extended-attribute
headers. 7z archives use the first of `7z`, `7zz` (7-Zip 21 and newer, as
Homebrew's `sevenzip` installs it), and `7za`.

Hardened extraction intentionally supports only GNU TAR archives and requires
GNU tar, found as `tar` or `gtar` (Homebrew's `gnu-tar` on macOS); bsdtar is
never used because its listings lack the escaped, typed fields the preflight
parses. The one resolved program lists, preflights, and extracts the same
snapshot. Archive extensions (`.tar`, `.tar.gz`, `.tgz`, `.tar.xz`,
`.tar.bz2`) are matched without regard to letter case, so `.TAR.GZ` is
accepted. Before extraction, the suite rejects:

- absolute paths and `..` traversal;
- duplicate archive member names, and on macOS, whose default filesystems
  ignore letter case, names or parent directories that differ only by case;
- symbolic links, hard links, devices, FIFOs, and other special entries;
- more than 4,096 entries;
- an inventory larger than 1 MiB; and
- a declared expanded size above 1 GiB.

The source archive is copied once into a private same-filesystem snapshot. Its
digest is matched to the unchanged source, and preflight plus extraction read
that same frozen snapshot. Extraction occurs in a private directory, and the
realized tree must reproduce every explicit member with its planned type and
exact regular-file size; only necessary implicit parent directories are
accepted, and realized bytes must equal the declared bounded total. A
destination that was absent at review is then published without merging into
existing data, through the same `mv` adapter as deletion; the published
directory must keep the staging identity, and a destination directory that
appeared meanwhile is reported with the path that received the validated
tree. ZIP, RAR, and 7z extraction fail closed.

## Streams, dependencies, and residual limits

UI, plans, warnings, and prompts use stderr. Without `--delete`,
`file-find-large` writes its documented data to stdout: one matching path per
line, or the selected paths after the interactive `show` action.
`file-trash list --json` writes its one `zdx.file-trash.v1` document; every
other `file-trash` form and `file-clean-junk` write nothing to stdout. The
trash needs `mv`, `ln`, `mkdir`, `mktemp`, `rm`, and `sha256sum` or `shasum`;
its pickers need `fzf`, and `--json` needs `jq`.

Content digests open the file without following a link and hash it through
standard input with `sha256sum` or `shasum -a 256`, so a name with a
backslash, which both tools escape in their output, and a FIFO, which could
block an open, are handled. Inventories use `find`, `head -c`, and `mktemp`
with options that GNU and BSD userlands share.

A hostile process with the same EUID can still race the final userspace check
and pathname operation. Directory descendants are re-inventoried but are not
held through filesystem handles for the complete compression transaction. In
a user namespace where overflow UID mappings collapse multiple host owners
into one visible UID, this trust model also depends on the namespace and
mount configuration faithfully isolating `/`. The same race applies between
the trash's same-filesystem check and its rename: a mount created over the
trash or a source in that window, such as a user FUSE mount, could let `mv`
fall back to copying; the post-move identity check then reports the
mismatch, and the data stays in the trash.

## Platform support

| Capability | Linux | WSL | macOS |
| --- | --- | --- | --- |
| Mount boundary | `/proc/self/mountinfo` snapshot | as Linux | device numbers |
| Junk discovery | GNU `find` | GNU `find` | Zsh walker |
| No-clobber moves | `mv -T -n` | `mv -T -n` | `mv -n` and identity check |
| Trash moves | same device and mount point | as Linux | same device |
| TAR creation | GNU tar | GNU tar | `gtar`, or bsdtar without metadata |
| TAR extraction | GNU tar | GNU tar | `gtar` only (Homebrew `gnu-tar`) |
| 7z creation | `7z`, `7zz`, or `7za` | as Linux | `7zz` from Homebrew `sevenzip` |

On WSL, the Windows drives below `/mnt` (DrvFs, or 9p) report every file as
mode 777 unless WSL mounts them with metadata, so the ownership and permission
checks refuse them. That refusal stays; for a base or ancestor below
`/mnt/<drive>` on WSL, the suite adds a hint to work in the Linux filesystem or
to add `[automount] options="metadata,umask=22,fmask=11"` to `/etc/wsl.conf`
and restart WSL. WSL is recognized from `WSL_DISTRO_NAME` or `WSL_INTEROP`,
its interop registration (`WSLInterop` or `WSLInterop-late`), or a Microsoft
kernel release.

Linux behavior runs natively in every test run. The WSL drive hint and WSL
detection, the macOS device comparison, BSD `mv`, bsdtar, `gtar`, `7zz`, the
junk walker, case-insensitive archive names, and trusted working-directory
aliases are verified on Linux through `uname` mocks, `PATH` shims, function
overrides, and fixtures, and the same tests run on the macOS CI job's Apple Silicon runner with its real BSD tools and
APFS volume. A real DrvFs mount, WSL1, and APFS case-sensitive volumes, on which
the case-folding refusal is stricter than necessary, remain manual acceptance
boundaries.

Focused coverage lives in `test/file.bats`, `test/file_contract.bats`,
`test/file_safety.bats`, `test/file_discovery_status.bats`,
`test/file_recovery.bats`, `test/file_junk.bats`, `test/file_trash.bats`,
and `test/file_platform.bats`, with trusted working-directory aliases in
`test/platform_paths.bats`. Trash tests run with `HOME` and the trash inside
the sandbox and cover the round trip of files, directories, links, and
names with spaces or a leading dash; refused control and `|` names, paths
outside or equal to the current directory, links in the path, the trash
itself, and directories the purge engine could not delete; private modes,
the record format, and `XDG_DATA_HOME`; dry runs, declines, and
terminal-less refusals; revalidation after confirmation; a failed or
interrupted move that withdraws its record; unique IDs; a mocked device
change and a bind mount from a fixture mount table; no-clobber and
missing-parent restores; age, ID, and `--all` purges through the quarantine
engine; malicious and damaged records; the JSON document and its UTC
conversion; and the picker with a forged row. Discovery regressions
explicitly order matching and smaller candidates, include empty results, and
retain scan failures. Recovery tests execute a real multi-file large-file
deletion and a real GNU TAR round trip in disposable trees; the round trip and
the interrupted extraction skip when the host has no GNU tar as `tar` or
`gtar`. Junk-file tests
cover the empty result, dry run, non-interactive refusal, decline, exact names
including colon and leading-dash names, names the plan cannot represent, links
and directories named like junk, pruned Git metadata and generated trees,
junk planned across a folder of repositories and worktrees, skipped
group-writable, hard-linked, and foreign-owned files with their counted
warning and verbosity listing, an unsafe directory above a candidate, the
depth bound, unreadable directories, inventory failures, an unsafe base, a
target or base changed after confirmation, a counted partial failure, and an
interrupted deletion that retains its quarantine. A File safety test keeps
large-file deletion refusing its whole plan for an unsafe target, and another
keeps a directory archive input planned as exactly that directory. Platform
tests cover one mount snapshot per pass, escaped and bind mount points, device
changes, unsupported kernels, the `mv` adapter, GNU tar as `gtar` behind a
bsdtar `tar`, metadata-free bsdtar creation, `7zz`, backslash names and FIFOs
in digests, case-colliding and uppercase archives, the WSL hint and
detection, the junk walker, and the menu's unavailable form.
Other archive backends, a real macOS or WSL host, and cross-filesystem
behavior remain manual boundaries.
