# README demo

The README shows a GIF recorded from this checkout and a static PNG of the Git
menu. The tour opens the `zdx` launcher, saves unfinished work as a stash from
the Git menu, shows the host summary from the System menu, and checks the
project's health from the Developer menu. These three actions really run, but
only inside a private recording workspace, and every other backend action stays
disabled.

## Recording choice

The README uses [VHS](https://github.com/charmbracelet/vhs). Its versioned
tape supports explicit screen waits, keyboard input, and a PNG screenshot from
the same real terminal session. A GIF works directly in a Markdown image; the
static poster and the written sequence below provide alternatives to motion.

| Tool | Useful properties | Decision for this demo |
| --- | --- | --- |
| [VHS](https://github.com/charmbracelet/vhs) | Scripted terminal interaction, screen waits, GIF and screenshot outputs | Selected: one tape renders both README images from the same real session |
| [asciinema](https://docs.asciinema.org/getting-started/) with [agg](https://github.com/asciinema/agg) | Small text recordings; its web player supports seeking and copying text; agg renders a GIF | A good option for a documentation site with a player; adds a recorder and converter without improving the README image itself |
| [svg-term-cli](https://github.com/marionebl/svg-term-cli) | Scalable animated SVG from an asciicast | Useful for vector output; rendering varies by host and it adds another conversion pipeline |

GitHub supports GIF and PNG images and lets readers control GIF autoplay through
[accessibility settings](https://docs.github.com/en/account-and-profile/how-tos/account-settings/managing-accessibility-settings).
Its [non-code file viewer](https://docs.github.com/en/repositories/working-with-files/using-files/working-with-non-code-files)
has separate SVG animation limitations. The choice of GIF does not imply that
all animated SVG placements behave identically on GitHub.

## Visible sequence

1. In `~/workspace/zdx-demo`, run `zdx`. The launcher lists every suite by
   domain, starting with Workspaces under Projects; filter for `git` and open
   the Git menu.
2. The Git menu's header names the repository, branch, three changes, and the
   `origin` remote, and its sections include Local Changes and Branches. The
   poster PNG is captured here.
3. Filter for `stash` and open **Manage Stashes**. Its first row, **Save
   current changes (3 files)**, previews `git status`. Choose it, type the
   message `WIP: friendlier greeting`, include the one untracked file, review
   the plan table of three files, and confirm. The stash manager reports
   `✔ Stash saved: 3 files stored as stash@{0}`.
4. Run `zdx sys`. The System menu's header names the platform, package
   manager, and service manager; filter for `system info` and open **Show
   System Info**, a read-only summary of the operating system, memory, CPU,
   disks, and installed tools of the recording host.
5. Run `zdx dev`. The Developer menu's header names the project, its Python
   stack, and its environment; filter for `health` and open **Inspect Python
   Project Health**, which checks `pyproject.toml`, the `.venv`, `uv.lock`, and
   the toolchain and ends with `✔ Project health: all checks passed.`

The tour follows the readable pace of a person: it types commands and filters,
pauses on each menu and result, and ends on the health check.

## Reproduce

From the repository root:

```sh
just demo
```

The recorder requires installed `zsh`, `fzf`, `git`, `uv`, `vhs`, `ttyd`,
`ffmpeg`, `ffprobe`, Python 3.11 or newer, and a working Chrome or Chromium
executable. It does not install tools or
request a browser download. On Linux it finds an installed browser on PATH or
an existing Rod/Playwright browser executable; an explicit existing executable
can be selected with `ZDX_DEMO_BROWSER=/absolute/path/to/chrome`. This selects the
binary only, not a personal browser profile. VHS uses its own browser discovery
on macOS, so a custom Linux browser override is not a macOS portability promise.

The tape is maintained against VHS 0.12.1 and uses its `Wait+Screen`,
`Wait+Line`, and `Screenshot` commands. `Wait+Screen` reads the first rows of
the terminal buffer rather than the scrolled view, so after output longer than
the screen the tape waits for the prompt with `Wait+Line`, and each hidden
check clears the screen before printing its marker. The current recording uses fzf 0.74.4,
ttyd 1.7.4, FFmpeg 6.1.1, and DejaVu Sans Mono at 18 px on a 1180 × 700 canvas,
about 100 columns, framed by a window bar and a rounded border. Catppuccin
Mocha supplies the terminal palette; ZDX uses its normal native terminal
colors. An already installed `jq` is exposed only to passive menu availability
checks.

`just demo-install` installs the recording tools with Homebrew on macOS, or
with the charm.sh APT repository on Debian and Ubuntu, which needs sudo. Read
it before use; it is not run by `just demo`. Other systems can follow the
[official VHS installation instructions](https://github.com/charmbracelet/vhs#installation).
A compatible existing browser and font remain prerequisites.

## Environment and publication

[record.zsh](../.demo/record.zsh) resolves the renderer tools before starting
VHS, creates a unique directory with mode 700 under `${TMPDIR:-/tmp}`, and starts
the renderer with `env -i`. The recorded process gets private HOME, ZDOTDIR,
TMPDIR, and XDG directories, an explicit PATH, a UTF-8 locale, and empty fzf
defaults. Inherited shell startup variables, Git environment overrides,
credentials, plugin paths, and theme overrides do not enter that process.

The recorder builds the workspace before VHS starts. The project
`~/workspace/zdx-demo` is a uv project without dependencies whose `uv.lock` and
`.venv` uv creates offline from the first Python 3.11 or newer interpreter it
finds, which the recorder links into the private PATH as `python3`. It has one
commit pushed to a private bare `origin` under the recording root, two edited
files, and one new file. Git's global configuration is fixed to the committed `.invalid`
identity fixture, system configuration is disabled, and discovery cannot ascend
above the private recording root. A temporary parent whose
canonical path contains `:` is rejected because Git treats it as a path-list
separator. The session loads this checkout's `functions.zsh` and suite entrypoints directly, without depending on
an installed plugin or reading the operator's ZDX configuration.

[session.zsh](../.demo/session.zsh) requires the expected private paths and
loads only the Git, System, Developer, and ZDX entrypoints. Its guards let
`zdx` route only to `git`, `sys`, and `dev`, and let exactly three actions run,
each without arguments and only in the project folder: `git-stash`,
`sys-info`, and `dev-check-health`. Any other route, action, argument, or
folder records a denial and stops the session from completing. The completion
marker requires three successful menu returns, no denial, and the saved stash
with its message. The recorder requires that
completion marker and successful rendering. It validates the raw GIF as an owned regular
file with one hard link and the expected codec, then always converts it with
the installed FFmpeg to 10 frames per second, a 64-color palette, and no
dithering. `-fps_mode vfr` avoids adding duplicate frames at the input rate.
The tape captures at the same 10 fps. Font size, canvas, and reading pauses
remain unchanged by conversion.

Conversion runs in the same closed environment with `-nostdin -n`, writing a
new private file. The converted GIF and the original PNG must be owned regular
files with one hard link, the expected codecs, and a nonzero size. The GIF has
a 2 MiB ceiling; the PNG has a 1 MiB ceiling. A size rejection reports the
observed bytes and the permitted range. The GIF's narrow repository size-check
exception keeps README media bounded; the current tour uses under half of it.

Both outputs are validated before publication, so rendering, conversion, and
validation failures preserve the previous README media. Same-directory temporary files are renamed individually into
`.demo/demo.gif` and `.demo/demo.png`; this is not an atomic transaction across
the pair if publication itself fails midway.

Cleanup checks the temporary root's device, inode, owner, mode, and owner marker
before removing it. A replaced root is retained with a diagnostic. These checks
reduce accidental deletion; they are not a defense against every concurrent
filesystem change by the same user. The outer invocation of `just` remains part
of the operator's environment. The renderer's isolation is not an OS sandbox or
a network firewall, and trusted installed tools can have their own behavior.
The workflow uploads nothing. The health check's PyPI reachability probe is its
only network request, and its only mutation outside the recording root's setup
is the stash inside the private workspace, which cleanup removes. It does not disable Chromium's sandbox.

## Review before publishing

The checked-in artifacts contain a 47.8-second GIF (478 frames at 10 fps,
887,056 bytes) and a 152,289-byte Git menu PNG, both on a 1180 × 700 canvas.
Each scene was inspected after recording and conversion:
the launcher, the Git menu, the stash picker and its plan, the saved stash, the
System menu and its host summary, and the Developer menu and its health check.
The System scene shows the recording host's real operating system, CPU,
memory, disk usage, and tool versions; record on a host whose summary may be
published.

Run `vhs validate .demo/demo.tape`, then `just demo`. Inspect the poster and
sample GIF frames at each of those states. Verify that labels are readable and
that menu rows show no trailing `|`. Check the artifact sizes and duration with
`ffprobe`; do not infer a successful sequence solely from a renderer exit code.
The isolated tests in `test/demo_recording.bats` cover hostile inherited
configuration, the workspace the recorder prepares, the routing and action
guards, completion only after the three actions and the stash, failed and oversized
media that preserve previous files, and refusal to clean a replaced temporary
directory.

This is a Linux recording, made under WSL 2, of a synthetic workspace. It is not evidence of real
macOS rendering, a particular user's keyboard mapping, or the behavior of
backends the tour does not run. The README poster and this written sequence
remain useful when animation is disabled.
