#!/usr/bin/env zsh
# =============================================================================
# ZDX Widgets: ZLE pickers that insert a branch, pull request, port, or venv
# =============================================================================
#
# Loaded on first use by the insert widgets that zdx-suite.plugin.zsh
# registers, or eagerly by functions.zsh; requires its _tk_fzf picker and
# _zdx_run_with_timeout services at invocation.
# Safe to re-source; defines functions only.
#
# A widget only edits the command line: it appends the chosen value, quoted
# with ${(q)...}, to LBUFFER and never runs it. The picker shows labels from
# this invocation's own snapshot, and the selection is resolved by its row
# index in that snapshot, never parsed back out of display text.
#

if [[ -n "${_ZDX_WIDGETS_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# One line below the prompt; the text is data, shown with controls escaped.
_zdx_widget_message() {
  zle -M "zdx: ${(V)1-}"
}

# True when git can run without side effects. On macOS, /usr/bin/git is a
# Command Line Tools placeholder that opens an installation dialog while
# xcode-select reports no developer directory, so it counts as missing.
_zdx_widget_git_usable() {
  emulate -L zsh
  local git_path="${commands[git]-}" developer_dir=""
  [[ -n "$git_path" ]] || return 1
  [[ "${OSTYPE:-}" == darwin* && "$git_path" == /usr/bin/git ]] || return 0
  (( ${+commands[xcode-select]} )) || return 1
  developer_dir=$(_zdx_run_with_timeout 3 xcode-select -p \
    </dev/null 2>/dev/null) || return 1
  developer_dir="${developer_dir%%$'\n'*}"
  [[ -n "$developer_dir" && -d "$developer_dir" ]]
}

# Adds one candidate to the caller's arrays. The value is what Enter inserts,
# the alternate is what the picker's alternate key inserts, and the label is
# display text only. At most 2000 candidates keep a huge inventory from
# stalling the editor; status 1 means the picker is full.
_zdx_widget_add() {
  (( ${#widget_values} < 2000 )) || return 1
  widget_values+=("${1-}")
  widget_alternates+=("${2-}")
  widget_labels+=("${(V)3-}")
}

# Local branches, then remote-tracking branches, each most recent first. The
# symbolic origin/HEAD is skipped; the short name is what Git accepts back.
_zdx_widget_branch_candidates() {
  emulate -L zsh
  REPLY=""
  _zdx_widget_git_usable || {
    REPLY="git is not installed"
    return 1
  }
  local output="" line="" mark=""
  local -i probe_rc=0
  local -a fields=() remote_values=() remote_labels=()
  output=$(_zdx_run_with_timeout 5 git for-each-ref \
    --sort=-committerdate \
    '--format=%(HEAD)%09%(refname)%09%(refname:short)%09%(symref)' \
    refs/heads refs/remotes </dev/null 2>/dev/null) || probe_rc=$?
  case $probe_rc in
    0) ;;
    124) REPLY="git timed out while listing branches"; return 1 ;;
    *) REPLY="not inside a Git repository"; return 1 ;;
  esac
  for line in "${(@f)output}"; do
    fields=("${(@ps:\t:)line}")
    (( ${#fields} == 4 )) && [[ -n "${fields[3]}" && -z "${fields[4]}" ]] \
      || continue
    case "${fields[2]}" in
      refs/heads/*)
        mark=" "
        [[ "${fields[1]}" == '*' ]] && mark="*"
        _zdx_widget_add "${fields[3]}" "" "local  $mark ${fields[3]}" || break
        ;;
      refs/remotes/*)
        remote_values+=("${fields[3]}")
        remote_labels+=("remote   ${fields[3]}")
        ;;
    esac
  done
  local -i index=0
  for (( index = 1; index <= ${#remote_values}; index++ )); do
    _zdx_widget_add "${remote_values[index]}" "" "${remote_labels[index]}" \
      || break
  done
  (( ${#widget_values} > 0 )) || {
    REPLY="no local or remote-tracking branches"
    return 1
  }
}

# Open pull requests of the current repository through gh. gh status 4 means
# that authentication is required.
_zdx_widget_pr_candidates() {
  emulate -L zsh
  REPLY=""
  (( ${+commands[gh]} )) || {
    REPLY="gh is not installed; install GitHub CLI to list pull requests"
    return 1
  }
  (( ${+commands[jq]} )) || {
    REPLY="jq is required to read pull requests; run zdx doctor"
    return 1
  }
  zle -R "zdx: loading open pull requests..."
  local output="" rows="" line=""
  local -i probe_rc=0
  local -a fields=()
  output=$(_zdx_run_with_timeout 15 env GH_PROMPT_DISABLED=1 \
    GH_NO_UPDATE_NOTIFIER=1 gh pr list --state open --limit 200 \
    --json number,title,headRefName </dev/null 2>/dev/null) || probe_rc=$?
  case $probe_rc in
    0) ;;
    4) REPLY="gh is not authenticated; run gh auth login"; return 1 ;;
    124) REPLY="gh timed out after 15s"; return 1 ;;
    *)
      REPLY="gh pr list failed (status $probe_rc); check the GitHub remote"
      return 1
      ;;
  esac
  # @tsv escapes tabs and newlines inside titles, so each record is a line.
  rows=$(print -r -- "$output" | _zdx_run_with_timeout 5 jq -r \
    '.[] | [(.number | tostring), (.headRefName // ""), (.title // "")] | @tsv' \
    2>/dev/null) || {
    REPLY="gh returned unreadable pull request data"
    return 1
  }
  for line in "${(@f)rows}"; do
    fields=("${(@ps:\t:)line}")
    (( ${#fields} == 3 )) && [[ "${fields[1]}" =~ '^[1-9][0-9]{0,9}$' ]] \
      || continue
    _zdx_widget_add "${fields[1]}" "" \
      "#${fields[1]}  ${fields[2][1,60]}  ${fields[3][1,120]}" || break
  done
  (( ${#widget_values} > 0 )) || {
    REPLY="no open pull requests"
    return 1
  }
}

# Records one listener once per port and PID, keeping ports in numeric order.
_zdx_widget_port_record() {
  local port="${1-}" pid="${2-}" name="${3-}" address="${4-}"
  [[ "$port" == <1-65535> ]] || return 0
  [[ -z "$pid" || "$pid" == <1-> ]] || pid=""
  local key="$port:$pid"
  (( ${+seen_listeners[$key]} )) && return 0
  seen_listeners[$key]=1
  listener_records+=("${(l:5::0:)port}"$'\t'"$pid"$'\t'"$name"$'\t'"$address")
}

# Listening TCP sockets and their owning processes: ss on Linux (lsof when ss
# is absent) and lsof on macOS. Without privileges another user's process is
# not visible, so its row offers only the port.
_zdx_widget_port_candidates() {
  emulate -L zsh
  REPLY=""
  local backend="" output="" line="" address="" pid="" name="" record=""
  local -i probe_rc=0
  local -a fields=() listener_records=()
  local -A seen_listeners=()
  case "${OSTYPE:-}" in
    linux*)
      if (( ${+commands[ss]} )); then
        backend=ss
      elif (( ${+commands[lsof]} )); then
        backend=lsof
      fi
      ;;
    darwin*)
      (( ${+commands[lsof]} )) && backend=lsof
      ;;
  esac
  [[ -n "$backend" ]] || {
    REPLY="ss or lsof is required to list listening ports"
    [[ "${OSTYPE:-}" == darwin* ]] \
      && REPLY="lsof is required to list listening ports"
    return 1
  }

  if [[ "$backend" == ss ]]; then
    output=$(_zdx_run_with_timeout 5 ss -l -t -n -p \
      </dev/null 2>/dev/null) || probe_rc=$?
    (( probe_rc == 124 )) && { REPLY="ss timed out after 5s"; return 1; }
    (( probe_rc == 0 )) || { REPLY="ss failed (status $probe_rc)"; return 1; }
    for line in "${(@f)output}"; do
      fields=(${=line})
      [[ "${fields[1]-}" == LISTEN ]] || continue
      address="${fields[4]-}"
      pid=""
      name=""
      [[ "$line" =~ 'pid=([0-9]+)' ]] && pid="${match[1]}"
      [[ "$line" =~ 'users:\(\("([^"]*)"' ]] && name="${match[1]}"
      _zdx_widget_port_record "${address##*:}" "$pid" "$name" "$address"
    done
  else
    output=$(_zdx_run_with_timeout 10 lsof -nP -iTCP -sTCP:LISTEN -Fpcn \
      </dev/null 2>/dev/null) || probe_rc=$?
    (( probe_rc == 124 )) && { REPLY="lsof timed out after 10s"; return 1; }
    # lsof also returns 1 when nothing matches.
    (( probe_rc == 0 || probe_rc == 1 )) || {
      REPLY="lsof failed (status $probe_rc)"
      return 1
    }
    for line in "${(@f)output}"; do
      case "$line" in
        p*) pid="${line#p}"; name="" ;;
        c*) name="${line#c}" ;;
        n*)
          address="${line#n}"
          _zdx_widget_port_record "${address##*:}" "$pid" "$name" "$address"
          ;;
      esac
    done
  fi

  # Records start with a validated, zero-padded port, so a text sort is
  # numeric and the arithmetic below sees only digits.
  local -i port_number=0
  for record in "${(@o)listener_records}"; do
    fields=("${(@ps:\t:)record}")
    port_number="${fields[1]}"
    if [[ -n "${fields[2]}" ]]; then
      _zdx_widget_add "${fields[2]}" "$port_number" \
        ":$port_number  ${fields[3][1,32]:-?}  pid ${fields[2]}  ${fields[4]}" \
        || break
    else
      _zdx_widget_add "" "$port_number" \
        ":$port_number  (process not visible)  ${fields[4]}" || break
    fi
  done
  (( ${#widget_values} > 0 )) || {
    REPLY="no listening TCP ports are visible"
    return 1
  }
}

# Virtual environments named .venv or venv in the current directory and its
# ancestors, then the environments below WORKON_HOME when it is set.
_zdx_widget_venv_candidates() {
  emulate -L zsh
  REPLY=""
  local directory="${PWD:-/}" candidate="" name=""
  local active_venv="${VIRTUAL_ENV:+${VIRTUAL_ENV:A}}"
  local -i depth=0 count=0
  local -A seen=()
  while (( depth++ < 64 )); do
    for name in .venv venv; do
      candidate="${directory%/}/$name"
      [[ -d "$candidate" && -f "$candidate/pyvenv.cfg" \
        && -z "${seen[$candidate]-}" ]] || continue
      seen[$candidate]=1
      _zdx_widget_venv_add project "$candidate" || break 2
    done
    [[ "$directory" == / ]] && break
    directory="${directory:h}"
  done
  if [[ -n "${WORKON_HOME:-}" && "$WORKON_HOME" == /* \
    && -d "$WORKON_HOME" ]]; then
    for candidate in "${WORKON_HOME%/}"/*(N-/); do
      (( count++ < 500 )) || break
      [[ -z "${seen[$candidate]-}" ]] || continue
      [[ -f "$candidate/pyvenv.cfg" || -f "$candidate/bin/activate" ]] \
        || continue
      seen[$candidate]=1
      _zdx_widget_venv_add workon "$candidate" || break
    done
  fi
  (( ${#widget_values} > 0 )) || {
    REPLY="no virtual environment here, in a parent directory, or in WORKON_HOME"
    return 1
  }
}

# Private: adds one environment with HOME shown as ~ and the caller's
# active_venv marked.
_zdx_widget_venv_add() {
  local origin="${1-}" candidate="${2-}" display="" note=""
  display="$candidate"
  [[ -n "${HOME:-}" && "$HOME" != / && "$candidate" == "$HOME"/* ]] \
    && display="~/${candidate#"$HOME"/}"
  [[ -n "$active_venv" && "${candidate:A}" == "$active_venv" ]] \
    && note="  (active)"
  _zdx_widget_add "$candidate" "" "${(r:7:)origin} $display$note"
}

# REPLY: the selected row index; reply[1]: the --expect key, empty for Enter.
# Status 0 selected, 1 cancelled or no match, 2 failure with REPLY a message.
_zdx_widget_pick() {
  local prompt="${1-}" header="${2-}" expect_key="${3-}"
  local selection="" row="" index_text=""
  local -i fzf_rc=0 index=0
  local -a rows=() options=() output_lines=()
  reply=()
  for (( index = 1; index <= ${#widget_labels}; index++ )); do
    rows+=("$index"$'\t'"${widget_labels[index]}")
  done
  options=(
    --height=40%
    "--prompt=$prompt"
    "--header=$header"
    $'--delimiter=\t'
    --with-nth=2
    --no-multi
  )
  [[ -n "$expect_key" ]] && options+=("--expect=$expect_key")

  selection=$(print -rl -- "${rows[@]}" | _tk_fzf "${options[@]}") \
    || fzf_rc=$?
  if (( fzf_rc == 1 || fzf_rc == 130 )); then
    REPLY=""
    return 1
  elif (( fzf_rc != 0 )); then
    REPLY="fzf failed (status $fzf_rc)"
    return 2
  fi

  output_lines=("${(@f)selection}")
  if [[ -n "$expect_key" ]]; then
    reply=("${output_lines[1]-}")
    [[ -z "${reply[1]}" || "${reply[1]}" == "$expect_key" ]] || {
      REPLY="fzf returned an unexpected key"
      return 2
    }
    row="${output_lines[2]-}"
  else
    reply=("")
    row="${output_lines[1]-}"
  fi
  [[ -n "$row" ]] || { REPLY=""; return 1; }
  # Validate the index as digits before any arithmetic sees it, then require
  # the complete row to be the one this invocation offered.
  index_text="${row%%$'\t'*}"
  if [[ "$index_text" != <1-> || ${#index_text} -gt 6 ]]; then
    REPLY="the selection was not in the picker snapshot"
    return 2
  fi
  index="$index_text"
  if (( index > ${#rows} )) || [[ "$row" != "${rows[index]}" ]]; then
    REPLY="the selection was not in the picker snapshot"
    return 2
  fi
  REPLY="$index"
}

# The widget body: collect, pick, and insert one quoted value at the cursor.
# Esc leaves the command line untouched.
_zdx_widget_insert() {
  emulate -L zsh
  local kind="${1-}" prompt="" header="" expect_key="" value="" REPLY=""
  local -a widget_values=() widget_alternates=() widget_labels=() reply=()
  local -i collect_rc=0 pick_rc=0 index=0

  (( ${+functions[_tk_fzf]} && ${+functions[_zdx_run_with_timeout]} )) || {
    _zdx_widget_message "the ZDX core runtime is not loaded"
    return 1
  }
  (( ${+commands[fzf]} )) || {
    _zdx_widget_message "fzf is required for insert pickers"
    return 1
  }

  case "$kind" in
    branch)
      _zdx_widget_branch_candidates || collect_rc=$?
      prompt='branch > '
      header='Enter insert branch | Esc cancel'
      ;;
    pr)
      _zdx_widget_pr_candidates || collect_rc=$?
      prompt='pull request > '
      header='Enter insert number | Esc cancel'
      ;;
    port)
      _zdx_widget_port_candidates || collect_rc=$?
      prompt='port > '
      header='Enter insert PID | Ctrl-O insert port | Esc cancel'
      expect_key=ctrl-o
      ;;
    venv)
      _zdx_widget_venv_candidates || collect_rc=$?
      prompt='venv > '
      header='Enter insert path | Esc cancel'
      ;;
    *)
      _zdx_widget_message "unknown insert picker"
      return 1
      ;;
  esac
  if (( collect_rc != 0 )); then
    _zdx_widget_message "$REPLY"
    return 1
  fi

  _zdx_widget_pick "$prompt" "$header" "$expect_key" || pick_rc=$?
  zle reset-prompt
  case $pick_rc in
    0) ;;
    1) return 0 ;;
    *) _zdx_widget_message "$REPLY"; return 1 ;;
  esac

  index="$REPLY"
  if [[ "${reply[1]-}" == ctrl-o ]]; then
    value="${widget_alternates[index]-}"
  else
    value="${widget_values[index]-}"
  fi
  if [[ -z "$value" ]]; then
    if [[ "$kind" == port ]]; then
      _zdx_widget_message "the process on port ${widget_alternates[index]-} is not visible; press Ctrl-O to insert the port"
    else
      _zdx_widget_message "the selection has no value to insert"
    fi
    return 1
  fi
  LBUFFER+="${(q)value}"
  return 0
}

typeset -g _ZDX_WIDGETS_SOURCED=1
