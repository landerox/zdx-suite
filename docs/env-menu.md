# Environment suite contract

This document freezes the public Environment interface and the security
boundary implemented by `functions/env-menu.zsh`, `functions/env-common.zsh`,
and the modules under `functions/env/`.

## Public surface

The canonical commands are:

| Command | Purpose |
| --- | --- |
| `env-list` | Inspect masked exported variables or copy one exact value |
| `env-path` | Inspect PATH and explicitly deduplicate the active session |
| `env-dotenv` | Compare a dotenv file's keys with its example and report file hygiene, read-only |

The fixture `test/fixtures/env-public-commands.tsv` is the machine-readable
surface. Menu rows, help, dispatch, lazy loading, completion, modules, and
public functions must remain aligned with it.

`env-menu` with no arguments opens the interactive menu. It also accepts one
canonical command followed by that command's unchanged arguments. Invalid
syntax returns `2`; interactive cancellation returns success.

The command menu follows [`menu-spec.md`](menu-spec.md) with a single
inspection section. The `env >` prompt and directory header orient the current
session; `Ctrl-/` toggles the compact command details. Variable values remain
excluded from menu rows and previews. When the current directory has no
`.env` entry, the dotenv row is listed as
`○ Inspect Dotenv File (unavailable: .env)`; selecting it still runs the
command, which explains the absence.

## Command grammar

```text
env-list
env-list --list
env-list --copy VARIABLE

env-path
env-path --list
env-path --dedupe [--dry-run] [--yes]

env-dotenv [FILE] [--example FILE] [--json]
```

`--yes` authorizes only the already printed and validated plan; `--dry-run`
never mutates shell state. The suite reads no profile files, reads a dotenv
file only through `env-dotenv` and only as data, persists no state, and
registers no `chpwd` or other shell hook when it is sourced.

## Secret and picker boundary

All exported values are withheld from rows and `--list` output. Names matching
credential patterns such as `token`, `password`, `secret`, `api_key`,
`credential`, `private`, `cookie`, or `session` are classified as `********`;
all other names use `<hidden>`. No prefix or suffix is disclosed. Raw values
never enter rows, previews, logs, plans, errors, fallback output, or temporary
picker files. `env-list --copy NAME` and an explicit interactive selection may
send the exact frozen value directly to a supported clipboard backend. If
copying fails, the value is not printed: no backend reports
`No supported clipboard backend is available; the value was not printed.`,
and a backend that fails reports
`The clipboard backend failed; the value was not printed.`

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
current directory rather than silently discarded. Entries are compared without
trailing slashes, so `/x/` duplicates an earlier `/x`. `--dedupe` removes
later duplicates while preserving order and empty components, prints the
exact removal plan, naming the kept entry when the text differs, such as
`remove later duplicate: /x/ (same as /x)`, confirms it, and compares the
current PATH with the frozen snapshot immediately before assignment. Entries
that differ from an earlier entry only by letter case, such as `/usr/Local/bin`
after `/usr/local/bin`, name one directory on a case-insensitive filesystem,
such as macOS's default or a Windows drive, but two on Linux. Inspection and
the deduplication plan report them, for example
`1 PATH entry differs from an earlier entry only by letter case; deduplication
keeps it.`, and deduplication never removes them; their `--list` `DUPLICATE`
field stays `no`.

All UI, plans, warnings, prompts, timing, and success messages use stderr.
Documented stdout data is limited to:

- `env-list --list`: `NAME<TAB>CLASSIFICATION`, with every value hidden;
- `env-path --list`:
  `INDEX<TAB>ENTRY<TAB>STATE<TAB>WRITABLE<TAB>DUPLICATE`; and
- `env-dotenv --json`: one `zdx.env-dotenv.v1` JSON object (see
  [Dotenv check](#dotenv-check)).

Control-bearing display data is rendered visibly before entering records.
`NO_COLOR` and `TERM=dumb` suppress ANSI decoration. Clipboard support is
optional; no clipboard backend is required for read-only commands. Interactive
pickers require `fzf`, the Zsh `stat` and `system` modules, `mktemp`, `rm`,
and `rmdir`.

## Dotenv check

`env-dotenv` is read-only. It compares the keys of a dotenv file with an
example file and reports facts about the dotenv file. It never sources,
evaluates, expands, or exports either file, and it never changes a file's
contents, mode, or Git state: every remedy is printed as a hint, never run.

### Files

`FILE` defaults to `.env` in the current directory. Without `--example`, the
example is the first of `.env.example`, `.env.sample`, `.env.template`, and
`.env.dist` that exists next to `FILE`, other than `FILE` itself. The first
existing name wins even when it is a link or another non-regular entry, so it
is refused rather than silently skipped. Without any example, key comparison
is reported as not checked and every other check still runs.

Both files are read through a no-follow, non-blocking descriptor whose device
and inode must match the inspected path. A symbolic link, a directory, a FIFO,
or another non-regular file is refused, as is a file larger than 1 MiB or
longer than 10,000 lines. A file owned by another user is read and reported,
not refused: the check reads data only, so ownership is a hygiene fact rather
than a trust boundary. An absent dotenv file fails with a hint to create it
from the example; an absent `--example` file fails. A `FILE` that begins with
`-` is passed as `./-name`.

### Supported syntax

The parser follows the subset that common dotenv loaders such as
python-dotenv and dotenv for Node.js accept:

- Lines end with LF; a CR before the LF is removed, so CRLF files parse. A
  UTF-8 byte-order mark at the start of the file is ignored.
- Blank lines and lines whose first non-blank character is `#` are comments.
- An assignment is optional blanks, an optional `export` followed by blanks,
  a key, optional blanks, `=`, and a value. Keys match
  `[A-Za-z_][A-Za-z0-9_]*` and are at most 128 characters long.
- An unquoted value runs to the end of the line, and a `#` that follows a
  blank starts a comment, so `KEY= # note` is empty while `KEY=a#b` is set.
  Leading and trailing blanks are not part of the value. `=` may appear
  inside any value.
- A value that starts with `'` or `"` ends at the first matching quote that
  is not escaped by a backslash. It may span several lines. After the closing
  quote, only blanks and an optional `#` comment may follow.

Anything else is a malformed line: a key that breaks the pattern, such as
`1KEY`, `KEY-NAME`, or `KEY.NAME`; a line without `=`, including a bare `KEY`,
`export KEY`, or `KEY: value`; text after a closing quote; a NUL byte; and an
opening quote that never closes, after which parsing resumes on the next line.
Backticks are ordinary characters, and no variable expansion or command
substitution is interpreted.

A key assigned on more than one line is a duplicate; the last assignment
decides whether its value is empty. A value is empty when nothing remains
after the rules above, such as `KEY=`, `KEY=""`, or `KEY=''`; any other value,
including one blank inside quotes, is set.

### Reported facts

The report names keys and line numbers only. A value's single exposed fact is
whether it is set or empty; values, value lengths, and digests never appear
in output, logs, or errors, and example values are treated the same way.
Malformed lines are identified by number alone.

- **Missing**: keys in the example but not in the dotenv file.
- **Extra**: keys in the dotenv file but not in the example.
- **Empty**: keys whose value in the dotenv file is empty.
- **Duplicates**: keys assigned more than once in either file, with their
  line numbers.
- **Malformed lines**: line numbers in either file.
- **Git**: whether the dotenv file is in a work tree, tracked, and matched by
  the ignore rules (`git check-ignore --no-index`). The probes run in the
  file's directory with `--no-optional-locks`, closed stdin, and a 10-second
  deadline; the tracking probe uses literal pathspecs, and repository
  variables such as `GIT_DIR` are cleared for them. A tracked file prints the
  exact `git rm --cached -- .env` hint (`git -C DIR rm --cached -- NAME` for a
  file in another directory); a file in a work tree that is neither tracked
  nor ignored is reported as one that could be committed. Without a usable
  `git`, including Apple's Command Line Tools placeholder and a Windows `git`
  on the WSL `PATH`, these facts are not checked. A timed-out or failed probe
  prints a warning and leaves its facts unknown.
- **Mode**: whether group or other users can read or write the file, with a
  `chmod -- 600 FILE` hint. On a WSL Windows drive without DrvFs metadata,
  which reports every file as mode `777`, the hint names that remedy.
- **Owner**: whether the current user owns the file.

Each missing, extra, empty, duplicate, and malformed item is one issue, as
are a tracked file, a work-tree file that is not ignored, an open mode, and a
foreign owner. A key list in the text report shows at most 50 names and
points to `--json` for the rest; a malformed-line list shows at most 20
numbers and counts the others.

### Output and exit status

The text report is UI on stderr: a heading, key-value facts, `Keys`,
`Syntax`, and `Hygiene` sections, and one verdict, either
`Dotenv check: no issues found.` or
`Dotenv check: N issues found — review the output above.` Its stdout is
empty.

`env-dotenv --json` never prompts and writes exactly one compact JSON object
on one line, followed by a newline, to stdout. jq builds it in compact mode
(`jq -c`): scalar facts arrive as `--arg` and `--argjson` values, and key
names and line numbers arrive as typed TAB-separated records on jq's standard
input, so the shell never assembles JSON text and no argument can exceed the
platform's size limit. Without `jq`, the command reports the missing
capability on stderr and returns `1`. Errors and Git probe warnings stay on
stderr.

```json
{"schema":"zdx.env-dotenv.v1","dotenv":{"path":"/home/me/project/.env","key_count":3,"empty":["SENTRY_DSN"],"duplicates":[{"key":"API_URL","lines":[2,9]}],"malformed_lines":[14],"mode":"0644","readable_by_others":true,"writable_by_others":false,"owned_by_user":true,"git":{"repository":true,"tracked":false,"ignored":true}},"example":{"path":"/home/me/project/.env.example","key_count":4,"duplicates":[],"malformed_lines":[]},"missing":["DATABASE_URL"],"extra":[],"in_sync":false,"issue_count":5}
```

The same document, formatted for reading:

```json
{
  "schema": "zdx.env-dotenv.v1",
  "dotenv": {
    "path": "/home/me/project/.env",
    "key_count": 3,
    "empty": ["SENTRY_DSN"],
    "duplicates": [{"key": "API_URL", "lines": [2, 9]}],
    "malformed_lines": [14],
    "mode": "0644",
    "readable_by_others": true,
    "writable_by_others": false,
    "owned_by_user": true,
    "git": {"repository": true, "tracked": false, "ignored": true}
  },
  "example": {
    "path": "/home/me/project/.env.example",
    "key_count": 4,
    "duplicates": [],
    "malformed_lines": []
  },
  "missing": ["DATABASE_URL"],
  "extra": [],
  "in_sync": false,
  "issue_count": 5
}
```

Paths are absolute. `example`, `missing`, `extra`, and `in_sync` are `null`
when no example exists. A Git fact is `null` when it was not checked, and
`tracked` and `ignored` are also `null` outside a work tree. `in_sync` is true
when no key is missing or extra. `issue_count` counts the issues defined
above, and the exit status follows it.

| Status | Meaning |
| --- | --- |
| `0` | No issue was found |
| `1` | At least one issue was found, or the check could not run: an absent, refused, or unreadable file, or `--json` without `jq` |
| `2` | Invalid arguments |

## Clipboard backends

The first available backend receives the value on standard input:

1. **macOS**: `pbcopy`. It decodes its input with the locale's encoding, so
   when `LC_ALL`, `LC_CTYPE`, or `LANG` does not name UTF-8, it runs with
   `LC_ALL=en_US.UTF-8`; otherwise UTF-8 text would become MacRoman.
2. **Wayland**: `wl-copy` when `WAYLAND_DISPLAY` is set.
3. **X11**: `xclip`, then `xsel`, when `DISPLAY` is set.
4. **WSL**: `clip.exe` on `PATH`, or under WSL the Windows system copy at
   `/mnt/c/Windows/System32/clip.exe`, which stays reachable when
   `appendWindowsPath=false` removes the Windows directories from `PATH`.
   `clip.exe` reads the console code page unless its input starts with a
   UTF-16LE byte-order mark, so the value is converted with `iconv` to
   UTF-16LE behind that mark. The whole value is validated first: invalid
   UTF-8 reaches no clipboard. Without `iconv`, only ASCII text is sent.

WSL is recognized from `WSL_DISTRO_NAME` or `WSL_INTEROP`, its interop
registration (`WSLInterop` or `WSLInterop-late`), or a Microsoft kernel
release. WSLg sessions that export `WAYLAND_DISPLAY` or `DISPLAY` use the
Linux backends, which WSLg synchronizes with Windows.

A hostile concurrent process with the same EUID can still race a userspace
pathname check of a picker capture file. File descriptors narrow that window,
but Linux `openat2`-style resolution is not available portably from this Zsh
implementation.

Focused coverage lives in `test/env.bats`, `test/env_contract.bats`,
`test/env_safety.bats`, `test/env_platform.bats`, and `test/env_dotenv.bats`.
Dotenv tests plant canary values in both files and assert that none reaches
stdout or stderr in text or JSON mode, cover each syntax rule and refusal, and
use disposable Git repositories for the tracking and ignore facts. Platform
tests record
the exact bytes each mocked backend receives: UTF-16LE with a byte-order mark
for `clip.exe`, the WSL fallback outside `PATH`, refusal of invalid UTF-8,
`pbcopy` under a UTF-8 locale, WSL detection from fixtures, and PATH entries
that differ by a trailing slash or by letter case. The macOS and WSL branches
run on Linux with `OSTYPE`, function, and program mocks; real clipboard
programs on macOS and Windows and cross-platform terminal behavior remain
manual acceptance boundaries.
