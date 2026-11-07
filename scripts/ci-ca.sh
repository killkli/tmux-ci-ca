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
# The script reads the copy-mode cursor, captures the pane buffer, computes
# the enclosed range with depth-counted bracket matching and vim quote
# semantics over the full scrollback, then drives the tmux selection with
# chained copy-mode commands.
#
# Options (tmux server options):
#   @ci-ca-copy-on-select  "1" copies the selection and leaves copy mode
#                          (default: select and stay, like vim visual mode)
#   @ci-ca-notify          "1" shows a status message on failure (default)
#
# Exit codes: 0 matched and selection driven; 1 no enclosing pair.

set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AWK="${AWK:-awk}"

discover_pane() {
    # prefer the active pane of an active window among those in copy mode
    tmux list-panes -a -F '#{pane_in_mode} #{window_active} #{pane_active} #{pane_id}' \
        | awk '$1 == "1" { if ($2 == "1" && $3 == "1") print "0 " $4; else print "1 " $4 }' \
        | sort | head -1 | cut -d' ' -f2-
}

notify_fail() {
    local notify
    notify=$(tmux show-options -gv '@ci-ca-notify' 2>/dev/null || true)
    [[ $notify == 0 ]] || tmux display-message -t "$PANE" \
        "tmux-ci-ca: no enclosing ${SCOPE} ${PAIR} around cursor"
}

SCOPE=${1:?(usage: ci-ca.sh <inner|around> <pair-name> [pane])}
PAIR=${2:?}
PANE=${3:-}

case $PAIR in
    paren)   OPEN='(' CLOSE=')' ;;
    brace)   OPEN='{' CLOSE='}' ;;
    bracket) OPEN='[' CLOSE=']' ;;
    angle)   OPEN='<' CLOSE='>' ;;
    dq)      OPEN='"' CLOSE='"' ;;
    sq)      OPEN="'" CLOSE="'" ;;
    bt)      OPEN='`' CLOSE='`' ;;
    *) printf 'unknown pair: %s\n' "$PAIR" >&2; exit 2 ;;
esac

# --- resolve the pane ---------------------------------------------------
if [[ -z $PANE ]]; then
    PANE=$(discover_pane)
fi
[[ -n $PANE ]] || { notify_fail; exit 1; }

# --- read copy-mode state ----------------------------------------------
IFS=, read -r CX CY SP HIST H \
    <<< "$(tmux display-message -p -t "$PANE" \
        '#{copy_cursor_x},#{copy_cursor_y},#{scroll_position},#{history_size},#{pane_height}')" || exit 1
[[ ${CX:-} =~ ^[0-9]+$ && ${CY:-} =~ ^[0-9]+$ ]] || exit 1
HIST=${HIST:-0}
SP=${SP:-0}
H=${H:-0}
ABS_ROW=$((HIST - SP + CY))

# --- compute the range --------------------------------------------------
MATCHED=$(LC_ALL=C "$AWK" -v scope="$SCOPE" -v ochar="$OPEN" -v cchar="$CLOSE" \
    -v currow="$ABS_ROW" -v curcx="$CX" -f "$DIR/surround.awk" \
    <<< "$(tmux capture-pane -p -S - -E - -t "$PANE")") || exit 1
[[ -n ${MATCHED:-} ]] || { notify_fail; exit 1; }
read -r R1 _C1 R2 _C2 _ENDLEN P1 P2 <<< "$MATCHED"

# --- drive the selection ------------------------------------------------
# tmux selection captures the half-open range [anchor, cursor): the cursor
# must rest one cell past the last included cell. end-of-line rests on the
# virtual end-of-line position, which includes the final cell.
#
# Vertical movement chains cursor-down/up from the cheaper anchor
# (history-top / history-bottom / current cursor). Horizontal movement
# chains cursor-right from start-of-line. Commands are batched into a few
# tmux invocations separated by ";" so latency stays flat.

CUR_ROW=$ABS_ROW
TOTAL=$((HIST + H))
ARGS=()

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
    # tmux command separator between chained groups
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

# start point (cursor-right steps over chars, not cells)
goto_row "$R1"
x start-of-line
n=$P1
while ((n--)); do x cursor-right
done
x begin-selection

# end point (cursor rests one past the last included cell)
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
