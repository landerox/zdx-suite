#!/usr/bin/env zsh
# =============================================================================
# Dev Update Actions: pinned GitHub Actions references in workflow files
# =============================================================================
#
# Loaded by dev-menu.zsh after dev-state.zsh and dev-update-transaction.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_DEV_UPDATE_ACTIONS_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# Most workflow files a single run inspects, and concurrent tag queries.
typeset -gi _DEV_ACTIONS_MAX_FILES=256
typeset -gi _DEV_ACTIONS_JOBS=8

# --- Parser and rewriter ----------------------------------------------------

# Runs the line-based workflow parser with the metadata interpreter in
# isolated mode (-I -S). Workflow files are read as bytes through a no-follow
# descriptor and are never executed or imported.
#
#   scan <file>...
#     stdout: one "F<TAB>index<TAB>sha256" record per file, then one
#             "R<TAB>index<TAB>line<TAB>class<TAB>owner<TAB>repo<TAB>path<TAB>
#             ref<TAB>comment<TAB>display" record per `uses:` line outside a
#             block scalar. Empty fields are "-". The class is remote, local,
#             docker, or invalid; only a remote record carries validated
#             owner, repo, path, and ref fields, and comment is the version a
#             trailing comment names (`# v4.2.2`, `# 4.2.2`, `# tag=v4.2.2`).
#   rewrite <original> <candidate> <edits>
#     Creates <candidate> (mode 600, never replacing a file) from <original>
#     with every "line<TAB>expected<TAB>new-value<TAB>version" edit applied.
#     Only the reference and its version comment change; every other byte is
#     copied, and each edited line must parse again to the new value.
#   Status: 0 on success, 1 for an unreadable, oversized, or unsafe input.
_dev_actions_python() {
  local REPLY=""
  _dev_python_toml_resolve || return 1
  command "$REPLY" -I -S - "$@" <<'PY_DEV_ACTIONS' 2>/dev/null
import hashlib
import os
import re
import stat
import sys

MAX_FILE_SIZE = 1024 * 1024
KEY_LINE = re.compile(rb"^[ \t]*(?:-[ \t]+)?uses[ \t]*:")
USES = re.compile(
    rb"^(?P<prefix>[ \t]*(?:-[ \t]+)?uses[ \t]*:[ \t]*)"
    rb"(?P<quote>['\"]?)(?P<value>[^\s'\"#]+)(?P=quote)"
    rb"(?P<trailer>(?:[ \t]+#.*)?[ \t]*)$"
)
BLOCK_HEADER = re.compile(
    rb"^[ \t]*(?:-[ \t]+)*(?:[^\s#][^#]*?[ \t]*:[ \t]+)?"
    rb"[|>][0-9+-]*(?:[ \t]+#.*)?[ \t]*$"
)
COMMENT = re.compile(
    rb"^(?P<lead>[ \t]+#[ \t]*(?:tag=)?)"
    rb"(?P<version>v?[0-9]+(?:\.[0-9]+){0,2})(?P<rest>(?:[ \t].*)?)$"
)
OWNER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]{0,38}$")
REPO = re.compile(r"^[A-Za-z0-9._-]{1,100}$")
SEGMENT = re.compile(r"^[A-Za-z0-9._-]{1,100}$")
REF = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,254}$")
NEW_VALUE = re.compile(
    rb"^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}"
    rb"(?:/[A-Za-z0-9._-]{1,100})*@[0-9a-f]{40}$"
)
NEW_VERSION = re.compile(rb"^v?[0-9]+\.[0-9]+\.[0-9]+$")


def read_stable(path):
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    linked = os.lstat(path)
    descriptor = os.open(path, flags)
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(linked.st_mode)
            or not stat.S_ISREG(before.st_mode)
            or (linked.st_dev, linked.st_ino) != (before.st_dev, before.st_ino)
            or before.st_size > MAX_FILE_SIZE
        ):
            raise ValueError
        chunks = []
        length = 0
        while length <= MAX_FILE_SIZE:
            chunk = os.read(descriptor, MAX_FILE_SIZE + 1 - length)
            if not chunk:
                break
            chunks.append(chunk)
            length += len(chunk)
        after = os.fstat(descriptor)
        stable = lambda state: (
            state.st_dev,
            state.st_ino,
            state.st_size,
            state.st_mtime_ns,
            state.st_ctime_ns,
        )
        if length > MAX_FILE_SIZE or stable(before) != stable(after):
            raise ValueError
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def split_lines(data):
    parts = data.split(b"\n")
    lines = [part + b"\n" for part in parts[:-1]]
    if parts[-1]:
        lines.append(parts[-1])
    return lines


def body_of(line):
    body = line[:-1] if line.endswith(b"\n") else line
    return body[:-1] if body.endswith(b"\r") else body


def display(value):
    text = value.decode("utf-8", "replace")
    text = "".join(char if char.isprintable() else "?" for char in text)
    return text[:100] or "-"


def valid_path(path):
    if not path:
        return True
    if len(path) > 255:
        return False
    return all(
        SEGMENT.match(segment) and segment not in (".", "..")
        for segment in path.split("/")
    )


def valid_ref(ref):
    return (
        REF.match(ref) is not None
        and ".." not in ref
        and "//" not in ref
        and "@{" not in ref
        and "/." not in ref
        and not ref.endswith(("/", ".", ".lock"))
    )


def classify(value):
    try:
        text = value.decode("ascii")
    except UnicodeDecodeError:
        return ["invalid", "-", "-", "-", "-"]
    if text.startswith("./"):
        return ["local", "-", "-", "-", "-"]
    if text.startswith("docker://"):
        return ["docker", "-", "-", "-", "-"]
    if text.count("@") != 1:
        return ["invalid", "-", "-", "-", "-"]
    action, ref = text.split("@")
    parts = action.split("/")
    if len(parts) < 2:
        return ["invalid", "-", "-", "-", "-"]
    owner, repo, path = parts[0], parts[1], "/".join(parts[2:])
    if (
        OWNER.match(owner) is None
        or REPO.match(repo) is None
        or repo in (".", "..")
        or not valid_path(path)
        or not valid_ref(ref)
    ):
        return ["invalid", "-", "-", "-", "-"]
    return ["remote", owner, repo, path or "-", ref]


def scan(paths):
    records = []
    for index, path in enumerate(paths, 1):
        data = read_stable(path)
        records.append(f"F\t{index}\t{hashlib.sha256(data).hexdigest()}")
        block_parent = None
        block_indent = None
        for number, line in enumerate(split_lines(data), 1):
            body = body_of(line)
            indent = len(body) - len(body.lstrip(b" "))
            if block_parent is not None:
                if not body.strip(b" \t"):
                    continue
                if block_indent is None:
                    if indent > block_parent:
                        block_indent = indent
                        continue
                    block_parent = None
                elif indent >= block_indent:
                    continue
                else:
                    block_parent = None
                    block_indent = None
            if KEY_LINE.match(body):
                match = USES.match(body)
                if match is None:
                    fields = ["invalid", "-", "-", "-", "-", "-"]
                    shown = display(body.split(b":", 1)[1].strip())
                else:
                    fields = classify(match.group("value"))
                    comment = COMMENT.match(match.group("trailer"))
                    version = "-"
                    if comment is not None:
                        version = comment.group("version").decode("ascii")
                    fields.append(version)
                    shown = display(match.group("value"))
                records.append(
                    "\t".join(["R", str(index), str(number)] + fields + [shown])
                )
            if BLOCK_HEADER.match(body):
                block_parent = indent
                block_indent = None
    for record in records:
        print(record)


def rewrite(original, candidate, edits_path):
    lines = split_lines(read_stable(original))
    edits = {}
    for raw in read_stable(edits_path).split(b"\n"):
        if not raw:
            continue
        fields = raw.split(b"\t")
        if len(fields) != 4 or not fields[0].isdigit():
            raise ValueError
        number = int(fields[0])
        expected, new_value, version = fields[1], fields[2], fields[3]
        if (
            number < 1
            or number > len(lines)
            or number in edits
            or NEW_VALUE.match(new_value) is None
            or NEW_VERSION.match(version) is None
        ):
            raise ValueError
        edits[number] = (expected, new_value, version)
    if not edits:
        raise ValueError

    output = []
    for number, line in enumerate(lines, 1):
        if number not in edits:
            output.append(line)
            continue
        expected, new_value, version = edits[number]
        body = body_of(line)
        ending = line[len(body):]
        match = USES.match(body)
        if match is None or match.group("value") != expected:
            raise ValueError
        trailer = match.group("trailer")
        comment = COMMENT.match(trailer)
        if comment is not None:
            trailer = comment.group("lead") + version + comment.group("rest")
        elif b"#" in trailer:
            trailer = b" # " + version + trailer
        else:
            trailer = (trailer or b" ") + b"# " + version
        quote = match.group("quote")
        new_body = match.group("prefix") + quote + new_value + quote + trailer
        check = USES.match(new_body)
        check_comment = COMMENT.match(check.group("trailer")) if check else None
        if (
            check is None
            or check.group("value") != new_value
            or check_comment is None
            or check_comment.group("version") != version
            or check.group("prefix") != match.group("prefix")
        ):
            raise ValueError
        output.append(new_body + ending)

    if len(output) != len(lines):
        raise ValueError
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    flags |= getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    descriptor = os.open(candidate, flags, 0o600)
    try:
        view = memoryview(b"".join(output))
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise OSError
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


try:
    if len(sys.argv) >= 3 and sys.argv[1] == "scan":
        scan(sys.argv[2:])
    elif len(sys.argv) == 5 and sys.argv[1] == "rewrite":
        rewrite(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        raise ValueError
except (OSError, UnicodeError, ValueError):
    raise SystemExit(1)
PY_DEV_ACTIONS
}

# --- Validation -------------------------------------------------------------
# Every value parsed from a workflow, a tag listing, or the GitHub API is data.
# These strict patterns run again before a value reaches a URL or a command.

_dev_actions_valid_repository() {
  local owner="${1-}" repo="${2-}"
  local MATCH MBEGIN MEND
  local -a match=() mbegin=() mend=()
  [[ "$owner" =~ '^[A-Za-z0-9][A-Za-z0-9-]{0,38}$' ]] || return 1
  [[ "$repo" =~ '^[A-Za-z0-9._-]{1,100}$' \
    && "$repo" != "." && "$repo" != ".." ]]
}

_dev_actions_valid_ref() {
  local ref="${1-}"
  local MATCH MBEGIN MEND
  local -a match=() mbegin=() mend=()
  [[ "$ref" =~ '^[A-Za-z0-9][A-Za-z0-9._/-]{0,254}$' ]] || return 1
  [[ "$ref" != *..* && "$ref" != *//* && "$ref" != *'@{'* \
    && "$ref" != */.* && "$ref" != */ && "$ref" != *. \
    && "$ref" != *.lock ]]
}

_dev_actions_valid_path() {
  local action_path="${1-}"
  [[ -z "$action_path" ]] && return 0
  local MATCH MBEGIN MEND
  local -a match=() mbegin=() mend=()
  (( ${#action_path} <= 255 )) || return 1
  [[ "$action_path" =~ '^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$' ]] || return 1
  [[ "/$action_path/" != */./* && "/$action_path/" != */../* ]]
}

_dev_actions_valid_sha() {
  local MATCH MBEGIN MEND
  local -a match=() mbegin=() mend=()
  [[ "${1-}" =~ '^[0-9a-f]{40}$' ]]
}

# REPLY: a sortable "MMMMMM.mmmmmm.pppppp" key for a semantic version name.
# `exact` accepts only vX.Y.Z or X.Y.Z without leading zeros or a prerelease;
# `partial` also accepts vX and vX.Y, padding the missing parts with zero.
# Usage: _dev_actions_version_key <name> <exact|partial>
_dev_actions_version_key() {
  local name="${1-}" mode="${2:-exact}"
  local MATCH MBEGIN MEND
  local -a match=() mbegin=() mend=()
  REPLY=""
  local number='(0|[1-9][0-9]{0,5})'
  if [[ "$mode" == exact ]]; then
    [[ "$name" =~ "^v?${number}\\.${number}\\.${number}\$" ]] || return 1
  else
    [[ "$name" =~ "^v?${number}(\\.${number})?(\\.${number})?\$" ]] \
      || return 1
  fi
  local -a parts=("${(@s:.:)${name#v}}")
  local -i major=$(( 10#${parts[1]} )) minor=$(( 10#${parts[2]:-0} ))
  local -i patch=$(( 10#${parts[3]:-0} ))
  REPLY="${(l:6::0:)major}.${(l:6::0:)minor}.${(l:6::0:)patch}"
}

# --- Network queries --------------------------------------------------------

# Lists the tags of one public github.com repository into <output-file>, with
# stderr in <error-file>. No token is used: credential helpers and askpass
# programs are disabled, terminal prompts are off, only HTTPS is allowed even
# when a url.<base>.insteadOf rule rewrites the address, Git's HTTP low-speed
# limit aborts a stalled transfer, and the whole query has a deadline. The
# listing is capped at 16 MiB.
# Usage: _dev_actions_list_tags <owner> <repo> <output-file> <error-file>
_dev_actions_list_tags() {
  local owner="$1" repo="$2" output_file="$3" error_file="$4"
  _dev_actions_valid_repository "$owner" "$repo" || return 2
  (
    limit -s filesize 16m 2>/dev/null || exit 125
    unset SSH_ASKPASS
    export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="" GCM_INTERACTIVE=never
    export GIT_HTTP_LOW_SPEED_LIMIT=1
    export GIT_HTTP_LOW_SPEED_TIME="$DEV_ACTIONS_TIMEOUT"
    _dev_run_with_timeout "$DEV_ACTIONS_TIMEOUT" git \
      -c credential.helper= -c core.askPass= \
      -c protocol.allow=never -c protocol.https.allow=always \
      ls-remote --tags -- "https://github.com/${owner}/${repo}"
  ) </dev/null >"$output_file" 2>"$error_file"
}

# Lists the tags of every repository in the caller's repo_keys with at most
# _DEV_ACTIONS_JOBS concurrent queries. Query N writes tags.N, tags.N.err, and
# tags.N.status below the caller's private transaction_dir. After a batch in
# which a query timed out, later repositories are not queried, so an
# unreachable github.com costs one deadline instead of one per repository;
# their status file stays absent. Every started query is waited for, also
# when a trapped interrupt returns from wait early.
_dev_actions_query_repositories() {
  setopt LOCAL_OPTIONS NO_MONITOR
  local -a pids=()
  local -i index=0 batch_start=0 total=${#repo_keys[@]} pid=0
  local stem="" status_text="" current_key=""
  {
    while (( index < total )); do
      (( interrupted )) && return 0
      batch_start=$(( index + 1 ))
      pids=()
      while (( index < total && ${#pids[@]} < _DEV_ACTIONS_JOBS )); do
        (( ++index ))
        current_key="${repo_keys[index]}"
        stem="${transaction_dir}/tags.${index}"
        (
          local -i query_rc=0
          _dev_actions_list_tags "${repo_owner[$current_key]}" \
            "${repo_name[$current_key]}" "$stem" "${stem}.err" \
            || query_rc=$?
          print -r -- "$query_rc" >| "${stem}.status"
        ) &
        pids+=($!)
      done
      for pid in "${pids[@]}"; do
        while builtin kill -0 "$pid" 2>/dev/null; do
          wait "$pid" 2>/dev/null
          (( $? == 127 )) && break
        done
      done
      pids=()
      for (( pid = batch_start; pid <= index; pid++ )); do
        stem="${transaction_dir}/tags.${pid}.status"
        status_text=""
        [[ -f "$stem" ]] && status_text=$(<"$stem") 2>/dev/null
        [[ "$status_text" == 124 ]] && return 0
      done
    done
  } always {
    for pid in "${pids[@]}"; do
      while builtin kill -0 "$pid" 2>/dev/null; do
        wait "$pid" 2>/dev/null
        (( $? == 127 )) && break
      done
    done
  }
  return 0
}

# Records the stable release tags of one repository from a tag listing into
# the caller's tag_commit, tag_object, sha_version, and repo_versions maps.
# Annotated tags are peeled: the commit of `refs/tags/<name>^{}` replaces the
# tag object. Prereleases and malformed lines are ignored.
# Usage: _dev_actions_record_tags <key> <listing-file>
_dev_actions_record_tags() {
  local key="$1" listing_file="$2"
  local listing="" line="" sha="" ref_name="" name="" map_key="" REPLY=""
  local peel_suffix='^{}'
  local -a version_entries=()
  local -A direct=() peeled=() best=()
  listing=$(<"$listing_file") 2>/dev/null || return 1

  for line in "${(@f)listing}"; do
    [[ "$line" == *$'\t'refs/tags/* ]] || continue
    sha="${line%%$'\t'*}"
    ref_name="${line#*$'\t'refs/tags/}"
    _dev_actions_valid_sha "$sha" || continue
    if [[ "$ref_name" == *"$peel_suffix" ]]; then
      name="${ref_name%$peel_suffix}"
      _dev_actions_valid_ref "$name" || continue
      peeled[$name]="$sha"
    else
      name="$ref_name"
      _dev_actions_valid_ref "$name" || continue
      direct[$name]="$sha"
    fi
  done

  for name in "${(@k)direct}"; do
    map_key="$key|$name"
    tag_object[$map_key]="${direct[$name]}"
    tag_commit[$map_key]="${peeled[$name]:-${direct[$name]}}"
    _dev_actions_version_key "$name" exact || continue
    # One name per version, preferring the v-prefixed spelling.
    if [[ -z "${best[$REPLY]-}" || "$name" == v* ]]; then
      best[$REPLY]="$name"
    fi
  done

  local version_key commit
  for version_key in "${(@k)best}"; do
    name="${best[$version_key]}"
    version_entries+=("$version_key"$'\t'"$name")
    commit="${tag_commit[$key|$name]}"
    map_key="$key|$commit"
    # A commit tagged several times is identified by its highest version.
    if [[ -z "${sha_version[$map_key]-}" ]]; then
      sha_version[$map_key]="$name"
    else
      local previous_key=""
      _dev_actions_version_key "${sha_version[$map_key]}" exact
      previous_key="$REPLY"
      [[ "$version_key" > "$previous_key" ]] && sha_version[$map_key]="$name"
    fi
    map_key="$key|${tag_object[$key|$name]}"
    [[ -n "${sha_version[$map_key]-}" ]] || sha_version[$map_key]="$name"
  done
  repo_versions[$key]="${(pj:\n:)${(@O)version_entries}}"
  return 0
}

# stdout: the epoch second a release was published, or its tag commit's
# committer date when the tag has no release. Values come from bounded gh
# api calls and must be plain integers.
# Usage: _dev_actions_release_epoch <owner> <repo> <tag> <commit>
_dev_actions_release_epoch() {
  local owner="$1" repo="$2" tag_name="$3" commit="$4" epoch=""
  _dev_actions_valid_repository "$owner" "$repo" \
    && _dev_actions_valid_ref "$tag_name" \
    && _dev_actions_valid_sha "$commit" || return 1

  epoch=$(GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
    _dev_run_with_timeout "$DEV_ACTIONS_TIMEOUT" gh api \
    --hostname github.com "repos/${owner}/${repo}/releases/tags/${tag_name}" \
    --jq '.published_at | fromdateiso8601' </dev/null 2>/dev/null) \
    || epoch=""
  epoch="${epoch%%$'\n'*}"
  if [[ "$epoch" != <-> || ${#epoch} -gt 12 ]]; then
    epoch=$(GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
      _dev_run_with_timeout "$DEV_ACTIONS_TIMEOUT" gh api \
      --hostname github.com "repos/${owner}/${repo}/commits/${commit}" \
      --jq '.commit.committer.date | fromdateiso8601' </dev/null 2>/dev/null) \
      || epoch=""
    epoch="${epoch%%$'\n'*}"
  fi
  [[ "$epoch" == <-> && ${#epoch} -le 12 ]] || return 1
  print -r -- "$epoch"
}

# Applies the release-age cooldown to one candidate. Status 0 when it may be
# adopted (also when the cooldown is 0 or gh cannot check it), 1 when it is
# younger than DEV_ACTIONS_COOLDOWN_DAYS with its age in whole days in REPLY,
# and 2 when gh is ready but the age could not be read. Uses the caller's
# gh_state, cooldown_note_shown, and release_epochs.
# Usage: _dev_actions_cooldown_allows <owner> <repo> <tag> <commit>
_dev_actions_cooldown_allows() {
  local owner="$1" repo="$2" tag_name="$3" commit="$4"
  REPLY=""
  (( cooldown_days > 0 )) || return 0

  if [[ "$gh_state" == unknown ]]; then
    gh_state=unavailable
    if _dev_have_command gh \
      && GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
        _dev_run_with_timeout "$DEV_ACTIONS_TIMEOUT" gh auth status \
        --hostname github.com </dev/null >/dev/null 2>&1; then
      gh_state=ready
    fi
  fi
  if [[ "$gh_state" != ready ]]; then
    if (( ! cooldown_note_shown )); then
      cooldown_note_shown=1
      _dev_warn \
        "Release ages were not checked: gh is not installed or not authenticated, so the ${cooldown_days}-day cooldown was not applied."
    fi
    return 0
  fi

  local cache_key="${owner:l}/${repo:l}|$tag_name" epoch=""
  if (( ${+release_epochs[$cache_key]} )); then
    epoch="${release_epochs[$cache_key]}"
  else
    epoch=$(_dev_actions_release_epoch \
      "$owner" "$repo" "$tag_name" "$commit") || epoch="!"
    release_epochs[$cache_key]="$epoch"
  fi
  [[ "$epoch" == <-> ]] || return 2

  local -i age=$(( EPOCHSECONDS - epoch ))
  if (( age < cooldown_days * 86400 )); then
    (( age < 0 )) && age=0
    REPLY=$(( age / 86400 ))
    return 1
  fi
  return 0
}

# --- Planning ---------------------------------------------------------------

# Resolves one remote reference against its repository's release tags.
# Sets reply=(outcome current new-name new-commit kind detail) where outcome is
# planned, current, skipped, or failed and kind is patch, minor, major, or
# pin. Uses the caller's tag maps, repo_state, allow_major, and cooldown state.
# Usage: _dev_actions_resolve <owner> <repo> <ref> <comment-version>
_dev_actions_resolve() {
  local owner="$1" repo="$2" ref="$3" comment="$4"
  local key="${owner:l}/${repo:l}" REPLY=""
  local MATCH MBEGIN MEND
  local -a match=() mbegin=() mend=()
  reply=()

  local state="${repo_state[$key]-}"
  if [[ "$state" == failed:* ]]; then
    reply=(failed "$ref" "" "" "" "${state#failed:}")
    return 0
  fi

  local current_name="" current_key="" floor_key="" in_use=""
  local current_display="$ref"
  local -i pinned=0 current_major=-1
  if _dev_actions_valid_sha "$ref"; then
    pinned=1
    current_display="${ref[1,7]}"
    if [[ -n "$comment" ]] && _dev_actions_version_key "$comment" exact; then
      local tagged_name="" candidate_name
      for candidate_name in "$comment" "${comment#v}" "v${comment#v}"; do
        if [[ -n "${tag_commit[$key|$candidate_name]-}" ]]; then
          tagged_name="$candidate_name"
          break
        fi
      done
      if [[ -z "$tagged_name" ]]; then
        reply=(skipped "$current_display" "" "" "" \
          "version comment $comment is not a release tag")
        return 0
      fi
      if [[ "$ref" != "${tag_commit[$key|$tagged_name]}" \
        && "$ref" != "${tag_object[$key|$tagged_name]}" ]]; then
        reply=(skipped "$current_display" "" "" "" \
          "pinned SHA does not match $tagged_name")
        return 0
      fi
      current_name="$tagged_name"
    else
      current_name="${sha_version[$key|$ref]-}"
      if [[ -z "$current_name" ]]; then
        reply=(skipped "$current_display" "" "" "" \
          "pinned SHA matches no release tag and has no version comment")
        return 0
      fi
    fi
    _dev_actions_version_key "$current_name" exact
    current_key="$REPLY"
    floor_key="$current_key"
    in_use="$ref"
    current_display="$current_name"
  elif [[ "$ref" =~ '^[0-9a-f]{7,39}$' ]]; then
    reply=(skipped "$ref" "" "" "" "abbreviated commit SHA is not resolved")
    return 0
  elif [[ "$ref" =~ '^v?[0-9]+(\.[0-9]+)*[-+]' ]]; then
    # A stable release would be older than the prerelease or build in use.
    reply=(skipped "$ref" "" "" "" "prerelease reference is kept")
    return 0
  elif _dev_actions_version_key "$ref" partial; then
    floor_key="$REPLY"
    in_use="${tag_commit[$key|$ref]-}"
  fi
  [[ -n "$floor_key" ]] && current_major=$(( 10#${floor_key%%.*} ))

  local versions="${repo_versions[$key]-}"
  if [[ -z "$versions" ]]; then
    reply=(skipped "$current_display" "" "" "" "no release tags")
    return 0
  fi

  local entry version_key name commit held_name="" major_name=""
  local -i version_major=0 cooldown_status=0 held_age=0
  local selected_name="" selected_commit="" selected_key=""
  for entry in "${(@f)versions}"; do
    version_key="${entry%%$'\t'*}"
    name="${entry#*$'\t'}"
    [[ -n "$floor_key" && "$version_key" < "$floor_key" ]] && break
    version_major=$(( 10#${version_key%%.*} ))
    if (( current_major >= 0 && version_major != current_major \
      && ! allow_major )); then
      [[ -n "$major_name" ]] || major_name="$name"
      continue
    fi
    commit="${tag_commit[$key|$name]}"
    if (( pinned )) && [[ "$version_key" == "$current_key" ]]; then
      break
    fi
    if [[ "$commit" != "$in_use" ]]; then
      cooldown_status=0
      _dev_actions_cooldown_allows "$owner" "$repo" "$name" "$commit" \
        || cooldown_status=$?
      if (( cooldown_status == 1 )); then
        if [[ -z "$held_name" ]]; then
          held_name="$name"
          held_age="$REPLY"
        fi
        continue
      fi
      if (( cooldown_status == 2 )); then
        reply=(failed "$current_display" "" "" "" \
          "release age of $name could not be checked")
        return 0
      fi
    fi
    selected_name="$name"
    selected_commit="$commit"
    selected_key="$version_key"
    break
  done

  local note=""
  if [[ -n "$held_name" ]]; then
    _dev_count_noun "$held_age" day
    note="$held_name is $REPLY old; cooldown is $cooldown_days days"
  elif [[ -n "$major_name" ]]; then
    note="$major_name needs --major"
  fi

  if [[ -z "$selected_name" ]]; then
    if (( pinned )); then
      reply=(current "$current_display" "" "" "" "$note")
    elif [[ -n "$held_name" ]]; then
      reply=(skipped "$current_display" "" "" "" \
        "every eligible release is in its cooldown ($note)")
    else
      reply=(skipped "$current_display" "" "" "" \
        "no stable release matches $ref")
    fi
    return 0
  fi

  local kind="pin"
  local -i selected_major=$(( 10#${selected_key%%.*} ))
  if (( current_major >= 0 && selected_major > current_major )); then
    kind="major"
  elif (( pinned )); then
    if [[ "${selected_key%.*}" != "${current_key%.*}" ]]; then
      kind="minor"
    else
      kind="patch"
    fi
  fi
  reply=(planned "$current_display" "$selected_name" "$selected_commit" \
    "$kind" "$note")
}

# --- Validation tools -------------------------------------------------------

# Runs one installed workflow validator on the changed files. Status 0 when it
# passes, 1 when it reports findings, and 3 when it is not installed. With
# `quiet`, the output is discarded; otherwise it is captured and replayed only
# on failure.
# Usage: _dev_actions_validate <actionlint|zizmor> <quiet|shown> <file>...
_dev_actions_validate() {
  local tool_name="$1" mode="$2"
  shift 2
  (( $# > 0 )) || return 0
  _dev_have_command "$tool_name" || return 3
  local -a tool_arguments=()
  case "$tool_name" in
    actionlint) tool_arguments=(-no-color) ;;
    zizmor) tool_arguments=(--offline) ;;
    *) return 2 ;;
  esac
  if [[ "$mode" == quiet ]]; then
    _dev_run_with_timeout 300 "$tool_name" "${tool_arguments[@]}" -- "$@" \
      </dev/null >/dev/null 2>&1 && return 0
    return 1
  fi
  local REPLY
  _dev_command_display "$tool_name" "${tool_arguments[@]}" "$@"
  _dev_run_captured "$REPLY" \
    _dev_run_with_timeout 300 "$tool_name" "${tool_arguments[@]}" -- "$@" \
    && return 0
  return 1
}

# --- Rollback ---------------------------------------------------------------

# Restores every file this invocation published, newest first, from its
# private original snapshot through the same compare-and-swap publication.
# A file changed by someone else after publication is never overwritten; its
# invocation backup is named instead. Uses the caller's published_indexes,
# file maps, and backups. Status 0 when every file was restored.
_dev_actions_rollback() {
  local -i index=0 failed=0 position=0
  local relative_path="" REPLY=""
  for (( position = ${#published_indexes[@]}; position >= 1; position-- )); do
    index="${published_indexes[position]}"
    relative_path="${change_files[index]}"
    if _dev_update_publish_snapshot \
      "${change_originals[index]}" "${project_root}/${relative_path}" \
      "${change_applied[index]}" "${change_original_fingerprints[index]}" \
      && [[ "${REPLY##*:}" == "${change_initial[index]##*:}" ]]; then
      _dev_info "Restored ${relative_path#.github/}."
    else
      failed=1
      _dev_error "Could not restore ${relative_path}."
      [[ -n "${change_backups[index]-}" ]] \
        && _dev_info "Recovery backup: ${change_backups[index]}"
    fi
  done
  published_indexes=()
  return $failed
}

# --- Plan construction ------------------------------------------------------
# These stages share the dynamically scoped state that dev-update-actions
# declares, as the dev-update-all step helpers do. Each returns non-zero to
# stop the command, after printing its own diagnostic.

# Reads the scanner records into file_digests and references. Every field is
# validated again; a remote value that fails a pattern becomes invalid.
# Usage: _dev_actions_read_scan <scanner-output>
_dev_actions_read_scan() {
  local scan_output="$1" record="" scanned_path=""
  local -a fields=()
  local MATCH MBEGIN MEND
  local -a match=() mbegin=() mend=()
  for record in "${(@f)scan_output}"; do
    [[ -n "$record" ]] || continue
    fields=("${(@ps:\t:)record}")
    case "${fields[1]}" in
      F)
        (( ${#fields[@]} == 3 )) && [[ "${fields[2]}" == <-> \
          && "${fields[3]}" =~ '^[0-9a-f]{64}$' ]] || {
          _dev_error "The workflow scanner returned an invalid record."
          return 1
        }
        file_digests[${fields[2]}]="${fields[3]}"
        ;;
      R)
        (( ${#fields[@]} == 10 )) && [[ "${fields[2]}" == <-> \
          && "${fields[3]}" == <-> \
          && "${fields[4]}" == (remote|local|docker|invalid) ]] \
          && (( fields[2] >= 1 && fields[2] <= ${#scanned_files[@]} )) || {
          _dev_error "The workflow scanner returned an invalid record."
          return 1
        }
        if [[ "${fields[4]}" == remote ]]; then
          scanned_path="${fields[7]}"
          [[ "$scanned_path" == - ]] && scanned_path=""
          if ! _dev_actions_valid_repository "${fields[5]}" "${fields[6]}" \
            || ! _dev_actions_valid_path "$scanned_path" \
            || ! _dev_actions_valid_ref "${fields[8]}"; then
            fields[4]=invalid
          fi
          if [[ "${fields[9]}" != - ]] \
            && ! _dev_actions_version_key "${fields[9]}" partial; then
            fields[9]=-
          fi
        fi
        references+=("${(pj:\t:)fields[2,10]}")
        ;;
      *)
        _dev_error "The workflow scanner returned an invalid record."
        return 1
        ;;
    esac
  done
  return 0
}

# Lists the release tags of each distinct repository (owner and repository
# names are case-insensitive on GitHub) and records them in the tag maps.
# A failed query marks its repository failed in repo_state with the reason.
# Status: the interrupt status, or 0.
_dev_actions_collect_tags() {
  local reference="" repo_key="" REPLY=""
  local -a fields=()
  for reference in "${references[@]}"; do
    fields=("${(@ps:\t:)reference}")
    [[ "${fields[3]}" == remote ]] || continue
    repo_key="${fields[4]:l}/${fields[5]:l}"
    (( ${+repo_owner[$repo_key]} )) && continue
    repo_owner[$repo_key]="${fields[4]}"
    repo_name[$repo_key]="${fields[5]}"
    repo_keys+=("$repo_key")
  done
  (( ${#repo_keys[@]} > 0 )) || return 0

  _dev_count_noun "${#repo_keys[@]}" "action repository" \
    "action repositories"
  _dev_info "Listing release tags of $REPLY on github.com..."
  _dev_actions_query_repositories
  if (( interrupted )); then
    _dev_warn "Interrupted while listing tags; no file was modified."
    return $interrupted
  fi

  local listing_file="" error_line="" status_text=""
  local -i query_index=0 query_status=0
  for repo_key in "${repo_keys[@]}"; do
    (( ++query_index ))
    listing_file="${transaction_dir}/tags.${query_index}"
    status_text=""
    [[ -f "${listing_file}.status" && ! -L "${listing_file}.status" ]] \
      && status_text=$(<"${listing_file}.status") 2>/dev/null
    if [[ -z "$status_text" ]]; then
      repo_state[$repo_key]="failed:not queried after a github.com timeout"
      continue
    fi
    query_status=1
    [[ "$status_text" == <-> && ${#status_text} -le 3 ]] \
      && query_status=$(( 10#$status_text ))
    if (( query_status == 0 )) \
      && _dev_actions_record_tags "$repo_key" "$listing_file"; then
      repo_state[$repo_key]=ok
      continue
    fi
    (( query_status == 0 )) && query_status=1
    if (( query_status == 124 )); then
      repo_state[$repo_key]="failed:tag query timed out"
    else
      repo_state[$repo_key]="failed:tag query failed (status $query_status)"
    fi
    _dev_warn \
      "Could not list the tags of ${repo_owner[$repo_key]}/${repo_name[$repo_key]} (status $query_status)."
    error_line=""
    [[ -f "${listing_file}.err" && ! -L "${listing_file}.err" ]] \
      && error_line=$(command head -c 4096 -- "${listing_file}.err" 2>/dev/null)
    error_line="${${error_line%%$'\n'*}//$'\r'/}"
    [[ -n "$error_line" ]] && _dev_dim "${error_line[1,200]}"
  done
  return 0
}

# Resolves each distinct reference once; equal references in several files
# share one group. Fills group_order, group_result (display, then the
# _dev_actions_resolve reply), group_files, group_count, and the planned line
# edits per file in file_edits, file_edit_count, and change_order.
# Status: the interrupt status, or 0.
_dev_actions_plan_references() {
  local reference="" group_key="" relative_file="" action_display=""
  local action_path="" comment_version="" file_display="" action_value=""
  local -i file_index=0 line_number=0
  local -a fields=() resolved=()
  for reference in "${references[@]}"; do
    fields=("${(@ps:\t:)reference}")
    file_index="${fields[1]}"
    line_number="${fields[2]}"
    relative_file="${scanned_files[file_index]}"
    action_path="${fields[6]}"
    [[ "$action_path" == - ]] && action_path=""
    if [[ "${fields[3]}" == remote ]]; then
      action_display="${fields[4]}/${fields[5]}${action_path:+/$action_path}"
      group_key="remote|${fields[4]:l}/${fields[5]:l}|${action_path}|${fields[7]}|${fields[8]}"
    else
      action_display="${fields[9]}"
      group_key="${fields[3]}|${fields[9]}"
    fi

    if (( ! ${+group_result[$group_key]} )); then
      group_order+=("$group_key")
      case "${fields[3]}" in
        remote)
          comment_version="${fields[8]}"
          [[ "$comment_version" == - ]] && comment_version=""
          _dev_actions_resolve "${fields[4]}" "${fields[5]}" \
            "${fields[7]}" "$comment_version"
          ;;
        local) reply=(skipped - "" "" "" "local action") ;;
        docker) reply=(skipped - "" "" "" "Docker image") ;;
        *) reply=(skipped - "" "" "" "invalid reference; not queried") ;;
      esac
      if (( interrupted )); then
        _dev_warn "Interrupted while planning; no file was modified."
        return $interrupted
      fi
      group_result[$group_key]="${action_display}"$'\t'"${(pj:\t:)reply}"
    fi

    # Paths are shown relative to .github; each file is listed once a row.
    file_display="${relative_file#.github/}"
    if [[ $'\n'"${group_files[$group_key]-}"$'\n' \
      != *$'\n'"$file_display"$'\n'* ]]; then
      group_files[$group_key]="${group_files[$group_key]:+${group_files[$group_key]}$'\n'}$file_display"
    fi
    group_count[$group_key]=$(( ${group_count[$group_key]:-0} + 1 ))

    resolved=("${(@ps:\t:)group_result[$group_key]}")
    [[ "${resolved[2]}" == planned ]] || continue
    action_value="${fields[4]}/${fields[5]}${action_path:+/$action_path}"
    (( ${+file_edits[$file_index]} )) || change_order+=("$file_index")
    file_edits[$file_index]+="${line_number}"$'\t'"${action_value}@${fields[7]}"$'\t'"${action_value}@${resolved[5]}"$'\t'"${resolved[4]}"$'\n'
    file_edit_count[$file_index]=$(( ${file_edit_count[$file_index]:-0} + 1 ))
  done
  return 0
}

# Builds each changed file in the private workspace from a fingerprinted
# snapshot whose digest must equal the scanned one, so the plan shown is
# exactly what publication applies. Fills the change_* arrays.
_dev_actions_build_candidates() {
  local relative_file="" edits_file="" REPLY=""
  local -i file_index=0 change_index=0
  for file_index in "${change_order[@]}"; do
    (( ++change_index ))
    relative_file="${scanned_files[file_index]}"
    change_files[change_index]="$relative_file"
    change_counts[change_index]="${file_edit_count[$file_index]}"
    _dev_update_file_fingerprint "${project_root}/${relative_file}" || {
      _dev_error "Could not fingerprint ${relative_file}."
      return 1
    }
    change_initial[change_index]="$REPLY"
    if [[ "${REPLY##*:}" != "${file_digests[$file_index]}" ]]; then
      _dev_error "${relative_file} changed during planning; refusing to continue."
      return 1
    fi
    change_originals[change_index]="${transaction_dir}/original.${change_index}"
    change_candidates[change_index]="${transaction_dir}/candidate.${change_index}"
    _dev_update_copy_snapshot "${project_root}/${relative_file}" \
      "${change_originals[change_index]}" \
      "${change_initial[change_index]}" || {
      _dev_error "Could not snapshot ${relative_file} for planning."
      return 1
    }
    change_original_fingerprints[change_index]="$REPLY"
    edits_file="${transaction_dir}/edits.${change_index}"
    print -rn -- "${file_edits[$file_index]}" >| "$edits_file" || return 1
    _dev_actions_python rewrite "${change_originals[change_index]}" \
      "${change_candidates[change_index]}" "$edits_file" || {
      _dev_error "Could not build the updated ${relative_file} safely."
      return 1
    }
    _dev_update_file_fingerprint "${change_candidates[change_index]}" || {
      _dev_error "Could not fingerprint the updated ${relative_file}."
      return 1
    }
    change_candidate_fingerprints[change_index]="$REPLY"
  done
  _dev_update_workspace_validate \
    "$transaction_root" "$transaction_root_identity" \
    "$transaction_dir" "$transaction_dir_identity" || {
    _dev_error "The actions update workspace changed during planning."
    return 1
  }
}

# Prints the plan: one numbered row per distinct change with its notes, then
# the references that stay as they are when a reason is worth showing, then
# the count of current references. Sets planned_references,
# failed_references, and change_details.
_dev_actions_print_plan() {
  local group_key="" files_text="" plan_note="" note_text="" REPLY=""
  local -a plan_rows=() unchanged_rows=() plan_notes=() resolved=()
  local -A note_rows=()
  local -i current_references=0 plan_number=0
  for group_key in "${group_order[@]}"; do
    resolved=("${(@ps:\t:)group_result[$group_key]}")
    files_text="${(pj:, :)${(@f)group_files[$group_key]}}"
    case "${resolved[2]}" in
      planned)
        (( ++plan_number ))
        planned_references=$(( planned_references + group_count[$group_key] ))
        plan_rows+=("$plan_number"$'\t'"${resolved[1]}"$'\t'"${resolved[3]}"$'\t'"${resolved[4]}"$'\t'"${resolved[6]}"$'\t'"$files_text")
        change_details+=("${resolved[1]} ${resolved[3]} → ${resolved[4]}")
        # One note line per distinct note, naming every row it applies to.
        if [[ -n "${resolved[7]-}" ]]; then
          note_text="${resolved[1]}: ${resolved[7]}"
          (( ${+note_rows[$note_text]} )) || plan_notes+=("$note_text")
          note_rows[$note_text]+="${note_rows[$note_text]:+, }$plan_number"
        fi
        ;;
      current)
        current_references=$(( current_references + group_count[$group_key] ))
        [[ -n "${resolved[7]-}" ]] \
          && unchanged_rows+=("${resolved[1]}"$'\t'"${resolved[3]}"$'\t'current$'\t'"${resolved[7]}")
        ;;
      failed)
        failed_references=$(( failed_references + group_count[$group_key] ))
        unchanged_rows+=("${resolved[1]}"$'\t'"${resolved[3]}"$'\t'failed$'\t'"${resolved[7]} (${files_text})")
        ;;
      *)
        unchanged_rows+=("${resolved[1]}"$'\t'"${resolved[3]}"$'\t'skipped$'\t'"${resolved[7]} (${files_text})")
        ;;
    esac
  done

  if (( ${#plan_rows[@]} > 0 )); then
    _dev_table $'#\tAction\tCurrent\tNew\tKind\tFiles' "${plan_rows[@]}"
    for plan_note in "${plan_notes[@]}"; do
      if [[ "${note_rows[$plan_note]}" == *,* ]]; then
        _dev_dim "Rows ${note_rows[$plan_note]} · $plan_note"
      else
        _dev_dim "Row ${note_rows[$plan_note]} · $plan_note"
      fi
    done
  fi
  if (( ${#unchanged_rows[@]} > 0 )); then
    _dev_table --outcome-column 3 $'Action\tCurrent\tResult\tDetail' \
      "${unchanged_rows[@]}"
  fi
  if (( current_references > 0 )); then
    _dev_count_noun "$current_references" "action reference"
    _dev_info "$REPLY already at the newest allowed release."
  fi
}

# Prints the counted verdict for references that could not be checked and
# the retry command outside an aggregate step, and marks a partial failure
# for the enclosing timer when other references were not failures. Uses the
# caller's failed_references, references, and failure_counts.
# Usage: _dev_actions_failure_verdict <subject> <retry-command>
_dev_actions_failure_verdict() {
  local subject="$1" retry_command="$2"
  if (( failed_references < ${#references[@]} )); then
    _dev_error "$subject completed with partial failures: $failure_counts."
    if (( ${+functions[_zdx_timed_mark_partial]} )); then
      _zdx_timed_mark_partial 2>/dev/null || true
    fi
  else
    _dev_error "$subject failed: $failure_counts."
  fi
  _dev_step_quiet || _dev_info "Retry after resolving the errors above: $retry_command"
}

# --- Authorized transaction -------------------------------------------------

# Applies the authorized plan: revalidates the project, workspace, private
# originals, candidates, and live files; runs the installed validators on the
# original files; backs up and publishes each file; validates the published
# files; and rolls every file back when a validator newly fails, publication
# fails, or the run is interrupted. Reports the step result and returns the
# command status.
_dev_actions_apply() {
  local relative_file="" current_project_identity="" REPLY=""
  local -i change_index=0
  current_project_identity=$(
    _dev_directory_identity "$project_root" "project directory"
  ) || return 1
  if [[ "$current_project_identity" != "$project_identity" \
    || "${PWD:A}" != "$project_root" ]]; then
    _dev_error "The project context changed after authorization."
    return 1
  fi
  _dev_update_workspace_validate \
    "$transaction_root" "$transaction_root_identity" \
    "$transaction_dir" "$transaction_dir_identity" || {
    _dev_error "The actions update workspace changed after authorization."
    return 1
  }
  for (( change_index = 1; change_index <= ${#change_files[@]}; change_index++ )); do
    relative_file="${change_files[change_index]}"
    _dev_update_file_fingerprint "${change_candidates[change_index]}" \
      && [[ "$REPLY" == "${change_candidate_fingerprints[change_index]}" ]] \
      && _dev_update_file_fingerprint "${change_originals[change_index]}" \
      && [[ "$REPLY" == "${change_original_fingerprints[change_index]}" ]] \
      && _dev_update_file_fingerprint "${project_root}/${relative_file}" \
      && [[ "$REPLY" == "${change_initial[change_index]}" ]] || {
      _dev_error \
        "${relative_file} or its private plan changed after authorization; nothing was changed."
      return 1
    }
  done

  # A validator that already fails on the original files cannot tell new
  # findings from old ones, so only a pass-to-fail change rolls back. Status
  # 3 means not installed and 4 means that no file of its kind changed;
  # actionlint lints workflows, not composite action metadata.
  local -a workflow_targets=() validated_targets=("${change_files[@]}")
  for relative_file in "${change_files[@]}"; do
    [[ "$relative_file" == .github/workflows/* ]] \
      && workflow_targets+=("$relative_file")
  done
  local -i actionlint_before=4 zizmor_before=0
  if (( ${#workflow_targets[@]} > 0 )); then
    actionlint_before=0
    _dev_actions_validate actionlint quiet "${workflow_targets[@]}" \
      || actionlint_before=$?
  fi
  _dev_actions_validate zizmor quiet "${validated_targets[@]}" \
    || zizmor_before=$?

  _dev_count_noun "${#change_files[@]}" file
  _dev_info "Backing up $REPLY..."
  for (( change_index = 1; change_index <= ${#change_files[@]}; change_index++ )); do
    relative_file="${change_files[change_index]}"
    reply=()
    _dev_update_prepare_file_backup "$relative_file" \
      "${change_initial[change_index]}" || {
      _dev_error "Could not back up ${relative_file}; nothing was changed."
      return 1
    }
    change_backups[change_index]="${reply[1]}"
  done

  local -i publish_failed=0
  for (( change_index = 1; change_index <= ${#change_files[@]}; change_index++ )); do
    relative_file="${change_files[change_index]}"
    if (( interrupted )); then
      publish_failed=1
      break
    fi
    if ! _dev_update_publish_snapshot \
      "${change_candidates[change_index]}" \
      "${project_root}/${relative_file}" \
      "${change_initial[change_index]}" \
      "${change_candidate_fingerprints[change_index]}"; then
      _dev_error "Could not publish ${relative_file} atomically."
      publish_failed=1
      break
    fi
    change_applied[change_index]="$REPLY"
    published_indexes+=("$change_index")
    _dev_count_noun "${change_counts[change_index]}" reference
    _dev_success "${relative_file#.github/}: $REPLY updated"
  done
  (( interrupted )) && publish_failed=1
  if (( publish_failed )); then
    if (( ${#published_indexes[@]} > 0 )); then
      _dev_warn "Restoring the files already published by this run..."
      if ! _dev_actions_rollback; then
        _dev_report_result failed "publication failed; rollback incomplete"
        return $(( interrupted ? interrupted : 1 ))
      fi
    fi
    _dev_report_result failed "publication failed; files restored"
    return $(( interrupted ? interrupted : 1 ))
  fi

  local -a validation_failures=() preexisting_findings=() tool_targets=()
  local tool_name=""
  local -i before_status=0 after_status=0
  for tool_name in actionlint zizmor; do
    if [[ "$tool_name" == actionlint ]]; then
      before_status=$actionlint_before
      tool_targets=("${workflow_targets[@]}")
    else
      before_status=$zizmor_before
      tool_targets=("${validated_targets[@]}")
    fi
    (( before_status == 4 )) && continue
    if (( before_status == 3 )); then
      _dev_dim "$tool_name is not installed; its validation was skipped."
      continue
    fi
    after_status=0
    _dev_actions_validate "$tool_name" shown "${tool_targets[@]}" \
      || after_status=$?
    (( after_status == 0 )) && continue
    if (( before_status == 0 )); then
      validation_failures+=("$tool_name")
    else
      preexisting_findings+=("$tool_name")
    fi
  done

  if (( interrupted )); then
    _dev_warn "Interrupted during validation; restoring the originals."
    _dev_actions_rollback
    return $interrupted
  fi
  if (( ${#validation_failures[@]} > 0 )); then
    _dev_error \
      "${(j: and :)validation_failures} failed on the updated files; restoring the originals."
    if ! _dev_actions_rollback; then
      _dev_report_result failed \
        "${(j: and :)validation_failures} failed; rollback incomplete"
      return 1
    fi
    _dev_report_result failed \
      "${(j: and :)validation_failures} failed; changes rolled back"
    return 1
  fi
  published_indexes=()

  if (( ${#preexisting_findings[@]} > 0 )); then
    _dev_warn \
      "${(j: and :)preexisting_findings} reported findings that the original files already had; the update was kept."
    _dev_report_result failed \
      "$planned_label updated; ${(j: and :)preexisting_findings} reported existing findings"
    return 1
  fi
  if (( failed_references > 0 )); then
    _dev_actions_failure_verdict "GitHub Actions update" \
      "dev-menu dev-update-actions"
    _dev_report_result failed "$planned_label updated; $failure_detail"
    return 1
  fi
  _dev_report_result updated "$planned_label ($change_summary)" \
    "GitHub Actions update completed: $planned_label updated."
  return 0
}

# --- Public command ---------------------------------------------------------

_dev_update_actions_usage() {
  print -u2 -r -- "Usage: dev-update-actions [--dry-run] [--yes] [--major]"
  print -u2 -r -- \
    "  Pin and update the GitHub Actions used by .github/workflows/*.yml and"
  print -u2 -r -- \
    "  .github/actions/**/action.yml to a release commit SHA with a version comment."
  print -u2 -r -- "  --dry-run       Show the plan without changing any file."
  print -u2 -r -- "  --yes, -y       Apply the plan without the confirmation prompt."
  print -u2 -r -- \
    "  --major         Also allow newer major versions; the plan marks them."
  print -u2 -r -- \
    "  Tags are listed with git ls-remote over HTTPS; no token is needed."
  print -u2 -r -- \
    "  With an authenticated gh, releases younger than DEV_ACTIONS_COOLDOWN_DAYS"
  print -u2 -r -- "  (default 7) are held back."
}

# dev-update-actions
#   Arguments: --dry-run | --yes | --major | --help
#   stdout:    none. The plan, results, and diagnostics go to stderr.
#   Effects:   lists the release tags of every referenced action repository
#              on github.com, plans SHA-pinned updates within the current
#              major version (or across majors with --major), builds the
#              rewritten files privately, confirms, backs up each file it
#              changes, publishes them atomically, then runs actionlint and
#              zizmor --offline when installed. A validator that passed before
#              the update and fails after it rolls every file back.
#   Requires:  git, Python 3.11+ (update fingerprints), network access to
#              github.com; gh is optional for the release-age cooldown.
#   Status:    0 on success, cancellation, or nothing to update; 1 when a
#              reference could not be checked, validation or publication
#              failed, or a validator reported findings; 2 on invalid
#              arguments; the signal status after an interruption.
dev-update-actions() {
  emulate -L zsh
  (( ${+_DEV_RUN_PYTHON} )) || local _DEV_RUN_PYTHON=""

  local -i dry_run=0 auto_yes=0 allow_major=0
  while (( $# > 0 )); do
    case "$1" in
      -h|--help) _dev_update_actions_usage; return 0 ;;
      --dry-run) dry_run=1 ;;
      --yes|-y) auto_yes=1 ;;
      --major) allow_major=1 ;;
      *)
        _dev_error "Unknown option: $1"
        _dev_update_actions_usage
        return 2
        ;;
    esac
    shift
  done

  _dev_validate_bounded_integer DEV_ACTIONS_COOLDOWN_DAYS \
    "$DEV_ACTIONS_COOLDOWN_DAYS" 0 90 || return 1
  _dev_validate_bounded_integer DEV_ACTIONS_TIMEOUT \
    "$DEV_ACTIONS_TIMEOUT" 1 300 || return 1
  local -i cooldown_days=$(( 10#$DEV_ACTIONS_COOLDOWN_DAYS ))

  _dev_header "Updating GitHub Actions"
  if (( dry_run )) && ! _dev_step_quiet; then
    _dev_warn "DRY-RUN — no files will be modified."
  fi

  local project_root="${PWD:A}" REPLY=""
  if [[ ! -e .github/workflows && ! -L .github/workflows \
    && ! -e .github/actions && ! -L .github/actions ]]; then
    _dev_report_result skipped "no .github/workflows" \
      "No GitHub Actions workflows found in this project."
    return 0
  fi
  local github_directory
  for github_directory in .github .github/workflows .github/actions; do
    [[ -e "$github_directory" || -L "$github_directory" ]] || continue
    if [[ -L "$github_directory" || ! -d "$github_directory" ]]; then
      _dev_error "Refusing a symlinked or non-directory ${github_directory}."
      return 1
    fi
  done

  _dev_require_command git || return 1
  _dev_require_python_toml "to fingerprint and rewrite workflow files" \
    || return 1
  zmodload -F zsh/datetime p:EPOCHSECONDS 2>/dev/null || {
    _dev_error "The zsh/datetime module is required for the release cooldown."
    return 1
  }

  local project_identity
  project_identity=$(
    _dev_directory_identity "$project_root" "project directory"
  ) || return 1

  # Workflow file names do not matter; GitHub reads every *.yml and *.yaml
  # directly below .github/workflows. Composite actions may nest. Globs never
  # follow a symlinked file or directory.
  local -a workflow_files=() composite_files=() scanned_files=()
  workflow_files=(.github/workflows/*.(yml|yaml)(N.D))
  [[ -d .github/actions ]] \
    && composite_files=(.github/actions/**/action.(yml|yaml)(N.D))
  scanned_files=("${workflow_files[@]}" "${composite_files[@]}")
  if (( ${#scanned_files[@]} == 0 )); then
    _dev_report_result skipped "no workflow files" \
      "No workflow or composite action files were found."
    return 0
  fi
  if (( ${#scanned_files[@]} > _DEV_ACTIONS_MAX_FILES )); then
    _dev_error \
      "Refusing to inspect more than $_DEV_ACTIONS_MAX_FILES workflow files."
    return 1
  fi

  setopt LOCAL_OPTIONS LOCAL_TRAPS NO_MONITOR
  local -i interrupted=0
  trap 'interrupted=130' INT
  trap 'interrupted=143' TERM

  # Shared state for the stages above.
  local -i previous_auto_yes=$_DEV_AUTO_YES
  local transaction_root="" transaction_root_identity=""
  local transaction_dir="" transaction_dir_identity=""
  local -a reply=() published_indexes=() references=() repo_keys=()
  local -A file_digests=() repo_owner=() repo_name=() repo_state=()
  local -A tag_commit=() tag_object=() sha_version=() repo_versions=()
  local -A release_epochs=() group_result=() group_files=() group_count=()
  local -A file_edits=() file_edit_count=()
  local -a group_order=() change_order=() change_details=()
  local -a change_files=() change_initial=() change_originals=()
  local -a change_original_fingerprints=() change_candidates=()
  local -a change_candidate_fingerprints=() change_applied=()
  local -a change_backups=() change_counts=()
  local gh_state=unknown
  local -i cooldown_note_shown=0 planned_references=0 failed_references=0

  {
    (( auto_yes )) && _DEV_AUTO_YES=1

    _dev_count_noun "${#workflow_files[@]}" "workflow file"
    local workflow_label="$REPLY"
    _dev_count_noun "${#composite_files[@]}" "composite action"
    _dev_info "Scanning $workflow_label and $REPLY..."

    local -a absolute_files=("${project_root}/${^scanned_files[@]}")
    local scan_output=""
    scan_output=$(_dev_actions_python scan "${absolute_files[@]}") || {
      _dev_error \
        "Could not read the workflow files safely (regular files up to 1 MiB)."
      return 1
    }
    _dev_actions_read_scan "$scan_output" || return 1
    if (( ${#references[@]} == 0 )); then
      _dev_report_result current "no action references" \
        "The workflow files reference no actions."
      return 0
    fi

    _dev_update_workspace_create || return 1
    transaction_root="${reply[1]}"
    transaction_root_identity="${reply[2]}"
    transaction_dir="${reply[3]}"
    transaction_dir_identity="${reply[4]}"

    _dev_actions_collect_tags || return $?
    _dev_actions_plan_references || return $?
    _dev_actions_build_candidates || return 1
    _dev_actions_print_plan

    local planned_label="" failed_label="" total_label=""
    _dev_count_noun "$planned_references" "action reference"
    planned_label="$REPLY"
    _dev_count_noun "$failed_references" "action reference"
    failed_label="$REPLY"
    _dev_count_noun "${#references[@]}" "action reference"
    total_label="$REPLY"
    local failure_detail="$failed_label could not be checked"
    local failure_counts="$failed_references of $total_label failed"
    local change_summary="${(j:, :)change_details[1,3]}"
    (( ${#change_details[@]} > 3 )) && change_summary+=", …"

    if (( dry_run )); then
      if (( planned_references > 0 )); then
        _dev_info "Dry run: $planned_label planned; nothing was changed."
      fi
      if (( failed_references > 0 )); then
        _dev_actions_failure_verdict "GitHub Actions dry run" \
          "dev-menu dev-update-actions --dry-run"
        local failed_detail="$failure_detail"
        (( planned_references > 0 )) \
          && failed_detail+="; $planned_label planned"
        _dev_report_result failed "$failed_detail"
        return 1
      fi
      if (( planned_references > 0 )); then
        _dev_report_result planned "$planned_label ($change_summary)" ""
      else
        _dev_report_result current "no action reference needs an update" \
          "No action reference needs an update."
      fi
      return 0
    fi

    if (( planned_references == 0 )); then
      if (( failed_references > 0 )); then
        _dev_actions_failure_verdict "GitHub Actions update" \
          "dev-menu dev-update-actions"
        _dev_report_result failed "$failure_detail"
        return 1
      fi
      _dev_report_result current "no action reference needs an update" \
        "No action reference needs an update."
      return 0
    fi

    if (( interrupted )); then
      _dev_warn "Interrupted during planning; no file was modified."
      return $interrupted
    fi
    local apply_outcome=""
    apply_outcome=$(_dev_confirm_outcome "Update $planned_label?")
    case "$apply_outcome" in
      confirmed) ;;
      unavailable)
        _dev_error \
          "Updating GitHub Actions needs confirmation; pass --yes in a non-interactive shell."
        return 1
        ;;
      *)
        _dev_info "Cancelled: nothing was changed."
        return 0
        ;;
    esac

    _dev_actions_apply
    return $?
  } always {
    if (( ${#published_indexes[@]} > 0 )); then
      _dev_warn "Restoring the files already published by this run..."
      _dev_actions_rollback || true
    fi
    _DEV_AUTO_YES=$previous_auto_yes
    _dev_update_workspace_cleanup \
      "$transaction_root" "$transaction_root_identity" \
      "$transaction_dir" "$transaction_dir_identity"
  }
}

typeset -g _DEV_UPDATE_ACTIONS_SOURCED=1
