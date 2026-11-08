# tmux-ci-ca

Complete vim-style `ci` / `ca` enclosed-text selection for **tmux copy mode**.

![tmux-ci-ca demo](assets/demo.gif)

Enable vi copy-mode keys, enter copy mode (`prefix + [`), and move the cursor
onto or inside a pair. Press `c`, then `i` (inner) or `a` (around), then the
pair character. For example, `ci(` selects the text inside parentheses and
`ca(` includes the parentheses. The native tmux selection stays highlighted
until you copy it with `y` or Enter, or leave copy mode.

## Supported pairs

| keys | pair (ASCII + CJK twins) |
|---|---|
| `(` `)` `b` | `()` 與全形 `（）` |
| `{` `}` `B` | `{}` 與全形 `｛｝` |
| `[` `]` | `[]`、全形 `［］` 與中式 `【】` |
| `<` `>` | `<>`、`〈〉` 與 `《》` |
| `"` | `"`、全形 `＂` 與彎引號 `“…”` |
| `'` | `'` 與 `‘…’` |
| `` ` `` | backtick |

CJK 全形/彎引號字元與 ASCII 配對在同一族內可互換：游標在 `（…）` 內按
`ci(` 會選到全形括號的內容。

## Why this is different from keybind-only approaches

Plugins such as [tmux-vilto](https://github.com/chathurb/tmux-vilto) compose
tmux's `jump-to-forward`/`jump-backward` copy-mode commands. That approach
cannot count nesting, cannot fail safely, and only works within the visible
screen. tmux-ci-ca instead computes the range with a real matcher
(`scripts/surround.awk`) over the pane buffer and its scrollback, then drives
tmux's native selection with cursor navigation:

- nesting depth counting: `f(a, (b + c), d)` selects the pair under the cursor
- already-matched pairs net out, matching vim's semantics
- a quote under the cursor opens the region extending forward; otherwise the
  nearest unescaped quote backward opens it
- pairs may span soft-wrapped rows and blank lines, including newlines at the
  start or end of the selected text
- CJK characters and common emoji sequences are handled using tmux's cell
  and grapheme conventions
- no enclosing pair or an empty inner region leaves the existing selection
  untouched and shows a status-line hint

On tmux 3.6 and newer, matching uses the copy-mode snapshot even if the pane
continues producing output. Earlier tmux versions can capture only the live
pane buffer: if the pane changes while you are in copy mode, leave and
re-enter copy mode before selecting.

The copied text is the text tmux stores; some older tmux builds insert padding
spaces in emoji sequences containing variation selectors.

## Install

詳細步驟、剪貼簿設定、更新與疑難排解，請參閱[繁體中文安裝指南](INSTALL.md)。

### With TPM

Set vi mode in `~/.tmux.conf`, and add the plugin before TPM is started:

```tmux
setw -g mode-keys vi
set -g @plugin 'killkli/tmux-ci-ca'
```

### Manual (no TPM)

```tmux
# ~/.tmux.conf
setw -g mode-keys vi
run-shell ~/.tmux/plugins/tmux-ci-ca/tmux-ci-ca.tmux
```

Reload the configuration (`tmux source-file ~/.tmux.conf`), or start a new
tmux server after installing.

## Options

```tmux
# copy to a tmux buffer and leave copy mode immediately after ci/ca
# (default off: the selection stays open for y / Enter)
set -g @ci-ca-copy-on-select "1"

# silence the "no enclosing pair" status message
set -g @ci-ca-notify "0"
```

## Keys in copy mode

- `c`, then `i` or `a`, then the pair character
- Esc or any other unrecognised key aborts the pending sequence
- `y` / Enter copy the selection; `q` leaves copy mode. If `y` is unbound,
  the plugin gives it the same default copy behavior as Enter; an existing
  `y` binding is left unchanged.

## Testing

```bash
test/awk_tests.sh    # matcher tests; no tmux needed
test/run_tests.sh    # real tmux client on an isolated server; requires Python 3
```

## Requirements

- Runtime: tmux 3.2+, any awk, and bash 3.2+
- Integration tests: Python 3, in addition to the runtime requirements
