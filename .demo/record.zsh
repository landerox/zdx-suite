#!/usr/bin/env zsh
# =============================================================================
# ZDX Demo: isolated rendering and validated README media publication
# =============================================================================
#
# Run with zsh -f .demo/record.zsh, normally through just demo.
# Safe to source; defines private recording helpers only.
#

if [[ -n "${_ZDX_DEMO_RECORD_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_zdx_demo_dir_identity() {
  local directory="$1"
  local -A details
  REPLY=''
  [[ -d "$directory" && ! -L "$directory" && -O "$directory" ]] || return 1
  zmodload -F zsh/stat b:zstat || return 1
  zstat -H details -- "$directory" || return 1
  (( (details[mode] & 8#777) == 8#700 )) || return 1
  REPLY="${details[device]}:${details[inode]}:${details[uid]}:${details[mode]}"
}

# Builds the synthetic workspace: a uv project with a locked, offline-created
# environment and unfinished work, tracked by a private bare origin.
_zdx_demo_workspace() {
  emulate -L zsh
  local runtime="$1" source_root="$2"
  local project="$runtime/home/workspace/zdx-demo"
  local origin="$runtime/home/remotes/zdx-demo.git"
  local -a tool_environment=(
    command env -i "HOME=$runtime/home" "PATH=$runtime/bin:/usr/bin:/bin"
    "GIT_CONFIG_GLOBAL=$source_root/.demo/git-demo.conf" 'GIT_CONFIG_NOSYSTEM=1'
    "GIT_CEILING_DIRECTORIES=$runtime" 'LC_ALL=C.UTF-8'
    "XDG_CACHE_HOME=$runtime/cache" 'UV_NO_CONFIG=1' 'UV_PYTHON_DOWNLOADS=never'
    'GIT_AUTHOR_DATE=2026-10-01T09:00:00Z' 'GIT_COMMITTER_DATE=2026-10-01T09:00:00Z'
  )
  local -a git_command=("${tool_environment[@]}" "$runtime/bin/git")
  local -a uv_command=("${tool_environment[@]}" "$runtime/bin/uv")
  command mkdir -p -- "$project/src" "$project/docs" || return 1
  print -rl -- '# zdx-demo' '' 'A small project for the README tour.' \
    > "$project/README.md" || return 1
  print -rl -- 'def greet(name: str) -> str:' '    return f"Hello, {name}!"' \
    > "$project/src/app.py" || return 1
  print -rl -- '[project]' 'name = "zdx-demo"' 'version = "0.1.0"' \
    'requires-python = ">=3.11"' 'dependencies = []' '' '[tool.uv]' \
    'package = false' > "$project/pyproject.toml" || return 1
  print -rl -- '.venv/' > "$project/.gitignore" || return 1
  # No dependencies, so the lock and the environment need no network.
  "${uv_command[@]}" --directory "$project" --quiet lock --offline || return 1
  "${uv_command[@]}" --directory "$project" --quiet sync --offline || return 1
  "${git_command[@]}" init -q --bare -- "$origin" || return 1
  "${git_command[@]}" -C "$project" init -q || return 1
  "${git_command[@]}" -C "$project" add -A || return 1
  "${git_command[@]}" -C "$project" commit -q -m 'feat: start the demo project' \
    || return 1
  "${git_command[@]}" -C "$project" remote add origin "$origin" || return 1
  "${git_command[@]}" -C "$project" push -q -u origin main 2>/dev/null || return 1
  # Unfinished work for the stash scene: two edits and one new file.
  print -rl -- 'def greet(name: str) -> str:' \
    '    return f"Hello, {name}! Welcome to ZDX."' > "$project/src/app.py" || return 1
  print -rl -- '' '## Usage' '' 'Run `python -m src.app`.' \
    >> "$project/README.md" || return 1
  print -rl -- '# Notes' '' '- Try the stash manager.' > "$project/docs/notes.md" \
    || return 1
}

_zdx_demo_record() {
  emulate -L zsh
  setopt localtraps
  umask 077
  local source_root="$1" tool resolved browser="${ZDX_DEMO_BROWSER:-}"
  local runtime='' identity='' result=0 media codec destination normalized
  local temporary_parent="${TMPDIR:-/tmp}"
  temporary_parent="${temporary_parent:A}"
  [[ "$temporary_parent" != *:* ]] || {
    print -u2 -r -- 'demo: TMPDIR cannot contain a colon because Git ceiling paths use it as a separator.'
    return 1
  }
  local -A programs details
  local -i media_limit=0
  local -a candidates clean_environment publication_files=()

  for tool in zsh vhs ttyd ffmpeg ffprobe fzf git uv; do
    resolved=$(builtin whence -p -- "$tool") || {
      print -u2 -r -- "demo: required executable not found: $tool"
      return 1
    }
    programs[$tool]="${resolved:A}"
  done
  # The demo project needs Python 3.11 or newer; macOS's /usr/bin/python3 is
  # older, so expose the first suitable interpreter as python3.
  for tool in python3.14 python3.13 python3.12 python3.11 python3; do
    resolved=$(builtin whence -p -- "$tool") || continue
    command "$resolved" -I -S -c \
      'import sys; raise SystemExit(sys.version_info < (3, 11))' 2>/dev/null \
      || continue
    programs[python3]="${resolved:A}"
    break
  done
  (( ${+programs[python3]} )) || {
    print -u2 -r -- 'demo: Python 3.11 or newer is required for the demo project.'
    return 1
  }
  # Expose installed optional tools to passive menu availability checks only.
  for tool in jq; do
    resolved=$(builtin whence -p -- "$tool") && programs[$tool]="${resolved:A}"
  done
  if [[ -z "$browser" ]]; then
    for tool in chrome google-chrome chromium chromium-browser; do
      resolved=$(builtin whence -p -- "$tool") || continue
      browser="$resolved"
      break
    done
    if [[ -z "$browser" ]]; then
      candidates=(
        '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
        '/Applications/Chromium.app/Contents/MacOS/Chromium'
        "$HOME"/.cache/rod/browser/chromium-*/chrome(N)
        "$HOME"/.cache/ms-playwright/chromium-*/chrome-linux64/chrome(N)
      )
      for resolved in "${candidates[@]}"; do
        [[ -f "$resolved" && -x "$resolved" ]] || continue
        browser="$resolved"
        break
      done
    fi
  fi
  [[ "$browser" == /* && -f "$browser" && -x "$browser" ]] || {
    print -u2 -r -- 'demo: install Chromium/Chrome or set ZDX_DEMO_BROWSER to its absolute executable.'
    return 1
  }
  browser="${browser:A}"
  runtime=$(command mktemp -d "$temporary_parent/zdx-demo.XXXXXXXX") || return 1
  runtime="${runtime:A}"
  _zdx_demo_dir_identity "$runtime" || return 1
  identity="$REPLY"
  print -r -- zdx-demo > "$runtime/.owner" || return 1
  trap 'return 130' INT
  trap 'return 143' TERM HUP

  {
    command mkdir -p -- "$runtime"/{bin,home,zdotdir,tmp,config,data,cache,state,run,output/.demo} \
      "$runtime/home/workspace/zdx-demo" "$runtime/home/remotes" || return 1
    for tool in ${(k)programs}; do
      command ln -s -- "${programs[$tool]}" "$runtime/bin/$tool" || return 1
    done
    command ln -s -- "$browser" "$runtime/bin/chrome" || return 1
    _zdx_demo_workspace "$runtime" "$source_root" || {
      print -u2 -r -- 'demo: could not prepare the private demo workspace.'
      return 1
    }
    clean_environment=(
      "PATH=$runtime/bin:/usr/bin:/bin" "HOME=$runtime/home"
      "ZDOTDIR=$runtime/zdotdir" "TMPDIR=$runtime/tmp"
      "XDG_CONFIG_HOME=$runtime/config" "XDG_DATA_HOME=$runtime/data"
      "XDG_CACHE_HOME=$runtime/cache" "XDG_STATE_HOME=$runtime/state"
      "XDG_RUNTIME_DIR=$runtime/run" "SHELL=${programs[zsh]}"
      'TERM=xterm-256color' 'LANG=C.UTF-8' 'LC_ALL=C.UTF-8'
      "ZDX_DEMO_ROOT=$runtime" "ZDX_DEMO_SOURCE_ROOT=$source_root"
      "GIT_CONFIG_GLOBAL=$source_root/.demo/git-demo.conf" 'GIT_CONFIG_NOSYSTEM=1'
      'FZF_DEFAULT_OPTS=' 'FZF_DEFAULT_OPTS_FILE=' 'FZF_DEFAULT_COMMAND='
      'ZDX_TELEMETRY=0' "GIT_CEILING_DIRECTORIES=$runtime"
    )
    (
      builtin cd -- "$runtime/output" || exit 1
      command env -i "${clean_environment[@]}" "${programs[vhs]}" "$source_root/.demo/demo.tape" >&2
    )
    result=$?
    (( result == 0 )) || return "$result"
    [[ -f "$runtime/session.complete" && ! -L "$runtime/session.complete" \
      && "$(<"$runtime/session.complete")" == 0 ]] || {
      print -u2 -r -- 'demo: the recorded menu sequence did not complete.'
      return 1
    }
    # Normalize the recorded GIF before enforcing the README artifact limit.
    resolved="$runtime/output/.demo/demo.gif"
    [[ -f "$resolved" && ! -L "$resolved" && -O "$resolved" ]] || return 1
    zstat -H details -- "$resolved" || return 1
    (( details[nlink] == 1 && details[size] > 0 )) || return 1
    codec=$(command env -i "${clean_environment[@]}" "${programs[ffprobe]}" \
      -v error -show_entries stream=codec_name -of default=nw=1:nk=1 "$resolved") || return 1
    [[ "$codec" == gif ]] || return 1
    normalized="$runtime/output/.demo/normalized.gif"
    [[ ! -e "$normalized" && ! -L "$normalized" ]] || return 1
    command env -i "${clean_environment[@]}" "${programs[ffmpeg]}" \
      -v error -nostdin -n -i "$resolved" \
      -filter_complex 'fps=10,split[pixels][palette];[palette]palettegen=max_colors=64[colors];[pixels][colors]paletteuse=dither=none[demo]' \
      -map '[demo]' -an -fps_mode vfr -loop 0 "$normalized"
    result=$?
    (( result == 0 )) || {
      print -u2 -r -- 'demo: GIF conversion failed; previous media preserved.'
      return "$result"
    }
    for media in gif png; do
      resolved="$runtime/output/.demo/demo.$media"
      [[ "$media" == gif ]] && resolved="$normalized"
      [[ -f "$resolved" && ! -L "$resolved" && -O "$resolved" ]] || return 1
      zstat -H details -- "$resolved" || return 1
      (( details[nlink] == 1 )) || return 1
      media_limit=1048576
      [[ "$media" == gif ]] && media_limit=2097152
      (( details[size] > 0 && details[size] <= media_limit )) || {
        print -u2 -r -- \
          "demo: $media is ${details[size]} bytes; expected 1..${media_limit} bytes."
        return 1
      }
      codec=$(command env -i "${clean_environment[@]}" "${programs[ffprobe]}" \
        -v error -show_entries stream=codec_name -of default=nw=1:nk=1 "$resolved") || return 1
      [[ "$codec" == "$media" ]] || return 1
    done
    # Refuse special destinations; mv must never adopt a directory or symlink.
    for media in gif png; do
      destination="$source_root/.demo/demo.$media"
      [[ ! -e "$destination" && ! -L "$destination" ]] && continue
      [[ -f "$destination" && ! -L "$destination" && -O "$destination" ]] || return 1
      zstat -H details -- "$destination" || return 1
      (( details[nlink] == 1 )) || return 1
    done
    # Validate both outputs before replacing either committed artifact.
    for media in gif png; do
      destination=$(command mktemp "$source_root/.demo/.publish-$media.XXXXXXXX") || return 1
      publication_files+=("$destination")
      resolved="$runtime/output/.demo/demo.$media"
      [[ "$media" == gif ]] && resolved="$normalized"
      command cp -- "$resolved" "$destination" || return 1
      command chmod -- 644 "$destination" || return 1
    done
    local -i index=0
    for media in gif png; do
      (( ++index ))
      destination="$source_root/.demo/demo.$media"
      if [[ -e "$destination" || -L "$destination" ]]; then
        [[ -f "$destination" && ! -L "$destination" && -O "$destination" ]] || return 1
        zstat -H details -- "$destination" || return 1
        (( details[nlink] == 1 )) || return 1
      fi
      command mv -f -- "${publication_files[$index]}" "$destination" || return 1
    done
    print -u2 -r -- 'demo: published .demo/demo.gif and .demo/demo.png'
  } always {
    result=$?
    for destination in "${publication_files[@]}"; do
      [[ ! -f "$destination" || -L "$destination" ]] || command rm -f -- "$destination"
    done
    # VHS may return just before Chromium finishes flushing its private profile.
    command sleep 1
    if _zdx_demo_dir_identity "$runtime" && [[ "$REPLY" == "$identity" \
      && -f "$runtime/.owner" && ! -L "$runtime/.owner" \
      && "$(<"$runtime/.owner")" == zdx-demo ]]; then
      command rm -rf -- "$runtime" || result=1
    else
      print -u2 -r -- "demo: temporary directory identity changed; retained $runtime"
      result=1
    fi
  }
  return "$result"
}

typeset -g _ZDX_DEMO_RECORD_SOURCED=1
if [[ "${ZSH_EVAL_CONTEXT:-}" == toplevel ]]; then
  (( $# == 0 )) || { print -u2 -r -- 'Usage: zsh -f .demo/record.zsh'; exit 2; }
  _zdx_demo_record "${0:A:h:h}"
  exit $?
fi
