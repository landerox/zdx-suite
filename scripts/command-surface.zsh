#!/usr/bin/env zsh
# =============================================================================
# ZDX Command Surfaces: public-command parity checker and scaffolding
# =============================================================================
#
# Executed by the Justfile surfaces and new-command recipes; reads and edits
# only the repository that contains this script.
# Safe to re-source; defines private helpers only.
#
# `check` is read-only. `new` plans every edit in memory, parses each changed
# Zsh file with `zsh -n`, and replaces files only after the whole plan
# validates. User input is checked against allowlists before it is placed in
# generated source, and nothing is evaluated.
#
if [[ -n "${_ZDX_SURFACE_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset -g _ZDX_SURFACE_SOURCE_FILE="${${(%):-%x}:A}"

# --- Shared state ------------------------------------------------------------
# One suite model is loaded at a time. Paths in messages are relative to the
# repository root, and line numbers are 1-based.

typeset -g _zs_root="" _zs_tool="surfaces"
typeset -gi _zs_problems=0 _zs_warnings=0
typeset -gA _ZS=()
typeset -ga _ZS_COLUMNS=() _ZS_COMMANDS=() _ZS_SUITE_ROWS=()
typeset -gA _ZS_ROW_LINE=() _ZS_ROW_MODULE=() _ZS_ROW_VALUES=()
typeset -gA _ZS_DEFS=() _ZS_ARMS=() _ZS_ROWS_COUNT=() _ZS_ROWS_LINE=()
typeset -gA _ZS_HELP=() _ZS_COMP=() _ZS_BIND=() _ZS_LAZY=() _ZS_ALLOW=()
typeset -gA _ZS_DOC=() _ZS_GUIDE=() _ZS_ROUTER=() _ZS_MASTER=() _ZS_ZDXCOMP=()
typeset -gA _ZS_RULE=() _ZS_VALUE=()
typeset -ga _ZS_L_menu=() _ZS_L_common=() _ZS_L_comp=() _ZS_L_lazy=()

# Planned edits for `new`: KIND is `after` (insert TEXT after LINE, 0 for the
# top) or `replace` (LINE becomes TEXT). LINE refers to the unedited file.
typeset -ga _ZS_EDIT_FILE=() _ZS_EDIT_KIND=() _ZS_EDIT_LINE=()
typeset -ga _ZS_EDIT_TEXT=() _ZS_EDIT_SURFACE=()
typeset -gA _ZS_ORIG=() _ZS_NEW=()

# Allowed characters for menu labels and descriptions. The text lands inside
# double-quoted Zsh strings, single-quoted completion specs, and `|`-delimited
# menu records, so quotes, `$`, backquotes, backslashes, `|`, `%`, and control
# characters are refused.
typeset -g _ZS_TEXT_PATTERN='^[A-Z][A-Za-z0-9 ,.;:()/+&_-]*[A-Za-z0-9.)]$'
typeset -ga _ZS_RISKS=(read-only mutating destructive privileged remote-code network)

# --- Messages ----------------------------------------------------------------

_zdx_surface_error() {
  print -u2 -r -- "$_zs_tool: $*"
}

_zdx_surface_problem() {
  (( _zs_problems++ ))
  print -u2 -r -- "surfaces: $*"
}

_zdx_surface_warning() {
  (( _zs_warnings++ ))
  print -u2 -r -- "surfaces: warning: $*"
}

# Prints "<count> <noun>" with the noun pluralized unless the count is one.
_zdx_surface_count() {
  if (( $1 == 1 )); then
    print -r -- "$1 $2"
  else
    print -r -- "$1 ${2}s"
  fi
}

_zdx_surface_usage() {
  print -u2 -r -- 'Usage:'
  print -u2 -r -- '  command-surface.zsh check [--strict] [SUITE...]'
  print -u2 -r -- '  command-surface.zsh new [--dry-run] [--after COMMAND]'
  print -u2 -r -- '      --label TEXT --description TEXT'
  print -u2 -r -- '      [--capability VALUE | --privilege VALUE | --owner VALUE]'
  print -u2 -r -- '      SUITE COMMAND MODULE RISK'
  print -u2 -r -- ''
  print -u2 -r -- 'check prints one row per public command and one per suite on stdout,'
  print -u2 -r -- 'names each missing surface with a file hint on stderr, and returns 1'
  print -u2 -r -- 'when a required surface is missing. A command absent from'
  print -u2 -r -- 'docs/user-guide.md is a warning; --strict makes warnings fail too.'
  print -u2 -r -- ''
  print -u2 -r -- 'new adds the fixture row, a function stub in MODULE, and, where the'
  print -u2 -r -- 'suite uses them, the dispatcher arm, menu record, --help entry,'
  print -u2 -r -- 'completion entry and binding, interactive allowlist entry, and lazy'
  print -u2 -r -- 'stub, each placed after the --after command (default: the last menu'
  print -u2 -r -- 'command of MODULE). It then prints the manual checklist. --dry-run'
  print -u2 -r -- 'prints the planned edits and writes nothing.'
}

# --- File and text primitives ------------------------------------------------

# reply: the lines of a file. Status 1 when the file cannot be read.
_zdx_surface_lines() {
  local file="$1" content=""
  reply=()
  [[ -f "$file" && -r "$file" ]] || return 1
  content="$(<"$file")" || return 1
  reply=("${(@f)content}")
}

# reply: the distinct kebab-case tokens of the text, such as `git-status`.
# tr splits the largest documents far faster than a Zsh substitution.
_zdx_surface_tokens() {
  local text="$1" output=""
  local -a words=()
  reply=()
  output=$(print -r -- "$text" | LC_ALL=C command tr -cs 'a-z0-9-' '\n') \
    || return 1
  words=(${(u)${(f)output}})
  words=("${(@)${(@)words##-##}%%-##}")
  reply=("${(@M)words:#[a-z][a-z0-9]#(-[a-z0-9]##)##}")
  return 0
}

# reply: start and end line of `NAME() {` ... `}` in the named line array.
_zdx_surface_region() {
  local array_name="$1" name="$2" line=""
  local -i index=0 start=0
  for line in "${(@P)array_name}"; do
    (( index++ ))
    if (( start == 0 )); then
      [[ "$line" == "${name}()"[[:space:]]#"{"* ]] && start=$index
    elif [[ "$line" == "}" ]]; then
      reply=($start $index)
      return 0
    fi
  done
  reply=()
  return 1
}

# Records the first located candidate function, searching the entrypoint and
# then the common file, as _ZS[<key>_which|_file|_start|_end|_name].
_zdx_surface_locate() {
  local key="$1" candidate="" which=""
  shift
  for candidate in "$@"; do
    for which in menu common; do
      _zdx_surface_region "_ZS_L_$which" "$candidate" || continue
      _ZS[${key}_which]="$which"
      _ZS[${key}_file]="${_ZS[$which]}"
      _ZS[${key}_start]="${reply[1]}"
      _ZS[${key}_end]="${reply[2]}"
      _ZS[${key}_name]="$candidate"
      return 0
    done
  done
  return 1
}

# Prints lines START..END of a line array, joined by newlines.
_zdx_surface_slice() {
  local array_name="$1"
  local -i start="$2" end="$3"
  local -a lines=("${(@P)array_name}")
  print -r -- "${(F)lines[start,end]}"
}

# reply: suite names that own a public-command fixture, sorted.
_zdx_surface_suites() {
  local fixture="" suite=""
  local -a found=()
  for fixture in "$_zs_root"/test/fixtures/*-public-commands.tsv(N.); do
    suite="${${fixture:t}%-public-commands.tsv}"
    [[ "$suite" =~ '^[a-z][a-z0-9]*$' ]] && found+=("$suite")
  done
  reply=("${(@o)found}")
}

# Path of a declared module: functions/<suite>/<module>, or the suite common
# or entrypoint file when the fixture names one of them.
_zdx_surface_module_path() {
  local suite="$1" module="$2"
  case "$module" in
    "$suite"-common.zsh|"$suite"-menu.zsh) REPLY="functions/$module" ;;
    *) REPLY="functions/$suite/$module" ;;
  esac
}

# --- Suite model -------------------------------------------------------------

_zdx_surface_reset() {
  _ZS=()
  _ZS_COLUMNS=() _ZS_COMMANDS=()
  _ZS_ROW_LINE=() _ZS_ROW_MODULE=() _ZS_ROW_VALUES=()
  _ZS_DEFS=() _ZS_ARMS=() _ZS_ROWS_COUNT=() _ZS_ROWS_LINE=()
  _ZS_HELP=() _ZS_COMP=() _ZS_BIND=() _ZS_LAZY=() _ZS_ALLOW=() _ZS_DOC=()
  _ZS_L_menu=() _ZS_L_common=() _ZS_L_comp=() _ZS_L_lazy=()
}

# Parses the fixture. Every existing layout is supported: a `# command ...`
# header naming tab-separated columns, or the header-less File layout of a
# command and its description.
_zdx_surface_load_fixture() {
  local suite="$1" rel="test/fixtures/${1}-public-commands.tsv"
  local line="" header="" command_name="" column=""
  local -a fields=()
  local -i number=0 index=0
  _ZS[fixture]="$rel"
  _zdx_surface_lines "$_zs_root/$rel" || {
    _zdx_surface_problem "$suite: cannot read $rel"
    return 1
  }
  for line in "${reply[@]}"; do
    (( number++ ))
    [[ -n "$line" ]] || continue
    if [[ "$line" == '#'* ]]; then
      if (( ${#_ZS_COLUMNS} == 0 )); then
        header="${line#\#}"
        for column in "${(@ps:\t:)header}"; do
          _ZS_COLUMNS+=("${${column##[[:space:]]#}%%[[:space:]]#}")
        done
      fi
      continue
    fi
    fields=("${(@ps:\t:)line}")
    command_name="${fields[1]}"
    if [[ ! "$command_name" =~ '^[a-z][a-z0-9]*(-[a-z0-9]+)+$' ]]; then
      _zdx_surface_problem "$suite: invalid command name ${(qqq)${(V)command_name}} ($rel:$number)"
      continue
    fi
    if (( ${+_ZS_ROW_LINE[$command_name]} )); then
      _zdx_surface_problem "$suite/$command_name: duplicate fixture row ($rel:$number)"
      continue
    fi
    _ZS_COMMANDS+=("$command_name")
    _ZS_ROW_LINE[$command_name]=$number
    _ZS_ROW_VALUES[$command_name]="$line"
  done
  (( ${#_ZS_COLUMNS} )) || _ZS_COLUMNS=(command description)
  index=${_ZS_COLUMNS[(Ie)module]}
  if (( index )); then
    for command_name in "${_ZS_COMMANDS[@]}"; do
      fields=("${(@ps:\t:)_ZS_ROW_VALUES[$command_name]}")
      _ZS_ROW_MODULE[$command_name]="${fields[index]}"
    done
  fi
  return 0
}

# Loads every surface of one suite into the _ZS* globals.
_zdx_surface_load_suite() {
  local suite="$1" rel="" line="" name="" token="" text="" file="" array_name=""
  local -a sources=()
  local -A block=()
  local -i index=0 start=0 block_start=0
  _zdx_surface_reset
  _ZS[suite]="$suite"
  _ZS[menu]="functions/${suite}-menu.zsh"
  _ZS[common]="functions/${suite}-common.zsh"
  _ZS[comp]="completions/_${suite}-menu"
  _ZS[doc]="docs/${suite}-menu.md"
  _ZS[contract]="test/${suite}_contract.bats"
  _ZS[bind_direct]=0
  _ZS[lazy_direct]=0
  _zdx_surface_load_fixture "$suite" || return 1

  _zdx_surface_lines "$_zs_root/${_ZS[menu]}" && _ZS_L_menu=("${reply[@]}")
  _zdx_surface_lines "$_zs_root/${_ZS[common]}" && _ZS_L_common=("${reply[@]}")
  _zdx_surface_lines "$_zs_root/${_ZS[comp]}" && _ZS_L_comp=("${reply[@]}")
  _zdx_surface_lines "$_zs_root/functions.zsh" && _ZS_L_lazy=("${reply[@]}")

  # Public kebab-case definitions in every suite source file.
  sources=("${_ZS[menu]}" "${_ZS[common]}")
  for file in "$_zs_root"/functions/"$suite"/*.zsh(N.); do
    sources+=("functions/$suite/${file:t}")
  done
  # A filter keeps the scan of large modules cheap; few lines are candidates.
  local -a source_lines=() candidates=()
  for rel in "${sources[@]}"; do
    _zdx_surface_lines "$_zs_root/$rel" || continue
    source_lines=("${reply[@]}")
    candidates=("${(@M)source_lines:#[a-z][a-z0-9]#-[a-z0-9-]##\(\)[[:space:]]#\{*}")
    for line in "${candidates[@]}"; do
      [[ "$line" =~ '^([a-z][a-z0-9]*(-[a-z0-9]+)+)\(\)[[:space:]]*\{' ]] || continue
      name="${match[1]}"
      index=${source_lines[(ie)$line]}
      _ZS_DEFS[$name]+="${_ZS_DEFS[$name]:+ }$rel:$index"
    done
  done

  # Dispatcher arms: `name)` or `a|b)` at the start of a line.
  if _zdx_surface_locate dispatch "_${suite}_dispatch"; then
    array_name="_ZS_L_${_ZS[dispatch_which]}"
    index=0
    for line in "${(@P)array_name}"; do
      (( index++ ))
      (( index > ${_ZS[dispatch_start]} && index < ${_ZS[dispatch_end]} )) || continue
      [[ "$line" =~ '^[[:space:]]*([a-z][a-z0-9-]*(\|[a-z][a-z0-9-]*)*)\)' ]] \
        || continue
      for name in "${(@s:|:)match[1]}"; do
        _ZS_ARMS[$name]=$index
      done
    done
  fi

  # Menu records: quoted kebab tokens inside the row builder.
  if _zdx_surface_locate rows "_${suite}_menu_rows_build" "_${suite}_menu_rows"; then
    array_name="_ZS_L_${_ZS[rows_which]}"
    index=0
    for line in "${(@P)array_name}"; do
      (( index++ ))
      (( index > ${_ZS[rows_start]} && index < ${_ZS[rows_end]} )) || continue
      while [[ "$line" =~ '"([a-z][a-z0-9]*(-[a-z0-9]+)+)"' ]]; do
        token="${match[1]}"
        _ZS_ROWS_COUNT[$token]=$(( ${_ZS_ROWS_COUNT[$token]:-0} + 1 ))
        (( ${+_ZS_ROWS_LINE[$token]} )) || _ZS_ROWS_LINE[$token]=$index
        line="${line[MEND+1,-1]}"
      done
    done
  fi

  # Help: every kebab token of the usage function.
  if _zdx_surface_locate usage "_${suite}_usage" "_${suite}_menu_usage"; then
    text=$(_zdx_surface_slice "_ZS_L_${_ZS[usage_which]}" \
      "${_ZS[usage_start]}" "${_ZS[usage_end]}")
    _zdx_surface_tokens "$text"
    for token in "${reply[@]}"; do _ZS_HELP[$token]=1; done
  fi

  # Optional interactive allowlist, such as _py_command_is_canonical.
  if _zdx_surface_locate allow "_${suite}_command_is_canonical"; then
    text=$(_zdx_surface_slice "_ZS_L_${_ZS[allow_which]}" \
      "${_ZS[allow_start]}" "${_ZS[allow_end]}")
    _zdx_surface_tokens "$text"
    for token in "${reply[@]}"; do _ZS_ALLOW[$token]=1; done
  fi

  # Completion: the #compdef binding, and the first command array that lists
  # a fixture command.
  if (( ${#_ZS_L_comp} )) && [[ "${_ZS_L_comp[1]}" == '#compdef '* ]]; then
    for name in ${=${_ZS_L_comp[1]#\#compdef }}; do
      _ZS_BIND[$name]=1
    done
  fi
  index=0
  for line in "${_ZS_L_comp[@]}"; do
    (( index++ ))
    if (( block_start == 0 )); then
      if [[ "$line" =~ '^[[:space:]]*([a-z_][a-z0-9_]*)=\($' ]]; then
        block_start=$index
        _ZS[comp_candidate]="${match[1]}"
        block=()
      fi
      continue
    fi
    if [[ "$line" =~ "^[[:space:]]*'([a-z][a-z0-9-]*):" ]]; then
      block[${match[1]}]=$index
      continue
    fi
    [[ "$line" =~ '^[[:space:]]*\)$' ]] || continue
    for name in "${_ZS_COMMANDS[@]}"; do
      (( ${+block[$name]} )) || continue
      _ZS_COMP=("${(@kv)block}")
      _ZS[comp_array]="${_ZS[comp_candidate]}"
      _ZS[comp_start]=$block_start
      _ZS[comp_end]=$index
      break 2
    done
    block_start=0
  done

  # Lazy registration: `name <suite>-menu.zsh` rows of _ZDX_LAZY_FILES.
  index=0
  for line in "${_ZS_L_lazy[@]}"; do
    (( index++ ))
    if (( start == 0 )); then
      [[ "$line" == *'typeset -gA _ZDX_LAZY_FILES=(' ]] && start=$index
      continue
    fi
    [[ "$line" =~ '^[[:space:]]*\)$' ]] && break
    [[ "$line" =~ '^[[:space:]]+([a-z0-9-]+)[[:space:]]+([a-z0-9-]+\.zsh)$' ]] \
      || continue
    [[ "${match[2]}" == "${suite}-menu.zsh" ]] || continue
    if [[ "${match[1]}" == "${suite}-menu" ]]; then
      _ZS[lazy_entry]=$index
    else
      _ZS_LAZY[${match[1]}]=$index
    fi
  done
  _ZS[lazy_start]=$start

  # A suite binds or lazily registers its direct commands when it does so for
  # at least one fixture command; then every command must follow.
  for name in "${_ZS_COMMANDS[@]}"; do
    (( ${+_ZS_BIND[$name]} )) && _ZS[bind_direct]=1
    (( ${+_ZS_LAZY[$name]} )) && _ZS[lazy_direct]=1
  done

  if [[ -f "$_zs_root/${_ZS[doc]}" && -r "$_zs_root/${_ZS[doc]}" ]]; then
    text="$(<"$_zs_root/${_ZS[doc]}")"
    _zdx_surface_tokens "$text"
    for token in "${reply[@]}"; do _ZS_DOC[$token]=1; done
  fi

  # The frozen count asserted by the contract test, when it states one.
  _ZS[count]=""
  _ZS[count_line]=""
  if _zdx_surface_lines "$_zs_root/${_ZS[contract]}"; then
    index=0
    for line in "${reply[@]}"; do
      (( index++ ))
      if [[ "$line" =~ '\[ "\$count" -eq ([0-9]+) \]' \
        || "$line" =~ 'NR == ([0-9]+)' ]]; then
        _ZS[count]="${match[1]}"
        _ZS[count_line]=$index
        break
      fi
    done
  fi
  return 0
}

# Loads the user guide and the master router facts shared by every suite.
_zdx_surface_load_shared() {
  local text="" token="" line="" name="" rest=""
  local -i in_router=0
  _ZS_GUIDE=() _ZS_ROUTER=() _ZS_MASTER=() _ZS_ZDXCOMP=()
  if [[ -f "$_zs_root/docs/user-guide.md" && -r "$_zs_root/docs/user-guide.md" ]]; then
    text="$(<"$_zs_root/docs/user-guide.md")"
    _zdx_surface_tokens "$text"
    for token in "${reply[@]}"; do _ZS_GUIDE[$token]=1; done
  fi
  if _zdx_surface_lines "$_zs_root/functions/zdx-common.zsh"; then
    for line in "${reply[@]}"; do
      if [[ "$line" == '_zdx_dispatch_suite() {' ]]; then
        in_router=1
        continue
      fi
      if (( in_router )); then
        if [[ "$line" == '}' ]]; then
          in_router=0
        elif [[ "$line" =~ '^[[:space:]]*([a-z][a-z0-9]*)\)' ]]; then
          _ZS_ROUTER[${match[1]}]=1
        fi
        continue
      fi
      # Master records: $'entry\t<label>\t<route>\t<description>'
      [[ "$line" == *"\$'entry\\t"* ]] || continue
      rest="${line#*entry\\t}"
      rest="${rest#*\\t}"
      _ZS_MASTER[${rest%%\\t*}]=1
    done
  fi
  if _zdx_surface_lines "$_zs_root/completions/_zdx-menu"; then
    for line in "${reply[@]}"; do
      if [[ "$line" =~ "^[[:space:]]*'([a-z][a-z0-9]*):" ]]; then
        name="${match[1]}"
        _ZS_ZDXCOMP[$name]=$(( ${_ZS_ZDXCOMP[$name]:-0} | 1 ))
      elif [[ "$line" =~ '^[[:space:]]*([a-z][a-z0-9]*(\|[a-z][a-z0-9]*)+)\)$' ]]; then
        for name in "${(@s:|:)match[1]}"; do
          _ZS_ZDXCOMP[$name]=$(( ${_ZS_ZDXCOMP[$name]:-0} | 2 ))
        done
      fi
    done
  fi
}

# --- check -------------------------------------------------------------------

# REPLY: "<function> (<file>:<line>)" for a located region, or the fallback.
_zdx_surface_where() {
  local key="$1" fallback="$2"
  if [[ -n "${_ZS[${key}_file]:-}" ]]; then
    REPLY="${_ZS[${key}_name]} (${_ZS[${key}_file]}:${_ZS[${key}_start]})"
  else
    REPLY="$fallback"
  fi
}

# Evaluates one command: prints its table row on stdout and reports each
# missing surface on stderr.
_zdx_surface_check_command() {
  local suite="${_ZS[suite]}" command_name="$1" module="" defs="" expected=""
  local label="$suite/$command_name"
  local -a marks=()

  module="${_ZS_ROW_MODULE[$command_name]:-}"
  defs="${_ZS_DEFS[$command_name]:-}"
  expected="functions/$suite/"
  if [[ -n "$module" ]]; then
    _zdx_surface_module_path "$suite" "$module"
    expected="$REPLY"
  fi
  if [[ -z "$defs" ]]; then
    _zdx_surface_problem "$label: no public function '$command_name() {' ($expected)"
    marks+=(MISS)
  elif [[ "$defs" == *' '* ]]; then
    _zdx_surface_problem "$label: defined more than once: $defs"
    marks+=(MISS)
  elif [[ -n "$module" && "${defs%:*}" != "$expected" ]]; then
    _zdx_surface_problem "$label: defined in $defs, but the fixture declares $module (${_ZS[fixture]}:${_ZS_ROW_LINE[$command_name]})"
    marks+=(MISS)
  else
    marks+=(ok)
  fi

  if (( ${+_ZS_ARMS[$command_name]} )); then
    marks+=(ok)
  else
    _zdx_surface_where dispatch "_${suite}_dispatch (not found)"
    _zdx_surface_problem "$label: no dispatcher arm in $REPLY"
    marks+=(MISS)
  fi

  if (( ${_ZS_ROWS_COUNT[$command_name]:-0} > 0 )); then
    marks+=(ok)
  else
    _zdx_surface_where rows "the $suite menu row builder (not found)"
    _zdx_surface_problem "$label: no menu record in $REPLY"
    marks+=(MISS)
  fi

  if (( ${+_ZS_HELP[$command_name]} )); then
    marks+=(ok)
  else
    _zdx_surface_where usage "the $suite usage function (not found)"
    _zdx_surface_problem "$label: not listed by --help in $REPLY"
    marks+=(MISS)
  fi

  if (( ${+_ZS_COMP[$command_name]} )); then
    marks+=(ok)
  elif [[ -n "${_ZS[comp_array]:-}" ]]; then
    _zdx_surface_problem "$label: no completion entry in ${_ZS[comp_array]} (${_ZS[comp]}:${_ZS[comp_start]})"
    marks+=(MISS)
  else
    _zdx_surface_problem "$label: no completion entry (${_ZS[comp]})"
    marks+=(MISS)
  fi

  if [[ "${_ZS[bind_direct]}" != 1 ]]; then
    marks+=(-)
  elif (( ${+_ZS_BIND[$command_name]} )); then
    marks+=(ok)
  else
    _zdx_surface_problem "$label: not bound by the #compdef line (${_ZS[comp]}:1)"
    marks+=(MISS)
  fi

  if [[ "${_ZS[lazy_direct]}" != 1 ]]; then
    marks+=(-)
  elif (( ${+_ZS_LAZY[$command_name]} )); then
    marks+=(ok)
  else
    _zdx_surface_problem "$label: no lazy stub in _ZDX_LAZY_FILES (functions.zsh:${_ZS[lazy_start]})"
    marks+=(MISS)
  fi

  if [[ -z "${_ZS[allow_file]:-}" ]]; then
    marks+=(-)
  elif (( ${+_ZS_ALLOW[$command_name]} )); then
    marks+=(ok)
  else
    _zdx_surface_where allow ""
    _zdx_surface_problem "$label: missing from the interactive allowlist $REPLY"
    marks+=(MISS)
  fi

  if (( ${+_ZS_DOC[$command_name]} )); then
    marks+=(ok)
  else
    _zdx_surface_problem "$label: not documented in ${_ZS[doc]}"
    marks+=(MISS)
  fi

  if (( ${+_ZS_GUIDE[$command_name]} )); then
    marks+=(ok)
  else
    _zdx_surface_warning "$label: not mentioned in docs/user-guide.md"
    marks+=(warn)
  fi

  printf "%-${_ZS[suite_width]}s  %-${_ZS[command_width]}s  %-4s  %-4s  %-4s  %-4s  %-4s  %-4s  %-4s  %-5s  %-4s  %s\n" \
    "$suite" "$command_name" "${marks[@]}"
}

# Reports surface entries that name no fixture command, the suite-level
# registrations, and the frozen contract count. The suite's table row is
# appended to _ZS_SUITE_ROWS.
_zdx_surface_check_suite() {
  local suite="${_ZS[suite]}" name=""
  local -A known=()
  local -a marks=()
  for name in "${_ZS_COMMANDS[@]}"; do known[$name]=1; done

  for name in "${(@ok)_ZS_ARMS}"; do
    (( ${+known[$name]} )) && continue
    _zdx_surface_problem "$suite/$name: dispatcher arm without a fixture row (${_ZS[dispatch_file]}:${_ZS_ARMS[$name]})"
  done
  for name in "${(@ok)_ZS_COMP}"; do
    (( ${+known[$name]} )) && continue
    _zdx_surface_problem "$suite/$name: completion entry without a fixture row (${_ZS[comp]}:${_ZS_COMP[$name]})"
  done
  if [[ "${_ZS[bind_direct]}" == 1 ]]; then
    for name in "${(@ok)_ZS_BIND}"; do
      [[ "$name" == "${suite}-menu" ]] && continue
      (( ${+known[$name]} )) && continue
      _zdx_surface_problem "$suite/$name: #compdef binding without a fixture row (${_ZS[comp]}:1)"
    done
  fi
  for name in "${(@ok)_ZS_LAZY}"; do
    (( ${+known[$name]} )) && continue
    _zdx_surface_problem "$suite/$name: lazy stub without a fixture row (functions.zsh:${_ZS_LAZY[$name]})"
  done
  for name in "${(@ok)_ZS_DEFS}"; do
    [[ "$name" == "${suite}-menu" ]] && continue
    (( ${+known[$name]} )) && continue
    _zdx_surface_problem "$suite/$name: public function without a fixture row (${_ZS_DEFS[$name]})"
  done

  if [[ "${_ZS_DEFS[${suite}-menu]:-}" == "${_ZS[menu]}:"* ]]; then
    marks+=(ok)
  else
    marks+=(MISS)
    _zdx_surface_problem "$suite: no ${suite}-menu() entrypoint in ${_ZS[menu]}"
  fi
  if [[ -n "${_ZS[lazy_entry]:-}" ]]; then
    marks+=(ok)
  else
    marks+=(MISS)
    _zdx_surface_problem "$suite: ${suite}-menu has no lazy stub in _ZDX_LAZY_FILES (functions.zsh)"
  fi
  if (( ${+_ZS_ROUTER[$suite]} )); then
    marks+=(ok)
  else
    marks+=(MISS)
    _zdx_surface_problem "$suite: no '$suite)' arm in _zdx_dispatch_suite (functions/zdx-common.zsh)"
  fi
  if (( ${+_ZS_MASTER[$suite]} )); then
    marks+=(ok)
  else
    marks+=(MISS)
    _zdx_surface_problem "$suite: no master-menu entry routed to '$suite' in _zdx_menu_model (functions/zdx-common.zsh)"
  fi
  if (( ${_ZS_ZDXCOMP[$suite]:-0} == 3 )); then
    marks+=(ok)
  else
    marks+=(MISS)
    _zdx_surface_problem "$suite: 'zdx $suite' completion needs the '$suite:' entry and the nested-menu case arm (completions/_zdx-menu)"
  fi
  if [[ -z "${_ZS[count]}" ]]; then
    marks+=(-)
  elif (( ${_ZS[count]} == ${#_ZS_COMMANDS} )); then
    marks+=(ok)
  else
    marks+=(MISS)
    _zdx_surface_problem "$suite: ${_ZS[contract]}:${_ZS[count_line]} freezes ${_ZS[count]} commands; the fixture has ${#_ZS_COMMANDS}"
  fi
  _ZS_SUITE_ROWS+=("$(printf '%-6s  %8d  %-5s  %-4s  %-6s  %-6s  %-7s  %s' \
    "$suite" "${#_ZS_COMMANDS}" "${marks[@]}")")
}

_zdx_surface_check_main() {
  local -i strict=0 total=0 suite_width=5 command_width=7
  local suite="" name="" row=""
  local -a requested=() suites=()
  while (( $# )); do
    case "$1" in
      --strict) strict=1 ;;
      -h|--help) _zdx_surface_usage; return 0 ;;
      --) shift; requested+=("$@"); break ;;
      -*) _zdx_surface_error "unknown option: ${(V)1}"; return 2 ;;
      *) requested+=("$1") ;;
    esac
    shift
  done
  _zdx_surface_suites
  suites=("${reply[@]}")
  (( ${#suites} )) || {
    _zdx_surface_error "no test/fixtures/<suite>-public-commands.tsv found"
    return 1
  }
  if (( ${#requested} )); then
    for suite in "${requested[@]}"; do
      (( ${suites[(Ie)$suite]} )) || {
        _zdx_surface_error "unknown suite ${(qqq)${(V)suite}}; known suites: ${(j:, :)suites}"
        return 2
      }
    done
    suites=("${(@u)requested}")
  fi

  _zdx_surface_load_shared
  for suite in "${suites[@]}"; do
    (( ${#suite} > suite_width )) && suite_width=${#suite}
    _zdx_surface_lines "$_zs_root/test/fixtures/${suite}-public-commands.tsv" || continue
    for name in "${reply[@]}"; do
      [[ "$name" == '#'* ]] && continue
      name="${name%%$'\t'*}"
      (( ${#name} > command_width )) && command_width=${#name}
    done
  done
  printf "%-${suite_width}s  %-${command_width}s  %-4s  %-4s  %-4s  %-4s  %-4s  %-4s  %-4s  %-5s  %-4s  %s\n" \
    SUITE COMMAND FN DISP MENU HELP COMP BIND LAZY ALLOW DOC GUIDE
  _ZS_SUITE_ROWS=()
  for suite in "${suites[@]}"; do
    _zdx_surface_load_suite "$suite" || continue
    _ZS[suite_width]=$suite_width
    _ZS[command_width]=$command_width
    for name in "${_ZS_COMMANDS[@]}"; do
      _zdx_surface_check_command "$name"
      (( total++ ))
    done
    _zdx_surface_check_suite
  done
  print -r --
  printf '%-6s  %8s  %-5s  %-4s  %-6s  %-6s  %-7s  %s\n' \
    SUITE COMMANDS ENTRY LAZY ROUTER MASTER ZDXCOMP COUNT
  for row in "${_ZS_SUITE_ROWS[@]}"; do
    print -r -- "$row"
  done
  print -u2 -r -- "surfaces: $(_zdx_surface_count "$total" command) in $(_zdx_surface_count ${#suites} suite); $(_zdx_surface_count $_zs_problems problem), $(_zdx_surface_count $_zs_warnings warning)."
  (( _zs_problems == 0 )) || return 1
  (( strict && _zs_warnings > 0 )) && return 1
  return 0
}

# --- new: validation ---------------------------------------------------------

# Reads the fixture validators of the suite contract test, such as
# `[[ "$risk" =~ ^(read-only|mutating)$ ]]`, into _ZS_RULE[<column>] as
# `re:<ERE>` or `eq:<literal>`. The new row must pass the same checks.
_zdx_surface_contract_rules() {
  local line="" joined="" variable="" rule=""
  local -a lines=() variables=()
  local -i index=0 position=0 collecting=0
  _ZS_RULE=()
  _zdx_surface_lines "$_zs_root/${_ZS[contract]}" || return 0
  lines=("${reply[@]}")
  for line in "${lines[@]}"; do
    (( index++ ))
    if (( collecting )); then
      joined+=" $line"
    elif [[ "$line" == *IFS=*'read -r'* ]]; then
      joined="${line#*read -r}"
      collecting=1
    else
      continue
    fi
    if [[ "$joined" == *'; do'* ]]; then
      joined="${joined%%; do*}"
      variables=(${=${joined//\\/ }})
      break
    fi
  done
  (( ${#variables} )) || return 0
  for line in "${(@)lines[index+1,-1]}"; do
    [[ "$line" =~ '^[[:space:]]*done([[:space:]]|$)' ]] && break
    if [[ "$line" =~ '^[[:space:]]*\[\[ "\$([a-z_]+)" =~ ([^ ]+) \]\]$' ]]; then
      variable="${match[1]}"
      rule="re:${match[2]}"
    elif [[ "$line" =~ '^[[:space:]]*\[\[ "\$([a-z_]+)" == "([a-z0-9-]*)" \]\]$' ]]; then
      variable="${match[1]}"
      rule="eq:${match[2]}"
    else
      continue
    fi
    position=${variables[(Ie)$variable]}
    (( position >= 1 && position <= ${#_ZS_COLUMNS} )) || continue
    _ZS_RULE[${_ZS_COLUMNS[position]}]="$rule"
  done
}

# Status 0 when VALUE satisfies the contract rule of COLUMN (or there is none).
_zdx_surface_rule_accepts() {
  local column="$1" value="$2" rule="${_ZS_RULE[$1]:-}"
  case "$rule" in
    "") return 0 ;;
    re:*) [[ "$value" =~ "${rule#re:}" ]] ;;
    eq:*) [[ "$value" == "${rule#eq:}" ]] ;;
    *) return 1 ;;
  esac
}

# Status 0 when the command name already exists anywhere in the runtime: a
# fixture row, a function definition, a lazy stub, or a completion entry or
# binding. REPLY names the first place found.
_zdx_surface_name_taken() {
  local name="$1" file="" content="" fixture="" line=""
  REPLY=""
  for fixture in "$_zs_root"/test/fixtures/*-public-commands.tsv(N.); do
    _zdx_surface_lines "$fixture" || continue
    for line in "${reply[@]}"; do
      [[ "${line%%$'\t'*}" == "$name" ]] || continue
      REPLY="${fixture#$_zs_root/}"
      return 0
    done
  done
  for file in "$_zs_root"/functions.zsh(N.) "$_zs_root"/functions/**/*.zsh(N.); do
    content=$'\n'"$(<"$file")"
    [[ "$content" == *$'\n'"${name}()"[[:space:]]#"{"* ]] || continue
    REPLY="${file#$_zs_root/}"
    return 0
  done
  for line in "${_ZS_L_lazy[@]}"; do
    [[ "$line" =~ "^[[:space:]]+${name}[[:space:]]+[a-z0-9-]+\\.zsh\$" ]] || continue
    REPLY="functions.zsh"
    return 0
  done
  for file in "$_zs_root"/completions/_*(N.); do
    content="$(<"$file")"
    if [[ "$content" == *"'${name}:"* \
      || " ${${(f)content}[1]} " == *" ${name} "* ]]; then
      REPLY="${file#$_zs_root/}"
      return 0
    fi
  done
  return 1
}

# --- new: edit planning ------------------------------------------------------

# Records one edit. TEXT may span lines.
_zdx_surface_edit() {
  _ZS_EDIT_FILE+=("$1")
  _ZS_EDIT_KIND+=("$2")
  _ZS_EDIT_LINE+=("$3")
  _ZS_EDIT_SURFACE+=("$4")
  _ZS_EDIT_TEXT+=("$5")
}

# Loads a file's unedited content once for planning and rendering.
_zdx_surface_original() {
  local rel="$1"
  (( ${+_ZS_ORIG[$rel]} )) && return 0
  [[ -f "$_zs_root/$rel" && -r "$_zs_root/$rel" ]] || return 1
  _ZS_ORIG[$rel]="$(<"$_zs_root/$rel")"
}

_zdx_surface_refuse() {
  _zdx_surface_error "$*"
  return 1
}

_zdx_surface_plan_fixture() {
  local rel="${_ZS[fixture]}" column="" candidate="" after_line=""
  local -a values=() sorted=()
  local LC_ALL=C
  for column in "${_ZS_COLUMNS[@]}"; do
    case "$column" in
      command) values+=("$_ZS_NEW_COMMAND") ;;
      module) values+=("$_ZS_NEW_MODULE") ;;
      risk) values+=("$_ZS_NEW_RISK") ;;
      description) values+=("$_ZS_NEW_SUMMARY") ;;
      *) values+=("${_ZS_VALUE[$column]}") ;;
    esac
  done
  # A sorted fixture stays sorted; another order keeps the new row next to
  # its anchor.
  sorted=("${(@o)_ZS_COMMANDS}")
  if [[ "${(j: :)sorted}" == "${(j: :)_ZS_COMMANDS}" ]]; then
    after_line="${_ZS_ROW_LINE[${_ZS_COMMANDS[-1]}]}"
    for candidate in "${_ZS_COMMANDS[@]}"; do
      if [[ "$candidate" > "$_ZS_NEW_COMMAND" ]]; then
        after_line=$(( ${_ZS_ROW_LINE[$candidate]} - 1 ))
        break
      fi
    done
  else
    after_line="${_ZS_ROW_LINE[$_ZS_NEW_ANCHOR]}"
  fi
  _zdx_surface_original "$rel" || return 1
  _zdx_surface_edit "$rel" after "$after_line" "fixture row" "${(pj:\t:)values}"
}

_zdx_surface_plan_stub() {
  local suite="${_ZS[suite]}" rel="" usage_name="" error_name="" text=""
  local -a lines=() stub=()
  local -i last=0
  _zdx_surface_module_path "$suite" "$_ZS_NEW_MODULE"
  rel="$REPLY"
  _zdx_surface_original "$rel" || return 1
  lines=("${(@f)_ZS_ORIG[$rel]}")
  for (( last = ${#lines}; last > 0; last-- )); do
    [[ -n "${lines[last]}" ]] && break
  done
  [[ "${lines[last]:-}" =~ '^typeset -g _[A-Z0-9_]+_SOURCED=1$' ]] \
    || _zdx_surface_refuse "$rel does not end with its typeset -g _..._SOURCED=1 sentinel; cannot place the stub" \
    || return 1
  usage_name="$_ZS_NEW_USAGE"
  error_name="_${suite}_error"
  stub=(
    "# $_ZS_NEW_COMMAND"
    "#   Arguments: --help only."
    "#   stdout:    none."
    "#   Effects:   $_ZS_NEW_RISK; not implemented yet."
    "#   Status:    0 help; 1 not implemented; 2 invalid arguments."
    "${usage_name}() {"
    "  print -u2 -r -- \"Usage: $_ZS_NEW_COMMAND [-h|--help]\""
    "  print -u2 -r -- \"$_ZS_NEW_SENTENCE\""
    "}"
    ""
    "${_ZS_NEW_COMMAND}() {"
    "  emulate -L zsh"
    ""
    '  case "${1:-}" in'
    "    -h|--help)"
    '      (( $# == 1 )) || {'
    "        $error_name \"--help accepts no additional arguments.\""
    "        return 2"
    "      }"
    "      $usage_name"
    "      return 0"
    "      ;;"
    "  esac"
    '  (( $# == 0 )) || {'
    "    $error_name \"$_ZS_NEW_COMMAND accepts no arguments.\""
    "    return 2"
    "  }"
    ""
    "  $error_name \"$_ZS_NEW_COMMAND is not implemented yet.\""
    "  return 1"
    "}"
  )
  if [[ -z "${lines[last-1]:-}" ]]; then
    text="${(F)stub}"$'\n'
  else
    text=$'\n'"${(F)stub}"$'\n'
  fi
  _zdx_surface_edit "$rel" after $(( last - 1 )) "function stub" "$text"
}

_zdx_surface_plan_dispatch() {
  local anchor="$_ZS_NEW_ANCHOR" new="$_ZS_NEW_COMMAND"
  local rel="${_ZS[dispatch_file]:-}" array_name="" first="" second="" third=""
  local indent="" pad="" prepare="" body="" text=""
  local -i arm=0 end=0 column=0 width=0
  [[ -n "$rel" ]] || _zdx_surface_refuse "no _${_ZS[suite]}_dispatch function found" || return 1
  (( ${+_ZS_ARMS[$anchor]} )) \
    || _zdx_surface_refuse "$anchor has no dispatcher arm to follow in ${_ZS[dispatch_name]} ($rel)" \
    || return 1
  array_name="_ZS_L_${_ZS[dispatch_which]}"
  local -a lines=("${(@P)array_name}")
  arm=${_ZS_ARMS[$anchor]}
  for (( end = arm; end < ${_ZS[dispatch_end]}; end++ )); do
    [[ "${lines[end]}" == *';;' ]] && break
  done
  first="${lines[arm]}"
  second="${lines[arm+1]:-}"
  third="${lines[arm+2]:-}"
  if (( end == arm )) \
    && [[ "$first" =~ "^([[:space:]]+)${anchor}\\)([[:space:]]+)${anchor} \"\\\$@\" ;;\$" ]]; then
    indent="${match[1]}"
    pad="${match[2]}"
    width=1
    # Aligned arms share one body column; the longest arm has a single space.
    local -i aligned=0 index=0
    for (( index = ${_ZS[dispatch_start]} + 1; index < ${_ZS[dispatch_end]}; index++ )); do
      [[ "${lines[index]}" =~ '^[[:space:]]+[a-z][a-z0-9-]*\)[[:space:]][[:space:]]+[a-z]' ]] \
        && aligned=1 && break
    done
    if (( aligned )); then
      column=$(( ${#indent} + ${#anchor} + 1 + ${#pad} ))
      width=$(( column - ${#indent} - ${#new} - 1 ))
      (( width < 1 )) && width=1
    fi
    text="${indent}${new})${(l:width:: :)}${new} \"\$@\" ;;"
  elif (( end == arm + 1 )) && [[ "$first" =~ "^([[:space:]]+)${anchor}\\)\$" ]]; then
    indent="${match[1]}"
    if [[ "$second" =~ "^([[:space:]]+)${anchor} \"\\\$@\" ;;\$" ]]; then
      text="${indent}${new})"$'\n'"${match[1]}${new} \"\$@\" ;;"
    elif [[ "$second" =~ "^([[:space:]]+)(_[a-z0-9_]+_dispatch_prepare) \"\\\$command_name\" \"\\\$@\" && ${anchor} \"\\\$@\" ;;\$" ]]; then
      prepare="${match[2]}"
      body="${match[1]}${prepare} \"\$command_name\" \"\$@\" && ${new} \"\$@\" ;;"
      if (( ${#body} > 80 )); then
        body="${match[1]}${prepare} \"\$command_name\" \"\$@\" \\"$'\n'"${match[1]}  && ${new} \"\$@\" ;;"
      fi
      text="${indent}${new})"$'\n'"$body"
    fi
  elif (( end == arm + 2 )) && [[ "$first" =~ "^([[:space:]]+)${anchor}\\)\$" ]]; then
    indent="${match[1]}"
    if [[ "$second" =~ '^([[:space:]]+)(_[a-z0-9_]+_dispatch_prepare) "\$command_name" "\$@" \\$' ]]; then
      prepare="${match[2]}"
      body="${match[1]}${prepare} \"\$command_name\" \"\$@\""
      if [[ "$third" =~ "^[[:space:]]+&& ${anchor} \"\\\$@\" ;;\$" ]]; then
        if (( ${#body} + ${#new} + 12 > 80 )); then
          text="${indent}${new})"$'\n'"${body} \\"$'\n'"${body%%[^[:space:]]*}  && ${new} \"\$@\" ;;"
        else
          text="${indent}${new})"$'\n'"${body} && ${new} \"\$@\" ;;"
        fi
      fi
    fi
  fi
  [[ -n "$text" ]] \
    || _zdx_surface_refuse "the dispatcher arm of $anchor ($rel:$arm) has an unrecognized shape; add the arm by hand or choose another --after command" \
    || return 1
  _zdx_surface_original "$rel" || return 1
  _zdx_surface_edit "$rel" after "$end" "dispatcher arm" "$text"
}

_zdx_surface_plan_menu() {
  local anchor="$_ZS_NEW_ANCHOR" new="$_ZS_NEW_COMMAND"
  local rel="${_ZS[rows_file]:-}" array_name="" indent="" entry_function=""
  local label_line="" closing="" text=""
  local -i at=0 start=0 end=0 rowvar=0 index=0
  [[ -n "$rel" ]] || _zdx_surface_refuse "no _${_ZS[suite]}_menu_rows function found" || return 1
  case "${_ZS_ROWS_COUNT[$anchor]:-0}" in
    1) ;;
    0) _zdx_surface_refuse "$anchor has no menu record in ${_ZS[rows_name]} ($rel); choose another --after command"
       return 1 ;;
    *) _zdx_surface_refuse "$anchor appears ${_ZS_ROWS_COUNT[$anchor]} times in ${_ZS[rows_name]} ($rel); choose another --after command"
       return 1 ;;
  esac
  array_name="_ZS_L_${_ZS[rows_which]}"
  local -a lines=("${(@P)array_name}")
  at=${_ZS_ROWS_LINE[$anchor]}
  for (( index = at; index >= at - 4 && index > ${_ZS[rows_start]}; index-- )); do
    if [[ "${lines[index]}" =~ '^([[:space:]]*)(row=\$\()?(_[a-z0-9_]+_menu_entry)([[:space:]]|$)' ]]; then
      start=$index
      indent="${match[1]}"
      [[ -n "${match[2]}" ]] && rowvar=1
      entry_function="${match[3]}"
      break
    fi
  done
  for (( index = at; start && index <= at + 6 && index < ${_ZS[rows_end]}; index++ )); do
    if (( rowvar )); then
      [[ "${lines[index]}" =~ '^[[:space:]]*rows\+=\("\$row"\)$' ]] && end=$index && break
    else
      [[ "${lines[index]}" == *'|| return $?' ]] && end=$index && break
    fi
  done
  (( start && end )) \
    || _zdx_surface_refuse "the menu record of $anchor ($rel:$at) has an unrecognized shape; add the record by hand or choose another --after command" \
    || return 1
  label_line="${indent}  \"$_ZS_NEW_LABEL\" \"$new\" \\"
  if (( rowvar )); then
    closing="${indent}  \"$_ZS_NEW_SENTENCE\") || return \$?"
    if (( ${#closing} > 80 )); then
      closing="${indent}  \"$_ZS_NEW_SENTENCE\") \\"$'\n'"${indent}  || return \$?"
    fi
    text="${indent}row=\$(${entry_function} \\"$'\n'"$label_line"$'\n'"$closing"$'\n'"${indent}rows+=(\"\$row\")"
  else
    closing="${indent}  \"$_ZS_NEW_SENTENCE\" || return \$?"
    if (( ${#closing} > 80 )); then
      closing="${indent}  \"$_ZS_NEW_SENTENCE\" \\"$'\n'"${indent}  || return \$?"
    fi
    text="${indent}${entry_function} \\"$'\n'"$label_line"$'\n'"$closing"
  fi
  _zdx_surface_original "$rel" || return 1
  _zdx_surface_edit "$rel" after "$end" "menu record" "$text"
}

_zdx_surface_plan_help() {
  local anchor="$_ZS_NEW_ANCHOR" new="$_ZS_NEW_COMMAND"
  local rel="${_ZS[usage_file]:-}" array_name="" line="" content="" prefix=""
  local suffix="" trailing="" candidate="" head="" tail="" leading=""
  local -a lines=() tokens=()
  local -i index=0 hit=0 hits=0 multi=0 position=0
  local list_pattern='"  ([a-z][a-z0-9-]*(, [a-z][a-z0-9-]*)*,?)"'
  [[ -n "$rel" ]] || _zdx_surface_refuse "no _${_ZS[suite]}_usage function found" || return 1
  array_name="_ZS_L_${_ZS[usage_which]}"
  lines=("${(@P)array_name}")
  for (( index = ${_ZS[usage_start]} + 1; index < ${_ZS[usage_end]}; index++ )); do
    [[ "${lines[index]}" =~ "$list_pattern" ]] || continue
    tokens=("${(@s:, :)${match[1]%,}}")
    (( ${#tokens} > 1 )) && multi=1
    if (( ${tokens[(Ie)$anchor]} )); then
      hit=$index
      (( hits++ ))
    fi
  done
  (( hits == 1 )) \
    || _zdx_surface_refuse "$anchor is listed $hits times in the command lists of ${_ZS[usage_name]} ($rel); add the help entry by hand or choose another --after command" \
    || return 1
  _zdx_surface_original "$rel" || return 1
  line="${lines[hit]}"
  [[ "$line" =~ "$list_pattern" ]]
  content="${match[1]}"
  prefix="${line[1,MBEGIN-1]}"
  suffix="${line[MEND+1,-1]}"
  trailing=""
  [[ "$content" == *, ]] && trailing=","
  tokens=("${(@s:, :)${content%,}}")
  leading="${prefix%%[^[:space:]]*}"

  if (( ! multi )); then
    # One command per help line: repeat the anchor's statement shape.
    if [[ -z "${prefix//[[:space:]]/}" ]]; then
      candidate="${lines[hit-1]}"$'\n'"${prefix}\"  ${new}\"${suffix}"
    else
      candidate="${prefix}\"  ${new}\"${suffix}"
    fi
    _zdx_surface_edit "$rel" after "$hit" "help entry" "$candidate"
    return 0
  fi

  position=${tokens[(Ie)$anchor]}
  candidate="${prefix}\"  ${(j:, :)${(@)tokens[1,position]}}, ${new}"
  (( position < ${#tokens} )) && candidate+=", ${(j:, :)${(@)tokens[position+1,-1]}}"
  candidate+="${trailing}\"${suffix}"
  if (( ${#candidate} <= 80 )); then
    _zdx_surface_edit "$rel" replace "$hit" "help entry" "$candidate"
    return 0
  fi
  # Too long for one line: split after the anchor into a new statement.
  head="${prefix}\"  ${(j:, :)${(@)tokens[1,position]}},\"${suffix}"
  tail="\"  ${new}"
  (( position < ${#tokens} )) && tail+=", ${(j:, :)${(@)tokens[position+1,-1]}}"
  tail+="${trailing}\"${suffix}"
  if [[ -z "${prefix//[[:space:]]/}" ]]; then
    candidate="${lines[hit-1]}"$'\n'"${prefix}${tail}"
  elif (( ${#prefix} + ${#tail} <= 80 )); then
    candidate="${prefix}${tail}"
  else
    candidate="${prefix%%[[:space:]]#}"
    candidate="${candidate} \\"$'\n'"${leading}  ${tail}"
  fi
  _zdx_surface_edit "$rel" replace "$hit" "help entry" "$head"
  _zdx_surface_edit "$rel" after "$hit" "help entry" "$candidate"
}

_zdx_surface_plan_completion() {
  local anchor="$_ZS_NEW_ANCHOR" new="$_ZS_NEW_COMMAND" rel="${_ZS[comp]}"
  local indent=""
  local -a words=()
  local -i at=0 position=0
  (( ${+_ZS_COMP[$anchor]} )) \
    || _zdx_surface_refuse "$anchor has no completion entry to follow in $rel" \
    || return 1
  at=${_ZS_COMP[$anchor]}
  [[ "${_ZS_L_comp[at]}" =~ "^([[:space:]]*)'${anchor}:" ]] || return 1
  indent="${match[1]}"
  _zdx_surface_original "$rel" || return 1
  _zdx_surface_edit "$rel" after "$at" "completion entry" \
    "${indent}'${new}:${_ZS_NEW_SUMMARY}'"
  [[ "${_ZS[bind_direct]}" == 1 ]] || return 0
  words=(${=${_ZS_L_comp[1]#\#compdef }})
  position=${words[(Ie)$anchor]}
  (( position )) \
    || _zdx_surface_refuse "$anchor is not bound by the #compdef line of $rel" \
    || return 1
  words=("${(@)words[1,position]}" "$new" "${(@)words[position+1,-1]}")
  _zdx_surface_edit "$rel" replace 1 "completion binding" "#compdef ${(j: :)words}"
}

_zdx_surface_plan_lazy() {
  local new="$_ZS_NEW_COMMAND" name="" indent=""
  local -a names=() sorted=()
  local -i after_line=0
  local LC_ALL=C
  [[ "${_ZS[lazy_direct]}" == 1 ]] || return 0
  # Registered names in file order.
  for name in "${(@k)_ZS_LAZY}"; do
    names+=("${(l:8::0:)_ZS_LAZY[$name]} $name")
  done
  names=("${(@o)names}")
  names=("${(@)names#* }")
  sorted=("${(@o)names}")
  if [[ "${(j: :)sorted}" == "${(j: :)names}" ]]; then
    after_line=${_ZS_LAZY[${names[-1]}]}
    for name in "${names[@]}"; do
      if [[ "$name" > "$new" ]]; then
        after_line=$(( ${_ZS_LAZY[$name]} - 1 ))
        break
      fi
    done
  elif (( ${+_ZS_LAZY[$_ZS_NEW_ANCHOR]} )); then
    after_line=${_ZS_LAZY[$_ZS_NEW_ANCHOR]}
  else
    _zdx_surface_refuse "cannot place the lazy stub: $_ZS_NEW_ANCHOR has none in functions.zsh"
    return 1
  fi
  [[ "${_ZS_L_lazy[${_ZS_LAZY[${names[1]}]}]}" =~ '^([[:space:]]+)' ]]
  indent="${match[1]}"
  _zdx_surface_original functions.zsh || return 1
  _zdx_surface_edit functions.zsh after "$after_line" "lazy stub" \
    "${indent}${new} ${_ZS[suite]}-menu.zsh"
}

_zdx_surface_plan_allow() {
  local anchor="$_ZS_NEW_ANCHOR" new="$_ZS_NEW_COMMAND" rel="${_ZS[allow_file]:-}"
  local array_name=""
  local -a lines=()
  local -i index=0 hit=0 hits=0
  [[ -n "$rel" ]] || return 0
  array_name="_ZS_L_${_ZS[allow_which]}"
  lines=("${(@P)array_name}")
  for (( index = ${_ZS[allow_start]} + 1; index < ${_ZS[allow_end]}; index++ )); do
    [[ "${lines[index]}" =~ "(^|[[:space:]|])${anchor}(\\||\\))" ]] || continue
    hit=$index
    (( hits++ ))
  done
  (( hits == 1 )) \
    || _zdx_surface_refuse "$anchor is listed $hits times in ${_ZS[allow_name]} ($rel); add the entry by hand" \
    || return 1
  [[ "${lines[hit]}" =~ '^([[:space:]]*)' ]]
  _zdx_surface_original "$rel" || return 1
  _zdx_surface_edit "$rel" after $(( hit - 1 )) "interactive allowlist" \
    "${match[1]}${new}|\\"
}

# --- new: rendering and writing ---------------------------------------------

# REPLY: the number of lines an edit adds.
_zdx_surface_edit_delta() {
  local -i i="$1"
  local -a text_lines=("${(@f)_ZS_EDIT_TEXT[i]}")
  if [[ "${_ZS_EDIT_KIND[i]}" == after ]]; then
    REPLY=${#text_lines}
  else
    REPLY=$(( ${#text_lines} - 1 ))
  fi
}

# REPLY: the first line of an edit in the edited file. Edits earlier in the
# file shift it; at the same line, a replacement precedes an insertion after
# that line, and insertions keep their planned order.
_zdx_surface_edit_position() {
  local -i i="$1" j=0 line=${_ZS_EDIT_LINE[$1]} other=0 position=0
  local kind="${_ZS_EDIT_KIND[$1]}" other_kind=""
  if [[ "$kind" == after ]]; then
    position=$(( line + 1 ))
  else
    position=$line
  fi
  for (( j = 1; j <= ${#_ZS_EDIT_FILE}; j++ )); do
    (( j == i )) && continue
    [[ "${_ZS_EDIT_FILE[j]}" == "${_ZS_EDIT_FILE[i]}" ]] || continue
    other=${_ZS_EDIT_LINE[j]}
    other_kind="${_ZS_EDIT_KIND[j]}"
    if (( other < line )); then
      :
    elif (( other == line )) && [[ "$kind" == after && "$other_kind" == replace ]]; then
      :
    elif (( other == line && j < i )) && [[ "$kind" == after && "$other_kind" == after ]]; then
      :
    else
      continue
    fi
    _zdx_surface_edit_delta $j
    (( position += REPLY ))
  done
  REPLY=$position
}

# Builds _ZS_NEW[<file>] from the unedited content and the planned edits.
# Edits apply from the bottom up so earlier line numbers stay valid. At one
# line, insertions after it apply before its replacement, and the later of two
# insertions applies first so the planned order is kept.
_zdx_surface_render() {
  local rel="" entry="" kind_key=""
  local -a lines=() order=() text_lines=()
  local -i i=0 line=0
  _ZS_NEW=()
  for rel in "${(@k)_ZS_ORIG}"; do
    lines=("${(@f)_ZS_ORIG[$rel]}")
    order=()
    for (( i = 1; i <= ${#_ZS_EDIT_FILE}; i++ )); do
      [[ "${_ZS_EDIT_FILE[i]}" == "$rel" ]] || continue
      kind_key=0
      [[ "${_ZS_EDIT_KIND[i]}" == after ]] && kind_key=1
      order+=("${(l:8::0:)_ZS_EDIT_LINE[i]} $kind_key ${(l:4::0:)i} $i")
    done
    for entry in "${(@O)order}"; do
      i=${entry##* }
      line=${_ZS_EDIT_LINE[i]}
      text_lines=("${(@f)_ZS_EDIT_TEXT[i]}")
      if [[ "${_ZS_EDIT_KIND[i]}" == after ]]; then
        lines=("${(@)lines[1,line]}" "${text_lines[@]}" "${(@)lines[line+1,-1]}")
      else
        lines=("${(@)lines[1,line-1]}" "${text_lines[@]}" "${(@)lines[line+1,-1]}")
      fi
    done
    _ZS_NEW[$rel]="${(F)lines}"
  done
}

# Parses every changed Zsh source and completion file with `zsh -n`.
_zdx_surface_validate() {
  local rel="" zsh_path="${commands[zsh]:-zsh}"
  for rel in "${(@ok)_ZS_NEW}"; do
    [[ "$rel" == *.zsh || "$rel" == completions/_* ]] || continue
    if ! print -r -- "${_ZS_NEW[$rel]}" | command "$zsh_path" -f -n 2>/dev/null; then
      _zdx_surface_error "the planned edit of $rel does not parse with zsh -n; nothing was written"
      return 1
    fi
  done
}

# Replaces each changed file through a private temporary file in the same
# directory, keeping its permission bits. A file that changed since planning
# stops the write before any file is replaced.
_zdx_surface_write() {
  local rel="" file="" temporary="" current=""
  local -a temporaries=() targets=()
  local -A file_state=()
  local -i i=0
  zmodload -F zsh/stat b:zstat || return 1
  {
    for rel in "${(@ok)_ZS_NEW}"; do
      file="$_zs_root/$rel"
      if [[ ! -f "$file" || -L "$file" || ! -w "$file" || "${file:A}" != "$file" ]]; then
        _zdx_surface_error "refusing to write $rel: not a writable regular file inside the repository"
        return 1
      fi
      current="$(<"$file")"
      if [[ "$current" != "${_ZS_ORIG[$rel]}" ]]; then
        _zdx_surface_error "$rel changed while the edits were planned; nothing was written"
        return 1
      fi
      zstat -LH file_state -- "$file" || return 1
      temporary=$(command mktemp "${file:h}/.${file:t}.XXXXXX") || return 1
      temporaries+=("$temporary")
      targets+=("$file")
      print -r -- "${_ZS_NEW[$rel]}" > "$temporary" || return 1
      command chmod -- "$(( [##8] file_state[mode] & 8#7777 ))" "$temporary" || return 1
    done
    for (( i = 1; i <= ${#temporaries}; i++ )); do
      command mv -f -- "${temporaries[i]}" "${targets[i]}" || return 1
      temporaries[i]=""
    done
  } always {
    for temporary in "${temporaries[@]}"; do
      [[ -n "$temporary" ]] && command rm -f -- "$temporary"
    done
  }
}

# --- new: checklist ----------------------------------------------------------

# reply: the lines of a file as they are after the planned edits, so the
# checklist points at the same lines in a dry run and after writing.
_zdx_surface_current_lines() {
  local rel="$1"
  if (( ${+_ZS_NEW[$rel]} )); then
    reply=("${(@f)_ZS_NEW[$rel]}")
    return 0
  fi
  _zdx_surface_lines "$_zs_root/$rel"
}

# Prints `file:line: text` for up to LIMIT lines of FILE matching the ERE.
_zdx_surface_find_lines() {
  local rel="$1" pattern="$2" line=""
  local -i index=0 limit=${3:-0} found=0
  _zdx_surface_current_lines "$rel" || return 0
  for line in "${reply[@]}"; do
    (( index++ ))
    [[ "$line" =~ "$pattern" ]] || continue
    print -r -- "     $rel:$index: ${${line##[[:space:]]#}[1,90]}"
    (( ++found == limit )) && break
  done
  return 0
}

# Lines that state a command count N, in digits or as an English word: test
# assertions about the fixture, and prose or tables that pair the number
# with commands, a suite name, or a table cell.
_zdx_surface_count_refs() {
  local -i count="$1" index=0
  shift
  local -a number_words=(one two three four five six seven eight nine ten eleven twelve)
  local number="$count" rel="" line="" pattern="" context=""
  (( count >= 1 && count <= ${#number_words} )) \
    && number="($count|${number_words[count]}|${(C)number_words[count]})"
  # A standalone number: not part of a word, a version, or 4,096.
  pattern="(^|[^0-9A-Za-z.,])${number}([^0-9A-Za-z.,]|[.,]([^0-9]|\$)|\$)"
  for rel in "$@"; do
    if [[ "$rel" == *.bats ]]; then
      context='(\$count|wc -l|NR ==|[Ff]reez|unique|fixture)'
    else
      context="([Cc]ommand|[Ff]reez|canonical|surface|inventory|\\| *${number} *\\||[A-Za-z] ${number}[,.])"
    fi
    _zdx_surface_current_lines "$rel" || continue
    index=0
    for line in "${reply[@]}"; do
      (( index++ ))
      [[ "$line" =~ "$pattern" && "$line" =~ "$context" ]] || continue
      print -r -- "     $rel:$index: ${${line##[[:space:]]#}[1,90]}"
    done
  done
  return 0
}

_zdx_surface_checklist() {
  local suite="${_ZS[suite]}" new="$_ZS_NEW_COMMAND" anchor="$_ZS_NEW_ANCHOR"
  local rel="" stub_line="" name="" file="" region="" completion_arm="" line=""
  local -a tests=() lines=() reviews=()
  local -i i=0 step=0 old_count=${#_ZS_COMMANDS} total=0 index=0
  for (( i = 1; i <= ${#_ZS_EDIT_FILE}; i++ )); do
    [[ "${_ZS_EDIT_SURFACE[i]}" == "function stub" ]] || continue
    _zdx_surface_edit_position $i
    stub_line="${_ZS_EDIT_FILE[i]}:$REPLY"
  done
  # The total after the edit; the fixture row is already counted.
  for file in "$_zs_root"/test/fixtures/*-public-commands.tsv(N.); do
    _zdx_surface_current_lines "${file#$_zs_root/}" || continue
    for name in "${reply[@]}"; do
      [[ -n "$name" && "$name" != '#'* ]] && (( total++ ))
    done
  done

  print -r -- ""
  print -r -- "Remaining manual surfaces for $new:"
  print -r -- "  $(( ++step )). Implement $new and keep its docblock contract and --help current:"
  print -r -- "     $stub_line"
  print -r -- "  $(( ++step )). Argument completion for its options; $anchor's arm is the model:"
  completion_arm=$(_zdx_surface_find_lines "${_ZS[comp]}" \
    "^[[:space:]]*([a-z][a-z0-9-]*\\|)*${anchor}(\\|[a-z][a-z0-9-]*)*\\)" 1)
  if [[ -n "$completion_arm" ]]; then
    print -r -- "$completion_arm"
  else
    print -r -- "     ${_ZS[comp]}: $anchor uses the default arm; add one if $new takes options"
  fi
  print -r -- "  $(( ++step )). Document it in the suite contract (${_ZS[doc]}); $anchor is mentioned at:"
  _zdx_surface_find_lines "${_ZS[doc]}" "(^|[^a-z0-9-])${anchor}([^a-z0-9-]|\$)" 3
  print -r -- "  $(( ++step )). Describe it in docs/user-guide.md, in the ${suite}-menu section:"
  _zdx_surface_find_lines docs/user-guide.md "^## .*\\(\`${suite}-menu\`\\)" 1
  print -r -- "  $(( ++step )). Update the frozen counts ($old_count -> $(( old_count + 1 ))) in tests and docs:"
  tests=("$_zs_root"/test/"${suite}"_*.bats(N.) "$_zs_root"/test/"${suite}".bats(N.))
  _zdx_surface_count_refs "$old_count" "${(@)tests#$_zs_root/}" "${_ZS[doc]}" \
    docs/suites.md docs/roadmap.md
  print -r -- "     Total public commands ($(( total - 1 )) -> $total):"
  _zdx_surface_count_refs "$(( total - 1 ))" docs/suites.md docs/roadmap.md README.md
  print -r -- "  $(( ++step )). Add BATS coverage for its grammar, streams, and behavior (test/${suite}_*.bats)."
  print -r -- "  $(( ++step )). Add a CHANGELOG.md [Unreleased] entry."

  # Other per-command tables that list the anchor, such as dependency or
  # batch-eligibility case arms, may need the new command too.
  for name in menu common; do
    rel="${_ZS[$name]}"
    _zdx_surface_current_lines "$rel" || continue
    lines=("${reply[@]}")
    index=0
    region=""
    for line in "${lines[@]}"; do
      (( index++ ))
      [[ "$line" =~ '^(_[a-z0-9_]+)\(\)[[:space:]]*\{' ]] && region="${match[1]}"
      [[ "$line" =~ "(^|[[:space:]|(])${anchor}(\\||\\)|\\\\\$)" ]] || continue
      case "$region" in
        "${_ZS[dispatch_name]:-}"|"${_ZS[allow_name]:-}"|"${_ZS[rows_name]:-}"|"${_ZS[usage_name]:-}") continue ;;
      esac
      reviews+=("     $rel:$index: $region")
    done
  done
  if (( ${#reviews} )); then
    print -r -- "  $(( ++step )). Review per-command tables that list $anchor; add $new where it applies:"
    print -rl -- "${(@u)reviews}"
  fi
  print -r -- "  $(( ++step )). New dependencies need zdx-doctor metadata; a new trust boundary needs docs/security-assessment.md."
  print -r -- ""
  print -r -- "Verify: just surfaces $suite; bats test/${suite}_contract.bats"
}

# --- new: entry --------------------------------------------------------------

typeset -g _ZS_NEW_COMMAND="" _ZS_NEW_MODULE="" _ZS_NEW_RISK="" _ZS_NEW_ANCHOR=""
typeset -g _ZS_NEW_LABEL="" _ZS_NEW_SENTENCE="" _ZS_NEW_SUMMARY="" _ZS_NEW_USAGE=""

_zdx_surface_new_main() {
  local -i dry_run=0 i=0
  local after="" label="" description="" suite="" command_name="" module=""
  local risk="" option="" value="" column="" prefix="" rel="" candidate=""
  local -a positional=() suites=() prefixes=() values=()
  local -A options=()
  _ZS_EDIT_FILE=() _ZS_EDIT_KIND=() _ZS_EDIT_LINE=() _ZS_EDIT_TEXT=()
  _ZS_EDIT_SURFACE=() _ZS_ORIG=() _ZS_NEW=() _ZS_VALUE=()

  while (( $# )); do
    case "$1" in
      --dry-run) dry_run=1 ;;
      -h|--help) _zdx_surface_usage; return 0 ;;
      --after|--label|--description|--capability|--privilege|--owner)
        (( $# >= 2 )) || { _zdx_surface_error "$1 requires a value"; return 2; }
        options[${1#--}]="$2"
        shift
        ;;
      --after=*|--label=*|--description=*|--capability=*|--privilege=*|--owner=*)
        option="${${1%%=*}#--}"
        options[$option]="${1#*=}"
        ;;
      --) shift; positional+=("$@"); break ;;
      -*) _zdx_surface_error "unknown option: ${(V)1}"; return 2 ;;
      *) positional+=("$1") ;;
    esac
    shift
  done
  (( ${#positional} == 4 )) || {
    _zdx_surface_error "expected SUITE COMMAND MODULE RISK; see --help"
    return 2
  }
  suite="${positional[1]}"
  command_name="${positional[2]}"
  module="${positional[3]}"
  risk="${positional[4]}"
  after="${options[after]:-}"
  label="${options[label]:-}"
  description="${options[description]:-}"

  _zdx_surface_suites
  suites=("${reply[@]}")
  (( ${suites[(Ie)$suite]} )) || {
    _zdx_surface_error "unknown suite ${(qqq)${(V)suite}}; known suites: ${(j:, :)suites}"
    return 2
  }
  _zdx_surface_load_suite "$suite" || return 1
  (( _zs_problems == 0 )) || {
    _zdx_surface_error "fix the $suite fixture before adding a command"
    return 1
  }
  _zdx_surface_contract_rules

  # Command name: kebab-case, an existing suite prefix, and the contract
  # test's own pattern. Digits are refused while no command of the suite
  # uses one.
  if [[ ! "$command_name" =~ '^[a-z]+(-[a-z0-9]+)+$' || ${#command_name} -gt 48 ]]; then
    _zdx_surface_error "invalid command name ${(qqq)${(V)command_name}}: use kebab-case such as ${suite}-example (at most 48 characters)"
    return 2
  fi
  for candidate in "${_ZS_COMMANDS[@]}"; do
    prefixes+=("${candidate%%-*}")
  done
  prefixes=("${(@u)prefixes}")
  prefix="${command_name%%-*}"
  (( ${prefixes[(Ie)$prefix]} )) || {
    _zdx_surface_error "$command_name does not start with a prefix of the $suite fixture: ${(j:-, :)prefixes}-"
    return 2
  }
  if [[ "$command_name" == *[0-9]* && "${(j: :)_ZS_COMMANDS}" != *[0-9]* ]]; then
    _zdx_surface_error "$command_name contains a digit, which no $suite command uses; use letters"
    return 2
  fi
  _zdx_surface_rule_accepts command "$command_name" || {
    _zdx_surface_error "$command_name does not match the ${_ZS[contract]} pattern ${_ZS_RULE[command]#*:}"
    return 2
  }

  # Module: an existing feature module of the suite that its entrypoint loads.
  if [[ ! "$module" =~ "^${suite}(-[a-z0-9]+)+\\.zsh\$" ]] \
    || [[ "$module" == "${suite}-common.zsh" || "$module" == "${suite}-menu.zsh" ]]; then
    _zdx_surface_error "invalid module ${(qqq)${(V)module}}: name a feature module under functions/$suite/, such as ${suite}-example.zsh"
    return 2
  fi
  rel="functions/$suite/$module"
  if [[ ! -f "$_zs_root/$rel" || -L "$_zs_root/$rel" ]]; then
    _zdx_surface_error "unknown module $rel; create and load a new module by hand first"
    return 2
  fi
  [[ "${(F)_ZS_L_menu}" =~ "(^|[^a-z0-9.-])${module//./\\.}([^a-z0-9.-]|\$)" ]] || {
    _zdx_surface_error "${_ZS[menu]} does not load $module"
    return 2
  }
  _zdx_surface_rule_accepts module "$module" || {
    _zdx_surface_error "$module does not match the ${_ZS[contract]} pattern ${_ZS_RULE[module]#*:}"
    return 2
  }

  # Risk: the development.md safety classes, narrowed by the contract test.
  if (( ! ${_ZS_RISKS[(Ie)$risk]} )) || ! _zdx_surface_rule_accepts risk "$risk"; then
    if [[ -n "${_ZS_RULE[risk]:-}" ]]; then
      _zdx_surface_error "invalid risk ${(qqq)${(V)risk}}: ${_ZS[contract]} accepts ${_ZS_RULE[risk]#*:}"
    else
      _zdx_surface_error "invalid risk ${(qqq)${(V)risk}}: use one of ${(j:, :)_ZS_RISKS}"
    fi
    return 2
  fi

  # Remaining fixture columns come from options or one shared value.
  for column in "${_ZS_COLUMNS[@]}"; do
    case "$column" in
      command|module|risk|description) continue ;;
      capability|current-capability) option=capability ;;
      privilege|owner) option="$column" ;;
      *)
        _zdx_surface_error "the $suite fixture column '$column' is not supported by this generator"
        return 1
        ;;
    esac
    i=${_ZS_COLUMNS[(Ie)$column]}
    values=()
    for candidate in "${_ZS_COMMANDS[@]}"; do
      values+=("${${(@ps:\t:)_ZS_ROW_VALUES[$candidate]}[i]}")
    done
    values=("${(@ou)values}")
    value="${options[$option]:-}"
    if [[ -z "$value" ]]; then
      if (( ${#values} == 1 )); then
        value="${values[1]}"
      else
        _zdx_surface_error "the $suite fixture needs a $column value: pass --$option VALUE (in use: ${(j:, :)values})"
        return 2
      fi
    fi
    if [[ ! "$value" =~ '^[a-z0-9]+(-[a-z0-9]+)*$' ]] || ! _zdx_surface_rule_accepts "$column" "$value"; then
      _zdx_surface_error "invalid $column ${(qqq)${(V)value}}${_ZS_RULE[$column]:+: the ${_ZS[contract]} rule is ${_ZS_RULE[$column]#*:}}"
      return 2
    fi
    _ZS_VALUE[$column]="$value"
  done
  for option in capability privilege owner; do
    (( ${+options[$option]} )) || continue
    [[ -n "${_ZS_VALUE[$option]:-}${_ZS_VALUE[current-$option]:-}" ]] && continue
    _zdx_surface_error "--$option does not apply to the $suite fixture"
    return 2
  done

  # Menu label and description, used in source strings and completion specs.
  if [[ -z "$label" || -z "$description" ]]; then
    _zdx_surface_error "--label and --description are required (menu label and one-sentence description)"
    return 2
  fi
  if [[ ! "$label" =~ "$_ZS_TEXT_PATTERN" || ${#label} -gt 48 || "$label" == *'  '* ]]; then
    _zdx_surface_error "invalid --label: start with an uppercase verb, use letters, digits, spaces, and , . ; : ( ) / + & _ - only (at most 48 characters)"
    return 2
  fi
  if [[ ! "$description" =~ "$_ZS_TEXT_PATTERN" || ${#description} -gt 120 || "$description" == *'  '* ]]; then
    _zdx_surface_error "invalid --description: one sentence starting with an uppercase letter, using letters, digits, spaces, and , . ; : ( ) / + & _ - only (at most 120 characters)"
    return 2
  fi

  # The command must be new everywhere, and so must its usage helper.
  if _zdx_surface_name_taken "$command_name"; then
    _zdx_surface_error "$command_name already exists ($REPLY); run just surfaces $suite to inspect its surfaces"
    return 1
  fi
  if [[ "$command_name" == "$suite"-* ]]; then
    _ZS_NEW_USAGE="_${suite}_${${command_name#${suite}-}//-/_}_usage"
  else
    _ZS_NEW_USAGE="_${suite}_${command_name//-/_}_usage"
  fi
  for rel in "$_zs_root"/functions/**/*.zsh(N.) "$_zs_root"/functions.zsh(N.); do
    [[ $'\n'"$(<"$rel")" == *$'\n'"${_ZS_NEW_USAGE}()"[[:space:]]#"{"* ]] || continue
    _zdx_surface_error "the helper name $_ZS_NEW_USAGE is already defined (${rel#$_zs_root/})"
    return 1
  done
  [[ $'\n'"${(F)_ZS_L_common}" == *$'\n'"_${suite}_error()"[[:space:]]#"{"* ]] || {
    _zdx_surface_error "${_ZS[common]} defines no _${suite}_error helper for the stub"
    return 1
  }

  # Anchor: the explicit --after command, or the last command of MODULE in
  # menu order that has exactly one menu record.
  if [[ -n "$after" ]]; then
    (( ${+_ZS_ROW_LINE[$after]} )) || {
      _zdx_surface_error "--after ${(qqq)${(V)after}} is not a command of the $suite fixture"
      return 2
    }
  else
    local -i best=0
    for candidate in "${_ZS_COMMANDS[@]}"; do
      [[ "${${_ZS_DEFS[$candidate]:-}%:*}" == */"$module" ]] || continue
      (( ${_ZS_ROWS_COUNT[$candidate]:-0} == 1 )) || continue
      (( ${_ZS_ROWS_LINE[$candidate]} > best )) || continue
      best=${_ZS_ROWS_LINE[$candidate]}
      after="$candidate"
    done
    [[ -n "$after" ]] || {
      _zdx_surface_error "no $module command has a single menu record to follow; pass --after COMMAND"
      return 1
    }
  fi

  _ZS_NEW_COMMAND="$command_name"
  _ZS_NEW_MODULE="$module"
  _ZS_NEW_RISK="$risk"
  _ZS_NEW_ANCHOR="$after"
  _ZS_NEW_LABEL="$label"
  _ZS_NEW_SENTENCE="${description%.}."
  _ZS_NEW_SUMMARY="${description%.}"

  _zdx_surface_plan_fixture || return 1
  _zdx_surface_plan_stub || return 1
  _zdx_surface_plan_dispatch || return 1
  _zdx_surface_plan_menu || return 1
  _zdx_surface_plan_help || return 1
  _zdx_surface_plan_completion || return 1
  _zdx_surface_plan_allow || return 1
  _zdx_surface_plan_lazy || return 1
  _zdx_surface_render
  _zdx_surface_validate || return 1

  print -r -- "New command: $command_name ($suite, $module, $risk), placed after $after"
  print -r -- ""
  if (( dry_run )); then
    print -r -- "Planned edits (dry run; nothing is written):"
  else
    print -r -- "Edits:"
  fi
  local -a old_lines=()
  for (( i = 1; i <= ${#_ZS_EDIT_FILE}; i++ )); do
    _zdx_surface_edit_position $i
    print -r -- "  ${_ZS_EDIT_FILE[i]}:$REPLY  ${_ZS_EDIT_SURFACE[i]}"
    (( dry_run )) || continue
    if [[ "${_ZS_EDIT_KIND[i]}" == replace ]]; then
      old_lines=("${(@f)_ZS_ORIG[${_ZS_EDIT_FILE[i]}]}")
      print -r -- "    - ${old_lines[${_ZS_EDIT_LINE[i]}]}"
    fi
    for value in "${(@f)_ZS_EDIT_TEXT[i]}"; do
      print -r -- "    + $value"
    done
  done
  if (( ! dry_run )); then
    _zdx_surface_write || return 1
    print -r -- ""
    print -r -- "Wrote ${#_ZS_NEW} files."
  fi
  _zdx_surface_checklist
  return 0
}

# --- Entry -------------------------------------------------------------------

_zdx_surface_main() {
  emulate -L zsh
  setopt extendedglob
  _zs_root="${_ZDX_SURFACE_SOURCE_FILE:h:h}"
  _zs_problems=0
  _zs_warnings=0
  case "${1:-}" in
    check)
      shift
      _zs_tool=surfaces
      _zdx_surface_check_main "$@"
      ;;
    new)
      shift
      _zs_tool=new-command
      _zdx_surface_new_main "$@"
      ;;
    -h|--help)
      _zdx_surface_usage
      ;;
    *)
      _zdx_surface_usage
      return 2
      ;;
  esac
}

typeset -g _ZDX_SURFACE_SOURCED=1
if [[ "$ZSH_EVAL_CONTEXT" == toplevel ]]; then
  _zdx_surface_main "$@"
  exit $?
fi
