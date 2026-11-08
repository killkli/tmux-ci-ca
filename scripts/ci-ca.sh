#!/usr/bin/env bash
# tmux-ci-ca: complete vim-style ci/ca text objects for tmux copy mode.
#
# Usage: ci-ca.sh <scope> <pair-name> <pane>
#   scope: "inner" (ci) or "around" (ca)
#   pair-name: paren brace bracket angle dq sq bt
#   pane: the pane ID resolved by tmux at the keypress
#
# Each pair-name maps to a CHARACTER CLASS: the ASCII pair and its CJK
# fullwidth/curly twins are interchangeable, so ci( also matches （）,
# ci" also matches “…” (curly quotes), ci[ also matches 【】.
#
# The range is computed by a matcher over the captured pane buffer (full
# scrollback) with nesting-depth counting, vim quote semantics and
# fail-closed behavior. The selection is then driven through tmux's native
# selection with vertical and horizontal cursor navigation.
#
# Expected failures are reported through a status-line message instead of
# writing to stdout, which would open a separate tmux view-mode pane.
#
# Written for bash 3.2 (macOS stock) — no associative arrays.

set -u
set -o pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AWK="${AWK:-awk}"

notify_fail() {
    local reason=${1:-no enclosing ${SCOPE} ${PAIR} around cursor} notify
    notify=$(tmux show-options -gv '@ci-ca-notify' 2>/dev/null || true)
    if [[ $notify != 0 ]]; then
        tmux display-message -t "$PANE" "tmux-ci-ca: $reason" 2>/dev/null || true
    fi
}

if (($# != 3)); then
    tmux display-message "tmux-ci-ca: invalid invocation" 2>/dev/null || true
    exit 0
fi
SCOPE=$1
PAIR=$2
PANE=$3
if [[ ! $PANE =~ ^%[0-9]+$ ]]; then
    tmux display-message "tmux-ci-ca: invalid pane" 2>/dev/null || true
    exit 0
fi

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
    *) notify_fail "unknown pair: $PAIR"; exit 0 ;;
esac

case $SCOPE in
    inner|around) ;;
    *) notify_fail "invalid selection scope"; exit 0 ;;
esac

# --- read copy-mode state ----------------------------------------------
IFS=, read -r CX CY SP HIST H IN_MODE \
    <<< "$(tmux display-message -p -t "$PANE" \
        '#{copy_cursor_x},#{copy_cursor_y},#{scroll_position},#{history_size},#{pane_height},#{pane_in_mode}')" || {
    notify_fail "pane is not in copy mode"
    exit 0
}
[[ ${IN_MODE:-0} == 1 && ${CX:-} =~ ^[0-9]+$ && ${CY:-} =~ ^[0-9]+$ ]] || {
    notify_fail "pane is not in copy mode"
    exit 0
}
HIST=${HIST:-0}
SP=${SP:-0}
H=${H:-0}
ABS_ROW=$((HIST - SP + CY))

# tmux's treatment of combined emoji changed across releases.
ZWJ=0
ZWJ_ASCII=0
MODIFIERS=0
VARIATION_WIDE=0
VERSION=$(tmux display-message -p -t "$PANE" '#{version}')
if [[ $VERSION =~ ^([0-9]+)\.([0-9]+) ]]; then
    MAJOR=${BASH_REMATCH[1]}
    MINOR=${BASH_REMATCH[2]}
    if ((MAJOR > 3 || (MAJOR == 3 && MINOR >= 3))); then
        ZWJ=1
        if ((MAJOR == 3 && MINOR == 3)); then ZWJ_ASCII=1; fi
    fi
    if ((MAJOR > 3 || (MAJOR == 3 && MINOR >= 4))); then
        MODIFIERS=1
        VARIATION_WIDE=1
        case $(tmux show-options -sqv variation-selector-always-wide 2>/dev/null) in
            off|0) VARIATION_WIDE=0 ;;
        esac
    fi
    if ((MAJOR == 3 && MINOR == 6)); then
        # 3.6a fixed the order in which skin-tone modifiers are combined.
        if [[ $VERSION == 3.6 ]]; then MODIFIERS=3; else MODIFIERS=4; fi
    elif ((MAJOR > 3 || (MAJOR == 3 && MINOR >= 7))); then
        MODIFIERS=2
    fi
fi

# Newer tmux can capture the copy-mode snapshot itself. Its history size
# stays fixed even if the underlying program continues producing output.
SNAPSHOT=0
CAPTURE=(-p -S - -E - -t "$PANE")
case $(tmux list-commands capture-pane 2>/dev/null) in
    *M*) CAPTURE+=(-M); SNAPSHOT=1 ;;
esac
if MATCHED=$(tmux capture-pane "${CAPTURE[@]}" 2>/dev/null |
    LC_ALL=C "$AWK" -v scope="$SCOPE" -v opens="$OPENS" -v closes="$CLOSES" \
        -v currow="$ABS_ROW" -v curcx="$CX" -v snapshot="$SNAPSHOT" \
        -v height="$H" -v scroll="$SP" -v cursory="$CY" -v pane="$PANE" \
        -v history="$HIST" -v zwj="$ZWJ" -v zwj_ascii="$ZWJ_ASCII" \
        -v modifiers="$MODIFIERS" -v variation_wide="$VARIATION_WIDE" \
        -f "$DIR/surround.awk" 2>/dev/null); then
    :
else
    status=$?
    if ((status == 1)); then
        notify_fail
    else
        notify_fail "unable to match pane text (exit $status)"
    fi
    exit 0
fi
read -r R1 C1 R2 C2 ENDLEN P1 P2 OPEN_ROW OPEN_INDEX CLOSE_ROW CLOSE_INDEX ROWS ONLY_BOUNDARIES <<< "$MATCHED"
if ((SNAPSHOT)); then
    HIST=$((ROWS - H))
    ABS_ROW=$((HIST - SP + CY))
fi

if ((ONLY_BOUNDARIES)); then
    # capture-pane -J joins soft wraps but retains hard newlines. A pair
    # split only by a soft wrap has no inner text and must fail closed.
    JOINED_ARGS=(-p -J -S "$((OPEN_ROW - HIST))" -E "$((CLOSE_ROW - HIST))" -t "$PANE")
    if ((SNAPSHOT)); then JOINED_ARGS+=(-M); fi
    if ! JOINED=$(tmux capture-pane "${JOINED_ARGS[@]}" 2>/dev/null); then
        notify_fail "unable to read copy mode"
        exit 0
    fi
    if [[ $JOINED != *$'\n'* ]]; then
        notify_fail
        exit 0
    fi
fi

# tmux's vi-mode selection includes both the anchor and the cursor.
# Vertical positioning uses the cheapest of the current row, history-top,
# and history-bottom, then positions on each physical row.

CUR_ROW=$ABS_ROW
TOTAL=$((HIST + H))
ARGS=()

flush() {
    if ((${#ARGS[@]} > 0)) && ! tmux "${ARGS[@]}" 2>/dev/null; then
        notify_fail "unable to apply selection"
        exit 0
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
        x -N "$d" cursor-down
    elif ((d < 0)); then
        x -N "$((-d))" cursor-up
    fi
    CUR_ROW=$target
}

current_row() {
    local y scroll
    IFS=, read -r y scroll <<< "$(tmux display-message -p -t "$PANE" \
        '#{copy_cursor_y},#{scroll_position}')"
    if [[ ! $y =~ ^[0-9]+$ || ! $scroll =~ ^[0-9]+$ ]]; then
        notify_fail "unable to position selection"
        exit 0
    fi
    CURRENT_ACTUAL_ROW=$((HIST - scroll + y))
}

position() {
    local target=$1 offset=$2
    goto_row "$target"
    # start-of-line moves to the start of the logical line, which may be
    # several physical rows above a soft wrap. Return to the requested row
    # at column zero before taking character steps.
    x start-of-line
    flush
    current_row
    if ((CURRENT_ACTUAL_ROW > target)); then
        notify_fail "unable to position selection"
        exit 0
    fi
    if ((CURRENT_ACTUAL_ROW < target)); then
        x -N "$((target - CURRENT_ACTUAL_ROW))" cursor-down
    fi
    if ((offset > 0)); then
        x -N "$offset" cursor-right
    fi
    CUR_ROW=$target
}
# Text objects are characterwise, regardless of an earlier rectangle toggle.
x rectangle-off

if [[ $SCOPE == inner ]] && ((OPEN_ROW != CLOSE_ROW)); then
    # Emacs-mode cursor movement can address the virtual cell at a hard
    # line ending. It lets us include newlines immediately inside a pair;
    # vi-mode movement otherwise jumps over those cells. Restore the exact
    # window option (including inheritance) before the user copies.
    LOCAL_MODE=$(tmux show-options -wqv -t "$PANE" mode-keys 2>/dev/null || true)
    restore_mode() {
        if [[ -n $LOCAL_MODE ]]; then
            tmux set-option -w -t "$PANE" mode-keys "$LOCAL_MODE" 2>/dev/null || true
        else
            tmux set-option -wu -t "$PANE" mode-keys 2>/dev/null || true
        fi
    }
    if ! tmux set-option -w -t "$PANE" mode-keys emacs 2>/dev/null; then
        notify_fail "unable to position selection"
        exit 0
    fi
    trap restore_mode EXIT
    trap 'exit 0' HUP INT TERM
    position "$OPEN_ROW" "$OPEN_INDEX"
    x cursor-right
    x begin-selection
    flush
    current_row
    CUR_ROW=$CURRENT_ACTUAL_ROW
    position "$CLOSE_ROW" "$CLOSE_INDEX"
    x cursor-left
    flush
    restore_mode
    trap - EXIT HUP INT TERM
else
    position "$R1" "$P1"
    x begin-selection
    position "$R2" "$P2"
fi

flush

# optional auto-copy
COPY_ON_SELECT=$(tmux show-options -gv '@ci-ca-copy-on-select' 2>/dev/null || true)
if [[ $COPY_ON_SELECT == 1 ]]; then
    tmux send-keys -t "$PANE" -X copy-selection-and-cancel
fi
exit 0
