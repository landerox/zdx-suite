#!/usr/bin/env zsh
# =============================================================================
# Env Suite: read-only dotenv key comparison and file hygiene
# =============================================================================
#
# Loaded by env-menu.zsh after env-common.zsh.
# Safe to re-source; defines functions and fixed limits only.
#
# Dotenv files are parsed as data through a bounded no-follow descriptor; no
# line ever becomes shell code. Only key names, line numbers, and whether a
# value is set or empty leave the parser. Values, their lengths, and their
# digests are never printed, logged, or emitted, including example values.
#

if [[ -n "${_ENV_DOTENV_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset -gi _ENV_DOTENV_MAX_LINES=10000
typeset -gi _ENV_DOTENV_MAX_KEY_LENGTH=128
typeset -gi _ENV_DOTENV_GIT_TIMEOUT=10
typeset -gi _ENV_DOTENV_TEXT_LIMIT=50
typeset -ga _ENV_DOTENV_EXAMPLE_NAMES=(
  .env.example
  .env.sample
  .env.template
  .env.dist
)

_env_dotenv_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- "  env-dotenv [FILE] [--example FILE] [--json]"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Compares the keys of a dotenv file (default: .env) with its example (default:"
  print -u2 -r -- \
    "the first of .env.example, .env.sample, .env.template, .env.dist next to FILE)."
  print -u2 -r -- \
    "Both files are parsed as data and never run. Only key names, line numbers, and"
  print -u2 -r -- \
    "whether a value is set or empty are reported; values never are."
  print -u2 -r -- ""
  print -u2 -r -- \
    "--json emits one zdx.env-dotenv.v1 JSON object on stdout and requires jq."
  print -u2 -r -- \
    "Exit status: 0 when no issue is found, 1 when an issue is found or the check"
  print -u2 -r -- "cannot run, and 2 for invalid arguments."
}

# --- Bounded external probes ------------------------------------------------

# Runs one external program with a deadline: status 124 on timeout, 2 for
# invalid arguments, and 127 when the program is not on PATH. The program is
# resolved to its absolute path, so a function or alias never runs. The core
# _zdx_run_with_timeout owns the portable implementation, including a Zsh
# watchdog for hosts without timeout; sourced without the core, timeout or
# gtimeout is required and the probe fails closed without either.
# Usage: _env_run_with_timeout <seconds> <program> [argument...]
_env_run_with_timeout() {
  local seconds="${1-}"
  shift 2>/dev/null
  [[ "$seconds" == <1-600> && ${#seconds} -le 3 ]] && (( $# > 0 )) \
    || return 2
  local program="$1"
  shift
  if [[ "$program" != /* ]]; then
    program=$(whence -p -- "$program" 2>/dev/null) || program=""
  fi
  [[ "$program" == /* && -x "$program" ]] || return 127

  if (( ${+functions[_zdx_run_with_timeout]} )); then
    _zdx_run_with_timeout "$seconds" "$program" "$@"
    return
  fi
  local candidate="" timeout_command=""
  for candidate in timeout gtimeout; do
    timeout_command=$(whence -p -- "$candidate" 2>/dev/null) \
      || timeout_command=""
    [[ "$timeout_command" == /* && -x "$timeout_command" ]] || continue
    command "$timeout_command" -k 2s "${seconds}s" "$program" "$@"
    return
  done
  return 1
}

# REPLY: the absolute git for the hygiene probes. Status 1 when git is
# absent, is Apple's Command Line Tools placeholder on macOS (running it opens
# an installation dialog), or is a Windows program that WSL reaches through
# the appended Windows PATH.
_env_git_program() {
  emulate -L zsh
  REPLY=""
  local program="" developer_dir=""
  program=$(whence -p git 2>/dev/null) || return 1
  [[ "$program" == /* && -x "$program" ]] || return 1
  if [[ "${OSTYPE:-}" == darwin* && "$program" == /usr/bin/git ]]; then
    developer_dir=$(_env_run_with_timeout 5 xcode-select -p \
      </dev/null 2>/dev/null) || return 1
    developer_dir="${developer_dir%%$'\n'*}"
    [[ -n "$developer_dir" && -d "$developer_dir" ]] || return 1
  fi
  if [[ "$program" == /mnt/[a-z]/* ]] && _env_host_is_wsl; then
    return 1
  fi
  REPLY="$program"
}

# Runs one read-only git query in <directory> with closed stdin and a
# deadline, taking no optional lock. Repository-locating variables such as
# GIT_DIR, which Git exports to its hooks, are cleared so the directory alone
# selects the repository.
# Usage: _env_dotenv_git <git> <directory> <git-arguments...>
_env_dotenv_git() {
  local git_program="$1" directory="$2"
  shift 2
  (
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX \
      GIT_IMPLICIT_WORK_TREE
    _env_run_with_timeout "$_ENV_DOTENV_GIT_TIMEOUT" "$git_program" \
      --no-optional-locks -C "$directory" "$@" </dev/null
  )
}

# reply: (repository tracked ignored note) for <file>. The first three are
# yes, no, or unknown; ignored follows the ignore rules even for a tracked
# file. note is empty, unavailable (no usable git), timeout, or failed.
_env_dotenv_git_facts() {
  emulate -L zsh
  local file_path="$1"
  local directory="${file_path:a:h}" file_name="${file_path:t}"
  local inside="" REPLY=""
  local -i probe_rc=0
  reply=(unknown unknown unknown "")

  _env_git_program || {
    reply[4]=unavailable
    return 0
  }
  local git_program="$REPLY"

  inside=$(_env_dotenv_git "$git_program" "$directory" \
    rev-parse --is-inside-work-tree 2>/dev/null) || probe_rc=$?
  case "$probe_rc" in
    0) ;;
    124) reply[4]=timeout; return 0 ;;
    128) reply=(no unknown unknown ""); return 0 ;;
    *) reply[4]=failed; return 0 ;;
  esac
  if [[ "$inside" != true ]]; then
    reply=(no unknown unknown "")
    return 0
  fi
  reply[1]=yes

  # The name is a literal pathspec, so glob characters match only themselves.
  # check-ignore takes plain path names and rejects that option.
  probe_rc=0
  _env_dotenv_git "$git_program" "$directory" --literal-pathspecs \
    ls-files --error-unmatch -- "$file_name" >/dev/null 2>&1 || probe_rc=$?
  case "$probe_rc" in
    0) reply[2]=yes ;;
    1) reply[2]=no ;;
    124) reply[4]=timeout; return 0 ;;
    *) reply[4]=failed; return 0 ;;
  esac

  probe_rc=0
  _env_dotenv_git "$git_program" "$directory" \
    check-ignore -q --no-index -- "$file_name" >/dev/null 2>&1 \
    || probe_rc=$?
  case "$probe_rc" in
    0) reply[3]=yes ;;
    1) reply[3]=no ;;
    124) reply[4]=timeout ;;
    *) reply[4]=failed ;;
  esac
  return 0
}

# --- Reading and parsing ----------------------------------------------------

# REPLY: the first of _ENV_DOTENV_EXAMPLE_NAMES that exists next to
# <dotenv-file>, other than that file itself. A symbolic link or other
# non-regular entry still wins its turn, so the reader refuses it rather than
# silently falling through to a later name. Status 1 when none exists.
_env_dotenv_find_example() {
  emulate -L zsh
  local dotenv_path="$1" directory="${1:h}" name="" candidate=""
  REPLY=""
  for name in "${_ENV_DOTENV_EXAMPLE_NAMES[@]}"; do
    if [[ "$dotenv_path" != */* ]]; then
      candidate="$name"
    elif [[ "$directory" == / ]]; then
      candidate="/$name"
    else
      candidate="$directory/$name"
    fi
    [[ "${candidate:a}" != "${dotenv_path:a}" ]] || continue
    if [[ -e "$candidate" || -L "$candidate" ]]; then
      REPLY="$candidate"
      return 0
    fi
  done
  return 1
}

# REPLY: the bytes of <file>; reply: (mode uid) of the file that was read.
# Refuses a symbolic link, a non-regular file, and a file larger than
# _ENV_MAX_FILE_BYTES. The bytes are read through a no-follow, non-blocking
# descriptor whose device and inode must match the inspected path.
# Usage: _env_dotenv_read <file> <label>
_env_dotenv_read() {
  emulate -L zsh
  setopt LOCAL_OPTIONS NO_MULTIBYTE
  local file_path="$1" label="$2"
  REPLY=""
  reply=()
  { zmodload -F zsh/stat b:zstat && zmodload zsh/system; } 2>/dev/null || {
    _env_error "Zsh file-descriptor support is required to read dotenv files."
    return 1
  }

  if [[ -L "$file_path" ]]; then
    _env_error "Refusing the $label $file_path: it is a symbolic link."
    _env_info "Pass the file it points to instead."
    return 1
  fi
  local -A path_state=() descriptor_state=()
  zstat -LH path_state -- "$file_path" 2>/dev/null || {
    _env_error "Cannot inspect the $label $file_path."
    return 1
  }
  (( (path_state[mode] & 8#170000) == 8#100000 )) || {
    _env_error "Refusing the $label $file_path: it is not a regular file."
    return 1
  }
  local -i limit_mib=$(( _ENV_MAX_FILE_BYTES / 1048576 ))
  (( path_state[size] <= _ENV_MAX_FILE_BYTES )) || {
    _env_error "Refusing the $label $file_path: it is larger than $limit_mib MiB."
    return 1
  }

  local -i read_fd=-1 read_rc=0
  local content="" chunk=""
  sysopen -r -o nofollow,nonblock,cloexec -u read_fd \
    -- "$file_path" 2>/dev/null || {
    _env_error "Cannot read the $label $file_path."
    return 1
  }
  {
    if ! zstat -H descriptor_state -f "$read_fd" 2>/dev/null \
      || (( (descriptor_state[mode] & 8#170000) != 8#100000 \
        || descriptor_state[device] != path_state[device] \
        || descriptor_state[inode] != path_state[inode] )); then
      read_rc=-1
    else
      while (( ${#content} <= _ENV_MAX_FILE_BYTES )); do
        sysread -i "$read_fd" -s 65536 chunk || {
          read_rc=$?
          break
        }
        content+="$chunk"
      done
    fi
  } always {
    (( read_fd >= 0 )) && exec {read_fd}<&-
  }

  if (( read_rc == -1 )); then
    _env_error "The $label $file_path changed while it was opened."
    return 1
  fi
  (( ${#content} <= _ENV_MAX_FILE_BYTES )) || {
    _env_error "Refusing the $label $file_path: it is larger than $limit_mib MiB."
    return 1
  }
  # sysread reports end of file as status 5.
  (( read_rc == 5 )) || {
    _env_error "Cannot read the $label $file_path."
    return 1
  }
  REPLY="$content"
  reply=("${descriptor_state[mode]}" "${descriptor_state[uid]}")
}

# REPLY: the length of <text> before its first unescaped <quote>. A backslash
# escapes the character after it, so \" or \' does not close a value. Status 1
# when <text> has no closing quote.
# Usage: _env_dotenv_quote_end <text> <quote>
_env_dotenv_quote_end() {
  emulate -L zsh
  setopt LOCAL_OPTIONS NO_MULTIBYTE
  local text="${1-}" quote="${2-}" head="" special=""
  local -i offset=0
  REPLY=""
  if [[ "$quote" == '"' ]]; then
    special='[\\"]'
  else
    special="[\\\\']"
  fi
  while :; do
    head="${text%%${~special}*}"
    (( ${#head} < ${#text} )) || return 1
    if [[ "${text[${#head}+1]}" == "$quote" ]]; then
      REPLY=$(( offset + ${#head} ))
      return 0
    fi
    # Skip the backslash and the character it escapes.
    offset+=$(( ${#head} + 2 ))
    text="${text[${#head}+3,-1]}"
  done
}

# stdout: summary records for dotenv <content> that carry key names and line
# numbers only; a value's single exposed fact is whether it is empty.
#   key<TAB>NAME                  each key once, in order of first assignment
#   empty<TAB>NAME                a key whose last assignment is empty
#   duplicate<TAB>NAME<TAB>L,L    a key assigned on more than one line
#   malformed<TAB>LINE            a line the grammar rejects
# Status 3 when the content has more than _ENV_DOTENV_MAX_LINES lines.
# The grammar is documented in docs/env-menu.md.
# Usage: _env_dotenv_parse <content>
_env_dotenv_parse() {
  emulate -L zsh
  setopt LOCAL_OPTIONS EXTENDED_GLOB NO_MULTIBYTE
  local content="${1-}"
  content="${content#$'\xef\xbb\xbf'}"
  local -a lines=("${(@f)content}")
  # A final newline ends the last line; it does not start another one.
  [[ "$content" == *$'\n' ]] && lines[-1]=()
  (( ${#lines[@]} <= _ENV_DOTENV_MAX_LINES )) || return 3

  local -a keys=() malformed=()
  local -A key_lines=() key_state=()
  local line="" rest="" key="" raw_value="" quote="" text="" tail="" state=""
  local -i index=1 start=0 next=0 closed=0 count=${#lines[@]}
  while (( index <= count )); do
    start=$index
    line="${lines[index]%$'\r'}"
    (( ++index ))
    rest="${line##[[:blank:]]#}"
    [[ -z "$rest" || "$rest" == \#* ]] && continue
    if [[ "$rest" == *$'\0'* ]]; then
      malformed+=($start)
      continue
    fi
    [[ "$rest" == export[[:blank:]]* ]] \
      && rest="${${rest#export}##[[:blank:]]#}"
    key="${rest%%[^A-Za-z0-9_]*}"
    rest="${${rest:${#key}}##[[:blank:]]#}"
    if [[ "$key" != [A-Za-z_]* || "$rest" != '='* ]] \
      || (( ${#key} > _ENV_DOTENV_MAX_KEY_LENGTH )); then
      malformed+=($start)
      continue
    fi
    raw_value="${rest#=}"
    rest="${raw_value##[[:blank:]]#}"

    if [[ "$rest" == [\"\']* ]]; then
      quote="${rest[1]}"
      text="${rest[2,-1]}"
      tail=""
      closed=0
      if _env_dotenv_quote_end "$text" "$quote"; then
        closed=1
        if (( REPLY > 0 )); then state=set; else state=empty; fi
        tail="${text[REPLY+2,-1]}"
      else
        # The value continues on the following lines until its quote
        # closes. Without a closing quote, parsing resumes on the next line.
        state=set
        for (( next = index; next <= count; ++next )); do
          text="${lines[next]%$'\r'}"
          if _env_dotenv_quote_end "$text" "$quote"; then
            closed=1
            tail="${text[REPLY+2,-1]}"
            index=$(( next + 1 ))
            break
          fi
        done
      fi
      tail="${tail##[[:blank:]]#}"
      if (( ! closed )) || [[ -n "$tail" && "$tail" != \#* ]]; then
        malformed+=($start)
        continue
      fi
    else
      # An unquoted value ends where a # follows a blank.
      rest="${raw_value%%[[:blank:]]\#*}"
      rest="${${rest##[[:blank:]]#}%%[[:blank:]]#}"
      if [[ -n "$rest" ]]; then state=set; else state=empty; fi
    fi

    if (( ${+key_lines[$key]} )); then
      key_lines[$key]+=",$start"
    else
      keys+=("$key")
      key_lines[$key]="$start"
    fi
    key_state[$key]="$state"
  done

  for key in "${keys[@]}"; do
    printf 'key\t%s\n' "$key"
  done
  for key in "${keys[@]}"; do
    [[ "${key_state[$key]}" == empty ]] && printf 'empty\t%s\n' "$key"
  done
  for key in "${keys[@]}"; do
    [[ "${key_lines[$key]}" == *,* ]] \
      && printf 'duplicate\t%s\t%s\n' "$key" "${key_lines[$key]}"
  done
  (( ${#malformed[@]} == 0 )) || printf 'malformed\t%s\n' "${malformed[@]}"
  return 0
}

# reply: the payloads of the <type> records among <records...>.
# Usage: _env_dotenv_select <type> [record...]
_env_dotenv_select() {
  local record_type="$1" record=""
  shift
  reply=()
  for record in "$@"; do
    [[ "$record" == "$record_type"$'\t'* ]] && reply+=("${record#*$'\t'}")
  done
  return 0
}

# REPLY: the records of <file> from _env_dotenv_parse after a bounded read.
# reply: (mode uid) as _env_dotenv_read reports them.
# Usage: _env_dotenv_scan <file> <label>
_env_dotenv_scan() {
  local file_path="$1" label="$2"
  local -i parse_rc=0
  _env_dotenv_read "$file_path" "$label" || return 1
  local records=""
  records=$(_env_dotenv_parse "$REPLY") || parse_rc=$?
  REPLY=""
  if (( parse_rc == 3 )); then
    _env_error \
      "Refusing the $label $file_path: it has more than $_ENV_DOTENV_MAX_LINES lines."
    return 1
  elif (( parse_rc != 0 )); then
    _env_error "Could not parse the $label $file_path."
    return 1
  fi
  REPLY="$records"
}

# --- Reporting --------------------------------------------------------------

# REPLY: "<count> <noun> <verb>", such as "1 key is" or "2 keys are", with the
# counted noun from _env_count_noun and the verb agreeing with the count.
# Usage: _env_dotenv_count_phrase <count> <noun> <singular-verb> <plural-verb>
_env_dotenv_count_phrase() {
  local -i count="$1"
  local verb="$4"
  (( count == 1 )) && verb="$3"
  _env_count_noun "$count" "$2" || return
  REPLY+=" $verb"
}

# Prints up to _ENV_DOTENV_TEXT_LIMIT items as dim detail lines.
_env_dotenv_detail_list() {
  local item=""
  local -i shown=0
  for item in "$@"; do
    (( shown < _ENV_DOTENV_TEXT_LIMIT )) || break
    _env_dim "$item"
    (( ++shown ))
  done
  (( $# > shown )) || return 0
  _env_dim "… and $(( $# - shown )) more; env-dotenv --json lists them all."
}

# Prints the syntax findings of one file: duplicate keys with their lines and
# malformed lines by number.
# Usage: _env_dotenv_report_syntax <display> <duplicate-count> \
#   [duplicate-payload...] -- [malformed-line...]
_env_dotenv_report_syntax() {
  local display="$1"
  local -i duplicate_count="$2"
  shift 2
  local -a duplicate_payloads=("${@[1,duplicate_count]}")
  shift $(( duplicate_count + 1 ))
  local -a malformed_lines=("$@") details=()
  local payload=""

  if (( ${#duplicate_payloads[@]} > 0 )); then
    _env_dotenv_count_phrase "${#duplicate_payloads[@]}" key is are
    _env_warn "$REPLY assigned on more than one line in $display:"
    for payload in "${duplicate_payloads[@]}"; do
      details+=("${payload%%$'\t'*}: lines ${${payload#*$'\t'}//,/, }")
    done
    _env_dotenv_detail_list "${details[@]}"
  fi
  if (( ${#malformed_lines[@]} > 0 )); then
    _env_count_noun "${#malformed_lines[@]}" line
    _env_warn "$REPLY in $display could not be parsed:"
    local -a shown_lines=("${malformed_lines[@]:0:20}")
    local line_list="${(j:, :)shown_lines}" line_word="Lines"
    (( ${#malformed_lines[@]} == 1 )) && line_word="Line"
    (( ${#malformed_lines[@]} <= 20 )) \
      || line_list+=", and $(( ${#malformed_lines[@]} - 20 )) more"
    _env_dim "$line_word $line_list"
  fi
}

# stdout: one zdx.env-dotenv.v1 JSON object on a single line followed by a
# newline, built by jq in compact mode. Scalar facts arrive as --arg and
# --argjson values; key names and line numbers arrive on stdin as
# TAB-separated typed records that jq splits itself, so the shell never
# assembles JSON text and no argument can exceed the platform's size limit.
# Usage: _env_dotenv_print_json <dotenv-path> <example-path-or-empty> <mode> \
#   <readable> <writable> <owned> <repository> <tracked> <ignored> \
#   <issue-count> [record...]
_env_dotenv_print_json() {
  emulate -L zsh
  setopt LOCAL_OPTIONS PIPE_FAIL
  local dotenv_path="$1" example_path="$2" mode="$3"
  local readable="$4" writable="$5" owned="$6"
  local git_repository="$7" git_tracked="$8" git_ignored="$9"
  local issue_count="${10}"
  shift 10
  [[ "$issue_count" == <-> ]] || return 1

  local json="" program='
def flag: if . == "yes" then true elif . == "no" then false else null end;
def payloads($records; $type):
  [$records[] | select(.[0] == $type) | .[1:]];
def names($records; $type): [payloads($records; $type)[] | .[0]];
def numbers: split(",") | map(tonumber);
def duplicates($records; $type):
  [payloads($records; $type)[] | {key: .[0], lines: (.[1] | numbers)}];
def line_numbers($records; $type):
  [payloads($records; $type)[] | .[0] | tonumber];
[inputs | select(length > 0) | split("\t")] as $records
| {
    schema: "zdx.env-dotenv.v1",
    dotenv: {
      path: $dotenv_path,
      key_count: (names($records; "dotenv-key") | length),
      empty: names($records; "dotenv-empty"),
      duplicates: duplicates($records; "dotenv-duplicate"),
      malformed_lines: line_numbers($records; "dotenv-malformed"),
      mode: $mode,
      readable_by_others: ($readable | flag),
      writable_by_others: ($writable | flag),
      owned_by_user: ($owned | flag),
      git: {
        repository: ($git_repository | flag),
        tracked: ($git_tracked | flag),
        ignored: ($git_ignored | flag)
      }
    },
    example: (if $example_path == "" then null else {
      path: $example_path,
      key_count: (names($records; "example-key") | length),
      duplicates: duplicates($records; "example-duplicate"),
      malformed_lines: line_numbers($records; "example-malformed")
    } end),
    missing: (if $example_path == "" then null
      else names($records; "missing") end),
    extra: (if $example_path == "" then null
      else names($records; "extra") end),
    in_sync: (if $example_path == "" then null
      else ((names($records; "missing") | length) == 0
        and (names($records; "extra") | length) == 0) end),
    issue_count: $issue_count
  }'
  json=$(print -rl -- "$@" | command jq -c -n -R -M \
    --arg dotenv_path "$dotenv_path" \
    --arg example_path "$example_path" \
    --arg mode "$mode" \
    --arg readable "$readable" \
    --arg writable "$writable" \
    --arg owned "$owned" \
    --arg git_repository "$git_repository" \
    --arg git_tracked "$git_tracked" \
    --arg git_ignored "$git_ignored" \
    --argjson issue_count "$issue_count" \
    "$program" 2>/dev/null) || {
    _env_error "jq could not build the env-dotenv JSON report."
    return 1
  }
  print -r -- "$json"
}

# --- Public command ---------------------------------------------------------

env-dotenv() {
  emulate -L zsh
  local dotenv_path=".env" example_path="" json_mode="no"
  local -i have_dotenv_path=0 have_example=0

  if [[ "${1:-}" == (-h|--help) ]]; then
    (( $# == 1 )) || {
      _env_error "--help accepts no additional arguments."
      return 2
    }
    _env_dotenv_usage
    return 0
  fi
  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        _env_error "--help accepts no additional arguments."
        return 2
        ;;
      --example)
        (( $# >= 2 )) && [[ -n "$2" ]] || {
          _env_error "--example requires a file path."
          return 2
        }
        (( ! have_example )) || {
          _env_error "--example accepts only one file."
          return 2
        }
        example_path="$2"
        have_example=1
        shift
        ;;
      --json)
        [[ "$json_mode" == no ]] || {
          _env_error "--json was given more than once."
          return 2
        }
        json_mode="yes"
        ;;
      -*)
        _env_error "Unknown env-dotenv option: $1"
        return 2
        ;;
      *)
        (( ! have_dotenv_path )) || {
          _env_error "env-dotenv accepts only one dotenv file."
          return 2
        }
        [[ -n "$1" ]] || {
          _env_error "The dotenv file path is empty."
          return 2
        }
        dotenv_path="$1"
        have_dotenv_path=1
        ;;
    esac
    shift
  done
  if [[ "$json_mode" == yes ]]; then
    _env_require_cmd jq "env-dotenv --json" || return 1
  fi

  local REPLY=""
  local -a reply=()
  if [[ ! -e "$dotenv_path" && ! -L "$dotenv_path" ]]; then
    _env_error "No dotenv file exists at $dotenv_path."
    if (( ! have_example )) && _env_dotenv_find_example "$dotenv_path"; then
      _env_info "Create $dotenv_path from $REPLY, then run env-dotenv again."
    fi
    return 1
  fi
  if (( have_example )); then
    [[ -e "$example_path" || -L "$example_path" ]] || {
      _env_error "No example file exists at $example_path."
      return 1
    }
  elif _env_dotenv_find_example "$dotenv_path"; then
    example_path="$REPLY"
  fi

  _env_dotenv_scan "$dotenv_path" "dotenv file" || return 1
  local -a dotenv_records=("${(@f)REPLY}")
  local -i dotenv_mode="${reply[1]}" dotenv_uid="${reply[2]}"
  local -a example_records=()
  if [[ -n "$example_path" ]]; then
    _env_dotenv_scan "$example_path" "example file" || return 1
    example_records=("${(@f)REPLY}")
  fi

  _env_dotenv_select key "${dotenv_records[@]}"
  local -a dotenv_keys=("${reply[@]}")
  _env_dotenv_select empty "${dotenv_records[@]}"
  local -a empty_keys=("${reply[@]}")
  _env_dotenv_select duplicate "${dotenv_records[@]}"
  local -a dotenv_duplicates=("${reply[@]}")
  _env_dotenv_select malformed "${dotenv_records[@]}"
  local -a dotenv_malformed=("${reply[@]}")
  _env_dotenv_select key "${example_records[@]}"
  local -a example_keys=("${reply[@]}")
  _env_dotenv_select duplicate "${example_records[@]}"
  local -a example_duplicates=("${reply[@]}")
  _env_dotenv_select malformed "${example_records[@]}"
  local -a example_malformed=("${reply[@]}")

  local -a missing_keys=() extra_keys=()
  local -A dotenv_has=() example_has=()
  local key=""
  for key in "${dotenv_keys[@]}"; do
    dotenv_has[$key]=1
  done
  for key in "${example_keys[@]}"; do
    example_has[$key]=1
    (( ${+dotenv_has[$key]} )) || missing_keys+=("$key")
  done
  if [[ -n "$example_path" ]]; then
    for key in "${dotenv_keys[@]}"; do
      (( ${+example_has[$key]} )) || extra_keys+=("$key")
    done
  fi

  local mode_text=""
  printf -v mode_text '%04o' $(( dotenv_mode & 8#7777 ))
  local readable_by_others="no" writable_by_others="no" owned_by_user="yes"
  (( (dotenv_mode & 8#044) == 0 )) || readable_by_others="yes"
  (( (dotenv_mode & 8#022) == 0 )) || writable_by_others="yes"
  (( dotenv_uid == EUID )) || owned_by_user="no"

  _env_dotenv_git_facts "$dotenv_path"
  local git_repository="${reply[1]}" git_tracked="${reply[2]}"
  local git_ignored="${reply[3]}" git_note="${reply[4]}"
  if [[ "$git_note" == timeout ]]; then
    _env_warn \
      "Git did not answer within ${_ENV_DOTENV_GIT_TIMEOUT}s; tracking and ignore rules were not checked."
  elif [[ "$git_note" == failed ]]; then
    _env_warn "Git could not check tracking and ignore rules for $dotenv_path."
  fi

  local -i issue_count=$(( ${#missing_keys[@]} + ${#extra_keys[@]} \
    + ${#empty_keys[@]} + ${#dotenv_duplicates[@]} \
    + ${#example_duplicates[@]} + ${#dotenv_malformed[@]} \
    + ${#example_malformed[@]} ))
  [[ "$git_tracked" == yes ]] && (( ++issue_count ))
  [[ "$git_tracked" == no && "$git_ignored" == no ]] && (( ++issue_count ))
  [[ "$readable_by_others" == yes || "$writable_by_others" == yes ]] \
    && (( ++issue_count ))
  [[ "$owned_by_user" == yes ]] || (( ++issue_count ))
  local -i result_rc=0
  (( issue_count == 0 )) || result_rc=1

  if [[ "$json_mode" == yes ]]; then
    local -a json_records=()
    local payload=""
    for key in "${dotenv_keys[@]}"; do json_records+=("dotenv-key"$'\t'"$key"); done
    for key in "${empty_keys[@]}"; do json_records+=("dotenv-empty"$'\t'"$key"); done
    for payload in "${dotenv_duplicates[@]}"; do
      json_records+=("dotenv-duplicate"$'\t'"$payload")
    done
    for payload in "${dotenv_malformed[@]}"; do
      json_records+=("dotenv-malformed"$'\t'"$payload")
    done
    for key in "${example_keys[@]}"; do json_records+=("example-key"$'\t'"$key"); done
    for payload in "${example_duplicates[@]}"; do
      json_records+=("example-duplicate"$'\t'"$payload")
    done
    for payload in "${example_malformed[@]}"; do
      json_records+=("example-malformed"$'\t'"$payload")
    done
    for key in "${missing_keys[@]}"; do json_records+=("missing"$'\t'"$key"); done
    for key in "${extra_keys[@]}"; do json_records+=("extra"$'\t'"$key"); done
    local example_absolute=""
    [[ -z "$example_path" ]] || example_absolute="${example_path:a}"
    _env_dotenv_print_json "${dotenv_path:a}" "$example_absolute" \
      "$mode_text" "$readable_by_others" "$writable_by_others" \
      "$owned_by_user" "$git_repository" "$git_tracked" "$git_ignored" \
      "$issue_count" "${json_records[@]}" || return 1
    return $result_rc
  fi

  local dotenv_display="$dotenv_path" example_display="$example_path"
  _env_header "Dotenv Check"
  _env_label "Dotenv file" "$dotenv_display"
  _env_label "Example file" "${example_display:-none found}"
  local key_summary="${#dotenv_keys[@]} in $dotenv_display"
  [[ -z "$example_path" ]] \
    || key_summary+=", ${#example_keys[@]} in $example_display"
  _env_label "Keys" "$key_summary"

  _env_section "Keys"
  if [[ -z "$example_path" ]]; then
    _env_info \
      "No example file was found next to $dotenv_display; missing and extra keys were not checked."
    _env_dim "Looked for ${(j:, :)_ENV_DOTENV_EXAMPLE_NAMES}."
  elif (( ${#missing_keys[@]} == 0 && ${#extra_keys[@]} == 0 )); then
    _env_success \
      "$dotenv_display defines every key in $example_display and no others."
  fi
  if (( ${#missing_keys[@]} > 0 )); then
    _env_dotenv_count_phrase "${#missing_keys[@]}" key is are
    _env_warn "$REPLY in $example_display but missing in $dotenv_display:"
    _env_dotenv_detail_list "${missing_keys[@]}"
  fi
  if (( ${#extra_keys[@]} > 0 )); then
    _env_dotenv_count_phrase "${#extra_keys[@]}" key is are
    _env_warn "$REPLY in $dotenv_display but not in $example_display:"
    _env_dotenv_detail_list "${extra_keys[@]}"
  fi
  if (( ${#empty_keys[@]} > 0 )); then
    _env_dotenv_count_phrase "${#empty_keys[@]}" key has have
    _env_warn "$REPLY an empty value in $dotenv_display:"
    _env_dotenv_detail_list "${empty_keys[@]}"
  else
    _env_success "Every key in $dotenv_display has a value."
  fi

  _env_section "Syntax"
  if (( ${#dotenv_duplicates[@]} + ${#dotenv_malformed[@]} \
    + ${#example_duplicates[@]} + ${#example_malformed[@]} == 0 )); then
    _env_success "No duplicate keys or malformed lines."
  else
    _env_dotenv_report_syntax "$dotenv_display" "${#dotenv_duplicates[@]}" \
      "${dotenv_duplicates[@]}" -- "${dotenv_malformed[@]}"
    [[ -z "$example_path" ]] \
      || _env_dotenv_report_syntax "$example_display" \
        "${#example_duplicates[@]}" "${example_duplicates[@]}" \
        -- "${example_malformed[@]}"
  fi

  _env_section "Hygiene"
  local git_directory="${dotenv_path:h}" git_name="${dotenv_path:t}"
  # A timed-out or failed probe was reported above; its unknown facts are
  # neither praised nor counted.
  if [[ "$git_note" == unavailable ]]; then
    _env_info "git is not available, so tracking and ignore rules were not checked."
  elif [[ "$git_repository" == no ]]; then
    _env_info "$dotenv_display is not in a Git repository."
  elif [[ "$git_tracked" == yes ]]; then
    _env_warn \
      "$dotenv_display is tracked by Git, so its values are in the repository history."
    if [[ "$dotenv_path" == */* ]]; then
      _env_command_display git -C "$git_directory" rm --cached -- "$git_name"
    else
      _env_command_display git rm --cached -- "$dotenv_path"
    fi
    _env_dim "Stop tracking it with: $REPLY"
    [[ "$git_ignored" == yes ]] \
      && _env_dim "Its ignore rule has no effect while it is tracked."
  elif [[ "$git_tracked" == no && "$git_ignored" == no ]]; then
    _env_warn "$dotenv_display is not ignored by Git, so it could be committed."
    _env_dim "Add it to .gitignore."
  elif [[ "$git_tracked" == no && "$git_ignored" == yes ]]; then
    _env_success "$dotenv_display is ignored by Git and not tracked."
  fi
  if [[ "$readable_by_others" == yes || "$writable_by_others" == yes ]]; then
    local access="readable"
    if [[ "$readable_by_others" == yes && "$writable_by_others" == yes ]]; then
      access="readable and writable"
    elif [[ "$writable_by_others" == yes ]]; then
      access="writable"
    fi
    _env_warn "$dotenv_display is $access by other users (mode $mode_text)."
    _env_command_display chmod -- 600 "$dotenv_path"
    _env_dim "Restrict it with: $REPLY"
    if [[ "${dotenv_path:A}" == /mnt/[a-z]/* ]] && _env_host_is_wsl; then
      _env_dim \
        "This file is on a Windows drive (DrvFs), which reports mode 777 unless metadata is enabled."
      _env_dim \
        "Keep the project in your Linux home (~), or add options = \"metadata,umask=22,fmask=11\" under [automount] in /etc/wsl.conf, then run: wsl.exe --shutdown"
    fi
  else
    _env_success "Only its owner can read or write $dotenv_display (mode $mode_text)."
  fi
  if [[ "$owned_by_user" == no ]]; then
    _env_warn "$dotenv_display is owned by another user (UID $dotenv_uid)."
  fi

  print -u2 -r -- ""
  if (( issue_count == 0 )); then
    _env_success "Dotenv check: no issues found."
  else
    _env_count_noun "$issue_count" issue
    _env_warn "Dotenv check: $REPLY found — review the output above."
  fi
  return $result_rc
}

typeset -g _ENV_DOTENV_SOURCED=1
