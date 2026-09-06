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
| `file-bulk-ops` | Copy, move, delete, rename, or duplicate local paths |
| `file-permissions` | Apply a validated mode to local paths |
| `file-find-large` | Find large files and optionally delete them |
| `file-find` | Find files by name, extension, content, or age |
| `file-diff` | Compare two local files or directories |
| `file-encode-decode` | Encode or decode Base64 text and files |
| `file-checksum` | Generate or verify SHA-256 and MD5 digests |
| `file-line-endings` | Convert regular files to LF or CRLF |

The fixture `test/fixtures/file-public-commands.tsv` is the machine-readable
surface. Menu rows, help, the dispatcher, lazy loading, completion, and public
functions must stay aligned with it.

`file-menu` with no arguments opens the interactive menu. It also accepts one
canonical command followed by that command's unchanged arguments. Invalid
syntax returns `2`; an interactive cancellation returns success.

The interactive menu follows [`menu-spec.md`](menu-spec.md): inspection comes
first, followed by archives, data conversion, and file changes. Its 80% layout
uses a four-line bottom description with `Ctrl-/` to toggle details. Copy
distinguishes TAR-only extraction from the broader compression formats and
names the scope of path, permission, and text changes.

## Command grammar

```text
file-compress --format FORMAT --output FILE
              [--overwrite] [--dry-run] [--yes] -- PATH...
file-extract --destination DIRECTORY [--dry-run] [--yes] -- ARCHIVE

file-bulk-ops copy|move --destination DIRECTORY
              [--dry-run] [--yes] -- PATH...
file-bulk-ops delete [--dry-run] [--yes] -- PATH...
file-bulk-ops rename --search TEXT --replace TEXT
              [--dry-run] [--yes] -- PATH...
file-bulk-ops duplicate [--dry-run] [--yes] -- PATH...

file-permissions --mode MODE [--dry-run] [--yes] -- PATH...
file-find-large --min-size SIZE [--delete] [--dry-run] [--yes]
file-find --name GLOB
file-find --extension EXTENSION
file-find --content TEXT
file-find --days NUMBER
file-diff [--] LEFT RIGHT

file-encode-decode --encode-text TEXT
file-encode-decode --decode-text BASE64
file-encode-decode --encode-file FILE --output FILE
                   [--overwrite] [--dry-run] [--yes]
file-encode-decode --decode-file FILE --output FILE
                   [--overwrite] [--dry-run] [--yes]
file-checksum --algorithm sha256|md5 -- FILE
file-checksum --verify HEX_DIGEST -- FILE
file-line-endings --to lf|crlf [--dry-run] [--yes] -- FILE...
```

Use `--` before operands when a path begins with `-`.

## Filesystem and mutation boundary

Mutating commands are limited to canonical, owned, symlink-free targets below
an owned, non-group/world-writable invocation directory. Every ancestor must be
owned by the current EUID or by the namespace-visible owner of `/` (normally
UID 0) and must not permit unprotected replacement; a sticky shared directory
owned by that system-root identity is the only shared exception. Regular
mutation targets must have one hard link, and paths containing controls or the
internal plan delimiter are refused. Transfer, archive, and data mutations
also reject group/world-writable targets and tree members. `file-permissions`
alone may accept an owned writable target so that it can repair that mode; all
other identity, ancestor, link, and scope checks still apply. Broad or
destructive operations print an exact plan and require an interactive
confirmation or `--yes`; `--dry-run` performs validation without mutation.

Selections are typed records validated against the current snapshot. `fzf`
runs synchronously in the foreground and writes its result to a private,
bounded capture file. No selected row is interpreted as shell program text.

Generated files use private staging below a validated current-user directory
or a sticky shared temporary root owned by the namespace-visible owner of `/`.
A new output is published without clobbering an entry that appeared after
review. An explicit `--overwrite` applies only to the unchanged, singly linked
regular file whose identity and SHA-256 content digest were frozen in the plan.
Line-ending conversion stages in the same directory before replacement.
Staging results must match the requested parent and temporary-name template,
with the expected owned private object type, before any write or cleanup.
Unexpected `mktemp` output is refused without changing that path.

Bulk operations reject symlinks, special files, duplicate targets,
ancestor/descendant target sets, embedded mounts, unsafe destination parents,
hard-linked tree members, and destination collisions. Move requires a
same-filesystem destination so it cannot silently become copy-then-delete.
Move and copy publication verify source, destination, and parent postconditions.
Recursive deletion first moves the exact reviewed object to an unpredictable
same-directory quarantine, validates that identity, and deletes only the
quarantine. A failed removal retains and reports the recovery path. Search and
transfer inventories are bounded and exclude control-bearing names from
interactive records; content search treats the query literally and propagates
read failures.

Successful search and large-file inventories return `0` independently of the
last candidate or whether any candidate matches. A later nonmatch cannot
discard earlier results. Collection failures, including interruptions, retain
their status. Content-read errors return `1`. Neither failure path publishes
partial path lists.

Multi-target plans preserve one complete identity per selected path, including
archive inputs, permission changes, and line-ending conversions. All targets
are revalidated after authorization before the first mutation. Independent
ordinary failures are reported while later targets remain eligible; an
execution interruption (`130` or `143`) stops the batch and preserves that
status. Completed changes remain in place. Interrupted deletion retains its
reported quarantine when removal did not finish, and interrupted conversion
does not publish its partial staged output.

## Archive boundary

Compression supports `tar.gz`, `tar.xz`, `tar.bz2`, `zip`, and `7z` when the
corresponding backend is installed. Input trees are bounded, reject links and
special entries, and may not cross a mount or overlap another selected input.

Hardened extraction intentionally supports only GNU TAR archives. Before
extraction, the suite rejects:

- absolute paths and `..` traversal;
- duplicate archive member names;
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
previously absent destination is then published without merging into existing
data. ZIP, RAR, and 7z extraction fail closed.

## Streams, dependencies, and residual limits

UI, plans, warnings, and prompts use stderr. `file-find`,
non-destructive `file-find-large`, checksum generation, text conversion, and
`file-diff` use stdout for their documented data. `file-diff` preserves the
usual status `1` for differences.

GNU TAR is required for hardened extraction. Recursive directory operations
also require `findmnt`, and archive, bounded-inventory, and publication paths
currently rely on GNU utility behavior. macOS needs explicit adapters before
equivalent support is claimed. A hostile process with the same EUID can still
race the final userspace check and pathname operation. Directory descendants
are re-inventoried but are not held through filesystem handles for the complete
compression transaction. In a user namespace where overflow UID mappings
collapse multiple host owners into one visible UID, this trust model also
depends on the namespace and mount configuration faithfully isolating `/`.

Focused coverage lives in `test/file.bats`, `test/file_contract.bats`,
`test/file_safety.bats`, `test/file_discovery_status.bats`, and
`test/file_recovery.bats`. Discovery regressions explicitly order matching and
nonmatching candidates, include empty results, and retain scan/read failures.
Recovery tests execute local multi-file operations and a real GNU TAR round
trip in disposable trees.
Other archive backends and cross-platform acceptance remain manual boundaries.
