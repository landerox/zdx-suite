# Hugging Face suite contract

This document freezes the public Hugging Face interface and records the
installed-backend, network, stream, and cache-deletion boundaries.

## Public surface

| Command | Grammar |
| --- | --- |
| `hf-search` | `--type model\|dataset --query TEXT [--limit N] [--list]` |
| `hf-repo-stats` | `--type model\|dataset --repo REPOSITORY` |
| `hf-cache-inspect` | `[--list]` |
| `hf-cache-clear` | `[--type TYPE --repo REPOSITORY] [--dry-run] [--yes]` |
| `hf-download` | `--type TYPE --repo REPOSITORY (--snapshot\|--file FILENAME)` |

With no arguments, commands that require a target use the interactive picker.
Direct downloads always require an explicit `--snapshot` or `--file` mode.
Invalid syntax returns `2`; an interactive cancellation returns success.

The command menu follows [`menu-spec.md`](menu-spec.md): inspection precedes
downloads, with local cache deletion last. `Ctrl-/` toggles the compact command
details. Repository and file browsers retain their own content layouts.

## Backend and network policy

The suite requires an already-installed `huggingface_hub` version from 0.23
through the 1.x series. It uses `python3`, `python`, or the explicit
`HF_PYTHON` interpreter with isolated Python mode. It never invokes `pip`,
`uv run --with`, `uvx`, a remote installer, or any other implicit package
bootstrap.

Search, repository metadata, remote file-list inspection, cache inventory, and
cache-plan scans are bounded by a 15-second `timeout` or `gtimeout` probe.
Actual snapshot and file downloads are not killed by this wrapper because a
large authorized transfer may legitimately take longer. The Hub library and
its normal `HF_TOKEN` authentication remain external trust boundaries.

Direct downloads and download actions selected from search share one executor
in `hf-download.zsh`. A start message is immediate; a fixed activity notice
appears every five seconds while the installed backend runs. These notices
show activity, not byte progress or a guarantee that a remote server is making
progress. The Python worker stops when the operation finishes; no background
Zsh job or additional transfer deadline is introduced.

Raw library stdout, progress, and exception text are hidden. Fixed failure
messages distinguish denied access, missing or inaccessible targets, network
problems, and cache storage failures. Successful results must name an existing,
readable snapshot directory or file; normal Hub file symlinks remain supported.
Failed or interrupted downloads show a safely quoted retry command and leave
existing cache data in place. The installed backend controls cache reuse, as
described in the [Hub download guide](https://huggingface.co/docs/huggingface_hub/guides/download).
Download/backend-discovery and download file-list interruptions retain status
`130` or `143`; cancelling a picker before starting a download remains success.

Repository types, IDs, queries, limits, filenames, metadata records, and
picker rows are typed and bounded. Repository filenames must be relative and
may not contain empty, `.` or `..` components. Picker output is captured
privately in the foreground below a validated current-user directory or
a sticky shared temporary root owned by the namespace-visible owner of `/`
(normally UID 0), and must match the displayed snapshot. Temporary-root
ancestors must be owned by that system-root identity or the current EUID and
protected against replacement.

Search records are accumulated and validated before stdout publication. A
search may return at most the requested 1-100 unique repositories; counters
must be exact non-boolean non-negative integers of at most 19 decimal digits.
Single-file discovery consumes the Hub's paginated repository-tree iterator
incrementally and stops at 2,001 files or 4,097 total tree records, before
publishing any filename.

## Stream contract

UI, progress, metadata rendering, plans, warnings, prompts, and cache paths use
stderr. Structured stdout is available only for:

- `hf-search --list`: `repo_id<TAB>downloads<TAB>likes`; and
- `hf-cache-inspect --list`:
  `repo_id<TAB>type<TAB>bytes<TAB>size<TAB>files`.

Remote and local display values are bounded and visibly escaped before terminal
rendering.

## Cache deletion

`hf-cache-clear` deletes one exact repository discovered by the installed
Hub cache scanner. It:

1. validates the repository record and resolves the configured
   `HF_HUB_CACHE` independently of the selected repository path;
2. requires a canonical, owned, symlink-free, non-group/world-writable target
   with the exact expected `models--...` or `datasets--...` name directly
   below that configured, owned cache root inside `HOME`;
3. fingerprints the root and target;
4. prints the exact plan and supports `--dry-run`;
5. requires interactive authorization or `--yes`;
6. revalidates the frozen plan; and
7. requires a timeout-bounded JSON `findmnt` inventory, parsed as decoded
   structured data, with no mount at or below the target; and
8. atomically renames the target to a random quarantine before recursive
   removal.

If recursive removal fails or Python receives an interrupt while the
quarantine still exists, the command reports that retained recovery path; it
does not report a path already removed successfully. Cache entries of type
Space are outside this public surface and are skipped without invalidating
supported model/dataset entries. Cache absence is handled through the
top-level `CacheNotFound` API supported throughout the declared
`huggingface_hub` range. The inventory accepts at most 1,000 supported
repositories and applies explicit per-record and aggregate size and file-count
bounds.

A hostile process with the same EUID still has a narrow final race around
pathname operations. A failed recursive deletion can leave a reported
quarantine for manual recovery. If overflow UID mapping collapses multiple host
owners into the namespace-visible owner of `/`, safety also depends on the
namespace and mount configuration.

Focused coverage lives in `test/hf.bats`, `test/hf_contract.bats`,
`test/hf_safety.bats`, and `test/hf_recovery.bats`. Recovery fixtures run the
production Python download adapter against an in-memory Hub module, including
activity before completion, classified failures, cached file symlinks, and
interruption/cancellation distinctions. Non-gated repository statistics return
success after rendering their complete metadata. Live Hub, authenticated
gated-repository, large download,
real-cache acceptance, and installed-backend acceptance at both the 0.23.x and
1.x compatibility edges remain manual boundaries.
