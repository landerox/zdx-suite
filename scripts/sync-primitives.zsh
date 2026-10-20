#!/usr/bin/env zsh
# =============================================================================
# Primitive sync: copies canonical core primitives into the suite common files
# =============================================================================
#
# functions.zsh owns one canonical copy of each shared primitive between
# `# >>> zdx-primitive NAME` and `# <<< zdx-primitive NAME` markers. Each suite
# common file keeps a generated copy between the same markers, renamed to its
# own prefix, so the suite still works when it is sourced without the core.
# The suite wrappers call the core copy when it is loaded.
#
# Usage: zsh -f scripts/sync-primitives.zsh [--check]
#   --check  report generated copies that differ and exit 1; change nothing
#

emulate -L zsh
setopt err_return no_unset pipe_fail

typeset root="${0:A:h:h}"
typeset mode=write
case "${1-}" in
  "") ;;
  --check) mode=check ;;
  *)
    print -u2 -r -- "Usage: zsh -f scripts/sync-primitives.zsh [--check]"
    exit 2
    ;;
esac

# Each primitive: its canonical function and the suite files that keep a copy,
# as file:prefix pairs; the copy is named <prefix><canonical without _zdx>.
typeset -a primitives=(picker-capture confirm-prompt)
typeset -A canonical_functions=(
  picker-capture _zdx_picker_capture
  confirm-prompt _zdx_confirm_prompt
)
typeset -A primitive_targets=(
  picker-capture "functions/git-common.zsh:_git functions/sys-common.zsh:_sys functions/dev-common.zsh:_dev functions/py-common.zsh:_py functions/ws-common.zsh:_ws functions/env-common.zsh:_env functions/file-common.zsh:_file functions/zdx-common.zsh:_zdx_menu"
  confirm-prompt "functions/git-common.zsh:_git functions/sys-common.zsh:_sys functions/dev-common.zsh:_dev functions/py-common.zsh:_py functions/ws-common.zsh:_ws functions/env-common.zsh:_env functions/file-common.zsh:_file functions/vpn-common.zsh:_vpn"
)

# REPLY: the text between the markers of PRIMITIVE in FILE, markers included.
_sync_extract() {
  local file="$1" primitive="$2" line="" inside=0 found=0
  local -a block=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "# >>> zdx-primitive $primitive" ]]; then
      (( inside == 0 && found == 0 )) || return 1
      inside=1
      found=1
    fi
    (( inside )) && block+=("$line")
    if [[ "$line" == "# <<< zdx-primitive $primitive" ]]; then
      (( inside )) || return 1
      inside=0
    fi
  done < "$file"
  (( found && ! inside )) || return 1
  REPLY="${(pj:\n:)block}"
}

typeset -i differences=0
typeset primitive="" canonical="" target_file="" target_prefix=""
typeset expected="" current="" target=""
for primitive in "${primitives[@]}"; do
  _sync_extract "$root/functions.zsh" "$primitive" || {
    print -u2 -r -- "sync-primitives: functions.zsh has no complete $primitive block."
    exit 1
  }
  canonical="$REPLY"
  for target in ${=primitive_targets[$primitive]}; do
    target_file="${target%%:*}"
    target_prefix="${target#*:}"
    expected="${canonical//${canonical_functions[$primitive]}/${target_prefix}${canonical_functions[$primitive]#_zdx}}"
    if ! _sync_extract "$root/$target_file" "$primitive"; then
      print -u2 -r -- "sync-primitives: $target_file has no complete $primitive block."
      differences+=1
      continue
    fi
    current="$REPLY"
    [[ "$current" == "$expected" ]] && continue
    differences+=1
    if [[ "$mode" == check ]]; then
      print -u2 -r -- "sync-primitives: $target_file differs from the canonical $primitive."
      continue
    fi
    local content=""
    content="$(<"$root/$target_file")"
    content="${content/"$current"/$expected}"
    print -r -- "$content" > "$root/$target_file"
    print -r -- "sync-primitives: updated $primitive in $target_file"
  done
done

if [[ "$mode" == check ]] && (( differences > 0 )); then
  exit 1
fi
exit 0
