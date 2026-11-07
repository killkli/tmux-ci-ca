#!/usr/bin/env bash
# Unit tests for scripts/surround.awk (no tmux needed).
#
# Each case feeds a synthetic buffer and cursor, runs the matcher, and
# compares the printed range "<r1> <c1> <r2> <c2> <row2_cell_len>" against
# the expected value. Exit code 1 (no pair / empty inner) is asserted with
# EXPECT=FAIL.

set -u
AWK="${AWK:-awk}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
AWKFILE="$DIR/scripts/surround.awk"

pass=0
fail=0

check() {
    local name=$1 expect=$2 scope=$3 open=$4 close=$5 currow=$6 curcx=$7
    shift 7
    local buffer out rc
    buffer=$(printf '%s\n' "$@")
    out=$(LC_ALL=C "$AWK" -v scope="$scope" -v opens="$open" -v closes="$close" \
        -v currow="$currow" -v curcx="$curcx" -f "$AWKFILE" <<< "$buffer")
    rc=$?
    out=$(head -1 <<< "$out" | cut -d' ' -f1-5)
    if [[ $expect == FAIL ]]; then
        if ((rc != 0)); then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
            echo "FAIL $name: expected failure, got '$out'"
        fi
        return
    fi
    if [[ $out == "$expect" ]]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL $name: expected [$expect], got [$out] (rc=$rc)"
    fi
}

# fn (arg one) end
#   cols: f0 n1 sp2 (3 a4 r5 g6 sp7 o8 n9 e10 sp11 e12 n13 d14  (len 15)
check inner-paren-basic "0 4 0 10 16" inner '(' ')' 0 8 \
    'fn (arg one) end'
check around-paren-basic "0 3 0 11 16" around '(' ')' 0 8 \
    'fn (arg one) end'
check inner-on-open "0 4 0 10 16" inner '(' ')' 0 3 \
    'fn (arg one) end'
check inner-on-close "0 4 0 10 16" inner '(' ')' 0 11 \
    'fn (arg one) end'

# f(a, (b + c), d)
#   cols: f0 (1 a2 ,3 sp4 (5 b6 sp7 +8 sp9 c10 )11 ,12 sp13 d14 )15 (len 16)
check inner-nested-inner "0 6 0 10 16" inner '(' ')' 0 7 \
    'f(a, (b + c), d)'
check inner-nested-outer "0 2 0 14 16" inner '(' ')' 0 13 \
    'f(a, (b + c), d)'

# let s = "say hi"; done
#   cols: l0 e1 t2 sp3 s4 sp5 =6 sp7 "8 s9 a10 y11 sp12 h13 i14 "15 ;16 sp17 d18 o19 n20 e21 (len 22)
check inner-quote "0 9 0 14 22" inner '"' '"' 0 10 \
    'let s = "say hi"; done'
check around-quote "0 8 0 15 22" around '"' '"' 0 10 \
    'let s = "say hi"; done'
check inner-on-quote "0 9 0 14 22" inner '"' '"' 0 8 \
    'let s = "say hi"; done'

# let a = "aa" + "bb"; x
#   cols: ... "8 a9 a10 "11 sp12 +13 sp14 "15 b16 b17 "18 ;19 sp20 x21
# cursor between two strings: nearest quote backward (11) + forward (15)
check inner-quote-between "0 12 0 14 22" inner '"' '"' 0 14 \
    'let a = "aa" + "bb"; x'

# pair across a soft wrap / physical rows
#   row0: foo(   row1: bar)baz — inner = bar (starts on row 1)
check inner-multiline "1 0 1 2 7" inner '(' ')' 1 2 \
    'foo(' \
    'bar)baz'

# open at end of one row, close inside a later row: inner = bar
check inner-blank-line "2 0 2 2 7" inner '(' ')' 0 3 \
    'foo(' \
    '' \
    'bar)baz'

# close at start of a later row: empty inner fails
check inner-empty-cross-row FAIL inner '(' ')' 0 3 \
    'foo(' \
    '' \
    ')bar'

# empty inner fails; around the empty pair works
check empty-inner FAIL inner '(' ')' 0 7 \
    'pair() tail'
# cursor after a fully closed pair: nothing encloses it
check around-after-closed FAIL around '(' ')' 0 7 \
    'pair() tail'
check inner-after-closed FAIL inner '(' ')' 0 7 \
    'pair() tail'

# no pair at all
check no-pair FAIL inner '(' ')' 1 3 \
    'aaa bbb' \
    'ccc ddd'

# unmatched open only
check unmatched-open FAIL inner '(' ')' 0 10 \
    'open ( only'

# single-char inner is valid: (x) -> x
check inner-single-char "0 1 0 1 5" inner '(' ')' 0 1 \
    '(x)yz'

# wide chars: 中(文)
#   cells: 中 0-1, ( 2, 文 3-4, ) 5 (row cell len 6)
check inner-wide "0 3 0 4 6" inner '(' ')' 0 4 \
    '中(文)'
check around-wide "0 2 0 5 6" around '(' ')' 0 4 \
    '中(文)'

# combining mark has zero width: a + U+0301 occupies one cell (col 0)
#   row0: a<cc81>(   row1: x)  -> inner = x
check inner-combining "1 0 1 0 2" inner '(' ')' 0 1 \
    "a$(printf '\xcc\x81')(" \
    'x)'

echo "pass=$pass fail=$fail"
((fail == 0))
