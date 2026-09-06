# README demo

The README uses a short GIF of the current checkout and a static PNG of the
Developer menu. Dev, Sys, and AI are the main focus, followed by brief Git and
File visits. The recording shows suite discovery, command filtering, readable
descriptions, and consistent suite navigation. Updates and other backend
operations remain disabled throughout the tour.

## Recording choice

Keep [VHS](https://github.com/charmbracelet/vhs) for this README. Its versioned
tape supports explicit screen waits, keyboard input, and a PNG screenshot from
the same real terminal session. A GIF works directly in a Markdown image; the
static poster and the written sequence below provide alternatives to motion.

| Tool | Useful properties | Decision for this demo |
| --- | --- | --- |
| [VHS](https://github.com/charmbracelet/vhs) | Scripted terminal interaction, screen waits, GIF and screenshot outputs | Keep the existing recorder and improve the tape, environment, typography, and checks |
| [asciinema](https://docs.asciinema.org/getting-started/) with [agg](https://github.com/asciinema/agg) | Small text recordings; its web player supports seeking and copying text; agg renders a GIF | A good option for a documentation site with a player; adds a recorder and converter without improving the README image itself |
| [svg-term-cli](https://github.com/marionebl/svg-term-cli) | Scalable animated SVG from an asciicast | Useful for vector output; rendering varies by host and it adds another conversion pipeline |

GitHub supports GIF and PNG images and lets readers control GIF autoplay through
[accessibility settings](https://docs.github.com/en/account-and-profile/how-tos/account-settings/managing-accessibility-settings).
Its [non-code file viewer](https://docs.github.com/en/repositories/working-with-files/using-files/working-with-non-code-files)
has separate SVG animation limitations. The choice of GIF does not imply that
all animated SVG placements behave identically on GitHub.

## Visible sequence

1. Open the ZDX directory, filter for `maintain projects`, and enter Dev.
2. Highlight **Inspect Python Project Health**, read its details, and capture
   the Developer poster. Filter for **Preview Dependency Updates**
   and read the description, then press Esc.
3. Open `zdx sys`, inspect **Run Health Check**, and filter for **Update System
   and Tools**. Read its maintenance description and `--safe-only` limitation,
   then press Esc.
4. Open `zdx ai`, inspect **Update All Assistants**, then **Diagnose MCP
   Servers**. Their descriptions explain installed-CLI updates and passive MCP
   inspection. Press Esc.
5. Open `zdx git`, inspect **Browse Diffs** and **Pull or Fetch**, then press
   Esc. The synthetic project is outside a repository, so repository-only
   entries retain their real unavailable annotation.
6. Finish with `zdx file`: filter for **Search Files**, read the description,
   and press Esc.

The tape targets a 45–60 second tour. Opening a suite displays its real rows,
capability annotations, and static command descriptions. The Sys update frame
shows the command description; generating an update plan is a backend action
and remains disabled. The same applies to AI update and MCP inspection
operations. The fixture guards all five action dispatchers and permits only
exact, argument-free routes to these suites. It does not synthesize successful
backend output.

## Reproduce

From the repository root:

```sh
just demo
```

The recorder requires installed `zsh`, `fzf`, `git`, `vhs`, `ttyd`, `ffmpeg`,
`ffprobe`, and a working Chrome or Chromium executable. It does not install tools or
request a browser download. On Linux it finds an installed browser on PATH or
an existing Rod/Playwright browser executable; an explicit existing executable
can be selected with `ZDX_DEMO_BROWSER=/absolute/path/to/chrome`. This selects the
binary only, not a personal browser profile. VHS uses its own browser discovery
on macOS, so a custom Linux browser override is not a macOS portability promise.

The tape is maintained against VHS 0.11.0 and uses its `Wait+Screen` and
`Screenshot` commands. The current Linux recording uses fzf 0.74.3, ttyd 1.7.4,
FFmpeg 6.1.1, and DejaVu Sans Mono at 16 px. The 1040 × 680 canvas is approximately
104 columns wide, with smaller text to show more of each menu. Already
installed `uv` and `jq` executables are exposed only
to passive menu availability checks; the demo does not install or run them. Catppuccin Mocha supplies the terminal palette; ZDX uses its
normal native terminal colors. It does not restore the old forced RGB menu
background.

`just demo-install` is a separate, privileged APT installation recipe for the
recording tools. Read it before use; it is not run by `just demo`. Other systems
can follow the [official VHS installation instructions](https://github.com/charmbracelet/vhs#installation).
A compatible existing browser and font remain prerequisites.

## Environment and publication

[record.zsh](../.demo/record.zsh) resolves the renderer tools before starting
VHS, creates a unique directory with mode 700 under `${TMPDIR:-/tmp}`, and starts
the renderer with `env -i`. The recorded process gets private HOME, ZDOTDIR,
TMPDIR, and XDG directories, an explicit PATH, a UTF-8 locale, and empty fzf
defaults. Inherited shell startup variables, Git environment overrides,
credentials, plugin paths, and theme overrides do not enter that process.

The synthetic project contains a README and a minimal `pyproject.toml`; it has
no Git repository. Git's global configuration is fixed to the committed
`.invalid` identity fixture, system configuration is disabled, and discovery
cannot ascend above the private recording root. A temporary parent whose
canonical path contains `:` is rejected because Git treats it as a path-list
separator. The session loads this checkout's `functions.zsh` and suite entrypoints directly, without depending on
an installed plugin or reading the operator's ZDX configuration.

[session.zsh](../.demo/session.zsh) requires the expected private paths and
records all five successful menu returns. The recorder requires that completion
marker and successful rendering. It validates the raw GIF as an owned regular
file with one hard link and the expected codec, then always converts it with
the installed FFmpeg to 10 frames per second, a 64-color palette, and no
dithering. `-fps_mode vfr` avoids adding duplicate frames at the input rate.
The tape captures at the same 10 fps. Font size, canvas, and reading pauses
remain unchanged by conversion.

Conversion runs in the same closed environment with `-nostdin -n`, writing a
new private file. The converted GIF and the original PNG must be owned regular
files with one hard link, the expected codecs, and a nonzero size. The GIF has
a 2 MiB ceiling; the PNG retains a 1 MiB ceiling. A size rejection reports the
observed bytes and the permitted range. The GIF's narrow repository size-check
exception accommodates the longer suite tour without reducing text size or
reading pauses; other files keep their normal size limit.

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
The workflow requests no remote service, upload, Git mutation, or backend
mutation. It does not disable Chromium's sandbox.

## Review before publishing

The checked-in artifacts reviewed on 2026-09-06 contain a 46.8-second GIF
(468 frames at 10 fps, 1,389,455 bytes) and a 238,763-byte Developer PNG.
Both use a 1040 × 680 canvas. The ZDX, Dev, Sys, AI, Git, and File scenes were
visually inspected after recording and conversion.

Run `vhs validate .demo/demo.tape`, then `just demo`. Inspect the poster and
sample GIF frames at the ZDX, Dev, Sys, AI, Git, and File states. Verify that labels are readable and the descriptions match the selected
commands. Check the artifact sizes and duration with `ffprobe`; do not infer a
successful sequence solely from a renderer exit code. The three isolated tests
in `test/demo_recording.bats` cover hostile inherited configuration, failed
render/conversion failure preservation, and refusal to clean a replaced
temporary directory.

This is a Linux recording of a synthetic workspace. It is not evidence of real
macOS rendering, a particular user's keyboard mapping, or the availability and
correctness of actual update or filesystem backends. The README poster and this
written sequence remain useful when animation is disabled.
