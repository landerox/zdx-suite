#!/usr/bin/env bats

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "hf safety: cache clear dry run validates an exact target without deleting" {
  run run_zsh '
    local cache_root="$HOME/hf-cache"
    local target="$cache_root/models--acme--gpt2"
    mkdir -m 700 -p "$target"
    _hf_cache_path_identity "$cache_root" || return 1
    local root_identity="$REPLY"
    _hf_cache_path_identity "$target" || return 1
    local target_identity="$REPLY"

    _hf_cache_plan_data() {
      printf "PLAN\tacme/gpt2\tmodel\t1200\t%s\t%s\t%s\t%s\n" \
        "$cache_root" "$target" "$root_identity" "$target_identity"
    }
    _hf_cache_execute_plan() {
      print -r -- called > "$HOME/executed"
    }
    _hf_cache_assert_no_mounts() {
      return 0
    }

    hf-cache-clear --type model --repo acme/gpt2 --dry-run \
      >"$HOME/stdout" 2>"$HOME/stderr"
    [[ ! -s "$HOME/stdout" && -d "$target" && ! -e "$HOME/executed" ]]
  '
  [ "$status" -eq 0 ]
  grep -q "Dry run complete" "$HOME/stderr"
}

@test "hf safety: cache clear rejects a protected target" {
  run run_zsh '
    _hf_cache_path_identity "$HOME" || return 1
    local identity="$REPLY"
    _hf_cache_plan_data() {
      printf "PLAN\tacme/gpt2\tmodel\t1200\t%s\t%s\t%s\t%s\n" \
        "$HOME" "$HOME" "$identity" "$identity"
    }
    hf-cache-clear --type model --repo acme/gpt2 --yes
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"boundary validation"* ]]
}

@test "hf safety: non-interactive deletion requires explicit yes" {
  run run_zsh '
    local cache_root="$HOME/hf-cache"
    local target="$cache_root/models--acme--gpt2"
    mkdir -m 700 -p "$target"
    _hf_cache_path_identity "$cache_root" || return 1
    local root_identity="$REPLY"
    _hf_cache_path_identity "$target" || return 1
    local target_identity="$REPLY"
    _hf_cache_plan_data() {
      printf "PLAN\tacme/gpt2\tmodel\t1200\t%s\t%s\t%s\t%s\n" \
        "$cache_root" "$target" "$root_identity" "$target_identity"
    }
    _hf_cache_assert_no_mounts() {
      return 0
    }

    hf-cache-clear --type model --repo acme/gpt2
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires --yes"* ]]
}

@test "hf safety: target replacement after confirmation is refused" {
  run run_zsh '
    local cache_root="$HOME/hf-cache"
    local target="$cache_root/models--acme--gpt2"
    mkdir -m 700 -p "$target"
    _hf_cache_path_identity "$cache_root" || return 1
    local root_identity="$REPLY"
    _hf_cache_path_identity "$target" || return 1
    local target_identity="$REPLY"
    _hf_cache_plan_data() {
      printf "PLAN\tacme/gpt2\tmodel\t1200\t%s\t%s\t%s\t%s\n" \
        "$cache_root" "$target" "$root_identity" "$target_identity"
    }
    functions[_hf_cache_validate_plan_real]="$functions[_hf_cache_validate_plan]"
    local -i validation_count=0
    _hf_cache_validate_plan() {
      (( validation_count++ ))
      if (( validation_count == 2 )); then
        mv "$target" "$target.old"
        mkdir -m 700 "$target"
      fi
      _hf_cache_validate_plan_real "$@"
    }
    _hf_cache_execute_plan() {
      print -r -- called > "$HOME/executed"
    }
    _hf_cache_assert_no_mounts() {
      return 0
    }

    hf-cache-clear --type model --repo acme/gpt2 --yes
  '
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/executed" ]
  [[ "$output" == *"changed after authorization"* ]]
}

@test "hf safety: yes executes only the revalidated frozen plan" {
  run run_zsh '
    local cache_root="$HOME/hf-cache"
    local target="$cache_root/models--acme--gpt2"
    mkdir -m 700 -p "$target"
    _hf_cache_path_identity "$cache_root" || return 1
    local root_identity="$REPLY"
    _hf_cache_path_identity "$target" || return 1
    local target_identity="$REPLY"
    _hf_cache_plan_data() {
      printf "PLAN\tacme/gpt2\tmodel\t1200\t%s\t%s\t%s\t%s\n" \
        "$cache_root" "$target" "$root_identity" "$target_identity"
    }
    _hf_cache_execute_plan() {
      [[ "$1" == model && "$2" == acme/gpt2 \
        && "$3" == "$cache_root" && "$4" == "$target" \
        && "$5" == "$root_identity" && "$6" == "$target_identity" ]] \
        || return 1
      print -r -- called > "$HOME/executed"
    }
    _hf_cache_assert_no_mounts() {
      return 0
    }

    hf-cache-clear --type model --repo acme/gpt2 --yes
    [[ "$(<"$HOME/executed")" == called ]]
  '
  [ "$status" -eq 0 ]
}
