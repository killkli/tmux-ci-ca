# tmux-copy-mode surround matcher.
#
# Reads the captured pane buffer (one physical row per input line) on stdin
# and computes the vim-style enclosed-text object around the copy-mode
# cursor. Output: "<r1> <c1> <r2> <c2> <row2_cell_len> <p1> <p2>
# <open_row> <open_index> <close_row> <close_index> <total_rows>
# <only_row_boundaries>". Coordinates and navigation offsets are zero-based.
# Exits 1 when there is no selection.
#
# Variables: scope ("inner"|"around"), opens, closes (open/closer character
# classes), currow (absolute row), curcx (cell column). When snapshot is 1,
# currow is derived from the captured row count, height, scroll and cursory.
#
# Runs under LC_ALL=C: input is scanned bytewise and UTF-8 sequences are
# grouped into characters with pure-arithmetic codepoint decoding, so any
# awk works. Cell columns use an East-Asian-width table so wide glyphs
# occupy two cells, matching tmux cursor semantics.
#
# Matching is a port of the herdr implementation:
# - brackets count nesting depth; already-matched pairs net out
# - quotes (opens == closes) use vim semantics: a quote under the cursor
#   opens the region extending forward; otherwise the nearest quote
#   backward opens the region extending forward
# - the cursor on a pair character anchors the object directly

function byte_at(str, idx) {
    return ORD[substr(str, idx, 1)]
}

function char_width(code) {
    if (code == -1) return 1
    # combining marks and zero-width characters
    if ((code >= 768 && code <= 879) || (code >= 6832 && code <= 6911) ||
        (code >= 7616 && code <= 7679) || (code >= 8400 && code <= 8447) ||
        (code >= 65024 && code <= 65039) || (code >= 65056 && code <= 65071) ||
        (code >= 917760 && code <= 917999) ||
        code == 8203 || code == 8204 || code == 8205 || code == 8288 ||
        code == 65279)
        return 0
    # wide: Hangul syllables, fullwidth forms, emoji, CJK ideographs and
    # compatibility, kana/bopomofo blocks, CJK punctuation
    if ((code >= 1100 && code <= 1151) ||
        (code >= 44032 && code <= 55215) ||
        (code >= 65281 && code <= 65376) ||
        (code >= 65504 && code <= 65510) ||
        (code >= 127744 && code <= 129791) ||
        (code >= 11904 && code <= 12031) ||
        (code >= 12352 && code <= 12543) ||
        (code >= 12288 && code <= 12543) ||
        (code >= 19904 && code <= 42127) ||
        (code >= 43472 && code <= 43487) ||
        (code >= 63744 && code <= 64255) ||
        (code >= 131072 && code <= 196607))
        return 2
    return 1
}

function regional(code) { return code >= 127462 && code <= 127487 }
function skin_tone(code) { return code >= 127995 && code <= 127999 }

# positions are (row, char index) pairs; cell columns derive from chstart

function row_position(li, cx,    i, pos) {
    # number of chars starting at or before cell column cx
    pos = 0
    for (i = 0; i < nchars[li]; i++) {
        if (chstart[li, i] <= cx) pos = i + 1
        else break
    }
    return pos
}

function next_char(at,    parts, li, ci) {
    split(at, parts, SUBSEP)
    li = parts[1]; ci = parts[2]
    for (;;) {
        if (ci + 1 < nchars[li]) return li SUBSEP (ci + 1)
        li++
        ci = -1
        if (!(li in nchars)) return ""
        if (nchars[li] > 0) return li SUBSEP 0
    }
}

function prev_char(at,    parts, li, ci) {
    split(at, parts, SUBSEP)
    li = parts[1]; ci = parts[2]
    for (;;) {
        if (ci > 0) return li SUBSEP (ci - 1)
        li--
        if (li < 0) return ""
        if (nchars[li] > 0) return li SUBSEP (nchars[li] - 1)
    }
}

function in_opens(ch) { return index(opens, ch) > 0 }
function in_closes(ch) { return index(closes, ch) > 0 }

function wrapped_into(li,    cmd, line, lines, status) {
    if (li in wrap_known) return wrap_value[li]
    if (pane !~ /^%[0-9]+$/) {
        wrap_error = 1
        return 0
    }
    cmd = "tmux capture-pane -p -J -S " (li - 1 - history) \
        " -E " (li - history) " -t " pane
    if (snapshot == 1) cmd = cmd " -M"
    cmd = cmd " 2>/dev/null"
    lines = 0
    while ((cmd | getline line) > 0) lines++
    status = close(cmd)
    if (status != 0 || lines < 1 || lines > 2) {
        wrap_error = 1
        return 0
    }
    wrap_known[li] = 1
    wrap_value[li] = (lines == 1)
    return wrap_value[li]
}

function quote_escaped(li, ci,    count) {
    count = 0
    for (;;) {
        while (ci > 0 && chtxt[li, ci - 1] == "\\") {
            count++
            ci--
        }
        if (ci > 0 || li == 0 || nchars[li - 1] == 0 ||
            chtxt[li - 1, nchars[li - 1] - 1] != "\\" ||
            !wrapped_into(li))
            break
        li--
        ci = nchars[li]
    }
    return count % 2
}

function match_backward(li, ci,    ch, depth) {
    depth = 0
    for (;;) {
        while (ci > 0) {
            ci--
            ch = chtxt[li, ci]
            if (in_closes(ch)) {
                depth++
            } else if (in_opens(ch)) {
                if (depth == 0) return li SUBSEP ci
                depth--
            }
        }
        li--
        if (li < 0) return ""
        ci = (li in nchars) ? nchars[li] : 0
    }
}

function match_forward(okey,    parts, li, ci, ch, depth, quoted, count) {
    split(okey, parts, SUBSEP)
    li = parts[1]; ci = parts[2]
    depth = 0
    quoted = (opens == closes)
    for (;;) {
        count = nchars[li]
        while (ci + 1 < count) {
            ci++
            ch = chtxt[li, ci]
            if (quoted) {
                if (in_closes(ch) && !quote_escaped(li, ci))
                    return li SUBSEP ci
                continue
            }
            if (in_opens(ch)) {
                depth++
            } else if (in_closes(ch)) {
                if (depth == 0) return li SUBSEP ci
                depth--
            }
        }
        li++
        ci = -1
        if (!(li in nchars)) return ""
    }
}

function scan_backward(li, ci, want) {
    for (;;) {
        while (ci > 0) {
            ci--
            if (in_closes(chtxt[li, ci]) && !quote_escaped(li, ci))
                return li SUBSEP ci
        }
        li--
        if (li < 0) return ""
        ci = (li in nchars) ? nchars[li] : 0
    }
}

BEGIN {
    # byte ordinal table (LC_ALL=C: sprintf("%c", n) yields byte n)
    for (ord_i = 1; ord_i <= 255; ord_i++)
        ORD[sprintf("%c", ord_i)] = ord_i
    # Emoji bases for tmux 3.6+'s skin-tone combination rules.
    count = split("128075 128076 128077 128078 128079 128080 128102 128103 " \
        "128104 128105 128110 128112 128113 128114 128115 128116 128117 " \
        "128118 128119 128120 128124 128129 128130 128131 128133 128134 " \
        "128135 128170 128373 128378 128400 128405 128406 128581 128582 " \
        "128583 128587 128588 128589 128590 128591 128692 128693 128694 " \
        "129318 129335 129336 129337 129341 129342 129461 129462 129464 " \
        "129465 129485 129486 129487 129489 129490 129491 129492 129493 " \
        "129494 129495 129496 129497 129498 129499 129500 129501 129502 " \
        "129503", base_codes, " ")
    for (base_i = 1; base_i <= count; base_i++)
        skin_base[base_codes[base_i]] = 1
    nlines = 0
    quoted = (opens == closes)
}
{
    row = nlines
    i = 0
    n = length($0)
    cell = 0
    join_next = 0
    previous = 0
    regional_count = 0
    p = 1
    while (p <= n) {
        b = byte_at($0, p)
        if (b < 0) break
        if (b < 128) {
            code = b
            s = 1
        } else {
            s = (b >= 194 && b <= 223) ? 2 : (b >= 224 && b <= 239) ? 3 : (b >= 240 && b <= 244) ? 4 : 1
            code = b - (s == 2 ? 192 : s == 3 ? 224 : s == 4 ? 240 : 128)
            bad = 0
            for (k = 2; k <= s; k++) {
                nb = (p + k - 1 <= n) ? byte_at($0, p + k - 1) : -1
                if (nb < 128 || nb > 191) { bad = 1; break }
                code = code * 64 + (nb - 128)
            }
            if (bad) { code = b; s = 1 }
        }
        w = char_width(code)
        if (code == 8205) {
            join_next = zwj && i > 0
        } else if (w == 0) {
            # tmux may widen a single-cell glyph when U+FE0F follows it.
            if (code == 65039 && variation_wide && i > 0 && chw[row, i - 1] == 1) {
                chw[row, i - 1] = 2
                cell++
            }
            join_next = 0
        } else if (i > 0 &&
            ((join_next && (s > 1 || zwj_ascii)) ||
             (modifiers == 1 && previous >= 128 && (regional(code) || skin_tone(code))) ||
             (modifiers >= 2 &&
              ((regional(code) && regional(previous) &&
                (modifiers != 2 || regional_count == 1)) ||
               (modifiers != 3 && skin_tone(code) && skin_base[previous]) ||
               (skin_tone(previous) && skin_base[code]))))) {
            if (!join_next && chw[row, i - 1] == 1) {
                chw[row, i - 1] = 2
                cell++
            }
            if (regional(code)) regional_count++
            join_next = 0
        } else {
            join_next = 0
            chstart[row, i] = cell
            chw[row, i] = w
            chtxt[row, i] = substr($0, p, s)
            previous = code
            regional_count = regional(code) ? 1 : 0
            cell += w
            i++
        }
        p += s
    }
    nchars[row] = i
    celllen[row] = cell
    nlines++
}
END {
    total = nlines
    if (snapshot == 1) {
        history = nlines - height
        currow = history - scroll + cursory
    }
    if (currow < 0 || currow >= total || curcx < 0) exit 1
    curli = currow
    pos = row_position(curli, curcx)

    open_at = ""
    if (pos > 0 && curcx < chstart[curli, pos - 1] + chw[curli, pos - 1]) {
        ch = chtxt[curli, pos - 1]
        if (in_opens(ch) && (!quoted || !quote_escaped(curli, pos - 1)))
            open_at = curli SUBSEP (pos - 1)
        else if (!quoted && in_closes(ch))
            open_at = match_backward(curli, pos - 1)
    }
    if (open_at == "") {
        if (quoted) open_at = scan_backward(curli, pos)
        else open_at = match_backward(curli, pos)
    }
    if (wrap_error) exit 2
    if (open_at == "") exit 1
    close_at = match_forward(open_at)
    if (wrap_error) exit 2
    if (close_at == "") exit 1
    split(open_at, op, SUBSEP)
    split(close_at, cp, SUBSEP)
    only_row_boundaries = 0

    if (scope == "around") {
        start = open_at
        end = close_at
    } else {
        start = next_char(open_at)
        end = prev_char(close_at)
        if (start == "" || end == "") exit 1
        split(start, sp, SUBSEP)
        split(end, ep, SUBSEP)
        # With no characters between delimiters, same-row pairs are empty.
        # Across rows the caller checks whether the boundaries are hard
        # newlines or an empty soft wrap.
        if (sp[1] > ep[1] ||
            (sp[1] == ep[1] && chstart[sp[1], sp[2]] > chstart[ep[1], ep[2]])) {
            if (op[1] == cp[1]) exit 1
            start = open_at
            end = close_at
            only_row_boundaries = 1
        }
    }

    split(start, sp, SUBSEP)
    split(end, ep, SUBSEP)
    # inclusive last cell of the end char (a wide char owns its tail cell)
    endcell = chstart[ep[1], ep[2]] + chw[ep[1], ep[2]] - 1
    # Offsets point at inclusive endpoints; delimiter positions also let the
    # caller include newlines immediately inside a multi-row pair.
    print sp[1], chstart[sp[1], sp[2]], ep[1], endcell, celllen[ep[1]], \
        sp[2], ep[2], op[1], op[2], cp[1], cp[2], nlines, only_row_boundaries
}
