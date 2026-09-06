# Real checkout menus in record.zsh's private environment. No backend actions.
Output .demo/demo.gif
Require zsh
Require fzf
Require git
Require ttyd
Require ffmpeg

Set Shell "zsh"
Set Theme "Catppuccin Mocha"
Set FontFamily "DejaVu Sans Mono"
Set Width 1040
Set Height 680
Set FontSize 16
Set Padding 16
Set Framerate 10
Set TypingSpeed 45ms
Set CursorBlink false
Set WaitTimeout 10s

Hide
Type@0 "exec zsh -f"
Enter
Type@0 'source "$ZDX_DEMO_SOURCE_ROOT/.demo/session.zsh" && _zdx_demo_session || exit $?'
Enter
Wait+Screen /DEMO_READY/
Type@0 "clear; zdx"
Enter
Wait+Screen /zdx >/
Show
Sleep 3s
Type "maintain projects"
Sleep 1s
Enter
Wait+Screen /dev >/
Sleep 1500ms
Down
Wait+Screen /Command: dev-check-health/
Sleep 3s
Sleep 1s
Wait+Screen /Command: dev-check-health/
Screenshot .demo/demo.png
Sleep 1s
Type "dependency updates"
Wait+Screen /Command: dev-update-deps-dry/
Sleep 4500ms
Escape
Wait+Line /^zdx-demo >$/
Hide
Type@0 "_zdx_demo_check $?; print -r -- DEMO_DEV_RETURN:$?"
Enter
Wait+Screen /DEMO_DEV_RETURN:0/
Type@0 "clear; zdx sys"
Enter
Wait+Screen /sys >/
Show
Sleep 1300ms
Type "health"
Wait+Screen /Command: sys-health/
Sleep 2500ms
Ctrl+U
Type "system tools"
Wait+Screen /Command: update-system/
Sleep 4s
Escape
Wait+Line /^zdx-demo >$/
Hide
Type@0 "_zdx_demo_check $?; print -r -- DEMO_SYS_RETURN:$?"
Enter
Wait+Screen /DEMO_SYS_RETURN:0/
Type@0 "clear; zdx ai"
Enter
Wait+Screen /ai >/
Show
Sleep 1200ms
Type "all assistants"
Wait+Screen /Command: ai-update/
Sleep 4s
Ctrl+U
Type "diagnose mcp"
Wait+Screen /Command: ai-mcp-doctor/
Sleep 3500ms
Escape
Wait+Line /^zdx-demo >$/
Hide
Type@0 "_zdx_demo_check $?; print -r -- DEMO_AI_RETURN:$?"
Enter
Wait+Screen /DEMO_AI_RETURN:0/
Type@0 "clear; zdx git"
Enter
Wait+Screen /git >/
Show
Sleep 1200ms
Type "diffs"
Wait+Screen /Command: git-diff/
Sleep 2500ms
Ctrl+U
Type "pull"
Wait+Screen /Command: git-pull/
Sleep 3s
Escape
Wait+Line /^zdx-demo >$/
Hide
Type@0 "_zdx_demo_check $?; print -r -- DEMO_GIT_RETURN:$?"
Enter
Wait+Screen /DEMO_GIT_RETURN:0/
Type@0 "clear; zdx file"
Enter
Wait+Screen /file >/
Show
Sleep 1s
Type "search files"
Wait+Screen /Command: file-find/
Sleep 3s
Escape
Wait+Line /^zdx-demo >$/
Hide
Type@0 "_zdx_demo_check $?; _zdx_demo_finish"
Enter
Wait+Screen /DEMO_COMPLETE/
Type@0 "exit"
Enter
