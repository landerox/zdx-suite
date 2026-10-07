#!/usr/bin/env zsh
# =============================================================================
# Git Pull Requests: repository-bound pull request creation and checkout
# =============================================================================
#
# Loaded by git-menu.zsh after git-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_GIT_PR_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset -gA _GIT_GH_REPO=()

_git_gh_usage() {
  case "${1:-}" in
    git-pr-create)
      print -u2 -r -- \
        "Usage: git-pr-create [--base <branch>]"
      print -u2 -r -- \
        "                     [--title <text> [--body <text>] | --fill]"
      print -u2 -r -- \
        "                     [--draft] [--dry-run] [--yes]"
      print -u2 -r -- \
        "Create a PR only after its repository, refs, and commit OIDs are fixed."
      ;;
    git-pr-checkout)
      print -u2 -r -- "Usage: git-pr-checkout [number]"
      print -u2 -r -- \
        "Checkout an explicitly numbered or selected PR in detached mode."
      ;;
  esac
  print -u2 -r -- "       ${1:-command} --help"
}

_git_gh_help_requested() {
  local command_name="$1"
  shift
  if (( $# == 1 )) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
    _git_gh_usage "$command_name"
    return 0
  fi
  return 1
}

_git_gh_repo_context() {
  _git_require_repo || return 1
  _git_check_gh || return 1

  local repo_output repo_id name_with_owner repo_url host remainder
  repo_output=$(command gh repo view \
    --json id,nameWithOwner,url \
    --template '{{.id}}{{"\t"}}{{.nameWithOwner}}{{"\t"}}{{.url}}' \
    2>/dev/null) || {
    _git_error "Unable to resolve the GitHub repository."
    return 1
  }
  repo_id="${repo_output%%$'\t'*}"
  remainder="${repo_output#*$'\t'}"
  name_with_owner="${remainder%%$'\t'*}"
  repo_url="${remainder#*$'\t'}"
  [[ "$name_with_owner" =~ \
    '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' \
    && -n "$repo_id" \
    && "$repo_id" != *$'\t'* \
    && "$repo_id" != *$'\n'* \
    && "$repo_url" == https://*/*/* ]] || {
    _git_error "GitHub returned an invalid repository identity."
    return 1
  }
  remainder="${repo_url#https://}"
  host="${remainder%%/*}"
  [[ "$host" =~ '^[A-Za-z0-9.-]+$' ]] || {
    _git_error "GitHub returned an invalid repository host."
    return 1
  }

  _GIT_GH_REPO=(
    id "$repo_id"
    host "$host"
    name "$name_with_owner"
    target "$host/$name_with_owner"
    url "$repo_url"
  )
}

_git_gh_require_same_repo() {
  local current_id
  current_id=$(command gh repo view \
    --repo "${_GIT_GH_REPO[target]}" \
    --json id \
    --template '{{.id}}' 2>/dev/null) || {
    _git_error "Unable to revalidate the GitHub repository."
    return 1
  }
  [[ "$current_id" == "${_GIT_GH_REPO[id]}" ]] || {
    _git_error "The GitHub repository identity changed; retry."
    return 1
  }
}

_git_gh_pick_pr() {
  local state="$1"
  local pr_output
  pr_output=$(command gh pr list \
    --repo "${_GIT_GH_REPO[target]}" \
    --state "$state" \
    --limit 100 \
    --json id,number,title,state,url,headRefName,headRefOid \
    --template \
      '{{range .}}{{.id}}{{"\t"}}{{.number}}{{"\t"}}{{.state}}{{"\t"}}{{.url}}{{"\t"}}{{.headRefOid}}{{"\t"}}{{.headRefName}}{{"\t"}}{{.title}}{{"\n"}}{{end}}' \
    2>/dev/null) || {
    _git_error "Unable to list pull requests."
    return 1
  }
  [[ -n "$pr_output" ]] || {
    _git_info "No $state pull requests were found."
    return 3
  }

  local -a ids=() numbers=() states=() urls=() heads=() branches=()
  local -a titles=()
  local -a rows=()
  local line pr_id number remainder pr_state pr_url head_oid head_branch title
  local -i index=0
  for line in "${(@f)pr_output}"; do
    pr_id="${line%%$'\t'*}"
    remainder="${line#*$'\t'}"
    number="${remainder%%$'\t'*}"
    remainder="${remainder#*$'\t'}"
    pr_state="${remainder%%$'\t'*}"
    remainder="${remainder#*$'\t'}"
    pr_url="${remainder%%$'\t'*}"
    remainder="${remainder#*$'\t'}"
    head_oid="${remainder%%$'\t'*}"
    remainder="${remainder#*$'\t'}"
    head_branch="${remainder%%$'\t'*}"
    title="${remainder#*$'\t'}"
    [[ -n "$pr_id" \
      && "$pr_id" != *$'\t'* \
      && "$number" == <-> \
      && "$pr_state" == (OPEN|CLOSED|MERGED|open|closed|merged) \
      && "$pr_url" == https://* ]] || continue
    _git_validate_oid "$head_oid" || continue
    ids+=("$pr_id")
    numbers+=("$number")
    states+=("${pr_state:l}")
    urls+=("$pr_url")
    heads+=("$head_oid")
    branches+=("$head_branch")
    titles+=("$title")
    (( index++ ))
    rows+=("#$number $(_git_record_escape "$title")|$index|${pr_state:l} · $(_git_record_escape "$head_branch") · ${head_oid[1,12]}")
  done
  (( ${#rows[@]} > 0 )) || {
    _git_error "GitHub returned no valid pull request records."
    return 1
  }

  local selected
  local -i fzf_rc=0
  selected=$(printf '%s\n' "${rows[@]}" | _git_fzf \
    --delimiter='[|]' \
    --with-nth=1 \
    --prompt='Pull request > ' \
    --header='Up/Down navigate | Enter select | Esc cancel' \
    --preview='printf "%s\n" {3}' \
    --preview-window='down:3:wrap') || fzf_rc=$?
  if (( fzf_rc != 0 )); then
    _git_fzf_rc_is_cancel "$fzf_rc" && return 3
    return 1
  fi
  local selected_index="${${selected#*|}%%|*}"
  [[ "$selected_index" == <-> \
    && selected_index -ge 1 \
    && selected_index -le ${#numbers[@]} ]] || return 1
  reply=(
    "${ids[$selected_index]}"
    "${numbers[$selected_index]}"
    "${states[$selected_index]}"
    "${urls[$selected_index]}"
    "${heads[$selected_index]}"
    "${branches[$selected_index]}"
    "${titles[$selected_index]}"
  )
}

_git_gh_pr_current() {
  local number="$1"
  local output pr_id state head_oid remainder
  output=$(command gh pr view "$number" \
    --repo "${_GIT_GH_REPO[target]}" \
    --json id,state,headRefOid \
    --template '{{.id}}{{"\t"}}{{.state}}{{"\t"}}{{.headRefOid}}' \
    2>/dev/null) || return 1
  pr_id="${output%%$'\t'*}"
  remainder="${output#*$'\t'}"
  state="${remainder%%$'\t'*}"
  head_oid="${remainder#*$'\t'}"
  [[ -n "$pr_id" \
    && "$state" == (OPEN|CLOSED|MERGED|open|closed|merged) ]] || return 1
  _git_validate_oid "$head_oid" || return 1
  reply=("$pr_id" "${state:l}" "$head_oid")
}

_git_gh_push_remote() {
  local branch="$1"
  local remote=""

  remote=$(command git config --get \
    "branch.${branch}.pushRemote" 2>/dev/null) || remote=""
  [[ -n "$remote" ]] \
    || remote=$(command git config --get remote.pushDefault 2>/dev/null) \
    || remote=""
  [[ -n "$remote" ]] \
    || remote=$(command git config --get \
      "branch.${branch}.remote" 2>/dev/null) \
    || remote=""
  if [[ "$remote" == "." ]]; then
    _git_error \
      "The branch is configured to push into this repository, not a remote."
    return 1
  fi
  if [[ -z "$remote" ]]; then
    command git remote get-url origin >/dev/null 2>&1 && remote="origin"
  fi
  [[ -n "$remote" ]] \
    || remote=$(_git_current_remote 2>/dev/null) \
    || remote=""
  [[ -n "$remote" ]] || {
    _git_error "No unambiguous push remote is available."
    return 1
  }
  _git_validate_remote_token "$remote" || {
    _git_error "The configured push remote is invalid."
    return 1
  }
  REPLY="$remote"
}

_git_gh_remote_push_url() {
  local remote="$1"
  local output
  output=$(command git remote get-url --push --all "$remote" 2>/dev/null) \
    || return 1

  local -a urls=("${(@f)output}")
  (( ${#urls[@]} == 1 )) || {
    _git_error \
      "Remote '$remote' must resolve to exactly one push URL."
    return 1
  }
  [[ -n "${urls[1]}" \
    && "${urls[1]}" != *$'\n'* \
    && "${urls[1]}" != *$'\r'* ]] || return 1
  REPLY="${urls[1]}"
}

# SSH host aliases such as github-<identity> resolve to their configured
# HostName locally; ssh -G never opens a connection. The alias is resolved by
# the SSH program Git itself runs -- GIT_SSH_COMMAND, core.sshCommand,
# GIT_SSH, then ssh -- so WSL's ssh.exe reads the Windows SSH configuration.
# Like Git, a command is run through the shell and GIT_SSH directly; PuTTY
# variants have no -G and keep the alias.
_git_gh_ssh_hostname() {
  emulate -L zsh

  local host="$1"
  local ssh_command="${GIT_SSH_COMMAND:-}"
  local ssh_program=""
  local ssh_variant=""
  local output=""
  local line=""
  REPLY="$host"

  if [[ -z "$ssh_command" ]]; then
    ssh_command=$(command git config --get core.sshCommand 2>/dev/null) ||
      ssh_command=""
  fi
  if [[ -n "$ssh_command" ]]; then
    local -a ssh_words=("${(z)ssh_command}")
    ssh_program="${(Q)ssh_words[1]}"
  else
    ssh_program="${GIT_SSH:-ssh}"
  fi

  ssh_variant=$(command git config --get ssh.variant 2>/dev/null) ||
    ssh_variant=""
  if [[ -z "$ssh_variant" || "$ssh_variant" == "auto" ]]; then
    ssh_variant="${${${ssh_program##*[/\\]}:l}%.exe}"
  fi
  [[ "$ssh_variant" == (plink|putty|tortoiseplink|simple) ]] && return 0

  if [[ -n "$ssh_command" ]]; then
    output=$(command /bin/sh -c "$ssh_command \"\$@\"" "$ssh_command" \
      -G -- "$host" </dev/null 2>/dev/null) || return 0
  else
    _git_check_cmd "$ssh_program" || return 0
    output=$(command "$ssh_program" -G -- "$host" </dev/null 2>/dev/null) ||
      return 0
  fi
  for line in "${(@f)output}"; do
    # Windows OpenSSH ends its lines with CRLF.
    line="${line%$'\r'}"
    if [[ "$line" == "hostname "* ]]; then
      line="${line#hostname }"
      [[ "$line" =~ '^[A-Za-z0-9][A-Za-z0-9.-]*$' ]] && REPLY="$line"
      return 0
    fi
  done
}

_git_gh_remote_identity() {
  local remote="$1"
  local remote_url remainder host repo_path owner repo
  local transport="https"
  _git_gh_remote_push_url "$remote" || return 1
  remote_url="$REPLY"

  if [[ "$remote_url" == (http|https|ssh)://* ]]; then
    [[ "$remote_url" == ssh://* ]] && transport="ssh"
    remainder="${remote_url#*://}"
    host="${remainder%%/*}"
    repo_path="${remainder#*/}"
    host="${host##*@}"
    [[ "$host" == *:<-> ]] && host="${host%:*}"
  elif [[ "$remote_url" == *@*:* ]]; then
    transport="ssh"
    remainder="${remote_url#*@}"
    host="${remainder%%:*}"
    repo_path="${remainder#*:}"
  else
    return 1
  fi
  repo_path="${repo_path#/}"
  repo_path="${repo_path%.git}"
  owner="${repo_path%%/*}"
  repo="${repo_path#*/}"
  [[ "$host" =~ '^[A-Za-z0-9][A-Za-z0-9.-]*$' \
    && "$owner" =~ '^[A-Za-z0-9_.-]+$' \
    && "$repo" =~ '^[A-Za-z0-9_.-]+$' \
    && "$repo" != */* ]] || return 1
  if [[ "$transport" == "ssh" ]]; then
    _git_gh_ssh_hostname "$host"
    host="$REPLY"
  fi
  reply=("$host/$owner/$repo" "$remote_url" "$owner")
}

_git_gh_remote_head_oid() {
  local remote_url="$1"
  local branch="$2"
  local output=""
  local -i ls_rc=0
  output=$(command git ls-remote --exit-code --heads \
    "$remote_url" "refs/heads/$branch" 2>/dev/null) || ls_rc=$?
  if (( ls_rc == 2 )); then
    REPLY=""
    return 0
  fi
  (( ls_rc == 0 )) || return 1

  # ls-remote also returns tail matches such as refs/heads/x/refs/heads/<b>.
  local line="" oid="" ref="" found_oid=""
  for line in "${(@f)output}"; do
    oid="${line%%$'\t'*}"
    ref="${line#*$'\t'}"
    [[ "$ref" == "refs/heads/$branch" ]] || continue
    [[ -z "$found_oid" ]] || return 1
    _git_validate_oid "$oid" || return 1
    found_oid="$oid"
  done
  REPLY="$found_oid"
}

_git_gh_created_pr_current() {
  local number="$1"
  local output remainder pr_id state pr_url head_branch head_oid
  local base_branch base_oid
  output=$(command gh pr view "$number" \
    --repo "${_GIT_GH_REPO[target]}" \
    --json id,state,url,headRefName,headRefOid,baseRefName,baseRefOid \
    --template \
      '{{.id}}{{"\t"}}{{.state}}{{"\t"}}{{.url}}{{"\t"}}{{.headRefName}}{{"\t"}}{{.headRefOid}}{{"\t"}}{{.baseRefName}}{{"\t"}}{{.baseRefOid}}' \
    2>/dev/null) || return 1

  pr_id="${output%%$'\t'*}"
  remainder="${output#*$'\t'}"
  state="${remainder%%$'\t'*}"
  remainder="${remainder#*$'\t'}"
  pr_url="${remainder%%$'\t'*}"
  remainder="${remainder#*$'\t'}"
  head_branch="${remainder%%$'\t'*}"
  remainder="${remainder#*$'\t'}"
  head_oid="${remainder%%$'\t'*}"
  remainder="${remainder#*$'\t'}"
  base_branch="${remainder%%$'\t'*}"
  base_oid="${remainder#*$'\t'}"
  [[ -n "$pr_id" \
    && "$state" == (OPEN|open) \
    && "$pr_url" == https://* ]] || return 1
  _git_validate_branch_name "$head_branch" || return 1
  _git_validate_oid "$head_oid" || return 1
  _git_validate_branch_name "$base_branch" || return 1
  _git_validate_oid "$base_oid" || return 1
  reply=(
    "$pr_id"
    "${state:l}"
    "$pr_url"
    "$head_branch"
    "$head_oid"
    "$base_branch"
    "$base_oid"
  )
}

_git_gh_base_oid() {
  local branch="$1"
  local owner="${_GIT_GH_REPO[name]%%/*}"
  local repo="${_GIT_GH_REPO[name]#*/}"
  local query
  query='query($owner:String!,$repo:String!,$expression:String!){repository(owner:$owner,name:$repo){object(expression:$expression){... on Commit{oid}}}}'
  local oid
  oid=$(command gh api graphql \
    --hostname "${_GIT_GH_REPO[host]}" \
    -f query="$query" \
    -f owner="$owner" \
    -f repo="$repo" \
    -f expression="refs/heads/$branch" \
    --jq '.data.repository.object.oid' 2>/dev/null) || return 1
  _git_validate_oid "$oid" || return 1
  REPLY="$oid"
}

git-pr-create() {
  emulate -L zsh

  _git_gh_help_requested git-pr-create "$@" && return 0

  local -i interactive_mode=$(( $# == 0 ))
  local base="" title="" body=""
  local -i fill=0 draft=0 dry_run=0 assume_yes=0
  while (( $# > 0 )); do
    case "$1" in
      --base)
        (( $# >= 2 )) || {
          _git_error "--base requires a branch."
          return 2
        }
        base="$2"
        shift
        ;;
      --title)
        (( $# >= 2 )) || {
          _git_error "--title requires text."
          return 2
        }
        title="$2"
        shift
        ;;
      --body)
        (( $# >= 2 )) || {
          _git_error "--body requires text."
          return 2
        }
        body="$2"
        shift
        ;;
      --fill)
        fill=1
        ;;
      --draft)
        draft=1
        ;;
      --dry-run)
        dry_run=1
        ;;
      -y|--yes)
        assume_yes=1
        ;;
      -*)
        _git_error "Unknown git-pr-create option: $1"
        return 2
        ;;
      *)
        _git_error "Unexpected git-pr-create argument: $1"
        return 2
        ;;
    esac
    shift
  done
  (( fill && ${#title} > 0 )) && {
    _git_error "--fill and --title cannot be combined."
    return 2
  }
  [[ -n "$body" && -z "$title" ]] && {
    _git_error "--body requires --title."
    return 2
  }
  (( dry_run && assume_yes )) && {
    _git_error "--dry-run and --yes cannot be combined."
    return 2
  }
  [[ "$title" != *$'\n'* && "$title" != *$'\r'* \
    && "$body" != *$'\r'* ]] || {
    _git_error "The PR title or body contains an unsupported control."
    return 2
  }
  if [[ -n "$base" ]]; then
    _git_validate_branch_name "$base" || {
      _git_error "Invalid base branch."
      return 2
    }
  fi
  if (( interactive_mode )); then
    _git_require_interactive || return 1
  fi

  _git_gh_repo_context || return 1
  _git_context_refresh || return 1

  local branch="${_GIT_CONTEXT[branch]}"
  local expected_head="${_GIT_CONTEXT[head]}"
  [[ "$branch" != "detached" && "$expected_head" != "unborn" ]] || {
    _git_error "Pull request creation requires an attached branch with a commit."
    return 1
  }
  local expected_root="${_GIT_CONTEXT[root]}"
  local expected_fingerprint="${_GIT_CONTEXT[fingerprint]}"

  local remote remote_branch="$branch"
  _git_gh_push_remote "$branch" || return 1
  remote="$REPLY"
  _git_validate_branch_name "$remote_branch" || {
    _git_error "The remote head branch is invalid."
    return 1
  }

  local -a reply=()
  _git_gh_remote_identity "$remote" || {
    _git_error "Remote '$remote' is not a supported GitHub remote URL."
    return 1
  }
  local remote_target="${reply[1]}"
  local remote_url="${reply[2]}"
  [[ "${remote_target:l}" == "${_GIT_GH_REPO[target]:l}" ]] || {
    _git_error \
      "Push remote '$remote' targets $remote_target, not ${_GIT_GH_REPO[target]}."
    return 1
  }

  local default_branch
  default_branch=$(command gh repo view \
    --repo "${_GIT_GH_REPO[target]}" \
    --json defaultBranchRef \
    --template '{{.defaultBranchRef.name}}' 2>/dev/null) || {
    _git_error "Unable to resolve the default branch."
    return 1
  }
  _git_validate_branch_name "$default_branch" || {
    _git_error "GitHub returned an invalid default branch."
    return 1
  }
  if (( interactive_mode )); then
    printf 'Base branch [%s]: ' "$default_branch" >&2
    IFS= read -r base
    base="${base:-$default_branch}"
    printf 'Pull request title (empty derives from commits): ' >&2
    IFS= read -r title
    [[ -n "$title" ]] || fill=1
  else
    base="${base:-$default_branch}"
    [[ -n "$title" ]] || fill=1
  fi
  _git_validate_branch_name "$base" || {
    _git_error "Invalid base branch."
    return 2
  }
  _git_gh_base_oid "$base" || {
    _git_error "Unable to resolve base branch '$base' on GitHub."
    return 1
  }
  local base_oid="$REPLY"

  _git_gh_remote_head_oid "$remote_url" "$remote_branch" || {
    _git_error "Unable to resolve the remote head branch."
    return 1
  }
  local remote_head_oid="$REPLY"
  local -i needs_push=0
  [[ "$remote_head_oid" != "$expected_head" ]] && needs_push=1
  if (( needs_push )) && [[ -n "$remote_head_oid" ]] \
    && ! command git merge-base --is-ancestor \
      "$remote_head_oid" "$expected_head" 2>/dev/null; then
    _git_error \
      "Remote branch '$remote_branch' is not an ancestor of HEAD; fetch and integrate it first."
    return 1
  fi

  _git_header "Pull Request Creation Plan"
  _git_label "Repository:" \
    "${_GIT_GH_REPO[target]} (${_GIT_GH_REPO[id]})"
  _git_label "Local head:" "$branch @ ${expected_head[1,12]}"
  _git_label "Remote:" \
    "$remote ($(_git_redact_remote_url "$remote_url"))"
  _git_label "Published head:" \
    "$remote_branch @ ${remote_head_oid[1,12]:-(missing)}"
  _git_label "Publish required:" "$(( needs_push ? 1 : 0 ))"
  _git_label "Base:" "$base @ ${base_oid[1,12]}"
  _git_label "Content:" \
    "$([[ -n "$title" ]] && print -r -- "$title" \
      || print -r -- "derive from commits")"
  _git_label "Draft:" "$(( draft ? 1 : 0 ))"
  (( dry_run )) && {
    _git_info "Dry run complete; no branch or pull request was changed."
    return 0
  }
  local -i authorize_rc=0
  _git_authorize "$assume_yes" "Publish this head and create the PR?" \
    || authorize_rc=$?
  (( authorize_rc == 3 )) && return 0
  (( authorize_rc != 0 )) && return $authorize_rc

  _git_require_same_context \
    "$expected_root" "$expected_head" "$expected_fingerprint" || return 1
  local current_branch
  current_branch=$(command git symbolic-ref --quiet --short HEAD \
    2>/dev/null) || current_branch=""
  [[ "$current_branch" == "$branch" ]] || {
    _git_error "The attached branch changed after review; retry."
    return 1
  }
  _git_gh_require_same_repo || return 1
  _git_gh_base_oid "$base" || {
    _git_error "The GitHub base branch is no longer available."
    return 1
  }
  [[ "$REPLY" == "$base_oid" ]] || {
    _git_error "The GitHub base branch changed; review the plan again."
    return 1
  }
  local -a current_remote=()
  _git_gh_remote_identity "$remote" || return 1
  current_remote=("${reply[@]}")
  [[ "${current_remote[1]:l}" == "${remote_target:l}" \
    && "${current_remote[2]}" == "$remote_url" ]] || {
    _git_error "The push remote identity changed; retry."
    return 1
  }
  _git_gh_remote_head_oid "$remote_url" "$remote_branch" || return 1
  [[ "$REPLY" == "$remote_head_oid" ]] || {
    _git_error "The remote head changed after review; retry."
    return 1
  }

  local -i published_now=0
  if (( needs_push )); then
    # The reviewed fast-forward is bound to the exact remote head (or its
    # absence); follow-tags and submodule recursion stay off so only the
    # reviewed head is published.
    command git push --no-follow-tags --recurse-submodules=no \
      "--force-with-lease=refs/heads/${remote_branch}:${remote_head_oid}" \
      -- "$remote_url" "${expected_head}:refs/heads/${remote_branch}" >&2
    local -i push_rc=$?
    (( push_rc == 0 )) || {
      _git_error "Unable to publish the exact head (exit $push_rc)."
      return $push_rc
    }
    _git_gh_remote_head_oid "$remote_url" "$remote_branch" \
      && [[ "$REPLY" == "$expected_head" ]] || {
      _git_error \
        "Push returned success, but the published head could not be verified."
      return 1
    }
    published_now=1
  fi
  _git_gh_require_same_repo || {
    _git_error "The GitHub repository changed before PR creation."
    (( published_now )) && _git_warn \
      "Partial result: the reviewed head remains published at $remote_branch."
    return 1
  }
  _git_gh_base_oid "$base" \
    && [[ "$REPLY" == "$base_oid" ]] || {
    _git_error "The GitHub base branch changed before PR creation."
    (( published_now )) && _git_warn \
      "Partial result: the reviewed head remains published at $remote_branch."
    return 1
  }

  local -a create_args=(
    pr create
    --repo "${_GIT_GH_REPO[target]}"
    --head "$remote_branch"
    --base "$base"
  )
  if (( fill )); then
    create_args+=(--fill)
  else
    create_args+=(--title "$title" --body "$body")
  fi
  (( draft )) && create_args+=(--draft)

  local created_url=""
  created_url=$(command gh "${create_args[@]}")
  local -i create_rc=$?
  if (( create_rc != 0 )); then
    _git_error "Unable to create the pull request (exit $create_rc)."
    (( published_now )) && _git_warn \
      "Partial result: the reviewed head remains published at $remote_branch."
    return $create_rc
  fi

  local created_number=""
  local expected_url_prefix="${_GIT_GH_REPO[url]%/}/pull/"
  if [[ "$created_url" == "${expected_url_prefix}"<-> ]]; then
    created_number="${created_url#$expected_url_prefix}"
  fi
  if [[ -z "$created_number" || 10#$created_number -lt 1 ]]; then
    _git_error \
      "GitHub reported success without a verifiable pull request URL."
    [[ -n "$created_url" ]] && _git_label "Reported URL:" "$created_url"
    (( published_now )) && _git_warn \
      "Partial result: the reviewed head remains published at $remote_branch."
    return 1
  fi

  _git_gh_require_same_repo || {
    _git_error "The GitHub repository changed after PR creation."
    _git_warn \
      "Partial result: PR #$created_number may exist but was not verified."
    (( published_now )) && _git_warn \
      "The reviewed head remains published at $remote_branch."
    return 1
  }
  local -a created_pr=()
  _git_gh_created_pr_current "$created_number" || {
    _git_error "Unable to verify the pull request after creation."
    _git_warn \
      "Partial result: PR #$created_number may exist at $created_url."
    (( published_now )) && _git_warn \
      "The reviewed head remains published at $remote_branch."
    return 1
  }
  created_pr=("${reply[@]}")
  [[ "${created_pr[2]}" == "open" \
    && "${created_pr[3]}" == "$created_url" \
    && "${created_pr[4]}" == "$remote_branch" \
    && "${created_pr[5]}" == "$expected_head" \
    && "${created_pr[6]}" == "$base" \
    && "${created_pr[7]}" == "$base_oid" ]] || {
    _git_error \
      "The created pull request does not match the reviewed repository, base, and head."
    _git_warn "Partial result: inspect PR #$created_number at $created_url."
    (( published_now )) && _git_warn \
      "The reviewed head remains published at $remote_branch."
    return 1
  }

  _git_success "Pull request #$created_number created and verified."
  _git_label "URL:" "$created_url"
  return 0
}

_git_gh_restore_checkout_state() {
  local original_branch="$1"
  local original_oid="$2"
  local current_branch current_oid
  current_branch=$(command git symbolic-ref --quiet --short HEAD \
    2>/dev/null) || current_branch=""
  current_oid=$(command git rev-parse --verify HEAD 2>/dev/null) \
    || current_oid=""

  if [[ "$current_oid" == "$original_oid" \
    && "$original_branch" == "detached" \
    && -z "$current_branch" ]]; then
    REPLY="unchanged"
    return 0
  fi
  if [[ "$current_oid" == "$original_oid" \
    && "$original_branch" != "detached" \
    && "$current_branch" == "$original_branch" ]]; then
    REPLY="unchanged"
    return 0
  fi

  if [[ "$original_branch" != "detached" ]]; then
    local original_ref_oid
    original_ref_oid=$(command git rev-parse --verify \
      "refs/heads/$original_branch" 2>/dev/null) || original_ref_oid=""
    if [[ "$original_ref_oid" == "$original_oid" ]] \
      && command git switch --quiet "$original_branch" >&2; then
      current_branch=$(command git symbolic-ref --quiet --short HEAD \
        2>/dev/null) || current_branch=""
      current_oid=$(command git rev-parse --verify HEAD 2>/dev/null) \
        || current_oid=""
      if [[ "$current_branch" == "$original_branch" \
        && "$current_oid" == "$original_oid" ]]; then
        REPLY="restored"
        return 0
      fi
    fi
  fi

  if command git switch --quiet --detach "$original_oid" >&2; then
    current_branch=$(command git symbolic-ref --quiet --short HEAD \
      2>/dev/null) || current_branch=""
    current_oid=$(command git rev-parse --verify HEAD 2>/dev/null) \
      || current_oid=""
    if [[ -z "$current_branch" && "$current_oid" == "$original_oid" ]]; then
      REPLY="detached"
      return 0
    fi
  fi
  REPLY="failed"
  return 1
}

git-pr-checkout() {
  emulate -L zsh

  _git_gh_help_requested git-pr-checkout "$@" && return 0
  (( $# <= 1 )) || {
    _git_error "git-pr-checkout accepts at most one PR number."
    return 2
  }
  [[ "${1:-}" != -* ]] || {
    _git_error "Unknown option: $1"
    return 2
  }
  if (( $# == 1 )); then
    [[ "$1" == <-> ]] || {
      _git_error "Pull request number must be a positive integer."
      return 2
    }
    (( 10#$1 >= 1 )) || {
      _git_error "Pull request number must be a positive integer."
      return 2
    }
  fi
  _git_gh_repo_context || return 1
  _git_context_refresh || return 1

  local number="${1:-}"
  local expected_root="${_GIT_CONTEXT[root]}"
  local expected_head="${_GIT_CONTEXT[head]}"
  local expected_fingerprint="${_GIT_CONTEXT[fingerprint]}"
  local original_branch="${_GIT_CONTEXT[branch]}"
  _git_validate_oid "$expected_head" || {
    _git_error "PR checkout requires an existing local HEAD to restore safely."
    return 1
  }
  if [[ -z "$number" ]]; then
    _git_require_interactive || return 1
    local -a reply=()
    local -i picker_rc=0
    _git_gh_pick_pr open || picker_rc=$?
    if (( picker_rc != 0 )); then
      (( picker_rc == 3 )) && return 0
      return 1
    fi
    number="${reply[2]}"
  fi
  [[ "$number" == <-> && number -ge 1 ]] || {
    _git_error "Pull request number must be a positive integer."
    return 2
  }

  local -a reply=()
  _git_gh_pr_current "$number" || {
    _git_error "Pull request #$number is not open or cannot be resolved."
    return 1
  }
  local pr_id="${reply[1]}"
  local pr_state="${reply[2]}"
  local head_oid="${reply[3]}"
  [[ "$pr_state" == "open" ]] || {
    _git_error "Pull request #$number is not open."
    return 1
  }
  _git_require_same_context \
    "$expected_root" "$expected_head" "$expected_fingerprint" || return 1
  _git_gh_require_same_repo || return 1
  _git_gh_pr_current "$number" || {
    _git_error "Pull request #$number changed before checkout."
    return 1
  }
  [[ "${reply[1]}" == "$pr_id" \
    && "${reply[2]}" == "open" \
    && "${reply[3]}" == "$head_oid" ]] || {
    _git_error "The PR head changed before checkout; review it again."
    return 1
  }

  _git_info \
    "Checking out PR #$number at reviewed head ${head_oid[1,12]}."
  command gh pr checkout "$number" --detach \
    --repo "${_GIT_GH_REPO[target]}" >&2
  local -i checkout_rc=$?
  if (( checkout_rc != 0 )); then
    if _git_gh_restore_checkout_state "$original_branch" "$expected_head"; then
      if [[ "$REPLY" == "detached" ]]; then
        _git_warn \
          "Checkout failed; the original OID was restored in detached mode."
      else
        _git_info "Checkout failed; the original worktree state is intact."
      fi
    else
      _git_warn \
        "Checkout failed and the original worktree state could not be restored."
    fi
    _git_error "Unable to checkout PR #$number (exit $checkout_rc)."
    return $checkout_rc
  fi

  local -i pin_rc=0
  command git switch --quiet --detach "$head_oid" >&2 || pin_rc=$?
  local checked_out_oid checked_out_branch
  checked_out_oid=$(command git rev-parse --verify HEAD 2>/dev/null) \
    || checked_out_oid=""
  checked_out_branch=$(command git symbolic-ref --quiet --short HEAD \
    2>/dev/null) || checked_out_branch=""
  if (( pin_rc != 0 )) \
    || [[ "$checked_out_oid" != "$head_oid" \
      || -n "$checked_out_branch" ]]; then
    _git_error \
      "Checkout did not reach the exact reviewed OID; restoring the prior state."
    if _git_gh_restore_checkout_state "$original_branch" "$expected_head"; then
      if [[ "$REPLY" == "detached" ]]; then
        _git_warn \
          "The original OID was restored, but only in detached mode."
      else
        _git_info "The original worktree state was restored."
      fi
    else
      _git_warn \
        "The original worktree state could not be restored; inspect HEAD."
    fi
    return 1
  fi

  _git_success \
    "Checked out pull request #$number in detached mode at ${head_oid[1,12]}."
  return 0
}

typeset -g _GIT_PR_SOURCED=1
