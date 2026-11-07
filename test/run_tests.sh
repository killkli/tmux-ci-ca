#!/usr/bin/env bash
# Integration tests: drive a real tmux server (isolated socket) through the
# same code path the bindings use and assert the captured selection.
#
# Socket isolation: the harness exports a tmux() wrapper (bash exported
# function) so every tmux call made by the harness AND by the plugin
# scripts lands on the throwaway server.

set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
S=tmuxcica-tests

PASS=0
FAIL=0

# PATH shim: every tmux call in the harness and the plugin scripts lands
# on the throwaway socket (no reliance on exported functions).
SHIM="$(mktemp -d)"
printf '#!/bin/sh\nexec /opt/homebrew/bin/tmux -L %s "$@"\n' "$S" > "$SHIM/tmux"
chmod +x "$SHIM/tmux"
export PATH="$SHIM:$PATH"

new_pane() { # $1 = inner printf/setup command (no single quotes); echoes pane id
    tmux -L $S -f /dev/null kill-server 2>/dev/null
    tmux -L $S -f /dev/null new-session -d -x 80 -y 10 -P -F '#{pane_id}' \
        "sh -c '$1; sleep 600'"
}

enter_copy() {
    sleep 0.4
    tmux -L $S copy-mode -t "$PANE"
    sleep 0.2
    tmux -L $S send-keys -t "$PANE" -X history-top
}

# position cursor: row (0-based buffer row), col (0-based cell)
pos() {
    local r=$1 c=$2 i
    while ((r-- > 0)); do tmux -L $S send-keys -t "$PANE" -X cursor-down; done
    tmux -L $S send-keys -t "$PANE" -X start-of-line
    for ((i = 0; i < c; i++)); do tmux -L $S send-keys -t "$PANE" -X cursor-right; done
}

run_ca() { # scope pair-name [pane]
    "$DIR/scripts/ci-ca.sh" "$1" "$2" "${3:-$PANE}"
}

selection() {
    tmux -L $S send-keys -t "$PANE" -X copy-selection-and-cancel
    sleep 0.15
    tmux -L $S show-buffer
}

ok() {
    PASS=$((PASS + 1))
}

bad() {
    FAIL=$((FAIL + 1))
    echo "FAIL $1: got [$2] want [$3]"
}

# --- scenario 1: ci" on one line ---------------------------------------
PANE=$(new_pane 'printf "say \"hello world\" done\n"')
enter_copy
pos 0 5
run_ca inner dq; rc=$?
SEL=$(selection)
[[ $rc == 0 && $SEL == 'hello world' ]] && ok || bad "ci\" single line" "$SEL (rc=$rc)" 'hello world'

# --- scenario 2: ca( includes brackets ----------------------------------
PANE=$(new_pane 'printf "calc (alpha beta) done\n"')
enter_copy
pos 0 6
run_ca around paren; rc=$?
SEL=$(selection)
[[ $rc == 0 && $SEL == '(alpha beta)' ]] && ok || bad "ca(" "$SEL (rc=$rc)" '(alpha beta)'

# --- scenario 3: nested ci( picks the inner pair -------------------------
PANE=$(new_pane 'printf "f(a, (b + c), d)\n"')
enter_copy
pos 0 7
run_ca inner paren; rc=$?
SEL=$(selection)
[[ $rc == 0 && $SEL == 'b + c' ]] && ok || bad "ci( nested inner" "$SEL (rc=$rc)" 'b + c'
enter_copy
pos 0 13
run_ca inner paren; rc=$?
SEL=$(selection)
[[ $rc == 0 && $SEL == 'a, (b + c), d' ]] && ok || bad "ci( nested outer" "$SEL (rc=$rc)" 'a, (b + c), d'

# --- scenario 4: pair across physical rows ------------------------------
WANT='arg1,
    arg2,
    arg3'
PANE=$(new_pane 'printf "multi = foo(arg1,\n    arg2,\n    arg3);\nend\n"')
enter_copy
pos 1 6
run_ca inner paren; rc=$?
SEL=$(selection)
[[ $rc == 0 && $SEL == "$WANT" ]] && ok || bad "ci( multiline" "$(echo "$SEL" | head -1)..." "$WANT"

# --- scenario 5: pair spanning scrollback history -------------------------
# row0=(top rows1-8 pads row9=mid) rows10-25 pads below; cursor at row 5.
# inner = top + pad1..pad8 + mid (10 lines); exercises history-top anchor
# and a 9-row vertical move.
PANE=$(new_pane 'printf "(top\n"; for i in 1 2 3 4 5 6 7 8; do echo "pad$i"; done; printf "mid) done\n"; for i in 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do echo "pad$i"; done')
enter_copy
pos 5 4
run_ca inner paren; rc=$?
SEL=$(selection)
LINES=$(printf '%s\n' "$SEL" | wc -l | tr -d ' ')
FIRST=$(printf '%s\n' "$SEL" | head -1)
LAST=$(printf '%s\n' "$SEL" | tail -1)
[[ $rc == 0 && $LINES == 10 && $FIRST == 'top' && $LAST == 'mid' ]] && ok || bad "ci( scrollback span" "lines=$LINES first=$FIRST last=$LAST (rc=$rc)" '10 lines top..mid'

# --- scenario 6: no pair fails closed ------------------------------------
PANE=$(new_pane 'printf "nothing here\n"')
enter_copy
pos 0 4
run_ca inner paren; rc=$?
[[ $rc == 1 ]] && ok || bad "no pair exit code" "rc=$rc" 'rc=1'

# --- scenario 6b: pane discovery (binding passes no pane id) --------------
PANE=$(new_pane 'printf "say \"found by discovery\" done\n"')
enter_copy
pos 0 5
run_ca inner dq ''; rc=$?
SEL=$(selection)
[[ $rc == 0 && $SEL == 'found by discovery' ]] && ok || bad "pane discovery" "$SEL (rc=$rc)" 'found by discovery'

# --- scenario 7: empty inner fails ---------------------------------------
PANE=$(new_pane 'printf "empty () pair\n"')
enter_copy
pos 0 9
run_ca inner paren; rc=$?
[[ $rc == 1 ]] && ok || bad "empty inner exit code" "rc=$rc" 'rc=1'

# --- scenario 8: wide characters -----------------------------------------
PANE=$(new_pane 'printf "中文 \"內容測試\" 結束\n"')
enter_copy
pos 0 7
run_ca inner dq; rc=$?
SEL=$(selection)
[[ $rc == 0 && $SEL == '內容測試' ]] && ok || bad "ci\" wide chars" "$SEL (rc=$rc)" '內容測試'

# --- scenario 9: copy-on-select option -----------------------------------
PANE=$(new_pane 'printf "say \"auto copy\" done\n"')
enter_copy
pos 0 5
tmux -L $S set-option -g '@ci-ca-copy-on-select' '1'
run_ca inner dq; rc=$?
SEL=$(tmux -L $S show-buffer 2>/dev/null)
tmux -L $S set-option -g '@ci-ca-copy-on-select' '0'
[[ $rc == 0 && $SEL == 'auto copy' ]] && ok || bad "copy-on-select" "$SEL (rc=$rc)" 'auto copy'

# --- scenario 10: dq binding + script path --------------------------------
# Bindings pass no pane id (formats do not survive bind-key storage); the
# script discovers the pane in copy mode by itself.
PANE=$(new_pane 'printf "say \"expanded\" done\n"')
enter_copy
pos 0 5
run_ca inner dq; rc=$?
SEL=$(selection)
[[ $rc == 0 && $SEL == 'expanded' ]] && ok || bad "ci\" on quote line" "$SEL (rc=$rc)" 'expanded'

# --- scenario 11: bindings installed -------------------------------------
tmux -L $S -f /dev/null kill-server 2>/dev/null
tmux -L $S -f /dev/null new-session -d -x 80 -y 10
bash "$DIR/tmux-ci-ca.tmux" >/dev/null 2>&1
KEYS=$(tmux -L $S list-keys -T copy-mode-vi 2>/dev/null | grep -c 'switch-client -T ci-ca-inner')
[[ $KEYS == 1 ]] && ok || bad "i binding" "$KEYS" 1
KEYS=$(tmux -L $S list-keys -T copy-mode-vi 2>/dev/null | grep -c 'switch-client -T ci-ca-around')
[[ $KEYS == 1 ]] && ok || bad "a binding" "$KEYS" 1
KEYS=$(tmux -L $S list-keys -T ci-ca-inner 2>/dev/null | grep -c 'run-shell -b')
[[ $KEYS == 13 ]] && ok || bad "inner pair binds" "$KEYS" 13
KEYS=$(tmux -L $S list-keys -T ci-ca-inner 2>/dev/null | grep -c 'Any')
[[ $KEYS == 1 ]] && ok || bad "Any fallback" "$KEYS" 1

# --- teardown ------------------------------------------------------------
tmux -L $S -f /dev/null kill-server 2>/dev/null
rm -rf "$SHIM"
echo "pass=$PASS fail=$FAIL"
((FAIL == 0))
