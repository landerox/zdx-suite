# A real ZDX tour in record.zsh's private workspace: the launcher, a stash
# saved from the Git menu, the System information, and a project health check.
Output .demo/demo.gif
Require zsh
Require fzf
Require git
Require ttyd
Require ffmpeg

Set Shell "zsh"
Set Theme "Catppuccin Mocha"
Set FontFamily "DejaVu Sans Mono"
Set FontSize 18
Set Width 1180
Set Height 700
Set Padding 18
Set Margin 14
Set MarginFill "#11111b"
Set WindowBar Colorful
Set BorderRadius 10
Set Framerate 10
Set TypingSpeed 55ms
Set CursorBlink false
Set WaitTimeout 15s

Hide
Type@0 "exec zsh -f"
Enter
Type@0 'source "$ZDX_DEMO_SOURCE_ROOT/.demo/session.zsh" && _zdx_demo_session || exit $?'
Enter
Wait+Screen /DEMO_READY/
Type@0 "clear"
Enter
Wait+Line /zdx-demo ❯/
Show

# One launcher for every suite.
Sleep 900ms
Type "zdx"
Sleep 500ms
Enter
Wait+Screen /zdx >/
Sleep 2800ms
Type "git"
Wait+Screen /Command: zdx git/
Sleep 900ms
Enter

# The Git menu reads the repository, then saves unfinished work as a stash.
Wait+Screen /Repository: zdx-demo/
Sleep 2600ms
Screenshot .demo/demo.png
Sleep 700ms
Type "stash"
Wait+Screen /Command: git-stash/
Sleep 1400ms
Enter
Wait+Screen /Save current changes/
Sleep 2600ms
Enter
Wait+Screen /Stash message/
Sleep 500ms
Type "WIP: friendlier greeting"
Sleep 600ms
Enter
Wait+Screen /Include 1 untracked file/
Sleep 1200ms
Down
Sleep 500ms
Enter
Wait+Screen /Save 3 files to a new stash/
Sleep 3000ms
Down
Sleep 500ms
Enter
Wait+Screen /Stash saved/
Sleep 2800ms
Hide
Type@0 "_zdx_demo_check $?; demo_status=$?; clear; print -r -- DEMO_GIT_RETURN:$demo_status"
Enter
Wait+Screen /DEMO_GIT_RETURN:0/
Type@0 "clear"
Enter
Wait+Line /zdx-demo ❯/
Show

# The System menu summarizes the host.
Sleep 700ms
Type "zdx sys"
Sleep 400ms
Enter
Wait+Screen /sys >/
Sleep 2600ms
Type "system info"
Wait+Screen /Command: sys-info/
Sleep 1300ms
Enter
Wait+Line /zdx-demo ❯\s*$/
Sleep 3600ms
Hide
Type@0 "_zdx_demo_check $?; demo_status=$?; clear; print -r -- DEMO_SYS_RETURN:$demo_status"
Enter
Wait+Screen /DEMO_SYS_RETURN:0/
Type@0 "clear"
Enter
Wait+Line /zdx-demo ❯/
Show

# The Developer menu reads the project and checks its health.
Sleep 700ms
Type "zdx dev"
Sleep 400ms
Enter
Wait+Screen /dev >/
Sleep 2800ms
Type "health"
Wait+Screen /Command: dev-check-health/
Sleep 1300ms
Enter
Wait+Line /zdx-demo ❯\s*$/
Sleep 3800ms
Hide
Type@0 "_zdx_demo_check $?; demo_status=$?; clear; print -r -- DEMO_DEV_RETURN:$demo_status"
Enter
Wait+Screen /DEMO_DEV_RETURN:0/
Type@0 "_zdx_demo_finish"
Enter
Wait+Screen /DEMO_COMPLETE/
Type@0 "exit"
Enter
