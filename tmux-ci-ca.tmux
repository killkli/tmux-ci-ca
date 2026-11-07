#!/usr/bin/env bash
# tmux-ci-ca — complete vim-style ci/ca text objects for tmux copy mode.
#
# Adds operator-pending `i` (inner) and `a` (around) key tables to
# copy-mode-vi. After pressing i/a, the pair character selects the enclosed
# text: pairs are () b B {} [] <> and quotes " ' `.
#
# Unlike keybind-only approaches, selections are computed by a matcher over
# the real pane buffer (full scrollback) with nesting-depth counting and
# fail-closed behavior — see scripts/ci-ca.sh and scripts/surround.awk.
#
# Options (tmux server options):
#   set -g @ci-ca-copy-on-select "1"   # copy + leave copy mode on select
#   set -g @ci-ca-notify "0"           # silence the failure status message
#
# TPM: set -g @plugin '<user>/tmux-ci-ca'
#
# Written for bash 3.2 (macOS stock) — no associative arrays.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_CA="$SCRIPT_DIR/scripts/ci-ca.sh"

# "key pair_name" — pair names are shell-safe words passed through tmux's
# command re-parser and run-shell's sh -c without any quoting hazards.
PAIRS=(
    '(' paren
    ')' paren
    'b' paren
    '{' brace
    '}' brace
    'B' brace
    '[' bracket
    ']' bracket
    '<' angle
    '>' angle
    '"' dq
    "'" sq
    '`' bt
)

add_table() {
    local scope=$1 table=$2 i=0 key pair
    while ((i < ${#PAIRS[@]})); do
        key=${PAIRS[$i]}
        pair=${PAIRS[$((i + 1))]}
        tmux bind-key -T "$table" "$key" \
            "run-shell -b \"$CI_CA\" $scope $pair #{pane_id}" \
            \; switch-client -T copy-mode-vi
        i=$((i + 2))
    done
    # any unbound key leaves the operator-pending table (covers esc/q)
    tmux bind-key -T "$table" Any switch-client -T copy-mode-vi
}

tmux bind-key -T copy-mode-vi i switch-client -T ci-ca-inner
tmux bind-key -T copy-mode-vi a switch-client -T ci-ca-around
add_table inner ci-ca-inner
add_table around ci-ca-around

tmux display-message "tmux-ci-ca: ci/ca ready (copy mode: i or a, then pair)"
