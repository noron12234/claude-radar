#!/bin/zsh
# 確保浮動面板activate著。必須從 cmux 內部呼叫 —— cmux 的 socket 只接受
# 「從 cmux 裡啟動的行程」，launchd 起的面板連得上畫面卻連不上 socket，
# 結果就是列表空白、而且點了不會跳。行程脫離 shell 後權限仍保留，
# 所以這裡 nohup 出去沒問題。
#
# 由兩個地方呼叫，兩者都跑在 cmux 內：
#   1. ~/.zshrc          —— 開新分頁時
#   2. cc_notify.py hook —— 每次有 Claude 結束一輪時（等於持續 keepalive）

BIN="$HOME/.claude/tools/bin/claude-panel"
[ -x "$BIN" ] || exit 0

# 用 -x 比對行程名，不能用 -f：-f 會連「指令列裡剛好含有這個路徑」的
# shell 也比中（例如這支腳本自己的呼叫端），結果永遠誤判成已在跑。
# 真正的單一實例保證在程式內的 flock，這裡只是省一次 fork。
pgrep -x claude-panel > /dev/null 2>&1 && exit 0

nohup "$BIN" > /tmp/claude-panel.log 2>&1 &
disown 2>/dev/null
exit 0

