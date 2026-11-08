# ==========================================================
#  tmux-ci-ca: True Vim-style ci / ca for tmux copy mode
# ==========================================================

# 1. Nested Parentheses: cursor on (base + offset) -> press `ci(`
data = fetch_metrics(service, (base_val + offset), timeout)

# 2. String Quotes: cursor inside string -> press `ca"`
message = "Welcome to tmux-ci-ca! Native Vim text objects."

# 3. CJK Twin Pairs: cursor inside CJK brackets -> press `ci(`
status = "系統狀態：（服務運行中：正常）"

# 4. Multiline Braces: cursor inside dict -> press `ci{`
config = {
    "engine": "vhs",
    "multiplexer": "tmux",
    "mode": "vi-copy"
}
