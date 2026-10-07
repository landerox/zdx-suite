#!/usr/bin/env bats

setup() {
  load test_helper

  # Setup dummy git repo inside TEST_TEMP_DIR for local git config testing
  export REPO_DIR="$TEST_TEMP_DIR/dummy-repo"
  mkdir -p "$REPO_DIR"
  cd "$REPO_DIR"
  git init -b main 2>/dev/null || git init 2>/dev/null
  git config user.name "Initial Name"
  git config user.email "initial@email.com"
}

teardown() {
  cleanup_sandbox
}

@test "git-identity: --help works" {
  run run_zsh "git-identity-switcher --help"
  [ "$status" -eq 0 ]
  [[ "$output" == *"git-identity-switcher --switch"* ]]
}

@test "git-identity: --status displays local and global settings" {
  run run_zsh "
    cd '$REPO_DIR'
    git-identity-switcher --status
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"Initial Name"* ]]
  [[ "$output" == *"initial@email.com"* ]]
}

@test "git-identity: --switch fails on missing profile name" {
  run run_zsh "
    cd '$REPO_DIR'
    git-identity-switcher --switch
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"Profile name is required"* ]]
}

@test "git-identity: --switch fails on non-existent profile name" {
  run run_zsh "
    cd '$REPO_DIR'
    git-identity-switcher --switch non-existent
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not defined in \$ZDX_GIT_IDENTITIES"* ]]
}

@test "git-identity: --switch applies a valid local identity profile successfully" {
  run run_zsh "
    cd '$REPO_DIR'
    # Define test profile in local environment
    typeset -gA ZDX_GIT_IDENTITIES
    ZDX_GIT_IDENTITIES=(
      'test-personal' 'Name|Test Jane;Email|test-jane@doe.dev;GpgKey|A1B2C3D4;SshKey|~/.ssh/test_id'
    )
    git-identity-switcher --switch test-personal local
    echo '---'
    git config user.name
    git config user.email
    git config user.signingkey
    git config core.sshCommand
  "
  if [ "$status" -ne 0 ]; then
    echo "STATUS: $status"
    echo "OUTPUT: $output"
    return 1
  fi
  [[ "$output" == *"Profile 'test-personal' successfully applied"* ]]
  [[ "$output" == *"Test Jane"* ]]
  [[ "$output" == *"test-jane@doe.dev"* ]]
  [[ "$output" == *"A1B2C3D4"* ]]
  [[ "$output" == *"ssh -i "* ]]
}

@test "git-identity: --switch applies a valid global identity profile successfully" {
  run run_zsh "
    cd '$REPO_DIR'
    typeset -gA ZDX_GIT_IDENTITIES
    ZDX_GIT_IDENTITIES=(
      'test-global' 'Name|Global Jane;Email|global-jane@doe.dev'
    )
    git-identity-switcher --switch test-global global
    echo '---'
    git config --global user.name
    git config --global user.email
  "
  if [ "$status" -ne 0 ]; then
    echo "STATUS: $status"
    echo "OUTPUT: $output"
    return 1
  fi
  [[ "$output" == *"Profile 'test-global' successfully applied"* ]]
  [[ "$output" == *"Global Jane"* ]]
  [[ "$output" == *"global-jane@doe.dev"* ]]
}

@test "git-identity: a local profile overrides inherited signing and SSH selection" {
  run run_zsh "
    cd '$REPO_DIR'
    typeset -gA ZDX_GIT_IDENTITIES
    ZDX_GIT_IDENTITIES=(
      work 'Name|Work Jane;Email|jane@work.example;GpgKey|WORKKEYID;SshKey|~/.ssh/id_work'
      personal 'Name|Jane;Email|jane@personal.example'
    )
    git-identity-switcher --switch work global 2>/dev/null || exit 10
    git-identity-switcher --switch personal local 2>'$HOME/local.stderr' || exit 11
    print -r -- \"email=\$(git config --get user.email)\"
    print -r -- \"commit=\$(git config --get commit.gpgSign)\"
    print -r -- \"tag=\$(git config --get tag.gpgSign)\"
    print -r -- \"ssh=\$(git config --get core.sshCommand)\"
    print -r -- \"global=\$(git config --global --get commit.gpgSign)\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"email=jane@personal.example"* ]]
  [[ "$output" == *"commit=false"* ]]
  [[ "$output" == *"tag=false"* ]]
  [[ "$output" == *"ssh=ssh"* ]]
  [[ "$output" == *"global=true"* ]]
  grep -Fq "overrides inherited core.sshCommand" "$HOME/local.stderr"
}

@test "git-identity: a local profile without a key keeps an inherited agent or program" {
  run run_zsh "
    cd '$REPO_DIR'
    typeset -gA ZDX_GIT_IDENTITIES
    ZDX_GIT_IDENTITIES=(personal 'Name|Jane;Email|jane@personal.example')

    command git config --global core.sshCommand ssh.exe
    git-identity-switcher --switch personal local 2>'$HOME/exe.stderr' || exit 10
    command git config --local --get core.sshCommand && exit 11
    print -r -- \"exe=\$(command git config --get core.sshCommand)\"

    command git config --global core.sshCommand \
      'ssh -o IdentityAgent=~/.1password/agent.sock'
    git-identity-switcher --switch personal local 2>'$HOME/agent.stderr' || exit 12
    command git config --local --get core.sshCommand && exit 13
    print -r -- \"agent=\$(command git config --get core.sshCommand)\"

    command git config --global core.sshCommand 'ssh.exe -i C:/keys/work'
    git-identity-switcher --switch personal local 2>'$HOME/keyed.stderr' || exit 14
    print -r -- \"keyed=\$(command git config --local --get core.sshCommand)\"
  "
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; cat "$HOME"/*.stderr >&2; false; }
  [[ "$output" == *"exe=ssh.exe"* ]]
  [[ "$output" == *"agent=ssh -o IdentityAgent=~/.1password/agent.sock"* ]]
  [[ "$output" == *"keyed=ssh.exe"* ]]
  grep -Fq "through the inherited core.sshCommand" "$HOME/exe.stderr"
  grep -Fq "through the inherited core.sshCommand" "$HOME/agent.stderr"
  grep -Fq "overrides inherited core.sshCommand" "$HOME/keyed.stderr"
}

@test "git-identity: a profile key joins an inherited IdentityAgent command" {
  run run_zsh "
    cd '$REPO_DIR'
    typeset -gA ZDX_GIT_IDENTITIES
    ZDX_GIT_IDENTITIES=(work 'Name|Work Jane;Email|jane@work.example;SshKey|~/.ssh/work.pub')
    command git config --global core.sshCommand \
      'ssh -o \"IdentityAgent ~/agent.sock\" -i ~/.ssh/other -o IdentitiesOnly=no'
    git-identity-switcher --switch work local 2>'$HOME/work.stderr' || exit 10
    print -r -- \"local=\$(command git config --local --get core.sshCommand)\"
  "
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; cat "$HOME/work.stderr" >&2; false; }
  local expected
  expected="local=ssh -o \"IdentityAgent ~/agent.sock\" -i '$HOME/.ssh/work.pub' -o IdentitiesOnly=yes"
  [[ "$output" == *"$expected"* ]]
  grep -Fq "SSH command:" "$HOME/work.stderr"
}

@test "git-identity: ssh.exe receives the profile key as a Windows path" {
  cat > "$TEST_MOCK_BIN/wslpath" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HOME/wslpath.args"
[[ "$1" == -w && "$2" == "$HOME/.ssh/id_work" ]] || exit 1
printf 'C:\\Users\\jane\\.ssh\\id_work\r\n'
MOCK
  chmod +x "$TEST_MOCK_BIN/wslpath"

  run run_zsh "
    cd '$REPO_DIR'
    typeset -gA ZDX_GIT_IDENTITIES
    ZDX_GIT_IDENTITIES=(
      work 'Name|Work Jane;Email|jane@work.example;SshKey|~/.ssh/id_work'
      personal 'Name|Jane;Email|jane@personal.example'
      winkey 'Name|Win Jane;Email|jane@win.example;SshKey|C:/Users/jane/.ssh/id_win'
    )
    command git config --global core.sshCommand /mnt/c/Windows/System32/OpenSSH/ssh.exe
    git-identity-switcher --switch work local 2>'$HOME/local.stderr' || exit 10
    print -r -- \"local=\$(command git config --local --get core.sshCommand)\"

    git-identity-switcher --switch work global 2>'$HOME/global.stderr' || exit 11
    print -r -- \"global=\$(command git config --global --get core.sshCommand)\"
    git-identity-switcher --switch personal global 2>'$HOME/global2.stderr' || exit 12
    print -r -- \"global2=\$(command git config --global --get core.sshCommand)\"

    git-identity-switcher --switch winkey local 2>'$HOME/winkey.stderr' || exit 13
    print -r -- \"winkey=\$(command git config --local --get core.sshCommand)\"
  "
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; cat "$HOME"/*.stderr >&2; false; }
  [[ "$output" == *"local=/mnt/c/Windows/System32/OpenSSH/ssh.exe -i 'C:\\Users\\jane\\.ssh\\id_work' -o IdentitiesOnly=yes"* ]]
  [[ "$output" == *"global=/mnt/c/Windows/System32/OpenSSH/ssh.exe -i 'C:\\Users\\jane\\.ssh\\id_work' -o IdentitiesOnly=yes"* ]]
  [[ "$output" == *"global2=/mnt/c/Windows/System32/OpenSSH/ssh.exe"* ]]
  [[ "$output" != *"global2=ssh "* ]]
  [[ "$output" == *"winkey=/mnt/c/Windows/System32/OpenSSH/ssh.exe -i 'C:/Users/jane/.ssh/id_win' -o IdentitiesOnly=yes"* ]]
  grep -Fxq -- "-w $HOME/.ssh/id_work" "$HOME/wslpath.args"
  [ "$(wc -l < "$HOME/wslpath.args")" -eq 2 ]
}

@test "git-identity: ssh.exe refuses a key wslpath cannot convert and changes nothing" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "$TEST_MOCK_BIN/wslpath"
  chmod +x "$TEST_MOCK_BIN/wslpath"

  run run_zsh "
    cd '$REPO_DIR'
    typeset -gA ZDX_GIT_IDENTITIES
    ZDX_GIT_IDENTITIES=(work 'Name|Work Jane;Email|jane@work.example;SshKey|~/.ssh/id_work')
    command git config --global core.sshCommand ssh.exe
    git-identity-switcher --switch work local \
      >'$HOME/refused.stdout' 2>'$HOME/refused.stderr' && exit 10
    print -r -- \"email=\$(command git config --local --get user.email)\"
    command git config --local --get core.sshCommand && exit 11
    exit 0
  "
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; cat "$HOME/refused.stderr" >&2; false; }
  [[ "$output" == *"email=initial@email.com"* ]]
  [ ! -s "$HOME/refused.stdout" ]
  grep -Fq "core.sshCommand runs ssh.exe, which needs a Windows path" "$HOME/refused.stderr"
  grep -Fq "Give SshKey as a Windows path" "$HOME/refused.stderr"
}

@test "git-identity: SSH command parsing removes only key selection and runs nothing" {
  # shellcheck disable=SC2016
  run run_zsh '
    local -a reply=()
    _git_identity_ssh_parts "GIT_TRACE=1 ssh.exe -iC:/keys/a -oIdentityFile=b -o IdentityAgent=c -v"
    print -r -- "1:${reply[1]}|${reply[2]}|${reply[3]}"
    _git_identity_ssh_parts "\"/opt/ssh tools/ssh\" -o \"IdentitiesOnly yes\" -p 22"
    print -r -- "2:${reply[1]}|${reply[2]}|${reply[3]}"
    _git_identity_ssh_parts "ssh \$(touch $HOME/executed) -o ControlMaster=no"
    print -r -- "3:${reply[1]}|${reply[2]}|${reply[3]}"
    [[ ! -e "$HOME/executed" ]]
  '
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
  [[ "$output" == *"1:ssh.exe|GIT_TRACE=1 ssh.exe -o IdentityAgent=c -v|yes"* ]]
  [[ "$output" == *'2:/opt/ssh tools/ssh|"/opt/ssh tools/ssh" -p 22|yes'* ]]
  [[ "$output" == *"3:ssh|ssh \$(touch $HOME/executed) -o ControlMaster=no|no"* ]]
  [ ! -e "$HOME/executed" ]
}
