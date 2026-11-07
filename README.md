# tmux-ci-ca

Complete vim-style `ci` / `ca` enclosed-text selection for **tmux copy mode**.

Enter copy mode (`prefix + [`), press `ci` or `ca`, then the pair character —
the enclosed text is selected with tmux's native selection highlight, ready
for `y` / Enter exactly like any `v` selection.

## Supported pairs

| keys | pair (ASCII + CJK twins) |
|---|---|
| `(` `)` `b` | `()` 與全形 `（）` |
| `{` `}` `B` | `{}` 與全形 `｛｝` |
| `[` `]` | `[]`、全形 `［］` 與中式 `【】` |
| `<` `>` | `<>`、`〈〉` 與 `《》` |
| `"` | `"` 與彎引號 `“…”` |
| `'` | `'` 與 `‘…’` |
| `` ` `` | backtick |

CJK 全形/彎引號字元與 ASCII 配對在同一族內可互換：游標在 `（…）` 內按
`ci(` 會選到全形括號的內容。

## Why this is different from keybind-only approaches

Plugins such as [tmux-vilto](https://github.com/chathurb/tmux-vilto) compose
tmux's `jump-to-forward`/`jump-backward` copy-mode commands. That approach
cannot count nesting, cannot fail safely, and only works within the visible
screen. tmux-ci-ca instead computes the range with a real matcher
(`scripts/surround.awk`) over the captured pane buffer — the full scrollback —
and drives tmux's selection with exact cursor navigation:

- nesting depth counting: `f(a, (b + c), d)` selects the pair under the cursor
- already-matched pairs net out, matching vim's semantics
- quotes follow vim behavior: a quote under the cursor opens the region
  extending forward; otherwise the nearest quote backward opens it
- pairs may span soft-wrapped rows and blank lines
- wide glyphs (CJK, emoji) count as two cells; combining marks are skipped
- fail closed: no enclosing pair or an empty inner region leaves the
  selection untouched and shows a status-line hint (move the cursor inside
  the pair first — e.g. with `/search` or `hjkl` — then press ci/ca again)

## Install

### With TPM

```tmux
set -g @plugin 'killkli/tmux-ci-ca'
```

### Manual (no TPM)

```tmux
# ~/.tmux.conf
run-shell ~/.tmux/plugins/tmux-ci-ca/tmux-ci-ca.tmux
```

## Options

```tmux
# copy the selection and leave copy mode immediately after ci/ca
# (default off: the selection stays open for y / Enter)
set -g @ci-ca-copy-on-select "1"

# silence the "no enclosing pair" status message
set -g @ci-ca-notify "0"
```

## Keys in copy mode

- `ci` / `ca`, then the pair character
- Esc or any other key aborts the pending sequence (returns to copy mode)
- `y` / Enter copy the selection; `q` leaves copy mode

## Testing

```bash
test/awk_tests.sh    # matcher unit tests (22 cases, no tmux needed)
test/run_tests.sh    # integration tests on a throwaway tmux server (16 cases)
```

## Requirements

- tmux 3.2+ (developed on 3.7), any awk, bash 3.2+
