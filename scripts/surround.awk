# tmux-copy-mode surround matcher.
#
# Reads the captured pane buffer (one physical row per input line) on stdin
# and computes the vim-style enclosed-text object around the copy-mode
# cursor. Output: "<r1> <c1> <r2> <c2> <row2_cell_len>" (0-based cell
# coordinates, selection endpoints inclusive). Exits 1 with no output when
# no enclosing pair exists or the inner region is empty.
#
# Variables: scope ("inner"|"around"), ochar, cchar, currow (absolute buffer
# row of the copy-mode cursor), curcx (cursor cell column).
#
# Runs under LC_ALL=C: input is scanned bytewise and UTF-8 sequences are
# grouped into characters with pure-arithmetic codepoint decoding, so any
# awk works. Cell columns use an East-Asian-width table so wide glyphs
# occupy two cells, matching tmux cursor semantics.
#
# Matching is a port of the herdr implementation:
# - brackets count nesting depth; already-matched pairs net out
# - quotes (ochar == cchar) use vim semantics: a quote under the cursor
#   opens the region extending forward; otherwise the nearest quote
#   backward opens the region extending forward
# - the cursor on a pair character anchors the object directly

function byte_at(str, idx) {
    return ORD[substr(str, idx, 1)]
}

function char_width(code) {
    if (code == -1) return 1
    # combining marks and zero-width characters
    if ((code >= 768 && code <= 879) || (code >= 65024 && code <= 65039) ||
        code == 8204 || code == 8205)
        return 0
    # wide: Hangul syllables, fullwidth forms, emoji, CJK ideographs and
    # compatibility, kana/bopomofo blocks, CJK punctuation
    if ((code >= 1100 && code <= 1151) ||
        (code >= 44032 && code <= 55215) ||
        (code >= 65280 && code <= 65519) ||
        (code >= 127744 && code <= 129791) ||
        (code >= 11904 && code <= 12031) ||
        (code >= 12352 && code <= 12543) ||
        (code >= 12784 && code <= 12799) ||
        (code >= 19904 && code <= 42127) ||
        (code >= 43472 && code <= 43487) ||
        (code >= 63744 && code <= 64255) ||
        (code >= 131072 && code <= 196607))
        return 2
    return 1
}

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

function match_backward(li, ci,    ch, depth) {
    depth = 0
    for (;;) {
        while (ci > 0) {
            ci--
            ch = chtxt[li, ci]
            if (ch == cchar) {
                depth++
            } else if (ch == ochar) {
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
    quoted = (ochar == cchar)
    for (;;) {
        count = nchars[li]
        while (ci + 1 < count) {
            ci++
            ch = chtxt[li, ci]
            if (quoted && ch == cchar) {
                return li SUBSEP ci
            }
            if (ch == ochar) {
                depth++
            } else if (ch == cchar) {
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
            if (chtxt[li, ci] == want) return li SUBSEP ci
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
    nlines = 0
    quoted = (ochar == cchar)
}
{
    row = nlines
    i = 0
    n = length($0)
    cell = 0
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
        if (w > 0) {
            chstart[row, i] = cell
            chw[row, i] = w
            chtxt[row, i] = substr($0, p, s)
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
    curli = (currow >= 0 && currow < total) ? currow : (total > 0 ? total - 1 : -1)
    if (curli < 0) exit 1
    pos = row_position(curli, curcx)

    open_at = ""
    if (pos > 0) {
        ch = chtxt[curli, pos - 1]
        if (ch == ochar) open_at = curli SUBSEP (pos - 1)
        else if (!quoted && ch == cchar)
            open_at = match_backward(curli, pos - 1)
    }
    if (open_at == "") {
        if (quoted) open_at = scan_backward(curli, pos, ochar)
        else open_at = match_backward(curli, pos)
    }
    if (open_at == "") exit 1
    close_at = match_forward(open_at)
    if (close_at == "") exit 1

    if (scope == "around") {
        start = open_at
        end = close_at
    } else {
        start = next_char(open_at)
        end = prev_char(close_at)
        if (start == "" || end == "") exit 1
        split(start, sp, SUBSEP)
        split(end, ep, SUBSEP)
        # empty inner: the first inner char sits past the last inner char
        if (sp[1] > ep[1] ||
            (sp[1] == ep[1] && chstart[sp[1], sp[2]] > chstart[ep[1], ep[2]]))
            exit 1
    }

    split(start, sp, SUBSEP)
    split(end, ep, SUBSEP)
    # inclusive last cell of the end char (a wide char owns its tail cell)
    endcell = chstart[ep[1], ep[2]] + chw[ep[1], ep[2]] - 1
    # tmux cursor-right skips wide tails, so horizontal moves are counted in
    # CHAR positions: rights to land on a cell = chars starting at/before it.
    if (endcell + 1 < celllen[ep[1]]) {
        # rights needed to rest the cursor on the cell after the end char
        p2 = row_position(ep[1], endcell + 1) - 1
    } else {
        p2 = -1
    }
    print sp[1], chstart[sp[1], sp[2]], ep[1], endcell, celllen[ep[1]], \
        row_position(sp[1], chstart[sp[1], sp[2]]) - 1, p2
}
