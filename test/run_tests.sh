#!/usr/bin/env bash
# Exercise the installed plugin through a real attached tmux client's keys.
# Requires tmux 3.2+, Python 3 for a PTY, and a UTF-8-capable environment.
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
REAL_TMUX=$(command -v tmux) || { echo 'tmux not found' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo 'python3 not found' >&2; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/tmux-ci-ca.XXXXXXXX") || exit 1
PASS=0
FAIL=0
CLIENT_PID=

cleanup() {
    "$REAL_TMUX" -S "$TMP/socket" kill-server >/dev/null 2>&1 || :
    if [ -n "$CLIENT_PID" ]; then
        kill "$CLIENT_PID" >/dev/null 2>&1 || :
        wait "$CLIENT_PID" 2>/dev/null || :
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# Plugin subprocesses must use the same private server as the harness.
PLUGIN="$TMP/plugin ' # spaces"
mkdir "$TMP/bin" "$PLUGIN"
printf '#!/usr/bin/env bash\nexec %q -S %q "$@"\n' "$REAL_TMUX" "$TMP/socket" > "$TMP/bin/tmux"
chmod +x "$TMP/bin/tmux"
export PATH="$TMP/bin:$PATH"
cp "$DIR/tmux-ci-ca.tmux" "$PLUGIN/"
cp -R "$DIR/scripts" "$PLUGIN/"

# Python supplies a real PTY even when the test runner has no terminal.
mkfifo "$TMP/input"
exec 3<>"$TMP/input"
export TERM=xterm-256color
tmux -f /dev/null new-session -d -s cica -x 80 -y 10 'sleep 600' || exit 1
tmux set-option -g mode-keys vi
tmux set-option -g history-limit 2000
tmux set-option -g status off
tmux set-option -s escape-time 10
bash "$PLUGIN/tmux-ci-ca.tmux" || exit 1
python3 -c 'import pty; pty.spawn(["tmux", "attach-session", "-t", "cica"])' \
    < "$TMP/input" > "$TMP/client.log" 2>&1 &
CLIENT_PID=$!
i=0
while [ "$i" -lt 100 ]; do
    CLIENT=$(tmux list-clients -F '#{client_name}' 2>/dev/null)
    [ -n "$CLIENT" ] && break
    sleep 0.05
    i=$((i + 1))
done
if [ -z "${CLIENT:-}" ]; then
    echo 'Could not attach tmux test client' >&2
    cat "$TMP/client.log" >&2
    exit 1
fi

PANE=$(tmux display-message -p -t cica '#{pane_id}')
new_pane() {
    # A new window gives each case an empty history and selection. The marker
    # provides a bounded readiness check without assuming a shell startup time.
    local old=$PANE i=0 captured
    printf '%s\n%s\n' "$1" '__CI_CA_READY__' > "$TMP/fixture"
    PANE=$(tmux new-window -P -F '#{pane_id}' -t cica "cat '$TMP/fixture'; sleep 600") || exit 1
    tmux kill-pane -t "$old"
    tmux resize-window -t "$PANE" -x 80 -y 10
    while [ "$i" -lt 100 ]; do
        captured=$(tmux capture-pane -p -t "$PANE" -S -2000)
        case $captured in *'__CI_CA_READY__'*) return 0 ;; esac
        sleep 0.05
        i=$((i + 1))
    done
    echo 'Fixture did not appear in pane' >&2
    exit 1
}
position() { # physical history row, then number of cursor-right operations
    local row=$1 col=$2 i
    tmux copy-mode -t "$PANE"
    tmux send-keys -t "$PANE" -X history-top
    tmux send-keys -t "$PANE" -X start-of-line
    for ((i=0; i<row; i++)); do tmux send-keys -t "$PANE" -X cursor-down; done
    for ((i=0; i<col; i++)); do tmux send-keys -t "$PANE" -X cursor-right; done
}
keys() {
    # Send real terminal input through the attached client.
    local text=$1 ch
    while [ -n "$text" ]; do
        ch=${text%"${text#?}"}
        text=${text#?}
        printf '%s' "$ch" >&3
        sleep 0.03
    done
}
mode() { tmux display-message -p -t "$PANE" '#{pane_in_mode}'; }
selected() { tmux display-message -p -t "$PANE" '#{selection_present}'; }
wait_selected() {
    local i=0
    while [ "$i" -lt 100 ]; do
        [ "$(selected)" = 1 ] && return 0
        sleep 0.05
        i=$((i + 1))
    done
    return 1
}
wait_normal() {
    local i=0
    while [ "$i" -lt 100 ]; do
        [ "$(mode)" = 0 ] && return 0
        sleep 0.05
        i=$((i + 1))
    done
    return 1
}
check() { # label, actual, expected
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL %s: got [%s], expected [%s]\n' "$1" "$2" "$3" >&2
    fi
}
selection_case() { # label, fixture, row, column, keys, expected
    local label=$1 expected=$6 actual
    new_pane "$2"
    position "$3" "$4"
    tmux set-buffer 'STALE BUFFER'
    keys "$5"
    check "$label stays in copy mode" "$(mode)" 1
    # y is sent through the client too: it must copy and exit copy mode.
    keys y
    wait_normal || :
    # Preserve trailing newlines that command substitution would strip.
    actual=$(tmux show-buffer 2>/dev/null; printf '.')
    check "$label copied text" "$actual" "$expected."
    check "$label exits after y" "$(mode)" 0
}

selection_case 'ci(' 'calc (alpha beta) done' 0 7 'ci(' 'alpha beta'
selection_case 'ca)' 'calc (alpha beta) done' 0 7 'ca)' '(alpha beta)'
selection_case 'single character' '(x)' 0 1 'ci(' 'x'
new_pane 'x (.) y'
position 0 3
keys 'ci('
i=0
while [ "$i" -lt 100 ]; do
    active=$(tmux display-message -p -t "$PANE" '#{selection_active}')
    [ "$active" = 1 ] && break
    sleep 0.05
    i=$((i + 1))
done
check 'single character has an active selection' "$active" 1
keys y
wait_normal || :
check 'single punctuation copies exactly' "$(tmux show-buffer 2>/dev/null || :)" '.'
selection_case 'closing delimiter at EOL' '(x)' 0 1 'ca(' '(x)'
selection_case 'around empty pair' '()' 0 0 'ca(' '()'

# Each documented key is exercised through the client in both scopes.
for key in '(' ')' b; do
    selection_case "ci$key alias" 'x (value) z' 0 4 "ci$key" 'value'
    selection_case "ca$key alias" 'x (value) z' 0 4 "ca$key" '(value)'
done
for key in '{' '}' B; do
    selection_case "ci$key alias" 'x {value} z' 0 4 "ci$key" 'value'
    selection_case "ca$key alias" 'x {value} z' 0 4 "ca$key" '{value}'
done
for key in '[' ']'; do
    selection_case "ci$key alias" 'x [value] z' 0 4 "ci$key" 'value'
    selection_case "ca$key alias" 'x [value] z' 0 4 "ca$key" '[value]'
done
for key in '<' '>'; do
    selection_case "ci$key alias" 'x <value> z' 0 4 "ci$key" 'value'
    selection_case "ca$key alias" 'x <value> z' 0 4 "ca$key" '<value>'
done
for key in '"' "'" '`'; do
    case $key in
        '"') text='x "value" z'; enclosed='"value"' ;;
        "'") text="x 'value' z"; enclosed="'value'" ;;
        '`') text='x `value` z'; enclosed='`value`' ;;
    esac
    selection_case "ci$key alias" "$text" 0 4 "ci$key" 'value'
    selection_case "ca$key alias" "$text" 0 4 "ca$key" "$enclosed"
done

selection_case 'cib nested' 'f(a, (b + c), d)' 0 7 'cib' 'b + c'
selection_case 'ci nested outer' 'f(a, (b + c), d)' 0 13 'ci(' 'a, (b + c), d'
selection_case 'ciB' 'x {brace} y' 0 4 'ciB' 'brace'
selection_case 'ca]' 'x [bracket] y' 0 4 'ca]' '[bracket]'
selection_case 'ci>' 'x <angle> y' 0 4 'ci>' 'angle'
selection_case 'ci double quote' 'say "hello world" done' 0 6 'ci"' 'hello world'
selection_case 'escaped double quote' 'say "hello \"world\"!" done' 0 12 'ci"' 'hello \"world\"!'
filler76=$(printf '%076d' 0)
soft_quote='x "'"$filler76"'\"tail" z'
selection_case 'escaped quote at soft wrap' "$soft_quote" 0 4 'ci"' "$filler76"'\"tail'
hard_quote='x "'"$filler76"'\'$'\n''" z'
selection_case 'quote after hard newline' "$hard_quote" 0 4 'ci"' "$filler76"'\'$'\n'
selection_case 'ca single quote' "say 'hello' done" 0 6 "ca'" "'hello'"
selection_case 'ci backtick' 'say `hello` done' 0 6 'ci`' 'hello'
selection_case 'emoji sequence inside pair' 'x (A👩‍💻B) y' 0 4 'ci(' 'A👩‍💻B'
selection_case 'emoji sequence before pair' '👩‍💻 x (value) y' 0 6 'ci(' 'value'
selection_case 'emoji skin tone' 'x (A👍🏽B) y' 0 4 'ci(' 'A👍🏽B'
selection_case 'emoji flag' 'x (A🇹🇼B) y' 0 4 'ci(' 'A🇹🇼B'
# Some tmux releases insert a padding space into their own captured grid.
# The object must copy exactly the text present in that grid.
new_pane 'x (A❤️B) y'
captured=$(tmux capture-pane -p -t "$PANE")
first_line=${captured%%$'\n'*}
variation_expected=${first_line#*\(}
variation_expected=${variation_expected%%\)*}
position 0 4
tmux set-buffer 'STALE BUFFER'
keys 'ci('
keys y
wait_normal || :
check 'emoji variation selector' "$(tmux show-buffer 2>/dev/null || :)" "$variation_expected"
selection_case 'emoji variation before pair' '❤️ (x)' 0 4 'ci(' 'x'
selection_case 'emoji skin tone before pair' '👍🏽 (x)' 0 4 'ci(' 'x'
selection_case 'emoji flag before pair' '🇹🇼 (x)' 0 4 'ci(' 'x'
selection_case 'half-width kana before pair' 'ｱｲｳ (x)' 0 6 'ci(' 'x'
selection_case 'CJK brackets' '前 【內容】 後' 0 4 'ci[' '內容'
selection_case 'curly quotes' '中文 “內容測試” 結束' 0 4 'ci"' '內容測試'
selection_case 'full-width parentheses' '前 （內容） 後' 0 4 'ca(' '（內容）'
selection_case 'multiline' 'multi = foo(arg1,
    arg2,
    arg3);
end' 1 6 'ci(' 'arg1,
    arg2,
    arg3'
selection_case 'hard newline boundaries' '(
first

last
)' 1 2 'ci(' '
first

last
'
check 'multiline preserves inherited mode-keys' "$(tmux show-options -wqv -t "$PANE" mode-keys)" ''
selection_case 'leading hard newline' '(
inside)' 1 2 'ci(' '
inside'
selection_case 'trailing hard newline' '(inside
)' 0 2 'ci(' 'inside
'
selection_case 'newline-only inner' '(

)' 0 0 'ci(' '

'
selection_case 'soft wrap' '(012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789)' 0 5 'ci(' '012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789'
filler=$(printf '%079d' 0)
selection_case 'opening at soft wrap' "${filler}(word)" 1 1 'ci(' 'word'
selection_case 'closing at soft wrap' "($filler)" 0 2 'ci(' "$filler"
new_pane "${filler}()"
position 0 79
keys 'ci('
sleep 0.2
check 'empty soft wrap keeps copy mode' "$(mode)" 1
check 'empty soft wrap leaves selection untouched' "$(selected)" 0
selection_case 'scrollback' '(top
pad1
pad2
pad3
pad4
pad5
pad6
pad7
pad8
mid) done
pad10
pad11
pad12
pad13
pad14
pad15
pad16
pad17
pad18
pad19
pad20
pad21
pad22
pad23
pad24
pad25' 5 2 'ci(' 'top
pad1
pad2
pad3
pad4
pad5
pad6
pad7
pad8
mid'

# A window-local mode-keys setting must survive multiline positioning too.
new_pane '(first
second)'
tmux set-window-option -t "$PANE" mode-keys vi
position 0 2
keys 'ci('
keys y
wait_normal || :
check 'multiline preserves local mode-keys' "$(tmux show-options -wqv -t "$PANE" mode-keys)" vi
check 'local mode selection text' "$(tmux show-buffer)" 'first
second'

new_pane '(first
second)'
position 0 2
tmux send-keys -t "$PANE" -X rectangle-on
keys 'ci('
keys y
wait_normal || :
check 'text object replaces rectangle mode' "$(tmux show-buffer)" 'first
second'

# On tmux versions supporting capture-pane -M, the copy-mode snapshot must
# remain the source even if the underlying process scrolls after entry.
case $(tmux list-commands capture-pane) in
    *M*)
        new_pane '(snapshot)
pad1
pad2
pad3
pad4
pad5
pad6
pad7
pad8
pad9
pad10
pad11'
        position 0 3
        pane_tty=$(tmux display-message -p -t "$PANE" '#{pane_tty}')
        printf 'new1\nnew2\nnew3\nnew4\nnew5\nnew6\nnew7\nnew8\nnew9\nnew10\n__LIVE_END__\n' > "$pane_tty"
        i=0
        while [ "$i" -lt 100 ]; do
            captured=$(tmux capture-pane -p -t "$PANE")
            case $captured in *'__LIVE_END__'*) break ;; esac
            sleep 0.05
            i=$((i + 1))
        done
        if [ "$i" -eq 100 ]; then
            FAIL=$((FAIL + 1))
            echo 'FAIL live output did not reach pane' >&2
        fi
        keys 'ci('
        keys y
        wait_normal || :
        check 'copy mode uses original snapshot' "$(tmux show-buffer 2>/dev/null || :)" snapshot
        ;;
esac

# A failed operation must preserve an existing native selection, not merely
# leave some selection flag set. Copy it without clearing before and after.
for fixture in 'nothing here' 'empty () pair'; do
    new_pane "$fixture"
    case $fixture in
        'empty () pair') position 0 5 ;;
        *) position 0 0 ;;
    esac
    tmux send-keys -t "$PANE" -X begin-selection
    tmux send-keys -t "$PANE" -X cursor-right
    tmux send-keys -t "$PANE" -X copy-selection-no-clear
    before=$(tmux show-buffer)
    keys 'ci('
    sleep 0.5
    check "$fixture keeps mode" "$(mode)" 1
    check "$fixture keeps selection" "$(selected)" 1
    tmux send-keys -t "$PANE" -X copy-selection-no-clear
    check "$fixture preserves text" "$(tmux show-buffer)" "$before"
done

new_pane 'no delimiters'
position 0 3
tmux set-option -g @ci-ca-notify 0
keys 'ci>'
sleep 0.2
messages=$(tmux show-messages -t "$CLIENT")
case $messages in *'tmux-ci-ca: no enclosing inner angle'*) present=1 ;; *) present=0 ;; esac
check 'notify option suppresses hint' "$present" 0
tmux set-option -g @ci-ca-notify 1
keys 'ci>'
sleep 0.2
messages=$(tmux show-messages -t "$CLIENT")
case $messages in *'tmux-ci-ca: no enclosing inner angle'*) present=1 ;; *) present=0 ;; esac
check 'notify option enables hint' "$present" 1
tmux set-option -gu @ci-ca-notify

new_pane 'x (abort works) y'
position 0 4
keys 'ci'
printf '\033' >&3
sleep 0.2
check 'escape abort keeps copy mode' "$(mode)" 1
check 'escape abort has no selection' "$(selected)" 0
keys 'ci('
if wait_selected; then
    keys y
    wait_normal || :
    check 'selection after abort' "$(tmux show-buffer 2>/dev/null || :)" 'abort works'
else
    check 'selection after abort' "$(selected)" 1
fi

new_pane 'x (still here) y'
position 0 4
keys 'ciq'
sleep 0.2
check 'unknown key abort keeps copy mode' "$(mode)" 1
keys 'ci('
keys y
wait_normal || :
check 'selection after unknown key' "$(tmux show-buffer 2>/dev/null || :)" 'still here'

new_pane 'x (auto copy) y'
position 0 4
tmux set-option -g @ci-ca-copy-on-select 1
tmux set-buffer 'STALE BUFFER'
keys 'ci('
wait_normal || :
check 'copy-on-select exits copy mode' "$(mode)" 0
check 'copy-on-select text' "$(tmux show-buffer 2>/dev/null || :)" 'auto copy'
tmux set-option -g @ci-ca-copy-on-select 0

# Both panes are in copy mode; the client-selected pane must be targeted.
new_pane 'x (correct pane) y'
OTHER=$(tmux split-window -h -P -F '#{pane_id}' -t "$PANE" 'sleep 600')
tmux copy-mode -t "$OTHER"
tmux select-pane -t "$PANE"
position 0 4
keys 'ci('
if wait_selected; then
    check 'other pane remains unselected' "$(tmux display-message -p -t "$OTHER" '#{selection_present}')" 0
    keys y
    wait_normal || :
    check 'multi-pane target text' "$(tmux show-buffer 2>/dev/null || :)" 'correct pane'
    check 'other pane remains in copy mode' "$(tmux display-message -p -t "$OTHER" '#{pane_in_mode}')" 1
else
    check 'multi-pane target selection' "$(selected)" 1
fi

# Reloading the plugin must not replace an existing user-provided y binding.
tmux bind-key -T copy-mode-vi y send-keys -X copy-selection-no-clear
bash "$PLUGIN/tmux-ci-ca.tmux"
new_pane 'x (custom y) z'
position 0 4
tmux set-buffer 'STALE BUFFER'
keys 'ci('
keys y
i=0
while [ "$i" -lt 100 ]; do
    [ "$(tmux show-buffer 2>/dev/null)" = 'custom y' ] && break
    sleep 0.05
    i=$((i + 1))
done
check 'existing y binding copies' "$(tmux show-buffer 2>/dev/null || :)" 'custom y'
check 'existing y binding remains in copy mode' "$(mode)" 1

printf 'pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
