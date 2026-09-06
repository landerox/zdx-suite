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
  zmodload zsh/stat || return 1
  zstat -H details -- "$directory" || return 1
  (( (details[mode] & 8#777) == 8#700 )) || return 1
  REPLY="${details[device]}:${details[inode]}:${details[uid]}:${details[mode]}"
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

  for tool in zsh vhs ttyd ffmpeg ffprobe fzf git; do
    resolved=$(builtin whence -p -- "$tool") || {
      print -u2 -r -- "demo: required executable not found: $tool"
      return 1
    }
    programs[$tool]="${resolved:A}"
  done
  # Expose installed optional tools to passive menu availability checks only.
  for tool in uv jq; do
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
      "$runtime/home/workspace/zdx-demo" || return 1
    for tool in ${(k)programs}; do
      command ln -s -- "${programs[$tool]}" "$runtime/bin/$tool" || return 1
    done
    command ln -s -- "$browser" "$runtime/bin/chrome" || return 1
    print -r -- '# Demo workspace' '' 'Browse real menus without running their actions.' \
      > "$runtime/home/workspace/zdx-demo/README.md"
    print -r -- '[project]' 'name = "zdx-demo"' 'version = "0.1.0"' \
      'requires-python = ">=3.11"' 'dependencies = []' \
      > "$runtime/home/workspace/zdx-demo/pyproject.toml"
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
      command chmod 644 -- "$destination" || return 1
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
if [[ "${(%):-%N}" == "$0" ]]; then
  (( $# == 0 )) || { print -u2 -r -- 'Usage: zsh -f .demo/record.zsh'; exit 2; }
  _zdx_demo_record "${0:A:h:h}"
  exit $?
fi
