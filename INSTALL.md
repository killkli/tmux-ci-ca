# 安裝指南

`tmux-ci-ca` 在 tmux 的 **vi copy mode** 中提供 `ci`／`ca` 文字物件選取。它會選取並複製文字，不會修改原本窗格中的內容。

## 環境需求

- tmux 3.2 以上、Bash 3.2 以上、`awk` 和 Git。
- 選取中文或其他 Unicode 字元時，終端機與 tmux 請使用 UTF-8 locale。
- 執行整合測試需要 Python 3；使用外掛本身不需要 Python。

可先檢查：

```sh
tmux -V
bash --version
command -v awk git
locale
```

macOS 使用者若已安裝 Homebrew，可以用 `brew install tmux` 安裝 tmux。其他系統請使用系統套件管理器，並確認版本符合需求。

以下選擇 **TPM 或手動安裝其中一種**；不要讓同一份設定同時載入兩份不同位置的 `tmux-ci-ca`。

## 方法一：使用 TPM

若尚未安裝 [Tmux Plugin Manager](https://github.com/tmux-plugins/tpm)，先執行：

```sh
mkdir -p ~/.tmux/plugins
git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
```

若目錄已存在，略過這一步。接著在 `~/.tmux.conf` 中設定：

```tmux
setw -g mode-keys vi

set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'killkli/tmux-ci-ca'

# TPM 初始化應放在所有 @plugin 宣告之後
run '~/.tmux/plugins/tpm/tpm'
```

如果原本已有 TPM 初始化行，保留原本那一行即可，不要新增第二行。將 `killkli/tmux-ci-ca` 的宣告放在初始化行之前。

在已執行的 tmux 中重新載入設定：

```sh
tmux source-file ~/.tmux.conf
```

接著按 tmux 的 prefix，再按大寫 `I`（預設是 `Ctrl-b`，接著 `Shift-i`），由 TPM 安裝外掛。等待安裝完成，出現 `Done, press ENTER to continue` 時按 Enter 返回。若尚未啟動 tmux，先執行 `tmux` 進入後再操作。

## 方法二：手動安裝

將專案複製到固定位置：

```sh
mkdir -p ~/.tmux/plugins
git clone https://github.com/killkli/tmux-ci-ca.git ~/.tmux/plugins/tmux-ci-ca
```

若目標目錄已存在，先確認其內容；不要直接覆蓋。已存在的 Git checkout 可參考下方「更新既有安裝」。

在 `~/.tmux.conf` 中加入：

```tmux
setw -g mode-keys vi
run-shell '"$HOME/.tmux/plugins/tmux-ci-ca/tmux-ci-ca.tmux"'
```

這個寫法可處理家目錄路徑中的空白。若專案放在其他位置，請改成該 checkout 的實際路徑，例如：

```tmux
run-shell '"$HOME/GitDev/tmux-ci-ca/tmux-ci-ca.tmux"'
```

請保留該目錄：tmux 每次載入設定時都會從此路徑執行外掛。在已執行的 tmux 中套用設定：

```sh
tmux source-file ~/.tmux.conf
```

如果設定檔原本有指向舊版 `tmux-ci-ca` 的 `run-shell`，請**替換舊行**，而不是額外加入另一行。

## 使用與驗證

1. 在 tmux 窗格中印出範例：

   ```sh
   printf 'calc (alpha beta) done\n'
   ```

2. 按 prefix、`[` 進入 copy mode（預設 prefix 是 `Ctrl-b`）。用 `h`、`j`、`k`、`l` 將游標移到 `alpha beta` 內。
3. 依序按 `c`、`i`、`(`。應看到 `alpha beta` 被原生選取反白，**不含括號**。
4. 按 `y` 或 Enter 複製並離開 copy mode；按 prefix、`]` 可貼上 tmux buffer。
5. 若要連同括號選取，重新進入 copy mode，在括號內依序按 `c`、`a`、`(`，結果應為 `(alpha beta)`。

支援的括號、引號與別名請見 [README 的配對表](README.md#supported-pairs)。按 Escape 或其他未識別的按鍵可中止尚未完成的 `ci`／`ca`。找不到包圍游標的配對，或 inner 範圍為空時，外掛會保留原有選取並顯示提示。

## 系統剪貼簿

外掛不會覆蓋已有的 copy-mode-vi `y` 綁定。若沒有自訂綁定，外掛會提供 `y` 供複製使用；是否同步到系統剪貼簿取決於 tmux 和終端機設定。

例如 macOS 可在 `~/.tmux.conf` 加入以下設定，讓 `y` 經由 `pbcopy` 複製到系統剪貼簿：

```tmux
bind-key -T copy-mode-vi y send-keys -X copy-pipe-and-cancel "pbcopy"
```

Wayland 使用者可在安裝 `wl-copy` 後，將 `pbcopy` 換成 `wl-copy`；X11 使用者可使用已安裝的 `xclip -selection clipboard`。修改設定後重新執行 `tmux source-file ~/.tmux.conf`。

如需選取後立刻複製並離開 copy mode，可加入：

```tmux
set -g @ci-ca-copy-on-select "1"
```

這個選項直接使用 tmux 的 `copy-selection-and-cancel`，不會執行自訂 `y` 綁定中的 `pbcopy`／`wl-copy` 指令。若依賴該指令，請維持預設值並在選取後按 `y`。

## 更新既有安裝

TPM 安裝可按 prefix、`U`，依提示更新外掛。

手動 Git 安裝請先檢查本機是否有尚未提交的修改，再以 fast-forward 方式更新：

```sh
git -C ~/.tmux/plugins/tmux-ci-ca status --short
git -C ~/.tmux/plugins/tmux-ci-ca pull --ff-only
tmux source-file ~/.tmux.conf
```

如果有本機修改或更新被拒絕，請先檢查並保留那些修改，不要強制重設。若設定使用的是其他 checkout，請改用該 checkout 的路徑。

## 疑難排解

**按 `ci(` 沒有作用**

- 確認已進入 vi copy mode，且游標位於配對字元上或其內部：

  ```sh
  tmux display-message -p '#{mode-keys}'
  tmux list-keys -T copy-mode-vi
  tmux list-keys -T ci-ca-operator
  tmux list-keys -T ci-ca-inner
  ```

  第一個指令應顯示 `vi`；`copy-mode-vi` 中的 `c` 應切換到 `ci-ca-operator`，後兩個表格則應存在。如果其他設定或外掛後來重新綁定了 `c`，請調整載入順序。
- 確認 `ci-ca-inner` 的 `run-shell` 指向預期 checkout 內的 `scripts/ci-ca.sh`。更新錯誤位置的副本不會更新目前載入的外掛。
- `ci(` 不會選取空的 `()`；使用 `ca(` 可選取括號本身。

**出現舊版腳本 `returned 1` 訊息**

檢查 `~/.tmux.conf` 是否仍載入舊目錄或同時載入兩份外掛。更新或修正路徑後執行 `tmux source-file ~/.tmux.conf`，再用上述按鍵檢查確認載入位置。

**copy mode 期間窗格持續輸出**

在 tmux 3.6 以上，外掛會比對進入 copy mode 時的快照。tmux 3.2–3.5 只能擷取即時窗格；若內容已變動，請離開並重新進入 copy mode 再選取。部分舊版 tmux 也可能在含 variation selector 的 emoji 中加入填補空白；外掛會複製 tmux 實際儲存的文字。

**執行專案測試**

在專案根目錄執行：

```sh
test/awk_tests.sh
test/run_tests.sh
```

第二項會使用 Python 3 啟動獨立的 tmux 測試伺服器，不會操作目前的 tmux 主伺服器。
