# Environment suite contract

This document freezes the public Environment interface and the security
boundary implemented by `functions/env-menu.zsh`, `functions/env-common.zsh`,
and the modules under `functions/env/`.

## Public surface

The canonical commands are:

| Command | Purpose |
| --- | --- |
| `env-switch` | Passively parse and load one reviewed dotenv file |
| `env-create` | Atomically publish one private dotenv file |
| `env-list` | Inspect masked exported variables or copy one exact value |
| `env-path` | Inspect PATH and explicitly deduplicate the active session |
| `env-profile-save` | Persist selected exported scalars privately |
| `env-profile-list` | List validated profile metadata |
| `env-profile-load` | Passively parse and load one reviewed profile |
| `env-profile-delete` | Quarantine and delete one unchanged profile |

The fixture `test/fixtures/env-public-commands.tsv` is the machine-readable
surface. Menu rows, help, dispatch, lazy loading, completion, modules, and
public functions must remain aligned with it.

`env-menu` with no arguments opens the interactive menu. It also accepts one
canonical command followed by that command's unchanged arguments. Invalid
syntax returns `2`; interactive cancellation returns success.

The command menu follows [`menu-spec.md`](menu-spec.md), with inspection first,
then dotenv and profile actions. The `env >` prompt and directory header orient
the current session; `Ctrl-/` toggles the compact command details. Variable
values remain excluded from menu rows and previews.

## Command grammar

```text
env-switch [--dry-run] [--yes] [--] [DOTENV_FILE]
env-create [--template FILE] [--output FILE] [--overwrite]
           [--dry-run] [--yes]

env-list
env-list --list
env-list --copy VARIABLE

env-path
env-path --list
env-path --dedupe [--dry-run] [--yes]

env-profile-save [--overwrite] [--dry-run] [--yes]
                 [--] [PROFILE [VARIABLE...]]
env-profile-list [--list]
env-profile-load [--dry-run] [--yes] [--] [PROFILE]
env-profile-delete [--dry-run] [--yes] [--] [PROFILE]
```

Use `--` before a dotenv path or profile operand that begins with `-`.
Interactive operands are optional conveniences over the same private command
functions. `--yes` authorizes only the already printed and validated plan;
`--dry-run` never mutates shell or filesystem state.

## Passive dotenv boundary

Dotenv and profile files are data, never shell programs. The suite does not
use `source`, `eval`, command substitution, parameter expansion, arithmetic
expansion, or escape decoding on their contents. A key must match
`[A-Za-z_][A-Za-z0-9_]{0,127}` and may not collide with protected Zsh
parameters. Duplicate keys, malformed records, oversized input, and unclosed
quotes fail the whole parse before any export occurs.

Dotenv input supports blank lines, full-line comments, an optional literal
`export` prefix, unquoted values, and literal single- or double-quoted values.
Quoted values may span lines. Quotes delimit data only; backslashes and `$`
have no executable meaning. Leading and trailing horizontal whitespace around
records is discarded. Inline comments are data. At most 512 records and 1 MiB
are accepted.

The complete file is parsed into a frozen in-memory snapshot before a mutation
plan is printed. Plans list keys and whether they replace or create a scalar,
but never values. Existing special, read-only, array, associative, local-only,
or unexported shell parameters are not overwritten. Loading revalidates file
identity after review and rolls back newly applied ordinary exported scalars
if a later assignment fails.

Interactive discovery is bounded to three directory levels, 512 candidates,
and 4,096 visited nodes. It excludes links, special files, unsafe directories,
and common dependency or VCS trees. File contents never enter an `fzf` row or
preview. Explicit files and discovered files share the same validation and
parser.

Automatic `chpwd` loading is intentionally not registered. Directory entry is
not authorization to import environment data, and hook registration would
make eager and lazy loading observably different. Call `env-switch` explicitly
or build a separately reviewed opt-in plugin if automatic policy is required.

## File and state transactions

Dotenv operations are rooted at the canonical invocation directory. The root,
every relevant parent, and every input must be symlink-free and protected
against group/world replacement. Inputs must be owned regular files with one
hard link, bounded size, and no group/world write permission. Environment
files that are readable by other accounts are accepted for compatibility; use
mode `600` when they contain secrets.

`env-create` publishes mode-`600` output below that root. It stages content in
a private same-directory directory, creates the destination without
clobbering, and removes staging only after publication. `--overwrite` applies
only to the unchanged regular file frozen in the plan. The original is first
quarantined in the private directory; a publication failure restores it when
safe or reports the retained recovery path.

Creation preserves leading literal quotes by adding an outer delimiter pair
under the passive dotenv grammar. Backslashes, dollar signs, hash characters,
and empty values retain their literal meaning after a later `env-switch`.
Interactive creation still rejects multiline values; passive loading continues
to support quoted multiline input.

The complete fingerprint is checked before each planned move. Immediately
after that authorized rename, only its expected `ctime` change is allowed;
device, inode, mode, owner, link count, size, modification time, and content
digest must still match. The resulting complete fingerprint is frozen again
for subsequent cleanup or restoration. An older file therefore does not become
a false replacement warning merely because the suite moved it into quarantine.

Profiles default to
`${XDG_CONFIG_HOME:-$HOME/.config}/zdx/env-profiles`; an explicit
`ZDX_ENV_PROFILES_DIR` must be absolute and still resolve below `HOME`.
An explicit `XDG_CONFIG_HOME` must also be absolute. The profile directory
must be owned, symlink-free, and mode `700`; profile files must be singly
linked owner files with mode `600`. New state is created component by
component only during an authorized save. Read-only commands never initialize
state.

The suite-owned profile format starts with
`# zdx-environment-profile-v1` and stores literal one-line `KEY=value`
records. Newlines, controls, and edge whitespace are rejected because the
format cannot preserve them unambiguously. Save and overwrite use the same
atomic publisher as `env-create`. Delete freezes identity, confirms one exact
path, moves it into a private same-directory quarantine, validates the moved
identity, and deletes only that quarantine object. Failed cleanup retains and
reports recovery data.

## Secret and picker boundary

All exported values are withheld from rows and `--list` output. Names matching
credential patterns such as `token`, `password`, `secret`, `api_key`,
`credential`, `private`, `cookie`, or `session` are classified as `********`;
all other names use `<hidden>`. No prefix or suffix is disclosed. Raw values
never enter rows, previews, logs, plans, errors, fallback output, or temporary
picker files. Interactive value prompts disable terminal echo.
`env-list --copy NAME` and an explicit interactive selection may send the
exact frozen value directly to a supported clipboard backend. If copying
fails, the value is not printed.

Every picker uses three-field fixed records or indexed typed records, validates
the returned row against the frozen snapshot, and maps an index back to the
original object. A single-select picker rejects multiline output rather than
reclassifying it as cancellation. `fzf` runs synchronously in the foreground.
Its output is captured through an owner-only bounded file below a validated
private or sticky-system temporary parent. Each `mktemp` result must first
prove that it is the expected owned direct child before `chmod` or cleanup can
touch it, and command substitution cannot suspend on TTY output.

## PATH and stream contract

`env-path` is read-only by default. Empty PATH components are reported as the
current directory rather than silently discarded. `--dedupe` removes later
duplicates while preserving order and empty components, prints the exact
removal plan, confirms it, and compares the current PATH with the frozen
snapshot immediately before assignment.

All UI, plans, warnings, prompts, timing, and success messages use stderr.
Documented stdout data is limited to:

- `env-list --list`: `NAME<TAB>CLASSIFICATION`, with every value hidden;
- `env-path --list`:
  `INDEX<TAB>ENTRY<TAB>STATE<TAB>WRITABLE<TAB>DUPLICATE`; and
- `env-profile-list --list`: `PROFILE<TAB>VARIABLE_COUNT`.

Control-bearing display data is rendered visibly before entering records.
`NO_COLOR` and `TERM=dumb` suppress ANSI decoration. Clipboard support is
optional (`pbcopy`, `wl-copy`, `xclip`, `xsel`, or WSL `clip.exe`); no
clipboard backend is required for read-only commands. Hardened file handling
requires the Zsh `stat` and `system` modules, `sha256sum` or `shasum`, plus
`find`, `head`, `mktemp`, `chmod`, `ln`, `mv`, `rm`, and `mkdir`.

A hostile concurrent process with the same EUID can still race a userspace
pathname check and filesystem operation. File descriptors and same-directory
quarantines narrow that window, but Linux `openat2`-style resolution is not
available portably from this Zsh implementation.

Focused coverage lives in `test/env.bats`, `test/env_contract.bats`,
`test/env_safety.bats`, and `test/env_recovery.bats`. Clipboard backends and cross-platform filesystem
behavior remain manual acceptance boundaries.
