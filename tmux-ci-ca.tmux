#!/usr/bin/env bash
# tmux-ci-ca — complete vim-style ci/ca text objects for tmux copy mode.
#
# Adds operator-pending `c`, `i` (inner), and `a` (around) key tables to
# copy-mode-vi. After ci/ca, the pair character selects the enclosed
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

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_CA="$SCRIPT_DIR/scripts/ci-ca.sh"

# Quote the script path for the shell and escape # for tmux's format
# expansion, which happens when the key is used.
SHELL_PATH=${CI_CA//\'/\'\\\'\'}
SHELL_PATH=${SHELL_PATH//#/##}

# "key pair_name"
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
        # run-shell takes one shell command argument, not a command followed
        # by separate arguments. Resolve the pane when the key is pressed.
        tmux bind-key -T "$table" "$key" run-shell \
            "'$SHELL_PATH' $scope $pair #{pane_id}"
        i=$((i + 2))
    done
    # Any other key aborts the pending sequence.
    tmux bind-key -T "$table" Any switch-client -T copy-mode-vi
}

tmux bind-key -T copy-mode-vi c switch-client -T ci-ca-operator
tmux bind-key -T ci-ca-operator i switch-client -T ci-ca-inner
tmux bind-key -T ci-ca-operator a switch-client -T ci-ca-around
tmux bind-key -T ci-ca-operator Any switch-client -T copy-mode-vi
# Match Enter's default behavior without replacing a user's existing y binding.
if ! tmux list-keys -T copy-mode-vi | awk '
    { for (i = 1; i <= NF - 2; i++)
        if ($i == "-T" && $(i + 1) == "copy-mode-vi" && $(i + 2) == "y") found = 1 }
    END { exit !found }
'; then
    tmux bind-key -T copy-mode-vi y send-keys -X copy-pipe-and-cancel
fi
add_table inner ci-ca-inner
add_table around ci-ca-around

tmux display-message "tmux-ci-ca: ci/ca ready (copy mode: ci/ca, then pair)"
