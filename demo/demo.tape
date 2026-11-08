Output "assets/demo.gif"
Output "assets/demo.mp4"

Set Shell "bash"
Set FontSize 18
Set Width 1100
Set Height 640
Set Theme "Catppuccin Mocha"
Set WindowBar Colorful
Set Padding 20

# Launch tmux with tmux-ci-ca preloaded
Type "tmux -f demo/tmux.conf new-session 'demo/run.sh'"
Enter
Sleep 1500ms

# Enter vi copy mode
Ctrl+B
Type "["
Sleep 1s

# Move to top
Type "g"
Sleep 400ms

# ==========================================================
# 1. Nested Parentheses: ci( and ca(
# ==========================================================
Type "5j"
Sleep 300ms
Type "0"
Sleep 200ms
Type "f("
Sleep 250ms
Type ";"
Sleep 250ms
Type "l"
Sleep 500ms

# ci) - select inner
Type "c"
Sleep 150ms
Type "i"
Sleep 150ms
Type ")"
Sleep 2200ms

Escape
Sleep 400ms

# ca) - select around
Type "c"
Sleep 150ms
Type "a"
Sleep 150ms
Type ")"
Sleep 2200ms

Escape
Sleep 400ms

# ==========================================================
# 2. String Quotes: ci" and ca"
# ==========================================================
Type "3j"
Sleep 300ms
Type "0"
Sleep 200ms
Type "2w"
Sleep 200ms
Type "l"
Sleep 500ms

# ci" - select inner quotes
Type "c"
Sleep 150ms
Type "i"
Sleep 150ms
Type '"'
Sleep 2200ms

Escape
Sleep 400ms

# ca" - select around quotes
Type "c"
Sleep 150ms
Type "a"
Sleep 150ms
Type '"'
Sleep 2200ms

Escape
Sleep 400ms

# ==========================================================
# 3. CJK Twin Pairs: ASCII ci( matches fullwidth （...）
# ==========================================================
Type "3j"
Sleep 300ms
Type "0"
Sleep 200ms
Type "22l"
Sleep 500ms

# ci) on CJK fullwidth brackets
Type "c"
Sleep 150ms
Type "i"
Sleep 150ms
Type ")"
Sleep 2500ms

Escape
Sleep 400ms

# ==========================================================
# 4. Multiline Braces: ci{ across multiple lines
# ==========================================================
Type "4j"
Sleep 300ms
Type "w"
Sleep 500ms

# ci{ - select dictionary body
Type "c"
Sleep 150ms
Type "i"
Sleep 150ms
Type "{"
Sleep 2800ms

# Press y to copy & exit copy mode
Type "y"
Sleep 1500ms

# Cleanly exit tmux
Ctrl+B
Type ":"
Sleep 200ms
Type "kill-session"
Enter
Sleep 600ms
