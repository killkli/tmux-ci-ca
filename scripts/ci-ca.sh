#!/usr/bin/env bash
# tmux-ci-ca: complete vim-style ci/ca text objects for tmux copy mode.
#
# Usage: ci-ca.sh <scope> <pair-name> [pane]
#   scope: "inner" (ci) or "around" (ca)
#   pair-name: paren brace bracket angle dq sq bt (shell-safe words so the
#              binding survives tmux's command re-parser and sh -c)
#   pane: optional pane id in the form %N, currently in copy mode. Without
#         it the script discovers the pane currently in copy mode (bindings
#         pass no arguments: formats do not survive bind-key storage).
#
# Each pair-name maps to a CHARACTER CLASS: the ASCII pair and its CJK
# fullwidth/curly twins are interchangeable, so ci( also matches （）,
# ci" also matches “…” (curly quotes), ci[ also matches 【】.
#
# The range is computed by a matcher over the captured pane buffer (full
# scrollback) with nesting-depth counting, vim quote semantics and
# fail-closed behavior. The selection is then driven through tmux's native
# selection with vertical cursor chains plus horizontal search positioning
# (search-forward-text is immune to wide-glyph cell math).
#
# Always exits 0: tmux announces non-zero run-shell exits as an ugly
# "returned 1" status error; failures are reported through a status-line
# message instead (set -g @ci-ca-notify "0" to silence).
#
# Written for bash 3.2 (macOS stock) — no associative arrays.

set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AWK="${AWK:-awk}"

notify_fail() {
    local reason=${1:-no enclosing ${SCOPE} ${PAIR} around cursor} notify
    echo "tmux-ci-ca: $reason"
    notify=$(tmux show-options -gv '@ci-ca-notify' 2>/dev/null || true)
    [[ $notify == 0 ]] || tmux display-message -t "$PANE" "tmux-ci-ca: $reason"
}

SCOPE=${1:?usage: ci-ca.sh <inner|around> <pair-name> [pane]}
PAIR=${2:?usage: ci-ca.sh <inner|around> <pair-name> [pane]}
PANE=${3:-}

# opener/closer character classes (ASCII + CJK twins). Quote families count
# parity over ALL their characters; curly-only strings would use direction.
case $PAIR in
    paren)   OPENS="(（"    CLOSES=")）" ;;
    brace)   OPENS="{｛"    CLOSES="}｝" ;;
    bracket) OPENS="[［【"  CLOSES="]］】" ;;
    angle)   OPENS="<〈《"  CLOSES=">〉》" ;;
    dq)      OPENS='"“＂”' CLOSES='"“＂”' ;;
    sq)      OPENS="'‘’"    CLOSES="'‘’" ;;
    bt)      OPENS='`'      CLOSES='`' ;;
    *) printf 'unknown pair: %s\n' "$PAIR" >&2; exit 0 ;;
esac

# --- resolve the pane ---------------------------------------------------
if [[ -z $PANE ]]; then
    # prefer the active pane of an active window among those in copy mode
    PANE=$(tmux list-panes -a -F '#{pane_in_mode} #{window_active} #{pane_active} #{pane_id}' \
        | awk '$1 == "1" { if ($2 == "1" && $3 == "1") print "0 " $4; else print "1 " $4 }' \
        | sort | head -1 | cut -d' ' -f2-)
fi
[[ -n $PANE ]] || {
    notify_fail "no pane in copy mode"
    exit 0
}

# --- read copy-mode state ----------------------------------------------
IFS=, read -r CX CY SP HIST H \
    <<< "$(tmux display-message -p -t "$PANE" \
        '#{copy_cursor_x},#{copy_cursor_y},#{scroll_position},#{history_size},#{pane_height}')" || {
    notify_fail "pane is not in copy mode"
    exit 0
}
[[ ${CX:-} =~ ^[0-9]+$ && ${CY:-} =~ ^[0-9]+$ ]] || {
    notify_fail "pane is not in copy mode"
    exit 0
}
HIST=${HIST:-0}
SP=${SP:-0}
H=${H:-0}
ABS_ROW=$((HIST - SP + CY))

# --- compute the range --------------------------------------------------
MATCHED=$(LC_ALL=C "$AWK" -v scope="$SCOPE" -v opens="$OPENS" -v closes="$CLOSES" \
    -v currow="$ABS_ROW" -v curcx="$CX" -f "$DIR/surround.awk" \
    <<< "$(tmux capture-pane -p -S - -E - -t "$PANE")") || {
    notify_fail
    exit 0
}
read -r R1 C1 R2 C2 ENDLEN P1 P2 <<< "$MATCHED"

# --- drive the selection ------------------------------------------------
# tmux selection captures the half-open range [anchor, cursor). Horizontal
# positioning uses search-forward-text, whose cursor lands one cell past
# the match end — exactly the half-open capture end — and is immune to
# wide-glyph cell math. Vertical positioning chains cursor-down/up from the
# cheapest anchor (history-top / history-bottom / current cursor). Commands
# are batched into a few tmux invocations separated by ";". Search patterns
# are tmux-quoted: the CLI re-parses argv, so spaces, quotes and
# backslashes in pane text must be escaped or the pattern splits apart.

CUR_ROW=$ABS_ROW
TOTAL=$((HIST + H))
ARGS=()

tq() { # quote a string for tmux's command tokenizer (double-quoted form)
    local s=${1//'\'/'\\'}
    printf '"%s"' "${s//'"'/'\"'}"
}

flush() {
    if ((${#ARGS[@]} > 0)); then
        tmux "${ARGS[@]}"
    fi
    ARGS=()
}

x() {
    cmd send-keys -t "$PANE" -X "$@"
}

cmd() {
    if ((${#ARGS[@]} > 0)); then
        ARGS+=(";")
    fi
    ARGS+=("$@")
    if ((${#ARGS[@]} >= 3000)); then
        flush
    fi
}

goto_row() {
    local target=$1 d cost_cur cost_top cost_bot
    d=$((target - CUR_ROW))
    cost_cur=$((d > 0 ? d : -d))
    cost_top=$((target + 1))
    cost_bot=$((TOTAL - target))
    if ((cost_top < cost_cur && cost_top <= cost_bot)); then
        x history-top
        CUR_ROW=0
        d=$target
    elif ((cost_bot < cost_cur)); then
        x history-bottom
        CUR_ROW=$((TOTAL - 1))
        d=$((target - CUR_ROW))
    fi
    if ((d > 0)); then
        while ((d--)); do x cursor-down
        done
    elif ((d < 0)); then
        d=$((-d))
        while ((d--)); do x cursor-up
        done
    fi
    CUR_ROW=$target
}

# Start point: vertical chain to the row, then char-step to the column.
# cursor-right advances one character per call (wide glyphs span two cells),
# so the step count is the character index from the matcher.
goto_row "$R1"
x start-of-line
n=$P1
while ((n--)); do x cursor-right
done
x begin-selection

# End point: char-step past the last included cell (or to the virtual
# end-of-line when the pair ends the row).
goto_row "$R2"
x start-of-line
if ((P2 >= 0)); then
    n=$P2
    while ((n--)); do x cursor-right
    done
else
    x end-of-line
fi

flush

# optional auto-copy
COPY_ON_SELECT=$(tmux show-options -gv '@ci-ca-copy-on-select' 2>/dev/null || true)
if [[ $COPY_ON_SELECT == 1 ]]; then
    tmux send-keys -t "$PANE" -X copy-selection-and-cancel
fi
exit 0
